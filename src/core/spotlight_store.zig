//! macOS Spotlight `8tsd` store structural validation (pure, no I/O).
//!
//! The `8tsd`-magic store (`store.db`, `.store.db`, and the per-user
//! `index.spotlightV3/store.db`, plus the classic `.Spotlight-V100/Store-V2`
//! stores) is a paged binary database — NOT SQLite, despite the `.db`
//! extension. Layout reverse-engineered publicly by Yogesh Khatri's
//! `spotlight_parser` and verified byte-for-byte against real macOS files
//! (see docs/spotlight-ivf-deadlock-diagnosis-2026-06-05.md):
//!
//!   header (header_size bytes):
//!     0x00 u32  magic "8tsd" (LE 0x64737438)  ["7tsd" = older v1, offsets shift]
//!     0x04 u32  flags
//!     0x24 u32  header_size   (e.g. 4096)
//!     0x28 u32  block0_size
//!     0x2C u32  block_size    (e.g. 16384)
//!     0x144 .. original_path  (256B UTF-8, the file's own path)
//!   block 0 (at offset header_size): map block
//!     0x00 u32  magic "1mbd"/"2mbd"
//!     0x08 u32  item_count    (record-block directory entries)
//!
//! This module raises the previous magic-only check to a real structural walk:
//! header sanity, block-0 map presence, and the block directory landing within
//! the file. It is intentionally conservative — it parses the documented
//! skeleton and flags incoherence, without decoding the compressed record
//! payloads (that is a deeper, separable effort).

const std = @import("std");

pub const MAGIC_V2: u32 = 0x64737438; // "8tsd" little-endian
pub const MAGIC_V1: u32 = 0x64737437; // "7tsd" little-endian (older variant)
pub const MAP_MAGIC_1: u32 = 0x6462_6d31; // "1mbd"
pub const MAP_MAGIC_2: u32 = 0x6462_6d32; // "2mbd"

pub const StoreError = error{
    TooSmall,
    BadMagic,
    BadHeaderSize,
    BadBlockSize,
    BlockZeroOutOfRange,
    BadMapMagic,
    MapOverrunsFile,
};

pub const StoreVersion = enum { v1_7tsd, v2_8tsd };

pub const StoreInfo = struct {
    version: StoreVersion,
    flags: u32,
    header_size: u32,
    block0_size: u32,
    block_size: u32,
    map_item_count: u32,
    /// Whether the original_path field decodes as valid UTF-8 (a cheap
    /// corruption signal — a torn header garbles it).
    original_path_valid_utf8: bool,
};

/// Validate the `8tsd` store header + block-0 map structurally.
///
/// `data` must contain at least the header + block 0 (callers pass a
/// header-region read; for full files the whole buffer is fine). `file_size`
/// is the true on-disk size, used to bound-check the block directory.
pub fn validateHeader(data: []const u8, file_size: u64) StoreError!StoreInfo {
    if (data.len < 0x148) return StoreError.TooSmall;

    const magic = readLeU32(data, 0);
    const version: StoreVersion = switch (magic) {
        MAGIC_V2 => .v2_8tsd,
        MAGIC_V1 => .v1_7tsd,
        else => return StoreError.BadMagic,
    };

    // v1 ("7tsd") shifts the size fields by 4 bytes vs v2.
    const off_header_size: usize = if (version == .v2_8tsd) 0x24 else 0x28;
    const off_block0_size: usize = off_header_size + 4;
    const off_block_size: usize = off_header_size + 8;

    const flags = readLeU32(data, 4);
    const header_size = readLeU32(data, off_header_size);
    const block0_size = readLeU32(data, off_block0_size);
    const block_size = readLeU32(data, off_block_size);

    // Sanity: sizes must be non-zero, power-of-two-ish, and fit the file.
    if (header_size == 0 or header_size > 1 << 20) return StoreError.BadHeaderSize;
    if (block_size == 0 or block_size > 1 << 28) return StoreError.BadBlockSize;
    if (block0_size == 0 or block0_size > 1 << 28) return StoreError.BadBlockSize;
    if (@as(u64, header_size) >= file_size) return StoreError.BadHeaderSize;

    // Block 0 sits at offset == header_size. Need it within our buffer to read
    // its map header; if the buffer is only the header region, require enough.
    const b0_off: usize = @intCast(header_size);
    if (b0_off + 12 > data.len) return StoreError.BlockZeroOutOfRange;
    if (@as(u64, b0_off) + block0_size > file_size) return StoreError.MapOverrunsFile;

    const map_magic = readLeU32(data, b0_off);
    if (map_magic != MAP_MAGIC_1 and map_magic != MAP_MAGIC_2) return StoreError.BadMapMagic;
    const map_item_count = readLeU32(data, b0_off + 8);

    // The record-block directory (map_item_count entries) must plausibly fit:
    // each entry is 16 bytes and they describe blocks that tile the file, so a
    // rough upper bound is item_count*block_size <= file_size (+ slack). A wild
    // count (overruns the file by >1 block) signals a torn header.
    const tiled: u64 = @as(u64, map_item_count) * @as(u64, block_size);
    if (tiled > file_size + block_size) return StoreError.MapOverrunsFile;

    // original_path at 0x144 (same in both variants per observed files): a
    // valid store names its own path here; garbage = torn header.
    var path_valid = false;
    if (data.len >= 0x144 + 1) {
        const path_end = @min(data.len, 0x144 + 256);
        const raw = data[0x144..path_end];
        const nul = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        path_valid = std.unicode.utf8ValidateSlice(raw[0..nul]) and nul > 0;
    }

    return .{
        .version = version,
        .flags = flags,
        .header_size = header_size,
        .block0_size = block0_size,
        .block_size = block_size,
        .map_item_count = map_item_count,
        .original_path_valid_utf8 = path_valid,
    };
}

fn readLeU32(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

// ============================== Tests ==============================

const testing = std.testing;

/// Build a synthetic minimal `8tsd` header + block-0 map for tests, mirroring
/// the real layout (header_size=4096, block_size=16384, 1mbd map).
fn buildStore(buf: []u8, opts: struct {
    magic: u32 = MAGIC_V2,
    header_size: u32 = 4096,
    block0_size: u32 = 16384,
    block_size: u32 = 16384,
    map_magic: u32 = MAP_MAGIC_1,
    item_count: u32 = 1,
    path: []const u8 = "/Users/x/store.db",
}) []u8 {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], opts.magic, .little);
    std.mem.writeInt(u32, buf[4..8], 0x10801, .little); // flags
    std.mem.writeInt(u32, buf[0x24..][0..4], opts.header_size, .little);
    std.mem.writeInt(u32, buf[0x28..][0..4], opts.block0_size, .little);
    std.mem.writeInt(u32, buf[0x2C..][0..4], opts.block_size, .little);
    @memcpy(buf[0x144..][0..opts.path.len], opts.path);
    // block 0 map header at header_size
    const b0 = opts.header_size;
    std.mem.writeInt(u32, buf[b0..][0..4], opts.map_magic, .little);
    std.mem.writeInt(u32, buf[b0 + 4 ..][0..4], opts.block0_size, .little);
    std.mem.writeInt(u32, buf[b0 + 8 ..][0..4], opts.item_count, .little);
    return buf;
}

test "validateHeader: well-formed 8tsd store" {
    var buf: [4096 + 64]u8 = undefined;
    const img = buildStore(&buf, .{ .item_count = 2 });
    const info = try validateHeader(img, 16384 * 2);
    try testing.expectEqual(StoreVersion.v2_8tsd, info.version);
    try testing.expectEqual(@as(u32, 4096), info.header_size);
    try testing.expectEqual(@as(u32, 16384), info.block_size);
    try testing.expectEqual(@as(u32, 2), info.map_item_count);
    try testing.expect(info.original_path_valid_utf8);
}

test "validateHeader: rejects bad magic" {
    var buf: [4096 + 64]u8 = undefined;
    const img = buildStore(&buf, .{ .magic = 0xDEADBEEF });
    try testing.expectError(StoreError.BadMagic, validateHeader(img, 16384));
}

test "validateHeader: rejects too-small buffer" {
    const tiny = [_]u8{0} ** 16;
    try testing.expectError(StoreError.TooSmall, validateHeader(&tiny, 16));
}

test "validateHeader: rejects bad block-0 map magic (torn store)" {
    var buf: [4096 + 64]u8 = undefined;
    const img = buildStore(&buf, .{ .map_magic = 0x12345678 });
    try testing.expectError(StoreError.BadMapMagic, validateHeader(img, 32768));
}

test "validateHeader: rejects header_size >= file_size" {
    var buf: [4096 + 64]u8 = undefined;
    const img = buildStore(&buf, .{});
    // file claims to be smaller than the header
    try testing.expectError(StoreError.BadHeaderSize, validateHeader(img, 100));
}

test "validateHeader: rejects map item_count that overruns the file" {
    var buf: [4096 + 64]u8 = undefined;
    // 1_000_000 blocks * 16384 >> a 1 MiB file
    const img = buildStore(&buf, .{ .item_count = 1_000_000 });
    try testing.expectError(StoreError.MapOverrunsFile, validateHeader(img, 1 << 20));
}

test "validateHeader: 7tsd v1 variant (shifted offsets)" {
    var buf: [4096 + 64]u8 = undefined;
    // v1 puts header_size at 0x28; emulate by writing sizes shifted +4.
    @memset(&buf, 0);
    std.mem.writeInt(u32, buf[0..4], MAGIC_V1, .little);
    std.mem.writeInt(u32, buf[0x28..][0..4], 4096, .little); // header_size (v1 offset)
    std.mem.writeInt(u32, buf[0x2C..][0..4], 16384, .little); // block0_size
    std.mem.writeInt(u32, buf[0x30..][0..4], 16384, .little); // block_size
    @memcpy(buf[0x144..][0..5], "/a/b/");
    std.mem.writeInt(u32, buf[4096..][0..4], MAP_MAGIC_1, .little);
    std.mem.writeInt(u32, buf[4096 + 8 ..][0..4], @as(u32, 1), .little);
    const info = try validateHeader(&buf, 32768);
    try testing.expectEqual(StoreVersion.v1_7tsd, info.version);
    try testing.expectEqual(@as(u32, 4096), info.header_size);
}
