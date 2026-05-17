/// FileSource provides uniform file read access backed by either mmap or
/// traditional file I/O. On POSIX systems, files are memory-mapped for
/// zero-syscall random access; on Windows or when mmap fails, falls back
/// to regular file I/O. This dramatically improves performance on network
/// mounts (NAS/SMB/NFS) where each seekTo+read is a network round-trip.
const std = @import("std");
const heap = @import("heap.zig");
const runtime = @import("runtime.zig");

/// 0.16: std.Io.Dir methods take `io` as their first parameter. This shim
/// lets us preserve the original `std.fs.cwd().openFile(path, .{})`-style
/// call shape without forking every caller's signature.
fn openCwdFile(path: []const u8, opts: std.Io.File.OpenOptions) std.Io.File.OpenError!std.Io.File {
    runtime.ensureInit();
    return std.Io.Dir.cwd().openFile(runtime.io(), path, opts);
}

pub const FileSource = struct {
    /// The backing storage — either mmap'd memory or a file handle
    backing: Backing,
    /// Current read position (for mmap mode)
    pos: usize = 0,
    /// Total file size
    file_size: u64,

    const Backing = union(enum) {
        mapped: MappedData,
        file: std.Io.File,
        /// Borrowed in-memory buffer (caller owns the data). close() is a no-op.
        buffer: []const u8,
    };

    const MappedData = struct {
        data: []align(std.heap.page_size_min) const u8,
    };

    /// Open a file. On Windows, transparently retries with the `\\?\` long-
    /// path prefix when the first attempt fails — this bypasses the Win32
    /// path-parsing layer that rejects characters NTFS itself allows (`|`,
    /// `<`, `>`, `"`, trailing dots/spaces) and also the legacy MAX_PATH
    /// limit. Real-world case: files named like
    /// `AI Is the Bubble to Burst Them All | WIRED.md` on Peter's
    /// Documents folder get rejected by plain CreateFileW but open fine
    /// through `\\?\C:\Users\...\AI Is...WIRED.md`.
    fn openFileTolerant(path: []const u8) !std.Io.File {
        const first_err = blk: {
            const f = openCwdFile(path, .{}) catch |err| break :blk err;
            return f;
        };

        if (comptime @import("builtin").os.tag != .windows) return first_err;

        // Already prefixed? Don't loop on retry.
        if (path.len >= 4 and std.mem.eql(u8, path[0..4], "\\\\?\\")) return first_err;

        var arena = std.heap.ArenaAllocator.init(heap.validateAllocator());
        defer arena.deinit();
        const alloc = arena.allocator();

        // Build an absolute Windows path. \\?\ paths MUST be absolute and
        // MUST use backslash separators — the prefix disables normalization.
        const abs_path = if (std.fs.path.isAbsolute(path))
            alloc.dupe(u8, path) catch return first_err
        else blk: {
            const cwd = std.process.getCwdAlloc(alloc) catch return first_err;
            break :blk std.fs.path.join(alloc, &.{ cwd, path }) catch return first_err;
        };
        for (abs_path) |*c| if (c.* == '/') { c.* = '\\'; };

        const prefixed = std.fmt.allocPrint(alloc, "\\\\?\\{s}", .{abs_path}) catch return first_err;
        return openCwdFile(prefixed, .{}) catch return first_err;
    }

    /// Open a file, preferring mmap on POSIX systems.
    /// Falls back to regular file I/O if mmap fails.
    pub fn open(path: []const u8) !FileSource {
        const file = try openFileTolerant(path);
        errdefer file.close();

        const file_size = try file.getEndPos();

        // Don't mmap empty files or files > 8GB (virtual address space caution)
        if (file_size == 0 or file_size > 8 * 1024 * 1024 * 1024) {
            return .{
                .backing = .{ .file = file },
                .file_size = file_size,
            };
        }

        // Try mmap on POSIX systems
        if (comptime @import("builtin").os.tag != .windows) {
            const mapped = std.posix.mmap(
                null,
                @intCast(file_size),
                std.posix.PROT.READ,
                .{ .TYPE = .SHARED },
                file.handle,
                0,
            ) catch {
                // mmap failed — fall back to file I/O
                return .{
                    .backing = .{ .file = file },
                    .file_size = file_size,
                };
            };

            // Advise the kernel that we'll access randomly
            std.posix.madvise(@constCast(mapped.ptr), mapped.len, std.posix.MADV.RANDOM) catch {};

            // Close the file handle — the mapping keeps the file alive
            file.close();

            return .{
                .backing = .{ .mapped = .{ .data = mapped } },
                .file_size = file_size,
            };
        }

        // Windows: fall back to file I/O (TODO: CreateFileMapping)
        return .{
            .backing = .{ .file = file },
            .file_size = file_size,
        };
    }

    /// Wrap an existing std.Io.File into a FileSource (file-backed, no mmap).
    /// The caller retains ownership of the underlying file handle.
    /// Do NOT call close() on this FileSource — it does not own the handle.
    pub fn fromFile(file: std.Io.File) FileSource {
        const file_size = file.getEndPos() catch 0;
        return .{
            .backing = .{ .file = file },
            .file_size = file_size,
        };
    }

    /// Wrap an existing in-memory buffer as a FileSource. Zero-copy — the caller
    /// retains ownership of the buffer which must outlive this FileSource.
    /// close() is a no-op for buffer-backed sources. Enables testing validators
    /// against in-memory data (e.g. sniper/shotgun corruption testing).
    pub fn fromBuffer(data: []const u8) FileSource {
        return .{
            .backing = .{ .buffer = data },
            .file_size = data.len,
        };
    }
    /// Close the file source and release resources.
    pub fn close(self: *FileSource) void {
        switch (self.backing) {
            .mapped => |m| {
                if (comptime @import("builtin").os.tag != .windows) {
                    const ptr: [*]align(std.heap.page_size_min) u8 = @constCast(m.data.ptr);
                    std.posix.munmap(ptr[0..m.data.len]);
                }
            },
            .file => |f| f.close(),
            .buffer => {}, // no-op, caller owns the buffer
        }
    }

    /// Seek relative to current position.
    pub fn seekBy(self: *FileSource, offset: i64) !void {
        const current = try self.getPos();
        const new_pos = if (offset >= 0)
            current +| @as(u64, @intCast(offset))
        else
            current -| @as(u64, @intCast(-offset));
        try self.seekTo(new_pos);
    }

    /// Seek to an absolute position.
    pub fn seekTo(self: *FileSource, pos: u64) !void {
        switch (self.backing) {
            .mapped, .buffer => {
                if (pos > self.file_size) return error.Unseekable;
                self.pos = @intCast(pos);
            },
            .file => |f| try f.seekTo(pos),
        }
    }

    /// Read into a buffer, returning the number of bytes read.
    pub fn read(self: *FileSource, dest: []u8) !usize {
        switch (self.backing) {
            .mapped => |m| {
                if (self.pos >= m.data.len) return 0;
                const available = m.data.len - self.pos;
                const to_read = @min(dest.len, available);
                @memcpy(dest[0..to_read], m.data[self.pos..][0..to_read]);
                self.pos += to_read;
                return to_read;
            },
            .buffer => |b| {
                if (self.pos >= b.len) return 0;
                const available = b.len - self.pos;
                const to_read = @min(dest.len, available);
                @memcpy(dest[0..to_read], b[self.pos..][0..to_read]);
                self.pos += to_read;
                return to_read;
            },
            .file => |f| return f.read(dest),
        }
    }

    /// Read exactly `dest.len` bytes, returning the count actually read.
    pub fn readAll(self: *FileSource, dest: []u8) !usize {
        switch (self.backing) {
            .mapped => |m| {
                if (self.pos >= m.data.len) return 0;
                const available = m.data.len - self.pos;
                const to_read = @min(dest.len, available);
                @memcpy(dest[0..to_read], m.data[self.pos..][0..to_read]);
                self.pos += to_read;
                return to_read;
            },
            .buffer => |b| {
                if (self.pos >= b.len) return 0;
                const available = b.len - self.pos;
                const to_read = @min(dest.len, available);
                @memcpy(dest[0..to_read], b[self.pos..][0..to_read]);
                self.pos += to_read;
                return to_read;
            },
            .file => |f| return f.readAll(dest),
        }
    }

    /// Get current position.
    pub fn getPos(self: *FileSource) !u64 {
        switch (self.backing) {
            .mapped, .buffer => return @intCast(self.pos),
            .file => |f| return f.getPos(),
        }
    }

    /// Get file size (end position).
    pub fn getEndPos(self: *FileSource) !u64 {
        return self.file_size;
    }

    /// Check if this source supports zero-copy in-memory access (mmap or buffer).
    pub fn isMapped(self: *const FileSource) bool {
        return switch (self.backing) {
            .mapped, .buffer => true,
            .file => false,
        };
    }

    /// Get zero-copy access to the entire file content if in-memory.
    /// Returns null for file-backed sources (use read() instead).
    /// The returned slice is valid for the lifetime of the FileSource.
    pub fn getMappedSlice(self: *const FileSource) ?[]const u8 {
        return switch (self.backing) {
            .mapped => |m| m.data,
            .buffer => |b| b,
            .file => null,
        };
    }

    /// Get zero-copy access to a range of the file content if in-memory.
    /// Returns null for file-backed sources or if range is out of bounds.
    pub fn getMappedRange(self: *const FileSource, offset: u64, len: u64) ?[]const u8 {
        const full = self.getMappedSlice() orelse return null;
        const start: usize = @intCast(@min(offset, full.len));
        const end: usize = @intCast(@min(offset + len, full.len));
        if (start >= end) return null;
        return full[start..end];
    }

    /// Result type for `getMappedOrSlurp`.
    pub const SlurpResult = union(enum) {
        /// Zero-copy mmap'd slice; do NOT free.
        mapped: []const u8,
        /// Heap buffer allocated for this call; caller MUST free with `allocator.free(.heap)`.
        heap: []u8,
        /// File too large for the bounded fallback; caller should downgrade to structural-only.
        too_large: u64,
    };

    /// Get the file content as a flat byte slice, preferring zero-copy mmap.
    ///
    /// Resolution order:
    ///   1. If the source is mmap'd or in-memory → return `.mapped` (zero-copy).
    ///   2. If file size <= `max_slurp_bytes` → allocate, read fully → return `.heap`.
    ///   3. Otherwise → return `.too_large` so the caller can downgrade gracefully
    ///      (typically: structural-only result with a "too large for non-mmap" note).
    ///
    /// This codifies the mmap-or-bounded-slurp pattern that was previously open-coded
    /// across ~10 validators. The `max_slurp_bytes` parameter is the hard ceiling on
    /// heap usage when we can't mmap (Windows, network mounts, very large files where
    /// mmap range is exhausted). Use a *small* value (e.g. 64 MB); the goal is to
    /// bound non-mmap RSS, not to handle the rare large-file-without-mmap case
    /// efficiently.
    pub fn getMappedOrSlurp(self: *FileSource, allocator: std.mem.Allocator, max_slurp_bytes: u64) !SlurpResult {
        if (self.getMappedSlice()) |m| return .{ .mapped = m };
        const file_size = try self.getEndPos();
        if (file_size > max_slurp_bytes) return .{ .too_large = file_size };
        const buf = try allocator.alloc(u8, @intCast(file_size));
        errdefer allocator.free(buf);
        try self.seekTo(0);
        const n = try self.readAll(buf);
        return .{ .heap = buf[0..n] };
    }


    /// Error type for FileSource reader — covers all backing variants.
    pub const ReaderError = std.Io.File.ReadError || error{Unseekable};

    /// Generic reader adapter — allows FileSource to be passed to APIs expecting
    /// a std.io.GenericReader (e.g. std.compress.xz.decompress).
    pub const Reader = std.io.GenericReader(*FileSource, ReaderError, readForReader);

    fn readForReader(self: *FileSource, buf: []u8) ReaderError!usize {
        return self.read(buf) catch |err| switch (err) {
            else => error.Unexpected,
        };
    }

    /// Wrap this FileSource as a std.io.GenericReader for compat with
    /// std.compress.xz.decompress and similar APIs.
    pub fn reader(self: *FileSource) Reader {
        return .{ .context = self };
    }
};

// ============ Tests ============

test "FileSource mmap read and seek" {
    // Create a temp file with known content
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "Hello, mmap world! This is a test of the file source abstraction.";
    tmp.dir.writeFile(.{ .sub_path = "test.bin", .data = content }) catch return;

    // Get absolute path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("test.bin", &path_buf) catch return;

    var source = FileSource.open(path) catch return;
    defer source.close();

    try std.testing.expectEqual(@as(u64, content.len), source.file_size);

    // Read first 5 bytes
    var buf: [5]u8 = undefined;
    const n = try source.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("Hello", &buf);

    // Seek and read
    try source.seekTo(7);
    const n2 = try source.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n2);
    try std.testing.expectEqualStrings("mmap ", &buf);

    // getPos
    const pos = try source.getPos();
    try std.testing.expectEqual(@as(u64, 12), pos);

    // getEndPos
    const end = try source.getEndPos();
    try std.testing.expectEqual(@as(u64, content.len), end);
}

test "FileSource read past end returns partial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(.{ .sub_path = "small.bin", .data = "abc" }) catch return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("small.bin", &path_buf) catch return;

    var source = FileSource.open(path) catch return;
    defer source.close();

    try source.seekTo(1);
    var buf: [10]u8 = undefined;
    const n = try source.read(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("bc", buf[0..2]);
}

test "FileSource seek past end returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(.{ .sub_path = "tiny.bin", .data = "x" }) catch return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("tiny.bin", &path_buf) catch return;

    var source = FileSource.open(path) catch return;
    defer source.close();

    // Seeking to exact end is OK
    try source.seekTo(1);
    // Seeking past end is error
    try std.testing.expectError(error.Unseekable, source.seekTo(100));
}

test "getMappedSlice returns full file content for mmap'd file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "Hello, zero-copy world!";
    tmp.dir.writeFile(.{ .sub_path = "mapped.bin", .data = content }) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("mapped.bin", &path_buf) catch return;
    var source = FileSource.open(path) catch return;
    defer source.close();
    if (source.getMappedSlice()) |slice| {
        try std.testing.expectEqualStrings(content, slice);
    }
    // On Windows or fallback, getMappedSlice returns null — that's OK
}

test "getMappedRange returns bounded slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "ABCDEFGHIJ";
    tmp.dir.writeFile(.{ .sub_path = "range.bin", .data = content }) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("range.bin", &path_buf) catch return;
    var source = FileSource.open(path) catch return;
    defer source.close();
    if (source.getMappedRange(3, 4)) |slice| {
        try std.testing.expectEqualStrings("DEFG", slice);
    }
}

test "fromBuffer wraps in-memory data with zero copy" {
    const content = "In-memory bytes, no file at all";
    var source = FileSource.fromBuffer(content);
    defer source.close(); // no-op for buffer

    try std.testing.expectEqual(@as(u64, content.len), source.file_size);
    try std.testing.expect(source.isMapped());

    // Zero-copy access returns the same pointer
    const slice = source.getMappedSlice().?;
    try std.testing.expectEqual(content.ptr, slice.ptr);
    try std.testing.expectEqualStrings(content, slice);

    // Read/seek work
    var buf: [8]u8 = undefined;
    try source.seekTo(3);
    const n = try source.read(&buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("memory b", &buf);

    // Ranged access
    const range = source.getMappedRange(3, 6).?;
    try std.testing.expectEqualStrings("memory", range);
}

test "getMappedOrSlurp returns mapped for in-memory source" {
    const content = "abcdef";
    var source = FileSource.fromBuffer(content);
    defer source.close();
    const result = try source.getMappedOrSlurp(std.testing.allocator, 1024);
    try std.testing.expect(result == .mapped);
    try std.testing.expectEqualStrings(content, result.mapped);
}

test "getMappedOrSlurp returns too_large when ceiling exceeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "0123456789" ** 200; // 2000 bytes
    tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = content }) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("big.bin", &path_buf) catch return;
    var source = FileSource.open(path) catch return;
    defer source.close();
    if (source.isMapped()) return error.SkipZigTest; // mmap path doesn't exercise the slurp branch

    const result = try source.getMappedOrSlurp(std.testing.allocator, 1024); // ceiling < file size
    switch (result) {
        .too_large => |sz| try std.testing.expectEqual(@as(u64, content.len), sz),
        .heap => |buf| {
            std.testing.allocator.free(buf);
            try std.testing.expect(false); // we expected too_large
        },
        .mapped => try std.testing.expect(false),
    }
}

test "getMappedOrSlurp returns heap when below ceiling and not mapped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "small file content";
    tmp.dir.writeFile(.{ .sub_path = "small.bin", .data = content }) catch return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = tmp.dir.realpath("small.bin", &path_buf) catch return;
    var source = FileSource.open(path) catch return;
    defer source.close();
    // mmap path is the common case here, but it's still a valid result.
    const result = try source.getMappedOrSlurp(std.testing.allocator, 1024);
    switch (result) {
        .mapped => |m| try std.testing.expectEqualStrings(content, m),
        .heap => |buf| {
            defer std.testing.allocator.free(buf);
            try std.testing.expectEqualStrings(content, buf);
        },
        .too_large => try std.testing.expect(false),
    }
}
