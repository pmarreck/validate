//! Resource fork handling for macOS files.
//!
//! Provides utilities for reading, writing, and managing resource fork data
//! across platforms. On macOS, resource forks are accessed via /..namedfork/rsrc.
//! On other platforms, AppleDouble files (._filename) are used.

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fs = std.fs;

/// AppleDouble magic signatures
pub const APPLEDOUBLE_MAGIC: u32 = 0x00051607;
pub const APPLESINGLE_MAGIC: u32 = 0x00051600;
pub const APPLEDOUBLE_VERSION: u32 = 0x00020000;

/// AppleDouble entry IDs
pub const ENTRY_DATA_FORK: u32 = 1;
pub const ENTRY_RESOURCE_FORK: u32 = 2;
pub const ENTRY_REAL_NAME: u32 = 3;
pub const ENTRY_COMMENT: u32 = 4;
pub const ENTRY_ICON_BW: u32 = 5;
pub const ENTRY_ICON_COLOR: u32 = 6;
pub const ENTRY_FILE_INFO: u32 = 7;
pub const ENTRY_FILE_DATES: u32 = 8;
pub const ENTRY_FINDER_INFO: u32 = 9;
pub const ENTRY_MACINTOSH_FILE_INFO: u32 = 10;
pub const ENTRY_PRODOS_FILE_INFO: u32 = 11;
pub const ENTRY_MSDOS_FILE_INFO: u32 = 12;
pub const ENTRY_AFP_SHORT_NAME: u32 = 13;
pub const ENTRY_AFP_FILE_INFO: u32 = 14;
pub const ENTRY_AFP_DIRECTORY_ID: u32 = 15;

/// Source of resource fork data
pub const ResourceForkSource = enum(u8) {
    /// Not a resource fork entry
    none = 0,
    /// Read from macOS native resource fork (/..namedfork/rsrc)
    native_fork = 1,
    /// Read from AppleDouble file (._filename)
    apple_double = 2,

    pub fn description(self: ResourceForkSource) []const u8 {
        return switch (self) {
            .none => "none",
            .native_fork => "native resource fork",
            .apple_double => "AppleDouble file",
        };
    }
};

/// Resource fork data with metadata
pub const ResourceForkData = struct {
    /// The resource fork contents
    data: []const u8,
    /// Where the data came from
    source: ResourceForkSource,
    /// Size of the data
    size: u64,
    /// Modification time (if available, 0 otherwise)
    mtime_ns: i64,

    pub fn deinit(self: *ResourceForkData, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// AppleDouble entry descriptor
pub const AppleDoubleEntry = struct {
    entry_id: u32,
    offset: u32,
    length: u32,
};

/// Build the AppleDouble path for a file (._filename in same directory)
pub fn appleDoublePath(path: []const u8, buf: []u8) ?[]const u8 {
    const dirname = fs.path.dirname(path);
    const basename = fs.path.basename(path);

    if (dirname) |dir| {
        return std.fmt.bufPrint(buf, "{s}/._" ++ "{s}", .{ dir, basename }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "._" ++ "{s}", .{basename}) catch null;
    }
}

/// Build the native resource fork path (macOS only)
pub fn nativeResourceForkPath(path: []const u8, buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }
    return std.fmt.bufPrint(buf, "{s}/..namedfork/rsrc", .{path}) catch null;
}

/// Check if a file has a native resource fork (macOS only)
pub fn hasNativeResourceFork(path: []const u8) bool {
    if (comptime builtin.os.tag != .macos) {
        return false;
    }

    var rsrc_path_buf: [fs.max_path_bytes]u8 = undefined;
    const rsrc_path = nativeResourceForkPath(path, &rsrc_path_buf) orelse return false;

    const file = if (fs.path.isAbsolute(rsrc_path))
        fs.openFileAbsolute(rsrc_path, .{}) catch return false
    else
        fs.cwd().openFile(rsrc_path, .{}) catch return false;
    defer file.close(runtime.io());

    const stat = file.stat() catch return false;
    return stat.size > 0;
}

/// Check if an AppleDouble file exists for the given path
pub fn hasAppleDoubleFile(path: []const u8) bool {
    var ad_path_buf: [fs.max_path_bytes]u8 = undefined;
    const ad_path = appleDoublePath(path, &ad_path_buf) orelse return false;

    const file = if (fs.path.isAbsolute(ad_path))
        fs.openFileAbsolute(ad_path, .{}) catch return false
    else
        fs.cwd().openFile(ad_path, .{}) catch return false;
    defer file.close(runtime.io());

    // Verify it's actually an AppleDouble file
    var magic_buf: [4]u8 = undefined;
    const bytes_read = file.read(&magic_buf) catch return false;
    if (bytes_read < 4) return false;

    const magic = std.mem.readInt(u32, &magic_buf, .big);
    return magic == APPLEDOUBLE_MAGIC or magic == APPLESINGLE_MAGIC;
}

/// Check if we should protect this file's resource fork
/// Returns true if file has a non-empty resource fork (native or AppleDouble)
pub fn hasProtectableResourceFork(path: []const u8) bool {
    // First check native resource fork (macOS only)
    if (hasNativeResourceFork(path)) {
        return true;
    }

    // Then check AppleDouble file
    if (hasAppleDoubleFile(path)) {
        // Need to verify the AppleDouble has a resource fork entry
        var ad_path_buf: [fs.max_path_bytes]u8 = undefined;
        const ad_path = appleDoublePath(path, &ad_path_buf) orelse return false;

        const rf_size = getAppleDoubleResourceForkSize(ad_path) catch return false;
        return rf_size > 0;
    }

    return false;
}

/// Result from optimized resource fork detection
pub const ResourceForkInfo = struct {
    source: ResourceForkSource,
    size: u64,
};

/// Optimized: Check for resource fork, returning source and size in a single pass.
/// This avoids multiple file opens/stats that were causing scan slowdowns.
/// Returns null if no protectable resource fork exists.
pub fn getResourceForkInfo(path: []const u8) ?ResourceForkInfo {
    // On macOS, first try native resource fork (most common case)
    if (comptime builtin.os.tag == .macos) {
        var rsrc_path_buf: [fs.max_path_bytes]u8 = undefined;
        if (nativeResourceForkPath(path, &rsrc_path_buf)) |rsrc_path| {
            // Use statFile instead of open+stat for efficiency
            // The named fork path works with stat
            const stat = if (fs.path.isAbsolute(rsrc_path))
                fs.cwd().statFile(rsrc_path) catch null
            else
                fs.cwd().statFile(rsrc_path) catch null;

            if (stat) |s| {
                if (s.size > 0) {
                    return ResourceForkInfo{
                        .source = .native_fork,
                        .size = s.size,
                    };
                }
            }
        }
    }

    // Check AppleDouble file (._filename)
    var ad_path_buf: [fs.max_path_bytes]u8 = undefined;
    const ad_path = appleDoublePath(path, &ad_path_buf) orelse return null;

    // Try to open and parse AppleDouble in one pass
    const file = if (fs.path.isAbsolute(ad_path))
        fs.openFileAbsolute(ad_path, .{}) catch return null
    else
        fs.cwd().openFile(ad_path, .{}) catch return null;
    defer file.close(runtime.io());

    // Read header (26 bytes)
    var header: [26]u8 = undefined;
    const header_bytes = file.read(&header) catch return null;
    if (header_bytes < 26) return null;

    // Verify magic
    const magic = std.mem.readInt(u32, header[0..4], .big);
    if (magic != APPLEDOUBLE_MAGIC and magic != APPLESINGLE_MAGIC) {
        return null;
    }

    // Get number of entries
    const num_entries = std.mem.readInt(u16, header[24..26], .big);
    if (num_entries == 0 or num_entries > 100) {
        return null;
    }

    // Read entries and find resource fork
    var entry_buf: [12]u8 = undefined;
    var i: u16 = 0;
    while (i < num_entries) : (i += 1) {
        const entry_bytes = file.read(&entry_buf) catch return null;
        if (entry_bytes < 12) return null;

        const entry_id = std.mem.readInt(u32, entry_buf[0..4], .big);
        if (entry_id == ENTRY_RESOURCE_FORK) {
            const length = std.mem.readInt(u32, entry_buf[8..12], .big);
            if (length > 0) {
                return ResourceForkInfo{
                    .source = .apple_double,
                    .size = length,
                };
            }
            return null;
        }
    }

    return null;
}

/// Get the size of the resource fork in an AppleDouble file
fn getAppleDoubleResourceForkSize(ad_path: []const u8) !u64 {
    const file = if (fs.path.isAbsolute(ad_path))
        try fs.openFileAbsolute(ad_path, .{})
    else
        try fs.cwd().openFile(ad_path, .{});
    defer file.close(runtime.io());

    // Read header
    var header: [26]u8 = undefined;
    const bytes_read = try file.read(&header);
    if (bytes_read < 26) return error.InvalidFormat;

    // Verify magic
    const magic = std.mem.readInt(u32, header[0..4], .big);
    if (magic != APPLEDOUBLE_MAGIC and magic != APPLESINGLE_MAGIC) {
        return error.InvalidFormat;
    }

    // Get number of entries
    const num_entries = std.mem.readInt(u16, header[24..26], .big);
    if (num_entries == 0 or num_entries > 100) {
        return error.InvalidFormat;
    }

    // Read entries and find resource fork
    var entry_buf: [12]u8 = undefined;
    var i: u16 = 0;
    while (i < num_entries) : (i += 1) {
        const entry_bytes = try file.read(&entry_buf);
        if (entry_bytes < 12) return error.InvalidFormat;

        const entry_id = std.mem.readInt(u32, entry_buf[0..4], .big);
        if (entry_id == ENTRY_RESOURCE_FORK) {
            const length = std.mem.readInt(u32, entry_buf[8..12], .big);
            return length;
        }
    }

    return 0; // No resource fork entry found
}

/// Read resource fork data from native fork (macOS only)
fn readNativeResourceFork(allocator: Allocator, path: []const u8) !?ResourceForkData {
    if (comptime builtin.os.tag != .macos) {
        return null;
    }

    var rsrc_path_buf: [fs.max_path_bytes]u8 = undefined;
    const rsrc_path = nativeResourceForkPath(path, &rsrc_path_buf) orelse return null;

    const file = if (fs.path.isAbsolute(rsrc_path))
        fs.openFileAbsolute(rsrc_path, .{}) catch return null
    else
        fs.cwd().openFile(rsrc_path, .{}) catch return null;
    defer file.close(runtime.io());

    const stat = file.stat() catch return null;
    if (stat.size == 0) return null;

    const data = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) {
        allocator.free(data);
        return null;
    }

    return ResourceForkData{
        .data = data,
        .source = .native_fork,
        .size = stat.size,
        .mtime_ns = @intCast(stat.mtime),
    };
}

/// Read resource fork data from AppleDouble file
pub fn readAppleDoubleResourceFork(allocator: Allocator, path: []const u8) !?ResourceForkData {
    var ad_path_buf: [fs.max_path_bytes]u8 = undefined;
    const ad_path = appleDoublePath(path, &ad_path_buf) orelse return null;

    const file = if (fs.path.isAbsolute(ad_path))
        fs.openFileAbsolute(ad_path, .{}) catch return null
    else
        fs.cwd().openFile(ad_path, .{}) catch return null;
    defer file.close(runtime.io());

    const stat = file.stat() catch return null;

    // Read header
    var header: [26]u8 = undefined;
    const header_bytes = file.read(&header) catch return null;
    if (header_bytes < 26) return null;

    // Verify magic
    const magic = std.mem.readInt(u32, header[0..4], .big);
    if (magic != APPLEDOUBLE_MAGIC and magic != APPLESINGLE_MAGIC) {
        return null;
    }

    // Get number of entries
    const num_entries = std.mem.readInt(u16, header[24..26], .big);
    if (num_entries == 0 or num_entries > 100) {
        return null;
    }

    // Read entries and find resource fork
    var entry_buf: [12]u8 = undefined;
    var i: u16 = 0;
    while (i < num_entries) : (i += 1) {
        const entry_bytes = file.read(&entry_buf) catch return null;
        if (entry_bytes < 12) return null;

        const entry_id = std.mem.readInt(u32, entry_buf[0..4], .big);
        if (entry_id == ENTRY_RESOURCE_FORK) {
            const offset = std.mem.readInt(u32, entry_buf[4..8], .big);
            const length = std.mem.readInt(u32, entry_buf[8..12], .big);

            if (length == 0) return null;

            // Seek to resource fork data
            file.seekTo(offset) catch return null;

            // Read the data
            const data = try allocator.alloc(u8, length);
            errdefer allocator.free(data);

            const bytes_read = file.readAll(data) catch {
                allocator.free(data);
                return null;
            };
            if (bytes_read != length) {
                allocator.free(data);
                return null;
            }

            return ResourceForkData{
                .data = data,
                .source = .apple_double,
                .size = length,
                .mtime_ns = @intCast(stat.mtime),
            };
        }
    }

    return null;
}

/// Read resource fork data, trying multiple sources in order:
/// 1. On macOS: native resource fork via /..namedfork/rsrc
/// 2. AppleDouble file: ._<filename> in same directory
pub fn readResourceForkData(allocator: Allocator, path: []const u8) !?ResourceForkData {
    // First try native resource fork (macOS only)
    if (comptime builtin.os.tag == .macos) {
        if (try readNativeResourceFork(allocator, path)) |data| {
            return data;
        }
    }

    // Then try AppleDouble file
    return try readAppleDoubleResourceFork(allocator, path);
}

/// Write resource fork data to native fork (macOS only)
fn writeNativeResourceFork(path: []const u8, data: []const u8) !void {
    if (comptime builtin.os.tag != .macos) {
        return error.UnsupportedPlatform;
    }

    var rsrc_path_buf: [fs.max_path_bytes]u8 = undefined;
    const rsrc_path = nativeResourceForkPath(path, &rsrc_path_buf) orelse return error.InvalidPath;

    const file = if (fs.path.isAbsolute(rsrc_path))
        try fs.createFileAbsolute(rsrc_path, .{})
    else
        try fs.cwd().createFile(rsrc_path, .{});
    defer file.close(runtime.io());

    try file.writePositionalAll(runtime.io(), data, 0);
}

/// Create an AppleDouble file with resource fork data
pub fn writeAppleDoubleFile(allocator: Allocator, path: []const u8, resource_fork_data: []const u8) !void {
    var ad_path_buf: [fs.max_path_bytes]u8 = undefined;
    const ad_path = appleDoublePath(path, &ad_path_buf) orelse return error.InvalidPath;

    // AppleDouble header: 26 bytes + one entry descriptor (12 bytes) = 38 bytes
    // Resource fork starts at offset 38
    const header_size: u32 = 26;
    const entry_size: u32 = 12;
    const rf_offset: u32 = header_size + entry_size;
    const rf_length: u32 = @intCast(resource_fork_data.len);

    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(allocator);

    // Write header
    var header: [26]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], APPLEDOUBLE_MAGIC, .big); // Magic
    std.mem.writeInt(u32, header[4..8], APPLEDOUBLE_VERSION, .big); // Version
    @memset(header[8..24], 0); // Filler (16 bytes)
    std.mem.writeInt(u16, header[24..26], 1, .big); // Number of entries
    try buffer.appendSlice(allocator, &header);

    // Write resource fork entry descriptor
    var entry: [12]u8 = undefined;
    std.mem.writeInt(u32, entry[0..4], ENTRY_RESOURCE_FORK, .big); // Entry ID
    std.mem.writeInt(u32, entry[4..8], rf_offset, .big); // Offset
    std.mem.writeInt(u32, entry[8..12], rf_length, .big); // Length
    try buffer.appendSlice(allocator, &entry);

    // Write resource fork data
    try buffer.appendSlice(allocator, resource_fork_data);

    // Write to file
    const file = if (fs.path.isAbsolute(ad_path))
        try fs.createFileAbsolute(ad_path, .{})
    else
        try fs.cwd().createFile(ad_path, .{});
    defer file.close(runtime.io());

    try file.writePositionalAll(runtime.io(), buffer.items, 0);
}

/// Write resource fork data to the appropriate location based on source
pub fn writeResourceForkData(allocator: Allocator, path: []const u8, data: []const u8, source: ResourceForkSource) !void {
    switch (source) {
        .none => return error.InvalidSource,
        .native_fork => {
            if (comptime builtin.os.tag != .macos) {
                // Fall back to AppleDouble on non-macOS
                return writeAppleDoubleFile(allocator, path, data);
            }
            return writeNativeResourceFork(path, data);
        },
        .apple_double => {
            return writeAppleDoubleFile(allocator, path, data);
        },
    }
}

// ============ Tests ============

test "appleDoublePath builds correct path" {
    var buf: [fs.max_path_bytes]u8 = undefined;

    // File in directory
    const path1 = appleDoublePath("/path/to/file.txt", &buf);
    try std.testing.expectEqualStrings("/path/to/._file.txt", path1.?);

    // File in root
    const path2 = appleDoublePath("file.txt", &buf);
    try std.testing.expectEqualStrings("._file.txt", path2.?);
}

test "nativeResourceForkPath builds correct path on macOS" {
    if (comptime builtin.os.tag != .macos) {
        return; // Skip on non-macOS
    }

    var buf: [fs.max_path_bytes]u8 = undefined;
    const path = nativeResourceForkPath("/path/to/file.txt", &buf);
    try std.testing.expectEqualStrings("/path/to/file.txt/..namedfork/rsrc", path.?);
}

test "ResourceForkSource descriptions" {
    try std.testing.expectEqualStrings("none", ResourceForkSource.none.description());
    try std.testing.expectEqualStrings("native resource fork", ResourceForkSource.native_fork.description());
    try std.testing.expectEqualStrings("AppleDouble file", ResourceForkSource.apple_double.description());
}

test "hasProtectableResourceFork returns false for nonexistent files" {
    const result = hasProtectableResourceFork("/nonexistent/path/to/file");
    try std.testing.expect(!result);
}

test "AppleDouble magic constants" {
    try std.testing.expectEqual(@as(u32, 0x00051607), APPLEDOUBLE_MAGIC);
    try std.testing.expectEqual(@as(u32, 0x00051600), APPLESINGLE_MAGIC);
    try std.testing.expectEqual(@as(u32, 0x00020000), APPLEDOUBLE_VERSION);
}

test "writeAppleDoubleFile and readAppleDoubleResourceFork roundtrip" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test file
    const test_file = try tmp.dir.createFile(runtime.io(), "testfile.txt", .{});
    test_file.close(runtime.io());

    // Get absolute path
    const abs_path = try runtime.tmpRealpathAlloc(&tmp, allocator, "testfile.txt");
    defer allocator.free(abs_path);

    // Write resource fork data via AppleDouble
    const test_data = "Hello, Resource Fork!";
    try writeAppleDoubleFile(allocator, abs_path, test_data);

    // Read it back
    var rf_data = (try readAppleDoubleResourceFork(allocator, abs_path)).?;
    defer rf_data.deinit(allocator);

    try std.testing.expectEqualStrings(test_data, rf_data.data);
    try std.testing.expectEqual(ResourceForkSource.apple_double, rf_data.source);
}

test "getResourceForkInfo returns null for nonexistent files" {
    const result = getResourceForkInfo("/nonexistent/path/to/file");
    try std.testing.expect(result == null);
}

test "getResourceForkInfo detects AppleDouble resource fork" {
    const allocator = std.testing.allocator;

    // Create temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a test file
    const test_file = try tmp.dir.createFile(runtime.io(), "testfile.txt", .{});
    test_file.close(runtime.io());

    // Get absolute path
    const abs_path = try runtime.tmpRealpathAlloc(&tmp, allocator, "testfile.txt");
    defer allocator.free(abs_path);

    // Initially no resource fork
    try std.testing.expect(getResourceForkInfo(abs_path) == null);

    // Write resource fork data via AppleDouble
    const test_data = "Hello, Resource Fork!";
    try writeAppleDoubleFile(allocator, abs_path, test_data);

    // Now should detect it
    const info = getResourceForkInfo(abs_path);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(ResourceForkSource.apple_double, info.?.source);
    try std.testing.expectEqual(@as(u64, test_data.len), info.?.size);
}
