//! LibRaw-based Camera RAW Validation
//!
//! Validates camera RAW formats (ARW, CR2, NEF, DNG, etc.) by actually
//! decoding the raw sensor data using LibRaw.
//!
//! LibRaw is dual-licensed under LGPL-2.1 or CDDL-1.0.
//! We use it under CDDL for commercial compatibility.

const std = @import("std");
const libraw = @import("libraw");
const errmsg = @import("error_messages.zig");

/// Result of LibRaw validation
pub const LibRawValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    camera_make: ?[]const u8 = null,
    camera_model: ?[]const u8 = null,
};

/// Validate a camera RAW file by decoding it with LibRaw
pub fn validateRawFile(path: []const u8) LibRawValidationResult {
    // Create null-terminated path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) {
        return .{ .valid = false, .error_message = "Path too long" };
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = path_buf[0..path.len :0];

    // Initialize LibRaw processor
    const data = libraw.libraw_init(0);
    if (data == null) {
        return .{ .valid = false, .error_message = "Failed to initialize LibRaw" };
    }
    defer libraw.libraw_close(data);

    // Open the file
    const open_result = libraw.libraw_open_file(data, path_z);
    if (open_result != 0) {
        return .{
            .valid = false,
            .error_message = getLibRawError(open_result),
        };
    }

    return finishValidation(data);
}

/// Validate a camera RAW image from an in-memory buffer.
/// Uses libraw_open_buffer so no file I/O is needed — integrates with FileSource mmap.
pub fn validateRawBuffer(buffer: []const u8) LibRawValidationResult {
    const data = libraw.libraw_init(0);
    if (data == null) {
        return .{ .valid = false, .error_message = "Failed to initialize LibRaw" };
    }
    defer libraw.libraw_close(data);

    const open_result = libraw.libraw_open_buffer(data, buffer.ptr, buffer.len);
    if (open_result != 0) {
        return .{
            .valid = false,
            .error_message = getLibRawError(open_result),
        };
    }

    return finishValidation(data);
}

/// Shared finishing steps: unpack raw, extract dimensions and camera info
fn finishValidation(data: ?*libraw.libraw_data_t) LibRawValidationResult {
    // Unpack the raw data (decode sensor data)
    const unpack_result = libraw.libraw_unpack(data);
    if (unpack_result != 0) {
        return .{
            .valid = false,
            .error_message = getLibRawError(unpack_result),
        };
    }

    // Note: `libraw_unpack_thumb` was tried here but doesn't detect
    // corruption — LibRaw just extracts the JPEG thumbnail bytes from the
    // TIFF container without decoding them, so bit flips inside the JPEG
    // don't surface as errors. The real lift for NEF/NRW/CR2/ARW thumbnail
    // coverage needs a DNG-style scan-for-SOI-then-validate-JPEG path
    // (see image_validators.zig:validateDngDeep). Tracked in PLAN.md P2.

    // Get image sizes
    const sizes = &data.?.*.sizes;
    const width: u32 = @intCast(sizes.width);
    const height: u32 = @intCast(sizes.height);

    // Get camera info
    const idata = &data.?.*.idata;
    const make_ptr: [*:0]const u8 = @ptrCast(&idata.make);
    const model_ptr: [*:0]const u8 = @ptrCast(&idata.model);

    return .{
        .valid = true,
        .width = width,
        .height = height,
        .camera_make = std.mem.span(make_ptr),
        .camera_model = std.mem.span(model_ptr),
    };
}

/// Convert LibRaw error code to human-readable message
fn getLibRawError(code: c_int) []const u8 {
    return switch (code) {
        libraw.LIBRAW_SUCCESS => "Success",
        libraw.LIBRAW_UNSPECIFIED_ERROR => "Unspecified error",
        libraw.LIBRAW_FILE_UNSUPPORTED => errmsg.unsupported("file format"),
        libraw.LIBRAW_REQUEST_FOR_NONEXISTENT_IMAGE => "Non-existent image requested",
        libraw.LIBRAW_OUT_OF_ORDER_CALL => "Out of order call",
        libraw.LIBRAW_NO_THUMBNAIL => "No thumbnail",
        libraw.LIBRAW_UNSUPPORTED_THUMBNAIL => errmsg.unsupported("thumbnail"),
        libraw.LIBRAW_INPUT_CLOSED => "Input closed",
        libraw.LIBRAW_NOT_IMPLEMENTED => "Not implemented",
        libraw.LIBRAW_UNSUFFICIENT_MEMORY => "Insufficient memory",
        libraw.LIBRAW_DATA_ERROR => "Data error - file may be corrupted",
        libraw.LIBRAW_IO_ERROR => "I/O error",
        libraw.LIBRAW_CANCELLED_BY_CALLBACK => "Cancelled by callback",
        libraw.LIBRAW_BAD_CROP => "Bad crop",
        libraw.LIBRAW_TOO_BIG => "Image too big",
        libraw.LIBRAW_MEMPOOL_OVERFLOW => "Memory pool overflow",
        else => errmsg.unknown("LibRaw error"),
    };
}

test "LibRaw initialization" {
    const data = libraw.libraw_init(0);
    try std.testing.expect(data != null);
    libraw.libraw_close(data);
}
