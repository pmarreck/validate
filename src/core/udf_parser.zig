//! UDF (Universal Disk Format) Parser (Pure Zig)
//!
//! Parses UDF filesystems commonly used on DVDs and Blu-ray discs.
//! Implements ECMA-167 and UDF 2.50+ specifications.
//!
//! UDF Structure:
//! - Anchor Volume Descriptor Pointer (AVDP) at sector 256
//! - Volume Descriptor Sequence (VDS)
//! - File Set Descriptor (FSD)
//! - File Identifier Descriptors (FID)
//! - File Entries with ICBs
//!
//! Reference: ECMA-167, OSTA UDF Specification

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// UDF sector size (same as ISO 9660)
pub const SECTOR_SIZE: usize = 2048;

/// Anchor Volume Descriptor Pointer location
pub const AVDP_SECTOR: u32 = 256;

/// UDF descriptor tag identifiers (ECMA-167 Table 1)
pub const TagId = enum(u16) {
    primary_volume_descriptor = 1,
    anchor_volume_descriptor_pointer = 2,
    volume_descriptor_pointer = 3,
    implementation_use_volume_descriptor = 4,
    partition_descriptor = 5,
    logical_volume_descriptor = 6,
    unallocated_space_descriptor = 7,
    terminating_descriptor = 8,
    logical_volume_integrity_descriptor = 9,
    file_set_descriptor = 256,
    file_identifier_descriptor = 257,
    allocation_extent_descriptor = 258,
    indirect_entry = 259,
    terminal_entry = 260,
    file_entry = 261,
    extended_attribute_header_descriptor = 262,
    unallocated_space_entry = 263,
    space_bitmap_descriptor = 264,
    partition_integrity_entry = 265,
    extended_file_entry = 266,
    _,
};

/// UDF file types (ECMA-167 14.6.6)
pub const FileType = enum(u8) {
    unspecified = 0,
    unallocated_space_entry = 1,
    partition_integrity_entry = 2,
    indirect_entry = 3,
    directory = 4,
    regular_file = 5,
    block_special = 6,
    character_special = 7,
    extended_attributes = 8,
    fifo = 9,
    socket = 10,
    terminal_entry = 11,
    symbolic_link = 12,
    stream_directory = 13,
    _,
};

// ============================================================================
// Descriptor Tag (16 bytes, ECMA-167 7.2)
// ============================================================================

pub const DescriptorTag = struct {
    tag_id: TagId,
    descriptor_version: u16,
    tag_checksum: u8,
    reserved: u8,
    tag_serial_number: u16,
    descriptor_crc: u16,
    descriptor_crc_length: u16,
    tag_location: u32,

    pub fn parse(data: []const u8) ?DescriptorTag {
        if (data.len < 16) return null;

        const tag_id_raw = std.mem.readInt(u16, data[0..2], .little);

        return DescriptorTag{
            .tag_id = @enumFromInt(tag_id_raw),
            .descriptor_version = std.mem.readInt(u16, data[2..4], .little),
            .tag_checksum = data[4],
            .reserved = data[5],
            .tag_serial_number = std.mem.readInt(u16, data[6..8], .little),
            .descriptor_crc = std.mem.readInt(u16, data[8..10], .little),
            .descriptor_crc_length = std.mem.readInt(u16, data[10..12], .little),
            .tag_location = std.mem.readInt(u32, data[12..16], .little),
        };
    }

    /// Verify tag checksum (sum of bytes 0-15 mod 256, excluding byte 4)
    pub fn verifyChecksum(data: []const u8) bool {
        if (data.len < 16) return false;

        var sum: u16 = 0;
        for (0..16) |i| {
            if (i != 4) { // Skip checksum byte itself
                sum += data[i];
            }
        }

        return @as(u8, @truncate(sum)) == data[4];
    }
};

// ============================================================================
// Extent Allocation Descriptor (8 bytes, ECMA-167 7.1)
// ============================================================================

pub const ExtentAd = struct {
    extent_length: u32,
    extent_location: u32,

    pub fn parse(data: []const u8) ?ExtentAd {
        if (data.len < 8) return null;

        return ExtentAd{
            .extent_length = std.mem.readInt(u32, data[0..4], .little),
            .extent_location = std.mem.readInt(u32, data[4..8], .little),
        };
    }
};

// ============================================================================
// Long Allocation Descriptor (16 bytes, ECMA-167 14.14.2.1)
// ============================================================================

pub const LongAd = struct {
    extent_length: u32,
    extent_location_lbn: u32, // Logical Block Number
    extent_location_partition: u16,
    implementation_use: [6]u8,

    pub fn parse(data: []const u8) ?LongAd {
        if (data.len < 16) return null;

        var impl_use: [6]u8 = undefined;
        @memcpy(&impl_use, data[10..16]);

        return LongAd{
            .extent_length = std.mem.readInt(u32, data[0..4], .little),
            .extent_location_lbn = std.mem.readInt(u32, data[4..8], .little),
            .extent_location_partition = std.mem.readInt(u16, data[8..10], .little),
            .implementation_use = impl_use,
        };
    }
};

// ============================================================================
// Anchor Volume Descriptor Pointer (ECMA-167 10.2)
// ============================================================================

pub const AnchorVolumeDescriptorPointer = struct {
    tag: DescriptorTag,
    main_vds_extent: ExtentAd,
    reserve_vds_extent: ExtentAd,

    pub fn parse(data: []const u8) ?AnchorVolumeDescriptorPointer {
        if (data.len < 32) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .anchor_volume_descriptor_pointer) return null;

        return AnchorVolumeDescriptorPointer{
            .tag = tag,
            .main_vds_extent = ExtentAd.parse(data[16..24]) orelse return null,
            .reserve_vds_extent = ExtentAd.parse(data[24..32]) orelse return null,
        };
    }
};

// ============================================================================
// Partition Descriptor (ECMA-167 10.5)
// ============================================================================

pub const PartitionDescriptor = struct {
    tag: DescriptorTag,
    volume_descriptor_sequence_number: u32,
    partition_flags: u16,
    partition_number: u16,
    partition_contents: [32]u8,
    partition_starting_location: u32,
    partition_length: u32,

    pub fn parse(data: []const u8) ?PartitionDescriptor {
        if (data.len < 512) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .partition_descriptor) return null;

        var contents: [32]u8 = undefined;
        @memcpy(&contents, data[24..56]);

        return PartitionDescriptor{
            .tag = tag,
            .volume_descriptor_sequence_number = std.mem.readInt(u32, data[16..20], .little),
            .partition_flags = std.mem.readInt(u16, data[20..22], .little),
            .partition_number = std.mem.readInt(u16, data[22..24], .little),
            .partition_contents = contents,
            .partition_starting_location = std.mem.readInt(u32, data[188..192], .little),
            .partition_length = std.mem.readInt(u32, data[192..196], .little),
        };
    }
};

// ============================================================================
// Logical Volume Descriptor (ECMA-167 10.6)
// ============================================================================

pub const LogicalVolumeDescriptor = struct {
    tag: DescriptorTag,
    volume_descriptor_sequence_number: u32,
    logical_block_size: u32,
    file_set_descriptor_icb: LongAd,
    logical_volume_identifier: [128]u8,

    pub fn parse(data: []const u8) ?LogicalVolumeDescriptor {
        if (data.len < 512) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .logical_volume_descriptor) return null;

        var lv_id: [128]u8 = undefined;
        @memcpy(&lv_id, data[84..212]);

        return LogicalVolumeDescriptor{
            .tag = tag,
            .volume_descriptor_sequence_number = std.mem.readInt(u32, data[16..20], .little),
            .logical_block_size = std.mem.readInt(u32, data[212..216], .little),
            .file_set_descriptor_icb = LongAd.parse(data[248..264]) orelse return null,
            .logical_volume_identifier = lv_id,
        };
    }

    /// Get clean volume identifier (null-terminated)
    pub fn getVolumeId(self: *const LogicalVolumeDescriptor) []const u8 {
        // UDF uses CS0 compressed unicode - first byte is compression ID
        // For simple ASCII, just return trimmed string after compression byte
        var end: usize = self.logical_volume_identifier.len;
        for (0..self.logical_volume_identifier.len) |i| {
            if (self.logical_volume_identifier[i] == 0) {
                end = i;
                break;
            }
        }
        if (end > 1) {
            return self.logical_volume_identifier[1..end];
        }
        return "";
    }
};

// ============================================================================
// File Set Descriptor (ECMA-167 14.1)
// ============================================================================

pub const FileSetDescriptor = struct {
    tag: DescriptorTag,
    recording_date_time: [12]u8, // Timestamp
    root_directory_icb: LongAd,
    file_set_identifier: [32]u8,

    pub fn parse(data: []const u8) ?FileSetDescriptor {
        if (data.len < 512) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .file_set_descriptor) return null;

        var rec_dt: [12]u8 = undefined;
        @memcpy(&rec_dt, data[16..28]);

        var fs_id: [32]u8 = undefined;
        @memcpy(&fs_id, data[304..336]);

        return FileSetDescriptor{
            .tag = tag,
            .recording_date_time = rec_dt,
            .root_directory_icb = LongAd.parse(data[400..416]) orelse return null,
            .file_set_identifier = fs_id,
        };
    }
};

// ============================================================================
// File Identifier Descriptor (ECMA-167 14.4)
// ============================================================================

pub const FileIdentifierDescriptor = struct {
    tag: DescriptorTag,
    file_version_number: u16,
    file_characteristics: u8,
    length_of_file_identifier: u8,
    icb: LongAd,
    length_of_implementation_use: u16,
    file_identifier: []const u8,

    /// File characteristics flags
    pub const Characteristics = struct {
        pub const HIDDEN: u8 = 0x01;
        pub const DIRECTORY: u8 = 0x02;
        pub const DELETED: u8 = 0x04;
        pub const PARENT: u8 = 0x08;
        pub const METADATA: u8 = 0x10;
    };

    pub fn isDirectory(self: *const FileIdentifierDescriptor) bool {
        return (self.file_characteristics & Characteristics.DIRECTORY) != 0;
    }

    pub fn isParent(self: *const FileIdentifierDescriptor) bool {
        return (self.file_characteristics & Characteristics.PARENT) != 0;
    }

    pub fn isHidden(self: *const FileIdentifierDescriptor) bool {
        return (self.file_characteristics & Characteristics.HIDDEN) != 0;
    }

    pub fn parse(data: []const u8) ?FileIdentifierDescriptor {
        if (data.len < 38) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .file_identifier_descriptor) return null;

        const file_version = std.mem.readInt(u16, data[16..18], .little);
        const file_chars = data[18];
        const id_len = data[19];
        const impl_use_len = std.mem.readInt(u16, data[36..38], .little);

        // File identifier starts after fixed header + ICB + implementation use
        const id_start: usize = 38 + impl_use_len;
        if (id_start + id_len > data.len) return null;

        return FileIdentifierDescriptor{
            .tag = tag,
            .file_version_number = file_version,
            .file_characteristics = file_chars,
            .length_of_file_identifier = id_len,
            .icb = LongAd.parse(data[20..36]) orelse return null,
            .length_of_implementation_use = impl_use_len,
            .file_identifier = data[id_start .. id_start + id_len],
        };
    }

    /// Get the total size of this FID (padded to 4-byte boundary)
    pub fn getSize(self: *const FileIdentifierDescriptor) usize {
        const base_size: usize = 38 + self.length_of_implementation_use + self.length_of_file_identifier;
        // Pad to 4-byte boundary
        return (base_size + 3) & ~@as(usize, 3);
    }
};

// ============================================================================
// File Entry (ECMA-167 14.9)
// ============================================================================

pub const FileEntry = struct {
    tag: DescriptorTag,
    icb_tag_file_type: FileType,
    icb_tag_flags: u16,
    uid: u32,
    gid: u32,
    permissions: u32,
    file_link_count: u16,
    information_length: u64, // File size
    logical_blocks_recorded: u64,
    access_time: [12]u8,
    modification_time: [12]u8,
    attribute_time: [12]u8,
    extended_attribute_icb: LongAd,
    length_of_allocation_descriptors: u32,

    pub fn parse(data: []const u8) ?FileEntry {
        if (data.len < 176) return null;

        const tag = DescriptorTag.parse(data) orelse return null;
        if (tag.tag_id != .file_entry and tag.tag_id != .extended_file_entry) return null;

        const icb_flags = std.mem.readInt(u16, data[18..20], .little);
        const file_type_raw = data[20];

        var access_t: [12]u8 = undefined;
        var mod_t: [12]u8 = undefined;
        var attr_t: [12]u8 = undefined;
        @memcpy(&access_t, data[84..96]);
        @memcpy(&mod_t, data[96..108]);
        @memcpy(&attr_t, data[108..120]);

        return FileEntry{
            .tag = tag,
            .icb_tag_file_type = @enumFromInt(file_type_raw),
            .icb_tag_flags = icb_flags,
            .uid = std.mem.readInt(u32, data[36..40], .little),
            .gid = std.mem.readInt(u32, data[40..44], .little),
            .permissions = std.mem.readInt(u32, data[44..48], .little),
            .file_link_count = std.mem.readInt(u16, data[48..50], .little),
            .information_length = std.mem.readInt(u64, data[56..64], .little),
            .logical_blocks_recorded = std.mem.readInt(u64, data[64..72], .little),
            .access_time = access_t,
            .modification_time = mod_t,
            .attribute_time = attr_t,
            .extended_attribute_icb = LongAd.parse(data[136..152]) orelse return null,
            .length_of_allocation_descriptors = std.mem.readInt(u32, data[168..172], .little),
        };
    }

    pub fn isDirectory(self: *const FileEntry) bool {
        return self.icb_tag_file_type == .directory;
    }

    pub fn isRegularFile(self: *const FileEntry) bool {
        return self.icb_tag_file_type == .regular_file;
    }
};

// ============================================================================
// UDF Volume Info
// ============================================================================

pub const UdfVolumeInfo = struct {
    has_avdp: bool,
    partition_start: u32,
    partition_length: u32,
    logical_block_size: u32,
    root_directory_lbn: u32,
    root_directory_partition: u16,
    volume_identifier: [128]u8,

    pub fn getVolumeId(self: *const UdfVolumeInfo) []const u8 {
        var end: usize = self.volume_identifier.len;
        for (0..self.volume_identifier.len) |i| {
            if (self.volume_identifier[i] == 0) {
                end = i;
                break;
            }
        }
        if (end > 1) {
            return self.volume_identifier[1..end];
        }
        return "";
    }
};

// ============================================================================
// High-Level Functions
// ============================================================================

/// Find Anchor Volume Descriptor Pointer
pub fn findAvdp(data: []const u8) ?AnchorVolumeDescriptorPointer {
    // AVDP is at sector 256
    const avdp_offset = AVDP_SECTOR * SECTOR_SIZE;
    if (avdp_offset + SECTOR_SIZE > data.len) return null;

    const avdp_data = data[avdp_offset .. avdp_offset + SECTOR_SIZE];
    if (!DescriptorTag.verifyChecksum(avdp_data)) return null;

    return AnchorVolumeDescriptorPointer.parse(avdp_data);
}

/// Parse UDF volume to get volume info
pub fn parseUdfVolume(data: []const u8) ?UdfVolumeInfo {
    // Find AVDP
    const avdp = findAvdp(data) orelse return null;

    // Read Volume Descriptor Sequence
    var partition_start: u32 = 0;
    var partition_length: u32 = 0;
    var logical_block_size: u32 = SECTOR_SIZE;
    var fsd_lbn: u32 = 0;
    var fsd_partition: u16 = 0;
    var volume_id: [128]u8 = [_]u8{0} ** 128;
    var found_partition = false;
    var found_lvd = false;

    const vds_start = avdp.main_vds_extent.extent_location * SECTOR_SIZE;
    const vds_end = vds_start + avdp.main_vds_extent.extent_length;

    if (vds_end > data.len) return null;

    var pos = vds_start;
    while (pos + SECTOR_SIZE <= vds_end) {
        const sector_data = data[pos .. pos + SECTOR_SIZE];

        if (!DescriptorTag.verifyChecksum(sector_data)) {
            pos += SECTOR_SIZE;
            continue;
        }

        const tag = DescriptorTag.parse(sector_data) orelse {
            pos += SECTOR_SIZE;
            continue;
        };

        switch (tag.tag_id) {
            .partition_descriptor => {
                if (PartitionDescriptor.parse(sector_data)) |pd| {
                    partition_start = pd.partition_starting_location;
                    partition_length = pd.partition_length;
                    found_partition = true;
                }
            },
            .logical_volume_descriptor => {
                if (LogicalVolumeDescriptor.parse(sector_data)) |lvd| {
                    logical_block_size = lvd.logical_block_size;
                    fsd_lbn = lvd.file_set_descriptor_icb.extent_location_lbn;
                    fsd_partition = lvd.file_set_descriptor_icb.extent_location_partition;
                    volume_id = lvd.logical_volume_identifier;
                    found_lvd = true;
                }
            },
            .terminating_descriptor => break,
            else => {},
        }

        pos += SECTOR_SIZE;
    }

    if (!found_partition or !found_lvd) return null;

    // Read File Set Descriptor to get root directory
    const fsd_offset = (partition_start + fsd_lbn) * SECTOR_SIZE;
    if (fsd_offset + SECTOR_SIZE > data.len) return null;

    const fsd_data = data[fsd_offset .. fsd_offset + SECTOR_SIZE];
    const fsd = FileSetDescriptor.parse(fsd_data) orelse return null;

    return UdfVolumeInfo{
        .has_avdp = true,
        .partition_start = partition_start,
        .partition_length = partition_length,
        .logical_block_size = logical_block_size,
        .root_directory_lbn = fsd.root_directory_icb.extent_location_lbn,
        .root_directory_partition = fsd.root_directory_icb.extent_location_partition,
        .volume_identifier = volume_id,
    };
}

/// Check if data contains a UDF filesystem
pub fn isUdf(data: []const u8) bool {
    return findAvdp(data) != null;
}

/// UDF file entry for directory listing
pub const UdfFileEntry = struct {
    name: []const u8,
    location_lbn: u32,
    location_partition: u16,
    size: u64,
    is_directory: bool,
};

/// Directory listing result
pub const UdfDirectoryListing = struct {
    items: []UdfFileEntry,
    allocator: std.mem.Allocator,
    capacity: usize,

    pub fn deinit(self: *UdfDirectoryListing) void {
        if (self.capacity > 0) {
            self.allocator.free(self.items.ptr[0..self.capacity]);
        }
        self.* = undefined;
    }
};

/// List directory contents from UDF
pub fn listUdfDirectory(
    data: []const u8,
    volume_info: *const UdfVolumeInfo,
    dir_lbn: u32,
    allocator: std.mem.Allocator,
) !UdfDirectoryListing {
    var files: std.ArrayListUnmanaged(UdfFileEntry) = .empty;
    errdefer files.deinit(allocator);

    // Calculate absolute offset
    const dir_offset = (volume_info.partition_start + dir_lbn) * SECTOR_SIZE;
    if (dir_offset >= data.len) {
        return UdfDirectoryListing{
            .items = files.items,
            .allocator = allocator,
            .capacity = files.capacity,
        };
    }

    // Read file entry to get allocation descriptors
    const fe_data = data[dir_offset..@min(dir_offset + SECTOR_SIZE, data.len)];
    const fe = FileEntry.parse(fe_data) orelse {
        return UdfDirectoryListing{
            .items = files.items,
            .allocator = allocator,
            .capacity = files.capacity,
        };
    };

    if (!fe.isDirectory()) {
        return UdfDirectoryListing{
            .items = files.items,
            .allocator = allocator,
            .capacity = files.capacity,
        };
    }

    // For embedded allocation descriptors, they start at offset 176
    // The allocation descriptor type is in icb_tag_flags bits 0-2
    const ad_type = fe.icb_tag_flags & 0x07;

    // Type 3 = data is embedded in file entry
    if (ad_type == 3) {
        // Embedded data starts after fixed fields
        const embedded_start: usize = 176;
        const embedded_end = embedded_start + @as(usize, @intCast(@min(fe.length_of_allocation_descriptors, fe.information_length)));

        if (embedded_end <= fe_data.len) {
            const dir_data = fe_data[embedded_start..embedded_end];
            try parseDirectoryFids(dir_data, &files, allocator);
        }
    } else {
        // Type 0 = short allocation descriptors, Type 1 = long allocation descriptors
        // For now, handle simple case of single extent
        const ad_start: usize = 176;
        const ad_end = ad_start + fe.length_of_allocation_descriptors;

        if (ad_end <= fe_data.len and fe.length_of_allocation_descriptors >= 8) {
            // Read first allocation descriptor
            const ad_data = fe_data[ad_start..ad_end];
            var extent_lbn: u32 = 0;
            var extent_len: u32 = 0;

            if (ad_type == 0 and ad_data.len >= 8) {
                // Short AD: 4 bytes length, 4 bytes position
                extent_len = std.mem.readInt(u32, ad_data[0..4], .little) & 0x3FFFFFFF;
                extent_lbn = std.mem.readInt(u32, ad_data[4..8], .little);
            } else if (ad_type == 1 and ad_data.len >= 16) {
                // Long AD
                if (LongAd.parse(ad_data)) |long_ad| {
                    extent_len = long_ad.extent_length & 0x3FFFFFFF;
                    extent_lbn = long_ad.extent_location_lbn;
                }
            }

            if (extent_len > 0 and extent_lbn > 0) {
                const content_offset = (volume_info.partition_start + extent_lbn) * SECTOR_SIZE;
                const content_end = @min(content_offset + extent_len, data.len);

                if (content_offset < data.len) {
                    const dir_content = data[content_offset..content_end];
                    try parseDirectoryFids(dir_content, &files, allocator);
                }
            }
        }
    }

    return UdfDirectoryListing{
        .items = files.items,
        .allocator = allocator,
        .capacity = files.capacity,
    };
}

/// Parse File Identifier Descriptors from directory data
fn parseDirectoryFids(
    dir_data: []const u8,
    files: *std.ArrayListUnmanaged(UdfFileEntry),
    allocator: std.mem.Allocator,
) !void {
    var pos: usize = 0;

    while (pos + 38 <= dir_data.len) {
        const fid = FileIdentifierDescriptor.parse(dir_data[pos..]) orelse break;

        // Skip parent directory entry
        if (!fid.isParent() and fid.length_of_file_identifier > 0) {
            try files.append(allocator, .{
                .name = fid.file_identifier,
                .location_lbn = fid.icb.extent_location_lbn,
                .location_partition = fid.icb.extent_location_partition,
                .size = 0, // Would need to read file entry to get size
                .is_directory = fid.isDirectory(),
            });
        }

        pos += fid.getSize();
    }
}

/// Find a file in UDF filesystem by path
pub fn findUdfFile(
    data: []const u8,
    volume_info: *const UdfVolumeInfo,
    path: []const u8,
    allocator: std.mem.Allocator,
) ?UdfFileEntry {
    // Start from root
    var current_lbn = volume_info.root_directory_lbn;

    // Split path by '/' or '\'
    var path_iter = std.mem.tokenizeAny(u8, path, "/\\");

    while (path_iter.next()) |component| {
        // List current directory
        var listing = listUdfDirectory(data, volume_info, current_lbn, allocator) catch return null;
        defer listing.deinit();

        // Find matching entry
        var found = false;
        for (listing.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, component)) {
                if (path_iter.peek() == null) {
                    // This is the final component - return it
                    return entry;
                } else if (entry.is_directory) {
                    // Traverse into directory
                    current_lbn = entry.location_lbn;
                    found = true;
                    break;
                }
            }
        }

        if (!found) return null;
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "DescriptorTag parse" {
    var tag_data: [16]u8 = [_]u8{0} ** 16;
    // Tag ID = 2 (AVDP)
    std.mem.writeInt(u16, tag_data[0..2], 2, .little);
    // Descriptor version
    std.mem.writeInt(u16, tag_data[2..4], 2, .little);
    // Tag location
    std.mem.writeInt(u32, tag_data[12..16], 256, .little);

    // Calculate checksum
    var sum: u16 = 0;
    for (0..16) |i| {
        if (i != 4) sum += tag_data[i];
    }
    tag_data[4] = @truncate(sum);

    const tag = DescriptorTag.parse(&tag_data);
    try std.testing.expect(tag != null);
    try std.testing.expectEqual(TagId.anchor_volume_descriptor_pointer, tag.?.tag_id);
    try std.testing.expectEqual(@as(u32, 256), tag.?.tag_location);
}

test "DescriptorTag checksum verification" {
    var tag_data: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u16, tag_data[0..2], 2, .little);

    // Calculate correct checksum
    var sum: u16 = 0;
    for (0..16) |i| {
        if (i != 4) sum += tag_data[i];
    }
    tag_data[4] = @truncate(sum);

    try std.testing.expect(DescriptorTag.verifyChecksum(&tag_data));

    // Corrupt checksum
    tag_data[4] = 0xFF;
    try std.testing.expect(!DescriptorTag.verifyChecksum(&tag_data));
}

test "isUdf rejects non-UDF data" {
    var garbage: [AVDP_SECTOR * SECTOR_SIZE + SECTOR_SIZE]u8 = undefined;
    @memset(&garbage, 0xAB);
    try std.testing.expect(!isUdf(&garbage));
}

test "ExtentAd parse" {
    var ad_data: [8]u8 = undefined;
    std.mem.writeInt(u32, ad_data[0..4], 4096, .little);
    std.mem.writeInt(u32, ad_data[4..8], 256, .little);

    const ad = ExtentAd.parse(&ad_data);
    try std.testing.expect(ad != null);
    try std.testing.expectEqual(@as(u32, 4096), ad.?.extent_length);
    try std.testing.expectEqual(@as(u32, 256), ad.?.extent_location);
}

test "LongAd parse" {
    var ad_data: [16]u8 = [_]u8{0} ** 16;
    std.mem.writeInt(u32, ad_data[0..4], 8192, .little);
    std.mem.writeInt(u32, ad_data[4..8], 512, .little);
    std.mem.writeInt(u16, ad_data[8..10], 0, .little);

    const ad = LongAd.parse(&ad_data);
    try std.testing.expect(ad != null);
    try std.testing.expectEqual(@as(u32, 8192), ad.?.extent_length);
    try std.testing.expectEqual(@as(u32, 512), ad.?.extent_location_lbn);
}
