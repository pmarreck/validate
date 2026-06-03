//! macOS Spotlight `.ivf-vector-indexes` reference-record decoding + rotation
//! deadlock detection.
//!
//! Background: each `~/Library/Metadata/CoreSpotlight/<domain>/index.spotlightV3/`
//! directory holds a committed `0.ivf-vector-indexes` plus rotation snapshots
//! `live.N.ivf-vector-indexes`. Each file is a tiny little-endian u32 record:
//!
//!     [ generation, MAGIC(0x015F1DA6), (id, type), (id, type), ..., (0,0)? ]
//!
//! A healthy domain's highest-generation rotation *drains* to an empty live set
//! (the indexer finished and committed). A stuck domain shows a monotonically
//! climbing `generation` with a non-draining live set — the `mds_stores`
//! `IVFVectorIndex::unlink` busy-loop: an index entry that can never be unlinked,
//! so each finalize attempt rotates a new `live.N` forever. This module exposes
//! the decode + a generic stuck-rotation heuristic so validate can flag the
//! deadlock-looking state mechanistically, without parsing the (undocumented)
//! IVF vector payload itself.
//!
//! Format reverse-engineered 2026-06-05 from a real stuck machine; see
//! docs/spotlight-ivf-deadlock-diagnosis-2026-06-05.md. Treat as best-effort:
//! callers should WARN, not hard-FAIL, on heuristic hits.

const std = @import("std");

/// Constant stamp present as the second u32 of every `.ivf-vector-indexes`
/// record observed (0x015F1DA6). Acts as a format/version sanity marker.
pub const IVF_MAGIC: u32 = 0x015F1DA6;

/// Maximum live-id entries we retain per record. Real records are tiny (≤ a
/// handful); this is a defensive cap so a malformed/huge file can't blow the
/// stack-backed buffer.
pub const MAX_LIVE_IDS: usize = 64;

pub const DecodeError = error{
    TooShort,
    BadMagic,
};

/// One decoded `.ivf-vector-indexes` reference record.
pub const IvfRecord = struct {
    generation: u32,
    magic_ok: bool,
    /// Live index-entry ids referenced by this rotation (the `(id,type)` pairs,
    /// excluding (0,0) terminators and zero ids). Truncated to MAX_LIVE_IDS.
    live_ids: [MAX_LIVE_IDS]u32 = undefined,
    live_count: usize = 0,
    /// True if the record had more live ids than MAX_LIVE_IDS (no silent cap).
    truncated: bool = false,

    pub fn liveSlice(self: *const IvfRecord) []const u32 {
        return self.live_ids[0..self.live_count];
    }

    pub fn hasId(self: *const IvfRecord, id: u32) bool {
        for (self.liveSlice()) |x| {
            if (x == id) return true;
        }
        return false;
    }
};

/// Decode a single `.ivf-vector-indexes` file image.
/// Layout: u32 generation, u32 magic, then (u32 id, u32 type) pairs; a (0,0)
/// pair or a zero id terminates / is skipped.
pub fn decodeRecord(data: []const u8) DecodeError!IvfRecord {
    if (data.len < 8) return DecodeError.TooShort;
    var rec: IvfRecord = .{
        .generation = readLeU32(data, 0),
        .magic_ok = readLeU32(data, 4) == IVF_MAGIC,
    };
    if (!rec.magic_ok) return DecodeError.BadMagic;

    // Walk (id, type) pairs starting at offset 8.
    var off: usize = 8;
    while (off + 8 <= data.len) : (off += 8) {
        const id = readLeU32(data, off);
        // type = readLeU32(data, off + 4); // currently unused (0x000A0012 seen)
        if (id == 0) continue; // (0,0) terminator / padding
        if (rec.live_count >= MAX_LIVE_IDS) {
            rec.truncated = true;
            break;
        }
        rec.live_ids[rec.live_count] = id;
        rec.live_count += 1;
    }
    return rec;
}

fn readLeU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

/// Verdict for one `index.spotlightV3` domain's rotation health.
pub const RotationHealth = enum {
    healthy,
    /// Generation gap is large but no single id is wedged across generations —
    /// busy but probably progressing; surface as INFO/soft-WARN.
    suspicious,
    /// A monotonically climbing generation with a non-draining live id across
    /// the most recent K rotations — the stuck-unlink deadlock signature.
    deadlock,
};

pub const RotationReport = struct {
    health: RotationHealth,
    committed_gen: u32,
    max_live_gen: u32,
    gen_gap: u32,
    rotation_count: usize,
    /// The id wedged across the recent window, if health == .deadlock.
    stuck_id: ?u32 = null,
    /// How many of the most-recent consecutive generations carried stuck_id.
    stuck_run: usize = 0,
};

/// Tuning knobs for the heuristic. Defaults chosen from the observed healthy
/// (gap ≤ 57, drains to empty) vs broken (gap > 400, id 532 across ≥8 gens)
/// machine; conservative so healthy-but-busy domains don't false-positive.
pub const RotationThresholds = struct {
    /// gen_gap above this with a non-empty terminal set → at least suspicious.
    suspicious_gap: u32 = 64,
    /// An id present in at least this many of the most-recent consecutive
    /// generations (and in the newest) → deadlock.
    stuck_run_min: usize = 6,
};

/// A committed record plus the rotation records, generic over how the caller
/// gathered them (file I/O lives in the adapter, not here).
pub const DomainRotations = struct {
    committed: IvfRecord,
    /// live.N records; order does NOT matter (we sort by generation internally).
    lives: []const IvfRecord,
};

/// Pure deadlock heuristic. Detects the "monotonic generation counter +
/// non-draining work set" signature that mechanically indicates a stuck
/// rotation/journal — reusable beyond Spotlight. No I/O, no allocation.
pub fn assessRotation(d: DomainRotations, t: RotationThresholds) RotationReport {
    var report: RotationReport = .{
        .health = .healthy,
        .committed_gen = d.committed.generation,
        .max_live_gen = d.committed.generation,
        .gen_gap = 0,
        .rotation_count = d.lives.len,
    };
    if (d.lives.len == 0) return report;

    // Find the newest (highest-generation) rotation, and the generation span.
    var newest: usize = 0;
    var min_gen: u32 = d.lives[0].generation;
    var max_gen: u32 = d.lives[0].generation;
    for (d.lives, 0..) |r, i| {
        if (r.generation > max_gen) {
            max_gen = r.generation;
            newest = i;
        }
        if (r.generation < min_gen) min_gen = r.generation;
    }
    report.max_live_gen = max_gen;
    report.gen_gap = max_gen -| d.committed.generation;

    const newest_rec = d.lives[newest];
    // Healthy: the newest rotation drained to an empty live set, regardless of
    // how large the gap got (the indexer finished its work).
    if (newest_rec.live_count == 0) {
        report.health = .healthy;
        return report;
    }

    // For each id live in the newest rotation, count how many of the most-recent
    // consecutive generations (descending from max) also carry it. A long run
    // that includes the newest = a never-draining (stuck) reference.
    // Build a generation-descending order.
    var order: [256]usize = undefined;
    const n = @min(d.lives.len, order.len);
    for (0..n) |i| order[i] = i;
    // simple insertion sort by generation desc (n is tiny)
    var a: usize = 1;
    while (a < n) : (a += 1) {
        const key = order[a];
        var b: isize = @as(isize, @intCast(a)) - 1;
        while (b >= 0 and d.lives[order[@intCast(b)]].generation < d.lives[key].generation) : (b -= 1) {
            order[@intCast(b + 1)] = order[@intCast(b)];
        }
        order[@intCast(b + 1)] = key;
    }

    var best_id: ?u32 = null;
    var best_run: usize = 0;
    for (newest_rec.liveSlice()) |id| {
        var run: usize = 0;
        for (0..n) |k| {
            if (d.lives[order[k]].hasId(id)) {
                run += 1;
            } else break; // must be a *consecutive* run from the newest
        }
        if (run > best_run) {
            best_run = run;
            best_id = id;
        }
    }

    if (best_id != null and best_run >= t.stuck_run_min) {
        report.health = .deadlock;
        report.stuck_id = best_id;
        report.stuck_run = best_run;
    } else if (report.gen_gap > t.suspicious_gap) {
        report.health = .suspicious;
    }
    return report;
}

// ============================== Tests ==============================

const testing = std.testing;

/// Build a synthetic `.ivf-vector-indexes` image: generation + magic + id pairs.
fn buildRecord(buf: []u8, generation: u32, ids: []const u32) []u8 {
    std.mem.writeInt(u32, buf[0..4], generation, .little);
    std.mem.writeInt(u32, buf[4..8], IVF_MAGIC, .little);
    var off: usize = 8;
    for (ids) |id| {
        std.mem.writeInt(u32, buf[off..][0..4], id, .little);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], 0x000A0012, .little); // observed type
        off += 8;
    }
    return buf[0..off];
}

test "decodeRecord: committed empty record" {
    var buf: [64]u8 = undefined;
    const img = buildRecord(&buf, 1, &.{});
    const rec = try decodeRecord(img);
    try testing.expectEqual(@as(u32, 1), rec.generation);
    try testing.expect(rec.magic_ok);
    try testing.expectEqual(@as(usize, 0), rec.live_count);
}

test "decodeRecord: live ids + terminator skipped" {
    var buf: [64]u8 = undefined;
    // ids 532,533,1054 then an explicit (0,0) terminator pair
    const img = buildRecord(&buf, 245, &.{ 532, 533, 1054, 0 });
    const rec = try decodeRecord(img);
    try testing.expectEqual(@as(u32, 245), rec.generation);
    try testing.expectEqual(@as(usize, 3), rec.live_count);
    try testing.expect(rec.hasId(532));
    try testing.expect(rec.hasId(1054));
    try testing.expect(!rec.hasId(999));
}

test "decodeRecord: bad magic + too short" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 7, .little);
    std.mem.writeInt(u32, buf[4..8], 0xDEADBEEF, .little);
    try testing.expectError(DecodeError.BadMagic, decodeRecord(buf[0..8]));
    try testing.expectError(DecodeError.TooShort, decodeRecord(buf[0..4]));
}

test "assessRotation: healthy domain drains to empty at top generation" {
    // Mirrors Priority: gap 57 but newest rotation has empty live set.
    var b0: [64]u8 = undefined;
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    const committed = try decodeRecord(buildRecord(&b0, 1, &.{}));
    const live_busy = try decodeRecord(buildRecord(&b1, 57, &.{ 366, 367 }));
    const live_drained = try decodeRecord(buildRecord(&b2, 58, &.{})); // newest, empty
    const lives = [_]IvfRecord{ live_busy, live_drained };
    const r = assessRotation(.{ .committed = committed, .lives = &lives }, .{});
    try testing.expectEqual(RotationHealth.healthy, r.health);
    try testing.expectEqual(@as(u32, 57), r.gen_gap);
}

test "assessRotation: deadlock — id wedged across recent generations" {
    // Mirrors NSFPCUFUA: id 532 present across the last 6+ generations, climbing.
    var bufs: [9][64]u8 = undefined;
    const committed = try decodeRecord(buildRecord(&bufs[0], 1, &.{}));
    var lives_arr: [8]IvfRecord = undefined;
    // generations 414..421, all carrying 532 (the stuck id); 1054 drains midway.
    const gens = [_]u32{ 414, 415, 416, 417, 418, 419, 420, 421 };
    const sets = [_][]const u32{
        &.{ 532, 1054 }, &.{532}, &.{532}, &.{532},
        &.{532},         &.{532}, &.{532}, &.{532},
    };
    for (0..8) |i| {
        lives_arr[i] = try decodeRecord(buildRecord(&bufs[i + 1], gens[i], sets[i]));
    }
    const r = assessRotation(.{ .committed = committed, .lives = &lives_arr }, .{});
    try testing.expectEqual(RotationHealth.deadlock, r.health);
    try testing.expectEqual(@as(u32, 532), r.stuck_id.?);
    try testing.expect(r.stuck_run >= 6);
}

test "assessRotation: suspicious — big gap but no single wedged id" {
    // Large gap, newest non-empty, but the live id changes each generation
    // (work is progressing, just slowly) → suspicious, not deadlock.
    var bufs: [8][64]u8 = undefined;
    const committed = try decodeRecord(buildRecord(&bufs[0], 1, &.{}));
    var lives_arr: [7]IvfRecord = undefined;
    const gens = [_]u32{ 100, 110, 120, 130, 140, 150, 160 };
    const sets = [_][]const u32{
        &.{10}, &.{11}, &.{12}, &.{13}, &.{14}, &.{15}, &.{16}, // all distinct
    };
    for (0..7) |i| {
        lives_arr[i] = try decodeRecord(buildRecord(&bufs[i + 1], gens[i], sets[i]));
    }
    const r = assessRotation(.{ .committed = committed, .lives = &lives_arr }, .{});
    try testing.expectEqual(RotationHealth.suspicious, r.health);
    try testing.expect(r.stuck_id == null);
}

test "assessRotation: empty rotation list is healthy" {
    var b0: [64]u8 = undefined;
    const committed = try decodeRecord(buildRecord(&b0, 1, &.{}));
    const lives = [_]IvfRecord{};
    const r = assessRotation(.{ .committed = committed, .lives = &lives }, .{});
    try testing.expectEqual(RotationHealth.healthy, r.health);
}
