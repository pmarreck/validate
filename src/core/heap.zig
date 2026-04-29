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

/// Returns the thread-safe scratch allocator used by validators that
/// don't already have an allocator in scope.
///
/// Do NOT use this in tight per-byte allocation loops — those should use
/// the per-task arena passed by the caller. This is for fixed-size
/// scratch buffers (header search windows, format probes, etc.).
pub fn validateAllocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

test "validateAllocator round-trips a 64KB allocation" {
    const a = validateAllocator();
    const buf = try a.alloc(u8, 65536);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 65536), buf.len);
    @memset(buf, 0xA5);
    try std.testing.expectEqual(@as(u8, 0xA5), buf[12345]);
}
