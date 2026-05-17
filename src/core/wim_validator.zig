//! WIM/ESD (Windows Imaging Format) Validator
//!
//! Validates Windows Imaging Format (.wim) and Electronic Software Delivery (.esd) files.
//! ESD is a variant of WIM using LZMS compression, used by Windows Update delivery.
//!
//! Format reference: Microsoft WIM File Format Specification (MS-WIM)
//! Header is 208 bytes, all multi-byte integers are little-endian.

const std = @import("std");
const runtime = @import("runtime.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const ValidationDepth = format_validation.ValidationDepth;
const FileFormat = format_validation.FileFormat;
const Allocator = std.mem.Allocator;

// WIM magic: "MSWIM\x00\x00\x00"
const WIM_MAGIC = [8]u8{ 0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00 };

const WIM_HEADER_SIZE: u32 = 208; // 0xD0
const WIM_VERSION_STANDARD: u32 = 0x00010D00;
const WIM_VERSION_ESD: u32 = 0x0000_0E00;

// WIM flags (offset 0x10)
const FLAG_COMPRESSION: u32 = 0x00000002;
const FLAG_WRITE_IN_PROGRESS: u32 = 0x00000040;
const FLAG_XPRESS: u32 = 0x00020000;
const FLAG_LZX: u32 = 0x00040000;
const FLAG_LZMS: u32 = 0x00080000;

/// All compression-type flags. At most one may be set.
const COMPRESSION_FLAGS: u32 = FLAG_XPRESS | FLAG_LZX | FLAG_LZMS;

// Resource header (reshdr) layout within the 208-byte WIM header
// Each reshdr is 24 bytes:
//   bytes 0-6: size_in_wim (7 bytes, 56-bit LE)
//   byte 7:    reshdr_flags
//   bytes 8-15: offset_in_wim (u64 LE)
//   bytes 16-23: uncompressed_size (u64 LE)

/// Parsed resource header.
const ResHdr = struct {
	size_in_wim: u64,
	flags: u8,
	offset_in_wim: u64,
	uncompressed_size: u64,
};

/// Decode a 24-byte resource header slice.
fn decodeResHdr(buf: *const [24]u8) ResHdr {
	// size_in_wim: 7 bytes LE at buf[0..7]
	var size: u64 = 0;
	for (0..7) |i| {
		size |= @as(u64, buf[i]) << @intCast(i * 8);
	}
	const flags = buf[7];
	const offset = std.mem.readInt(u64, buf[8..16], .little);
	const uncompressed = std.mem.readInt(u64, buf[16..24], .little);
	return .{
		.size_in_wim = size,
		.flags = flags,
		.offset_in_wim = offset,
		.uncompressed_size = uncompressed,
	};
}

/// Validate WIM/ESD (Windows Imaging Format) structural integrity.
/// Checks magic, header size, version, flags, part numbers, resource header bounds,
/// and the all-zeros reserved region. Returns .wim or .esd based on version/flags.
pub fn validateWim(file: *FileSource) ValidationResult {
	const file_size = file.file_size;

	if (file_size < WIM_HEADER_SIZE) {
		return ValidationResult.invalidCode(.wim, .file_too_small, "WIM header");
	}

	file.seekTo(0) catch return ValidationResult.invalidCode(.wim, .failed_to_seek, "to start");

	var hdr: [WIM_HEADER_SIZE]u8 = undefined;
	const nread = file.readAll(&hdr) catch return ValidationResult.invalidCode(.wim, .failed_to_read, "WIM header");
	if (nread < @as(usize, WIM_HEADER_SIZE)) {
		return ValidationResult.invalidCode(.wim, .truncated, "WIM header");
	}

	// 1. Magic bytes
	if (!std.mem.eql(u8, hdr[0..8], &WIM_MAGIC)) {
		return ValidationResult.invalidCode(.wim, .invalid_signature, "WIM");
	}

	// 2. Header size must be 208
	const hdr_size = std.mem.readInt(u32, hdr[0x08..0x0C], .little);
	if (hdr_size != WIM_HEADER_SIZE) {
		return ValidationResult.invalidCode(.wim, .invalid_value, "WIM header size");
	}

	// 3. Version
	const wim_version = std.mem.readInt(u32, hdr[0x0C..0x10], .little);
	const is_esd = (wim_version == WIM_VERSION_ESD);
	if (wim_version != WIM_VERSION_STANDARD and wim_version != WIM_VERSION_ESD) {
		return ValidationResult.invalidCode(.wim, .invalid_value, "WIM version");
	}

	// Determine format (.esd if ESD version + LZMS flag)
	const wim_flags = std.mem.readInt(u32, hdr[0x10..0x14], .little);
	const lzms_set = (wim_flags & FLAG_LZMS) != 0;
	const detected_format: FileFormat = if (is_esd and lzms_set) .esd else .wim;

	// 4. WRITE_IN_PROGRESS is a corruption indicator
	if ((wim_flags & FLAG_WRITE_IN_PROGRESS) != 0) {
		return ValidationResult.invalid(detected_format, "WIM file write was interrupted (WRITE_IN_PROGRESS flag set)");
	}

	// 5. At most one compression type when COMPRESSION is set
	if ((wim_flags & FLAG_COMPRESSION) != 0) {
		const comp_bits = wim_flags & COMPRESSION_FLAGS;
		// popcount: more than one bit set is invalid
		if (comp_bits != 0 and (comp_bits & (comp_bits - 1)) != 0) {
			return ValidationResult.invalidCode(.wim, .invalid_value, "WIM compression flags (multiple types set)");
		}
	}

	// 6. Part numbers
	const part_number = std.mem.readInt(u16, hdr[0x28..0x2A], .little);
	const total_parts = std.mem.readInt(u16, hdr[0x2A..0x2C], .little);
	if (part_number < 1) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM part_number (must be >= 1)");
	}
	if (total_parts < part_number) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM total_parts (must be >= part_number)");
	}

	// 7. image_count and boot_idx
	const image_count = std.mem.readInt(u32, hdr[0x2C..0x30], .little);
	const boot_idx = std.mem.readInt(u32, hdr[0x78..0x7C], .little);
	if (boot_idx != 0 and boot_idx > image_count) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM boot_idx exceeds image_count");
	}

	// 8. Reserved bytes at offset 0x94 (60 bytes) must all be zeros (WIM only; ESD uses this region)
	if (!is_esd) {
		const reserved = hdr[0x94..0xD0];
		for (reserved) |b| {
			if (b != 0) {
				return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM reserved region (non-zero bytes)");
			}
		}
	}

	// 9. Resource header bounds checking
	// blob_table_reshdr at 0x30, xml_data_reshdr at 0x48, boot_metadata_reshdr at 0x60, integrity_table_reshdr at 0x7C
	const reshdr_offsets = [_]usize{ 0x30, 0x48, 0x60, 0x7C };
	for (reshdr_offsets) |roff| {
		const rbuf: *const [24]u8 = hdr[roff..][0..24];
		const rh = decodeResHdr(rbuf);
		// A reshdr with offset=0 and size=0 is a null/absent resource — that's fine.
		if (rh.offset_in_wim == 0 and rh.size_in_wim == 0) continue;
		// If present, it must lie within the file.
		if (rh.offset_in_wim >= file_size) {
			return ValidationResult.invalidCode(detected_format, .exceeds_bounds, "WIM resource header offset");
		}
		// Avoid overflow when checking offset + size
		const end_pos = rh.offset_in_wim +| rh.size_in_wim;
		if (end_pos > file_size) {
			return ValidationResult.invalidCode(detected_format, .exceeds_bounds, "WIM resource header data");
		}
	}

	return ValidationResult.okWithDepth(detected_format, .structural);
}

/// Deep validate WIM/ESD: verifies the integrity table structure if present.
/// If the integrity_table_reshdr is non-null, reads its header (12 bytes) and
/// checks that the declared entry count matches the data size.
pub fn validateWimDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	_ = allocator;
	const file = source;

	// Run structural validation first
	const basic = validateWim(file);
	if (!basic.is_valid) return basic;

	const detected_format = basic.format;
	const file_size = file.file_size;

	// Re-read header to get integrity_table_reshdr (at offset 0x7C)
	file.seekTo(0) catch return ValidationResult.invalidCode(detected_format, .failed_to_seek, "to start");
	var hdr: [WIM_HEADER_SIZE]u8 = undefined;
	const nread = file.readAll(&hdr) catch return basic;
	if (nread < @as(usize, WIM_HEADER_SIZE)) return basic;

	const ibuf: *const [24]u8 = hdr[0x7C..][0..24];
	const irh = decodeResHdr(ibuf);

	// No integrity table — structural validation is the best we can do.
	if (irh.offset_in_wim == 0 and irh.size_in_wim == 0) {
		return ValidationResult.okWithDepth(detected_format, .structural);
	}

	// Integrity table header: u32 size, u32 num_entries, u32 chunk_size = 12 bytes
	if (irh.size_in_wim < 12) {
		return ValidationResult.invalidCode(detected_format, .truncated, "WIM integrity table header");
	}
	if (irh.offset_in_wim + 12 > file_size) {
		return ValidationResult.invalidCode(detected_format, .exceeds_bounds, "WIM integrity table header");
	}

	file.seekTo(irh.offset_in_wim) catch return ValidationResult.invalidCode(detected_format, .failed_to_seek, "to integrity table");
	var itable_hdr: [12]u8 = undefined;
	const ihread = file.readAll(&itable_hdr) catch return ValidationResult.invalidCode(detected_format, .failed_to_read, "integrity table header");
	if (ihread < 12) {
		return ValidationResult.invalidCode(detected_format, .truncated, "WIM integrity table header");
	}

	const itbl_size = std.mem.readInt(u32, itable_hdr[0..4], .little);
	const num_entries = std.mem.readInt(u32, itable_hdr[4..8], .little);
	// chunk_size is at itable_hdr[8..12] — we don't need to use it here

	// The total table size must be 12 + num_entries * 20 (SHA-1 = 20 bytes each)
	const expected_size: u64 = 12 + @as(u64, num_entries) * 20;
	if (@as(u64, itbl_size) != expected_size) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM integrity table size/entry count mismatch");
	}
	// The on-disk resource must accommodate at least the declared size
	if (irh.size_in_wim < expected_size) {
		return ValidationResult.invalidCode(detected_format, .truncated, "WIM integrity table entries");
	}

	return ValidationResult.okWithDepth(detected_format, .structural);
}

/// Validate WIM/ESD from an in-memory buffer (buffer-based API).
pub fn validateWimFromBuffer(data: []const u8) ValidationResult {
	if (data.len < WIM_HEADER_SIZE) {
		return ValidationResult.invalidCode(.wim, .file_too_small, "WIM header");
	}

	// 1. Magic
	if (!std.mem.eql(u8, data[0..8], &WIM_MAGIC)) {
		return ValidationResult.invalidCode(.wim, .invalid_signature, "WIM");
	}

	// 2. Header size
	const hdr_size = std.mem.readInt(u32, data[0x08..][0..4], .little);
	if (hdr_size != WIM_HEADER_SIZE) {
		return ValidationResult.invalidCode(.wim, .invalid_value, "WIM header size");
	}

	// 3. Version
	const wim_version = std.mem.readInt(u32, data[0x0C..][0..4], .little);
	const is_esd = (wim_version == WIM_VERSION_ESD);
	if (wim_version != WIM_VERSION_STANDARD and wim_version != WIM_VERSION_ESD) {
		return ValidationResult.invalidCode(.wim, .invalid_value, "WIM version");
	}

	const wim_flags = std.mem.readInt(u32, data[0x10..][0..4], .little);
	const lzms_set = (wim_flags & FLAG_LZMS) != 0;
	const detected_format: FileFormat = if (is_esd and lzms_set) .esd else .wim;

	// 4. WRITE_IN_PROGRESS
	if ((wim_flags & FLAG_WRITE_IN_PROGRESS) != 0) {
		return ValidationResult.invalid(detected_format, "WIM file write was interrupted (WRITE_IN_PROGRESS flag set)");
	}

	// 5. At most one compression type
	if ((wim_flags & FLAG_COMPRESSION) != 0) {
		const comp_bits = wim_flags & COMPRESSION_FLAGS;
		if (comp_bits != 0 and (comp_bits & (comp_bits - 1)) != 0) {
			return ValidationResult.invalidCode(.wim, .invalid_value, "WIM compression flags (multiple types set)");
		}
	}

	// 6. Part numbers
	const part_number = std.mem.readInt(u16, data[0x28..][0..2], .little);
	const total_parts = std.mem.readInt(u16, data[0x2A..][0..2], .little);
	if (part_number < 1) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM part_number (must be >= 1)");
	}
	if (total_parts < part_number) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM total_parts (must be >= part_number)");
	}

	// 7. boot_idx
	const image_count = std.mem.readInt(u32, data[0x2C..][0..4], .little);
	const boot_idx = std.mem.readInt(u32, data[0x78..][0..4], .little);
	if (boot_idx != 0 and boot_idx > image_count) {
		return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM boot_idx exceeds image_count");
	}

	// 8. Reserved bytes at 0x94 (60 bytes) must all be zeros (WIM only; ESD uses this region)
	if (!is_esd) {
		const reserved = data[0x94..0xD0];
		for (reserved) |b| {
			if (b != 0) {
				return ValidationResult.invalidCode(detected_format, .invalid_value, "WIM reserved region (non-zero bytes)");
			}
		}
	}

	return ValidationResult.okWithDepth(detected_format, .structural);
}

// ============ Tests ============

const testing = std.testing;

test "validateWim: valid WIM ground truth" {
	var file = FileSource.open("ground_truth_examples/wim/sample.wim") catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer file.close();
	const result = validateWim(&file);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.wim, result.format);
}

test "validateWimDeep: valid WIM ground truth deep" {
	var file = FileSource.open("ground_truth_examples/wim/sample.wim") catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer file.close();
	const result = validateWimDeep(testing.allocator, &file);
	try testing.expect(result.is_valid);
}

test "validateWimFromBuffer: valid minimal WIM buffer" {
	// Build a minimal valid WIM header (208 bytes)
	var buf = [_]u8{0} ** 208;
	// Magic
	@memcpy(buf[0..8], &WIM_MAGIC);
	// hdr_size = 208 (0xD0) LE
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	// version = WIM standard
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	// flags = COMPRESSION | LZX
	std.mem.writeInt(u32, buf[0x10..0x14], FLAG_COMPRESSION | FLAG_LZX, .little);
	// part_number = 1, total_parts = 1
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);
	// image_count = 1, boot_idx = 0
	std.mem.writeInt(u32, buf[0x2C..0x30], 1, .little);
	std.mem.writeInt(u32, buf[0x78..0x7C], 0, .little);
	// All resource headers are zero (null/absent) — already zero from init
	// Reserved region is already zero

	const result = validateWimFromBuffer(&buf);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.wim, result.format);
}

test "validateWimFromBuffer: detects ESD format" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	// ESD version
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_ESD, .little);
	// flags = COMPRESSION | LZMS
	std.mem.writeInt(u32, buf[0x10..0x14], FLAG_COMPRESSION | FLAG_LZMS, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.esd, result.format);
}

test "validateWimFromBuffer: rejects invalid magic" {
	var buf = [_]u8{0} ** 208;
	buf[0] = 'X'; // Corrupt first magic byte
	@memcpy(buf[1..8], WIM_MAGIC[1..]);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects wrong header size" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], 100, .little); // Wrong size
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects WRITE_IN_PROGRESS flag" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	// Set WRITE_IN_PROGRESS
	std.mem.writeInt(u32, buf[0x10..0x14], FLAG_WRITE_IN_PROGRESS, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects multiple compression types" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	// COMPRESSION + both XPRESS and LZX — invalid
	std.mem.writeInt(u32, buf[0x10..0x14], FLAG_COMPRESSION | FLAG_XPRESS | FLAG_LZX, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects part_number=0" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 0, .little); // part_number = 0 (invalid)
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects part_number > total_parts" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 3, .little); // part_number = 3
	std.mem.writeInt(u16, buf[0x2A..0x2C], 2, .little); // total_parts = 2 (invalid)

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects boot_idx > image_count" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);
	std.mem.writeInt(u32, buf[0x2C..0x30], 1, .little); // image_count = 1
	std.mem.writeInt(u32, buf[0x78..0x7C], 5, .little); // boot_idx = 5 > image_count

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: ESD allows non-zero reserved bytes" {
    // ESD files legitimately use the reserved region at 0x94-0xD0.
    // This must NOT be rejected as invalid.
    var buf = [_]u8{0} ** 208;
    @memcpy(buf[0..8], &WIM_MAGIC);
    std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
    // ESD version
    std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_ESD, .little);
    // flags = COMPRESSION | LZMS (required for ESD detection)
    std.mem.writeInt(u32, buf[0x10..0x14], FLAG_COMPRESSION | FLAG_LZMS, .little);
    std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
    std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);
    // Set non-zero bytes in the reserved region
    buf[0x94] = 0xFF;
    buf[0xA0] = 0x42;
    buf[0xCF] = 0x01;

    const result = validateWimFromBuffer(&buf);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.esd, result.format);
}

test "validateWimFromBuffer: rejects non-zero reserved bytes" {
	var buf = [_]u8{0} ** 208;
	@memcpy(buf[0..8], &WIM_MAGIC);
	std.mem.writeInt(u32, buf[0x08..0x0C], WIM_HEADER_SIZE, .little);
	std.mem.writeInt(u32, buf[0x0C..0x10], WIM_VERSION_STANDARD, .little);
	std.mem.writeInt(u16, buf[0x28..0x2A], 1, .little);
	std.mem.writeInt(u16, buf[0x2A..0x2C], 1, .little);
	buf[0x94] = 0xFF; // Non-zero reserved byte

	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}

test "validateWimFromBuffer: rejects too-small buffer" {
	const buf = [_]u8{0} ** 100; // Too small for WIM header
	const result = validateWimFromBuffer(&buf);
	try testing.expect(!result.is_valid);
}
