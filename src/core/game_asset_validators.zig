//! Game asset format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for game asset formats: WAD (DOOM), PAK (Quake), LSPK (Larian Studios),
//! Chromium PAK, BSP (Quake/Source maps), VPK (Valve PAK), IFF, and Blorb.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;

const errmsg = @import("error_messages.zig");

const testing = std.testing;

// ============ WAD (DOOM) Validator ============

/// Validate WAD (DOOM) archive format.
/// WAD files start with "IWAD" (internal) or "PWAD" (patch) followed by
/// lump count (4 bytes, little-endian) and directory offset (4 bytes, little-endian).
pub fn validateWad(file: std.fs.File) ValidationResult {
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
pub fn validateWadDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.wad, .failed_to_open, "WAD file");
    };
    defer file.close();

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
pub fn validatePak(file: std.fs.File) ValidationResult {
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
pub fn validatePakDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.pak, .failed_to_open, "PAK file");
    };
    defer file.close();

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
pub fn validateLspk(file: std.fs.File) ValidationResult {
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
pub fn validateChromiumPak(file: std.fs.File) ValidationResult {
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
/// BSP files use version numbers at offset 0 to identify the format variant.
pub fn validateBsp(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.bsp, .failed_to_seek, "to start");

    var header: [8]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.bsp, .failed_to_read, "BSP header");

    if (header_read < 8) {
        return ValidationResult.invalidCode(.bsp, .file_too_small, "BSP");
    }

    // BSP version at offset 0 (little-endian)
    const version = std.mem.readInt(u32, header[0..4], .little);

    // Known BSP versions:
    // 29 = Quake 1
    // 30 = Half-Life 1 / GoldSrc
    // 38 = Quake 2
    // 46, 47 = Quake 3
    // 19, 20, 21 = Source engine (VBSP)
    // Also check for "IBSP" or "VBSP" strings
    const valid_versions = [_]u32{ 29, 30, 38, 46, 47, 19, 20, 21 };
    var version_valid = false;
    for (valid_versions) |v| {
        if (version == v) {
            version_valid = true;
            break;
        }
    }

    // Check for IBSP (id BSP) or VBSP (Valve BSP) magic strings
    if (!version_valid) {
        if (std.mem.eql(u8, header[0..4], "IBSP") or std.mem.eql(u8, header[0..4], "VBSP")) {
            // Version is in next 4 bytes
            const string_version = std.mem.readInt(u32, header[4..8], .little);
            for (valid_versions) |v| {
                if (string_version == v) {
                    version_valid = true;
                    break;
                }
            }
        }
    }

    if (!version_valid) {
        return ValidationResult.invalidCode(.bsp, .unknown_element, "BSP version");
    }

    // No CRC/hash — version check only, no structural parsing
    return ValidationResult.structuralOnly(.bsp);
}

// ============ VPK (Valve PAK) Validator ============

/// Validate VPK (Valve PAK) file format.
/// VPK files start with signature 0x55AA1234 followed by version.
pub fn validateVpk(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.vpk, .failed_to_seek, "to start");

    var header: [12]u8 = undefined;
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

    // Tree size (VPK v1 and v2 both have this)
    const tree_size = std.mem.readInt(u32, header[8..12], .little);
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.vpk, .failed_to_get, "file size");

    // Tree must fit in file
    if (tree_size > file_size) {
        return ValidationResult.invalidCodeMsg(.vpk, .exceeds_bounds, "Tree size", "Tree size exceeds file size");
    }

    // No CRC/hash — header + tree size check only, no deep structural parsing
    return ValidationResult.structuralOnly(.vpk);
}

// ============ IFF/Blorb Validators ============

/// Validate generic IFF (Interchange File Format) container.
/// IFF files have "FORM" signature followed by 4-byte size (big-endian) and 4-byte type.
pub fn validateIff(file: std.fs.File) ValidationResult {
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

/// Deep validation for IFF files - parses all nested chunks.
pub fn validateIffDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalidCode(.iff, .failed_to_open, "IFF file");
    };
    defer file.close();

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

    // Parse all chunks within the FORM
    var pos: u64 = 12; // After FORM + size + type
    var chunk_count: u32 = 0;
    const form_end = 8 + @as(u64, form_size);

    while (pos + 8 <= form_end) {
        file.seekTo(pos) catch break;

        var chunk_header: [8]u8 = undefined;
        const bytes_read = file.read(&chunk_header) catch break;
        if (bytes_read < 8) break;

        const chunk_sz = std.mem.readInt(u32, chunk_header[4..8], .big);

        // Verify chunk doesn't exceed container
        if (pos + 8 + chunk_sz > form_end) {
            return ValidationResult.invalid(.iff, "Chunk extends beyond FORM boundary");
        }

        chunk_count += 1;

        // Move to next chunk (pad to even boundary)
        pos += 8 + chunk_sz;
        if (chunk_sz % 2 == 1 and pos < form_end) pos += 1;
    }

    if (chunk_count == 0) {
        return ValidationResult.invalid(.iff, "No chunks found in FORM");
    }

    return ValidationResult.okWithDepth(.iff, .structural);
}

/// Validate Blorb (Interactive Fiction resource) format.
/// Blorb is an IFF container with IFRS (Z-machine) or IFZS (Glulx) form type.
pub fn validateBlorb(file: std.fs.File) ValidationResult {
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
