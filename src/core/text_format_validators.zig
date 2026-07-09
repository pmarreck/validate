const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const cj5 = @import("cj5");
const errmsg = @import("error_messages.zig");
const archive_validators = @import("archive_validators.zig");
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;
const isAsciiCompatibleEncoding = format_validation.isAsciiCompatibleEncoding;
const normalizeXmlEncoding = format_validation.normalizeXmlEncoding;

// uchardet C API for charset detection — replaces the in-tree control-byte
// heuristic in `validatePlainTextLatin1Fallback`. Detects 30+ encodings
// (UTF-8, UTF-16, ISO-8859-*, Windows-125x, Big5, GB18030, Shift-JIS, etc.).
const uchardet_c = @cImport({
	@cInclude("uchardet.h");
});
const EncodingNormalizedResult = format_validation.EncodingNormalizedResult;
const getTextContent = format_validation.getTextContent;
const convertUtf16LeToUtf8 = format_validation.convertUtf16LeToUtf8;

/// Maximum file size for text format parsing (1 GB).
/// Files larger than this are too risky to load entirely into memory.
const max_text_file_size: usize = 1024 * 1024 * 1024;

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;

/// Helper: get file content zero-copy from mmap when possible, heap fallback otherwise.
/// Returns the content slice and an optional heap buffer that the caller must free.
/// Usage:
///   var heap_buf: ?[]u8 = null;
///   defer if (heap_buf) |buf| heap.validateAllocator().free(buf);
///   const content = getFileContent(file, max_size, &heap_buf) orelse return error_result;
fn getFileContent(file: *FileSource, max_size: u64, heap_buf_out: *?[]u8) ?[]const u8 {
    const file_sz = file.getEndPos() catch return null;
    if (file_sz == 0 or file_sz > max_size) return null;

    if (file.getMappedSlice()) |mapped| return mapped;

    // Fallback: allocate and read
    const buf = heap.validateAllocator().alloc(u8, @intCast(file_sz)) catch return null;
    heap_buf_out.* = buf;
    file.seekTo(0) catch return null;
    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

// ============ Unicode Warning Types ============

pub const UnicodeWarningKind = enum(u3) {
    noncharacter,
    bidi_override,
    zero_width,
    misplaced_bom,
};

pub const UnicodeWarning = struct {
    kind: UnicodeWarningKind,
    byte_offset: usize,
};

pub const Utf8Result = struct {
    /// Byte offset of first encoding error, or null if valid UTF-8
    error_offset: ?usize = null,
    /// Suspicious codepoint warnings (up to 25)
    warnings: [25]UnicodeWarning = undefined,
    warning_count: u8 = 0,

    pub fn isValid(self: Utf8Result) bool {
        return self.error_offset == null;
    }

    pub fn hasWarnings(self: Utf8Result) bool {
        return self.warning_count > 0;
    }
};

pub fn isNoncharacter(cp: u21) bool {
    return (cp >= 0xFDD0 and cp <= 0xFDEF) or
        (cp & 0xFFFF) == 0xFFFE or
        (cp & 0xFFFF) == 0xFFFF;
}

pub fn isBidiOverride(cp: u21) bool {
    return (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2066 and cp <= 0x2069);
}

pub fn isZeroWidth(cp: u21) bool {
    return cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0x2060;
}

pub fn formatUnicodeWarnings(allocator: Allocator, warnings: []const UnicodeWarning) ?[]const u8 {
    if (warnings.len == 0) return null;

    // Group warnings by kind and collect byte offsets + total counts
    var nonchar_offsets: [25]usize = undefined;
    var nonchar_count: usize = 0;
    var nonchar_total: usize = 0;
    var bidi_offsets: [25]usize = undefined;
    var bidi_count: usize = 0;
    var bidi_total: usize = 0;
    var zw_offsets: [25]usize = undefined;
    var zw_count: usize = 0;
    var zw_total: usize = 0;
    var bom_offsets: [25]usize = undefined;
    var bom_count: usize = 0;
    var bom_total: usize = 0;

    for (warnings) |w| {
        switch (w.kind) {
            .noncharacter => {
                nonchar_total += 1;
                if (nonchar_count < 25) {
                    nonchar_offsets[nonchar_count] = w.byte_offset;
                    nonchar_count += 1;
                }
            },
            .bidi_override => {
                bidi_total += 1;
                if (bidi_count < 25) {
                    bidi_offsets[bidi_count] = w.byte_offset;
                    bidi_count += 1;
                }
            },
            .zero_width => {
                zw_total += 1;
                if (zw_count < 25) {
                    zw_offsets[zw_count] = w.byte_offset;
                    zw_count += 1;
                }
            },
            .misplaced_bom => {
                bom_total += 1;
                if (bom_count < 25) {
                    bom_offsets[bom_count] = w.byte_offset;
                    bom_count += 1;
                }
            },
        }
    }

    // Build formatted string using std.Io.Writer.Allocating (0.16 replacement for ArrayList.writer).
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    writer.writeAll("[") catch return null;
    var first_group = true;

    const groups = [_]struct { name: []const u8, offsets: []const usize, total: usize }{
        .{ .name = "noncharacters", .offsets = nonchar_offsets[0..nonchar_count], .total = nonchar_total },
        .{ .name = "bidi overrides", .offsets = bidi_offsets[0..bidi_count], .total = bidi_total },
        .{ .name = "zero-width chars", .offsets = zw_offsets[0..zw_count], .total = zw_total },
        .{ .name = "misplaced BOM", .offsets = bom_offsets[0..bom_count], .total = bom_total },
    };

    for (groups) |group| {
        if (group.offsets.len == 0) continue;
        if (!first_group) {
            writer.writeAll("; ") catch return null;
        }
        first_group = false;
        writer.writeAll(group.name) catch return null;
        writer.writeAll(" @ ") catch return null;
        for (group.offsets, 0..) |offset, idx| {
            if (idx > 0) {
                writer.writeAll(", ") catch return null;
            }
            writer.print("{d}", .{offset}) catch return null;
        }
        if (group.total > group.offsets.len) {
            writer.print(", ... ({d} total)", .{group.total}) catch return null;
        }
    }

    writer.writeAll("]") catch return null;
    return aw.toOwnedSlice() catch return null;
}

// ============ UTF-8 Validator ============

pub fn validateUtf8(data: []const u8) Utf8Result {
    var result = Utf8Result{};
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        const seq_len = getUtf8SequenceLength(byte) orelse {
            result.error_offset = i;
            return result;
        };

        if (i + seq_len > data.len) { // Truncated sequence
            result.error_offset = i;
            return result;
        }

        // Validate continuation bytes
        var j: usize = 1;
        while (j < seq_len) : (j += 1) {
            if (i + j >= data.len) {
                result.error_offset = i;
                return result;
            }
            const cont = data[i + j];
            if ((cont & 0xC0) != 0x80) { // Not a valid continuation byte
                result.error_offset = i + j;
                return result;
            }
        }

        // Check for overlong encodings and invalid codepoints
        const codepoint = decodeUtf8Codepoint(data[i..][0..seq_len]) orelse {
            result.error_offset = i;
            return result;
        };

        // Check for overlong encoding
        if (seq_len == 2 and codepoint < 0x80) {
            result.error_offset = i;
            return result;
        }
        if (seq_len == 3 and codepoint < 0x800) {
            result.error_offset = i;
            return result;
        }
        if (seq_len == 4 and codepoint < 0x10000) {
            result.error_offset = i;
            return result;
        }

        // Check for surrogate pairs (U+D800 to U+DFFF) - invalid in UTF-8
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
            result.error_offset = i;
            return result;
        }

        // Check for values above U+10FFFF
        if (codepoint > 0x10FFFF) {
            result.error_offset = i;
            return result;
        }

        // Check for suspicious but valid codepoints
        if (result.warning_count < 25) {
            if (isNoncharacter(codepoint)) {
                result.warnings[result.warning_count] = .{ .kind = .noncharacter, .byte_offset = i };
                result.warning_count += 1;
            } else if (isBidiOverride(codepoint)) {
                result.warnings[result.warning_count] = .{ .kind = .bidi_override, .byte_offset = i };
                result.warning_count += 1;
            } else if (isZeroWidth(codepoint)) {
                result.warnings[result.warning_count] = .{ .kind = .zero_width, .byte_offset = i };
                result.warning_count += 1;
            } else if (codepoint == 0xFEFF and i > 0) {
                result.warnings[result.warning_count] = .{ .kind = .misplaced_bom, .byte_offset = i };
                result.warning_count += 1;
            }
        }

        i += seq_len;
    }
    return result; // Valid UTF-8
}

pub fn getUtf8SequenceLength(first_byte: u8) ?usize {
    if (first_byte < 0x80) return 1; // ASCII
    if ((first_byte & 0xE0) == 0xC0) return 2; // 110xxxxx
    if ((first_byte & 0xF0) == 0xE0) return 3; // 1110xxxx
    if ((first_byte & 0xF8) == 0xF0) return 4; // 11110xxx
    return null; // Invalid start byte
}

pub fn decodeUtf8Codepoint(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const first = bytes[0];

    if (bytes.len == 1) {
        return first;
    } else if (bytes.len == 2) {
        return (@as(u21, first & 0x1F) << 6) |
            @as(u21, bytes[1] & 0x3F);
    } else if (bytes.len == 3) {
        return (@as(u21, first & 0x0F) << 12) |
            (@as(u21, bytes[1] & 0x3F) << 6) |
            @as(u21, bytes[2] & 0x3F);
    } else if (bytes.len == 4) {
        return (@as(u21, first & 0x07) << 18) |
            (@as(u21, bytes[1] & 0x3F) << 12) |
            (@as(u21, bytes[2] & 0x3F) << 6) |
            @as(u21, bytes[3] & 0x3F);
    }
    return null;
}

// ============ UTF-16 Validators ============

/// Validate that a byte sequence is valid UTF-16 (little-endian).
/// Returns the byte offset of the first invalid sequence, or null if valid.
pub fn validateUtf16Le(data: []const u8) ?usize {
    if (data.len % 2 != 0) return data.len - 1; // Odd length

    var i: usize = 0;
    while (i + 1 < data.len) {
        const unit = std.mem.readInt(u16, data[i..][0..2], .little);

        // High surrogate (0xD800-0xDBFF)
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            // Must be followed by low surrogate
            if (i + 3 >= data.len) return i; // Truncated surrogate pair

            const low = std.mem.readInt(u16, data[i + 2 ..][0..2], .little);
            if (low < 0xDC00 or low > 0xDFFF) return i + 2; // Invalid low surrogate

            i += 4; // Skip surrogate pair
        }
        // Low surrogate without high surrogate
        else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return i; // Orphan low surrogate
        } else {
            i += 2;
        }
    }
    return null; // Valid UTF-16
}

/// Validate that a byte sequence is valid UTF-16 (big-endian).
pub fn validateUtf16Be(data: []const u8) ?usize {
    if (data.len % 2 != 0) return data.len - 1;

    var i: usize = 0;
    while (i + 1 < data.len) {
        const unit = std.mem.readInt(u16, data[i..][0..2], .big);

        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 3 >= data.len) return i;
            const low = std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
            if (low < 0xDC00 or low > 0xDFFF) return i + 2;
            i += 4;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return i;
        } else {
            i += 2;
        }
    }
    return null;
}

// ============ JSON Validator ============

/// Check if content contains template code markers from various templating languages.
/// Returns true if template markers are detected.
pub fn containsTemplateMarkers(content: []const u8) bool {
    // EEx/ERB/Phoenix/ASP: <% and %>
    if (std.mem.indexOf(u8, content, "<%") != null and std.mem.indexOf(u8, content, "%>") != null) {
        return true;
    }
    // Handlebars/Mustache/Jinja2: {{ and }}
    if (std.mem.indexOf(u8, content, "{{") != null and std.mem.indexOf(u8, content, "}}") != null) {
        return true;
    }
    // Jinja2/Django block tags: {% and %}
    if (std.mem.indexOf(u8, content, "{%") != null and std.mem.indexOf(u8, content, "%}") != null) {
        return true;
    }
    // PHP: <?php or <?=
    if (std.mem.indexOf(u8, content, "<?php") != null or std.mem.indexOf(u8, content, "<?=") != null) {
        return true;
    }
    return false;
}

/// Uses std.json to parse and verify syntactic correctness.
/// ext_hint: optional lowercase file extension (e.g. "json5", "jsonc", "ndjson")
/// to suppress expected-variant warnings when the extension matches the detected format.
pub fn validateJson(file: *FileSource, ext_hint: ?[]const u8) ValidationResult {
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |buf| heap.validateAllocator().free(buf);
    const content = getFileContent(file, max_text_file_size, &heap_buf) orelse {
        return ValidationResult.invalidCode(.json, .failed_to_read, "file");
    };

    // Handle UTF-16 LE/BE encoding (common on Windows)
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) heap.validateAllocator().free(conv_buf);

    const text_result = blk: {
        // Allocate conversion buffer if needed (UTF-16 -> UTF-8 can be same size or smaller)
        if (content.len >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = heap.validateAllocator().alloc(u8, content.len) catch {
                return ValidationResult.invalidCode(.json, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
        } else {
            conv_buf = &[_]u8{};
        }
        break :blk getTextContent(content, conv_buf);
    };

    const data = text_result.content;

    // RFC 8259: JSON text MUST be UTF-8. A byte that breaks UTF-8 is corruption,
    // not a parseable document — reject it (don't let a permissive path accept it).
    if (!std.unicode.utf8ValidateSlice(data)) {
        return ValidationResult.invalidCode(.json, .invalid_value, "UTF-8 encoding");
    }

    // Try to parse the JSON using Scanner
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    // First try strict JSON parsing
    if (tryParseJson(gpa.allocator(), data)) {
        return ValidationResult.okWithDepth(.json, .full);
    }

    // Strict parsing failed - check if it contains template markers
    if (containsTemplateMarkers(data)) {
        return ValidationResult.okWithWarning(.json, "JSON contains template code (not valid JSON until rendered)");
    }

    // Try stripping C-style comments (JSONC format used by MAME, VS Code, etc.)
    if (stripJsonComments(gpa.allocator(), data)) |stripped| {
        defer stripped.deinit(gpa.allocator());
        if (tryParseJson(gpa.allocator(), stripped.data)) {
            if (ext_hint) |ext| {
                if (std.mem.eql(u8, ext, "jsonc")) return ValidationResult.okWithDepth(.json, .full);
            }
            return ValidationResult.okWithWarning(.json, "JSONC: contains comments (non-standard JSON extension)");
        }
    }

    // Try JSON5 (superset of JSON with unquoted keys, trailing commas, Infinity/NaN, etc.)
    if (tryParseJson5(data)) {
        if (ext_hint) |ext| {
            if (std.mem.eql(u8, ext, "json5")) return ValidationResult.okWithDepth(.json, .full);
        }
        return ValidationResult.okWithDepthAndWarning(.json, .full, "JSON5: uses JSON5 extensions (unquoted keys, trailing commas, etc.)");
    }

    // Try JSON Lines (NDJSON) format
    return validateJsonLines(gpa.allocator(), data);
}

/// Try to parse JSON data, returns true if valid.
pub fn tryParseJson(allocator: Allocator, data: []const u8) bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, data);
    defer scanner.deinit();

    while (true) {
        const token = scanner.next() catch return false;
        if (token == .end_of_document) return true;
    }
}

/// Try to parse JSON5 data using the cj5 library.
/// JSON5 is a superset of JSON that allows unquoted keys, trailing commas,
/// single-quoted strings, hex numbers, Infinity/NaN, and C-style comments.
pub fn tryParseJson5(data: []const u8) bool {
    return cj5.isValid(data);
}

/// Result of stripping JSON comments - includes both data and the original allocation for freeing.
pub const StrippedJson = struct {
    data: []const u8,
    allocation: []u8, // The full allocation to free

    pub fn deinit(self: *const StrippedJson, allocator: Allocator) void {
        allocator.free(self.allocation);
    }
};

/// Strip C-style comments from JSON (// and /* */).
/// Returns stripped content or null if no comments found or allocation fails.
pub fn stripJsonComments(allocator: Allocator, data: []const u8) ?StrippedJson {
    // Quick scan for comment markers outside strings
    var has_comments = false;
    var in_string = false;
    var escape_next = false;
    for (data, 0..) |c, i| {
        if (!escape_next and c == '"') {
            in_string = !in_string;
        }
        escape_next = in_string and c == '\\' and !escape_next;

        if (!in_string and c == '/' and i + 1 < data.len) {
            if (data[i + 1] == '/' or data[i + 1] == '*') {
                has_comments = true;
                break;
            }
        }
    }

    if (!has_comments) return null;

    // Allocate output buffer
    const result = allocator.alloc(u8, data.len) catch return null;
    var out_idx: usize = 0;
    in_string = false;
    escape_next = false;

    var i: usize = 0;
    while (i < data.len) {
        const c = data[i];

        // Track string state to avoid stripping "comments" inside strings
        if (!escape_next and c == '"') {
            in_string = !in_string;
        }
        escape_next = in_string and c == '\\' and !escape_next;

        if (!in_string and i + 1 < data.len and c == '/') {
            if (data[i + 1] == '/') {
                // Line comment - skip until newline
                i += 2;
                while (i < data.len and data[i] != '\n') : (i += 1) {}
                // Keep the newline for line number preservation
                if (i < data.len) {
                    result[out_idx] = '\n';
                    out_idx += 1;
                    i += 1;
                }
                continue;
            } else if (data[i + 1] == '*') {
                // Block comment - skip until */
                i += 2;
                while (i + 1 < data.len) {
                    if (data[i] == '*' and data[i + 1] == '/') {
                        i += 2;
                        break;
                    }
                    // Preserve newlines for line number preservation
                    if (data[i] == '\n') {
                        result[out_idx] = '\n';
                        out_idx += 1;
                    }
                    i += 1;
                }
                continue;
            }
        }

        result[out_idx] = c;
        out_idx += 1;
        i += 1;
    }

    return StrippedJson{
        .data = result[0..out_idx],
        .allocation = result,
    };
}

/// Validate JSON Lines (NDJSON) format where each line is a complete JSON value.
pub fn validateJsonLines(allocator: Allocator, content: []const u8) ValidationResult {
    var lines_validated: usize = 0;
    var iter = std.mem.splitScalar(u8, content, '\n');

    while (iter.next()) |line| {
        // Skip empty lines (allowed in JSON Lines)
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Try to parse this line as JSON
        var scanner = std.json.Scanner.initCompleteInput(allocator, trimmed);
        defer scanner.deinit();

        while (true) {
            const token = scanner.next() catch {
                if (lines_validated == 0) {
                    return ValidationResult.invalid(.json, "JSON parse error");
                } else {
                    return ValidationResult.invalid(.json, "JSON Lines parse error");
                }
            };
            if (token == .end_of_document) break;
        }
        lines_validated += 1;
    }

    if (lines_validated == 0) {
        return ValidationResult.invalidCode(.json, .empty, "JSON file");
    }

    // JSON Lines validated successfully
    return ValidationResult.okWithDepth(.json, .full);
}

// ============ TOML Validator ============

/// Validate TOML file structure.
/// Uses the external sam701/zig-toml parser for validation.
pub fn validateToml(file: *FileSource) ValidationResult {
    const toml = @import("toml");

    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |buf| heap.validateAllocator().free(buf);
    const content = getFileContent(file, max_text_file_size, &heap_buf) orelse {
        return ValidationResult.invalidCode(.toml, .failed_to_read, "file");
    };

    // Handle UTF-16 and BOM
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) heap.validateAllocator().free(conv_buf);

    const data = blk: {
        if (content.len >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = heap.validateAllocator().alloc(u8, content.len) catch {
                return ValidationResult.invalidCode(.toml, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content, conv_buf);
            break :blk text_result.content;
        }
        if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            break :blk content[3..];
        }
        break :blk content;
    };

    // TOML spec: a TOML file MUST be a valid UTF-8 document. A byte that breaks
    // UTF-8 is corruption — reject it before the parser (which is permissive).
    if (!std.unicode.utf8ValidateSlice(data)) {
        return ValidationResult.invalidCode(.toml, .invalid_value, "UTF-8 encoding");
    }
    // Use the sam701/zig-toml parser to parse as a generic Table
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(data) catch {
        return ValidationResult.invalid(.toml, "TOML parse error");
    };
    defer parsed.deinit();

    // TOML parsed successfully with semantic validation
    return ValidationResult.okWithDepth(.toml, .structural);
}

// ============ INI Validator ============

/// Validate INI file structure.
/// INI files have [section] headers and key=value pairs.
/// Detection already verified basic structure, so we just do a simple parse check.
/// Handles UTF-8 and UTF-16 LE encoded INI files (common on Windows).
pub fn validateIni(file: *FileSource) ValidationResult {
    // Get file size
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.ini, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        return ValidationResult.invalidCode(.ini, .empty, "INI file");
    }

    if (file_sz > max_text_file_size) {
        return ValidationResult.invalid(.ini, "INI file too large (>1GB)");
    }

    // Read first portion to verify structure
    const read_size: usize = @min(@as(usize, @intCast(file_sz)), 8192);
    var buffer: [8192]u8 = undefined;

    file.seekTo(0) catch {
        return ValidationResult.invalid(.ini, "Failed to seek");
    };

    const bytes_read = file.read(buffer[0..read_size]) catch {
        return ValidationResult.invalidCode(.ini, .failed_to_read, "file");
    };

    if (bytes_read == 0) {
        return ValidationResult.invalidCode(.ini, .empty, "INI file");
    }

    // Check for UTF-16 LE BOM and convert if needed
    var content: []const u8 = buffer[0..bytes_read];
    var utf8_buf: [4096]u8 = undefined;

    if (bytes_read >= 2 and buffer[0] == 0xFF and buffer[1] == 0xFE) {
        // UTF-16 LE BOM detected - convert to UTF-8
        if (convertUtf16LeToUtf8(buffer[2..bytes_read], &utf8_buf)) |utf8_content| {
            content = utf8_content;
        } else {
            // Conversion failed - not valid UTF-16
            return ValidationResult.invalidCode(.ini, .invalid_value, "UTF-16 encoding");
        }
    } else if (bytes_read >= 3 and buffer[0] == 0xEF and buffer[1] == 0xBB and buffer[2] == 0xBF) {
        // UTF-8 BOM - skip it
        content = buffer[3..bytes_read];
    } else if (looksLikeUtf16LeWithoutBom(buffer[0..bytes_read])) {
        // UTF-16 LE without BOM detected by heuristic (common on Windows)
        if (convertUtf16LeToUtf8(buffer[0..bytes_read], &utf8_buf)) |utf8_content| {
            content = utf8_content;
        } else {
            // Conversion failed - not valid UTF-16
            return ValidationResult.invalidCode(.ini, .invalid_value, "UTF-16 encoding");
        }
    }

    // Verify we can find at least one [section] or key=value pattern
    return validateIniContent(content);
}

/// Check INI content (UTF-8) for valid structure.
/// Performs full validation: every line must be valid (empty, comment, section, or key=value).
pub fn validateIniContent(content: []const u8) ValidationResult {
    var found_structure = false;
    var line_num: usize = 1;
    var i: usize = 0;

    while (i < content.len) {
        const line_start = i;

        // Find end of line
        while (i < content.len and content[i] != '\n') : (i += 1) {}
        const line_end = if (i > line_start and content[i - 1] == '\r') i - 1 else i;
        const line = content[line_start..line_end];

        // Skip past newline for next iteration
        if (i < content.len and content[i] == '\n') i += 1;

        // Validate this line
        const validation = validateIniLine(line);
        switch (validation) {
            .empty, .comment => {}, // Valid but not structural
            .section, .key_value => found_structure = true, // Valid structure
            .invalid => {
                // Return error with line number
                return ValidationResult.invalidCode(.ini, .invalid_value, "INI syntax");
            },
        }

        line_num += 1;
    }

    if (!found_structure) {
        // File has .ini extension but no INI structure - treat as Unknown text file
        // This is common with MAME config files that use whitespace-separated key/value pairs
        return ValidationResult.okWithDepth(.unknown, .structural);
    }

    // INI fully validated - every line is syntactically correct
    return ValidationResult.okWithDepth(.ini, .structural);
}

/// Result of validating a single INI line
pub const IniLineType = enum {
    empty, // Blank line or whitespace only
    comment, // Starts with ; or #
    section, // [section_name]
    key_value, // key = value
    invalid, // Syntax error
};

/// Validate a single INI line.
/// Valid lines are:
/// - Empty (whitespace only)
/// - Comment: starts with ; or # (after optional whitespace)
/// - Section: [name] where name contains alphanumeric, dots, underscores, hyphens, spaces
/// - Key-value: key = value where key starts with letter/underscore
pub fn validateIniLine(line: []const u8) IniLineType {
    var i: usize = 0;

    // Skip leading whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Empty line (or whitespace only)
    if (i >= line.len) return .empty;

    const first_char = line[i];

    // Comment line
    if (first_char == ';' or first_char == '#') return .comment;

    // Section header: [name]
    if (first_char == '[') {
        i += 1;
        // Section name: allow any printable ASCII except ] and newline.
        // Real-world INI sections include things like [.ShellClassInfo],
        // [{GUID}], [remote "origin"], etc.
        const name_start = i;
        while (i < line.len and line[i] != ']' and line[i] != '\n') {
            const ch = line[i];
            if (ch >= 0x20 and ch <= 0x7E) {
                i += 1;
            } else if (ch >= 0x80) {
                // Allow UTF-8 continuation bytes in section names
                i += 1;
            } else {
                return .invalid; // Control character in section name
            }
        }
        // Must have closing ]
        if (i >= line.len or line[i] != ']') return .invalid;
        // Must have at least one character in name
        if (i == name_start) return .invalid;
        i += 1;
        // Only whitespace or inline comment allowed after ]
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i < line.len and line[i] != ';' and line[i] != '#') return .invalid;
        return .section;
    }

    // Unreal Engine INI array operation prefixes: +Key=value, -Key=value, .Key=value, !Key=value
    // These are used for array append (+), remove (-), clear-and-add (.), and exact-remove (!)
    if (first_char == '+' or first_char == '-' or first_char == '!') {
        // Skip the prefix and check if a valid key follows
        i += 1;
        if (i < line.len) {
            const next_char = line[i];
            if ((next_char >= 'a' and next_char <= 'z') or
                (next_char >= 'A' and next_char <= 'Z') or
                (next_char >= '0' and next_char <= '9') or
                next_char == '_' or next_char == '.' or next_char == '-' or next_char == '%' or
                next_char >= 0x80)
            {
                // Continue to key-value parsing below with the prefix consumed
                while (i < line.len) {
                    const ch = line[i];
                    if (ch == '=' or ch == ':') break;
                    if (ch < 0x20 and ch != '\t') return .invalid;
                    i += 1;
                }
                if (i >= line.len or (line[i] != '=' and line[i] != ':')) return .invalid;
                return .key_value;
            }
        }
        return .invalid;
    }

    // Bare '=' with no key (e.g., game config files like Neverwinter Nights).
    // Quirky but tolerated by most INI parsers — treat as valid key-value.
    if (first_char == '=') return .key_value;

    // Key-value pair: key = value (or key: value)
    // Key must start with a printable non-special character.
    // Real-world INI keys include dots, hyphens, percent signs, spaces, etc.
    // (e.g., LocalizedResourceName, icon-theme, user.name,
    // "Administrative Tools.lnk" in Windows desktop.ini)
    if ((first_char >= 'a' and first_char <= 'z') or
        (first_char >= 'A' and first_char <= 'Z') or
        (first_char >= '0' and first_char <= '9') or
        first_char == '_' or first_char == '.' or first_char == '-' or first_char == '%' or
        first_char >= 0x80) // UTF-8
    {
        // Scan forward to find delimiter (= or :), allowing spaces within keys.
        // Windows desktop.ini uses filenames as keys which commonly contain spaces
        // (e.g., "Administrative Tools.lnk=@%SystemRoot%\...").
        while (i < line.len) {
            const ch = line[i];
            if (ch == '=' or ch == ':') break;
            if (ch < 0x20 and ch != '\t') return .invalid; // Control chars
            i += 1;
        }
        // Must have = or : (both are common INI delimiters)
        if (i >= line.len or (line[i] != '=' and line[i] != ':')) return .invalid;
        // Value can be anything after delimiter, so this is valid
        return .key_value;
    }

    // Line starts with something unexpected
    return .invalid;
}

/// Detect UTF-16 LE encoding without BOM by looking for the pattern of
/// ASCII characters followed by null bytes (e.g., '[', 0x00, 's', 0x00, ...).
/// This is common in Windows-generated INI files.
pub fn looksLikeUtf16LeWithoutBom(data: []const u8) bool {
    if (data.len < 4) return false;

    // Check for pattern: printable ASCII followed by 0x00, repeated
    // At least 4 such pairs in the first 16 bytes suggests UTF-16 LE
    var utf16_pairs: usize = 0;
    var i: usize = 0;
    const check_len = @min(data.len, 16);

    while (i + 1 < check_len) {
        const char = data[i];
        const next = data[i + 1];

        // Printable ASCII or common whitespace followed by 0x00
        if (((char >= 0x20 and char <= 0x7E) or char == 0x09 or char == 0x0A or char == 0x0D) and next == 0x00) {
            utf16_pairs += 1;
        }
        i += 2;
    }

    // If at least half the byte pairs look like UTF-16 LE, it probably is
    return utf16_pairs >= 4;
}

// ============ XML Validator ============

/// Validate XML file structure using zig-xml library (0BSD, ianprime0509/zig-xml).
/// Performs full XML 1.0 Fifth Edition well-formedness check.
/// DOCTYPE declarations are stripped before parsing (DTD validation is not performed).
/// Adds an XML 1.1 fallback path: control-character numeric refs in 0x01..0x1F
/// (excluding 0x09/0x0A/0x0D, which are legal in 1.0) are permitted under 1.1
/// (§2.2 Restricted Characters). Apple .keylayout files declare version="1.1"
/// and rely on this. We accept them by rewriting offending refs to U+0020 SPACE
/// before handing the data to zig-xml (which is a strict 1.0 parser).
pub fn validateXml(file: *FileSource) ValidationResult {
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |buf| heap.validateAllocator().free(buf);
    const content = getFileContent(file, max_text_file_size, &heap_buf) orelse {
        return ValidationResult.invalidCode(.xml, .failed_to_read, "file");
    };

    // Handle UTF-16 LE/BE encoding
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) heap.validateAllocator().free(conv_buf);

    const raw_data = blk: {
        if (content.len >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = heap.validateAllocator().alloc(u8, content.len) catch {
                return ValidationResult.invalidCode(.xml, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content, conv_buf);
            break :blk text_result.content;
        }
        break :blk content;
    };

    // Normalize ASCII-compatible encodings (us-ascii, iso-8859-1, etc.) to UTF-8
    // These are byte-compatible for ASCII range which is what most XML files use
    const encoding_normalized = normalizeXmlEncoding(heap.validateAllocator(), raw_data);
    defer if (encoding_normalized.allocated) heap.validateAllocator().free(@constCast(encoding_normalized.data));

    // Strip DOCTYPE declaration if present (zig-xml doesn't support DTD validation)
    // We only validate XML structure, not DTD conformance
    const preprocessed = stripDoctypeDeclaration(heap.validateAllocator(), encoding_normalized.data);
    defer if (preprocessed.allocated) heap.validateAllocator().free(preprocessed.data);

    // XML 1.1 dispatch:
    //   * If <?xml version="1.1"?> is declared, preprocess control-char refs up front.
    //   * Otherwise, attempt 1.0 parse first; on character_reference_malformed,
    //     scan for 1.1-only refs (0x01..0x1F minus 9/A/D) and retry preprocessed.
    //     If 1.1 accepts it, return WARN: technically non-conformant per declaration.
    const declares_xml11 = isXml11Declared(preprocessed.data);

    if (declares_xml11) {
        const rewrite = rewriteXml11ControlRefs(heap.validateAllocator(), preprocessed.data) orelse {
            return ValidationResult.invalidCode(.xml, .failed_to_allocate, "1.1 rewrite buffer");
        };
        defer if (rewrite.allocated) heap.validateAllocator().free(rewrite.data);
        const outcome = parseXmlWellFormed(preprocessed.had_doctype, rewrite.data);
        switch (outcome) {
            .ok => |has_doctype_warn| {
                _ = has_doctype_warn;
                return ValidationResult.okWithDepth(.xml, .structural);
            },
            .undefined_entity_under_doctype => {
                var tolerated = ValidationResult.okWithDepthAndMalformation(.xml, .structural, .xml_undefined_entity);
                tolerated.warning_message = "undefined entity reference tolerated";
                return tolerated;
            },
            .err => |msg| return ValidationResult.invalid(.xml, msg),
            .out_of_memory => return ValidationResult.invalidCode(.xml, .out_of_memory, "during parsing"),
            .read_failed => return ValidationResult.invalid(.xml, "Read failed during parsing"),
        }
    }

    const first_outcome = parseXmlWellFormed(preprocessed.had_doctype, preprocessed.data);
    switch (first_outcome) {
        .ok => |has_doctype_warn| {
            _ = has_doctype_warn;
            return ValidationResult.okWithDepth(.xml, .structural);
        },
        .undefined_entity_under_doctype => {
            var tolerated = ValidationResult.okWithDepthAndMalformation(.xml, .structural, .xml_undefined_entity);
            tolerated.warning_message = "undefined entity reference tolerated";
            return tolerated;
        },
        .err => |msg| {
            // Only retry under XML 1.1 rules if the failure is a malformed character reference
            // and the content contains an offending 1.1-only control-char ref (0x01..0x1F minus 9/A/D).
            if (std.mem.eql(u8, msg, "malformed character reference") and hasXml11ControlCharRef(preprocessed.data)) {
                const rewrite = rewriteXml11ControlRefs(heap.validateAllocator(), preprocessed.data) orelse {
                    return ValidationResult.invalidCode(.xml, .failed_to_allocate, "1.1 rewrite buffer");
                };
                defer if (rewrite.allocated) heap.validateAllocator().free(rewrite.data);
                const retry = parseXmlWellFormed(preprocessed.had_doctype, rewrite.data);
                switch (retry) {
                    .ok => return ValidationResult.okWithDepthAndWarning(.xml, .structural, "uses XML 1.1 control-character refs without declaring version 1.1"),
                    .undefined_entity_under_doctype => {
                        var tolerated = ValidationResult.okWithDepthAndMalformation(.xml, .structural, .xml_undefined_entity);
                        tolerated.warning_message = "uses XML 1.1 control-character refs without declaring version 1.1; DOCTYPE skipped";
                        return tolerated;
                    },
                    else => {},
                }
            }
            return ValidationResult.invalid(.xml, msg);
        },
        .out_of_memory => return ValidationResult.invalidCode(.xml, .out_of_memory, "during parsing"),
        .read_failed => return ValidationResult.invalid(.xml, "Read failed during parsing"),
    }
}

const XmlParseOutcome = union(enum) {
    /// Parsed successfully. Bool is true when DOCTYPE was stripped (warning).
    ok: bool,
    /// Parsed all the way through, but encountered an undefined entity reference
    /// inside a document that had its DOCTYPE stripped — we treat this as a
    /// tolerated structural malformation (the entity may have been declared in
    /// the DTD we discarded).
    undefined_entity_under_doctype: void,
    err: []const u8,
    out_of_memory: void,
    read_failed: void,
};

fn parseXmlWellFormed(had_doctype: bool, data: []const u8) XmlParseOutcome {
    const xml = @import("xml");
    var static_reader: xml.Reader.Static = .init(heap.validateAllocator(), data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch |err| {
            switch (err) {
                error.MalformedXml => {
                    const error_code = reader.errorCode();
                    const error_msg = switch (error_code) {
                        .xml_declaration_attribute_unsupported => "XML declaration attribute unsupported",
                        .xml_declaration_version_missing => "XML declaration version missing",
                        .xml_declaration_version_unsupported => "XML declaration version unsupported",
                        .xml_declaration_encoding_unsupported => "XML declaration encoding unsupported",
                        .xml_declaration_standalone_malformed => "XML declaration standalone malformed",
                        .doctype_unsupported => "DOCTYPE unsupported",
                        .directive_unknown => "unknown directive",
                        .attribute_missing_space => "missing space before attribute",
                        .attribute_duplicate => "duplicate attribute",
                        .attribute_prefix_undeclared => "attribute prefix undeclared",
                        .attribute_illegal_character => "illegal character in attribute",
                        .element_end_mismatched => "mismatched end tag",
                        .element_end_unclosed => "unclosed end tag",
                        .comment_malformed => "malformed comment",
                        .comment_unclosed => "unclosed comment",
                        .pi_unclosed => "unclosed processing instruction",
                        .pi_target_disallowed => "disallowed processing instruction target",
                        .pi_missing_space => "missing space in processing instruction",
                        .text_cdata_end_disallowed => "CDATA end marker in text",
                        .cdata_unclosed => "unclosed CDATA section",
                        .entity_reference_unclosed => "unclosed entity reference",
                        .entity_reference_undefined => "undefined entity reference",
                        .character_reference_unclosed => "unclosed character reference",
                        .character_reference_malformed => "malformed character reference",
                        .name_malformed => "malformed name",
                        .namespace_prefix_unbound => "unbound namespace prefix",
                        .namespace_binding_illegal => "illegal namespace binding",
                        .namespace_prefix_illegal => "illegal namespace prefix",
                        .unexpected_character => "unexpected character",
                        .unexpected_eof => "unexpected end of file",
                        .expected_equals => "expected equals sign",
                        .expected_quote => "expected quote",
                        .missing_end_quote => "missing end quote",
                        .invalid_encoding => "invalid encoding",
                        .illegal_character => "illegal character",
                    };
                    if (error_code == .entity_reference_undefined and had_doctype) {
                        return .{ .undefined_entity_under_doctype = {} };
                    }
                    return .{ .err = error_msg };
                },
                error.OutOfMemory => return .{ .out_of_memory = {} },
                error.ReadFailed => return .{ .read_failed = {} },
            }
        };
        if (node == .eof) break;
    }
    return .{ .ok = had_doctype };
}

/// Detect an XML 1.1 declaration: `<?xml ... version="1.1" ... ?>` (single or double quote).
/// Tolerant: only the leading bytes of the document are inspected.
fn isXml11Declared(data: []const u8) bool {
    const head_len = @min(data.len, 256);
    const head = data[0..head_len];
    if (!std.mem.startsWith(u8, std.mem.trimStart(u8, head, &[_]u8{ ' ', '\t', '\r', '\n', 0xEF, 0xBB, 0xBF }), "<?xml")) return false;
    const decl_end = std.mem.indexOf(u8, head, "?>") orelse return false;
    const decl = head[0..decl_end];
    // Look for version="1.1" or version='1.1' allowing surrounding whitespace.
    return std.mem.indexOf(u8, decl, "version=\"1.1\"") != null or
        std.mem.indexOf(u8, decl, "version='1.1'") != null;
}

/// Scan for an XML-1.1-only numeric character reference: 0x01..0x1F except 0x09/0x0A/0x0D.
/// Recognizes both `&#xHH;` (hex) and `&#DD;` (decimal) forms.
fn hasXml11ControlCharRef(data: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "&#")) |hash| {
        i = hash + 2;
        if (i >= data.len) return false;
        const code = parseCharRefCodePoint(data, i) orelse continue;
        if (isXml11OnlyControl(code.value)) return true;
        i = code.end_excl;
    }
    return false;
}

const CharRefSpan = struct { value: u32, end_excl: usize };

fn parseCharRefCodePoint(data: []const u8, start: usize) ?CharRefSpan {
    var idx = start;
    var hex = false;
    if (idx < data.len and (data[idx] == 'x' or data[idx] == 'X')) {
        hex = true;
        idx += 1;
    }
    const num_start = idx;
    while (idx < data.len) : (idx += 1) {
        const c = data[idx];
        if (c == ';') break;
        if (hex) {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return null;
        } else {
            if (!(c >= '0' and c <= '9')) return null;
        }
    }
    if (idx >= data.len or data[idx] != ';' or num_start == idx) return null;
    const slice = data[num_start..idx];
    const value = std.fmt.parseInt(u32, slice, if (hex) 16 else 10) catch return null;
    return .{ .value = value, .end_excl = idx + 1 };
}

fn isXml11OnlyControl(c: u32) bool {
    return switch (c) {
        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F => true,
        else => false,
    };
}

/// Rewrite XML 1.1-only control-character numeric refs to a 1.0-legal `&#x20;`
/// (SPACE). This is a structural well-formedness aid — we don't preserve the
/// semantic value of the control character because our caller only validates
/// well-formedness, not content. NUL refs (0x00) are left alone so the parser
/// rejects them (NUL is forbidden in both 1.0 and 1.1).
const RewriteResult = struct { data: []const u8, allocated: bool };
fn rewriteXml11ControlRefs(allocator: Allocator, data: []const u8) ?RewriteResult {
    if (!hasXml11ControlCharRef(data)) return RewriteResult{ .data = data, .allocated = false };
    var out = std.ArrayListUnmanaged(u8).empty;
    out.ensureTotalCapacity(allocator, data.len) catch {
        out.deinit(allocator);
        return null;
    };
    var i: usize = 0;
    while (i < data.len) {
        if (i + 1 < data.len and data[i] == '&' and data[i + 1] == '#') {
            if (parseCharRefCodePoint(data, i + 2)) |span| {
                if (isXml11OnlyControl(span.value)) {
                    out.appendSlice(allocator, "&#x20;") catch {
                        out.deinit(allocator);
                        return null;
                    };
                    i = span.end_excl;
                    continue;
                }
            }
        }
        out.append(allocator, data[i]) catch {
            out.deinit(allocator);
            return null;
        };
        i += 1;
    }
    return RewriteResult{ .data = out.toOwnedSlice(allocator) catch return null, .allocated = true };
}

// ============ CSV Validator ============

/// Validate CSV (Comma-Separated Values) files.
/// Checks for consistent column count, proper quoting, and valid UTF-8.
pub fn validateCsv(file: *FileSource) ValidationResult {
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.csv, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        // Empty CSV is technically valid
        return ValidationResult.ok(.csv);
    }

    // Sample first 1MB for validation
    const max_sample_size: u64 = 1024 * 1024;
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |buf| heap.validateAllocator().free(buf);
    const content = getFileContent(file, max_sample_size, &heap_buf) orelse blk: {
        // File larger than sample — use mmap range or read sample
        if (file.getMappedRange(0, max_sample_size)) |mapped| break :blk mapped;
        const sample = heap.validateAllocator().alloc(u8, @intCast(max_sample_size)) catch {
            return ValidationResult.invalidCode(.csv, .failed_to_allocate, "sample buffer");
        };
        heap_buf = sample;
        file.seekTo(0) catch return ValidationResult.invalidCode(.csv, .failed_to_read, "file");
        const n = file.readAll(sample) catch return ValidationResult.invalidCode(.csv, .failed_to_read, "file");
        if (n == 0) return ValidationResult.invalidCode(.csv, .failed_to_read, "file");
        break :blk sample[0..n];
    };
    const sampled_prefix = file_sz > content.len;

    // Handle UTF-16/BOM
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) heap.validateAllocator().free(conv_buf);

    const data = blk: {
        if (content.len >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = heap.validateAllocator().alloc(u8, content.len) catch {
                return ValidationResult.invalidCode(.csv, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content, conv_buf);
            break :blk text_result.content;
        }
        if (content.len >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            break :blk content[3..];
        }
        break :blk content;
    };

    // Check for UTF-8 validity
    if (!std.unicode.utf8ValidateSlice(data)) {
        return ValidationResult.invalidCode(.csv, .invalid_value, "UTF-8 encoding");
    }

    // Detect delimiter by looking at first line
    const delimiter = detectCsvDelimiter(data);

    // Parse rows and check column consistency
    var row_count: u32 = 0;
    var first_row_cols: ?u32 = null;
    var pos: usize = 0;
    var in_quotes = false;
    var col_count: u32 = 1; // Start with 1 (first column)
    var row_start: usize = 0;

    while (pos < data.len) {
        const c = data[pos];

        if (in_quotes) {
            if (c == '"') {
                // Check for escaped quote
                if (pos + 1 < data.len and data[pos + 1] == '"') {
                    pos += 2;
                    continue;
                }
                in_quotes = false;
            }
        } else {
            if (c == '"') {
                in_quotes = true;
            } else if (c == delimiter) {
                col_count += 1;
            } else if (c == '\n' or c == '\r') {
                // End of row
                if (pos > row_start) { // Non-empty row
                    if (first_row_cols == null) {
                        first_row_cols = col_count;
                    } else if (col_count != first_row_cols.?) {
                        // Column count mismatch - this is a warning, not necessarily invalid
                        // Many real CSVs have irregular rows
                    }
                    row_count += 1;
                }

                // Skip \r\n combination
                if (c == '\r' and pos + 1 < data.len and data[pos + 1] == '\n') {
                    pos += 1;
                }

                col_count = 1;
                row_start = pos + 1;
            }
        }
        pos += 1;
    }

    // Handle last row without trailing newline
    if (pos > row_start and !in_quotes) {
        row_count += 1;
    }

    // Check for unclosed quote
    if (in_quotes) {
        if (sampled_prefix and row_count > 0) {
            return ValidationResult.okWithDepth(.csv, .structural);
        }
        return ValidationResult.invalid(.csv, "Unclosed quoted field");
    }

    // Basic sanity checks
    if (row_count == 0 and data.len > 0) {
        // File has content but no parseable rows - might be binary
        return ValidationResult.invalidCode(.csv, .no_valid_x_found, "CSV rows");
    }

    return ValidationResult.okWithDepth(.csv, .structural);
}

/// Detect CSV delimiter by analyzing first line
pub fn detectCsvDelimiter(data: []const u8) u8 {
    var comma_count: u32 = 0;
    var tab_count: u32 = 0;
    var semicolon_count: u32 = 0;
    var pipe_count: u32 = 0;
    var in_quotes = false;

    for (data) |c| {
        if (c == '\n' or c == '\r') break;

        if (in_quotes) {
            if (c == '"') in_quotes = false;
            continue;
        }

        if (c == '"') {
            in_quotes = true;
        } else if (c == ',') {
            comma_count += 1;
        } else if (c == '\t') {
            tab_count += 1;
        } else if (c == ';') {
            semicolon_count += 1;
        } else if (c == '|') {
            pipe_count += 1;
        }
    }

    // Return most common delimiter
    var max_count = comma_count;
    var delimiter: u8 = ',';

    if (tab_count > max_count) {
        max_count = tab_count;
        delimiter = '\t';
    }
    if (semicolon_count > max_count) {
        max_count = semicolon_count;
        delimiter = ';';
    }
    if (pipe_count > max_count) {
        delimiter = '|';
    }

    return delimiter;
}

// ============ MessagePack Validator ============

/// Validate MessagePack binary serialization structure by walking the top-level
/// element tree. No magic bytes — relies on extension-based detection (.msgpack).
/// Iteratively walks the type/length/data structure verifying all elements fit
/// within the file and format bytes are valid.
pub fn validateMsgpack(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.msgpack, .failed_to_get, "file size");
    if (file_size == 0) return ValidationResult.invalidCode(.msgpack, .empty, "MessagePack file");

    file.seekTo(0) catch return ValidationResult.invalidCode(.msgpack, .failed_to_seek, "in MessagePack file");

    // Read up to 64KB for structural validation
    const read_size: usize = @min(file_size, 65536);
    const buf = heap.validateAllocator().alloc(u8, 65536) catch {
        return ValidationResult.invalidCode(.msgpack, .out_of_memory, "MessagePack read buffer");
    };
    defer heap.validateAllocator().free(buf);
    const bytes_read = file.readAll(buf[0..read_size]) catch
        return ValidationResult.invalidCode(.msgpack, .failed_to_read, "MessagePack data");
    if (bytes_read == 0) return ValidationResult.invalidCode(.msgpack, .empty, "MessagePack file");

    const data = buf[0..bytes_read];

    // Walk the structure iteratively using a stack of remaining element counts
    var stack: [128]u32 = undefined; // nesting depth limit
    var depth: usize = 0;
    var pos: usize = 0;
    var elements_validated: u32 = 0;

    stack[0] = 1; // expect exactly 1 top-level element
    depth = 1;

    while (depth > 0) {
        if (stack[depth - 1] == 0) {
            depth -= 1;
            continue;
        }
        stack[depth - 1] -= 1;

        if (pos >= data.len) {
            // Ran out of data — only fail if we read the entire file
            if (bytes_read < file_size) return ValidationResult.structuralOnly(.msgpack);
            return ValidationResult.invalidCode(.msgpack, .truncated, "MessagePack element");
        }

        const fmt_byte = data[pos];
        pos += 1;
        elements_validated += 1;

        // Prevent excessive processing
        if (elements_validated > 10000) return ValidationResult.structuralOnly(.msgpack);

        if (fmt_byte <= 0x7f) {
            // positive fixint — no additional data
        } else if (fmt_byte >= 0xe0) {
            // negative fixint — no additional data
        } else if ((fmt_byte & 0xf0) == 0x80) {
            // fixmap: N key-value pairs
            const n: u32 = @as(u32, fmt_byte & 0x0f) * 2;
            if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
            stack[depth] = n;
            depth += 1;
        } else if ((fmt_byte & 0xf0) == 0x90) {
            // fixarray: N elements
            const n: u32 = fmt_byte & 0x0f;
            if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
            stack[depth] = n;
            depth += 1;
        } else if ((fmt_byte & 0xe0) == 0xa0) {
            // fixstr: length in lower 5 bits
            const len: usize = fmt_byte & 0x1f;
            if (pos + len > data.len) {
                if (bytes_read < file_size) return ValidationResult.structuralOnly(.msgpack);
                return ValidationResult.invalidCode(.msgpack, .truncated, "MessagePack fixstr");
            }
            pos += len;
        } else switch (fmt_byte) {
            0xc0 => {}, // nil
            0xc1 => return ValidationResult.invalidCode(.msgpack, .invalid_value, "MessagePack reserved byte 0xc1"),
            0xc2, 0xc3 => {}, // false, true
            0xc4 => { // bin 8
                if (pos >= data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = data[pos];
                pos += 1;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xc5 => { // bin 16
                if (pos + 2 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xc6 => { // bin 32
                if (pos + 4 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xc7 => { // ext 8
                if (pos + 2 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = data[pos];
                pos += 2; // length + type byte
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xc8 => { // ext 16
                if (pos + 3 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 3;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xc9 => { // ext 32
                if (pos + 5 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 5;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xca => pos += 4, // float 32
            0xcb => pos += 8, // float 64
            0xcc => pos += 1, // uint 8
            0xcd => pos += 2, // uint 16
            0xce => pos += 4, // uint 32
            0xcf => pos += 8, // uint 64
            0xd0 => pos += 1, // int 8
            0xd1 => pos += 2, // int 16
            0xd2 => pos += 4, // int 32
            0xd3 => pos += 8, // int 64
            0xd4 => pos += 2, // fixext 1 (type + 1 byte)
            0xd5 => pos += 3, // fixext 2
            0xd6 => pos += 5, // fixext 4
            0xd7 => pos += 9, // fixext 8
            0xd8 => pos += 17, // fixext 16
            0xd9 => { // str 8
                if (pos >= data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = data[pos];
                pos += 1;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xda => { // str 16
                if (pos + 2 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xdb => { // str 32
                if (pos + 4 > data.len) return msgpackTruncated(bytes_read, file_size);
                const len: usize = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                if (pos + len > data.len) return msgpackTruncated(bytes_read, file_size);
                pos += len;
            },
            0xdc => { // array 16
                if (pos + 2 > data.len) return msgpackTruncated(bytes_read, file_size);
                const n: u32 = std.mem.readInt(u16, data[pos..][0..2], .big);
                pos += 2;
                if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
                stack[depth] = n;
                depth += 1;
            },
            0xdd => { // array 32
                if (pos + 4 > data.len) return msgpackTruncated(bytes_read, file_size);
                const n: u32 = std.mem.readInt(u32, data[pos..][0..4], .big);
                pos += 4;
                if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
                stack[depth] = n;
                depth += 1;
            },
            0xde => { // map 16
                if (pos + 2 > data.len) return msgpackTruncated(bytes_read, file_size);
                const n: u32 = @as(u32, std.mem.readInt(u16, data[pos..][0..2], .big)) * 2;
                pos += 2;
                if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
                stack[depth] = n;
                depth += 1;
            },
            0xdf => { // map 32
                if (pos + 4 > data.len) return msgpackTruncated(bytes_read, file_size);
                const n: u32 = std.mem.readInt(u32, data[pos..][0..4], .big) *| 2;
                pos += 4;
                if (depth >= stack.len) return ValidationResult.invalidCode(.msgpack, .too_many, "nesting levels");
                stack[depth] = n;
                depth += 1;
            },
            else => return ValidationResult.invalidCode(.msgpack, .invalid_value, "MessagePack format byte"),
        }

        // Bounds check for fixed-size skips
        if (pos > data.len) {
            if (bytes_read < file_size) return ValidationResult.structuralOnly(.msgpack);
            return ValidationResult.invalidCode(.msgpack, .truncated, "MessagePack data");
        }
    }

    return ValidationResult.structuralOnly(.msgpack);
}

fn msgpackTruncated(bytes_read: usize, file_size: u64) ValidationResult {
    if (bytes_read < file_size) return ValidationResult.structuralOnly(.msgpack);
    return ValidationResult.invalidCode(.msgpack, .truncated, "MessagePack data");
}

// ============ RTF Validator ============

/// Validate RTF document structure.
pub fn validateRtf(file: *FileSource) ValidationResult {
    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_read, "RTF header");
    };

    if (bytes_read < 6) {
        return ValidationResult.invalidCode(.rtf, .file_too_small, "RTF");
    }

    // Check RTF signature
    if (!std.mem.eql(u8, header[0..5], "{\\rtf")) {
        return ValidationResult.invalidCode(.rtf, .invalid_signature, "RTF");
    }

    // Check version character (should be a digit, typically '1')
    if (header[5] < '0' or header[5] > '9') {
        return ValidationResult.invalidCode(.rtf, .invalid_value, "RTF version");
    }

    // Verify file ends with closing brace by scanning end of file
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_get, "file size");
    };

    if (file_size < 10) {
        return ValidationResult.invalid(.rtf, "RTF file too small");
    }

    // Check last few bytes for closing brace
    const tail_start = if (file_size > 256) file_size - 256 else 0;
    file.seekTo(tail_start) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_seek, "to end");
    };

    var tail: [256]u8 = undefined;
    const tail_bytes = file.read(&tail) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_read, "RTF tail");
    };

    // Find last non-whitespace character
    var last_idx: usize = tail_bytes;
    while (last_idx > 0) {
        last_idx -= 1;
        const c = tail[last_idx];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0) {
            break;
        }
    }

    if (tail[last_idx] != '}') {
        return ValidationResult.invalid(.rtf, "RTF file missing closing brace");
    }

    return ValidationResult.ok(.rtf);
}

/// Deep validation for RTF files.
/// Validates brace matching and control word structure.
pub fn validateRtfDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_get, "file size");
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit
        return ValidationResult.okWithDepth(.rtf, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.rtf, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = source.readAll(data) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.rtf, .incomplete, "file read");
    }

    // Check signature
    if (data.len < 6 or !std.mem.eql(u8, data[0..5], "{\\rtf")) {
        return ValidationResult.invalidCode(.rtf, .invalid_signature, "RTF");
    }

    // Check version character
    if (data[5] < '0' or data[5] > '9') {
        return ValidationResult.invalidCode(.rtf, .invalid_value, "RTF version");
    }

    // Validate brace matching
    var brace_depth: i32 = 0;
    var i: usize = 0;
    var in_escape = false;

    while (i < data.len) {
        const c = data[i];

        if (in_escape) {
            in_escape = false;
            i += 1;
            continue;
        }

        if (c == '\\') {
            in_escape = true;
        } else if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            brace_depth -= 1;
            if (brace_depth < 0) {
                return ValidationResult.invalid(.rtf, "Unmatched closing brace");
            }
        }
        i += 1;
    }

    if (brace_depth != 0) {
        return ValidationResult.invalid(.rtf, "Mismatched braces in RTF");
    }

    return ValidationResult.okWithDepth(.rtf, .structural);
}

// ============ HTML Validator ============

/// Case-insensitive substring search (std.ascii provides only startsWith/eql).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

/// True if the HTML head declares a UTF-8 charset (<meta charset=utf-8> or a
/// Content-Type meta with utf-8). Gates strict UTF-8 validation so we don't
/// false-positive on legacy (e.g. windows-1252) documents.
fn htmlDeclaresUtf8(head: []const u8) bool {
    if (!containsIgnoreCase(head, "charset")) return false;
    return containsIgnoreCase(head, "utf-8") or containsIgnoreCase(head, "utf8");
}

/// Validate HTML document.
/// Checks for DOCTYPE declaration or <html> tag, validates basic tag structure.
pub fn validateHtml(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.html, .failed_to_get, "file size");
    if (file_size < 7) return ValidationResult.invalidCode(.html, .file_too_small, "HTML");
    if (file_size > 500 * 1024 * 1024) return ValidationResult.invalidCode(.html, .file_too_large, "HTML validation");

    file.seekTo(0) catch return ValidationResult.invalid(.html, "Failed to seek");

    // Read first 8KB for header analysis
    var buf: [8192]u8 = undefined;
    const read_size = @min(file_size, buf.len);
    const bytes_read = file.read(buf[0..@intCast(read_size)]) catch
        return ValidationResult.invalidCode(.html, .failed_to_read, "file");
    if (bytes_read < 7) return ValidationResult.invalid(.html, "HTML too short");

    const data = buf[0..bytes_read];

    // If the document declares charset=utf-8, the byte stream MUST be valid UTF-8;
    // a flipped byte that breaks UTF-8 is corruption. Gated on an explicit utf-8
    // declaration to avoid false positives on legacy charsets. Validate the WHOLE
    // file (not just this 8 KB head) so corruption anywhere is caught.
    if (htmlDeclaresUtf8(data)) {
        var html_heap: ?[]u8 = null;
        defer if (html_heap) |b| heap.validateAllocator().free(b);
        if (getFileContent(file, max_text_file_size, &html_heap)) |full| {
            if (!std.unicode.utf8ValidateSlice(full)) {
                return ValidationResult.invalidCode(.html, .invalid_value, "UTF-8 encoding");
            }
        }
    }

    // Skip BOM if present
    var start: usize = 0;
    if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
        start = 3;
    }

    // Skip leading whitespace
    while (start < bytes_read and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) {
        start += 1;
    }

    if (start >= bytes_read) return ValidationResult.invalid(.html, "HTML file is empty");

    // Look for DOCTYPE or <html> or <HTML> or <?xml (XHTML)
    var has_doctype = false;
    var has_html_tag = false;

    // Case-insensitive check for <!DOCTYPE
    if (start + 9 <= bytes_read and data[start] == '<' and data[start + 1] == '!') {
        // Check for DOCTYPE (case-insensitive)
        var doctype_check: [7]u8 = undefined;
        for (0..7) |i| {
            if (start + 2 + i >= bytes_read) break;
            const c = data[start + 2 + i];
            doctype_check[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        if (start + 9 <= bytes_read and std.mem.eql(u8, &doctype_check, "doctype")) {
            has_doctype = true;
        }
    }

    // Scan for <html tag (case-insensitive)
    var i: usize = start;
    while (i + 5 < bytes_read) : (i += 1) {
        if (data[i] == '<') {
            // Check for <html
            if (i + 5 <= bytes_read) {
                var tag_lower: [4]u8 = undefined;
                for (0..4) |j| {
                    const c = data[i + 1 + j];
                    tag_lower[j] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                }
                if (std.mem.eql(u8, &tag_lower, "html") and
                    (i + 5 >= bytes_read or data[i + 5] == '>' or data[i + 5] == ' ' or data[i + 5] == '\n' or data[i + 5] == '\r' or data[i + 5] == '\t'))
                {
                    has_html_tag = true;
                    break;
                }
            }
        }
    }

    if (!has_doctype and !has_html_tag) {
        // Also accept <?xml for XHTML
        if (start + 5 <= bytes_read and std.mem.eql(u8, data[start .. start + 5], "<?xml")) {
            // Check if it contains html namespace or html tag further in
            // For XHTML, accept if it has xml declaration
            return ValidationResult.okWithDepth(.html, .structural);
        }
        // Missing DOCTYPE/html tag — could be an HTML fragment, template, or email HTML.
        // DOCTYPE is technically required by HTML5 spec for standards mode, but many
        // legitimate HTML files omit it. WARN rather than FAIL.
        return ValidationResult.okWithDepthAndWarning(.html, .structural, "No DOCTYPE or <html> tag found (may render in quirks mode)");
    }

    // Count basic open/close angle brackets to verify it's tag-based content
    var open_count: u32 = 0;
    var close_count: u32 = 0;
    for (data[start..]) |c| {
        if (c == '<') open_count += 1;
        if (c == '>') close_count += 1;
    }

    if (open_count < 2) return ValidationResult.invalid(.html, "Too few HTML tags");
    // Open and close brackets should roughly match
    if (close_count == 0) return ValidationResult.invalid(.html, "No closing angle brackets found");

    return ValidationResult.okWithDepth(.html, .structural);
}

// ============ KML Validator ============

/// Validate KML (Keyhole Markup Language) format.
/// KML is XML with <kml> root element.
pub fn validateKml(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.kml, .failed_to_seek, "to start");

    var header: [1024]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.kml, .failed_to_read, "KML header");

    if (header_read < 5) {
        return ValidationResult.invalidCode(.kml, .file_too_small, "KML");
    }

    const content = header[0..header_read];

    // Skip BOM if present
    var start: usize = 0;
    if (content.len >= 3 and std.mem.eql(u8, content[0..3], "\xEF\xBB\xBF")) {
        start = 3;
    }

    // Skip whitespace
    while (start < content.len and (content[start] == ' ' or content[start] == '\t' or
        content[start] == '\n' or content[start] == '\r'))
    {
        start += 1;
    }

    const remaining = content[start..];

    // Check for XML declaration or KML element
    if (remaining.len >= 5 and std.mem.eql(u8, remaining[0..5], "<?xml")) {
        if (std.mem.indexOf(u8, remaining, "<kml") != null) {
            return ValidationResult.ok(.kml);
        }
        return ValidationResult.invalid(.kml, "XML file but no <kml> element");
    }

    if (remaining.len >= 4 and std.mem.eql(u8, remaining[0..4], "<kml")) {
        return ValidationResult.ok(.kml);
    }

    return ValidationResult.invalid(.kml, "Not a valid KML file");
}

/// Deep validation for KML files using full XML parsing.
pub fn validateKmlDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCode(.kml, .failed_to_get, "file size");
    };

    if (file_size > 50 * 1024 * 1024) { // 50MB limit
        return ValidationResult.okWithDepth(.kml, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.kml, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = source.readAll(data) catch {
        return ValidationResult.invalidCode(.kml, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.kml, .incomplete, "file read");
    }

    // Import XML parser
    const xml = @import("xml");

    // Strip DOCTYPE declarations
    const preprocessed = stripDoctypeDeclaration(allocator, data);
    defer if (preprocessed.allocated) allocator.free(preprocessed.data);

    // Parse the XML
    var static_reader: xml.Reader.Static = .init(allocator, preprocessed.data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    var element_count: usize = 0;
    var found_kml = false;

    while (true) {
        const node = reader.read() catch {
            return ValidationResult.invalidCode(.kml, .invalid_value, "XML structure");
        };
        if (node == .eof) break;

        if (node == .element_start) {
            const name = reader.elementName();
            if (std.mem.eql(u8, name, "kml")) {
                found_kml = true;
            }
        }
        element_count += 1;
    }

    if (element_count == 0) {
        return ValidationResult.invalidCode(.kml, .empty, "XML document");
    }

    if (!found_kml) {
        return ValidationResult.invalid(.kml, "No <kml> element found");
    }

    return ValidationResult.okWithDepth(.kml, .structural);
}

/// Validate KMZ (compressed KML) format.
/// KMZ is a ZIP archive containing doc.kml.
pub fn validateKmz(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.kmz, .failed_to_seek, "to start");

    var header: [4]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.kmz, .failed_to_read, "KMZ header");

    if (header_read < 4) {
        return ValidationResult.invalidCode(.kmz, .file_too_small, "KMZ");
    }

    // KMZ is a ZIP file
    if (!std.mem.eql(u8, header[0..4], "PK\x03\x04")) {
        return ValidationResult.invalid(.kmz, "Not a valid ZIP/KMZ file");
    }

    // For now, accept any ZIP as potentially valid KMZ
    // Full validation would require extracting and checking for doc.kml
    return ValidationResult.okWithDepth(.kmz, .structural);
}

pub fn validateKmzDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const zip_result = archive_validators.validateZipDeep(allocator, source);
    var coerced = zip_result;
    coerced.format = .kmz;
    return coerced;
}

// ============ Plain Text Validators ============

/// Detect self-extracting archive: shebang on line 1, >= 5 non-blank text lines,
/// then binary data running to EOF. Returns true if the pattern matches.
/// "Text byte" = 0x09 (tab), 0x0A (LF), 0x0D (CR), or 0x20..0x7E (printable ASCII).
fn detectSelfExtractingArchive(file: *FileSource) bool {
    file.seekTo(0) catch return false;

    // Read enough to cover any reasonable script prefix (64KB)
    var buf: [64 * 1024]u8 = undefined;
    const n = file.read(&buf) catch return false;
    if (n < 4) return false; // Too small for "#!" + newline + anything
    const data = buf[0..n];

    // 1. First line must be a shebang
    if (data[0] != '#' or data[1] != '!') return false;

    // Find end of first line
    const first_nl = std.mem.indexOfScalar(u8, data, '\n') orelse return false;

    // Verify shebang references a shell interpreter
    const shebang_line = data[0..first_nl];
    const is_shell = std.mem.indexOf(u8, shebang_line, "/bin/sh") != null or
        std.mem.indexOf(u8, shebang_line, "/bin/bash") != null or
        std.mem.indexOf(u8, shebang_line, "/bin/zsh") != null or
        std.mem.indexOf(u8, shebang_line, "/bin/dash") != null or
        std.mem.indexOf(u8, shebang_line, "env sh") != null or
        std.mem.indexOf(u8, shebang_line, "env bash") != null or
        std.mem.indexOf(u8, shebang_line, "env zsh") != null or
        std.mem.indexOf(u8, shebang_line, "env dash") != null;
    if (!is_shell) return false;

    // 2. Scan forward for first non-text byte
    var first_binary: ?usize = null;
    for (data, 0..) |b, i| {
        if (!isTextByte(b)) {
            first_binary = i;
            break;
        }
    }

    // No binary data found in first 64KB — might still be a self-extractor
    // with a very long script prefix, but we need binary data to confirm
    if (first_binary == null) {
        // Check if the file is larger than what we read (binary beyond 64KB)
        const file_size = file.getEndPos() catch return false;
        if (file_size <= n) return false; // Entire file is text — not a self-extractor
        // Binary data exists beyond our buffer. The script prefix is all text
        // and >= 64KB. Count lines in what we have.
        var non_blank_lines: usize = 0;
        var line_start: usize = 0;
        for (data, 0..) |b, i| {
            if (b == '\n') {
                const line = data[line_start..i];
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0) non_blank_lines += 1;
                line_start = i + 1;
            }
        }
        return non_blank_lines >= 5;
    }

    const binary_pos = first_binary.?;

    // 3. Walk backwards to preceding newline — that's the seam
    var seam: usize = binary_pos;
    while (seam > 0 and data[seam - 1] != '\n') {
        seam -= 1;
    }
    // seam is now the start of the line containing the first binary byte
    // The script prefix is data[0..seam]

    if (seam == 0) return false; // Binary on first line — not a script

    // 4. Count non-blank lines in script prefix
    var non_blank_lines: usize = 0;
    var line_start: usize = 0;
    for (data[0..seam], 0..) |b, i| {
        if (b == '\n') {
            const line = data[line_start..i];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) non_blank_lines += 1;
            line_start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (line_start < seam) {
        const line = data[line_start..seam];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) non_blank_lines += 1;
    }

    return non_blank_lines >= 5;
}

/// Returns true for bytes that are valid in a text/shell script context.
fn isTextByte(b: u8) bool {
    return switch (b) {
        0x09, 0x0A, 0x0D => true, // tab, LF, CR
        0x20...0x7E => true, // printable ASCII
        else => false,
    };
}

/// Validate plain text file as UTF-8 using streaming validation.
/// Reads file in chunks and validates UTF-8 encoding throughout.
// ============ G-code Validator ============

/// Validate G-code file (3D printer / CNC) by parsing every line.
/// Every non-blank, non-comment line must be a valid G/M/T/N command with
/// valid parameters (single letter + number). Full depth when all lines parse.
pub fn validateGcode(file: *FileSource) ValidationResult {
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.gcode, .failed_to_stat, "file");
    };
    if (file_sz == 0) return ValidationResult.invalidCode(.gcode, .empty, "G-code file");
    if (file_sz > max_text_file_size) return ValidationResult.invalid(.gcode, "G-code file too large (>1GB)");

    file.seekTo(0) catch return ValidationResult.invalidCode(.gcode, .failed_to_seek, "in G-code file");

    var line_buf: [4096]u8 = undefined;
    var line_count: u64 = 0;
    var command_count: u64 = 0;
    var carry: usize = 0;

    while (true) {
        const n = file.read(line_buf[carry..]) catch break;
        if (n == 0 and carry == 0) break;
        const filled = carry + n;
        var start: usize = 0;

        while (std.mem.indexOfScalar(u8, line_buf[start..filled], '\n')) |nl_pos| {
            const line_end = start + nl_pos;
            const line = std.mem.trim(u8, line_buf[start..line_end], " \t\r");
            start = line_end + 1;

            if (line.len == 0) continue;
            if (line[0] == ';') continue; // comment line
            // Also handle % (program start/end delimiter in RS-274)
            if (line[0] == '%') continue;

            line_count += 1;

            // Strip inline comment
            const cmd_end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const cmd = std.mem.trimEnd(u8, line[0..cmd_end], " \t");
            if (cmd.len == 0) continue;

            // Valid command starts with G, M, T, N, O, or a parameter letter
            // (some slicers emit bare parameters like "E0" for reset)
            const first = cmd[0];
            if (!isGcodeCommandStart(first)) {
                return ValidationResult.invalid(.gcode, "Invalid G-code command");
            }

            // Validate the rest: alternating letter + number groups
            if (!validateGcodeLine(cmd)) {
                return ValidationResult.invalid(.gcode, "Invalid G-code syntax");
            }
            command_count += 1;
        }

        // Carry leftover (partial line) to front of buffer
        if (start < filled) {
            const leftover = filled - start;
            if (leftover >= line_buf.len) {
                // Line too long — treat as structural (can't fully validate)
                return ValidationResult.okWithDepth(.gcode, .structural);
            }
            std.mem.copyBackwards(u8, line_buf[0..leftover], line_buf[start..filled]);
            carry = leftover;
        } else {
            carry = 0;
        }

        if (n == 0) break;
    }

    // Handle last line without newline
    if (carry > 0) {
        const line = std.mem.trim(u8, line_buf[0..carry], " \t\r");
        if (line.len > 0 and line[0] != ';' and line[0] != '%') {
            const cmd_end = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
            const cmd = std.mem.trimEnd(u8, line[0..cmd_end], " \t");
            if (cmd.len > 0) {
                if (!isGcodeCommandStart(cmd[0]) or !validateGcodeLine(cmd)) {
                    return ValidationResult.invalid(.gcode, "Invalid G-code syntax");
                }
                command_count += 1;
            }
        }
    }

    if (line_count == 0 and command_count == 0) {
        // File is all comments — structural only (no commands to validate)
        return ValidationResult.okWithDepth(.gcode, .structural);
    }

    return ValidationResult.okWithDepth(.gcode, .full);
}

/// Check if a character can start a G-code command word.
fn isGcodeCommandStart(c: u8) bool {
    return switch (c) {
        'G', 'g', 'M', 'm', 'T', 't', 'N', 'n', 'O', 'o',
        // Parameter letters that can appear as bare commands (e.g., "E0", "F1800")
        'X', 'x', 'Y', 'y', 'Z', 'z', 'E', 'e', 'F', 'f',
        'S', 's', 'P', 'p', 'R', 'r', 'I', 'i', 'J', 'j',
        'K', 'k', 'D', 'd', 'H', 'h', 'L', 'l', 'Q', 'q',
        'A', 'a', 'B', 'b', 'C', 'c',
        => true,
        else => false,
    };
}

/// Validate a G-code line (after stripping comments).
/// Expected pattern: letter + optional number, repeated with spaces.
/// Examples: "G0 X10 Y20 F3600", "M104 S200", "G28", "T0"
fn validateGcodeLine(cmd: []const u8) bool {
    var i: usize = 0;
    while (i < cmd.len) {
        // Skip spaces
        while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) : (i += 1) {}
        if (i >= cmd.len) break;

        const c = cmd[i];
        // Must start with a letter
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'))) return false;
        i += 1;

        // Optional number: sign, digits, decimal point
        if (i < cmd.len and (cmd[i] == '-' or cmd[i] == '+')) i += 1;
        while (i < cmd.len and cmd[i] >= '0' and cmd[i] <= '9') : (i += 1) {}
        if (i < cmd.len and cmd[i] == '.') {
            i += 1;
            while (i < cmd.len and cmd[i] >= '0' and cmd[i] <= '9') : (i += 1) {}
        }
        // A letter without a following number is OK for some commands (G28, M107)
    }
    return true;
}

/// This allows validating arbitrarily large text files without loading them entirely into memory.
/// If file has UTF-16 BOM, delegates to UTF-16 validation.
/// If UTF-8 validation fails but content looks like text, falls back to Latin-1.
pub fn validatePlainText(allocator: ?Allocator, file: *FileSource) ValidationResult {
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.plain_text, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        // Empty file is valid UTF-8 (vacuously true)
        return ValidationResult.okWithDepth(.plain_text, .structural);
    }

    file.seekTo(0) catch {
        return ValidationResult.invalid(.plain_text, "Failed to seek");
    };

    // Use a reasonable chunk size for streaming validation
    const chunk_size: usize = 64 * 1024; // 64KB chunks
    var buffer: [chunk_size + 4]u8 = undefined; // Extra 4 bytes for pending sequences

    // Track incomplete multi-byte UTF-8 sequences at chunk boundaries
    var pending_count: usize = 0;
    var is_first_chunk = true;

    // Warning accumulation across chunks
    var file_warnings: [25]UnicodeWarning = undefined;
    var file_warning_count: u8 = 0;
    var chunk_base_offset: usize = 0;

    while (true) {
        // Read into buffer after any pending bytes
        const bytes_read = file.read(buffer[pending_count..chunk_size + pending_count]) catch {
            return ValidationResult.invalidCode(.plain_text, .failed_to_read, "file");
        };

        if (bytes_read == 0) {
            // End of file - check for incomplete sequence
            if (pending_count > 0) {
                // Check for self-extracting archive before falling back to Latin-1
                if (detectSelfExtractingArchive(file)) {
                    return ValidationResult.okWithDepthAndWarning(.plain_text, .structural, "self-extracting archive (shell script with embedded binary payload)");
                }
                // Invalid UTF-8, try Latin-1 fallback
                file.seekTo(0) catch {
                    return ValidationResult.invalidCode(.plain_text, .failed_to_seek, "for Latin-1 check");
                };
                return validatePlainTextLatin1Fallback(file);
            }
            break;
        }

        var data_start: usize = 0;
        const data_end = pending_count + bytes_read;

        // Handle BOMs at start of file
        if (is_first_chunk) {
            is_first_chunk = false;
            // Check for UTF-16 LE BOM (0xFF 0xFE) - common on Windows
            if (data_end >= 2 and buffer[0] == 0xFF and buffer[1] == 0xFE) {
                // This is UTF-16 LE, not UTF-8 - delegate to UTF-16 validator
                file.seekTo(0) catch {
                    return ValidationResult.invalid(.plain_text_utf16, "Failed to seek");
                };
                return validatePlainTextUtf16(allocator, file);
            }
            // Check for UTF-16 BE BOM (0xFE 0xFF)
            if (data_end >= 2 and buffer[0] == 0xFE and buffer[1] == 0xFF) {
                // This is UTF-16 BE, not UTF-8 - delegate to UTF-16 validator
                file.seekTo(0) catch {
                    return ValidationResult.invalid(.plain_text_utf16, "Failed to seek");
                };
                return validatePlainTextUtf16(allocator, file);
            }
            // Check for UTF-8 BOM (0xEF 0xBB 0xBF)
            if (data_end >= 3 and buffer[0] == 0xEF and buffer[1] == 0xBB and buffer[2] == 0xBF) {
                data_start = 3;
            }
        }

        // Find where complete UTF-8 sequences end
        // We need to handle the case where a multi-byte sequence spans chunk boundaries
        var validate_end = data_end;

        // Check last few bytes for incomplete sequences
        if (validate_end > data_start) {
            var i = validate_end;
            while (i > data_start and i > validate_end - 4) {
                i -= 1;
                const b = buffer[i];
                if (b < 0x80) {
                    // ASCII byte - everything before this is complete
                    break;
                } else if ((b & 0xC0) != 0x80) {
                    // Start of multi-byte sequence
                    const seq_len = utf8SequenceLength(b);
                    const remaining = validate_end - i;
                    if (remaining < seq_len) {
                        // Incomplete sequence - don't validate past this point
                        validate_end = i;
                    }
                    break;
                }
                // Continuation byte - keep going back
            }
        }

        // Validate complete sequences
        if (validate_end > data_start) {
            const utf8_result = validateUtf8(buffer[data_start..validate_end]);
            if (!utf8_result.isValid()) {
                // Check for self-extracting archive before falling back to Latin-1
                if (detectSelfExtractingArchive(file)) {
                    return ValidationResult.okWithDepthAndWarning(.plain_text, .structural, "self-extracting archive (shell script with embedded binary payload)");
                }
                // Invalid UTF-8, try Latin-1 fallback
                file.seekTo(0) catch {
                    return ValidationResult.invalidCode(.plain_text, .failed_to_seek, "for Latin-1 check");
                };
                return validatePlainTextLatin1Fallback(file);
            }
            // Accumulate warnings with adjusted byte offsets
            const adj_offset = chunk_base_offset + data_start;
            var wi: u3 = 0;
            while (wi < utf8_result.warning_count) : (wi += 1) {
                if (file_warning_count >= 5) break;
                file_warnings[file_warning_count] = .{
                    .kind = utf8_result.warnings[wi].kind,
                    .byte_offset = utf8_result.warnings[wi].byte_offset + adj_offset,
                };
                file_warning_count += 1;
            }
        }

        // Move any incomplete sequence to start of buffer for next iteration
        pending_count = data_end - validate_end;
        if (pending_count > 0) {
            // Use a temp buffer to avoid overlap issues
            var temp: [4]u8 = undefined;
            @memcpy(temp[0..pending_count], buffer[validate_end..data_end]);
            @memcpy(buffer[0..pending_count], temp[0..pending_count]);
        }

        chunk_base_offset += bytes_read;
    }

    if (file_warning_count > 0) {
        if (allocator) |alloc| {
            if (formatUnicodeWarnings(alloc, file_warnings[0..file_warning_count])) |warning_str| {
                return ValidationResult.okWithDepthAndWarning(.plain_text, .structural, warning_str);
            }
        }
    }

    return ValidationResult.okWithDepth(.plain_text, .structural);
}

/// Detect non-UTF-8 text encoding using uchardet (Mozilla's universal
/// charset detector via uchardetz). Called as a fallback when UTF-8
/// validation has already failed. Returns OK if uchardet identifies a
/// known charset (Latin-1, Windows-125x, Big5, Shift-JIS, GB18030, etc.)
/// — we know the file IS text, just not UTF-8. Returns invalid if
/// uchardet can't identify the encoding (likely binary content).
///
/// Replaces the previous heuristic that counted control bytes; uchardet's
/// statistical model is much more accurate, especially for non-Latin
/// scripts.
pub fn validatePlainTextLatin1Fallback(file: *FileSource) ValidationResult {
	const chunk_size: usize = 64 * 1024;
	var buffer: [chunk_size]u8 = undefined;

	const detector = uchardet_c.uchardet_new();
	if (detector == null) {
		return ValidationResult.invalidCode(.plain_text, .failed_to_allocate, "uchardet detector");
	}
	defer uchardet_c.uchardet_delete(detector);

	var total_bytes: usize = 0;
	var has_null: bool = false;

	while (true) {
		const bytes_read = file.read(&buffer) catch {
			return ValidationResult.invalidCode(.plain_text, .failed_to_read, "file for charset detection");
		};
		if (bytes_read == 0) break;
		total_bytes += bytes_read;

		// Embedded NULs are a strong binary signal (uchardet may still
		// identify a charset, but pragmatically a "text" file with NULs
		// is almost certainly UTF-16 mistakenly tagged as 8-bit, or
		// genuinely binary). UTF-16 has its own validator path.
		for (buffer[0..bytes_read]) |b| {
			if (b == 0x00) has_null = true;
		}
		if (has_null) {
			return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
		}

		const rc = uchardet_c.uchardet_handle_data(detector, buffer[0..bytes_read].ptr, bytes_read);
		if (rc != 0) {
			return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
		}
	}

	uchardet_c.uchardet_data_end(detector);
	const charset_ptr = uchardet_c.uchardet_get_charset(detector);
	if (charset_ptr == null) {
		return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
	}
	const charset = std.mem.span(@as([*:0]const u8, charset_ptr));

	// Empty string = uchardet couldn't identify → probably binary.
	if (charset.len == 0) {
		return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
	}

	// ASCII-only files end up here only if they have high bytes that
	// failed UTF-8 conformance — so any uchardet hit is by definition
	// non-UTF-8 text. Surface as plain_text_latin1 for the structural
	// "this is text in some encoding" verdict, and WARN: the content is NOT
	// valid UTF-8, so we fell back to a permissive single-byte decode. This
	// surfaces the corruption signal (a flipped byte that breaks UTF-8) instead
	// of silently passing — the human decides if Latin-1 was intended. The warn
	// is unconditional (not date-gated): mtime is non-deterministic, spoofable,
	// and often absent (stdin/embedded), and would only hide real corruption.
	return ValidationResult.okWithDepthAndWarning(.plain_text_latin1, .structural, "not valid UTF-8; fell back to Latin-1/single-byte decode (search for: \"fell back to Latin-1\")");
}

/// Validate plain text file as UTF-16 using streaming validation.
/// Supports both UTF-16 LE (0xFF 0xFE BOM) and UTF-16 BE (0xFE 0xFF BOM).
pub fn validatePlainTextUtf16(allocator: ?Allocator, file: *FileSource) ValidationResult {
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.plain_text_utf16, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        return ValidationResult.okWithDepth(.plain_text_utf16, .structural);
    }

    // UTF-16 files should have even number of bytes (after BOM)
    if (file_sz < 2) {
        return ValidationResult.invalidCode(.plain_text_utf16, .file_too_small, "UTF-16");
    }

    file.seekTo(0) catch {
        return ValidationResult.invalid(.plain_text_utf16, "Failed to seek");
    };

    // Read BOM to determine endianness
    var bom: [2]u8 = undefined;
    const bom_read = file.read(&bom) catch {
        return ValidationResult.invalidCode(.plain_text_utf16, .failed_to_read, "BOM");
    };

    if (bom_read < 2) {
        return ValidationResult.invalidCode(.plain_text_utf16, .failed_to_read, "BOM");
    }

    const is_little_endian = (bom[0] == 0xFF and bom[1] == 0xFE);
    const is_big_endian = (bom[0] == 0xFE and bom[1] == 0xFF);

    if (!is_little_endian and !is_big_endian) {
        // No BOM - assume it was already detected as UTF-16 some other way
        // Try little-endian (more common)
        file.seekTo(0) catch {
            return ValidationResult.invalid(.plain_text_utf16, "Failed to seek");
        };
    }

    // Streaming validation of UTF-16 content
    const chunk_size: usize = 64 * 1024; // 64KB chunks (must be even)
    var buffer: [chunk_size + 2]u8 = undefined; // Extra 2 bytes for pending code unit

    var pending_byte: ?u8 = null;
    var pending_high_surrogate: ?u16 = null;

    // Warning accumulation
    var file_warnings: [25]UnicodeWarning = undefined;
    var file_warning_count: u8 = 0;
    var byte_offset: usize = if (is_little_endian or is_big_endian) @as(usize, 2) else @as(usize, 0);

    while (true) {
        const read_start: usize = if (pending_byte != null) 1 else 0;
        if (pending_byte) |b| {
            buffer[0] = b;
        }

        const bytes_read = file.read(buffer[read_start..chunk_size + read_start]) catch {
            return ValidationResult.invalidCode(.plain_text_utf16, .failed_to_read, "file");
        };

        if (bytes_read == 0) {
            // End of file
            if (pending_byte != null) {
                return ValidationResult.invalidCode(.plain_text_utf16, .invalid_value, "UTF-16 (odd byte count)");
            }
            if (pending_high_surrogate != null) {
                return ValidationResult.invalidCode(.plain_text_utf16, .invalid_value, "UTF-16 (unpaired high surrogate at EOF)");
            }
            break;
        }

        const data_end = read_start + bytes_read;

        // Handle odd byte at end of chunk
        const validate_end = if (data_end % 2 == 1) blk: {
            pending_byte = buffer[data_end - 1];
            break :blk data_end - 1;
        } else blk: {
            pending_byte = null;
            break :blk data_end;
        };

        // Validate UTF-16 code units
        var i: usize = 0;
        while (i + 1 < validate_end) {
            const code_unit: u16 = if (is_big_endian)
                (@as(u16, buffer[i]) << 8) | buffer[i + 1]
            else
                (@as(u16, buffer[i + 1]) << 8) | buffer[i];

            if (pending_high_surrogate) |high| {
                // Expecting low surrogate (0xDC00-0xDFFF)
                if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
                    // Valid surrogate pair -- decode full codepoint for warning check
                    const codepoint: u21 = (@as(u21, high - 0xD800) << 10) + @as(u21, code_unit - 0xDC00) + 0x10000;
                    pending_high_surrogate = null;
                    if (file_warning_count < 25 and isNoncharacter(codepoint)) {
                        file_warnings[file_warning_count] = .{ .kind = .noncharacter, .byte_offset = byte_offset - 2 };
                        file_warning_count += 1;
                    }
                } else {
                    return ValidationResult.invalidCode(.plain_text_utf16, .invalid_value, "UTF-16 (missing low surrogate)");
                }
            } else if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
                // High surrogate - expect low surrogate next
                pending_high_surrogate = code_unit;
            } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
                // Unexpected low surrogate
                return ValidationResult.invalidCode(.plain_text_utf16, .invalid_value, "UTF-16 (unexpected low surrogate)");
            } else {
                // BMP codepoint -- check for suspicious characters
                const codepoint: u21 = @as(u21, code_unit);
                if (file_warning_count < 25) {
                    if (isNoncharacter(codepoint)) {
                        file_warnings[file_warning_count] = .{ .kind = .noncharacter, .byte_offset = byte_offset };
                        file_warning_count += 1;
                    } else if (isBidiOverride(codepoint)) {
                        file_warnings[file_warning_count] = .{ .kind = .bidi_override, .byte_offset = byte_offset };
                        file_warning_count += 1;
                    } else if (isZeroWidth(codepoint)) {
                        file_warnings[file_warning_count] = .{ .kind = .zero_width, .byte_offset = byte_offset };
                        file_warning_count += 1;
                    } else if (codepoint == 0xFEFF and byte_offset > 2) {
                        // Misplaced BOM (not at file start; offset > 2 means past the BOM)
                        file_warnings[file_warning_count] = .{ .kind = .misplaced_bom, .byte_offset = byte_offset };
                        file_warning_count += 1;
                    }
                }
            }

            byte_offset += 2;
            i += 2;
        }
    }

    if (file_warning_count > 0) {
        if (allocator) |alloc| {
            if (formatUnicodeWarnings(alloc, file_warnings[0..file_warning_count])) |warning_str| {
                return ValidationResult.okWithDepthAndWarning(.plain_text_utf16, .structural, warning_str);
            }
        }
    }

    return ValidationResult.okWithDepth(.plain_text_utf16, .structural);
}

/// Get the expected length of a UTF-8 sequence from its first byte.
pub fn utf8SequenceLength(first_byte: u8) u8 {
    if (first_byte < 0x80) return 1;
    if ((first_byte & 0xE0) == 0xC0) return 2;
    if ((first_byte & 0xF0) == 0xE0) return 3;
    if ((first_byte & 0xF8) == 0xF0) return 4;
    return 1; // Invalid, but return 1 to avoid infinite loops
}

// ============ Tests ============

const testing = std.testing;
const ValidationDepth = format_validation.ValidationDepth;

// ---------- UTF-8 validator unit tests ----------

test "validateUtf8 accepts valid ASCII" {
    const result = validateUtf8("Hello, world!");
    try testing.expect(result.isValid());
    try testing.expect(!result.hasWarnings());
}

test "validateUtf8 accepts valid multi-byte sequences" {
    // 2-byte: e-acute (U+00E9)
    const r2 = validateUtf8("\xC3\xA9");
    try testing.expect(r2.isValid());
    // 3-byte: euro sign (U+20AC)
    const r3 = validateUtf8("\xE2\x82\xAC");
    try testing.expect(r3.isValid());
    // 4-byte: Gothic letter hwair (U+10348)
    const r4 = validateUtf8("\xF0\x90\x8D\x88");
    try testing.expect(r4.isValid());
}

test "validateUtf8 rejects invalid continuation byte" {
    const result = validateUtf8("\xC3\x00");
    try testing.expect(!result.isValid());
    try testing.expectEqual(@as(?usize, 1), result.error_offset);
}

test "validateUtf8 rejects truncated sequence" {
    const result = validateUtf8("\xE2\x82");
    try testing.expect(!result.isValid());
}

test "validateUtf8 rejects overlong encoding" {
    const result = validateUtf8("\xC0\xAF");
    try testing.expect(!result.isValid());
    try testing.expectEqual(@as(?usize, 0), result.error_offset);
}

test "validateUtf8 rejects surrogate codepoints" {
    const result = validateUtf8("\xED\xA0\x80");
    try testing.expect(!result.isValid());
}

test "validateUtf8 detects noncharacter warnings" {
    // U+FFFE: 0xEF 0xBF 0xBE
    const result = validateUtf8("\xEF\xBF\xBE");
    try testing.expect(result.isValid());
    try testing.expect(result.hasWarnings());
    try testing.expectEqual(@as(u8, 1), result.warning_count);
    try testing.expectEqual(UnicodeWarningKind.noncharacter, result.warnings[0].kind);
}

test "validateUtf8 detects bidi override warnings" {
    // U+202E RIGHT-TO-LEFT OVERRIDE: 0xE2 0x80 0xAE
    const result = validateUtf8("abc\xE2\x80\xAEdef");
    try testing.expect(result.isValid());
    try testing.expect(result.hasWarnings());
    try testing.expectEqual(UnicodeWarningKind.bidi_override, result.warnings[0].kind);
    try testing.expectEqual(@as(usize, 3), result.warnings[0].byte_offset);
}

test "validateUtf8 detects zero-width char warnings" {
    // U+200B ZERO WIDTH SPACE: 0xE2 0x80 0x8B
    const result = validateUtf8("a\xE2\x80\x8Bb");
    try testing.expect(result.isValid());
    try testing.expect(result.hasWarnings());
    try testing.expectEqual(UnicodeWarningKind.zero_width, result.warnings[0].kind);
}

test "validateUtf8 detects misplaced BOM warning" {
    // BOM (U+FEFF) at non-zero position
    const result = validateUtf8("x\xEF\xBB\xBF");
    try testing.expect(result.isValid());
    try testing.expect(result.hasWarnings());
    try testing.expectEqual(UnicodeWarningKind.misplaced_bom, result.warnings[0].kind);
}

test "validateUtf8 BOM at position 0 does not warn" {
    const result = validateUtf8("\xEF\xBB\xBF" ++ "hello");
    try testing.expect(result.isValid());
    try testing.expect(!result.hasWarnings());
}

test "validateUtf8 caps warnings at 25" {
    // 26 noncharacters: U+FDD0..U+FDE9
    const data = "\xEF\xB7\x90" ++ "\xEF\xB7\x91" ++ "\xEF\xB7\x92" ++ "\xEF\xB7\x93" ++ "\xEF\xB7\x94" ++
        "\xEF\xB7\x95" ++ "\xEF\xB7\x96" ++ "\xEF\xB7\x97" ++ "\xEF\xB7\x98" ++ "\xEF\xB7\x99" ++
        "\xEF\xB7\x9A" ++ "\xEF\xB7\x9B" ++ "\xEF\xB7\x9C" ++ "\xEF\xB7\x9D" ++ "\xEF\xB7\x9E" ++
        "\xEF\xB7\x9F" ++ "\xEF\xB7\xA0" ++ "\xEF\xB7\xA1" ++ "\xEF\xB7\xA2" ++ "\xEF\xB7\xA3" ++
        "\xEF\xB7\xA4" ++ "\xEF\xB7\xA5" ++ "\xEF\xB7\xA6" ++ "\xEF\xB7\xA7" ++ "\xEF\xB7\xA8" ++
        "\xEF\xB7\xA9"; // 26th
    const result = validateUtf8(data);
    try testing.expect(result.isValid());
    try testing.expectEqual(@as(u8, 25), result.warning_count);
}

test "validateUtf8 reports 16 zero-width chars" {
    // 16 zero-width spaces (U+200B) — like the jailbreaks.txt pattern
    const data = "prefix" ++ "\xE2\x80\x8B" ** 16 ++ "suffix";
    const result = validateUtf8(data);
    try testing.expect(result.isValid());
    try testing.expectEqual(@as(u8, 16), result.warning_count);
    // All should be zero_width kind
    for (result.warnings[0..16]) |w| {
        try testing.expectEqual(UnicodeWarningKind.zero_width, w.kind);
    }
}

// ---------- UTF-16 validator unit tests ----------

test "validateUtf16Le accepts valid BMP text" {
    const data = [_]u8{ 0x48, 0x00, 0x69, 0x00 };
    try testing.expectEqual(@as(?usize, null), validateUtf16Le(&data));
}

test "validateUtf16Le accepts valid surrogate pair" {
    // U+10000: high=0xD800, low=0xDC00
    const data = [_]u8{ 0x00, 0xD8, 0x00, 0xDC };
    try testing.expectEqual(@as(?usize, null), validateUtf16Le(&data));
}

test "validateUtf16Le rejects orphan high surrogate" {
    const data = [_]u8{ 0x00, 0xD8, 0x41, 0x00 };
    try testing.expectEqual(@as(?usize, 2), validateUtf16Le(&data));
}

test "validateUtf16Le rejects orphan low surrogate" {
    const data = [_]u8{ 0x00, 0xDC };
    try testing.expectEqual(@as(?usize, 0), validateUtf16Le(&data));
}

test "validateUtf16Le rejects odd length" {
    const data = [_]u8{ 0x48, 0x00, 0x69 };
    try testing.expect(validateUtf16Le(&data) != null);
}

test "validateUtf16Be accepts valid BMP text" {
    const data = [_]u8{ 0x00, 0x48, 0x00, 0x69 };
    try testing.expectEqual(@as(?usize, null), validateUtf16Be(&data));
}

test "validateUtf16Be rejects orphan low surrogate" {
    const data = [_]u8{ 0xDC, 0x00 };
    try testing.expectEqual(@as(?usize, 0), validateUtf16Be(&data));
}

// ---------- formatUnicodeWarnings unit tests ----------

test "formatUnicodeWarnings returns null for empty slice" {
    const result = formatUnicodeWarnings(testing.allocator, &[_]UnicodeWarning{});
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "formatUnicodeWarnings formats single warning group" {
    const warnings = [_]UnicodeWarning{
        .{ .kind = .noncharacter, .byte_offset = 100 },
    };
    const result = formatUnicodeWarnings(testing.allocator, &warnings) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[noncharacters @ 100]", result);
}

test "formatUnicodeWarnings formats multiple groups" {
    const warnings = [_]UnicodeWarning{
        .{ .kind = .noncharacter, .byte_offset = 10 },
        .{ .kind = .bidi_override, .byte_offset = 20 },
    };
    const result = formatUnicodeWarnings(testing.allocator, &warnings) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("[noncharacters @ 10; bidi overrides @ 20]", result);
}

// ---------- INI line validator unit tests ----------

test "validateIniLine classifies empty line" {
    try testing.expectEqual(IniLineType.empty, validateIniLine(""));
    try testing.expectEqual(IniLineType.empty, validateIniLine("   \t  "));
}

test "validateIniLine classifies comment" {
    try testing.expectEqual(IniLineType.comment, validateIniLine("; this is a comment"));
    try testing.expectEqual(IniLineType.comment, validateIniLine("# hash comment"));
    try testing.expectEqual(IniLineType.comment, validateIniLine("  ; indented comment"));
}

test "validateIniLine classifies section header" {
    try testing.expectEqual(IniLineType.section, validateIniLine("[section]"));
    try testing.expectEqual(IniLineType.section, validateIniLine("[my.section]"));
    try testing.expectEqual(IniLineType.section, validateIniLine("  [indented]  "));
}

test "validateIniLine rejects invalid sections" {
    try testing.expectEqual(IniLineType.invalid, validateIniLine("["));
    try testing.expectEqual(IniLineType.invalid, validateIniLine("[]"));
    try testing.expectEqual(IniLineType.invalid, validateIniLine("[section] extra"));
}

test "validateIniLine classifies key-value pair" {
    try testing.expectEqual(IniLineType.key_value, validateIniLine("key=value"));
    try testing.expectEqual(IniLineType.key_value, validateIniLine("key: value"));
    try testing.expectEqual(IniLineType.key_value, validateIniLine("some.dotted.key=val"));
}

test "validateIniLine handles Unreal Engine prefixes" {
    try testing.expectEqual(IniLineType.key_value, validateIniLine("+Key=Value"));
    try testing.expectEqual(IniLineType.key_value, validateIniLine("-Key=Value"));
    try testing.expectEqual(IniLineType.key_value, validateIniLine("!Key=Value"));
}

// ---------- INI content validator unit tests ----------

test "validateIniContent validates well-formed INI" {
    const result = validateIniContent("[section]\nkey=value\n");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ini, result.format);
}

test "validateIniContent rejects structureless content" {
    const result = validateIniContent("; only comments\n# nothing else\n");
    try testing.expectEqual(FileFormat.unknown, result.format);
}

// ---------- CSV delimiter detection ----------

test "detectCsvDelimiter detects comma" {
    try testing.expectEqual(@as(u8, ','), detectCsvDelimiter("name,age,city\n"));
}

test "detectCsvDelimiter detects tab" {
    try testing.expectEqual(@as(u8, '\t'), detectCsvDelimiter("name\tage\tcity\n"));
}

test "detectCsvDelimiter detects semicolon" {
    try testing.expectEqual(@as(u8, ';'), detectCsvDelimiter("name;age;city\n"));
}

test "detectCsvDelimiter detects pipe" {
    try testing.expectEqual(@as(u8, '|'), detectCsvDelimiter("name|age|city\n"));
}

// ---------- containsTemplateMarkers ----------

test "containsTemplateMarkers detects EEx/ERB" {
    try testing.expect(containsTemplateMarkers("<%= @name %>"));
}

test "containsTemplateMarkers detects Handlebars" {
    try testing.expect(containsTemplateMarkers("Hello {{name}}"));
}

test "containsTemplateMarkers detects Jinja2 blocks" {
    try testing.expect(containsTemplateMarkers("{% if x %}ok{% endif %}"));
}

test "containsTemplateMarkers detects PHP" {
    try testing.expect(containsTemplateMarkers("<?php echo $x; ?>"));
}

test "containsTemplateMarkers returns false for plain text" {
    try testing.expect(!containsTemplateMarkers("just plain text"));
}

// ---------- JSON comment stripping ----------

test "stripJsonComments strips line comments" {
    const input = "{\n// comment\n\"key\": 1\n}";
    const stripped = stripJsonComments(testing.allocator, input) orelse
        return error.TestUnexpectedResult;
    defer stripped.deinit(testing.allocator);
    try testing.expect(tryParseJson(testing.allocator, stripped.data));
}

test "stripJsonComments strips block comments" {
    const input = "{\n/* block\ncomment */\n\"key\": 1\n}";
    const stripped = stripJsonComments(testing.allocator, input) orelse
        return error.TestUnexpectedResult;
    defer stripped.deinit(testing.allocator);
    try testing.expect(tryParseJson(testing.allocator, stripped.data));
}

test "stripJsonComments returns null when no comments present" {
    const result = stripJsonComments(testing.allocator, "{\"key\": 1}");
    try testing.expectEqual(@as(?StrippedJson, null), result);
}

// ---------- tryParseJson ----------

test "tryParseJson accepts valid JSON" {
    try testing.expect(tryParseJson(testing.allocator, "{\"a\":1}"));
    try testing.expect(tryParseJson(testing.allocator, "[1,2,3]"));
    try testing.expect(tryParseJson(testing.allocator, "\"hello\""));
}

test "tryParseJson rejects invalid JSON" {
    try testing.expect(!tryParseJson(testing.allocator, "{bad}"));
    try testing.expect(!tryParseJson(testing.allocator, ""));
    try testing.expect(!tryParseJson(testing.allocator, "{\"a\": }"));
}

// ---------- tryParseJson5 ----------

test "tryParseJson5 accepts JSON5 features" {
    try testing.expect(tryParseJson5("{unquoted: 'value'}"));
    try testing.expect(tryParseJson5("{a: 1,}"));
}

test "tryParseJson5 rejects garbage" {
    try testing.expect(!tryParseJson5("not json at all ~~~"));
}

// ---------- validateJsonLines ----------

test "validateJsonLines accepts valid NDJSON" {
    const result = validateJsonLines(testing.allocator, "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.json, result.format);
}

test "validateJsonLines rejects mixed invalid lines" {
    const result = validateJsonLines(testing.allocator, "{\"a\":1}\n{bad}\n");
    try testing.expect(!result.is_valid);
}

// ---------- looksLikeUtf16LeWithoutBom ----------

test "looksLikeUtf16LeWithoutBom detects UTF-16 LE pattern" {
    const data = [_]u8{
        0x5B, 0x00, 0x73, 0x00, 0x65, 0x00, 0x63, 0x00,
        0x74, 0x00, 0x69, 0x00, 0x6F, 0x00, 0x6E, 0x00,
    };
    try testing.expect(looksLikeUtf16LeWithoutBom(&data));
}

test "looksLikeUtf16LeWithoutBom rejects ASCII" {
    try testing.expect(!looksLikeUtf16LeWithoutBom("Hello, world!"));
}

// ---------- utf8SequenceLength ----------

test "utf8SequenceLength returns correct lengths" {
    try testing.expectEqual(@as(u8, 1), utf8SequenceLength(0x41));
    try testing.expectEqual(@as(u8, 2), utf8SequenceLength(0xC3));
    try testing.expectEqual(@as(u8, 3), utf8SequenceLength(0xE2));
    try testing.expectEqual(@as(u8, 4), utf8SequenceLength(0xF0));
    try testing.expectEqual(@as(u8, 1), utf8SequenceLength(0x80));
}

// ---------- decodeUtf8Codepoint ----------

test "decodeUtf8Codepoint decodes correctly" {
    try testing.expectEqual(@as(?u21, 0x41), decodeUtf8Codepoint("A"));
    try testing.expectEqual(@as(?u21, 0xE9), decodeUtf8Codepoint("\xC3\xA9"));
    try testing.expectEqual(@as(?u21, 0x20AC), decodeUtf8Codepoint("\xE2\x82\xAC"));
    try testing.expectEqual(@as(?u21, null), decodeUtf8Codepoint(""));
}

// ---------- isNoncharacter / isBidiOverride / isZeroWidth ----------

test "isNoncharacter identifies noncharacters" {
    try testing.expect(isNoncharacter(0xFDD0));
    try testing.expect(isNoncharacter(0xFDEF));
    try testing.expect(isNoncharacter(0xFFFE));
    try testing.expect(isNoncharacter(0xFFFF));
    try testing.expect(isNoncharacter(0x1FFFE));
    try testing.expect(!isNoncharacter(0x41));
    try testing.expect(!isNoncharacter(0xFDCF));
}

test "isBidiOverride identifies bidi overrides" {
    try testing.expect(isBidiOverride(0x202A));
    try testing.expect(isBidiOverride(0x202E));
    try testing.expect(isBidiOverride(0x2066));
    try testing.expect(isBidiOverride(0x2069));
    try testing.expect(!isBidiOverride(0x41));
}

test "isZeroWidth identifies zero-width chars" {
    try testing.expect(isZeroWidth(0x200B));
    try testing.expect(isZeroWidth(0x200C));
    try testing.expect(isZeroWidth(0x200D));
    try testing.expect(isZeroWidth(0x2060));
    try testing.expect(!isZeroWidth(0x41));
}

// ---------- File-based validator tests using ground truth ----------

test "validateJson accepts valid ground truth JSON file" {
    var source = FileSource.open("ground_truth_examples/json/sample.json") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateJson(&source, null);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.json, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateJson rejects truncated JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.json", .{});
    try f.writePositionalAll(runtime.io(), "{\"key\": ", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.json");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateJson(&source, null);
    try testing.expect(!result.is_valid);
}

test "validateJson rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "empty.json", .{});
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "empty.json");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateJson(&source, null);
    try testing.expect(!result.is_valid);
}

test "validateToml accepts valid ground truth TOML file" {
    var source = FileSource.open("ground_truth_examples/toml/sample.toml") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateToml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.toml, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateToml rejects truncated TOML" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.toml", .{});
    try f.writePositionalAll(runtime.io(), "[section\nkey = ", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.toml");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateToml(&source);
    try testing.expect(!result.is_valid);
}

test "validateToml rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "empty.toml", .{});
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "empty.toml");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateToml(&source);
    try testing.expect(!result.is_valid);
}

test "validateIni accepts valid ground truth INI file" {
    var source = FileSource.open("ground_truth_examples/ini/sample.ini") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateIni(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.ini, result.format);
}

test "validateIni rejects file with invalid syntax" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.ini", .{});
    try f.writePositionalAll(runtime.io(), "[section]\n<<<invalid>>>\n", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.ini");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateIni(&source);
    try testing.expect(!result.is_valid);
}

test "validateXml accepts valid ground truth XML file" {
    var source = FileSource.open("ground_truth_examples/xml/sample.xml") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xml, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateXml rejects malformed XML" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.xml", .{});
    try f.writePositionalAll(runtime.io(), "<?xml version=\"1.0\"?>\n<root><unclosed>\n", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.xml");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(!result.is_valid);
}

test "validateXml rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "empty.xml", .{});
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "empty.xml");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(!result.is_valid);
}

// XML 1.1 path: real-input regression for Apple .keylayout files
// Apples keyboard layout XML uses numeric refs &#x0001;..&#x001F; to map
// keystrokes to control-character outputs (Ctrl-A..Ctrl-_). XML 1.0 §2.2
// forbids these refs; XML 1.1 §2.2 allows them.
test "validateXml accepts XML 1.1 .keylayout with control-char refs" {
    var source = FileSource.open("tests/fixtures/sample.keylayout") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.xml, result.format);
}

test "validateXml accepts XML 1.1 declaration with control-char refs" {
    const xml_content = "<?xml version=\"1.1\" encoding=\"UTF-8\"?><r>&#x0001;&#x001F;</r>";
    var source = FileSource.fromBuffer(xml_content);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(result.is_valid);
}

test "validateXml accepts undeclared 1.0 doc with control-char refs (with WARN)" {
    const xml_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>&#x0001;</r>";
    var source = FileSource.fromBuffer(xml_content);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message != null);
}

test "validateXml rejects NUL character reference even under 1.1" {
    const xml_content = "<?xml version=\"1.1\"?><r>&#x0000;</r>";
    var source = FileSource.fromBuffer(xml_content);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(!result.is_valid);
}

test "validateXml accepts &#x007F; under 1.1 declaration" {
    const xml_content = "<?xml version=\"1.1\"?><r>&#x007F;</r>";
    var source = FileSource.fromBuffer(xml_content);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(result.is_valid);
}

test "validateCsv accepts valid ground truth CSV file" {
    var source = FileSource.open("ground_truth_examples/csv/sample.csv") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateCsv(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.csv, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateCsv rejects unclosed quoted field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.csv", .{});
    try f.writePositionalAll(runtime.io(), "name,desc\nAlice,\"unclosed\n", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.csv");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateCsv(&source);
    try testing.expect(!result.is_valid);
}

test "validateRtf accepts valid ground truth RTF file" {
    var source = FileSource.open("ground_truth_examples/rtf/sample.rtf") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateRtf(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rtf, result.format);
}

test "validateRtf rejects missing signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.rtf", .{});
    try f.writePositionalAll(runtime.io(), "not an rtf file at all", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.rtf");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateRtf(&source);
    try testing.expect(!result.is_valid);
}

test "validateRtf rejects missing closing brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "noclosing.rtf", .{});
    try f.writePositionalAll(runtime.io(), "{\\rtf1\\ansi no closing brace here ", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "noclosing.rtf");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateRtf(&source);
    try testing.expect(!result.is_valid);
}

test "validateRtfDeep accepts valid ground truth RTF file" {
    const path_buf = testing.allocator.dupe(u8, "ground_truth_examples/rtf/sample.rtf") catch return;
    defer testing.allocator.free(path_buf);
    var source = FileSource.open(path_buf) catch return;
    defer source.close();
    const result = validateRtfDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rtf, result.format);
}

test "validateRtfDeep detects unmatched closing brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "extrabrace.rtf", .{});
    try f.writePositionalAll(runtime.io(), "{\\rtf1\\ansi Hello}}", 0);
    f.close(runtime.io());
    const path_buf = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "extrabrace.rtf") catch return;
    defer testing.allocator.free(path_buf);
    var source = FileSource.open(path_buf) catch return;
    defer source.close();
    const result = validateRtfDeep(testing.allocator, &source);
    try testing.expect(!result.is_valid);
}

test "validateRtfDeep detects unclosed brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "unclosed.rtf", .{});
    try f.writePositionalAll(runtime.io(), "{\\rtf1\\ansi {nested text", 0);
    f.close(runtime.io());
    const path_buf = runtime.tmpRealpathAlloc(&tmp, testing.allocator, "unclosed.rtf") catch return;
    defer testing.allocator.free(path_buf);
    var source2 = FileSource.open(path_buf) catch return;
    defer source2.close();
    const result = validateRtfDeep(testing.allocator, &source2);
    try testing.expect(!result.is_valid);
}

test "validateHtml accepts valid ground truth HTML file" {
    var source = FileSource.open("ground_truth_examples/html/simple.html") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateHtml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.html, result.format);
}

test "validateHtml warns (not fails) for file without DOCTYPE or html tag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.html", .{});
    try f.writePositionalAll(runtime.io(), "<div>Just a div, no html or doctype</div>", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.html");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateHtml(&source);
    // Should be valid with a warning, not invalid
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message != null);
}

test "validateHtml rejects tiny file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "tiny.html", .{});
    try f.writePositionalAll(runtime.io(), "hi", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "tiny.html");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateHtml(&source);
    try testing.expect(!result.is_valid);
}

test "validateKml accepts valid ground truth KML file" {
    var source = FileSource.open("ground_truth_examples/kml/sample.kml") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateKml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.kml, result.format);
}

test "validateKml rejects file without kml element" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.kml", .{});
    try f.writePositionalAll(runtime.io(), "<?xml version=\"1.0\"?>\n<notKml>test</notKml>\n", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.kml");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateKml(&source);
    try testing.expect(!result.is_valid);
}

test "validateKmlDeep accepts valid ground truth KML file" {
    const path_buf = testing.allocator.dupe(u8, "ground_truth_examples/kml/sample.kml") catch return;
    defer testing.allocator.free(path_buf);
    var source = FileSource.open(path_buf) catch return;
    defer source.close();
    const result = validateKmlDeep(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.kml, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateKmz accepts valid ground truth KMZ file" {
    var source = FileSource.open("ground_truth_examples/kmz/sample.kmz") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateKmz(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.kmz, result.format);
}

test "validateKmz rejects non-ZIP file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "bad.kmz", .{});
    try f.writePositionalAll(runtime.io(), "not a zip file", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.kmz");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateKmz(&source);
    try testing.expect(!result.is_valid);
}

test "validatePlainText accepts valid UTF-8 ground truth file" {
    var source = FileSource.open("ground_truth_examples/plain_text/utf8/sample.txt") catch return;
    defer source.close();
    const result = validatePlainText(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.plain_text, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validatePlainText accepts UTF-16 LE file with BOM" {
    var source2 = FileSource.open("ground_truth_examples/plain_text/utf16/sample.txt") catch return;
    defer source2.close();
    const result = validatePlainText(testing.allocator, &source2);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.plain_text_utf16, result.format);
}

test "validatePlainText falls back to Latin-1 for non-UTF-8 text" {
    var source = FileSource.open("ground_truth_examples/plain_text/latin1/sample.txt") catch return;
    defer source.close();
    const result = validatePlainText(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.plain_text_latin1, result.format);
}

test "validatePlainText accepts empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "empty.txt", .{});
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "empty.txt");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validatePlainText(null, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.plain_text, result.format);
}

test "validatePlainTextUtf16 accepts valid UTF-16 LE file" {
    var source = FileSource.open("ground_truth_examples/plain_text/utf16/sample.txt") catch return;
    defer source.close();
    const result = validatePlainTextUtf16(testing.allocator, &source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.plain_text_utf16, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validatePlainTextUtf16 rejects odd byte count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(runtime.io(), "odd.txt", .{});
    // UTF-16 LE BOM + 3 bytes (odd after BOM)
    try f.writePositionalAll(runtime.io(), "\xFF\xFE\x41\x00\x42", 0);
    f.close(runtime.io());
    const real_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "odd.txt");
    defer std.testing.allocator.free(real_path);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validatePlainTextUtf16(null, &source);
    try testing.expect(!result.is_valid);
}

test "validateJson accepts JSON5 ground truth file with warning" {
    var source = FileSource.open("ground_truth_examples/json5/sample.json5") catch return;
    defer source.close();
    const result = validateJson(&source, null);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.json, result.format);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "detectFormat RTF" {
    const rtf_header = "{\\rtf1";
    try std.testing.expectEqual(FileFormat.rtf, detectFormat(rtf_header));
}

test "FormatValidator accepts valid RTF" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Simple valid RTF document
    const valid_rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}Hello World}";

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid.rtf", .{});
    try file.writePositionalAll(runtime.io(), valid_rtf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid.rtf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.rtf, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid RTF failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects RTF missing closing brace" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // RTF missing closing brace
    const invalid_rtf = "{\\rtf1\\ansi\\deff0 Hello World";

    const file = try tmp_dir.dir.createFile(runtime.io(), "invalid.rtf", .{});
    try file.writePositionalAll(runtime.io(), invalid_rtf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "invalid.rtf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.rtf, result.format);
    try std.testing.expect(!result.is_valid);
}

test "UTF-8 fallback validates plain text file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create plain ASCII text file (no format signature)
    const text_content = "Hello, world!\nThis is a plain text file.\nNo special format signature.";

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.txt", .{});
    try file.writePositionalAll(runtime.io(), text_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.txt");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should be detected as plain_text — UTF-8 validated but no CRC/hash
    try std.testing.expectEqual(FileFormat.plain_text, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "UTF-8 fallback validates UTF-8 with BOM" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create UTF-8 file with BOM
    const bom = [_]u8{ 0xEF, 0xBB, 0xBF };
    const text = "UTF-8 text with BOM: \xC3\xA9\xC3\xA0\xC3\xBC"; // é, à, ü

    const file = try tmp_dir.dir.createFile(runtime.io(), "test_bom.txt", .{});
    try file.writePositionalAll(runtime.io(), &bom, 0);
    try file.writePositionalAll(runtime.io(), text, bom.len);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test_bom.txt");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.plain_text, result.format);
    try std.testing.expect(result.is_valid);
    // UTF-8 parse but no CRC/hash integrity mechanism
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "UTF-8 fallback does not validate binary file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create binary file with lots of null bytes and control characters
    var binary_data: [100]u8 = undefined;
    for (&binary_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 32); // Mix of control characters and nulls
    }

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.bin", .{});
    try file.writePositionalAll(runtime.io(), &binary_data, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.bin");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should be unknown with no validation depth (binary content)
    try std.testing.expectEqual(FileFormat.unknown, result.format);
    try std.testing.expect(result.is_valid);
    // Binary files don't get structural validation
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "UTF-8 fallback validates multi-byte UTF-8" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create file with multi-byte UTF-8 sequences (no format signature)
    const utf8_content = "日本語テキスト\n中文文本\n한국어 텍스트\nΕλληνικά\n";

    const file = try tmp_dir.dir.createFile(runtime.io(), "test_multibyte.txt", .{});
    try file.writePositionalAll(runtime.io(), utf8_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test_multibyte.txt");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.plain_text, result.format);
    try std.testing.expect(result.is_valid);
    // UTF-8 parse but no CRC/hash integrity mechanism
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "CP437 detection for demoscene NFO files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Classic demoscene/warez NFO ASCII art using CP437 box-drawing characters
    // These bytes are: ██▓▓░░ followed by newline and more box chars
    // 0xDB = █ (full block), 0xB2 = ▓ (dark shade), 0xB0 = ░ (light shade)
    // 0xC4 = ─ (horizontal line), 0xB3 = │ (vertical line)
    const cp437_content = [_]u8{
        0xDB, 0xDB, 0xB2, 0xB2, 0xB0, 0xB0, 0x20, 'H', 'E', 'L', 'L', 'O', 0x20, 0xB0, 0xB0, 0xB2, 0xB2, 0xDB, 0xDB, 0x0D, 0x0A, // ██▓▓░░ HELLO ░░▓▓██\r\n
        0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0x0D, 0x0A, // ───────────────────\r\n
        0xB3, 0x20, 'D', 'E', 'M', 'O', 'S', 'C', 'E', 'N', 'E', 0x20, 'N', 'F', 'O', 0x20, 0x20, 0xB3, 0x0D, 0x0A, // │ DEMOSCENE NFO  │\r\n
        0xC0, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xC4, 0xD9, 0x0D, 0x0A, // └─────────────────┘\r\n
    };

    const file = try tmp_dir.dir.createFile(runtime.io(), "release.nfo", .{});
    try file.writePositionalAll(runtime.io(), &cp437_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "release.nfo");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should be detected as CP437 text (demoscene NFO)
    try std.testing.expectEqual(FileFormat.plain_text_cp437, result.format);
    try std.testing.expect(result.is_valid);
    // CP437 has no integrity mechanism — any byte is valid
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FormatValidator accepts valid JSON" {
    const allocator = std.testing.allocator;

    // Create a temp file with valid JSON
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const json_content =
        \\{
        \\  "name": "test",
        \\  "value": 42,
        \\  "items": [1, 2, 3],
        \\  "nested": {"a": true, "b": null}
        \\}
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.json", .{});
    try file.writePositionalAll(runtime.io(), json_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(result.is_valid);
    // Complete JSON parse validates every token — that's full depth
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator rejects invalid JSON" {
    const allocator = std.testing.allocator;

    // Create a temp file with invalid JSON
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const json_content =
        \\{
        \\  "name": "test",
        \\  "value": 42,
        \\  "missing_closing_brace"
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.json", .{});
    try file.writePositionalAll(runtime.io(), json_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(!result.is_valid);
}

test "Log files with timestamps not misidentified as JSON" {
    const allocator = std.testing.allocator;

    // Log files often start with [timestamp] which could look like JSON array with number
    // Example: [23:24:10][game_tag][source.cpp:59]: message
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const log_content =
        \\[23:24:10][no_game_date][equipment_graphic_database.cpp:59]: Entity referenced in equipment graphic database does not exist
        \\[23:24:15][no_game_date][triggerimplementation.cpp:9557]: common/scripted_effects/BLT_scripted_effects.txt:77: has_game_rule
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "game.log", .{});
    try file.writePositionalAll(runtime.io(), log_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "game.log");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should NOT be detected as JSON (should be unknown since .log extension maps to unknown)
    try std.testing.expect(result.format != FileFormat.json);
}

test "FormatValidator accepts JSONC with line comments" {
    const allocator = std.testing.allocator;

    // JSONC (JSON with Comments) - used by MAME, VS Code, TypeScript configs, etc.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const jsonc_content =
        \\// license:BSD-3-Clause
        \\// copyright-holders:Ryan Holtz
        \\{
        \\  "name": "test",
        \\  // This is a comment
        \\  "value": 42
        \\}
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.json", .{});
    try file.writePositionalAll(runtime.io(), jsonc_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(result.is_valid);
    // Should have a warning about comments
    try std.testing.expect(result.warning_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.warning_message.?, "comment") != null);
}

test "FormatValidator accepts JSONC with block comments" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const jsonc_content =
        \\/* This is a block comment
        \\   that spans multiple lines */
        \\{
        \\  "name": "test",
        \\  "items": [1, /* inline comment */ 2, 3]
        \\}
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.json", .{});
    try file.writePositionalAll(runtime.io(), jsonc_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(result.is_valid);
    // Should have a warning about comments
    try std.testing.expect(result.warning_message != null);
}

test "FormatValidator does not strip comments inside JSON strings" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Comments inside strings should NOT be stripped - this is valid JSON
    const json_content =
        \\{
        \\  "url": "http://example.com/path",
        \\  "comment": "This // is not a comment",
        \\  "block": "Neither /* is */ this"
        \\}
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.json", .{});
    try file.writePositionalAll(runtime.io(), json_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(result.is_valid);
    // Should NOT have a warning - this is valid standard JSON
    try std.testing.expect(result.warning_message == null);
}

test "FormatValidator accepts valid TOML" {
    const allocator = std.testing.allocator;

    // Create a temp file with valid TOML
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const toml_content =
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[database]
        \\name = "mydb"
        \\enabled = true
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.toml", .{});
    try file.writePositionalAll(runtime.io(), toml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.toml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.toml, result.format);
    try std.testing.expect(result.is_valid);
    // TOML parsing but no CRC/hash integrity mechanism
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FormatValidator rejects invalid TOML" {
    const allocator = std.testing.allocator;

    // Create a temp file with invalid TOML
    // Uses valid [section] header but invalid value syntax
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const toml_content =
        \\[server]
        \\host = invalid unquoted string
        \\port = 8080
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.toml", .{});
    try file.writePositionalAll(runtime.io(), toml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.toml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.toml, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts valid XML" {
    const allocator = std.testing.allocator;

    // Create a temp file with valid XML
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>
        \\  <item id="1">First</item>
        \\  <item id="2">Second</item>
        \\  <empty/>
        \\</root>
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.xml", .{});
    try file.writePositionalAll(runtime.io(), xml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.xml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.xml, result.format);
    try std.testing.expect(result.is_valid);
    // XML parsing but no CRC/hash integrity mechanism
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FormatValidator rejects invalid XML with mismatched tags" {
    const allocator = std.testing.allocator;

    // Create a temp file with invalid XML
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const xml_content =
        \\<root>
        \\  <item>Content</wrong>
        \\</root>
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.xml", .{});
    try file.writePositionalAll(runtime.io(), xml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.xml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.xml, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator rejects XML with unclosed tags" {
    const allocator = std.testing.allocator;

    // Create a temp file with XML that has unclosed tags
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const xml_content =
        \\<root>
        \\  <item>Content
        \\</root>
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.xml", .{});
    try file.writePositionalAll(runtime.io(), xml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.xml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.xml, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator accepts XML with undefined entity when DOCTYPE was stripped" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const xml_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE root [
        \\  <!ENTITY demo "ok">
        \\]>
        \\<root>&demo;</root>
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.xml", .{});
    try file.writePositionalAll(runtime.io(), xml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.xml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.xml, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.malformations.contains(.xml_undefined_entity));
    try std.testing.expect(result.warning_message != null);
}

test "zig-xml accepts simple XML" {
    const xml_content = "<root><child>text</child></root>";
    try std.testing.expect(format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml accepts XML with declaration" {
    const xml_content = "<?xml version=\"1.0\"?><root><child/></root>";
    try std.testing.expect(format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml accepts XML with CDATA" {
    const xml_content = "<root><![CDATA[<not a tag>]]></root>";
    try std.testing.expect(format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml accepts XML with comments" {
    const xml_content = "<root><!-- comment --><child/></root>";
    try std.testing.expect(format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml rejects mismatched tags" {
    const xml_content = "<root><child></wrong></root>";
    try std.testing.expect(!format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml rejects unclosed tags" {
    const xml_content = "<root><child>";
    try std.testing.expect(!format_validation.isXmlWellFormed(xml_content));
}

test "zig-xml accepts > in quoted attribute values" {
    // This is the bug we fixed - > inside attribute values should be allowed
    const xml_content = "<info name=\"usage\" value=\">Load\" />";
    try std.testing.expect(format_validation.isXmlWellFormed(xml_content));
}

test "FormatValidator accepts valid KML" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const kml_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<kml xmlns="http://www.opengis.net/kml/2.2">
        \\  <Document>
        \\    <name>Test KML</name>
        \\    <Placemark>
        \\      <name>Point</name>
        \\      <Point>
        \\        <coordinates>-122.0822035425683,37.42228990140251,0</coordinates>
        \\      </Point>
        \\    </Placemark>
        \\  </Document>
        \\</kml>
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "test.kml", .{});
    try file.writePositionalAll(runtime.io(), kml_content, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "test.kml");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.kml, result.format);
    try std.testing.expect(result.is_valid);
}

test "UTF-16 LE INI detection" {
    // UTF-16 LE BOM + "[section]\r\nkey=value\r\n"
    const utf16_ini = [_]u8{
        0xFF, 0xFE, // BOM
        '[',  0x00,
        's',  0x00,
        'e',  0x00,
        'c',  0x00,
        't',  0x00,
        'i',  0x00,
        'o',  0x00,
        'n',  0x00,
        ']',  0x00,
        0x0D, 0x00, 0x0A, 0x00, // \r\n
        'k',  0x00, 'e',  0x00,
        'y',  0x00, '=',  0x00,
        'v',  0x00, 'a',  0x00,
        'l',  0x00, 'u',  0x00,
        'e',  0x00,
        0x0D, 0x00, 0x0A, 0x00, // \r\n
    };

    const format = format_validation.detectTextFormat(&utf16_ini);
    // INI is no longer detected by content alone (too many false positives).
    // UTF-16 INI content without .ini extension should detect as plain_text_utf16 or null.
    if (format) |f| {
        try std.testing.expect(f != .ini); // Must NOT falsely classify as INI
    }
}

test "validatePlainText: self-extracting shell script returns WARN, not FAIL" {
    // Synthetic self-extracting archive: shebang + 6 non-blank script lines + binary payload
    const script_prefix =
        "#!/bin/bash\n" ++
        "# Self-extracting installer\n" ++
        "ARCHIVE_OFFSET=$(awk '/^__ARCHIVE__/{print NR + 1; exit 0;}' \"$0\")\n" ++
        "TMPDIR=$(mktemp -d)\n" ++
        "tail -n +$ARCHIVE_OFFSET \"$0\" | tar xz -C \"$TMPDIR\"\n" ++
        "\"$TMPDIR/install.sh\"\n" ++
        "exit 0\n" ++
        "__ARCHIVE__\n";
    // Binary payload: gzip magic + random binary data (NOT valid UTF-8)
    const binary_payload = [_]u8{
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, // gzip header
        0x02, 0x03, 0xED, 0x93, 0x4F, 0x6F, 0xD3, 0x40, // binary data
        0x10, 0xC5, 0xEF, 0x48, 0xFC, 0x87, 0xD1, 0x9E, // more binary
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x80, // high bytes
        0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, // control chars
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write the synthetic self-extractor
    const file = try tmp.dir.createFile(runtime.io(), "installer.sh", .{});
    try file.writePositionalAll(runtime.io(), script_prefix, 0);
    try file.writePositionalAll(runtime.io(), &binary_payload, script_prefix.len);
    file.close(runtime.io());

    // Open and validate as plain text
    const opened = try tmp.dir.openFile(runtime.io(), "installer.sh", .{});
    defer opened.close(runtime.io());
    var source = FileSource.fromFile(opened);
    const result = validatePlainText(std.testing.allocator, &source);

    // Should be valid (is_valid = true) with a warning about self-extracting archive
    try std.testing.expect(result.is_valid);
    try std.testing.expect(result.warning_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.warning_message.?, "self-extracting") != null);
}

test "validatePlainText: script with <5 non-blank lines + binary is NOT self-extractor" {
    // Only 3 non-blank lines before binary — too short to be a real self-extractor
    const script_prefix =
        "#!/bin/sh\n" ++
        "echo hello\n" ++
        "\n" ++
        "exit 0\n";
    const binary_payload = [_]u8{ 0x80, 0x81, 0x82, 0xFF, 0xFE, 0xFD, 0x00, 0x01 };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(runtime.io(), "short.sh", .{});
    try file.writePositionalAll(runtime.io(), script_prefix, 0);
    try file.writePositionalAll(runtime.io(), &binary_payload, script_prefix.len);
    file.close(runtime.io());

    const opened = try tmp.dir.openFile(runtime.io(), "short.sh", .{});
    defer opened.close(runtime.io());
    var source = FileSource.fromFile(opened);
    const result = validatePlainText(std.testing.allocator, &source);

    // Should NOT be detected as self-extractor (too few lines)
    // It will fail as invalid plain text or fall through to Latin-1
    try std.testing.expect(!result.is_valid or result.warning_message == null or
        std.mem.indexOf(u8, result.warning_message.?, "self-extracting") == null);
}

test "validatePlainText: file without shebang + binary is NOT self-extractor" {
    // No shebang — just text then binary
    const text_prefix =
        "This is just a text file\n" ++
        "with some lines\n" ++
        "nothing special\n" ++
        "no shebang here\n" ++
        "just plain text\n" ++
        "and more text\n";
    const binary_payload = [_]u8{ 0x80, 0x81, 0x82, 0xFF, 0xFE, 0xFD, 0x00, 0x01 };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(runtime.io(), "notscript.txt", .{});
    try file.writePositionalAll(runtime.io(), text_prefix, 0);
    try file.writePositionalAll(runtime.io(), &binary_payload, text_prefix.len);
    file.close(runtime.io());

    const opened = try tmp.dir.openFile(runtime.io(), "notscript.txt", .{});
    defer opened.close(runtime.io());
    var source = FileSource.fromFile(opened);
    const result = validatePlainText(std.testing.allocator, &source);

    // Should NOT be self-extractor (no shebang)
    try std.testing.expect(!result.is_valid or result.warning_message == null or
        std.mem.indexOf(u8, result.warning_message.?, "self-extracting") == null);
}

// ============================================================
// JSON variant extension tests (JSON5, JSONC, NDJSON)
// ============================================================

test "validateJson with ext_hint 'json5' suppresses JSON5 warning" {
    // JSON5 content that would normally trigger a warning
    const json5_content = "{unquoted: 'value', trailing: 1,}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "test.json5", .data = json5_content }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "test.json5") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateJson(&source, "json5");
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.json, result.format);
    // Key assertion: no warning when extension matches JSON5
    try testing.expect(result.warning_message == null);
}

test "validateJson with ext_hint 'json' still warns about JSON5 features" {
    const json5_content = "{unquoted: 'value', trailing: 1,}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "test.json", .data = json5_content }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "test.json") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateJson(&source, "json");
    try testing.expect(result.is_valid);
    // Key assertion: warning IS present for .json extension with JSON5 content
    try testing.expect(result.warning_message != null);
}

// ============================================================
// G-code validator tests
// ============================================================

test "validateGcode accepts valid G-code" {
    const gcode =
        \\;FLAVOR:UltiGCode
        \\;TIME:1234
        \\;Generated with Cura_SteamEngine 4.2.1
        \\M82 ;absolute extrusion mode
        \\G92 E0
        \\G0 F3600 X23.5 Y99.0 Z0.27
        \\G1 F1800 X24.0 Y98.9 E0.05
        \\M106 S255
        \\M107
        \\G28
        \\M84
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "test.gcode", .data = gcode }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "test.gcode") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateGcode(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.gcode, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "validateGcode rejects file with invalid command" {
    const gcode =
        \\;FLAVOR:UltiGCode
        \\G0 X10 Y20
        \\INVALID_COMMAND
        \\G1 X30 Y40
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "bad.gcode", .data = gcode }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "bad.gcode") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateGcode(&source);
    try testing.expect(!result.is_valid);
}

test "validateGcode accepts comment-only file" {
    const gcode =
        \\; This is a comment
        \\; Another comment
        \\;SETTING_3 {"key": "value"}
    ;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "comments.gcode", .data = gcode }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "comments.gcode") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateGcode(&source);
    try testing.expect(result.is_valid);
}

test "validateGcode rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "empty.gcode", .data = "" }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "empty.gcode") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateGcode(&source);
    try testing.expect(!result.is_valid);
}
test "validateJson with ext_hint 'jsonc' suppresses JSONC warning" {
    const jsonc_content = "// comment\n{\"key\": \"value\"}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "test.jsonc", .data = jsonc_content }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "test.jsonc") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateJson(&source, "jsonc");
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message == null);
}

test "validateJson with null ext_hint still warns about JSON5" {
    const json5_content = "{unquoted: 'value', trailing: 1,}";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(runtime.io(), .{ .sub_path = "test.json", .data = json5_content }) catch return;
    const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "test.json") catch return;
    defer std.testing.allocator.free(rp);
    var source = FileSource.open(rp) catch return;
    defer source.close();
    const result = validateJson(&source, null);
    try testing.expect(result.is_valid);
    try testing.expect(result.warning_message != null);
}

// ── UTF-8 integrity: declared/required-UTF-8 formats must reject invalid UTF-8 ──
// A lone 0x80 is an invalid UTF-8 sequence (continuation byte with no lead). The
// formats below are UTF-8 by spec (JSON RFC 8259, CSV, TOML) or by declaration
// (XML default; HTML with charset=utf-8). They must NOT silently accept a byte
// that breaks UTF-8 — that is exactly the corruption EML/MBOX already catch.
// (Raised by Peter 2026-06-22: text formats showing ~0% corruption detection.)

test "JSON rejects invalid UTF-8 in a string value" {
    var s = FileSource.fromBuffer("{\"k\":\"v\x80w\"}");
    const r = validateJson(&s, null);
    try testing.expect(!r.is_valid);
}

test "CSV rejects invalid UTF-8 in a field" {
    var s = FileSource.fromBuffer("name,age\nbob,\x80\n");
    const r = validateCsv(&s);
    try testing.expect(!r.is_valid);
}

test "TOML rejects invalid UTF-8 in a string value" {
    var s = FileSource.fromBuffer("title = \"hi\x80\"\n");
    const r = validateToml(&s);
    try testing.expect(!r.is_valid);
}

test "XML rejects invalid UTF-8 in text content" {
    var s = FileSource.fromBuffer("<?xml version=\"1.0\"?><r>a\x80b</r>");
    const r = validateXml(&s);
    try testing.expect(!r.is_valid);
}

test "HTML (charset=utf-8) rejects invalid UTF-8 in body" {
    var s = FileSource.fromBuffer("<!doctype html><meta charset=\"utf-8\"><p>a\x80b</p>");
    const r = validateHtml(&s);
    try testing.expect(!r.is_valid);
}
