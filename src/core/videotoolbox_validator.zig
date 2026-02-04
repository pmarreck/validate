//! VideoToolbox-based video validation for macOS.
//!
//! This module provides a Zig interface to the C shim (videotoolbox_shim.c)
//! which handles all VideoToolbox framework interactions using dlopen/dlsym
//! for runtime loading.
//!
//! WHY RUNTIME LOADING:
//! Zig's extern declarations for macOS frameworks cause dyld symbol resolution
//! at module load time, leading to bus errors when loaded from worker threads.
//! By using dlopen/dlsym in C, we control exactly when the framework loads.
//!
//! THREAD SAFETY:
//! - Call init() once from the main thread before spawning workers
//! - All VideoToolbox calls are dispatched to the main thread by the C shim

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
// C Shim Interface
// =============================================================================

// Result structure matching C shim
const VTShimResult = extern struct {
    valid: bool,
    frames_decoded: u32,
    error_message: ?[*:0]const u8,
};

// In test mode, use stubs instead of extern declarations to avoid linker issues
const is_test = @import("builtin").is_test;

// C shim function declarations (or stubs in test mode)
const vt_shim_init = if (is_test) struct {
    fn f() bool {
        return false;
    }
}.f else @extern(*const fn () callconv(.c) bool, .{ .name = "vt_shim_init" }).*;

const vt_shim_is_initialized = if (is_test) struct {
    fn f() bool {
        return false;
    }
}.f else @extern(*const fn () callconv(.c) bool, .{ .name = "vt_shim_is_initialized" }).*;

const vt_shim_is_available = if (is_test) struct {
    fn f() bool {
        return false;
    }
}.f else @extern(*const fn () callconv(.c) bool, .{ .name = "vt_shim_is_available" }).*;

const vt_shim_validate_h264 = if (is_test) struct {
    fn f(_: [*]const u8, _: usize, _: [*]const [*]const u8, _: [*]const usize, _: usize, result: *VTShimResult) void {
        result.* = .{ .valid = false, .frames_decoded = 0, .error_message = "Test mode" };
    }
}.f else @extern(*const fn ([*]const u8, usize, [*]const [*]const u8, [*]const usize, usize, *VTShimResult) callconv(.c) void, .{ .name = "vt_shim_validate_h264" }).*;

const vt_shim_validate_hevc = if (is_test) struct {
    fn f(_: [*]const u8, _: usize, _: [*]const [*]const u8, _: [*]const usize, _: usize, result: *VTShimResult) void {
        result.* = .{ .valid = false, .frames_decoded = 0, .error_message = "Test mode" };
    }
}.f else @extern(*const fn ([*]const u8, usize, [*]const [*]const u8, [*]const usize, usize, *VTShimResult) callconv(.c) void, .{ .name = "vt_shim_validate_hevc" }).*;

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

/// Initialize VideoToolbox via dlopen/dlsym.
/// MUST be called from the main thread before any validation.
/// Safe to call multiple times (subsequent calls are no-ops).
/// Returns true if VideoToolbox loaded successfully.
pub fn init() bool {
    return vt_shim_init();
}

/// Check if VideoToolbox has been initialized.
pub fn isInitialized() bool {
    return vt_shim_is_initialized();
}

/// Check if VideoToolbox is available and ready to use.
pub fn isAvailable() bool {
    return vt_shim_is_available();
}

/// Validate H.264 stream using VideoToolbox (via C shim)
/// Thread-safe: can be called from any thread after init().
pub fn validateH264(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;

    if (!vt_shim_is_available()) {
        return VTValidationResult.invalid("VideoToolbox not initialized", .h264);
    }

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
/// Thread-safe: can be called from any thread after init().
pub fn validateHEVC(
    allocator: Allocator,
    codec_private: []const u8,
    samples: []const []const u8,
) VTValidationResult {
    _ = allocator;

    if (!vt_shim_is_available()) {
        return VTValidationResult.invalid("VideoToolbox not initialized", .hevc);
    }

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

/// Pre-initialization - loads VideoToolbox via dlopen.
/// MUST be called from main thread before spawning workers.
pub fn preInit() void {
    _ = init();
}

// Tests disabled - VideoToolbox currently disabled due to dispatch_sync deadlock
// test "VideoToolbox shim availability" {
//     const initialized = isInitialized();
//     if (!initialized) return;
//     _ = isAvailable();
// }
