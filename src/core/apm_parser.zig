//! Apple Partition Map (APM) Parser
//!
//! Parses Apple Partition Map partition tables from disk images.
//! APM was the partitioning scheme used by classic Mac OS (before GPT).
//!
//! Reference: Inside Macintosh: Devices, Chapter 3

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Driver Descriptor Map signature: 'ER' (0x4552)
pub const DDM_SIGNATURE: u16 = 0x4552;

/// Partition Map entry signature: 'PM' (0x504D)
pub const PM_SIGNATURE: u16 = 0x504D;

/// Standard block size for APM
pub const BLOCK_SIZE: usize = 512;

/// Driver Descriptor Map (at block 0)
pub const DriverDescriptorMap = struct {
    signature: u16,
    block_size: u16,
    block_count: u32,
    device_type: u16,
    device_id: u16,
    driver_data: u32,
    driver_count: u16,

    /// Parse DDM from raw bytes
    pub fn parse(data: []const u8) !DriverDescriptorMap {
        if (data.len < 18) {
            return error.BufferTooSmall;
        }

        const signature = std.mem.readInt(u16, data[0..2], .big);
        if (signature != DDM_SIGNATURE) {
            return error.InvalidSignature;
        }

        return DriverDescriptorMap{
            .signature = signature,
            .block_size = std.mem.readInt(u16, data[2..4], .big),
            .block_count = std.mem.readInt(u32, data[4..8], .big),
            .device_type = std.mem.readInt(u16, data[8..10], .big),
            .device_id = std.mem.readInt(u16, data[10..12], .big),
            .driver_data = std.mem.readInt(u32, data[12..16], .big),
            .driver_count = std.mem.readInt(u16, data[16..18], .big),
        };
    }
};

/// Partition Map Entry
pub const PartitionMapEntry = struct {
    signature: u16,
    reserved1: u16,
    map_entries: u32,
    physical_block_start: u32,
    physical_block_count: u32,
    name: [32]u8,
    type_name: [32]u8,
    logical_block_start: u32,
    logical_block_count: u32,
    flags: u32,
    logical_boot_block: u32,
    boot_size: u32,
    boot_load_addr: u32,
    boot_load_addr2: u32,
    boot_entry_addr: u32,
    boot_entry_addr2: u32,
    boot_checksum: u32,
    processor: [16]u8,

    /// Parse partition entry from raw bytes
    pub fn parse(data: []const u8) !PartitionMapEntry {
        if (data.len < 136) {
            return error.BufferTooSmall;
        }

        const signature = std.mem.readInt(u16, data[0..2], .big);
        if (signature != PM_SIGNATURE) {
            return error.InvalidSignature;
        }

        var entry = PartitionMapEntry{
            .signature = signature,
            .reserved1 = std.mem.readInt(u16, data[2..4], .big),
            .map_entries = std.mem.readInt(u32, data[4..8], .big),
            .physical_block_start = std.mem.readInt(u32, data[8..12], .big),
            .physical_block_count = std.mem.readInt(u32, data[12..16], .big),
            .name = undefined,
            .type_name = undefined,
            .logical_block_start = std.mem.readInt(u32, data[80..84], .big),
            .logical_block_count = std.mem.readInt(u32, data[84..88], .big),
            .flags = std.mem.readInt(u32, data[88..92], .big),
            .logical_boot_block = std.mem.readInt(u32, data[92..96], .big),
            .boot_size = std.mem.readInt(u32, data[96..100], .big),
            .boot_load_addr = std.mem.readInt(u32, data[100..104], .big),
            .boot_load_addr2 = std.mem.readInt(u32, data[104..108], .big),
            .boot_entry_addr = std.mem.readInt(u32, data[108..112], .big),
            .boot_entry_addr2 = std.mem.readInt(u32, data[112..116], .big),
            .boot_checksum = std.mem.readInt(u32, data[116..120], .big),
            .processor = undefined,
        };

        entry.name = data[16..48].*;
        entry.type_name = data[48..80].*;
        entry.processor = data[120..136].*;

        return entry;
    }

    /// Get partition name as null-terminated string
    pub fn getName(self: *const PartitionMapEntry) []const u8 {
        var len: usize = 0;
        for (self.name) |c| {
            if (c == 0) break;
            len += 1;
        }
        return self.name[0..len];
    }

    /// Get partition type as null-terminated string
    pub fn getTypeName(self: *const PartitionMapEntry) []const u8 {
        var len: usize = 0;
        for (self.type_name) |c| {
            if (c == 0) break;
            len += 1;
        }
        return self.type_name[0..len];
    }

    /// Get the size of this partition in bytes
    pub fn getSizeBytes(self: PartitionMapEntry) u64 {
        return @as(u64, self.physical_block_count) * BLOCK_SIZE;
    }

    /// Check if this is an HFS or HFS+ partition
    pub fn isHfsPartition(self: *const PartitionMapEntry) bool {
        const type_name = self.getTypeName();
        return std.mem.eql(u8, type_name, "Apple_HFS") or
            std.mem.eql(u8, type_name, "Apple_HFSX");
    }
};

/// Well-known partition type names
pub const PartitionType = struct {
    pub const PARTITION_MAP = "Apple_partition_map";
    pub const DRIVER = "Apple_Driver";
    pub const DRIVER43 = "Apple_Driver43";
    pub const DRIVER_ATA = "Apple_Driver_ATA";
    pub const DRIVER_ATAPI = "Apple_Driver_ATAPI";
    pub const PATCHES = "Apple_Patches";
    pub const HFS = "Apple_HFS";
    pub const HFSX = "Apple_HFSX";
    pub const UNIX_SVR2 = "Apple_Unix_SVR2";
    pub const FREE = "Apple_Free";
    pub const SCRATCH = "Apple_Scratch";
    pub const VOID = "Apple_Void";
};

/// Parsed APM information
pub const ApmInfo = struct {
    ddm: DriverDescriptorMap,
    partitions: []PartitionMapEntry,
    allocator: Allocator,

    pub fn deinit(self: *ApmInfo) void {
        self.allocator.free(self.partitions);
    }

    /// Find first HFS/HFS+ partition
    pub fn findHfsPartition(self: ApmInfo) ?*const PartitionMapEntry {
        for (self.partitions) |*partition| {
            if (partition.isHfsPartition()) {
                return partition;
            }
        }
        return null;
    }
};

/// Parse APM from disk image data
pub fn parseApm(data: []const u8, allocator: Allocator) !ApmInfo {
    if (data.len < BLOCK_SIZE * 2) {
        return error.DataTooSmall;
    }

    // Parse DDM at block 0
    const ddm = try DriverDescriptorMap.parse(data[0..BLOCK_SIZE]);

    // Parse first partition entry to get map entry count
    const first_entry = try PartitionMapEntry.parse(data[BLOCK_SIZE .. BLOCK_SIZE * 2]);
    const num_entries = first_entry.map_entries;

    if (data.len < BLOCK_SIZE * (1 + num_entries)) {
        return error.PartitionEntriesOutOfBounds;
    }

    // Allocate partition array
    const partitions = try allocator.alloc(PartitionMapEntry, num_entries);
    errdefer allocator.free(partitions);

    // Parse all partition entries
    for (0..num_entries) |i| {
        const offset = BLOCK_SIZE * (1 + i);
        partitions[i] = try PartitionMapEntry.parse(data[offset .. offset + BLOCK_SIZE]);
    }

    return ApmInfo{
        .ddm = ddm,
        .partitions = partitions,
        .allocator = allocator,
    };
}

/// Check if data contains a valid APM
pub fn hasApm(data: []const u8) bool {
    if (data.len < BLOCK_SIZE * 2) return false;

    // Check DDM signature at block 0
    const ddm_sig = std.mem.readInt(u16, data[0..2], .big);
    if (ddm_sig != DDM_SIGNATURE) return false;

    // Check partition map signature at block 1
    const pm_sig = std.mem.readInt(u16, data[BLOCK_SIZE .. BLOCK_SIZE + 2], .big);
    return pm_sig == PM_SIGNATURE;
}

// ============ Tests ============

test "DDM_SIGNATURE and PM_SIGNATURE are correct" {
    try std.testing.expectEqual(@as(u16, 0x4552), DDM_SIGNATURE); // 'ER'
    try std.testing.expectEqual(@as(u16, 0x504D), PM_SIGNATURE); // 'PM'
}

test "DriverDescriptorMap.parse rejects invalid signature" {
    var data = std.mem.zeroes([18]u8);
    data[0] = 'X';
    const result = DriverDescriptorMap.parse(&data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "DriverDescriptorMap.parse parses valid DDM" {
    var data = std.mem.zeroes([512]u8);

    // Signature: 'ER' (big-endian)
    data[0] = 0x45; // 'E'
    data[1] = 0x52; // 'R'

    // Block size: 512
    std.mem.writeInt(u16, data[2..4], 512, .big);

    // Block count: 1000
    std.mem.writeInt(u32, data[4..8], 1000, .big);

    const ddm = try DriverDescriptorMap.parse(&data);
    try std.testing.expectEqual(@as(u16, DDM_SIGNATURE), ddm.signature);
    try std.testing.expectEqual(@as(u16, 512), ddm.block_size);
    try std.testing.expectEqual(@as(u32, 1000), ddm.block_count);
}

test "PartitionMapEntry.parse rejects invalid signature" {
    var data = std.mem.zeroes([136]u8);
    data[0] = 'X';
    const result = PartitionMapEntry.parse(&data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "PartitionMapEntry.parse parses valid entry" {
    var data: [512]u8 = [_]u8{0} ** 512;

    // Signature: 'PM' (big-endian)
    data[0] = 0x50; // 'P'
    data[1] = 0x4D; // 'M'

    // Map entries: 3
    std.mem.writeInt(u32, data[4..8], 3, .big);

    // Physical block start: 100
    std.mem.writeInt(u32, data[8..12], 100, .big);

    // Physical block count: 500
    std.mem.writeInt(u32, data[12..16], 500, .big);

    // Name: "MacOS" - copy directly into the array
    const name = "MacOS";
    for (name, 0..) |c, i| {
        data[16 + i] = c;
    }

    // Type: "Apple_HFS"
    const type_str = "Apple_HFS";
    for (type_str, 0..) |c, i| {
        data[48 + i] = c;
    }

    // Debug: verify the data is set correctly
    try std.testing.expectEqual(@as(u8, 'M'), data[16]);
    try std.testing.expectEqual(@as(u8, 'a'), data[17]);

    const entry = try PartitionMapEntry.parse(&data);

    // Debug: check raw bytes in entry.name
    try std.testing.expectEqual(@as(u8, 'M'), entry.name[0]);
    try std.testing.expectEqual(@as(u8, 'a'), entry.name[1]);

    try std.testing.expectEqual(@as(u16, PM_SIGNATURE), entry.signature);
    try std.testing.expectEqual(@as(u32, 3), entry.map_entries);
    try std.testing.expectEqual(@as(u32, 100), entry.physical_block_start);
    try std.testing.expectEqual(@as(u32, 500), entry.physical_block_count);
    try std.testing.expectEqualStrings("MacOS", entry.getName());
    try std.testing.expectEqualStrings("Apple_HFS", entry.getTypeName());
}

test "PartitionMapEntry.isHfsPartition works correctly" {
    var data = std.mem.zeroes([512]u8);

    data[0] = 0x50;
    data[1] = 0x4D;
    const type_str = "Apple_HFS";
    for (type_str, 0..) |c, i| {
        data[48 + i] = c;
    }

    const entry = try PartitionMapEntry.parse(&data);
    try std.testing.expect(entry.isHfsPartition());
}

test "PartitionMapEntry.getSizeBytes calculates correctly" {
    var data = std.mem.zeroes([512]u8);

    data[0] = 0x50;
    data[1] = 0x4D;
    std.mem.writeInt(u32, data[12..16], 100, .big);

    const entry = try PartitionMapEntry.parse(&data);
    try std.testing.expectEqual(@as(u64, 100 * 512), entry.getSizeBytes());
}

test "hasApm returns false for non-APM data" {
    const data = std.mem.zeroes([1024]u8);
    try std.testing.expect(!hasApm(&data));
}

test "hasApm returns true for APM data" {
    var data = std.mem.zeroes([1024]u8);

    // DDM signature at block 0
    data[0] = 0x45; // 'E'
    data[1] = 0x52; // 'R'

    // PM signature at block 1
    data[512] = 0x50; // 'P'
    data[513] = 0x4D; // 'M'

    try std.testing.expect(hasApm(&data));
}
