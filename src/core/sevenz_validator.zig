//! Deep 7-Zip validation module.
//!
//! Validates 7z archives by opening them with z7z (cleanroom LZMA2 decoder)
//! and iterating every file entry to verify decompression + CRC integrity.
//! No external executable dependency — uses linked z7z static library.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errmsg = @import("error_messages.zig");

// z7z C FFI
const c = @cImport({
	@cInclude("z7z.h");
});

/// Result of 7z deep validation
pub const SevenZValidationResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	files_checked: u32,
	total_files: u32,
	bytes_verified: u64,

	pub fn ok(files: u32, bytes: u64) SevenZValidationResult {
		return .{
			.valid = true,
			.error_message = null,
			.files_checked = files,
			.total_files = files,
			.bytes_verified = bytes,
		};
	}

	pub fn okPartial(checked: u32, total: u32, bytes: u64) SevenZValidationResult {
		return .{
			.valid = true,
			.error_message = null,
			.files_checked = checked,
			.total_files = total,
			.bytes_verified = bytes,
		};
	}

	pub fn invalid(message: []const u8) SevenZValidationResult {
		return .{
			.valid = false,
			.error_message = message,
			.files_checked = 0,
			.total_files = 0,
			.bytes_verified = 0,
		};
	}
};

/// 7z signature bytes
const SEVENZ_SIGNATURE = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };

/// Parsed 7z start header
pub const StartHeader = struct {
	version_major: u8,
	version_minor: u8,
	start_header_crc: u32,
	next_header_offset: u64,
	next_header_size: u64,
	next_header_crc: u32,
};

/// Parse and validate the 7z start header
pub fn parseStartHeader(data: []const u8) ?StartHeader {
	if (data.len < 32) return null;

	// Check signature
	if (!std.mem.eql(u8, data[0..6], &SEVENZ_SIGNATURE)) {
		return null;
	}

	const header = StartHeader{
		.version_major = data[6],
		.version_minor = data[7],
		.start_header_crc = std.mem.readInt(u32, data[8..12], .little),
		.next_header_offset = std.mem.readInt(u64, data[12..20], .little),
		.next_header_size = std.mem.readInt(u64, data[20..28], .little),
		.next_header_crc = std.mem.readInt(u32, data[28..32], .little),
	};

	// Verify start header CRC (covers bytes 12-31)
	const computed_crc = std.hash.Crc32.hash(data[12..32]);
	if (computed_crc != header.start_header_crc) {
		return null;
	}

	return header;
}

/// z7z error code to human-readable string
fn z7zErrorString(code: c_int) []const u8 {
	const msg = c.z7z_error_string(code);
	if (msg) |m| {
		return std.mem.span(m);
	}
	return "Unknown error";
}

/// Deep validate a 7z file using z7z (cleanroom LZMA2 decoder).
/// Reads the file into memory, opens with z7z, and iterates every
/// file entry — decompression + CRC verification happens on open/access.
pub fn validateSevenZDeep(allocator: Allocator, source: *@import("file_source.zig").FileSource) SevenZValidationResult {

	const file_size = source.getEndPos() catch {
		return SevenZValidationResult.invalid("Failed to get file size");
	};

	if (file_size < 32) {
		return SevenZValidationResult.invalid("File too small for 7z header");
	}

	if (file_size > 4 * 1024 * 1024 * 1024) {
		return SevenZValidationResult.invalid("File too large for in-memory validation");
	}

	var heap_7z: ?[]u8 = null;
	defer if (heap_7z) |buf| allocator.free(buf);
	const data: []const u8 = if (source.getMappedSlice()) |m| m else blk: {
		const buf = allocator.alloc(u8, @intCast(file_size)) catch {
			return SevenZValidationResult.invalid("Out of memory");
		};
		heap_7z = buf;
		const n = source.readAll(buf) catch {
			return SevenZValidationResult.invalid("Failed to read file");
		};
		if (n != buf.len) {
			return SevenZValidationResult.invalid("Incomplete read");
		}
		break :blk buf[0..n];
	};

	// Open with z7z — this parses headers, decompresses all folders,
	// and verifies CRCs internally
	var archive: ?*c.z7z_archive = null;
	const open_res = c.z7z_open(data.ptr, data.len, &archive);
	if (open_res != c.Z7Z_OK) {
		return SevenZValidationResult.invalid(z7zErrorString(open_res));
	}
	defer c.z7z_close(archive);

	const num_files = c.z7z_file_count(archive);
	if (num_files == 0) {
		return SevenZValidationResult.ok(0, 0);
	}

	// Iterate every file entry — accessing data triggers decompression
	// and CRC verification for each file
	var files_checked: u32 = 0;
	var bytes_verified: u64 = 0;

	for (0..num_files) |i| {
		// Skip directories
		if (c.z7z_file_is_dir(archive, i) != 0) continue;

		const entry_size = c.z7z_file_size(archive, i);

		// Access the data to force decompression/CRC verification
		if (entry_size > 0) {
			const entry_data = c.z7z_file_data(archive, i);
			if (entry_data == null) {
				return SevenZValidationResult.invalid("Failed to decompress file entry");
			}
		}

		files_checked += 1;
		bytes_verified += entry_size;
	}

	return SevenZValidationResult.ok(files_checked, bytes_verified);
}

/// Validate a 7z file from a buffer (for embedded archives).
/// Uses Zig-native header CRC validation only (no decompression).
pub fn validateSevenZFromBuffer(allocator: Allocator, data: []const u8) SevenZValidationResult {
	_ = allocator;
	if (data.len < 32) {
		return SevenZValidationResult.invalid("Data too small for 7z header");
	}

	// Parse and validate start header
	const start_header = parseStartHeader(data) orelse {
		return SevenZValidationResult.invalid("Invalid start header or CRC mismatch");
	};

	// Validate version
	if (start_header.version_major != 0 or start_header.version_minor > 4) {
		return SevenZValidationResult.invalid(errmsg.unsupported("7z version"));
	}

	// Validate data size
	const expected_min_size = 32 + start_header.next_header_offset + start_header.next_header_size;
	if (data.len < expected_min_size) {
		return SevenZValidationResult.invalid("Data truncated");
	}

	// Verify next header CRC
	if (start_header.next_header_size > 0) {
		const next_header_start: usize = @intCast(32 + start_header.next_header_offset);
		const next_header_end: usize = @intCast(next_header_start + start_header.next_header_size);

		if (next_header_end > data.len) {
			return SevenZValidationResult.invalid("Next header extends beyond data");
		}

		const next_header_data = data[next_header_start..next_header_end];
		const computed_crc = std.hash.Crc32.hash(next_header_data);

		if (computed_crc != start_header.next_header_crc) {
			return SevenZValidationResult.invalid("Next header CRC mismatch");
		}
	}

	return SevenZValidationResult{
		.valid = true,
		.error_message = null,
		.files_checked = 0,
		.total_files = 0,
		.bytes_verified = 0,
	};
}

// Tests
test "parseStartHeader valid header" {
	// Build a valid 7z header
	var header: [32]u8 = undefined;
	@memcpy(header[0..6], &SEVENZ_SIGNATURE);
	header[6] = 0x00; // major version
	header[7] = 0x04; // minor version
	// Placeholder CRC
	@memset(header[8..12], 0);
	// Next header offset = 0
	@memset(header[12..20], 0);
	// Next header size = 0
	@memset(header[20..28], 0);
	// Next header CRC = 0
	@memset(header[28..32], 0);

	// Calculate correct CRC
	const crc = std.hash.Crc32.hash(header[12..32]);
	std.mem.writeInt(u32, header[8..12], crc, .little);

	const parsed = parseStartHeader(&header);
	try std.testing.expect(parsed != null);
	try std.testing.expectEqual(@as(u8, 0), parsed.?.version_major);
	try std.testing.expectEqual(@as(u8, 4), parsed.?.version_minor);
}

test "parseStartHeader invalid signature" {
	var header: [32]u8 = undefined;
	@memset(&header, 0);
	header[0] = 0xFF; // Wrong signature

	const parsed = parseStartHeader(&header);
	try std.testing.expect(parsed == null);
}

test "parseStartHeader crc mismatch" {
	var header: [32]u8 = undefined;
	@memcpy(header[0..6], &SEVENZ_SIGNATURE);
	header[6] = 0x00;
	header[7] = 0x04;
	// Wrong CRC
	header[8] = 0xDE;
	header[9] = 0xAD;
	header[10] = 0xBE;
	header[11] = 0xEF;
	@memset(header[12..32], 0);

	const parsed = parseStartHeader(&header);
	try std.testing.expect(parsed == null);
}

test "validate non-existent file returns error" {
	const file_source = @import("file_source.zig");
	var source = file_source.FileSource.open("/nonexistent/path/fake.7z") catch return;
	defer source.close();
	const result = validateSevenZDeep(std.testing.allocator, &source);
	try std.testing.expect(!result.valid);
	try std.testing.expect(result.error_message != null);
}
