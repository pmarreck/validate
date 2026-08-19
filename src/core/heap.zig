//! Centralized heap allocator surface for validate's internal scratch
//! allocations. All sites that previously used `std.heap.page_allocator`
//! directly should route through `validateAllocator()` so a future budget
//! tracker / racetrack / arena strategy can be slotted in here without
//! touching every call site.
//!
//! Currently delegates to `std.heap.smp_allocator` (Zig 0.15+), which is
//! lock-free, thread-safe, and significantly faster than page_allocator
//! for the small-and-frequent scratch buffers we use (64 KB EOI search
//! buffers, sample scan windows, etc.).
//!
//! Why a wrapper instead of `std.heap.smp_allocator` directly:
//!   - Single grep target (`heap.validateAllocator()`) makes future
//!     instrumentation trivial: budget tracker, fragmentation logging,
//!     test-time leak detection.
//!   - The tracker / budget queue we're adding next will replace the
//!     body here without churning every validator.
//!   - Discourages new sites from picking arbitrary allocators ad-hoc.

const std = @import("std");

const AtomicU64 = std.atomic.Value(u64);

pub const AllocStats = extern struct {
    current_bytes: u64,
    peak_bytes: u64,
    small_current_bytes: u64,
    small_peak_bytes: u64,
    big_current_bytes: u64,
    big_peak_bytes: u64,
    total_alloc_bytes: u64,
    total_free_bytes: u64,
    arena_reset_bytes: u64,
    alloc_count: u64,
    free_count: u64,
    resize_count: u64,
    remap_count: u64,
    arena_reset_count: u64,
};

const GlobalAllocStats = struct {
    current_bytes: AtomicU64 = AtomicU64.init(0),
    peak_bytes: AtomicU64 = AtomicU64.init(0),
    small_current_bytes: AtomicU64 = AtomicU64.init(0),
    small_peak_bytes: AtomicU64 = AtomicU64.init(0),
    big_current_bytes: AtomicU64 = AtomicU64.init(0),
    big_peak_bytes: AtomicU64 = AtomicU64.init(0),
    total_alloc_bytes: AtomicU64 = AtomicU64.init(0),
    total_free_bytes: AtomicU64 = AtomicU64.init(0),
    arena_reset_bytes: AtomicU64 = AtomicU64.init(0),
    alloc_count: AtomicU64 = AtomicU64.init(0),
    free_count: AtomicU64 = AtomicU64.init(0),
    resize_count: AtomicU64 = AtomicU64.init(0),
    remap_count: AtomicU64 = AtomicU64.init(0),
    arena_reset_count: AtomicU64 = AtomicU64.init(0),
};

var g_alloc_stats: GlobalAllocStats = .{};

fn atomicMax(counter: *AtomicU64, value: u64) void {
    var old = counter.load(.monotonic);
    while (value > old) {
        if (counter.cmpxchgWeak(old, value, .monotonic, .monotonic)) |actual| {
            old = actual;
        } else {
            return;
        }
    }
}

fn addLive(current: *AtomicU64, peak: *AtomicU64, amount: u64) void {
    if (amount == 0) return;
    const new = current.fetchAdd(amount, .monotonic) + amount;
    atomicMax(peak, new);
}

fn subLive(current: *AtomicU64, amount: u64) void {
    if (amount == 0) return;
    var old = current.load(.monotonic);
    while (true) {
        const new = if (old > amount) old - amount else 0;
        if (counterUpdate(current, old, new)) |actual| {
            old = actual;
        } else {
            return;
        }
    }
}

fn counterUpdate(counter: *AtomicU64, old: u64, new: u64) ?u64 {
    return counter.cmpxchgWeak(old, new, .monotonic, .monotonic);
}

fn noteGlobalAlloc(amount: u64, big: bool) void {
    addLive(&g_alloc_stats.current_bytes, &g_alloc_stats.peak_bytes, amount);
    if (big) {
        addLive(&g_alloc_stats.big_current_bytes, &g_alloc_stats.big_peak_bytes, amount);
    } else {
        addLive(&g_alloc_stats.small_current_bytes, &g_alloc_stats.small_peak_bytes, amount);
    }
    _ = g_alloc_stats.total_alloc_bytes.fetchAdd(amount, .monotonic);
    _ = g_alloc_stats.alloc_count.fetchAdd(1, .monotonic);
}

fn noteGlobalFree(amount: u64, big: bool) void {
    subLive(&g_alloc_stats.current_bytes, amount);
    if (big) {
        subLive(&g_alloc_stats.big_current_bytes, amount);
    } else {
        subLive(&g_alloc_stats.small_current_bytes, amount);
    }
    _ = g_alloc_stats.total_free_bytes.fetchAdd(amount, .monotonic);
    _ = g_alloc_stats.free_count.fetchAdd(1, .monotonic);
}

fn noteArenaReset(amount: u64) void {
    subLive(&g_alloc_stats.current_bytes, amount);
    subLive(&g_alloc_stats.small_current_bytes, amount);
    _ = g_alloc_stats.arena_reset_bytes.fetchAdd(amount, .monotonic);
    _ = g_alloc_stats.arena_reset_count.fetchAdd(1, .monotonic);
}

pub fn resetStats() void {
    g_alloc_stats.current_bytes.store(0, .monotonic);
    g_alloc_stats.peak_bytes.store(0, .monotonic);
    g_alloc_stats.small_current_bytes.store(0, .monotonic);
    g_alloc_stats.small_peak_bytes.store(0, .monotonic);
    g_alloc_stats.big_current_bytes.store(0, .monotonic);
    g_alloc_stats.big_peak_bytes.store(0, .monotonic);
    g_alloc_stats.total_alloc_bytes.store(0, .monotonic);
    g_alloc_stats.total_free_bytes.store(0, .monotonic);
    g_alloc_stats.arena_reset_bytes.store(0, .monotonic);
    g_alloc_stats.alloc_count.store(0, .monotonic);
    g_alloc_stats.free_count.store(0, .monotonic);
    g_alloc_stats.resize_count.store(0, .monotonic);
    g_alloc_stats.remap_count.store(0, .monotonic);
    g_alloc_stats.arena_reset_count.store(0, .monotonic);
}

pub fn snapshotStats() AllocStats {
    return .{
        .current_bytes = g_alloc_stats.current_bytes.load(.monotonic),
        .peak_bytes = g_alloc_stats.peak_bytes.load(.monotonic),
        .small_current_bytes = g_alloc_stats.small_current_bytes.load(.monotonic),
        .small_peak_bytes = g_alloc_stats.small_peak_bytes.load(.monotonic),
        .big_current_bytes = g_alloc_stats.big_current_bytes.load(.monotonic),
        .big_peak_bytes = g_alloc_stats.big_peak_bytes.load(.monotonic),
        .total_alloc_bytes = g_alloc_stats.total_alloc_bytes.load(.monotonic),
        .total_free_bytes = g_alloc_stats.total_free_bytes.load(.monotonic),
        .arena_reset_bytes = g_alloc_stats.arena_reset_bytes.load(.monotonic),
        .alloc_count = g_alloc_stats.alloc_count.load(.monotonic),
        .free_count = g_alloc_stats.free_count.load(.monotonic),
        .resize_count = g_alloc_stats.resize_count.load(.monotonic),
        .remap_count = g_alloc_stats.remap_count.load(.monotonic),
        .arena_reset_count = g_alloc_stats.arena_reset_count.load(.monotonic),
    };
}

/// Per-thread arena override. When set (typically by the FFI batch task
/// dispatcher at the start of each file's validation, cleared on exit),
/// `validateAllocator()` returns this instead of the shared smp allocator.
/// Allows every scratch allocation under a task — including those from
/// `validateAllocator()` call sites — to share the per-task arena and
/// be reclaimed wholesale on `arena.deinit()`. Also contains C-library
/// leaks if any FFI'd library forgets to free.
///
/// nullable: when no batch is running (e.g. CLI tools, tests), falls
/// back to smp_allocator which is what we shipped with originally.
pub threadlocal var thread_arena: ?std.mem.Allocator = null;

/// Returns the thread-safe scratch allocator used by validators that
/// don't already have an allocator in scope.
///
/// Resolution: per-thread arena (if set) → smp_allocator. The arena
/// override is set by FFI's executeBatchTask via `setThreadArena` so
/// every scratch alloc under a task shares the same arena, freed
/// wholesale on task end.
///
/// Do NOT use this in tight per-byte allocation loops — those should use
/// the per-task arena passed explicitly by the caller. This is for
/// fixed-size scratch buffers (header search windows, format probes,
/// etc.).
pub fn validateAllocator() std.mem.Allocator {
    return thread_arena orelse std.heap.smp_allocator;
}

/// Returns an allocator whose individual frees reclaim storage even while a
/// batch task is active. Use it for growable or per-item scratch whose memory
/// bound depends on releasing superseded buffers before the task ends.
pub fn reclaimingScratchAllocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

/// Set the per-thread arena override. Call from a task entry, paired
/// with `clearThreadArena()` on exit (typically via `defer`).
pub fn setThreadArena(allocator: std.mem.Allocator) void {
    thread_arena = allocator;
}

pub fn clearThreadArena() void {
    thread_arena = null;
}


/// Big-allocation diversion threshold. Allocations >= this size are routed
/// directly to mmap (via `std.heap.page_allocator`) instead of through the
/// per-task arena. mmap'd pages are returned to the OS on `free()`,
/// avoiding the "arena holds the giant until task ends" hazard for tasks
/// that briefly need a large scratch buffer (e.g. file slurp paths that
/// allocate then free within the same call).
///
/// Default: 16 MB. Tunable via `setBigAllocThreshold` if a future budget
/// queue wants to scale this with the configured per-process budget.
threadlocal var big_alloc_threshold: usize = 16 * 1024 * 1024;

pub fn setBigAllocThreshold(bytes: usize) void {
    big_alloc_threshold = bytes;
}

/// Allocator wrapper that diverts allocations >= `big_alloc_threshold` to
/// `std.heap.page_allocator` (which uses mmap on POSIX, VirtualAlloc on
/// Windows). Small allocations pass through to the parent allocator.
///
/// Typical use: wrap the per-task arena. Small per-validator scratch
/// allocations stay in the arena (cheap, bulk-freed); large slurp buffers
/// are mmap'd and immediately returned to OS on free, even mid-task.
pub const DivertingAllocator = struct {
    parent: std.mem.Allocator,
    threshold: usize,
    small_live_bytes: usize = 0,
    big_live_bytes: usize = 0,
    finished: bool = false,

    pub fn init(parent: std.mem.Allocator, threshold: usize) DivertingAllocator {
        return .{ .parent = parent, .threshold = threshold };
    }

    pub fn allocator(self: *DivertingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Account for small allocations still owned by the per-task arena before
    /// `ArenaAllocator.deinit()` releases them wholesale. Big allocations are
    /// deliberately not cleared here: they bypass the arena, so an outstanding
    /// big allocation at task end is a real leak signal.
    pub fn finishTask(self: *DivertingAllocator) void {
        if (self.finished) return;
        self.finished = true;
        if (self.small_live_bytes > 0) {
            noteArenaReset(@intCast(self.small_live_bytes));
            self.small_live_bytes = 0;
        }
    }

    fn noteAlloc(self: *DivertingAllocator, len: usize, big: bool) void {
        if (len == 0) return;
        if (big) {
            self.big_live_bytes += len;
        } else {
            self.small_live_bytes += len;
        }
        noteGlobalAlloc(@intCast(len), big);
    }

    fn noteFree(self: *DivertingAllocator, len: usize, big: bool) void {
        if (len == 0) return;
        if (big) {
            if (self.big_live_bytes >= len) self.big_live_bytes -= len else self.big_live_bytes = 0;
        } else {
            if (self.small_live_bytes >= len) self.small_live_bytes -= len else self.small_live_bytes = 0;
        }
        noteGlobalFree(@intCast(len), big);
    }

    fn noteResize(self: *DivertingAllocator, old_len: usize, new_len: usize, big: bool) void {
        _ = g_alloc_stats.resize_count.fetchAdd(1, .monotonic);
        if (new_len > old_len) {
            const delta = new_len - old_len;
            if (big) {
                self.big_live_bytes += delta;
            } else {
                self.small_live_bytes += delta;
            }
            addLive(&g_alloc_stats.current_bytes, &g_alloc_stats.peak_bytes, @intCast(delta));
            if (big) {
                addLive(&g_alloc_stats.big_current_bytes, &g_alloc_stats.big_peak_bytes, @intCast(delta));
            } else {
                addLive(&g_alloc_stats.small_current_bytes, &g_alloc_stats.small_peak_bytes, @intCast(delta));
            }
            _ = g_alloc_stats.total_alloc_bytes.fetchAdd(@intCast(delta), .monotonic);
        } else if (old_len > new_len) {
            const delta = old_len - new_len;
            if (big) {
                if (self.big_live_bytes >= delta) self.big_live_bytes -= delta else self.big_live_bytes = 0;
            } else {
                if (self.small_live_bytes >= delta) self.small_live_bytes -= delta else self.small_live_bytes = 0;
            }
            subLive(&g_alloc_stats.current_bytes, @intCast(delta));
            if (big) {
                subLive(&g_alloc_stats.big_current_bytes, @intCast(delta));
            } else {
                subLive(&g_alloc_stats.small_current_bytes, @intCast(delta));
            }
            _ = g_alloc_stats.total_free_bytes.fetchAdd(@intCast(delta), .monotonic);
        }
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        if (len >= self.threshold) {
            const ptr = std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
            if (ptr != null) self.noteAlloc(len, true);
            return ptr;
        }
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) self.noteAlloc(len, false);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        const was_big = memory.len >= self.threshold;
        const becomes_big = new_len >= self.threshold;
        if (was_big != becomes_big) {
            return false;
        }
        const ok = if (was_big)
            std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr)
        else
            self.parent.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.noteResize(memory.len, new_len, was_big);
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        const was_big = memory.len >= self.threshold;
        const becomes_big = new_len >= self.threshold;
        if (was_big != becomes_big) {
            return null;
        }
        const ptr = if (was_big)
            std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr)
        else
            self.parent.rawRemap(memory, alignment, new_len, ret_addr);
        if (ptr != null) {
            _ = g_alloc_stats.remap_count.fetchAdd(1, .monotonic);
            self.noteResize(memory.len, new_len, was_big);
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len >= self.threshold) {
            self.noteFree(memory.len, true);
            std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
            return;
        }
        self.noteFree(memory.len, false);
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

test "DivertingAllocator routes large allocs to page_allocator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var diverter = DivertingAllocator.init(arena.allocator(), 64 * 1024);
    const a = diverter.allocator();

    // Small alloc: stays in arena
    const small = try a.alloc(u8, 1024);
    @memset(small, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), small[500]);

    // Big alloc: diverted to mmap
    const big = try a.alloc(u8, 1024 * 1024);
    @memset(big, 0xBB);
    try std.testing.expectEqual(@as(u8, 0xBB), big[500_000]);
    a.free(big); // returns to OS immediately, not held by arena
}

test "validateAllocator round-trips a 64KB allocation" {
    const a = validateAllocator();
    const buf = try a.alloc(u8, 65536);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 65536), buf.len);
    @memset(buf, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), buf[12345]);
}

test "reclaiming scratch allocator bypasses the per-task arena" {
    var arena_storage: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_storage);
    var arena = std.heap.ArenaAllocator.init(fixed.allocator());
    defer arena.deinit();

    const prior_thread_arena = thread_arena;
    setThreadArena(arena.allocator());
    defer thread_arena = prior_thread_arena;

    try std.testing.expectError(error.OutOfMemory, validateAllocator().alloc(u8, 4096));

    const scratch = reclaimingScratchAllocator();
    const first = try scratch.alloc(u8, 4096);
    scratch.free(first);
    const grown = try scratch.alloc(u8, 8192);
    defer scratch.free(grown);
    try std.testing.expectEqual(@as(usize, 8192), grown.len);
}
