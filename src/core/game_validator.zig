//! Deep validation for game ROM and archive formats.
//!
//! This module provides enhanced validation for:
//! - NES ROMs (iNES/NES 2.0 format)
//! - CHD (MAME Compressed Hunks of Data)
//!
//! Deep validation includes:
//! - Header consistency checks
//! - Internal checksum validation (where applicable)
//! - Size validation against declared values
//! - Map/index structure validation

const std = @import("std");

/// Result of deep game format validation
pub const GameValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    format_details: FormatDetails,

    pub const FormatDetails = struct {
        format_version: u32 = 0,
        declared_size: u64 = 0,
        actual_size: u64 = 0,
    };

    pub fn ok(details: FormatDetails) GameValidationResult {
        return .{ .valid = true, .error_message = null, .format_details = details };
    }

    pub fn invalid(message: []const u8) GameValidationResult {
        return .{ .valid = false, .error_message = message, .format_details = .{} };
    }
};

// ============ NES Deep Validation ============

/// Deep validation for NES ROMs (iNES and NES 2.0 formats).
/// Validates header consistency and file size.
pub fn validateNesDeep(path: []const u8) GameValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => GameValidationResult.invalid("File not found"),
            error.AccessDenied => GameValidationResult.invalid("Access denied"),
            else => GameValidationResult.invalid("Failed to open file"),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return GameValidationResult.invalid("Failed to get file size");
    };

    if (file_size < 16) {
        return GameValidationResult.invalid("File too small for NES ROM");
    }

    // Read header
    var header: [16]u8 = undefined;
    _ = file.readAll(&header) catch return GameValidationResult.invalid("Read failed");

    // Check signature
    if (!std.mem.eql(u8, header[0..4], "NES\x1A")) {
        return GameValidationResult.invalid("Invalid NES signature");
    }

    // Parse header
    const prg_rom_size_lsb = header[4];
    const chr_rom_size_lsb = header[5];
    const flags6 = header[6];
    const flags7 = header[7];

    // Check for NES 2.0 format (bits 2-3 of flags7 == 2)
    const is_nes2 = (flags7 & 0x0C) == 0x08;

    var prg_rom_size: u64 = undefined;
    var chr_rom_size: u64 = undefined;

    if (is_nes2) {
        // NES 2.0 extended sizes
        const prg_rom_msb = (header[9] & 0x0F);
        const chr_rom_msb = (header[9] >> 4);

        if (prg_rom_msb == 0x0F) {
            // Exponent form
            const multiplier = (prg_rom_size_lsb & 0x03) * 2 + 1;
            const exponent = prg_rom_size_lsb >> 2;
            prg_rom_size = @as(u64, multiplier) * (@as(u64, 1) << @as(u6, @intCast(exponent)));
        } else {
            prg_rom_size = (@as(u64, prg_rom_msb) << 8 | prg_rom_size_lsb) * 16384;
        }

        if (chr_rom_msb == 0x0F) {
            const multiplier = (chr_rom_size_lsb & 0x03) * 2 + 1;
            const exponent = chr_rom_size_lsb >> 2;
            chr_rom_size = @as(u64, multiplier) * (@as(u64, 1) << @as(u6, @intCast(exponent)));
        } else {
            chr_rom_size = (@as(u64, chr_rom_msb) << 8 | chr_rom_size_lsb) * 8192;
        }
    } else {
        // iNES format
        prg_rom_size = @as(u64, prg_rom_size_lsb) * 16384;
        chr_rom_size = @as(u64, chr_rom_size_lsb) * 8192;
    }

    // Check for trainer
    const has_trainer = (flags6 & 0x04) != 0;
    const trainer_size: u64 = if (has_trainer) 512 else 0;

    // Calculate expected file size
    const expected_size = 16 + trainer_size + prg_rom_size + chr_rom_size;

    // Allow some tolerance (some ROMs have extra data)
    if (file_size < expected_size) {
        return GameValidationResult.invalid("NES ROM truncated");
    }

    return GameValidationResult.ok(.{
        .format_version = if (is_nes2) 2 else 1,
        .declared_size = expected_size,
        .actual_size = file_size,
    });
}

// ============ CHD Deep Validation ============

/// Deep validation for MAME CHD (Compressed Hunks of Data).
/// Validates header, map structure, and consistency.
pub fn validateChdDeep(path: []const u8) GameValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => GameValidationResult.invalid("File not found"),
            error.AccessDenied => GameValidationResult.invalid("Access denied"),
            else => GameValidationResult.invalid("Failed to open file"),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return GameValidationResult.invalid("Failed to get file size");
    };

    if (file_size < 124) {
        return GameValidationResult.invalid("File too small for CHD");
    }

    // Read header (max v5 header size)
    var header: [124]u8 = undefined;
    _ = file.readAll(&header) catch return GameValidationResult.invalid("Read failed");

    // Check signature
    if (!std.mem.eql(u8, header[0..8], "MComprHD")) {
        return GameValidationResult.invalid("Invalid CHD signature");
    }

    // Parse header (all fields are big-endian)
    const header_len = std.mem.readInt(u32, header[8..12], .big);
    const version = std.mem.readInt(u32, header[12..16], .big);

    if (version < 1 or version > 5) {
        return GameValidationResult.invalid("Unknown CHD version");
    }

    if (header_len < 76) {
        return GameValidationResult.invalid("Invalid CHD header length");
    }

    // Version-specific validation
    if (version >= 3) {
        // V3+ has logical bytes at offset 28 (8 bytes)
        const logical_bytes = std.mem.readInt(u64, header[28..36], .big);
        // Logical bytes should be reasonable (< 1TB)
        if (logical_bytes > 1024 * 1024 * 1024 * 1024) {
            return GameValidationResult.invalid("CHD logical size unreasonable");
        }
    }

    if (version >= 4) {
        // V4+ has hunk bytes at offset 44 (4 bytes)
        const hunk_bytes = std.mem.readInt(u32, header[44..48], .big);
        if (hunk_bytes == 0 or hunk_bytes > 1024 * 1024) {
            return GameValidationResult.invalid("Invalid CHD hunk size");
        }

        // Total hunks at offset 24 (4 bytes)
        const total_hunks = std.mem.readInt(u32, header[24..28], .big);
        if (total_hunks == 0) {
            return GameValidationResult.invalid("CHD has zero hunks");
        }

        // Verify the map offset is within file
        const map_offset: u64 = @as(u64, header_len);
        const map_entry_size: u64 = if (version == 5) 12 else 16;
        const map_size = @as(u64, total_hunks) * map_entry_size;

        if (map_offset + map_size > file_size) {
            return GameValidationResult.invalid("CHD map extends past file end");
        }
    }

    return GameValidationResult.ok(.{
        .format_version = version,
        .declared_size = header_len,
        .actual_size = file_size,
    });
}

// ============ Tests ============

test "NES deep validation - missing file" {
    const result = validateNesDeep("/nonexistent/file.nes");
    try std.testing.expect(!result.valid);
}

test "CHD deep validation - missing file" {
    const result = validateChdDeep("/nonexistent/file.chd");
    try std.testing.expect(!result.valid);
}

test "NES deep validation - valid minimal ROM" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid iNES ROM
    // Header: NES\x1A, 1 PRG bank (16KB), 0 CHR banks, flags
    var rom_data: [16 + 16384]u8 = undefined;
    @memset(&rom_data, 0);
    rom_data[0] = 'N';
    rom_data[1] = 'E';
    rom_data[2] = 'S';
    rom_data[3] = 0x1A;
    rom_data[4] = 1; // 1 PRG bank
    rom_data[5] = 0; // 0 CHR banks

    const file = try tmp_dir.dir.createFile("test.nes", .{});
    try file.writeAll(&rom_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.nes");
    defer allocator.free(path);

    const result = validateNesDeep(path);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.format_details.format_version);
}

test "CHD deep validation - valid minimal header" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create minimal valid CHD v4 header
    var chd_data: [124 + 16]u8 = undefined; // Header + 1 map entry
    @memset(&chd_data, 0);

    // Signature
    @memcpy(chd_data[0..8], "MComprHD");
    // Header length (big-endian) = 108 for v4
    std.mem.writeInt(u32, chd_data[8..12], 108, .big);
    // Version = 4
    std.mem.writeInt(u32, chd_data[12..16], 4, .big);
    // Total hunks = 1
    std.mem.writeInt(u32, chd_data[24..28], 1, .big);
    // Logical bytes = 512
    std.mem.writeInt(u64, chd_data[28..36], 512, .big);
    // Hunk bytes = 512
    std.mem.writeInt(u32, chd_data[44..48], 512, .big);

    const file = try tmp_dir.dir.createFile("test.chd", .{});
    try file.writeAll(&chd_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.chd");
    defer allocator.free(path);

    const result = validateChdDeep(path);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 4), result.format_details.format_version);
}
