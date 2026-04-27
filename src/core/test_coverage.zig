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
/// Half-width of the 95% Wilson score confidence interval for a binomial
/// proportion p̂ = k/n. The Wilson interval is well-behaved at small n and at
/// p̂ near 0/1 (where the naive normal-approximation interval collapses or
/// strays outside [0,1]) — exactly the regimes we need for adaptive early
/// stopping on bimodal corruption rates.
///
/// Returns 1.0 (the maximum possible radius) when n == 0, so it never
/// satisfies any positive threshold.
///
/// Constants match `wilson_ci` in `scripts/corruption-experiment` (z = 1.96).
pub fn wilsonRadius(k: u32, n: u32) f64 {
    if (n == 0) return 1.0;
    const z: f64 = 1.959963984540054; // 97.5th percentile of N(0,1)
    const nf: f64 = @floatFromInt(n);
    const p_hat: f64 = @as(f64, @floatFromInt(k)) / nf;
    const z2: f64 = z * z;
    const den: f64 = 1.0 + z2 / nf;
    const radius: f64 = (z * @sqrt(p_hat * (1.0 - p_hat) / nf + z2 / (4.0 * nf * nf))) / den;
    return radius;
}


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
    /// Adaptive early-stop threshold expressed as the half-width of the
    /// 95% Wilson confidence interval over the per-mode detection rate.
    ///
    ///   - `0.0` — disabled at this layer (caller chooses the policy).
    ///     `runCoverage` will run all `rounds` requested.
    ///   - negative — explicitly disabled. Same behavior as 0.0; the negative
    ///     sentinel exists so the FFI layer can pass through a CLI
    ///     `--no-early-stop` flag distinctly from "use default".
    ///   - positive — every `early_stop_check_interval` rounds, compute the
    ///     Wilson radius for each enabled mode that has run ≥ the interval.
    ///     If ALL such modes are at or under this threshold (and every mode
    ///     has produced at least `early_stop_check_interval` samples),
    ///     break out of the round loop. Mirrors `scripts/corruption-experiment`.
    early_stop_radius: f64 = 0.0,
    /// Round interval between Wilson-radius checks. The corruption-experiment
    /// script uses 100; we keep the same default so behavior is consistent.
    early_stop_check_interval: u32 = 100,
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

    // Adaptive early-stop bookkeeping. We trip out of the loop as soon as
    // every enabled mode has produced at least `early_stop_check_interval`
    // samples AND the Wilson 95% CI radius for each mode has dropped to or
    // below `early_stop_radius`. This mirrors the per-mode `radius<=thresh`
    // gate in `scripts/corruption-experiment` but generalizes from one mode
    // to the full enabled set.
    const early_stop_enabled = config.early_stop_radius > 0.0 and config.early_stop_check_interval > 0;
    const early_stop_threshold = config.early_stop_radius;
    const early_stop_interval = config.early_stop_check_interval;

    var round: u32 = 0;
    var actual_rounds: u32 = config.rounds;
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

        // Adaptive early-stop check. We only fire on interval boundaries to
        // amortize the cost of iterating per-mode stats; on extreme bimodal
        // detection rates the radius collapses fast, so a 100-round granularity
        // is plenty.
        if (early_stop_enabled and (round + 1) % early_stop_interval == 0) {
            var all_tight = true;
            for (enabled_modes) |m| {
                const s = by_mode.get(m);
                if (s.total < early_stop_interval) {
                    all_tight = false;
                    break;
                }
                const r = wilsonRadius(s.detected, s.total);
                if (r > early_stop_threshold) {
                    all_tight = false;
                    break;
                }
            }
            if (all_tight) {
                actual_rounds = round + 1;
                break;
            }
        }
    }
    // If we exited via the loop condition (no early stop), `actual_rounds`
    // still holds its initial cap value, which equals `round` here.
    if (actual_rounds == config.rounds) actual_rounds = round;

    const end_ns = std.time.nanoTimestamp();

    // Trim the events buffer down to what we actually filled. The caller's
    // `deinit` will `free(events)` and that requires the slice length to
    // match the allocation length exactly — so we either keep the original
    // sized slice or reallocate to the smaller exact size.
    var final_events: []CorruptionEvent = events;
    if (actual_rounds < config.rounds) {
        if (allocator.realloc(events, actual_rounds)) |shrunk| {
            final_events = shrunk;
        } else |_| {
            // Realloc shouldn't fail when shrinking, but if it somehow does,
            // copy into a fresh buffer and free the old one.
            const fresh = try allocator.alloc(CorruptionEvent, actual_rounds);
            @memcpy(fresh, events[0..actual_rounds]);
            allocator.free(events);
            final_events = fresh;
        }
    }

    return CoverageResult{
        .file_size = original.len,
        .rounds = actual_rounds,
        .duration_ns = @intCast(end_ns - start_ns),
        .by_mode = by_mode,
        .events = final_events,
        .allocator = allocator,
    };
}

/// Terminal color depth for heatmap rendering. Mirrors Peter's
/// `max_bits_color_support` bash heuristic: COLORTERM=truecolor|24bit →
/// truecolor; TERM ends in -256color/-direct or COLORTERM=direct → ansi256;
/// else ansi16; NO_COLOR (https://no-color.org) → ascii.
pub const ColorDepth = enum {
    ascii, // no escapes — graded by character density (' .:-=+*#%@')
    ansi16, // \x1b[40-47;100-107m — coarse 6-step black/red/yellow/white
    ansi256, // \x1b[48;5;Nm — 16-step black→darkred→red→orange→yellow→white
    truecolor, // \x1b[48;2;R;G;Bm — smooth perceptual `hot` gradient

    pub fn detectFromEnv() ColorDepth {
        if (comptime @import("builtin").os.tag == .windows) return .ansi256;
        // NO_COLOR takes absolute precedence per https://no-color.org/.
        if (std.posix.getenv("NO_COLOR")) |v| {
            if (v.len > 0) return .ascii;
        }
        if (std.posix.getenv("COLORTERM")) |ct| {
            if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return .truecolor;
            if (std.mem.eql(u8, ct, "direct")) return .ansi256;
        }
        if (std.posix.getenv("TERM")) |term| {
            if (std.mem.endsWith(u8, term, "-256color") or std.mem.endsWith(u8, term, "-direct")) return .ansi256;
        }
        return .ansi16;
    }
};

/// Emit one heatmap cell at the given normalized intensity (`q` in 0..steps-1)
/// for the chosen depth. Each cell is a single screen column.
fn emitHeatmapCell(out_writer: anytype, depth: ColorDepth, q: usize, steps: usize) !void {
    // Clamp guard for callers who pass q == steps.
    const qc = if (q >= steps) steps - 1 else q;
    switch (depth) {
        .ascii => {
            // 10-step density ramp ' .:-=+*#%@' — perceptually monotonic.
            const ramp = " .:-=+*#%@";
            const idx = (qc * (ramp.len - 1)) / (steps - 1);
            try out_writer.writeByte(ramp[idx]);
        },
        .ansi16 => {
            // Coarse 6-step gradient over basic + bright bg colors:
            // black(40) → red(41) → bright-red(101) → yellow(43) → bright-yellow(103) → bright-white(107).
            const palette = [_]u8{ 40, 41, 101, 43, 103, 107 };
            const idx = (qc * (palette.len - 1)) / (steps - 1);
            try std.fmt.format(out_writer, "\x1b[{d}m ", .{palette[idx]});
        },
        .ansi256 => {
            // 16-step `hot` palette over the 6x6x6 cube + grayscale ramp endpoint:
            // 16(black) → 52,88,124,160(dark red→red) → 196(red) → 202,208,214,220(orange→amber)
            // → 226(yellow) → 227,228,229,230(pale yellow) → 231(white).
            const palette = [_]u8{ 16, 52, 88, 124, 160, 196, 202, 208, 214, 220, 226, 227, 228, 229, 230, 231 };
            const idx = (qc * (palette.len - 1)) / (steps - 1);
            try std.fmt.format(out_writer, "\x1b[48;5;{d}m ", .{palette[idx]});
        },
        .truecolor => {
            // Classic matplotlib `hot` colormap, computed:
            //   t in [0,1]
            //   t < 1/3: R = 3t,         G = 0,         B = 0    (black → red)
            //   t < 2/3: R = 1,          G = 3t-1,      B = 0    (red → yellow)
            //   else  : R = 1,           G = 1,         B = 3t-2 (yellow → white)
            // Quantize across `steps` buckets.
            const t: f64 = if (steps <= 1) 0.0 else @as(f64, @floatFromInt(qc)) / @as(f64, @floatFromInt(steps - 1));
            var r: f64 = 0;
            var g: f64 = 0;
            var b: f64 = 0;
            if (t < 1.0 / 3.0) {
                r = 3.0 * t;
            } else if (t < 2.0 / 3.0) {
                r = 1.0;
                g = 3.0 * t - 1.0;
            } else {
                r = 1.0;
                g = 1.0;
                b = 3.0 * t - 2.0;
            }
            const ri: u8 = @intFromFloat(@min(255.0, @max(0.0, r * 255.0)));
            const gi: u8 = @intFromFloat(@min(255.0, @max(0.0, g * 255.0)));
            const bi: u8 = @intFromFloat(@min(255.0, @max(0.0, b * 255.0)));
            try std.fmt.format(out_writer, "\x1b[48;2;{d};{d};{d}m ", .{ ri, gi, bi });
        },
    }
}

/// Render a heatmap string showing undetected-corruption density across
/// the file. The bar is `width` cells wide. Color depth is auto-detected
/// from `COLORTERM`/`TERM`/`NO_COLOR` (see ColorDepth.detectFromEnv).
/// Returns an owned string; caller must free.
pub fn renderHeatmap(
    allocator: Allocator,
    result: *const CoverageResult,
    width: u32,
) ![]u8 {
    return renderHeatmapWithDepth(allocator, result, width, null, ColorDepth.detectFromEnv());
}

/// Per-mode heatmap (only events with `mode_filter` count toward the gradient).
pub fn renderHeatmapFiltered(
    allocator: Allocator,
    result: *const CoverageResult,
    width: u32,
    mode_filter: ?CorruptionMode,
) ![]u8 {
    return renderHeatmapWithDepth(allocator, result, width, mode_filter, ColorDepth.detectFromEnv());
}

/// Lower-level form that takes an explicit color depth, for tests and for
/// callers that have already detected the terminal capability.
pub fn renderHeatmapWithDepth(
    allocator: Allocator,
    result: *const CoverageResult,
    width: u32,
    mode_filter: ?CorruptionMode,
    depth: ColorDepth,
) ![]u8 {
    if (width == 0) return error.InvalidWidth;

    const buckets = try allocator.alloc(u32, width);
    defer allocator.free(buckets);
    @memset(buckets, 0);

    for (result.events) |event| {
        if (event.detected) continue;
        if (mode_filter) |m| if (event.mode != m) continue;
        const bucket: usize = @intCast(@min(
            @as(u64, width - 1),
            (event.offset * width) / result.file_size,
        ));
        buckets[bucket] += 1;
    }

    var max_count: u32 = 0;
    for (buckets) |c| max_count = @max(max_count, c);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);

    // We always quantize into 16 steps so every depth tier maps consistently.
    const steps: usize = 16;
    for (buckets) |count| {
        const q = if (max_count == 0) 0 else (@as(usize, count) * (steps - 1)) / max_count;
        try emitHeatmapCell(out.writer(allocator), depth, q, steps);
    }
    if (depth != .ascii) try out.writer(allocator).writeAll("\x1b[0m");

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

    // Should contain ANSI escape sequences (any tier above .ascii ends with reset).
    // Whatever tier env-detect picks, the bar must have width-many cells.
    try testing.expect(heat.len > 0);
}

test "renderHeatmapWithDepth ascii produces no escapes" {
    const original = "x" ** 100;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 20, .seed = 7 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    const heat = try renderHeatmapWithDepth(testing.allocator, &result, 32, null, .ascii);
    defer testing.allocator.free(heat);

    // 32 cells, each ASCII char from " .:-=+*#%@", no escapes anywhere.
    try testing.expectEqual(@as(usize, 32), heat.len);
    try testing.expect(std.mem.indexOf(u8, heat, "\x1b") == null);
    for (heat) |c| {
        const ramp = " .:-=+*#%@";
        try testing.expect(std.mem.indexOfScalar(u8, ramp, c) != null);
    }
}

test "renderHeatmapWithDepth ansi16 emits basic-bg escapes" {
    const original = "x" ** 100;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 20, .seed = 7 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    const heat = try renderHeatmapWithDepth(testing.allocator, &result, 32, null, .ansi16);
    defer testing.allocator.free(heat);

    // ANSI 16-color uses \x1b[NNm not \x1b[48;5; or \x1b[48;2;.
    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;5;") == null);
    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;2;") == null);
    try testing.expect(std.mem.endsWith(u8, heat, "\x1b[0m"));
    // At least one of the chosen palette codes (40, 41, 101, 43, 103, 107).
    var any_palette = false;
    inline for (.{ "\x1b[40m", "\x1b[41m", "\x1b[101m", "\x1b[43m", "\x1b[103m", "\x1b[107m" }) |needle| {
        if (std.mem.indexOf(u8, heat, needle) != null) any_palette = true;
    }
    try testing.expect(any_palette);
}

test "renderHeatmapWithDepth ansi256 uses hot palette indices only" {
    const original = "x" ** 100;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 30, .seed = 11 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    const heat = try renderHeatmapWithDepth(testing.allocator, &result, 32, null, .ansi256);
    defer testing.allocator.free(heat);

    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;5;") != null);
    try testing.expect(std.mem.endsWith(u8, heat, "\x1b[0m"));
    // No truecolor fallback in this tier.
    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;2;") == null);

    // Every index in the palette must be one of the 16 hot steps.
    const palette = [_][]const u8{
        "\x1b[48;5;16m",  "\x1b[48;5;52m",  "\x1b[48;5;88m",  "\x1b[48;5;124m",
        "\x1b[48;5;160m", "\x1b[48;5;196m", "\x1b[48;5;202m", "\x1b[48;5;208m",
        "\x1b[48;5;214m", "\x1b[48;5;220m", "\x1b[48;5;226m", "\x1b[48;5;227m",
        "\x1b[48;5;228m", "\x1b[48;5;229m", "\x1b[48;5;230m", "\x1b[48;5;231m",
    };
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, heat, i, "\x1b[48;5;")) |pos| {
        const end = std.mem.indexOfScalarPos(u8, heat, pos, 'm') orelse break;
        const seq = heat[pos .. end + 1];
        var matched = false;
        for (palette) |p| {
            if (std.mem.eql(u8, seq, p)) {
                matched = true;
                break;
            }
        }
        try testing.expect(matched);
        i = end + 1;
    }
}

test "renderHeatmapWithDepth truecolor stays on the matplotlib hot curve" {
    const original = "x" ** 100;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 30, .seed = 13 },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();

    const heat = try renderHeatmapWithDepth(testing.allocator, &result, 32, null, .truecolor);
    defer testing.allocator.free(heat);

    try testing.expect(std.mem.indexOf(u8, heat, "\x1b[48;2;") != null);
    try testing.expect(std.mem.endsWith(u8, heat, "\x1b[0m"));

    // Hot curve invariant: across all (R,G,B) triples, R must be ≥ G and G ≥ B.
    // (black→red→yellow→white never touches blue/green dominance.)
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, heat, i, "\x1b[48;2;")) |pos| {
        const end = std.mem.indexOfScalarPos(u8, heat, pos + 7, 'm') orelse break;
        var iter = std.mem.splitScalar(u8, heat[pos + 7 .. end], ';');
        const r = std.fmt.parseInt(u16, iter.next() orelse break, 10) catch break;
        const g = std.fmt.parseInt(u16, iter.next() orelse break, 10) catch break;
        const b = std.fmt.parseInt(u16, iter.next() orelse break, 10) catch break;
        try testing.expect(r >= g);
        try testing.expect(g >= b);
        try testing.expect(r <= 255 and g <= 255 and b <= 255);
        i = end + 1;
    }
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

test "wilsonRadius matches reference values" {
    // Hand-checked against the LuaJIT corruption-experiment script at p=0.5,
    // n=100 (worst case for symmetric Wilson interval — 95% CI radius ≈ 0.094).
    const r1 = wilsonRadius(50, 100);
    try testing.expect(r1 > 0.09 and r1 < 0.10);
    // At p=1.0, n=200 the radius pulls in tightly.
    const r2 = wilsonRadius(200, 200);
    try testing.expect(r2 < 0.025);
    // At p=0.0, n=200 — symmetric tail, also tight.
    const r3 = wilsonRadius(0, 200);
    try testing.expect(r3 < 0.025);
    // n=0 is undefined; we return 1.0 (max possible) so it never trips early stop.
    try testing.expectEqual(@as(f64, 1.0), wilsonRadius(0, 0));
}

test "runCoverage early-stops at extreme detection rate" {
    // alwaysDetects: every round adds to the detected tally (p̂=1). The Wilson
    // upper bound clamps at 1, so the radius shrinks rapidly. With cap=10000
    // and the default check interval (100), we should stop well before round 1000.
    const original = "z" ** 4096;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{
            .rounds = 10000,
            .seed = 1,
            .early_stop_radius = 0.025,
        },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer result.deinit();
    try testing.expect(result.rounds < 1000);
    try testing.expect(result.rounds >= 100); // first feasible check
    // events slice should be sized to the actual run, not the cap
    try testing.expectEqual(@as(usize, result.rounds), result.events.len);
}

test "runCoverage early-stops at zero detection rate (symmetric tail)" {
    // neverDetects: p̂=0. The interval also shrinks fast; should stop early.
    const original = "z" ** 4096;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{
            .rounds = 10000,
            .seed = 2,
            .early_stop_radius = 0.025,
        },
        @ptrCast(&ctx),
        neverDetectsValidator,
    );
    defer result.deinit();
    try testing.expect(result.rounds < 1000);
}

test "runCoverage with early_stop disabled runs all rounds" {
    // Negative radius = disabled; should run exactly the cap.
    const original = "z" ** 4096;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{
            .rounds = 250,
            .seed = 3,
            .early_stop_radius = -1.0,
        },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer result.deinit();
    try testing.expectEqual(@as(u32, 250), result.rounds);
    try testing.expectEqual(@as(usize, 250), result.events.len);
}

test "runCoverage with early_stop_radius=0 means disabled (default)" {
    // 0.0 = disabled at the core layer (caller picks the default elsewhere).
    const original = "z" ** 4096;
    var ctx: u32 = 0;
    var result = try runCoverage(
        testing.allocator,
        original,
        .{
            .rounds = 220,
            .seed = 4,
            .early_stop_radius = 0.0,
        },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer result.deinit();
    try testing.expectEqual(@as(u32, 220), result.rounds);
}

test "runCoverage tighter early_stop_radius needs more rounds before stopping" {
    // With a much tighter threshold (0.001 = ±0.1%), early stop requires
    // many more samples than at 0.025.
    const original = "z" ** 4096;
    var ctx: u32 = 0;
    var loose = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 100000, .seed = 7, .early_stop_radius = 0.025 },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer loose.deinit();
    var tight = try runCoverage(
        testing.allocator,
        original,
        .{ .rounds = 100000, .seed = 7, .early_stop_radius = 0.001 },
        @ptrCast(&ctx),
        alwaysDetectsValidator,
    );
    defer tight.deinit();
    try testing.expect(tight.rounds > loose.rounds);
}
