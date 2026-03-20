//! ISO Image Validator (Pure Zig)
//!
//! Recursively validates ISO 9660 and UDF filesystem images by:
//! 1. Parsing the filesystem structure
//! 2. Detecting file formats via magic bytes
//! 3. Validating each file using appropriate validators
//!
//! This catches corruption before PAR2 generation since ISO 9660/UDF
//! have NO internal content checksums.

const std = @import("std");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const iso9660 = @import("iso9660_parser.zig");
const udf = @import("udf_parser.zig");
const format_validation = @import("format_validation.zig");
const errmsg = @import("error_messages.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

/// Per-file validation result
pub const FileValidationResult = struct {
    path: []const u8,
    size: u64,
    format: ?[]const u8,
    valid: bool,
    deep_validated: bool,
};

/// Unknown file extension entry
pub const UnknownExtension = struct {
    extension: [16]u8,
    extension_len: u8,
    count: u32,

    pub fn getExtension(self: *const UnknownExtension) []const u8 {
        return self.extension[0..self.extension_len];
    }
};

/// Overall ISO validation result
pub const IsoValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    filesystem_type: FilesystemType,
    volume_id: []const u8,
    total_files: u32,
    files_validated: u32,
    files_with_errors: u32,
    files_unknown: u32,
    formats_found: u32,
    /// Top unknown extensions (up to 16)
    unknown_extensions: [16]UnknownExtension,
    unknown_extension_count: u8,

    pub const FilesystemType = enum {
        iso9660,
        udf,
        unknown,
    };

    pub fn ok(
        fs_type: FilesystemType,
        vol_id: []const u8,
        total: u32,
        validated: u32,
        errors: u32,
        unknown: u32,
        formats: u32,
        unknown_exts: [16]UnknownExtension,
        unknown_ext_count: u8,
    ) IsoValidationResult {
        return .{
            .valid = errors == 0,
            .error_message = null,
            .filesystem_type = fs_type,
            .volume_id = vol_id,
            .total_files = total,
            .files_validated = validated,
            .files_with_errors = errors,
            .files_unknown = unknown,
            .formats_found = formats,
            .unknown_extensions = unknown_exts,
            .unknown_extension_count = unknown_ext_count,
        };
    }

    pub fn invalid(msg: []const u8) IsoValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .filesystem_type = .unknown,
            .volume_id = "",
            .total_files = 0,
            .files_validated = 0,
            .files_with_errors = 0,
            .files_unknown = 0,
            .formats_found = 0,
            .unknown_extensions = [_]UnknownExtension{.{ .extension = [_]u8{0} ** 16, .extension_len = 0, .count = 0 }} ** 16,
            .unknown_extension_count = 0,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Extract file extension from filename (lowercase, max 15 chars)
fn extractExtension(filename: []const u8) ?[]const u8 {
    // Find last dot
    var last_dot: ?usize = null;
    for (filename, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }

    if (last_dot) |dot_pos| {
        if (dot_pos + 1 < filename.len) {
            return filename[dot_pos + 1 ..];
        }
    }
    return null;
}

/// Unknown extension tracker
const ExtensionTracker = struct {
    map: std.StringHashMap(u32),
    allocator: Allocator,

    fn init(allocator: Allocator) ExtensionTracker {
        return .{
            .map = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *ExtensionTracker) void {
        // Free all the keys we duped
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.map.deinit();
    }

    fn track(self: *ExtensionTracker, ext: []const u8) void {
        // Normalize to lowercase and limit length
        var normalized: [16]u8 = undefined;
        const len = @min(ext.len, 15);
        for (ext[0..len], 0..) |c, i| {
            normalized[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const norm_ext = normalized[0..len];

        if (self.map.get(norm_ext)) |count| {
            self.map.put(norm_ext, count + 1) catch {};
        } else {
            // Need to dupe the key for storage
            const duped = self.allocator.dupe(u8, norm_ext) catch return;
            self.map.put(duped, 1) catch {
                self.allocator.free(duped);
            };
        }
    }

    fn toArray(self: *ExtensionTracker) struct { exts: [16]UnknownExtension, count: u8 } {
        var result: [16]UnknownExtension = [_]UnknownExtension{.{
            .extension = [_]u8{0} ** 16,
            .extension_len = 0,
            .count = 0,
        }} ** 16;
        var count: u8 = 0;

        // Collect all entries
        var entries: [256]struct { ext: []const u8, cnt: u32 } = undefined;
        var entry_count: usize = 0;

        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            if (entry_count < 256) {
                entries[entry_count] = .{ .ext = entry.key_ptr.*, .cnt = entry.value_ptr.* };
                entry_count += 1;
            }
        }

        // Sort by count descending (simple bubble sort for small array)
        for (0..entry_count) |i| {
            for (i + 1..entry_count) |j| {
                if (entries[j].cnt > entries[i].cnt) {
                    const tmp = entries[i];
                    entries[i] = entries[j];
                    entries[j] = tmp;
                }
            }
        }

        // Take top 16
        for (entries[0..@min(entry_count, 16)]) |entry| {
            const len: u8 = @intCast(@min(entry.ext.len, 16));
            @memcpy(result[count].extension[0..len], entry.ext[0..len]);
            result[count].extension_len = len;
            result[count].count = entry.cnt;
            count += 1;
        }

        return .{ .exts = result, .count = count };
    }
};

// ============================================================================
// Validation
// ============================================================================

/// Validate ISO image with recursive file validation
pub fn validateIso(
    data: []const u8,
    deep_validate: bool,
    max_files: u32,
    allocator: Allocator,
) IsoValidationResult {
    // Try ISO 9660 first
    if (validateIsoViaIso9660(data, deep_validate, max_files, allocator)) |result| {
        return result;
    }

    // Try UDF
    if (validateIsoViaUdf(data, deep_validate, max_files, allocator)) |result| {
        return result;
    }

    return IsoValidationResult.invalid(errmsg.noValidXFound("ISO 9660 or UDF filesystem"));
}

/// Validate using ISO 9660
fn validateIsoViaIso9660(
    data: []const u8,
    deep_validate: bool,
    max_files: u32,
    allocator: Allocator,
) ?IsoValidationResult {
    const pvd = iso9660.findPrimaryVolumeDescriptor(data) orelse return null;

    var total_files: u32 = 0;
    var files_validated: u32 = 0;
    var files_with_errors: u32 = 0;
    var files_unknown: u32 = 0;
    var formats_found: u32 = 0;

    // Recursively scan directories
    var format_set = std.AutoHashMap(u32, void).init(allocator);
    defer format_set.deinit();

    var ext_tracker = ExtensionTracker.init(allocator);
    defer ext_tracker.deinit();

    validateDirectoryRecursive(
        data,
        pvd.root_directory_record.extent_location,
        pvd.root_directory_record.data_length,
        "",
        deep_validate,
        max_files,
        &total_files,
        &files_validated,
        &files_with_errors,
        &files_unknown,
        &format_set,
        &ext_tracker,
        allocator,
    );

    formats_found = @intCast(format_set.count());
    const ext_result = ext_tracker.toArray();

    const vol_id = std.mem.trimRight(u8, &pvd.volume_identifier, " \x00");

    return IsoValidationResult.ok(
        .iso9660,
        vol_id,
        total_files,
        files_validated,
        files_with_errors,
        files_unknown,
        formats_found,
        ext_result.exts,
        ext_result.count,
    );
}

/// Validate using UDF
fn validateIsoViaUdf(
    data: []const u8,
    deep_validate: bool,
    max_files: u32,
    allocator: Allocator,
) ?IsoValidationResult {
    const volume_info = udf.parseUdfVolume(data) orelse return null;

    var total_files: u32 = 0;
    var files_validated: u32 = 0;
    var files_with_errors: u32 = 0;
    var files_unknown: u32 = 0;
    var formats_found: u32 = 0;

    var format_set = std.AutoHashMap(u32, void).init(allocator);
    defer format_set.deinit();

    var ext_tracker = ExtensionTracker.init(allocator);
    defer ext_tracker.deinit();

    validateUdfDirectoryRecursive(
        data,
        &volume_info,
        volume_info.root_directory_lbn,
        "",
        deep_validate,
        max_files,
        &total_files,
        &files_validated,
        &files_with_errors,
        &files_unknown,
        &format_set,
        &ext_tracker,
        allocator,
    );

    formats_found = @intCast(format_set.count());
    const ext_result = ext_tracker.toArray();

    return IsoValidationResult.ok(
        .udf,
        volume_info.getVolumeId(),
        total_files,
        files_validated,
        files_with_errors,
        files_unknown,
        formats_found,
        ext_result.exts,
        ext_result.count,
    );
}

/// Recursively validate ISO 9660 directory
fn validateDirectoryRecursive(
    data: []const u8,
    extent_location: u32,
    extent_size: u32,
    parent_path: []const u8,
    deep_validate: bool,
    max_files: u32,
    total_files: *u32,
    files_validated: *u32,
    files_with_errors: *u32,
    files_unknown: *u32,
    format_set: *std.AutoHashMap(u32, void),
    ext_tracker: *ExtensionTracker,
    allocator: Allocator,
) void {
    _ = parent_path;

    if (total_files.* >= max_files) return;

    var listing = iso9660.listDirectory(data, extent_location, extent_size, allocator) catch return;
    defer listing.deinit();

    for (listing.items) |entry| {
        if (total_files.* >= max_files) break;

        if (entry.is_directory) {
            // Recurse into subdirectory
            validateDirectoryRecursive(
                data,
                entry.extent_location,
                entry.size,
                entry.name,
                deep_validate,
                max_files,
                total_files,
                files_validated,
                files_with_errors,
                files_unknown,
                format_set,
                ext_tracker,
                allocator,
            );
        } else {
            // Validate file
            total_files.* += 1;

            if (deep_validate) {
                const file_offset: usize = @as(usize, entry.extent_location) * iso9660.SECTOR_SIZE;
                const file_size: usize = @min(entry.size, data.len -| file_offset);

                if (file_offset + file_size <= data.len and file_size > 0) {
                    const file_data = data[file_offset .. file_offset + file_size];

                    // Use validateDataBuffer for full structural validation
                    const result = format_validation.validateDataBuffer(file_data, allocator);

                    if (result.format != .unknown) {
                        format_set.put(@intFromEnum(result.format), {}) catch {};
                        if (result.is_valid) {
                            files_validated.* += 1;
                        } else {
                            // Format recognized but validation failed - corrupted file
                            files_with_errors.* += 1;
                        }
                    } else {
                        // Track unknown file
                        files_unknown.* += 1;
                        if (extractExtension(entry.name)) |ext| {
                            ext_tracker.track(ext);
                        }
                    }
                }
            }
        }
    }
}

/// Recursively validate UDF directory
fn validateUdfDirectoryRecursive(
    data: []const u8,
    volume_info: *const udf.UdfVolumeInfo,
    dir_lbn: u32,
    parent_path: []const u8,
    deep_validate: bool,
    max_files: u32,
    total_files: *u32,
    files_validated: *u32,
    files_with_errors: *u32,
    files_unknown: *u32,
    format_set: *std.AutoHashMap(u32, void),
    ext_tracker: *ExtensionTracker,
    allocator: Allocator,
) void {
    if (total_files.* >= max_files) return;

    var listing = udf.listUdfDirectory(data, volume_info, dir_lbn, allocator) catch return;
    defer listing.deinit();

    for (listing.items) |entry| {
        if (total_files.* >= max_files) break;

        if (entry.is_directory) {
            // Recurse into subdirectory
            validateUdfDirectoryRecursive(
                data,
                volume_info,
                entry.location_lbn,
                entry.name,
                deep_validate,
                max_files,
                total_files,
                files_validated,
                files_with_errors,
                files_unknown,
                format_set,
                ext_tracker,
                allocator,
            );
        } else {
            // Validate file - count it first
            total_files.* += 1;

            // For UDF, we need to read the file content
            // UDF files have their extent info in the FID or FileEntry
            if (deep_validate and entry.size > 0) {
                // Calculate file offset from partition start + location
                // Note: UDF uses sector_size from volume, but typically 2048
                const file_offset: usize = (@as(usize, volume_info.partition_start) + @as(usize, entry.location_lbn)) * udf.SECTOR_SIZE;
                const file_size: usize = @min(entry.size, data.len -| file_offset);

                if (file_offset + file_size <= data.len and file_size > 0) {
                    const file_data = data[file_offset .. file_offset + file_size];

                    // Use validateDataBuffer for full structural validation
                    const result = format_validation.validateDataBuffer(file_data, allocator);

                    if (result.format != .unknown) {
                        format_set.put(@intFromEnum(result.format), {}) catch {};
                        if (result.is_valid) {
                            files_validated.* += 1;
                        } else {
                            // Format recognized but validation failed - corrupted file
                            files_with_errors.* += 1;
                        }
                    } else {
                        // Track unknown file
                        files_unknown.* += 1;
                        if (extractExtension(entry.name)) |ext| {
                            ext_tracker.track(ext);
                        }
                    }
                }
            }
        }
    }

    // parent_path is passed to recursive calls for path building (unused currently)
    _ = parent_path;
}

/// Validate ISO image from file
pub fn validateIsoFile(
    file: *FileSource,
    deep_validate: bool,
    max_files: u32,
    allocator: Allocator,
) IsoValidationResult {
    const file_size = file.getEndPos() catch {
        return IsoValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // Limit memory usage
    const max_read: usize = 500 * 1024 * 1024; // 500MB
    const read_size: usize = @min(file_size, max_read);

    file.seekTo(0) catch {
        return IsoValidationResult.invalid("Failed to seek");
    };

    const data = allocator.alloc(u8, read_size) catch {
        return IsoValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return IsoValidationResult.invalid(errmsg.failedToRead("file"));
    };

    return validateIso(data[0..bytes_read], deep_validate, max_files, allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "validateIso rejects garbage" {
    var garbage: [1024]u8 = undefined;
    @memset(&garbage, 0xAB);
    const result = validateIso(&garbage, false, 100, std.testing.allocator);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.filesystem_type == .unknown);
}

test "IsoValidationResult constructors" {
    const empty_exts = [_]UnknownExtension{.{ .extension = [_]u8{0} ** 16, .extension_len = 0, .count = 0 }} ** 16;
    const ok_result = IsoValidationResult.ok(.iso9660, "TEST", 10, 8, 0, 2, 3, empty_exts, 0);
    try std.testing.expect(ok_result.valid);
    try std.testing.expectEqual(@as(u32, 10), ok_result.total_files);
    try std.testing.expectEqual(@as(u32, 2), ok_result.files_unknown);

    const invalid_result = IsoValidationResult.invalid("Test error");
    try std.testing.expect(!invalid_result.valid);
    try std.testing.expectEqualStrings("Test error", invalid_result.error_message.?);
}
