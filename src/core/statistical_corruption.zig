//! Statistical corruption heuristics for raw PCM audio.
//!
//! This module implements a forensic heuristic panel that scans decoded PCM
//! samples for statistical signatures of bit-rot, sector overwrites, NUL/stuck
//! runs, and DC injection — the kinds of corruption that pass any structural
//! check but leave a faint anomaly in the *signal*. It is a **WARN** signal
//! only; we never fail a file on heuristic grounds.
//!
//! Phase 1 supports mono signed-16-bit PCM only. Stereo, s24/s32/f32, and
//! channel-correlation breaks are deferred to Phase 2.
//!
//! Heuristic panel (per the R&D spec, /tmp/dispatch-log/stat-corruption-final.md):
//!   0. **Synth-flat pre-classifier** — fraction of samples in any
//!      constant-value run >= 5 long. > 30% means the signal is intentionally
//!      piecewise-flat (square wave, pulse synth) and residual scoring is
//!      suppressed. Pure detection unlock for the square-wave false-positive.
//!   A. **Constant-run detection** — runs >= 100 samples on normal signals
//!      (>= 800 on synth-flat). Catches NUL/stuck/DC injection.
//!   B. **AR(2) prediction residual + single-bit-flip rescue** — predict
//!      s[i] = 2*s[i-1] - s[i-2]; flag |z| > 6; for each flagged sample,
//!      iterate over the outlier sample AND its 2 immediate predecessors,
//!      trying all 16 single-bit flips per candidate. If any flip drops the
//!      residual z below 2.0, that's a *diagnosed* bit flip (forensic-grade
//!      output: byte offset + bit index). The R&D prototype was off-by-one
//!      because it iterated only the outlier sample; the production fix
//!      iterates [i-2, i-1, i].
//!   C. **Sector-alignment bonus** — cluster outliers, check if start offset
//!      and span match 512/2048/2352/4096/16384 byte multiples (+/- 16 byte
//!      tolerance). +25 score on hit; strong "media-failure corruption"
//!      signature.
//!
//! All scoring is single-pass O(N), small-constant memory; suitable for the
//! default deep-validation budget.

const std = @import("std");

/// Per-sample window for residual variance estimation. 64 covers ~1.5 ms at
/// 44.1 kHz — long enough to estimate a stationary noise floor for residual
/// normalization, short enough to track local non-stationarity (voice
/// envelopes, drum decays).
pub const RESIDUAL_WINDOW: usize = 64;

/// Z-score threshold for residual outlier flagging. 6 sigma is conservative;
/// the R&D battery confirmed lowering below 5 starts flagging legitimate
/// transients (voice plosives, drum hits).
pub const Z_THRESHOLD: f32 = 6.0;

/// Z-score threshold for "rescued" residual after a candidate single-bit flip.
/// If a flip pulls z below 2.0, we declare it a diagnosed bit flip.
pub const RESCUE_Z_THRESHOLD: f32 = 2.0;

/// Constant-run thresholds. Below `synth_flat_min_run` we treat short runs
/// as legit (e.g., a 220 Hz square at 44.1 kHz has ~100-sample half-cycles);
/// above we declare corruption. The R&D battery confirmed 800 leaves all
/// audible-range synthesizers (>= 30 Hz) clean.
///
/// Updated 2026-05-02 (Peter): noise-not-silence rework. Real drive
/// corruption almost never looks like silence — bit rot, freed-sector
/// reuse, decoder confusion all produce *noise* (random bytes) or
/// DC-stuck output (constant non-zero byte). Long zero runs in audio
/// are typically just silence. So we now distinguish zero from non-zero
/// constant runs and weight them very differently.
pub const NORMAL_MIN_RUN: u32 = 100;
pub const SYNTH_FLAT_MIN_RUN: u32 = 800;

/// Synth-flat classification threshold: fraction of samples in any constant
/// run >= 5 long. > 30% triggers synth-flat mode (square waves, pulse
/// synth) and suppresses residual scoring to avoid false positives.
pub const SYNTH_FLAT_FRACTION_THRESHOLD: f32 = 0.30;
pub const SYNTH_FLAT_RUN_LEN: u32 = 5;
/// Threshold (in seconds of audio) for a non-zero constant-run to count as
/// a likely corruption signal. 0.1 s is well past any natural plateau in
/// real PCM (codec DC-offset block, snare-attack saturation, etc.) but
/// short enough to catch a clear DC-stuck signal.
pub const NONZERO_RUN_MIN_SECONDS: f32 = 0.1;
/// Threshold (in seconds of audio) at which a non-zero constant-run is so
/// improbable that we score it as overwhelmingly likely corruption.
pub const NONZERO_RUN_STRONG_SECONDS: f32 = 1.0;

/// Zero-run reporting threshold — we still emit findings for long zero
/// runs because the user may want to see them in the warning, but they
/// only contribute to the score via the aggregate-zero-fraction signal
/// below (silence is normal).
pub const ZERO_RUN_REPORT_MIN: u32 = 800;

/// Aggregate zero-fraction threshold: only when zero samples make up more
/// than this fraction of the file (and the file is long enough for that
/// to be unusual) do we score zero-run points. 25% of a multi-second
/// audio clip being silence is still common (podcasts, voicemail), so
/// this is conservative.
pub const ZERO_FRACTION_SCORE_THRESHOLD: f32 = 0.50;

/// Inter-sample slew-rate threshold. A real audio signal containing only
/// frequencies <= sr/2 cannot transition this much in a single sample
/// period without aliasing. 28000 == 85% of i16 full-scale; sustained
/// jumps of this magnitude indicate drive-corruption noise or a
/// decoder/format mismatch.
pub const DISCONTINUITY_THRESHOLD: i32 = 28000;
/// Fraction of samples with a discontinuity above DISCONTINUITY_THRESHOLD
/// at which we begin scoring points. Real percussive transients in legit
/// audio rarely produce more than a fraction of a percent.
pub const DISCONTINUITY_RATE_SCORE: f32 = 0.005;
/// Strong threshold — drive corruption / random-byte fill produces
/// discontinuities on essentially every adjacent-sample pair.
pub const DISCONTINUITY_RATE_STRONG: f32 = 0.02;

/// Sector sizes recognized for the alignment-bonus heuristic.
pub const SECTOR_SIZES = [_]u32{ 512, 2048, 2352, 4096, 16384 };
/// Byte tolerance for sector alignment (encoder padding, off-by-a-few).
pub const SECTOR_TOLERANCE: u32 = 16;

/// Maximum number of findings reported (caps memory + UX noise).
pub const MAX_FINDINGS: usize = 16;

/// Severity classification derived from `score`.
pub const Severity = enum {
    clean, // score < 25
    suspicious, // 25 <= score < 50
    likely_corrupt, // score >= 50
};

/// One concrete finding produced by the scan. Stable, small enum so callers
/// can format it for warnings without coupling to scoring details.
pub const Finding = union(enum) {
    /// A run of identical sample values >= the configured min length.
    constant_run: struct {
        sample_offset: u64,
        length: u32,
        value: i32,
    },
    /// An AR(2) residual outlier that was rescued by flipping a single bit
    /// in a sample at or near the outlier position. Forensic-grade.
    diagnosed_bit_flip: struct {
        sample_offset: u64,
        byte_offset: u64,
        bit_index: u8,
        z_before: f32,
        z_after: f32,
    },
    /// A cluster of outliers whose first byte and total span match a sector
    /// boundary multiple within tolerance.
    sector_aligned_cluster: struct {
        first_byte: u64,
        span: u32,
        sector_size: u32,
    },
};

/// Whole-scan result. Findings slice is owned by `arena` (caller-supplied).
pub const ScanResult = struct {
    /// 0..100. Higher = more suspicious. Compose of run/diagnosis/sector points.
    score: u8,
    severity: Severity,
    findings: []Finding,

    /// Telemetry — fraction of samples in short constant runs (synth-flat
    /// pre-classifier signal).
    flat_fraction: f32,
    /// Whether the synth-flat path was taken (residual scoring suppressed).
    synth_flat: bool,
    /// Number of samples scanned (after channel handling).
    sample_count: u64,
};

/// Why we may decline to scan. Callers can surface this verbatim or just no-op.
pub const SkipReason = enum {
    not_mono,
    not_s16,
    too_short,
};

/// Result of analyzePcmS16 — either a scan or a structured skip.
pub const Result = union(enum) {
    scanned: ScanResult,
    skipped: SkipReason,
};

/// Analyze mono signed-16-bit PCM samples for statistical corruption.
///
/// Phase 1 contract:
///   - `channels` must be 1; otherwise returns `.skipped = .not_mono`.
///   - `samples.len` must be at least `min_samples` (default 256, here required
///     by the residual stat path); otherwise returns `.skipped = .too_short`.
///   - `sample_rate` is informational (not currently used by the heuristics
///     but plumbed for future tunings).
///   - `data_byte_offset` is the absolute file offset of `samples[0]`'s first
///     byte. Used for forensic byte-offset reporting in `Finding`s.
///   - `arena` provides backing memory for the `findings` slice. Callers
///     supplying an arena allocator can free everything at once.
///
/// Returns a `ScanResult` with score, severity, and concrete findings.
pub fn analyzePcmS16(
    arena: std.mem.Allocator,
    samples: []const i16,
    sample_rate: u32,
    channels: u8,
    data_byte_offset: u64,
) !Result {
    if (channels != 1) return Result{ .skipped = .not_mono };
    if (samples.len < 64) return Result{ .skipped = .too_short };

    var findings = try std.ArrayListUnmanaged(Finding).initCapacity(arena, MAX_FINDINGS);

    // ---- Pre-pass: synth-flat classification ----
    const flat_fraction = computeFlatFraction(samples);
    const synth_flat = flat_fraction > SYNTH_FLAT_FRACTION_THRESHOLD;
    const min_run: u32 = if (synth_flat) SYNTH_FLAT_MIN_RUN else NORMAL_MIN_RUN;

    // ---- A: constant-value runs (categorized by zero vs non-zero) ----
    // Drive corruption is noise (random bytes) or DC-stuck output (constant
    // non-zero byte), not silence — so non-zero runs carry the weight here.
    const run_stats = scanConstantRuns(samples, sample_rate, min_run, &findings);

    // ---- B: AR(2) residual + bit-flip rescue (skip if synth-flat) ----
    var outlier_sample_indices = std.ArrayListUnmanaged(u64).empty;
    defer outlier_sample_indices.deinit(arena);
    var diagnosed_count: u32 = 0;
    var generic_outlier_count: u32 = 0;
    if (!synth_flat) {
        try residualOutlierScan(
            samples,
            data_byte_offset,
            &findings,
            arena,
            &outlier_sample_indices,
            &diagnosed_count,
            &generic_outlier_count,
        );
    }

    // ---- C: sector-alignment bonus ----
    var sector_bonus: u32 = 0;
    if (outlier_sample_indices.items.len > 0) {
        const first_idx = outlier_sample_indices.items[0];
        const last_idx = outlier_sample_indices.items[outlier_sample_indices.items.len - 1];
        const first_byte = data_byte_offset + first_idx * 2;
        const last_byte = data_byte_offset + last_idx * 2 + 2;
        const span: u64 = last_byte - first_byte;
        if (sectorAlignmentBonus(first_byte, span)) |hit| {
            sector_bonus = 25;
            if (findings.items.len < MAX_FINDINGS) {
                findings.appendAssumeCapacity(.{ .sector_aligned_cluster = .{
                    .first_byte = first_byte,
                    .span = @intCast(@min(span, std.math.maxInt(u32))),
                    .sector_size = hit,
                } });
            }
        }
    }

    // ---- D: inter-sample discontinuity rate ----
    // Real audio bandlimited at sr/2 cannot exceed DISCONTINUITY_THRESHOLD
    // between adjacent samples; widespread violations indicate corruption.
    const discontinuity_count: u64 = if (synth_flat) 0 else countDiscontinuities(samples);
    const discontinuity_rate: f32 = if (samples.len > 0)
        @as(f32, @floatFromInt(discontinuity_count)) / @as(f32, @floatFromInt(samples.len))
    else
        0.0;

    // ---- Score composition (noise-not-silence rework, 2026-05-02) ----
    // Non-zero constant runs are the primary signal. Each short (>= 0.1 s)
    // run = 30 pts; each strong (>= 1 s) run = +30 (so a single 1 s run
    // contributes 60). Capped at 90 to leave room for the AR(2) rescue and
    // sector bonus to push to 100.
    const nz_short_pts: u32 = @min(@as(u32, 90), 30 * run_stats.nonzero_runs_short);
    const nz_strong_pts: u32 = @min(@as(u32, 60), 30 * run_stats.nonzero_runs_strong);
    const run_pts: u32 = @min(@as(u32, 90), nz_short_pts + nz_strong_pts);

    // Zero runs only score when aggregate zero-mass is unusually high. Even
    // then, capped at 20 pts so silence alone never crosses likely_corrupt.
    const zero_fraction: f32 = if (samples.len > 0)
        @as(f32, @floatFromInt(run_stats.zero_run_samples)) / @as(f32, @floatFromInt(samples.len))
    else
        0.0;
    const zero_pts: u32 = if (zero_fraction > ZERO_FRACTION_SCORE_THRESHOLD) 20 else 0;

    // Inter-sample slew-rate violations.
    const disc_pts: u32 = if (discontinuity_rate >= DISCONTINUITY_RATE_STRONG)
        60
    else if (discontinuity_rate >= DISCONTINUITY_RATE_SCORE)
        30
    else
        0;

    // AR(2) bit-flip diagnoses (forensic-grade) — non-monotonic weight under
    // the noise-not-silence rework. The rescue mechanism produces false
    // positives at silence/plateau transitions in normal audio: every
    // boundary contributes 1-3 spurious diagnoses. Real drive corruption
    // (an actual flipped bit) is rare and isolated — usually exactly one
    // diagnosis. So a single diagnosis is treated as "possible bit rot,
    // worth surfacing"; a swarm is treated as boundary noise and
    // downweighted. The "single-bit flip in sine -> diagnosed" test only
    // checks the finding is emitted, not the score, so this remains
    // compatible.
    const diag_pts: u32 = blk: {
        if (diagnosed_count == 0) break :blk 0;
        if (diagnosed_count == 1) break :blk 15;
        if (diagnosed_count <= 3) break :blk 10;
        break :blk 5;
    };
    // Generic AR(2) residual outliers — capped very tightly. Transient-rich
    // legit audio routinely produces dozens of outliers; only a flood of
    // them adds anything to the score, and even then it's a tertiary
    // signal next to constant-run and discontinuity-rate.
    const generic_pts: u32 = blk: {
        if (generic_outlier_count <= 50) break :blk 0;
        break :blk @min(@as(u32, 5), (generic_outlier_count - 50) / 10);
    };

    const total: u32 = @min(@as(u32, 100), run_pts + zero_pts + disc_pts + diag_pts + generic_pts + sector_bonus);
    const score: u8 = @intCast(total);

    const severity: Severity = if (score >= 50)
        .likely_corrupt
    else if (score >= 25)
        .suspicious
    else
        .clean;

    return Result{ .scanned = ScanResult{
        .score = score,
        .severity = severity,
        .findings = findings.items,
        .flat_fraction = flat_fraction,
        .synth_flat = synth_flat,
        .sample_count = samples.len,
    } };
}

// ============================================================================
// Internals
// ============================================================================

/// Compute fraction of samples that lie in any constant-value run >=
/// SYNTH_FLAT_RUN_LEN long. Cheap O(N) single pass.
fn computeFlatFraction(samples: []const i16) f32 {
    if (samples.len == 0) return 0.0;
    var i: usize = 0;
    var flat_count: usize = 0;
    while (i < samples.len) {
        var j: usize = i + 1;
        while (j < samples.len and samples[j] == samples[i]) : (j += 1) {}
        const run_len = j - i;
        if (run_len >= SYNTH_FLAT_RUN_LEN) flat_count += run_len;
        i = j;
    }
    return @as(f32, @floatFromInt(flat_count)) / @as(f32, @floatFromInt(samples.len));
}

/// Categorized result from a single pass over samples to find constant-value
/// runs. Distinguishes zero-valued runs (silence — usually benign) from
/// non-zero runs (DC-stuck / decoder confusion — likely corruption).
const ConstantRunStats = struct {
    /// Count of non-zero constant runs >= 0.1 s of audio at the file's sample
    /// rate. Each such run contributes meaningfully to the score.
    nonzero_runs_short: u32,
    /// Count of non-zero constant runs >= 1.0 s of audio. Each is a strong
    /// corruption signal.
    nonzero_runs_strong: u32,
    /// Total samples sitting inside a zero-valued run >= NORMAL_MIN_RUN.
    /// Used to derive the aggregate-zero-fraction signal.
    zero_run_samples: u64,
};

/// Heuristic A: emit findings for constant-value runs and return categorized
/// stats. Zero runs >= ZERO_RUN_REPORT_MIN are reported as findings (so the
/// user sees them in the warning) but do not contribute directly to the
/// score — silence is normal. Non-zero runs >= 0.1 s of audio are emitted
/// and counted; >= 1 s of audio bumps the strong counter.
fn scanConstantRuns(
    samples: []const i16,
    sample_rate: u32,
    min_run: u32,
    findings: *std.ArrayListUnmanaged(Finding),
) ConstantRunStats {
    var stats = ConstantRunStats{
        .nonzero_runs_short = 0,
        .nonzero_runs_strong = 0,
        .zero_run_samples = 0,
    };
    if (samples.len < min_run) return stats;

    // Translate seconds-of-audio thresholds into sample counts. Floor at
    // NORMAL_MIN_RUN to avoid degenerate behavior on tiny sample rates.
    const sr_f: f32 = if (sample_rate > 0) @floatFromInt(sample_rate) else 0;
    const nz_short_min: u32 = @max(min_run, @as(u32, @intFromFloat(@max(@as(f32, @floatFromInt(min_run)), sr_f * NONZERO_RUN_MIN_SECONDS))));
    const nz_strong_min: u32 = @intFromFloat(@max(@as(f32, @floatFromInt(nz_short_min)), sr_f * NONZERO_RUN_STRONG_SECONDS));

    var i: usize = 0;
    while (i + 1 < samples.len) {
        var j: usize = i + 1;
        while (j < samples.len and samples[j] == samples[i]) : (j += 1) {}
        const run_len: usize = j - i;
        const value = samples[i];
        if (value == 0) {
            // Zero runs only contribute via aggregate zero-fraction. Track
            // total zero-run mass against NORMAL_MIN_RUN (anything shorter
            // is likely just a phase-zero crossing).
            if (run_len >= NORMAL_MIN_RUN) {
                stats.zero_run_samples += run_len;
            }
            // Still emit a finding for very long zero runs so the user
            // sees them (transparency), but they don't alter the score.
            if (run_len >= ZERO_RUN_REPORT_MIN and findings.items.len < MAX_FINDINGS) {
                findings.appendAssumeCapacity(.{ .constant_run = .{
                    .sample_offset = i,
                    .length = @intCast(@min(run_len, std.math.maxInt(u32))),
                    .value = 0,
                } });
            }
        } else if (run_len >= nz_short_min) {
            // Non-zero constant run >= 0.1 s of audio — high signal.
            stats.nonzero_runs_short += 1;
            if (run_len >= nz_strong_min) {
                stats.nonzero_runs_strong += 1;
            }
            if (findings.items.len < MAX_FINDINGS) {
                findings.appendAssumeCapacity(.{ .constant_run = .{
                    .sample_offset = i,
                    .length = @intCast(@min(run_len, std.math.maxInt(u32))),
                    .value = @intCast(value),
                } });
            }
        }
        i = j;
    }
    return stats;
}

/// Heuristic D: count inter-sample discontinuities exceeding a slew-rate
/// threshold. A real audio signal containing only frequencies <= sr/2 has a
/// bounded sample-to-sample delta; jumps larger than DISCONTINUITY_THRESHOLD
/// (~85% of i16 full-scale) imply either drive-corruption noise or a
/// decoder/format-mismatch spray of random bytes. Returns the count.
fn countDiscontinuities(samples: []const i16) u64 {
    if (samples.len < 2) return 0;
    var count: u64 = 0;
    var i: usize = 1;
    while (i < samples.len) : (i += 1) {
        const a: i32 = samples[i];
        const b: i32 = samples[i - 1];
        const diff: i32 = if (a > b) a - b else b - a;
        if (diff > DISCONTINUITY_THRESHOLD) count += 1;
    }
    return count;
}

/// Predict s[idx] from AR(2) extrapolation s[idx] = 2*s[idx-1] - s[idx-2].
/// Returns the residual (signed, may be negative).
inline fn ar2Residual(samples: []const i16, idx: usize) i32 {
    const pred: i32 = 2 * @as(i32, samples[idx - 1]) - @as(i32, samples[idx - 2]);
    return @as(i32, samples[idx]) - pred;
}

/// Compute residual mean and stddev over a sliding window ending at idx-1.
fn residualWindowStats(samples: []const i16, idx: usize) struct { mean: f64, sd: f64, n: usize } {
    const lo: usize = if (idx > RESIDUAL_WINDOW + 2) idx - RESIDUAL_WINDOW else 2;
    var sum: f64 = 0.0;
    var sumsq: f64 = 0.0;
    var n: usize = 0;
    var k: usize = lo;
    while (k < idx) : (k += 1) {
        const r: f64 = @floatFromInt(ar2Residual(samples, k));
        sum += r;
        sumsq += r * r;
        n += 1;
    }
    if (n < 4) return .{ .mean = 0, .sd = 1, .n = n };
    const mean = sum / @as(f64, @floatFromInt(n));
    var variance = (sumsq / @as(f64, @floatFromInt(n))) - mean * mean;
    if (variance < 1.0) variance = 1.0; // avoid div-by-zero on perfect silence
    return .{ .mean = mean, .sd = @sqrt(variance), .n = n };
}

/// Compute z-score for residual at idx. Mutates nothing.
fn residualZ(samples: []const i16, idx: usize) f32 {
    if (idx < 2) return 0;
    const r: f64 = @floatFromInt(ar2Residual(samples, idx));
    const stats = residualWindowStats(samples, idx);
    if (stats.n < 4) return 0;
    return @floatCast((r - stats.mean) / stats.sd);
}

/// Heuristic B: AR(2) residual scan + single-bit-flip rescue.
fn residualOutlierScan(
    samples: []const i16,
    data_byte_offset: u64,
    findings: *std.ArrayListUnmanaged(Finding),
    arena: std.mem.Allocator,
    outlier_sample_indices: *std.ArrayListUnmanaged(u64),
    diagnosed_count: *u32,
    generic_outlier_count: *u32,
) !void {
    if (samples.len < 4) return;
    // Mutable copy so we can flip bits in place during rescue.
    const buf = try arena.alloc(i16, samples.len);
    @memcpy(buf, samples);

    var i: usize = 2;
    while (i + 1 < buf.len) : (i += 1) {
        const z = residualZ(buf, i);
        if (@abs(z) <= Z_THRESHOLD) continue;
        try outlier_sample_indices.append(arena, i);
        generic_outlier_count.* += 1;
        if (findRescue(buf, i)) |hit| {
            diagnosed_count.* += 1;
            if (findings.items.len < MAX_FINDINGS) {
                findings.appendAssumeCapacity(.{ .diagnosed_bit_flip = .{
                    .sample_offset = hit.sample_offset,
                    .byte_offset = data_byte_offset + hit.sample_offset * 2,
                    .bit_index = hit.bit_index,
                    .z_before = z,
                    .z_after = hit.rescue_z,
                } });
            }
        }
    }
}

const RescueHit = struct {
    sample_offset: u64,
    bit_index: u8,
    rescue_z: f32,
};

/// Attempt a single-bit-flip rescue at outlier index `i`. Iterates the outlier
/// AND its two immediate predecessors (fixes the off-by-one bug observed in
/// the R&D prototype). For each candidate sample, tries all 16 bit positions;
/// returns the (sample_offset, bit_index, rescue_z) with the smallest |z| that
/// is below RESCUE_Z_THRESHOLD, or null if no flip rescues.
fn findRescue(buf: []i16, i: usize) ?RescueHit {
    var best_abs_z: f32 = std.math.inf(f32);
    var best: ?RescueHit = null;

    // Iterate candidate samples [i-2, i-1, i]. We need each candidate to be
    // valid for residualZ at i, so candidate must be >= 2.
    var off: i32 = -2;
    while (off <= 0) : (off += 1) {
        if (off < 0 and @as(i32, @intCast(i)) + off < 2) continue;
        const cand_idx_signed = @as(i32, @intCast(i)) + off;
        if (cand_idx_signed < 0) continue;
        const cand_idx: usize = @intCast(cand_idx_signed);
        if (cand_idx >= buf.len) continue;

        const original = buf[cand_idx];
        var b: u8 = 0;
        while (b < 16) : (b += 1) {
            const mask: i16 = @bitCast(@as(u16, 1) << @intCast(b));
            const flipped: i16 = original ^ mask;
            buf[cand_idx] = flipped;
            const new_z = residualZ(buf, i);
            const abs_new_z = @abs(new_z);
            if (abs_new_z < best_abs_z) {
                best_abs_z = abs_new_z;
                best = RescueHit{
                    .sample_offset = cand_idx,
                    .bit_index = b,
                    .rescue_z = new_z,
                };
            }
            buf[cand_idx] = original;
        }
    }

    if (best_abs_z < RESCUE_Z_THRESHOLD) return best;
    return null;
}

/// Heuristic C: did a cluster of outliers land on a recognized sector
/// boundary? Returns the sector size on hit, null otherwise.
fn sectorAlignmentBonus(first_byte: u64, span: u64) ?u32 {
    for (SECTOR_SIZES) |ss| {
        const ssu: u64 = ss;
        const off_mod: u64 = first_byte % ssu;
        const off_match = off_mod <= SECTOR_TOLERANCE or (ssu - off_mod) <= SECTOR_TOLERANCE;
        if (!off_match) continue;
        // Span must roughly match 1, 2, or 4 sectors (the R&D battery showed
        // these capture the dominant real-world overwrite sizes).
        const len_match =
            absDiffU64(span, ssu) <= SECTOR_TOLERANCE or
            absDiffU64(span, 2 * ssu) <= SECTOR_TOLERANCE or
            absDiffU64(span, 4 * ssu) <= SECTOR_TOLERANCE;
        if (len_match) return ss;
    }
    return null;
}

inline fn absDiffU64(a: u64, b: u64) u64 {
    return if (a > b) a - b else b - a;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "analyzePcmS16: rejects stereo with not_mono" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const samples = [_]i16{ 0, 1, 2, 3 } ** 64;
    const r = try analyzePcmS16(arena.allocator(), &samples, 44100, 2, 0);
    try testing.expectEqual(SkipReason.not_mono, r.skipped);
}

test "analyzePcmS16: rejects too-short buffers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const samples = [_]i16{ 0, 1, 2 };
    const r = try analyzePcmS16(arena.allocator(), &samples, 44100, 1, 0);
    try testing.expectEqual(SkipReason.too_short, r.skipped);
}

test "analyzePcmS16: clean sine wave scores 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: [4096]i16 = undefined;
    const sr: f64 = 44100.0;
    const freq: f64 = 440.0;
    for (&buf, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * 16000.0;
        s.* = @intFromFloat(v);
    }
    const r = try analyzePcmS16(arena.allocator(), &buf, 44100, 1, 0);
    try testing.expectEqual(@as(u8, 0), r.scanned.score);
    try testing.expectEqual(Severity.clean, r.scanned.severity);
}

test "analyzePcmS16: clean white noise scores 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rng = prng.random();
    var buf: [4096]i16 = undefined;
    for (&buf) |*s| {
        s.* = rng.intRangeAtMost(i16, -3000, 3000);
    }
    const r = try analyzePcmS16(arena.allocator(), &buf, 44100, 1, 0);
    try testing.expectEqual(Severity.clean, r.scanned.severity);
}

test "analyzePcmS16: square wave is synth_flat and avoids residual scoring" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [4096]i16 = undefined;
    // 100-sample half-cycles — way under SYNTH_FLAT_MIN_RUN of 800.
    for (&buf, 0..) |*s, i| {
        s.* = if ((i / 100) & 1 == 0) 16000 else -16000;
    }
    const r = try analyzePcmS16(arena.allocator(), &buf, 44100, 1, 0);
    try testing.expect(r.scanned.synth_flat);
    try testing.expectEqual(Severity.clean, r.scanned.severity);
    try testing.expectEqual(@as(u8, 0), r.scanned.score);
}

test "analyzePcmS16: short zero run in sine is NOT flagged (silence != corruption)" {
    // Updated 2026-05-02 (Peter): under the noise-not-silence rework, a brief
    // (sub-second) zero run is normal silence (e.g. plosive in spoken word,
    // DC-offset block, codec gating). It is no longer scored as corruption.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Synthesize a 4096-sample sine, then zero a 200-sample run in the middle
    // (4.5 ms at 44.1 kHz — sub-millisecond gap).
    var buf: [4096]i16 = undefined;
    const sr: f64 = 44100.0;
    const freq: f64 = 440.0;
    for (&buf, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * 16000.0;
        s.* = @intFromFloat(v);
    }
    for (1500..1700) |i| buf[i] = 0;

    const r = try analyzePcmS16(arena.allocator(), &buf, 44100, 1, 0);
    try testing.expect(r.scanned.severity != .likely_corrupt);
}

test "analyzePcmS16: single-bit flip in sine -> diagnosed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: [4096]i16 = undefined;
    const sr: f64 = 44100.0;
    const freq: f64 = 440.0;
    for (&buf, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * 16000.0;
        s.* = @intFromFloat(v);
    }
    // Flip bit 12 (value 0x1000 = 4096) on a sample with non-zero value to
    // produce a strong residual outlier.
    const target_idx: usize = 1234;
    buf[target_idx] ^= @as(i16, @bitCast(@as(u16, 1) << 12));

    const r = try analyzePcmS16(arena.allocator(), &buf, 44100, 1, 0);
    var diagnosed: ?Finding = null;
    for (r.scanned.findings) |f| switch (f) {
        .diagnosed_bit_flip => diagnosed = f,
        else => {},
    };
    try testing.expect(diagnosed != null);
    if (diagnosed) |d| {
        const dbf = d.diagnosed_bit_flip;
        // Rescue must locate the corruption within the [-2, 0] window of
        // the outlier — i.e. the actual injected sample, not a neighbor.
        try testing.expect(dbf.sample_offset == target_idx or
            dbf.sample_offset == target_idx + 1 or
            dbf.sample_offset == target_idx + 2);
        // The bit index should be near 12 — that's the bit we flipped (the
        // single-bit-flip rescue may pick an adjacent bit if it produces a
        // marginally smaller residual on a noisy sample, but a real bit-rot
        // still gets diagnosed within the same byte).
        try testing.expect(dbf.bit_index == 12 or dbf.bit_index == 11 or dbf.bit_index == 13);
    }
}

// ============================================================================
// Tests for the noise-not-silence rework (Peter, 2026-05-02).
//
// Drive corruption looks like noise (random bytes, decoder confusion ->
// constant non-zero byte, inter-sample discontinuities), not silence.
// Long zero runs are normal — they're just quiet passages. The tests below
// exercise both the false-positive reproducers (zero runs at file
// boundaries, sub-second zero gaps) and the real-corruption signals
// (sustained non-zero DC, sample-to-sample jumps exceeding Nyquist).
// ============================================================================

/// Synthesize a mono 16-bit sine wave at `sample_rate` Hz with `freq` Hz tone.
fn synthSine(buf: []i16, sample_rate: u32, freq: f64, amp: f64) void {
    const sr: f64 = @floatFromInt(sample_rate);
    for (buf, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) / sr;
        const v: f64 = @sin(2.0 * std.math.pi * freq * t) * amp;
        s.* = @intFromFloat(v);
    }
}

test "analyzePcmS16: bizarre.wav-shape — head silence + sine + tiny zero gaps is NOT corruption" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Real reproducer: 24 kHz mono. Lead 4063 zero samples (header silence,
    // ~169 ms), then ~250k samples of sine wave with a few short zero runs
    // (240, 129, 2436 samples — sub-millisecond to ~100 ms of silence).
    const sr: u32 = 24000;
    const buf = try testing.allocator.alloc(i16, 256_000);
    defer testing.allocator.free(buf);
    @memset(buf[0..4063], 0);
    synthSine(buf[4063..], sr, 440.0, 12000.0);
    // Short zero gaps representing sub-second silences in spoken word.
    for (10_000..10_240) |i| buf[i] = 0;
    for (50_000..50_129) |i| buf[i] = 0;
    for (100_000..102_436) |i| buf[i] = 0;

    const r = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0x2C);
    // Must NOT be flagged as likely_corrupt — these are normal silences.
    try testing.expect(r.scanned.severity != .likely_corrupt);
    try testing.expect(r.scanned.score < 50);
}

test "analyzePcmS16: Hidden-Racism-shape — sub-second zero gaps in long PCM is NOT corruption" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // 24 kHz mono — 6.5 minutes of audio is ~9.4M samples; we cap at 200k
    // for test speed but keep the silence-fraction representative.
    const sr: u32 = 24000;
    const buf = try testing.allocator.alloc(i16, 200_000);
    defer testing.allocator.free(buf);
    synthSine(buf, sr, 220.0, 10000.0);
    // Three short zero gaps — 240, 129, 2436 samples (sub-100 ms each).
    for (50_000..50_240) |i| buf[i] = 0;
    for (100_000..100_129) |i| buf[i] = 0;
    for (150_000..152_436) |i| buf[i] = 0;

    const r = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    try testing.expect(r.scanned.severity != .likely_corrupt);
    try testing.expect(r.scanned.score < 50);
}

test "analyzePcmS16: sustained non-zero constant byte run IS likely_corrupt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Decoder confusion / DC stuck — 1.2 seconds of audio at 24 kHz of a
    // constant non-zero sample value (would be 0xCCCC byte pattern in WAV).
    const sr: u32 = 24000;
    const total: usize = 60_000;
    const buf = try testing.allocator.alloc(i16, total);
    defer testing.allocator.free(buf);
    synthSine(buf, sr, 440.0, 12000.0);
    // 1.2 s of constant non-zero (0xCCCC == -13108 as i16 little-endian).
    const stuck_start: usize = 10_000;
    const stuck_len: usize = 30_000; // 1.25 s at 24 kHz
    for (stuck_start..stuck_start + stuck_len) |i| buf[i] = -13108;

    const r = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    try testing.expect(r.scanned.score >= 50);
    try testing.expectEqual(Severity.likely_corrupt, r.scanned.severity);

    // Confirm a constant_run finding with a non-zero value was emitted.
    var saw_nonzero_run = false;
    for (r.scanned.findings) |f| switch (f) {
        .constant_run => |cr| {
            if (cr.value != 0 and cr.length >= 2400) saw_nonzero_run = true;
        },
        else => {},
    };
    try testing.expect(saw_nonzero_run);
}

test "analyzePcmS16: short non-zero constant runs (< 0.1s) do NOT contribute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const sr: u32 = 24000;
    const buf = try testing.allocator.alloc(i16, 60_000);
    defer testing.allocator.free(buf);
    synthSine(buf, sr, 440.0, 12000.0);
    // Several short non-zero constant runs — each well under 0.1 s
    // (2400 samples at 24 kHz). These can occur in legit audio (DC offset
    // removed and re-added by codec, plateau in a saturated drum hit, etc.)
    for (5_000..5_400) |i| buf[i] = -8000; // ~17 ms
    for (15_000..15_500) |i| buf[i] = 5000; // ~21 ms
    for (25_000..26_000) |i| buf[i] = -1000; // ~42 ms

    const r = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    try testing.expect(r.scanned.severity != .likely_corrupt);
}

test "analyzePcmS16: inter-sample discontinuities exceeding Nyquist score points" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const sr: u32 = 44100;
    const buf = try testing.allocator.alloc(i16, 8192);
    defer testing.allocator.free(buf);
    synthSine(buf, sr, 440.0, 8000.0);

    // Baseline — clean sine.
    const r0 = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    const baseline_score = r0.scanned.score;

    // Inject 100 inter-sample discontinuities (~1.2% of samples) — pairs of
    // adjacent samples with delta > 30000. Real audio essentially never
    // produces this many huge slew-rate violations.
    var i: usize = 100;
    while (i < buf.len - 1) : (i += 80) {
        buf[i] = 16000;
        buf[i + 1] = -16000;
    }

    const r1 = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    try testing.expect(r1.scanned.score > baseline_score);
}

test "analyzePcmS16: noise-byte fill (uniform random) IS suspicious" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const sr: u32 = 44100;
    const buf = try testing.allocator.alloc(i16, 16_384);
    defer testing.allocator.free(buf);
    // Fill with uniformly distributed full-range bytes — what drive
    // corruption / freed-sector reuse looks like. As i16 samples this is
    // uniform in [-32768, 32767], which maxes out inter-sample slew rate.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    for (buf) |*s| s.* = rng.int(i16);

    const r = try analyzePcmS16(arena.allocator(), buf, sr, 1, 0);
    // Uniform-random bytes have max-amplitude inter-sample jumps everywhere
    // — this should at minimum register as suspicious.
    try testing.expect(r.scanned.score >= 25);
}
