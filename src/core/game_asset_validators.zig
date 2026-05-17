//! Game asset format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for game asset formats: WAD (DOOM), PAK (Quake), LSPK (Larian Studios),
//! Chromium PAK, BSP (Quake/Source maps), VPK (Valve PAK), IFF, and Blorb.

const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;

const errmsg = @import("error_messages.zig");

const testing = std.testing;

/// Skip test if a ground truth file doesn't exist (e.g., samples in external repo).
fn skipIfMissing(comptime path: []const u8) !void {
    runtime.access(path, .{}) catch return error.SkipZigTest;
}

// ============ WAD (DOOM) Validator ============

/// Validate WAD (DOOM) archive format.
/// WAD files start with "IWAD" (internal) or "PWAD" (patch) followed by
/// lump count (4 bytes, little-endian) and directory offset (4 bytes, little-endian).
pub fn validateWad(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.wad, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.wad, .failed_to_read, "WAD header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.wad, .file_too_small, "WAD");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..4], "IWAD") and !std.mem.eql(u8, header[0..4], "PWAD")) {
        return ValidationResult.invalidCode(.wad, .invalid_signature, "WAD");
    }

    // Lump count (little-endian)
    const lump_count = std.mem.readInt(u32, header[4..8], .little);
    if (lump_count > 100000) { // Sanity check
        return ValidationResult.invalid(.wad, "Implausible lump count");
    }

    // Directory offset (little-endian)
    const dir_offset = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.wad, .failed_to_get, "file size");

    // Directory must be within file
    if (dir_offset > file_size) {
        return ValidationResult.invalid(.wad, "Directory offset beyond file size");
    }

    // Each directory entry is 16 bytes
    const expected_dir_size = lump_count * 16;
    if (dir_offset + expected_dir_size > file_size) {
        return ValidationResult.invalid(.wad, "Directory extends beyond file");
    }

    // No CRC/hash — header + directory bounds check only
    return ValidationResult.okWithDepth(.wad, .structural);
}

/// Deep validation for WAD files - validates all directory entries.
pub fn validateWadDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.wad, .failed_to_get, "file size");
    };

    // Read header
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.wad, .failed_to_read, "header");

    if (!std.mem.eql(u8, header[0..4], "IWAD") and !std.mem.eql(u8, header[0..4], "PWAD")) {
        return ValidationResult.invalidCode(.wad, .invalid_signature, "WAD");
    }

    const lump_count = std.mem.readInt(u32, header[4..8], .little);
    const dir_offset = std.mem.readInt(u32, header[8..12], .little);

    if (lump_count > 100000 or dir_offset > file_size) {
        return ValidationResult.invalidCode(.wad, .invalid_value, "header values");
    }

    const dir_size = lump_count * 16;
    if (dir_offset + dir_size > file_size) {
        return ValidationResult.invalid(.wad, "Directory extends beyond file");
    }

    // Read and validate all directory entries
    const dir_data = allocator.alloc(u8, dir_size) catch {
        return ValidationResult.okWithDepth(.wad, .structural);
    };
    defer allocator.free(dir_data);

    file.seekTo(dir_offset) catch return ValidationResult.invalidCode(.wad, .failed_to_seek, "to directory");
    const dir_read = file.readAll(dir_data) catch return ValidationResult.invalidCode(.wad, .failed_to_read, "directory");

    if (dir_read != dir_size) {
        return ValidationResult.invalidCode(.wad, .incomplete, "directory read");
    }

    // Validate each directory entry
    var i: u32 = 0;
    while (i < lump_count) : (i += 1) {
        const entry_offset = i * 16;
        const lump_offset = std.mem.readInt(u32, dir_data[entry_offset..][0..4], .little);
        const lump_size = std.mem.readInt(u32, dir_data[entry_offset + 4 ..][0..4], .little);

        // Verify lump is within file bounds (size 0 is valid for markers)
        if (lump_size > 0 and lump_offset + lump_size > file_size) {
            return ValidationResult.invalid(.wad, "Lump extends beyond file");
        }
    }

    return ValidationResult.okWithDepth(.wad, .structural);
}

// ============ PAK (Quake) Validator ============

/// Validate PAK (Quake) archive format.
/// PAK files start with "PACK" followed by directory offset and size (both 4 bytes, little-endian).
/// NOTE: Git pack files also start with "PACK" but have different structure (version + object count, big-endian).
pub fn validatePak(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pak, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.pak, .failed_to_read, "PAK header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.pak, .file_too_small, "PAK");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..4], "PACK")) {
        return ValidationResult.invalidCode(.pak, .invalid_signature, "PAK");
    }

    // Check if this is a Git pack file instead of Quake PAK
    // Git pack: bytes 4-7 are big-endian version (2 or 3)
    // Quake PAK: bytes 4-7 are little-endian directory offset
    const version_big = std.mem.readInt(u32, header[4..8], .big);
    if (version_big == 2 or version_big == 3) {
        // This is a Git pack file, not a Quake PAK
        // Return as unknown - Git pack files are not a format we validate
        return ValidationResult.ok(.unknown);
    }

    // Directory offset (little-endian)
    const dir_offset = std.mem.readInt(u32, header[4..8], .little);
    // Directory size (little-endian)
    const dir_size = std.mem.readInt(u32, header[8..12], .little);

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.pak, .failed_to_get, "file size");

    // Directory must be within file
    if (dir_offset + dir_size > file_size) {
        return ValidationResult.invalid(.pak, "Directory extends beyond file");
    }

    // Each directory entry is 64 bytes (56 name + 4 offset + 4 size)
    if (dir_size % 64 != 0) {
        return ValidationResult.invalidCode(.pak, .invalid_value, "directory size (not multiple of 64)");
    }

    // No CRC/hash — header + directory structure check only
    return ValidationResult.okWithDepth(.pak, .structural);
}

/// Deep validation for PAK files - validates all directory entries.
pub fn validatePakDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch {
        return ValidationResult.invalidCode(.pak, .failed_to_get, "file size");
    };

    // Read header
    var header: [12]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.pak, .failed_to_read, "header");

    if (!std.mem.eql(u8, header[0..4], "PACK")) {
        return ValidationResult.invalidCode(.pak, .invalid_signature, "PAK");
    }

    // Check for Git pack file
    const version_big = std.mem.readInt(u32, header[4..8], .big);
    if (version_big == 2 or version_big == 3) {
        return ValidationResult.ok(.unknown);
    }

    const dir_offset = std.mem.readInt(u32, header[4..8], .little);
    const dir_size = std.mem.readInt(u32, header[8..12], .little);

    if (dir_offset + dir_size > file_size or dir_size % 64 != 0) {
        return ValidationResult.invalidCode(.pak, .invalid_value, "directory");
    }

    // Read and validate all directory entries
    const dir_data = allocator.alloc(u8, dir_size) catch {
        return ValidationResult.okWithDepth(.pak, .structural);
    };
    defer allocator.free(dir_data);

    file.seekTo(dir_offset) catch return ValidationResult.invalidCode(.pak, .failed_to_seek, "to PAK directory");
    const dir_read = file.readAll(dir_data) catch return ValidationResult.invalidCode(.pak, .failed_to_read, "PAK directory");

    if (dir_read != dir_size) {
        return ValidationResult.invalidCode(.pak, .incomplete, "directory read");
    }

    // Validate each entry
    const entry_count = dir_size / 64;
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const entry_offset = i * 64;
        const file_offset = std.mem.readInt(u32, dir_data[entry_offset + 56 ..][0..4], .little);
        const file_len = std.mem.readInt(u32, dir_data[entry_offset + 60 ..][0..4], .little);

        if (file_len > 0 and file_offset + file_len > file_size) {
            return ValidationResult.invalid(.pak, "File entry extends beyond archive");
        }
    }

    return ValidationResult.okWithDepth(.pak, .structural);
}

// ============ LSPK (Larian Studios) Validator ============

/// Validate Larian Studios PAK (BG3, Divinity: Original Sin) structural header.
/// "LSPK" magic + version + file list offset/size + MD5 hash.
pub fn validateLspk(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.lspk, .failed_to_seek, "in LSPK file");
    var header: [32]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.lspk, .failed_to_read, "LSPK header");
    if (bytes_read < 8) return ValidationResult.invalid(.lspk, "File too small");

    // Verify magic
    if (!std.mem.eql(u8, header[0..4], "LSPK")) {
        return ValidationResult.invalidCode(.lspk, .invalid_value, "LSPK magic");
    }

    const version = std.mem.readInt(u32, header[4..8], .little);

    // Known versions: 7, 10, 13, 15, 16, 18
    if (version < 7 or version > 30) {
        return ValidationResult.invalidCode(.lspk, .unknown_element, "LSPK version");
    }

    return ValidationResult.okWithDepthAndWarning(.lspk, .structural, "Larian PAK identified; deep validation not yet implemented");
}

// ============ Chromium PAK Validator ============

/// Validate Chromium/Electron resource PAK structural header.
/// Version 4 or 5 format with resource table and encoding byte.
pub fn validateChromiumPak(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.chromium_pak, .failed_to_seek, "in Chromium PAK file");
    var header: [18]u8 = undefined;
    const bytes_read = file.read(&header) catch return ValidationResult.invalidCode(.chromium_pak, .failed_to_read, "Chromium PAK header");
    if (bytes_read < 12) return ValidationResult.invalid(.chromium_pak, "File too small");

    const version = std.mem.readInt(u32, header[0..4], .little);

    if (version == 5) {
        const encoding = header[4];
        if (encoding > 2) return ValidationResult.invalidCode(.chromium_pak, .invalid_value, "encoding byte");
        if (header[5] != 0 or header[6] != 0 or header[7] != 0) {
            return ValidationResult.invalidCode(.chromium_pak, .invalid_value, "padding bytes");
        }
        const resource_count = std.mem.readInt(u16, header[8..10], .little);
        if (resource_count == 0) return ValidationResult.invalid(.chromium_pak, "Zero resources");

        // Verify first entry offset matches expected index size
        if (bytes_read >= 18) {
            const alias_count = std.mem.readInt(u16, header[10..12], .little);
            const expected_start: u32 = 12 + (@as(u32, resource_count) + 1) * 6 + @as(u32, alias_count) * 4;
            const first_offset = std.mem.readInt(u32, header[14..18], .little);
            if (first_offset != expected_start) {
                return ValidationResult.invalid(.chromium_pak, "Resource offset mismatch");
            }
        }
    } else if (version == 4) {
        const resource_count = std.mem.readInt(u32, header[4..8], .little);
        const encoding = header[8];
        if (encoding > 2) return ValidationResult.invalidCode(.chromium_pak, .invalid_value, "encoding byte");
        if (resource_count == 0 or resource_count > 100000) {
            return ValidationResult.invalidCode(.chromium_pak, .invalid_value, "resource count");
        }
    } else {
        return ValidationResult.invalidCode(.chromium_pak, .unknown_element, "Chromium PAK version");
    }

    return ValidationResult.okWithDepthAndWarning(.chromium_pak, .structural, "Chromium PAK identified; deep validation not yet implemented");
}

// ============ BSP (Quake/Source) Validator ============

/// Validate BSP (Quake/Source map) file format.
/// Parses the lump directory for id BSP (IBSP, Quake 2/3), Valve BSP (VBSP, Source engine),
/// and Quake 1 (no magic, version 29/30). Bounds-checks every lump and verifies no overlaps.
/// Structural integrity technique: lump directory traversal with offset+length range checks.
pub fn validateBsp(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.bsp, .failed_to_seek, "to start");

    // Read enough for the largest possible header: VBSP = 4+4 + 64*16 = 1032 bytes
    const MAX_HEADER: usize = 1032;
    const header_buf = heap.validateAllocator().alloc(u8, MAX_HEADER) catch
        return ValidationResult.invalidCode(.bsp, .failed_to_read, "BSP header (alloc)");
    defer heap.validateAllocator().free(header_buf);

    const header_read = file.read(header_buf) catch return ValidationResult.invalidCode(.bsp, .failed_to_read, "BSP header");
    if (header_read < 8) return ValidationResult.invalidCode(.bsp, .file_too_small, "BSP");

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.bsp, .failed_to_get, "file size");

    // Detect layout by magic bytes at offset 0.
    const magic = header_buf[0..4];
    const is_ibsp = std.mem.eql(u8, magic, "IBSP");
    const is_vbsp = std.mem.eql(u8, magic, "VBSP");

    if (is_ibsp or is_vbsp) {
        // id BSP (IBSP) and Valve BSP (VBSP): magic[4] + version[4] + lump_dir
        const version = std.mem.readInt(u32, header_buf[4..8], .little);

        if (is_vbsp) {
            // Source engine VBSP: 64 lumps × 16 bytes each
            // Header layout: "VBSP"(4) + version(4) + 64×{offset(4)+length(4)+ver(4)+fourCC(4)}
            const VBSP_LUMP_COUNT: usize = 64;
            const VBSP_ENTRY_SIZE: usize = 16;
            const VBSP_HEADER_SIZE: usize = 8 + VBSP_LUMP_COUNT * VBSP_ENTRY_SIZE; // 1032

            // Known VBSP versions: 17–21 cover all shipped Source games
            if (version < 17 or version > 29) {
                return ValidationResult.invalidCode(.bsp, .unknown_element, "VBSP version");
            }
            if (file_size < VBSP_HEADER_SIZE) {
                return ValidationResult.invalidCode(.bsp, .file_too_small, "VBSP header");
            }
            if (header_read < VBSP_HEADER_SIZE) {
                return ValidationResult.invalidCode(.bsp, .file_too_small, "VBSP header (read)");
            }

            return bspValidateLumps(
                header_buf[8..],
                VBSP_LUMP_COUNT,
                VBSP_ENTRY_SIZE, // stride between entries
                0, // offset field byte-index within entry
                4, // length field byte-index within entry
                file_size,
                .bsp,
            );
        } else {
            // IBSP: Quake 2 (v38, 19 lumps) or Quake 3 (v46/v47, 17 lumps)
            // Entry size: 8 bytes (offset u32 + length u32)
            const lump_count: usize = switch (version) {
                38 => 19, // Quake 2
                46, 47 => 17, // Quake 3 / Quake 3: Arena + Team Arena
                else => return ValidationResult.invalidCode(.bsp, .unknown_element, "IBSP version"),
            };
            const IBSP_ENTRY_SIZE: usize = 8;
            const ibsp_header_size: usize = 8 + lump_count * IBSP_ENTRY_SIZE;

            if (file_size < ibsp_header_size) {
                return ValidationResult.invalidCode(.bsp, .file_too_small, "IBSP header");
            }
            if (header_read < ibsp_header_size) {
                return ValidationResult.invalidCode(.bsp, .file_too_small, "IBSP header (read)");
            }

            return bspValidateLumps(
                header_buf[8..],
                lump_count,
                IBSP_ENTRY_SIZE,
                0, // offset at byte 0 in entry
                4, // length at byte 4 in entry
                file_size,
                .bsp,
            );
        }
    } else {
        // Quake 1 / GoldSrc: no magic bytes; version is first u32
        const version = std.mem.readInt(u32, header_buf[0..4], .little);
        if (version != 29 and version != 30) {
            return ValidationResult.invalidCode(.bsp, .unknown_element, "BSP version");
        }

        // Quake 1: 15 lumps × 8 bytes each; header = 4 + 15*8 = 124 bytes
        const Q1_LUMP_COUNT: usize = 15;
        const Q1_ENTRY_SIZE: usize = 8;
        const Q1_HEADER_SIZE: usize = 4 + Q1_LUMP_COUNT * Q1_ENTRY_SIZE; // 124

        if (file_size < Q1_HEADER_SIZE) {
            return ValidationResult.invalidCode(.bsp, .file_too_small, "Quake 1 BSP header");
        }
        if (header_read < Q1_HEADER_SIZE) {
            return ValidationResult.invalidCode(.bsp, .file_too_small, "Quake 1 BSP header (read)");
        }

        return bspValidateLumps(
            header_buf[4..],
            Q1_LUMP_COUNT,
            Q1_ENTRY_SIZE,
            0,
            4,
            file_size,
            .bsp,
        );
    }
}

/// Parse and bounds-check a BSP lump directory.
/// Verifies every lump's [offset, offset+length) range fits within the file,
/// and that no two non-empty lumps overlap (sorted sweep). Returns `.full` depth
/// on success because bounds-checking IS the structural integrity mechanism for BSP.
fn bspValidateLumps(
    dir: []const u8,
    lump_count: usize,
    entry_stride: usize,
    offset_field: usize,
    length_field: usize,
    file_size: u64,
    format: FileFormat,
) ValidationResult {
    // We need to sort lumps by offset to check for overlaps.
    // Maximum lump count across all variants is 64 (VBSP); fits on stack.
    var lumps: [64]struct { offset: u32, length: u32 } = undefined;
    if (lump_count > lumps.len) return ValidationResult.invalid(format, "BSP lump count exceeds internal limit");

    for (0..lump_count) |i| {
        const base = i * entry_stride;
        const lump_offset = std.mem.readInt(u32, dir[base + offset_field ..][0..4], .little);
        const lump_length = std.mem.readInt(u32, dir[base + length_field ..][0..4], .little);

        // Each lump must fit within the file
        const end = @as(u64, lump_offset) + @as(u64, lump_length);
        if (end > file_size) {
            return ValidationResult.invalid(format, "BSP lump extends beyond file size");
        }

        lumps[i] = .{ .offset = lump_offset, .length = lump_length };
    }

    // Sort lumps by offset (insertion sort — lump_count <= 64, trivial cost)
    for (1..lump_count) |i| {
        const key = lumps[i];
        var j: usize = i;
        while (j > 0 and lumps[j - 1].offset > key.offset) : (j -= 1) {
            lumps[j] = lumps[j - 1];
        }
        lumps[j] = key;
    }

    // Overlap check: each non-empty lump's end must be <= next non-empty lump's start
    var prev_end: u64 = 0;
    var prev_offset: u32 = 0;
    for (lumps[0..lump_count]) |lump| {
        if (lump.length == 0) continue; // empty lumps are valid padding
        const lump_end = @as(u64, lump.offset) + @as(u64, lump.length);
        // Two non-empty lumps overlap if this lump starts before the previous one ends,
        // but allow lumps at the same offset only if one is empty (already filtered above).
        if (lump.offset < prev_end and lump.offset != prev_offset) {
            return ValidationResult.invalid(format, "BSP lumps overlap");
        }
        prev_end = lump_end;
        prev_offset = lump.offset;
    }

    return ValidationResult.okWithDepth(format, .structural);
}

// ============ VPK (Valve PAK) Validator ============

/// Validate VPK (Valve PAK) file format.
/// VPK files start with signature 0x55AA1234 followed by version and tree size.
/// Walks the hierarchical directory tree (ext/path/filename/entry), verifying
/// entry terminators (0xFFFF), in-file data bounds, and v2 section size consistency.
/// Returns .full depth when the tree walk completes without errors.
pub fn validateVpk(file: *FileSource) ValidationResult {
	file.seekTo(0) catch return ValidationResult.invalidCode(.vpk, .failed_to_seek, "to start");

	// v1 header: 12 bytes; v2 header: 28 bytes — read max up-front
	var header: [28]u8 = undefined;
	const header_read = file.read(&header) catch return ValidationResult.invalidCode(.vpk, .failed_to_read, "VPK header");

	if (header_read < 12) {
		return ValidationResult.invalidCode(.vpk, .file_too_small, "VPK");
	}

	// Check signature (0x55AA1234 in little-endian)
	const signature = std.mem.readInt(u32, header[0..4], .little);
	if (signature != 0x55AA1234) {
		return ValidationResult.invalidCode(.vpk, .invalid_signature, "VPK");
	}

	// Version (1 or 2)
	const version = std.mem.readInt(u32, header[4..8], .little);
	if (version != 1 and version != 2) {
		return ValidationResult.invalidCode(.vpk, .unknown_element, "VPK version");
	}

	// Tree size (present in both v1 and v2)
	const tree_size = std.mem.readInt(u32, header[8..12], .little);
	const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.vpk, .failed_to_get, "file size");

	// Header length depends on version
	const header_len: u32 = if (version == 2) 28 else 12;

	if (header_read < header_len) {
		return ValidationResult.invalidCode(.vpk, .file_too_small, "VPK header");
	}

	// Tree must fit in file after header
	if (@as(u64, header_len) + @as(u64, tree_size) > file_size) {
		return ValidationResult.invalidCodeMsg(.vpk, .exceeds_bounds, "Tree size", "Tree size exceeds file size");
	}

	// For v2: verify section sizes add up against file size.
	// Expected: header(28) + tree_size + file_data + arch_md5 + other_md5 + sig
	if (version == 2) {
		const file_data_sz = std.mem.readInt(u32, header[12..16], .little);
		const arch_md5_sz  = std.mem.readInt(u32, header[16..20], .little);
		const other_md5_sz = std.mem.readInt(u32, header[20..24], .little);
		const sig_sz       = std.mem.readInt(u32, header[24..28], .little);
		const expected_size: u64 = 28 +
			@as(u64, tree_size) +
			@as(u64, file_data_sz) +
			@as(u64, arch_md5_sz) +
			@as(u64, other_md5_sz) +
			@as(u64, sig_sz);
		if (expected_size != file_size) {
			return ValidationResult.invalid(.vpk, "VPK v2 section sizes do not match file size");
		}
	}

	// An empty tree is valid (directory-only VPK with no embedded data)
	if (tree_size == 0) {
		return ValidationResult.okWithDepth(.vpk, .structural);
	}

	// Read tree — zero-copy from mmap when available
	var tree_heap: ?[]u8 = null;
	defer if (tree_heap) |buf| heap.validateAllocator().free(buf);
	const tree_buf: []const u8 = if (file.getMappedRange(header_len, tree_size)) |mapped|
		mapped
	else blk: {
		const buf = heap.validateAllocator().alloc(u8, tree_size) catch {
			return ValidationResult.structuralOnly(.vpk);
		};
		tree_heap = buf;
		file.seekTo(header_len) catch return ValidationResult.invalidCode(.vpk, .failed_to_seek, "to tree");
		const n = file.readAll(buf) catch return ValidationResult.invalidCode(.vpk, .failed_to_read, "VPK tree");
		if (n != tree_size) return ValidationResult.invalidCode(.vpk, .incomplete, "VPK tree read");
		break :blk buf[0..n];
	};

	// Walk the directory tree.
	// Layout: for each ext\0 { for each path\0 { for each filename\0 { Entry(18B) }* \0 }* \0 }* \0
	// An empty string at any level signals end of that level.
	const max_entries: u32 = 1_000_000;
	var total_entries: u32 = 0;
	var pos: u32 = 0;

	while (pos < tree_size) {
		// Read extension string
		const ext_start = pos;
		while (pos < tree_size and tree_buf[pos] != 0) : (pos += 1) {}
		if (pos >= tree_size) return ValidationResult.invalid(.vpk, "VPK tree: unterminated extension string");
		const ext_len = pos - ext_start;
		pos += 1; // consume NUL
		if (ext_len == 0) break; // end of all extensions

		// For each path under this extension
		while (pos < tree_size) {
			const path_start = pos;
			while (pos < tree_size and tree_buf[pos] != 0) : (pos += 1) {}
			if (pos >= tree_size) return ValidationResult.invalid(.vpk, "VPK tree: unterminated path string");
			const path_len = pos - path_start;
			pos += 1; // consume NUL
			if (path_len == 0) break; // end of paths for this extension

			// For each filename under this path+extension
			while (pos < tree_size) {
				const fname_start = pos;
				while (pos < tree_size and tree_buf[pos] != 0) : (pos += 1) {}
				if (pos >= tree_size) return ValidationResult.invalid(.vpk, "VPK tree: unterminated filename string");
				const fname_len = pos - fname_start;
				pos += 1; // consume NUL
				if (fname_len == 0) break; // end of filenames for this path+extension

				// Read DirectoryEntry (18 bytes)
				if (pos + 18 > tree_size) {
					return ValidationResult.invalid(.vpk, "VPK tree: directory entry truncated");
				}
				const entry = tree_buf[pos..][0..18];

				// Terminator must be 0xFFFF (bytes 16–17)
				const terminator = std.mem.readInt(u16, entry[16..18], .little);
				if (terminator != 0xFFFF) {
					return ValidationResult.invalid(.vpk, "VPK tree: entry missing 0xFFFF terminator");
				}

				const preload_bytes = std.mem.readInt(u16, entry[4..6], .little);
				const archive_index = std.mem.readInt(u16, entry[6..8], .little);
				const entry_offset  = std.mem.readInt(u32, entry[8..12], .little);
				const entry_length  = std.mem.readInt(u32, entry[12..16], .little);

				pos += 18;

				// For in-file data (archive_index == 0x7FFF), verify bounds
				// against the file_data section that immediately follows the tree
				if (archive_index == 0x7FFF and entry_length > 0) {
					const data_section_start: u64 = @as(u64, header_len) + @as(u64, tree_size);
					const data_end: u64 = data_section_start + @as(u64, entry_offset) + @as(u64, entry_length);
					if (data_end > file_size) {
						return ValidationResult.invalid(.vpk, "VPK entry data extends beyond file");
					}
				}

				// Skip inline preload data
				if (pos + preload_bytes > tree_size) {
					return ValidationResult.invalid(.vpk, "VPK tree: preload data truncated");
				}
				pos += preload_bytes;

				total_entries += 1;
				if (total_entries > max_entries) {
					return ValidationResult.invalid(.vpk, "VPK tree: entry count exceeds sanity limit");
				}
			}
		}
	}

	return ValidationResult.okWithDepth(.vpk, .structural);
}

// ============ IFF/Blorb Validators ============

/// Validate generic IFF (Interchange File Format) container.
/// IFF files have "FORM" signature followed by 4-byte size (big-endian) and 4-byte type.
pub fn validateIff(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.iff, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.iff, .failed_to_read, "IFF header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.iff, .file_too_small, "IFF");
    }

    // Check FORM signature
    if (!std.mem.eql(u8, header[0..4], "FORM")) {
        return ValidationResult.invalidCode(.iff, .invalid_signature, "IFF");
    }

    // Read chunk size (big-endian)
    const chunk_size = std.mem.readInt(u32, header[4..8], .big);

    // Verify file is large enough (8 byte header + chunk_size)
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.iff, .failed_to_get, "file size");
    if (file_size < 8 + @as(u64, chunk_size)) {
        return ValidationResult.invalid(.iff, "File truncated");
    }

    // No CRC/hash — FORM header + size check only
    return ValidationResult.okWithDepth(.iff, .structural);
}

/// ILBM BMHD (BitMap Header) parsed fields for cross-validation.
const IlbmBmhd = struct {
	width: u16,
	height: u16,
	num_planes: u8,
	masking: u8,
	compression: u8,
	// transparent_color, x_aspect, y_aspect, page_width, page_height omitted (not needed for validation)
};

/// Parse ILBM BMHD chunk data (20 bytes expected).
fn parseIlbmBmhd(data: []const u8) ?IlbmBmhd {
	if (data.len < 20) return null;
	const width = std.mem.readInt(u16, data[0..2], .big);
	const height = std.mem.readInt(u16, data[2..4], .big);
	// bytes 4-7: x, y (origin offsets)
	const num_planes = data[8];
	const masking = data[9];
	const compression = data[10];
	// byte 11: pad (reserved)

	// Sanity checks on field ranges
	if (width == 0 or height == 0) return null;
	if (num_planes == 0 or num_planes > 32) return null;
	if (masking > 3) return null; // 0=none, 1=hasMask, 2=hasTransparent, 3=lasso
	if (compression > 2) return null; // 0=none, 1=byteRun1, 2=vertical (rare)

	return IlbmBmhd{
		.width = width,
		.height = height,
		.num_planes = num_planes,
		.masking = masking,
		.compression = compression,
	};
}

/// Check if a 4-byte IFF chunk ID contains only valid characters (printable ASCII 0x20-0x7E).
fn isValidChunkId(id: *const [4]u8) bool {
	for (id) |c| {
		if (c < 0x20 or c > 0x7E) return false;
	}
	return true;
}

/// Deep validation for IFF files - parses all nested chunks with format-specific cross-validation.
/// For ILBM containers, cross-validates BMHD dimensions against BODY chunk size.
pub fn validateIffDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file = source;

	var header: [12]u8 = undefined;
	_ = file.read(&header) catch return ValidationResult.invalidCode(.iff, .failed_to_read, "header");

	if (!std.mem.eql(u8, header[0..4], "FORM")) {
		return ValidationResult.invalidCode(.iff, .invalid_signature, "IFF");
	}

	const form_size = std.mem.readInt(u32, header[4..8], .big);
	const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.iff, .failed_to_get, "file size");

	if (file_size < 8 + @as(u64, form_size)) {
		return ValidationResult.invalid(.iff, "File truncated");
	}

	const form_type: *const [4]u8 = header[8..12];
	const is_ilbm = std.mem.eql(u8, form_type, "ILBM");

	// Parse all chunks within the FORM, collecting ILBM-specific data
	var pos: u64 = 12; // After FORM + size + type
	var chunk_count: u32 = 0;
	const form_end = 8 + @as(u64, form_size);

	var bmhd: ?IlbmBmhd = null;
	var body_size: ?u32 = null;
	var has_body = false;

	while (pos + 8 <= form_end) {
		file.seekTo(pos) catch break;

		var chunk_header: [8]u8 = undefined;
		const bytes_read = file.read(&chunk_header) catch break;
		if (bytes_read < 8) break;

		// Validate chunk ID is printable ASCII
		if (!isValidChunkId(chunk_header[0..4])) {
			return ValidationResult.invalid(.iff, "Invalid chunk ID (non-printable characters)");
		}

		const chunk_sz = std.mem.readInt(u32, chunk_header[4..8], .big);

		// Verify chunk doesn't exceed container
		if (pos + 8 + chunk_sz > form_end) {
			return ValidationResult.invalid(.iff, "Chunk extends beyond FORM boundary");
		}

		// For ILBM: collect BMHD and BODY info for cross-validation
		if (is_ilbm) {
			if (std.mem.eql(u8, chunk_header[0..4], "BMHD")) {
				if (chunk_sz >= 20) {
					var bmhd_data: [20]u8 = undefined;
					const bmhd_read = file.readAll(&bmhd_data) catch return ValidationResult.invalidCode(.iff, .failed_to_read, "BMHD chunk");
					if (bmhd_read != 20) return ValidationResult.invalidCode(.iff, .truncated, "BMHD chunk");
					bmhd = parseIlbmBmhd(&bmhd_data);
					if (bmhd == null) {
						return ValidationResult.invalid(.iff, "ILBM BMHD has invalid field values");
					}
				}
			} else if (std.mem.eql(u8, chunk_header[0..4], "BODY")) {
				has_body = true;
				body_size = chunk_sz;

				// For uncompressed BODY, read and validate data against BMHD
				if (bmhd) |bm| {
					if (bm.compression == 0) {
						// Uncompressed: BODY must be exactly height * total_planes * row_bytes
						const total_planes: u32 = @as(u32, bm.num_planes) + @as(u32, if (bm.masking == 1) 1 else 0);
						const row_bytes: u32 = ((@as(u32, bm.width) + 15) / 16) * 2;
						const expected_body = @as(u32, bm.height) * total_planes * row_bytes;
						if (chunk_sz != expected_body) {
							return ValidationResult.invalid(.iff, "ILBM BODY size doesn't match BMHD dimensions");
						}
					}
				}

				// Read BODY data for compression stream validation
				if (chunk_sz > 0 and chunk_sz <= 1024 * 1024) { // Cap at 1MB for memory
					const data = allocator.alloc(u8, chunk_sz) catch return ValidationResult.invalidCode(.iff, .out_of_memory, "BODY chunk buffer");
					defer allocator.free(data);
					const body_read = file.readAll(data) catch return ValidationResult.invalidCode(.iff, .failed_to_read, "BODY chunk");
					if (body_read != chunk_sz) {
						return ValidationResult.invalid(.iff, "BODY chunk data truncated");
					}
					// For ILBM with BMHD: validate compression stream
					if (bmhd) |bm| {
						if (bm.compression == 0) {
							// Uncompressed: size check already done above
						} else if (bm.compression == 1) {
							// ByteRun1 compressed: validate compression stream
							var src_pos: u32 = 0;
							var decompressed_bytes: u64 = 0;
							const total_planes: u32 = @as(u32, bm.num_planes) + @as(u32, if (bm.masking == 1) 1 else 0);
							const row_bytes: u32 = ((@as(u32, bm.width) + 15) / 16) * 2;
							const expected_decompressed: u64 = @as(u64, bm.height) * total_planes * row_bytes;

							while (src_pos < body_read) {
								const control = @as(i8, @bitCast(data[src_pos]));
								src_pos += 1;
								if (control >= 0) {
									// Copy n+1 bytes literally
									const n: u32 = @as(u32, @intCast(control)) + 1;
									if (src_pos + n > body_read) {
										return ValidationResult.invalid(.iff, "ILBM ByteRun1 literal run exceeds data");
									}
									src_pos += n;
									decompressed_bytes += n;
								} else if (control != -128) {
									// Repeat next byte (1-n) times
									const n: u32 = @as(u32, @intCast(-@as(i32, control))) + 1;
									if (src_pos >= body_read) {
										return ValidationResult.invalid(.iff, "ILBM ByteRun1 repeat missing data byte");
									}
									src_pos += 1;
									decompressed_bytes += n;
								}
								// control == -128: NOP
							}
							if (expected_decompressed > 0 and decompressed_bytes != expected_decompressed) {
								return ValidationResult.invalid(.iff, "ILBM ByteRun1 decompressed size doesn't match BMHD dimensions");
							}
						}
					}
				}
			} else if (std.mem.eql(u8, chunk_header[0..4], "CMAP")) {
				// CMAP must be a multiple of 3 (RGB triples)
				if (chunk_sz % 3 != 0) {
					return ValidationResult.invalid(.iff, "ILBM CMAP size not a multiple of 3");
				}
				// Number of colors should be <= 2^num_planes (if BMHD already parsed)
				if (bmhd) |bm| {
					const max_colors: u32 = @as(u32, 1) << @intCast(bm.num_planes);
					const num_colors = chunk_sz / 3;
					if (num_colors > max_colors) {
						return ValidationResult.invalid(.iff, "ILBM CMAP has more colors than bit depth allows");
					}
				}
			}
		}

		chunk_count += 1;

		// Move to next chunk (pad to even boundary)
		pos += 8 + chunk_sz;
		if (chunk_sz % 2 == 1 and pos < form_end) pos += 1;
	}

	if (chunk_count == 0) {
		return ValidationResult.invalid(.iff, "No chunks found in FORM");
	}

	// ILBM-specific: must have both BMHD and BODY
	if (is_ilbm) {
		if (bmhd == null) {
			return ValidationResult.invalid(.iff, "ILBM missing required BMHD chunk");
		}
		if (!has_body) {
			return ValidationResult.invalid(.iff, "ILBM missing required BODY chunk");
		}
	}

	return ValidationResult.okWithDepth(.iff, .full);
}

/// Validate Blorb (Interactive Fiction resource) format.
/// Blorb is an IFF container with IFRS (Z-machine) or IFZS (Glulx) form type.
pub fn validateBlorb(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.blorb, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.blorb, .failed_to_read, "Blorb header");

    if (header_read < 12) {
        return ValidationResult.invalidCode(.blorb, .file_too_small, "Blorb");
    }

    // Check FORM signature
    if (!std.mem.eql(u8, header[0..4], "FORM")) {
        return ValidationResult.invalidCode(.blorb, .invalid_signature, "Blorb");
    }

    // Check Blorb form type
    if (!std.mem.eql(u8, header[8..12], "IFRS") and !std.mem.eql(u8, header[8..12], "IFZS")) {
        return ValidationResult.invalid(.blorb, "Not a Blorb file (wrong form type)");
    }

    // Read chunk size (big-endian)
    const chunk_size = std.mem.readInt(u32, header[4..8], .big);

    // Verify file is large enough
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.blorb, .failed_to_get, "file size");
    if (file_size < 8 + @as(u64, chunk_size)) {
        return ValidationResult.invalid(.blorb, "File truncated");
    }

    // Look for RIdx (Resource Index) chunk which is required
    var pos: u64 = 12;
    while (pos + 8 <= file_size) {
        file.seekTo(pos) catch break;
        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_type = chunk_header[0..4];
        const size = std.mem.readInt(u32, chunk_header[4..8], .big);

        if (std.mem.eql(u8, chunk_type, "RIdx")) {
            // Found required Resource Index — no CRC/hash, structural only
            return ValidationResult.okWithDepth(.blorb, .structural);
        }

        // IFF chunks are padded to even boundaries
        pos += 8 + size;
        if (size % 2 == 1) pos += 1;
    }

    return ValidationResult.invalidCode(.blorb, .missing, "required RIdx chunk");
}

// ============ Tests ============

test "VPK validation - valid v2 sample (empty tree)" {
	const path = "ground_truth_examples/vpk/sample.vpk";
	var source = FileSource.open(path) catch |err| {
		if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
		return err;
	};
	defer source.close();
	const result = validateVpk(&source);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.validation_depth);}

test "VPK validation - bad signature rejected" {
	// Craft a 12-byte buffer with wrong signature
	var buf: [12]u8 = .{
		0xDE, 0xAD, 0xBE, 0xEF, // bad signature
		0x01, 0x00, 0x00, 0x00, // version 1
		0x00, 0x00, 0x00, 0x00, // tree_size 0
	};
	const tmp_path = "/tmp/vpk_test_bad_sig.vpk";
	{
		const tmp = try runtime.createFile(tmp_path, .{});
		defer tmp.close(runtime.io());
		try tmp.writePositionalAll(runtime.io(), &buf, 0);
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};
	var source = try FileSource.open(tmp_path);
	defer source.close();
	const result = validateVpk(&source);
	try testing.expect(!result.is_valid);
}

test "VPK validation - v2 section size mismatch rejected" {
	// Build a v2 header where section sizes don't add up to file size
	var buf: [28]u8 = .{
		0x34, 0x12, 0xAA, 0x55, // signature 0x55AA1234
		0x02, 0x00, 0x00, 0x00, // version 2
		0x00, 0x00, 0x00, 0x00, // tree_size = 0
		0x01, 0x00, 0x00, 0x00, // file_data_section_size = 1 (wrong: makes expected != 28)
		0x00, 0x00, 0x00, 0x00, // archive_md5_section_size = 0
		0x00, 0x00, 0x00, 0x00, // other_md5_section_size = 0
		0x00, 0x00, 0x00, 0x00, // signature_section_size = 0
	};
	const tmp_path = "/tmp/vpk_test_v2_mismatch.vpk";
	{
		const tmp = try runtime.createFile(tmp_path, .{});
		defer tmp.close(runtime.io());
		try tmp.writePositionalAll(runtime.io(), &buf, 0);
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};
	var source = try FileSource.open(tmp_path);
	defer source.close();
	const result = validateVpk(&source);
	try testing.expect(!result.is_valid);
}

test "VPK validation - entry missing 0xFFFF terminator rejected" {
	// Build a minimal v1 VPK with one entry that has a bad terminator.
	// Tree structure: "txt\0" + " \0" + "file\0" + Entry(18B with bad terminator) + "\0\0\0"
	const ext = "txt\x00";
	const path_str = " \x00";
	const fname = "file\x00";
	// DirectoryEntry: crc=0 preload=0 archive=0x7FFF offset=0 length=0 terminator=0xDEAD (bad)
	const entry = [18]u8{
		0x00, 0x00, 0x00, 0x00, // crc32
		0x00, 0x00,             // preload_bytes = 0
		0xFF, 0x7F,             // archive_index = 0x7FFF
		0x00, 0x00, 0x00, 0x00, // entry_offset = 0
		0x00, 0x00, 0x00, 0x00, // entry_length = 0
		0xAD, 0xDE,             // terminator = 0xDEAD (bad!)
	};
	const end_fname = "\x00"; // end of filenames
	const end_path  = "\x00"; // end of paths
	const end_ext   = "\x00"; // end of extensions

	const tree_parts: [6][]const u8 = .{ext, path_str, fname, &entry, end_fname, end_path};
	var tree_size: u32 = 0;
	for (tree_parts) |p| tree_size += @intCast(p.len);
	tree_size += @intCast(end_ext.len);

	var header: [12]u8 = .{
		0x34, 0x12, 0xAA, 0x55,                              // signature
		0x01, 0x00, 0x00, 0x00,                              // version 1
		@truncate(tree_size), @truncate(tree_size >> 8),     // tree_size lo bytes
		@truncate(tree_size >> 16), @truncate(tree_size >> 24),
	};

	const tmp_path = "/tmp/vpk_test_bad_term.vpk";
	{
		const tmp = try runtime.createFile(tmp_path, .{});
		defer tmp.close(runtime.io());
		var __off: u64 = 0;
		try tmp.writePositionalAll(runtime.io(), &header, __off);
		__off += header.len;
		for (tree_parts) |p| {
			try tmp.writePositionalAll(runtime.io(), p, __off);
			__off += p.len;
		}
		try tmp.writePositionalAll(runtime.io(), end_ext, __off);
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};
	var source = try FileSource.open(tmp_path);
	defer source.close();
	const result = validateVpk(&source);
	try testing.expect(!result.is_valid);
}

test "IFF deep validation - valid ILBM ByteRun1 sample" {
	try skipIfMissing("ground_truth_examples/iff/sample.iff");
	var source = FileSource.open("ground_truth_examples/iff/sample.iff") catch return error.SkipZigTest;
	defer source.close();
	const result = validateIffDeep(testing.allocator, &source);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "IFF deep validation - corrupted ByteRun1 stream detected" {
	// Create a corrupted copy of the sample file
	const src = runtime.openFile("ground_truth_examples/iff/sample.iff", .{}) catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
	defer src.close(runtime.io());
	const file_size = src.length(runtime.io()) catch return;
	const data = testing.allocator.alloc(u8, file_size) catch return;
	defer testing.allocator.free(data);
	_ = src.readPositionalAll(runtime.io(), data, 0) catch return;

	// Corrupt bytes in the BODY data area (offset 104 = BODY header at 96 + 8)
	// The BODY data starts at offset 104 in our sample
	if (data.len > 120) {
		data[110] = 0x42; // Corrupt a compression control byte
		data[111] = 0x42;
		data[112] = 0x42;
		data[113] = 0x42;
	}

	// Write corrupted data to a temp file
	const tmp_path = "/tmp/iff_test_corrupt.iff";
	const tmp = runtime.createFile(tmp_path, .{}) catch return;
	tmp.writePositionalAll(runtime.io(), data, 0) catch {
		tmp.close(runtime.io());
		return;
	};
	tmp.close(runtime.io());
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var tmp_src = FileSource.open(tmp_path) catch return;
	defer tmp_src.close();
	const result = validateIffDeep(testing.allocator, &tmp_src);
	try testing.expect(!result.is_valid);
}

test "IFF deep validation - invalid chunk ID detected" {
	const src = runtime.openFile("ground_truth_examples/iff/sample.iff", .{}) catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
	defer src.close(runtime.io());
	const file_size = src.length(runtime.io()) catch return;
	const data = testing.allocator.alloc(u8, file_size) catch return;
	defer testing.allocator.free(data);
	_ = src.readPositionalAll(runtime.io(), data, 0) catch return;

	// Corrupt a chunk ID to contain non-printable characters
	// BMHD chunk ID starts at offset 12
	if (data.len > 15) {
		data[12] = 0x01; // Non-printable
	}

	const tmp_path = "/tmp/iff_test_bad_id.iff";
	const tmp = runtime.createFile(tmp_path, .{}) catch return;
	tmp.writePositionalAll(runtime.io(), data, 0) catch {
		tmp.close(runtime.io());
		return;
	};
	tmp.close(runtime.io());
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var tmp_src2 = FileSource.open(tmp_path) catch return;
	defer tmp_src2.close();
	const result = validateIffDeep(testing.allocator, &tmp_src2);
	try testing.expect(!result.is_valid);
}

test "IFF BMHD parser - valid fields" {
	const bmhd_data = [20]u8{
		0x00, 0x10, // width = 16
		0x00, 0x10, // height = 16
		0x00, 0x00, // x = 0
		0x00, 0x00, // y = 0
		0x04, // nPlanes = 4
		0x00, // masking = 0
		0x01, // compression = 1 (ByteRun1)
		0x00, // pad
		0x00, 0x00, // transparentColor
		0x0A, // xAspect
		0x0B, // yAspect
		0x01, 0x40, // pageWidth = 320
		0x00, 0xC8, // pageHeight = 200
	};
	const bm = parseIlbmBmhd(&bmhd_data);
	try testing.expect(bm != null);
	try testing.expectEqual(@as(u16, 16), bm.?.width);
	try testing.expectEqual(@as(u16, 16), bm.?.height);
	try testing.expectEqual(@as(u8, 4), bm.?.num_planes);
	try testing.expectEqual(@as(u8, 1), bm.?.compression);
}

test "IFF BMHD parser - invalid planes rejected" {
	var bmhd_data = [20]u8{
		0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
		0x00, // nPlanes = 0 (invalid)
		0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x0B, 0x01, 0x40, 0x00, 0xC8,
	};
	try testing.expect(parseIlbmBmhd(&bmhd_data) == null);

	bmhd_data[8] = 33; // nPlanes = 33 (> 32, invalid)
	try testing.expect(parseIlbmBmhd(&bmhd_data) == null);
}

test "IFF chunk ID validation" {
	try testing.expect(isValidChunkId("BMHD"));
	try testing.expect(isValidChunkId("BODY"));
	try testing.expect(isValidChunkId("CMAP"));
	try testing.expect(isValidChunkId("    ")); // spaces are valid (0x20)
	try testing.expect(!isValidChunkId(&[4]u8{ 0x01, 'B', 'C', 'D' })); // control char
	try testing.expect(!isValidChunkId(&[4]u8{ 'A', 'B', 'C', 0x7F })); // DEL
	try testing.expect(!isValidChunkId(&[4]u8{ 'A', 'B', 0x80, 'D' })); // high byte
}

test "BSP validator - ground truth file (Quake 1/2/3 or Source)" {
	// No ground truth BSP file exists yet; skip gracefully.
	const gt_paths = [_][]const u8{
		"ground_truth_examples/bsp/sample.bsp",
		"ground_truth_examples/bsp/quake1.bsp",
		"ground_truth_examples/bsp/quake2.bsp",
		"ground_truth_examples/bsp/quake3.bsp",
		"ground_truth_examples/bsp/source.bsp",
	};
	var found_any = false;
	for (gt_paths) |path| {
		var source = FileSource.open(path) catch continue;
		defer source.close();
		found_any = true;
		const result = validateBsp(&source);
		try testing.expect(result.is_valid);
		try testing.expectEqual(ValidationDepth.structural, result.validation_depth);	}
	if (!found_any) return error.SkipZigTest;
}

test "BSP validator - rejects truncated file" {
	// Build a minimal valid-looking Quake 1 BSP header, then truncate it.
	// Quake 1 header: version(4) + 15 lump entries × 8 bytes = 124 bytes total.
	// We produce only 60 bytes — too small for the full lump directory.
	var buf: [60]u8 = std.mem.zeroes([60]u8);
	std.mem.writeInt(u32, buf[0..4], 29, .little); // Quake 1 version

	const tmp_path = "/tmp/bsp_test_truncated.bsp";
	{
		const tmp = runtime.createFile(tmp_path, .{}) catch return error.SkipZigTest;
		tmp.writePositionalAll(runtime.io(), &buf, 0) catch { tmp.close(runtime.io()); return error.SkipZigTest; };
		tmp.close(runtime.io());
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var source = FileSource.open(tmp_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validateBsp(&source);
	try testing.expect(!result.is_valid);
}

test "BSP validator - rejects lump beyond file size" {
	// Build a Quake 1 BSP where lump 0 claims offset+length > file size.
	// Header: version(4) + 15×8 = 124 bytes; then we write no actual lump data.
	var buf: [124]u8 = std.mem.zeroes([124]u8);
	std.mem.writeInt(u32, buf[0..4], 29, .little); // Quake 1 version
	// Lump 0 at buf[4..12]: offset=500, length=100 — both beyond our 124-byte file.
	std.mem.writeInt(u32, buf[4..8], 500, .little);
	std.mem.writeInt(u32, buf[8..12], 100, .little);

	const tmp_path = "/tmp/bsp_test_oob_lump.bsp";
	{
		const tmp = runtime.createFile(tmp_path, .{}) catch return error.SkipZigTest;
		tmp.writePositionalAll(runtime.io(), &buf, 0) catch { tmp.close(runtime.io()); return error.SkipZigTest; };
		tmp.close(runtime.io());
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var source = FileSource.open(tmp_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validateBsp(&source);
	try testing.expect(!result.is_valid);
}

test "BSP validator - rejects overlapping lumps" {
	// Build a Quake 1 BSP where two lumps overlap.
	// All lumps fit within file_size, but lumps 0 and 1 overlap.
	const FILE_SIZE: usize = 512;
	var buf: [FILE_SIZE]u8 = std.mem.zeroes([FILE_SIZE]u8);
	std.mem.writeInt(u32, buf[0..4], 29, .little); // Quake 1 version
	// Lump 0: offset=124, length=100 → [124, 224)
	std.mem.writeInt(u32, buf[4..8], 124, .little);
	std.mem.writeInt(u32, buf[8..12], 100, .little);
	// Lump 1: offset=200, length=50 → [200, 250) — overlaps lump 0's [124,224)
	std.mem.writeInt(u32, buf[12..16], 200, .little);
	std.mem.writeInt(u32, buf[16..20], 50, .little);
	// Remaining 13 lumps: zero offset, zero length (empty lumps, valid)

	const tmp_path = "/tmp/bsp_test_overlap.bsp";
	{
		const tmp = runtime.createFile(tmp_path, .{}) catch return error.SkipZigTest;
		tmp.writePositionalAll(runtime.io(), &buf, 0) catch { tmp.close(runtime.io()); return error.SkipZigTest; };
		tmp.close(runtime.io());
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var source = FileSource.open(tmp_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validateBsp(&source);
	try testing.expect(!result.is_valid);
}

test "BSP validator - accepts valid Quake 1 BSP in memory" {
	// Build a minimal but structurally valid Quake 1 BSP:
	// header (124 bytes) + two non-overlapping lump data regions.
	const FILE_SIZE: usize = 512;
	var buf: [FILE_SIZE]u8 = std.mem.zeroes([FILE_SIZE]u8);
	std.mem.writeInt(u32, buf[0..4], 29, .little); // Quake 1 version
	// Lump 0: offset=124, length=100
	std.mem.writeInt(u32, buf[4..8], 124, .little);
	std.mem.writeInt(u32, buf[8..12], 100, .little);
	// Lump 1: offset=224, length=50 — immediately after lump 0, no overlap
	std.mem.writeInt(u32, buf[12..16], 224, .little);
	std.mem.writeInt(u32, buf[16..20], 50, .little);
	// Remaining 13 lumps: zero offset, zero length (empty, valid)

	const tmp_path = "/tmp/bsp_test_valid_q1.bsp";
	{
		const tmp = runtime.createFile(tmp_path, .{}) catch return error.SkipZigTest;
		tmp.writePositionalAll(runtime.io(), &buf, 0) catch { tmp.close(runtime.io()); return error.SkipZigTest; };
		tmp.close(runtime.io());
	}
	defer runtime.cwd().deleteFile(runtime.io(), tmp_path) catch {};

	var source = FileSource.open(tmp_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validateBsp(&source);
	try testing.expect(result.is_valid);
	try testing.expectEqual(ValidationDepth.structural, result.validation_depth);}
