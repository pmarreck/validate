//! Zig bindings for libwebp decoder.
//!
//! This module provides access to the libwebp decoding API for validating
//! WebP images by fully decompressing them.

pub const c = @cImport({
    @cInclude("webp/decode.h");
    @cInclude("webp/types.h");
});

// Re-export commonly used types and functions
pub const WebPGetInfo = c.WebPGetInfo;
pub const WebPDecodeRGBA = c.WebPDecodeRGBA;
pub const WebPDecodeRGBAInto = c.WebPDecodeRGBAInto;
pub const WebPFree = c.WebPFree;

/// Get image dimensions without decoding.
/// Returns true if valid WebP, false otherwise.
pub fn getInfo(data: []const u8, width: *c_int, height: *c_int) bool {
    return c.WebPGetInfo(data.ptr, data.len, width, height) != 0;
}

/// Decode WebP to RGBA buffer.
/// Caller must free returned memory with WebPFree.
pub fn decodeRGBA(data: []const u8, width: *c_int, height: *c_int) ?[*]u8 {
    return c.WebPDecodeRGBA(data.ptr, data.len, width, height);
}

/// Decode WebP into pre-allocated RGBA buffer.
/// Returns null on failure.
pub fn decodeRGBAInto(data: []const u8, output: []u8, stride: c_int) ?[*]u8 {
    return c.WebPDecodeRGBAInto(
        data.ptr,
        data.len,
        output.ptr,
        output.len,
        stride,
    );
}

/// Free memory allocated by WebP decode functions.
pub fn free(ptr: ?*anyopaque) void {
    c.WebPFree(ptr);
}
