//! PDF Embedded Image Validator
//!
//! Extracts and validates images embedded in PDF files.
//! Supports:
//! - DCTDecode (JPEG) - validated via libjpeg-turbo
//! - JPXDecode (JPEG2000) - validated via OpenJPEG
//! - JBIG2Decode - validated via pure Zig decoder
//! - FlateDecode - decompressed then checked for nested format
//! - CCITTFaxDecode - structural validation only
//!
//! This module parses PDF structure to find image XObjects and
//! validates their embedded image data.

const std = @import("std");
const Allocator = std.mem.Allocator;
const jpeg_validator = @import("jpeg_validator.zig");
const jpeg2000_validator = @import("jpeg2000_validator.zig");
const jbig2_decoder = @import("jbig2_decoder.zig");
const ccitt_fax_decoder = @import("ccitt_fax_decoder.zig");
const ascii_hex_decoder = @import("ascii_hex_decoder.zig");
const ascii85_decoder = @import("ascii85_decoder.zig");
const run_length_decoder = @import("run_length_decoder.zig");
const lzw_decoder = @import("lzw_decoder.zig");
const pdf_decryptor = @import("pdf_decryptor.zig");
const zlib = @import("zlib.zig");
const thread_pool = @import("thread_pool.zig");

/// Minimum number of images to trigger parallel validation
const PARALLEL_IMAGE_THRESHOLD: usize = 10;

// ============ Types ============

pub const ImageFilter = enum {
    dct_decode, // JPEG
    jpx_decode, // JPEG2000
    jbig2_decode, // JBIG2
    ccitt_fax_decode, // CCITT Fax (G3/G4)
    flate_decode, // Deflate (not an image format, but may wrap images)
    ascii85_decode, // ASCII85 encoding
    ascii_hex_decode, // ASCII Hex encoding
    lzw_decode, // LZW compression
    run_length_decode, // Run-length encoding
    unknown,
};

pub const PdfImageInfo = struct {
    /// Byte offset of stream data start
    stream_start: usize,
    /// Byte offset of stream data end
    stream_end: usize,
    /// Image width (if found)
    width: ?u32,
    /// Image height (if found)
    height: ?u32,
    /// Bits per component
    bits_per_component: ?u8,
    /// Filter chain (in order of application)
    filters: []const ImageFilter,
    /// Object number
    object_num: u32,
    /// Generation number
    gen_num: u32,
    /// JBIG2Globals object number (if JBIG2 with globals)
    jbig2_globals_obj: ?u32,
    /// JBIG2Globals generation number
    jbig2_globals_gen: ?u32,
};

pub const ImageValidationResult = struct {
    object_num: u32,
    filter: ImageFilter,
    valid: bool,
    error_message: ?[]const u8,
    width: u32,
    height: u32,
};

pub const PdfImageValidationResult = struct {
    valid: bool,
    total_images: u32,
    validated_images: u32,
    failed_images: u32,
    skipped_images: u32, // Images with filters we can't decode
    results: []const ImageValidationResult,
    error_message: ?[]const u8,
    is_encrypted: bool = false, // True if PDF uses encryption
    decryption_succeeded: bool = false, // True if we decrypted with empty password

    pub fn deinit(self: *PdfImageValidationResult, allocator: Allocator) void {
        allocator.free(self.results);
    }
};

// ============ Decompression ============

/// Decompress FlateDecode (zlib) data
/// Uses system zlib instead of Zig's buggy std.compress.flate (ziglang/zig#24963).
/// Returns allocated buffer that caller must free
pub fn decompressFlate(allocator: Allocator, compressed: []const u8) ![]u8 {
    if (compressed.len < 2) return error.DataTooShort;

    // PDF FlateDecode uses zlib format (has header/footer)
    // Try zlib first, then raw deflate if that fails (some PDFs use raw)
    const max_output: usize = 512 * 1024 * 1024; // 512MB max decompressed size

    // Try zlib format first
    if (zlib.inflateZlibAlloc(allocator, compressed, max_output)) |data| {
        return data;
    } else |_| {
        // Try raw deflate format
        return zlib.inflateRawAlloc(allocator, compressed, max_output) catch |err| {
            return switch (err) {
                zlib.ZlibError.DataError => error.InvalidData,
                zlib.ZlibError.BufferError => error.OutputTooLarge,
                zlib.ZlibError.OutOfMemory => error.OutOfMemory,
                else => error.DecompressionFailed,
            };
        };
    }
}

/// Detect the actual image format after FlateDecode decompression
pub fn detectDecompressedFormat(data: []const u8) ?ImageFilter {
    if (data.len < 4) return null;

    // Check for JPEG (FFD8FF)
    if (data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF) {
        return .dct_decode;
    }

    // Check for JPEG2000 JP2 box (0000000C6A502020)
    if (data.len >= 12 and
        data[0] == 0x00 and data[1] == 0x00 and data[2] == 0x00 and data[3] == 0x0C and
        data[4] == 0x6A and data[5] == 0x50 and data[6] == 0x20 and data[7] == 0x20)
    {
        return .jpx_decode;
    }

    // Check for JPEG2000 codestream (FF4F)
    if (data[0] == 0xFF and data[1] == 0x4F) {
        return .jpx_decode;
    }

    // Most FlateDecode images are raw pixel data - no nested format
    return null;
}

/// Apply a filter chain to decode data.
/// Filters are applied in order (first filter in array is applied first).
/// Returns decoded data - caller must free the result.
/// Returns null if any filter fails or is unsupported.
pub fn applyFilterChain(allocator: Allocator, data: []const u8, filters: []const ImageFilter) ?[]u8 {
    if (filters.len == 0) return null;

    var current_data: []const u8 = data;
    var allocated_data: ?[]u8 = null;
    errdefer if (allocated_data) |d| allocator.free(d);

    for (filters) |filter| {
        const decoded: ?[]u8 = switch (filter) {
            .flate_decode => decompressFlate(allocator, current_data) catch null,
            .lzw_decode => lzw_decoder.decode(allocator, current_data) catch null,
            .ascii85_decode => ascii85_decoder.decode(allocator, current_data) catch null,
            .ascii_hex_decode => ascii_hex_decoder.decode(allocator, current_data) catch null,
            .run_length_decode => run_length_decoder.decode(allocator, current_data) catch null,
            // Terminal filters (image formats) - don't decode, just pass through
            .dct_decode, .jpx_decode, .jbig2_decode, .ccitt_fax_decode => blk: {
                // These are the final image formats - return current data
                if (allocated_data) |d| {
                    break :blk d;
                } else {
                    // Need to copy since we're returning ownership
                    break :blk allocator.dupe(u8, current_data) catch null;
                }
            },
            .unknown => null,
        };

        if (decoded) |new_data| {
            // Free previous allocated data if any (but not the terminal case)
            if (filter != .dct_decode and filter != .jpx_decode and
                filter != .jbig2_decode and filter != .ccitt_fax_decode)
            {
                if (allocated_data) |d| allocator.free(d);
            }
            allocated_data = new_data;
            current_data = new_data;
        } else {
            // Decoding failed
            if (allocated_data) |d| allocator.free(d);
            return null;
        }
    }

    return allocated_data;
}

// ============ PDF Parsing ============

/// Result of parsing an integer value
const IntParseResult = struct { value: i64, end: usize };

/// Skip whitespace in PDF data
fn skipWhitespace(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len) {
        switch (data[i]) {
            ' ', '\t', '\n', '\r', '\x0c', '\x00' => i += 1,
            '%' => {
                // Skip comment until end of line
                while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
            },
            else => break,
        }
    }
    return i;
}

/// Parse a PDF name (e.g., /Filter, /Width)
fn parseName(data: []const u8, start: usize) ?struct { name: []const u8, end: usize } {
    if (start >= data.len or data[start] != '/') return null;

    var end = start + 1;
    while (end < data.len) {
        const c = data[end];
        // Name terminates at delimiter or whitespace
        if (c == '/' or c == '[' or c == ']' or c == '<' or c == '>' or
            c == '(' or c == ')' or c == '{' or c == '}' or
            c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c')
        {
            break;
        }
        end += 1;
    }

    return .{
        .name = data[start + 1 .. end],
        .end = end,
    };
}

/// Parse a PDF integer
fn parseInt(data: []const u8, start: usize) ?IntParseResult {
    var i = start;
    var negative = false;

    if (i < data.len and data[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < data.len and data[i] == '+') {
        i += 1;
    }

    const num_start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}

    if (i == num_start) return null;

    const value = std.fmt.parseInt(i64, data[num_start..i], 10) catch return null;
    return .{
        .value = if (negative) -value else value,
        .end = i,
    };
}

/// Parse a PDF direct integer value, returning null if it's an indirect reference.
/// Indirect references have the form: "N G R" where N is object number, G is generation.
/// We can't resolve these without parsing the xref table, so return null.
fn parseDirectInt(data: []const u8, start: usize) ?IntParseResult {
    const int_result = parseInt(data, start) orelse return null;

    // Check if this is an indirect reference (number whitespace number whitespace "R")
    var check_pos = skipWhitespace(data, int_result.end);
    if (parseInt(data, check_pos)) |gen_result| {
        check_pos = skipWhitespace(data, gen_result.end);
        if (check_pos < data.len and data[check_pos] == 'R') {
            // This is an indirect reference - we can't resolve it
            return null;
        }
    }

    return int_result;
}

/// Convert filter name to enum
fn filterFromName(name: []const u8) ImageFilter {
    if (std.mem.eql(u8, name, "DCTDecode")) return .dct_decode;
    if (std.mem.eql(u8, name, "JPXDecode")) return .jpx_decode;
    if (std.mem.eql(u8, name, "JBIG2Decode")) return .jbig2_decode;
    if (std.mem.eql(u8, name, "CCITTFaxDecode")) return .ccitt_fax_decode;
    if (std.mem.eql(u8, name, "FlateDecode")) return .flate_decode;
    if (std.mem.eql(u8, name, "ASCII85Decode")) return .ascii85_decode;
    if (std.mem.eql(u8, name, "ASCIIHexDecode")) return .ascii_hex_decode;
    if (std.mem.eql(u8, name, "LZWDecode")) return .lzw_decode;
    if (std.mem.eql(u8, name, "RunLengthDecode")) return .run_length_decode;
    return .unknown;
}

/// Find all image XObjects in PDF data
pub fn findPdfImages(allocator: Allocator, data: []const u8) ![]PdfImageInfo {
    var images: std.ArrayListUnmanaged(PdfImageInfo) = .{};
    errdefer images.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        // Look for "obj" which marks object start
        if (i + 3 < data.len and std.mem.eql(u8, data[i..][0..3], "obj")) {
            // Backtrack to find object number
            var obj_start = i;
            while (obj_start > 0 and (data[obj_start - 1] == ' ' or data[obj_start - 1] == '\n' or data[obj_start - 1] == '\r')) {
                obj_start -= 1;
            }
            // Find generation number
            const gen_end = obj_start;
            while (obj_start > 0 and data[obj_start - 1] >= '0' and data[obj_start - 1] <= '9') {
                obj_start -= 1;
            }
            const gen_str = data[obj_start..gen_end];

            // Skip whitespace before gen number
            while (obj_start > 0 and (data[obj_start - 1] == ' ' or data[obj_start - 1] == '\n' or data[obj_start - 1] == '\r')) {
                obj_start -= 1;
            }
            // Find object number
            const obj_num_end = obj_start;
            while (obj_start > 0 and data[obj_start - 1] >= '0' and data[obj_start - 1] <= '9') {
                obj_start -= 1;
            }
            const obj_str = data[obj_start..obj_num_end];

            const obj_num = std.fmt.parseInt(u32, obj_str, 10) catch {
                i += 1;
                continue;
            };
            const gen_num = std.fmt.parseInt(u32, gen_str, 10) catch 0;

            // Parse object content looking for image XObject
            var j = i + 3;
            var is_image = false;
            var width: ?u32 = null;
            var height: ?u32 = null;
            var bits: ?u8 = null;
            var stream_length: ?u32 = null;
            var filters: std.ArrayListUnmanaged(ImageFilter) = .{};
            defer filters.deinit(allocator);
            var stream_start: ?usize = null;
            var stream_end: ?usize = null;
            var jbig2_globals_obj: ?u32 = null;
            var jbig2_globals_gen: ?u32 = null;

            // Parse until endobj
            while (j < data.len) {
                j = skipWhitespace(data, j);
                if (j >= data.len) break;

                // Check for stream keyword (not "endstream" - ensure not preceded by "end")
                if (j + 6 < data.len and std.mem.eql(u8, data[j..][0..6], "stream") and
                    (j < 3 or !std.mem.eql(u8, data[j - 3 ..][0..3], "end")))
                {
                    j += 6;
                    // Skip line ending after "stream"
                    if (j < data.len and data[j] == '\r') j += 1;
                    if (j < data.len and data[j] == '\n') j += 1;
                    stream_start = j;

                    // Use Length field if available (preferred - avoids false "endstream" matches in binary)
                    if (stream_length) |len| {
                        stream_end = stream_start.? + len;
                        if (stream_end.? > data.len) {
                            stream_end = data.len; // Clamp to file size
                        }
                    } else {
                        // Fallback: search for endstream (may have false positives in binary data)
                        // When Length is indirect and we can't resolve it, we have no way to know
                        // the exact stream boundary. The byte(s) before "endstream" could be:
                        // 1. An EOL separator (convention), or
                        // 2. Part of the actual stream data
                        // Since trimming incorrectly breaks decompression, we DON'T trim here.
                        // Valid compressed data that ends with 0x0A (LF) would be corrupted by trimming.
                        while (j < data.len) {
                            if (j + 9 <= data.len and std.mem.eql(u8, data[j..][0..9], "endstream")) {
                                stream_end = j;
                                break;
                            }
                            j += 1;
                        }
                    }
                    break;
                }

                // Check for endobj
                if (j + 6 < data.len and std.mem.eql(u8, data[j..][0..6], "endobj")) {
                    break;
                }

                // Parse dictionary entries
                if (data[j] == '/') {
                    const name_result = parseName(data, j) orelse {
                        j += 1;
                        continue;
                    };
                    const name = name_result.name;
                    j = skipWhitespace(data, name_result.end);

                    if (std.mem.eql(u8, name, "Subtype")) {
                        if (j < data.len and data[j] == '/') {
                            const subtype = parseName(data, j) orelse {
                                j += 1;
                                continue;
                            };
                            if (std.mem.eql(u8, subtype.name, "Image")) {
                                is_image = true;
                            }
                            j = subtype.end;
                        }
                    } else if (std.mem.eql(u8, name, "Width")) {
                        if (parseInt(data, j)) |int_result| {
                            width = @intCast(@max(0, int_result.value));
                            j = int_result.end;
                        }
                    } else if (std.mem.eql(u8, name, "Height")) {
                        if (parseInt(data, j)) |int_result| {
                            height = @intCast(@max(0, int_result.value));
                            j = int_result.end;
                        }
                    } else if (std.mem.eql(u8, name, "BitsPerComponent")) {
                        if (parseInt(data, j)) |int_result| {
                            bits = @intCast(@max(0, @min(255, int_result.value)));
                            j = int_result.end;
                        }
                    } else if (std.mem.eql(u8, name, "Length")) {
                        // Use parseDirectInt to skip indirect references (e.g., "154 0 R")
                        // When Length is indirect, we fall back to endstream search
                        if (parseDirectInt(data, j)) |int_result| {
                            stream_length = @intCast(@max(0, int_result.value));
                            j = int_result.end;
                        }
                    } else if (std.mem.eql(u8, name, "Filter")) {
                        // Filter can be a single name or an array
                        if (j < data.len and data[j] == '/') {
                            // Single filter
                            const filter_name = parseName(data, j) orelse {
                                j += 1;
                                continue;
                            };
                            try filters.append(allocator, filterFromName(filter_name.name));
                            j = filter_name.end;
                        } else if (j < data.len and data[j] == '[') {
                            // Array of filters
                            j += 1;
                            while (j < data.len and data[j] != ']') {
                                j = skipWhitespace(data, j);
                                if (j < data.len and data[j] == '/') {
                                    const filter_name = parseName(data, j) orelse break;
                                    try filters.append(allocator, filterFromName(filter_name.name));
                                    j = filter_name.end;
                                } else {
                                    j += 1;
                                }
                            }
                            if (j < data.len) j += 1; // Skip ']'
                        }
                    } else if (std.mem.eql(u8, name, "DecodeParms")) {
                        // DecodeParms can contain JBIG2Globals reference
                        // Look for /JBIG2Globals followed by object reference
                        const dp_start = j;
                        var dp_depth: u32 = 0;
                        var in_decode_parms = false;

                        // Find the DecodeParms dictionary
                        while (j < data.len) {
                            if (data[j] == '<' and j + 1 < data.len and data[j + 1] == '<') {
                                dp_depth += 1;
                                in_decode_parms = true;
                                j += 2;
                            } else if (data[j] == '>' and j + 1 < data.len and data[j + 1] == '>') {
                                if (dp_depth > 0) dp_depth -= 1;
                                if (dp_depth == 0 and in_decode_parms) {
                                    j += 2;
                                    break;
                                }
                                j += 2;
                            } else {
                                j += 1;
                            }
                            if (in_decode_parms and dp_depth == 0) break;
                        }

                        // Search for /JBIG2Globals in the DecodeParms section
                        const dp_end = j;
                        var k = dp_start;
                        while (k + 13 < dp_end) : (k += 1) {
                            if (std.mem.startsWith(u8, data[k..], "/JBIG2Globals")) {
                                // Found JBIG2Globals - parse the indirect reference
                                var ref_pos = k + 13;
                                ref_pos = skipWhitespace(data, ref_pos);

                                // Parse object number
                                if (parseInt(data, ref_pos)) |obj_result| {
                                    jbig2_globals_obj = @intCast(@max(0, obj_result.value));
                                    ref_pos = skipWhitespace(data, obj_result.end);

                                    // Parse generation number
                                    if (parseInt(data, ref_pos)) |gen_result| {
                                        jbig2_globals_gen = @intCast(@max(0, gen_result.value));
                                    }
                                }
                                break;
                            }
                        }
                    }
                } else {
                    j += 1;
                }
            }

            // If we found an image with a stream, record it
            if (is_image and stream_start != null and stream_end != null) {
                // Debug: show stream detection results
                if (false) { // Debug: stream detection
                    const actual_len = stream_end.? - stream_start.?;
                    std.debug.print("PDF: obj#{d} stream len={d} (declared={d})\n", .{
                        obj_num,
                        actual_len,
                        stream_length orelse 0,
                    });
                }
                try images.append(allocator, .{
                    .stream_start = stream_start.?,
                    .stream_end = stream_end.?,
                    .width = width,
                    .height = height,
                    .bits_per_component = bits,
                    .filters = try filters.toOwnedSlice(allocator),
                    .object_num = obj_num,
                    .gen_num = gen_num,
                    .jbig2_globals_obj = jbig2_globals_obj,
                    .jbig2_globals_gen = jbig2_globals_gen,
                });
            }

            i = j;
        } else {
            i += 1;
        }
    }

    return images.toOwnedSlice(allocator);
}

/// Free PdfImageInfo array
pub fn freePdfImages(allocator: Allocator, images: []PdfImageInfo) void {
    for (images) |img| {
        allocator.free(img.filters);
    }
    allocator.free(images);
}

/// Find an object's stream data by object number
/// Returns the raw stream data (between "stream" and "endstream")
pub fn findObjectStream(data: []const u8, obj_num: u32, gen_num: u32) ?[]const u8 {
    // Build the object definition pattern: "obj_num gen_num obj"
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{d} {d} obj", .{ obj_num, gen_num }) catch return null;

    // Search for the object
    var i: usize = 0;
    while (i + pattern.len < data.len) : (i += 1) {
        if (std.mem.startsWith(u8, data[i..], pattern)) {
            // Found the object - now find stream
            var j = i + pattern.len;
            while (j + 6 < data.len) : (j += 1) {
                if (std.mem.startsWith(u8, data[j..], "stream")) {
                    j += 6;
                    // Skip line ending after "stream"
                    if (j < data.len and data[j] == '\r') j += 1;
                    if (j < data.len and data[j] == '\n') j += 1;

                    const stream_start = j;

                    // Find endstream
                    // Don't trim EOL before endstream - it might be part of the data
                    while (j + 9 <= data.len) : (j += 1) {
                        if (std.mem.startsWith(u8, data[j..], "endstream")) {
                            return data[stream_start..j];
                        }
                    }
                    return null; // endstream not found
                }
                // Stop if we hit endobj without finding stream
                if (std.mem.startsWith(u8, data[j..], "endobj")) {
                    return null;
                }
            }
        }
    }
    return null;
}

// ============ Image Validation ============

/// Validate a single extracted image based on its filter
pub fn validateExtractedImage(allocator: Allocator, data: []const u8, filter: ImageFilter) ImageValidationResult {
    switch (filter) {
        .dct_decode => {
            // JPEG validation via libjpeg-turbo
            const result = jpeg_validator.validateJpegDeepFromBuffer(data);
            return .{
                .object_num = 0,
                .filter = filter,
                .valid = result.valid,
                .error_message = result.error_message,
                .width = 0, // JPEG validator doesn't return dimensions
                .height = 0,
            };
        },
        .jpx_decode => {
            // JPEG2000 validation via OpenJPEG
            const result = jpeg2000_validator.validateJpeg2000(data);
            return .{
                .object_num = 0,
                .filter = filter,
                .valid = result.valid,
                .error_message = result.error_message,
                .width = result.width,
                .height = result.height,
            };
        },
        .jbig2_decode => {
            // JBIG2 validation via pure Zig decoder
            // PDF JBIG2 streams don't have the file header, just segments
            // Use validateJbig2WithGlobals for proper globals support
            if (data.len < 5) {
                return .{
                    .object_num = 0,
                    .filter = filter,
                    .valid = false,
                    .error_message = "JBIG2 stream too short",
                    .width = 0,
                    .height = 0,
                };
            }

            // Without globals reference, try to decode standalone
            // Pass null dimensions since we don't have PDF metadata in this context
            const result = jbig2_decoder.validatePdfJbig2(allocator, null, data, null, null);
            return .{
                .object_num = 0,
                .filter = filter,
                .valid = result.valid,
                .error_message = result.error_message,
                .width = result.width,
                .height = result.height,
            };
        },
        .ccitt_fax_decode => {
            // CCITT Fax - full decode validation
            // Default to Group 4 (most common in PDFs) with standard parameters
            const params = ccitt_fax_decoder.CcittParams{
                .k = -1, // Group 4
                .columns = 1728, // Standard fax width
                .rows = 0, // Unknown
                .black_is_1 = false,
            };

            const result = ccitt_fax_decoder.validate(data, params);
            return .{
                .object_num = 0,
                .filter = filter,
                .valid = result.valid,
                .error_message = result.error_message,
                .width = result.width,
                .height = result.height,
            };
        },
        else => {
            // Filter we can't validate
            return .{
                .object_num = 0,
                .filter = filter,
                .valid = true, // Can't validate, assume OK
                .error_message = null,
                .width = 0,
                .height = 0,
            };
        },
    }
}

/// Validate all images in a PDF
pub fn validatePdfImages(allocator: Allocator, pdf_data: []const u8) !PdfImageValidationResult {
    const timing_debug = isPdfTimingDebug();
    const total_start = if (timing_debug) std.time.nanoTimestamp() else 0;
    const parse_start = total_start;

    const images = try findPdfImages(allocator, pdf_data);
    defer freePdfImages(allocator, images);

    if (timing_debug) {
        const parse_end = std.time.nanoTimestamp();
        const parse_ms = @as(f64, @floatFromInt(parse_end - parse_start)) / 1_000_000.0;
        std.debug.print("PDF parsing: found {d} images in {d:.1}ms ({d:.2}MB PDF)\n", .{
            images.len,
            parse_ms,
            @as(f64, @floatFromInt(pdf_data.len)) / (1024.0 * 1024.0),
        });
    }

    // Check for encryption and attempt decryption with empty password
    var is_encrypted = false;
    var decryption_succeeded = false;
    var encryption_key: ?[16]u8 = null;
    var key_length: u8 = 0;
    var use_aes = false;

    if (pdf_decryptor.parseEncryptionParams(pdf_data)) |enc_params| {
        is_encrypted = true;
        const decrypt_result = pdf_decryptor.tryEmptyPassword(enc_params);
        if (decrypt_result.success) {
            decryption_succeeded = true;
            encryption_key = decrypt_result.encryption_key;
            key_length = decrypt_result.key_length;
            use_aes = decrypt_result.use_aes;
        } else {
            // Encryption present but requires password - can't validate images
            return .{
                .valid = true, // Not a validation failure, just can't verify
                .total_images = @intCast(images.len),
                .validated_images = 0,
                .failed_images = 0,
                .skipped_images = @intCast(images.len),
                .results = &.{},
                .error_message = "PDF encrypted with password - images not validated",
                .is_encrypted = true,
                .decryption_succeeded = false,
            };
        }
    }

    // Use parallel validation for PDFs with many images
    if (images.len >= PARALLEL_IMAGE_THRESHOLD) {
        const parallel_start = if (timing_debug) std.time.nanoTimestamp() else 0;
        const result = try validatePdfImagesParallel(
            allocator,
            images,
            pdf_data,
            encryption_key,
            key_length,
            use_aes,
            decryption_succeeded,
            is_encrypted,
        );
        if (timing_debug) {
            const parallel_end = std.time.nanoTimestamp();
            const parallel_ms = @as(f64, @floatFromInt(parallel_end - parallel_start)) / 1_000_000.0;
            const total_ms = @as(f64, @floatFromInt(parallel_end - total_start)) / 1_000_000.0;
            std.debug.print("PDF parallel validation: {d:.1}ms, TOTAL: {d:.1}ms\n", .{ parallel_ms, total_ms });
        }
        return result;
    }

    // Sequential validation for small image counts
    var results: std.ArrayListUnmanaged(ImageValidationResult) = .{};
    errdefer results.deinit(allocator);

    var validated: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    for (images) |img| {

        // Get the primary image filter (last in chain, as filters are applied in order)
        if (img.filters.len == 0) {
            skipped += 1;
            continue;
        }

        const primary_filter = img.filters[img.filters.len - 1];

        // Get the raw stream data and decrypt if needed
        var raw_data = pdf_data[img.stream_start..img.stream_end];
        var decrypted_data: ?[]u8 = null;
        defer if (decrypted_data) |d| allocator.free(d);

        if (decryption_succeeded) {
            if (encryption_key) |key| {
                decrypted_data = pdf_decryptor.decryptStream(
                    allocator,
                    raw_data,
                    key[0..key_length],
                    img.object_num,
                    img.gen_num,
                    use_aes,
                ) catch null;

                if (decrypted_data) |d| {
                    raw_data = d;
                } else {
                    // Decryption failed for this stream - skip it
                    skipped += 1;
                    continue;
                }
            }
        }

        // Apply filter chain if there are multiple filters
        const image_data: []const u8 = if (img.filters.len > 1) blk: {
            // Apply all filters except the last (terminal) one
            const preprocessing_filters = img.filters[0 .. img.filters.len - 1];
            if (applyFilterChain(allocator, raw_data, preprocessing_filters)) |decoded| {
                break :blk decoded;
            } else {
                // Filter chain failed - skip this image
                skipped += 1;
                continue;
            }
        } else raw_data;

        // Track if we allocated image_data
        const image_data_allocated = img.filters.len > 1;
        defer if (image_data_allocated) allocator.free(@constCast(image_data));

        // Validate based on filter type
        switch (primary_filter) {
            .jbig2_decode => {
                // Special handling for JBIG2 with globals
                // Try to find JBIG2Globals if referenced
                const globals_data: ?[]const u8 = if (img.jbig2_globals_obj) |globals_obj|
                    findObjectStream(pdf_data, globals_obj, img.jbig2_globals_gen orelse 0)
                else
                    null;
                if (image_data.len < 5) {
                    try results.append(allocator, .{
                        .object_num = img.object_num,
                        .filter = primary_filter,
                        .valid = false,
                        .error_message = "JBIG2 stream too short",
                        .width = 0,
                        .height = 0,
                    });
                    failed += 1;
                } else {
                    const jbig2_result = jbig2_decoder.validatePdfJbig2(allocator, globals_data, image_data, img.width, img.height);
                    var result = ImageValidationResult{
                        .object_num = img.object_num,
                        .filter = primary_filter,
                        .valid = jbig2_result.valid,
                        .error_message = jbig2_result.error_message,
                        .width = jbig2_result.width,
                        .height = jbig2_result.height,
                    };

                    if (jbig2_result.valid) {
                        validated += 1;
                        if (jbig2_result.warning_message) |warn| {
                            result.error_message = warn;
                        }
                    } else {
                        failed += 1;
                    }

                    try results.append(allocator, result);
                }
            },
            .dct_decode, .jpx_decode, .ccitt_fax_decode => {
                var result = validateExtractedImage(allocator, image_data, primary_filter);
                result.object_num = img.object_num;

                if (result.valid) {
                    validated += 1;
                } else {
                    failed += 1;
                }

                try results.append(allocator, result);
            },
            .flate_decode => {
                // FlateDecode as terminal filter - might be raw pixel data or nested image
                if (decompressFlate(allocator, image_data)) |decompressed| {
                    defer allocator.free(decompressed);

                    // Check if decompressed data is a known image format
                    if (detectDecompressedFormat(decompressed)) |nested_format| {
                        var result = validateExtractedImage(allocator, decompressed, nested_format);
                        result.object_num = img.object_num;

                        if (result.valid) {
                            validated += 1;
                        } else {
                            failed += 1;
                        }

                        try results.append(allocator, result);
                    } else {
                        // Raw pixel data - decompression succeeded, consider valid
                        validated += 1;
                        try results.append(allocator, .{
                            .object_num = img.object_num,
                            .filter = .flate_decode,
                            .valid = true,
                            .error_message = null,
                            .width = img.width orelse 0,
                            .height = img.height orelse 0,
                        });
                    }
                } else |_| {
                    // Decompression failed
                    failed += 1;
                    try results.append(allocator, .{
                        .object_num = img.object_num,
                        .filter = .flate_decode,
                        .valid = false,
                        .error_message = "FlateDecode decompression failed",
                        .width = 0,
                        .height = 0,
                    });
                }
            },
            .lzw_decode => {
                // LZW as terminal filter
                if (lzw_decoder.decode(allocator, image_data)) |decompressed| {
                    defer allocator.free(decompressed);

                    if (detectDecompressedFormat(decompressed)) |nested_format| {
                        var result = validateExtractedImage(allocator, decompressed, nested_format);
                        result.object_num = img.object_num;

                        if (result.valid) {
                            validated += 1;
                        } else {
                            failed += 1;
                        }

                        try results.append(allocator, result);
                    } else {
                        // Raw pixel data
                        validated += 1;
                        try results.append(allocator, .{
                            .object_num = img.object_num,
                            .filter = .lzw_decode,
                            .valid = true,
                            .error_message = null,
                            .width = img.width orelse 0,
                            .height = img.height orelse 0,
                        });
                    }
                } else |_| {
                    failed += 1;
                    try results.append(allocator, .{
                        .object_num = img.object_num,
                        .filter = .lzw_decode,
                        .valid = false,
                        .error_message = "LZW decode failed",
                        .width = 0,
                        .height = 0,
                    });
                }
            },
            else => {
                skipped += 1;
            },
        }
    }

    return .{
        .valid = failed == 0,
        .total_images = @intCast(images.len),
        .validated_images = validated,
        .failed_images = failed,
        .skipped_images = skipped,
        .results = try results.toOwnedSlice(allocator),
        .error_message = if (failed > 0) "Some images failed validation" else null,
        .is_encrypted = is_encrypted,
        .decryption_succeeded = decryption_succeeded,
    };
}

// ============ Parallel Image Validation ============

/// Task for parallel image validation
const ImageTask = struct {
    /// Index into images array
    image_index: usize,
};

/// Result from parallel image validation
const ImageTaskResult = struct {
    result: ?ImageValidationResult,
    status: enum { validated, failed, skipped },
};

/// Shared context for parallel validation workers
const ParallelContext = struct {
    images: []const PdfImageInfo,
    pdf_data: []const u8,
    encryption_key: ?[16]u8,
    key_length: u8,
    use_aes: bool,
    decryption_succeeded: bool,
};

/// Check if PDF image timing debug is enabled
fn isPdfTimingDebug() bool {
    return std.posix.getenv("PDF_IMAGE_TIMING") != null;
}

/// Execute a single image validation task (called by worker threads)
fn executeImageTask(task: ImageTask, ctx_ptr: ?*anyopaque) ImageTaskResult {
    const timing_debug = isPdfTimingDebug();
    const task_start = if (timing_debug) std.time.nanoTimestamp() else 0;

    const ctx: *const ParallelContext = @ptrCast(@alignCast(ctx_ptr orelse return .{
        .result = null,
        .status = .skipped,
    }));

    const img = ctx.images[task.image_index];

    // Use page_allocator for temporary work
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get the primary image filter (last in chain)
    if (img.filters.len == 0) {
        return .{ .result = null, .status = .skipped };
    }

    const primary_filter = img.filters[img.filters.len - 1];

    // Get the raw stream data
    var raw_data = ctx.pdf_data[img.stream_start..img.stream_end];
    const raw_size = raw_data.len;

    // Decrypt if needed
    if (ctx.decryption_succeeded) {
        if (ctx.encryption_key) |key| {
            const decrypted = pdf_decryptor.decryptStream(
                allocator,
                raw_data,
                key[0..ctx.key_length],
                img.object_num,
                img.gen_num,
                ctx.use_aes,
            ) catch {
                return .{ .result = null, .status = .skipped };
            };
            raw_data = decrypted;
        }
    }

    // Apply filter chain if there are multiple filters
    const image_data: []const u8 = if (img.filters.len > 1) blk: {
        const preprocessing_filters = img.filters[0 .. img.filters.len - 1];
        if (applyFilterChain(allocator, raw_data, preprocessing_filters)) |decoded| {
            break :blk decoded;
        } else {
            return .{ .result = null, .status = .skipped };
        }
    } else raw_data;

    // Validate based on filter type
    const validation_result: ImageTaskResult = switch (primary_filter) {
        .jbig2_decode => blk: {
            const globals_data: ?[]const u8 = if (img.jbig2_globals_obj) |globals_obj|
                findObjectStream(ctx.pdf_data, globals_obj, img.jbig2_globals_gen orelse 0)
            else
                null;

            if (image_data.len < 5) {
                break :blk .{
                    .result = .{
                        .object_num = img.object_num,
                        .filter = primary_filter,
                        .valid = false,
                        .error_message = "JBIG2 stream too short",
                        .width = 0,
                        .height = 0,
                    },
                    .status = .failed,
                };
            }

            const jbig2_result = jbig2_decoder.validatePdfJbig2(allocator, globals_data, image_data, img.width, img.height);
            break :blk .{
                .result = .{
                    .object_num = img.object_num,
                    .filter = primary_filter,
                    .valid = jbig2_result.valid,
                    .error_message = jbig2_result.error_message orelse jbig2_result.warning_message,
                    .width = jbig2_result.width,
                    .height = jbig2_result.height,
                },
                .status = if (jbig2_result.valid) .validated else .failed,
            };
        },
        .dct_decode, .jpx_decode, .ccitt_fax_decode => blk: {
            var result = validateExtractedImage(allocator, image_data, primary_filter);
            result.object_num = img.object_num;
            break :blk .{
                .result = result,
                .status = if (result.valid) .validated else .failed,
            };
        },
        .flate_decode => blk: {
            const decomp_start = if (timing_debug) std.time.nanoTimestamp() else 0;
            if (decompressFlate(allocator, image_data)) |decompressed| {
                const decomp_end = if (timing_debug) std.time.nanoTimestamp() else 0;
                const decomp_ms = if (timing_debug) @as(f64, @floatFromInt(decomp_end - decomp_start)) / 1_000_000.0 else 0;

                if (timing_debug) {
                    std.debug.print("PDF img#{d}: FlateDecode {d}KB -> {d}KB in {d:.1}ms\n", .{
                        img.object_num,
                        raw_size / 1024,
                        decompressed.len / 1024,
                        decomp_ms,
                    });
                }

                if (detectDecompressedFormat(decompressed)) |nested_format| {
                    const validate_start = if (timing_debug) std.time.nanoTimestamp() else 0;
                    var result = validateExtractedImage(allocator, decompressed, nested_format);
                    const validate_end = if (timing_debug) std.time.nanoTimestamp() else 0;
                    result.object_num = img.object_num;

                    if (timing_debug) {
                        const validate_ms = @as(f64, @floatFromInt(validate_end - validate_start)) / 1_000_000.0;
                        std.debug.print("  -> nested format validation: {d:.1}ms\n", .{validate_ms});
                    }

                    break :blk .{
                        .result = result,
                        .status = if (result.valid) .validated else .failed,
                    };
                } else {
                    // Raw pixel data - decompression succeeded, consider valid
                    if (timing_debug) {
                        const total_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - task_start)) / 1_000_000.0;
                        std.debug.print("  -> raw pixels, total: {d:.1}ms\n", .{total_ms});
                    }
                    break :blk .{
                        .result = .{
                            .object_num = img.object_num,
                            .filter = .flate_decode,
                            .valid = true,
                            .error_message = null,
                            .width = img.width orelse 0,
                            .height = img.height orelse 0,
                        },
                        .status = .validated,
                    };
                }
            } else |_| {
                break :blk .{
                    .result = .{
                        .object_num = img.object_num,
                        .filter = .flate_decode,
                        .valid = false,
                        .error_message = "FlateDecode decompression failed",
                        .width = 0,
                        .height = 0,
                    },
                    .status = .failed,
                };
            }
        },
        .lzw_decode => blk: {
            if (lzw_decoder.decode(allocator, image_data)) |decompressed| {
                if (detectDecompressedFormat(decompressed)) |nested_format| {
                    var result = validateExtractedImage(allocator, decompressed, nested_format);
                    result.object_num = img.object_num;
                    break :blk .{
                        .result = result,
                        .status = if (result.valid) .validated else .failed,
                    };
                } else {
                    break :blk .{
                        .result = .{
                            .object_num = img.object_num,
                            .filter = .lzw_decode,
                            .valid = true,
                            .error_message = null,
                            .width = img.width orelse 0,
                            .height = img.height orelse 0,
                        },
                        .status = .validated,
                    };
                }
            } else |_| {
                break :blk .{
                    .result = .{
                        .object_num = img.object_num,
                        .filter = .lzw_decode,
                        .valid = false,
                        .error_message = "LZW decode failed",
                        .width = 0,
                        .height = 0,
                    },
                    .status = .failed,
                };
            }
        },
        else => .{ .result = null, .status = .skipped },
    };

    return validation_result;
}

/// Validate PDF images in parallel using thread pool
fn validatePdfImagesParallel(
    allocator: Allocator,
    images: []const PdfImageInfo,
    pdf_data: []const u8,
    encryption_key: ?[16]u8,
    key_length: u8,
    use_aes: bool,
    decryption_succeeded: bool,
    is_encrypted: bool,
) !PdfImageValidationResult {
    // Use inner job count (1/3 of CPUs) to avoid over-subscription
    // when already running in parallel at the batch level (2/3 of CPUs).
    // This way, outer + inner ≈ total CPUs when one PDF is being validated.
    const job_count = thread_pool.getInnerJobCount();

    // Shared context for all workers
    var ctx = ParallelContext{
        .images = images,
        .pdf_data = pdf_data,
        .encryption_key = encryption_key,
        .key_length = key_length,
        .use_aes = use_aes,
        .decryption_succeeded = decryption_succeeded,
    };

    // IMPORTANT: Use page_allocator for thread pool internals because:
    // 1. The passed-in allocator may be an arena allocator (not thread-safe)
    // 2. Thread pool's work queue and result queue are accessed from multiple threads
    // 3. page_allocator is thread-safe
    const pool_allocator = std.heap.page_allocator;

    // Collect results thread-safely
    var results_mutex: std.Thread.Mutex = .{};
    var collected_results: std.ArrayListUnmanaged(ImageValidationResult) = .{};
    errdefer collected_results.deinit(pool_allocator);

    var validated = std.atomic.Value(u32).init(0);
    var failed = std.atomic.Value(u32).init(0);
    var skipped = std.atomic.Value(u32).init(0);

    const ResultContext = struct {
        mutex: *std.Thread.Mutex,
        results: *std.ArrayListUnmanaged(ImageValidationResult),
        allocator: Allocator,
        validated: *std.atomic.Value(u32),
        failed: *std.atomic.Value(u32),
        skipped: *std.atomic.Value(u32),
    };

    var result_ctx = ResultContext{
        .mutex = &results_mutex,
        .results = &collected_results,
        .allocator = pool_allocator,
        .validated = &validated,
        .failed = &failed,
        .skipped = &skipped,
    };

    // Create thread pool with thread-safe allocator
    const Pool = thread_pool.ThreadPool(ImageTask, ImageTaskResult);
    const pool = try Pool.create(
        pool_allocator,
        job_count,
        executeImageTask,
        @ptrCast(&ctx),
        struct {
            fn callback(task_result: ImageTaskResult, cb_ctx: ?*anyopaque) void {
                const rc: *ResultContext = @ptrCast(@alignCast(cb_ctx orelse return));

                switch (task_result.status) {
                    .validated => _ = rc.validated.fetchAdd(1, .seq_cst),
                    .failed => _ = rc.failed.fetchAdd(1, .seq_cst),
                    .skipped => _ = rc.skipped.fetchAdd(1, .seq_cst),
                }

                if (task_result.result) |result| {
                    rc.mutex.lock();
                    defer rc.mutex.unlock();
                    rc.results.append(rc.allocator, result) catch {};
                }
            }
        }.callback,
        @ptrCast(&result_ctx),
    );
    defer pool.destroy();

    // Submit all image tasks
    for (0..images.len) |i| {
        try pool.submit(.{ .image_index = i });
    }

    // Wait for completion
    pool.shutdown();
    pool.wait();

    const final_validated = validated.load(.seq_cst);
    const final_failed = failed.load(.seq_cst);
    const final_skipped = skipped.load(.seq_cst);

    // Get results from pool_allocator, then copy to caller's allocator
    const pool_results = try collected_results.toOwnedSlice(pool_allocator);
    defer pool_allocator.free(pool_results);

    // Copy to caller's allocator (so they can free with their allocator)
    const caller_results = try allocator.dupe(ImageValidationResult, pool_results);

    return .{
        .valid = final_failed == 0,
        .total_images = @intCast(images.len),
        .validated_images = final_validated,
        .failed_images = final_failed,
        .skipped_images = final_skipped,
        .results = caller_results,
        .error_message = if (final_failed > 0) "Some images failed validation" else null,
        .is_encrypted = is_encrypted,
        .decryption_succeeded = decryption_succeeded,
    };
}

// ============ Tests ============

test "filterFromName parses filter names correctly" {
    try std.testing.expectEqual(ImageFilter.dct_decode, filterFromName("DCTDecode"));
    try std.testing.expectEqual(ImageFilter.jpx_decode, filterFromName("JPXDecode"));
    try std.testing.expectEqual(ImageFilter.jbig2_decode, filterFromName("JBIG2Decode"));
    try std.testing.expectEqual(ImageFilter.ccitt_fax_decode, filterFromName("CCITTFaxDecode"));
    try std.testing.expectEqual(ImageFilter.flate_decode, filterFromName("FlateDecode"));
    try std.testing.expectEqual(ImageFilter.unknown, filterFromName("SomeOtherFilter"));
}

test "parseName extracts PDF names" {
    const result = parseName("/Filter /Width", 0).?;
    try std.testing.expectEqualStrings("Filter", result.name);
    try std.testing.expectEqual(@as(usize, 7), result.end);
}

test "parseInt parses integers" {
    const result = parseInt("123 456", 0).?;
    try std.testing.expectEqual(@as(i64, 123), result.value);
    try std.testing.expectEqual(@as(usize, 3), result.end);

    const neg = parseInt("-42", 0).?;
    try std.testing.expectEqual(@as(i64, -42), neg.value);
}

test "skipWhitespace skips spaces and newlines" {
    try std.testing.expectEqual(@as(usize, 3), skipWhitespace("   hello", 0));
    try std.testing.expectEqual(@as(usize, 2), skipWhitespace("\n\nhello", 0));
    try std.testing.expectEqual(@as(usize, 0), skipWhitespace("hello", 0));
}

test "skipWhitespace skips comments" {
    const result = skipWhitespace("% this is a comment\nhello", 0);
    try std.testing.expectEqual(@as(usize, 20), result);
}

test "findPdfImages handles empty PDF" {
    const allocator = std.testing.allocator;
    const images = try findPdfImages(allocator, "");
    defer freePdfImages(allocator, images);
    try std.testing.expectEqual(@as(usize, 0), images.len);
}

test "findPdfImages finds image XObject" {
    const allocator = std.testing.allocator;

    // Minimal PDF with an image XObject
    const pdf =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /XObject /Subtype /Image /Width 10 /Height 10 /Filter /DCTDecode >>
        \\stream
        \\fake image data
        \\endstream
        \\endobj
    ;

    const images = try findPdfImages(allocator, pdf);
    defer freePdfImages(allocator, images);

    try std.testing.expectEqual(@as(usize, 1), images.len);
    try std.testing.expectEqual(@as(u32, 1), images[0].object_num);
    try std.testing.expectEqual(@as(?u32, 10), images[0].width);
    try std.testing.expectEqual(@as(?u32, 10), images[0].height);
    try std.testing.expectEqual(@as(usize, 1), images[0].filters.len);
    try std.testing.expectEqual(ImageFilter.dct_decode, images[0].filters[0]);
}

test "validateExtractedImage validates JPEG" {
    // Create a minimal invalid JPEG (just to test the flow)
    const fake_jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }; // JPEG SOI + APP0 marker (truncated)
    const result = validateExtractedImage(std.testing.allocator, &fake_jpeg, .dct_decode);

    // Should fail because it's truncated
    try std.testing.expect(!result.valid);
}

test "findPdfImages on real PDF file" {
    const allocator = std.testing.allocator;

    // Try to read a real PDF from the user's Documents
    const pdf_path = "/Users/pmarreck/Documents/27 Overlook Deed.pdf";

    const file = std.fs.openFileAbsolute(pdf_path, .{}) catch {
        return; // Skip if file doesn't exist
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        return;
    };
    defer allocator.free(data);

    const images = try findPdfImages(allocator, data);
    defer freePdfImages(allocator, images);

    // Verify we can iterate images without crashing
    for (images) |img| {
        _ = img.object_num;
        _ = img.width;
        _ = img.height;
        for (img.filters) |f| {
            _ = f;
        }
    }

    // The test passes if we don't crash - we're just exploring the PDF structure
}
