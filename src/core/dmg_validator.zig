//! DMG Validator (Pure Zig)
//!
//! Validates Apple Disk Image (DMG) files by parsing the koly trailer
//! and verifying internal checksums.
//!
//! DMG Structure:
//! - Data fork: Compressed/raw disk data
//! - XML plist: Block map with mish structures
//! - koly block: 512-byte trailer at EOF with checksums
//!
//! Reference: https://newosxbook.com/DMG.html

const std = @import("std");
const errmsg = @import("error_messages.zig");

// ============================================================================
// Constants
// ============================================================================

/// koly block signature
pub const KOLY_SIGNATURE: u32 = 0x6B6F6C79; // "koly" in big-endian

/// mish block signature
pub const MISH_SIGNATURE: u32 = 0x6D697368; // "mish" in big-endian

/// koly block size
pub const KOLY_SIZE: usize = 512;

/// Checksum types
pub const ChecksumType = enum(u32) {
    none = 0,
    crc32 = 1,
    // md5 = 2, // Uncommon
    _,
};

/// Compression types for block chunks
pub const CompressionType = enum(u32) {
    zero_fill = 0x00000000,
    raw = 0x00000001,
    ignored = 0x00000002,
    adc = 0x80000004, // Apple Data Compression
    zlib = 0x80000005,
    bzip2 = 0x80000006,
    lzfse = 0x80000007,
    lzma = 0x80000008,
    comment = 0x7FFFFFFE,
    terminator = 0xFFFFFFFF,
    _,
};

// ============================================================================
// Types
// ============================================================================

/// koly block (512 bytes, big-endian)
pub const KolyBlock = struct {
    signature: u32, // "koly" = 0x6B6F6C79
    version: u32, // Currently 4
    header_size: u32, // Always 512
    flags: u32,
    running_data_fork_offset: u64,
    data_fork_offset: u64, // Usually 0
    data_fork_length: u64,
    rsrc_fork_offset: u64,
    rsrc_fork_length: u64,
    segment_number: u32,
    segment_count: u32,
    segment_id: [16]u8, // UUID
    data_checksum_type: ChecksumType,
    data_checksum_size: u32,
    data_checksum: [32]u32, // Up to 128 bytes
    xml_offset: u64,
    xml_length: u64,
    // reserved1: [120]u8
    master_checksum_type: ChecksumType,
    master_checksum_size: u32,
    master_checksum: [32]u32, // Up to 128 bytes
    image_variant: u32,
    sector_count: u64,

    pub fn getDataCrc32(self: KolyBlock) ?u32 {
        if (self.data_checksum_type == .crc32 and self.data_checksum_size >= 4) {
            return self.data_checksum[0];
        }
        return null;
    }

    pub fn getMasterCrc32(self: KolyBlock) ?u32 {
        if (self.master_checksum_type == .crc32 and self.master_checksum_size >= 4) {
            return self.master_checksum[0];
        }
        return null;
    }

    pub fn getUncompressedSize(self: KolyBlock) u64 {
        return self.sector_count * 512;
    }
};

/// DMG validation result
pub const DmgValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    has_data_checksum: bool,
    has_master_checksum: bool,
    data_checksum_verified: bool,
    master_checksum_verified: bool,
    data_fork_size: u64,
    uncompressed_size: u64,
    xml_plist_size: u64,
    segment_count: u32,

    pub fn ok(
        data_ck: bool,
        master_ck: bool,
        data_verified: bool,
        master_verified: bool,
        data_size: u64,
        uncomp_size: u64,
        xml_size: u64,
        segments: u32,
    ) DmgValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .has_data_checksum = data_ck,
            .has_master_checksum = master_ck,
            .data_checksum_verified = data_verified,
            .master_checksum_verified = master_verified,
            .data_fork_size = data_size,
            .uncompressed_size = uncomp_size,
            .xml_plist_size = xml_size,
            .segment_count = segments,
        };
    }

    pub fn invalid(msg: []const u8) DmgValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .has_data_checksum = false,
            .has_master_checksum = false,
            .data_checksum_verified = false,
            .master_checksum_verified = false,
            .data_fork_size = 0,
            .uncompressed_size = 0,
            .xml_plist_size = 0,
            .segment_count = 0,
        };
    }
};

// ============================================================================
// Parsing
// ============================================================================

/// Parse koly block from 512-byte buffer (big-endian)
pub fn parseKolyBlock(data: []const u8) ?KolyBlock {
    if (data.len < KOLY_SIZE) return null;

    // Check signature
    const sig = std.mem.readInt(u32, data[0..4], .big);
    if (sig != KOLY_SIGNATURE) return null;

    var koly = KolyBlock{
        .signature = sig,
        .version = std.mem.readInt(u32, data[4..8], .big),
        .header_size = std.mem.readInt(u32, data[8..12], .big),
        .flags = std.mem.readInt(u32, data[12..16], .big),
        .running_data_fork_offset = std.mem.readInt(u64, data[16..24], .big),
        .data_fork_offset = std.mem.readInt(u64, data[24..32], .big),
        .data_fork_length = std.mem.readInt(u64, data[32..40], .big),
        .rsrc_fork_offset = std.mem.readInt(u64, data[40..48], .big),
        .rsrc_fork_length = std.mem.readInt(u64, data[48..56], .big),
        .segment_number = std.mem.readInt(u32, data[56..60], .big),
        .segment_count = std.mem.readInt(u32, data[60..64], .big),
        .segment_id = data[64..80].*,
        .data_checksum_type = @enumFromInt(std.mem.readInt(u32, data[80..84], .big)),
        .data_checksum_size = std.mem.readInt(u32, data[84..88], .big),
        .data_checksum = undefined,
        .xml_offset = std.mem.readInt(u64, data[216..224], .big),
        .xml_length = std.mem.readInt(u64, data[224..232], .big),
        // reserved1 at 232-352
        .master_checksum_type = @enumFromInt(std.mem.readInt(u32, data[352..356], .big)),
        .master_checksum_size = std.mem.readInt(u32, data[356..360], .big),
        .master_checksum = undefined,
        .image_variant = std.mem.readInt(u32, data[488..492], .big),
        .sector_count = std.mem.readInt(u64, data[492..500], .big),
    };

    // Parse data checksum (32 x u32 = 128 bytes at offset 88)
    for (0..32) |i| {
        const offset = 88 + i * 4;
        koly.data_checksum[i] = std.mem.readInt(u32, data[offset..][0..4], .big);
    }

    // Parse master checksum (32 x u32 = 128 bytes at offset 360)
    for (0..32) |i| {
        const offset = 360 + i * 4;
        koly.master_checksum[i] = std.mem.readInt(u32, data[offset..][0..4], .big);
    }

    return koly;
}

/// CRC32 (IEEE 802.3 polynomial, same as zlib) - uses std.hash.Crc32
fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

// ============================================================================
// Validation
// ============================================================================

/// Validate DMG file with checksum verification
pub fn validateDmgFile(file: std.fs.File, allocator: std.mem.Allocator) DmgValidationResult {
    // Get file size
    const file_size = file.getEndPos() catch {
        return DmgValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < KOLY_SIZE) {
        return DmgValidationResult.invalid(errmsg.fileTooSmallFor("DMG"));
    }

    // Read koly block from end of file
    file.seekTo(file_size - KOLY_SIZE) catch {
        return DmgValidationResult.invalid(errmsg.failedToSeek("to koly block"));
    };

    var koly_data: [KOLY_SIZE]u8 = undefined;
    const bytes_read = file.readAll(&koly_data) catch {
        return DmgValidationResult.invalid(errmsg.failedToRead("koly block"));
    };

    if (bytes_read < KOLY_SIZE) {
        return DmgValidationResult.invalid(errmsg.incomplete("koly block read"));
    }

    // Parse koly block
    const koly = parseKolyBlock(&koly_data) orelse {
        return DmgValidationResult.invalid(errmsg.invalidSignature("koly"));
    };

    // Validate version
    if (koly.version < 1 or koly.version > 10) {
        return DmgValidationResult.invalid(errmsg.unsupported("DMG version"));
    }

    // Check for checksums
    const has_data_ck = koly.data_checksum_type == .crc32 and koly.data_checksum_size >= 4;
    const has_master_ck = koly.master_checksum_type == .crc32 and koly.master_checksum_size >= 4;

    var data_verified = false;
    const master_verified = false; // TODO: implement master checksum verification

    // Verify data fork checksum if present
    if (has_data_ck and koly.data_fork_length > 0) {
        const stored_crc = koly.getDataCrc32().?;

        // Read data fork and compute CRC32
        const data_size: usize = @intCast(@min(koly.data_fork_length, 1024 * 1024 * 1024)); // Cap at 1GB for memory

        if (data_size <= 100 * 1024 * 1024) { // Only verify if <= 100MB (fast path)
            file.seekTo(koly.data_fork_offset) catch {
                return DmgValidationResult.invalid(errmsg.failedToSeek("to data fork"));
            };

            const data_buf = allocator.alloc(u8, data_size) catch {
                // Skip verification if allocation fails
                return DmgValidationResult.ok(
                    has_data_ck,
                    has_master_ck,
                    false,
                    false,
                    koly.data_fork_length,
                    koly.getUncompressedSize(),
                    koly.xml_length,
                    koly.segment_count,
                );
            };
            defer allocator.free(data_buf);

            const read_size = file.readAll(data_buf) catch {
                return DmgValidationResult.invalid(errmsg.failedToRead("data fork"));
            };

            if (read_size == data_size) {
                const computed_crc = crc32(data_buf);
                data_verified = (computed_crc == stored_crc);
            }
        }
    }

    // Master checksum typically covers more than just data fork
    // For now, we just report if it's present
    // Full verification would require understanding exactly what it covers

    return DmgValidationResult.ok(
        has_data_ck,
        has_master_ck,
        data_verified,
        master_verified,
        koly.data_fork_length,
        koly.getUncompressedSize(),
        koly.xml_length,
        koly.segment_count,
    );
}

/// Validate DMG from buffer (for testing)
pub fn validateDmgBuffer(data: []const u8) DmgValidationResult {
    if (data.len < KOLY_SIZE) {
        return DmgValidationResult.invalid(errmsg.bufferTooSmallFor("DMG"));
    }

    // koly block is at end
    const koly_start = data.len - KOLY_SIZE;
    const koly = parseKolyBlock(data[koly_start..]) orelse {
        return DmgValidationResult.invalid(errmsg.invalidSignature("koly"));
    };

    if (koly.version < 1 or koly.version > 10) {
        return DmgValidationResult.invalid(errmsg.unsupported("DMG version"));
    }

    const has_data_ck = koly.data_checksum_type == .crc32 and koly.data_checksum_size >= 4;
    const has_master_ck = koly.master_checksum_type == .crc32 and koly.master_checksum_size >= 4;

    var data_verified = false;

    // Verify data fork checksum
    if (has_data_ck and koly.data_fork_length > 0) {
        const stored_crc = koly.getDataCrc32().?;
        const data_end: usize = @intCast(koly.data_fork_offset + koly.data_fork_length);

        if (data_end <= data.len) {
            const data_fork = data[@intCast(koly.data_fork_offset)..data_end];
            const computed_crc = crc32(data_fork);
            data_verified = (computed_crc == stored_crc);
        }
    }

    return DmgValidationResult.ok(
        has_data_ck,
        has_master_ck,
        data_verified,
        false,
        koly.data_fork_length,
        koly.getUncompressedSize(),
        koly.xml_length,
        koly.segment_count,
    );
}

// ============================================================================
// Tests
// ============================================================================

test "crc32 - known values" {
    // Empty string
    try std.testing.expectEqual(@as(u32, 0x00000000), crc32(""));

    // "123456789" - standard test vector
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));

    // Single byte
    try std.testing.expectEqual(@as(u32, 0xE8B7BE43), crc32("a"));
}

test "parseKolyBlock - valid header" {
    var koly_data: [KOLY_SIZE]u8 = [_]u8{0} ** KOLY_SIZE;

    // Signature "koly" big-endian
    koly_data[0] = 0x6B;
    koly_data[1] = 0x6F;
    koly_data[2] = 0x6C;
    koly_data[3] = 0x79;

    // Version 4
    std.mem.writeInt(u32, koly_data[4..8], 4, .big);

    // Header size 512
    std.mem.writeInt(u32, koly_data[8..12], 512, .big);

    // Data fork length
    std.mem.writeInt(u64, koly_data[32..40], 1024 * 1024, .big);

    // Sector count
    std.mem.writeInt(u64, koly_data[492..500], 2048, .big);

    // Data checksum type = CRC32
    std.mem.writeInt(u32, koly_data[80..84], 1, .big);
    std.mem.writeInt(u32, koly_data[84..88], 4, .big);

    const koly = parseKolyBlock(&koly_data);
    try std.testing.expect(koly != null);

    try std.testing.expectEqual(@as(u32, KOLY_SIGNATURE), koly.?.signature);
    try std.testing.expectEqual(@as(u32, 4), koly.?.version);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), koly.?.data_fork_length);
    try std.testing.expectEqual(ChecksumType.crc32, koly.?.data_checksum_type);
    try std.testing.expectEqual(@as(u64, 2048 * 512), koly.?.getUncompressedSize());
}

test "parseKolyBlock - rejects invalid signature" {
    var koly_data: [KOLY_SIZE]u8 = [_]u8{0} ** KOLY_SIZE;

    // Wrong signature
    koly_data[0] = 'b';
    koly_data[1] = 'a';
    koly_data[2] = 'd';
    koly_data[3] = '!';

    const koly = parseKolyBlock(&koly_data);
    try std.testing.expect(koly == null);
}

test "validateDmgBuffer - synthetic DMG" {
    // Create minimal synthetic DMG with koly block
    const data_fork = "Hello, DMG data fork!";
    const data_crc = crc32(data_fork);

    // Total: data fork + padding + koly block
    var dmg_data: [1024]u8 = [_]u8{0} ** 1024;

    // Copy data fork
    @memcpy(dmg_data[0..data_fork.len], data_fork);

    // Build koly block at end (offset 512)
    const koly_offset = 1024 - KOLY_SIZE;

    // Signature
    dmg_data[koly_offset + 0] = 0x6B;
    dmg_data[koly_offset + 1] = 0x6F;
    dmg_data[koly_offset + 2] = 0x6C;
    dmg_data[koly_offset + 3] = 0x79;

    // Version 4
    std.mem.writeInt(u32, dmg_data[koly_offset + 4 ..][0..4], 4, .big);

    // Header size
    std.mem.writeInt(u32, dmg_data[koly_offset + 8 ..][0..4], 512, .big);

    // Data fork offset = 0
    std.mem.writeInt(u64, dmg_data[koly_offset + 24 ..][0..8], 0, .big);

    // Data fork length
    std.mem.writeInt(u64, dmg_data[koly_offset + 32 ..][0..8], data_fork.len, .big);

    // Data checksum type = CRC32
    std.mem.writeInt(u32, dmg_data[koly_offset + 80 ..][0..4], 1, .big);
    std.mem.writeInt(u32, dmg_data[koly_offset + 84 ..][0..4], 4, .big);

    // Data checksum value
    std.mem.writeInt(u32, dmg_data[koly_offset + 88 ..][0..4], data_crc, .big);

    // Sector count
    std.mem.writeInt(u64, dmg_data[koly_offset + 492 ..][0..8], 1, .big);

    const result = validateDmgBuffer(&dmg_data);

    try std.testing.expect(result.valid);
    try std.testing.expect(result.has_data_checksum);
    try std.testing.expect(result.data_checksum_verified);
    try std.testing.expectEqual(@as(u64, data_fork.len), result.data_fork_size);
}

test "validateDmgBuffer - detects corruption" {
    // Same as above but corrupt the data
    const data_fork = "Hello, DMG data fork!";
    const data_crc = crc32(data_fork);

    var dmg_data: [1024]u8 = [_]u8{0} ** 1024;

    // Copy data fork but corrupt it
    @memcpy(dmg_data[0..data_fork.len], data_fork);
    dmg_data[0] = 'X'; // Corrupt first byte

    const koly_offset = 1024 - KOLY_SIZE;

    dmg_data[koly_offset + 0] = 0x6B;
    dmg_data[koly_offset + 1] = 0x6F;
    dmg_data[koly_offset + 2] = 0x6C;
    dmg_data[koly_offset + 3] = 0x79;

    std.mem.writeInt(u32, dmg_data[koly_offset + 4 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dmg_data[koly_offset + 8 ..][0..4], 512, .big);
    std.mem.writeInt(u64, dmg_data[koly_offset + 24 ..][0..8], 0, .big);
    std.mem.writeInt(u64, dmg_data[koly_offset + 32 ..][0..8], data_fork.len, .big);
    std.mem.writeInt(u32, dmg_data[koly_offset + 80 ..][0..4], 1, .big);
    std.mem.writeInt(u32, dmg_data[koly_offset + 84 ..][0..4], 4, .big);
    std.mem.writeInt(u32, dmg_data[koly_offset + 88 ..][0..4], data_crc, .big); // Original CRC
    std.mem.writeInt(u64, dmg_data[koly_offset + 492 ..][0..8], 1, .big);

    const result = validateDmgBuffer(&dmg_data);

    try std.testing.expect(result.valid); // Structure is valid
    try std.testing.expect(result.has_data_checksum);
    try std.testing.expect(!result.data_checksum_verified); // But checksum fails!
}

test "ground truth - DMG sample" {
    // Test with real DMG file if available
    const file = std.fs.cwd().openFile("ground_truth_examples/dmg/sample.dmg", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const allocator = std.testing.allocator;
    const result = validateDmgFile(file, allocator);

    try std.testing.expect(result.valid);
    try std.testing.expect(result.data_fork_size > 0);
}
