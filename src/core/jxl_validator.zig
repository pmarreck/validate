//! Deep JPEG-XL validation using libjxl.
//!
//! This module provides comprehensive JPEG-XL validation by decoding the
//! compressed bitstream to verify integrity, but discarding pixel output.
//!
//! Uses libjxl's JxlDecoder API which validates:
//! - Container format (BMFF box structure or naked codestream)
//! - Modular/VarDCT bitstream integrity
//! - ANS entropy coding correctness
//! - Squeeze/transform validity
//! - ICC profile integrity
//! - Image dimension consistency
//!
//! Performance optimization: Uses JxlDecoderSetImageOutCallback with a no-op
//! callback to decode and validate pixel data without allocating a massive
//! output buffer. The decode happens (validating the compressed data), but
//! decoded rows are immediately discarded rather than stored.
//!
//! Single-threaded decode avoids thread explosion when validating many files
//! concurrently.

const std = @import("std");
const builtin = @import("builtin");
const errmsg = @import("error_messages.zig");

/// Threshold for warning about large image files (200MB)
const large_image_threshold: u64 = 200 * 1024 * 1024;

const c = @cImport({
    @cInclude("jxl/decode.h");
    @cInclude("jxl/types.h");
    @cInclude("jxl/thread_parallel_runner.h");
});

/// Result of deep JPEG-XL validation
pub const JxlValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    warning_message: ?[]const u8 = null,

    pub fn ok() JxlValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = null };
    }

    pub fn okWithWarning(warning: []const u8) JxlValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = warning };
    }

    pub fn invalid(message: []const u8) JxlValidationResult {
        return .{ .valid = false, .error_message = message, .warning_message = null };
    }
};

/// Validate a JPEG-XL file by attempting full decompression.
/// Returns validation result with error details if invalid.
pub fn validateJxlDeep(file_path: []const u8) JxlValidationResult {
    // Open file using Zig's stdlib
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => JxlValidationResult.invalid("File not found"),
            error.AccessDenied => JxlValidationResult.invalid("Access denied"),
            else => JxlValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return JxlValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // Track large files for warning (but don't reject them)
    const is_large_file = file_size > large_image_threshold;

    if (file_size < 2) {
        return JxlValidationResult.invalid("File too small");
    }

    // Allocate buffer
    const buffer = std.c.malloc(file_size) orelse {
        return JxlValidationResult.invalid("Memory allocation failed");
    };
    defer std.c.free(buffer);

    // Read entire file
    const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
    const bytes_read = file.readAll(buf_slice) catch {
        return JxlValidationResult.invalid(errmsg.failedToRead("file"));
    };
    if (bytes_read != file_size) {
        return JxlValidationResult.invalid(errmsg.incomplete("file read"));
    }

    const result = validateJxlDeepFromBuffer(buf_slice);

    // Add warning for large files if validation passed
    if (result.valid and is_large_file) {
        return JxlValidationResult.okWithWarning("Large image file (>200MB)");
    }
    return result;
}

/// Validate JPEG-XL from memory buffer.
pub fn validateJxlDeepFromBuffer(data: []const u8) JxlValidationResult {
    if (data.len < 2) {
        return JxlValidationResult.invalid("File too small");
    }

    // Create parallel runner - use single thread to avoid thread explosion
    // when validating many files concurrently from the main thread pool
    const runner = c.JxlThreadParallelRunnerCreate(null, 1);
    if (runner == null) {
        return JxlValidationResult.invalid("Failed to create parallel runner");
    }
    defer c.JxlThreadParallelRunnerDestroy(runner);

    // Create decoder
    const dec = c.JxlDecoderCreate(null);
    if (dec == null) {
        return JxlValidationResult.invalid("Failed to create JXL decoder");
    }
    defer c.JxlDecoderDestroy(dec);

    // Set parallel runner for multithreaded decoding
    if (c.JxlDecoderSetParallelRunner(dec, c.JxlThreadParallelRunner, runner) != c.JXL_DEC_SUCCESS) {
        return JxlValidationResult.invalid("Failed to set parallel runner");
    }

    // Subscribe to events we need to handle for validation
    // We need FULL_IMAGE to validate that all compressed data decodes correctly
    const events_wanted: c_int = c.JXL_DEC_BASIC_INFO | c.JXL_DEC_FULL_IMAGE;
    if (c.JxlDecoderSubscribeEvents(dec, events_wanted) != c.JXL_DEC_SUCCESS) {
        return JxlValidationResult.invalid("Failed to subscribe to decoder events");
    }

    // Set input buffer
    if (c.JxlDecoderSetInput(dec, data.ptr, data.len) != c.JXL_DEC_SUCCESS) {
        return JxlValidationResult.invalid("Failed to set input buffer");
    }
    c.JxlDecoderCloseInput(dec);

    // Process the decoding - decode to validate but discard output via callback
    var basic_info: c.JxlBasicInfo = undefined;
    var have_basic_info = false;

    while (true) {
        const status = c.JxlDecoderProcessInput(dec);

        switch (status) {
            c.JXL_DEC_ERROR => {
                return JxlValidationResult.invalid("JXL decode error - corrupted data");
            },
            c.JXL_DEC_NEED_MORE_INPUT => {
                return JxlValidationResult.invalid("JXL decode incomplete - truncated file");
            },
            c.JXL_DEC_BASIC_INFO => {
                if (c.JxlDecoderGetBasicInfo(dec, &basic_info) != c.JXL_DEC_SUCCESS) {
                    return JxlValidationResult.invalid(errmsg.failedToGet("basic info"));
                }
                have_basic_info = true;

                // Validate dimensions
                if (basic_info.xsize == 0 or basic_info.ysize == 0) {
                    return JxlValidationResult.invalid("Invalid image dimensions (zero)");
                }
                if (basic_info.xsize > 65535 or basic_info.ysize > 65535) {
                    return JxlValidationResult.invalid("Image dimensions too large");
                }
            },
            c.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
                // Decoder needs output - use callback to discard rows immediately
                // This validates decode without allocating huge output buffer
                // Pixel format: grayscale 8-bit (smallest possible, still validates decode)
                const pixel_format = c.JxlPixelFormat{
                    .num_channels = 1, // Grayscale - smaller than RGBA
                    .data_type = c.JXL_TYPE_UINT8,
                    .endianness = c.JXL_NATIVE_ENDIAN,
                    .@"align" = 0,
                };

                // Set callback that discards decoded rows immediately
                // The decode still happens (validating the data), but output is thrown away
                if (c.JxlDecoderSetImageOutCallback(
                    dec,
                    &pixel_format,
                    discardPixelCallback,
                    null, // No userdata needed
                ) != c.JXL_DEC_SUCCESS) {
                    return JxlValidationResult.invalid("Failed to set output callback");
                }
            },
            c.JXL_DEC_FULL_IMAGE => {
                // Successfully decoded and validated entire image
                // Continue to get JXL_DEC_SUCCESS (for multi-frame images)
            },
            c.JXL_DEC_SUCCESS => {
                // All done successfully - every byte validated as renderable
                if (!have_basic_info) {
                    return JxlValidationResult.invalid("Decode succeeded but no image info");
                }
                return JxlValidationResult.ok();
            },
            else => {
                // Other events we don't care about (color encoding, preview, etc.)
                // Just continue processing
            },
        }
    }
}

/// Callback that discards decoded pixel rows.
/// libjxl calls this for each decoded row - we simply do nothing with the data.
/// This validates the decode (compressed data is processed) but avoids memory allocation.
fn discardPixelCallback(
    _: ?*anyopaque, // opaque userdata (unused)
    _: usize, // x position
    _: usize, // y position
    _: usize, // num_pixels
    _: ?*const anyopaque, // pixel data pointer (discarded)
) callconv(.c) void {
    // Intentionally empty - discard all decoded pixels
    // The important thing is that the decode happened and validated the data
}

// Tests
test "reject invalid data with expected stderr" {
    // Test that invalid data is rejected
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateJxlDeepFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
    // Note: stderr message checking removed - libjxl doesn't output messages in release mode
}

test "reject truncated JXL with expected stderr" {
    // JXL signature but nothing else
    // JPEG-XL codestream starts with 0xFF 0x0A
    const truncated = [_]u8{ 0xFF, 0x0A, 0x00, 0x00 };
    const result = validateJxlDeepFromBuffer(&truncated);
    try std.testing.expect(!result.valid);
    // Note: stderr message checking removed - libjxl doesn't output messages in release mode
}

test "reject container with truncated box and expected stderr" {
    // JPEG-XL container starts with ftyp box: 00 00 00 0C 4A 58 4C 20
    const truncated_container = [_]u8{
        0x00, 0x00, 0x00, 0x0C, // box size
        'J', 'X', 'L', ' ', // box type
        0x00, 0x00, // truncated data
    };
    const result = validateJxlDeepFromBuffer(&truncated_container);
    try std.testing.expect(!result.valid);
    // Note: stderr message checking removed - libjxl doesn't output messages in release mode
}
