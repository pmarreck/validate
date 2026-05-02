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
    /// Decompression succeeded only via the Adobe-InDesign-style lenient
    /// path (zlib trailer was missing/truncated by <4 bytes; the deflate
    /// body itself terminated cleanly). Caller should emit a WARN-tier
    /// verdict — the file works in every reader but deviates from the
    /// zlib spec. Payload is identical shape to `.ok`.
    ok_lenient: []u8,
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


/// Decompress zlib-format data, with PDF-producer-quirk recovery.
///
/// Some PDF producers (notably Adobe InDesign) emit FlateDecode streams
/// whose deflate body is intact and properly terminated, but whose zlib
/// wrapper is missing the trailing 4-byte Adler-32 checksum. Strict zlib
/// decoders (this module's inflateZlibAllocWithRatio, qpdf's Pl_Flate when
/// not in stream-pipeline mode, etc.) report Z_BUF_ERROR / "incomplete or
/// truncated stream" on these. Every PDF reader (qpdf via its filtered
/// stream pipeline, Preview, Acrobat, browsers, mutool) tolerates them.
///
/// Algorithm:
///   1. Try strict zlib decompression. If it succeeds, return that output.
///   2. On data_error, validate the zlib header (CMF byte's low nibble == 8
///      for deflate AND (CMF*256 + FLG) % 31 == 0 for FCHECK). If the
///      header is malformed, return data_error — this is real corruption.
///   3. Retry as raw deflate on compressed[2..] (skipping the validated
///      zlib header). If the deflate body is properly terminated, this
///      succeeds and we recover the same bytes the PDF reader would render.
///   4. If raw deflate also fails, the data is genuinely corrupt — return
///      data_error.
///
/// This is strictly more permissive than inflateZlibAllocWithRatio for one
/// well-defined class of producer output; it does NOT accept arbitrary
/// garbage because raw deflate still requires a valid Huffman-coded body
/// terminated by a BFINAL block. exceeded_limit / alloc_error semantics
/// are identical to the strict version.
pub fn inflateZlibLenientAllocWithRatio(
    allocator: Allocator,
    compressed: []const u8,
    max_output_size: usize,
) DecompressResult {
    // Fast path: strict zlib succeeds for well-formed streams.
    // Fast path: strict zlib succeeds for well-formed streams.
    switch (inflateZlibAllocWithRatio(allocator, compressed, max_output_size)) {
        .ok => |data| return .{ .ok = data },
        .ok_lenient => |data| return .{ .ok_lenient = data }, // strict shouldn't return this, but cover for completeness
        .exceeded_limit => |info| return .{ .exceeded_limit = info },
        .alloc_error => return .alloc_error,
        .data_error => {}, // Fall through to recovery
    }

    // Recovery path: only attempt if the input has a syntactically valid
    // zlib header. CMF byte's low 4 bits = compression method (8 = deflate).
    // (CMF * 256 + FLG) must be divisible by 31 (FCHECK).
    if (compressed.len < 4) return .data_error;
    const cmf = compressed[0];
    const flg = compressed[1];
    if ((cmf & 0x0f) != 8) return .data_error;
    const cmf_flg: u32 = (@as(u32, cmf) << 8) | @as(u32, flg);
    if (cmf_flg % 31 != 0) return .data_error;
    // PDFs using a preset dictionary (FDICT bit set) are vanishingly rare
    // and we can't supply the dictionary anyway — bail.
    if ((flg & 0x20) != 0) return .data_error;

    // Body looks like a syntactically valid zlib stream. Try raw deflate
    // on the body, but ALSO require that <4 bytes are left over after
    // Z_STREAM_END. If 4+ leftover bytes are present, those are the
    // Adler-32 trailer — its presence means the stream WAS supposed to be
    // self-checking and strict zlib's failure was likely an Adler-32
    // mismatch (i.e., real mid-body corruption that the deflate Huffman
    // decoder happened to parse through). Treat that as data_error to
    // preserve corruption-detection power. <4 leftover means the trailer
    // is genuinely missing — the Adobe-InDesign quirk we want to recover.
    return inflateRawWithLeftoverCheck(allocator, compressed[2..], max_output_size);
}

/// Raw-deflate decompression that succeeds only when the stream terminates
/// cleanly AND fewer than 4 trailing bytes remain after Z_STREAM_END. Used
/// by inflateZlibLenientAllocWithRatio to distinguish missing-Adler-32
/// (recoverable producer quirk) from present-but-mismatched-Adler-32 (real
/// mid-body corruption that we shouldn't silently accept).
fn inflateRawWithLeftoverCheck(allocator: Allocator, compressed: []const u8, max_output_size: usize) DecompressResult {
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
    const init_ret = c.inflateInit2(&stream, -15);
    if (init_ret != c.Z_OK) return .data_error;
    defer _ = c.inflateEnd(&stream);

    var output_size: usize = @min(compressed.len * 4, max_output_size);
    if (output_size < 4096) output_size = 4096;
    var output = allocator.alloc(u8, output_size) catch return .alloc_error;
    stream.next_out = output.ptr;
    stream.avail_out = @intCast(output.len);

    while (true) {
        const ret = c.inflate(&stream, c.Z_NO_FLUSH);
        switch (ret) {
            c.Z_STREAM_END => {
                // Require <4 leftover bytes — see inflateZlibLenientAllocWithRatio.
                if (stream.avail_in >= 4) {
                    allocator.free(output);
                    return .data_error;
                }
                const final_size = stream.total_out;
                if (final_size < output.len) {
                    output = allocator.realloc(output, final_size) catch output;
                }
                // The lenient recovery path successfully completed — return
                // ok_lenient so the caller can emit WARN. We only get here
                // after strict zlib failed; this is the Adobe-InDesign-style
                // recovery, not a regular success.
                return .{ .ok_lenient = output[0..final_size] };
            },
            c.Z_OK, c.Z_BUF_ERROR => {
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


/// Streaming inflate validator with PDF-producer-quirk recovery.
///
/// Same contract as inflateStreamValidate (returns total decompressed size,
/// rejects bombs via max_uncompressed) but tolerates the Adobe-InDesign
/// missing-Adler-32 quirk: if strict zlib decoding fails AND the input has
/// a syntactically valid zlib header AND the deflate body terminates with
/// fewer than 4 trailing bytes (i.e. no full Adler-32 trailer), accepts.
/// The leftover-bytes check distinguishes "Adler-32 missing" (recoverable
/// producer quirk) from "Adler-32 present but mismatched" (real mid-body
/// corruption that we shouldn't silently swallow).
///
/// Use this for PDF FlateDecode streams where reader tolerance is the
/// relevant correctness bar; use the strict version for integrity checks
/// where the trailer is contractual (ZIP entries, gzip, git objects).
///
/// Only applies to zlib-framed input (raw=false). raw=true delegates
/// directly to inflateStreamValidate since there is no header to strip.
pub fn inflateStreamValidateLenient(
    compressed: []const u8,
    max_uncompressed: u64,
    raw: bool,
    /// Optional out-param: set to true if the lenient recovery path was
    /// taken (zlib trailer was missing/truncated by <4 bytes; deflate body
    /// itself terminated cleanly). Caller should emit a WARN verdict in
    /// that case. Pass null to ignore.
    lenient_recovery: ?*bool,
) !u64 {
    if (lenient_recovery) |p| p.* = false;
    if (raw) return inflateStreamValidate(compressed, max_uncompressed, raw);

    if (inflateStreamValidate(compressed, max_uncompressed, false)) |total| {
        return total;
    } else |err| switch (err) {
        ZlibError.UnexpectedEof, ZlibError.DataError => {
            // Possible Adobe-truncated-trailer quirk. Validate the zlib
            // header before attempting raw recovery.
            if (compressed.len < 4) return err;
            const cmf = compressed[0];
            const flg = compressed[1];
            if ((cmf & 0x0f) != 8) return err;
            const cmf_flg: u32 = (@as(u32, cmf) << 8) | @as(u32, flg);
            if (cmf_flg % 31 != 0) return err;
            if ((flg & 0x20) != 0) return err; // FDICT — can't supply preset
            // Retry as raw deflate, requiring <4 leftover bytes.
            const recovered = try rawStreamValidateWithLeftoverCheck(compressed[2..], max_uncompressed, err);
            if (lenient_recovery) |p| p.* = true;
            return recovered;
        },
        else => return err,
    }
}

/// Streaming raw-deflate validator that succeeds only when fewer than 4
/// trailing bytes remain after Z_STREAM_END. See rationale in
/// inflateZlibLenientAllocWithRatio. On any failure (including >=4 leftover
/// bytes which signals a present-but-mismatched Adler-32), returns the
/// caller's original error so the call site sees the same diagnostic class
/// as the strict path.
fn rawStreamValidateWithLeftoverCheck(compressed: []const u8, max_uncompressed: u64, original_err: anyerror) !u64 {
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
    if (c.inflateInit2(&stream, -15) != c.Z_OK) return ZlibError.InitFailed;
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
            c.Z_STREAM_END => {
                // Strict: require <4 leftover bytes after stream end.
                if (stream.avail_in >= 4) return original_err;
                return total;
            },
            c.Z_OK => {
                if (stream.avail_in == 0 and stream.avail_out > 0) return original_err;
            },
            c.Z_BUF_ERROR => {
                if (stream.avail_in == 0) return original_err;
            },
            c.Z_DATA_ERROR => return original_err,
            c.Z_MEM_ERROR => return ZlibError.OutOfMemory,
            else => return original_err,
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

test "inflateZlibLenientAllocWithRatio: well-formed stream still works" {
    const allocator = std.testing.allocator;
    const input = "hello, world!";
    const compressed = try deflateZlib(allocator, input);
    defer allocator.free(compressed);

    const result = inflateZlibLenientAllocWithRatio(allocator, compressed, 1024 * 1024);
    switch (result) {
        .ok => |data| {
            defer allocator.free(data);
            try std.testing.expectEqualStrings(input, data);
        },
        else => try std.testing.expect(false),
    }
}

test "inflateZlibLenientAllocWithRatio: rejects garbage with valid-looking header" {
    const allocator = std.testing.allocator;
    // 0x78 0x9c is a valid zlib header but the body is random — neither
    // strict zlib nor raw deflate will parse this as a valid Huffman stream.
    var garbage: [50]u8 = undefined;
    garbage[0] = 0x78;
    garbage[1] = 0x9c;
    for (garbage[2..], 0..) |*b, i| {
        b.* = @intCast((i * 73 + 41) & 0xff);
    }
    const result = inflateZlibLenientAllocWithRatio(allocator, &garbage, 1024 * 1024);
    try std.testing.expect(result == .data_error);
}

test "inflateZlibLenientAllocWithRatio: recovers from missing Adler-32 trailer" {
    // Adobe-InDesign-style stream: valid deflate body, valid zlib header,
    // missing 4-byte Adler-32 checksum. Captured from object 6012 of
    // IT-Salary-Guide-2024-Job-Trends.pdf.
    const compressed = [_]u8{
        0x48, 0x4b, 0xec, 0xcf, 0xc9, 0x0d, 0x82, 0x40, 0x00, 0x00, 0x40, 0x04,
        0x84, 0x05, 0x2f, 0xf0, 0xbe, 0xe8, 0xbf, 0x4d, 0xc3, 0x66, 0x89, 0x1a,
        0xf9, 0xf9, 0x9d, 0xe9, 0x60, 0x86, 0x61, 0xc6, 0x33, 0x79, 0xfc, 0xb8,
        0x27, 0xb7, 0xe8, 0xfa, 0x76, 0x99, 0x9c, 0x93, 0xd3, 0x87, 0x63, 0x72,
        0x98, 0xec, 0x93, 0xbe, 0xef, 0xbb, 0xae, 0xdb, 0x7d, 0xd9, 0x46, 0x9b,
        0x68, 0x3d, 0x5a, 0x45, 0x6d, 0xdb, 0x36, 0x4d, 0x13, 0x42, 0xa8, 0xeb,
        0x3a, 0x24, 0x55, 0x55, 0x2d, 0xa3, 0xa2, 0x28, 0xca, 0x32, 0xcf, 0xf3,
        0x2c, 0xcb, 0x16, 0xd1, 0xdc, 0x4a, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0xeb, 0xff, 0xd6, 0x0b, 0x00, 0x00,
        0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0x03, 0x00, 0xc4,
    };
    const allocator = std.testing.allocator;
    const result = inflateZlibLenientAllocWithRatio(allocator, &compressed, 16 * 1024 * 1024);
    switch (result) {
        .ok_lenient => |data| {
            defer allocator.free(data);
            try std.testing.expect(data.len > 1024); // qpdf gets exactly 16555
        },
        else => try std.testing.expect(false),
    }
}

test "inflateStreamValidateLenient: recovers from missing Adler-32 trailer" {
    const compressed = [_]u8{
        0x48, 0x4b, 0xec, 0xcf, 0xc9, 0x0d, 0x82, 0x40, 0x00, 0x00, 0x40, 0x04,
        0x84, 0x05, 0x2f, 0xf0, 0xbe, 0xe8, 0xbf, 0x4d, 0xc3, 0x66, 0x89, 0x1a,
        0xf9, 0xf9, 0x9d, 0xe9, 0x60, 0x86, 0x61, 0xc6, 0x33, 0x79, 0xfc, 0xb8,
        0x27, 0xb7, 0xe8, 0xfa, 0x76, 0x99, 0x9c, 0x93, 0xd3, 0x87, 0x63, 0x72,
        0x98, 0xec, 0x93, 0xbe, 0xef, 0xbb, 0xae, 0xdb, 0x7d, 0xd9, 0x46, 0x9b,
        0x68, 0x3d, 0x5a, 0x45, 0x6d, 0xdb, 0x36, 0x4d, 0x13, 0x42, 0xa8, 0xeb,
        0x3a, 0x24, 0x55, 0x55, 0x2d, 0xa3, 0xa2, 0x28, 0xca, 0x32, 0xcf, 0xf3,
        0x2c, 0xcb, 0x16, 0xd1, 0xdc, 0x4a, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b,
        0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0x4b, 0xeb, 0xff, 0xd6, 0x0b, 0x00, 0x00,
        0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0x03, 0x00, 0xc4,
    };
    const size = try inflateStreamValidateLenient(&compressed, 16 * 1024 * 1024, false, null);
    try std.testing.expect(size > 1024);
}

test "inflateStreamValidateLenient: well-formed stream returns same size as strict" {
    // "hello" zlib-compressed (full Adler-32)
    const compressed = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15 };
    const size = try inflateStreamValidateLenient(&compressed, 1024, false, null);
    try std.testing.expectEqual(@as(u64, 5), size);
}

test "inflateStreamValidateLenient: rejects mid-body corruption with full Adler-32" {
    // Take a well-formed zlib stream, flip a byte mid-body. Strict zlib
    // catches it via Adler-32 mismatch. The lenient path's leftover-bytes
    // check ensures we don't silently swallow this just because raw deflate
    // happened to parse through — the 4 trailing bytes are a present (but
    // mismatched) Adler-32, so we reject.
    const allocator = std.testing.allocator;
    const payload = "The quick brown fox jumps over the lazy dog. " ** 20;
    const compressed_orig = try deflateZlib(allocator, payload);
    defer allocator.free(compressed_orig);
    var corrupted = try allocator.dupe(u8, compressed_orig);
    defer allocator.free(corrupted);
    // Flip a byte well inside the body so the full Adler-32 trailer survives.
    corrupted[corrupted.len / 2] ^= 0xff;
    try std.testing.expectError(ZlibError.DataError, inflateStreamValidateLenient(corrupted, 16 * 1024 * 1024, false, null));
}

test "inflateZlibLenientAllocWithRatio: rejects mid-body corruption with full Adler-32" {
    const allocator = std.testing.allocator;
    const payload = "The quick brown fox jumps over the lazy dog. " ** 20;
    const compressed_orig = try deflateZlib(allocator, payload);
    defer allocator.free(compressed_orig);
    var corrupted = try allocator.dupe(u8, compressed_orig);
    defer allocator.free(corrupted);
    corrupted[corrupted.len / 2] ^= 0xff;
    const result = inflateZlibLenientAllocWithRatio(allocator, corrupted, 16 * 1024 * 1024);
    try std.testing.expect(result == .data_error);
}
