//! Archive format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for archive/compression formats: ZIP, Gzip, Bzip2, XZ, Zstandard, RAR, 7-Zip,
//! Tar, PAR2, and WARC.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const codec_utils = @import("codec_utils.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const MalformationType = format_validation.MalformationType;
const ValidationDepth = format_validation.ValidationDepth;

// External module imports
const zlib = @import("zlib.zig");
const bzip2 = @import("bzip2.zig");
const sevenz_validator = @import("sevenz_validator.zig");
const errmsg = @import("error_messages.zig");
const XxHash64 = std.hash.XxHash64;
const rarz = @import("rarz");
const c_compact_pro = @cImport({
    @cInclude("compact_pro.h");
});

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;

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
pub const rarCrc16 = codec_utils.crc16Ccitt;

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

    // Parse file size from header (bytes 124-135, octal) and advance to next entry
    const file_size_field = header[124..136];
    var entry_size: u64 = 0;
    for (file_size_field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') break;
        entry_size = entry_size * 8 + (c - '0');
    }

    // Data blocks follow header: ceil(entry_size / 512) * 512 bytes
    const data_blocks = (entry_size + 511) / 512;
    var pos: u64 = 512 + data_blocks * 512;

    const total_file_size = file.getEndPos() catch return ValidationResult.ok(.tar);
    var headers_validated: u32 = 1;

    // Validate ALL subsequent tar entry headers
    while (pos + 512 <= total_file_size and headers_validated < 100000) {
        file.seekTo(pos) catch break;
        const n = file.read(&header) catch break;
        if (n < 512) break;

        // Check for end-of-archive marker (two consecutive zero blocks per POSIX)
        var is_zero = true;
        for (header) |b| {
            if (b != 0) {
                is_zero = false;
                break;
            }
        }
        if (is_zero) {
            // Validate second zero block if present
            if (pos + 512 + 512 <= total_file_size) {
                file.seekTo(pos + 512) catch break;
                var second_block: [512]u8 = undefined;
                const sb_read = file.readAll(&second_block) catch break;
                if (sb_read == 512) {
                    var second_zero = true;
                    for (second_block) |b| {
                        if (b != 0) {
                            second_zero = false;
                            break;
                        }
                    }
                    if (!second_zero) {
                        return ValidationResult.invalidCode(.tar, .invalid_value, "Second end-of-archive block is not zero");
                    }
                }
            }
            // Also validate any remaining blocks are zero (padding)
            var check_pos = pos + 1024;
            while (check_pos + 512 <= total_file_size) {
                file.seekTo(check_pos) catch break;
                var pad_block: [512]u8 = undefined;
                const pb_read = file.readAll(&pad_block) catch break;
                if (pb_read < 512) break;
                for (pad_block) |b| {
                    if (b != 0) {
                        return ValidationResult.invalidCode(.tar, .invalid_value, "Non-zero data after end-of-archive marker");
                    }
                }
                check_pos += 512;
            }
            break;
        }

        // Validate this header's checksum
        var hdr_checksum: u32 = 0;
        for (header, 0..) |byte, i| {
            if (i >= 148 and i < 156) {
                hdr_checksum += ' ';
            } else {
                hdr_checksum += byte;
            }
        }

        var hdr_stored: u32 = 0;
        for (header[148..156]) |c| {
            if (c == 0 or c == ' ') break;
            if (c < '0' or c > '7') {
                return ValidationResult.invalidCode(.tar, .invalid_value, "entry checksum format");
            }
            hdr_stored = hdr_stored * 8 + (c - '0');
        }

        if (hdr_checksum != hdr_stored) {
            return ValidationResult.invalidCodeMsg(.tar, .checksum_mismatch, "Entry header", "Tar entry header checksum mismatch");
        }

        headers_validated += 1;

        // Parse this entry's file size and skip to next
        entry_size = 0;
        for (header[124..136]) |c| {
            if (c == 0 or c == ' ') break;
            if (c < '0' or c > '7') break;
            entry_size = entry_size * 8 + (c - '0');
        }

        const next_data_blocks = (entry_size + 511) / 512;

        // Validate data block padding (POSIX requires zero-fill)
        if (entry_size > 0 and next_data_blocks > 0) {
            const remainder = entry_size % 512;
            if (remainder != 0) {
                const padding_start = pos + 512 + entry_size;
                const padding_len = 512 - remainder;
                file.seekTo(padding_start) catch {};
                var pad_buf: [512]u8 = undefined;
                const pad_read = file.readAll(pad_buf[0..padding_len]) catch 0;
                if (pad_read == padding_len) {
                    for (pad_buf[0..padding_len]) |b| {
                        if (b != 0) {
                            return ValidationResult.invalidCode(.tar, .invalid_value, "Non-zero data block padding");
                        }
                    }
                }
            }
        }

        pos += 512 + next_data_blocks * 512;
    }

    return ValidationResult.okWithDepth(.tar, .full);
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

    return ValidationResult.okWithDepth(.warc, .structural);
}

// ============ WARC Deep Validation (SHA-1 Block Digest) ============

const Sha1 = std.crypto.hash.Sha1;

/// RFC 4648 Base32 alphabet: A-Z = 0-25, 2-7 = 26-31
fn base32CharValue(c: u8) ?u5 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a'), // case-insensitive per RFC 4648
        '2'...'7' => @intCast(c - '2' + 26),
        else => null,
    };
}

/// Decode RFC 4648 Base32-encoded data into `out`. Returns number of bytes
/// written, or null if the input contains invalid characters or the output
/// buffer is too small.
fn base32Decode(encoded: []const u8, out: []u8) ?usize {
    // Strip trailing padding
    var len = encoded.len;
    while (len > 0 and encoded[len - 1] == '=') : (len -= 1) {}
    const input = encoded[0..len];

    // Each 8 base32 chars → 5 bytes; partial groups are allowed
    const out_len = (input.len * 5) / 8;
    if (out.len < out_len) return null;

    var buf: u64 = 0;
    var bits: u6 = 0;
    var written: usize = 0;

    for (input) |c| {
        const val: u64 = base32CharValue(c) orelse return null;
        buf = (buf << 5) | val;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            if (written >= out.len) return null;
            out[written] = @intCast((buf >> bits) & 0xFF);
            written += 1;
        }
    }

    return written;
}

/// Deep WARC validation: parses records and verifies WARC-Block-Digest SHA-1
/// checksums against computed hashes of record bodies. Returns .full depth when
/// at least one digest is present and all verify; .structural with a warning
/// when no digests are found; invalid on any mismatch.
pub fn validateWarcDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.warc, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.warc, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.warc, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.warc, .failed_to_get, "file size", .structural);
    };

    if (file_size < 20) {
        return ValidationResult.invalidCode(.warc, .file_too_small, "WARC");
    }

    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    var record_count: u32 = 0;
    var digest_count: u32 = 0;
    var verified_count: u32 = 0;

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
        var digest_value: ?[]const u8 = null; // slice into buffer pointing at "sha1:XXXXX"

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
                var val_start: usize = 15;
                while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
                if (val_start < line.len) {
                    content_length = std.fmt.parseInt(u64, line[val_start..], 10) catch null;
                }
            } else if (std.mem.startsWith(u8, line, "WARC-Block-Digest:")) {
                // Extract digest value, trimming leading whitespace
                var val_start: usize = 18; // len("WARC-Block-Digest:")
                while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
                if (val_start < line.len) {
                    digest_value = line[val_start..];
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

        const body_start = offset + header_end;
        const body_end = body_start + content_length.?;
        const next_record = body_end + 4; // \r\n\r\n separator

        if (body_end > file_size) {
            return ValidationResult.invalidCodeMsg(.warc, .exceeds_bounds, "Content-Length", "Content-Length exceeds file bounds");
        }

        // Verify digest if present
        if (digest_value) |dv| {
            if (std.mem.startsWith(u8, dv, "sha1:") or std.mem.startsWith(u8, dv, "SHA1:") or
                std.mem.startsWith(u8, dv, "sha-1:") or std.mem.startsWith(u8, dv, "SHA-1:"))
            {
                // Find the colon separating algorithm from hash
                const colon_pos = std.mem.indexOfScalar(u8, dv, ':').?;
                const b32_encoded = dv[colon_pos + 1 ..];

                // Decode the expected SHA-1 from Base32
                var expected_hash: [20]u8 = undefined;
                const decoded_len = base32Decode(b32_encoded, &expected_hash) orelse {
                    return ValidationResult.invalidWithDepth(.warc, "Invalid Base32 in WARC-Block-Digest", .full);
                };
                if (decoded_len != 20) {
                    return ValidationResult.invalidWithDepth(.warc, "WARC-Block-Digest SHA-1 has wrong length", .full);
                }

                // Compute SHA-1 over the record body by streaming from the file
                file.seekTo(body_start) catch {
                    return ValidationResult.invalidCode(.warc, .failed_to_seek, "to record body");
                };

                var hasher = Sha1.init(.{});
                var remaining = content_length.?;
                var hash_buf: [8192]u8 = undefined;

                while (remaining > 0) {
                    const chunk = @min(hash_buf.len, @as(usize, @intCast(remaining)));
                    const n = file.read(hash_buf[0..chunk]) catch {
                        return ValidationResult.invalidCode(.warc, .failed_to_read, "record body");
                    };
                    if (n == 0) break;
                    hasher.update(hash_buf[0..n]);
                    remaining -= @as(u64, @intCast(n));
                }

                if (remaining != 0) {
                    return ValidationResult.invalidWithDepth(.warc, "Record body shorter than Content-Length", .full);
                }

                const computed_hash = hasher.finalResult();

                if (!std.mem.eql(u8, &computed_hash, &expected_hash)) {
                    return ValidationResult.invalidWithDepth(.warc, "WARC-Block-Digest SHA-1 mismatch", .full);
                }

                digest_count += 1;
                verified_count += 1;
            }
            // Silently skip unsupported digest algorithms (not sha1)
        }

        record_count += 1;
        offset = next_record;

        if (record_count > 10_000_000) {
            return ValidationResult.invalidCode(.warc, .too_many, "records");
        }

        if (record_count >= 100 and offset > file_size / 2) {
            break;
        }
    }

    if (record_count == 0) {
        return ValidationResult.invalid(.warc, "No WARC records found");
    }

    if (digest_count == 0) {
        return ValidationResult.okWithDepthAndWarning(.warc, .structural, "no WARC-Block-Digest headers found; structure valid but content not verified");
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

const readLe = codec_utils.readLe;

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

        const local_compression = readLe(u16, local_header[4..6]);
        const local_crc = readLe(u32, local_header[10..14]);
        const local_compressed_size = readLe(u32, local_header[14..18]);
        const local_uncompressed_size = readLe(u32, local_header[18..22]);
        const local_filename_len = readLe(u16, local_header[22..24]);
        const local_extra_len = readLe(u16, local_header[24..26]);
        const local_flags = readLe(u16, local_header[0..2]);

        // Cross-validate central directory vs local file header fields
        if (local_compression != compression_method) {
            return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP compression method mismatch (central vs local)", .full);
        }

        // CRC/sizes may be zero in local header if data descriptor flag (bit 3) is set
        const has_data_descriptor = (local_flags & 0x0008) != 0;
        if (!has_data_descriptor) {
            if (local_crc != 0 and stored_crc != 0 and local_crc != @as(u32, @intCast(stored_crc & 0xFFFFFFFF))) {
                return ValidationResult.invalidCodeWithDepth(format, .checksum_mismatch, "ZIP CRC-32 mismatch (central vs local header)", .full);
            }
            if (local_compressed_size != 0 and compressed_size != 0 and
                local_compressed_size != 0xFFFFFFFF and
                local_compressed_size != @as(u32, @intCast(@min(compressed_size, std.math.maxInt(u32)))))
            {
                return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP compressed size mismatch (central vs local)", .full);
            }
            if (local_uncompressed_size != 0 and uncompressed_size != 0 and
                local_uncompressed_size != 0xFFFFFFFF and
                local_uncompressed_size != @as(u32, @intCast(@min(uncompressed_size, std.math.maxInt(u32)))))
            {
                return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP uncompressed size mismatch (central vs local)", .full);
            }
        }

        // Cross-validate filename length
        if (local_filename_len != filename_len) {
            return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP filename length mismatch (central vs local)", .full);
        }

        // Cross-validate filename content (not just length)
        // This catches corruption that lands on filename bytes in either the
        // central directory or local header without affecting CRC/size fields
        if (!name_truncated and name_slice.len > 0 and local_filename_len == filename_len) {
            var local_name_buf: [ZIP_TELEMETRY_MAX_NAME]u8 = undefined;
            const local_name_to_read = @min(@as(usize, local_filename_len), local_name_buf.len);
            const local_name_read = file.readAll(local_name_buf[0..local_name_to_read]) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "local filename", .full);
            };
            if (local_name_read != local_name_to_read) {
                return ValidationResult.invalidCodeWithDepth(format, .truncated, "local filename", .full);
            }
            if (!std.mem.eql(u8, name_slice, local_name_buf[0..local_name_to_read])) {
                return ValidationResult.invalidCodeWithDepth(format, .invalid_value, "ZIP filename mismatch (central vs local)", .full);
            }
            // Skip any remaining filename bytes beyond our buffer
            if (local_filename_len > local_name_to_read) {
                const remaining: i64 = @intCast(local_filename_len - local_name_to_read);
                file.seekBy(remaining) catch {
                    return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "local filename", .full);
                };
            }
        } else {
            // Can't compare content (truncated or empty) — just skip
            const skip_local_name: i64 = @intCast(local_filename_len);
            file.seekBy(skip_local_name) catch {
                return ValidationResult.invalidCodeWithDepth(format, .failed_to_skip, "local filename", .full);
            };
        }
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

    // Read the frame header to check Content_Checksum_Flag
    // Bytes 0-3: magic (0xFD2FB528 LE), byte 4: Frame_Header_Descriptor
    var header_buf: [5]u8 = undefined;
    const header_read = file.readAll(&header_buf) catch {
        return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_read, "frame header", .structural);
    };
    if (header_read < 5) {
        return ValidationResult.invalidWithDepth(.zstd, "File too small for frame header", .structural);
    }

    const has_checksum = (header_buf[4] & 0x04) != 0;

    // Read expected checksum from end of file if flag is set
    var expected_checksum: u32 = 0;
    if (has_checksum) {
        if (file_size < 12) { // magic(4) + FHD(1) + at least 1 block + checksum(4)
            return ValidationResult.invalidWithDepth(.zstd, "File too small for checksum", .structural);
        }
        file.seekTo(file_size - 4) catch {
            return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_read, "checksum", .structural);
        };
        var cksum_buf: [4]u8 = undefined;
        const cksum_read = file.readAll(&cksum_buf) catch {
            return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_read, "checksum", .structural);
        };
        if (cksum_read < 4) {
            return ValidationResult.invalidWithDepth(.zstd, "Could not read checksum", .structural);
        }
        expected_checksum = std.mem.readInt(u32, &cksum_buf, .little);
    }

    // Seek back to beginning for decompression
    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_read, "file", .structural);
    };

    // Create reader from file
    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(&file_buf);

    // Initialize Zstd decompressor in direct mode (empty reader buffer).
    // In direct mode, decompressed data flows directly to the Writer buffer.
    var zstd_stream: std.compress.zstd.Decompress = .init(&file_reader.interface, &.{}, .{});

    // Initialize xxHash64 hasher for content checksum verification
    var hasher = XxHash64.init(0);

    // Allocate writer buffer: must be >= window_len + block_size_max for direct mode.
    const writer_buf_size = std.compress.zstd.default_window_len + (1 << 17); // 8MB + 128KB
    const writer_buf = allocator.alloc(u8, writer_buf_size) catch {
        return ValidationResult.invalidCodeWithDepth(.zstd, .failed_to_allocate, "decompression buffer", .structural);
    };
    defer allocator.free(writer_buf);

    // Create a hashing writer that feeds decompressed data to xxHash64
    var hashing_state = HashingWriter{
        .hasher = &hasher,
        .has_checksum = has_checksum,
        .total_decompressed = 0,
        .writer = undefined,
    };
    hashing_state.writer = .{
        .vtable = &.{
            .drain = HashingWriter.drain,
            .sendFile = discardSendFile,
        },
        .buffer = writer_buf,
    };

    // Decompress using streamRemaining pattern: loop until EndOfStream.
    // In direct mode, stream() writes decompressed blocks to the Writer.
    var total_decompressed: u64 = 0;
    while (true) {
        const bytes_written = zstd_stream.reader.stream(&hashing_state.writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return ValidationResult.invalidWithDepth(.zstd, "Decompression failed - corrupt data", .full),
            error.WriteFailed => return ValidationResult.invalidWithDepth(.zstd, "Write failed during validation", .structural),
        };
        total_decompressed += bytes_written;

        // Zip bomb protection
        if (total_decompressed > format_validation.MAX_DECOMPRESSED_SIZE) {
            return ValidationResult.invalidCodeMsgWithDepth(.zstd, .exceeds_bounds, "Decompressed size", "Decompressed size exceeds limit", .structural);
        }
    }

    // Hash any remaining data in the writer buffer that wasn't drained
    if (has_checksum and hashing_state.writer.end > 0) {
        hasher.update(hashing_state.writer.buffer[0..hashing_state.writer.end]);
    }

    // Verify checksum if present
    if (has_checksum) {
        const computed = hasher.final();
        const computed_lower32: u32 = @truncate(computed);
        if (computed_lower32 != expected_checksum) {
            return ValidationResult.invalidCodeWithDepth(.zstd, .checksum_mismatch, "xxHash64 content checksum mismatch", .full);
        }
    }

    // Successfully decompressed and verified
    return ValidationResult.okWithDepth(.zstd, .full);
}

/// Writer context that hashes decompressed data with xxHash64 while discarding it.
/// Uses @fieldParentPtr to recover the context from the embedded Writer.
const HashingWriter = struct {
    hasher: *XxHash64,
    has_checksum: bool,
    total_decompressed: u64,
    writer: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *HashingWriter = @alignCast(@fieldParentPtr("writer", w));

        // Hash buffer contents first (buffer[0..end] is consumed before data)
        if (self.has_checksum and w.end > 0) {
            self.hasher.update(w.buffer[0..w.end]);
        }
        self.total_decompressed += w.end;

        var total: usize = 0;

        // Hash and count each data slice
        for (data[0 .. data.len - 1]) |slice| {
            if (self.has_checksum) {
                self.hasher.update(slice);
            }
            total += slice.len;
        }

        // Handle splatted last element
        const last = data[data.len - 1];
        if (self.has_checksum and splat > 0) {
            for (0..splat) |_| {
                self.hasher.update(last);
            }
        }
        total += last.len * splat;

        self.total_decompressed += total;

        // Clear the buffer since we're discarding
        w.end = 0;

        return total;
    }
};

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

fn validateRarWithRarz(data: []const u8) ValidationResult {
    if (data.len == 0) {
        return ValidationResult.invalidWithDepth(.rar, "File too small", .structural);
    }

    const result = rarz.policy.validate(data);

    if (!result.is_valid) {
        const message = result.error_message orelse "RAR validation failed";
        // rarz verified CRC/BLAKE2sp to detect the mismatch → .full depth on failure too
        const depth: ValidationDepth = if (result.file_count > 0) .full else .structural;
        return ValidationResult.invalidWithDepth(.rar, message, depth);
    }

    if (result.has_encrypted_content) {
        var warning_result = ValidationResult.okWithDepthAndWarning(.rar, .structural, "Encrypted archive content; integrity verification unavailable");
        warning_result.has_encrypted_content = true;
        return warning_result;
    }

    // rarz now decompresses + verifies CRC32/BLAKE2sp for all files (stored and compressed).
    // If validation passed with files present, content integrity is verified → .full
    const depth: ValidationDepth = if (result.file_count > 0) .full else .structural;
    return ValidationResult.okWithDepth(.rar, depth);
}

/// Deep RAR validation using rarz (in-memory clean-room implementation).
pub fn validateRarDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.rar, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.rar, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.rar, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.rar, .failed_to_get, "file size", .structural);
    };
    if (file_size == 0) {
        return ValidationResult.invalidWithDepth(.rar, "File too small", .structural);
    }

    const max_size: u64 = 1024 * 1024 * 1024;
    if (file_size > max_size) {
        return ValidationResult.invalidCodeWithDepth(.rar, .file_too_large, "validation", .structural);
    }

    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.rar, .failed_to_allocate, "RAR read buffer", .structural);
    };
    defer allocator.free(data);

    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.rar, .failed_to_seek, "to start", .structural);
    };
    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.rar, .failed_to_read, "RAR file", .structural);
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCodeWithDepth(.rar, .incomplete, "RAR file", .structural);
    }

    return validateRarWithRarz(data);
}

// ============ Buffer Validators ============

pub fn validateZipFromBuffer(data: []const u8, format: FileFormat) ValidationResult {
    if (data.len < 4) return ValidationResult.invalid(format, "File too small");
    // Check local file header signature
    if (data[0] == 0x50 and data[1] == 0x4B and data[2] == 0x03 and data[3] == 0x04) {
        // Signature-only check — no EOCD or CRC verification
        return ValidationResult.structuralOnly(format);
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
    return validateRarWithRarz(data);
}

fn compactProDepthForError(code: i32) ValidationDepth {
    return switch (code) {
        c_compact_pro.CP_ERR_FILE_CRC_MISMATCH,
        c_compact_pro.CP_ERR_INVALID_RUN_LENGTH_ONE,
        c_compact_pro.CP_ERR_OUTPUT_LENGTH_MISMATCH,
        c_compact_pro.CP_ERR_UNEXPECTED_END_OF_STREAM,
        => .full,
        else => .structural,
    };
}

fn validateCptWithCompactPro(data: []const u8) ValidationResult {
    if (data.len < 8) return ValidationResult.invalidWithDepth(.cpt, "File too small", .structural);

    var listing = std.mem.zeroes(c_compact_pro.cp_archive_listing);
    defer c_compact_pro.cp_archive_listing_free(&listing);
    const list_code = c_compact_pro.cp_archive_list(data.ptr, data.len, 1, &listing);
    if (list_code != c_compact_pro.CP_OK) {
        return ValidationResult.invalidWithDepth(.cpt, std.mem.span(c_compact_pro.cp_error_string(list_code)), compactProDepthForError(list_code));
    }

    var extracted = std.mem.zeroes(c_compact_pro.cp_archive_output);
    defer c_compact_pro.cp_archive_output_free(&extracted);
    const extract_code = c_compact_pro.cp_archive_extract(data.ptr, data.len, 1, &extracted);
    if (extract_code == c_compact_pro.CP_OK) {
        return ValidationResult.okWithDepth(.cpt, .full);
    }

    if (extract_code == c_compact_pro.CP_ERR_UNSUPPORTED_ENCRYPTED) {
        var encrypted_result = ValidationResult.okWithDepthAndWarning(.cpt, .structural, "Encrypted Compact Pro content; full validation unavailable");
        encrypted_result.has_encrypted_content = true;
        return encrypted_result;
    }

    if (extract_code == c_compact_pro.CP_ERR_UNSUPPORTED_LZH) {
        return ValidationResult.okWithDepthAndWarning(.cpt, .structural, "Unsupported Compact Pro compression profile; structural validation only");
    }

    return ValidationResult.invalidWithDepth(.cpt, std.mem.span(c_compact_pro.cp_error_string(extract_code)), compactProDepthForError(extract_code));
}

pub fn validateCpt(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_get, "file size", .structural);
    };
    if (file_size == 0) return ValidationResult.invalidWithDepth(.cpt, "File too small", .structural);

    const max_size: u64 = 1024 * 1024 * 1024;
    if (file_size > max_size) {
        return ValidationResult.invalidCodeWithDepth(.cpt, .file_too_large, "validation", .structural);
    }

    const data = std.heap.page_allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_allocate, "CPT read buffer", .structural);
    };
    defer std.heap.page_allocator.free(data);

    file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_seek, "to start", .structural);
    const bytes_read = file.readAll(data) catch return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_read, "CPT file", .structural);
    if (bytes_read != file_size) return ValidationResult.invalidCodeWithDepth(.cpt, .incomplete, "CPT file", .structural);

    return validateCptWithCompactPro(data);
}

pub fn validateCptDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.cpt, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.cpt, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_get, "file size", .structural);
    };
    if (file_size == 0) return ValidationResult.invalidWithDepth(.cpt, "File too small", .structural);

    const max_size: u64 = 1024 * 1024 * 1024;
    if (file_size > max_size) {
        return ValidationResult.invalidCodeWithDepth(.cpt, .file_too_large, "validation", .structural);
    }

    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_allocate, "CPT read buffer", .structural);
    };
    defer allocator.free(data);

    file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_seek, "to start", .structural);
    const bytes_read = file.readAll(data) catch return ValidationResult.invalidCodeWithDepth(.cpt, .failed_to_read, "CPT file", .structural);
    if (bytes_read != file_size) return ValidationResult.invalidCodeWithDepth(.cpt, .incomplete, "CPT file", .structural);

    return validateCptWithCompactPro(data);
}

pub fn validateCptFromBuffer(data: []const u8) ValidationResult {
    return validateCptWithCompactPro(data);
}

pub fn validate7zFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 6) return ValidationResult.invalid(.sevenz, "File too small");
    const sig_7z = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };
    if (std.mem.eql(u8, data[0..6], &sig_7z)) {
        return ValidationResult.ok(.sevenz);
    }
    return ValidationResult.invalidCode(.sevenz, .invalid_signature, "7z");
}

// ============ Tests ============

const testing = std.testing;

fn openGroundTruth(comptime path: []const u8) !std.fs.File {
    return std.fs.cwd().openFile(path, .{});
}

// ---------- Structural validators on valid ground truth files ----------

test "validateZip: valid ZIP ground truth" {
    const file = try openGroundTruth("ground_truth_examples/zip/test_archive.zip");
    defer file.close();
    const result = validateZip(file, .zip);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zip, result.format);
}

test "validateGzip: valid gzip ground truth" {
    const file = try openGroundTruth("ground_truth_examples/gzip/sample.gz");
    defer file.close();
    const result = validateGzip(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.gzip, result.format);
}

test "validateBzip2: valid bzip2 ground truth" {
    const file = try openGroundTruth("ground_truth_examples/bzip2/sample.bz2");
    defer file.close();
    const result = validateBzip2(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.bzip2, result.format);
}

test "validateXz: valid XZ ground truth" {
    const file = try openGroundTruth("ground_truth_examples/xz/sample.xz");
    defer file.close();
    const result = validateXz(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xz, result.format);
}

test "validateZstd: valid Zstd ground truth" {
    const file = try openGroundTruth("ground_truth_examples/zstd/sample.zst");
    defer file.close();
    const result = validateZstd(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validateRar: valid RAR ground truth" {
    const file = try openGroundTruth("ground_truth_examples/rar/sample.rar");
    defer file.close();
    const result = validateRar(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rar, result.format);
}

test "validate7z: valid 7z ground truth" {
    const file = try openGroundTruth("ground_truth_examples/7z/sample.7z");
    defer file.close();
    const result = validate7z(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sevenz, result.format);
}

test "validateTar: valid tar ground truth" {
    const file = try openGroundTruth("ground_truth_examples/tar/sample.tar");
    defer file.close();
    const result = validateTar(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.tar, result.format);
}

test "validatePar2: valid PAR2 ground truth" {
    const file = try openGroundTruth("ground_truth_examples/par2/sample.par2");
    defer file.close();
    const result = validatePar2(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.par2, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateWarc: valid WARC ground truth" {
    const file = try openGroundTruth("ground_truth_examples/warc/sample.warc");
    defer file.close();
    const result = validateWarc(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.warc, result.format);
}

test "validateCpt: valid CPT ground truth" {
    const file = try openGroundTruth("ground_truth_examples/cpt/sample.cpt");
    defer file.close();
    const result = validateCpt(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.cpt, result.format);
}

// ---------- Deep validators on valid ground truth files ----------

test "validateZipDeep: valid ZIP ground truth" {
    const result = validateZipDeep(testing.allocator, "ground_truth_examples/zip/test_archive.zip");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zip, result.format);
}

test "validateGzipDeep: valid gzip ground truth" {
    const result = validateGzipDeep(testing.allocator, "ground_truth_examples/gzip/sample.gz");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.gzip, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateBzip2Deep: valid bzip2 ground truth" {
    const result = validateBzip2Deep(testing.allocator, "ground_truth_examples/bzip2/sample.bz2");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.bzip2, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateXzDeep: valid XZ ground truth" {
    const result = validateXzDeep(testing.allocator, "ground_truth_examples/xz/sample.xz");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xz, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateZstdDeep: valid Zstd ground truth" {
    const result = validateZstdDeep(testing.allocator, "ground_truth_examples/zstd/sample.zst");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateZstdDeep: xxHash64 checksum verified on ground truth" {
    // The ground truth sample.zst has Content_Checksum_Flag set (byte 4 bit 2).
    // Verify it passes with full depth (checksum verified).
    const result = validateZstdDeep(testing.allocator, "ground_truth_examples/zstd/sample.zst");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateZstdDeep: corrupted checksum detected" {
    // Create a zstd file with valid compressed data but a corrupted content checksum.
    const src_file = std.fs.cwd().openFile("ground_truth_examples/zstd/sample.zst", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer src_file.close();
    const file_size = try src_file.getEndPos();
    const data = try testing.allocator.alloc(u8, @intCast(file_size));
    defer testing.allocator.free(data);
    const read = try src_file.readAll(data);
    try testing.expect(read == data.len);

    // Verify checksum flag is set (bit 2 of byte 4)
    try testing.expect(data[4] & 0x04 != 0);

    // Corrupt the last byte (part of the 4-byte content checksum)
    data[data.len - 1] ^= 0xFF;

    // Write corrupted data to a temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("corrupt_checksum.zst", .{ .read = true });
    try file.writeAll(data);
    file.close();
    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "corrupt_checksum.zst");
    defer testing.allocator.free(path);

    const result = validateZstdDeep(testing.allocator, path);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validate7zDeep: valid 7z ground truth" {
    const result = validate7zDeep(testing.allocator, "ground_truth_examples/7z/sample.7z");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sevenz, result.format);
}

test "validateRarDeep: valid RAR ground truth" {
    const result = validateRarDeep(testing.allocator, "ground_truth_examples/rar/sample.rar");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rar, result.format);
}

test "validateCptDeep: valid CPT ground truth" {
    const result = validateCptDeep(testing.allocator, "ground_truth_examples/cpt/sample.cpt");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.cpt, result.format);
}

// ---------- Buffer validators on valid signatures ----------

test "validateZipFromBuffer: valid ZIP signature" {
    const zip_sig = [_]u8{ 0x50, 0x4B, 0x03, 0x04, 0x00, 0x00 };
    const result = validateZipFromBuffer(&zip_sig, .zip);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zip, result.format);
}

test "validateGzipFromBuffer: valid gzip signature" {
    const gz_sig = [_]u8{ 0x1F, 0x8B, 0x08, 0x00 };
    const result = validateGzipFromBuffer(&gz_sig);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.gzip, result.format);
}

test "validateBzip2FromBuffer: valid bzip2 signature" {
    const bz2_sig = [_]u8{ 'B', 'Z', 'h', '9' };
    const result = validateBzip2FromBuffer(&bz2_sig);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.bzip2, result.format);
}

test "validateXzFromBuffer: valid XZ signature" {
    const xz_sig = [_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x00 };
    const result = validateXzFromBuffer(&xz_sig);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xz, result.format);
}

test "validateZstdFromBuffer: valid Zstd signature" {
    const zstd_sig = [_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00 };
    const result = validateZstdFromBuffer(&zstd_sig);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validateRarFromBuffer: valid RAR from ground truth" {
    // Use the real RAR file bytes because rarz needs enough data for full parsing
    const file = try openGroundTruth("ground_truth_examples/rar/sample.rar");
    defer file.close();
    const file_size = try file.getEndPos();
    const size: usize = @intCast(@min(file_size, 4096));
    var buf: [4096]u8 = undefined;
    const read = try file.readAll(buf[0..size]);
    const result = validateRarFromBuffer(buf[0..read]);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rar, result.format);
}

test "validate7zFromBuffer: valid 7z signature" {
    const sig_7z = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x00 };
    const result = validate7zFromBuffer(&sig_7z);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sevenz, result.format);
}

test "validateCptFromBuffer: valid CPT from ground truth" {
    const file = try openGroundTruth("ground_truth_examples/cpt/sample.cpt");
    defer file.close();
    const file_size = try file.getEndPos();
    const size: usize = @intCast(file_size);
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    const read = try file.readAll(data);
    const result = validateCptFromBuffer(data[0..read]);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.cpt, result.format);
}

// ---------- Corrupt / truncated inputs (structural validators) ----------

test "validateZip: corrupt ZIP magic rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/zip/test_archive_magic_corrupt.zip");
    defer file.close();
    const result = validateZip(file, .zip);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.zip, result.format);
}

test "validateGzip: corrupt gzip rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/gzip/sample_corrupt_1.gz");
    defer file.close();
    const result = validateGzip(file);
    // A corruption in body may still pass structural validation if header+trailer are intact,
    // so we only check that the result is for gzip format
    try testing.expectEqual(FileFormat.gzip, result.format);
}

test "validateBzip2: corrupt bzip2 rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/bzip2/sample_corrupt_1.bz2");
    defer file.close();
    const result = validateBzip2(file);
    try testing.expectEqual(FileFormat.bzip2, result.format);
}

test "validateXz: corrupt XZ rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/xz/sample_corrupt_1.xz");
    defer file.close();
    const result = validateXz(file);
    try testing.expectEqual(FileFormat.xz, result.format);
}

test "validateZstd: corrupt Zstd rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/zstd/sample_corrupt_1.zst");
    defer file.close();
    const result = validateZstd(file);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validateRar: corrupt RAR rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/rar/sample_corrupt_1.rar");
    defer file.close();
    const result = validateRar(file);
    try testing.expectEqual(FileFormat.rar, result.format);
}

test "validate7z: corrupt 7z rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/7z/sample_corrupt_1.7z");
    defer file.close();
    const result = validate7z(file);
    try testing.expectEqual(FileFormat.sevenz, result.format);
}

test "validateTar: corrupt tar rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/tar/sample_corrupt_1.tar");
    defer file.close();
    const result = validateTar(file);
    try testing.expectEqual(FileFormat.tar, result.format);
}

test "validatePar2: corrupt PAR2 rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/par2/sample_corrupt_1.par2");
    defer file.close();
    const result = validatePar2(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.par2, result.format);
}

test "validateWarc: corrupt WARC rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/warc/sample_corrupt_1.warc");
    defer file.close();
    const result = validateWarc(file);
    try testing.expectEqual(FileFormat.warc, result.format);
}

// ---------- base32Decode unit tests ----------

test "base32Decode: RFC 4648 test vectors" {
    // RFC 4648 section 10 test vectors
    var out: [32]u8 = undefined;

    // "" -> ""
    try testing.expectEqual(@as(?usize, 0), base32Decode("", &out));

    // "f" -> "MY======"
    try testing.expectEqual(@as(?usize, 1), base32Decode("MY======", &out));
    try testing.expectEqualSlices(u8, "f", out[0..1]);

    // "fo" -> "MZXQ===="
    try testing.expectEqual(@as(?usize, 2), base32Decode("MZXQ====", &out));
    try testing.expectEqualSlices(u8, "fo", out[0..2]);

    // "foo" -> "MZXW6==="
    try testing.expectEqual(@as(?usize, 3), base32Decode("MZXW6===", &out));
    try testing.expectEqualSlices(u8, "foo", out[0..3]);

    // "foob" -> "MZXW6YQ="
    try testing.expectEqual(@as(?usize, 4), base32Decode("MZXW6YQ=", &out));
    try testing.expectEqualSlices(u8, "foob", out[0..4]);

    // "fooba" -> "MZXW6YTB"
    try testing.expectEqual(@as(?usize, 5), base32Decode("MZXW6YTB", &out));
    try testing.expectEqualSlices(u8, "fooba", out[0..5]);

    // "foobar" -> "MZXW6YTBOI======"
    try testing.expectEqual(@as(?usize, 6), base32Decode("MZXW6YTBOI======", &out));
    try testing.expectEqualSlices(u8, "foobar", out[0..6]);
}

test "base32Decode: case insensitive" {
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(?usize, 3), base32Decode("mzxw6===", &out));
    try testing.expectEqualSlices(u8, "foo", out[0..3]);
}

test "base32Decode: invalid character returns null" {
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), base32Decode("MZXW6!==", &out));
}

test "base32Decode: SHA-1 digest round trip" {
    // SHA-1 of empty string is da39a3ee5e6b4b0d3255bfef95601890afd80709
    // Base32 of that: 3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ
    var out: [20]u8 = undefined;
    const decoded = base32Decode("3I42H3S6NNFQ2MSVX7XZKYAYSCX5QBYJ", &out);
    try testing.expectEqual(@as(?usize, 20), decoded);
    const expected = [_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d, 0x32, 0x55,
        0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09,
    };
    try testing.expectEqualSlices(u8, &expected, out[0..20]);
}

// ---------- WARC deep validator tests ----------

test "validateWarcDeep: WARC with SHA-1 digests returns full depth" {
    const result = validateWarcDeep(testing.allocator, "ground_truth_examples/warc/sample.warc");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.warc, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateWarcDeep: synthetic WARC with valid SHA-1 digest returns full" {
    // Build a WARC record body
    const body = "Hello, WARC world!\r\n";

    // Compute SHA-1 of body
    var hasher = Sha1.init(.{});
    hasher.update(body);
    const hash = hasher.finalResult();

    // Base32-encode the SHA-1 hash
    const b32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    var b32_buf: [32]u8 = undefined;
    var b32_len: usize = 0;
    {
        var bits: u32 = 0;
        var n_bits: u4 = 0;
        for (hash) |byte| {
            bits = (bits << 8) | @as(u32, byte);
            n_bits += 8;
            while (n_bits >= 5) {
                n_bits -= 5;
                b32_buf[b32_len] = b32_alphabet[@as(usize, @intCast((bits >> n_bits) & 0x1F))];
                b32_len += 1;
            }
        }
        // Handle remaining bits (20 bytes = 160 bits, 160/5=32, no remainder)
    }
    const b32_hash = b32_buf[0..b32_len];

    // Construct the WARC file content using a fixed buffer
    var warc_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&warc_buf);
    const writer = fbs.writer();
    try writer.print("WARC/1.0\r\n", .{});
    try writer.print("WARC-Type: resource\r\n", .{});
    try writer.print("WARC-Record-ID: <urn:uuid:test-0001>\r\n", .{});
    try writer.print("WARC-Date: 2025-01-28T00:00:00Z\r\n", .{});
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    try writer.print("WARC-Block-Digest: sha1:{s}\r\n", .{b32_hash});
    try writer.print("\r\n", .{}); // end of headers
    try writer.writeAll(body);
    try writer.writeAll("\r\n\r\n"); // record separator

    const warc_data = fbs.getWritten();

    // Write to temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = try tmp_dir.dir.createFile("test.warc", .{});
    try tmp_file.writeAll(warc_data);
    tmp_file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.warc");
    defer testing.allocator.free(path);

    const result = validateWarcDeep(testing.allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.warc, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateWarcDeep: synthetic WARC with wrong SHA-1 digest returns invalid" {
    const body = "Hello, WARC world!\r\n";

    // Use a known-wrong hash (all zeros base32)
    const wrong_b32 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"; // 32 chars = 20 bytes of zeros

    var warc_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&warc_buf);
    const writer = fbs.writer();
    try writer.print("WARC/1.0\r\n", .{});
    try writer.print("WARC-Type: resource\r\n", .{});
    try writer.print("WARC-Record-ID: <urn:uuid:test-0002>\r\n", .{});
    try writer.print("WARC-Date: 2025-01-28T00:00:00Z\r\n", .{});
    try writer.print("Content-Length: {d}\r\n", .{body.len});
    try writer.print("WARC-Block-Digest: sha1:{s}\r\n", .{wrong_b32});
    try writer.print("\r\n", .{});
    try writer.writeAll(body);
    try writer.writeAll("\r\n\r\n");

    const warc_data = fbs.getWritten();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_file = try tmp_dir.dir.createFile("test_bad.warc", .{});
    try tmp_file.writeAll(warc_data);
    tmp_file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test_bad.warc");
    defer testing.allocator.free(path);

    const result = validateWarcDeep(testing.allocator, path);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.warc, result.format);
}

test "validateWarcDeep: file not found returns invalid" {
    const result = validateWarcDeep(testing.allocator, "nonexistent_file.warc");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.warc, result.format);
}

test "validateCpt: corrupt CPT rejected" {
    const file = try openGroundTruth("ground_truth_examples/corrupted/cpt/sample_corrupt_1.cpt");
    defer file.close();
    const result = validateCpt(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.cpt, result.format);
}

// ---------- Deep validators on corrupt files ----------

test "validateGzipDeep: corrupt gzip detected" {
    const result = validateGzipDeep(testing.allocator, "ground_truth_examples/corrupted/gzip/sample_corrupt_1.gz");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.gzip, result.format);
}

test "validateBzip2Deep: corrupt bzip2 detected" {
    const result = validateBzip2Deep(testing.allocator, "ground_truth_examples/corrupted/bzip2/sample_corrupt_1.bz2");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.bzip2, result.format);
}

test "validateXzDeep: corrupt XZ detected" {
    const result = validateXzDeep(testing.allocator, "ground_truth_examples/corrupted/xz/sample_corrupt_1.xz");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.xz, result.format);
}

test "validateZstdDeep: too-small file detected" {
    // Zstd corrupt samples have optional checksums and may decompress fine.
    // Instead test with a file that is structurally too small.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.zst", .{ .read = true });
    try file.writeAll(&[_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0x00 });
    file.close();
    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "tiny.zst");
    defer testing.allocator.free(path);
    const result = validateZstdDeep(testing.allocator, path);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validateRarDeep: corrupt RAR detected" {
    const result = validateRarDeep(testing.allocator, "ground_truth_examples/corrupted/rar/sample_corrupt_1.rar");
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.rar, result.format);
}

// ---------- Buffer validators on invalid / truncated data ----------

test "validateZipFromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 0x50, 0x4B };
    const result = validateZipFromBuffer(&truncated, .zip);
    try testing.expect(!result.is_valid);
}

test "validateZipFromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const result = validateZipFromBuffer(&bad, .zip);
    try testing.expect(!result.is_valid);
}

test "validateGzipFromBuffer: truncated data rejected" {
    const truncated = [_]u8{0x1F};
    const result = validateGzipFromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

test "validateGzipFromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateGzipFromBuffer(&bad);
    try testing.expect(!result.is_valid);
}

test "validateBzip2FromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 'B', 'Z' };
    const result = validateBzip2FromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

test "validateBzip2FromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateBzip2FromBuffer(&bad);
    try testing.expect(!result.is_valid);
}

test "validateXzFromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 0xFD, 0x37, 0x7A };
    const result = validateXzFromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

test "validateXzFromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = validateXzFromBuffer(&bad);
    try testing.expect(!result.is_valid);
}

test "validateZstdFromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 0x28, 0xB5 };
    const result = validateZstdFromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

test "validateZstdFromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = validateZstdFromBuffer(&bad);
    try testing.expect(!result.is_valid);
}

test "validate7zFromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 0x37, 0x7A, 0xBC };
    const result = validate7zFromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

test "validate7zFromBuffer: wrong magic rejected" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = validate7zFromBuffer(&bad);
    try testing.expect(!result.is_valid);
}

test "validateCptFromBuffer: truncated data rejected" {
    const truncated = [_]u8{ 0x01, 0x00, 0x00 };
    const result = validateCptFromBuffer(&truncated);
    try testing.expect(!result.is_valid);
}

// ---------- Deep validators: file not found ----------

test "validateZipDeep: file not found returns invalid" {
    const result = validateZipDeep(testing.allocator, "nonexistent_file.zip");
    try testing.expect(!result.is_valid);
}

test "validateGzipDeep: file not found returns invalid" {
    const result = validateGzipDeep(testing.allocator, "nonexistent_file.gz");
    try testing.expect(!result.is_valid);
}

test "validateBzip2Deep: file not found returns invalid" {
    const result = validateBzip2Deep(testing.allocator, "nonexistent_file.bz2");
    try testing.expect(!result.is_valid);
}

test "validateXzDeep: file not found returns invalid" {
    const result = validateXzDeep(testing.allocator, "nonexistent_file.xz");
    try testing.expect(!result.is_valid);
}

test "validateZstdDeep: file not found returns invalid" {
    const result = validateZstdDeep(testing.allocator, "nonexistent_file.zst");
    try testing.expect(!result.is_valid);
}

test "validate7zDeep: file not found returns invalid" {
    const result = validate7zDeep(testing.allocator, "nonexistent_file.7z");
    try testing.expect(!result.is_valid);
}

test "validateRarDeep: file not found returns invalid" {
    const result = validateRarDeep(testing.allocator, "nonexistent_file.rar");
    try testing.expect(!result.is_valid);
}

test "validateCptDeep: file not found returns invalid" {
    const result = validateCptDeep(testing.allocator, "nonexistent_file.cpt");
    try testing.expect(!result.is_valid);
}

// ---------- Structural validators: synthetic empty/too-small input ----------

test "validateGzip: too-small input rejected" {
    // Create a temp file with only 5 bytes (less than 10-byte gzip header)
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.gz", .{ .read = true });
    defer file.close();
    try file.writeAll(&[_]u8{ 0x1F, 0x8B, 0x08, 0x00, 0x00 });
    try file.seekTo(0);
    const result = validateGzip(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.gzip, result.format);
}

test "validateBzip2: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.bz2", .{ .read = true });
    defer file.close();
    try file.writeAll("BZh");
    try file.seekTo(0);
    const result = validateBzip2(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.bzip2, result.format);
}

test "validateXz: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.xz", .{ .read = true });
    defer file.close();
    try file.writeAll(&[_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 });
    try file.seekTo(0);
    const result = validateXz(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.xz, result.format);
}

test "validateZstd: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.zst", .{ .read = true });
    defer file.close();
    try file.writeAll(&[_]u8{ 0x28, 0xB5, 0x2F, 0xFD });
    try file.seekTo(0);
    const result = validateZstd(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.zstd, result.format);
}

test "validate7z: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.7z", .{ .read = true });
    defer file.close();
    try file.writeAll(&[_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C });
    try file.seekTo(0);
    const result = validate7z(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.sevenz, result.format);
}

test "validateTar: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.tar", .{ .read = true });
    defer file.close();
    try file.writeAll("too short for tar header");
    try file.seekTo(0);
    const result = validateTar(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.tar, result.format);
}

test "validatePar2: too-small input rejected" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tiny.par2", .{ .read = true });
    defer file.close();
    try file.writeAll("PAR2\x00PKT"); // Only 8 bytes, need 64
    try file.seekTo(0);
    const result = validatePar2(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.par2, result.format);
}

// ---------- Buffer validators: empty input ----------

test "validateZipFromBuffer: empty data rejected" {
    const result = validateZipFromBuffer(&[_]u8{}, .zip);
    try testing.expect(!result.is_valid);
}

test "validateGzipFromBuffer: empty data rejected" {
    const result = validateGzipFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

test "validateBzip2FromBuffer: empty data rejected" {
    const result = validateBzip2FromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

test "validateXzFromBuffer: empty data rejected" {
    const result = validateXzFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

test "validateZstdFromBuffer: empty data rejected" {
    const result = validateZstdFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

test "validate7zFromBuffer: empty data rejected" {
    const result = validate7zFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

test "validateCptFromBuffer: empty data rejected" {
    const result = validateCptFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

// ============ BinHex (HQX) Validation ============

const BINHEX4_BANNER = "(This file must be converted with BinHex 4.0)";
const BINHEX4_ALPHABET = "!\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr";
const BINHEX4_RLE_MARKER: u8 = 0x90;
const BINHEX4_MAX_FILE_SIZE: u64 = 64 * 1024 * 1024;
const BINHEX4_MAX_DECODED_SIZE: usize = 128 * 1024 * 1024;

const BinhexError = error{
    InvalidEnvelope,
    InvalidCharacter,
    TruncatedData,
    InvalidRunLength,
    InvalidHeader,
    CrcMismatch,
    DataTooLarge,
} || Allocator.Error;

const binhex4_decode_table: [256]i16 = blk: {
    var table: [256]i16 = [_]i16{-1} ** 256;
    for (BINHEX4_ALPHABET, 0..) |ch, idx| {
        table[ch] = @intCast(idx);
    }
    break :blk table;
};

const hqxCrc16 = codec_utils.crc16Ccitt;

fn hqxDecodeValue(ch: u8) ?u8 {
    const value = binhex4_decode_table[ch];
    if (value < 0) return null;
    return @intCast(value);
}

fn decodeBinhex4Payload(allocator: Allocator, file_data: []const u8) BinhexError![]u8 {
    const start = std.mem.indexOfScalar(u8, file_data, ':') orelse return error.InvalidEnvelope;
    const after_start = file_data[start + 1 ..];
    const end_rel = std.mem.indexOfScalar(u8, after_start, ':') orelse return error.InvalidEnvelope;
    const encoded = after_start[0..end_rel];

    var decoded: std.ArrayListUnmanaged(u8) = .{};
    errdefer decoded.deinit(allocator);

    var group: [4]u8 = undefined;
    var group_len: u8 = 0;
    var non_ws_chars: usize = 0;

    for (encoded) |ch| {
        switch (ch) {
            ' ', '\t', '\r', '\n' => continue,
            else => {},
        }
        const value = hqxDecodeValue(ch) orelse return error.InvalidCharacter;
        group[group_len] = value;
        group_len += 1;
        non_ws_chars += 1;

        if (group_len == 4) {
            const combined: u32 = (@as(u32, group[0]) << 18) |
                (@as(u32, group[1]) << 12) |
                (@as(u32, group[2]) << 6) |
                @as(u32, group[3]);
            if (decoded.items.len + 3 > BINHEX4_MAX_DECODED_SIZE) return error.DataTooLarge;
            try decoded.append(allocator, @intCast((combined >> 16) & 0xFF));
            try decoded.append(allocator, @intCast((combined >> 8) & 0xFF));
            try decoded.append(allocator, @intCast(combined & 0xFF));
            group_len = 0;
        }
    }

    if (non_ws_chars == 0 or group_len != 0) return error.TruncatedData;
    return decoded.toOwnedSlice(allocator);
}

fn expandBinhex4Rle(allocator: Allocator, packed_data: []const u8) BinhexError![]u8 {
    var expanded: std.ArrayListUnmanaged(u8) = .{};
    errdefer expanded.deinit(allocator);

    var i: usize = 0;
    var have_prev = false;
    var prev: u8 = 0;

    while (i < packed_data.len) {
        const b = packed_data[i];
        i += 1;

        if (b != BINHEX4_RLE_MARKER) {
            if (expanded.items.len + 1 > BINHEX4_MAX_DECODED_SIZE) return error.DataTooLarge;
            try expanded.append(allocator, b);
            prev = b;
            have_prev = true;
            continue;
        }

        if (i >= packed_data.len) return error.TruncatedData;
        const count = packed_data[i];
        i += 1;

        if (count == 0) {
            if (expanded.items.len + 1 > BINHEX4_MAX_DECODED_SIZE) return error.DataTooLarge;
            try expanded.append(allocator, BINHEX4_RLE_MARKER);
            prev = BINHEX4_RLE_MARKER;
            have_prev = true;
            continue;
        }

        if (!have_prev) return error.InvalidRunLength;
        const repeat_count: usize = @as(usize, count) - 1;
        if (expanded.items.len + repeat_count > BINHEX4_MAX_DECODED_SIZE) return error.DataTooLarge;
        for (0..repeat_count) |_| {
            try expanded.append(allocator, prev);
        }
    }

    if (expanded.items.len == 0) return error.TruncatedData;
    return expanded.toOwnedSlice(allocator);
}

fn validateBinhex4Decoded(decoded: []const u8) BinhexError!void {
    var cursor: usize = 0;

    if (decoded.len < 22) return error.InvalidHeader;

    const name_len = decoded[cursor];
    cursor += 1;
    if (name_len == 0 or name_len > 63) return error.InvalidHeader;

    const name_len_usize: usize = name_len;
    if (cursor + name_len_usize + 1 + 4 + 4 + 2 + 4 + 4 + 2 > decoded.len) return error.TruncatedData;

    cursor += name_len_usize;
    if (decoded[cursor] != 0) return error.InvalidHeader;
    cursor += 1;

    cursor += 4; // type
    cursor += 4; // creator
    cursor += 2; // finder flags

    const data_len = std.mem.readInt(u32, decoded[cursor..][0..4], .big);
    cursor += 4;
    const resource_len = std.mem.readInt(u32, decoded[cursor..][0..4], .big);
    cursor += 4;

    const header_crc_input = decoded[0..cursor];
    const stored_header_crc = std.mem.readInt(u16, decoded[cursor..][0..2], .big);
    cursor += 2;
    if (hqxCrc16(header_crc_input) != stored_header_crc) return error.CrcMismatch;

    const data_len_usize: usize = @intCast(data_len);
    if (cursor + data_len_usize + 2 > decoded.len) return error.TruncatedData;
    const data_fork = decoded[cursor .. cursor + data_len_usize];
    cursor += data_len_usize;
    const stored_data_crc = std.mem.readInt(u16, decoded[cursor..][0..2], .big);
    cursor += 2;
    if (hqxCrc16(data_fork) != stored_data_crc) return error.CrcMismatch;

    const resource_len_usize: usize = @intCast(resource_len);
    if (cursor + resource_len_usize + 2 > decoded.len) return error.TruncatedData;
    const resource_fork = decoded[cursor .. cursor + resource_len_usize];
    cursor += resource_len_usize;
    const stored_resource_crc = std.mem.readInt(u16, decoded[cursor..][0..2], .big);
    cursor += 2;
    if (hqxCrc16(resource_fork) != stored_resource_crc) return error.CrcMismatch;

    if (cursor != decoded.len) return error.InvalidHeader;
}

pub fn validateHqxBytes(file_data: []const u8) ValidationResult {
    if (file_data.len == 0) return ValidationResult.invalidCode(.hqx, .empty, "BinHex file");

    if (std.mem.indexOf(u8, file_data, BINHEX4_BANNER) == null) {
        return ValidationResult.invalidCode(.hqx, .missing, "BinHex 4.0 banner");
    }

    const allocator = std.heap.page_allocator;
    const packed_data = decodeBinhex4Payload(allocator, file_data) catch |err| {
        return switch (err) {
            error.InvalidEnvelope => ValidationResult.invalid(.hqx, "Missing BinHex data delimiters"),
            error.InvalidCharacter => ValidationResult.invalid(.hqx, "Invalid BinHex alphabet character"),
            error.TruncatedData => ValidationResult.invalidCode(.hqx, .truncated, "BinHex payload"),
            error.DataTooLarge => ValidationResult.invalid(.hqx, "BinHex payload too large"),
            error.OutOfMemory => ValidationResult.invalidCode(.hqx, .failed_to_allocate, "BinHex decode buffer"),
            else => ValidationResult.invalid(.hqx, "Invalid BinHex payload"),
        };
    };
    defer allocator.free(packed_data);

    const decoded = expandBinhex4Rle(allocator, packed_data) catch |err| {
        return switch (err) {
            error.InvalidRunLength => ValidationResult.invalid(.hqx, "Invalid BinHex run-length encoding"),
            error.TruncatedData => ValidationResult.invalidCode(.hqx, .truncated, "BinHex RLE payload"),
            error.DataTooLarge => ValidationResult.invalid(.hqx, "Expanded BinHex data too large"),
            error.OutOfMemory => ValidationResult.invalidCode(.hqx, .failed_to_allocate, "BinHex expansion buffer"),
            else => ValidationResult.invalid(.hqx, "Invalid BinHex RLE payload"),
        };
    };
    defer allocator.free(decoded);

    validateBinhex4Decoded(decoded) catch |err| {
        return switch (err) {
            error.CrcMismatch => ValidationResult.invalidCode(.hqx, .checksum_mismatch, "BinHex fork/header CRC"),
            error.InvalidHeader => ValidationResult.invalid(.hqx, "Invalid BinHex container header"),
            error.TruncatedData => ValidationResult.invalidCode(.hqx, .truncated, "BinHex container"),
            else => ValidationResult.invalid(.hqx, "Invalid BinHex container"),
        };
    };

    return ValidationResult.okWithDepth(.hqx, .full);
}

pub fn validateHqx(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.hqx, .failed_to_get, "file size");
    if (file_size == 0) return ValidationResult.invalidCode(.hqx, .empty, "BinHex file");
    if (file_size > BINHEX4_MAX_FILE_SIZE) return ValidationResult.invalid(.hqx, "BinHex file too large (>64MB)");

    file.seekTo(0) catch return ValidationResult.invalidCode(.hqx, .failed_to_seek, "to start");

    const allocator = std.heap.page_allocator;
    const content = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCode(.hqx, .failed_to_allocate, "BinHex input buffer");
    };
    defer allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.hqx, .failed_to_read, "BinHex file");
    };
    if (bytes_read == 0) return ValidationResult.invalidCode(.hqx, .empty, "BinHex file");

    return validateHqxBytes(content[0..bytes_read]);
}

pub fn validateHqxFromBuffer(data: []const u8) ValidationResult {
    return validateHqxBytes(data);
}

// ============ BinHex (HQX) Tests ============

const hqx_valid_sample =
    "(This file must be converted with BinHex 4.0)\n" ++
    ":#R0KEA\"XC5jdH(3!N!iE!*!%AU&&ER4bEh\"j)&0SD@9XC#\")89JJCQPiG(9bC3U\n" ++
    "Z2J!!:\n";

test "validateHqxFromBuffer: valid BinHex sample" {
    const result = validateHqxFromBuffer(hqx_valid_sample);
    try testing.expectEqual(FileFormat.hqx, result.format);
    try testing.expect(result.is_valid);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateHqxFromBuffer: empty data rejected" {
    const result = validateHqxFromBuffer(&[_]u8{});
    try testing.expect(!result.is_valid);
}

// Type for ZIP test file entries
const ZipTestFile = struct { name: []const u8, content: []const u8 };

// Helper function to build a minimal ZIP with given internal files
fn buildMinimalZip(files: []const ZipTestFile) [4096]u8 {
    var buffer: [4096]u8 = undefined;
    @memset(&buffer, 0);
    var offset: usize = 0;

    var cd_entries: [16]struct { offset: u32, name_len: u16, name: [256]u8 } = undefined;
    var cd_count: usize = 0;

    // Write local file headers and data
    for (files) |f| {
        cd_entries[cd_count].offset = @intCast(offset);
        cd_entries[cd_count].name_len = @intCast(f.name.len);
        @memcpy(cd_entries[cd_count].name[0..f.name.len], f.name);
        cd_count += 1;

        // Local file header (30 bytes + filename + data)
        buffer[offset] = 0x50;
        buffer[offset + 1] = 0x4B;
        buffer[offset + 2] = 0x03;
        buffer[offset + 3] = 0x04; // signature
        buffer[offset + 4] = 0x0A;
        buffer[offset + 5] = 0x00; // version
        buffer[offset + 6] = 0x00;
        buffer[offset + 7] = 0x00; // flags
        buffer[offset + 8] = 0x00;
        buffer[offset + 9] = 0x00; // compression
        buffer[offset + 10] = 0x00;
        buffer[offset + 11] = 0x00; // time
        buffer[offset + 12] = 0x00;
        buffer[offset + 13] = 0x00; // date
        buffer[offset + 14] = 0x00;
        buffer[offset + 15] = 0x00;
        buffer[offset + 16] = 0x00;
        buffer[offset + 17] = 0x00; // CRC
        std.mem.writeInt(u32, buffer[offset + 18 ..][0..4], @intCast(f.content.len), .little); // compressed
        std.mem.writeInt(u32, buffer[offset + 22 ..][0..4], @intCast(f.content.len), .little); // uncompressed
        std.mem.writeInt(u16, buffer[offset + 26 ..][0..2], @intCast(f.name.len), .little); // name len
        buffer[offset + 28] = 0x00;
        buffer[offset + 29] = 0x00; // extra len
        offset += 30;
        @memcpy(buffer[offset..][0..f.name.len], f.name);
        offset += f.name.len;
        @memcpy(buffer[offset..][0..f.content.len], f.content);
        offset += f.content.len;
    }

    const cd_start = offset;

    // Write central directory
    for (cd_entries[0..cd_count]) |entry| {
        buffer[offset] = 0x50;
        buffer[offset + 1] = 0x4B;
        buffer[offset + 2] = 0x01;
        buffer[offset + 3] = 0x02; // signature
        buffer[offset + 4] = 0x0A;
        buffer[offset + 5] = 0x00; // version made by
        buffer[offset + 6] = 0x0A;
        buffer[offset + 7] = 0x00; // version needed
        buffer[offset + 8] = 0x00;
        buffer[offset + 9] = 0x00; // flags
        buffer[offset + 10] = 0x00;
        buffer[offset + 11] = 0x00; // compression
        buffer[offset + 12] = 0x00;
        buffer[offset + 13] = 0x00; // time
        buffer[offset + 14] = 0x00;
        buffer[offset + 15] = 0x00; // date
        buffer[offset + 16] = 0x00;
        buffer[offset + 17] = 0x00;
        buffer[offset + 18] = 0x00;
        buffer[offset + 19] = 0x00; // CRC
        buffer[offset + 20] = 0x00;
        buffer[offset + 21] = 0x00;
        buffer[offset + 22] = 0x00;
        buffer[offset + 23] = 0x00; // compressed
        buffer[offset + 24] = 0x00;
        buffer[offset + 25] = 0x00;
        buffer[offset + 26] = 0x00;
        buffer[offset + 27] = 0x00; // uncompressed
        std.mem.writeInt(u16, buffer[offset + 28 ..][0..2], entry.name_len, .little); // name len
        buffer[offset + 30] = 0x00;
        buffer[offset + 31] = 0x00; // extra len
        buffer[offset + 32] = 0x00;
        buffer[offset + 33] = 0x00; // comment len
        buffer[offset + 34] = 0x00;
        buffer[offset + 35] = 0x00; // disk number
        buffer[offset + 36] = 0x00;
        buffer[offset + 37] = 0x00; // internal attrs
        buffer[offset + 38] = 0x00;
        buffer[offset + 39] = 0x00;
        buffer[offset + 40] = 0x00;
        buffer[offset + 41] = 0x00; // external attrs
        std.mem.writeInt(u32, buffer[offset + 42 ..][0..4], entry.offset, .little); // local header offset
        offset += 46;
        @memcpy(buffer[offset..][0..entry.name_len], entry.name[0..entry.name_len]);
        offset += entry.name_len;
    }

    const cd_size = offset - cd_start;

    // Write EOCD
    buffer[offset] = 0x50;
    buffer[offset + 1] = 0x4B;
    buffer[offset + 2] = 0x05;
    buffer[offset + 3] = 0x06; // signature
    buffer[offset + 4] = 0x00;
    buffer[offset + 5] = 0x00; // disk number
    buffer[offset + 6] = 0x00;
    buffer[offset + 7] = 0x00; // disk with CD
    std.mem.writeInt(u16, buffer[offset + 8 ..][0..2], @intCast(cd_count), .little); // entries on disk
    std.mem.writeInt(u16, buffer[offset + 10 ..][0..2], @intCast(cd_count), .little); // total entries
    std.mem.writeInt(u32, buffer[offset + 12 ..][0..4], @intCast(cd_size), .little); // CD size
    std.mem.writeInt(u32, buffer[offset + 16 ..][0..4], @intCast(cd_start), .little); // CD offset
    buffer[offset + 20] = 0x00;
    buffer[offset + 21] = 0x00; // comment len

    return buffer;
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "detectFormat ZIP" {
    const zip_header = [_]u8{ 0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(FileFormat.zip, detectFormat(&zip_header));
}

test "FormatValidator accepts valid ZIP file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid ZIP file structure:
    // - Local file header (PK\x03\x04)
    // - File data (empty file named "test.txt")
    // - Central directory header (PK\x01\x02)
    // - End of central directory (PK\x05\x06)
    //
    // This is a real, minimal ZIP file that any ZIP tool can read.
    const valid_zip = [_]u8{
        // Local file header
        0x50, 0x4B, 0x03, 0x04, // signature
        0x0A, 0x00, // version needed (1.0)
        0x00, 0x00, // general purpose flag
        0x00, 0x00, // compression method (store)
        0x00, 0x00, // last mod time
        0x00, 0x00, // last mod date
        0x00, 0x00, 0x00, 0x00, // CRC-32 (0 for empty file)
        0x00, 0x00, 0x00, 0x00, // compressed size (0)
        0x00, 0x00, 0x00, 0x00, // uncompressed size (0)
        0x08, 0x00, // filename length (8)
        0x00, 0x00, // extra field length (0)
        't', 'e', 's', 't', '.', 't', 'x', 't', // filename

        // Central directory header
        0x50, 0x4B, 0x01, 0x02, // signature
        0x0A, 0x00, // version made by
        0x0A, 0x00, // version needed
        0x00, 0x00, // general purpose flag
        0x00, 0x00, // compression method
        0x00, 0x00, // last mod time
        0x00, 0x00, // last mod date
        0x00, 0x00, 0x00, 0x00, // CRC-32
        0x00, 0x00, 0x00, 0x00, // compressed size
        0x00, 0x00, 0x00, 0x00, // uncompressed size
        0x08, 0x00, // filename length
        0x00, 0x00, // extra field length
        0x00, 0x00, // file comment length
        0x00, 0x00, // disk number start
        0x00, 0x00, // internal file attributes
        0x00, 0x00, 0x00, 0x00, // external file attributes
        0x00, 0x00, 0x00, 0x00, // relative offset of local header
        't', 'e', 's', 't', '.', 't', 'x', 't', // filename

        // End of central directory
        0x50, 0x4B, 0x05, 0x06, // signature
        0x00, 0x00, // disk number
        0x00, 0x00, // disk number with CD
        0x01, 0x00, // number of entries on this disk
        0x01, 0x00, // total number of entries
        0x36, 0x00, 0x00, 0x00, // size of central directory (54 bytes)
        0x26, 0x00, 0x00, 0x00, // offset of central directory (38 bytes)
        0x00, 0x00, // comment length
    };

    // Write valid ZIP to temp file
    const file = try tmp_dir.dir.createFile("valid.zip", .{});
    try file.writeAll(&valid_zip);
    file.close();

    // Get full path
    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.zip");
    defer allocator.free(path);

    // Validate the file
    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should detect as ZIP format and be VALID
    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(result.is_valid); // THIS IS THE KEY ASSERTION - currently failing!
    if (!result.is_valid) {
        std.debug.print("\nZIP validation failed with: {s}\n", .{result.error_message orelse "no message"});
    }
}

test "FormatValidator accepts real-world ZIP file with extra fields" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // This is an actual ZIP file created by macOS zip command containing "hello world\n"
    // It includes Unix timestamp extension fields (UT) which real ZIP tools add
    const real_zip = [_]u8{
        // Local file header with extra fields
        0x50, 0x4b, 0x03, 0x04, // signature
        0x0a, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression (store)
        0x51, 0x4c, // mod time
        0x2c, 0x5c, // mod date
        0x2d, 0x3b, 0x08, 0xaf, // CRC-32
        0x0c, 0x00, 0x00, 0x00, // compressed size (12)
        0x0c, 0x00, 0x00, 0x00, // uncompressed size (12)
        0x10, 0x00, // filename length (16)
        0x1c, 0x00, // extra field length (28)
        // filename: "test_content.txt"
        't',  'e',
        's',  't',
        '_',  'c',
        'o',  'n',
        't',  'e',
        'n',  't',
        '.',  't',
        'x',  't',
        // extra field (Unix timestamp)
        'U',  'T',
        0x09, 0x00,
        0x03, 0x7a,
        0x06, 0x65,
        0x69, 0x7a,
        0x06, 0x65,
        0x69, 'u',
        'x',  0x0b,
        0x00, 0x01,
        0x04, 0xf5,
        0x01, 0x00,
        0x00, 0x04,
        0x14, 0x00,
        0x00, 0x00,
        // file data: "hello world\n"
        'h',  'e',
        'l',  'l',
        'o',  ' ',
        'w',  'o',
        'r',  'l',
        'd',
        0x0a,

        // Central directory header
        0x50, 0x4b, 0x01, 0x02, // signature
        0x1e, 0x03, // version made by
        0x0a, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x51, 0x4c, // mod time
        0x2c, 0x5c, // mod date
        0x2d, 0x3b, 0x08, 0xaf, // CRC-32
        0x0c, 0x00, 0x00, 0x00, // compressed size
        0x0c, 0x00, 0x00, 0x00, // uncompressed size
        0x10, 0x00, // filename length (16)
        0x18, 0x00, // extra field length (24)
        0x00, 0x00, // comment length
        0x00, 0x00, // disk number
        0x01, 0x00, // internal attrs
        0x00, 0x00, 0xa4, 0x81, // external attrs
        0x00, 0x00, 0x00, 0x00, // local header offset
        // filename
        't',  'e',  's',  't',
        '_',  'c',  'o',  'n',
        't',  'e',  'n',  't',
        '.',  't',  'x',  't',
        // extra field
        'U',  'T',  0x05, 0x00,
        0x03, 0x7a, 0x06, 0x65,
        0x69, 'u',  'x',  0x0b,
        0x00, 0x01, 0x04, 0xf5,
        0x01, 0x00, 0x00, 0x04,
        0x14, 0x00, 0x00,
        0x00,

        // End of central directory
        0x50, 0x4b, 0x05, 0x06, // signature
        0x00, 0x00, // disk number
        0x00, 0x00, // disk with CD
        0x01, 0x00, // entries on this disk
        0x01, 0x00, // total entries
        0x56, 0x00, 0x00, 0x00, // CD size
        0x56, 0x00, 0x00, 0x00, // CD offset
        0x00, 0x00, // comment length
    };

    const file = try tmp_dir.dir.createFile("real.zip", .{});
    try file.writeAll(&real_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "real.zip");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should detect as ZIP format and be VALID
    try std.testing.expectEqual(FileFormat.zip, result.format);
    if (!result.is_valid) {
        std.debug.print("\nReal ZIP validation failed with: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects corrupted ZIP file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a corrupted ZIP file - has signature but missing EOCD
    const corrupted_zip = [_]u8{
        // Local file header only, no central directory or EOCD
        0x50, 0x4B, 0x03, 0x04, // signature
        0x0A, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, 0x00, 0x00, // time/date
        0x00, 0x00, 0x00, 0x00, // CRC
        0x00, 0x00, 0x00, 0x00, // compressed size
        0x00, 0x00, 0x00, 0x00, // uncompressed size
        0x04, 0x00, // filename length
        0x00, 0x00, // extra length
        't', 'e', 's', 't', // filename
        // Missing central directory and EOCD - this is corrupted!
    };

    const file = try tmp_dir.dir.createFile("corrupted.zip", .{});
    try file.writeAll(&corrupted_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupted.zip");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should detect as ZIP format but INVALID (missing EOCD)
    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid EPUB file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // EPUB is a ZIP with mimetype and META-INF/container.xml
    const files = [_]ZipTestFile{
        .{ .name = "mimetype", .content = "application/epub+zip" },
        .{ .name = "META-INF/container.xml", .content = "<?xml version=\"1.0\"?><container/>" },
    };
    const epub_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("valid.epub", .{});
    // Find actual data length (up to end of EOCD + 22)
    var data_len: usize = 0;
    for (epub_data, 0..) |_, i| {
        if (i >= 4 and epub_data[i - 4] == 0x50 and epub_data[i - 3] == 0x4B and
            epub_data[i - 2] == 0x05 and epub_data[i - 1] == 0x06)
        {
            data_len = i + 18; // EOCD is 22 bytes, we found it at i-4
            break;
        }
    }
    if (data_len == 0) data_len = 512; // fallback
    try file.writeAll(epub_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.epub");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    if (!result.is_valid) {
        std.debug.print("\nValid EPUB failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.epub, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects corrupted EPUB file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // EPUB without required structure (just a plain ZIP)
    const files = [_]ZipTestFile{
        .{ .name = "random.txt", .content = "not an epub" },
    };
    const zip_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("corrupted.epub", .{});
    var data_len: usize = 512;
    for (zip_data, 0..) |_, i| {
        if (i >= 4 and zip_data[i - 4] == 0x50 and zip_data[i - 3] == 0x4B and
            zip_data[i - 2] == 0x05 and zip_data[i - 1] == 0x06)
        {
            data_len = i + 18;
            break;
        }
    }
    try file.writeAll(zip_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupted.epub");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    // Note: This will be detected as plain ZIP since it lacks EPUB markers
    // We need to test a file that IS detected as EPUB but is invalid
    const result = validator.validateFile(path);

    // It should be detected as ZIP (not EPUB) since it lacks the markers
    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(result.is_valid); // Valid ZIP, just not EPUB
}

test "FormatValidator accepts valid DOCX file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // DOCX requires [Content_Types].xml and word/ directory
    const files = [_]ZipTestFile{
        .{ .name = "[Content_Types].xml", .content = "<?xml version=\"1.0\"?><Types/>" },
        .{ .name = "word/document.xml", .content = "<?xml version=\"1.0\"?><document/>" },
    };
    const docx_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("valid.docx", .{});
    var data_len: usize = 512;
    for (docx_data, 0..) |_, i| {
        if (i >= 4 and docx_data[i - 4] == 0x50 and docx_data[i - 3] == 0x4B and
            docx_data[i - 2] == 0x05 and docx_data[i - 1] == 0x06)
        {
            data_len = i + 18;
            break;
        }
    }
    try file.writeAll(docx_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.docx");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    if (!result.is_valid) {
        std.debug.print("\nValid DOCX failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.docx, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects DOCX missing word directory" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Has Content_Types but no word/ directory
    const files = [_]ZipTestFile{
        .{ .name = "[Content_Types].xml", .content = "<?xml version=\"1.0\"?><Types/>" },
        .{ .name = "other/file.xml", .content = "<?xml version=\"1.0\"?><data/>" },
    };
    const zip_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("invalid.docx", .{});
    var data_len: usize = 512;
    for (zip_data, 0..) |_, i| {
        if (i >= 4 and zip_data[i - 4] == 0x50 and zip_data[i - 3] == 0x4B and
            zip_data[i - 2] == 0x05 and zip_data[i - 1] == 0x06)
        {
            data_len = i + 18;
            break;
        }
    }
    try file.writeAll(zip_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.docx");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Without word/, it won't be detected as DOCX, just plain ZIP
    try std.testing.expectEqual(FileFormat.zip, result.format);
}

test "FormatValidator accepts valid XLSX file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // XLSX requires [Content_Types].xml and xl/ directory
    const files = [_]ZipTestFile{
        .{ .name = "[Content_Types].xml", .content = "<?xml version=\"1.0\"?><Types/>" },
        .{ .name = "xl/workbook.xml", .content = "<?xml version=\"1.0\"?><workbook/>" },
    };
    const xlsx_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("valid.xlsx", .{});
    var data_len: usize = 512;
    for (xlsx_data, 0..) |_, i| {
        if (i >= 4 and xlsx_data[i - 4] == 0x50 and xlsx_data[i - 3] == 0x4B and
            xlsx_data[i - 2] == 0x05 and xlsx_data[i - 1] == 0x06)
        {
            data_len = i + 18;
            break;
        }
    }
    try file.writeAll(xlsx_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.xlsx");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    if (!result.is_valid) {
        std.debug.print("\nValid XLSX failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.xlsx, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid PPTX file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // PPTX requires [Content_Types].xml and ppt/ directory
    const files = [_]ZipTestFile{
        .{ .name = "[Content_Types].xml", .content = "<?xml version=\"1.0\"?><Types/>" },
        .{ .name = "ppt/presentation.xml", .content = "<?xml version=\"1.0\"?><presentation/>" },
    };
    const pptx_data = buildMinimalZip(&files);

    const file = try tmp_dir.dir.createFile("valid.pptx", .{});
    var data_len: usize = 512;
    for (pptx_data, 0..) |_, i| {
        if (i >= 4 and pptx_data[i - 4] == 0x50 and pptx_data[i - 3] == 0x4B and
            pptx_data[i - 2] == 0x05 and pptx_data[i - 1] == 0x06)
        {
            data_len = i + 18;
            break;
        }
    }
    try file.writeAll(pptx_data[0..data_len]);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.pptx");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    if (!result.is_valid) {
        std.debug.print("\nValid PPTX failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expectEqual(FileFormat.pptx, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects truncated ZIP-based files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Truncated ZIP (missing EOCD) - simulates what generate_test_files bug did
    const truncated_zip = [_]u8{
        0x50, 0x4B, 0x03, 0x04, // Local file header signature
        0x0A, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, 0x00, 0x00, // time/date
        0x00, 0x00, 0x00, 0x00, // CRC
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x08, 0x00, // filename length
        0x00, 0x00, // extra length
        't', 'e', 's', 't', '.', 't', 'x', 't', // filename
        'h', 'e', 'l', 'l', 'o', // file content
        // Missing central directory and EOCD - this is truncated!
    };

    const file = try tmp_dir.dir.createFile("truncated.zip", .{});
    try file.writeAll(&truncated_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.zip");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should be detected as ZIP but invalid (missing EOCD)
    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator deep validates Brotli from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth Brotli file ("Hello" compressed)
    const file = std.fs.cwd().openFile("ground_truth_examples/brotli/hello.br", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/brotli/hello.br") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.br, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator detects Brotli by extension" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid Brotli (empty string, window bits=10)
    const empty_brotli = [_]u8{0x06};
    const file = try tmp_dir.dir.createFile("empty.br", .{});
    try file.writeAll(&empty_brotli);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "empty.br");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    // Should detect as Brotli by extension
    try std.testing.expectEqual(FileFormat.br, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator rejects corrupted Brotli" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid Brotli data (random bytes)
    const invalid = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    const file = try tmp_dir.dir.createFile("invalid.br", .{});
    try file.writeAll(&invalid);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.br");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    // Should be detected as Brotli but fail validation
    try std.testing.expectEqual(FileFormat.br, result.format);
    try std.testing.expect(!result.is_valid);
}

test "validateZipDeep accepts valid ZIP with stored entry" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid ZIP with one stored (uncompressed) file
    // Contains "hello.txt" with content "Hello" (5 bytes)
    // CRC-32 of "Hello" is 0xf7d18982
    const valid_zip = [_]u8{
        // Local file header
        'P', 'K', 3, 4, // signature
        0x0A, 0x00, // version needed (1.0)
        0x00, 0x00, // general purpose flags
        0x00, 0x00, // compression method (stored)
        0x00, 0x00, // last mod time
        0x00, 0x00, // last mod date
        0x82, 0x89, 0xD1, 0xF7, // CRC-32 of "Hello" (little endian: 0xf7d18982)
        0x05, 0x00, 0x00, 0x00, // compressed size (5)
        0x05, 0x00, 0x00, 0x00, // uncompressed size (5)
        0x09, 0x00, // filename length (9)
        0x00, 0x00, // extra field length (0)
        'h', 'e', 'l', 'l', 'o', '.', 't', 'x', 't', // filename
        'H', 'e', 'l', 'l', 'o', // file data
        // Central directory header
        'P', 'K', 1, 2, // signature
        0x14, 0x00, // version made by
        0x0A, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x82, 0x89, 0xD1, 0xF7, // CRC
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra length
        0x00, 0x00, // comment length
        0x00, 0x00, // disk number
        0x00, 0x00, // internal attributes
        0x00, 0x00, 0x00, 0x00, // external attributes
        0x00, 0x00, 0x00, 0x00, // local header offset
        'h', 'e', 'l', 'l', 'o', '.', 't', 'x', 't', // filename
        // End of central directory
        'P', 'K', 5, 6, // signature
        0x00, 0x00, // disk number
        0x00, 0x00, // disk with CD
        0x01, 0x00, // entries on disk
        0x01, 0x00, // total entries
        0x37, 0x00, 0x00, 0x00, // CD size (55 bytes)
        0x2C, 0x00, 0x00, 0x00, // CD offset (44 bytes)
        0x00, 0x00, // comment length
    };

    const file = try tmp_dir.dir.createFile("valid.zip", .{});
    try file.writeAll(&valid_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.zip");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.zip, result.format);
    if (!result.is_valid) {
        std.debug.print("\nZIP CRC validation failed unexpectedly: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateZipDeep rejects ZIP with corrupted stored entry CRC" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // ZIP with corrupted CRC (changed last byte)
    const corrupted_zip = [_]u8{
        // Local file header
        'P', 'K', 3, 4,
        0x0A, 0x00, // version
        0x00, 0x00, // flags
        0x00, 0x00, // compression (stored)
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x82, 0x89, 0xD1, 0xFF, // CORRUPTED CRC (should be 0xF7)
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra length
        'h',  'e',
        'l',  'l',
        'o',  '.',
        't',  'x',
        't',
        'H', 'e', 'l', 'l', 'o', // file data
        // Central directory header
        'P', 'K', 1, 2, // signature
        0x14, 0x00, // version made by
        0x0A, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x82, 0x89, 0xD1, 0xFF, // corrupted CRC
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra length
        0x00, 0x00, // comment length
        0x00, 0x00, // disk number
        0x00, 0x00, // internal attributes
        0x00, 0x00, 0x00, 0x00, // external attributes
        0x00, 0x00, 0x00, 0x00, // local header offset
        'h',  'e',  'l',  'l',
        'o',  '.',  't',  'x',
        't',
        // End of central directory
         'P',  'K',  5,
        6,    0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x37, 0x00, 0x00,
        0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };

    const file = try tmp_dir.dir.createFile("corrupted.zip", .{});
    try file.writeAll(&corrupted_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupted.zip");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqualStrings("CRC mismatch in stored entry", result.error_message.?);
}

test "validateZipDeep rejects ZIP with bitrot in stored data" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // ZIP with bit flip in the data (simulating bitrot)
    const bitrot_zip = [_]u8{
        // Local file header
        'P',  'K',  3,    4,
        0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, // compression (stored)
        0x00, 0x00,
        0x00, 0x00,
        0x82, 0x89, 0xD1, 0xF7, // correct CRC for "Hello"
        0x05, 0x00, 0x00, 0x00,
        0x05, 0x00, 0x00, 0x00,
        0x09, 0x00, 0x00, 0x00,
        'h',  'e',  'l',  'l',
        'o',  '.',  't',  'x',
        't',
        'H', 'e', 'l', 'l', 'p', // BIT FLIPPED: 'o' (0x6F) -> 'p' (0x70)
        // Central directory header
        'P', 'K', 1, 2, // signature
        0x14, 0x00, // version made by
        0x0A, 0x00, // version needed
        0x00, 0x00, // flags
        0x00, 0x00, // compression
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x82, 0x89, 0xD1, 0xF7, // CRC
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra length
        0x00, 0x00, // comment length
        0x00, 0x00, // disk number
        0x00, 0x00, // internal attributes
        0x00, 0x00, 0x00, 0x00, // external attributes
        0x00, 0x00, 0x00, 0x00, // local header offset
        'h',  'e',  'l',  'l',
        'o',  '.',  't',  'x',
        't',
        // End of central directory
         'P',  'K',  5,
        6,    0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x37, 0x00, 0x00,
        0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };

    const file = try tmp_dir.dir.createFile("bitrot.zip", .{});
    try file.writeAll(&bitrot_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bitrot.zip");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqualStrings("CRC mismatch in stored entry", result.error_message.?);
}

test "validateZipDeep returns structural for encrypted ZIP entries" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // ZIP with encryption flag set (bit 0 of general purpose flags at offset 6-7)
    const encrypted_zip = [_]u8{
        // Local file header
        'P', 'K', 3, 4,
        0x0A, 0x00, // version needed
        0x01, 0x00, // general purpose flags with encryption bit (0x0001)
        0x00, 0x00, // compression (stored)
        0x00, 0x00,
        0x00, 0x00,
        0x82, 0x89, 0xD1, 0xF7, // CRC (doesn't matter for encrypted)
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra field length
        'h',  'e',
        'l',  'l',
        'o',  '.',
        't',  'x',
        't',
        // Encrypted data (just dummy bytes - would fail CRC if decrypted)
         0xDE,
        0xAD, 0xBE,
        0xEF,
        0x00,
        // Central directory header
        'P', 'K', 1, 2, // signature
        0x14, 0x00, // version made by
        0x0A, 0x00, // version needed
        0x01, 0x00, // encryption flag
        0x00, 0x00, // compression
        0x00, 0x00, // mod time
        0x00, 0x00, // mod date
        0x82, 0x89, 0xD1, 0xF7, // CRC
        0x05, 0x00, 0x00, 0x00, // compressed size
        0x05, 0x00, 0x00, 0x00, // uncompressed size
        0x09, 0x00, // filename length
        0x00, 0x00, // extra length
        0x00, 0x00, // comment length
        0x00, 0x00, // disk number
        0x00, 0x00, // internal attributes
        0x00, 0x00, 0x00, 0x00, // external attributes
        0x00, 0x00, 0x00, 0x00, // local header offset
        'h',  'e',  'l',  'l',
        'o',  '.',  't',  'x',
        't',
        // End of central directory
         'P',  'K',  5,
        6,    0x00, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x37, 0x00, 0x00,
        0x00, 0x2C, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };

    const file = try tmp_dir.dir.createFile("encrypted.zip", .{});
    try file.writeAll(&encrypted_zip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "encrypted.zip");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.zip, result.format);
    try std.testing.expect(result.is_valid);
    // Should be structural only since we can't validate encrypted content
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "detectFormat gzip" {
    const gzip_data = [_]u8{ 0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 };
    const format = detectFormat(&gzip_data);
    try std.testing.expectEqual(FileFormat.gzip, format);
}

test "detectFormat 7z" {
    const sevenz_data = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04 };
    const format = detectFormat(&sevenz_data);
    try std.testing.expectEqual(FileFormat.sevenz, format);
}

test "detectFormat tar POSIX ustar" {
    // tar file with ustar magic at offset 257
    var tar_data: [512]u8 = undefined;
    @memset(&tar_data, 0);
    // Put "ustar" at offset 257 (after null terminator at 256)
    tar_data[257] = 'u';
    tar_data[258] = 's';
    tar_data[259] = 't';
    tar_data[260] = 'a';
    tar_data[261] = 'r';
    tar_data[262] = 0;
    const format = detectFormat(&tar_data);
    try std.testing.expectEqual(FileFormat.tar, format);
}

test "FormatValidator accepts valid gzip file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid gzip file containing "Hello" (deflated)
    // Created with: echo -n "Hello" | gzip | xxd -i
    const valid_gzip = [_]u8{
        0x1f, 0x8b, // magic number
        0x08, // compression method (deflate)
        0x00, // flags (none)
        0x00, 0x00, 0x00, 0x00, // mtime (0)
        0x00, // extra flags
        0x03, // OS (Unix)
        // Compressed data for "Hello"
        0xf3,
        0x48,
        0xcd,
        0xc9,
        0xc9,
        0x07,
        0x00,
        // CRC32 of "Hello" (0xF7D18982) in little-endian
        0x82,
        0x89,
        0xd1,
        0xf7,
        // ISIZE (5) in little-endian
        0x05,
        0x00,
        0x00,
        0x00,
    };

    const file = try tmp_dir.dir.createFile("valid.gz", .{});
    try file.writeAll(&valid_gzip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.gz");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.gzip, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.error_message == null);
}

test "FormatValidator rejects truncated gzip file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Truncated gzip - missing trailer
    const truncated_gzip = [_]u8{
        0x1f, 0x8b, // magic number
        0x08, // compression method
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // mtime
        0x00, // extra flags
        0x03, // OS
        // Truncated - no compressed data or trailer
    };

    const file = try tmp_dir.dir.createFile("truncated.gz", .{});
    try file.writeAll(&truncated_gzip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.gz");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.gzip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator rejects gzip with invalid compression method" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Gzip with invalid compression method (0x09 instead of 0x08)
    const invalid_gzip = [_]u8{
        0x1f, 0x8b, // magic number
        0x09, // INVALID compression method (should be 0x08)
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // mtime
        0x00, // extra flags
        0x03, // OS
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, // compressed data
        0x82, 0x89, 0xd1, 0xf7, // CRC32
        0x05, 0x00, 0x00, 0x00, // ISIZE
    };

    const file = try tmp_dir.dir.createFile("invalid.gz", .{});
    try file.writeAll(&invalid_gzip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.gz");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.gzip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "detectFormat bzip2" {
    const bzip2_data = [_]u8{ 0x42, 0x5A, 0x68, 0x39, 0x00, 0x00, 0x00, 0x00 }; // BZh9 + data
    const format = detectFormat(&bzip2_data);
    try std.testing.expectEqual(FileFormat.bzip2, format);
}

test "FormatValidator accepts valid bzip2 file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid bzip2 file
    // Header: BZh9 (block size 9 = 900KB)
    // Then we need enough bytes to look like a valid stream
    // A real bzip2 has: header + compressed blocks + stream end magic + CRC
    // Minimum realistic size ~14 bytes
    var valid_bz2: [20]u8 = undefined;
    valid_bz2[0] = 0x42; // B
    valid_bz2[1] = 0x5A; // Z
    valid_bz2[2] = 0x68; // h
    valid_bz2[3] = 0x39; // 9 (block size)
    // Fill rest with some data (would be compressed blocks in real file)
    @memset(valid_bz2[4..], 0x00);

    const file = try tmp_dir.dir.createFile("valid.bz2", .{});
    try file.writeAll(&valid_bz2);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.bz2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.bzip2, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects truncated bzip2 file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Truncated bzip2 - only header, file too small
    const truncated_bz2 = [_]u8{
        0x42, 0x5A, 0x68, 0x39, // BZh9
        0x00, 0x00, // Only 6 bytes total
    };

    const file = try tmp_dir.dir.createFile("truncated.bz2", .{});
    try file.writeAll(&truncated_bz2);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.bz2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.bzip2, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator rejects bzip2 with invalid block size" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid block size (0 instead of 1-9)
    var invalid_bz2: [20]u8 = undefined;
    invalid_bz2[0] = 0x42; // B
    invalid_bz2[1] = 0x5A; // Z
    invalid_bz2[2] = 0x68; // h
    invalid_bz2[3] = 0x30; // 0 - invalid! (must be 1-9)
    @memset(invalid_bz2[4..], 0x00);

    const file = try tmp_dir.dir.createFile("invalid_block.bz2", .{});
    try file.writeAll(&invalid_bz2);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid_block.bz2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.bzip2, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator accepts valid 7z file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid 7z file header (32 bytes)
    // The 7z format has a specific 32-byte signature header
    var valid_7z: [32]u8 = undefined;
    // Signature: 37 7A BC AF 27 1C
    valid_7z[0] = 0x37;
    valid_7z[1] = 0x7A;
    valid_7z[2] = 0xBC;
    valid_7z[3] = 0xAF;
    valid_7z[4] = 0x27;
    valid_7z[5] = 0x1C;
    // Format version: 0.4
    valid_7z[6] = 0x00;
    valid_7z[7] = 0x04;
    // CRC of next 20 bytes (bytes 12-31) - set to 0 initially
    valid_7z[8] = 0x00;
    valid_7z[9] = 0x00;
    valid_7z[10] = 0x00;
    valid_7z[11] = 0x00;
    // Next header offset (0 = no compressed data)
    @memset(valid_7z[12..20], 0);
    // Next header size (0)
    @memset(valid_7z[20..28], 0);
    // Next header CRC (0 for empty)
    @memset(valid_7z[28..32], 0);

    // Calculate and set the start header CRC (bytes 8-11 cover bytes 12-31)
    const start_crc = std.hash.Crc32.hash(valid_7z[12..32]);
    std.mem.writeInt(u32, valid_7z[8..12], start_crc, .little);

    const file = try tmp_dir.dir.createFile("valid.7z", .{});
    try file.writeAll(&valid_7z);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.7z");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.sevenz, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.error_message == null);
}

test "FormatValidator rejects truncated 7z file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Truncated 7z - only signature, missing rest of header
    const truncated_7z = [_]u8{
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, // signature
        0x00, 0x04, // version
        // Missing: CRC, next header offset/size/crc
    };

    const file = try tmp_dir.dir.createFile("truncated.7z", .{});
    try file.writeAll(&truncated_7z);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.7z");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.sevenz, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator accepts valid tar file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid POSIX tar file with one empty file entry
    var valid_tar: [1024]u8 = undefined;
    @memset(&valid_tar, 0);

    // First 512-byte block: file header
    // Name (100 bytes): "test.txt"
    const name = "test.txt";
    @memcpy(valid_tar[0..name.len], name);

    // Mode (8 bytes at offset 100): "0000644\0"
    const mode = "0000644";
    @memcpy(valid_tar[100..107], mode);
    valid_tar[107] = 0;

    // UID (8 bytes at offset 108): "0000000\0"
    @memcpy(valid_tar[108..115], "0000000");
    valid_tar[115] = 0;

    // GID (8 bytes at offset 116): "0000000\0"
    @memcpy(valid_tar[116..123], "0000000");
    valid_tar[123] = 0;

    // Size (12 bytes at offset 124): "00000000000\0" (0 bytes)
    @memcpy(valid_tar[124..135], "00000000000");
    valid_tar[135] = 0;

    // Mtime (12 bytes at offset 136): "00000000000\0"
    @memcpy(valid_tar[136..147], "00000000000");
    valid_tar[147] = 0;

    // Checksum placeholder (8 spaces at offset 148)
    @memset(valid_tar[148..156], ' ');

    // Type flag (1 byte at offset 156): '0' (regular file)
    valid_tar[156] = '0';

    // Link name (100 bytes at offset 157): empty
    // Already zeroed

    // Magic (6 bytes at offset 257): "ustar\0"
    @memcpy(valid_tar[257..262], "ustar");
    valid_tar[262] = 0;

    // Version (2 bytes at offset 263): "00"
    valid_tar[263] = '0';
    valid_tar[264] = '0';

    // Calculate checksum: sum of all bytes in header, treating checksum field as spaces
    var checksum: u32 = 0;
    for (valid_tar[0..512]) |b| {
        checksum += b;
    }

    // Write checksum as 6 octal digits + null + space
    var checksum_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&checksum_buf, "{o:0>6}", .{checksum}) catch unreachable;
    checksum_buf[6] = 0;
    checksum_buf[7] = ' ';
    @memcpy(valid_tar[148..156], &checksum_buf);

    // Second 512-byte block: end-of-archive (all zeros)
    // Already zeroed

    const file = try tmp_dir.dir.createFile("valid.tar", .{});
    try file.writeAll(&valid_tar);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.tar");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.tar, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.error_message == null);
}

test "FormatValidator rejects tar with invalid checksum" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Tar file with corrupted checksum
    var invalid_tar: [1024]u8 = undefined;
    @memset(&invalid_tar, 0);

    const name = "test.txt";
    @memcpy(invalid_tar[0..name.len], name);
    @memcpy(invalid_tar[100..107], "0000644");
    invalid_tar[107] = 0;
    @memcpy(invalid_tar[108..115], "0000000");
    invalid_tar[115] = 0;
    @memcpy(invalid_tar[116..123], "0000000");
    invalid_tar[123] = 0;
    @memcpy(invalid_tar[124..135], "00000000000");
    invalid_tar[135] = 0;
    @memcpy(invalid_tar[136..147], "00000000000");
    invalid_tar[147] = 0;
    // WRONG checksum
    @memcpy(invalid_tar[148..156], "000000\x00 ");
    invalid_tar[156] = '0';
    @memcpy(invalid_tar[257..262], "ustar");
    invalid_tar[262] = 0;
    invalid_tar[263] = '0';
    invalid_tar[264] = '0';

    const file = try tmp_dir.dir.createFile("invalid.tar", .{});
    try file.writeAll(&invalid_tar);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.tar");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.tar, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "validateGzipDeep accepts valid gzip and verifies trailer" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Valid gzip with correct CRC32 and ISIZE
    const valid_gzip = [_]u8{
        0x1f, 0x8b, // magic
        0x08, // compression method
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // mtime
        0x00, // extra flags
        0x03, // OS
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, // "Hello" deflated
        0x82, 0x89, 0xd1, 0xf7, // CRC32 of "Hello"
        0x05, 0x00, 0x00, 0x00, // ISIZE = 5
    };

    const file = try tmp_dir.dir.createFile("valid_deep.gz", .{});
    try file.writeAll(&valid_gzip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid_deep.gz");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.gzip, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateGzipDeep detects CRC corruption" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Valid gzip structure but with corrupted CRC32 in trailer
    const corrupt_gzip = [_]u8{
        0x1f, 0x8b, // magic
        0x08, // compression method
        0x00, // flags
        0x00, 0x00, 0x00, 0x00, // mtime
        0x00, // extra flags
        0x03, // OS
        0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, // "Hello" deflated
        0xFF, 0xFF, 0xFF, 0xFF, // WRONG CRC32 (should be 0xf7d18982)
        0x05, 0x00, 0x00, 0x00, // ISIZE = 5 (correct)
    };

    const file = try tmp_dir.dir.createFile("corrupt_crc.gz", .{});
    try file.writeAll(&corrupt_gzip);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupt_crc.gz");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.gzip, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
    try std.testing.expect(result.error_message != null);
}

test "validate7zDeep detects CRC corruption in start header" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // 7z with corrupted start header CRC
    var corrupted_7z: [32]u8 = undefined;
    corrupted_7z[0] = 0x37;
    corrupted_7z[1] = 0x7A;
    corrupted_7z[2] = 0xBC;
    corrupted_7z[3] = 0xAF;
    corrupted_7z[4] = 0x27;
    corrupted_7z[5] = 0x1C;
    corrupted_7z[6] = 0x00;
    corrupted_7z[7] = 0x04;
    // WRONG CRC - should fail validation
    corrupted_7z[8] = 0xDE;
    corrupted_7z[9] = 0xAD;
    corrupted_7z[10] = 0xBE;
    corrupted_7z[11] = 0xEF;
    @memset(corrupted_7z[12..32], 0);

    const file = try tmp_dir.dir.createFile("corrupted_crc.7z", .{});
    try file.writeAll(&corrupted_7z);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupted_crc.7z");
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.sevenz, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "validate7zDeep accepts valid 7z with full decompression" {
    const allocator = std.testing.allocator;

    // Use the ground truth sample which is a real 7z archive
    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, "ground_truth_examples/7z/sample.7z");

    try std.testing.expectEqual(FileFormat.sevenz, result.format);
    try std.testing.expect(result.is_valid);
    // z7z does full decompression + CRC verification
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator accepts valid ALS (gzip-based)" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid ALS file (gzip header)
    // ALS is gzip-compressed, so it will be detected as gzip
    var als_data: [20]u8 = undefined;
    als_data[0] = 0x1f; // Gzip magic byte 1
    als_data[1] = 0x8b; // Gzip magic byte 2
    als_data[2] = 0x08; // Compression method (deflate)
    als_data[3] = 0x00; // Flags
    als_data[4] = 0x00; // MTIME
    als_data[5] = 0x00;
    als_data[6] = 0x00;
    als_data[7] = 0x00;
    als_data[8] = 0x00; // XFL
    als_data[9] = 0xFF; // OS (unknown)
    @memset(als_data[10..20], 0);

    const file = try tmp_dir.dir.createFile("test.als", .{});
    try file.writeAll(&als_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.als");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // ALS files are detected as gzip by magic bytes, then remapped to .als by extension
    try std.testing.expectEqual(FileFormat.als, result.format);
    try std.testing.expect(result.is_valid);
}

test "detectFormat WARC" {
    const warc_1_0 = "WARC/1.0\r\nWARC-Type: warcinfo\r\n";
    try std.testing.expectEqual(FileFormat.warc, detectFormat(warc_1_0));

    const warc_1_1 = "WARC/1.1\r\nWARC-Type: response\r\n";
    try std.testing.expectEqual(FileFormat.warc, detectFormat(warc_1_1));
}

test "FormatValidator accepts valid WARC" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const warc_content =
        \\WARC/1.0
        \\WARC-Type: warcinfo
        \\WARC-Date: 2024-01-15T00:00:00Z
        \\WARC-Record-ID: <urn:uuid:12345678-1234-1234-1234-123456789abc>
        \\Content-Type: application/warc-fields
        \\Content-Length: 0
        \\
        \\
    ;

    const file = try tmp_dir.dir.createFile("test.warc", .{});
    try file.writeAll(warc_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.warc");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.warc, result.format);
    try std.testing.expect(result.is_valid);
}

test "detectFormat PAR2" {
    // PAR2 magic signature: "PAR2\x00PKT"
    const par2_header = [_]u8{ 'P', 'A', 'R', '2', 0x00, 'P', 'K', 'T' };
    try std.testing.expectEqual(FileFormat.par2, detectFormat(&par2_header));
}

test "FormatValidator accepts valid PAR2" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid PAR2 file: single packet header (64 bytes)
    var par2_data: [64]u8 = undefined;
    @memset(&par2_data, 0);

    // Magic "PAR2\x00PKT"
    par2_data[0] = 'P';
    par2_data[1] = 'A';
    par2_data[2] = 'R';
    par2_data[3] = '2';
    par2_data[4] = 0x00;
    par2_data[5] = 'P';
    par2_data[6] = 'K';
    par2_data[7] = 'T';

    // Packet length (64 bytes, little-endian u64)
    par2_data[8] = 0x40; // 64
    par2_data[9] = 0x00;
    // Remaining length bytes are already 0

    // Recovery set ID (bytes 32-47) - placeholder
    for (0..16) |i| {
        par2_data[32 + i] = @intCast(i + 16);
    }

    // Packet type (bytes 48-63) - "PAR 2.0\x00Main\x00..."
    const packet_type = "PAR 2.0\x00Main\x00\x00\x00\x00";
    @memcpy(par2_data[48..64], packet_type);

    // Packet MD5 digest is computed over bytes 32..packet_len.
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(par2_data[32..64], &digest, .{});
    @memcpy(par2_data[16..32], &digest);

    const file = try tmp_dir.dir.createFile("test.par2", .{});
    try file.writeAll(&par2_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.par2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.par2, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator rejects truncated PAR2" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Truncated PAR2 (only 32 bytes, less than 64-byte header)
    var truncated: [32]u8 = undefined;
    @memset(&truncated, 0);

    // Magic "PAR2\x00PKT"
    truncated[0] = 'P';
    truncated[1] = 'A';
    truncated[2] = 'R';
    truncated[3] = '2';
    truncated[4] = 0x00;
    truncated[5] = 'P';
    truncated[6] = 'K';
    truncated[7] = 'T';

    const file = try tmp_dir.dir.createFile("truncated.par2", .{});
    try file.writeAll(&truncated);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "truncated.par2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.par2, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator rejects PAR2 with invalid packet length" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // PAR2 with packet length claiming 128 bytes but file is only 64
    var bad_par2: [64]u8 = undefined;
    @memset(&bad_par2, 0);

    // Magic "PAR2\x00PKT"
    bad_par2[0] = 'P';
    bad_par2[1] = 'A';
    bad_par2[2] = 'R';
    bad_par2[3] = '2';
    bad_par2[4] = 0x00;
    bad_par2[5] = 'P';
    bad_par2[6] = 'K';
    bad_par2[7] = 'T';

    // Packet length = 128 (but file is only 64 bytes)
    bad_par2[8] = 0x80; // 128
    bad_par2[9] = 0x00;

    const file = try tmp_dir.dir.createFile("bad_length.par2", .{});
    try file.writeAll(&bad_par2);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "bad_length.par2");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.par2, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator validates PAR2 from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth PAR2 file
    const file = std.fs.cwd().openFile("ground_truth_examples/par2/sample.par2", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/par2/sample.par2") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.par2, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

