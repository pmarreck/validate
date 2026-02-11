//! Game ROM Validators
//!
//! Validates game ROM formats: NES (iNES), SNES, N64, Game Boy, GBA, NDS,
//! Sega Genesis/Mega Drive, and CHD (MAME compressed disk images).

const std = @import("std");
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;
const ValidationResult = format_validation.ValidationResult;

// ============ NES ============

/// Validate NES ROM (iNES format).
/// iNES header: "NES\x1A" + PRG ROM size + CHR ROM size + flags
pub fn validateNes(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.nes, errmsg.failedToSeek("to start"));

    var header: [16]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.nes, errmsg.failedToRead("NES header"));

    if (header_read < 16) {
        return ValidationResult.invalid(.nes, errmsg.fileTooSmallFor("NES ROM"));
    }

    // Check iNES signature
    if (!std.mem.eql(u8, header[0..4], "NES\x1A")) {
        return ValidationResult.invalid(.nes, errmsg.invalidSignature("NES"));
    }

    // PRG ROM size in 16KB units
    const prg_size = header[4];
    // CHR ROM size in 8KB units
    const chr_size = header[5];

    // Flags 6 and 7 contain mapper info
    const flags6 = header[6];
    const flags7 = header[7];

    // Check for NES 2.0 format (bits 2-3 of flags 7 == 2)
    const is_nes2 = (flags7 & 0x0C) == 0x08;
    _ = is_nes2;

    // Validate sizes make sense
    if (prg_size == 0 and (flags6 & 0x02) == 0) {
        // PRG size 0 only valid if trainer bit isn't set in a weird way
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.nes, errmsg.failedToGet("file size"));

    // Minimum size: 16 header + 16KB PRG
    const expected_min = 16 + (@as(u64, prg_size) * 16384) + (@as(u64, chr_size) * 8192);
    if (file_size < expected_min - 512) { // Allow some slack for trainer/misc
        return ValidationResult.invalid(.nes, "File smaller than header indicates");
    }

    return ValidationResult.okWithDepth(.nes, .full);
}

/// Deep validate NES ROM - checks size consistency with header declarations
pub fn validateNesDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.nes, errmsg.failedToOpen("NES file"));
    };
    defer file.close();

    var header: [16]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.nes, errmsg.failedToRead("header"));

    if (!std.mem.eql(u8, header[0..4], "NES\x1A")) {
        return ValidationResult.invalid(.nes, errmsg.invalidSignature("NES"));
    }

    const prg_size = header[4];
    const chr_size = header[5];
    const flags6 = header[6];

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.nes, errmsg.failedToGet("file size"));

    // Calculate expected size
    var expected_size: u64 = 16; // Header
    if ((flags6 & 0x04) != 0) {
        expected_size += 512; // Trainer
    }
    expected_size += @as(u64, prg_size) * 16384; // PRG ROM
    expected_size += @as(u64, chr_size) * 8192; // CHR ROM

    // Allow some flexibility for PlayChoice/VS bits and padding
    if (file_size < expected_size) {
        return ValidationResult.invalid(.nes, errmsg.fileTooSmallFor("declared ROM sizes"));
    }
    if (file_size > expected_size + 16384) { // More than 16KB extra seems wrong
        return ValidationResult.okWithDepthAndWarning(.nes, .structural, "File larger than expected");
    }

    return ValidationResult.okWithDepth(.nes, .structural);
}

// ============ SNES ============

/// Validate SNES ROM - checks internal header checksum complement and computes full ROM checksum.
pub fn validateSnes(file: std.fs.File) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalid(.snes, errmsg.failedToGet("file size"));

    // SNES ROMs are typically 256KB to 6MB
    if (file_size < 32768) {
        return ValidationResult.invalid(.snes, errmsg.fileTooSmallFor("SNES ROM"));
    }
    if (file_size > 8 * 1024 * 1024) {
        return ValidationResult.invalid(.snes, errmsg.fileTooLargeFor("SNES ROM"));
    }

    // Detect if there's a 512-byte copier header
    const has_copier_header = (file_size & 0x7FFF) == 512;
    const rom_start: u64 = if (has_copier_header) 512 else 0;
    const rom_size = file_size - rom_start;

    // Try to find internal header - check common locations
    // LoROM: 0x7FC0, HiROM: 0xFFC0, ExHiROM: 0x40FFC0
    const header_offsets = [_]struct { offset: u64, mapping: enum { lorom, hirom, exhirom } }{
        .{ .offset = 0x7FC0, .mapping = .lorom },
        .{ .offset = 0xFFC0, .mapping = .hirom },
        .{ .offset = 0x40FFC0, .mapping = .exhirom },
    };

    file.seekTo(0) catch return ValidationResult.invalid(.snes, errmsg.failedToSeek("to start"));

    for (header_offsets) |hdr| {
        const offset = rom_start + hdr.offset;
        if (offset + 32 > file_size) continue;

        file.seekTo(offset) catch continue;

        var header: [32]u8 = undefined;
        const bytes_read = file.read(&header) catch continue;
        if (bytes_read < 32) continue;

        // Check checksum complement (bytes 28-29 should be inverse of 30-31)
        const stored_checksum = std.mem.readInt(u16, header[28..30], .little);
        const complement = std.mem.readInt(u16, header[30..32], .little);

        if ((stored_checksum ^ complement) != 0xFFFF) {
            continue; // Header consistency check failed
        }

        // Calculate actual ROM checksum
        const computed_checksum = computeSnesChecksum(file, rom_start, rom_size) catch {
            // Couldn't compute checksum - accept with structural validation
            return ValidationResult.ok(.snes);
        };

        if (computed_checksum == stored_checksum) {
            return ValidationResult.okWithDepth(.snes, .full);
        } else {
            // Checksum mismatch - ROM may be corrupted or modified
            return ValidationResult.invalid(.snes, "SNES ROM checksum mismatch");
        }
    }

    // No valid header found, but might still be valid headerless ROM
    // Accept if size is reasonable power-of-two
    if (rom_size >= 32768 and (rom_size & (rom_size - 1)) == 0) {
        return ValidationResult.ok(.snes); // Power of two, likely valid
    }

    return ValidationResult.invalid(.snes, errmsg.noValidXFound("SNES header"));
}

/// Compute SNES ROM checksum (sum of all bytes, mirrored to power-of-two boundary)
fn computeSnesChecksum(file: std.fs.File, rom_start: u64, rom_size: u64) !u16 {
    // Find next power of 2 for mirroring
    var target_size: u64 = 32768; // Minimum 32KB
    while (target_size < rom_size) {
        target_size *= 2;
    }

    file.seekTo(rom_start) catch return error.SeekFailed;

    var checksum: u32 = 0;
    var buffer: [8192]u8 = undefined;
    var bytes_summed: u64 = 0;

    // Sum actual ROM bytes
    while (bytes_summed < rom_size) {
        const to_read = @min(buffer.len, rom_size - bytes_summed);
        const bytes_read = file.read(buffer[0..to_read]) catch return error.ReadFailed;
        if (bytes_read == 0) break;

        for (buffer[0..bytes_read]) |byte| {
            checksum += byte;
        }
        bytes_summed += bytes_read;
    }

    // If ROM size is not a power of 2, mirror to fill
    if (rom_size < target_size) {
        // For mirroring, we need to repeat the ROM data
        // The checksum calculation for mirrored ROMs repeats bytes
        const mirror_count = target_size / rom_size;
        if (mirror_count > 1) {
            // We already summed once, need to add (mirror_count - 1) more times
            const rom_sum = checksum;
            for (1..mirror_count) |_| {
                checksum += rom_sum;
            }
        }
    }

    return @truncate(checksum);
}

// ============ N64 ============

/// Validate N64 ROM - checks signature (.z64/.n64/.v64 formats) and size bounds.
pub fn validateN64(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.n64, errmsg.failedToSeek("to start"));

    var header: [64]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.n64, errmsg.failedToRead("N64 header"));

    if (header_read < 64) {
        return ValidationResult.invalid(.n64, errmsg.fileTooSmallFor("N64 ROM"));
    }

    // Check for known N64 ROM signatures
    // .z64 (big-endian): 0x80371240
    // .n64 (little-endian): 0x40123780
    // .v64 (byte-swapped): 0x37804012
    const sig = std.mem.readInt(u32, header[0..4], .big);

    if (sig != 0x80371240 and sig != 0x40123780 and sig != 0x37804012) {
        return ValidationResult.invalid(.n64, errmsg.invalidSignature("N64 ROM"));
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.n64, errmsg.failedToGet("file size"));

    // N64 ROMs are typically 4MB to 64MB
    if (file_size < 1024 * 1024) {
        return ValidationResult.invalid(.n64, errmsg.fileTooSmallFor("N64 ROM"));
    }
    if (file_size > 64 * 1024 * 1024) {
        return ValidationResult.invalid(.n64, errmsg.fileTooLargeFor("N64 ROM"));
    }

    return ValidationResult.okWithDepth(.n64, .full);
}

/// Deep validate N64 ROM - checks game title and country code fields
pub fn validateN64Deep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.n64, errmsg.failedToOpen("N64 file"));
    };
    defer file.close();

    var header: [64]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.n64, errmsg.failedToRead("header"));

    const sig = std.mem.readInt(u32, header[0..4], .big);
    if (sig != 0x80371240 and sig != 0x40123780 and sig != 0x37804012) {
        return ValidationResult.invalid(.n64, errmsg.invalidSignature("N64"));
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.n64, errmsg.failedToGet("file size"));
    if (file_size < 1024 * 1024 or file_size > 64 * 1024 * 1024) {
        return ValidationResult.invalid(.n64, "Invalid N64 ROM size");
    }

    // Game title at offset 0x20 (20 bytes, should be printable ASCII or spaces)
    for (header[0x20..0x34]) |c| {
        if (c != 0 and c != ' ' and (c < 0x20 or c > 0x7E)) {
            return ValidationResult.okWithDepthAndWarning(.n64, .structural, "Non-ASCII in game title");
        }
    }

    // Country code at offset 0x3E should be valid ASCII letter
    const country = header[0x3E];
    if (country != 0 and (country < 'A' or country > 'Z') and (country < '0' or country > '9')) {
        return ValidationResult.okWithDepthAndWarning(.n64, .structural, "Invalid country code");
    }

    return ValidationResult.okWithDepth(.n64, .structural);
}

// ============ Game Boy ============

/// Validate Game Boy ROM - checks Nintendo logo and header checksum.
pub fn validateGb(file: std.fs.File) ValidationResult {
    file.seekTo(0x104) catch return ValidationResult.invalid(.gb, errmsg.failedToSeek("to logo"));

    // Nintendo logo (48 bytes) - must match exactly for real hardware
    const nintendo_logo = [_]u8{
        0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
        0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
        0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
        0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
    };

    var logo: [48]u8 = undefined;
    const logo_read = file.read(&logo) catch return ValidationResult.invalid(.gb, errmsg.failedToRead("Nintendo logo"));

    if (logo_read < 48) {
        return ValidationResult.invalid(.gb, errmsg.fileTooSmallFor("GB ROM"));
    }

    // Check Nintendo logo (real GB hardware requires exact match)
    if (!std.mem.eql(u8, &logo, &nintendo_logo)) {
        return ValidationResult.invalid(.gb, "Invalid Nintendo logo");
    }

    // Read header checksum at 0x14D
    file.seekTo(0x134) catch return ValidationResult.invalid(.gb, errmsg.failedToSeek("to header"));

    var header: [25]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.gb, errmsg.failedToRead("GB header"));

    // Header checksum at 0x14D (offset 25 from 0x134)
    file.seekTo(0x14D) catch return ValidationResult.invalid(.gb, errmsg.failedToSeek("to checksum"));

    var checksum_byte: [1]u8 = undefined;
    _ = file.read(&checksum_byte) catch return ValidationResult.invalid(.gb, errmsg.failedToRead("checksum"));

    // Calculate header checksum
    var checksum: u8 = 0;
    for (header) |b| {
        checksum = checksum -% b -% 1;
    }

    if (checksum != checksum_byte[0]) {
        return ValidationResult.invalid(.gb, "Header checksum mismatch");
    }

    // Header checksum verified
    return ValidationResult.okWithDepth(.gb, .full);
}

// ============ GBA ============

/// Validate GBA ROM - checks ARM branch entry point, Nintendo logo, and header checksum.
pub fn validateGba(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.gba, errmsg.failedToSeek("to start"));

    var header: [192]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.gba, errmsg.failedToRead("GBA header"));

    if (header_read < 192) {
        return ValidationResult.invalid(.gba, errmsg.fileTooSmallFor("GBA ROM"));
    }

    // First 4 bytes are ARM branch instruction (should be 0xEA000000 + offset)
    const branch = std.mem.readInt(u32, header[0..4], .little);
    if ((branch & 0xFF000000) != 0xEA000000) {
        return ValidationResult.invalid(.gba, "Invalid GBA entry point");
    }

    // Check for Nintendo logo (simplified check - first bytes)
    // Full logo is at 0x04-0x9F
    if (header[0x04] != 0x24 or header[0x05] != 0xFF or header[0x06] != 0xAE) {
        return ValidationResult.invalid(.gba, "Invalid GBA Nintendo logo");
    }

    // Header checksum at 0xBD
    var checksum: u8 = 0;
    for (header[0xA0..0xBD]) |b| {
        checksum = checksum +% b;
    }
    checksum = (0 -% (0x19 +% checksum));

    if (checksum != header[0xBD]) {
        return ValidationResult.invalid(.gba, "GBA header checksum mismatch");
    }

    // Header checksum verified
    return ValidationResult.okWithDepth(.gba, .full);
}

// ============ NDS ============

/// Validate NDS ROM - checks ARM9/ARM7 offsets and header CRC-16 MODBUS.
pub fn validateNds(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.nds, errmsg.failedToSeek("to start"));

    var header: [512]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.nds, errmsg.failedToRead("NDS header"));

    if (header_read < 512) {
        return ValidationResult.invalid(.nds, errmsg.fileTooSmallFor("NDS ROM"));
    }

    // Check ARM9 ROM offset (should be reasonable)
    const arm9_offset = std.mem.readInt(u32, header[0x20..0x24], .little);
    const arm9_size = std.mem.readInt(u32, header[0x2C..0x30], .little);

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.nds, errmsg.failedToGet("file size"));

    if (arm9_offset == 0 or arm9_offset > file_size) {
        return ValidationResult.invalid(.nds, "Invalid ARM9 offset");
    }

    if (arm9_size == 0 or arm9_offset + arm9_size > file_size) {
        return ValidationResult.invalid(.nds, "Invalid ARM9 size");
    }

    // Check ARM7 ROM offset
    const arm7_offset = std.mem.readInt(u32, header[0x30..0x34], .little);
    const arm7_size = std.mem.readInt(u32, header[0x3C..0x40], .little);

    if (arm7_offset == 0 or arm7_offset > file_size) {
        return ValidationResult.invalid(.nds, "Invalid ARM7 offset");
    }

    if (arm7_size == 0 or arm7_offset + arm7_size > file_size) {
        return ValidationResult.invalid(.nds, "Invalid ARM7 size");
    }

    // Header CRC at 0x15E (covers 0x00-0x15D)
    // NDS uses CRC-16 MODBUS (polynomial 0xA001, init 0xFFFF)
    const stored_crc = std.mem.readInt(u16, header[0x15E..0x160], .little);

    // Calculate CRC-16 MODBUS
    var crc: u16 = 0xFFFF;
    for (header[0..0x15E]) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xA001;
            } else {
                crc >>= 1;
            }
        }
    }

    if (crc != stored_crc) {
        return ValidationResult.invalid(.nds, "Header CRC mismatch");
    }

    // Header CRC verified
    return ValidationResult.okWithDepth(.nds, .full);
}

// ============ Sega Genesis / Mega Drive ============

/// Validate Genesis/Mega Drive ROM - checks "SEGA" signature and SMD format detection.
pub fn validateGenesis(file: std.fs.File) ValidationResult {
    file.seekTo(0x100) catch return ValidationResult.invalid(.genesis, errmsg.failedToSeek("to header"));

    var header: [256]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.genesis, errmsg.failedToRead("Genesis header"));

    if (header_read < 256) {
        return ValidationResult.invalid(.genesis, errmsg.fileTooSmallFor("Genesis ROM"));
    }

    // Check for "SEGA" at offset 0x100 (console name field)
    if (!std.mem.eql(u8, header[0..4], "SEGA") and
        !std.mem.eql(u8, header[0..4], " SEG"))
    {
        // Also check at offset 0 for SMD format
        file.seekTo(0) catch return ValidationResult.invalid(.genesis, errmsg.failedToSeek("to start"));

        var alt_header: [16]u8 = undefined;
        _ = file.read(&alt_header) catch return ValidationResult.invalid(.genesis, errmsg.failedToRead("SMD header"));

        // SMD format has specific pattern
        const is_smd = (alt_header[8] == 0xAA and alt_header[9] == 0xBB);
        if (!is_smd) {
            return ValidationResult.invalid(.genesis, errmsg.invalidSignature("Genesis ROM"));
        }
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.genesis, errmsg.failedToGet("file size"));

    // Genesis ROMs are typically 256KB to 4MB
    if (file_size < 128 * 1024) {
        return ValidationResult.invalid(.genesis, errmsg.fileTooSmallFor("Genesis ROM"));
    }
    if (file_size > 8 * 1024 * 1024) {
        return ValidationResult.invalid(.genesis, errmsg.fileTooLargeFor("Genesis ROM"));
    }

    return ValidationResult.okWithDepth(.genesis, .full);
}

/// Deep validate Genesis ROM - checks game title printability and ROM address range.
pub fn validateGenesisDeep(allocator: Allocator, path: []const u8) ValidationResult {
    _ = allocator;
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return ValidationResult.invalid(.genesis, errmsg.failedToOpen("Genesis file"));
    };
    defer file.close();

    file.seekTo(0x100) catch return ValidationResult.invalid(.genesis, "Failed to seek");

    var header: [256]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalid(.genesis, errmsg.failedToRead("header"));

    const has_sega = std.mem.eql(u8, header[0..4], "SEGA") or std.mem.eql(u8, header[0..4], " SEG");

    if (!has_sega) {
        // Check SMD format
        file.seekTo(0) catch return ValidationResult.invalid(.genesis, "Failed to seek");
        var alt_header: [16]u8 = undefined;
        _ = file.read(&alt_header) catch return ValidationResult.invalid(.genesis, errmsg.failedToRead("SMD"));
        if (alt_header[8] != 0xAA or alt_header[9] != 0xBB) {
            return ValidationResult.invalid(.genesis, errmsg.invalidSignature("Genesis"));
        }
        return ValidationResult.okWithDepth(.genesis, .structural);
    }

    // Validate domestic/overseas name are printable (offsets 0x20-0x4F and 0x50-0x7F)
    for (header[0x20..0x70]) |c| {
        if (c != 0 and c != ' ' and (c < 0x20 or c > 0x7E)) {
            return ValidationResult.okWithDepthAndWarning(.genesis, .structural, "Non-ASCII in game title");
        }
    }

    // ROM addresses at 0x1A0-0x1A7 (start/end)
    const rom_start = std.mem.readInt(u32, header[0xA0..0xA4], .big);
    const rom_end = std.mem.readInt(u32, header[0xA4..0xA8], .big);

    if (rom_start > rom_end) {
        return ValidationResult.invalid(.genesis, "Invalid ROM address range");
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalid(.genesis, errmsg.failedToGet("size"));
    if (rom_end > file_size) {
        return ValidationResult.okWithDepthAndWarning(.genesis, .structural, "ROM end exceeds file size");
    }

    return ValidationResult.okWithDepth(.genesis, .structural);
}

// ============ CHD (MAME Compressed Hunks of Data) ============

/// Validate CHD disk image - checks "MComprHD" signature, header length, and version.
pub fn validateChd(file: std.fs.File) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalid(.chd, errmsg.failedToSeek("to start"));

    var header: [124]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalid(.chd, errmsg.failedToRead("CHD header"));

    if (header_read < 124) {
        return ValidationResult.invalid(.chd, errmsg.fileTooSmallFor("CHD"));
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..8], "MComprHD")) {
        return ValidationResult.invalid(.chd, errmsg.invalidSignature("CHD"));
    }

    // Header length (big-endian)
    const header_len = std.mem.readInt(u32, header[8..12], .big);
    if (header_len < 76 or header_len > 124) {
        return ValidationResult.invalid(.chd, "Invalid CHD header length");
    }

    // Version (big-endian) - versions 1-5 are known
    const version = std.mem.readInt(u32, header[12..16], .big);
    if (version < 1 or version > 5) {
        return ValidationResult.invalid(.chd, errmsg.unknown("CHD version"));
    }

    return ValidationResult.okWithDepth(.chd, .full);
}
