//! PDF Embedded Font Validator.
//!
//! Extracts and validates fonts embedded in PDF files:
//! - /FontFile  -> Type1 (PFB/PFA)
//! - /FontFile2 -> TrueType
//! - /FontFile3 -> CFF, OpenType, or Type1C
//!
//! Reference: PDF 1.7 specification, Section 9.9

const std = @import("std");
const Allocator = std.mem.Allocator;
const font_validator = @import("font_validator.zig");
const pdf_image_validator = @import("pdf_image_validator.zig");
const ascii_hex_decoder = @import("ascii_hex_decoder.zig");
const ascii85_decoder = @import("ascii85_decoder.zig");
const run_length_decoder = @import("run_length_decoder.zig");
const lzw_decoder = @import("lzw_decoder.zig");
const zlib = @import("zlib.zig");

pub const PdfFontType = enum {
    type1, // /FontFile - Type1 PFB/PFA
    truetype, // /FontFile2 - TrueType
    cff, // /FontFile3 /Type1C - CFF
    opentype, // /FontFile3 /OpenType - OpenType
    cid_cff, // /FontFile3 /CIDFontType0C - CIDFont CFF
};

pub const PdfFontInfo = struct {
    object_num: u32,
    font_type: PdfFontType,
    stream_start: usize,
    stream_end: usize,
    filter: ?pdf_image_validator.ImageFilter,
};

pub const FontValidationSummary = struct {
	total_fonts: u32,
	validated: u32,
	skipped: u32,
	failed: u32,
	valid: bool,
	error_message: ?[]const u8,
	first_error_message: ?[]const u8 = null,

	pub fn ok(total: u32, validated: u32, skipped: u32) FontValidationSummary {
		return .{
			.total_fonts = total,
			.validated = validated,
			.skipped = skipped,
			.failed = 0,
			.valid = true,
			.error_message = null,
			.first_error_message = null,
		};
	}

    /// For PDF embedded fonts, we don't fail the PDF validation when fonts
    /// fail validation - we just report stats. PDF embedded fonts use
    /// different formats than standalone font files and strict validation
    /// would reject many legitimate PDFs.
	pub fn withWarnings(total: u32, validated: u32, skipped: u32, failed: u32, first_error: ?[]const u8) FontValidationSummary {
		return .{
			.total_fonts = total,
			.validated = validated,
			.skipped = skipped,
			.failed = failed,
			// Valid even if some fonts failed - PDF structure is what matters
			.valid = true,
			.error_message = null,
			.first_error_message = first_error,
		};
	}

	pub fn invalid(total: u32, validated: u32, failed: u32, msg: []const u8) FontValidationSummary {
		return .{
			.total_fonts = total,
			.validated = validated,
			.skipped = 0,
			.failed = failed,
			.valid = false,
			.error_message = msg,
			.first_error_message = null,
		};
	}
};

/// Extract embedded font streams from a PDF.
/// Returns list of font info structs with stream locations.
/// Uses O(n) indexing pass + O(1) lookups instead of O(n²) linear scans.
pub fn extractFontStreams(allocator: Allocator, pdf_data: []const u8) ![]PdfFontInfo {
    // First, collect all font object references (fast linear scan for /FontFile*)
    var font_refs: std.ArrayListUnmanaged(struct { obj_num: u32, font_type: PdfFontType }) = .{};
    defer font_refs.deinit(allocator);

    var pos: usize = 0;
    while (pos < pdf_data.len) {
        const fontfile_pos = std.mem.indexOfPos(u8, pdf_data, pos, "/FontFile") orelse break;

        const font_type_result = determineFontType(pdf_data, fontfile_pos);
        if (font_type_result.font_type) |font_type| {
            const obj_ref_start = fontfile_pos + font_type_result.keyword_len;
            if (obj_ref_start < pdf_data.len) {
                if (parseObjectReference(pdf_data, obj_ref_start)) |obj_num| {
                    font_refs.append(allocator, .{ .obj_num = obj_num, .font_type = font_type }) catch return error.OutOfMemory;
                }
            }
        }
        pos = fontfile_pos + 9;
    }

    if (font_refs.items.len == 0) {
        return allocator.alloc(PdfFontInfo, 0) catch return error.OutOfMemory;
    }

    // Build object index once (O(n) scan of PDF)
    var index = ObjectIndex.init(allocator);
    defer index.deinit();
    index.build(pdf_data) catch return error.OutOfMemory;

    // Now look up each font object using the index (O(1) per lookup)
    var fonts: std.ArrayListUnmanaged(PdfFontInfo) = .{};
    errdefer fonts.deinit(allocator);

    for (font_refs.items) |ref| {
        if (findObjectStreamIndexed(pdf_data, ref.obj_num, &index)) |stream_info| {
            fonts.append(allocator, .{
                .object_num = ref.obj_num,
                .font_type = ref.font_type,
                .stream_start = stream_info.start,
                .stream_end = stream_info.end,
                .filter = stream_info.filter,
            }) catch return error.OutOfMemory;
        }
    }

    return fonts.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const FontTypeResult = struct {
    font_type: ?PdfFontType,
    keyword_len: usize,
};

fn determineFontType(data: []const u8, pos: usize) FontTypeResult {
    // Check for /FontFile3 first (most specific)
    if (pos + 10 <= data.len and std.mem.eql(u8, data[pos..][0..10], "/FontFile3")) {
        // Need to find /Subtype in the object to determine actual type
        // For now, default to CFF
        return .{ .font_type = .cff, .keyword_len = 10 };
    }

    // Check for /FontFile2 (TrueType)
    if (pos + 10 <= data.len and std.mem.eql(u8, data[pos..][0..10], "/FontFile2")) {
        return .{ .font_type = .truetype, .keyword_len = 10 };
    }

    // Check for /FontFile (Type1)
    if (pos + 9 <= data.len and std.mem.eql(u8, data[pos..][0..9], "/FontFile")) {
        // Make sure it's not /FontFile2 or /FontFile3
        if (pos + 10 <= data.len and (data[pos + 9] == '2' or data[pos + 9] == '3')) {
            return .{ .font_type = null, .keyword_len = 0 };
        }
        return .{ .font_type = .type1, .keyword_len = 9 };
    }

    return .{ .font_type = null, .keyword_len = 0 };
}

/// Parse an object reference like "123 0 R"
fn parseObjectReference(data: []const u8, start: usize) ?u32 {
    var pos = start;

    // Skip whitespace
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or data[pos] == '\r' or data[pos] == '\t')) {
        pos += 1;
    }

    // Parse object number
    const num_start = pos;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        pos += 1;
    }

    if (pos == num_start) return null;

    const obj_num = std.fmt.parseInt(u32, data[num_start..pos], 10) catch return null;

    // Skip whitespace
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or data[pos] == '\r' or data[pos] == '\t')) {
        pos += 1;
    }

    // Expect generation number
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        pos += 1;
    }

    // Skip whitespace
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\n' or data[pos] == '\r' or data[pos] == '\t')) {
        pos += 1;
    }

    // Expect 'R'
    if (pos >= data.len or data[pos] != 'R') return null;

    return obj_num;
}

const StreamInfo = struct {
    start: usize,
    end: usize,
    filter: ?pdf_image_validator.ImageFilter,
};

/// Object index for O(1) lookups instead of O(n) linear scans.
/// Built once, then used for all object lookups.
const ObjectIndex = struct {
    /// Maps object_num -> offset in PDF data where "N 0 obj" starts
    offsets: std.AutoHashMapUnmanaged(u32, usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ObjectIndex {
        return .{
            .offsets = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ObjectIndex) void {
        self.offsets.deinit(self.allocator);
    }

    /// Build index by scanning PDF once for all object definitions.
    pub fn build(self: *ObjectIndex, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            // Look for " obj" or start of line followed by digits
            const obj_marker = std.mem.indexOfPos(u8, data, pos, " obj") orelse break;

            // Backtrack to find "N G obj" pattern
            // We need to find the object number before " obj"
            if (obj_marker < 3) {
                pos = obj_marker + 4;
                continue;
            }

            // Find the start of this line/object definition
            var line_start = obj_marker;
            while (line_start > 0 and data[line_start - 1] != '\n' and data[line_start - 1] != '\r') {
                line_start -= 1;
            }

            // Try to parse "N G obj" from line_start
            var parse_pos = line_start;

            // Skip leading whitespace
            while (parse_pos < obj_marker and (data[parse_pos] == ' ' or data[parse_pos] == '\t')) {
                parse_pos += 1;
            }

            // Parse object number
            const num_start = parse_pos;
            while (parse_pos < obj_marker and data[parse_pos] >= '0' and data[parse_pos] <= '9') {
                parse_pos += 1;
            }

            if (parse_pos > num_start) {
                if (std.fmt.parseInt(u32, data[num_start..parse_pos], 10)) |obj_num| {
                    // Skip whitespace
                    while (parse_pos < obj_marker and (data[parse_pos] == ' ' or data[parse_pos] == '\t')) {
                        parse_pos += 1;
                    }

                    // Skip generation number
                    while (parse_pos < obj_marker and data[parse_pos] >= '0' and data[parse_pos] <= '9') {
                        parse_pos += 1;
                    }

                    // Skip whitespace before "obj"
                    while (parse_pos < obj_marker and (data[parse_pos] == ' ' or data[parse_pos] == '\t')) {
                        parse_pos += 1;
                    }

                    // Verify we're at " obj"
                    if (parse_pos == obj_marker) {
                        try self.offsets.put(self.allocator, obj_num, line_start);
                    }
                } else |_| {}
            }

            pos = obj_marker + 4;
        }
    }

    /// Look up object offset by number.
    pub fn getOffset(self: *const ObjectIndex, obj_num: u32) ?usize {
        return self.offsets.get(obj_num);
    }
};

/// Thread-local object index for the current PDF being validated.
threadlocal var current_object_index: ?*ObjectIndex = null;

/// Find an object's stream by object number using the pre-built index.
fn findObjectStreamIndexed(data: []const u8, obj_num: u32, index: *const ObjectIndex) ?StreamInfo {
    const obj_pos = index.getOffset(obj_num) orelse return null;
    return findObjectStreamAtOffset(data, obj_pos);
}

/// Find stream info starting at a known object offset.
fn findObjectStreamAtOffset(data: []const u8, obj_pos: usize) ?StreamInfo {
    // Find the stream within this object
    const obj_end_search_limit = @min(obj_pos + 65536, data.len);
    const stream_start_marker = std.mem.indexOfPos(u8, data[0..obj_end_search_limit], obj_pos, "stream") orelse return null;

    // Skip past "stream" and any whitespace (CRLF or LF)
    var stream_data_start = stream_start_marker + 6;
    if (stream_data_start < data.len and data[stream_data_start] == '\r') {
        stream_data_start += 1;
    }
    if (stream_data_start < data.len and data[stream_data_start] == '\n') {
        stream_data_start += 1;
    }

    // Find endstream
    const endstream_pos = std.mem.indexOfPos(u8, data, stream_data_start, "endstream") orelse return null;

    // Determine filter by looking in object dictionary
    var filter: ?pdf_image_validator.ImageFilter = null;
    const dict_data = data[obj_pos..stream_start_marker];

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

    return .{
        .start = stream_data_start,
        .end = endstream_pos,
        .filter = filter,
    };
}

/// Find an object's stream by object number (legacy O(n) version for compatibility).
fn findObjectStream(data: []const u8, obj_num: u32) ?StreamInfo {
    // Build search pattern "N 0 obj" where N is object number
    var pattern_buf: [32]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{d} 0 obj", .{obj_num}) catch return null;

    // Search for the object definition
    const obj_pos = std.mem.indexOf(u8, data, pattern) orelse return null;

    // Find the stream within this object
    const obj_end_search_limit = @min(obj_pos + 65536, data.len);
    const stream_start_marker = std.mem.indexOfPos(u8, data[0..obj_end_search_limit], obj_pos, "stream") orelse return null;

    // Skip past "stream" and any whitespace (CRLF or LF)
    var stream_data_start = stream_start_marker + 6;
    if (stream_data_start < data.len and data[stream_data_start] == '\r') {
        stream_data_start += 1;
    }
    if (stream_data_start < data.len and data[stream_data_start] == '\n') {
        stream_data_start += 1;
    }

    // Find endstream
    const endstream_pos = std.mem.indexOfPos(u8, data, stream_data_start, "endstream") orelse return null;

    // Determine filter by looking in object dictionary
    var filter: ?pdf_image_validator.ImageFilter = null;
    const dict_data = data[obj_pos..stream_start_marker];

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

    return .{
        .start = stream_data_start,
        .end = endstream_pos,
        .filter = filter,
    };
}

/// Validate all embedded fonts in a PDF.
pub fn validatePdfFonts(allocator: Allocator, pdf_data: []const u8) FontValidationSummary {
    const fonts = extractFontStreams(allocator, pdf_data) catch {
        return FontValidationSummary.invalid(0, 0, 0, "Failed to extract font streams");
    };
    defer allocator.free(fonts);

    if (fonts.len == 0) {
        return FontValidationSummary.ok(0, 0, 0);
    }

    var validated: u32 = 0;
    var skipped: u32 = 0;
    var failed: u32 = 0;
    var first_error: ?[]const u8 = null;

    for (fonts) |fnt| {
        const stream_data = pdf_data[fnt.stream_start..fnt.stream_end];

        // Decompress if needed
        var decompressed_data: ?[]u8 = null;
        defer if (decompressed_data) |d| allocator.free(d);

        const font_data = blk: {
            if (fnt.filter) |filter| {
                const decoded = switch (filter) {
                    .flate_decode => decompressFlate(allocator, stream_data),
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

        // Validate based on font type.
        // We keep PDF-level lenience (warnings instead of invalid),
        // but still compute checksums to validate every byte.
        const strict_options = font_validator.ValidationOptions{ .skip_checksums = false };
        const result = switch (fnt.font_type) {
            .truetype => font_validator.validateTtfOtfWithOptions(font_data, strict_options),
            .type1 => font_validator.validateType1(font_data),
            .cff, .cid_cff => font_validator.validateCff(font_data),
            .opentype => font_validator.validateTtfOtfWithOptions(font_data, strict_options),
        };

        if (result.valid) {
            validated += 1;
        } else {
            failed += 1;
            if (first_error == null) {
                first_error = result.error_message;
            }
        }
    }

    // For PDF embedded fonts, we don't fail validation when fonts fail.
    // PDF uses different embedding formats than standalone font files,
    // and many legitimate PDFs have fonts that don't pass strict validation.
    // The PDF structure validation is what matters for integrity.
    if (failed > 0) {
        return FontValidationSummary.withWarnings(@intCast(fonts.len), validated, skipped, failed, first_error);
    }

    return FontValidationSummary.ok(@intCast(fonts.len), validated, skipped);
}

/// Decompress FlateDecode data.
/// Uses system zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
fn decompressFlate(allocator: Allocator, compressed: []const u8) ?[]u8 {
    const max_output: usize = 64 * 1024 * 1024; // 64MB max for fonts

    // Try zlib format first, then raw deflate
    if (zlib.inflateZlibAlloc(allocator, compressed, max_output)) |data| {
        return data;
    } else |_| {
        return zlib.inflateRawAlloc(allocator, compressed, max_output) catch null;
    }
}

// ============ Tests ============

test "parseObjectReference valid" {
    const data = " 123 0 R more stuff";
    const result = parseObjectReference(data, 0);
    try std.testing.expectEqual(@as(?u32, 123), result);
}

test "parseObjectReference invalid" {
    const data = " abc 0 R";
    const result = parseObjectReference(data, 0);
    try std.testing.expectEqual(@as(?u32, null), result);
}

test "determineFontType FontFile" {
    const data = "/FontFile 123 0 R";
    const result = determineFontType(data, 0);
    try std.testing.expectEqual(PdfFontType.type1, result.font_type.?);
}

test "determineFontType FontFile2" {
    const data = "/FontFile2 456 0 R";
    const result = determineFontType(data, 0);
    try std.testing.expectEqual(PdfFontType.truetype, result.font_type.?);
}

test "determineFontType FontFile3" {
    const data = "/FontFile3 789 0 R";
    const result = determineFontType(data, 0);
    try std.testing.expectEqual(PdfFontType.cff, result.font_type.?);
}

test "empty PDF has no fonts" {
    const allocator = std.testing.allocator;
    const result = validatePdfFonts(allocator, "");
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 0), result.total_fonts);
}
