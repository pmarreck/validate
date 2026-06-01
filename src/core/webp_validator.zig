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
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

/// Threshold for warning about large image files (200MB)
const large_image_threshold: u64 = 200 * 1024 * 1024;

const c = @cImport({
    @cInclude("webp/decode.h");
    @cInclude("webp/types.h");
    @cInclude("webp/demux.h");
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
pub fn validateWebpDeep(source: *FileSource) WebpValidationResult {
    const file_size = source.getEndPos() catch {
        return WebpValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // Track large files for warning (but don't reject them)
    const is_large_file = file_size > large_image_threshold;

    if (file_size < 12) {
        return WebpValidationResult.invalid("File too small");
    }

    // Use mmap slice if available, else allocate and read
    var heap_buf: ?[*]u8 = null;
    defer if (heap_buf) |b| std.c.free(b);
    const buf_slice: []const u8 = if (source.getMappedSlice()) |m| m else blk: {
        const buffer = std.c.malloc(file_size) orelse {
            return WebpValidationResult.invalid("Memory allocation failed");
        };
        heap_buf = @ptrCast(buffer);
        const slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
        source.seekTo(0) catch return WebpValidationResult.invalid(errmsg.failedToRead("seek"));
        const bytes_read = source.readAll(slice) catch {
            return WebpValidationResult.invalid(errmsg.failedToRead("file"));
        };
        if (bytes_read != file_size) {
            return WebpValidationResult.invalid(errmsg.incomplete("file read"));
        }
        break :blk slice;
    };

    const result = validateWebpDeepFromBuffer(buf_slice);

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

    // Probe features to route animated WebP (VP8X+ANIM/ANMF) to the demux
    // path. The simple WebPDecode* APIs cannot decode animation frames and
    // return NULL, which previously surfaced as a false "corrupted data".
    var features: c.WebPBitstreamFeatures = undefined;
    if (c.WebPGetFeatures(data.ptr, data.len, &features) != c.VP8_STATUS_OK) {
        return WebpValidationResult.invalid("Invalid WebP header");
    }
    if (features.has_animation != 0) {
        return validateAnimatedWebp(data);
    }

    const width: c_int = features.width;
    const height: c_int = features.height;

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

/// Validate an animated WebP by demuxing and fully decoding every ANMF frame.
/// The simple decoder only handles a single still image; animation requires
/// walking each frame's sub-bitstream and decoding it for real per-frame
/// integrity (not just a header skim).
fn validateAnimatedWebp(data: []const u8) WebpValidationResult {
    const wd: c.WebPData = .{ .bytes = data.ptr, .size = data.len };
    const demux = c.WebPDemux(&wd) orelse {
        return WebpValidationResult.invalid("WebP demux failed - corrupted animation container");
    };
    defer c.WebPDemuxDelete(demux);

    const canvas_w = c.WebPDemuxGetI(demux, c.WEBP_FF_CANVAS_WIDTH);
    const canvas_h = c.WebPDemuxGetI(demux, c.WEBP_FF_CANVAS_HEIGHT);
    if (canvas_w == 0 or canvas_h == 0 or canvas_w > 16384 or canvas_h > 16384) {
        return WebpValidationResult.invalid("Invalid animated WebP canvas dimensions");
    }
    const frame_count = c.WebPDemuxGetI(demux, c.WEBP_FF_FRAME_COUNT);
    if (frame_count == 0) {
        return WebpValidationResult.invalid("Animated WebP declares zero frames");
    }

    var iter: c.WebPIterator = undefined;
    if (c.WebPDemuxGetFrame(demux, 1, &iter) == 0) {
        return WebpValidationResult.invalid("WebP demux failed - cannot read first frame");
    }
    defer c.WebPDemuxReleaseIterator(&iter);

    var decoded_frames: u32 = 0;
    while (true) {
        // Each iter.fragment is one frame's complete WebP sub-bitstream.
        var fw: c_int = 0;
        var fh: c_int = 0;
        if (c.WebPGetInfo(iter.fragment.bytes, iter.fragment.size, &fw, &fh) == 0) {
            return WebpValidationResult.invalid("Animated WebP frame has invalid header");
        }
        if (fw <= 0 or fh <= 0 or fw > 16384 or fh > 16384) {
            return WebpValidationResult.invalid("Animated WebP frame dimensions out of range");
        }
        const out_size: u64 = @as(u64, @intCast(fw)) * @as(u64, @intCast(fh)) * 4;
        if (out_size > 512 * 1024 * 1024) {
            return WebpValidationResult.invalid("Animated WebP frame too large to decode");
        }
        const out = std.c.malloc(out_size) orelse {
            return WebpValidationResult.invalid("Memory allocation failed for frame decode");
        };
        const ok = c.WebPDecodeRGBAInto(iter.fragment.bytes, iter.fragment.size, @ptrCast(out), out_size, fw * 4);
        std.c.free(out);
        if (ok == null) {
            return WebpValidationResult.invalid("Animated WebP frame decode failed - corrupted data");
        }
        decoded_frames += 1;
        if (c.WebPDemuxNextFrame(&iter) == 0) break;
    }

    // The demuxer reports frame_count from the container; ensure we actually
    // walked+decoded every declared frame (no silent truncation).
    if (decoded_frames != @as(u32, @intCast(frame_count))) {
        return WebpValidationResult.invalid("Animated WebP frame count mismatch (truncated animation)");
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

test "reject too small buffer" {
    const tiny = [_]u8{ 0x00, 0x01, 0x02 };
    const result = validateWebpDeepFromBuffer(&tiny);
    try std.testing.expect(!result.valid);
}

test "valid animated WebP decodes all frames" {
    // Tiny 2-frame VP8X+ANIM WebP (img2webp). The old simple-decoder path
    // returned "corrupted data" on animation; the demux path validates clean.
    // Oracle cross-check: `webpinfo` reports "No error detected" on this file.
    // @embedFile (not a runtime path) so the nix sandbox test actually runs it.
    const data = @embedFile("fixtures/anim_tiny.webp");
    const result = validateWebpDeepFromBuffer(data);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
}

test "corrupted animated WebP frame is detected" {
    // Same fixture with bytes flipped inside frame 2's VP8L payload. Oracle
    // cross-check: `webpinfo` reports "Errors detected" on this file too, so
    // it is genuine corruption (not validate being arbitrarily strict). The
    // per-frame demux decode must catch it instead of falsely passing.
    const data = @embedFile("fixtures/anim_tiny_corrupt.webp");
    const result = validateWebpDeepFromBuffer(data);
    try std.testing.expect(!result.valid);
}

test "valid WebP from ground truth sample" {
    var source = FileSource.open("ground_truth_examples/webp/sample.webp") catch return;
    defer source.close();
    const result = validateWebpDeep(&source);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
}

test "valid WebP from ground truth google_gallery_1" {
    var source = FileSource.open("ground_truth_examples/webp/google_gallery_1.webp") catch return;
    defer source.close();
    const result = validateWebpDeep(&source);
    try std.testing.expect(result.valid);
}
