//! CCITT Fax (Group 3/4) Decoder
//!
//! Pure Zig implementation of CCITT T.4 (Group 3) and T.6 (Group 4) fax decoding.
//! This is commonly used in PDF files for scanned documents (CCITTFaxDecode filter).
//!
//! Supports:
//! - Group 4 (K=-1): Pure 2D encoding (most common in PDFs)
//! - Group 3 1D (K=0): Modified Huffman run-length encoding
//! - Group 3 2D (K>0): Mixed 1D/2D encoding
//!
//! References:
//! - ITU-T T.4: Standardization of Group 3 facsimile terminals
//! - ITU-T T.6: Facsimile coding schemes and coding control functions for Group 4

const std = @import("std");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;

/// CCITT Fax decode parameters (from PDF DecodeParms)
pub const CcittParams = struct {
    /// K parameter: encoding mode
    /// K < 0: Group 4 (pure 2D)
    /// K = 0: Group 3 1D
    /// K > 0: Group 3 2D (K specifies the ratio of 1D to 2D lines)
    k: i32 = -1,
    /// Image width in pixels
    columns: u32 = 1728,
    /// Image height in pixels (0 = unknown)
    rows: u32 = 0,
    /// End of line markers present
    end_of_line: bool = false,
    /// Byte-aligned rows
    encoded_byte_align: bool = false,
    /// Black pixels are 1 (default: black=0, white=1)
    black_is_1: bool = false,
    /// End of block marker present
    end_of_block: bool = true,
    /// Damage tolerance (currently ignored)
    damaged_rows_before_error: u32 = 0,
};

/// Decode result
pub const DecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    width: u32,
    height: u32,
    /// Decoded bitmap (1 bit per pixel, row-major, MSB first)
    /// Caller must free with allocator
    bitmap: ?[]u8,
    bytes_per_row: u32,

    pub fn deinit(self: *DecodeResult, allocator: Allocator) void {
        if (self.bitmap) |bmp| {
            allocator.free(bmp);
            self.bitmap = null;
        }
    }

    pub fn failure(msg: []const u8) DecodeResult {
        return .{
            .valid = false,
            .error_message = msg,
            .width = 0,
            .height = 0,
            .bitmap = null,
            .bytes_per_row = 0,
        };
    }

    pub fn success(w: u32, h: u32, bmp: []u8, bpr: u32) DecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .width = w,
            .height = h,
            .bitmap = bmp,
            .bytes_per_row = bpr,
        };
    }
};

/// Bit reader for packed data
const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3, // 0-7, MSB first (0 = bit 7)

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .byte_pos = 0,
            .bit_pos = 0,
        };
    }

    /// Read a single bit (returns 0 or 1)
    pub fn readBit(self: *BitReader) ?u1 {
        if (self.byte_pos >= self.data.len) return null;

        const byte = self.data[self.byte_pos];
        const bit: u1 = @truncate((byte >> (7 - @as(u3, self.bit_pos))) & 1);

        self.bit_pos +%= 1;
        if (self.bit_pos == 0) {
            self.byte_pos += 1;
        }

        return bit;
    }

    /// Peek at next N bits without consuming
    pub fn peekBits(self: *BitReader, n: u5) ?u32 {
        if (n == 0) return 0;
        if (n > 24) return null;

        var result: u32 = 0;
        var byte_idx = self.byte_pos;
        var bit_idx = self.bit_pos;

        var remaining: u5 = n;
        while (remaining > 0) {
            if (byte_idx >= self.data.len) return null;

            const byte = self.data[byte_idx];
            const bits_in_byte = @as(u5, 8) - @as(u5, bit_idx);
            const bits_to_read = @min(remaining, bits_in_byte);

            // Extract bits from current byte
            const shift = @as(u3, @intCast(bits_in_byte - bits_to_read));
            const mask = (@as(u32, 1) << bits_to_read) - 1;
            const extracted = (byte >> shift) & @as(u8, @truncate(mask));

            result = (result << bits_to_read) | extracted;
            remaining -= bits_to_read;

            bit_idx = @truncate(@as(u4, bit_idx) + bits_to_read);
            if (bit_idx >= 8) {
                bit_idx = 0;
                byte_idx += 1;
            }
        }

        return result;
    }

    /// Skip N bits
    pub fn skipBits(self: *BitReader, n: u32) void {
        const total_bits = @as(u32, self.bit_pos) + n;
        self.byte_pos += total_bits / 8;
        self.bit_pos = @truncate(total_bits % 8);
    }

    /// Align to next byte boundary
    pub fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        }
    }

    /// Check if at end of data
    pub fn isAtEnd(self: *BitReader) bool {
        return self.byte_pos >= self.data.len;
    }
};

// ============ Huffman Tables (ITU-T T.4) ============

/// White run-length codes (table 1)
/// Format: { code_bits, code_length, run_length }
const white_terminating_codes = [_][3]u16{
    .{ 0b00110101, 8, 0 },
    .{ 0b000111, 6, 1 },
    .{ 0b0111, 4, 2 },
    .{ 0b1000, 4, 3 },
    .{ 0b1011, 4, 4 },
    .{ 0b1100, 4, 5 },
    .{ 0b1110, 4, 6 },
    .{ 0b1111, 4, 7 },
    .{ 0b10011, 5, 8 },
    .{ 0b10100, 5, 9 },
    .{ 0b00111, 5, 10 },
    .{ 0b01000, 5, 11 },
    .{ 0b001000, 6, 12 },
    .{ 0b000011, 6, 13 },
    .{ 0b110100, 6, 14 },
    .{ 0b110101, 6, 15 },
    .{ 0b101010, 6, 16 },
    .{ 0b101011, 6, 17 },
    .{ 0b0100111, 7, 18 },
    .{ 0b0001100, 7, 19 },
    .{ 0b0001000, 7, 20 },
    .{ 0b0010111, 7, 21 },
    .{ 0b0000011, 7, 22 },
    .{ 0b0000100, 7, 23 },
    .{ 0b0101000, 7, 24 },
    .{ 0b0101011, 7, 25 },
    .{ 0b0010011, 7, 26 },
    .{ 0b0100100, 7, 27 },
    .{ 0b0011000, 7, 28 },
    .{ 0b00000010, 8, 29 },
    .{ 0b00000011, 8, 30 },
    .{ 0b00011010, 8, 31 },
    .{ 0b00011011, 8, 32 },
    .{ 0b00010010, 8, 33 },
    .{ 0b00010011, 8, 34 },
    .{ 0b00010100, 8, 35 },
    .{ 0b00010101, 8, 36 },
    .{ 0b00010110, 8, 37 },
    .{ 0b00010111, 8, 38 },
    .{ 0b00101000, 8, 39 },
    .{ 0b00101001, 8, 40 },
    .{ 0b00101010, 8, 41 },
    .{ 0b00101011, 8, 42 },
    .{ 0b00101100, 8, 43 },
    .{ 0b00101101, 8, 44 },
    .{ 0b00000100, 8, 45 },
    .{ 0b00000101, 8, 46 },
    .{ 0b00001010, 8, 47 },
    .{ 0b00001011, 8, 48 },
    .{ 0b01010010, 8, 49 },
    .{ 0b01010011, 8, 50 },
    .{ 0b01010100, 8, 51 },
    .{ 0b01010101, 8, 52 },
    .{ 0b00100100, 8, 53 },
    .{ 0b00100101, 8, 54 },
    .{ 0b01011000, 8, 55 },
    .{ 0b01011001, 8, 56 },
    .{ 0b01011010, 8, 57 },
    .{ 0b01011011, 8, 58 },
    .{ 0b01001010, 8, 59 },
    .{ 0b01001011, 8, 60 },
    .{ 0b00110010, 8, 61 },
    .{ 0b00110011, 8, 62 },
    .{ 0b00110100, 8, 63 },
};

const white_makeup_codes = [_][3]u16{
    .{ 0b11011, 5, 64 },
    .{ 0b10010, 5, 128 },
    .{ 0b010111, 6, 192 },
    .{ 0b0110111, 7, 256 },
    .{ 0b00110110, 8, 320 },
    .{ 0b00110111, 8, 384 },
    .{ 0b01100100, 8, 448 },
    .{ 0b01100101, 8, 512 },
    .{ 0b01101000, 8, 576 },
    .{ 0b01100111, 8, 640 },
    .{ 0b011001100, 9, 704 },
    .{ 0b011001101, 9, 768 },
    .{ 0b011010010, 9, 832 },
    .{ 0b011010011, 9, 896 },
    .{ 0b011010100, 9, 960 },
    .{ 0b011010101, 9, 1024 },
    .{ 0b011010110, 9, 1088 },
    .{ 0b011010111, 9, 1152 },
    .{ 0b011011000, 9, 1216 },
    .{ 0b011011001, 9, 1280 },
    .{ 0b011011010, 9, 1344 },
    .{ 0b011011011, 9, 1408 },
    .{ 0b010011000, 9, 1472 },
    .{ 0b010011001, 9, 1536 },
    .{ 0b010011010, 9, 1600 },
    .{ 0b011000, 6, 1664 },
    .{ 0b010011011, 9, 1728 },
};

/// Black run-length codes (table 2)
const black_terminating_codes = [_][3]u16{
    .{ 0b0000110111, 10, 0 },
    .{ 0b010, 3, 1 },
    .{ 0b11, 2, 2 },
    .{ 0b10, 2, 3 },
    .{ 0b011, 3, 4 },
    .{ 0b0011, 4, 5 },
    .{ 0b0010, 4, 6 },
    .{ 0b00011, 5, 7 },
    .{ 0b000101, 6, 8 },
    .{ 0b000100, 6, 9 },
    .{ 0b0000100, 7, 10 },
    .{ 0b0000101, 7, 11 },
    .{ 0b0000111, 7, 12 },
    .{ 0b00000100, 8, 13 },
    .{ 0b00000111, 8, 14 },
    .{ 0b000011000, 9, 15 },
    .{ 0b0000010111, 10, 16 },
    .{ 0b0000011000, 10, 17 },
    .{ 0b0000001000, 10, 18 },
    .{ 0b00001100111, 11, 19 },
    .{ 0b00001101000, 11, 20 },
    .{ 0b00001101100, 11, 21 },
    .{ 0b00000110111, 11, 22 },
    .{ 0b00000101000, 11, 23 },
    .{ 0b00000010111, 11, 24 },
    .{ 0b00000011000, 11, 25 },
    .{ 0b000011001010, 12, 26 },
    .{ 0b000011001011, 12, 27 },
    .{ 0b000011001100, 12, 28 },
    .{ 0b000011001101, 12, 29 },
    .{ 0b000001101000, 12, 30 },
    .{ 0b000001101001, 12, 31 },
    .{ 0b000001101010, 12, 32 },
    .{ 0b000001101011, 12, 33 },
    .{ 0b000011010010, 12, 34 },
    .{ 0b000011010011, 12, 35 },
    .{ 0b000011010100, 12, 36 },
    .{ 0b000011010101, 12, 37 },
    .{ 0b000011010110, 12, 38 },
    .{ 0b000011010111, 12, 39 },
    .{ 0b000001101100, 12, 40 },
    .{ 0b000001101101, 12, 41 },
    .{ 0b000011011010, 12, 42 },
    .{ 0b000011011011, 12, 43 },
    .{ 0b000001010100, 12, 44 },
    .{ 0b000001010101, 12, 45 },
    .{ 0b000001010110, 12, 46 },
    .{ 0b000001010111, 12, 47 },
    .{ 0b000001100100, 12, 48 },
    .{ 0b000001100101, 12, 49 },
    .{ 0b000001010010, 12, 50 },
    .{ 0b000001010011, 12, 51 },
    .{ 0b000000100100, 12, 52 },
    .{ 0b000000110111, 12, 53 },
    .{ 0b000000111000, 12, 54 },
    .{ 0b000000100111, 12, 55 },
    .{ 0b000000101000, 12, 56 },
    .{ 0b000001011000, 12, 57 },
    .{ 0b000001011001, 12, 58 },
    .{ 0b000000101011, 12, 59 },
    .{ 0b000000101100, 12, 60 },
    .{ 0b000001011010, 12, 61 },
    .{ 0b000001100110, 12, 62 },
    .{ 0b000001100111, 12, 63 },
};

const black_makeup_codes = [_][3]u16{
    .{ 0b0000001111, 10, 64 },
    .{ 0b000011001000, 12, 128 },
    .{ 0b000011001001, 12, 192 },
    .{ 0b000001011011, 12, 256 },
    .{ 0b000000110011, 12, 320 },
    .{ 0b000000110100, 12, 384 },
    .{ 0b000000110101, 12, 448 },
    .{ 0b0000001101100, 13, 512 },
    .{ 0b0000001101101, 13, 576 },
    .{ 0b0000001001010, 13, 640 },
    .{ 0b0000001001011, 13, 704 },
    .{ 0b0000001001100, 13, 768 },
    .{ 0b0000001001101, 13, 832 },
    .{ 0b0000001110010, 13, 896 },
    .{ 0b0000001110011, 13, 960 },
    .{ 0b0000001110100, 13, 1024 },
    .{ 0b0000001110101, 13, 1088 },
    .{ 0b0000001110110, 13, 1152 },
    .{ 0b0000001110111, 13, 1216 },
    .{ 0b0000001010010, 13, 1280 },
    .{ 0b0000001010011, 13, 1344 },
    .{ 0b0000001010100, 13, 1408 },
    .{ 0b0000001010101, 13, 1472 },
    .{ 0b0000001011010, 13, 1536 },
    .{ 0b0000001011011, 13, 1600 },
    .{ 0b0000001100100, 13, 1664 },
    .{ 0b0000001100101, 13, 1728 },
};

// Extended makeup codes (common to both black and white)
const extended_makeup_codes = [_][3]u16{
    .{ 0b00000001000, 11, 1792 },
    .{ 0b00000001100, 11, 1856 },
    .{ 0b00000001101, 11, 1920 },
    .{ 0b000000010010, 12, 1984 },
    .{ 0b000000010011, 12, 2048 },
    .{ 0b000000010100, 12, 2112 },
    .{ 0b000000010101, 12, 2176 },
    .{ 0b000000010110, 12, 2240 },
    .{ 0b000000010111, 12, 2304 },
    .{ 0b000000011100, 12, 2368 },
    .{ 0b000000011101, 12, 2432 },
    .{ 0b000000011110, 12, 2496 },
    .{ 0b000000011111, 12, 2560 },
};

/// Mode codes for 2D encoding (Group 4 / T.6)
const Mode = enum {
    pass, // P: skip over reference line
    horizontal, // H: explicit run lengths
    vertical_0, // V(0): same position
    vertical_r1, // V(1): 1 pixel right
    vertical_r2, // V(2): 2 pixels right
    vertical_r3, // V(3): 3 pixels right
    vertical_l1, // V(-1): 1 pixel left
    vertical_l2, // V(-2): 2 pixels left
    vertical_l3, // V(-3): 3 pixels left
    extension, // Extension (not used in PDF)
    eol, // End of line (Group 3)
};

/// Try to decode a mode code from the bit stream
fn decodeMode(reader: *BitReader) ?Mode {
    // Mode codes (T.6 Table 1):
    // 0001: Pass
    // 001: Horizontal
    // 1: V(0)
    // 011: V(1)
    // 000011: V(2)
    // 0000011: V(3)
    // 010: V(-1)
    // 000010: V(-2)
    // 0000010: V(-3)

    const peek12 = reader.peekBits(12) orelse return null;

    // Check single bit first
    if ((peek12 >> 11) & 1 == 1) {
        reader.skipBits(1);
        return .vertical_0;
    }

    // Check 3-bit codes
    const top3 = (peek12 >> 9) & 0b111;
    if (top3 == 0b011) {
        reader.skipBits(3);
        return .vertical_r1;
    }
    if (top3 == 0b010) {
        reader.skipBits(3);
        return .vertical_l1;
    }
    if (top3 == 0b001) {
        reader.skipBits(3);
        return .horizontal;
    }

    // Check 4-bit codes
    const top4 = (peek12 >> 8) & 0b1111;
    if (top4 == 0b0001) {
        reader.skipBits(4);
        return .pass;
    }

    // Check 6-bit codes
    const top6 = (peek12 >> 6) & 0b111111;
    if (top6 == 0b000011) {
        reader.skipBits(6);
        return .vertical_r2;
    }
    if (top6 == 0b000010) {
        reader.skipBits(6);
        return .vertical_l2;
    }

    // Check 7-bit codes
    const top7 = (peek12 >> 5) & 0b1111111;
    if (top7 == 0b0000011) {
        reader.skipBits(7);
        return .vertical_r3;
    }
    if (top7 == 0b0000010) {
        reader.skipBits(7);
        return .vertical_l3;
    }

    // Check for EOFB (end of facsimile block) - 24 zero bits
    // In practice, check for 12 zeros followed by more zeros
    if (peek12 == 0) {
        return .eol;
    }

    return null;
}

/// Decode a run length code (either white or black)
fn decodeRunLength(reader: *BitReader, is_white: bool) ?u32 {
    var total: u32 = 0;

    while (true) {
        const run = decodeRunLengthCode(reader, is_white) orelse return null;
        total += run;

        // Makeup codes (>=64) indicate more codes follow
        // Terminating codes (<64) end the run
        if (run < 64) {
            return total;
        }
    }
}

/// Decode a single run length code
/// O(1) run-length dispatch. The fleet review flagged the linear-table-scan in
/// decodeRunLengthCode (peek 13 bits, then for-loop over up to 5 ~100-entry
/// tables per run). We build [1<<13] LUTs at comptime by replicating the EXACT
/// same ordered scan (terminating -> makeup -> extended, first match wins), so
/// the fast path is provably equivalent. CCITT modified-Huffman codes are
/// prefix-free, so a 13-bit lookahead uniquely identifies each codeword.
const CcittRlEntry = struct { run: u32, len: u5 };

/// Replicate decodeRunLengthCode's match logic for one 13-bit peek value,
/// scanning the given tables in order and returning the first hit.
fn matchCcittRl(comptime tables: []const []const [3]u16, peek13: u32) ?CcittRlEntry {
    for (tables) |table| {
        for (table) |entry| {
            const code = entry[0];
            const len = entry[1];
            if (len <= 13) {
                const shift: u5 = @intCast(13 - len);
                if ((peek13 >> shift) == code) {
                    return .{ .run = entry[2], .len = @intCast(len) };
                }
            }
        }
    }
    return null;
}

fn buildCcittRlLut(comptime tables: []const []const [3]u16) [1 << 13]?CcittRlEntry {
    @setEvalBranchQuota(80_000_000);
    var lut: [1 << 13]?CcittRlEntry = undefined;
    for (&lut, 0..) |*slot, peek| {
        slot.* = matchCcittRl(tables, @intCast(peek));
    }
    return lut;
}

const white_rl_lut: [1 << 13]?CcittRlEntry = buildCcittRlLut(&.{
    &white_terminating_codes, &white_makeup_codes, &extended_makeup_codes,
});
const black_rl_lut: [1 << 13]?CcittRlEntry = buildCcittRlLut(&.{
    &black_terminating_codes, &black_makeup_codes, &extended_makeup_codes,
});

fn decodeRunLengthCode(reader: *BitReader, is_white: bool) ?u32 {
    const peek13 = reader.peekBits(13) orelse return null;
    const entry = (if (is_white) white_rl_lut[peek13] else black_rl_lut[peek13]) orelse return null;
    reader.skipBits(entry.len);
    return entry.run;
}

/// Find b1 position (first changing pixel on reference line at or after a0 of opposite color)
fn findB1(ref_line: []const u8, a0: i32, width: u32, current_color_is_white: bool) i32 {
    // b1 is the position of the first changing element on the reference line
    // to the right of a0 and of the opposite color to a0

    const start_pos: u32 = if (a0 < 0) 0 else @intCast(a0);
    const ref_color_at_start = if (start_pos < width) getPixel(ref_line, start_pos) else 0;

    // We want the first change TO the opposite color
    // If current is white, we want the first black run start
    // If current is black, we want the first white run start

    var pos = start_pos;
    var prev_pixel = ref_color_at_start;

    // Skip to first pixel that's the opposite color (what we're looking for a change TO)
    const target_color: u1 = if (current_color_is_white) 0 else 1;

    while (pos < width) {
        const pixel = getPixel(ref_line, pos);
        if (pixel == target_color and (pos == 0 or prev_pixel != target_color)) {
            return @intCast(pos);
        }
        prev_pixel = pixel;
        pos += 1;
    }

    return @intCast(width);
}

/// Find b2 position (first changing pixel after b1)
fn findB2(ref_line: []const u8, b1: i32, width: u32) i32 {
    if (b1 < 0 or b1 >= @as(i32, @intCast(width))) return @intCast(width);

    const b1_pos: u32 = @intCast(b1);
    const b1_color = getPixel(ref_line, b1_pos);

    var pos = b1_pos + 1;
    while (pos < width) {
        const pixel = getPixel(ref_line, pos);
        if (pixel != b1_color) {
            return @intCast(pos);
        }
        pos += 1;
    }

    return @intCast(width);
}

/// Get a pixel from a line (0=white, 1=black)
fn getPixel(line: []const u8, x: u32) u1 {
    if (line.len == 0) return 0; // White
    const byte_idx = x / 8;
    const bit_idx = @as(u3, @intCast(7 - (x % 8)));
    if (byte_idx >= line.len) return 0;
    return @truncate((line[byte_idx] >> bit_idx) & 1);
}

/// Set a pixel in a line
fn setPixel(line: []u8, x: u32, value: u1) void {
    const byte_idx = x / 8;
    const bit_idx = @as(u3, @intCast(7 - (x % 8)));
    if (byte_idx >= line.len) return;

    if (value == 1) {
        line[byte_idx] |= @as(u8, 1) << bit_idx;
    } else {
        line[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }
}

/// Fill a run of pixels
fn fillRun(line: []u8, start: u32, length: u32, width: u32, color: u1) void {
    var x = start;
    const end = @min(start + length, width);
    while (x < end) : (x += 1) {
        setPixel(line, x, color);
    }
}

/// Decode Group 4 (T.6) encoded data
pub fn decodeGroup4(allocator: Allocator, data: []const u8, params: CcittParams) DecodeResult {
    const width = params.columns;
    const expected_rows = params.rows;

    // Calculate bytes per row
    const bytes_per_row = (width + 7) / 8;

    // Estimate number of rows if not specified
    const max_rows: u32 = if (expected_rows > 0) expected_rows else @intCast(@max(1, data.len * 8 / width));

    // Allocate bitmap
    const bitmap = allocator.alloc(u8, bytes_per_row * max_rows) catch {
        return DecodeResult.failure(errmsg.outOfMemory("allocating bitmap"));
    };
    errdefer allocator.free(bitmap);

    // Initialize to white (0)
    @memset(bitmap, if (params.black_is_1) 0xFF else 0x00);

    var reader = BitReader.init(data);

    // Reference line (initially all white)
    const ref_line = allocator.alloc(u8, bytes_per_row) catch {
        return DecodeResult.failure("Out of memory");
    };
    defer allocator.free(ref_line);
    @memset(ref_line, 0); // All white

    var row: u32 = 0;

    while (row < max_rows) {
        if (reader.isAtEnd()) break;

        const current_line = bitmap[row * bytes_per_row ..][0..bytes_per_row];
        @memset(current_line, 0); // Start white

        var a0: i32 = -1; // Current position (-1 means "before first pixel")
        var color_is_white = true; // Start with white

        while (true) {
            if (reader.isAtEnd()) break;

            const mode = decodeMode(&reader) orelse {
                // Unrecognized code - might be at end
                break;
            };

            switch (mode) {
                .pass => {
                    // Pass mode: skip over b2 position
                    const b1 = findB1(ref_line, a0, width, color_is_white);
                    const b2 = findB2(ref_line, b1, width);
                    a0 = b2;
                    // Color doesn't change
                },
                .horizontal => {
                    // Horizontal mode: explicit run lengths
                    const run1 = decodeRunLength(&reader, color_is_white) orelse break;
                    const run2 = decodeRunLength(&reader, !color_is_white) orelse break;

                    const start1: u32 = if (a0 < 0) 0 else @intCast(a0);
                    if (!color_is_white) {
                        fillRun(current_line, start1, run1, width, if (params.black_is_1) 1 else 1);
                    }
                    if (color_is_white) {
                        fillRun(current_line, start1 + run1, run2, width, if (params.black_is_1) 1 else 1);
                    }

                    a0 = @as(i32, @intCast(start1)) + @as(i32, @intCast(run1)) + @as(i32, @intCast(run2));
                    // Color returns to original
                },
                .vertical_0, .vertical_r1, .vertical_r2, .vertical_r3, .vertical_l1, .vertical_l2, .vertical_l3 => {
                    const offset: i32 = switch (mode) {
                        .vertical_0 => 0,
                        .vertical_r1 => 1,
                        .vertical_r2 => 2,
                        .vertical_r3 => 3,
                        .vertical_l1 => -1,
                        .vertical_l2 => -2,
                        .vertical_l3 => -3,
                        else => unreachable,
                    };

                    const b1 = findB1(ref_line, a0, width, color_is_white);
                    const a1 = b1 + offset;

                    // Fill from a0 to a1 with current color
                    if (!color_is_white) {
                        const start: u32 = if (a0 < 0) 0 else @intCast(a0);
                        const end: u32 = @intCast(@max(0, a1));
                        if (end > start) {
                            fillRun(current_line, start, end - start, width, if (params.black_is_1) 1 else 1);
                        }
                    }

                    a0 = a1;
                    color_is_white = !color_is_white;
                },
                .eol => {
                    // End of line (check for EOFB - double EOL)
                    const peek = reader.peekBits(12) orelse break;
                    if (peek == 0) {
                        // Likely EOFB
                        break;
                    }
                },
                .extension => {
                    // Extension not supported
                    break;
                },
            }

            // Check if we've reached end of line
            if (a0 >= @as(i32, @intCast(width))) {
                break;
            }
        }

        // Copy current line to reference for next row
        @memcpy(ref_line, current_line);
        row += 1;

        if (params.encoded_byte_align) {
            reader.alignToByte();
        }
    }

    // If we decoded fewer rows than allocated, shrink the bitmap
    if (row < max_rows and row > 0) {
        const actual_size = row * bytes_per_row;
        const shrunk = allocator.realloc(bitmap, actual_size) catch bitmap;
        return DecodeResult.success(width, row, shrunk, bytes_per_row);
    }

    return DecodeResult.success(width, row, bitmap, bytes_per_row);
}

/// Decode Group 3 1D (Modified Huffman) encoded data
pub fn decodeGroup3_1D(allocator: Allocator, data: []const u8, params: CcittParams) DecodeResult {
    const width = params.columns;
    const expected_rows = params.rows;

    // Calculate bytes per row
    const bytes_per_row = (width + 7) / 8;

    // Estimate number of rows if not specified
    const max_rows: u32 = if (expected_rows > 0) expected_rows else @intCast(@max(1, data.len * 8 / width));

    // Allocate bitmap
    const bitmap = allocator.alloc(u8, bytes_per_row * max_rows) catch {
        return DecodeResult.failure(errmsg.outOfMemory("allocating bitmap"));
    };
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0); // All white

    var reader = BitReader.init(data);
    var row: u32 = 0;

    while (row < max_rows) {
        if (reader.isAtEnd()) break;

        // Skip EOL marker if present
        if (params.end_of_line) {
            // EOL is 000000000001 (11 zeros followed by 1)
            const peek = reader.peekBits(12) orelse break;
            if (peek == 1) {
                reader.skipBits(12);
            }
        }

        const current_line = bitmap[row * bytes_per_row ..][0..bytes_per_row];
        @memset(current_line, 0);

        var x: u32 = 0;
        var is_white = true;

        while (x < width) {
            const run = decodeRunLength(&reader, is_white) orelse break;

            if (!is_white) {
                fillRun(current_line, x, run, width, 1);
            }

            x += run;
            is_white = !is_white;
        }

        row += 1;

        if (params.encoded_byte_align) {
            reader.alignToByte();
        }
    }

    // Shrink if needed
    if (row < max_rows and row > 0) {
        const actual_size = row * bytes_per_row;
        const shrunk = allocator.realloc(bitmap, actual_size) catch bitmap;
        return DecodeResult.success(width, row, shrunk, bytes_per_row);
    }

    return DecodeResult.success(width, row, bitmap, bytes_per_row);
}

/// Main decode function - dispatches based on K parameter
pub fn decode(allocator: Allocator, data: []const u8, params: CcittParams) DecodeResult {
    if (data.len == 0) {
        return DecodeResult.failure(errmsg.empty("data"));
    }

    if (params.k < 0) {
        // Group 4
        return decodeGroup4(allocator, data, params);
    } else if (params.k == 0) {
        // Group 3 1D
        return decodeGroup3_1D(allocator, data, params);
    } else {
        // Group 3 2D (mixed mode): not yet implemented as distinct decoder.
        // Falls back to Group 4 decoder which handles the 2D-coded lines
        // but may misinterpret periodic 1D reference lines (k parameter).
        // Extremely rare in modern files; validation result is approximate.
        return decodeGroup4(allocator, data, params);
    }
}

/// Validate CCITT Fax data without keeping the decoded bitmap
pub fn validate(data: []const u8, params: CcittParams) struct { valid: bool, error_message: ?[]const u8, width: u32, height: u32 } {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var result = decode(gpa.allocator(), data, params);
    defer result.deinit(gpa.allocator());

    return .{
        .valid = result.valid,
        .error_message = result.error_message,
        .width = result.width,
        .height = result.height,
    };
}

// ============ Tests ============

test "CCITT RL LUT matches ordered linear scan for all 13-bit prefixes" {
    // matchCcittRl replicates the original decodeRunLengthCode scan order
    // (terminating -> makeup -> extended, first match wins); the comptime LUTs
    // are built from it. Assert they agree for every possible 13-bit lookahead.
    var peek: u32 = 0;
    while (peek < (1 << 13)) : (peek += 1) {
        const w_ref = matchCcittRl(&.{ &white_terminating_codes, &white_makeup_codes, &extended_makeup_codes }, peek);
        const w_got = white_rl_lut[peek];
        try std.testing.expectEqual(w_ref == null, w_got == null);
        if (w_ref) |r| {
            try std.testing.expectEqual(r.run, w_got.?.run);
            try std.testing.expectEqual(r.len, w_got.?.len);
        }
        const b_ref = matchCcittRl(&.{ &black_terminating_codes, &black_makeup_codes, &extended_makeup_codes }, peek);
        const b_got = black_rl_lut[peek];
        try std.testing.expectEqual(b_ref == null, b_got == null);
        if (b_ref) |r| {
            try std.testing.expectEqual(r.run, b_got.?.run);
            try std.testing.expectEqual(r.len, b_got.?.len);
        }
    }
}

test "BitReader reads bits correctly" {
    const data = [_]u8{ 0b10110100, 0b11001010 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 0), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
}

test "BitReader peekBits" {
    const data = [_]u8{ 0b10110100, 0b11001010 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 0b1011), reader.peekBits(4));
    // Peek doesn't consume
    try std.testing.expectEqual(@as(?u32, 0b1011), reader.peekBits(4));

    reader.skipBits(4);
    try std.testing.expectEqual(@as(?u32, 0b0100), reader.peekBits(4));
}

test "setPixel and getPixel" {
    var line = [_]u8{ 0, 0 };

    setPixel(&line, 0, 1);
    setPixel(&line, 7, 1);
    setPixel(&line, 8, 1);

    try std.testing.expectEqual(@as(u1, 1), getPixel(&line, 0));
    try std.testing.expectEqual(@as(u1, 0), getPixel(&line, 1));
    try std.testing.expectEqual(@as(u1, 1), getPixel(&line, 7));
    try std.testing.expectEqual(@as(u1, 1), getPixel(&line, 8));
    try std.testing.expectEqual(@as(u1, 0), getPixel(&line, 9));
}

test "fillRun fills pixels" {
    var line = [_]u8{ 0, 0, 0 };

    fillRun(&line, 2, 10, 24, 1);

    try std.testing.expectEqual(@as(u1, 0), getPixel(&line, 0));
    try std.testing.expectEqual(@as(u1, 0), getPixel(&line, 1));
    try std.testing.expectEqual(@as(u1, 1), getPixel(&line, 2));
    try std.testing.expectEqual(@as(u1, 1), getPixel(&line, 11));
    try std.testing.expectEqual(@as(u1, 0), getPixel(&line, 12));
}

test "decode empty data returns error" {
    const allocator = std.testing.allocator;
    var result = decode(allocator, &[_]u8{}, .{});
    defer result.deinit(allocator);

    try std.testing.expect(!result.valid);
}

test "decode minimal Group 4 data" {
    const allocator = std.testing.allocator;

    // EOFB marker (000000000001 repeated twice = 24 zeros)
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00 };

    var result = decode(allocator, &data, .{
        .k = -1,
        .columns = 8,
        .rows = 1,
    });
    defer result.deinit(allocator);

    // Should at least not crash
    try std.testing.expect(result.valid);
}
