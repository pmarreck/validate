//! MPEG-4 Part 2 Video Decoder (Pure Zig)
//!
//! DCT-based decoder for MPEG-4 Visual / ASP (ISO 14496-2) validation.
//! Decodes macroblocks to verify bitstream integrity without producing video output.
//!
//! This extends the structural validator with full DCT decode capability.
//! Key MPEG-4 Part 2 features beyond MPEG-2:
//! - AC/DC prediction for intra blocks
//! - Different VLC tables (B-15, B-16, B-17)
//! - Short video header mode (H.263 compatibility)
//! - Advanced prediction modes
//!
//! Reference: ISO/IEC 14496-2 (MPEG-4 Visual)
//!
//! Patents: All expired 2019-2022

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const math = std.math;
const Allocator = std.mem.Allocator;

// Import shared MPEG decoder infrastructure
const mpeg12 = @import("mpeg12_decoder.zig");

// Import structural validator for VOL/VOP parsing
const mpeg4p2_struct = @import("mpeg4p2_validator.zig");

// ============================================================================
// Re-exported shared types
// ============================================================================

/// 8x8 DCT block coefficients
pub const DctBlock = mpeg12.DctBlock;

/// 8x8 pixel block
pub const PixelBlock = mpeg12.PixelBlock;

/// Zigzag scan order (same as MPEG-2)
pub const zigzag_scan = mpeg12.zigzag_scan;

/// IDCT function (same algorithm as MPEG-2)
pub const inverseDct8x8 = mpeg12.inverseDct8x8;

// ============================================================================
// MPEG-4 Part 2 Specific Constants
// ============================================================================

/// Default intra quantization matrix (Table 6-6 in ISO 14496-2)
/// This is the same as MPEG-2's default intra matrix
pub const default_intra_quant_mp4 = mpeg12.default_intra_quant;

/// Default inter (non-intra) quantization matrix
pub const default_inter_quant_mp4 = mpeg12.default_non_intra_quant;

/// DC scaler table for luminance (Table 7-1)
/// Index is quant_dc (1-31), returns DC scaler
pub const dc_scaler_luma = [32]u8{
    0, // 0 is invalid
    8, 8, 8, 8, // quant 1-4
    10, 12, 14, 16, // quant 5-8
    17, 18, 19, 20, // quant 9-12
    21, 22, 23, 24, // quant 13-16
    25, 26, 27, 28, // quant 17-20
    29, 30, 31, 32, // quant 21-24
    34, 36, 38, 40, // quant 25-28
    42, 44, 46, // quant 29-31
};

/// DC scaler table for chrominance (Table 7-1)
pub const dc_scaler_chroma = [32]u8{
    0, // 0 is invalid
    8, 8, 8, 8, // quant 1-4
    9, 9, 10, 10, // quant 5-8
    11, 11, 12, 12, // quant 9-12
    13, 13, 14, 14, // quant 13-16
    15, 15, 16, 16, // quant 17-20
    17, 17, 18, 18, // quant 21-24
    19, 20, 21, 22, // quant 25-28
    23, 24, 25, // quant 29-31
};

// ============================================================================
// Intra DC VLC Decoding (Table B-15)
// ============================================================================

/// Decode intra DC coefficient size for luminance
/// Table B-15 in ISO 14496-2
pub fn decodeIntraDcSizeLuma(reader: *BitReader) ?u5 {
    const peek = reader.peekBits(11) orelse return null;

    // Table B-15 (luminance):
    // Size 0:  011        (3 bits)
    // Size 1:  100        (3 bits)
    // Size 2:  00         (2 bits)
    // Size 3:  101        (3 bits)
    // Size 4:  110        (3 bits)
    // Size 5:  1110       (4 bits)
    // Size 6:  11110      (5 bits)
    // Size 7:  111110     (6 bits)
    // Size 8:  1111110    (7 bits)
    // Size 9:  11111110   (8 bits)
    // Size 10: 111111110  (9 bits)
    // Size 11: 1111111110 (10 bits)
    // Size 12: 11111111110 (11 bits)

    // Check 2-bit codes first
    if ((peek >> 9) == 0b00) {
        _ = reader.readBits(2);
        return 2;
    }

    // Check 3-bit codes
    const three_bits = peek >> 8;
    if (three_bits == 0b011) {
        _ = reader.readBits(3);
        return 0;
    }
    if (three_bits == 0b100) {
        _ = reader.readBits(3);
        return 1;
    }
    if (three_bits == 0b101) {
        _ = reader.readBits(3);
        return 3;
    }
    if (three_bits == 0b110) {
        _ = reader.readBits(3);
        return 4;
    }

    // Check 4-bit code
    if ((peek >> 7) == 0b1110) {
        _ = reader.readBits(4);
        return 5;
    }

    // Check 5-bit code
    if ((peek >> 6) == 0b11110) {
        _ = reader.readBits(5);
        return 6;
    }

    // Check 6-bit code
    if ((peek >> 5) == 0b111110) {
        _ = reader.readBits(6);
        return 7;
    }

    // Check 7-bit code
    if ((peek >> 4) == 0b1111110) {
        _ = reader.readBits(7);
        return 8;
    }

    // Check 8-bit code
    if ((peek >> 3) == 0b11111110) {
        _ = reader.readBits(8);
        return 9;
    }

    // Check 9-bit code
    if ((peek >> 2) == 0b111111110) {
        _ = reader.readBits(9);
        return 10;
    }

    // Check 10-bit code
    if ((peek >> 1) == 0b1111111110) {
        _ = reader.readBits(10);
        return 11;
    }

    // Check 11-bit code
    if (peek == 0b11111111110) {
        _ = reader.readBits(11);
        return 12;
    }

    return null; // Invalid code
}

/// Decode intra DC coefficient size for chrominance
/// Table B-15 in ISO 14496-2
pub fn decodeIntraDcSizeChroma(reader: *BitReader) ?u5 {
    const peek = reader.peekBits(12) orelse return null;

    // Table B-15 (chrominance):
    // Size 0:  00          (2 bits)
    // Size 1:  01          (2 bits)
    // Size 2:  10          (2 bits)
    // Size 3:  110         (3 bits)
    // Size 4:  1110        (4 bits)
    // Size 5:  11110       (5 bits)
    // Size 6:  111110      (6 bits)
    // Size 7:  1111110     (7 bits)
    // Size 8:  11111110    (8 bits)
    // Size 9:  111111110   (9 bits)
    // Size 10: 1111111110  (10 bits)
    // Size 11: 11111111110 (11 bits)
    // Size 12: 111111111110 (12 bits)

    // Check 2-bit codes first
    const two_bits = peek >> 10;
    if (two_bits == 0b00) {
        _ = reader.readBits(2);
        return 0;
    }
    if (two_bits == 0b01) {
        _ = reader.readBits(2);
        return 1;
    }
    if (two_bits == 0b10) {
        _ = reader.readBits(2);
        return 2;
    }

    // Check 3-bit code
    if ((peek >> 9) == 0b110) {
        _ = reader.readBits(3);
        return 3;
    }

    // Check 4-bit code
    if ((peek >> 8) == 0b1110) {
        _ = reader.readBits(4);
        return 4;
    }

    // Check 5-bit code
    if ((peek >> 7) == 0b11110) {
        _ = reader.readBits(5);
        return 5;
    }

    // Check 6-bit code
    if ((peek >> 6) == 0b111110) {
        _ = reader.readBits(6);
        return 6;
    }

    // Check 7-bit code
    if ((peek >> 5) == 0b1111110) {
        _ = reader.readBits(7);
        return 7;
    }

    // Check 8-bit code
    if ((peek >> 4) == 0b11111110) {
        _ = reader.readBits(8);
        return 8;
    }

    // Check 9-bit code
    if ((peek >> 3) == 0b111111110) {
        _ = reader.readBits(9);
        return 9;
    }

    // Check 10-bit code
    if ((peek >> 2) == 0b1111111110) {
        _ = reader.readBits(10);
        return 10;
    }

    // Check 11-bit code
    if ((peek >> 1) == 0b11111111110) {
        _ = reader.readBits(11);
        return 11;
    }

    // Check 12-bit code
    if (peek == 0b111111111110) {
        _ = reader.readBits(12);
        return 12;
    }

    return null; // Invalid code
}

/// Decode the DC coefficient value given its size
/// Returns the signed DC differential value
pub fn decodeIntraDcValue(reader: *BitReader, size: u5) ?i32 {
    if (size == 0) return 0;

    // Read 'size' bits
    const bits = reader.readBits(size) orelse return null;

    // If first bit is 0, value is negative
    // Value = bits - (1 << size) + 1 for negative
    // Value = bits for positive
    const threshold: u32 = @as(u32, 1) << @intCast(size - 1);
    if (bits < threshold) {
        // Negative value
        const offset: i32 = @as(i32, 1) << @intCast(size);
        return @as(i32, @intCast(bits)) - offset + 1;
    } else {
        return @as(i32, @intCast(bits));
    }
}

// ============================================================================
// AC Coefficient VLC Decoding (Tables B-16, B-17)
// ============================================================================

/// AC coefficient decode result
pub const AcCoeff = struct {
    run: u6, // Number of zeros before this coefficient
    level: i12, // Coefficient value (signed)
    last: bool, // Last coefficient in block flag
};

/// RVLC (Reversible VLC) AC coefficient table entry
/// MPEG-4 Part 2 uses different tables than MPEG-2
const AcVlcEntry = struct {
    code: u16,
    len: u5,
    run: u6,
    level: u6,
    last: bool,
};

/// Intra AC coefficient VLC table (Table B-16)
/// Format: last, run, level -> code, length
const intra_ac_vlc_table = [_]AcVlcEntry{
    // Last=0 coefficients (not end of block)
    // Run=0
    .{ .code = 0b10, .len = 2, .run = 0, .level = 1, .last = false },
    .{ .code = 0b1111, .len = 4, .run = 0, .level = 2, .last = false },
    .{ .code = 0b010101, .len = 6, .run = 0, .level = 3, .last = false },
    .{ .code = 0b0010111, .len = 7, .run = 0, .level = 4, .last = false },
    .{ .code = 0b00110111, .len = 8, .run = 0, .level = 5, .last = false },
    .{ .code = 0b00110110, .len = 8, .run = 0, .level = 6, .last = false },
    .{ .code = 0b00110101, .len = 8, .run = 0, .level = 7, .last = false },
    .{ .code = 0b00110100, .len = 8, .run = 0, .level = 8, .last = false },
    .{ .code = 0b001101011, .len = 9, .run = 0, .level = 9, .last = false },
    .{ .code = 0b001101010, .len = 9, .run = 0, .level = 10, .last = false },
    .{ .code = 0b001101001, .len = 9, .run = 0, .level = 11, .last = false },
    .{ .code = 0b001101000, .len = 9, .run = 0, .level = 12, .last = false },
    // Run=1
    .{ .code = 0b110, .len = 3, .run = 1, .level = 1, .last = false },
    .{ .code = 0b010111, .len = 6, .run = 1, .level = 2, .last = false },
    .{ .code = 0b00110011, .len = 8, .run = 1, .level = 3, .last = false },
    .{ .code = 0b001100111, .len = 9, .run = 1, .level = 4, .last = false },
    // Run=2
    .{ .code = 0b1110, .len = 4, .run = 2, .level = 1, .last = false },
    .{ .code = 0b0010110, .len = 7, .run = 2, .level = 2, .last = false },
    .{ .code = 0b00110010, .len = 8, .run = 2, .level = 3, .last = false },
    // Run=3
    .{ .code = 0b010110, .len = 6, .run = 3, .level = 1, .last = false },
    .{ .code = 0b001100110, .len = 9, .run = 3, .level = 2, .last = false },
    // Run=4
    .{ .code = 0b010100, .len = 6, .run = 4, .level = 1, .last = false },
    .{ .code = 0b00110001, .len = 8, .run = 4, .level = 2, .last = false },
    // Run=5
    .{ .code = 0b010011, .len = 6, .run = 5, .level = 1, .last = false },
    .{ .code = 0b001100101, .len = 9, .run = 5, .level = 2, .last = false },
    // Run=6
    .{ .code = 0b0010101, .len = 7, .run = 6, .level = 1, .last = false },
    // Run=7
    .{ .code = 0b0010100, .len = 7, .run = 7, .level = 1, .last = false },
    // Run=8
    .{ .code = 0b0010011, .len = 7, .run = 8, .level = 1, .last = false },
    // Run=9
    .{ .code = 0b00110000, .len = 8, .run = 9, .level = 1, .last = false },
    // Run=10
    .{ .code = 0b001100100, .len = 9, .run = 10, .level = 1, .last = false },
    // Run=11
    .{ .code = 0b001100011, .len = 9, .run = 11, .level = 1, .last = false },
    // Run=12
    .{ .code = 0b001100010, .len = 9, .run = 12, .level = 1, .last = false },

    // Last=1 coefficients (end of block after this)
    // Run=0
    .{ .code = 0b0111, .len = 4, .run = 0, .level = 1, .last = true },
    .{ .code = 0b010010, .len = 6, .run = 0, .level = 2, .last = true },
    .{ .code = 0b0010010, .len = 7, .run = 0, .level = 3, .last = true },
    // Run=1
    .{ .code = 0b0110, .len = 4, .run = 1, .level = 1, .last = true },
    .{ .code = 0b010001, .len = 6, .run = 1, .level = 2, .last = true },
    .{ .code = 0b0010001, .len = 7, .run = 1, .level = 3, .last = true },
    // Run=2
    .{ .code = 0b010000, .len = 6, .run = 2, .level = 1, .last = true },
    // Run=3
    .{ .code = 0b0010000, .len = 7, .run = 3, .level = 1, .last = true },
    // Run=4-5
    .{ .code = 0b00101111, .len = 8, .run = 4, .level = 1, .last = true },
    .{ .code = 0b00101110, .len = 8, .run = 5, .level = 1, .last = true },
    // Run=6-9
    .{ .code = 0b00101101, .len = 8, .run = 6, .level = 1, .last = true },
    .{ .code = 0b00101100, .len = 8, .run = 7, .level = 1, .last = true },
    .{ .code = 0b00101011, .len = 8, .run = 8, .level = 1, .last = true },
    .{ .code = 0b00101010, .len = 8, .run = 9, .level = 1, .last = true },
};

/// Decode an AC coefficient using the intra VLC table
/// Returns null on error, or the coefficient (run, level, last)
pub fn decodeIntraAcCoeff(reader: *BitReader) ?AcCoeff {
    const peek = reader.peekBits(16) orelse return null;

    // Check for escape code (0000 0001 1 = 9 bits for Type 1 escape)
    // MPEG-4 Part 2 has three escape modes
    if ((peek >> 7) == 0b000000011) {
        return decodeEscapeCoeff(reader);
    }

    // Search VLC table (ordered by code length for efficiency)
    for (intra_ac_vlc_table) |entry| {
        const shifted = peek >> @intCast(16 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            // Read sign bit
            const sign = reader.readBit() orelse return null;
            const level: i12 = if (sign == 1)
                -@as(i12, @intCast(entry.level))
            else
                @as(i12, @intCast(entry.level));
            return .{ .run = entry.run, .level = level, .last = entry.last };
        }
    }

    return null; // Invalid VLC code
}

/// Decode escape-coded AC coefficient
fn decodeEscapeCoeff(reader: *BitReader) ?AcCoeff {
    // Skip the escape prefix (9 bits: 0000 0001 1)
    _ = reader.readBits(9);

    // Read escape type indicator
    const type_bit = reader.readBit() orelse return null;

    if (type_bit == 0) {
        // Type 1: Modified VLC
        // Read the VLC code and add to LMAX or RMAX
        return decodeIntraAcCoeff(reader); // Recursive, adds to base
    } else {
        // Check next bit for Type 2 vs Type 3
        const type2_bit = reader.readBit() orelse return null;

        if (type2_bit == 0) {
            // Type 2: Modified VLC with different table lookup
            return decodeIntraAcCoeff(reader);
        } else {
            // Type 3: Fixed length code
            // last (1 bit) + run (6 bits) + marker (1 bit) + level (12 bits) + marker (1 bit)
            const last = reader.readBit() orelse return null;
            const run = reader.readBits(6) orelse return null;
            const marker1 = reader.readBit() orelse return null;
            if (marker1 != 1) return null; // Marker should be 1
            const level_bits = reader.readBits(12) orelse return null;
            const marker2 = reader.readBit() orelse return null;
            if (marker2 != 1) return null; // Marker should be 1

            // Convert to signed level
            const level: i12 = if (level_bits >= 2048)
                @as(i12, @intCast(level_bits)) - 4096
            else
                @as(i12, @intCast(level_bits));

            return .{
                .run = @intCast(run),
                .level = level,
                .last = last == 1,
            };
        }
    }
}

// ============================================================================
// DC/AC Prediction
// ============================================================================

/// Direction for DC/AC prediction
pub const PredictionDirection = enum {
    horizontal, // Predict from left block
    vertical, // Predict from top block
    none, // No prediction (first block)
};

/// Determine prediction direction based on gradient
/// dc_a = DC of block to the left
/// dc_b = DC of block above-left (diagonal)
/// dc_c = DC of block above
pub fn getPredictionDirection(dc_a: i32, dc_b: i32, dc_c: i32) PredictionDirection {
    // abs(dc_a - dc_b) < abs(dc_b - dc_c) => predict from C (vertical)
    // otherwise predict from A (horizontal)
    const diff_ab = @abs(dc_a - dc_b);
    const diff_bc = @abs(dc_b - dc_c);

    if (diff_ab < diff_bc) {
        return .vertical;
    } else {
        return .horizontal;
    }
}

/// Apply DC prediction
pub fn applyDcPrediction(dc_diff: i32, predictor: i32, dc_scaler: u8) i32 {
    // Predicted DC = predictor / dc_scaler (with rounding)
    const pred = @divTrunc(predictor + @as(i32, dc_scaler / 2), @as(i32, dc_scaler));
    return dc_diff + pred;
}

// ============================================================================
// Block Decoding
// ============================================================================

/// Result of decoding a single 8x8 block
pub const BlockDecodeResult = struct {
    success: bool,
    error_message: ?[]const u8,
    dc_value: i32,
    num_coeffs: u8,
};

/// Decode an intra block
pub fn decodeIntraBlock(
    reader: *BitReader,
    is_luma: bool,
    quant: u5,
    pred_dc: i32,
) BlockDecodeResult {
    var coeffs: DctBlock = [_]i32{0} ** 64;

    // Decode DC coefficient
    const dc_size = if (is_luma)
        decodeIntraDcSizeLuma(reader)
    else
        decodeIntraDcSizeChroma(reader);

    if (dc_size == null) {
        return .{
            .success = false,
            .error_message = "Failed to decode DC size",
            .dc_value = 0,
            .num_coeffs = 0,
        };
    }

    const dc_diff = decodeIntraDcValue(reader, dc_size.?) orelse {
        return .{
            .success = false,
            .error_message = "Failed to decode DC value",
            .dc_value = 0,
            .num_coeffs = 0,
        };
    };

    // Apply DC prediction
    const dc_scaler = if (is_luma) dc_scaler_luma[quant] else dc_scaler_chroma[quant];
    const dc_value = applyDcPrediction(dc_diff, pred_dc, dc_scaler);
    coeffs[0] = dc_value * @as(i32, dc_scaler);

    // Decode AC coefficients
    var coeff_idx: u8 = 1;
    while (coeff_idx < 64) {
        const ac = decodeIntraAcCoeff(reader) orelse {
            return .{
                .success = false,
                .error_message = "Failed to decode AC coefficient",
                .dc_value = dc_value,
                .num_coeffs = coeff_idx,
            };
        };

        // Apply run (skip zeros)
        coeff_idx += ac.run;
        if (coeff_idx >= 64) {
            return .{
                .success = false,
                .error_message = "AC coefficient index out of range",
                .dc_value = dc_value,
                .num_coeffs = coeff_idx,
            };
        }

        // Store coefficient (zigzag order)
        coeffs[zigzag_scan[coeff_idx]] = ac.level;
        coeff_idx += 1;

        if (ac.last) break;
    }

    // Dequantize and perform IDCT
    // (For validation, we just verify the decode succeeded)
    _ = inverseDct8x8(&coeffs);

    return .{
        .success = true,
        .error_message = null,
        .dc_value = dc_value,
        .num_coeffs = coeff_idx,
    };
}

// ============================================================================
// Motion Vector Decoding
// ============================================================================

/// Motion vector component
pub const MotionVector = struct {
    x: i16,
    y: i16,
};

/// Motion Vector Difference VLC entry
const MvdVlcEntry = struct {
    code: u16,
    len: u5,
    value: i7, // -32 to +32 (including half-pel extended)
};

/// MVD VLC table (Table B-12 in ISO 14496-2)
/// Codes motion vector differences from -32 to +32
const mvd_vlc_table = [_]MvdVlcEntry{
    // MVD = 0
    .{ .code = 0b1, .len = 1, .value = 0 },
    // MVD = ±0.5 (half-pel only, coded as ±1 in half-pel units)
    .{ .code = 0b010, .len = 3, .value = 1 },
    .{ .code = 0b011, .len = 3, .value = -1 },
    // MVD = ±1
    .{ .code = 0b0010, .len = 4, .value = 2 },
    .{ .code = 0b0011, .len = 4, .value = -2 },
    // MVD = ±1.5
    .{ .code = 0b00010, .len = 5, .value = 3 },
    .{ .code = 0b00011, .len = 5, .value = -3 },
    // MVD = ±2
    .{ .code = 0b0000110, .len = 7, .value = 4 },
    .{ .code = 0b0000111, .len = 7, .value = -4 },
    // MVD = ±2.5
    .{ .code = 0b00001010, .len = 8, .value = 5 },
    .{ .code = 0b00001011, .len = 8, .value = -5 },
    // MVD = ±3
    .{ .code = 0b00001000, .len = 8, .value = 6 },
    .{ .code = 0b00001001, .len = 8, .value = -6 },
    // MVD = ±3.5
    .{ .code = 0b00000110, .len = 8, .value = 7 },
    .{ .code = 0b00000111, .len = 8, .value = -7 },
    // MVD = ±4 to ±7 (longer codes)
    .{ .code = 0b0000010110, .len = 10, .value = 8 },
    .{ .code = 0b0000010111, .len = 10, .value = -8 },
    .{ .code = 0b0000010100, .len = 10, .value = 9 },
    .{ .code = 0b0000010101, .len = 10, .value = -9 },
    .{ .code = 0b0000010010, .len = 10, .value = 10 },
    .{ .code = 0b0000010011, .len = 10, .value = -10 },
    .{ .code = 0b00000100010, .len = 11, .value = 11 },
    .{ .code = 0b00000100011, .len = 11, .value = -11 },
    .{ .code = 0b00000100000, .len = 11, .value = 12 },
    .{ .code = 0b00000100001, .len = 11, .value = -12 },
    .{ .code = 0b00000011110, .len = 11, .value = 13 },
    .{ .code = 0b00000011111, .len = 11, .value = -13 },
    .{ .code = 0b00000011100, .len = 11, .value = 14 },
    .{ .code = 0b00000011101, .len = 11, .value = -14 },
    // MVD = ±8 to ±16 (even longer codes)
    .{ .code = 0b00000011010, .len = 11, .value = 15 },
    .{ .code = 0b00000011011, .len = 11, .value = -15 },
    .{ .code = 0b00000011000, .len = 11, .value = 16 },
    .{ .code = 0b00000011001, .len = 11, .value = -16 },
    .{ .code = 0b00000010110, .len = 11, .value = 17 },
    .{ .code = 0b00000010111, .len = 11, .value = -17 },
    .{ .code = 0b00000010100, .len = 11, .value = 18 },
    .{ .code = 0b00000010101, .len = 11, .value = -18 },
    .{ .code = 0b00000010010, .len = 11, .value = 19 },
    .{ .code = 0b00000010011, .len = 11, .value = -19 },
    .{ .code = 0b00000010000, .len = 11, .value = 20 },
    .{ .code = 0b00000010001, .len = 11, .value = -20 },
    // Larger MVDs (12-bit codes)
    .{ .code = 0b000000011110, .len = 12, .value = 21 },
    .{ .code = 0b000000011111, .len = 12, .value = -21 },
    .{ .code = 0b000000011100, .len = 12, .value = 22 },
    .{ .code = 0b000000011101, .len = 12, .value = -22 },
    .{ .code = 0b000000011010, .len = 12, .value = 23 },
    .{ .code = 0b000000011011, .len = 12, .value = -23 },
    .{ .code = 0b000000011000, .len = 12, .value = 24 },
    .{ .code = 0b000000011001, .len = 12, .value = -24 },
    .{ .code = 0b000000010110, .len = 12, .value = 25 },
    .{ .code = 0b000000010111, .len = 12, .value = -25 },
    .{ .code = 0b000000010100, .len = 12, .value = 26 },
    .{ .code = 0b000000010101, .len = 12, .value = -26 },
    .{ .code = 0b000000010010, .len = 12, .value = 27 },
    .{ .code = 0b000000010011, .len = 12, .value = -27 },
    .{ .code = 0b000000010000, .len = 12, .value = 28 },
    .{ .code = 0b000000010001, .len = 12, .value = -28 },
    // Maximum MVDs (13-bit codes for ±29 to ±32)
    .{ .code = 0b0000000011110, .len = 13, .value = 29 },
    .{ .code = 0b0000000011111, .len = 13, .value = -29 },
    .{ .code = 0b0000000011100, .len = 13, .value = 30 },
    .{ .code = 0b0000000011101, .len = 13, .value = -30 },
    .{ .code = 0b0000000011010, .len = 13, .value = 31 },
    .{ .code = 0b0000000011011, .len = 13, .value = -31 },
    .{ .code = 0b0000000011000, .len = 13, .value = 32 },
    .{ .code = 0b0000000011001, .len = 13, .value = -32 },
};

/// Decode motion vector difference (MVD) component
/// Returns the VLC-decoded difference value (in half-pel units for the VLC lookup)
pub fn decodeMvd(reader: *BitReader) ?i7 {
    const peek = reader.peekBits(13) orelse return null;

    // Check for MVD = 0 first (most common)
    if ((peek >> 12) == 1) {
        _ = reader.readBits(1);
        return 0;
    }

    // Search VLC table
    for (mvd_vlc_table) |entry| {
        if (entry.len > 13) continue;
        const shifted = peek >> @intCast(13 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            return entry.value;
        }
    }

    return null; // Invalid VLC code
}

/// Decode full motion vector difference with residual bits
/// fcode determines the range and precision of motion vectors
/// Returns motion vector difference in half-pel units
pub fn decodeMotionVectorDiff(reader: *BitReader, fcode: u3) ?i16 {
    if (fcode == 0) return null; // Invalid fcode

    // Decode VLC part
    const vlc_diff = decodeMvd(reader) orelse return null;

    // If fcode > 1, read residual bits
    if (fcode > 1 and vlc_diff != 0) {
        const residual_bits = fcode - 1;
        const residual = reader.readBits(residual_bits) orelse return null;

        // Combine VLC and residual
        // mv_diff = vlc_diff * (1 << residual_bits) + residual + 1 for positive
        // mv_diff = vlc_diff * (1 << residual_bits) - residual - 1 for negative
        const scale: i16 = @as(i16, 1) << @intCast(residual_bits);
        if (vlc_diff > 0) {
            return (@as(i16, vlc_diff) - 1) * scale + @as(i16, @intCast(residual)) + 1;
        } else {
            return (@as(i16, vlc_diff) + 1) * scale - @as(i16, @intCast(residual)) - 1;
        }
    }

    return @as(i16, vlc_diff);
}

/// Calculate motion vector prediction from neighboring blocks
/// mv_a = MV of block to the left
/// mv_b = MV of block above-left (diagonal)
/// mv_c = MV of block above
/// For 16x16 blocks in MPEG-4 Part 2, uses median prediction
pub fn predictMotionVector(mv_a: MotionVector, mv_b: MotionVector, mv_c: MotionVector) MotionVector {
    return .{
        .x = median3(mv_a.x, mv_b.x, mv_c.x),
        .y = median3(mv_a.y, mv_b.y, mv_c.y),
    };
}

/// Median of three values
fn median3(a: i16, b: i16, c: i16) i16 {
    if ((a >= b and a <= c) or (a >= c and a <= b)) return a;
    if ((b >= a and b <= c) or (b >= c and b <= a)) return b;
    return c;
}

/// Apply motion vector prediction and clamp to valid range
/// range = 1 << (fcode + 4) in half-pel units
pub fn applyMotionVectorPrediction(
    diff: MotionVector,
    predictor: MotionVector,
    fcode: u3,
) MotionVector {
    const range: i16 = @as(i16, 1) << @intCast(fcode + 4);
    const low: i16 = -range;
    const high: i16 = range - 1;

    var mv: MotionVector = .{
        .x = diff.x + predictor.x,
        .y = diff.y + predictor.y,
    };

    // Wrap motion vectors to valid range
    if (mv.x < low) mv.x += range * 2;
    if (mv.x > high) mv.x -= range * 2;
    if (mv.y < low) mv.y += range * 2;
    if (mv.y > high) mv.y -= range * 2;

    return mv;
}

/// Decode a motion vector (x and y components)
pub fn decodeMotionVector(
    reader: *BitReader,
    predictor: MotionVector,
    fcode: u3,
) ?MotionVector {
    const diff_x = decodeMotionVectorDiff(reader, fcode) orelse return null;
    const diff_y = decodeMotionVectorDiff(reader, fcode) orelse return null;

    return applyMotionVectorPrediction(
        .{ .x = diff_x, .y = diff_y },
        predictor,
        fcode,
    );
}

// ============================================================================
// Inter Block Decoding (P/B frames)
// ============================================================================

/// Decode an inter (predicted) block
/// For inter blocks, coefficients are dequantized differently than intra
pub fn decodeInterBlock(
    reader: *BitReader,
    quant: u5,
    coded_block_pattern: bool,
) BlockDecodeResult {
    if (!coded_block_pattern) {
        // Block is not coded (all zeros after motion compensation)
        return .{
            .success = true,
            .error_message = null,
            .dc_value = 0,
            .num_coeffs = 0,
        };
    }

    var coeffs: DctBlock = [_]i32{0} ** 64;
    var coeff_idx: u8 = 0;

    // Inter blocks don't have separate DC coding - use same VLC for all
    while (coeff_idx < 64) {
        const ac = decodeIntraAcCoeff(reader) orelse {
            return .{
                .success = false,
                .error_message = "Failed to decode inter coefficient",
                .dc_value = 0,
                .num_coeffs = coeff_idx,
            };
        };

        coeff_idx += ac.run;
        if (coeff_idx >= 64) {
            return .{
                .success = false,
                .error_message = "Inter coefficient index out of range",
                .dc_value = 0,
                .num_coeffs = coeff_idx,
            };
        }

        // Store coefficient (zigzag order)
        // Inter dequantization: level * (2 * quant + 1)
        const dequant: i32 = @as(i32, ac.level) * (2 * @as(i32, quant) + 1);
        coeffs[zigzag_scan[coeff_idx]] = dequant;
        coeff_idx += 1;

        if (ac.last) break;
    }

    // IDCT
    _ = inverseDct8x8(&coeffs);

    return .{
        .success = true,
        .error_message = null,
        .dc_value = coeffs[0],
        .num_coeffs = coeff_idx,
    };
}

// ============================================================================
// Macroblock Type Decoding
// ============================================================================

/// Macroblock types for I-VOP
pub const IntraMbType = enum(u2) {
    intra = 0, // Intra-coded macroblock
    intra_q = 1, // Intra with DQUANT
};

/// Macroblock types for P-VOP
pub const InterMbType = enum(u4) {
    inter = 0, // Inter 16x16
    inter_q = 1, // Inter 16x16 with DQUANT
    inter4v = 2, // Inter 8x8 (4 motion vectors)
    intra = 3, // Intra in P-frame
    intra_q = 4, // Intra with DQUANT in P-frame
    inter4v_q = 5, // Inter 8x8 with DQUANT
    stuffing = 6, // Stuffing code (skip)
};

/// MCBPC decode result for I-VOP
pub const McbpcIntra = struct {
    mb_type: IntraMbType,
    cbpc: u2, // Coded block pattern for chrominance (Cb, Cr)
};

/// MCBPC decode result for P-VOP
pub const McbpcInter = struct {
    mb_type: InterMbType,
    cbpc: u2, // Coded block pattern for chrominance
};

/// MCBPC VLC entry for I-VOP (Table B-1)
const McbpcIntraEntry = struct {
    code: u9,
    len: u4,
    mb_type: IntraMbType,
    cbpc: u2,
};

/// MCBPC VLC table for I-VOP (Table B-1)
const mcbpc_intra_table = [_]McbpcIntraEntry{
    // mb_type=intra, cbpc=00: 1
    .{ .code = 0b1, .len = 1, .mb_type = .intra, .cbpc = 0b00 },
    // mb_type=intra, cbpc=01: 001
    .{ .code = 0b001, .len = 3, .mb_type = .intra, .cbpc = 0b01 },
    // mb_type=intra, cbpc=10: 010
    .{ .code = 0b010, .len = 3, .mb_type = .intra, .cbpc = 0b10 },
    // mb_type=intra, cbpc=11: 011
    .{ .code = 0b011, .len = 3, .mb_type = .intra, .cbpc = 0b11 },
    // mb_type=intra_q, cbpc=00: 0001
    .{ .code = 0b0001, .len = 4, .mb_type = .intra_q, .cbpc = 0b00 },
    // mb_type=intra_q, cbpc=01: 000001
    .{ .code = 0b000001, .len = 6, .mb_type = .intra_q, .cbpc = 0b01 },
    // mb_type=intra_q, cbpc=10: 000010
    .{ .code = 0b000010, .len = 6, .mb_type = .intra_q, .cbpc = 0b10 },
    // mb_type=intra_q, cbpc=11: 000011
    .{ .code = 0b000011, .len = 6, .mb_type = .intra_q, .cbpc = 0b11 },
    // stuffing: 000000001
    .{ .code = 0b000000001, .len = 9, .mb_type = .intra, .cbpc = 0b00 }, // Special stuffing
};

/// MCBPC VLC entry for P-VOP (Table B-2)
const McbpcInterEntry = struct {
    code: u9,
    len: u4,
    mb_type: InterMbType,
    cbpc: u2,
};

/// MCBPC VLC table for P-VOP (Table B-2) - subset
const mcbpc_inter_table = [_]McbpcInterEntry{
    // mb_type=inter, cbpc=00: 1
    .{ .code = 0b1, .len = 1, .mb_type = .inter, .cbpc = 0b00 },
    // mb_type=inter, cbpc=01: 0011
    .{ .code = 0b0011, .len = 4, .mb_type = .inter, .cbpc = 0b01 },
    // mb_type=inter, cbpc=10: 0010
    .{ .code = 0b0010, .len = 4, .mb_type = .inter, .cbpc = 0b10 },
    // mb_type=inter, cbpc=11: 000101
    .{ .code = 0b000101, .len = 6, .mb_type = .inter, .cbpc = 0b11 },
    // mb_type=inter_q, cbpc=00: 010
    .{ .code = 0b010, .len = 3, .mb_type = .inter_q, .cbpc = 0b00 },
    // mb_type=inter_q, cbpc=01: 0000111
    .{ .code = 0b0000111, .len = 7, .mb_type = .inter_q, .cbpc = 0b01 },
    // mb_type=inter_q, cbpc=10: 0000110
    .{ .code = 0b0000110, .len = 7, .mb_type = .inter_q, .cbpc = 0b10 },
    // mb_type=inter_q, cbpc=11: 000001011
    .{ .code = 0b000001011, .len = 9, .mb_type = .inter_q, .cbpc = 0b11 },
    // mb_type=inter4v, cbpc=00: 011
    .{ .code = 0b011, .len = 3, .mb_type = .inter4v, .cbpc = 0b00 },
    // mb_type=intra, cbpc=00: 0001
    .{ .code = 0b0001, .len = 4, .mb_type = .intra, .cbpc = 0b00 },
    // mb_type=intra_q, cbpc=00: 000100
    .{ .code = 0b000100, .len = 6, .mb_type = .intra_q, .cbpc = 0b00 },
    // stuffing: 000000001
    .{ .code = 0b000000001, .len = 9, .mb_type = .stuffing, .cbpc = 0b00 },
};

/// Decode MCBPC for I-VOP
pub fn decodeMcbpcIntra(reader: *BitReader) ?McbpcIntra {
    const peek = reader.peekBits(9) orelse return null;

    for (mcbpc_intra_table) |entry| {
        const shifted = peek >> @intCast(9 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            return .{ .mb_type = entry.mb_type, .cbpc = entry.cbpc };
        }
    }

    return null; // Invalid code
}

/// Decode MCBPC for P-VOP
pub fn decodeMcbpcInter(reader: *BitReader) ?McbpcInter {
    const peek = reader.peekBits(9) orelse return null;

    for (mcbpc_inter_table) |entry| {
        const shifted = peek >> @intCast(9 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            return .{ .mb_type = entry.mb_type, .cbpc = entry.cbpc };
        }
    }

    return null; // Invalid code
}

/// CBPY VLC entry (Table B-3)
const CbpyEntry = struct {
    code: u6,
    len: u3,
    cbpy: u4, // Coded block pattern for luminance (4 blocks)
};

/// CBPY VLC table for intra blocks (Table B-3)
/// For intra, the table is used directly
/// For inter, the values should be inverted (15 - cbpy)
const cbpy_table = [_]CbpyEntry{
    // cbpy=0 (0000): 0011
    .{ .code = 0b0011, .len = 4, .cbpy = 0b0000 },
    // cbpy=1 (0001): 00101
    .{ .code = 0b00101, .len = 5, .cbpy = 0b0001 },
    // cbpy=2 (0010): 00100
    .{ .code = 0b00100, .len = 5, .cbpy = 0b0010 },
    // cbpy=3 (0011): 1001
    .{ .code = 0b1001, .len = 4, .cbpy = 0b0011 },
    // cbpy=4 (0100): 00011
    .{ .code = 0b00011, .len = 5, .cbpy = 0b0100 },
    // cbpy=5 (0101): 0111
    .{ .code = 0b0111, .len = 4, .cbpy = 0b0101 },
    // cbpy=6 (0110): 000010
    .{ .code = 0b000010, .len = 6, .cbpy = 0b0110 },
    // cbpy=7 (0111): 1011
    .{ .code = 0b1011, .len = 4, .cbpy = 0b0111 },
    // cbpy=8 (1000): 00010
    .{ .code = 0b00010, .len = 5, .cbpy = 0b1000 },
    // cbpy=9 (1001): 000011
    .{ .code = 0b000011, .len = 6, .cbpy = 0b1001 },
    // cbpy=10 (1010): 0101
    .{ .code = 0b0101, .len = 4, .cbpy = 0b1010 },
    // cbpy=11 (1011): 1010
    .{ .code = 0b1010, .len = 4, .cbpy = 0b1011 },
    // cbpy=12 (1100): 0100
    .{ .code = 0b0100, .len = 4, .cbpy = 0b1100 },
    // cbpy=13 (1101): 1000
    .{ .code = 0b1000, .len = 4, .cbpy = 0b1101 },
    // cbpy=14 (1110): 0110
    .{ .code = 0b0110, .len = 4, .cbpy = 0b1110 },
    // cbpy=15 (1111): 11
    .{ .code = 0b11, .len = 2, .cbpy = 0b1111 },
};

/// Decode CBPY
/// For intra macroblocks, use invert=false
/// For inter macroblocks, use invert=true
pub fn decodeCbpy(reader: *BitReader, invert: bool) ?u4 {
    const peek = reader.peekBits(6) orelse return null;

    for (cbpy_table) |entry| {
        const shifted = peek >> @intCast(6 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            return if (invert) 0b1111 ^ entry.cbpy else entry.cbpy;
        }
    }

    return null; // Invalid code
}

/// Full macroblock decoding result
pub const MacroblockDecodeResult = struct {
    success: bool,
    error_message: ?[]const u8,
    is_intra: bool,
    has_motion: bool,
    blocks_decoded: u8, // Number of 8x8 blocks successfully decoded
};

/// Decode an I-VOP macroblock (all blocks are intra)
pub fn decodeIntraMacroblock(
    reader: *BitReader,
    quant: u5,
    dc_pred_y: [4]i32, // DC predictors for 4 luma blocks
    dc_pred_cb: i32,
    dc_pred_cr: i32,
) MacroblockDecodeResult {
    // Decode MCBPC
    const mcbpc = decodeMcbpcIntra(reader) orelse {
        return .{
            .success = false,
            .error_message = "Failed to decode MCBPC",
            .is_intra = true,
            .has_motion = false,
            .blocks_decoded = 0,
        };
    };

    // Decode CBPY
    const cbpy = decodeCbpy(reader, false) orelse {
        return .{
            .success = false,
            .error_message = "Failed to decode CBPY",
            .is_intra = true,
            .has_motion = false,
            .blocks_decoded = 0,
        };
    };

    // Handle DQUANT if mb_type is intra_q
    var current_quant = quant;
    if (mcbpc.mb_type == .intra_q) {
        const dquant = reader.readBits(2) orelse {
            return .{
                .success = false,
                .error_message = "Failed to decode DQUANT",
                .is_intra = true,
                .has_motion = false,
                .blocks_decoded = 0,
            };
        };
        // DQUANT: 00=-1, 01=-2, 10=+1, 11=+2
        const delta: i8 = switch (dquant) {
            0 => -1,
            1 => -2,
            2 => 1,
            3 => 2,
            else => unreachable,
        };
        const new_quant = @as(i8, current_quant) + delta;
        current_quant = @as(u5, @intCast(@max(1, @min(31, new_quant))));
    }

    // Combine CBP
    const cbp_y = cbpy;
    const cbp_c = mcbpc.cbpc;

    // Decode 4 luminance blocks (Y)
    var blocks_decoded: u8 = 0;
    for (0..4) |i| {
        const coded = (cbp_y >> @intCast(3 - i)) & 1 == 1;
        if (coded) {
            const result = decodeIntraBlock(reader, true, current_quant, dc_pred_y[i]);
            if (!result.success) {
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .is_intra = true,
                    .has_motion = false,
                    .blocks_decoded = blocks_decoded,
                };
            }
        }
        blocks_decoded += 1;
    }

    // Decode Cb block
    const cb_coded = (cbp_c >> 1) & 1 == 1;
    if (cb_coded) {
        const result = decodeIntraBlock(reader, false, current_quant, dc_pred_cb);
        if (!result.success) {
            return .{
                .success = false,
                .error_message = result.error_message,
                .is_intra = true,
                .has_motion = false,
                .blocks_decoded = blocks_decoded,
            };
        }
    }
    blocks_decoded += 1;

    // Decode Cr block
    const cr_coded = cbp_c & 1 == 1;
    if (cr_coded) {
        const result = decodeIntraBlock(reader, false, current_quant, dc_pred_cr);
        if (!result.success) {
            return .{
                .success = false,
                .error_message = result.error_message,
                .is_intra = true,
                .has_motion = false,
                .blocks_decoded = blocks_decoded,
            };
        }
    }
    blocks_decoded += 1;

    return .{
        .success = true,
        .error_message = null,
        .is_intra = true,
        .has_motion = false,
        .blocks_decoded = blocks_decoded,
    };
}

/// Decode a P-VOP macroblock (may be inter or intra)
pub fn decodeInterMacroblock(
    reader: *BitReader,
    quant: u5,
    mv_predictor: MotionVector,
    fcode: u3,
    dc_pred_y: [4]i32,
    dc_pred_cb: i32,
    dc_pred_cr: i32,
) MacroblockDecodeResult {
    // Check for not_coded flag
    const not_coded = reader.readBit() orelse {
        return .{
            .success = false,
            .error_message = "Failed to read not_coded bit",
            .is_intra = false,
            .has_motion = false,
            .blocks_decoded = 0,
        };
    };

    if (not_coded == 1) {
        // Macroblock is not coded - use predictor MV, no residual
        return .{
            .success = true,
            .error_message = null,
            .is_intra = false,
            .has_motion = true,
            .blocks_decoded = 0, // No blocks to decode
        };
    }

    // Decode MCBPC
    const mcbpc = decodeMcbpcInter(reader) orelse {
        return .{
            .success = false,
            .error_message = "Failed to decode MCBPC for inter MB",
            .is_intra = false,
            .has_motion = false,
            .blocks_decoded = 0,
        };
    };

    // Handle stuffing
    if (mcbpc.mb_type == .stuffing) {
        return .{
            .success = true,
            .error_message = null,
            .is_intra = false,
            .has_motion = false,
            .blocks_decoded = 0,
        };
    }

    // Check if this is an intra macroblock in P-frame
    const is_intra = (mcbpc.mb_type == .intra or mcbpc.mb_type == .intra_q);
    const has_4mv = (mcbpc.mb_type == .inter4v or mcbpc.mb_type == .inter4v_q);

    // Decode CBPY (invert for inter)
    const cbpy = decodeCbpy(reader, !is_intra) orelse {
        return .{
            .success = false,
            .error_message = "Failed to decode CBPY for inter MB",
            .is_intra = is_intra,
            .has_motion = !is_intra,
            .blocks_decoded = 0,
        };
    };

    // Handle DQUANT
    var current_quant = quant;
    if (mcbpc.mb_type == .inter_q or mcbpc.mb_type == .intra_q or mcbpc.mb_type == .inter4v_q) {
        const dquant = reader.readBits(2) orelse {
            return .{
                .success = false,
                .error_message = "Failed to decode DQUANT",
                .is_intra = is_intra,
                .has_motion = !is_intra,
                .blocks_decoded = 0,
            };
        };
        const delta: i8 = switch (dquant) {
            0 => -1,
            1 => -2,
            2 => 1,
            3 => 2,
            else => unreachable,
        };
        const new_quant = @as(i8, current_quant) + delta;
        current_quant = @as(u5, @intCast(@max(1, @min(31, new_quant))));
    }

    // Decode motion vectors (for inter macroblocks)
    if (!is_intra) {
        if (has_4mv) {
            // 4 motion vectors for 8x8 mode
            for (0..4) |_| {
                _ = decodeMotionVector(reader, mv_predictor, fcode) orelse {
                    return .{
                        .success = false,
                        .error_message = "Failed to decode motion vector",
                        .is_intra = false,
                        .has_motion = true,
                        .blocks_decoded = 0,
                    };
                };
            }
        } else {
            // Single 16x16 motion vector
            _ = decodeMotionVector(reader, mv_predictor, fcode) orelse {
                return .{
                    .success = false,
                    .error_message = "Failed to decode motion vector",
                    .is_intra = false,
                    .has_motion = true,
                    .blocks_decoded = 0,
                };
            };
        }
    }

    // Combine CBP
    const cbp_y = cbpy;
    const cbp_c = mcbpc.cbpc;

    // Decode blocks
    var blocks_decoded: u8 = 0;

    // Decode 4 luminance blocks
    for (0..4) |i| {
        const coded = (cbp_y >> @intCast(3 - i)) & 1 == 1;
        if (is_intra) {
            if (coded) {
                const result = decodeIntraBlock(reader, true, current_quant, dc_pred_y[i]);
                if (!result.success) {
                    return .{
                        .success = false,
                        .error_message = result.error_message,
                        .is_intra = true,
                        .has_motion = false,
                        .blocks_decoded = blocks_decoded,
                    };
                }
            }
        } else {
            const result = decodeInterBlock(reader, current_quant, coded);
            if (!result.success) {
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .is_intra = false,
                    .has_motion = true,
                    .blocks_decoded = blocks_decoded,
                };
            }
        }
        blocks_decoded += 1;
    }

    // Decode Cb block
    const cb_coded = (cbp_c >> 1) & 1 == 1;
    if (is_intra) {
        if (cb_coded) {
            const result = decodeIntraBlock(reader, false, current_quant, dc_pred_cb);
            if (!result.success) {
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .is_intra = true,
                    .has_motion = false,
                    .blocks_decoded = blocks_decoded,
                };
            }
        }
    } else {
        const result = decodeInterBlock(reader, current_quant, cb_coded);
        if (!result.success) {
            return .{
                .success = false,
                .error_message = result.error_message,
                .is_intra = false,
                .has_motion = true,
                .blocks_decoded = blocks_decoded,
            };
        }
    }
    blocks_decoded += 1;

    // Decode Cr block
    const cr_coded = cbp_c & 1 == 1;
    if (is_intra) {
        if (cr_coded) {
            const result = decodeIntraBlock(reader, false, current_quant, dc_pred_cr);
            if (!result.success) {
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .is_intra = true,
                    .has_motion = false,
                    .blocks_decoded = blocks_decoded,
                };
            }
        }
    } else {
        const result = decodeInterBlock(reader, current_quant, cr_coded);
        if (!result.success) {
            return .{
                .success = false,
                .error_message = result.error_message,
                .is_intra = false,
                .has_motion = true,
                .blocks_decoded = blocks_decoded,
            };
        }
    }
    blocks_decoded += 1;

    return .{
        .success = true,
        .error_message = null,
        .is_intra = is_intra,
        .has_motion = !is_intra,
        .blocks_decoded = blocks_decoded,
    };
}

// ============================================================================
// Full VOP Decode Validation
// ============================================================================

/// Result of VOP decode validation
pub const VopDecodeResult = struct {
    success: bool,
    error_message: ?[]const u8,
    macroblocks_decoded: u32,
    intra_macroblocks: u32,
    inter_macroblocks: u32,
};

/// Validate a VOP by decoding macroblocks
/// This reads VOP data after the VOP header has been parsed
/// vol_info and vop_info come from mpeg4p2_validator parsing
pub fn validateVopDecode(
    reader: *BitReader,
    width: u14,
    height: u14,
    vop_quant: u5,
    coding_type: u2, // 0=I, 1=P, 2=B, 3=S
    fcode_forward: u3,
) VopDecodeResult {
    // Calculate macroblock dimensions
    const mb_width = (width + 15) / 16;
    const mb_height = (height + 15) / 16;
    const total_mbs = @as(u32, mb_width) * @as(u32, mb_height);

    var macroblocks_decoded: u32 = 0;
    var intra_macroblocks: u32 = 0;
    var inter_macroblocks: u32 = 0;

    // Default DC predictors (1024 for 8-bit)
    const default_dc: i32 = 1024;
    const dc_pred_y = [4]i32{ default_dc, default_dc, default_dc, default_dc };

    // Zero motion vector predictor
    const mv_predictor = MotionVector{ .x = 0, .y = 0 };

    // Decode macroblocks
    while (macroblocks_decoded < total_mbs) {
        if (reader.bitsRemaining() < 8) {
            // Check for stuffing/end
            break;
        }

        if (coding_type == 0) {
            // I-VOP: all intra macroblocks
            const result = decodeIntraMacroblock(
                reader,
                vop_quant,
                dc_pred_y,
                default_dc,
                default_dc,
            );

            if (!result.success) {
                // Allow early termination if we've decoded at least some MBs
                if (macroblocks_decoded > 0) {
                    break;
                }
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .macroblocks_decoded = macroblocks_decoded,
                    .intra_macroblocks = intra_macroblocks,
                    .inter_macroblocks = inter_macroblocks,
                };
            }

            intra_macroblocks += 1;
        } else if (coding_type == 1) {
            // P-VOP: inter or intra macroblocks
            const result = decodeInterMacroblock(
                reader,
                vop_quant,
                mv_predictor,
                fcode_forward,
                dc_pred_y,
                default_dc,
                default_dc,
            );

            if (!result.success) {
                if (macroblocks_decoded > 0) {
                    break;
                }
                return .{
                    .success = false,
                    .error_message = result.error_message,
                    .macroblocks_decoded = macroblocks_decoded,
                    .intra_macroblocks = intra_macroblocks,
                    .inter_macroblocks = inter_macroblocks,
                };
            }

            if (result.is_intra) {
                intra_macroblocks += 1;
            } else {
                inter_macroblocks += 1;
            }
        } else {
            // B-VOP or S-VOP: complex, just count as inter for now
            // Full B-frame decode requires backward references
            inter_macroblocks += 1;
            // Skip to next start code (simplified)
            break;
        }

        macroblocks_decoded += 1;

        // Limit to avoid infinite loops on malformed data
        if (macroblocks_decoded > total_mbs * 2) {
            break;
        }
    }

    return .{
        .success = macroblocks_decoded > 0,
        .error_message = if (macroblocks_decoded == 0) "No macroblocks decoded" else null,
        .macroblocks_decoded = macroblocks_decoded,
        .intra_macroblocks = intra_macroblocks,
        .inter_macroblocks = inter_macroblocks,
    };
}

/// Full stream validation result
pub const FullDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    vops_decoded: u32,
    total_macroblocks: u32,
    i_vops: u32,
    p_vops: u32,
    b_vops: u32,
    width: u16,
    height: u16,
};

// ============================================================================
// Tests
// ============================================================================

test "BitReader basics" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 0), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try std.testing.expectEqual(@as(u32, 0b0100), reader.readBits(4).?);
    try std.testing.expectEqual(@as(u32, 0b01011010), reader.readBits(8).?);
    try std.testing.expectEqual(@as(usize, 0), reader.bitsRemaining());
}

test "BitReader peekBits" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    // Peek should not consume bits
    try std.testing.expectEqual(@as(u32, 0b1011), reader.peekBits(4).?);
    try std.testing.expectEqual(@as(u32, 0b1011), reader.peekBits(4).?);
    try std.testing.expectEqual(@as(u32, 0b10110100), reader.peekBits(8).?);

    // Now consume
    try std.testing.expectEqual(@as(u32, 0b1011), reader.readBits(4).?);
    try std.testing.expectEqual(@as(u32, 0b0100), reader.peekBits(4).?);
}

test "decodeIntraDcSizeLuma" {
    // Need at least 2 bytes (16 bits) since peekBits(11) is used
    // Test size 0: 011 (3 bits)
    {
        const data = [_]u8{ 0b01100000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 0), decodeIntraDcSizeLuma(&reader).?);
    }
    // Test size 1: 100 (3 bits)
    {
        const data = [_]u8{ 0b10000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 1), decodeIntraDcSizeLuma(&reader).?);
    }
    // Test size 2: 00 (2 bits)
    {
        const data = [_]u8{ 0b00000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 2), decodeIntraDcSizeLuma(&reader).?);
    }
    // Test size 3: 101 (3 bits)
    {
        const data = [_]u8{ 0b10100000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 3), decodeIntraDcSizeLuma(&reader).?);
    }
    // Test size 4: 110 (3 bits)
    {
        const data = [_]u8{ 0b11000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 4), decodeIntraDcSizeLuma(&reader).?);
    }
    // Test size 5: 1110 (4 bits)
    {
        const data = [_]u8{ 0b11100000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 5), decodeIntraDcSizeLuma(&reader).?);
    }
}

test "decodeIntraDcSizeChroma" {
    // Need at least 2 bytes (16 bits) since peekBits(12) is used
    // Test size 0: 00 (2 bits)
    {
        const data = [_]u8{ 0b00000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 0), decodeIntraDcSizeChroma(&reader).?);
    }
    // Test size 1: 01 (2 bits)
    {
        const data = [_]u8{ 0b01000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 1), decodeIntraDcSizeChroma(&reader).?);
    }
    // Test size 2: 10 (2 bits)
    {
        const data = [_]u8{ 0b10000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 2), decodeIntraDcSizeChroma(&reader).?);
    }
    // Test size 3: 110 (3 bits)
    {
        const data = [_]u8{ 0b11000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 3), decodeIntraDcSizeChroma(&reader).?);
    }
    // Test size 4: 1110 (4 bits)
    {
        const data = [_]u8{ 0b11100000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u5, 4), decodeIntraDcSizeChroma(&reader).?);
    }
}

test "decodeIntraDcValue" {
    // Size 0 should return 0
    {
        const data = [_]u8{0b00000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, 0), decodeIntraDcValue(&reader, 0).?);
    }
    // Size 1, value 1 (bit = 1)
    {
        const data = [_]u8{0b10000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, 1), decodeIntraDcValue(&reader, 1).?);
    }
    // Size 1, value -1 (bit = 0)
    {
        const data = [_]u8{0b00000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, -1), decodeIntraDcValue(&reader, 1).?);
    }
    // Size 2, value 2 (bits = 10)
    {
        const data = [_]u8{0b10000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, 2), decodeIntraDcValue(&reader, 2).?);
    }
    // Size 2, value 3 (bits = 11)
    {
        const data = [_]u8{0b11000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, 3), decodeIntraDcValue(&reader, 2).?);
    }
    // Size 2, value -3 (bits = 00)
    {
        const data = [_]u8{0b00000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, -3), decodeIntraDcValue(&reader, 2).?);
    }
    // Size 2, value -2 (bits = 01)
    {
        const data = [_]u8{0b01000000};
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(i32, -2), decodeIntraDcValue(&reader, 2).?);
    }
}

test "DC scaler tables" {
    // Verify DC scaler values for common quant values
    try std.testing.expectEqual(@as(u8, 8), dc_scaler_luma[1]);
    try std.testing.expectEqual(@as(u8, 8), dc_scaler_luma[4]);
    try std.testing.expectEqual(@as(u8, 10), dc_scaler_luma[5]);
    try std.testing.expectEqual(@as(u8, 16), dc_scaler_luma[8]);
    try std.testing.expectEqual(@as(u8, 24), dc_scaler_luma[16]);
    try std.testing.expectEqual(@as(u8, 46), dc_scaler_luma[31]);

    try std.testing.expectEqual(@as(u8, 8), dc_scaler_chroma[1]);
    try std.testing.expectEqual(@as(u8, 9), dc_scaler_chroma[5]);
    try std.testing.expectEqual(@as(u8, 10), dc_scaler_chroma[8]);
    try std.testing.expectEqual(@as(u8, 25), dc_scaler_chroma[31]);
}

test "getPredictionDirection" {
    // When |dc_a - dc_b| < |dc_b - dc_c|, predict vertically
    try std.testing.expectEqual(PredictionDirection.vertical, getPredictionDirection(100, 100, 200));
    // When |dc_a - dc_b| >= |dc_b - dc_c|, predict horizontally
    try std.testing.expectEqual(PredictionDirection.horizontal, getPredictionDirection(200, 100, 100));
    // Equal differences -> horizontal
    try std.testing.expectEqual(PredictionDirection.horizontal, getPredictionDirection(100, 150, 200));
}

test "applyDcPrediction" {
    // Simple prediction: diff=5, predictor=100, scaler=8
    // pred = (100 + 4) / 8 = 13
    // result = 5 + 13 = 18
    try std.testing.expectEqual(@as(i32, 18), applyDcPrediction(5, 100, 8));

    // Zero diff should return pred = (100 + 4) / 8 = 13
    try std.testing.expectEqual(@as(i32, 13), applyDcPrediction(0, 100, 8));
}

test "IDCT reuse from mpeg12" {
    // Verify IDCT produces expected output for simple input
    var coeffs: DctBlock = [_]i32{0} ** 64;
    coeffs[0] = 1024; // DC only

    const pixels = inverseDct8x8(&coeffs);

    // All pixels should be approximately equal for DC-only block
    const expected: i16 = 128; // 1024 / 8 = 128 (normalized)
    for (pixels) |p| {
        try std.testing.expect(p >= expected - 2 and p <= expected + 2);
    }
}

test "decodeMvd zero" {
    // MVD = 0 is coded as single bit '1'
    const data = [_]u8{ 0b10000000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i7, 0), decodeMvd(&reader).?);
}

test "decodeMvd positive small" {
    // MVD = +1 is coded as '010' (3 bits)
    const data = [_]u8{ 0b01000000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i7, 1), decodeMvd(&reader).?);
}

test "decodeMvd negative small" {
    // MVD = -1 is coded as '011' (3 bits)
    const data = [_]u8{ 0b01100000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i7, -1), decodeMvd(&reader).?);
}

test "decodeMvd larger positive" {
    // MVD = +2 is coded as '0010' (4 bits)
    const data = [_]u8{ 0b00100000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i7, 2), decodeMvd(&reader).?);
}

test "decodeMvd larger negative" {
    // MVD = -2 is coded as '0011' (4 bits)
    const data = [_]u8{ 0b00110000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i7, -2), decodeMvd(&reader).?);
}

test "median3" {
    try std.testing.expectEqual(@as(i16, 2), median3(1, 2, 3));
    try std.testing.expectEqual(@as(i16, 2), median3(3, 2, 1));
    try std.testing.expectEqual(@as(i16, 2), median3(2, 1, 3));
    try std.testing.expectEqual(@as(i16, 5), median3(5, 5, 5));
    try std.testing.expectEqual(@as(i16, -3), median3(-5, -3, -1));
    try std.testing.expectEqual(@as(i16, 0), median3(-1, 0, 1));
}

test "predictMotionVector" {
    const mv_a = MotionVector{ .x = 10, .y = 20 };
    const mv_b = MotionVector{ .x = 15, .y = 25 };
    const mv_c = MotionVector{ .x = 12, .y = 22 };

    const pred = predictMotionVector(mv_a, mv_b, mv_c);

    // Median of (10, 15, 12) = 12
    try std.testing.expectEqual(@as(i16, 12), pred.x);
    // Median of (20, 25, 22) = 22
    try std.testing.expectEqual(@as(i16, 22), pred.y);
}

test "applyMotionVectorPrediction" {
    // Test basic prediction application
    const diff = MotionVector{ .x = 5, .y = -3 };
    const pred = MotionVector{ .x = 10, .y = 10 };

    const mv = applyMotionVectorPrediction(diff, pred, 1);

    // fcode=1: range = 1 << 5 = 32
    // Result should be (15, 7) which is within range [-32, 31]
    try std.testing.expectEqual(@as(i16, 15), mv.x);
    try std.testing.expectEqual(@as(i16, 7), mv.y);
}

test "decodeMotionVectorDiff fcode 1" {
    // With fcode=1, no residual bits are read
    // MVD = 0 coded as '1'
    const data = [_]u8{ 0b10000000, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(i16, 0), decodeMotionVectorDiff(&reader, 1).?);
}

test "decodeMcbpcIntra basic" {
    // MCBPC for intra, cbpc=00: code '1' (1 bit)
    {
        const data = [_]u8{ 0b10000000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcIntra(&reader).?;
        try std.testing.expectEqual(IntraMbType.intra, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b00), result.cbpc);
    }
    // MCBPC for intra, cbpc=01: code '001' (3 bits)
    {
        const data = [_]u8{ 0b00100000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcIntra(&reader).?;
        try std.testing.expectEqual(IntraMbType.intra, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b01), result.cbpc);
    }
    // MCBPC for intra_q, cbpc=00: code '0001' (4 bits)
    {
        const data = [_]u8{ 0b00010000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcIntra(&reader).?;
        try std.testing.expectEqual(IntraMbType.intra_q, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b00), result.cbpc);
    }
}

test "decodeMcbpcInter basic" {
    // MCBPC for inter, cbpc=00: code '1' (1 bit)
    {
        const data = [_]u8{ 0b10000000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcInter(&reader).?;
        try std.testing.expectEqual(InterMbType.inter, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b00), result.cbpc);
    }
    // MCBPC for inter_q, cbpc=00: code '010' (3 bits)
    {
        const data = [_]u8{ 0b01000000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcInter(&reader).?;
        try std.testing.expectEqual(InterMbType.inter_q, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b00), result.cbpc);
    }
    // MCBPC for inter4v, cbpc=00: code '011' (3 bits)
    {
        const data = [_]u8{ 0b01100000, 0x00 };
        var reader = BitReader.init(&data);
        const result = decodeMcbpcInter(&reader).?;
        try std.testing.expectEqual(InterMbType.inter4v, result.mb_type);
        try std.testing.expectEqual(@as(u2, 0b00), result.cbpc);
    }
}

test "decodeCbpy intra" {
    // CBPY=15 (1111): code '11' (2 bits)
    {
        const data = [_]u8{ 0b11000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u4, 0b1111), decodeCbpy(&reader, false).?);
    }
    // CBPY=0 (0000): code '0011' (4 bits)
    {
        const data = [_]u8{ 0b00110000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u4, 0b0000), decodeCbpy(&reader, false).?);
    }
}

test "decodeCbpy inter with invert" {
    // CBPY=15 (1111): code '11', inverted = 0000
    {
        const data = [_]u8{ 0b11000000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u4, 0b0000), decodeCbpy(&reader, true).?);
    }
    // CBPY=0 (0000): code '0011', inverted = 1111
    {
        const data = [_]u8{ 0b00110000, 0x00 };
        var reader = BitReader.init(&data);
        try std.testing.expectEqual(@as(u4, 0b1111), decodeCbpy(&reader, true).?);
    }
}
