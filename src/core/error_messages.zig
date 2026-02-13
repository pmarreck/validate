//! Canonical error/warning message templates.
//! All functions use comptime string concatenation — zero runtime cost.
//! English output is byte-identical to the previous string literals.
//!
//! For i18n: templates define the translatable verb/action phrases.
//! The detail parameter (technical nouns) stays English across all locales.

// Tier 1: High-impact templates

/// "Failed to read " ++ detail
/// Example: failedToRead("PNG signature") → "Failed to read PNG signature"
pub fn failedToRead(comptime detail: []const u8) *const [("Failed to read " ++ detail).len:0]u8 {
    return "Failed to read " ++ detail;
}

/// "File too small for " ++ what
/// Example: fileTooSmallFor("valid ZIP") → "File too small for valid ZIP"
pub fn fileTooSmallFor(comptime what: []const u8) *const [("File too small for " ++ what).len:0]u8 {
    return "File too small for " ++ what;
}

/// "Invalid " ++ what ++ " signature"
/// Example: invalidSignature("PNG") → "Invalid PNG signature"
pub fn invalidSignature(comptime what: []const u8) *const [("Invalid " ++ what ++ " signature").len:0]u8 {
    return "Invalid " ++ what ++ " signature";
}

/// "Missing " ++ what
/// Example: missing("IHDR chunk") → "Missing IHDR chunk"
pub fn missing(comptime what: []const u8) *const [("Missing " ++ what).len:0]u8 {
    return "Missing " ++ what;
}

/// "Failed to seek " ++ detail
/// Example: failedToSeek("to chunk") → "Failed to seek to chunk"
pub fn failedToSeek(comptime detail: []const u8) *const [("Failed to seek " ++ detail).len:0]u8 {
    return "Failed to seek " ++ detail;
}

/// "Truncated " ++ what
/// Example: truncated("PNG chunk") → "Truncated PNG chunk"
pub fn truncated(comptime what: []const u8) *const [("Truncated " ++ what).len:0]u8 {
    return "Truncated " ++ what;
}

// Tier 2: Medium-impact templates

/// "Invalid " ++ what ++ " magic bytes"
/// Example: invalidMagic("PNG") → "Invalid PNG magic bytes"
pub fn invalidMagic(comptime what: []const u8) *const [("Invalid " ++ what ++ " magic bytes").len:0]u8 {
    return "Invalid " ++ what ++ " magic bytes";
}

/// "Invalid " ++ what ++ " magic number"
/// Example: invalidMagicNumber("GIF") → "Invalid GIF magic number"
pub fn invalidMagicNumber(comptime what: []const u8) *const [("Invalid " ++ what ++ " magic number").len:0]u8 {
    return "Invalid " ++ what ++ " magic number";
}

/// "Failed to open " ++ what
/// Example: failedToOpen("file") → "Failed to open file"
pub fn failedToOpen(comptime what: []const u8) *const [("Failed to open " ++ what).len:0]u8 {
    return "Failed to open " ++ what;
}

/// "Failed to skip " ++ what
/// Example: failedToSkip("padding") → "Failed to skip padding"
pub fn failedToSkip(comptime what: []const u8) *const [("Failed to skip " ++ what).len:0]u8 {
    return "Failed to skip " ++ what;
}

/// "Too many " ++ what
/// Example: tooMany("chunks") → "Too many chunks"
pub fn tooMany(comptime what: []const u8) *const [("Too many " ++ what).len:0]u8 {
    return "Too many " ++ what;
}

/// "Unsupported " ++ what
/// Example: unsupported("compression method") → "Unsupported compression method"
pub fn unsupported(comptime what: []const u8) *const [("Unsupported " ++ what).len:0]u8 {
    return "Unsupported " ++ what;
}

/// "Incomplete " ++ what
/// Example: incomplete("frame data") → "Incomplete frame data"
pub fn incomplete(comptime what: []const u8) *const [("Incomplete " ++ what).len:0]u8 {
    return "Incomplete " ++ what;
}

/// "Buffer too small for " ++ what
/// Example: bufferTooSmallFor("header") → "Buffer too small for header"
pub fn bufferTooSmallFor(comptime what: []const u8) *const [("Buffer too small for " ++ what).len:0]u8 {
    return "Buffer too small for " ++ what;
}

/// "No valid " ++ what ++ " found"
/// Example: noValidXFound("frames") → "No valid frames found"
pub fn noValidXFound(comptime what: []const u8) *const [("No valid " ++ what ++ " found").len:0]u8 {
    return "No valid " ++ what ++ " found";
}

/// "Unknown " ++ what
/// Example: unknown("chunk type") → "Unknown chunk type"
pub fn unknown(comptime what: []const u8) *const [("Unknown " ++ what).len:0]u8 {
    return "Unknown " ++ what;
}

/// "Empty " ++ what
/// Example: empty("file") → "Empty file"
pub fn empty(comptime what: []const u8) *const [("Empty " ++ what).len:0]u8 {
    return "Empty " ++ what;
}

// Tier 3: Lower-impact templates

/// "File too large for " ++ what
/// Example: fileTooLargeFor("format detection") → "File too large for format detection"
pub fn fileTooLargeFor(comptime what: []const u8) *const [("File too large for " ++ what).len:0]u8 {
    return "File too large for " ++ what;
}

/// "Failed to allocate " ++ what
/// Example: failedToAllocate("memory for buffer") → "Failed to allocate memory for buffer"
pub fn failedToAllocate(comptime what: []const u8) *const [("Failed to allocate " ++ what).len:0]u8 {
    return "Failed to allocate " ++ what;
}

/// "Failed to stat " ++ what
/// Example: failedToStat("file") → "Failed to stat file"
pub fn failedToStat(comptime what: []const u8) *const [("Failed to stat " ++ what).len:0]u8 {
    return "Failed to stat " ++ what;
}

/// "Out of memory " ++ detail
/// Example: outOfMemory("for JSON") → "Out of memory for JSON"
pub fn outOfMemory(comptime detail: []const u8) *const [("Out of memory " ++ detail).len:0]u8 {
    return "Out of memory " ++ detail;
}

/// "Failed to get " ++ what
/// Example: failedToGet("file size") → "Failed to get file size"
pub fn failedToGet(comptime what: []const u8) *const [("Failed to get " ++ what).len:0]u8 {
    return "Failed to get " ++ what;
}

/// "Invalid " ++ what ++ " signature (expected " ++ expected ++ ")"
/// Example: invalidSignatureExpected("DWG", "AC") → "Invalid DWG signature (expected AC)"
pub fn invalidSignatureExpected(comptime what: []const u8, comptime expected: []const u8) *const [("Invalid " ++ what ++ " signature (expected " ++ expected ++ ")").len:0]u8 {
    return "Invalid " ++ what ++ " signature (expected " ++ expected ++ ")";
}

/// "Invalid " ++ what ++ " signature (not " ++ not_what ++ ")"
/// Example: invalidSignatureNot("PRPROJ", "gzip or XML") → "Invalid PRPROJ signature (not gzip or XML)"
pub fn invalidSignatureNot(comptime what: []const u8, comptime not_what: []const u8) *const [("Invalid " ++ what ++ " signature (not " ++ not_what ++ ")").len:0]u8 {
    return "Invalid " ++ what ++ " signature (not " ++ not_what ++ ")";
}

/// method ++ " decompression failed"
/// Example: decompressionFailed("Zlib") → "Zlib decompression failed"
pub fn decompressionFailed(comptime method: []const u8) *const [(method ++ " decompression failed").len:0]u8 {
    return method ++ " decompression failed";
}

// Phase 2 templates

/// "Invalid " ++ detail
/// Example: invalidValue("chunk type") → "Invalid chunk type"
pub fn invalidValue(comptime detail: []const u8) *const [("Invalid " ++ detail).len:0]u8 {
    return "Invalid " ++ detail;
}

/// detail ++ " checksum mismatch"
/// Example: checksumMismatch("CRC-32") → "CRC-32 checksum mismatch"
pub fn checksumMismatch(comptime detail: []const u8) *const [(detail ++ " checksum mismatch").len:0]u8 {
    return detail ++ " checksum mismatch";
}

/// detail ++ " exceeds bounds"
/// Example: exceedsBounds("chunk size") → "chunk size exceeds bounds"
pub fn exceedsBounds(comptime detail: []const u8) *const [(detail ++ " exceeds bounds").len:0]u8 {
    return detail ++ " exceeds bounds";
}

// Tests
test "template output matches expected strings" {
    const std = @import("std");
    const testing = std.testing;

    // Tier 1
    try testing.expectEqualStrings("Failed to read PNG signature", failedToRead("PNG signature"));
    try testing.expectEqualStrings("File too small for valid ZIP", fileTooSmallFor("valid ZIP"));
    try testing.expectEqualStrings("Invalid PNG signature", invalidSignature("PNG"));
    try testing.expectEqualStrings("Missing IHDR chunk", missing("IHDR chunk"));
    try testing.expectEqualStrings("Failed to seek to chunk", failedToSeek("to chunk"));
    try testing.expectEqualStrings("Truncated PNG chunk", truncated("PNG chunk"));

    // Tier 2
    try testing.expectEqualStrings("Invalid PNG magic bytes", invalidMagic("PNG"));
    try testing.expectEqualStrings("Invalid GIF magic number", invalidMagicNumber("GIF"));
    try testing.expectEqualStrings("Failed to open file", failedToOpen("file"));
    try testing.expectEqualStrings("Failed to skip padding", failedToSkip("padding"));
    try testing.expectEqualStrings("Too many chunks", tooMany("chunks"));
    try testing.expectEqualStrings("Unsupported compression method", unsupported("compression method"));
    try testing.expectEqualStrings("Incomplete frame data", incomplete("frame data"));
    try testing.expectEqualStrings("Buffer too small for header", bufferTooSmallFor("header"));
    try testing.expectEqualStrings("No valid frames found", noValidXFound("frames"));
    try testing.expectEqualStrings("Unknown chunk type", unknown("chunk type"));
    try testing.expectEqualStrings("Empty file", empty("file"));

    // Tier 3
    try testing.expectEqualStrings("File too large for format detection", fileTooLargeFor("format detection"));
    try testing.expectEqualStrings("Failed to allocate memory for buffer", failedToAllocate("memory for buffer"));
    try testing.expectEqualStrings("Failed to stat file", failedToStat("file"));
    try testing.expectEqualStrings("Out of memory for JSON", outOfMemory("for JSON"));
    try testing.expectEqualStrings("Failed to get file size", failedToGet("file size"));
    try testing.expectEqualStrings("Invalid DWG signature (expected AC)", invalidSignatureExpected("DWG", "AC"));
    try testing.expectEqualStrings("Invalid PRPROJ signature (not gzip or XML)", invalidSignatureNot("PRPROJ", "gzip or XML"));
    try testing.expectEqualStrings("Zlib decompression failed", decompressionFailed("Zlib"));

    // Phase 2
    try testing.expectEqualStrings("Invalid chunk type", invalidValue("chunk type"));
    try testing.expectEqualStrings("CRC-32 checksum mismatch", checksumMismatch("CRC-32"));
    try testing.expectEqualStrings("chunk size exceeds bounds", exceedsBounds("chunk size"));
}

test "ValidationErrorCode.message round-trips all single-param templates" {
    const std = @import("std");
    const testing = std.testing;
    const ValidationErrorCode = @import("format_validation.zig").ValidationErrorCode;

    // Every single-param code must produce byte-identical output to the direct errmsg call
    try testing.expectEqualStrings(failedToRead("PNG signature"), ValidationErrorCode.failed_to_read.message("PNG signature"));
    try testing.expectEqualStrings(fileTooSmallFor("valid ZIP"), ValidationErrorCode.file_too_small.message("valid ZIP"));
    try testing.expectEqualStrings(invalidSignature("PNG"), ValidationErrorCode.invalid_signature.message("PNG"));
    try testing.expectEqualStrings(missing("IHDR chunk"), ValidationErrorCode.missing.message("IHDR chunk"));
    try testing.expectEqualStrings(failedToSeek("to chunk"), ValidationErrorCode.failed_to_seek.message("to chunk"));
    try testing.expectEqualStrings(truncated("PNG chunk"), ValidationErrorCode.truncated.message("PNG chunk"));
    try testing.expectEqualStrings(invalidMagic("PNG"), ValidationErrorCode.invalid_magic.message("PNG"));
    try testing.expectEqualStrings(invalidMagicNumber("GIF"), ValidationErrorCode.invalid_magic_number.message("GIF"));
    try testing.expectEqualStrings(failedToOpen("file"), ValidationErrorCode.failed_to_open.message("file"));
    try testing.expectEqualStrings(failedToSkip("padding"), ValidationErrorCode.failed_to_skip.message("padding"));
    try testing.expectEqualStrings(tooMany("chunks"), ValidationErrorCode.too_many.message("chunks"));
    try testing.expectEqualStrings(unsupported("compression method"), ValidationErrorCode.unsupported.message("compression method"));
    try testing.expectEqualStrings(incomplete("frame data"), ValidationErrorCode.incomplete.message("frame data"));
    try testing.expectEqualStrings(bufferTooSmallFor("header"), ValidationErrorCode.buffer_too_small.message("header"));
    try testing.expectEqualStrings(noValidXFound("frames"), ValidationErrorCode.no_valid_x_found.message("frames"));
    try testing.expectEqualStrings(unknown("chunk type"), ValidationErrorCode.unknown_element.message("chunk type"));
    try testing.expectEqualStrings(empty("file"), ValidationErrorCode.empty.message("file"));
    try testing.expectEqualStrings(fileTooLargeFor("format detection"), ValidationErrorCode.file_too_large.message("format detection"));
    try testing.expectEqualStrings(failedToAllocate("memory for buffer"), ValidationErrorCode.failed_to_allocate.message("memory for buffer"));
    try testing.expectEqualStrings(failedToStat("file"), ValidationErrorCode.failed_to_stat.message("file"));
    try testing.expectEqualStrings(outOfMemory("for JSON"), ValidationErrorCode.out_of_memory.message("for JSON"));
    try testing.expectEqualStrings(failedToGet("file size"), ValidationErrorCode.failed_to_get.message("file size"));
    try testing.expectEqualStrings(decompressionFailed("Zlib"), ValidationErrorCode.decompression_failed.message("Zlib"));
    try testing.expectEqualStrings(invalidValue("chunk type"), ValidationErrorCode.invalid_value.message("chunk type"));
    try testing.expectEqualStrings(checksumMismatch("CRC-32"), ValidationErrorCode.checksum_mismatch.message("CRC-32"));
    try testing.expectEqualStrings(exceedsBounds("chunk size"), ValidationErrorCode.exceeds_bounds.message("chunk size"));
}

test "ValidationErrorCode.message2 round-trips two-param templates" {
    const std = @import("std");
    const testing = std.testing;
    const ValidationErrorCode = @import("format_validation.zig").ValidationErrorCode;

    try testing.expectEqualStrings(
        invalidSignatureExpected("DWG", "AC"),
        ValidationErrorCode.invalid_signature_expected.message2("DWG", "AC"),
    );
    try testing.expectEqualStrings(
        invalidSignatureNot("PRPROJ", "gzip or XML"),
        ValidationErrorCode.invalid_signature_not.message2("PRPROJ", "gzip or XML"),
    );
}

test "ValidationResult helper methods set all fields correctly" {
    const std = @import("std");
    const testing = std.testing;
    const fv = @import("format_validation.zig");
    const ValidationResult = fv.ValidationResult;
    const ValidationErrorCode = fv.ValidationErrorCode;

    // invalidCode
    const r1 = ValidationResult.invalidCode(.png, .failed_to_read, "PNG signature");
    try testing.expect(!r1.is_valid);
    try testing.expectEqual(r1.format, .png);
    try testing.expectEqualStrings("Failed to read PNG signature", r1.error_message.?);
    try testing.expectEqual(r1.error_code.?, ValidationErrorCode.failed_to_read);
    try testing.expectEqualStrings("PNG signature", r1.error_detail.?);
    try testing.expectEqual(r1.validation_depth, .structural);

    // invalidCodeWithDepth
    const r2 = ValidationResult.invalidCodeWithDepth(.mp4, .truncated, "atom", .full);
    try testing.expect(!r2.is_valid);
    try testing.expectEqualStrings("Truncated atom", r2.error_message.?);
    try testing.expectEqual(r2.error_code.?, ValidationErrorCode.truncated);
    try testing.expectEqualStrings("atom", r2.error_detail.?);
    try testing.expectEqual(r2.validation_depth, .full);

    // invalidCodeMsg
    const r3 = ValidationResult.invalidCodeMsg(.dwg, .invalid_signature_expected, "DWG", "Invalid DWG signature (expected AC)");
    try testing.expect(!r3.is_valid);
    try testing.expectEqualStrings("Invalid DWG signature (expected AC)", r3.error_message.?);
    try testing.expectEqual(r3.error_code.?, ValidationErrorCode.invalid_signature_expected);
    try testing.expectEqualStrings("DWG", r3.error_detail.?);

    // Existing .invalid() leaves error_code = null (backward compat)
    const r4 = ValidationResult.invalid(.png, "some custom error");
    try testing.expect(!r4.is_valid);
    try testing.expectEqualStrings("some custom error", r4.error_message.?);
    try testing.expectEqual(r4.error_code, null);
    try testing.expectEqual(r4.error_detail, null);
}

test "ValidationErrorCode template_count" {
    const ValidationErrorCode = @import("format_validation.zig").ValidationErrorCode;
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 28), ValidationErrorCode.template_count);
}
