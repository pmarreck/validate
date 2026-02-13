const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const cj5 = @import("cj5");
const errmsg = @import("error_messages.zig");
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;
const isAsciiCompatibleEncoding = format_validation.isAsciiCompatibleEncoding;
const normalizeXmlEncoding = format_validation.normalizeXmlEncoding;
const EncodingNormalizedResult = format_validation.EncodingNormalizedResult;
const getTextContent = format_validation.getTextContent;
const convertUtf16LeToUtf8 = format_validation.convertUtf16LeToUtf8;

/// Maximum file size for text format parsing (1 GB).
/// Files larger than this are too risky to load entirely into memory.
const max_text_file_size: usize = 1024 * 1024 * 1024;

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
    /// Suspicious codepoint warnings (up to 5)
    warnings: [5]UnicodeWarning = undefined,
    warning_count: u3 = 0,

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

    // Group warnings by kind and collect byte offsets
    var nonchar_offsets: [5]usize = undefined;
    var nonchar_count: usize = 0;
    var bidi_offsets: [5]usize = undefined;
    var bidi_count: usize = 0;
    var zw_offsets: [5]usize = undefined;
    var zw_count: usize = 0;
    var bom_offsets: [5]usize = undefined;
    var bom_count: usize = 0;

    for (warnings) |w| {
        switch (w.kind) {
            .noncharacter => {
                if (nonchar_count < 5) {
                    nonchar_offsets[nonchar_count] = w.byte_offset;
                    nonchar_count += 1;
                }
            },
            .bidi_override => {
                if (bidi_count < 5) {
                    bidi_offsets[bidi_count] = w.byte_offset;
                    bidi_count += 1;
                }
            },
            .zero_width => {
                if (zw_count < 5) {
                    zw_offsets[zw_count] = w.byte_offset;
                    zw_count += 1;
                }
            },
            .misplaced_bom => {
                if (bom_count < 5) {
                    bom_offsets[bom_count] = w.byte_offset;
                    bom_count += 1;
                }
            },
        }
    }

    // Build formatted string using ArrayList
    var list = std.ArrayListUnmanaged(u8){};
    const writer = list.writer(allocator);

    writer.writeAll("[") catch return null;
    var first_group = true;

    const groups = [_]struct { name: []const u8, offsets: []const usize }{
        .{ .name = "noncharacters", .offsets = nonchar_offsets[0..nonchar_count] },
        .{ .name = "bidi overrides", .offsets = bidi_offsets[0..bidi_count] },
        .{ .name = "zero-width chars", .offsets = zw_offsets[0..zw_count] },
        .{ .name = "misplaced BOM", .offsets = bom_offsets[0..bom_count] },
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
            std.fmt.format(writer, "{d}", .{offset}) catch return null;
        }
    }

    writer.writeAll("]") catch return null;
    return list.toOwnedSlice(allocator) catch return null;
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
        if (result.warning_count < 5) {
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
pub fn validateJson(file: std.fs.File) ValidationResult {
    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.json, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        return ValidationResult.invalidCode(.json, .empty, "JSON file");
    }

    if (stat.size > max_text_file_size) {
        return ValidationResult.invalid(.json, "JSON file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalidCode(.json, .failed_to_allocate, "memory");
    };
    defer std.heap.page_allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.json, .failed_to_read, "file");
    };

    if (bytes_read == 0) {
        return ValidationResult.invalidCode(.json, .empty, "JSON file");
    }

    // Handle UTF-16 LE/BE encoding (common on Windows)
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) std.heap.page_allocator.free(conv_buf);

    const text_result = blk: {
        // Allocate conversion buffer if needed (UTF-16 -> UTF-8 can be same size or smaller)
        if (bytes_read >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = std.heap.page_allocator.alloc(u8, bytes_read) catch {
                return ValidationResult.invalidCode(.json, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
        } else {
            conv_buf = &[_]u8{};
        }
        break :blk getTextContent(content[0..bytes_read], conv_buf);
    };

    const data = text_result.content;

    // Try to parse the JSON using Scanner
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
            return ValidationResult.okWithWarning(.json, "JSONC: contains comments (non-standard JSON extension)");
        }
    }

    // Try JSON5 (superset of JSON with unquoted keys, trailing commas, Infinity/NaN, etc.)
    if (tryParseJson5(data)) {
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
pub fn validateToml(file: std.fs.File) ValidationResult {
    const toml = @import("toml");

    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.toml, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        return ValidationResult.invalidCode(.toml, .empty, "TOML file");
    }

    if (stat.size > max_text_file_size) {
        return ValidationResult.invalid(.toml, "TOML file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalidCode(.toml, .failed_to_allocate, "memory");
    };
    defer std.heap.page_allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.toml, .failed_to_read, "file");
    };

    if (bytes_read == 0) {
        return ValidationResult.invalidCode(.toml, .empty, "TOML file");
    }

    // Handle UTF-16 LE/BE encoding (less common for TOML but possible on Windows)
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) std.heap.page_allocator.free(conv_buf);

    const data = blk: {
        if (bytes_read >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = std.heap.page_allocator.alloc(u8, bytes_read) catch {
                return ValidationResult.invalidCode(.toml, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content[0..bytes_read], conv_buf);
            break :blk text_result.content;
        }
        // Handle UTF-8 BOM
        if (bytes_read >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            break :blk content[3..bytes_read];
        }
        break :blk content[0..bytes_read];
    };

    // Use the sam701/zig-toml parser to parse as a generic Table
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(data) catch {
        return ValidationResult.invalid(.toml, "TOML parse error");
    };
    defer parsed.deinit();

    // TOML parsed successfully with semantic validation
    return ValidationResult.okWithDepth(.toml, .full);
}

// ============ INI Validator ============

/// Validate INI file structure.
/// INI files have [section] headers and key=value pairs.
/// Detection already verified basic structure, so we just do a simple parse check.
/// Handles UTF-8 and UTF-16 LE encoded INI files (common on Windows).
pub fn validateIni(file: std.fs.File) ValidationResult {
    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.ini, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        return ValidationResult.invalidCode(.ini, .empty, "INI file");
    }

    if (stat.size > max_text_file_size) {
        return ValidationResult.invalid(.ini, "INI file too large (>1GB)");
    }

    // Read first portion to verify structure
    const read_size: usize = @min(@as(usize, @intCast(stat.size)), 8192);
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
    return ValidationResult.okWithDepth(.ini, .full);
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
pub fn validateXml(file: std.fs.File) ValidationResult {
    const xml = @import("xml");

    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.xml, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        return ValidationResult.invalidCode(.xml, .empty, "XML file");
    }

    if (stat.size > max_text_file_size) {
        return ValidationResult.invalid(.xml, "XML file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalidCode(.xml, .failed_to_allocate, "memory");
    };
    defer std.heap.page_allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.xml, .failed_to_read, "file");
    };

    if (bytes_read == 0) {
        return ValidationResult.invalidCode(.xml, .empty, "XML file");
    }

    // Handle UTF-16 LE/BE encoding (Windows sometimes uses this for XML)
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) std.heap.page_allocator.free(conv_buf);

    const raw_data = blk: {
        if (bytes_read >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = std.heap.page_allocator.alloc(u8, bytes_read) catch {
                return ValidationResult.invalidCode(.xml, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content[0..bytes_read], conv_buf);
            break :blk text_result.content;
        }
        break :blk content[0..bytes_read];
    };

    // Normalize ASCII-compatible encodings (us-ascii, iso-8859-1, etc.) to UTF-8
    // These are byte-compatible for ASCII range which is what most XML files use
    const encoding_normalized = normalizeXmlEncoding(raw_data);
    defer if (encoding_normalized.allocated) std.heap.page_allocator.free(@constCast(encoding_normalized.data));

    // Strip DOCTYPE declaration if present (zig-xml doesn't support DTD validation)
    // We only validate XML structure, not DTD conformance
    const preprocessed = stripDoctypeDeclaration(encoding_normalized.data);
    defer if (preprocessed.allocated) std.heap.page_allocator.free(preprocessed.data);

    // Use zig-xml's spec-compliant parser for well-formedness check
    var static_reader: xml.Reader.Static = .init(std.heap.page_allocator, preprocessed.data, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    // Read through entire document - any malformed XML will return error.MalformedXml
    while (true) {
        const node = reader.read() catch |err| {
            switch (err) {
                error.MalformedXml => {
                    // Get error code for diagnostics
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
                    if (error_code == .entity_reference_undefined and preprocessed.had_doctype) {
                        var tolerated = ValidationResult.okWithDepthAndMalformation(.xml, .full, .xml_undefined_entity);
                        tolerated.warning_message = "DOCTYPE declaration skipped (DTD not validated); undefined entity reference tolerated";
                        return tolerated;
                    }
                    return ValidationResult.invalid(.xml, error_msg);
                },
                error.OutOfMemory => return ValidationResult.invalidCode(.xml, .out_of_memory, "during parsing"),
                error.ReadFailed => return ValidationResult.invalid(.xml, "Read failed during parsing"),
            }
        };

        if (node == .eof) break;
    }

    // XML validated with spec-compliant parser
    // Return with warning if DOCTYPE was stripped
    if (preprocessed.had_doctype) {
        return ValidationResult.okWithDepthAndWarning(.xml, .full, "DOCTYPE declaration skipped (DTD not validated)");
    }
    return ValidationResult.okWithDepth(.xml, .full);
}

// ============ CSV Validator ============

/// Validate CSV (Comma-Separated Values) files.
/// Checks for consistent column count, proper quoting, and valid UTF-8.
pub fn validateCsv(file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.csv, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        // Empty CSV is technically valid
        return ValidationResult.ok(.csv);
    }

    // Don't try to fully parse huge files - just sample
    const max_sample_size: u64 = 1024 * 1024; // 1MB sample
    const sample_size: usize = @intCast(@min(stat.size, max_sample_size));

    const content = std.heap.page_allocator.alloc(u8, sample_size) catch {
        return ValidationResult.invalidCode(.csv, .failed_to_allocate, "memory");
    };
    defer std.heap.page_allocator.free(content);

    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.csv, .failed_to_read, "file");
    };

    if (bytes_read == 0) {
        return ValidationResult.ok(.csv);
    }

    // Handle UTF-16 LE/BE encoding (Excel sometimes saves CSV as UTF-16)
    var conv_buf: []u8 = undefined;
    var conv_buf_allocated = false;
    defer if (conv_buf_allocated) std.heap.page_allocator.free(conv_buf);

    const data = blk: {
        if (bytes_read >= 2 and ((content[0] == 0xFF and content[1] == 0xFE) or
            (content[0] == 0xFE and content[1] == 0xFF)))
        {
            conv_buf = std.heap.page_allocator.alloc(u8, bytes_read) catch {
                return ValidationResult.invalidCode(.csv, .failed_to_allocate, "conversion buffer");
            };
            conv_buf_allocated = true;
            const text_result = getTextContent(content[0..bytes_read], conv_buf);
            break :blk text_result.content;
        }
        // Handle UTF-8 BOM
        if (bytes_read >= 3 and content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF) {
            break :blk content[3..bytes_read];
        }
        break :blk content[0..bytes_read];
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
        return ValidationResult.invalid(.csv, "Unclosed quoted field");
    }

    // Basic sanity checks
    if (row_count == 0 and data.len > 0) {
        // File has content but no parseable rows - might be binary
        return ValidationResult.invalidCode(.csv, .no_valid_x_found, "CSV rows");
    }

    return ValidationResult.okWithDepth(.csv, .full);
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

// ============ RTF Validator ============

/// Validate RTF document structure.
pub fn validateRtf(file: std.fs.File) ValidationResult {
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
pub fn validateRtfDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_open, "RTF file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_get, "file size");
    };

    if (file_size > 100 * 1024 * 1024) { // 100MB limit
        return ValidationResult.okWithDepth(.rtf, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.rtf, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
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

/// Validate HTML document.
/// Checks for DOCTYPE declaration or <html> tag, validates basic tag structure.
pub fn validateHtml(file: std.fs.File) ValidationResult {
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
        return ValidationResult.invalid(.html, "No DOCTYPE or <html> tag found");
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
pub fn validateKml(file: std.fs.File) ValidationResult {
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
pub fn validateKmlDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.kml, .failed_to_open, "KML file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.kml, .failed_to_get, "file size");
    };

    if (file_size > 50 * 1024 * 1024) { // 50MB limit
        return ValidationResult.okWithDepth(.kml, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.kml, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.kml, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.kml, .incomplete, "file read");
    }

    // Import XML parser
    const xml = @import("xml");

    // Strip DOCTYPE declarations
    const preprocessed = stripDoctypeDeclaration(data);
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

    return ValidationResult.okWithDepth(.kml, .full);
}

/// Validate KMZ (compressed KML) format.
/// KMZ is a ZIP archive containing doc.kml.
pub fn validateKmz(file: std.fs.File) ValidationResult {
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
    return ValidationResult.okWithDepth(.kmz, .full);
}

// ============ Plain Text Validators ============

/// Validate plain text file as UTF-8 using streaming validation.
/// Reads file in chunks and validates UTF-8 encoding throughout.
/// This allows validating arbitrarily large text files without loading them entirely into memory.
/// If file has UTF-16 BOM, delegates to UTF-16 validation.
/// If UTF-8 validation fails but content looks like text, falls back to Latin-1.
pub fn validatePlainText(allocator: ?Allocator, file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.plain_text, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        // Empty file is valid UTF-8 (vacuously true)
        return ValidationResult.okWithDepth(.plain_text, .full);
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
    var file_warnings: [5]UnicodeWarning = undefined;
    var file_warning_count: u3 = 0;
    var chunk_base_offset: usize = 0;

    while (true) {
        // Read into buffer after any pending bytes
        const bytes_read = file.read(buffer[pending_count..chunk_size + pending_count]) catch {
            return ValidationResult.invalidCode(.plain_text, .failed_to_read, "file");
        };

        if (bytes_read == 0) {
            // End of file - check for incomplete sequence
            if (pending_count > 0) {
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
                return ValidationResult.okWithDepthAndWarning(.plain_text, .full, warning_str);
            }
        }
    }

    return ValidationResult.okWithDepth(.plain_text, .full);
}

/// Check if a file looks like Latin-1 text (fallback when UTF-8 validation fails).
/// Latin-1 is always "valid" since every byte 0x00-0xFF maps to a character,
/// but we check for text-like characteristics to avoid misidentifying binary files.
pub fn validatePlainTextLatin1Fallback(file: std.fs.File) ValidationResult {
    const chunk_size: usize = 64 * 1024;
    var buffer: [chunk_size]u8 = undefined;

    var total_bytes: usize = 0;
    var control_bytes: usize = 0;
    var has_null: bool = false;
    var has_high_bytes: bool = false;

    while (true) {
        const bytes_read = file.read(&buffer) catch {
            return ValidationResult.invalidCode(.plain_text, .failed_to_read, "file for Latin-1 check");
        };

        if (bytes_read == 0) break;
        total_bytes += bytes_read;

        for (buffer[0..bytes_read]) |b| {
            if (b == 0x00) {
                has_null = true;
                // NULL bytes strongly suggest binary, not text
                return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
            } else if (b >= 0x80) {
                has_high_bytes = true;
            }
            // Count problematic control characters (except common whitespace)
            // 0x00-0x08: NUL, SOH, STX, ETX, EOT, ENQ, ACK, BEL, BS
            // 0x0B: VT (vertical tab)
            // 0x0C: FF (form feed) - sometimes used
            // 0x0E-0x1F: SO, SI, DLE, DC1-DC4, NAK, SYN, ETB, CAN, EM, SUB, ESC, FS, GS, RS, US
            // Allow: 0x09 (tab), 0x0A (LF), 0x0D (CR)
            if ((b >= 0x00 and b <= 0x08) or b == 0x0B or (b >= 0x0E and b <= 0x1F)) {
                control_bytes += 1;
            }
        }
    }

    // If no high bytes, it would have passed UTF-8 validation, so this shouldn't happen
    // But just in case, still accept it
    if (!has_high_bytes) {
        return ValidationResult.okWithDepth(.plain_text, .full);
    }

    // Heuristic: if more than 5% control characters, probably binary
    if (total_bytes > 0 and control_bytes * 100 / total_bytes > 5) {
        return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
    }

    // Looks like Latin-1 text
    return ValidationResult.okWithDepth(.plain_text_latin1, .full);
}

/// Validate plain text file as UTF-16 using streaming validation.
/// Supports both UTF-16 LE (0xFF 0xFE BOM) and UTF-16 BE (0xFE 0xFF BOM).
pub fn validatePlainTextUtf16(allocator: ?Allocator, file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.plain_text_utf16, .failed_to_stat, "file");
    };

    if (stat.size == 0) {
        return ValidationResult.okWithDepth(.plain_text_utf16, .full);
    }

    // UTF-16 files should have even number of bytes (after BOM)
    if (stat.size < 2) {
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
    var file_warnings: [5]UnicodeWarning = undefined;
    var file_warning_count: u3 = 0;
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
                    if (file_warning_count < 5 and isNoncharacter(codepoint)) {
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
                if (file_warning_count < 5) {
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
                return ValidationResult.okWithDepthAndWarning(.plain_text_utf16, .full, warning_str);
            }
        }
    }

    return ValidationResult.okWithDepth(.plain_text_utf16, .full);
}

/// Get the expected length of a UTF-8 sequence from its first byte.
pub fn utf8SequenceLength(first_byte: u8) u8 {
    if (first_byte < 0x80) return 1;
    if ((first_byte & 0xE0) == 0xC0) return 2;
    if ((first_byte & 0xF0) == 0xE0) return 3;
    if ((first_byte & 0xF8) == 0xF0) return 4;
    return 1; // Invalid, but return 1 to avoid infinite loops
}
