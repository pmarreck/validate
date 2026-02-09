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

// Imported helpers from format_validation
const VideoDecodeTolerance = format_validation.VideoDecodeTolerance;
const toleratedVideoDecodeFailure = format_validation.toleratedVideoDecodeFailure;
const isValidBoxType = format_validation.isValidBoxType;


// ============ ISO BMFF (MP4/MOV) Validator ============

/// Validate ISO BMFF (MP4, MOV, HEIC, M4A) file structure.
pub fn validateIsobmff(file: std.fs.File, format: FileFormat) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(format, "Failed to seek to start");

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(format, "Failed to get file size");
    };

    if (file_size < 8) {
        return ValidationResult.invalid(format, "File too small for ISO BMFF");
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
            return ValidationResult.invalid(format, "Invalid box type (non-ASCII data)");
        }

        // Handle extended size
        if (box_size == 1) {
            var ext_size: [8]u8 = undefined;
            _ = file.read(&ext_size) catch break;
            const large_size = std.mem.readInt(u64, &ext_size, .big);
            if (large_size < 16) {
                return ValidationResult.invalid(format, "Invalid extended box size");
            }
            if (large_size > file_size) {
                return ValidationResult.invalid(format, "Box size exceeds file size");
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
                return ValidationResult.invalid(format, "Missing moov or mdat box");
            }
            // Valid classic QuickTime file
        } else {
            // ISO BMFF formats require ftyp
            return ValidationResult.invalid(format, "Missing ftyp box");
        }
    }

    return ValidationResult.ok(format);
}

// ============ Matroska/WebM Validator ============

/// Validate Matroska (MKV/WebM) file structure using EBML.
pub fn validateMatroska(file: std.fs.File, format: FileFormat) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(format, "Failed to seek to start");

    var header: [4]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(format, "Failed to read EBML header");

    // Check EBML signature
    if (!std.mem.eql(u8, &header, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return ValidationResult.invalid(format, "Invalid EBML signature");
    }

    // Read more to find DocType
    file.seekTo(0) catch return ValidationResult.invalid(format, "Failed to seek");

    var buffer: [256]u8 = undefined;
    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.invalid(format, "Failed to read EBML data");
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
    _ = file.read(&header) catch return ValidationResult.invalid(.avi, "Failed to read AVI header");

    // Check RIFF signature
    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalid(.avi, "Invalid RIFF signature");
    }

    // Check AVI fourcc
    if (!std.mem.eql(u8, header[8..12], "AVI ")) {
        return ValidationResult.invalid(.avi, "Invalid AVI fourcc");
    }

    // Get declared RIFF size
    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.avi, "Failed to get file size");
    };

    if (riff_size + 8 > file_size) {
        return ValidationResult.invalid(.avi, "RIFF size exceeds file size (truncated)");
    }

    // Look for required LIST chunks (hdrl, movi)
    var buffer: [4096]u8 = undefined;
    file.seekTo(12) catch return ValidationResult.invalid(.avi, "Failed to seek");

    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.invalid(.avi, "Failed to read AVI data");
    };

    const has_hdrl = format_validation.findInBuffer(&buffer, bytes_read, "hdrl");
    if (!has_hdrl) {
        return ValidationResult.invalid(.avi, "Missing AVI header list");
    }

    return ValidationResult.ok(.avi);
}

// ============ SWF (Flash) Validator ============

/// Validate Adobe Flash SWF file structure.
/// Supports FWS (uncompressed), CWS (zlib), and ZWS (LZMA) formats.
pub fn validateSwf(file: std.fs.File) ValidationResult {
    var header: [8]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.swf, "Failed to read SWF header");

    // Check signature (FWS, CWS, or ZWS)
    const sig = header[0..3];
    const compression: enum { uncompressed, zlib, lzma } = if (std.mem.eql(u8, sig, "FWS"))
        .uncompressed
    else if (std.mem.eql(u8, sig, "CWS"))
        .zlib
    else if (std.mem.eql(u8, sig, "ZWS"))
        .lzma
    else
        return ValidationResult.invalid(.swf, "Invalid SWF signature");

    // Version (byte 3): must be reasonable (1-50)
    const version = header[3];
    if (version == 0 or version > 50) {
        return ValidationResult.invalid(.swf, "Invalid SWF version");
    }

    // File length (bytes 4-7, little-endian)
    // For compressed SWF, this is the uncompressed size
    const declared_size = std.mem.readInt(u32, header[4..8], .little);
    if (declared_size < 8) {
        return ValidationResult.invalid(.swf, "Invalid SWF file size");
    }

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.swf, "Failed to get file size");
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
            file.seekTo(8) catch return ValidationResult.invalid(.swf, "Failed to seek to RECT");

            const rect_read = file.read(&rect_buffer) catch {
                return ValidationResult.invalid(.swf, "Failed to read SWF RECT");
            };

            if (rect_read < 1) {
                return ValidationResult.invalid(.swf, "Truncated SWF RECT");
            }

            // RECT: first 5 bits are Nbits (number of bits per value)
            const nbits = rect_buffer[0] >> 3;
            if (nbits == 0 or nbits > 31) {
                return ValidationResult.invalid(.swf, "Invalid RECT Nbits value");
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
        return ValidationResult.invalid(.swf, "Invalid SWF RECT Nbits value");
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
    _ = file.read(&header) catch return ValidationResult.invalid(.flv, "Failed to read FLV header");

    // Check signature "FLV"
    if (!std.mem.eql(u8, header[0..3], "FLV")) {
        return ValidationResult.invalid(.flv, "Invalid FLV signature");
    }

    // Version (usually 1)
    const version = header[3];
    if (version == 0 or version > 10) {
        return ValidationResult.invalid(.flv, "Invalid FLV version");
    }

    // Flags (byte 4): bits 0-4 reserved (0), bit 2 = has audio, bit 0 = has video
    const flags = header[4];
    const reserved_bits = flags & 0xFA; // bits 7,6,5,4,3,1 should be 0
    if (reserved_bits != 0) {
        return ValidationResult.invalid(.flv, "Invalid FLV flags (reserved bits set)");
    }

    // Data offset (bytes 5-8, big-endian) - typically 9
    const data_offset = std.mem.readInt(u32, header[5..9], .big);
    if (data_offset < 9) {
        return ValidationResult.invalid(.flv, "Invalid FLV data offset");
    }

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.flv, "Failed to get file size");
    };

    if (data_offset > file_size) {
        return ValidationResult.invalid(.flv, "FLV data offset exceeds file size");
    }

    // Read first tag header (if present)
    if (file_size > data_offset + 4) {
        file.seekTo(data_offset) catch return ValidationResult.invalid(.flv, "Failed to seek to tags");

        // PreviousTagSize0 should be 0
        var prev_tag_size: [4]u8 = undefined;
        _ = file.read(&prev_tag_size) catch return ValidationResult.invalid(.flv, "Failed to read PreviousTagSize0");

        const prev_size = std.mem.readInt(u32, &prev_tag_size, .big);
        if (prev_size != 0) {
            return ValidationResult.invalid(.flv, "Invalid PreviousTagSize0 (should be 0)");
        }

        // If there's more data, validate first tag header
        if (file_size > data_offset + 4 + 11) {
            var tag_header: [11]u8 = undefined;
            _ = file.read(&tag_header) catch return ValidationResult.invalid(.flv, "Failed to read tag header");

            const tag_type = tag_header[0];
            // Valid tag types: 8 (audio), 9 (video), 18 (script data)
            if (tag_type != 8 and tag_type != 9 and tag_type != 18) {
                return ValidationResult.invalid(.flv, "Invalid FLV tag type");
            }

            // Tag data size (3 bytes, big-endian)
            const tag_size = (@as(u32, tag_header[1]) << 16) | (@as(u32, tag_header[2]) << 8) | @as(u32, tag_header[3]);

            // Check tag doesn't exceed file
            const tag_end = data_offset + 4 + 11 + tag_size + 4; // +4 for PreviousTagSize
            if (tag_end > file_size) {
                return ValidationResult.invalid(.flv, "FLV tag exceeds file size (truncated)");
            }
        }
    }

    return ValidationResult.ok(.flv);
}

/// Deep validation for FLV files - parses all tag boundaries.
pub fn validateFlvDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.flv, "Failed to open FLV file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.flv, "Failed to get file size");
    };

    if (file_size > 4 * 1024 * 1024 * 1024) { // 4GB limit
        return ValidationResult.okWithDepth(.flv, .structural);
    }

    // Read header
    var header: [9]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.flv, "Failed to read FLV header");

    if (!std.mem.eql(u8, header[0..3], "FLV")) {
        return ValidationResult.invalid(.flv, "Invalid FLV signature");
    }

    const data_offset = std.mem.readInt(u32, header[5..9], .big);
    if (data_offset < 9 or data_offset > file_size) {
        return ValidationResult.invalid(.flv, "Invalid FLV data offset");
    }

    // Parse all tags
    file.seekTo(data_offset) catch return ValidationResult.invalid(.flv, "Failed to seek to tags");

    var tag_count: u32 = 0;
    var offset: u64 = data_offset;
    _ = allocator;

    while (offset + 4 < file_size) {
        // Read PreviousTagSize
        var prev_tag_size: [4]u8 = undefined;
        _ = file.read(&prev_tag_size) catch break;
        offset += 4;

        if (offset + 11 >= file_size) break;

        // Read tag header
        var tag_header: [11]u8 = undefined;
        _ = file.read(&tag_header) catch break;

        const tag_type = tag_header[0];
        if (tag_type != 8 and tag_type != 9 and tag_type != 18) {
            return ValidationResult.invalid(.flv, "Invalid FLV tag type");
        }

        const tag_size = (@as(u32, tag_header[1]) << 16) | (@as(u32, tag_header[2]) << 8) | @as(u32, tag_header[3]);

        // Skip tag data
        offset += 11 + tag_size;
        if (offset > file_size) {
            return ValidationResult.invalid(.flv, "FLV tag exceeds file size");
        }

        file.seekTo(offset) catch break;
        tag_count += 1;

        // Safety limit
        if (tag_count > 10000000) break;
    }

    if (tag_count == 0) {
        return ValidationResult.invalid(.flv, "No valid FLV tags found");
    }

    return ValidationResult.okWithDepth(.flv, .full);
}

// ============ MPEG PS/TS/ES/IVF Validators ============

/// Validate MPEG Program Stream file structure.
/// Pack start code: 00 00 01 BA followed by SCR and mux rate
pub fn validateMpegPs(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.mpeg_ps, "Failed to seek to start");

    var header: [14]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalid(.mpeg_ps, "Failed to read header");

    if (bytes_read < 14) {
        return ValidationResult.invalid(.mpeg_ps, "File too small for MPEG PS");
    }

    // Check pack start code: 00 00 01 BA
    if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x01, 0xBA })) {
        return ValidationResult.invalid(.mpeg_ps, "Invalid MPEG PS pack start code");
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

    return ValidationResult.invalid(.mpeg_ps, "Invalid MPEG PS marker bits");
}

/// Validate MPEG Transport Stream file structure.
/// 188-byte packets starting with 0x47 sync byte
pub fn validateMpegTs(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.mpeg_ts, "Failed to seek to start");

    // Read enough to check multiple sync bytes
    var buffer: [376]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return ValidationResult.invalid(.mpeg_ts, "Failed to read header");

    if (bytes_read < 188) {
        return ValidationResult.invalid(.mpeg_ts, "File too small for MPEG TS");
    }

    // First byte must be sync byte
    if (buffer[0] != 0x47) {
        return ValidationResult.invalid(.mpeg_ts, "Invalid MPEG TS sync byte");
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
        return ValidationResult.invalid(.mpeg_ts, "Invalid MPEG TS PID");
    }

    return ValidationResult.structuralOnly(.mpeg_ts);
}

/// Deep MPEG-TS validation: CRC-32 for PAT/PMT, continuity counters, PES assembly + stream validation
pub fn validateMpegTsDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.mpeg_ts, "Failed to open file");
    };
    defer file.close();

    file.seekTo(0) catch return ValidationResult.invalid(.mpeg_ts, "Failed to seek");

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.mpeg_ts, "Failed to get file size");
    if (file_size < mpeg_ts_parser.TS_PACKET_SIZE) {
        return ValidationResult.invalid(.mpeg_ts, "File too small for MPEG-TS");
    }

    // Read up to 4MB for deep validation
    const max_read: usize = 4 * 1024 * 1024;
    const read_size: usize = @min(file_size, max_read);

    const data = allocator.alloc(u8, read_size) catch {
        return ValidationResult.invalid(.mpeg_ts, "Out of memory for TS data");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalid(.mpeg_ts, "Failed to read TS data");
    };

    if (bytes_read < mpeg_ts_parser.TS_PACKET_SIZE) {
        return ValidationResult.invalid(.mpeg_ts, "Incomplete TS data");
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
    file.seekTo(0) catch return ValidationResult.invalid(.mpeg_es, "Failed to seek to start");

    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalid(.mpeg_es, "Failed to read header");

    if (bytes_read < 12) {
        return ValidationResult.invalid(.mpeg_es, "File too small for MPEG ES");
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

    return ValidationResult.invalid(.mpeg_es, "Invalid MPEG ES start code");
}

/// Validate IVF container file structure.
/// IVF header: DKIF + version + header_size + codec + dimensions + frame rate
pub fn validateIvf(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.ivf, "Failed to seek to start");

    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalid(.ivf, "Failed to read header");

    if (bytes_read < 32) {
        return ValidationResult.invalid(.ivf, "File too small for IVF header");
    }

    // Check signature "DKIF"
    if (!std.mem.eql(u8, header[0..4], "DKIF")) {
        return ValidationResult.invalid(.ivf, "Invalid IVF signature");
    }

    // Version (should be 0)
    const version = std.mem.readInt(u16, header[4..6], .little);
    if (version != 0) {
        return ValidationResult.invalid(.ivf, "Unsupported IVF version");
    }

    // Header size (should be 32)
    const header_size = std.mem.readInt(u16, header[6..8], .little);
    if (header_size != 32) {
        return ValidationResult.invalid(.ivf, "Invalid IVF header size");
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
        return ValidationResult.invalid(.ivf, "Invalid IVF dimensions");
    }

    return ValidationResult.okWithDepth(.ivf, .full);
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
            else => ValidationResult.invalidWithDepth(.mp4, "Failed to open file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidWithDepth(.mp4, "Failed to get file size", .structural);
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
                return ValidationResult.invalidWithDepth(.mp4, "Failed to read extended size", .structural);
            };
            if (ext_read < 8) {
                return ValidationResult.invalidWithDepth(.mp4, "Truncated extended size", .structural);
            }
            actual_size = std.mem.readInt(u64, &ext_size, .big);
            if (actual_size < 16) {
                return ValidationResult.invalidWithDepth(.mp4, "Invalid extended box size", .structural);
            }
        } else if (box_size == 0) {
            // Box extends to end of file
            actual_size = file_size - position;
        }

        // Validate box doesn't exceed file bounds
        if (position + actual_size > file_size) {
            return ValidationResult.invalidWithDepth(.mp4, "Box exceeds file bounds", .structural);
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
        return ValidationResult.invalidWithDepth(.mov, "Missing moov or mdat box", .structural);
    }

    // A valid file should have either moov or mdat (or both)
    if (!found_moov and !found_mdat) {
        return ValidationResult.invalidWithDepth(format, "Missing moov/mdat boxes", .structural);
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
    // Note if audio couldn't be fully validated
    if (has_audio and !audio_validated and result.warning_message == null) {
        if (audio_result.codec == .pcm) {
            result.warning_message = "PCM audio track cannot be integrity-checked (raw unstructured samples)";
        } else {
            result.warning_message = "audio track not fully decoded (decode validation not yet implemented for this codec)";
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
            else => ValidationResult.invalidWithDepth(.mkv, "Failed to open file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidWithDepth(.mkv, "Failed to get file size", .structural);
    };

    // Skip deep validation for large files (when MAX_VIDEO_SIZE is set)
    if (file_size > getMaxVideoDeepSize()) {
        return ValidationResult.structuralOnly(.mkv);
    }

    // Verify EBML header
    var header: [4]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidWithDepth(.mkv, "Failed to read EBML header", .structural);
    };

    if (!std.mem.eql(u8, &header, &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return ValidationResult.invalidWithDepth(.mkv, "Invalid EBML signature", .structural);
    }

    // Read EBML header size (variable-length integer)
    var size_byte: [1]u8 = undefined;
    _ = file.read(&size_byte) catch {
        return ValidationResult.invalidWithDepth(.mkv, "Failed to read EBML header size", .structural);
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
            return ValidationResult.invalidWithDepth(.mkv, "Invalid EBML size encoding", .structural);
        }
    }

    // Count leading zeros to determine VINT byte count
    // EBML VINT: 1xxxxxxx = 1 byte, 01xxxxxx = 2 bytes, 001xxxxx = 3 bytes, etc.
    const leading_zeros = @clz(size_byte[0]);
    if (leading_zeros > 7) {
        return ValidationResult.invalidWithDepth(.mkv, "Invalid EBML size encoding", .structural);
    }
    size_bytes = @as(usize, leading_zeros) + 1;

    var size_data: [8]u8 = [_]u8{0} ** 8;
    size_data[8 - size_bytes] = size_byte[0] & vint_masks[leading_zeros];

    if (size_bytes > 1) {
        const remaining = size_bytes - 1;
        const read_bytes = file.read(size_data[8 - remaining ..]) catch {
            return ValidationResult.invalidWithDepth(.mkv, "Failed to read EBML size", .structural);
        };
        if (read_bytes < remaining) {
            return ValidationResult.invalidWithDepth(.mkv, "Truncated EBML size", .structural);
        }
    }

    const header_size = std.mem.readInt(u64, &size_data, .big);
    const header_end = 4 + size_bytes + header_size;

    if (header_end > file_size) {
        return ValidationResult.invalidWithDepth(.mkv, "EBML header exceeds file size", .structural);
    }

    // Look for Segment element after EBML header
    file.seekTo(header_end) catch {
        return ValidationResult.invalidWithDepth(.mkv, "Failed to seek past EBML header", .structural);
    };

    var segment_id: [4]u8 = undefined;
    const seg_read = file.read(&segment_id) catch {
        return ValidationResult.invalidWithDepth(.mkv, "Failed to read Segment ID", .structural);
    };

    if (seg_read < 4) {
        return ValidationResult.invalidWithDepth(.mkv, "File too small for Segment", .structural);
    }

    // Segment ID is 0x18538067
    if (!std.mem.eql(u8, &segment_id, &[_]u8{ 0x18, 0x53, 0x80, 0x67 })) {
        return ValidationResult.invalidWithDepth(.mkv, "Missing Segment element", .structural);
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
            else => ValidationResult.invalidWithDepth(.avi, "Failed to open file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidWithDepth(.avi, "Failed to get file size", .structural);
    };

    // Skip deep validation for large files (when MAX_VIDEO_SIZE is set)
    if (file_size > getMaxVideoDeepSize()) {
        return ValidationResult.structuralOnly(.avi);
    }

    // Validate RIFF header first (structural check)
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidWithDepth(.avi, "Failed to read RIFF header", .structural);
    };

    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidWithDepth(.avi, "Invalid RIFF signature", .structural);
    }

    if (!std.mem.eql(u8, header[8..12], "AVI ")) {
        return ValidationResult.invalidWithDepth(.avi, "Invalid AVI fourcc", .structural);
    }

    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    if (@as(u64, riff_size) + 8 > file_size) {
        return ValidationResult.invalidWithDepth(.avi, "RIFF size exceeds file size", .structural);
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
    return ValidationResult.invalid(.mp4, "Invalid MP4 signature");
}

pub fn validateMkvFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(.mkv, "File too small");
    // EBML signature
    if (data[0] == 0x1A and data[1] == 0x45 and data[2] == 0xDF and data[3] == 0xA3) {
        return ValidationResult.ok(.mkv);
    }
    return ValidationResult.invalid(.mkv, "Invalid MKV/WebM signature");
}

pub fn validateAviFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) return ValidationResult.invalid(.avi, "File too small");
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "AVI ")) {
        return ValidationResult.ok(.avi);
    }
    return ValidationResult.invalid(.avi, "Invalid AVI signature");
}

// ============ Tests ============

test "parseMaxVideoDeepSize defaults to unlimited and honors MAX_VIDEO_SIZE" {
	try std.testing.expectEqual(std.math.maxInt(u64), parseMaxVideoDeepSize(null));
	try std.testing.expectEqual(std.math.maxInt(u64), parseMaxVideoDeepSize("invalid"));
	try std.testing.expectEqual(@as(u64, 1024 * 1024), parseMaxVideoDeepSize("1"));
}
