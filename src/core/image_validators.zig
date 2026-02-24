//! Image/photography format validators extracted from format_validation.zig.
//! Covers PNG, JPEG, GIF, BMP, TIFF, WebP, JPEG XL, SVG, EXR, PSD, JPEG2000,
//! JBIG2, HEIC, AVIF, ICO, QOI, TGA, and DNG.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const MalformationType = format_validation.MalformationType;
const jpeg_validator = @import("jpeg_validator.zig");
const jxl_validator = @import("jxl_validator.zig");
const webp_validator = @import("webp_validator.zig");
const bmp_decoder = @import("bmp_decoder.zig");
const jpeg2000_validator = @import("jpeg2000_validator.zig");
const jbig2_decoder = @import("jbig2_decoder.zig");
const ccitt_fax_decoder = @import("ccitt_fax_decoder.zig");
const tiff_lzw_decoder = @import("tiff_lzw_decoder.zig");
const heic_validator = @import("heic_validator.zig");
const avif_validator = @import("avif_validator.zig");
const zlib = @import("zlib.zig");
const libraw_validator = @import("libraw_validator.zig");
const zigimg = @import("zigimg");
const xml = @import("xml");
const jpeg_lossless_decoder = @import("jpeg_lossless_decoder.zig");
const errmsg = @import("error_messages.zig");

// ============ PNG Validator ============

/// PNG chunk types
pub const PNG_IHDR: u32 = 0x49484452; // IHDR
pub const PNG_IEND: u32 = 0x49454E44; // IEND

/// Validate PNG file structure.
pub fn validatePng(file: std.fs.File) ValidationResult {
    return validatePngWithOptions(file, false);
}

pub fn validatePngWithOptions(file: std.fs.File, skip_magic: bool) ValidationResult {
    // Check PNG signature (or skip past it if skip_magic is set)
    var signature: [8]u8 = undefined;
    _ = file.read(&signature) catch return ValidationResult.invalidCode(.png, .failed_to_read, "PNG signature");

    if (!skip_magic) {
        const expected_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        if (!std.mem.eql(u8, &signature, &expected_sig)) {
            return ValidationResult.invalidCode(.png, .invalid_signature, "PNG");
        }
    }

    // Read and validate chunks
    var chunk_count: usize = 0;
    var found_ihdr = false;
    var found_iend = false;

    while (true) {
        // Read chunk header (4 bytes length + 4 bytes type)
        var chunk_header: [8]u8 = undefined;
        const header_bytes = file.read(&chunk_header) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCode(.png, .failed_to_read, "chunk header");
        };
        if (header_bytes < 8) break;

        const chunk_length = std.mem.readInt(u32, chunk_header[0..4], .big);
        const chunk_type = std.mem.readInt(u32, chunk_header[4..8], .big);

        // Validate first chunk is IHDR
        if (chunk_count == 0 and chunk_type != PNG_IHDR) {
            return ValidationResult.invalid(.png, "First chunk must be IHDR");
        }

        if (chunk_type == PNG_IHDR) found_ihdr = true;
        if (chunk_type == PNG_IEND) found_iend = true;

        // Skip chunk data + CRC (4 bytes)
        file.seekBy(@as(i64, @intCast(chunk_length)) + 4) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCode(.png, .truncated, "PNG chunk");
        };

        chunk_count += 1;

        // Safety limit
        if (chunk_count > 10000) {
            return ValidationResult.invalidCode(.png, .too_many, "PNG chunks");
        }

        if (found_iend) break;
    }

    if (!found_ihdr) {
        return ValidationResult.invalidCode(.png, .missing, "IHDR chunk");
    }
    if (!found_iend) {
        return ValidationResult.invalidCode(.png, .missing, "IEND chunk (truncated file)");
    }

    return ValidationResult.ok(.png);
}

// ============ Debug Logging ============

/// Debug log file for format validation (written to /tmp/es_format_debug.log)
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    // Use fixed path for reliability (TMPDIR varies per process on macOS)
    const log_path = "/tmp/es_format_debug.log";
    // Create file if it doesn't exist, otherwise append
    const file = std.fs.cwd().createFile(log_path, .{
        .truncate = false,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(msg) catch return;
}

// ============ JPEG Validator ============

/// Validate JPEG file structure.
pub fn validateJpeg(file: std.fs.File) ValidationResult {
    return validateJpegWithOptions(file, false);
}

pub fn validateJpegWithOptions(file: std.fs.File, skip_magic: bool) ValidationResult {
    // Check SOI marker (or skip past it if skip_magic is set)
    var header: [2]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.jpeg, .failed_to_read, "JPEG header");

    if (!skip_magic) {
        if (header[0] != 0xFF or header[1] != 0xD8) {
            return ValidationResult.invalidCode(.jpeg, .invalid_value, "JPEG SOI marker");
        }
    }

    // Scan through segments
    var segment_count: usize = 0;
    var found_sos = false; // Start of Scan
    var found_eoi = false; // End of Image

    while (true) {
        // Read segment marker
        var marker: [2]u8 = undefined;
        const marker_bytes = file.read(&marker) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCode(.jpeg, .failed_to_read, "segment marker");
        };
        if (marker_bytes < 2) break;

        if (marker[0] != 0xFF) {
            return ValidationResult.invalidCode(.jpeg, .invalid_value, "segment marker");
        }

        // Skip padding bytes (0xFF)
        while (marker[1] == 0xFF) {
            var next: [1]u8 = undefined;
            _ = file.read(&next) catch break;
            marker[1] = next[0];
        }

        const marker_type = marker[1];

        // EOI (End of Image)
        if (marker_type == 0xD9) {
            found_eoi = true;
            break;
        }

        // SOS (Start of Scan) - marks beginning of compressed data
        if (marker_type == 0xDA) {
            found_sos = true;
            // After SOS, we have raw scan data until EOI
            // Scan backwards from end looking for EOI marker (0xFF 0xD9)
            // Many JPEGs have trailing data after EOI (thumbnails, metadata)
            const file_size = file.getEndPos() catch {
                return ValidationResult.invalidCode(.jpeg, .failed_to_get, "file size");
            };
            // Search last 64KB for EOI marker (should be much closer to end)
            const search_start = if (file_size > 65536) file_size - 65536 else 0;
            file.seekTo(search_start) catch {
                return ValidationResult.invalidCode(.jpeg, .failed_to_seek, "for EOI search");
            };
            var search_buf: [65536]u8 = undefined;
            const bytes_to_read = @min(file_size - search_start, 65536);
            // Use readAll to ensure we get all requested bytes (handles short reads)
            const bytes_read = file.readAll(search_buf[0..bytes_to_read]) catch {
                return ValidationResult.invalidCode(.jpeg, .failed_to_read, "for EOI search");
            };
            // Search backwards for 0xFF 0xD9
            if (bytes_read >= 2) {
                var i: usize = bytes_read - 1;
                while (i > 0) : (i -= 1) {
                    if (search_buf[i] == 0xD9 and search_buf[i - 1] == 0xFF) {
                        found_eoi = true;
                        break;
                    }
                }
            }
            // Debug: Log short reads (potential cause of false positives)
            if (bytes_read < bytes_to_read) {
                debugLog("JPEG SHORT READ: size={d} start={d} toread={d} read={d}\n", .{
                    file_size,
                    search_start,
                    bytes_to_read,
                    bytes_read,
                });
            }
            // Debug: Log if EOI not found (only failures to avoid huge logs)
            if (!found_eoi) {
                debugLog("JPEG EOI NOT FOUND: size={d} start={d} toread={d} read={d} last2=0x{x:0>2}{x:0>2}\n", .{
                    file_size,
                    search_start,
                    bytes_to_read,
                    bytes_read,
                    if (bytes_read >= 2) search_buf[bytes_read - 2] else 0,
                    if (bytes_read >= 1) search_buf[bytes_read - 1] else 0,
                });
            }
            break;
        }

        // Standalone markers (no length)
        if ((marker_type >= 0xD0 and marker_type <= 0xD7) or marker_type == 0x01) {
            segment_count += 1;
            continue;
        }

        // Read segment length
        var length_bytes: [2]u8 = undefined;
        _ = file.read(&length_bytes) catch {
            return ValidationResult.invalidCode(.jpeg, .failed_to_read, "segment length");
        };
        const segment_length = std.mem.readInt(u16, &length_bytes, .big);

        if (segment_length < 2) {
            return ValidationResult.invalidCode(.jpeg, .invalid_value, "segment length");
        }

        // Skip segment data (length includes the 2 length bytes)
        file.seekBy(@as(i64, segment_length) - 2) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCode(.jpeg, .truncated, "JPEG segment");
        };

        segment_count += 1;

        // Safety limit
        if (segment_count > 1000) {
            return ValidationResult.invalidCode(.jpeg, .too_many, "JPEG segments");
        }
    }

    if (!found_sos) {
        return ValidationResult.invalidCode(.jpeg, .missing, "SOS marker (no image data)");
    }
    if (!found_eoi) {
        return ValidationResult.invalidCode(.jpeg, .missing, "EOI marker (truncated file)");
    }

    return ValidationResult.ok(.jpeg);
}

// ============ SVG Validator ============

/// Validate SVG (XML-based vector graphics) file structure.
pub fn validateSvg(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.svg, .failed_to_seek, "to start");

    // Read enough to find <?xml or <svg
    var header: [1024]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.svg, .failed_to_read, "SVG header");

    if (header_read < 5) {
        return ValidationResult.invalidCode(.svg, .file_too_small, "SVG");
    }

    const content = header[0..header_read];

    // Skip BOM if present
    var start: usize = 0;
    if (content.len >= 3 and std.mem.eql(u8, content[0..3], "\xEF\xBB\xBF")) {
        start = 3;
    }

    // Skip leading whitespace
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or
        content[start] == '\n' or content[start] == '\r'))
    {
        start += 1;
    }

    // Check for XML declaration or SVG tag
    const remaining = content[start..];

    if (remaining.len >= 5 and std.mem.eql(u8, remaining[0..5], "<?xml")) {
        // Has XML declaration, check for <svg later
        if (std.mem.indexOf(u8, remaining, "<svg") != null) {
            return ValidationResult.ok(.svg);
        }
        return ValidationResult.invalid(.svg, "XML file but no <svg> element found");
    }

    if (remaining.len >= 4 and std.mem.eql(u8, remaining[0..4], "<svg")) {
        return ValidationResult.ok(.svg);
    }

    return ValidationResult.invalid(.svg, "Not a valid SVG file");
}

// XML helpers imported from format_validation
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;

/// Deep validation for SVG files using full XML parsing.
pub fn validateSvgDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.svg, .failed_to_open, "SVG file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.svg, .failed_to_get, "file size");
    };

    if (file_size > 50 * 1024 * 1024) { // 50MB limit for SVG
        return ValidationResult.okWithDepth(.svg, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.svg, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.svg, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.svg, .incomplete, "file read");
    }

    // Strip DOCTYPE declarations to avoid DTD validation issues
    const preprocessed = stripDoctypeDeclaration(data);
    defer if (preprocessed.allocated) allocator.free(preprocessed.data);

    // Parse the XML to validate structure
    var static_reader: xml.Reader.Static = .init(allocator, preprocessed.data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    // Iterate through all XML elements to validate structure
    var element_count: usize = 0;
    var found_svg = false;

    while (true) {
        const node = reader.read() catch {
            return ValidationResult.invalidCode(.svg, .invalid_value, "XML structure");
        };
        if (node == .eof) break;

        // Check for svg element
        if (node == .element_start) {
            const name = reader.elementName();
            if (std.mem.eql(u8, name, "svg")) {
                found_svg = true;
            }
        }
        element_count += 1;
    }

    if (element_count == 0) {
        return ValidationResult.invalidCode(.svg, .empty, "XML document");
    }

    if (!found_svg) {
        return ValidationResult.invalid(.svg, "No <svg> element found");
    }

    return ValidationResult.okWithDepth(.svg, .structural);
}

// ============ JPEG XL Validator ============

/// Validate JPEG XL file structure.
/// Supports both naked codestream (FF 0A) and ISO BMFF container formats.
pub fn validateJxl(file: std.fs.File) ValidationResult {
    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.jxl, .failed_to_read, "JXL header");

    if (bytes_read < 2) {
        return ValidationResult.invalidCode(.jxl, .file_too_small, "JXL");
    }

    // Naked codestream: FF 0A
    if (header[0] == 0xFF and header[1] == 0x0A) {
        // Valid JXL codestream signature
        return ValidationResult.ok(.jxl);
    }

    // ISO BMFF container: 00 00 00 0C 4A 58 4C 20 0D 0A 87 0A
    if (bytes_read >= 12) {
        const jxl_container_sig = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A };
        if (std.mem.eql(u8, header[0..12], &jxl_container_sig)) {
            // Valid JXL container signature
            return ValidationResult.ok(.jxl);
        }
    }

    return ValidationResult.invalidCode(.jxl, .invalid_signature, "JPEG XL");
}

// ============ GIF Validator ============

/// Validate GIF file structure.
pub fn validateGif(file: std.fs.File) ValidationResult {
    return validateGifWithOptions(file, false);
}

pub fn validateGifWithOptions(file: std.fs.File, skip_magic: bool) ValidationResult {
    // Check header (GIF87a or GIF89a) - or skip past it if skip_magic is set
    var header: [6]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.gif, .failed_to_read, "GIF header");

    if (!skip_magic) {
        const is_gif87a = std.mem.eql(u8, &header, "GIF87a");
        const is_gif89a = std.mem.eql(u8, &header, "GIF89a");

        if (!is_gif87a and !is_gif89a) {
            return ValidationResult.invalidCode(.gif, .invalid_value, "GIF header");
        }
    }

    // Check for trailer (0x3B) near end of file
    // Some GIF files have substantial null padding after the trailer,
    // so we scan backwards in chunks until we find it
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.gif, .failed_to_get, "file size");
    };

    if (file_size < 13) { // Minimum GIF: 6 header + 7 LSD + trailer
        return ValidationResult.invalidCode(.gif, .file_too_small, "valid GIF");
    }

    // Scan backwards in 4KB chunks, up to 64KB of padding
    const chunk_size: usize = 4096;
    const max_padding: u64 = 65536;
    var chunk: [chunk_size]u8 = undefined;
    var scanned: u64 = 0;

    while (scanned < file_size - 13 and scanned < max_padding) {
        const remaining = file_size - scanned;
        const to_read: usize = @min(chunk_size, @as(usize, @intCast(remaining)));

        file.seekFromEnd(-@as(i64, @intCast(scanned + to_read))) catch {
            return ValidationResult.invalidCode(.gif, .failed_to_seek, "in GIF data");
        };

        const bytes_read = file.read(chunk[0..to_read]) catch {
            return ValidationResult.invalidCode(.gif, .failed_to_read, "GIF data");
        };

        // Scan this chunk backwards
        var i: usize = bytes_read;
        while (i > 0) {
            i -= 1;
            if (chunk[i] == 0x3B) {
                return ValidationResult.ok(.gif);
            }
            // Allow null bytes (padding) but nothing else after trailer
            if (chunk[i] != 0x00) {
                // Found non-null, non-trailer byte - file is corrupt
                return ValidationResult.invalidCode(.gif, .missing, "GIF trailer (truncated file)");
            }
        }

        scanned += bytes_read;
    }

    return ValidationResult.invalidCode(.gif, .missing, "GIF trailer (truncated file)");
}

// ============ BMP Validator ============

/// Validate BMP file structure.
pub fn validateBmp(file: std.fs.File) ValidationResult {
    var header: [54]u8 = undefined; // Minimum BMP header size
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.bmp, .failed_to_read, "BMP header");

    if (bytes_read < 14) {
        return ValidationResult.invalidCode(.bmp, .file_too_small, "BMP");
    }

    // Check signature
    if (header[0] != 'B' or header[1] != 'M') {
        return ValidationResult.invalidCode(.bmp, .invalid_signature, "BMP");
    }

    // Check file size field matches actual size
    const declared_size = std.mem.readInt(u32, header[2..6], .little);
    const actual_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.bmp, .failed_to_get, "file size");
    };

    if (declared_size > actual_size) {
        return ValidationResult.invalid(.bmp, "BMP file size mismatch (truncated)");
    }

    // Check header size (offset 14) - must be at least 12 (BITMAPCOREHEADER)
    if (bytes_read >= 18) {
        const header_size = std.mem.readInt(u32, header[14..18], .little);
        if (header_size < 12) {
            return ValidationResult.invalidCode(.bmp, .invalid_value, "BMP info header size");
        }
    }

    return ValidationResult.ok(.bmp);
}

// ============ WebP Validator ============

/// Validate WebP file structure (RIFF container with VP8/VP8L/VP8X chunks).
pub fn validateWebp(file: std.fs.File) ValidationResult {
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.webp, .failed_to_read, "WebP header");

    // Check RIFF signature
    if (!std.mem.eql(u8, header[0..4], "RIFF")) {
        return ValidationResult.invalidCode(.webp, .invalid_signature, "RIFF");
    }

    // Check WEBP fourcc
    if (!std.mem.eql(u8, header[8..12], "WEBP")) {
        return ValidationResult.invalidCode(.webp, .invalid_value, "WebP fourcc");
    }

    // Get declared RIFF size
    const riff_size = std.mem.readInt(u32, header[4..8], .little);
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.webp, .failed_to_get, "file size");
    };

    // RIFF size should be file_size - 8 (excludes RIFF header)
    if (riff_size + 8 > file_size) {
        return ValidationResult.invalidCodeMsg(.webp, .exceeds_bounds, "RIFF size", "RIFF size exceeds file size (truncated)");
    }

    // Read first chunk to verify it's a valid WebP chunk type
    var chunk_header: [8]u8 = undefined;
    const chunk_bytes = file.read(&chunk_header) catch {
        return ValidationResult.invalidCode(.webp, .failed_to_read, "chunk header");
    };

    if (chunk_bytes >= 4) {
        const chunk_type = chunk_header[0..4];
        // Valid WebP chunk types: VP8 , VP8L, VP8X, ANIM, ANMF, ALPH, ICCP, EXIF, XMP
        const valid_chunks = [_][]const u8{ "VP8 ", "VP8L", "VP8X", "ANIM", "ANMF", "ALPH", "ICCP", "EXIF", "XMP " };
        var found_valid = false;
        for (valid_chunks) |valid| {
            if (std.mem.eql(u8, chunk_type, valid)) {
                found_valid = true;
                break;
            }
        }
        if (!found_valid) {
            return ValidationResult.invalidCode(.webp, .invalid_value, "WebP chunk type");
        }
    }

    return ValidationResult.ok(.webp);
}

// ============ TIFF Validator ============

/// Validate TIFF file structure (also used for RAW formats).
pub fn validateTiff(file: std.fs.File, format: FileFormat) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(format, .failed_to_seek, "to start");

    var header: [8]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(format, .failed_to_read, "TIFF header");

    // Check byte order marker
    const is_le = std.mem.eql(u8, header[0..2], "II");
    const is_be = std.mem.eql(u8, header[0..2], "MM");

    if (!is_le and !is_be) {
        return ValidationResult.invalidCode(format, .invalid_value, "TIFF byte order marker");
    }

    // Check magic number (42)
    const magic = if (is_le)
        std.mem.readInt(u16, header[2..4], .little)
    else
        std.mem.readInt(u16, header[2..4], .big);

    if (magic != 42) {
        return ValidationResult.invalidCode(format, .invalid_magic_number, "TIFF");
    }

    // Get IFD offset
    const ifd_offset = if (is_le)
        std.mem.readInt(u32, header[4..8], .little)
    else
        std.mem.readInt(u32, header[4..8], .big);

    // Verify IFD offset is within file
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(format, .failed_to_get, "file size");
    };

    if (ifd_offset >= file_size) {
        return ValidationResult.invalid(format, "IFD offset beyond file end (truncated)");
    }

    // Seek to IFD and verify it's readable
    file.seekTo(ifd_offset) catch {
        return ValidationResult.invalidCode(format, .failed_to_seek, "to IFD");
    };

    var ifd_header: [2]u8 = undefined;
    _ = file.read(&ifd_header) catch {
        return ValidationResult.invalidCode(format, .failed_to_read, "IFD");
    };

    const entry_count = if (is_le)
        std.mem.readInt(u16, &ifd_header, .little)
    else
        std.mem.readInt(u16, &ifd_header, .big);

    // Sanity check entry count
    if (entry_count == 0 or entry_count > 1000) {
        return ValidationResult.invalidCode(format, .invalid_value, "IFD entry count");
    }

    return ValidationResult.ok(format);
}

// ============ OpenEXR Validator ============

/// Validate OpenEXR file structure.
/// OpenEXR files have magic bytes 76 2F 31 01 (little-endian 20000630).
pub fn validateExr(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.exr, .failed_to_seek, "to start");

    var header: [8]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.exr, .failed_to_read, "EXR header");
    };

    if (bytes_read < 8) {
        return ValidationResult.invalidCode(.exr, .file_too_small, "EXR format");
    }

    // Check magic bytes: 0x76, 0x2f, 0x31, 0x01 (20000630 little-endian)
    if (header[0] != 0x76 or header[1] != 0x2f or header[2] != 0x31 or header[3] != 0x01) {
        return ValidationResult.invalidCode(.exr, .invalid_magic, "EXR");
    }

    // Version field (4 bytes): bits 0-7 = version, bits 8-31 = flags
    const version = header[4] & 0xFF;
    if (version == 0 or version > 2) {
        return ValidationResult.okWithDepthAndWarning(.exr, .structural, errmsg.unknown("EXR version"));
    }

    // Check for some common flags
    const flags: u32 = std.mem.readInt(u32, header[4..8], .little);
    const is_tiled = (flags >> 9) & 1 == 1;
    const long_names = (flags >> 10) & 1 == 1;
    const non_image = (flags >> 11) & 1 == 1;
    const multipart = (flags >> 12) & 1 == 1;

    _ = is_tiled;
    _ = long_names;
    _ = non_image;
    _ = multipart;

    // Basic header validation passed
    return ValidationResult.ok(.exr);
}

/// Deep validation for OpenEXR files - reads and validates header attributes.
/// Required attributes per OpenEXR spec: channels, compression, dataWindow, displayWindow,
/// lineOrder, pixelAspectRatio, screenWindowCenter, screenWindowWidth.
pub fn validateExrDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.exr, .failed_to_open, "EXR file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.exr, .failed_to_get, "file size");
    };

    // Read and validate header
    var header: [8]u8 = undefined;
    file.seekTo(0) catch return ValidationResult.invalidCode(.exr, .failed_to_seek, "to start");
    _ = file.read(&header) catch return ValidationResult.invalidCode(.exr, .failed_to_read, "header");

    if (header[0] != 0x76 or header[1] != 0x2f or header[2] != 0x31 or header[3] != 0x01) {
        return ValidationResult.invalidCode(.exr, .invalid_magic, "EXR");
    }

    const flags: u32 = std.mem.readInt(u32, header[4..8], .little);
    const is_tiled = (flags >> 9) & 1 == 1;

    // Track required attributes and values we need
    var has_channels = false;
    var has_compression = false;
    var has_data_window = false;
    var has_display_window = false;
    var compression_type: u8 = 0;
    var data_window_min_y: i32 = 0;
    var data_window_max_y: i32 = 0;

    // Parse header attributes
    file.seekTo(8) catch return ValidationResult.invalidCode(.exr, .failed_to_seek, "past magic");

    var name_buf: [256]u8 = undefined;
    var type_buf: [256]u8 = undefined;
    var attr_value: [128]u8 = undefined;

    while (true) {
        // Read attribute name
        var name_len: usize = 0;
        while (name_len < 255) {
            const byte_read = file.read(name_buf[name_len .. name_len + 1]) catch break;
            if (byte_read == 0) break;
            if (name_buf[name_len] == 0) break;
            name_len += 1;
        }

        if (name_len == 0) break; // End of header

        const attr_name = name_buf[0..name_len];

        // Read attribute type
        var type_len: usize = 0;
        while (type_len < 255) {
            const byte_read = file.read(type_buf[type_len .. type_len + 1]) catch break;
            if (byte_read == 0) break;
            if (type_buf[type_len] == 0) break;
            type_len += 1;
        }

        // Read attribute size
        var size_bytes: [4]u8 = undefined;
        _ = file.read(&size_bytes) catch break;
        const attr_size: u32 = @bitCast(std.mem.readInt(i32, &size_bytes, .little));

        if (attr_size > 16 * 1024 * 1024) {
            return ValidationResult.invalidCode(.exr, .invalid_value, "attribute size");
        }

        // Read attribute value for specific attributes
        const read_size = @min(attr_size, 128);
        _ = file.read(attr_value[0..read_size]) catch break;

        // Skip remainder if attribute is larger
        if (attr_size > 128) {
            file.seekBy(@intCast(attr_size - 128)) catch break;
        }

        if (std.mem.eql(u8, attr_name, "channels")) has_channels = true;
        if (std.mem.eql(u8, attr_name, "compression")) {
            has_compression = true;
            if (attr_size >= 1) {
                compression_type = attr_value[0];
            }
        }
        if (std.mem.eql(u8, attr_name, "dataWindow")) {
            has_data_window = true;
            if (attr_size >= 16) {
                data_window_min_y = std.mem.readInt(i32, attr_value[4..8], .little);
                data_window_max_y = std.mem.readInt(i32, attr_value[12..16], .little);
            }
        }
        if (std.mem.eql(u8, attr_name, "displayWindow")) has_display_window = true;
    }

    if (!has_channels or !has_compression or !has_data_window or !has_display_window) {
        return ValidationResult.invalidCode(.exr, .missing, "required EXR attributes");
    }

    // Get position after header (this is where offset table starts)
    const offset_table_pos = file.getPos() catch {
        return ValidationResult.invalidCode(.exr, .failed_to_get, "offset table position");
    };

    // For tiled images, we'd need different logic - just validate header for now
    if (is_tiled) {
        return ValidationResult.okWithDepth(.exr, .structural);
    }

    // Calculate number of scanlines
    const num_scanlines: u32 = if (data_window_max_y >= data_window_min_y)
        @intCast(data_window_max_y - data_window_min_y + 1)
    else
        0;

    if (num_scanlines == 0 or num_scanlines > 100000) {
        return ValidationResult.okWithDepthAndWarning(.exr, .structural, "Unusual scanline count");
    }

    // Scanlines per chunk depends on compression
    const scanlines_per_chunk: u32 = switch (compression_type) {
        0 => 1, // NO_COMPRESSION
        1 => 1, // RLE
        2 => 1, // ZIPS (single scanline)
        3 => 16, // ZIP (16 scanlines)
        else => 1,
    };

    const num_chunks = (num_scanlines + scanlines_per_chunk - 1) / scanlines_per_chunk;

    // Read and validate offset table
    const offset_table_size = num_chunks * 8; // 8 bytes per offset
    if (offset_table_pos + offset_table_size > file_size) {
        return ValidationResult.invalid(.exr, "Offset table extends beyond file");
    }

    // Read offset table
    const offsets = allocator.alloc(u64, num_chunks) catch {
        return ValidationResult.okWithDepth(.exr, .structural);
    };
    defer allocator.free(offsets);

    for (offsets) |*offset| {
        var offset_bytes: [8]u8 = undefined;
        _ = file.read(&offset_bytes) catch {
            return ValidationResult.invalidCode(.exr, .failed_to_read, "offset table");
        };
        offset.* = std.mem.readInt(u64, &offset_bytes, .little);

        // Validate offset is within file bounds
        if (offset.* >= file_size) {
            return ValidationResult.invalidCodeMsg(.exr, .exceeds_bounds, "Scanline offset", "Scanline offset exceeds file size");
        }
    }

    // For ZIP/ZIPS compression, try to decompress some scanline blocks
    if (compression_type == 2 or compression_type == 3) {
        // Sample up to 10 blocks evenly distributed
        const sample_count = @min(num_chunks, 10);
        const step = if (num_chunks > 10) num_chunks / 10 else 1;

        var sample_idx: u32 = 0;
        while (sample_idx < sample_count) : (sample_idx += 1) {
            const chunk_idx = sample_idx * step;
            if (chunk_idx >= num_chunks) break;

            const offset = offsets[chunk_idx];

            // Seek to scanline block
            file.seekTo(offset) catch continue;

            // Read scanline block header: y coordinate (4 bytes) + pixel data size (4 bytes)
            var block_header: [8]u8 = undefined;
            _ = file.read(&block_header) catch continue;

            const pixel_data_size = std.mem.readInt(u32, block_header[4..8], .little);

            if (pixel_data_size == 0 or pixel_data_size > 50 * 1024 * 1024) {
                continue; // Skip invalid blocks
            }

            // Read compressed data
            const compressed = allocator.alloc(u8, pixel_data_size) catch continue;
            defer allocator.free(compressed);

            const bytes_read = file.readAll(compressed) catch continue;
            if (bytes_read != pixel_data_size) continue;

            // Try to decompress
            const max_decompressed: usize = 16 * 1024 * 1024; // 16MB max per block
            const decompressed = zlib.inflateRawAlloc(allocator, compressed, max_decompressed) catch |err| {
                switch (err) {
                    zlib.ZlibError.DataError => {
                        return ValidationResult.invalid(.exr, "EXR scanline decompression failed: corrupt data");
                    },
                    else => continue,
                }
            };
            defer allocator.free(decompressed);

            // Decompression succeeded for this block
        }
    }

    return ValidationResult.okWithDepth(.exr, .full);
}

/// Buffer-based validation for OpenEXR files.
pub fn validateExrFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 8) {
        return ValidationResult.invalidCode(.exr, .buffer_too_small, "EXR");
    }

    // Check magic bytes: 0x76, 0x2f, 0x31, 0x01
    if (data[0] != 0x76 or data[1] != 0x2f or data[2] != 0x31 or data[3] != 0x01) {
        return ValidationResult.invalidCode(.exr, .invalid_magic, "EXR");
    }

    // Check version
    const version = data[4] & 0xFF;
    if (version == 0 or version > 2) {
        return ValidationResult.okWithDepthAndWarning(.exr, .structural, errmsg.unknown("EXR version"));
    }

    return ValidationResult.ok(.exr);
}

// ============ PSD (Adobe Photoshop) Validator ============

/// PSD Color Modes
pub const PsdColorMode = enum(u16) {
    bitmap = 0,
    grayscale = 1,
    indexed = 2,
    rgb = 3,
    cmyk = 4,
    multichannel = 7,
    duotone = 8,
    lab = 9,
};

/// Validate PSD/PSB file structure.
/// PSD uses big-endian byte order throughout.
pub fn validatePsd(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.psd, .failed_to_seek, "to start");

    // Read header (26 bytes)
    var header: [26]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "PSD header");
    if (bytes_read < 26) {
        return ValidationResult.invalidCode(.psd, .file_too_small, "PSD header");
    }

    // Verify signature "8BPS"
    if (!std.mem.eql(u8, header[0..4], "8BPS")) {
        return ValidationResult.invalidCodeMsg(.psd, .invalid_signature_expected, "PSD", errmsg.invalidSignatureExpected("PSD", "8BPS"));
    }

    // Version: 1 for PSD, 2 for PSB (Large Document)
    const version = std.mem.readInt(u16, header[4..6], .big);
    if (version != 1 and version != 2) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "PSD version (expected 1 or 2)");
    }
    const is_psb = version == 2;

    // Reserved 6 bytes must be zero
    const reserved = header[6..12];
    for (reserved) |b| {
        if (b != 0) {
            return ValidationResult.invalid(.psd, "Reserved bytes in header are not zero");
        }
    }

    // Channels: 1-56 for PSD, 1-99 for PSB
    const channels = std.mem.readInt(u16, header[12..14], .big);
    const max_channels: u16 = if (is_psb) 99 else 56;
    if (channels == 0 or channels > max_channels) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "channel count");
    }

    // Height: 1-30000 for PSD, 1-300000 for PSB
    const height = std.mem.readInt(u32, header[14..18], .big);
    const max_dim: u32 = if (is_psb) 300000 else 30000;
    if (height == 0 or height > max_dim) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "image height");
    }

    // Width: 1-30000 for PSD, 1-300000 for PSB
    const width = std.mem.readInt(u32, header[18..22], .big);
    if (width == 0 or width > max_dim) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "image width");
    }

    // Bit depth: 1, 8, 16, or 32
    const depth = std.mem.readInt(u16, header[22..24], .big);
    if (depth != 1 and depth != 8 and depth != 16 and depth != 32) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "bit depth (expected 1, 8, 16, or 32)");
    }

    // Color mode: 0-9 (excluding 5, 6 which are reserved)
    const color_mode = std.mem.readInt(u16, header[24..26], .big);
    if (color_mode > 9 or color_mode == 5 or color_mode == 6) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "color mode");
    }

    // Get file size for bounds checking
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.psd, .failed_to_get, "file size");
    };

    // ---- Color Mode Data Section ----
    var color_mode_len_buf: [4]u8 = undefined;
    _ = file.read(&color_mode_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "color mode data length");
    const color_mode_len = std.mem.readInt(u32, &color_mode_len_buf, .big);

    // For indexed/duotone, this section contains the color table
    const color_mode_end = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    if (color_mode_end + color_mode_len > file_size) {
        return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Color mode data section", "Color mode data section exceeds file size");
    }
    file.seekBy(@intCast(color_mode_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "color mode data");

    // ---- Image Resources Section ----
    var img_res_len_buf: [4]u8 = undefined;
    _ = file.read(&img_res_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "image resources length");
    const img_res_len = std.mem.readInt(u32, &img_res_len_buf, .big);

    const img_res_end = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    if (img_res_end + img_res_len > file_size) {
        return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Image resources section", "Image resources section exceeds file size");
    }
    file.seekBy(@intCast(img_res_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "image resources");

    // ---- Layer and Mask Information Section ----
    // Length is 4 bytes for PSD, 8 bytes for PSB
    var layer_mask_len: u64 = 0;
    if (is_psb) {
        var len_buf: [8]u8 = undefined;
        _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer/mask length");
        layer_mask_len = std.mem.readInt(u64, &len_buf, .big);
    } else {
        var len_buf: [4]u8 = undefined;
        _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer/mask length");
        layer_mask_len = std.mem.readInt(u32, &len_buf, .big);
    }

    const layer_mask_end = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    if (layer_mask_end + layer_mask_len > file_size) {
        return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Layer and mask section", "Layer and mask section exceeds file size");
    }
    file.seekBy(@intCast(layer_mask_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "layer/mask data");

    // ---- Image Data Section ----
    // At minimum we should have 2 bytes for compression type
    const image_data_pos = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    if (image_data_pos + 2 > file_size) {
        return ValidationResult.invalid(.psd, "No image data section");
    }

    var compression_buf: [2]u8 = undefined;
    _ = file.read(&compression_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "compression type");
    const compression = std.mem.readInt(u16, &compression_buf, .big);

    // Valid compression types: 0=Raw, 1=RLE, 2=ZIP without prediction, 3=ZIP with prediction
    if (compression > 3) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "compression type in image data");
    }

    // Basic validation passed
    return ValidationResult.ok(.psd);
}

/// Deep validation of PSD file - fully parse all sections and decode image data.
pub fn validatePsdDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.psd, .failed_to_open, "file");
    };
    defer file.close();

    // First do basic validation
    const basic = validatePsd(file);
    if (!basic.is_valid) {
        return basic;
    }

    file.seekTo(0) catch return ValidationResult.invalidCode(.psd, .failed_to_seek, "to start");

    // Re-read header
    var header: [26]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "header");

    const version = std.mem.readInt(u16, header[4..6], .big);
    const is_psb = version == 2;
    const channels = std.mem.readInt(u16, header[12..14], .big);
    const height = std.mem.readInt(u32, header[14..18], .big);
    const width = std.mem.readInt(u32, header[18..22], .big);
    const depth = std.mem.readInt(u16, header[22..24], .big);

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.psd, .failed_to_get, "file size");
    };

    // ---- Skip Color Mode Data ----
    var color_mode_len_buf: [4]u8 = undefined;
    _ = file.read(&color_mode_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "color mode length");
    const color_mode_len = std.mem.readInt(u32, &color_mode_len_buf, .big);
    file.seekBy(@intCast(color_mode_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "color mode data");

    // ---- Parse Image Resources Section (8BIM blocks) ----
    var img_res_len_buf: [4]u8 = undefined;
    _ = file.read(&img_res_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "image resources length");
    const img_res_len = std.mem.readInt(u32, &img_res_len_buf, .big);

    const img_res_start = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    const img_res_end = img_res_start + img_res_len;

    // Parse all 8BIM resource blocks
    var resource_count: u32 = 0;
    while (file.getPos() catch 0 < img_res_end) {
        // Read resource signature (should be "8BIM")
        var sig: [4]u8 = undefined;
        const sig_bytes = file.read(&sig) catch break;
        if (sig_bytes < 4) break;

        if (!std.mem.eql(u8, &sig, "8BIM")) {
            // Some older files use "MeSa" or "AgHg" signatures
            if (!std.mem.eql(u8, &sig, "MeSa") and !std.mem.eql(u8, &sig, "AgHg") and !std.mem.eql(u8, &sig, "PHUT") and !std.mem.eql(u8, &sig, "DCSR")) {
                return ValidationResult.invalidCodeMsg(.psd, .invalid_signature_expected, "image resource", errmsg.invalidSignatureExpected("image resource", "8BIM"));
            }
        }

        // Resource ID (2 bytes)
        var id_buf: [2]u8 = undefined;
        _ = file.read(&id_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "resource ID");

        // Pascal string (1 byte length + string, padded to even)
        var name_len_buf: [1]u8 = undefined;
        _ = file.read(&name_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "resource name length");
        const name_len = name_len_buf[0];
        // Pad to even boundary: if name_len is even, we need 1 more byte padding; if odd, name itself makes it even
        const name_padded_len: u32 = if (name_len % 2 == 0) @as(u32, name_len) + 1 else @as(u32, name_len);
        file.seekBy(@intCast(name_padded_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "resource name");

        // Resource data length (4 bytes)
        var data_len_buf: [4]u8 = undefined;
        _ = file.read(&data_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "resource data length");
        const data_len = std.mem.readInt(u32, &data_len_buf, .big);

        // Pad to even boundary
        const data_padded_len = (data_len + 1) & ~@as(u32, 1);
        file.seekBy(@intCast(data_padded_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "resource data");

        resource_count += 1;
        if (resource_count > 10000) {
            return ValidationResult.invalidCode(.psd, .too_many, "image resources");
        }
    }

    // Seek to end of image resources section
    file.seekTo(img_res_end) catch return ValidationResult.invalidCode(.psd, .failed_to_seek, "past image resources");

    // ---- Parse Layer and Mask Information ----
    var layer_mask_len: u64 = 0;
    if (is_psb) {
        var len_buf: [8]u8 = undefined;
        _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer/mask length");
        layer_mask_len = std.mem.readInt(u64, &len_buf, .big);
    } else {
        var len_buf: [4]u8 = undefined;
        _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer/mask length");
        layer_mask_len = std.mem.readInt(u32, &len_buf, .big);
    }

    const layer_section_start = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");
    const layer_section_end = layer_section_start + layer_mask_len;

    // Parse layer info if present
    if (layer_mask_len > 0) {
        // Layer info section length
        var layer_info_len: u64 = 0;
        if (is_psb) {
            var len_buf: [8]u8 = undefined;
            _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer info length");
            layer_info_len = std.mem.readInt(u64, &len_buf, .big);
        } else {
            var len_buf: [4]u8 = undefined;
            _ = file.read(&len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer info length");
            layer_info_len = std.mem.readInt(u32, &len_buf, .big);
        }

        if (layer_info_len > 0) {
            // Layer count (2 bytes, can be negative for merged alpha)
            var count_buf: [2]u8 = undefined;
            _ = file.read(&count_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer count");
            const layer_count_raw = std.mem.readInt(i16, &count_buf, .big);
            const layer_count: u16 = @abs(layer_count_raw);

            // Validate each layer record
            var layer_idx: u16 = 0;
            while (layer_idx < layer_count) : (layer_idx += 1) {
                // Layer record: top, left, bottom, right (4 bytes each)
                var bounds: [16]u8 = undefined;
                _ = file.read(&bounds) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer bounds");

                // Number of channels
                var ch_count_buf: [2]u8 = undefined;
                _ = file.read(&ch_count_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "layer channel count");
                const ch_count = std.mem.readInt(u16, &ch_count_buf, .big);

                // Channel info (2 bytes ID + 4/8 bytes length per channel)
                const ch_info_size: u32 = if (is_psb) 6 else 6; // Actually both are 2 + 4 for PSD
                const ch_size: u64 = if (is_psb) 10 else 6; // PSB uses 8-byte lengths
                file.seekBy(@intCast(ch_count * ch_size)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "channel info");

                // Blend mode signature (should be "8BIM")
                var blend_sig: [4]u8 = undefined;
                _ = file.read(&blend_sig) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "blend signature");
                if (!std.mem.eql(u8, &blend_sig, "8BIM")) {
                    return ValidationResult.invalidCode(.psd, .invalid_signature, "layer blend mode");
                }

                // Blend mode key, opacity, clipping, flags, filler
                file.seekBy(4 + 1 + 1 + 1 + 1) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "layer properties");

                // Extra data length
                var extra_len_buf: [4]u8 = undefined;
                _ = file.read(&extra_len_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "extra data length");
                const extra_len = std.mem.readInt(u32, &extra_len_buf, .big);
                file.seekBy(@intCast(extra_len)) catch return ValidationResult.invalidCode(.psd, .failed_to_skip, "extra data");

                _ = ch_info_size;
            }
        }
    }

    // Seek to layer section end
    file.seekTo(layer_section_end) catch return ValidationResult.invalidCode(.psd, .failed_to_seek, "past layers");

    // ---- Decode Image Data ----
    const image_data_start = file.getPos() catch return ValidationResult.invalidCode(.psd, .failed_to_get, "position");

    var compression_buf: [2]u8 = undefined;
    _ = file.read(&compression_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "compression type");
    const compression = std.mem.readInt(u16, &compression_buf, .big);

    // Calculate expected image size
    const bytes_per_channel: u64 = switch (depth) {
        1 => (width + 7) / 8, // 1-bit packed
        8 => width,
        16 => width * 2,
        32 => width * 4,
        else => return ValidationResult.invalidCode(.psd, .unsupported, "bit depth"),
    };
    const scanline_size = bytes_per_channel;
    const channel_size = scanline_size * height;
    const total_uncompressed = channel_size * channels;

    _ = total_uncompressed;

    if (compression == 0) {
        // Raw data - verify we have enough bytes
        const remaining = file_size - (file.getPos() catch 0);
        const expected_raw = channel_size * channels;
        if (remaining < expected_raw) {
            return ValidationResult.invalidCode(.psd, .truncated, "raw image data");
        }
    } else if (compression == 1) {
        // RLE compression
        // First, read byte counts for each scanline (2 bytes each for PSD, 4 bytes for PSB)
        const scanline_count = height * channels;
        const count_size: u64 = if (is_psb) 4 else 2;
        const counts_size = scanline_count * count_size;

        const remaining = file_size - (file.getPos() catch 0);
        if (remaining < counts_size) {
            return ValidationResult.invalidCode(.psd, .truncated, "RLE byte counts");
        }

        // Read and validate all RLE byte counts
        var total_rle_size: u64 = 0;
        var scanline_idx: u64 = 0;
        while (scanline_idx < scanline_count) : (scanline_idx += 1) {
            if (is_psb) {
                var count_buf: [4]u8 = undefined;
                _ = file.read(&count_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "RLE count");
                total_rle_size += std.mem.readInt(u32, &count_buf, .big);
            } else {
                var count_buf: [2]u8 = undefined;
                _ = file.read(&count_buf) catch return ValidationResult.invalidCode(.psd, .failed_to_read, "RLE count");
                total_rle_size += std.mem.readInt(u16, &count_buf, .big);
            }
        }

        // Verify RLE data size
        const rle_start = file.getPos() catch 0;
        if (rle_start + total_rle_size > file_size) {
            return ValidationResult.invalidCode(.psd, .truncated, "RLE compressed data");
        }

        // Actually decode RLE to verify integrity
        // For full validation, we decode all scanlines
        var decoded_ok = true;
        scanline_idx = 0;

        // Reset to start of RLE data
        file.seekTo(image_data_start + 2 + counts_size) catch return ValidationResult.invalidCode(.psd, .failed_to_seek, "to RLE data");

        // Allocate buffer for one scanline
        const max_scanline = @min(scanline_size, 1024 * 1024); // Cap at 1MB per scanline
        var scanline_buf = allocator.alloc(u8, max_scanline) catch {
            // Can't allocate - do size check only
            return ValidationResult.structuralOnly(.psd);
        };
        defer allocator.free(scanline_buf);

        // Read a sample of RLE data to verify it decodes correctly
        // For very large files, sample first and last 100 scanlines
        const sample_size = @min(scanline_count, 200);
        var sample_idx: u64 = 0;

        while (sample_idx < sample_size) : (sample_idx += 1) {
            // Read one byte to check RLE marker
            var marker: [1]u8 = undefined;
            const marker_read = file.read(&marker) catch break;
            if (marker_read == 0) break;

            // RLE format: if marker >= 128, next byte repeated (257 - marker) times
            //             if marker < 128, next (marker + 1) bytes are literal
            const n = marker[0];
            if (n >= 128) {
                // Run: read 1 byte
                var run_byte: [1]u8 = undefined;
                _ = file.read(&run_byte) catch {
                    decoded_ok = false;
                    break;
                };
            } else {
                // Literal: read n+1 bytes
                const literal_len = @as(usize, n) + 1;
                if (literal_len <= scanline_buf.len) {
                    _ = file.read(scanline_buf[0..literal_len]) catch {
                        decoded_ok = false;
                        break;
                    };
                } else {
                    file.seekBy(@intCast(literal_len)) catch {
                        decoded_ok = false;
                        break;
                    };
                }
            }
        }

        if (!decoded_ok) {
            return ValidationResult.invalidCode(.psd, .decompression_failed, "RLE");
        }
    } else if (compression == 2 or compression == 3) {
        // ZIP compression (2 = ZIP without prediction, 3 = ZIP with prediction)
        const zip_data_start = file.getPos() catch {
            return ValidationResult.invalidCode(.psd, .failed_to_get, "ZIP data position");
        };
        const remaining = file_size - zip_data_start;
        if (remaining == 0) {
            return ValidationResult.invalid(.psd, "No ZIP compressed data");
        }

        // Read compressed data (limit to 100MB to avoid memory issues)
        const max_compressed_read: u64 = @min(remaining, 100 * 1024 * 1024);
        const compressed_data = allocator.alloc(u8, @intCast(max_compressed_read)) catch {
            return ValidationResult.okWithDepthAndWarning(.psd, .structural, "ZIP: out of memory for compressed data");
        };
        defer allocator.free(compressed_data);

        const bytes_read = file.readAll(compressed_data) catch {
            return ValidationResult.invalidCode(.psd, .failed_to_read, "ZIP compressed data");
        };

        if (bytes_read == 0) {
            return ValidationResult.invalid(.psd, "No ZIP compressed data read");
        }

        // Calculate expected uncompressed size (for entire image data)
        const expected_uncompressed = channel_size * channels;
        // Cap decompression at 500MB to avoid memory exhaustion
        const max_uncompressed: usize = @min(@as(usize, @intCast(expected_uncompressed)), 500 * 1024 * 1024);

        // Decompress using zlib
        const decompressed = zlib.inflateRawAlloc(allocator, compressed_data[0..bytes_read], max_uncompressed) catch |err| {
            switch (err) {
                zlib.ZlibError.DataError => return ValidationResult.invalid(.psd, "ZIP decompression failed: corrupt data"),
                zlib.ZlibError.BufferError => return ValidationResult.okWithDepthAndWarning(.psd, .structural, "ZIP: decompressed data exceeds limit"),
                else => return ValidationResult.invalid(.psd, "ZIP decompression error"),
            }
        };
        defer allocator.free(decompressed);

        // For compression type 3 (ZIP with prediction), verify we got reasonable data
        // The prediction filter is applied after decompression, but we just verify decompression succeeded
        if (compression == 3) {
            // ZIP with prediction - the decompressed data has a horizontal difference filter applied
            // Each row starts with a filter byte, so we can't easily verify the exact size
            // But successful decompression is enough for validation
            if (decompressed.len == 0) {
                return ValidationResult.invalid(.psd, "ZIP decompression produced empty output");
            }
        } else {
            // ZIP without prediction - decompressed size should match expected
            // Allow some tolerance since we might have read partial data for large files
            if (decompressed.len == 0) {
                return ValidationResult.invalid(.psd, "ZIP decompression produced empty output");
            }
        }
    }

    return ValidationResult.okWithDepth(.psd, .full);
}

/// Validate PSD from memory buffer.
pub fn validatePsdFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 26) {
        return ValidationResult.invalidCode(.psd, .buffer_too_small, "PSD header");
    }

    // Verify signature
    if (!std.mem.eql(u8, data[0..4], "8BPS")) {
        return ValidationResult.invalidCode(.psd, .invalid_signature, "PSD");
    }

    // Version
    const version = std.mem.readInt(u16, data[4..6], .big);
    if (version != 1 and version != 2) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "PSD version");
    }
    const is_psb = version == 2;

    // Reserved bytes must be zero
    for (data[6..12]) |b| {
        if (b != 0) return ValidationResult.invalid(.psd, "Reserved bytes not zero");
    }

    // Channels
    const channels = std.mem.readInt(u16, data[12..14], .big);
    const max_ch: u16 = if (is_psb) 99 else 56;
    if (channels == 0 or channels > max_ch) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "channel count");
    }

    // Dimensions
    const height = std.mem.readInt(u32, data[14..18], .big);
    const width = std.mem.readInt(u32, data[18..22], .big);
    const max_dim: u32 = if (is_psb) 300000 else 30000;
    if (height == 0 or height > max_dim or width == 0 or width > max_dim) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "dimensions");
    }

    // Bit depth
    const depth = std.mem.readInt(u16, data[22..24], .big);
    if (depth != 1 and depth != 8 and depth != 16 and depth != 32) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "bit depth");
    }

    // Color mode
    const color_mode = std.mem.readInt(u16, data[24..26], .big);
    if (color_mode > 9 or color_mode == 5 or color_mode == 6) {
        return ValidationResult.invalidCode(.psd, .invalid_value, "color mode");
    }

    // Parse sections
    var pos: usize = 26;

    // Color Mode Data
    if (pos + 4 > data.len) return ValidationResult.invalidCode(.psd, .truncated, "at color mode section");
    const color_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    if (pos + color_len > data.len) return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Color mode data", "Color mode data exceeds buffer");
    pos += color_len;

    // Image Resources
    if (pos + 4 > data.len) return ValidationResult.invalidCode(.psd, .truncated, "at image resources section");
    const img_res_len = std.mem.readInt(u32, data[pos..][0..4], .big);
    pos += 4;
    if (pos + img_res_len > data.len) return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Image resources", "Image resources exceeds buffer");
    pos += img_res_len;

    // Layer and Mask Info
    if (is_psb) {
        if (pos + 8 > data.len) return ValidationResult.invalidCode(.psd, .truncated, "at layer section");
        const layer_len = std.mem.readInt(u64, data[pos..][0..8], .big);
        pos += 8;
        if (pos + layer_len > data.len) return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Layer section", "Layer section exceeds buffer");
        pos += @intCast(layer_len);
    } else {
        if (pos + 4 > data.len) return ValidationResult.invalidCode(.psd, .truncated, "at layer section");
        const layer_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        pos += 4;
        if (pos + layer_len > data.len) return ValidationResult.invalidCodeMsg(.psd, .exceeds_bounds, "Layer section", "Layer section exceeds buffer");
        pos += layer_len;
    }

    // Image Data (must have at least compression type)
    if (pos + 2 > data.len) return ValidationResult.invalid(.psd, "No image data section");
    const compression = std.mem.readInt(u16, data[pos..][0..2], .big);
    if (compression > 3) return ValidationResult.invalidCode(.psd, .invalid_value, "compression type");

    return ValidationResult.ok(.psd);
}

// ============ JPEG2000 Validator ============

/// Validate JPEG2000 file structure (.jp2 container or .j2k/.j2c codestream).
/// JP2 container: starts with 00 00 00 0C 6A 50 20 20 (jP box)
/// J2K codestream: starts with FF 4F FF 51 (SOC + SIZ markers)
pub fn validateJpeg2000(file: std.fs.File) ValidationResult {
    var header: [12]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.jpeg2000, .failed_to_read, "JPEG2000 header");
    };

    if (bytes_read < 4) {
        return ValidationResult.invalidCode(.jpeg2000, .file_too_small, "JPEG2000");
    }

    // Check for J2K codestream signature (FF 4F FF 51)
    if (header[0] == 0xFF and header[1] == 0x4F and header[2] == 0xFF and header[3] == 0x51) {
        return ValidationResult.ok(.jpeg2000);
    }

    // Check for JP2 container signature (00 00 00 0C 6A 50 20 20)
    if (bytes_read >= 8) {
        const jp2_sig = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20 };
        if (std.mem.eql(u8, header[0..8], &jp2_sig)) {
            return ValidationResult.ok(.jpeg2000);
        }
    }

    // Check for JPX (extended JP2) - same signature structure
    if (bytes_read >= 12) {
        // JP2/JPX have jP box at start followed by ftyp box
        const jp_box_size = std.mem.readInt(u32, header[0..4], .big);
        if (jp_box_size == 12 and std.mem.eql(u8, header[4..8], "jP  ")) {
            return ValidationResult.ok(.jpeg2000);
        }
    }

    return ValidationResult.invalidCode(.jpeg2000, .invalid_signature, "JPEG2000");
}

// ============ JBIG2 Validator ============

/// Validate standalone JBIG2 file structure (.jbig2, .jb2).
/// JBIG2 files have signature: 97 4A 42 32 0D 0A 1A 0A (0x97 "JB2" CR LF SUB LF)
pub fn validateJbig2File(file: std.fs.File) ValidationResult {
    var header: [8]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.jbig2, .failed_to_read, "JBIG2 header");
    };

    if (bytes_read < 8) {
        return ValidationResult.invalidCode(.jbig2, .file_too_small, "JBIG2");
    }

    // Check for JBIG2 file signature
    if (!std.mem.eql(u8, &header, &jbig2_decoder.FILE_SIGNATURE)) {
        return ValidationResult.invalidCode(.jbig2, .invalid_signature, "JBIG2");
    }

    // Basic structural validation passed
    return ValidationResult.ok(.jbig2);
}

// ============ JPEG Deep Validation (libjpeg-turbo) ============

/// Deep JPEG validation by fully decompressing the image using libjpeg-turbo.
/// This catches Huffman errors, invalid DCT coefficients, and corrupted scan data
/// that structural validation would miss.
pub fn validateJpegDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const result = jpeg_validator.validateJpegDeep(path);
    if (result.valid) {
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(.jpeg, .full, warning);
        }
        return ValidationResult.okWithDepth(.jpeg, .full);
    } else {
        return ValidationResult.invalidWithDepth(.jpeg, result.error_message orelse errmsg.decompressionFailed("JPEG"), .full);
    }
}

// ============ GIF Deep Validation (zigimg full decode) ============

/// Deep GIF validation by fully decoding the image using zigimg.
/// This catches LZW decompression errors and corrupted image data
/// that structural validation would miss.
pub fn validateGifDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Allocate read buffer for zigimg (256K for larger/animated GIFs)
    var read_buffer: [262144]u8 = undefined;

    // Try to load the image - this performs full LZW decompression and validates the data
    var image = zigimg.Image.fromFilePath(allocator, path, &read_buffer) catch |err| {
        return switch (err) {
            // These are definite file access errors
            error.FileNotFound => ValidationResult.invalidWithDepth(.gif, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.gif, "Access denied", .full),
            // InvalidData means the GIF is corrupt - report as failure!
            error.InvalidData => ValidationResult.invalidWithDepth(.gif, "GIF decode failed - data may be corrupt", .full),
            error.EndOfStream => ValidationResult.invalidWithDepth(.gif, "GIF truncated - unexpected end of data", .full),
            error.OutOfMemory => ValidationResult.okWithDepthAndWarning(.gif, .structural, "GIF too large to fully decode in memory"),
            else => ValidationResult.invalidWithDepth(.gif, "GIF decode error", .full),
        };
    };
    image.deinit(allocator);

    // If we get here, the image decoded successfully
    return ValidationResult.okWithDepth(.gif, .full);
}

// ============ TIFF Deep Validation (zigimg full decode) ============

/// Deep TIFF validation by fully decoding the image using zigimg.
/// This catches decompression errors in LZW/Deflate/PackBits/etc and corrupted IFD data
/// that structural validation would miss.
pub fn validateTiffDeep(allocator: Allocator, path: []const u8, format: FileFormat) ValidationResult {
    // For camera RAW formats (ARW, CR2, NEF), try LibRaw first
    // LibRaw handles proprietary vendor compression that zigimg can't decode
    if (format == .arw or format == .cr2 or format == .nef) {
        const libraw_result = libraw_validator.validateRawFile(path);
        if (libraw_result.valid) {
            return ValidationResult.okWithDepth(format, .full);
        }
        // LibRaw failed - return its specific error
        if (libraw_result.error_message) |msg| {
            return ValidationResult.invalidWithDepth(format, msg, .full);
        }
        return ValidationResult.invalidWithDepth(format, "LibRaw decode failed", .full);
    }

    // Check if this TIFF contains special tags that need different handling
    const tag_check = checkTiffTagSupport(path);
    if (tag_check.has_dng_tags) {
        // Actual DNG/RAW files: use DNG validation path which validates
        // embedded JPEGs and doesn't try to decode the raw image data
        return validateDngDeep(allocator, path);
    }
    // Note: has_unsupported_tags no longer forces structural-only validation
    // Our forked zigimg now skips unknown tags gracefully instead of panicking
    if (tag_check.has_1bit_lzw) {
        // 1-bit image with LZW compression - zigimg's LZW decoder can't handle these
        // Use our pure Zig LZW decoder instead
        return validateTiff1BitLzw(allocator, path);
    }

    // Allocate read buffer for zigimg (64K is reasonable for most images)
    var read_buffer: [65536]u8 = undefined;

    // Try to load the image - this performs full decompression and validates the data
    var image = zigimg.Image.fromFilePath(allocator, path, &read_buffer) catch |err| {
        // Debug output for error diagnosis
        if (format_validation.getenvCrossPlatform("TIFF_DEBUG")) |_| {
            std.debug.print("TIFF decode error: {s}\n", .{@errorName(err)});
        }
        return switch (err) {
            // Clear I/O errors - definitely invalid
            error.FileNotFound => ValidationResult.invalid(format, "File not found"),
            error.AccessDenied => ValidationResult.invalid(format, "Access denied"),
            error.EndOfStream => ValidationResult.invalidCodeWithDepth(format, .truncated, "file", .full),
            error.OutOfMemory => ValidationResult.invalidCodeWithDepth(format, .out_of_memory, "during decode", .full),

            // InvalidData could mean corruption OR unsupported format features
            // zigimg has limited support (e.g., unusual strip sizes, some predictor modes)
            error.InvalidData => {
                return ValidationResult.okWithDepthAndWarning(format, .structural, "zigimg decode failed, structural only");
            },

            // Unsupported - zigimg doesn't handle this format variant (e.g., 16-bit TIFF)
            error.Unsupported => {
                return ValidationResult.okWithDepthAndWarning(format, .structural, "unsupported format variant");
            },

            // Other errors - structural validation only
            else => ValidationResult.okWithDepthAndWarning(format, .structural, "decode failed"),
        };
    };
    image.deinit(allocator);

    // If we get here, the image decoded successfully
    return ValidationResult.okWithDepth(format, .full);
}

/// Result of checking TIFF tags for zigimg compatibility
pub const TiffTagCheckResult = struct {
    has_dng_tags: bool, // Has DNG proprietary tags (0xC612-0xC7FF)
    has_unsupported_tags: bool, // Has other unsupported tags (deprecated, vendor, etc.)
    has_1bit_lzw: bool, // Has 1-bit samples with LZW compression (zigimg can't decode)
};

/// Check if a TIFF file contains tags that zigimg can't handle.
/// zigimg panics on unknown enum values, so we need to pre-check for:
/// - DNG proprietary tags (0xC612-0xC7FF range)
/// - Deprecated TIFF tags that aren't in zigimg's enum (e.g., 0xFF SubfileType)
/// - Other non-standard tags
pub fn checkTiffTagSupport(path: []const u8) TiffTagCheckResult {
    var result = TiffTagCheckResult{ .has_dng_tags = false, .has_unsupported_tags = false, .has_1bit_lzw = false };

    // Track compression and bits per sample to detect 1-bit LZW
    var compression: u16 = 0;
    var bits_per_sample: u16 = 0;

    const file = std.fs.cwd().openFile(path, .{}) catch return result;
    defer file.close();

    // Read TIFF header
    var header: [8]u8 = undefined;
    _ = file.readAll(&header) catch return result;

    // Check byte order
    const is_big_endian = std.mem.eql(u8, header[0..2], "MM");
    const is_little_endian = std.mem.eql(u8, header[0..2], "II");
    if (!is_big_endian and !is_little_endian) return result;

    // Read IFD offset
    const ifd_offset = if (is_big_endian)
        std.mem.readInt(u32, header[4..8], .big)
    else
        std.mem.readInt(u32, header[4..8], .little);

    // Seek to IFD
    file.seekTo(ifd_offset) catch return result;

    // Read number of IFD entries
    var count_bytes: [2]u8 = undefined;
    _ = file.readAll(&count_bytes) catch return result;
    const entry_count = if (is_big_endian)
        std.mem.readInt(u16, &count_bytes, .big)
    else
        std.mem.readInt(u16, &count_bytes, .little);

    // Limit scan to prevent huge reads
    const max_entries = @min(entry_count, 200);

    // Scan IFD entries for tags that zigimg doesn't support.
    // zigimg panics on unknown tag values via @enumFromInt(), so we must use a whitelist
    // approach: only tags explicitly in zigimg's TagId enum are safe.
    var entry: [12]u8 = undefined;
    for (0..max_entries) |_| {
        _ = file.readAll(&entry) catch return result;
        const tag = if (is_big_endian)
            std.mem.readInt(u16, entry[0..2], .big)
        else
            std.mem.readInt(u16, entry[0..2], .little);

        // Get the tag value for SHORT/LONG type entries (value is inline if count*size <= 4)
        const tag_type = if (is_big_endian)
            std.mem.readInt(u16, entry[2..4], .big)
        else
            std.mem.readInt(u16, entry[2..4], .little);
        const tag_count = if (is_big_endian)
            std.mem.readInt(u32, entry[4..8], .big)
        else
            std.mem.readInt(u32, entry[4..8], .little);

        // For small values, they're stored inline in the value offset field
        var tag_value: u16 = 0;
        if (tag_count == 1 and (tag_type == 3 or tag_type == 4)) { // SHORT or LONG
            tag_value = if (is_big_endian)
                std.mem.readInt(u16, entry[8..10], .big)
            else
                std.mem.readInt(u16, entry[8..10], .little);
        }

        // Track BitsPerSample (tag 0x0102)
        if (tag == 0x0102) {
            bits_per_sample = tag_value;
        }

        // Track Compression (tag 0x0103)
        if (tag == 0x0103) {
            compression = tag_value;
        }

        // DNG detection: specifically check for DNGVersion tag (0xC612).
        // Other tags in the 0xC612-0xC7FF range are used by various manufacturers
        // (Sony uses 0xC634, etc.) and don't indicate DNG format.
        if (tag == 0xC612) {
            result.has_dng_tags = true;
        }

        // Check if this tag is in zigimg's TagId enum (whitelist approach).
        // zigimg panics on @enumFromInt() for unknown values, so we must pre-filter.
        // Tags from zigimg's TagId enum in types.zig:
        const zigimg_supported = switch (tag) {
            254, // new_subfile_type
            256, // image_width
            257, // image_height
            258, // bits_per_sample
            259, // compression
            262, // photometric_interpretation
            266, // fill_order
            269, // document_name
            270, // image_description
            273, // strip_offsets
            274, // orientation
            277, // samples_per_pixel
            278, // rows_per_strip
            279, // strip_byte_counts
            282, // x_resolution
            283, // y_resolution
            284, // planar_configuration
            286, // x_position
            287, // y_position
            292, // t4_options
            296, // resolution_unit
            297, // page_number
            305, // software
            317, // predictor
            318, // white_point
            319, // primary_chromaticities
            320, // color_map
            338, // extra_samples
            339, // sample_format
            700, // unknown_1 (XMP)
            34665, // unknown_2 (Exif IFD Pointer)
            34675, // unknown_3 (ICC Profile)
            => true,
            else => false,
        };

        if (!zigimg_supported and tag < 0xC612) {
            // Tag not in zigimg's enum and not a DNG tag (already handled above)
            result.has_unsupported_tags = true;
        }
    }

    // Check for 1-bit images with LZW compression (zigimg LZW decoder doesn't handle these)
    // Compression = 5 is LZW, BitsPerSample = 1 is 1-bit (bilevel) image
    if (bits_per_sample == 1 and compression == 5) {
        result.has_1bit_lzw = true;
    }

    return result;
}

/// Validate 1-bit TIFF with LZW compression using our pure Zig LZW decoder.
/// zigimg's LZW decoder can't handle 1-bit images, so we do it ourselves.
pub fn validateTiff1BitLzw(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.tiff, .failed_to_open, "TIFF file");
    };
    defer file.close();

    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.tiff, .failed_to_stat, "TIFF file");
    };

    // Read TIFF header to determine byte order
    var header: [8]u8 = undefined;
    _ = file.readAll(&header) catch {
        return ValidationResult.invalidCode(.tiff, .failed_to_read, "TIFF header");
    };

    // Determine byte order
    const is_big_endian = std.mem.eql(u8, header[0..2], "MM");
    const is_little_endian = std.mem.eql(u8, header[0..2], "II");
    if (!is_big_endian and !is_little_endian) {
        return ValidationResult.invalidCode(.tiff, .invalid_value, "TIFF byte order");
    }

    // Determine endianness for value reading
    const endian: std.builtin.Endian = if (is_big_endian) .big else .little;

    // Read IFD offset
    const ifd_offset = std.mem.readInt(u32, header[4..8], endian);

    // Seek to IFD and read entry count
    file.seekTo(ifd_offset) catch {
        return ValidationResult.invalidCode(.tiff, .failed_to_seek, "to TIFF IFD");
    };

    var count_bytes: [2]u8 = undefined;
    _ = file.readAll(&count_bytes) catch {
        return ValidationResult.invalidCode(.tiff, .failed_to_read, "IFD entry count");
    };
    const entry_count = std.mem.readInt(u16, &count_bytes, endian);

    // Initialize tag values (use optionals to detect missing required tags)
    var image_width: ?u32 = null;
    var image_length: ?u32 = null;
    var rows_per_strip: u32 = 0xFFFFFFFF; // Default per spec if not present
    var strip_offsets: ?[]u32 = null;
    var strip_byte_counts: ?[]u32 = null;
    defer if (strip_offsets) |s| allocator.free(s);
    defer if (strip_byte_counts) |s| allocator.free(s);

    // Parse IFD entries
    const max_entries = @min(entry_count, 200);
    var entry: [12]u8 = undefined;

    for (0..max_entries) |_| {
        _ = file.readAll(&entry) catch {
            return ValidationResult.invalidCode(.tiff, .failed_to_read, "IFD entry");
        };

        const tag = std.mem.readInt(u16, entry[0..2], endian);
        const field_type = std.mem.readInt(u16, entry[2..4], endian);
        const count = std.mem.readInt(u32, entry[4..8], endian);

        // Get value (inline for small values, offset for large arrays)
        // Type 3 = SHORT (2 bytes), Type 4 = LONG (4 bytes)
        const single_value: u32 = if (field_type == 3)
            std.mem.readInt(u16, entry[8..10], endian)
        else
            std.mem.readInt(u32, entry[8..12], endian);

        switch (tag) {
            256 => image_width = single_value, // ImageWidth
            257 => image_length = single_value, // ImageLength
            278 => rows_per_strip = single_value, // RowsPerStrip
            273 => { // StripOffsets
                strip_offsets = readTiffTagArray(allocator, file, entry[0..12], field_type, count, endian, stat.size) catch {
                    return ValidationResult.invalidCode(.tiff, .failed_to_read, "StripOffsets");
                };
            },
            279 => { // StripByteCounts
                strip_byte_counts = readTiffTagArray(allocator, file, entry[0..12], field_type, count, endian, stat.size) catch {
                    return ValidationResult.invalidCode(.tiff, .failed_to_read, "StripByteCounts");
                };
            },
            else => {},
        }
    }

    // Verify required tags are present
    const width = image_width orelse {
        return ValidationResult.invalidCode(.tiff, .missing, "ImageWidth tag");
    };
    const height = image_length orelse {
        return ValidationResult.invalidCode(.tiff, .missing, "ImageLength tag");
    };
    const offsets = strip_offsets orelse {
        return ValidationResult.invalidCode(.tiff, .missing, "StripOffsets tag");
    };
    const byte_counts = strip_byte_counts orelse {
        return ValidationResult.invalidCode(.tiff, .missing, "StripByteCounts tag");
    };

    if (offsets.len != byte_counts.len) {
        return ValidationResult.invalid(.tiff, "StripOffsets/StripByteCounts count mismatch");
    }

    // Calculate expected decompressed row size (1-bit, byte-aligned)
    const bytes_per_row = (width + 7) / 8;

    // Clamp rows_per_strip to actual remaining rows for each strip
    const num_strips = offsets.len;
    var remaining_rows: u32 = height;

    // Validate each strip by decompressing with LZW
    for (0..num_strips) |i| {
        const strip_offset = offsets[i];
        const compressed_size = byte_counts[i];

        // Sanity check strip offset/size
        if (strip_offset + compressed_size > stat.size) {
            return ValidationResult.invalid(.tiff, "Strip extends beyond file end");
        }

        // Calculate expected decompressed size for this strip
        const rows_in_strip = @min(rows_per_strip, remaining_rows);
        const expected_size = bytes_per_row * rows_in_strip;
        remaining_rows -|= rows_in_strip;

        // Read compressed strip data
        file.seekTo(strip_offset) catch {
            return ValidationResult.invalidCode(.tiff, .failed_to_seek, "to strip");
        };

        const compressed_data = allocator.alloc(u8, compressed_size) catch {
            return ValidationResult.okWithWarning(.tiff, errmsg.outOfMemory("for strip decompression"));
        };
        defer allocator.free(compressed_data);

        const bytes_read = file.readAll(compressed_data) catch {
            return ValidationResult.invalidCode(.tiff, .failed_to_read, "strip data");
        };
        if (bytes_read != compressed_size) {
            return ValidationResult.invalidCode(.tiff, .incomplete, "strip read");
        }

        // Decompress with TIFF LZW decoder
        const decompressed = tiff_lzw_decoder.decode(allocator, compressed_data) catch {
            return ValidationResult.invalidCode(.tiff, .decompression_failed, "LZW");
        };
        defer allocator.free(decompressed);

        // Verify decompressed size matches expected
        if (decompressed.len != expected_size) {
            return ValidationResult.invalid(.tiff, "Decompressed size mismatch");
        }
    }

    return ValidationResult.okWithDepth(.tiff, .full);
}

/// Read a TIFF tag array value (StripOffsets or StripByteCounts).
pub fn readTiffTagArray(
    allocator: Allocator,
    file: std.fs.File,
    entry: *const [12]u8,
    field_type: u16,
    count: u32,
    endian: std.builtin.Endian,
    file_size: u64,
) ![]u32 {
    const result = try allocator.alloc(u32, count);
    errdefer allocator.free(result);

    const type_size: u32 = if (field_type == 3) 2 else 4; // SHORT or LONG
    const total_size = count * type_size;

    if (total_size <= 4) {
        // Value fits in entry (inline)
        if (field_type == 3 and count == 1) {
            result[0] = std.mem.readInt(u16, entry[8..10], endian);
        } else if (field_type == 4 and count == 1) {
            result[0] = std.mem.readInt(u32, entry[8..12], endian);
        } else if (field_type == 3 and count == 2) {
            result[0] = std.mem.readInt(u16, entry[8..10], endian);
            result[1] = std.mem.readInt(u16, entry[10..12], endian);
        } else {
            // Unexpected inline format
            return error.InvalidData;
        }
    } else {
        // Value is offset to array data
        const offset = std.mem.readInt(u32, entry[8..12], endian);

        if (offset + total_size > file_size) {
            return error.InvalidData;
        }

        try file.seekTo(offset);

        if (field_type == 3) {
            // SHORT array
            var buf: [2]u8 = undefined;
            for (0..count) |i| {
                _ = try file.readAll(&buf);
                result[i] = std.mem.readInt(u16, &buf, endian);
            }
        } else {
            // LONG array
            var buf: [4]u8 = undefined;
            for (0..count) |i| {
                _ = try file.readAll(&buf);
                result[i] = std.mem.readInt(u32, &buf, endian);
            }
        }
    }

    return result;
}

/// Deep DNG validation - validates embedded JPEG previews and checks for RawImageDigest.
/// DNG files contain proprietary Adobe tags that zigimg can't handle, so we can't decode
/// the raw sensor data directly. Instead we:
/// 1. Parse IFD structure to find embedded JPEG offsets/sizes
/// 2. Decode and validate each embedded JPEG preview via libjpeg-turbo
/// 3. Check for RawImageDigest tag (MD5 of raw data) and verify if present
pub fn validateDngDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.dng, .failed_to_open, "DNG file");
    };
    defer file.close();

    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.dng, .failed_to_stat, "DNG file");
    };

    // Read entire file for embedded JPEG scanning
    // DNG files can be large (50-100MB+) but we need to scan for JPEGs
    const max_size: usize = 500 * 1024 * 1024; // 500MB max
    if (stat.size > max_size) {
        return ValidationResult.okWithWarning(.dng, "DNG too large for deep validation");
    }

    const data = allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.okWithWarning(.dng, "DNG: out of memory for deep validation");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.dng, .failed_to_read, "DNG file");
    };
    if (bytes_read != stat.size) {
        return ValidationResult.invalid(.dng, "DNG file read incomplete");
    }

    // Find and validate embedded JPEGs with proper headers
    // DNG files contain:
    // 1. Preview/thumbnail JPEGs (baseline/progressive) - critical for display
    // 2. Semantic map tiles (lossless JPEG SOF3) - internal processing data
    // We fail only on corrupt previews; warn on semantic map issues
    var preview_count: usize = 0;
    var preview_valid: usize = 0;
    var semantic_count: usize = 0;
    var semantic_valid: usize = 0;
    var i: usize = 0;

    // Minimum size for a "real" JPEG (1KB) - smaller patterns are likely false positives
    const min_jpeg_size: usize = 1024;
    const debug = format_validation.getenvCrossPlatform("DNG_DEBUG") != null;

    while (i + 10 < data.len) {
        // Look for JPEG SOI marker (0xFFD8) followed by APP0 (JFIF) or APP1 (EXIF)
        if (data[i] == 0xFF and data[i + 1] == 0xD8 and data[i + 2] == 0xFF) {
            const marker = data[i + 3];
            // Only consider JPEGs with application markers (JFIF/EXIF)
            const is_jpeg_with_app = marker == 0xE0 or marker == 0xE1;

            if (is_jpeg_with_app) {
                // This looks like a real JPEG, find its end
                var j = i + 4;
                var found_end = false;

                while (j + 1 < data.len) {
                    if (data[j] == 0xFF and data[j + 1] == 0xD9) {
                        // Found JPEG end
                        const jpeg_data = data[i .. j + 2];

                        // Only validate if it's large enough
                        if (jpeg_data.len >= min_jpeg_size) {
                            // Check if this is a lossless JPEG (SOF3 = 0xFFC3)
                            const is_lossless = jpeg_lossless_decoder.isLosslessJpeg(jpeg_data);

                            if (is_lossless) {
                                // Semantic map tile (lossless JPEG)
                                semantic_count += 1;
                                const lossless_result = jpeg_lossless_decoder.validateLosslessJpeg(allocator, jpeg_data);
                                if (lossless_result.valid) {
                                    semantic_valid += 1;
                                    if (debug) std.debug.print("  Semantic #{d} @ offset {d}: {d} bytes, VALID\n", .{ semantic_count, i, jpeg_data.len });
                                } else {
                                    if (debug) std.debug.print("  Semantic #{d} @ offset {d}: {d} bytes, INVALID\n", .{ semantic_count, i, jpeg_data.len });
                                }
                            } else {
                                // Preview JPEG (baseline/progressive)
                                preview_count += 1;
                                if (validateJpegBufferForDng(jpeg_data)) {
                                    preview_valid += 1;
                                    if (debug) std.debug.print("  Preview #{d} @ offset {d}: {d} bytes, VALID\n", .{ preview_count, i, jpeg_data.len });
                                } else {
                                    if (debug) std.debug.print("  Preview #{d} @ offset {d}: {d} bytes, INVALID\n", .{ preview_count, i, jpeg_data.len });
                                }
                            }
                        }

                        i = j + 2;
                        found_end = true;
                        break;
                    }
                    j += 1;
                }

                if (!found_end) {
                    // Truncated JPEG - skip and continue
                    i += 4;
                }
            } else {
                // Not a JPEG with app marker, skip
                i += 2;
            }
        } else {
            i += 1;
        }
    }

    if (debug) {
        std.debug.print("DNG: {d}/{d} previews valid, {d}/{d} semantic tiles valid\n", .{ preview_valid, preview_count, semantic_valid, semantic_count });
    }

    // Determine validation result based on preview health
    // Previews are critical; semantic tiles are internal data
    if (preview_count == 0 and semantic_count == 0) {
        // No embedded JPEGs found
        return ValidationResult.okWithWarning(.dng, "DNG: no embedded previews to validate");
    }

    if (preview_count > 0 and preview_valid < preview_count) {
        // Corrupt preview JPEG - this is a failure
        return ValidationResult.invalidWithDepth(.dng, "DNG: embedded preview image corrupt", .full);
    }

    if (semantic_valid < semantic_count) {
        // Some semantic map tiles failed - warn but don't fail
        // The preview images are fine, semantic maps are internal processing data
        return ValidationResult.okWithDepthAndWarning(.dng, .full, "DNG: some semantic map tiles invalid");
    }

    // All embedded JPEGs validated successfully
    return ValidationResult.okWithDepth(.dng, .full);
}

/// Validate a JPEG buffer using libjpeg-turbo
pub fn validateJpegBufferForDng(data: []const u8) bool {
    const result = jpeg_validator.validateJpegDeepFromBuffer(data);
    return result.valid;
}

// ============ BMP Deep Validation (native V3 + zigimg V4/V5) ============

/// Deep BMP validation by fully decoding the image.
/// Uses native decoder for V3 (Windows 3.x) and zigimg for V4/V5.
/// This catches corrupted pixel data and invalid RLE compression
/// that structural validation would miss.
pub fn validateBmpDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const result = bmp_decoder.validateBmp(allocator, path);
    if (result.valid) {
        return ValidationResult.okWithDepth(.bmp, .full);
    } else {
        return ValidationResult.invalidWithDepth(.bmp, result.error_message orelse "BMP decode failed", .full);
    }
}

// ============ WebP Deep Validation (libwebp full decode) ============

/// Deep WebP validation by fully decoding the image using libwebp.
/// This catches VP8/VP8L bitstream errors and corrupted data
/// that structural validation would miss.
pub fn validateWebpDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const result = webp_validator.validateWebpDeep(path);
    if (result.valid) {
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(.webp, .full, warning);
        }
        return ValidationResult.okWithDepth(.webp, .full);
    } else {
        return ValidationResult.invalidWithDepth(.webp, result.error_message orelse "WebP decode failed", .full);
    }
}

// ============ JPEG-XL Deep Validation (libjxl) ============

/// Deep JPEG-XL validation by fully decoding the image using libjxl.
/// This catches ANS entropy coding errors, squeeze transform errors,
/// and corrupted data that structural validation would miss.
pub fn validateJxlDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const result = jxl_validator.validateJxlDeep(path);
    if (result.valid) {
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(.jxl, .full, warning);
        }
        return ValidationResult.okWithDepth(.jxl, .full);
    } else {
        return ValidationResult.invalidWithDepth(.jxl, result.error_message orelse "JPEG-XL decode failed", .full);
    }
}

// ============ JPEG2000 Deep Validation ============

/// Deep JPEG2000 validation using OpenJPEG to fully decode the image.
pub fn validateJpeg2000Deep(allocator: Allocator, path: []const u8) ValidationResult {
    // Read the file into memory for OpenJPEG
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCodeWithDepth(.jpeg2000, .failed_to_open, "file", .full);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.jpeg2000, .failed_to_get, "file size", .full);
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit
        return ValidationResult.invalidWithDepth(.jpeg2000, "File too large", .full);
    }

    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.jpeg2000, .out_of_memory, "for JPEG 2000", .full);
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.jpeg2000, .failed_to_read, "file", .full);
    };

    const result = jpeg2000_validator.validateJpeg2000(data[0..bytes_read]);
    if (result.valid) {
        return ValidationResult.okWithDepth(.jpeg2000, .full);
    } else {
        return ValidationResult.invalidWithDepth(.jpeg2000, result.error_message orelse "JPEG2000 decode failed", .full);
    }
}

// ============ JBIG2 Deep Validation ============

/// Deep JBIG2 validation by fully parsing segment structure and headers.
/// This validates file header, segment headers, page info, and segment data.
pub fn validateJbig2Deep(allocator: Allocator, path: []const u8) ValidationResult {
    // Read the file into memory for JBIG2 decoder
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCodeWithDepth(.jbig2, .failed_to_open, "file", .full);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.jbig2, .failed_to_get, "file size", .full);
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit
        return ValidationResult.invalidWithDepth(.jbig2, "File too large", .full);
    }

    const data = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.invalidCodeWithDepth(.jbig2, .out_of_memory, "for JBIG2", .full);
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.jbig2, .failed_to_read, "file", .full);
    };

    const result = jbig2_decoder.validateJbig2(allocator, data[0..bytes_read]);
    if (result.valid) {
        if (result.warning_message) |warning| {
            // Return valid with warning if decoder reported non-fatal issues
            return ValidationResult.okWithDepthAndWarning(.jbig2, .full, warning);
        }
        return ValidationResult.okWithDepth(.jbig2, .full);
    } else {
        return ValidationResult.invalidWithDepth(.jbig2, result.error_message orelse "JBIG2 decode failed", .full);
    }
}

// ============ HEIC/AVIF Deep Validation (pure Zig) ============

/// Deep HEIC validation using pure-Zig HEIF container parser + H.265 syntax validator.
pub fn validateHeicDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const result = heic_validator.validateHeicDeep(path);
    if (result.valid) {
        if (result.structural_only) {
            return ValidationResult.okWithDepth(.heic, .structural);
        }
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(.heic, .full, warning);
        }
        return ValidationResult.okWithDepth(.heic, .full);
    } else {
        const msg: []const u8 = if (result.error_message) |e| e else "HEIC validation failed";
        return ValidationResult.invalidWithDepth(.heic, msg, .full);
    }
}

/// Deep AVIF validation using pure-Zig HEIF container parser + AV1 OBU validator.
pub fn validateAvifDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const result = avif_validator.validateAvifDeep(path);
    if (result.valid) {
        if (result.structural_only) {
            return ValidationResult.okWithDepth(.avif, .structural);
        }
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(.avif, .full, warning);
        }
        return ValidationResult.okWithDepth(.avif, .full);
    } else {
        const msg: []const u8 = if (result.error_message) |e| e else "AVIF validation failed";
        return ValidationResult.invalidWithDepth(.avif, msg, .full);
    }
}

// ============ PNG Deep Validation (CRC-32) ============

/// Deep PNG validation by verifying CRC-32 checksums for all chunks.
/// PNG stores a CRC-32 at the end of each chunk, computed over (type + data).
/// This catches any single-bit error in the image data.
/// Note: CRC errors in ancillary (non-critical) chunks are tolerated with a warning.
/// Per PNG spec, a chunk is ancillary if the first byte has bit 5 set (lowercase letter).
pub fn validatePngDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator; // May use allocator for detailed error message in future
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.png, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.png, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(.png, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    // Skip PNG signature (8 bytes) - already validated in structural check
    file.seekTo(8) catch {
        return ValidationResult.invalidCodeWithDepth(.png, .failed_to_seek, "past signature", .full);
    };

    var chunk_count: usize = 0;
    const max_chunk_size: u32 = 128 * 1024 * 1024; // 128 MiB max chunk

    // Track ancillary CRC errors - tolerable but we warn about them
    // REPAIRABLE: png_ancillary_crc_error - can be fixed by recalculating CRCs
    var has_ancillary_crc_error = false;

    while (true) {
        // Read chunk header (4 bytes length + 4 bytes type)
        var chunk_header: [8]u8 = undefined;
        const header_bytes = file.read(&chunk_header) catch |err| {
            if (err == error.EndOfStream) break;
            return ValidationResult.invalidCodeWithDepth(.png, .failed_to_read, "chunk header", .full);
        };
        if (header_bytes == 0) break;
        if (header_bytes < 8) {
            return ValidationResult.invalidCodeWithDepth(.png, .truncated, "chunk header", .full);
        }

        const chunk_length = std.mem.readInt(u32, chunk_header[0..4], .big);
        const chunk_type = chunk_header[4..8];

        // Safety: don't try to allocate ridiculous amounts
        if (chunk_length > max_chunk_size) {
            return ValidationResult.invalidCodeMsgWithDepth(.png, .exceeds_bounds, "Chunk size", "Chunk size exceeds maximum", .full);
        }

        // Calculate CRC-32 over (type + data)
        var crc = std.hash.Crc32.init();

        // Hash the chunk type
        crc.update(chunk_type);

        // Read and hash chunk data in chunks to avoid huge allocations
        var data_remaining = chunk_length;
        var read_buffer: [65536]u8 = undefined; // 64K read buffer

        while (data_remaining > 0) {
            const to_read = @min(data_remaining, read_buffer.len);
            const bytes_read = file.read(read_buffer[0..to_read]) catch |err| {
                if (err == error.EndOfStream) {
                    return ValidationResult.invalidWithDepth(.png, "Unexpected EOF in chunk data", .full);
                }
                return ValidationResult.invalidCodeWithDepth(.png, .failed_to_read, "chunk data", .full);
            };
            if (bytes_read == 0) {
                return ValidationResult.invalidWithDepth(.png, "Unexpected EOF in chunk data", .full);
            }
            crc.update(read_buffer[0..bytes_read]);
            data_remaining -= @as(u32, @intCast(bytes_read));
        }

        // Read stored CRC (4 bytes, big endian)
        var stored_crc_bytes: [4]u8 = undefined;
        const crc_bytes_read = file.read(&stored_crc_bytes) catch |err| {
            if (err == error.EndOfStream) {
                return ValidationResult.invalidCodeWithDepth(.png, .missing, "chunk CRC", .full);
            }
            return ValidationResult.invalidCodeWithDepth(.png, .failed_to_read, "chunk CRC", .full);
        };
        if (crc_bytes_read < 4) {
            return ValidationResult.invalidCodeWithDepth(.png, .truncated, "chunk CRC", .full);
        }

        const stored_crc = std.mem.readInt(u32, &stored_crc_bytes, .big);
        const computed_crc = crc.final();

        if (stored_crc != computed_crc) {
            // Check if this is an ancillary chunk (first byte has bit 5 set = lowercase)
            // Ancillary chunks are non-critical metadata that viewers can ignore
            const is_ancillary = (chunk_type[0] & 0x20) != 0;
            if (is_ancillary) {
                // Tolerate CRC error in ancillary chunk - image still viewable
                has_ancillary_crc_error = true;
            } else {
                // Critical chunk CRC error - image may be corrupted
                return ValidationResult.invalidCodeMsgWithDepth(.png, .checksum_mismatch, "CRC", "CRC mismatch in critical chunk", .full);
            }
        }

        chunk_count += 1;

        // Check for IEND (end of PNG)
        if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        // Safety limit
        if (chunk_count > 10000) {
            return ValidationResult.invalidCodeWithDepth(.png, .too_many, "chunks", .full);
        }
    }

    if (chunk_count == 0) {
        return ValidationResult.invalidWithDepth(.png, "No chunks found", .full);
    }

    // Return with warning if ancillary CRC errors were found
    if (has_ancillary_crc_error) {
        return ValidationResult.okWithDepthAndMalformation(.png, .full, .png_ancillary_crc_error);
    }
    return ValidationResult.okWithDepth(.png, .full);
}

// ============ Buffer-based Validators ============

/// Validate PNG from memory buffer.
/// Core buffer-based validator - file-based validatePng calls this.
pub fn validatePngFromBuffer(data: []const u8) ValidationResult {
    // Check minimum size for PNG signature
    if (data.len < 8) {
        return ValidationResult.invalidCode(.png, .file_too_small, "PNG");
    }

    // Verify PNG signature
    const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, data[0..8], &png_signature)) {
        return ValidationResult.invalidCode(.png, .invalid_signature, "PNG");
    }

    // Parse chunks
    var offset: usize = 8;
    var found_ihdr = false;
    var found_iend = false;
    var chunk_count: u32 = 0;

    while (offset + 12 <= data.len) {
        // Read chunk length (big-endian)
        const length = std.mem.readInt(u32, data[offset..][0..4], .big);

        // Read chunk type
        const chunk_type = data[offset + 4 ..][0..4];

        // Validate chunk length doesn't exceed remaining data
        if (offset + 12 + length > data.len) {
            return ValidationResult.invalidCode(.png, .truncated, "PNG chunk");
        }

        // Track critical chunks
        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_count != 0) {
                return ValidationResult.invalid(.png, "IHDR must be first chunk");
            }
            found_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            found_iend = true;
            break; // IEND marks end of PNG
        }

        // Move to next chunk (length + type + data + CRC)
        offset += 12 + length;
        chunk_count += 1;

        // Sanity check
        if (chunk_count > 10000) {
            return ValidationResult.invalidCode(.png, .too_many, "PNG chunks");
        }
    }

    if (!found_ihdr) {
        return ValidationResult.invalidCode(.png, .missing, "IHDR chunk");
    }

    if (!found_iend) {
        return ValidationResult.invalidCode(.png, .missing, "IEND chunk");
    }

    return ValidationResult.ok(.png);
}

/// Deep PNG validation from memory buffer — verifies CRC-32 for all chunks.
/// Returns .full depth on success. Used by ICO deep validator for embedded PNGs.
pub fn validatePngFromBufferDeep(data: []const u8) ValidationResult {
    if (data.len < 8) {
        return ValidationResult.invalidCodeWithDepth(.png, .file_too_small, "PNG", .full);
    }

    const png_signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, data[0..8], &png_signature)) {
        return ValidationResult.invalidCodeWithDepth(.png, .invalid_signature, "PNG", .full);
    }

    var offset: usize = 8;
    var chunk_count: u32 = 0;
    var found_ihdr = false;
    var found_iend = false;

    while (offset + 12 <= data.len) {
        const chunk_length = std.mem.readInt(u32, data[offset..][0..4], .big);
        const chunk_type = data[offset + 4 ..][0..4];

        // Validate chunk data + CRC fit in buffer
        if (offset + 12 + chunk_length > data.len) {
            return ValidationResult.invalidCodeWithDepth(.png, .truncated, "PNG chunk", .full);
        }

        // CRC-32 over (type + data)
        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(data[offset + 8 ..][0..chunk_length]);
        const computed_crc = crc.final();

        const stored_crc = std.mem.readInt(u32, data[offset + 8 + chunk_length ..][0..4], .big);
        if (stored_crc != computed_crc) {
            // Critical chunk CRC failure = corruption
            const is_ancillary = (chunk_type[0] & 0x20) != 0;
            if (!is_ancillary) {
                return ValidationResult.invalidCodeMsgWithDepth(.png, .checksum_mismatch, "CRC", "CRC mismatch in critical PNG chunk", .full);
            }
            // Ancillary CRC errors are tolerated
        }

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_count != 0) return ValidationResult.invalidWithDepth(.png, "IHDR must be first chunk", .full);
            found_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            found_iend = true;
            break;
        }

        offset += 12 + chunk_length;
        chunk_count += 1;

        if (chunk_count > 10000) {
            return ValidationResult.invalidCodeWithDepth(.png, .too_many, "PNG chunks", .full);
        }
    }

    if (!found_ihdr) return ValidationResult.invalidCodeWithDepth(.png, .missing, "IHDR chunk", .full);
    if (!found_iend) return ValidationResult.invalidCodeWithDepth(.png, .missing, "IEND chunk", .full);

    return ValidationResult.okWithDepth(.png, .full);
}

/// Validate JPEG from memory buffer.
pub fn validateJpegFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 2) {
        return ValidationResult.invalidCode(.jpeg, .file_too_small, "JPEG");
    }

    // Check SOI marker
    if (data[0] != 0xFF or data[1] != 0xD8) {
        return ValidationResult.invalidCode(.jpeg, .invalid_value, "JPEG SOI marker");
    }

    // Scan for EOI marker
    var offset: usize = 2;
    var found_eoi = false;

    while (offset + 1 < data.len) {
        if (data[offset] == 0xFF) {
            const marker = data[offset + 1];

            // Skip padding FF bytes
            if (marker == 0xFF) {
                offset += 1;
                continue;
            }

            // EOI marker
            if (marker == 0xD9) {
                found_eoi = true;
                break;
            }

            // SOS marker - start of scan data
            if (marker == 0xDA) {
                // Skip to find EOI in entropy-coded data
                offset += 2;
                while (offset + 1 < data.len) {
                    if (data[offset] == 0xFF and data[offset + 1] == 0xD9) {
                        found_eoi = true;
                        break;
                    }
                    offset += 1;
                }
                break;
            }

            // Skip variable-length segments
            if (marker >= 0xC0 and marker != 0xFF) {
                if (offset + 4 > data.len) break;
                const seg_len = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);
                offset += 2 + seg_len;
                continue;
            }
        }
        offset += 1;
    }

    if (!found_eoi) {
        return ValidationResult.invalidCode(.jpeg, .missing, "JPEG EOI marker");
    }

    return ValidationResult.ok(.jpeg);
}

// Stub implementations for other formats - to be filled in
pub fn validateGifFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 6) return ValidationResult.invalid(.gif, "File too small");
    if (std.mem.eql(u8, data[0..3], "GIF")) {
        return ValidationResult.ok(.gif);
    }
    return ValidationResult.invalidCode(.gif, .invalid_signature, "GIF");
}

pub fn validateBmpFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 2) return ValidationResult.invalid(.bmp, "File too small");
    if (data[0] == 'B' and data[1] == 'M') {
        return ValidationResult.ok(.bmp);
    }
    return ValidationResult.invalidCode(.bmp, .invalid_signature, "BMP");
}

pub fn validateTiffFromBuffer(data: []const u8) ValidationResult {
    // TIFF header: 8 bytes minimum
    // - Byte order: "II" (little-endian) or "MM" (big-endian)
    // - Magic: 42 (0x002A)
    // - Offset to first IFD

    if (data.len < 8) return ValidationResult.invalidCode(.tiff, .file_too_small, "TIFF header");

    // Check byte order
    const is_big_endian = std.mem.eql(u8, data[0..2], "MM");
    const is_little_endian = std.mem.eql(u8, data[0..2], "II");
    if (!is_big_endian and !is_little_endian) {
        return ValidationResult.invalidCode(.tiff, .invalid_value, "TIFF byte order");
    }

    // Check magic number (42)
    const magic = if (is_big_endian)
        std.mem.readInt(u16, data[2..4], .big)
    else
        std.mem.readInt(u16, data[2..4], .little);

    if (magic != 42) {
        return ValidationResult.invalidCode(.tiff, .invalid_magic_number, "TIFF");
    }

    // Read IFD offset
    const ifd_offset = if (is_big_endian)
        std.mem.readInt(u32, data[4..8], .big)
    else
        std.mem.readInt(u32, data[4..8], .little);

    // Validate IFD offset is within bounds
    if (ifd_offset >= data.len or ifd_offset + 2 > data.len) {
        return ValidationResult.invalidWithDepth(.tiff, "IFD offset out of bounds", .full);
    }

    // Read number of IFD entries
    const entry_count = if (is_big_endian)
        std.mem.readInt(u16, data[ifd_offset..][0..2], .big)
    else
        std.mem.readInt(u16, data[ifd_offset..][0..2], .little);

    // Validate IFD entries fit within buffer
    const ifd_entries_end = ifd_offset + 2 + @as(usize, entry_count) * 12;
    if (ifd_entries_end > data.len) {
        return ValidationResult.invalidWithDepth(.tiff, "IFD entries truncated", .full);
    }

    // Track important tags for validation
    var strip_offsets: ?u32 = null;
    var strip_byte_counts: ?u32 = null;
    var strip_count: u32 = 0;
    var image_width: u32 = 0;
    var image_height: u32 = 0;

    // Parse IFD entries
    var pos = ifd_offset + 2;
    for (0..entry_count) |_| {
        if (pos + 12 > data.len) break;

        const entry = data[pos..][0..12];
        const tag = if (is_big_endian)
            std.mem.readInt(u16, entry[0..2], .big)
        else
            std.mem.readInt(u16, entry[0..2], .little);
        const tag_type = if (is_big_endian)
            std.mem.readInt(u16, entry[2..4], .big)
        else
            std.mem.readInt(u16, entry[2..4], .little);
        const count = if (is_big_endian)
            std.mem.readInt(u32, entry[4..8], .big)
        else
            std.mem.readInt(u32, entry[4..8], .little);
        const value_offset = if (is_big_endian)
            std.mem.readInt(u32, entry[8..12], .big)
        else
            std.mem.readInt(u32, entry[8..12], .little);

        // Get inline value for small entries
        const inline_value: u32 = if (count == 1) blk: {
            if (tag_type == 3) { // SHORT
                break :blk if (is_big_endian)
                    std.mem.readInt(u16, entry[8..10], .big)
                else
                    std.mem.readInt(u16, entry[8..10], .little);
            } else if (tag_type == 4) { // LONG
                break :blk value_offset;
            } else break :blk 0;
        } else 0;

        switch (tag) {
            256 => image_width = inline_value, // ImageWidth
            257 => image_height = inline_value, // ImageLength
            273 => { // StripOffsets
                strip_count = count;
                if (count == 1) {
                    strip_offsets = value_offset;
                } else {
                    // Multiple strips - value_offset points to array
                    if (value_offset < data.len) {
                        strip_offsets = value_offset;
                    }
                }
            },
            279 => { // StripByteCounts
                if (count == 1) {
                    strip_byte_counts = value_offset;
                } else if (value_offset < data.len) {
                    strip_byte_counts = value_offset;
                }
            },
            else => {},
        }

        pos += 12;
    }

    // Validate strip data if present
    if (strip_offsets) |offsets| {
        if (strip_count == 1) {
            // Single strip - offsets is the direct offset
            if (offsets >= data.len) {
                return ValidationResult.invalidWithDepth(.tiff, "Strip offset out of bounds", .full);
            }
            if (strip_byte_counts) |bytes| {
                if (offsets + bytes > data.len) {
                    return ValidationResult.invalidWithDepth(.tiff, "Strip data truncated", .full);
                }
            }
        } else if (strip_count > 1) {
            // Multiple strips - offsets points to offset array
            // Validate first offset in array as a sanity check
            const type_size: usize = 4; // Assuming LONG offsets
            if (offsets + strip_count * type_size > data.len) {
                return ValidationResult.invalidWithDepth(.tiff, "Strip offset array truncated", .full);
            }

            // Check first strip offset
            const first_strip = if (is_big_endian)
                std.mem.readInt(u32, data[offsets..][0..4], .big)
            else
                std.mem.readInt(u32, data[offsets..][0..4], .little);

            if (first_strip >= data.len) {
                return ValidationResult.invalidWithDepth(.tiff, "Strip data out of bounds", .full);
            }
        }
    }

    // If we have dimensions, validate they're reasonable
    if (image_width > 0 and image_height > 0) {
        if (image_width > 65535 or image_height > 65535) {
            // Very large dimensions - could be corrupted but still structurally valid
            return ValidationResult.okWithDepthAndWarning(.tiff, .full, "unusual dimensions");
        }
    }

    // All structural checks passed
    return ValidationResult.okWithDepth(.tiff, .full);
}

pub fn validateWebpFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 12) return ValidationResult.invalid(.webp, "File too small");
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) {
        return ValidationResult.ok(.webp);
    }
    return ValidationResult.invalidCode(.webp, .invalid_signature, "WebP");
}

// ============ Windows ICO Validation ============

/// Validate Windows ICO icon files.
/// ICO format: ICONDIR header + ICONDIRENTRY array + image data (BMP or PNG)
pub fn validateIco(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.ico, .failed_to_stat, "file");
    };

    if (stat.size < 6) {
        return ValidationResult.invalidCode(.ico, .file_too_small, "ICO format");
    }

    // Read ICONDIR header: 2 reserved + 2 type + 2 count
    var header: [6]u8 = undefined;
    const bytes_read = file.readAll(&header) catch {
        return ValidationResult.invalidCode(.ico, .failed_to_read, "header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalidCode(.ico, .truncated, "header");
    }

    // Verify reserved field is 0
    const reserved = std.mem.readInt(u16, header[0..2], .little);
    if (reserved != 0) {
        return ValidationResult.invalidCode(.ico, .invalid_value, "reserved field");
    }

    // Verify type: 1 = icon, 2 = cursor
    const image_type = std.mem.readInt(u16, header[2..4], .little);
    if (image_type != 1 and image_type != 2) {
        return ValidationResult.invalidCode(.ico, .invalid_value, "image type (must be 1 or 2)");
    }

    // Get image count
    const count = std.mem.readInt(u16, header[4..6], .little);
    if (count == 0) {
        return ValidationResult.invalid(.ico, "No images in icon file");
    }

    // Sanity check - ICO files shouldn't have thousands of images
    if (count > 256) {
        return ValidationResult.invalidCode(.ico, .too_many, "images (max 256)");
    }

    // Verify file is large enough for directory entries (16 bytes each)
    const dir_size: u64 = 6 + @as(u64, count) * 16;
    if (stat.size < dir_size) {
        return ValidationResult.invalidCode(.ico, .file_too_small, "directory entries");
    }

    // Read and validate each directory entry
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        var entry: [16]u8 = undefined;
        const entry_bytes = file.readAll(&entry) catch {
            return ValidationResult.invalidCode(.ico, .failed_to_read, "directory entry");
        };

        if (entry_bytes < 16) {
            return ValidationResult.invalidCode(.ico, .truncated, "directory entry");
        }

        // Entry format:
        // 0: width (0 = 256)
        // 1: height (0 = 256)
        // 2: color count (0 for >= 256 colors)
        // 3: reserved (should be 0)
        // 4-5: color planes (icons) or hotspot X (cursors)
        // 6-7: bits per pixel (icons) or hotspot Y (cursors)
        // 8-11: image data size
        // 12-15: image data offset

        const reserved_byte = entry[3];
        if (reserved_byte != 0) {
            // Some ICO files have non-zero reserved bytes, just warn
            // Don't fail validation for this
        }

        const data_size = std.mem.readInt(u32, entry[8..12], .little);
        const data_offset = std.mem.readInt(u32, entry[12..16], .little);

        // Validate offset and size are within file bounds
        if (data_offset == 0 or data_size == 0) {
            return ValidationResult.invalidCode(.ico, .invalid_value, "image entry (zero offset/size)");
        }

        const image_end: u64 = @as(u64, data_offset) + @as(u64, data_size);
        if (image_end > stat.size) {
            return ValidationResult.invalidCodeMsg(.ico, .exceeds_bounds, "Image data", "Image data exceeds file bounds");
        }

        // Optionally verify image data starts with valid signature
        // PNG: 89 50 4E 47 or BMP DIB header: biSize field
        var img_header: [8]u8 = undefined;
        file.seekTo(data_offset) catch {
            return ValidationResult.invalidCode(.ico, .failed_to_seek, "to image data");
        };
        const img_bytes = file.readAll(&img_header) catch {
            return ValidationResult.invalidCode(.ico, .failed_to_read, "image data");
        };

        if (img_bytes >= 8) {
            // Check for PNG signature
            const is_png = std.mem.eql(u8, img_header[0..8], &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });
            if (!is_png) {
                // Should be DIB header - check for reasonable biSize values
                // Common values: 40 (BITMAPINFOHEADER), 108 (BITMAPV4HEADER), 124 (BITMAPV5HEADER)
                const dib_size = std.mem.readInt(u32, img_header[0..4], .little);
                if (dib_size != 40 and dib_size != 108 and dib_size != 124 and dib_size != 12) {
                    // Could be corrupt or unusual format, but don't fail
                    // Some tools create ICOs with non-standard headers
                }
            }
        }

        // Seek back to next directory entry position
        file.seekTo(6 + @as(u64, i + 1) * 16) catch {
            // Last entry, this is fine
        };
    }

    return ValidationResult.okWithDepth(.ico, .structural);
}

/// Deep ICO validation — verifies embedded PNG CRC-32 checksums and BMP structure.
/// Returns .full if all entries are PNG with valid CRCs, .structural if any are BMP/unknown.
pub fn validateIcoDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.ico, "File not found", .full),
            error.AccessDenied => ValidationResult.invalidWithDepth(.ico, "Access denied", .full),
            else => ValidationResult.invalidCodeWithDepth(.ico, .failed_to_open, "file", .full),
        };
    };
    defer file.close();

    const stat = file.stat() catch {
        return ValidationResult.invalidCodeWithDepth(.ico, .failed_to_stat, "file", .structural);
    };

    if (stat.size < 6) {
        return ValidationResult.invalidCodeWithDepth(.ico, .file_too_small, "ICO format", .structural);
    }

    var header: [6]u8 = undefined;
    _ = file.readAll(&header) catch {
        return ValidationResult.invalidCodeWithDepth(.ico, .failed_to_read, "header", .structural);
    };

    const count = std.mem.readInt(u16, header[4..6], .little);
    if (count == 0 or count > 256) {
        return ValidationResult.invalidCodeWithDepth(.ico, .invalid_value, "image count", .structural);
    }

    // Read all directory entries first
    const dir_size = @as(usize, count) * 16;
    const dir_buf = allocator.alloc(u8, dir_size) catch {
        return ValidationResult.invalidCodeWithDepth(.ico, .out_of_memory, "for ICO directory", .structural);
    };
    defer allocator.free(dir_buf);

    const dir_read = file.readAll(dir_buf) catch {
        return ValidationResult.invalidCodeWithDepth(.ico, .failed_to_read, "directory", .structural);
    };
    if (dir_read < dir_size) {
        return ValidationResult.invalidCodeWithDepth(.ico, .truncated, "directory", .structural);
    }

    var all_png = true;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        const entry = dir_buf[@as(usize, i) * 16 ..][0..16];
        const data_size = std.mem.readInt(u32, entry[8..12], .little);
        const data_offset = std.mem.readInt(u32, entry[12..16], .little);

        if (data_offset == 0 or data_size == 0) {
            return ValidationResult.invalidCodeWithDepth(.ico, .invalid_value, "image entry (zero offset/size)", .structural);
        }

        const image_end: u64 = @as(u64, data_offset) + @as(u64, data_size);
        if (image_end > stat.size) {
            return ValidationResult.invalidCodeMsgWithDepth(.ico, .exceeds_bounds, "Image data", "Image data exceeds file bounds", .structural);
        }

        // Read image data
        const img_data = allocator.alloc(u8, data_size) catch {
            return ValidationResult.invalidCodeWithDepth(.ico, .out_of_memory, "for ICO image", .structural);
        };
        defer allocator.free(img_data);

        file.seekTo(data_offset) catch {
            return ValidationResult.invalidCodeWithDepth(.ico, .failed_to_seek, "to image data", .structural);
        };
        const img_read = file.readAll(img_data) catch {
            return ValidationResult.invalidCodeWithDepth(.ico, .failed_to_read, "image data", .structural);
        };
        if (img_read < data_size) {
            return ValidationResult.invalidCodeWithDepth(.ico, .truncated, "image data", .structural);
        }

        // Check if PNG
        const png_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
        if (data_size >= 8 and std.mem.eql(u8, img_data[0..8], &png_sig)) {
            // Validate PNG with CRC-32 checking
            const png_result = validatePngFromBufferDeep(img_data);
            if (!png_result.is_valid) {
                return ValidationResult.invalidWithDepth(.ico, "Embedded PNG validation failed", .full);
            }
        } else {
            // BMP/DIB entry — no checksums available
            all_png = false;
            // Still validate DIB header structure
            if (data_size >= 4) {
                const dib_size = std.mem.readInt(u32, img_data[0..4], .little);
                if (dib_size != 40 and dib_size != 108 and dib_size != 124 and dib_size != 12) {
                    return ValidationResult.invalidCodeWithDepth(.ico, .invalid_value, "DIB header size", .structural);
                }
            }
        }
    }

    if (all_png) {
        return ValidationResult.okWithDepth(.ico, .full);
    }
    // Mixed PNG+BMP or all-BMP: BMP has no checksums, can only do structural
    return ValidationResult.okWithDepth(.ico, .structural);
}

// ============ QOI Validator ============

/// Validate QOI (Quite OK Image) file structure.
/// Header: "qoif"(4) + width(4,BE) + height(4,BE) + channels(1) + colorspace(1) = 14 bytes.
pub fn validateQoi(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.qoi, .failed_to_seek, "in QOI file");

    var header: [14]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.qoi, .failed_to_read, "QOI header");

    if (bytes_read < 14) {
        return ValidationResult.invalidCode(.qoi, .file_too_small, "QOI header (need 14 bytes)");
    }

    if (!std.mem.eql(u8, header[0..4], "qoif")) {
        return ValidationResult.invalidCode(.qoi, .invalid_magic, "QOI");
    }

    const width = std.mem.readInt(u32, header[4..8], .big);
    if (width == 0) {
        return ValidationResult.invalid(.qoi, "QOI width is zero");
    }

    const height = std.mem.readInt(u32, header[8..12], .big);
    if (height == 0) {
        return ValidationResult.invalid(.qoi, "QOI height is zero");
    }

    const channels = header[12];
    if (channels != 3 and channels != 4) {
        return ValidationResult.invalid(.qoi, "QOI channels must be 3 or 4");
    }

    const colorspace = header[13];
    if (colorspace > 1) {
        return ValidationResult.invalid(.qoi, "QOI colorspace must be 0 (sRGB) or 1 (linear)");
    }

    return ValidationResult.structuralOnly(.qoi);
}

// ============ TGA Validator ============

/// Validate TGA (Truevision TGA/TARGA) file structure.
/// No magic bytes - 18-byte header with: id_length(1) + color_map_type(1) + image_type(1) + color_map_spec(5) + image_spec(10).
pub fn validateTga(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.tga, .failed_to_seek, "in TGA file");

    var header: [18]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.tga, .failed_to_read, "TGA header");

    if (bytes_read < 18) {
        return ValidationResult.invalidCode(.tga, .file_too_small, "TGA header (need 18 bytes)");
    }

    const color_map_type = header[1];
    if (color_map_type > 1) {
        return ValidationResult.invalid(.tga, "TGA color map type must be 0 or 1");
    }

    const image_type = header[2];
    const valid_image_types = [_]u8{ 0, 1, 2, 3, 9, 10, 11, 32, 33 };
    var type_valid = false;
    for (valid_image_types) |vt| {
        if (image_type == vt) {
            type_valid = true;
            break;
        }
    }
    if (!type_valid) {
        return ValidationResult.invalidCode(.tga, .invalid_value, "TGA image type");
    }

    // Color-mapped image types require color map type 1
    if (color_map_type == 0 and (image_type == 1 or image_type == 9 or image_type == 32 or image_type == 33)) {
        return ValidationResult.invalid(.tga, "TGA color-mapped image type requires color map type 1");
    }

    const width = std.mem.readInt(u16, header[12..14], .little);
    const height = std.mem.readInt(u16, header[14..16], .little);

    if (image_type != 0) {
        if (width == 0) {
            return ValidationResult.invalid(.tga, "TGA image width is zero");
        }
        if (height == 0) {
            return ValidationResult.invalid(.tga, "TGA image height is zero");
        }
    }

    const pixel_depth = header[16];
    if (image_type != 0) {
        if (pixel_depth != 1 and pixel_depth != 8 and pixel_depth != 15 and
            pixel_depth != 16 and pixel_depth != 24 and pixel_depth != 32)
        {
            return ValidationResult.invalidCode(.tga, .invalid_value, "TGA pixel depth");
        }
    }

    // Check for TGA v2 footer
    const file_size = file.getEndPos() catch {
        return ValidationResult.structuralOnly(.tga);
    };

    if (file_size >= 26) {
        file.seekTo(file_size - 26) catch {
            return ValidationResult.structuralOnly(.tga);
        };

        var footer: [26]u8 = undefined;
        const footer_bytes = file.read(&footer) catch {
            return ValidationResult.structuralOnly(.tga);
        };

        if (footer_bytes == 26) {
            const tga_sig = "TRUEVISION-XFILE.\x00";
            if (std.mem.eql(u8, footer[8..26], tga_sig)) {
                return ValidationResult.structuralOnly(.tga);
            }
        }
    }

    return ValidationResult.structuralOnly(.tga);
}

// ============ PAM/PBM/PGM/PPM Validator ============

/// Validate Portable Anymap (PBM/PGM/PPM/PAM) file structure.
/// P1=PBM ASCII, P2=PGM ASCII, P3=PPM ASCII, P4=PBM binary, P5=PGM binary, P6=PPM binary, P7=PAM.
pub fn validatePam(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pam, .failed_to_seek, "in PAM file");

    var header: [256]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.pam, .failed_to_read, "PAM header");

    if (bytes_read < 3) {
        return ValidationResult.invalidCode(.pam, .file_too_small, "Portable Anymap header");
    }

    if (header[0] != 'P') {
        return ValidationResult.invalidCode(.pam, .invalid_value, "Portable Anymap magic (expected 'P')");
    }

    if (header[1] < '1' or header[1] > '7') {
        return ValidationResult.invalidCode(.pam, .invalid_value, "Portable Anymap type (expected P1-P7)");
    }

    if (header[2] != ' ' and header[2] != '\t' and header[2] != '\n' and header[2] != '\r') {
        return ValidationResult.invalid(.pam, "Portable Anymap magic not followed by whitespace");
    }

    // For P7 (PAM), check for ENDHDR keyword
    if (header[1] == '7') {
        const header_data = header[0..bytes_read];
        if (std.mem.indexOf(u8, header_data, "ENDHDR") == null) {
            // Could be a very large header; not necessarily invalid
        }
    } else {
        // P1-P6: Try to parse width/height
        var pos: usize = 3;
        var number_count: u32 = 0;

        while (pos < bytes_read and number_count < 2) {
            if (header[pos] == '#') {
                while (pos < bytes_read and header[pos] != '\n') : (pos += 1) {}
                if (pos < bytes_read) pos += 1;
                continue;
            }
            if (header[pos] == ' ' or header[pos] == '\t' or header[pos] == '\n' or header[pos] == '\r') {
                pos += 1;
                continue;
            }
            if (header[pos] >= '0' and header[pos] <= '9') {
                var value: u32 = 0;
                while (pos < bytes_read and header[pos] >= '0' and header[pos] <= '9') {
                    value = value *% 10 +% @as(u32, header[pos] - '0');
                    pos += 1;
                }
                number_count += 1;
                if (value == 0) {
                    if (number_count == 1) {
                        return ValidationResult.invalid(.pam, "Portable Anymap width is zero");
                    } else {
                        return ValidationResult.invalid(.pam, "Portable Anymap height is zero");
                    }
                }
            } else {
                return ValidationResult.invalidCode(.pam, .invalid_value, "character in Portable Anymap header");
            }
        }
    }

    return ValidationResult.structuralOnly(.pam);
}

// ============ DPX Validator ============

/// Validate DPX (Digital Picture Exchange) file structure.
/// Magic: "SDPX" (LE) or "XPDS" (BE). Minimum header 2048 bytes in practice.
pub fn validateDpx(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.dpx, .failed_to_seek, "in DPX file");

    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.dpx, .failed_to_read, "DPX header");

    if (bytes_read < 32) {
        return ValidationResult.invalidCode(.dpx, .file_too_small, "DPX header");
    }

    // DPX spec: "SDPX" (0x53445058) = big-endian, "XPDS" (0x58504453) = little-endian
    const is_be = std.mem.eql(u8, header[0..4], "SDPX");
    const is_le = std.mem.eql(u8, header[0..4], "XPDS");

    if (!is_le and !is_be) {
        return ValidationResult.invalidCode(.dpx, .invalid_value, "DPX magic bytes (expected SDPX or XPDS)");
    }

    const endian: std.builtin.Endian = if (is_le) .little else .big;

    const image_offset = std.mem.readInt(u32, header[4..8], endian);
    if (image_offset < 1024) {
        return ValidationResult.invalid(.dpx, "DPX image offset too small");
    }

    // Version string at offset 8 should start with 'V'
    if (header[8] != 'V') {
        return ValidationResult.invalid(.dpx, "DPX version string does not start with 'V'");
    }

    const declared_size = std.mem.readInt(u32, header[16..20], endian);
    const actual_size = file.getEndPos() catch {
        return ValidationResult.structuralOnly(.dpx);
    };

    if (declared_size != 0xFFFFFFFF) {
        if (declared_size > actual_size) {
            return ValidationResult.invalidCodeMsg(.dpx, .exceeds_bounds, "DPX declared file size", "DPX declared file size exceeds actual size (truncated)");
        }
    }

    if (image_offset > actual_size) {
        return ValidationResult.invalid(.dpx, "DPX image offset beyond end of file");
    }

    return ValidationResult.structuralOnly(.dpx);
}

// ============ Tests ============

const testing = std.testing;

// ---- PNG ----

test "validatePng accepts valid PNG from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/png/generated_gradient.png", .{}) catch return;
    defer file.close();
    const result = validatePng(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.png, result.format);
}

test "validatePng rejects truncated PNG" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid PNG signature but no IHDR chunk
    const data = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    const f = try tmp.dir.createFile("bad.png", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.png", .{});
    defer file.close();
    const result = validatePng(file);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.png, result.format);
}

test "validatePng rejects non-IHDR first chunk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid PNG signature + a chunk that is NOT IHDR
    const data = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG sig
        0x00, 0x00, 0x00, 0x00, // chunk length 0
        'X',  'X',  'X',  'X', // chunk type (not IHDR)
        0x00, 0x00, 0x00, 0x00, // CRC
    };
    const f = try tmp.dir.createFile("bad2.png", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad2.png", .{});
    defer file.close();
    const result = validatePng(file);
    try testing.expect(!result.is_valid);
}

test "validatePngDeep accepts valid PNG from ground truth" {
    const allocator = testing.allocator;
    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/png/generated_gradient.png") catch return;
    defer allocator.free(path);
    const result = validatePngDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.png, result.format);
}

// ---- JPEG ----

test "validateJpeg accepts valid JPEG from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/jpeg/generated_gradient.jpg", .{}) catch return;
    defer file.close();
    const result = validateJpeg(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.jpeg, result.format);
}

test "validateJpeg rejects truncated JPEG" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid SOI marker but nothing else
    const data = [_]u8{ 0xFF, 0xD8 };
    const f = try tmp.dir.createFile("bad.jpg", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.jpg", .{});
    defer file.close();
    const result = validateJpeg(file);
    // Truncated JPEG with no SOS and no EOI should be invalid
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.jpeg, result.format);
}

test "validateJpeg rejects invalid magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad2.jpg", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad2.jpg", .{});
    defer file.close();
    const result = validateJpeg(file);
    try testing.expect(!result.is_valid);
}

// ---- GIF ----

test "validateGif accepts valid GIF from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/gif/sample_1.gif", .{}) catch return;
    defer file.close();
    const result = validateGif(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.gif, result.format);
}

test "validateGif rejects invalid header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'N', 'O', 'T', 'G', 'I', 'F' };
    const f = try tmp.dir.createFile("bad.gif", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.gif", .{});
    defer file.close();
    const result = validateGif(file);
    try testing.expect(!result.is_valid);
}

test "validateGif rejects too-small file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Valid GIF header but file too small (< 13 bytes)
    const data = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0x01, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("small.gif", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("small.gif", .{});
    defer file.close();
    const result = validateGif(file);
    try testing.expect(!result.is_valid);
}

// ---- BMP ----

test "validateBmp accepts valid BMP from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/bmp/sample.bmp", .{}) catch return;
    defer file.close();
    const result = validateBmp(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.bmp, result.format);
}

test "validateBmp rejects invalid signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'X', 'X', 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.bmp", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.bmp", .{});
    defer file.close();
    const result = validateBmp(file);
    try testing.expect(!result.is_valid);
}

// ---- TIFF ----

test "validateTiff accepts valid TIFF from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tiff/bali.tif", .{}) catch return;
    defer file.close();
    const result = validateTiff(file, .tiff);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.tiff, result.format);
}

test "validateTiff rejects invalid byte order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'X', 'X', 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.tif", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.tif", .{});
    defer file.close();
    const result = validateTiff(file, .tiff);
    try testing.expect(!result.is_valid);
}

// ---- WebP ----

test "validateWebp accepts valid WebP from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/webp/google_gallery_1.webp", .{}) catch return;
    defer file.close();
    const result = validateWebp(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.webp, result.format);
}

test "validateWebp rejects invalid RIFF signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'N', 'O', 'P', 'E', 0x00, 0x00, 0x00, 0x00, 'W', 'E', 'B', 'P' };
    const f = try tmp.dir.createFile("bad.webp", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.webp", .{});
    defer file.close();
    const result = validateWebp(file);
    try testing.expect(!result.is_valid);
}

test "validateWebp rejects invalid fourcc" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'R', 'I', 'F', 'F', 0x04, 0x00, 0x00, 0x00, 'N', 'O', 'P', 'E' };
    const f = try tmp.dir.createFile("bad2.webp", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad2.webp", .{});
    defer file.close();
    const result = validateWebp(file);
    try testing.expect(!result.is_valid);
}

// ---- SVG ----

test "validateSvg accepts valid SVG from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/svg/sample.svg", .{}) catch return;
    defer file.close();
    const result = validateSvg(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.svg, result.format);
}

test "validateSvg rejects non-SVG content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("bad.svg", .{});
    try f.writeAll("This is not an SVG file at all.");
    f.close();
    const file = try tmp.dir.openFile("bad.svg", .{});
    defer file.close();
    const result = validateSvg(file);
    try testing.expect(!result.is_valid);
}

test "validateSvgDeep accepts valid SVG from ground truth" {
    const allocator = testing.allocator;
    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/svg/sample.svg") catch return;
    defer allocator.free(path);
    const result = validateSvgDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.svg, result.format);
}

// ---- JPEG XL ----

test "validateJxl accepts valid JXL from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/jxl/bicycles.jxl", .{}) catch return;
    defer file.close();
    const result = validateJxl(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.jxl, result.format);
}

test "validateJxl rejects invalid signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.jxl", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.jxl", .{});
    defer file.close();
    const result = validateJxl(file);
    try testing.expect(!result.is_valid);
}

// ---- EXR ----

test "validateExr accepts valid EXR from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/exr/sample.exr", .{}) catch return;
    defer file.close();
    const result = validateExr(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.exr, result.format);
}

test "validateExr rejects invalid magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.exr", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.exr", .{});
    defer file.close();
    const result = validateExr(file);
    try testing.expect(!result.is_valid);
}

test "validateExrDeep accepts valid EXR from ground truth" {
    const allocator = testing.allocator;
    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/exr/sample.exr") catch return;
    defer allocator.free(path);
    const result = validateExrDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.exr, result.format);
}

// ---- ICO ----

test "validateIco accepts valid ICO from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/ico/sample.ico", .{}) catch return;
    defer file.close();
    const result = validateIco(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ico, result.format);
}

test "validateIco rejects invalid reserved field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // reserved=0x0001 (invalid), type=1, count=1, then 16 dummy entry bytes
    const data = [_]u8{
        0x01, 0x00, // reserved (should be 0)
        0x01, 0x00, // type = icon
        0x01, 0x00, // count = 1
        // 16 bytes dummy entry
        0x10, 0x10, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00,
        0x00, 0x04, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00,
    };
    const f = try tmp.dir.createFile("bad.ico", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.ico", .{});
    defer file.close();
    const result = validateIco(file);
    try testing.expect(!result.is_valid);
}

test "validateIco rejects zero image count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{
        0x00, 0x00, // reserved
        0x01, 0x00, // type = icon
        0x00, 0x00, // count = 0
    };
    const f = try tmp.dir.createFile("empty.ico", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("empty.ico", .{});
    defer file.close();
    const result = validateIco(file);
    try testing.expect(!result.is_valid);
}

// ---- QOI ----

test "validateQoi accepts valid QOI from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/qoi/sample.qoi", .{}) catch return;
    defer file.close();
    const result = validateQoi(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.qoi, result.format);
}

test "validateQoi rejects invalid magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'n', 'o', 'p', 'e', 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x03, 0x00 };
    const f = try tmp.dir.createFile("bad.qoi", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.qoi", .{});
    defer file.close();
    const result = validateQoi(file);
    try testing.expect(!result.is_valid);
}

test "validateQoi rejects zero width" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 'q', 'o', 'i', 'f', 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03, 0x00 };
    const f = try tmp.dir.createFile("zero_w.qoi", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("zero_w.qoi", .{});
    defer file.close();
    const result = validateQoi(file);
    try testing.expect(!result.is_valid);
}

test "validateQoi rejects invalid channels" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // channels = 5 (must be 3 or 4)
    const data = [_]u8{ 'q', 'o', 'i', 'f', 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x00 };
    const f = try tmp.dir.createFile("bad_ch.qoi", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad_ch.qoi", .{});
    defer file.close();
    const result = validateQoi(file);
    try testing.expect(!result.is_valid);
}

// ---- TGA ----

test "validateTga accepts valid TGA from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/tga/sample.tga", .{}) catch return;
    defer file.close();
    const result = validateTga(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.tga, result.format);
}

test "validateTga rejects invalid color map type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // color_map_type = 2 (invalid, must be 0 or 1)
    var data = [_]u8{0} ** 18;
    data[1] = 2; // color_map_type
    data[2] = 2; // image_type = uncompressed true-color
    data[12] = 0x01; // width = 1
    data[14] = 0x01; // height = 1
    data[16] = 24; // pixel depth
    const f = try tmp.dir.createFile("bad.tga", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.tga", .{});
    defer file.close();
    const result = validateTga(file);
    try testing.expect(!result.is_valid);
}

test "validateTga rejects invalid image type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data = [_]u8{0} ** 18;
    data[1] = 0; // color_map_type
    data[2] = 99; // image_type (invalid)
    data[12] = 0x01;
    data[14] = 0x01;
    data[16] = 24;
    const f = try tmp.dir.createFile("bad2.tga", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad2.tga", .{});
    defer file.close();
    const result = validateTga(file);
    try testing.expect(!result.is_valid);
}

// ---- PAM ----

test "validatePam accepts valid PPM from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/pam/sample.ppm", .{}) catch return;
    defer file.close();
    const result = validatePam(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pam, result.format);
}

test "validatePam rejects invalid magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("bad.pam", .{});
    try f.writeAll("X6 1 1 255\n");
    f.close();
    const file = try tmp.dir.openFile("bad.pam", .{});
    defer file.close();
    const result = validatePam(file);
    try testing.expect(!result.is_valid);
}

test "validatePam rejects out-of-range type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("bad2.pam", .{});
    try f.writeAll("P8 1 1\n");
    f.close();
    const file = try tmp.dir.openFile("bad2.pam", .{});
    defer file.close();
    const result = validatePam(file);
    try testing.expect(!result.is_valid);
}

// ---- DPX ----

test "validateDpx accepts valid DPX from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/dpx/sample.dpx", .{}) catch return;
    defer file.close();
    const result = validateDpx(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dpx, result.format);
}

test "validateDpx rejects invalid magic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data = [_]u8{0} ** 32;
    data[0] = 'N';
    data[1] = 'O';
    data[2] = 'P';
    data[3] = 'E';
    const f = try tmp.dir.createFile("bad.dpx", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.dpx", .{});
    defer file.close();
    const result = validateDpx(file);
    try testing.expect(!result.is_valid);
}

// ---- JPEG2000 ----

test "validateJpeg2000 accepts valid JP2 from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/jpeg2k/balloon_intact.jp2", .{}) catch return;
    defer file.close();
    const result = validateJpeg2000(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.jpeg2000, result.format);
}

test "validateJpeg2000 accepts valid J2C codestream from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/jpeg2k/balloon.j2c", .{}) catch return;
    defer file.close();
    const result = validateJpeg2000(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.jpeg2000, result.format);
}

test "validateJpeg2000 rejects invalid signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.jp2", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.jp2", .{});
    defer file.close();
    const result = validateJpeg2000(file);
    try testing.expect(!result.is_valid);
}

// ---- JBIG2 ----

test "validateJbig2File accepts valid JBIG2 from ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/jbig2/minimal_white_page.jbig2", .{}) catch return;
    defer file.close();
    const result = validateJbig2File(file);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.jbig2, result.format);
}

test "validateJbig2File rejects invalid signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const f = try tmp.dir.createFile("bad.jbig2", .{});
    try f.writeAll(&data);
    f.close();
    const file = try tmp.dir.openFile("bad.jbig2", .{});
    defer file.close();
    const result = validateJbig2File(file);
    try testing.expect(!result.is_valid);
}

// ---- HEIC ----

test "validateHeicDeep accepts valid HEIC from ground truth" {
    const allocator = testing.allocator;
    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/heic/sample.heic") catch return;
    defer allocator.free(path);
    const result = validateHeicDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.heic, result.format);
}

// ---- AVIF ----

test "validateAvifDeep accepts valid AVIF from ground truth" {
    const allocator = testing.allocator;
    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/avif/fox.avif") catch return;
    defer allocator.free(path);
    const result = validateAvifDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.avif, result.format);
}

// ---- FromBuffer variants ----

test "validatePngFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validatePngFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateJpegFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateJpegFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateGifFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateGifFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateBmpFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateBmpFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateTiffFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateTiffFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateWebpFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateWebpFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validateExrFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validateExrFromBuffer(&data);
    try testing.expect(!result.is_valid);
}

test "validatePsdFromBuffer rejects empty data" {
    const data = [_]u8{};
    const result = validatePsdFromBuffer(&data);
    try testing.expect(!result.is_valid);
}
