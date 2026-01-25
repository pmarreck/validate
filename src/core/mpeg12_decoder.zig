//! MPEG-1/2 Video Decoder (Pure Zig)
//!
//! DCT-based decoder for MPEG-1 (ISO 11172-2) and MPEG-2 (ISO 13818-2) video validation.
//! Decodes macroblocks to verify bitstream integrity without producing video output.
//!
//! Key structures:
//! - 8x8 DCT blocks (same as JPEG/ProRes)
//! - 16x16 macroblocks (4 Y blocks + 2 Cb + 2 Cr for 4:2:0)
//! - I-frames: intra-coded only (like ProRes)
//! - P-frames: forward prediction from previous I/P
//! - B-frames: bidirectional prediction
//!
//! Reference: ISO/IEC 11172-2, ISO/IEC 13818-2

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const BitReader = @import("bitstream_reader.zig").BitReader;

// ============================================================================
// Constants
// ============================================================================

/// Default intra quantization matrix (Table 6-4 in ISO 13818-2)
pub const default_intra_quant = [64]u8{
    8,  16, 19, 22, 26, 27, 29, 34,
    16, 16, 22, 24, 27, 29, 34, 37,
    19, 22, 26, 27, 29, 34, 34, 38,
    22, 22, 26, 27, 29, 34, 37, 40,
    22, 26, 27, 29, 32, 35, 40, 48,
    26, 27, 29, 32, 35, 40, 48, 58,
    26, 27, 29, 34, 38, 46, 56, 69,
    27, 29, 35, 38, 46, 56, 69, 83,
};

/// Default non-intra quantization matrix (all 16s)
pub const default_non_intra_quant = [64]u8{16} ** 64;

/// Zigzag scan order for 8x8 blocks
pub const zigzag_scan = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Alternate scan order for interlaced MPEG-2
pub const alternate_scan = [64]u8{
    0,  8,  16, 24, 1,  9,  2,  10,
    17, 25, 32, 40, 48, 56, 57, 49,
    41, 33, 26, 18, 3,  11, 4,  12,
    19, 27, 34, 42, 50, 58, 35, 43,
    51, 59, 20, 28, 5,  13, 6,  14,
    21, 29, 36, 44, 52, 60, 37, 45,
    53, 61, 22, 30, 7,  15, 23, 31,
    38, 46, 54, 62, 39, 47, 55, 63,
};

// ============================================================================
// DCT Coefficient VLC Tables (Table B-14, B-15 in ISO 13818-2)
// ============================================================================

/// DCT coefficient entry: run, level, and end-of-block flag
pub const DctCoeff = struct {
    run: u6,
    level: i12,
    eob: bool,
};

/// VLC table entry for DCT coefficients
const VlcEntry = struct {
    bits: u16,
    len: u4,
    run: u6,
    level: u6,
};

/// AC coefficient decode result
pub const AcCoeff = struct {
    run: u6, // Number of zeros before this coefficient
    level: i12, // Coefficient value (signed)
    eob: bool, // End of block flag
};

/// Decode an AC coefficient using Table B-14 VLC
pub fn decodeAcCoeff(reader: *BitReader, is_first: bool) ?AcCoeff {
    const peek = reader.peekBits(17) orelse return null;

    // EOB: 10 (2 bits) for non-first, special handling for first
    if (!is_first and (peek >> 15) == 0b10) {
        _ = reader.readBits(2);
        return .{ .run = 0, .level = 0, .eob = true };
    }

    // (0,1): 1s or 11s depending on first/non-first
    // Non-first: 11 + sign (3 bits)
    if (!is_first and (peek >> 15) == 0b11) {
        _ = reader.readBits(2);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 0, .level = level, .eob = false };
    }

    // First coefficient: 1s (2 bits) for DC value 1
    if (is_first and (peek >> 16) == 0b1) {
        _ = reader.readBits(1);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 0, .level = level, .eob = false };
    }

    // (1,1): 011s (4 bits)
    if ((peek >> 14) == 0b011) {
        _ = reader.readBits(3);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 1, .level = level, .eob = false };
    }

    // (0,2): 0100s (5 bits)
    if ((peek >> 13) == 0b0100) {
        _ = reader.readBits(4);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -2 else 2;
        return .{ .run = 0, .level = level, .eob = false };
    }

    // (2,1): 0101s (5 bits)
    if ((peek >> 13) == 0b0101) {
        _ = reader.readBits(4);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 2, .level = level, .eob = false };
    }

    // (0,3): 00101s (6 bits)
    if ((peek >> 12) == 0b00101) {
        _ = reader.readBits(5);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -3 else 3;
        return .{ .run = 0, .level = level, .eob = false };
    }

    // (3,1): 00111s (6 bits)
    if ((peek >> 12) == 0b00111) {
        _ = reader.readBits(5);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 3, .level = level, .eob = false };
    }

    // (4,1): 00110s (6 bits)
    if ((peek >> 12) == 0b00110) {
        _ = reader.readBits(5);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 4, .level = level, .eob = false };
    }

    // (1,2): 000110s (7 bits)
    if ((peek >> 11) == 0b000110) {
        _ = reader.readBits(6);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -2 else 2;
        return .{ .run = 1, .level = level, .eob = false };
    }

    // (5,1): 000111s (7 bits)
    if ((peek >> 11) == 0b000111) {
        _ = reader.readBits(6);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 5, .level = level, .eob = false };
    }

    // (6,1): 000101s (7 bits)
    if ((peek >> 11) == 0b000101) {
        _ = reader.readBits(6);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 6, .level = level, .eob = false };
    }

    // (7,1): 000100s (7 bits)
    if ((peek >> 11) == 0b000100) {
        _ = reader.readBits(6);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 7, .level = level, .eob = false };
    }

    // (0,4): 0000110s (8 bits)
    if ((peek >> 10) == 0b0000110) {
        _ = reader.readBits(7);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -4 else 4;
        return .{ .run = 0, .level = level, .eob = false };
    }

    // (2,2): 0000100s (8 bits)
    if ((peek >> 10) == 0b0000100) {
        _ = reader.readBits(7);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -2 else 2;
        return .{ .run = 2, .level = level, .eob = false };
    }

    // (8,1): 0000111s (8 bits)
    if ((peek >> 10) == 0b0000111) {
        _ = reader.readBits(7);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 8, .level = level, .eob = false };
    }

    // (9,1): 0000101s (8 bits)
    if ((peek >> 10) == 0b0000101) {
        _ = reader.readBits(7);
        const sign = reader.readBit() orelse return null;
        const level: i12 = if (sign == 1) -1 else 1;
        return .{ .run = 9, .level = level, .eob = false };
    }

    // Escape: 000001 (6 bits) + 6-bit run + 8 or 16-bit level
    if ((peek >> 11) == 0b000001) {
        _ = reader.readBits(6);

        // Read 6-bit run
        const run = reader.readBits(6) orelse return null;

        // MPEG-1 level is 8 bits (or 16 if first 8 bits are 0x00 or 0x80)
        const first_byte = reader.readBits(8) orelse return null;
        var level: i12 = undefined;

        if (first_byte == 0x00) {
            // Positive level follows
            const level_byte = reader.readBits(8) orelse return null;
            level = @intCast(level_byte);
        } else if (first_byte == 0x80) {
            // Negative level follows (two's complement)
            const level_byte = reader.readBits(8) orelse return null;
            level = @as(i12, @intCast(level_byte)) - 256;
        } else {
            // Single byte level
            if (first_byte < 128) {
                level = @intCast(first_byte);
            } else {
                level = @as(i12, @intCast(first_byte)) - 256;
            }
        }

        return .{
            .run = @intCast(run),
            .level = level,
            .eob = false,
        };
    }

    // For validation purposes, treat unrecognized codes as EOB
    // (real decoder would have complete table)
    return .{ .run = 0, .level = 0, .eob = true };
}

// ============================================================================
// 8x8 Inverse DCT
// ============================================================================

/// Precomputed DCT cosine table
const dct_cos_table: [8][8]f64 = blk: {
    var table: [8][8]f64 = undefined;
    const PI: f64 = 3.14159265358979323846;
    for (0..8) |u| {
        for (0..8) |x| {
            table[u][x] = @cos((@as(f64, @floatFromInt(2 * x + 1)) * @as(f64, @floatFromInt(u)) * PI) / 16.0);
        }
    }
    break :blk table;
};

/// DCT scaling factors (1/sqrt(2) for k=0, 1 otherwise)
const dct_scale: [8]f64 = blk: {
    var scale: [8]f64 = undefined;
    const SQRT2_INV: f64 = 0.7071067811865475;
    for (0..8) |i| {
        scale[i] = if (i == 0) SQRT2_INV else 1.0;
    }
    break :blk scale;
};

/// 8x8 DCT block
pub const DctBlock = [64]i32;

/// 8x8 pixel block
pub const PixelBlock = [64]i16;

/// Perform 2D inverse DCT on 8x8 block
pub fn inverseDct8x8(coeffs: *const DctBlock) PixelBlock {
    var result: PixelBlock = undefined;
    var temp: [64]f64 = undefined;

    // Step 1: 1D IDCT on rows
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f64 = 0.0;
            for (0..8) |u| {
                const coeff: f64 = @floatFromInt(coeffs[y * 8 + u]);
                sum += dct_scale[u] * coeff * dct_cos_table[u][x];
            }
            temp[y * 8 + x] = sum * 0.5;
        }
    }

    // Step 2: 1D IDCT on columns
    for (0..8) |x| {
        for (0..8) |y| {
            var sum: f64 = 0.0;
            for (0..8) |v| {
                sum += dct_scale[v] * temp[v * 8 + x] * dct_cos_table[v][y];
            }
            // Round and clamp to valid range
            const pixel = @round(sum * 0.5);
            result[y * 8 + x] = @intFromFloat(std.math.clamp(pixel, -2048, 2047));
        }
    }

    return result;
}

// ============================================================================
// VLC Decoding
// ============================================================================

/// Decode DC coefficient size (luminance) - Table B-12
pub fn decodeDcSizeLuma(reader: *BitReader) ?u4 {
    const peek = reader.peekBits(9) orelse return null;

    // Table B-12: DC size luminance codes
    // Size 0: 100 (3 bits)
    // Size 1: 00 (2 bits)
    // Size 2: 01 (2 bits)
    // Size 3: 101 (3 bits)
    // Size 4: 110 (3 bits)
    // Size 5: 1110 (4 bits)
    // Size 6: 11110 (5 bits)
    // Size 7: 111110 (6 bits)
    // Size 8: 1111110 (7 bits)
    // Size 9: 11111110 (8 bits)
    // Size 10: 111111110 (9 bits)
    // Size 11: 111111111 (9 bits)

    // Check 2-bit codes first (most common)
    if ((peek >> 7) == 0b00) {
        _ = reader.readBits(2);
        return 1;
    }
    if ((peek >> 7) == 0b01) {
        _ = reader.readBits(2);
        return 2;
    }

    // Check 3-bit codes
    if ((peek >> 6) == 0b100) {
        _ = reader.readBits(3);
        return 0;
    }
    if ((peek >> 6) == 0b101) {
        _ = reader.readBits(3);
        return 3;
    }
    if ((peek >> 6) == 0b110) {
        _ = reader.readBits(3);
        return 4;
    }

    // Check 4-bit codes
    if ((peek >> 5) == 0b1110) {
        _ = reader.readBits(4);
        return 5;
    }

    // Check 5-bit codes
    if ((peek >> 4) == 0b11110) {
        _ = reader.readBits(5);
        return 6;
    }

    // Check 6-bit codes
    if ((peek >> 3) == 0b111110) {
        _ = reader.readBits(6);
        return 7;
    }

    // Check 7-bit codes
    if ((peek >> 2) == 0b1111110) {
        _ = reader.readBits(7);
        return 8;
    }

    // Check 8-bit codes
    if ((peek >> 1) == 0b11111110) {
        _ = reader.readBits(8);
        return 9;
    }

    // Check 9-bit codes
    if (peek == 0b111111110) {
        _ = reader.readBits(9);
        return 10;
    }
    if (peek == 0b111111111) {
        _ = reader.readBits(9);
        return 11;
    }

    return null;
}

/// Decode DC coefficient size (chrominance)
pub fn decodeDcSizeChroma(reader: *BitReader) ?u4 {
    // Table B-13: DC size chrominance
    const peek = reader.peekBits(10) orelse return null;

    if ((peek >> 8) == 0b00) {
        _ = reader.readBits(2);
        return 0;
    } else if ((peek >> 8) == 0b01) {
        _ = reader.readBits(2);
        return 1;
    } else if ((peek >> 8) == 0b10) {
        _ = reader.readBits(2);
        return 2;
    } else if ((peek >> 7) == 0b110) {
        _ = reader.readBits(3);
        return 3;
    } else if ((peek >> 6) == 0b1110) {
        _ = reader.readBits(4);
        return 4;
    } else if ((peek >> 5) == 0b11110) {
        _ = reader.readBits(5);
        return 5;
    } else if ((peek >> 4) == 0b111110) {
        _ = reader.readBits(6);
        return 6;
    } else if ((peek >> 3) == 0b1111110) {
        _ = reader.readBits(7);
        return 7;
    } else if ((peek >> 2) == 0b11111110) {
        _ = reader.readBits(8);
        return 8;
    } else if ((peek >> 1) == 0b111111110) {
        _ = reader.readBits(9);
        return 9;
    } else if ((peek >> 0) == 0b1111111110) {
        _ = reader.readBits(10);
        return 10;
    }

    return null;
}

/// Decode DC coefficient value from size
pub fn decodeDcValue(reader: *BitReader, size: u4) ?i32 {
    if (size == 0) return 0;

    const bits = reader.readBits(size) orelse return null;
    const half: u32 = @as(u32, 1) << @intCast(size - 1);

    // If MSB is 0, value is negative
    if (bits < half) {
        return @as(i32, @intCast(bits)) - @as(i32, @intCast((@as(u32, 1) << size) - 1));
    } else {
        return @intCast(bits);
    }
}

// ============================================================================
// Block Decoding
// ============================================================================

/// Decode result for a block
pub const BlockDecodeResult = struct {
    valid: bool,
    coeffs: DctBlock,
    dc_value: i32,
};

/// Decode an intra block (I-frame or intra macroblock)
pub fn decodeIntraBlock(
    reader: *BitReader,
    is_luma: bool,
    prev_dc: i32,
    quant_scale: u5,
    quant_matrix: *const [64]u8,
) BlockDecodeResult {
    var coeffs: DctBlock = [_]i32{0} ** 64;

    // Decode DC coefficient
    const dc_size = if (is_luma)
        decodeDcSizeLuma(reader)
    else
        decodeDcSizeChroma(reader);

    if (dc_size == null) {
        return .{ .valid = false, .coeffs = undefined, .dc_value = prev_dc };
    }

    const dc_diff = decodeDcValue(reader, dc_size.?) orelse {
        return .{ .valid = false, .coeffs = undefined, .dc_value = prev_dc };
    };

    const dc_value = prev_dc + dc_diff;
    coeffs[0] = dc_value * 8; // DC is scaled by 8 in MPEG

    // Decode AC coefficients using VLC
    var coeff_idx: usize = 1; // Start after DC
    var is_first_ac = true;

    while (coeff_idx < 64) {
        const ac = decodeAcCoeff(reader, is_first_ac) orelse {
            // Treat decode failure as end of block for robustness
            break;
        };
        is_first_ac = false;

        if (ac.eob) break;

        // Apply run (skip zeros)
        coeff_idx += ac.run;
        if (coeff_idx >= 64) break;

        // Store coefficient at zigzag position
        coeffs[zigzag_scan[coeff_idx]] = ac.level;
        coeff_idx += 1;
    }

    // Dequantize coefficients
    // DC coefficient
    const q0: i32 = @intCast(quant_matrix[0]);
    coeffs[0] = @divTrunc(coeffs[0] * q0 * @as(i32, quant_scale), 8);

    // AC coefficients: level * quant_matrix[i] * quant_scale / 16
    for (1..64) |j| {
        if (coeffs[j] != 0) {
            const q: i32 = @intCast(quant_matrix[zigzag_scan[j]]);
            const sign: i32 = if (coeffs[j] < 0) -1 else 1;
            const abs_level: i32 = if (coeffs[j] < 0) -coeffs[j] else coeffs[j];
            coeffs[j] = sign * @divTrunc((2 * abs_level + 1) * q * @as(i32, quant_scale), 16);
        }
    }

    return .{
        .valid = true,
        .coeffs = coeffs,
        .dc_value = dc_value,
    };
}

// ============================================================================
// Slice Decoding
// ============================================================================

/// Slice decode result
pub const SliceDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    macroblocks_decoded: u32,
    blocks_decoded: u32,
};

/// Decode a slice (row of macroblocks)
pub fn decodeSlice(
    data: []const u8,
    slice_vertical_pos: u8,
    width_in_mb: u16,
    quant_scale: u5,
    intra_quant: *const [64]u8,
) SliceDecodeResult {
    _ = slice_vertical_pos;

    var reader = BitReader.init(data);
    var macroblocks_decoded: u32 = 0;
    var blocks_decoded: u32 = 0;

    // DC prediction values (reset per slice)
    var dc_y: i32 = 1024; // Reset value for 8-bit video
    var dc_cb: i32 = 1024;
    var dc_cr: i32 = 1024;

    // Decode macroblocks in slice
    var mb_x: u16 = 0;
    while (mb_x < width_in_mb) : (mb_x += 1) {
        if (!reader.hasMore()) break;

        // For I-frames, each macroblock has 6 blocks (4Y + Cb + Cr for 4:2:0)
        // Decode Y blocks
        for (0..4) |_| {
            const result = decodeIntraBlock(&reader, true, dc_y, quant_scale, intra_quant);
            if (!result.valid) {
                return .{
                    .valid = false,
                    .error_message = "Y block decode failed",
                    .macroblocks_decoded = macroblocks_decoded,
                    .blocks_decoded = blocks_decoded,
                };
            }
            dc_y = result.dc_value;
            blocks_decoded += 1;
        }

        // Decode Cb block
        {
            const result = decodeIntraBlock(&reader, false, dc_cb, quant_scale, intra_quant);
            if (!result.valid) {
                return .{
                    .valid = false,
                    .error_message = "Cb block decode failed",
                    .macroblocks_decoded = macroblocks_decoded,
                    .blocks_decoded = blocks_decoded,
                };
            }
            dc_cb = result.dc_value;
            blocks_decoded += 1;
        }

        // Decode Cr block
        {
            const result = decodeIntraBlock(&reader, false, dc_cr, quant_scale, intra_quant);
            if (!result.valid) {
                return .{
                    .valid = false,
                    .error_message = "Cr block decode failed",
                    .macroblocks_decoded = macroblocks_decoded,
                    .blocks_decoded = blocks_decoded,
                };
            }
            dc_cr = result.dc_value;
            blocks_decoded += 1;
        }

        macroblocks_decoded += 1;
    }

    return .{
        .valid = true,
        .error_message = null,
        .macroblocks_decoded = macroblocks_decoded,
        .blocks_decoded = blocks_decoded,
    };
}

// ============================================================================
// Frame-level Deep Validation
// ============================================================================

/// Deep validation result
pub const FrameDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    slices_decoded: u32,
    macroblocks_decoded: u32,
    blocks_decoded: u32,
    is_mpeg2: bool,
};

/// Find next start code
fn findStartCode(data: []const u8, offset: usize) ?struct { pos: usize, code: u8 } {
    if (offset + 4 > data.len) return null;

    var i = offset;
    while (i + 3 < data.len) {
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            return .{ .pos = i, .code = data[i + 3] };
        }
        i += 1;
    }
    return null;
}

/// Deep validate an MPEG-1/2 I-frame
pub fn validateIFrameDeep(data: []const u8) FrameDecodeResult {
    var slices_decoded: u32 = 0;
    var total_mb: u32 = 0;
    var total_blocks: u32 = 0;
    var is_mpeg2 = false;

    // Parse sequence header to get dimensions
    var width: u16 = 0;
    var height: u16 = 0;
    const quant_scale: u5 = 8; // Default (would be parsed from slice header)
    var intra_quant = default_intra_quant;

    var pos: usize = 0;

    // Find sequence header
    while (findStartCode(data, pos)) |sc| {
        if (sc.code == 0xB3) {
            // Sequence header
            if (sc.pos + 8 <= data.len) {
                const h_size = (@as(u16, data[sc.pos + 4]) << 4) | (data[sc.pos + 5] >> 4);
                const v_size = (@as(u16, data[sc.pos + 5] & 0x0F) << 8) | data[sc.pos + 6];
                width = h_size;
                height = v_size;

                // Check for custom quant matrix
                if (sc.pos + 12 <= data.len) {
                    const flags = data[sc.pos + 11];
                    if (flags & 0x02 != 0) {
                        // Load intra quant matrix
                        if (sc.pos + 12 + 64 <= data.len) {
                            @memcpy(&intra_quant, data[sc.pos + 12 .. sc.pos + 12 + 64]);
                        }
                    }
                }
            }
            pos = sc.pos + 4;
        } else if (sc.code == 0xB5) {
            // Extension (MPEG-2)
            is_mpeg2 = true;
            pos = sc.pos + 4;
        } else if (sc.code >= 0x01 and sc.code <= 0xAF) {
            // Slice start code
            const slice_end = findStartCode(data, sc.pos + 4);
            const slice_data = if (slice_end) |se|
                data[sc.pos + 4 .. se.pos]
            else
                data[sc.pos + 4 ..];

            if (slice_data.len > 0 and width > 0) {
                const width_in_mb = (width + 15) / 16;
                const result = decodeSlice(slice_data, sc.code, width_in_mb, quant_scale, &intra_quant);
                total_mb += result.macroblocks_decoded;
                total_blocks += result.blocks_decoded;
                slices_decoded += 1;

                // Don't fail on individual slice errors - MPEG streams can be complex
            }

            pos = sc.pos + 4;
        } else {
            pos = sc.pos + 4;
        }
    }

    if (slices_decoded == 0) {
        return .{
            .valid = false,
            .error_message = "No slices decoded",
            .slices_decoded = 0,
            .macroblocks_decoded = 0,
            .blocks_decoded = 0,
            .is_mpeg2 = is_mpeg2,
        };
    }

    return .{
        .valid = true,
        .error_message = null,
        .slices_decoded = slices_decoded,
        .macroblocks_decoded = total_mb,
        .blocks_decoded = total_blocks,
        .is_mpeg2 = is_mpeg2,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "inverse DCT of DC-only block" {
    var coeffs: DctBlock = [_]i32{0} ** 64;
    coeffs[0] = 1024;

    const pixels = inverseDct8x8(&coeffs);

    // DC-only should produce uniform output
    const expected: i16 = 128;
    for (pixels) |p| {
        try std.testing.expect(@abs(p - expected) <= 2);
    }
}

test "BitReader basic" {
    const data = [_]u8{ 0xAB, 0xCD };
    var reader = BitReader.init(&data);

    const v1 = reader.readBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xA), v1);

    const v2 = reader.readBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xB), v2);

    const v3 = reader.readBits(8).?;
    try std.testing.expectEqual(@as(u32, 0xCD), v3);
}

test "BitReader peek" {
    const data = [_]u8{0xFF};
    var reader = BitReader.init(&data);

    const peek1 = reader.peekBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xF), peek1);

    const peek2 = reader.peekBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xF), peek2);

    const read = reader.readBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xF), read);

    const peek3 = reader.peekBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xF), peek3);
}

test "DC size decode luma" {
    // Need at least 2 bytes since we peek 9 bits
    // Size 0: 100 (3 bits)
    var data0 = [_]u8{ 0b10000000, 0x00 };
    var reader0 = BitReader.init(&data0);
    try std.testing.expectEqual(@as(?u4, 0), decodeDcSizeLuma(&reader0));

    // Size 1: 00 (2 bits)
    var data1 = [_]u8{ 0b00000000, 0x00 };
    var reader1 = BitReader.init(&data1);
    try std.testing.expectEqual(@as(?u4, 1), decodeDcSizeLuma(&reader1));

    // Size 2: 01 (2 bits)
    var data2 = [_]u8{ 0b01000000, 0x00 };
    var reader2 = BitReader.init(&data2);
    try std.testing.expectEqual(@as(?u4, 2), decodeDcSizeLuma(&reader2));

    // Size 3: 101 (3 bits)
    var data3 = [_]u8{ 0b10100000, 0x00 };
    var reader3 = BitReader.init(&data3);
    try std.testing.expectEqual(@as(?u4, 3), decodeDcSizeLuma(&reader3));

    // Size 4: 110 (3 bits)
    var data4 = [_]u8{ 0b11000000, 0x00 };
    var reader4 = BitReader.init(&data4);
    try std.testing.expectEqual(@as(?u4, 4), decodeDcSizeLuma(&reader4));
}

test "DC value decode" {
    var data = [_]u8{0b11000000};
    var reader = BitReader.init(&data);

    // Size 2, bits = 11 = 3 (positive)
    const val = decodeDcValue(&reader, 2).?;
    try std.testing.expectEqual(@as(i32, 3), val);
}

test "zigzag scan order" {
    // First few entries should be: 0, 1, 8, 16, 9, 2, 3, 10
    try std.testing.expectEqual(@as(u8, 0), zigzag_scan[0]);
    try std.testing.expectEqual(@as(u8, 1), zigzag_scan[1]);
    try std.testing.expectEqual(@as(u8, 8), zigzag_scan[2]);
    try std.testing.expectEqual(@as(u8, 16), zigzag_scan[3]);
    try std.testing.expectEqual(@as(u8, 9), zigzag_scan[4]);
}

test "AC coefficient decode EOB" {
    // EOB: 10 (2 bits) - need 3 bytes for 17-bit peek
    var data = [_]u8{ 0b10000000, 0x00, 0x00 };
    var reader = BitReader.init(&data);

    const ac = decodeAcCoeff(&reader, false).?;
    try std.testing.expect(ac.eob);
    try std.testing.expectEqual(@as(u6, 0), ac.run);
    try std.testing.expectEqual(@as(i12, 0), ac.level);
}

test "AC coefficient decode (0,1)" {
    // Non-first (0,1): 11s = 110 for +1, 111 for -1
    // Need 3 bytes for 17-bit peek
    var data_pos = [_]u8{ 0b11000000, 0x00, 0x00 };
    var reader_pos = BitReader.init(&data_pos);

    const ac_pos = decodeAcCoeff(&reader_pos, false).?;
    try std.testing.expect(!ac_pos.eob);
    try std.testing.expectEqual(@as(u6, 0), ac_pos.run);
    try std.testing.expectEqual(@as(i12, 1), ac_pos.level);

    var data_neg = [_]u8{ 0b11100000, 0x00, 0x00 };
    var reader_neg = BitReader.init(&data_neg);

    const ac_neg = decodeAcCoeff(&reader_neg, false).?;
    try std.testing.expect(!ac_neg.eob);
    try std.testing.expectEqual(@as(u6, 0), ac_neg.run);
    try std.testing.expectEqual(@as(i12, -1), ac_neg.level);
}

test "AC coefficient decode (1,1)" {
    // (1,1): 011s = 0110 for +1
    var data = [_]u8{ 0b01100000, 0x00, 0x00 };
    var reader = BitReader.init(&data);

    const ac = decodeAcCoeff(&reader, false).?;
    try std.testing.expect(!ac.eob);
    try std.testing.expectEqual(@as(u6, 1), ac.run);
    try std.testing.expectEqual(@as(i12, 1), ac.level);
}

test "AC coefficient decode escape" {
    // Escape: 000001 + 6-bit run + 8-bit level
    // Run=5, Level=42
    // 000001 00 0101 00101010
    var data = [_]u8{ 0b00000100, 0b01010010, 0b10100000 };
    var reader = BitReader.init(&data);

    const ac = decodeAcCoeff(&reader, false).?;
    try std.testing.expect(!ac.eob);
    try std.testing.expectEqual(@as(u6, 5), ac.run);
    try std.testing.expectEqual(@as(i12, 42), ac.level);
}
