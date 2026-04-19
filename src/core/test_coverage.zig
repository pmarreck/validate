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
    sniper,   // flip one random bit
    shotgun,  // overwrite K random bytes at random offset
    header,   // shotgun restricted to first 10% of file
    tail,     // shotgun restricted to last 10% of file
    zeroed,   // zero-fill a K-byte region at random offset
    xor,      // XOR a K-byte region with a random pattern

    pub fn name(self: CorruptionMode) []const u8 {
        return switch (self) {
            .sniper => "sniper",
            .shotgun => "shotgun",
            .header => "header",
            .tail => "tail",
            .zeroed => "zeroed",
            .xor => "xor",
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
