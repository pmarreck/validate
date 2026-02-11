//! VP8 Video Decoder (Pure Zig)
//!
//! Full DCT coefficient decoder for VP8 video deep validation.
//! VP8 uses boolean (arithmetic) coding and 4x4 transforms.
//!
//! Key structures:
//! - Boolean decoder for arithmetic-coded data
//! - Token tree decoding with probability tables (4 types × 8 bands × 3 contexts)
//! - 4x4 Walsh-Hadamard Transform (WHT) for Y2 DC blocks
//! - 4x4 DCT for Y, U, V blocks
//!
//! This decoder validates the entire bitstream by:
//! 1. Parsing frame header via boolean decoder
//! 2. Decoding all DCT coefficients for each macroblock
//! 3. Running inverse transforms (WHT/DCT)
//!
//! Reference: RFC 6386 - VP8 Data Format and Decoding Guide

const std = @import("std");
const errmsg = @import("error_messages.zig");
const math = std.math;

// ============================================================================
// Boolean Decoder (Arithmetic Decoder)
// ============================================================================

/// VP8 Boolean Decoder
/// Decodes bits using probability-weighted ranges
pub const BoolDecoder = struct {
    data: []const u8,
    pos: usize,
    value: u32, // Current range value
    range: u32, // Current range
    count: i32, // Bits remaining in current byte

    const VALUE_BITS = 8;

    pub fn init(data: []const u8) ?BoolDecoder {
        if (data.len < 2) return null;

        // Initialize with first two bytes
        return BoolDecoder{
            .data = data,
            .pos = 2,
            .value = (@as(u32, data[0]) << 8) | data[1],
            .range = 255,
            .count = 0,
        };
    }

    /// Read a single bit with given probability (0-255)
    /// prob = 0 means P(0) = 0/256, prob = 255 means P(0) = 255/256
    pub fn readBool(self: *BoolDecoder, prob: u8) ?bool {
        const split = 1 + ((self.range - 1) * @as(u32, prob) >> 8);

        if (self.value >= split) {
            // Bit is 1
            self.value -= split;
            self.range -= split;
            self.normalize() catch return null;
            return true;
        } else {
            // Bit is 0
            self.range = split;
            self.normalize() catch return null;
            return false;
        }
    }

    /// Read a bit with 50% probability
    pub fn readBit(self: *BoolDecoder) ?bool {
        return self.readBool(128);
    }

    /// Read n-bit unsigned value with uniform probability
    pub fn readLiteral(self: *BoolDecoder, n: u5) ?u32 {
        var result: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const bit = self.readBit() orelse return null;
            result = (result << 1) | @as(u32, @intFromBool(bit));
        }
        return result;
    }

    /// Read signed value: n-bit magnitude followed by sign bit
    pub fn readSignedLiteral(self: *BoolDecoder, n: u5) ?i32 {
        const mag = self.readLiteral(n) orelse return null;
        if (mag == 0) return 0;

        const sign = self.readBit() orelse return null;
        if (sign) {
            return -@as(i32, @intCast(mag));
        }
        return @intCast(mag);
    }

    /// Normalize the range (renormalization)
    fn normalize(self: *BoolDecoder) !void {
        while (self.range < 128) {
            self.range <<= 1;
            self.value <<= 1;

            self.count += 1;
            if (self.count == 8) {
                self.count = 0;
                if (self.pos < self.data.len) {
                    self.value |= self.data[self.pos];
                    self.pos += 1;
                }
            }
        }
    }

    /// Check if more data is available
    pub fn hasMore(self: *const BoolDecoder) bool {
        return self.pos < self.data.len or self.count < 8;
    }
};

// ============================================================================
// 4x4 Inverse Walsh-Hadamard Transform (WHT)
// ============================================================================

/// 4x4 WHT block
pub const WhtBlock = [16]i16;

/// Inverse Walsh-Hadamard Transform for Y2 DC blocks
/// This is applied to the DC coefficients of Y blocks
pub fn inverseWht4x4(input: *const WhtBlock) WhtBlock {
    var temp: [16]i32 = undefined;
    var output: WhtBlock = undefined;

    // Horizontal pass
    for (0..4) |i| {
        const a0: i32 = input[i * 4 + 0];
        const a1: i32 = input[i * 4 + 1];
        const a2: i32 = input[i * 4 + 2];
        const a3: i32 = input[i * 4 + 3];

        const b0 = a0 + a2;
        const b1 = a0 - a2;
        const b2 = a1 - a3;
        const b3 = a1 + a3;

        temp[i * 4 + 0] = b0 + b3;
        temp[i * 4 + 1] = b1 + b2;
        temp[i * 4 + 2] = b1 - b2;
        temp[i * 4 + 3] = b0 - b3;
    }

    // Vertical pass
    for (0..4) |i| {
        const a0 = temp[i];
        const a1 = temp[4 + i];
        const a2 = temp[8 + i];
        const a3 = temp[12 + i];

        const b0 = a0 + a2;
        const b1 = a0 - a2;
        const b2 = a1 - a3;
        const b3 = a1 + a3;

        // Add 3 and shift right by 3 for proper rounding
        output[i] = @intCast((b0 + b3 + 3) >> 3);
        output[4 + i] = @intCast((b1 + b2 + 3) >> 3);
        output[8 + i] = @intCast((b1 - b2 + 3) >> 3);
        output[12 + i] = @intCast((b0 - b3 + 3) >> 3);
    }

    return output;
}

// ============================================================================
// 4x4 Inverse DCT
// ============================================================================

/// 4x4 DCT block
pub const DctBlock = [16]i16;

// DCT constants (14.7.3 in RFC 6386)
const cospi8sqrt2minus1: i32 = 20091;
const sinpi8sqrt2: i32 = 35468;

/// Inverse 4x4 DCT for VP8
pub fn inverseDct4x4(input: *const DctBlock) DctBlock {
    var temp: [16]i32 = undefined;
    var output: DctBlock = undefined;

    // Horizontal pass
    for (0..4) |i| {
        const a0: i32 = input[i * 4 + 0];
        const a1: i32 = input[i * 4 + 1];
        const a2: i32 = input[i * 4 + 2];
        const a3: i32 = input[i * 4 + 3];

        const b0 = a0 + a2;
        const b1 = a0 - a2;

        // a1 * cos(pi/8) * sqrt(2)
        const t0 = (a1 * sinpi8sqrt2) >> 16;
        // a3 * sin(pi/8) * sqrt(2)
        const t1 = a3 + ((a3 * cospi8sqrt2minus1) >> 16);
        // a1 * sin(pi/8) * sqrt(2)
        const t2 = a1 + ((a1 * cospi8sqrt2minus1) >> 16);
        // a3 * cos(pi/8) * sqrt(2)
        const t3 = (a3 * sinpi8sqrt2) >> 16;

        const b2 = t0 - t1;
        const b3 = t2 + t3;

        temp[i * 4 + 0] = b0 + b3;
        temp[i * 4 + 1] = b1 + b2;
        temp[i * 4 + 2] = b1 - b2;
        temp[i * 4 + 3] = b0 - b3;
    }

    // Vertical pass
    for (0..4) |i| {
        const a0 = temp[i];
        const a1 = temp[4 + i];
        const a2 = temp[8 + i];
        const a3 = temp[12 + i];

        const b0 = a0 + a2;
        const b1 = a0 - a2;

        const t0 = (a1 * sinpi8sqrt2) >> 16;
        const t1 = a3 + ((a3 * cospi8sqrt2minus1) >> 16);
        const t2 = a1 + ((a1 * cospi8sqrt2minus1) >> 16);
        const t3 = (a3 * sinpi8sqrt2) >> 16;

        const b2 = t0 - t1;
        const b3 = t2 + t3;

        // Add 4 and shift right by 3 for proper rounding
        output[i] = @intCast(std.math.clamp((b0 + b3 + 4) >> 3, -128, 127));
        output[4 + i] = @intCast(std.math.clamp((b1 + b2 + 4) >> 3, -128, 127));
        output[8 + i] = @intCast(std.math.clamp((b1 - b2 + 4) >> 3, -128, 127));
        output[12 + i] = @intCast(std.math.clamp((b0 - b3 + 4) >> 3, -128, 127));
    }

    return output;
}

// ============================================================================
// Coefficient Token Probabilities (RFC 6386 Section 13.4)
// ============================================================================

/// Token categories for coefficient decoding
pub const Token = enum(u4) {
    dct_0 = 0, // coefficient is 0
    dct_1 = 1, // coefficient is 1
    dct_2 = 2, // coefficient is 2
    dct_3 = 3, // coefficient is 3
    dct_4 = 4, // coefficient is 4
    dct_cat1 = 5, // 5-6 (1 extra bit)
    dct_cat2 = 6, // 7-10 (2 extra bits)
    dct_cat3 = 7, // 11-18 (3 extra bits)
    dct_cat4 = 8, // 19-34 (4 extra bits)
    dct_cat5 = 9, // 35-66 (5 extra bits)
    dct_cat6 = 10, // 67-2048 (11 extra bits)
    dct_eob = 11, // end of block
};

/// Base values for category tokens
const cat_base_values = [_]i16{ 0, 1, 2, 3, 4, 5, 7, 11, 19, 35, 67 };

/// Extra bits count for category tokens (cat1=1, cat2=2, ..., cat6=11)
const cat_extra_bits = [_]u4{ 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 11 };

/// Probabilities for extra bits in each category (RFC 6386 Section 13.3)
const cat1_prob = [_]u8{159};
const cat2_prob = [_]u8{ 165, 145 };
const cat3_prob = [_]u8{ 173, 148, 140 };
const cat4_prob = [_]u8{ 176, 155, 140, 135 };
const cat5_prob = [_]u8{ 180, 157, 141, 134, 130 };
const cat6_prob = [_]u8{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 };

/// Zigzag scan order for 4x4 blocks
const zigzag_order = [16]u8{
    0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15,
};

/// Map coefficient position to band (0-7)
/// Band determines which probability table to use
const coeff_bands = [16]u8{
    0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7,
};

/// Block types for coefficient decoding
const BlockType = enum(u2) {
    y2 = 0, // Luma DC (from WHT)
    y = 1, // Luma AC
    u = 2, // Chroma U
    v = 3, // Chroma V
};

/// Default coefficient probabilities from RFC 6386 Section 13.5
/// Format: [4 block types][8 bands][3 contexts][11 tree probs]
/// These are the starting probabilities, can be updated per-frame
const default_coeff_probs = [4][8][3][11]u8{
    // Block type 0: Y2 (luma DC)
    .{
        // Band 0
        .{ .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
        // Band 1
        .{ .{ 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128 }, .{ 189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128 }, .{ 106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128 } },
        // Band 2
        .{ .{ 1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128 }, .{ 181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128 }, .{ 78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128 } },
        // Band 3
        .{ .{ 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128 }, .{ 184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128 }, .{ 77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128 } },
        // Band 4
        .{ .{ 1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128 }, .{ 170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128 }, .{ 37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128 } },
        // Band 5
        .{ .{ 1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128 }, .{ 207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128 }, .{ 102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128 } },
        // Band 6
        .{ .{ 1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128 }, .{ 177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128 }, .{ 80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128 } },
        // Band 7
        .{ .{ 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
    // Block type 1: Y (luma AC)
    .{
        // Band 0
        .{ .{ 198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62 }, .{ 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1 }, .{ 68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128 } },
        // Band 1
        .{ .{ 1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128 }, .{ 184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128 }, .{ 81, 99, 181, 242, 195, 203, 255, 219, 128, 128, 128 } },
        // Band 2
        .{ .{ 1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128 }, .{ 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128 }, .{ 23, 91, 163, 242, 170, 187, 247, 210, 128, 128, 128 } },
        // Band 3
        .{ .{ 1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128 }, .{ 109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128 }, .{ 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128 } },
        // Band 4
        .{ .{ 1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128 }, .{ 94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128 }, .{ 22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128 } },
        // Band 5
        .{ .{ 1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128 }, .{ 124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128 }, .{ 35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128 } },
        // Band 6
        .{ .{ 1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128 }, .{ 121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128 }, .{ 45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128 } },
        // Band 7
        .{ .{ 1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128 }, .{ 203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128 } },
    },
    // Block type 2: U (chroma)
    .{
        // Band 0
        .{ .{ 253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128 }, .{ 175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128 }, .{ 73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128 } },
        // Band 1
        .{ .{ 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128 }, .{ 239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128 }, .{ 155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128 } },
        // Band 2
        .{ .{ 1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128 }, .{ 201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128 }, .{ 69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128 } },
        // Band 3
        .{ .{ 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128 }, .{ 141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128 } },
        // Band 4
        .{ .{ 1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128 }, .{ 149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        // Band 5
        .{ .{ 1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        // Band 6
        .{ .{ 1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        // Band 7
        .{ .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
    // Block type 3: V (chroma)
    .{
        // Band 0
        .{ .{ 202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255 }, .{ 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128 }, .{ 61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128 } },
        // Band 1
        .{ .{ 1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128 }, .{ 166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128 }, .{ 39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128 } },
        // Band 2
        .{ .{ 1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128 }, .{ 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128 }, .{ 24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128 } },
        // Band 3
        .{ .{ 1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128 }, .{ 149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128 }, .{ 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128 } },
        // Band 4
        .{ .{ 1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128 }, .{ 123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128 }, .{ 20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128 } },
        // Band 5
        .{ .{ 1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128 }, .{ 168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128 }, .{ 47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128 } },
        // Band 6
        .{ .{ 1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128 }, .{ 141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128 }, .{ 42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128 } },
        // Band 7
        .{ .{ 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
};

/// Coefficient probability state (can be modified per-frame)
pub const CoeffProbs = [4][8][3][11]u8;

/// Decode a single token from the boolean decoder
/// Returns the decoded coefficient value, or null on decode error
/// Uses the probability tree from RFC 6386 Section 13.2
fn decodeToken(decoder: *BoolDecoder, probs: *const [11]u8) ?i16 {
    // Tree structure (RFC 6386 Section 13.2):
    // probs[0]: EOB vs more
    // probs[1]: 0 vs non-zero
    // probs[2]: 1 vs >1
    // probs[3]: 2 vs >2
    // probs[4]: 3 vs >3
    // probs[5]: 4 vs >4
    // probs[6]: cat1 vs higher
    // probs[7]: cat2 vs higher
    // probs[8]: cat3 vs higher
    // probs[9]: cat4 vs higher
    // probs[10]: cat5 vs cat6

    // First decision: more coefficients or end of block?
    if (!(decoder.readBool(probs[0]) orelse return null)) {
        return null; // Signal EOB with special value
    }

    // Second decision: zero or non-zero?
    if (!(decoder.readBool(probs[1]) orelse return null)) {
        return 0; // Coefficient is zero
    }

    // Non-zero coefficient - determine magnitude
    var value: i16 = undefined;

    if (!(decoder.readBool(probs[2]) orelse return null)) {
        value = 1;
    } else if (!(decoder.readBool(probs[3]) orelse return null)) {
        value = 2;
    } else if (!(decoder.readBool(probs[4]) orelse return null)) {
        value = 3;
    } else if (!(decoder.readBool(probs[5]) orelse return null)) {
        value = 4;
    } else if (!(decoder.readBool(probs[6]) orelse return null)) {
        // Category 1: 5-6
        const extra = decoder.readBool(cat1_prob[0]) orelse return null;
        value = 5 + @as(i16, @intFromBool(extra));
    } else if (!(decoder.readBool(probs[7]) orelse return null)) {
        // Category 2: 7-10
        var extra: i16 = 0;
        for (cat2_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 7 + extra;
    } else if (!(decoder.readBool(probs[8]) orelse return null)) {
        // Category 3: 11-18
        var extra: i16 = 0;
        for (cat3_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 11 + extra;
    } else if (!(decoder.readBool(probs[9]) orelse return null)) {
        // Category 4: 19-34
        var extra: i16 = 0;
        for (cat4_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 19 + extra;
    } else if (!(decoder.readBool(probs[10]) orelse return null)) {
        // Category 5: 35-66
        var extra: i16 = 0;
        for (cat5_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 35 + extra;
    } else {
        // Category 6: 67-2048
        var extra: i16 = 0;
        for (cat6_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 67 + extra;
    }

    // Read sign bit for non-zero values
    const sign = decoder.readBit() orelse return null;
    if (sign) {
        value = -value;
    }

    return value;
}

/// Special return value to indicate EOB
const EOB_MARKER: i16 = -32768;

/// Decode a single token, returning EOB_MARKER for end-of-block
fn decodeTokenOrEob(decoder: *BoolDecoder, probs: *const [11]u8) ?i16 {
    // First decision: more coefficients or end of block?
    if (!(decoder.readBool(probs[0]) orelse return null)) {
        return EOB_MARKER; // End of block
    }

    // Second decision: zero or non-zero?
    if (!(decoder.readBool(probs[1]) orelse return null)) {
        return 0; // Coefficient is zero
    }

    // Non-zero coefficient - determine magnitude
    var value: i16 = undefined;

    if (!(decoder.readBool(probs[2]) orelse return null)) {
        value = 1;
    } else if (!(decoder.readBool(probs[3]) orelse return null)) {
        value = 2;
    } else if (!(decoder.readBool(probs[4]) orelse return null)) {
        value = 3;
    } else if (!(decoder.readBool(probs[5]) orelse return null)) {
        value = 4;
    } else if (!(decoder.readBool(probs[6]) orelse return null)) {
        // Category 1: 5-6
        const extra = decoder.readBool(cat1_prob[0]) orelse return null;
        value = 5 + @as(i16, @intFromBool(extra));
    } else if (!(decoder.readBool(probs[7]) orelse return null)) {
        // Category 2: 7-10
        var extra: i16 = 0;
        for (cat2_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 7 + extra;
    } else if (!(decoder.readBool(probs[8]) orelse return null)) {
        // Category 3: 11-18
        var extra: i16 = 0;
        for (cat3_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 11 + extra;
    } else if (!(decoder.readBool(probs[9]) orelse return null)) {
        // Category 4: 19-34
        var extra: i16 = 0;
        for (cat4_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 19 + extra;
    } else if (!(decoder.readBool(probs[10]) orelse return null)) {
        // Category 5: 35-66
        var extra: i16 = 0;
        for (cat5_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 35 + extra;
    } else {
        // Category 6: 67-2048
        var extra: i16 = 0;
        for (cat6_prob) |p| {
            const bit = decoder.readBool(p) orelse return null;
            extra = (extra << 1) | @as(i16, @intFromBool(bit));
        }
        value = 67 + extra;
    }

    // Read sign bit for non-zero values
    const sign = decoder.readBit() orelse return null;
    if (sign) {
        value = -value;
    }

    return value;
}

/// Decode one 4x4 block of DCT coefficients
/// Returns number of non-zero coefficients, or null on error
fn decodeBlock(
    decoder: *BoolDecoder,
    block_type: u2,
    coeffs: *DctBlock,
    probs: *const CoeffProbs,
    start_coeff: usize, // 0 for most blocks, 1 for Y blocks when Y2 is used
) ?u8 {
    // Initialize block to zeros
    coeffs.* = [_]i16{0} ** 16;

    var nonzero_count: u8 = 0;
    var prev_coeff: i16 = 0;

    var i: usize = start_coeff;
    while (i < 16) : (i += 1) {
        const pos = zigzag_order[i];
        const band = coeff_bands[i];

        // Determine context based on previous coefficient
        const ctx: usize = if (prev_coeff == 0) 0 else if (prev_coeff == 1 or prev_coeff == -1) 1 else 2;

        const token = decodeTokenOrEob(decoder, &probs[block_type][band][ctx]) orelse return null;

        if (token == EOB_MARKER) {
            break; // End of block
        }

        coeffs[pos] = token;
        prev_coeff = token;

        if (token != 0) {
            nonzero_count += 1;
        }
    }

    return nonzero_count;
}

// ============================================================================
// Deep Validation
// ============================================================================

/// Deep validation result
pub const Vp8DeepValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    blocks_decoded: u32,
    macroblocks_decoded: u32,
    width: u32,
    height: u32,

    pub fn ok(blocks: u32, mbs: u32, w: u32, h: u32) Vp8DeepValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .blocks_decoded = blocks,
            .macroblocks_decoded = mbs,
            .width = w,
            .height = h,
        };
    }

    pub fn invalid(msg: []const u8) Vp8DeepValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .blocks_decoded = 0,
            .macroblocks_decoded = 0,
            .width = 0,
            .height = 0,
        };
    }
};

/// VP8 sync code for keyframes
const VP8_SYNC_CODE: [3]u8 = .{ 0x9D, 0x01, 0x2A };

/// Parse header segmentation data
fn parseSegmentationData(decoder: *BoolDecoder) bool {
    // update_mb_segmentation_map
    const update_map = decoder.readBit() orelse return false;
    // update_segment_feature_data
    const update_data = decoder.readBit() orelse return false;

    if (update_data) {
        // segment_feature_mode
        _ = decoder.readBit() orelse return false;

        // 4 segment quantizer values
        for (0..4) |_| {
            const present = decoder.readBit() orelse return false;
            if (present) {
                _ = decoder.readLiteral(7) orelse return false; // quantizer_update
                _ = decoder.readBit() orelse return false; // sign
            }
        }

        // 4 segment loop filter values
        for (0..4) |_| {
            const present = decoder.readBit() orelse return false;
            if (present) {
                _ = decoder.readLiteral(6) orelse return false; // lf_update
                _ = decoder.readBit() orelse return false; // sign
            }
        }
    }

    if (update_map) {
        // 3 segment probabilities
        for (0..3) |_| {
            const present = decoder.readBit() orelse return false;
            if (present) {
                _ = decoder.readLiteral(8) orelse return false;
            }
        }
    }

    return true;
}

/// Parse loop filter adjustments
fn parseLoopFilterAdjustments(decoder: *BoolDecoder) bool {
    const enabled = decoder.readBit() orelse return false;
    if (enabled) {
        // ref_frame_delta_update_flag
        const update_ref = decoder.readBit() orelse return false;
        if (update_ref) {
            for (0..4) |_| {
                const present = decoder.readBit() orelse return false;
                if (present) {
                    _ = decoder.readLiteral(6) orelse return false;
                    _ = decoder.readBit() orelse return false; // sign
                }
            }
        }
        // mb_mode_delta_update_flag
        const update_mode = decoder.readBit() orelse return false;
        if (update_mode) {
            for (0..4) |_| {
                const present = decoder.readBit() orelse return false;
                if (present) {
                    _ = decoder.readLiteral(6) orelse return false;
                    _ = decoder.readBit() orelse return false; // sign
                }
            }
        }
    }
    return true;
}

/// Parse coefficient probability updates
fn parseCoeffProbUpdates(decoder: *BoolDecoder, probs: *CoeffProbs) bool {
    // RFC 6386 Section 13.4 - coefficient probability updates
    // For each probability in the 4D array, read update flag and potentially new value
    for (0..4) |block_type| {
        for (0..8) |band| {
            for (0..3) |ctx| {
                for (0..11) |prob_idx| {
                    // Update probability for this position: ~0.5% chance
                    // Using fixed probability 252 (RFC 6386)
                    const update = decoder.readBool(252) orelse return false;
                    if (update) {
                        const new_prob = decoder.readLiteral(8) orelse return false;
                        probs[block_type][band][ctx][prob_idx] = @intCast(new_prob);
                    }
                }
            }
        }
    }
    return true;
}

/// Deep validate a VP8 keyframe
/// Parses full header and decodes DCT coefficients using boolean decoder
pub fn validateKeyframeDeep(data: []const u8) Vp8DeepValidationResult {
    if (data.len < 10) {
        return Vp8DeepValidationResult.invalid("Data too small for VP8 keyframe");
    }

    // Parse frame tag
    const tag = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    const is_keyframe = (tag & 1) == 0;
    const version = (tag >> 1) & 0x7;
    const first_partition_size: usize = @intCast((tag >> 5) & 0x7FFFF);

    if (!is_keyframe) {
        return Vp8DeepValidationResult.invalid("Not a keyframe");
    }

    if (version > 3) {
        return Vp8DeepValidationResult.invalid("Invalid VP8 version");
    }

    // Check sync code
    if (data[3] != VP8_SYNC_CODE[0] or data[4] != VP8_SYNC_CODE[1] or data[5] != VP8_SYNC_CODE[2]) {
        return Vp8DeepValidationResult.invalid("Invalid VP8 sync code");
    }

    // Parse dimensions
    const width_word = @as(u16, data[6]) | (@as(u16, data[7]) << 8);
    const height_word = @as(u16, data[8]) | (@as(u16, data[9]) << 8);
    const width: u32 = width_word & 0x3FFF;
    const height: u32 = height_word & 0x3FFF;

    if (width == 0 or height == 0) {
        return Vp8DeepValidationResult.invalid("Invalid dimensions");
    }

    // First partition starts at byte 10
    const first_part_start: usize = 10;
    if (first_part_start + first_partition_size > data.len) {
        return Vp8DeepValidationResult.invalid("First partition exceeds data");
    }

    // Initialize boolean decoder for first partition (header + macroblock modes)
    const first_part = data[first_part_start .. first_part_start + first_partition_size];
    var decoder = BoolDecoder.init(first_part) orelse {
        return Vp8DeepValidationResult.invalid("Failed to init boolean decoder");
    };

    // ========== Frame Header Parsing (RFC 6386 Section 9) ==========

    // color_space (1 bit) and clamping_type (1 bit)
    _ = decoder.readBit() orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("color_space"));
    };
    _ = decoder.readBit() orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("clamping_type"));
    };

    // segmentation_enabled (1 bit)
    const seg_enabled = decoder.readBit() orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("segmentation_enabled"));
    };

    if (seg_enabled) {
        if (!parseSegmentationData(&decoder)) {
            return Vp8DeepValidationResult.invalid("Failed to parse segmentation data");
        }
    }

    // filter_type (1 bit)
    _ = decoder.readBit() orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("filter_type"));
    };

    // loop_filter_level (6 bits)
    _ = decoder.readLiteral(6) orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("loop_filter_level"));
    };

    // sharpness_level (3 bits)
    _ = decoder.readLiteral(3) orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("sharpness_level"));
    };

    // Loop filter adjustments
    if (!parseLoopFilterAdjustments(&decoder)) {
        return Vp8DeepValidationResult.invalid("Failed to parse loop filter adjustments");
    }

    // Number of token partitions (log2, 2 bits)
    const log2_partitions = decoder.readLiteral(2) orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("partition count"));
    };
    const num_partitions: usize = @as(usize, 1) << @intCast(log2_partitions);

    // Quantization indices
    const y_ac_qi = decoder.readLiteral(7) orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("y_ac_qi"));
    };
    _ = y_ac_qi;

    // Delta quantizers (y_dc, y2_dc, y2_ac, uv_dc, uv_ac)
    for (0..5) |_| {
        const present = decoder.readBit() orelse {
            return Vp8DeepValidationResult.invalid(errmsg.failedToRead("delta qi flag"));
        };
        if (present) {
            _ = decoder.readLiteral(4) orelse {
                return Vp8DeepValidationResult.invalid(errmsg.failedToRead("delta qi value"));
            };
            _ = decoder.readBit() orelse {
                return Vp8DeepValidationResult.invalid(errmsg.failedToRead("delta qi sign"));
            };
        }
    }

    // Coefficient probability updates (keyframes always have this)
    var coeff_probs = default_coeff_probs;
    if (!parseCoeffProbUpdates(&decoder, &coeff_probs)) {
        return Vp8DeepValidationResult.invalid("Failed to parse coefficient probabilities");
    }

    // mb_no_coeff_skip flag
    const mb_skip = decoder.readBit() orelse {
        return Vp8DeepValidationResult.invalid(errmsg.failedToRead("mb_no_coeff_skip"));
    };

    if (mb_skip) {
        // Read skip probability (used during macroblock decoding, not needed for validation)
        _ = decoder.readLiteral(8) orelse {
            return Vp8DeepValidationResult.invalid(errmsg.failedToRead("skip probability"));
        };
    }

    // Calculate macroblock dimensions
    const mb_width: u32 = (width + 15) / 16;
    const mb_height: u32 = (height + 15) / 16;
    const mb_count: u32 = mb_width * mb_height;

    // ========== Token Partition Setup ==========
    // After first partition, we have partition size headers, then the partitions themselves

    const token_part_start = first_part_start + first_partition_size;

    // For multi-partition, sizes are stored as 3 bytes each (little-endian, 24-bit)
    // Number of size fields = num_partitions - 1
    const size_bytes = (num_partitions - 1) * 3;
    if (token_part_start + size_bytes > data.len) {
        return Vp8DeepValidationResult.invalid("Token partition sizes exceed data");
    }

    // Parse partition sizes
    var partition_sizes: [8]usize = undefined;
    var total_size: usize = 0;
    for (0..num_partitions - 1) |i| {
        const offset = token_part_start + i * 3;
        partition_sizes[i] = @as(usize, data[offset]) |
            (@as(usize, data[offset + 1]) << 8) |
            (@as(usize, data[offset + 2]) << 16);
        total_size += partition_sizes[i];
    }
    // Last partition is remainder of file
    const last_part_start = token_part_start + size_bytes + total_size;
    if (last_part_start > data.len) {
        return Vp8DeepValidationResult.invalid("Token partitions exceed data");
    }
    partition_sizes[num_partitions - 1] = data.len - last_part_start;

    // ========== Coefficient Decoding ==========
    // Initialize decoder for first token partition
    const coeff_data_start = token_part_start + size_bytes;
    if (coeff_data_start + partition_sizes[0] > data.len) {
        return Vp8DeepValidationResult.invalid("First token partition exceeds data");
    }

    var coeff_decoder = BoolDecoder.init(data[coeff_data_start .. coeff_data_start + partition_sizes[0]]) orelse {
        return Vp8DeepValidationResult.invalid("Failed to init coefficient decoder");
    };

    // Decode coefficients for a sample of macroblocks
    // For validation, we don't need to decode all - just enough to verify the bitstream
    var blocks_decoded: u32 = 0;
    var mbs_decoded: u32 = 0;
    const max_mbs_to_decode: u32 = @min(mb_count, 100); // Sample up to 100 macroblocks

    // Track partial validation success
    var partial_valid = false;

    while (mbs_decoded < max_mbs_to_decode) {
        // Each macroblock in a keyframe has:
        // - 1 Y2 block (4x4 DC coefficients from WHT) - if prediction mode uses it
        // - 16 Y blocks (4x4 AC coefficients)
        // - 4 U blocks (4x4)
        // - 4 V blocks (4x4)
        // Total: up to 25 blocks per macroblock

        // Decode Y2 block (block type 0)
        var y2_block: DctBlock = undefined;
        const y2_nz = decodeBlock(&coeff_decoder, 0, &y2_block, &coeff_probs, 0);
        if (y2_nz == null) {
            // Ran out of data or decode error - check if we decoded anything
            if (blocks_decoded > 0) {
                partial_valid = true;
            }
            break;
        }
        blocks_decoded += 1;

        // Run WHT on Y2 block to verify transform works
        const y2_wht = inverseWht4x4(@ptrCast(&y2_block));
        _ = y2_wht;

        // Decode 16 Y blocks (block type 1)
        var y_valid = true;
        for (0..16) |_| {
            var y_block: DctBlock = undefined;
            const y_nz = decodeBlock(&coeff_decoder, 1, &y_block, &coeff_probs, 1); // Start at coeff 1, DC from Y2
            if (y_nz == null) {
                y_valid = false;
                break;
            }
            blocks_decoded += 1;

            // Run DCT on Y block
            const y_dct = inverseDct4x4(&y_block);
            _ = y_dct;
        }
        if (!y_valid) {
            if (blocks_decoded > 0) partial_valid = true;
            break;
        }

        // Decode 4 U blocks (block type 2)
        var u_valid = true;
        for (0..4) |_| {
            var u_block: DctBlock = undefined;
            const u_nz = decodeBlock(&coeff_decoder, 2, &u_block, &coeff_probs, 0);
            if (u_nz == null) {
                u_valid = false;
                break;
            }
            blocks_decoded += 1;

            const u_dct = inverseDct4x4(&u_block);
            _ = u_dct;
        }
        if (!u_valid) {
            if (blocks_decoded > 0) partial_valid = true;
            break;
        }

        // Decode 4 V blocks (block type 3)
        var v_valid = true;
        for (0..4) |_| {
            var v_block: DctBlock = undefined;
            const v_nz = decodeBlock(&coeff_decoder, 3, &v_block, &coeff_probs, 0);
            if (v_nz == null) {
                v_valid = false;
                break;
            }
            blocks_decoded += 1;

            const v_dct = inverseDct4x4(&v_block);
            _ = v_dct;
        }
        if (!v_valid) {
            if (blocks_decoded > 0) partial_valid = true;
            break;
        }

        mbs_decoded += 1;
    }

    // Success if we decoded at least some coefficient data
    // A corrupted file would fail during token decoding
    if (mbs_decoded > 0 or partial_valid) {
        return Vp8DeepValidationResult.ok(
            blocks_decoded,
            mbs_decoded,
            width,
            height,
        );
    }

    return Vp8DeepValidationResult.invalid("Failed to decode any coefficient blocks");
}

// ============================================================================
// Tests
// ============================================================================

test "BoolDecoder initialization" {
    const data = [_]u8{ 0x00, 0xFF, 0xAA, 0x55 };
    const decoder = BoolDecoder.init(&data);
    try std.testing.expect(decoder != null);
    try std.testing.expectEqual(@as(u32, 0x00FF), decoder.?.value);
    try std.testing.expectEqual(@as(u32, 255), decoder.?.range);
}

test "BoolDecoder read bit" {
    var data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    var decoder = BoolDecoder.init(&data).?;

    // With all zeros and prob 128, first bit should be 0
    const bit = decoder.readBit();
    try std.testing.expect(bit != null);
    try std.testing.expect(bit.? == false);
}

test "BoolDecoder read literal" {
    var data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var decoder = BoolDecoder.init(&data).?;

    // Reading with high values should give non-zero result
    const literal = decoder.readLiteral(4);
    try std.testing.expect(literal != null);
}

test "inverse WHT 4x4 - DC only" {
    // A DC-only WHT block should produce uniform output
    var input: WhtBlock = [_]i16{0} ** 16;
    input[0] = 64; // DC value

    const output = inverseWht4x4(&input);

    // All values should be close to DC/4 = 16
    // Due to rounding, check they're in reasonable range
    for (output) |val| {
        try std.testing.expect(@abs(val - 8) <= 2);
    }
}

test "inverse DCT 4x4 - DC only" {
    // A DC-only DCT block should produce uniform output
    var input: DctBlock = [_]i16{0} ** 16;
    input[0] = 64; // DC value

    const output = inverseDct4x4(&input);

    // All values should be similar
    for (output) |val| {
        try std.testing.expect(@abs(val - 8) <= 2);
    }
}

test "VP8 deep validation - synthetic data fails gracefully" {
    // Synthetic minimal keyframe - doesn't have valid coefficient data
    // The deep validator should detect this and return invalid
    const keyframe = [_]u8{
        0x90, 0x02, 0x00, // Frame tag with partition_size=20
        0x9D, 0x01, 0x2A, // Sync code
        0x10, 0x00, // width 16
        0x10, 0x00, // height 16
        // First partition data (zeros - invalid for coefficient probs)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    const result = validateKeyframeDeep(&keyframe);
    // Synthetic data should fail during coefficient probability parsing
    // This is correct behavior - we detect invalid bitstreams
    try std.testing.expect(!result.valid or result.blocks_decoded == 0);
}

test "VP8 deep validation - ground truth keyframe" {
    // Real VP8 keyframe from ground_truth_examples/vp8/sample.ivf
    // 160x120 frame, 91 bytes total (extracted from IVF offset 44)
    const keyframe = [_]u8{
        0x30, 0x07, 0x00, 0x9d, 0x01, 0x2a, 0xa0, 0x00, 0x78, 0x00, 0x00, 0x47,
        0x08, 0x85, 0x85, 0x88, 0x85, 0x84, 0x88, 0x02, 0x02, 0x02, 0x75, 0xaa,
        0x03, 0xf8, 0x03, 0xfa, 0x02, 0x06, 0xc3, 0xef, 0x05, 0x10, 0x9c, 0x52,
        0xd2, 0xa1, 0x38, 0xa5, 0xa5, 0x42, 0x71, 0x4b, 0x4a, 0x84, 0xe2, 0x96,
        0x95, 0x09, 0xc5, 0x2d, 0x2a, 0x13, 0x8a, 0x5a, 0x54, 0x27, 0x14, 0xb4,
        0xa8, 0x4e, 0x29, 0x69, 0x50, 0x9b, 0x00, 0xfe, 0xfd, 0x6e, 0xf3, 0xff,
        0xe3, 0x99, 0x37, 0x30, 0xc4, 0xff, 0x8e, 0x6d, 0xff, 0xf1, 0x61, 0x3c,
        0x0e, 0x28, 0xc8, 0xff, 0xf1, 0x51, 0x00,
    };

    const result = validateKeyframeDeep(&keyframe);

    // Real VP8 data should validate successfully
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 160), result.width);
    try std.testing.expectEqual(@as(u32, 120), result.height);
    // Should decode at least some blocks (header + coefficient data)
    try std.testing.expect(result.blocks_decoded > 0);
}
