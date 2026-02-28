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
/// **Database encryption** (v11):
///   - v11 data pages are encrypted ("simple encryption" / obfuscation by SA)
///   - Entropy analysis: page 0 = 4.575 (plaintext), all other pages = 7.95-8.00
///   - This is separate from password protection and is why data pages have no CRC:
///     encrypted content cannot be checksummed externally without the key
///
/// **16-byte cleartext footer** on every page (bytes [4080:4096]):
///   - [4080]: record/slot count (0-255)
///   - [4081]: flag byte, always 0 or 1
///   - [4082:4084]: page type (u16 LE): {0=bitmap, 1=index, 5=data, 8/9=system,
///                  37/40/41/45=system/checkpoint}
///   - [4084:4088]: object/table ID or LSN (byte 4087 always 0x00)
///   - [4088:4092]: reserved, always 0x00000000
///   - [4092:4096]: CRC-32 on system pages; metadata flags on data pages
///   - Footer validation catches corruption in ~0.2% of additional bytes
///
/// **Password protection** (v11, password "farming" on test file):
///   - NOT encryption — only 121 of 20484 pages changed (access control metadata)
///   - Pages 509-510, 774, 1334-1335 had the most changes (user/permission tables)
///   - Page 0 CRC was correctly updated after password was set, confirming v11
///     actively maintains CRCs on system pages through write operations
///   - v11 password protection is application-layer gating, not crypto
///
/// **Page count fields**: offsets 0x1C and 0xC8 (both u32 LE) store total page
///   count. On v11, this matches file_size/4096 exactly. On v17, it may differ
///   (e.g. 3562 stored vs 3690 actual), so we only validate when it matches.
///
/// **Version detection**: We parse the SA major version from the copyright string
/// on page 0 rather than sampling CRC pass rates (which could mask corruption on
/// a v17 file by misclassifying it as "old version without CRC").
///   - v12+: CRC on all pages expected → any failure = corruption FAIL
///   - v11-: CRC on system pages + footer validation on all pages → structural
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
	// Cross-validate page count from header against actual file size.
	// v11 stores page count at offsets 0x1C (u32 LE) and 0xC8 (u32 LE).
	const header_page_count = std.mem.readInt(u32, page_buf[0x1C..0x20], .little);
	const header_page_count_dup = std.mem.readInt(u32, page_buf[0xC8..0xCC], .little);
	if (header_page_count == total_pages) {
		// v11-style: page count matches file size exactly
		if (header_page_count_dup != header_page_count) {
			return ValidationResult.invalidCode(.qbw, .invalid_value, "SQL Anywhere page count fields disagree");
		}
	}
	// Note: v17 may store a different value here (e.g. 3562 vs 3690 actual pages),
	// so we only validate when it matches — don't fail on v17 for this field.

	if (sa_major_version != null and sa_major_version.? < 12) {
		// Old SA version (v11 and below): CRC-32 exists only on system/checkpoint
		// pages, not data pages (data pages are encrypted, and their last 4 bytes
		// contain metadata like page type flags). We verify all known system pages:
		//   - Page 0: header (already verified above)
		//   - Pages 1, 8, 9, 10: fixed system pages
		//   - Checkpoint pages at 4064-page intervals from page 1
		// Plus footer structure validation on ALL pages (catches ~0.2% extra).
		// If any system page CRC fails, it's corruption of critical metadata.

		// Known fixed system pages with CRC (page 0 already verified)
		const system_pages = [_]u64{ 1, 8, 9, 10 };
		for (system_pages) |sys_page| {
			if (sys_page >= total_pages) continue;
			file.seekTo(sys_page * 4096) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_seek, "system page");
			};
			bytes_read = file.readAll(&page_buf) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_read, "system page");
			};
			if (bytes_read < 4096) {
				return ValidationResult.invalidCode(.qbw, .truncated, "system page");
			}
			const stored = std.mem.readInt(u32, page_buf[4092..4096], .little);
			const computed = std.hash.Crc32.hash(page_buf[0..4092]);
			if (stored != computed) {
				return ValidationResult.invalidCode(.qbw, .checksum_mismatch, "SQL Anywhere system page CRC-32");
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

		// Footer structure validation on all data pages.
		// Every page has a 16-byte cleartext footer at [4080:4096] with:
		//   [4081]: flag byte, always 0 or 1
		//   [4082:4084]: page type (u16 LE), valid set: {0,1,5,8,9,37,40,41,45}
		//   [4088:4092]: reserved, always 0x00000000
		// Page 0's footer area overlaps copyright text, so skip it.
		const valid_page_types = [_]u16{ 0, 1, 5, 8, 9, 37, 40, 41, 45 };
		file.seekTo(4096) catch {
			return ValidationResult.invalidCode(.qbw, .failed_to_seek, "footer validation");
		};
		for (1..total_pages) |_| {
			bytes_read = file.readAll(&page_buf) catch {
				return ValidationResult.invalidCode(.qbw, .failed_to_read, "footer validation");
			};
			if (bytes_read < 4096) {
				return ValidationResult.invalidCode(.qbw, .truncated, "footer validation");
			}
			// Flag byte at 4081 must be 0 or 1
			if (page_buf[4081] > 1) {
				return ValidationResult.invalidCode(.qbw, .invalid_value, "SQL Anywhere page footer flag byte");
			}
			// Page type at 4082 must be in valid set
			const page_type = std.mem.readInt(u16, page_buf[4082..4084], .little);
			var type_valid = false;
			for (valid_page_types) |vt| {
				if (page_type == vt) {
					type_valid = true;
					break;
				}
			}
			if (!type_valid) {
				return ValidationResult.invalidCode(.qbw, .invalid_value, "SQL Anywhere page type");
			}
			// Reserved field at 4088 must be zero
			if (std.mem.readInt(u32, page_buf[4088..4092], .little) != 0) {
				return ValidationResult.invalidCode(.qbw, .invalid_value, "SQL Anywhere page footer reserved field");
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
// NACHA/ACH Validators
// ============================================================================

/// Validates a NACHA/ACH file (.ach, .nacha).
/// NACHA files are fixed 94-character ASCII records with strict record type sequencing:
/// File Header (1) → Batch Header (5) → Entry Detail (6) / Addenda (7) → Batch Control (8) → File Control (9)
pub fn validateNacha(file: std.fs.File) ValidationResult {
	var header: [512]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.nacha, .failed_to_seek, "NACHA header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.nacha, .failed_to_read, "NACHA header");
	};
	if (bytes_read < 94) {
		return ValidationResult.invalidCode(.nacha, .file_too_small, "NACHA file (minimum 94 bytes for one record)");
	}

	const data = header[0..bytes_read];

	// Record type 1 = File Header
	if (data[0] != '1') {
		return ValidationResult.invalidCode(.nacha, .invalid_signature, "NACHA file (first record must be type 1 File Header)");
	}

	// Positions 35-38 should be "094" or spaces (format code / immediate destination routing)
	// Priority code at positions 1-2 should be "01"
	if (data[1] != '0' or data[2] != '1') {
		return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Header priority code (expected '01')");
	}

	// Check that the first record is 94 chars of printable ASCII (before any line ending)
	var line_len: usize = 0;
	while (line_len < data.len and data[line_len] != '\r' and data[line_len] != '\n') : (line_len += 1) {}

	if (line_len != 94) {
		return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA record length (expected exactly 94 characters)");
	}

	// Verify all characters in the first record are printable ASCII (0x20-0x7E)
	for (data[0..94]) |c| {
		if (c < 0x20 or c > 0x7E) {
			return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA file contains non-printable ASCII characters");
		}
	}

	return ValidationResult.okWithDepth(.nacha, .structural);
}

/// Deep validation of NACHA/ACH files: verifies entry hash, counts, and totals at batch and file level.
/// Per batch: entry hash = sum of 8-digit routing numbers from type 6 records mod 10^10.
/// Batch/file entry+addenda counts, debit/credit totals, block count verification.
pub fn validateNachaDeep(allocator: Allocator, path: []const u8) ValidationResult {
	const file_data = std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024) catch {
		return ValidationResult.invalidCode(.nacha, .failed_to_read, "NACHA file");
	};
	defer allocator.free(file_data);

	if (file_data.len < 94) {
		return ValidationResult.invalidCode(.nacha, .file_too_small, "NACHA file");
	}

	// Split into lines (handling CRLF, LF, or fixed-width 94-char records)
	var lines = std.ArrayListUnmanaged([]const u8){};
	defer lines.deinit(allocator);
	{
		var pos: usize = 0;
		while (pos < file_data.len) {
			var end = pos;
			while (end < file_data.len and file_data[end] != '\r' and file_data[end] != '\n') : (end += 1) {}
			if (end > pos) {
				lines.append(allocator, file_data[pos..end]) catch {
					return ValidationResult.invalidCode(.nacha, .failed_to_read, "NACHA line allocation");
				};
			}
			if (end < file_data.len and file_data[end] == '\r') end += 1;
			if (end < file_data.len and file_data[end] == '\n') end += 1;
			if (end == pos) break; // safety
			pos = end;
		}
	}

	if (lines.items.len == 0) {
		return ValidationResult.invalidCode(.nacha, .file_too_small, "NACHA file (no records)");
	}

	// Verify first record is File Header (type 1)
	if (lines.items[0].len < 94 or lines.items[0][0] != '1') {
		return ValidationResult.invalidCode(.nacha, .invalid_signature, "NACHA file (first record must be type 1)");
	}

	// Track batch-level and file-level totals
	var file_batch_count: u64 = 0;
	var file_entry_addenda_count: u64 = 0;
	var file_entry_hash: u64 = 0;
	var file_total_debit: u64 = 0;
	var file_total_credit: u64 = 0;

	// Current batch accumulators
	var batch_entry_hash: u64 = 0;
	var batch_entry_addenda_count: u64 = 0;
	var batch_total_debit: u64 = 0;
	var batch_total_credit: u64 = 0;
	var in_batch = false;

	var record_count: u64 = 0;
	var found_file_control = false;

	for (lines.items) |line| {
		if (line.len < 1) continue;
		record_count += 1;

		switch (line[0]) {
			'1' => {
				// File Header — already validated structurally
			},
			'5' => {
				// Batch Header — start new batch
				if (line.len < 94) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Header record too short");
				}
				in_batch = true;
				batch_entry_hash = 0;
				batch_entry_addenda_count = 0;
				batch_total_debit = 0;
				batch_total_credit = 0;
			},
			'6' => {
				// Entry Detail
				if (line.len < 94) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Entry Detail record too short");
				}
				if (!in_batch) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Entry Detail outside of batch");
				}
				batch_entry_addenda_count += 1;

				// Routing number: positions 3-11 (0-indexed: 3..11), take first 8 digits
				const routing = parseNachaNumber(line[3..11]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Entry Detail invalid routing number");
				};
				batch_entry_hash += routing;

				// Transaction code at positions 1-2 determines debit vs credit
				const txn_code = parseNachaNumber(line[1..3]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Entry Detail invalid transaction code");
				};
				// Amount at positions 29-39 (0-indexed)
				const amount = parseNachaNumber(line[29..39]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Entry Detail invalid amount");
				};
				// Debit codes: 27, 28, 37, 38; Credit codes: 22, 23, 32, 33
				if (txn_code == 27 or txn_code == 28 or txn_code == 37 or txn_code == 38) {
					batch_total_debit += amount;
				} else {
					batch_total_credit += amount;
				}
			},
			'7' => {
				// Addenda Record
				if (line.len < 94) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Addenda record too short");
				}
				if (!in_batch) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Addenda outside of batch");
				}
				batch_entry_addenda_count += 1;
			},
			'8' => {
				// Batch Control
				if (line.len < 94) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control record too short");
				}
				if (!in_batch) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control without matching Batch Header");
				}

				// Verify batch entry/addenda count (positions 4-9)
				const expected_count = parseNachaNumber(line[4..10]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control invalid entry/addenda count");
				};
				if (expected_count != batch_entry_addenda_count) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control entry/addenda count mismatch");
				}

				// Verify entry hash (positions 10-19), mod 10^10
				const expected_hash = parseNachaNumber(line[10..20]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control invalid entry hash");
				};
				const actual_hash = batch_entry_hash % 10_000_000_000;
				if (expected_hash != actual_hash) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control entry hash mismatch");
				}

				// Verify debit total (positions 20-31)
				const expected_debit = parseNachaNumber(line[20..32]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control invalid debit total");
				};
				if (expected_debit != batch_total_debit) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control debit total mismatch");
				}

				// Verify credit total (positions 32-43)
				const expected_credit = parseNachaNumber(line[32..44]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control invalid credit total");
				};
				if (expected_credit != batch_total_credit) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA Batch Control credit total mismatch");
				}

				// Accumulate into file-level totals
				file_batch_count += 1;
				file_entry_addenda_count += batch_entry_addenda_count;
				file_entry_hash += batch_entry_hash;
				file_total_debit += batch_total_debit;
				file_total_credit += batch_total_credit;
				in_batch = false;
			},
			'9' => {
				// File Control
				if (line.len < 94) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control record too short");
				}
				found_file_control = true;

				// Verify batch count (positions 1-6)
				const expected_batches = parseNachaNumber(line[1..7]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid batch count");
				};
				if (expected_batches != file_batch_count) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control batch count mismatch");
				}

				// Verify block count (positions 7-12)
				const expected_blocks = parseNachaNumber(line[7..13]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid block count");
				};
				// Block count = total records (including padding 9s) / 10, rounded up
				const total_records_for_blocking = ((record_count + 9) / 10) * 10;
				const actual_blocks = total_records_for_blocking / 10;
				if (expected_blocks != actual_blocks) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control block count mismatch");
				}

				// Verify entry/addenda count (positions 13-20)
				const expected_ea_count = parseNachaNumber(line[13..21]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid entry/addenda count");
				};
				if (expected_ea_count != file_entry_addenda_count) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control entry/addenda count mismatch");
				}

				// Verify entry hash (positions 21-30), mod 10^10
				const expected_file_hash = parseNachaNumber(line[21..31]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid entry hash");
				};
				const actual_file_hash = file_entry_hash % 10_000_000_000;
				if (expected_file_hash != actual_file_hash) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control entry hash mismatch");
				}

				// Verify debit total (positions 31-42)
				const expected_file_debit = parseNachaNumber(line[31..43]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid debit total");
				};
				if (expected_file_debit != file_total_debit) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control debit total mismatch");
				}

				// Verify credit total (positions 43-54)
				const expected_file_credit = parseNachaNumber(line[43..55]) orelse {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control invalid credit total");
				};
				if (expected_file_credit != file_total_credit) {
					return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA File Control credit total mismatch");
				}

				break; // File Control found, stop (remaining 9s are padding)
			},
			else => {
				return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA file contains invalid record type");
			},
		}
	}

	if (!found_file_control) {
		return ValidationResult.invalidCode(.nacha, .invalid_value, "NACHA file missing File Control record (type 9)");
	}

	return ValidationResult.okWithDepth(.nacha, .full);
}

/// Parse a numeric field from a NACHA record (ASCII digits, possibly with leading spaces/zeros).
fn parseNachaNumber(field: []const u8) ?u64 {
	var result: u64 = 0;
	for (field) |c| {
		if (c == ' ') continue; // Leading spaces treated as zero
		if (c < '0' or c > '9') return null;
		result = result *% 10 +% (c - '0');
	}
	return result;
}

// ============================================================================
// MT940 SWIFT Validators
// ============================================================================

/// Validates an MT940 SWIFT bank statement (.mt940, .sta, .940).
/// MT940 messages use tagged fields (:XX:) and may optionally have a SWIFT envelope ({1:F01...}).
pub fn validateMt940(file: std.fs.File) ValidationResult {
	var header: [2048]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.mt940, .failed_to_seek, "MT940 header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.mt940, .failed_to_read, "MT940 header");
	};
	if (bytes_read < 10) {
		return ValidationResult.invalidCode(.mt940, .file_too_small, "MT940 file");
	}

	const data = header[0..bytes_read];

	// Skip BOM
	var start: usize = 0;
	if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		start = 3;
	}

	// Skip leading whitespace
	while (start < data.len and (data[start] == ' ' or data[start] == '\t' or
		data[start] == '\n' or data[start] == '\r')) : (start += 1)
	{}

	if (start >= data.len) {
		return ValidationResult.invalidCode(.mt940, .invalid_signature, "MT940 file (empty content)");
	}

	const trimmed = data[start..];

	// Check for SWIFT envelope: {1:F01...}
	if (trimmed.len >= 6 and std.mem.startsWith(u8, trimmed, "{1:F01")) {
		// Enveloped MT940 — look for mandatory :20: tag somewhere in the data
		if (std.mem.indexOf(u8, trimmed, ":20:") != null) {
			return ValidationResult.okWithDepth(.mt940, .structural);
		}
		// Envelope present but no :20: tag — could be another SWIFT message type
		return ValidationResult.invalidCode(.mt940, .invalid_value, "MT940 SWIFT envelope found but missing :20: transaction reference");
	}

	// Check for bare MT940: starts with :20: (transaction reference)
	if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, ":20:")) {
		return ValidationResult.okWithDepth(.mt940, .structural);
	}

	// Also check if the file contains SWIFT block markers and MT940-specific tags
	if (std.mem.indexOf(u8, trimmed, "{4:") != null and std.mem.indexOf(u8, trimmed, ":20:") != null) {
		return ValidationResult.okWithDepth(.mt940, .structural);
	}

	return ValidationResult.invalidCode(.mt940, .invalid_signature, "MT940 file (expected SWIFT envelope {1:F01 or bare :20: tag)");
}

/// Deep validation of MT940: verifies balance arithmetic (opening + transactions = closing)
/// and currency consistency across balance tags.
pub fn validateMt940Deep(allocator: Allocator, path: []const u8) ValidationResult {
	const file_data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch {
		return ValidationResult.invalidCode(.mt940, .failed_to_read, "MT940 file");
	};
	defer allocator.free(file_data);

	if (file_data.len < 10) {
		return ValidationResult.invalidCode(.mt940, .file_too_small, "MT940 file");
	}

	// Find the message body — skip SWIFT envelope if present
	var body = file_data;
	if (std.mem.indexOf(u8, file_data, "{4:")) |block4_start| {
		body = file_data[block4_start + 3 ..];
	}

	// Parse opening balance (:60F: or :60M:)
	const opening = parseMt940Balance(body, ":60F:") orelse
		parseMt940Balance(body, ":60M:") orelse {
		return ValidationResult.invalidCode(.mt940, .invalid_value, "MT940 missing opening balance (:60F: or :60M:)");
	};

	// Parse closing balance (:62F: or :62M:)
	const closing = parseMt940Balance(body, ":62F:") orelse
		parseMt940Balance(body, ":62M:") orelse {
		return ValidationResult.invalidCode(.mt940, .invalid_value, "MT940 missing closing balance (:62F: or :62M:)");
	};

	// Currency consistency
	if (!std.mem.eql(u8, &opening.currency, &closing.currency)) {
		return ValidationResult.invalidCode(.mt940, .invalid_value, "MT940 opening/closing balance currency mismatch");
	}

	// Sum all :61: statement line transactions
	var transaction_sum: i64 = 0;
	var search_pos: usize = 0;
	var transaction_count: u32 = 0;
	while (std.mem.indexOf(u8, body[search_pos..], ":61:")) |offset| {
		const tag_start = search_pos + offset + 4;
		if (tag_start >= body.len) break;

		// Find end of this field (next tag or end of data)
		var field_end = tag_start;
		while (field_end < body.len) : (field_end += 1) {
			if (field_end + 1 < body.len and body[field_end] == ':' and
				field_end + 3 < body.len and body[field_end + 2] >= '0' and body[field_end + 2] <= '9')
			{
				// Looks like a new :XX: tag — but verify it's a real tag pattern
				if (body[field_end + 1] >= '0' and body[field_end + 1] <= '9') {
					// Check for : after digits
					var tag_check = field_end + 1;
					while (tag_check < body.len and body[tag_check] >= '0' and body[tag_check] <= '9') : (tag_check += 1) {}
					if (tag_check < body.len and (body[tag_check] == ':' or body[tag_check] == 'a' or
						body[tag_check] == 'F' or body[tag_check] == 'M'))
					{
						break;
					}
				}
			}
			// Also break on CRLF followed by : (new tag on new line)
			if (field_end + 2 < body.len and body[field_end] == '\r' and body[field_end + 1] == '\n' and body[field_end + 2] == ':') {
				break;
			}
			if (field_end + 1 < body.len and body[field_end] == '\n' and body[field_end + 1] == ':') {
				break;
			}
		}

		const field = body[tag_start..field_end];
		if (parseMt940Transaction(field)) |amount| {
			transaction_sum += amount;
			transaction_count += 1;
		}

		search_pos = field_end;
	}

	// Verify balance arithmetic: opening + transactions = closing
	// Amounts are in cents (integer arithmetic to avoid floating point)
	const expected_closing = opening.amount + transaction_sum;
	if (expected_closing != closing.amount) {
		// Some banks omit transactions — warn but don't fail if no transactions found
		if (transaction_count == 0) {
			return ValidationResult.okWithDepthAndWarning(.mt940, .structural,
				"MT940 balance arithmetic cannot be verified (no :61: transactions found)");
		}
		return ValidationResult.invalidCode(.mt940, .invalid_value, "MT940 balance arithmetic mismatch (opening + transactions != closing)");
	}

	return ValidationResult.okWithDepth(.mt940, .full);
}

const Mt940Balance = struct {
	amount: i64, // In cents (or smallest currency unit), signed
	currency: [3]u8,
};

/// Parse an MT940 balance tag (:60F:, :60M:, :62F:, :62M:).
/// Format: D/CYYMMDDCURRXXXXXXX,XX (D/C = debit/credit indicator, date, currency, amount)
fn parseMt940Balance(data: []const u8, tag: []const u8) ?Mt940Balance {
	const tag_pos = std.mem.indexOf(u8, data, tag) orelse return null;
	const field_start = tag_pos + tag.len;

	// Skip any leading whitespace/newlines
	var pos = field_start;
	while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n' or data[pos] == ' ')) : (pos += 1) {}

	if (pos + 14 > data.len) return null; // Minimum: D/C + 6 date + 3 currency + amount

	// D/C indicator
	const sign: i64 = if (data[pos] == 'D') -1 else if (data[pos] == 'C') 1 else return null;
	pos += 1;

	// Date: YYMMDD (6 digits)
	for (data[pos..][0..6]) |c| {
		if (c < '0' or c > '9') return null;
	}
	pos += 6;

	// Currency: 3 alpha chars
	var currency: [3]u8 = undefined;
	for (0..3) |i| {
		if (pos + i >= data.len) return null;
		const c = data[pos + i];
		if ((c < 'A' or c > 'Z') and (c < 'a' or c > 'z')) return null;
		currency[i] = if (c >= 'a') c - 32 else c; // Uppercase
	}
	pos += 3;

	// Amount: digits with optional comma decimal separator
	const amount = parseMt940Amount(data[pos..]) orelse return null;

	return Mt940Balance{
		.amount = sign * amount,
		.currency = currency,
	};
}

/// Parse an MT940 amount field (digits with comma as decimal separator).
/// Returns amount in cents (smallest unit, 2 decimal places).
fn parseMt940Amount(data: []const u8) ?i64 {
	var integer_part: i64 = 0;
	var decimal_part: i64 = 0;
	var decimal_digits: u8 = 0;
	var in_decimal = false;
	var found_digit = false;

	for (data) |c| {
		if (c == ',') {
			if (in_decimal) break; // Second comma = end
			in_decimal = true;
			continue;
		}
		if (c < '0' or c > '9') break;
		found_digit = true;
		if (in_decimal) {
			if (decimal_digits < 2) {
				decimal_part = decimal_part * 10 + (c - '0');
				decimal_digits += 1;
			}
			// Ignore digits beyond 2 decimal places
		} else {
			integer_part = integer_part * 10 + (c - '0');
		}
	}

	if (!found_digit) return null;

	// Pad decimal to 2 places
	while (decimal_digits < 2) : (decimal_digits += 1) {
		decimal_part *= 10;
	}

	return integer_part * 100 + decimal_part;
}

/// Parse an MT940 :61: transaction line amount.
/// Format: YYMMDD[MMDD]D/CXXXXXXXXX,XX... (date, optional value date, D/C, amount, rest)
fn parseMt940Transaction(field: []const u8) ?i64 {
	var pos: usize = 0;

	// Skip leading whitespace
	while (pos < field.len and (field[pos] == '\r' or field[pos] == '\n' or field[pos] == ' ')) : (pos += 1) {}

	// Value date: YYMMDD (6 digits)
	if (pos + 6 > field.len) return null;
	for (field[pos..][0..6]) |c| {
		if (c < '0' or c > '9') return null;
	}
	pos += 6;

	// Optional entry date: MMDD (4 digits)
	if (pos + 4 <= field.len and field[pos] >= '0' and field[pos] <= '1') {
		var all_digits = true;
		for (field[pos..][0..4]) |c| {
			if (c < '0' or c > '9') {
				all_digits = false;
				break;
			}
		}
		if (all_digits) pos += 4;
	}

	// D/C indicator (possibly with R for reversal: RD, RC)
	if (pos >= field.len) return null;
	var sign: i64 = 1;
	if (field[pos] == 'R') {
		pos += 1; // Reversal prefix
		if (pos >= field.len) return null;
	}
	if (field[pos] == 'D') {
		sign = -1;
		pos += 1;
	} else if (field[pos] == 'C') {
		sign = 1;
		pos += 1;
	} else {
		return null;
	}

	// Optional third character of the funds code
	if (pos < field.len and field[pos] >= 'A' and field[pos] <= 'Z' and field[pos] != 'N') {
		// Skip funds code letter (but not 'N' which starts the reference)
		pos += 1;
	}

	// Amount: digits with comma
	const amount = parseMt940Amount(field[pos..]) orelse return null;
	return sign * amount;
}

// ============================================================================
// BAI2 Validators
// ============================================================================

/// Validates a BAI2 file (.bai, .bai2).
/// BAI2 files are comma-separated with '/' record terminators and hierarchical structure:
/// File Header (01) → Group Header (02) → Account (03) → Transactions (16/88) → Account Trailer (49) → Group Trailer (98) → File Trailer (99)
pub fn validateBai2(file: std.fs.File) ValidationResult {
	var header: [512]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.bai2, .failed_to_seek, "BAI2 header");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.bai2, .failed_to_read, "BAI2 header");
	};
	if (bytes_read < 10) {
		return ValidationResult.invalidCode(.bai2, .file_too_small, "BAI2 file");
	}

	const data = header[0..bytes_read];

	// Skip BOM
	var start: usize = 0;
	if (bytes_read >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		start = 3;
	}

	// Skip leading whitespace
	while (start < data.len and (data[start] == ' ' or data[start] == '\t' or
		data[start] == '\n' or data[start] == '\r')) : (start += 1)
	{}

	if (start + 3 >= data.len) {
		return ValidationResult.invalidCode(.bai2, .invalid_signature, "BAI2 file too short");
	}

	const trimmed = data[start..];

	// BAI2 File Header starts with "01,"
	if (!std.mem.startsWith(u8, trimmed, "01,")) {
		return ValidationResult.invalidCode(.bai2, .invalid_signature, "BAI2 file (first record must start with '01,')");
	}

	// Check for record terminator '/' somewhere in the header
	if (std.mem.indexOf(u8, trimmed, "/") == null) {
		return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 file missing '/' record terminator");
	}

	// Verify version field is "2" — parse fields from the 01 record
	// Format: 01,SENDER_ID,RECEIVER_ID,FILE_CREATION_DATE,FILE_CREATION_TIME,FILE_ID,PHYSICAL_RECORD_LENGTH,BLOCK_SIZE,VERSION_NUMBER/
	const fields = parseBai2RecordFields(trimmed) orelse {
		return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 File Header cannot be parsed");
	};
	// Version number is the last field before /
	if (fields.count >= 9) {
		const version = fields.get(8);
		if (version.len > 0 and !std.mem.eql(u8, version, "2")) {
			return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 version number (expected '2')");
		}
	}

	return ValidationResult.okWithDepth(.bai2, .structural);
}

const Bai2Fields = struct {
	starts: [32]usize = [_]usize{0} ** 32,
	ends: [32]usize = [_]usize{0} ** 32,
	count: usize = 0,
	data: []const u8,

	fn get(self: *const Bai2Fields, idx: usize) []const u8 {
		if (idx >= self.count) return "";
		return self.data[self.starts[idx]..self.ends[idx]];
	}
};

/// Parse a BAI2 record line into comma-separated fields (up to the '/' terminator).
fn parseBai2RecordFields(line: []const u8) ?Bai2Fields {
	var fields = Bai2Fields{ .data = line };
	var pos: usize = 0;
	var field_start: usize = 0;

	while (pos < line.len) : (pos += 1) {
		if (line[pos] == '/' or line[pos] == '\r' or line[pos] == '\n') {
			if (fields.count < 32) {
				fields.starts[fields.count] = field_start;
				fields.ends[fields.count] = pos;
				fields.count += 1;
			}
			break;
		}
		if (line[pos] == ',') {
			if (fields.count < 32) {
				fields.starts[fields.count] = field_start;
				fields.ends[fields.count] = pos;
				fields.count += 1;
			}
			field_start = pos + 1;
		}
	}

	if (fields.count == 0) return null;
	return fields;
}

/// Parse a signed BAI2 amount field. BAI2 amounts may have optional +/- prefix.
fn parseBai2Amount(field: []const u8) ?i64 {
	if (field.len == 0) return null;
	var pos: usize = 0;
	var sign: i64 = 1;

	// Skip whitespace
	while (pos < field.len and (field[pos] == ' ' or field[pos] == '\t')) : (pos += 1) {}
	if (pos >= field.len) return null;

	if (field[pos] == '-') {
		sign = -1;
		pos += 1;
	} else if (field[pos] == '+') {
		pos += 1;
	}

	var result: i64 = 0;
	var found_digit = false;
	while (pos < field.len) : (pos += 1) {
		if (field[pos] < '0' or field[pos] > '9') break;
		found_digit = true;
		result = result *% 10 +% (field[pos] - '0');
	}

	if (!found_digit) return null;
	return sign * result;
}

/// Deep validation of BAI2 files: verifies cascading control totals at account, group, and file levels.
/// Account trailer (49) = sum of transaction amounts; Group trailer (98) = sum of account totals;
/// File trailer (99) = sum of group totals. Record counts verified at all three levels.
pub fn validateBai2Deep(allocator: Allocator, path: []const u8) ValidationResult {
	const file_data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024) catch {
		return ValidationResult.invalidCode(.bai2, .failed_to_read, "BAI2 file");
	};
	defer allocator.free(file_data);

	if (file_data.len < 10) {
		return ValidationResult.invalidCode(.bai2, .file_too_small, "BAI2 file");
	}

	// Collect logical records (handling continuation with 88 records)
	var lines = std.ArrayListUnmanaged([]const u8){};
	defer lines.deinit(allocator);
	{
		var pos: usize = 0;
		while (pos < file_data.len) {
			// Skip whitespace/newlines between records
			while (pos < file_data.len and (file_data[pos] == '\r' or file_data[pos] == '\n' or file_data[pos] == ' ')) : (pos += 1) {}
			if (pos >= file_data.len) break;

			// Find end of record (terminated by / or newline)
			var end = pos;
			while (end < file_data.len and file_data[end] != '\n') : (end += 1) {
				if (file_data[end] == '/') {
					end += 1; // Include the /
					break;
				}
			}
			if (end > pos) {
				lines.append(allocator, file_data[pos..end]) catch {
					return ValidationResult.invalidCode(.bai2, .failed_to_read, "BAI2 line allocation");
				};
			}
			// Skip past newlines
			while (end < file_data.len and (file_data[end] == '\r' or file_data[end] == '\n')) : (end += 1) {}
			if (end == pos) break;
			pos = end;
		}
	}

	if (lines.items.len == 0) {
		return ValidationResult.invalidCode(.bai2, .file_too_small, "BAI2 file (no records)");
	}

	// File-level accumulators
	var file_group_count: i64 = 0;
	var file_record_count: i64 = 0;
	var file_control_total: i64 = 0;

	// Group-level accumulators
	var group_account_count: i64 = 0;
	var group_record_count: i64 = 0;
	var group_control_total: i64 = 0;
	var in_group = false;

	// Account-level accumulators
	var account_record_count: i64 = 0;
	var account_control_total: i64 = 0;
	var in_account = false;

	var found_file_trailer = false;

	for (lines.items) |line| {
		if (line.len < 2) continue;

		const fields = parseBai2RecordFields(line) orelse continue;
		const rec_type = fields.get(0);
		file_record_count += 1;

		if (std.mem.eql(u8, rec_type, "01")) {
			// File Header — already structurally validated
		} else if (std.mem.eql(u8, rec_type, "02")) {
			// Group Header
			in_group = true;
			group_account_count = 0;
			group_record_count = 1; // Count the group header itself
			group_control_total = 0;
		} else if (std.mem.eql(u8, rec_type, "03")) {
			// Account Identifier
			if (!in_group) {
				return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Account (03) outside of group");
			}
			in_account = true;
			account_record_count = 1; // Count the account header itself
			account_control_total = 0;
			group_record_count += 1;

			// Account summary may contain amounts in fields 4+ (status/type/amount triples)
			var fi: usize = 4;
			while (fi + 2 < fields.count) : (fi += 3) {
				const amt_str = fields.get(fi + 1);
				if (amt_str.len > 0) {
					if (parseBai2Amount(amt_str)) |amt| {
						_ = amt; // Summary amounts don't count toward control total
					}
				}
			}
		} else if (std.mem.eql(u8, rec_type, "16")) {
			// Transaction Detail
			if (!in_account) {
				return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Transaction (16) outside of account");
			}
			account_record_count += 1;
			group_record_count += 1;

			// Amount is field index 2
			if (fields.count >= 3) {
				const amt_str = fields.get(2);
				if (amt_str.len > 0) {
					if (parseBai2Amount(amt_str)) |amt| {
						account_control_total += amt;
					}
				}
			}
		} else if (std.mem.eql(u8, rec_type, "88")) {
			// Continuation Record — counts toward the current level
			if (in_account) {
				account_record_count += 1;
			}
			if (in_group) {
				group_record_count += 1;
			}
		} else if (std.mem.eql(u8, rec_type, "49")) {
			// Account Trailer
			if (!in_account) {
				return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Account Trailer (49) without matching Account (03)");
			}
			account_record_count += 1;
			group_record_count += 1;

			// Verify account control total (field 1)
			if (fields.count >= 2) {
				const expected_total = parseBai2Amount(fields.get(1));
				if (expected_total) |expected| {
					if (expected != account_control_total) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Account Trailer (49) control total mismatch");
					}
				}
			}

			// Verify account record count (field 2)
			if (fields.count >= 3) {
				const expected_count = parseBai2Amount(fields.get(2));
				if (expected_count) |expected| {
					if (expected != account_record_count) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Account Trailer (49) record count mismatch");
					}
				}
			}

			group_control_total += account_control_total;
			group_account_count += 1;
			in_account = false;
		} else if (std.mem.eql(u8, rec_type, "98")) {
			// Group Trailer
			if (!in_group) {
				return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Group Trailer (98) without matching Group Header (02)");
			}
			group_record_count += 1;

			// Verify group control total (field 1)
			if (fields.count >= 2) {
				const expected_total = parseBai2Amount(fields.get(1));
				if (expected_total) |expected| {
					if (expected != group_control_total) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Group Trailer (98) control total mismatch");
					}
				}
			}

			// Verify number of accounts (field 2)
			if (fields.count >= 3) {
				const expected_accounts = parseBai2Amount(fields.get(2));
				if (expected_accounts) |expected| {
					if (expected != group_account_count) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Group Trailer (98) account count mismatch");
					}
				}
			}

			// Verify group record count (field 3)
			if (fields.count >= 4) {
				const expected_records = parseBai2Amount(fields.get(3));
				if (expected_records) |expected| {
					if (expected != group_record_count) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 Group Trailer (98) record count mismatch");
					}
				}
			}

			file_control_total += group_control_total;
			file_group_count += 1;
			in_group = false;
		} else if (std.mem.eql(u8, rec_type, "99")) {
			// File Trailer
			found_file_trailer = true;

			// Verify file control total (field 1)
			if (fields.count >= 2) {
				const expected_total = parseBai2Amount(fields.get(1));
				if (expected_total) |expected| {
					if (expected != file_control_total) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 File Trailer (99) control total mismatch");
					}
				}
			}

			// Verify number of groups (field 2)
			if (fields.count >= 3) {
				const expected_groups = parseBai2Amount(fields.get(2));
				if (expected_groups) |expected| {
					if (expected != file_group_count) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 File Trailer (99) group count mismatch");
					}
				}
			}

			// Verify file record count (field 3)
			if (fields.count >= 4) {
				const expected_records = parseBai2Amount(fields.get(3));
				if (expected_records) |expected| {
					if (expected != file_record_count) {
						return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 File Trailer (99) record count mismatch");
					}
				}
			}

			break;
		}
	}

	if (!found_file_trailer) {
		return ValidationResult.invalidCode(.bai2, .invalid_value, "BAI2 file missing File Trailer (99)");
	}

	return ValidationResult.okWithDepth(.bai2, .full);
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

// ============================================================================
// NACHA/ACH Tests
// ============================================================================

/// Helper to build a 94-char NACHA record padded with spaces.
fn buildNachaRecord(content: []const u8) [94]u8 {
	var record: [94]u8 = [_]u8{' '} ** 94;
	const len = @min(content.len, 94);
	@memcpy(record[0..len], content[0..len]);
	return record;
}

test "NACHA structural: valid file header" {
	// File Header: type 1, priority 01, rest padded
	const rec = buildNachaRecord("101 021000021 1234567890240115073 A094101First National Bank    Acme Corporation       ");

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.ach", .{});
	try file.writeAll(&rec);
	try file.writeAll("\n");
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.ach", .{});
	defer read_file.close();

	const result = validateNacha(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.nacha, result.format);
}

test "NACHA structural: invalid record type" {
	// First char is '2' instead of '1'
	const rec = buildNachaRecord("201 021000021 1234567890240115073 A094101First National Bank    Acme Corporation       ");

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("bad.ach", .{});
	try file.writeAll(&rec);
	try file.writeAll("\n");
	file.close();

	const read_file = try tmp_dir.dir.openFile("bad.ach", .{});
	defer read_file.close();

	const result = validateNacha(read_file);
	try std.testing.expect(!result.is_valid);
}

test "NACHA structural: invalid priority code" {
	const rec = buildNachaRecord("199 021000021 1234567890240115073 A094101First National Bank    Acme Corporation       ");

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("bad_priority.ach", .{});
	try file.writeAll(&rec);
	try file.writeAll("\n");
	file.close();

	const read_file = try tmp_dir.dir.openFile("bad_priority.ach", .{});
	defer read_file.close();

	const result = validateNacha(read_file);
	try std.testing.expect(!result.is_valid);
}

test "NACHA structural: file too small" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("tiny.ach", .{});
	try file.writeAll("101 short");
	file.close();

	const read_file = try tmp_dir.dir.openFile("tiny.ach", .{});
	defer read_file.close();

	const result = validateNacha(read_file);
	try std.testing.expect(!result.is_valid);
}

test "NACHA deep: valid file with correct integrity" {
	// Build a valid NACHA file with exact field-aligned records.
	// Batch: 2 credit entries (txn code 22), routing 02100002
	//   Entry 1: amount $500.00 = 50000; Entry 2: amount $300.00 = 30000
	//   Entry hash: 2100002 + 2100002 = 4200004
	//   Entry/addenda count: 2, Total debit: 0, Total credit: 80000
	// File: 1 batch, 1 block (10 records), 2 ea_count, hash 4200004

	// Each record is built with explicit field boundaries (NACHA spec, 0-indexed)
	// File Header (type 1): 1+2+10+10+6+4+1+3+2+1+23+23+8 = 94
	const fh = "1" ++ "01" ++ " 021000021" ++ "1234567890" ++ "240115" ++ "0730" ++ "A" ++ "094" ++ "10" ++ "1" ++ "First National Bank    " ++ "Acme Corporation       " ++ "        ";
	// Batch Header (type 5): 1+3+16+20+10+3+10+6+6+3+1+8+7 = 94
	const bh = "5" ++ "200" ++ "Acme Corporation" ++ "                    " ++ "1234567890" ++ "PPD" ++ "Payroll   " ++ "240115" ++ "240115" ++ "   " ++ "1" ++ "02100002" ++ "0000001";
	// Entry Detail (type 6): 1+2+8+1+17+10+15+22+2+1+15 = 94
	const e1 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234567         " ++ "0000050000" ++ "REF00000000001 " ++ "John Doe              " ++ "  " ++ "0" ++ "021000020000001";
	const e2 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234568         " ++ "0000030000" ++ "REF00000000002 " ++ "Jane Smith            " ++ "  " ++ "0" ++ "021000020000002";
	// Batch Control (type 8): 1+3+6+10+12+12+10+19+6+8+7 = 94
	const bc = "8" ++ "200" ++ "000002" ++ "0004200004" ++ "000000000000" ++ "000000080000" ++ "1234567890" ++ "                   " ++ "      " ++ "02100002" ++ "0000001";
	// File Control (type 9): 1+6+6+8+10+12+12+39 = 94
	const fc = "9" ++ "000001" ++ "000001" ++ "00000002" ++ "0004200004" ++ "000000000000" ++ "000000080000" ++ "                                       ";
	const pad = "9" ** 94;

	const file_data = fh ++ "\n" ++ bh ++ "\n" ++ e1 ++ "\n" ++ e2 ++ "\n" ++ bc ++ "\n" ++ fc ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("valid_deep.ach", .{});
	try file.writeAll(file_data);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("valid_deep.ach", &path_buf);

	const result = validateNachaDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "NACHA deep: corrupted entry hash detected" {
	const fh = "1" ++ "01" ++ " 021000021" ++ "1234567890" ++ "240115" ++ "0730" ++ "A" ++ "094" ++ "10" ++ "1" ++ "First National Bank    " ++ "Acme Corporation       " ++ "        ";
	const bh = "5" ++ "200" ++ "Acme Corporation" ++ "                    " ++ "1234567890" ++ "PPD" ++ "Payroll   " ++ "240115" ++ "240115" ++ "   " ++ "1" ++ "02100002" ++ "0000001";
	const e1 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234567         " ++ "0000050000" ++ "REF00000000001 " ++ "John Doe              " ++ "  " ++ "0" ++ "021000020000001";
	const e2 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234568         " ++ "0000030000" ++ "REF00000000002 " ++ "Jane Smith            " ++ "  " ++ "0" ++ "021000020000002";
	// WRONG entry hash: 0009999999 instead of 0004200004
	const bc = "8" ++ "200" ++ "000002" ++ "0009999999" ++ "000000000000" ++ "000000080000" ++ "1234567890" ++ "                   " ++ "      " ++ "02100002" ++ "0000001";
	const fc = "9" ++ "000001" ++ "000001" ++ "00000002" ++ "0004200004" ++ "000000000000" ++ "000000080000" ++ "                                       ";
	const pad = "9" ** 94;
	const file_data = fh ++ "\n" ++ bh ++ "\n" ++ e1 ++ "\n" ++ e2 ++ "\n" ++ bc ++ "\n" ++ fc ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_hash.ach", .{});
	try file.writeAll(file_data);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_hash.ach", &path_buf);

	const result = validateNachaDeep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "NACHA deep: corrupted credit total detected" {
	const fh = "1" ++ "01" ++ " 021000021" ++ "1234567890" ++ "240115" ++ "0730" ++ "A" ++ "094" ++ "10" ++ "1" ++ "First National Bank    " ++ "Acme Corporation       " ++ "        ";
	const bh = "5" ++ "200" ++ "Acme Corporation" ++ "                    " ++ "1234567890" ++ "PPD" ++ "Payroll   " ++ "240115" ++ "240115" ++ "   " ++ "1" ++ "02100002" ++ "0000001";
	const e1 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234567         " ++ "0000050000" ++ "REF00000000001 " ++ "John Doe              " ++ "  " ++ "0" ++ "021000020000001";
	const e2 = "6" ++ "22" ++ "02100002" ++ "1" ++ "01234568         " ++ "0000030000" ++ "REF00000000002 " ++ "Jane Smith            " ++ "  " ++ "0" ++ "021000020000002";
	// Correct hash but WRONG credit total: 000000099999 instead of 000000080000
	const bc = "8" ++ "200" ++ "000002" ++ "0004200004" ++ "000000000000" ++ "000000099999" ++ "1234567890" ++ "                   " ++ "      " ++ "02100002" ++ "0000001";
	const fc = "9" ++ "000001" ++ "000001" ++ "00000002" ++ "0004200004" ++ "000000000000" ++ "000000080000" ++ "                                       ";
	const pad = "9" ** 94;
	const file_data = fh ++ "\n" ++ bh ++ "\n" ++ e1 ++ "\n" ++ e2 ++ "\n" ++ bc ++ "\n" ++ fc ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_credit.ach", .{});
	try file.writeAll(file_data);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_credit.ach", &path_buf);

	const result = validateNachaDeep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "parseNachaNumber: basic parsing" {
	try std.testing.expectEqual(@as(?u64, 42000), parseNachaNumber("0042000"));
	try std.testing.expectEqual(@as(?u64, 0), parseNachaNumber("0000000"));
	try std.testing.expectEqual(@as(?u64, 0), parseNachaNumber("       "));
	try std.testing.expectEqual(@as(?u64, 123), parseNachaNumber("  123  "));
	try std.testing.expectEqual(@as(?u64, null), parseNachaNumber("abc"));
}

// ============================================================================
// MT940 SWIFT Tests
// ============================================================================

test "MT940 structural: SWIFT envelope" {
	const mt940 =
		"{1:F01BANKBEBB0AXXX0000000000}{2:O9401200240115BANKBEBB0AXXX00000000002401150000N}{4:\r\n" ++
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:C240101EUR1000,00\r\n" ++
		":61:2401150115C500,00NMSC//REF001\r\n" ++
		":62F:C240115EUR1500,00\r\n" ++
		"-}\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.mt940", .{});
	defer read_file.close();

	const result = validateMt940(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.mt940, result.format);
}

test "MT940 structural: bare format (starts with :20:)" {
	const mt940 =
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:C240101EUR1000,00\r\n" ++
		":62F:C240115EUR1500,00\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test_bare.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test_bare.mt940", .{});
	defer read_file.close();

	const result = validateMt940(read_file);
	try std.testing.expect(result.is_valid);
}

test "MT940 structural: invalid content" {
	const bad = "This is not an MT940 file\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("bad.mt940", .{});
	try file.writeAll(bad);
	file.close();

	const read_file = try tmp_dir.dir.openFile("bad.mt940", .{});
	defer read_file.close();

	const result = validateMt940(read_file);
	try std.testing.expect(!result.is_valid);
}

test "MT940 deep: valid balance arithmetic" {
	// Opening: C (credit) 240101 EUR 1000,00 = +100000 cents
	// Transaction 1: C 500,00 = +50000 cents
	// Transaction 2: D 200,50 = -20050 cents
	// Closing: C 240115 EUR 1299,50 = +129950 cents
	// Check: 100000 + 50000 - 20050 = 129950 ✓
	const mt940 =
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:C240101EUR1000,00\r\n" ++
		":61:2401050105C500,00NMSC//REF001\r\n" ++
		":61:2401100110D200,50NMSC//REF002\r\n" ++
		":62F:C240115EUR1299,50\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("valid_deep.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("valid_deep.mt940", &path_buf);

	const result = validateMt940Deep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "MT940 deep: balance arithmetic mismatch detected" {
	// Opening: C 1000,00 = +100000
	// Transaction: C 500,00 = +50000
	// Closing: C 2000,00 = +200000 (should be 1500,00)
	const mt940 =
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:C240101EUR1000,00\r\n" ++
		":61:2401050105C500,00NMSC//REF001\r\n" ++
		":62F:C240115EUR2000,00\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_balance.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_balance.mt940", &path_buf);

	const result = validateMt940Deep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "MT940 deep: currency mismatch detected" {
	const mt940 =
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:C240101EUR1000,00\r\n" ++
		":62F:C240115USD1000,00\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("currency_mismatch.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("currency_mismatch.mt940", &path_buf);

	const result = validateMt940Deep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "MT940 deep: debit opening balance" {
	// Opening: D (debit) 240101 EUR 500,00 = -50000 cents
	// Transaction: C 1500,00 = +150000 cents
	// Closing: C 240115 EUR 1000,00 = +100000 cents
	// Check: -50000 + 150000 = 100000 ✓
	const mt940 =
		":20:TESTSTMT\r\n" ++
		":25:BE12345678901234\r\n" ++
		":28C:1/1\r\n" ++
		":60F:D240101EUR500,00\r\n" ++
		":61:2401050105C1500,00NMSC//REF001\r\n" ++
		":62F:C240115EUR1000,00\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("debit_opening.mt940", .{});
	try file.writeAll(mt940);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("debit_opening.mt940", &path_buf);

	const result = validateMt940Deep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "parseMt940Amount: basic parsing" {
	try std.testing.expectEqual(@as(?i64, 100000), parseMt940Amount("1000,00"));
	try std.testing.expectEqual(@as(?i64, 50), parseMt940Amount("0,50"));
	try std.testing.expectEqual(@as(?i64, 100), parseMt940Amount("1,00"));
	try std.testing.expectEqual(@as(?i64, 1234567), parseMt940Amount("12345,67"));
	try std.testing.expectEqual(@as(?i64, null), parseMt940Amount(""));
}

// ============================================================================
// BAI2 Tests
// ============================================================================

test "BAI2 structural: valid file header" {
	const bai2 =
		"01,SENDER01,RECVR01,240115,0730,01,80,10,2/\r\n" ++
		"02,BANK01,SENDER01,1,240115,0730,,2/\r\n" ++
		"03,1234567890,USD,010,100000,,,015,50000/\r\n" ++
		"49,100000,3/\r\n" ++
		"98,100000,1,4/\r\n" ++
		"99,100000,1,6/\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("test.bai2", .{});
	try file.writeAll(bai2);
	file.close();

	const read_file = try tmp_dir.dir.openFile("test.bai2", .{});
	defer read_file.close();

	const result = validateBai2(read_file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.bai2, result.format);
}

test "BAI2 structural: invalid start" {
	const bad = "02,BANK01,SENDER01,1/\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("bad.bai2", .{});
	try file.writeAll(bad);
	file.close();

	const read_file = try tmp_dir.dir.openFile("bad.bai2", .{});
	defer read_file.close();

	const result = validateBai2(read_file);
	try std.testing.expect(!result.is_valid);
}

test "BAI2 structural: missing terminator" {
	const bad = "01,SENDER01,RECVR01,240115,0730,01,80,10,2\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("no_slash.bai2", .{});
	try file.writeAll(bad);
	file.close();

	const read_file = try tmp_dir.dir.openFile("no_slash.bai2", .{});
	defer read_file.close();

	const result = validateBai2(read_file);
	try std.testing.expect(!result.is_valid);
}

test "BAI2 deep: valid cascading control totals" {
	// File with 1 group, 1 account, 2 transactions + 1 continuation
	// Transaction amounts: 5000 + 3000 = 8000
	// Account trailer (49): control total = 8000, record count = 5 (03 + 16 + 16 + 88 + 49)
	// Group trailer (98): control total = 8000, 1 account, record count = 7 (02 + 03 + 16 + 16 + 88 + 49 + 98)
	// File trailer (99): control total = 8000, 1 group, record count = 9 (01 + 02 + 03 + 16 + 16 + 88 + 49 + 98 + 99)
	const bai2 =
		"01,SENDER01,RECVR01,240115,0730,01,80,10,2/\r\n" ++
		"02,BANK01,SENDER01,1,240115,0730,,2/\r\n" ++
		"03,1234567890,USD,010,100000/\r\n" ++
		"16,195,5000,0,REF001/\r\n" ++
		"16,195,3000,0,REF002/\r\n" ++
		"88,Additional info for REF002/\r\n" ++
		"49,8000,5/\r\n" ++
		"98,8000,1,7/\r\n" ++
		"99,8000,1,9/\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("valid_deep.bai2", .{});
	try file.writeAll(bai2);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("valid_deep.bai2", &path_buf);

	const result = validateBai2Deep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "BAI2 deep: account control total mismatch detected" {
	// Same structure but wrong account control total (9999 instead of 8000)
	const bai2 =
		"01,SENDER01,RECVR01,240115,0730,01,80,10,2/\r\n" ++
		"02,BANK01,SENDER01,1,240115,0730,,2/\r\n" ++
		"03,1234567890,USD,010,100000/\r\n" ++
		"16,195,5000,0,REF001/\r\n" ++
		"16,195,3000,0,REF002/\r\n" ++
		"49,9999,4/\r\n" ++
		"98,9999,1,5/\r\n" ++
		"99,9999,1,7/\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_total.bai2", .{});
	try file.writeAll(bai2);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_total.bai2", &path_buf);

	const result = validateBai2Deep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "BAI2 deep: group record count mismatch detected" {
	const bai2 =
		"01,SENDER01,RECVR01,240115,0730,01,80,10,2/\r\n" ++
		"02,BANK01,SENDER01,1,240115,0730,,2/\r\n" ++
		"03,1234567890,USD,010,100000/\r\n" ++
		"16,195,5000,0,REF001/\r\n" ++
		"49,5000,3/\r\n" ++
		"98,5000,1,99/\r\n" ++ // Wrong record count: 99 instead of 5
		"99,5000,1,7/\r\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_count.bai2", .{});
	try file.writeAll(bai2);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_count.bai2", &path_buf);

	const result = validateBai2Deep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "BAI2 deep: file group count mismatch detected" {
	const bai2 =
		"01,SENDER01,RECVR01,240115,0730,01,80,10,2/\r\n" ++
		"02,BANK01,SENDER01,1,240115,0730,,2/\r\n" ++
		"03,1234567890,USD,010,100000/\r\n" ++
		"49,0,2/\r\n" ++
		"98,0,1,4/\r\n" ++
		"99,0,5,6/\r\n"; // Wrong group count: 5 instead of 1

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const file = try tmp_dir.dir.createFile("corrupt_groups.bai2", .{});
	try file.writeAll(bai2);
	file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath("corrupt_groups.bai2", &path_buf);

	const result = validateBai2Deep(std.testing.allocator, path);
	try std.testing.expect(!result.is_valid);
}

test "parseBai2Amount: signed parsing" {
	try std.testing.expectEqual(@as(?i64, 5000), parseBai2Amount("5000"));
	try std.testing.expectEqual(@as(?i64, -5000), parseBai2Amount("-5000"));
	try std.testing.expectEqual(@as(?i64, 5000), parseBai2Amount("+5000"));
	try std.testing.expectEqual(@as(?i64, 0), parseBai2Amount("0"));
	try std.testing.expectEqual(@as(?i64, null), parseBai2Amount(""));
}

// ============================================================================
// Ground Truth Tests
// ============================================================================

test "ground truth: NACHA sample structural validation" {
	const file = std.fs.cwd().openFile("ground_truth_examples/nacha/sample.ach", .{}) catch {
		return; // Skip if sample not present
	};
	defer file.close();

	const result = validateNacha(file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.nacha, result.format);
}

test "ground truth: NACHA sample deep validation" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/nacha/sample.ach", &path_buf) catch {
		return; // Skip if sample not present
	};

	const result = validateNachaDeep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	try std.testing.expectEqual(FileFormat.nacha, result.format);
}

test "ground truth: MT940 sample structural validation" {
	const file = std.fs.cwd().openFile("ground_truth_examples/mt940/sample.mt940", .{}) catch {
		return;
	};
	defer file.close();

	const result = validateMt940(file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.mt940, result.format);
}

test "ground truth: MT940 sample deep validation" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/mt940/sample.mt940", &path_buf) catch {
		return;
	};

	const result = validateMt940Deep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	try std.testing.expectEqual(FileFormat.mt940, result.format);
}

test "ground truth: BAI2 sample structural validation" {
	const file = std.fs.cwd().openFile("ground_truth_examples/bai2/sample.bai2", .{}) catch {
		return;
	};
	defer file.close();

	const result = validateBai2(file);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.bai2, result.format);
}

test "ground truth: BAI2 sample deep validation" {
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = std.fs.cwd().realpath("ground_truth_examples/bai2/sample.bai2", &path_buf) catch {
		return;
	};

	const result = validateBai2Deep(std.testing.allocator, path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	try std.testing.expectEqual(FileFormat.bai2, result.format);
}
