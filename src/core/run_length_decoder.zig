//! PDF RunLengthDecode filter decoder.
//!
//! Decodes run-length encoded data as specified in PDF Reference.
//! - Length byte 0-127: copy next (length+1) bytes literally
//! - Length byte 129-255: repeat next byte (257-length) times
//! - Length byte 128: EOD (end of data)

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RunLengthDecodeError = error{
	UnexpectedEndOfData,
	OutOfMemory,
};

/// Decode run-length encoded data.
/// Returns allocated buffer that caller must free.
pub fn decode(allocator: Allocator, input: []const u8) RunLengthDecodeError![]u8 {
	var result: std.ArrayListUnmanaged(u8) = .{};
	errdefer result.deinit(allocator);

	var i: usize = 0;
	while (i < input.len) {
		const length_byte = input[i];
		i += 1;

		if (length_byte == 128) {
			// EOD marker
			break;
		} else if (length_byte < 128) {
			// Literal run: copy next (length+1) bytes
			const count = @as(usize, length_byte) + 1;
			if (i + count > input.len) {
				return RunLengthDecodeError.UnexpectedEndOfData;
			}
			result.appendSlice(allocator, input[i .. i + count]) catch return RunLengthDecodeError.OutOfMemory;
			i += count;
		} else {
			// Repeat run: repeat next byte (257-length) times
			if (i >= input.len) {
				return RunLengthDecodeError.UnexpectedEndOfData;
			}
			const count = 257 - @as(usize, length_byte);
			const byte = input[i];
			i += 1;
			result.appendNTimes(allocator, byte, count) catch return RunLengthDecodeError.OutOfMemory;
		}
	}

	return result.toOwnedSlice(allocator) catch return RunLengthDecodeError.OutOfMemory;
}

// ============ Tests ============

test "decode literal run" {
	const allocator = std.testing.allocator;

	// Length 4 (0x04) means copy next 5 bytes
	const input = [_]u8{ 0x04, 'H', 'e', 'l', 'l', 'o', 128 };
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode repeat run" {
	const allocator = std.testing.allocator;

	// Length 252 (0xFC) means repeat next byte (257-252)=5 times
	const input = [_]u8{ 0xFC, 'A', 128 };
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("AAAAA", result);
}

test "decode mixed literal and repeat" {
	const allocator = std.testing.allocator;

	// "Hello" as literal, then 3 x's as repeat
	const input = [_]u8{
		0x04, 'H', 'e', 'l', 'l', 'o', // literal: 5 bytes
		0xFE, 'x', // repeat 'x' 3 times (257-254=3)
		128, // EOD
	};
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Helloxxx", result);
}

test "decode empty" {
	const allocator = std.testing.allocator;

	const input = [_]u8{128};
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decode without EOD marker" {
	const allocator = std.testing.allocator;

	// Should decode everything when no EOD
	const input = [_]u8{ 0x02, 'a', 'b', 'c' };
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("abc", result);
}

test "decode maximum literal run" {
	const allocator = std.testing.allocator;

	// Length 127 means copy next 128 bytes
	var input: [130]u8 = undefined;
	input[0] = 127;
	for (1..129) |j| {
		input[j] = 'X';
	}
	input[129] = 128;

	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 128), result.len);
	for (result) |c| {
		try std.testing.expectEqual(@as(u8, 'X'), c);
	}
}

test "decode maximum repeat run" {
	const allocator = std.testing.allocator;

	// Length 129 means repeat byte (257-129)=128 times
	const input = [_]u8{ 129, 'Y', 128 };
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 128), result.len);
	for (result) |c| {
		try std.testing.expectEqual(@as(u8, 'Y'), c);
	}
}

test "decode truncated literal run" {
	const allocator = std.testing.allocator;

	// Claims 5 bytes but only 3 follow
	const input = [_]u8{ 0x04, 'a', 'b', 'c' };
	const result = decode(allocator, &input);
	try std.testing.expectError(RunLengthDecodeError.UnexpectedEndOfData, result);
}

test "decode truncated repeat run" {
	const allocator = std.testing.allocator;

	// Repeat marker but no byte to repeat
	const input = [_]u8{0xFC};
	const result = decode(allocator, &input);
	try std.testing.expectError(RunLengthDecodeError.UnexpectedEndOfData, result);
}

test "decode binary data" {
	const allocator = std.testing.allocator;

	const input = [_]u8{
		0x03, 0x00, 0xFF, 0x80, 0x7F, // 4 literal bytes
		0xFD, 0x00, // repeat 0x00 four times (257-253=4)
		128,
	};
	const result = try decode(allocator, &input);
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF, 0x80, 0x7F, 0x00, 0x00, 0x00, 0x00 }, result);
}
