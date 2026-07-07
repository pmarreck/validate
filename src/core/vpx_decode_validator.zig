//! VP8/VP9 video deep validation using libvpx.
//!
//! libvpx is the WebM Project's reference decoder for VP8 and VP9. Unlike
//! the pure-Zig vp8_validator / vp9_syntax_validator which only parse frame
//! headers (and for VP8 the boolean-coded MB header), this module feeds each
//! frame through `vpx_codec_decode()` which performs full entropy decoding,
//! dequantization, inverse transform, motion compensation, loop filtering,
//! and frame reconstruction.
//!
//! Why this matters:
//! - MKV/WebM has NO per-chunk CRC on the codec payload. A random bit-flip
//!   inside a VP9 DCT region was slipping through at ~45% rate (the
//!   detection came from Opus in the companion audio track, not VP9).
//! - Pure-Zig VP9 syntax validation only covers the uncompressed header; a
//!   bit-flip in the compressed residual data sails through.
//! - libvpx surfaces corruption as `VPX_CODEC_CORRUPT_FRAME`,
//!   `VPX_CODEC_UNSUP_BITSTREAM`, or `VPX_CODEC_INVALID_PARAM`.
//!
//! libvpx API surface used:
//! - `vpx_codec_vp8_dx()` / `vpx_codec_vp9_dx()` — codec interface factories
//! - `vpx_codec_dec_init` — decoder construction (via the versioned _ver entry)
//! - `vpx_codec_decode` — submit one compressed frame
//! - `vpx_codec_destroy` — tear down
//! - `vpx_codec_err_to_string` — surface a human-readable error
//!
//! Reference: https://www.webmproject.org/docs/

const std = @import("std");

const vpx_c = @cImport({
    @cInclude("vpx/vpx_codec.h");
    @cInclude("vpx/vpx_decoder.h");
    @cInclude("vpx/vp8dx.h");
});

pub const VpxCodec = enum { vp8, vp9 };

pub const VpxDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,
    /// libvpx return code for the first error, or 0 if OK.
    vpx_errno: c_int,

    pub fn ok(frames: u32) VpxDecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .vpx_errno = 0,
        };
    }

    pub fn invalid(message: []const u8, frames: u32, err: c_int) VpxDecodeResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_decoded = frames,
            .vpx_errno = err,
        };
    }
};

/// Convert the libvpx C-string error into a Zig slice valid for the current
/// scope. The pointer returned by vpx_codec_err_to_string has static storage,
/// so the slice is safe to return across function boundaries.
fn vpxErrString(err: c_int) []const u8 {
    const c_str = vpx_c.vpx_codec_err_to_string(@intCast(err));
    if (c_str == null) return "unknown libvpx error";
    return std.mem.span(c_str);
}

/// Feed every frame through libvpx. A single decode failure fails the whole
/// stream — we treat VP8/VP9 corruption as unrecoverable for validation
/// purposes. `frames` must already be split into per-frame payloads (for
/// VP9 superframes, libvpx handles the index internally so a whole
/// superframe chunk works fine as one call).
pub fn validateFrames(codec: VpxCodec, frames: []const []const u8) VpxDecodeResult {
    if (frames.len == 0) {
        return VpxDecodeResult.invalid("No frames to decode", 0, 0);
    }

    // @cImport types vpx_codec_vp{8,9}_dx() as ?*const vpx_codec_iface_t,
    // even though the C header declares them non-null. Use orelse to
    // unwrap and pass the const pointer directly to the _ver initializer.
    const iface = switch (codec) {
        .vp8 => vpx_c.vpx_codec_vp8_dx() orelse return VpxDecodeResult.invalid(
            "vpx_codec_vp8_dx returned null",
            0,
            0,
        ),
        .vp9 => vpx_c.vpx_codec_vp9_dx() orelse return VpxDecodeResult.invalid(
            "vpx_codec_vp9_dx returned null",
            0,
            0,
        ),
    };

    var cfg: vpx_c.vpx_codec_dec_cfg_t = std.mem.zeroes(vpx_c.vpx_codec_dec_cfg_t);
    // Decode across cores. With CONFIG_MULTITHREAD=1, libvpx runs the loop filter
    // on a worker thread and parallelizes tile columns; the useful thread count is
    // stream-bounded, so cap it (beyond ~8 gives diminishing returns for a single
    // stream while each worker allocates frame buffers). File-level parallelism
    // (many files at once) is handled by the caller's worker pool.
    const cpu_count = std.Thread.getCpuCount() catch 1;
    cfg.threads = @intCast(@min(cpu_count, 8));

    var ctx: vpx_c.vpx_codec_ctx_t = std.mem.zeroes(vpx_c.vpx_codec_ctx_t);
    // Use the _ver entry point directly so we don't depend on the
    // vpx_codec_dec_init preprocessor macro which @cImport may drop.
    const init_ret = vpx_c.vpx_codec_dec_init_ver(
        &ctx,
        iface,
        &cfg,
        0,
        vpx_c.VPX_DECODER_ABI_VERSION,
    );
    if (init_ret != vpx_c.VPX_CODEC_OK) {
        return VpxDecodeResult.invalid(
            "vpx_codec_dec_init failed",
            0,
            @intCast(init_ret),
        );
    }
    defer _ = vpx_c.vpx_codec_destroy(&ctx);

    var decoded: u32 = 0;
    for (frames) |frame| {
        if (frame.len == 0) continue;
        const ret = vpx_c.vpx_codec_decode(
            &ctx,
            frame.ptr,
            @intCast(frame.len),
            null,
            0,
        );
        if (ret != vpx_c.VPX_CODEC_OK) {
            return VpxDecodeResult.invalid(
                vpxErrString(@intCast(ret)),
                decoded,
                @intCast(ret),
            );
        }
        // Drain any frames ready for display. VP8's decoder has built-in
        // error concealment — a corrupt frame can return VPX_CODEC_OK from
        // vpx_codec_decode while silently patching up coefficient mismatches.
        // The VP8D_GET_FRAME_CORRUPTED control queries whether the most
        // recent frame was internally flagged as corrupted; we surface that
        // as a decode failure.
        var iter: vpx_c.vpx_codec_iter_t = null;
        while (vpx_c.vpx_codec_get_frame(&ctx, &iter) != null) {
            var corrupted: c_int = 0;
            const cret = vpx_c.vpx_codec_control_(
                &ctx,
                vpx_c.VP8D_GET_FRAME_CORRUPTED,
                &corrupted,
            );
            if (cret == vpx_c.VPX_CODEC_OK and corrupted != 0) {
                return VpxDecodeResult.invalid(
                    "libvpx internal corruption flag set",
                    decoded,
                    @intCast(vpx_c.VPX_CODEC_CORRUPT_FRAME),
                );
            }
        }
        decoded += 1;
    }

    return VpxDecodeResult.ok(decoded);
}

// ============ Tests ============

test "libvpx rejects empty frame set" {
    const empty: []const []const u8 = &.{};
    const result = validateFrames(.vp9, empty);
    try std.testing.expect(!result.valid);
}

test "libvpx rejects garbage VP9 bytes" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
    const frames = [_][]const u8{&garbage};
    const result = validateFrames(.vp9, &frames);
    try std.testing.expect(!result.valid);
}

test "libvpx rejects garbage VP8 bytes" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };
    const frames = [_][]const u8{&garbage};
    const result = validateFrames(.vp8, &frames);
    try std.testing.expect(!result.valid);
}
