//! GPT (GUID Partition Table) disk-image validator.
//!
//! Validates GPT-partitioned disk images per UEFI 2.x §5.3.2.
//!
//! Many `.iso`-extensioned files (Apple Mojave installers, modern hybrid
//! disks) are actually GPT-partitioned disk images, not ISO 9660 filesystems.
//! Detecting them lets us downgrade what would otherwise be a FAIL on these
//! files into an informative WARN with the real format.
//!
//! Validation steps:
//! 1. Protective MBR signature (0x55 0xAA at offset 510).
//! 2. "EFI PART" signature at offset = block_size (512 or 4096).
//! 3. Header CRC32 over header_size bytes (with header_crc32 field zeroed).
//! 4. Partition entries CRC32 over (num_entries × entry_size) bytes at
//!    partition_entry_lba × block_size.

const std = @import("std");
const fv = @import("format_validation.zig");
const FileFormat = fv.FileFormat;
const ValidationResult = fv.ValidationResult;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const gpt_parser = @import("gpt_parser.zig");
const Allocator = std.mem.Allocator;

/// GPT signature ("EFI PART" little-endian) — re-exported for convenience.
pub const GPT_SIGNATURE = gpt_parser.GPT_SIGNATURE;

/// Common LBA / block sizes seen on disk images.
pub const BLOCK_512: u32 = 512;
pub const BLOCK_4096: u32 = 4096;

/// Quick "is this a GPT disk image?" sniff. Looks for the protective MBR
/// 0x55 0xAA signature plus the "EFI PART" magic at offset 512 or 4096.
/// Returns the detected block size, or null if not GPT.
pub fn detectGptBlockSize(data: []const u8) ?u32 {
	// Protective MBR signature must be present at offset 510.
	if (data.len < 512 + 8) return null;
	if (data[510] != 0x55 or data[511] != 0xAA) return null;

	// Try 512-byte block first (most common).
	if (data.len >= 512 + 8) {
		const sig = std.mem.readInt(u64, data[512..520], .little);
		if (sig == GPT_SIGNATURE) return BLOCK_512;
	}
	// Try 4096-byte block (4Kn drives).
	if (data.len >= 4096 + 8) {
		const sig = std.mem.readInt(u64, data[4096..4104], .little);
		if (sig == GPT_SIGNATURE) return BLOCK_4096;
	}
	return null;
}

/// Same as detectGptBlockSize but only checks the magic, not the protective
/// MBR. Useful for the magic_signatures table dispatch where the protective
/// MBR check is redundant with the GPT magic at offset 512 in practice.
pub fn hasGptSignature(data: []const u8) ?u32 {
	if (data.len >= 512 + 8) {
		const sig = std.mem.readInt(u64, data[512..520], .little);
		if (sig == GPT_SIGNATURE) return BLOCK_512;
	}
	if (data.len >= 4096 + 8) {
		const sig = std.mem.readInt(u64, data[4096..4104], .little);
		if (sig == GPT_SIGNATURE) return BLOCK_4096;
	}
	return null;
}

pub const GptValidationLevel = enum {
	/// Header signature + protective MBR found, but couldn't verify CRCs.
	structural,
	/// Header CRC verified.
	header_crc_ok,
	/// Header CRC + partition entries CRC verified.
	full,
};

pub const GptValidationOutcome = struct {
	level: GptValidationLevel,
	block_size: u32,
	error_message: ?[]const u8 = null,
};

/// Validate a GPT-partitioned disk image from a buffer. Verifies the
/// protective MBR, primary header signature, header CRC32, and (if the
/// buffer is large enough to reach them) the partition entries CRC32.
///
/// The buffer must contain at least the first block + header (i.e. at
/// least 1024 bytes for 512-byte blocks). For full verification the
/// buffer should also contain the entry array referenced by
/// partition_entry_lba.
pub fn validateGptFromBuffer(data: []const u8) GptValidationOutcome {
	const block_size = detectGptBlockSize(data) orelse return .{
		.level = .structural,
		.block_size = 0,
		.error_message = "Not a GPT-partitioned disk image",
	};

	const header_off: usize = block_size;
	if (data.len < header_off + 92) {
		return .{
			.level = .structural,
			.block_size = block_size,
			.error_message = "Truncated GPT primary header",
		};
	}

	const header_data = data[header_off..];
	const header = gpt_parser.GptHeader.parse(header_data[0..@min(header_data.len, 512)]) catch {
		return .{
			.level = .structural,
			.block_size = block_size,
			.error_message = "Malformed GPT header",
		};
	};

	// Sanity-bound the header_size per UEFI: 92 ≤ header_size ≤ block_size.
	if (header.header_size < 92 or header.header_size > block_size) {
		return .{
			.level = .structural,
			.block_size = block_size,
			.error_message = "GPT header_size out of range",
		};
	}

	// Reserved field must be zero per UEFI 2.x.
	if (header.reserved != 0) {
		return .{
			.level = .structural,
			.block_size = block_size,
			.error_message = "GPT reserved field non-zero",
		};
	}

	// Verify header CRC over the declared header_size (header_crc32 field zeroed).
	if (!verifyHeaderCrc(header_data, header.header_size, header.header_crc32)) {
		return .{
			.level = .structural,
			.block_size = block_size,
			.error_message = "GPT header CRC32 mismatch",
		};
	}

	// Verify partition entry array CRC if the buffer reaches it.
	const entry_off: u64 = @as(u64, header.partition_entry_lba) * @as(u64, block_size);
	const entry_array_size: u64 = @as(u64, header.num_partition_entries) * @as(u64, header.size_of_partition_entry);
	const entry_end: u64 = entry_off + entry_array_size;

	if (entry_end <= data.len and entry_off >= header_off + 92) {
		const entries = data[@intCast(entry_off)..@intCast(entry_end)];
		const computed = std.hash.Crc32.hash(entries);
		if (computed != header.partition_entry_array_crc32) {
			return .{
				.level = .header_crc_ok,
				.block_size = block_size,
				.error_message = "GPT partition entry array CRC32 mismatch",
			};
		}
		return .{
			.level = .full,
			.block_size = block_size,
		};
	}

	// Couldn't reach the entry array (truncated buffer / past EOF).
	return .{
		.level = .header_crc_ok,
		.block_size = block_size,
	};
}

fn verifyHeaderCrc(header_data: []const u8, header_size: u32, expected_crc: u32) bool {
	if (header_data.len < header_size) return false;
	// Build a working copy with the CRC field (offset 16, 4 bytes) zeroed.
	// header_size capped at 512 (block_size 4096 still has header ≤ 512).
	var buf: [512]u8 = undefined;
	if (header_size > buf.len) return false;
	@memcpy(buf[0..header_size], header_data[0..header_size]);
	@memset(buf[16..20], 0);
	const computed = std.hash.Crc32.hash(buf[0..header_size]);
	return computed == expected_crc;
}

/// File-backed deep validation. Reads enough of the file to verify the
/// primary header and the partition entry array.
///
/// The maximum bytes we ever need for full validation is roughly
/// `block_size + 92 + 128 entries * 128 bytes = block_size + 16476` for
/// the typical 128-entry array, with a hard ceiling of `block_size + 1MB`.
pub fn validateGptDeepFromSource(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_size = source.getEndPos() catch {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .failed_to_get, "file size", .structural);
	};

	// Need at least one block + header. 4096 + 92 covers both 512 and 4096
	// block sizes.
	const min_size: u64 = 4096 + 92;
	if (file_size < 1024) {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .file_too_small, "GPT disk image", .structural);
	}

	// Read up to 1 MiB (covers 512-block + 128-entry × 128-byte array
	// plus headroom for unusual entry counts).
	const cap: usize = 1 * 1024 * 1024;
	const want: usize = @intCast(@min(file_size, @as(u64, cap)));
	const buf = allocator.alloc(u8, want) catch {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .out_of_memory, "GPT validation buffer", .structural);
	};
	defer allocator.free(buf);

	source.seekTo(0) catch {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .failed_to_seek, "to start", .structural);
	};
	const bytes_read = source.readAll(buf) catch {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .failed_to_read, "GPT image", .structural);
	};
	if (bytes_read < min_size and bytes_read < file_size) {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .incomplete, "read", .structural);
	}

	const outcome = validateGptFromBuffer(buf[0..bytes_read]);

	return switch (outcome.level) {
		.structural => ValidationResult.invalidWithDepth(
			.gpt_disk_image,
			outcome.error_message orelse "GPT validation failed",
			.structural,
		),
		// Header CRC verified, but entries CRC couldn't be reached or didn't match.
		.header_crc_ok => blk: {
			if (outcome.error_message) |msg| {
				// Entries CRC mismatch — header passed, surface as structural-only with warning.
				break :blk ValidationResult.okWithDepthAndWarning(.gpt_disk_image, .structural, msg);
			}
			// Couldn't reach entries (buffer cap or truncated trailing block).
			break :blk ValidationResult.okWithDepth(.gpt_disk_image, .structural);
		},
		.full => ValidationResult.okWithDepth(.gpt_disk_image, .full),
	};
}

/// Lightweight (structural) validation: confirms protective MBR + GPT
/// signature without verifying CRCs. Used by the non-deep dispatch path.
pub fn validateGptStructural(file: *FileSource) ValidationResult {
	file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .failed_to_seek, "to start", .structural);
	var probe: [4104]u8 = undefined;
	const n = file.readAll(&probe) catch return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .failed_to_read, "GPT probe", .structural);
	if (n < 520) return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .file_too_small, "GPT disk image", .structural);
	if (detectGptBlockSize(probe[0..n]) == null) {
		return ValidationResult.invalidCodeWithDepth(.gpt_disk_image, .invalid_signature, "GPT", .structural);
	}
	return ValidationResult.okWithDepth(.gpt_disk_image, .structural);
}
// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Build a minimal valid GPT image in `block_size`-byte LBAs:
///   LBA 0  — protective MBR (zeros + 0x55 0xAA at end)
///   LBA 1  — primary header
///   LBA 2+ — partition entry array (default 128 entries × 128 bytes)
fn buildSyntheticGpt(
	allocator: Allocator,
	block_size: u32,
	num_entries: u32,
	corrupt: enum { none, header_crc, entries_crc, signature, mbr_sig },
) ![]u8 {
	const entry_size: u32 = 128;
	const entry_array_bytes: u64 = @as(u64, num_entries) * @as(u64, entry_size);
	const entry_array_blocks: u64 = (entry_array_bytes + block_size - 1) / block_size;
	// Total: 2 blocks (MBR + header) + entry array blocks + 1 trailer block.
	const total_blocks: u64 = 2 + entry_array_blocks + 1;
	const total_bytes: usize = @intCast(total_blocks * block_size);

	const buf = try allocator.alloc(u8, total_bytes);
	@memset(buf, 0);

	// Protective MBR signature.
	if (corrupt != .mbr_sig) {
		buf[510] = 0x55;
		buf[511] = 0xAA;
	}

	const header_off: usize = block_size;

	// Signature.
	if (corrupt == .signature) {
		@memcpy(buf[header_off..][0..8], "BAD PART");
	} else {
		@memcpy(buf[header_off..][0..8], "EFI PART");
	}
	// Revision 1.0
	std.mem.writeInt(u32, buf[header_off + 8 ..][0..4], 0x00010000, .little);
	// HeaderSize
	std.mem.writeInt(u32, buf[header_off + 12 ..][0..4], 92, .little);
	// HeaderCRC32 — placeholder
	std.mem.writeInt(u32, buf[header_off + 16 ..][0..4], 0, .little);
	// Reserved
	std.mem.writeInt(u32, buf[header_off + 20 ..][0..4], 0, .little);
	// MyLBA = 1
	std.mem.writeInt(u64, buf[header_off + 24 ..][0..8], 1, .little);
	// AlternateLBA = total_blocks - 1
	std.mem.writeInt(u64, buf[header_off + 32 ..][0..8], total_blocks - 1, .little);
	// FirstUsableLBA = 2 + entry_array_blocks
	std.mem.writeInt(u64, buf[header_off + 40 ..][0..8], 2 + entry_array_blocks, .little);
	// LastUsableLBA = total_blocks - 2
	std.mem.writeInt(u64, buf[header_off + 48 ..][0..8], total_blocks - 2, .little);
	// DiskGUID — leave zero (synthetic).
	// PartitionEntryLBA = 2
	std.mem.writeInt(u64, buf[header_off + 72 ..][0..8], 2, .little);
	// NumberOfPartitionEntries
	std.mem.writeInt(u32, buf[header_off + 80 ..][0..4], num_entries, .little);
	// SizeOfPartitionEntry
	std.mem.writeInt(u32, buf[header_off + 84 ..][0..4], entry_size, .little);

	// Compute partition entry array CRC.
	const entry_off: usize = 2 * block_size;
	// Add one synthetic entry so the CRC check is non-trivial — fill the
	// first entry's GUID with a known pattern.
	@memset(buf[entry_off..][0..16], 0xAB);
	const entries = buf[entry_off..][0..@intCast(entry_array_bytes)];
	var entries_crc = std.hash.Crc32.hash(entries);
	if (corrupt == .entries_crc) entries_crc ^= 0xDEADBEEF;
	std.mem.writeInt(u32, buf[header_off + 88 ..][0..4], entries_crc, .little);

	// Compute header CRC over the 92-byte header with the CRC field zeroed.
	var hdr_buf: [92]u8 = undefined;
	@memcpy(&hdr_buf, buf[header_off..][0..92]);
	@memset(hdr_buf[16..20], 0);
	var hdr_crc = std.hash.Crc32.hash(&hdr_buf);
	if (corrupt == .header_crc) hdr_crc ^= 0xCAFEBABE;
	std.mem.writeInt(u32, buf[header_off + 16 ..][0..4], hdr_crc, .little);

	return buf;
}

test "GPT detect: 512-byte block valid signature" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .none);
	defer testing.allocator.free(buf);
	try testing.expectEqual(@as(?u32, BLOCK_512), detectGptBlockSize(buf));
}

test "GPT detect: 4096-byte block valid signature" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_4096, 128, .none);
	defer testing.allocator.free(buf);
	try testing.expectEqual(@as(?u32, BLOCK_4096), detectGptBlockSize(buf));
}

test "GPT detect: missing protective MBR fails" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .mbr_sig);
	defer testing.allocator.free(buf);
	try testing.expectEqual(@as(?u32, null), detectGptBlockSize(buf));
}

test "GPT detect: wrong signature fails" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .signature);
	defer testing.allocator.free(buf);
	try testing.expectEqual(@as(?u32, null), detectGptBlockSize(buf));
}

test "GPT validate: full success on synthetic image" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .none);
	defer testing.allocator.free(buf);
	const outcome = validateGptFromBuffer(buf);
	try testing.expectEqual(GptValidationLevel.full, outcome.level);
	try testing.expectEqual(@as(u32, BLOCK_512), outcome.block_size);
}

test "GPT validate: bad header CRC -> structural fail" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .header_crc);
	defer testing.allocator.free(buf);
	const outcome = validateGptFromBuffer(buf);
	try testing.expectEqual(GptValidationLevel.structural, outcome.level);
	try testing.expect(outcome.error_message != null);
}

test "GPT validate: bad entries CRC -> header_crc_ok with msg" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_512, 128, .entries_crc);
	defer testing.allocator.free(buf);
	const outcome = validateGptFromBuffer(buf);
	try testing.expectEqual(GptValidationLevel.header_crc_ok, outcome.level);
	try testing.expect(outcome.error_message != null);
}

test "GPT validate: 4096 block size full success" {
	const buf = try buildSyntheticGpt(testing.allocator, BLOCK_4096, 128, .none);
	defer testing.allocator.free(buf);
	const outcome = validateGptFromBuffer(buf);
	try testing.expectEqual(GptValidationLevel.full, outcome.level);
	try testing.expectEqual(@as(u32, BLOCK_4096), outcome.block_size);
}
