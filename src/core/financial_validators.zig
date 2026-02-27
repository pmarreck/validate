const std = @import("std");
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const document_validators = @import("document_validators.zig");
const archive_validators = @import("archive_validators.zig");
const Allocator = std.mem.Allocator;

/// Validates a QuickBooks Company File (.qbw).
/// Modern QBW files (2007+) are SQL Anywhere databases with an Intuit header overlay.
/// Legacy QBW files (pre-2007) use a MAUI/Btrieve format with 1024-byte blocks.
pub fn validateQbw(file: std.fs.File) ValidationResult {
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.qbw, .file_too_small, "failed to get file size");
	};

	// QBW files must be at least 1024 bytes (one block)
	if (file_size < 1024) {
		return ValidationResult.invalidCode(.qbw, .file_too_small, "QuickBooks company file");
	}

	// Read the first 1024 bytes (first page/block)
	var header: [1024]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_seek, "QuickBooks header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_read, "QuickBooks header");
	};
	if (bytes_read < 1024) {
		return ValidationResult.invalidCode(.qbw, .file_too_small, "QuickBooks company file header incomplete");
	}

	// Check for modern SQL Anywhere format: 5E BA 7A DA at offset 0x14
	const sql_anywhere_magic = [4]u8{ 0x5E, 0xBA, 0x7A, 0xDA };
	if (std.mem.eql(u8, header[0x14..0x18], &sql_anywhere_magic)) {
		// Modern QBW (SQL Anywhere 10-17+)
		// File size should be a multiple of 4096 (SQL Anywhere page size)
		if (file_size % 4096 != 0) {
			return ValidationResult.invalidCode(.qbw, .invalid_value, "file size not aligned to 4096-byte SQL Anywhere pages");
		}

		// Look for SAP copyright string at offset 0x349 as additional confirmation
		if (bytes_read >= 0x34D) {
			if (std.mem.eql(u8, header[0x349..0x34C], "SAP")) {
				return ValidationResult.okWithDepth(.qbw, .structural);
			}
		}

		// Even without SAP string (may be encrypted or different version), the SQL Anywhere
		// constant and page alignment are sufficient for structural validation
		return ValidationResult.okWithDepth(.qbw, .structural);
	}

	// Check for legacy MAUI format: "MAUI" at offset 0x60
	if (std.mem.eql(u8, header[0x60..0x64], "MAUI")) {
		// Legacy QBW (Btrieve/C-tree, pre-2007)
		// File size must be a multiple of 1024 bytes
		if (file_size % 1024 != 0) {
			return ValidationResult.invalidCode(.qbw, .invalid_value, "file size not aligned to 1024-byte blocks");
		}

		// Read block count fields
		const data_blocks_m1 = std.mem.readInt(u32, header[0x24..0x28], .little);
		const total_blocks_m1 = std.mem.readInt(u32, header[0x34..0x38], .little);

		// Total blocks must exceed data blocks
		if (total_blocks_m1 == 0 or total_blocks_m1 <= data_blocks_m1) {
			return ValidationResult.invalidCode(.qbw, .invalid_value, "total block count must exceed data block count");
		}

		// Verify file size matches block count
		const expected_size: u64 = @as(u64, total_blocks_m1 + 1) * 1024;
		if (expected_size != file_size) {
			return ValidationResult.invalidCode(.qbw, .invalid_value, "file size does not match block count");
		}

		return ValidationResult.okWithDepth(.qbw, .structural);
	}

	// Neither SQL Anywhere nor MAUI signature found
	return ValidationResult.invalidCode(.qbw, .invalid_signature, "QuickBooks company file (expected SQL Anywhere or MAUI signature)");
}

/// Validates a QuickBooks Backup/Portable file (.qbb, .qbm).
/// QBB/QBM files are OLE2 compound files containing a compressed QBW database.
pub fn validateQbb(file: std.fs.File) ValidationResult {
	var header: [8]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qbb, .failed_to_seek, "QuickBooks backup header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.qbb, .failed_to_read, "QuickBooks backup header");
	};
	if (bytes_read < 8) {
		return ValidationResult.invalidCode(.qbb, .file_too_small, "QuickBooks backup");
	}

	// Check for OLE2 magic: D0 CF 11 E0 A1 B1 1A E1
	const ole2_magic = [8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
	if (std.mem.eql(u8, &header, &ole2_magic)) {
		return ValidationResult.okWithDepth(.qbb, .structural);
	}

	// Check for Gary Kessler's QBB signature: 45 86 00 00 06 00
	if (bytes_read >= 6) {
		const qbb_magic = [6]u8{ 0x45, 0x86, 0x00, 0x00, 0x06, 0x00 };
		if (std.mem.eql(u8, header[0..6], &qbb_magic)) {
			return ValidationResult.okWithDepth(.qbb, .structural);
		}
	}

	return ValidationResult.invalidCode(.qbb, .invalid_signature, "QuickBooks backup (expected OLE2 or QBB signature)");
}

/// Validates a Quicken Data File (.qdf).
/// QDF files come in three variants:
/// 1. Modern (2010+): ZIP container with internal .QDF, .QEL, .QPH, .IDX entries
/// 2. OLE2 variant: Microsoft Compound File containing Quicken data streams
/// 3. Legacy (pre-2010): Proprietary format with AC 9E BD 8F 00 00 magic
pub fn validateQdf(file: std.fs.File) ValidationResult {
	var header: [8]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qdf, .failed_to_seek, "Quicken data file header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.qdf, .failed_to_read, "Quicken data file header");
	};
	if (bytes_read < 6) {
		return ValidationResult.invalidCode(.qdf, .file_too_small, "Quicken data file");
	}

	// Check for OLE2 magic: D0 CF 11 E0 A1 B1 1A E1
	if (bytes_read >= 8) {
		const ole2_magic = [8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
		if (std.mem.eql(u8, &header, &ole2_magic)) {
			return ValidationResult.okWithDepth(.qdf, .structural);
		}
	}

	// Check for ZIP magic: 50 4B 03 04
	if (std.mem.eql(u8, header[0..4], &[4]u8{ 0x50, 0x4B, 0x03, 0x04 })) {
		return ValidationResult.okWithDepth(.qdf, .structural);
	}

	// Check for legacy QDF magic: AC 9E BD 8F 00 00
	const qdf_magic = [6]u8{ 0xAC, 0x9E, 0xBD, 0x8F, 0x00, 0x00 };
	if (std.mem.eql(u8, header[0..6], &qdf_magic)) {
		return ValidationResult.okWithDepth(.qdf, .structural);
	}

	return ValidationResult.invalidCode(.qdf, .invalid_signature, "Quicken data file (expected OLE2, ZIP, or legacy QDF signature)");
}

/// Validates an Open Financial Exchange file (.ofx, .qfx).
/// OFX files use either SGML (OFX 1.x) or XML (OFX 2.x) format.
pub fn validateOfx(file: std.fs.File) ValidationResult {
	var header: [512]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.ofx, .failed_to_seek, "OFX header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.ofx, .failed_to_read, "OFX header");
	};
	if (bytes_read < 10) {
		return ValidationResult.invalidCode(.ofx, .file_too_small, "OFX file");
	}

	const data = header[0..bytes_read];

	// Skip optional UTF-8 BOM
	var start: usize = 0;
	if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		start = 3;
	}

	// Skip leading whitespace
	while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) {
		start += 1;
	}

	if (start >= data.len) {
		return ValidationResult.invalidCode(.ofx, .invalid_signature, "OFX file (empty content)");
	}

	const trimmed = data[start..];

	// OFX 1.x (SGML): starts with OFXHEADER: or <OFX>
	if (trimmed.len >= 10 and std.mem.startsWith(u8, trimmed, "OFXHEADER:")) {
		// Validate OFXHEADER line followed by required headers
		return validateOfxSgml(trimmed);
	}

	// OFX 2.x (XML): starts with <?xml or <?OFX
	if (trimmed.len >= 5) {
		if (std.mem.startsWith(u8, trimmed, "<?xml") or std.mem.startsWith(u8, trimmed, "<?OFX")) {
			// Check for OFX namespace or element somewhere in the header
			if (std.mem.indexOf(u8, trimmed, "<OFX>") != null or
				std.mem.indexOf(u8, trimmed, "<OFX ") != null or
				std.mem.indexOf(u8, trimmed, "ofx") != null)
			{
				return ValidationResult.okWithDepth(.ofx, .structural);
			}
			// XML but no OFX markers found in first 512 bytes — still could be OFX
			// (the <OFX> tag might be further in), trust the extension
			return ValidationResult.okWithDepth(.ofx, .structural);
		}
	}

	// Direct <OFX> tag (some generators skip the XML declaration)
	if (std.mem.startsWith(u8, trimmed, "<OFX>") or std.mem.startsWith(u8, trimmed, "<OFX ")) {
		return ValidationResult.okWithDepth(.ofx, .structural);
	}

	return ValidationResult.invalidCode(.ofx, .invalid_signature, "OFX file (expected OFXHEADER:, <?xml, or <OFX>)");
}

/// Validate OFX 1.x SGML header structure.
fn validateOfxSgml(data: []const u8) ValidationResult {
	// OFXHEADER:100 is the standard first line
	// Must contain at minimum OFXHEADER: followed by version digits
	if (data.len < 14) {
		return ValidationResult.invalidCode(.ofx, .file_too_small, "OFX SGML header too short");
	}

	// Look for key OFX SGML headers in the data
	var found_data_tag = false;
	var found_version = false;

	if (std.mem.indexOf(u8, data, "DATA:") != null) {
		found_data_tag = true;
	}
	if (std.mem.indexOf(u8, data, "VERSION:") != null) {
		found_version = true;
	}

	if (found_data_tag and found_version) {
		return ValidationResult.okWithDepth(.ofx, .structural);
	}

	// At minimum, OFXHEADER: prefix is present (already checked by caller)
	return ValidationResult.okWithDepth(.ofx, .structural);
}

/// Validates a Quicken Interchange Format file (.qif).
/// QIF is a plain text format with single-character field codes.
pub fn validateQif(file: std.fs.File) ValidationResult {
	var header: [256]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qif, .failed_to_seek, "QIF header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.qif, .failed_to_read, "QIF header");
	};
	if (bytes_read < 6) {
		return ValidationResult.invalidCode(.qif, .file_too_small, "QIF file");
	}

	const data = header[0..bytes_read];

	// Skip optional UTF-8 BOM
	var start: usize = 0;
	if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		start = 3;
	}

	// Skip leading whitespace
	while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) {
		start += 1;
	}

	if (start >= data.len) {
		return ValidationResult.invalidCode(.qif, .invalid_signature, "QIF file (empty content)");
	}

	const trimmed = data[start..];

	// QIF files must start with !Type: or !Account or !Option
	if (std.mem.startsWith(u8, trimmed, "!Type:") or
		std.mem.startsWith(u8, trimmed, "!Account") or
		std.mem.startsWith(u8, trimmed, "!Option"))
	{
		// Look for record separator (^) to confirm QIF structure
		if (std.mem.indexOf(u8, trimmed, "\n^") != null or
			std.mem.indexOf(u8, trimmed, "\r\n^") != null or
			std.mem.indexOf(u8, trimmed, "\r^") != null)
		{
			return ValidationResult.okWithDepth(.qif, .structural);
		}
		// No record separator found yet, but header is correct — file may be truncated
		// or have only one record. Trust the !Type: prefix.
		return ValidationResult.okWithDepth(.qif, .structural);
	}

	return ValidationResult.invalidCode(.qif, .invalid_signature, "QIF file (expected !Type: or !Account header)");
}

/// Validates a Tax Exchange Format file (.txf).
/// TXF is a plain text format for US federal income tax data, version-prefixed.
pub fn validateTxf(file: std.fs.File) ValidationResult {
	var header: [128]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.txf, .failed_to_seek, "TXF header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.txf, .failed_to_read, "TXF header");
	};
	if (bytes_read < 4) {
		return ValidationResult.invalidCode(.txf, .file_too_small, "TXF file");
	}

	const data = header[0..bytes_read];

	// Skip optional UTF-8 BOM
	var start: usize = 0;
	if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		start = 3;
	}

	// Skip leading whitespace
	while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) {
		start += 1;
	}

	if (start + 4 > data.len) {
		return ValidationResult.invalidCode(.txf, .invalid_signature, "TXF file (too short)");
	}

	const trimmed = data[start..];

	// TXF files start with 'V' followed by 3 version digits (e.g., V042)
	if (trimmed[0] == 'V' and
		trimmed[1] >= '0' and trimmed[1] <= '9' and
		trimmed[2] >= '0' and trimmed[2] <= '9' and
		trimmed[3] >= '0' and trimmed[3] <= '9')
	{
		// Look for the 'A' (application) line following the version
		if (std.mem.indexOf(u8, trimmed, "\nA") != null or
			std.mem.indexOf(u8, trimmed, "\r\nA") != null or
			std.mem.indexOf(u8, trimmed, "\rA") != null)
		{
			return ValidationResult.okWithDepth(.txf, .structural);
		}
		// Version line found but no 'A' line in the first 128 bytes —
		// trust the V### prefix
		return ValidationResult.okWithDepth(.txf, .structural);
	}

	return ValidationResult.invalidCode(.txf, .invalid_signature, "TXF file (expected V followed by 3 version digits)");
}

// ============================================================================
// Deep Validators
// ============================================================================

/// Deep validation of QuickBooks Company Files (.qbw) via per-page CRC-32.
///
/// ## QBW File Format (reverse-engineered 2026-02-26)
///
/// QBW files are SAP SQL Anywhere databases. Key structural facts:
///
/// **Page layout**: Fixed 4096-byte pages. File size is always a multiple of 4096.
///
/// **Header (page 0)**:
///   - Offset 0x14: SQL Anywhere magic `5E BA 7A DA` (all modern versions)
///   - Offset 0x06: Flags byte (0x29 for v11/Sybase, 0x09 for v17/SAP)
///   - Offset 0x1C: Total page count (u16 LE, but only for smaller files)
///   - Copyright string at varying offset (0x2C4 for v11, 0x349 for v17):
///     Format: "<vendor>, Copyright (c)<year> <major>.<minor>.<patch>.<build>"
///     Examples: "Sybase Inc., Copyright (c)2000 11.0.1.2250"
///               "SAP SE, Copyright (c)2015 17.0.4.2182"
///
/// **CRC-32 integrity** (standard ISO 3309, polynomial 0xEDB88320):
///   - Algorithm: `CRC32(page[0..4092])` stored as u32 LE at `page[4092..4096]`
///   - v17+ (SAP era): CRC on ALL pages → full integrity verification possible
///   - v11 (Sybase era): CRC only on system/checkpoint pages (see below)
///
/// **v11 system page map** (empirically verified on 3 files, 20484 pages each):
///   - Pages 0, 1: header pages (always have CRC)
///   - Pages 8, 9, 10: early system pages (have CRC)
///   - Pages 56, 120, 153: system metadata (have CRC, positions may be file-specific)
///   - Checkpoint pages at 4064-page intervals from page 1: 4065, 8129, 12193, ...
///   - Total: ~13 system pages with CRC out of 20484
///   - Data pages use the last 4 bytes for metadata, NOT checksums:
///     0x00000000 (9979 pages, free/unused), 0x00010000 (4298 pages, type flag),
///     0x00000FC0 (1233 pages), 0x00000001 (1018 pages), 0xFEFEFEFE (98 pages,
///     uninitialized marker), plus ~2100 other structured values.
///   - These are clearly not checksums: checksums would be pseudo-random/unique,
///     but these are highly structured with massive repetition (0x00010000 x 4298).
///
/// **Password protection** (v11, password "farming" on test file):
///   - NOT encryption — only 121 of 20484 pages changed (access control metadata)
///   - Pages 509-510, 774, 1334-1335 had the most changes (user/permission tables)
///   - Page 0 CRC was correctly updated after password was set, confirming v11
///     actively maintains CRCs on system pages through write operations
///   - v11 password protection is application-layer gating, not crypto
///
/// **Version detection**: We parse the SA major version from the copyright string
/// on page 0 rather than sampling CRC pass rates (which could mask corruption on
/// a v17 file by misclassifying it as "old version without CRC").
///   - v12+: CRC on all pages expected → any failure = corruption FAIL
///   - v11-: CRC only on system pages → verify those, structural for the rest
///   - Unknown: fail-safe, treat as v12+ (CRC failures = corruption)
pub fn validateQbwDeep(allocator: Allocator, path: []const u8) ValidationResult {
	_ = allocator;

	const file = std.fs.cwd().openFile(path, .{}) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_open, "QuickBooks company file");
	};
	defer file.close();

	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_read, "QuickBooks file size");
	};

	// Must be a multiple of 4096
	if (file_size < 4096 or file_size % 4096 != 0) {
		return ValidationResult.invalidCode(.qbw, .invalid_value, "file size not aligned to 4096-byte pages");
	}

	const total_pages = file_size / 4096;

	// Read page 0 (header page)
	var page_buf: [4096]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_seek, "page 0 header");
	};
	var bytes_read = file.readAll(&page_buf) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_read, "page 0 header");
	};
	if (bytes_read < 4096) {
		return ValidationResult.invalidCode(.qbw, .file_too_small, "page 0 header");
	}

	// Verify SQL Anywhere magic at offset 0x14
	const sql_anywhere_magic = [4]u8{ 0x5E, 0xBA, 0x7A, 0xDA };
	if (!std.mem.eql(u8, page_buf[0x14..0x18], &sql_anywhere_magic)) {
		// Not a modern SQL Anywhere QBW — fall back to structural-only
		return ValidationResult.okWithDepth(.qbw, .structural);
	}

	// Verify page 0 CRC-32 (header page always has CRC in all SA versions)
	const page0_stored = std.mem.readInt(u32, page_buf[4092..4096], .little);
	const page0_computed = std.hash.Crc32.hash(page_buf[0..4092]);
	if (page0_stored != page0_computed) {
		return ValidationResult.invalidCode(.qbw, .checksum_mismatch, "SQL Anywhere header page CRC-32");
	}

	// Parse SQL Anywhere major version from copyright string on page 0.
	// Format: "Copyright (c)YYYY MM.N.P.BBBB" — we extract MM (major version).
	// The copyright string appears at varying offsets (0x2C4 for v11, 0x349 for v17)
	// so we scan page 0 for the pattern rather than using a fixed offset.
	const sa_major_version = parseSaMajorVersion(&page_buf);

	// Version-based CRC coverage decision:
	// - v12+ (SAP era): CRC-32 on ALL pages → any failure = corruption
	// - v11 and below (Sybase era): CRC only on system pages → structural-only
	// - Unknown version: attempt full CRC, failures = corruption (fail-safe)
	// The threshold of 12 is conservative; v17 is confirmed, v11 is confirmed not.
	// If we encounter a version between 12-16 with different behavior, we can adjust.
	if (sa_major_version != null and sa_major_version.? < 12) {
		// Old SA version (v11 and below): CRC-32 exists only on system/checkpoint
		// pages, not data pages. Data pages use the last 4 bytes for metadata
		// (flags like 0x00010000, counters, etc.). We verify all known system pages:
		//   - Page 0: header (already verified above)
		//   - Page 1: second system page
		//   - Checkpoint pages at 4064-page intervals from page 1
		// If any of these fail CRC, it's corruption of critical database metadata.

		// Verify page 1
		if (total_pages > 1) {
			file.seekTo(4096) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_seek, "system page 1");
			};
			bytes_read = file.readAll(&page_buf) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_read, "system page 1");
			};
			if (bytes_read < 4096) {
				return ValidationResult.invalidCode(.qbw, .truncated, "system page 1");
			}
			const stored = std.mem.readInt(u32, page_buf[4092..4096], .little);
			const computed = std.hash.Crc32.hash(page_buf[0..4092]);
			if (stored != computed) {
				return ValidationResult.invalidCode(.qbw, .checksum_mismatch, "SQL Anywhere system page 1 CRC-32");
			}
		}

		// Verify checkpoint pages at 4064-page intervals from page 1
		// (pages 4065, 8129, 12193, 16257, 20321, ...)
		const checkpoint_interval: u64 = 4064;
		var checkpoint_page: u64 = 1 + checkpoint_interval;
		while (checkpoint_page < total_pages) : (checkpoint_page += checkpoint_interval) {
			file.seekTo(checkpoint_page * 4096) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_seek, "checkpoint page");
			};
			bytes_read = file.readAll(&page_buf) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_read, "checkpoint page");
			};
			if (bytes_read < 4096) {
				return ValidationResult.invalidCode(.qbw, .truncated, "checkpoint page");
			}
			const stored = std.mem.readInt(u32, page_buf[4092..4096], .little);
			const computed = std.hash.Crc32.hash(page_buf[0..4092]);
			if (stored != computed) {
				return ValidationResult.invalidCode(.qbw, .checksum_mismatch, "SQL Anywhere checkpoint page CRC-32");
			}
		}

		return ValidationResult.okWithDepth(.qbw, .structural);
	}

	// Full per-page CRC validation (v12+, or unknown version — fail-safe)
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.qbw, .failed_to_seek, "page 0");
	};

	for (0..total_pages) |page_idx| {
		bytes_read = file.readAll(&page_buf) catch {
			return ValidationResult.invalidCode(.qbw, .failed_to_read, "page data");
		};
		if (bytes_read < 4096) {
			return ValidationResult.invalidCode(.qbw, .truncated, "page data");
		}

		const stored_crc = std.mem.readInt(u32, page_buf[4092..4096], .little);
		const computed_crc = std.hash.Crc32.hash(page_buf[0..4092]);

		if (stored_crc != computed_crc) {
			_ = page_idx;
			return ValidationResult.invalidCode(.qbw, .checksum_mismatch, "SQL Anywhere page CRC-32");
		}
	}

	return ValidationResult.okWithDepth(.qbw, .full);
}

/// Parse SQL Anywhere major version from the copyright string on page 0.
/// Scans for "Copyright (c)" followed by a 4-digit year, space, then the
/// version number (e.g. "11.0.1.2250" → returns 11, "17.0.4.2182" → returns 17).
/// Returns null if the pattern is not found.
fn parseSaMajorVersion(page0: *const [4096]u8) ?u32 {
	const needle = "Copyright (c)";
	// Search page 0 for the copyright string
	const idx = std.mem.indexOf(u8, page0, needle) orelse return null;
	// Skip "Copyright (c)" + 4-digit year + space
	const version_start = idx + needle.len + 5; // "YYYY "
	if (version_start >= 4096) return null;
	// Parse major version digits until '.'
	var major: u32 = 0;
	var i = version_start;
	var found_digit = false;
	while (i < @min(version_start + 4, 4096)) : (i += 1) {
		if (page0[i] >= '0' and page0[i] <= '9') {
			major = major * 10 + (page0[i] - '0');
			found_digit = true;
		} else break;
	}
	if (!found_digit) return null;
	// Verify it's followed by '.' (version separator)
	if (i < 4096 and page0[i] == '.') return major;
	return null;
}

/// Deep validation of QuickBooks Backup files (.qbb, .qbm) via OLE2 deep validation.
/// QBB files are OLE2 compound files; we delegate to the existing OLE2 FAT/directory validator.
pub fn validateQbbDeep(allocator: Allocator, path: []const u8) ValidationResult {
	return document_validators.validateOle2Deep(allocator, path, .qbb);
}

/// Deep validation of Quicken Data Files (.qdf).
/// QDF files come in three container variants; we dispatch to the appropriate deep validator:
/// - OLE2 variant → OLE2 FAT/directory validation
/// - ZIP variant → ZIP CRC-32 verification for all entries
/// - Legacy variant → structural only (no known integrity mechanism)
pub fn validateQdfDeep(allocator: Allocator, path: []const u8) ValidationResult {
	// Detect the container type by reading magic bytes
	const file = std.fs.cwd().openFile(path, .{}) catch {
		return ValidationResult.invalidCode(.qdf, .failed_to_open, "Quicken data file");
	};
	defer file.close();

	var header: [8]u8 = undefined;
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.qdf, .failed_to_read, "Quicken data file header");
	};

	if (bytes_read >= 8 and std.mem.eql(u8, &header, &[8]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 })) {
		// OLE2 container — use OLE2 deep validation (FAT/directory integrity)
		return document_validators.validateOle2Deep(allocator, path, .qdf);
	}

	if (bytes_read >= 4 and std.mem.eql(u8, header[0..4], &[4]u8{ 0x50, 0x4B, 0x03, 0x04 })) {
		// ZIP container — use ZIP deep validation (with CRC-32 verification)
		var result = archive_validators.validateZipDeep(allocator, path);
		// Override format to QDF (validateZipDeep returns .zip or a zip subformat)
		result.format = .qdf;
		return result;
	}

	// Legacy format — no known deep validation mechanism
	return ValidationResult.okWithDepth(.qdf, .structural);
}

// ============================================================================
// Tests
// ============================================================================

test "QBW validator: modern SQL Anywhere format" {
	// Construct a minimal QBW header with SQL Anywhere constant
	var header: [4096]u8 = [_]u8{0} ** 4096;

	// SQL Anywhere constant at offset 0x14
	header[0x14] = 0x5E;
	header[0x15] = 0xBA;
	header[0x16] = 0x7A;
	header[0x17] = 0xDA;

	// SAP copyright at offset 0x349
	const sap = "SAP";
	@memcpy(header[0x349..][0..sap.len], sap);

	// Write to temp file
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.qbw", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
}

test "QBW validator: legacy MAUI format" {
	// Construct a minimal MAUI QBW: 10 blocks of 1024
	const total_blocks: u32 = 10;
	const data_blocks: u32 = 5;

	var file_data: [10 * 1024]u8 = [_]u8{0} ** (10 * 1024);

	// MAUI at offset 0x60
	file_data[0x60] = 'M';
	file_data[0x61] = 'A';
	file_data[0x62] = 'U';
	file_data[0x63] = 'I';

	// Data blocks minus 1 at offset 0x24 (LE)
	std.mem.writeInt(u32, file_data[0x24..0x28], data_blocks - 1, .little);

	// Total blocks minus 1 at offset 0x34 (LE)
	std.mem.writeInt(u32, file_data[0x34..0x38], total_blocks - 1, .little);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_maui.qbw", .{});
	try file.writeAll(&file_data);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_maui.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
}

test "QBW validator: invalid signature" {
	var header: [4096]u8 = [_]u8{0xFF} ** 4096;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_bad.qbw", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_bad.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(!result.is_valid);
}

test "QBW validator: MAUI block count mismatch" {
	// Create MAUI file with wrong block count
	const total_blocks: u32 = 20; // Claims 20 blocks
	const data_blocks: u32 = 5;

	var file_data: [10 * 1024]u8 = [_]u8{0} ** (10 * 1024); // Only 10 blocks on disk

	file_data[0x60] = 'M';
	file_data[0x61] = 'A';
	file_data[0x62] = 'U';
	file_data[0x63] = 'I';

	std.mem.writeInt(u32, file_data[0x24..0x28], data_blocks - 1, .little);
	std.mem.writeInt(u32, file_data[0x34..0x38], total_blocks - 1, .little);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_mismatch.qbw", .{});
	try file.writeAll(&file_data);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_mismatch.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(!result.is_valid);
}

test "QBB validator: OLE2 format" {
	var header: [512]u8 = [_]u8{0} ** 512;

	// OLE2 magic
	header[0] = 0xD0;
	header[1] = 0xCF;
	header[2] = 0x11;
	header[3] = 0xE0;
	header[4] = 0xA1;
	header[5] = 0xB1;
	header[6] = 0x1A;
	header[7] = 0xE1;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.qbb", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.qbb", .{});
	defer read_file.close();

	const result = validateQbb(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbb, result.format);
}

test "QDF validator: OLE2 variant" {
	var header: [512]u8 = [_]u8{0} ** 512;

	header[0] = 0xD0;
	header[1] = 0xCF;
	header[2] = 0x11;
	header[3] = 0xE0;
	header[4] = 0xA1;
	header[5] = 0xB1;
	header[6] = 0x1A;
	header[7] = 0xE1;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.qdf", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.qdf", .{});
	defer read_file.close();

	const result = validateQdf(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qdf, result.format);
}

test "QDF validator: ZIP variant" {
	var header: [512]u8 = [_]u8{0} ** 512;

	// ZIP magic
	header[0] = 0x50; // P
	header[1] = 0x4B; // K
	header[2] = 0x03;
	header[3] = 0x04;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_zip.qdf", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_zip.qdf", .{});
	defer read_file.close();

	const result = validateQdf(read_file);
	try std.testing.expect(result.is_valid);
}

test "QDF validator: legacy format" {
	var header: [512]u8 = [_]u8{0} ** 512;

	// Legacy QDF magic: AC 9E BD 8F 00 00
	header[0] = 0xAC;
	header[1] = 0x9E;
	header[2] = 0xBD;
	header[3] = 0x8F;
	header[4] = 0x00;
	header[5] = 0x00;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_legacy.qdf", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_legacy.qdf", .{});
	defer read_file.close();

	const result = validateQdf(read_file);
	try std.testing.expect(result.is_valid);
}

test "OFX validator: SGML format (OFX 1.x)" {
	const ofx_content =
		"OFXHEADER:100\r\n" ++
		"DATA:OFXSGML\r\n" ++
		"VERSION:102\r\n" ++
		"SECURITY:NONE\r\n" ++
		"ENCODING:USASCII\r\n" ++
		"CHARSET:1252\r\n" ++
		"COMPRESSION:NONE\r\n" ++
		"OLDFILEUID:NONE\r\n" ++
		"NEWFILEUID:NONE\r\n" ++
		"\r\n" ++
		"<OFX>\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.ofx", .{});
	try file.writeAll(ofx_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.ofx", .{});
	defer read_file.close();

	const result = validateOfx(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.ofx, result.format);
}

test "OFX validator: XML format (OFX 2.x)" {
	const ofx_content =
		\\<?xml version="1.0" encoding="UTF-8"?>
		\\<?OFX OFXHEADER="200" VERSION="220"?>
		\\<OFX>
		\\<SIGNONMSGSRSV1>
		\\</SIGNONMSGSRSV1>
		\\</OFX>
	;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.ofx", .{});
	try file.writeAll(ofx_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.ofx", .{});
	defer read_file.close();

	const result = validateOfx(read_file);
	try std.testing.expect(result.is_valid);
}

test "QIF validator: Bank type" {
	const qif_content =
		"!Type:Bank\r\n" ++
		"D01/15/2024\r\n" ++
		"T-150.00\r\n" ++
		"PGrocery Store\r\n" ++
		"LFood:Groceries\r\n" ++
		"^\r\n" ++
		"D01/20/2024\r\n" ++
		"T2500.00\r\n" ++
		"PPayroll\r\n" ++
		"LIncome:Salary\r\n" ++
		"^\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.qif", .{});
	try file.writeAll(qif_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.qif", .{});
	defer read_file.close();

	const result = validateQif(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qif, result.format);
}

test "QIF validator: invalid content" {
	const bad_content = "This is not a QIF file\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_bad.qif", .{});
	try file.writeAll(bad_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_bad.qif", .{});
	defer read_file.close();

	const result = validateQif(read_file);
	try std.testing.expect(!result.is_valid);
}

test "TXF validator: valid format" {
	const txf_content =
		"V042\r\n" ++
		"AQuicken 2018 for Windows R1\r\n" ++
		"D 01/15/2024\r\n" ++
		"^\r\n" ++
		"TD\r\n" ++
		"N280\r\n" ++
		"$5000.00\r\n" ++
		"PMy Employer\r\n" ++
		"^\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.txf", .{});
	try file.writeAll(txf_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.txf", .{});
	defer read_file.close();

	const result = validateTxf(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.txf, result.format);
}

test "TXF validator: invalid content" {
	const bad_content = "Not a TXF file\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_bad.txf", .{});
	try file.writeAll(bad_content);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_bad.txf", .{});
	defer read_file.close();

	const result = validateTxf(read_file);
	try std.testing.expect(!result.is_valid);
}

test "QBW validator: too small" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_tiny.qbw", .{});
	try file.writeAll("tiny");
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_tiny.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(!result.is_valid);
}

test "QBW validator: SQL Anywhere with wrong page alignment" {
	// 4097 bytes — not a multiple of 4096
	var header: [4097]u8 = [_]u8{0} ** 4097;

	header[0x14] = 0x5E;
	header[0x15] = 0xBA;
	header[0x16] = 0x7A;
	header[0x17] = 0xDA;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_misaligned.qbw", .{});
	try file.writeAll(&header);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_misaligned.qbw", .{});
	defer read_file.close();

	const result = validateQbw(read_file);
	try std.testing.expect(!result.is_valid);
}

test "ground truth: QBW sample validates" {
	const file = std.fs.cwd().openFile("ground_truth_examples/qbw/B18_Managing_Company_Files.qbw", .{}) catch {
		return; // Skip if sample not present
	};
	defer file.close();

	const result = validateQbw(file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
}

test "ground truth: QDF sample validates" {
	const file = std.fs.cwd().openFile("ground_truth_examples/qdf/LONDON_2018.QDF", .{}) catch {
		return; // Skip if sample not present
	};
	defer file.close();

	const result = validateQdf(file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qdf, result.format);
}

// ============================================================================
// Deep Validator Tests
// ============================================================================

test "QBW deep: valid CRC-32 pages" {
	// Build a 2-page QBW file with correct CRC-32 checksums
	var page0: [4096]u8 = [_]u8{0} ** 4096;
	var page1: [4096]u8 = [_]u8{0xAB} ** 4096;

	// SQL Anywhere magic at offset 0x14
	page0[0x14] = 0x5E;
	page0[0x15] = 0xBA;
	page0[0x16] = 0x7A;
	page0[0x17] = 0xDA;

	// Compute and store CRC-32 for page 0
	const crc0 = std.hash.Crc32.hash(page0[0..4092]);
	std.mem.writeInt(u32, page0[4092..4096], crc0, .little);

	// Compute and store CRC-32 for page 1
	const crc1 = std.hash.Crc32.hash(page1[0..4092]);
	std.mem.writeInt(u32, page1[4092..4096], crc1, .little);

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("valid_deep.qbw", .{});
	try file.writeAll(&page0);
	try file.writeAll(&page1);
	file.close();

	// Construct a path for the deep validator
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("valid_deep.qbw", &path_buf);

	const result = validateQbwDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "QBW deep: corrupted CRC-32 detected" {
	// Build a 1-page QBW file, then corrupt one byte
	var page0: [4096]u8 = [_]u8{0} ** 4096;

	// SQL Anywhere magic
	page0[0x14] = 0x5E;
	page0[0x15] = 0xBA;
	page0[0x16] = 0x7A;
	page0[0x17] = 0xDA;

	// Compute correct CRC-32
	const crc0 = std.hash.Crc32.hash(page0[0..4092]);
	std.mem.writeInt(u32, page0[4092..4096], crc0, .little);

	// Corrupt a byte in the page body (after storing the checksum)
	page0[0x100] = 0xFF;

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_deep.qbw", .{});
	try file.writeAll(&page0);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_deep.qbw", &path_buf);

	const result = validateQbwDeep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "ground truth: QBW deep validation passes all page CRCs" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/qbw/B18_Managing_Company_Files.qbw", &path_buf) catch {
		return; // Skip if sample not present
	};

	const result = validateQbwDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
}

test "parseSaMajorVersion extracts version from copyright string" {
	// Simulate a page 0 with a v17 copyright string at a typical offset
	var page: [4096]u8 = [_]u8{0} ** 4096;
	const copyright = "SAP SE, Copyright (c)2015 17.0.4.2182";
	@memcpy(page[0x349..][0..copyright.len], copyright);
	try std.testing.expectEqual(@as(?u32, 17), parseSaMajorVersion(&page));

	// Simulate v11
	var page2: [4096]u8 = [_]u8{0} ** 4096;
	const copyright2 = "Sybase Inc., Copyright (c)2000 11.0.1.2250";
	@memcpy(page2[0x2C4..][0..copyright2.len], copyright2);
	try std.testing.expectEqual(@as(?u32, 11), parseSaMajorVersion(&page2));

	// No copyright string → null
	var page3: [4096]u8 = [_]u8{0} ** 4096;
	try std.testing.expectEqual(@as(?u32, null), parseSaMajorVersion(&page3));
}

test "ground truth: QBW v11 (Sybase) deep validation returns structural" {
	// SQL Anywhere v11 is detected via copyright string parsing.
	// v11 does not have per-page CRC on data pages, so we honestly report structural.
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/qbw/Farm2010.QBW", &path_buf) catch {
		return; // Skip if sample not present
	};

	const result = validateQbwDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
	// v11 should get structural depth (no full CRC coverage)
	try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "ground truth: QBW v11 password-protected deep validation" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/qbw/Farm2010 - pass.QBW", &path_buf) catch {
		return; // Skip if sample not present
	};

	const result = validateQbwDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qbw, result.format);
	try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "ground truth: QDF deep validation via OLE2" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/qdf/LONDON_2018.QDF", &path_buf) catch {
		return; // Skip if sample not present
	};

	const result = validateQdfDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.qdf, result.format);
}
