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

    pub fn init(parent: std.mem.Allocator, threshold: usize) DivertingAllocator {
        return .{ .parent = parent, .threshold = threshold };
    }

    pub fn allocator(self: *DivertingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
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
            return std.heap.page_allocator.rawAlloc(len, alignment, ret_addr);
        }
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        // If either the current or new size crosses the threshold, refuse to
        // resize in place — caller will alloc + copy + free, which routes
        // each correctly.
        if (memory.len >= self.threshold or new_len >= self.threshold) {
            return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
        }
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len >= self.threshold or new_len >= self.threshold) {
            return std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }
        return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *DivertingAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len >= self.threshold) {
            std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
            return;
        }
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
