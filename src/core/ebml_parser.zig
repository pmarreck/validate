//! EBML (Extensible Binary Meta Language) parser for Matroska/WebM.
//!
//! EBML is a binary format using variable-length integers for element IDs and sizes.
//! This parser provides low-level EBML primitives and high-level Matroska structure parsing.
//!
//! Reference: https://www.matroska.org/technical/elements.html
//! EBML spec: https://github.com/ietf-wg-cellar/ebml-specification

const std = @import("std");
const runtime = @import("runtime.zig");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

// ============ EBML Element IDs (Matroska) ============

/// Top-level EBML elements
pub const EBML_ID = struct {
    pub const EBML: u32 = 0x1A45DFA3;
    pub const Segment: u32 = 0x18538067;
    pub const CRC32: u32 = 0xBF; // Can appear in any master element
    pub const Void: u32 = 0xEC; // Padding element
};

/// Segment children
pub const Segment_ID = struct {
    pub const SeekHead: u32 = 0x114D9B74;
    pub const Info: u32 = 0x1549A966;
    pub const Tracks: u32 = 0x1654AE6B;
    pub const Chapters: u32 = 0x1043A770;
    pub const Cluster: u32 = 0x1F43B675;
    pub const Cues: u32 = 0x1C53BB6B;
    pub const Attachments: u32 = 0x1941A469;
    pub const Tags: u32 = 0x1254C367;
};

/// EBML Header children
pub const EBMLHeader_ID = struct {
    pub const EBMLVersion: u32 = 0x4286;
    pub const EBMLReadVersion: u32 = 0x42F7;
    pub const EBMLMaxIDLength: u32 = 0x42F2;
    pub const EBMLMaxSizeLength: u32 = 0x42F3;
    pub const DocType: u32 = 0x4282;
    pub const DocTypeVersion: u32 = 0x4287;
    pub const DocTypeReadVersion: u32 = 0x4285;
};

/// Segment Info children
pub const Info_ID = struct {
    pub const TimestampScale: u32 = 0x2AD7B1;
    pub const Duration: u32 = 0x4489;
    pub const DateUTC: u32 = 0x4461;
    pub const Title: u32 = 0x7BA9;
    pub const MuxingApp: u32 = 0x4D80;
    pub const WritingApp: u32 = 0x5741;
    pub const SegmentUID: u32 = 0x73A4;
};

/// Track children
pub const Tracks_ID = struct {
    pub const TrackEntry: u32 = 0xAE;
};

/// TrackEntry children
pub const TrackEntry_ID = struct {
    pub const TrackNumber: u32 = 0xD7;
    pub const TrackUID: u32 = 0x73C5;
    pub const TrackType: u32 = 0x83;
    pub const FlagEnabled: u32 = 0xB9;
    pub const FlagDefault: u32 = 0x88;
    pub const FlagForced: u32 = 0x55AA;
    pub const FlagLacing: u32 = 0x9C;
    pub const DefaultDuration: u32 = 0x23E383;
    pub const Name: u32 = 0x536E;
    pub const Language: u32 = 0x22B59C;
    pub const CodecID: u32 = 0x86;
    pub const CodecPrivate: u32 = 0x63A2;
    pub const CodecName: u32 = 0x258688;
    pub const Video: u32 = 0xE0;
    pub const Audio: u32 = 0xE1;
    pub const ContentEncodings: u32 = 0x6D80;
};

/// ContentEncoding children
pub const ContentEncoding_ID = struct {
    pub const ContentCompression: u32 = 0x5034;
};

/// ContentCompression children
pub const ContentCompression_ID = struct {
    pub const ContentCompAlgo: u32 = 0x4254;
    pub const ContentCompSettings: u32 = 0x4255;
};

/// Video settings children
pub const Video_ID = struct {
    pub const FlagInterlaced: u32 = 0x9A;
    pub const StereoMode: u32 = 0x53B8;
    pub const PixelWidth: u32 = 0xB0;
    pub const PixelHeight: u32 = 0xBA;
    pub const DisplayWidth: u32 = 0x54B0;
    pub const DisplayHeight: u32 = 0x54BA;
    pub const DisplayUnit: u32 = 0x54B2;
    pub const ColourSpace: u32 = 0x2EB524;
    pub const Colour: u32 = 0x55B0;
};

/// Cluster children
pub const Cluster_ID = struct {
    pub const Timestamp: u32 = 0xE7;
    pub const Position: u32 = 0xA7;
    pub const PrevSize: u32 = 0xAB;
    pub const SimpleBlock: u32 = 0xA3;
    pub const BlockGroup: u32 = 0xA0;
};

/// BlockGroup children
pub const BlockGroup_ID = struct {
    pub const Block: u32 = 0xA1;
    pub const BlockDuration: u32 = 0x9B;
    pub const ReferenceBlock: u32 = 0xFB;
    pub const CodecState: u32 = 0xA4;
};

// ============ Track Types ============

pub const TrackType = enum(u8) {
    video = 1,
    audio = 2,
    complex = 3,
    logo = 0x10,
    subtitle = 0x11,
    buttons = 0x12,
    control = 0x20,
    metadata = 0x21,
    _,
};

// ============ EBML VINT (Variable-length Integer) ============

/// Read a variable-length integer (VINT) from a byte slice.
/// Returns the value and the number of bytes consumed.
/// VINT encoding: leading zeros count determines byte length.
pub fn readVint(data: []const u8) ?struct { value: u64, bytes: usize } {
    if (data.len == 0) return null;

    const first = data[0];
    if (first == 0) return null; // Invalid: all zeros

    // Count leading zeros to determine length
    const leading_zeros = @clz(first);
    const length: usize = @as(usize, leading_zeros) + 1;

    if (data.len < length) return null;

    // Mask to remove the length marker bit
    // For 8-byte VINTs (leading_zeros = 7), the mask would need shift by 8, so handle specially
    const shift_amount: u3 = if (leading_zeros >= 7) 7 else @intCast(leading_zeros + 1);
    const mask: u8 = @as(u8, 0xFF) >> shift_amount;

    var value: u64 = if (leading_zeros >= 7) 0 else first & mask;
    for (data[1..length]) |byte| {
        value = (value << 8) | byte;
    }

    return .{ .value = value, .bytes = length };
}

fn readSignedVint(data: []const u8) ?struct { value: i64, bytes: usize } {
    const vint = readVint(data) orelse return null;
    const bits: u6 = @intCast(vint.bytes * 7);
    const bias: i64 = (@as(i64, 1) << (bits - 1)) - 1;
    const signed: i64 = @as(i64, @intCast(vint.value)) - bias;
    return .{ .value = signed, .bytes = vint.bytes };
}

const BlockFrameConsumerFn = fn (ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool;

const BlockHeaderInfo = struct {
    track_number: u64,
    rel_timestamp: i16,
    flags: u8,
    lacing: u2,
    header_bytes: usize,
};

fn writeFmt(writer: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    // 0.16: Io.File has no sequential writeAll; this debug logger needs offset
    // tracking. The user-visible debug path is gated on MKV_BYTE_DEBUG, so a
    // regression here doesn't affect normal validation. TODO: refactor to take
    // a *std.Io.Writer (buffered) so the debug stream is restored.
    _ = writer;
    _ = args;
    _ = fmt;
}

fn parseBlockHeader(data: []const u8) ?BlockHeaderInfo {
    if (data.len < 4) return null;
    const track_vint = readVint(data) orelse return null;
    const offset = track_vint.bytes;
    if (data.len < offset + 3) return null;
    const rel_timestamp = std.mem.readInt(i16, data[offset..][0..2], .big);
    const flags = data[offset + 2];
    const lacing: u2 = @intCast((flags >> 1) & 0x03);
    return .{
        .track_number = track_vint.value,
        .rel_timestamp = rel_timestamp,
        .flags = flags,
        .lacing = lacing,
        .header_bytes = offset + 3,
    };
}

fn parseBlockFramesFromBuffer(
    data: []const u8,
    target_track: u64,
    cluster_timestamp: i64,
    combine_laced_frames: bool,
    ctx: ?*anyopaque,
    consumer: BlockFrameConsumerFn,
) ?usize {
    if (data.len < 4) return null;

    const track_vint = readVint(data) orelse return null;
    if (track_vint.value != target_track) return 0;

    var offset: usize = track_vint.bytes;
    if (data.len < offset + 3) return null;

    const rel_timestamp = std.mem.readInt(i16, data[offset..][0..2], .big);
    offset += 2;

    const flags = data[offset];
    offset += 1;

    const timestamp = cluster_timestamp + rel_timestamp;
    const lacing: u2 = @intCast((flags >> 1) & 0x03);

    const frame_data = data[offset..];
    if (lacing == 0) {
        if (frame_data.len == 0) return null;
        if (!consumer(ctx, frame_data, timestamp)) return null;
        return 1;
    }

    if (frame_data.len < 1) return null;

    const lace_count: u8 = frame_data[0];
    const num_frames: usize = @as(usize, lace_count) + 1;
    if (num_frames > 256) return null;

    var cursor: usize = 1;

    if (combine_laced_frames) {
        switch (lacing) {
            1 => { // Xiph lacing
                var i: usize = 0;
                while (i + 1 < num_frames) : (i += 1) {
                    while (true) {
                        if (cursor >= frame_data.len) return null;
                        const b = frame_data[cursor];
                        cursor += 1;
                        if (b != 0xFF) break;
                    }
                }
            },
            2 => {}, // Fixed-size lacing has no additional headers
            3 => { // EBML lacing
                if (num_frames > 1) {
                    const first = readVint(frame_data[cursor..]) orelse return null;
                    cursor += first.bytes;
                    var i: usize = 1;
                    while (i + 1 < num_frames) : (i += 1) {
                        const diff = readSignedVint(frame_data[cursor..]) orelse return null;
                        cursor += diff.bytes;
                    }
                }
            },
            else => return null,
        }

        if (cursor >= frame_data.len) return null;
        if (!consumer(ctx, frame_data[cursor..], timestamp)) return null;
        return 1;
    }

    var sizes: [256]u64 = undefined;
    var sizes_total: u64 = 0;

    switch (lacing) {
        1 => { // Xiph lacing
            var i: usize = 0;
            while (i + 1 < num_frames) : (i += 1) {
                var size: u64 = 0;
                while (true) {
                    if (cursor >= frame_data.len) return null;
                    const b = frame_data[cursor];
                    cursor += 1;
                    size += b;
                    if (b != 0xFF) break;
                }
                sizes[i] = size;
                sizes_total += size;
            }
        },
        2 => { // Fixed-size lacing
            const remaining = frame_data.len - cursor;
            if (num_frames == 0) return null;
            if (remaining % num_frames != 0) return null;
            const size = remaining / num_frames;
            if (size == 0) return null;
            var i: usize = 0;
            while (i < num_frames) : (i += 1) {
                sizes[i] = @intCast(size);
            }
            sizes_total = @as(u64, @intCast(size)) * @as(u64, @intCast(num_frames));
        },
        3 => { // EBML lacing
            if (num_frames > 1) {
                const first = readVint(frame_data[cursor..]) orelse return null;
                cursor += first.bytes;
                sizes[0] = first.value;
                sizes_total += first.value;

                var prev_size: i64 = @intCast(first.value);
                var i: usize = 1;
                while (i + 1 < num_frames) : (i += 1) {
                    const diff = readSignedVint(frame_data[cursor..]) orelse return null;
                    cursor += diff.bytes;
                    const next_size = prev_size + diff.value;
                    if (next_size < 0) return null;
                    const next_u: u64 = @intCast(next_size);
                    sizes[i] = next_u;
                    sizes_total += next_u;
                    prev_size = next_size;
                }
            }
        },
        else => return null,
    }

    // For Xiph and EBML lacing, only the first N-1 frame sizes are encoded;
    // the last frame size is inferred from the remaining bytes.
    // For fixed-size lacing, all frame sizes are already computed.
    if (lacing != 2) {
        const remaining_bytes: u64 = @intCast(frame_data.len - cursor);
        if (sizes_total > remaining_bytes) return null;

        const last_size: u64 = remaining_bytes - sizes_total;
        sizes[num_frames - 1] = last_size;
    }

    var data_offset: usize = cursor;
    var frame_index: usize = 0;
    while (frame_index < num_frames) : (frame_index += 1) {
        const size_u64 = sizes[frame_index];
        if (size_u64 == 0) return null;
        if (size_u64 > std.math.maxInt(usize)) return null;
        const size = @as(usize, @intCast(size_u64));
        if (data_offset + size > frame_data.len) return null;

        const frame = frame_data[data_offset .. data_offset + size];
        if (!consumer(ctx, frame, timestamp)) return null;
        data_offset += size;
    }

    if (data_offset != frame_data.len) return null;
    return num_frames;
}

/// Read an element ID (same format as VINT but we keep the marker bit for IDs).
pub fn readElementId(data: []const u8) ?struct { id: u32, bytes: usize } {
    if (data.len == 0) return null;

    const first = data[0];
    if (first == 0) return null;

    const leading_zeros = @clz(first);
    const length: usize = @as(usize, leading_zeros) + 1;

    if (length > 4) return null; // Max 4-byte element IDs
    if (data.len < length) return null;

    var id: u32 = first;
    for (data[1..length]) |byte| {
        id = (id << 8) | byte;
    }

    return .{ .id = id, .bytes = length };
}

/// Read an element size (VINT with special handling for unknown size).
/// Returns null for unknown/infinite size (all 1s).
pub fn readElementSize(data: []const u8) ?struct { size: ?u64, bytes: usize } {
    const vint = readVint(data) orelse return null;

    // Check for unknown size (all data bits are 1)
    const length = vint.bytes;
    const max_value: u64 = (@as(u64, 1) << @intCast(7 * length)) - 1;

    if (vint.value == max_value) {
        return .{ .size = null, .bytes = length }; // Unknown size
    }

    return .{ .size = vint.value, .bytes = length };
}

// ============ EBML Element ============

/// Represents a parsed EBML element header.
pub const EbmlElement = struct {
    id: u32,
    size: ?u64, // null means unknown/streaming size
    header_size: usize,
    data_offset: u64, // Absolute offset in file where data starts

    /// Get the total element size including header.
    pub fn totalSize(self: EbmlElement) ?u64 {
        if (self.size) |s| {
            return s + self.header_size;
        }
        return null;
    }
};

// ============ EBML Reader ============

/// Streaming EBML reader that works with FileSource handles.
pub const EbmlReader = struct {
    file: *FileSource,
    file_size: u64,

    pub fn init(file: *FileSource) EbmlReader {
        const file_size = file.getEndPos() catch 0;
        return .{
            .file = file,
            .file_size = file_size,
        };
    }

    /// Read an element header at the current position.
    pub fn readElementHeader(self: *EbmlReader) ?EbmlElement {
        const start_pos = self.file.getPos() catch return null;

        var header_buf: [12]u8 = undefined; // Max: 4-byte ID + 8-byte size
        const bytes_read = self.file.read(&header_buf) catch return null;
        if (bytes_read < 2) return null;

        // Parse element ID
        const id_result = readElementId(header_buf[0..bytes_read]) orelse return null;

        // Parse element size
        const remaining = header_buf[id_result.bytes..bytes_read];
        const size_result = readElementSize(remaining) orelse return null;

        const header_size = id_result.bytes + size_result.bytes;
        const data_offset = start_pos + header_size;

        return EbmlElement{
            .id = id_result.id,
            .size = size_result.size,
            .header_size = header_size,
            .data_offset = data_offset,
        };
    }

    /// Read element data as bytes (for small elements).
    pub fn readElementData(self: *EbmlReader, element: EbmlElement, allocator: Allocator) ?[]u8 {
        const size = element.size orelse return null;
        if (size > 1024 * 1024) return null; // Limit to 1MB for safety

        self.file.seekTo(element.data_offset) catch return null;

        const buffer = allocator.alloc(u8, @intCast(size)) catch return null;
        const bytes_read = self.file.readAll(buffer) catch {
            allocator.free(buffer);
            return null;
        };

        if (bytes_read != size) {
            allocator.free(buffer);
            return null;
        }

        return buffer;
    }

    /// Read element data as unsigned integer.
    pub fn readElementUint(self: *EbmlReader, element: EbmlElement) ?u64 {
        const size = element.size orelse return null;
        if (size > 8) return null;

        self.file.seekTo(element.data_offset) catch return null;

        var buf: [8]u8 = [_]u8{0} ** 8;
        const offset = 8 - @as(usize, @intCast(size));
        const bytes_read = self.file.read(buf[offset..]) catch return null;
        if (bytes_read != size) return null;

        return std.mem.readInt(u64, &buf, .big);
    }

    /// Read element data as string.
    pub fn readElementString(self: *EbmlReader, element: EbmlElement, allocator: Allocator) ?[]u8 {
        return self.readElementData(element, allocator);
    }

    /// Skip to the next sibling element (skip current element's data).
    pub fn skipElement(self: *EbmlReader, element: EbmlElement) bool {
        const size = element.size orelse return false;
        const next_pos = element.data_offset + size;
        self.file.seekTo(next_pos) catch return false;
        return true;
    }

    /// Seek to a specific position.
    pub fn seekTo(self: *EbmlReader, pos: u64) bool {
        self.file.seekTo(pos) catch return false;
        return true;
    }

    /// Get current position.
    pub fn getPos(self: *EbmlReader) ?u64 {
        return self.file.getPos() catch null;
    }
};

// ============ Matroska Document Info ============

/// Parsed EBML document header info.
/// Uses fixed-size buffer for doc_type to avoid allocation.
pub const EbmlDocInfo = struct {
    doc_type_buf: [32]u8,
    doc_type_len: usize,
    doc_type_version: u64,
    doc_type_read_version: u64,
    ebml_version: u64,
    ebml_read_version: u64,

    pub fn docType(self: *const EbmlDocInfo) []const u8 {
        return self.doc_type_buf[0..self.doc_type_len];
    }

    pub fn isMatroska(self: *const EbmlDocInfo) bool {
        return std.mem.eql(u8, self.docType(), "matroska");
    }

    pub fn isWebM(self: *const EbmlDocInfo) bool {
        return std.mem.eql(u8, self.docType(), "webm");
    }
};

// ============ Video Track Info ============

/// Maximum codec_id length (longest is ~32 chars like "V_MPEGH/ISO/HEVC")
const MAX_CODEC_ID_LEN: usize = 64;

/// Parsed video track information.
/// Uses fixed-size buffer for codec_id to avoid allocation.
/// codec_private is heap-allocated and must be freed via deinit().
pub const VideoTrackInfo = struct {
    track_number: u64,
    track_uid: u64,
    codec_id_buf: [MAX_CODEC_ID_LEN]u8,
    codec_id_len: usize,
    codec_private: ?[]const u8, // Codec initialization data (heap allocated)
    codec_private_allocator: ?Allocator, // Allocator used for codec_private
    pixel_width: u64,
    pixel_height: u64,
    display_width: ?u64,
    display_height: ?u64,
    default_duration: ?u64, // In nanoseconds
    // ContentCompression header stripping (algo=3): bytes to prepend to each frame
    content_comp_header: ?[]const u8, // Heap allocated
    content_comp_allocator: ?Allocator,

    pub fn codecId(self: *const VideoTrackInfo) []const u8 {
        return self.codec_id_buf[0..self.codec_id_len];
    }

    pub fn deinit(self: *VideoTrackInfo) void {
        if (self.codec_private) |cp| {
            if (self.codec_private_allocator) |alloc| {
                alloc.free(cp);
            }
        }
        self.codec_private = null;
        self.codec_private_allocator = null;
        if (self.content_comp_header) |hdr| {
            if (self.content_comp_allocator) |alloc| {
                alloc.free(hdr);
            }
        }
        self.content_comp_header = null;
        self.content_comp_allocator = null;
    }

    pub fn isHevc(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_MPEGH/ISO/HEVC");
    }

    pub fn isAv1(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_AV1");
    }

    pub fn isH264(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_MPEG4/ISO/AVC");
    }

    pub fn isVp9(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_VP9");
    }

    pub fn isVp8(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_VP8");
    }

    pub fn isMjpeg(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_MJPEG");
    }

    pub fn isMpeg1(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_MPEG1");
    }

    pub fn isMpeg2(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_MPEG2");
    }

    pub fn isTheora(self: *const VideoTrackInfo) bool {
        return std.mem.eql(u8, self.codecId(), "V_THEORA");
    }
};

// ============ Matroska Parser ============

/// High-level Matroska/WebM parser.
pub const MatroskaParser = struct {
    reader: EbmlReader,
    allocator: Allocator,
    segment_offset: u64,
    segment_size: ?u64,

    pub fn init(allocator: Allocator, file: *FileSource) MatroskaParser {
        return .{
            .reader = EbmlReader.init(file),
            .allocator = allocator,
            .segment_offset = 0,
            .segment_size = null,
        };
    }

    /// Parse and validate the EBML header.
    pub fn parseEbmlHeader(self: *MatroskaParser) ?EbmlDocInfo {
        _ = self.reader.seekTo(0);

        const header = self.reader.readElementHeader() orelse return null;
        if (header.id != EBML_ID.EBML) return null;

        var result = EbmlDocInfo{
            .doc_type_buf = [_]u8{0} ** 32,
            .doc_type_len = 8,
            .doc_type_version = 1,
            .doc_type_read_version = 1,
            .ebml_version = 1,
            .ebml_read_version = 1,
        };
        // Default to "matroska"
        @memcpy(result.doc_type_buf[0..8], "matroska");

        // Parse EBML header children
        const header_end = header.data_offset + (header.size orelse return null);
        _ = self.reader.seekTo(header.data_offset);

        while ((self.reader.getPos() orelse header_end) < header_end) {
            const child = self.reader.readElementHeader() orelse break;

            switch (child.id) {
                EBMLHeader_ID.DocType => {
                    // Read directly into fixed buffer
                    const size = child.size orelse 0;
                    if (size > 0 and size <= 32) {
                        _ = self.reader.seekTo(child.data_offset);
                        const bytes_read = self.reader.file.read(result.doc_type_buf[0..@intCast(size)]) catch 0;
                        // Trim null terminator
                        var len = bytes_read;
                        while (len > 0 and result.doc_type_buf[len - 1] == 0) : (len -= 1) {}
                        result.doc_type_len = len;
                    }
                },
                EBMLHeader_ID.DocTypeVersion => {
                    result.doc_type_version = self.reader.readElementUint(child) orelse 1;
                },
                EBMLHeader_ID.DocTypeReadVersion => {
                    result.doc_type_read_version = self.reader.readElementUint(child) orelse 1;
                },
                EBMLHeader_ID.EBMLVersion => {
                    result.ebml_version = self.reader.readElementUint(child) orelse 1;
                },
                EBMLHeader_ID.EBMLReadVersion => {
                    result.ebml_read_version = self.reader.readElementUint(child) orelse 1;
                },
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        return result;
    }

    /// Find and position at the Segment element.
    pub fn findSegment(self: *MatroskaParser) bool {
        // Segment should be right after EBML header
        _ = self.reader.seekTo(0);

        const ebml_header = self.reader.readElementHeader() orelse return false;
        if (ebml_header.id != EBML_ID.EBML) return false;
        _ = self.reader.skipElement(ebml_header);

        const segment = self.reader.readElementHeader() orelse return false;
        if (segment.id != EBML_ID.Segment) return false;

        self.segment_offset = segment.data_offset;
        self.segment_size = segment.size;
        return true;
    }

    /// Find a top-level element within the Segment.
    pub fn findSegmentChild(self: *MatroskaParser, target_id: u32) ?EbmlElement {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return null;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        while ((self.reader.getPos() orelse segment_end) < segment_end) {
            const element = self.reader.readElementHeader() orelse return null;

            if (element.id == target_id) {
                return element;
            }

            // Skip to next element
            if (!self.reader.skipElement(element)) {
                // Unknown size - can't skip
                return null;
            }
        }

        return null;
    }

    /// Parse video tracks from the Tracks element.
    pub fn parseVideoTracks(self: *MatroskaParser, out_tracks: *std.ArrayListUnmanaged(VideoTrackInfo)) !void {
        const tracks_elem = self.findSegmentChild(Segment_ID.Tracks) orelse return;

        const tracks_end = tracks_elem.data_offset + (tracks_elem.size orelse return);
        _ = self.reader.seekTo(tracks_elem.data_offset);

        while ((self.reader.getPos() orelse tracks_end) < tracks_end) {
            const entry = self.reader.readElementHeader() orelse break;

            if (entry.id == Tracks_ID.TrackEntry) {
                if (self.parseTrackEntry(entry)) |track| {
                    try out_tracks.append(track);
                }
            } else {
                _ = self.reader.skipElement(entry);
            }
        }
    }

    /// Parse a single TrackEntry element.
    pub fn parseTrackEntry(self: *MatroskaParser, entry: EbmlElement) ?VideoTrackInfo {
        const entry_end = entry.data_offset + (entry.size orelse return null);
        _ = self.reader.seekTo(entry.data_offset);

        var result = VideoTrackInfo{
            .track_number = 0,
            .track_uid = 0,
            .codec_id_buf = [_]u8{0} ** MAX_CODEC_ID_LEN,
            .codec_id_len = 0,
            .codec_private = null,
            .codec_private_allocator = null,
            .pixel_width = 0,
            .pixel_height = 0,
            .display_width = null,
            .display_height = null,
            .default_duration = null,
            .content_comp_header = null,
            .content_comp_allocator = null,
        };

        var track_type: u8 = 0;
        var has_codec_id = false;

        while ((self.reader.getPos() orelse entry_end) < entry_end) {
            const child = self.reader.readElementHeader() orelse break;

            switch (child.id) {
                TrackEntry_ID.TrackNumber => {
                    result.track_number = self.reader.readElementUint(child) orelse 0;
                },
                TrackEntry_ID.TrackUID => {
                    result.track_uid = self.reader.readElementUint(child) orelse 0;
                },
                TrackEntry_ID.TrackType => {
                    track_type = @intCast(self.reader.readElementUint(child) orelse 0);
                },
                TrackEntry_ID.CodecID => {
                    // Read directly into fixed buffer
                    const size = child.size orelse 0;
                    if (size > 0 and size <= MAX_CODEC_ID_LEN) {
                        _ = self.reader.seekTo(child.data_offset);
                        const bytes_read = self.reader.file.read(result.codec_id_buf[0..@intCast(size)]) catch 0;
                        // Trim null terminator
                        var len = bytes_read;
                        while (len > 0 and result.codec_id_buf[len - 1] == 0) : (len -= 1) {}
                        result.codec_id_len = len;
                        has_codec_id = true;
                    }
                },
                TrackEntry_ID.CodecPrivate => {
                    // This is heap allocated - track the allocator for cleanup
                    result.codec_private = self.reader.readElementData(child, self.allocator);
                    if (result.codec_private != null) {
                        result.codec_private_allocator = self.allocator;
                    }
                },
                TrackEntry_ID.DefaultDuration => {
                    result.default_duration = self.reader.readElementUint(child);
                },
                TrackEntry_ID.Video => {
                    // Parse Video sub-element
                    const video_end = child.data_offset + (child.size orelse 0);
                    _ = self.reader.seekTo(child.data_offset);

                    while ((self.reader.getPos() orelse video_end) < video_end) {
                        const video_child = self.reader.readElementHeader() orelse break;
                        switch (video_child.id) {
                            Video_ID.PixelWidth => {
                                result.pixel_width = self.reader.readElementUint(video_child) orelse 0;
                            },
                            Video_ID.PixelHeight => {
                                result.pixel_height = self.reader.readElementUint(video_child) orelse 0;
                            },
                            Video_ID.DisplayWidth => {
                                result.display_width = self.reader.readElementUint(video_child);
                            },
                            Video_ID.DisplayHeight => {
                                result.display_height = self.reader.readElementUint(video_child);
                            },
                            else => {
                                _ = self.reader.skipElement(video_child);
                            },
                        }
                    }
                },
                TrackEntry_ID.ContentEncodings => {
                    // Parse ContentEncodings → ContentEncoding → ContentCompression
                    // to detect header stripping (algo=3)
                    const enc_end = child.data_offset + (child.size orelse 0);
                    _ = self.reader.seekTo(child.data_offset);

                    while ((self.reader.getPos() orelse enc_end) < enc_end) {
                        const enc_child = self.reader.readElementHeader() orelse break;
                        // ContentEncoding element (0x6240)
                        if (enc_child.id == 0x6240) {
                            const ce_end = enc_child.data_offset + (enc_child.size orelse 0);
                            _ = self.reader.seekTo(enc_child.data_offset);

                            var comp_algo: ?u64 = null;
                            var comp_settings: ?[]const u8 = null;

                            while ((self.reader.getPos() orelse ce_end) < ce_end) {
                                const ce_child = self.reader.readElementHeader() orelse break;
                                if (ce_child.id == ContentEncoding_ID.ContentCompression) {
                                    const cc_end = ce_child.data_offset + (ce_child.size orelse 0);
                                    _ = self.reader.seekTo(ce_child.data_offset);

                                    while ((self.reader.getPos() orelse cc_end) < cc_end) {
                                        const cc_child = self.reader.readElementHeader() orelse break;
                                        switch (cc_child.id) {
                                            ContentCompression_ID.ContentCompAlgo => {
                                                comp_algo = self.reader.readElementUint(cc_child);
                                            },
                                            ContentCompression_ID.ContentCompSettings => {
                                                comp_settings = self.reader.readElementData(cc_child, self.allocator);
                                            },
                                            else => {
                                                _ = self.reader.skipElement(cc_child);
                                            },
                                        }
                                    }
                                } else {
                                    _ = self.reader.skipElement(ce_child);
                                }
                            }

                            // algo=3 means header stripping
                            if (comp_algo != null and comp_algo.? == 3) {
                                if (comp_settings) |settings| {
                                    result.content_comp_header = settings;
                                    result.content_comp_allocator = self.allocator;
                                }
                            } else {
                                // Not header stripping — free settings if allocated
                                if (comp_settings) |settings| {
                                    self.allocator.free(settings);
                                }
                            }
                        } else {
                            _ = self.reader.skipElement(enc_child);
                        }
                    }
                },
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        // Return video and audio tracks (filter out subtitle, logo, complex, etc.)
        if (track_type != @intFromEnum(TrackType.video) and track_type != @intFromEnum(TrackType.audio)) {
            result.deinit(); // Clean up any allocated codec_private
            return null;
        }
        if (!has_codec_id) {
            result.deinit();
            return null;
        }

        return result;
    }

    /// Iterate through Clusters and find keyframes.
    /// Calls the callback for each keyframe found.
    pub fn iterateKeyframes(
        self: *MatroskaParser,
        video_track_number: u64,
        max_keyframes: usize,
        callback: *const fn (data: []const u8, timestamp: i64) bool,
    ) usize {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return 0;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var keyframe_count: usize = 0;
        var current_cluster_timestamp: i64 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end and keyframe_count < max_keyframes) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                // Parse cluster
                const cluster_end = element.data_offset + (element.size orelse break);
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and keyframe_count < max_keyframes) {
                    const cluster_child = self.reader.readElementHeader() orelse break;

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            // Parse SimpleBlock header to check if keyframe
                            if (self.parseSimpleBlock(cluster_child, video_track_number, current_cluster_timestamp, callback)) {
                                keyframe_count += 1;
                            }
                        },
                        Cluster_ID.BlockGroup => {
                            if (self.parseBlockGroup(cluster_child, video_track_number, current_cluster_timestamp, callback)) {
                                keyframe_count += 1;
                            }
                        },
                        else => {
                            _ = self.reader.skipElement(cluster_child);
                        },
                    }
                }
            } else {
                _ = self.reader.skipElement(element);
            }
        }

        return keyframe_count;
    }

    /// Collected keyframe data
    pub const KeyframeData = struct {
        data: []u8,
        timestamp: i64,
        allocator: Allocator,

        pub fn deinit(self: *KeyframeData) void {
            self.allocator.free(self.data);
        }
    };

    pub const FrameValidatorFn = *const fn (?*anyopaque, []const u8) bool;

    /// Collect keyframes into a list.
    /// Returns a list of keyframe data that must be freed by the caller.
    // Previously used for partial validation (keyframe-only checks).
    // Replaced by collectAllFrames for full validation — audio tracks
    // don't set the keyframe flag, causing this to return null.
    // Retained in case keyframe-only collection is ever needed again.
    //
    // pub fn collectKeyframes(
    //     self: *MatroskaParser,
    //     video_track_number: u64,
    //     max_keyframes: usize,
    // ) ?[]KeyframeData {
    //     if (self.segment_offset == 0) {
    //         if (!self.findSegment()) return null;
    //     }
    //
    //     _ = self.reader.seekTo(self.segment_offset);
    //     const segment_end = if (self.segment_size) |s|
    //         self.segment_offset + s
    //     else
    //         self.reader.file_size;
    //
    //     var keyframes: std.ArrayListUnmanaged(KeyframeData) = .{};
    //     errdefer {
    //         for (keyframes.items) |*kf| kf.deinit();
    //         keyframes.deinit(self.allocator);
    //     }
    //
    //     var current_cluster_timestamp: i64 = 0;
    //
    //     while ((self.reader.getPos() orelse segment_end) < segment_end and keyframes.items.len < max_keyframes) {
    //         const element = self.reader.readElementHeader() orelse break;
    //
    //         if (element.id == Segment_ID.Cluster) {
    //             const cluster_end = element.data_offset + (element.size orelse break);
    //             _ = self.reader.seekTo(element.data_offset);
    //
    //             while ((self.reader.getPos() orelse cluster_end) < cluster_end and keyframes.items.len < max_keyframes) {
    //                 const cluster_child = self.reader.readElementHeader() orelse break;
    //
    //                 switch (cluster_child.id) {
    //                     Cluster_ID.Timestamp => {
    //                         current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
    //                     },
    //                     Cluster_ID.SimpleBlock => {
    //                         if (self.extractSimpleBlockKeyframe(cluster_child, video_track_number, current_cluster_timestamp)) |kf| {
    //                             keyframes.append(self.allocator, kf) catch {
    //                                 var mutable_kf = kf;
    //                                 mutable_kf.deinit();
    //                                 continue;
    //                             };
    //                         }
    //                     },
    //                     Cluster_ID.BlockGroup => {
    //                         if (self.extractBlockGroupKeyframe(cluster_child, video_track_number, current_cluster_timestamp)) |kf| {
    //                             keyframes.append(self.allocator, kf) catch {
    //                                 var mutable_kf = kf;
    //                                 mutable_kf.deinit();
    //                                 continue;
    //                             };
    //                         }
    //                     },
    //                     else => {
    //                         _ = self.reader.skipElement(cluster_child);
    //                     },
    //                 }
    //             }
    //         } else {
    //             _ = self.reader.skipElement(element);
    //         }
    //     }
    //
    //     if (keyframes.items.len == 0) {
    //         keyframes.deinit(self.allocator);
    //         return null;
    //     }
    //
    //     return keyframes.toOwnedSlice(self.allocator) catch null;
    // }

    /// Extract keyframe data from a SimpleBlock (returns null if not a keyframe or wrong track)
    fn extractSimpleBlockKeyframe(
        self: *MatroskaParser,
        block: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
    ) ?KeyframeData {
        const size = block.size orelse return null;
        if (size < 4) return null;

        _ = self.reader.seekTo(block.data_offset);

        var header_buf: [16]u8 = undefined;
        const header_read = self.reader.file.read(&header_buf) catch return null;
        if (header_read < 4) return null;

        const track_vint = readVint(&header_buf) orelse return null;
        if (track_vint.value != target_track) return null;

        const header_offset = track_vint.bytes;
        if (header_read < header_offset + 3) return null;

        const rel_timestamp = std.mem.readInt(i16, header_buf[header_offset..][0..2], .big);
        const flags = header_buf[header_offset + 2];

        const is_keyframe = (flags & 0x80) != 0;
        if (!is_keyframe) return null;

        const timestamp = cluster_timestamp + rel_timestamp;
        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 10 * 1024 * 1024) return null;

        const data = self.allocator.alloc(u8, @intCast(data_size)) catch return null;
        errdefer self.allocator.free(data);

        _ = self.reader.seekTo(block.data_offset + data_offset);
        const bytes_read = self.reader.file.readAll(data) catch {
            self.allocator.free(data);
            return null;
        };
        if (bytes_read != data_size) {
            self.allocator.free(data);
            return null;
        }

        return KeyframeData{
            .data = data,
            .timestamp = timestamp,
            .allocator = self.allocator,
        };
    }

    fn walkBlockFrames(
        self: *MatroskaParser,
        block: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
        combine_laced_frames: bool,
        ctx: ?*anyopaque,
        consumer: BlockFrameConsumerFn,
    ) ?usize {
        const size = block.size orelse return null;
        if (size < 4) return null;

        const max_block_bytes: u64 = 50 * 1024 * 1024;
        if (size > max_block_bytes) return null;
        if (size > std.math.maxInt(usize)) return null;

        // Always end at data_offset + size so the cluster-child loop advances
        // correctly, even on the mmap fast path (which otherwise leaves the
        // file position wherever readElementHeader's speculative 12-byte read
        // landed, causing subsequent reads to start mid-block and corrupt the
        // parse). Found by ffmpeg-generated WebM (SimpleBlock 304 bytes → next
        // child attempted 9 bytes past the header → garbage VINTs).
        defer _ = self.reader.seekTo(block.data_offset + size);

        var e1_heap: ?[]u8 = null;
        defer if (e1_heap) |buf| self.allocator.free(buf);
        const data: []const u8 = if (self.reader.file.getMappedRange(block.data_offset, size)) |mapped|
            mapped
        else blk: {
            const buf = self.allocator.alloc(u8, @intCast(size)) catch return null;
            e1_heap = buf;
            _ = self.reader.seekTo(block.data_offset);
            const n = self.reader.file.readAll(buf) catch return null;
            if (n != @as(usize, @intCast(size))) return null;
            break :blk buf[0..n];
        };

        return parseBlockFramesFromBuffer(data, target_track, cluster_timestamp, combine_laced_frames, ctx, consumer);
    }

    fn walkBlockGroupFrames(
        self: *MatroskaParser,
        block_group: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
        combine_laced_frames: bool,
        ctx: ?*anyopaque,
        consumer: BlockFrameConsumerFn,
    ) ?usize {
        const group_size = block_group.size orelse return null;
        const group_end = block_group.data_offset + group_size;

        _ = self.reader.seekTo(block_group.data_offset);

        var block_element: ?EbmlElement = null;

        while ((self.reader.getPos() orelse group_end) < group_end) {
            const child = self.reader.readElementHeader() orelse break;

            switch (child.id) {
                BlockGroup_ID.Block => {
                    block_element = child;
                    _ = self.reader.skipElement(child);
                },
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        defer _ = self.reader.seekTo(group_end);

        const block = block_element orelse return 0;
        return self.walkBlockFrames(block, target_track, cluster_timestamp, combine_laced_frames, ctx, consumer);
    }

    /// Result of frame collection with parsing status
    pub const FrameCollectionResult = struct {
        frames: []KeyframeData,
        completed_normally: bool, // True if parsing reached end of segment
        position_reached: u64, // Position where parsing stopped
        segment_end: u64, // Expected end position

        pub fn deinit(self: *FrameCollectionResult, allocator: Allocator) void {
            for (self.frames) |*f| {
                @constCast(f).deinit();
            }
            allocator.free(self.frames);
        }
    };

    /// Collect ALL frames (not just keyframes) into a list for full validation.
    /// Returns a result struct with frames and parsing status.
    pub fn collectAllFramesWithStatus(
        self: *MatroskaParser,
        target_track_number: u64,
        max_frames: usize,
    ) ?FrameCollectionResult {
        const CollectContext = struct {
            allocator: Allocator,
            frames: *std.ArrayListUnmanaged(KeyframeData),
        };

        const Collector = struct {
            pub fn consume(ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
                const collect: *CollectContext = @ptrCast(@alignCast(ctx.?));
                const data = collect.allocator.alloc(u8, frame.len) catch return false;
                std.mem.copyForwards(u8, data, frame);
                const kf = KeyframeData{
                    .data = data,
                    .timestamp = timestamp,
                    .allocator = collect.allocator,
                };
                collect.frames.append(collect.allocator, kf) catch {
                    collect.allocator.free(data);
                    return false;
                };
                return true;
            }
        };

        if (self.segment_offset == 0) {
            if (!self.findSegment()) return null;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var frames: std.ArrayListUnmanaged(KeyframeData) = .empty;
        errdefer {
            for (frames.items) |*f| f.deinit();
            frames.deinit(self.allocator);
        }
        var collect_ctx = CollectContext{
            .allocator = self.allocator,
            .frames = &frames,
        };

        var current_cluster_timestamp: i64 = 0;
        var parsing_error = false;

        while ((self.reader.getPos() orelse segment_end) < segment_end and frames.items.len < max_frames) {
            const element = self.reader.readElementHeader() orelse {
                parsing_error = true;
                break;
            };

            if (element.id == Segment_ID.Cluster) {
                const cluster_end = element.data_offset + (element.size orelse {
                    parsing_error = true;
                    break;
                });
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and frames.items.len < max_frames) {
                    const cluster_child = self.reader.readElementHeader() orelse {
                        parsing_error = true;
                        break;
                    };

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            if (self.walkBlockFrames(
                                cluster_child,
                                target_track_number,
                                current_cluster_timestamp,
                                false,
                                &collect_ctx,
                                Collector.consume,
                            ) == null) {
                                parsing_error = true;
                                break;
                            }
                        },
                        Cluster_ID.BlockGroup => {
                            if (self.walkBlockGroupFrames(
                                cluster_child,
                                target_track_number,
                                current_cluster_timestamp,
                                false,
                                &collect_ctx,
                                Collector.consume,
                            ) == null) {
                                parsing_error = true;
                                break;
                            }
                        },
                        else => {
                            _ = self.reader.skipElement(cluster_child);
                        },
                    }
                }
                if (parsing_error) break;
                _ = self.reader.seekTo(cluster_end);
            } else {
                if (!self.reader.skipElement(element)) {
                    parsing_error = true;
                    break;
                }
            }
        }

        const final_pos = self.reader.getPos() orelse 0;
        const completed = !parsing_error and (final_pos >= segment_end or frames.items.len >= max_frames);

        if (frames.items.len == 0) {
            frames.deinit(self.allocator);
            return null;
        }

        return FrameCollectionResult{
            .frames = frames.toOwnedSlice(self.allocator) catch return null,
            .completed_normally = completed,
            .position_reached = final_pos,
            .segment_end = segment_end,
        };
    }

    /// Shared segment→cluster→block walk: drives `consumer` over every frame
    /// of `video_track_number` in stream order until `max_frames` frames have
    /// been consumed. Lacing is split per-frame when `combine_laced_frames`
    /// is false. Returns the total frame count, or null if a block was
    /// malformed or the consumer aborted. This is the single walk shared by
    /// the copying collector, the zero-copy ref collector, and walkFrames.
    fn walkTrackFrames(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
        combine_laced_frames: bool,
        ctx: ?*anyopaque,
        consumer: BlockFrameConsumerFn,
    ) ?usize {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return null;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var frames_consumed: usize = 0;
        var current_cluster_timestamp: i64 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end and frames_consumed < max_frames) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                const cluster_end = element.data_offset + (element.size orelse break);
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and frames_consumed < max_frames) {
                    const cluster_child = self.reader.readElementHeader() orelse break;

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            frames_consumed += self.walkBlockFrames(
                                cluster_child,
                                video_track_number,
                                current_cluster_timestamp,
                                combine_laced_frames,
                                ctx,
                                consumer,
                            ) orelse return null;
                        },
                        Cluster_ID.BlockGroup => {
                            frames_consumed += self.walkBlockGroupFrames(
                                cluster_child,
                                video_track_number,
                                current_cluster_timestamp,
                                combine_laced_frames,
                                ctx,
                                consumer,
                            ) orelse return null;
                        },
                        else => {
                            _ = self.reader.skipElement(cluster_child);
                        },
                    }
                }
            } else {
                _ = self.reader.skipElement(element);
            }
        }

        return frames_consumed;
    }

    /// Collect ALL frames (not just keyframes) into a list for full validation.
    /// Returns a list of frame data that must be freed by the caller.
    pub fn collectAllFrames(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
    ) ?[]KeyframeData {
        const CollectContext = struct {
            allocator: Allocator,
            frames: *std.ArrayListUnmanaged(KeyframeData),
        };

        const Collector = struct {
            pub fn consume(ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
                const collect: *CollectContext = @ptrCast(@alignCast(ctx.?));
                const data = collect.allocator.alloc(u8, frame.len) catch return false;
                std.mem.copyForwards(u8, data, frame);
                const kf = KeyframeData{
                    .data = data,
                    .timestamp = timestamp,
                    .allocator = collect.allocator,
                };
                collect.frames.append(collect.allocator, kf) catch {
                    collect.allocator.free(data);
                    return false;
                };
                return true;
            }
        };

        var frames: std.ArrayListUnmanaged(KeyframeData) = .empty;
        var collect_ctx = CollectContext{
            .allocator = self.allocator,
            .frames = &frames,
        };

        const walked = self.walkTrackFrames(video_track_number, max_frames, false, &collect_ctx, Collector.consume);
        if (walked == null or frames.items.len == 0) {
            for (frames.items) |*f| f.deinit();
            frames.deinit(self.allocator);
            return null;
        }

        return frames.toOwnedSlice(self.allocator) catch {
            for (frames.items) |*f| f.deinit();
            frames.deinit(self.allocator);
            return null;
        };
    }

    /// Zero-copy sibling of collectAllFrames: returns slices INTO the source's
    /// mapped/in-memory backing instead of heap copies, so a whole-file frame
    /// walk adds no anonymous memory proportional to file size (the resident
    /// OOM class the streaming_ceiling gate witnesses for VP8/VP9). ONLY valid
    /// when `reader.file.isMapped()` — for file-backed sources the per-block
    /// buffers these slices would point into are freed as each block is
    /// walked, so this returns null there (caller falls back to the copying
    /// collector). Also null on malformed blocks or zero frames. Caller frees
    /// only the returned slice array, never the frame bytes.
    pub fn collectAllFrameRefs(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
    ) ?[]const []const u8 {
        if (!self.reader.file.isMapped()) return null;

        const RefContext = struct {
            allocator: Allocator,
            frames: *std.ArrayListUnmanaged([]const u8),
        };

        const RefCollector = struct {
            pub fn consume(ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
                _ = timestamp;
                const collect: *RefContext = @ptrCast(@alignCast(ctx.?));
                collect.frames.append(collect.allocator, frame) catch return false;
                return true;
            }
        };

        var frames: std.ArrayListUnmanaged([]const u8) = .empty;
        var ref_ctx = RefContext{
            .allocator = self.allocator,
            .frames = &frames,
        };

        const walked = self.walkTrackFrames(video_track_number, max_frames, false, &ref_ctx, RefCollector.consume);
        if (walked == null or frames.items.len == 0) {
            frames.deinit(self.allocator);
            return null;
        }

        return frames.toOwnedSlice(self.allocator) catch {
            frames.deinit(self.allocator);
            return null;
        };
    }

    /// Walk ALL frames (not just keyframes) and validate each frame via callback.
    /// Returns false if any frame fails validation or if no frames are found.
    pub fn walkFrames(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
        ctx: ?*anyopaque,
        validator: FrameValidatorFn,
    ) bool {
        const ValidateContext = struct {
            ctx: ?*anyopaque,
            validator: FrameValidatorFn,
        };

        const Adapter = struct {
            pub fn consume(opaque_ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
                _ = timestamp;
                const validate: *ValidateContext = @ptrCast(@alignCast(opaque_ctx.?));
                return validate.validator(validate.ctx, frame);
            }
        };

        var validate_ctx = ValidateContext{
            .ctx = ctx,
            .validator = validator,
        };

        const walked = self.walkTrackFrames(video_track_number, max_frames, true, &validate_ctx, Adapter.consume) orelse return false;
        return walked > 0;
    }

    /// Debug: emit details for the first frame that fails byte validation.
    pub fn debugFirstInvalidFrame(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
        ctx: ?*anyopaque,
        validator: FrameValidatorFn,
        writer: std.Io.File,
        frame_dump: ?std.Io.File,
    ) void {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) {
                writeFmt(writer, "MKV debug: failed to find Segment\n", .{});
                return;
            }
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var frames_validated: usize = 0;
        var current_cluster_timestamp: i64 = 0;

        const DebugContext = struct {
            ctx: ?*anyopaque,
            validator: FrameValidatorFn,
            failed: bool = false,
            failed_frame_index: usize = 0,
            failed_frame_len: usize = 0,
            preview: [64]u8 = [_]u8{0} ** 64,
            preview_len: usize = 0,
            failed_frame: ?[]const u8 = null,
            frame_index: usize = 0,
        };

        const DebugConsumer = struct {
            pub fn consume(opaque_ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
                _ = timestamp;
                const debug: *DebugContext = @ptrCast(@alignCast(opaque_ctx.?));
                const ok = debug.validator(debug.ctx, frame);
                if (!ok) {
                    debug.failed = true;
                    debug.failed_frame_index = debug.frame_index;
                    debug.failed_frame_len = frame.len;
                    debug.preview_len = @min(frame.len, debug.preview.len);
                    std.mem.copyForwards(u8, debug.preview[0..debug.preview_len], frame[0..debug.preview_len]);
                    debug.failed_frame = frame;
                }
                debug.frame_index += 1;
                return ok;
            }
        };

        while ((self.reader.getPos() orelse segment_end) < segment_end and frames_validated < max_frames) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id != Segment_ID.Cluster) {
                _ = self.reader.skipElement(element);
                continue;
            }

            const cluster_end = element.data_offset + (element.size orelse break);
            _ = self.reader.seekTo(element.data_offset);

            while ((self.reader.getPos() orelse cluster_end) < cluster_end and frames_validated < max_frames) {
                const cluster_child = self.reader.readElementHeader() orelse break;

                switch (cluster_child.id) {
                    Cluster_ID.Timestamp => {
                        current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                    },
                    Cluster_ID.SimpleBlock => {
                        const size = cluster_child.size orelse return;
                        if (size == 0 or size > 50 * 1024 * 1024) return;
                        if (size > std.math.maxInt(usize)) return;

                        var sb_heap: ?[]u8 = null;
                        defer if (sb_heap) |buf| self.allocator.free(buf);
                        const data: []const u8 = if (self.reader.file.getMappedRange(cluster_child.data_offset, size)) |mapped|
                            mapped
                        else blk: {
                            const buf = self.allocator.alloc(u8, @intCast(size)) catch return;
                            sb_heap = buf;
                            _ = self.reader.seekTo(cluster_child.data_offset);
                            const n = self.reader.file.readAll(buf) catch return;
                            if (n != @as(usize, @intCast(size))) return;
                            break :blk buf[0..n];
                        };

                        var debug_ctx = DebugContext{ .ctx = ctx, .validator = validator };
                        const result = parseBlockFramesFromBuffer(data, video_track_number, current_cluster_timestamp, true, &debug_ctx, DebugConsumer.consume);
                        if (result == null) {
                            writeFmt(writer, "MKV debug: SimpleBlock parse/validate failed\n", .{});
                            if (parseBlockHeader(data)) |header| {
                                writeFmt(
                                    writer,
                                    "  track={} rel_ts={} flags=0x{x:0>2} lacing={} header_bytes={}\n",
                                    .{ header.track_number, header.rel_timestamp, header.flags, header.lacing, header.header_bytes },
                                );
                            } else {
                                writeFmt(writer, "  header parse failed\n", .{});
                            }
                            if (debug_ctx.failed) {
                                writeFmt(
                                    writer,
                                    "  failed_frame_index={} failed_frame_len={}\n",
                                    .{ debug_ctx.failed_frame_index, debug_ctx.failed_frame_len },
                                );
                                writeFmt(writer, "  failed_frame_preview:", .{});
                                for (debug_ctx.preview[0..debug_ctx.preview_len]) |b| {
                                    writeFmt(writer, " {x:0>2}", .{b});
                                }
                                writeFmt(writer, "\n", .{});
                                if (frame_dump) |dump| {
                                    if (debug_ctx.failed_frame) |frame| {
                                        dump.writePositionalAll(runtime.io(), frame, 0) catch {};
                                    }
                                }
                            }
                            return;
                        }
                        frames_validated += result.?;
                    },
                    Cluster_ID.BlockGroup => {
                        const group_size = cluster_child.size orelse return;
                        const group_end = cluster_child.data_offset + group_size;

                        _ = self.reader.seekTo(cluster_child.data_offset);
                        var block_element: ?EbmlElement = null;
                        while ((self.reader.getPos() orelse group_end) < group_end) {
                            const child = self.reader.readElementHeader() orelse break;
                            switch (child.id) {
                                BlockGroup_ID.Block => {
                                    block_element = child;
                                    _ = self.reader.skipElement(child);
                                },
                                else => {
                                    _ = self.reader.skipElement(child);
                                },
                            }
                        }
                        const block = block_element orelse continue;
                        const size = block.size orelse continue;
                        if (size == 0 or size > 50 * 1024 * 1024) return;
                        if (size > std.math.maxInt(usize)) return;

                        var bg_heap: ?[]u8 = null;
                        defer if (bg_heap) |buf| self.allocator.free(buf);
                        const data: []const u8 = if (self.reader.file.getMappedRange(block.data_offset, size)) |mapped|
                            mapped
                        else blk: {
                            const buf = self.allocator.alloc(u8, @intCast(size)) catch return;
                            bg_heap = buf;
                            _ = self.reader.seekTo(block.data_offset);
                            const n = self.reader.file.readAll(buf) catch return;
                            if (n != @as(usize, @intCast(size))) return;
                            break :blk buf[0..n];
                        };

                        var debug_ctx = DebugContext{ .ctx = ctx, .validator = validator };
                        const result = parseBlockFramesFromBuffer(data, video_track_number, current_cluster_timestamp, true, &debug_ctx, DebugConsumer.consume);
                        if (result == null) {
                            writeFmt(writer, "MKV debug: BlockGroup/Block parse/validate failed\n", .{});
                            if (parseBlockHeader(data)) |header| {
                                writeFmt(
                                    writer,
                                    "  track={} rel_ts={} flags=0x{x:0>2} lacing={} header_bytes={}\n",
                                    .{ header.track_number, header.rel_timestamp, header.flags, header.lacing, header.header_bytes },
                                );
                            } else {
                                writeFmt(writer, "  header parse failed\n", .{});
                            }
                            if (debug_ctx.failed) {
                                writeFmt(
                                    writer,
                                    "  failed_frame_index={} failed_frame_len={}\n",
                                    .{ debug_ctx.failed_frame_index, debug_ctx.failed_frame_len },
                                );
                                writeFmt(writer, "  failed_frame_preview:", .{});
                                for (debug_ctx.preview[0..debug_ctx.preview_len]) |b| {
                                    writeFmt(writer, " {x:0>2}", .{b});
                                }
                                writeFmt(writer, "\n", .{});
                                if (frame_dump) |dump| {
                                    if (debug_ctx.failed_frame) |frame| {
                                        dump.writePositionalAll(runtime.io(), frame, 0) catch {};
                                    }
                                }
                            }
                            return;
                        }
                        frames_validated += result.?;
                    },
                    else => {
                        _ = self.reader.skipElement(cluster_child);
                    },
                }
            }
        }

        if (frames_validated == 0) {
            writeFmt(writer, "MKV debug: no frames validated for target track {}\n", .{video_track_number});
        }
    }

    /// Parse a SimpleBlock and call callback if it's a keyframe for the target track.
    fn parseSimpleBlock(
        self: *MatroskaParser,
        block: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
        callback: *const fn (data: []const u8, timestamp: i64) bool,
    ) bool {
        const size = block.size orelse return false;
        if (size < 4) return false;

        _ = self.reader.seekTo(block.data_offset);

        // Read SimpleBlock header: track number (VINT) + timestamp (2 bytes) + flags (1 byte)
        var header_buf: [16]u8 = undefined;
        const header_read = self.reader.file.read(&header_buf) catch return false;
        if (header_read < 4) return false;

        // Track number is a VINT
        const track_vint = readVint(&header_buf) orelse return false;
        if (track_vint.value != target_track) return false;

        const header_offset = track_vint.bytes;
        if (header_read < header_offset + 3) return false;

        // Relative timestamp (signed 16-bit)
        const rel_timestamp = std.mem.readInt(i16, header_buf[header_offset..][0..2], .big);
        const flags = header_buf[header_offset + 2];

        // Check keyframe flag (bit 7)
        const is_keyframe = (flags & 0x80) != 0;
        if (!is_keyframe) return false;

        // Calculate absolute timestamp
        const timestamp = cluster_timestamp + rel_timestamp;

        // Read frame data
        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 10 * 1024 * 1024) return false; // Limit to 10MB per frame

        var e2_heap: ?[]u8 = null;
        defer if (e2_heap) |buf| self.allocator.free(buf);
        const data: []const u8 = if (self.reader.file.getMappedRange(block.data_offset + data_offset, data_size)) |mapped|
            mapped
        else blk: {
            const buf = self.allocator.alloc(u8, @intCast(data_size)) catch return false;
            e2_heap = buf;
            _ = self.reader.seekTo(block.data_offset + data_offset);
            const n = self.reader.file.readAll(buf) catch return false;
            if (n != data_size) return false;
            break :blk buf[0..n];
        };

        return callback(data, timestamp);
    }

    /// Extract keyframe data from a BlockGroup (returns null if not a keyframe or wrong track).
    /// BlockGroup keyframes are identified by the absence of ReferenceBlock elements.
    fn extractBlockGroupKeyframe(
        self: *MatroskaParser,
        block_group: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
    ) ?KeyframeData {
        const group_size = block_group.size orelse return null;
        const group_end = block_group.data_offset + group_size;

        _ = self.reader.seekTo(block_group.data_offset);

        var block_element: ?EbmlElement = null;
        var has_reference: bool = false;

        // Parse BlockGroup children to find Block and check for ReferenceBlock
        while ((self.reader.getPos() orelse group_end) < group_end) {
            const child = self.reader.readElementHeader() orelse break;

            switch (child.id) {
                BlockGroup_ID.Block => {
                    block_element = child;
                    _ = self.reader.skipElement(child);
                },
                BlockGroup_ID.ReferenceBlock => {
                    // If ReferenceBlock exists, this is NOT a keyframe
                    has_reference = true;
                    _ = self.reader.skipElement(child);
                },
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        // Not a keyframe if it has reference frames
        if (has_reference) return null;

        const block = block_element orelse return null;
        const size = block.size orelse return null;
        if (size < 4) return null;

        _ = self.reader.seekTo(block.data_offset);

        var header_buf: [16]u8 = undefined;
        const header_read = self.reader.file.read(&header_buf) catch return null;
        if (header_read < 4) return null;

        // Track number is a VINT
        const track_vint = readVint(&header_buf) orelse return null;
        if (track_vint.value != target_track) return null;

        const header_offset = track_vint.bytes;
        if (header_read < header_offset + 3) return null;

        // Relative timestamp (signed 16-bit)
        const rel_timestamp = std.mem.readInt(i16, header_buf[header_offset..][0..2], .big);
        // Block has flags byte like SimpleBlock but keyframe is determined by ReferenceBlock absence

        const timestamp = cluster_timestamp + rel_timestamp;
        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 10 * 1024 * 1024) return null;

        const data = self.allocator.alloc(u8, @intCast(data_size)) catch return null;
        errdefer self.allocator.free(data);

        _ = self.reader.seekTo(block.data_offset + data_offset);
        const bytes_read = self.reader.file.readAll(data) catch {
            self.allocator.free(data);
            return null;
        };
        if (bytes_read != data_size) {
            self.allocator.free(data);
            return null;
        }

        return KeyframeData{
            .data = data,
            .timestamp = timestamp,
            .allocator = self.allocator,
        };
    }

    /// Parse a BlockGroup and call callback if it's a keyframe for the target track.
    /// BlockGroup keyframes are identified by the absence of ReferenceBlock elements.
    fn parseBlockGroup(
        self: *MatroskaParser,
        block_group: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
        callback: *const fn (data: []const u8, timestamp: i64) bool,
    ) bool {
        const group_size = block_group.size orelse return false;
        const group_end = block_group.data_offset + group_size;

        _ = self.reader.seekTo(block_group.data_offset);

        var block_element: ?EbmlElement = null;
        var has_reference: bool = false;

        // Parse BlockGroup children to find Block and check for ReferenceBlock
        while ((self.reader.getPos() orelse group_end) < group_end) {
            const child = self.reader.readElementHeader() orelse break;

            switch (child.id) {
                BlockGroup_ID.Block => {
                    block_element = child;
                    _ = self.reader.skipElement(child);
                },
                BlockGroup_ID.ReferenceBlock => {
                    has_reference = true;
                    _ = self.reader.skipElement(child);
                },
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        // Not a keyframe if it has reference frames
        if (has_reference) return false;

        const block = block_element orelse return false;
        const size = block.size orelse return false;
        if (size < 4) return false;

        _ = self.reader.seekTo(block.data_offset);

        var header_buf: [16]u8 = undefined;
        const header_read = self.reader.file.read(&header_buf) catch return false;
        if (header_read < 4) return false;

        const track_vint = readVint(&header_buf) orelse return false;
        if (track_vint.value != target_track) return false;

        const header_offset = track_vint.bytes;
        if (header_read < header_offset + 3) return false;

        const rel_timestamp = std.mem.readInt(i16, header_buf[header_offset..][0..2], .big);
        const timestamp = cluster_timestamp + rel_timestamp;

        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 10 * 1024 * 1024) return false;

        var e3_heap: ?[]u8 = null;
        defer if (e3_heap) |buf| self.allocator.free(buf);
        const data: []const u8 = if (self.reader.file.getMappedRange(block.data_offset + data_offset, data_size)) |mapped|
            mapped
        else blk: {
            const buf = self.allocator.alloc(u8, @intCast(data_size)) catch return false;
            e3_heap = buf;
            _ = self.reader.seekTo(block.data_offset + data_offset);
            const n = self.reader.file.readAll(buf) catch return false;
            if (n != data_size) return false;
            break :blk buf[0..n];
        };

        return callback(data, timestamp);
    }

    /// Result of MKV CRC verification
    pub const CrcVerifyResult = struct {
        valid: bool,
        clusters_checked: u32,
        clusters_with_crc: u32,
        error_message: ?[]const u8,

        pub fn ok(checked: u32, with_crc: u32) CrcVerifyResult {
            return .{
                .valid = true,
                .clusters_checked = checked,
                .clusters_with_crc = with_crc,
                .error_message = null,
            };
        }

        pub fn invalid(msg: []const u8, checked: u32, with_crc: u32) CrcVerifyResult {
            return .{
                .valid = false,
                .clusters_checked = checked,
                .clusters_with_crc = with_crc,
                .error_message = msg,
            };
        }

        pub fn noCrc(checked: u32) CrcVerifyResult {
            return .{
                .valid = true, // Not a failure, just no CRCs present
                .clusters_checked = checked,
                .clusters_with_crc = 0,
                .error_message = null,
            };
        }

        /// Returns true if all clusters had CRCs (100% coverage)
        pub fn hasFullCoverage(self: *const CrcVerifyResult) bool {
            return self.clusters_with_crc > 0 and self.clusters_with_crc == self.clusters_checked;
        }
    };

    /// Verify CRC-32 elements in all Clusters.
    /// Returns verification result indicating whether CRCs are present and valid.
    pub fn verifyCluterCrcs(self: *MatroskaParser) CrcVerifyResult {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) {
                return CrcVerifyResult.invalid("No segment found", 0, 0);
            }
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var clusters_checked: u32 = 0;
        var clusters_with_crc: u32 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                clusters_checked += 1;
                const cluster_size = element.size orelse continue;
                const cluster_end = element.data_offset + cluster_size;

                // Check first child for CRC-32 element
                _ = self.reader.seekTo(element.data_offset);
                const first_child = self.reader.readElementHeader() orelse continue;

                if (first_child.id == EBML_ID.CRC32) {
                    clusters_with_crc += 1;

                    // Read stored CRC value (4 bytes, little-endian)
                    // Must seek to data_offset since readElementHeader leaves file position past it
                    _ = self.reader.seekTo(first_child.data_offset);
                    var crc_buf: [4]u8 = undefined;
                    const crc_read = self.reader.file.read(&crc_buf) catch continue;
                    if (crc_read < 4) continue;
                    const stored_crc = std.mem.readInt(u32, &crc_buf, .little);

                    // Calculate CRC of remaining cluster data
                    const data_start = first_child.data_offset + 4; // After CRC element
                    const data_len = cluster_end - data_start;

                    if (data_len > 100 * 1024 * 1024) continue; // Skip huge clusters

                    // Read and compute CRC
                    _ = self.reader.seekTo(data_start);
                    var crc_state = std.hash.Crc32.init();

                    var remaining = data_len;
                    var buf: [8192]u8 = undefined;
                    while (remaining > 0) {
                        const to_read = @min(remaining, buf.len);
                        const bytes = self.reader.file.read(buf[0..to_read]) catch break;
                        if (bytes == 0) break;

                        crc_state.update(buf[0..bytes]);
                        remaining -= bytes;
                    }

                    const computed_crc = crc_state.final();

                    if (computed_crc != stored_crc) {
                        return CrcVerifyResult.invalid("CRC mismatch in cluster", clusters_checked, clusters_with_crc);
                    }
                }

                // Move to next element after cluster
                _ = self.reader.seekTo(cluster_end);
            } else {
                _ = self.reader.skipElement(element);
            }
        }

        if (clusters_checked == 0) {
            return CrcVerifyResult.invalid("No clusters found", 0, 0);
        }

        if (clusters_with_crc == 0) {
            return CrcVerifyResult.noCrc(clusters_checked);
        }

        return CrcVerifyResult.ok(clusters_checked, clusters_with_crc);
    }
};


// ============ Tests ============

test "VINT parsing" {
    // 1-byte VINT: 0x81 = 1
    const vint1 = readVint(&[_]u8{0x81});
    try std.testing.expect(vint1 != null);
    try std.testing.expectEqual(@as(u64, 1), vint1.?.value);
    try std.testing.expectEqual(@as(usize, 1), vint1.?.bytes);

    // 2-byte VINT: 0x40 0x01 = 1
    const vint2 = readVint(&[_]u8{ 0x40, 0x01 });
    try std.testing.expect(vint2 != null);
    try std.testing.expectEqual(@as(u64, 1), vint2.?.value);
    try std.testing.expectEqual(@as(usize, 2), vint2.?.bytes);

    // Element ID parsing
    const id1 = readElementId(&[_]u8{0xA3}); // SimpleBlock
    try std.testing.expect(id1 != null);
    try std.testing.expectEqual(@as(u32, 0xA3), id1.?.id);
}

test "Element ID constants" {
    try std.testing.expectEqual(@as(u32, 0x1A45DFA3), EBML_ID.EBML);
    try std.testing.expectEqual(@as(u32, 0x18538067), EBML_ID.Segment);
    try std.testing.expectEqual(@as(u32, 0x1654AE6B), Segment_ID.Tracks);
}

test "parseBlockFramesFromBuffer Xiph lacing" {
    const data = [_]u8{
        0x81, // track 1
        0x00, 0x00, // timecode
        0x02, // flags: Xiph lacing
        0x01, // lace count (2 frames)
        0x03, // size of first frame
        0x11, 0x22, 0x33, // frame 1
        0x44, 0x55, // frame 2
    };

    const Ctx = struct {
        frames: [2][]const u8 = undefined,
        count: usize = 0,
        timestamp: i64 = 0,
    };

    const Collector = struct {
        pub fn consume(ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
            const collect: *Ctx = @ptrCast(@alignCast(ctx.?));
            collect.frames[collect.count] = frame;
            collect.count += 1;
            collect.timestamp = timestamp;
            return true;
        }
    };

    var ctx = Ctx{};
    const count = parseBlockFramesFromBuffer(&data, 1, 100, false, &ctx, Collector.consume) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    try std.testing.expectEqual(@as(i64, 100), ctx.timestamp);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33 }, ctx.frames[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x44, 0x55 }, ctx.frames[1]);
}

test "parseBlockFramesFromBuffer EBML lacing" {
    const data = [_]u8{
        0x81, // track 1
        0x00, 0x01, // timecode
        0x06, // flags: EBML lacing
        0x02, // lace count (3 frames)
        0x84, // size 4
        0xC0, // delta +1 (size 5)
        0x01, 0x02, 0x03, 0x04, // frame 1 (4 bytes)
        0x05, 0x06, 0x07, 0x08, 0x09, // frame 2 (5 bytes)
        0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, // frame 3 (6 bytes)
    };

    const Ctx = struct {
        frames: [3][]const u8 = undefined,
        count: usize = 0,
        timestamp: i64 = 0,
    };

    const Collector = struct {
        pub fn consume(ctx: ?*anyopaque, frame: []const u8, timestamp: i64) bool {
            const collect: *Ctx = @ptrCast(@alignCast(ctx.?));
            collect.frames[collect.count] = frame;
            collect.count += 1;
            collect.timestamp = timestamp;
            return true;
        }
    };

    var ctx = Ctx{};
    const count = parseBlockFramesFromBuffer(&data, 1, 100, false, &ctx, Collector.consume) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 3), ctx.count);
    try std.testing.expectEqual(@as(i64, 101), ctx.timestamp);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, ctx.frames[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x05, 0x06, 0x07, 0x08, 0x09 }, ctx.frames[1]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F }, ctx.frames[2]);
}

test "parseBlockHeader basic fields" {
    const data = [_]u8{
        0x81, // track 1
        0xFF, 0xFE, // rel timestamp -2
        0x02, // flags: Xiph lacing
        0x00,
    };

    const header = parseBlockHeader(&data) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 1), header.track_number);
    try std.testing.expectEqual(@as(i16, -2), header.rel_timestamp);
    try std.testing.expectEqual(@as(u8, 0x02), header.flags);
    try std.testing.expectEqual(@as(u2, 1), header.lacing);
    try std.testing.expectEqual(@as(usize, 4), header.header_bytes);
}

// MFIC differential: the zero-copy frame walk (collectAllFrameRefs) must yield
// byte-identical frames, in identical order, to the copying collector
// (collectAllFrames) whose behavior the corruption sweeps certified. The refs
// variant exists so VP8/VP9 decode validation can stream a whole file without
// duplicating every compressed frame into anonymous memory (the OOM class the
// streaming_ceiling gate witnesses on 2GiB fixtures at a 512MiB ceiling).
test "collectAllFrameRefs matches collectAllFrames byte-for-byte on committed VP9 fixture" {
    const path = "tests/fixtures/vp9/vp9_multikf.webm";
    const file = runtime.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer file.close(runtime.io());
    const stat = try file.stat(runtime.io());
    const data = try std.testing.allocator.alloc(u8, @intCast(stat.size));
    defer std.testing.allocator.free(data);
    const n = try file.readPositionalAll(runtime.io(), data, 0);
    try std.testing.expect(n == data.len);

    // Locate the first video track number by parsing the Tracks element.
    var source_a = FileSource.fromBuffer(data);
    var parser_a = MatroskaParser.init(std.testing.allocator, &source_a);
    _ = parser_a.parseEbmlHeader() orelse return error.TestUnexpectedResult;
    const tracks_elem = parser_a.findSegmentChild(Segment_ID.Tracks) orelse return error.TestUnexpectedResult;
    _ = parser_a.reader.seekTo(tracks_elem.data_offset);
    const entry = parser_a.reader.readElementHeader() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Tracks_ID.TrackEntry, entry.id);
    var track = parser_a.parseTrackEntry(entry) orelse return error.TestUnexpectedResult;
    defer track.deinit();

    const copied = parser_a.collectAllFrames(track.track_number, std.math.maxInt(u32)) orelse
        return error.TestUnexpectedResult;
    defer {
        for (copied) |*f| {
            var mutable_f = @constCast(f);
            mutable_f.deinit();
        }
        std.testing.allocator.free(copied);
    }

    var source_b = FileSource.fromBuffer(data);
    var parser_b = MatroskaParser.init(std.testing.allocator, &source_b);
    const refs = parser_b.collectAllFrameRefs(track.track_number, std.math.maxInt(u32)) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(refs);

    try std.testing.expect(copied.len > 1);
    try std.testing.expectEqual(copied.len, refs.len);
    for (copied, refs) |kf, ref| {
        try std.testing.expectEqualSlices(u8, kf.data, ref);
    }
}
