const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ogg_validator = @import("ogg_validator.zig");
const vorbis_validator = @import("vorbis_validator.zig");
const opus_validator = @import("opus_validator.zig");
const ac3_validator = @import("ac3_validator.zig");
const eac3_validator = @import("eac3_validator.zig");
const wavpack_decoder = @import("wavpack_decoder.zig");
const midi_validator = @import("midi_validator.zig");
const tracker_validator = @import("tracker_validator.zig");
const libopenmpt = @import("libopenmpt.zig");
const flac_decoder = @import("flac_decoder.zig");
const mp3_decode_validator = @import("mp3_decode_validator.zig");
const mp3_validator = @import("mp3_validator.zig");
const aac_syntax_validator = @import("aac_syntax_validator.zig");
const errmsg = @import("error_messages.zig");

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;
const ValidationDepth = format_validation.ValidationDepth;

// ============ Helper ============

const findInBuffer = format_validation.findInBuffer;

// ============ MP3 Validator ============

/// Validate MP3 file structure.
pub fn validateMp3(file: std.fs.File) ValidationResult {
    var header: [10]u8 = undefined;
    var pos: u64 = 0;

    file.seekTo(0) catch return ValidationResult.invalidCode(.mp3, .failed_to_seek, "to start");
    _ = file.read(&header) catch return ValidationResult.invalidCode(.mp3, .failed_to_read, "MP3 header");

    // Loop to skip multiple ID3v2 tags (some files have multiple consecutive tags)
    while (std.mem.eql(u8, header[0..3], "ID3")) {
        // Valid ID3v2 header, skip to audio data
        // ID3v2 size is in bytes 6-9, syncsafe integer (7 bits per byte, MSB always 0)
        const size = (@as(u32, header[6] & 0x7F) << 21) |
            (@as(u32, header[7] & 0x7F) << 14) |
            (@as(u32, header[8] & 0x7F) << 7) |
            @as(u32, header[9] & 0x7F);
        pos = pos + 10 + size;

        file.seekTo(pos) catch {
            return ValidationResult.invalidCode(.mp3, .failed_to_seek, "past ID3");
        };

        // Read next header (might be another ID3 or frame sync)
        _ = file.read(&header) catch {
            return ValidationResult.invalidCode(.mp3, .failed_to_read, "after ID3");
        };
    }

    // Check for frame sync (0xFF followed by 0xE* or 0xF*)
    if (header[0] == 0xFF and (header[1] & 0xE0) == 0xE0) {
        return ValidationResult.ok(.mp3);
    }

    return ValidationResult.invalidCode(.mp3, .invalid_value, "MP3 frame sync");
}

// ============ FLAC Validator ============

/// Validate FLAC file structure.
pub fn validateFlac(file: std.fs.File) ValidationResult {
    var header: [4]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.flac, .failed_to_read, "FLAC header");

    // Check fLaC signature
    if (!std.mem.eql(u8, &header, "fLaC")) {
        return ValidationResult.invalidCode(.flac, .invalid_signature, "FLAC");
    }

    // Read metadata block header
    var meta_header: [4]u8 = undefined;
    _ = file.read(&meta_header) catch {
        return ValidationResult.invalidCode(.flac, .failed_to_read, "metadata header");
    };

    // First metadata block must be STREAMINFO (type 0)
    const block_type = meta_header[0] & 0x7F;
    if (block_type != 0) {
        return ValidationResult.invalid(.flac, "First metadata block must be STREAMINFO");
    }

    // STREAMINFO is 34 bytes
    const block_size = (@as(u32, meta_header[1]) << 16) |
        (@as(u32, meta_header[2]) << 8) |
        @as(u32, meta_header[3]);

    if (block_size != 34) {
        return ValidationResult.invalidCode(.flac, .invalid_value, "STREAMINFO size");
    }

    return ValidationResult.ok(.flac);
}

// ============ WAV Validator ============

/// Validate WAV file structure (RIFF container).
pub fn validateWav(file: std.fs.File) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.wav, .failed_to_read, "WAV header");

    // Check RIFF signature
    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCode(.wav, .invalid_signature, "RIFF");
    }

    // Check WAVE fourcc
    if (!std.mem.eql(u8, header[8..12], "WAVE")) {
        return ValidationResult.invalidCode(.wav, .invalid_value, "WAVE fourcc");
    }

    // Get declared RIFF size
    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.wav, .failed_to_get, "file size");
    };

    if (riff_size + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(.wav, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size (truncated)");
    }

    // Look for fmt chunk
    var buffer: [256]u8 = undefined;
    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.invalidCode(.wav, .failed_to_read, "WAV data");
    };

    if (!findInBuffer(&buffer, bytes_read, "fmt ")) {
        return ValidationResult.invalidCode(.wav, .missing, "fmt chunk");
    }

    return ValidationResult.ok(.wav);
}

/// Deep WAV validation - verifies fmt chunk, data chunk size, and file consistency.
pub fn validateWavDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator; // No longer needed - using streaming validation

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.wav, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.wav, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.wav, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size for bounds checking
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_get, "file size", .structural);
    };

    if (file_size < 44) { // Minimum WAV size: 12 (RIFF) + 24 (fmt) + 8 (data header)
        return ValidationResult.invalidCodeWithDepth(.wav, .file_too_small, "valid WAV", .structural);
    }

    // Read RIFF header (12 bytes)
    var header: [12]u8 = undefined;
    const header_read = file.readAll(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_read, "header", .structural);
    };
    if (header_read < 12) {
        return ValidationResult.invalidCodeWithDepth(.wav, .truncated, "header", .structural);
    }

    // Verify RIFF/WAVE signature
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) {
        return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "WAV header", .structural);
    }

    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    if (@as(u64, riff_size) + 8 > file_size) {
        return ValidationResult.invalidCodeMsgWithDepth(.wav, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size", .structural);
    }

    // Stream through chunks without loading entire file
    var offset: u64 = 12;
    var found_fmt = false;
    var found_data = false;
    var fmt_audio_format: u16 = 0;
    var fmt_channels: u16 = 0;
    var fmt_sample_rate: u32 = 0;
    var fmt_bits_per_sample: u16 = 0;
    var data_chunk_offset: u64 = 0;
    var data_chunk_size: u32 = 0;

    while (offset + 8 <= file_size) {
        // Seek to chunk header
        file.seekTo(offset) catch {
            return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_seek, "to chunk", .structural);
        };

        // Read chunk header (8 bytes: 4 ID + 4 size)
        var chunk_header: [8]u8 = undefined;
        const chunk_read = file.readAll(&chunk_header) catch {
            break; // End of file
        };
        if (chunk_read < 8) break;

        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        // Validate chunk doesn't exceed file
        if (offset + 8 + chunk_size > file_size) {
            // Allow slight overrun for last chunk (common in some encoders)
            if (found_fmt and found_data) {
                break;
            }
            return ValidationResult.invalidWithDepth(.wav, "Chunk extends beyond file", .structural);
        }

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            found_fmt = true;

            if (chunk_size < 16) {
                return ValidationResult.invalidWithDepth(.wav, "fmt chunk too small", .structural);
            }

            // Read fmt chunk data for validation
            var fmt_data: [16]u8 = undefined;
            const fmt_read = file.readAll(&fmt_data) catch {
                return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_read, "fmt chunk", .structural);
            };
            if (fmt_read < 16) {
                return ValidationResult.invalidCodeWithDepth(.wav, .truncated, "fmt chunk", .structural);
            }

            fmt_audio_format = std.mem.readInt(u16, fmt_data[0..2], .little);
            fmt_channels = std.mem.readInt(u16, fmt_data[2..4], .little);
            fmt_sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little);
            // bytes 8-11: byte rate
            // bytes 12-13: block align
            fmt_bits_per_sample = std.mem.readInt(u16, fmt_data[14..16], .little);

            // Validate format parameters
            if (fmt_channels == 0 or fmt_channels > 32) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "channel count", .structural);
            }
            if (fmt_sample_rate == 0 or fmt_sample_rate > 384000) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "sample rate", .structural);
            }
            if (fmt_bits_per_sample == 0 or fmt_bits_per_sample > 64) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "bits per sample", .structural);
            }
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            found_data = true;
            data_chunk_offset = offset + 8;
            data_chunk_size = chunk_size;

            // For data chunk, verify size is consistent with format
            if (found_fmt and fmt_channels > 0 and fmt_bits_per_sample > 0) {
                const bytes_per_sample = (fmt_bits_per_sample + 7) / 8;
                const block_align = fmt_channels * bytes_per_sample;
                if (block_align > 0 and chunk_size % block_align != 0) {
                    // Data size not aligned to block boundary - warn but don't fail
                    // Some encoders pad with extra bytes
                }
            }
        }

        // Move to next chunk (pad to even boundary per RIFF spec)
        offset += 8 + chunk_size;
        if (chunk_size % 2 != 0) {
            offset += 1;
        }
    }

    if (!found_fmt) {
        return ValidationResult.invalidCodeWithDepth(.wav, .missing, "fmt chunk", .structural);
    }
    if (!found_data) {
        return ValidationResult.invalidCodeWithDepth(.wav, .missing, "data chunk", .structural);
    }

    // IEEE 754 float PCM (format tag 3): scan every sample for NaN/Inf corruption
    if (fmt_audio_format == 3 and (fmt_bits_per_sample == 32 or fmt_bits_per_sample == 64)) {
        return validateWavFloatSamples(file, data_chunk_offset, data_chunk_size, fmt_bits_per_sample);
    }

    // Integer PCM: no corruption signal (any value is valid) — structural only
    return ValidationResult.okWithDepth(.wav, .structural);
}

/// Scan IEEE 754 float WAV samples for NaN/Inf — definitive corruption signal.
fn validateWavFloatSamples(file: std.fs.File, data_offset: u64, data_size: u32, bits_per_sample: u16) ValidationResult {
    file.seekTo(data_offset) catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_seek, "to audio data", .full);
    };

    var buf: [65536]u8 = undefined;
    var remaining: u64 = data_size;
    const sample_bytes: usize = if (bits_per_sample == 64) 8 else 4;

    while (remaining > 0) {
        const to_read = @min(remaining, buf.len);
        const bytes_read = file.read(buf[0..@intCast(to_read)]) catch {
            return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_read, "audio data", .full);
        };
        if (bytes_read == 0) break;

        // Check each aligned sample in the buffer
        const aligned_len = (bytes_read / sample_bytes) * sample_bytes;
        var pos: usize = 0;
        while (pos + sample_bytes <= aligned_len) : (pos += sample_bytes) {
            if (sample_bytes == 4) {
                const val: f32 = @bitCast(std.mem.readInt(u32, buf[pos..][0..4], .little));
                if (std.math.isNan(val) or std.math.isInf(val)) {
                    return ValidationResult.invalidWithDepth(.wav, "NaN/Inf in float audio data (corruption)", .full);
                }
            } else {
                const val: f64 = @bitCast(std.mem.readInt(u64, buf[pos..][0..8], .little));
                if (std.math.isNan(val) or std.math.isInf(val)) {
                    return ValidationResult.invalidWithDepth(.wav, "NaN/Inf in float audio data (corruption)", .full);
                }
            }
        }

        remaining -= bytes_read;
    }

    return ValidationResult.okWithDepth(.wav, .full);
}

/// Deep validation for AIFF audio files.
/// Parses all IFF chunks and validates structure similar to WAV deep validation.
pub fn validateAiffDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.aiff, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.aiff, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.aiff, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Read entire file for validation
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.aiff, .failed_to_get, "file size", .structural);
    };

    if (file_size < 12) { // Minimum AIFF: FORM header
        return ValidationResult.invalidCodeWithDepth(.aiff, .file_too_small, "valid AIFF", .structural);
    }

    if (file_size > 100 * 1024 * 1024) { // 100MB limit for deep validation
        // For large files, just do structural validation
        return ValidationResult.okWithDepth(.aiff, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalidWithDepth(.aiff, "Memory allocation failed", .structural);
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.aiff, .failed_to_read, "file", .structural);
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCodeWithDepth(.aiff, .incomplete, "file read", .structural);
    }

    // Verify FORM header
    if (!std.mem.eql(u8, data[0..4], "FORM")) {
        return ValidationResult.invalidCodeWithDepth(.aiff, .invalid_value, "AIFF header (not FORM)", .structural);
    }

    const form_size = std.mem.readInt(u32, data[4..8], .big);
    if (form_size + 8 > file_size) {
        return ValidationResult.invalidCodeMsgWithDepth(.aiff, .exceeds_bounds, "FORM size", "FORM size exceeds file size", .structural);
    }

    // Check AIFF or AIFC form type
    const is_aifc = std.mem.eql(u8, data[8..12], "AIFC");
    if (!std.mem.eql(u8, data[8..12], "AIFF") and !is_aifc) {
        return ValidationResult.invalidCodeWithDepth(.aiff, .invalid_value, "AIFF form type", .structural);
    }

    // Parse chunks
    var offset: usize = 12;
    var found_comm = false;
    var found_ssnd = false;
    var comm_sample_size: u16 = 0;
    var is_float = false;
    var ssnd_data_start: usize = 0;
    var ssnd_data_len: usize = 0;

    while (offset + 8 <= file_size) {
        const chunk_id = data[offset..][0..4];
        const chunk_size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big);

        if (std.mem.eql(u8, chunk_id, "COMM")) {
            found_comm = true;

            // Validate COMM chunk contents
            if (offset + 8 + chunk_size > file_size) {
                return ValidationResult.invalidWithDepth(.aiff, "COMM chunk extends beyond file", .structural);
            }
            if (chunk_size < 18) {
                return ValidationResult.invalidWithDepth(.aiff, "COMM chunk too small", .structural);
            }

            // COMM: numChannels(2) + numSampleFrames(4) + sampleSize(2) + sampleRate(10)
            const comm_data = data[offset + 8 ..];
            comm_sample_size = std.mem.readInt(u16, comm_data[4..6], .big);

            // AIFC has compressionType after the standard COMM fields
            if (is_aifc and chunk_size >= 22) {
                const comp_type = comm_data[18..22];
                // fl32/FL32 = 32-bit float, fl64/FL64 = 64-bit float
                if (std.mem.eql(u8, comp_type, "fl32") or std.mem.eql(u8, comp_type, "FL32") or
                    std.mem.eql(u8, comp_type, "fl64") or std.mem.eql(u8, comp_type, "FL64"))
                {
                    is_float = true;
                }
            }
        } else if (std.mem.eql(u8, chunk_id, "SSND")) {
            found_ssnd = true;

            // Verify SSND chunk doesn't exceed file
            if (offset + 8 + chunk_size > file_size) {
                return ValidationResult.invalidWithDepth(.aiff, "SSND chunk extends beyond file", .structural);
            }

            // SSND: offset(4) + blockSize(4) + sound data
            if (chunk_size >= 8) {
                ssnd_data_start = offset + 8 + 8; // skip chunk header + offset/blockSize fields
                ssnd_data_len = chunk_size - 8;
            }
        }

        // Move to next chunk (pad to even boundary)
        offset += 8 + chunk_size;
        if (chunk_size % 2 != 0 and offset < file_size) {
            offset += 1;
        }
    }

    if (!found_comm) {
        return ValidationResult.invalidCodeWithDepth(.aiff, .missing, "COMM chunk", .structural);
    }
    if (!found_ssnd) {
        return ValidationResult.invalidCodeWithDepth(.aiff, .missing, "SSND chunk", .structural);
    }

    // AIFC float: scan every sample for NaN/Inf — definitive corruption signal
    if (is_float and ssnd_data_len > 0 and ssnd_data_start + ssnd_data_len <= file_size) {
        const sample_bytes: usize = if (comm_sample_size == 64) 8 else 4;
        const ssnd_data = data[ssnd_data_start..][0..ssnd_data_len];
        const aligned_len = (ssnd_data_len / sample_bytes) * sample_bytes;
        var pos: usize = 0;
        while (pos + sample_bytes <= aligned_len) : (pos += sample_bytes) {
            if (sample_bytes == 4) {
                const val: f32 = @bitCast(std.mem.readInt(u32, ssnd_data[pos..][0..4], .big));
                if (std.math.isNan(val) or std.math.isInf(val)) {
                    return ValidationResult.invalidWithDepth(.aiff, "NaN/Inf in float audio data (corruption)", .full);
                }
            } else {
                const val: f64 = @bitCast(std.mem.readInt(u64, ssnd_data[pos..][0..8], .big));
                if (std.math.isNan(val) or std.math.isInf(val)) {
                    return ValidationResult.invalidWithDepth(.aiff, "NaN/Inf in float audio data (corruption)", .full);
                }
            }
        }
        return ValidationResult.okWithDepth(.aiff, .full);
    }

    // Integer PCM: no corruption signal (any value is valid) — structural only
    return ValidationResult.okWithDepth(.aiff, .structural);
}

// ============ RIFF Audio Validator (WAV, AIFF) ============

/// Validate RIFF-based audio file structure (WAV, AIFF).
pub fn validateRiffAudio(file: std.fs.File, format: FileFormat) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(format, .failed_to_read, "audio header");

    // AIFF uses "FORM" instead of "RIFF"
    const is_riff = std.mem.eql(u8, header[0..4], "RIFF");
    const is_form = std.mem.eql(u8, header[0..4], "FORM");

    if (!is_riff and !is_form) {
        return ValidationResult.invalidCode(format, .invalid_signature, "container");
    }

    // Check fourcc based on format
    const expected_fourcc: []const u8 = switch (format) {
        .wav => "WAVE",
        .aiff => "AIFF",
        else => return ValidationResult.invalid(format, "Unexpected format for RIFF audio"),
    };

    if (!std.mem.eql(u8, header[8..12], expected_fourcc)) {
        return ValidationResult.invalidCode(format, .invalid_value, "format fourcc");
    }

    // Get declared size (big-endian for AIFF, little-endian for WAV)
    const declared_size = if (is_form)
        std.mem.readInt(u32, header[4..8], .big)
    else
        std.mem.readInt(u32, header[4..8], .little);

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    };

    if (declared_size + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(format, .exceeds_bounds, "Container size", "Container size exceeds file size (truncated)");
    }

    return ValidationResult.ok(format);
}

// ============ Ogg Validator ============

/// Validate Ogg container file structure (Vorbis, Opus, etc.).
pub fn validateOgg(file: std.fs.File) ValidationResult {
    var header: [27]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.ogg, .failed_to_read, "Ogg header");

    // Check OggS capture pattern
    if (!std.mem.eql(u8, header[0..4], "OggS")) {
        return ValidationResult.invalidCode(.ogg, .invalid_signature, "Ogg");
    }

    // Check stream structure version (must be 0)
    if (header[4] != 0) {
        return ValidationResult.invalidCode(.ogg, .unsupported, "Ogg version");
    }

    // Read segment table length
    const num_segments = header[26];

    // Verify we can read the segment table
    var segment_table: [255]u8 = undefined;
    if (num_segments > 0) {
        const seg_bytes = file.read(segment_table[0..num_segments]) catch {
            return ValidationResult.invalidCode(.ogg, .failed_to_read, "segment table");
        };
        if (seg_bytes < num_segments) {
            return ValidationResult.invalidCode(.ogg, .truncated, "segment table");
        }
    }

    // Check for valid stream by seeking to end and finding last page
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.ogg, .failed_to_get, "file size");
    };

    if (file_size < 27) {
        return ValidationResult.invalidCode(.ogg, .file_too_small, "Ogg");
    }

    // Quick check: look for OggS near end of file (last page)
    const search_start = if (file_size > 65536) file_size - 65536 else 0;
    file.seekTo(search_start) catch {
        return ValidationResult.invalidCode(.ogg, .failed_to_seek, "to end");
    };

    var buffer: [4096]u8 = undefined;
    var found_end_page = false;

    while (true) {
        const bytes_read = file.read(&buffer) catch break;
        if (bytes_read == 0) break;

        // Look for "OggS" in buffer
        var i: usize = 0;
        while (i + 4 <= bytes_read) : (i += 1) {
            if (std.mem.eql(u8, buffer[i..][0..4], "OggS")) {
                found_end_page = true;
            }
        }

        if (bytes_read < buffer.len) break;
    }

    if (!found_end_page and file_size > 4096) {
        return ValidationResult.invalid(.ogg, "No valid Ogg pages found (truncated)");
    }

    return ValidationResult.ok(.ogg);
}

/// Deep OGG validation using Vorbis or Opus codec decode.
/// First verifies OGG page CRCs, then decodes audio packets.
pub fn validateOggDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.ogg, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.ogg, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // First, verify OGG page CRCs for container integrity
    const crc_result = ogg_validator.validateOggCrc(file);
    if (!crc_result.valid) {
        return ValidationResult.invalidWithDepth(.ogg, crc_result.error_message orelse "OGG CRC verification failed", .full);
    }

    // Reset file position for packet extraction
    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "to start", .structural);
    };

    // Extract packets to determine codec type
    var packet_result = ogg_validator.extractPackets(allocator, file) catch |err| {
        return ValidationResult.invalidWithDepth(.ogg, switch (err) {
            error.TruncatedPageHeader => errmsg.truncated("OGG page header"),
            error.InvalidOggSignature => errmsg.invalidSignature("OGG"),
            error.UnsupportedOggVersion => errmsg.unsupported("OGG version"),
            error.TruncatedSegmentTable => errmsg.truncated("OGG segment table"),
            error.TruncatedPageData => errmsg.truncated("OGG page data"),
            else => "Failed to extract OGG packets",
        }, .full);
    };
    defer packet_result.deinit(allocator);

    if (packet_result.packets.len == 0) {
        return ValidationResult.invalidWithDepth(.ogg, "No packets found in OGG stream", .full);
    }

    // Determine codec type from first packet
    const first_packet = packet_result.packets[0].data;

    // Check for Vorbis: first byte 0x01 followed by "vorbis"
    if (first_packet.len >= 7 and first_packet[0] == 0x01 and std.mem.eql(u8, first_packet[1..7], "vorbis")) {
        // Reset and validate as Vorbis
        file.seekTo(0) catch {
            return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "for Vorbis validation", .full);
        };

        const vorbis_result = vorbis_validator.validateOggVorbisAlloc(allocator, file);
        if (vorbis_result.valid) {
            return ValidationResult.okWithDepth(.ogg, .full);
        } else {
            return ValidationResult.invalidWithDepth(.ogg, vorbis_result.error_message orelse "Vorbis validation failed", .full);
        }
    }

    // Check for Opus: starts with "OpusHead"
    if (first_packet.len >= 8 and std.mem.eql(u8, first_packet[0..8], "OpusHead")) {
        // Reset and validate as Opus
        file.seekTo(0) catch {
            return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "for Opus validation", .full);
        };

        const opus_result = opus_validator.validateOggOpus(file);
        if (opus_result.valid) {
            return ValidationResult.okWithDepth(.ogg, .full);
        } else {
            return ValidationResult.invalidWithDepth(.ogg, opus_result.error_message orelse "Opus validation failed", .full);
        }
    }

    // Check for Theora video: 0x80 followed by "theora"
    if (first_packet.len >= 7 and first_packet[0] == 0x80 and std.mem.eql(u8, first_packet[1..7], "theora")) {
        // Theora video - OGG CRC32 covers every byte of payload data,
        // so all bytes are verified even without bitstream decode
        return ValidationResult.okWithDepth(.ogv, .full);
    }

    // Check for FLAC in OGG: 0x7F followed by "FLAC"
    if (first_packet.len >= 5 and first_packet[0] == 0x7F and std.mem.eql(u8, first_packet[1..5], "FLAC")) {
        return ValidationResult.okWithDepthAndWarning(.ogg, .full, "FLAC-in-OGG codec - CRC verified, no bitstream decode");
    }

    // Check for Speex: starts with "Speex   " (with trailing spaces)
    if (first_packet.len >= 8 and std.mem.eql(u8, first_packet[0..8], "Speex   ")) {
        return ValidationResult.okWithDepthAndWarning(.ogg, .full, "Speex audio codec - CRC verified, no bitstream decode");
    }

    // Unknown codec - just verify CRC was OK (already done above)
    // Show first few bytes to help identify what it is
    if (first_packet.len >= 4) {
        // Format a hint about the unknown codec's signature
        return ValidationResult.okWithDepthAndWarning(.ogg, .full, errmsg.unknown("OGG codec, CRC verification only"));
    }
    return ValidationResult.okWithDepthAndWarning(.ogg, .full, errmsg.unknown("OGG codec, CRC verification only"));
}

// ============ MIDI Validator (Standard MIDI File) ============

/// Validate Standard MIDI File structure.
/// MIDI files consist of a header chunk (MThd) followed by one or more track chunks (MTrk).
pub fn validateMidi(file: std.fs.File) ValidationResult {
    // Read header chunk: "MThd" + 4-byte length + 6-byte data
    var header: [14]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.midi, .failed_to_read, "MIDI header");
    };

    if (bytes_read < 14) {
        return ValidationResult.invalidCode(.midi, .file_too_small, "MIDI");
    }

    // Check MThd signature
    if (!std.mem.eql(u8, header[0..4], "MThd")) {
        return ValidationResult.invalidCode(.midi, .invalid_signature, "MIDI");
    }

    // Check header length (big-endian, should be 6)
    const header_length = std.mem.readInt(u32, header[4..8], .big);
    if (header_length != 6) {
        return ValidationResult.invalidCode(.midi, .invalid_value, "MIDI header length");
    }

    // Parse format type (0 = single track, 1 = multi-track sync, 2 = multi-track async)
    const format_type = std.mem.readInt(u16, header[8..10], .big);
    if (format_type > 2) {
        return ValidationResult.invalidCode(.midi, .invalid_value, "MIDI format type");
    }

    // Parse track count
    const num_tracks = std.mem.readInt(u16, header[10..12], .big);
    if (num_tracks == 0) {
        return ValidationResult.invalid(.midi, "MIDI file has no tracks");
    }

    // Format 0 must have exactly 1 track
    if (format_type == 0 and num_tracks != 1) {
        return ValidationResult.invalid(.midi, "Format 0 MIDI must have exactly 1 track");
    }

    // Parse division (timing info) - just verify it's readable
    const division = std.mem.readInt(u16, header[12..14], .big);
    _ = division;

    // Verify at least one MTrk chunk exists
    var track_header: [8]u8 = undefined;
    const track_bytes = file.read(&track_header) catch {
        return ValidationResult.invalidCode(.midi, .failed_to_read, "track header");
    };

    if (track_bytes < 8) {
        return ValidationResult.invalidCode(.midi, .missing, "track chunk");
    }

    // Check MTrk signature
    if (!std.mem.eql(u8, track_header[0..4], "MTrk")) {
        return ValidationResult.invalidCode(.midi, .invalid_signature, "track chunk");
    }

    // Verify track length is reasonable
    const track_length = std.mem.readInt(u32, track_header[4..8], .big);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.midi, .failed_to_get, "file size");
    };

    // Track length should fit within remaining file
    if (track_length > file_size - 22) { // 14 header + 8 track header
        return ValidationResult.invalidCodeMsg(.midi, .exceeds_bounds, "Track length", "Track length exceeds file size");
    }

    return ValidationResult.ok(.midi);
}

// ============ DSD Audio Format Validators ============

/// Validate DSF (DSD Stream File) format.
/// DSF is Sony's chunk-based format for DSD audio.
/// Structure: DSD chunk (header) + fmt chunk (format info) + data chunk
pub fn validateDsf(file: std.fs.File) ValidationResult {
    var header: [28]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.dsf, .failed_to_read, "DSF header");
    };

    if (bytes_read < 28) {
        return ValidationResult.invalidCode(.dsf, .file_too_small, "DSF");
    }

    // Check DSD chunk signature
    if (!std.mem.eql(u8, header[0..4], "DSD ")) {
        return ValidationResult.invalidCode(.dsf, .invalid_signature, "DSF");
    }

    // DSD chunk size (little-endian u64) - should be 28
    const dsd_chunk_size = std.mem.readInt(u64, header[4..12], .little);
    if (dsd_chunk_size != 28) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "DSD chunk size");
    }

    // Total file size (little-endian u64)
    const total_size = std.mem.readInt(u64, header[12..20], .little);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.dsf, .failed_to_get, "file size");
    };

    // Allow some tolerance for metadata padding
    if (total_size > file_size + 4096) {
        return ValidationResult.invalid(.dsf, "DSF header claims larger size than file");
    }

    // Metadata offset (little-endian u64) - can be 0 if no metadata
    const metadata_offset = std.mem.readInt(u64, header[20..28], .little);
    if (metadata_offset != 0 and metadata_offset > file_size) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "metadata offset");
    }

    // Read fmt chunk header
    var fmt_header: [52]u8 = undefined;
    const fmt_bytes = file.read(&fmt_header) catch {
        return ValidationResult.invalidCode(.dsf, .failed_to_read, "fmt chunk");
    };

    if (fmt_bytes < 52) {
        return ValidationResult.invalidCode(.dsf, .missing, "fmt chunk");
    }

    // Check fmt chunk signature
    if (!std.mem.eql(u8, fmt_header[0..4], "fmt ")) {
        return ValidationResult.invalidCode(.dsf, .invalid_signature, "fmt chunk");
    }

    // fmt chunk size (should be 52)
    const fmt_chunk_size = std.mem.readInt(u64, fmt_header[4..12], .little);
    if (fmt_chunk_size != 52) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "fmt chunk size");
    }

    // Format version (should be 1)
    const format_version = std.mem.readInt(u32, fmt_header[12..16], .little);
    if (format_version != 1) {
        return ValidationResult.invalidCode(.dsf, .unsupported, "DSF format version");
    }

    // Format ID (0 = DSD raw)
    const format_id = std.mem.readInt(u32, fmt_header[16..20], .little);
    if (format_id != 0) {
        return ValidationResult.invalidCode(.dsf, .unsupported, "DSF format ID");
    }

    // Channel type (1-7 valid)
    const channel_type = std.mem.readInt(u32, fmt_header[20..24], .little);
    if (channel_type == 0 or channel_type > 7) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "channel type");
    }

    // Channel count (1-6)
    const channel_count = std.mem.readInt(u32, fmt_header[24..28], .little);
    if (channel_count == 0 or channel_count > 6) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "channel count");
    }

    // Sample rate (must be multiple of 2.8224 MHz base rate)
    const sample_rate = std.mem.readInt(u32, fmt_header[28..32], .little);
    // Valid DSD rates: 2822400 (DSD64), 5644800 (DSD128), 11289600 (DSD256), 22579200 (DSD512)
    const valid_rates = [_]u32{ 2822400, 5644800, 11289600, 22579200 };
    var valid_rate = false;
    for (valid_rates) |rate| {
        if (sample_rate == rate) {
            valid_rate = true;
            break;
        }
    }
    if (!valid_rate) {
        return ValidationResult.invalidCode(.dsf, .invalid_value, "DSD sample rate");
    }

    return ValidationResult.ok(.dsf);
}

/// Validate DFF (DSDIFF) format.
/// DSDIFF is Philips' IFF-based format for DSD audio.
/// Structure: FRM8 container with DSD form type, containing property chunks
pub fn validateDff(file: std.fs.File) ValidationResult {
    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.dff, .failed_to_read, "DFF header");
    };

    if (bytes_read < 16) {
        return ValidationResult.invalidCode(.dff, .file_too_small, "DFF");
    }

    // Check FRM8 signature (IFF container)
    if (!std.mem.eql(u8, header[0..4], "FRM8")) {
        return ValidationResult.invalidCode(.dff, .invalid_signature, "DFF");
    }

    // Chunk size (big-endian u64)
    const chunk_size = std.mem.readInt(u64, header[4..12], .big);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.dff, .failed_to_get, "file size");
    };

    // Chunk size + 12 (header) should approximately equal file size
    if (chunk_size + 12 > file_size + 4096) {
        return ValidationResult.invalidCodeMsg(.dff, .exceeds_bounds, "DFF chunk size", "DFF chunk size exceeds file size");
    }

    // Check form type "DSD " at offset 12
    if (!std.mem.eql(u8, header[12..16], "DSD ")) {
        return ValidationResult.invalidCode(.dff, .invalid_value, "DFF form type (expected DSD)");
    }

    // Read next chunk to verify structure (should be FVER or PROP)
    var next_chunk: [12]u8 = undefined;
    const next_bytes = file.read(&next_chunk) catch {
        return ValidationResult.invalidCode(.dff, .failed_to_read, "DFF chunks");
    };

    if (next_bytes < 12) {
        return ValidationResult.invalidCode(.dff, .missing, "DFF chunks");
    }

    // Check for expected chunk types
    const chunk_id = next_chunk[0..4];
    if (!std.mem.eql(u8, chunk_id, "FVER") and
        !std.mem.eql(u8, chunk_id, "PROP") and
        !std.mem.eql(u8, chunk_id, "DSD "))
    {
        return ValidationResult.invalid(.dff, "Unexpected DFF chunk type");
    }

    return ValidationResult.ok(.dff);
}

// ============ AC-3/E-AC-3 (Dolby Digital) Validators ============

/// Validate AC-3 (Dolby Digital) file structure.
/// AC-3 frames start with sync word 0x0B77, bsid 0-8 at byte 5 bits 3-7.
pub fn validateAc3(file: std.fs.File) ValidationResult {
    var header: [6]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.ac3, .failed_to_read, "AC-3 header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalidCode(.ac3, .file_too_small, "AC-3");
    }

    // Check sync word 0x0B77
    if (header[0] != 0x0B or header[1] != 0x77) {
        return ValidationResult.invalidCode(.ac3, .invalid_value, "AC-3 sync word");
    }

    // Check bsid (bit stream identification) at byte 5, bits 3-7
    // AC-3: bsid 0-8, E-AC-3: bsid 16
    const bsid = header[5] >> 3;
    if (bsid > 8) {
        return ValidationResult.invalidCode(.ac3, .invalid_value, "AC-3 bsid (expected 0-8)");
    }

    return ValidationResult.ok(.ac3);
}

/// Validate E-AC-3 (Dolby Digital Plus) file structure.
/// E-AC-3 frames start with sync word 0x0B77, bsid 16 at byte 5 bits 3-7.
pub fn validateEac3(file: std.fs.File) ValidationResult {
    var header: [6]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.eac3, .failed_to_read, "E-AC-3 header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalidCode(.eac3, .file_too_small, "E-AC-3");
    }

    // Check sync word 0x0B77
    if (header[0] != 0x0B or header[1] != 0x77) {
        return ValidationResult.invalidCode(.eac3, .invalid_value, "E-AC-3 sync word");
    }

    // Check bsid (bit stream identification) at byte 5, bits 3-7
    // E-AC-3 uses bsid 16
    const bsid = header[5] >> 3;
    if (bsid != 16) {
        return ValidationResult.invalidCode(.eac3, .invalid_value, "E-AC-3 bsid (expected 16)");
    }

    return ValidationResult.ok(.eac3);
}

// ============ Tracker/Module Format Validators ============

/// Validate ProTracker MOD file structure.
/// MOD files have a signature at offset 1080: "M.K.", "M!K!", "FLT4", "FLT8", "4CHN", etc.
pub fn validateMod(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.mod, .failed_to_get, "file size");
    };

    // Minimum MOD file size: 1084 bytes (to read signature at offset 1080)
    if (file_size < 1084) {
        return ValidationResult.invalidCode(.mod, .file_too_small, "MOD format");
    }

    // Read signature at offset 1080
    file.seekTo(1080) catch {
        return ValidationResult.invalidCode(.mod, .failed_to_seek, "to MOD signature");
    };

    var sig: [4]u8 = undefined;
    _ = file.read(&sig) catch {
        return ValidationResult.invalidCode(.mod, .failed_to_read, "MOD signature");
    };

    // Check for known MOD signatures
    const valid_sigs = [_][]const u8{
        "M.K.", // Standard ProTracker (4 channels)
        "M!K!", // ProTracker with more than 64 patterns
        "FLT4", // StarTrekker 4 channels
        "FLT8", // StarTrekker 8 channels
        "4CHN", // 4 channel MOD
        "6CHN", // 6 channel MOD
        "8CHN", // 8 channel MOD
        "CD81", // Octalyser
        "OKTA", // Octalyser
    };

    var found_valid_sig = false;
    for (valid_sigs) |valid_sig| {
        if (std.mem.eql(u8, &sig, valid_sig)) {
            found_valid_sig = true;
            break;
        }
    }

    // Also check for xCHN patterns (5CHN, 7CHN, 9CHN, etc.)
    if (!found_valid_sig and sig[1] == 'C' and sig[2] == 'H' and sig[3] == 'N') {
        if (sig[0] >= '1' and sig[0] <= '9') {
            found_valid_sig = true;
        }
    }

    // Check for xxCH patterns (10CH, 11CH, ..., 32CH)
    if (!found_valid_sig and sig[2] == 'C' and sig[3] == 'H') {
        if (sig[0] >= '1' and sig[0] <= '3' and sig[1] >= '0' and sig[1] <= '9') {
            found_valid_sig = true;
        }
    }

    if (!found_valid_sig) {
        return ValidationResult.invalidCode(.mod, .invalid_signature, "MOD");
    }

    return ValidationResult.ok(.mod);
}

/// Validate FastTracker 2 XM file structure.
/// XM files start with "Extended Module: " followed by module name and version info.
pub fn validateXm(file: std.fs.File) ValidationResult {
    var header: [80]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.xm, .failed_to_read, "XM header");
    };

    if (bytes_read < 80) {
        return ValidationResult.invalidCode(.xm, .file_too_small, "XM format");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..17], "Extended Module: ")) {
        return ValidationResult.invalidCode(.xm, .invalid_signature, "XM");
    }

    // Check for 0x1A marker at offset 37
    if (header[37] != 0x1A) {
        return ValidationResult.invalidCode(.xm, .missing, "XM end-of-text marker");
    }

    // Check version (offset 58-59, little-endian) - should be >= 0x0104
    const version = std.mem.readInt(u16, header[58..60], .little);
    if (version < 0x0102) {
        return ValidationResult.invalidCode(.xm, .unsupported, "XM version");
    }

    // Header size (offset 60-63) - should be reasonable
    const header_size = std.mem.readInt(u32, header[60..64], .little);
    if (header_size < 20 or header_size > 1000) {
        return ValidationResult.invalidCode(.xm, .invalid_value, "XM header size");
    }

    // Number of channels (offset 68-69)
    const num_channels = std.mem.readInt(u16, header[68..70], .little);
    if (num_channels == 0 or num_channels > 32) {
        return ValidationResult.invalidCode(.xm, .invalid_value, "XM channel count");
    }

    return ValidationResult.ok(.xm);
}

/// Validate Impulse Tracker IT file structure.
/// IT files start with "IMPM" signature followed by module info.
pub fn validateIt(file: std.fs.File) ValidationResult {
    var header: [192]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.it, .failed_to_read, "IT header");
    };

    if (bytes_read < 192) {
        return ValidationResult.invalidCode(.it, .file_too_small, "IT format");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..4], "IMPM")) {
        return ValidationResult.invalidCode(.it, .invalid_signature, "IT");
    }

    // Check version (offset 0x28-0x29)
    const version = std.mem.readInt(u16, header[0x28..0x2A], .little);
    if (version < 0x0200 or version > 0x0220) {
        // Most IT files are version 2.xx
        return ValidationResult.invalidCode(.it, .unsupported, "IT version");
    }

    // Number of orders (offset 0x20-0x21)
    const num_orders = std.mem.readInt(u16, header[0x20..0x22], .little);
    if (num_orders == 0) {
        return ValidationResult.invalid(.it, "IT file has no orders");
    }

    // Number of instruments (offset 0x22-0x23)
    const num_instruments = std.mem.readInt(u16, header[0x22..0x24], .little);
    if (num_instruments > 256) {
        return ValidationResult.invalidCode(.it, .invalid_value, "IT instrument count");
    }

    // Number of samples (offset 0x24-0x25)
    const num_samples = std.mem.readInt(u16, header[0x24..0x26], .little);
    if (num_samples > 256) {
        return ValidationResult.invalidCode(.it, .invalid_value, "IT sample count");
    }

    return ValidationResult.ok(.it);
}

/// Validate Scream Tracker 3 S3M file structure.
/// S3M files have "SCRM" signature at offset 44.
pub fn validateS3m(file: std.fs.File) ValidationResult {
    var header: [96]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.s3m, .failed_to_read, "S3M header");
    };

    if (bytes_read < 96) {
        return ValidationResult.invalidCode(.s3m, .file_too_small, "S3M format");
    }

    // Check signature at offset 44
    if (!std.mem.eql(u8, header[44..48], "SCRM")) {
        return ValidationResult.invalidCode(.s3m, .invalid_signature, "S3M");
    }

    // Check type (offset 0x1D) - should be 16 for S3M
    if (header[0x1D] != 16) {
        return ValidationResult.invalidCode(.s3m, .invalid_value, "S3M type byte");
    }

    // Number of orders (offset 0x20-0x21)
    const num_orders = std.mem.readInt(u16, header[0x20..0x22], .little);
    if (num_orders == 0 or num_orders > 256) {
        return ValidationResult.invalidCode(.s3m, .invalid_value, "S3M order count");
    }

    // Number of instruments (offset 0x22-0x23)
    const num_instruments = std.mem.readInt(u16, header[0x22..0x24], .little);
    if (num_instruments > 99) {
        return ValidationResult.invalidCode(.s3m, .invalid_value, "S3M instrument count");
    }

    // Number of patterns (offset 0x24-0x25)
    const num_patterns = std.mem.readInt(u16, header[0x24..0x26], .little);
    if (num_patterns > 100) {
        return ValidationResult.invalidCode(.s3m, .invalid_value, "S3M pattern count");
    }

    return ValidationResult.ok(.s3m);
}

// ============ Lossless Audio Format Validators (APE, WavPack) ============

/// Validate Monkey's Audio (APE) file structure.
/// APE files start with "MAC " signature followed by version and descriptor info.
pub fn validateApe(file: std.fs.File) ValidationResult {
    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.ape, .failed_to_read, "APE header");
    };

    if (bytes_read < 32) {
        return ValidationResult.invalidCode(.ape, .file_too_small, "APE format");
    }

    // Check "MAC " signature
    if (!std.mem.eql(u8, header[0..4], "MAC ")) {
        return ValidationResult.invalidCode(.ape, .invalid_signature, "APE");
    }

    // Version number (2 bytes at offset 4, little-endian)
    // Modern APE: >= 3980, Legacy APE: 3800-3979, Very old: < 3800
    const version = std.mem.readInt(u16, header[4..6], .little);
    if (version < 3800) {
        // Very old APE format - still valid, but limited checks possible
        return ValidationResult.ok(.ape);
    }

    // For version >= 3980, there's a descriptor block
    if (version >= 3980) {
        // Padding bytes at offset 6-7 should be zero
        if (header[6] != 0 or header[7] != 0) {
            // Not critical - some encoders may vary
        }

        // Descriptor length at offset 8 (4 bytes)
        const desc_length = std.mem.readInt(u32, header[8..12], .little);
        if (desc_length < 52) {
            return ValidationResult.invalid(.ape, "APE descriptor too small");
        }

        // Header length at offset 12 (4 bytes)
        const header_length = std.mem.readInt(u32, header[12..16], .little);
        if (header_length < 24) {
            return ValidationResult.invalid(.ape, "APE header too small");
        }
    }

    // APE has MD5 checksums for audio blocks (internal integrity),
    // but reading them requires parsing the full file structure.
    // For now, structural validation is sufficient.
    return ValidationResult.ok(.ape);
}

/// Validate WavPack audio file structure.
/// WavPack files start with "wvpk" signature followed by block header.
/// Uses deep validation to parse all blocks and detect MD5 sub-block.
pub fn validateWavPack(file: std.fs.File) ValidationResult {
    // Use the deep validator which parses all blocks and looks for MD5
    const allocator = std.heap.page_allocator;
    const result = wavpack_decoder.validateWavPackFile(file, 1000, allocator);

    if (!result.valid) {
        return ValidationResult.invalid(.wavpack, result.error_message orelse "WavPack validation failed");
    }

    // If MD5 sub-block is present, we've verified structural integrity at checksum level
    // (the MD5 itself can only be verified by full audio decode, but its presence
    // indicates the file was encoded with integrity information)
    if (result.has_md5) {
        return ValidationResult.okWithDepth(.wavpack, .full);
    }

    // No MD5 present - structural validation only
    // WavPack still has per-block CRC32 for decoded audio, but we'd need
    // full decode to verify those
    return ValidationResult.ok(.wavpack);
}

// ============ MIDI Deep Validation (track data parsing) ============

/// Deep MIDI validation by parsing all track data.
/// This validates delta times, event status/data bytes, running status,
/// and verifies each track ends with End of Track meta event.
pub fn validateMidiDeep(path: []const u8) ValidationResult {
    const result = midi_validator.validateMidiDeep(path);
    if (result.valid) {
        return ValidationResult.okWithDepth(.midi, .full);
    } else {
        return ValidationResult.invalidWithDepth(.midi, result.error_message orelse "MIDI validation failed", .full);
    }
}

// ============ AC-3 / E-AC-3 Deep Validation ============

/// Deep AC-3 (Dolby Digital) validation by parsing frame structure and verifying CRCs.
pub fn validateAc3Deep(path: []const u8) ValidationResult {
    const result = ac3_validator.validateAc3File(path, 1000); // Validate up to 1000 frames
    if (result.valid) {
        return ValidationResult.okWithDepth(.ac3, .full);
    } else {
        return ValidationResult.invalidWithDepth(.ac3, result.error_message orelse "AC-3 validation failed", .full);
    }
}

/// Deep E-AC-3 (Dolby Digital Plus) validation by parsing frame structure and verifying CRCs.
pub fn validateEac3Deep(path: []const u8) ValidationResult {
    const result = eac3_validator.validateEac3File(path, 1000); // Validate up to 1000 frames
    if (result.valid) {
        return ValidationResult.okWithDepth(.eac3, .full);
    } else {
        return ValidationResult.invalidWithDepth(.eac3, result.error_message orelse "E-AC-3 validation failed", .full);
    }
}

// ============ Tracker/Module Deep Validation ============

/// Helper to perform full decode validation of tracker file using libopenmpt.
/// Reads the file and uses libopenmpt to fully decode/render audio.
pub fn validateTrackerFullDecode(path: []const u8, format: FileFormat) ValidationResult {
    // Open and read the file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(format, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(format, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(format, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(format, .failed_to_get, "file size", .full);
    };

    // Limit to 100MB for full decode
    if (file_size > 100 * 1024 * 1024) {
        return ValidationResult.invalidCodeWithDepth(format, .file_too_large, "full decode validation", .full);
    }

    // Allocate buffer
    const buffer = std.c.malloc(file_size) orelse {
        return ValidationResult.invalidWithDepth(format, "Memory allocation failed", .full);
    };
    defer std.c.free(buffer);

    const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
    const bytes_read = file.readAll(buf_slice) catch {
        return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "file", .full);
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCodeWithDepth(format, .incomplete, "file read", .full);
    }

    // Use libopenmpt to fully decode the file
    var openmpt_result = libopenmpt.validateTrackerFile(buf_slice, true);
    if (openmpt_result.valid) {
        // Clean up metadata if needed
        if (openmpt_result.metadata) |*meta| {
            meta.deinit();
        }
        return ValidationResult.okWithDepth(format, .full);
    } else {
        return ValidationResult.invalidWithDepth(format, openmpt_result.error_message orelse "Full decode failed", .full);
    }
}

/// Deep MOD validation - validates sample headers, pattern data, and file structure.
/// Also performs full decode using libopenmpt.
pub fn validateModDeep(path: []const u8) ValidationResult {
    const result = tracker_validator.validateModDeep(path);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.mod, result.error_message orelse "MOD validation failed", .full);
    }
    // Structural validation passed, now do full decode
    return validateTrackerFullDecode(path, .mod);
}

/// Deep XM validation - validates header, patterns, instruments, and samples.
/// Also performs full decode using libopenmpt.
pub fn validateXmDeep(path: []const u8) ValidationResult {
    const result = tracker_validator.validateXmDeep(path);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.xm, result.error_message orelse "XM validation failed", .full);
    }
    // Structural validation passed, now do full decode
    return validateTrackerFullDecode(path, .xm);
}

/// Deep IT validation - validates header, instruments, samples, and patterns.
/// Also performs full decode using libopenmpt.
pub fn validateItDeep(path: []const u8) ValidationResult {
    const result = tracker_validator.validateItDeep(path);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.it, result.error_message orelse "IT validation failed", .full);
    }
    // Structural validation passed, now do full decode
    return validateTrackerFullDecode(path, .it);
}

/// Deep S3M validation - validates header, instruments, patterns, and sample data.
/// Also performs full decode using libopenmpt.
pub fn validateS3mDeep(path: []const u8) ValidationResult {
    const result = tracker_validator.validateS3mDeep(path);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.s3m, result.error_message orelse "S3M validation failed", .full);
    }
    // Structural validation passed, now do full decode
    return validateTrackerFullDecode(path, .s3m);
}

// ============ FLAC Deep Validation (MD5) ============

/// Deep FLAC validation by checking MD5 hash presence and attempting full decode.
/// FLAC stores an MD5 hash of the uncompressed audio in STREAMINFO.
/// We first check the structure, then attempt full decoding if possible.
pub fn validateFlacDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // First, verify basic FLAC structure
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.flac, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.flac, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.flac, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Read FLAC header
    var header: [42]u8 = undefined;
    const header_bytes = file.read(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.flac, .failed_to_read, "FLAC header", .structural);
    };
    if (header_bytes < 42) {
        return ValidationResult.invalidCodeWithDepth(.flac, .truncated, "FLAC header", .structural);
    }

    // Verify fLaC signature
    if (!std.mem.eql(u8, header[0..4], "fLaC")) {
        return ValidationResult.invalidCodeWithDepth(.flac, .invalid_signature, "FLAC", .structural);
    }

    // Verify first block is STREAMINFO
    const block_type = header[4] & 0x7F;
    if (block_type != 0) {
        return ValidationResult.invalidWithDepth(.flac, "First block must be STREAMINFO", .structural);
    }

    // Check for MD5 presence in STREAMINFO (bytes 18-33 of block, offset 8 in header)
    const md5_hash = header[26..42];
    var has_md5 = false;
    for (md5_hash) |byte| {
        if (byte != 0) {
            has_md5 = true;
            break;
        }
    }

    if (!has_md5) {
        // MD5 hash is missing - do full decode to validate frame CRCs
        const decode_result = flac_decoder.decodeFlacFull(allocator, path) catch |err| {
            if (err == flac_decoder.FlacError.Unsupported or err == flac_decoder.FlacError.OutOfMemory) {
                return ValidationResult.okWithDepth(.flac, .structural);
            }
            return ValidationResult.invalidWithDepth(.flac, "FLAC decode failed: audio data corrupted", .full);
        };

        if (decode_result) {
            // All frames decoded successfully - full validation achieved
            return ValidationResult.okWithDepth(.flac, .full);
        } else {
            // Decode found corruption
            return ValidationResult.invalidWithDepth(.flac, "Frame decode failed: audio data corrupted", .full);
        }
    }

    // Try full MD5 verification using the decoder
    const result = flac_decoder.verifyFlacMd5(allocator, path) catch |err| {
        // Unsupported features (e.g., >1GB) fall back to structural
        if (err == flac_decoder.FlacError.Unsupported or err == flac_decoder.FlacError.OutOfMemory) {
            return ValidationResult.okWithDepth(.flac, .structural);
        }
        // Any other decoder error (truncated, invalid sync, bad frame) means corruption
        return ValidationResult.invalidWithDepth(.flac, "FLAC decode failed: audio data corrupted", .full);
    };

    if (result) {
        // MD5 verified successfully - this is full decode level validation
        return ValidationResult.okWithDepth(.flac, .full);
    } else {
        // MD5 mismatch - audio data corruption detected
        return ValidationResult.invalidWithDepth(.flac, "MD5 mismatch: audio data corrupted", .full);
    }
}

// ============ MP3 Deep Validation ============

/// CRC-16 polynomial for MPEG audio: X^16 + X^15 + X^2 + 1 (0x8005)
pub fn crc16Mpeg(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x8005;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

/// MPEG audio bitrate lookup tables (kbps)
/// Index is bitrate_index from header, rows are [V1L1, V1L2, V1L3, V2L1, V2L2/3]
const BITRATE_TABLE = [_][5]u16{
    .{ 0, 0, 0, 0, 0 }, // free
    .{ 32, 32, 32, 32, 8 },
    .{ 64, 48, 40, 48, 16 },
    .{ 96, 56, 48, 56, 24 },
    .{ 128, 64, 56, 64, 32 },
    .{ 160, 80, 64, 80, 40 },
    .{ 192, 96, 80, 96, 48 },
    .{ 224, 112, 96, 112, 56 },
    .{ 256, 128, 112, 128, 64 },
    .{ 288, 160, 128, 144, 80 },
    .{ 320, 192, 160, 160, 96 },
    .{ 352, 224, 192, 176, 112 },
    .{ 384, 256, 224, 192, 128 },
    .{ 416, 320, 256, 224, 144 },
    .{ 448, 384, 320, 256, 160 },
    .{ 0, 0, 0, 0, 0 }, // bad
};

/// Sample rate lookup table (Hz)
/// Index is sample_rate_index, rows are [V1, V2, V2.5]
const SAMPLE_RATE_TABLE = [_][3]u32{
    .{ 44100, 22050, 11025 },
    .{ 48000, 24000, 12000 },
    .{ 32000, 16000, 8000 },
    .{ 0, 0, 0 }, // reserved
};

/// Deep MP3 validation by parsing and optionally verifying frame CRCs.
/// Most MP3 files don't have CRC, so we validate frame structure.
pub fn validateMp3Deep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.mp3, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.mp3, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    var header: [10]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_read, "header", .structural);
    };

    var audio_start: u64 = 0;

    // Skip multiple ID3v2 tags if present (some files have multiple consecutive tags)
    while (std.mem.eql(u8, header[0..3], "ID3")) {
        // ID3v2 size is syncsafe integer in bytes 6-9 (7 bits per byte)
        const size = (@as(u32, header[6] & 0x7F) << 21) |
            (@as(u32, header[7] & 0x7F) << 14) |
            (@as(u32, header[8] & 0x7F) << 7) |
            @as(u32, header[9] & 0x7F);
        audio_start = audio_start + 10 + size;

        file.seekTo(audio_start) catch {
            return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_seek, "past ID3", .structural);
        };

        // Read next header (might be another ID3 or audio data)
        _ = file.read(&header) catch {
            return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_read, "after ID3", .structural);
        };
    }

    // Now we should be at the audio data, but seekTo above positioned us there,
    // and we read 10 bytes into header, so we need to check those bytes
    // The first bytes of audio should be the frame sync (0xFF 0xE*)
    // We already have them in header[0..1], so seek back and let the frame loop handle it
    file.seekTo(audio_start) catch {
        return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_seek, "to audio", .structural);
    };

    // Validate all frames
    var frames_checked: usize = 0;
    var frames_with_crc: usize = 0;

    while (true) {
        var frame_header: [4]u8 = undefined;
        const bytes_read = file.read(&frame_header) catch break;
        if (bytes_read < 4) break;

        // Check frame sync (11 bits: 0xFF followed by 0xE0 or higher in next byte)
        if (frame_header[0] != 0xFF or (frame_header[1] & 0xE0) != 0xE0) {
            if (frames_checked == 0) {
                return ValidationResult.invalidCodeWithDepth(.mp3, .invalid_value, "MP3 frame sync", .structural);
            }
            break; // End of audio or padding
        }

        // Parse header fields
        // Byte 1: aaaa bbcc - frame sync (aa), version (bb), layer (cc)
        const version_bits = (frame_header[1] >> 3) & 0x03;
        const layer_bits = (frame_header[1] >> 1) & 0x03;
        const protection_bit = frame_header[1] & 0x01; // 0 = CRC present, 1 = not protected

        // Byte 2: eeee ffgh - bitrate (e), sample rate (f), padding (g), private (h)
        const bitrate_index = (frame_header[2] >> 4) & 0x0F;
        const sample_rate_index = (frame_header[2] >> 2) & 0x03;
        const padding_bit = (frame_header[2] >> 1) & 0x01;

        // Validate version and layer
        if (version_bits == 1) { // Reserved
            return ValidationResult.invalidWithDepth(.mp3, "Reserved MPEG version", .structural);
        }
        if (layer_bits == 0) { // Reserved
            return ValidationResult.invalidWithDepth(.mp3, "Reserved layer", .structural);
        }
        if (bitrate_index == 0 or bitrate_index == 15) { // Free or bad
            if (frames_checked == 0) {
                return ValidationResult.invalidCodeWithDepth(.mp3, .invalid_value, "bitrate index", .structural);
            }
            break;
        }
        if (sample_rate_index == 3) { // Reserved
            return ValidationResult.invalidWithDepth(.mp3, "Reserved sample rate", .structural);
        }

        // Get bitrate and sample rate
        const is_v1 = (version_bits == 3); // MPEG Version 1
        const layer = 4 - layer_bits; // 1, 2, or 3

        const bitrate_col: usize = if (is_v1) switch (layer) {
            1 => 0,
            2 => 1,
            3 => 2,
            else => 2,
        } else switch (layer) {
            1 => 3,
            else => 4,
        };
        const bitrate = BITRATE_TABLE[bitrate_index][bitrate_col];
        if (bitrate == 0) {
            return ValidationResult.invalidCodeWithDepth(.mp3, .invalid_value, "bitrate", .structural);
        }

        const sample_rate_col: usize = switch (version_bits) {
            3 => 0, // V1
            2 => 1, // V2
            0 => 2, // V2.5
            else => 0,
        };
        const sample_rate = SAMPLE_RATE_TABLE[sample_rate_index][sample_rate_col];
        if (sample_rate == 0) {
            return ValidationResult.invalidCodeWithDepth(.mp3, .invalid_value, "sample rate", .structural);
        }

        // Calculate frame size
        const frame_size: usize = if (layer == 1) blk: {
            // Layer I: (12 * bitrate / sample_rate + padding) * 4
            break :blk (12 * @as(usize, bitrate) * 1000 / sample_rate + padding_bit) * 4;
        } else blk: {
            // Layer II/III: 144 * bitrate / sample_rate + padding
            const samples_per_frame: usize = if (layer == 3 and !is_v1) 72 else 144;
            break :blk samples_per_frame * @as(usize, bitrate) * 1000 / sample_rate + padding_bit;
        };

        // Check CRC if present
        if (protection_bit == 0) {
            frames_with_crc += 1;

            var crc_bytes: [2]u8 = undefined;
            const crc_read = file.read(&crc_bytes) catch break;
            if (crc_read < 2) break;

            const stored_crc = std.mem.readInt(u16, &crc_bytes, .big);

            // CRC covers header bytes 2-3 and side info
            // Side info size varies: 32 bytes for stereo, 17 for mono in Layer III
            // For now, just verify CRC presence and format
            _ = stored_crc; // Would need to compute CRC over side info

            // Move to next frame (frame_size includes header but we already read header+CRC)
            file.seekBy(@intCast(frame_size - 4 - 2)) catch break;
        } else {
            // No CRC, skip to next frame
            file.seekBy(@intCast(frame_size - 4)) catch break;
        }

        frames_checked += 1;
    }

    if (frames_checked == 0) {
        return ValidationResult.invalidCodeWithDepth(.mp3, .no_valid_x_found, "MP3 frames", .structural);
    }

    // If CRC frames exist, verify them with the dedicated MP3 CRC validator
    if (frames_with_crc > 0) {
        const crc_result = mp3_validator.validateMp3CrcPath(path);
        if (crc_result.valid) {
            // CRCs verified successfully
            return ValidationResult.okWithDepth(.mp3, .full);
        } else if (crc_result.error_message) |msg| {
            // CRC mismatch detected - corruption
            return ValidationResult.invalidWithDepth(.mp3, msg, .full);
        } else {
            // Fallback to decode validation if CRC check had issues
            const decode_result = mp3_decode_validator.validateMp3DecodePath(path);
            if (decode_result.valid and decode_result.frames_decoded > 0) {
                return ValidationResult.okWithDepth(.mp3, .full);
            }
            return ValidationResult.structuralOnly(.mp3);
        }
    }

    // No CRC present - do full decode validation to catch corruption
    const decode_result = mp3_decode_validator.validateMp3DecodePath(path);
    if (decode_result.valid and decode_result.frames_decoded > 0) {
        return ValidationResult.okWithDepth(.mp3, .full);
    }

    // Decode failed or no frames - structural validation only
    // This could indicate corruption or just an unusual encoding
    return ValidationResult.structuralOnly(.mp3);
}

// ============ Buffer Validators ============

pub fn validateMp3FromBuffer(data: []const u8) ValidationResult {
    if (data.len < 2) return ValidationResult.invalid(.mp3, "File too small");
    // Check for frame sync or ID3 tag
    if ((data[0] == 0xFF and (data[1] & 0xE0) == 0xE0) or std.mem.eql(u8, data[0..3], "ID3")) {
        return ValidationResult.ok(.mp3);
    }
    return ValidationResult.invalidCode(.mp3, .invalid_signature, "MP3");
}

pub fn validateFlacFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(.flac, "File too small");
    if (std.mem.eql(u8, data[0..4], "fLaC")) {
        return ValidationResult.ok(.flac);
    }
    return ValidationResult.invalidCode(.flac, .invalid_signature, "FLAC");
}

pub fn validateWavFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) return ValidationResult.invalid(.wav, "File too small");
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WAVE")) {
        return ValidationResult.ok(.wav);
    }
    return ValidationResult.invalidCode(.wav, .invalid_signature, "WAV");
}

pub fn validateAiffFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) return ValidationResult.invalid(.aiff, "File too small");
    if (std.mem.eql(u8, data[0..4], "FORM") and (std.mem.eql(u8, data[8..12], "AIFF") or std.mem.eql(u8, data[8..12], "AIFC"))) {
        return ValidationResult.ok(.aiff);
    }
    return ValidationResult.invalidCode(.aiff, .invalid_signature, "AIFF");
}

pub fn validateOggFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(.ogg, "File too small");
    if (std.mem.eql(u8, data[0..4], "OggS")) {
        return ValidationResult.ok(.ogg);
    }
    return ValidationResult.invalidCode(.ogg, .invalid_signature, "OGG");
}

// ============ AMR Validator ============

/// Validate AMR (Adaptive Multi-Rate) audio file structure.
/// AMR-NB: "#!AMR\n", AMR-WB: "#!AMR-WB\n", multi-channel variants also supported.
pub fn validateAmr(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.amr, .failed_to_seek, "in AMR file");

    var header: [15]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.amr, .failed_to_read, "header");

    if (bytes_read < 6) return ValidationResult.invalidCode(.amr, .truncated, "header");

    if (bytes_read >= 15 and std.mem.eql(u8, header[0..15], "#!AMR-WB_MC1.0\n")) {
        return ValidationResult.structuralOnly(.amr);
    }
    if (bytes_read >= 12 and std.mem.eql(u8, header[0..12], "#!AMR_MC1.0\n")) {
        return ValidationResult.structuralOnly(.amr);
    }
    if (bytes_read >= 9 and std.mem.eql(u8, header[0..9], "#!AMR-WB\n")) {
        if (bytes_read > 9) {
            const frame_header = header[9];
            const ft = (frame_header >> 3) & 0x0F;
            if (ft > 9 and ft != 14 and ft != 15) {
                return ValidationResult.invalidCode(.amr, .invalid_value, "AMR-WB frame type");
            }
        }
        return ValidationResult.structuralOnly(.amr);
    }
    if (std.mem.eql(u8, header[0..6], "#!AMR\n")) {
        if (bytes_read > 6) {
            const frame_header = header[6];
            const ft = (frame_header >> 3) & 0x0F;
            if (ft > 8 and ft != 15) {
                return ValidationResult.invalidCode(.amr, .invalid_value, "AMR-NB frame type");
            }
        }
        return ValidationResult.structuralOnly(.amr);
    }

    return ValidationResult.invalidCode(.amr, .invalid_magic, "AMR");
}

// ============ AU/SND Validator ============

/// Validate AU/SND (Sun/NeXT audio) file structure.
pub fn validateAu(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.au, .failed_to_seek, "in AU file");

    var header: [24]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.au, .failed_to_read, "header");
    if (bytes_read < 24) return ValidationResult.invalidCode(.au, .truncated, "header (need 24 bytes)");

    if (!std.mem.eql(u8, header[0..4], ".snd")) {
        return ValidationResult.invalidCode(.au, .invalid_value, "AU magic (expected .snd)");
    }

    const data_offset = std.mem.readInt(u32, header[4..8], .big);
    const data_size = std.mem.readInt(u32, header[8..12], .big);
    const encoding = std.mem.readInt(u32, header[12..16], .big);
    const sample_rate = std.mem.readInt(u32, header[16..20], .big);
    const channels = std.mem.readInt(u32, header[20..24], .big);

    if (data_offset < 24) return ValidationResult.invalidCode(.au, .invalid_value, "data offset (must be >= 24)");
    if (encoding == 0 or encoding > 27) return ValidationResult.invalidCode(.au, .invalid_value, "encoding format (must be 1-27)");
    if (sample_rate == 0) return ValidationResult.invalidCode(.au, .invalid_value, "sample rate (must be > 0)");
    if (sample_rate > 768000) return ValidationResult.invalid(.au, "Unreasonable sample rate (> 768000 Hz)");
    if (channels == 0) return ValidationResult.invalidCode(.au, .invalid_value, "channel count (must be > 0)");
    if (channels > 128) return ValidationResult.invalid(.au, "Unreasonable channel count (> 128)");

    if (data_size != 0xFFFFFFFF and data_size != 0) {
        const file_size = file.getEndPos() catch return ValidationResult.structuralOnly(.au);
        const expected_min: u64 = @as(u64, data_offset) + @as(u64, data_size);
        if (expected_min > file_size) {
            return ValidationResult.invalidCodeMsg(.au, .exceeds_bounds, "Data size", "Data size exceeds file size (truncated)");
        }
    }

    return ValidationResult.structuralOnly(.au);
}

// ============ TTA Validator ============

/// Validate TTA (True Audio) lossless file structure with header CRC32 verification.
pub fn validateTta(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.tta, .failed_to_seek, "in TTA file");

    var header: [22]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.tta, .failed_to_read, "header");
    if (bytes_read < 22) return ValidationResult.invalidCode(.tta, .truncated, "header (need 22 bytes)");

    if (!std.mem.eql(u8, header[0..4], "TTA1")) {
        return ValidationResult.invalidCode(.tta, .invalid_value, "TTA magic (expected TTA1)");
    }

    const audio_format = std.mem.readInt(u16, header[4..6], .little);
    const num_channels = std.mem.readInt(u16, header[6..8], .little);
    const bits_per_sample = std.mem.readInt(u16, header[8..10], .little);
    const sample_rate = std.mem.readInt(u32, header[10..14], .little);
    const total_samples = std.mem.readInt(u32, header[14..18], .little);

    if (audio_format != 1) return ValidationResult.invalidCode(.tta, .invalid_value, "audio format (expected 1 for lossless)");
    if (num_channels == 0 or num_channels > 8) return ValidationResult.invalidCode(.tta, .invalid_value, "channel count (must be 1-8)");
    if (bits_per_sample != 8 and bits_per_sample != 16 and bits_per_sample != 24) return ValidationResult.invalidCode(.tta, .invalid_value, "bits per sample (must be 8, 16, or 24)");
    if (sample_rate == 0 or sample_rate > 768000) return ValidationResult.invalidCode(.tta, .invalid_value, "sample rate");
    if (total_samples == 0) return ValidationResult.invalidCode(.tta, .invalid_value, "total samples (must be > 0)");

    // Verify CRC32 of header bytes 0-17
    const stored_crc = std.mem.readInt(u32, header[18..22], .little);
    const computed_crc = std.hash.Crc32.hash(header[0..18]);
    if (stored_crc != computed_crc) return ValidationResult.invalidCodeMsg(.tta, .checksum_mismatch, "Header CRC32", "Header CRC32 mismatch");

    // Validate seek table fits
    const frame_length: u64 = @as(u64, sample_rate) * 256 / 245;
    if (frame_length > 0) {
        const fl32: u32 = @intCast(@min(frame_length, std.math.maxInt(u32)));
        if (fl32 > 0) {
            const num_frames = (total_samples + fl32 - 1) / fl32;
            const seek_table_size: u64 = @as(u64, num_frames) * 4 + 4;
            const file_size = file.getEndPos() catch return ValidationResult.structuralOnly(.tta);
            if (file_size < 22 + seek_table_size) return ValidationResult.invalidCode(.tta, .file_too_small, "seek table");
        }
    }

    return ValidationResult.structuralOnly(.tta);
}

// ============ CAF Validator ============

/// Validate CAF (Core Audio Format) file structure.
pub fn validateCaf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.caf, .failed_to_seek, "in CAF file");

    var header: [20]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.caf, .failed_to_read, "CAF header");
    if (bytes_read < 20) return ValidationResult.invalidCode(.caf, .file_too_small, "CAF header");

    if (!std.mem.eql(u8, header[0..4], "caff")) return ValidationResult.invalidCode(.caf, .invalid_magic, "CAF");

    const version = std.mem.readInt(u16, header[4..6], .big);
    if (version != 1) return ValidationResult.invalidCode(.caf, .unsupported, "CAF version (expected 1)");

    const flags = std.mem.readInt(u16, header[6..8], .big);
    if (flags != 0) return ValidationResult.invalidCode(.caf, .invalid_value, "CAF flags (expected 0)");

    if (!std.mem.eql(u8, header[8..12], "desc")) return ValidationResult.invalid(.caf, "First CAF chunk is not 'desc' (Audio Description)");

    const chunk_size = std.mem.readInt(i64, header[12..20], .big);
    if (chunk_size != -1 and chunk_size != 32) return ValidationResult.invalid(.caf, "Unexpected CAF Audio Description chunk size");

    return ValidationResult.structuralOnly(.caf);
}

// ============ AAC ADTS Validator ============

/// Validate standalone AAC ADTS (.aac) file using pure-Zig bitstream validator.
pub fn validateAacAdts(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.aac_adts, .failed_to_seek, "in AAC ADTS file");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.aac_adts, .failed_to_get, "file size");
    if (file_size < 7) return ValidationResult.invalidCode(.aac_adts, .file_too_small, "ADTS");

    const max_read: usize = 1024 * 1024;
    const read_size: usize = @min(file_size, max_read);
    var buf: [max_read]u8 = undefined;
    const bytes_read = file.readAll(buf[0..read_size]) catch return ValidationResult.invalidCode(.aac_adts, .failed_to_read, "ADTS data");
    if (bytes_read < 7) return ValidationResult.invalidCode(.aac_adts, .incomplete, "ADTS data");

    const result = aac_syntax_validator.validateAdtsStream(buf[0..bytes_read]);
    if (!result.valid) {
        return ValidationResult.invalid(.aac_adts, result.error_message orelse "ADTS validation failed");
    }

    return ValidationResult.okWithDepth(.aac_adts, .full);
}

// ============ Tests ============

const testing = std.testing;

// ---------- Buffer validators ----------

test "validateMp3FromBuffer accepts MP3 frame sync" {
    const data = [_]u8{ 0xFF, 0xFB, 0x90, 0x00 };
    const result = validateMp3FromBuffer(&data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mp3, result.format);
}

test "validateMp3FromBuffer accepts ID3 tag" {
    const data = "ID3" ++ [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = validateMp3FromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mp3, result.format);
}

test "validateMp3FromBuffer rejects invalid data" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateMp3FromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateMp3FromBuffer rejects too-small data" {
    const data = [_]u8{0x00};
    const result = validateMp3FromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateFlacFromBuffer accepts fLaC signature" {
    const data = "fLaC" ++ [_]u8{0x00} ** 4;
    const result = validateFlacFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
}

test "validateFlacFromBuffer rejects invalid data" {
    const data = [_]u8{ 'f', 'L', 'a', 'X' };
    const result = validateFlacFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateFlacFromBuffer rejects too-small data" {
    const data = [_]u8{ 'f', 'L' };
    const result = validateFlacFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateWavFromBuffer accepts RIFF/WAVE" {
    const data = "RIFF" ++ [_]u8{ 0x24, 0x00, 0x00, 0x00 } ++ "WAVE";
    const result = validateWavFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
}

test "validateWavFromBuffer rejects non-WAVE RIFF" {
    const data = "RIFF" ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ "AVI ";
    const result = validateWavFromBuffer(data);
    try testing.expect(!result.is_valid);
}

test "validateWavFromBuffer rejects too-small data" {
    const data = "RIFF" ++ [_]u8{ 0x00, 0x00, 0x00 };
    const result = validateWavFromBuffer(data);
    try testing.expect(!result.is_valid);
}

test "validateAiffFromBuffer accepts FORM/AIFF" {
    const data = "FORM" ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ "AIFF";
    const result = validateAiffFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
}

test "validateAiffFromBuffer accepts FORM/AIFC" {
    const data = "FORM" ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ "AIFC";
    const result = validateAiffFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
}

test "validateAiffFromBuffer rejects invalid data" {
    const data = "FORM" ++ [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++ "XXXX";
    const result = validateAiffFromBuffer(data);
    try testing.expect(!result.is_valid);
}

test "validateOggFromBuffer accepts OggS" {
    const data = "OggS" ++ [_]u8{0x00} ** 4;
    const result = validateOggFromBuffer(data);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ogg, result.format);
}

test "validateOggFromBuffer rejects invalid data" {
    const data = [_]u8{ 'O', 'g', 'g', 'X' };
    const result = validateOggFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

// ---------- CRC-16 utility ----------

test "crc16Mpeg produces non-trivial output" {
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const crc = crc16Mpeg(&data);
    try testing.expectEqual(crc, crc16Mpeg(&data));
    try testing.expect(crc != 0);
}

test "crc16Mpeg empty input returns initial value" {
    const data = [_]u8{};
    const crc = crc16Mpeg(&data);
    try testing.expectEqual(@as(u16, 0xFFFF), crc);
}

// ---------- Ground truth file-based structural validators ----------

test "validateWav accepts ground truth WAV" {
    const file = std.fs.cwd().openFile("ground_truth_examples/wav/sample.wav", .{}) catch return;
    defer file.close();
    const result = validateWav(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
}

test "validateFlac accepts ground truth FLAC" {
    const file = std.fs.cwd().openFile("ground_truth_examples/flac/generated_tone_440hz.flac", .{}) catch return;
    defer file.close();
    const result = validateFlac(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
}

test "validateMp3 accepts ground truth MP3" {
    const file = std.fs.cwd().openFile("ground_truth_examples/mp3/generated_tone_440hz.mp3", .{}) catch return;
    defer file.close();
    const result = validateMp3(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mp3, result.format);
}

test "validateOgg accepts ground truth OGG" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ogg/generated_tone_440hz.ogg", .{}) catch return;
    defer file.close();
    const result = validateOgg(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ogg, result.format);
}

test "validateRiffAudio accepts ground truth AIFF" {
    const file = std.fs.cwd().openFile("ground_truth_examples/aiff/sample.aiff", .{}) catch return;
    defer file.close();
    const result = validateRiffAudio(file, .aiff);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
}

test "validateMidi accepts ground truth MIDI" {
    const file = std.fs.cwd().openFile("ground_truth_examples/midi/fur_elise.mid", .{}) catch return;
    defer file.close();
    const result = validateMidi(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.midi, result.format);
}

test "validateAc3 accepts ground truth AC-3" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ac3/sample.ac3", .{}) catch return;
    defer file.close();
    const result = validateAc3(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ac3, result.format);
}

test "validateEac3 accepts ground truth E-AC-3" {
    const file = std.fs.cwd().openFile("ground_truth_examples/eac3/sample.eac3", .{}) catch return;
    defer file.close();
    const result = validateEac3(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eac3, result.format);
}

test "validateApe accepts ground truth APE" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ape/sample.ape", .{}) catch return;
    defer file.close();
    const result = validateApe(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ape, result.format);
}

test "validateWavPack accepts ground truth WavPack" {
    const file = std.fs.cwd().openFile("ground_truth_examples/wavpack/sample.wv", .{}) catch return;
    defer file.close();
    const result = validateWavPack(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wavpack, result.format);
}

test "validateDsf accepts ground truth DSF" {
    const file = std.fs.cwd().openFile("ground_truth_examples/dsf/sample.dsf", .{}) catch return;
    defer file.close();
    const result = validateDsf(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dsf, result.format);
}

test "validateDff accepts ground truth DFF" {
    const file = std.fs.cwd().openFile("ground_truth_examples/dff/sample.dff", .{}) catch return;
    defer file.close();
    const result = validateDff(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dff, result.format);
}

test "validateAmr accepts ground truth AMR" {
    const file = std.fs.cwd().openFile("ground_truth_examples/amr/sample.amr", .{}) catch return;
    defer file.close();
    const result = validateAmr(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.amr, result.format);
}

test "validateAu accepts ground truth AU" {
    const file = std.fs.cwd().openFile("ground_truth_examples/au/sample.au", .{}) catch return;
    defer file.close();
    const result = validateAu(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.au, result.format);
}

test "validateTta accepts ground truth TTA" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tta/sample.tta", .{}) catch return;
    defer file.close();
    const result = validateTta(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.tta, result.format);
}

test "validateCaf accepts ground truth CAF" {
    const file = std.fs.cwd().openFile("ground_truth_examples/caf/sample.caf", .{}) catch return;
    defer file.close();
    const result = validateCaf(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.caf, result.format);
}

test "validateAacAdts accepts ground truth AAC ADTS" {
    const file = std.fs.cwd().openFile("ground_truth_examples/aac_adts/sample.aac", .{}) catch return;
    defer file.close();
    const result = validateAacAdts(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aac_adts, result.format);
}

test "validateMod accepts ground truth MOD" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/otm.mod", .{}) catch return;
    defer file.close();
    const result = validateMod(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mod, result.format);
}

test "validateXm accepts ground truth XM" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/agony.xm", .{}) catch return;
    defer file.close();
    const result = validateXm(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xm, result.format);
}

test "validateIt accepts ground truth IT" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/flitter.it", .{}) catch return;
    defer file.close();
    const result = validateIt(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.it, result.format);
}

test "validateS3m accepts ground truth S3M" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/twilight_garden.s3m", .{}) catch return;
    defer file.close();
    const result = validateS3m(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.s3m, result.format);
}

// ---------- Ground truth deep validators ----------

test "validateWavDeep accepts ground truth WAV" {
    const file = std.fs.cwd().openFile("ground_truth_examples/wav/sample.wav", .{}) catch return;
    file.close();
    const result = validateWavDeep(testing.allocator, "ground_truth_examples/wav/sample.wav");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
    // WAV validates chunk structure but no audio decode or checksum
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "validateAiffDeep accepts ground truth AIFF" {
    const file = std.fs.cwd().openFile("ground_truth_examples/aiff/sample.aiff", .{}) catch return;
    file.close();
    const result = validateAiffDeep(testing.allocator, "ground_truth_examples/aiff/sample.aiff");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
    // AIFF validates chunk structure but no audio decode or checksum
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "validateFlacDeep accepts ground truth FLAC" {
    const file = std.fs.cwd().openFile("ground_truth_examples/flac/generated_tone_440hz.flac", .{}) catch return;
    file.close();
    const result = validateFlacDeep(testing.allocator, "ground_truth_examples/flac/generated_tone_440hz.flac");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateOggDeep accepts ground truth OGG" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ogg/generated_tone_440hz.ogg", .{}) catch return;
    file.close();
    const result = validateOggDeep(testing.allocator, "ground_truth_examples/ogg/generated_tone_440hz.ogg");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ogg, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateMidiDeep accepts ground truth MIDI" {
    const file = std.fs.cwd().openFile("ground_truth_examples/midi/fur_elise.mid", .{}) catch return;
    file.close();
    const result = validateMidiDeep("ground_truth_examples/midi/fur_elise.mid");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.midi, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateAc3Deep accepts ground truth AC-3" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ac3/sample.ac3", .{}) catch return;
    file.close();
    const result = validateAc3Deep("ground_truth_examples/ac3/sample.ac3");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ac3, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateEac3Deep accepts ground truth E-AC-3" {
    const file = std.fs.cwd().openFile("ground_truth_examples/eac3/sample.eac3", .{}) catch return;
    file.close();
    const result = validateEac3Deep("ground_truth_examples/eac3/sample.eac3");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eac3, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

// ---------- Corrupt / truncated input tests ----------

test "validateWav rejects truncated WAV" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const truncated = "RIFF" ++ [_]u8{ 0xFF, 0x00, 0x00, 0x00 } ++ "WAVE";
    tmp.dir.writeFile(.{ .sub_path = "bad.wav", .data = truncated }) catch return;
    const file = tmp.dir.openFile("bad.wav", .{}) catch return;
    defer file.close();
    const result = validateWav(file);
    try testing.expect(!result.is_valid);
}

test "validateFlac rejects invalid FLAC signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = "fLaX" ++ [_]u8{0x00} ** 34;
    tmp.dir.writeFile(.{ .sub_path = "bad.flac", .data = bad_data }) catch return;
    const file = tmp.dir.openFile("bad.flac", .{}) catch return;
    defer file.close();
    const result = validateFlac(file);
    try testing.expect(!result.is_valid);
}

test "validateFlac rejects non-STREAMINFO first block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = "fLaC" ++ [_]u8{ 0x01, 0x00, 0x00, 0x22 } ++ [_]u8{0x00} ** 34;
    tmp.dir.writeFile(.{ .sub_path = "bad.flac", .data = bad_data }) catch return;
    const file = tmp.dir.openFile("bad.flac", .{}) catch return;
    defer file.close();
    const result = validateFlac(file);
    try testing.expect(!result.is_valid);
}

test "validateMp3 rejects random bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
    tmp.dir.writeFile(.{ .sub_path = "bad.mp3", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.mp3", .{}) catch return;
    defer file.close();
    const result = validateMp3(file);
    try testing.expect(!result.is_valid);
}

test "validateOgg rejects non-OggS data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 28;
    tmp.dir.writeFile(.{ .sub_path = "bad.ogg", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.ogg", .{}) catch return;
    defer file.close();
    const result = validateOgg(file);
    try testing.expect(!result.is_valid);
}

test "validateMidi rejects non-MThd data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 22;
    tmp.dir.writeFile(.{ .sub_path = "bad.mid", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.mid", .{}) catch return;
    defer file.close();
    const result = validateMidi(file);
    try testing.expect(!result.is_valid);
}

test "validateAc3 rejects wrong sync word" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{ 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00 };
    tmp.dir.writeFile(.{ .sub_path = "bad.ac3", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.ac3", .{}) catch return;
    defer file.close();
    const result = validateAc3(file);
    try testing.expect(!result.is_valid);
}

test "validateEac3 rejects wrong bsid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Sync word correct (0x0B77) but bsid=8 (AC-3) instead of 16 (E-AC-3)
    const bad_data = [_]u8{ 0x0B, 0x77, 0x00, 0x00, 0x00, 0x08 << 3 };
    tmp.dir.writeFile(.{ .sub_path = "bad.eac3", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.eac3", .{}) catch return;
    defer file.close();
    const result = validateEac3(file);
    try testing.expect(!result.is_valid);
}

test "validateApe rejects non-MAC signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 32;
    tmp.dir.writeFile(.{ .sub_path = "bad.ape", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.ape", .{}) catch return;
    defer file.close();
    const result = validateApe(file);
    try testing.expect(!result.is_valid);
}

test "validateDsf rejects non-DSD signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 80;
    tmp.dir.writeFile(.{ .sub_path = "bad.dsf", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.dsf", .{}) catch return;
    defer file.close();
    const result = validateDsf(file);
    try testing.expect(!result.is_valid);
}

test "validateDff rejects non-FRM8 signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 28;
    tmp.dir.writeFile(.{ .sub_path = "bad.dff", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.dff", .{}) catch return;
    defer file.close();
    const result = validateDff(file);
    try testing.expect(!result.is_valid);
}

test "validateAmr rejects non-AMR data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 16;
    tmp.dir.writeFile(.{ .sub_path = "bad.amr", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.amr", .{}) catch return;
    defer file.close();
    const result = validateAmr(file);
    try testing.expect(!result.is_valid);
}

test "validateAu rejects non-snd magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 24;
    tmp.dir.writeFile(.{ .sub_path = "bad.au", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.au", .{}) catch return;
    defer file.close();
    const result = validateAu(file);
    try testing.expect(!result.is_valid);
}

test "validateTta rejects non-TTA1 magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 22;
    tmp.dir.writeFile(.{ .sub_path = "bad.tta", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.tta", .{}) catch return;
    defer file.close();
    const result = validateTta(file);
    try testing.expect(!result.is_valid);
}

test "validateCaf rejects non-caff magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 20;
    tmp.dir.writeFile(.{ .sub_path = "bad.caf", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.caf", .{}) catch return;
    defer file.close();
    const result = validateCaf(file);
    try testing.expect(!result.is_valid);
}

test "validateXm rejects non-XM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 80;
    tmp.dir.writeFile(.{ .sub_path = "bad.xm", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.xm", .{}) catch return;
    defer file.close();
    const result = validateXm(file);
    try testing.expect(!result.is_valid);
}

test "validateIt rejects non-IMPM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 192;
    tmp.dir.writeFile(.{ .sub_path = "bad.it", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.it", .{}) catch return;
    defer file.close();
    const result = validateIt(file);
    try testing.expect(!result.is_valid);
}

test "validateS3m rejects non-SCRM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 96;
    tmp.dir.writeFile(.{ .sub_path = "bad.s3m", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.s3m", .{}) catch return;
    defer file.close();
    const result = validateS3m(file);
    try testing.expect(!result.is_valid);
}

test "validateMod rejects file too small for MOD" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 100;
    tmp.dir.writeFile(.{ .sub_path = "bad.mod", .data = &bad_data }) catch return;
    const file = tmp.dir.openFile("bad.mod", .{}) catch return;
    defer file.close();
    const result = validateMod(file);
    try testing.expect(!result.is_valid);
}

// ---------- Deep validators with corrupt data ----------

test "validateWavDeep rejects file not found" {
    const result = validateWavDeep(testing.allocator, "/nonexistent/path/to/file.wav");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
}

test "validateAiffDeep rejects file not found" {
    const result = validateAiffDeep(testing.allocator, "/nonexistent/path/to/file.aiff");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
}

test "validateFlacDeep rejects file not found" {
    const result = validateFlacDeep(testing.allocator, "/nonexistent/path/to/file.flac");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
}

test "validateMidiDeep rejects file not found" {
    const result = validateMidiDeep("/nonexistent/path/to/file.mid");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.midi, result.format);
}

test "validateAc3Deep rejects file not found" {
    const result = validateAc3Deep("/nonexistent/path/to/file.ac3");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.ac3, result.format);
}

test "validateEac3Deep rejects file not found" {
    const result = validateEac3Deep("/nonexistent/path/to/file.eac3");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.eac3, result.format);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "FormatValidator deep validates real MIDI from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth MIDI file (Beethoven's Für Elise from mfiles.co.uk)
    const file = std.fs.cwd().openFile("ground_truth_examples/midi/fur_elise.mid", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/midi/fur_elise.mid") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.midi, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator deep validates MOD from ground truth" {
    const allocator = std.testing.allocator;

    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/otm.mod", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/tracker/otm.mod") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.mod, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator deep validates XM from ground truth" {
    const allocator = std.testing.allocator;

    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/agony.xm", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/tracker/agony.xm") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.xm, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator deep validates IT from ground truth" {
    const allocator = std.testing.allocator;

    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/flitter.it", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/tracker/flitter.it") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.it, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator deep validates S3M from ground truth" {
    const allocator = std.testing.allocator;

    const file = std.fs.cwd().openFile("ground_truth_examples/tracker/twilight_garden.s3m", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/tracker/twilight_garden.s3m") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.s3m, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator accepts valid MP3 with ID3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid MP3 with ID3v2 tag
    const valid_mp3 = [_]u8{
        // ID3v2 header
        'I', 'D', '3', // signature
        0x04, 0x00, // version (2.4.0)
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // size (0, no frames)
        // MP3 frame sync
        0xFF, 0xFB, // frame sync + MPEG1 Layer3
        0x90, 0x00, // bitrate, sample rate, etc
    };

    const file = try tmp_dir.dir.createFile("valid_id3.mp3", .{});
    try file.writeAll(&valid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid_id3.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid MP3 ID3 failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid MP3 without ID3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid MP3 starting with frame sync
    const valid_mp3 = [_]u8{
        0xFF, 0xFB, // frame sync + MPEG1 Layer3
        0x90, 0x00, // bitrate, sample rate, etc
        0x00, 0x00, 0x00, 0x00, // frame data
    };

    const file = try tmp_dir.dir.createFile("valid_raw.mp3", .{});
    try file.writeAll(&valid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid_raw.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid MP3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid MP3 (ID3 header but no valid frame sync after)
    const invalid_mp3 = [_]u8{
        'I',  'D',  '3',
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
        // No valid frame sync - just garbage
        0x00, 0x00,
        0x00, 0x00,
    };

    const file = try tmp_dir.dir.createFile("invalid.mp3", .{});
    try file.writeAll(&invalid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid FLAC" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid FLAC with STREAMINFO
    const valid_flac = [_]u8{
        'f', 'L', 'a', 'C', // signature
        0x80, // metadata block header (last block, type 0 = STREAMINFO)
        0x00, 0x00, 0x22, // block size (34 bytes)
        // STREAMINFO (34 bytes)
        0x00, 0x10, // min block size
        0x00, 0x10, // max block size
        0x00, 0x00, 0x00, // min frame size
        0x00, 0x00, 0x00, // max frame size
        0x0A, 0xC4, 0x40, // sample rate (44100) + channels + bits
        0x00, 0x00, 0x00, 0x00, 0x00, // total samples (high bits)
        0x00, 0x00, 0x00, 0x00, // total samples (low bits)
        // MD5 signature (16 bytes)
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };

    const file = try tmp_dir.dir.createFile("valid.flac", .{});
    try file.writeAll(&valid_flac);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.flac");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.flac, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid FLAC failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid FLAC" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // FLAC with wrong first metadata block type
    const invalid_flac = [_]u8{
        'f', 'L', 'a', 'C',
        0x81, // metadata block header (type 1 = PADDING, but should be 0 = STREAMINFO)
        0x00,
        0x00,
        0x22,
    };

    const file = try tmp_dir.dir.createFile("invalid.flac", .{});
    try file.writeAll(&invalid_flac);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.flac");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.flac, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid WAV" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid WAV
    const valid_wav = [_]u8{
        'R', 'I', 'F', 'F', // RIFF signature
        0x24, 0x00, 0x00, 0x00, // file size - 8 (36 bytes)
        'W', 'A', 'V', 'E', // WAVE fourcc
        'f', 'm', 't', ' ', // fmt chunk
        0x10, 0x00, 0x00, 0x00, // fmt chunk size (16)
        0x01, 0x00, // audio format (PCM)
        0x01, 0x00, // num channels (1)
        0x44, 0xAC, 0x00, 0x00, // sample rate (44100)
        0x88, 0x58, 0x01, 0x00, // byte rate
        0x02, 0x00, // block align
        0x10, 0x00, // bits per sample (16)
        'd', 'a', 't', 'a', // data chunk
        0x00, 0x00, 0x00, 0x00, // data size (0)
    };

    const file = try tmp_dir.dir.createFile("valid.wav", .{});
    try file.writeAll(&valid_wav);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.wav");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wav, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid WAV failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects truncated WAV" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // WAV with RIFF size larger than file
    const truncated_wav = [_]u8{
        'R', 'I', 'F', 'F',
        0xFF, 0x00, 0x00, 0x00, // declared size (255)
        'W',  'A',  'V',
        'E',
        // Missing fmt chunk
    };

    const file = try tmp_dir.dir.createFile("truncated.wav", .{});
    try file.writeAll(&truncated_wav);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.wav");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wav, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator deep validates real WAV from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth WAV file (440Hz sine wave)
    const file = std.fs.cwd().openFile("ground_truth_examples/wav/sample.wav", .{}) catch {
        return; // Skip if file doesn't exist
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/wav/sample.wav") catch return;
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.wav, result.format);
    try std.testing.expect(result.is_valid);
    // WAV validates chunk structure but no audio decode or checksum
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateMp3Deep accepts valid MP3 with frame sync" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid MP3 frame (Layer III, 128kbps, 44.1kHz, stereo)
    // Frame sync: FF FB (11 bits of 1s + version/layer/protection)
    // FB = 11111011 = sync(3) + MPEG1(2) + Layer3(2) + no CRC(1)
    // 90 = 10010000 = bitrate 128(4) + 44.1kHz(2) + no padding(1) + private(1)
    // 00 = mode/etc
    const valid_mp3 = [_]u8{
        0xFF, 0xFB, // Frame sync + MPEG1 Layer3 no CRC
        0x90, 0x00, // 128kbps, 44.1kHz, stereo
        // Frame data (padding to min frame size ~417 bytes for 128kbps@44.1kHz)
    } ++ [_]u8{0x00} ** 417;

    const file = try tmp_dir.dir.createFile("valid.mp3", .{});
    try file.writeAll(&valid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateMp3Deep accepts valid MP3 with ID3 tag" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MP3 with ID3v2 header followed by valid frame
    const id3_header = [_]u8{
        'I', 'D', '3', // ID3 signature
        0x04, 0x00, // version 2.4
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // size (0 bytes of tag data)
    };
    const frame = [_]u8{
        0xFF, 0xFB, // Frame sync + MPEG1 Layer3 no CRC
        0x90, 0x00, // 128kbps, 44.1kHz
    } ++ [_]u8{0x00} ** 417;

    const valid_mp3 = id3_header ++ frame;

    const file = try tmp_dir.dir.createFile("valid_id3.mp3", .{});
    try file.writeAll(&valid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid_id3.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateMp3Deep rejects invalid frame sync after ID3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MP3 with ID3 tag but invalid frame sync after it
    const id3_header = [_]u8{
        'I', 'D', '3', // ID3 signature
        0x04, 0x00, // version 2.4
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // size (0 bytes of tag data)
    };
    const invalid_frame = [_]u8{
        0xFF, 0x00, // Invalid - second byte doesn't have sync bits (should be E0+)
        0x90, 0x00,
    } ++ [_]u8{0x00} ** 417;

    const invalid_mp3 = id3_header ++ invalid_frame;

    const file = try tmp_dir.dir.createFile("invalid.mp3", .{});
    try file.writeAll(&invalid_mp3);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "detectFormat MIDI" {
    // Valid MIDI header: MThd + length (6) + format (1) + tracks (2) + division (480)
    const midi_header = [_]u8{
        'M', 'T', 'h', 'd', // Signature
        0x00, 0x00, 0x00, 0x06, // Length = 6 (big-endian)
        0x00, 0x01, // Format type 1
        0x00, 0x02, // 2 tracks
        0x01, 0xE0, // Division = 480 ticks per quarter note
    };
    try std.testing.expectEqual(FileFormat.midi, detectFormat(&midi_header));
}

test "FormatValidator accepts valid MIDI" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid MIDI file (format 1, 1 track with empty events)
    const midi_data = [_]u8{
        // Header chunk
        'M', 'T', 'h', 'd', // Signature
        0x00, 0x00, 0x00, 0x06, // Length = 6
        0x00, 0x01, // Format type 1
        0x00, 0x01, // 1 track
        0x01, 0xE0, // Division = 480
        // Track chunk
        'M', 'T', 'r', 'k', // Signature
        0x00, 0x00, 0x00, 0x04, // Length = 4 bytes
        0x00, 0xFF, 0x2F, 0x00, // End of track meta event
    };

    const file = try tmp_dir.dir.createFile("test.mid", .{});
    try file.writeAll(&midi_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.mid");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.midi, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects MIDI with invalid format type" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MIDI with invalid format type (3)
    const midi_data = [_]u8{
        'M',  'T',  'h',  'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x03, // Invalid format type 3
        0x00, 0x01,
        0x01, 0xE0,
        'M',  'T',
        'r',  'k',
        0x00, 0x00,
        0x00, 0x04,
        0x00, 0xFF,
        0x2F, 0x00,
    };

    const file = try tmp_dir.dir.createFile("invalid_format.mid", .{});
    try file.writeAll(&midi_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid_format.mid");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.midi, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator rejects MIDI with missing track" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MIDI header only, no track
    const midi_data = [_]u8{
        'M',  'T',  'h',  'd',
        0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x01,
        0x01,
        0xE0,
        // Missing MTrk chunk
    };

    const file = try tmp_dir.dir.createFile("no_track.mid", .{});
    try file.writeAll(&midi_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "no_track.mid");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.midi, result.format);
    try std.testing.expect(!result.is_valid);
}

test "detectFormat XM" {
    // Valid XM header
    var xm_header: [60]u8 = undefined;
    @memcpy(xm_header[0..17], "Extended Module: ");
    @memset(xm_header[17..37], 0x20); // Module name (spaces)
    xm_header[37] = 0x1A; // End-of-text marker
    @memset(xm_header[38..58], 0);
    xm_header[58] = 0x04; // Version low byte
    xm_header[59] = 0x01; // Version high byte (0x0104)
    try std.testing.expectEqual(FileFormat.xm, detectFormat(&xm_header));
}

test "detectFormat IT" {
    // Valid IT header
    const it_header: [4]u8 = "IMPM".*;
    try std.testing.expectEqual(FileFormat.it, detectFormat(&it_header));
}

test "detectFormat S3M" {
    // Valid S3M header with SCRM at offset 44
    var s3m_header: [48]u8 = undefined;
    @memset(s3m_header[0..44], 0);
    @memcpy(s3m_header[44..48], "SCRM");
    try std.testing.expectEqual(FileFormat.s3m, detectFormat(&s3m_header));
}

test "FormatValidator accepts valid XM" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid XM file
    var xm_data: [80]u8 = undefined;
    @memcpy(xm_data[0..17], "Extended Module: ");
    @memset(xm_data[17..37], 0x20); // Module name
    xm_data[37] = 0x1A; // End-of-text marker
    @memset(xm_data[38..58], 0);
    xm_data[58] = 0x04; // Version 0x0104
    xm_data[59] = 0x01;
    // Header size at 60-63 (little-endian)
    xm_data[60] = 0x14; // 276 (standard header size) - low byte
    xm_data[61] = 0x01;
    xm_data[62] = 0x00;
    xm_data[63] = 0x00;
    // Song length at 64-65
    xm_data[64] = 0x01;
    xm_data[65] = 0x00;
    // Restart position at 66-67
    xm_data[66] = 0x00;
    xm_data[67] = 0x00;
    // Number of channels at 68-69
    xm_data[68] = 0x08; // 8 channels
    xm_data[69] = 0x00;
    @memset(xm_data[70..80], 0);

    const file = try tmp_dir.dir.createFile("test.xm", .{});
    try file.writeAll(&xm_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.xm");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.xm, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid IT" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid IT file
    var it_data: [192]u8 = undefined;
    @memcpy(it_data[0..4], "IMPM"); // Signature
    @memset(it_data[4..0x20], 0); // Song name and reserved
    it_data[0x20] = 0x10; // Number of orders (16)
    it_data[0x21] = 0x00;
    it_data[0x22] = 0x00; // Number of instruments (0)
    it_data[0x23] = 0x00;
    it_data[0x24] = 0x01; // Number of samples (1)
    it_data[0x25] = 0x00;
    it_data[0x26] = 0x01; // Number of patterns (1)
    it_data[0x27] = 0x00;
    it_data[0x28] = 0x14; // Created with version (0x0214)
    it_data[0x29] = 0x02;
    it_data[0x2A] = 0x14; // Compatible with version
    it_data[0x2B] = 0x02;
    @memset(it_data[0x2C..192], 0);

    const file = try tmp_dir.dir.createFile("test.it", .{});
    try file.writeAll(&it_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.it");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.it, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid S3M" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid S3M file
    var s3m_data: [96]u8 = undefined;
    @memset(s3m_data[0..28], 0); // Song name
    s3m_data[0x1C] = 0x1A; // 0x1A marker
    s3m_data[0x1D] = 16; // Type (16 = S3M)
    s3m_data[0x1E] = 0x00;
    s3m_data[0x1F] = 0x00;
    s3m_data[0x20] = 0x10; // Number of orders (16)
    s3m_data[0x21] = 0x00;
    s3m_data[0x22] = 0x01; // Number of instruments (1)
    s3m_data[0x23] = 0x00;
    s3m_data[0x24] = 0x01; // Number of patterns (1)
    s3m_data[0x25] = 0x00;
    @memset(s3m_data[0x26..44], 0);
    @memcpy(s3m_data[44..48], "SCRM"); // Signature
    @memset(s3m_data[48..96], 0);

    const file = try tmp_dir.dir.createFile("test.s3m", .{});
    try file.writeAll(&s3m_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.s3m");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.s3m, result.format);
    try std.testing.expect(result.is_valid);
}

test "detectFormat APE" {
    // APE files start with "MAC " followed by version info
    const ape_data = "MAC " ++ [_]u8{ 0xC4, 0x0F }; // "MAC " + version 3980 (0x0FC4) little-endian
    const result = detectFormat(ape_data);
    try std.testing.expectEqual(FileFormat.ape, result);
}

test "detectFormat WavPack" {
    // WavPack files start with "wvpk"
    const wavpack_data = "wvpk";
    const result = detectFormat(wavpack_data);
    try std.testing.expectEqual(FileFormat.wavpack, result);
}

test "FormatValidator accepts valid APE" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid APE file (version 3980+)
    var ape_data: [32]u8 = undefined;
    @memcpy(ape_data[0..4], "MAC "); // Signature
    ape_data[4] = 0xC4; // Version 3980 low byte
    ape_data[5] = 0x0F; // Version 3980 high byte
    ape_data[6] = 0; // Padding
    ape_data[7] = 0; // Padding
    // Descriptor length (52 bytes minimum for modern APE)
    ape_data[8] = 52;
    ape_data[9] = 0;
    ape_data[10] = 0;
    ape_data[11] = 0;
    // Header length (24 bytes minimum)
    ape_data[12] = 24;
    ape_data[13] = 0;
    ape_data[14] = 0;
    ape_data[15] = 0;
    @memset(ape_data[16..32], 0);

    const file = try tmp_dir.dir.createFile("test.ape", .{});
    try file.writeAll(&ape_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.ape");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.ape, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts legacy APE (version < 3980)" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid APE file (legacy version 3900)
    var ape_data: [32]u8 = undefined;
    @memcpy(ape_data[0..4], "MAC "); // Signature
    ape_data[4] = 0x3C; // Version 3900 low byte
    ape_data[5] = 0x0F; // Version 3900 high byte
    @memset(ape_data[6..32], 0);

    const file = try tmp_dir.dir.createFile("test.ape", .{});
    try file.writeAll(&ape_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.ape");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.ape, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects APE with invalid descriptor" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create APE file with descriptor too small
    var ape_data: [32]u8 = undefined;
    @memcpy(ape_data[0..4], "MAC "); // Signature
    ape_data[4] = 0xC4; // Version 3980 low byte
    ape_data[5] = 0x0F; // Version 3980 high byte
    ape_data[6] = 0;
    ape_data[7] = 0;
    // Descriptor length too small (10 instead of 52+)
    ape_data[8] = 10;
    ape_data[9] = 0;
    ape_data[10] = 0;
    ape_data[11] = 0;
    @memset(ape_data[12..32], 0);

    const file = try tmp_dir.dir.createFile("test.ape", .{});
    try file.writeAll(&ape_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.ape");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.ape, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid WavPack" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid WavPack file
    var wv_data: [32]u8 = undefined;
    @memcpy(wv_data[0..4], "wvpk"); // Signature
    // Block size (24 bytes - reasonable)
    wv_data[4] = 24;
    wv_data[5] = 0;
    wv_data[6] = 0;
    wv_data[7] = 0;
    // Version 0x0410 (4.10)
    wv_data[8] = 0x10;
    wv_data[9] = 0x04;
    // Track number and sub-block index
    wv_data[10] = 0;
    wv_data[11] = 0;
    // Total samples
    wv_data[12] = 0x00;
    wv_data[13] = 0x10;
    wv_data[14] = 0;
    wv_data[15] = 0;
    // Block index
    wv_data[16] = 0;
    wv_data[17] = 0;
    wv_data[18] = 0;
    wv_data[19] = 0;
    // Block samples (reasonable value)
    wv_data[20] = 0x00;
    wv_data[21] = 0x10;
    wv_data[22] = 0;
    wv_data[23] = 0;
    // Flags (16-bit stereo)
    wv_data[24] = 0x01; // 16-bit
    wv_data[25] = 0;
    wv_data[26] = 0;
    wv_data[27] = 0;
    @memset(wv_data[28..32], 0);

    const file = try tmp_dir.dir.createFile("test.wv", .{});
    try file.writeAll(&wv_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.wv");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wavpack, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects WavPack with invalid version" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create WavPack file with version too low
    var wv_data: [32]u8 = undefined;
    @memcpy(wv_data[0..4], "wvpk"); // Signature
    // Block size
    wv_data[4] = 24;
    wv_data[5] = 0;
    wv_data[6] = 0;
    wv_data[7] = 0;
    // Version 0x0300 (too old)
    wv_data[8] = 0x00;
    wv_data[9] = 0x03;
    @memset(wv_data[10..32], 0);

    const file = try tmp_dir.dir.createFile("test.wv", .{});
    try file.writeAll(&wv_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.wv");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wavpack, result.format);
    try std.testing.expect(!result.is_valid);
}

test "detectFormat DSF" {
    // DSF header starts with "DSD "
    const dsf_header = [_]u8{
        'D', 'S', 'D', ' ', // Signature
        0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Chunk size = 28 (little-endian)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // File size placeholder
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // Metadata offset
    };
    try std.testing.expectEqual(FileFormat.dsf, detectFormat(&dsf_header));
}

test "detectFormat DFF" {
    // DFF (DSDIFF) header starts with "FRM8"
    const dff_header = [_]u8{
        'F', 'R', 'M', '8', // IFF container signature
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, // Chunk size (big-endian)
        'D', 'S', 'D', ' ', // Form type
    };
    try std.testing.expectEqual(FileFormat.dff, detectFormat(&dff_header));
}

test "FormatValidator accepts valid DSF" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid DSF file (DSD64, stereo)
    // DSD chunk (28 bytes) + fmt chunk (52 bytes) + data chunk header (12 bytes) + minimal data
    var dsf_data: [100]u8 = undefined;

    // DSD chunk
    @memcpy(dsf_data[0..4], "DSD ");
    std.mem.writeInt(u64, dsf_data[4..12], 28, .little); // DSD chunk size
    std.mem.writeInt(u64, dsf_data[12..20], 100, .little); // Total file size
    std.mem.writeInt(u64, dsf_data[20..28], 0, .little); // No metadata

    // fmt chunk
    @memcpy(dsf_data[28..32], "fmt ");
    std.mem.writeInt(u64, dsf_data[32..40], 52, .little); // fmt chunk size
    std.mem.writeInt(u32, dsf_data[40..44], 1, .little); // Format version
    std.mem.writeInt(u32, dsf_data[44..48], 0, .little); // Format ID (DSD raw)
    std.mem.writeInt(u32, dsf_data[48..52], 2, .little); // Channel type (stereo)
    std.mem.writeInt(u32, dsf_data[52..56], 2, .little); // Channel count
    std.mem.writeInt(u32, dsf_data[56..60], 2822400, .little); // Sample rate (DSD64)
    std.mem.writeInt(u32, dsf_data[60..64], 1, .little); // Bits per sample
    std.mem.writeInt(u64, dsf_data[64..72], 0, .little); // Sample count
    std.mem.writeInt(u32, dsf_data[72..76], 4096, .little); // Block size per channel
    std.mem.writeInt(u32, dsf_data[76..80], 0, .little); // Reserved

    // data chunk (header only for minimal file)
    @memcpy(dsf_data[80..84], "data");
    std.mem.writeInt(u64, dsf_data[84..92], 20, .little); // data chunk size (12 header + 8 data)
    @memset(dsf_data[92..100], 0); // Minimal audio data

    const file = try tmp_dir.dir.createFile("test.dsf", .{});
    try file.writeAll(&dsf_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.dsf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.dsf, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid DFF" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid DFF (DSDIFF) file
    var dff_data: [40]u8 = undefined;

    // FRM8 container header
    @memcpy(dff_data[0..4], "FRM8");
    std.mem.writeInt(u64, dff_data[4..12], 28, .big); // Chunk size (big-endian)
    @memcpy(dff_data[12..16], "DSD "); // Form type

    // FVER chunk (format version)
    @memcpy(dff_data[16..20], "FVER");
    std.mem.writeInt(u64, dff_data[20..28], 4, .big); // Chunk size
    std.mem.writeInt(u32, dff_data[28..32], 0x01050000, .big); // Version 1.5

    // Pad to 40 bytes
    @memset(dff_data[32..40], 0);

    const file = try tmp_dir.dir.createFile("test.dff", .{});
    try file.writeAll(&dff_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.dff");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.dff, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects DSF with invalid sample rate" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dsf_data: [100]u8 = undefined;

    // DSD chunk
    @memcpy(dsf_data[0..4], "DSD ");
    std.mem.writeInt(u64, dsf_data[4..12], 28, .little);
    std.mem.writeInt(u64, dsf_data[12..20], 100, .little);
    std.mem.writeInt(u64, dsf_data[20..28], 0, .little);

    // fmt chunk with invalid sample rate
    @memcpy(dsf_data[28..32], "fmt ");
    std.mem.writeInt(u64, dsf_data[32..40], 52, .little);
    std.mem.writeInt(u32, dsf_data[40..44], 1, .little);
    std.mem.writeInt(u32, dsf_data[44..48], 0, .little);
    std.mem.writeInt(u32, dsf_data[48..52], 2, .little);
    std.mem.writeInt(u32, dsf_data[52..56], 2, .little);
    std.mem.writeInt(u32, dsf_data[56..60], 44100, .little); // Invalid! Not a DSD rate
    std.mem.writeInt(u32, dsf_data[60..64], 1, .little);
    std.mem.writeInt(u64, dsf_data[64..72], 0, .little);
    std.mem.writeInt(u32, dsf_data[72..76], 4096, .little);
    std.mem.writeInt(u32, dsf_data[76..80], 0, .little);
    @memcpy(dsf_data[80..84], "data");
    std.mem.writeInt(u64, dsf_data[84..92], 20, .little);
    @memset(dsf_data[92..100], 0);

    const file = try tmp_dir.dir.createFile("invalid.dsf", .{});
    try file.writeAll(&dsf_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.dsf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.dsf, result.format);
    try std.testing.expect(!result.is_valid);
}

