//! zlib wrapper for robust deflate decompression.
//!
//! Uses bundled zlib (allyourcodebase/zlib) built from source via Zig's
//! build system. This avoids Zig's std.compress.flate which has known bugs
//! (ziglang/zig#24963) that cause crashes on valid deflate streams.
//!
//! The bundled zlib is fully portable across macOS, Linux, and Windows
//! with no system library dependencies.
//!
//! This module provides a simple interface for raw deflate decompression
//! (no zlib/gzip headers) suitable for ZIP file entry decompression.

const std = @import("std");
const heap = @import("heap.zig");
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
    /// Decompressed output exceeds caller's maximum
    DecompressedTooLarge,
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

/// Result type for ratio-aware decompression — distinguishes success, limit exceeded, corrupt data, and alloc failure.
pub const DecompressResult = union(enum) {
    ok: []u8,
    exceeded_limit: struct {
        bytes_produced: usize,
        compressed_len: usize,
        ratio: usize,
    },
    data_error,
    alloc_error,
};

/// Decompress zlib-format data, returning DecompressResult instead of an error union.
/// When output would exceed max_output_size, returns .exceeded_limit with compression ratio info.
/// Caller owns the slice in the .ok case and must free it with the same allocator.
pub fn inflateZlibAllocWithRatio(allocator: Allocator, compressed: []const u8, max_output_size: usize) DecompressResult {
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
        return .data_error;
    }
    defer _ = c.inflateEnd(&stream);

    // Start with a reasonable buffer size, grow as needed
    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = allocator.alloc(u8, output_size) catch return .alloc_error;

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
                return .{ .ok = output[0..final_size] };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                // Need more output space
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        const bytes_produced = stream.total_out;
                        const ratio = if (compressed.len > 0) bytes_produced / compressed.len else 0;
                        allocator.free(output);
                        return .{ .exceeded_limit = .{
                            .bytes_produced = bytes_produced,
                            .compressed_len = compressed.len,
                            .ratio = ratio,
                        } };
                    }
                    output = allocator.realloc(output, new_size) catch {
                        allocator.free(output);
                        return .alloc_error;
                    };
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    // No more input but not at stream end
                    allocator.free(output);
                    return .data_error;
                }
            },
            c.Z_DATA_ERROR => {
                allocator.free(output);
                return .data_error;
            },
            c.Z_MEM_ERROR => {
                allocator.free(output);
                return .alloc_error;
            },
            else => {
                allocator.free(output);
                return .data_error;
            },
        }
    }
}

/// Decompress raw deflate data (no header), returning DecompressResult instead of an error union.
/// When output would exceed max_output_size, returns .exceeded_limit with compression ratio info.
/// Caller owns the slice in the .ok case and must free it with the same allocator.
pub fn inflateRawAllocWithRatio(allocator: Allocator, compressed: []const u8, max_output_size: usize) DecompressResult {
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
        return .data_error;
    }
    defer _ = c.inflateEnd(&stream);

    // Start with a reasonable buffer size, grow as needed
    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;

    var output = allocator.alloc(u8, output_size) catch return .alloc_error;

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
                return .{ .ok = output[0..final_size] };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
                // Need more output space
                if (stream.avail_out == 0) {
                    const new_size = output.len * 2;
                    if (new_size > max_output_size) {
                        const bytes_produced = stream.total_out;
                        const ratio = if (compressed.len > 0) bytes_produced / compressed.len else 0;
                        allocator.free(output);
                        return .{ .exceeded_limit = .{
                            .bytes_produced = bytes_produced,
                            .compressed_len = compressed.len,
                            .ratio = ratio,
                        } };
                    }
                    output = allocator.realloc(output, new_size) catch {
                        allocator.free(output);
                        return .alloc_error;
                    };
                    stream.next_out = output.ptr + stream.total_out;
                    stream.avail_out = @intCast(output.len - stream.total_out);
                } else if (stream.avail_in == 0) {
                    // No more input but not at stream end
                    allocator.free(output);
                    return .data_error;
                }
            },
            c.Z_DATA_ERROR => {
                allocator.free(output);
                return .data_error;
            },
            c.Z_MEM_ERROR => {
                allocator.free(output);
                return .alloc_error;
            },
            else => {
                allocator.free(output);
                return .data_error;
            },
        }
    }
}

/// Compress data to zlib format. Test helper — not optimized for production use.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn deflateZlib(allocator: Allocator, input: []const u8) (Allocator.Error || ZlibError)![]u8 {
    var stream: c.z_stream = .{
        .next_in = @constCast(input.ptr),
        .avail_in = @intCast(input.len),
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

    const init_ret = c.deflateInit(&stream, c.Z_DEFAULT_COMPRESSION);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.deflateEnd(&stream);

    // Upper bound on compressed size
    const bound: usize = @intCast(c.deflateBound(&stream, @intCast(input.len)));
    var output = try allocator.alloc(u8, bound);
    errdefer allocator.free(output);

    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    const ret = c.deflate(&stream, c.Z_FINISH);
    if (ret != c.Z_STREAM_END) {
        return ZlibError.ZlibError;
    }

    const final_size = stream.total_out;
    if (final_size < output.len) {
        output = allocator.realloc(output, final_size) catch output;
    }
    return output[0..final_size];
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

/// Validate zlib-compressed data by streaming decompression with fixed buffer.
/// Returns true if decompression completes successfully, false on data error.
/// Uses no heap allocation - only a fixed stack buffer for streaming.
/// This is ideal for integrity validation when you don't need the decompressed result.
pub fn validateZlib(compressed: []const u8) ZlibError!void {
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

    // Initialize for zlib format
    const init_ret = c.inflateInit(&stream);
    if (init_ret != c.Z_OK) {
        return ZlibError.InitFailed;
    }
    defer _ = c.inflateEnd(&stream);

    // Use heap buffer - decompress and discard
    const discard_buf = heap.validateAllocator().alloc(u8, 65536) catch {
        return ZlibError.OutOfMemory;
    };
    defer heap.validateAllocator().free(discard_buf);

    while (true) {
        stream.next_out = discard_buf.ptr;
        stream.avail_out = @intCast(discard_buf.len);

        const ret = c.inflate(&stream, c.Z_NO_FLUSH);

        switch (ret) {
            c.Z_STREAM_END => return, // Success - decompression complete
            c.Z_OK => {
                // Continue decompressing
                if (stream.avail_in == 0 and stream.avail_out > 0) {
                    // No more input but not at stream end
                    return ZlibError.UnexpectedEof;
                }
            },
            c.Z_BUF_ERROR => {
                // Need more input or output space
                if (stream.avail_in == 0) {
                    return ZlibError.UnexpectedEof;
                }
                // Output buffer full - just continue (we discard anyway)
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
}

/// Streaming inflate: validates compressed data without materializing the full output.
/// Uses a 64KB scratch buffer on the heap (bounded, not proportional to output size).
/// Returns the total decompressed size for caller-side size-matching checks.
/// If total exceeds max_uncompressed, returns DecompressedTooLarge.
/// Set raw=true for raw deflate (no zlib wrapper), false for zlib-framed.
pub fn inflateStreamValidate(compressed: []const u8, max_uncompressed: u64, raw: bool) !u64 {
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

    // raw deflate uses negative window bits; zlib-framed uses positive
    const init_ret = if (raw)
        c.inflateInit2(&stream, -15)
    else
        c.inflateInit2(&stream, 15);
    if (init_ret != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.inflateEnd(&stream);

    const discard_buf = heap.validateAllocator().alloc(u8, 65536) catch return ZlibError.OutOfMemory;
    defer heap.validateAllocator().free(discard_buf);

    var total: u64 = 0;
    while (true) {
        stream.next_out = discard_buf.ptr;
        stream.avail_out = @intCast(discard_buf.len);
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        const produced: u64 = @intCast(discard_buf.len - stream.avail_out);
        total += produced;
        if (total > max_uncompressed) return ZlibError.DecompressedTooLarge;

        switch (ret) {
            c.Z_STREAM_END => return total,
            c.Z_OK => {
                if (stream.avail_in == 0 and stream.avail_out > 0) return ZlibError.UnexpectedEof;
            },
            c.Z_BUF_ERROR => {
                if (stream.avail_in == 0) return ZlibError.UnexpectedEof;
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
}

/// Streaming inflate with per-chunk callback. Same as inflateStreamValidate but calls
/// the callback for each decompressed chunk — useful for feeding a hasher incrementally.
/// The callback must NOT retain references to the chunk buffer.
pub fn inflateStream(
    compressed: []const u8,
    max_uncompressed: u64,
    raw: bool,
    context: anytype,
    comptime callback: fn (ctx: @TypeOf(context), chunk: []const u8) void,
) !u64 {
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

    const init_ret = if (raw) c.inflateInit2(&stream, -15) else c.inflateInit2(&stream, 15);
    if (init_ret != c.Z_OK) return ZlibError.InitFailed;
    defer _ = c.inflateEnd(&stream);

    const chunk_buf = heap.validateAllocator().alloc(u8, 65536) catch return ZlibError.OutOfMemory;
    defer heap.validateAllocator().free(chunk_buf);

    var total: u64 = 0;
    while (true) {
        stream.next_out = chunk_buf.ptr;
        stream.avail_out = @intCast(chunk_buf.len);
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        const produced: u64 = @intCast(chunk_buf.len - stream.avail_out);
        if (produced > 0) {
            callback(context, chunk_buf[0..@intCast(produced)]);
            total += produced;
            if (total > max_uncompressed) return ZlibError.DecompressedTooLarge;
        }

        switch (ret) {
            c.Z_STREAM_END => return total,
            c.Z_OK => {
                if (stream.avail_in == 0 and stream.avail_out > 0) return ZlibError.UnexpectedEof;
            },
            c.Z_BUF_ERROR => {
                if (stream.avail_in == 0) return ZlibError.UnexpectedEof;
            },
            c.Z_DATA_ERROR => return ZlibError.DataError,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return ZlibError.ZlibError,
        }
    }
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

test "inflateZlibAllocWithRatio: ok case" {
    // Compress a small string, then decompress with a generous limit
    const allocator = std.testing.allocator;
    const input = "hello, world!";
    const compressed = try deflateZlib(allocator, input);
    defer allocator.free(compressed);

    const result = inflateZlibAllocWithRatio(allocator, compressed, 1024 * 1024);
    switch (result) {
        .ok => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(input, data);
        },
        else => {
            try std.testing.expect(false); // unexpected result
        },
    }
}

test "inflateZlibAllocWithRatio: exceeded_limit case" {
    // Compress 64KB of zeros (very high compression ratio), then decompress with tiny limit
    const allocator = std.testing.allocator;
    const input = [_]u8{0} ** (64 * 1024);
    const compressed = try deflateZlib(allocator, &input);
    defer allocator.free(compressed);

    // 256-byte output limit — will be exceeded immediately since input expands ~1000x
    const result = inflateZlibAllocWithRatio(allocator, compressed, 256);
    switch (result) {
        .exceeded_limit => |info| {
            try std.testing.expect(info.compressed_len > 0);
            try std.testing.expect(info.ratio > 1); // should be very high ratio
        },
        else => {
            try std.testing.expect(false); // expected exceeded_limit
        },
    }
}

test "inflateStreamValidate zlib format returns size" {
    // "hello" zlib-compressed
    const compressed = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15 };
    const size = try inflateStreamValidate(&compressed, 1024, false);
    try std.testing.expectEqual(@as(u64, 5), size);
}

test "inflateStreamValidate raw deflate returns size" {
    // "hello" raw deflate
    const compressed = [_]u8{ 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00 };
    const size = try inflateStreamValidate(&compressed, 1024, true);
    try std.testing.expectEqual(@as(u64, 5), size);
}

test "inflateStreamValidate enforces max_uncompressed" {
    // "hello" zlib-compressed (5 bytes output), limit to 3
    const compressed = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15 };
    try std.testing.expectError(ZlibError.DecompressedTooLarge, inflateStreamValidate(&compressed, 3, false));
}
