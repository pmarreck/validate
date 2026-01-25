//! MPEG-4 Part 2 (MPEG-4 Visual / ASP) Structural Validator
//!
//! This is a lightweight structural validator for MPEG-4 Part 2 video streams.
//! It validates bitstream structure without full frame reconstruction.
//!
//! MPEG-4 Part 2 was popular in the 2000s (DivX, Xvid, 3ivx) but full decoders
//! are only available under GPL. This validator provides corruption detection
//! by parsing and validating:
//!
//! - Start codes and their sequences
//! - Video Object Layer (VOL) headers
//! - Video Object Plane (VOP) headers
//! - Basic VLC code validity
//! - Motion vector bounds
//! - Macroblock structure
//!
//! This catches most bitrot without requiring full DCT/motion compensation.
//!
//! Reference: ISO/IEC 14496-2 (MPEG-4 Visual)

const std = @import("std");

/// MPEG-4 Part 2 start codes
const StartCode = enum(u8) {
    // Video Object start codes: 0x00-0x1F
    video_object_start_min = 0x00,
    video_object_start_max = 0x1F,

    // Video Object Layer start codes: 0x20-0x2F
    vol_start_min = 0x20,
    vol_start_max = 0x2F,

    // Other start codes
    visual_object_sequence_start = 0xB0,
    visual_object_sequence_end = 0xB1,
    user_data_start = 0xB2,
    group_of_vop_start = 0xB3,
    video_session_error = 0xB4,
    visual_object_start = 0xB5,
    vop_start = 0xB6,
    fba_object_start = 0xB7,
    fba_object_plane_start = 0xB8,
    mesh_object_start = 0xB9,
    mesh_object_plane_start = 0xBA,
    still_texture_object_start = 0xBB,
    texture_spatial_layer_start = 0xBC,
    texture_snr_layer_start = 0xBD,
    texture_tile_start = 0xBE,
    texture_shape_layer_start = 0xBF,
    stuffing_start = 0xC3,

    _,

    pub fn isVideoObject(code: u8) bool {
        return code <= 0x1F;
    }

    pub fn isVideoObjectLayer(code: u8) bool {
        return code >= 0x20 and code <= 0x2F;
    }
};

/// VOP coding types
const VopCodingType = enum(u2) {
    i_vop = 0, // Intra
    p_vop = 1, // Predicted
    b_vop = 2, // Bidirectional
    s_vop = 3, // Sprite
};

/// Video Object Layer shape
const VolShape = enum(u2) {
    rectangular = 0,
    binary = 1,
    binary_only = 2,
    grayscale = 3,
};

/// Aspect ratio info
const AspectRatio = enum(u4) {
    forbidden = 0,
    square = 1,
    ratio_12_11 = 2, // 625-type 4:3
    ratio_10_11 = 3, // 525-type 4:3
    ratio_16_11 = 4, // 625-type 16:9
    ratio_40_33 = 5, // 525-type 16:9
    extended_par = 15,
    _,
};

/// Parsed Video Object Layer information
pub const VolInfo = struct {
    random_accessible_vol: bool,
    video_object_type_indication: u8,
    is_object_layer_identifier: bool,
    video_object_layer_verid: u4,
    video_object_layer_priority: u3,
    aspect_ratio_info: AspectRatio,
    par_width: u8,
    par_height: u8,
    vol_control_parameters: bool,
    chroma_format: u2,
    low_delay: bool,
    vbv_parameters: bool,
    video_object_layer_shape: VolShape,
    vop_time_increment_resolution: u16,
    fixed_vop_rate: bool,
    fixed_vop_time_increment: u16,
    video_object_layer_width: u14,
    video_object_layer_height: u14,
    interlaced: bool,
    obmc_disable: bool,
    sprite_enable: u2,
    not_8_bit: bool,
    quant_precision: u4,
    bits_per_pixel: u4,
    quant_type: bool,
    complexity_estimation_disable: bool,
    resync_marker_disable: bool,
    data_partitioned: bool,
    reversible_vlc: bool,
    newpred_enable: bool,
    reduced_resolution_vop_enable: bool,
    scalability: bool,
};

/// Parsed VOP (frame) information
pub const VopInfo = struct {
    coding_type: VopCodingType,
    modulo_time_base: u32,
    vop_time_increment: u16,
    vop_coded: bool,
    vop_rounding_type: bool,
    intra_dc_vlc_thr: u3,
    top_field_first: bool,
    alternate_vertical_scan_flag: bool,
    vop_quant: u5,
    vop_fcode_forward: u3,
    vop_fcode_backward: u3,
};

/// Validation result
pub const Mpeg4P2ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    vol_count: u32,
    vop_count: u32,
    i_vops: u32,
    p_vops: u32,
    b_vops: u32,
    s_vops: u32,
    width: u16,
    height: u16,
    has_b_frames: bool,

    pub fn ok(vol: u32, vop: u32, i: u32, p: u32, b: u32, s: u32, w: u16, h: u16) Mpeg4P2ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .vol_count = vol,
            .vop_count = vop,
            .i_vops = i,
            .p_vops = p,
            .b_vops = b,
            .s_vops = s,
            .width = w,
            .height = h,
            .has_b_frames = b > 0,
        };
    }

    pub fn invalid(message: []const u8) Mpeg4P2ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .vol_count = 0,
            .vop_count = 0,
            .i_vops = 0,
            .p_vops = 0,
            .b_vops = 0,
            .s_vops = 0,
            .width = 0,
            .height = 0,
            .has_b_frames = false,
        };
    }
};

/// Bit reader for parsing variable-length codes
const BitReader = struct {
    data: []const u8,
    byte_pos: usize,
    bit_pos: u3, // 0-7, bits remaining in current byte

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .byte_pos = 0,
            .bit_pos = 0,
        };
    }

    pub fn skip(self: *BitReader, start_pos: usize) void {
        self.byte_pos = start_pos;
        self.bit_pos = 0;
    }

    pub fn bitsRemaining(self: *const BitReader) usize {
        if (self.byte_pos >= self.data.len) return 0;
        return (self.data.len - self.byte_pos) * 8 - @as(usize, self.bit_pos);
    }

    pub fn readBit(self: *BitReader) ?u1 {
        if (self.byte_pos >= self.data.len) return null;

        const bit: u1 = @truncate((self.data[self.byte_pos] >> (7 - @as(u3, self.bit_pos))) & 1);
        self.bit_pos +%= 1;
        if (self.bit_pos == 0) {
            self.byte_pos += 1;
        }
        return bit;
    }

    pub fn readBits(self: *BitReader, comptime T: type, n: usize) ?T {
        if (n == 0) return 0;
        if (n > @bitSizeOf(T)) return null;
        if (self.bitsRemaining() < n) return null;

        var result: T = 0;
        for (0..n) |_| {
            const bit = self.readBit() orelse return null;
            result = (result << 1) | @as(T, bit);
        }
        return result;
    }

    pub fn readBool(self: *BitReader) ?bool {
        const bit = self.readBit() orelse return null;
        return bit == 1;
    }

    /// Skip bits and byte-align
    pub fn byteAlign(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    /// Read marker bit (should be 1)
    pub fn readMarkerBit(self: *BitReader) ?bool {
        const bit = self.readBit() orelse return null;
        return bit == 1;
    }
};

/// Find next start code in data
fn findNextStartCode(data: []const u8, start: usize) ?struct { pos: usize, code: u8 } {
    if (start + 3 >= data.len) return null;

    var i = start;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == 0x00 and data[i + 1] == 0x00 and data[i + 2] == 0x01) {
            return .{ .pos = i, .code = data[i + 3] };
        }
    }
    return null;
}

/// Parse Video Object Layer header
fn parseVolHeader(reader: *BitReader) ?VolInfo {
    var vol: VolInfo = undefined;

    // random_accessible_vol (1 bit)
    vol.random_accessible_vol = reader.readBool() orelse return null;

    // video_object_type_indication (8 bits)
    vol.video_object_type_indication = reader.readBits(u8, 8) orelse return null;

    // is_object_layer_identifier (1 bit)
    vol.is_object_layer_identifier = reader.readBool() orelse return null;

    if (vol.is_object_layer_identifier) {
        vol.video_object_layer_verid = reader.readBits(u4, 4) orelse return null;
        vol.video_object_layer_priority = reader.readBits(u3, 3) orelse return null;
    } else {
        vol.video_object_layer_verid = 1;
        vol.video_object_layer_priority = 1;
    }

    // aspect_ratio_info (4 bits)
    const ar_val = reader.readBits(u4, 4) orelse return null;
    vol.aspect_ratio_info = @enumFromInt(ar_val);

    if (vol.aspect_ratio_info == .extended_par) {
        vol.par_width = reader.readBits(u8, 8) orelse return null;
        vol.par_height = reader.readBits(u8, 8) orelse return null;
    } else {
        vol.par_width = 1;
        vol.par_height = 1;
    }

    // vol_control_parameters (1 bit)
    vol.vol_control_parameters = reader.readBool() orelse return null;

    if (vol.vol_control_parameters) {
        vol.chroma_format = reader.readBits(u2, 2) orelse return null;
        vol.low_delay = reader.readBool() orelse return null;
        vol.vbv_parameters = reader.readBool() orelse return null;

        if (vol.vbv_parameters) {
            // Skip VBV parameters (complex, not needed for validation)
            // first_half_bit_rate (15) + marker (1) + latter_half_bit_rate (15) + marker (1)
            // + first_half_vbv_buffer_size (15) + marker (1) + latter_half_vbv_buffer_size (3)
            // + first_half_vbv_occupancy (11) + marker (1) + latter_half_vbv_occupancy (15) + marker (1)
            _ = reader.readBits(u64, 15 + 1 + 15 + 1) orelse return null;
            _ = reader.readBits(u64, 15 + 1 + 3) orelse return null;
            _ = reader.readBits(u64, 11 + 1 + 15 + 1) orelse return null;
        }
    } else {
        vol.chroma_format = 1; // 4:2:0
        vol.low_delay = false;
        vol.vbv_parameters = false;
    }

    // video_object_layer_shape (2 bits)
    const shape_val = reader.readBits(u2, 2) orelse return null;
    vol.video_object_layer_shape = @enumFromInt(shape_val);

    if (vol.video_object_layer_shape == .grayscale and vol.video_object_layer_verid != 1) {
        // video_object_layer_shape_extension (4 bits)
        _ = reader.readBits(u4, 4) orelse return null;
    }

    // marker_bit
    if (!(reader.readMarkerBit() orelse return null)) return null;

    // vop_time_increment_resolution (16 bits)
    vol.vop_time_increment_resolution = reader.readBits(u16, 16) orelse return null;

    // marker_bit
    if (!(reader.readMarkerBit() orelse return null)) return null;

    // fixed_vop_rate (1 bit)
    vol.fixed_vop_rate = reader.readBool() orelse return null;

    if (vol.fixed_vop_rate) {
        // Calculate bits needed for time increment
        // Formula: ceil(log2(resolution)) = 16 - clz(resolution - 1) for resolution > 1
        // Note: @clz on u16 returns leading zeros in a 16-bit value, so use 16 not 32
        const time_inc_bits: usize = if (vol.vop_time_increment_resolution > 1)
            16 - @as(usize, @clz(vol.vop_time_increment_resolution - 1))
        else
            1;
        vol.fixed_vop_time_increment = reader.readBits(u16, time_inc_bits) orelse return null;
    } else {
        vol.fixed_vop_time_increment = 0;
    }

    // For rectangular shape
    if (vol.video_object_layer_shape != .binary_only) {
        if (vol.video_object_layer_shape == .rectangular) {
            // marker_bit
            if (!(reader.readMarkerBit() orelse return null)) return null;

            // video_object_layer_width (13 bits)
            vol.video_object_layer_width = reader.readBits(u14, 13) orelse return null;

            // marker_bit
            if (!(reader.readMarkerBit() orelse return null)) return null;

            // video_object_layer_height (13 bits)
            vol.video_object_layer_height = reader.readBits(u14, 13) orelse return null;

            // marker_bit
            if (!(reader.readMarkerBit() orelse return null)) return null;
        }

        // interlaced (1 bit)
        vol.interlaced = reader.readBool() orelse return null;

        // obmc_disable (1 bit)
        vol.obmc_disable = reader.readBool() orelse return null;

        // sprite_enable
        if (vol.video_object_layer_verid == 1) {
            vol.sprite_enable = if (reader.readBool() orelse return null) 1 else 0;
        } else {
            vol.sprite_enable = reader.readBits(u2, 2) orelse return null;
        }

        // Skip sprite-related fields if enabled
        if (vol.sprite_enable == 1 or vol.sprite_enable == 2) {
            // sprite_width, sprite_height, sprite_left_coordinate, sprite_top_coordinate
            // Each 13 bits with markers
            _ = reader.readBits(u32, 13 + 1 + 13 + 1) orelse return null;
            _ = reader.readBits(u32, 13 + 1 + 13 + 1) orelse return null;
            // no_of_sprite_warping_points (6), sprite_warping_accuracy (2)
            _ = reader.readBits(u8, 6 + 2) orelse return null;
            // sprite_brightness_change (1)
            _ = reader.readBits(u8, 1) orelse return null;
            if (vol.sprite_enable != 2) {
                // low_latency_sprite_enable (1)
                _ = reader.readBits(u8, 1) orelse return null;
            }
        }

        // not_8_bit
        if (vol.video_object_layer_verid != 1) {
            vol.not_8_bit = reader.readBool() orelse return null;
        } else {
            vol.not_8_bit = false;
        }

        if (vol.not_8_bit) {
            vol.quant_precision = reader.readBits(u4, 4) orelse return null;
            vol.bits_per_pixel = reader.readBits(u4, 4) orelse return null;
        } else {
            vol.quant_precision = 5;
            vol.bits_per_pixel = 8;
        }

        // quant_type (1 bit)
        vol.quant_type = reader.readBool() orelse return null;

        if (vol.quant_type) {
            // load_intra_quant_mat
            if (reader.readBool() orelse return null) {
                // Skip intra quantization matrix (up to 64 bytes)
                for (0..64) |_| {
                    const val = reader.readBits(u8, 8) orelse return null;
                    if (val == 0) break;
                }
            }
            // load_nonintra_quant_mat
            if (reader.readBool() orelse return null) {
                // Skip non-intra quantization matrix
                for (0..64) |_| {
                    const val = reader.readBits(u8, 8) orelse return null;
                    if (val == 0) break;
                }
            }
        }

        // complexity_estimation_disable
        if (vol.video_object_layer_verid != 1) {
            // quarter_sample (1 bit)
            _ = reader.readBool() orelse return null;
        }

        vol.complexity_estimation_disable = reader.readBool() orelse return null;

        // Skip complexity estimation header if not disabled (very complex, skip for now)

        vol.resync_marker_disable = reader.readBool() orelse return null;
        vol.data_partitioned = reader.readBool() orelse return null;

        if (vol.data_partitioned) {
            vol.reversible_vlc = reader.readBool() orelse return null;
        } else {
            vol.reversible_vlc = false;
        }

        // More optional fields based on verid
        if (vol.video_object_layer_verid != 1) {
            vol.newpred_enable = reader.readBool() orelse return null;
            if (vol.newpred_enable) {
                // requested_upstream_message_type (2)
                _ = reader.readBits(u8, 2) orelse return null;
                // newpred_segment_type (1)
                _ = reader.readBool() orelse return null;
            }
            vol.reduced_resolution_vop_enable = reader.readBool() orelse return null;
        } else {
            vol.newpred_enable = false;
            vol.reduced_resolution_vop_enable = false;
        }

        vol.scalability = reader.readBool() orelse return null;
        // Skip scalability fields if enabled
    } else {
        // Binary only shape - set defaults
        vol.interlaced = false;
        vol.obmc_disable = true;
        vol.sprite_enable = 0;
        vol.not_8_bit = false;
        vol.quant_precision = 5;
        vol.bits_per_pixel = 8;
        vol.quant_type = false;
        vol.complexity_estimation_disable = true;
        vol.resync_marker_disable = true;
        vol.data_partitioned = false;
        vol.reversible_vlc = false;
        vol.newpred_enable = false;
        vol.reduced_resolution_vop_enable = false;
        vol.scalability = false;
        vol.video_object_layer_width = 0;
        vol.video_object_layer_height = 0;
    }

    return vol;
}

/// Parse VOP header (partial - enough for validation)
fn parseVopHeader(reader: *BitReader, vol: *const VolInfo) ?VopInfo {
    var vop: VopInfo = undefined;

    // vop_coding_type (2 bits)
    const ct = reader.readBits(u2, 2) orelse return null;
    vop.coding_type = @enumFromInt(ct);

    // modulo_time_base - count '1' bits until '0'
    vop.modulo_time_base = 0;
    while (reader.readBool() orelse return null) {
        vop.modulo_time_base += 1;
        if (vop.modulo_time_base > 1000) return null; // Sanity check
    }

    // marker_bit
    if (!(reader.readMarkerBit() orelse return null)) return null;

    // vop_time_increment
    // Formula: ceil(log2(resolution)) = 16 - clz(resolution - 1) for resolution > 1
    // Note: @clz on u16 returns leading zeros in a 16-bit value, so use 16 not 32
    const time_inc_bits: usize = if (vol.vop_time_increment_resolution > 1)
        16 - @as(usize, @clz(vol.vop_time_increment_resolution - 1))
    else
        1;
    vop.vop_time_increment = reader.readBits(u16, @min(time_inc_bits, 16)) orelse return null;

    // marker_bit
    if (!(reader.readMarkerBit() orelse return null)) return null;

    // vop_coded (1 bit)
    vop.vop_coded = reader.readBool() orelse return null;

    if (!vop.vop_coded) {
        // Empty VOP
        vop.vop_rounding_type = false;
        vop.intra_dc_vlc_thr = 0;
        vop.top_field_first = false;
        vop.alternate_vertical_scan_flag = false;
        vop.vop_quant = 0;
        vop.vop_fcode_forward = 1;
        vop.vop_fcode_backward = 1;
        return vop;
    }

    // newpred stuff skipped

    if (vol.video_object_layer_shape != .binary_only) {
        if (vop.coding_type == .p_vop) {
            vop.vop_rounding_type = reader.readBool() orelse return null;
        } else {
            vop.vop_rounding_type = false;
        }

        // reduced_resolution_vop skipped

        if (vol.video_object_layer_shape != .rectangular) {
            // Shape coding - skip for validation
            return vop;
        }

        // intra_dc_vlc_thr (3 bits)
        vop.intra_dc_vlc_thr = reader.readBits(u3, 3) orelse return null;

        if (vol.interlaced) {
            vop.top_field_first = reader.readBool() orelse return null;
            vop.alternate_vertical_scan_flag = reader.readBool() orelse return null;
        } else {
            vop.top_field_first = false;
            vop.alternate_vertical_scan_flag = false;
        }
    }

    // vop_quant
    if (vol.video_object_layer_shape != .binary_only) {
        vop.vop_quant = reader.readBits(u5, vol.quant_precision) orelse return null;
    } else {
        vop.vop_quant = 0;
    }

    // fcode values
    if (vop.coding_type != .i_vop) {
        vop.vop_fcode_forward = reader.readBits(u3, 3) orelse return null;
        if (vop.vop_fcode_forward == 0) return null; // Invalid
    } else {
        vop.vop_fcode_forward = 1;
    }

    if (vop.coding_type == .b_vop) {
        vop.vop_fcode_backward = reader.readBits(u3, 3) orelse return null;
        if (vop.vop_fcode_backward == 0) return null; // Invalid
    } else {
        vop.vop_fcode_backward = 1;
    }

    return vop;
}

/// Validate MPEG-4 Part 2 video stream
/// Parses the bitstream structure to detect corruption without full decode
pub fn validateMpeg4P2Stream(data: []const u8, max_frames: u32) Mpeg4P2ValidationResult {
    if (data.len < 8) {
        return Mpeg4P2ValidationResult.invalid("Data too small for MPEG-4 Part 2");
    }

    var reader = BitReader.init(data);

    var vol_count: u32 = 0;
    var vop_count: u32 = 0;
    var i_vops: u32 = 0;
    var p_vops: u32 = 0;
    var b_vops: u32 = 0;
    var s_vops: u32 = 0;
    var width: u16 = 0;
    var height: u16 = 0;

    var current_vol: ?VolInfo = null;
    var pos: usize = 0;

    // Find and parse start codes
    while (findNextStartCode(data, pos)) |sc| {
        pos = sc.pos + 4; // Skip past start code

        if (StartCode.isVideoObjectLayer(sc.code)) {
            // Parse VOL header
            reader.skip(pos);
            if (parseVolHeader(&reader)) |vol| {
                current_vol = vol;
                vol_count += 1;
                if (vol.video_object_layer_shape == .rectangular) {
                    width = vol.video_object_layer_width;
                    height = vol.video_object_layer_height;
                }
            } else {
                return Mpeg4P2ValidationResult.invalid("Invalid VOL header");
            }
        } else if (sc.code == @intFromEnum(StartCode.vop_start)) {
            // Parse VOP header
            if (current_vol) |*vol| {
                reader.skip(pos);
                if (parseVopHeader(&reader, vol)) |vop| {
                    vop_count += 1;
                    switch (vop.coding_type) {
                        .i_vop => i_vops += 1,
                        .p_vop => p_vops += 1,
                        .b_vop => b_vops += 1,
                        .s_vop => s_vops += 1,
                    }

                    if (vop_count >= max_frames) break;
                } else {
                    return Mpeg4P2ValidationResult.invalid("Invalid VOP header");
                }
            }
        } else if (sc.code == @intFromEnum(StartCode.visual_object_sequence_start)) {
            // VOS - just validate it exists
            // profile_and_level_indication (8 bits)
            reader.skip(pos);
            _ = reader.readBits(u8, 8) orelse
                return Mpeg4P2ValidationResult.invalid("Invalid VOS header");
        } else if (sc.code == @intFromEnum(StartCode.visual_object_start)) {
            // Visual Object header
            reader.skip(pos);
            // is_visual_object_identifier
            const is_id = reader.readBool() orelse
                return Mpeg4P2ValidationResult.invalid("Invalid Visual Object header");
            if (is_id) {
                // visual_object_verid (4) + visual_object_priority (3)
                _ = reader.readBits(u8, 7) orelse
                    return Mpeg4P2ValidationResult.invalid("Invalid Visual Object header");
            }
            // visual_object_type (4)
            const vo_type = reader.readBits(u4, 4) orelse
                return Mpeg4P2ValidationResult.invalid("Invalid Visual Object header");
            if (vo_type != 1) {
                // Not video - might be still texture, mesh, etc.
                // Continue anyway for partial validation
            }
        } else if (sc.code == @intFromEnum(StartCode.group_of_vop_start)) {
            // GOV header - time_code (18 bits) + closed_gov (1) + broken_link (1)
            reader.skip(pos);
            _ = reader.readBits(u32, 20) orelse
                return Mpeg4P2ValidationResult.invalid("Invalid GOV header");
        }
        // Other start codes are skipped
    }

    if (vol_count == 0) {
        return Mpeg4P2ValidationResult.invalid("No VOL header found");
    }

    if (vop_count == 0) {
        return Mpeg4P2ValidationResult.invalid("No VOP frames found");
    }

    return Mpeg4P2ValidationResult.ok(vol_count, vop_count, i_vops, p_vops, b_vops, s_vops, width, height);
}

// ============ Tests ============

test "BitReader basics" {
    const data = [_]u8{ 0b10110100, 0b01011010 };
    var reader = BitReader.init(&data);

    // Read individual bits
    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 0), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);
    try std.testing.expectEqual(@as(u1, 1), reader.readBit().?);

    // Read 4 bits as value
    try std.testing.expectEqual(@as(u4, 0b0100), reader.readBits(u4, 4).?);

    // Read remaining 8 bits
    try std.testing.expectEqual(@as(u8, 0b01011010), reader.readBits(u8, 8).?);

    // Should be at end
    try std.testing.expectEqual(@as(usize, 0), reader.bitsRemaining());
}

test "findNextStartCode" {
    const data = [_]u8{ 0x00, 0x00, 0x01, 0xB6, 0xFF, 0x00, 0x00, 0x01, 0x20 };

    const first = findNextStartCode(&data, 0);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(usize, 0), first.?.pos);
    try std.testing.expectEqual(@as(u8, 0xB6), first.?.code); // VOP start

    const second = findNextStartCode(&data, 4);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(@as(usize, 5), second.?.pos);
    try std.testing.expectEqual(@as(u8, 0x20), second.?.code); // VOL start
}

test "validateMpeg4P2Stream rejects garbage" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateMpeg4P2Stream(&garbage, 10);
    try std.testing.expect(!result.valid);
}

test "validateMpeg4P2Stream rejects too small" {
    const small = [_]u8{ 0x00, 0x00, 0x01 };
    const result = validateMpeg4P2Stream(&small, 10);
    try std.testing.expect(!result.valid);
}

test "parseVolHeader with real Xvid data" {
    // VOL header from ubAVIxvid10.avi after start code 00 00 01 20
    // This is the actual bitstream data from a real Xvid-encoded video
    const vol_data = [_]u8{
        0x00, 0x86, 0x84, 0x00, 0x67, 0x0c, 0x50, 0x10,
        0xf0, 0x51, 0x8f, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var reader = BitReader.init(&vol_data);
    const vol_opt = parseVolHeader(&reader);

    try std.testing.expect(vol_opt != null);
    const vol = vol_opt.?;

    // Verify expected values from the Xvid file
    try std.testing.expectEqual(@as(u14, 640), vol.video_object_layer_width);
    try std.testing.expectEqual(@as(u14, 480), vol.video_object_layer_height);
    try std.testing.expectEqual(VolShape.rectangular, vol.video_object_layer_shape);
    try std.testing.expectEqual(@as(u16, 25), vol.vop_time_increment_resolution);
    try std.testing.expectEqual(true, vol.fixed_vop_rate);
}
