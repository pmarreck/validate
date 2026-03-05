//! Document format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for document formats: SQLite, OLE2 (DOC/XLS/PPT), WordPerfect, MDB, ACCDB.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const findInBuffer = format_validation.findInBuffer;

const ole2_validator = @import("ole2_validator.zig");
const word_doc_validator = @import("word_doc_validator.zig");
const errmsg = @import("error_messages.zig");

const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

const testing = std.testing;

// ============ Microsoft Access Database Validators ============

/// Validate Microsoft Access MDB file structure (Access 97-2003).
/// MDB files have magic bytes 00 01 00 00 followed by "Standard Jet DB" at offset 4.
pub fn validateMdb(file: std.fs.File) ValidationResult {
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
pub fn validateAccdb(file: std.fs.File) ValidationResult {
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
pub fn validateMdbDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.mdb, .failed_to_open, "MDB file");
    };
    defer file.close();

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
pub fn validateAccdbDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.accdb, .failed_to_open, "ACCDB file");
    };
    defer file.close();

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
pub fn validateOle2(file: std.fs.File, format: FileFormat) ValidationResult {
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

/// Detect specific OLE2 subformat (DOC, XLS, PPT) by examining directory entries.
/// OLE2 stores stream names as UTF-16LE in directory entry structures.
pub fn detectOle2Subformat(file: std.fs.File) FileFormat {
    // First try reading from the start (works for small files)
    var buffer: [65536]u8 = undefined;
    file.seekTo(0) catch return .doc;
    const bytes_read = file.read(&buffer) catch return .doc;

    // Stream names in OLE2 are stored as UTF-16LE in 64-byte directory entries
    // Known stream names for each format
    const workbook_utf16 = [_]u8{ 'W', 0, 'o', 0, 'r', 0, 'k', 0, 'b', 0, 'o', 0, 'o', 0, 'k', 0 };
    const book_utf16 = [_]u8{ 'B', 0, 'o', 0, 'o', 0, 'k', 0 };
    const ppt_utf16 = [_]u8{ 'P', 0, 'o', 0, 'w', 0, 'e', 0, 'r', 0, 'P', 0, 'o', 0, 'i', 0, 'n', 0, 't', 0 };
    const word_utf16 = [_]u8{ 'W', 0, 'o', 0, 'r', 0, 'd', 0, 'D', 0, 'o', 0, 'c', 0, 'u', 0, 'm', 0, 'e', 0, 'n', 0, 't', 0 };

    // Check initial buffer
    if (findInBuffer(&buffer, bytes_read, &workbook_utf16) or findInBuffer(&buffer, bytes_read, &book_utf16)) {
        return .xls;
    }
    if (findInBuffer(&buffer, bytes_read, &ppt_utf16)) {
        return .ppt;
    }
    if (findInBuffer(&buffer, bytes_read, &word_utf16)) {
        return .doc;
    }

    // For larger files, read the directory sector from the OLE2 header
    // Header at offset 0x30 contains the first directory sector ID (little-endian u32)
    if (bytes_read >= 0x34) {
        const sector_size: u64 = blk: {
            // Sector size shift is at offset 0x1E (typically 9 for 512 bytes)
            const shift = @as(u6, @intCast(buffer[0x1E]));
            break :blk @as(u64, 1) << shift;
        };
        const dir_sector_id = std.mem.readInt(u32, buffer[0x30..0x34], .little);
        if (dir_sector_id != 0xFFFFFFFE and dir_sector_id != 0xFFFFFFFF) {
            // Calculate directory offset: header (512) + sector_id * sector_size
            const dir_offset = 512 + @as(u64, dir_sector_id) * sector_size;
            file.seekTo(dir_offset) catch return .doc;
            var dir_buffer: [65536]u8 = undefined;
            const dir_read = file.read(&dir_buffer) catch return .doc;

            if (findInBuffer(&dir_buffer, dir_read, &workbook_utf16) or findInBuffer(&dir_buffer, dir_read, &book_utf16)) {
                return .xls;
            }
            if (findInBuffer(&dir_buffer, dir_read, &ppt_utf16)) {
                return .ppt;
            }
            if (findInBuffer(&dir_buffer, dir_read, &word_utf16)) {
                return .doc;
            }
        }
    }

    return .doc; // Default fallback
}

// ============ WordPerfect Validator ============

/// Validate WordPerfect document structure.
pub fn validateWordPerfect(file: std.fs.File) ValidationResult {
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

/// Validate SQLite database file structure.
pub fn validateSqlite(file: std.fs.File) ValidationResult {
    return validateSqliteWithOptions(file, false);
}

pub fn validateSqliteWithOptions(file: std.fs.File, skip_magic: bool) ValidationResult {
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

    // File change counter (bytes 24-27) and schema cookie (bytes 40-43) are informational

    // Database size in pages (bytes 28-31, big-endian)
    const db_page_count = std.mem.readInt(u32, header[28..32], .big);

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
    const result = ole2_validator.validateOle2Deep(allocator, path);
    if (!result.valid) {
        return ValidationResult.invalidWithDepth(format, result.error_message orelse "OLE2 validation failed", .structural);
    }

    // For .doc, go deeper: parse FIB + cross-validate Table stream
    if (format == .doc) {
        return word_doc_validator.validateDocDeep(allocator, path);
    }

    // XLS, PPT: still structural-only for now
    return ValidationResult.okWithDepth(format, .structural);
}
