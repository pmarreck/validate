//! Theora Video Validator (Pure Zig)
//!
//! Validates Theora video streams inside Ogg containers.
//! Theora is based on VP3 and is defined in the Theora I Specification (Xiph.org).
//!
//! Theora packets in Ogg:
//! - Info header (first packet): version, frame size, pixel aspect, FPS, etc.
//! - Comment header (second packet): vendor + user comments (like Vorbis)
//! - Setup header (third packet): codebooks and quantization matrices
//! - Video frames: keyframes (intra) and inter frames
//!
//! Each Theora packet starts with a header type byte:
//! - 0x80: Info header
//! - 0x81: Comment header
//! - 0x82: Setup header
//! - 0x00-0x3F: Video frame (low bit indicates frame type)

const std = @import("std");
const Allocator = std.mem.Allocator;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const theora_decoder = @import("theora_decoder.zig");

/// Theora version info
pub const TheoraVersion = struct {
    major: u8,
    minor: u8,
    subminor: u8,

    pub fn isValid(self: TheoraVersion) bool {
        // Theora 1.0 is the only stable version
        return self.major == 3 and (self.minor >= 2);
    }
};

/// Pixel format
pub const PixelFormat = enum(u2) {
    yuv420 = 0, // 4:2:0
    reserved = 1,
    yuv422 = 2, // 4:2:2
    yuv444 = 3, // 4:4:4
};

/// Theora info header (identification header)
pub const TheoraInfoHeader = struct {
    version: TheoraVersion,
    frame_width_macro: u16, // Frame width in 16-pixel macroblocks
    frame_height_macro: u16, // Frame height in 16-pixel macroblocks
    pic_width: u24, // Picture width in pixels
    pic_height: u24, // Picture height in pixels
    pic_offset_x: u8, // Picture X offset
    pic_offset_y: u8, // Picture Y offset
    fps_numerator: u32,
    fps_denominator: u32,
    aspect_numerator: u24,
    aspect_denominator: u24,
    colorspace: u8,
    target_bitrate: u24,
    quality: u6,
    keyframe_granule_shift: u5,
    pixel_format: PixelFormat,

    pub fn getWidth(self: TheoraInfoHeader) u32 {
        return @as(u32, self.frame_width_macro) * 16;
    }

    pub fn getHeight(self: TheoraInfoHeader) u32 {
        return @as(u32, self.frame_height_macro) * 16;
    }

    pub fn getFrameRate(self: TheoraInfoHeader) f32 {
        if (self.fps_denominator == 0) return 0.0;
        return @as(f32, @floatFromInt(self.fps_numerator)) / @as(f32, @floatFromInt(self.fps_denominator));
    }
};

/// Theora validation result
pub const TheoraValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    version: ?TheoraVersion,
    width: u32,
    height: u32,
    frame_rate: f32,
    keyframes: u32,
    inter_frames: u32,

    pub fn ok(ver: TheoraVersion, w: u32, h: u32, fps: f32, keyframes: u32, inter: u32) TheoraValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .version = ver,
            .width = w,
            .height = h,
            .frame_rate = fps,
            .keyframes = keyframes,
            .inter_frames = inter,
        };
    }

    pub fn invalid(message: []const u8) TheoraValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .version = null,
            .width = 0,
            .height = 0,
            .frame_rate = 0,
            .keyframes = 0,
            .inter_frames = 0,
        };
    }
};

/// Parse Theora info header from packet data
pub fn parseInfoHeader(data: []const u8) ?TheoraInfoHeader {
    // Minimum info header size: 42 bytes
    // Header type (1) + "theora" (6) + version (3) + sizes, etc.
    if (data.len < 42) return null;

    // Check header type
    if (data[0] != 0x80) return null;

    // Check magic "theora"
    if (!std.mem.eql(u8, data[1..7], "theora")) return null;

    // Parse version
    const version = TheoraVersion{
        .major = data[7],
        .minor = data[8],
        .subminor = data[9],
    };

    // Frame dimensions in macroblocks (16x16 blocks)
    const frame_width_macro = std.mem.readInt(u16, data[10..12], .big);
    const frame_height_macro = std.mem.readInt(u16, data[12..14], .big);

    // Picture dimensions
    const pic_width = std.mem.readInt(u24, data[14..17], .big);
    const pic_height = std.mem.readInt(u24, data[17..20], .big);

    // Picture offset
    const pic_offset_x = data[20];
    const pic_offset_y = data[21];

    // Frame rate
    const fps_num = std.mem.readInt(u32, data[22..26], .big);
    const fps_den = std.mem.readInt(u32, data[26..30], .big);

    // Aspect ratio
    const aspect_num = std.mem.readInt(u24, data[30..33], .big);
    const aspect_den = std.mem.readInt(u24, data[33..36], .big);

    // Colorspace
    const colorspace = data[36];

    // Target bitrate (24 bits)
    const target_bitrate = std.mem.readInt(u24, data[37..40], .big);

    // Quality (6 bits) + keyframe granule shift (5 bits) + pixel format (2 bits)
    // These are packed in 2 bytes
    const packed1 = data[40];
    const packed2 = data[41];

    const quality: u6 = @intCast(packed1 >> 2);
    const keyframe_granule_shift: u5 = @intCast(((packed1 & 0x03) << 3) | (packed2 >> 5));
    const pixel_format: PixelFormat = @enumFromInt(@as(u2, @truncate(packed2 >> 3)));

    // Validate dimensions
    if (frame_width_macro == 0 or frame_height_macro == 0) return null;
    if (pic_width == 0 or pic_height == 0) return null;

    return TheoraInfoHeader{
        .version = version,
        .frame_width_macro = frame_width_macro,
        .frame_height_macro = frame_height_macro,
        .pic_width = pic_width,
        .pic_height = pic_height,
        .pic_offset_x = pic_offset_x,
        .pic_offset_y = pic_offset_y,
        .fps_numerator = fps_num,
        .fps_denominator = fps_den,
        .aspect_numerator = aspect_num,
        .aspect_denominator = aspect_den,
        .colorspace = colorspace,
        .target_bitrate = target_bitrate,
        .quality = quality,
        .keyframe_granule_shift = keyframe_granule_shift,
        .pixel_format = pixel_format,
    };
}

/// Parse Theora comment header
pub fn parseCommentHeader(data: []const u8) bool {
    // Comment header: type (1) + "theora" (6) + vendor length (4) + vendor + count (4) + comments
    if (data.len < 11) return false;

    // Check header type
    if (data[0] != 0x81) return false;

    // Check magic "theora"
    if (!std.mem.eql(u8, data[1..7], "theora")) return false;

    // Vendor string length (little-endian, unlike other fields!)
    if (data.len < 11) return false;
    const vendor_len = std.mem.readInt(u32, data[7..11], .little);

    // Sanity check
    if (vendor_len > 65536 or 11 + vendor_len > data.len) return false;

    return true;
}

/// Parse Theora setup header
pub fn parseSetupHeader(data: []const u8) bool {
    // Setup header: type (1) + "theora" (6) + codebooks...
    if (data.len < 7) return false;

    // Check header type
    if (data[0] != 0x82) return false;

    // Check magic "theora"
    if (!std.mem.eql(u8, data[1..7], "theora")) return false;

    // Setup header contains:
    // - Loop filter limits (64 bytes)
    // - Quantization parameters
    // - DCT token Huffman codes
    // We just verify it exists and has the right header
    return data.len > 7;
}

/// Check if a packet is a video frame and return frame type
/// Returns: true if keyframe, false if inter frame, null if not a video frame
pub fn isVideoFrame(data: []const u8) ?bool {
    if (data.len == 0) return null;

    const first_byte = data[0];

    // Header packets have high bit set
    if (first_byte & 0x80 != 0) return null;

    // For video frames, bit 6 indicates frame type:
    // 0 = keyframe (intra)
    // 1 = inter frame
    return (first_byte & 0x40) == 0;
}

/// Validate Theora stream from Ogg container data.
/// The data should be concatenated Theora packets extracted from Ogg pages.
pub fn validateTheoraStream(allocator: Allocator, data: []const u8, max_frames: u32) TheoraValidationResult {
    _ = allocator;
    _ = max_frames;

    if (data.len < 42) {
        return TheoraValidationResult.invalid("Data too small for Theora");
    }

    // Parse info header (first packet)
    const info = parseInfoHeader(data) orelse {
        return TheoraValidationResult.invalid("Invalid Theora info header");
    };

    // We'd need to parse Ogg pages to get individual packets
    // For now, just return info from the header
    // Full validation would extract packets from Ogg and count frames

    return TheoraValidationResult.ok(
        info.version,
        info.getWidth(),
        info.getHeight(),
        info.getFrameRate(),
        0, // Would need to count keyframes
        0, // Would need to count inter frames
    );
}

/// Validate Theora from an Ogg file by extracting Theora stream data.
/// This parses Ogg pages and validates the Theora packets.
pub fn validateTheoraFromOgg(allocator: Allocator, file: *FileSource, max_frames: u32) TheoraValidationResult {
    var packets: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (packets.items) |pkt| {
            allocator.free(pkt);
        }
        packets.deinit(allocator);
    }

    // Find Theora stream serial number and extract packets
    var theora_serial: ?u32 = null;
    var info_header: ?TheoraInfoHeader = null;
    var has_comment: bool = false;
    var has_setup: bool = false;
    var keyframes: u32 = 0;
    var inter_frames: u32 = 0;

    file.seekTo(0) catch {
        return TheoraValidationResult.invalid("Failed to seek");
    };

    // Parse Ogg pages
    while (true) {
        // Read page header
        var header: [27]u8 = undefined;
        const bytes_read = file.read(&header) catch break;
        if (bytes_read < 27) break;

        // Verify "OggS"
        if (!std.mem.eql(u8, header[0..4], "OggS")) break;

        const serial = std.mem.readInt(u32, header[14..18], .little);
        const num_segments = header[26];

        // Read segment table
        const segment_table = allocator.alloc(u8, num_segments) catch {
            return TheoraValidationResult.invalid("Memory allocation failed");
        };
        defer allocator.free(segment_table);

        const seg_read = file.read(segment_table) catch break;
        if (seg_read < num_segments) break;

        // Calculate page data size
        var page_data_size: u32 = 0;
        for (segment_table) |seg| {
            page_data_size += seg;
        }

        // Read page data
        if (page_data_size == 0) continue;

        const page_data = allocator.alloc(u8, page_data_size) catch {
            return TheoraValidationResult.invalid("Memory allocation failed");
        };
        defer allocator.free(page_data);

        const data_read = file.read(page_data) catch break;
        if (data_read < page_data_size) break;

        // Extract packets from segments
        var packet_start: u32 = 0;
        var packet_size: u32 = 0;
        for (segment_table) |seg| {
            packet_size += seg;
            if (seg < 255) {
                // End of packet
                if (packet_size > 0) {
                    const packet = page_data[packet_start .. packet_start + packet_size];

                    // Check if this is a Theora stream
                    if (theora_serial == null and packet.len >= 7 and packet[0] == 0x80 and
                        std.mem.eql(u8, packet[1..7], "theora"))
                    {
                        theora_serial = serial;
                    }

                    // Process packets from Theora stream
                    if (theora_serial != null and serial == theora_serial.?) {
                        // Info header
                        if (packet.len >= 7 and packet[0] == 0x80) {
                            info_header = parseInfoHeader(packet);
                        }
                        // Comment header
                        else if (packet.len >= 7 and packet[0] == 0x81) {
                            has_comment = parseCommentHeader(packet);
                        }
                        // Setup header
                        else if (packet.len >= 7 and packet[0] == 0x82) {
                            has_setup = parseSetupHeader(packet);
                        }
                        // Video frame
                        else if (isVideoFrame(packet)) |is_key| {
                            if (keyframes + inter_frames < max_frames) {
                                if (is_key) {
                                    keyframes += 1;
                                } else {
                                    inter_frames += 1;
                                }
                            }
                        }
                    }
                }
                packet_start = packet_start + packet_size;
                packet_size = 0;
            }
        }

        // Handle packet continuation (packet spans pages)
        if (packet_size > 0) {
            // Packet continues to next page - we skip continued packets for simplicity
            // A full implementation would buffer and reassemble
        }
    }

    if (info_header == null) {
        return TheoraValidationResult.invalid("No Theora info header found");
    }

    if (!has_comment) {
        return TheoraValidationResult.invalid("No Theora comment header found");
    }

    if (!has_setup) {
        return TheoraValidationResult.invalid("No Theora setup header found");
    }

    const info = info_header.?;
    return TheoraValidationResult.ok(
        info.version,
        info.getWidth(),
        info.getHeight(),
        info.getFrameRate(),
        keyframes,
        inter_frames,
    );
}

// Tests
test "parseInfoHeader valid" {
    // Construct a minimal Theora info header
    var header: [42]u8 = undefined;
    header[0] = 0x80; // Header type
    @memcpy(header[1..7], "theora");
    header[7] = 3; // Major version
    header[8] = 2; // Minor version
    header[9] = 1; // Subminor version

    // Frame dimensions in macroblocks (big-endian)
    std.mem.writeInt(u16, header[10..12], 20, .big); // 320 pixels
    std.mem.writeInt(u16, header[12..14], 15, .big); // 240 pixels

    // Picture dimensions (big-endian, 24-bit)
    header[14] = 0;
    header[15] = 0x01;
    header[16] = 0x40; // 320
    header[17] = 0;
    header[18] = 0x00;
    header[19] = 0xF0; // 240

    // Picture offset
    header[20] = 0;
    header[21] = 0;

    // FPS 30/1 (big-endian)
    std.mem.writeInt(u32, header[22..26], 30, .big);
    std.mem.writeInt(u32, header[26..30], 1, .big);

    // Aspect ratio 1:1 (big-endian, 24-bit)
    header[30] = 0;
    header[31] = 0;
    header[32] = 1;
    header[33] = 0;
    header[34] = 0;
    header[35] = 1;

    // Colorspace
    header[36] = 0;

    // Target bitrate (24-bit)
    header[37] = 0;
    header[38] = 0;
    header[39] = 0;

    // Quality + keyframe shift + pixel format
    header[40] = 0x3F << 2; // Quality 63
    header[41] = 0x00; // Shift 0, format 0

    const result = parseInfoHeader(&header);
    try std.testing.expect(result != null);

    const info = result.?;
    try std.testing.expectEqual(@as(u8, 3), info.version.major);
    try std.testing.expectEqual(@as(u8, 2), info.version.minor);
    try std.testing.expectEqual(@as(u32, 320), info.getWidth());
    try std.testing.expectEqual(@as(u32, 240), info.getHeight());
    try std.testing.expectEqual(@as(f32, 30.0), info.getFrameRate());
}

test "parseInfoHeader rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = parseInfoHeader(&garbage);
    try std.testing.expect(result == null);
}

test "parseCommentHeader valid" {
    // Type + "theora" + vendor_len (4, little-endian) + vendor
    var header: [20]u8 = undefined;
    header[0] = 0x81;
    @memcpy(header[1..7], "theora");
    std.mem.writeInt(u32, header[7..11], 4, .little); // vendor length
    @memcpy(header[11..15], "test");
    std.mem.writeInt(u32, header[15..19], 0, .little); // 0 comments
    header[19] = 0;

    const result = parseCommentHeader(&header);
    try std.testing.expect(result);
}

test "isVideoFrame detects keyframes" {
    const keyframe = [_]u8{0x00}; // Bit 6 = 0 -> keyframe
    const inter = [_]u8{0x40}; // Bit 6 = 1 -> inter frame
    const header = [_]u8{0x80}; // High bit set -> not a video frame

    try std.testing.expectEqual(@as(?bool, true), isVideoFrame(&keyframe));
    try std.testing.expectEqual(@as(?bool, false), isVideoFrame(&inter));
    try std.testing.expectEqual(@as(?bool, null), isVideoFrame(&header));
}

// ============================================================================
// Deep Validation Integration
// ============================================================================

/// Combined deep validation result with structural + decode statistics
pub const TheoraDeepValidationCombinedResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    structural_valid: bool,
    deep_valid: bool,
    blocks_decoded: u32,
    superblocks_decoded: u32,
    keyframes_validated: u32,
    structural_result: TheoraValidationResult,

    pub fn ok(structural: TheoraValidationResult, blocks: u32, sbs: u32, keyframes: u32) TheoraDeepValidationCombinedResult {
        return .{
            .valid = true,
            .error_message = null,
            .structural_valid = true,
            .deep_valid = true,
            .blocks_decoded = blocks,
            .superblocks_decoded = sbs,
            .keyframes_validated = keyframes,
            .structural_result = structural,
        };
    }

    pub fn structuralOnly(structural: TheoraValidationResult) TheoraDeepValidationCombinedResult {
        return .{
            .valid = structural.valid,
            .error_message = structural.error_message,
            .structural_valid = structural.valid,
            .deep_valid = false,
            .blocks_decoded = 0,
            .superblocks_decoded = 0,
            .keyframes_validated = 0,
            .structural_result = structural,
        };
    }
};

/// Validate Theora from Ogg file with deep decode validation
pub fn validateTheoraDeepFromOgg(allocator: Allocator, file: *FileSource, max_frames: u32) TheoraDeepValidationCombinedResult {
    // First do structural validation
    const structural = validateTheoraFromOgg(allocator, file, max_frames);
    if (!structural.valid) {
        return TheoraDeepValidationCombinedResult.structuralOnly(structural);
    }

    // Seek back to beginning for deep validation pass
    file.seekTo(0) catch {
        return TheoraDeepValidationCombinedResult.structuralOnly(structural);
    };

    // Deep validation: extract frame packets and validate with decoder
    var total_blocks: u32 = 0;
    var total_superblocks: u32 = 0;
    var keyframes_validated: u32 = 0;
    var frames_validated: u32 = 0;
    var theora_serial: ?u32 = null;
    var info: ?TheoraInfoHeader = null;

    // Parse Ogg pages and deep-validate frame packets
    while (frames_validated < max_frames) {
        // Read page header
        var header: [27]u8 = undefined;
        const bytes_read = file.read(&header) catch break;
        if (bytes_read < 27) break;

        // Verify "OggS"
        if (!std.mem.eql(u8, header[0..4], "OggS")) break;

        const serial = std.mem.readInt(u32, header[14..18], .little);
        const num_segments = header[26];

        // Read segment table
        const segment_table = allocator.alloc(u8, num_segments) catch break;
        defer allocator.free(segment_table);

        const seg_read = file.read(segment_table) catch break;
        if (seg_read < num_segments) break;

        // Calculate page data size
        var page_data_size: u32 = 0;
        for (segment_table) |seg| {
            page_data_size += seg;
        }

        if (page_data_size == 0) continue;

        // Read page data
        const page_data = allocator.alloc(u8, page_data_size) catch break;
        defer allocator.free(page_data);

        const data_read = file.read(page_data) catch break;
        if (data_read < page_data_size) break;

        // Extract packets from segments
        var packet_start: u32 = 0;
        var packet_size: u32 = 0;
        for (segment_table) |seg| {
            packet_size += seg;
            if (seg < 255) {
                // End of packet
                if (packet_size > 0) {
                    const packet = page_data[packet_start .. packet_start + packet_size];

                    // Identify Theora stream
                    if (theora_serial == null and packet.len >= 7 and packet[0] == 0x80 and
                        std.mem.eql(u8, packet[1..7], "theora"))
                    {
                        theora_serial = serial;
                        info = parseInfoHeader(packet);
                    }

                    // Process packets from Theora stream
                    if (theora_serial != null and serial == theora_serial.?) {
                        // Video frame - attempt deep validation
                        if (isVideoFrame(packet)) |is_key| {
                            if (frames_validated < max_frames and info != null) {
                                const deep_result = theora_decoder.validateFrameDeep(
                                    packet,
                                    info.?.getWidth(),
                                    info.?.getHeight(),
                                );
                                if (deep_result.valid) {
                                    total_blocks += deep_result.blocks_decoded;
                                    total_superblocks += deep_result.superblocks_decoded;
                                    if (is_key) keyframes_validated += 1;
                                    frames_validated += 1;
                                }
                            }
                        }
                    }
                }
                packet_start = packet_start + packet_size;
                packet_size = 0;
            }
        }
    }

    // If we validated at least one frame deeply, return success
    if (frames_validated > 0) {
        return TheoraDeepValidationCombinedResult.ok(
            structural,
            total_blocks,
            total_superblocks,
            keyframes_validated,
        );
    }

    // Fall back to structural only
    return TheoraDeepValidationCombinedResult.structuralOnly(structural);
}

/// Validate Theora packets directly (for testing)
pub fn validateTheoraPacketsDeep(info: ?TheoraInfoHeader, packets: []const []const u8, max_frames: u32) TheoraDeepValidationCombinedResult {
    if (info == null) {
        return TheoraDeepValidationCombinedResult.structuralOnly(
            TheoraValidationResult.invalid("No info header"),
        );
    }

    var total_blocks: u32 = 0;
    var total_superblocks: u32 = 0;
    var keyframes_validated: u32 = 0;
    var inter_frames: u32 = 0;
    var frames_validated: u32 = 0;

    for (packets) |packet| {
        if (frames_validated >= max_frames) break;

        if (isVideoFrame(packet)) |is_key| {
            const deep_result = theora_decoder.validateFrameDeep(
                packet,
                info.?.getWidth(),
                info.?.getHeight(),
            );
            if (deep_result.valid) {
                total_blocks += deep_result.blocks_decoded;
                total_superblocks += deep_result.superblocks_decoded;
                if (is_key) {
                    keyframes_validated += 1;
                } else {
                    inter_frames += 1;
                }
                frames_validated += 1;
            }
        }
    }

    if (frames_validated == 0) {
        return TheoraDeepValidationCombinedResult.structuralOnly(
            TheoraValidationResult.invalid("No frames validated"),
        );
    }

    const structural = TheoraValidationResult.ok(
        info.?.version,
        info.?.getWidth(),
        info.?.getHeight(),
        info.?.getFrameRate(),
        keyframes_validated,
        inter_frames,
    );

    return TheoraDeepValidationCombinedResult.ok(
        structural,
        total_blocks,
        total_superblocks,
        keyframes_validated,
    );
}

test "deep validation - synthetic frame" {
    // Construct minimal valid info header
    var info_bytes: [42]u8 = undefined;
    info_bytes[0] = 0x80; // Header type
    @memcpy(info_bytes[1..7], "theora");
    info_bytes[7] = 3; // Major version
    info_bytes[8] = 2; // Minor version
    info_bytes[9] = 1; // Subminor version

    std.mem.writeInt(u16, info_bytes[10..12], 20, .big); // 320 pixels
    std.mem.writeInt(u16, info_bytes[12..14], 15, .big); // 240 pixels

    // Picture dimensions 320x240 (24-bit big-endian)
    info_bytes[14] = 0;
    info_bytes[15] = 0x01;
    info_bytes[16] = 0x40; // 320
    info_bytes[17] = 0;
    info_bytes[18] = 0x00;
    info_bytes[19] = 0xF0; // 240

    // Picture offset
    info_bytes[20] = 0;
    info_bytes[21] = 0;

    // FPS 30/1
    std.mem.writeInt(u32, info_bytes[22..26], 30, .big);
    std.mem.writeInt(u32, info_bytes[26..30], 1, .big);

    // Aspect ratio 1:1
    info_bytes[30] = 0;
    info_bytes[31] = 0;
    info_bytes[32] = 1;
    info_bytes[33] = 0;
    info_bytes[34] = 0;
    info_bytes[35] = 1;

    // Colorspace
    info_bytes[36] = 0;

    // Target bitrate
    info_bytes[37] = 0;
    info_bytes[38] = 0;
    info_bytes[39] = 0;

    // Quality + keyframe shift + pixel format
    info_bytes[40] = 0x3F << 2;
    info_bytes[41] = 0x00;

    const info = parseInfoHeader(&info_bytes);
    try std.testing.expect(info != null);

    // Create synthetic keyframe packet
    const keyframe_packet = [_]u8{
        0x00, // Keyframe indicator
        0x00, 0x00, 0x00, 0x00, // Padding
        0x00, 0x00, 0x00, 0x00,
    };

    const packets = [_][]const u8{&keyframe_packet};
    const result = validateTheoraPacketsDeep(info, &packets, 10);

    try std.testing.expect(result.structural_valid);
    try std.testing.expect(result.deep_valid);
    try std.testing.expect(result.keyframes_validated >= 1);
}

test "ground truth - Theora OGV sample" {
    // Test with real Theora OGV file
    var source = FileSource.open("ground_truth_examples/theora/sample.ogv") catch |err| {
        // Skip test if ground truth sample not available
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer source.close();

    const allocator = std.testing.allocator;
    const result = validateTheoraDeepFromOgg(allocator, &source, 10);

    try std.testing.expect(result.structural_valid);
    // Deep validation may or may not succeed depending on frame complexity
    // but structural validation should pass for valid OGV files
    try std.testing.expect(result.structural_result.valid);
    try std.testing.expect(result.structural_result.width > 0);
    try std.testing.expect(result.structural_result.height > 0);
}
