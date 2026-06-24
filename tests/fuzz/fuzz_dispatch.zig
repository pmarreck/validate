//! Tier-1 whole-surface stdin fuzz harness.
//!
//! AFL++/honggfuzz-style: reads one input from stdin and routes it through
//! validate's full detect→shallow→deep dispatch (`dispatch.runOne`). Crash-only
//! oracle — a non-zero/abnormal exit (segv/abort/bus) means the validator
//! crashed on untrusted input, which is the bug class fuzzing exists to find.
//!
//! Two consumers: (1) coverage-guided fuzzers (AFL++/honggfuzz feed inputs on
//! stdin); (2) the `./fuzz` runner's CI-safe replay of the committed minimized
//! crashers in `tests/fuzz/corpus/` (self-contained, no fixtures).

const std = @import("std");
const core = @import("core");
const dispatch = @import("dispatch.zig");

pub fn main() !void {
    // DebugAllocator (0.16 rename of GeneralPurposeAllocator) for leak/UAF
    // detection on the explicit-allocator path.
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // 0.16: File has no readToEndAlloc — read via the streaming reader interface.
    const io = core.runtime.io();
    const stdin = std.Io.File.stdin();
    var rbuf: [64 * 1024]u8 = undefined;
    var r = stdin.readerStreaming(io, &rbuf);
    // Cap input at 64 MiB — matches fuzz_smoke's headline size and bounds RAM.
    const input = try r.interface.allocRemaining(alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(input);

    dispatch.runOne(alloc, input);
}
