//! ProRes deep structural validation (Pure Zig).
//!
//! ProRes is an intra-frame video codec developed by Apple for professional
//! video production. This module validates ProRes frames by parsing their
//! structure and verifying integrity without full DCT decoding.
//!
//! ProRes profiles:
//! - ProRes 422 Proxy (apco)
//! - ProRes 422 LT (apcs)
//! - ProRes 422 (apcn)
//! - ProRes 422 HQ (apch)
//! - ProRes 4444 (ap4h)
//! - ProRes 4444 XQ (ap4x)
//!
//! Validation approach:
//! 1. Parse frame header (signature, version, dimensions)
//! 2. Parse slice headers (offsets, sizes)
//! 3. Verify slice data bounds
//! 4. Validate quantization matrices if present

const std = @import("std");
const Allocator = std.mem.Allocator;
const prores_decoder = @import("prores_decoder.zig");
const errmsg = @import("error_messages.zig");

/// ProRes codec profile
pub const ProResProfile = enum {
    proxy, // apco - lowest quality
    lt, // apcs - light
    standard, // apcn - standard 422
    hq, // apch - high quality
    prores4444, // ap4h - with alpha
    prores4444xq, // ap4x - extended quality

    pub fn fromFourCC(fourcc: []const u8) ?ProResProfile {
        if (fourcc.len < 4) return null;
        if (std.mem.eql(u8, fourcc[0..4], "apco")) return .proxy;
        if (std.mem.eql(u8, fourcc[0..4], "apcs")) return .lt;
        if (std.mem.eql(u8, fourcc[0..4], "apcn")) return .standard;
        if (std.mem.eql(u8, fourcc[0..4], "apch")) return .hq;
        if (std.mem.eql(u8, fourcc[0..4], "ap4h")) return .prores4444;
        if (std.mem.eql(u8, fourcc[0..4], "ap4x")) return .prores4444xq;
        return null;
    }

    pub fn name(self: ProResProfile) []const u8 {
        return switch (self) {
            .proxy => "ProRes 422 Proxy",
            .lt => "ProRes 422 LT",
            .standard => "ProRes 422",
            .hq => "ProRes 422 HQ",
            .prores4444 => "ProRes 4444",
            .prores4444xq => "ProRes 4444 XQ",
        };
    }

    pub fn hasAlpha(self: ProResProfile) bool {
        return self == .prores4444 or self == .prores4444xq;
    }
};

/// Result of ProRes validation
pub const ProResValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_validated: u32,
    profile: ?ProResProfile,
    width: u16,
    height: u16,

    pub fn ok(frames: u32, profile: ProResProfile, width: u16, height: u16) ProResValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_validated = frames,
            .profile = profile,
            .width = width,
            .height = height,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) ProResValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_validated = frames,
            .profile = null,
            .width = 0,
            .height = 0,
        };
    }
};

/// ProRes frame header structure
pub const ProResFrameHeader = struct {
    frame_size: u32,
    frame_id: [4]u8, // "icpf"
    header_size: u16,
    version: u16,
    encoder_id: [4]u8,
    width: u16,
    height: u16,
    chroma_format: u8, // 2 = 422, 3 = 4444
    reserved1: u8,
    interlace_mode: u8, // 0 = progressive, 1 = interlaced top first, 2 = interlaced bottom first
    reserved2: u8,
    color_primaries: u8,
    transfer_function: u8,
    matrix_coefficients: u8,
    reserved3: u8,
    alpha_info: u8, // 0 = no alpha, 1-8 = alpha bit depth

    /// Parse frame header from data
    pub fn parse(data: []const u8) ?ProResFrameHeader {
        if (data.len < 28) return null;

        // ProRes frame starts with size (4 bytes) + "icpf" (4 bytes)
        const frame_size = std.mem.readInt(u32, data[0..4], .big);
        const frame_id = data[4..8].*;

        // Verify frame signature
        if (!std.mem.eql(u8, &frame_id, "icpf")) {
            return null;
        }

        if (frame_size < 28 or frame_size > 100 * 1024 * 1024) {
            return null;
        }

        const header_size = std.mem.readInt(u16, data[8..10], .big);
        const version = std.mem.readInt(u16, data[10..12], .big);

        // Version should be 0 or 1
        if (version > 1) {
            return null;
        }

        const encoder_id = data[12..16].*;
        const width = std.mem.readInt(u16, data[16..18], .big);
        const height = std.mem.readInt(u16, data[18..20], .big);

        // Sanity check dimensions
        if (width == 0 or height == 0 or width > 32768 or height > 32768) {
            return null;
        }

        // Chroma format is in upper 2 bits of byte 20 (per Apple ProRes spec)
        // 2 = 4:2:2, 3 = 4:4:4:4
        const chroma_format = (data[20] >> 6) & 0x03;
        if (chroma_format != 2 and chroma_format != 3) {
            return null; // Must be 422 or 4444
        }

        return ProResFrameHeader{
            .frame_size = frame_size,
            .frame_id = frame_id,
            .header_size = header_size,
            .version = version,
            .encoder_id = encoder_id,
            .width = width,
            .height = height,
            .chroma_format = chroma_format,
            .reserved1 = data[21],
            .interlace_mode = data[22],
            .reserved2 = data[23],
            .color_primaries = data[24],
            .transfer_function = data[25],
            .matrix_coefficients = data[26],
            .reserved3 = data[27],
            .alpha_info = if (data.len > 28) data[28] else 0,
        };
    }

    pub fn is4444(self: *const ProResFrameHeader) bool {
        return self.chroma_format == 3;
    }
};

/// Validate a single ProRes frame
pub fn validateProResFrame(data: []const u8) ?ProResFrameHeader {
    const header = ProResFrameHeader.parse(data) orelse return null;

    // Verify frame data is complete
    if (data.len < header.frame_size) {
        return null;
    }

    // Verify header size is reasonable
    if (header.header_size < 28 or header.header_size > header.frame_size) {
        return null;
    }

    // Parse picture header (comes after frame header)
    const pic_header_offset: usize = 8 + header.header_size;
    if (pic_header_offset + 8 > data.len) {
        return null;
    }

    const pic_data = data[pic_header_offset..];
    if (pic_data.len < 8) {
        return null;
    }

    // Picture header size is encoded in upper 5 bits of first byte
    // (per Apple ProRes spec and ffmpeg implementation)
    const pic_header_size: u16 = pic_data[0] >> 3;
    if (pic_header_size < 8 or pic_header_size > pic_data.len) {
        return null;
    }

    // Slice count is explicitly stored at bytes 5-6 (big-endian 16-bit)
    const num_slices: u32 = std.mem.readInt(u16, pic_data[5..7], .big);

    if (num_slices == 0 or num_slices > 65536) {
        return null;
    }

    // Verify slice index table
    const slice_table_offset: usize = pic_header_size;
    const slice_table_size: usize = num_slices * 2;

    if (slice_table_offset + slice_table_size > pic_data.len) {
        return null;
    }

    // Slice data starts after the slice index table
    const slice_data_start = slice_table_offset + slice_table_size;

    // Verify slice sizes are valid - the table contains sizes, not offsets
    // Sum all slice sizes to verify they fit within remaining data
    var total_slice_size: u32 = 0;
    for (0..num_slices) |i| {
        const table_entry_offset = slice_table_offset + i * 2;
        const slice_size = std.mem.readInt(u16, pic_data[table_entry_offset..][0..2], .big);
        total_slice_size += slice_size;
    }

    // Verify total slice data fits within picture data
    if (slice_data_start + total_slice_size > pic_data.len) {
        return null;
    }

    return header;
}

/// Validate ProRes frames from raw frame data
pub fn validateProResFrames(
    frames: []const []const u8,
    max_frames: u32,
) ProResValidationResult {
    var frames_validated: u32 = 0;
    var detected_profile: ?ProResProfile = null;
    var width: u16 = 0;
    var height: u16 = 0;

    for (frames) |frame| {
        if (frames_validated >= max_frames) break;

        const header = validateProResFrame(frame) orelse {
            return ProResValidationResult.invalid("Invalid ProRes frame", frames_validated);
        };

        if (frames_validated == 0) {
            width = header.width;
            height = header.height;
            // Detect profile from chroma format and encoder ID
            if (header.is4444()) {
                detected_profile = if (header.alpha_info > 0) .prores4444xq else .prores4444;
            } else {
                // Try to detect from encoder ID or default to standard
                detected_profile = .standard;
            }
        } else {
            // Verify dimensions match
            if (header.width != width or header.height != height) {
                return ProResValidationResult.invalid("Frame dimension mismatch", frames_validated);
            }
        }

        frames_validated += 1;
    }

    if (frames_validated == 0) {
        return ProResValidationResult.invalid("No frames validated", 0);
    }

    return ProResValidationResult.ok(
        frames_validated,
        detected_profile orelse .standard,
        width,
        height,
    );
}

/// Validate ProRes from contiguous buffer with frame sizes
pub fn validateProResFromBuffer(
    frame_data: []const u8,
    frame_sizes: []const u32,
    max_frames: u32,
) ProResValidationResult {
    var frames_validated: u32 = 0;
    var detected_profile: ?ProResProfile = null;
    var width: u16 = 0;
    var height: u16 = 0;
    var offset: usize = 0;

    for (frame_sizes) |size| {
        if (frames_validated >= max_frames) break;
        if (offset + size > frame_data.len) break;

        const frame = frame_data[offset .. offset + size];
        const header = validateProResFrame(frame) orelse {
            return ProResValidationResult.invalid("Invalid ProRes frame", frames_validated);
        };

        if (frames_validated == 0) {
            width = header.width;
            height = header.height;
            if (header.is4444()) {
                detected_profile = if (header.alpha_info > 0) .prores4444xq else .prores4444;
            } else {
                detected_profile = .standard;
            }
        } else {
            if (header.width != width or header.height != height) {
                return ProResValidationResult.invalid("Frame dimension mismatch", frames_validated);
            }
        }

        frames_validated += 1;
        offset += size;
    }

    if (frames_validated == 0) {
        return ProResValidationResult.invalid("No frames validated", 0);
    }

    return ProResValidationResult.ok(
        frames_validated,
        detected_profile orelse .standard,
        width,
        height,
    );
}

/// Deep validation result with decode statistics
pub const ProResDeepValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_validated: u32,
    slices_decoded: u32,
    blocks_decoded: u32,
    profile: ?ProResProfile,
    width: u16,
    height: u16,

    pub fn ok(frames: u32, slices: u32, blocks: u32, profile: ProResProfile, width: u16, height: u16) ProResDeepValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_validated = frames,
            .slices_decoded = slices,
            .blocks_decoded = blocks,
            .profile = profile,
            .width = width,
            .height = height,
        };
    }

    pub fn invalid(message: []const u8, frames: u32, slices: u32, blocks: u32) ProResDeepValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_validated = frames,
            .slices_decoded = slices,
            .blocks_decoded = blocks,
            .profile = null,
            .width = 0,
            .height = 0,
        };
    }
};

/// Deep validate a single ProRes frame with DCT decode
pub fn validateProResFrameDeep(data: []const u8) ProResDeepValidationResult {
    // First do structural validation
    const header = ProResFrameHeader.parse(data) orelse {
        return ProResDeepValidationResult.invalid("Invalid frame header", 0, 0, 0);
    };

    if (data.len < header.frame_size) {
        return ProResDeepValidationResult.invalid(errmsg.incomplete("frame data"), 0, 0, 0);
    }

    // Now do deep decode validation
    const decode_result = prores_decoder.validateFrameDeep(data);

    if (!decode_result.valid) {
        return ProResDeepValidationResult.invalid(
            decode_result.error_message orelse "Decode error",
            0,
            decode_result.slices_decoded,
            decode_result.blocks_decoded,
        );
    }

    // Determine profile
    var profile: ProResProfile = .standard;
    if (header.is4444()) {
        profile = if (header.alpha_info > 0) .prores4444xq else .prores4444;
    }

    return ProResDeepValidationResult.ok(
        1,
        decode_result.slices_decoded,
        decode_result.blocks_decoded,
        profile,
        header.width,
        header.height,
    );
}

/// Deep validate multiple ProRes frames with DCT decode
pub fn validateProResFramesDeep(
    frames: []const []const u8,
    max_frames: u32,
) ProResDeepValidationResult {
    var frames_validated: u32 = 0;
    var total_slices: u32 = 0;
    var total_blocks: u32 = 0;
    var detected_profile: ?ProResProfile = null;
    var width: u16 = 0;
    var height: u16 = 0;

    for (frames) |frame| {
        if (frames_validated >= max_frames) break;

        const result = validateProResFrameDeep(frame);
        if (!result.valid) {
            return ProResDeepValidationResult.invalid(
                result.error_message orelse "Frame validation failed",
                frames_validated,
                total_slices,
                total_blocks,
            );
        }

        if (frames_validated == 0) {
            width = result.width;
            height = result.height;
            detected_profile = result.profile;
        } else {
            if (result.width != width or result.height != height) {
                return ProResDeepValidationResult.invalid(
                    "Frame dimension mismatch",
                    frames_validated,
                    total_slices,
                    total_blocks,
                );
            }
        }

        total_slices += result.slices_decoded;
        total_blocks += result.blocks_decoded;
        frames_validated += 1;
    }

    if (frames_validated == 0) {
        return ProResDeepValidationResult.invalid("No frames validated", 0, 0, 0);
    }

    return ProResDeepValidationResult.ok(
        frames_validated,
        total_slices,
        total_blocks,
        detected_profile orelse .standard,
        width,
        height,
    );
}

// Tests
test "ProRes profile from FourCC" {
    try std.testing.expectEqual(ProResProfile.hq, ProResProfile.fromFourCC("apch").?);
    try std.testing.expectEqual(ProResProfile.standard, ProResProfile.fromFourCC("apcn").?);
    try std.testing.expectEqual(ProResProfile.lt, ProResProfile.fromFourCC("apcs").?);
    try std.testing.expectEqual(ProResProfile.proxy, ProResProfile.fromFourCC("apco").?);
    try std.testing.expectEqual(ProResProfile.prores4444, ProResProfile.fromFourCC("ap4h").?);
    try std.testing.expectEqual(ProResProfile.prores4444xq, ProResProfile.fromFourCC("ap4x").?);
    try std.testing.expect(ProResProfile.fromFourCC("xxxx") == null);
}

test "ProRes frame header parsing rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    try std.testing.expect(ProResFrameHeader.parse(&garbage) == null);
}

test "ProRes frame validation rejects short data" {
    const short = [_]u8{ 0x00, 0x00, 0x00, 0x10, 'i', 'c', 'p', 'f' };
    try std.testing.expect(validateProResFrame(&short) == null);
}

test "ProRes profile names" {
    try std.testing.expectEqualStrings("ProRes 422 HQ", ProResProfile.hq.name());
    try std.testing.expectEqualStrings("ProRes 4444", ProResProfile.prores4444.name());
}

test "ProRes 4444 has alpha" {
    try std.testing.expect(ProResProfile.prores4444.hasAlpha());
    try std.testing.expect(ProResProfile.prores4444xq.hasAlpha());
    try std.testing.expect(!ProResProfile.hq.hasAlpha());
    try std.testing.expect(!ProResProfile.standard.hasAlpha());
}
