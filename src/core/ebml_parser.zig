//! EBML (Extensible Binary Meta Language) parser for Matroska/WebM.
//!
//! EBML is a binary format using variable-length integers for element IDs and sizes.
//! This parser provides low-level EBML primitives and high-level Matroska structure parsing.
//!
//! Reference: https://www.matroska.org/technical/elements.html
//! EBML spec: https://github.com/ietf-wg-cellar/ebml-specification

const std = @import("std");
const Allocator = std.mem.Allocator;

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

/// Streaming EBML reader that works with file handles.
pub const EbmlReader = struct {
    file: std.fs.File,
    file_size: u64,

    pub fn init(file: std.fs.File) EbmlReader {
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

    pub fn init(allocator: Allocator, file: std.fs.File) MatroskaParser {
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
                else => {
                    _ = self.reader.skipElement(child);
                },
            }
        }

        // Only return video tracks
        if (track_type != @intFromEnum(TrackType.video)) {
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
    pub fn collectKeyframes(
        self: *MatroskaParser,
        video_track_number: u64,
        max_keyframes: usize,
    ) ?[]KeyframeData {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return null;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var keyframes: std.ArrayListUnmanaged(KeyframeData) = .{};
        errdefer {
            for (keyframes.items) |*kf| kf.deinit();
            keyframes.deinit(self.allocator);
        }

        var current_cluster_timestamp: i64 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end and keyframes.items.len < max_keyframes) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                const cluster_end = element.data_offset + (element.size orelse break);
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and keyframes.items.len < max_keyframes) {
                    const cluster_child = self.reader.readElementHeader() orelse break;

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            if (self.extractSimpleBlockKeyframe(cluster_child, video_track_number, current_cluster_timestamp)) |kf| {
                                keyframes.append(self.allocator, kf) catch {
                                    var mutable_kf = kf;
                                    mutable_kf.deinit();
                                    continue;
                                };
                            }
                        },
                        Cluster_ID.BlockGroup => {
                            if (self.extractBlockGroupKeyframe(cluster_child, video_track_number, current_cluster_timestamp)) |kf| {
                                keyframes.append(self.allocator, kf) catch {
                                    var mutable_kf = kf;
                                    mutable_kf.deinit();
                                    continue;
                                };
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

        if (keyframes.items.len == 0) {
            keyframes.deinit(self.allocator);
            return null;
        }

        return keyframes.toOwnedSlice(self.allocator) catch null;
    }

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

    /// Extract frame data from ANY SimpleBlock (not just keyframes)
    fn extractSimpleBlockFrame(
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
        // Note: NOT checking keyframe flag - we want ALL frames

        const timestamp = cluster_timestamp + rel_timestamp;
        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 50 * 1024 * 1024) return null; // 50MB limit per frame

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

    /// Extract frame data from ANY BlockGroup block (not just keyframes)
    fn extractBlockGroupFrame(
        self: *MatroskaParser,
        block_group: EbmlElement,
        target_track: u64,
        cluster_timestamp: i64,
    ) ?KeyframeData {
        const group_size = block_group.size orelse return null;
        const group_end = block_group.data_offset + group_size;

        _ = self.reader.seekTo(block_group.data_offset);

        var block_element: ?EbmlElement = null;

        // Parse BlockGroup children to find Block (we want ALL frames, not just keyframes)
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

        const block = block_element orelse return null;
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

        const timestamp = cluster_timestamp + rel_timestamp;
        const data_offset = header_offset + 3;
        const data_size = size - data_offset;

        if (data_size > 50 * 1024 * 1024) return null;

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

    /// Collect ALL frames (not just keyframes) into a list for full validation.
    /// Returns a list of frame data that must be freed by the caller.
    pub fn collectAllFrames(
        self: *MatroskaParser,
        video_track_number: u64,
        max_frames: usize,
    ) ?[]KeyframeData {
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return null;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var frames: std.ArrayListUnmanaged(KeyframeData) = .{};
        errdefer {
            for (frames.items) |*f| f.deinit();
            frames.deinit(self.allocator);
        }

        var current_cluster_timestamp: i64 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end and frames.items.len < max_frames) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                const cluster_end = element.data_offset + (element.size orelse break);
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and frames.items.len < max_frames) {
                    const cluster_child = self.reader.readElementHeader() orelse break;

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            if (self.extractSimpleBlockFrame(cluster_child, video_track_number, current_cluster_timestamp)) |frame| {
                                frames.append(self.allocator, frame) catch {
                                    var mutable_frame = frame;
                                    mutable_frame.deinit();
                                    continue;
                                };
                            }
                        },
                        Cluster_ID.BlockGroup => {
                            if (self.extractBlockGroupFrame(cluster_child, video_track_number, current_cluster_timestamp)) |frame| {
                                frames.append(self.allocator, frame) catch {
                                    var mutable_frame = frame;
                                    mutable_frame.deinit();
                                    continue;
                                };
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

        if (frames.items.len == 0) {
            frames.deinit(self.allocator);
            return null;
        }

        return frames.toOwnedSlice(self.allocator) catch null;
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
        if (self.segment_offset == 0) {
            if (!self.findSegment()) return false;
        }

        _ = self.reader.seekTo(self.segment_offset);
        const segment_end = if (self.segment_size) |s|
            self.segment_offset + s
        else
            self.reader.file_size;

        var frames_validated: usize = 0;
        var current_cluster_timestamp: i64 = 0;

        while ((self.reader.getPos() orelse segment_end) < segment_end and frames_validated < max_frames) {
            const element = self.reader.readElementHeader() orelse break;

            if (element.id == Segment_ID.Cluster) {
                const cluster_end = element.data_offset + (element.size orelse break);
                _ = self.reader.seekTo(element.data_offset);

                while ((self.reader.getPos() orelse cluster_end) < cluster_end and frames_validated < max_frames) {
                    const cluster_child = self.reader.readElementHeader() orelse break;

                    switch (cluster_child.id) {
                        Cluster_ID.Timestamp => {
                            current_cluster_timestamp = @intCast(self.reader.readElementUint(cluster_child) orelse 0);
                        },
                        Cluster_ID.SimpleBlock => {
                            if (self.extractSimpleBlockFrame(cluster_child, video_track_number, current_cluster_timestamp)) |frame| {
                                if (!validator(ctx, frame.data)) {
                                    var mutable_frame = frame;
                                    mutable_frame.deinit();
                                    return false;
                                }
                                var mutable_frame = frame;
                                mutable_frame.deinit();
                                frames_validated += 1;
                            }
                        },
                        Cluster_ID.BlockGroup => {
                            if (self.extractBlockGroupFrame(cluster_child, video_track_number, current_cluster_timestamp)) |frame| {
                                if (!validator(ctx, frame.data)) {
                                    var mutable_frame = frame;
                                    mutable_frame.deinit();
                                    return false;
                                }
                                var mutable_frame = frame;
                                mutable_frame.deinit();
                                frames_validated += 1;
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

        return frames_validated > 0;
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

        const data = self.allocator.alloc(u8, @intCast(data_size)) catch return false;
        defer self.allocator.free(data);

        _ = self.reader.seekTo(block.data_offset + data_offset);
        const bytes_read = self.reader.file.readAll(data) catch return false;
        if (bytes_read != data_size) return false;

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

        const data = self.allocator.alloc(u8, @intCast(data_size)) catch return false;
        defer self.allocator.free(data);

        _ = self.reader.seekTo(block.data_offset + data_offset);
        const bytes_read = self.reader.file.readAll(data) catch return false;
        if (bytes_read != data_size) return false;

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
                    var computed_crc: u32 = 0xFFFFFFFF;

                    var remaining = data_len;
                    var buf: [8192]u8 = undefined;
                    while (remaining > 0) {
                        const to_read = @min(remaining, buf.len);
                        const bytes = self.reader.file.read(buf[0..to_read]) catch break;
                        if (bytes == 0) break;

                        for (buf[0..bytes]) |byte| {
                            computed_crc = crc32_table[(computed_crc ^ byte) & 0xFF] ^ (computed_crc >> 8);
                        }
                        remaining -= bytes;
                    }

                    computed_crc ^= 0xFFFFFFFF;

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

/// CRC-32 lookup table (polynomial 0x04C11DB7, reflected)
/// Same polynomial as OGG/ISO-HDLC
const crc32_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @intCast(i);
        for (0..8) |_| {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc = crc >> 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
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
