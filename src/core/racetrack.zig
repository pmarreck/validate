//! "Fair racetrack" allocator — fixed-buffer bump allocator with a
//! sliding-window invariant.
//!
//! ## Design
//!
//! A single buffer of size `total_size`. Allocations are bump-pointer:
//! each `acquire(N)` returns the next N bytes. Logical offsets are
//! monotonically-increasing 64-bit counters; the *physical* position
//! into the buffer is `logical % total_size` (wraparound).
//!
//! Two pointers track the active region:
//!   `head_logical`  — oldest still-live allocation's start offset
//!   `next_logical`  — next allocation's start offset
//!
//! Window invariant: `next_logical - head_logical <= window_size`.
//! When a new allocation would violate this, the caller blocks on a
//! condvar until enough live allocations release that the head advances.
//! Typically `window_size = total_size / 2` so wraparound never overlaps
//! a live block.
//!
//! Releases mark a block as freed in a FIFO of live entries. The head
//! advances *only* when the oldest entry is freed (and then walks
//! forward over any contiguous already-freed entries). This is how the
//! "fair race" is enforced: if the slowest thread holds the head
//! position, *everyone* eventually waits behind it.
//!
//! ## Convoy hazard (acknowledged by design)
//!
//! Heterogeneous-lifetime workloads can hit a convoy: one slow task at
//! the head blocks every fast task whose allocation lands inside the
//! same window. This is the design's worst-case shape. The load test
//! at the bottom of this file measures it directly so we can decide
//! whether the racetrack belongs in our outer scheduler (it doesn't,
//! per measurements below) or only in codec-internal contexts where
//! lifetimes are uniform.
//!
//! ## When to use this
//!
//! GOOD fit: uniform-lifetime, uniform-size workloads (codec decode
//! rings, parsing pipelines with bounded per-step cost). Bump
//! allocation is O(1), zero fragmentation, dense locality.
//!
//! BAD fit: heterogeneous-lifetime workloads (file validation across
//! mixed file sizes — convoy effect collapses throughput).

const std = @import("std");
const runtime = @import("runtime.zig");

pub const Racetrack = struct {
	allocator: std.mem.Allocator,
	buffer: []u8,
	total_size: usize,
	window_size: usize,

	mutex: std.Io.Mutex = .init,
	cond: std.Io.Condition = .init,

	next_logical: u64 = 0,
	head_logical: u64 = 0,

	// FIFO of live entries; oldest at front. Compacted when head advances.
	// Variable-size; never expected to grow beyond `window_size /
	// min_alloc_size`. Backed by ArrayListUnmanaged.
	live: std.ArrayListUnmanaged(LiveBlock) = .empty,

	// Diagnostics — sampled by load test, otherwise harmless overhead.
	stats: Stats = .{},

	pub const LiveBlock = struct {
		offset: u64,
		size: usize,
		freed: bool,
	};

	pub const Stats = struct {
		acquire_count: u64 = 0,
		release_count: u64 = 0,
		blocked_acquire_count: u64 = 0,
		total_blocked_ns: u64 = 0,
		max_blocked_ns: u64 = 0,
	};

	pub const Token = struct {
		offset: u64,
		size: usize,
	};

	pub fn init(allocator: std.mem.Allocator, total_size: usize, window_size: usize) !Racetrack {
		std.debug.assert(window_size > 0);
		std.debug.assert(window_size <= total_size);
		const buf = try allocator.alloc(u8, total_size);
		return .{
			.allocator = allocator,
			.buffer = buf,
			.total_size = total_size,
			.window_size = window_size,
		};
	}

	pub fn deinit(self: *Racetrack) void {
		self.live.deinit(self.allocator);
		self.allocator.free(self.buffer);
		self.* = undefined;
	}

	/// Reserve `size` bytes. Blocks until the window admits the allocation.
	/// Returns a Token that the caller passes to release() and a slice
	/// view of the reserved bytes.
	pub fn acquire(self: *Racetrack, size: usize) !struct { token: Token, bytes: []u8 } {
		std.debug.assert(size > 0);
		std.debug.assert(size <= self.window_size);

		self.mutex.lockUncancelable(runtime.io());
		defer self.mutex.unlock(runtime.io());

		const start = runtime.nanoTimestamp();
		var blocked = false;

		// Per-iteration logic:
		// 1. If allocation would straddle the buffer wrap, skip trailing bytes.
		// 2. Window invariant: `next - head + need <= window_size`.
		// Loop because cond.wait may spuriously return or the head may
		// not have advanced enough yet on first wake.
		// NOTE: no writer-priority — naive priority causes its own
		// deadlock when small waiters yield to a "phantom" large waiter
		// that already proceeded. The convoy hazard is real but bounded
		// when window_size > N * max_alloc_size for typical N.
		while (true) {
			const phys = self.next_logical % self.total_size;
			const skip: usize = if (phys + size > self.total_size) self.total_size - phys else 0;
			const need = skip + size;
			if ((self.next_logical - self.head_logical) + need <= self.window_size) {
				if (skip > 0) self.next_logical += skip;
				break;
			}
			if (!blocked) {
				blocked = true;
				// Counted when the wait BEGINS (still under the mutex) so an
				// observer can synchronize on "a waiter exists" instead of
				// guessing at scheduling; the elapsed-time stats still land
				// after the wait completes.
				self.stats.blocked_acquire_count += 1;
			}
			self.cond.waitUncancelable(runtime.io(), &self.mutex);
		}

		if (blocked) {
			const elapsed: u64 = @intCast(runtime.nanoTimestamp() - start);
			self.stats.total_blocked_ns += elapsed;
			if (elapsed > self.stats.max_blocked_ns) self.stats.max_blocked_ns = elapsed;
		}

		const offset = self.next_logical;
		self.next_logical += size;
		self.stats.acquire_count += 1;

		try self.live.append(self.allocator, .{
			.offset = offset,
			.size = size,
			.freed = false,
		});

		const phys = offset % self.total_size;
		const slice = self.buffer[phys .. phys + size];
		return .{
			.token = .{ .offset = offset, .size = size },
			.bytes = slice,
		};
	}

	/// Try to acquire without blocking. Returns null if window full.
	pub fn tryAcquire(self: *Racetrack, size: usize) !?struct { token: Token, bytes: []u8 } {
		self.mutex.lockUncancelable(runtime.io());
		defer self.mutex.unlock(runtime.io());
		if ((self.next_logical - self.head_logical) + size > self.window_size) return null;

		const offset = self.next_logical;
		self.next_logical += size;
		self.stats.acquire_count += 1;

		try self.live.append(self.allocator, .{
			.offset = offset,
			.size = size,
			.freed = false,
		});

		const phys = offset % self.total_size;
		return .{
			.token = .{ .offset = offset, .size = size },
			.bytes = self.buffer[phys .. phys + size],
		};
	}

	/// Mark `token`'s allocation as released. The head advances past any
	/// contiguous freed blocks, waking waiters.
	pub fn release(self: *Racetrack, token: Token) void {
		self.mutex.lockUncancelable(runtime.io());
		defer self.mutex.unlock(runtime.io());

		// Find the entry. Linear scan; live list is bounded by
		// window_size/min_size which is small in practice.
		for (self.live.items) |*entry| {
			if (entry.offset == token.offset) {
				entry.freed = true;
				break;
			}
		}

		// Walk freed entries from the front, advancing head_logical.
		var advanced: usize = 0;
		while (advanced < self.live.items.len and self.live.items[advanced].freed) : (advanced += 1) {
			const e = self.live.items[advanced];
			self.head_logical = e.offset + e.size;
		}
		if (advanced > 0) {
			// Drop the freed prefix.
			std.mem.copyForwards(LiveBlock, self.live.items[0 .. self.live.items.len - advanced], self.live.items[advanced..]);
			self.live.shrinkRetainingCapacity(self.live.items.len - advanced);
			self.cond.broadcast(runtime.io());
		}

		self.stats.release_count += 1;
	}

	pub fn snapshot(self: *Racetrack) Stats {
		self.mutex.lockUncancelable(runtime.io());
		defer self.mutex.unlock(runtime.io());
		return self.stats;
	}
};

// ===== Tests =====

test "Racetrack acquire returns non-overlapping bytes within window" {
	var rt = try Racetrack.init(std.testing.allocator, 1024, 512);
	defer rt.deinit();

	const a = try rt.acquire(100);
	const b = try rt.acquire(100);
	try std.testing.expect(@intFromPtr(a.bytes.ptr) != @intFromPtr(b.bytes.ptr));
	try std.testing.expectEqual(@as(usize, 100), a.bytes.len);
	try std.testing.expectEqual(@as(usize, 100), b.bytes.len);

	rt.release(a.token);
	rt.release(b.token);
}

test "Racetrack tryAcquire returns null when window full" {
	var rt = try Racetrack.init(std.testing.allocator, 1024, 512);
	defer rt.deinit();

	const a = (try rt.tryAcquire(400)).?;
	const b = (try rt.tryAcquire(100)).?;
	const c = try rt.tryAcquire(100); // 500/512 used, 100 more would overflow
	try std.testing.expect(c == null);

	rt.release(a.token);
	const d = (try rt.tryAcquire(100)).?;
	rt.release(b.token);
	rt.release(d.token);
}

test "Racetrack out-of-order release does not advance head until front frees" {
	var rt = try Racetrack.init(std.testing.allocator, 1024, 512);
	defer rt.deinit();

	const a = try rt.acquire(100);
	const b = try rt.acquire(100);
	const c = try rt.acquire(100);

	// Release b and c first; head should NOT advance because a is still live.
	rt.release(b.token);
	rt.release(c.token);
	{
		rt.mutex.lockUncancelable(runtime.io());
		defer rt.mutex.unlock(runtime.io());
		try std.testing.expectEqual(@as(u64, 0), rt.head_logical);
		try std.testing.expectEqual(@as(u64, 300), rt.next_logical);
	}

	// Releasing a should sweep all three.
	rt.release(a.token);
	{
		rt.mutex.lockUncancelable(runtime.io());
		defer rt.mutex.unlock(runtime.io());
		try std.testing.expectEqual(@as(u64, 300), rt.head_logical);
	}
}

test "Racetrack wraparound: physical offset reuses buffer after head advances" {
	var rt = try Racetrack.init(std.testing.allocator, 1024, 512);
	defer rt.deinit();

	// Fill up the window once, release, then fill again.
	const a = try rt.acquire(500);
	const a_ptr = @intFromPtr(a.bytes.ptr);
	rt.release(a.token);

	// Now next_logical=500, head_logical=500. Allocate again — should
	// wrap to physical offset 500.
	const b = try rt.acquire(500);
	const b_ptr = @intFromPtr(b.bytes.ptr);
	try std.testing.expect(a_ptr != b_ptr); // Different physical positions

	rt.release(b.token);

	// Eventually next_logical will wrap past total_size; verify we keep
	// going correctly.
	var i: usize = 0;
	while (i < 10) : (i += 1) {
		const t = try rt.acquire(256);
		rt.release(t.token);
	}
}

test "Racetrack acquire blocks then unblocks on head advance" {
	var rt = try Racetrack.init(std.testing.allocator, 1024, 512);
	defer rt.deinit();

	const a = try rt.acquire(500); // 500/512 used

	const Worker = struct {
		fn run(racetrack: *Racetrack, latch: *std.atomic.Value(u32)) void {
			const r = racetrack.acquire(100) catch return;
			latch.store(1, .seq_cst);
			racetrack.release(r.token);
		}
	};

	var latch = std.atomic.Value(u32).init(0);
	var t = try std.Thread.spawn(.{}, Worker.run, .{ &rt, &latch });

	// Deterministic: acquire(100) MUST block (500 + 100 > 512 window), and
	// the blocked count becomes visible the moment the worker parks. Wait on
	// that event; a spin budget racing thread scheduling is a flake.
	while (rt.snapshot().blocked_acquire_count == 0) std.Thread.yield() catch {};
	try std.testing.expectEqual(@as(u32, 0), latch.load(.seq_cst));

	rt.release(a.token);
	t.join();
	try std.testing.expectEqual(@as(u32, 1), latch.load(.seq_cst));

	const stats = rt.snapshot();
	try std.testing.expect(stats.blocked_acquire_count >= 1);
}

// ===== Load test =====
//
// Compares Racetrack vs std.heap.ArenaAllocator under heterogeneous-lifetime
// workload — 95% small/fast operations + 5% large/slow operations — to
// quantify the convoy hazard.
//
// Run via: nix build .#checks.<system>.test (already covered by ./test).
// Output is captured by the test harness; check stderr for the report.

const LoadTestParams = struct {
	num_workers: usize = 8,
	total_ops: usize = 10_000,
	rng_seed: u64 = 0xC0FFEE,
	// Window sized to be CONTENDED but not pathological: 32 MB total /
	// 16 MB window means 4-16 large tasks (1-4 MB) fit simultaneously.
	// Mixed with small tasks under 10% large fraction, this exercises
	// convoy without single-task starvation.
	racetrack_total: usize = 32 * 1024 * 1024,
	racetrack_window: usize = 16 * 1024 * 1024,
	small_size_min: usize = 1024,
	small_size_max: usize = 8 * 1024,
	large_size_min: usize = 1 * 1024 * 1024,
	large_size_max: usize = 4 * 1024 * 1024,
	large_fraction: f32 = 0.10,
	small_hold_us_mean: f32 = 100.0,
	small_hold_us_stddev: f32 = 30.0,
	large_hold_us_mean: f32 = 5000.0,
	large_hold_us_stddev: f32 = 1500.0,
};

const LoadTestResult = struct {
	wall_ns: u64 = 0,
	throughput_ops_per_sec: f64 = 0,
	racetrack_stats: ?Racetrack.Stats = null,
};

fn busyWaitNs(ns: u64) void {
	const start = runtime.nanoTimestamp();
	while (runtime.nanoTimestamp() - start < ns) {
		// busy-wait keeps thread on-CPU (more deterministic than sleep)
		// for short durations characteristic of decode loops.
		std.atomic.spinLoopHint();
	}
}

fn workerRacetrack(rt: *Racetrack, prng: *std.Random.DefaultPrng, ops_count: *std.atomic.Value(usize), params: LoadTestParams) void {
	const random = prng.random();
	while (true) {
		const my_op = ops_count.fetchAdd(1, .seq_cst);
		if (my_op >= params.total_ops) break;

		const is_large = random.float(f32) < params.large_fraction;
		const size: usize = if (is_large)
			random.intRangeAtMost(usize, params.large_size_min, params.large_size_max)
		else
			random.intRangeAtMost(usize, params.small_size_min, params.small_size_max);

		const hold_us_f = if (is_large)
			random.floatNorm(f32) * params.large_hold_us_stddev + params.large_hold_us_mean
		else
			random.floatNorm(f32) * params.small_hold_us_stddev + params.small_hold_us_mean;
		const hold_ns: u64 = @intFromFloat(@max(0, hold_us_f) * 1000);

		const t = rt.acquire(size) catch continue;
		busyWaitNs(hold_ns);
		rt.release(t.token);
	}
}

fn workerArena(parent_allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng, ops_count: *std.atomic.Value(usize), params: LoadTestParams) void {
	const random = prng.random();
	while (true) {
		const my_op = ops_count.fetchAdd(1, .seq_cst);
		if (my_op >= params.total_ops) break;

		const is_large = random.float(f32) < params.large_fraction;
		const size: usize = if (is_large)
			random.intRangeAtMost(usize, params.large_size_min, params.large_size_max)
		else
			random.intRangeAtMost(usize, params.small_size_min, params.small_size_max);

		const hold_us_f = if (is_large)
			random.floatNorm(f32) * params.large_hold_us_stddev + params.large_hold_us_mean
		else
			random.floatNorm(f32) * params.small_hold_us_stddev + params.small_hold_us_mean;
		const hold_ns: u64 = @intFromFloat(@max(0, hold_us_f) * 1000);

		var arena = std.heap.ArenaAllocator.init(parent_allocator);
		defer arena.deinit();
		const a = arena.allocator();
		const buf = a.alloc(u8, size) catch continue;
		busyWaitNs(hold_ns);
		std.mem.doNotOptimizeAway(buf);
	}
}

fn runRacetrackLoad(parent_allocator: std.mem.Allocator, params: LoadTestParams) !LoadTestResult {
	var rt = try Racetrack.init(parent_allocator, params.racetrack_total, params.racetrack_window);
	defer rt.deinit();

	var ops_count = std.atomic.Value(usize).init(0);

	// Seed each worker's PRNG deterministically from the master seed.
	const prngs = try parent_allocator.alloc(std.Random.DefaultPrng, params.num_workers);
	defer parent_allocator.free(prngs);
	for (prngs, 0..) |*p, i| p.* = std.Random.DefaultPrng.init(params.rng_seed +% i);

	const threads = try parent_allocator.alloc(std.Thread, params.num_workers);
	defer parent_allocator.free(threads);

	const start = runtime.nanoTimestamp();
	for (threads, 0..) |*t, i| {
		t.* = try std.Thread.spawn(.{}, workerRacetrack, .{ &rt, &prngs[i], &ops_count, params });
	}
	for (threads) |t| t.join();
	const elapsed: u64 = @intCast(runtime.nanoTimestamp() - start);

	return .{
		.wall_ns = elapsed,
		.throughput_ops_per_sec = @as(f64, @floatFromInt(params.total_ops)) / (@as(f64, @floatFromInt(elapsed)) / 1e9),
		.racetrack_stats = rt.snapshot(),
	};
}

fn runArenaLoad(parent_allocator: std.mem.Allocator, params: LoadTestParams) !LoadTestResult {
	var ops_count = std.atomic.Value(usize).init(0);

	const prngs = try parent_allocator.alloc(std.Random.DefaultPrng, params.num_workers);
	defer parent_allocator.free(prngs);
	for (prngs, 0..) |*p, i| p.* = std.Random.DefaultPrng.init(params.rng_seed +% i);

	const threads = try parent_allocator.alloc(std.Thread, params.num_workers);
	defer parent_allocator.free(threads);

	const start = runtime.nanoTimestamp();
	for (threads, 0..) |*t, i| {
		t.* = try std.Thread.spawn(.{}, workerArena, .{ parent_allocator, &prngs[i], &ops_count, params });
	}
	for (threads) |t| t.join();
	const elapsed: u64 = @intCast(runtime.nanoTimestamp() - start);

	return .{
		.wall_ns = elapsed,
		.throughput_ops_per_sec = @as(f64, @floatFromInt(params.total_ops)) / (@as(f64, @floatFromInt(elapsed)) / 1e9),
	};
}

test "Racetrack load test: heterogeneous workload (convoy hazard)" {
	if (@import("builtin").is_test and runtime.hasEnvVar("VALIDATE_SKIP_RACETRACK_LOADTEST")) return error.SkipZigTest;

	// Reduce ops in test mode so the suite stays fast.
	// Set VALIDATE_RACETRACK_FULL=1 for the full 10K-op run.
	const params: LoadTestParams = if (runtime.hasEnvVar("VALIDATE_RACETRACK_FULL"))
		.{}
	else
		.{ .total_ops = 1000 };

	const a = std.testing.allocator;

	const rt_result = try runRacetrackLoad(a, params);
	const arena_result = try runArenaLoad(a, params);

	std.debug.print(
		\\
		\\=== Racetrack vs Arena load test (heterogeneous) ===
		\\  Workload: {d} ops, {d} workers, large_frac={d:.0}%
		\\  Sizes: small {d}-{d}B, large {d}-{d}B
		\\  Hold: small µ={d:.0}±{d:.0}µs, large µ={d:.0}±{d:.0}µs
		\\
		\\  Racetrack:
		\\    wall:        {d:.2}ms
		\\    throughput:  {d:.0} ops/sec
		\\    blocked:     {d}/{d} ({d:.1}%)
		\\    total stall: {d:.2}ms
		\\    max stall:   {d:.2}ms
		\\
		\\  Arena (per-task):
		\\    wall:        {d:.2}ms
		\\    throughput:  {d:.0} ops/sec
		\\
		\\  Verdict: arena {d:.2}x {s} racetrack on this workload
		\\
	, .{
		params.total_ops,                                                             params.num_workers, params.large_fraction * 100,
		params.small_size_min,                                                        params.small_size_max, params.large_size_min, params.large_size_max,
		params.small_hold_us_mean,                                                    params.small_hold_us_stddev, params.large_hold_us_mean, params.large_hold_us_stddev,
		@as(f64, @floatFromInt(rt_result.wall_ns)) / 1e6,
		rt_result.throughput_ops_per_sec,
		rt_result.racetrack_stats.?.blocked_acquire_count,                            rt_result.racetrack_stats.?.acquire_count,
		(@as(f64, @floatFromInt(rt_result.racetrack_stats.?.blocked_acquire_count)) / @as(f64, @floatFromInt(rt_result.racetrack_stats.?.acquire_count))) * 100.0,
		@as(f64, @floatFromInt(rt_result.racetrack_stats.?.total_blocked_ns)) / 1e6,
		@as(f64, @floatFromInt(rt_result.racetrack_stats.?.max_blocked_ns)) / 1e6,
		@as(f64, @floatFromInt(arena_result.wall_ns)) / 1e6,
		arena_result.throughput_ops_per_sec,
		arena_result.throughput_ops_per_sec / rt_result.throughput_ops_per_sec,
		if (arena_result.throughput_ops_per_sec > rt_result.throughput_ops_per_sec) "BEATS" else "loses-to",
	});
}

test "Racetrack load test: uniform workload (best case for racetrack)" {
	if (runtime.hasEnvVar("VALIDATE_SKIP_RACETRACK_LOADTEST")) return error.SkipZigTest;

	const params: LoadTestParams = if (runtime.hasEnvVar("VALIDATE_RACETRACK_FULL")) .{
		.large_fraction = 0.0, // no slow tasks
		.small_size_min = 4096,
		.small_size_max = 16 * 1024,
		.small_hold_us_mean = 50.0,
		.small_hold_us_stddev = 10.0,
	} else .{
		.total_ops = 1000,
		.large_fraction = 0.0,
		.small_size_min = 4096,
		.small_size_max = 16 * 1024,
		.small_hold_us_mean = 50.0,
		.small_hold_us_stddev = 10.0,
	};

	const a = std.testing.allocator;
	const rt_result = try runRacetrackLoad(a, params);
	const arena_result = try runArenaLoad(a, params);

	std.debug.print(
		\\
		\\=== Racetrack vs Arena load test (uniform — best case) ===
		\\  Workload: {d} ops, {d} workers, all small
		\\  Sizes: {d}-{d}B,  Hold: µ={d:.0}±{d:.0}µs
		\\
		\\  Racetrack: {d:.2}ms / {d:.0} ops/sec / blocked {d}/{d}
		\\  Arena:     {d:.2}ms / {d:.0} ops/sec
		\\  Verdict:   arena {d:.2}x {s} racetrack
		\\
	, .{
		params.total_ops,                                                                              params.num_workers,
		params.small_size_min,                                                                         params.small_size_max,
		params.small_hold_us_mean,                                                                     params.small_hold_us_stddev,
		@as(f64, @floatFromInt(rt_result.wall_ns)) / 1e6,                                              rt_result.throughput_ops_per_sec,
		rt_result.racetrack_stats.?.blocked_acquire_count,                                             rt_result.racetrack_stats.?.acquire_count,
		@as(f64, @floatFromInt(arena_result.wall_ns)) / 1e6,                                           arena_result.throughput_ops_per_sec,
		arena_result.throughput_ops_per_sec / rt_result.throughput_ops_per_sec,
		if (arena_result.throughput_ops_per_sec > rt_result.throughput_ops_per_sec) "BEATS" else "loses-to",
	});
}
