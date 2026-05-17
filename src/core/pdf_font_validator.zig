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
const pdf_decryptor = @import("pdf_decryptor.zig");

pub const PdfFontType = enum {
    type1, // /FontFile - Type1 PFB/PFA
    truetype, // /FontFile2 - TrueType
    cff, // /FontFile3 /Type1C - CFF
    opentype, // /FontFile3 /OpenType - OpenType
    cid_cff, // /FontFile3 /CIDFontType0C - CIDFont CFF
};

pub const PdfFontInfo = struct {
    object_num: u32,
    gen_num: u32 = 0,
    font_type: PdfFontType,
    stream_start: usize,
    stream_end: usize,
    filter: ?pdf_image_validator.ImageFilter,
};

pub const FontValidationSummary = struct {
	total_fonts: u32,
	validated: u32,
	skipped: u32,
	skipped_size_limit: u32 = 0, // Streams exceeding decompression size limit
	skipped_corrupt: u32 = 0, // Streams with suspicious compression ratio (>100:1)
	failed: u32,
	valid: bool,
	error_message: ?[]const u8,
	first_error_message: ?[]const u8 = null,
	/// When deep font validation is skipped wholesale (not per-stream-skipped
	/// for size or corruption, but completely bypassed because we can't run
	/// the check at all — e.g. encrypted PDF with non-empty password,
	/// unsupported encryption variant), this carries the user-visible
	/// reason. Required to honor the project's "no silent skip" invariant
	/// (RULES.md): every skipped deep check must surface to the verdict
	/// surface, INFO at minimum.
	skip_reason: ?[]const u8 = null,

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

	/// Like `ok` but carries a reason describing why deep validation was
	/// skipped wholesale. The consumer is responsible for surfacing the
	/// reason to the verdict (typically as an INFO-tier annotation).
	/// Use this whenever a code path decides "I can't run deep font
	/// validation here" — never silently fall through to plain `ok`.
	pub fn okSkipped(total: u32, reason: []const u8) FontValidationSummary {
		return .{
			.total_fonts = total,
			.validated = 0,
			.skipped = total,
			.failed = 0,
			.valid = true,
			.error_message = null,
			.first_error_message = null,
			.skip_reason = reason,
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
    // Deduplicate by object number — the same font can be referenced from multiple
    // pages/descriptors, and we only need to validate it once.
    var font_refs: std.ArrayListUnmanaged(struct { obj_num: u32, font_type: PdfFontType }) = .empty;
    defer font_refs.deinit(allocator);
    var seen_obj_nums: std.AutoHashMapUnmanaged(u32, void) = .{};
    defer seen_obj_nums.deinit(allocator);

    var pos: usize = 0;
    while (pos < pdf_data.len) {
        const fontfile_pos = std.mem.indexOfPos(u8, pdf_data, pos, "/FontFile") orelse break;

        const font_type_result = determineFontType(pdf_data, fontfile_pos);
        if (font_type_result.font_type) |font_type| {
            const obj_ref_start = fontfile_pos + font_type_result.keyword_len;
            if (obj_ref_start < pdf_data.len) {
                if (parseObjectReference(pdf_data, obj_ref_start)) |obj_num| {
                    if (!seen_obj_nums.contains(obj_num)) {
                        seen_obj_nums.put(allocator, obj_num, {}) catch return error.OutOfMemory;
                        font_refs.append(allocator, .{ .obj_num = obj_num, .font_type = font_type }) catch return error.OutOfMemory;
                    }
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
    var fonts: std.ArrayListUnmanaged(PdfFontInfo) = .empty;
    errdefer fonts.deinit(allocator);

    for (font_refs.items) |ref| {
        if (findObjectStreamIndexed(pdf_data, ref.obj_num, &index)) |stream_info| {
            fonts.append(allocator, .{
                .object_num = ref.obj_num,
                .gen_num = stream_info.gen_num,
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
    gen_num: u32 = 0,
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
    // Parse generation number from "N G obj" header at obj_pos. Needed for
    // per-object key derivation in encrypted PDFs (see pdf_decryptor.decryptStream).
    const gen_num: u32 = blk: {
        var p = obj_pos;
        while (p < data.len and (data[p] == ' ' or data[p] == '\t')) p += 1;
        // skip N
        while (p < data.len and data[p] >= '0' and data[p] <= '9') p += 1;
        while (p < data.len and (data[p] == ' ' or data[p] == '\t')) p += 1;
        const g_start = p;
        while (p < data.len and data[p] >= '0' and data[p] <= '9') p += 1;
        if (p > g_start) {
            break :blk std.fmt.parseInt(u32, data[g_start..p], 10) catch 0;
        }
        break :blk 0;
    };

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
        .gen_num = gen_num,
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

/// Cached decompression result for a stream byte range, avoiding redundant inflate calls.
const CachedDecompressResult = enum {
    ok,
    exceeded_limit,
    corrupt,
    data_error,
    alloc_error,
    decode_failed,
};

/// Key for the decompression cache: identifies a unique stream byte range.
const StreamRange = struct {
    start: usize,
    end: usize,
};

/// Validate all embedded fonts in a PDF.
/// Uses a decompression cache to avoid re-inflating the same stream data when
/// multiple font references resolve to identical byte ranges (e.g., same font
/// referenced from multiple pages).
pub fn validatePdfFonts(allocator: Allocator, pdf_data: []const u8) FontValidationSummary {
    const fonts = extractFontStreams(allocator, pdf_data) catch {
        return FontValidationSummary.invalid(0, 0, 0, "Failed to extract font streams");
    };
    defer allocator.free(fonts);

    if (fonts.len == 0) {
        return FontValidationSummary.ok(0, 0, 0);
    }

    // Encrypted PDFs: each font stream is RC4/AES-encrypted at the byte
    // level (PDF crypto applies BEFORE FlateDecode). Mirror the
    // pdf_image_validator pattern: parse the /Encrypt dictionary, attempt
    // empty-password decryption, and if that succeeds, decrypt every stream
    // with its per-object key before running deep validation.
    //
    // If the encryption variant is unsupported (V5+/AES-256) or the user
    // password is non-empty, we cannot deeply validate the fonts. Per the
    // project's "no silent skip" invariant (RULES.md), every such skip
    // MUST surface a reason — INFO-tier annotation at minimum. The caller
    // (pdf_validator.zig) consumes FontValidationSummary.skip_reason and
    // routes it to the verdict.
    var decryption_succeeded: bool = false;
    var encryption_key: ?[16]u8 = null;
    var key_length: u8 = 0;
    var use_aes: bool = false;
    var encryption_present: bool = false;
    var skip_reason: ?[]const u8 = null;

    if (pdf_decryptor.parseEncryptionParams(pdf_data)) |enc_params| {
        encryption_present = true;
        const decrypt_result = pdf_decryptor.tryEmptyPassword(enc_params);
        if (decrypt_result.success) {
            decryption_succeeded = true;
            encryption_key = decrypt_result.encryption_key;
            key_length = decrypt_result.key_length;
            use_aes = decrypt_result.use_aes;
        } else {
            skip_reason = "embedded font deep validation skipped — PDF encryption uses a non-empty password or unsupported variant; per-stream decryption unavailable";
        }
    } else if (std.mem.indexOf(u8, pdf_data, "/Encrypt") != null) {
        // /Encrypt is declared but the encryption dictionary couldn't be
        // parsed (broken reference, missing /O / /U / /ID, etc.).
        encryption_present = true;
        skip_reason = "embedded font deep validation skipped — PDF /Encrypt declared but encryption dictionary could not be parsed";
    }

    if (encryption_present and !decryption_succeeded) {
        const total: u32 = @intCast(fonts.len);
        return FontValidationSummary.okSkipped(total, skip_reason orelse "embedded font deep validation skipped — encrypted PDF, key derivation failed");
    }

    // Decompression cache: keyed by (stream_start, stream_end) byte range.
    // Stores the decompressed data and the result status so we can replay
    // skip/fail decisions without re-decompressing.
    var decompress_cache = std.AutoHashMapUnmanaged(StreamRange, struct {
        data: ?[]u8,
        status: CachedDecompressResult,
    }){};
    defer {
        var cache_iter = decompress_cache.valueIterator();
        while (cache_iter.next()) |entry| {
            if (entry.data) |d| allocator.free(d);
        }
        decompress_cache.deinit(allocator);
    }

    var validated: u32 = 0;
    var skipped: u32 = 0;
    var skipped_size_limit: u32 = 0;
    var skipped_corrupt: u32 = 0;
    var failed: u32 = 0;
    var first_error: ?[]const u8 = null;

    for (fonts) |fnt| {
        const raw_stream = pdf_data[fnt.stream_start..fnt.stream_end];
        // Decrypt the raw stream bytes if the PDF is encrypted. PDF crypto
        // applies BEFORE filters (FlateDecode etc.), so this must precede the
        // decompression cache. We allocate a fresh buffer for the decrypted
        // bytes; if decryption fails for this object, we skip rather than fail.
        var decrypted_data: ?[]u8 = null;
        defer if (decrypted_data) |d| allocator.free(d);
        const stream_data: []const u8 = if (decryption_succeeded) blk_dec: {
            const key = encryption_key.?;
            const dec = pdf_decryptor.decryptStream(
                allocator,
                raw_stream,
                key[0..key_length],
                fnt.object_num,
                fnt.gen_num,
                use_aes,
            ) catch null;
            if (dec) |d| {
                decrypted_data = d;
                break :blk_dec d;
            }
            skipped += 1;
            continue;
        } else raw_stream;
        const range_key = StreamRange{ .start = fnt.stream_start, .end = fnt.stream_end };

        // Check decompression cache first
        const font_data = blk: {
            if (fnt.filter) |filter| {
                // Look up cache for this byte range
                if (decompress_cache.get(range_key)) |cached| {
                    switch (cached.status) {
                        .ok => break :blk cached.data.?,
                        .exceeded_limit => {
                            skipped += 1;
                            skipped_size_limit += 1;
                            continue;
                        },
                        .corrupt => {
                            failed += 1;
                            skipped_corrupt += 1;
                            if (first_error == null) {
                                first_error = "FlateDecode decompression bomb (ratio >100:1)";
                            }
                            continue;
                        },
                        .data_error, .alloc_error, .decode_failed => {
                            skipped += 1;
                            continue;
                        },
                    }
                }

                // Cache miss — decompress and store result
                if (filter == .flate_decode) {
                    switch (decompressFlate(allocator, stream_data)) {
                        .ok => |d| {
                            decompress_cache.put(allocator, range_key, .{ .data = d, .status = .ok }) catch {};
                            break :blk d;
                        },
                        .exceeded_limit => {
                            decompress_cache.put(allocator, range_key, .{ .data = null, .status = .exceeded_limit }) catch {};
                            skipped += 1;
                            skipped_size_limit += 1;
                            continue;
                        },
                        .corrupt => {
                            decompress_cache.put(allocator, range_key, .{ .data = null, .status = .corrupt }) catch {};
                            failed += 1;
                            skipped_corrupt += 1;
                            if (first_error == null) {
                                first_error = "FlateDecode decompression bomb (ratio >100:1)";
                            }
                            continue;
                        },
                        .data_error => {
                            decompress_cache.put(allocator, range_key, .{ .data = null, .status = .data_error }) catch {};
                            skipped += 1;
                            continue;
                        },
                        .alloc_error => {
                            decompress_cache.put(allocator, range_key, .{ .data = null, .status = .alloc_error }) catch {};
                            skipped += 1;
                            continue;
                        },
                    }
                }

                // Other decoders return ?[]u8
                const decoded: ?[]u8 = switch (filter) {
                    .ascii_hex_decode => ascii_hex_decoder.decode(allocator, stream_data) catch null,
                    .ascii85_decode => ascii85_decoder.decode(allocator, stream_data) catch null,
                    .lzw_decode => lzw_decoder.decode(allocator, stream_data) catch null,
                    .run_length_decode => run_length_decoder.decode(allocator, stream_data) catch null,
                    else => null,
                };
                if (decoded) |d| {
                    decompress_cache.put(allocator, range_key, .{ .data = d, .status = .ok }) catch {};
                    break :blk d;
                } else {
                    decompress_cache.put(allocator, range_key, .{ .data = null, .status = .decode_failed }) catch {};
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
        const strict_options = font_validator.ValidationOptions{ .skip_checksums = false, .lenient_checksums = true };
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
        var summary = FontValidationSummary.withWarnings(@intCast(fonts.len), validated, skipped, failed, first_error);
        summary.skipped_size_limit = skipped_size_limit;
        summary.skipped_corrupt = skipped_corrupt;
        return summary;
    }

    var summary = FontValidationSummary.ok(@intCast(fonts.len), validated, skipped);
    summary.skipped_size_limit = skipped_size_limit;
    summary.skipped_corrupt = skipped_corrupt;
    return summary;
}

/// Tagged result for FlateDecode decompression, distinguishing size limits from corruption.
const DecompressFlateResult = union(enum) {
    ok: []u8,
    exceeded_limit,
    corrupt,
    data_error,
    alloc_error,
};

/// Decompress FlateDecode data with ratio-aware bomb detection.
/// Uses bundled zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
/// Tolerates Adobe-InDesign-style truncated-Adler-32 streams via the lenient
/// decoder (see zlib.inflateZlibLenientAllocWithRatio).
fn decompressFlate(allocator: Allocator, compressed: []const u8) DecompressFlateResult {
    const max_output: usize = 64 * 1024 * 1024; // 64MB max for fonts

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
        .data_error => {}, // Fall through to raw deflate
        .alloc_error => return .alloc_error,
    }

    // Final fallback: raw deflate without zlib wrapper
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

test "FontValidationSummary tracks skip reasons" {
    const summary = FontValidationSummary{
        .total_fonts = 5,
        .validated = 2,
        .skipped = 3,
        .skipped_size_limit = 1,
        .skipped_corrupt = 1,
        .failed = 0,
        .valid = true,
        .error_message = null,
    };
    try std.testing.expectEqual(@as(u32, 1), summary.skipped_size_limit);
    try std.testing.expectEqual(@as(u32, 1), summary.skipped_corrupt);
    // Verify defaults are zero when not specified
    const summary2 = FontValidationSummary.ok(3, 2, 1);
    try std.testing.expectEqual(@as(u32, 0), summary2.skipped_size_limit);
    try std.testing.expectEqual(@as(u32, 0), summary2.skipped_corrupt);
}

test "extractFontStreams deduplicates by object number" {
    const allocator = std.testing.allocator;

    // PDF-like data with the same font object (42) referenced three times
    // from different font descriptors
    const pdf_data =
        "1 0 obj\n<< /Type /FontDescriptor /FontFile2 42 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /FontDescriptor /FontFile2 42 0 R >>\nendobj\n" ++
        "3 0 obj\n<< /Type /FontDescriptor /FontFile2 42 0 R >>\nendobj\n" ++
        "42 0 obj\n<< /Length 4 >>\nstream\nABCD\nendstream\nendobj\n";

    const fonts = try extractFontStreams(allocator, pdf_data);
    defer allocator.free(fonts);

    // Should be deduplicated to a single entry, not three
    try std.testing.expectEqual(@as(usize, 1), fonts.len);
    try std.testing.expectEqual(@as(u32, 42), fonts[0].object_num);
}

test "extractFontStreams keeps distinct objects" {
    const allocator = std.testing.allocator;

    // PDF-like data with two different font objects
    const pdf_data =
        "1 0 obj\n<< /Type /FontDescriptor /FontFile2 42 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Type /FontDescriptor /FontFile2 43 0 R >>\nendobj\n" ++
        "42 0 obj\n<< /Length 4 >>\nstream\nABCD\nendstream\nendobj\n" ++
        "43 0 obj\n<< /Length 4 >>\nstream\nEFGH\nendstream\nendobj\n";

    const fonts = try extractFontStreams(allocator, pdf_data);
    defer allocator.free(fonts);

    // Both distinct font objects should be present
    try std.testing.expectEqual(@as(usize, 2), fonts.len);
}

test "StreamRange cache key equality" {
    // Verify the cache key type works correctly with AutoHashMap
    const a = StreamRange{ .start = 100, .end = 200 };
    const b = StreamRange{ .start = 100, .end = 200 };
    const c = StreamRange{ .start = 100, .end = 300 };

    // AutoHashMap uses @hasDecl for eql/hash, but for packed structs
    // it falls back to byte-level comparison which works for our case.
    const ctx = std.hash_map.AutoContext(StreamRange){};
    try std.testing.expect(ctx.eql(a, b));
    try std.testing.expect(!ctx.eql(a, c));
    try std.testing.expectEqual(ctx.hash(a), ctx.hash(b));
}

// Encrypted PDFs with empty user password (the common "trivial protection"
// case used by tools like Ghostscript and many commercial PDF generators)
// must have their font streams RC4/AES-decrypted before validation. Without
// per-stream decryption, every CFF / Type1 / sfnt header check would compare
// against ciphertext and produce false-positive WARNs. This test pins the
// behavior contract: when empty-password decryption succeeds, the validator
// runs deep checks on the decrypted bytes (validated >= 1, no failures).
// Mirrors the per-stream decryption pattern in pdf_image_validator.
test "validatePdfFonts deep-validates fonts in empty-password encrypted PDFs" {
    const allocator = std.testing.allocator;

    // Real Ghostscript-produced PDF, encrypted via qpdf with empty user
    // password and 40-bit RC4 (V=1 R=2). Contains one /FontFile3 (CFF)
    // stream that decrypts to a valid CFF blob.
    const pdf_data = @embedFile("fixtures/encrypted_v1r2_with_font.pdf");

    const result = validatePdfFonts(allocator, pdf_data);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.total_fonts >= 1);
    // Deep validation must run: at least one font validated, none failed.
    try std.testing.expect(result.validated >= 1);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(?[]const u8, null), result.first_error_message);
}

// When a PDF declares /Encrypt but the encryption object cannot be parsed
// (broken reference, malformed dictionary, etc.), the font validator must
// gracefully skip rather than feed undecrypted bytes to the deep checks
// (which would WARN noisily about "Invalid sfnt version" et al.).
test "validatePdfFonts skips fonts when /Encrypt is present but unparseable" {
    const allocator = std.testing.allocator;

    // /Encrypt 99 0 R points to a non-existent object — parseEncryptionParams
    // returns null. Font stream contains nonsense (would WARN on raw bytes).
    const pdf_data =
        "%PDF-1.4\n" ++
        "1 0 obj\n<< /Type /FontDescriptor /FontFile2 2 0 R >>\nendobj\n" ++
        "2 0 obj\n<< /Length 8 >>\nstream\nGARBAGE!\nendstream\nendobj\n" ++
        "trailer\n<< /Size 3 /Encrypt 99 0 R /Root 1 0 R >>\n" ++
        "startxref\n0\n%%EOF\n";

    const result = validatePdfFonts(allocator, pdf_data);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(?[]const u8, null), result.first_error_message);
    try std.testing.expect(result.total_fonts >= 1);
    try std.testing.expectEqual(result.total_fonts, result.skipped);
}
