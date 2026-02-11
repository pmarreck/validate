//! TrueType/OpenType font validator.
//!
//! Validates TTF and OTF fonts by:
//! - Verifying sfnt version (0x00010000 for TrueType, "OTTO" for CFF)
//! - Parsing table directory
//! - Verifying checksum for each table
//! - Verifying whole-file checkSumAdjustment in head table
//!
//! Reference: Apple TrueType Reference Manual, OpenType spec

const std = @import("std");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;

pub const FontValidationError = error{
	InvalidSignature,
	InvalidTableDirectory,
	ChecksumMismatch,
	HeadTableMissing,
	HeadTableInvalid,
	FileTooSmall,
	TableOutOfBounds,
	OutOfMemory,
};

pub const FontType = enum {
	truetype, // sfnt version 0x00010000
	opentype_cff, // sfnt version "OTTO"
	woff, // WOFF container
	woff2, // WOFF2 container
};

pub const FontValidationResult = struct {
	valid: bool,
	font_type: ?FontType,
	num_tables: u16,
	tables_verified: u16,
	error_message: ?[]const u8,
	warning_message: ?[]const u8,

	pub fn ok(font_type: FontType, num_tables: u16, tables_verified: u16) FontValidationResult {
		return .{
			.valid = true,
			.font_type = font_type,
			.num_tables = num_tables,
			.tables_verified = tables_verified,
			.error_message = null,
			.warning_message = null,
		};
	}

	pub fn okWithWarning(font_type: FontType, num_tables: u16, tables_verified: u16, warning: []const u8) FontValidationResult {
		return .{
			.valid = true,
			.font_type = font_type,
			.num_tables = num_tables,
			.tables_verified = tables_verified,
			.error_message = null,
			.warning_message = warning,
		};
	}

	pub fn invalid(msg: []const u8) FontValidationResult {
		return .{
			.valid = false,
			.font_type = null,
			.num_tables = 0,
			.tables_verified = 0,
			.error_message = msg,
			.warning_message = null,
		};
	}
};

/// Table directory entry.
const TableRecord = struct {
	tag: [4]u8,
	checksum: u32,
	offset: u32,
	length: u32,
};

/// Calculate checksum of a block of data.
/// Font checksums treat data as big-endian u32 values.
fn calcChecksum(data: []const u8) u32 {
	var sum: u32 = 0;
	var i: usize = 0;

	// Process complete u32s
	while (i + 4 <= data.len) : (i += 4) {
		const val = std.mem.readInt(u32, data[i..][0..4], .big);
		sum +%= val;
	}

	// Handle remainder (pad with zeros)
	if (i < data.len) {
		var last: [4]u8 = .{ 0, 0, 0, 0 };
		const remaining = data.len - i;
		@memcpy(last[0..remaining], data[i..]);
		const val = std.mem.readInt(u32, &last, .big);
		sum +%= val;
	}

	return sum;
}

/// Validation options for fonts.
pub const ValidationOptions = struct {
	/// Skip table checksum verification.
	/// Useful for PDF-embedded fonts where subsetters often break checksums.
	skip_checksums: bool = false,
	/// When a checksum mismatch is detected, attempt a structural parse fallback
	/// to provide a more specific reason.
	checksum_fallback: bool = true,
};

const CHECKSUM_FALLBACK_OK = "Table checksum mismatch; parsing fallback: no structural errors";
const CHECKSUM_FALLBACK_INVALID_SIGNATURE = "Table checksum mismatch; parsing fallback: Invalid sfnt version";
const CHECKSUM_FALLBACK_NO_TABLES = "Table checksum mismatch; parsing fallback: No tables in font";
const CHECKSUM_FALLBACK_DIR_TOO_SMALL = "Table checksum mismatch; parsing fallback: File too small for table directory";
const CHECKSUM_FALLBACK_TABLE_OOB = "Table checksum mismatch; parsing fallback: Table extends beyond file";
const CHECKSUM_FALLBACK_HEAD_MISSING = "Table checksum mismatch; parsing fallback: Missing head table";
const CHECKSUM_FALLBACK_HEAD_TOO_SMALL = "Table checksum mismatch; parsing fallback: head table too small";
const CHECKSUM_FALLBACK_OTHER = "Table checksum mismatch; parsing fallback revealed structural errors";

fn checksumMismatchMessage(fallback_error: ?[]const u8) []const u8 {
	if (fallback_error == null) return CHECKSUM_FALLBACK_OK;
	const msg = fallback_error.?;
	if (std.mem.eql(u8, msg, "Invalid sfnt version")) return CHECKSUM_FALLBACK_INVALID_SIGNATURE;
	if (std.mem.eql(u8, msg, "No tables in font")) return CHECKSUM_FALLBACK_NO_TABLES;
	if (std.mem.eql(u8, msg, "File too small for table directory")) return CHECKSUM_FALLBACK_DIR_TOO_SMALL;
	if (std.mem.eql(u8, msg, "Table extends beyond file")) return CHECKSUM_FALLBACK_TABLE_OOB;
	if (std.mem.eql(u8, msg, "Missing head table")) return CHECKSUM_FALLBACK_HEAD_MISSING;
	if (std.mem.eql(u8, msg, "head table too small")) return CHECKSUM_FALLBACK_HEAD_TOO_SMALL;
	return CHECKSUM_FALLBACK_OTHER;
}

/// Validate a TrueType or OpenType font from memory.
/// Uses strict validation by default.
pub fn validateTtfOtf(data: []const u8) FontValidationResult {
	return validateTtfOtfWithOptions(data, .{});
}

/// Validate a TrueType or OpenType font with options.
/// Use skip_checksums=true for PDF-embedded fonts where
/// checksum mismatches are common due to subsetting.
pub fn validateTtfOtfWithOptions(data: []const u8, options: ValidationOptions) FontValidationResult {
	// Minimum size: sfnt header (12 bytes) + at least 1 table record (16 bytes)
	if (data.len < 28) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("TTF/OTF"));
	}

	// Parse sfnt version
	const sfnt_version = data[0..4];
	const font_type: FontType = blk: {
		if (std.mem.eql(u8, sfnt_version, &[_]u8{ 0x00, 0x01, 0x00, 0x00 })) {
			break :blk .truetype;
		} else if (std.mem.eql(u8, sfnt_version, "OTTO")) {
			break :blk .opentype_cff;
		} else {
			return FontValidationResult.invalid("Invalid sfnt version");
		}
	};

	// Parse table count
	const num_tables = std.mem.readInt(u16, data[4..6], .big);
	if (num_tables == 0) {
		return FontValidationResult.invalid("No tables in font");
	}

	// Calculate required size for table directory
	const table_dir_end = 12 + @as(usize, num_tables) * 16;
	if (data.len < table_dir_end) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("table directory"));
	}

	// Parse table directory and verify checksums
	var tables_verified: u16 = 0;
	var head_offset: ?u32 = null;
	var head_length: ?u32 = null;
	var head_checksum: ?u32 = null;

	for (0..num_tables) |i| {
		const record_start = 12 + i * 16;
		const record = parseTableRecord(data[record_start..][0..16]);

		// Check if table is within file bounds
		const table_end = @as(u64, record.offset) + @as(u64, record.length);
		if (table_end > data.len) {
			return FontValidationResult.invalid("Table extends beyond file");
		}

		// Remember head table location and its stored checksum
		if (std.mem.eql(u8, &record.tag, "head")) {
			head_offset = record.offset;
			head_length = record.length;
			head_checksum = record.checksum;
		}

		// Verify table checksum (skip head table - it has special handling below)
		if (!options.skip_checksums and !std.mem.eql(u8, &record.tag, "head")) {
			const table_data = data[record.offset..][0..record.length];
			const calc_sum = calcChecksum(table_data);

			if (calc_sum != record.checksum) {
				if (options.checksum_fallback) {
					// Checksum failed - do structural parsing to determine if data is actually corrupt
					const fallback = validateTtfOtfWithOptions(data, .{
						.skip_checksums = true,
						.checksum_fallback = false,
					});
					if (fallback.valid) {
						// Structural parsing succeeded despite checksum mismatch
						// This indicates a build-time checksum error, not data corruption
						// Return valid with warning (data is usable but checksums are wrong)
						return FontValidationResult.okWithWarning(
							fallback.font_type.?,
							fallback.num_tables,
							fallback.tables_verified,
							CHECKSUM_FALLBACK_OK,
						);
					} else {
						// Both checksum AND structural parsing failed - actual corruption
						const combined = checksumMismatchMessage(fallback.error_message);
						return FontValidationResult.invalid(combined);
					}
				}
				return FontValidationResult.invalid("Table checksum mismatch");
			}
		}

		tables_verified += 1;
	}

	// Verify head table exists
	if (head_offset == null) {
		return FontValidationResult.invalid(errmsg.missing("head table"));
	}

	// Verify head table (special checksum handling)
	const h_off = head_offset.?;
	const h_len = head_length.?;

	if (h_len < 54) {
		return FontValidationResult.invalid("head table too small");
	}

	// head table checksum: computed with checkSumAdjustment set to 0
	// The checkSumAdjustment is at offset 8 in the head table
	const head_data = data[h_off..][0..h_len];

	// Verify head table checksum (special handling: checkSumAdjustment treated as 0)
	// Calculate: actual_checksum - checkSumAdjustment_value = expected_checksum
	// This is equivalent to computing checksum with bytes 8-11 zeroed
	if (!options.skip_checksums) {
		const stored_adjustment = std.mem.readInt(u32, head_data[8..12], .big);
		const actual_head_sum = calcChecksum(head_data);
		const expected_head_checksum = actual_head_sum -% stored_adjustment;

		if (expected_head_checksum != head_checksum.?) {
			// Head table checksum mismatch - but structure is valid at this point
			// Return warning since we've already verified the structure
			return FontValidationResult.okWithWarning(
				font_type,
				num_tables,
				tables_verified,
				"head table checksum mismatch (font may have been modified)",
			);
		}
	}

	// Verify whole-file checksum adjustment
	if (!options.skip_checksums) {
		const stored_adj = std.mem.readInt(u32, head_data[8..12], .big);
		const whole_file_sum = calcChecksum(data);

		// The magic value: whole_file_sum should equal 0xB1B0AFBA when font is correct.
		// stored_adjustment = expected_sum - sum_without_adjustment
		// where sum_without_adjustment = whole_file_sum - stored_adjustment
		const expected_sum: u32 = 0xB1B0AFBA;
		const sum_without_adj = whole_file_sum -% stored_adj;
		const expected_adjustment = expected_sum -% sum_without_adj;

		if (stored_adj != expected_adjustment) {
			// Whole-file checksum adjustment is wrong but structure is valid
			return FontValidationResult.okWithWarning(
				font_type,
				num_tables,
				tables_verified,
				"Whole-file checkSumAdjustment invalid (font may have been modified)",
			);
		}
	}

	return FontValidationResult.ok(font_type, num_tables, tables_verified);
}

/// Parse a table directory record.
fn parseTableRecord(data: *const [16]u8) TableRecord {
	return .{
		.tag = data[0..4].*,
		.checksum = std.mem.readInt(u32, data[4..8], .big),
		.offset = std.mem.readInt(u32, data[8..12], .big),
		.length = std.mem.readInt(u32, data[12..16], .big),
	};
}

/// Validate a WOFF font.
/// WOFF wraps TTF/OTF data with compression.
pub fn validateWoff(data: []const u8) FontValidationResult {
	// WOFF header: 44 bytes minimum
	if (data.len < 44) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("WOFF"));
	}

	// Verify signature
	if (!std.mem.eql(u8, data[0..4], "wOFF")) {
		return FontValidationResult.invalid(errmsg.invalidSignature("WOFF"));
	}

	// Parse header
	const flavor = data[4..8]; // Original sfnt version
	// bytes 8-11: length (we don't need it for validation)
	const num_tables = std.mem.readInt(u16, data[12..14], .big);
	// reserved, totalSfntSize, majorVersion, minorVersion follow...

	// Validate flavor (should be TTF or CFF)
	const font_type: FontType = blk: {
		if (std.mem.eql(u8, flavor, &[_]u8{ 0x00, 0x01, 0x00, 0x00 })) {
			break :blk .woff;
		} else if (std.mem.eql(u8, flavor, "OTTO")) {
			break :blk .woff;
		} else {
			return FontValidationResult.invalid("Invalid WOFF flavor");
		}
	};

	// For WOFF, we trust the container structure since decompressing
	// all tables would be expensive. The structure itself is validated.
	return FontValidationResult.ok(font_type, num_tables, 0);
}

/// Validate a WOFF2 font.
/// WOFF2 uses Brotli compression and a different table format.
pub fn validateWoff2(data: []const u8) FontValidationResult {
	// WOFF2 header: 48 bytes minimum
	if (data.len < 48) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("WOFF2"));
	}

	// Verify signature
	if (!std.mem.eql(u8, data[0..4], "wOF2")) {
		return FontValidationResult.invalid(errmsg.invalidSignature("WOFF2"));
	}

	// Parse header
	const flavor = data[4..8]; // Original sfnt version
	// bytes 8-11: length (we don't need it for validation)
	const num_tables = std.mem.readInt(u16, data[12..14], .big);

	// Validate flavor
	if (!std.mem.eql(u8, flavor, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }) and
		!std.mem.eql(u8, flavor, "OTTO"))
	{
		return FontValidationResult.invalid("Invalid WOFF2 flavor");
	}

	// WOFF2 tables are Brotli-compressed, so we can't easily verify
	// their checksums without a Brotli decoder.
	return FontValidationResult.ok(.woff2, num_tables, 0);
}

/// Validate a Type1 font (PFB or PFA format).
/// PFB: Binary format with segment structure
/// PFA: ASCII format (PostScript source)
pub fn validateType1(data: []const u8) FontValidationResult {
	if (data.len < 6) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("Type1 font"));
	}

	// Check for PFB format: starts with 0x80 followed by segment type (1, 2, or 3)
	if (data[0] == 0x80 and (data[1] == 0x01 or data[1] == 0x02)) {
		return validateType1Pfb(data);
	}

	// Check for PFA format: starts with "%!" (PostScript header)
	if (data.len >= 2 and data[0] == '%' and data[1] == '!') {
		return validateType1Pfa(data);
	}

	return FontValidationResult.invalid(errmsg.invalidSignature("Type1"));
}

/// Validate a PFB (PostScript Font Binary) file.
/// PFB consists of segments with:
/// - 0x80: segment marker
/// - type: 1=ASCII, 2=binary, 3=EOF
/// - length: 4 bytes little-endian
/// - data: length bytes
fn validateType1Pfb(data: []const u8) FontValidationResult {
	var pos: usize = 0;
	var segment_count: u16 = 0;
	var found_eof = false;

	while (pos < data.len) {
		// Check segment marker
		if (data[pos] != 0x80) {
			return FontValidationResult.invalid("Invalid PFB segment marker");
		}
		pos += 1;

		if (pos >= data.len) {
			return FontValidationResult.invalid(errmsg.truncated("PFB segment header"));
		}

		const segment_type = data[pos];
		pos += 1;

		// Type 3 = EOF marker (no length/data)
		if (segment_type == 0x03) {
			found_eof = true;
			break;
		}

		// Types 1 (ASCII) and 2 (binary) have length + data
		if (segment_type != 0x01 and segment_type != 0x02) {
			return FontValidationResult.invalid("Invalid PFB segment type");
		}

		if (pos + 4 > data.len) {
			return FontValidationResult.invalid(errmsg.truncated("PFB segment length"));
		}

		// Length is little-endian
		const length = std.mem.readInt(u32, data[pos..][0..4], .little);
		pos += 4;

		// Verify segment data fits
		if (pos + length > data.len) {
			return FontValidationResult.invalid("PFB segment extends beyond file");
		}

		pos += length;
		segment_count += 1;

		// Sanity check
		if (segment_count > 10000) {
			return FontValidationResult.invalid(errmsg.tooMany("PFB segments"));
		}
	}

	if (segment_count == 0) {
		return FontValidationResult.invalid("No PFB data segments");
	}

	// Note: EOF marker is optional in some implementations
	return FontValidationResult.ok(.truetype, segment_count, segment_count);
}

/// Validate a PFA (PostScript Font ASCII) file.
/// PFA is plain ASCII PostScript source.
fn validateType1Pfa(data: []const u8) FontValidationResult {
	// PFA should start with "%!PS-AdobeFont" or similar
	// Minimum: "%!FontType1" or "%!PS"
	if (data.len < 10) {
		return FontValidationResult.invalid("PFA file too small");
	}

	// Check for required PostScript keywords
	var found_fonttype = false;
	var found_dict = false;
	var found_def = false;

	// Simple scan for key tokens (not a full PS parser)
	var i: usize = 0;
	while (i + 8 < data.len and i < 8192) : (i += 1) {
		if (data[i] == 'F' and i + 8 <= data.len) {
			if (std.mem.eql(u8, data[i..][0..8], "FontType")) {
				found_fonttype = true;
			}
		}
		if (data[i] == 'd' and i + 4 <= data.len) {
			if (std.mem.eql(u8, data[i..][0..4], "dict")) {
				found_dict = true;
			}
		}
		if (data[i] == 'd' and i + 3 <= data.len) {
			if (std.mem.eql(u8, data[i..][0..3], "def")) {
				found_def = true;
			}
		}
	}

	// A valid PFA should have at least some PostScript structure
	if (!found_def) {
		return FontValidationResult.invalid("PFA missing PostScript structure");
	}

	return FontValidationResult.ok(.truetype, 1, 1);
}

/// Validate a CFF (Compact Font Format) file.
/// CFF is used standalone or embedded in OpenType fonts.
pub fn validateCff(data: []const u8) FontValidationResult {
	// CFF header is at least 4 bytes
	if (data.len < 4) {
		return FontValidationResult.invalid(errmsg.fileTooSmallFor("CFF"));
	}

	// CFF header:
	// - major version: u8 (should be 1 or 2)
	// - minor version: u8
	// - header size: u8 (minimum 4)
	// - offSize: u8 (1-4)

	const major = data[0];
	const minor = data[1];
	const hdr_size = data[2];
	const off_size = data[3];

	// Validate version
	if (major != 1 and major != 2) {
		return FontValidationResult.invalid("Invalid CFF version");
	}

	// Validate header size
	if (hdr_size < 4) {
		return FontValidationResult.invalid("Invalid CFF header size");
	}

	// Validate offSize
	if (off_size < 1 or off_size > 4) {
		return FontValidationResult.invalid("Invalid CFF offSize");
	}

	// Check file is large enough for header
	if (data.len < hdr_size) {
		return FontValidationResult.invalid("CFF file truncated at header");
	}

	// After header comes the Name INDEX, which is a CFF index structure
	// INDEX: count (2 bytes), offSize (1 byte), offset array, data
	const idx_start = hdr_size;
	if (data.len < idx_start + 3) {
		return FontValidationResult.invalid("CFF Name INDEX truncated");
	}

	const name_count = std.mem.readInt(u16, data[idx_start..][0..2], .big);

	// Name INDEX should have at least 1 name (the font name)
	// But 0 is valid for empty fonts
	if (name_count > 256) {
		// Reasonable limit for number of fonts in a CFF
		return FontValidationResult.invalid("CFF Name INDEX count too large");
	}

	// Basic structure looks valid
	_ = minor; // suppress unused warning
	return FontValidationResult.ok(.opentype_cff, name_count, 1);
}

// ============ Tests ============

test "calcChecksum simple" {
	const data = [_]u8{ 0x00, 0x00, 0x00, 0x01 };
	const sum = calcChecksum(&data);
	try std.testing.expectEqual(@as(u32, 1), sum);
}

test "calcChecksum multiple values" {
	const data = [_]u8{
		0x00, 0x00, 0x00, 0x01, // 1
		0x00, 0x00, 0x00, 0x02, // 2
	};
	const sum = calcChecksum(&data);
	try std.testing.expectEqual(@as(u32, 3), sum);
}

test "calcChecksum with padding" {
	// 5 bytes - last byte needs padding
	const data = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x80 };
	const sum = calcChecksum(&data);
	// 1 + 0x80000000
	try std.testing.expectEqual(@as(u32, 0x80000001), sum);
}

test "validateTtfOtf rejects too small" {
	const data = [_]u8{ 0x00, 0x01, 0x00, 0x00 };
	const result = validateTtfOtf(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("File too small for TTF/OTF", result.error_message.?);
}

test "validateTtfOtf rejects invalid signature" {
	var data: [32]u8 = undefined;
	@memset(&data, 0);
	data[0] = 0xFF; // Invalid signature
	const result = validateTtfOtf(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("Invalid sfnt version", result.error_message.?);
}

test "validateTtfOtf rejects zero tables" {
	var data: [32]u8 = undefined;
	@memset(&data, 0);
	// Valid TrueType signature
	data[0] = 0x00;
	data[1] = 0x01;
	data[2] = 0x00;
	data[3] = 0x00;
	// numTables = 0
	data[4] = 0;
	data[5] = 0;

	const result = validateTtfOtf(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("No tables in font", result.error_message.?);
}

test "validateWoff rejects too small" {
	const data = [_]u8{ 'w', 'O', 'F', 'F' };
	const result = validateWoff(&data);
	try std.testing.expect(!result.valid);
}

test "validateWoff rejects invalid signature" {
	var data: [48]u8 = undefined;
	@memset(&data, 0);
	data[0] = 'X';
	const result = validateWoff(&data);
	try std.testing.expect(!result.valid);
}

test "validateWoff2 rejects too small" {
	const data = [_]u8{ 'w', 'O', 'F', '2' };
	const result = validateWoff2(&data);
	try std.testing.expect(!result.valid);
}

test "validateWoff2 rejects invalid signature" {
	var data: [52]u8 = undefined;
	@memset(&data, 0);
	data[0] = 'X';
	const result = validateWoff2(&data);
	try std.testing.expect(!result.valid);
}

// Test with a minimal valid TTF structure
test "validateTtfOtf minimal valid structure" {
	// Create minimal TTF with head table
	var data: [256]u8 = undefined;
	@memset(&data, 0);

	// sfnt version (TrueType)
	data[0] = 0x00;
	data[1] = 0x01;
	data[2] = 0x00;
	data[3] = 0x00;

	// numTables = 1
	data[4] = 0;
	data[5] = 1;
	// searchRange, entrySelector, rangeShift (placeholder values)
	data[6] = 0;
	data[7] = 16;
	data[8] = 0;
	data[9] = 0;
	data[10] = 0;
	data[11] = 0;

	// Table record for 'head' at offset 12
	data[12] = 'h';
	data[13] = 'e';
	data[14] = 'a';
	data[15] = 'd';

	// Checksum (we'll calculate this)
	// For now, put placeholder - head table has special handling

	// Offset = 28 (after sfnt header + 1 table record)
	data[20] = 0;
	data[21] = 0;
	data[22] = 0;
	data[23] = 28;

	// Length = 54 (minimum head table)
	data[24] = 0;
	data[25] = 0;
	data[26] = 0;
	data[27] = 54;

	// head table at offset 28
	// version = 1.0
	data[28] = 0;
	data[29] = 1;
	data[30] = 0;
	data[31] = 0;
	// fontRevision (4 bytes)
	// checkSumAdjustment at offset 8 (global offset 36)
	// magicNumber at offset 12 should be 0x5F0F3CF5
	data[28 + 12] = 0x5F;
	data[28 + 13] = 0x0F;
	data[28 + 14] = 0x3C;
	data[28 + 15] = 0xF5;

	// Now calculate checksum for table record
	// head checksum calculation is special - checkSumAdjustment is zeroed

	const result = validateTtfOtf(&data);
	try std.testing.expect(result.valid);
	try std.testing.expectEqual(FontType.truetype, result.font_type.?);
	try std.testing.expectEqual(@as(u16, 1), result.num_tables);
}

test "validateTtfOtf checksum mismatch reports fallback detail" {
	var data: [256]u8 = undefined;
	@memset(&data, 0);

	// sfnt version (TrueType)
	data[0] = 0x00;
	data[1] = 0x01;
	data[2] = 0x00;
	data[3] = 0x00;

	// numTables = 2
	data[4] = 0;
	data[5] = 2;
	// searchRange, entrySelector, rangeShift (placeholder values)
	data[6] = 0;
	data[7] = 32;
	data[8] = 0;
	data[9] = 1;
	data[10] = 0;
	data[11] = 0;

	// Table record 0: 'head'
	data[12] = 'h';
	data[13] = 'e';
	data[14] = 'a';
	data[15] = 'd';
	// checksum placeholder (head table skipped)
	data[20] = 0;
	data[21] = 0;
	data[22] = 0;
	data[23] = 44; // head offset (after 2 table records)
	data[24] = 0;
	data[25] = 0;
	data[26] = 0;
	data[27] = 54; // head length

	// Table record 1: 'test'
	data[28] = 't';
	data[29] = 'e';
	data[30] = 's';
	data[31] = 't';
	// checksum (intentionally wrong: 0)
	data[32] = 0;
	data[33] = 0;
	data[34] = 0;
	data[35] = 0;
	// offset = 98 (44 + 54)
	data[36] = 0;
	data[37] = 0;
	data[38] = 0;
	data[39] = 98;
	// length = 4
	data[40] = 0;
	data[41] = 0;
	data[42] = 0;
	data[43] = 4;

	// head table at offset 44
	data[44] = 0;
	data[45] = 1;
	data[46] = 0;
	data[47] = 0;
	// magicNumber in head table (offset 12 in head)
	data[44 + 12] = 0x5F;
	data[44 + 13] = 0x0F;
	data[44 + 14] = 0x3C;
	data[44 + 15] = 0xF5;

	// test table data at offset 98 (arbitrary bytes)
	data[98] = 1;
	data[99] = 2;
	data[100] = 3;
	data[101] = 4;

	const result = validateTtfOtf(&data);
	// Checksum mismatch with valid structure now returns valid with warning
	try std.testing.expect(result.valid);
	try std.testing.expectEqualStrings(CHECKSUM_FALLBACK_OK, result.warning_message.?);
}

// Type1 PFB tests
test "validateType1 rejects too small" {
	const data = [_]u8{ 0x80, 0x01 };
	const result = validateType1(&data);
	try std.testing.expect(!result.valid);
}

test "validateType1 rejects invalid signature" {
	var data: [32]u8 = undefined;
	@memset(&data, 0);
	data[0] = 0xFF;
	const result = validateType1(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("Invalid Type1 signature", result.error_message.?);
}

test "validateType1 minimal PFB" {
	// Minimal PFB: ASCII segment + EOF marker
	var data: [16]u8 = undefined;
	@memset(&data, 0);

	// Segment 1: ASCII (type 1)
	data[0] = 0x80; // marker
	data[1] = 0x01; // ASCII segment
	data[2] = 0x02; // length = 2 (little-endian)
	data[3] = 0x00;
	data[4] = 0x00;
	data[5] = 0x00;
	data[6] = 'A'; // data
	data[7] = 'B';

	// EOF segment
	data[8] = 0x80;
	data[9] = 0x03; // EOF

	const result = validateType1(&data);
	try std.testing.expect(result.valid);
}

test "validateType1 truncated PFB segment" {
	// PFB segment claims more data than available
	var data: [10]u8 = undefined;
	@memset(&data, 0);

	data[0] = 0x80;
	data[1] = 0x01; // ASCII segment
	data[2] = 0xFF; // length = 255 (but only 4 bytes follow)
	data[3] = 0x00;
	data[4] = 0x00;
	data[5] = 0x00;

	const result = validateType1(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("PFB segment extends beyond file", result.error_message.?);
}

test "validateType1 minimal PFA" {
	// Minimal PFA with PostScript structure including 'def' keyword
	const data = "%!PS-AdobeFont-1.0\n/FontName /TestFont def\n/FontType 1 def\n";
	const result = validateType1(data);
	try std.testing.expect(result.valid);
}

test "validateType1 PFA missing structure" {
	// PFA header but no PostScript content - missing 'def' keyword
	const longer = "%!PS\n" ++ "random content without keywords" ++ "\n" ** 10;
	const result = validateType1(longer);
	try std.testing.expect(!result.valid);
}

// CFF tests
test "validateCff rejects too small" {
	const data = [_]u8{ 0x01, 0x00 };
	const result = validateCff(&data);
	try std.testing.expect(!result.valid);
}

test "validateCff rejects invalid version" {
	var data: [10]u8 = undefined;
	@memset(&data, 0);
	data[0] = 0x05; // Invalid major version
	data[1] = 0x00;
	data[2] = 0x04; // header size
	data[3] = 0x01; // offSize

	const result = validateCff(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("Invalid CFF version", result.error_message.?);
}

test "validateCff rejects invalid offSize" {
	var data: [10]u8 = undefined;
	@memset(&data, 0);
	data[0] = 0x01; // major version 1
	data[1] = 0x00;
	data[2] = 0x04; // header size
	data[3] = 0x05; // Invalid offSize (must be 1-4)

	const result = validateCff(&data);
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("Invalid CFF offSize", result.error_message.?);
}

test "validateCff minimal valid" {
	var data: [16]u8 = undefined;
	@memset(&data, 0);

	// CFF header
	data[0] = 0x01; // major version 1
	data[1] = 0x00; // minor version 0
	data[2] = 0x04; // header size
	data[3] = 0x01; // offSize 1

	// Name INDEX at offset 4
	data[4] = 0x00; // count = 1 (big-endian)
	data[5] = 0x01;
	// ... INDEX continues but we only check count

	const result = validateCff(&data);
	try std.testing.expect(result.valid);
}
