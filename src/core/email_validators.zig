//! Email format validators extracted from format_validation.zig.
//! Covers EML (RFC 5322) and MBOX mailbox formats, including MIME
//! multipart parsing and base64 attachment validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

// Helper references from format_validation
const isEmailHeader = format_validation.isEmailHeader;
const hasValidEmailHeaders = format_validation.hasValidEmailHeaders;
const findMimeBoundary = format_validation.findMimeBoundary;
const findHeaderValue = format_validation.findHeaderValue;
const base64_decode_table = format_validation.base64_decode_table;
const decodeBase64 = format_validation.decodeBase64;
const max_attachment_decode_size = format_validation.max_attachment_decode_size;
const detectFormat = format_validation.detectFormat;
const validateDataBufferFormat = format_validation.validateDataBufferFormat;

// ============ EML Validator ============

/// Validate an EML (RFC 5322) email message file.
pub fn validateEml(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.eml, errmsg.failedToSeek("to start"));

    // Read entire file (limit to reasonable size)
    const stat = file.stat() catch return ValidationResult.invalid(.eml, errmsg.failedToStat("file"));
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

    file.seekTo(0) catch return ValidationResult.invalid(.eml, errmsg.failedToSeek("to start"));
    const bytes_read = file.readAll(content) catch {
        return ValidationResult.invalid(.eml, errmsg.failedToRead("file"));
    };

    return validateEmlContent(allocator, content[0..bytes_read]);
}

/// Validate EML structural headers only (used for oversized files).
pub fn validateEmlStructure(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.eml, errmsg.failedToSeek("to start"));

    var header: [4096]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.eml, errmsg.failedToRead("header"));

    if (header_read < 10) {
        return ValidationResult.invalid(.eml, errmsg.fileTooSmallFor("EML"));
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
        return ValidationResult.invalid(.eml, errmsg.noValidXFound("email headers"));
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
        return ValidationResult.invalid(.eml, errmsg.noValidXFound("email headers"));
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
        return ValidationResult.invalid(.eml, "Invalid base64 encoding in attachment");
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

    // Attachment validated successfully - return full depth if attachment was fully validated
    if (attachment_result.validation_depth == .full) {
        return ValidationResult.okWithDepth(.eml, .full);
    }

    // Return structural if attachment could only be structurally validated
    return ValidationResult.okWithDepth(.eml, .structural);
}

// ============ MBOX Validator ============

/// Validate an MBOX mailbox file structure.
pub fn validateMbox(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.mbox, errmsg.failedToSeek("to start"));

    var header: [4096]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.mbox, errmsg.failedToRead("header"));

    if (header_read < 5) {
        return ValidationResult.invalid(.mbox, errmsg.fileTooSmallFor("MBOX"));
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
        return ValidationResult.invalid(.mbox, errmsg.noValidXFound("MBOX messages"));
    }

    return ValidationResult.ok(.mbox);
}

/// Deep-validate an MBOX mailbox file by reading all message separators.
pub fn validateMboxDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.mbox, errmsg.failedToOpen("MBOX file"));
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalid(.mbox, errmsg.failedToGet("file size"));
    };

    if (file_size > 1024 * 1024 * 1024) { // 1GB limit
        return ValidationResult.okWithDepth(.mbox, .structural);
    }

    const data = allocator.alloc(u8, file_size) catch {
        return ValidationResult.invalid(.mbox, "Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalid(.mbox, errmsg.failedToRead("file"));
    };
    if (bytes_read != file_size) {
        return ValidationResult.invalid(.mbox, errmsg.incomplete("file read"));
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
        return ValidationResult.invalid(.mbox, errmsg.noValidXFound("messages"));
    }

    return ValidationResult.okWithDepth(.mbox, .structural);
}
