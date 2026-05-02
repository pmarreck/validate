//! PDF Embedded File Validator.
//!
//! Extracts and validates files embedded (attached) in PDFs.
//! Embedded files are found via /EmbeddedFile streams.
//!
//! Reference: PDF 1.7 specification, Section 7.11.4

const std = @import("std");
const Allocator = std.mem.Allocator;
const pdf_image_validator = @import("pdf_image_validator.zig");
const ascii_hex_decoder = @import("ascii_hex_decoder.zig");
const ascii85_decoder = @import("ascii85_decoder.zig");
const run_length_decoder = @import("run_length_decoder.zig");
const lzw_decoder = @import("lzw_decoder.zig");
const zlib = @import("zlib.zig");

pub const PdfEmbeddedFile = struct {
    object_num: u32,
    filename: ?[]const u8, // From /F or /UF in Filespec
    mime_type: ?[]const u8, // From /Subtype in EmbeddedFile
    stream_start: usize,
    stream_end: usize,
    filter: ?pdf_image_validator.ImageFilter,
};

pub const EmbeddedFileValidationSummary = struct {
    total_files: u32,
    validated: u32,
    skipped: u32,
    failed: u32,
    skipped_size_limit: u32 = 0,
    skipped_corrupt: u32 = 0,
    valid: bool,
    error_message: ?[]const u8,

    pub fn ok(total: u32, validated: u32, skipped: u32) EmbeddedFileValidationSummary {
        return .{
            .total_files = total,
            .validated = validated,
            .skipped = skipped,
            .failed = 0,
            .valid = true,
            .error_message = null,
        };
    }

    pub fn invalid(total: u32, validated: u32, failed: u32, msg: []const u8) EmbeddedFileValidationSummary {
        return .{
            .total_files = total,
            .validated = validated,
            .skipped = 0,
            .failed = failed,
            .valid = false,
            .error_message = msg,
        };
    }
};

/// Extract embedded file streams from a PDF.
pub fn extractEmbeddedFiles(allocator: Allocator, pdf_data: []const u8) ![]PdfEmbeddedFile {
    var files: std.ArrayListUnmanaged(PdfEmbeddedFile) = .{};
    errdefer files.deinit(allocator);

    // Find all /EmbeddedFile objects
    // These are found by looking for /Type /EmbeddedFile in object dictionaries
    var pos: usize = 0;
    while (pos < pdf_data.len) {
        // Look for /Type /EmbeddedFile
        const type_pos = std.mem.indexOfPos(u8, pdf_data, pos, "/Type /EmbeddedFile") orelse
            std.mem.indexOfPos(u8, pdf_data, pos, "/Type/EmbeddedFile") orelse break;

        // Find the object start (look backwards for "N 0 obj")
        const obj_start = findObjectStart(pdf_data, type_pos) orelse {
            pos = type_pos + 19;
            continue;
        };

        // Parse object number
        const obj_num = parseObjectNumber(pdf_data, obj_start) orelse {
            pos = type_pos + 19;
            continue;
        };

        // Find the stream
        const search_limit = @min(type_pos + 65536, pdf_data.len);
        const stream_marker = std.mem.indexOfPos(u8, pdf_data[0..search_limit], type_pos, "stream") orelse {
            pos = type_pos + 19;
            continue;
        };

        // Skip past "stream" and whitespace
        var stream_data_start = stream_marker + 6;
        if (stream_data_start < pdf_data.len and pdf_data[stream_data_start] == '\r') {
            stream_data_start += 1;
        }
        if (stream_data_start < pdf_data.len and pdf_data[stream_data_start] == '\n') {
            stream_data_start += 1;
        }

        // Find endstream
        const endstream_pos = std.mem.indexOfPos(u8, pdf_data, stream_data_start, "endstream") orelse {
            pos = type_pos + 19;
            continue;
        };

        // Determine filter
        const dict_data = pdf_data[obj_start..stream_marker];
        var filter: ?pdf_image_validator.ImageFilter = null;

        if (std.mem.indexOf(u8, dict_data, "/FlateDecode") != null) {
            filter = .flate_decode;
        } else if (std.mem.indexOf(u8, dict_data, "/ASCIIHexDecode") != null) {
            filter = .ascii_hex_decode;
        } else if (std.mem.indexOf(u8, dict_data, "/ASCII85Decode") != null) {
            filter = .ascii85_decode;
        } else if (std.mem.indexOf(u8, dict_data, "/LZWDecode") != null) {
            filter = .lzw_decode;
        } else if (std.mem.indexOf(u8, dict_data, "/RunLengthDecode") != null) {
            filter = .run_length_decode;
        }

        // Extract MIME type if present
        var mime_type: ?[]const u8 = null;
        if (std.mem.indexOf(u8, dict_data, "/Subtype /")) |subtype_pos| {
            const start = subtype_pos + 10;
            var end = start;
            while (end < dict_data.len and dict_data[end] != ' ' and dict_data[end] != '/' and dict_data[end] != '\n' and dict_data[end] != '\r') {
                end += 1;
            }
            if (end > start) {
                mime_type = dict_data[start..end];
            }
        }

        files.append(allocator, .{
            .object_num = obj_num,
            .filename = null, // Would need to trace Filespec reference
            .mime_type = mime_type,
            .stream_start = stream_data_start,
            .stream_end = endstream_pos,
            .filter = filter,
        }) catch return error.OutOfMemory;

        pos = endstream_pos + 9;
    }

    return files.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Find the start of an object definition by searching backwards for "N 0 obj".
fn findObjectStart(data: []const u8, from: usize) ?usize {
    // Search backwards for "obj" keyword
    var search_pos = from;
    const search_limit = if (from > 1024) from - 1024 else 0;

    while (search_pos > search_limit + 3) {
        search_pos -= 1;
        if (search_pos + 3 < data.len and std.mem.eql(u8, data[search_pos..][0..3], "obj")) {
            // Found "obj", find the start of the line
            var line_start = search_pos;
            while (line_start > 0 and data[line_start - 1] != '\n' and data[line_start - 1] != '\r') {
                line_start -= 1;
            }
            return line_start;
        }
    }

    return null;
}

/// Parse object number from "N G obj" format.
fn parseObjectNumber(data: []const u8, start: usize) ?u32 {
    var pos = start;

    // Skip whitespace
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) {
        pos += 1;
    }

    // Parse number
    const num_start = pos;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        pos += 1;
    }

    if (pos == num_start) return null;

    return std.fmt.parseInt(u32, data[num_start..pos], 10) catch null;
}

/// Result type for FlateDecode decompression with ratio-awareness.
const DecompressFlateResult = union(enum) {
    ok: []u8,
    exceeded_limit,
    corrupt,
    data_error,
    alloc_error,
};

/// Validate all embedded files in a PDF with recursive format validation.
pub fn validatePdfEmbeddedFiles(
    allocator: Allocator,
    pdf_data: []const u8,
    detect_format_fn: *const fn ([]const u8) u8, // Returns format ID
    validate_fn: *const fn (Allocator, []const u8, u8) bool, // Validates data with format
) EmbeddedFileValidationSummary {
    const files = extractEmbeddedFiles(allocator, pdf_data) catch {
        return EmbeddedFileValidationSummary.invalid(0, 0, 0, "Failed to extract embedded files");
    };
    defer allocator.free(files);

    if (files.len == 0) {
        return EmbeddedFileValidationSummary.ok(0, 0, 0);
    }

    var validated: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;
    var skipped_size_limit: u32 = 0;

    for (files) |file| {
        const stream_data = pdf_data[file.stream_start..file.stream_end];

        // Decompress if needed
        var decompressed_data: ?[]u8 = null;
        defer if (decompressed_data) |d| allocator.free(d);

        const file_data: []const u8 = blk: {
            if (file.filter) |filter| {
                if (filter == .flate_decode) {
                    // Handle flate_decode separately with ratio-aware decompression
                    switch (decompressFlate(allocator, stream_data)) {
                        .ok => |d| {
                            decompressed_data = d;
                            break :blk d;
                        },
                        .exceeded_limit => {
                            skipped += 1;
                            skipped_size_limit += 1;
                            continue;
                        },
                        .corrupt => {
                            failed += 1;
                            continue;
                        },
                        .data_error, .alloc_error => {
                            skipped += 1;
                            continue;
                        },
                    }
                }
                // Other decoders still return ?[]u8
                const decoded: ?[]u8 = switch (filter) {
                    .flate_decode => unreachable,
                    .ascii_hex_decode => ascii_hex_decoder.decode(allocator, stream_data) catch null,
                    .ascii85_decode => ascii85_decoder.decode(allocator, stream_data) catch null,
                    .lzw_decode => lzw_decoder.decode(allocator, stream_data) catch null,
                    .run_length_decode => run_length_decoder.decode(allocator, stream_data) catch null,
                    else => null,
                };
                if (decoded) |d| {
                    decompressed_data = d;
                    break :blk d;
                } else {
                    skipped += 1;
                    continue;
                }
            } else {
                break :blk stream_data;
            }
        };

        // Detect format and validate recursively
        const format_id = detect_format_fn(file_data);
        if (format_id == 0) {
            // Unknown format - skip
            skipped += 1;
            continue;
        }

        if (validate_fn(allocator, file_data, format_id)) {
            validated += 1;
        } else {
            failed += 1;
        }
    }

    if (failed > 0) {
        return EmbeddedFileValidationSummary.invalid(@intCast(files.len), validated, failed, "One or more embedded files failed validation");
    }

    var result = EmbeddedFileValidationSummary.ok(@intCast(files.len), validated, skipped);
    result.skipped_size_limit = skipped_size_limit;
    return result;
}

/// Simplified validation without recursive dispatch (just extracts and decompresses).
pub fn validatePdfEmbeddedFilesBasic(allocator: Allocator, pdf_data: []const u8) EmbeddedFileValidationSummary {
    const files = extractEmbeddedFiles(allocator, pdf_data) catch {
        return EmbeddedFileValidationSummary.invalid(0, 0, 0, "Failed to extract embedded files");
    };
    defer allocator.free(files);

    if (files.len == 0) {
        return EmbeddedFileValidationSummary.ok(0, 0, 0);
    }

    var validated: u32 = 0;
    var skipped: u32 = 0;
    var skipped_size_limit: u32 = 0;
    var skipped_corrupt: u32 = 0;

    for (files) |file| {
        const stream_data = pdf_data[file.stream_start..file.stream_end];

        // Try to decompress if filtered
        if (file.filter) |filter| {
            if (filter == .flate_decode) {
                // Handle flate_decode separately with ratio-aware decompression
                switch (decompressFlate(allocator, stream_data)) {
                    .ok => |d| {
                        allocator.free(d);
                        validated += 1;
                    },
                    .exceeded_limit => {
                        skipped += 1;
                        skipped_size_limit += 1;
                    },
                    .corrupt => {
                        skipped += 1;
                        skipped_corrupt += 1;
                    },
                    .data_error, .alloc_error => {
                        skipped += 1;
                    },
                }
            } else {
                // Other decoders still return ?[]u8
                const decoded: ?[]u8 = switch (filter) {
                    .ascii_hex_decode => ascii_hex_decoder.decode(allocator, stream_data) catch null,
                    .ascii85_decode => ascii85_decoder.decode(allocator, stream_data) catch null,
                    .lzw_decode => lzw_decoder.decode(allocator, stream_data) catch null,
                    .run_length_decode => run_length_decoder.decode(allocator, stream_data) catch null,
                    else => null,
                };
                if (decoded) |d| {
                    allocator.free(d);
                    validated += 1;
                } else {
                    skipped += 1;
                }
            }
        } else {
            // Uncompressed - just count as validated
            validated += 1;
        }
    }

    var result = EmbeddedFileValidationSummary.ok(@intCast(files.len), validated, skipped);
    result.skipped_size_limit = skipped_size_limit;
    result.skipped_corrupt = skipped_corrupt;
    return result;
}

/// Decompress FlateDecode data with ratio-aware decompression.
/// Uses bundled zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
/// Tolerates Adobe-InDesign-style truncated-Adler-32 streams via the lenient
/// decoder (see zlib.inflateZlibLenientAllocWithRatio). Returns a tagged
/// union distinguishing successful decompression, size limit exceeded,
/// suspected zip bomb (corrupt), and data/alloc errors.
fn decompressFlate(allocator: Allocator, compressed: []const u8) DecompressFlateResult {
    const max_output: usize = 256 * 1024 * 1024; // 256MB max for embedded files

    switch (zlib.inflateZlibLenientAllocWithRatio(allocator, compressed, max_output)) {
        .ok => |data| return .{ .ok = data },
        .ok_lenient => |data| {
            // Adobe-InDesign-style truncated-Adler-32 quirk; surface as WARN
            // by setting the shared per-thread flag read by the top-level
            // PDF deep validator.
            @import("pdf_image_validator.zig").lenient_recovery_seen = true;
            return .{ .ok = data };
        },
        .exceeded_limit => |info| {
            if (info.ratio > 100) return .corrupt;
            return .exceeded_limit;
        },
        .data_error => {},
        .alloc_error => return .alloc_error,
    }

    switch (zlib.inflateRawAllocWithRatio(allocator, compressed, max_output)) {
        .ok, .ok_lenient => |data| return .{ .ok = data },
        .exceeded_limit => |info| {
            if (info.ratio > 100) return .corrupt;
            return .exceeded_limit;
        },
        .data_error => return .data_error,
        .alloc_error => return .alloc_error,
    }
}

// ============ Tests ============

test "findObjectStart basic" {
    const data = "1 0 obj\n<< /Type /EmbeddedFile >>";
    const result = findObjectStart(data, 20);
    try std.testing.expectEqual(@as(?usize, 0), result);
}

test "parseObjectNumber basic" {
    const data = "123 0 obj";
    const result = parseObjectNumber(data, 0);
    try std.testing.expectEqual(@as(?u32, 123), result);
}

test "empty PDF has no embedded files" {
    const allocator = std.testing.allocator;
    const result = validatePdfEmbeddedFilesBasic(allocator, "");
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 0), result.total_files);
}

test "extractEmbeddedFiles finds EmbeddedFile objects" {
    const allocator = std.testing.allocator;

    // Minimal PDF-like structure with embedded file
    const pdf_data =
        \\5 0 obj
        \\<< /Type /EmbeddedFile /Length 4 >>
        \\stream
        \\test
        \\endstream
        \\endobj
    ;

    const files = try extractEmbeddedFiles(allocator, pdf_data);
    defer allocator.free(files);

    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqual(@as(u32, 5), files[0].object_num);
}

test "EmbeddedFileValidationSummary tracks skip reasons" {
    const summary = EmbeddedFileValidationSummary{
        .total_files = 5,
        .validated = 3,
        .skipped = 2,
        .skipped_size_limit = 1,
        .skipped_corrupt = 1,
        .failed = 0,
        .valid = true,
        .error_message = null,
    };
    try std.testing.expectEqual(@as(u32, 1), summary.skipped_size_limit);
    try std.testing.expectEqual(@as(u32, 1), summary.skipped_corrupt);
}
