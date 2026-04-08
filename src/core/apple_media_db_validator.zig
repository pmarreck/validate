const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const zlib = @import("zlib.zig");

/// Apple Media Library Database (hfma) deep validator.
/// Validates .musicdb and .tvdb files used by Music.app and TV.app.
/// Format: 160-byte header + AES-128-ECB encrypted + zlib-compressed payload
/// containing FourCC-tagged chunks (itma, plma, ltma, etc.).
pub fn validateAppleMediaDbDeep(allocator: Allocator, path: []const u8) ValidationResult {
	const file = std.fs.cwd().openFile(path, .{}) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Failed to open file", .structural);
	};
	defer file.close();

	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Failed to get file size", .structural);
	};

	// Minimum: 160-byte header + at least 16 bytes of encrypted data
	if (file_size < header_size + 16) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "File too small for hfma format", .structural);
	}

	var header: [header_size]u8 = undefined;
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Failed to read header", .structural);
	};
	if (bytes_read < header_size) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Incomplete header", .structural);
	}

	// Verify magic bytes
	if (!std.mem.eql(u8, header[0..4], "hfma")) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Invalid magic bytes (expected 'hfma')", .structural);
	}

	// Header size field at offset 4 (u32 LE) — should be 0xA0 (160)
	const declared_header_size = std.mem.readInt(u32, header[4..8], .little);
	if (declared_header_size != header_size) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Invalid header size field", .structural);
	}

	// Total file size at offset 8 (u32 LE)
	const declared_file_size = std.mem.readInt(u32, header[8..12], .little);
	if (declared_file_size == 0) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Declared file size is zero", .structural);
	}
	if (declared_file_size != @as(u32, @truncate(file_size))) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Declared file size mismatch", .structural);
	}

	// Version string at offset 16, null-terminated, up to 32 bytes
	if (!validateVersionString(header[16..48])) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Invalid version string", .structural);
	}

	// Read the payload (everything after the 160-byte header)
	const payload_size = file_size - header_size;
	const payload = allocator.alloc(u8, @intCast(payload_size)) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Out of memory reading payload", .structural);
	};
	defer allocator.free(payload);

	file.seekTo(header_size) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Failed to seek past header", .structural);
	};
	const payload_read = file.readAll(payload) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Failed to read payload", .structural);
	};

	// AES-128-ECB decrypt the payload (aligned to 16-byte blocks)
	const aligned_size = payload_read & ~@as(usize, 15);
	if (aligned_size > 0) {
		decryptAes128Ecb(payload[0..aligned_size]);
	}

	// The decrypted data is zlib-compressed
	const decompressed = zlib.inflateZlibAlloc(allocator, payload[0..payload_read], 64 * 1024 * 1024) catch {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Zlib decompression failed", .full);
	};
	defer allocator.free(decompressed);

	if (decompressed.len < 4) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Decompressed data too small", .full);
	}

	// Validate inner structure: should start with "hfma" (inner copy) or contain
	// recognized FourCC chunks. The inner data uses 4-byte type + 4-byte length chunks.
	if (!validateInnerChunks(decompressed)) {
		return ValidationResult.invalidWithDepth(.apple_media_db, "Invalid inner chunk structure", .full);
	}

	return ValidationResult.okWithDepth(.apple_media_db, .full);
}

const header_size: u64 = 0xA0; // 160 bytes

/// AES-128-ECB key used by Apple for iTunes/Music/TV library databases.
const aes_key = "BHUILuilfghuila3".*;

/// Decrypt AES-128-ECB in-place. Data length must be a multiple of 16.
fn decryptAes128Ecb(data: []u8) void {
	const Aes128 = std.crypto.core.aes.Aes128;
	const aes = Aes128.initDec(aes_key);

	var i: usize = 0;
	while (i + 16 <= data.len) : (i += 16) {
		var block: [16]u8 = data[i..][0..16].*;
		aes.decrypt(&block, &block);
		@memcpy(data[i..][0..16], &block);
	}
}

/// Validate version string at header offset 16: expect dotted numeric like "1.6.5.3".
/// Public wrapper for structural validation in format_validation.zig.
pub fn validateVersionStringPub(bytes: []const u8) bool {
	if (bytes.len < 32) return false;
	return validateVersionString(bytes[0..32]);
}

fn validateVersionString(bytes: *const [32]u8) bool {
	// Find null terminator
	var len: usize = 0;	for (bytes) |b| {
		if (b == 0) break;
		len += 1;
	}
	if (len < 5) return false; // Minimum: "1.0.0" but Apple uses 4-part

	const version = bytes[0..len];
	var dot_count: usize = 0;
	for (version) |c| {
		if (c == '.') {
			dot_count += 1;
		} else if (c < '0' or c > '9') {
			return false;
		}
	}
	// Apple uses 4-part versions (3 dots), but accept 2+ dots for flexibility
	return dot_count >= 2;
}

/// Known FourCC chunk types in decrypted Apple media library data.
const known_fourccs = [_]*const [4]u8{
	"hfma", // File header (inner copy)
	"hsma", // Section boundary marker
	"plma", // Playlist master container
	"lama", // Album list master
	"iama", // Individual album metadata
	"lAma", // Artist list master
	"iAma", // Individual artist metadata
	"ltma", // Track list master
	"itma", // Individual track metadata
	"lPma", // Playlist list master
	"lpma", // Individual playlist
	"boma", // Metadata block
	"ipfa", // Identifier block
};

/// Check if a 4-byte slice matches any known FourCC.
fn isKnownFourcc(tag: *const [4]u8) bool {
	for (known_fourccs) |known| {
		if (std.mem.eql(u8, tag, known)) return true;
	}
	return false;
}

/// Validate decompressed inner chunk structure.
/// Chunks use 4-byte FourCC type + 4-byte LE length.
fn validateInnerChunks(data: []const u8) bool {
	if (data.len < 8) return false;

	// The first chunk should be "hsma" (section marker) or "hfma" (inner header)
	if (!std.mem.eql(u8, data[0..4], "hfma") and !std.mem.eql(u8, data[0..4], "hsma")) return false;

	// Walk chunks: each is type(4) + length(4) + payload
	var offset: usize = 0;
	var valid_chunks: usize = 0;
	const max_chunks: usize = 1000; // Safety limit

	while (offset + 8 <= data.len and valid_chunks < max_chunks) {
		const tag = data[offset..][0..4];
		const chunk_len = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);

		if (!isKnownFourcc(tag)) {
			// Unknown chunk type — if we've seen at least one valid chunk
			// (the header), allow it as potentially a newer format extension.
			// But if the very first chunk is unknown, fail.
			if (valid_chunks == 0) return false;
			// For non-first chunks, just stop walking (don't fail)
			break;
		}

		valid_chunks += 1;

		// Advance past this chunk
		if (chunk_len == 0) {
			// Zero-length chunk — advance past just the header
			offset += 8;
		} else if (chunk_len <= data.len - offset) {
			offset += @intCast(chunk_len);
		} else {
			// Chunk extends past end of data — could be last chunk with trailing data
			break;
		}
	}

	return valid_chunks >= 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "hfma magic detection" {
	var header: [160]u8 = undefined;
	@memset(&header, 0);
	@memcpy(header[0..4], "hfma");
	// Set header size field
	std.mem.writeInt(u32, header[4..8], 0xA0, .little);

	const format = format_validation.detectFormat(&header);
	try testing.expectEqual(format_validation.FileFormat.apple_media_db, format);
}

test "hfma magic detection rejects wrong magic" {
	var header: [160]u8 = undefined;
	@memset(&header, 0);
	@memcpy(header[0..4], "hdfm"); // old iTunes format, not hfma
	std.mem.writeInt(u32, header[4..8], 0xA0, .little);

	const format = format_validation.detectFormat(&header);
	try testing.expect(format != .apple_media_db);
}

test "validateVersionString accepts valid versions" {
	const v1: [32]u8 = blk: {
		var buf: [32]u8 = undefined;
		@memset(&buf, 0);
		@memcpy(buf[0..7], "1.6.5.3");
		break :blk buf;
	};
	try testing.expect(validateVersionString(&v1));

	const v2: [32]u8 = blk: {
		var buf: [32]u8 = undefined;
		@memset(&buf, 0);
		@memcpy(buf[0..8], "1.6.4.88");
		break :blk buf;
	};
	try testing.expect(validateVersionString(&v2));
}

test "validateVersionString rejects invalid versions" {
	const bad1: [32]u8 = blk: {
		var buf: [32]u8 = undefined;
		@memset(&buf, 0);
		@memcpy(buf[0..3], "abc");
		break :blk buf;
	};
	try testing.expect(!validateVersionString(&bad1));

	// Too short
	const bad2: [32]u8 = blk: {
		var buf: [32]u8 = undefined;
		@memset(&buf, 0);
		@memcpy(buf[0..1], "1");
		break :blk buf;
	};
	try testing.expect(!validateVersionString(&bad2));
}

test "AES-128-ECB round-trip" {
	const Aes128 = std.crypto.core.aes.Aes128;

	// Encrypt a known block then decrypt it
	const plaintext: [16]u8 = "Hello, Apple DB!".*;
	var ciphertext: [16]u8 = undefined;
	const enc = Aes128.initEnc(aes_key);
	enc.encrypt(&ciphertext, &plaintext);

	// Now decrypt with our function
	var data: [16]u8 = ciphertext;
	decryptAes128Ecb(&data);
	try testing.expectEqualSlices(u8, &plaintext, &data);
}

test "validateInnerChunks accepts valid structure" {
	// Build a minimal valid inner structure: hfma header + hsma section
	var buf: [24]u8 = undefined;
	@memcpy(buf[0..4], "hfma"); // chunk type
	std.mem.writeInt(u32, buf[4..8], 16, .little); // chunk length (includes type+len+8 payload)
	@memset(buf[8..16], 0); // payload
	@memcpy(buf[16..20], "hsma"); // second chunk
	std.mem.writeInt(u32, buf[20..24], 8, .little); // minimal chunk

	try testing.expect(validateInnerChunks(&buf));
}

test "validateInnerChunks rejects non-hfma start" {
	var buf: [16]u8 = undefined;
	@memcpy(buf[0..4], "xxxx");
	std.mem.writeInt(u32, buf[4..8], 16, .little);
	@memset(buf[8..16], 0);

	try testing.expect(!validateInnerChunks(&buf));
}

test "deep validation of real tvdb file" {
	const test_path = "ground_truth_examples/apple_media_db/sample.tvdb";
	const file = std.fs.cwd().openFile(test_path, .{}) catch {
		return error.SkipZigTest;
	};
	file.close();

	const result = validateAppleMediaDbDeep(testing.allocator, test_path);
	try testing.expect(result.is_valid);
	try testing.expectEqual(format_validation.FileFormat.apple_media_db, result.format);
}

test "deep validation of real musicdb file" {
	const test_path = "ground_truth_examples/apple_media_db/sample.musicdb";
	const file = std.fs.cwd().openFile(test_path, .{}) catch {
		return error.SkipZigTest;
	};
	file.close();

	const result = validateAppleMediaDbDeep(testing.allocator, test_path);
	try testing.expect(result.is_valid);
	try testing.expectEqual(format_validation.FileFormat.apple_media_db, result.format);
}
test "deep validation rejects truncated file" {
	// Create a minimal header-only file (too small to have valid encrypted data)
	var header: [160]u8 = undefined;
	@memset(&header, 0);
	@memcpy(header[0..4], "hfma");
	std.mem.writeInt(u32, header[4..8], 0xA0, .little);
	std.mem.writeInt(u32, header[8..12], 192, .little); // total file size (160 header + 32 payload)
	@memcpy(header[16..23], "1.6.5.3");
	// Write to temp file
	const tmp_path = "/tmp/test_hfma_truncated.tvdb";
	const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return error.SkipZigTest;
	tmp_file.writeAll(&header) catch return error.SkipZigTest;
	// Write only 16 bytes of "encrypted" data (not enough for valid zlib after decrypt)
	const fake_payload = [_]u8{0} ** 32;
	tmp_file.writeAll(&fake_payload) catch return error.SkipZigTest;
	tmp_file.close();
	defer std.fs.cwd().deleteFile(tmp_path) catch {};

	const result = validateAppleMediaDbDeep(testing.allocator, tmp_path);
	try testing.expect(!result.is_valid);
}
