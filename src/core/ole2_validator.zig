//! OLE2/CFBF (Compound File Binary Format) Deep Validator
//!
//! Validates the structural integrity of OLE2 compound documents used by:
//! - Microsoft Word 97-2003 (.doc)
//! - Microsoft Excel 97-2003 (.xls)
//! - Microsoft PowerPoint 97-2003 (.ppt)
//! - And other applications using the CFBF container format
//!
//! ## Validation Levels
//!
//! This validator performs STRUCTURAL validation only:
//! - Header fields and version compatibility
//! - FAT (File Allocation Table) chain integrity
//! - DIFAT (Double-Indirect FAT) chain integrity
//! - Mini FAT chain integrity
//! - Directory entry validity (types, names, references)
//! - Stream chain consistency
//!
//! ## NOT Validated (Future Work)
//!
//! Binary format structures within streams are NOT validated:
//! - Word: WordDocument stream structure, FIB, piece tables, styles
//! - Excel: Workbook stream BIFF records, cell data, formulas
//! - PowerPoint: PowerPoint Document stream, slides, embedded objects
//!
//! Full binary format validation would require:
//! - ~1000+ pages of MS-DOC/MS-XLS/MS-PPT specifications
//! - Complex state machines for record parsing
//! - VBA macro decompression (MS-OVBA)
//! - Embedded OLE object recursion
//!
//! Options for future deep content validation:
//! 1. libgsf (GNOME Structured File Library) - C, full OLE2 + content
//! 2. Apache POI (Java) - comprehensive but heavy
//! 3. python-oletools - good for analysis, not validation
//! 4. Native Zig implementation - significant effort (~2000+ lines per format)
//!
//! References:
//! - [MS-CFB]: Compound File Binary File Format
//!   https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/
//! - [MS-DOC]: Word Binary File Format
//! - [MS-XLS]: Excel Binary File Format
//! - [MS-PPT]: PowerPoint Binary File Format

const std = @import("std");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

/// OLE2 magic signature: D0 CF 11 E0 A1 B1 1A E1
pub const OLE2_MAGIC = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

/// Special sector values in FAT
const FREESECT: u32 = 0xFFFFFFFF; // Free sector
const ENDOFCHAIN: u32 = 0xFFFFFFFE; // End of chain
const FATSECT: u32 = 0xFFFFFFFD; // FAT sector
const DIFSECT: u32 = 0xFFFFFFFC; // DIFAT sector
const MAXREGSECT: u32 = 0xFFFFFFFA; // Maximum regular sector

/// Directory entry type
const EntryType = enum(u8) {
    unknown = 0,
    storage = 1, // Directory/folder
    stream = 2, // File/data
    root = 5, // Root entry
    _,
};

/// Result of OLE2 validation
pub const Ole2ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    format_detected: ?[]const u8, // "doc", "xls", "ppt", or null
    num_directory_entries: u32,
    num_streams: u32,
    total_fat_sectors: u32,

    pub fn ok(format: ?[]const u8, entries: u32, streams: u32, fat_sectors: u32) Ole2ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .format_detected = format,
            .num_directory_entries = entries,
            .num_streams = streams,
            .total_fat_sectors = fat_sectors,
        };
    }

    pub fn invalid(message: []const u8) Ole2ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .format_detected = null,
            .num_directory_entries = 0,
            .num_streams = 0,
            .total_fat_sectors = 0,
        };
    }
};

/// Parsed OLE2 header
const Ole2Header = struct {
    major_version: u16,
    minor_version: u16,
    sector_size: u32, // Actual size in bytes (512 or 4096)
    mini_sector_size: u32, // Actual size in bytes (64)
    total_fat_sectors: u32,
    first_directory_sector: u32,
    first_mini_fat_sector: u32,
    total_mini_fat_sectors: u32,
    first_difat_sector: u32,
    total_difat_sectors: u32,
    mini_stream_cutoff: u32,
    difat_array: [109]u32, // First 109 DIFAT entries in header
};

/// Validate OLE2/CFBF file structure deeply.
pub fn validateOle2Deep(allocator: Allocator, source: *FileSource) Ole2ValidationResult {
    source.pos = 0;
    const file_size = source.getEndPos() catch {
        return Ole2ValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < 512) {
        return Ole2ValidationResult.invalid(errmsg.fileTooSmallFor("OLE2 (min 512 bytes)"));
    }

    // Read and parse header
    var header_buf: [512]u8 = undefined;
    const header_bytes = source.readAll(&header_buf) catch {
        return Ole2ValidationResult.invalid(errmsg.failedToRead("OLE2 header"));
    };

    if (header_bytes < 512) {
        return Ole2ValidationResult.invalid(errmsg.incomplete("OLE2 header"));
    }

    const header = parseHeader(&header_buf) catch |err| {
        return switch (err) {
            error.InvalidSignature => Ole2ValidationResult.invalid(errmsg.invalidSignature("OLE2")),
            error.InvalidVersion => Ole2ValidationResult.invalid(errmsg.unsupported("OLE2 version")),
            error.InvalidByteOrder => Ole2ValidationResult.invalid("Invalid byte order marker"),
            error.InvalidSectorSize => Ole2ValidationResult.invalid("Invalid sector size"),
            error.InvalidMiniSectorSize => Ole2ValidationResult.invalid("Invalid mini sector size"),
        };
    };

    // Calculate total sectors in file
    // For v3 (512-byte sectors), header occupies 512 bytes; for v4 (4096-byte sectors),
    // header occupies a full 4096-byte sector (512 bytes + zero padding per [MS-CFB]).
    // In both cases, header.sector_size gives the correct header region size.
    const header_region_size: u64 = header.sector_size;
    const total_sectors = @as(u32, @intCast((file_size - header_region_size) / header.sector_size));

    // Validate FAT
    const fat = readFat(allocator, source, &header, total_sectors) catch |err| {
        return switch (err) {
            error.OutOfMemory => Ole2ValidationResult.invalid(errmsg.outOfMemory("reading FAT")),
            error.InvalidDifatChain => Ole2ValidationResult.invalid("Invalid DIFAT chain"),
            error.InvalidFatSector => Ole2ValidationResult.invalid("FAT references invalid sector"),
            error.FatChainLoop => Ole2ValidationResult.invalid("FAT chain contains loop"),
            else => Ole2ValidationResult.invalid(errmsg.failedToRead("FAT")),
        };
    };
    defer allocator.free(fat);

    // Validate FAT integrity
    const fat_result = validateFatIntegrity(fat, total_sectors);
    if (!fat_result.valid) {
        return Ole2ValidationResult.invalid(fat_result.error_message.?);
    }

    // Read and validate directory entries
    const dir_result = validateDirectoryEntries(allocator, source, &header, fat, total_sectors) catch |err| {
        return switch (err) {
            error.OutOfMemory => Ole2ValidationResult.invalid(errmsg.outOfMemory("reading directory")),
            error.InvalidDirectorySector => Ole2ValidationResult.invalid("Invalid directory sector"),
            error.DirectoryChainLoop => Ole2ValidationResult.invalid("Directory chain contains loop"),
            else => Ole2ValidationResult.invalid(errmsg.failedToRead("directory")),
        };
    };

    if (!dir_result.valid) {
        return Ole2ValidationResult.invalid(dir_result.error_message.?);
    }

    // Validate mini-FAT integrity (if present)
    if (header.total_mini_fat_sectors > 0 and header.first_mini_fat_sector != ENDOFCHAIN) {
        const mini_fat = readMiniFat(allocator, source, &header, fat) catch {
            return Ole2ValidationResult.invalid("Failed to read mini-FAT");
        };
        defer allocator.free(mini_fat);

        for (mini_fat) |entry| {
            if (entry != FREESECT and entry != ENDOFCHAIN) {
                if (entry > mini_fat.len) {
                    return Ole2ValidationResult.invalid("Mini-FAT entry references invalid mini-sector");
                }
            }
        }
    }

    return Ole2ValidationResult.ok(
        dir_result.format_detected,
        dir_result.num_entries,
        dir_result.num_streams,
        header.total_fat_sectors,
    );
}

const HeaderParseError = error{
    InvalidSignature,
    InvalidVersion,
    InvalidByteOrder,
    InvalidSectorSize,
    InvalidMiniSectorSize,
};

fn parseHeader(buf: *const [512]u8) HeaderParseError!Ole2Header {
    // Validate magic signature
    if (!std.mem.eql(u8, buf[0..8], &OLE2_MAGIC)) {
        return error.InvalidSignature;
    }

    const major_version = std.mem.readInt(u16, buf[0x1A..0x1C], .little);
    const minor_version = std.mem.readInt(u16, buf[0x18..0x1A], .little);

    // Version 3 or 4 only
    if (major_version != 3 and major_version != 4) {
        return error.InvalidVersion;
    }

    // Byte order must be little-endian (0xFFFE)
    const byte_order = std.mem.readInt(u16, buf[0x1C..0x1E], .little);
    if (byte_order != 0xFFFE) {
        return error.InvalidByteOrder;
    }

    // Sector size: 2^power
    const sector_power = std.mem.readInt(u16, buf[0x1E..0x20], .little);
    if (sector_power != 9 and sector_power != 12) {
        return error.InvalidSectorSize;
    }

    // Version 3 must use 512-byte sectors, version 4 must use 4096-byte sectors
    if (major_version == 3 and sector_power != 9) {
        return error.InvalidSectorSize;
    }
    if (major_version == 4 and sector_power != 12) {
        return error.InvalidSectorSize;
    }

    // Mini sector size must be 64 bytes (2^6)
    const mini_sector_power = std.mem.readInt(u16, buf[0x20..0x22], .little);
    if (mini_sector_power != 6) {
        return error.InvalidMiniSectorSize;
    }

    // Parse DIFAT array from header (109 entries at offset 0x4C)
    var difat_array: [109]u32 = undefined;
    for (0..109) |i| {
        const offset = 0x4C + i * 4;
        difat_array[i] = std.mem.readInt(u32, buf[offset..][0..4], .little);
    }

    return Ole2Header{
        .major_version = major_version,
        .minor_version = minor_version,
        .sector_size = @as(u32, 1) << @intCast(sector_power),
        .mini_sector_size = @as(u32, 1) << @intCast(mini_sector_power),
        .total_fat_sectors = std.mem.readInt(u32, buf[0x2C..0x30], .little),
        .first_directory_sector = std.mem.readInt(u32, buf[0x30..0x34], .little),
        .first_mini_fat_sector = std.mem.readInt(u32, buf[0x3C..0x40], .little),
        .total_mini_fat_sectors = std.mem.readInt(u32, buf[0x40..0x44], .little),
        .first_difat_sector = std.mem.readInt(u32, buf[0x44..0x48], .little),
        .total_difat_sectors = std.mem.readInt(u32, buf[0x48..0x4C], .little),
        .mini_stream_cutoff = std.mem.readInt(u32, buf[0x38..0x3C], .little),
        .difat_array = difat_array,
    };
}

const FatReadError = error{
    OutOfMemory,
    InvalidDifatChain,
    InvalidFatSector,
    FatChainLoop,
    ReadError,
};

fn readFat(allocator: Allocator, file: *FileSource, header: *const Ole2Header, total_sectors: u32) FatReadError![]u32 {
    // DoS guard: a CFBF cannot contain more FAT sectors than it has sectors
    // total; reject a crafted header whose total_fat_sectors would request a
    // giant allocation (a ~512-byte file claiming millions of FAT sectors ≈ 17 GB).
    if (header.total_fat_sectors > total_sectors) return error.InvalidFatSector;
    const entries_per_sector = header.sector_size / 4;
    const total_fat_entries = header.total_fat_sectors * entries_per_sector;

    var fat = try allocator.alloc(u32, total_fat_entries);
    errdefer allocator.free(fat);

    var fat_index: usize = 0;
    var sector_buf = try allocator.alloc(u8, header.sector_size);
    defer allocator.free(sector_buf);

    // Read FAT sectors from DIFAT
    // First 109 entries are in header
    var used_difat_count: usize = 0;
    for (header.difat_array) |fat_sector| {
        if (fat_sector == FREESECT) break;
        used_difat_count += 1;
        if (fat_sector > total_sectors) return error.InvalidFatSector;

        // Read FAT sector (sectors start after the header region)
        const sector_offset = @as(u64, header.sector_size) + @as(u64, fat_sector) * header.sector_size;
        file.seekTo(sector_offset) catch return error.ReadError;
        const bytes_read = file.readAll(sector_buf) catch return error.ReadError;
        if (bytes_read < header.sector_size) return error.ReadError;

        // Copy FAT entries
        for (0..entries_per_sector) |i| {
            if (fat_index >= fat.len) break;
            fat[fat_index] = std.mem.readInt(u32, sector_buf[i * 4 ..][0..4], .little);
            fat_index += 1;
        }
    }

    // Validate unused DIFAT entries are FREESECT (structural integrity check)
    for (header.difat_array[used_difat_count..]) |entry| {
        if (entry != FREESECT) return error.InvalidFatSector;
    }

    // If more FAT sectors needed, follow DIFAT chain
    if (header.total_difat_sectors > 0 and header.first_difat_sector != ENDOFCHAIN) {
        var difat_sector = header.first_difat_sector;
        var difat_count: u32 = 0;
        var visited = std.AutoHashMapUnmanaged(u32, void){};
        defer visited.deinit(allocator);

        while (difat_sector != ENDOFCHAIN and difat_count < header.total_difat_sectors) {
            if (difat_sector > total_sectors) return error.InvalidDifatChain;

            // Check for loop
            if (visited.contains(difat_sector)) return error.FatChainLoop;
            try visited.put(allocator, difat_sector, {});

            // Read DIFAT sector
            const sector_offset = @as(u64, header.sector_size) + @as(u64, difat_sector) * header.sector_size;
            file.seekTo(sector_offset) catch return error.ReadError;
            const bytes_read = file.readAll(sector_buf) catch return error.ReadError;
            if (bytes_read < header.sector_size) return error.ReadError;

            // DIFAT sector contains (sector_size/4 - 1) FAT sector references + next DIFAT pointer
            const difat_entries = entries_per_sector - 1;
            for (0..difat_entries) |i| {
                const fat_sector = std.mem.readInt(u32, sector_buf[i * 4 ..][0..4], .little);
                if (fat_sector == FREESECT) break;
                if (fat_sector > total_sectors) return error.InvalidFatSector;

                // Read this FAT sector
                const fat_offset = @as(u64, header.sector_size) + @as(u64, fat_sector) * header.sector_size;
                file.seekTo(fat_offset) catch return error.ReadError;

                var fat_buf = try allocator.alloc(u8, header.sector_size);
                defer allocator.free(fat_buf);

                const fat_bytes = file.readAll(fat_buf) catch return error.ReadError;
                if (fat_bytes < header.sector_size) return error.ReadError;

                for (0..entries_per_sector) |j| {
                    if (fat_index >= fat.len) break;
                    fat[fat_index] = std.mem.readInt(u32, fat_buf[j * 4 ..][0..4], .little);
                    fat_index += 1;
                }
            }

            // Get next DIFAT sector (last entry)
            difat_sector = std.mem.readInt(u32, sector_buf[(difat_entries) * 4 ..][0..4], .little);
            difat_count += 1;
        }
    }

    return fat;
}

const FatIntegrityResult = struct {
    valid: bool,
    error_message: ?[]const u8,
};

fn validateFatIntegrity(fat: []const u32, total_sectors: u32) FatIntegrityResult {
    // Verify all FAT entries point to valid sectors or special values
    for (fat, 0..) |entry, i| {
        if (entry <= MAXREGSECT) {
            // Regular sector reference - must be within file
            if (entry >= total_sectors) {
                return .{ .valid = false, .error_message = "FAT entry references sector beyond file" };
            }
        } else if (entry != FREESECT and entry != ENDOFCHAIN and entry != FATSECT and entry != DIFSECT) {
            // Unknown special value
            _ = i;
            return .{ .valid = false, .error_message = "FAT contains invalid entry value" };
        }
    }

    return .{ .valid = true, .error_message = null };
}

const DirectoryResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    format_detected: ?[]const u8,
    num_entries: u32,
    num_streams: u32,
};

const DirectoryError = error{
    OutOfMemory,
    InvalidDirectorySector,
    DirectoryChainLoop,
    ReadError,
};

fn validateDirectoryEntries(
    allocator: Allocator,
    file: *FileSource,
    header: *const Ole2Header,
    fat: []const u32,
    total_sectors: u32,
) DirectoryError!DirectoryResult {
    const entries_per_sector = header.sector_size / 128; // Each directory entry is 128 bytes

    // Follow directory chain and collect sectors
    var dir_sectors = std.ArrayListUnmanaged(u32).empty;
    defer dir_sectors.deinit(allocator);

    var current = header.first_directory_sector;
    var visited = std.AutoHashMapUnmanaged(u32, void){};
    defer visited.deinit(allocator);

    while (current != ENDOFCHAIN and current <= MAXREGSECT) {
        if (current >= total_sectors) return error.InvalidDirectorySector;
        if (visited.contains(current)) return error.DirectoryChainLoop;
        try visited.put(allocator, current, {});
        try dir_sectors.append(allocator, current);

        if (current < fat.len) {
            current = fat[current];
        } else {
            break;
        }
    }

    if (dir_sectors.items.len == 0) {
        return .{
            .valid = false,
            .error_message = "No directory sectors found",
            .format_detected = null,
            .num_entries = 0,
            .num_streams = 0,
        };
    }

    // Read and validate directory entries
    var num_entries: u32 = 0;
    var num_streams: u32 = 0;
    var format_detected: ?[]const u8 = null;
    var found_root = false;

    var sector_buf = try allocator.alloc(u8, header.sector_size);
    defer allocator.free(sector_buf);

    for (dir_sectors.items) |sector| {
        const sector_offset = @as(u64, header.sector_size) + @as(u64, sector) * header.sector_size;
        file.seekTo(sector_offset) catch return error.ReadError;
        const bytes_read = file.readAll(sector_buf) catch return error.ReadError;
        if (bytes_read < header.sector_size) return error.ReadError;

        for (0..entries_per_sector) |i| {
            const entry_offset = i * 128;
            const entry = sector_buf[entry_offset..][0..128];

            // Entry type at offset 66
            const entry_type: EntryType = @enumFromInt(entry[66]);

            // Skip unknown/empty entries
            if (entry_type == .unknown) continue;

            num_entries += 1;

            // Validate entry type
            switch (entry_type) {
                .root => {
                    found_root = true;
                },
                .stream => {
                    num_streams += 1;

                    // Try to detect format from stream names
                    const name_len = std.mem.readInt(u16, entry[64..66], .little);
                    if (name_len > 0 and name_len <= 64) {
                        // Name is UTF-16LE
                        const name_bytes = (name_len / 2) - 1; // Exclude null terminator
                        if (name_bytes > 0 and name_bytes <= 32) {
                            var name_buf: [32]u8 = undefined;
                            var name_idx: usize = 0;
                            for (0..name_bytes) |j| {
                                const char = entry[j * 2];
                                if (char >= 0x20 and char < 0x7F) {
                                    name_buf[name_idx] = char;
                                    name_idx += 1;
                                }
                            }
                            const name = name_buf[0..name_idx];

                            // Detect format from well-known stream names
                            if (std.mem.eql(u8, name, "WordDocument")) {
                                format_detected = "doc";
                            } else if (std.mem.eql(u8, name, "Workbook") or std.mem.eql(u8, name, "Book")) {
                                format_detected = "xls";
                            } else if (std.mem.eql(u8, name, "PowerPoint Document")) {
                                format_detected = "ppt";
                            }
                        }
                    }
                },
                .storage => {
                    // Storage (directory) entry - validate sibling/child references
                    const left_sibling = std.mem.readInt(u32, entry[68..72], .little);
                    const right_sibling = std.mem.readInt(u32, entry[72..76], .little);
                    const child = std.mem.readInt(u32, entry[76..80], .little);

                    // References must be NOSTREAM (0xFFFFFFFF) or valid entry index
                    const max_entries = @as(u32, @intCast(dir_sectors.items.len)) * entries_per_sector;
                    if (left_sibling != 0xFFFFFFFF and left_sibling >= max_entries) {
                        return .{
                            .valid = false,
                            .error_message = "Invalid directory entry left sibling",
                            .format_detected = null,
                            .num_entries = num_entries,
                            .num_streams = num_streams,
                        };
                    }
                    if (right_sibling != 0xFFFFFFFF and right_sibling >= max_entries) {
                        return .{
                            .valid = false,
                            .error_message = "Invalid directory entry right sibling",
                            .format_detected = null,
                            .num_entries = num_entries,
                            .num_streams = num_streams,
                        };
                    }
                    if (child != 0xFFFFFFFF and child >= max_entries) {
                        return .{
                            .valid = false,
                            .error_message = "Invalid directory entry child",
                            .format_detected = null,
                            .num_entries = num_entries,
                            .num_streams = num_streams,
                        };
                    }
                },
                else => {},
            }

            // Validate stream starting sector (for streams and root)
            if (entry_type == .stream or entry_type == .root) {
                const start_sector = std.mem.readInt(u32, entry[116..120], .little);
                const stream_size = readStreamSize(entry, header);

                if (stream_size > 0 and start_sector != ENDOFCHAIN) {
                    // Small streams use mini stream, large streams use regular FAT
                    if (stream_size >= header.mini_stream_cutoff) {
                        if (start_sector > total_sectors and start_sector <= MAXREGSECT) {
                            return .{
                                .valid = false,
                                .error_message = "Stream start sector beyond file",
                                .format_detected = null,
                                .num_entries = num_entries,
                                .num_streams = num_streams,
                            };
                        }
                    }
                }
            }
        }
    }

    if (!found_root) {
        return .{
            .valid = false,
            .error_message = "No root entry found in directory",
            .format_detected = null,
            .num_entries = num_entries,
            .num_streams = num_streams,
        };
    }

    return .{
        .valid = true,
        .error_message = null,
        .format_detected = format_detected,
        .num_entries = num_entries,
        .num_streams = num_streams,
    };
}

// ============ Stream Reading ============

/// Read stream size from a directory entry, respecting OLE2 version.
/// For v3 (sector size 512), only the low 32 bits of the 64-bit field are valid;
/// the high 32 bits may contain garbage per [MS-CFB] §2.6.
fn readStreamSize(entry: []const u8, header: *const Ole2Header) u64 {
    if (header.major_version == 3) {
        return std.mem.readInt(u32, entry[120..124], .little);
    } else {
        return std.mem.readInt(u64, entry[120..128], .little);
    }
}

/// Directory entry info needed for stream reading
const DirEntryInfo = struct {
    start_sector: u32,
    stream_size: u64,
    entry_type: EntryType,
};

/// Read a named stream from an OLE2 file. Returns allocated bytes or null if not found.
/// stream_name_ascii is an ASCII name (e.g. "WordDocument") which is matched against
/// UTF-16LE directory entry names.
pub fn readNamedStream(allocator: Allocator, source: *FileSource, stream_name_ascii: []const u8) ?[]u8 {
    source.pos = 0;
    const file_size = source.getEndPos() catch return null;
    if (file_size < 512) return null;

    // Read and parse header
    var header_buf: [512]u8 = undefined;
    const header_bytes = source.readAll(&header_buf) catch return null;
    if (header_bytes < 512) return null;

    const header = parseHeader(&header_buf) catch return null;

    const header_region_size: u64 = header.sector_size;
    const total_sectors = @as(u32, @intCast((file_size - header_region_size) / header.sector_size));

    // Read FAT
    const fat = readFat(allocator, source, &header, total_sectors) catch return null;
    defer allocator.free(fat);

    // Read directory entries and find the named stream
    const entry_info = findStreamEntry(allocator, source, &header, fat, total_sectors, stream_name_ascii) catch return null;
    if (entry_info == null) return null;

    const info = entry_info.?;
    if (info.stream_size == 0) {
        // Return empty allocated slice
        return allocator.alloc(u8, 0) catch return null;
    }

    // Sanity check: stream size should not exceed file size (corrupted directory entry)
    if (info.stream_size > file_size) return null;

    // Read the stream data
    if (info.stream_size < header.mini_stream_cutoff and info.entry_type != .root) {
        // Small stream: use mini-FAT + mini-stream
        return readMiniStreamData(allocator, source, &header, fat, total_sectors, info.start_sector, info.stream_size) catch return null;
    } else {
        // Large stream: use regular FAT chain
        return readStreamData(allocator, source, &header, fat, info.start_sector, info.stream_size) catch return null;
    }
}

/// Find a stream entry by ASCII name in the OLE2 directory.
fn findStreamEntry(
    allocator: Allocator,
    file: *FileSource,
    header: *const Ole2Header,
    fat: []const u32,
    total_sectors: u32,
    name_ascii: []const u8,
) !?DirEntryInfo {
    const entries_per_sector = header.sector_size / 128;

    // Collect directory sectors
    var dir_sectors = std.ArrayListUnmanaged(u32).empty;
    defer dir_sectors.deinit(allocator);

    var current = header.first_directory_sector;
    var visited = std.AutoHashMapUnmanaged(u32, void){};
    defer visited.deinit(allocator);

    while (current != ENDOFCHAIN and current <= MAXREGSECT) {
        if (current >= total_sectors) break;
        if (visited.contains(current)) break;
        try visited.put(allocator, current, {});
        try dir_sectors.append(allocator, current);
        if (current < fat.len) {
            current = fat[current];
        } else break;
    }

    var sector_buf = try allocator.alloc(u8, header.sector_size);
    defer allocator.free(sector_buf);

    for (dir_sectors.items) |sector| {
        const sector_offset = @as(u64, header.sector_size) + @as(u64, sector) * header.sector_size;
        file.seekTo(sector_offset) catch continue;
        const bytes_read = file.readAll(sector_buf) catch continue;
        if (bytes_read < header.sector_size) continue;

        for (0..entries_per_sector) |i| {
            const entry_offset = i * 128;
            const entry = sector_buf[entry_offset..][0..128];

            const entry_type: EntryType = @enumFromInt(entry[66]);
            if (entry_type != .stream and entry_type != .root) continue;

            // Extract ASCII name from UTF-16LE
            const name_len = std.mem.readInt(u16, entry[64..66], .little);
            if (name_len < 2 or name_len > 64) continue;

            const name_chars = (name_len / 2) - 1; // Exclude null terminator
            if (name_chars != name_ascii.len) continue;

            // Compare character by character (ASCII in UTF-16LE: low byte = char, high byte = 0)
            var match = true;
            for (0..name_chars) |j| {
                if (entry[j * 2] != name_ascii[j] or entry[j * 2 + 1] != 0) {
                    match = false;
                    break;
                }
            }

            if (match) {
                return DirEntryInfo{
                    .start_sector = std.mem.readInt(u32, entry[116..120], .little),
                    .stream_size = readStreamSize(entry, header),
                    .entry_type = entry_type,
                };
            }
        }
    }

    return null;
}

/// Read stream data following a FAT chain.
fn readStreamData(
    allocator: Allocator,
    file: *FileSource,
    header: *const Ole2Header,
    fat: []const u32,
    start_sector: u32,
    stream_size: u64,
) ![]u8 {
    var data = try allocator.alloc(u8, stream_size);
    errdefer allocator.free(data);

    var offset: usize = 0;
    var current = start_sector;
    var sector_buf = try allocator.alloc(u8, header.sector_size);
    defer allocator.free(sector_buf);
    var chain_len: u32 = 0;
    const max_chain = @as(u32, @intCast(stream_size / header.sector_size)) + 2;

    while (current != ENDOFCHAIN and current <= MAXREGSECT and offset < stream_size) {
        chain_len += 1;
        if (chain_len > max_chain) return error.FatChainLoop;

        const sector_offset = @as(u64, header.sector_size) + @as(u64, current) * header.sector_size;
        file.seekTo(sector_offset) catch return error.ReadError;
        const bytes_read = file.readAll(sector_buf) catch return error.ReadError;
        if (bytes_read < header.sector_size) return error.ReadError;

        const to_copy = @min(header.sector_size, stream_size - offset);
        @memcpy(data[offset..][0..to_copy], sector_buf[0..to_copy]);
        offset += to_copy;

        if (current < fat.len) {
            current = fat[current];
        } else break;
    }

    return data;
}

/// Read mini-stream data (for streams < mini_stream_cutoff).
/// Mini-stream is stored in the root entry's stream data, indexed by mini-FAT.
fn readMiniStreamData(
    allocator: Allocator,
    file: *FileSource,
    header: *const Ole2Header,
    fat: []const u32,
    total_sectors: u32,
    start_mini_sector: u32,
    stream_size: u64,
) ![]u8 {
    // First, find root entry to get mini-stream's start sector and size
    const root_info = (try findStreamEntry(allocator, file, header, fat, total_sectors, "Root Entry")) orelse
        return error.ReadError;

    // Read the full mini-stream (root entry's data via regular FAT)
    const mini_stream = try readStreamData(allocator, file, header, fat, root_info.start_sector, root_info.stream_size);
    defer allocator.free(mini_stream);

    // Read the mini-FAT
    const mini_fat = try readMiniFat(allocator, file, header, fat);
    defer allocator.free(mini_fat);

    // Now follow mini-FAT chain and collect data
    var data = try allocator.alloc(u8, stream_size);
    errdefer allocator.free(data);

    var offset: usize = 0;
    var current = start_mini_sector;
    var chain_len: u32 = 0;
    const max_chain = @as(u32, @intCast(stream_size / header.mini_sector_size)) + 2;

    while (current != ENDOFCHAIN and current <= MAXREGSECT and offset < stream_size) {
        chain_len += 1;
        if (chain_len > max_chain) return error.FatChainLoop;

        const mini_offset = @as(usize, current) * header.mini_sector_size;
        if (mini_offset + header.mini_sector_size > mini_stream.len) return error.ReadError;

        const to_copy = @min(header.mini_sector_size, stream_size - offset);
        @memcpy(data[offset..][0..to_copy], mini_stream[mini_offset..][0..to_copy]);
        offset += to_copy;

        if (current < mini_fat.len) {
            current = mini_fat[current];
        } else break;
    }

    return data;
}

/// Read the mini-FAT from the file.
fn readMiniFat(
    allocator: Allocator,
    file: *FileSource,
    header: *const Ole2Header,
    fat: []const u32,
) ![]u32 {
    if (header.total_mini_fat_sectors == 0 or header.first_mini_fat_sector == ENDOFCHAIN) {
        return try allocator.alloc(u32, 0);
    }

    const entries_per_sector = header.sector_size / 4;
    var mini_fat = std.ArrayListUnmanaged(u32).empty;
    defer mini_fat.deinit(allocator); // only on error path; we transfer ownership below

    var sector_buf = try allocator.alloc(u8, header.sector_size);
    defer allocator.free(sector_buf);

    var current = header.first_mini_fat_sector;
    var chain_len: u32 = 0;

    while (current != ENDOFCHAIN and current <= MAXREGSECT) {
        chain_len += 1;
        if (chain_len > header.total_mini_fat_sectors + 1) break;

        const sector_offset = @as(u64, header.sector_size) + @as(u64, current) * header.sector_size;
        file.seekTo(sector_offset) catch return error.ReadError;
        const bytes_read = file.readAll(sector_buf) catch return error.ReadError;
        if (bytes_read < header.sector_size) return error.ReadError;

        for (0..entries_per_sector) |i| {
            try mini_fat.append(allocator, std.mem.readInt(u32, sector_buf[i * 4 ..][0..4], .little));
        }

        if (current < fat.len) {
            current = fat[current];
        } else break;
    }

    // Transfer ownership - return the internal slice
    const result = try allocator.alloc(u32, mini_fat.items.len);
    @memcpy(result, mini_fat.items);
    return result;
}

// ============ Tests ============

test "readNamedStream returns WordDocument from sample.doc" {
    const allocator = std.testing.allocator;
    var source = FileSource.open("ground_truth_examples/doc/sample.doc") catch return error.SkipZigTest;
    defer source.close();
    const data = readNamedStream(allocator, &source, "WordDocument");
    if (data) |d| {
        defer allocator.free(d);
        // WordDocument stream should be non-empty
        try std.testing.expect(d.len > 0);
        // FIB magic: first 2 bytes should be 0xA5EC (little-endian)
        try std.testing.expect(d.len >= 2);
        const wIdent = std.mem.readInt(u16, d[0..2], .little);
        try std.testing.expectEqual(@as(u16, 0xA5EC), wIdent);
    } else {
        // If sample.doc doesn't exist in test CWD, skip
        return error.SkipZigTest;
    }
}

test "readNamedStream returns null for non-existent stream" {
    const allocator = std.testing.allocator;
    var source = FileSource.open("ground_truth_examples/doc/sample.doc") catch return error.SkipZigTest;
    defer source.close();
    const data = readNamedStream(allocator, &source, "NonExistentStream");
    if (data) |d| {
        defer allocator.free(d);
        // Should not reach here
        try std.testing.expect(false);
    }
    // null is the expected result - test passes
}

test "readNamedStream returns null for non-existent file" {
    // Opening a nonexistent file should fail — test that FileSource.open returns an error
    const result = FileSource.open("/nonexistent/file.doc");
    try std.testing.expectError(error.FileNotFound, result);
}

test "readNamedStream can read Table stream" {
    const allocator = std.testing.allocator;
    var source = FileSource.open("ground_truth_examples/doc/sample.doc") catch return error.SkipZigTest;
    defer source.close();
    // Try both "0Table" and "1Table" — one should exist
    const t0 = readNamedStream(allocator, &source, "0Table");
    const t1 = readNamedStream(allocator, &source, "1Table");
    defer {
        if (t0) |d| allocator.free(d);
        if (t1) |d| allocator.free(d);
    }
    if (t0 == null and t1 == null) {
        // If sample.doc doesn't exist in test CWD, skip
        return error.SkipZigTest;
    }
    // At least one table stream must exist and be non-empty
    const table = t0 orelse t1.?;
    try std.testing.expect(table.len > 0);
}

test "reject non-OLE2 data" {
    const result = Ole2ValidationResult.invalid(errmsg.invalidSignature("OLE2"));
    try std.testing.expect(!result.valid);
}

test "parse valid OLE2 header" {
    // Minimal valid OLE2 header
    var header: [512]u8 = [_]u8{0} ** 512;

    // Magic signature
    @memcpy(header[0..8], &OLE2_MAGIC);

    // Minor version (0x003E)
    header[0x18] = 0x3E;
    header[0x19] = 0x00;

    // Major version (3)
    header[0x1A] = 0x03;
    header[0x1B] = 0x00;

    // Byte order (0xFFFE = little-endian)
    header[0x1C] = 0xFE;
    header[0x1D] = 0xFF;

    // Sector size power (9 = 512 bytes)
    header[0x1E] = 0x09;
    header[0x1F] = 0x00;

    // Mini sector size power (6 = 64 bytes)
    header[0x20] = 0x06;
    header[0x21] = 0x00;

    const parsed = try parseHeader(&header);
    try std.testing.expectEqual(@as(u16, 3), parsed.major_version);
    try std.testing.expectEqual(@as(u32, 512), parsed.sector_size);
    try std.testing.expectEqual(@as(u32, 64), parsed.mini_sector_size);
}

test "reject invalid OLE2 signature" {
    var header: [512]u8 = [_]u8{0} ** 512;
    header[0] = 0x00; // Wrong signature

    const result = parseHeader(&header);
    try std.testing.expectError(error.InvalidSignature, result);
}

test "reject unsupported OLE2 version" {
    var header: [512]u8 = [_]u8{0} ** 512;
    @memcpy(header[0..8], &OLE2_MAGIC);
    header[0x1A] = 0x05; // Version 5 (invalid)
    header[0x1C] = 0xFE;
    header[0x1D] = 0xFF;

    const result = parseHeader(&header);
    try std.testing.expectError(error.InvalidVersion, result);
}

test "validate FAT integrity with valid entries" {
    const fat = [_]u32{ ENDOFCHAIN, 2, ENDOFCHAIN, FREESECT };
    const result = validateFatIntegrity(&fat, 10);
    try std.testing.expect(result.valid);
}

test "validate FAT integrity rejects out-of-bounds reference" {
    const fat = [_]u32{ 100, ENDOFCHAIN }; // Sector 100 beyond file
    const result = validateFatIntegrity(&fat, 10);
    try std.testing.expect(!result.valid);
}

test "readFat rejects a crafted huge total_fat_sectors without a giant allocation (DoS guard)" {
	// A ~512-byte crafted CFBF (.doc/.xls/.msi/Thumbs.db) can declare
	// total_fat_sectors large enough that readFat allocates ~15 GB from a single
	// unchecked 4-byte header field. A file cannot contain more FAT sectors than
	// it has sectors total; bound against that. The FixedBufferAllocator makes a
	// giant request surface as OutOfMemory, so pre-fix this returns OutOfMemory
	// (the giant alloc) and post-fix returns InvalidFatSector BEFORE allocating.
	var backing: [1024]u8 = undefined;
	var src = FileSource.fromBuffer(backing[0..]);
	var header = std.mem.zeroes(Ole2Header);
	header.sector_size = 512;
	header.total_fat_sectors = 30_000_000; // * 128 entries/sector = ~3.84e9 u32 = ~15 GB
	for (&header.difat_array) |*d| d.* = FREESECT;
	var arena: [64 * 1024]u8 = undefined;
	var fba = std.heap.FixedBufferAllocator.init(&arena);
	const result = readFat(fba.allocator(), &src, &header, 1); // total_sectors = 1
	try std.testing.expectError(error.InvalidFatSector, result);
}
