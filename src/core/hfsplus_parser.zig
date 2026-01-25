//! HFS+ (Hierarchical File System Plus) Parser
//!
//! Parses HFS+ filesystems from disk images.
//! HFS+ was Apple's primary filesystem from Mac OS 8.1 until APFS.
//!
//! Reference: Apple Technical Note TN1150

const std = @import("std");
const Allocator = std.mem.Allocator;

/// HFS+ Volume Header signature: 'H+' (0x482B)
pub const HFSPLUS_SIGNATURE: u16 = 0x482B;

/// HFSX Volume Header signature: 'HX' (0x4858) - case-sensitive variant
pub const HFSX_SIGNATURE: u16 = 0x4858;

/// Volume Header is located at offset 1024 bytes
pub const VOLUME_HEADER_OFFSET: usize = 1024;

/// Standard block size (minimum)
pub const MIN_BLOCK_SIZE: u32 = 512;

/// HFS+ Fork Data - describes a file's data or resource fork
pub const HfsPlusForkData = struct {
    logical_size: u64,
    clump_size: u32,
    total_blocks: u32,
    extents: [8]HfsPlusExtentDescriptor,

    pub fn parse(data: []const u8) !HfsPlusForkData {
        if (data.len < 80) return error.BufferTooSmall;

        var fork = HfsPlusForkData{
            .logical_size = std.mem.readInt(u64, data[0..8], .big),
            .clump_size = std.mem.readInt(u32, data[8..12], .big),
            .total_blocks = std.mem.readInt(u32, data[12..16], .big),
            .extents = undefined,
        };

        // Parse 8 extent descriptors (8 bytes each)
        for (0..8) |i| {
            const offset = 16 + i * 8;
            fork.extents[i] = HfsPlusExtentDescriptor{
                .start_block = std.mem.readInt(u32, data[offset..][0..4], .big),
                .block_count = std.mem.readInt(u32, data[offset + 4 ..][0..4], .big),
            };
        }

        return fork;
    }
};

/// HFS+ Extent Descriptor - describes a contiguous range of blocks
pub const HfsPlusExtentDescriptor = struct {
    start_block: u32,
    block_count: u32,
};

/// HFS+ Volume Header (512 bytes at offset 1024)
pub const HfsPlusVolumeHeader = struct {
    signature: u16,
    version: u16,
    attributes: u32,
    last_mounted_version: u32,
    journal_info_block: u32,
    create_date: u32,
    modify_date: u32,
    backup_date: u32,
    checked_date: u32,
    file_count: u32,
    folder_count: u32,
    block_size: u32,
    total_blocks: u32,
    free_blocks: u32,
    next_allocation: u32,
    rsrc_clump_size: u32,
    data_clump_size: u32,
    next_catalog_id: u32,
    write_count: u32,
    encodings_bitmap: u64,
    finder_info: [32]u8,
    allocation_file: HfsPlusForkData,
    extents_file: HfsPlusForkData,
    catalog_file: HfsPlusForkData,
    attributes_file: HfsPlusForkData,
    startup_file: HfsPlusForkData,

    /// Parse Volume Header from raw bytes
    pub fn parse(data: []const u8) !HfsPlusVolumeHeader {
        if (data.len < 512) return error.BufferTooSmall;

        const signature = std.mem.readInt(u16, data[0..2], .big);
        if (signature != HFSPLUS_SIGNATURE and signature != HFSX_SIGNATURE) {
            return error.InvalidSignature;
        }

        return HfsPlusVolumeHeader{
            .signature = signature,
            .version = std.mem.readInt(u16, data[2..4], .big),
            .attributes = std.mem.readInt(u32, data[4..8], .big),
            .last_mounted_version = std.mem.readInt(u32, data[8..12], .big),
            .journal_info_block = std.mem.readInt(u32, data[12..16], .big),
            .create_date = std.mem.readInt(u32, data[16..20], .big),
            .modify_date = std.mem.readInt(u32, data[20..24], .big),
            .backup_date = std.mem.readInt(u32, data[24..28], .big),
            .checked_date = std.mem.readInt(u32, data[28..32], .big),
            .file_count = std.mem.readInt(u32, data[32..36], .big),
            .folder_count = std.mem.readInt(u32, data[36..40], .big),
            .block_size = std.mem.readInt(u32, data[40..44], .big),
            .total_blocks = std.mem.readInt(u32, data[44..48], .big),
            .free_blocks = std.mem.readInt(u32, data[48..52], .big),
            .next_allocation = std.mem.readInt(u32, data[52..56], .big),
            .rsrc_clump_size = std.mem.readInt(u32, data[56..60], .big),
            .data_clump_size = std.mem.readInt(u32, data[60..64], .big),
            .next_catalog_id = std.mem.readInt(u32, data[64..68], .big),
            .write_count = std.mem.readInt(u32, data[68..72], .big),
            .encodings_bitmap = std.mem.readInt(u64, data[72..80], .big),
            .finder_info = data[80..112].*,
            .allocation_file = try HfsPlusForkData.parse(data[112..192]),
            .extents_file = try HfsPlusForkData.parse(data[192..272]),
            .catalog_file = try HfsPlusForkData.parse(data[272..352]),
            .attributes_file = try HfsPlusForkData.parse(data[352..432]),
            .startup_file = try HfsPlusForkData.parse(data[432..512]),
        };
    }

    /// Check if this is a journaled volume
    pub fn isJournaled(self: *const HfsPlusVolumeHeader) bool {
        return (self.attributes & 0x2000) != 0; // kHFSVolumeJournaledBit
    }

    /// Check if this is case-sensitive (HFSX)
    pub fn isCaseSensitive(self: *const HfsPlusVolumeHeader) bool {
        return self.signature == HFSX_SIGNATURE;
    }

    /// Get volume size in bytes
    pub fn getVolumeSize(self: *const HfsPlusVolumeHeader) u64 {
        return @as(u64, self.total_blocks) * @as(u64, self.block_size);
    }

    /// Get free space in bytes
    pub fn getFreeSpace(self: *const HfsPlusVolumeHeader) u64 {
        return @as(u64, self.free_blocks) * @as(u64, self.block_size);
    }
};

/// Volume attributes bit flags
pub const VolumeAttributes = struct {
    pub const UNMOUNTED: u32 = 0x0100;
    pub const SPARED_BLOCKS: u32 = 0x0200;
    pub const NO_CACHE: u32 = 0x0400;
    pub const BOOT_INCONSISTENT: u32 = 0x0800;
    pub const CATALOG_NODE_IDS_REUSED: u32 = 0x1000;
    pub const JOURNALED: u32 = 0x2000;
    pub const SOFTWARE_LOCK: u32 = 0x4000;
    pub const HARDWARE_LOCK: u32 = 0x8000;
};

/// Parsed HFS+ volume information
pub const HfsPlusInfo = struct {
    header: HfsPlusVolumeHeader,
    partition_offset: usize,

    /// Get the byte offset for a given allocation block
    pub fn blockToOffset(self: *const HfsPlusInfo, block: u32) usize {
        return self.partition_offset + @as(usize, block) * @as(usize, self.header.block_size);
    }
};

/// Parse HFS+ volume from disk image data
pub fn parseHfsPlus(data: []const u8, partition_offset: usize) !HfsPlusInfo {
    if (data.len < partition_offset + VOLUME_HEADER_OFFSET + 512) {
        return error.DataTooSmall;
    }

    const header_data = data[partition_offset + VOLUME_HEADER_OFFSET ..][0..512];
    const header = try HfsPlusVolumeHeader.parse(header_data);

    // Validate block size is reasonable
    if (header.block_size < MIN_BLOCK_SIZE or header.block_size > 1024 * 1024) {
        return error.InvalidBlockSize;
    }

    return HfsPlusInfo{
        .header = header,
        .partition_offset = partition_offset,
    };
}

/// Check if data at offset contains HFS+ signature
pub fn hasHfsPlus(data: []const u8, partition_offset: usize) bool {
    if (data.len < partition_offset + VOLUME_HEADER_OFFSET + 2) return false;

    const sig_offset = partition_offset + VOLUME_HEADER_OFFSET;
    const signature = std.mem.readInt(u16, data[sig_offset..][0..2], .big);
    return signature == HFSPLUS_SIGNATURE or signature == HFSX_SIGNATURE;
}

// ============ Tests ============

test "HFSPLUS_SIGNATURE and HFSX_SIGNATURE are correct" {
    // 'H+' = 0x48 0x2B
    try std.testing.expectEqual(@as(u16, 0x482B), HFSPLUS_SIGNATURE);
    // 'HX' = 0x48 0x58
    try std.testing.expectEqual(@as(u16, 0x4858), HFSX_SIGNATURE);
}

test "HfsPlusVolumeHeader.parse rejects invalid signature" {
    var data = std.mem.zeroes([512]u8);
    data[0] = 'X';
    data[1] = 'X';
    const result = HfsPlusVolumeHeader.parse(&data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "HfsPlusVolumeHeader.parse parses valid HFS+ header" {
    var data = std.mem.zeroes([512]u8);

    // Signature: 'H+' (big-endian)
    data[0] = 0x48; // 'H'
    data[1] = 0x2B; // '+'

    // Version: 4
    std.mem.writeInt(u16, data[2..4], 4, .big);

    // Block size: 4096
    std.mem.writeInt(u32, data[40..44], 4096, .big);

    // Total blocks: 1000000
    std.mem.writeInt(u32, data[44..48], 1000000, .big);

    // Free blocks: 500000
    std.mem.writeInt(u32, data[48..52], 500000, .big);

    // File count: 1000
    std.mem.writeInt(u32, data[32..36], 1000, .big);

    // Folder count: 100
    std.mem.writeInt(u32, data[36..40], 100, .big);

    const header = try HfsPlusVolumeHeader.parse(&data);
    try std.testing.expectEqual(@as(u16, HFSPLUS_SIGNATURE), header.signature);
    try std.testing.expectEqual(@as(u16, 4), header.version);
    try std.testing.expectEqual(@as(u32, 4096), header.block_size);
    try std.testing.expectEqual(@as(u32, 1000000), header.total_blocks);
    try std.testing.expectEqual(@as(u32, 500000), header.free_blocks);
    try std.testing.expectEqual(@as(u32, 1000), header.file_count);
    try std.testing.expectEqual(@as(u32, 100), header.folder_count);
}

test "HfsPlusVolumeHeader.parse parses HFSX header" {
    var data = std.mem.zeroes([512]u8);

    // Signature: 'HX' (big-endian)
    data[0] = 0x48; // 'H'
    data[1] = 0x58; // 'X'

    // Block size: 4096
    std.mem.writeInt(u32, data[40..44], 4096, .big);

    const header = try HfsPlusVolumeHeader.parse(&data);
    try std.testing.expectEqual(@as(u16, HFSX_SIGNATURE), header.signature);
    try std.testing.expect(header.isCaseSensitive());
}

test "HfsPlusVolumeHeader.getVolumeSize calculates correctly" {
    var data = std.mem.zeroes([512]u8);

    data[0] = 0x48;
    data[1] = 0x2B;
    std.mem.writeInt(u32, data[40..44], 4096, .big); // block_size
    std.mem.writeInt(u32, data[44..48], 1000, .big); // total_blocks

    const header = try HfsPlusVolumeHeader.parse(&data);
    try std.testing.expectEqual(@as(u64, 4096 * 1000), header.getVolumeSize());
}

test "HfsPlusVolumeHeader.getFreeSpace calculates correctly" {
    var data = std.mem.zeroes([512]u8);

    data[0] = 0x48;
    data[1] = 0x2B;
    std.mem.writeInt(u32, data[40..44], 4096, .big); // block_size
    std.mem.writeInt(u32, data[48..52], 500, .big); // free_blocks

    const header = try HfsPlusVolumeHeader.parse(&data);
    try std.testing.expectEqual(@as(u64, 4096 * 500), header.getFreeSpace());
}

test "HfsPlusVolumeHeader.isJournaled detects journaled volumes" {
    var data = std.mem.zeroes([512]u8);

    data[0] = 0x48;
    data[1] = 0x2B;
    std.mem.writeInt(u32, data[40..44], 4096, .big);

    // Set journaled attribute
    std.mem.writeInt(u32, data[4..8], VolumeAttributes.JOURNALED, .big);

    const header = try HfsPlusVolumeHeader.parse(&data);
    try std.testing.expect(header.isJournaled());
}

test "hasHfsPlus returns false for non-HFS+ data" {
    const data = std.mem.zeroes([2048]u8);
    try std.testing.expect(!hasHfsPlus(&data, 0));
}

test "hasHfsPlus returns true for HFS+ data" {
    var data = std.mem.zeroes([2048]u8);

    // Put HFS+ signature at offset 1024
    data[1024] = 0x48; // 'H'
    data[1025] = 0x2B; // '+'

    try std.testing.expect(hasHfsPlus(&data, 0));
}

test "parseHfsPlus with partition offset" {
    var data = std.mem.zeroes([4096]u8);

    const partition_start: usize = 1024;

    // Put HFS+ header at partition_start + 1024
    const header_offset = partition_start + VOLUME_HEADER_OFFSET;
    data[header_offset] = 0x48; // 'H'
    data[header_offset + 1] = 0x2B; // '+'
    std.mem.writeInt(u32, data[header_offset + 40 ..][0..4], 4096, .big); // block_size
    std.mem.writeInt(u32, data[header_offset + 44 ..][0..4], 1000, .big); // total_blocks

    const info = try parseHfsPlus(&data, partition_start);
    try std.testing.expectEqual(@as(u16, HFSPLUS_SIGNATURE), info.header.signature);
    try std.testing.expectEqual(partition_start, info.partition_offset);
}

test "HfsPlusInfo.blockToOffset calculates correctly" {
    var data = std.mem.zeroes([4096]u8);

    data[VOLUME_HEADER_OFFSET] = 0x48;
    data[VOLUME_HEADER_OFFSET + 1] = 0x2B;
    std.mem.writeInt(u32, data[VOLUME_HEADER_OFFSET + 40 ..][0..4], 4096, .big);

    const info = try parseHfsPlus(&data, 0);
    // Block 10 at block_size 4096 = offset 40960
    try std.testing.expectEqual(@as(usize, 40960), info.blockToOffset(10));
}
