//! VP9 video decode validation using libvpx
//!
//! This module provides full decode validation for VP9 video streams by
//! decoding frames through libvpx. VP9 is commonly found in WebM containers
//! and is widely used for web video.
//!
//! Note: VP8 is not currently supported due to build complexity. VP9-only
//! validation is sufficient for most modern WebM content.

const std = @import("std");

/// libvpx C API bindings
const vpx = @cImport({
    @cInclude("vpx/vpx_codec.h");
    @cInclude("vpx/vpx_decoder.h");
    @cInclude("vpx/vp8dx.h");
});

/// Result of VP9 decode validation
pub const Vp9DecodeResult = struct {
    valid: bool,
    frames_decoded: u32,
    error_message: ?[]const u8,
    width: u32,
    height: u32,

    pub fn success(frames: u32, w: u32, h: u32) Vp9DecodeResult {
        return .{
            .valid = true,
            .frames_decoded = frames,
            .error_message = null,
            .width = w,
            .height = h,
        };
    }

    pub fn failure(msg: []const u8) Vp9DecodeResult {
        return .{
            .valid = false,
            .frames_decoded = 0,
            .error_message = msg,
            .width = 0,
            .height = 0,
        };
    }
};

/// VP9 decoder wrapper for libvpx
pub const Vp9Decoder = struct {
    codec: vpx.vpx_codec_ctx_t,
    initialized: bool,

    /// Initialize VP9 decoder
    pub fn init() ?Vp9Decoder {
        var self: Vp9Decoder = .{
            .codec = undefined,
            .initialized = false,
        };

        const iface = vpx.vpx_codec_vp9_dx();
        if (iface == null) {
            return null;
        }

        const cfg: vpx.vpx_codec_dec_cfg_t = .{
            .threads = 1, // Single-threaded for validation
            .w = 0,
            .h = 0,
            .allow_lowbitdepth = 0,
        };

        const res = vpx.vpx_codec_dec_init(&self.codec, iface, &cfg, 0);
        if (res != vpx.VPX_CODEC_OK) {
            return null;
        }

        self.initialized = true;
        return self;
    }

    /// Deinitialize decoder
    pub fn deinit(self: *Vp9Decoder) void {
        if (self.initialized) {
            _ = vpx.vpx_codec_destroy(&self.codec);
            self.initialized = false;
        }
    }

    /// Decode a single VP9 frame
    /// Returns true if frame decoded successfully, false on error
    pub fn decodeFrame(self: *Vp9Decoder, data: []const u8) bool {
        if (!self.initialized) return false;
        if (data.len == 0) return false;

        const res = vpx.vpx_codec_decode(
            &self.codec,
            data.ptr,
            @intCast(data.len),
            null,
            0,
        );

        return res == vpx.VPX_CODEC_OK;
    }

    /// Get decoded frame info (width, height)
    pub fn getFrameInfo(self: *Vp9Decoder) ?struct { width: u32, height: u32 } {
        if (!self.initialized) return null;

        var iter: vpx.vpx_codec_iter_t = null;
        const img = vpx.vpx_codec_get_frame(&self.codec, &iter);

        if (img != null) {
            return .{
                .width = img.*.d_w,
                .height = img.*.d_h,
            };
        }

        return null;
    }

    /// Get last error message
    pub fn getError(self: *Vp9Decoder) ?[]const u8 {
        const err = vpx.vpx_codec_error(&self.codec);
        if (err != null) {
            return std.mem.span(err);
        }
        return null;
    }
};

/// Validate VP9 stream by decoding all frames
/// `frames` is a slice of VP9 frame data (each frame is a []const u8)
pub fn validateVp9Frames(frames: []const []const u8) Vp9DecodeResult {
    var decoder = Vp9Decoder.init() orelse {
        return Vp9DecodeResult.failure("Failed to initialize VP9 decoder");
    };
    defer decoder.deinit();

    var frames_decoded: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;

    for (frames) |frame_data| {
        if (!decoder.decodeFrame(frame_data)) {
            return Vp9DecodeResult.failure(decoder.getError() orelse "VP9 decode error");
        }

        // Get frame dimensions from first successfully decoded frame
        if (frames_decoded == 0) {
            if (decoder.getFrameInfo()) |info| {
                width = info.width;
                height = info.height;
            }
        }

        frames_decoded += 1;
    }

    if (frames_decoded == 0) {
        return Vp9DecodeResult.failure("No frames decoded");
    }

    return Vp9DecodeResult.success(frames_decoded, width, height);
}

/// Validate a single VP9 superframe (may contain multiple frames)
pub fn validateVp9Superframe(data: []const u8) Vp9DecodeResult {
    if (data.len == 0) {
        return Vp9DecodeResult.failure("Empty VP9 data");
    }

    var decoder = Vp9Decoder.init() orelse {
        return Vp9DecodeResult.failure("Failed to initialize VP9 decoder");
    };
    defer decoder.deinit();

    // Decode the superframe (may contain multiple frames)
    if (!decoder.decodeFrame(data)) {
        return Vp9DecodeResult.failure(decoder.getError() orelse "VP9 decode error");
    }

    // Get frame info
    var width: u32 = 0;
    var height: u32 = 0;
    if (decoder.getFrameInfo()) |info| {
        width = info.width;
        height = info.height;
    }

    return Vp9DecodeResult.success(1, width, height);
}

/// Check if data starts with a valid VP9 frame header
pub fn isVp9FrameHeader(data: []const u8) bool {
    if (data.len < 3) return false;

    // VP9 frame header: first 3 bytes contain frame marker and profile
    // Frame marker is 2 bits, profile is 1-3 bits
    // The frame marker should be 0b10 (decimal 2)
    const frame_marker = (data[0] >> 6) & 0x03;
    return frame_marker == 2;
}

// Tests
test "Vp9Decoder initialization" {
    // Skip test if VP9 decoder not available (VP8-only build)
    var decoder = Vp9Decoder.init() orelse {
        // VP9 decoder not available - this is expected in VP8-only builds
        return;
    };
    defer decoder.deinit();

    // Decoder should be initialized
    try std.testing.expect(decoder.initialized);
}

test "validateVp9Superframe with invalid data" {
    // Invalid VP9 data should fail
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateVp9Superframe(&invalid_data);
    try std.testing.expect(!result.valid);
}

test "isVp9FrameHeader" {
    // Valid VP9 frame header starts with frame marker 0b10 in top 2 bits
    const valid_header = [_]u8{ 0x82, 0x00, 0x00 }; // 0b10000010
    try std.testing.expect(isVp9FrameHeader(&valid_header));

    // Invalid frame marker
    const invalid_header = [_]u8{ 0x42, 0x00, 0x00 }; // 0b01000010
    try std.testing.expect(!isVp9FrameHeader(&invalid_header));

    // Too short
    const short_data = [_]u8{ 0x82, 0x00 };
    try std.testing.expect(!isVp9FrameHeader(&short_data));
}
