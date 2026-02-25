//! Email format validators extracted from format_validation.zig.
//! Covers EML (RFC 5322) and MBOX mailbox formats, including MIME
//! multipart parsing and base64 attachment validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

const detectFormat = format_validation.detectFormat;
const validateDataBufferFormat = format_validation.validateDataBufferFormat;

/// Maximum attachment size to decode and validate (16 MB)
const max_attachment_decode_size: usize = 16 * 1024 * 1024;

/// Check if a header name is a common RFC 822/2822 email header.
const FormatValidator = format_validation.FormatValidator;

pub fn isEmailHeader(name: []const u8) bool {
    const email_headers = [_][]const u8{
        "From",                      "To",                     "Cc",             "Bcc",                 "Subject",     "Date",       "Message-ID",    "Message-Id",
        "Received",                  "Return-Path",            "Reply-To",       "Sender",              "In-Reply-To", "References", "MIME-Version",  "Content-Type",
        "Content-Transfer-Encoding", "Content-Disposition",    "Content-ID",     "Content-Description", "X-Mailer",    "X-Priority", "X-Spam-Status", "X-Originating-IP",
        "Delivered-To",              "Authentication-Results", "DKIM-Signature",
    };

    for (email_headers) |header| {
        if (std.ascii.eqlIgnoreCase(name, header)) {
            return true;
        }
    }

    // Also check for X- custom headers
    if (name.len >= 2 and (name[0] == 'X' or name[0] == 'x') and name[1] == '-') {
        return true;
    }

    return false;
}

/// Check if headers contain at least one recognized email header.
pub fn hasValidEmailHeaders(headers: []const u8) bool {
    var line_start: usize = 0;
    for (headers, 0..) |c, idx| {
        if (c == '\n') {
            const line = headers[line_start..idx];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                const clean_line = line[0 .. line.len - 1];
                if (std.mem.indexOf(u8, clean_line, ":")) |colon_pos| {
                    if (colon_pos > 0 and isEmailHeader(clean_line[0..colon_pos])) {
                        return true;
                    }
                }
            } else if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                if (colon_pos > 0 and isEmailHeader(line[0..colon_pos])) {
                    return true;
                }
            }
            line_start = idx + 1;
        }
    }
    return false;
}

/// Find MIME boundary from Content-Type header.
pub fn findMimeBoundary(headers: []const u8) ?[]const u8 {
    const content_type = findHeaderValue(headers, "Content-Type") orelse return null;
    const boundary_start = std.ascii.indexOfIgnoreCase(content_type, "boundary=") orelse return null;
    var start = boundary_start + 9;

    if (start >= content_type.len) return null;

    if (content_type[start] == '"') {
        start += 1;
        const end = std.mem.indexOfPos(u8, content_type, start, "\"") orelse return null;
        return content_type[start..end];
    }

    var end = start;
    while (end < content_type.len and
        content_type[end] != ';' and
        content_type[end] != ' ' and
        content_type[end] != '\t' and
        content_type[end] != '\r' and
        content_type[end] != '\n')
    {
        end += 1;
    }

    return content_type[start..end];
}

/// Find a header value by name (case-insensitive).
pub fn findHeaderValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var line_start: usize = 0;
    var in_continuation = false;
    var value_start: usize = 0;
    var value_end: usize = 0;

    for (headers, 0..) |c, idx| {
        if (c == '\n') {
            const line = headers[line_start..idx];
            const clean_line = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;

            if (in_continuation) {
                if (clean_line.len > 0 and (clean_line[0] == ' ' or clean_line[0] == '\t')) {
                    value_end = idx;
                } else {
                    return headers[value_start..value_end];
                }
            } else if (std.mem.indexOf(u8, clean_line, ":")) |colon_pos| {
                const header_name = clean_line[0..colon_pos];
                if (std.ascii.eqlIgnoreCase(header_name, name)) {
                    value_start = line_start + colon_pos + 1;
                    while (value_start < idx and (headers[value_start] == ' ' or headers[value_start] == '\t')) {
                        value_start += 1;
                    }
                    value_end = idx;
                    in_continuation = true;
                }
            }

            line_start = idx + 1;
        }
    }

    if (in_continuation and value_end > value_start) {
        return headers[value_start..value_end];
    }

    return null;
}

/// Base64 decoding table (RFC 4648)
const base64_decode_table = blk: {
    var table: [256]u8 = .{0xFF} ** 256;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    table['='] = 0xFE;
    break :blk table;
};

/// Decode base64 data into output buffer.
pub fn decodeBase64(encoded: []const u8, output: []u8) !usize {
    var out_idx: usize = 0;
    var accum: u32 = 0;
    var bits: u8 = 0;
    var padding_count: u8 = 0;

    for (encoded) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;

        const val = base64_decode_table[c];
        if (val == 0xFF) {
            return error.InvalidBase64;
        }
        if (val == 0xFE) {
            padding_count += 1;
            continue;
        }
        if (padding_count > 0) {
            return error.InvalidBase64;
        }

        accum = (accum << 6) | val;
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            if (out_idx >= output.len) {
                return error.OutputBufferTooSmall;
            }
            output[out_idx] = @intCast((accum >> @as(u5, @intCast(bits))) & 0xFF);
            out_idx += 1;
        }
    }

    return out_idx;
}

// ============ EML Validator ============

/// Validate an EML (RFC 5322) email message file.
pub fn validateEml(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.eml, .failed_to_seek, "to start");

    // Read entire file (limit to reasonable size)
    const stat = file.stat() catch return ValidationResult.invalidCode(.eml, .failed_to_stat, "file");
    if (stat.size > 100 * 1024 * 1024) {
        // File too large, just do structural validation
        return validateEmlStructure(file);
    }

    // Allocate buffer for file content
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalid(.eml, "Out of memory");
    };
    defer allocator.free(content);

    file.seekTo(0) catch return ValidationResult.invalidCode(.eml, .failed_to_seek, "to start");
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalidCode(.eml, .failed_to_read, "file");
    };

    return validateEmlContent(allocator, content[0..bytes_read]);
}

/// Validate EML structural headers only (used for oversized files).
pub fn validateEmlStructure(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.eml, .failed_to_seek, "to start");

    var header: [4096]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.eml, .failed_to_read, "header");

    if (header_read < 10) {
        return ValidationResult.invalidCode(.eml, .file_too_small, "EML");
    }

    // Check for valid email headers
    const content = header[0..header_read];
    var found_header = false;

    var line_start: usize = 0;
    for (content, 0..) |c, idx| {
        if (c == '\n') {
            const line = content[line_start..idx];
            // Skip empty lines at start
            if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
                line_start = idx + 1;
                continue;
            }
            // Check for header: word followed by colon
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                if (colon_pos > 0) {
                    const header_name = line[0..colon_pos];
                    if (isEmailHeader(header_name)) {
                        found_header = true;
                        break;
                    }
                }
            }
            line_start = idx + 1;
        }
    }

    if (!found_header) {
        return ValidationResult.invalidCode(.eml, .no_valid_x_found, "email headers");
    }

    return ValidationResult.okWithDepth(.eml, .structural);
}

/// Validate EML content (headers + body) from a buffer.
pub fn validateEmlContent(allocator: Allocator, content: []const u8) ValidationResult {
    // Find the header/body separator (blank line)
    var header_end: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\n') {
            // Check for blank line (just \n or \r\n)
            if (i + 1 < content.len and content[i + 1] == '\n') {
                header_end = i + 2;
                break;
            }
            if (i + 2 < content.len and content[i + 1] == '\r' and content[i + 2] == '\n') {
                header_end = i + 3;
                break;
            }
        }
        i += 1;
    }

    if (header_end == 0) {
        return ValidationResult.invalid(.eml, "No header/body separator found");
    }

    const headers = content[0..header_end];

    // Check for valid email headers
    if (!hasValidEmailHeaders(headers)) {
        return ValidationResult.invalidCode(.eml, .no_valid_x_found, "email headers");
    }

    // Check for multipart MIME
    const boundary = findMimeBoundary(headers);
    if (boundary) |b| {
        // Parse and validate multipart attachments
        return validateMimeAttachments(allocator, content[header_end..], b);
    }

    // No multipart - check for single-part base64 content
    if (findHeaderValue(headers, "Content-Transfer-Encoding")) |encoding| {
        if (std.ascii.indexOfIgnoreCase(encoding, "base64") != null) {
            // Single part base64 encoded
            return validateBase64Attachment(allocator, content[header_end..], headers);
        }
    }

    // Plain text email - structurally valid
    return ValidationResult.ok(.eml);
}

/// Validate MIME multipart attachments within an email body.
pub fn validateMimeAttachments(allocator: Allocator, body: []const u8, boundary: []const u8) ValidationResult {
    // Build boundary markers
    var boundary_marker: [256]u8 = undefined;
    const marker_len = 2 + boundary.len;
    if (marker_len > boundary_marker.len) {
        return ValidationResult.invalid(.eml, "Boundary too long");
    }
    boundary_marker[0] = '-';
    boundary_marker[1] = '-';
    @memcpy(boundary_marker[2..][0..boundary.len], boundary);

    const marker = boundary_marker[0..marker_len];

    // Find all parts
    var part_start: ?usize = null;
    var attachment_count: u32 = 0;
    var idx: usize = 0;

    while (idx < body.len) {
        // Look for boundary marker
        if (idx + marker.len <= body.len and std.mem.eql(u8, body[idx..][0..marker.len], marker)) {
            if (part_start) |start| {
                // End of previous part
                const part_end = idx;
                const part_result = validateMimePart(allocator, body[start..part_end]);
                if (!part_result.is_valid) {
                    attachment_count += 1;
                    return ValidationResult.invalid(.eml, part_result.error_message orelse "Attachment validation failed");
                }
                if (part_result.validation_depth != .structural) {
                    attachment_count += 1;
                }
            }

            // Check for closing boundary (--)
            if (idx + marker.len + 2 <= body.len and
                body[idx + marker.len] == '-' and body[idx + marker.len + 1] == '-')
            {
                // End of multipart
                break;
            }

            // Skip to end of line
            idx += marker.len;
            while (idx < body.len and body[idx] != '\n') : (idx += 1) {}
            if (idx < body.len) idx += 1; // Skip newline

            part_start = idx;
        } else {
            idx += 1;
        }
    }

    return ValidationResult.ok(.eml);
}

/// Validate a single MIME part (header + body).
pub fn validateMimePart(allocator: Allocator, part: []const u8) ValidationResult {
    // Find part header/body separator
    var header_end: usize = 0;
    var i: usize = 0;
    while (i < part.len) {
        if (part[i] == '\n') {
            if (i + 1 < part.len and part[i + 1] == '\n') {
                header_end = i + 2;
                break;
            }
            if (i + 2 < part.len and part[i + 1] == '\r' and part[i + 2] == '\n') {
                header_end = i + 3;
                break;
            }
            if (i + 1 < part.len and part[i + 1] == '\r') {
                header_end = i + 2;
                break;
            }
        }
        i += 1;
    }

    if (header_end == 0) {
        // No headers - just body content
        return ValidationResult.okWithDepth(.eml, .structural);
    }

    const headers = part[0..header_end];
    const body = part[header_end..];

    // Check if this is base64 encoded
    const encoding = findHeaderValue(headers, "Content-Transfer-Encoding");
    if (encoding) |enc| {
        if (std.ascii.indexOfIgnoreCase(enc, "base64") != null) {
            return validateBase64Attachment(allocator, body, headers);
        }
    }

    // Not base64 - accept as valid
    return ValidationResult.okWithDepth(.eml, .structural);
}

/// Validate a base64-encoded attachment by decoding and format-checking.
pub fn validateBase64Attachment(allocator: Allocator, body: []const u8, headers: []const u8) ValidationResult {
    // Headers could be used for Content-Type hints but we rely on magic detection
    _ = headers;

    // Skip if body is too large
    if (body.len > max_attachment_decode_size * 4 / 3) {
        return ValidationResult.okWithDepth(.eml, .structural);
    }

    // Allocate decode buffer
    const decode_buffer = allocator.alloc(u8, body.len) catch {
        return ValidationResult.okWithDepth(.eml, .structural);
    };
    defer allocator.free(decode_buffer);

    // Decode base64
    const decoded_len = decodeBase64(body, decode_buffer) catch {
        return ValidationResult.invalidCode(.eml, .invalid_value, "base64 encoding in attachment");
    };

    if (decoded_len == 0) {
        return ValidationResult.okWithDepth(.eml, .structural);
    }

    const decoded = decode_buffer[0..decoded_len];

    // Detect format of decoded content
    const format = detectFormat(decoded);

    // If format is unknown, accept as structurally valid
    if (format == .unknown) {
        return ValidationResult.okWithDepth(.eml, .structural);
    }

    // Use the buffer validation function to fully validate the attachment
    const attachment_result = validateDataBufferFormat(decoded, format);

    // If the attachment is invalid, report it
    if (!attachment_result.is_valid) {
        return ValidationResult.invalid(.eml, attachment_result.error_message orelse "Attachment validation failed");
    }

    // EML is an opaque text format with no integrity mechanism (no checksums,
    // no CRCs, no signatures verified), so we never claim .full — even if an
    // embedded attachment validated fully, the envelope itself is structural only.
    return ValidationResult.okWithDepth(.eml, .structural);
}

// ============ MBOX Validator ============

/// Validate an MBOX mailbox file structure.
pub fn validateMbox(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.mbox, .failed_to_seek, "to start");

    var header: [4096]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.mbox, .failed_to_read, "header");

    if (header_read < 5) {
        return ValidationResult.invalidCode(.mbox, .file_too_small, "MBOX");
    }

    // MBOX must start with "From " (note the space)
    if (!std.mem.eql(u8, header[0..5], "From ")) {
        return ValidationResult.invalid(.mbox, "MBOX must start with 'From ' separator");
    }

    // Count message separators to verify structure
    var message_count: u32 = 0;
    var i: usize = 0;
    while (i < header_read) {
        // Look for "\nFrom " or start with "From "
        if (i == 0 and std.mem.eql(u8, header[0..5], "From ")) {
            message_count += 1;
            i = 5;
            continue;
        }
        if (i + 6 < header_read and header[i] == '\n' and std.mem.eql(u8, header[i + 1 ..][0..5], "From ")) {
            message_count += 1;
            i += 6;
            continue;
        }
        i += 1;
    }

    if (message_count == 0) {
        return ValidationResult.invalidCode(.mbox, .no_valid_x_found, "MBOX messages");
    }

    return ValidationResult.ok(.mbox);
}

/// Deep-validate an MBOX mailbox file by reading all message separators.
pub fn validateMboxDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.mbox, .failed_to_open, "MBOX file");
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.mbox, .failed_to_get, "file size");
    };

    if (file_size > 1024 * 1024 * 1024) { // 1GB limit
        return ValidationResult.okWithDepth(.mbox, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.mbox, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.mbox, .failed_to_read, "file");
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalidCode(.mbox, .incomplete, "file read");
    }

    // Must start with "From "
    if (data.len < 5 or !std.mem.eql(u8, data[0..5], "From ")) {
        return ValidationResult.invalid(.mbox, "MBOX must start with 'From ' separator");
    }

    // Count all message separators
    var message_count: u32 = 1; // Already found first one
    var i: usize = 5;

    while (i + 5 < data.len) {
        // Look for "\nFrom " pattern
        if (data[i] == '\n' and std.mem.eql(u8, data[i + 1 ..][0..5], "From ")) {
            message_count += 1;
            i += 6;
            continue;
        }
        i += 1;
    }

    if (message_count == 0) {
        return ValidationResult.invalidCode(.mbox, .no_valid_x_found, "messages");
    }

    return ValidationResult.okWithDepth(.mbox, .structural);
}

// ============ Tests ============

test "validateEml with ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/eml/sample.eml", .{}) catch return;
    defer file.close();
    const result = validateEml(file);
    try std.testing.expect(result.is_valid);
}

test "validateMbox with ground truth" {
    const file = std.fs.cwd().openFile("ground_truth_examples/mbox/sample.mbox", .{}) catch return;
    defer file.close();
    const result = validateMbox(file);
    try std.testing.expect(result.is_valid);
}

test "validateMboxDeep with ground truth" {
    const allocator = std.testing.allocator;
    const result = validateMboxDeep(allocator, "ground_truth_examples/mbox/sample.mbox");
    try std.testing.expect(result.is_valid);
}

test "validateEml with minimal valid email" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_minimal.eml", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("From: a@b.c\r\nTo: d@e.f\r\nSubject: test\r\n\r\nbody") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const result = validateEml(file);
    try std.testing.expect(result.is_valid);
}

test "validateMbox with minimal valid mbox" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_minimal.mbox", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        wf.writeAll("From sender@example.com Mon Jan  1 00:00:00 2024\r\nFrom: a@b.c\r\nTo: d@e.f\r\nSubject: test\r\n\r\nbody\r\n") catch return;
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const result = validateMbox(file);
    try std.testing.expect(result.is_valid);
}

test "validateEml with empty file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_empty.eml", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        // Write nothing — empty file
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const result = validateEml(file);
    try std.testing.expect(!result.is_valid);
}

test "validateMbox with empty file" {
    const tmpdir = std.posix.getenv("TMPDIR") orelse "/tmp";
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/test_empty.mbox", .{tmpdir}) catch return;
    {
        const wf = std.fs.cwd().createFile(path, .{}) catch return;
        defer wf.close();
        // Write nothing — empty file
    }
    defer std.fs.cwd().deleteFile(path) catch {};
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();
    const result = validateMbox(file);
    try std.testing.expect(!result.is_valid);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "detectFormat EML with From header" {
    const eml_content = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Test\r\n\r\nBody";
    try std.testing.expectEqual(FileFormat.eml, detectFormat(eml_content));
}

test "detectFormat EML with Received header" {
    const eml_content = "Received: from mail.example.com\r\nFrom: sender@example.com\r\n\r\nBody";
    try std.testing.expectEqual(FileFormat.eml, detectFormat(eml_content));
}

test "detectFormat EML with MIME-Version" {
    const eml_content = "MIME-Version: 1.0\r\nFrom: sender@example.com\r\n\r\nBody";
    try std.testing.expectEqual(FileFormat.eml, detectFormat(eml_content));
}

test "detectFormat MBOX" {
    const mbox_content = "From sender@example.com Mon Jan 15 10:00:00 2024\r\nFrom: sender@example.com\r\n\r\nBody";
    try std.testing.expectEqual(FileFormat.mbox, detectFormat(mbox_content));
}

test "FormatValidator accepts valid EML" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const eml_content =
        \\From: sender@example.com
        \\To: recipient@example.com
        \\Subject: Test Email
        \\Date: Mon, 15 Jan 2024 10:00:00 +0000
        \\MIME-Version: 1.0
        \\Content-Type: text/plain; charset=utf-8
        \\
        \\This is a test email body.
    ;

    const file = try tmp_dir.dir.createFile("test.eml", .{});
    try file.writeAll(eml_content);
    file.close();

    const validate_file = try tmp_dir.dir.openFile("test.eml", .{});
    defer validate_file.close();

    const result = validateEml(validate_file);

    try std.testing.expectEqual(FileFormat.eml, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts EML with valid PNG attachment" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid PNG (1x1 transparent pixel) base64 encoded
    const png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

    const eml_content =
        "From: sender@example.com\r\n" ++
        "To: recipient@example.com\r\n" ++
        "Subject: Test with attachment\r\n" ++
        "MIME-Version: 1.0\r\n" ++
        "Content-Type: multipart/mixed; boundary=\"----=_Part_0\"\r\n" ++
        "\r\n" ++
        "------=_Part_0\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Email body\r\n" ++
        "------=_Part_0\r\n" ++
        "Content-Type: image/png; name=\"test.png\"\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "Content-Disposition: attachment; filename=\"test.png\"\r\n" ++
        "\r\n" ++
        png_base64 ++ "\r\n" ++
        "------=_Part_0--\r\n";

    const file = try tmp_dir.dir.createFile("test_attachment.eml", .{});
    try file.writeAll(eml_content);
    file.close();

    const validate_file = try tmp_dir.dir.openFile("test_attachment.eml", .{});
    defer validate_file.close();

    const result = validateEml(validate_file);

    try std.testing.expectEqual(FileFormat.eml, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects EML with corrupted attachment" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Corrupted PNG - valid PNG signature but invalid chunk type (XXXX instead of IHDR)
    const corrupted_png_base64 = "iVBORw0KGgoAAAANWFhYWGV4dHJhZGF0YQ=="; // Has "XXXX" not "IHDR"

    const eml_content =
        "From: sender@example.com\r\n" ++
        "To: recipient@example.com\r\n" ++
        "Subject: Test with corrupted attachment\r\n" ++
        "MIME-Version: 1.0\r\n" ++
        "Content-Type: multipart/mixed; boundary=\"----=_Part_0\"\r\n" ++
        "\r\n" ++
        "------=_Part_0\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "Email body\r\n" ++
        "------=_Part_0\r\n" ++
        "Content-Type: image/png; name=\"corrupt.png\"\r\n" ++
        "Content-Transfer-Encoding: base64\r\n" ++
        "Content-Disposition: attachment; filename=\"corrupt.png\"\r\n" ++
        "\r\n" ++
        corrupted_png_base64 ++ "\r\n" ++
        "------=_Part_0--\r\n";

    const file = try tmp_dir.dir.createFile("test_corrupt.eml", .{});
    try file.writeAll(eml_content);
    file.close();

    const validate_file = try tmp_dir.dir.openFile("test_corrupt.eml", .{});
    defer validate_file.close();

    const result = validateEml(validate_file);

    try std.testing.expectEqual(FileFormat.eml, result.format);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.error_message != null);
}

test "FormatValidator accepts valid MBOX" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const mbox_content =
        \\From sender@example.com Mon Jan 15 10:00:00 2024
        \\From: sender@example.com
        \\To: recipient@example.com
        \\Subject: First Message
        \\
        \\First message body.
        \\
        \\From another@example.com Mon Jan 15 11:00:00 2024
        \\From: another@example.com
        \\To: recipient@example.com
        \\Subject: Second Message
        \\
        \\Second message body.
    ;

    const file = try tmp_dir.dir.createFile("test.mbox", .{});
    try file.writeAll(mbox_content);
    file.close();

    const validate_file = try tmp_dir.dir.openFile("test.mbox", .{});
    defer validate_file.close();

    const result = validateMbox(validate_file);

    try std.testing.expectEqual(FileFormat.mbox, result.format);
    try std.testing.expect(result.is_valid);
}

test "base64 decode valid data" {
    const encoded = "SGVsbG8gV29ybGQh"; // "Hello World!"
    var decoded: [64]u8 = undefined;
    const len = decodeBase64(encoded, &decoded) catch unreachable;
    try std.testing.expectEqualStrings("Hello World!", decoded[0..len]);
}

test "base64 decode with padding" {
    const encoded = "SGVsbG8="; // "Hello"
    var decoded: [64]u8 = undefined;
    const len = decodeBase64(encoded, &decoded) catch unreachable;
    try std.testing.expectEqualStrings("Hello", decoded[0..len]);
}

test "base64 decode invalid characters fails" {
    const encoded = "Invalid!!!";
    var decoded: [64]u8 = undefined;
    const result = decodeBase64(encoded, &decoded);
    try std.testing.expectError(error.InvalidBase64, result);
}

