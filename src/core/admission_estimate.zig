//! Per-format admission-reserve estimation for the batch memory gate.
//!
//! The memory budget admits tasks by *estimated* working set. stat.size alone
//! under-estimates formats whose decode residency is pixel-buffer- or
//! decompression-proportional (witnessed 2026-08-15: a 64 MB JXL decoding to
//! 2.07 GB anonymous — 33x), and over-estimates formats proven to stream via
//! evictable pages. This module owns the evidence-seeded multiplier table and
//! the refusal text for wedge-class files (estimate exceeds the whole
//! budget), which the batch layer refuses with an indeterminate verdict.
//!
//! Pure (no I/O): callers supply the path and the base size; this module only
//! classifies and multiplies. Keep the table SMALL and every row cited.

const std = @import("std");

/// Blanket multiplier for formats with no measured evidence. Decode residency
/// measured 1x-33x stat.size across the 2026-08-15 corpus; 2x is the
/// conservative floor for the unmeasured middle.
pub const DEFAULT_MULTIPLIER: usize = 2;

/// Residency ceiling for families PROVEN to stream (memory-ceiling gate,
/// tests/cli/streaming_expected.tsv): audio fixtures 256 MiB+ completed under
/// a 64 MiB cgroup ceiling because their file pages stay clean/evictable.
/// Extrapolation to larger files is by mechanism (page-cache eviction is
/// size-independent), not by direct witness at every size.
pub const STREAMING_RESIDENCY_CAP_BYTES: usize = 64 * 1024 * 1024;

/// Render the per-file WARN message for a refused over-budget file (no path;
/// the result is already per-file). Pure formatting; single line, no newline.
pub fn formatRefusalWarning(buf: []u8, reserve_bytes: usize, budget_total: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "deep validation refused: estimated working set {d} MiB exceeds memory budget {d} MiB (raise --max-memory to validate)",
        .{ ceilMiB(reserve_bytes), ceilMiB(budget_total) },
    ) catch buf[0..0];
}

const FormatMultiplier = struct {
    /// Case-insensitive path suffix including the dot (matches the
    /// heapDebugFormatHint convention in ffi/c_api.zig).
    suffix: []const u8,
    multiplier: usize,
    /// Residency ceiling for families with a PROVEN streaming path: their
    /// working set is bounded regardless of file size, so the reserve is
    /// min(size * multiplier, cap) and they can never be wedge-class.
    residency_cap_bytes: ?usize = null,
};

/// Evidence-seeded rows. Cite the measurement when adding one:
/// - .jxl 33x: 64 MB file -> 2.07 GB anonymous residency (pixel-buffer
///   proportional; 2026-08-15 91.7 GB corpus scan, PLAN.md task #28).
/// - .mkv/.webm 3x: Matroska ContentCompression measured ~2.08x expansion;
///   ceil plus margin. NOT residency-capped: h265_mkv streams but mkv_cc is
///   resident, and the extension cannot tell them apart at admission.
/// - .mp3/.flac/.wav 1x + 64 MiB cap: every family behind these extensions
///   is proven `streams` under the memory-ceiling gate
///   (tests/cli/streaming_expected.tsv, witnessed 2026-08-15). Extensions
///   with a MIX of streaming and resident families (.mp4: h264 streams,
///   h265 resident; .ogg: opus/vorbis resident) get no cap.
const format_multipliers = [_]FormatMultiplier{
    .{ .suffix = ".jxl", .multiplier = 33 },
    .{ .suffix = ".mkv", .multiplier = 3 },
    .{ .suffix = ".webm", .multiplier = 3 },
    .{ .suffix = ".mp3", .multiplier = 1, .residency_cap_bytes = STREAMING_RESIDENCY_CAP_BYTES },
    .{ .suffix = ".flac", .multiplier = 1, .residency_cap_bytes = STREAMING_RESIDENCY_CAP_BYTES },
    .{ .suffix = ".wav", .multiplier = 1, .residency_cap_bytes = STREAMING_RESIDENCY_CAP_BYTES },
};

/// Admission-reserve multiplier for a path, from the cheapest format signal
/// available at admission time (extension suffix; magic would require an
/// open+read per file before the gate). Unknown formats get the conservative
/// DEFAULT_MULTIPLIER. complexity: O(table size * suffix length)
pub fn multiplierForPath(path: []const u8) usize {
    return (rowForPath(path) orelse return DEFAULT_MULTIPLIER).multiplier;
}

fn rowForPath(path: []const u8) ?FormatMultiplier {
    for (format_multipliers) |row| {
        if (path.len >= row.suffix.len and
            std.ascii.eqlIgnoreCase(path[path.len - row.suffix.len ..], row.suffix))
        {
            return row;
        }
    }
    return null;
}

/// Bytes the admission gate should reserve for `path` given a base size from
/// enumeration/stat. Saturating multiply: a near-maxInt base clamps instead
/// of wrapping; wedge classification (reserve > whole budget => refuse) is
/// the caller's job via isWedge. Streaming-proven rows are residency-capped.
pub fn reserveBytesForPath(path: []const u8, base_bytes: usize) usize {
    const row = rowForPath(path) orelse return base_bytes *| DEFAULT_MULTIPLIER;
    const raw = base_bytes *| row.multiplier;
    if (row.residency_cap_bytes) |cap| return @min(raw, cap);
    return raw;
}

/// True when a task's reserve can never fit the budget. Such a file must be
/// REFUSED with an honest indeterminate verdict, never admitted unbounded:
/// field OOM #2 (2026-08-19) saw an 87 GB HEVC MKV admitted "alone" slurp
/// ~13 GB/min anonymous memory to a 90.2 G cgroup kill on a 125 G box.
/// Admission cannot bound a decode once it starts. Files whose reserve fits
/// the total budget but not the current free share simply wait (ordinary
/// acquire blocking) — that serialization stays.
pub fn isWedge(reserve_bytes: usize, budget_total: usize) bool {
    return reserve_bytes > budget_total;
}

/// Render the single-line user note for a wedge-class file. Pure formatting;
/// the caller owns the sink (stderr in the CLI). Returns a slice of `buf`.
pub fn formatWedgeNote(buf: []u8, path: []const u8, reserve_bytes: usize, budget_total: usize) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "NOTE: {s}: estimated working set {d} MiB exceeds memory budget {d} MiB; deep validation refused (raise --max-memory to validate)\n",
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

test "streaming-proven formats are residency-capped and can never be wedge-class" {
    // The memory-ceiling gate witnessed these families completing under a
    // 64 MiB cgroup ceiling (file pages stay clean/evictable; anonymous
    // residency is bounded, not size-proportional). Their reserve is
    // min(size, 64 MiB), so a huge streaming file is admitted normally
    // instead of being refused as over-budget.
    const ten_gb: usize = 10 * 1024 * 1024 * 1024;
    try std.testing.expectEqual(STREAMING_RESIDENCY_CAP_BYTES, reserveBytesForPath("/music/huge.wav", ten_gb));
    try std.testing.expectEqual(STREAMING_RESIDENCY_CAP_BYTES, reserveBytesForPath("/music/huge.flac", ten_gb));
    try std.testing.expectEqual(STREAMING_RESIDENCY_CAP_BYTES, reserveBytesForPath("/music/huge.mp3", ten_gb));
    // Small streaming files reserve their own size (the cap is an upper bound).
    try std.testing.expectEqual(@as(usize, 100), reserveBytesForPath("/music/small.wav", 100));
    // Non-streaming formats stay size-proportional: a 10 GB default-format
    // file estimates 20 GB and CAN be wedge-class (refused by the caller).
    try std.testing.expectEqual(ten_gb *| 2, reserveBytesForPath("/data/huge.bin", ten_gb));
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

test "formatWedgeNote names the path, sizes in MiB, and the refusal" {
    // Field OOM #2 (2026-08-19): an 87 GB HEVC MKV admitted "alone" slurped
    // ~13 GB/min anonymous to a 90.2 G cgroup kill. Over-budget estimates are
    // REFUSED, not run alone — the note must say so.
    var buf: [512]u8 = undefined;
    const note = formatWedgeNote(&buf, "/scan/huge.jxl", 2 * 1024 * 1024 * 1024, 1024 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, note, "/scan/huge.jxl") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "2048 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "1024 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "refus") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "max-memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "alone") == null);
    try std.testing.expect(std.mem.endsWith(u8, note, "\n"));
}

test "formatWedgeNote rounds sub-MiB reserves up so the note never says 0 MiB" {
    var buf: [512]u8 = undefined;
    const note = formatWedgeNote(&buf, "/tiny", 1, 0);
    try std.testing.expect(std.mem.indexOf(u8, note, "1 MiB") != null);
}

test "formatRefusalWarning explains the honest indeterminate verdict without the path" {
    var buf: [256]u8 = undefined;
    const warning = formatRefusalWarning(&buf, 2 * 1024 * 1024 * 1024, 1024 * 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, warning, "refus") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "2048 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "1024 MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "max-memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, warning, "\n") == null);
}
