const std = @import("std");
const runtime = @import("runtime.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

/// MP4/ISOBMFF box header information.
/// Shared between video_validator.zig and video_audio_validator.zig.
pub const Mp4Box = struct {
    box_type: [4]u8,
    offset: u64,
    size: u64,
    header_size: u8, // 8 for normal, 16 for extended size
};

/// Read MP4 box header at current file position.
/// Returns null if the header is unreadable or the box size is invalid.
pub fn readMp4BoxHeader(file: *FileSource) ?Mp4Box {
    var header: [16]u8 = undefined;
    const bytes_read = file.read(header[0..8]) catch return null;
    if (bytes_read < 8) return null;

    const position = (file.getPos() catch return null) - 8;
    const size = std.mem.readInt(u32, header[0..4], .big);
    const box_type = header[4..8];

    var header_size: u8 = 8;
    var actual_size: u64 = size;

    if (size == 1) {
        // Extended size (64-bit)
        const ext_read = file.read(header[8..16]) catch return null;
        if (ext_read < 8) return null;
        actual_size = std.mem.readInt(u64, header[8..16], .big);
        header_size = 16;
    } else if (size == 0) {
        // Box extends to end of file
        const file_size = file.getEndPos() catch return null;
        actual_size = file_size - position;
    }

    // Reject boxes with size smaller than header (prevents infinite loops on corrupted data)
    if (actual_size < header_size) return null;

    return Mp4Box{
        .box_type = box_type.*,
        .offset = position,
        .size = actual_size,
        .header_size = header_size,
    };
}

/// Find a child box of the given type within a parent box.
/// Seeks through sibling boxes starting at parent_offset.
pub fn findChildBox(file: *FileSource, parent_offset: u64, parent_size: u64, target_type: []const u8) ?Mp4Box {
    const end_offset = parent_offset + parent_size;
    file.seekTo(parent_offset) catch return null;

    while ((file.getPos() catch return null) < end_offset) {
        const box = readMp4BoxHeader(file) orelse return null;
        if (std.mem.eql(u8, &box.box_type, target_type)) {
            return box;
        }
        // Skip to next box
        file.seekTo(box.offset + box.size) catch return null;
    }
    return null;
}

test "readMp4BoxHeader parses standard box" {
    // Create a minimal MP4 box in memory: size=16, type="ftyp", then 8 bytes of data
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x10, // size = 16
        0x66, 0x74, 0x79, 0x70, // "ftyp"
        0x69, 0x73, 0x6F, 0x6D, // "isom" (brand)
        0x00, 0x00, 0x02, 0x00, // version
    };

    // Write to a temp file, then open via FileSource
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const wf = tmp_dir.dir.createFile(runtime.io(), "test.mp4", .{}) catch unreachable;
        wf.writePositionalAll(runtime.io(), &box_data, 0) catch unreachable;
        wf.close(runtime.io());
    }
    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.mp4") catch unreachable;
    defer std.testing.allocator.free(path);
    var source = FileSource.open(path) catch unreachable;
    defer source.close();

    const box = readMp4BoxHeader(&source);
    try std.testing.expect(box != null);
    try std.testing.expectEqualSlices(u8, "ftyp", &box.?.box_type);
    try std.testing.expectEqual(@as(u64, 0), box.?.offset);
    try std.testing.expectEqual(@as(u64, 16), box.?.size);
    try std.testing.expectEqual(@as(u8, 8), box.?.header_size);
}

test "readMp4BoxHeader rejects zero-size extended box" {
    // size=1 triggers extended size read; next 8 bytes are all zeros = invalid
    const box_data = [_]u8{
        0x00, 0x00, 0x00, 0x01, // size = 1 (extended)
        0x6D, 0x76, 0x68, 0x64, // "mvhd"
        0x00, 0x00, 0x00, 0x00, // extended size = 0 (invalid)
        0x00, 0x00, 0x00, 0x00,
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    {
        const wf = tmp_dir.dir.createFile(runtime.io(), "test.mp4", .{}) catch unreachable;
        wf.writePositionalAll(runtime.io(), &box_data, 0) catch unreachable;
        wf.close(runtime.io());
    }
    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.mp4") catch unreachable;
    defer std.testing.allocator.free(path);
    var source = FileSource.open(path) catch unreachable;
    defer source.close();

    const box = readMp4BoxHeader(&source);
    try std.testing.expect(box == null);
}
