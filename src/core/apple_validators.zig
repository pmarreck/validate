//! Apple/macOS format validators
//!
//! Extracted from format_validation.zig. Contains validation for Apple-specific
//! formats: Property Lists (binary + XML), DS_Store, Spotlight, AppleDouble,
//! resource forks, and legacy word processors (ClarisWorks, MacWrite).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const DoctypeStrippedResult = format_validation.DoctypeStrippedResult;
const stripDoctypeDeclaration = format_validation.stripDoctypeDeclaration;
const errmsg = @import("error_messages.zig");

const xml = @import("xml");

const testing = std.testing;

/// Maximum text file size for XML plist validation (1 GB).
const max_text_file_size: usize = 1024 * 1024 * 1024;

// ============ Resource Fork Detection (macOS) ============

/// Check if a file has a non-empty resource fork.
/// On non-macOS systems, always returns false.
pub fn hasResourceFork(path: []const u8) bool {
	if (comptime builtin.os.tag != .macos) {
		return false;
	}

	// Build resource fork path: path/..namedfork/rsrc
	var rsrc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const rsrc_path = std.fmt.bufPrint(&rsrc_path_buf, "{s}/..namedfork/rsrc", .{path}) catch return false;

	// Try to open the resource fork - handle both absolute and relative paths
	const file = if (std.fs.path.isAbsolute(rsrc_path))
		std.fs.cwd().openFile(rsrc_path, .{}) catch return false
	else
		std.fs.cwd().openFile(rsrc_path, .{}) catch return false;
	defer file.close();

	const stat = file.stat() catch return false;
	return stat.size > 0;
}

/// Get the size of a file's resource fork (0 if none or not on macOS).
pub fn getResourceForkSize(path: []const u8) u64 {
	if (comptime builtin.os.tag != .macos) {
		return 0;
	}

	var rsrc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const rsrc_path = std.fmt.bufPrint(&rsrc_path_buf, "{s}/..namedfork/rsrc", .{path}) catch return 0;

	// Handle both absolute and relative paths
	const file = if (std.fs.path.isAbsolute(rsrc_path))
		std.fs.cwd().openFile(rsrc_path, .{}) catch return 0
	else
		std.fs.cwd().openFile(rsrc_path, .{}) catch return 0;
	defer file.close();

	const stat = file.stat() catch return 0;
	return stat.size;
}

/// Read the contents of a file's resource fork.
/// Caller owns the returned slice.
pub fn readResourceFork(allocator: Allocator, path: []const u8) !?[]u8 {
	if (comptime builtin.os.tag != .macos) {
		return null;
	}

	var rsrc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const rsrc_path = std.fmt.bufPrint(&rsrc_path_buf, "{s}/..namedfork/rsrc", .{path}) catch return null;

	const file = std.fs.cwd().openFile(rsrc_path, .{}) catch return null;
	defer file.close();

	const stat = file.stat() catch return null;
	if (stat.size == 0) return null;

	const data = try allocator.alloc(u8, stat.size);
	errdefer allocator.free(data);

	const bytes_read = try file.readAll(data);
	if (bytes_read != stat.size) {
		allocator.free(data);
		return null;
	}

	return data;
}

/// Build the resource fork path for a file.
pub fn getResourceForkPath(path: []const u8, buf: []u8) ?[]const u8 {
	if (comptime builtin.os.tag != .macos) {
		return null;
	}
	return std.fmt.bufPrint(buf, "{s}/..namedfork/rsrc", .{path}) catch null;
}

// ============ AppleDouble Detection (._filename) ============

/// AppleDouble magic signature
pub const APPLEDOUBLE_MAGIC: u32 = 0x00051607;
pub const APPLESINGLE_MAGIC: u32 = 0x00051600;

/// Check if data starts with AppleDouble header.
pub fn isAppleDouble(data: []const u8) bool {
	if (data.len < 4) return false;
	const magic = std.mem.readInt(u32, data[0..4], .big);
	return magic == APPLEDOUBLE_MAGIC or magic == APPLESINGLE_MAGIC;
}

/// Validate AppleDouble file structure.
pub fn validateAppleDouble(file: *FileSource) ValidationResult {
	var header: [26]u8 = undefined;
	const bytes_read = file.read(&header) catch {
		return ValidationResult.invalidCode(.apple_double, .failed_to_read, "AppleDouble header");
	};

	if (bytes_read < 26) {
		return ValidationResult.invalidCode(.apple_double, .file_too_small, "AppleDouble");
	}

	// Check magic
	const magic = std.mem.readInt(u32, header[0..4], .big);
	if (magic != APPLEDOUBLE_MAGIC and magic != APPLESINGLE_MAGIC) {
		return ValidationResult.invalidCode(.apple_double, .invalid_signature, "AppleDouble");
	}

	// Check version (should be 0x00020000)
	const version = std.mem.readInt(u32, header[4..8], .big);
	if (version != 0x00020000) {
		return ValidationResult.invalidCode(.apple_double, .unsupported, "AppleDouble version");
	}

	// Number of entries (bytes 24-25)
	const num_entries = std.mem.readInt(u16, header[24..26], .big);
	if (num_entries == 0 or num_entries > 100) {
		return ValidationResult.invalidCode(.apple_double, .invalid_value, "AppleDouble entry count");
	}

	return ValidationResult.ok(.apple_double);
}

// ============ Legacy Word Processor Validators ============

/// Validate ClarisWorks/AppleWorks document (best effort).
/// ClarisWorks uses a proprietary format with various magic bytes depending on version.
pub fn validateClarisWorks(file: *FileSource) ValidationResult {
	var header: [32]u8 = undefined;
	const bytes_read = file.read(&header) catch {
		return ValidationResult.invalidCode(.cwk, .failed_to_read, "ClarisWorks header");
	};

	if (bytes_read < 8) {
		return ValidationResult.invalidCode(.cwk, .file_too_small, "ClarisWorks");
	}

	// ClarisWorks/AppleWorks has multiple magic signatures depending on version
	// Common patterns:
	// - BOBO (0x424F424F) at start or offset 4
	// - Version-specific headers
	if (std.mem.eql(u8, header[0..4], "BOBO") or
		std.mem.eql(u8, header[4..8], "BOBO"))
	{
		// ClarisWorks format is obsolete and undocumented - magic verified only
		return ValidationResult.structuralOnly(.cwk);
	}

	// AppleWorks 6 uses different magic
	if (header[0] == 0x07 and header[1] == 0x04) {
		return ValidationResult.structuralOnly(.cwk);
	}

	return ValidationResult.invalid(.cwk, "Unrecognized ClarisWorks format");
}

/// Validate MacWrite document (best effort).
/// MacWrite has evolved through several versions with different formats.
pub fn validateMacWrite(file: *FileSource) ValidationResult {
	var header: [16]u8 = undefined;
	const bytes_read = file.read(&header) catch {
		return ValidationResult.invalidCode(.mwd, .failed_to_read, "MacWrite header");
	};

	if (bytes_read < 8) {
		return ValidationResult.invalidCode(.mwd, .file_too_small, "MacWrite");
	}

	// MacWrite II uses version bytes at offset 0
	// Common values: 0x0003, 0x0006
	// MacWrite format is obsolete and undocumented - magic/version verified only
	const version = std.mem.readInt(u16, header[0..2], .big);
	if (version == 0x0003 or version == 0x0006 or version == 0x0004) {
		return ValidationResult.structuralOnly(.mwd);
	}

	// MacWrite Pro has different magic
	if (std.mem.eql(u8, header[0..4], "MWPR")) {
		return ValidationResult.structuralOnly(.mwd);
	}

	// Accept any reasonable-looking MacWrite file given it's archival
	// Classic Mac files often lack clear signatures
	if (bytes_read >= 4) {
		return ValidationResult.structuralOnly(.mwd);
	}

	return ValidationResult.invalid(.mwd, "Unrecognized MacWrite format");
}

// ============ Apple Property List (plist) Validation ============

/// Validate Apple Property List files (XML or binary format).
pub fn validatePlist(file: *FileSource) ValidationResult {
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.plist, .failed_to_stat, "file");
	};

	if (file_size < 8) {
		return ValidationResult.invalidCode(.plist, .file_too_small, "plist format");
	}

	// Read header to determine format
	var header: [16]u8 = undefined;
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.plist, .failed_to_read, "header");
	};

	if (bytes_read < 8) {
		return ValidationResult.invalidCode(.plist, .truncated, "header");
	}

	// Check for binary plist magic: "bplist00" or "bplist01"
	if (std.mem.eql(u8, header[0..6], "bplist")) {
		return validateBinaryPlist(file, file_size);
	}

	// Otherwise, assume XML plist
	return validateXmlPlist(file, file_size);
}

/// Validate macOS .DS_Store file (Desktop Services Store)
/// DS_Store files store custom folder attributes (icon positions, view settings, etc.)
/// Format: 0x00000001 (big-endian) + "Bud1" magic + allocator + B-tree structure
pub fn validateDsStore(file: *FileSource) ValidationResult {
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.ds_store, .failed_to_stat, "file");
	};

	// Minimum size: header (32 bytes minimum)
	if (file_size < 32) {
		return ValidationResult.invalidCode(.ds_store, .file_too_small, "DS_Store format");
	}

	// Read header
	var header: [32]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.ds_store, .failed_to_seek, "to start");
	};
	const bytes_read = file.readAll(&header) catch {
		return ValidationResult.invalidCode(.ds_store, .failed_to_read, "header");
	};

	if (bytes_read < 32) {
		return ValidationResult.invalidCode(.ds_store, .truncated, "header");
	}

	// Verify magic: 0x00000001 (big-endian) + "Bud1"
	if (!std.mem.eql(u8, header[0..4], &[_]u8{ 0x00, 0x00, 0x00, 0x01 })) {
		return ValidationResult.invalidCode(.ds_store, .invalid_magic_number, "DS_Store");
	}
	if (!std.mem.eql(u8, header[4..8], "Bud1")) {
		return ValidationResult.invalidCode(.ds_store, .invalid_signature, "DS_Store Bud1");
	}

	// Header structure (all big-endian):
	// 0-3: magic (0x00000001)
	// 4-7: "Bud1"
	// 8-11: offset to bookkeeping section
	// 12-15: size of bookkeeping section
	// 16-19: offset to bookkeeping section (redundant copy)
	// 20-31: additional header fields

	const bookkeeping_offset = std.mem.readInt(u32, header[8..12], .big);
	const bookkeeping_size = std.mem.readInt(u32, header[12..16], .big);
	const bookkeeping_offset_copy = std.mem.readInt(u32, header[16..20], .big);

	// Sanity checks
	if (bookkeeping_offset > file_size) {
		return ValidationResult.invalidCodeMsg(.ds_store, .exceeds_bounds, "Bookkeeping offset", "Bookkeeping offset exceeds file size");
	}
	if (bookkeeping_size > file_size) {
		return ValidationResult.invalidCodeMsg(.ds_store, .exceeds_bounds, "Bookkeeping size", "Bookkeeping size exceeds file size");
	}
	if (bookkeeping_offset != bookkeeping_offset_copy) {
		// The two offset fields should match - if not, file might be corrupted
		return ValidationResult.okWithWarning(.ds_store, "Bookkeeping offset mismatch (possible corruption)");
	}

	// Read bookkeeping section header
	// Bookkeeping section structure:
	// 0-3: unknown (usually 0)
	// 4-7: number of block allocations
	// 8+: block allocation table entries

	if (bookkeeping_offset + 8 > file_size) {
		return ValidationResult.invalid(.ds_store, "Bookkeeping section truncated");
	}

	file.seekTo(bookkeeping_offset) catch {
		return ValidationResult.invalidCode(.ds_store, .failed_to_seek, "to bookkeeping");
	};

	var bk_header: [16]u8 = undefined;
	const bk_read = file.read(&bk_header) catch {
		return ValidationResult.invalidCode(.ds_store, .failed_to_read, "bookkeeping");
	};

	if (bk_read < 8) {
		return ValidationResult.invalidCode(.ds_store, .truncated, "bookkeeping header");
	}

	// Block allocation count at offset 4
	const num_allocations = std.mem.readInt(u32, bk_header[4..8], .big);

	// Sanity check - a DS_Store shouldn't have millions of allocations
	if (num_allocations > 100000) {
		return ValidationResult.invalid(.ds_store, "Unreasonably large allocation count");
	}

	// Each allocation entry is 4 bytes, so verify we have enough room
	const alloc_table_size = num_allocations * 4;
	if (bookkeeping_offset + 8 + alloc_table_size > file_size) {
		return ValidationResult.invalid(.ds_store, "Allocation table extends beyond file");
	}

	// No CRC/hash — header + allocation table bounds check only
	return ValidationResult.okWithDepth(.ds_store, .structural);
}

/// Validate macOS Spotlight index file (proprietary Apple format)
/// Magic: "8tsd" at offset 0. Deep validation is not possible since the format
/// is proprietary and undocumented, so we verify the magic and return structural.
pub fn validateSpotlight(file: *FileSource) ValidationResult {
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.spotlight, .failed_to_seek, "in Spotlight file");
	};

	var header: [8]u8 = undefined;
	const bytes_read = file.read(&header) catch {
		return ValidationResult.invalidCode(.spotlight, .failed_to_read, "header");
	};
	if (bytes_read < 8) {
		return ValidationResult.invalidCode(.spotlight, .truncated, "header");
	}

	// Verify "8tsd" magic
	if (!std.mem.eql(u8, header[0..4], "8tsd")) {
		return ValidationResult.invalidCode(.spotlight, .invalid_value, "magic bytes");
	}

	// Proprietary format - structural validation only (magic verified)
	return ValidationResult.structuralOnly(.spotlight);
}

/// Validate binary plist format (bplist00/bplist01)
pub fn validateBinaryPlist(file: *FileSource, file_size: u64) ValidationResult {
	// Binary plist structure:
	// - Header: "bplist00" or "bplist01" (8 bytes)
	// - Object table (variable)
	// - Offset table (variable)
	// - Trailer (32 bytes at end of file)

	if (file_size < 40) { // 8 (header) + 32 (trailer) minimum
		return ValidationResult.invalid(.plist, "Binary plist too small");
	}

	// Read trailer (last 32 bytes)
	file.seekTo(file_size - 32) catch {
		return ValidationResult.invalidCode(.plist, .failed_to_seek, "to trailer");
	};

	var trailer: [32]u8 = undefined;
	const trailer_bytes = file.readAll(&trailer) catch {
		return ValidationResult.invalidCode(.plist, .failed_to_read, "trailer");
	};

	if (trailer_bytes < 32) {
		return ValidationResult.invalidCode(.plist, .truncated, "trailer");
	}

	// Trailer format:
	// 0-5: unused (padding)
	// 6: offset int size (1, 2, 4, or 8)
	// 7: object ref size (1, 2, 4, or 8)
	// 8-15: number of objects (big-endian u64)
	// 16-23: top object index (big-endian u64)
	// 24-31: offset table start (big-endian u64)

	const offset_int_size = trailer[6];
	const object_ref_size = trailer[7];

	// Validate sizes
	if (offset_int_size == 0 or offset_int_size > 8 or
		(offset_int_size != 1 and offset_int_size != 2 and offset_int_size != 4 and offset_int_size != 8))
	{
		return ValidationResult.invalidCode(.plist, .invalid_value, "offset int size in trailer");
	}

	if (object_ref_size == 0 or object_ref_size > 8 or
		(object_ref_size != 1 and object_ref_size != 2 and object_ref_size != 4 and object_ref_size != 8))
	{
		return ValidationResult.invalidCode(.plist, .invalid_value, "object ref size in trailer");
	}

	// Read number of objects
	const num_objects = std.mem.readInt(u64, trailer[8..16], .big);

	// Sanity check - plist shouldn't have billions of objects
	if (num_objects > 10_000_000) {
		return ValidationResult.invalidCode(.plist, .too_many, "objects (likely corrupt)");
	}

	// Read offset table start
	const offset_table_start = std.mem.readInt(u64, trailer[24..32], .big);

	// Validate offset table location
	if (offset_table_start < 8) {
		return ValidationResult.invalidCode(.plist, .invalid_value, "offset table start");
	}

	if (offset_table_start >= file_size - 32) {
		return ValidationResult.invalid(.plist, "Offset table overlaps trailer");
	}

	// Calculate expected offset table size
	const offset_table_size = num_objects * offset_int_size;
	const expected_end = offset_table_start + offset_table_size;

	if (expected_end > file_size - 32) {
		return ValidationResult.invalidCodeMsg(.plist, .exceeds_bounds, "Offset table", "Offset table exceeds file bounds");
	}

	// No CRC/hash — binary plist trailer parsing only
	return ValidationResult.okWithDepth(.plist, .structural);
}

/// Validate XML plist format
pub fn validateXmlPlist(file: *FileSource, file_size: u64) ValidationResult {
	// For XML plists, delegate to XML validator but verify plist structure
	if (file_size > max_text_file_size) {
		return ValidationResult.invalid(.plist, "XML plist too large (>1GB)");
	}

	// Get file content — zero-copy from mmap when available
	var heap_buf: ?[]u8 = null;
	defer if (heap_buf) |buf| std.heap.page_allocator.free(buf);
	const data: []const u8 = if (file.getMappedSlice()) |mapped|
		mapped
	else blk: {
		file.seekTo(0) catch return ValidationResult.invalidCode(.plist, .failed_to_seek, "to start");
		const buf = std.heap.page_allocator.alloc(u8, @intCast(file_size)) catch {
			return ValidationResult.invalidCode(.plist, .failed_to_allocate, "memory");
		};
		heap_buf = buf;
		const n = file.readAll(buf) catch return ValidationResult.invalidCode(.plist, .failed_to_read, "file");
		if (n == 0) return ValidationResult.invalidCode(.plist, .empty, "plist file");
		break :blk buf[0..n];
	};

	// Strip DOCTYPE if present (use same logic as XML validator)
	const preprocessed = stripDoctypeDeclaration(std.heap.page_allocator, data);
	defer if (preprocessed.allocated) std.heap.page_allocator.free(preprocessed.data);

	// Parse with zig-xml
	var static_reader: xml.Reader.Static = .init(std.heap.page_allocator, preprocessed.data, .{});
	defer static_reader.deinit();
	const reader = &static_reader.interface;

	var found_plist_root = false;
	var depth: u32 = 0;

	while (true) {
		const node = reader.read() catch |err| {
			switch (err) {
				error.MalformedXml => {
					return ValidationResult.invalid(.plist, "Malformed XML in plist");
				},
				error.OutOfMemory => return ValidationResult.invalidCode(.plist, .out_of_memory, "for plist"),
				error.ReadFailed => return ValidationResult.invalid(.plist, "Read failed"),
			}
		};

		switch (node) {
			.eof => break,
			.element_start => {
				const name = reader.elementName();
				if (depth == 0 and std.mem.eql(u8, name, "plist")) {
					found_plist_root = true;
				}
				depth += 1;
			},
			.element_end => {
				if (depth > 0) depth -= 1;
			},
			else => {},
		}
	}

	if (!found_plist_root) {
		return ValidationResult.invalidCode(.plist, .missing, "<plist> root element");
	}

	// DOCTYPE is ubiquitous in Apple plists - don't warn about it
	_ = preprocessed.had_doctype;

	// No CRC/hash — XML parsing only (no integrity mechanism)
	return ValidationResult.okWithDepth(.plist, .structural);
}

// ============ Tests ============

test "hasResourceFork returns false on non-macOS or for files without resource forks" {
	// On non-macOS, should always return false
	// On macOS with normal files, should return false
	const result = hasResourceFork("/tmp/nonexistent_file_for_test");
	try std.testing.expect(!result);
}

test "getResourceForkSize returns 0 for files without resource forks" {
	const size = getResourceForkSize("/tmp/nonexistent_file_for_test");
	try std.testing.expectEqual(@as(u64, 0), size);
}

test "isAppleDouble detects AppleDouble magic" {
	const appledouble = [_]u8{ 0x00, 0x05, 0x16, 0x07, 0x00, 0x00 };
	try std.testing.expect(isAppleDouble(&appledouble));

	const applesingle = [_]u8{ 0x00, 0x05, 0x16, 0x00, 0x00, 0x00 };
	try std.testing.expect(isAppleDouble(&applesingle));
}

test "isAppleDouble rejects non-AppleDouble data" {
	const not_appledouble = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
	try std.testing.expect(!isAppleDouble(&not_appledouble));
}
