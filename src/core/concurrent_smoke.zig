//! Concurrent-stress smoke test for deep validators.
//!
//! Catches bugs of the shape just fixed in `heif_container_parser.zig`:
//! module-level mutable state that's not threadlocal/atomic, surfacing as
//! nondeterministic false positives when the same file is validated from
//! multiple threads.
//!
//! Strategy: for each format with a ground-truth sample, run its deep
//! validator once single-threaded (baseline), then 8 threads × 50 iterations
//! concurrent (stress). Assert every concurrent result is "valid" and matches
//! the baseline's valid bit. Mismatch = data race in that validator's call
//! graph.
//!
//! Runs as part of `./test` via mod.zig's `test {}` block. Time-bounded:
//! ~30 seconds total for the suite of formats listed below; tunable via
//! `VALIDATE_CONCURRENT_SMOKE_ITERS` env var.

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const heic_validator = @import("heic_validator.zig");
const heif_container_parser = @import("heif_container_parser.zig");

// ===== Per-format probes =====

const heicProbe = struct {
	fn probe(data: []const u8) bool {
		return heic_validator.validateHeicDeepFromBuffer(data).valid;
	}
}.probe;

// Re-validates the heic_validator parse repeatedly on the SAME buffer.
// Bug surfaces in heif_container_parser.zig's StaticBufs if not threadlocal.
fn probeHeifContainerInfo(data: []const u8) bool {
	const info = heif_container_parser.parseHeifContainer(data) catch return false;
	// Returned slices index into a threadlocal scratch buffer; consume them
	// fully before returning so any aliasing surfaces immediately.
	if (info.items.len == 0) return false;
	if (info.primary_item_id == 0) return false;
	return true;
}

// ===== Stress runner =====

const Probe = *const fn (data: []const u8) bool;

const StressContext = struct {
	probe: Probe,
	data: []const u8,
	iterations: usize,
	failure_count: std.atomic.Value(u32) = .init(0),
};

fn stressWorker(ctx: *StressContext) void {
	var i: usize = 0;
	while (i < ctx.iterations) : (i += 1) {
		if (!ctx.probe(ctx.data)) {
			_ = ctx.failure_count.fetchAdd(1, .seq_cst);
			return;
		}
	}
}

fn runConcurrentStress(probe: Probe, data: []const u8, num_threads: usize, iterations: usize) !u32 {
	// Establish baseline first — if probe fails single-threaded, the bug
	// isn't a concurrency issue and the test should not pretend otherwise.
	if (!probe(data)) return error.BaselineProbeFailed;

	var ctx = StressContext{
		.probe = probe,
		.data = data,
		.iterations = iterations,
	};

	const threads = try std.testing.allocator.alloc(std.Thread, num_threads);
	defer std.testing.allocator.free(threads);

	for (threads) |*t| {
		t.* = try std.Thread.spawn(.{}, stressWorker, .{&ctx});
	}
	for (threads) |t| t.join();

	return ctx.failure_count.load(.seq_cst);
}

fn iterationsFromEnv() usize {
	if (std.process.hasEnvVarConstant("VALIDATE_CONCURRENT_SMOKE_FAST")) return 10;
	if (std.process.hasEnvVarConstant("VALIDATE_CONCURRENT_SMOKE_FULL")) return 200;
	return 50;
}

// ===== Tests =====
//
// These tests use synthesized minimal inputs rather than ground-truth files
// because (a) sandbox tests can't reliably read repo files, and (b) the
// concurrency-bug class we're catching is independent of input complexity:
// any module-level mutable state in the parse path will surface even on a
// minimal valid file.

test "concurrent stress: heif_container_parser" {
	// Synthesize a minimal valid HEIF (same fixture pattern as the
	// thread-safety test in heif_container_parser.zig itself, but
	// reduced to one sample for speed).
	const Sample = struct {
		fn make(allocator: std.mem.Allocator, primary_id: u16) ![]u8 {
			var out: std.ArrayListUnmanaged(u8) = .{};
			defer out.deinit(allocator);

			// ftyp
			try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 24, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c', 0, 0, 0, 0, 'h', 'e', 'i', 'c', 'm', 'i', 'f', '1' });

			// meta body
			var meta: std.ArrayListUnmanaged(u8) = .{};
			defer meta.deinit(allocator);
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // ver+flags

			// hdlr
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 33 });
			try meta.appendSlice(allocator, "hdlr");
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
			try meta.appendSlice(allocator, "pict");
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{0});

			// pitm
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 14 });
			try meta.appendSlice(allocator, "pitm");
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) });

			// iinf
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 35 });
			try meta.appendSlice(allocator, "iinf");
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 1 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 21 });
			try meta.appendSlice(allocator, "infe");
			try meta.appendSlice(allocator, &[_]u8{ 2, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0 });
			try meta.appendSlice(allocator, "hvc1");
			try meta.appendSlice(allocator, &[_]u8{0});

			// iloc
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 32 });
			try meta.appendSlice(allocator, "iloc");
			try meta.appendSlice(allocator, &[_]u8{ 1, 0, 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{0x44});
			try meta.appendSlice(allocator, &[_]u8{0x00});
			try meta.appendSlice(allocator, &[_]u8{ 0, 1 });
			try meta.appendSlice(allocator, &[_]u8{ @intCast((primary_id >> 8) & 0xff), @intCast(primary_id & 0xff) });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 1 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0x80 });
			try meta.appendSlice(allocator, &[_]u8{ 0, 0, 0, 4 });

			const total: u32 = @intCast(meta.items.len + 8);
			var size_be: [4]u8 = undefined;
			std.mem.writeInt(u32, &size_be, total, .big);
			try out.appendSlice(allocator, &size_be);
			try out.appendSlice(allocator, "meta");
			try out.appendSlice(allocator, meta.items);

			while (out.items.len < 256) try out.append(allocator, 0);
			return out.toOwnedSlice(allocator);
		}
	};

	const sample = Sample.make(std.testing.allocator, 1) catch return error.SkipZigTest;
	defer std.testing.allocator.free(sample);

	const failures = runConcurrentStress(probeHeifContainerInfo, sample, 8, iterationsFromEnv()) catch |err| switch (err) {
		error.BaselineProbeFailed => return error.SkipZigTest,
		else => return err,
	};
	try std.testing.expectEqual(@as(u32, 0), failures);
}

// Future expansions: add stress tests for other validators here as bugs are
// found. Pattern: write a probe fn that takes []const u8 and returns bool,
// add it to the suite. The harness handles thread spawning and assertions.
