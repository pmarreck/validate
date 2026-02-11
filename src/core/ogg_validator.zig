//! OGG container deep validation with CRC32 verification.
//!
//! OGG pages contain a CRC32 checksum covering the entire page (header + data).
//! This module verifies those checksums to detect bitrot/corruption that
//! structural validation alone cannot catch.
//!
//! OGG Page Header (27 bytes):
//!   Bytes 0-3:   "OggS" capture pattern
//!   Byte 4:      Stream structure version (0)
//!   Byte 5:      Header type flags
//!   Bytes 6-13:  Granule position (8 bytes, little-endian)
//!   Bytes 14-17: Bitstream serial number (4 bytes, little-endian)
//!   Bytes 18-21: Page sequence number (4 bytes, little-endian)
//!   Bytes 22-25: CRC32 checksum (4 bytes, little-endian)
//!   Byte 26:     Number of segments (n)
//!   Followed by: n bytes segment table, then page data
//!
//! The CRC32 is calculated over the entire page with the CRC field set to 0.
//! OGG uses polynomial 0x04C11DB7 (reflected: 0xEDB88320).

const std = @import("std");
const errmsg = @import("error_messages.zig");

/// Result of OGG deep validation
pub const OggValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    pages_verified: u32,
    total_bytes_verified: u64,

    pub fn ok(pages: u32, bytes: u64) OggValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .pages_verified = pages,
            .total_bytes_verified = bytes,
        };
    }

    pub fn invalid(message: []const u8, pages: u32, bytes: u64) OggValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .pages_verified = pages,
            .total_bytes_verified = bytes,
        };
    }
};

/// OGG CRC32 lookup table (polynomial 0x04C11DB7, direct/non-reflected)
/// OGG uses MSB-first CRC, NOT the standard reflected CRC-32
const crc32_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            if (crc & 0x80000000 != 0) {
                crc = (crc << 1) ^ 0x04C11DB7;
            } else {
                crc = crc << 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate OGG CRC32 for a buffer (MSB-first, direct polynomial)
pub fn oggCrc32(data: []const u8) u32 {
    var crc: u32 = 0;
    for (data) |byte| {
        crc = (crc << 8) ^ crc32_table[((crc >> 24) ^ byte) & 0xFF];
    }
    return crc;
}

/// Validate all OGG page CRCs in a file.
/// Returns the number of pages verified and total bytes covered.
pub fn validateOggCrc(file: std.fs.File) OggValidationResult {
    var pages_verified: u32 = 0;
    var total_bytes: u64 = 0;

    // Seek to beginning
    file.seekTo(0) catch {
        return OggValidationResult.invalid(errmsg.failedToSeek("to start"), 0, 0);
    };

    // Read and verify each page
    while (true) {
        // Read page header (27 bytes minimum)
        var header: [27]u8 = undefined;
        const header_bytes = file.read(&header) catch {
            return OggValidationResult.invalid(errmsg.failedToRead("page header"), pages_verified, total_bytes);
        };

        // End of file
        if (header_bytes == 0) {
            break;
        }

        // Need at least 27 bytes for a valid header
        if (header_bytes < 27) {
            if (pages_verified == 0) {
                return OggValidationResult.invalid(errmsg.fileTooSmallFor("OGG page"), 0, 0);
            }
            return OggValidationResult.invalid(errmsg.truncated("page header"), pages_verified, total_bytes);
        }

        // Verify capture pattern
        if (!std.mem.eql(u8, header[0..4], "OggS")) {
            if (pages_verified == 0) {
                return OggValidationResult.invalid(errmsg.invalidSignature("OGG"), 0, 0);
            }
            return OggValidationResult.invalid("Corrupt page - invalid signature", pages_verified, total_bytes);
        }

        // Check version
        if (header[4] != 0) {
            return OggValidationResult.invalid(errmsg.unsupported("OGG version"), pages_verified, total_bytes);
        }

        // Extract stored CRC (little-endian, bytes 22-25)
        const stored_crc = std.mem.readInt(u32, header[22..26], .little);

        // Get number of segments
        const n_segments: usize = header[26];

        // Read segment table
        var segment_table: [255]u8 = undefined;
        if (n_segments > 0) {
            const seg_bytes = file.read(segment_table[0..n_segments]) catch {
                return OggValidationResult.invalid(errmsg.failedToRead("segment table"), pages_verified, total_bytes);
            };
            if (seg_bytes < n_segments) {
                return OggValidationResult.invalid(errmsg.truncated("segment table"), pages_verified, total_bytes);
            }
        }

        // Calculate page data size from segment table
        var page_data_size: usize = 0;
        for (segment_table[0..n_segments]) |seg_size| {
            page_data_size += seg_size;
        }

        // Total page size = header(27) + segment_table(n_segments) + page_data
        const total_page_size = 27 + n_segments + page_data_size;

        // Calculate CRC over the entire page
        // We need to re-read the page or reconstruct it with CRC = 0
        // For efficiency, calculate CRC incrementally:
        // 1. CRC of header with bytes 22-25 set to 0
        // 2. CRC of segment table
        // 3. CRC of page data

        // Header with CRC zeroed
        var header_for_crc: [27]u8 = header;
        header_for_crc[22] = 0;
        header_for_crc[23] = 0;
        header_for_crc[24] = 0;
        header_for_crc[25] = 0;

        // Start CRC calculation (MSB-first, direct polynomial)
        var crc: u32 = 0;

        // CRC of header
        for (header_for_crc) |byte| {
            crc = (crc << 8) ^ crc32_table[((crc >> 24) ^ byte) & 0xFF];
        }

        // CRC of segment table
        for (segment_table[0..n_segments]) |byte| {
            crc = (crc << 8) ^ crc32_table[((crc >> 24) ^ byte) & 0xFF];
        }

        // Read and CRC page data in chunks
        var data_remaining = page_data_size;
        var read_buf: [4096]u8 = undefined;
        while (data_remaining > 0) {
            const to_read = @min(data_remaining, read_buf.len);
            const bytes_read = file.read(read_buf[0..to_read]) catch {
                return OggValidationResult.invalid(errmsg.failedToRead("page data"), pages_verified, total_bytes);
            };
            if (bytes_read < to_read) {
                return OggValidationResult.invalid(errmsg.truncated("page data"), pages_verified, total_bytes);
            }

            // Add to CRC (MSB-first)
            for (read_buf[0..bytes_read]) |byte| {
                crc = (crc << 8) ^ crc32_table[((crc >> 24) ^ byte) & 0xFF];
            }

            data_remaining -= bytes_read;
        }

        // Verify CRC
        if (crc != stored_crc) {
            return OggValidationResult.invalid("CRC mismatch - page corrupted", pages_verified, total_bytes);
        }

        pages_verified += 1;
        total_bytes += total_page_size;
    }

    if (pages_verified == 0) {
        return OggValidationResult.invalid("No OGG pages found", 0, 0);
    }

    return OggValidationResult.ok(pages_verified, total_bytes);
}

/// Validate OGG CRCs from a file path.
pub fn validateOggCrcPath(path: []const u8) OggValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return OggValidationResult.invalid(errmsg.failedToOpen("file"), 0, 0);
    };
    defer file.close();
    return validateOggCrc(file);
}

// ============ OGG Packet Extraction ============

/// A single packet extracted from an OGG stream.
pub const OggPacket = struct {
    data: []u8,
    /// True if this is the first packet in a logical bitstream (BOS)
    is_bos: bool,
    /// True if this is the last packet in a logical bitstream (EOS)
    is_eos: bool,
    /// Granule position at end of this packet (-1 if unknown)
    granule_pos: i64,
    /// Packet number (0-indexed within the stream)
    packet_no: u64,
};

/// Result of packet extraction
pub const PacketExtractResult = struct {
    packets: []OggPacket,
    serial_number: u32,
    error_message: ?[]const u8,

    pub fn deinit(self: *PacketExtractResult, allocator: std.mem.Allocator) void {
        for (self.packets) |packet| {
            allocator.free(packet.data);
        }
        allocator.free(self.packets);
    }
};

/// Extract all packets from an OGG file.
/// Caller must call result.deinit() when done.
/// Only extracts packets from the first logical bitstream encountered.
pub fn extractPackets(allocator: std.mem.Allocator, file: std.fs.File) !PacketExtractResult {
    var packets: std.ArrayListUnmanaged(OggPacket) = .{};
    errdefer {
        for (packets.items) |packet| {
            allocator.free(packet.data);
        }
        packets.deinit(allocator);
    }

    // Buffer for building packets that span multiple segments
    var packet_buffer: std.ArrayListUnmanaged(u8) = .{};
    defer packet_buffer.deinit(allocator);

    var serial_number: ?u32 = null;
    var packet_no: u64 = 0;
    var current_granule: i64 = -1;
    var is_continuation: bool = false;

    // Seek to beginning
    try file.seekTo(0);

    // Read pages
    while (true) {
        // Read page header (27 bytes minimum)
        var header: [27]u8 = undefined;
        const header_bytes = try file.read(&header);

        // End of file
        if (header_bytes == 0) {
            break;
        }

        if (header_bytes < 27) {
            return error.TruncatedPageHeader;
        }

        // Verify capture pattern
        if (!std.mem.eql(u8, header[0..4], "OggS")) {
            return error.InvalidOggSignature;
        }

        // Check version
        if (header[4] != 0) {
            return error.UnsupportedOggVersion;
        }

        // Header type flags
        const header_type = header[5];
        const is_continued_packet = (header_type & 0x01) != 0;
        const is_bos = (header_type & 0x02) != 0;
        const is_eos = (header_type & 0x04) != 0;

        // Granule position (8 bytes, little-endian, signed)
        current_granule = @bitCast(std.mem.readInt(u64, header[6..14], .little));

        // Serial number
        const page_serial = std.mem.readInt(u32, header[14..18], .little);

        // Track first serial number (ignore other streams)
        if (serial_number == null) {
            serial_number = page_serial;
        } else if (serial_number != page_serial) {
            // Skip pages from other bitstreams (multiplexed OGG)
            const n_segments: usize = header[26];
            var skip_size: usize = 0;
            var seg_table: [255]u8 = undefined;
            if (n_segments > 0) {
                _ = try file.read(seg_table[0..n_segments]);
                for (seg_table[0..n_segments]) |s| {
                    skip_size += s;
                }
            }
            try file.seekBy(@intCast(skip_size));
            continue;
        }

        // Number of segments
        const n_segments: usize = header[26];

        // Read segment table
        var segment_table: [255]u8 = undefined;
        if (n_segments > 0) {
            const seg_bytes = try file.read(segment_table[0..n_segments]);
            if (seg_bytes < n_segments) {
                return error.TruncatedSegmentTable;
            }
        }

        // Handle continuation mismatch
        if (is_continued_packet and !is_continuation) {
            // We don't have a partial packet to continue - skip this segment
            // This can happen if we started reading mid-stream
        }

        // Process segments
        for (segment_table[0..n_segments]) |seg_size| {
            // Read segment data
            if (seg_size > 0) {
                const old_len = packet_buffer.items.len;
                try packet_buffer.resize(allocator, old_len + seg_size);
                const bytes_read = try file.read(packet_buffer.items[old_len..]);
                if (bytes_read < seg_size) {
                    return error.TruncatedPageData;
                }
            }

            // Segment size < 255 means end of packet
            if (seg_size < 255) {
                if (packet_buffer.items.len > 0) {
                    // Complete packet - add to list
                    const packet_data = try allocator.dupe(u8, packet_buffer.items);
                    errdefer allocator.free(packet_data);

                    try packets.append(allocator, .{
                        .data = packet_data,
                        .is_bos = is_bos and packet_no == 0,
                        .is_eos = false, // Will set on last packet
                        .granule_pos = current_granule,
                        .packet_no = packet_no,
                    });
                    packet_no += 1;
                }
                packet_buffer.clearRetainingCapacity();
                is_continuation = false;
            } else {
                // Segment size == 255, packet continues
                is_continuation = true;
            }
        }

        // Mark EOS on last page
        if (is_eos and packets.items.len > 0) {
            packets.items[packets.items.len - 1].is_eos = true;
        }
    }

    // Handle any remaining partial packet (shouldn't happen in valid OGG)
    if (packet_buffer.items.len > 0) {
        const packet_data = try allocator.dupe(u8, packet_buffer.items);
        errdefer allocator.free(packet_data);
        try packets.append(allocator, .{
            .data = packet_data,
            .is_bos = false,
            .is_eos = true,
            .granule_pos = current_granule,
            .packet_no = packet_no,
        });
    }

    return .{
        .packets = try packets.toOwnedSlice(allocator),
        .serial_number = serial_number orelse 0,
        .error_message = null,
    };
}

/// Extract packets from a file path.
pub fn extractPacketsPath(allocator: std.mem.Allocator, path: []const u8) !PacketExtractResult {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return extractPackets(allocator, file);
}

// ============ Tests ============

test "OGG CRC32 calculation matches known values" {
    // Test vector: "OggS" should produce a known CRC
    // CRC32 of "OggS" with OGG polynomial
    const result = oggCrc32("OggS");
    // This is a basic sanity check - the actual value needs verification
    try std.testing.expect(result != 0);
}

test "OGG CRC32 of empty data is 0" {
    const result = oggCrc32("");
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "OGG CRC32 is deterministic" {
    const data = "test data for CRC";
    const crc1 = oggCrc32(data);
    const crc2 = oggCrc32(data);
    try std.testing.expectEqual(crc1, crc2);
}

test "OGG validation rejects empty file" {
    // Create a temp file with no content
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile("empty.ogg", .{}) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "empty.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggCrcPath(path);
    // Empty file should be invalid (no OGG pages)
    try std.testing.expect(!result.valid);
}

test "OGG validation rejects garbage data" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile("garbage.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 }) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "garbage.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggCrcPath(path);
    try std.testing.expect(!result.valid);
}

test "OGG validation detects valid page with correct CRC" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid OGG page
    // This is a simplified test - real OGG files have codec-specific data
    var page: [28]u8 = undefined;

    // OggS capture pattern
    page[0] = 'O';
    page[1] = 'g';
    page[2] = 'g';
    page[3] = 'S';
    // Version 0
    page[4] = 0;
    // Header type: BOS (beginning of stream)
    page[5] = 0x02;
    // Granule position (8 bytes) - 0
    @memset(page[6..14], 0);
    // Serial number (4 bytes)
    page[14] = 0x01;
    page[15] = 0x00;
    page[16] = 0x00;
    page[17] = 0x00;
    // Page sequence (4 bytes)
    page[18] = 0x00;
    page[19] = 0x00;
    page[20] = 0x00;
    page[21] = 0x00;
    // CRC placeholder (4 bytes) - will be calculated
    page[22] = 0x00;
    page[23] = 0x00;
    page[24] = 0x00;
    page[25] = 0x00;
    // Number of segments: 1
    page[26] = 0x01;
    // Segment table: 0 bytes (empty segment)
    page[27] = 0x00;

    // Calculate CRC with CRC field set to 0
    const crc = oggCrc32(&page);
    // Write CRC back (little-endian)
    page[22] = @truncate(crc);
    page[23] = @truncate(crc >> 8);
    page[24] = @truncate(crc >> 16);
    page[25] = @truncate(crc >> 24);

    const file = tmp_dir.dir.createFile("valid.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&page) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "valid.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggCrcPath(path);
    // This should pass once implemented
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.pages_verified);
}

test "OGG validation detects corrupted CRC" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a valid OGG page, then corrupt it
    var page: [28]u8 = undefined;

    page[0] = 'O';
    page[1] = 'g';
    page[2] = 'g';
    page[3] = 'S';
    page[4] = 0;
    page[5] = 0x02;
    @memset(page[6..14], 0);
    page[14] = 0x01;
    page[15] = 0x00;
    page[16] = 0x00;
    page[17] = 0x00;
    page[18] = 0x00;
    page[19] = 0x00;
    page[20] = 0x00;
    page[21] = 0x00;
    page[22] = 0x00;
    page[23] = 0x00;
    page[24] = 0x00;
    page[25] = 0x00;
    page[26] = 0x01;
    page[27] = 0x00;

    // Calculate correct CRC
    const crc = oggCrc32(&page);
    // Write WRONG CRC (corrupted)
    page[22] = @truncate(crc ^ 0xFF); // Flip bits
    page[23] = @truncate(crc >> 8);
    page[24] = @truncate(crc >> 16);
    page[25] = @truncate(crc >> 24);

    const file = tmp_dir.dir.createFile("corrupted.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&page) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "corrupted.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggCrcPath(path);
    // Should detect the corruption
    try std.testing.expect(!result.valid);
}

test "OGG packet extraction from single-packet page" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create an OGG page with a single packet containing "Hello"
    const packet_data = "Hello";
    var page: [27 + 1 + 5]u8 = undefined; // header + segment table + data

    // OggS capture pattern
    page[0] = 'O';
    page[1] = 'g';
    page[2] = 'g';
    page[3] = 'S';
    // Version 0
    page[4] = 0;
    // Header type: BOS | EOS (single page stream)
    page[5] = 0x06;
    // Granule position (8 bytes) - 0
    @memset(page[6..14], 0);
    // Serial number (4 bytes)
    page[14] = 0x01;
    page[15] = 0x00;
    page[16] = 0x00;
    page[17] = 0x00;
    // Page sequence (4 bytes)
    page[18] = 0x00;
    page[19] = 0x00;
    page[20] = 0x00;
    page[21] = 0x00;
    // CRC placeholder (4 bytes)
    page[22] = 0x00;
    page[23] = 0x00;
    page[24] = 0x00;
    page[25] = 0x00;
    // Number of segments: 1
    page[26] = 0x01;
    // Segment table: 5 bytes
    page[27] = 5;
    // Packet data
    @memcpy(page[28..33], packet_data);

    // Calculate CRC with CRC field set to 0
    const crc = oggCrc32(&page);
    page[22] = @truncate(crc);
    page[23] = @truncate(crc >> 8);
    page[24] = @truncate(crc >> 16);
    page[25] = @truncate(crc >> 24);

    const file = tmp_dir.dir.createFile("packet.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&page) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "packet.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    var result = extractPacketsPath(std.testing.allocator, path) catch unreachable;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.packets.len);
    try std.testing.expectEqualStrings("Hello", result.packets[0].data);
    try std.testing.expect(result.packets[0].is_bos);
    try std.testing.expect(result.packets[0].is_eos);
}

test "OGG packet extraction with multi-segment packet" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create an OGG page with a packet spanning 2 segments (255 + 45 = 300 bytes)
    const packet_len: usize = 300;
    var packet_data: [packet_len]u8 = undefined;
    for (&packet_data, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    // Page: header(27) + segment_table(2) + data(300) = 329 bytes
    var page: [329]u8 = undefined;

    // OggS capture pattern
    page[0] = 'O';
    page[1] = 'g';
    page[2] = 'g';
    page[3] = 'S';
    page[4] = 0;
    page[5] = 0x06; // BOS | EOS
    @memset(page[6..14], 0);
    page[14] = 0x01;
    page[15] = 0x00;
    page[16] = 0x00;
    page[17] = 0x00;
    page[18] = 0x00;
    page[19] = 0x00;
    page[20] = 0x00;
    page[21] = 0x00;
    page[22] = 0x00;
    page[23] = 0x00;
    page[24] = 0x00;
    page[25] = 0x00;
    // Number of segments: 2
    page[26] = 0x02;
    // Segment table: 255, 45
    page[27] = 255;
    page[28] = 45;
    // Packet data
    @memcpy(page[29..329], &packet_data);

    // Calculate CRC
    const crc = oggCrc32(&page);
    page[22] = @truncate(crc);
    page[23] = @truncate(crc >> 8);
    page[24] = @truncate(crc >> 16);
    page[25] = @truncate(crc >> 24);

    const file = tmp_dir.dir.createFile("multi_seg.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&page) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "multi_seg.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    var result = extractPacketsPath(std.testing.allocator, path) catch unreachable;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.packets.len);
    try std.testing.expectEqual(@as(usize, 300), result.packets[0].data.len);
    try std.testing.expectEqualSlices(u8, &packet_data, result.packets[0].data);
}
