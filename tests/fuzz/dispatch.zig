//! Tier-1 whole-surface fuzz dispatch — the single code path that BOTH the
//! stdin harness (`fuzz_dispatch.zig`, for AFL++/honggfuzz + committed-crasher
//! CI replay) and the in-memory seeded driver (`fuzz_sweep.zig`) route every
//! untrusted buffer through. Keeping it in one place guarantees the two
//! harnesses exercise byte-for-byte identical behaviour.
//!
//! Intent: take an arbitrary byte buffer and run it through validate's full
//! detect → shallow → deep dispatch, exercising all ~50 validator entry points
//! / ~210 formats reachable from untrusted input. The ROBUSTNESS oracle is
//! implicit: any crash/hang/OOM/UB inside `runOne` is a found bug (a Zig panic
//! aborts the process; the sweep's panic handler attributes it to its input).
//! The verdict returned by the validators is intentionally IGNORED here — a
//! blind mutation that yields a "valid-but-different" file is correct behaviour,
//! so robustness is the only universally-sound assertion at this layer. The
//! DETECTION oracle (corrupt → INVALID for integrity-backed formats) lives in
//! the sweep driver, which has the before/after context this stateless routine
//! lacks.

const std = @import("std");
const core = @import("core");
const fv = core.format_validation;
const FileSource = core.file_source.FileSource;

/// Route one untrusted buffer through the whole detect→shallow→deep dispatch.
/// Pure robustness exercise — return value discarded. `allocator` should be a
/// safety-checking allocator (GPA) so leaks/UAF surface on the explicit-
/// allocator path. Empty input is a no-op (validators treat 0 bytes as unknown).
pub fn runOne(allocator: std.mem.Allocator, input: []const u8) void {
    if (input.len == 0) return;

    // 1. Format detection from the raw header bytes.
    _ = fv.detectFormat(input);

    // 2. Shallow buffer dispatch (FormatValidator.validateFileBuffer →
    //    validateDataBuffer): re-detects and routes into the matching
    //    buffer-based validator.
    var shallow = fv.FormatValidator.initWithAllocator(allocator);
    _ = shallow.validateFileBuffer(input);

    // 3. Deep dispatch via an in-memory FileSource (no file I/O). Re-detect so
    //    the format we hand to validateDeepFromSource is whatever the bytes
    //    actually route to (a mutation may have changed it — follow it).
    const fmt = fv.detectFormat(input);
    var src = FileSource.fromBuffer(input);
    defer src.close();
    var deep = fv.FormatValidator.initDeep();
    _ = deep.validateDeepFromSource(allocator, fmt, &src);
}

/// Detection-aware variant used by the sweep's DETECTION oracle. Runs the same
/// robustness path, then returns the deep verdict so the caller can assert
/// `corrupt → INVALID` when (and only when) it is sound to do so.
pub const Verdict = struct {
    format: fv.FileFormat,
    is_valid: bool,
    depth: fv.ValidationDepth,
};

/// Like `runOne` but returns the deep-validation verdict. Same robustness
/// guarantees; the caller decides whether the verdict is oracle-relevant.
pub fn runOneVerdict(allocator: std.mem.Allocator, input: []const u8) Verdict {
    // Shallow pass first (exercises the buffer dispatch path for robustness).
    var shallow = fv.FormatValidator.initWithAllocator(allocator);
    _ = shallow.validateFileBuffer(input);

    const fmt = fv.detectFormat(input);
    var src = FileSource.fromBuffer(input);
    defer src.close();
    var deep = fv.FormatValidator.initDeep();
    const r = deep.validateDeepFromSource(allocator, fmt, &src);
    return .{ .format = r.format, .is_valid = r.is_valid, .depth = r.validation_depth };
}
