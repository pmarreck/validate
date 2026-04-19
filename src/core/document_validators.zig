//! Document format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for document formats: SQLite, OLE2 (DOC/XLS/PPT), WordPerfect, MDB, ACCDB.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const findInBuffer = format_validation.findInBuffer;

const ole2_validator = @import("ole2_validator.zig");
const word_doc_validator = @import("word_doc_validator.zig");
const excel_biff8_validator = @import("excel_biff8_validator.zig");
const errmsg = @import("error_messages.zig");

const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

const testing = std.testing;

// ============ Microsoft Access Database Validators ============

/// Validate Microsoft Access MDB file structure (Access 97-2003).
/// MDB files have magic bytes 00 01 00 00 followed by "Standard Jet DB" at offset 4.
pub fn validateMdb(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.mdb, .failed_to_seek, "to start");

    var header: [20]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.mdb, .failed_to_read, "MDB header");
    };

    if (bytes_read < 20) {
        return ValidationResult.invalidCode(.mdb, .file_too_small, "MDB format");
    }

    // Check magic bytes: 00 01 00 00
    if (header[0] != 0x00 or header[1] != 0x01 or header[2] != 0x00 or header[3] != 0x00) {
        return ValidationResult.invalidCode(.mdb, .invalid_magic, "MDB");
    }

    // Check for "Standard Jet DB" at offset 4 (15 characters, null terminated makes 16)
    const jet_sig = "Standard Jet DB";
    if (!std.mem.eql(u8, header[4..19], jet_sig)) {
        return ValidationResult.invalidCodeMsg(.mdb, .invalid_signature_not, "MDB", errmsg.invalidSignatureNot("MDB", "Standard Jet DB"));
    }

    return ValidationResult.ok(.mdb);
}

/// Validate Microsoft Access ACCDB file structure (Access 2007+).
/// ACCDB files have magic bytes 00 01 00 00 followed by "Standard ACE DB" at offset 4.
pub fn validateAccdb(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.accdb, .failed_to_seek, "to start");

    var header: [20]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.accdb, .failed_to_read, "ACCDB header");
    };

    if (bytes_read < 20) {
        return ValidationResult.invalidCode(.accdb, .file_too_small, "ACCDB format");
    }

    // Check magic bytes: 00 01 00 00
    if (header[0] != 0x00 or header[1] != 0x01 or header[2] != 0x00 or header[3] != 0x00) {
        return ValidationResult.invalidCode(.accdb, .invalid_magic, "ACCDB");
    }

    // Check for "Standard ACE DB" at offset 4 (15 characters, null terminated makes 16)
    const ace_sig = "Standard ACE DB";
    if (!std.mem.eql(u8, header[4..19], ace_sig)) {
        return ValidationResult.invalidCodeMsg(.accdb, .invalid_signature_not, "ACCDB", errmsg.invalidSignatureNot("ACCDB", "Standard ACE DB"));
    }

    return ValidationResult.ok(.accdb);
}

/// Deep validation for MDB files.
/// MDB is a proprietary binary format - deep validation checks version codes.
pub fn validateMdbDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    var header: [64]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.mdb, .failed_to_read, "MDB header");
    };

    if (bytes_read < 64) {
        return ValidationResult.invalidCode(.mdb, .file_too_small, "MDB format");
    }

    // Check magic bytes: 00 01 00 00
    if (header[0] != 0x00 or header[1] != 0x01 or header[2] != 0x00 or header[3] != 0x00) {
        return ValidationResult.invalidCode(.mdb, .invalid_magic, "MDB");
    }

    // Check for "Standard Jet DB" at offset 4
    const jet_sig = "Standard Jet DB";
    if (!std.mem.eql(u8, header[4..19], jet_sig)) {
        return ValidationResult.invalidCodeMsg(.mdb, .invalid_signature_not, "MDB", errmsg.invalidSignatureNot("MDB", "Standard Jet DB"));
    }

    // Jet version at offset 0x14 (0 = Jet3, 1 = Jet4)
    const jet_version = header[0x14];
    if (jet_version > 1) {
        return ValidationResult.okWithDepthAndWarning(.mdb, .structural, errmsg.unknown("Jet version"));
    }

    // For MDB files, we can only do structural validation since the internal
    // structure is proprietary and complex. The header check is sufficient.
    return ValidationResult.okWithDepth(.mdb, .structural);
}

/// Deep validation for ACCDB files.
pub fn validateAccdbDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    var header: [64]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.accdb, .failed_to_read, "ACCDB header");
    };

    if (bytes_read < 64) {
        return ValidationResult.invalidCode(.accdb, .file_too_small, "ACCDB format");
    }

    // Check magic bytes: 00 01 00 00
    if (header[0] != 0x00 or header[1] != 0x01 or header[2] != 0x00 or header[3] != 0x00) {
        return ValidationResult.invalidCode(.accdb, .invalid_magic, "ACCDB");
    }

    // Check for "Standard ACE DB" at offset 4
    const ace_sig = "Standard ACE DB";
    if (!std.mem.eql(u8, header[4..19], ace_sig)) {
        return ValidationResult.invalidCodeMsg(.accdb, .invalid_signature_not, "ACCDB", errmsg.invalidSignatureNot("ACCDB", "Standard ACE DB"));
    }

    // ACE version at offset 0x14:
    // 0x02 = ACE 12 (Access 2007)
    // 0x03 = ACE 14 (Access 2010)
    // 0x05 = ACE 16 (Access 2016 with Large Integer)
    const ace_version = header[0x14];
    if (ace_version < 0x02 or ace_version > 0x05) {
        return ValidationResult.okWithDepthAndWarning(.accdb, .structural, errmsg.unknown("ACE version"));
    }

    // ACCDB is proprietary - structural validation only
    return ValidationResult.okWithDepth(.accdb, .structural);
}

/// Buffer-based validation for MDB files.
pub fn validateMdbFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 20) {
        return ValidationResult.invalidCode(.mdb, .buffer_too_small, "MDB");
    }

    // Check magic bytes: 00 01 00 00
    if (data[0] != 0x00 or data[1] != 0x01 or data[2] != 0x00 or data[3] != 0x00) {
        return ValidationResult.invalidCode(.mdb, .invalid_magic, "MDB");
    }

    // Check for "Standard Jet DB" at offset 4
    const jet_sig = "Standard Jet DB";
    if (!std.mem.eql(u8, data[4..19], jet_sig)) {
        return ValidationResult.invalidCodeMsg(.mdb, .invalid_signature_not, "MDB", errmsg.invalidSignatureNot("MDB", "Standard Jet DB"));
    }

    return ValidationResult.ok(.mdb);
}

/// Buffer-based validation for ACCDB files.
pub fn validateAccdbFromBuffer(data: []const u8) ValidationResult {
    if (data.len < 20) {
        return ValidationResult.invalidCode(.accdb, .buffer_too_small, "ACCDB");
    }

    // Check magic bytes: 00 01 00 00
    if (data[0] != 0x00 or data[1] != 0x01 or data[2] != 0x00 or data[3] != 0x00) {
        return ValidationResult.invalidCode(.accdb, .invalid_magic, "ACCDB");
    }

    // Check for "Standard ACE DB" at offset 4
    const ace_sig = "Standard ACE DB";
    if (!std.mem.eql(u8, data[4..19], ace_sig)) {
        return ValidationResult.invalidCodeMsg(.accdb, .invalid_signature_not, "ACCDB", errmsg.invalidSignatureNot("ACCDB", "Standard ACE DB"));
    }

    return ValidationResult.ok(.accdb);
}

// ============ OLE2/CFBF Validators ============

/// OLE2/CFBF (Compound File Binary Format) magic signature
pub const OLE2_MAGIC = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

/// Validate OLE2/CFBF compound file structure.
/// This covers DOC, XLS, PPT (Office 97-2003) formats.
pub fn validateOle2(file: *FileSource, format: FileFormat) ValidationResult {
    var header: [512]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(format, .failed_to_read, "OLE2 header");
    };

    if (bytes_read < 512) {
        return ValidationResult.invalidCode(format, .file_too_small, "OLE2 format");
    }

    // Check magic signature
    if (!std.mem.eql(u8, header[0..8], &OLE2_MAGIC)) {
        return ValidationResult.invalidCode(format, .invalid_signature, "OLE2");
    }

    // Check minor version (offset 0x18, 2 bytes) - should be 0x003E or less common values
    const minor_version = std.mem.readInt(u16, header[0x18..0x1A], .little);
    _ = minor_version; // Informational

    // Check major version (offset 0x1A, 2 bytes) - should be 3 or 4
    const major_version = std.mem.readInt(u16, header[0x1A..0x1C], .little);
    if (major_version != 3 and major_version != 4) {
        return ValidationResult.invalidCode(format, .unsupported, "OLE2 version");
    }

    // Check byte order (offset 0x1C, 2 bytes) - should be 0xFFFE (little-endian)
    const byte_order = std.mem.readInt(u16, header[0x1C..0x1E], .little);
    if (byte_order != 0xFFFE) {
        return ValidationResult.invalidCode(format, .invalid_value, "OLE2 byte order marker");
    }

    // Check sector size power (offset 0x1E, 2 bytes) - should be 9 (512) or 12 (4096)
    const sector_power = std.mem.readInt(u16, header[0x1E..0x20], .little);
    if (sector_power != 9 and sector_power != 12) {
        return ValidationResult.invalidCode(format, .invalid_value, "OLE2 sector size");
    }

    // Check mini sector size power (offset 0x20, 2 bytes) - should be 6 (64)
    const mini_sector_power = std.mem.readInt(u16, header[0x20..0x22], .little);
    if (mini_sector_power != 6) {
        return ValidationResult.invalidCode(format, .invalid_value, "OLE2 mini sector size");
    }

    return ValidationResult.ok(format);
}

/// Validate MSI (Microsoft Installer) as an OLE2/CFBF container.
pub fn validateMsi(file: *FileSource) ValidationResult {
    return validateOle2(file, .msi);
}

/// Detect specific OLE2 subformat (DOC, XLS, PPT, MSI) by examining directory entries.
/// OLE2 stores stream names as UTF-16LE in directory entry structures.
pub fn detectOle2Subformat(file: *FileSource) FileFormat {
    // Zero-copy from mmap when available
    var heap_buf1: ?[]u8 = null;
    defer if (heap_buf1) |buf| std.heap.page_allocator.free(buf);
    const buffer: []const u8 = if (file.getMappedRange(0, 65536)) |mapped|
        mapped
    else blk: {
        const buf = std.heap.page_allocator.alloc(u8, 65536) catch return .doc;
        heap_buf1 = buf;
        file.seekTo(0) catch return .doc;
        const n = file.read(buf) catch return .doc;
        break :blk buf[0..n];
    };
    const bytes_read = buffer.len;

    // Stream names in OLE2 are stored as UTF-16LE in 64-byte directory entries
    const workbook_utf16 = [_]u8{ 'W', 0, 'o', 0, 'r', 0, 'k', 0, 'b', 0, 'o', 0, 'o', 0, 'k', 0 };
    const book_utf16 = [_]u8{ 'B', 0, 'o', 0, 'o', 0, 'k', 0 };
    const ppt_utf16 = [_]u8{ 'P', 0, 'o', 0, 'w', 0, 'e', 0, 'r', 0, 'P', 0, 'o', 0, 'i', 0, 'n', 0, 't', 0 };
    const word_utf16 = [_]u8{ 'W', 0, 'o', 0, 'r', 0, 'd', 0, 'D', 0, 'o', 0, 'c', 0, 'u', 0, 'm', 0, 'e', 0, 'n', 0, 't', 0 };
    const msi_tables_utf16 = [_]u8{ 0x05, 0, 'T', 0, 'a', 0, 'b', 0, 'l', 0, 'e', 0, 's', 0 };
    const msi_string_pool_utf16 = [_]u8{ 0x05, 0, 'S', 0, 'u', 0, 'm', 0, 'm', 0, 'a', 0, 'r', 0, 'y', 0 };
    const msi_clsid = [_]u8{ 0x84, 0x10, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 };

    const result = detectOle2InBuffer(buffer, bytes_read, &workbook_utf16, &book_utf16, &ppt_utf16, &word_utf16, &msi_tables_utf16, &msi_string_pool_utf16, &msi_clsid);
    if (result != .unknown) return result;
    // For larger files, read the directory sector from the OLE2 header
    if (bytes_read >= 0x34) {
        const sector_size: u64 = blk: {
            const shift = @as(u6, @intCast(buffer[0x1E]));
            break :blk @as(u64, 1) << shift;
        };
        const dir_sector_id = std.mem.readInt(u32, buffer[0x30..0x34], .little);
        if (dir_sector_id != 0xFFFFFFFE and dir_sector_id != 0xFFFFFFFF) {
            const dir_offset = 512 + @as(u64, dir_sector_id) * sector_size;
            var heap_buf2: ?[]u8 = null;
            defer if (heap_buf2) |buf| std.heap.page_allocator.free(buf);
            const dir_buffer: []const u8 = if (file.getMappedRange(dir_offset, 65536)) |mapped|
                mapped
            else blk: {
                file.seekTo(dir_offset) catch return .doc;
                const buf = std.heap.page_allocator.alloc(u8, 65536) catch return .doc;
                heap_buf2 = buf;
                const n = file.read(buf) catch return .doc;
                break :blk buf[0..n];
            };
            const dir_read = dir_buffer.len;

            const dir_result = detectOle2InBuffer(dir_buffer, dir_read, &workbook_utf16, &book_utf16, &ppt_utf16, &word_utf16, &msi_tables_utf16, &msi_string_pool_utf16, &msi_clsid);
            if (dir_result != .unknown) return dir_result;
        }
    }

    return .doc; // Default fallback
}

/// Helper: search a buffer for known OLE2 subformat stream names.
fn detectOle2InBuffer(
    buf: []const u8,
    len: usize,
    workbook_utf16: []const u8,
    book_utf16: []const u8,
    ppt_utf16: []const u8,
    word_utf16: []const u8,
    msi_tables_utf16: []const u8,
    msi_string_pool_utf16: []const u8,
    msi_clsid: []const u8,
) FileFormat {
    if (findInBuffer(buf, len, workbook_utf16) or findInBuffer(buf, len, book_utf16)) return .xls;
    if (findInBuffer(buf, len, ppt_utf16)) return .ppt;
    if (findInBuffer(buf, len, word_utf16)) return .doc;
    // MSI detection: check for characteristic stream names or CLSID
    if (findInBuffer(buf, len, msi_tables_utf16) or findInBuffer(buf, len, msi_string_pool_utf16)) return .msi;
    if (findInBuffer(buf, len, msi_clsid)) return .msi;
    return .unknown;
}

// ============ WordPerfect Validator ============

/// Validate WordPerfect document structure.
pub fn validateWordPerfect(file: *FileSource) ValidationResult {
    var header: [16]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.wpd, .failed_to_read, "WordPerfect header");
    };

    if (bytes_read < 16) {
        return ValidationResult.invalidCode(.wpd, .file_too_small, "WordPerfect");
    }

    // Check magic signature: FF 57 50 43 (WPC prefix)
    if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0xFF, 0x57, 0x50, 0x43 })) {
        return ValidationResult.invalidCode(.wpd, .invalid_signature, "WordPerfect");
    }

    // Check document area offset (bytes 4-7)
    const doc_offset = std.mem.readInt(u32, header[4..8], .little);

    // Verify file is large enough for document area
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.wpd, .failed_to_get, "file size");
    };

    if (doc_offset > file_size) {
        return ValidationResult.invalidCode(.wpd, .invalid_value, "document offset (truncated)");
    }

    // Check product type (byte 8) - should be reasonable
    const product_type = header[8];
    if (product_type == 0) {
        return ValidationResult.invalidCode(.wpd, .invalid_value, "product type");
    }

    // Check file type (byte 9) - 0x0A for WPD
    const file_type = header[9];
    if (file_type != 0x0A and file_type != 0x01) {
        return ValidationResult.invalidCode(.wpd, .unsupported, "WordPerfect file type");
    }

    return ValidationResult.ok(.wpd);
}

// ============ SQLite Validator ============

/// SQLite varint result: the decoded value and how many bytes were consumed.
const VarintResult = struct {
	value: u64,
	bytes_read: u32,
};

/// Read a SQLite-format varint starting at `pos` within `data[0..limit]`.
/// Returns bytes_read=0 if the varint would exceed the buffer.
/// SQLite varints are 1-9 bytes: high bit set means "more bytes follow",
/// except the 9th byte which uses all 8 bits.
fn readVarint(data: []const u8, pos: u32, limit: u32) VarintResult {
	if (pos >= limit) return .{ .value = 0, .bytes_read = 0 };
	var result: u64 = 0;
	var i: u32 = 0;
	while (i < 8) : (i += 1) {
		if (pos + i >= limit) return .{ .value = 0, .bytes_read = 0 };
		const b = data[pos + i];
		result = (result << 7) | @as(u64, b & 0x7F);
		if (b & 0x80 == 0) return .{ .value = result, .bytes_read = i + 1 };
	}
	// 9th byte: all 8 bits are data
	if (pos + 8 >= limit) return .{ .value = 0, .bytes_read = 0 };
	result = (result << 8) | @as(u64, data[pos + 8]);
	return .{ .value = result, .bytes_read = 9 };
}

/// Return the content size in bytes for a SQLite serial type code.
/// Serial types: 0=NULL(0), 1=int8(1), 2=int16(2), 3=int24(3), 4=int32(4),
/// 5=int48(6), 6=int64(8), 7=float64(8), 8=zero(0), 9=one(0),
/// >=12 even: blob of (N-12)/2, >=13 odd: text of (N-13)/2.
fn serialTypeContentSize(serial_type: u64) u64 {
	return switch (serial_type) {
		0 => 0, // NULL
		1 => 1, // 8-bit int
		2 => 2, // 16-bit int
		3 => 3, // 24-bit int
		4 => 4, // 32-bit int
		5 => 6, // 48-bit int
		6 => 8, // 64-bit int
		7 => 8, // IEEE 754 float
		8 => 0, // integer 0
		9 => 0, // integer 1
		10, 11 => 0, // reserved (should not appear)
		else => if (serial_type >= 12)
			if (serial_type % 2 == 0)
				(serial_type - 12) / 2 // blob
			else
				(serial_type - 13) / 2 // text
		else
			0,
	};
}

/// Validate SQLite database file structure.
pub fn validateSqlite(file: *FileSource) ValidationResult {
    return validateSqliteWithOptions(file, false);
}

pub fn validateSqliteWithOptions(file: *FileSource, skip_magic: bool) ValidationResult {
    var header: [100]u8 = undefined;
    const bytes_read = file.read(&header) catch {
        return ValidationResult.invalidCode(.sqlite, .failed_to_read, "SQLite header");
    };

    if (bytes_read < 100) {
        return ValidationResult.invalidCode(.sqlite, .file_too_small, "SQLite");
    }

    // Check magic signature: "SQLite format 3\0" (or skip if skip_magic is set)
    if (!skip_magic) {
        if (!std.mem.eql(u8, header[0..16], "SQLite format 3\x00")) {
            return ValidationResult.invalidCode(.sqlite, .invalid_signature, "SQLite");
        }
    }

    // Page size (bytes 16-17, big-endian): must be power of 2 between 512 and 65536
    const page_size = std.mem.readInt(u16, header[16..18], .big);
    const valid_page_size = switch (page_size) {
        512, 1024, 2048, 4096, 8192, 16384, 32768, 65535 => true,
        1 => true, // Special value meaning 65536
        else => false,
    };
    if (!valid_page_size) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite page size");
    }

    // File format write version (byte 18): 1 for legacy, 2 for WAL
    const write_version = header[18];
    if (write_version != 1 and write_version != 2) {
        return ValidationResult.invalidCode(.sqlite, .unsupported, "SQLite write version");
    }

    // File format read version (byte 19): 1 for legacy, 2 for WAL
    const read_version = header[19];
    if (read_version != 1 and read_version != 2) {
        return ValidationResult.invalidCode(.sqlite, .unsupported, "SQLite read version");
    }

    // Reserved space per page (byte 20): usually 0
    // Maximum embedded payload fraction (byte 21): must be 64
    if (header[21] != 64) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "max embedded payload fraction");
    }

    // Minimum embedded payload fraction (byte 22): must be 32
    if (header[22] != 32) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "min embedded payload fraction");
    }

    // Leaf payload fraction (byte 23): must be 32
    if (header[23] != 32) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "leaf payload fraction");
    }

    // File change counter (bytes 24-27) and version-valid-for (bytes 92-95)
    // When they match, the page count is reliable
    const file_change_counter = std.mem.readInt(u32, header[24..28], .big);
    const version_valid_for = std.mem.readInt(u32, header[92..96], .big);

    // Schema format number (bytes 44-47): 0 (empty/default), 1, 2, 3, or 4
    const schema_format = std.mem.readInt(u32, header[44..48], .big);
    if (schema_format > 4) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite schema format number (must be 0-4)");
    }

    // Text encoding (bytes 56-59): 0 (unset/default), 1 (UTF-8), 2 (UTF-16le), or 3 (UTF-16be)
    const text_encoding = std.mem.readInt(u32, header[56..60], .big);
    if (text_encoding > 3) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite text encoding (must be 0-3)");
    }

    // Application ID (bytes 68-71) and user version (bytes 60-63) are informational

    // Bytes 72-91 must be zero (reserved for expansion)
    var reserved_ok = true;
    for (header[72..92]) |b| {
        if (b != 0) {
            reserved_ok = false;
            break;
        }
    }
    if (!reserved_ok) {
        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite reserved header bytes (must be zero)");
    }

    // Database size in pages (bytes 28-31, big-endian)
    const db_page_count = std.mem.readInt(u32, header[28..32], .big);

    // Freelist pages (bytes 32-35): first freelist trunk page, (bytes 36-39): total freelist pages
    const total_freelist = std.mem.readInt(u32, header[36..40], .big);
    if (db_page_count > 0 and total_freelist > db_page_count) {
        return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "freelist page count exceeds database size");
    }

    // Verify file size is consistent with page count (basic check)
    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.sqlite, .failed_to_get, "file size");
    };

    const actual_page_size: u64 = if (page_size == 1) 65536 else @as(u64, page_size);
    if (db_page_count > 0) {
        const expected_size = @as(u64, db_page_count) * actual_page_size;
        // Allow some tolerance for journaling modes
        if (file_size < expected_size - actual_page_size) {
            return ValidationResult.invalid(.sqlite, "SQLite file appears truncated");
        }
    }

    // Validate root page B-tree header (starts at offset 100 in page 1)
    // Page type: 2=interior index, 5=interior table, 10=leaf index, 13=leaf table
    // Page 1 must be a table B-tree (type 5 or 13)
    if (bytes_read >= 100) {
        // Read root page header (first 8 bytes of B-tree at offset 100)
        file.seekTo(100) catch return ValidationResult.ok(.sqlite);
        var btree_hdr: [8]u8 = undefined;
        const btree_read = file.read(&btree_hdr) catch return ValidationResult.ok(.sqlite);
        if (btree_read >= 8) {
            const page_type = btree_hdr[0];
            if (page_type != 2 and page_type != 5 and page_type != 10 and page_type != 13) {
                return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite root page B-tree type");
            }
            // Cell count (bytes 3-4 big-endian) should be reasonable
            const cell_count = std.mem.readInt(u16, btree_hdr[3..5], .big);
            // Cell content area offset (bytes 5-6): 0 means 65536
            const content_offset = std.mem.readInt(u16, btree_hdr[5..7], .big);
            const actual_content = if (content_offset == 0) @as(u32, 65536) else @as(u32, content_offset);
            // Content offset must be within the page (after header)
            if (actual_content > actual_page_size) {
                return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite cell content area beyond page");
            }
            // If cells exist, content area should be before end of page
            if (cell_count > 0 and actual_content <= 100 + 8) {
                return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite cell content area overlaps header");
            }
        }
    }

    // Cross-validate: if version-valid-for matches file change counter,
    // the page count should be consistent with file size
    if (file_change_counter == version_valid_for and db_page_count > 0) {
        const expected_size = @as(u64, db_page_count) * actual_page_size;
        if (file_size != expected_size) {
            // Allow minor tolerance (WAL mode may differ)
            if (file_size < expected_size -| actual_page_size or file_size > expected_size + actual_page_size) {
                return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite file size inconsistent with page count");
            }
        }
    }

    // Validate B-tree page headers, cell pointers, freeblocks, and cell record
    // headers across all pages. This catches corruption in structural fields,
    // cell pointer arrays, freeblock chains, and cell content (varint headers).
    const reserved_per_page = @as(u32, header[20]);
    const usable_size: u32 = @intCast(actual_page_size - reserved_per_page);
    const total_pages: u32 = if (db_page_count > 0)
        db_page_count
    else
        @intCast(file_size / actual_page_size);

    // Validate all pages (capped at a reasonable limit for performance)
    const max_pages_to_check: u32 = @min(total_pages, 256);
    const page_buf = std.heap.page_allocator.alloc(u8, 65536) catch {
        return ValidationResult.invalidCode(.sqlite, .out_of_memory, "SQLite page buffer");
    };
    defer std.heap.page_allocator.free(page_buf);
    const page_slice = page_buf[0..@intCast(actual_page_size)];

    var page_num: u32 = 1;
    while (page_num <= max_pages_to_check) : (page_num += 1) {
        const page_offset: u64 = (@as(u64, page_num) - 1) * actual_page_size;
        file.seekTo(page_offset) catch break;
        const n = file.read(page_slice) catch break;
        if (n < actual_page_size) break;

        // Page 1 has the 100-byte database header; B-tree header starts at offset 100
        const hdr_offset: u32 = if (page_num == 1) 100 else 0;
        const page_type = page_slice[hdr_offset];

        // Only validate B-tree pages (types 2, 5, 10, 13)
        if (page_type != 2 and page_type != 5 and page_type != 10 and page_type != 13) {
            continue;
        }

        const is_interior = (page_type == 2 or page_type == 5);
        const btree_hdr_size: u32 = if (is_interior) 12 else 8;

        // Parse B-tree page header
        const first_freeblock = std.mem.readInt(u16, page_slice[hdr_offset + 1 ..][0..2], .big);
        const pg_cell_count = std.mem.readInt(u16, page_slice[hdr_offset + 3 ..][0..2], .big);
        const pg_content_offset = std.mem.readInt(u16, page_slice[hdr_offset + 5 ..][0..2], .big);
        const pg_fragmented = page_slice[hdr_offset + 7];
        const actual_pg_content: u32 = if (pg_content_offset == 0) 65536 else @as(u32, pg_content_offset);

        // Validate content offset is within usable page
        if (actual_pg_content > usable_size) {
            return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite B-tree cell content area beyond page");
        }

        // Validate cell count is reasonable (each cell pointer is 2 bytes)
        const ptr_array_start = hdr_offset + btree_hdr_size;
        const ptr_array_end = ptr_array_start + @as(u32, pg_cell_count) * 2;
        if (ptr_array_end > usable_size) {
            return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite cell pointer array exceeds page");
        }

        // Validate each cell pointer points within the content area
        var ptr_idx: u32 = 0;
        while (ptr_idx < pg_cell_count) : (ptr_idx += 1) {
            const ptr_off = ptr_array_start + ptr_idx * 2;
            const cell_ptr = std.mem.readInt(u16, page_slice[ptr_off..][0..2], .big);
            if (cell_ptr < actual_pg_content or cell_ptr >= usable_size) {
                return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite cell pointer out of range");
            }
        }

        // Walk the freeblock chain and validate consistency
        var total_free_bytes: u32 = 0;
        if (first_freeblock != 0) {
            var fb_offset: u32 = @as(u32, first_freeblock);
            var fb_count: u32 = 0;
            while (fb_offset != 0 and fb_count < 1000) : (fb_count += 1) {
                if (fb_offset < ptr_array_end or fb_offset + 4 > usable_size) {
                    return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite freeblock outside page bounds");
                }
                const next_fb = std.mem.readInt(u16, page_slice[fb_offset..][0..2], .big);
                const fb_size = std.mem.readInt(u16, page_slice[fb_offset + 2 ..][0..2], .big);
                if (fb_size < 4) {
                    return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite freeblock size too small");
                }
                if (fb_offset + fb_size > usable_size) {
                    return ValidationResult.invalidCode(.sqlite, .exceeds_bounds, "SQLite freeblock extends beyond page");
                }
                // Freeblocks must be in ascending order
                if (next_fb != 0 and next_fb <= fb_offset) {
                    return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite freeblock chain not ascending");
                }
                total_free_bytes += fb_size;
                fb_offset = @as(u32, next_fb);
            }
        }

        // Page space accounting: all space on the page must be accounted for.
        if (actual_pg_content + total_free_bytes + pg_fragmented > usable_size) {
            return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite page space accounting overflow");
        }

        // Note: The unallocated gap between cell pointer array and cell content area
        // may contain remnant data from previous cell allocations. SQLite does not
        // zero this region when allocating cells from the gap, so non-zero bytes
        // in this area are normal and cannot be used as a corruption indicator.

        // Validate cell record headers on leaf pages by parsing varint payload lengths.
        // On leaf table pages (type 13), each cell starts with: varint(payload_len), varint(rowid), then payload.
        // On leaf index pages (type 10), each cell starts with: varint(payload_len), then payload.
        // The payload begins with a varint header_len followed by serial type codes.
        // Corrupted bytes in cell content will produce invalid varint sequences.
        if (page_type == 13 or page_type == 10) {
            var cell_idx: u32 = 0;
            while (cell_idx < pg_cell_count) : (cell_idx += 1) {
                const ptr_off = ptr_array_start + cell_idx * 2;
                const cell_start = std.mem.readInt(u16, page_slice[ptr_off..][0..2], .big);
                if (cell_start >= usable_size) continue;

                var pos: u32 = cell_start;

                // Parse payload length varint
                const payload_result = readVarint(page_slice, pos, usable_size);
                if (payload_result.bytes_read == 0) {
                    return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite cell payload varint");
                }
                const payload_len = payload_result.value;
                pos += payload_result.bytes_read;

                // For table leaf pages, parse rowid varint
                if (page_type == 13) {
                    const rowid_result = readVarint(page_slice, pos, usable_size);
                    if (rowid_result.bytes_read == 0) {
                        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite cell rowid varint");
                    }
                    pos += rowid_result.bytes_read;
                }

                // Parse the record header: first varint is header_len, then serial type codes
                if (pos < usable_size and payload_len > 0) {
                    const hdr_len_result = readVarint(page_slice, pos, usable_size);
                    if (hdr_len_result.bytes_read == 0) {
                        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite record header length varint");
                    }
                    const record_hdr_len = hdr_len_result.value;
                    // Header length includes itself; must be at least 1 (the varint itself)
                    if (record_hdr_len < hdr_len_result.bytes_read or record_hdr_len > payload_len) {
                        return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite record header length");
                    }

                    // Parse serial type codes within the header
                    const hdr_end: u32 = @intCast(@min(@as(u64, pos) + record_hdr_len, usable_size));
                    var hdr_pos = pos + hdr_len_result.bytes_read;
                    var total_content_size: u64 = 0;
                    while (hdr_pos < hdr_end) {
                        const st_result = readVarint(page_slice, hdr_pos, hdr_end);
                        if (st_result.bytes_read == 0) {
                            return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite serial type varint");
                        }
                        total_content_size += serialTypeContentSize(st_result.value);
                        hdr_pos += st_result.bytes_read;
                    }

                    // Verify content size is consistent with payload
                    // payload = header + content; content = payload - header_len
                    if (payload_len >= record_hdr_len) {
                        const expected_content = payload_len - record_hdr_len;
                        // For overflow pages, total_content_size can exceed what's on this page,
                        // but it must match the declared payload content exactly
                        if (total_content_size != expected_content) {
                            return ValidationResult.invalidCode(.sqlite, .invalid_value, "SQLite record content size mismatch");
                        }
                    }
                }
            }
        }
    }

    return ValidationResult.ok(.sqlite);
}

/// Deep SQLite validation using PRAGMA integrity_check.
/// This validates B-tree structure, page integrity, and index consistency.
pub fn validateSqliteDeep(allocator: Allocator, path: []const u8) ValidationResult {
    // Create null-terminated path for SQLite
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch {
        return ValidationResult.invalidCode(.sqlite, .out_of_memory, "for SQLite");
    };
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    var db: ?*sqlite3.sqlite3 = null;
    const open_result = sqlite3.sqlite3_open_v2(
        path_z.ptr,
        &db,
        sqlite3.SQLITE_OPEN_READONLY,
        null,
    );
    if (open_result != sqlite3.SQLITE_OK) {
        if (db) |d| _ = sqlite3.sqlite3_close(d);
        // SQLITE_BUSY (5) and SQLITE_LOCKED (6) indicate the database is in use
        if (open_result == 5 or open_result == 6) {
            return ValidationResult.okWithDepthAndWarning(.sqlite, .structural, "Database is locked by another process");
        }
        return ValidationResult.invalidCodeWithDepth(.sqlite, .failed_to_open, "database for integrity check", .full);
    }
    defer _ = sqlite3.sqlite3_close(db);

    // Run PRAGMA integrity_check
    var stmt: ?*sqlite3.sqlite3_stmt = null;
    const sql = "PRAGMA integrity_check;";
    const prepare_result = sqlite3.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
    if (prepare_result != sqlite3.SQLITE_OK) {
        // SQLITE_BUSY (5) and SQLITE_LOCKED (6) indicate the database is in use,
        // not that it's corrupt. Return a warning instead of failure.
        if (prepare_result == 5 or prepare_result == 6) {
            return ValidationResult.okWithDepthAndWarning(.sqlite, .structural, "Database is locked by another process");
        }
        return ValidationResult.invalidWithDepth(.sqlite, "Failed to prepare integrity check", .full);
    }
    defer _ = sqlite3.sqlite3_finalize(stmt);

    // Execute and check result
    const step_result = sqlite3.sqlite3_step(stmt);
    if (step_result == sqlite3.SQLITE_ROW) {
        const result_ptr: [*:0]const u8 = @ptrCast(sqlite3.sqlite3_column_text(stmt, 0));
        const result_text = std.mem.span(result_ptr);

        if (std.mem.eql(u8, result_text, "ok")) {
            return ValidationResult.okWithDepth(.sqlite, .full);
        } else {
            // Database has integrity issues
            return ValidationResult.invalidWithDepth(.sqlite, "Database integrity check failed", .full);
        }
    }

    // SQLITE_BUSY (5) and SQLITE_LOCKED (6) during step indicate the database is in use
    if (step_result == 5 or step_result == 6) {
        return ValidationResult.okWithDepthAndWarning(.sqlite, .structural, "Database is locked by another process");
    }

    return ValidationResult.invalidWithDepth(.sqlite, "Integrity check returned no result", .full);
}

// ============ OLE2/CFBF Deep Validation (DOC, XLS, PPT) ============

/// Deep OLE2 validation by validating FAT chains, directory structure, and stream chains.
/// This validates the container structure but NOT the binary format content within streams.
/// See ole2_validator.zig for details on what is and isn't validated.
pub fn validateOle2Deep(allocator: Allocator, path: []const u8, format: FileFormat) ValidationResult {
    var source = FileSource.open(path) catch {
        return ValidationResult.invalidCodeWithDepth(format, .failed_to_open, "file", .structural);
    };
    defer source.close();

    const result = ole2_validator.validateOle2Deep(allocator, &source);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(format, result.error_message orelse "OLE2 validation failed", .structural);
    }

    // For .doc, go deeper: parse FIB + cross-validate Table stream
    if (format == .doc) {
        return word_doc_validator.validateDocDeep(allocator, &source);
    }

    // For .xls, go deeper: parse BIFF8 record chain + BoundSheet8 cross-validation
    if (format == .xls) {
        return excel_biff8_validator.validateXlsDeep(allocator, &source);
    }

    // PPT: still structural-only for now
    return ValidationResult.okWithDepth(format, .structural);
}

// ============ dBASE Database Validators ============

/// Known valid dBASE version bytes.
/// Low 3 bits encode the dBASE level; upper bits indicate memo/SQL extensions.
fn isValidDbfVersion(v: u8) bool {
    return switch (v) {
        0x02, 0x03, 0x04, 0x05, 0x07, // dBASE II/III/IV/V
        0x30, 0x31, 0x32, 0x43, 0x63, // Visual FoxPro variants
        0x7B, // dBASE IV + memo + SQL table
        0x83, 0x87, 0x8B, 0x8E, // dBASE III+ with memo, dBASE IV with memo
        0xCB, // dBASE IV with memo + SQL table
        0xE5, // Clipper SIX with SMT memo
        0xF5, 0xF4, 0xFB, // FoxPro with memo
        => true,
        else => false,
    };
}

/// Recognized dBASE field type characters.
fn isValidDbfFieldType(t: u8) bool {
    return switch (t) {
        'C', 'N', 'D', 'L', 'M', 'F', 'B', 'G', 'P', 'Y', 'T', 'I', 'V', 'X', '@', 'O', '+' => true,
        else => false,
    };
}

/// Validate a dBASE .dbf file from a memory buffer.
/// Checks version byte, header/record cross-validation, field descriptors, and terminator.
/// Returns structural validity; no checksum exists in the format so corruption is "mixed" opacity.
pub fn validateDbfFromBuffer(data: []const u8) ValidationResult {
    // Minimum: 12-byte header1 + 1 terminator = 13 bytes
    if (data.len < 13) {
        return ValidationResult.invalidCode(.dbf, .file_too_small, "dBASE format");
    }

    // Version byte
    const version = data[0];
    if (!isValidDbfVersion(version)) {
        return ValidationResult.invalidCode(.dbf, .invalid_magic, "dBASE version byte");
    }

    // Date: month 1-12, day 1-31
    const last_update_m = data[2];
    const last_update_d = data[3];
    if (last_update_m == 0 or last_update_m > 12) {
        return ValidationResult.invalid(.dbf, "Invalid last-update month in dBASE header");
    }
    if (last_update_d == 0 or last_update_d > 31) {
        return ValidationResult.invalid(.dbf, "Invalid last-update day in dBASE header");
    }

    // Header and record lengths (little-endian u16 at offsets 8 and 10)
    if (data.len < 12) {
        return ValidationResult.invalidCode(.dbf, .truncated, "dBASE header");
    }
    const len_header = std.mem.readInt(u16, data[8..10], .little);
    const len_record = std.mem.readInt(u16, data[10..12], .little);

    if (len_header < 33) {
        return ValidationResult.invalid(.dbf, "dBASE header length too small (< 33)");
    }
    if (len_record == 0) {
        return ValidationResult.invalid(.dbf, "dBASE record length is zero");
    }
    if (data.len < len_header) {
        return ValidationResult.invalidCode(.dbf, .truncated, "dBASE header");
    }

    // Header terminator at len_header - 1 must be 0x0D
    if (data[len_header - 1] != 0x0D) {
        return ValidationResult.invalid(.dbf, "Missing dBASE header terminator (0x0D)");
    }

    // Determine the prefix size before field descriptors.
    // dBASE III uses a 32-byte fixed prefix (bytes 0-31).
    // The remaining bytes up to the terminator are 32-byte field descriptors.
    const prefix_size: u16 = 32;
    const fields_area: u16 = len_header - prefix_size - 1; // -1 for terminator byte

    // Must divide evenly into 32-byte descriptors
    if (fields_area % 32 != 0) {
        return ValidationResult.invalid(.dbf, "dBASE field descriptor area is not a multiple of 32 bytes");
    }
    const num_fields = fields_area / 32;

    // Parse and validate each 32-byte field descriptor
    var field_length_sum: u32 = 0;
    var field_offset: usize = prefix_size;
    var i: u32 = 0;
    while (i < num_fields) : (i += 1) {
        if (field_offset + 32 > data.len) {
            return ValidationResult.invalidCode(.dbf, .truncated, "dBASE field descriptors");
        }
        const field = data[field_offset .. field_offset + 32];
        // Field type at offset 11 within the descriptor
        const field_type = field[11];
        if (!isValidDbfFieldType(field_type)) {
            return ValidationResult.invalid(.dbf, "Invalid dBASE field type character");
        }
        // Field length at offset 16 within the descriptor
        const field_length = field[16];
        field_length_sum += field_length;
        field_offset += 32;
    }

    // Cross-validate: sum of field lengths + 1 (deletion flag) must equal len_record
    if (field_length_sum + 1 != len_record) {
        return ValidationResult.invalid(.dbf, "dBASE field length sum does not match record length");
    }

    // File size cross-validation (allow ±1 for optional 0x1A EOF marker)
    const num_records = std.mem.readInt(u32, data[4..8], .little);
    const expected_min: u64 = @as(u64, len_header) + @as(u64, num_records) * @as(u64, len_record);
    const expected_max: u64 = expected_min + 1; // optional 0x1A EOF byte
    if (data.len < expected_min or data.len > expected_max) {
        return ValidationResult.invalid(.dbf, "dBASE file size does not match header + records");
    }

    // Validate deletion flags on each record (first byte of each record: 0x20=active, 0x2A=deleted)
    var rec_idx: u32 = 0;
    while (rec_idx < num_records) : (rec_idx += 1) {
        const rec_start: usize = len_header + @as(usize, rec_idx) * @as(usize, len_record);
        if (rec_start >= data.len) break;
        const deletion_flag = data[rec_start];
        if (deletion_flag != 0x20 and deletion_flag != 0x2A) {
            return ValidationResult.invalid(.dbf, "Invalid dBASE record deletion flag (not 0x20 or 0x2A)");
        }
    }

    return ValidationResult.ok(.dbf);
}

/// File-source validator for dBASE .dbf files.
/// Reads the entire file into a buffer and delegates to validateDbfFromBuffer.
pub fn validateDbf(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.dbf, .failed_to_seek, "to start");

    // Read enough for header validation: up to 64KB covers almost any real .dbf
    var buf: [65536]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalidCode(.dbf, .failed_to_read, "dBASE file");
    };

    // For large files we only have a partial buffer — do header-only validation
    // (skip file-size cross-check for files > 64KB)
    if (bytes_read == buf.len) {
        // Large file: validate header structure only, skip record-count size check
        return validateDbfHeaderOnly(buf[0..bytes_read]);
    }

    return validateDbfFromBuffer(buf[0..bytes_read]);
}

/// Header-only validation for dBASE files larger than the read buffer.
/// Validates everything except the file-size cross-check.
fn validateDbfHeaderOnly(data: []const u8) ValidationResult {
    if (data.len < 13) return ValidationResult.invalidCode(.dbf, .file_too_small, "dBASE format");

    const version = data[0];
    if (!isValidDbfVersion(version)) return ValidationResult.invalidCode(.dbf, .invalid_magic, "dBASE version byte");

    const last_update_m = data[2];
    const last_update_d = data[3];
    if (last_update_m == 0 or last_update_m > 12) return ValidationResult.invalid(.dbf, "Invalid last-update month");
    if (last_update_d == 0 or last_update_d > 31) return ValidationResult.invalid(.dbf, "Invalid last-update day");

    const len_header = std.mem.readInt(u16, data[8..10], .little);
    const len_record = std.mem.readInt(u16, data[10..12], .little);
    if (len_header < 33) return ValidationResult.invalid(.dbf, "dBASE header length too small");
    if (len_record == 0) return ValidationResult.invalid(.dbf, "dBASE record length is zero");
    if (data.len < len_header) return ValidationResult.invalidCode(.dbf, .truncated, "dBASE header");

    if (data[len_header - 1] != 0x0D) return ValidationResult.invalid(.dbf, "Missing dBASE header terminator");

    const prefix_size: u16 = 32;
    const fields_area: u16 = len_header - prefix_size - 1;
    if (fields_area % 32 != 0) return ValidationResult.invalid(.dbf, "dBASE field area not multiple of 32");

    const num_fields = fields_area / 32;
    var field_length_sum: u32 = 0;
    var field_offset: usize = prefix_size;
    var i: u32 = 0;
    while (i < num_fields) : (i += 1) {
        if (field_offset + 32 > data.len) return ValidationResult.invalidCode(.dbf, .truncated, "dBASE field descriptors");
        const field = data[field_offset .. field_offset + 32];
        if (!isValidDbfFieldType(field[11])) return ValidationResult.invalid(.dbf, "Invalid dBASE field type");
        field_length_sum += field[16];
        field_offset += 32;
    }

    if (field_length_sum + 1 != len_record) return ValidationResult.invalid(.dbf, "dBASE field lengths do not match record length");

    return ValidationResult.okWithDepth(.dbf, .structural);
}

// ============================================================
// Tests
// ============================================================

test "MDB buffer validation: valid header" {
    // Construct a synthetic valid MDB header: 00 01 00 00 + "Standard Jet DB\x00"
    var header: [20]u8 = undefined;
    header[0] = 0x00;
    header[1] = 0x01;
    header[2] = 0x00;
    header[3] = 0x00;
    @memcpy(header[4..19], "Standard Jet DB");
    header[19] = 0x00;

    const result = validateMdbFromBuffer(&header);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mdb, result.format);
}

test "MDB buffer validation: wrong magic rejected" {
    var header: [20]u8 = undefined;
    header[0] = 0xFF;
    header[1] = 0xFF;
    header[2] = 0x00;
    header[3] = 0x00;
    @memcpy(header[4..19], "Standard Jet DB");
    header[19] = 0x00;

    const result = validateMdbFromBuffer(&header);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(FileFormat.mdb, result.format);
}

test "MDB buffer validation: wrong signature rejected" {
    var header: [20]u8 = undefined;
    header[0] = 0x00;
    header[1] = 0x01;
    header[2] = 0x00;
    header[3] = 0x00;
    @memcpy(header[4..19], "Standard ACE DB"); // Wrong sig (ACCDB not MDB)
    header[19] = 0x00;

    const result = validateMdbFromBuffer(&header);
    try testing.expect(!result.is_valid);
}

test "MDB buffer validation: too small rejected" {
    const tiny = [_]u8{ 0x00, 0x01, 0x00, 0x00 };
    const result = validateMdbFromBuffer(&tiny);
    try testing.expect(!result.is_valid);
}

test "ACCDB buffer validation: valid header" {
    var header: [20]u8 = undefined;
    header[0] = 0x00;
    header[1] = 0x01;
    header[2] = 0x00;
    header[3] = 0x00;
    @memcpy(header[4..19], "Standard ACE DB");
    header[19] = 0x00;

    const result = validateAccdbFromBuffer(&header);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.accdb, result.format);
}

test "ACCDB buffer validation: wrong signature rejected" {
    var header: [20]u8 = undefined;
    header[0] = 0x00;
    header[1] = 0x01;
    header[2] = 0x00;
    header[3] = 0x00;
    @memcpy(header[4..19], "Standard Jet DB"); // Wrong sig (MDB not ACCDB)
    header[19] = 0x00;

    const result = validateAccdbFromBuffer(&header);
    try testing.expect(!result.is_valid);
}

test "OLE2 structural: valid OLE2 header accepted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a synthetic 512-byte OLE2 header
    var header: [512]u8 = [_]u8{0} ** 512;
    // Magic: D0 CF 11 E0 A1 B1 1A E1
    @memcpy(header[0..8], &OLE2_MAGIC);
    // Minor version at 0x18 (e.g. 0x003E)
    std.mem.writeInt(u16, header[0x18..0x1A], 0x003E, .little);
    // Major version at 0x1A = 3
    std.mem.writeInt(u16, header[0x1A..0x1C], 3, .little);
    // Byte order at 0x1C = 0xFFFE
    std.mem.writeInt(u16, header[0x1C..0x1E], 0xFFFE, .little);
    // Sector size power at 0x1E = 9 (512 bytes)
    std.mem.writeInt(u16, header[0x1E..0x20], 9, .little);
    // Mini sector size power at 0x20 = 6 (64 bytes)
    std.mem.writeInt(u16, header[0x20..0x22], 6, .little);

    try tmp.dir.writeFile(.{ .sub_path = "test.ole2", .data = &header });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.ole2", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateOle2(&source, .doc);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.doc, result.format);
}

test "OLE2 structural: wrong magic rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var header: [512]u8 = [_]u8{0} ** 512;
    // Wrong magic
    @memcpy(header[0..8], &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    try tmp.dir.writeFile(.{ .sub_path = "test.ole2", .data = &header });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.ole2", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateOle2(&source, .doc);
    try testing.expect(!result.is_valid);
}

test "OLE2 structural: invalid major version rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var header: [512]u8 = [_]u8{0} ** 512;
    @memcpy(header[0..8], &OLE2_MAGIC);
    std.mem.writeInt(u16, header[0x18..0x1A], 0x003E, .little);
    std.mem.writeInt(u16, header[0x1A..0x1C], 99, .little); // Bad major version
    std.mem.writeInt(u16, header[0x1C..0x1E], 0xFFFE, .little);
    std.mem.writeInt(u16, header[0x1E..0x20], 9, .little);
    std.mem.writeInt(u16, header[0x20..0x22], 6, .little);

    try tmp.dir.writeFile(.{ .sub_path = "test.ole2", .data = &header });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.ole2", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateOle2(&source, .xls);
    try testing.expect(!result.is_valid);
}

test "SQLite structural: valid synthetic header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a minimal valid 4096-byte SQLite database (1 page)
    var page: [4096]u8 = [_]u8{0} ** 4096;
    // Magic "SQLite format 3\0"
    @memcpy(page[0..16], "SQLite format 3\x00");
    // Page size = 4096 big-endian
    std.mem.writeInt(u16, page[16..18], 4096, .big);
    // Write version = 1, Read version = 1
    page[18] = 1;
    page[19] = 1;
    // Reserved per page = 0 (byte 20)
    page[20] = 0;
    // Max embedded payload fraction = 64
    page[21] = 64;
    // Min embedded payload fraction = 32
    page[22] = 32;
    // Leaf payload fraction = 32
    page[23] = 32;
    // File change counter = 1 (bytes 24-27)
    std.mem.writeInt(u32, page[24..28], 1, .big);
    // Database size in pages = 1 (bytes 28-31)
    std.mem.writeInt(u32, page[28..32], 1, .big);
    // Schema format = 4 (bytes 44-47)
    std.mem.writeInt(u32, page[44..48], 4, .big);
    // Text encoding = 1 (UTF-8) (bytes 56-59)
    std.mem.writeInt(u32, page[56..60], 1, .big);
    // Reserved bytes 72-91 = 0 (already zeroed)
    // Version-valid-for = 1 (bytes 92-95, matches change counter)
    std.mem.writeInt(u32, page[92..96], 1, .big);
    // B-tree page type at offset 100: 13 = leaf table
    page[100] = 13;
    // Cell count = 0 (bytes 103-104)
    std.mem.writeInt(u16, page[103..105], 0, .big);
    // Cell content offset = 0x0FFF (near end of page) (bytes 105-106)
    std.mem.writeInt(u16, page[105..107], 0x0FFF, .big);

    try tmp.dir.writeFile(.{ .sub_path = "test.sqlite", .data = &page });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.sqlite", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateSqlite(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sqlite, result.format);
}

test "SQLite structural: invalid magic rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: [100]u8 = [_]u8{0} ** 100;
    @memcpy(data[0..16], "Not a SQLite DB\x00");

    try tmp.dir.writeFile(.{ .sub_path = "test.sqlite", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.sqlite", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateSqlite(&source);
    try testing.expect(!result.is_valid);
}

test "SQLite structural: invalid page size rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: [100]u8 = [_]u8{0} ** 100;
    @memcpy(data[0..16], "SQLite format 3\x00");
    // Bad page size: 777 (not power of 2)
    std.mem.writeInt(u16, data[16..18], 777, .big);

    try tmp.dir.writeFile(.{ .sub_path = "test.sqlite", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.sqlite", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateSqlite(&source);
    try testing.expect(!result.is_valid);
}

test "SQLite deep: ground truth chinook.sqlite" {
    const allocator = testing.allocator;

    std.fs.cwd().access("ground_truth_examples/sqlite/chinook.sqlite", .{}) catch return;

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/sqlite/chinook.sqlite") catch return;
    defer allocator.free(path);

    const result = validateSqliteDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sqlite, result.format);
    try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "SQLite structural: ground truth test_sample.sqlite" {
    var source = FileSource.open("ground_truth_examples/sqlite/test_sample.sqlite") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateSqlite(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.sqlite, result.format);
}

test "WordPerfect structural: valid synthetic header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Construct a minimal valid WordPerfect header
    var header: [32]u8 = [_]u8{0} ** 32;
    // Magic: FF 57 50 43
    header[0] = 0xFF;
    header[1] = 0x57;
    header[2] = 0x50;
    header[3] = 0x43;
    // Document area offset at bytes 4-7 (little endian, pointing within file)
    std.mem.writeInt(u32, header[4..8], 16, .little);
    // Product type = 1 (byte 8)
    header[8] = 1;
    // File type = 0x0A (WPD) (byte 9)
    header[9] = 0x0A;

    try tmp.dir.writeFile(.{ .sub_path = "test.wpd", .data = &header });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.wpd", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateWordPerfect(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wpd, result.format);
}

test "WordPerfect structural: wrong magic rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var header: [32]u8 = [_]u8{0} ** 32;
    // Wrong magic
    header[0] = 0x00;
    header[1] = 0x00;
    header[2] = 0x00;
    header[3] = 0x00;

    try tmp.dir.writeFile(.{ .sub_path = "test.wpd", .data = &header });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.wpd", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateWordPerfect(&source);
    try testing.expect(!result.is_valid);
}

test "WordPerfect structural: ground truth sample.wpd" {
    var source = FileSource.open("ground_truth_examples/wpd/sample.wpd") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateWordPerfect(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.wpd, result.format);
}

test "MDB structural: ground truth sample.mdb" {
    var source = FileSource.open("ground_truth_examples/mdb/sample.mdb") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateMdb(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.mdb, result.format);
}

test "ACCDB structural: ground truth sample.accdb" {
    var source = FileSource.open("ground_truth_examples/accdb/sample.accdb") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateAccdb(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.accdb, result.format);
}

test "OLE2 subformat detection: ground truth DOC dispatches correctly" {
    var source = FileSource.open("ground_truth_examples/ole2/sample.doc") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const subformat = detectOle2Subformat(&source);
    try testing.expectEqual(FileFormat.doc, subformat);
}

test "OLE2 subformat detection: ground truth XLS dispatches correctly" {
    var source = FileSource.open("ground_truth_examples/ole2/sample.xls") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const subformat = detectOle2Subformat(&source);
    try testing.expectEqual(FileFormat.xls, subformat);
}

test "OLE2 subformat detection: ground truth PPT dispatches correctly" {
    var source = FileSource.open("ground_truth_examples/ole2/sample.ppt") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const subformat = detectOle2Subformat(&source);
    try testing.expectEqual(FileFormat.ppt, subformat);
}

test "readVarint: single byte value" {
    const data = [_]u8{0x05}; // value 5, high bit clear = 1 byte
    const result = readVarint(&data, 0, 1);
    try testing.expectEqual(@as(u64, 5), result.value);
    try testing.expectEqual(@as(u32, 1), result.bytes_read);
}

test "readVarint: multi-byte value" {
    const data = [_]u8{ 0x81, 0x01 }; // 0x81 -> high bit set, 0x01 -> high bit clear
    // result = (1 << 7) | 1 = 129
    const result = readVarint(&data, 0, 2);
    try testing.expectEqual(@as(u64, 129), result.value);
    try testing.expectEqual(@as(u32, 2), result.bytes_read);
}

test "readVarint: out of bounds returns zero bytes_read" {
    const data = [_]u8{0x05};
    const result = readVarint(&data, 5, 1); // pos > limit
    try testing.expectEqual(@as(u32, 0), result.bytes_read);
}

// =========================================================
// dBASE (.dbf) buffer validation tests
// =========================================================

/// Build a minimal valid dBASE III DBF buffer in memory.
/// No field descriptors — header is 33 bytes (32-byte prefix + 0x0D terminator).
/// len_record = 1 (deletion flag only). num_records = 0.
fn makeMinimalDbf(buf: *[33]u8) void {
    @memset(buf, 0);
    buf[0] = 0x03; // version: dBASE III
    buf[1] = 25; // last_update year (1925)
    buf[2] = 1; // last_update month
    buf[3] = 1; // last_update day
    // num_records = 0 (little-endian u32 at offsets 4-7, already 0)
    // len_header = 33 (little-endian u16 at offsets 8-9)
    buf[8] = 33;
    buf[9] = 0;
    // len_record = 1 (little-endian u16 at offsets 10-11)
    buf[10] = 1;
    buf[11] = 0;
    // Terminator at len_header - 1 = 32
    buf[32] = 0x0D;
}

test "DBF buffer validation: minimal valid file accepted" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dbf, result.format);
}

test "DBF buffer validation: too small rejected" {
    const buf = [_]u8{0x03} ** 10;
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: invalid version byte rejected" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    buf[0] = 0xFF; // not a valid dBASE version
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: invalid month rejected" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    buf[2] = 13; // month > 12
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: invalid day rejected" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    buf[3] = 0; // day == 0
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: missing header terminator rejected" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    buf[32] = 0x00; // corrupt terminator
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: zero record length rejected" {
    var buf: [33]u8 = undefined;
    makeMinimalDbf(&buf);
    buf[10] = 0; // len_record = 0
    buf[11] = 0;
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: with one field — lengths must cross-validate" {
    // Header: 32-byte prefix + 32-byte field descriptor + 0x0D terminator = 65 bytes
    // Field: type='C', field_length=10 -> len_record must be 11 (1 flag + 10)
    // num_records = 1, so file = 65 + 11 = 76 bytes
    var buf: [76]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0x03;
    buf[1] = 25;
    buf[2] = 3;
    buf[3] = 15;
    // num_records = 1
    buf[4] = 1;
    // len_header = 65
    buf[8] = 65;
    buf[9] = 0;
    // len_record = 11
    buf[10] = 11;
    buf[11] = 0;
    // Field descriptor at offset 32: name="TEST\0..." type='C' at [11], length=10 at [16]
    buf[32] = 'T';
    buf[33] = 'E';
    buf[34] = 'S';
    buf[35] = 'T';
    buf[43] = 'C'; // field type at descriptor offset 11
    buf[48] = 10; // field length at descriptor offset 16
    // Header terminator at len_header-1 = 64
    buf[64] = 0x0D;
    // Record at offset 65: deletion flag = 0x20 (active), then 10 bytes data
    buf[65] = 0x20;
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(result.is_valid);
}

test "DBF buffer validation: field length mismatch rejected" {
    // Same as above but len_record is wrong (say 15 instead of 11)
    var buf: [76]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0x03;
    buf[1] = 25;
    buf[2] = 3;
    buf[3] = 15;
    buf[4] = 1;
    buf[8] = 65;
    buf[9] = 0;
    buf[10] = 15; // len_record = 15, but field sum = 10 -> should be 11
    buf[11] = 0;
    buf[43] = 'C';
    buf[48] = 10;
    buf[64] = 0x0D;
    buf[65] = 0x20;
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: invalid field type rejected" {
    var buf: [76]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0x03;
    buf[1] = 25;
    buf[2] = 3;
    buf[3] = 15;
    buf[4] = 1;
    buf[8] = 65;
    buf[9] = 0;
    buf[10] = 11;
    buf[11] = 0;
    buf[43] = 0x01; // invalid field type (non-ASCII)
    buf[48] = 10;
    buf[64] = 0x0D;
    buf[65] = 0x20;
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF buffer validation: invalid deletion flag rejected" {
    var buf: [76]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0x03;
    buf[1] = 25;
    buf[2] = 3;
    buf[3] = 15;
    buf[4] = 1;
    buf[8] = 65;
    buf[9] = 0;
    buf[10] = 11;
    buf[11] = 0;
    buf[43] = 'C';
    buf[48] = 10;
    buf[64] = 0x0D;
    buf[65] = 0xFF; // invalid deletion flag (not 0x20 or 0x2A)
    const result = validateDbfFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "DBF structural: ground truth sample.dbf from shapefile" {
    // sample.dbf lives alongside the shapefile ground truth
    const path = "ground_truth_examples/shapefile/companions/sample.dbf";
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer file.close();
    var src = @import("file_source.zig").FileSource.fromFile(file);
    const result = validateDbf(&src);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.dbf, result.format);
}

test "serialTypeContentSize: standard types" {
    try testing.expectEqual(@as(u64, 0), serialTypeContentSize(0)); // NULL
    try testing.expectEqual(@as(u64, 1), serialTypeContentSize(1)); // int8
    try testing.expectEqual(@as(u64, 2), serialTypeContentSize(2)); // int16
    try testing.expectEqual(@as(u64, 4), serialTypeContentSize(4)); // int32
    try testing.expectEqual(@as(u64, 8), serialTypeContentSize(6)); // int64
    try testing.expectEqual(@as(u64, 8), serialTypeContentSize(7)); // float64
    try testing.expectEqual(@as(u64, 0), serialTypeContentSize(8)); // integer 0
    try testing.expectEqual(@as(u64, 0), serialTypeContentSize(9)); // integer 1
    // Blob: (14 - 12) / 2 = 1
    try testing.expectEqual(@as(u64, 1), serialTypeContentSize(14));
    // Text: (15 - 13) / 2 = 1
    try testing.expectEqual(@as(u64, 1), serialTypeContentSize(15));
}
