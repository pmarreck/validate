//! In-memory deterministic fuzz sweep driver (Tier-1).
//!
//! Loads each corpus file given on the command line, applies the deterministic
//! mutation operators from `mutate.zig`, and routes every mutated buffer through
//! validate's full detect→shallow→deep dispatch (`dispatch.runOne`). RAM-first:
//! no temp files on the hot path. Directory enumeration is the bash runner's
//! job (hexagonal — I/O at the edges); this driver takes explicit file paths.
//!
//! ## Two-tier oracle
//!  1. ROBUSTNESS (always): any crash/hang/OOM/UB is a found bug. A Zig panic is
//!     caught by the custom panic handler below, which dumps the reproducing
//!     descriptor + the exact bytes before aborting. Hangs are caught by a
//!     watchdog thread. This is the universal, always-sound assertion.
//!  2. DETECTION (conditional): for integrity-backed formats only
//!     (`maxAchievableDepth()==.full`) we additionally assert that corrupting a
//!     byte inside the format's integrity-covered region flips the verdict to
//!     INVALID. Implemented as targeted probes over an integrity-region table
//!     (seeded with gzip's trailing CRC32) — NOT over the blind random
//!     mutations, which may legitimately land on tolerant payload bytes.
//!
//! ## Determinism
//! All mutation choices derive from a seeded PRNG (`--seed`). No wall-clock, no
//! /dev/urandom in input generation. Every crash reproduces from its
//! (seed, file, operator, iteration, prefix) descriptor. The watchdog's timeout
//! uses wall-clock — that is a safety mechanism, not input generation.

const std = @import("std");
const core = @import("core");
const fv = core.format_validation;
const dispatch = @import("dispatch.zig");
const mutate = @import("mutate.zig");

// ── Custom panic handler: attribute a crash to its reproducing input ────────
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    dumpCrash("PANIC", msg);
    std.debug.defaultPanic(msg, first_trace_addr);
}

// ── Hardware-fault capture (SEGV/BUS/ILL/FPE bypass the Zig panic handler) ───
// A segfault is delivered as a POSIX signal, NOT a Zig panic, so without this
// the reproducing bytes would be lost (the original jbig2 segv had no saved
// reproducer until this was added). The handler dumps the in-flight descriptor
// + bytes, then exits. Not strictly async-signal-safe, but the process is dying
// and capturing the reproducer is what matters.
fn installCrashHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    inline for (.{ std.posix.SIG.SEGV, std.posix.SIG.BUS, std.posix.SIG.ILL, std.posix.SIG.FPE }) |s| {
        std.posix.sigaction(s, &act, null);
    }
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    dumpCrash("SIGNAL", @tagName(sig));
    std.process.exit(139);
}

// ── Crash-attribution globals (set before each dispatch, read on crash/hang) ─
var g_crash_dir: []const u8 = "fuzz-crashes";
var g_cur_seed: u64 = 0;
var g_cur_file: []const u8 = "";
var g_cur_op: []const u8 = "<none>";
var g_cur_iter: usize = 0;
var g_cur_prefix: usize = 0;
var g_cur_input: []const u8 = &.{};
// Wall-clock deadline (ms) for the in-flight dispatch; 0 = idle. Watchdog only.
var g_deadline_ms: std.atomic.Value(i64) = .init(0);
var g_detection_failures: usize = 0;
var g_detection_passes: usize = 0;

/// Write the in-flight reproducer bytes + descriptor without allocating (the
/// heap may be corrupt during a panic). Path/desc built in stack buffers.
fn dumpCrash(kind: []const u8, msg: []const u8) void {
    std.debug.print(
        "\n=== {s} ===\n  seed={d} file={s} op={s} iter={d} prefix={d} len={d}\n  msg={s}\n",
        .{ kind, g_cur_seed, g_cur_file, g_cur_op, g_cur_iter, g_cur_prefix, g_cur_input.len, msg },
    );
    if (g_cur_input.len == 0) return;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/crash-seed{d}-iter{d}-{s}.bin",
        .{ g_crash_dir, g_cur_seed, g_cur_iter, g_cur_op },
    ) catch return;
    // The crash dir is created by the ./fuzz runner; we only createFile here
    // (0.16 std.Io.Dir has no makePath). Heap may be corrupt during a panic —
    // this path allocates nothing.
    const io = core.runtime.io();
    const f = core.runtime.createFile(path, .{}) catch return;
    defer f.close(io);
    core.runtime.writeAllAt(f, 0, g_cur_input) catch {};
    std.debug.print("  reproducer written: {s}\n", .{path});
}

/// Current monotonic-ish wall time in ms (0.16 removed std.time.milliTimestamp;
/// route through the runtime's nanoTimestamp). Used only by the watchdog —
/// never for input generation, so determinism is preserved.
fn nowMs() i64 {
    return @intCast(@divTrunc(core.runtime.nanoTimestamp(), std.time.ns_per_ms));
}

// ── Watchdog: a per-input hang is a found bug (the /Prev infinite-loop class) ─
fn watchdog() void {
    while (true) {
        core.runtime.sleep(100 * std.time.ns_per_ms);
        const deadline = g_deadline_ms.load(.acquire);
        if (deadline != 0 and nowMs() > deadline) {
            dumpCrash("HANG", "input exceeded per-input timeout");
            std.process.exit(99);
        }
    }
}

const Config = struct {
    seed: u64 = 0x5EED_F0FE,
    iters: usize = 256, // mutations per seed file
    timeout_ms: i64 = 10_000, // per-input hang threshold
    max_bytes: usize = 16 * 1024 * 1024,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

pub fn main(init: std.process.Init) !void {
    // init.gpa is a leak-checking general-purpose allocator (DebugAllocator in
    // Debug); the runtime reports leaks on exit. We route validator allocations
    // through it so leaks/UAF surface.
    const alloc = init.gpa;

    var cfg = Config{};
    defer cfg.files.deinit(alloc);

    // 0.16: args come from std.process.Init, not the removed argsAlloc. On
    // POSIX the iterator's slices point into argv (stable for process life), so
    // storing them in cfg.files is safe.
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.skip(); // arg0

    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = try std.fmt.parseInt(u64, arg_it.next() orelse return error.MissingValue, 0);
        } else if (std.mem.eql(u8, a, "--iters")) {
            cfg.iters = try std.fmt.parseInt(usize, arg_it.next() orelse return error.MissingValue, 0);
        } else if (std.mem.eql(u8, a, "--timeout-ms")) {
            cfg.timeout_ms = try std.fmt.parseInt(i64, arg_it.next() orelse return error.MissingValue, 0);
        } else if (std.mem.eql(u8, a, "--max-bytes")) {
            cfg.max_bytes = try std.fmt.parseInt(usize, arg_it.next() orelse return error.MissingValue, 0);
        } else if (std.mem.eql(u8, a, "--crash-dir")) {
            g_crash_dir = arg_it.next() orelse return error.MissingValue;
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("unknown flag: {s}\n", .{a});
            std.process.exit(2);
        } else {
            try cfg.files.append(alloc, a);
        }
    }

    if (cfg.files.items.len == 0) {
        std.debug.print(
            "usage: fuzz-sweep [--seed N] [--iters N] [--timeout-ms N] [--max-bytes N] [--crash-dir D] FILE...\n",
            .{},
        );
        std.process.exit(2);
    }

    g_cur_seed = cfg.seed;
    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rng = prng.random();

    // Capture hardware faults (segv/bus/etc) so their reproducers are saved.
    installCrashHandlers();

    // Start the hang watchdog (only reads atomics + aborts; never touches Io).
    const wd = try std.Thread.spawn(.{}, watchdog, .{});
    wd.detach();

    var total_runs: usize = 0;
    // Donor buffer for splice — the previously-loaded seed's bytes.
    var donor: []const u8 = &.{};
    var donor_owned: ?[]u8 = null;
    defer if (donor_owned) |d| alloc.free(d);

    for (cfg.files.items) |path| {
        const bytes = readFile(alloc, path, cfg.max_bytes) catch |err| {
            std.debug.print("skip {s}: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer alloc.free(bytes);
        g_cur_file = path;

        // DETECTION oracle (targeted, sound) before the robustness sweep.
        runDetectionProbe(alloc, bytes);

        // ROBUSTNESS sweep.
        var iter: usize = 0;
        while (iter < cfg.iters) : (iter += 1) {
            const op = mutate.Operator.all[rng.uintLessThan(usize, mutate.Operator.all.len)];
            // 1-in-5: fuzz the header/magic too (prefix 0); else preserve a
            // small magic prefix so the mutation reaches the body. Re-detect in
            // dispatch handles any format change (re-bucket).
            const prefix: usize = if (rng.uintLessThan(u8, 5) == 0)
                0
            else
                @min(bytes.len, 1 + rng.uintLessThan(usize, 16));

            const mutated = mutate.mutate(alloc, op, bytes, prefix, rng, donor) catch continue;
            defer alloc.free(mutated);

            // Arm crash attribution + watchdog, run, disarm.
            g_cur_op = @tagName(op);
            g_cur_iter = iter;
            g_cur_prefix = prefix;
            g_cur_input = mutated;
            g_deadline_ms.store(nowMs() + cfg.timeout_ms, .release);

            dispatch.runOne(alloc, mutated);

            g_deadline_ms.store(0, .release);
            g_cur_input = &.{};
            total_runs += 1;
        }

        // This seed becomes the splice donor for the next file.
        if (donor_owned) |d| alloc.free(d);
        donor_owned = alloc.dupe(u8, bytes) catch null;
        donor = donor_owned orelse &.{};
    }

    std.debug.print(
        "fuzz-sweep: {d} files, {d} robustness runs, {d} detection probes passed, seed={d} — no crash/hang.\n",
        .{ cfg.files.items.len, total_runs, g_detection_passes, cfg.seed },
    );
    if (g_detection_failures > 0) {
        std.debug.print("fuzz-sweep: {d} DETECTION failure(s) — integrity corruption went undetected.\n", .{g_detection_failures});
        std.process.exit(1);
    }
}

/// Slurp a file into an owned buffer, capped at `max`. 0.16: stat for the size,
/// then a single positional read (no streaming reader needed for a real file).
fn readFile(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const io = core.runtime.io();
    const st = try core.runtime.statFile(path);
    const want: usize = @intCast(@min(st.size, max));
    const f = try core.runtime.openFile(path, .{});
    defer f.close(io);
    const buf = try alloc.alloc(u8, want);
    errdefer alloc.free(buf);
    var off: u64 = 0;
    var filled: usize = 0;
    while (filled < want) {
        const n = try f.readPositionalAll(io, buf[filled..], off);
        if (n == 0) break;
        filled += n;
        off += n;
    }
    return buf[0..filled];
}

// ── DETECTION oracle ────────────────────────────────────────────────────────

/// The byte offset of the start of a format's integrity-covered region, given
/// the file length. Returns null when the format has no known cheap region
/// (robustness-only) or the file is too short to contain one. External oracle:
/// these are real integrity primitives (e.g. gzip's CRC-32 trailer) whose
/// definition is independent of validate's author.
fn integrityRegionStart(format: fv.FileFormat, len: usize) ?usize {
    return switch (format) {
        // gzip: ...[deflate][CRC-32 (4)][ISIZE (4)]. Corrupting the CRC-32 of a
        // valid stream MUST fail decode verification. Need ≥ 10-byte header +
        // 8-byte trailer.
        .gzip => if (len >= 18) len - 8 else null,
        else => null,
    };
}

/// Targeted, sound detection probe: if `bytes` is a clean full-depth sample of
/// a format with a known integrity region, flip one bit inside that region and
/// assert the verdict becomes INVALID. Skips (no-op) otherwise.
fn runDetectionProbe(alloc: std.mem.Allocator, bytes: []const u8) void {
    const fmt = fv.detectFormat(bytes);
    if (fmt.maxAchievableDepth() != .full) return;
    const start = integrityRegionStart(fmt, bytes.len) orelse return;

    // Require a CLEAN baseline: the unmutated sample must validate as valid at
    // full depth and detect as this exact format. Otherwise it's not a sound
    // detection subject — skip rather than false-positive.
    const base = dispatch.runOneVerdict(alloc, bytes);
    if (!(base.is_valid and base.depth == .full and base.format == fmt)) return;

    const corrupt = alloc.dupe(u8, bytes) catch return;
    defer alloc.free(corrupt);
    corrupt[start] ^= 0x01; // deterministic single-bit flip in the integrity region

    // A 1-bit flip in the trailer must not change the detected format; if it
    // somehow re-buckets, that's a detection no-op (follow the format).
    if (fv.detectFormat(corrupt) != fmt) return;

    const after = dispatch.runOneVerdict(alloc, corrupt);
    if (after.is_valid) {
        g_detection_failures += 1;
        std.debug.print(
            "=== DETECTION MISS ===\n  file={s} format={s}: integrity-region corruption at offset {d} still validated VALID\n",
            .{ g_cur_file, @tagName(fmt), start },
        );
    } else {
        // Make the Control non-vacuous + visible: a passed probe is logged so a
        // silently-skipped (vacuous) oracle is distinguishable from a real one.
        g_detection_passes += 1;
        std.debug.print(
            "detection probe OK: {s} ({s}) — integrity-region flip @offset {d} → INVALID\n",
            .{ g_cur_file, @tagName(fmt), start },
        );
    }
}
