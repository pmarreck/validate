//! Archive format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for archive/compression formats: ZIP, Gzip, Bzip2, XZ, Zstandard, RAR, 7-Zip,
//! Tar, PAR2, and WARC.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const MalformationType = format_validation.MalformationType;
const ValidationDepth = format_validation.ValidationDepth;

// External module imports
const zlib = @import("zlib.zig");
const bzip2 = @import("bzip2.zig");
const sevenz_validator = @import("sevenz_validator.zig");
const rar_validator = @import("rar_validator.zig");
const errmsg = @import("error_messages.zig");

// ============ ZIP Validator ============

/// ZIP signature constants
pub const ZIP_LOCAL_FILE_HEADER: u32 = 0x04034B50;
pub const ZIP_CENTRAL_DIR_HEADER: u32 = 0x02014B50;
pub const ZIP_END_CENTRAL_DIR: u32 = 0x06054B50;

/// Validate ZIP file structure (also handles EPUB, DOCX, XLSX, PPTX).
pub fn validateZip(file: std.fs.File, format: FileFormat) ValidationResult {
    return validateZipWithOptions(file, format, false);
}

pub fn validateZipWithOptions(file: std.fs.File, format: FileFormat, skip_magic: bool) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, "to start");

    // Read first 4 bytes for signature (or skip past if skip_magic is set)
    var sig: [4]u8 = undefined;
    _ = file.read(&sig) catch return ValidationResult.invalidCode(format, .failed_to_read, "ZIP signature");

    if (!skip_magic) {
        const signature = std.mem.readInt(u32, &sig, .little);
        if (signature != ZIP_LOCAL_FILE_HEADER) {
            return ValidationResult.invalidCode(format, .invalid_signature, "ZIP");
        }
    }

    // Seek to end to find End of Central Directory
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    };

    if (file_size < 22) { // Minimum EOCD size
        return ValidationResult.invalidCode(format, .file_too_small, "valid ZIP");
    }

    // Search for EOCD signature (can have comment up to 65535 bytes)
    const search_start = if (file_size > 65557) file_size - 65557 else 0;
    file.seekTo(search_start) catch {
        return ValidationResult.invalidCode(format, .failed_to_seek, "for EOCD");
    };

    var buffer: [65557]u8 = undefined;
    const to_read = file_size - search_start;
    // Use readAll to handle potential short reads under concurrent I/O
    const bytes_read = file.readAll(buffer[0..to_read]) catch {
        return ValidationResult.invalidCode(format, .failed_to_read, "EOCD area");
    };

    // Search backwards for EOCD signature
    var found_eocd = false;
    if (bytes_read >= 22) {
        var i: usize = bytes_read - 22;
        while (true) {
            if (buffer[i] == 0x50 and buffer[i + 1] == 0x4B and
                buffer[i + 2] == 0x05 and buffer[i + 3] == 0x06)
            {
                found_eocd = true;
                break;
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    if (!found_eocd) {
        return ValidationResult.invalidCode(format, .missing, "End of Central Directory (corrupted or truncated)");
    }

    // For ZIP-based formats, check for required content
    if (format != .zip) {
        file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, "for content check");

        var content_buffer: [16384]u8 = undefined;
        const content_bytes = file.read(&content_buffer) catch {
            return ValidationResult.invalidCode(format, .failed_to_read, "for content check");
        };

        const has_required = switch (format) {
            .epub => format_validation.findInBuffer(&content_buffer, content_bytes, "META-INF/container.xml") or
                format_validation.findInBuffer(&content_buffer, content_bytes, "mimetype"),
            .docx => format_validation.findInBuffer(&content_buffer, content_bytes, "[Content_Types].xml") and
                format_validation.findInBuffer(&content_buffer, content_bytes, "word/"),
            .xlsx => format_validation.findInBuffer(&content_buffer, content_bytes, "[Content_Types].xml") and
                format_validation.findInBuffer(&content_buffer, content_bytes, "xl/"),
            .pptx => format_validation.findInBuffer(&content_buffer, content_bytes, "[Content_Types].xml") and
                format_validation.findInBuffer(&content_buffer, content_bytes, "ppt/"),
            else => true,
        };

        if (!has_required) {
            return switch (format) {
                .epub => ValidationResult.invalidCode(format, .missing, "EPUB container structure"),
                .docx => ValidationResult.invalidCode(format, .missing, "Word document structure"),
                .xlsx => ValidationResult.invalidCode(format, .missing, "Excel spreadsheet structure"),
                .pptx => ValidationResult.invalidCode(format, .missing, "PowerPoint structure"),
                else => ValidationResult.ok(format),
            };
        }
    }

    return ValidationResult.ok(format);
}

// ============ Gzip Validator ============

/// Gzip header flags
pub const GZIP_FTEXT: u8 = 0x01;
pub const GZIP_FHCRC: u8 = 0x02;
pub const GZIP_FEXTRA: u8 = 0x04;
pub const GZIP_FNAME: u8 = 0x08;
pub const GZIP_FCOMMENT: u8 = 0x10;

/// Validate gzip file structure (header and trailer).
pub fn validateGzip(file: std.fs.File) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.gzip, .failed_to_seek, "to start");

    // Read header (minimum 10 bytes)
    var header: [10]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.gzip, .failed_to_read, "gzip header");

    if (header_read < 10) {
        return ValidationResult.invalidCode(.gzip, .file_too_small, "gzip");
    }

    // Check magic number (1F 8B)
    if (header[0] != 0x1F or header[1] != 0x8B) {
        return ValidationResult.invalidCode(.gzip, .invalid_magic_number, "gzip");
    }

    // Check compression method (8 = deflate)
    if (header[2] != 8) {
        return ValidationResult.invalidCode(.gzip, .unsupported, "compression method (not deflate)");
    }

    const flags = header[3];

    // Skip optional fields based on flags
    var pos: u64 = 10;

    // FEXTRA: extra field
    if (flags & GZIP_FEXTRA != 0) {
        file.seekTo(pos) catch return ValidationResult.invalidCode(.gzip, .failed_to_seek, "past extra field");
        var xlen_buf: [2]u8 = undefined;
        _ = file.read(&xlen_buf) catch return ValidationResult.invalidCode(.gzip, .failed_to_read, "extra field length");
        const xlen = std.mem.readInt(u16, &xlen_buf, .little);
        pos += 2 + xlen;
    }

    // FNAME: original filename (null-terminated)
    if (flags & GZIP_FNAME != 0) {
        file.seekTo(pos) catch return ValidationResult.invalidCode(.gzip, .failed_to_seek, "to filename");
        var byte: [1]u8 = undefined;
        while (true) {
            const n = file.read(&byte) catch return ValidationResult.invalidCode(.gzip, .failed_to_read, "filename");
            if (n == 0) return ValidationResult.invalidCode(.gzip, .truncated, "filename field");
            pos += 1;
            if (byte[0] == 0) break;
            if (pos > 65536) return ValidationResult.invalid(.gzip, "Filename too long");
        }
    }

    // FCOMMENT: comment (null-terminated)
    if (flags & GZIP_FCOMMENT != 0) {
        file.seekTo(pos) catch return ValidationResult.invalidCode(.gzip, .failed_to_seek, "to comment");
        var byte: [1]u8 = undefined;
        while (true) {
            const n = file.read(&byte) catch return ValidationResult.invalidCode(.gzip, .failed_to_read, "comment");
            if (n == 0) return ValidationResult.invalidCode(.gzip, .truncated, "comment field");
            pos += 1;
            if (byte[0] == 0) break;
            if (pos > 1048576) return ValidationResult.invalid(.gzip, "Comment too long");
        }
    }

    // FHCRC: header CRC16 (we don't validate it in basic mode)
    if (flags & GZIP_FHCRC != 0) {
        pos += 2;
    }

    // Validate trailer (last 8 bytes: CRC32 + ISIZE)
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.gzip, .failed_to_get, "file size");

    if (file_size < pos + 8) {
        return ValidationResult.invalidCode(.gzip, .file_too_small, "gzip trailer");
    }

    // Seek to trailer
    file.seekTo(file_size - 8) catch return ValidationResult.invalidCode(.gzip, .failed_to_seek, "to trailer");

    var trailer: [8]u8 = undefined;
    const trailer_read = file.read(&trailer) catch return ValidationResult.invalidCode(.gzip, .failed_to_read, "gzip trailer");

    if (trailer_read != 8) {
        return ValidationResult.invalidCode(.gzip, .incomplete, "gzip trailer");
    }

    // Trailer contains CRC32 and ISIZE (uncompressed size mod 2^32)
    // We just verify the structure exists; deep validation will verify the actual values

    return ValidationResult.ok(.gzip);
}

// ============ Bzip2 Validator ============

/// Bzip2 signature: "BZh" followed by block size digit (1-9)
pub const BZIP2_SIGNATURE = [_]u8{ 0x42, 0x5A, 0x68 }; // "BZh"

/// Validate Bzip2 file structure.
pub fn validateBzip2(file: std.fs.File) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.bzip2, .failed_to_seek, "to start");

    // Read header (4 bytes minimum: BZh + block size)
    var header: [10]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.bzip2, .failed_to_read, "bzip2 header");

    if (header_read < 4) {
        return ValidationResult.invalidCode(.bzip2, .file_too_small, "bzip2");
    }

    // Check magic number "BZh"
    if (!std.mem.eql(u8, header[0..3], &BZIP2_SIGNATURE)) {
        return ValidationResult.invalidCode(.bzip2, .invalid_magic_number, "bzip2");
    }

    // Check block size (must be '1' to '9', i.e., 0x31-0x39)
    const block_size_char = header[3];
    if (block_size_char < '1' or block_size_char > '9') {
        return ValidationResult.invalidCode(.bzip2, .invalid_value, "bzip2 block size");
    }

    // For basic validation, verify file has some content after header
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.bzip2, .failed_to_get, "file size");

    // Minimum bzip2 file needs header (4 bytes) + some compressed data + trailer
    // A realistic minimum is around 14 bytes for an empty compressed stream
    if (file_size < 14) {
        return ValidationResult.invalidCode(.bzip2, .file_too_small, "valid bzip2");
    }

    return ValidationResult.ok(.bzip2);
}

// ============ XZ Validator ============

/// XZ signature: FD 37 7A 58 5A 00
pub const XZ_SIGNATURE = [_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 };

/// Validate XZ file structure.
pub fn validateXz(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.xz, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.xz, .failed_to_read, "XZ header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.xz, .file_too_small, "XZ");
    }

    // Check magic number
    if (!std.mem.eql(u8, header[0..6], &XZ_SIGNATURE)) {
        return ValidationResult.invalidCode(.xz, .invalid_magic_number, "XZ");
    }

    // Bytes 6-7 are stream flags
    // Byte 6: reserved (must be 0)
    // Byte 7: bits 0-3 = check type (0-15), bits 4-7 = reserved (must be 0)
    const reserved_byte = header[6];
    const check_byte = header[7];
    if (reserved_byte != 0 or (check_byte & 0xF0) != 0) {
        return ValidationResult.invalidCode(.xz, .invalid_value, "stream flags");
    }

    return ValidationResult.ok(.xz);
}

// ============ Zstandard Validator ============

/// Zstandard magic number: 28 B5 2F FD
pub const ZSTD_SIGNATURE = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD };

/// Validate Zstandard file structure.
pub fn validateZstd(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.zstd, .failed_to_seek, "to start");

    var header: [18]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.zstd, .failed_to_read, "Zstd header");

    if (header_read < 5) {
        return ValidationResult.invalidCode(.zstd, .file_too_small, "Zstd");
    }

    // Check magic number
    if (!std.mem.eql(u8, header[0..4], &ZSTD_SIGNATURE)) {
        return ValidationResult.invalidCode(.zstd, .invalid_magic_number, "Zstd");
    }

    // Byte 4 is frame header descriptor
    // Bits 5-7 are frame content size flag, other bits have specific meanings
    // We just verify it's a valid frame header
    const frame_header = header[4];
    _ = frame_header; // Basic structural check passed

    return ValidationResult.ok(.zstd);
}

// ============ RAR Validator ============

/// RAR5 signature: 52 61 72 21 1A 07 01 00
pub const RAR5_SIGNATURE = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };
/// RAR4 signature: 52 61 72 21 1A 07 00
pub const RAR4_SIGNATURE = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };

/// RAR4 header types
pub const RAR4_HEAD_MARK: u8 = 0x72; // Marker header
pub const RAR4_HEAD_MAIN: u8 = 0x73; // Archive header
pub const RAR4_HEAD_FILE: u8 = 0x74; // File header
pub const RAR4_HEAD_COMM: u8 = 0x75; // Comment header
pub const RAR4_HEAD_AV: u8 = 0x76; // Extra info header
pub const RAR4_HEAD_SUB: u8 = 0x77; // Subblock header
pub const RAR4_HEAD_PROTECT: u8 = 0x78; // Recovery record
pub const RAR4_HEAD_SIGN: u8 = 0x79; // Sign header
pub const RAR4_HEAD_NEWSUB: u8 = 0x7A; // Subblock header (new)
pub const RAR4_HEAD_ENDARC: u8 = 0x7B; // End of archive

/// RAR4 header flags
pub const RAR4_LONG_BLOCK: u16 = 0x8000; // Block has ADD_SIZE field

/// RAR CRC16 for RAR4 header validation (CCITT variant)
pub fn rarCrc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc = crc ^ (@as(u16, byte) << 8);
        for (0..8) |_| {
            if ((crc & 0x8000) != 0) {
                crc = (crc << 1) ^ 0x1021;
            } else {
                crc = crc << 1;
            }
        }
    }
    return crc;
}

/// Validate RAR file structure with header CRC verification.
pub fn validateRar(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "to start");

    var signature: [8]u8 = undefined;
    const sig_read = file.read(&signature) catch return ValidationResult.invalidCode(.rar, .failed_to_read, "RAR header");

    if (sig_read < 7) {
        return ValidationResult.invalidCode(.rar, .file_too_small, "RAR");
    }

    // Check RAR5 signature first (8 bytes)
    if (sig_read >= 8 and std.mem.eql(u8, signature[0..8], &RAR5_SIGNATURE)) {
        return validateRar5Headers(file);
    }

    // Check RAR4 signature (7 bytes)
    if (std.mem.eql(u8, signature[0..7], &RAR4_SIGNATURE)) {
        return validateRar4Headers(file);
    }

    return ValidationResult.invalidCode(.rar, .invalid_signature, "RAR");
}

/// Validate RAR4 archive headers with CRC16 verification
pub fn validateRar4Headers(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.rar, .failed_to_get, "file size");

    // Start after 7-byte signature
    var pos: u64 = 7;
    var headers_validated: u32 = 0;
    const max_headers: u32 = 10000; // Sanity limit

    while (pos < file_size and headers_validated < max_headers) {
        file.seekTo(pos) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "to header");

        // Read base header: CRC16 (2) + TYPE (1) + FLAGS (2) + SIZE (2) = 7 bytes
        var base_header: [7]u8 = undefined;
        const base_read = file.read(&base_header) catch return ValidationResult.invalidCode(.rar, .failed_to_read, "header");

        if (base_read < 7) {
            // Reached end of file
            break;
        }

        const stored_crc = std.mem.readInt(u16, base_header[0..2], .little);
        const head_type = base_header[2];
        const flags = std.mem.readInt(u16, base_header[3..5], .little);
        const head_size = std.mem.readInt(u16, base_header[5..7], .little);

        if (head_size < 7) {
            return ValidationResult.invalidCode(.rar, .invalid_value, "RAR4 header size");
        }

        // Read full header for CRC calculation
        if (head_size > 65535) {
            return ValidationResult.invalid(.rar, "RAR4 header too large");
        }

        file.seekTo(pos + 2) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "for CRC");

        var header_buf: [4096]u8 = undefined;
        const to_read = @min(head_size - 2, header_buf.len);
        const header_read = file.read(header_buf[0..to_read]) catch return ValidationResult.invalidCode(.rar, .failed_to_read, "header data");

        if (header_read < head_size - 2) {
            return ValidationResult.invalidCode(.rar, .incomplete, "RAR4 header");
        }

        // Calculate CRC16 of header (excluding the CRC field itself)
        const computed_crc = rarCrc16(header_buf[0..to_read]);
        if (computed_crc != stored_crc) {
            return ValidationResult.okWithDepthAndMalformation(.rar, .full, .rar_header_crc_mismatch);
        }

        headers_validated += 1;

        // Check for end of archive
        if (head_type == RAR4_HEAD_ENDARC) {
            break;
        }

        // Calculate next header position
        var block_size: u64 = head_size;

        // If LONG_BLOCK flag set, there's ADD_SIZE after the header
        if ((flags & RAR4_LONG_BLOCK) != 0 and head_type == RAR4_HEAD_FILE) {
            // ADD_SIZE is a 4-byte field at offset 7 in file header (packed size)
            // But we need to extract it from the already-read buffer
            // For file headers: after base 7 bytes, we have PACK_SIZE (4) + UNP_SIZE (4) + ...
            // Actually, pack_size is at offset 7-9 in the header (relative to start)
            if (head_size >= 11) {
                // PACK_SIZE is at bytes 7-10 (4 bytes after FLAGS and SIZE)
                // Since we read from pos+2, the pack_size is at offset 5 in header_buf
                const pack_size = std.mem.readInt(u32, header_buf[5..9], .little);
                block_size += pack_size;
            }
        }

        pos += block_size;
    }

    if (headers_validated == 0) {
        return ValidationResult.invalidCode(.rar, .no_valid_x_found, "RAR4 headers");
    }

    // Note: Only header CRCs are verified, NOT file content CRCs
    // Full validation would require decompressing and verifying each file's CRC32
    return ValidationResult.okWithDepthAndWarning(.rar, .structural, "header CRCs verified, file content CRCs not checked");
}

/// Read RAR5 variable-length integer
pub fn readRar5Vint(file: std.fs.File) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| { // Max 10 bytes for 64-bit vint
        var byte_buf: [1]u8 = undefined;
        const read = try file.read(&byte_buf);
        if (read == 0) return error.EndOfFile;
        const byte = byte_buf[0];
        result |= @as(u64, byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) return result;
        shift += 7;
    }
    return error.InvalidVint;
}

/// Validate RAR5 archive headers with CRC32 verification
pub fn validateRar5Headers(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.rar, .failed_to_get, "file size");

    // Start after 8-byte signature
    var pos: u64 = 8;
    var headers_validated: u32 = 0;
    const max_headers: u32 = 10000;

    while (pos < file_size and headers_validated < max_headers) {
        file.seekTo(pos) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "to header");

        // Read header CRC32 (4 bytes)
        var crc_buf: [4]u8 = undefined;
        const crc_read = file.read(&crc_buf) catch return ValidationResult.invalidCode(.rar, .failed_to_read, "header CRC");

        if (crc_read < 4) {
            break; // End of file
        }

        const stored_crc = std.mem.readInt(u32, &crc_buf, .little);

        // Read header size (vint)
        const header_size = readRar5Vint(file) catch {
            return ValidationResult.invalidCode(.rar, .invalid_value, "RAR5 header size");
        };

        if (header_size > 2 * 1024 * 1024) { // 2MB sanity limit
            return ValidationResult.invalid(.rar, "RAR5 header too large");
        }

        // Remember position after size vint
        const header_data_pos = file.getPos() catch return ValidationResult.invalidCode(.rar, .failed_to_get, "position");

        // Read header data for CRC calculation (size vint + rest of header)
        // We need to include the size vint in CRC calculation
        const vint_size = header_data_pos - pos - 4;
        const total_header_data = vint_size + header_size;

        if (total_header_data > 65536) {
            return ValidationResult.invalid(.rar, "RAR5 header data too large");
        }

        file.seekTo(pos + 4) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "for CRC calc");

        var header_buf: [65536]u8 = undefined;
        const to_read: usize = @intCast(total_header_data);
        const header_read = file.read(header_buf[0..to_read]) catch return ValidationResult.invalidCode(.rar, .failed_to_read, "header");

        if (header_read < to_read) {
            return ValidationResult.invalidCode(.rar, .incomplete, "RAR5 header");
        }

        // Calculate CRC32
        const computed_crc = std.hash.Crc32.hash(header_buf[0..to_read]);
        if (computed_crc != stored_crc) {
            return ValidationResult.okWithDepthAndMalformation(.rar, .full, .rar_header_crc_mismatch);
        }

        headers_validated += 1;

        // Parse header type and flags to determine next position
        file.seekTo(header_data_pos) catch return ValidationResult.invalidCode(.rar, .failed_to_seek, "to header type");
        const header_type = readRar5Vint(file) catch {
            return ValidationResult.invalidCode(.rar, .invalid_value, "RAR5 header type");
        };

        // Header type 5 = End of archive
        if (header_type == 5) {
            break;
        }

        const header_flags = readRar5Vint(file) catch {
            return ValidationResult.invalidCode(.rar, .invalid_value, "RAR5 header flags");
        };

        // Check if data area follows header (bit 1 of flags)
        var data_size: u64 = 0;
        if ((header_flags & 0x02) != 0) {
            // Skip extra area size if present (bit 0)
            if ((header_flags & 0x01) != 0) {
                _ = readRar5Vint(file) catch {
                    return ValidationResult.invalidCode(.rar, .invalid_value, "RAR5 extra area size");
                };
            }
            // Read data size
            data_size = readRar5Vint(file) catch {
                return ValidationResult.invalidCode(.rar, .invalid_value, "RAR5 data size");
            };
        }

        // Move to next header (skip header + data area)
        pos = header_data_pos + header_size + data_size;
    }

    if (headers_validated == 0) {
        return ValidationResult.invalidCode(.rar, .no_valid_x_found, "RAR5 headers");
    }

    // Note: Only header CRCs are verified, NOT file content CRCs
    // Full validation would require decompressing and verifying each file's CRC32
    return ValidationResult.okWithDepthAndWarning(.rar, .structural, "header CRCs verified, file content CRCs not checked");
}

// ============ 7-Zip Validator ============

/// 7-Zip signature
pub const SEVENZ_SIGNATURE = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };

/// Validate 7-Zip file structure.
pub fn validate7z(file: std.fs.File) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.sevenz, .failed_to_seek, "to start");

    // 7z header: 32 bytes
    // - 6 bytes: signature (37 7A BC AF 27 1C)
    // - 2 bytes: format version (major, minor)
    // - 4 bytes: start header CRC
    // - 8 bytes: next header offset
    // - 8 bytes: next header size
    // - 4 bytes: next header CRC

    var header: [32]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.sevenz, .failed_to_read, "7z header");

    if (header_read < 32) {
        return ValidationResult.invalidCode(.sevenz, .file_too_small, "7z header");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..6], &SEVENZ_SIGNATURE)) {
        return ValidationResult.invalidCode(.sevenz, .invalid_signature, "7z");
    }

    // Check version (we support 0.x where x <= 4)
    const major_version = header[6];
    const minor_version = header[7];
    if (major_version != 0 or minor_version > 4) {
        return ValidationResult.invalidCode(.sevenz, .unsupported, "7z version");
    }

    // Read next header offset and size
    const next_header_offset = std.mem.readInt(u64, header[12..20], .little);
    const next_header_size = std.mem.readInt(u64, header[20..28], .little);

    // Validate that the file is large enough for the next header
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.sevenz, .failed_to_get, "file size");

    // Next header starts after the 32-byte start header
    const expected_min_size = 32 + next_header_offset + next_header_size;
    if (file_size < expected_min_size) {
        return ValidationResult.invalid(.sevenz, "File truncated (next header beyond EOF)");
    }

    return ValidationResult.ok(.sevenz);
}

// ============ Tar Validator ============

/// Validate tar file structure.
pub fn validateTar(file: std.fs.File) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.tar, .failed_to_seek, "to start");

    // Tar files consist of 512-byte blocks
    // Each file entry has a header block followed by data blocks
    // The header has "ustar" magic at offset 257 (POSIX/GNU tar)
    // Or the file can be old-style V7 tar with no magic

    var header: [512]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.tar, .failed_to_read, "tar header");

    if (header_read < 512) {
        return ValidationResult.invalidCode(.tar, .file_too_small, "tar header");
    }

    // Check for POSIX ustar magic at offset 257
    const ustar_magic = "ustar";
    const is_posix = std.mem.eql(u8, header[257..262], ustar_magic);

    // Check for GNU tar magic "ustar " with trailing space
    const is_gnu = std.mem.eql(u8, header[257..263], "ustar ");

    // For V7 tar, check if the first 100 bytes look like a valid filename
    // (printable ASCII or null-padding)
    var is_v7 = true;
    for (header[0..100]) |c| {
        if (c != 0 and (c < 0x20 or c > 0x7E)) {
            is_v7 = false;
            break;
        }
    }

    if (!is_posix and !is_gnu and !is_v7) {
        return ValidationResult.invalidCode(.tar, .invalid_value, "tar format (no ustar magic and not V7)");
    }

    // Validate checksum (bytes 148-155, octal)
    // The checksum is the sum of all header bytes, with checksum field treated as spaces
    var checksum: u32 = 0;
    for (header, 0..) |byte, i| {
        if (i >= 148 and i < 156) {
            checksum += ' '; // Treat checksum field as spaces
        } else {
            checksum += byte;
        }
    }

    // Parse stored checksum (octal string, null or space terminated)
    const checksum_field = header[148..156];
    var stored_checksum: u32 = 0;
    for (checksum_field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') {
            // All zeros is valid for empty archive
            if (checksum == 256 * 8) { // All spaces in checksum field
                return ValidationResult.ok(.tar);
            }
            return ValidationResult.invalidCode(.tar, .invalid_value, "checksum format");
        }
        stored_checksum = stored_checksum * 8 + (c - '0');
    }

    // Handle empty archive (all zeros)
    var all_zero = true;
    for (header) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        return ValidationResult.ok(.tar); // Empty tar archive
    }

    if (checksum != stored_checksum) {
        return ValidationResult.invalidCodeMsg(.tar, .checksum_mismatch, "Header", "Header checksum mismatch");
    }

    return ValidationResult.ok(.tar);
}

// ============ PAR2 Validator ============

/// Validate PAR2 parity archive structure.
/// PAR2 files contain packets with 64-byte headers followed by packet data.
/// Each packet header includes: magic (8 bytes), length (8 bytes), MD5 (16 bytes),
/// recovery set ID (16 bytes), and packet type (16 bytes).
pub fn validatePar2(file: std.fs.File) ValidationResult {
    // Reset to start
    file.seekTo(0) catch return ValidationResult.invalidCode(.par2, .failed_to_seek, "to start");

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.par2, .failed_to_get, "file size");
    };

    // Minimum PAR2 file is at least one packet header (64 bytes)
    if (file_size < 64) {
        return ValidationResult.invalidCode(.par2, .file_too_small, "PAR2 packet");
    }

    // PAR2 packet header is 64 bytes:
    // 0-7:   Magic "PAR2\x00PKT"
    // 8-15:  Packet length (little-endian, includes the 64-byte header)
    // 16-31: MD5 hash of packet body (from offset 32 to end of packet)
    // 32-47: Recovery Set ID (identifies which files belong together)
    // 48-63: Packet type (e.g., "PAR 2.0\x00Main\x00\x00\x00\x00")

    const par2_magic = "PAR2\x00PKT";
    var packets_validated: u32 = 0;
    var offset: u64 = 0;

    // Validate up to 100 packets or until EOF
    while (packets_validated < 100 and offset + 64 <= file_size) {
        file.seekTo(offset) catch {
            return ValidationResult.invalidCode(.par2, .failed_to_seek, "to packet");
        };

        var header: [64]u8 = undefined;
        const bytes_read = file.read(&header) catch {
            return ValidationResult.invalidCode(.par2, .failed_to_read, "packet header");
        };

        if (bytes_read < 64) {
            // Partial read at end - might be truncated
            if (packets_validated > 0) {
                return ValidationResult.invalidCode(.par2, .truncated, "packet header");
            }
            return ValidationResult.invalidCode(.par2, .file_too_small, "packet header");
        }

        // Check magic
        if (!std.mem.eql(u8, header[0..8], par2_magic)) {
            if (packets_validated == 0) {
                return ValidationResult.invalidCode(.par2, .invalid_value, "PAR2 magic");
            }
            // Might be padding or end of file
            break;
        }

        // Read packet length (little-endian u64)
        const packet_len = std.mem.readInt(u64, header[8..16], .little);

        // Sanity check: packet length must be at least 64 (header size)
        if (packet_len < 64) {
            return ValidationResult.invalidCode(.par2, .invalid_value, "packet length (too small)");
        }

        // Sanity check: packet length shouldn't exceed remaining file size
        if (offset + packet_len > file_size) {
            return ValidationResult.invalidCodeMsg(.par2, .exceeds_bounds, "Packet length", "Packet length exceeds file size");
        }

        // Verify packet MD5 digest (stored in bytes 16..31).
        // Digest is computed over packet bytes from offset 32 to packet end.
        var md5 = std.crypto.hash.Md5.init(.{});
        var remaining = packet_len - 32;
        var body_buf: [4096]u8 = undefined;

        file.seekTo(offset + 32) catch {
            return ValidationResult.invalidCode(.par2, .failed_to_seek, "to packet body");
        };

        while (remaining > 0) {
            const chunk_len_u64 = @min(remaining, @as(u64, body_buf.len));
            const chunk_len: usize = @intCast(chunk_len_u64);
            const got = file.readAll(body_buf[0..chunk_len]) catch {
                return ValidationResult.invalidCode(.par2, .failed_to_read, "packet body");
            };
            if (got != chunk_len) {
                return ValidationResult.invalidCode(.par2, .truncated, "packet body");
            }
            md5.update(body_buf[0..got]);
            remaining -= chunk_len_u64;
        }

        var digest: [16]u8 = undefined;
        md5.final(&digest);
        if (!std.mem.eql(u8, &digest, header[16..32])) {
            return ValidationResult.invalidCodeMsg(.par2, .checksum_mismatch, "Packet MD5", "Packet MD5 digest mismatch");
        }

        // Move to next packet
        offset += packet_len;
        packets_validated += 1;
    }

    if (packets_validated == 0) {
        return ValidationResult.invalidCode(.par2, .no_valid_x_found, "PAR2 packets");
    }

    // Successfully validated packet structure and packet digests
    return ValidationResult.okWithDepth(.par2, .full);
}

// ============ WARC Validator ============

/// Validate WARC (Web ARChive) file structure.
/// Full integrity validation: parses multiple records, validates headers,
/// and verifies Content-Length consistency.
pub fn validateWarc(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch return ValidationResult.invalidCode(.warc, .failed_to_stat, "file");
    const file_size = stat.size;

    if (file_size < 20) {
        return ValidationResult.invalidCode(.warc, .file_too_small, "WARC");
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.warc, .failed_to_seek, "to start");

    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    var record_count: u32 = 0;

    while (offset < file_size) {
        file.seekTo(offset) catch return ValidationResult.invalidCode(.warc, .failed_to_seek, "to record");

        const to_read = @min(buffer.len, @as(usize, @intCast(file_size - offset)));
        const bytes_read = file.read(buffer[0..to_read]) catch {
            return ValidationResult.invalidCode(.warc, .failed_to_read, "record");
        };

        if (bytes_read < 10) break;

        const data = buffer[0..bytes_read];

        // Check WARC version
        if (!std.mem.startsWith(u8, data, "WARC/1.0") and
            !std.mem.startsWith(u8, data, "WARC/1.1"))
        {
            if (record_count == 0) {
                return ValidationResult.invalidCode(.warc, .invalid_value, "WARC version");
            } else {
                return ValidationResult.invalidCode(.warc, .invalid_value, "WARC record version");
            }
        }

        // Parse headers
        var found_type = false;
        var found_record_id = false;
        var found_date = false;
        var content_length: ?u64 = null;
        var header_end: usize = 0;

        var i: usize = 0;
        while (i < data.len) {
            const line_start = i;
            while (i < data.len and data[i] != '\n') : (i += 1) {}

            var line_end = i;
            if (line_end > line_start and data[line_end - 1] == '\r') {
                line_end -= 1;
            }

            const line = data[line_start..line_end];

            // Check for empty line (end of headers)
            if (line.len == 0) {
                header_end = i + 1;
                break;
            }

            // Parse header fields
            if (std.mem.startsWith(u8, line, "WARC-Type:")) {
                found_type = true;
            } else if (std.mem.startsWith(u8, line, "WARC-Record-ID:")) {
                found_record_id = true;
            } else if (std.mem.startsWith(u8, line, "WARC-Date:")) {
                found_date = true;
            } else if (std.mem.startsWith(u8, line, "Content-Length:")) {
                // Parse content length
                var val_start: usize = 15;
                while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
                if (val_start < line.len) {
                    content_length = std.fmt.parseInt(u64, line[val_start..], 10) catch null;
                }
            }

            i += 1; // Skip newline
        }

        if (!found_type) {
            return ValidationResult.invalidCode(.warc, .missing, "WARC-Type header");
        }

        if (!found_record_id) {
            return ValidationResult.invalidCode(.warc, .missing, "WARC-Record-ID header");
        }

        if (!found_date) {
            return ValidationResult.invalidCode(.warc, .missing, "WARC-Date header");
        }

        if (content_length == null) {
            return ValidationResult.invalidCode(.warc, .missing, "Content-Length header");
        }

        // Calculate next record offset
        // Record = headers + \r\n + body + \r\n\r\n
        const body_start = offset + header_end;
        const body_end = body_start + content_length.?;
        const next_record = body_end + 4; // \r\n\r\n separator

        if (body_end > file_size) {
            return ValidationResult.invalidCodeMsg(.warc, .exceeds_bounds, "Content-Length", "Content-Length exceeds file bounds");
        }

        record_count += 1;
        offset = next_record;

        if (record_count > 10_000_000) {
            return ValidationResult.invalidCode(.warc, .too_many, "records");
        }

        // Stop if we've validated enough records (sampling for large files)
        if (record_count >= 100 and offset > file_size / 2) {
            break;
        }
    }

    if (record_count == 0) {
        return ValidationResult.invalid(.warc, "No WARC records found");
    }

    return ValidationResult.okWithDepth(.warc, .full);
}

// ============ ZIP Deep Validation (CRC-32) ============

/// ZIP compression methods
pub const ZipCompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
    _,
};

const ZIP_TELEMETRY_DEFAULT_SLOW_SECONDS: f64 = 2.0;
const ZIP_TELEMETRY_MAX_NAME: usize = 256;

pub const ZipTelemetry = struct {
    enabled: bool,
    slow_threshold_ns: i128,

    pub fn init() ZipTelemetry {
        const env = format_validation.getenvCrossPlatform("ZIP_TELEMETRY") orelse {
            return .{ .enabled = false, .slow_threshold_ns = 0 };
        };
        if (!isTruthy(env)) {
            return .{ .enabled = false, .slow_threshold_ns = 0 };
        }
        var threshold_seconds = ZIP_TELEMETRY_DEFAULT_SLOW_SECONDS;
        if (format_validation.getenvCrossPlatform("ZIP_SLOW_SECONDS")) |threshold_slice| {
            threshold_seconds = std.fmt.parseFloat(f64, threshold_slice) catch threshold_seconds;
        }
        const threshold_ns = @as(i128, @intFromFloat(threshold_seconds * 1_000_000_000.0));
        return .{ .enabled = true, .slow_threshold_ns = threshold_ns };
    }
};

pub const ZipEntryTelemetry = struct {
    enabled: bool,
    start_ns: i128,
    entry_index: usize,
    name: []const u8 = "",
    name_truncated: bool = false,
    compression_method: u16 = 0,
    compressed_size: u32 = 0,
    uncompressed_size: u32 = 0,
    flags: u16 = 0,
    encrypted: bool = false,
    has_descriptor: bool = false,
    descriptor_reads: u64 = 0,

    pub fn init(telemetry: ZipTelemetry, entry_index: usize) ZipEntryTelemetry {
        return .{
            .enabled = telemetry.enabled,
            .start_ns = if (telemetry.enabled) std.time.nanoTimestamp() else 0,
            .entry_index = entry_index,
        };
    }

    pub fn setName(self: *ZipEntryTelemetry, name: []const u8, truncated: bool) void {
        self.name = name;
        self.name_truncated = truncated;
    }

    pub fn finish(self: *ZipEntryTelemetry, telemetry: ZipTelemetry, format: FileFormat) void {
        if (!self.enabled) return;
        const elapsed_ns = std.time.nanoTimestamp() - self.start_ns;
        if (elapsed_ns < telemetry.slow_threshold_ns) {
            return;
        }
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const name_suffix = if (self.name_truncated) "..." else "";
        std.debug.print(
            "ZIP_SLOW format={s} entry={d} name=\"{s}{s}\" method={d} comp={d} uncomp={d} flags=0x{x} encrypted={d} descriptor={d} descriptor_reads={d} elapsed={d:.2}s\n",
            .{
                format.description(),
                self.entry_index,
                self.name,
                name_suffix,
                self.compression_method,
                self.compressed_size,
                self.uncompressed_size,
                self.flags,
                @intFromBool(self.encrypted),
                @intFromBool(self.has_descriptor),
                self.descriptor_reads,
                elapsed_seconds,
            },
        );
    }
};

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on");
}

fn readLe(comptime T: type, slice: []const u8) T {
    const ptr: *const [@sizeOf(T)]u8 = @ptrCast(slice.ptr);
    return std.mem.readInt(T, ptr, .little);
}

pub const ZipCentralDirectoryInfo = struct {
    offset: u64,
    size: u64,
    entries: u64,
};

pub const ZipCentralEntry = struct {
    local_header_offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    crc32: u32,
    flags: u16,
    compression_method: u16,
};

pub const Zip64Sizes = struct {
    compressed_size: u64,
    uncompressed_size: u64,
    local_header_offset: u64,
};

pub fn findZipCentralDirectory(allocator: Allocator, file: std.fs.File, file_size: u64) ?ZipCentralDirectoryInfo {
    if (file_size < 22) {
        return null;
    }
    const max_comment: usize = 0xFFFF;
    const search_len = @min(@as(u64, max_comment + 22), file_size);
    const read_len: usize = @intCast(search_len);
    const start_pos = file_size - search_len;

    const buf = allocator.alloc(u8, read_len) catch return null;
    defer allocator.free(buf);

    file.seekTo(start_pos) catch return null;
    const bytes_read = file.readAll(buf) catch return null;
    if (bytes_read < 22) {
        return null;
    }

    const eocd_sig = "PK\x05\x06";
    const idx = std.mem.lastIndexOf(u8, buf[0..bytes_read], eocd_sig) orelse return null;
    if (idx + 22 > bytes_read) {
        return null;
    }

    const total_entries = readLe(u16, buf[idx + 10 .. idx + 12]);
    const central_dir_size = readLe(u32, buf[idx + 12 .. idx + 16]);
    const central_dir_offset = readLe(u32, buf[idx + 16 .. idx + 20]);

    const needs_zip64 = total_entries == 0xFFFF or central_dir_size == 0xFFFFFFFF or central_dir_offset == 0xFFFFFFFF;
    if (!needs_zip64) {
        return .{
            .offset = central_dir_offset,
            .size = central_dir_size,
            .entries = total_entries,
        };
    }

    if (idx < 20) {
        return null;
    }
    const locator_pos = start_pos + @as(u64, @intCast(idx - 20));
    var locator: [20]u8 = undefined;
    file.seekTo(locator_pos) catch return null;
    const locator_read = file.readAll(&locator) catch return null;
    if (locator_read != locator.len) {
        return null;
    }
    if (!std.mem.eql(u8, locator[0..4], "PK\x06\x07")) {
        return null;
    }
    const zip64_eocd_offset = readLe(u64, locator[8..16]);
    if (zip64_eocd_offset + 56 > file_size) {
        return null;
    }

    var zip64_eocd: [56]u8 = undefined;
    file.seekTo(zip64_eocd_offset) catch return null;
    const zip64_read = file.readAll(&zip64_eocd) catch return null;
    if (zip64_read != zip64_eocd.len) {
        return null;
    }
    if (!std.mem.eql(u8, zip64_eocd[0..4], "PK\x06\x06")) {
        return null;
    }

    const zip64_entries = readLe(u64, zip64_eocd[32..40]);
    const zip64_size = readLe(u64, zip64_eocd[40..48]);
    const zip64_offset = readLe(u64, zip64_eocd[48..56]);
    return .{
        .offset = zip64_offset,
        .size = zip64_size,
        .entries = zip64_entries,
    };
}

pub fn readZip64Extra(
    extra: []const u8,
    compressed_size: u64,
    uncompressed_size: u64,
    local_header_offset: u64,
) ?Zip64Sizes {
    var offset: usize = 0;
    var updated = false;
    var new_compressed = compressed_size;
    var new_uncompressed = uncompressed_size;
    var new_local_offset = local_header_offset;

    while (offset + 4 <= extra.len) {
        const header_id = readLe(u16, extra[offset .. offset + 2]);
        const data_size = readLe(u16, extra[offset + 2 .. offset + 4]);
        offset += 4;
        if (offset + data_size > extra.len) {
            break;
        }
        if (header_id == 0x0001) {
            var cursor: usize = 0;
            if (uncompressed_size == 0xFFFFFFFF and cursor + 8 <= data_size) {
                new_uncompressed = readLe(u64, extra[offset + cursor .. offset + cursor + 8]);
                cursor += 8;
                updated = true;
            }
            if (compressed_size == 0xFFFFFFFF and cursor + 8 <= data_size) {
                new_compressed = readLe(u64, extra[offset + cursor .. offset + cursor + 8]);
                cursor += 8;
                updated = true;
            }
            if (local_header_offset == 0xFFFFFFFF and cursor + 8 <= data_size) {
                new_local_offset = readLe(u64, extra[offset + cursor .. offset + cursor + 8]);
                updated = true;
            }
            break;
        }
        offset += data_size;
    }

    if (!updated) {
        return null;
    }
    return .{
        .local_header_offset = new_local_offset,
        .compressed_size = new_compressed,
        .uncompressed_size = new_uncompressed,
    };
}

pub fn validateZipDeepWithCentralDirectory(
    allocator: Allocator,
    file: std.fs.File,
    format: FileFormat,
    telemetry: ZipTelemetry,
) ?ValidationResult {
    const file_size = file.getEndPos() catch return null;
    const central = findZipCentralDirectory(allocator, file, file_size) orelse return null;
    if (central.entries == 0) {
        return ValidationResult.invalidWithDepth(format, "No entries found", .full);
    }
    if (central.offset + central.size > file_size) {
        return ValidationResult.invalidWithDepth(format, "Central directory extends beyond file", .full);
    }

    var entry_count: u64 = 0;
    var encrypted_entry_count: u64 = 0;
    var cdir_pos = central.offset;
    const max_entries: u64 = 100000;

    while (entry_count < central.entries and entry_count < max_entries) : (entry_count += 1) {
        file.seekTo(cdir_pos) catch return ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "to central directory", .full);

        var header: [46]u8 = undefined;
        const header_read = file.readAll(&header) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "central directory header", .full);
        };
        if (header_read != header.len) {
            return ValidationResult.invalidCodeWithDepth(format, .truncated, "central directory header", .full);
        }
        if (!std.mem.eql(u8, header[0..4], "PK\x01\x02")) {
            return ValidationResult.invalidCodeWithDepth(format, .invalid_signature, "central directory", .full);
        }

        const flags = readLe(u16, header[8..10]);
        const compression_method = readLe(u16, header[10..12]);
        const stored_crc = readLe(u32, header[16..20]);
        const compressed_size = readLe(u32, header[20..24]);
        const uncompressed_size = readLe(u32, header[24..28]);
        const filename_len = readLe(u16, header[28..30]);
        const extra_len = readLe(u16, header[30..32]);
        const comment_len = readLe(u16, header[32..34]);
        const local_header_offset = readLe(u32, header[42..46]);

        const name_len_usize: usize = @intCast(filename_len);
        const extra_len_usize: usize = @intCast(extra_len);
        const comment_len_usize: usize = @intCast(comment_len);

        var name_buf: [ZIP_TELEMETRY_MAX_NAME]u8 = undefined;
        var name_slice: []const u8 = "";
        var name_truncated = false;
        const to_read = @min(name_len_usize, name_buf.len);
        if (to_read > 0) {
            const name_read = file.readAll(name_buf[0..to_read]) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "central directory filename", .full);
            };
            if (name_read != to_read) {
                return ValidationResult.invalidCodeWithDepth(format, .truncated, "central directory filename", .full);
            }
            name_slice = name_buf[0..to_read];
            if (name_len_usize > to_read) {
                name_truncated = true;
                const remaining: i64 = @intCast(name_len_usize - to_read);
                file.seekBy(remaining) catch {
                    return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "central directory filename", .full);
                };
            }
        } else if (name_len_usize > 0) {
            const remaining: i64 = @intCast(name_len_usize);
            file.seekBy(remaining) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "central directory filename", .full);
            };
        }

        var extra_buf: []u8 = &[_]u8{};
        if (extra_len_usize > 0) {
            extra_buf = allocator.alloc(u8, extra_len_usize) catch {
                return ValidationResult.invalidCodeWithDepth(format, .out_of_memory, "reading central directory extra", .full);
            };
            defer allocator.free(extra_buf);
            const extra_read = file.readAll(extra_buf) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "central directory extra", .full);
            };
            if (extra_read != extra_len_usize) {
                return ValidationResult.invalidCodeWithDepth(format, .truncated, "central directory extra", .full);
            }
        }

        if (comment_len_usize > 0) {
            const skip_comment: i64 = @intCast(comment_len_usize);
            file.seekBy(skip_comment) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "central directory comment", .full);
            };
        }

        var entry = ZipCentralEntry{
            .local_header_offset = local_header_offset,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .crc32 = stored_crc,
            .flags = flags,
            .compression_method = compression_method,
        };

        if (entry.local_header_offset == 0xFFFFFFFF or entry.compressed_size == 0xFFFFFFFF or entry.uncompressed_size == 0xFFFFFFFF) {
            if (readZip64Extra(extra_buf, entry.compressed_size, entry.uncompressed_size, entry.local_header_offset)) |zip64| {
                entry.local_header_offset = zip64.local_header_offset;
                entry.compressed_size = zip64.compressed_size;
                entry.uncompressed_size = zip64.uncompressed_size;
            }
        }

        const next_cdir_pos = cdir_pos + 46 + name_len_usize + extra_len_usize + comment_len_usize;

        var entry_telemetry = ZipEntryTelemetry.init(telemetry, @intCast(entry_count + 1));
        entry_telemetry.setName(name_slice, name_truncated);
        entry_telemetry.compression_method = entry.compression_method;
        entry_telemetry.compressed_size = @intCast(@min(entry.compressed_size, @as(u64, std.math.maxInt(u32))));
        entry_telemetry.uncompressed_size = @intCast(@min(entry.uncompressed_size, @as(u64, std.math.maxInt(u32))));
        entry_telemetry.flags = entry.flags;
        entry_telemetry.encrypted = (entry.flags & 0x0001) != 0;
        entry_telemetry.has_descriptor = (entry.flags & 0x0008) != 0;
        defer entry_telemetry.finish(telemetry, format);

        file.seekTo(entry.local_header_offset) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "to local file header", .full);
        };

        var local_sig: [4]u8 = undefined;
        const sig_read = file.readAll(&local_sig) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "local file header signature", .full);
        };
        if (sig_read != local_sig.len or !std.mem.eql(u8, local_sig[0..], "PK\x03\x04")) {
            return ValidationResult.invalidCodeWithDepth(format, .invalid_signature, "local file header", .full);
        }

        var local_header: [26]u8 = undefined;
        const local_header_read = file.readAll(&local_header) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "local file header", .full);
        };
        if (local_header_read != local_header.len) {
            return ValidationResult.invalidCodeWithDepth(format, .truncated, "local file header", .full);
        }

        const local_filename_len = readLe(u16, local_header[22..24]);
        const local_extra_len = readLe(u16, local_header[24..26]);

        const skip_local_name: i64 = @intCast(local_filename_len);
        file.seekBy(skip_local_name) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "local filename", .full);
        };
        const skip_local_extra: i64 = @intCast(local_extra_len);
        file.seekBy(skip_local_extra) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "local extra", .full);
        };

        if (entry_telemetry.encrypted) {
            encrypted_entry_count += 1;
            cdir_pos = next_cdir_pos;
            continue;
        }

        if (entry.compressed_size == 0 and entry.uncompressed_size == 0) {
            cdir_pos = next_cdir_pos;
            continue;
        }

        if (entry.crc32 == 0) {
            cdir_pos = next_cdir_pos;
            continue;
        }

        if (entry.uncompressed_size > format_validation.MAX_ZIP_ENTRY_SIZE) {
            cdir_pos = next_cdir_pos;
            continue;
        }

        if (entry.compressed_size > @as(u64, std.math.maxInt(u32)) or entry.uncompressed_size > @as(u64, std.math.maxInt(u32))) {
            cdir_pos = next_cdir_pos;
            continue;
        }

        const compressed_u32: u32 = @intCast(entry.compressed_size);
        const uncompressed_u32: u32 = @intCast(entry.uncompressed_size);

        switch (@as(ZipCompressionMethod, @enumFromInt(entry.compression_method))) {
            .store => {
                const result = validateZipStoredEntry(file, entry.crc32, compressed_u32);
                if (!result.is_valid) {
                    return ValidationResult.invalidWithDepth(format, result.error_message orelse "CRC mismatch", .full);
                }
            },
            .deflate => {
                const result = validateZipDeflatedEntry(allocator, file, entry.crc32, compressed_u32, uncompressed_u32);
                if (!result.is_valid) {
                    return ValidationResult.invalidWithDepth(format, result.error_message orelse "Deflate CRC mismatch", .full);
                }
            },
            _ => {
                // Unknown compression method - skip
            },
        }

        cdir_pos = next_cdir_pos;
    }

    if (entry_count == 0) {
        return ValidationResult.invalidWithDepth(format, "No entries found", .full);
    }

    if (encrypted_entry_count > 0 and encrypted_entry_count == entry_count) {
        return ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = .structural,
            .has_encrypted_content = true,
        };
    }
    if (encrypted_entry_count > 0) {
        return ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = .full,
            .has_encrypted_content = true,
        };
    }

    return ValidationResult.okWithDepth(format, .full);
}

/// Deep ZIP validation by verifying CRC-32 checksums for all entries.
/// ZIP stores a CRC-32 for each file entry, computed over the uncompressed data.
/// For stored files, we CRC the data directly. For deflated files, we decompress first.
pub fn validateZipDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.zip, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.zip, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(.zip, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    const format = format_validation.detectZipSubformat(file);
    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "to start", .full);
    };

    const telemetry = ZipTelemetry.init();
    if (validateZipDeepWithCentralDirectory(allocator, file, format, telemetry)) |result| {
        return result;
    }

    var entry_count: usize = 0;
    var encrypted_entry_count: usize = 0;
    const max_entries: usize = 100000;
    const max_uncompressed_size: u64 = 512 * 1024 * 1024; // 512 MiB max per entry

    while (true) : (entry_count += 1) {
        if (entry_count > max_entries) {
            return ValidationResult.invalidCodeWithDepth(format, .too_many, "ZIP entries", .full);
        }

        // Read local file header signature
        var sig: [4]u8 = undefined;
        const sig_bytes = file.read(&sig) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "entry signature", .full);
        };
        if (sig_bytes == 0) break;
        if (sig_bytes < 4) {
            return ValidationResult.invalidCodeWithDepth(format, .truncated, "entry signature", .full);
        }

        // Check for end of entries (central directory starts)
        if (sig[0] == 'P' and sig[1] == 'K' and sig[2] == 1 and sig[3] == 2) {
            // Central directory header - we're done with file entries
            break;
        }
        if (sig[0] == 'P' and sig[1] == 'K' and sig[2] == 5 and sig[3] == 6) {
            // End of central directory - we're done
            break;
        }

        // Verify local file header signature
        if (sig[0] != 'P' or sig[1] != 'K' or sig[2] != 3 or sig[3] != 4) {
            return ValidationResult.invalidCodeWithDepth(format, .invalid_signature, "local file header", .full);
        }

        var entry_telemetry = ZipEntryTelemetry.init(telemetry, entry_count + 1);
        defer entry_telemetry.finish(telemetry, format);

        // Read rest of local file header (26 bytes after signature)
        var header: [26]u8 = undefined;
        const header_bytes = file.read(&header) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "local file header", .full);
        };
        if (header_bytes < 26) {
            return ValidationResult.invalidCodeWithDepth(format, .truncated, "local file header", .full);
        }

        // Parse header fields (little endian)
        const general_purpose_flags = std.mem.readInt(u16, header[2..4], .little);
        const compression_method = std.mem.readInt(u16, header[4..6], .little);
        const stored_crc = std.mem.readInt(u32, header[10..14], .little);
        const compressed_size = std.mem.readInt(u32, header[14..18], .little);
        const uncompressed_size = std.mem.readInt(u32, header[18..22], .little);
        const filename_len = std.mem.readInt(u16, header[22..24], .little);
        const extra_len = std.mem.readInt(u16, header[24..26], .little);

        // Check for encryption (bit 0 of general purpose flags)
        const is_encrypted = (general_purpose_flags & 0x0001) != 0;
        // Check for data descriptor (bit 3 of general purpose flags)
        // When set, CRC and sizes are in a data descriptor AFTER the compressed data
        const has_data_descriptor = (general_purpose_flags & 0x0008) != 0;

        entry_telemetry.compression_method = compression_method;
        entry_telemetry.compressed_size = compressed_size;
        entry_telemetry.uncompressed_size = uncompressed_size;
        entry_telemetry.flags = general_purpose_flags;
        entry_telemetry.encrypted = is_encrypted;
        entry_telemetry.has_descriptor = has_data_descriptor;

        const filename_len_usize = @as(usize, filename_len);
        if (telemetry.enabled) {
            var name_buf: [ZIP_TELEMETRY_MAX_NAME]u8 = undefined;
            const to_read = @min(filename_len_usize, name_buf.len);
            var truncated = false;
            if (to_read > 0) {
                const name_read = file.readAll(name_buf[0..to_read]) catch {
                    return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "entry filename", .full);
                };
                if (name_read != to_read) {
                    return ValidationResult.invalidCodeWithDepth(format, .truncated, "entry filename", .full);
                }
                entry_telemetry.setName(name_buf[0..to_read], false);
            }
            if (filename_len_usize > to_read) {
                truncated = true;
                const remaining: i64 = @intCast(filename_len_usize - to_read);
                file.seekBy(remaining) catch {
                    return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "entry filename", .full);
                };
            }
            if (to_read == 0) {
                entry_telemetry.setName("", false);
            } else if (truncated) {
                entry_telemetry.name_truncated = true;
            }
        } else {
            // Skip filename
            const filename_len_i64: i64 = @intCast(filename_len_usize);
            file.seekBy(filename_len_i64) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "entry filename", .full);
            };
        }

        // Skip extra field
        file.seekBy(@as(i64, extra_len)) catch {
            return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "filename/extra", .full);
        };

        if (is_encrypted) {
            // Entry is encrypted - we cannot validate CRC without decryption key
            // Skip the compressed data and continue with structural validation
            encrypted_entry_count += 1;
            file.seekBy(@as(i64, compressed_size)) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "encrypted entry", .structural);
            };
            continue;
        }

        // Handle data descriptor entries (bit 3 set) - sizes in header are 0
        // We need to scan forward to find the data descriptor or central directory
        if (has_data_descriptor) {
            // Data descriptor entries: the CRC and sizes in the local header are 0.
            // The actual CRC/sizes are in a data descriptor that follows the compressed data.
            // For validation, we skip CRC verification for these entries since we'd need to
            // decompress to find where the data ends (chicken-and-egg problem).
            // Just scan forward to find the data descriptor.

            // Scan for data descriptor or central directory
            // Data descriptor: [PK\x07\x08] CRC(4) CompSize(4) UncompSize(4)
            // NOTE: We do NOT stop at PK\x03\x04 (local file header) because that could be
            // a false positive inside compressed data (e.g., nested ZIP files).
            // We only stop at:
            // - PK\x07\x08 (data descriptor with signature)
            // - PK\x01\x02 (central directory - end of local file headers)
            // - PK\x05\x06 (end of central directory)
            var scan_buf: [4]u8 = undefined;
            var found_next = false;
            while (!found_next) {
                const bytes_read = file.read(&scan_buf) catch break;
                entry_telemetry.descriptor_reads += 1;
                if (bytes_read == 0) break;
                if (bytes_read < 4) break;

                // Check for PK signature
                if (scan_buf[0] == 'P' and scan_buf[1] == 'K') {
                    if (scan_buf[2] == 0x07 and scan_buf[3] == 0x08) {
                        // Data descriptor - skip the 12-byte descriptor (CRC + sizes)
                        file.seekBy(12) catch break;
                        found_next = true;
                        break;
                    } else if (scan_buf[2] == 0x01 and scan_buf[3] == 0x02) {
                        // Central directory header - end of local file headers
                        file.seekBy(-4) catch break;
                        found_next = true;
                        break;
                    } else if (scan_buf[2] == 0x05 and scan_buf[3] == 0x06) {
                        // End of central directory
                        file.seekBy(-4) catch break;
                        found_next = true;
                        break;
                    }
                    // PK\x03\x04 could be inside compressed data (nested ZIP), continue scanning
                }
                // Continue scanning - seek back 3 bytes to catch overlapping signatures
                file.seekBy(-3) catch break;
            }
            continue;
        }

        // Skip entries with size 0 (directories)
        if (compressed_size == 0 and uncompressed_size == 0) {
            continue;
        }

        // Skip entries with CRC of 0 (shouldn't happen if data descriptor flag isn't set, but be safe)
        if (stored_crc == 0) {
            // Skip the compressed data
            file.seekBy(@as(i64, compressed_size)) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "entry data", .full);
            };
            continue;
        }

        // Safety: don't decompress huge files
        if (uncompressed_size > max_uncompressed_size) {
            // Skip this entry but don't fail
            file.seekBy(@as(i64, compressed_size)) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "large entry", .full);
            };
            continue;
        }

        // Validate CRC based on compression method
        switch (@as(ZipCompressionMethod, @enumFromInt(compression_method))) {
            .store => {
                // Stored (uncompressed) - CRC the data directly
                const result = validateZipStoredEntry(file, stored_crc, compressed_size);
                if (!result.is_valid) {
                    return ValidationResult.invalidWithDepth(format, result.error_message orelse "CRC mismatch", .full);
                }
            },
            .deflate => {
                // Deflated - decompress and verify CRC
                const result = validateZipDeflatedEntry(allocator, file, stored_crc, compressed_size, uncompressed_size);
                if (!result.is_valid) {
                    return ValidationResult.invalidWithDepth(format, result.error_message orelse "Deflate CRC mismatch", .full);
                }
            },
            _ => {
                // Unknown compression method - skip
                file.seekBy(@as(i64, compressed_size)) catch {
                    return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "entry", .full);
                };
            },
        }
    }

    if (entry_count == 0) {
        return ValidationResult.invalidWithDepth(format, "No entries found", .full);
    }

    // If all entries were encrypted, we could only do structural validation
    if (encrypted_entry_count > 0 and encrypted_entry_count == entry_count) {
        return ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = .structural,
            .has_encrypted_content = true,
        };
    }

    // If some entries were encrypted, report it but validation succeeded for unencrypted ones
    if (encrypted_entry_count > 0) {
        return ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = .full,
            .has_encrypted_content = true,
        };
    }

    return ValidationResult.okWithDepth(format, .full);
}

/// Validate a stored (uncompressed) ZIP entry by computing CRC-32.
pub fn validateZipStoredEntry(file: std.fs.File, stored_crc: u32, size: u32) ValidationResult {
    var crc = std.hash.Crc32.init();
    var remaining: u32 = size;
    var read_buffer: [65536]u8 = undefined;

    while (remaining > 0) {
        const to_read = @min(remaining, read_buffer.len);
        const bytes_read = file.read(read_buffer[0..to_read]) catch |err| {
            if (err == error.EndOfStream) {
                return ValidationResult.invalid(.zip, "Unexpected EOF in entry data");
            }
            return ValidationResult.invalidCode(.zip, .failed_to_read, "entry data");
        };
        if (bytes_read == 0) {
            return ValidationResult.invalid(.zip, "Unexpected EOF in entry data");
        }
        crc.update(read_buffer[0..bytes_read]);
        remaining -= @as(u32, @intCast(bytes_read));
    }

    const computed_crc = crc.final();
    if (stored_crc != computed_crc) {
        return ValidationResult.invalidCodeMsg(.zip, .checksum_mismatch, "CRC", "CRC mismatch in stored entry");
    }

    return ValidationResult.ok(.zip);
}

/// Validate a deflated ZIP entry by decompressing and computing CRC-32.
/// Uses bundled zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
pub fn validateZipDeflatedEntry(allocator: Allocator, file: std.fs.File, stored_crc: u32, compressed_size: u32, uncompressed_size: u32) ValidationResult {
    // Skip if uncompressed size exceeds limit (zip bomb protection)
    if (uncompressed_size > format_validation.MAX_ZIP_ENTRY_SIZE) {
        // Skip validation for huge entries - just seek past
        file.seekBy(@as(i64, compressed_size)) catch {
            return ValidationResult.invalidCode(.zip, .failed_to_skip, "large deflated entry");
        };
        return ValidationResult.ok(.zip);
    }

    // Skip validation for very large compressed data (memory limit)
    const max_compressed_read: u32 = 64 * 1024 * 1024; // 64MB limit for compressed data
    if (compressed_size > max_compressed_read) {
        file.seekBy(@as(i64, compressed_size)) catch {
            return ValidationResult.invalidCode(.zip, .failed_to_skip, "large compressed entry");
        };
        return ValidationResult.ok(.zip);
    }

    // Read compressed data directly from file
    const compressed_data = allocator.alloc(u8, compressed_size) catch {
        // If allocation fails, skip this entry
        file.seekBy(@as(i64, compressed_size)) catch {
            return ValidationResult.invalidCode(.zip, .failed_to_skip, "entry after alloc failure");
        };
        return ValidationResult.ok(.zip);
    };
    defer allocator.free(compressed_data);

    const bytes_read = file.readAll(compressed_data) catch {
        return ValidationResult.invalidCode(.zip, .failed_to_read, "compressed data");
    };
    if (bytes_read != compressed_size) {
        return ValidationResult.invalidCode(.zip, .incomplete, "read of compressed data");
    }

    // Allocate output buffer for decompressed data
    const output_data = allocator.alloc(u8, uncompressed_size) catch {
        return ValidationResult.ok(.zip); // Skip on alloc failure
    };
    defer allocator.free(output_data);

    // Use zlib for robust decompression (Zig's std.compress.flate has bugs)
    const result = zlib.inflateRawWithCrc(compressed_data, output_data) catch |err| {
        return switch (err) {
            zlib.ZlibError.DataError => ValidationResult.invalid(.zip, "Deflate decompression failed - corrupted data"),
            zlib.ZlibError.BufferError => ValidationResult.invalid(.zip, "Deflate decompression failed - buffer error"),
            else => ValidationResult.invalidCode(.zip, .decompression_failed, "Deflate"),
        };
    };

    // Verify CRC matches
    if (stored_crc != result.crc32) {
        return ValidationResult.invalidCodeMsg(.zip, .checksum_mismatch, "CRC", "CRC mismatch in deflated entry");
    }

    // Verify size matches
    if (result.size != uncompressed_size) {
        return ValidationResult.invalid(.zip, "Decompressed size mismatch");
    }

    return ValidationResult.ok(.zip);
}

// ============ Gzip Deep Validation ============

/// Deep gzip validation - decompresses and verifies CRC32.
/// Uses bundled zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
/// Validates:
/// - Header structure and flags
/// - Full decompression of deflate stream
/// - CRC32 of decompressed data matches trailer
/// - ISIZE (uncompressed size mod 2^32) matches
pub fn validateGzipDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.gzip, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.gzip, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.gzip, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.gzip, .failed_to_get, "file size", .structural);
    };

    if (file_size < 18) { // Minimum gzip: 10 header + 8 trailer
        return ValidationResult.invalidWithDepth(.gzip, "File too small", .structural);
    }

    // Limit file size to prevent memory exhaustion (1GB max for gzip validation)
    const max_gzip_size: u64 = 1024 * 1024 * 1024;
    if (file_size > max_gzip_size) {
        return ValidationResult.invalidCodeWithDepth(.gzip, .file_too_large, "validation", .structural);
    }

    // Read entire file
    const file_data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalidCodeWithDepth(.gzip, .failed_to_allocate, "read buffer", .structural);
    };
    defer allocator.free(file_data);

    const bytes_read = file.readAll(file_data) catch {
        return ValidationResult.invalidCodeWithDepth(.gzip, .failed_to_read, "file", .structural);
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCodeWithDepth(.gzip, .incomplete, "file read", .structural);
    }

    // Validate header
    if (file_data[0] != 0x1F or file_data[1] != 0x8B) {
        return ValidationResult.invalidCodeWithDepth(.gzip, .invalid_value, "magic number", .structural);
    }
    if (file_data[2] != 8) {
        return ValidationResult.invalidCodeWithDepth(.gzip, .invalid_value, "compression method", .structural);
    }
    if (file_data[3] & 0xE0 != 0) {
        return ValidationResult.invalidWithDepth(.gzip, "Reserved flag bits set", .structural);
    }

    // Use zlib to validate (robust, handles all edge cases)
    const max_decompressed = format_validation.MAX_DECOMPRESSED_SIZE;
    const valid = zlib.validateGzip(allocator, file_data, max_decompressed) catch |err| {
        return switch (err) {
            zlib.ZlibError.DataError => ValidationResult.invalidWithDepth(.gzip, "Decompression failed - corrupt data", .full),
            zlib.ZlibError.BufferError => ValidationResult.invalidWithDepth(.gzip, "Decompressed data too large", .full),
            else => ValidationResult.invalidWithDepth(.gzip, "Decompression failed", .full),
        };
    };

    if (valid) {
        return ValidationResult.okWithDepth(.gzip, .full);
    } else {
        return ValidationResult.invalidCodeMsgWithDepth(.gzip, .checksum_mismatch, "CRC32 or ISIZE", "CRC32 or ISIZE mismatch - data corrupted", .full);
    }
}

/// A writer that computes CRC32 of all data written to it, then discards the data.
/// Used for streaming gzip validation without buffering the entire decompressed output.
/// Based on std.Io.Writer.Discarding pattern for Zig 0.15 compatibility.
pub const CrcHashingWriter = struct {
    crc: *std.hash.Crc32,
    count: u64,
    writer: std.Io.Writer,

    const IoWriter = std.Io.Writer;
    const File = std.fs.File;

    pub fn init(crc: *std.hash.Crc32, buffer: []u8) CrcHashingWriter {
        return .{
            .crc = crc,
            .count = 0,
            .writer = .{
                .vtable = &.{
                    .drain = CrcHashingWriter.drain,
                    .sendFile = CrcHashingWriter.sendFile,
                    .rebase = CrcHashingWriter.rebase,
                },
                .buffer = buffer,
            },
        };
    }

    /// Total bytes processed including buffered data
    pub fn fullCount(self: *const CrcHashingWriter) u64 {
        return self.count + self.writer.end;
    }

    pub fn drain(w: *IoWriter, data: []const []const u8, splat: usize) IoWriter.Error!usize {
        const self: *CrcHashingWriter = @alignCast(@fieldParentPtr("writer", w));

        // Hash buffered data first
        if (w.end > 0) {
            self.crc.update(w.buffer[0..w.end]);
        }

        // Hash incoming data slices
        const slice = data[0 .. data.len - 1];
        const pattern = data[slice.len];
        var written: usize = 0;

        for (slice) |bytes| {
            self.crc.update(bytes);
            written += bytes.len;
        }

        // Handle splatted pattern (repeated data)
        for (0..splat) |_| {
            self.crc.update(pattern);
        }
        written += pattern.len * splat;

        self.count += w.end + written;
        w.end = 0;
        return written;
    }

    pub fn sendFile(w: *IoWriter, file_reader: *File.Reader, limit: std.Io.Limit) IoWriter.FileError!usize {
        // For CRC hashing, we can't just skip bytes - we need to read and hash them
        // Fall back to unimplemented to force buffered reads
        _ = w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented;
    }

    /// Rebase: ensure capacity by draining old data while preserving history for LZ77
    /// This is critical for flate decompression which needs back-reference history
    pub fn rebase(w: *IoWriter, preserve: usize, minimum_len: usize) IoWriter.Error!void {
        // Use the standard library's default rebase logic which:
        // 1. Calculates how much data to keep (preserve bytes from end)
        // 2. Drains data before the preserved section
        // 3. Moves preserved data to the start of buffer
        // This maintains the history window needed for LZ77 back-references
        while (w.buffer.len - w.end < minimum_len) {
            const preserved_head = w.end -| preserve;
            const preserved_tail = w.end;
            const preserved_len = preserved_tail - preserved_head;

            // Temporarily set end to before preserved data so drain only hashes old data
            w.end = preserved_head;

            // Drain the old data (will hash buffer[0..preserved_head])
            // After drain, w.end will be 0
            _ = try CrcHashingWriter.drain(w, &.{""}, 1);

            // Move preserved data to the start of buffer (at position 0 after drain)
            if (preserved_len > 0) {
                // Use copyForwards since dest.ptr < src.ptr (we're moving data earlier in buffer)
                // Note: slices may overlap when preserved_len > preserved_head
                std.mem.copyForwards(u8, w.buffer[0..preserved_len], w.buffer[preserved_head..preserved_tail]);
            }
            w.end = preserved_len;

            // Safety check - buffer must be large enough after rebase
            if (w.buffer.len - preserve < minimum_len) {
                return error.WriteFailed;
            }
        }
    }
};

// ============ Bzip2 Deep Validation ============

/// Deep Bzip2 validation by attempting decompression with CRC verification.
/// Bzip2 uses CRC32 for each block and a combined CRC at the end.
/// Our pure Zig bzip2 decompressor verifies all checksums during decompression.
pub fn validateBzip2Deep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.bzip2, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.bzip2, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_get, "file size", .structural);
    };

    if (file_size < 14) {
        return ValidationResult.invalidWithDepth(.bzip2, "File too small", .structural);
    }

    // Read the entire file for decompression
    // Limit to prevent memory exhaustion (1 GB compressed limit)
    const max_compressed_size: usize = 1024 * 1024 * 1024;
    if (file_size > max_compressed_size) {
        // For very large files, fall back to structural validation
        return validateBzip2LargeFile(file);
    }

    const compressed_data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .out_of_memory, "for bzip2", .structural);
    };
    defer allocator.free(compressed_data);

    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_seek, "in bzip2 data", .structural);
    };

    const bytes_read = file.readAll(compressed_data) catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_read, "file", .structural);
    };

    if (bytes_read != file_size) {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .incomplete, "read", .structural);
    }

    // Validate header
    if (compressed_data.len < 4) {
        return ValidationResult.invalidWithDepth(.bzip2, "File too small", .structural);
    }

    if (!std.mem.eql(u8, compressed_data[0..3], &BZIP2_SIGNATURE)) {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "magic number", .structural);
    }

    const block_size_char = compressed_data[3];
    if (block_size_char < '1' or block_size_char > '9') {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "block size", .structural);
    }

    // Attempt full decompression with CRC verification
    // Our bzip2 decompressor checks both block CRCs and stream CRC
    const decompressed = bzip2.decompress(allocator, compressed_data) catch |err| {
        return switch (err) {
            error.BlockCrcMismatch => ValidationResult.invalidCodeMsgWithDepth(.bzip2, .checksum_mismatch, "Block CRC", "Block CRC mismatch - data corrupted", .full),
            error.StreamCrcMismatch => ValidationResult.invalidCodeMsgWithDepth(.bzip2, .checksum_mismatch, "Stream CRC", "Stream CRC mismatch - data corrupted", .full),
            error.InvalidMagic => ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "magic number", .structural),
            error.InvalidBlockSize => ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "block size", .structural),
            error.InvalidBlockHeader => ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "block header", .structural),
            error.CorruptData => ValidationResult.invalidWithDepth(.bzip2, "Corrupt compressed data", .structural),
            error.HuffmanOverflow => ValidationResult.invalidWithDepth(.bzip2, "Huffman table overflow", .structural),
            error.InvalidSelector => ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "selector", .structural),
            error.UnexpectedEof => ValidationResult.invalidWithDepth(.bzip2, "Unexpected end of file", .structural),
            error.InvalidBwtIndex => ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "BWT index", .structural),
            error.OutOfMemory => ValidationResult.invalidCodeWithDepth(.bzip2, .out_of_memory, "during decompression", .structural),
            else => ValidationResult.invalidWithDepth(.bzip2, "Decompression failed", .structural),
        };
    };
    defer allocator.free(decompressed);

    // Decompression succeeded with CRC verification
    return ValidationResult.okWithDepth(.bzip2, .full);
}

/// Structural validation for large bzip2 files (>1GB compressed)
pub fn validateBzip2LargeFile(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_seek, "in bzip2 data", .structural);
    };

    var header: [4]u8 = undefined;
    _ = file.read(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .failed_to_read, "header", .structural);
    };

    if (!std.mem.eql(u8, header[0..3], &BZIP2_SIGNATURE)) {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "magic number", .structural);
    }

    const block_size_char = header[3];
    if (block_size_char < '1' or block_size_char > '9') {
        return ValidationResult.invalidCodeWithDepth(.bzip2, .invalid_value, "block size", .structural);
    }

    // For large files, we only do structural validation
    // Full CRC verification would require decompressing the entire file
    return ValidationResult.okWithDepth(.bzip2, .structural);
}

// ============ XZ Deep Validation ============

/// Deep XZ validation by streaming decompression.
/// XZ format includes CRC32/CRC64 checksums that are verified during decompression.
pub fn validateXzDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.xz, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.xz, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.xz, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size for basic validation
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.xz, .failed_to_get, "file size", .structural);
    };

    if (file_size < 32) { // Minimum XZ: 12 header + index + 12 footer
        return ValidationResult.invalidWithDepth(.xz, "File too small", .structural);
    }

    // Use deprecatedReader for XZ (it uses old std.io.GenericReader API)
    const deprecated_reader = file.deprecatedReader();

    // Initialize XZ decompressor
    var decompressor = std.compress.xz.decompress(allocator, deprecated_reader) catch |err| {
        return switch (err) {
            error.BadHeader => ValidationResult.invalidCodeWithDepth(.xz, .invalid_value, "XZ header", .structural),
            error.WrongChecksum => ValidationResult.invalidCodeMsgWithDepth(.xz, .checksum_mismatch, "Header", "Header checksum mismatch", .full),
            else => ValidationResult.invalidWithDepth(.xz, "Decompressor init failed", .structural),
        };
    };
    defer decompressor.deinit();

    // Stream decompression, discarding output but verifying integrity
    // XZ decoder verifies CRC checksums internally
    var discard_buf: [65536]u8 = undefined;
    var total_decompressed: u64 = 0;

    while (true) {
        const bytes_read = decompressor.read(&discard_buf) catch |err| {
            // Check for specific error types
            return switch (err) {
                error.CorruptInput => ValidationResult.invalidWithDepth(.xz, "Corrupt compressed data", .full),
                error.WrongChecksum => ValidationResult.invalidCodeMsgWithDepth(.xz, .checksum_mismatch, "CRC", "CRC checksum mismatch", .full),
                error.EndOfStream => ValidationResult.invalidWithDepth(.xz, "Unexpected end of stream", .structural),
                else => ValidationResult.invalidWithDepth(.xz, "Decompression error", .full),
            };
        };

        if (bytes_read == 0) break; // EOF

        total_decompressed += bytes_read;

        // Zip bomb protection
        if (total_decompressed > format_validation.MAX_DECOMPRESSED_SIZE) {
            return ValidationResult.invalidCodeMsgWithDepth(.xz, .exceeds_bounds, "Decompressed size", "Decompressed size exceeds limit", .structural);
        }
    }

    // Successfully decompressed entire stream with CRC verification
    return ValidationResult.okWithDepth(.xz, .full);
}

// ============ Zstd Deep Validation ============

/// Deep Zstandard validation by streaming decompression.
/// Zstd has optional xxHash checksum that is verified during decompression.
pub fn validateZstdDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator; // Zstd decompressor doesn't need allocator for streaming

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.zstd, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.zstd, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size for basic validation
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_get, "file size", .structural);
    };

    if (file_size < 8) { // Minimum Zstd frame
        return ValidationResult.invalidWithDepth(.zstd, "File too small", .structural);
    }

    // Create reader from file (new std.Io.Reader API)
    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buf);

    // Initialize Zstd decompressor
    // Zstd.Decompress uses window buffer for dictionary
    var window_buf: [std.compress.zstd.default_window_len]u8 = undefined;
    var zstd_stream: std.compress.zstd.Decompress = .init(&file_reader.interface, &window_buf, .{});

    // Create a counting writer that discards output (like gzip does)
    // We use streamRemaining to decompress the entire stream
    var discard_buf: [65536]u8 = undefined;
    var discard_writer: std.Io.Writer = .{
        .vtable = &.{
            .drain = discardDrain,
            .sendFile = discardSendFile,
        },
        .buffer = &discard_buf,
    };

    // Track total decompressed size for zip bomb protection
    var total_decompressed: u64 = 0;

    // Stream decompression in chunks with size limit check
    // Note: reader.stream() returns StreamError (EndOfStream, ReadFailed, WriteFailed)
    // Zstd-specific errors are wrapped into these generic errors
    while (true) {
        const bytes_written = zstd_stream.reader.stream(&discard_writer, .limited(discard_buf.len)) catch |err| {
            return switch (err) {
                error.EndOfStream => ValidationResult.invalidWithDepth(.zstd, "Unexpected end of stream", .structural),
                error.ReadFailed => ValidationResult.invalidWithDepth(.zstd, "Decompression failed - corrupt data", .full),
                error.WriteFailed => ValidationResult.invalidWithDepth(.zstd, "Write failed during validation", .structural),
            };
        };

        if (bytes_written == 0) break; // EOF

        total_decompressed += bytes_written;

        // Zip bomb protection
        if (total_decompressed > format_validation.MAX_DECOMPRESSED_SIZE) {
            return ValidationResult.invalidCodeMsgWithDepth(.zstd, .exceeds_bounds, "Decompressed size", "Decompressed size exceeds limit", .structural);
        }
    }

    // Successfully decompressed entire stream
    // Note: Zstd checksum is optional, so we report decompression depth
    return ValidationResult.okWithDepth(.zstd, .full);
}

/// Discard drain function for validation (accepts data and throws it away)
pub fn discardDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    // Just count the bytes without actually storing them
    var total: usize = 0;
    for (data[0 .. data.len - 1]) |slice| {
        total += slice.len;
    }
    // Add the splatted pattern
    total += data[data.len - 1].len * splat;

    // Clear the buffer since we're discarding
    w.end = 0;

    return total;
}

/// Discard sendFile function (not supported for discarding writer)
pub fn discardSendFile(w: *std.Io.Writer, file_reader: *std.fs.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
    _ = w;
    _ = file_reader;
    _ = limit;
    return error.Unimplemented;
}

// ============ 7-Zip Deep Validation ============

/// Deep 7-Zip validation using the sevenz_validator module.
/// This validates header CRCs and uses the system's 7z command for full integrity testing.
pub fn validate7zDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const result = sevenz_validator.validateSevenZDeep(allocator, path);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.sevenz, result.error_message orelse "7z validation failed", .full);
    }

    // If files were checked via 7z command, report full validation
    if (result.files_checked > 0) {
        return ValidationResult.okWithDepth(.sevenz, .full);
    }

    // Otherwise header CRCs were verified but no file decompression
    return ValidationResult.okWithDepth(.sevenz, .structural);
}

// ============ RAR Deep Validation ============

/// Deep RAR validation using the rar_validator module.
/// This validates header CRCs and uses unrar or 7z for full integrity testing.
pub fn validateRarDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const result = rar_validator.validateRarDeep(allocator, path);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.rar, result.error_message orelse "RAR validation failed", .full);
    }

    // If files were checked via unrar/7z command, report full validation
    if (result.files_checked > 0) {
        return ValidationResult.okWithDepth(.rar, .full);
    }

    // Otherwise only header validation was possible (no unrar/7z available)
    return ValidationResult.okWithDepth(.rar, .structural);
}

// ============ Buffer Validators ============

pub fn validateZipFromBuffer(data: []const u8, format: FileFormat) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(format, "File too small");
    // Check local file header signature
    if (data[0] == 0x50 and data[1] == 0x4B and data[2] == 0x03 and data[3] == 0x04) {
        // TODO: Full ZIP validation (EOCD check)
        return ValidationResult.ok(format);
    }
    return ValidationResult.invalidCode(format, .invalid_signature, "ZIP");
}

pub fn validateGzipFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 2) return ValidationResult.invalid(.gzip, "File too small");
    if (data[0] == 0x1F and data[1] == 0x8B) {
        return ValidationResult.ok(.gzip);
    }
    return ValidationResult.invalidCode(.gzip, .invalid_signature, "GZIP");
}

pub fn validateBzip2FromBuffer(data: []const u8) ValidationResult {
    if (data.len < 3) return ValidationResult.invalid(.bzip2, "File too small");
    if (data[0] == 'B' and data[1] == 'Z' and data[2] == 'h') {
        return ValidationResult.ok(.bzip2);
    }
    return ValidationResult.invalidCode(.bzip2, .invalid_signature, "BZIP2");
}

pub fn validateXzFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 6) return ValidationResult.invalid(.xz, "File too small");
    const xz_sig = [_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 };
    if (std.mem.eql(u8, data[0..6], &xz_sig)) {
        return ValidationResult.ok(.xz);
    }
    return ValidationResult.invalidCode(.xz, .invalid_signature, "XZ");
}

pub fn validateZstdFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(.zstd, "File too small");
    // Zstd magic: 0xFD2FB528 (little-endian)
    if (data[0] == 0x28 and data[1] == 0xB5 and data[2] == 0x2F and data[3] == 0xFD) {
        return ValidationResult.ok(.zstd);
    }
    return ValidationResult.invalidCode(.zstd, .invalid_signature, "ZSTD");
}

pub fn validateRarFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 7) return ValidationResult.invalid(.rar, "File too small");
    // RAR 5.0 signature
    const rar5_sig = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01 };
    // RAR 4.x signature
    const rar4_sig = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };
    if (std.mem.eql(u8, data[0..7], &rar5_sig) or std.mem.eql(u8, data[0..7], &rar4_sig)) {
        return ValidationResult.ok(.rar);
    }
    return ValidationResult.invalidCode(.rar, .invalid_signature, "RAR");
}

pub fn validate7zFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 6) return ValidationResult.invalid(.sevenz, "File too small");
    const sig_7z = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };
    if (std.mem.eql(u8, data[0..6], &sig_7z)) {
        return ValidationResult.ok(.sevenz);
    }
    return ValidationResult.invalidCode(.sevenz, .invalid_signature, "7z");
}
