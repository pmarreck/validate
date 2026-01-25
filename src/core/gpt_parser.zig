//! GPT (GUID Partition Table) Parser
//!
//! Parses GPT partition tables from disk images.
//! GPT is the modern partitioning scheme used on UEFI systems.
//!
//! Reference: UEFI Specification 2.10, Section 5.3

const std = @import("std");
const Allocator = std.mem.Allocator;

/// GPT signature: "EFI PART"
pub const GPT_SIGNATURE: u64 = 0x5452415020494645; // "EFI PART" in little-endian

/// Standard sector size
pub const SECTOR_SIZE: usize = 512;

/// GPT Header structure (92 bytes minimum, typically in 512-byte sector)
pub const GptHeader = struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    my_lba: u64,
    alternate_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_of_partition_entry: u32,
    partition_entry_array_crc32: u32,

    /// Parse GPT header from raw bytes
    pub fn parse(data: []const u8) !GptHeader {
        if (data.len < 92) {
            return error.BufferTooSmall;
        }

        const signature = std.mem.readInt(u64, data[0..8], .little);
        if (signature != GPT_SIGNATURE) {
            return error.InvalidSignature;
        }

        return GptHeader{
            .signature = signature,
            .revision = std.mem.readInt(u32, data[8..12], .little),
            .header_size = std.mem.readInt(u32, data[12..16], .little),
            .header_crc32 = std.mem.readInt(u32, data[16..20], .little),
            .reserved = std.mem.readInt(u32, data[20..24], .little),
            .my_lba = std.mem.readInt(u64, data[24..32], .little),
            .alternate_lba = std.mem.readInt(u64, data[32..40], .little),
            .first_usable_lba = std.mem.readInt(u64, data[40..48], .little),
            .last_usable_lba = std.mem.readInt(u64, data[48..56], .little),
            .disk_guid = data[56..72].*,
            .partition_entry_lba = std.mem.readInt(u64, data[72..80], .little),
            .num_partition_entries = std.mem.readInt(u32, data[80..84], .little),
            .size_of_partition_entry = std.mem.readInt(u32, data[84..88], .little),
            .partition_entry_array_crc32 = std.mem.readInt(u32, data[88..92], .little),
        };
    }

    /// Verify the header CRC32
    pub fn verifyCrc32(self: GptHeader, header_data: []const u8) bool {
        if (header_data.len < self.header_size) return false;

        // Create copy with CRC32 field zeroed for verification
        var verify_data: [92]u8 = undefined;
        @memcpy(&verify_data, header_data[0..92]);
        verify_data[16] = 0;
        verify_data[17] = 0;
        verify_data[18] = 0;
        verify_data[19] = 0;

        const computed = std.hash.crc.Crc32Ieee.hash(verify_data[0..self.header_size]);
        return computed == self.header_crc32;
    }
};

/// GPT Partition Entry structure (128 bytes minimum)
pub const GptPartitionEntry = struct {
    partition_type_guid: [16]u8,
    unique_partition_guid: [16]u8,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    partition_name: [72]u8, // UTF-16LE, up to 36 chars

    /// Check if this partition entry is empty (all zeros)
    pub fn isEmpty(self: GptPartitionEntry) bool {
        for (self.partition_type_guid) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Get partition name as UTF-8
    pub fn getName(self: GptPartitionEntry, allocator: Allocator) ![]u8 {
        // Find length (null-terminated UTF-16LE)
        var len: usize = 0;
        while (len < 72) : (len += 2) {
            if (self.partition_name[len] == 0 and self.partition_name[len + 1] == 0) {
                break;
            }
        }

        // Convert UTF-16LE to UTF-8
        const utf16 = std.mem.bytesAsSlice(u16, self.partition_name[0..len]);
        var utf8: std.ArrayListUnmanaged(u8) = .{};
        errdefer utf8.deinit(allocator);

        for (utf16) |code_unit| {
            const native = std.mem.littleToNative(u16, code_unit);
            if (native == 0) break;
            var buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(@intCast(native), &buf) catch continue;
            try utf8.appendSlice(allocator, buf[0..utf8_len]);
        }

        return try utf8.toOwnedSlice(allocator);
    }

    /// Parse partition entry from raw bytes
    pub fn parse(data: []const u8) !GptPartitionEntry {
        if (data.len < 128) {
            return error.BufferTooSmall;
        }

        return GptPartitionEntry{
            .partition_type_guid = data[0..16].*,
            .unique_partition_guid = data[16..32].*,
            .starting_lba = std.mem.readInt(u64, data[32..40], .little),
            .ending_lba = std.mem.readInt(u64, data[40..48], .little),
            .attributes = std.mem.readInt(u64, data[48..56], .little),
            .partition_name = data[56..128].*,
        };
    }

    /// Get the size of this partition in bytes
    pub fn getSizeBytes(self: GptPartitionEntry) u64 {
        if (self.ending_lba < self.starting_lba) return 0;
        return (self.ending_lba - self.starting_lba + 1) * SECTOR_SIZE;
    }
};

/// Well-known partition type GUIDs
pub const PartitionTypeGuid = struct {
    pub const UNUSED: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    pub const EFI_SYSTEM: [16]u8 = .{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
    pub const APPLE_HFS_PLUS: [16]u8 = .{ 0x00, 0x53, 0x46, 0x48, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC };
    pub const APPLE_APFS: [16]u8 = .{ 0xEF, 0x57, 0x34, 0x7C, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC };
    pub const MICROSOFT_BASIC_DATA: [16]u8 = .{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 };
};

/// Parsed GPT information
pub const GptInfo = struct {
    header: GptHeader,
    partitions: []GptPartitionEntry,
    allocator: Allocator,

    pub fn deinit(self: *GptInfo) void {
        self.allocator.free(self.partitions);
    }
};

/// Parse GPT from disk image data
pub fn parseGpt(data: []const u8, allocator: Allocator) !GptInfo {
    // GPT header is at LBA 1 (after protective MBR)
    if (data.len < SECTOR_SIZE * 2) {
        return error.DataTooSmall;
    }

    const header_data = data[SECTOR_SIZE .. SECTOR_SIZE * 2];
    const header = try GptHeader.parse(header_data);

    // Verify header CRC32
    if (!header.verifyCrc32(header_data)) {
        return error.InvalidHeaderCrc;
    }

    // Parse partition entries
    const entry_start = header.partition_entry_lba * SECTOR_SIZE;
    const entry_size = header.size_of_partition_entry;
    const num_entries = header.num_partition_entries;

    if (entry_start + num_entries * entry_size > data.len) {
        return error.PartitionEntriesOutOfBounds;
    }

    // Count non-empty partitions
    var count: usize = 0;
    for (0..num_entries) |i| {
        const offset = entry_start + i * entry_size;
        const entry = try GptPartitionEntry.parse(data[offset .. offset + entry_size]);
        if (!entry.isEmpty()) count += 1;
    }

    // Allocate and fill partition array
    const partitions = try allocator.alloc(GptPartitionEntry, count);
    errdefer allocator.free(partitions);

    var idx: usize = 0;
    for (0..num_entries) |i| {
        const offset = entry_start + i * entry_size;
        const entry = try GptPartitionEntry.parse(data[offset .. offset + entry_size]);
        if (!entry.isEmpty()) {
            partitions[idx] = entry;
            idx += 1;
        }
    }

    return GptInfo{
        .header = header,
        .partitions = partitions,
        .allocator = allocator,
    };
}

/// Check if data contains a valid GPT
pub fn hasGpt(data: []const u8) bool {
    if (data.len < SECTOR_SIZE * 2) return false;
    const header_data = data[SECTOR_SIZE .. SECTOR_SIZE + 8];
    const signature = std.mem.readInt(u64, header_data[0..8], .little);
    return signature == GPT_SIGNATURE;
}

// ============ Tests ============

test "GPT signature constant is correct" {
    const sig_bytes = [8]u8{ 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
    const sig = std.mem.readInt(u64, &sig_bytes, .little);
    try std.testing.expectEqual(GPT_SIGNATURE, sig);
}

test "GptHeader.parse rejects invalid signature" {
    var data: [92]u8 = undefined;
    @memset(&data, 0);
    // Invalid signature
    data[0] = 'X';
    const result = GptHeader.parse(&data);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "GptHeader.parse parses valid header" {
    // Create minimal valid GPT header
    var data: [512]u8 = undefined;
    @memset(&data, 0);

    // Signature: "EFI PART"
    data[0] = 'E';
    data[1] = 'F';
    data[2] = 'I';
    data[3] = ' ';
    data[4] = 'P';
    data[5] = 'A';
    data[6] = 'R';
    data[7] = 'T';

    // Revision: 1.0 (0x00010000)
    std.mem.writeInt(u32, data[8..12], 0x00010000, .little);

    // Header size: 92
    std.mem.writeInt(u32, data[12..16], 92, .little);

    // CRC32 will be computed later
    // Reserved: 0 (already set)

    // my_lba: 1
    std.mem.writeInt(u64, data[24..32], 1, .little);

    // alternate_lba: 100
    std.mem.writeInt(u64, data[32..40], 100, .little);

    // first_usable_lba: 34
    std.mem.writeInt(u64, data[40..48], 34, .little);

    // last_usable_lba: 90
    std.mem.writeInt(u64, data[48..56], 90, .little);

    // partition_entry_lba: 2
    std.mem.writeInt(u64, data[72..80], 2, .little);

    // num_partition_entries: 128
    std.mem.writeInt(u32, data[80..84], 128, .little);

    // size_of_partition_entry: 128
    std.mem.writeInt(u32, data[84..88], 128, .little);

    const header = try GptHeader.parse(&data);
    try std.testing.expectEqual(@as(u64, GPT_SIGNATURE), header.signature);
    try std.testing.expectEqual(@as(u32, 0x00010000), header.revision);
    try std.testing.expectEqual(@as(u32, 92), header.header_size);
    try std.testing.expectEqual(@as(u64, 1), header.my_lba);
    try std.testing.expectEqual(@as(u64, 100), header.alternate_lba);
    try std.testing.expectEqual(@as(u32, 128), header.num_partition_entries);
}

test "GptPartitionEntry.isEmpty returns true for zero entry" {
    var entry: GptPartitionEntry = undefined;
    @memset(&entry.partition_type_guid, 0);
    try std.testing.expect(entry.isEmpty());
}

test "GptPartitionEntry.isEmpty returns false for non-zero entry" {
    var entry: GptPartitionEntry = undefined;
    @memset(&entry.partition_type_guid, 0);
    entry.partition_type_guid[0] = 1;
    try std.testing.expect(!entry.isEmpty());
}

test "hasGpt returns false for non-GPT data" {
    var data: [1024]u8 = undefined;
    @memset(&data, 0);
    try std.testing.expect(!hasGpt(&data));
}

test "hasGpt returns true for GPT data" {
    var data: [1024]u8 = undefined;
    @memset(&data, 0);

    // Put GPT signature at LBA 1
    data[512] = 'E';
    data[513] = 'F';
    data[514] = 'I';
    data[515] = ' ';
    data[516] = 'P';
    data[517] = 'A';
    data[518] = 'R';
    data[519] = 'T';

    try std.testing.expect(hasGpt(&data));
}

test "GptPartitionEntry.getSizeBytes calculates correctly" {
    var entry: GptPartitionEntry = undefined;
    entry.starting_lba = 100;
    entry.ending_lba = 199; // 100 sectors
    try std.testing.expectEqual(@as(u64, 100 * 512), entry.getSizeBytes());
}
