//! Shared codec/validator utility functions.
//!
//! Consolidates duplicated algorithms (CRC, RBSP, start codes, LEB128,
//! endian helpers) that were previously copy-pasted across multiple
//! validator files. All functions are pure (no I/O, no allocations).

const std = @import("std");

// ============================================================================
// CRC-32 Normal Form (MSB-first, polynomial 0x04C11DB7)
// ============================================================================

/// Comptime-parameterized MSB-first CRC-32 using polynomial 0x04C11DB7.
/// Instantiate with different `init_val` and `xor_out` to get OGG, MPEG-2,
/// or bzip2 variants — all share the same lookup table.
pub fn Crc32Normal(comptime init_val: u32, comptime xor_out: u32) type {
	return struct {
		const Self = @This();

		crc: u32,

		/// Precomputed MSB-first lookup table for polynomial 0x04C11DB7.
		const table: [256]u32 = blk: {
			@setEvalBranchQuota(10000);
			var t: [256]u32 = undefined;
			for (0..256) |i| {
				var c: u32 = @as(u32, @intCast(i)) << 24;
				for (0..8) |_| {
					if (c & 0x80000000 != 0) {
						c = (c << 1) ^ 0x04C11DB7;
					} else {
						c = c << 1;
					}
				}
				t[i] = c;
			}
			break :blk t;
		};

		pub fn init() Self {
			return .{ .crc = init_val };
		}

		pub fn update(self: *Self, byte: u8) void {
			const idx = ((self.crc >> 24) ^ byte) & 0xFF;
			self.crc = (self.crc << 8) ^ table[idx];
		}

		pub fn updateSlice(self: *Self, data: []const u8) void {
			for (data) |byte| {
				self.update(byte);
			}
		}

		pub fn final(self: Self) u32 {
			return self.crc ^ xor_out;
		}

		/// One-shot hash: init, feed all data, finalize.
		pub fn hash(data: []const u8) u32 {
			var h = Self.init();
			h.updateSlice(data);
			return h.final();
		}
	};
}

/// CRC-32 OGG: init=0, xorout=0 (MSB-first, poly 0x04C11DB7)
pub const Crc32Ogg = Crc32Normal(0, 0);

/// CRC-32 MPEG-2: init=0xFFFFFFFF, xorout=0 (MSB-first, poly 0x04C11DB7)
pub const Crc32Mpeg2 = Crc32Normal(0xFFFFFFFF, 0);

/// CRC-32 bzip2: init=0xFFFFFFFF, xorout=0xFFFFFFFF (MSB-first, poly 0x04C11DB7)
pub const Crc32Bzip2 = Crc32Normal(0xFFFFFFFF, 0xFFFFFFFF);

// ============================================================================
// CRC-16/CCITT (polynomial 0x1021, MSB-first, init=0)
// ============================================================================

/// CRC-16/CCITT used by RAR4 headers and BinHex 4.0.
/// Polynomial 0x1021, init=0, MSB-first, no final XOR.
pub fn crc16Ccitt(data: []const u8) u16 {
	var crc: u16 = 0;
	for (data) |byte| {
		crc = crc ^ (@as(u16, byte) << 8);
		for (0..8) |_| {
			if ((crc & 0x8000) != 0) {
				crc = (crc << 1) ^ 0x1021;
			} else {
				crc = crc << 1;
			}
		}
	}
	return crc;
}

// ============================================================================
// RBSP Emulation Prevention Byte Removal (H.264 / H.265)
// ============================================================================

/// Remove emulation prevention bytes from a NAL unit to get the RBSP.
/// In H.264/H.265, the byte sequence 0x00 0x00 0x03 is an emulation prevention marker.
/// 0x000003 0x00 -> 0x0000 0x00
/// 0x000003 0x01 -> 0x0000 0x01
/// 0x000003 0x02 -> 0x0000 0x02
/// 0x000003 0x03 -> 0x0000 0x03
///
/// Returns a slice into the provided output buffer, or null if the buffer is too small.
pub fn removeEmulationPreventionBytes(input: []const u8, output: []u8) ?[]u8 {
	if (input.len == 0) return output[0..0];
	if (output.len < input.len) return null;

	var out_idx: usize = 0;
	var i: usize = 0;

	while (i < input.len) {
		if (i + 2 < input.len and input[i] == 0x00 and input[i + 1] == 0x00 and input[i + 2] == 0x03) {
			// Check that the byte after 0x03 is valid (0x00, 0x01, 0x02, or 0x03)
			if (i + 3 < input.len) {
				const next = input[i + 3];
				if (next <= 0x03) {
					// Valid emulation prevention: copy 0x00 0x00, skip 0x03
					output[out_idx] = 0x00;
					output[out_idx + 1] = 0x00;
					out_idx += 2;
					i += 3; // Skip past 0x00 0x00 0x03
					continue;
				}
			} else {
				// 0x000003 at end of data — still a valid EPB (the next byte is implicit)
				output[out_idx] = 0x00;
				output[out_idx + 1] = 0x00;
				out_idx += 2;
				i += 3;
				continue;
			}
		}

		output[out_idx] = input[i];
		out_idx += 1;
		i += 1;
	}

	return output[0..out_idx];
}

// ============================================================================
// Annex B Start Code Finder (H.264 / H.265)
// ============================================================================

/// Result of finding a start code in an Annex B byte stream.
pub const StartCode = struct {
	pos: usize,
	len: u8,
};

/// Find the next Annex B start code (0x000001 or 0x00000001) at or after `from`.
/// Returns the position and length (3 or 4) of the start code, or null if not found.
pub fn findAnnexBStartCode(data: []const u8, from: usize) ?StartCode {
	var i = from;
	while (i + 2 < data.len) {
		if (data[i] == 0x00 and data[i + 1] == 0x00) {
			if (data[i + 2] == 0x01) {
				return .{ .pos = i, .len = 3 };
			}
			if (i + 3 < data.len and data[i + 2] == 0x00 and data[i + 3] == 0x01) {
				return .{ .pos = i, .len = 4 };
			}
		}
		i += 1;
	}
	return null;
}

// ============================================================================
// LEB128 Unsigned Decoder
// ============================================================================

/// Read a LEB128-encoded unsigned integer from data starting at pos.
/// Returns the decoded value or null if the data is truncated or the
/// encoding uses too many bytes (>8).
pub fn readLeb128(data: []const u8, pos: *usize) ?u64 {
	var value: u64 = 0;
	var i: u6 = 0;
	while (i < 8) : (i += 1) {
		if (pos.* >= data.len) return null;
		const byte = data[pos.*];
		pos.* += 1;
		value |= @as(u64, byte & 0x7F) << (i * 7);
		if (byte & 0x80 == 0) return value;
	}
	return null; // Too many bytes
}

// ============================================================================
// Endian Read Helpers
// ============================================================================

/// Read a little-endian integer of type T from a byte slice.
/// The slice must be at least @sizeOf(T) bytes long.
pub fn readLe(comptime T: type, slice: []const u8) T {
	const ptr: *const [@sizeOf(T)]u8 = @ptrCast(slice.ptr);
	return std.mem.readInt(T, ptr, .little);
}

/// Read a big-endian integer of type T from a byte slice.
/// The slice must be at least @sizeOf(T) bytes long.
pub fn readBe(comptime T: type, slice: []const u8) T {
	const ptr: *const [@sizeOf(T)]u8 = @ptrCast(slice.ptr);
	return std.mem.readInt(T, ptr, .big);
}

// ============================================================================
// Tests
// ============================================================================

test "CRC-32 ISO-HDLC - standard test vector" {
	// std.hash.Crc32 is ISO-HDLC (reflected, init=0xFFFFFFFF, xorout=0xFFFFFFFF)
	// "123456789" -> 0xCBF43926
	var h = std.hash.Crc32.init();
	h.update("123456789");
	try std.testing.expectEqual(@as(u32, 0xCBF43926), h.final());
}

test "CRC-32 OGG - standard test vector" {
	// OGG CRC-32: init=0, xorout=0, MSB-first, poly 0x04C11DB7
	// "123456789" -> 0x89A1897F (computed; no standard catalogue name for this variant)
	try std.testing.expectEqual(@as(u32, 0x89A1897F), Crc32Ogg.hash("123456789"));
}

test "CRC-32 OGG - incremental equals one-shot" {
	var h = Crc32Ogg.init();
	h.updateSlice("12345");
	h.updateSlice("6789");
	try std.testing.expectEqual(Crc32Ogg.hash("123456789"), h.final());
}

test "CRC-32 MPEG-2 - standard test vector" {
	// CRC-32/MPEG-2: init=0xFFFFFFFF, xorout=0, MSB-first, poly 0x04C11DB7
	// "123456789" -> 0x0376E6E7
	try std.testing.expectEqual(@as(u32, 0x0376E6E7), Crc32Mpeg2.hash("123456789"));
}

test "CRC-32 bzip2 - standard test vector" {
	// CRC-32/BZIP2: init=0xFFFFFFFF, xorout=0xFFFFFFFF, MSB-first
	// "123456789" -> 0xFC891918
	try std.testing.expectEqual(@as(u32, 0xfc891918), Crc32Bzip2.hash("123456789"));
}

test "CRC-32 bzip2 - empty" {
	var h = Crc32Bzip2.init();
	try std.testing.expectEqual(@as(u32, 0), h.final());
}

test "CRC-32 bzip2 - incremental equals batch" {
	var crc1 = Crc32Bzip2.init();
	crc1.update('h');
	crc1.update('e');
	crc1.update('l');
	crc1.update('l');
	crc1.update('o');

	var crc2 = Crc32Bzip2.init();
	crc2.updateSlice("hello");

	try std.testing.expectEqual(crc1.final(), crc2.final());
}

test "CRC-16 CCITT - basic" {
	// CRC-16/XMODEM (poly=0x1021, init=0): "123456789" -> 0x31C3
	try std.testing.expectEqual(@as(u16, 0x31C3), crc16Ccitt("123456789"));
}

test "CRC-16 CCITT - empty" {
	try std.testing.expectEqual(@as(u16, 0), crc16Ccitt(""));
}

test "RBSP - no emulation prevention bytes" {
	const input = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
	var output: [4]u8 = undefined;
	const result = removeEmulationPreventionBytes(&input, &output);
	try std.testing.expect(result != null);
	try std.testing.expectEqualSlices(u8, &input, result.?);
}

test "RBSP - single emulation prevention byte" {
	// 0x00 0x00 0x03 0x00 -> 0x00 0x00 0x00
	const input = [_]u8{ 0x00, 0x00, 0x03, 0x00 };
	var output: [4]u8 = undefined;
	const result = removeEmulationPreventionBytes(&input, &output);
	try std.testing.expect(result != null);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00 }, result.?);
}

test "RBSP - multiple emulation prevention bytes" {
	// 0x00 0x00 0x03 0x01 0x00 0x00 0x03 0x02
	// -> 0x00 0x00 0x01 0x00 0x00 0x02
	const input = [_]u8{ 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03, 0x02 };
	var output: [8]u8 = undefined;
	const result = removeEmulationPreventionBytes(&input, &output);
	try std.testing.expect(result != null);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x01, 0x00, 0x00, 0x02 }, result.?);
}

test "RBSP - EPB at end of data" {
	// 0x00 0x00 0x03 at end (no following byte)
	const input = [_]u8{ 0x00, 0x00, 0x03 };
	var output: [3]u8 = undefined;
	const result = removeEmulationPreventionBytes(&input, &output);
	try std.testing.expect(result != null);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, result.?);
}

test "RBSP - buffer too small" {
	const input = [_]u8{ 0x01, 0x02, 0x03 };
	var output: [2]u8 = undefined;
	try std.testing.expect(removeEmulationPreventionBytes(&input, &output) == null);
}

test "RBSP - empty input" {
	var output: [1]u8 = undefined;
	const result = removeEmulationPreventionBytes(&[_]u8{}, &output);
	try std.testing.expect(result != null);
	try std.testing.expectEqual(@as(usize, 0), result.?.len);
}

test "Annex B start code - 3-byte" {
	const data = [_]u8{ 0xFF, 0x00, 0x00, 0x01, 0xAA };
	const sc = findAnnexBStartCode(&data, 0);
	try std.testing.expect(sc != null);
	try std.testing.expectEqual(@as(usize, 1), sc.?.pos);
	try std.testing.expectEqual(@as(u8, 3), sc.?.len);
}

test "Annex B start code - 4-byte" {
	const data = [_]u8{ 0xFF, 0x00, 0x00, 0x00, 0x01, 0xAA };
	const sc = findAnnexBStartCode(&data, 0);
	try std.testing.expect(sc != null);
	try std.testing.expectEqual(@as(usize, 1), sc.?.pos);
	try std.testing.expectEqual(@as(u8, 4), sc.?.len);
}

test "Annex B start code - from offset" {
	const data = [_]u8{ 0x00, 0x00, 0x01, 0xAA, 0x00, 0x00, 0x01, 0xBB };
	const sc = findAnnexBStartCode(&data, 3);
	try std.testing.expect(sc != null);
	try std.testing.expectEqual(@as(usize, 4), sc.?.pos);
}

test "Annex B start code - not found" {
	const data = [_]u8{ 0x00, 0x00, 0x02, 0xAA };
	try std.testing.expect(findAnnexBStartCode(&data, 0) == null);
}

test "LEB128 - zero" {
	const data = [_]u8{0x00};
	var pos: usize = 0;
	try std.testing.expectEqual(@as(u64, 0), readLeb128(&data, &pos).?);
	try std.testing.expectEqual(@as(usize, 1), pos);
}

test "LEB128 - 127 (single byte max)" {
	const data = [_]u8{0x7F};
	var pos: usize = 0;
	try std.testing.expectEqual(@as(u64, 127), readLeb128(&data, &pos).?);
}

test "LEB128 - 128 (two bytes)" {
	const data = [_]u8{ 0x80, 0x01 };
	var pos: usize = 0;
	try std.testing.expectEqual(@as(u64, 128), readLeb128(&data, &pos).?);
	try std.testing.expectEqual(@as(usize, 2), pos);
}

test "LEB128 - 624485 (three bytes)" {
	// 624485 = 0xE5 0x8E 0x26
	const data = [_]u8{ 0xE5, 0x8E, 0x26 };
	var pos: usize = 0;
	try std.testing.expectEqual(@as(u64, 624485), readLeb128(&data, &pos).?);
}

test "LEB128 - truncated" {
	const data = [_]u8{0x80}; // continuation bit set but no following byte
	var pos: usize = 0;
	try std.testing.expect(readLeb128(&data, &pos) == null);
}

test "readLe - u16" {
	const data = [_]u8{ 0x34, 0x12 };
	try std.testing.expectEqual(@as(u16, 0x1234), readLe(u16, &data));
}

test "readLe - u32" {
	const data = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
	try std.testing.expectEqual(@as(u32, 0x12345678), readLe(u32, &data));
}

test "readBe - u16" {
	const data = [_]u8{ 0x12, 0x34 };
	try std.testing.expectEqual(@as(u16, 0x1234), readBe(u16, &data));
}

test "readBe - u32" {
	const data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
	try std.testing.expectEqual(@as(u32, 0x12345678), readBe(u32, &data));
}
