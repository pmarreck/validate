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
}
