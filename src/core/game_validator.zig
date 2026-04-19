//! Game ROM Validators
//!
//! Validates game ROM formats: NES (iNES), SNES, N64, Game Boy, GBA, NDS,
//! Sega Genesis/Mega Drive, and CHD (MAME compressed disk images).

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;
const ValidationResult = format_validation.ValidationResult;

const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;
const FileFormat = format_validation.FileFormat;

// ============ NES ============

/// Validate NES ROM (iNES format).
/// iNES header: "NES\x1A" + PRG ROM size + CHR ROM size + flags
pub fn validateNes(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.nes, .failed_to_seek, "to start");

    var header: [16]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.nes, .failed_to_read, "NES header");

    if (header_read < 16) {
        return ValidationResult.invalidCode(.nes, .file_too_small, "NES ROM");
    }

    // Check iNES signature
    if (!std.mem.eql(u8, header[0..4], "NES\x1A")) {
        return ValidationResult.invalidCode(.nes, .invalid_signature, "NES");
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

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.nes, .failed_to_get, "file size");

    // Minimum size: 16 header + 16KB PRG
    const expected_min = 16 + (@as(u64, prg_size) * 16384) + (@as(u64, chr_size) * 8192);
    if (file_size < expected_min - 512) { // Allow some slack for trainer/misc
        return ValidationResult.invalid(.nes, "File smaller than header indicates");
    }

    return ValidationResult.okWithDepth(.nes, .structural);
}

/// Deep validate NES ROM - checks size consistency with header declarations
pub fn validateNesDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    _ = allocator;
    const file = source;

    var header: [16]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.nes, .failed_to_read, "header");

    if (!std.mem.eql(u8, header[0..4], "NES\x1A")) {
        return ValidationResult.invalidCode(.nes, .invalid_signature, "NES");
    }

    const prg_size = header[4];
    const chr_size = header[5];
    const flags6 = header[6];

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.nes, .failed_to_get, "file size");

    // Calculate expected size
    var expected_size: u64 = 16; // Header
    if ((flags6 & 0x04) != 0) {
        expected_size += 512; // Trainer
    }
    expected_size += @as(u64, prg_size) * 16384; // PRG ROM
    expected_size += @as(u64, chr_size) * 8192; // CHR ROM

    // Allow some flexibility for PlayChoice/VS bits and padding
    if (file_size < expected_size) {
        return ValidationResult.invalidCode(.nes, .file_too_small, "declared ROM sizes");
    }
    if (file_size > expected_size + 16384) { // More than 16KB extra seems wrong
        return ValidationResult.okWithDepthAndWarning(.nes, .structural, "File larger than expected");
    }

    return ValidationResult.okWithDepth(.nes, .structural);
}

// ============ SNES ============

/// Validate SNES ROM - checks internal header checksum complement and computes full ROM checksum.
pub fn validateSnes(file: *FileSource) ValidationResult {
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.snes, .failed_to_get, "file size");

    // SNES ROMs are typically 256KB to 6MB
    if (file_size < 32768) {
        return ValidationResult.invalidCode(.snes, .file_too_small, "SNES ROM");
    }
    if (file_size > 8 * 1024 * 1024) {
        return ValidationResult.invalidCode(.snes, .file_too_large, "SNES ROM");
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

    file.seekTo(0) catch return ValidationResult.invalidCode(.snes, .failed_to_seek, "to start");

    for (header_offsets) |hdr| {
        const offset = rom_start + hdr.offset;
        if (offset + 32 > file_size) continue;

        file.seekTo(offset) catch continue;

        var header: [32]u8 = undefined;
        const bytes_read = file.read(&header) catch continue;
        if (bytes_read < 32) continue;

        // Check checksum complement: offset 0x1C (28) = complement, offset 0x1E (30) = checksum
        const complement = std.mem.readInt(u16, header[28..30], .little);
        const stored_checksum = std.mem.readInt(u16, header[30..32], .little);

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
            return ValidationResult.invalidCodeMsg(.snes, .checksum_mismatch, "SNES ROM", "SNES ROM checksum mismatch");
        }
    }

    // No valid header found, but might still be valid headerless ROM
    // Accept if size is reasonable power-of-two
    if (rom_size >= 32768 and (rom_size & (rom_size - 1)) == 0) {
        return ValidationResult.ok(.snes); // Power of two, likely valid
    }

    return ValidationResult.invalidCode(.snes, .no_valid_x_found, "SNES header");
}

/// Compute SNES ROM checksum (sum of all bytes, mirrored to power-of-two boundary)
fn computeSnesChecksum(file: *FileSource, rom_start: u64, rom_size: u64) !u16 {
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
pub fn validateN64(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.n64, .failed_to_seek, "to start");

    var header: [64]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.n64, .failed_to_read, "N64 header");

    if (header_read < 64) {
        return ValidationResult.invalidCode(.n64, .file_too_small, "N64 ROM");
    }

    // Check for known N64 ROM signatures
    // .z64 (big-endian): 0x80371240
    // .n64 (little-endian): 0x40123780
    // .v64 (byte-swapped): 0x37804012
    const sig = std.mem.readInt(u32, header[0..4], .big);

    if (sig != 0x80371240 and sig != 0x40123780 and sig != 0x37804012) {
        return ValidationResult.invalidCode(.n64, .invalid_signature, "N64 ROM");
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.n64, .failed_to_get, "file size");

    // N64 ROMs are typically 4MB to 64MB
    if (file_size < 1024 * 1024) {
        return ValidationResult.invalidCode(.n64, .file_too_small, "N64 ROM");
    }
    if (file_size > 64 * 1024 * 1024) {
        return ValidationResult.invalidCode(.n64, .file_too_large, "N64 ROM");
    }

    return ValidationResult.okWithDepth(.n64, .structural);
}

/// CIC variant detected from bootcode CRC-32.
const CicVariant = enum {
    cic_6101,
    cic_6102,
    cic_6103,
    cic_6105,
    cic_6106,
    unknown,
};

/// Detect CIC variant by computing CRC-32 of the bootcode region (0x40-0xFFF).
/// Reference: cen64/si/cic.c, n64hijack/src/crc.h
fn detectCicVariant(rom: []const u8) CicVariant {
    if (rom.len < 0x1000) return .unknown;

    // CRC-32 (standard polynomial 0xEDB88320) of bootcode
    var crc: u32 = 0xFFFFFFFF;
    for (rom[0x40..0x1000]) |byte| {
        crc = (crc >> 8) ^ crc32Table[(crc ^ byte) & 0xFF];
    }
    crc = ~crc;

    return switch (crc) {
        0x6170A4A1 => .cic_6101,
        0x90BB6CB5, 0x009E9EA3 => .cic_6102, // NUS-6102 and NUS-7102
        0x0B050EE0 => .cic_6103,
        0x98BC2C86 => .cic_6105,
        0xACC8580A => .cic_6106,
        else => .unknown,
    };
}

/// CRC-32 lookup table (polynomial 0xEDB88320)
const crc32Table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            if (c & 1 != 0) {
                c = 0xEDB88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        table[n] = c;
    }
    break :blk table;
};

/// Unified N64 CRC algorithm supporting all CIC variants (6101/6102/6103/6105/6106).
/// The core loop is identical; differences are:
/// - CIC-6105: t1 accumulates from bootcode lookup table instead of t5^d
/// - CIC-6103: final combine uses + instead of ^
/// - CIC-6106: final combine uses * instead of ^
/// Reference: n64hijack/src/crc.h by Parasyte/Andreas Sterbenz
fn computeN64Crc(rom: []const u8, cic: CicVariant) ?struct { crc1: u32, crc2: u32 } {
    if (rom.len < 0x101000) return null;

    const seed: u32 = switch (cic) {
        .cic_6101, .cic_6102 => 0xF8CA4DDC,
        .cic_6103 => 0xA3886759,
        .cic_6105 => 0xDF26F436,
        .cic_6106 => 0x1FEA617A,
        .unknown => return null,
    };

    var t1: u32 = seed;
    var t2: u32 = seed;
    var t3: u32 = seed;
    var t4: u32 = seed;
    var t5: u32 = seed;
    var t6: u32 = seed;

    var i: usize = 0x1000;
    while (i < 0x101000) : (i += 4) {
        const d = std.mem.readInt(u32, rom[i..][0..4], .big);
        const r = t6 +% d;
        if (r < t6) t4 +%= 1;
        t6 = r;
        t3 ^= d;
        const shift: u5 = @truncate(d);
        const rotated = std.math.rotl(u32, d, shift);
        t5 +%= rotated;
        if (t2 > d) {
            t2 ^= rotated;
        } else {
            t2 ^= t6 ^ d;
        }

        // CIC-6105: t1 accumulates from bootcode lookup table
        if (cic == .cic_6105) {
            const lookup = std.mem.readInt(u32, rom[0x750 + (i & 0xFF) ..][0..4], .big);
            t1 +%= lookup ^ d;
        } else {
            t1 +%= t5 ^ d;
        }
    }

    // Final combine differs by CIC variant
    return switch (cic) {
        .cic_6103 => .{
            .crc1 = (t6 ^ t4) +% t3,
            .crc2 = (t5 ^ t2) +% t1,
        },
        .cic_6106 => .{
            .crc1 = (t6 *% t4) +% t3,
            .crc2 = (t5 *% t2) +% t1,
        },
        else => .{
            .crc1 = t6 ^ t4 ^ t3,
            .crc2 = t5 ^ t2 ^ t1,
        },
    };
}

/// Normalize N64 ROM data to big-endian (.z64) format in-place.
/// Detects byte-swap format from the first 4 bytes and converts.
fn normalizeN64ByteOrder(rom: []u8) void {
    const sig = std.mem.readInt(u32, rom[0..4], .big);
    if (sig == 0x80371240) return; // Already big-endian (.z64)

    if (sig == 0x40123780) {
        // Little-endian (.n64) — swap every 4 bytes
        var i: usize = 0;
        while (i + 3 < rom.len) : (i += 4) {
            const tmp0 = rom[i];
            const tmp1 = rom[i + 1];
            rom[i] = rom[i + 3];
            rom[i + 1] = rom[i + 2];
            rom[i + 2] = tmp1;
            rom[i + 3] = tmp0;
        }
    } else if (sig == 0x37804012) {
        // Byte-swapped (.v64) — swap every 2 bytes
        var i: usize = 0;
        while (i + 1 < rom.len) : (i += 2) {
            const tmp = rom[i];
            rom[i] = rom[i + 1];
            rom[i + 1] = tmp;
        }
    }
}

/// Deep validate N64 ROM - verifies CRC integrity using CIC-auto-detection.
/// Auto-detects CIC variant from bootcode CRC-32, then validates ROM CRC.
pub fn validateN64Deep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.n64, .failed_to_get, "file size");
    if (file_size < 1024 * 1024 or file_size > 64 * 1024 * 1024) {
        return ValidationResult.invalidCode(.n64, .invalid_value, "N64 ROM size");
    }

    // Need at least 0x101000 bytes for CRC computation
    if (file_size < 0x101000) {
        return ValidationResult.okWithDepth(.n64, .structural);
    }

    // N64 validator needs a mutable copy (normalizeN64ByteOrder modifies in-place)
    const rom = allocator.alloc(u8, @intCast(file_size)) catch {
        return ValidationResult.okWithDepth(.n64, .structural);
    };
    defer allocator.free(rom);

    if (file.getMappedSlice()) |mapped| {
        @memcpy(rom, mapped);
    } else {
        file.seekTo(0) catch return ValidationResult.invalidCode(.n64, .failed_to_seek, "to start");
        const n = file.readAll(rom) catch return ValidationResult.invalidCode(.n64, .failed_to_read, "N64 ROM");
        if (n != file_size) return ValidationResult.invalidCode(.n64, .incomplete, "N64 ROM");
    }

    const sig = std.mem.readInt(u32, rom[0..4], .big);
    if (sig != 0x80371240 and sig != 0x40123780 and sig != 0x37804012) {
        return ValidationResult.invalidCode(.n64, .invalid_signature, "N64");
    }

    // Normalize to big-endian for CRC computation
    normalizeN64ByteOrder(rom);

    // Stored CRC values at 0x10-0x17 (now in big-endian)
    const stored_crc1 = std.mem.readInt(u32, rom[0x10..0x14], .big);
    const stored_crc2 = std.mem.readInt(u32, rom[0x14..0x18], .big);

    // Auto-detect CIC variant from bootcode
    const cic = detectCicVariant(rom);

    if (cic != .unknown) {
        if (computeN64Crc(rom, cic)) |computed| {
            if (computed.crc1 == stored_crc1 and computed.crc2 == stored_crc2) {
                return ValidationResult.okWithDepth(.n64, .full);
            }
        }
    }

    // If auto-detect failed or CRC didn't match, try all variants as fallback
    const all_variants = [_]CicVariant{ .cic_6102, .cic_6101, .cic_6103, .cic_6105, .cic_6106 };
    for (all_variants) |variant| {
        if (variant == cic) continue; // Already tried
        if (computeN64Crc(rom, variant)) |computed| {
            if (computed.crc1 == stored_crc1 and computed.crc2 == stored_crc2) {
                return ValidationResult.okWithDepth(.n64, .full);
            }
        }
    }

    return ValidationResult.invalidCodeMsg(.n64, .checksum_mismatch, "N64 ROM CRC", "N64 ROM CRC mismatch");
}

// ============ Game Boy ============

/// Validate Game Boy ROM - checks Nintendo logo and header checksum.
pub fn validateGb(file: *FileSource) ValidationResult {
    file.seekTo(0x104) catch return ValidationResult.invalidCode(.gb, .failed_to_seek, "to logo");

    // Nintendo logo (48 bytes) - must match exactly for real hardware
    const nintendo_logo = [_]u8{
        0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83,
        0x00, 0x0C, 0x00, 0x0D, 0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E,
        0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99, 0xBB, 0xBB, 0x67, 0x63,
        0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
    };

    var logo: [48]u8 = undefined;
    const logo_read = file.read(&logo) catch return ValidationResult.invalidCode(.gb, .failed_to_read, "Nintendo logo");

    if (logo_read < 48) {
        return ValidationResult.invalidCode(.gb, .file_too_small, "GB ROM");
    }

    // Check Nintendo logo (real GB hardware requires exact match)
    if (!std.mem.eql(u8, &logo, &nintendo_logo)) {
        return ValidationResult.invalidCode(.gb, .invalid_value, "Nintendo logo");
    }

    // Read header checksum at 0x14D
    file.seekTo(0x134) catch return ValidationResult.invalidCode(.gb, .failed_to_seek, "to header");

    var header: [25]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.gb, .failed_to_read, "GB header");

    // Header checksum at 0x14D (offset 25 from 0x134)
    file.seekTo(0x14D) catch return ValidationResult.invalidCode(.gb, .failed_to_seek, "to checksum");

    var checksum_byte: [1]u8 = undefined;
    _ = file.read(&checksum_byte) catch return ValidationResult.invalidCode(.gb, .failed_to_read, "checksum");

    // Calculate header checksum
    var checksum: u8 = 0;
    for (header) |b| {
        checksum = checksum -% b -% 1;
    }

    if (checksum != checksum_byte[0]) {
        return ValidationResult.invalidCodeMsg(.gb, .checksum_mismatch, "Header", "Header checksum mismatch");
    }

    // Header checksum verified
    return ValidationResult.okWithDepth(.gb, .structural);
}

/// Deep validate Game Boy ROM - reads entire file and verifies the global checksum at 0x14E-0x14F.
pub fn validateGbDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.gb, .failed_to_get, "file size");

    // GB ROM must be at least 0x150 bytes (header ends at 0x14F)
    if (file_size < 0x150) {
        return ValidationResult.invalidCode(.gb, .file_too_small, "GB ROM");
    }

    // Cap at 32 MB for safety (largest GB ROMs are 8 MB)
    if (file_size > 32 * 1024 * 1024) {
        return ValidationResult.invalidCode(.gb, .file_too_large, "GB ROM");
    }

    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |buf| allocator.free(buf);
    const rom: []const u8 = if (file.getMappedSlice()) |mapped|
        mapped
    else blk: {
        const buf = allocator.alloc(u8, @intCast(file_size)) catch {
            return ValidationResult.invalidCode(.gb, .out_of_memory, "GB ROM");
        };
        heap_buf = buf;
        file.seekTo(0) catch return ValidationResult.invalidCode(.gb, .failed_to_seek, "to start");
        const n = file.readAll(buf) catch return ValidationResult.invalidCode(.gb, .failed_to_read, "GB ROM");
        if (n < file_size) return ValidationResult.invalidCode(.gb, .file_too_small, "GB ROM truncated");
        break :blk buf[0..n];
    };

    // Stored global checksum at 0x14E-0x14F (big-endian u16)
    const stored_checksum = std.mem.readInt(u16, rom[0x14E..0x150], .big);

    // Compute global checksum: sum of all bytes excluding 0x14E and 0x14F
    var computed: u16 = 0;
    for (rom, 0..) |b, i| {
        if (i == 0x14E or i == 0x14F) continue;
        computed +%= b;
    }

    if (computed != stored_checksum) {
        return ValidationResult.invalidCodeMsg(.gb, .checksum_mismatch, "Global", "Global checksum mismatch");
    }

    return ValidationResult.okWithDepth(.gb, .full);
}

// ============ GBA ============

/// Validate GBA ROM - checks ARM branch entry point, Nintendo logo, and header checksum.
pub fn validateGba(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.gba, .failed_to_seek, "to start");

    var header: [192]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.gba, .failed_to_read, "GBA header");

    if (header_read < 192) {
        return ValidationResult.invalidCode(.gba, .file_too_small, "GBA ROM");
    }

    // First 4 bytes are ARM branch instruction (should be 0xEA000000 + offset)
    const branch = std.mem.readInt(u32, header[0..4], .little);
    if ((branch & 0xFF000000) != 0xEA000000) {
        return ValidationResult.invalidCode(.gba, .invalid_value, "GBA entry point");
    }

    // Check for Nintendo logo (simplified check - first bytes)
    // Full logo is at 0x04-0x9F
    if (header[0x04] != 0x24 or header[0x05] != 0xFF or header[0x06] != 0xAE) {
        return ValidationResult.invalidCode(.gba, .invalid_value, "GBA Nintendo logo");
    }

    // Header checksum at 0xBD
    var checksum: u8 = 0;
    for (header[0xA0..0xBD]) |b| {
        checksum = checksum +% b;
    }
    checksum = (0 -% (0x19 +% checksum));

    if (checksum != header[0xBD]) {
        return ValidationResult.invalidCodeMsg(.gba, .checksum_mismatch, "GBA header", "GBA header checksum mismatch");
    }

    // Header checksum verified
    return ValidationResult.okWithDepth(.gba, .structural);
}

// ============ NDS ============

/// Validate NDS ROM - checks ARM9/ARM7 offsets and header CRC-16 MODBUS.
pub fn validateNds(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.nds, .failed_to_seek, "to start");

    var header: [512]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.nds, .failed_to_read, "NDS header");

    if (header_read < 512) {
        return ValidationResult.invalidCode(.nds, .file_too_small, "NDS ROM");
    }

    // Check ARM9 ROM offset (should be reasonable)
    const arm9_offset = std.mem.readInt(u32, header[0x20..0x24], .little);
    const arm9_size = std.mem.readInt(u32, header[0x2C..0x30], .little);

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.nds, .failed_to_get, "file size");

    if (arm9_offset == 0 or arm9_offset > file_size) {
        return ValidationResult.invalidCode(.nds, .invalid_value, "ARM9 offset");
    }

    if (arm9_size == 0 or arm9_offset + arm9_size > file_size) {
        return ValidationResult.invalidCode(.nds, .invalid_value, "ARM9 size");
    }

    // Check ARM7 ROM offset
    const arm7_offset = std.mem.readInt(u32, header[0x30..0x34], .little);
    const arm7_size = std.mem.readInt(u32, header[0x3C..0x40], .little);

    if (arm7_offset == 0 or arm7_offset > file_size) {
        return ValidationResult.invalidCode(.nds, .invalid_value, "ARM7 offset");
    }

    if (arm7_size == 0 or arm7_offset + arm7_size > file_size) {
        return ValidationResult.invalidCode(.nds, .invalid_value, "ARM7 size");
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
        return ValidationResult.invalidCodeMsg(.nds, .checksum_mismatch, "Header CRC", "Header CRC mismatch");
    }

    // Header CRC verified
    return ValidationResult.okWithDepth(.nds, .structural);
}

// ============ Sega Genesis / Mega Drive ============

/// Validate Genesis/Mega Drive ROM - checks "SEGA" signature and SMD format detection.
pub fn validateGenesis(file: *FileSource) ValidationResult {
    file.seekTo(0x100) catch return ValidationResult.invalidCode(.genesis, .failed_to_seek, "to header");

    var header: [256]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.genesis, .failed_to_read, "Genesis header");

    if (header_read < 256) {
        return ValidationResult.invalidCode(.genesis, .file_too_small, "Genesis ROM");
    }

    // Check for "SEGA" at offset 0x100 (console name field)
    if (!std.mem.eql(u8, header[0..4], "SEGA") and
        !std.mem.eql(u8, header[0..4], " SEG"))
    {
        // Also check at offset 0 for SMD format
        file.seekTo(0) catch return ValidationResult.invalidCode(.genesis, .failed_to_seek, "to start");

        var alt_header: [16]u8 = undefined;
        _ = file.read(&alt_header) catch return ValidationResult.invalidCode(.genesis, .failed_to_read, "SMD header");

        // SMD format has specific pattern
        const is_smd = (alt_header[8] == 0xAA and alt_header[9] == 0xBB);
        if (!is_smd) {
            return ValidationResult.invalidCode(.genesis, .invalid_signature, "Genesis ROM");
        }
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.genesis, .failed_to_get, "file size");

    // Genesis ROMs are typically 256KB to 4MB
    if (file_size < 128 * 1024) {
        return ValidationResult.invalidCode(.genesis, .file_too_small, "Genesis ROM");
    }
    if (file_size > 8 * 1024 * 1024) {
        return ValidationResult.invalidCode(.genesis, .file_too_large, "Genesis ROM");
    }

    return ValidationResult.okWithDepth(.genesis, .structural);
}

/// Deep validate Genesis ROM - checks game title, ROM address range, and ROM checksum.
/// The Genesis ROM checksum at offset 0x18E is a 16-bit big-endian sum of all
/// 16-bit big-endian words from offset 0x200 to end of ROM.
pub fn validateGenesisDeep(allocator: Allocator, source: *FileSource) ValidationResult {
    const file = source;

    file.seekTo(0x100) catch return ValidationResult.invalid(.genesis, "Failed to seek");

    var header: [256]u8 = undefined;
    _ = file.read(&header) catch return ValidationResult.invalidCode(.genesis, .failed_to_read, "header");

    const has_sega = std.mem.eql(u8, header[0..4], "SEGA") or std.mem.eql(u8, header[0..4], " SEG");

    if (!has_sega) {
        // Check SMD format
        file.seekTo(0) catch return ValidationResult.invalid(.genesis, "Failed to seek");
        var alt_header: [16]u8 = undefined;
        _ = file.read(&alt_header) catch return ValidationResult.invalidCode(.genesis, .failed_to_read, "SMD");
        if (alt_header[8] != 0xAA or alt_header[9] != 0xBB) {
            return ValidationResult.invalidCode(.genesis, .invalid_signature, "Genesis");
        }
        return ValidationResult.okWithDepth(.genesis, .structural);
    }

    // ROM addresses at 0x1A0-0x1A7 (start/end)
    const rom_start_addr = std.mem.readInt(u32, header[0xA0..0xA4], .big);
    const rom_end_addr = std.mem.readInt(u32, header[0xA4..0xA8], .big);

    if (rom_start_addr > rom_end_addr) {
        return ValidationResult.invalidCode(.genesis, .invalid_value, "ROM address range");
    }

    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.genesis, .failed_to_get, "size");
    if (rom_end_addr > file_size) {
        return ValidationResult.okWithDepthAndWarning(.genesis, .structural, "ROM end exceeds file size");
    }

    // Genesis ROM checksum at 0x18E: big-endian u16 sum of all big-endian u16 words
    // from offset 0x200 to end of ROM
    const stored_checksum = std.mem.readInt(u16, header[0x8E..0x90], .big);

    if (file_size < 0x202) {
        // Too small for checksum computation
        return ValidationResult.okWithDepth(.genesis, .structural);
    }

    // Read entire ROM from 0x200 onward
    const rom_data_size: usize = @intCast(file_size - 0x200);
    const rom_data = allocator.alloc(u8, rom_data_size) catch {
        // Can't allocate — fall back to structural
        return ValidationResult.okWithDepth(.genesis, .structural);
    };
    defer allocator.free(rom_data);

    file.seekTo(0x200) catch return ValidationResult.invalidCode(.genesis, .failed_to_seek, "to ROM data");
    const bytes_read = file.readAll(rom_data) catch return ValidationResult.invalidCode(.genesis, .failed_to_read, "ROM data");
    if (bytes_read != rom_data_size) {
        return ValidationResult.invalidCode(.genesis, .incomplete, "Genesis ROM");
    }

    // Compute checksum: sum of all big-endian u16 words
    var computed: u16 = 0;
    var i: usize = 0;
    while (i + 1 < rom_data.len) : (i += 2) {
        computed +%= std.mem.readInt(u16, rom_data[i..][0..2], .big);
    }
    // If odd byte at end, treat as high byte of a u16 (pad with 0)
    if (rom_data.len & 1 != 0) {
        computed +%= @as(u16, rom_data[rom_data.len - 1]) << 8;
    }

    if (computed != stored_checksum) {
        return ValidationResult.invalidCodeMsg(.genesis, .checksum_mismatch, "Genesis ROM", "Genesis ROM checksum mismatch");
    }

    return ValidationResult.okWithDepth(.genesis, .full);
}

// ============ CHD (MAME Compressed Hunks of Data) ============

/// Validate CHD disk image - checks "MComprHD" signature, header length, and version.
pub fn validateChd(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.chd, .failed_to_seek, "to start");

    var header: [124]u8 = undefined;
    const header_read = file.read(&header) catch return ValidationResult.invalidCode(.chd, .failed_to_read, "CHD header");

    if (header_read < 124) {
        return ValidationResult.invalidCode(.chd, .file_too_small, "CHD");
    }

    // Check signature
    if (!std.mem.eql(u8, header[0..8], "MComprHD")) {
        return ValidationResult.invalidCode(.chd, .invalid_signature, "CHD");
    }

    // Header length (big-endian)
    const header_len = std.mem.readInt(u32, header[8..12], .big);
    if (header_len < 76 or header_len > 124) {
        return ValidationResult.invalidCode(.chd, .invalid_value, "CHD header length");
    }

    // Version (big-endian) - versions 1-5 are known
    const version = std.mem.readInt(u32, header[12..16], .big);
    if (version < 1 or version > 5) {
        return ValidationResult.invalidCode(.chd, .unknown_element, "CHD version");
    }

    return ValidationResult.okWithDepth(.chd, .structural);
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

/// Skip test if a ground truth file doesn't exist (e.g., samples in external repo).
fn skipIfMissing(comptime path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch return error.SkipZigTest;
}

test "detectFormat IFF generic" {
    // Generic IFF with unknown form type
    var iff_header: [12]u8 = undefined;
    @memcpy(iff_header[0..4], "FORM");
    std.mem.writeInt(u32, iff_header[4..8], 100, .big); // Size
    @memcpy(iff_header[8..12], "TEST"); // Unknown form type
    try std.testing.expectEqual(FileFormat.iff, detectFormat(&iff_header));
}

test "detectFormat Blorb IFRS" {
    // Blorb with Z-machine resources
    var blorb_header: [12]u8 = undefined;
    @memcpy(blorb_header[0..4], "FORM");
    std.mem.writeInt(u32, blorb_header[4..8], 100, .big);
    @memcpy(blorb_header[8..12], "IFRS");
    try std.testing.expectEqual(FileFormat.blorb, detectFormat(&blorb_header));
}

test "detectFormat Blorb IFZS" {
    // Blorb with Glulx resources
    var blorb_header: [12]u8 = undefined;
    @memcpy(blorb_header[0..4], "FORM");
    std.mem.writeInt(u32, blorb_header[4..8], 100, .big);
    @memcpy(blorb_header[8..12], "IFZS");
    try std.testing.expectEqual(FileFormat.blorb, detectFormat(&blorb_header));
}

test "FormatValidator accepts valid IFF" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal IFF file: FORM + size + type + data
    var iff_data: [20]u8 = undefined;
    @memcpy(iff_data[0..4], "FORM");
    std.mem.writeInt(u32, iff_data[4..8], 12, .big); // Size of content
    @memcpy(iff_data[8..12], "TEST"); // Form type
    @memcpy(iff_data[12..16], "DATA"); // Chunk type
    std.mem.writeInt(u32, iff_data[16..20], 0, .big); // Chunk size

    const file = try tmp_dir.dir.createFile("test.iff", .{});
    try file.writeAll(&iff_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.iff");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.iff, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator accepts valid Blorb" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Blorb file with RIdx (Resource Index) chunk
    var blorb_data: [32]u8 = undefined;
    @memcpy(blorb_data[0..4], "FORM");
    std.mem.writeInt(u32, blorb_data[4..8], 24, .big); // Size
    @memcpy(blorb_data[8..12], "IFRS"); // Blorb form type
    @memcpy(blorb_data[12..16], "RIdx"); // Resource Index chunk (required)
    std.mem.writeInt(u32, blorb_data[16..20], 4, .big); // Chunk size
    std.mem.writeInt(u32, blorb_data[20..24], 0, .big); // Number of resources
    @memset(blorb_data[24..32], 0); // Padding

    const file = try tmp_dir.dir.createFile("test.blorb", .{});
    try file.writeAll(&blorb_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.blorb");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.blorb, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects Blorb without RIdx" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Blorb file without RIdx chunk (invalid)
    var blorb_data: [20]u8 = undefined;
    @memcpy(blorb_data[0..4], "FORM");
    std.mem.writeInt(u32, blorb_data[4..8], 12, .big);
    @memcpy(blorb_data[8..12], "IFRS");
    @memcpy(blorb_data[12..16], "AUTH"); // Auth chunk, not RIdx
    std.mem.writeInt(u32, blorb_data[16..20], 0, .big);

    const file = try tmp_dir.dir.createFile("invalid.blorb", .{});
    try file.writeAll(&blorb_data);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.blorb");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.blorb, result.format);
    try std.testing.expect(!result.is_valid);
}

test "validateGenesisDeep: valid ROM has full depth (checksum verified)" {
    try skipIfMissing("ground_truth_examples/genesis/Afterburner II (J).gen");
    var source = try FileSource.open("ground_truth_examples/genesis/Afterburner II (J).gen");
    defer source.close();
    const result = validateGenesisDeep(std.testing.allocator, &source);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateGenesisDeep: second sample also passes checksum" {
    try skipIfMissing("ground_truth_examples/genesis/Aero Blasters (JU).gen");
    var source = try FileSource.open("ground_truth_examples/genesis/Aero Blasters (JU).gen");
    defer source.close();
    const result = validateGenesisDeep(std.testing.allocator, &source);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateGenesisDeep: corrupted ROM detected by checksum" {
    const allocator = std.testing.allocator;

    // Read a valid ROM and corrupt data in the checksummed region (0x200+)
    try skipIfMissing("ground_truth_examples/genesis/Afterburner II (J).gen");
    const original = try std.fs.cwd().readFileAlloc(allocator, "ground_truth_examples/genesis/Afterburner II (J).gen", 8 * 1024 * 1024);
    defer allocator.free(original);

    var corrupted = try allocator.dupe(u8, original);
    defer allocator.free(corrupted);

    // Flip bytes at various offsets in the checksummed region
    corrupted[0x300] ^= 0xFF;
    corrupted[0x1000] ^= 0xFF;

    // Write to temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("corrupt.gen", .{});
    try file.writeAll(corrupted);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupt.gen");
    defer allocator.free(path);

    var source = try FileSource.open(path);
    defer source.close();
    const result = validateGenesisDeep(allocator, &source);
    try std.testing.expect(!result.is_valid);
}

test "validateN64Deep: valid ROM has full depth (CRC verified)" {
    try skipIfMissing("ground_truth_examples/n64/Super Mario 64.z64");
    var source = try FileSource.open("ground_truth_examples/n64/Super Mario 64.z64");
    defer source.close();
    const result = validateN64Deep(std.testing.allocator, &source);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateN64Deep: corrupted ROM detected by CRC" {
    const allocator = std.testing.allocator;

    try skipIfMissing("ground_truth_examples/n64/Mario 64 (J).z64");
    const original = try std.fs.cwd().readFileAlloc(allocator, "ground_truth_examples/n64/Super Mario 64.z64", 64 * 1024 * 1024);
    defer allocator.free(original);

    var corrupted = try allocator.dupe(u8, original);
    defer allocator.free(corrupted);

    // Corrupt data in the CRC-covered region (0x1000-0x101000)
    corrupted[0x2000] ^= 0xFF;
    corrupted[0x50000] ^= 0xFF;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("corrupt.z64", .{});
    try file.writeAll(corrupted);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupt.z64");
    defer allocator.free(path);

    var source = try FileSource.open(path);
    defer source.close();
    const result = validateN64Deep(allocator, &source);
    try std.testing.expect(!result.is_valid);
}

