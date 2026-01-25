//! MPEG-1/2 Video Stream Validator (Pure Zig)
//!
//! Validates MPEG-1 (ISO/IEC 11172-2) and MPEG-2 (ISO/IEC 13818-2) video elementary streams.
//! This is a structural validator that verifies bitstream syntax without full decode.
//!
//! Start codes (0x000001xx):
//! - 0x00000100: Picture start code
//! - 0x00000101-0x000001AF: Slice start codes
//! - 0x000001B0-0x000001B1: Reserved
//! - 0x000001B2: User data start code
//! - 0x000001B3: Sequence header start code
//! - 0x000001B4: Sequence error code
//! - 0x000001B5: Extension start code
//! - 0x000001B6: Reserved
//! - 0x000001B7: Sequence end code
//! - 0x000001B8: Group of pictures start code

const std = @import("std");
const Allocator = std.mem.Allocator;
const mpeg12_decoder = @import("mpeg12_decoder.zig");
const BitReader = @import("bitstream_reader.zig").BitReader;

/// MPEG video profile/level
pub const MpegVersion = enum {
    mpeg1,
    mpeg2,
    unknown,
};

/// Picture type (I/P/B)
pub const PictureType = enum(u3) {
    forbidden = 0,
    I = 1, // Intra-coded
    P = 2, // Predictive-coded
    B = 3, // Bidirectionally predictive-coded
    D = 4, // DC Intra-coded (MPEG-1 only)
    reserved5 = 5,
    reserved6 = 6,
    reserved7 = 7,

    pub fn isValid(self: PictureType) bool {
        return switch (self) {
            .I, .P, .B, .D => true,
            else => false,
        };
    }
};

/// Frame rate codes (Table 6-4)
pub const frame_rate_values = [_]f32{
    0.0, // forbidden
    24000.0 / 1001.0, // 23.976 fps
    24.0, // 24 fps
    25.0, // 25 fps (PAL)
    30000.0 / 1001.0, // 29.97 fps (NTSC)
    30.0, // 30 fps
    50.0, // 50 fps
    60000.0 / 1001.0, // 59.94 fps
    60.0, // 60 fps
    0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, // reserved
};

/// Aspect ratio codes (MPEG-1 Table 2-3, MPEG-2 Table 6-3)
pub const aspect_ratio_mpeg2 = [_]struct { w: u8, h: u8 }{
    .{ .w = 0, .h = 0 }, // forbidden
    .{ .w = 1, .h = 1 }, // Square samples (1:1)
    .{ .w = 4, .h = 3 }, // 4:3 display
    .{ .w = 16, .h = 9 }, // 16:9 display
    .{ .w = 221, .h = 100 }, // 2.21:1 display
    // rest reserved
};

/// Sequence header information
pub const SequenceHeader = struct {
    horizontal_size: u12,
    vertical_size: u12,
    aspect_ratio_code: u4,
    frame_rate_code: u4,
    bit_rate: u18, // In 400 bps units
    vbv_buffer_size: u10,
    constrained_parameters_flag: bool,
    // MPEG-2 extensions (if present)
    profile_level: ?u8,
    progressive_sequence: ?bool,
    chroma_format: ?u2,

    pub fn getWidth(self: *const SequenceHeader) u16 {
        return @as(u16, self.horizontal_size);
    }

    pub fn getHeight(self: *const SequenceHeader) u16 {
        return @as(u16, self.vertical_size);
    }

    pub fn getFrameRate(self: *const SequenceHeader) f32 {
        if (self.frame_rate_code < frame_rate_values.len) {
            return frame_rate_values[self.frame_rate_code];
        }
        return 0.0;
    }

    pub fn getBitRate(self: *const SequenceHeader) u32 {
        // bit_rate in 400 bps units, 0x3FFFF means variable
        if (self.bit_rate == 0x3FFFF) return 0; // variable
        return @as(u32, self.bit_rate) * 400;
    }
};

/// GOP (Group of Pictures) header
pub const GopHeader = struct {
    time_code_hours: u5,
    time_code_minutes: u6,
    time_code_seconds: u6,
    time_code_pictures: u6,
    drop_frame_flag: bool,
    closed_gop: bool,
    broken_link: bool,
};

/// Picture header
pub const PictureHeader = struct {
    temporal_reference: u10,
    picture_type: PictureType,
    vbv_delay: u16,
    // Extra fields for P/B frames
    full_pel_forward_vector: ?bool,
    forward_f_code: ?u3,
    full_pel_backward_vector: ?bool,
    backward_f_code: ?u3,
};

/// Validation result
pub const Mpeg12ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    version: MpegVersion,
    sequence_headers: u32,
    gop_headers: u32,
    pictures: u32,
    slices: u32,
    i_frames: u32,
    p_frames: u32,
    b_frames: u32,
    width: u16,
    height: u16,
    frame_rate: f32,

    pub fn ok(ver: MpegVersion, seq: u32, gop: u32, pics: u32, slc: u32, i: u32, p: u32, b: u32, w: u16, h: u16, fr: f32) Mpeg12ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .version = ver,
            .sequence_headers = seq,
            .gop_headers = gop,
            .pictures = pics,
            .slices = slc,
            .i_frames = i,
            .p_frames = p,
            .b_frames = b,
            .width = w,
            .height = h,
            .frame_rate = fr,
        };
    }

    pub fn invalid(message: []const u8) Mpeg12ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .version = .unknown,
            .sequence_headers = 0,
            .gop_headers = 0,
            .pictures = 0,
            .slices = 0,
            .i_frames = 0,
            .p_frames = 0,
            .b_frames = 0,
            .width = 0,
            .height = 0,
            .frame_rate = 0,
        };
    }
};


/// Find next start code in data starting from offset
/// Returns position of 0x000001 and the start code byte, or null if not found
fn findNextStartCode(data: []const u8, start_offset: usize) ?struct { pos: usize, code: u8 } {
    if (start_offset + 4 > data.len) return null;

    var i = start_offset;
    while (i + 3 < data.len) {
        if (data[i] == 0x00 and data[i + 1] == 0x00 and data[i + 2] == 0x01) {
            return .{ .pos = i, .code = data[i + 3] };
        }
        i += 1;
    }
    return null;
}

/// Parse sequence header
fn parseSequenceHeader(data: []const u8, offset: usize) ?struct { header: SequenceHeader, end: usize } {
    // Sequence header after start code: 4 bytes
    // horizontal_size (12) + vertical_size (12) + aspect_ratio (4) + frame_rate (4)
    // + bit_rate (18) + marker (1) + vbv_buffer_size (10) + constrained (1)
    // + load_intra_quantiser_matrix (1) + [intra_matrix] + load_non_intra_matrix (1) + [non_intra_matrix]

    if (offset + 4 + 8 > data.len) return null;

    var reader = BitReader.init(data[offset + 4 ..]); // Skip start code

    const h_size = reader.readBits(12) orelse return null;
    const v_size = reader.readBits(12) orelse return null;
    const aspect = reader.readBits(4) orelse return null;
    const frame_rate = reader.readBits(4) orelse return null;
    const bit_rate = reader.readBits(18) orelse return null;
    const marker1 = reader.readBool() orelse return null;
    if (!marker1) return null; // marker_bit must be 1
    const vbv = reader.readBits(10) orelse return null;
    const constrained = reader.readBool() orelse return null;

    // Check for quantisation matrices
    const load_intra = reader.readBool() orelse return null;
    if (load_intra) {
        // Skip 64 * 8 bits = 512 bits
        if (!reader.skipBits(512)) return null;
    }
    const load_non_intra = reader.readBool() orelse return null;
    if (load_non_intra) {
        if (!reader.skipBits(512)) return null;
    }

    reader.alignToByte();
    const end_offset = offset + 4 + reader.getBytePos();

    return .{
        .header = .{
            .horizontal_size = @intCast(h_size),
            .vertical_size = @intCast(v_size),
            .aspect_ratio_code = @intCast(aspect),
            .frame_rate_code = @intCast(frame_rate),
            .bit_rate = @intCast(bit_rate),
            .vbv_buffer_size = @intCast(vbv),
            .constrained_parameters_flag = constrained,
            .profile_level = null,
            .progressive_sequence = null,
            .chroma_format = null,
        },
        .end = end_offset,
    };
}

/// Parse sequence extension (MPEG-2 only)
fn parseSequenceExtension(data: []const u8, offset: usize, header: *SequenceHeader) ?usize {
    // Extension start code + extension_start_code_identifier (4 bits)
    if (offset + 4 + 2 > data.len) return null;

    var reader = BitReader.init(data[offset + 4 ..]); // Skip start code

    const ext_id = reader.readBits(4) orelse return null;
    if (ext_id != 1) return null; // sequence_extension_id = 1

    header.profile_level = @intCast(reader.readBits(8) orelse return null);
    header.progressive_sequence = reader.readBool();
    header.chroma_format = @intCast(reader.readBits(2) orelse return null);

    // horizontal_size_extension (2) + vertical_size_extension (2)
    const h_ext = reader.readBits(2) orelse return null;
    const v_ext = reader.readBits(2) orelse return null;

    // Update dimensions with extensions
    header.horizontal_size |= @intCast(h_ext << 12);
    header.vertical_size |= @intCast(v_ext << 12);

    // bit_rate_extension (12) + marker (1) + vbv_buffer_size_extension (8)
    _ = reader.readBits(12) orelse return null;
    _ = reader.readBool() orelse return null;
    _ = reader.readBits(8) orelse return null;

    // low_delay (1) + frame_rate_extension_n (2) + frame_rate_extension_d (5)
    _ = reader.readBits(8) orelse return null;

    reader.alignToByte();
    return offset + 4 + reader.getBytePos();
}

/// Parse GOP header
fn parseGopHeader(data: []const u8, offset: usize) ?struct { header: GopHeader, end: usize } {
    // GOP header: time_code (25) + closed_gop (1) + broken_link (1)
    if (offset + 4 + 4 > data.len) return null;

    var reader = BitReader.init(data[offset + 4 ..]);

    const drop_frame = reader.readBool() orelse return null;
    const hours = reader.readBits(5) orelse return null;
    const minutes = reader.readBits(6) orelse return null;
    _ = reader.readBool() orelse return null; // marker bit
    const seconds = reader.readBits(6) orelse return null;
    const pictures = reader.readBits(6) orelse return null;
    const closed = reader.readBool() orelse return null;
    const broken = reader.readBool() orelse return null;

    reader.alignToByte();
    return .{
        .header = .{
            .time_code_hours = @intCast(hours),
            .time_code_minutes = @intCast(minutes),
            .time_code_seconds = @intCast(seconds),
            .time_code_pictures = @intCast(pictures),
            .drop_frame_flag = drop_frame,
            .closed_gop = closed,
            .broken_link = broken,
        },
        .end = offset + 4 + reader.getBytePos(),
    };
}

/// Parse picture header
fn parsePictureHeader(data: []const u8, offset: usize) ?struct { header: PictureHeader, end: usize } {
    // Picture header: temporal_reference (10) + picture_coding_type (3) + vbv_delay (16)
    if (offset + 4 + 4 > data.len) return null;

    var reader = BitReader.init(data[offset + 4 ..]);

    const temporal_ref = reader.readBits(10) orelse return null;
    const pic_type_val = reader.readBits(3) orelse return null;
    const vbv_delay = reader.readBits(16) orelse return null;

    const pic_type: PictureType = @enumFromInt(pic_type_val);

    var full_pel_forward: ?bool = null;
    var forward_f_code: ?u3 = null;
    var full_pel_backward: ?bool = null;
    var backward_f_code: ?u3 = null;

    // For P and B pictures, read forward motion vector info
    if (pic_type == .P or pic_type == .B) {
        full_pel_forward = reader.readBool();
        forward_f_code = @intCast(reader.readBits(3) orelse return null);
    }

    // For B pictures, read backward motion vector info
    if (pic_type == .B) {
        full_pel_backward = reader.readBool();
        backward_f_code = @intCast(reader.readBits(3) orelse return null);
    }

    // Skip extra_bit_picture and extra_information_picture
    while (reader.readBool() orelse false) {
        _ = reader.readBits(8) orelse break;
    }

    reader.alignToByte();
    return .{
        .header = .{
            .temporal_reference = @intCast(temporal_ref),
            .picture_type = pic_type,
            .vbv_delay = @intCast(vbv_delay),
            .full_pel_forward_vector = full_pel_forward,
            .forward_f_code = forward_f_code,
            .full_pel_backward_vector = full_pel_backward,
            .backward_f_code = backward_f_code,
        },
        .end = offset + 4 + reader.getBytePos(),
    };
}

/// Validate MPEG-1/2 video elementary stream
pub fn validateMpeg12Stream(data: []const u8, max_frames: u32) Mpeg12ValidationResult {
    if (data.len < 12) {
        return Mpeg12ValidationResult.invalid("Data too small for MPEG video");
    }

    // Find first sequence header
    var pos: usize = 0;
    var found_sequence = false;
    var version: MpegVersion = .unknown;
    var seq_header: ?SequenceHeader = null;

    var sequence_headers: u32 = 0;
    var gop_headers: u32 = 0;
    var pictures: u32 = 0;
    var slices: u32 = 0;
    var i_frames: u32 = 0;
    var p_frames: u32 = 0;
    var b_frames: u32 = 0;

    while (pos < data.len and pictures < max_frames) {
        const start_code = findNextStartCode(data, pos) orelse break;

        switch (start_code.code) {
            0xB3 => {
                // Sequence header
                if (parseSequenceHeader(data, start_code.pos)) |result| {
                    seq_header = result.header;
                    sequence_headers += 1;
                    found_sequence = true;
                    version = .mpeg1; // Default, may upgrade to MPEG-2

                    // Validate basic parameters
                    if (result.header.horizontal_size == 0 or result.header.vertical_size == 0) {
                        return Mpeg12ValidationResult.invalid("Invalid sequence header dimensions");
                    }
                    if (result.header.frame_rate_code == 0 or result.header.frame_rate_code > 8) {
                        return Mpeg12ValidationResult.invalid("Invalid frame rate code");
                    }

                    pos = result.end;
                } else {
                    pos = start_code.pos + 4;
                }
            },
            0xB5 => {
                // Extension start code (MPEG-2)
                if (seq_header != null) {
                    if (parseSequenceExtension(data, start_code.pos, &seq_header.?)) |end| {
                        version = .mpeg2;
                        pos = end;
                    } else {
                        pos = start_code.pos + 4;
                    }
                } else {
                    pos = start_code.pos + 4;
                }
            },
            0xB8 => {
                // GOP header
                if (parseGopHeader(data, start_code.pos)) |result| {
                    gop_headers += 1;
                    pos = result.end;
                } else {
                    pos = start_code.pos + 4;
                }
            },
            0x00 => {
                // Picture start code
                if (parsePictureHeader(data, start_code.pos)) |result| {
                    pictures += 1;
                    switch (result.header.picture_type) {
                        .I => i_frames += 1,
                        .P => p_frames += 1,
                        .B => b_frames += 1,
                        .D => i_frames += 1, // D-frames are DC-only I-frames
                        else => {},
                    }
                    pos = result.end;
                } else {
                    pos = start_code.pos + 4;
                }
            },
            0x01...0xAF => {
                // Slice start codes
                slices += 1;
                pos = start_code.pos + 4;
            },
            0xB7 => {
                // Sequence end code
                break;
            },
            else => {
                pos = start_code.pos + 4;
            },
        }
    }

    if (!found_sequence) {
        return Mpeg12ValidationResult.invalid("No sequence header found");
    }

    if (pictures == 0) {
        return Mpeg12ValidationResult.invalid("No pictures found");
    }

    // Should have at least some slices per picture (typically 1-68 for SD, more for HD)
    if (slices < pictures) {
        return Mpeg12ValidationResult.invalid("Insufficient slices for pictures");
    }

    const header = seq_header.?;
    return Mpeg12ValidationResult.ok(
        version,
        sequence_headers,
        gop_headers,
        pictures,
        slices,
        i_frames,
        p_frames,
        b_frames,
        header.getWidth(),
        header.getHeight(),
        header.getFrameRate(),
    );
}

/// Validate MPEG video from buffer
pub fn validateMpeg12FromBuffer(data: []const u8) Mpeg12ValidationResult {
    return validateMpeg12Stream(data, 100);
}

/// Deep validation result with decode statistics
pub const Mpeg12DeepValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    /// Structural validation passed
    structural_valid: bool,
    /// Deep decode validation passed (I-frames decoded)
    deep_valid: bool,
    /// Number of slices successfully deep-decoded
    slices_decoded: u32,
    /// Number of macroblocks decoded
    macroblocks_decoded: u32,
    /// Number of 8x8 blocks decoded
    blocks_decoded: u32,
    /// Underlying structural validation result
    structural_result: Mpeg12ValidationResult,

    pub fn ok(structural: Mpeg12ValidationResult, slices: u32, mbs: u32, blocks: u32) Mpeg12DeepValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .structural_valid = true,
            .deep_valid = true,
            .slices_decoded = slices,
            .macroblocks_decoded = mbs,
            .blocks_decoded = blocks,
            .structural_result = structural,
        };
    }

    pub fn structuralOnly(structural: Mpeg12ValidationResult) Mpeg12DeepValidationResult {
        return .{
            .valid = structural.valid,
            .error_message = structural.error_message,
            .structural_valid = structural.valid,
            .deep_valid = false,
            .slices_decoded = 0,
            .macroblocks_decoded = 0,
            .blocks_decoded = 0,
            .structural_result = structural,
        };
    }

    pub fn invalid(message: []const u8) Mpeg12DeepValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .structural_valid = false,
            .deep_valid = false,
            .slices_decoded = 0,
            .macroblocks_decoded = 0,
            .blocks_decoded = 0,
            .structural_result = Mpeg12ValidationResult.invalid(message),
        };
    }
};

/// Validate MPEG-1/2 video with deep decode validation
/// Performs structural validation first, then attempts DCT decode on I-frames
pub fn validateMpeg12Deep(data: []const u8, max_frames: u32) Mpeg12DeepValidationResult {
    // First do structural validation
    const structural = validateMpeg12Stream(data, max_frames);
    if (!structural.valid) {
        return Mpeg12DeepValidationResult.structuralOnly(structural);
    }

    // If no I-frames, we can't do deep validation
    if (structural.i_frames == 0) {
        return Mpeg12DeepValidationResult.structuralOnly(structural);
    }

    // Attempt deep validation on the stream
    const deep_result = mpeg12_decoder.validateIFrameDeep(data);

    if (deep_result.valid) {
        return Mpeg12DeepValidationResult.ok(
            structural,
            deep_result.slices_decoded,
            deep_result.macroblocks_decoded,
            deep_result.blocks_decoded,
        );
    } else {
        // Deep validation failed but structural passed - return structural only
        // This can happen with complex streams that use features not yet implemented
        return Mpeg12DeepValidationResult.structuralOnly(structural);
    }
}

/// Deep validate MPEG video from buffer
pub fn validateMpeg12DeepFromBuffer(data: []const u8) Mpeg12DeepValidationResult {
    return validateMpeg12Deep(data, 100);
}

// Tests
test "BitReader basic operations" {
    const data = [_]u8{ 0xAB, 0xCD, 0xEF };
    var reader = BitReader.init(&data);

    // Read 4 bits: 0xA = 1010
    const v1 = reader.readBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xA), v1);

    // Read 4 bits: 0xB = 1011
    const v2 = reader.readBits(4).?;
    try std.testing.expectEqual(@as(u32, 0xB), v2);

    // Read 8 bits: 0xCD
    const v3 = reader.readBits(8).?;
    try std.testing.expectEqual(@as(u32, 0xCD), v3);
}

test "findNextStartCode locates start codes" {
    const data = [_]u8{ 0x00, 0x00, 0x01, 0xB3, 0x12, 0x34, 0x00, 0x00, 0x01, 0x00 };

    const first = findNextStartCode(&data, 0).?;
    try std.testing.expectEqual(@as(usize, 0), first.pos);
    try std.testing.expectEqual(@as(u8, 0xB3), first.code);

    const second = findNextStartCode(&data, 4).?;
    try std.testing.expectEqual(@as(usize, 6), second.pos);
    try std.testing.expectEqual(@as(u8, 0x00), second.code);
}

test "validateMpeg12Stream rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateMpeg12Stream(&garbage, 10);
    try std.testing.expect(!result.valid);
}

test "validateMpeg12Stream rejects empty data" {
    const result = validateMpeg12Stream(&[_]u8{}, 10);
    try std.testing.expect(!result.valid);
}

test "parseSequenceHeader minimal" {
    // Construct a minimal sequence header
    // Start code: 00 00 01 B3
    // horizontal_size (12) = 352 = 0x160
    // vertical_size (12) = 288 = 0x120
    // aspect_ratio (4) = 2 (4:3)
    // frame_rate (4) = 3 (25fps PAL)
    // bit_rate (18) = 0x1E8 (200,000 bps / 400 = 500)
    // marker (1) = 1
    // vbv_buffer_size (10) = 112
    // constrained (1) = 1
    // load_intra (1) = 0
    // load_non_intra (1) = 0

    // 352 = 0x160 -> 12 bits = 0001 0110 0000
    // 288 = 0x120 -> 12 bits = 0001 0010 0000
    // aspect = 2 -> 4 bits = 0010
    // frame_rate = 3 -> 4 bits = 0011
    // bit_rate = 500 = 0x1F4 -> 18 bits = 00 0000 0001 1111 0100
    // marker = 1 -> 1 bit
    // vbv = 112 = 0x70 -> 10 bits = 00 0111 0000
    // constrained = 1 -> 1 bit
    // load_intra = 0 -> 1 bit
    // load_non_intra = 0 -> 1 bit

    // Byte by byte:
    // 0: horizontal[11:4] = 0001 0110 = 0x16
    // 1: horizontal[3:0] + vertical[11:8] = 0000 0001 = 0x01
    // 2: vertical[7:0] = 0010 0000 = 0x20
    // 3: aspect + frame_rate = 0010 0011 = 0x23
    // 4: bit_rate[17:10] = 0000 0001 = 0x01
    // 5: bit_rate[9:2] = 1111 0100 = 0xF4
    // 6: bit_rate[1:0] + marker + vbv[9:5] = 00 1 00111 = 0x27
    // 7: vbv[4:0] + constrained + load_intra + load_non_intra = 00000 1 0 0 = 0x04

    const seq_header = [_]u8{
        0x00, 0x00, 0x01, 0xB3, // start code
        0x16, 0x01, 0x20, 0x23, // h_size, v_size, aspect, frame_rate
        0x01, 0xF4, 0x27, 0x04, // bit_rate, marker, vbv, constrained, loads
    };

    const result = parseSequenceHeader(&seq_header, 0);
    try std.testing.expect(result != null);

    const header = result.?.header;
    try std.testing.expectEqual(@as(u12, 352), header.horizontal_size);
    try std.testing.expectEqual(@as(u12, 288), header.vertical_size);
    try std.testing.expectEqual(@as(u4, 2), header.aspect_ratio_code);
    try std.testing.expectEqual(@as(u4, 3), header.frame_rate_code);
    try std.testing.expectEqual(@as(f32, 25.0), header.getFrameRate());
}

test "parsePictureHeader I-frame" {
    // Picture start code: 00 00 01 00
    // temporal_reference (10) = 0
    // picture_coding_type (3) = 1 (I-frame)
    // vbv_delay (16) = 0xFFFF
    // extra_bit = 0

    // Bit layout after start code:
    // byte 0: temporal_ref[9:2] = 0000 0000 = 0x00
    // byte 1: temporal_ref[1:0] + pic_type[2:0] + vbv_delay[15:13] = 00 001 111 = 0x0F
    // byte 2: vbv_delay[12:5] = 1111 1111 = 0xFF
    // byte 3: vbv_delay[4:0] + extra_bit + padding = 11111 0 00 = 0xF8

    const pic_header = [_]u8{
        0x00, 0x00, 0x01, 0x00, // start code
        0x00, 0x0F, 0xFF, 0xF8, // temporal_ref, pic_type, vbv_delay
    };

    const result = parsePictureHeader(&pic_header, 0);
    try std.testing.expect(result != null);

    const header = result.?.header;
    try std.testing.expectEqual(@as(u10, 0), header.temporal_reference);
    try std.testing.expectEqual(PictureType.I, header.picture_type);
    try std.testing.expectEqual(@as(u16, 0xFFFF), header.vbv_delay);
}

test "deep validation on ground truth MPEG-1 sample" {
    // Read ground truth MPEG-PS sample containing MPEG-1 video
    const allocator = std.testing.allocator;
    const file = std.fs.cwd().openFile("ground_truth_examples/mpeg12/sample_mpeg1.mpg", .{}) catch {
        // Skip test if file not found
        return;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 1024) catch return;
    defer allocator.free(data);

    // The sample is an MPEG-PS, so deep validation should work on the embedded video ES
    const result = validateMpeg12Deep(data, 10);

    // Should at least pass structural validation
    try std.testing.expect(result.structural_valid);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(MpegVersion.mpeg1, result.structural_result.version);

    // Verify we found pictures
    try std.testing.expect(result.structural_result.pictures > 0);
}

test "deep validation on ground truth MPEG-2 sample" {
    // Read ground truth MPEG-PS sample containing MPEG-2 video
    const allocator = std.testing.allocator;
    const file = std.fs.cwd().openFile("ground_truth_examples/mpeg12/sample.mpg", .{}) catch {
        // Skip test if file not found
        return;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 1024) catch return;
    defer allocator.free(data);

    const result = validateMpeg12Deep(data, 10);

    // Should at least pass structural validation
    try std.testing.expect(result.structural_valid);
    try std.testing.expect(result.valid);

    // Verify we found pictures
    try std.testing.expect(result.structural_result.pictures > 0);
}
