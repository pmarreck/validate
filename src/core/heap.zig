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

test "validateAllocator round-trips a 64KB allocation" {
    const a = validateAllocator();
    const buf = try a.alloc(u8, 65536);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 65536), buf.len);
    @memset(buf, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), buf[12345]);
}
