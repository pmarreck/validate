//! zlib wrapper for robust deflate decompression.
//!
//! Uses the system zlib library instead of Zig's std.compress.flate,
//! which has known bugs (ziglang/zig#24963) that cause crashes on valid
//! deflate streams.
//!
//! This module provides a simple interface for raw deflate decompression
//! (no zlib/gzip headers) suitable for ZIP file entry decompression.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("zlib.h");
});

/// Error types for zlib operations
pub const ZlibError = error{
    /// zlib initialization failed
    InitFailed,
    /// Decompression encountered invalid data
    DataError,
    /// Output buffer too small
    BufferError,
    /// Generic zlib error
    ZlibError,
    /// Memory allocation failed
    OutOfMemory,
    /// Unexpected end of input
    UnexpectedEof,
};

/// Decompress raw deflate data (no zlib/gzip header) into a pre-allocated buffer.
/// Returns the number of bytes written to the output buffer.
pub fn inflateRaw(compressed: []const u8, output: []u8) ZlibError!usize {
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = output.ptr,
        .avail_out = @intCast(output.len),
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Initialize for raw deflate (negative windowBits)
    // -15 means raw deflate with 32KB window
    const init_ret = c.inflateInit2(&stream, -15);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.inflateEnd(&stream);

    // Decompress
    const ret = c.inflate(&stream, c.Z_FINISH);

    return switch (ret) {
        c.Z_STREAM_END => stream.total_out,
        c.Z_OK => ZlibError.BufferError, // Output buffer full but not done
        c.Z_DATA_ERROR => ZlibError.DataError,
        c.Z_BUF_ERROR => ZlibError.BufferError,
        c.Z_MEM_ERROR => ZlibError.OutOfMemory,
        else => ZlibError.ZlibError,
    };
}

/// Decompress zlib-format data (with zlib header), allocating the output buffer.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn inflateZlibAlloc(allocator: Allocator, compressed: []const u8, max_output_size: usize) (Allocator.Error || ZlibError)![]u8 {
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Initialize for zlib format (default windowBits = 15)
    const init_ret = c.inflateInit(&stream);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.inflateEnd(&stream);

    // Start with a reasonable buffer size, grow as needed
    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);

        switch (ret) {
            c.Z_STREAM_END => {
                // Done - shrink buffer to actual size
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                return output[0..final_size];
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                // Need more output space
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        return ZlibError.BufferError;
                    }
                    output = try allocator.realloc(output, new_size);
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    // No more input but not at stream end
                    return ZlibError.UnexpectedEof;
                }
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
}

/// Decompress raw deflate data, allocating the output buffer.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn inflateRawAlloc(allocator: Allocator, compressed: []const u8, max_output_size: usize) (Allocator.Error || ZlibError)![]u8 {
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Initialize for raw deflate
    const init_ret = c.inflateInit2(&stream, -15);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.inflateEnd(&stream);

    // Start with a reasonable buffer size, grow as needed
    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);

        switch (ret) {
            c.Z_STREAM_END => {
                // Done - shrink buffer to actual size
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                return output[0..final_size];
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                // Need more output space
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        return ZlibError.BufferError;
                    }
                    output = try allocator.realloc(output, new_size);
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    // No more input but not at stream end
                    return ZlibError.UnexpectedEof;
                }
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
}

/// Decompress raw deflate data and compute CRC32 simultaneously.
/// Returns the decompressed size and CRC32 value.
pub fn inflateRawWithCrc(compressed: []const u8, output: []u8) ZlibError!struct { size: usize, crc32: u32 } {
    const size = try inflateRaw(compressed, output);

    // Compute CRC32 of decompressed data
    const crc = c.crc32(0, output.ptr, @intCast(size));

    return .{ .size = size, .crc32 = @intCast(crc) };
}

/// Decompress gzip data (with header) and compute CRC32.
/// Returns the decompressed size, CRC32, and ISIZE from trailer.
/// This is for validating gzip files by comparing computed vs stored values.
pub fn inflateGzipWithCrc(allocator: Allocator, compressed: []const u8, max_output_size: usize) (Allocator.Error || ZlibError)!struct {
    decompressed_size: usize,
    computed_crc32: u32,
    data: []u8,
} {
    var stream: c.z_stream = .{
        .next_in = @constCast(compressed.ptr),
        .avail_in = @intCast(compressed.len),
        .next_out = undefined,
        .avail_out = 0,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Initialize for gzip (windowBits = 15 + 16 = 31 for gzip)
    const init_ret = c.inflateInit2(&stream, 31);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.inflateEnd(&stream);

    // Start with reasonable buffer, grow as needed
    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 65536) output_size = 65536;

    var output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);

        switch (ret) {
            c.Z_STREAM_END => {
                // Done - compute CRC and shrink buffer
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                const crc = c.crc32(0, output.ptr, @intCast(final_size));
                return .{
                    .decompressed_size = final_size,
                    .computed_crc32 = @intCast(crc),
                    .data = output[0..final_size],
                };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                // Need more output space
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        return ZlibError.BufferError;
                    }
                    output = try allocator.realloc(output, new_size);
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    return ZlibError.UnexpectedEof;
                }
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
}

/// Validate a gzip file by decompressing and verifying CRC32/ISIZE.
/// This reads the entire file into memory - use for files up to a reasonable size.
/// Returns true if valid, false if CRC or size mismatch.
pub fn validateGzip(allocator: Allocator, file_data: []const u8, max_decompressed: usize) (Allocator.Error || ZlibError)!bool {
    if (file_data.len < 18) return ZlibError.DataError; // Min gzip size

    // Extract stored CRC and ISIZE from trailer
    const stored_crc = std.mem.readInt(u32, file_data[file_data.len - 8 ..][0..4], .little);
    const stored_isize = std.mem.readInt(u32, file_data[file_data.len - 4 ..][0..4], .little);

    // Decompress and compute CRC
    const result = try inflateGzipWithCrc(allocator, file_data, max_decompressed);
    defer allocator.free(result.data);

    // Verify CRC
    if (result.computed_crc32 != stored_crc) {
        return false;
    }

    // Verify ISIZE (mod 2^32)
    const computed_isize: u32 = @truncate(result.decompressed_size);
    if (computed_isize != stored_isize) {
        return false;
    }

    return true;
}

/// Check if zlib is available and working
pub fn isAvailable() bool {
    // Try to init/deinit a stream
    var stream: c.z_stream = std.mem.zeroes(c.z_stream);
    const ret = c.inflateInit2(&stream, -15);
    if (ret != c.Z_OK) return false;
    _ = c.inflateEnd(&stream);
    return true;
}

/// Get zlib version string
pub fn version() []const u8 {
    const ver = c.zlibVersion();
    if (ver) |v| {
        return std.mem.span(v);
    }
    return "unknown";
}

// ============================================================================
// Tests
// ============================================================================

test "inflateRaw basic" {
    // This is "hello" compressed with raw deflate
    const compressed = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    var output: [64]u8 = undefined;

    const size = try inflateRaw(&compressed, &output);
    try std.testing.expectEqualStrings("hello", output[0..size]);
}

test "inflateRawWithCrc" {
    const compressed = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    var output: [64]u8 = undefined;

    const result = try inflateRawWithCrc(&compressed, &output);
    try std.testing.expectEqualStrings("hello", output[0..result.size]);
    // CRC32 of "hello" is 0x3610a686
    try std.testing.expectEqual(@as(u32, 0x3610a686), result.crc32);
}

test "inflateRaw invalid data" {
    const invalid = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var output: [64]u8 = undefined;

    const result = inflateRaw(&invalid, &output);
    try std.testing.expectError(ZlibError.DataError, result);
}

test "isAvailable" {
    try std.testing.expect(isAvailable());
}

test "version" {
    const ver = version();
    try std.testing.expect(ver.len > 0);
}
