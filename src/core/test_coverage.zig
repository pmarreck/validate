//! Statistical corruption coverage testing.
//!
//! Given a known-good file, performs N rounds of in-memory corruption and
//! measures how often our validators detect the corruption. Output: per-mode
//! detection rate + heatmap of undetected-corruption byte regions.
//!
//! Uses FileSource.fromBuffer() to pass corrupted data directly to deep
//! validators without disk I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CorruptionMode = enum {
    sniper,       // flip one random bit
    shotgun,      // overwrite K random bytes at random offset
    header,       // shotgun restricted to first 10% of file
    tail,         // shotgun restricted to last 10% of file
    zeroed,       // zero-fill a K-byte region at random offset
    xor,          // XOR a K-byte region with a random pattern
    sparse_noise, // flip every Nth bit across a K-byte region (degraded media)
    boundary,     // concentrate corruption at a structurally-critical region
                  // (magic/header, footer, or block boundary)

    pub fn name(self: CorruptionMode) []const u8 {
        return switch (self) {
            .sniper => "sniper",
            .shotgun => "shotgun",
            .header => "header",
            .tail => "tail",
            .zeroed => "zeroed",
            .xor => "xor",
            .sparse_noise => "sparse_noise",
            .boundary => "boundary",
        };
    }
};

pub const CorruptionEvent = struct {
    mode: CorruptionMode,
    /// Byte offset of the corruption (first affected byte)
    offset: u64,
    /// Bit position within the byte (only meaningful for sniper; 0-7)
    bit: u3,
    /// Number of bytes affected
    size: u32,
    /// True if our validator detected the corruption as invalid
    detected: bool,
};

/// Apply a sniper corruption: flip one random bit in the buffer.
/// Returns the event so the caller can record offset+bit for the heatmap.
pub fn applySniper(buffer: []u8, rng: std.Random) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const offset = rng.uintLessThan(u64, buffer.len);
    const bit: u3 = @intCast(rng.uintLessThan(u8, 8));
    buffer[@intCast(offset)] ^= (@as(u8, 1) << bit);
    return .{
        .mode = .sniper,
        .offset = offset,
        .bit = bit,
        .size = 1,
        .detected = false,
    };
}

/// Apply a shotgun corruption: overwrite K random bytes at a random offset.
pub fn applyShotgun(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), buffer.len));
    const max_offset: u64 = buffer.len - clamped_size;
    const offset = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    var i: usize = 0;
    while (i < clamped_size) : (i += 1) {
        buffer[@intCast(offset + i)] = rng.int(u8);
    }
    return .{
        .mode = .shotgun,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply a header corruption: shotgun restricted to first 10% of file.
pub fn applyHeader(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const header_region: u64 = @max(@as(u64, 1), buffer.len / 10);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), header_region));
    const max_offset: u64 = header_region - clamped_size;
    const offset = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    var i: usize = 0;
    while (i < clamped_size) : (i += 1) {
        buffer[@intCast(offset + i)] = rng.int(u8);
    }
    return .{
        .mode = .header,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply a tail corruption: shotgun restricted to last 10% of file.
pub fn applyTail(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const tail_region: u64 = @max(@as(u64, 1), buffer.len / 10);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), tail_region));
    const tail_start = buffer.len - tail_region;
    const max_offset: u64 = tail_region - clamped_size;
    const offset_in_tail = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    const offset = tail_start + offset_in_tail;
    var i: usize = 0;
    while (i < clamped_size) : (i += 1) {
        buffer[@intCast(offset + i)] = rng.int(u8);
    }
    return .{
        .mode = .tail,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply a zeroed corruption: zero-fill K bytes at a random offset.
pub fn applyZeroed(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), buffer.len));
    const max_offset: u64 = buffer.len - clamped_size;
    const offset = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    @memset(buffer[@intCast(offset)..][0..clamped_size], 0);
    return .{
        .mode = .zeroed,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply an XOR corruption: XOR K bytes with a random pattern.
pub fn applyXor(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), buffer.len));
    const max_offset: u64 = buffer.len - clamped_size;
    const offset = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    const pattern = rng.int(u8);
    var i: usize = 0;
    while (i < clamped_size) : (i += 1) {
        buffer[@intCast(offset + i)] ^= pattern;
    }
    return .{
        .mode = .xor,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply a sparse-noise corruption: within a `size`-byte region at a random
/// offset, flip every Nth bit (spacing N = 1..=31 picked per call). Models
/// degraded physical media where a single failing trace or address line
/// causes a repeating bit-error pattern rather than contiguous damage.
pub fn applySparseNoise(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const clamped_size: u32 = @intCast(@min(@as(u64, size), buffer.len));
    const max_offset: u64 = buffer.len - clamped_size;
    const offset = if (max_offset == 0) 0 else rng.uintLessThan(u64, max_offset + 1);
    // Spacing in bits — avoid 0 (undefined) and keep bounded so we flip at
    // least a handful of bits on small regions.
    const spacing: u32 = rng.intRangeAtMost(u32, 1, 31);
    const total_bits: u64 = @as(u64, clamped_size) * 8;
    var bit: u64 = 0;
    while (bit < total_bits) : (bit += spacing) {
        const byte_idx = offset + (bit / 8);
        const bit_idx: u3 = @intCast(bit % 8);
        buffer[@intCast(byte_idx)] ^= (@as(u8, 1) << bit_idx);
    }
    return .{
        .mode = .sparse_noise,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Apply a boundary corruption: concentrate a shotgun-style overwrite on a
/// structurally-critical region of the file. Three equally-weighted
/// strategies are rolled per call:
///
///   1. "magic/header" — a K-byte window anchored to the first 64 bytes,
///      where formats keep their signature + primary header fields.
///   2. "footer" — a K-byte window anchored to the last 64 bytes, where
///      containers tend to keep EOF markers, central directories, index
///      offsets, or CRCs (ZIP EOCD, PNG IEND, etc.).
///   3. "block boundary" — a K-byte window straddling a 4096-byte-aligned
///      offset somewhere in the middle of the file, modeling damage to
///      filesystem-level sector edges that often coincide with chunk /
///      segment boundaries in container formats.
///
/// This is format-agnostic but strictly higher-leverage than plain shotgun:
/// real formats almost always concentrate structural invariants in these
/// regions, so undetected corruption here is a more interesting signal.
/// Future work: format-specific landmark tables (MKV segment tail, ZIP
/// EOCD, etc.) can replace this heuristic for the handful of formats
/// where deep layout knowledge pays off.
pub fn applyBoundary(buffer: []u8, rng: std.Random, size: u32) CorruptionEvent {
    std.debug.assert(buffer.len > 0);
    const strategy = rng.uintLessThan(u8, 3);

    // The corruption-region length is capped at min(size, buffer.len, 64) for
    // the header/footer strategies (so we don't overflow the anchored window),
    // and at min(size, buffer.len) for the block-boundary strategy.
    const offset: u64 = switch (strategy) {
        0 => blk: {
            // Anchored to first min(64, buffer.len) bytes.
            const anchor: u64 = @min(@as(u64, 64), buffer.len);
            const region: u64 = @min(@as(u64, size), anchor);
            const max_start: u64 = anchor - region;
            break :blk if (max_start == 0) 0 else rng.uintLessThan(u64, max_start + 1);
        },
        1 => blk: {
            // Anchored to last min(64, buffer.len) bytes.
            const anchor: u64 = @min(@as(u64, 64), buffer.len);
            const region: u64 = @min(@as(u64, size), anchor);
            const start_of_tail: u64 = buffer.len - anchor;
            const max_start_within: u64 = anchor - region;
            const within: u64 = if (max_start_within == 0) 0 else rng.uintLessThan(u64, max_start_within + 1);
            break :blk start_of_tail + within;
        },
        2 => blk: {
            // Straddle a 4096-aligned offset in the middle. Pick a random
            // 4 KiB-aligned position (at least 4 KiB in from the start so
            // the region actually straddles) and offset by -region/2.
            const clamped_size: u64 = @min(@as(u64, size), buffer.len);
            if (buffer.len < 8192) {
                // File too small to meaningfully straddle; fall back to a
                // mid-file shotgun.
                const max_off: u64 = buffer.len - clamped_size;
                break :blk if (max_off == 0) 0 else rng.uintLessThan(u64, max_off + 1);
            }
            const block = 4096;
            const num_blocks: u64 = buffer.len / block;
            // Prefer the interior: skip blocks 0 and last.
            const picked_block: u64 = 1 + rng.uintLessThan(u64, num_blocks - 1);
            const boundary_off: u64 = picked_block * block;
            const half: u64 = clamped_size / 2;
            break :blk if (boundary_off < half)
                0
            else if (boundary_off + (clamped_size - half) > buffer.len)
                buffer.len - clamped_size
            else
                boundary_off - half;
        },
        else => unreachable,
    };

    const region: u64 = switch (strategy) {
        0, 1 => blk: {
            const anchor: u64 = @min(@as(u64, 64), buffer.len);
            break :blk @min(@as(u64, size), anchor);
        },
        2 => @min(@as(u64, size), buffer.len),
        else => unreachable,
    };

    const clamped_size: u32 = @intCast(region);
    var i: usize = 0;
    while (i < clamped_size) : (i += 1) {
        buffer[@intCast(offset + i)] = rng.int(u8);
    }
    return .{
        .mode = .boundary,
        .offset = offset,
        .bit = 0,
        .size = clamped_size,
        .detected = false,
    };
}

/// Aggregated statistics for a single corruption mode.
pub const ModeStats = struct {
    total: u32 = 0,
    detected: u32 = 0,
};

/// Result of a full coverage run.
pub const CoverageResult = struct {
    file_size: u64,
    rounds: u32,
    duration_ns: u64,
    by_mode: std.EnumArray(CorruptionMode, ModeStats),
    /// All events (detected AND undetected). Owned by caller.
    events: []CorruptionEvent,
    allocator: Allocator,

    pub fn deinit(self: *CoverageResult) void {
        self.allocator.free(self.events);
    }

    pub fn totalDetected(self: *const CoverageResult) u32 {
        var sum: u32 = 0;
        for (self.by_mode.values) |stats| sum += stats.detected;
        return sum;
    }

    pub fn totalRuns(self: *const CoverageResult) u32 {
        var sum: u32 = 0;
        for (self.by_mode.values) |stats| sum += stats.total;
        return sum;
    }
};

/// Signature for a validator callback: given corrupted bytes, returns true if
/// the validator detected it as invalid (caught the corruption), false if not.
pub const ValidatorFn = *const fn (ctx: *anyopaque, bytes: []const u8) bool;

/// Signature for an optional progress callback: called before each round.
/// round is 0-indexed; total_rounds is the planned total.
pub const ProgressFn = *const fn (ctx: *anyopaque, round: u32, total_rounds: u32, detected_so_far: u32) void;

/// Config for a coverage run.
pub const CoverageConfig = struct {
    rounds: u32 = 100,
    /// Byte count for shotgun-style corruptions
    shotgun_bytes: u32 = 4096,
    /// Random seed (for reproducibility). Use std.time.milliTimestamp() for
    /// different runs each invocation.
    seed: u64 = 0,
    /// Which modes to include. Default: the six long-shipped modes
    /// (sparse_noise and future opt-in modes stay off unless the caller
    /// asks for them — the FFI layer enforces the same policy for
    /// modes_bitmask == 0).
    enabled_modes: std.EnumSet(CorruptionMode) = blk: {
        var set = std.EnumSet(CorruptionMode).initEmpty();
        set.insert(.sniper);
        set.insert(.shotgun);
        set.insert(.header);
        set.insert(.tail);
        set.insert(.zeroed);
        set.insert(.xor);
        break :blk set;
    },
    /// Optional progress callback fired before each round.
    progress: ?ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
};

/// Run a corruption coverage test.
///
/// Given a known-good byte buffer and a validator callback, performs N rounds
/// of:
///   1. Allocate a working copy (memcpy from original)
///   2. Apply a randomly-chosen corruption mode
///   3. Invoke the validator on the corrupted bytes
///   4. Record: was the corruption detected?
///   5. Free the working copy
///
/// Returns aggregate stats + all events (for heatmap rendering).
/// Caller must call result.deinit() to free the events slice.
pub fn runCoverage(
    allocator: Allocator,
    original: []const u8,
    config: CoverageConfig,
    validator_ctx: *anyopaque,
    validator_fn: ValidatorFn,
) !CoverageResult {
    const enabled_count = config.enabled_modes.count();
    if (enabled_count == 0) return error.NoCorruptionModesEnabled;
    if (original.len == 0) return error.EmptyInput;

    // Build list of enabled modes for random selection
    var modes_buf: [@typeInfo(CorruptionMode).@"enum".fields.len]CorruptionMode = undefined;
    var modes_len: usize = 0;
    var mode_iter = config.enabled_modes.iterator();
    while (mode_iter.next()) |m| {
        modes_buf[modes_len] = m;
        modes_len += 1;
    }
    const enabled_modes = modes_buf[0..modes_len];

    const events = try allocator.alloc(CorruptionEvent, config.rounds);
    errdefer allocator.free(events);

    var by_mode = std.EnumArray(CorruptionMode, ModeStats).initFill(.{});
    var prng = std.Random.DefaultPrng.init(config.seed);
    const rng = prng.random();

    const start_ns = std.time.nanoTimestamp();
    var detected_count: u32 = 0;

    // Memory optimization: allocate + copy the working buffer ONCE, then each
    // round only restores the bytes we just corrupted. For a 500 MB file and
    // 4 KiB shotguns, this drops per-round memcpy volume from 500 MB to 4 KiB
    // (~125,000×). Every resync_interval rounds we do a full-buffer memcpy
    // anyway, so any drift from a misbehaving validator (OOB write, stale
    // cache, etc.) is bounded.
    const resync_interval: u32 = 64;
    const work = try allocator.alloc(u8, original.len);
    defer allocator.free(work);
    @memcpy(work, original);

    // Debug-build safety net: hash a sentinel window outside the corrupted
    // range before every validate() and check it after. Any drift means a
    // validator wrote to what it was handed as read-only input — which has
    // bitten us three times this week (compact_pro CPT, zigimg TIFF, bzip2).
    const debug_build = @import("builtin").mode == .Debug;
    const sentinel_len: usize = @min(@as(usize, 1024), original.len);

    var round: u32 = 0;
    while (round < config.rounds) : (round += 1) {
        if (config.progress) |cb| cb(config.progress_ctx.?, round, config.rounds, detected_count);

        // Periodic full resync so any accumulated drift can't hide forever.
        if (round > 0 and round % resync_interval == 0) @memcpy(work, original);

        const chosen_mode = enabled_modes[rng.uintLessThan(usize, enabled_modes.len)];
        var event: CorruptionEvent = switch (chosen_mode) {
            .sniper => applySniper(work, rng),
            .shotgun => applyShotgun(work, rng, config.shotgun_bytes),
            .header => applyHeader(work, rng, config.shotgun_bytes),
            .tail => applyTail(work, rng, config.shotgun_bytes),
            .zeroed => applyZeroed(work, rng, config.shotgun_bytes),
            .xor => applyXor(work, rng, config.shotgun_bytes),
            .sparse_noise => applySparseNoise(work, rng, config.shotgun_bytes),
            .boundary => applyBoundary(work, rng, config.shotgun_bytes),
        };

        if (comptime @import("builtin").os.tag != .windows) {
            if (std.posix.getenv("VALIDATE_COVERAGE_TRACE")) |_| {
                std.debug.print(
                    "[coverage trace] seed={d} round={d}/{d} mode={s} offset={d} bit={d} size={d}\n",
                    .{ config.seed, round + 1, config.rounds, event.mode.name(), event.offset, event.bit, event.size },
                );
            }
        }

        // Pick a sentinel region that does NOT overlap the corrupted range.
        // Easiest rule: take the first sentinel_len bytes if they're outside
        // the event, otherwise the last sentinel_len bytes. If the file is too
        // small or the event spans everything, skip the check for this round.
        var sentinel_check: ?struct { off: usize, hash_before: u64 } = null;
        if (debug_build and original.len > sentinel_len) {
            const ev_end = event.offset + event.size;
            var s_off: ?usize = null;
            if (event.offset >= sentinel_len) {
                s_off = 0;
            } else if (ev_end <= original.len - sentinel_len) {
                s_off = original.len - sentinel_len;
            }
            if (s_off) |off| {
                const h = std.hash.Wyhash.hash(0, work[off .. off + sentinel_len]);
                sentinel_check = .{ .off = off, .hash_before = h };
            }
        }

        const detected = validator_fn(validator_ctx, work);

        if (sentinel_check) |sc| {
            const h_after = std.hash.Wyhash.hash(0, work[sc.off .. sc.off + sentinel_len]);
            if (h_after != sc.hash_before) {
                std.debug.panic(
                    "test-coverage sentinel changed at offset {d} (round {d} mode {s}); a validator wrote to its read-only input",
                    .{ sc.off, round + 1, event.mode.name() },
                );
            }
        }

        event.detected = detected;
        events[round] = event;

        var stats = by_mode.get(chosen_mode);
        stats.total += 1;
        if (detected) stats.detected += 1;
        by_mode.set(chosen_mode, stats);
        if (detected) detected_count += 1;

        // Restore only the corrupted range so the next round starts clean.
        // Clamp to the buffer in case a future mode writes beyond event.size.
        const restore_end = @min(event.offset + event.size, original.len);
        if (event.offset < original.len) {
            @memcpy(work[event.offset..restore_end], original[event.offset..restore_end]);
        }
    }

    const end_ns = std.time.nanoTimestamp();

    return CoverageResult{
        .file_size = original.len,
        .rounds = config.rounds,
        .duration_ns = @intCast(end_ns - start_ns),
        .by_mode = by_mode,
        .events = events,
        .allocator = allocator,
    };
}

/// Render a heatmap string showing undetected-corruption density across
/// the file, using ANSI 256-color gradient. If `mode_filter` is non-null,
/// only events in that mode contribute (useful for per-mode heatmaps so
/// each corruption mode gets its own visibility map). The bar is `width`
/// cells wide. Returns an owned string; caller must free.
pub fn renderHeatmap(
    allocator: Allocator,
    result: *const CoverageResult,
    width: u32,
) ![]u8 {
    return renderHeatmapFiltered(allocator, result, width, null);
}

pub fn renderHeatmapFiltered(
    allocator: Allocator,
    result: *const CoverageResult,
    width: u32,
    mode_filter: ?CorruptionMode,
) ![]u8 {
    if (width == 0) return error.InvalidWidth;

    // Count undetected corruption events per bucket
    const buckets = try allocator.alloc(u32, width);
    defer allocator.free(buckets);
    @memset(buckets, 0);

    for (result.events) |event| {
        if (event.detected) continue;
        if (mode_filter) |m| if (event.mode != m) continue;
        // Map byte offset to bucket index
        const bucket: usize = @intCast(@min(
            @as(u64, width - 1),
            (event.offset * width) / result.file_size,
        ));
        buckets[bucket] += 1;
    }

    // Find max for normalization
    var max_count: u32 = 0;
    for (buckets) |c| max_count = @max(max_count, c);

    // Build the output string with ANSI 256-color escapes
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    // ANSI 256-color gradient: cooler (blue/cyan) → hot (yellow/red/white)
    // Picked from the 6x6x6 color cube: black(16) → blue(21) → cyan(51) →
    //   green(46) → yellow(226) → red(196) → white(231)
    const gradient = [_]u8{ 16, 17, 18, 19, 20, 21, 27, 33, 39, 45, 51, 87, 123, 159, 195, 226, 220, 214, 208, 202, 196, 231 };

    for (buckets) |count| {
        const intensity = if (max_count == 0)
            @as(usize, 0)
        else
            (@as(usize, count) * (gradient.len - 1)) / max_count;
        const color = gradient[intensity];
        try std.fmt.format(out.writer(allocator), "\x1b[48;5;{d}m ", .{color});
    }
    try out.writer(allocator).writeAll("\x1b[0m");

    return out.toOwnedSlice(allocator);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "applySniper flips exactly one bit" {
    var prng = std.Random.DefaultPrng.init(42);
    var buffer = [_]u8{0xAA} ** 100;
    const original = buffer;

    const event = applySniper(&buffer, prng.random());

    try testing.expectEqual(CorruptionMode.sniper, event.mode);
    try testing.expectEqual(@as(u32, 1), event.size);
    try testing.expect(event.offset < buffer.len);

    // Exactly one byte should differ
    var diff_count: u32 = 0;
    for (original, buffer) |a, b| {
        if (a != b) diff_count += 1;
    }
    try testing.expectEqual(@as(u32, 1), diff_count);

    // The differing byte should differ by exactly one bit
    const xor = original[@intCast(event.offset)] ^ buffer[@intCast(event.offset)];
    try testing.expectEqual(@as(u8, 1) << event.bit, xor);
}

test "applyShotgun overwrites N bytes starting at offset" {
    var prng = std.Random.DefaultPrng.init(123);
    var buffer = [_]u8{0} ** 1000;

    const event = applyShotgun(&buffer, prng.random(), 16);

    try testing.expectEqual(CorruptionMode.shotgun, event.mode);
    try testing.expectEqual(@as(u32, 16), event.size);
    try testing.expect(event.offset + 16 <= buffer.len);

    // The 16-byte window should be modified (very likely not all zero)
    var any_nonzero = false;
    for (buffer[@intCast(event.offset)..][0..16]) |b| {
        if (b != 0) any_nonzero = true;
    }
    try testing.expect(any_nonzero);
}

test "applyHeader stays within first 10% of buffer" {
    var prng = std.Random.DefaultPrng.init(7);
    var buffer = [_]u8{0} ** 1000;

    for (0..50) |_| {
        buffer = [_]u8{0} ** 1000;
        const event = applyHeader(&buffer, prng.random(), 8);
        try testing.expect(event.offset + event.size <= 100); // 10% of 1000
    }
}

test "applyTail stays within last 10% of buffer" {
    var prng = std.Random.DefaultPrng.init(99);
    var buffer = [_]u8{0} ** 1000;

    for (0..50) |_| {
        buffer = [_]u8{0} ** 1000;
        const event = applyTail(&buffer, prng.random(), 8);
        try testing.expect(event.offset >= 900); // last 10%
        try testing.expect(event.offset + event.size <= 1000);
    }
}

test "applyZeroed sets bytes to zero" {
    var prng = std.Random.DefaultPrng.init(555);
    var buffer = [_]u8{0xFF} ** 200;

    const event = applyZeroed(&buffer, prng.random(), 10);

    for (buffer[@intCast(event.offset)..][0..10]) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "applyXor flips bits according to pattern" {
    var prng = std.Random.DefaultPrng.init(7777);
    var buffer = [_]u8{0x42} ** 50;

    const event = applyXor(&buffer, prng.random(), 5);

    // XOR with a random pattern: region may be unchanged if pattern is 0.
    // Just verify the event is well-formed.
    try testing.expectEqual(@as(u32, 5), event.size);
}

// ---- Runner tests ----

const always_detects_ctx = struct {};
fn alwaysDetectsValidator(_: *anyopaque, _: []const u8) bool {
    return true;
}

const never_detects_ctx = struct {};
fn neverDetectsValidator(_: *anyopaque, _: []const u8) bool {
    return false;
}

test "runCoverage aggregates stats across all enabled modes" {
    const original = "hello world, this is a test buffer" ** 10; // 340 bytes
    var ctx: u32 = 0;
    const Ctx = struct {};
    _ = Ctx;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 60, .seed = 42 },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer result.deinit();

    try testing.expectEqual(@as(u64, original.len), result.file_size);
    try testing.expectEqual(@as(u32, 60), result.rounds);
    try testing.expectEqual(@as(u32, 60), result.totalRuns());
    try testing.expectEqual(@as(u32, 60), result.totalDetected());
}

test "runCoverage records undetected events for heatmap" {
    const original = "a" ** 1000;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 30, .seed = 7 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    try testing.expectEqual(@as(u32, 0), result.totalDetected());
    try testing.expectEqual(@as(u32, 30), result.rounds);
    for (result.events) |e| try testing.expect(!e.detected);
}

test "renderHeatmap produces ANSI-colored bar of requested width" {
    const original = "x" ** 100;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 20, .seed = 99 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    const heat = try renderHeatmap(testing.allocator, &result, 40);
    defer testing.allocator.free(heat);

    // Should contain ANSI escape sequences
    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;5;") != null);
    try testing.expect(std.mem.endsWith(u8, heat, "\x1b[0m"));
}

test "runCoverage respects enabled_modes subset" {
    const original = "y" ** 500;
    var ctx: u32 = 0;
    var only_sniper = std.EnumSet(CorruptionMode).initEmpty();
    only_sniper.insert(.sniper);

    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 40, .seed = 1234, .enabled_modes = only_sniper },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    try testing.expectEqual(@as(u32, 40), result.by_mode.get(.sniper).total);
    try testing.expectEqual(@as(u32, 0), result.by_mode.get(.shotgun).total);
    try testing.expectEqual(@as(u32, 0), result.by_mode.get(.xor).total);
    for (result.events) |e| try testing.expectEqual(CorruptionMode.sniper, e.mode);
}
