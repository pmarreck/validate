//! Deep WebP validation using libwebp.
//!
//! This module provides comprehensive WebP validation by actually decompressing
//! the image data and detecting any errors in the compressed stream.
//!
//! Uses libwebp's WebPDecode API which validates:
//! - VP8/VP8L bitstream integrity
//! - Huffman/arithmetic coding correctness
//! - Transform validity (lossy DCT, lossless filters)
//! - Image dimension consistency

const std = @import("std");
const builtin = @import("builtin");
const errmsg = @import("error_messages.zig");

/// Threshold for warning about large image files (200MB)
const large_image_threshold: u64 = 200 * 1024 * 1024;

const c = @cImport({
    @cInclude("webp/decode.h");
    @cInclude("webp/types.h");
});

/// Result of deep WebP validation
pub const WebpValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    warning_message: ?[]const u8 = null,

    pub fn ok() WebpValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = null };
    }

    pub fn okWithWarning(warning: []const u8) WebpValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = warning };
    }

    pub fn invalid(message: []const u8) WebpValidationResult {
        return .{ .valid = false, .error_message = message, .warning_message = null };
    }
};

/// Validate a WebP file by attempting full decompression.
/// Returns validation result with error details if invalid.
pub fn validateWebpDeep(file_path: []const u8) WebpValidationResult {
    // Open file using Zig's stdlib
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => WebpValidationResult.invalid("File not found"),
            error.AccessDenied => WebpValidationResult.invalid("Access denied"),
            else => WebpValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return WebpValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // Track large files for warning (but don't reject them)
    const is_large_file = file_size > large_image_threshold;

    if (file_size < 12) {
        return WebpValidationResult.invalid("File too small");
    }

    // Allocate buffer
    const buffer = std.c.malloc(file_size) orelse {
        return WebpValidationResult.invalid("Memory allocation failed");
    };
    defer std.c.free(buffer);

    // Read entire file
    const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
    const bytes_read = file.readAll(buf_slice) catch {
        return WebpValidationResult.invalid(errmsg.failedToRead("file"));
    };
    if (bytes_read != file_size) {
        return WebpValidationResult.invalid(errmsg.incomplete("file read"));
    }

    const result = validateWebpDeepFromBuffer(buf_slice);

    // Add warning for large files if validation passed
    if (result.valid and is_large_file) {
        return WebpValidationResult.okWithWarning("Large image file (>200MB)");
    }
    return result;
}

/// Validate WebP from memory buffer.
pub fn validateWebpDeepFromBuffer(data: []const u8) WebpValidationResult {
    if (data.len < 12) {
        return WebpValidationResult.invalid("File too small");
    }

    // First, get the image dimensions to validate the header
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.WebPGetInfo(data.ptr, data.len, &width, &height) == 0) {
        return WebpValidationResult.invalid("Invalid WebP header");
    }

    // Validate dimensions are reasonable
    if (width <= 0 or height <= 0) {
        return WebpValidationResult.invalid("Invalid image dimensions");
    }
    if (width > 16384 or height > 16384) {
        return WebpValidationResult.invalid("Image dimensions too large");
    }

    // Calculate output size and check for overflow
    const pixel_count: u64 = @as(u64, @intCast(width)) * @as(u64, @intCast(height));
    const output_size = pixel_count * 4; // RGBA
    if (output_size > 512 * 1024 * 1024) { // 512 MiB limit
        return WebpValidationResult.invalid("Decoded image too large");
    }

    // Allocate output buffer for decoded pixels
    const output_buffer = std.c.malloc(output_size) orelse {
        return WebpValidationResult.invalid("Memory allocation failed for decode");
    };
    defer std.c.free(output_buffer);

    // Attempt full decode to RGBA
    const stride: c_int = width * 4;
    const decoded = c.WebPDecodeRGBAInto(
        data.ptr,
        data.len,
        @ptrCast(output_buffer),
        output_size,
        stride,
    );

    if (decoded == null) {
        return WebpValidationResult.invalid("WebP decode failed - corrupted data");
    }

    return WebpValidationResult.ok();
}

// Tests
test "reject invalid data" {
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateWebpDeepFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
}

test "reject truncated WebP" {
    // Just RIFF header, nothing else
    const truncated = [_]u8{ 'R', 'I', 'F', 'F', 0x00, 0x00, 0x00, 0x00, 'W', 'E', 'B', 'P' };
    const result = validateWebpDeepFromBuffer(&truncated);
    try std.testing.expect(!result.valid);
}
