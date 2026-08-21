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
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return validateFramesWithThreads(codec, frames, @intCast(@min(cpu_count, 8)));
}

/// Core decode: feed every frame through one libvpx decoder using `threads`
/// internal worker threads. The segment-parallel path calls this with threads=1
/// (segment-level parallelism fills the cores); the plain sequential path uses a
/// modest internal count.
pub fn validateFramesWithThreads(codec: VpxCodec, frames: []const []const u8, threads: u32) VpxDecodeResult {
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
    cfg.threads = threads;

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

// ---- Keyframe-segment-parallel decode ----------------------------------------

/// MSB-first bit reader over a byte slice (VP9 uncompressed-header parsing).
const BitReader = struct {
    data: []const u8,
    byte: usize = 0,
    bit: u3 = 0,

    fn read(self: *BitReader, n: u4) u32 {
        var v: u32 = 0;
        var i: u4 = 0;
        while (i < n) : (i += 1) {
            if (self.byte < self.data.len) {
                const shift: u3 = 7 - self.bit;
                const b: u32 = (self.data[self.byte] >> shift) & 1;
                v = (v << 1) | b;
            } else {
                v <<= 1; // past end → read as 0
            }
            if (self.bit == 7) {
                self.bit = 0;
                self.byte += 1;
            } else {
                self.bit += 1;
            }
        }
        return v;
    }
};

/// True if `frame` begins a keyframe — a resync point that resets all references,
/// so the following inter frames only reference within its GOP. Splitting the
/// stream at keyframes yields independently-decodable segments.
fn isKeyframe(codec: VpxCodec, frame: []const u8) bool {
    if (frame.len < 3) return false;
    switch (codec) {
        // VP8 frame tag (24-bit LE); bit 0 of byte 0 == 0 → key frame.
        .vp8 => return (frame[0] & 0x01) == 0,
        // VP9 uncompressed header: frame_marker(2)=2, profile bits (+reserved if
        // profile 3), show_existing_frame(1) (a repeat, not a key frame), then
        // frame_type(1): 0 = KEY_FRAME.
        .vp9 => {
            var br = BitReader{ .data = frame };
            if (br.read(2) != 2) return false;
            const p_low = br.read(1);
            const p_high = br.read(1);
            if (((p_high << 1) | p_low) == 3) _ = br.read(1); // reserved_zero
            if (br.read(1) == 1) return false; // show_existing_frame
            return br.read(1) == 0; // frame_type == KEY_FRAME
        },
    }
}

/// Anonymous-memory budget for concurrent libvpx decoder instances during
/// segment-parallel decode. Each VP9 decoder owns a reference-frame pool
/// (8 ref slots + working/new frames ≈ 12 YUV 4:2:0 buffers) whose size
/// scales with frame area; bounding the instance count by this budget keeps
/// whole-file validation inside the streaming memory ceiling (512MiB for
/// 2GiB+ video, tests/cli/streaming_ceiling) regardless of host core count.
const decoder_memory_budget_bytes: u64 = 256 * 1024 * 1024;
const yuv420_buffers_per_decoder: u64 = 12;

/// Max concurrent libvpx decoder instances that fit the anonymous-memory
/// budget for the given frame dimensions (0 → assume 1080p; dims clamped to
/// the VP9 maximum of 65536 so hostile track headers cannot overflow).
pub fn maxDecodersForDims(width: u64, height: u64) usize {
    const w: u64 = @min(if (width == 0) 1920 else width, 65536);
    const h: u64 = @min(if (height == 0) 1080 else height, 65536);
    const yuv420_bytes = w * h * 3 / 2;
    const per_decoder = yuv420_bytes * yuv420_buffers_per_decoder;
    const n = decoder_memory_budget_bytes / per_decoder;
    return @intCast(@max(n, 1));
}

const SegCtx = struct {
    codec: VpxCodec,
    frames: []const []const u8,
    bounds: []const usize, // segment i = frames[bounds[i]..bounds[i+1]]
    next: std.atomic.Value(usize),
    results: []VpxDecodeResult,
    /// libvpx-internal worker threads per decoder instance (row-mt/tile
    /// threading). >1 when the decoder-instance count is memory-budget-capped
    /// below the core count, so idle cores still help inside each instance.
    internal_threads: u32,
};

/// Worker: pull segment indices off the shared counter and decode each with
/// its own libvpx instance (segment-level parallelism fills the cores; each
/// instance may additionally use internal row-mt threads when instances are
/// memory-capped below the core count).
fn segWorker(ctx: *SegCtx) void {
    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.results.len) break;
        const seg = ctx.frames[ctx.bounds[i]..ctx.bounds[i + 1]];
        ctx.results[i] = validateFramesWithThreads(ctx.codec, seg, ctx.internal_threads);
    }
}

/// Validate a VP8/VP9 stream by decoding keyframe-delimited segments in parallel
/// across cores. Every frame is still fully decoded and corruption-checked — the
/// work is merely partitioned. The verdict is identical to a sequential decode:
/// keyframes reset all references, so each segment is independently decodable,
/// and any segment's corruption fails the whole stream. Falls back to sequential
/// for short streams, a single segment, or on any allocation/spawn failure.
pub fn validateFramesParallel(
    allocator: std.mem.Allocator,
    codec: VpxCodec,
    frames: []const []const u8,
) VpxDecodeResult {
    return validateFramesParallelBudget(allocator, codec, frames, std.math.maxInt(usize));
}

/// validateFramesParallel with the decoder-instance count additionally capped
/// by `max_decoders` — the anonymous-memory budget from maxDecodersForDims.
/// Verdict is identical for any cap ≥ 1; only the fan-out width changes.
pub fn validateFramesParallelBudget(
    allocator: std.mem.Allocator,
    codec: VpxCodec,
    frames: []const []const u8,
    max_decoders: usize,
) VpxDecodeResult {
    if (frames.len == 0) return VpxDecodeResult.invalid("No frames to decode", 0, 0);

    var bounds: std.ArrayListUnmanaged(usize) = .empty;
    defer bounds.deinit(allocator);
    bounds.append(allocator, 0) catch return validateFrames(codec, frames);
    for (frames, 0..) |f, i| {
        if (i == 0) continue;
        if (isKeyframe(codec, f)) {
            bounds.append(allocator, i) catch return validateFrames(codec, frames);
        }
    }
    bounds.append(allocator, frames.len) catch return validateFrames(codec, frames);
    const num_segs = bounds.items.len - 1;

    // With only a few segments, 1-thread-per-segment loses to internal libvpx
    // threading over the whole stream (uneven segment sizes stall on the largest),
    // so fall back there; segment-parallel wins once there are enough segments to
    // fill the cores. Short streams likewise aren't worth the fan-out.
    const min_frames_for_parallel = 64;
    const min_segments_for_parallel = 4;
    if (num_segs < min_segments_for_parallel or frames.len < min_frames_for_parallel) {
        return validateFrames(codec, frames);
    }

    const cpu = std.Thread.getCpuCount() catch 1;
    // Bound by segment count and a memory ceiling (each decoder allocs frame buffers).
    const n_threads = @min(@min(@min(cpu, num_segs), 64), @max(max_decoders, 1));
    // When the memory budget caps instances below the core count, spend the
    // idle cores INSIDE each instance via libvpx row-mt threading (worker
    // state is small next to a reference-frame pool). Capped at 4: VP9 row-mt
    // scaling flattens beyond that at common resolutions.
    const internal_threads: u32 = @intCast(@min(@max(cpu / n_threads, 1), 4));

    const results = allocator.alloc(VpxDecodeResult, num_segs) catch return validateFrames(codec, frames);
    defer allocator.free(results);

    var ctx = SegCtx{
        .codec = codec,
        .frames = frames,
        .bounds = bounds.items,
        .next = std.atomic.Value(usize).init(0),
        .results = results,
        .internal_threads = internal_threads,
    };

    const threads = allocator.alloc(std.Thread, n_threads) catch return validateFrames(codec, frames);
    defer allocator.free(threads);
    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, segWorker, .{&ctx}) catch break;
        spawned += 1;
    }
    // The calling thread participates too (progress even if no worker spawned).
    segWorker(&ctx);
    for (threads[0..spawned]) |t| t.join();

    // Aggregate: lowest-index failing segment wins; sum decoded frame counts.
    var total: u32 = 0;
    for (results) |r| {
        if (!r.valid) {
            return VpxDecodeResult.invalid(r.error_message orelse "VP9 segment decode failed", total, r.vpx_errno);
        }
        total +|= r.frames_decoded;
    }
    return VpxDecodeResult.ok(total);
}

// ============ Tests ============

test "vpx decoder budget scales inversely with frame area and never hits zero" {
    // 1080p: enough instances for real segment parallelism under the budget.
    const at_1080p = maxDecodersForDims(1920, 1080);
    try std.testing.expect(at_1080p >= 4 and at_1080p <= 16);
    // Unknown dims assume 1080p (conservative middle ground).
    try std.testing.expectEqual(at_1080p, maxDecodersForDims(0, 0));
    // 8K: reference pools are huge; must still make progress with one decoder.
    try std.testing.expect(maxDecodersForDims(7680, 4320) >= 1);
    // Tiny video: budget is generous (downstream still caps at cpu/segments/64).
    try std.testing.expect(maxDecodersForDims(320, 240) >= 16);
    // Hostile dims from a corrupt track header must not overflow or zero out.
    try std.testing.expect(maxDecodersForDims(std.math.maxInt(u64), std.math.maxInt(u64)) >= 1);
}

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
