//! PDF ASCII85Decode (also known as btoa) filter decoder.
//!
//! Decodes ASCII85-encoded data as specified in PDF Reference.
//! - Each group of 5 ASCII characters (values 33-117, '!' to 'u') decodes to 4 bytes
//! - The special character 'z' represents 4 null bytes (0x00000000)
//! - The sequence '~>' marks end-of-data (EOD)
//! - Whitespace is ignored
//! - Final group may have 2-5 characters, encoding 1-4 bytes

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Ascii85DecodeError = error{
	InvalidChar,
	InvalidZPlacement,
	TruncatedInput,
	Overflow,
	OutOfMemory,
};

/// Decode ASCII85-encoded data.
/// Returns allocated buffer that caller must free.
pub fn decode(allocator: Allocator, input: []const u8) Ascii85DecodeError![]u8 {
	var result: std.ArrayListUnmanaged(u8) = .empty;
	errdefer result.deinit(allocator);

	var group: [5]u8 = undefined;
	var group_len: usize = 0;

	var i: usize = 0;
	while (i < input.len) {
		const c = input[i];

		// Check for end-of-data marker
		if (c == '~') {
			if (i + 1 < input.len and input[i + 1] == '>') {
				break; // EOD found
			}
			// ~ without > is invalid but we'll treat lone ~ as invalid char
			return Ascii85DecodeError.InvalidChar;
		}

		// Skip whitespace
		if (isWhitespace(c)) {
			i += 1;
			continue;
		}

		// Handle 'z' shorthand for 4 null bytes
		if (c == 'z') {
			// 'z' can only appear between complete groups
			if (group_len != 0) {
				return Ascii85DecodeError.InvalidZPlacement;
			}
			try appendBytes(allocator, &result, &[_]u8{ 0, 0, 0, 0 });
			i += 1;
			continue;
		}

		// Validate character is in ASCII85 range ('!' to 'u', 33-117)
		if (c < '!' or c > 'u') {
			return Ascii85DecodeError.InvalidChar;
		}

		// Add to current group
		group[group_len] = c;
		group_len += 1;

		// Process complete group
		if (group_len == 5) {
			const bytes = try decodeGroup(group[0..5], 5);
			try appendBytes(allocator, &result, bytes[0..4]);
			group_len = 0;
		}

		i += 1;
	}

	// Process final partial group
	if (group_len > 0) {
		if (group_len == 1) {
			// Single character is invalid (need at least 2)
			return Ascii85DecodeError.TruncatedInput;
		}

		// Pad with 'u' (max value) for decoding
		var padded: [5]u8 = .{ 'u', 'u', 'u', 'u', 'u' };
		for (group[0..group_len], 0..) |g, j| {
			padded[j] = g;
		}

		const bytes = try decodeGroup(&padded, group_len);
		// Output (group_len - 1) bytes
		const output_bytes = group_len - 1;
		try appendBytes(allocator, &result, bytes[0..output_bytes]);
	}

	return result.toOwnedSlice(allocator) catch return Ascii85DecodeError.OutOfMemory;
}

fn decodeGroup(group: *const [5]u8, actual_len: usize) Ascii85DecodeError![4]u8 {
	// Convert 5 base-85 digits to a 32-bit value
	var value: u64 = 0; // Use u64 to detect overflow

	for (group) |c| {
		value = value * 85 + (c - '!');
	}

	// Check for overflow (max valid value is 85^5 - 1 = 4437053124)
	// But with padding, we can exceed this. For partial groups, we need
	// to handle this differently - the padding causes higher values.
	// For complete groups (actual_len == 5), validate the range.
	if (actual_len == 5 and value > 0xFFFFFFFF) {
		return Ascii85DecodeError.Overflow;
	}

	// Clamp for partial groups (padding with 'u' can cause overflow)
	if (value > 0xFFFFFFFF) {
		value = 0xFFFFFFFF;
	}

	const val32: u32 = @intCast(value);

	return .{
		@intCast((val32 >> 24) & 0xFF),
		@intCast((val32 >> 16) & 0xFF),
		@intCast((val32 >> 8) & 0xFF),
		@intCast(val32 & 0xFF),
	};
}

fn appendBytes(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), bytes: []const u8) Ascii85DecodeError!void {
	list.appendSlice(allocator, bytes) catch return Ascii85DecodeError.OutOfMemory;
}

fn isWhitespace(c: u8) bool {
	return switch (c) {
		' ', '\t', '\n', '\r', '\x0c', '\x00' => true,
		else => false,
	};
}

// ============ Tests ============

test "decode simple string" {
	const allocator = std.testing.allocator;

	// "Man " encodes to "9jqo^"
	const result = try decode(allocator, "9jqo^~>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Man ", result);
}

test "decode Hello" {
	const allocator = std.testing.allocator;

	// "Hello" (5 bytes) encodes to "87cURDZ" (7 chars)
	// First 4 bytes "Hell" -> "87cUR", last 1 byte "o" -> "DZ" (2 chars for 1 byte)
	const result = try decode(allocator, "87cURDZ~>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode with z shorthand" {
	const allocator = std.testing.allocator;

	// 'z' represents four null bytes
	const result = try decode(allocator, "z~>");
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result);
}

test "decode with whitespace" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "87cUR DZ~>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode with newlines" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "87cUR\nDZ~>");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "decode empty" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "~>");
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decode partial group 2 chars" {
	const allocator = std.testing.allocator;

	// 2 chars encode 1 byte
	// "!!" = 0 -> 0x00
	const result = try decode(allocator, "!!~>");
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 1), result.len);
	try std.testing.expectEqual(@as(u8, 0), result[0]);
}

test "decode partial group 3 chars" {
	const allocator = std.testing.allocator;

	// 3 chars encode 2 bytes
	const result = try decode(allocator, "!!!~>");
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "decode partial group 4 chars" {
	const allocator = std.testing.allocator;

	// 4 chars encode 3 bytes
	const result = try decode(allocator, "!!!!~>");
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "decode without terminator" {
	const allocator = std.testing.allocator;

	// Should decode everything when no terminator
	const result = try decode(allocator, "87cURDZ");
	defer allocator.free(result);

	try std.testing.expectEqualStrings("Hello", result);
}

test "invalid character" {
	const allocator = std.testing.allocator;

	// 'v' is outside the valid range
	const result = decode(allocator, "87cURv~>");
	try std.testing.expectError(Ascii85DecodeError.InvalidChar, result);
}

test "z in middle of group" {
	const allocator = std.testing.allocator;

	// 'z' can only appear between complete groups
	const result = decode(allocator, "87z~>");
	try std.testing.expectError(Ascii85DecodeError.InvalidZPlacement, result);
}

test "single character is invalid" {
	const allocator = std.testing.allocator;

	const result = decode(allocator, "!~>");
	try std.testing.expectError(Ascii85DecodeError.TruncatedInput, result);
}

test "multiple z groups" {
	const allocator = std.testing.allocator;

	const result = try decode(allocator, "zz~>");
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, result);
}

test "mixed content with z" {
	const allocator = std.testing.allocator;

	// Complete group, then z, then partial
	const result = try decode(allocator, "9jqo^z!!~>");
	defer allocator.free(result);

	// "Man " + 4 nulls + 1 byte
	try std.testing.expectEqual(@as(usize, 9), result.len);
	try std.testing.expectEqualStrings("Man ", result[0..4]);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result[4..8]);
}
