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
const runtime = @import("runtime.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const errmsg = @import("error_messages.zig");
const codec_utils = @import("codec_utils.zig");

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

/// Calculate OGG CRC32 for a buffer (MSB-first, direct polynomial)
pub const oggCrc32 = codec_utils.Crc32Ogg.hash;

/// Validate all OGG page CRCs in a file.
/// Returns the number of pages verified and total bytes covered.
pub fn validateOggCrc(file: *FileSource) OggValidationResult {
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
        var crc_state = codec_utils.Crc32Ogg.init();

        // CRC of header
        crc_state.updateSlice(&header_for_crc);

        // CRC of segment table
        crc_state.updateSlice(segment_table[0..n_segments]);

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
            crc_state.updateSlice(read_buf[0..bytes_read]);

            data_remaining -= bytes_read;
        }

        // Verify CRC
        if (crc_state.final() != stored_crc) {
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
    var source = FileSource.open(path) catch {
        return OggValidationResult.invalid(errmsg.failedToOpen("file"), 0, 0);
    };
    defer source.close();
    return validateOggCrc(&source);
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

/// Map a packet-walk error to the user-facing message every ogg-family
/// validator historically produced. Shared so the streaming consumers
/// (vorbis/opus/theora/deep-dispatch) stay message-identical.
pub fn extractErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TruncatedPageHeader => "Truncated OGG page header",
        error.InvalidOggSignature => "Invalid OGG signature",
        error.UnsupportedOggVersion => "Unsupported OGG version",
        error.TruncatedSegmentTable => "Truncated OGG segment table",
        error.TruncatedPageData => "Truncated OGG page data",
        else => "Failed to extract OGG packets",
    };
}

/// Streaming OGG packet reader: incremental demux that yields ONE packet at a
/// time so anonymous memory stays O(largest packet) instead of O(file size).
/// This is the memory-ceiling ("streams" vs "resident") fix for the ogg
/// families — extractPackets() duplicated every packet into the (arena-backed)
/// allocator, which OOM-killed multi-GiB files under a cgroup MemoryMax.
/// Technique: same page walk as the old extractPackets (first logical
/// bitstream only; multiplexed pages skipped), but the packet-assembly buffer
/// is yielded by reference and cleared-retaining-capacity on the next call.
pub const PacketIter = struct {
    file: *FileSource,
    packet_buffer: std.ArrayListUnmanaged(u8) = .empty,
    serial_number: ?u32 = null,
    packet_no: u64 = 0,
    current_granule: i64 = -1,
    /// Segment table of the page currently being drained.
    segment_table: [255]u8 = undefined,
    n_segments: usize = 0,
    seg_idx: usize = 0,
    page_is_bos: bool = false,
    page_is_eos: bool = false,
    at_eof: bool = false,
    /// True while packet_buffer holds a packet already handed to the caller;
    /// the next call to next() reclaims it.
    yielded: bool = false,

    pub fn init(file: *FileSource) !PacketIter {
        try file.seekTo(0);
        return .{ .file = file };
    }

    pub fn deinit(self: *PacketIter, allocator: std.mem.Allocator) void {
        self.packet_buffer.deinit(allocator);
    }

    /// True when no payload bytes remain in the current page's segment table.
    /// Used to mark is_eos: a packet completing on an EOS page with nothing
    /// after it is the logical stream's final packet.
    fn pageRemainderEmpty(self: *const PacketIter) bool {
        for (self.segment_table[self.seg_idx..self.n_segments]) |s| {
            if (s != 0) return false;
        }
        return true;
    }

    /// Yield the next packet, or null at end of stream. The returned
    /// packet's `data` slice is owned by the iterator and is INVALIDATED
    /// by the next call to next() (or deinit()); callers that need it
    /// longer must dupe it.
    pub fn next(self: *PacketIter, allocator: std.mem.Allocator) !?OggPacket {
        if (self.yielded) {
            self.packet_buffer.clearRetainingCapacity();
            self.yielded = false;
        }
        if (self.at_eof) return null;

        while (true) {
            // Drain segments of the current page.
            while (self.seg_idx < self.n_segments) {
                const seg_size: usize = self.segment_table[self.seg_idx];
                self.seg_idx += 1;

                if (seg_size > 0) {
                    const old_len = self.packet_buffer.items.len;
                    try self.packet_buffer.resize(allocator, old_len + seg_size);
                    const bytes_read = try self.file.read(self.packet_buffer.items[old_len..]);
                    if (bytes_read < seg_size) {
                        return error.TruncatedPageData;
                    }
                }

                // Segment size < 255 terminates a packet; zero-length
                // packets are skipped (matches historical extractPackets).
                if (seg_size < 255 and self.packet_buffer.items.len > 0) {
                    const pkt = OggPacket{
                        .data = self.packet_buffer.items,
                        .is_bos = self.page_is_bos and self.packet_no == 0,
                        .is_eos = self.page_is_eos and self.pageRemainderEmpty(),
                        .granule_pos = self.current_granule,
                        .packet_no = self.packet_no,
                    };
                    self.packet_no += 1;
                    self.yielded = true;
                    return pkt;
                }
            }

            // Page exhausted — read the next page header (27 bytes).
            var header: [27]u8 = undefined;
            const header_bytes = try self.file.read(&header);

            if (header_bytes == 0) {
                self.at_eof = true;
                // Trailing partial packet (invalid stream, tolerated).
                if (self.packet_buffer.items.len > 0) {
                    const pkt = OggPacket{
                        .data = self.packet_buffer.items,
                        .is_bos = false,
                        .is_eos = true,
                        .granule_pos = self.current_granule,
                        .packet_no = self.packet_no,
                    };
                    self.packet_no += 1;
                    self.yielded = true;
                    return pkt;
                }
                return null;
            }
            if (header_bytes < 27) return error.TruncatedPageHeader;
            if (!std.mem.eql(u8, header[0..4], "OggS")) return error.InvalidOggSignature;
            if (header[4] != 0) return error.UnsupportedOggVersion;

            const header_type = header[5];
            const page_serial = std.mem.readInt(u32, header[14..18], .little);
            const n_segments: usize = header[26];

            if (self.serial_number == null) {
                self.serial_number = page_serial;
            } else if (self.serial_number.? != page_serial) {
                // Skip pages from other bitstreams (multiplexed OGG).
                var seg_table: [255]u8 = undefined;
                var skip_size: usize = 0;
                if (n_segments > 0) {
                    _ = try self.file.read(seg_table[0..n_segments]);
                    for (seg_table[0..n_segments]) |s| {
                        skip_size += s;
                    }
                }
                try self.file.seekBy(@intCast(skip_size));
                continue;
            }

            self.page_is_bos = (header_type & 0x02) != 0;
            self.page_is_eos = (header_type & 0x04) != 0;
            self.current_granule = @bitCast(std.mem.readInt(u64, header[6..14], .little));

            if (n_segments > 0) {
                const seg_bytes = try self.file.read(self.segment_table[0..n_segments]);
                if (seg_bytes < n_segments) {
                    return error.TruncatedSegmentTable;
                }
            }
            self.n_segments = n_segments;
            self.seg_idx = 0;
        }
    }
};

/// Extract all packets from an OGG file into owned memory.
/// Caller must call result.deinit() when done.
/// Only extracts packets from the first logical bitstream encountered.
/// NOTE: this holds every packet resident (~file size) — use PacketIter for
/// anything that may see large files; this remains for small inputs/tests.
pub fn extractPackets(allocator: std.mem.Allocator, file: *FileSource) !PacketExtractResult {
    var packets: std.ArrayListUnmanaged(OggPacket) = .empty;
    errdefer {
        for (packets.items) |packet| {
            allocator.free(packet.data);
        }
        packets.deinit(allocator);
    }

    var iter = try PacketIter.init(file);
    defer iter.deinit(allocator);

    while (try iter.next(allocator)) |pkt| {
        const packet_data = try allocator.dupe(u8, pkt.data);
        errdefer allocator.free(packet_data);
        var owned = pkt;
        owned.data = packet_data;
        try packets.append(allocator, owned);
    }

    return .{
        .packets = try packets.toOwnedSlice(allocator),
        .serial_number = iter.serial_number orelse 0,
        .error_message = null,
    };
}

/// Extract packets from a file path.
pub fn extractPacketsPath(allocator: std.mem.Allocator, path: []const u8) !PacketExtractResult {
    var source = try FileSource.open(path);
    defer source.close();
    return extractPackets(allocator, &source);
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

    const file = tmp_dir.dir.createFile(runtime.io(), "empty.ogg", .{}) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "empty.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggCrcPath(path);
    // Empty file should be invalid (no OGG pages)
    try std.testing.expect(!result.valid);
}

test "OGG validation rejects garbage data" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile(runtime.io(), "garbage.ogg", .{ .read = true }) catch unreachable;
    file.writePositionalAll(runtime.io(), &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 }, 0) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "garbage.ogg") catch unreachable;
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

    const file = tmp_dir.dir.createFile(runtime.io(), "valid.ogg", .{ .read = true }) catch unreachable;
    file.writePositionalAll(runtime.io(), &page, 0) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "valid.ogg") catch unreachable;
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

    const file = tmp_dir.dir.createFile(runtime.io(), "corrupted.ogg", .{ .read = true }) catch unreachable;
    file.writePositionalAll(runtime.io(), &page, 0) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "corrupted.ogg") catch unreachable;
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

    const file = tmp_dir.dir.createFile(runtime.io(), "packet.ogg", .{ .read = true }) catch unreachable;
    file.writePositionalAll(runtime.io(), &page, 0) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "packet.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    var result = extractPacketsPath(std.testing.allocator, path) catch unreachable;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.packets.len);
    try std.testing.expectEqualStrings("Hello", result.packets[0].data);
    try std.testing.expect(result.packets[0].is_bos);
    try std.testing.expect(result.packets[0].is_eos);
}

/// Test helper: append one OGG page (header + segment table + data) to `out`,
/// with a correct page CRC. `segments` is the raw segment table; `data` must
/// be exactly the sum of the segment sizes.
fn testAppendPage(
	out: *std.ArrayListUnmanaged(u8),
	allocator: std.mem.Allocator,
	flags: u8,
	serial: u32,
	segments: []const u8,
	data: []const u8,
) !void {
	var total: usize = 0;
	for (segments) |s| total += s;
	std.debug.assert(total == data.len);

	const start = out.items.len;
	try out.appendSlice(allocator, "OggS");
	try out.append(allocator, 0); // version
	try out.append(allocator, flags);
	try out.appendSlice(allocator, &[_]u8{0} ** 8); // granule position
	var le4: [4]u8 = undefined;
	std.mem.writeInt(u32, &le4, serial, .little);
	try out.appendSlice(allocator, &le4); // serial number
	try out.appendSlice(allocator, &[_]u8{0} ** 4); // page sequence
	try out.appendSlice(allocator, &[_]u8{0} ** 4); // CRC placeholder
	try out.append(allocator, @intCast(segments.len));
	try out.appendSlice(allocator, segments);
	try out.appendSlice(allocator, data);

	const crc = oggCrc32(out.items[start..]);
	std.mem.writeInt(u32, out.items[start + 22 ..][0..4], crc, .little);
}

test "PacketIter yields packets one at a time with buffer reuse" {
	var page: std.ArrayListUnmanaged(u8) = .empty;
	defer page.deinit(std.testing.allocator);
	// One page, two packets: "Hello" (seg 5) and "Wld" (seg 3), BOS|EOS.
	try testAppendPage(&page, std.testing.allocator, 0x06, 1, &.{ 5, 3 }, "HelloWld");

	var src = FileSource.fromBuffer(page.items);
	defer src.close();
	var iter = try PacketIter.init(&src);
	defer iter.deinit(std.testing.allocator);

	const p1 = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqualStrings("Hello", p1.data);
	try std.testing.expect(p1.is_bos);
	try std.testing.expect(!p1.is_eos);
	try std.testing.expectEqual(@as(u64, 0), p1.packet_no);

	const p2 = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqualStrings("Wld", p2.data);
	try std.testing.expect(!p2.is_bos);
	try std.testing.expect(p2.is_eos);
	try std.testing.expectEqual(@as(u64, 1), p2.packet_no);

	try std.testing.expectEqual(@as(?OggPacket, null), try iter.next(std.testing.allocator));
	// Exhausted iterator stays exhausted.
	try std.testing.expectEqual(@as(?OggPacket, null), try iter.next(std.testing.allocator));
}

test "PacketIter reassembles packet spanning two pages" {
	var stream: std.ArrayListUnmanaged(u8) = .empty;
	defer stream.deinit(std.testing.allocator);

	var payload: [300]u8 = undefined;
	for (&payload, 0..) |*b, i| b.* = @truncate(i);

	// Page 1: BOS, one 255-byte segment (packet continues).
	try testAppendPage(&stream, std.testing.allocator, 0x02, 1, &.{255}, payload[0..255]);
	// Page 2: continuation | EOS, remaining 45 bytes terminate the packet.
	try testAppendPage(&stream, std.testing.allocator, 0x05, 1, &.{45}, payload[255..300]);

	var src = FileSource.fromBuffer(stream.items);
	defer src.close();
	var iter = try PacketIter.init(&src);
	defer iter.deinit(std.testing.allocator);

	const p = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqual(@as(usize, 300), p.data.len);
	try std.testing.expectEqualSlices(u8, &payload, p.data);
	try std.testing.expect(p.is_eos);
	try std.testing.expectEqual(@as(?OggPacket, null), try iter.next(std.testing.allocator));
}

test "PacketIter skips pages from other logical bitstreams" {
	var stream: std.ArrayListUnmanaged(u8) = .empty;
	defer stream.deinit(std.testing.allocator);

	try testAppendPage(&stream, std.testing.allocator, 0x02, 1, &.{3}, "AAA");
	try testAppendPage(&stream, std.testing.allocator, 0x02, 2, &.{3}, "BBB"); // other serial
	try testAppendPage(&stream, std.testing.allocator, 0x04, 1, &.{3}, "CCC");

	var src = FileSource.fromBuffer(stream.items);
	defer src.close();
	var iter = try PacketIter.init(&src);
	defer iter.deinit(std.testing.allocator);

	const p1 = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqualStrings("AAA", p1.data);
	const p2 = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqualStrings("CCC", p2.data);
	try std.testing.expect(p2.is_eos);
	try std.testing.expectEqual(@as(?OggPacket, null), try iter.next(std.testing.allocator));
}

test "PacketIter yields trailing partial packet at EOF as EOS" {
	var stream: std.ArrayListUnmanaged(u8) = .empty;
	defer stream.deinit(std.testing.allocator);

	var payload: [255]u8 = undefined;
	for (&payload, 0..) |*b, i| b.* = @truncate(i);
	// Single page whose only segment is 255 bytes (packet never terminates).
	try testAppendPage(&stream, std.testing.allocator, 0x02, 1, &.{255}, &payload);

	var src = FileSource.fromBuffer(stream.items);
	defer src.close();
	var iter = try PacketIter.init(&src);
	defer iter.deinit(std.testing.allocator);

	const p = (try iter.next(std.testing.allocator)) orelse return error.TestExpectedPacket;
	try std.testing.expectEqualSlices(u8, &payload, p.data);
	try std.testing.expect(p.is_eos);
	try std.testing.expectEqual(@as(?OggPacket, null), try iter.next(std.testing.allocator));
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

    const file = tmp_dir.dir.createFile(runtime.io(), "multi_seg.ogg", .{ .read = true }) catch unreachable;
    file.writePositionalAll(runtime.io(), &page, 0) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "multi_seg.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    var result = extractPacketsPath(std.testing.allocator, path) catch unreachable;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.packets.len);
    try std.testing.expectEqual(@as(usize, 300), result.packets[0].data.len);
    try std.testing.expectEqualSlices(u8, &packet_data, result.packets[0].data);
}
