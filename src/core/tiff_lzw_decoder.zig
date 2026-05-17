//! TIFF LZW decoder.
//!
//! Decodes LZW-compressed data as used in TIFF files.
//! TIFF LZW has minor differences from PDF LZW:
//! - Early change: code width increases at 2^n - 1 (not 2^n)
//! - Same clear (256), EOD (257), first data code (258)
//! - MSB-first bit packing within bytes
//!
//! Reference: TIFF 6.0 Specification, Section 13

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LzwDecodeError = error{
	InvalidCode,
	TableOverflow,
	UnexpectedEndOfData,
	OutOfMemory,
};

const CLEAR_TABLE: u16 = 256;
const EOD: u16 = 257;
const FIRST_CODE: u16 = 258;
const MAX_CODE: u16 = 4095; // 12-bit max
const MAX_TABLE_SIZE: usize = 4096;

/// Dictionary entry - stores string as reference to previous entry + new byte
const DictEntry = struct {
	prefix: ?u16, // Index of prefix entry, null for single-byte entries
	suffix: u8, // Last byte of this entry
	length: u16, // Total length of string this entry represents
};

/// Bit reader for variable-width codes (MSB-first, TIFF-style)
const BitReader = struct {
	data: []const u8,
	byte_pos: usize,
	bit_pos: u3, // 0-7, bits remaining in current byte

	fn init(data: []const u8) BitReader {
		return .{
			.data = data,
			.byte_pos = 0,
			.bit_pos = 0,
		};
	}

	/// Read n bits (9-12) as a code
	fn readCode(self: *BitReader, bits: u4) ?u16 {
		var result: u16 = 0;
		var bits_needed: u4 = bits;

		while (bits_needed > 0) {
			if (self.byte_pos >= self.data.len) {
				return null;
			}

			const current_byte = self.data[self.byte_pos];
			const bits_in_byte: u4 = @intCast(8 - @as(u4, self.bit_pos));
			const bits_to_take: u4 = @min(bits_in_byte, bits_needed);

			// Extract bits from current byte (MSB first)
			const shift: u3 = @intCast(bits_in_byte - bits_to_take);
			const mask: u8 = @as(u8, @intCast((@as(u16, 1) << bits_to_take) - 1)) << shift;
			const extracted: u8 = (current_byte & mask) >> shift;

			result = (result << bits_to_take) | extracted;
			bits_needed -= bits_to_take;

			const new_bit_pos = @as(u4, self.bit_pos) + bits_to_take;
			if (new_bit_pos >= 8) {
				self.byte_pos += 1;
				self.bit_pos = 0;
			} else {
				self.bit_pos = @intCast(new_bit_pos);
			}
		}

		return result;
	}
};

/// Decode TIFF LZW-compressed data.
/// Returns allocated buffer that caller must free.
pub fn decode(allocator: Allocator, input: []const u8) LzwDecodeError![]u8 {
	var result: std.ArrayListUnmanaged(u8) = .empty;
	errdefer result.deinit(allocator);

	// Initialize dictionary with single-byte entries (0-255)
	var dict: [MAX_TABLE_SIZE]DictEntry = undefined;
	for (0..256) |i| {
		dict[i] = .{
			.prefix = null,
			.suffix = @intCast(i),
			.length = 1,
		};
	}
	// Codes 256 (clear) and 257 (EOD) are reserved but not used as entries
	var next_code: u16 = FIRST_CODE;
	var code_bits: u4 = 9;

	var reader = BitReader.init(input);
	var prev_code: ?u16 = null;

	while (true) {
		const code = reader.readCode(code_bits) orelse break;

		if (code == EOD) {
			break;
		}

		if (code == CLEAR_TABLE) {
			// Reset dictionary
			next_code = FIRST_CODE;
			code_bits = 9;
			prev_code = null;
			continue;
		}

		// Decode the current code
		if (code < next_code) {
			// Code exists in dictionary - output it
			try outputString(allocator, &result, &dict, code);

			// Add new entry: previous string + first byte of current string
			if (prev_code) |pc| {
				if (next_code <= MAX_CODE) {
					const first_byte = getFirstByte(&dict, code);
					dict[next_code] = .{
						.prefix = pc,
						.suffix = first_byte,
						.length = dict[pc].length + 1,
					};
					next_code += 1;

					// TIFF "old-style" early change: increase bits when next_code reaches 2^n - 1
					// This is before we run out of codes at the current width
					if (next_code >= (@as(u16, 1) << code_bits) - 1 and code_bits < 12) {
						code_bits += 1;
					}
				}
			}
		} else if (code == next_code) {
			// Special case: code not yet in dictionary
			// String is: previous string + first byte of previous string
			if (prev_code) |pc| {
				const first_byte = getFirstByte(&dict, pc);
				try outputString(allocator, &result, &dict, pc);
				result.append(allocator, first_byte) catch return LzwDecodeError.OutOfMemory;

				if (next_code <= MAX_CODE) {
					dict[next_code] = .{
						.prefix = pc,
						.suffix = first_byte,
						.length = dict[pc].length + 1,
					};
					next_code += 1;

					// TIFF "old-style" early change: same as first occurrence
					if (next_code >= (@as(u16, 1) << code_bits) - 1 and code_bits < 12) {
						code_bits += 1;
					}
				}
			} else {
				return LzwDecodeError.InvalidCode;
			}
		} else {
			return LzwDecodeError.InvalidCode;
		}

		prev_code = code;
	}

	return result.toOwnedSlice(allocator) catch return LzwDecodeError.OutOfMemory;
}

/// Output the string represented by a dictionary entry
fn outputString(allocator: Allocator, result: *std.ArrayListUnmanaged(u8), dict: []const DictEntry, code: u16) LzwDecodeError!void {
	const entry = dict[code];
	const len = entry.length;

	// Ensure capacity for the string
	result.ensureUnusedCapacity(allocator, len) catch return LzwDecodeError.OutOfMemory;

	// Build string by traversing prefix chain
	const start_pos = result.items.len;
	result.items.len += len;

	var pos: usize = start_pos + len;
	var current: u16 = code;
	while (true) {
		pos -= 1;
		result.items[pos] = dict[current].suffix;
		if (dict[current].prefix) |prefix| {
			current = prefix;
		} else {
			break;
		}
	}
}

/// Get the first byte of a dictionary entry's string
fn getFirstByte(dict: []const DictEntry, code: u16) u8 {
	var current = code;
	while (dict[current].prefix) |prefix| {
		current = prefix;
	}
	return dict[current].suffix;
}

// ============ Tests ============

// Helper to pack 9-bit codes into bytes (MSB first)
fn packCodes9(codes: []const u16) [32]u8 {
	var result: [32]u8 = .{0} ** 32;
	var bit_pos: usize = 0;

	for (codes) |code| {
		// Write 9 bits MSB first
		for (0..9) |i| {
			const bit: u1 = @intCast((code >> @intCast(8 - i)) & 1);
			const byte_idx = bit_pos / 8;
			const bit_in_byte: u3 = @intCast(7 - (bit_pos % 8));
			result[byte_idx] |= @as(u8, bit) << bit_in_byte;
			bit_pos += 1;
		}
	}

	return result;
}

test "TIFF LZW decode single byte" {
	const allocator = std.testing.allocator;

	// Code 65 ('A') then EOD (257)
	const codes = [_]u16{ 65, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..3]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("A", result);
}

test "TIFF LZW decode multiple literal bytes" {
	const allocator = std.testing.allocator;

	// Codes: 65 ('A'), 66 ('B'), 67 ('C'), EOD
	const codes = [_]u16{ 65, 66, 67, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..5]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("ABC", result);
}

test "TIFF LZW decode with clear code" {
	const allocator = std.testing.allocator;

	// Clear code (256) resets the dictionary
	// Codes: 65, CLEAR(256), 66, EOD(257)
	const codes = [_]u16{ 65, 256, 66, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..5]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("AB", result);
}

test "TIFF LZW decode empty (just EOD)" {
	const allocator = std.testing.allocator;

	const codes = [_]u16{257};
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..2]);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}
