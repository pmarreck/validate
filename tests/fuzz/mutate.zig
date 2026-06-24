//! Deterministic mutation operators for the fuzz sweep.
//!
//! These are the structural mutations the 8 CODE_REVIEW CRITICALs came from —
//! not just point-noise. Every operator is a pure function of (input, RNG
//! state), so a crash reproduces exactly from its (seed, file, operator,
//! offset) descriptor. Each returns a freshly-allocated buffer the caller owns;
//! the input is never modified in place.
//!
//! `prefix_len` bytes at the front are left untouched so the mutation keeps
//! reaching the intended decoder (the detector's consumed magic). The driver
//! varies prefix_len (0 to fuzz the header itself, >0 to fuzz the body) and
//! always re-detects + re-buckets afterward.

const std = @import("std");

/// The mutation classes. Names map to the CRITICAL bug classes they target:
/// sniper/bolter = bit/byte flips; truncate = RIFF/Parquet tail-cut overflow;
/// maxout = OLE2 ~17 GB alloc + u32-size overflow; shotgun/splice/zero =
/// region overwrite.
pub const Operator = enum {
    /// Flip a single bit at one offset.
    sniper,
    /// XOR a small cluster (2–8 bytes) with 0xFF.
    bolter,
    /// Chop the tail at a random offset (keep a valid-length prefix).
    truncate,
    /// Set a 1/2/4/8-byte field to all-0xFF (max-out a declared size/length).
    maxout,
    /// Overwrite a region (≤4 KiB) with deterministic RNG bytes.
    shotgun,
    /// Zero a region (≤4 KiB).
    zero,
    /// Overwrite a region with bytes spliced from another buffer.
    splice,

    pub const all = [_]Operator{ .sniper, .bolter, .truncate, .maxout, .shotgun, .zero, .splice };
};

/// Largest region a shotgun/zero/splice operator overwrites.
const max_region: usize = 4 * 1024;

/// Apply `op` to a copy of `input`, returning the new buffer (caller frees).
/// `prefix_len` front bytes are preserved. `splice_src` is only consulted by
/// `.splice` (pass `&.{}` otherwise; splice degrades to shotgun if empty).
pub fn mutate(
    allocator: std.mem.Allocator,
    op: Operator,
    input: []const u8,
    prefix_len: usize,
    rng: std.Random,
    splice_src: []const u8,
) ![]u8 {
    const plen = @min(prefix_len, input.len);
    // The mutable window is [plen, input.len). If there's nothing to mutate
    // (tiny input fully covered by the prefix), just return a copy.
    if (plen >= input.len) return allocator.dupe(u8, input);

    switch (op) {
        .truncate => {
            // Keep at least the prefix + 1 byte, drop a random-length tail.
            const new_len = plen + rng.uintLessThan(usize, input.len - plen);
            return allocator.dupe(u8, input[0..new_len]);
        },
        .sniper => {
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const bit = rng.int(u3); // 0..7, exactly 8 outcomes
            out[off] ^= (@as(u8, 1) << bit);
            return out;
        },
        .bolter => {
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const span = @min(input.len - off, 2 + rng.uintLessThan(usize, 7)); // 2..8
            for (out[off .. off + span]) |*b| b.* ^= 0xFF;
            return out;
        },
        .maxout => {
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const widths = [_]usize{ 1, 2, 4, 8 };
            const want = widths[rng.uintLessThan(usize, widths.len)];
            const span = @min(want, input.len - off);
            @memset(out[off .. off + span], 0xFF);
            return out;
        },
        .zero => {
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const span = @min(input.len - off, 1 + rng.uintLessThan(usize, max_region));
            @memset(out[off .. off + span], 0);
            return out;
        },
        .shotgun => {
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const span = @min(input.len - off, 1 + rng.uintLessThan(usize, max_region));
            for (out[off .. off + span]) |*b| b.* = rng.int(u8);
            return out;
        },
        .splice => {
            if (splice_src.len == 0) {
                // No donor — degrade to shotgun (still deterministic).
                return mutate(allocator, .shotgun, input, prefix_len, rng, &.{});
            }
            const out = try allocator.dupe(u8, input);
            const off = plen + rng.uintLessThan(usize, input.len - plen);
            const span = @min(input.len - off, 1 + rng.uintLessThan(usize, max_region));
            const src_off = rng.uintLessThan(usize, splice_src.len);
            const copy = @min(span, splice_src.len - src_off);
            @memcpy(out[off .. off + copy], splice_src[src_off .. src_off + copy]);
            return out;
        },
    }
}

// ── Tests (run via the fuzz build's own test step, NOT ./test) ──────────────

const testing = std.testing;

fn fixedRng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

test "sniper preserves length + prefix, flips exactly one bit" {
    const input = "MAGICabcdefghijklmnop";
    var prng = fixedRng(1);
    const out = try mutate(testing.allocator, .sniper, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(input.len, out.len);
    try testing.expectEqualSlices(u8, input[0..5], out[0..5]); // prefix intact
    // Exactly one bit differs across the whole buffer.
    var diff_bits: usize = 0;
    for (input, out) |a, b| diff_bits += @popCount(a ^ b);
    try testing.expectEqual(@as(usize, 1), diff_bits);
}

test "truncate keeps prefix and shortens" {
    const input = "MAGICabcdefghijklmnop";
    var prng = fixedRng(2);
    const out = try mutate(testing.allocator, .truncate, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expect(out.len < input.len);
    try testing.expect(out.len >= 5);
    try testing.expectEqualSlices(u8, input[0..out.len], out);
}

test "maxout writes an all-0xFF run inside the mutable window" {
    const input = "MAGIC0000000000000000000000";
    var prng = fixedRng(3);
    const out = try mutate(testing.allocator, .maxout, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(input.len, out.len);
    try testing.expectEqualSlices(u8, input[0..5], out[0..5]);
    // At least one 0xFF byte was introduced beyond the prefix.
    var found_ff = false;
    for (out[5..]) |b| {
        if (b == 0xFF) found_ff = true;
    }
    try testing.expect(found_ff);
}

test "bolter never touches the preserved prefix" {
    const input = "MAGICabcdefghijklmnop";
    var prng = fixedRng(4);
    const out = try mutate(testing.allocator, .bolter, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, input[0..5], out[0..5]);
}

test "splice degrades to shotgun with empty donor (no crash, same length)" {
    const input = "MAGICabcdefghijklmnop";
    var prng = fixedRng(5);
    const out = try mutate(testing.allocator, .splice, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expectEqual(input.len, out.len);
}

test "determinism: same seed yields identical output for every operator" {
    const input = "MAGICabcdefghijklmnopqrstuvwxyz0123456789";
    const donor = "ZZZZZZZZZZZZZZZZZZZZ";
    for (Operator.all) |op| {
        var p1 = fixedRng(99);
        var p2 = fixedRng(99);
        const a = try mutate(testing.allocator, op, input, 5, p1.random(), donor);
        defer testing.allocator.free(a);
        const b = try mutate(testing.allocator, op, input, 5, p2.random(), donor);
        defer testing.allocator.free(b);
        try testing.expectEqualSlices(u8, a, b);
    }
}

test "tiny input fully covered by prefix returns a copy" {
    const input = "AB";
    var prng = fixedRng(6);
    const out = try mutate(testing.allocator, .sniper, input, 5, prng.random(), &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, input, out);
}
