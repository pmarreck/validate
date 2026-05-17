//! Runtime singleton for the 0.16 `std.Io` interface.
//!
//! validate's public API is a C FFI — there is no Juicy Main entry point
//! where `init.io` is naturally available. Threading `io: std.Io` through
//! every function that touches a clock, mutex, or filesystem path would
//! cascade into thousands of call sites and would also change the C ABI
//! (each FFI function would grow an opaque `io` pointer parameter).
//!
//! The singleton + helpers pattern from
//! `ZIG_RECENT_API_CHANGES.md` §12.31 is the pragmatic shortcut for this
//! exact shape (single-entry CLI / FFI library with synchronous shutdown).
//! `ensureInit()` is idempotent and called from each FFI entry point, so
//! library consumers don't need to know about the singleton at all.
//!
//! The Zig std.Io interface itself is thread-safe; the underlying
//! `std.Io.Threaded` backend has its own internal synchronization. The
//! one-time global write happens under `init_mutex` so concurrent FFI
//! callers can't race the initialization.

const std = @import("std");

var threaded_storage: std.Io.Threaded = undefined;
var g_io: ?std.Io = null;

// Hand-rolled once-guard (std.once is removed in 0.16, std.Io.Mutex
// needs io which is exactly what we're constructing — chicken-and-egg).
// Atomic cmpxchg picks a single winner thread; losers spin briefly until
// the winner publishes the result. The expected steady-state path is a
// single acquire-load returning `true`.
var init_started: std.atomic.Value(bool) = .init(false);
var init_done: std.atomic.Value(bool) = .init(false);

/// Ensure the global `Io` is initialized. Safe to call from any thread,
/// any number of times. First call constructs a single-threaded
/// `Io.Threaded` (validate's worker-pool handles parallelism on top of
/// the synchronous Io primitives — see thread_pool.zig).
pub fn ensureInit() void {
    if (init_done.load(.acquire)) return;
    if (init_started.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
        threaded_storage = .init_single_threaded;
        g_io = threaded_storage.io();
        init_done.store(true, .release);
    } else {
        while (!init_done.load(.acquire)) std.atomic.spinLoopHint();
    }
}

/// Return the global `Io`. Panics if `ensureInit()` was not called first.
pub fn io() std.Io {
    return g_io.?;
}

// ─── std.fs.cwd().X(...) → 0.16 std.Io.Dir convenience wrappers ──────────
// These preserve the 0.15 call shape (no explicit io arg, no options struct
// where the old API didn't have one) by closing over the runtime singleton.
// Mechanical sed targets across the codebase.

/// 0.16 replacement for `std.fs.cwd().openFile(path, opts)`.
pub fn openFile(path: []const u8, opts: std.Io.File.OpenOptions) std.Io.File.OpenError!std.Io.File {
    ensureInit();
    return std.Io.Dir.cwd().openFile(g_io.?, path, opts);
}

/// 0.16 replacement for `std.fs.cwd().openDir(path, opts)`.
pub fn openDir(path: []const u8, opts: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
    ensureInit();
    return std.Io.Dir.cwd().openDir(g_io.?, path, opts);
}

/// 0.16 replacement for `std.fs.cwd().access(path, opts)`.
pub fn access(path: []const u8, opts: std.Io.Dir.AccessOptions) std.Io.Dir.AccessError!void {
    ensureInit();
    return std.Io.Dir.cwd().access(g_io.?, path, opts);
}

/// 0.16 replacement for `std.fs.cwd().statFile(path)`. 0.16 grew an options
/// param; we default to `.{}` to match the prior call shape exactly.
pub fn statFile(path: []const u8) std.Io.Dir.StatFileError!std.Io.Dir.Stat {
    ensureInit();
    return std.Io.Dir.cwd().statFile(g_io.?, path, .{});
}
