//! Deep 7-Zip validation module.
//!
//! Validates 7z archives with z7z's Zig-native verifier.
//! No external executable dependency.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errmsg = @import("error_messages.zig");
const z7z = @import("z7z");

/// Result of 7z deep validation.
///
/// Four-way outcome discipline: `valid=false` alone means corruption evidence.
/// The two flags below mark the non-corrupt failure classes so callers can
/// keep capability gaps and resource caps out of the "invalid" tier.
pub const SevenZValidationResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	files_checked: u32,
	total_files: u32,
	bytes_verified: u64,
	/// Archive uses a syntactically valid feature outside the promoted
	/// verifier surface (capability gap, not corruption evidence).
	unsupported: bool = false,
	/// Verification stopped at a self-imposed resource cap (size or
	/// expansion-ratio limit), not because damage was found.
	resource_limited: bool = false,

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

	pub fn unsupportedFeature(message: []const u8) SevenZValidationResult {
		var result = invalid(message);
		result.unsupported = true;
		return result;
	}

	pub fn resourceLimited(message: []const u8) SevenZValidationResult {
		var result = invalid(message);
		result.resource_limited = true;
		return result;
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

const MAX_TOTAL_UNPACK_SIZE: u64 = 64 * 1024 * 1024 * 1024;
const MAX_EXPANSION_RATIO: u64 = 256;

fn z7zErrorString(err: z7z.archive.ArchiveError) []const u8 {
	return switch (err) {
		error.NotArchive => "Not a 7-Zip archive",
		error.ChecksumError => "7-Zip checksum mismatch",
		error.TruncatedInput => "7-Zip archive truncated",
		error.StructuralError => "7-Zip archive structure invalid",
		error.UnsupportedFeature => errmsg.unsupported("7z feature"),
		error.EndOfStream => "7-Zip archive ended unexpectedly",
		error.OutOfMemory => "Out of memory validating 7-Zip archive",
		error.PasswordRequired => "7-Zip archive requires a password",
		error.ResourceLimitExceeded => "7-Zip archive exceeds validation resource limits",
	};
}

/// Deep validate a 7z file using z7z (cleanroom LZMA2 decoder).
/// Streams decoded bytes into z7z's verification sink, checks payload CRCs,
/// and never materializes extracted file or folder payloads.
pub fn validateSevenZDeep(allocator: Allocator, source: *@import("file_source.zig").FileSource) SevenZValidationResult {

	const file_size = source.getEndPos() catch {
		return SevenZValidationResult.invalid("Failed to get file size");
	};

	if (file_size < 32) {
		return SevenZValidationResult.invalid("File too small for 7z header");
	}

	const slurp_7z = source.getMappedOrSlurp(allocator, 256 << 20) catch
		return SevenZValidationResult.invalid("Failed to read file");
	var heap_7z: ?[]u8 = null;
	defer if (heap_7z) |b| allocator.free(b);
	const data: []const u8 = switch (slurp_7z) {
		.mapped => |m| m,
		.heap => |b| blk: { heap_7z = b; break :blk b; },
		.too_large => return SevenZValidationResult.resourceLimited("7-Zip too large for non-mmap deep validation"),
	};

	const stats = z7z.archive.verify(data, .{
		.max_total_unpack_size = MAX_TOTAL_UNPACK_SIZE,
		.max_expansion_ratio = MAX_EXPANSION_RATIO,
	}, allocator) catch |err| {
		return switch (err) {
			error.UnsupportedFeature => SevenZValidationResult.unsupportedFeature(z7zErrorString(err)),
			error.ResourceLimitExceeded => SevenZValidationResult.resourceLimited(z7zErrorString(err)),
			else => SevenZValidationResult.invalid(z7zErrorString(err)),
		};
	};

	const data_file_count: u32 = @intCast(@min(stats.data_file_count, std.math.maxInt(u32)));
	const file_count: u32 = @intCast(@min(stats.file_count, std.math.maxInt(u32)));
	return SevenZValidationResult.okPartial(data_file_count, file_count, stats.total_unpack_size);
}

/// Validate a 7z file from a buffer (for embedded archives).
/// Uses the same z7z streaming verifier as file-backed deep validation.
pub fn validateSevenZFromBuffer(allocator: Allocator, data: []const u8) SevenZValidationResult {
	if (data.len < 32) {
		return SevenZValidationResult.invalid("Data too small for 7z header");
	}

	const stats = z7z.archive.verify(data, .{
		.max_total_unpack_size = MAX_TOTAL_UNPACK_SIZE,
		.max_expansion_ratio = MAX_EXPANSION_RATIO,
	}, allocator) catch |err| {
		return switch (err) {
			error.UnsupportedFeature => SevenZValidationResult.unsupportedFeature(z7zErrorString(err)),
			error.ResourceLimitExceeded => SevenZValidationResult.resourceLimited(z7zErrorString(err)),
			else => SevenZValidationResult.invalid(z7zErrorString(err)),
		};
	};

	const data_file_count: u32 = @intCast(@min(stats.data_file_count, std.math.maxInt(u32)));
	const file_count: u32 = @intCast(@min(stats.file_count, std.math.maxInt(u32)));
	return SevenZValidationResult.okPartial(data_file_count, file_count, stats.total_unpack_size);
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
