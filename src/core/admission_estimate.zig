//! Per-format admission-reserve estimation for the batch memory gate.
//!
//! The memory budget admits tasks by *estimated* working set. stat.size alone
//! under-estimates formats whose decode residency is pixel-buffer- or
//! decompression-proportional (witnessed 2026-08-15: a 64 MB JXL decoding to
//! 2.07 GB anonymous — 33x), and over-estimates formats proven to stream via
//! evictable pages. This module owns the evidence-seeded multiplier table and
//! the wedge-note text for files whose estimate exceeds the whole budget.
//!
//! Pure (no I/O): callers supply the path and the base size; this module only
//! classifies and multiplies. Keep the table SMALL and every row cited.

const std = @import("std");

/// Blanket multiplier for formats with no measured evidence. Decode residency
/// measured 1x-33x stat.size across the 2026-08-15 corpus; 2x is the
/// conservative floor for the unmeasured middle.
pub const DEFAULT_MULTIPLIER: usize = 2;

const FormatMultiplier = struct {
    /// Case-insensitive path suffix including the dot (matches the
    /// heapDebugFormatHint convention in ffi/c_api.zig).
    suffix: []const u8,
    multiplier: usize,
};

/// Evidence-seeded rows. Cite the measurement when adding one:
/// - .jxl 33x: 64 MB file -> 2.07 GB anonymous residency (pixel-buffer
///   proportional; 2026-08-15 91.7 GB corpus scan, PLAN.md task #28).
/// - .mkv/.webm 3x: Matroska ContentCompression measured ~2.08x expansion;
///   ceil plus margin.
/// - .mp3/.flac/.wav 1x: proven `streams` under the memory-ceiling gate
///   (tests/cli/streaming_expected.tsv, witnessed 2026-08-15) — residency is
///   bounded well below stat.size, so the blanket 2x only wastes admission
///   concurrency.
const format_multipliers = [_]FormatMultiplier{
    .{ .suffix = ".jxl", .multiplier = 33 },
    .{ .suffix = ".mkv", .multiplier = 3 },
    .{ .suffix = ".webm", .multiplier = 3 },
    .{ .suffix = ".mp3", .multiplier = 1 },
    .{ .suffix = ".flac", .multiplier = 1 },
    .{ .suffix = ".wav", .multiplier = 1 },
};

/// Admission-reserve multiplier for a path, from the cheapest format signal
/// available at admission time (extension suffix; magic would require an
/// open+read per file before the gate). Unknown formats get the conservative
/// DEFAULT_MULTIPLIER. complexity: O(table size * suffix length)
pub fn multiplierForPath(path: []const u8) usize {
    for (format_multipliers) |row| {
        if (path.len >= row.suffix.len and
            std.ascii.eqlIgnoreCase(path[path.len - row.suffix.len ..], row.suffix))
        {
            return row.multiplier;
        }
    }
    return DEFAULT_MULTIPLIER;
}

/// Bytes the admission gate should reserve for `path` given a base size from
/// enumeration/stat. Saturating multiply: a near-maxInt base clamps instead
/// of wrapping; the budget's oversized-task rule handles the clamped value.
pub fn reserveBytesForPath(path: []const u8, base_bytes: usize) usize {
    return base_bytes *| multiplierForPath(path);
}

/// True when a task's reserve can never fit the budget: it will be admitted
/// alone (MemoryBudget's oversized rule) rather than refused or left to
/// starve peers, and the caller should surface a note saying so.
pub fn isWedge(reserve_bytes: usize, budget_total: usize) bool {
    return reserve_bytes > budget_total;
}

/// Render the single-line user note for a wedge-class file. Pure formatting;
/// the caller owns the sink (stderr in the CLI). Returns a slice of `buf`.
pub fn formatWedgeNote(buf: []u8, path: []const u8, reserve_bytes: usize, budget_total: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "NOTE: {s}: estimated working set {d} MiB exceeds memory budget {d} MiB; validating alone when the pool drains\n",
        .{ path, ceilMiB(reserve_bytes), ceilMiB(budget_total) },
    ) catch buf[0..0]; // buffer too small for the path: drop the note, never truncate mid-path
}

/// Bytes -> whole MiB, rounded up so a nonzero reserve never reads "0 MiB".
fn ceilMiB(bytes: usize) usize {
    return (bytes + (1 << 20) - 1) >> 20;
}

// ===== Tests =====

test "known amplifying formats get evidence-seeded multipliers" {
    // JXL: pixel-buffer proportional, witnessed 33x.
    try std.testing.expectEqual(@as(usize, 33), multiplierForPath("/scan/photo.jxl"));
    // Case-insensitive, as extensions in the wild are.
    try std.testing.expectEqual(@as(usize, 33), multiplierForPath("C:\\pics\\PHOTO.JXL"));
    // Matroska ContentCompression ~2.08x, reserved with margin.
    try std.testing.expectEqual(@as(usize, 3), multiplierForPath("/movies/film.mkv"));
    try std.testing.expectEqual(@as(usize, 3), multiplierForPath("/movies/clip.WebM"));
}

test "streaming-proven formats reserve 1x" {
    try std.testing.expectEqual(@as(usize, 1), multiplierForPath("/music/track.mp3"));
    try std.testing.expectEqual(@as(usize, 1), multiplierForPath("/music/track.FLAC"));
    try std.testing.expectEqual(@as(usize, 1), multiplierForPath("/music/take 1.wav"));
}

test "unmeasured formats keep the conservative default multiplier" {
    try std.testing.expectEqual(DEFAULT_MULTIPLIER, multiplierForPath("/docs/report.pdf"));
    try std.testing.expectEqual(DEFAULT_MULTIPLIER, multiplierForPath("/movies/film.mp4")); // h265/mp4 is resident
    try std.testing.expectEqual(DEFAULT_MULTIPLIER, multiplierForPath("no_extension"));
    try std.testing.expectEqual(DEFAULT_MULTIPLIER, multiplierForPath(""));
    try std.testing.expectEqual(DEFAULT_MULTIPLIER, multiplierForPath("/dir/trailing-dot."));
}

test "reserveBytesForPath multiplies and saturates" {
    try std.testing.expectEqual(@as(usize, 3300), reserveBytesForPath("/a/b.jxl", 100));
    try std.testing.expectEqual(@as(usize, 200), reserveBytesForPath("/a/b.dat", 100));
    try std.testing.expectEqual(@as(usize, 100), reserveBytesForPath("/a/b.wav", 100));
    try std.testing.expectEqual(
        @as(usize, std.math.maxInt(usize)),
        reserveBytesForPath("/a/b.jxl", std.math.maxInt(usize) / 2),
    );
}

test "isWedge is strict excess over the whole budget" {
    try std.testing.expect(isWedge(1025, 1024));
    try std.testing.expect(!isWedge(1024, 1024));
    try std.testing.expect(!isWedge(0, 1024));
}

test "formatWedgeNote names the path, sizes in MiB, and the serialize action" {
    var buf: [512]u8 = undefined;
    const note = formatWedgeNote(&buf, "/scan/huge.jxl", 2 * 1024 * 1024 * 1024, 1024 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, note, "/scan/huge.jxl") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "2048 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "1024 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "alone") != null);
    try std.testing.expect(std.mem.endsWith(u8, note, "\n"));
}

test "formatWedgeNote rounds sub-MiB reserves up so the note never says 0 MiB" {
    var buf: [512]u8 = undefined;
    const note = formatWedgeNote(&buf, "/tiny", 1, 0);
    try std.testing.expect(std.mem.indexOf(u8, note, "1 MiB") != null);
}
