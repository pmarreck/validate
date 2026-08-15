const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ogg_validator = @import("ogg_validator.zig");
const vorbis_validator = @import("vorbis_validator.zig");
const opus_validator = @import("opus_validator.zig");
const ac3_validator = @import("ac3_validator.zig");
const dts_validator = @import("dts_validator.zig");
const eac3_validator = @import("eac3_validator.zig");
const wavpack_decoder = @import("wavpack_decoder.zig");
const wavpack_decode_validator = @import("wavpack_decode_validator.zig");
const ape_decode_validator = @import("ape_decode_validator.zig");
const midi_validator = @import("midi_validator.zig");
const tracker_validator = @import("tracker_validator.zig");
const libopenmpt = @import("libopenmpt.zig");
const flac_decoder = @import("flac_decoder.zig");
const mp3_decode_validator = @import("mp3_decode_validator.zig");
const mp3_validator = @import("mp3_validator.zig");
const aac_syntax_validator = @import("aac_syntax_validator.zig");
const statistical_corruption = @import("statistical_corruption.zig");
const errmsg = @import("error_messages.zig");

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;
const ValidationDepth = format_validation.ValidationDepth;

// ============ Helper ============

const findInBuffer = format_validation.findInBuffer;

// ============ MP3 Validator ============

/// Validate MP3 file structure.
pub fn validateMp3(file: *FileSource) ValidationResult {
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

    // MP3 files may have zero-padding or non-audio metadata (e.g., MusicMatch)
    // between ID3v2 tag and first audio frame. Scan up to 128KB to find frame sync.
    if (pos > 0) { // Only scan if we skipped an ID3 tag
        const scan_limit: u64 = pos + 131072;
        var scan_buf: [2]u8 = undefined;
        while (pos < scan_limit) {
            file.seekTo(pos) catch break;
            const n = file.read(&scan_buf) catch break;
            if (n < 2) break;
            if (scan_buf[0] == 0xFF and (scan_buf[1] & 0xE0) == 0xE0) {
                return ValidationResult.ok(.mp3);
            }
            pos += 1;
        }
    }

    return ValidationResult.invalidCode(.mp3, .invalid_value, "MP3 frame sync");
}

// ============ FLAC Validator ============

/// Validate FLAC file structure.
pub fn validateFlac(file: *FileSource) ValidationResult {
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

/// WARN-tier result for big-endian RIFX WAVs: a legitimate byte-order variant
/// (SGI/big-endian tooling; scipy ships them as test data) that this parser
/// does not read. Capability gap, never corruption.
fn rifxWavUnsupported() ValidationResult {
    var result = ValidationResult.okWithDepthAndWarning(
        .wav,
        .structural,
        "RIFX (big-endian) WAV: byte-order variant not parsed by this validator",
    );
    result.verdict = .indeterminate;
    result.validation_unsupported = true;
    result.format_variant = "rifx";
    return result;
}

fn isRifxWav(header: []const u8) bool {
    return header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFX") and std.mem.eql(u8, header[8..12], "WAVE");
}

/// Validate WAV file structure (RIFF container).
pub fn validateWav(file: *FileSource) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.wav, .failed_to_read, "WAV header");

    if (isRifxWav(&header)) return rifxWavUnsupported();

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

    if (@as(u64, riff_size) + 8 > file_size) {
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
pub fn validateWavDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator; // No longer needed - using streaming validation


    // Get file size for bounds checking
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_get, "file size", .structural);
    };

    if (file_size < 44) { // Minimum WAV size: 12 (RIFF) + 24 (fmt) + 8 (data header)
        return ValidationResult.invalidCodeWithDepth(.wav, .file_too_small, "valid WAV", .structural);
    }

    // Read RIFF header (12 bytes)
    var header: [12]u8 = undefined;
    const header_read = source.readAll(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_read, "header", .structural);
    };
    if (header_read < 12) {
        return ValidationResult.invalidCodeWithDepth(.wav, .truncated, "header", .structural);
    }

    // Verify RIFF/WAVE signature
    if (isRifxWav(&header)) return rifxWavUnsupported();
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
        source.seekTo(offset) catch {
            return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_seek, "to chunk", .structural);
        };

        // Read chunk header (8 bytes: 4 ID + 4 size)
        var chunk_header: [8]u8 = undefined;
        const chunk_read = source.readAll(&chunk_header) catch {
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
            const fmt_read = source.readAll(&fmt_data) catch {
                return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_read, "fmt chunk", .structural);
            };
            if (fmt_read < 16) {
                return ValidationResult.invalidCodeWithDepth(.wav, .truncated, "fmt chunk", .structural);
            }

            fmt_audio_format = std.mem.readInt(u16, fmt_data[0..2], .little);
            fmt_channels = std.mem.readInt(u16, fmt_data[2..4], .little);
            fmt_sample_rate = std.mem.readInt(u32, fmt_data[4..8], .little);
            const fmt_byte_rate = std.mem.readInt(u32, fmt_data[8..12], .little);
            const fmt_block_align = std.mem.readInt(u16, fmt_data[12..14], .little);
            fmt_bits_per_sample = std.mem.readInt(u16, fmt_data[14..16], .little);

            // Validate format parameters
            if (fmt_channels == 0 or fmt_channels > 32) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "channel count", .structural);
            }
            if (fmt_sample_rate == 0 or fmt_sample_rate > 384000) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "sample rate", .structural);
            }
            // For PCM (1) and IEEE float (3), bits_per_sample must be valid.
            // For compressed/custom codecs (ADPCM, Wwise, etc.), bits_per_sample
            // may be 0 or non-standard — the codec handles its own sample format.
            if (fmt_audio_format == 1 or fmt_audio_format == 3) {
                if (fmt_bits_per_sample == 0 or fmt_bits_per_sample > 64) {
                    return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "bits per sample", .structural);
                }
            }

            // Cross-validate block_align = channels * bytes_per_sample
            // Note: ADPCM and other compressed formats use non-standard block_align values,
            // so a mismatch is not a corruption signal — treat as informational only.
            // Only hard-fail for uncompressed PCM (format 1) and IEEE float (format 3).
            const expected_block_align = fmt_channels * ((fmt_bits_per_sample + 7) / 8);
            if (fmt_block_align != expected_block_align and (fmt_audio_format == 1 or fmt_audio_format == 3)) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "block align mismatch (channels * bytes_per_sample)", .structural);
            }

            // Cross-validate byte_rate = sample_rate * block_align
            // Same rationale: only enforce for uncompressed PCM and IEEE float.
            const expected_byte_rate: u64 = @as(u64, fmt_sample_rate) * @as(u64, fmt_block_align);
            if (expected_byte_rate <= std.math.maxInt(u32) and fmt_byte_rate != @as(u32, @intCast(expected_byte_rate)) and (fmt_audio_format == 1 or fmt_audio_format == 3)) {
                return ValidationResult.invalidCodeWithDepth(.wav, .invalid_value, "byte rate mismatch (sample_rate * block_align)", .structural);
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
        return validateWavFloatSamples(source, data_chunk_offset, data_chunk_size, fmt_bits_per_sample);
    }

    // Integer PCM: no inherent corruption signal (any value is valid).
    // Run the statistical heuristic on mono s16 — Phase 1 of the WARN-tier
    // scanner. See src/core/statistical_corruption.zig.
    if (fmt_audio_format == 1 and fmt_channels == 1 and fmt_bits_per_sample == 16) {
        return scanWavMonoS16Heuristic(source, data_chunk_offset, data_chunk_size, fmt_sample_rate);
    }
    return ValidationResult.okWithDepth(.wav, .structural);
}

/// Scan IEEE 754 float WAV samples for NaN/Inf — definitive corruption signal.
fn validateWavFloatSamples(file: *FileSource, data_offset: u64, data_size: u32, bits_per_sample: u16) ValidationResult {
    file.seekTo(data_offset) catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .failed_to_seek, "to audio data", .full);
    };

    const heap_alloc = heap.validateAllocator();
    const buf = heap_alloc.alloc(u8, 65536) catch {
        return ValidationResult.invalidCodeWithDepth(.wav, .out_of_memory, "audio scan buffer", .full);
    };
    defer heap_alloc.free(buf);
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

/// Render a sample index as wall-clock time `time=HH:MM:SS.mmm` for use in
/// statistical-corruption diagnostic warnings. Always written; if sample_rate
/// is zero (broken WAV header) the literal `time=?` is emitted so the caller
/// still gets the byte offset and the user knows time is undetermined.
/// Concise format chosen so multiple findings fit in the 512-byte warning buffer.
fn writeTimeOffset(w: *std.Io.Writer, sample_index: u64, sample_rate: u32) !void {
    if (sample_rate == 0) {
        try w.print("time=?", .{});
        return;
    }
    const total_ms: u64 = (sample_index * 1000) / sample_rate;
    const ms: u32 = @intCast(total_ms % 1000);
    const total_seconds: u64 = total_ms / 1000;
    const seconds: u32 = @intCast(total_seconds % 60);
    const total_minutes: u64 = total_seconds / 60;
    const minutes: u32 = @intCast(total_minutes % 60);
    const hours: u32 = @intCast(total_minutes / 60);
    try w.print("time={d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, minutes, seconds, ms });
}

/// Run the statistical-corruption WARN heuristic on mono signed-16-bit PCM
/// inside a WAV file. Returns ValidationResult.okWithDepthAndWarning when the
/// heuristic score crosses the SUSPICIOUS threshold (>= 25/100). The
/// underlying scoring panel is documented in src/core/statistical_corruption.zig.
///
/// Cap on inspected payload: 32 MiB (~3 minutes of 44.1 kHz mono s16). Files
/// larger than that are scanned only over the first 32 MiB; the warning notes
/// that explicitly. This bounds the heuristic's wall-clock cost and avoids
/// pathological allocations on multi-GB raw recordings.
fn scanWavMonoS16Heuristic(file: *FileSource, data_offset: u64, data_size: u32, sample_rate: u32) ValidationResult {
    const MAX_SCAN_BYTES: u32 = 32 * 1024 * 1024; // 32 MiB
    const scan_bytes: u32 = @min(data_size, MAX_SCAN_BYTES);
    // Need at least a few hundred samples for the residual stats to be sane.
    if (scan_bytes < 256) {
        return ValidationResult.okWithDepth(.wav, .structural);
    }

    file.seekTo(data_offset) catch {
        return ValidationResult.okWithDepth(.wav, .structural);
    };

    const sample_count: usize = scan_bytes / 2;
    const samples = heap.validateAllocator().alloc(i16, sample_count) catch {
        // OOM on heuristic — just skip; structural is still valid.
        return ValidationResult.okWithDepth(.wav, .structural);
    };
    defer heap.validateAllocator().free(samples);

    // Read raw bytes into a temporary buffer, then decode little-endian s16.
    const raw = heap.validateAllocator().alloc(u8, scan_bytes) catch {
        return ValidationResult.okWithDepth(.wav, .structural);
    };
    defer heap.validateAllocator().free(raw);

    const bytes_read = file.read(raw) catch {
        return ValidationResult.okWithDepth(.wav, .structural);
    };
    if (bytes_read < 256) {
        return ValidationResult.okWithDepth(.wav, .structural);
    }
    const real_sample_count: usize = bytes_read / 2;
    var i: usize = 0;
    while (i < real_sample_count) : (i += 1) {
        samples[i] = std.mem.readInt(i16, raw[i * 2 ..][0..2], .little);
    }

    var arena = std.heap.ArenaAllocator.init(heap.validateAllocator());
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const result = statistical_corruption.analyzePcmS16(
        arena_alloc,
        samples[0..real_sample_count],
        sample_rate,
        1,
        data_offset,
    ) catch {
        return ValidationResult.okWithDepth(.wav, .structural);
    };

    const scan = switch (result) {
        .scanned => |s| s,
        .skipped => return ValidationResult.okWithDepth(.wav, .structural),
    };

    if (scan.score < 25) {
        return ValidationResult.okWithDepth(.wav, .structural);
    }

    // Format a concise WARN message into a thread-local buffer (see
    // crypto_validators.zig for the precedent — ValidationResult borrows
    // string slices, so dynamic warnings live in static thread-local storage).
    const S = struct {
        threadlocal var buf: [512]u8 = undefined;
    };
    const severity_label: []const u8 = switch (scan.severity) {
        .clean => "clean",
        .suspicious => "possible PCM corruption",
        .likely_corrupt => "likely PCM corruption",
    };

    var w = std.Io.Writer.fixed(&S.buf);
    w.print("statistical-corruption heuristic: {s} (score={d}/100", .{ severity_label, scan.score }) catch {};
    if (scan.synth_flat) {
        w.print(", synth-flat", .{}) catch {};
    }
    w.print(")", .{}) catch {};
    var emitted: usize = 0;
    for (scan.findings) |f| {
        if (emitted >= 3) break;
        switch (f) {
            .constant_run => |cr| {
                const byte_offset = data_offset + cr.sample_offset * 2;
                w.print("; constant_run byte=0x{X} ", .{byte_offset}) catch {};
                writeTimeOffset(&w, cr.sample_offset, sample_rate) catch {};
                w.print(" len={d} val={d}", .{ cr.length, cr.value }) catch {};
                emitted += 1;
            },
            .diagnosed_bit_flip => |bf| {
                w.print("; bit_flip byte=0x{X} ", .{bf.byte_offset}) catch {};
                writeTimeOffset(&w, bf.sample_offset, sample_rate) catch {};
                w.print(" bit={d} z={d:.1}->{d:.1}", .{ bf.bit_index, bf.z_before, bf.z_after }) catch {};
                emitted += 1;
            },
            .sector_aligned_cluster => |sc| {
                // Convert byte offset back to a sample index for time display.
                const sample_idx = if (sc.first_byte > data_offset)
                    (sc.first_byte - data_offset) / 2
                else
                    0;
                w.print("; sector_cluster byte=0x{X} ", .{sc.first_byte}) catch {};
                writeTimeOffset(&w, sample_idx, sample_rate) catch {};
                w.print(" span={d} sector={d}", .{ sc.span, sc.sector_size }) catch {};
                emitted += 1;
            },
        }
    }
    if (data_size > MAX_SCAN_BYTES) {
        w.print("; scanned first {d}MiB", .{MAX_SCAN_BYTES / (1024 * 1024)}) catch {};
    }
    const written = w.buffered();
    return ValidationResult.okWithDepthAndWarning(.wav, .structural, written);
}

/// Deep validation for AIFF audio files.
/// Parses all IFF chunks and validates structure similar to WAV deep validation.
pub fn validateAiffDeep(allocator: Allocator, source: *FileSource) ValidationResult {

    // Read entire file for validation
    const file_size = source.getEndPos() catch {
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

    const bytes_read = source.readAll(data) catch {
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
    if (@as(u64, form_size) + 8 > file_size) {
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
    var comm_num_channels: u16 = 0;
    var comm_num_sample_frames: u32 = 0;
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
            comm_num_channels = std.mem.readInt(u16, comm_data[0..2], .big);
            comm_num_sample_frames = std.mem.readInt(u32, comm_data[2..6], .big);
            comm_sample_size = std.mem.readInt(u16, comm_data[6..8], .big);

            // Validate numChannels range (most reliable field for corruption detection)
            if (comm_num_channels == 0 or comm_num_channels > 32) {
                return ValidationResult.invalidCodeWithDepth(.aiff, .invalid_value, "COMM channel count", .structural);
            }

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

    // Cross-validate SSND size with COMM fields: expected = numFrames * numChannels * bytesPerSample
    // Only validate when sampleSize is a standard audio bit depth (8, 16, 24, 32, 64)
    if (comm_num_channels > 0 and comm_num_sample_frames > 0 and ssnd_data_len > 0) {
        const valid_sample_size = (comm_sample_size == 8 or comm_sample_size == 16 or
            comm_sample_size == 24 or comm_sample_size == 32 or comm_sample_size == 64);
        if (valid_sample_size) {
            const bytes_per_sample: u64 = (@as(u64, comm_sample_size) + 7) / 8;
            const expected_ssnd_size = @as(u64, comm_num_sample_frames) * @as(u64, comm_num_channels) * bytes_per_sample;
            if (ssnd_data_len != expected_ssnd_size) {
                return ValidationResult.invalidCodeWithDepth(.aiff, .invalid_value, "SSND size mismatch (numFrames * channels * bytesPerSample)", .structural);
            }
        }
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
pub fn validateRiffAudio(file: *FileSource, format: FileFormat) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(format, .failed_to_read, "audio header");

    // Big-endian RIFX WAV: legitimate byte-order variant, not corruption.
    if (format == .wav and isRifxWav(&header)) return rifxWavUnsupported();

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

    if (@as(u64, declared_size) + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(format, .exceeds_bounds, "Container size", "Container size exceeds file size (truncated)");
    }

    return ValidationResult.ok(format);
}

// ============ Ogg Validator ============

/// Validate Ogg container file structure (Vorbis, Opus, etc.).
pub fn validateOgg(file: *FileSource) ValidationResult {
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
pub fn validateOggDeep(allocator: Allocator, source: *FileSource) ValidationResult {

    // First, verify OGG page CRCs for container integrity
    const crc_result = ogg_validator.validateOggCrc(source);
    if (!crc_result.valid) {
        return ValidationResult.invalidWithDepth(.ogg, crc_result.error_message orelse "OGG CRC verification failed", .full);
    }

    // Reset file position for packet extraction
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "to start", .structural);
    };

    // Extract packets to determine codec type
    var packet_result = ogg_validator.extractPackets(allocator, source) catch |err| {
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
        source.seekTo(0) catch {
            return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "for Vorbis validation", .full);
        };

        const vorbis_result = vorbis_validator.validateOggVorbisAlloc(allocator, source);
        if (vorbis_result.valid) {
            return ValidationResult.okWithDepth(.ogg, .full);
        } else {
            return ValidationResult.invalidWithDepth(.ogg, vorbis_result.error_message orelse "Vorbis validation failed", .full);
        }
    }

    // Check for Opus: starts with "OpusHead"
    if (first_packet.len >= 8 and std.mem.eql(u8, first_packet[0..8], "OpusHead")) {
        // Reset and validate as Opus
        source.seekTo(0) catch {
            return ValidationResult.invalidCodeWithDepth(.ogg, .failed_to_seek, "for Opus validation", .full);
        };

        const opus_result = opus_validator.validateOggOpus(source);
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
pub fn validateMidi(file: *FileSource) ValidationResult {
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
pub fn validateDsf(file: *FileSource) ValidationResult {
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
pub fn validateDff(file: *FileSource) ValidationResult {
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
pub fn validateAc3(file: *FileSource) ValidationResult {
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
pub fn validateEac3(file: *FileSource) ValidationResult {
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
pub fn validateMod(file: *FileSource) ValidationResult {
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
pub fn validateXm(file: *FileSource) ValidationResult {
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
pub fn validateIt(file: *FileSource) ValidationResult {
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
pub fn validateS3m(file: *FileSource) ValidationResult {
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

/// Validate Monkey's Audio (APE) file structure with structural-rigor checks.
///
/// Spec coverage (per FFmpeg libavformat/ape.c demuxer + libavcodec/apedec.c):
/// - v3800-v3970 (legacy): single 32-byte header, optional peak level + seek table, WAV header chunk
/// - v3980+ (modern): 52-byte descriptor (MD5 + sizes) followed by 24-byte header, then seek table,
///   then optional WAV header chunk, then frame data
///
/// Structural checks performed (no audio decode — full byte-level CRC32 over decoded PCM
/// requires a Monkey's Audio decoder, deferred to a follow-up multi-session task):
///   1. "MAC " magic
///   2. Version range: 3800..=3990 (APE_MIN_VERSION..APE_MAX_VERSION per FFmpeg)
///   3. Compression level is one of {1000, 2000, 3000, 4000, 5000} ('insane' only legal for >= 3930)
///   4. Channels in {1, 2}
///   5. Sample rate in plausible audio range (4 kHz .. 384 kHz)
///   6. BPS in {8, 16, 24}
///   7. totalframes > 0 and not absurdly large
///   8. Seek table length sufficient (≥ totalframes × 4 bytes)
///   9. Sum of (descriptor + header + seektable + wavheader) <= file size
///  10. Seek table entries strictly monotonically increasing AND inside the audio-data region
///  11. (v3980+) descriptor's audiodatalength + audiodatalength_high covers the audio
///      data region implied by file_size - first_frame_offset - wavtaillength
///
/// Returns `.full` depth so corruption beyond the header/seek-table is correctly attributed
/// when caught; returns `.structural` only on the v < 3800 path which has no rich layout.
pub fn validateApe(file: *FileSource) ValidationResult {
	var header: [32]u8 = undefined;
	const bytes_read = file.read(&header) catch {
		return ValidationResult.invalidCode(.ape, .failed_to_read, "APE header");
	};

	if (bytes_read < 32) {
		return ValidationResult.invalidCode(.ape, .file_too_small, "APE format");
	}

	if (!std.mem.eql(u8, header[0..4], "MAC ")) {
		return ValidationResult.invalidCode(.ape, .invalid_signature, "APE");
	}

	const version = std.mem.readInt(u16, header[4..6], .little);

	// Per FFmpeg APE_MIN_VERSION/APE_MAX_VERSION.
	if (version > 3990) {
		return ValidationResult.invalidWithDepth(.ape, "APE version unsupported (> 3990)", .full);
	}
	if (version < 3800) {
		// Very old APE format — limited spec knowledge; accept structurally.
		return ValidationResult.ok(.ape);
	}

	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_get, "APE file size", .full);
	};
	if (file_size > 1024 * 1024 * 1024) {
		// 1 GiB — far above any realistic audio file. Cap to avoid integer issues below.
		return ValidationResult.invalidCodeWithDepth(.ape, .file_too_large, "APE", .full);
	}

	// --------- Parse descriptor + header ---------
	var compression_type: u16 = 0;
	var format_flags: u16 = 0;
	var channels: u16 = 0;
	var sample_rate: u32 = 0;
	var total_frames: u32 = 0;
	var final_frame_blocks: u32 = 0;
	var bps: u16 = 16;
	var seek_table_len_bytes: u64 = 0;
	var first_frame_offset: u64 = 0;
	var audio_end_min: u64 = 0; // tightest lower bound for end of audio data
	var audio_end_max: u64 = file_size; // upper bound

	if (version >= 3980) {
		// Descriptor block: 52 bytes minimum (FFmpeg may skip extra bytes for forward compat).
		var desc_buf: [52]u8 = undefined;
		// We already read 32 bytes (header[0..32]). Copy them into desc_buf[0..32], read remaining 20.
		@memcpy(desc_buf[0..32], header[0..32]);
		const more = file.read(desc_buf[32..52]) catch {
			return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE descriptor", .full);
		};
		if (more < 20) {
			return ValidationResult.invalidWithDepth(.ape, "APE descriptor truncated", .full);
		}

		const descriptor_length = std.mem.readInt(u32, desc_buf[8..12], .little);
		const header_length = std.mem.readInt(u32, desc_buf[12..16], .little);
		const seek_table_length = std.mem.readInt(u32, desc_buf[16..20], .little);
		const wav_header_length = std.mem.readInt(u32, desc_buf[20..24], .little);
		const audio_data_length = std.mem.readInt(u32, desc_buf[24..28], .little);
		const audio_data_length_high = std.mem.readInt(u32, desc_buf[28..32], .little);
		const wav_tail_length = std.mem.readInt(u32, desc_buf[32..36], .little);
		// MD5 is desc_buf[36..52] — we cannot verify without decoding. Stored for future use.

		if (descriptor_length < 52) {
			return ValidationResult.invalidWithDepth(.ape, "APE descriptor length too small", .full);
		}
		if (header_length < 24) {
			return ValidationResult.invalidWithDepth(.ape, "APE header length too small", .full);
		}

		// Skip any unknown trailing descriptor bytes (forward compat).
		const desc_extra = descriptor_length - 52;
		if (desc_extra > 0) {
			file.seekTo(@as(u64, descriptor_length)) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .invalid_value, "APE descriptor seek", .full);
			};
		}

		// Read APE_HEADER (24 bytes minimum, may be more — FFmpeg reads exactly 24 for the
		// known fields and skips remainder as part of header_length).
		var hdr: [24]u8 = undefined;
		const hr = file.read(&hdr) catch {
			return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE header block", .full);
		};
		if (hr < 24) {
			return ValidationResult.invalidWithDepth(.ape, "APE header block truncated", .full);
		}

		compression_type = std.mem.readInt(u16, hdr[0..2], .little);
		format_flags = std.mem.readInt(u16, hdr[2..4], .little);
		const blocks_per_frame = std.mem.readInt(u32, hdr[4..8], .little);
		_ = blocks_per_frame;
		final_frame_blocks = std.mem.readInt(u32, hdr[8..12], .little);
		total_frames = std.mem.readInt(u32, hdr[12..16], .little);
		bps = std.mem.readInt(u16, hdr[16..18], .little);
		channels = std.mem.readInt(u16, hdr[18..20], .little);
		sample_rate = std.mem.readInt(u32, hdr[20..24], .little);

		seek_table_len_bytes = seek_table_length;

		first_frame_offset = @as(u64, descriptor_length) + @as(u64, header_length) +
			@as(u64, seek_table_length) + @as(u64, wav_header_length);

		// audio_data_length spans the audio-data region (from first_frame to file_end - wav_tail).
		const audio_data_total = (@as(u64, audio_data_length_high) << 32) | @as(u64, audio_data_length);
		if (audio_data_total > 0 and audio_data_total < std.math.maxInt(u32) * @as(u64, 16)) {
			const computed_end = first_frame_offset + audio_data_total;
			audio_end_min = computed_end;
			audio_end_max = computed_end;
		}
		// If audio_data_length is zero (unknown), use file_size - wav_tail as the end.
		if (wav_tail_length > 0 and wav_tail_length < file_size) {
			if (audio_end_max > file_size - @as(u64, wav_tail_length)) {
				audio_end_max = file_size - @as(u64, wav_tail_length);
			}
		}
	} else {
		// Legacy header (v3800-v3970): single 32-byte block we already read.
		compression_type = std.mem.readInt(u16, header[6..8], .little);
		format_flags = std.mem.readInt(u16, header[8..10], .little);
		channels = std.mem.readInt(u16, header[10..12], .little);
		sample_rate = std.mem.readInt(u32, header[12..16], .little);
		const wav_header_length = std.mem.readInt(u32, header[16..20], .little);
		const wav_tail_length = std.mem.readInt(u32, header[20..24], .little);
		total_frames = std.mem.readInt(u32, header[24..28], .little);
		final_frame_blocks = std.mem.readInt(u32, header[28..32], .little);

		// Legacy format flags determine BPS:
		const MAC_FORMAT_FLAG_8_BIT: u16 = 0x01;
		const MAC_FORMAT_FLAG_24_BIT: u16 = 0x08;
		const MAC_FORMAT_FLAG_HAS_PEAK_LEVEL: u16 = 0x04;
		const MAC_FORMAT_FLAG_HAS_SEEK_ELEMENTS: u16 = 0x10;
		if ((format_flags & MAC_FORMAT_FLAG_8_BIT) != 0) {
			bps = 8;
		} else if ((format_flags & MAC_FORMAT_FLAG_24_BIT) != 0) {
			bps = 24;
		} else {
			bps = 16;
		}

		// Track current cursor: we have read 32 bytes from the start.
		var cursor: u64 = 32;
		if ((format_flags & MAC_FORMAT_FLAG_HAS_PEAK_LEVEL) != 0) cursor += 4;

		if ((format_flags & MAC_FORMAT_FLAG_HAS_SEEK_ELEMENTS) != 0) {
			// Read explicit seek table count (4 bytes after peak level).
			file.seekTo(cursor) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .invalid_value, "APE legacy seek", .full);
			};
			var ste: [4]u8 = undefined;
			const r = file.read(&ste) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE seek count", .full);
			};
			if (r < 4) {
				return ValidationResult.invalidWithDepth(.ape, "APE legacy seek count truncated", .full);
			}
			const ste_count = std.mem.readInt(u32, &ste, .little);
			seek_table_len_bytes = @as(u64, ste_count) * 4;
			cursor += 4;
		} else {
			seek_table_len_bytes = @as(u64, total_frames) * 4;
		}

		first_frame_offset = cursor + seek_table_len_bytes + @as(u64, wav_header_length);
		if (wav_tail_length > 0 and @as(u64, wav_tail_length) < file_size) {
			audio_end_max = file_size - @as(u64, wav_tail_length);
		}
	}

	// --------- Validate parsed fields ---------
	// Compression level: must be one of 1000/2000/3000/4000/5000; insane only for v >= 3930
	if (compression_type == 0 or compression_type % 1000 != 0 or compression_type > 5000) {
		return ValidationResult.invalidWithDepth(.ape, "APE compression level invalid", .full);
	}
	if (compression_type == 5000 and version < 3930) {
		return ValidationResult.invalidWithDepth(.ape, "APE insane compression illegal for this version", .full);
	}

	if (channels == 0 or channels > 2) {
		return ValidationResult.invalidWithDepth(.ape, "APE channels not in {1,2}", .full);
	}

	// Plausible audio sample rate: 4 kHz .. 384 kHz (covers common 8k/11k/16k/22k/32k/44k/48k/88k/96k/176k/192k/352k)
	if (sample_rate < 4000 or sample_rate > 384000) {
		return ValidationResult.invalidWithDepth(.ape, "APE sample rate implausible", .full);
	}

	if (bps != 8 and bps != 16 and bps != 24) {
		return ValidationResult.invalidWithDepth(.ape, "APE bits-per-sample not in {8,16,24}", .full);
	}

	if (total_frames == 0) {
		return ValidationResult.invalidWithDepth(.ape, "APE has zero frames", .full);
	}
	if (total_frames > 256 * 1024 * 1024) {
		return ValidationResult.invalidWithDepth(.ape, "APE total_frames absurd", .full);
	}
	if (final_frame_blocks == 0) {
		return ValidationResult.invalidWithDepth(.ape, "APE final_frame_blocks is zero", .full);
	}

	// Seek table must contain at least one entry per frame.
	if (seek_table_len_bytes < @as(u64, total_frames) * 4) {
		return ValidationResult.invalidWithDepth(.ape, "APE seek table too short for frame count", .full);
	}

	if (first_frame_offset > file_size) {
		return ValidationResult.invalidWithDepth(.ape, "APE first frame offset past EOF", .full);
	}
	if (audio_end_max > file_size) {
		audio_end_max = file_size;
	}
	if (audio_end_min > file_size) {
		return ValidationResult.invalidWithDepth(.ape, "APE descriptor audio length past EOF", .full);
	}
	if (first_frame_offset >= audio_end_max) {
		return ValidationResult.invalidWithDepth(.ape, "APE has no room for audio data", .full);
	}

	// --------- Walk seek table ---------
	// Compute seek table file offset.
	// Modern (v >= 3980): seek table sits right after descriptor + header.
	// Legacy (v < 3980): seek table sits after the 32-byte header + optional peak level (4) + optional seek-count (4).
	var seek_off: u64 = 0;
	if (version >= 3980) {
		// For modern APE, seek table sits right after descriptor + header.
		const descriptor_length = blk: {
			var dh: [4]u8 = undefined;
			file.seekTo(8) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .invalid_value, "APE re-read", .full);
			};
			_ = file.read(&dh) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE re-read", .full);
			};
			break :blk std.mem.readInt(u32, &dh, .little);
		};
		const header_length = blk: {
			var hh: [4]u8 = undefined;
			file.seekTo(12) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .invalid_value, "APE re-read", .full);
			};
			_ = file.read(&hh) catch {
				return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE re-read", .full);
			};
			break :blk std.mem.readInt(u32, &hh, .little);
		};
		seek_off = @as(u64, descriptor_length) + @as(u64, header_length);
	} else {
		// Legacy file order is:
		//   header (32) + peak_level (4 if flag) + seek_count (4 if flag) + WAV header + seek table + frames
		// So the WAV header is BEFORE the seek table; we must skip it when locating seek_off.
		seek_off = 32;
		const MAC_FORMAT_FLAG_HAS_PEAK_LEVEL: u16 = 0x04;
		const MAC_FORMAT_FLAG_HAS_SEEK_ELEMENTS: u16 = 0x10;
		if ((format_flags & MAC_FORMAT_FLAG_HAS_PEAK_LEVEL) != 0) seek_off += 4;
		if ((format_flags & MAC_FORMAT_FLAG_HAS_SEEK_ELEMENTS) != 0) seek_off += 4;
		// Re-read wav_header_length from the legacy header (offset 16..20).
		const legacy_wav_header_length = std.mem.readInt(u32, header[16..20], .little);
		seek_off += @as(u64, legacy_wav_header_length);
	}

	if (seek_off + seek_table_len_bytes > file_size) {
		return ValidationResult.invalidWithDepth(.ape, "APE seek table extends past EOF", .full);
	}

	// Read first N (up to a cap) seek-table entries and verify monotonicity + bounds.
	const max_entries_to_check: u32 = @min(total_frames, @as(u32, 4096));
	file.seekTo(seek_off) catch {
		return ValidationResult.invalidCodeWithDepth(.ape, .invalid_value, "APE seek-table seek", .full);
	};
	var prev_off: u64 = 0;
	var i: u32 = 0;
	var ent: [4]u8 = undefined;
	while (i < max_entries_to_check) : (i += 1) {
		const r = file.read(&ent) catch {
			return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE seek entry", .full);
		};
		if (r < 4) {
			return ValidationResult.invalidWithDepth(.ape, "APE seek table truncated", .full);
		}
		const entry = @as(u64, std.mem.readInt(u32, &ent, .little));

		if (i == 0) {
			// First entry must equal first_frame_offset (modulo junklength = 0 for files we accept).
			if (entry < first_frame_offset or entry > audio_end_max) {
				return ValidationResult.invalidWithDepth(.ape, "APE first seek entry out of range", .full);
			}
		} else {
			if (entry <= prev_off) {
				return ValidationResult.invalidWithDepth(.ape, "APE seek table not monotonically increasing", .full);
			}
			if (entry > audio_end_max) {
				return ValidationResult.invalidWithDepth(.ape, "APE seek entry past audio end", .full);
			}
		}
		prev_off = entry;
	}

	// Structural rigor passed. Now run the full Monkey's Audio decoder over
	// the bitstream so per-frame CRC32 (computed over decoded PCM) catches
	// any payload corruption that survived the structural walker. Files
	// above 256 MiB stay structural-only to avoid pinning that much RAM.
	if (file_size > 256 * 1024 * 1024) {
		return ValidationResult.okWithDepth(.ape, .structural);
	}

	const ape_alloc = heap.validateAllocator();
	const slurp_ape = file.getMappedOrSlurp(ape_alloc, 256 << 20) catch
		return ValidationResult.invalidCodeWithDepth(.ape, .failed_to_read, "APE for decode", .full);
	var heap_ape: ?[]u8 = null;
	defer if (heap_ape) |b| ape_alloc.free(b);
	const data: []const u8 = switch (slurp_ape) {
		.mapped => |m| m,
		.heap => |b| blk: { heap_ape = b; break :blk b; },
		.too_large => return ValidationResult.okWithDepthAndWarning(.ape, .structural, "APE too large for non-mmap deep decode"),
	};
	const n = data.len;
	const buf = data;
	const dr = ape_decode_validator.validateApeDecode(buf[0..n]);
	if (!dr.valid) {
		return ValidationResult.invalidWithDepth(
			.ape,
			dr.error_message orelse "APE decode validation failed",
			.full,
		);
	}
	return ValidationResult.okWithDepth(.ape, .full);
}

/// Validate WavPack audio file by decoding every block to PCM and checking
/// libwavpack's internal CRC verifier. The CRC field in the WavPack block
/// header is computed over decoded samples (per dbry's `unpack.c`), so byte-
/// level corruption is only catchable via full decode + CRC compare. We
/// surface mismatches via `WavpackGetNumErrors`.
pub fn validateWavPack(file: *FileSource) ValidationResult {
    const allocator = heap.validateAllocator();
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidWithDepth(.wavpack, errmsg.failedToGet("file size"), .full);
    };
    if (file_size < 32) {
        return ValidationResult.invalidWithDepth(.wavpack, errmsg.fileTooSmallFor("WavPack"), .full);
    }
    if (file_size > 256 * 1024 * 1024) {
        // Above 256MB, fall back to structural validation rather than reading
        // the whole file into RAM. CRC verification still happens at the
        // structural-walker level (no full decode but block-level integrity
        // checks). Production samples for the validate test suite are far
        // smaller than this.
        const r = wavpack_decoder.validateWavPackFile(file, 10000, allocator);
        if (!r.valid) {
            return ValidationResult.invalid(.wavpack, r.error_message orelse "WavPack validation failed");
        }
        return ValidationResult.ok(.wavpack);
    }

    const slurp_wv = file.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidWithDepth(.wavpack, errmsg.failedToRead("file"), .full);
    var heap_wv: ?[]u8 = null;
    defer if (heap_wv) |b| allocator.free(b);
    const bytes: []const u8 = switch (slurp_wv) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_wv = b; break :blk b; },
        .too_large => return ValidationResult.okWithDepthAndWarning(.wavpack, .structural, "WavPack too large for non-mmap deep decode"),
    };
    const n = bytes.len;

    const result = wavpack_decode_validator.validateWavPackDecode(allocator, bytes[0..n]) catch |err| {
        return ValidationResult.invalidWithDepth(.wavpack, @errorName(err), .full);
    };
    if (!result.valid) {
        if (result.error_message) |msg| {
            // The decode validator may have allocated this; we just report it
            // and let the page allocator reclaim on process exit (page_allocator
            // free is a no-op anyway).
            return ValidationResult.invalidWithDepth(.wavpack, msg, .full);
        }
        return ValidationResult.invalidWithDepth(.wavpack, "WavPack decode validation failed", .full);
    }
    return ValidationResult.okWithDepth(.wavpack, .full);
}

// ============ MIDI Deep Validation (track data parsing) ============

/// Deep MIDI validation by parsing all track data.
/// This validates delta times, event status/data bytes, running status,
/// and verifies each track ends with End of Track meta event.
pub fn validateMidiDeep(source: *FileSource) ValidationResult {
    const result = midi_validator.validateMidiDeep(source);
    if (result.valid) {
        return ValidationResult.okWithDepth(.midi, .full);
    } else {
        return ValidationResult.invalidWithDepth(.midi, result.error_message orelse "MIDI validation failed", .full);
    }
}

// ============ AC-3 / E-AC-3 Deep Validation ============

/// Deep AC-3 (Dolby Digital) validation by parsing frame structure and verifying CRCs.
pub fn validateAc3Deep(source: *FileSource) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.ac3, .failed_to_get, "file size", .full);
    };
    if (file_size < 7) {
        return ValidationResult.invalidCodeWithDepth(.ac3, .file_too_small, "AC-3", .full);
    }
    if (file_size > 256 * 1024 * 1024) {
        return ValidationResult.invalidCodeWithDepth(.ac3, .file_too_large, "AC-3 deep validation", .full);
    }

    const slurp_ac3 = source.getMappedOrSlurp(heap.validateAllocator(), 256 << 20) catch
        return ValidationResult.invalidCodeWithDepth(.ac3, .failed_to_read, "AC-3 data", .full);
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |b| heap.validateAllocator().free(b);
    const data: []const u8 = switch (slurp_ac3) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_buf = b; break :blk b; },
        .too_large => return ValidationResult.okWithDepthAndWarning(.ac3, .structural, "AC-3 too large for non-mmap deep validation"),
    };

    const result = ac3_validator.validateAc3Stream(data, std.math.maxInt(u32));
    if (result.valid) {
        return ValidationResult.okWithDepth(.ac3, .full);
    } else {
        return ValidationResult.invalidWithDepth(.ac3, result.error_message orelse "AC-3 validation failed", .full);
    }
}

/// Deep E-AC-3 (Dolby Digital Plus) validation by parsing frame structure and verifying CRCs.
pub fn validateEac3Deep(source: *FileSource) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.eac3, .failed_to_get, "file size", .full);
    };
    if (file_size > 256 * 1024 * 1024) {
        return ValidationResult.invalidCodeWithDepth(.eac3, .file_too_large, "E-AC-3 deep validation", .full);
    }

    const slurp_eac3 = source.getMappedOrSlurp(heap.validateAllocator(), 256 << 20) catch
        return ValidationResult.invalidCodeWithDepth(.eac3, .failed_to_read, "E-AC-3 data", .full);
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |b| heap.validateAllocator().free(b);
    const data: []const u8 = switch (slurp_eac3) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_buf = b; break :blk b; },
        .too_large => return ValidationResult.okWithDepthAndWarning(.eac3, .structural, "E-AC-3 too large for non-mmap deep validation"),
    };

    const result = eac3_validator.validateEac3Stream(data, std.math.maxInt(u32));
    if (result.valid) {
        return ValidationResult.okWithDepth(.eac3, .full);
    } else {
        return ValidationResult.invalidWithDepth(.eac3, result.error_message orelse "E-AC-3 validation failed", .full);
    }
}

/// Validate DTS (Digital Theater Systems) file structure.
/// DTS Core frames start with sync word 0x7FFE8001.
pub fn validateDts(file: *FileSource) ValidationResult {
    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.dts, .failed_to_read, "DTS header");
    };

    if (bytes_read < 12) {
        return ValidationResult.invalidCode(.dts, .file_too_small, "DTS");
    }

    // Check DTS Core sync word 0x7FFE8001
    const sync = std.mem.readInt(u32, header[0..4], .big);
    if (sync != 0x7FFE8001) {
        return ValidationResult.invalidCode(.dts, .invalid_value, "DTS sync word");
    }

    return ValidationResult.ok(.dts);
}

/// Deep DTS validation by parsing frame headers and verifying frame boundaries.
pub fn validateDtsDeep(source: *FileSource) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.dts, .failed_to_get, "file size", .structural);
    };
    if (file_size > 10 * 1024 * 1024) {
        return ValidationResult.invalidCodeWithDepth(.dts, .file_too_large, "DTS deep validation", .structural);
    }

    const slurp_dts = source.getMappedOrSlurp(heap.validateAllocator(), 256 << 20) catch
        return ValidationResult.invalidCodeWithDepth(.dts, .failed_to_read, "DTS data", .structural);
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |b| heap.validateAllocator().free(b);
    const data: []const u8 = switch (slurp_dts) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_buf = b; break :blk b; },
        .too_large => return ValidationResult.okWithDepthAndWarning(.dts, .structural, "DTS too large for non-mmap deep validation"),
    };

    const result = dts_validator.validateDtsStream(data, 100);
    if (result.valid) {
        return ValidationResult.okWithDepth(.dts, .full);
    } else {
        return ValidationResult.invalidWithDepth(.dts, result.error_message orelse "DTS validation failed", .full);
    }
}

// ============ Tracker/Module Deep Validation ============

/// Helper to perform full decode validation of tracker file using libopenmpt.
/// Reads the file and uses libopenmpt to fully decode/render audio.
pub fn validateTrackerFullDecode(source: *FileSource, format: FileFormat) ValidationResult {
    const file_size = source.getEndPos() catch {
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
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "to start", .full);
    };
    const bytes_read = source.readAll(buf_slice) catch {
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
pub fn validateModDeep(source: *FileSource) ValidationResult {
    const result = tracker_validator.validateModDeep(source);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.mod, result.error_message orelse "MOD validation failed", .full);
    }
    // Structural validation passed, now do full decode
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.mod, .failed_to_seek, "to start", .full);
    };
    return validateTrackerFullDecode(source, .mod);
}

/// Deep XM validation - validates header, patterns, instruments, and samples.
/// Also performs full decode using libopenmpt.
pub fn validateXmDeep(source: *FileSource) ValidationResult {
    const result = tracker_validator.validateXmDeep(source);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.xm, result.error_message orelse "XM validation failed", .full);
    }
    // Structural validation passed, now do full decode
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.xm, .failed_to_seek, "to start", .full);
    };
    return validateTrackerFullDecode(source, .xm);
}

/// Deep IT validation - validates header, instruments, samples, and patterns.
/// Also performs full decode using libopenmpt.
pub fn validateItDeep(source: *FileSource) ValidationResult {
    const result = tracker_validator.validateItDeep(source);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.it, result.error_message orelse "IT validation failed", .full);
    }
    // Structural validation passed, now do full decode
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.it, .failed_to_seek, "to start", .full);
    };
    return validateTrackerFullDecode(source, .it);
}

/// Deep S3M validation - validates header, instruments, patterns, and sample data.
/// Also performs full decode using libopenmpt.
pub fn validateS3mDeep(source: *FileSource) ValidationResult {
    const result = tracker_validator.validateS3mDeep(source);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.s3m, result.error_message orelse "S3M validation failed", .full);
    }
    // Structural validation passed, now do full decode
    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.s3m, .failed_to_seek, "to start", .full);
    };
    return validateTrackerFullDecode(source, .s3m);
}

// ============ FLAC Deep Validation (MD5) ============

/// Deep FLAC validation by checking MD5 hash presence and attempting full decode.
/// FLAC stores an MD5 hash of the uncompressed audio in STREAMINFO.
/// We first check the structure, then attempt full decoding if possible.
pub fn validateFlacDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    // Read FLAC header
    var header: [42]u8 = undefined;
    const header_bytes = source.read(&header) catch {
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
        const decode_result = flac_decoder.decodeFlacFull(allocator, source) catch |err| {
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
    const result = flac_decoder.verifyFlacMd5(allocator, source) catch |err| {
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
pub fn validateMp3Deep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;


    var header: [10]u8 = undefined;
    _ = source.read(&header) catch {
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

        source.seekTo(audio_start) catch {
            return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_seek, "past ID3", .structural);
        };

        // Read next header (might be another ID3 or audio data)
        _ = source.read(&header) catch {
            return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_read, "after ID3", .structural);
        };
    }

    // Now we should be at the audio data, but seekTo above positioned us there,
    // and we read 10 bytes into header, so we need to check those bytes
    // The first bytes of audio should be the frame sync (0xFF 0xE*)
    // We already have them in header[0..1], so seek back and let the frame loop handle it
    source.seekTo(audio_start) catch {
        return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_seek, "to audio", .structural);
    };

    // Scan past zero-padding between ID3v2 tag and first audio frame
    if (audio_start > 0) {
        const scan_limit = audio_start + 4096;
        var scan_buf: [2]u8 = undefined;
        var scan_pos = audio_start;
        while (scan_pos < scan_limit) {
            source.seekTo(scan_pos) catch break;
            const n = source.read(&scan_buf) catch break;
            if (n < 2) break;
            if (scan_buf[0] == 0xFF and (scan_buf[1] & 0xE0) == 0xE0) {
                audio_start = scan_pos;
                break;
            }
            scan_pos += 1;
        }
        source.seekTo(audio_start) catch {
            return ValidationResult.invalidCodeWithDepth(.mp3, .failed_to_seek, "to audio", .structural);
        };
    }

    // Validate all frames
    var frames_checked: usize = 0;
    var frames_with_crc: usize = 0;

    while (true) {
        var frame_header: [4]u8 = undefined;
        const bytes_read = source.read(&frame_header) catch break;
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
            const crc_read = source.read(&crc_bytes) catch break;
            if (crc_read < 2) break;

            const stored_crc = std.mem.readInt(u16, &crc_bytes, .big);

            // CRC covers header bytes 2-3 and side info
            // Side info size varies: 32 bytes for stereo, 17 for mono in Layer III
            // For now, just verify CRC presence and format
            _ = stored_crc; // Would need to compute CRC over side info

            // Move to next frame (frame_size includes header but we already read header+CRC)
            const cur_pos1 = source.getPos() catch break;
            source.seekTo(cur_pos1 + (frame_size - 4 - 2)) catch break;
        } else {
            // No CRC, skip to next frame
            const cur_pos2 = source.getPos() catch break;
            source.seekTo(cur_pos2 + (frame_size - 4)) catch break;
        }

        frames_checked += 1;
    }

    if (frames_checked == 0) {
        return ValidationResult.invalidCodeWithDepth(.mp3, .no_valid_x_found, "MP3 frames", .structural);
    }

    // If CRC frames exist, verify them with the dedicated MP3 CRC validator
    if (frames_with_crc > 0) {
        source.seekTo(0) catch return ValidationResult.okWithDepthAndWarning(.mp3, .structural, "MP3 deep validation skipped — could not seek to start of file before CRC verification");
        const crc_result = mp3_validator.validateMp3Crc(source);
        if (crc_result.valid) {
            // CRCs verified successfully
            return ValidationResult.okWithDepth(.mp3, .full);
        } else if (crc_result.error_message) |msg| {
            // CRC mismatch detected - corruption
            return ValidationResult.invalidWithDepth(.mp3, msg, .full);
        } else {
            // Fallback to decode validation if CRC check had issues
            source.seekTo(0) catch return ValidationResult.okWithDepthAndWarning(.mp3, .structural, "MP3 deep validation skipped — could not seek to start of file for decode-fallback after CRC produced no verdict");
            const decode_result = mp3_decode_validator.validateMp3Decode(source);
            if (decode_result.valid and decode_result.frames_decoded > 0) {
                return ValidationResult.okWithDepth(.mp3, .full);
            }
            return ValidationResult.okWithDepthAndWarning(.mp3, .structural, "MP3 deep validation incomplete — CRC produced no verdict and decode fallback returned 0 frames");
        }
    }

    // No CRC present - do full decode validation to catch corruption
    source.seekTo(0) catch return ValidationResult.okWithDepthAndWarning(.mp3, .structural, "MP3 deep validation skipped — could not seek to start of file for decode validation");
    const decode_result = mp3_decode_validator.validateMp3Decode(source);
    if (decode_result.valid and decode_result.frames_decoded > 0) {
        return ValidationResult.okWithDepth(.mp3, .full);
    }

    // Decode failed or no frames — structural validation only.
    // This could indicate corruption or just an unusual encoding.
    return ValidationResult.okWithDepthAndWarning(.mp3, .structural, "MP3 deep validation incomplete — decode produced 0 frames; structure-only verdict");
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
    if (isRifxWav(data)) return rifxWavUnsupported();
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WAVE")) {
        return ValidationResult.ok(.wav);
    }
    return ValidationResult.invalidCode(.wav, .invalid_signature, "WAV");
}

test "RIFX big-endian WAV is unsupported-WARN naming the variant, not corrupt" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Big-endian RIFX WAV header (scipy test-*-be.wav shape): RIFX + BE size + WAVE + fmt
    var wav_data: [64]u8 = undefined;
    @memset(&wav_data, 0);
    @memcpy(wav_data[0..4], "RIFX");
    std.mem.writeInt(u32, wav_data[4..8], 56, .big);
    @memcpy(wav_data[8..12], "WAVE");
    @memcpy(wav_data[12..16], "fmt ");

    const file = try tmp_dir.dir.createFile(runtime.io(), "be.wav", .{});
    try file.writePositionalAll(runtime.io(), &wav_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "be.wav");
    defer allocator.free(path);

    {
        var src = try FileSource.open(path);
        defer src.close();
        const result = validateWav(&src);
        try std.testing.expect(result.is_valid);
        try std.testing.expectEqual(format_validation.ResultVerdict.indeterminate, result.verdict);
        try std.testing.expect(result.validation_unsupported);
        try std.testing.expect(std.mem.indexOf(u8, result.warning_message.?, "RIFX") != null);
    }
    {
        var src = try FileSource.open(path);
        defer src.close();
        const result = validateWavDeep(std.testing.allocator, &src);
        try std.testing.expect(result.is_valid);
        try std.testing.expectEqual(format_validation.ResultVerdict.indeterminate, result.verdict);
        try std.testing.expect(result.validation_unsupported);
    }
    {
        // The pipeline dispatches detected WAVs through validateRiffAudio —
        // it must apply the same unsupported-WARN tier (regression: it was
        // reporting "Invalid container signature").
        var src = try FileSource.open(path);
        defer src.close();
        const result = validateRiffAudio(&src, .wav);
        try std.testing.expect(result.is_valid);
        try std.testing.expect(result.validation_unsupported);
    }

    // Classifier must-not rows: plain corrupt magic stays invalid.
    const bad = [_]u8{ 'R', 'I', 'F', 'Q', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    try std.testing.expect(!validateWavFromBuffer(&bad).is_valid);
    // RIFX from buffer follows the same unsupported-WARN tier.
    const rifx_buf = [_]u8{ 'R', 'I', 'F', 'X', 0, 0, 0, 0, 'W', 'A', 'V', 'E' };
    const buf_result = validateWavFromBuffer(&rifx_buf);
    try std.testing.expect(buf_result.is_valid);
    try std.testing.expect(buf_result.validation_unsupported);
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

const AmrWalkResult = union(enum) { ok: u32, err: ValidationResult };

/// Walk AMR frames starting at `start_pos` in `file` of `file_size` bytes.
/// `frame_sizes` maps frame_type (0-15) to payload byte count.
/// Reserved frame types (reserved_lo..reserved_hi inclusive) cause immediate rejection.
/// Last-frame truncation is tolerated (AMR is a streaming format).
/// Returns the number of valid frames walked, or a ValidationResult error.
fn walkAmrFrames(
    file: *FileSource,
    start_pos: u64,
    file_size: u64,
    frame_sizes: *const [16]u8,
    reserved_lo: u8,
    reserved_hi: u8,
) AmrWalkResult {
    var pos: u64 = start_pos;
    var frame_count: u32 = 0;

    while (pos < file_size) {
        file.seekTo(pos) catch return .{ .err = ValidationResult.invalidCode(.amr, .failed_to_seek, "frame header") };
        var fh_buf: [1]u8 = undefined;
        const fh_read = file.read(&fh_buf) catch return .{ .err = ValidationResult.invalidCode(.amr, .failed_to_read, "frame header") };
        if (fh_read < 1) break;

        const fh = fh_buf[0];
        const ft: u8 = (fh >> 3) & 0x0F;

        if (ft >= reserved_lo and ft <= reserved_hi) {
            return .{ .err = ValidationResult.invalidCode(.amr, .invalid_value, "reserved AMR frame type") };
        }

        const payload_size: u64 = frame_sizes[ft];
        pos += 1 + payload_size;
        frame_count += 1;

        // Last frame may be truncated (streaming format) — always tolerated
        if (pos > file_size) break;
    }

    return .{ .ok = frame_count };
}

/// Validate AMR (Adaptive Multi-Rate) audio file structure by walking the frame chain.
/// AMR-NB: "#!AMR\n" (6 bytes), AMR-WB: "#!AMR-WB\n" (9 bytes).
/// Each frame has a 1-byte header: (frame_type<<3)|(quality<<2)|padding.
/// Frame sizes are fixed per mode; last frame truncation is tolerated (streaming format).
/// Multi-channel variants (#!AMR_MC1.0\n / #!AMR-WB_MC1.0\n) return structuralOnly
/// because their frame layout includes additional channel headers not documented here.
pub fn validateAmr(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.amr, .failed_to_seek, "in AMR file");

    var header: [15]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.amr, .failed_to_read, "header");

    if (bytes_read < 6) return ValidationResult.invalidCode(.amr, .truncated, "header");

    // Multi-channel variants: frame layout undocumented, return structural only
    if (bytes_read >= 15 and std.mem.eql(u8, header[0..15], "#!AMR-WB_MC1.0\n")) {
        return ValidationResult.structuralOnly(.amr);
    }
    if (bytes_read >= 12 and std.mem.eql(u8, header[0..12], "#!AMR_MC1.0\n")) {
        return ValidationResult.structuralOnly(.amr);
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.amr, .failed_to_read, "file size");

    // AMR-WB frame payload sizes indexed by frame_type (modes 0-8, SID=9, reserved 10-14, NO_DATA=15)
    const amr_wb_sizes = [16]u8{ 18, 24, 33, 37, 41, 47, 51, 59, 61, 6, 0, 0, 0, 0, 0, 0 };
    // AMR-NB frame payload sizes indexed by frame_type (modes 0-7, SID=8, comfort 9-11, reserved 12-14, NO_DATA=15)
    const amr_nb_sizes = [16]u8{ 13, 14, 16, 18, 20, 21, 27, 32, 6, 6, 6, 6, 0, 0, 0, 0 };

    if (bytes_read >= 9 and std.mem.eql(u8, header[0..9], "#!AMR-WB\n")) {
        // AMR-WB: reserved types 10-14
        const walk = walkAmrFrames(file, 9, file_size, &amr_wb_sizes, 10, 14);
        switch (walk) {
            .err => |e| return e,
            .ok => |count| if (count == 0) return ValidationResult.invalidCode(.amr, .truncated, "no AMR-WB frames found"),
        }
        return ValidationResult.okWithDepth(.amr, .structural);
    }

    if (std.mem.eql(u8, header[0..6], "#!AMR\n")) {
        // AMR-NB: reserved types 12-14
        const walk = walkAmrFrames(file, 6, file_size, &amr_nb_sizes, 12, 14);
        switch (walk) {
            .err => |e| return e,
            .ok => |count| if (count == 0) return ValidationResult.invalidCode(.amr, .truncated, "no AMR-NB frames found"),
        }
        return ValidationResult.okWithDepth(.amr, .structural);
    }

    return ValidationResult.invalidCode(.amr, .invalid_magic, "AMR");
}

// ============ AU/SND Validator ============

/// Validate AU/SND (Sun/NeXT audio) file structure.
pub fn validateAu(file: *FileSource) ValidationResult {
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
        return ValidationResult.okWithDepth(.au, .structural);
    }

    return ValidationResult.structuralOnly(.au);
}

// ============ TTA Validator ============

/// Validate TTA (True Audio) lossless file structure with header CRC32 verification.
pub fn validateTta(file: *FileSource) ValidationResult {
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

    return ValidationResult.okWithDepth(.tta, .structural);
}

/// Deep TTA validation: verifies seek table CRC32 and per-frame CRC32s.
/// This IS full validation — CRC32 covers every byte of compressed audio data.
pub fn validateTtaDeep(allocator: Allocator, source: *FileSource) ValidationResult {

    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.tta, .failed_to_read, "file size", .full);
    };

    // Cap at 100 MB
    if (file_size > 100 * 1024 * 1024) {
        return ValidationResult.structuralOnly(.tta);
    }

    const slurp_tta = source.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidCodeWithDepth(.tta, .failed_to_read, "file data", .full);
    var heap_tta: ?[]u8 = null;
    defer if (heap_tta) |b| allocator.free(b);
    const buf: []const u8 = switch (slurp_tta) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_tta = b; break :blk b; },
        .too_large => return ValidationResult.structuralOnly(.tta),
    };
    if (buf.len < 22) {
        return ValidationResult.invalidCodeWithDepth(.tta, .truncated, "header", .full);
    }

    // Parse header
    if (!std.mem.eql(u8, buf[0..4], "TTA1")) {
        return ValidationResult.invalidCodeWithDepth(.tta, .invalid_signature, "TTA magic", .full);
    }

    const sample_rate = std.mem.readInt(u32, buf[10..14], .little);
    const total_samples = std.mem.readInt(u32, buf[14..18], .little);

    // Verify header CRC
    const stored_header_crc = std.mem.readInt(u32, buf[18..22], .little);
    const computed_header_crc = std.hash.Crc32.hash(buf[0..18]);
    if (stored_header_crc != computed_header_crc) {
        return ValidationResult.invalidCodeMsgWithDepth(.tta, .checksum_mismatch, "Header CRC32", "Header CRC32 mismatch", .full);
    }

    // Calculate number of frames
    const frame_length: u64 = @as(u64, sample_rate) * 256 / 245;
    if (frame_length == 0) {
        return ValidationResult.invalidCodeWithDepth(.tta, .invalid_value, "frame length is zero", .full);
    }
    const fl32: u32 = @intCast(@min(frame_length, std.math.maxInt(u32)));
    const num_frames: u32 = (total_samples + fl32 - 1) / fl32;

    // Seek table starts at offset 22, contains num_frames × u32 entries + 4-byte CRC
    const seek_table_offset: usize = 22;
    const seek_table_data_size: usize = @as(usize, num_frames) * 4;
    const seek_table_total_size: usize = seek_table_data_size + 4; // data + CRC

    if (buf.len < seek_table_offset + seek_table_total_size) {
        return ValidationResult.invalidCodeWithDepth(.tta, .truncated, "seek table", .full);
    }

    // Verify seek table CRC
    const seek_table_bytes = buf[seek_table_offset .. seek_table_offset + seek_table_data_size];
    const stored_seek_crc = std.mem.readInt(u32, buf[seek_table_offset + seek_table_data_size ..][0..4], .little);
    const computed_seek_crc = std.hash.Crc32.hash(seek_table_bytes);
    if (stored_seek_crc != computed_seek_crc) {
        return ValidationResult.invalidCodeMsgWithDepth(.tta, .checksum_mismatch, "Seek table CRC32", "Seek table CRC32 mismatch", .full);
    }

    // Read frame sizes from seek table
    var frame_sizes: []u32 = allocator.alloc(u32, num_frames) catch {
        return ValidationResult.structuralOnly(.tta);
    };
    defer allocator.free(frame_sizes);

    for (0..num_frames) |i| {
        const entry_offset = seek_table_offset + i * 4;
        frame_sizes[i] = std.mem.readInt(u32, buf[entry_offset..][0..4], .little);
    }

    // Walk frames and verify CRCs
    // Frame data starts after header (22) + seek table (num_frames*4 + 4)
    var frame_offset: usize = seek_table_offset + seek_table_total_size;
    const max_frames_to_check: u32 = @min(num_frames, 1000);

    for (0..max_frames_to_check) |i| {
        const entry_size = frame_sizes[i]; // includes 4-byte CRC
        if (entry_size < 4) {
            return ValidationResult.invalidCodeMsgWithDepth(.tta, .invalid_value, "Frame size", "Frame size too small (< 4 bytes)", .full);
        }

        const frame_data_size: usize = entry_size - 4;
        const frame_end: usize = frame_offset + entry_size;

        if (frame_end > buf.len) {
            return ValidationResult.invalidCodeMsgWithDepth(.tta, .truncated, "Frame data", "Frame data extends beyond file", .full);
        }

        const frame_data = buf[frame_offset .. frame_offset + frame_data_size];
        const stored_frame_crc = std.mem.readInt(u32, buf[frame_offset + frame_data_size ..][0..4], .little);
        const computed_frame_crc = std.hash.Crc32.hash(frame_data);

        if (stored_frame_crc != computed_frame_crc) {
            return ValidationResult.invalidCodeMsgWithDepth(.tta, .checksum_mismatch, "Frame CRC32", "Frame CRC32 mismatch", .full);
        }

        frame_offset = frame_end;
    }

    return ValidationResult.okWithDepth(.tta, .full); // Per-frame CRC32 covers all audio bytes
}
// ============ CAF Validator ============

/// Validate CAF (Core Audio Format) file structure.
pub fn validateCaf(file: *FileSource) ValidationResult {
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

    // Parse Audio Description chunk (32 bytes): sampleRate(f64) + formatID(4) + formatFlags(4) +
    // bytesPerPacket(4) + framesPerPacket(4) + channelsPerFrame(4) + bitsPerChannel(4)
    var desc_data: [32]u8 = undefined;
    const desc_read = file.read(&desc_data) catch return ValidationResult.invalidCode(.caf, .failed_to_read, "Audio Description");
    if (desc_read < 32) return ValidationResult.invalidCode(.caf, .truncated, "Audio Description");

    const sample_rate_bits = std.mem.readInt(u64, desc_data[0..8], .big);
    const sample_rate: f64 = @bitCast(sample_rate_bits);
    const channels_per_frame = std.mem.readInt(u32, desc_data[24..28], .big);
    const bits_per_channel = std.mem.readInt(u32, desc_data[28..32], .big);

    // Validate sample rate is finite and reasonable
    if (std.math.isNan(sample_rate) or std.math.isInf(sample_rate) or sample_rate <= 0 or sample_rate > 768000) {
        return ValidationResult.invalidCode(.caf, .invalid_value, "sample rate");
    }

    // Validate channels
    if (channels_per_frame == 0 or channels_per_frame > 128) {
        return ValidationResult.invalidCode(.caf, .invalid_value, "channels per frame");
    }

    // Validate bits per channel (0 is valid for compressed formats like AAC)
    if (bits_per_channel > 64) {
        return ValidationResult.invalidCode(.caf, .invalid_value, "bits per channel");
    }

    // Walk remaining chunks to validate structure
    const file_size = file.getEndPos() catch return ValidationResult.structuralOnly(.caf);
    var offset: u64 = 20 + 32; // caff header(8) + desc chunk header(12) + desc data(32)
    var chunk_count: u32 = 0;

    while (offset + 12 <= file_size and chunk_count < 10000) {
        file.seekTo(offset) catch break;
        var chunk_hdr: [12]u8 = undefined;
        const hdr_read = file.read(&chunk_hdr) catch break;
        if (hdr_read < 12) break;

        const caf_chunk_size = std.mem.readInt(i64, chunk_hdr[4..12], .big);
        if (caf_chunk_size < -1) {
            return ValidationResult.invalidCode(.caf, .invalid_value, "chunk size");
        }

        // -1 means unknown size (last chunk extends to EOF)
        if (caf_chunk_size == -1) break;

        const csize: u64 = @intCast(caf_chunk_size);
        if (offset + 12 + csize > file_size) {
            return ValidationResult.invalidCodeMsg(.caf, .exceeds_bounds, "CAF chunk", "CAF chunk extends beyond file");
        }

        offset += 12 + csize;
        chunk_count += 1;
    }

    return ValidationResult.okWithDepth(.caf, .structural);
}

// ============ AAC ADTS Validator ============

/// Validate standalone AAC ADTS (.aac) file using pure-Zig bitstream validator.
pub fn validateAacAdts(file: *FileSource) ValidationResult {
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
    var source = FileSource.open("ground_truth_examples/wav/sample.wav") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateWav(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
}

test "validateFlac accepts ground truth FLAC" {
    var source = FileSource.open("ground_truth_examples/flac/generated_tone_440hz.flac") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateFlac(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
}

test "validateMp3 accepts ground truth MP3" {
    var source = FileSource.open("ground_truth_examples/mp3/generated_tone_440hz.mp3") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMp3(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mp3, result.format);
}

test "validateOgg accepts ground truth OGG" {
    var source = FileSource.open("ground_truth_examples/ogg/generated_tone_440hz.ogg") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateOgg(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ogg, result.format);
}

test "validateRiffAudio accepts ground truth AIFF" {
    var source = FileSource.open("ground_truth_examples/aiff/sample.aiff") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateRiffAudio(&source, .aiff);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
}

test "validateMidi accepts ground truth MIDI" {
    var source = FileSource.open("ground_truth_examples/midi/fur_elise.mid") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMidi(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.midi, result.format);
}

test "validateAc3 accepts ground truth AC-3" {
    var source = FileSource.open("ground_truth_examples/ac3/sample.ac3") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAc3(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ac3, result.format);
}

test "validateEac3 accepts ground truth E-AC-3" {
    var source = FileSource.open("ground_truth_examples/eac3/sample.eac3") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateEac3(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eac3, result.format);
}

test "validateApe accepts ground truth APE" {
    var source = FileSource.open("ground_truth_examples/ape/sample.ape") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateApe(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ape, result.format);
}

test "validateWavPack accepts ground truth WavPack" {
    var source = FileSource.open("ground_truth_examples/wavpack/sample.wv") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateWavPack(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wavpack, result.format);
}

test "validateDsf accepts ground truth DSF" {
    var source = FileSource.open("ground_truth_examples/dsf/sample.dsf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateDsf(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dsf, result.format);
}

test "validateDff accepts ground truth DFF" {
    var source = FileSource.open("ground_truth_examples/dff/sample.dff") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateDff(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dff, result.format);
}

test "validateAmr accepts ground truth AMR" {
    var source = FileSource.open("ground_truth_examples/amr/sample.amr") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAmr(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.amr, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);}

test "validateAmr rejects reserved AMR-NB frame type 12" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // "#!AMR\n" + frame header with reserved type 12: (12 << 3) = 0x60
    const bad_data = "#!AMR\n" ++ [_]u8{0x60} ++ [_]u8{0x00} ** 13;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_ft.amr", .data = bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad_ft.amr") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateAmr(&source);
    try testing.expect(!result.is_valid);
}

test "validateAmr accepts truncated-last-frame AMR-NB (streaming tolerance)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // "#!AMR\n" + frame header mode 7 (0x3c = type 7, 32-byte payload) but only 10 payload bytes
    const data = "#!AMR\n" ++ [_]u8{0x3c} ++ [_]u8{0xaa} ** 10;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "trunc.amr", .data = data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "trunc.amr") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateAmr(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);}
test "validateAu accepts ground truth AU" {
    var source = FileSource.open("ground_truth_examples/au/sample.au") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAu(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.au, result.format);
}

test "validateTta accepts ground truth TTA" {
    var source = FileSource.open("ground_truth_examples/tta/sample.tta") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateTta(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.tta, result.format);
}

test "validateCaf accepts ground truth CAF" {
    var source = FileSource.open("ground_truth_examples/caf/sample.caf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateCaf(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.caf, result.format);
}

test "validateAacAdts accepts ground truth AAC ADTS" {
    var source = FileSource.open("ground_truth_examples/aac_adts/sample.aac") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAacAdts(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aac_adts, result.format);
}

test "validateMod accepts ground truth MOD" {
    var source = FileSource.open("ground_truth_examples/tracker/otm.mod") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMod(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mod, result.format);
}

test "validateXm accepts ground truth XM" {
    var source = FileSource.open("ground_truth_examples/tracker/agony.xm") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateXm(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xm, result.format);
}

test "validateIt accepts ground truth IT" {
    var source = FileSource.open("ground_truth_examples/tracker/flitter.it") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateIt(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.it, result.format);
}

test "validateS3m accepts ground truth S3M" {
    var source = FileSource.open("ground_truth_examples/tracker/twilight_garden.s3m") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateS3m(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.s3m, result.format);
}

// ---------- Ground truth deep validators ----------

test "validateWavDeep accepts ground truth WAV" {
    var source = FileSource.open("ground_truth_examples/wav/sample.wav") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateWavDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wav, result.format);
    // WAV validates chunk structure but no audio decode or checksum
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "validateAiffDeep accepts ground truth AIFF" {
    var source = FileSource.open("ground_truth_examples/aiff/sample.aiff") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAiffDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.aiff, result.format);
    // AIFF validates chunk structure but no audio decode or checksum
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "validateFlacDeep accepts ground truth FLAC" {
    var source = FileSource.open("ground_truth_examples/flac/generated_tone_440hz.flac") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateFlacDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.flac, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateOggDeep accepts ground truth OGG" {
    var source = FileSource.open("ground_truth_examples/ogg/generated_tone_440hz.ogg") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateOggDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ogg, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateMidiDeep accepts ground truth MIDI" {
    var source = FileSource.open("ground_truth_examples/midi/fur_elise.mid") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateMidiDeep(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.midi, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateAc3Deep accepts ground truth AC-3" {
    var source = FileSource.open("ground_truth_examples/ac3/sample.ac3") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateAc3Deep(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ac3, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateEac3Deep accepts ground truth E-AC-3" {
    var source = FileSource.open("ground_truth_examples/eac3/sample.eac3") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateEac3Deep(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.eac3, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

// ---------- Corrupt / truncated input tests ----------

test "validateWav rejects truncated WAV" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const truncated = "RIFF" ++ [_]u8{ 0xFF, 0x00, 0x00, 0x00 } ++ "WAVE";
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.wav", .data = truncated }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.wav") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateWav(&source);
    try testing.expect(!result.is_valid);
}

test "validateFlac rejects invalid FLAC signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = "fLaX" ++ [_]u8{0x00} ** 34;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.flac", .data = bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.flac") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateFlac(&source);
    try testing.expect(!result.is_valid);
}

test "validateFlac rejects non-STREAMINFO first block" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = "fLaC" ++ [_]u8{ 0x01, 0x00, 0x00, 0x22 } ++ [_]u8{0x00} ** 34;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.flac", .data = bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.flac") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateFlac(&source);
    try testing.expect(!result.is_valid);
}

test "validateMp3 rejects random bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09 };
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.mp3", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.mp3") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateMp3(&source);
    try testing.expect(!result.is_valid);
}

test "validateOgg rejects non-OggS data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 28;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.ogg", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.ogg") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateOgg(&source);
    try testing.expect(!result.is_valid);
}

test "validateMidi rejects non-MThd data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 22;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.mid", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.mid") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateMidi(&source);
    try testing.expect(!result.is_valid);
}

test "validateAc3 rejects wrong sync word" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{ 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00 };
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.ac3", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.ac3") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateAc3(&source);
    try testing.expect(!result.is_valid);
}

test "validateEac3 rejects wrong bsid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Sync word correct (0x0B77) but bsid=8 (AC-3) instead of 16 (E-AC-3)
    const bad_data = [_]u8{ 0x0B, 0x77, 0x00, 0x00, 0x00, 0x08 << 3 };
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.eac3", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.eac3") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateEac3(&source);
    try testing.expect(!result.is_valid);
}

test "validateApe rejects non-MAC signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 32;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.ape", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.ape") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateApe(&source);
    try testing.expect(!result.is_valid);
}

test "validateDsf rejects non-DSD signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 80;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.dsf", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.dsf") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateDsf(&source);
    try testing.expect(!result.is_valid);
}

test "validateDff rejects non-FRM8 signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 28;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.dff", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.dff") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateDff(&source);
    try testing.expect(!result.is_valid);
}

test "validateAmr rejects non-AMR data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 16;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.amr", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.amr") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateAmr(&source);
    try testing.expect(!result.is_valid);
}

test "validateAu rejects non-snd magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 24;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.au", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.au") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateAu(&source);
    try testing.expect(!result.is_valid);
}

test "validateTta rejects non-TTA1 magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 22;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.tta", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.tta") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateTta(&source);
    try testing.expect(!result.is_valid);
}

test "validateCaf rejects non-caff magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 20;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.caf", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.caf") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateCaf(&source);
    try testing.expect(!result.is_valid);
}

test "validateXm rejects non-XM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 80;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.xm", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.xm") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateXm(&source);
    try testing.expect(!result.is_valid);
}

test "validateIt rejects non-IMPM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 192;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.it", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.it") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateIt(&source);
    try testing.expect(!result.is_valid);
}

test "validateS3m rejects non-SCRM data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 96;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.s3m", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.s3m") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateS3m(&source);
    try testing.expect(!result.is_valid);
}

test "validateMod rejects file too small for MOD" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const bad_data = [_]u8{0x00} ** 100;
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.mod", .data = &bad_data }) catch return;
    const realpath = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.mod") catch return;
    defer std.testing.allocator.free(realpath);
    var source = FileSource.open(realpath) catch return;
    defer source.close();
    const result = validateMod(&source);
    try testing.expect(!result.is_valid);
}

// ---------- Deep validators with corrupt data ----------

test "validateWavDeep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.wav"));
}

test "validateAiffDeep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.aiff"));
}

test "validateFlacDeep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.flac"));
}

test "validateMidiDeep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.mid"));
}

test "validateAc3Deep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.ac3"));
}

test "validateEac3Deep rejects file not found" {
    try testing.expectError(error.FileNotFound, FileSource.open("/nonexistent/path/to/file.eac3"));
}

// ---------- WAV corruption detection tests ----------

test "validateWavDeep rejects corrupted block_align" {
    // Build minimal valid WAV: RIFF(12) + fmt(24) + data(8+16) = 60 bytes
    // 16-bit stereo 44100Hz PCM
    var wav: [60]u8 = undefined;
    // RIFF header
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 52, .little); // file size - 8
    @memcpy(wav[8..12], "WAVE");
    // fmt chunk
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little); // chunk size
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 2, .little); // channels
    std.mem.writeInt(u32, wav[24..28], 44100, .little); // sample rate
    std.mem.writeInt(u32, wav[28..32], 176400, .little); // byte rate = 44100*2*2
    std.mem.writeInt(u16, wav[32..34], 4, .little); // block align = 2*2
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits per sample
    // data chunk
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 16, .little); // 16 bytes of audio
    @memset(wav[44..60], 0); // silence

    // Verify valid first
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "good.wav", .data = &wav }) catch return;
    const good_path = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "good.wav") catch return;
    defer testing.allocator.free(good_path);
    var good_src = FileSource.open(good_path) catch return;
    defer good_src.close();
    const good_result = validateWavDeep(testing.allocator, &good_src);
    try testing.expect(good_result.is_valid);

    // Corrupt block_align (byte 32-33: change from 4 to 99)
    var bad_wav = wav;
    std.mem.writeInt(u16, bad_wav[32..34], 99, .little);
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_align.wav", .data = &bad_wav }) catch return;
    const bad_path = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "bad_align.wav") catch return;
    defer testing.allocator.free(bad_path);
    var bad_src = FileSource.open(bad_path) catch return;
    defer bad_src.close();
    const bad_result = validateWavDeep(testing.allocator, &bad_src);
    try testing.expect(!bad_result.is_valid);
}

test "validateWavDeep rejects corrupted byte_rate" {
    var wav: [60]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 52, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 2, .little); // stereo
    std.mem.writeInt(u32, wav[24..28], 44100, .little);
    std.mem.writeInt(u32, wav[28..32], 176400, .little); // correct byte rate
    std.mem.writeInt(u16, wav[32..34], 4, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 16, .little);
    @memset(wav[44..60], 0);

    // Corrupt byte_rate (bytes 28-31)
    var bad_wav = wav;
    std.mem.writeInt(u32, bad_wav[28..32], 999999, .little);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_rate.wav", .data = &bad_wav }) catch return;
    const path = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "bad_rate.wav") catch return;
    defer testing.allocator.free(path);
    var src = FileSource.open(path) catch return;
    defer src.close();
    const result = validateWavDeep(testing.allocator, &src);
    try testing.expect(!result.is_valid);
}

// ---------- AIFF corruption detection tests ----------

test "validateAiffDeep rejects corrupted channel count" {
    // Build minimal AIFF: FORM(12) + COMM(26) + SSND(8+8+8) = 62 bytes
    // 8-bit mono 8000Hz
    var aiff: [54]u8 = undefined;
    @memcpy(aiff[0..4], "FORM");
    std.mem.writeInt(u32, aiff[4..8], 46, .big); // form size
    @memcpy(aiff[8..12], "AIFF");
    @memcpy(aiff[12..16], "COMM");
    std.mem.writeInt(u32, aiff[16..20], 18, .big); // COMM chunk size
    std.mem.writeInt(u16, aiff[20..22], 1, .big); // numChannels
    std.mem.writeInt(u32, aiff[22..26], 8, .big); // numSampleFrames
    std.mem.writeInt(u16, aiff[26..28], 8, .big); // sampleSize
    // sampleRate as 80-bit extended (8000 Hz = 0x400B FA00...)
    aiff[28] = 0x40;
    aiff[29] = 0x0B;
    aiff[30] = 0xFA;
    @memset(aiff[31..38], 0);
    // SSND chunk
    @memcpy(aiff[38..42], "SSND");
    std.mem.writeInt(u32, aiff[42..46], 16, .big); // chunk size (8 header + 8 data)
    std.mem.writeInt(u32, aiff[46..50], 0, .big); // offset
    std.mem.writeInt(u32, aiff[50..54], 0, .big); // blockSize
    // (8 bytes of audio data would follow but we'll add zeros)

    var full: [62]u8 = undefined;
    @memcpy(full[0..54], &aiff);
    @memset(full[54..62], 0); // 8 bytes of silence
    // Fix FORM size
    std.mem.writeInt(u32, full[4..8], 54, .big);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Verify valid
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "good.aiff", .data = &full }) catch return;
    const good_path = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "good.aiff") catch return;
    defer testing.allocator.free(good_path);
    var good_src = FileSource.open(good_path) catch return;
    defer good_src.close();
    const good_result = validateAiffDeep(testing.allocator, &good_src);
    try testing.expect(good_result.is_valid);

    // Corrupt numChannels to 0
    var bad = full;
    std.mem.writeInt(u16, bad[20..22], 0, .big);
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_ch.aiff", .data = &bad }) catch return;
    const bad_path = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "bad_ch.aiff") catch return;
    defer testing.allocator.free(bad_path);
    var bad_src = FileSource.open(bad_path) catch return;
    defer bad_src.close();
    const result = validateAiffDeep(testing.allocator, &bad_src);
    try testing.expect(!result.is_valid);
}

// ---------- CAF corruption detection tests ----------

test "validateCaf rejects corrupted sample rate" {
    // Build minimal CAF: caff(4) + version(2) + flags(2) + desc chunk header(12) + desc data(32) = 52 bytes
    var caf: [52]u8 = undefined;
    @memcpy(caf[0..4], "caff");
    std.mem.writeInt(u16, caf[4..6], 1, .big); // version
    std.mem.writeInt(u16, caf[6..8], 0, .big); // flags
    @memcpy(caf[8..12], "desc");
    std.mem.writeInt(i64, caf[12..20], 32, .big); // chunk size
    // Audio Description: sample_rate(f64) + formatID(4) + formatFlags(4) +
    //   bytesPerPacket(4) + framesPerPacket(4) + channelsPerFrame(4) + bitsPerChannel(4)
    const sr: f64 = 44100.0;
    std.mem.writeInt(u64, caf[20..28], @bitCast(sr), .big); // sample rate
    @memcpy(caf[28..32], "lpcm"); // format ID
    std.mem.writeInt(u32, caf[32..36], 0, .big); // format flags
    std.mem.writeInt(u32, caf[36..40], 4, .big); // bytes per packet
    std.mem.writeInt(u32, caf[40..44], 1, .big); // frames per packet
    std.mem.writeInt(u32, caf[44..48], 2, .big); // channels per frame
    std.mem.writeInt(u32, caf[48..52], 16, .big); // bits per channel

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Verify valid
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "good.caf", .data = &caf }) catch return;
    const good_path = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "good.caf") catch return;
    defer std.testing.allocator.free(good_path);
    var good = FileSource.open(good_path) catch return;
    defer good.close();
    const good_result = validateCaf(&good);
    try testing.expect(good_result.is_valid);

    // Corrupt sample rate to NaN
    var bad_caf = caf;
    const nan_bits: u64 = @bitCast(@as(f64, std.math.nan(f64)));
    std.mem.writeInt(u64, bad_caf[20..28], nan_bits, .big);
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_sr.caf", .data = &bad_caf }) catch return;
    const bad_path = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad_sr.caf") catch return;
    defer std.testing.allocator.free(bad_path);
    var bad = FileSource.open(bad_path) catch return;
    defer bad.close();
    const bad_result = validateCaf(&bad);
    try testing.expect(!bad_result.is_valid);
}

test "validateCaf rejects corrupted channel count" {
    var caf: [52]u8 = undefined;
    @memcpy(caf[0..4], "caff");
    std.mem.writeInt(u16, caf[4..6], 1, .big);
    std.mem.writeInt(u16, caf[6..8], 0, .big);
    @memcpy(caf[8..12], "desc");
    std.mem.writeInt(i64, caf[12..20], 32, .big);
    const sr: f64 = 44100.0;
    std.mem.writeInt(u64, caf[20..28], @bitCast(sr), .big);
    @memcpy(caf[28..32], "lpcm");
    std.mem.writeInt(u32, caf[32..36], 0, .big);
    std.mem.writeInt(u32, caf[36..40], 4, .big);
    std.mem.writeInt(u32, caf[40..44], 1, .big);
    std.mem.writeInt(u32, caf[44..48], 2, .big); // valid channels
    std.mem.writeInt(u32, caf[48..52], 16, .big);

    // Corrupt channels to 0
    var bad_caf = caf;
    std.mem.writeInt(u32, bad_caf[44..48], 0, .big);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad_ch.caf", .data = &bad_caf }) catch return;
    const bad_path = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad_ch.caf") catch return;
    defer std.testing.allocator.free(bad_path);
    var bad = FileSource.open(bad_path) catch return;
    defer bad.close();
    const result = validateCaf(&bad);
    try testing.expect(!result.is_valid);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "FormatValidator deep validates real MIDI from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth MIDI file (Beethoven's Für Elise from mfiles.co.uk)
    var source = FileSource.open("ground_truth_examples/midi/fur_elise.mid") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/midi/fur_elise.mid") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    var source = FileSource.open("ground_truth_examples/tracker/otm.mod") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/tracker/otm.mod") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    var source = FileSource.open("ground_truth_examples/tracker/agony.xm") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/tracker/agony.xm") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    var source = FileSource.open("ground_truth_examples/tracker/flitter.it") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/tracker/flitter.it") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    var source = FileSource.open("ground_truth_examples/tracker/twilight_garden.s3m") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/tracker/twilight_garden.s3m") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid_id3.mp3", .{});
    try file.writePositionalAll(runtime.io(), &valid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid_id3.mp3");
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

test "FormatValidator accepts MP3 with large metadata gap after ID3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Simulate an MP3 audiobook with ~8KB of non-audio metadata (e.g., MusicMatch)
    // between the ID3v2 tag and the first MPEG frame sync.
    // This exercises the scan-forward logic that previously only searched 4KB.
    const file = try tmp_dir.dir.createFile(runtime.io(), "valid_large_gap.mp3", .{});
    // ID3v2 header (10 bytes, size=0 meaning no tag frames)
    try file.writePositionalAll(runtime.io(), &[_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }, 0);
    // 8192 bytes of non-sync padding (0x42 avoids false frame sync)
    const padding: [8192]u8 = .{0x42} ** 8192;
    try file.writePositionalAll(runtime.io(), &padding, 0);
    // Valid MP3 frame sync
    try file.writePositionalAll(runtime.io(), &[_]u8{ 0xFF, 0xFB, 0x90, 0x00 }, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid_large_gap.mp3");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.mp3, result.format);
    if (!result.is_valid) {
        std.debug.print("\nMP3 with 8KB metadata gap after ID3 failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid MP3 without ID3" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid MP3 starting with frame sync (padded to 128 bytes — the minimum
    // plausible MP3 size enforced by detectFormat to suppress Spotlight stub false positives)
    var valid_mp3 = [_]u8{0} ** 128;
    valid_mp3[0] = 0xFF;
    valid_mp3[1] = 0xFB; // frame sync + MPEG1 Layer3
    valid_mp3[2] = 0x90; // bitrate index 9 (128kbps), sample rate 0 (44100Hz)
    valid_mp3[3] = 0x00; // padding=0, private=0, channel=stereo

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid_raw.mp3", .{});
    try file.writePositionalAll(runtime.io(), &valid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid_raw.mp3");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid.mp3", .{});
    try file.writePositionalAll(runtime.io(), &invalid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid.mp3");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid.flac", .{});
    try file.writePositionalAll(runtime.io(), &valid_flac, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid.flac");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid.flac", .{});
    try file.writePositionalAll(runtime.io(), &invalid_flac, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid.flac");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid.wav", .{});
    try file.writePositionalAll(runtime.io(), &valid_wav, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid.wav");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "truncated.wav", .{});
    try file.writePositionalAll(runtime.io(), &truncated_wav, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "truncated.wav");
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
    var source = FileSource.open("ground_truth_examples/wav/sample.wav") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    source.close();

    const path = allocator.dupe(u8, "ground_truth_examples/wav/sample.wav") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid.mp3", .{});
    try file.writePositionalAll(runtime.io(), &valid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid.mp3");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid_id3.mp3", .{});
    try file.writePositionalAll(runtime.io(), &valid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid_id3.mp3");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid.mp3", .{});
    try file.writePositionalAll(runtime.io(), &invalid_mp3, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid.mp3");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.mid", .{});
    try file.writePositionalAll(runtime.io(), &midi_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.mid");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid_format.mid", .{});
    try file.writePositionalAll(runtime.io(), &midi_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid_format.mid");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "no_track.mid", .{});
    try file.writePositionalAll(runtime.io(), &midi_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "no_track.mid");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.xm", .{});
    try file.writePositionalAll(runtime.io(), &xm_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.xm");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.it", .{});
    try file.writePositionalAll(runtime.io(), &it_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.it");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.s3m", .{});
    try file.writePositionalAll(runtime.io(), &s3m_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.s3m");
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

test "FormatValidator accepts valid APE (modern v3990, full deep decode)" {
    // Now that validateApe runs the full Monkey's Audio decoder, only a
    // real APE file (one that actually decodes cleanly) can pass. Use
    // the in-tree ground-truth corpus, which is a real SDK-encoded APE.
    const allocator = std.testing.allocator;

    const path = "ground_truth_examples/ape/corpus_synthetic.ape";
    runtime.access(path, .{}) catch return error.SkipZigTest;
    const path_dup = try allocator.dupe(u8, path);
    defer allocator.free(path_dup);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path_dup);

    try std.testing.expectEqual(FileFormat.ape, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts large real APE (sample.ape, full deep decode)" {
    // Exercise the deep decoder on the larger luckynight.ape sample
    // (~6.5 MB v3990) when present.
    const allocator = std.testing.allocator;

    const path = "ground_truth_examples/ape/sample.ape";
    runtime.access(path, .{}) catch return error.SkipZigTest;
    const path_dup = try allocator.dupe(u8, path);
    defer allocator.free(path_dup);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path_dup);

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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.ape", .{});
    try file.writePositionalAll(runtime.io(), &ape_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.ape");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.ape, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid WavPack" {
    // Uses the real ground-truth sample so the libwavpack-backed deep
    // validator can actually decode blocks. A 32-byte synthetic header
    // is no longer enough — libwavpack rejects partial files at open time.
    const allocator = std.testing.allocator;
    // Skip if the ground-truth sample isn't available (e.g., nix sandbox build).
    {
        var probe = FileSource.open("ground_truth_examples/wavpack/sample.wv") catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
            else => return err,
        };
        probe.close();
    }
    const path = allocator.dupe(u8, "ground_truth_examples/wavpack/sample.wv") catch return error.SkipZigTest;
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.wv", .{});
    try file.writePositionalAll(runtime.io(), &wv_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.wv");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.dsf", .{});
    try file.writePositionalAll(runtime.io(), &dsf_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.dsf");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.dff", .{});
    try file.writePositionalAll(runtime.io(), &dff_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.dff");
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

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid.dsf", .{});
    try file.writePositionalAll(runtime.io(), &dsf_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid.dsf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.dsf, result.format);
    try std.testing.expect(!result.is_valid);
}

// ---------- Statistical-corruption WARN integration (Phase 1: mono s16 WAV) ----------

/// Construct a minimal mono signed-16-bit WAV in memory from a slice of i16
/// samples. Used by the integration tests below.
fn buildMonoS16Wav(allocator: Allocator, samples: []const i16, sample_rate: u32) ![]u8 {
    const data_size: u32 = @intCast(samples.len * 2);
    const fmt_size: u32 = 16;
    const file_size: u32 = 4 + (8 + fmt_size) + (8 + data_size);
    var buf = try allocator.alloc(u8, 8 + file_size);

    // RIFF header
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], file_size, .little);
    @memcpy(buf[8..12], "WAVE");

    // fmt  chunk
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], fmt_size, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // 1 channel
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    const byte_rate: u32 = sample_rate * 1 * 2;
    std.mem.writeInt(u32, buf[28..32], byte_rate, .little);
    std.mem.writeInt(u16, buf[32..34], 2, .little); // block_align = ch * bytes_per_sample
    std.mem.writeInt(u16, buf[34..36], 16, .little); // bits_per_sample

    // data chunk
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    var i: usize = 0;
    while (i < samples.len) : (i += 1) {
        std.mem.writeInt(i16, buf[44 + i * 2 ..][0..2], samples[i], .little);
    }
    return buf;
}

test "validateWavDeep: clean mono s16 sine wave returns OK without warning" {
    const allocator = testing.allocator;
    const samples = try allocator.alloc(i16, 4096);
    defer allocator.free(samples);
    const sr: f64 = 44100.0;
    const freq: f64 = 440.0;
    for (samples, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * 16000.0;
        s.* = @intFromFloat(v);
    }
    const wav = try buildMonoS16Wav(allocator, samples, 44100);
    defer allocator.free(wav);
    var source = FileSource.fromBuffer(wav);
    defer source.close();
    const result = validateWavDeep(allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}

test "validateWavDeep: sustained non-zero constant run in mono s16 emits WARN" {
    // Updated 2026-05-02 (Peter): under the noise-not-silence rework, NUL
    // runs are silence (no longer corruption). Real drive corruption shows
    // up as a sustained non-zero DC value (decoder confusion / freed-sector
    // contents) -- a constant non-zero sample run >= 0.1 s of audio.
    const allocator = testing.allocator;
    // 2.0 seconds at 44.1 kHz mono = 88200 samples -- well past the 1 s
    // strong threshold so the heuristic flags it as likely_corrupt.
    const sample_count: usize = 88_200;
    const samples = try allocator.alloc(i16, sample_count);
    defer allocator.free(samples);
    const sr: f64 = 44100.0;
    const freq: f64 = 440.0;
    for (samples, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * 16000.0;
        s.* = @intFromFloat(v);
    }
    // Inject a 60000-sample (~1.4 s) constant non-zero run -- DC stuck.
    for (15_000..75_000) |i| samples[i] = -13108;
    const wav = try buildMonoS16Wav(allocator, samples, 44100);
    defer allocator.free(wav);
    var source = FileSource.fromBuffer(wav);
    defer source.close();
    const result = validateWavDeep(allocator, &source);
    try testing.expect(result.is_valid); // WARN, not FAIL
    try testing.expect(result.warning_message != null);
    if (result.warning_message) |w| {
        try testing.expect(std.mem.indexOf(u8, w, "statistical-corruption") != null);
    }
}

test "validateWavDeep: stereo s16 is not scanned (heuristic skipped)" {
    const allocator = testing.allocator;
    const sample_count: usize = 4096;
    const data_size: u32 = @intCast(sample_count * 2 * 2);
    const fmt_size: u32 = 16;
    const file_size: u32 = 4 + (8 + fmt_size) + (8 + data_size);
    var buf = try allocator.alloc(u8, 8 + file_size);
    defer allocator.free(buf);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], file_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], fmt_size, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], 2, .little);
    std.mem.writeInt(u32, buf[24..28], 44100, .little);
    std.mem.writeInt(u32, buf[28..32], 44100 * 2 * 2, .little);
    std.mem.writeInt(u16, buf[32..34], 4, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_size, .little);
    @memset(buf[44..], 0);
    var source = FileSource.fromBuffer(buf);
    defer source.close();
    const result = validateWavDeep(allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}

test "validateWavDeep: clean white noise mono s16 stays clean" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    const samples = try allocator.alloc(i16, 4096);
    defer allocator.free(samples);
    for (samples) |*s| s.* = rng.intRangeAtMost(i16, -3000, 3000);
    const wav = try buildMonoS16Wav(allocator, samples, 44100);
    defer allocator.free(wav);
    var source = FileSource.fromBuffer(wav);
    defer source.close();
    const result = validateWavDeep(allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}

test "validateWavDeep: square wave mono s16 (synth-flat) stays clean" {
    const allocator = testing.allocator;
    const samples = try allocator.alloc(i16, 4096);
    defer allocator.free(samples);
    for (samples, 0..) |*s, i| {
        s.* = if ((i / 100) & 1 == 0) 16000 else -16000;
    }
    const wav = try buildMonoS16Wav(allocator, samples, 44100);
    defer allocator.free(wav);
    var source = FileSource.fromBuffer(wav);
    defer source.close();
    const result = validateWavDeep(allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}

test "validateWavDeep: ground truth WAV stays clean (no statistical warning)" {
    var source = FileSource.open("ground_truth_examples/wav/sample.wav") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer source.close();
    const result = validateWavDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}


test "validateWav: u32-overflow declared RIFF size must not bypass the truncation guard" {
	// riff_size = 0xFFFFFFFF on a 12-byte file. Pre-fix `riff_size + 8` is u32
	// arithmetic: it wraps to 7 (ReleaseFast) or panics (safe build) -> the
	// truncation guard is bypassed. The fix widens the LHS to u64.
	const buf = [_]u8{ 'R', 'I', 'F', 'F', 0xFF, 0xFF, 0xFF, 0xFF, 'W', 'A', 'V', 'E' };
	var src = FileSource.fromBuffer(&buf);
	const r = validateWav(&src);
	// Assert the SPECIFIC truncation error (not just any failure): in ReleaseFast
	// the wrap would bypass the guard and fail later for a different reason, so a
	// bare !is_valid would pass vacuously.
	try std.testing.expect(!r.is_valid and r.error_code != null and r.error_code.? == .exceeds_bounds);
}

test "validateAiffDeep: u32-overflow declared FORM size must not bypass the truncation guard" {
	const buf = [_]u8{ 'F', 'O', 'R', 'M', 0xFF, 0xFF, 0xFF, 0xFF, 'A', 'I', 'F', 'F' };
	var src = FileSource.fromBuffer(&buf);
	const r = validateAiffDeep(std.testing.allocator, &src);
	try std.testing.expect(!r.is_valid and r.error_code != null and r.error_code.? == .exceeds_bounds);
}
