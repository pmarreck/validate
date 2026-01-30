//! Deep HEIC/AVIF validation using libheif.
//!
//! This module provides comprehensive HEIF validation by actually decoding
//! the image data and detecting any errors in the compressed stream.
//!
//! Uses libheif's decode API which validates:
//! - ISOBMFF container structure
//! - HEVC/AV1 bitstream integrity
//! - Color profile validity
//! - Image item references
//!
//! Thread safety: libheif requires heif_init() to be called before multithreaded use.
//! This module uses std.once to ensure initialization happens exactly once.

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("libheif/heif.h");
});

/// Global initialization state for libheif (thread-safe)
var heif_init_once = std.once(initHeif);
var heif_init_success: bool = false;

fn initHeif() void {
    // Debug: log before init
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("VALIDATE_DEBUG") != null) {
            std.debug.print("[HEIF] Calling heif_init()...\n", .{});
        }
    }
    const err = c.heif_init(null);
    heif_init_success = (err.code == c.heif_error_Ok);
    if (comptime builtin.os.tag != .windows) {
        if (std.posix.getenv("VALIDATE_DEBUG") != null) {
            std.debug.print("[HEIF] heif_init() returned: success={}\n", .{heif_init_success});
        }
    }
}

/// Ensure libheif is initialized. Safe to call from multiple threads.
fn ensureInitialized() bool {
    heif_init_once.call();
    return heif_init_success;
}

/// Result of deep HEIF validation
pub const HeifValidationResult = struct {
    valid: bool,
    structural_only: bool, // true if we could only do structural validation (not full decode)
    error_message: ?[]const u8,
    is_heic: bool, // true for HEIC, false for AVIF

    pub fn ok(is_heic: bool) HeifValidationResult {
        return .{ .valid = true, .structural_only = false, .error_message = null, .is_heic = is_heic };
    }

    pub fn invalid(message: []const u8, is_heic: bool) HeifValidationResult {
        return .{ .valid = false, .structural_only = false, .error_message = message, .is_heic = is_heic };
    }

    /// Valid structure but couldn't do full decode (ambiguous file type)
    pub fn structural_valid(is_heic: bool) HeifValidationResult {
        return .{ .valid = true, .structural_only = true, .error_message = null, .is_heic = is_heic };
    }
};

/// Validate a HEIC/AVIF file by attempting full decode.
/// Returns validation result with error details if invalid.
pub fn validateHeifDeep(file_path: []const u8) HeifValidationResult {
    // Open file using Zig's stdlib
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => HeifValidationResult.invalid("File not found", true),
            error.AccessDenied => HeifValidationResult.invalid("Access denied", true),
            else => HeifValidationResult.invalid("Failed to open file", true),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
        return HeifValidationResult.invalid("Failed to get file size", true);
    };

    // Limit to reasonable size (200MB for high-res photos)
    if (file_size > 200 * 1024 * 1024) {
        return HeifValidationResult.invalid("File too large for deep validation", true);
    }

    if (file_size < 12) {
        return HeifValidationResult.invalid("File too small", true);
    }

    // Allocate buffer
    const buffer = std.c.malloc(file_size) orelse {
        return HeifValidationResult.invalid("Memory allocation failed", true);
    };
    defer std.c.free(buffer);

    // Read entire file
    const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
    const bytes_read = file.readAll(buf_slice) catch {
        return HeifValidationResult.invalid("Failed to read file", true);
    };
    if (bytes_read != file_size) {
        return HeifValidationResult.invalid("Incomplete file read", true);
    }

    return validateHeifDeepFromBuffer(buf_slice);
}

/// Validate HEIF from memory buffer.
pub fn validateHeifDeepFromBuffer(data: []const u8) HeifValidationResult {
    // Ensure libheif is initialized (thread-safe, only runs once)
    if (!ensureInitialized()) {
        return HeifValidationResult.invalid("Failed to initialize libheif", true);
    }

    if (data.len < 12) {
        return HeifValidationResult.invalid("File too small", true);
    }

    // Check file type (HEIC vs AVIF)
    const filetype = c.heif_check_filetype(data.ptr, @intCast(data.len));
    const is_heic = switch (filetype) {
        c.heif_filetype_yes_supported, c.heif_filetype_yes_unsupported => true,
        c.heif_filetype_maybe => true, // Assume HEIC for maybe
        else => false,
    };

    if (filetype == c.heif_filetype_no) {
        return HeifValidationResult.invalid("Not a valid HEIF/AVIF file", is_heic);
    }

    // Track if this is an "unsupported" variant - if decode fails, we'll still
    // accept it as structurally valid rather than calling it corrupted
    const is_unsupported_variant = (filetype == c.heif_filetype_yes_unsupported);

    // For ambiguous files, be cautious - structural validation only
    if (filetype == c.heif_filetype_maybe) {
        return HeifValidationResult.structural_valid(is_heic);
    }

    // Create context
    const ctx = c.heif_context_alloc();
    if (ctx == null) {
        return HeifValidationResult.invalid("Failed to allocate context", is_heic);
    }
    defer c.heif_context_free(ctx);

    // Read from memory
    var err = c.heif_context_read_from_memory_without_copy(ctx, data.ptr, data.len, null);
    if (err.code != c.heif_error_Ok) {
        // Container parse failed - if it's supposedly HEIF but we can't parse it, it's broken
        return HeifValidationResult.invalid("Failed to parse HEIF container", is_heic);
    }

    // Get primary image handle (opaque pointer type)
    var handle: ?*c.struct_heif_image_handle = null;
    err = c.heif_context_get_primary_image_handle(ctx, &handle);
    if (err.code != c.heif_error_Ok or handle == null) {
        // For unsupported variants (like animated AVIF), there might not be a "primary" image
        // in the traditional sense - accept as structurally valid
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Failed to get primary image", is_heic);
    }
    defer c.heif_image_handle_release(handle);

    // Get image dimensions to validate
    const width = c.heif_image_handle_get_width(handle);
    const height = c.heif_image_handle_get_height(handle);

    if (width <= 0 or height <= 0) {
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Invalid image dimensions", is_heic);
    }

    // Attempt to decode the image (this validates the bitstream)
    // Debug: flush stderr before decode in case of crash
    const debug_enabled = if (comptime builtin.os.tag == .windows) false else (std.posix.getenv("VALIDATE_DEBUG") != null);
    if (debug_enabled) {
        std.debug.print("[HEIF] About to decode image: {d}x{d}\n", .{ width, height });
    }

    var image: ?*c.struct_heif_image = null;
    err = c.heif_decode_image(handle, &image, c.heif_colorspace_RGB, c.heif_chroma_interleaved_RGBA, null);
    if (err.code != c.heif_error_Ok or image == null) {
        // For unsupported variants, decode failure is expected - accept as structural
        if (is_unsupported_variant) {
            return HeifValidationResult.structural_valid(is_heic);
        }
        return HeifValidationResult.invalid("Decode failed - corrupted data", is_heic);
    }
    defer c.heif_image_release(image);

    // Full decode succeeded!
    if (debug_enabled) {
        std.debug.print("[HEIF] Decode succeeded!\n", .{});
    }
    return HeifValidationResult.ok(is_heic);
}

// Tests
test "reject invalid data" {
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateHeifDeepFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
}

test "reject truncated HEIF" {
    // Just ftyp box start, nothing else
    const truncated = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c' };
    const result = validateHeifDeepFromBuffer(&truncated);
    try std.testing.expect(!result.valid);
}
