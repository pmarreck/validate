//! VideoToolbox-based video validation for macOS.
//!
//! This module provides a Zig interface to the C shim (videotoolbox_shim.c)
//! which handles all VideoToolbox framework interactions in a thread-safe manner.
//!
//! WHY A C SHIM:
//! Zig's extern declarations for macOS frameworks cause dyld symbol resolution
//! at module load time, leading to bus errors. By keeping VideoToolbox code in C,
//! we get predictable symbol resolution and can use GCD's dispatch_sync for
//! thread safety.
//!
//! THREAD SAFETY:
//! All VideoToolbox calls are automatically dispatched to the main thread
//! by the C shim, so these functions can be called from any thread.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// This entire module is macOS-only
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("videotoolbox_validator.zig is macOS-only");
    }
}

// =============================================================================
// C Shim Interface (manual declarations to avoid @cImport issues)
// =============================================================================

// Result structure matching C shim
const VTShimResult = extern struct {
    valid: bool,
    frames_decoded: u32,
    error_message: ?[*:0]const u8,
};

// C shim function declarations
extern "c" fn vt_shim_validate_h264(
    codec_private: [*]const u8,
    codec_private_size: usize,
    samples: [*]const [*]const u8,
    sample_sizes: [*]const usize,
    num_samples: usize,
    result: *VTShimResult,
) void;

extern "c" fn vt_shim_validate_hevc(
    codec_private: [*]const u8,
    codec_private_size: usize,
    samples: [*]const [*]const u8,
    sample_sizes: [*]const usize,
    num_samples: usize,
    result: *VTShimResult,
) void;

extern "c" fn vt_shim_is_available() bool;

/// Result of VideoToolbox validation
pub const VTValidationResult = struct {
    valid: bool,
    frames_decoded: u32,
    error_message: ?[]const u8,
    codec: VideoCodec,

    pub fn ok(codec: VideoCodec, frames: u32) VTValidationResult {
        return .{
            .valid = true,
            .frames_decoded = frames,
            .error_message = null,
            .codec = codec,
        };
    }

    pub fn invalid(msg: []const u8, codec: VideoCodec) VTValidationResult {
        return .{
            .valid = false,
            .frames_decoded = 0,
            .error_message = msg,
            .codec = codec,
        };
    }
};

/// Video codec type
pub const VideoCodec = enum {
    h264,
    hevc,
    av1,
};

/// Validate H.264 stream using VideoToolbox (via C shim)
/// Thread-safe: can be called from any thread.
pub fn validateH264(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;

    if (samples.len == 0) {
        return VTValidationResult.invalid("No samples provided", .h264);
    }

    // Build arrays for C interface
    var sample_ptrs: [8192][*]const u8 = undefined;
    var sample_sizes: [8192]usize = undefined;
    const num_samples = @min(samples.len, 8192);

    for (0..num_samples) |i| {
        sample_ptrs[i] = samples[i].ptr;
        sample_sizes[i] = samples[i].len;
    }

    var result: VTShimResult = undefined;
    vt_shim_validate_h264(
        codec_private.ptr,
        codec_private.len,
        @ptrCast(&sample_ptrs),
        &sample_sizes,
        num_samples,
        &result,
    );

    if (result.valid) {
        return VTValidationResult.ok(.h264, result.frames_decoded);
    } else {
        const msg = if (result.error_message) |ptr|
            std.mem.span(ptr)
        else
            "Unknown error";
        return VTValidationResult.invalid(msg, .h264);
    }
}

/// Validate HEVC stream using VideoToolbox (via C shim)
/// Thread-safe: can be called from any thread.
pub fn validateHEVC(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;

    if (samples.len == 0) {
        return VTValidationResult.invalid("No samples provided", .hevc);
    }

    // Build arrays for C interface
    var sample_ptrs: [8192][*]const u8 = undefined;
    var sample_sizes: [8192]usize = undefined;
    const num_samples = @min(samples.len, 8192);

    for (0..num_samples) |i| {
        sample_ptrs[i] = samples[i].ptr;
        sample_sizes[i] = samples[i].len;
    }

    var result: VTShimResult = undefined;
    vt_shim_validate_hevc(
        codec_private.ptr,
        codec_private.len,
        @ptrCast(&sample_ptrs),
        &sample_sizes,
        num_samples,
        &result,
    );

    if (result.valid) {
        return VTValidationResult.ok(.hevc, result.frames_decoded);
    } else {
        const msg = if (result.error_message) |ptr|
            std.mem.span(ptr)
        else
            "Unknown error";
        return VTValidationResult.invalid(msg, .hevc);
    }
}

/// Validate AV1 stream using VideoToolbox
/// Note: AV1 support requires macOS 13+ and is not yet implemented in the C shim.
pub fn validateAV1(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;
    _ = codec_private;
    _ = samples;
    return VTValidationResult.invalid("AV1 VideoToolbox validation not yet implemented", .av1);
}

/// Check if AV1 hardware decode is available
pub fn isAV1Available() bool {
    // AV1 requires macOS 13+ and ideally Apple Silicon
    return false; // Not implemented yet
}

/// Pre-initialization (no-op with C shim, kept for API compatibility)
pub fn preInit() void {
    // The C shim handles all initialization internally
}

test "VideoToolbox shim availability" {
    // Just verify the C shim is linked correctly
    const available = vt_shim_is_available();
    try std.testing.expect(available);
}
