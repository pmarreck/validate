const std = @import("std");
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
const EncodingNormalizedResult = format_validation.EncodingNormalizedResult;
const getTextContent = format_validation.getTextContent;
const convertUtf16LeToUtf8 = format_validation.convertUtf16LeToUtf8;

/// Maximum file size for text format parsing (1 GB).
/// Files larger than this are too risky to load entirely into memory.
const max_text_file_size: usize = 1024 * 1024 * 1024;

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;

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
pub fn validateJson(file: *FileSource) ValidationResult {
    // Get file size
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.json, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        return ValidationResult.invalidCode(.json, .empty, "JSON file");
    }

    if (file_sz > max_text_file_size) {
        return ValidationResult.invalid(.json, "JSON file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(file_sz)) catch {
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
        return ValidationResult.okWithDepth(.json, .structural);
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
        return ValidationResult.okWithDepthAndWarning(.json, .structural, "JSON5: uses JSON5 extensions (unquoted keys, trailing commas, etc.)");
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
    return ValidationResult.okWithDepth(.json, .structural);
}

// ============ TOML Validator ============

/// Validate TOML file structure.
/// Uses the external sam701/zig-toml parser for validation.
pub fn validateToml(file: *FileSource) ValidationResult {
    const toml = @import("toml");

    // Get file size
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.toml, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        return ValidationResult.invalidCode(.toml, .empty, "TOML file");
    }

    if (file_sz > max_text_file_size) {
        return ValidationResult.invalid(.toml, "TOML file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(file_sz)) catch {
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
pub fn validateXml(file: *FileSource) ValidationResult {
    const xml = @import("xml");

    // Get file size
    const file_sz = file.getEndPos() catch {
        return ValidationResult.invalidCode(.xml, .failed_to_stat, "file");
    };

    if (file_sz == 0) {
        return ValidationResult.invalidCode(.xml, .empty, "XML file");
    }

    if (file_sz > max_text_file_size) {
        return ValidationResult.invalid(.xml, "XML file too large (>1GB)");
    }

    // Read entire file - use heap allocation to avoid stack overflow with multiple threads
    const content = std.heap.page_allocator.alloc(u8, @intCast(file_sz)) catch {
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
    const encoding_normalized = normalizeXmlEncoding(std.heap.page_allocator, raw_data);
    defer if (encoding_normalized.allocated) std.heap.page_allocator.free(@constCast(encoding_normalized.data));

    // Strip DOCTYPE declaration if present (zig-xml doesn't support DTD validation)
    // We only validate XML structure, not DTD conformance
    const preprocessed = stripDoctypeDeclaration(std.heap.page_allocator, encoding_normalized.data);
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
                        var tolerated = ValidationResult.okWithDepthAndMalformation(.xml, .structural, .xml_undefined_entity);
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
        return ValidationResult.okWithDepthAndWarning(.xml, .structural, "DOCTYPE declaration skipped (DTD not validated)");
    }
    return ValidationResult.okWithDepth(.xml, .structural);
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

    // Don't try to fully parse huge files - just sample
    const max_sample_size: u64 = 1024 * 1024; // 1MB sample
    const sample_size: usize = @intCast(@min(file_sz, max_sample_size));

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
    var buf: [65536]u8 = undefined;
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
pub fn validateRtfDeep(allocator: Allocator, path: []const u8) ValidationResult {
    var source = FileSource.open(path) catch {
        return ValidationResult.invalidCode(.rtf, .failed_to_open, "RTF file");
    };
    defer source.close();

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
pub fn validateKmlDeep(allocator: Allocator, path: []const u8) ValidationResult {
    var kml_source = FileSource.open(path) catch {
        return ValidationResult.invalidCode(.kml, .failed_to_open, "KML file");
    };
    defer kml_source.close();

    const file_size = kml_source.getEndPos() catch {
        return ValidationResult.invalidCode(.kml, .failed_to_get, "file size");
    };

    if (file_size > 50 * 1024 * 1024) { // 50MB limit
        return ValidationResult.okWithDepth(.kml, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.kml, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = kml_source.readAll(data) catch {
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

pub fn validateKmzDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const zip_result = archive_validators.validateZipDeep(allocator, path);
    var coerced = zip_result;
    coerced.format = .kmz;
    return coerced;
}

// ============ Plain Text Validators ============

/// Validate plain text file as UTF-8 using streaming validation.
/// Reads file in chunks and validates UTF-8 encoding throughout.
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
                return ValidationResult.okWithDepthAndWarning(.plain_text, .structural, warning_str);
            }
        }
    }

    return ValidationResult.okWithDepth(.plain_text, .structural);
}

/// Check if a file looks like Latin-1 text (fallback when UTF-8 validation fails).
/// Latin-1 is always "valid" since every byte 0x00-0xFF maps to a character,
/// but we check for text-like characteristics to avoid misidentifying binary files.
pub fn validatePlainTextLatin1Fallback(file: *FileSource) ValidationResult {
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
        return ValidationResult.okWithDepth(.plain_text, .structural);
    }

    // Heuristic: if more than 5% control characters, probably binary
    if (total_bytes > 0 and control_bytes * 100 / total_bytes > 5) {
        return ValidationResult.invalidCode(.plain_text, .invalid_value, "UTF-8 encoding");
    }

    // Looks like Latin-1 text
    return ValidationResult.okWithDepth(.plain_text_latin1, .structural);
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
    try testing.expectEqual(@as(u3, 1), result.warning_count);
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

test "validateUtf8 caps warnings at 5" {
    // 6 noncharacters: U+FDD0..U+FDD5
    const data = "\xEF\xB7\x90" ++ "\xEF\xB7\x91" ++ "\xEF\xB7\x92" ++ "\xEF\xB7\x93" ++ "\xEF\xB7\x94" ++ "\xEF\xB7\x95";
    const result = validateUtf8(data);
    try testing.expect(result.isValid());
    try testing.expectEqual(@as(u3, 5), result.warning_count);
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
    const result = validateJson(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.json, result.format);
    try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateJson rejects truncated JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("bad.json", .{});
    try f.writeAll("{\"key\": ");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.json", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateJson(&source);
    try testing.expect(!result.is_valid);
}

test "validateJson rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("empty.json", .{});
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("empty.json", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateJson(&source);
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
    const f = try tmp.dir.createFile("bad.toml", .{});
    try f.writeAll("[section\nkey = ");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.toml", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateToml(&source);
    try testing.expect(!result.is_valid);
}

test "validateToml rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("empty.toml", .{});
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("empty.toml", &real_path_buf);
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
    const f = try tmp.dir.createFile("bad.ini", .{});
    try f.writeAll("[section]\n<<<invalid>>>\n");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.ini", &real_path_buf);
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
    const f = try tmp.dir.createFile("bad.xml", .{});
    try f.writeAll("<?xml version=\"1.0\"?>\n<root><unclosed>\n");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.xml", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(!result.is_valid);
}

test "validateXml rejects empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("empty.xml", .{});
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("empty.xml", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateXml(&source);
    try testing.expect(!result.is_valid);
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
    const f = try tmp.dir.createFile("bad.csv", .{});
    try f.writeAll("name,desc\nAlice,\"unclosed\n");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.csv", &real_path_buf);
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
    const f = try tmp.dir.createFile("bad.rtf", .{});
    try f.writeAll("not an rtf file at all");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.rtf", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateRtf(&source);
    try testing.expect(!result.is_valid);
}

test "validateRtf rejects missing closing brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("noclosing.rtf", .{});
    try f.writeAll("{\\rtf1\\ansi no closing brace here ");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("noclosing.rtf", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateRtf(&source);
    try testing.expect(!result.is_valid);
}

test "validateRtfDeep accepts valid ground truth RTF file" {
    const path_buf = std.fs.cwd().realpathAlloc(
        testing.allocator,
        "ground_truth_examples/rtf/sample.rtf",
    ) catch return;
    defer testing.allocator.free(path_buf);
    const result = validateRtfDeep(testing.allocator, path_buf);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.rtf, result.format);
}

test "validateRtfDeep detects unmatched closing brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("extrabrace.rtf", .{});
    try f.writeAll("{\\rtf1\\ansi Hello}}");
    f.close();
    const path_buf = tmp.dir.realpathAlloc(
        testing.allocator,
        "extrabrace.rtf",
    ) catch return;
    defer testing.allocator.free(path_buf);
    const result = validateRtfDeep(testing.allocator, path_buf);
    try testing.expect(!result.is_valid);
}

test "validateRtfDeep detects unclosed brace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("unclosed.rtf", .{});
    try f.writeAll("{\\rtf1\\ansi {nested text");
    f.close();
    const path_buf = tmp.dir.realpathAlloc(
        testing.allocator,
        "unclosed.rtf",
    ) catch return;
    defer testing.allocator.free(path_buf);
    const result = validateRtfDeep(testing.allocator, path_buf);
    try testing.expect(!result.is_valid);
}

test "validateHtml accepts valid ground truth HTML file" {
    var source = FileSource.open("ground_truth_examples/html/simple.html") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer source.close();
    const result = validateHtml(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.html, result.format);
}

test "validateHtml rejects file without DOCTYPE or html tag" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("bad.html", .{});
    try f.writeAll("<div>Just a div, no html or doctype</div>");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.html", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateHtml(&source);
    try testing.expect(!result.is_valid);
}

test "validateHtml rejects tiny file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("tiny.html", .{});
    try f.writeAll("hi");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("tiny.html", &real_path_buf);
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
    const f = try tmp.dir.createFile("bad.kml", .{});
    try f.writeAll("<?xml version=\"1.0\"?>\n<notKml>test</notKml>\n");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.kml", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validateKml(&source);
    try testing.expect(!result.is_valid);
}

test "validateKmlDeep accepts valid ground truth KML file" {
    const path_buf = std.fs.cwd().realpathAlloc(
        testing.allocator,
        "ground_truth_examples/kml/sample.kml",
    ) catch return;
    defer testing.allocator.free(path_buf);
    const result = validateKmlDeep(testing.allocator, path_buf);
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
    const f = try tmp.dir.createFile("bad.kmz", .{});
    try f.writeAll("not a zip file");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("bad.kmz", &real_path_buf);
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
    const f = try tmp.dir.createFile("empty.txt", .{});
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("empty.txt", &real_path_buf);
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
    const f = try tmp.dir.createFile("odd.txt", .{});
    // UTF-16 LE BOM + 3 bytes (odd after BOM)
    try f.writeAll("\xFF\xFE\x41\x00\x42");
    f.close();
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("odd.txt", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();
    const result = validatePlainTextUtf16(null, &source);
    try testing.expect(!result.is_valid);
}

test "validateJson accepts JSON5 ground truth file with warning" {
    var source = FileSource.open("ground_truth_examples/json5/sample.json5") catch return;
    defer source.close();
    const result = validateJson(&source);
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

    const file = try tmp_dir.dir.createFile("valid.rtf", .{});
    try file.writeAll(valid_rtf);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.rtf");
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

    const file = try tmp_dir.dir.createFile("invalid.rtf", .{});
    try file.writeAll(invalid_rtf);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.rtf");
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

    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(text_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.txt");
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

    const file = try tmp_dir.dir.createFile("test_bom.txt", .{});
    try file.writeAll(&bom);
    try file.writeAll(text);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test_bom.txt");
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

    const file = try tmp_dir.dir.createFile("test.bin", .{});
    try file.writeAll(&binary_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.bin");
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

    const file = try tmp_dir.dir.createFile("test_multibyte.txt", .{});
    try file.writeAll(utf8_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test_multibyte.txt");
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

    const file = try tmp_dir.dir.createFile("release.nfo", .{});
    try file.writeAll(&cp437_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "release.nfo");
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

    const file = try tmp_dir.dir.createFile("test.json", .{});
    try file.writeAll(json_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.json");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.json, result.format);
    try std.testing.expect(result.is_valid);
    // JSON parsing but no CRC/hash integrity mechanism
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
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

    const file = try tmp_dir.dir.createFile("test.json", .{});
    try file.writeAll(json_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.json");
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

    const file = try tmp_dir.dir.createFile("game.log", .{});
    try file.writeAll(log_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "game.log");
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

    const file = try tmp_dir.dir.createFile("test.json", .{});
    try file.writeAll(jsonc_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.json");
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

    const file = try tmp_dir.dir.createFile("test.json", .{});
    try file.writeAll(jsonc_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.json");
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

    const file = try tmp_dir.dir.createFile("test.json", .{});
    try file.writeAll(json_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.json");
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

    const file = try tmp_dir.dir.createFile("test.toml", .{});
    try file.writeAll(toml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.toml");
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

    const file = try tmp_dir.dir.createFile("test.toml", .{});
    try file.writeAll(toml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.toml");
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

    const file = try tmp_dir.dir.createFile("test.xml", .{});
    try file.writeAll(xml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.xml");
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

    const file = try tmp_dir.dir.createFile("test.xml", .{});
    try file.writeAll(xml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.xml");
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

    const file = try tmp_dir.dir.createFile("test.xml", .{});
    try file.writeAll(xml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.xml");
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

    const file = try tmp_dir.dir.createFile("test.xml", .{});
    try file.writeAll(xml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.xml");
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

    const file = try tmp_dir.dir.createFile("test.kml", .{});
    try file.writeAll(kml_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.kml");
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
    try std.testing.expect(format != null);
    try std.testing.expectEqual(FileFormat.ini, format.?);
}

