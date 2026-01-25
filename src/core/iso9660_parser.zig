//! ISO 9660 Parser (Pure Zig)
//!
//! Parses ISO 9660 filesystem images (CD-ROM, DVD-ROM).
//! Used for deep validation of DVD/Blu-Ray ISO files.
//!
//! Structure:
//! - Sectors 0-15: System Area (reserved)
//! - Sector 16+: Volume Descriptors (PVD, SVD, VDT)
//! - Path Tables and Directory Records
//!
//! Reference: ECMA-119, ISO 9660:1988

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Sector/block size
pub const SECTOR_SIZE: usize = 2048;

/// Volume descriptor starts at sector 16
pub const VOLUME_DESCRIPTOR_START: usize = 16;

/// Standard identifier for ISO 9660
pub const STANDARD_ID = "CD001";

/// Volume Descriptor Types
pub const VolumeDescriptorType = enum(u8) {
    boot_record = 0,
    primary = 1,
    supplementary = 2,
    partition = 3,
    terminator = 255,
    _,
};

/// File flags
pub const FileFlags = struct {
    pub const HIDDEN: u8 = 0x01;
    pub const DIRECTORY: u8 = 0x02;
    pub const ASSOCIATED: u8 = 0x04;
    pub const EXTENDED_ATTR: u8 = 0x08;
    pub const PERMISSIONS: u8 = 0x10;
    pub const NOT_FINAL: u8 = 0x80;
};

// ============================================================================
// Types
// ============================================================================

/// ISO 9660 Date/Time (7 bytes)
pub const DateTime7 = struct {
    years_since_1900: u8,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    gmt_offset: i8, // 15-minute intervals from GMT
};

/// Directory Record (variable length, 33+ bytes)
pub const DirectoryRecord = struct {
    record_length: u8,
    extended_attr_length: u8,
    extent_location: u32, // Logical block number
    data_length: u32,
    recording_time: DateTime7,
    file_flags: u8,
    file_unit_size: u8,
    interleave_gap_size: u8,
    volume_sequence_number: u16,
    file_identifier: []const u8,

    pub fn isDirectory(self: DirectoryRecord) bool {
        return (self.file_flags & FileFlags.DIRECTORY) != 0;
    }

    pub fn isHidden(self: DirectoryRecord) bool {
        return (self.file_flags & FileFlags.HIDDEN) != 0;
    }
};

/// Primary Volume Descriptor
pub const PrimaryVolumeDescriptor = struct {
    type_code: VolumeDescriptorType,
    standard_id: [5]u8,
    version: u8,
    system_identifier: [32]u8,
    volume_identifier: [32]u8,
    volume_space_size: u32, // Number of logical blocks
    volume_set_size: u16,
    volume_sequence_number: u16,
    logical_block_size: u16,
    path_table_size: u32,
    path_table_location_le: u32,
    path_table_location_be: u32,
    root_directory_record: DirectoryRecord,

    pub fn getVolumeId(self: PrimaryVolumeDescriptor) []const u8 {
        // Trim trailing spaces
        var end: usize = 32;
        while (end > 0 and self.volume_identifier[end - 1] == ' ') {
            end -= 1;
        }
        return self.volume_identifier[0..end];
    }

    pub fn getTotalSize(self: PrimaryVolumeDescriptor) u64 {
        return @as(u64, self.volume_space_size) * @as(u64, self.logical_block_size);
    }
};

/// ISO validation result
pub const Iso9660ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    volume_id: [32]u8,
    volume_size: u64,
    logical_block_size: u16,
    root_directory_location: u32,
    root_directory_size: u32,
    file_count: u32,
    directory_count: u32,

    pub fn ok(pvd: PrimaryVolumeDescriptor, files: u32, dirs: u32) Iso9660ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .volume_id = pvd.volume_identifier,
            .volume_size = pvd.getTotalSize(),
            .logical_block_size = pvd.logical_block_size,
            .root_directory_location = pvd.root_directory_record.extent_location,
            .root_directory_size = pvd.root_directory_record.data_length,
            .file_count = files,
            .directory_count = dirs,
        };
    }

    pub fn invalid(msg: []const u8) Iso9660ValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .volume_id = [_]u8{0} ** 32,
            .volume_size = 0,
            .logical_block_size = 0,
            .root_directory_location = 0,
            .root_directory_size = 0,
            .file_count = 0,
            .directory_count = 0,
        };
    }
};

/// File entry from directory listing
pub const FileEntry = struct {
    name: []const u8,
    extent_location: u32,
    size: u32,
    is_directory: bool,
};

// ============================================================================
// Parsing
// ============================================================================

/// Read both-endian 16-bit value (little-endian first, then big-endian)
fn readBothEndian16(data: []const u8) u16 {
    // ISO 9660 stores both little and big endian; we use little
    return std.mem.readInt(u16, data[0..2], .little);
}

/// Read both-endian 32-bit value
fn readBothEndian32(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .little);
}

/// Parse DateTime7 from 7 bytes
fn parseDateTime7(data: []const u8) DateTime7 {
    return DateTime7{
        .years_since_1900 = data[0],
        .month = data[1],
        .day = data[2],
        .hour = data[3],
        .minute = data[4],
        .second = data[5],
        .gmt_offset = @bitCast(data[6]),
    };
}

/// Parse directory record from buffer
pub fn parseDirectoryRecord(data: []const u8) ?DirectoryRecord {
    if (data.len < 33) return null;

    const record_length = data[0];
    if (record_length < 33 or record_length > data.len) return null;

    const file_id_length = data[32];
    if (33 + file_id_length > record_length) return null;

    return DirectoryRecord{
        .record_length = record_length,
        .extended_attr_length = data[1],
        .extent_location = readBothEndian32(data[2..10]),
        .data_length = readBothEndian32(data[10..18]),
        .recording_time = parseDateTime7(data[18..25]),
        .file_flags = data[25],
        .file_unit_size = data[26],
        .interleave_gap_size = data[27],
        .volume_sequence_number = readBothEndian16(data[28..32]),
        .file_identifier = data[33 .. 33 + file_id_length],
    };
}

/// Parse Primary Volume Descriptor from sector data
pub fn parsePrimaryVolumeDescriptor(data: []const u8) ?PrimaryVolumeDescriptor {
    if (data.len < SECTOR_SIZE) return null;

    // Check type
    const type_code: VolumeDescriptorType = @enumFromInt(data[0]);
    if (type_code != .primary) return null;

    // Check standard identifier
    if (!std.mem.eql(u8, data[1..6], STANDARD_ID)) return null;

    // Check version
    if (data[6] != 1) return null;

    // Parse root directory record at offset 156
    const root_record = parseDirectoryRecord(data[156..190]) orelse return null;

    const pvd = PrimaryVolumeDescriptor{
        .type_code = type_code,
        .standard_id = data[1..6].*,
        .version = data[6],
        .system_identifier = data[8..40].*,
        .volume_identifier = data[40..72].*,
        .volume_space_size = readBothEndian32(data[80..88]),
        .volume_set_size = readBothEndian16(data[120..124]),
        .volume_sequence_number = readBothEndian16(data[124..128]),
        .logical_block_size = readBothEndian16(data[128..132]),
        .path_table_size = readBothEndian32(data[132..140]),
        .path_table_location_le = std.mem.readInt(u32, data[140..144], .little),
        .path_table_location_be = std.mem.readInt(u32, data[148..152], .big),
        .root_directory_record = root_record,
    };

    // Validate logical block size (must be 2048 for CD/DVD)
    if (pvd.logical_block_size != 2048 and pvd.logical_block_size != 512 and
        pvd.logical_block_size != 1024 and pvd.logical_block_size != 4096)
    {
        return null;
    }

    return pvd;
}

/// Find and parse PVD from ISO data
pub fn findPrimaryVolumeDescriptor(data: []const u8) ?PrimaryVolumeDescriptor {
    var sector: usize = VOLUME_DESCRIPTOR_START;

    while (sector * SECTOR_SIZE + SECTOR_SIZE <= data.len) {
        const offset = sector * SECTOR_SIZE;
        const sector_data = data[offset .. offset + SECTOR_SIZE];

        // Check for terminator
        if (sector_data[0] == @intFromEnum(VolumeDescriptorType.terminator)) {
            break;
        }

        // Try to parse as PVD
        if (parsePrimaryVolumeDescriptor(sector_data)) |pvd| {
            return pvd;
        }

        sector += 1;

        // Safety limit
        if (sector > 100) break;
    }

    return null;
}

// ============================================================================
// Directory Iteration
// ============================================================================

/// Iterator over directory entries
pub const DirectoryIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn init(directory_data: []const u8) DirectoryIterator {
        return .{
            .data = directory_data,
            .pos = 0,
        };
    }

    pub fn next(self: *DirectoryIterator) ?DirectoryRecord {
        while (self.pos < self.data.len) {
            // Skip padding (zeros at sector boundaries)
            if (self.data[self.pos] == 0) {
                // Align to next sector
                const next_sector = ((self.pos / SECTOR_SIZE) + 1) * SECTOR_SIZE;
                if (next_sector >= self.data.len) break;
                self.pos = next_sector;
                continue;
            }

            const record = parseDirectoryRecord(self.data[self.pos..]) orelse break;
            self.pos += record.record_length;
            return record;
        }
        return null;
    }
};

// ============================================================================
// Validation
// ============================================================================

/// Validate ISO 9660 filesystem
pub fn validateIso9660(data: []const u8) Iso9660ValidationResult {
    if (data.len < (VOLUME_DESCRIPTOR_START + 1) * SECTOR_SIZE) {
        return Iso9660ValidationResult.invalid("Data too small for ISO 9660");
    }

    // Find Primary Volume Descriptor
    const pvd = findPrimaryVolumeDescriptor(data) orelse {
        return Iso9660ValidationResult.invalid("No Primary Volume Descriptor found");
    };

    // Validate volume size
    const declared_size = pvd.getTotalSize();
    if (declared_size > data.len + SECTOR_SIZE * 10) {
        // Allow some slack for partial images
        return Iso9660ValidationResult.invalid("Volume size exceeds data length");
    }

    // Count files and directories by reading root directory
    var file_count: u32 = 0;
    var dir_count: u32 = 0;

    const root_offset: usize = @as(usize, pvd.root_directory_record.extent_location) * SECTOR_SIZE;
    const root_size: usize = pvd.root_directory_record.data_length;

    if (root_offset + root_size <= data.len) {
        var iter = DirectoryIterator.init(data[root_offset .. root_offset + root_size]);
        while (iter.next()) |record| {
            // Skip . and .. entries
            if (record.file_identifier.len == 1 and
                (record.file_identifier[0] == 0 or record.file_identifier[0] == 1))
            {
                continue;
            }

            if (record.isDirectory()) {
                dir_count += 1;
            } else {
                file_count += 1;
            }
        }
    }

    return Iso9660ValidationResult.ok(pvd, file_count, dir_count);
}

/// Validate ISO 9660 from file
pub fn validateIso9660File(file: std.fs.File, allocator: std.mem.Allocator) Iso9660ValidationResult {
    const file_size = file.getEndPos() catch {
        return Iso9660ValidationResult.invalid("Failed to get file size");
    };

    // Read enough to parse PVD and root directory
    // At minimum, need 17 sectors (system area + PVD)
    const min_read: usize = 20 * SECTOR_SIZE;
    const read_size: usize = @min(file_size, 100 * 1024 * 1024); // Cap at 100MB

    if (read_size < min_read) {
        return Iso9660ValidationResult.invalid("File too small for ISO 9660");
    }

    file.seekTo(0) catch {
        return Iso9660ValidationResult.invalid("Failed to seek");
    };

    const data = allocator.alloc(u8, read_size) catch {
        return Iso9660ValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return Iso9660ValidationResult.invalid("Failed to read file");
    };

    return validateIso9660(data[0..bytes_read]);
}

// ============================================================================
// File Extraction (for deep validation)
// ============================================================================

/// Find file in ISO by path (e.g., "VIDEO_TS/VTS_01_1.VOB")
pub fn findFile(data: []const u8, pvd: PrimaryVolumeDescriptor, path: []const u8) ?FileEntry {
    var current_extent = pvd.root_directory_record.extent_location;
    var current_size = pvd.root_directory_record.data_length;

    // Split path and navigate
    var path_iter = std.mem.splitScalar(u8, path, '/');

    while (path_iter.next()) |component| {
        if (component.len == 0) continue;

        const dir_offset: usize = @as(usize, current_extent) * SECTOR_SIZE;
        if (dir_offset + current_size > data.len) return null;

        var found = false;
        var iter = DirectoryIterator.init(data[dir_offset .. dir_offset + current_size]);

        while (iter.next()) |record| {
            // Compare filename (case-insensitive, handle ;1 suffix)
            var name = record.file_identifier;

            // Remove version number (;1)
            if (std.mem.indexOfScalar(u8, name, ';')) |idx| {
                name = name[0..idx];
            }

            // Case-insensitive compare
            if (std.ascii.eqlIgnoreCase(name, component)) {
                current_extent = record.extent_location;
                current_size = record.data_length;
                found = true;

                // If this is the last component, return it
                if (path_iter.peek() == null) {
                    return FileEntry{
                        .name = record.file_identifier,
                        .extent_location = record.extent_location,
                        .size = record.data_length,
                        .is_directory = record.isDirectory(),
                    };
                }
                break;
            }
        }

        if (!found) return null;
    }

    return null;
}

/// Directory listing result - caller must call deinit(allocator) when done
pub const DirectoryListing = struct {
    items: []FileEntry,
    allocator: std.mem.Allocator,
    capacity: usize,

    pub fn deinit(self: *DirectoryListing) void {
        if (self.capacity > 0) {
            self.allocator.free(self.items.ptr[0..self.capacity]);
        }
        self.* = undefined;
    }
};

/// List files in directory
pub fn listDirectory(
    data: []const u8,
    extent_location: u32,
    extent_size: u32,
    allocator: std.mem.Allocator,
) !DirectoryListing {
    var files: std.ArrayListUnmanaged(FileEntry) = .{};
    errdefer files.deinit(allocator);

    const dir_offset: usize = @as(usize, extent_location) * SECTOR_SIZE;
    if (dir_offset + extent_size > data.len) {
        return DirectoryListing{
            .items = files.items,
            .allocator = allocator,
            .capacity = files.capacity,
        };
    }

    var iter = DirectoryIterator.init(data[dir_offset .. dir_offset + extent_size]);

    while (iter.next()) |record| {
        // Skip . and ..
        if (record.file_identifier.len == 1 and
            (record.file_identifier[0] == 0 or record.file_identifier[0] == 1))
        {
            continue;
        }

        try files.append(allocator, .{
            .name = record.file_identifier,
            .extent_location = record.extent_location,
            .size = record.data_length,
            .is_directory = record.isDirectory(),
        });
    }

    return DirectoryListing{
        .items = files.items,
        .allocator = allocator,
        .capacity = files.capacity,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseDirectoryRecord - valid record" {
    // Minimal directory record (33 bytes + 1 byte filename)
    var record_data: [34]u8 = [_]u8{0} ** 34;
    record_data[0] = 34; // Record length
    record_data[1] = 0; // Extended attr length
    // Extent location (both-endian)
    std.mem.writeInt(u32, record_data[2..6], 100, .little);
    std.mem.writeInt(u32, record_data[6..10], 100, .big);
    // Data length (both-endian)
    std.mem.writeInt(u32, record_data[10..14], 2048, .little);
    std.mem.writeInt(u32, record_data[14..18], 2048, .big);
    // Date/time
    record_data[18] = 124; // Year (2024)
    record_data[19] = 1; // Month
    record_data[20] = 15; // Day
    record_data[21] = 12; // Hour
    record_data[22] = 30; // Minute
    record_data[23] = 0; // Second
    record_data[24] = 0; // GMT offset
    // Flags
    record_data[25] = 0; // Regular file
    // File unit size, interleave gap
    record_data[26] = 0;
    record_data[27] = 0;
    // Volume sequence number
    std.mem.writeInt(u16, record_data[28..30], 1, .little);
    std.mem.writeInt(u16, record_data[30..32], 1, .big);
    // File identifier length
    record_data[32] = 1;
    // File identifier
    record_data[33] = 'A';

    const record = parseDirectoryRecord(&record_data);
    try std.testing.expect(record != null);
    try std.testing.expectEqual(@as(u32, 100), record.?.extent_location);
    try std.testing.expectEqual(@as(u32, 2048), record.?.data_length);
    try std.testing.expect(!record.?.isDirectory());
}

test "parsePrimaryVolumeDescriptor - valid PVD" {
    var pvd_data: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;

    // Type = Primary (1)
    pvd_data[0] = 1;
    // Standard ID
    @memcpy(pvd_data[1..6], "CD001");
    // Version
    pvd_data[6] = 1;
    // System identifier (32 bytes at offset 8)
    @memcpy(pvd_data[8..20], "TEST SYSTEM ");
    // Volume identifier (32 bytes at offset 40)
    @memcpy(pvd_data[40..52], "TEST VOLUME ");
    // Volume space size (both-endian at offset 80)
    std.mem.writeInt(u32, pvd_data[80..84], 1000, .little);
    std.mem.writeInt(u32, pvd_data[84..88], 1000, .big);
    // Volume set size (both-endian at offset 120)
    std.mem.writeInt(u16, pvd_data[120..122], 1, .little);
    std.mem.writeInt(u16, pvd_data[122..124], 1, .big);
    // Volume sequence number (both-endian at offset 124)
    std.mem.writeInt(u16, pvd_data[124..126], 1, .little);
    std.mem.writeInt(u16, pvd_data[126..128], 1, .big);
    // Logical block size (both-endian at offset 128)
    std.mem.writeInt(u16, pvd_data[128..130], 2048, .little);
    std.mem.writeInt(u16, pvd_data[130..132], 2048, .big);
    // Path table size (both-endian at offset 132)
    std.mem.writeInt(u32, pvd_data[132..136], 100, .little);
    std.mem.writeInt(u32, pvd_data[136..140], 100, .big);
    // Path table locations
    std.mem.writeInt(u32, pvd_data[140..144], 20, .little);
    std.mem.writeInt(u32, pvd_data[148..152], 20, .big);

    // Root directory record at offset 156
    pvd_data[156] = 34; // Record length
    pvd_data[157] = 0; // Extended attr length
    std.mem.writeInt(u32, pvd_data[158..162], 25, .little); // Extent location
    std.mem.writeInt(u32, pvd_data[162..166], 25, .big);
    std.mem.writeInt(u32, pvd_data[166..170], 2048, .little); // Data length
    std.mem.writeInt(u32, pvd_data[170..174], 2048, .big);
    pvd_data[174] = 124; // Year
    pvd_data[175] = 1; // Month
    pvd_data[176] = 1; // Day
    pvd_data[177] = 0; // Hour
    pvd_data[178] = 0; // Minute
    pvd_data[179] = 0; // Second
    pvd_data[180] = 0; // GMT
    pvd_data[181] = FileFlags.DIRECTORY; // Flags = directory
    pvd_data[182] = 0; // File unit size
    pvd_data[183] = 0; // Interleave gap
    std.mem.writeInt(u16, pvd_data[184..186], 1, .little);
    std.mem.writeInt(u16, pvd_data[186..188], 1, .big);
    pvd_data[188] = 1; // File identifier length
    pvd_data[189] = 0; // File identifier (root = 0x00)

    const pvd = parsePrimaryVolumeDescriptor(&pvd_data);
    try std.testing.expect(pvd != null);
    try std.testing.expectEqual(@as(u32, 1000), pvd.?.volume_space_size);
    try std.testing.expectEqual(@as(u16, 2048), pvd.?.logical_block_size);
    try std.testing.expectEqual(@as(u32, 25), pvd.?.root_directory_record.extent_location);
}

test "parsePrimaryVolumeDescriptor - rejects invalid" {
    var pvd_data: [SECTOR_SIZE]u8 = [_]u8{0} ** SECTOR_SIZE;

    // Wrong type
    pvd_data[0] = 0;
    @memcpy(pvd_data[1..6], "CD001");
    pvd_data[6] = 1;

    const pvd = parsePrimaryVolumeDescriptor(&pvd_data);
    try std.testing.expect(pvd == null);
}

test "validateIso9660 - synthetic ISO" {
    // Create minimal synthetic ISO
    const iso_size = 30 * SECTOR_SIZE;
    var iso_data: [iso_size]u8 = [_]u8{0} ** iso_size;

    // System area (sectors 0-15) - empty

    // PVD at sector 16
    const pvd_offset = 16 * SECTOR_SIZE;
    iso_data[pvd_offset + 0] = 1; // Type = Primary
    @memcpy(iso_data[pvd_offset + 1 ..][0..5], "CD001");
    iso_data[pvd_offset + 6] = 1; // Version

    // Volume identifier
    @memcpy(iso_data[pvd_offset + 40 ..][0..8], "TESTISO ");

    // Volume space size
    std.mem.writeInt(u32, iso_data[pvd_offset + 80 ..][0..4], 30, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 84 ..][0..4], 30, .big);

    // Set sizes
    std.mem.writeInt(u16, iso_data[pvd_offset + 120 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 122 ..][0..2], 1, .big);
    std.mem.writeInt(u16, iso_data[pvd_offset + 124 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 126 ..][0..2], 1, .big);

    // Logical block size
    std.mem.writeInt(u16, iso_data[pvd_offset + 128 ..][0..2], 2048, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 130 ..][0..2], 2048, .big);

    // Path table size
    std.mem.writeInt(u32, iso_data[pvd_offset + 132 ..][0..4], 10, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 136 ..][0..4], 10, .big);

    // Path table locations
    std.mem.writeInt(u32, iso_data[pvd_offset + 140 ..][0..4], 18, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 148 ..][0..4], 18, .big);

    // Root directory record at PVD offset 156
    const root_rec = pvd_offset + 156;
    iso_data[root_rec + 0] = 34; // Record length
    iso_data[root_rec + 1] = 0;
    std.mem.writeInt(u32, iso_data[root_rec + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[root_rec + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[root_rec + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[root_rec + 14 ..][0..4], 2048, .big);
    iso_data[root_rec + 18] = 124;
    iso_data[root_rec + 19] = 1;
    iso_data[root_rec + 20] = 1;
    iso_data[root_rec + 25] = FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[root_rec + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[root_rec + 30 ..][0..2], 1, .big);
    iso_data[root_rec + 32] = 1;
    iso_data[root_rec + 33] = 0; // Root = 0x00

    // Volume Descriptor Set Terminator at sector 17
    const vdst_offset = 17 * SECTOR_SIZE;
    iso_data[vdst_offset + 0] = 255; // Type = Terminator
    @memcpy(iso_data[vdst_offset + 1 ..][0..5], "CD001");

    // Root directory at sector 20
    const root_dir = 20 * SECTOR_SIZE;
    // . entry
    iso_data[root_dir + 0] = 34;
    std.mem.writeInt(u32, iso_data[root_dir + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[root_dir + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[root_dir + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[root_dir + 14 ..][0..4], 2048, .big);
    iso_data[root_dir + 25] = FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[root_dir + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[root_dir + 30 ..][0..2], 1, .big);
    iso_data[root_dir + 32] = 1;
    iso_data[root_dir + 33] = 0; // . = 0x00

    // .. entry
    const parent_rec = root_dir + 34;
    iso_data[parent_rec + 0] = 34;
    std.mem.writeInt(u32, iso_data[parent_rec + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[parent_rec + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[parent_rec + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[parent_rec + 14 ..][0..4], 2048, .big);
    iso_data[parent_rec + 25] = FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[parent_rec + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[parent_rec + 30 ..][0..2], 1, .big);
    iso_data[parent_rec + 32] = 1;
    iso_data[parent_rec + 33] = 1; // .. = 0x01

    const result = validateIso9660(&iso_data);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 2048), result.logical_block_size);
    try std.testing.expectEqual(@as(u32, 20), result.root_directory_location);
}

test "ground truth - ISO sample" {
    const file = std.fs.cwd().openFile("ground_truth_examples/iso/sample.iso", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const allocator = std.testing.allocator;
    const result = validateIso9660File(file, allocator);

    try std.testing.expect(result.valid);
    try std.testing.expect(result.logical_block_size > 0);
}
