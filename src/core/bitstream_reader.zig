//! Unified bit-level reader for parsing binary formats.
//!
//! This module consolidates multiple BitReader implementations that were
//! duplicated across the codebase (MPEG-1/2, MPEG-4, ProRes, FLAC, ALAC,
//! Theora, JBIG2, etc.) into a single, well-tested implementation.
//!
//! Features:
//! - Read 1-64 bits at a time
//! - Peek without consuming
//! - Skip bits efficiently
//! - Unary coding (count leading 1s/0s)
//! - Exp-Golomb coding (H.264/HEVC)
//! - Sign extension and sign-magnitude decoding
//! - Byte alignment
//! - Position tracking
//!
//! All methods use optional return types for EOF handling. Callers that
//! prefer error unions can use the `orelse return error.Truncated` pattern.

const std = @import("std");

/// Bit-level reader for parsing binary bitstreams.
/// Reads bits MSB-first (most significant bit first), which is the standard
/// for most video/audio codecs (MPEG, H.264, ProRes, FLAC, etc.).
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize, // Total bit position from start (allows >4GB streams)

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .bit_pos = 0 };
    }

    /// Read up to 32 bits. Returns null if not enough data available.
    pub fn readBits(self: *BitReader, count: u6) ?u32 {
        if (count == 0) return 0;
        const wide = self.readBitsWide(count) orelse return null;
        return @intCast(wide);
    }

    /// Read up to 64 bits. Returns null if not enough data available.
    pub fn readBits64(self: *BitReader, count: u7) ?u64 {
        if (count == 0) return 0;
        return self.readBitsWide(count);
    }

    /// Read n bits and cast to specified type T (for validators using typed returns).
    /// Example: reader.readBitsTyped(u16, 13) returns ?u16
    pub fn readBitsTyped(self: *BitReader, comptime T: type, n: usize) ?T {
        if (n == 0) return 0;
        if (n > @bitSizeOf(T)) return null;
        if (self.remainingBits() < n) return null;

        var result: T = 0;
        for (0..n) |_| {
            const bit = self.readBit() orelse return null;
            result = (result << 1) | @as(T, bit);
        }
        return result;
    }

    /// Internal: read up to 64 bits with any count type
    fn readBitsWide(self: *BitReader, count: anytype) ?u64 {
        var result: u64 = 0;
        var bits_remaining: u8 = @intCast(count);

        while (bits_remaining > 0) {
            const byte_pos = self.bit_pos / 8;
            if (byte_pos >= self.data.len) return null;

            const bit_in_byte: u3 = @intCast(self.bit_pos % 8);
            const bits_available: u8 = 8 - @as(u8, bit_in_byte);
            const bits_to_read: u8 = @min(bits_available, bits_remaining);

            // Extract bits from MSB side of current byte
            const shift: u3 = @intCast(bits_available - bits_to_read);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(bits_to_read)) - 1);
            const bits: u64 = (self.data[byte_pos] >> shift) & mask;

            result = (result << @intCast(bits_to_read)) | bits;
            self.bit_pos += bits_to_read;
            bits_remaining -= bits_to_read;
        }

        return result;
    }

    /// Read a single bit. Returns null if at end of data.
    pub fn readBit(self: *BitReader) ?u1 {
        const byte_pos = self.bit_pos / 8;
        if (byte_pos >= self.data.len) return null;

        const bit_in_byte: u3 = @intCast(self.bit_pos % 8);
        const bit: u1 = @intCast((self.data[byte_pos] >> (7 - bit_in_byte)) & 1);
        self.bit_pos += 1;
        return bit;
    }

    /// Peek at next n bits without consuming them.
    pub fn peekBits(self: *BitReader, count: u6) ?u32 {
        const saved_pos = self.bit_pos;
        const result = self.readBits(count);
        self.bit_pos = saved_pos;
        return result;
    }

    /// Peek at next n bits (up to 64) without consuming them.
    pub fn peekBits64(self: *BitReader, count: u7) ?u64 {
        const saved_pos = self.bit_pos;
        const result = self.readBits64(count);
        self.bit_pos = saved_pos;
        return result;
    }

    /// Skip n bits. Returns false if not enough data available.
    pub fn skipBits(self: *BitReader, count: usize) bool {
        const end_pos = self.bit_pos + count;
        const end_byte = (end_pos + 7) / 8;
        if (end_byte > self.data.len) return false;
        self.bit_pos = end_pos;
        return true;
    }

    /// Read unary code: count of 1-bits before a 0-bit.
    /// Used by FLAC, Rice coding, etc.
    pub fn readUnary(self: *BitReader) ?u32 {
        var count: u32 = 0;
        while (true) {
            const bit = self.readBit() orelse return null;
            if (bit == 0) return count;
            count += 1;
            if (count > 64) return null; // Sanity limit
        }
    }

    /// Read unary code: count of 0-bits before a 1-bit.
    /// Used by some codecs that use inverse unary.
    pub fn readUnaryZeros(self: *BitReader) ?u32 {
        return self.readUnaryZerosMax(64);
    }

    /// Read unary code with max limit: count of 0-bits before a 1-bit.
    /// Used by ALAC and other codecs with bounded unary codes.
    pub fn readUnaryZerosMax(self: *BitReader, max: u32) ?u32 {
        var count: u32 = 0;
        while (count < max) {
            const bit = self.readBit() orelse return null;
            if (bit == 1) return count;
            count += 1;
        }
        return count; // Return max if we hit the limit
    }

    /// Read unsigned Exp-Golomb code (used by H.264, HEVC).
    /// Format: (leading_zeros) 1 (suffix_bits)
    /// Value = 2^leading_zeros - 1 + suffix
    pub fn readExpGolomb(self: *BitReader) ?u32 {
        // Count leading zeros
        var leading_zeros: u32 = 0;
        while (true) {
            const bit = self.readBit() orelse return null;
            if (bit == 1) break;
            leading_zeros += 1;
            if (leading_zeros > 31) return null;
        }

        if (leading_zeros == 0) return 0;

        // Read suffix bits
        const suffix = self.readBits(@intCast(leading_zeros)) orelse return null;
        return (@as(u32, 1) << @intCast(leading_zeros)) - 1 + suffix;
    }

    /// Read signed Exp-Golomb code (used by H.264, HEVC).
    /// Maps unsigned values: 0->0, 1->1, 2->-1, 3->2, 4->-2, ...
    pub fn readSignedExpGolomb(self: *BitReader) ?i32 {
        const unsigned = self.readExpGolomb() orelse return null;
        if (unsigned == 0) return 0;
        const magnitude: i32 = @intCast((unsigned + 1) / 2);
        return if (unsigned & 1 == 0) -magnitude else magnitude;
    }

    /// Read signed value with two's complement sign extension.
    /// Used by FLAC and other codecs.
    pub fn readSignedTwosComplement(self: *BitReader, bits: u6) ?i32 {
        if (bits == 0) return 0;
        const unsigned = self.readBits(bits) orelse return null;
        const sign_bit = @as(u32, 1) << @intCast(bits - 1);
        if ((unsigned & sign_bit) != 0) {
            // Negative: sign extend
            const mask = @as(u32, 0xFFFFFFFF) << @intCast(bits);
            return @bitCast(unsigned | mask);
        }
        return @intCast(unsigned);
    }

    /// Read signed value with sign-magnitude encoding.
    /// Format: magnitude bits followed by 1-bit sign (0=positive, 1=negative).
    /// Used by ProRes and some other codecs.
    pub fn readSignedMagnitude(self: *BitReader, magnitude_bits: u6) ?i32 {
        const magnitude = self.readBits(magnitude_bits) orelse return null;
        if (magnitude == 0) return 0;
        const sign = self.readBit() orelse return null;
        const val: i32 = @intCast(magnitude);
        return if (sign == 1) -val else val;
    }

    /// Align to next byte boundary by skipping remaining bits in current byte.
    pub fn alignToByte(self: *BitReader) void {
        const remainder = self.bit_pos % 8;
        if (remainder != 0) {
            self.bit_pos += 8 - remainder;
        }
    }

    /// Check if there's more data available.
    pub fn hasMore(self: *const BitReader) bool {
        return self.bit_pos / 8 < self.data.len;
    }

    /// Get current bit position from start.
    pub fn getBitPosition(self: *const BitReader) usize {
        return self.bit_pos;
    }

    /// Get current byte position (truncated).
    pub fn getBytePosition(self: *const BitReader) usize {
        return self.bit_pos / 8;
    }

    /// Get remaining bits available.
    pub fn remainingBits(self: *const BitReader) usize {
        const total_bits = self.data.len * 8;
        if (self.bit_pos >= total_bits) return 0;
        return total_bits - self.bit_pos;
    }

    /// Seek to absolute bit position.
    pub fn seekToBit(self: *BitReader, pos: usize) bool {
        if (pos > self.data.len * 8) return false;
        self.bit_pos = pos;
        return true;
    }

    /// Seek to absolute byte position (resets bit offset to 0).
    pub fn seekToByte(self: *BitReader, pos: usize) bool {
        if (pos > self.data.len) return false;
        self.bit_pos = pos * 8;
        return true;
    }

    // =========================================================================
    // Backward-compatible aliases for different codebases
    // =========================================================================

    /// Alias for readSignedMagnitude (used by ProRes)
    pub fn readSigned(self: *BitReader, bits: u5) ?i32 {
        return self.readSignedMagnitude(@intCast(bits));
    }

    /// Alias for skipBits that returns void (used by MPEG4)
    pub fn skip(self: *BitReader, n: usize) void {
        _ = self.skipBits(n);
    }

    /// Alias for alignToByte (used by MPEG4)
    pub fn byteAlign(self: *BitReader) void {
        self.alignToByte();
    }

    /// Alias for remainingBits (used by MPEG4)
    pub fn bitsRemaining(self: *const BitReader) usize {
        return self.remainingBits();
    }

    /// Get remaining bytes (for ProRes compatibility)
    pub fn remainingBytes(self: *const BitReader) usize {
        const byte_pos = (self.bit_pos + 7) / 8;
        return if (byte_pos >= self.data.len) 0 else self.data.len - byte_pos;
    }

    /// Alias for readUnaryZerosMax (used by ALAC which calls it readUnary)
    pub fn readUnaryMax(self: *BitReader, max: u32) ?u32 {
        return self.readUnaryZerosMax(max);
    }

    /// Read single bit as bool (for MPEG validators)
    pub fn readBool(self: *BitReader) ?bool {
        const bit = self.readBit() orelse return null;
        return bit != 0;
    }

    /// Alias for getBytePosition (for MPEG validators)
    pub fn getBytePos(self: *const BitReader) usize {
        return self.getBytePosition();
    }

    /// Check if reader is at byte boundary
    pub fn isAligned(self: *const BitReader) bool {
        return (self.bit_pos % 8) == 0;
    }

    /// Read marker bit and verify it's 1 (for MPEG validators)
    pub fn readMarkerBit(self: *BitReader) ?bool {
        const bit = self.readBit() orelse return null;
        return bit == 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "readBits basic" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    // Read 4 bits: 1011
    try std.testing.expectEqual(@as(?u32, 0b1011), reader.readBits(4));
    // Read 4 bits: 0100
    try std.testing.expectEqual(@as(?u32, 0b0100), reader.readBits(4));
    // Read 8 bits: 01011010
    try std.testing.expectEqual(@as(?u32, 0b01011010), reader.readBits(8));
    // No more data
    try std.testing.expectEqual(@as(?u32, null), reader.readBits(1));
}

test "readBit" {
    const data = [_]u8{0b10110100};
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 0), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 0), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 1), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 0), reader.readBit());
    try std.testing.expectEqual(@as(?u1, 0), reader.readBit());
    try std.testing.expectEqual(@as(?u1, null), reader.readBit());
}

test "peekBits does not consume" {
    const data = [_]u8{0b10110100};
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 0b1011), reader.peekBits(4));
    try std.testing.expectEqual(@as(?u32, 0b1011), reader.peekBits(4)); // Same result
    try std.testing.expectEqual(@as(?u32, 0b1011), reader.readBits(4)); // Now consume
    try std.testing.expectEqual(@as(?u32, 0b0100), reader.peekBits(4)); // Next 4
}

test "skipBits" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    try std.testing.expect(reader.skipBits(4));
    try std.testing.expectEqual(@as(?u32, 0b0100), reader.readBits(4));
    try std.testing.expect(reader.skipBits(4));
    try std.testing.expectEqual(@as(?u32, 0b1010), reader.readBits(4));
    try std.testing.expect(!reader.skipBits(1)); // Past end
}

test "readUnary" {
    // 1110 0... = three 1s followed by 0
    const data = [_]u8{0b11100000};
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 3), reader.readUnary());
}

test "readUnaryZeros" {
    // 0001 ... = three 0s followed by 1
    const data = [_]u8{0b00010000};
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 3), reader.readUnaryZeros());
}

test "readExpGolomb" {
    // Exp-Golomb codes:
    // 1 = 0
    // 010 = 1
    // 011 = 2
    // 00100 = 3
    const data = [_]u8{ 0b10100110, 0b01000000 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 0), reader.readExpGolomb()); // 1
    try std.testing.expectEqual(@as(?u32, 1), reader.readExpGolomb()); // 010
    try std.testing.expectEqual(@as(?u32, 2), reader.readExpGolomb()); // 011
    try std.testing.expectEqual(@as(?u32, 3), reader.readExpGolomb()); // 00100
}

test "readSignedExpGolomb" {
    // Signed Exp-Golomb mapping: code_num 0->0, 1->1, 2->-1, 3->2, 4->-2
    // Codes: 0=1, 1=010, 2=011, 3=00100, 4=00101
    // Layout: 1 010 011 00100 00101 = 10100110 01000010 1...
    const data = [_]u8{ 0b10100110, 0b01000010, 0b10000000 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?i32, 0), reader.readSignedExpGolomb()); // code 0 -> 0
    try std.testing.expectEqual(@as(?i32, 1), reader.readSignedExpGolomb()); // code 1 -> 1
    try std.testing.expectEqual(@as(?i32, -1), reader.readSignedExpGolomb()); // code 2 -> -1
    try std.testing.expectEqual(@as(?i32, 2), reader.readSignedExpGolomb()); // code 3 -> 2
    try std.testing.expectEqual(@as(?i32, -2), reader.readSignedExpGolomb()); // code 4 -> -2
}

test "readSignedTwosComplement" {
    // 4-bit two's complement: 0111=7, 1111=-1, 1000=-8
    const data = [_]u8{ 0b01111111, 0b10000000 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?i32, 7), reader.readSignedTwosComplement(4)); // 0111
    try std.testing.expectEqual(@as(?i32, -1), reader.readSignedTwosComplement(4)); // 1111
    try std.testing.expectEqual(@as(?i32, -8), reader.readSignedTwosComplement(4)); // 1000
}

test "alignToByte" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    _ = reader.readBits(3); // Read 3 bits
    try std.testing.expectEqual(@as(usize, 3), reader.getBitPosition());
    reader.alignToByte();
    try std.testing.expectEqual(@as(usize, 8), reader.getBitPosition());
    try std.testing.expectEqual(@as(?u32, 0b01011010), reader.readBits(8));
}

test "hasMore and remainingBits" {
    const data = [_]u8{0xFF};
    var reader = BitReader.init(&data);

    try std.testing.expect(reader.hasMore());
    try std.testing.expectEqual(@as(usize, 8), reader.remainingBits());

    _ = reader.readBits(4);
    try std.testing.expect(reader.hasMore());
    try std.testing.expectEqual(@as(usize, 4), reader.remainingBits());

    _ = reader.readBits(4);
    try std.testing.expect(!reader.hasMore());
    try std.testing.expectEqual(@as(usize, 0), reader.remainingBits());
}

test "seek operations" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var reader = BitReader.init(&data);

    _ = reader.readBits(8);
    try std.testing.expectEqual(@as(usize, 8), reader.getBitPosition());

    try std.testing.expect(reader.seekToBit(4));
    try std.testing.expectEqual(@as(usize, 4), reader.getBitPosition());

    try std.testing.expect(reader.seekToByte(2));
    try std.testing.expectEqual(@as(usize, 16), reader.getBitPosition());

    try std.testing.expect(!reader.seekToByte(4)); // Past end
}

test "cross-byte reads" {
    // Test reading values that span byte boundaries
    const data = [_]u8{ 0b11110000, 0b00001111 };
    var reader = BitReader.init(&data);

    // Skip 4 bits, then read 8 bits spanning both bytes
    _ = reader.readBits(4);
    try std.testing.expectEqual(@as(?u32, 0b00000000), reader.readBits(8));
}

test "readBits64" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
    var reader = BitReader.init(&data);

    // Read full 64 bits
    const val = reader.readBits64(64) orelse unreachable;
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), val);

    // Read 4 more
    try std.testing.expectEqual(@as(?u64, 0x0), reader.readBits64(4));
}
