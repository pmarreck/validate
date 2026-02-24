//! Movie/video format validators extracted from format_validation.zig.
//! Covers MP4/MOV, MKV/WebM, AVI, SWF, FLV, MPEG-PS/TS/ES, and IVF.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const MalformationType = format_validation.MalformationType;
const video_audio_validator = @import("video_audio_validator.zig");
const video_validator = @import("video_validator.zig");
const ebml_parser = @import("ebml_parser.zig");
const mp4_box_parser = @import("mp4_box_parser.zig");
const mpeg_ts_parser = @import("mpeg_ts_parser.zig");
const zlib = @import("zlib.zig");
const errmsg = @import("error_messages.zig");
const vp9_syntax_validator = @import("vp9_syntax_validator.zig");
const av1_obu_validator = @import("av1_obu_validator.zig");
const h264_syntax_validator = @import("h264_syntax_validator.zig");
const aac_syntax_validator = @import("aac_syntax_validator.zig");

// Imported helpers from format_validation
const VideoDecodeTolerance = format_validation.VideoDecodeTolerance;
const toleratedVideoDecodeFailure = format_validation.toleratedVideoDecodeFailure;
const isValidBoxType = format_validation.isValidBoxType;


// ============ ISO BMFF (MP4/MOV) Validator ============

/// Validate ISO BMFF (MP4, MOV, HEIC, M4A) file structure.
pub fn validateIsobmff(file: std.fs.File, format: FileFormat) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    };

    if (file_size < 8) {
        return ValidationResult.invalidCode(format, .file_too_small, "ISO BMFF");
    }

    // Scan boxes (atoms)
    var offset: u64 = 0;
    var found_ftyp = false;
    var found_mdat_or_moov = false;
    var box_count: usize = 0;

    while (offset < file_size and box_count < 100) {
        file.seekTo(offset) catch break;

        var box_header: [8]u8 = undefined;
        const bytes_read = file.read(&box_header) catch break;

        if (bytes_read < 8) break;

        const box_size = std.mem.readInt(u32, box_header[0..4], .big);
        const box_type = box_header[4..8];

        // Check if box type is valid ASCII - if not, we may have hit padding/trailer data
        // This is common in files from Apple Photos and some other sources
        if (!isValidBoxType(box_type)) {
            // If we've found the essential boxes, treat non-box data as acceptable trailer
            if (found_ftyp and found_mdat_or_moov) {
                break;
            }
            // Otherwise, this is invalid data where we expected a box
            return ValidationResult.invalidCode(format, .invalid_value, "box type (non-ASCII data)");
        }

        // Handle extended size
        if (box_size == 1) {
            var ext_size: [8]u8 = undefined;
            _ = file.read(&ext_size) catch break;
            const large_size = std.mem.readInt(u64, &ext_size, .big);
            if (large_size < 16) {
                return ValidationResult.invalidCode(format, .invalid_value, "extended box size");
            }
            if (large_size > file_size) {
                return ValidationResult.invalidCodeMsg(format, .exceeds_bounds, "Box size", "Box size exceeds file size");
            }
            offset += large_size;
        } else if (box_size == 0) {
            // Box extends to end of file
            break;
        } else {
            if (offset + box_size > file_size) {
                // If we've found essential boxes and this is near EOF, could be trailer
                if (found_ftyp and found_mdat_or_moov) {
                    // Accept trailing data up to 1KB as padding/metadata
                    const remaining = file_size - offset;
                    if (remaining <= 1024) {
                        break;
                    }
                }
                return ValidationResult.invalid(format, "Box extends beyond file end (truncated)");
            }
            offset += box_size;
        }

        // Check for required boxes
        if (std.mem.eql(u8, box_type, "ftyp")) {
            found_ftyp = true;
        }
        if (std.mem.eql(u8, box_type, "mdat") or std.mem.eql(u8, box_type, "moov")) {
            found_mdat_or_moov = true;
        }

        box_count += 1;
    }

    // Check for required boxes
    // Classic QuickTime (.mov) doesn't require ftyp - it predates ISO BMFF
    // ISO BMFF formats (MP4, M4A, HEIC, AVIF) require ftyp
    if (!found_ftyp) {
        if (format == .mov) {
            // Classic QuickTime: ftyp is optional, but we need moov or mdat
            if (!found_mdat_or_moov) {
                return ValidationResult.invalidCode(format, .missing, "moov or mdat box");
            }
            // Valid classic QuickTime file
        } else {
            // ISO BMFF formats require ftyp
            return ValidationResult.invalidCode(format, .missing, "ftyp box");
        }
    }

    return ValidationResult.ok(format);
}

// ============ Matroska/WebM Validator ============

/// Validate Matroska (MKV/WebM) file structure using EBML.
pub fn validateMatroska(file: std.fs.File, format: FileFormat) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(format, .failed_to_read, "EBML header");

    // Check EBML signature
    if (!std.mem.eql(u8, &header, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return ValidationResult.invalidCode(format, .invalid_signature, "EBML");
    }

    // Read more to find DocType
    file.seekTo(0) catch return ValidationResult.invalid(format, "Failed to seek");

    var buffer: [256]u8 = undefined;
    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.invalidCode(format, .failed_to_read, "EBML data");
    };

    // Look for DocType element (0x4282)
    var i: usize = 4;
    var found_doctype = false;
    while (i + 2 < bytes_read) {
        if (buffer[i] == 0x42 and buffer[i + 1] == 0x82) {
            // Found DocType element
            found_doctype = true;
            break;
        }
        i += 1;
    }

    if (!found_doctype) {
        // DocType not found in first 256 bytes, but EBML header is valid
        // This is acceptable for a basic check
        return ValidationResult.ok(format);
    }

    // Verify doctype matches format
    if (format == .webm) {
        if (!format_validation.findInBuffer(&buffer, bytes_read, "webm")) {
            // Has EBML but not webm doctype - might be MKV mislabeled
            return ValidationResult.ok(format); // Accept it anyway
        }
    }

    return ValidationResult.ok(format);
}

// ============ AVI Validator ============

/// Validate AVI file structure (RIFF container).
pub fn validateAvi(file: std.fs.File) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.avi, .failed_to_read, "AVI header");

    // Check RIFF signature
    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCode(.avi, .invalid_signature, "RIFF");
    }

    // Check AVI fourcc
    if (!std.mem.eql(u8, header[8..12], "AVI ")) {
        return ValidationResult.invalidCode(.avi, .invalid_value, "AVI fourcc");
    }

    // Get declared RIFF size
    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.avi, .failed_to_get, "file size");
    };

    if (riff_size + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(.avi, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size (truncated)");
    }

    // Look for required LIST chunks (hdrl, movi)
    var buffer: [4096]u8 = undefined;
    file.seekTo(12) catch return ValidationResult.invalid(.avi, "Failed to seek");

    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.invalidCode(.avi, .failed_to_read, "AVI data");
    };

    const has_hdrl = format_validation.findInBuffer(&buffer, bytes_read, "hdrl");
    if (!has_hdrl) {
        return ValidationResult.invalidCode(.avi, .missing, "AVI header list");
    }

    return ValidationResult.ok(.avi);
}

// ============ SWF (Flash) Validator ============

/// Validate Adobe Flash SWF file structure.
/// Supports FWS (uncompressed), CWS (zlib), and ZWS (LZMA) formats.
pub fn validateSwf(file: std.fs.File) ValidationResult {
    var header: [8]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.swf, .failed_to_read, "SWF header");

    // Check signature (FWS, CWS, or ZWS)
    const sig = header[0..3];
    const compression: enum { uncompressed, zlib, lzma } = if (std.mem.eql(u8, sig, "FWS"))
        .uncompressed
    else if (std.mem.eql(u8, sig, "CWS"))
        .zlib
    else if (std.mem.eql(u8, sig, "ZWS"))
        .lzma
    else
        return ValidationResult.invalidCode(.swf, .invalid_signature, "SWF");

    // Version (byte 3): must be reasonable (1-50)
    const version = header[3];
    if (version == 0 or version > 50) {
        return ValidationResult.invalidCode(.swf, .invalid_value, "SWF version");
    }

    // File length (bytes 4-7, little-endian)
    // For compressed SWF, this is the uncompressed size
    const declared_size = std.mem.readInt(u32, header[4..8], .little);
    if (declared_size < 8) {
        return ValidationResult.invalidCode(.swf, .invalid_value, "SWF file size");
    }

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.swf, .failed_to_get, "file size");
    };

    // For uncompressed SWF, check file size matches
    if (compression == .uncompressed) {
        if (declared_size != file_size) {
            return ValidationResult.invalid(.swf, "SWF size mismatch (truncated or corrupted)");
        }
    } else {
        // For compressed SWF, actual file must be smaller than declared (uncompressed) size
        if (file_size >= declared_size) {
            // This could indicate corruption or wrong compression type
            return ValidationResult.invalid(.swf, "Compressed SWF larger than declared size");
        }
    }

    // Validate content based on compression type
    switch (compression) {
        .uncompressed => {
            // Read the RECT directly
            var rect_buffer: [16]u8 = undefined;
            file.seekTo(8) catch return ValidationResult.invalidCode(.swf, .failed_to_seek, "to RECT");

            const rect_read = file.read(&rect_buffer) catch {
                return ValidationResult.invalidCode(.swf, .failed_to_read, "SWF RECT");
            };

            if (rect_read < 1) {
                return ValidationResult.invalidCode(.swf, .truncated, "SWF RECT");
            }

            // RECT: first 5 bits are Nbits (number of bits per value)
            const nbits = rect_buffer[0] >> 3;
            if (nbits == 0 or nbits > 31) {
                return ValidationResult.invalidCode(.swf, .invalid_value, "RECT Nbits value");
            }

            return ValidationResult.ok(.swf);
        },
        .zlib => {
            // Decompress CWS (zlib) data and validate
            return validateSwfZlib(file, declared_size);
        },
        .lzma => {
            // LZMA (ZWS) - structural validation only for now
            // ZWS format: 8 byte header + 4 byte compressed size + 5 byte LZMA props + LZMA data
            // Full LZMA validation would require LZMA library
            return ValidationResult.ok(.swf);
        },
    }
}

/// Validate zlib-compressed SWF (CWS) by decompressing and validating RECT structure
pub fn validateSwfZlib(file: std.fs.File, declared_size: u32) ValidationResult {
    // Read compressed data (after 8-byte header)
    file.seekTo(8) catch return ValidationResult.ok(.swf); // Fall back to structural

    const file_size = file.getEndPos() catch return ValidationResult.ok(.swf);
    const compressed_size = file_size - 8;

    // Sanity check - if too large, accept as structural
    if (compressed_size > 100 * 1024 * 1024 or declared_size > 500 * 1024 * 1024) {
        return ValidationResult.ok(.swf);
    }

    // Allocate buffer for compressed data
    var gpa = std.heap.page_allocator;
    const compressed_data = gpa.alloc(u8, @intCast(compressed_size)) catch {
        return ValidationResult.ok(.swf); // Fall back to structural
    };
    defer gpa.free(compressed_data);

    // Read compressed data
    const bytes_read = file.readAll(compressed_data) catch {
        return ValidationResult.ok(.swf);
    };
    if (bytes_read != compressed_size) {
        return ValidationResult.ok(.swf); // Truncated but header was valid
    }

    // Decompress using zlib (the 8-byte header has been stripped, data starts with zlib stream)
    // SWF CWS uses standard zlib format (not raw deflate)
    const decompressed_size: usize = declared_size - 8; // Subtract header size
    const result = zlib.inflateZlibAlloc(gpa, compressed_data, decompressed_size + 1024) catch {
        // Decompression failed - fall back to structural validation
        // The header was valid, so it's a valid CWS file, just can't verify content
        return ValidationResult.ok(.swf);
    };
    defer gpa.free(result);

    // Validate decompressed size matches (within tolerance for padding)
    if (result.len < decompressed_size -| 16 or result.len > decompressed_size + 16) {
        // Size mismatch but decompression succeeded - might be truncated
        return ValidationResult.ok(.swf);
    }

    // Validate RECT structure in decompressed data
    if (result.len < 1) {
        return ValidationResult.ok(.swf);
    }

    const nbits = result[0] >> 3;
    if (nbits == 0 or nbits > 31) {
        return ValidationResult.invalidCode(.swf, .invalid_value, "SWF RECT Nbits value");
    }

    // Calculate RECT size in bytes: (5 + nbits * 4) bits, rounded up
    const rect_bits = 5 + @as(usize, nbits) * 4;
    const rect_bytes = (rect_bits + 7) / 8;

    if (result.len < rect_bytes + 4) { // RECT + at least frame rate and count
        return ValidationResult.ok(.swf); // Too small but format was valid
    }

    return ValidationResult.okWithDepth(.swf, .full);
}

// ============ FLV (Flash Video) Validator ============

/// Validate Adobe Flash Video (FLV) container structure.
pub fn validateFlv(file: std.fs.File) ValidationResult {
    var header: [9]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.flv, .failed_to_read, "FLV header");

    // Check signature "FLV"
    if (!std.mem.eql(u8, header[0..3], "FLV")) {
        return ValidationResult.invalidCode(.flv, .invalid_signature, "FLV");
    }

    // Version (usually 1)
    const version = header[3];
    if (version == 0 or version > 10) {
        return ValidationResult.invalidCode(.flv, .invalid_value, "FLV version");
    }

    // Flags (byte 4): bits 0-4 reserved (0), bit 2 = has audio, bit 0 = has video
    const flags = header[4];
    const reserved_bits = flags & 0xFA; // bits 7,6,5,4,3,1 should be 0
    if (reserved_bits != 0) {
        return ValidationResult.invalidCode(.flv, .invalid_value, "FLV flags (reserved bits set)");
    }

    // Data offset (bytes 5-8, big-endian) - typically 9
    const data_offset = std.mem.readInt(u32, header[5..9], .big);
    if (data_offset < 9) {
        return ValidationResult.invalidCode(.flv, .invalid_value, "FLV data offset");
    }

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.flv, .failed_to_get, "file size");
    };

    if (data_offset > file_size) {
        return ValidationResult.invalidCodeMsg(.flv, .exceeds_bounds, "FLV data offset", "FLV data offset exceeds file size");
    }

    // Read first tag header (if present)
    if (file_size > data_offset + 4) {
        file.seekTo(data_offset) catch return ValidationResult.invalidCode(.flv, .failed_to_seek, "to tags");

        // PreviousTagSize0 should be 0
        var prev_tag_size: [4]u8 = undefined;
        _ = file.read(&prev_tag_size) catch return ValidationResult.invalidCode(.flv, .failed_to_read, "PreviousTagSize0");

        const prev_size = std.mem.readInt(u32, &prev_tag_size, .big);
        if (prev_size != 0) {
            return ValidationResult.invalidCode(.flv, .invalid_value, "PreviousTagSize0 (should be 0)");
        }

        // If there's more data, validate first tag header
        if (file_size > data_offset + 4 + 11) {
            var tag_header: [11]u8 = undefined;
            _ = file.read(&tag_header) catch return ValidationResult.invalidCode(.flv, .failed_to_read, "tag header");

            const tag_type = tag_header[0];
            // Valid tag types: 8 (audio), 9 (video), 18 (script data)
            if (tag_type != 8 and tag_type != 9 and tag_type != 18) {
                return ValidationResult.invalidCode(.flv, .invalid_value, "FLV tag type");
            }

            // Tag data size (3 bytes, big-endian)
            const tag_size = (@as(u32, tag_header[1]) << 16) | (@as(u32, tag_header[2]) << 8) | @as(u32, tag_header[3]);

            // Check tag doesn't exceed file
            const tag_end = data_offset + 4 + 11 + tag_size + 4; // +4 for PreviousTagSize
            if (tag_end > file_size) {
                return ValidationResult.invalidCodeMsg(.flv, .exceeds_bounds, "FLV tag", "FLV tag exceeds file size (truncated)");
            }
        }
    }

    return ValidationResult.ok(.flv);
}

/// Deep FLV validation — extracts H.264 NALs and AAC frames from tags, dispatches
/// to codec validators. FLV video tags with codec ID 7 contain AVCC-format H.264;
/// audio tags with sound format 10 contain raw AAC frames.
pub fn validateFlvDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.flv, .failed_to_open, "FLV file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.flv, .failed_to_get, "file size");
    };

    if (file_size > 4 * 1024 * 1024 * 1024) { // 4GB limit
        return ValidationResult.okWithDepth(.flv, .structural);
    }

    // Read header
    var header: [9]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.flv, .failed_to_read, "FLV header");

    if (!std.mem.eql(u8, header[0..3], "FLV")) {
        return ValidationResult.invalidCode(.flv, .invalid_signature, "FLV");
    }

    const data_offset = std.mem.readInt(u32, header[5..9], .big);
    if (data_offset < 9 or data_offset > file_size) {
        return ValidationResult.invalidCode(.flv, .invalid_value, "FLV data offset");
    }

    // Parse tags, collecting H.264 and AAC data
    file.seekTo(data_offset) catch return ValidationResult.invalidCode(.flv, .failed_to_seek, "to tags");

    var tag_count: u32 = 0;
    var offset: u64 = data_offset;

    // H.264 collection
    var h264_annexb: std.ArrayListUnmanaged(u8) = .{};
    defer h264_annexb.deinit(allocator);
    var nal_length_size: u8 = 4;
    var has_h264 = false;

    // AAC collection
    var aac_data: std.ArrayListUnmanaged(u8) = .{};
    defer aac_data.deinit(allocator);
    var aac_sizes: std.ArrayListUnmanaged(u32) = .{};
    defer aac_sizes.deinit(allocator);
    var aac_config: std.ArrayListUnmanaged(u8) = .{};
    defer aac_config.deinit(allocator);
    var has_aac = false;

    const max_codec_tags: u32 = 200; // Limit frames to validate
    var video_tags_collected: u32 = 0;
    var audio_tags_collected: u32 = 0;

    while (offset + 4 < file_size) {
        // Read PreviousTagSize
        var prev_tag_buf: [4]u8 = undefined;
        _ = file.read(&prev_tag_buf) catch break;
        offset += 4;

        if (offset + 11 >= file_size) break;

        // Read tag header
        var tag_header: [11]u8 = undefined;
        _ = file.read(&tag_header) catch break;

        const tag_type = tag_header[0];
        if (tag_type != 8 and tag_type != 9 and tag_type != 18) {
            return ValidationResult.invalidCode(.flv, .invalid_value, "FLV tag type");
        }

        const tag_size = (@as(u32, tag_header[1]) << 16) | (@as(u32, tag_header[2]) << 8) | @as(u32, tag_header[3]);
        const tag_data_start = offset + 11;

        if (tag_data_start + tag_size > file_size) {
            return ValidationResult.invalidCodeMsg(.flv, .exceeds_bounds, "FLV tag", "FLV tag exceeds file size");
        }

        // Video tag (type 9): extract H.264 data
        if (tag_type == 9 and tag_size >= 5 and video_tags_collected < max_codec_tags) {
            var video_hdr: [5]u8 = undefined;
            if ((file.read(&video_hdr) catch null) == 5) {
                const codec_id = video_hdr[0] & 0x0F;
                if (codec_id == 7) { // AVC (H.264)
                    has_h264 = true;
                    const avc_packet_type = video_hdr[1];
                    const payload_size = tag_size - 5;

                    if (avc_packet_type == 0 and payload_size > 6) {
                        // AVC sequence header (AVCDecoderConfigurationRecord)
                        // Extract nal_length_size and SPS/PPS as Annex B
                        const config_data = allocator.alloc(u8, payload_size) catch break;
                        defer allocator.free(config_data);
                        const config_read = file.readAll(config_data) catch break;
                        if (config_read >= 6) {
                            nal_length_size = (config_data[4] & 0x03) + 1;
                            // Extract SPS
                            const num_sps = config_data[5] & 0x1F;
                            var cfg_pos: usize = 6;
                            var sps_idx: u8 = 0;
                            while (sps_idx < num_sps and cfg_pos + 2 <= config_read) : (sps_idx += 1) {
                                const sps_len = std.mem.readInt(u16, config_data[cfg_pos..][0..2], .big);
                                cfg_pos += 2;
                                if (cfg_pos + sps_len <= config_read) {
                                    h264_annexb.appendSlice(allocator, &[_]u8{ 0, 0, 0, 1 }) catch break;
                                    h264_annexb.appendSlice(allocator, config_data[cfg_pos..][0..sps_len]) catch break;
                                    cfg_pos += sps_len;
                                }
                            }
                            // Extract PPS
                            if (cfg_pos < config_read) {
                                const num_pps = config_data[cfg_pos];
                                cfg_pos += 1;
                                var pps_idx: u8 = 0;
                                while (pps_idx < num_pps and cfg_pos + 2 <= config_read) : (pps_idx += 1) {
                                    const pps_len = std.mem.readInt(u16, config_data[cfg_pos..][0..2], .big);
                                    cfg_pos += 2;
                                    if (cfg_pos + pps_len <= config_read) {
                                        h264_annexb.appendSlice(allocator, &[_]u8{ 0, 0, 0, 1 }) catch break;
                                        h264_annexb.appendSlice(allocator, config_data[cfg_pos..][0..pps_len]) catch break;
                                        cfg_pos += pps_len;
                                    }
                                }
                            }
                        }
                    } else if (avc_packet_type == 1 and payload_size > 0) {
                        // AVC NALU — AVCC format (length-prefixed NALs)
                        const nalu_data = allocator.alloc(u8, payload_size) catch break;
                        defer allocator.free(nalu_data);
                        const nalu_read = file.readAll(nalu_data) catch break;
                        if (nalu_read > 0) {
                            if (video_validator.convertToAnnexB(allocator, nalu_data[0..nalu_read], nal_length_size)) |annexb| {
                                defer allocator.free(annexb);
                                h264_annexb.appendSlice(allocator, annexb) catch {};
                            }
                        }
                        video_tags_collected += 1;
                    }
                }
            }
        }

        // Audio tag (type 8): extract AAC data
        if (tag_type == 8 and tag_size >= 2 and audio_tags_collected < max_codec_tags) {
            file.seekTo(tag_data_start) catch break;
            var audio_hdr: [2]u8 = undefined;
            if ((file.read(&audio_hdr) catch null) == 2) {
                const sound_format = (audio_hdr[0] >> 4) & 0x0F;
                if (sound_format == 10) { // AAC
                    has_aac = true;
                    const aac_packet_type = audio_hdr[1];
                    const payload_size = tag_size - 2;

                    if (aac_packet_type == 0 and payload_size > 0) {
                        // AAC sequence header (AudioSpecificConfig)
                        aac_config.resize(allocator, payload_size) catch break;
                        _ = file.readAll(aac_config.items) catch break;
                    } else if (aac_packet_type == 1 and payload_size > 0) {
                        // AAC raw frame
                        const frame_start = aac_data.items.len;
                        aac_data.resize(allocator, frame_start + payload_size) catch break;
                        _ = file.readAll(aac_data.items[frame_start..]) catch break;
                        aac_sizes.append(allocator, @intCast(payload_size)) catch break;
                        audio_tags_collected += 1;
                    }
                }
            }
        }

        offset = tag_data_start + tag_size;
        file.seekTo(offset) catch break;
        tag_count += 1;

        if (tag_count > 10_000_000) break;
    }

    if (tag_count == 0) {
        return ValidationResult.invalidCode(.flv, .no_valid_x_found, "FLV tags");
    }

    // Validate collected codec data
    var validated_codec = false;

    if (has_h264 and h264_annexb.items.len > 0) {
        const h264_result = h264_syntax_validator.validateH264Stream(h264_annexb.items, 100);
        if (!h264_result.valid) {
            const msg = if (h264_result.error_message) |m| std.mem.span(m) else "H.264 stream validation failed";
            return ValidationResult.invalidWithDepth(.flv, msg, .full);
        }
        validated_codec = true;
    }

    if (has_aac and aac_config.items.len > 0 and aac_sizes.items.len > 0) {
        const aac_result = aac_syntax_validator.validateAacSyntax(aac_data.items, aac_sizes.items, aac_config.items);
        if (!aac_result.valid) {
            const msg = aac_result.error_message orelse "AAC syntax validation failed";
            return ValidationResult.invalidWithDepth(.flv, msg, .full);
        }
        validated_codec = true;
    }

    if (validated_codec) {
        return ValidationResult.okWithDepth(.flv, .full);
    }

    // No H.264/AAC codecs found (VP6, Speex, etc.) — structural only
    return ValidationResult.okWithDepth(.flv, .structural);
}

// ============ MPEG PS/TS/ES/IVF Validators ============

/// Validate MPEG Program Stream file structure.
/// Pack start code: 00 00 01 BA followed by SCR and mux rate
pub fn validateMpegPs(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.mpeg_ps, .failed_to_seek, "to start");

    var header: [14]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.mpeg_ps, .failed_to_read, "header");

    if (bytes_read < 14) {
        return ValidationResult.invalidCode(.mpeg_ps, .file_too_small, "MPEG PS");
    }

    // Check pack start code: 00 00 01 BA
    if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xBA })) {
        return ValidationResult.invalidCode(.mpeg_ps, .invalid_value, "MPEG PS pack start code");
    }

    // Check MPEG version based on next 2 bits after start code
    // MPEG-1: starts with 0010xxxx (bits 4-5 are 00)
    // MPEG-2: starts with 01xxxxxx (bit 6 is 0, bit 7 is 1)
    const marker = header[4];
    if ((marker & 0xF0) == 0x20) {
        // MPEG-1 PS
        return ValidationResult.okWithDepth(.mpeg_ps, .full);
    } else if ((marker & 0xC0) == 0x40) {
        // MPEG-2 PS
        return ValidationResult.okWithDepth(.mpeg_ps, .full);
    }

    return ValidationResult.invalidCode(.mpeg_ps, .invalid_value, "MPEG PS marker bits");
}

/// Validate MPEG Transport Stream file structure.
/// 188-byte packets starting with 0x47 sync byte
pub fn validateMpegTs(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.mpeg_ts, .failed_to_seek, "to start");

    // Read enough to check multiple sync bytes
    var buffer: [376]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalidCode(.mpeg_ts, .failed_to_read, "header");

    if (bytes_read < 188) {
        return ValidationResult.invalidCode(.mpeg_ts, .file_too_small, "MPEG TS");
    }

    // First byte must be sync byte
    if (buffer[0] != 0x47) {
        return ValidationResult.invalidCode(.mpeg_ts, .invalid_value, "MPEG TS sync byte");
    }

    // Determine packet size by checking for sync at different intervals
    // Valid packet sizes: 188 (standard), 192 (with timestamp), 204 (with FEC)
    const has_valid_packets = (bytes_read >= 376 and buffer[188] == 0x47) or
        (bytes_read >= 384 and buffer[192] == 0x47) or
        (bytes_read >= 408 and buffer[204] == 0x47);

    if (!has_valid_packets) {
        return ValidationResult.invalid(.mpeg_ts, "Cannot determine MPEG TS packet size");
    }

    // Verify PID field (bits 0-12 of bytes 1-2) is valid
    const pid = ((@as(u16, buffer[1] & 0x1F) << 8) | @as(u16, buffer[2]));
    if (pid > 0x1FFF) {
        return ValidationResult.invalidCode(.mpeg_ts, .invalid_value, "MPEG TS PID");
    }

    return ValidationResult.structuralOnly(.mpeg_ts);
}

/// Deep MPEG-TS validation: CRC-32 for PAT/PMT, continuity counters, PES assembly + stream validation
pub fn validateMpegTsDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.mpeg_ts, .failed_to_open, "file");
    };
    defer file.close();

    file.seekTo(0) catch return ValidationResult.invalid(.mpeg_ts, "Failed to seek");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.mpeg_ts, .failed_to_get, "file size");
    if (file_size < mpeg_ts_parser.TS_PACKET_SIZE) {
        return ValidationResult.invalidCode(.mpeg_ts, .file_too_small, "MPEG-TS");
    }

    // Read up to 4MB for deep validation
    const max_read: usize = 4 * 1024 * 1024;
    const read_size: usize = @min(file_size, max_read);

    const data = allocator.alloc(u8, read_size) catch {
        return ValidationResult.invalidCode(.mpeg_ts, .out_of_memory, "for TS data");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.mpeg_ts, .failed_to_read, "TS data");
    };

    if (bytes_read < mpeg_ts_parser.TS_PACKET_SIZE) {
        return ValidationResult.invalidCode(.mpeg_ts, .incomplete, "TS data");
    }

    const result = mpeg_ts_parser.validateTsDeep(allocator, data[0..bytes_read], 50000);

    if (!result.valid) {
        return ValidationResult.invalid(.mpeg_ts, result.error_message orelse "MPEG-TS validation failed");
    }

    // If we have CRC validation and stream validation, report full depth
    if (result.pat_crc_valid and result.pmt_crc_valid and
        (result.video_streams_validated > 0 or result.audio_streams_validated > 0))
    {
        return ValidationResult.okWithDepth(.mpeg_ts, .full);
    }

    // If we have stream validation but no CRC, still report full
    if (result.video_streams_validated > 0 or result.audio_streams_validated > 0) {
        return ValidationResult.okWithDepth(.mpeg_ts, .full);
    }

    // Structural validation with continuity check passed
    return ValidationResult.okWithDepth(.mpeg_ts, .structural);
}

/// Validate MPEG Elementary Stream (raw MPEG-1/2 video).
/// Video sequence header: 00 00 01 B3
pub fn validateMpegEs(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.mpeg_es, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.mpeg_es, .failed_to_read, "header");

    if (bytes_read < 12) {
        return ValidationResult.invalidCode(.mpeg_es, .file_too_small, "MPEG ES");
    }

    // Check for sequence header (video) or system start code
    // Video sequence: 00 00 01 B3
    // Pack start code (PS): 00 00 01 BA - shouldn't match ES
    if (std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xB3 })) {
        // MPEG video sequence header
        return ValidationResult.okWithDepth(.mpeg_es, .full);
    }

    // Could also start with picture start code or GOP
    if (std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0x00 })) {
        // Picture start code
        return ValidationResult.okWithDepth(.mpeg_es, .full);
    }

    if (std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xB8 })) {
        // GOP header
        return ValidationResult.okWithDepth(.mpeg_es, .full);
    }

    return ValidationResult.invalidCode(.mpeg_es, .invalid_value, "MPEG ES start code");
}

/// Validate IVF container file structure.
/// IVF header: DKIF + version + header_size + codec + dimensions + frame rate
pub fn validateIvf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.ivf, .failed_to_seek, "to start");

    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.ivf, .failed_to_read, "header");

    if (bytes_read < 32) {
        return ValidationResult.invalidCode(.ivf, .file_too_small, "IVF header");
    }

    // Check signature "DKIF"
    if (!std.mem.eql(u8, header[0..4], "DKIF")) {
        return ValidationResult.invalidCode(.ivf, .invalid_signature, "IVF");
    }

    // Version (should be 0)
    const version = std.mem.readInt(u16, header[4..6], .little);
    if (version != 0) {
        return ValidationResult.invalidCode(.ivf, .unsupported, "IVF version");
    }

    // Header size (should be 32)
    const header_size = std.mem.readInt(u16, header[6..8], .little);
    if (header_size != 32) {
        return ValidationResult.invalidCode(.ivf, .invalid_value, "IVF header size");
    }

    // Codec FourCC at offset 8-12 (VP80, VP90, AV01, etc.)
    const codec = header[8..12];
    const valid_codecs = [_][]const u8{ "VP80", "VP90", "AV01" };
    var valid_codec = false;
    for (valid_codecs) |vc| {
        if (std.mem.eql(u8, codec, vc)) {
            valid_codec = true;
            break;
        }
    }
    if (!valid_codec) {
        // Unknown codec but structure is valid
    }

    // Width and height (sanity check)
    const width = std.mem.readInt(u16, header[12..14], .little);
    const height = std.mem.readInt(u16, header[14..16], .little);
    if (width == 0 or height == 0 or width > 8192 or height > 8192) {
        return ValidationResult.invalidCode(.ivf, .invalid_value, "IVF dimensions");
    }

    return ValidationResult.okWithDepth(.ivf, .structural);
}

/// Deep IVF validation — dispatches to VP9/AV1 codec validators for frame-level integrity.
/// IVF frames are preceded by 12-byte headers: frame_size(u32 LE) + timestamp(u64 LE).
pub fn validateIvfDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.ivf, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.ivf, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(.ivf, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.ivf, .failed_to_get, "file size", .full);
    };

    if (file_size < 32) {
        return ValidationResult.invalidCodeWithDepth(.ivf, .file_too_small, "IVF header", .structural);
    }

    // Read IVF 32-byte header
    var header: [32]u8 = undefined;
    _ = file.readAll(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.ivf, .failed_to_read, "header", .structural);
    };

    if (!std.mem.eql(u8, header[0..4], "DKIF")) {
        return ValidationResult.invalidCodeWithDepth(.ivf, .invalid_signature, "IVF", .structural);
    }

    const codec = header[8..12];
    const is_vp9 = std.mem.eql(u8, codec, "VP90");
    const is_av1 = std.mem.eql(u8, codec, "AV01");

    if (!is_vp9 and !is_av1) {
        // VP80 or unknown codec — no deep validator available, structural only
        return ValidationResult.okWithDepthAndWarning(.ivf, .structural, "No deep validator for this codec");
    }

    // Collect frame data from IVF frame table
    const max_frames: u32 = 100;
    var offset: u64 = 32;

    if (is_av1) {
        // AV1: concatenate all frame data for stream validation
        var total_size: usize = 0;
        var frame_count: u32 = 0;

        // First pass: compute total size
        var scan_offset: u64 = 32;
        while (scan_offset + 12 <= file_size and frame_count < max_frames) {
            var frame_header: [12]u8 = undefined;
            file.seekTo(scan_offset) catch break;
            const fh_read = file.read(&frame_header) catch break;
            if (fh_read < 12) break;

            const frame_size = std.mem.readInt(u32, frame_header[0..4], .little);
            if (frame_size == 0 or scan_offset + 12 + frame_size > file_size) break;

            total_size += frame_size;
            scan_offset += 12 + frame_size;
            frame_count += 1;
        }

        if (frame_count == 0) {
            return ValidationResult.okWithDepthAndWarning(.ivf, .structural, "No frames found in IVF");
        }

        const av1_data = allocator.alloc(u8, total_size) catch {
            return ValidationResult.invalidCodeWithDepth(.ivf, .out_of_memory, "for AV1 frames", .structural);
        };
        defer allocator.free(av1_data);

        // Second pass: read frame data
        var write_pos: usize = 0;
        offset = 32;
        frame_count = 0;
        while (offset + 12 <= file_size and frame_count < max_frames) {
            var frame_header: [12]u8 = undefined;
            file.seekTo(offset) catch break;
            const fh_read = file.read(&frame_header) catch break;
            if (fh_read < 12) break;

            const frame_size = std.mem.readInt(u32, frame_header[0..4], .little);
            if (frame_size == 0 or offset + 12 + frame_size > file_size) break;

            const bytes_read = file.readAll(av1_data[write_pos..][0..frame_size]) catch break;
            if (bytes_read < frame_size) break;

            write_pos += frame_size;
            offset += 12 + frame_size;
            frame_count += 1;
        }

        const result = av1_obu_validator.validateAv1Stream(av1_data[0..write_pos], max_frames);
        if (!result.valid) {
            const msg = if (result.error_message) |m| std.mem.span(m) else "AV1 stream validation failed";
            return ValidationResult.invalidWithDepth(.ivf, msg, .full);
        }
        return ValidationResult.okWithDepth(.ivf, .full);
    } else {
        // VP9: collect individual frame slices for stream validation
        var frame_slices: [100][]const u8 = undefined;
        var frame_allocs: [100][]u8 = undefined;
        var frame_count: u32 = 0;

        defer {
            for (frame_allocs[0..frame_count]) |alloc| {
                allocator.free(alloc);
            }
        }

        while (offset + 12 <= file_size and frame_count < max_frames) {
            var frame_header: [12]u8 = undefined;
            file.seekTo(offset) catch break;
            const fh_read = file.read(&frame_header) catch break;
            if (fh_read < 12) break;

            const frame_size = std.mem.readInt(u32, frame_header[0..4], .little);
            if (frame_size == 0 or offset + 12 + frame_size > file_size) break;

            const frame_data = allocator.alloc(u8, frame_size) catch break;
            const bytes_read = file.readAll(frame_data) catch {
                allocator.free(frame_data);
                break;
            };
            if (bytes_read < frame_size) {
                allocator.free(frame_data);
                break;
            }

            frame_allocs[frame_count] = frame_data;
            frame_slices[frame_count] = frame_data;
            frame_count += 1;
            offset += 12 + frame_size;
        }

        if (frame_count == 0) {
            return ValidationResult.okWithDepthAndWarning(.ivf, .structural, "No frames found in IVF");
        }

        const result = vp9_syntax_validator.validateVp9Stream(frame_slices[0..frame_count], max_frames);
        if (!result.valid) {
            const msg = if (result.error_message) |m| std.mem.span(m) else "VP9 stream validation failed";
            return ValidationResult.invalidWithDepth(.ivf, msg, .full);
        }
        return ValidationResult.okWithDepth(.ivf, .full);
    }
}

// ============ Video Deep Validation ============

/// Default maximum file size for deep video validation (unlimited)
pub const DEFAULT_MAX_VIDEO_DEEP_SIZE: u64 = std.math.maxInt(u64);

/// Get maximum file size for deep video validation from environment variable.
/// Reads MAX_VIDEO_SIZE env var (in MB). Defaults to unlimited.
/// Set to a number to limit deep validation to files under that many MB.
pub fn getMaxVideoDeepSize() u64 {
    return parseMaxVideoDeepSize(format_validation.getenvCrossPlatform("MAX_VIDEO_SIZE"));
}

pub fn parseMaxVideoDeepSize(env: ?[:0]const u8) u64 {
    const value = env orelse return DEFAULT_MAX_VIDEO_DEEP_SIZE;
    const mb = std.fmt.parseInt(u64, value, 10) catch return DEFAULT_MAX_VIDEO_DEEP_SIZE;
    return mb * 1024 * 1024; // Convert MB to bytes
}

/// Deep MP4/ISOBMFF validation - validates all box sizes and structure.
/// Also validates video stream integrity using pure-Zig codec validators.
pub fn validateMp4Deep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.mp4, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.mp4, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.mp4, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.mp4, .failed_to_get, "file size", .structural);
    };

    // Validate all boxes in the file
    var position: u64 = 0;
    var box_count: usize = 0;
    var found_ftyp = false;
    var found_moov = false;
    var found_mdat = false;
    var ftyp_brand: [4]u8 = undefined; // Major brand from ftyp box
    const max_boxes: usize = 1000; // Sanity limit

    while (position < file_size and box_count < max_boxes) {
        file.seekTo(position) catch {
            return ValidationResult.invalidWithDepth(.mp4, "Seek failed during box scan", .structural);
        };

        var box_header: [8]u8 = undefined;
        const header_read = file.read(&box_header) catch break;
        if (header_read < 8) break;

        const box_size = std.mem.readInt(u32, box_header[0..4], .big);
        const box_type = box_header[4..8];

        // Validate box type is printable ASCII (0x20-0x7E).
        // Apple MP4 files can have trailing non-box metadata after the last
        // real box. If we hit non-ASCII, stop parsing rather than failing.
        var valid_type = true;
        for (box_type) |c| {
            if (c < 0x20 or c > 0x7E) {
                valid_type = false;
                break;
            }
        }
        if (!valid_type) break; // Trailing data, not a real box

        // Handle extended size (size == 1 means 64-bit size follows)
        var actual_size: u64 = box_size;
        if (box_size == 1) {
            var ext_size: [8]u8 = undefined;
            const ext_read = file.read(&ext_size) catch {
                return ValidationResult.invalidCodeWithDepth(.mp4, .failed_to_read, "extended size", .structural);
            };
            if (ext_read < 8) {
                return ValidationResult.invalidCodeWithDepth(.mp4, .truncated, "extended size", .structural);
            }
            actual_size = std.mem.readInt(u64, &ext_size, .big);
            if (actual_size < 16) {
                return ValidationResult.invalidCodeWithDepth(.mp4, .invalid_value, "extended box size", .structural);
            }
        } else if (box_size == 0) {
            // Box extends to end of file
            actual_size = file_size - position;
        }

        // Validate box doesn't exceed file bounds
        if (position + actual_size > file_size) {
            return ValidationResult.invalidCodeMsgWithDepth(.mp4, .exceeds_bounds, "Box", "Box exceeds file bounds", .structural);
        }

        // Track important boxes
        if (std.mem.eql(u8, box_type, "ftyp")) {
            found_ftyp = true;
            // Read the major brand (first 4 bytes after box header)
            _ = file.read(&ftyp_brand) catch {};
        }
        if (std.mem.eql(u8, box_type, "moov")) found_moov = true;
        if (std.mem.eql(u8, box_type, "mdat")) found_mdat = true;

        position += actual_size;
        box_count += 1;
    }

    // Determine format from ftyp major brand
    // Classic QuickTime files pre-date ISO BMFF and don't have ftyp
    const format: FileFormat = if (!found_ftyp) .mov else if (std.mem.eql(u8, &ftyp_brand, "M4A ") or std.mem.eql(u8, &ftyp_brand, "M4B ")) .m4a else if (std.mem.eql(u8, &ftyp_brand, "qt  ")) .mov else .mp4;

    // For ISO BMFF (.mp4), ftyp is required - but we already know found_ftyp is true if format is .mp4
    // For classic QuickTime (.mov), we need moov or mdat instead
    if (!found_ftyp and !found_moov and !found_mdat) {
        return ValidationResult.invalidCodeWithDepth(.mov, .missing, "moov or mdat box", .structural);
    }

    // A valid file should have either moov or mdat (or both)
    if (!found_moov and !found_mdat) {
        return ValidationResult.invalidCodeWithDepth(format, .missing, "moov/mdat boxes", .structural);
    }

    // Skip deep validation for large files (when MAX_VIDEO_SIZE is set)
    if (file_size > getMaxVideoDeepSize()) {
        return ValidationResult.structuralOnly(format);
    }

    // Structural validation passed - now attempt video stream validation
    // This parses the container to find video tracks and validates codec info
    const video_result = video_validator.validateMp4Video(allocator, path, std.math.maxInt(u32));

    // Check if this is an audio-only file (M4A) - no video track is expected
    const is_audio_only = video_result.error_message != null and
        std.mem.indexOf(u8, video_result.error_message.?, "No video track found") != null;

    if (!video_result.valid and !is_audio_only) {
        if (toleratedVideoDecodeFailure(video_result)) |tolerated| {
			// When no frames decoded, always use structural depth - we didn't actually decode video
			const depth: ValidationDepth = if (video_result.frames_decoded > 0 and video_result.byte_validated) .full else .structural;
			var result = ValidationResult.okWithDepthAndMalformation(format, depth, tolerated.malformation);
			result.warning_message = tolerated.warning;
			return result;
		}
        // Video codec validation failed
        return ValidationResult.invalidWithDepth(format, video_result.error_message orelse "Video validation failed", .full);
    }

    // Video validation passed - now validate audio track if present
    const audio_result = video_audio_validator.validateMp4Audio(allocator, path);

    // Audio validation failure is a real failure (corruption), not just "unsupported codec"
    if (!audio_result.valid and audio_result.error_message != null) {
        // Check if it's an actual failure vs just unsupported codec
        const err_msg = audio_result.error_message.?;
        const is_unsupported = std.mem.indexOf(u8, err_msg, "not supported") != null or
            std.mem.indexOf(u8, err_msg, "Unsupported") != null;
        if (!is_unsupported) {
            return ValidationResult.invalidWithDepth(format, err_msg, .full);
        }
    }

    // Return with appropriate depth based on validation level
    // For video files: video byte-validation is the primary indicator
    // For audio-only files (M4A): audio validation is the primary indicator
    const audio_validated = audio_result.valid and audio_result.frames_decoded > 0;
    const has_audio = audio_result.codec != .unknown;

    // Determine validation depth
    var result = if (is_audio_only) blk: {
        // Audio-only file (M4A): audio validation determines depth
        // Adjust format to m4a for correct output
        break :blk if (audio_validated)
            ValidationResult.okWithDepth(.m4a, .full)
        else if (audio_result.valid)
            ValidationResult.structuralOnly(.m4a) // Audio track found but not decoded
        else
            ValidationResult.invalidWithDepth(.m4a, audio_result.error_message orelse "Audio validation failed", .full);
    } else blk: {
        // Video file: video validation determines depth
        break :blk if (video_result.byte_validated)
            ValidationResult.okWithDepth(format, .full)
        else
            ValidationResult.structuralOnly(format);
    };
    if (video_result.validated_via_ffmpeg) {
        result.validated_via_ffmpeg = true;
    }

    if (video_result.mixed_nal_prefix) {
        result.malformations.insert(.video_mixed_nal_prefix);
        result.warning_message = "mixed NAL prefix sizes detected (repairable by remux)";
    }
    // Check for unsupported profile warning
    if (video_result.unsupported_profile_no_ffmpeg) {
        result.malformations.insert(.video_unsupported_profile_no_ffmpeg);
        result.warning_message = "full validation of this file requires ffmpeg (v4.0+) on PATH due to H.264 profile complexity";
    }
    // Audio not fully validated → not every byte is verified → downgrade from .full
    if (has_audio and !audio_validated) {
        if (result.validation_depth == .full) {
            result.validation_depth = .structural;
        }
        if (result.warning_message == null) {
            if (audio_result.codec == .pcm) {
                result.warning_message = "PCM audio track cannot be integrity-checked (raw unstructured samples)";
            } else {
                result.warning_message = "audio track not fully decoded (decode validation not yet implemented for this codec)";
            }
        }
    }
    return result;
}

/// Deep MKV/EBML validation - validates element structure.
/// Only performs deep validation for files under 100MB.
pub fn validateMkvDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.mkv, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.mkv, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_get, "file size", .structural);
    };

    // Skip deep validation for large files (when MAX_VIDEO_SIZE is set)
    if (file_size > getMaxVideoDeepSize()) {
        return ValidationResult.structuralOnly(.mkv);
    }

    // Verify EBML header
    var header: [4]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_read, "EBML header", .structural);
    };

    if (!std.mem.eql(u8, &header, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return ValidationResult.invalidCodeWithDepth(.mkv, .invalid_signature, "EBML", .structural);
    }

    // Read EBML header size (variable-length integer)
    var size_byte: [1]u8 = undefined;
    _ = file.read(&size_byte) catch {
        return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_read, "EBML header size", .structural);
    };

    // VINT decoding: leading bit determines byte count
    // Mask table for stripping the VINT marker bits
    const vint_masks = [_]u8{ 0x7F, 0x3F, 0x1F, 0x0F, 0x07, 0x03, 0x01, 0x00 };

    // Count leading ones to determine size
    var size_bytes: usize = 1;
    var test_bit: u8 = 0x80;
    while ((size_byte[0] & test_bit) != 0 and size_bytes < 8) : ({
        test_bit >>= 1;
        size_bytes += 1;
    }) {}

    if (size_bytes > 8 or (size_byte[0] & test_bit) == 0) {
        // First byte must have the marker bit set
        if (size_byte[0] == 0) {
            return ValidationResult.invalidCodeWithDepth(.mkv, .invalid_value, "EBML size encoding", .structural);
        }
    }

    // Count leading zeros to determine VINT byte count
    // EBML VINT: 1xxxxxxx = 1 byte, 01xxxxxx = 2 bytes, 001xxxxx = 3 bytes, etc.
    const leading_zeros = @clz(size_byte[0]);
    if (leading_zeros > 7) {
        return ValidationResult.invalidCodeWithDepth(.mkv, .invalid_value, "EBML size encoding", .structural);
    }
    size_bytes = @as(usize, leading_zeros) + 1;

    var size_data: [8]u8 = [_]u8{0} ** 8;
    size_data[8 - size_bytes] = size_byte[0] & vint_masks[leading_zeros];

    if (size_bytes > 1) {
        const remaining = size_bytes - 1;
        const read_bytes = file.read(size_data[8 - remaining ..]) catch {
            return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_read, "EBML size", .structural);
        };
        if (read_bytes < remaining) {
            return ValidationResult.invalidCodeWithDepth(.mkv, .truncated, "EBML size", .structural);
        }
    }

    const header_size = std.mem.readInt(u64, &size_data, .big);
    const header_end = 4 + size_bytes + header_size;

    if (header_end > file_size) {
        return ValidationResult.invalidCodeMsgWithDepth(.mkv, .exceeds_bounds, "EBML header", "EBML header exceeds file size", .structural);
    }

    // Look for Segment element after EBML header
    file.seekTo(header_end) catch {
        return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_seek, "past EBML header", .structural);
    };

    var segment_id: [4]u8 = undefined;
    const seg_read = file.read(&segment_id) catch {
        return ValidationResult.invalidCodeWithDepth(.mkv, .failed_to_read, "Segment ID", .structural);
    };

    if (seg_read < 4) {
        return ValidationResult.invalidCodeWithDepth(.mkv, .file_too_small, "Segment", .structural);
    }

    // Segment ID is 0x18538067
    if (!std.mem.eql(u8, &segment_id, &[_]u8{ 0x18, 0x53, 0x80, 0x67 })) {
        return ValidationResult.invalidCodeWithDepth(.mkv, .missing, "Segment element", .structural);
    }

    // Structural validation passed - now do codec validation (video + audio)
    const media_result = video_audio_validator.validateMkvMedia(allocator, path, std.math.maxInt(u32));

    // Handle video validation results
    if (media_result.has_video_track) {
        // Get the video-specific result from the media result
        const video_result = video_validator.VideoValidationResult{
            .valid = media_result.video_valid,
            .error_message = media_result.video_message,
            .frames_decoded = media_result.video_frames_decoded,
            .byte_validated = media_result.crc_validated or (media_result.video_valid and media_result.video_frames_decoded > 0),
            .codec = media_result.video_codec,
            .validated_via_ffmpeg = false, // Not available in MediaValidationResult

            .mixed_nal_prefix = false,
            .unsupported_profile_no_ffmpeg = false,
        };

        if (!video_result.valid) {
            if (toleratedVideoDecodeFailure(video_result)) |tolerated| {
                // When no frames decoded, always use structural depth - we didn't actually decode video
                const depth: ValidationDepth = if (video_result.frames_decoded > 0 and video_result.byte_validated) .full else .structural;
                var result = ValidationResult.okWithDepthAndMalformation(.mkv, depth, tolerated.malformation);
                result.warning_message = tolerated.warning;
                return result;
            }
            return ValidationResult.invalidWithDepth(.mkv, video_result.error_message orelse "Video validation failed", .full);
        }
    }

    // Handle audio validation results
    if (media_result.has_audio_track and !media_result.audio_valid) {
        // Audio validation failed
        return ValidationResult.invalidWithDepth(.mkv, media_result.audio_message orelse "Audio validation failed", .full);
    }

    // Determine overall validation depth
    const video_byte_validated = media_result.has_video_track and media_result.video_valid and media_result.video_frames_decoded > 0;
    const audio_byte_validated = media_result.has_audio_track and media_result.audio_valid and media_result.audio_frames_decoded > 0;
    const audio_is_pcm = media_result.has_audio_track and media_result.audio_codec == .pcm;

    // Full validation requires at least one track to be byte-validated,
    // OR CRC-validated (CRC covers all cluster bytes without needing decode)
    const byte_validated = video_byte_validated or audio_byte_validated or media_result.crc_validated;

    var result = if (byte_validated)
        ValidationResult.okWithDepth(.mkv, .full)
    else
        ValidationResult.structuralOnly(.mkv);

    // Add PCM warning when audio is PCM (integrity cannot be verified)
    if (audio_is_pcm and result.warning_message == null) {
        result.warning_message = "PCM audio track cannot be integrity-checked (raw unstructured samples)";
    }

    return result;
}

/// Deep AVI validation - validates video frames by decoding.
/// Supports MJPEG, H.264, MPEG-1/2 codecs.
/// Only performs deep validation for files under 100MB.
pub fn validateAviDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.avi, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.avi, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.avi, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.avi, .failed_to_get, "file size", .structural);
    };

    // Skip deep validation for large files (when MAX_VIDEO_SIZE is set)
    if (file_size > getMaxVideoDeepSize()) {
        return ValidationResult.structuralOnly(.avi);
    }

    // Validate RIFF header first (structural check)
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.avi, .failed_to_read, "RIFF header", .structural);
    };

    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCodeWithDepth(.avi, .invalid_signature, "RIFF", .structural);
    }

    if (!std.mem.eql(u8, header[8..12], "AVI ")) {
        return ValidationResult.invalidCodeWithDepth(.avi, .invalid_value, "AVI fourcc", .structural);
    }

    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    if (@as(u64, riff_size) + 8 > file_size) {
        return ValidationResult.invalidCodeMsgWithDepth(.avi, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size", .structural);
    }

    // Now do video frame validation
    const video_result = video_validator.validateAviVideo(allocator, path, std.math.maxInt(u32));
    if (!video_result.valid) {
        if (toleratedVideoDecodeFailure(video_result)) |tolerated| {
			// When no frames decoded, always use structural depth - we didn't actually decode video
			const depth: ValidationDepth = if (video_result.frames_decoded > 0 and video_result.byte_validated) .full else .structural;
			var result = ValidationResult.okWithDepthAndMalformation(.avi, depth, tolerated.malformation);
			result.warning_message = tolerated.warning;
			return result;
		}
        return ValidationResult.invalidWithDepth(.avi, video_result.error_message orelse "Video validation failed", .full);
    }

    var result = if (video_result.byte_validated)
        ValidationResult.okWithDepth(.avi, .full)
    else
        ValidationResult.structuralOnly(.avi);
    if (video_result.validated_via_ffmpeg) {
        result.validated_via_ffmpeg = true;
    }

    // Check for unsupported profile warning
    if (video_result.unsupported_profile_no_ffmpeg) {
        result.malformations.insert(.video_unsupported_profile_no_ffmpeg);
        result.warning_message = "full validation of this file requires ffmpeg (v4.0+) on PATH due to H.264 profile complexity";
    }
    return result;
}

// ============ Buffer-based Validators ============

pub fn validateMp4FromBuffer(data: []const u8) ValidationResult {
    if (data.len < 8) return ValidationResult.invalid(.mp4, "File too small");
    // Check for ftyp box
    if (std.mem.eql(u8, data[4..8], "ftyp")) {
        return ValidationResult.ok(.mp4);
    }
    return ValidationResult.invalidCode(.mp4, .invalid_signature, "MP4");
}

pub fn validateMkvFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(.mkv, "File too small");
    // EBML signature
    if (data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3) {
        return ValidationResult.ok(.mkv);
    }
    return ValidationResult.invalidCode(.mkv, .invalid_signature, "MKV/WebM");
}

pub fn validateAviFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) return ValidationResult.invalid(.avi, "File too small");
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "AVI ")) {
        return ValidationResult.ok(.avi);
    }
    return ValidationResult.invalidCode(.avi, .invalid_signature, "AVI");
}

// ============ ASF/WMV/WMA Validator ============

/// Validate ASF (Advanced Systems Format) file structure. Used by WMV video and WMA audio.
/// 16-byte GUID header + object size(8,LE) + num_objects(4,LE) + reserved(2) = 30 bytes minimum.
pub fn validateAsf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.asf, "Failed to seek");

    var header: [30]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.asf, .failed_to_read, "ASF header");

    if (bytes_read < 30) {
        return ValidationResult.invalidCode(.asf, .file_too_small, "ASF header");
    }

    // ASF Header Object GUID
    const asf_header_guid = [_]u8{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C };
    if (!std.mem.eql(u8, header[0..16], &asf_header_guid)) {
        return ValidationResult.invalidCode(.asf, .invalid_value, "ASF Header Object GUID");
    }

    const object_size = std.mem.readInt(u64, header[16..24], .little);
    if (object_size < 30) {
        return ValidationResult.invalid(.asf, "ASF Header Object size too small");
    }

    const file_size = file.getEndPos() catch {
        return ValidationResult.structuralOnly(.asf);
    };
    if (object_size > file_size) {
        return ValidationResult.invalidCodeMsg(.asf, .exceeds_bounds, "ASF Header Object size", "ASF Header Object size exceeds file size (truncated)");
    }

    const num_header_objects = std.mem.readInt(u32, header[24..28], .little);
    if (num_header_objects == 0) {
        return ValidationResult.invalid(.asf, "ASF header contains no sub-objects");
    }
    if (num_header_objects > 10000) {
        return ValidationResult.invalid(.asf, "ASF header object count unreasonably large");
    }

    return ValidationResult.structuralOnly(.asf);
}

// ============ DV Validator ============

/// Validate DV (Digital Video) raw stream.
/// DV uses 80-byte DIF (Digital Interface Format) blocks.
/// First block: section type = 000 (header section) in high 3 bits of byte 0.
pub fn validateDv(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.dv, "Failed to seek");

    var header: [80]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.dv, .failed_to_read, "DV header");

    if (bytes_read < 80) {
        return ValidationResult.invalidCode(.dv, .file_too_small, "DV DIF block (need 80 bytes)");
    }

    // Section type in high 3 bits of byte 0: should be 000 (header section)
    const section_type = (header[0] >> 5) & 0x07;
    if (section_type != 0) {
        return ValidationResult.invalid(.dv, "First DIF block is not a header section");
    }

    // DIF block number (byte 2) should be 0 for first block
    if (header[2] != 0) {
        return ValidationResult.invalid(.dv, "First DIF block number is not 0");
    }

    // Check for a second DIF block at offset 80
    const file_size = file.getEndPos() catch {
        return ValidationResult.structuralOnly(.dv);
    };

    if (file_size >= 160) {
        var second_block: [3]u8 = undefined;
        file.seekTo(80) catch return ValidationResult.structuralOnly(.dv);
        const second_read = file.read(&second_block) catch return ValidationResult.structuralOnly(.dv);

        if (second_read >= 1) {
            const second_section_type = (second_block[0] >> 5) & 0x07;
            // Second block should be subcode section (001)
            if (second_section_type != 1) {
                return ValidationResult.structuralOnly(.dv);
            }
        }
    }

    return ValidationResult.structuralOnly(.dv);
}

// ============ Tests ============

test "parseMaxVideoDeepSize defaults to unlimited and honors MAX_VIDEO_SIZE" {
	try std.testing.expectEqual(std.math.maxInt(u64), parseMaxVideoDeepSize(null));
	try std.testing.expectEqual(std.math.maxInt(u64), parseMaxVideoDeepSize("invalid"));
	try std.testing.expectEqual(@as(u64, 1024 * 1024), parseMaxVideoDeepSize("1"));
}
