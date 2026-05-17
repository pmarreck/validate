//! Memory-budget gate for the worker thread pool's task queue.
//!
//! Workers call `acquire(bytes)` before starting a task and `release(bytes)`
//! after finishing. `acquire` blocks (on a condvar) until enough bytes are
//! available. The starvation-prevention rule: any single task with
//! `bytes > total` is admitted *alone* — it waits for `active_count == 0`
//! then proceeds. This avoids the deadlock where a giant file would wait
//! forever for budget that can never accumulate to its size.
//!
//! Default budget: `clamp(total_ram / 3, 1 GB, 8 GB)`. Override via
//! `--memory-budget=N{K,M,G}` CLI flag or `VALIDATE_MEMORY_BUDGET` env var.
//! These knobs are wired in cli/main.c and ffi/c_api.zig respectively.
//!
//! The estimator is best-effort: stat.size approximates per-task working
//! set but doesn't catch decompression amplification (PDF stream blowup,
//! libavif internal threading). The gate caps *intent*, not *fact*.
//! Pair with arena-per-task to keep actual usage bounded.

const std = @import("std");
const runtime = @import("runtime.zig");

// 0.16: std.Thread.Mutex / Condition removed; sync primitives moved to
// std.Io.Mutex / std.Io.Condition with an `io` parameter on lock/wait.
// Under Io.Threaded these are mutex-equivalent; we treat lock()/wait()
// failure as a panic since validate doesn't use Io cancellation.
inline fn lockOrPanic(m: *std.Io.Mutex) void {
	m.lock(runtime.io()) catch |err| std.debug.panic("Io.Mutex.lock failed: {s}", .{@errorName(err)});
}
inline fn condWaitOrPanic(c: *std.Io.Condition, m: *std.Io.Mutex) void {
	c.wait(runtime.io(), m) catch |err| std.debug.panic("Io.Condition.wait failed: {s}", .{@errorName(err)});
}

pub const MemoryBudget = struct {
	mutex: std.Io.Mutex = .init,
	cond: std.Io.Condition = .init,
	total_bytes: usize,
	available_bytes: usize,
	active_count: usize = 0,

	pub fn init(total_bytes: usize) MemoryBudget {
		runtime.ensureInit();
		return .{
			.total_bytes = total_bytes,
			.available_bytes = total_bytes,
		};
	}

	/// Block until `bytes` can be reserved against the budget. Tasks larger
	/// than the total budget are admitted alone (when active_count == 0).
	pub fn acquire(self: *MemoryBudget, bytes: usize) void {
		lockOrPanic(&self.mutex);
		defer self.mutex.unlock(runtime.io());

		if (bytes > self.total_bytes) {
			while (self.active_count > 0) condWaitOrPanic(&self.cond, &self.mutex);
			self.active_count += 1;
			self.available_bytes = 0; // oversized task drains the budget so no peer admits
			return;
		}

		while (self.available_bytes < bytes) {
			condWaitOrPanic(&self.cond, &self.mutex);
		}
		self.available_bytes -= bytes;
		self.active_count += 1;
	}

	/// Try to acquire without blocking. Returns true if reserved.
	pub fn tryAcquire(self: *MemoryBudget, bytes: usize) bool {
		lockOrPanic(&self.mutex);
		defer self.mutex.unlock(runtime.io());
		if (bytes > self.total_bytes) {
			if (self.active_count > 0) return false;
			self.active_count += 1;
			self.available_bytes = 0; // oversized task drains the budget
			return true;
		}
		if (self.available_bytes < bytes) return false;
		self.available_bytes -= bytes;
		self.active_count += 1;
		return true;
	}

	pub fn release(self: *MemoryBudget, bytes: usize) void {
		lockOrPanic(&self.mutex);
		defer self.mutex.unlock(runtime.io());
		if (bytes > self.total_bytes) {
			// oversized release: restore full budget
			self.available_bytes = self.total_bytes;
		} else {
			self.available_bytes += bytes;
		}
		self.active_count -= 1;
		self.cond.broadcast();
	}

	pub fn snapshot(self: *MemoryBudget) struct { total: usize, available: usize, active: usize } {
		lockOrPanic(&self.mutex);
		defer self.mutex.unlock(runtime.io());
		return .{
			.total = self.total_bytes,
			.available = self.available_bytes,
			.active = self.active_count,
		};
	}
};

/// Parse a human-readable byte size like "1G", "512M", "256K", "1024".
/// Suffixes use binary multipliers (1G = 2^30). Case-insensitive.
pub fn parseSize(s: []const u8) !usize {
	if (s.len == 0) return error.InvalidSize;
	const last = s[s.len - 1];
	const suffix: usize = switch (std.ascii.toLower(last)) {
		'k' => 1 << 10,
		'm' => 1 << 20,
		'g' => 1 << 30,
		else => 0,
	};
	const num_str = if (suffix > 0) s[0 .. s.len - 1] else s;
	const n = std.fmt.parseInt(usize, num_str, 10) catch return error.InvalidSize;
	if (suffix == 0) return n;
	return n * suffix;
}

/// Returns the default budget for a process: clamp(total_ram / 3, 1 GB, 8 GB).
/// Floor protects very-low-RAM systems from getting an unusably small cap;
/// ceiling prevents pathological waste on memory-rich machines (a CLI tool
/// shouldn't quietly eat 32+ GB just because the machine has it).
pub fn defaultBudget(total_ram_bytes: usize) usize {
	const one_gb: usize = 1 << 30;
	const eight_gb: usize = 8 * one_gb;
	const computed = total_ram_bytes / 3;
	if (computed < one_gb) return one_gb;
	if (computed > eight_gb) return eight_gb;
	return computed;
}

/// Read total physical RAM. Returns 0 on platforms where we can't
/// determine it; caller should fall back to a reasonable default.
pub fn detectTotalRam() usize {
	if (@import("builtin").os.tag == .macos or @import("builtin").os.tag == .ios) {
		var size: u64 = 0;
		var len: usize = @sizeOf(u64);
		const mib = [_]c_int{ 6, 24 }; // CTL_HW=6, HW_MEMSIZE=24
		const rc = std.c.sysctl(@ptrCast(@constCast(&mib)), mib.len, &size, &len, null, 0);
		if (rc == 0 and size > 0) return @intCast(size);
		return 0;
	}
	if (@import("builtin").os.tag == .linux) {
		const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return 0;
		defer file.close();
		var buf: [4096]u8 = undefined;
		const n = file.readAll(&buf) catch return 0;
		const data = buf[0..n];
		// Parse "MemTotal:    16384000 kB"
		var it = std.mem.splitScalar(u8, data, '\n');
		while (it.next()) |line| {
			if (std.mem.startsWith(u8, line, "MemTotal:")) {
				var pieces = std.mem.tokenizeAny(u8, line[9..], " \t");
				const num_str = pieces.next() orelse return 0;
				const kb = std.fmt.parseInt(usize, num_str, 10) catch return 0;
				return kb * 1024;
			}
		}
		return 0;
	}
	return 0; // Windows / unknown
}

// ===== Tests =====

test "MemoryBudget acquire and release within budget" {
	var b = MemoryBudget.init(1024);
	b.acquire(256);
	const s1 = b.snapshot();
	try std.testing.expectEqual(@as(usize, 768), s1.available);
	try std.testing.expectEqual(@as(usize, 1), s1.active);
	b.release(256);
	const s2 = b.snapshot();
	try std.testing.expectEqual(@as(usize, 1024), s2.available);
	try std.testing.expectEqual(@as(usize, 0), s2.active);
}

test "MemoryBudget tryAcquire fails when insufficient" {
	var b = MemoryBudget.init(1024);
	try std.testing.expect(b.tryAcquire(800));
	try std.testing.expect(!b.tryAcquire(300)); // would exceed
	try std.testing.expect(b.tryAcquire(200)); // fits
	b.release(800);
	b.release(200);
}

test "MemoryBudget oversized task admitted alone" {
	var b = MemoryBudget.init(1024);
	// Oversized task: 2048 > 1024 total
	try std.testing.expect(b.tryAcquire(2048));
	const s1 = b.snapshot();
	try std.testing.expectEqual(@as(usize, 1), s1.active);
	// While oversized task active, no others admit
	try std.testing.expect(!b.tryAcquire(512));
	b.release(2048);
	const s2 = b.snapshot();
	try std.testing.expectEqual(@as(usize, 0), s2.active);
	try std.testing.expectEqual(@as(usize, 1024), s2.available);
}

test "MemoryBudget acquire blocks then unblocks on release" {
	const test_alloc = std.testing.allocator;
	_ = test_alloc;

	var b = MemoryBudget.init(1024);
	b.acquire(800);
	try std.testing.expectEqual(@as(usize, 224), b.snapshot().available);

	const Worker = struct {
		fn run(budget: *MemoryBudget, latch: *std.atomic.Value(u32)) void {
			budget.acquire(500); // must wait until released
			latch.store(1, .seq_cst);
		}
	};

	var latch = std.atomic.Value(u32).init(0);
	var t = try std.Thread.spawn(.{}, Worker.run, .{ &b, &latch });

	// Spin briefly to confirm latch hasn't fired (worker is still blocked).
	// Bounded loop, no time-based assertions.
	var spins: usize = 0;
	while (spins < 1_000_000 and latch.load(.seq_cst) == 0) : (spins += 1) {}
	try std.testing.expectEqual(@as(u32, 0), latch.load(.seq_cst));

	// Release frees enough budget for the waiter to proceed.
	b.release(800);
	t.join();
	try std.testing.expectEqual(@as(u32, 1), latch.load(.seq_cst));
	b.release(500);
}

test "parseSize handles raw bytes and KMG suffixes" {
	try std.testing.expectEqual(@as(usize, 1024), try parseSize("1024"));
	try std.testing.expectEqual(@as(usize, 1 << 10), try parseSize("1K"));
	try std.testing.expectEqual(@as(usize, 1 << 10), try parseSize("1k"));
	try std.testing.expectEqual(@as(usize, 512 << 20), try parseSize("512M"));
	try std.testing.expectEqual(@as(usize, 4 * (@as(usize, 1) << 30)), try parseSize("4G"));
}

test "parseSize rejects garbage" {
	try std.testing.expectError(error.InvalidSize, parseSize(""));
	try std.testing.expectError(error.InvalidSize, parseSize("abc"));
	try std.testing.expectError(error.InvalidSize, parseSize("1X"));
}

test "defaultBudget formula" {
	const one_gb: usize = 1 << 30;
	const eight_gb: usize = 8 * one_gb;
	// Floor at 1 GB on small RAM
	try std.testing.expectEqual(one_gb, defaultBudget(2 * one_gb));
	// Linear within range
	try std.testing.expectEqual(4 * one_gb, defaultBudget(12 * one_gb));
	// Ceiling at 8 GB
	try std.testing.expectEqual(eight_gb, defaultBudget(64 * one_gb));
	try std.testing.expectEqual(eight_gb, defaultBudget(128 * one_gb));
}

test "detectTotalRam returns nonzero on supported platforms" {
	const ram = detectTotalRam();
	if (@import("builtin").os.tag == .macos or @import("builtin").os.tag == .linux) {
		try std.testing.expect(ram > 0);
	}
}
