//! xxHash64 — fast non-cryptographic hash (Yann Collet, 2012).
//! Used by Zstd for content checksums. Seed is always 0 for Zstd frames.
//! Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md

const std = @import("std");

const PRIME64_1: u64 = 0x9E3779B185EBCA87;
const PRIME64_2: u64 = 0xC2B2AE3D27D4EB4F;
const PRIME64_3: u64 = 0x165667B19E3779F9;
const PRIME64_4: u64 = 0x85EBCA77C2B2AE63;
const PRIME64_5: u64 = 0x27D4EB2F165667C5;

/// Compute xxHash64 of the given data with the given seed.
pub fn hash(data: []const u8, seed: u64) u64 {
	const len = data.len;
	var h: u64 = undefined;

	if (len >= 32) {
		var v1: u64 = seed +% PRIME64_1 +% PRIME64_2;
		var v2: u64 = seed +% PRIME64_2;
		var v3: u64 = seed;
		var v4: u64 = seed -% PRIME64_1;

		var pos: usize = 0;
		while (pos + 32 <= len) : (pos += 32) {
			v1 = round(v1, readLE64(data[pos..][0..8]));
			v2 = round(v2, readLE64(data[pos + 8 ..][0..8]));
			v3 = round(v3, readLE64(data[pos + 16 ..][0..8]));
			v4 = round(v4, readLE64(data[pos + 24 ..][0..8]));
		}

		h = std.math.rotl(u64, v1, 1) +%
			std.math.rotl(u64, v2, 7) +%
			std.math.rotl(u64, v3, 12) +%
			std.math.rotl(u64, v4, 18);

		h = mergeAccumulator(h, v1);
		h = mergeAccumulator(h, v2);
		h = mergeAccumulator(h, v3);
		h = mergeAccumulator(h, v4);

		// Mix in total length BEFORE processing remaining bytes (per spec)
		h +%= @as(u64, @intCast(len));

		// Process remaining bytes after the last 32-byte stripe
		while (pos + 8 <= len) : (pos += 8) {
			const k1 = round(0, readLE64(data[pos..][0..8]));
			h ^= k1;
			h = std.math.rotl(u64, h, 27) *% PRIME64_1 +% PRIME64_4;
		}

		while (pos + 4 <= len) : (pos += 4) {
			h ^= @as(u64, std.mem.readInt(u32, data[pos..][0..4], .little)) *% PRIME64_1;
			h = std.math.rotl(u64, h, 23) *% PRIME64_2 +% PRIME64_3;
		}

		while (pos < len) : (pos += 1) {
			h ^= @as(u64, data[pos]) *% PRIME64_5;
			h = std.math.rotl(u64, h, 11) *% PRIME64_1;
		}
	} else {
		h = seed +% PRIME64_5;

		// Mix in total length BEFORE processing bytes (per spec)
		h +%= @as(u64, @intCast(len));

		var pos: usize = 0;

		while (pos + 8 <= len) : (pos += 8) {
			const k1 = round(0, readLE64(data[pos..][0..8]));
			h ^= k1;
			h = std.math.rotl(u64, h, 27) *% PRIME64_1 +% PRIME64_4;
		}

		while (pos + 4 <= len) : (pos += 4) {
			h ^= @as(u64, std.mem.readInt(u32, data[pos..][0..4], .little)) *% PRIME64_1;
			h = std.math.rotl(u64, h, 23) *% PRIME64_2 +% PRIME64_3;
		}

		while (pos < len) : (pos += 1) {
			h ^= @as(u64, data[pos]) *% PRIME64_5;
			h = std.math.rotl(u64, h, 11) *% PRIME64_1;
		}
	}

	// Final avalanche
	h = avalanche(h);

	return h;
}

fn round(acc: u64, input: u64) u64 {
	var v = acc +% (input *% PRIME64_2);
	v = std.math.rotl(u64, v, 31);
	v *%= PRIME64_1;
	return v;
}

fn mergeAccumulator(h_in: u64, acc: u64) u64 {
	const val = round(0, acc);
	var h = h_in ^ val;
	h = h *% PRIME64_1 +% PRIME64_4;
	return h;
}

fn avalanche(h_in: u64) u64 {
	var h = h_in;
	h ^= h >> 33;
	h *%= PRIME64_2;
	h ^= h >> 29;
	h *%= PRIME64_3;
	h ^= h >> 32;
	return h;
}

fn readLE64(bytes: *const [8]u8) u64 {
	return std.mem.readInt(u64, bytes, .little);
}

/// Streaming xxHash64 state for incremental hashing.
pub const XxHash64 = struct {
	v1: u64,
	v2: u64,
	v3: u64,
	v4: u64,
	total_len: u64,
	buf: [32]u8,
	buf_len: usize,
	seed: u64,

	pub fn init(seed: u64) XxHash64 {
		return .{
			.v1 = seed +% PRIME64_1 +% PRIME64_2,
			.v2 = seed +% PRIME64_2,
			.v3 = seed,
			.v4 = seed -% PRIME64_1,
			.total_len = 0,
			.buf = undefined,
			.buf_len = 0,
			.seed = seed,
		};
	}

	pub fn update(self: *XxHash64, data: []const u8) void {
		var input = data;
		self.total_len += input.len;

		// If we have buffered data, try to fill the 32-byte stripe
		if (self.buf_len > 0) {
			const needed = 32 - self.buf_len;
			if (input.len < needed) {
				@memcpy(self.buf[self.buf_len..][0..input.len], input);
				self.buf_len += input.len;
				return;
			}
			@memcpy(self.buf[self.buf_len..][0..needed], input[0..needed]);
			input = input[needed..];

			self.v1 = round(self.v1, readLE64(self.buf[0..8]));
			self.v2 = round(self.v2, readLE64(self.buf[8..16]));
			self.v3 = round(self.v3, readLE64(self.buf[16..24]));
			self.v4 = round(self.v4, readLE64(self.buf[24..32]));
			self.buf_len = 0;
		}

		// Process full 32-byte stripes
		while (input.len >= 32) {
			self.v1 = round(self.v1, readLE64(input[0..8]));
			self.v2 = round(self.v2, readLE64(input[8..16]));
			self.v3 = round(self.v3, readLE64(input[16..24]));
			self.v4 = round(self.v4, readLE64(input[24..32]));
			input = input[32..];
		}

		// Buffer remaining
		if (input.len > 0) {
			@memcpy(self.buf[0..input.len], input);
			self.buf_len = input.len;
		}
	}

	pub fn final(self: *const XxHash64) u64 {
		var h: u64 = undefined;
		const len = self.total_len;

		if (len >= 32) {
			h = std.math.rotl(u64, self.v1, 1) +%
				std.math.rotl(u64, self.v2, 7) +%
				std.math.rotl(u64, self.v3, 12) +%
				std.math.rotl(u64, self.v4, 18);

			h = mergeAccumulator(h, self.v1);
			h = mergeAccumulator(h, self.v2);
			h = mergeAccumulator(h, self.v3);
			h = mergeAccumulator(h, self.v4);
		} else {
			h = self.seed +% PRIME64_5;
		}

		h +%= len;

		// Process remaining buffered bytes
		const remaining = self.buf[0..self.buf_len];
		var pos: usize = 0;

		while (pos + 8 <= remaining.len) : (pos += 8) {
			const k1 = round(0, readLE64(remaining[pos..][0..8]));
			h ^= k1;
			h = std.math.rotl(u64, h, 27) *% PRIME64_1 +% PRIME64_4;
		}

		while (pos + 4 <= remaining.len) : (pos += 4) {
			h ^= @as(u64, std.mem.readInt(u32, remaining[pos..][0..4], .little)) *% PRIME64_1;
			h = std.math.rotl(u64, h, 23) *% PRIME64_2 +% PRIME64_3;
		}

		while (pos < remaining.len) : (pos += 1) {
			h ^= @as(u64, remaining[pos]) *% PRIME64_5;
			h = std.math.rotl(u64, h, 11) *% PRIME64_1;
		}

		return avalanche(h);
	}
};

// ======================== Tests ========================

const testing = std.testing;

// Official xxHash test vectors from the spec (seed = 0)
test "xxhash64: empty string" {
	const h = hash("", 0);
	try testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), h);
}

test "xxhash64: single byte (0)" {
	const h = hash(&[_]u8{0}, 0);
	// Known test vector for single zero byte
	try testing.expectEqual(@as(u64, 0xE934A84ADB052768), h);
}

test "xxhash64: 'Hello, this is a test file for compression format validation.\\n'" {
	const input = "Hello, this is a test file for compression format validation.\n";
	const h = hash(input, 0);
	// Verified via Python xxhash library
	try testing.expectEqual(@as(u64, 0xc5cfbfa0b1d8e148), h);
	// Lower 32 bits should match the Zstd checksum in sample.zst
	try testing.expectEqual(@as(u32, 0xb1d8e148), @as(u32, @truncate(h)));
}

test "xxhash64: 14 bytes" {
	// Test vector: exactly 14 bytes (< 32 threshold, exercises 8-byte + 4-byte + 2-byte paths)
	const input = "Hello, World!\n";
	const h = hash(input, 0);
	// Just verify it's deterministic
	const h2 = hash(input, 0);
	try testing.expectEqual(h, h2);
}

test "xxhash64: 32+ bytes trigger accumulator path" {
	// 64 bytes — exercises the 32-byte stripe path
	const input = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	const h = hash(input, 0);
	const h2 = hash(input, 0);
	try testing.expectEqual(h, h2);
}

test "xxhash64: streaming matches one-shot" {
	const input = "Hello, this is a test file for compression format validation.\n";
	const expected = hash(input, 0);

	// Feed in various chunk sizes
	const chunk_sizes = [_]usize{ 1, 3, 7, 13, 31, 32, 33, 62 };
	for (chunk_sizes) |chunk_size| {
		var hasher = XxHash64.init(0);
		var pos: usize = 0;
		while (pos < input.len) {
			const end = @min(pos + chunk_size, input.len);
			hasher.update(input[pos..end]);
			pos = end;
		}
		const result = hasher.final();
		try testing.expectEqual(expected, result);
	}
}

test "xxhash64: streaming empty" {
	var hasher = XxHash64.init(0);
	const result = hasher.final();
	try testing.expectEqual(hash("", 0), result);
}

test "xxhash64: seed matters" {
	const input = "test";
	const h0 = hash(input, 0);
	const h1 = hash(input, 1);
	try testing.expect(h0 != h1);
}
