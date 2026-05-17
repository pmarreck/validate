//! JPEG2000 image decode validation using OpenJPEG
//!
//! This module provides full decode validation for JPEG2000 images by
//! decoding through OpenJPEG (libopenjp2). JPEG2000 is commonly found in:
//! - PDF documents (JPXDecode filter)
//! - Digital Cinema Packages (DCPs)
//! - Medical imaging (DICOM)
//! - Geospatial imagery (GeoJP2)
//!
//! Supports both raw codestream (.j2k/.j2c) and JP2 container (.jp2) formats.

const std = @import("std");
const runtime = @import("runtime.zig");
const errmsg = @import("error_messages.zig");

/// OpenJPEG C API bindings
const opj = @cImport({
    @cInclude("openjpeg.h");
});

/// Result of JPEG2000 decode validation
pub const Jpeg2000DecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    width: u32,
    height: u32,
    num_components: u32,
    bit_depth: u32,

    pub fn success(w: u32, h: u32, components: u32, bits: u32) Jpeg2000DecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .width = w,
            .height = h,
            .num_components = components,
            .bit_depth = bits,
        };
    }

    pub fn failure(msg: []const u8) Jpeg2000DecodeResult {
        return .{
            .valid = false,
            .error_message = msg,
            .width = 0,
            .height = 0,
            .num_components = 0,
            .bit_depth = 0,
        };
    }
};

/// JPEG2000 codec type
pub const Jpeg2000CodecType = enum {
    j2k, // Raw codestream (.j2k, .j2c)
    jp2, // JP2 container (.jp2)
};

/// Memory stream context for OpenJPEG
const MemoryStream = struct {
    data: []const u8,
    position: usize,
};

/// Read callback for memory stream
fn memoryStreamRead(p_buffer: ?*anyopaque, p_nb_bytes: opj.OPJ_SIZE_T, p_user_data: ?*anyopaque) callconv(.c) opj.OPJ_SIZE_T {
    const ctx = @as(*MemoryStream, @ptrCast(@alignCast(p_user_data orelse return 0)));
    const buffer = @as([*]u8, @ptrCast(p_buffer orelse return 0));

    const remaining = ctx.data.len - ctx.position;
    const to_read = @min(p_nb_bytes, remaining);

    if (to_read == 0) {
        return @as(opj.OPJ_SIZE_T, @bitCast(@as(isize, -1))); // EOF
    }

    @memcpy(buffer[0..to_read], ctx.data[ctx.position..][0..to_read]);
    ctx.position += to_read;

    return to_read;
}

/// Skip callback for memory stream
fn memoryStreamSkip(p_nb_bytes: opj.OPJ_OFF_T, p_user_data: ?*anyopaque) callconv(.c) opj.OPJ_OFF_T {
    const ctx = @as(*MemoryStream, @ptrCast(@alignCast(p_user_data orelse return -1)));

    if (p_nb_bytes < 0) {
        // Negative skip - go backwards
        const back = @as(usize, @intCast(-p_nb_bytes));
        if (back > ctx.position) {
            ctx.position = 0;
        } else {
            ctx.position -= back;
        }
    } else {
        const skip = @as(usize, @intCast(p_nb_bytes));
        const new_pos = ctx.position + skip;
        if (new_pos > ctx.data.len) {
            ctx.position = ctx.data.len;
        } else {
            ctx.position = new_pos;
        }
    }

    return p_nb_bytes;
}

/// Seek callback for memory stream
fn memoryStreamSeek(p_nb_bytes: opj.OPJ_OFF_T, p_user_data: ?*anyopaque) callconv(.c) opj.OPJ_BOOL {
    const ctx = @as(*MemoryStream, @ptrCast(@alignCast(p_user_data orelse return opj.OPJ_FALSE)));

    if (p_nb_bytes < 0) {
        return opj.OPJ_FALSE;
    }

    const pos = @as(usize, @intCast(p_nb_bytes));
    if (pos > ctx.data.len) {
        return opj.OPJ_FALSE;
    }

    ctx.position = pos;
    return opj.OPJ_TRUE;
}

/// Detect JPEG2000 codec type from data
pub fn detectCodecType(data: []const u8) ?Jpeg2000CodecType {
    if (data.len < 2) return null;

    // JP2 container: starts with JP2 signature box
    // 0000 000C 6A50 2020 0D0A 870A (12 bytes)
    if (data.len >= 12 and
        data[0] == 0x00 and data[1] == 0x00 and data[2] == 0x00 and data[3] == 0x0C and
        data[4] == 0x6A and data[5] == 0x50 and data[6] == 0x20 and data[7] == 0x20 and
        data[8] == 0x0D and data[9] == 0x0A and data[10] == 0x87 and data[11] == 0x0A)
    {
        return .jp2;
    }

    // Raw J2K codestream: starts with SOC marker (FF 4F)
    if (data[0] == 0xFF and data[1] == 0x4F) {
        return .j2k;
    }

    return null;
}

/// Validate JPEG2000 image data by full decode
pub fn validateJpeg2000(data: []const u8) Jpeg2000DecodeResult {
    // Detect codec type
    const codec_type = detectCodecType(data) orelse {
        return Jpeg2000DecodeResult.failure("Not a valid JPEG2000 file");
    };

    // Create decoder
    const opj_codec_type: c_int = switch (codec_type) {
        .j2k => opj.OPJ_CODEC_J2K,
        .jp2 => opj.OPJ_CODEC_JP2,
    };

    const codec = opj.opj_create_decompress(opj_codec_type);
    if (codec == null) {
        return Jpeg2000DecodeResult.failure("Failed to create JPEG2000 decoder");
    }
    defer opj.opj_destroy_codec(codec);

    // Setup decoder with default parameters
    var params: opj.opj_dparameters_t = undefined;
    opj.opj_set_default_decoder_parameters(&params);

    if (opj.opj_setup_decoder(codec, &params) == opj.OPJ_FALSE) {
        return Jpeg2000DecodeResult.failure("Failed to setup JPEG2000 decoder");
    }

    // Create memory stream
    var stream_ctx = MemoryStream{
        .data = data,
        .position = 0,
    };

    const stream = opj.opj_stream_create(data.len, opj.OPJ_TRUE);
    if (stream == null) {
        return Jpeg2000DecodeResult.failure("Failed to create input stream");
    }
    defer opj.opj_stream_destroy(stream);

    opj.opj_stream_set_read_function(stream, memoryStreamRead);
    opj.opj_stream_set_skip_function(stream, memoryStreamSkip);
    opj.opj_stream_set_seek_function(stream, memoryStreamSeek);
    opj.opj_stream_set_user_data(stream, &stream_ctx, null);
    opj.opj_stream_set_user_data_length(stream, data.len);

    // Read header
    var image: ?*opj.opj_image_t = null;
    if (opj.opj_read_header(stream, codec, &image) == opj.OPJ_FALSE) {
        return Jpeg2000DecodeResult.failure(errmsg.failedToRead("JPEG2000 header"));
    }
    defer if (image) |img| opj.opj_image_destroy(img);

    const img = image orelse {
        return Jpeg2000DecodeResult.failure("No image data in JPEG2000 file");
    };

    // Full decode
    if (opj.opj_decode(codec, stream, img) == opj.OPJ_FALSE) {
        return Jpeg2000DecodeResult.failure("Failed to decode JPEG2000 image");
    }

    if (opj.opj_end_decompress(codec, stream) == opj.OPJ_FALSE) {
        return Jpeg2000DecodeResult.failure("Failed to end JPEG2000 decompression");
    }

    // Extract image info
    const width = @as(u32, @intCast(img.x1 - img.x0));
    const height = @as(u32, @intCast(img.y1 - img.y0));
    const num_comps = img.numcomps;

    // Get bit depth from first component
    var bit_depth: u32 = 0;
    if (num_comps > 0 and img.comps != null) {
        bit_depth = img.comps[0].prec;
    }

    return Jpeg2000DecodeResult.success(width, height, num_comps, bit_depth);
}

/// Check if data appears to be JPEG2000
pub fn isJpeg2000(data: []const u8) bool {
    return detectCodecType(data) != null;
}

// ============ Tests ============

test "detectCodecType JP2 signature" {
    // JP2 signature box
    const jp2_sig = [_]u8{
        0x00, 0x00, 0x00, 0x0C, // Box length
        0x6A, 0x50, 0x20, 0x20, // JP2 signature
        0x0D, 0x0A, 0x87, 0x0A, // Signature continuation
    };

    try std.testing.expectEqual(Jpeg2000CodecType.jp2, detectCodecType(&jp2_sig).?);
}

test "detectCodecType J2K codestream" {
    // SOC marker
    const j2k_sig = [_]u8{ 0xFF, 0x4F, 0xFF, 0x51 }; // SOC + SIZ marker

    try std.testing.expectEqual(Jpeg2000CodecType.j2k, detectCodecType(&j2k_sig).?);
}

test "detectCodecType invalid data" {
    const invalid = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    try std.testing.expect(detectCodecType(&invalid) == null);
}

test "isJpeg2000 detection" {
    const jp2_sig = [_]u8{
        0x00, 0x00, 0x00, 0x0C,
        0x6A, 0x50, 0x20, 0x20,
        0x0D, 0x0A, 0x87, 0x0A,
    };
    const j2k_sig = [_]u8{ 0xFF, 0x4F };
    const not_jp2 = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 }; // JPEG

    try std.testing.expect(isJpeg2000(&jp2_sig));
    try std.testing.expect(isJpeg2000(&j2k_sig));
    try std.testing.expect(!isJpeg2000(&not_jp2));
}

test "validateJpeg2000 on real JP2 container file" {
    const allocator = std.testing.allocator;

    // Ground truth JP2 file (public domain balloon image)
    const file = runtime.openFile("ground_truth_examples/jpeg2k/balloon.jp2", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer file.close(runtime.io());

    const __sz_data = file.length(runtime.io()) catch return;
    if (__sz_data > 10 * 1024 * 1024) return;
    const data = allocator.alloc(u8, @intCast(__sz_data)) catch return;
    _ = file.readPositionalAll(runtime.io(), data, 0) catch return;
    defer allocator.free(data);

    // Verify detection works
    const codec_type = detectCodecType(data);
    try std.testing.expect(codec_type != null);
    try std.testing.expectEqual(Jpeg2000CodecType.jp2, codec_type.?);

    // Verify full decode validation works
    const result = validateJpeg2000(data);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}

test "validateJpeg2000 on real J2K codestream file" {
    const allocator = std.testing.allocator;

    // Ground truth J2K codestream file (public domain balloon image)
    const file = runtime.openFile("ground_truth_examples/jpeg2k/balloon.j2c", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer file.close(runtime.io());

    const __sz_data = file.length(runtime.io()) catch return;
    if (__sz_data > 10 * 1024 * 1024) return;
    const data = allocator.alloc(u8, @intCast(__sz_data)) catch return;
    _ = file.readPositionalAll(runtime.io(), data, 0) catch return;
    defer allocator.free(data);

    // Verify detection works
    const codec_type = detectCodecType(data);
    try std.testing.expect(codec_type != null);
    try std.testing.expectEqual(Jpeg2000CodecType.j2k, codec_type.?);

    // Verify full decode validation works
    const result = validateJpeg2000(data);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.width > 0);
    try std.testing.expect(result.height > 0);
}
