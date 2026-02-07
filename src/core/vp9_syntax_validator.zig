//! VP9 Frame Header Parser and Structural Validator (Pure Zig)
//!
//! Validates VP9 bitstreams by parsing uncompressed frame headers without full
//! pixel decoding. Implements parsing of the VP9 uncompressed header per the
//! VP9 specification (section 6.2), including superframe index parsing for
//! frames extracted from MKV/WebM containers.
//!
//! This is a pure-Zig implementation with no external C dependencies.

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;

// ============================================================================
// VP9 Constants
// ============================================================================

/// VP9 frame marker must be 0b10 (value 2)
const VP9_FRAME_MARKER: u32 = 2;

/// VP9 sync code bytes
const VP9_SYNC_CODE_0: u32 = 0x49;
const VP9_SYNC_CODE_1: u32 = 0x83;
const VP9_SYNC_CODE_2: u32 = 0x42;

/// Maximum number of reference frames
const REFS_PER_FRAME: u32 = 3;

/// Number of reference frame slots
const REF_FRAMES: u32 = 8;

/// Maximum number of frames in a superframe
const MAX_SUPERFRAME_FRAMES: u32 = 8;

// ============================================================================
// Color Space (VP9 spec Table 7-1 equivalent)
// ============================================================================

pub const ColorSpace = enum(u3) {
    CS_UNKNOWN = 0,
    CS_BT_601 = 1,
    CS_BT_709 = 2,
    CS_SMPTE_170 = 3,
    CS_SMPTE_240 = 4,
    CS_BT_2020 = 5,
    CS_RESERVED = 6,
    CS_RGB = 7,
};

// ============================================================================
// VP9 Syntax Result
// ============================================================================

pub const Vp9SyntaxResult = struct {
    valid: bool,
    error_message: ?[*:0]const u8,
    frames_decoded: u32,
    width: u32,
    height: u32,

    pub fn ok(frames: u32, w: u32, h: u32) Vp9SyntaxResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .width = w,
            .height = h,
        };
    }

    pub fn invalid(msg: [*:0]const u8) Vp9SyntaxResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_decoded = 0,
            .width = 0,
            .height = 0,
        };
    }
};

// ============================================================================
// Superframe Index
// ============================================================================

pub const SuperframeIndex = struct {
    num_frames: u32,
    sizes: [MAX_SUPERFRAME_FRAMES]u32,
};

/// Parse a VP9 superframe index from the end of a chunk.
///
/// VP9 superframes pack multiple frames into a single chunk with an index
/// appended at the end. The index format:
///   - Last byte is the marker: 110SSFFF where SS+1 = bytes_per_size, FFF+1 = num_frames
///   - First byte of index must match the marker
///   - Between the markers: num_frames * bytes_per_size bytes of little-endian frame sizes
pub fn parseSuperframeIndex(data: []const u8) ?SuperframeIndex {
    if (data.len < 2) return null;

    const marker = data[data.len - 1];
    // Superframe marker has top 3 bits = 110
    if (marker & 0xE0 != 0xC0) return null;

    const bytes_per_size: u32 = ((marker >> 3) & 0x3) + 1;
    const num_frames: u32 = (@as(u32, marker) & 0x7) + 1;
    const index_size: usize = 2 + @as(usize, num_frames) * @as(usize, bytes_per_size);

    if (data.len < index_size) return null;
    // First byte of the index must match the marker
    if (data[data.len - index_size] != marker) return null;

    var sizes: [MAX_SUPERFRAME_FRAMES]u32 = .{0} ** MAX_SUPERFRAME_FRAMES;
    var pos: usize = data.len - index_size + 1;

    for (0..num_frames) |i| {
        var size: u32 = 0;
        for (0..bytes_per_size) |j| {
            size |= @as(u32, data[pos]) << @intCast(j * 8);
            pos += 1;
        }
        sizes[i] = size;
    }

    return SuperframeIndex{ .num_frames = num_frames, .sizes = sizes };
}

// ============================================================================
// Frame Header Parsing State
// ============================================================================

const FrameInfo = struct {
    profile: u32,
    frame_type: u32, // 0 = KEY_FRAME, 1 = NON_KEY_FRAME
    show_frame: bool,
    error_resilient_mode: bool,
    intra_only: bool,
    width: u32,
    height: u32,
    bit_depth: u32,
    color_space: u32,
    show_existing_frame: bool,
};

// ============================================================================
// Frame Header Parser
// ============================================================================

/// Parse the uncompressed header of a VP9 frame.
/// Returns frame info on success, or an error message on failure.
fn parseUncompressedHeader(data: []const u8) union(enum) {
    frame: FrameInfo,
    err: [*:0]const u8,
} {
    if (data.len < 1) {
        return .{ .err = "VP9: frame data too short" };
    }

    var reader = BitReader.init(data);

    // frame_marker (2 bits) — must be 0b10 (value 2)
    const frame_marker = reader.readBits(2) orelse return .{ .err = "VP9: truncated frame marker" };
    if (frame_marker != VP9_FRAME_MARKER) {
        return .{ .err = "VP9: invalid frame marker (expected 0b10)" };
    }

    // profile
    const profile_low_bit = reader.readBits(1) orelse return .{ .err = "VP9: truncated profile" };
    const profile_high_bit = reader.readBits(1) orelse return .{ .err = "VP9: truncated profile" };
    const profile = (profile_high_bit << 1) | profile_low_bit;

    if (profile >= 2) {
        const reserved_zero = reader.readBits(1) orelse return .{ .err = "VP9: truncated profile reserved bit" };
        if (reserved_zero != 0) {
            return .{ .err = "VP9: profile reserved bit must be 0" };
        }
    }

    // show_existing_frame
    const show_existing_frame = reader.readBits(1) orelse return .{ .err = "VP9: truncated show_existing_frame" };
    if (show_existing_frame == 1) {
        // frame_to_show_map_idx (3 bits)
        _ = reader.readBits(3) orelse return .{ .err = "VP9: truncated frame_to_show_map_idx" };
        return .{ .frame = FrameInfo{
            .profile = profile,
            .frame_type = 1, // treated as non-key
            .show_frame = true,
            .error_resilient_mode = false,
            .intra_only = false,
            .width = 0,
            .height = 0,
            .bit_depth = 8,
            .color_space = 0,
            .show_existing_frame = true,
        } };
    }

    // frame_type: 0 = KEY_FRAME, 1 = NON_KEY_FRAME
    const frame_type = reader.readBits(1) orelse return .{ .err = "VP9: truncated frame_type" };

    // show_frame
    const show_frame_bit = reader.readBits(1) orelse return .{ .err = "VP9: truncated show_frame" };
    const show_frame = show_frame_bit == 1;

    // error_resilient_mode
    const error_resilient_bit = reader.readBits(1) orelse return .{ .err = "VP9: truncated error_resilient_mode" };
    const error_resilient_mode = error_resilient_bit == 1;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u32 = 8;
    var color_space: u32 = 0;
    var intra_only = false;

    if (frame_type == 0) {
        // KEY_FRAME
        // frame_sync_code
        const sync0 = reader.readBits(8) orelse return .{ .err = "VP9: truncated key frame sync code" };
        const sync1 = reader.readBits(8) orelse return .{ .err = "VP9: truncated key frame sync code" };
        const sync2 = reader.readBits(8) orelse return .{ .err = "VP9: truncated key frame sync code" };
        if (sync0 != VP9_SYNC_CODE_0 or sync1 != VP9_SYNC_CODE_1 or sync2 != VP9_SYNC_CODE_2) {
            return .{ .err = "VP9: invalid key frame sync code" };
        }

        // color_config
        const cc = parseColorConfig(&reader, profile) orelse return .{ .err = "VP9: truncated color config" };
        bit_depth = cc.bit_depth;
        color_space = cc.color_space;
        if (cc.err) |e| return .{ .err = e };

        // frame_size
        const fs = parseFrameSize(&reader) orelse return .{ .err = "VP9: truncated frame size" };
        width = fs.width;
        height = fs.height;

        // render_size
        const render_diff = reader.readBits(1) orelse return .{ .err = "VP9: truncated render size flag" };
        if (render_diff == 1) {
            _ = reader.readBits(16) orelse return .{ .err = "VP9: truncated render width" };
            _ = reader.readBits(16) orelse return .{ .err = "VP9: truncated render height" };
        }
    } else {
        // NON_KEY_FRAME
        if (!show_frame) {
            const intra_only_bit = reader.readBits(1) orelse return .{ .err = "VP9: truncated intra_only" };
            intra_only = intra_only_bit == 1;
        }

        if (!error_resilient_mode) {
            // reset_frame_context (2 bits)
            _ = reader.readBits(2) orelse return .{ .err = "VP9: truncated reset_frame_context" };
        }

        if (intra_only) {
            // frame_sync_code
            const sync0 = reader.readBits(8) orelse return .{ .err = "VP9: truncated intra-only sync code" };
            const sync1 = reader.readBits(8) orelse return .{ .err = "VP9: truncated intra-only sync code" };
            const sync2 = reader.readBits(8) orelse return .{ .err = "VP9: truncated intra-only sync code" };
            if (sync0 != VP9_SYNC_CODE_0 or sync1 != VP9_SYNC_CODE_1 or sync2 != VP9_SYNC_CODE_2) {
                return .{ .err = "VP9: invalid intra-only sync code" };
            }

            if (profile > 0) {
                // color_config
                const cc = parseColorConfig(&reader, profile) orelse return .{ .err = "VP9: truncated color config" };
                bit_depth = cc.bit_depth;
                color_space = cc.color_space;
                if (cc.err) |e| return .{ .err = e };
            }

            // refresh_frame_flags (8 bits)
            _ = reader.readBits(8) orelse return .{ .err = "VP9: truncated refresh_frame_flags" };

            // frame_size
            const fs = parseFrameSize(&reader) orelse return .{ .err = "VP9: truncated frame size" };
            width = fs.width;
            height = fs.height;
        } else {
            // Inter frame
            // refresh_frame_flags (8 bits)
            _ = reader.readBits(8) orelse return .{ .err = "VP9: truncated refresh_frame_flags" };

            // 3x ref_frame_idx (3 bits each) + ref_frame_sign_bias (1 bit each)
            for (0..REFS_PER_FRAME) |_| {
                _ = reader.readBits(3) orelse return .{ .err = "VP9: truncated ref_frame_idx" };
                _ = reader.readBits(1) orelse return .{ .err = "VP9: truncated ref_frame_sign_bias" };
            }

            // frame_size_with_refs
            var found_ref = false;
            for (0..REFS_PER_FRAME) |_| {
                const found = reader.readBits(1) orelse return .{ .err = "VP9: truncated found_ref" };
                if (found == 1) {
                    found_ref = true;
                    break;
                }
            }
            if (!found_ref) {
                const fs = parseFrameSize(&reader) orelse return .{ .err = "VP9: truncated inter frame size" };
                width = fs.width;
                height = fs.height;
            }
            // If found_ref, dimensions come from reference frame — we can't know them
            // without tracking state, so we leave width/height as 0.

            // allow_high_precision_mv (1 bit)
            _ = reader.readBits(1) orelse return .{ .err = "VP9: truncated allow_high_precision_mv" };

            // interpolation_filter
            const is_filter_switchable = reader.readBits(1) orelse return .{ .err = "VP9: truncated interpolation filter" };
            if (is_filter_switchable == 0) {
                // raw_interpolation_filter (2 bits)
                _ = reader.readBits(2) orelse return .{ .err = "VP9: truncated raw_interpolation_filter" };
            }
        }
    }

    return .{ .frame = FrameInfo{
        .profile = profile,
        .frame_type = frame_type,
        .show_frame = show_frame,
        .error_resilient_mode = error_resilient_mode,
        .intra_only = intra_only,
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_space = color_space,
        .show_existing_frame = false,
    } };
}

// ============================================================================
// Color Config Parser
// ============================================================================

const ColorConfig = struct {
    bit_depth: u32,
    color_space: u32,
    err: ?[*:0]const u8,
};

fn parseColorConfig(reader: *BitReader, profile: u32) ?ColorConfig {
    var bit_depth: u32 = 8;

    if (profile >= 2) {
        const ten_or_twelve = reader.readBits(1) orelse return null;
        bit_depth = if (ten_or_twelve == 1) 12 else 10;
    }

    const color_space = reader.readBits(3) orelse return null;

    if (color_space != @intFromEnum(ColorSpace.CS_RGB)) {
        // color_range
        _ = reader.readBits(1) orelse return null;

        if (profile == 1 or profile == 3) {
            // subsampling_x, subsampling_y
            _ = reader.readBits(1) orelse return null;
            _ = reader.readBits(1) orelse return null;
            // reserved
            const reserved = reader.readBits(1) orelse return null;
            if (reserved != 0) {
                return ColorConfig{
                    .bit_depth = bit_depth,
                    .color_space = color_space,
                    .err = "VP9: color config reserved bit must be 0",
                };
            }
        }
        // For profile 0 and 2: subsampling_x = 1, subsampling_y = 1 (implied)
    } else {
        // CS_RGB: color_range is implicitly 1 (full range)
        if (profile == 1 or profile == 3) {
            // subsampling_x = 0, subsampling_y = 0 (implied for RGB)
            // reserved (1 bit)
            const reserved = reader.readBits(1) orelse return null;
            if (reserved != 0) {
                return ColorConfig{
                    .bit_depth = bit_depth,
                    .color_space = color_space,
                    .err = "VP9: RGB color config reserved bit must be 0",
                };
            }
        }
    }

    return ColorConfig{
        .bit_depth = bit_depth,
        .color_space = color_space,
        .err = null,
    };
}

// ============================================================================
// Frame Size Parser
// ============================================================================

const FrameSize = struct {
    width: u32,
    height: u32,
};

fn parseFrameSize(reader: *BitReader) ?FrameSize {
    const width_minus_1 = reader.readBits(16) orelse return null;
    const height_minus_1 = reader.readBits(16) orelse return null;
    return FrameSize{
        .width = width_minus_1 + 1,
        .height = height_minus_1 + 1,
    };
}

// ============================================================================
// Public API: Validate VP9 Stream
// ============================================================================

/// Validate a VP9 stream given as a slice of frame data slices (as extracted
/// from a container like MKV/WebM or IVF).
///
/// For each provided chunk:
///   1. Check for a superframe index; if found, split into sub-frames
///   2. Parse the uncompressed header of each frame
///   3. Validate the frame marker, sync codes, and structural constraints
///
/// Returns a result indicating validity, number of frames decoded, and
/// the width/height from the first key frame encountered.
pub fn validateVp9Stream(frames: []const []const u8, max_frames: u32) Vp9SyntaxResult {
    if (frames.len == 0) {
        return Vp9SyntaxResult.invalid("VP9: no frames provided");
    }

    var total_decoded: u32 = 0;
    var result_width: u32 = 0;
    var result_height: u32 = 0;
    var had_key_frame = false;

    for (frames) |chunk| {
        if (max_frames > 0 and total_decoded >= max_frames) break;

        // Try to parse as superframe
        if (parseSuperframeIndex(chunk)) |sf_index| {
            // Process each sub-frame within the superframe
            var offset: usize = 0;
            for (0..sf_index.num_frames) |i| {
                if (max_frames > 0 and total_decoded >= max_frames) break;

                const frame_size = sf_index.sizes[i];
                if (offset + frame_size > chunk.len) {
                    return Vp9SyntaxResult.invalid("VP9: superframe size exceeds chunk boundary");
                }

                const sub_frame = chunk[offset .. offset + frame_size];
                const result = parseUncompressedHeader(sub_frame);

                switch (result) {
                    .err => |e| return Vp9SyntaxResult.invalid(e),
                    .frame => |info| {
                        total_decoded += 1;
                        if (info.frame_type == 0 and !info.show_existing_frame and !had_key_frame) {
                            result_width = info.width;
                            result_height = info.height;
                            had_key_frame = true;
                        } else if (!had_key_frame and info.width > 0) {
                            result_width = info.width;
                            result_height = info.height;
                        }
                    },
                }

                offset += frame_size;
            }
        } else {
            // Single frame (no superframe index)
            const result = parseUncompressedHeader(chunk);

            switch (result) {
                .err => |e| return Vp9SyntaxResult.invalid(e),
                .frame => |info| {
                    total_decoded += 1;
                    if (info.frame_type == 0 and !info.show_existing_frame and !had_key_frame) {
                        result_width = info.width;
                        result_height = info.height;
                        had_key_frame = true;
                    } else if (!had_key_frame and info.width > 0) {
                        result_width = info.width;
                        result_height = info.height;
                    }
                },
            }
        }
    }

    if (total_decoded == 0) {
        return Vp9SyntaxResult.invalid("VP9: no frames could be decoded");
    }

    return Vp9SyntaxResult.ok(total_decoded, result_width, result_height);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "VP9 frame header rejects empty data" {
    const empty: []const []const u8 = &.{};
    const result = validateVp9Stream(empty, 0);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("VP9: no frames provided", std.mem.span(result.error_message.?));
}

test "VP9 frame marker validation" {
    // Construct a frame with wrong frame_marker (0b00 instead of 0b10)
    // 00 0 0 0 0 1 0 = 0x02
    const bad_marker = [_]u8{ 0x02, 0x49, 0x83, 0x42, 0x20, 0x13, 0xF0, 0x0E, 0xF0 };
    const frames: []const []const u8 = &.{&bad_marker};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("VP9: invalid frame marker (expected 0b10)", std.mem.span(result.error_message.?));
}

test "VP9 key frame sync code validation" {
    // Valid frame_marker but wrong sync code
    // frame_marker=2 (10), profile=0, show_existing=0, frame_type=0(key), show_frame=1, error_resilient=0
    // = 10 0 0 0 0 1 0 = 0x82
    // Then wrong sync bytes: 0xFF, 0xFF, 0xFF
    const bad_sync = [_]u8{ 0x82, 0xFF, 0xFF, 0xFF, 0x20, 0x13, 0xF0, 0x0E, 0xF0 };
    const frames: []const []const u8 = &.{&bad_sync};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqualStrings("VP9: invalid key frame sync code", std.mem.span(result.error_message.?));
}

test "VP9 key frame parsing with synthetic data" {
    // Construct a minimal valid VP9 Profile 0 key frame header:
    //
    // Bit layout:
    //   frame_marker   = 10        (2 bits, value 2)
    //   profile_low    = 0         (1 bit)
    //   profile_high   = 0         (1 bit)
    //   show_existing  = 0         (1 bit)
    //   frame_type     = 0         (1 bit, KEY_FRAME)
    //   show_frame     = 1         (1 bit)
    //   error_resilient= 0         (1 bit)
    //   sync_byte_0    = 01001001  (8 bits, 0x49)
    //   sync_byte_1    = 10000011  (8 bits, 0x83)
    //   sync_byte_2    = 01000010  (8 bits, 0x42)
    //   color_space    = 001       (3 bits, CS_BT_601)
    //   color_range    = 0         (1 bit)
    //   (profile 0: subsampling implied as 1,1)
    //   width_minus_1  = 0000000100111111  (16 bits, 319 → width=320)
    //   height_minus_1 = 0000000011101111  (16 bits, 239 → height=240)
    //   render_diff    = 0         (1 bit)
    //
    // Byte 0: 10000010 = 0x82
    // Byte 1: 01001001 = 0x49
    // Byte 2: 10000011 = 0x83
    // Byte 3: 01000010 = 0x42
    // Byte 4: 0010 0000 = 0x20  (color_space=001, color_range=0, first 4 bits of width)
    // Byte 5: 00010011 = 0x13  (next 8 bits of width)
    // Byte 6: 11110000 = 0xF0  (last 4 bits of width + first 4 bits of height)
    // Byte 7: 00001110 = 0x0E  (next 8 bits of height)
    // Byte 8: 11110000 = 0xF0  (last 4 bits of height + render_diff=0 + padding)
    const key_frame = [_]u8{ 0x82, 0x49, 0x83, 0x42, 0x20, 0x13, 0xF0, 0x0E, 0xF0 };
    const frames: []const []const u8 = &.{&key_frame};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
}

test "VP9 superframe index parsing" {
    // Construct a superframe with 2 sub-frames
    // Sub-frame 0: 4 bytes (valid key frame header, minimal)
    // Sub-frame 1: 4 bytes
    //
    // Superframe marker byte: 110 SS FFF
    //   SS = 0 → bytes_per_size = 1
    //   FFF = 1 → num_frames = 2
    // marker = 0b11000001 = 0xC1
    //
    // Index layout: [marker] [size0] [size1] [marker]
    // size0 = 9, size1 = 9 (each sub-frame is 9 bytes)

    // Two copies of a valid key frame header
    const kf = [_]u8{ 0x82, 0x49, 0x83, 0x42, 0x20, 0x13, 0xF0, 0x0E, 0xF0 };

    // Build the superframe: frame0 ++ frame1 ++ [marker, size0, size1, marker]
    const marker: u8 = 0xC1;
    var superframe: [9 + 9 + 4]u8 = undefined;
    @memcpy(superframe[0..9], &kf);
    @memcpy(superframe[9..18], &kf);
    superframe[18] = marker;
    superframe[19] = 9; // size of frame 0
    superframe[20] = 9; // size of frame 1
    superframe[21] = marker;

    // Test superframe index parsing directly
    const sf = parseSuperframeIndex(&superframe);
    try std.testing.expect(sf != null);
    try std.testing.expectEqual(@as(u32, 2), sf.?.num_frames);
    try std.testing.expectEqual(@as(u32, 9), sf.?.sizes[0]);
    try std.testing.expectEqual(@as(u32, 9), sf.?.sizes[1]);

    // Test that validateVp9Stream handles superframes correctly
    const frames: []const []const u8 = &.{&superframe};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
}

test "VP9 rejects garbage data" {
    // Random garbage that doesn't have a valid frame marker
    const garbage = [_]u8{ 0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA };
    const frames: []const []const u8 = &.{&garbage};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(!result.valid);
}

test "VP9 show_existing_frame parsing" {
    // frame_marker=2 (10), profile=0 (00), show_existing_frame=1 (1),
    // frame_to_show_map_idx=3 (011)
    // Bits: 10 0 0 1 011 = 10001011 = 0x8B
    const show_existing = [_]u8{0x8B};
    const frames: []const []const u8 = &.{&show_existing};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    // show_existing_frame doesn't carry dimensions
    try std.testing.expectEqual(@as(u32, 0), result.width);
    try std.testing.expectEqual(@as(u32, 0), result.height);
}

test "VP9 non-key frame inter parsing" {
    // Construct a non-key inter frame (not intra_only, shown):
    //
    // frame_marker=2 (10), profile=0 (00), show_existing=0 (0),
    // frame_type=1 (1, NON_KEY), show_frame=1 (1), error_resilient=1 (1)
    // Bits so far: 10 0 0 0 1 1 1 = 10000111 = 0x87
    //
    // Since show_frame=1, intra_only is NOT read.
    // Since error_resilient=1, reset_frame_context is NOT read.
    // Since NOT intra_only:
    //   refresh_frame_flags (8 bits): 0xFF
    //   3x ref_frame_idx (3 bits each): 000, 001, 010
    //   3x ref_frame_sign_bias (1 bit each): 0, 0, 0
    //   frame_size_with_refs: 3x found_ref attempts
    //     found_ref[0] = 0, found_ref[1] = 0, found_ref[2] = 0
    //     → must read frame_size: width-1=319 (16 bits), height-1=239 (16 bits)
    //   allow_high_precision_mv (1 bit): 0
    //   is_filter_switchable (1 bit): 1 (switchable, no extra bits)
    //
    // Byte 0: 10000111 = 0x87
    // Byte 1: 11111111 = 0xFF (refresh_frame_flags)
    // Bytes 2+: ref_frame_idx[0]=000, sign_bias[0]=0, ref_frame_idx[1]=001, sign_bias[1]=0,
    //           ref_frame_idx[2]=010, sign_bias[2]=0
    //           = 0000 0010 0100 = split across bytes
    //
    // After byte 1 (16 bits consumed): remaining bits start at bit 16
    // Bits 16-18: ref_frame_idx[0] = 000
    // Bit 19: sign_bias[0] = 0
    // Bits 20-22: ref_frame_idx[1] = 001
    // Bit 23: sign_bias[1] = 0
    // Byte 2: 00000010 = 0x02
    //
    // Bits 24-26: ref_frame_idx[2] = 010
    // Bit 27: sign_bias[2] = 0
    // Bits 28-30: found_ref[0]=0, found_ref[1]=0, found_ref[2]=0
    // Bit 31: first bit of width-1
    // Byte 3: 01000000 = 0x40
    //
    // Bits 32-46: remaining 15 bits of width-1=319=0x013F
    //   width-1 = 319 = 0000000100111111
    //   Bit 31 already consumed first bit (0), so bits 32-46 = 000000100111111
    // Bits 47-62: height-1=239=0x00EF = 0000000011101111
    // Bit 63: allow_high_precision_mv = 0
    // Bit 64: is_filter_switchable = 1
    //
    // Let me re-layout byte by byte more carefully:
    //
    // Bit 0-7:   10000111 = 0x87  (marker+profile+show_existing+frame_type+show_frame+error_resilient)
    // Bit 8-15:  11111111 = 0xFF  (refresh_frame_flags)
    // Bit 16-23: 000 0 001 0 = 0x02  (ref_idx[0], bias[0], ref_idx[1] first 2 bits... wait)
    //
    // Actually ref_frame_idx is 3 bits, so:
    // Bit 16-18: 000 (ref_idx[0])
    // Bit 19: 0 (bias[0])
    // Bit 20-22: 001 (ref_idx[1])
    // Bit 23: 0 (bias[1])
    // → Byte 2: 00000010 = 0x02
    //
    // Bit 24-26: 010 (ref_idx[2])
    // Bit 27: 0 (bias[2])
    // Bit 28: 0 (found_ref[0])
    // Bit 29: 0 (found_ref[1])
    // Bit 30: 0 (found_ref[2])
    // Bit 31: 0 (first bit of width-1=319)
    // → Byte 3: 01000000 = 0x40
    //
    // width-1=319 = 0b0000000100111111 (16 bits, bit 31-46)
    // Bit 31 = 0 (already in byte 3)
    // Bit 32-39: 00000010 = 0x02
    // Bit 40-46: 0111111 (7 bits) + bit 47 (first bit of height-1)
    //
    // height-1=239 = 0b0000000011101111 (16 bits, bit 47-62)
    // Bit 40-47: 01111110 = 0x7E  (last 7 of width + first 1 of height)
    // Wait, let me be more systematic.
    //
    // Actually this is getting complex, let me just provide enough bytes with
    // a simpler approach: all refs as 0, no found_ref, explicit dimensions.

    // Let me just encode the bytes directly:
    // Using a helper: build bit by bit
    const frame_data = [_]u8{
        0x87, // 10 0 0 0 1 1 1 (marker=2, profile=0, show_existing=0, frame_type=1, show_frame=1, err_resilient=1)
        0xFF, // refresh_frame_flags = 0xFF
        0x02, // 000 0 001 0 (ref_idx[0]=0, bias[0]=0, ref_idx[1]=1, bias[1]=0)
        0x40, // 010 0 0 00 0 (ref_idx[2]=2, bias[2]=0, found[0]=0, found[1]=0, found[2]=0, first bit of width)
        0x02, // bits 32-39 of width-1=319: 00000010 (continuing 0000000100111111 from bit 31)
        0x7E, // bits 40-47: 0111111 0 (last 7 bits of width=0111111, first bit of height=0)
        0x00, // bits 48-55: 00000001 ... wait, height-1=239=0b0000000011101111
        // Let me recompute. After bit 31 (which is 0, first bit of width):
        // width-1 = 319 = 0000000100111111
        //   bit 31: 0
        //   bit 32: 0
        //   bit 33: 0
        //   bit 34: 0
        //   bit 35: 0
        //   bit 36: 0
        //   bit 37: 0
        //   bit 38: 1
        //   bit 39: 0
        //   bit 40: 0
        //   bit 41: 1
        //   bit 42: 1
        //   bit 43: 1
        //   bit 44: 1
        //   bit 45: 1
        //   bit 46: 1
        // height-1 = 239 = 0000000011101111
        //   bit 47: 0
        //   ...bit 62: 1
        // bit 63: allow_high_precision_mv = 0
        // bit 64: is_filter_switchable = 1
    };
    // Rather than hand-encoding all this, I'll just make sure we have enough bytes
    // with a larger buffer that covers everything

    _ = frame_data;

    // Build properly bit-by-bit using a buffer
    var buf: [12]u8 = .{0} ** 12;
    var bit_pos: usize = 0;

    // Helper to write bits
    const Writer = struct {
        fn writeBits(b: *[12]u8, pos: *usize, value: u32, count: u5) void {
            for (0..count) |i| {
                const bit_idx: u5 = @intCast(count - 1 - i);
                const bit: u1 = @intCast((value >> bit_idx) & 1);
                const byte_idx = pos.* / 8;
                const bit_offset: u3 = @intCast(7 - (pos.* % 8));
                b[byte_idx] |= @as(u8, bit) << bit_offset;
                pos.* += 1;
            }
        }
    };

    Writer.writeBits(&buf, &bit_pos, 2, 2); // frame_marker = 2
    Writer.writeBits(&buf, &bit_pos, 0, 1); // profile_low = 0
    Writer.writeBits(&buf, &bit_pos, 0, 1); // profile_high = 0
    Writer.writeBits(&buf, &bit_pos, 0, 1); // show_existing_frame = 0
    Writer.writeBits(&buf, &bit_pos, 1, 1); // frame_type = 1 (NON_KEY)
    Writer.writeBits(&buf, &bit_pos, 1, 1); // show_frame = 1
    Writer.writeBits(&buf, &bit_pos, 1, 1); // error_resilient = 1

    // Inter frame: show_frame=1 so no intra_only; error_resilient=1 so no reset_frame_context
    Writer.writeBits(&buf, &bit_pos, 0xFF, 8); // refresh_frame_flags

    // 3x ref_frame_idx + sign_bias
    Writer.writeBits(&buf, &bit_pos, 0, 3); // ref_idx[0]
    Writer.writeBits(&buf, &bit_pos, 0, 1); // sign_bias[0]
    Writer.writeBits(&buf, &bit_pos, 1, 3); // ref_idx[1]
    Writer.writeBits(&buf, &bit_pos, 0, 1); // sign_bias[1]
    Writer.writeBits(&buf, &bit_pos, 2, 3); // ref_idx[2]
    Writer.writeBits(&buf, &bit_pos, 0, 1); // sign_bias[2]

    // found_ref: all 0, then explicit frame_size
    Writer.writeBits(&buf, &bit_pos, 0, 1); // found_ref[0]
    Writer.writeBits(&buf, &bit_pos, 0, 1); // found_ref[1]
    Writer.writeBits(&buf, &bit_pos, 0, 1); // found_ref[2]

    // frame_size: width-1=319, height-1=239
    Writer.writeBits(&buf, &bit_pos, 319, 16); // width_minus_1
    Writer.writeBits(&buf, &bit_pos, 239, 16); // height_minus_1

    // allow_high_precision_mv
    Writer.writeBits(&buf, &bit_pos, 0, 1);
    // is_filter_switchable = 1 (no extra bits needed)
    Writer.writeBits(&buf, &bit_pos, 1, 1);

    const frames: []const []const u8 = &.{&buf};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
}

test "VP9 multiple frames with max_frames limit" {
    // Two valid key frames
    const kf = [_]u8{ 0x82, 0x49, 0x83, 0x42, 0x20, 0x13, 0xF0, 0x0E, 0xF0 };
    const frames: []const []const u8 = &.{ &kf, &kf };

    // With max_frames=1, only first frame should be decoded
    const result = validateVp9Stream(frames, 1);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);

    // With max_frames=0 (unlimited), both frames decoded
    const result2 = validateVp9Stream(frames, 0);
    try std.testing.expect(result2.valid);
    try std.testing.expectEqual(@as(u32, 2), result2.frames_decoded);
}

test "VP9 superframe with non-matching markers rejected" {
    // Build a buffer where the first and last bytes of the "index" don't match
    var data: [20]u8 = .{0} ** 20;
    // Put a valid key frame at the start
    @memcpy(data[0..9], &[_]u8{ 0x82, 0x49, 0x83, 0x42, 0x20, 0x13, 0xF0, 0x0E, 0xF0 });
    // Fake superframe marker at the end
    data[19] = 0xC1; // marker byte at end
    data[16] = 0xC2; // different marker at start of index → mismatch
    data[17] = 9; // size0
    data[18] = 9; // size1

    const sf = parseSuperframeIndex(&data);
    try std.testing.expect(sf == null);
}

test "VP9 profile 2 key frame with 10-bit depth" {
    // Profile 2: profile_low=0, profile_high=1 → profile = (1<<1)|0 = 2
    // Profile >= 2 means we read reserved_zero (1 bit, must be 0)
    // Also means bit_depth field: ten_or_twelve_bit
    //
    // Bit layout:
    //   frame_marker=10 (2), profile_low=0, profile_high=1, reserved_zero=0
    //   show_existing=0, frame_type=0(key), show_frame=1, error_resilient=0
    //   sync: 0x49, 0x83, 0x42
    //   ten_or_twelve_bit=0 (→ bit_depth=10)
    //   color_space=001 (BT.601), color_range=0
    //   (profile 2, not 1 or 3: subsampling implied)
    //   width-1=319 (16 bits), height-1=239 (16 bits)
    //   render_diff=0

    var buf: [12]u8 = .{0} ** 12;
    var bit_pos: usize = 0;

    const Writer = struct {
        fn writeBits(b: *[12]u8, pos: *usize, value: u32, count: u5) void {
            for (0..count) |i| {
                const bit_idx: u5 = @intCast(count - 1 - i);
                const bit: u1 = @intCast((value >> bit_idx) & 1);
                const byte_idx = pos.* / 8;
                const bit_offset: u3 = @intCast(7 - (pos.* % 8));
                b[byte_idx] |= @as(u8, bit) << bit_offset;
                pos.* += 1;
            }
        }
    };

    Writer.writeBits(&buf, &bit_pos, 2, 2); // frame_marker
    Writer.writeBits(&buf, &bit_pos, 0, 1); // profile_low = 0
    Writer.writeBits(&buf, &bit_pos, 1, 1); // profile_high = 1 → profile = 2
    Writer.writeBits(&buf, &bit_pos, 0, 1); // reserved_zero (profile >= 2)
    Writer.writeBits(&buf, &bit_pos, 0, 1); // show_existing_frame = 0
    Writer.writeBits(&buf, &bit_pos, 0, 1); // frame_type = 0 (KEY)
    Writer.writeBits(&buf, &bit_pos, 1, 1); // show_frame = 1
    Writer.writeBits(&buf, &bit_pos, 0, 1); // error_resilient = 0

    // sync code
    Writer.writeBits(&buf, &bit_pos, 0x49, 8);
    Writer.writeBits(&buf, &bit_pos, 0x83, 8);
    Writer.writeBits(&buf, &bit_pos, 0x42, 8);

    // color_config for profile 2:
    Writer.writeBits(&buf, &bit_pos, 0, 1); // ten_or_twelve_bit = 0 → bit_depth=10
    Writer.writeBits(&buf, &bit_pos, 1, 3); // color_space = 1 (BT.601)
    Writer.writeBits(&buf, &bit_pos, 0, 1); // color_range = 0

    // frame_size
    Writer.writeBits(&buf, &bit_pos, 319, 16);
    Writer.writeBits(&buf, &bit_pos, 239, 16);

    // render_diff
    Writer.writeBits(&buf, &bit_pos, 0, 1);

    const frames: []const []const u8 = &.{&buf};
    const result = validateVp9Stream(frames, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
}
