//! Env-flag-gated diagnostic tracing.
//!
//! Why this exists: validate ships ReleaseFast, so a comptime build-mode gate
//! is useless in the wild. A user hitting a false-positive or false-negative
//! after the binary is published needs a runtime opt-in that does not require
//! a rebuild. Per category so a single subsystem (e.g., the H.265 CABAC
//! decoder) can be isolated without drowning in noise from other validators.
//!
//! Hot-path discipline: callers cache the per-category enable state at
//! function entry so the printf/format work is fully elided when tracing is
//! off. The check itself is one `getenv` call, but skipping the comptime-fmt
//! arg pack is the bigger win on inner loops.
//!
//!     const trace_cabac = trace.isEnabled(.h265_cabac);
//!     if (trace_cabac) trace.print(.h265_cabac, "ctu={d} bits={d}", .{ctu, bits});
//!
//! Env vars:
//!   VALIDATE_TRACE          enables ALL categories
//!   VALIDATE_TRACE_<CAT>    enables one category

const std = @import("std");
const runtime = @import("runtime.zig");

pub const Category = enum {
	h264,
	h265,
	h265_cabac,
	heic,
	jpeg,
	pdf,
	tiff,

	fn envName(comptime self: Category) [:0]const u8 {
		return switch (self) {
			.h264 => "VALIDATE_TRACE_H264",
			.h265 => "VALIDATE_TRACE_H265",
			.h265_cabac => "VALIDATE_TRACE_H265_CABAC",
			.heic => "VALIDATE_TRACE_HEIC",
			.jpeg => "VALIDATE_TRACE_JPEG",
			.pdf => "VALIDATE_TRACE_PDF",
			.tiff => "VALIDATE_TRACE_TIFF",
		};
	}
};

/// Returns true if the global VALIDATE_TRACE env var is set or the
/// per-category override is set. Cache the result at function entry.
pub fn isEnabled(comptime cat: Category) bool {
	if (runtime.hasEnvVar("VALIDATE_TRACE")) return true;
	return runtime.hasEnvVar(cat.envName());
}

/// Prefix-tag a trace line and emit to stderr. Gate the call with
/// isEnabled() so format+args overhead is avoided when off. A trailing
/// newline is added.
pub fn print(comptime cat: Category, comptime fmt: []const u8, args: anytype) void {
	const tag = comptime "[" ++ cat.envName() ++ "] ";
	std.debug.print(tag ++ fmt ++ "\n", args);
}
