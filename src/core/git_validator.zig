//! Git Repository Validator
//!
//! Pure Zig implementation of git repository integrity validation.
//! Validates all SHA-1 checksums without shelling out to git.
//!
//! Git object store integrity:
//! - Loose objects: SHA-1(decompress(file)) == filename
//! - Pack files: SHA-1 trailer covers entire pack
//! - Pack index: SHA-1 of pack contents + SHA-1 of index
//! - Index file (.git/index): SHA-1 trailer
//!
//! This catches bitrot, transmission errors, and filesystem corruption
//! that would otherwise go undetected until git tries to read the object.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

/// Result of git repository validation
pub const GitValidationResult = struct {
    is_valid: bool,
    /// Total objects checked (loose + packed)
    objects_checked: u32,
    /// Objects that passed SHA-1 verification
    objects_valid: u32,
    /// Objects that failed SHA-1 verification
    objects_corrupt: u32,
    /// Pack files validated
    packs_checked: u32,
    /// Pack files with valid checksums
    packs_valid: u32,
    /// Error message if validation failed
    error_message: ?[]const u8,

    pub fn ok(checked: u32, valid: u32, packs: u32) GitValidationResult {
        return .{
            .is_valid = true,
            .objects_checked = checked,
            .objects_valid = valid,
            .objects_corrupt = 0,
            .packs_checked = packs,
            .packs_valid = packs,
            .error_message = null,
        };
    }

    pub fn corrupt(checked: u32, valid: u32, corrupt_count: u32, msg: []const u8) GitValidationResult {
        return .{
            .is_valid = false,
            .objects_checked = checked,
            .objects_valid = valid,
            .objects_corrupt = corrupt_count,
            .packs_checked = 0,
            .packs_valid = 0,
            .error_message = msg,
        };
    }

    pub fn invalid(msg: []const u8) GitValidationResult {
        return .{
            .is_valid = false,
            .objects_checked = 0,
            .objects_valid = 0,
            .objects_corrupt = 0,
            .packs_checked = 0,
            .packs_valid = 0,
            .error_message = msg,
        };
    }
};

/// Git object types
pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    // Pack-specific delta types
    ofs_delta = 6,
    ref_delta = 7,

    pub fn fromString(s: []const u8) ?ObjectType {
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }
};

/// Validate a loose git object file.
/// Returns true if SHA-1 of decompressed content matches the expected hash.
pub fn validateLooseObject(allocator: Allocator, object_path: []const u8, expected_hash: *const [40]u8) !bool {
    const file = std.fs.cwd().openFile(object_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) return false;
    if (file_size > 100 * 1024 * 1024) return error.ObjectTooLarge; // 100MB limit for loose objects

    // Read compressed data
    const compressed = try allocator.alloc(u8, file_size);
    defer allocator.free(compressed);
    const bytes_read = try file.readAll(compressed);
    if (bytes_read != file_size) return false;

    // Decompress using zlib
    const decompressed = try decompressZlib(allocator, compressed);
    defer allocator.free(decompressed);

    // Compute SHA-1 of decompressed content
    var hash: [20]u8 = undefined;
    Sha1.hash(decompressed, &hash, .{});

    // Convert to hex and compare
    var hex: [40]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return std.mem.eql(u8, &hex, expected_hash);
}

/// Decompress zlib-compressed data (git uses zlib, not gzip)
fn decompressZlib(allocator: Allocator, compressed: []const u8) ![]u8 {
    // Use bundled zlib for decompression
    // Max 100MB output (same as loose object limit)
    const zlib = @import("zlib.zig");
    return zlib.inflateZlibAlloc(allocator, compressed, 100 * 1024 * 1024) catch |err| {
        return err;
    };
}

/// Extract expected hash from loose object path.
/// Path format: .git/objects/xx/yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
/// Returns the 40-char hex hash (xx + yy...)
pub fn hashFromLooseObjectPath(path: []const u8) ?[40]u8 {
    // Find "objects/" in path and extract xx/yyyy...
    const objects_marker = "objects/";
    const idx = std.mem.indexOf(u8, path, objects_marker) orelse return null;
    const after_objects = path[idx + objects_marker.len ..];

    // Need at least "xx/yyyy..." (2 + 1 + 38 = 41 chars)
    if (after_objects.len < 41) return null;
    if (after_objects[2] != '/') return null;

    var hash: [40]u8 = undefined;
    hash[0] = after_objects[0];
    hash[1] = after_objects[1];
    @memcpy(hash[2..40], after_objects[3..41]);

    // Validate all chars are hex
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    return hash;
}

/// Validate a git pack file's SHA-1 checksum.
/// Pack format: PACK + version(4) + count(4) + objects... + SHA-1(20)
/// The trailing SHA-1 covers everything before it.
pub fn validatePackFile(allocator: Allocator, pack_path: []const u8) !bool {
    _ = allocator;

    const file = try std.fs.cwd().openFile(pack_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < 32) return false; // Minimum: header(12) + SHA-1(20)

    // Read and verify header
    var header: [12]u8 = undefined;
    _ = try file.read(&header);

    if (!std.mem.eql(u8, header[0..4], "PACK")) return false;

    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version < 2 or version > 3) return false;

    // Read stored SHA-1 from end
    try file.seekTo(file_size - 20);
    var stored_hash: [20]u8 = undefined;
    _ = try file.read(&stored_hash);

    // Compute SHA-1 of everything except the trailing hash
    try file.seekTo(0);
    var hasher = Sha1.init(.{});

    const content_size = file_size - 20;
    var buffer: [8192]u8 = undefined;
    var bytes_remaining = content_size;

    while (bytes_remaining > 0) {
        const to_read = @min(buffer.len, bytes_remaining);
        const bytes_read = try file.read(buffer[0..to_read]);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
        bytes_remaining -= bytes_read;
    }

    var computed_hash: [20]u8 = undefined;
    hasher.final(&computed_hash);

    return std.mem.eql(u8, &computed_hash, &stored_hash);
}

/// Validate a git pack index file (.idx).
/// Version 2 format:
/// - Magic: 0xff744f63 ("\377tOc")
/// - Version: 4 bytes (2)
/// - Fan-out table: 256 * 4 bytes
/// - SHA-1 table: N * 20 bytes
/// - CRC32 table: N * 4 bytes
/// - Offset table: N * 4 bytes
/// - (optional) Large offset table
/// - Pack SHA-1: 20 bytes
/// - Index SHA-1: 20 bytes (covers everything before it)
pub fn validatePackIndex(allocator: Allocator, idx_path: []const u8, pack_hash: ?*const [20]u8) !bool {
    _ = allocator;

    const file = try std.fs.cwd().openFile(idx_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < 8 + 256 * 4 + 40) return false; // Minimum size

    // Check for v2 magic
    var header: [8]u8 = undefined;
    _ = try file.read(&header);

    const is_v2 = std.mem.eql(u8, header[0..4], "\xff\x74\x4f\x63");
    if (!is_v2) {
        // v1 format - less common, skip for now
        return false;
    }

    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version != 2) return false;

    // Read stored SHA-1s from end (pack hash + index hash)
    try file.seekTo(file_size - 40);
    var stored_pack_hash: [20]u8 = undefined;
    var stored_index_hash: [20]u8 = undefined;
    _ = try file.read(&stored_pack_hash);
    _ = try file.read(&stored_index_hash);

    // Verify pack hash matches if provided
    if (pack_hash) |ph| {
        if (!std.mem.eql(u8, &stored_pack_hash, ph)) return false;
    }

    // Compute SHA-1 of everything except the trailing index hash
    try file.seekTo(0);
    var hasher = Sha1.init(.{});

    const content_size = file_size - 20;
    var buffer: [8192]u8 = undefined;
    var bytes_remaining = content_size;

    while (bytes_remaining > 0) {
        const to_read = @min(buffer.len, bytes_remaining);
        const bytes_read = try file.read(buffer[0..to_read]);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
        bytes_remaining -= bytes_read;
    }

    var computed_hash: [20]u8 = undefined;
    hasher.final(&computed_hash);

    return std.mem.eql(u8, &computed_hash, &stored_index_hash);
}

/// Validate a .git/index file.
/// Format: "DIRC" + version(4) + entry_count(4) + entries... + extensions... + SHA-1(20)
pub fn validateIndexFile(allocator: Allocator, index_path: []const u8) !bool {
    _ = allocator;

    const file = std.fs.cwd().openFile(index_path, .{}) catch |err| {
        if (err == error.FileNotFound) return true; // No index is valid (empty repo)
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size < 12 + 20) return false; // Header + SHA-1

    // Verify header
    var header: [12]u8 = undefined;
    _ = try file.read(&header);

    if (!std.mem.eql(u8, header[0..4], "DIRC")) return false;

    const version = std.mem.readInt(u32, header[4..8], .big);
    if (version < 2 or version > 4) return false;

    // Read stored SHA-1 from end
    try file.seekTo(file_size - 20);
    var stored_hash: [20]u8 = undefined;
    _ = try file.read(&stored_hash);

    // Compute SHA-1 of everything except the trailing hash
    try file.seekTo(0);
    var hasher = Sha1.init(.{});

    const content_size = file_size - 20;
    var buffer: [8192]u8 = undefined;
    var bytes_remaining = content_size;

    while (bytes_remaining > 0) {
        const to_read = @min(buffer.len, bytes_remaining);
        const bytes_read = try file.read(buffer[0..to_read]);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
        bytes_remaining -= bytes_read;
    }

    var computed_hash: [20]u8 = undefined;
    hasher.final(&computed_hash);

    return std.mem.eql(u8, &computed_hash, &stored_hash);
}

/// Validate an entire git repository.
/// Checks all loose objects, pack files, and the index.
pub fn validateRepository(allocator: Allocator, repo_path: []const u8) !GitValidationResult {
    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = try std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{repo_path});

    // Check .git directory exists
    std.fs.cwd().access(git_dir, .{}) catch {
        return GitValidationResult.invalid("Not a git repository (no .git directory)");
    };

    var objects_checked: u32 = 0;
    var objects_valid: u32 = 0;
    var objects_corrupt: u32 = 0;
    var packs_checked: u32 = 0;
    var packs_valid: u32 = 0;

    // Validate loose objects
    var objects_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const objects_dir = try std.fmt.bufPrint(&objects_dir_buf, "{s}/objects", .{git_dir});

    var dir = std.fs.cwd().openDir(objects_dir, .{ .iterate = true }) catch {
        return GitValidationResult.invalid("Cannot open .git/objects");
    };
    defer dir.close();

    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        if (std.mem.eql(u8, entry.name, "pack") or std.mem.eql(u8, entry.name, "info")) continue;

        // This is a loose object directory (e.g., "ab")
        var subdir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const subdir_path = try std.fmt.bufPrint(&subdir_buf, "{s}/{s}", .{ objects_dir, entry.name });

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var subdir_iter = subdir.iterate();
        while (try subdir_iter.next()) |obj_entry| {
            if (obj_entry.kind != .file) continue;
            if (obj_entry.name.len != 38) continue; // SHA-1 remainder

            var obj_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const obj_path = try std.fmt.bufPrint(&obj_path_buf, "{s}/{s}", .{ subdir_path, obj_entry.name });

            // Construct expected hash
            var expected_hash: [40]u8 = undefined;
            expected_hash[0] = entry.name[0];
            expected_hash[1] = entry.name[1];
            @memcpy(expected_hash[2..40], obj_entry.name[0..38]);

            objects_checked += 1;

            const valid = validateLooseObject(allocator, obj_path, &expected_hash) catch false;
            if (valid) {
                objects_valid += 1;
            } else {
                objects_corrupt += 1;
            }
        }
    }

    // Validate pack files
    var pack_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pack_dir = try std.fmt.bufPrint(&pack_dir_buf, "{s}/objects/pack", .{git_dir});

    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pack_dir_handle_const| {
        var pack_dir_handle = pack_dir_handle_const;
        defer pack_dir_handle.close();

        var pack_iter = pack_dir_handle.iterate();
        while (try pack_iter.next()) |pack_entry| {
            if (pack_entry.kind != .file) continue;

            if (std.mem.endsWith(u8, pack_entry.name, ".pack")) {
                var pack_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const pack_path = try std.fmt.bufPrint(&pack_path_buf, "{s}/{s}", .{ pack_dir, pack_entry.name });

                packs_checked += 1;

                const valid = validatePackFile(allocator, pack_path) catch false;
                if (valid) {
                    packs_valid += 1;
                    objects_checked += 1; // Count pack as one unit
                    objects_valid += 1;
                } else {
                    objects_corrupt += 1;
                }

                // Also validate corresponding .idx if exists
                var idx_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const idx_name_len = pack_entry.name.len - 5; // Remove ".pack"
                const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/{s}.idx", .{ pack_dir, pack_entry.name[0..idx_name_len] });

                if (validatePackIndex(allocator, idx_path, null)) |idx_valid| {
                    if (!idx_valid) {
                        objects_corrupt += 1;
                    }
                } else |_| {}
            }
        }
    } else |_| {
        // No pack directory is fine
    }

    // Validate index file
    var index_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&index_path_buf, "{s}/index", .{git_dir});

    if (validateIndexFile(allocator, index_path)) |index_valid| {
        if (!index_valid) {
            return GitValidationResult.corrupt(objects_checked, objects_valid, objects_corrupt + 1, "Index file checksum mismatch");
        }
    } else |_| {
        // Index file error
    }

    if (objects_corrupt > 0) {
        return GitValidationResult.corrupt(objects_checked, objects_valid, objects_corrupt, "Corrupt objects detected");
    }

    return GitValidationResult.ok(objects_checked, objects_valid, packs_checked);
}

// ============ Tests ============

test "hashFromLooseObjectPath extracts hash correctly" {
    const path = "/repo/.git/objects/ab/cdef1234567890abcdef1234567890abcdef12";
    const hash = hashFromLooseObjectPath(path);
    try std.testing.expect(hash != null);
    try std.testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", &hash.?);
}

test "hashFromLooseObjectPath rejects invalid paths" {
    try std.testing.expect(hashFromLooseObjectPath("/repo/.git/objects/pack/something") == null);
    try std.testing.expect(hashFromLooseObjectPath("/repo/.git/objects/ab") == null);
    try std.testing.expect(hashFromLooseObjectPath("/repo/.git/objects/ab/short") == null);
}

test "ObjectType.fromString parses types" {
    try std.testing.expect(ObjectType.fromString("commit") == .commit);
    try std.testing.expect(ObjectType.fromString("tree") == .tree);
    try std.testing.expect(ObjectType.fromString("blob") == .blob);
    try std.testing.expect(ObjectType.fromString("tag") == .tag);
    try std.testing.expect(ObjectType.fromString("invalid") == null);
}
