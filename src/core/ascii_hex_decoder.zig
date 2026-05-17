//! PDF ASCIIHexDecode filter decoder.
//!
//! Decodes hexadecimal-encoded data as specified in PDF Reference.
//! Each pair of hex digits (0-9, A-F, a-f) produces one output byte.
//! Whitespace is ignored. The `>` character marks end-of-data.
//! If there's an odd number of hex digits, the final digit is assumed
//! to be followed by 0.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AsciiHexDecodeError = error{
	InvalidHexChar,
	OutOfMemory,
};

/// Decode ASCIIHex-encoded data.
/// Returns allocated buffer that caller must free.
pub fn decode(allocator: Allocator, input: []const u8) AsciiHexDecodeError![]u8 {
	// Output is at most half the input size (2 hex chars = 1 byte)
	var result: std.ArrayListUnmanaged(u8) = .empty;
	errdefer result.deinit(allocator);

	var high_nibble: ?u4 = null;

	for (input) |c| {
		// End-of-data marker
		if (c == '>') break;

		// Skip whitespace
		if (isWhitespace(c)) continue;

		// Decode hex digit
		const nibble = hexToNibble(c) orelse return AsciiHexDecodeError.InvalidHexChar;

		if (high_nibble) |high| {
			// We have both nibbles, output the byte
			const byte: u8 = (@as(u8, high) << 4) | @as(u8, nibble);
			result.append(allocator, byte) catch return AsciiHexDecodeError.OutOfMemory;
			high_nibble = null;
		} else {
			// Store high nibble for next iteration
			high_nibble = nibble;
		}
	}

	// Handle odd number of hex digits (treat as if followed by 0)
	if (high_nibble) |high| {
		const byte: u8 = @as(u8, high) << 4;
		result.append(allocator, byte) catch return AsciiHexDecodeError.OutOfMemory;
	}

	return result.toOwnedSlice(allocator) catch return AsciiHexDecodeError.OutOfMemory;
}

fn isWhitespace(c: u8) bool {
	return switch (c) {
		' ', '\t', '\n', '\r', '\x0c', '\x00' => true,
		else => false,
	};
}

fn hexToNibble(c: u8) ?u4 {
	return switch (c) {
		'0'...'9' => @intCast(c - '0'),
		'A'...'F' => @intCast(c - 'A' + 10),
		'a'...'f' => @intCast(c - 'a' + 10),
		else => null,
	};
}

// ============ Tests ============

test "decode valid hex pairs" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "48656C6C6F>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode lowercase hex" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "48656c6c6f>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode mixed case hex" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "48656C6c6F>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode with whitespace" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "48 65 6C\n6C\t6F>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode odd number of digits" {
	const allocator = std.testing.allocator;

	// "F" at end should be treated as "F0"
	const result = try decode(allocator, "48656C6C6F4>");
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 'H', 'e', 'l', 'l', 'o', 0x40 }, result);
}

test "decode empty input" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, ">");
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decode without terminator" {
	const allocator = std.testing.allocator;

	// No '>' terminator - should decode everything
	const result = try decode(allocator, "48656C6C6F");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode invalid hex character" {
	const allocator = std.testing.allocator;

	const result = decode(allocator, "48GG>");
	try std.testing.expectError(AsciiHexDecodeError.InvalidHexChar, result);
}

test "decode binary data" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "00FF807F>");
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x80, 0x7F }, result);
}
