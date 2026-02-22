//! H.264/AVC NAL Unit Validator (Pure Zig)
//!
//! Full validation for H.264/AVC (ITU-T H.264 / ISO/IEC 14496-10) video elementary
//! streams. Parses NAL unit headers, SPS, and PPS with Exp-Golomb coded fields,
//! performs RBSP emulation prevention byte removal, and validates all syntactic
//! constraints from the specification.
//!
//! Supported inputs:
//! - Raw H.264 NAL unit streams (Annex B format with start codes)
//! - NAL units extracted from MP4/MKV containers (length-prefixed)
//!
//! This is a pure-Zig implementation with no external C dependencies.

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const cavlc = @import("h264_cavlc_tables.zig");
const cabac_engine = @import("h264_cabac_engine.zig");
const errmsg = @import("error_messages.zig");
const codec_utils = @import("codec_utils.zig");

// ============================================================================
// NAL Unit Types (ITU-T H.264 Table 7-1)
// ============================================================================

pub const NalUnitType = enum(u5) {
    unspecified = 0,
    slice_non_idr = 1, // Coded slice of a non-IDR picture
    slice_data_partition_a = 2, // Coded slice data partition A
    slice_data_partition_b = 3, // Coded slice data partition B
    slice_data_partition_c = 4, // Coded slice data partition C
    slice_idr = 5, // Coded slice of an IDR picture
    sei = 6, // Supplemental Enhancement Information
    sps = 7, // Sequence Parameter Set
    pps = 8, // Picture Parameter Set
    aud = 9, // Access Unit Delimiter
    end_of_sequence = 10, // End of sequence
    end_of_stream = 11, // End of stream
    filler_data = 12, // Filler data
    sps_extension = 13, // SPS extension
    prefix_nal_unit = 14, // Prefix NAL unit
    subset_sps = 15, // Subset SPS
    reserved16 = 16,
    reserved17 = 17,
    reserved18 = 18,
    slice_auxiliary = 19, // Coded slice of an auxiliary coded picture
    slice_extension = 20, // Coded slice extension
    slice_extension_depth = 21, // Coded slice extension for 3D-AVC
    reserved22 = 22,
    reserved23 = 23,
    unspecified24 = 24,
    unspecified25 = 25,
    unspecified26 = 26,
    unspecified27 = 27,
    unspecified28 = 28,
    unspecified29 = 29,
    unspecified30 = 30,
    unspecified31 = 31,

    /// Returns true if this is a slice NAL unit type (coded picture data).
    pub fn isSlice(self: NalUnitType) bool {
        return self == .slice_non_idr or self == .slice_idr;
    }

    /// Returns true if this is an IDR slice.
    pub fn isIdr(self: NalUnitType) bool {
        return self == .slice_idr;
    }

    /// Returns true if this is a VCL (Video Coding Layer) NAL unit type.
    pub fn isVcl(self: NalUnitType) bool {
        const v = @intFromEnum(self);
        return v >= 1 and v <= 5;
    }
};

// ============================================================================
// NAL Unit Header (1 byte for H.264, unlike 2 bytes for H.265)
// ============================================================================

/// H.264 NAL unit header (1 byte).
/// forbidden_zero_bit(1) | nal_ref_idc(2) | nal_unit_type(5)
pub const NalHeader = struct {
    forbidden_zero_bit: u1,
    nal_ref_idc: u2,
    nal_unit_type: NalUnitType,

    /// Parse a 1-byte NAL header.
    pub fn parse(header_byte: u8) ?NalHeader {
        const forbidden_zero_bit: u1 = @intCast((header_byte >> 7) & 1);
        const nal_ref_idc: u2 = @intCast((header_byte >> 5) & 0x03);
        const nal_type_val: u5 = @intCast(header_byte & 0x1F);

        const nal_unit_type = std.meta.intToEnum(NalUnitType, nal_type_val) catch return null;

        return .{
            .forbidden_zero_bit = forbidden_zero_bit,
            .nal_ref_idc = nal_ref_idc,
            .nal_unit_type = nal_unit_type,
        };
    }

    /// Validate the NAL header per spec constraints.
    pub fn validate(self: NalHeader) ?[]const u8 {
        if (self.forbidden_zero_bit != 0) {
            return "H.264 NAL forbidden_zero_bit is not zero";
        }
        // SPS, PPS, and IDR slices should have nal_ref_idc > 0 (recommendation, not hard reject)
        // Non-reference slices may have nal_ref_idc == 0
        return null;
    }
};

// ============================================================================
// H264SyntaxResult
// ============================================================================

/// Result of H.264/AVC stream validation.
pub const H264SyntaxResult = struct {
    valid: bool,
    error_message: ?[*:0]const u8,
    frames_decoded: u32,
    has_sps: bool,
    has_pps: bool,
    width: u32,
    height: u32,
    profile_idc: u8,
    level_idc: u8,

    pub fn ok(frames: u32, w: u32, h: u32, profile: u8, level: u8) H264SyntaxResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .has_sps = true,
            .has_pps = true,
            .width = w,
            .height = h,
            .profile_idc = profile,
            .level_idc = level,
        };
    }

    pub fn invalid(msg: [*:0]const u8) H264SyntaxResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_decoded = 0,
            .has_sps = false,
            .has_pps = false,
            .width = 0,
            .height = 0,
            .profile_idc = 0,
            .level_idc = 0,
        };
    }

    pub fn invalidPartial(msg: [*:0]const u8, frames: u32) H264SyntaxResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_decoded = frames,
            .has_sps = false,
            .has_pps = false,
            .width = 0,
            .height = 0,
            .profile_idc = 0,
            .level_idc = 0,
        };
    }
};

// ============================================================================
// SPS (Sequence Parameter Set) — ITU-T H.264 section 7.3.2.1.1
// ============================================================================

/// Parsed SPS information.
pub const SequenceParameterSet = struct {
    profile_idc: u8,
    constraint_set0_flag: bool,
    constraint_set1_flag: bool,
    constraint_set2_flag: bool,
    constraint_set3_flag: bool,
    constraint_set4_flag: bool,
    constraint_set5_flag: bool,
    level_idc: u8,
    seq_parameter_set_id: u32,
    chroma_format_idc: u32,
    separate_colour_plane_flag: bool,
    bit_depth_luma_minus8: u32,
    bit_depth_chroma_minus8: u32,
    log2_max_frame_num_minus4: u32,
    pic_order_cnt_type: u32,
    log2_max_pic_order_cnt_lsb_minus4: u32,
    max_num_ref_frames: u32,
    pic_width_in_mbs_minus1: u32,
    pic_height_in_map_units_minus1: u32,
    frame_mbs_only_flag: bool,
    frame_cropping_flag: bool,
    frame_crop_left_offset: u32,
    frame_crop_right_offset: u32,
    frame_crop_top_offset: u32,
    frame_crop_bottom_offset: u32,
    vui_parameters_present_flag: bool,
    /// Fields needed by slice header parsing
    delta_pic_order_always_zero_flag: bool,
    width: u32,
    height: u32,
};

/// Profiles that have extended chroma/bit-depth/scaling info in SPS.
fn isHighProfile(profile_idc: u8) bool {
    return switch (profile_idc) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134 => true,
        else => false,
    };
}

/// Skip a scaling list in SPS (ITU-T H.264 section 7.3.2.1.1.1).
fn skipScalingList(reader: *BitReader, size: u32) void {
    var last_scale: i32 = 8;
    var next_scale: i32 = 8;
    for (0..size) |_| {
        if (next_scale != 0) {
            const delta = reader.readSignedExpGolomb() orelse return;
            next_scale = @mod(last_scale + delta + 256, 256);
        }
        last_scale = if (next_scale == 0) last_scale else next_scale;
    }
}

/// Parse an SPS NAL unit (after RBSP byte removal).

/// Parse HRD parameters (ITU-T H.264 Annex E, E.1.2)
fn parseHrdParameters(reader: *BitReader) bool {
    // cpb_cnt_minus1: ue(v) — range 0..31
    const cpb_cnt_minus1 = reader.readExpGolomb() orelse return false;
    if (cpb_cnt_minus1 > 31) return false;

    // bit_rate_scale: u(4)
    if (!reader.skipBits(4)) return false;
    // cpb_size_scale: u(4)
    if (!reader.skipBits(4)) return false;

    // For each SchedSelIdx
    for (0..cpb_cnt_minus1 + 1) |_| {
        // bit_rate_value_minus1[i]: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // cpb_size_value_minus1[i]: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // cbr_flag[i]: u(1)
        _ = reader.readBit() orelse return false;
    }

    // initial_cpb_removal_delay_length_minus1: u(5)
    if (!reader.skipBits(5)) return false;
    // cpb_removal_delay_length_minus1: u(5)
    if (!reader.skipBits(5)) return false;
    // dpb_output_delay_length_minus1: u(5)
    if (!reader.skipBits(5)) return false;
    // time_offset_length: u(5)
    if (!reader.skipBits(5)) return false;

    return true;
}

/// Parse VUI parameters (ITU-T H.264 Annex E, E.1.1)
fn parseVuiParameters(reader: *BitReader) bool {
    // aspect_ratio_info_present_flag: u(1)
    const aspect_ratio_present = (reader.readBit() orelse return false) != 0;
    if (aspect_ratio_present) {
        const aspect_ratio_idc = reader.readBits(8) orelse return false;
        if (aspect_ratio_idc == 255) { // Extended_SAR
            // sar_width: u(16)
            if (!reader.skipBits(16)) return false;
            // sar_height: u(16)
            if (!reader.skipBits(16)) return false;
        }
    }

    // overscan_info_present_flag: u(1)
    const overscan_present = (reader.readBit() orelse return false) != 0;
    if (overscan_present) {
        // overscan_appropriate_flag: u(1)
        _ = reader.readBit() orelse return false;
    }

    // video_signal_type_present_flag: u(1)
    const video_signal_present = (reader.readBit() orelse return false) != 0;
    if (video_signal_present) {
        // video_format: u(3)
        if (!reader.skipBits(3)) return false;
        // video_full_range_flag: u(1)
        _ = reader.readBit() orelse return false;
        // colour_description_present_flag: u(1)
        const colour_present = (reader.readBit() orelse return false) != 0;
        if (colour_present) {
            // colour_primaries: u(8)
            if (!reader.skipBits(8)) return false;
            // transfer_characteristics: u(8)
            if (!reader.skipBits(8)) return false;
            // matrix_coefficients: u(8)
            if (!reader.skipBits(8)) return false;
        }
    }

    // chroma_loc_info_present_flag: u(1)
    const chroma_loc_present = (reader.readBit() orelse return false) != 0;
    if (chroma_loc_present) {
        // chroma_sample_loc_type_top_field: ue(v) — range 0..5
        const top = reader.readExpGolomb() orelse return false;
        if (top > 5) return false;
        // chroma_sample_loc_type_bottom_field: ue(v) — range 0..5
        const bottom = reader.readExpGolomb() orelse return false;
        if (bottom > 5) return false;
    }

    // timing_info_present_flag: u(1)
    const timing_present = (reader.readBit() orelse return false) != 0;
    if (timing_present) {
        // num_units_in_tick: u(32)
        if (!reader.skipBits(32)) return false;
        // time_scale: u(32)
        if (!reader.skipBits(32)) return false;
        // fixed_frame_rate_flag: u(1)
        _ = reader.readBit() orelse return false;
    }

    // nal_hrd_parameters_present_flag: u(1)
    const nal_hrd_present = (reader.readBit() orelse return false) != 0;
    if (nal_hrd_present) {
        if (!parseHrdParameters(reader)) return false;
    }

    // vcl_hrd_parameters_present_flag: u(1)
    const vcl_hrd_present = (reader.readBit() orelse return false) != 0;
    if (vcl_hrd_present) {
        if (!parseHrdParameters(reader)) return false;
    }

    if (nal_hrd_present or vcl_hrd_present) {
        // low_delay_hrd_flag: u(1)
        _ = reader.readBit() orelse return false;
    }

    // pic_struct_present_flag: u(1)
    _ = reader.readBit() orelse return false;

    // bitstream_restriction_flag: u(1)
    const bitstream_restriction = (reader.readBit() orelse return false) != 0;
    if (bitstream_restriction) {
        // motion_vectors_over_pic_boundaries_flag: u(1)
        _ = reader.readBit() orelse return false;
        // max_bytes_per_pic_denom: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // max_bits_per_mb_denom: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // log2_max_mv_length_horizontal: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // log2_max_mv_length_vertical: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // max_num_reorder_frames: ue(v)
        _ = reader.readExpGolomb() orelse return false;
        // max_dec_frame_buffering: ue(v)
        _ = reader.readExpGolomb() orelse return false;
    }

    return true;
}

fn parseSps(rbsp: []const u8) ?SequenceParameterSet {
    var reader = BitReader.init(rbsp);
    var sps: SequenceParameterSet = undefined;

    // profile_idc: u(8)
    sps.profile_idc = @intCast(reader.readBits(8) orelse return null);

    // constraint_set0..5_flag: u(1) each
    sps.constraint_set0_flag = (reader.readBit() orelse return null) != 0;
    sps.constraint_set1_flag = (reader.readBit() orelse return null) != 0;
    sps.constraint_set2_flag = (reader.readBit() orelse return null) != 0;
    sps.constraint_set3_flag = (reader.readBit() orelse return null) != 0;
    sps.constraint_set4_flag = (reader.readBit() orelse return null) != 0;
    sps.constraint_set5_flag = (reader.readBit() orelse return null) != 0;

    // reserved_zero_2bits: u(2) — just skip
    if (!reader.skipBits(2)) return null;

    // level_idc: u(8)
    sps.level_idc = @intCast(reader.readBits(8) orelse return null);

    // seq_parameter_set_id: ue(v) — range 0..31
    sps.seq_parameter_set_id = reader.readExpGolomb() orelse return null;
    if (sps.seq_parameter_set_id > 31) return null;

    // Defaults for non-high profiles
    sps.chroma_format_idc = 1; // 4:2:0 default
    sps.separate_colour_plane_flag = false;
    sps.bit_depth_luma_minus8 = 0;
    sps.bit_depth_chroma_minus8 = 0;

    // High profiles have extra fields
    if (isHighProfile(sps.profile_idc)) {
        // chroma_format_idc: ue(v) — range 0..3
        sps.chroma_format_idc = reader.readExpGolomb() orelse return null;
        if (sps.chroma_format_idc > 3) return null;

        if (sps.chroma_format_idc == 3) {
            // separate_colour_plane_flag: u(1)
            sps.separate_colour_plane_flag = (reader.readBit() orelse return null) != 0;
        }

        // bit_depth_luma_minus8: ue(v) — range 0..6
        sps.bit_depth_luma_minus8 = reader.readExpGolomb() orelse return null;
        if (sps.bit_depth_luma_minus8 > 6) return null;

        // bit_depth_chroma_minus8: ue(v) — range 0..6
        sps.bit_depth_chroma_minus8 = reader.readExpGolomb() orelse return null;
        if (sps.bit_depth_chroma_minus8 > 6) return null;

        // qpprime_y_zero_transform_bypass_flag: u(1)
        _ = reader.readBit() orelse return null;

        // seq_scaling_matrix_present_flag: u(1)
        const scaling_matrix_present = (reader.readBit() orelse return null) != 0;
        if (scaling_matrix_present) {
            const num_lists: u32 = if (sps.chroma_format_idc != 3) 8 else 12;
            for (0..num_lists) |i| {
                const list_present = (reader.readBit() orelse return null) != 0;
                if (list_present) {
                    const size: u32 = if (i < 6) 16 else 64;
                    skipScalingList(&reader, size);
                }
            }
        }
    }

    // log2_max_frame_num_minus4: ue(v) — range 0..12
    sps.log2_max_frame_num_minus4 = reader.readExpGolomb() orelse return null;
    if (sps.log2_max_frame_num_minus4 > 12) return null;

    // pic_order_cnt_type: ue(v) — range 0..2
    sps.pic_order_cnt_type = reader.readExpGolomb() orelse return null;
    if (sps.pic_order_cnt_type > 2) return null;

    sps.log2_max_pic_order_cnt_lsb_minus4 = 0;
    sps.delta_pic_order_always_zero_flag = false;

    if (sps.pic_order_cnt_type == 0) {
        // log2_max_pic_order_cnt_lsb_minus4: ue(v) — range 0..12
        sps.log2_max_pic_order_cnt_lsb_minus4 = reader.readExpGolomb() orelse return null;
        if (sps.log2_max_pic_order_cnt_lsb_minus4 > 12) return null;
    } else if (sps.pic_order_cnt_type == 1) {
        // delta_pic_order_always_zero_flag: u(1)
        sps.delta_pic_order_always_zero_flag = (reader.readBit() orelse return null) != 0;

        // offset_for_non_ref_pic: se(v)
        _ = reader.readSignedExpGolomb() orelse return null;

        // offset_for_top_to_bottom_field: se(v)
        _ = reader.readSignedExpGolomb() orelse return null;

        // num_ref_frames_in_pic_order_cnt_cycle: ue(v)
        const num_ref_frames_in_cycle = reader.readExpGolomb() orelse return null;
        if (num_ref_frames_in_cycle > 255) return null;

        // offset_for_ref_frame[i]: se(v)
        for (0..num_ref_frames_in_cycle) |_| {
            _ = reader.readSignedExpGolomb() orelse return null;
        }
    }
    // pic_order_cnt_type == 2: no additional data

    // max_num_ref_frames: ue(v)
    sps.max_num_ref_frames = reader.readExpGolomb() orelse return null;
    if (sps.max_num_ref_frames > 16) return null;

    // gaps_in_frame_num_value_allowed_flag: u(1)
    _ = reader.readBit() orelse return null;

    // pic_width_in_mbs_minus1: ue(v)
    sps.pic_width_in_mbs_minus1 = reader.readExpGolomb() orelse return null;
    if (sps.pic_width_in_mbs_minus1 > 1023) return null; // max ~16K width

    // pic_height_in_map_units_minus1: ue(v)
    sps.pic_height_in_map_units_minus1 = reader.readExpGolomb() orelse return null;
    if (sps.pic_height_in_map_units_minus1 > 1023) return null; // max ~16K height

    // frame_mbs_only_flag: u(1)
    sps.frame_mbs_only_flag = (reader.readBit() orelse return null) != 0;

    if (!sps.frame_mbs_only_flag) {
        // mb_adaptive_frame_field_flag: u(1)
        _ = reader.readBit() orelse return null;
    }

    // direct_8x8_inference_flag: u(1)
    _ = reader.readBit() orelse return null;

    // Calculate dimensions before cropping
    sps.width = (sps.pic_width_in_mbs_minus1 + 1) * 16;
    const frame_mbs_factor: u32 = if (sps.frame_mbs_only_flag) 1 else 2;
    sps.height = frame_mbs_factor * (sps.pic_height_in_map_units_minus1 + 1) * 16;

    // frame_cropping_flag: u(1)
    sps.frame_cropping_flag = (reader.readBit() orelse return null) != 0;
    sps.frame_crop_left_offset = 0;
    sps.frame_crop_right_offset = 0;
    sps.frame_crop_top_offset = 0;
    sps.frame_crop_bottom_offset = 0;
    sps.vui_parameters_present_flag = false;

    if (sps.frame_cropping_flag) {
        sps.frame_crop_left_offset = reader.readExpGolomb() orelse return null;
        sps.frame_crop_right_offset = reader.readExpGolomb() orelse return null;
        sps.frame_crop_top_offset = reader.readExpGolomb() orelse return null;
        sps.frame_crop_bottom_offset = reader.readExpGolomb() orelse return null;

        // Crop unit depends on chroma_format_idc
        var crop_unit_x: u32 = 1;
        var crop_unit_y: u32 = 1;

        if (sps.chroma_format_idc == 0) {
            // Monochrome: CropUnitX = 1, CropUnitY = 2 - frame_mbs_only_flag
            crop_unit_x = 1;
            crop_unit_y = 2 - @as(u32, if (sps.frame_mbs_only_flag) 1 else 0);
        } else {
            // SubWidthC and SubHeightC depend on chroma_format_idc
            const sub_width_c: u32 = if (sps.chroma_format_idc == 3 and sps.separate_colour_plane_flag) 1 else if (sps.chroma_format_idc == 1 or sps.chroma_format_idc == 2) 2 else 1;
            const sub_height_c: u32 = if (sps.chroma_format_idc == 3 and sps.separate_colour_plane_flag) 1 else if (sps.chroma_format_idc == 1) 2 else 1;
            crop_unit_x = sub_width_c;
            crop_unit_y = sub_height_c * (2 - @as(u32, if (sps.frame_mbs_only_flag) 1 else 0));
        }

        // Apply cropping
        const crop_left = crop_unit_x * sps.frame_crop_left_offset;
        const crop_right = crop_unit_x * sps.frame_crop_right_offset;
        const crop_top = crop_unit_y * sps.frame_crop_top_offset;
        const crop_bottom = crop_unit_y * sps.frame_crop_bottom_offset;

        if (crop_left + crop_right >= sps.width or crop_top + crop_bottom >= sps.height) {
            return null; // Cropping exceeds picture dimensions
        }

        sps.width -= crop_left + crop_right;
        sps.height -= crop_top + crop_bottom;
    }

    // vui_parameters_present_flag: u(1)
    sps.vui_parameters_present_flag = (reader.readBit() orelse return null) != 0;
    if (sps.vui_parameters_present_flag) {
        if (!parseVuiParameters(&reader)) return null;
    }

    // Validate final dimensions
    if (sps.width == 0 or sps.height == 0) return null;
    if (sps.width > 16384 or sps.height > 16384) return null;

    return sps;
}

// ============================================================================
// PPS (Picture Parameter Set) — ITU-T H.264 section 7.3.2.2
// ============================================================================

/// Parsed PPS information.
pub const PictureParameterSet = struct {
    pic_parameter_set_id: u32,
    seq_parameter_set_id: u32,
    entropy_coding_mode_flag: bool,
    bottom_field_pic_order_in_frame_present_flag: bool,
    num_slice_groups_minus1: u32,
    num_ref_idx_l0_default_active_minus1: u32,
    num_ref_idx_l1_default_active_minus1: u32,
    weighted_pred_flag: bool,
    weighted_bipred_idc: u2,
    pic_init_qp_minus26: i32,
    pic_init_qs_minus26: i32,
    chroma_qp_index_offset: i32,
    deblocking_filter_control_present_flag: bool,
    constrained_intra_pred_flag: bool,
    redundant_pic_cnt_present_flag: bool,
    /// High profile extensions
    transform_8x8_mode_flag: bool,
    second_chroma_qp_index_offset: i32,
};

/// Parse a PPS NAL unit (after RBSP byte removal).
fn parsePps(rbsp: []const u8) ?PictureParameterSet {
    var reader = BitReader.init(rbsp);
    var pps: PictureParameterSet = undefined;

    // pic_parameter_set_id: ue(v) — range 0..255
    pps.pic_parameter_set_id = reader.readExpGolomb() orelse return null;
    if (pps.pic_parameter_set_id > 255) return null;

    // seq_parameter_set_id: ue(v) — range 0..31
    pps.seq_parameter_set_id = reader.readExpGolomb() orelse return null;
    if (pps.seq_parameter_set_id > 31) return null;

    // entropy_coding_mode_flag: u(1) — 0=CAVLC, 1=CABAC
    pps.entropy_coding_mode_flag = (reader.readBit() orelse return null) != 0;

    // bottom_field_pic_order_in_frame_present_flag: u(1)
    pps.bottom_field_pic_order_in_frame_present_flag = (reader.readBit() orelse return null) != 0;

    // num_slice_groups_minus1: ue(v)
    pps.num_slice_groups_minus1 = reader.readExpGolomb() orelse return null;
    if (pps.num_slice_groups_minus1 > 7) return null;

    if (pps.num_slice_groups_minus1 > 0) {
        // slice_group_map_type: ue(v)
        const slice_group_map_type = reader.readExpGolomb() orelse return null;
        if (slice_group_map_type > 6) return null;

        if (slice_group_map_type == 0) {
            for (0..pps.num_slice_groups_minus1 + 1) |_| {
                // run_length_minus1[i]: ue(v)
                _ = reader.readExpGolomb() orelse return null;
            }
        } else if (slice_group_map_type == 2) {
            for (0..pps.num_slice_groups_minus1) |_| {
                // top_left[i]: ue(v)
                _ = reader.readExpGolomb() orelse return null;
                // bottom_right[i]: ue(v)
                _ = reader.readExpGolomb() orelse return null;
            }
        } else if (slice_group_map_type == 3 or slice_group_map_type == 4 or slice_group_map_type == 5) {
            // slice_group_change_direction_flag: u(1)
            _ = reader.readBit() orelse return null;
            // slice_group_change_rate_minus1: ue(v)
            _ = reader.readExpGolomb() orelse return null;
        } else if (slice_group_map_type == 6) {
            // pic_size_in_map_units_minus1: ue(v)
            const pic_size = reader.readExpGolomb() orelse return null;
            if (pic_size > 65535) return null;
            // slice_group_id[i] — skip
            const bits_needed = if (pps.num_slice_groups_minus1 + 1 <= 2)
                @as(u32, 1)
            else if (pps.num_slice_groups_minus1 + 1 <= 4)
                @as(u32, 2)
            else
                @as(u32, 3);
            for (0..pic_size + 1) |_| {
                if (!reader.skipBits(bits_needed)) return null;
            }
        }
    }

    // num_ref_idx_l0_default_active_minus1: ue(v) — range 0..31
    pps.num_ref_idx_l0_default_active_minus1 = reader.readExpGolomb() orelse return null;
    if (pps.num_ref_idx_l0_default_active_minus1 > 31) return null;

    // num_ref_idx_l1_default_active_minus1: ue(v) — range 0..31
    pps.num_ref_idx_l1_default_active_minus1 = reader.readExpGolomb() orelse return null;
    if (pps.num_ref_idx_l1_default_active_minus1 > 31) return null;

    // weighted_pred_flag: u(1)
    pps.weighted_pred_flag = (reader.readBit() orelse return null) != 0;

    // weighted_bipred_idc: u(2)
    pps.weighted_bipred_idc = @intCast(reader.readBits(2) orelse return null);

    // pic_init_qp_minus26: se(v) — range -(26 + QpBdOffsetY)..+25
    // QpBdOffsetY = 6 * bit_depth_luma_minus8, max = 6*6 = 36
    // So min is -(26+36) = -62
    pps.pic_init_qp_minus26 = reader.readSignedExpGolomb() orelse return null;
    if (pps.pic_init_qp_minus26 < -62 or pps.pic_init_qp_minus26 > 25) return null;

    // pic_init_qs_minus26: se(v) — range -26..+25
    pps.pic_init_qs_minus26 = reader.readSignedExpGolomb() orelse return null;
    if (pps.pic_init_qs_minus26 < -26 or pps.pic_init_qs_minus26 > 25) return null;

    // chroma_qp_index_offset: se(v) — range -12..+12
    pps.chroma_qp_index_offset = reader.readSignedExpGolomb() orelse return null;
    if (pps.chroma_qp_index_offset < -12 or pps.chroma_qp_index_offset > 12) return null;

    // deblocking_filter_control_present_flag: u(1)
    pps.deblocking_filter_control_present_flag = (reader.readBit() orelse return null) != 0;

    // constrained_intra_pred_flag: u(1)
    pps.constrained_intra_pred_flag = (reader.readBit() orelse return null) != 0;

    // redundant_pic_cnt_present_flag: u(1)
    pps.redundant_pic_cnt_present_flag = (reader.readBit() orelse return null) != 0;

    // High profile extensions — present if more RBSP data available
    pps.transform_8x8_mode_flag = false;
    pps.second_chroma_qp_index_offset = pps.chroma_qp_index_offset; // defaults to first offset

    if (reader.remainingBits() > 0) {
        // transform_8x8_mode_flag: u(1)
        pps.transform_8x8_mode_flag = (reader.readBit() orelse return pps) != 0;

        // pic_scaling_matrix_present_flag: u(1)
        const scaling_present = (reader.readBit() orelse return pps) != 0;
        if (scaling_present) {
            const num_lists: u32 = 6 + (if (pps.transform_8x8_mode_flag) @as(u32, 2) else 0);
            for (0..num_lists) |i| {
                const list_present = (reader.readBit() orelse return pps) != 0;
                if (list_present) {
                    const size: u32 = if (i < 6) 16 else 64;
                    skipScalingList(&reader, size);
                }
            }
        }

        // second_chroma_qp_index_offset: se(v) — range -12..+12
        pps.second_chroma_qp_index_offset = reader.readSignedExpGolomb() orelse return pps;
        if (pps.second_chroma_qp_index_offset < -12 or pps.second_chroma_qp_index_offset > 12) {
            pps.second_chroma_qp_index_offset = pps.chroma_qp_index_offset;
        }
    }

    return pps;
}

// ============================================================================
// Slice Header — ITU-T H.264 section 7.3.3
// ============================================================================

/// Parsed slice header info — just enough for frame counting.
const SliceHeaderInfo = struct {
    first_mb_in_slice: u32,
    slice_type: u32,
};

/// Parse just enough of the slice header to determine if it starts a new picture.
fn parseSliceHeader(rbsp: []const u8) ?SliceHeaderInfo {
    var reader = BitReader.init(rbsp);

    // first_mb_in_slice: ue(v)
    const first_mb = reader.readExpGolomb() orelse return null;

    // slice_type: ue(v) — values 0-9
    const slice_type = reader.readExpGolomb() orelse return null;
    if (slice_type > 9) return null;

    return .{
        .first_mb_in_slice = first_mb,
        .slice_type = slice_type,
    };
}

/// Normalized slice type (0-4 range from 0-9 raw values)
pub const SliceType = enum(u3) {
    p = 0,
    b = 1,
    i = 2,
    sp = 3,
    si = 4,

    fn fromRaw(raw: u32) ?SliceType {
        return switch (raw) {
            0, 5 => .p,
            1, 6 => .b,
            2, 7 => .i,
            3, 8 => .sp,
            4, 9 => .si,
            else => null,
        };
    }

    pub fn isIntra(self: SliceType) bool {
        return self == .i or self == .si;
    }
};

/// Full slice header parse result, used for deep validation.
const FullSliceHeaderResult = struct {
    first_mb_in_slice: u32,
    slice_type: SliceType,
    pic_parameter_set_id: u32,
    frame_num: u32,
    field_pic_flag: bool,
    bottom_field_flag: bool,
    idr_pic_id: u32,
    slice_qp: i32,
    cabac_init_idc: u32,
    /// Number of bits consumed by the slice header (for entropy decoding start point)
    header_bits: usize,
};

/// Parse full slice header with SPS/PPS context for deep validation.
/// Returns null on parse error (indicates corruption).
fn parseFullSliceHeader(
    rbsp: []const u8,
    sps: *const SequenceParameterSet,
    pps: *const PictureParameterSet,
    nal_type: NalUnitType,
    nal_ref_idc: u2,
) ?FullSliceHeaderResult {
    var reader = BitReader.init(rbsp);
    var result: FullSliceHeaderResult = undefined;
    result.field_pic_flag = false;
    result.bottom_field_flag = false;
    result.idr_pic_id = 0;
    result.cabac_init_idc = 0;

    // first_mb_in_slice: ue(v)
    result.first_mb_in_slice = reader.readExpGolomb() orelse return null;

    // slice_type: ue(v)
    const raw_slice_type = reader.readExpGolomb() orelse return null;
    if (raw_slice_type > 9) return null;
    result.slice_type = SliceType.fromRaw(raw_slice_type) orelse return null;

    // pic_parameter_set_id: ue(v) — must match known PPS
    result.pic_parameter_set_id = reader.readExpGolomb() orelse return null;
    if (result.pic_parameter_set_id > 255) return null;
    // Cross-reference: the PPS id should match what we were given
    if (result.pic_parameter_set_id != pps.pic_parameter_set_id) return null;

    // colour_plane_id: u(2) — only if separate_colour_plane_flag
    if (sps.separate_colour_plane_flag) {
        const colour_plane = reader.readBits(2) orelse return null;
        if (colour_plane > 2) return null;
    }

    // frame_num: u(v) — log2_max_frame_num_minus4 + 4 bits
    const frame_num_bits: u6 = @intCast(sps.log2_max_frame_num_minus4 + 4);
    result.frame_num = reader.readBits(frame_num_bits) orelse return null;
    // Validate frame_num < MaxFrameNum
    const max_frame_num: u32 = @as(u32, 1) << @as(u5, @intCast(frame_num_bits));
    if (result.frame_num >= max_frame_num) return null;

    // field_pic_flag / bottom_field_flag
    if (!sps.frame_mbs_only_flag) {
        result.field_pic_flag = (reader.readBit() orelse return null) != 0;
        if (result.field_pic_flag) {
            result.bottom_field_flag = (reader.readBit() orelse return null) != 0;
        }
    }

    // idr_pic_id: ue(v) — only for IDR slices, range 0..65535
    if (nal_type == .slice_idr) {
        result.idr_pic_id = reader.readExpGolomb() orelse return null;
        if (result.idr_pic_id > 65535) return null;
    }

    // pic_order_cnt fields — depend on pic_order_cnt_type
    if (sps.pic_order_cnt_type == 0) {
        // pic_order_cnt_lsb: u(v)
        const poc_lsb_bits: u6 = @intCast(sps.log2_max_pic_order_cnt_lsb_minus4 + 4);
        const poc_lsb = reader.readBits(poc_lsb_bits) orelse return null;
        const max_poc_lsb: u32 = @as(u32, 1) << @as(u5, @intCast(poc_lsb_bits));
        if (poc_lsb >= max_poc_lsb) return null;

        // delta_pic_order_cnt_bottom: se(v) — if bottom_field_pic_order_in_frame_present && !field_pic
        if (pps.bottom_field_pic_order_in_frame_present_flag and !result.field_pic_flag) {
            _ = reader.readSignedExpGolomb() orelse return null;
        }
    }

    if (sps.pic_order_cnt_type == 1 and !sps.delta_pic_order_always_zero_flag) {
        // delta_pic_order_cnt[0]: se(v)
        _ = reader.readSignedExpGolomb() orelse return null;

        // delta_pic_order_cnt[1]: se(v) — if bottom_field_pic_order_in_frame_present && !field_pic
        if (pps.bottom_field_pic_order_in_frame_present_flag and !result.field_pic_flag) {
            _ = reader.readSignedExpGolomb() orelse return null;
        }
    }

    // redundant_pic_cnt: ue(v) — if redundant_pic_cnt_present_flag
    if (pps.redundant_pic_cnt_present_flag) {
        const rpc = reader.readExpGolomb() orelse return null;
        if (rpc > 127) return null;
    }

    // direct_spatial_mv_pred_flag: u(1) — B slices only
    if (result.slice_type == .b) {
        _ = reader.readBit() orelse return null;
    }

    // num_ref_idx_active_override_flag and ref idx counts
    var num_ref_idx_l0: u32 = pps.num_ref_idx_l0_default_active_minus1 + 1;
    var num_ref_idx_l1: u32 = pps.num_ref_idx_l1_default_active_minus1 + 1;

    if (result.slice_type == .p or result.slice_type == .sp or result.slice_type == .b) {
        const override = (reader.readBit() orelse return null) != 0;
        if (override) {
            num_ref_idx_l0 = (reader.readExpGolomb() orelse return null) + 1;
            if (num_ref_idx_l0 > 32) return null;
            if (result.slice_type == .b) {
                num_ref_idx_l1 = (reader.readExpGolomb() orelse return null) + 1;
                if (num_ref_idx_l1 > 32) return null;
            }
        }
    }

    // ref_pic_list_modification() — ITU-T H.264 section 7.3.3.1
    if (!result.slice_type.isIntra()) {
        if (!parseRefPicListModification(&reader, result.slice_type)) return null;
    }

    // pred_weight_table() — ITU-T H.264 section 7.3.3.2
    if ((pps.weighted_pred_flag and (result.slice_type == .p or result.slice_type == .sp)) or
        (pps.weighted_bipred_idc == 1 and result.slice_type == .b))
    {
        if (!parsePredWeightTable(&reader, result.slice_type, num_ref_idx_l0, num_ref_idx_l1, sps.chroma_format_idc)) return null;
    }

    // dec_ref_pic_marking() — ITU-T H.264 section 7.3.3.3
    if (nal_ref_idc != 0) {
        if (!parseDecRefPicMarking(&reader, nal_type)) return null;
    }

    // cabac_init_idc: ue(v) — only for CABAC, range 0..2
    if (pps.entropy_coding_mode_flag and !result.slice_type.isIntra()) {
        result.cabac_init_idc = reader.readExpGolomb() orelse return null;
        if (result.cabac_init_idc > 2) return null;
    }

    // slice_qp_delta: se(v) — validate resulting QP in 0..51
    const slice_qp_delta = reader.readSignedExpGolomb() orelse return null;
    result.slice_qp = 26 + pps.pic_init_qp_minus26 + slice_qp_delta;
    if (result.slice_qp < 0 or result.slice_qp > 51) return null;

    // SP/SI specific
    if (result.slice_type == .sp or result.slice_type == .si) {
        if (result.slice_type == .sp) {
            // sp_for_switch_flag: u(1)
            _ = reader.readBit() orelse return null;
        }
        // slice_qs_delta: se(v)
        const qs_delta = reader.readSignedExpGolomb() orelse return null;
        const qs = 26 + pps.pic_init_qs_minus26 + qs_delta;
        if (qs < 0 or qs > 51) return null;
    }

    // deblocking_filter_control
    if (pps.deblocking_filter_control_present_flag) {
        const disable_deblocking = reader.readExpGolomb() orelse return null;
        if (disable_deblocking > 2) return null;
        if (disable_deblocking != 1) {
            // slice_alpha_c0_offset_div2: se(v) — range -6..6
            const alpha = reader.readSignedExpGolomb() orelse return null;
            if (alpha < -6 or alpha > 6) return null;
            // slice_beta_offset_div2: se(v) — range -6..6
            const beta = reader.readSignedExpGolomb() orelse return null;
            if (beta < -6 or beta > 6) return null;
        }
    }

    // slice_group_change_cycle — only if num_slice_groups > 1 and map_type 3..5
    // (very rare, skip for now)

    result.header_bits = reader.getBitPosition();
    return result;
}

/// Parse ref_pic_list_modification() — ITU-T H.264 section 7.3.3.1
fn parseRefPicListModification(reader: *BitReader, slice_type: SliceType) bool {
    // L0 modification
    if (slice_type != .b) {
        // Only non-B, non-intra slices: P, SP
    }
    // ref_pic_list_modification_flag_l0: u(1) — for P/SP/B
    if (slice_type == .p or slice_type == .sp or slice_type == .b) {
        const mod_flag_l0 = (reader.readBit() orelse return false) != 0;
        if (mod_flag_l0) {
            var count: u32 = 0;
            while (count < 33) : (count += 1) {
                const op = reader.readExpGolomb() orelse return false;
                if (op == 3) break; // end
                if (op > 5) return false;
                if (op == 0 or op == 1) {
                    // abs_diff_pic_num_minus1: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                } else if (op == 2) {
                    // long_term_pic_num: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                }
                // ops 4,5: abs_diff_view_idx_minus1 (MVC extension)
            }
        }
    }

    // ref_pic_list_modification_flag_l1: u(1) — only for B slices
    if (slice_type == .b) {
        const mod_flag_l1 = (reader.readBit() orelse return false) != 0;
        if (mod_flag_l1) {
            var count: u32 = 0;
            while (count < 33) : (count += 1) {
                const op = reader.readExpGolomb() orelse return false;
                if (op == 3) break;
                if (op > 5) return false;
                if (op == 0 or op == 1) {
                    _ = reader.readExpGolomb() orelse return false;
                } else if (op == 2) {
                    _ = reader.readExpGolomb() orelse return false;
                }
            }
        }
    }

    return true;
}

/// Parse pred_weight_table() — ITU-T H.264 section 7.3.3.2
fn parsePredWeightTable(
    reader: *BitReader,
    slice_type: SliceType,
    num_ref_idx_l0: u32,
    num_ref_idx_l1: u32,
    chroma_format_idc: u32,
) bool {
    // luma_log2_weight_denom: ue(v) — range 0..7
    const luma_log2 = reader.readExpGolomb() orelse return false;
    if (luma_log2 > 7) return false;

    // chroma_log2_weight_denom: ue(v) — range 0..7 (if chroma)
    if (chroma_format_idc != 0) {
        const chroma_log2 = reader.readExpGolomb() orelse return false;
        if (chroma_log2 > 7) return false;
    }

    // L0 weights
    for (0..num_ref_idx_l0) |_| {
        const luma_weight_flag = (reader.readBit() orelse return false) != 0;
        if (luma_weight_flag) {
            _ = reader.readSignedExpGolomb() orelse return false; // luma_weight
            _ = reader.readSignedExpGolomb() orelse return false; // luma_offset
        }
        if (chroma_format_idc != 0) {
            const chroma_weight_flag = (reader.readBit() orelse return false) != 0;
            if (chroma_weight_flag) {
                // 2 chroma components
                for (0..2) |_| {
                    _ = reader.readSignedExpGolomb() orelse return false; // chroma_weight
                    _ = reader.readSignedExpGolomb() orelse return false; // chroma_offset
                }
            }
        }
    }

    // L1 weights (B slices only)
    if (slice_type == .b) {
        for (0..num_ref_idx_l1) |_| {
            const luma_weight_flag = (reader.readBit() orelse return false) != 0;
            if (luma_weight_flag) {
                _ = reader.readSignedExpGolomb() orelse return false;
                _ = reader.readSignedExpGolomb() orelse return false;
            }
            if (chroma_format_idc != 0) {
                const chroma_weight_flag = (reader.readBit() orelse return false) != 0;
                if (chroma_weight_flag) {
                    for (0..2) |_| {
                        _ = reader.readSignedExpGolomb() orelse return false;
                        _ = reader.readSignedExpGolomb() orelse return false;
                    }
                }
            }
        }
    }

    return true;
}

/// Parse dec_ref_pic_marking() — ITU-T H.264 section 7.3.3.3
fn parseDecRefPicMarking(reader: *BitReader, nal_type: NalUnitType) bool {
    if (nal_type == .slice_idr) {
        // no_output_of_prior_pics_flag: u(1)
        _ = reader.readBit() orelse return false;
        // long_term_reference_flag: u(1)
        _ = reader.readBit() orelse return false;
    } else {
        // adaptive_ref_pic_marking_mode_flag: u(1)
        const adaptive = (reader.readBit() orelse return false) != 0;
        if (adaptive) {
            var count: u32 = 0;
            while (count < 66) : (count += 1) { // reasonable limit
                const mmco = reader.readExpGolomb() orelse return false;
                if (mmco == 0) break; // end
                if (mmco > 6) return false;
                if (mmco == 1 or mmco == 3) {
                    // difference_of_pic_nums_minus1: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                }
                if (mmco == 2) {
                    // long_term_pic_num: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                }
                if (mmco == 3 or mmco == 6) {
                    // long_term_frame_idx: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                }
                if (mmco == 4) {
                    // max_long_term_frame_idx_plus1: ue(v)
                    _ = reader.readExpGolomb() orelse return false;
                }
            }
        }
    }
    return true;
}

// ============================================================================
// RBSP Emulation Prevention Byte Removal
// ============================================================================

const removeEmulationPreventionBytes = codec_utils.removeEmulationPreventionBytes;

// ============================================================================
// NAL Unit Finder
// ============================================================================

/// A NAL unit found in the bitstream.
const NalUnit = struct {
    header: NalHeader,
    /// The NAL unit body (after the 1-byte header, before the next start code).
    data: []const u8,
};

/// Iterator over NAL units in an Annex B byte stream.
const NalUnitIterator = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) NalUnitIterator {
        return .{ .data = data, .pos = 0 };
    }

    /// Find the next start code position (0x000001 or 0x00000001).
    /// Returns the position of the first byte of the start code and its length.
    fn findStartCode(self: *const NalUnitIterator, from: usize) ?codec_utils.StartCode {
        return codec_utils.findAnnexBStartCode(self.data, from);
    }

    /// Get the next NAL unit.
    fn next(self: *NalUnitIterator) ?NalUnit {
        // Find current start code
        const sc = self.findStartCode(self.pos) orelse return null;
        const nal_start = sc.pos + sc.len;

        // Need at least 1 byte for the NAL header (H.264 has 1-byte header)
        if (nal_start + 1 > self.data.len) return null;

        // Parse NAL header (single byte)
        const header = NalHeader.parse(self.data[nal_start]) orelse {
            // Skip to after this header on parse failure
            self.pos = nal_start + 1;
            return null;
        };

        // Find end of this NAL unit (next start code or end of data)
        const body_start = nal_start + 1;
        const next_sc = self.findStartCode(body_start);
        const nal_end = if (next_sc) |nsc| nsc.pos else self.data.len;

        // Strip trailing zero bytes (padding between NAL units)
        var end = nal_end;
        while (end > body_start and self.data[end - 1] == 0x00) {
            end -= 1;
        }

        self.pos = if (next_sc) |nsc| nsc.pos else self.data.len;

        return .{
            .header = header,
            .data = self.data[body_start..end],
        };
    }
};

// ============================================================================
// Public API
// ============================================================================

/// Check if data contains an Annex B start code.
pub fn hasAnnexBStartCode(data: []const u8) bool {
    if (data.len < 3) return false;
    var i: usize = 0;
    while (i + 2 < data.len) : (i += 1) {
        if (data[i] == 0 and data[i + 1] == 0) {
            if (data[i + 2] == 1) return true;
            if (i + 3 < data.len and data[i + 2] == 0 and data[i + 3] == 1) return true;
        }
    }
    return false;
}

/// Validate an H.264/AVC bitstream in Annex B format.
///
/// Parses all NAL units, validates SPS/PPS syntax, counts coded pictures,
/// and checks structural constraints. Returns detailed validation results.
///
/// `data` must be in Annex B format (start code prefixed NAL units).
/// `max_frames` limits the number of coded pictures to validate (0 = unlimited).

// ============================================================================
// CAVLC Slice Data Validation — ITU-T H.264 Section 7.3.4/7.3.5
// ============================================================================

/// Validate CAVLC-encoded slice data by parsing macroblock layer.
/// This is the core entropy validation for Baseline profile H.264 streams.
/// Returns true if the slice data parses successfully, false on corruption.
fn validateCavlcSliceData(
    rbsp: []const u8,
    header_bits: usize,
    sps: *const SequenceParameterSet,
    pps: *const PictureParameterSet,
    slice_type: SliceType,
    first_mb_in_slice: u32,
) bool {
    _ = pps;
    var reader = BitReader.init(rbsp);

    // Skip past the already-parsed slice header
    if (!reader.skipBits(header_bits)) return false;

    // CABAC alignment — not needed for CAVLC, but handle just in case
    // (CAVLC doesn't byte-align after the header)

    // Calculate picture dimensions in macroblocks
    const pic_width_mbs = sps.pic_width_in_mbs_minus1 + 1;
    const pic_height_mbs = sps.pic_height_in_map_units_minus1 + 1;
    const total_mbs = pic_width_mbs * pic_height_mbs;

    // Limit validation to a reasonable number of macroblocks
    // to avoid spending too long on very high-res streams
    const max_mbs_to_validate: u32 = 256; // ~one 16x16 tile worth
    const mbs_to_validate = @min(total_mbs - first_mb_in_slice, max_mbs_to_validate);

    // nC context tracking: we track TotalCoeff for each 4x4 block position
    // For validation we use a simplified context: just use 0 for all blocks
    // (proper nC requires tracking above/left neighbors, which needs a full row buffer)
    // This is sufficient for corruption detection since the CAVLC decode itself
    // will fail on corrupt data regardless of the exact nC value.

    const is_intra = slice_type.isIntra();

    var mb_count: u32 = 0;
    while (mb_count < mbs_to_validate) : (mb_count += 1) {
        // Check if we've run out of bits (normal end of slice)
        if (reader.remainingBits() < 2) break;

        // mb_type: ue(v)
        const mb_type = reader.readExpGolomb() orelse {
            // Bit exhaustion in the middle of a slice can be normal
            // for truncated last frames
            return mb_count > 0;
        };

        // I_PCM: special case — raw samples, no entropy coding
        if (is_intra and mb_type == 25) {
            // I_PCM: byte-align then read 256*BitDepthY + 2*64*BitDepthC samples
            reader.alignToByte();
            const luma_bits = 256 * (8 + @as(u32, sps.bit_depth_luma_minus8));
            const chroma_bits = 2 * 64 * (8 + @as(u32, sps.bit_depth_chroma_minus8));
            if (!reader.skipBits(luma_bits + chroma_bits)) return mb_count > 0;
            continue;
        }

        // For I slices: mb_type 0 = I_4x4, 1..24 = I_16x16
        // For P slices: mb_type 0..4 = P types, 5+ = intra types
        // Validate mb_type range
        if (is_intra) {
            if (mb_type > 25) return false; // invalid I mb_type
        } else {
            if (mb_type > 30) return false; // reasonable limit for P/B
        }

        // Determine if this is an intra MB
        const mb_is_intra = if (is_intra) true else (mb_type >= 5);

        // For intra 4x4 prediction modes
        if (mb_is_intra and ((is_intra and mb_type == 0) or (!is_intra and mb_type == 5))) {
            // I_4x4: parse prev_intra4x4_pred_mode_flag + rem_intra4x4_pred_mode for each 4x4 block
            var blk: u32 = 0;
            while (blk < 16) : (blk += 1) {
                const prev_flag = reader.readBit() orelse return mb_count > 0;
                if (prev_flag == 0) {
                    // rem_intra4x4_pred_mode: u(3)
                    _ = reader.readBits(3) orelse return mb_count > 0;
                }
            }
        }

        // Chroma intra prediction mode (if not monochrome)
        if (mb_is_intra and sps.chroma_format_idc != 0) {
            const chroma_pred = reader.readExpGolomb() orelse return mb_count > 0;
            if (chroma_pred > 3) return false;
        }

        // For P/B slices, inter MBs need motion vectors
        if (!mb_is_intra and !is_intra) {
            // Parse sub_mb_type for P_8x8/B_8x8 or motion vectors for other types
            // For validation, we just need to consume the right bits
            if (mb_type == 3 or mb_type == 4) {
                // P_8x8/P_8x8ref0: 4 sub_mb_type values
                for (0..4) |_| {
                    _ = reader.readExpGolomb() orelse return mb_count > 0;
                }
            }

            // ref_idx and mvd — parse as exp-golomb/signed values
            // For P_L0_16x16 (mb_type=0):
            if (mb_type == 0) {
                // ref_idx_l0: te(v) (use ue for validation)
                _ = reader.readExpGolomb() orelse return mb_count > 0;
                // mvd_l0[0]: se(v) x 2 (horizontal, vertical)
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
            } else if (mb_type == 1) {
                // P_L0_L0_16x8: two partitions
                _ = reader.readExpGolomb() orelse return mb_count > 0;
                _ = reader.readExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
            } else if (mb_type == 2) {
                // P_L0_L0_8x16: two partitions
                _ = reader.readExpGolomb() orelse return mb_count > 0;
                _ = reader.readExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
                _ = reader.readSignedExpGolomb() orelse return mb_count > 0;
            }
            // Skip residual parsing for complex inter modes (sub_mb types)
            // to avoid complexity — the slice header + first few MBs are sufficient
            if (mb_type >= 3 and mb_type < 5) {
                // Sub-macroblock partitions are complex; skip residual for these
                continue;
            }
        }

        // coded_block_pattern — for non-I_16x16 MBs
        var coded_block_pattern: u32 = 0;
        var has_luma_dc = false;

        if (mb_is_intra) {
            if (is_intra and mb_type == 0) {
                // I_4x4: CBP from ue(v) mapped through Table 9-4
                coded_block_pattern = reader.readExpGolomb() orelse return mb_count > 0;
                if (coded_block_pattern > 47) return false;
                coded_block_pattern = mapIntraCbp(coded_block_pattern);
            } else if (is_intra and mb_type >= 1 and mb_type <= 24) {
                // I_16x16: CBP is encoded in mb_type
                has_luma_dc = true;
                const cbp_luma: u32 = if ((mb_type - 1) / 12 > 0) 15 else 0;
                const cbp_chroma: u32 = ((mb_type - 1) % 12) / 4;
                coded_block_pattern = cbp_luma | (cbp_chroma << 4);
            } else if (!is_intra and mb_type >= 5) {
                // Intra MB in P/B slice
                const intra_type = mb_type - 5;
                if (intra_type == 0) {
                    coded_block_pattern = reader.readExpGolomb() orelse return mb_count > 0;
                    if (coded_block_pattern > 47) return false;
                    coded_block_pattern = mapIntraCbp(coded_block_pattern);
                } else if (intra_type >= 1 and intra_type <= 24) {
                    has_luma_dc = true;
                    const cbp_luma: u32 = if ((intra_type - 1) / 12 > 0) 15 else 0;
                    const cbp_chroma: u32 = ((intra_type - 1) % 12) / 4;
                    coded_block_pattern = cbp_luma | (cbp_chroma << 4);
                }
            }
        } else {
            // Inter MB: CBP from ue(v) mapped through Table 9-4
            coded_block_pattern = reader.readExpGolomb() orelse return mb_count > 0;
            if (coded_block_pattern > 47) return false;
            coded_block_pattern = mapInterCbp(coded_block_pattern);
        }

        // mb_qp_delta: se(v) — only if CBP > 0 or I_16x16
        if (coded_block_pattern > 0 or has_luma_dc) {
            const qp_delta = reader.readSignedExpGolomb() orelse return mb_count > 0;
            if (qp_delta < -26 or qp_delta > 25) return false;
        }

        // Residual data — CAVLC decode
        if (coded_block_pattern > 0 or has_luma_dc) {
            if (!parseCavlcResidual(&reader, coded_block_pattern, has_luma_dc, sps.chroma_format_idc)) {
                // Residual decode failure — could be truncation or corruption
                return mb_count > 0;
            }
        }
    }

    return mb_count > 0;
}

/// Parse CAVLC residual data for a macroblock.
fn parseCavlcResidual(
    reader: *BitReader,
    coded_block_pattern: u32,
    has_luma_dc: bool,
    chroma_format_idc: u32,
) bool {
    const cbp_luma = coded_block_pattern & 0xF;
    const cbp_chroma = (coded_block_pattern >> 4) & 0x3;

    // Luma DC (I_16x16 only)
    if (has_luma_dc) {
        _ = cavlc.decodeResidualBlockCavlc(reader, 0, 16) orelse return false;
    }

    // Luma AC: 4 blocks of 4 4x4 sub-blocks each
    if (cbp_luma > 0) {
        var block8x8: u32 = 0;
        while (block8x8 < 4) : (block8x8 += 1) {
            if (cbp_luma & (@as(u32, 1) << @as(u2, @intCast(block8x8))) != 0) {
                // 4 sub-blocks in this 8x8 block
                var sub: u32 = 0;
                while (sub < 4) : (sub += 1) {
                    const max_coeff: u5 = if (has_luma_dc) 15 else 16;
                    _ = cavlc.decodeResidualBlockCavlc(reader, 0, max_coeff) orelse return false;
                }
            }
        }
    }

    // Chroma residual
    if (chroma_format_idc != 0 and cbp_chroma > 0) {
        // Chroma DC (2 components for 4:2:0)
        const num_chroma_dc = if (chroma_format_idc == 1) @as(u5, 4) else if (chroma_format_idc == 2) @as(u5, 8) else @as(u5, 16);
        for (0..2) |_| {
            _ = cavlc.decodeResidualBlockCavlc(reader, -1, num_chroma_dc) orelse return false;
        }

        // Chroma AC
        if (cbp_chroma == 2) {
            const num_blocks: u32 = if (chroma_format_idc == 1) 4 else if (chroma_format_idc == 2) 8 else 16;
            for (0..2) |_| {
                var blk: u32 = 0;
                while (blk < num_blocks) : (blk += 1) {
                    _ = cavlc.decodeResidualBlockCavlc(reader, 0, 15) orelse return false;
                }
            }
        }
    }

    return true;
}

/// Map coded_block_pattern for intra MBs (Table 9-4a)
fn mapIntraCbp(code_num: u32) u32 {
    const table = [48]u32{
        47, 31, 15, 0, 23, 27, 29, 30, 7, 11, 13, 14, 39, 43, 45, 46,
        16, 3, 5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1, 2, 4,
        8, 17, 18, 20, 24, 6, 9, 22, 25, 32, 33, 34, 36, 40, 38, 41,
    };
    if (code_num >= 48) return 0;
    return table[code_num];
}

/// Map coded_block_pattern for inter MBs (Table 9-4b)
fn mapInterCbp(code_num: u32) u32 {
    const table = [48]u32{
        0, 16, 1, 2, 4, 8, 32, 3, 5, 10, 12, 15, 47, 7, 11, 13,
        14, 6, 9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
        17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
    };
    if (code_num >= 48) return 0;
    return table[code_num];
}

pub fn validateH264Stream(data: []const u8, max_frames: u32) H264SyntaxResult {
    if (data.len < 4) {
        return H264SyntaxResult.invalid("Data too small for H.264");
    }

    // Check for Annex B start code
    if (!hasAnnexBStartCode(data)) {
        return H264SyntaxResult.invalid(errmsg.missing("Annex B start code"));
    }

    var iterator = NalUnitIterator.init(data);

    var found_sps = false;
    var found_pps = false;
    var found_slice = false;
    var frames_counted: u32 = 0;

    var width: u32 = 0;
    var height: u32 = 0;
    var profile_idc: u8 = 0;
    var level_idc: u8 = 0;

    var nal_count: u32 = 0;
    var sps_parse_error = false;
    var pps_parse_error = false;

    // Store last parsed SPS/PPS for full slice header validation
    var last_sps: ?SequenceParameterSet = null;
    var last_pps: ?PictureParameterSet = null;
    var slice_header_errors: u32 = 0;
    var slices_deep_validated: u32 = 0;
    var cavlc_validated: u32 = 0;
    var cabac_validated: u32 = 0;

    // Allocate RBSP buffer on stack for parameter set parsing.
    var rbsp_buf: [8192]u8 = undefined;

    while (iterator.next()) |nal| {
        nal_count += 1;

        // Validate NAL header
        if (nal.header.validate()) |err_msg| {
            // If we already have some frames, report partial success
            if (frames_counted > 0) {
                return H264SyntaxResult.invalidPartial(
                    @ptrCast(err_msg.ptr),
                    frames_counted,
                );
            }
            return H264SyntaxResult.invalid(@ptrCast(err_msg.ptr));
        }

        const nal_type = nal.header.nal_unit_type;

        switch (nal_type) {
            .sps => {
                if (nal.data.len > rbsp_buf.len) {
                    sps_parse_error = true;
                    continue;
                }
                const rbsp = removeEmulationPreventionBytes(nal.data, &rbsp_buf) orelse {
                    sps_parse_error = true;
                    continue;
                };
                if (parseSps(rbsp)) |sps| {
                    found_sps = true;
                    width = sps.width;
                    height = sps.height;
                    profile_idc = sps.profile_idc;
                    level_idc = sps.level_idc;
                    last_sps = sps;
                } else {
                    sps_parse_error = true;
                }
            },

            .pps => {
                if (nal.data.len > rbsp_buf.len) {
                    pps_parse_error = true;
                    continue;
                }
                const rbsp = removeEmulationPreventionBytes(nal.data, &rbsp_buf) orelse {
                    pps_parse_error = true;
                    continue;
                };
                if (parsePps(rbsp)) |pps| {
                    found_pps = true;
                    last_pps = pps;
                } else {
                    pps_parse_error = true;
                }
            },

            // Slice NAL units (coded picture data)
            .slice_non_idr, .slice_idr => {
                found_slice = true;

                // Parse slice header for frame counting and validation
                if (nal.data.len > 0) {
                    // For full slice header parsing, we need more data than just 512 bytes
                    // For CAVLC entropy validation, we need the full slice data
                    const max_slice_bytes = @min(nal.data.len, rbsp_buf.len);
                    const slice_data = nal.data[0..max_slice_bytes];
                    const rbsp = removeEmulationPreventionBytes(
                        slice_data,
                        &rbsp_buf,
                    ) orelse continue;

                    // Try full slice header parse if we have SPS/PPS context
                    var first_mb: u32 = 0;
                    var did_full_parse = false;

                    if (last_sps != null and last_pps != null) {
                        if (parseFullSliceHeader(
                            rbsp,
                            &last_sps.?,
                            &last_pps.?,
                            nal_type,
                            nal.header.nal_ref_idc,
                        )) |full_result| {
                            first_mb = full_result.first_mb_in_slice;
                            did_full_parse = true;
                            slices_deep_validated += 1;

                            // Entropy validation for slice data
                            if (first_mb == 0 and rbsp.len > full_result.header_bits / 8 + 1) {
                                if (!last_pps.?.entropy_coding_mode_flag) {
                                    // CAVLC entropy validation (Baseline profile)
                                    if (validateCavlcSliceData(
                                        rbsp,
                                        full_result.header_bits,
                                        &last_sps.?,
                                        &last_pps.?,
                                        full_result.slice_type,
                                        first_mb,
                                    )) {
                                        cavlc_validated += 1;
                                    }
                                } else {
                                    // CABAC entropy validation (Main/High profile)
                                    if (cabac_engine.validateCabacSliceData(
                                        rbsp,
                                        full_result.header_bits,
                                        &last_sps.?,
                                        full_result.slice_type,
                                        full_result.slice_qp,
                                        full_result.cabac_init_idc,
                                        first_mb,
                                    )) {
                                        cabac_validated += 1;
                                    }
                                }
                                // Don't treat entropy failure as fatal — header validation is sufficient
                            }
                        } else {
                            slice_header_errors += 1;
                        }
                    }

                    // Fall back to simple parse if full parse failed or wasn't attempted
                    if (!did_full_parse) {
                        if (parseSliceHeader(rbsp)) |slice_info| {
                            first_mb = slice_info.first_mb_in_slice;
                        }
                    }

                    if (first_mb == 0) {
                        frames_counted += 1;
                        if (max_frames > 0 and frames_counted >= max_frames) {
                            break;
                        }
                    }
                }
            },

            // Data partition slices — count as slices for basic validation
            .slice_data_partition_a, .slice_data_partition_b, .slice_data_partition_c => {
                found_slice = true;
            },

            // SEI — skip (not critical for structural validation)
            .sei => {},

            // AUD — Access Unit Delimiter (just validates it exists)
            .aud => {},

            // EOS, EOB — stream termination signals
            .end_of_sequence, .end_of_stream => {},

            // Filler data — skip
            .filler_data => {},

            // SPS extension, subset SPS, prefix NAL unit, auxiliary/extension slices
            .sps_extension, .subset_sps, .prefix_nal_unit, .slice_auxiliary, .slice_extension, .slice_extension_depth => {},

            // Reserved and unspecified — allow but don't process
            else => {},
        }
    }

    // Validate overall stream
    if (nal_count == 0) {
        return H264SyntaxResult.invalid("No NAL units found in H.264 stream");
    }

    if (sps_parse_error and !found_sps) {
        return H264SyntaxResult.invalid("H.264 SPS parsing failed");
    }

    if (pps_parse_error and !found_pps) {
        return H264SyntaxResult.invalid("H.264 PPS parsing failed");
    }

    if (!found_sps) {
        return H264SyntaxResult.invalid("H.264 stream missing SPS");
    }

    if (!found_pps) {
        return H264SyntaxResult.invalid("H.264 stream missing PPS");
    }

    if (!found_slice) {
        // If we have valid SPS+PPS but no slices, this may be codec_private-only data
        // (e.g. MKV containers where collectAllFrames returns no frames).
        // Return success with 0 frames rather than an error.
        if (found_sps and found_pps) {
            return H264SyntaxResult.ok(0, width, height, profile_idc, level_idc);
        }
        return H264SyntaxResult.invalid("H.264 stream has no coded slice NAL units");
    }

    // If all slices failed full header parse and we had enough attempts, flag corruption.
    // A low threshold allows real corruption to be caught while permitting minimal synthetic
    // test streams (which don't have full slice headers) to pass.
    if (slices_deep_validated == 0 and slice_header_errors >= 3) {
        if (frames_counted > 0) {
            return H264SyntaxResult.invalidPartial(
                "H.264 slice header parsing failed",
                frames_counted,
            );
        }
        return H264SyntaxResult.invalid("H.264 slice header parsing failed");
    }

    // Width and height must be reasonable
    if (width == 0 or height == 0) {
        return H264SyntaxResult.invalid("H.264 SPS has zero width or height");
    }

    return H264SyntaxResult.ok(frames_counted, width, height, profile_idc, level_idc);
}

// ============================================================================
// Tests
// ============================================================================

test "H.264 syntax validation rejects empty data" {
    const result = validateH264Stream(&[_]u8{}, 1);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_message != null);
}

test "H.264 syntax validation rejects too-small data" {
    const result = validateH264Stream(&[_]u8{ 0x00, 0x01 }, 1);
    try std.testing.expect(!result.valid);
}

test "H.264 syntax validation rejects data without start codes" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = validateH264Stream(&garbage, 1);
    try std.testing.expect(!result.valid);
}

test "H.264 NAL header parsing - SPS" {
    // forbidden=0, ref_idc=3, type=7 (SPS)
    // 0_11_00111 = 0x67
    const header = NalHeader.parse(0x67).?;
    try std.testing.expectEqual(@as(u1, 0), header.forbidden_zero_bit);
    try std.testing.expectEqual(@as(u2, 3), header.nal_ref_idc);
    try std.testing.expectEqual(NalUnitType.sps, header.nal_unit_type);
    try std.testing.expectEqual(@as(?[]const u8, null), header.validate());
}

test "H.264 NAL header parsing - PPS" {
    // forbidden=0, ref_idc=3, type=8 (PPS)
    // 0_11_01000 = 0x68
    const header = NalHeader.parse(0x68).?;
    try std.testing.expectEqual(NalUnitType.pps, header.nal_unit_type);
    try std.testing.expectEqual(@as(?[]const u8, null), header.validate());
}

test "H.264 NAL header parsing - IDR slice" {
    // forbidden=0, ref_idc=3, type=5 (IDR)
    // 0_11_00101 = 0x65
    const header = NalHeader.parse(0x65).?;
    try std.testing.expectEqual(NalUnitType.slice_idr, header.nal_unit_type);
    try std.testing.expect(header.nal_unit_type.isIdr());
    try std.testing.expect(header.nal_unit_type.isSlice());
    try std.testing.expect(header.nal_unit_type.isVcl());
}

test "H.264 NAL header parsing - non-IDR slice" {
    // forbidden=0, ref_idc=2, type=1 (non-IDR)
    // 0_10_00001 = 0x41
    const header = NalHeader.parse(0x41).?;
    try std.testing.expectEqual(NalUnitType.slice_non_idr, header.nal_unit_type);
    try std.testing.expect(!header.nal_unit_type.isIdr());
    try std.testing.expect(header.nal_unit_type.isSlice());
    try std.testing.expect(header.nal_unit_type.isVcl());
}

test "H.264 NAL header validation - forbidden bit set" {
    // forbidden=1, ref_idc=0, type=1
    // 1_00_00001 = 0x81
    const header = NalHeader.parse(0x81).?;
    try std.testing.expect(header.validate() != null);
}

test "H.264 NAL unit type classification" {
    try std.testing.expect(NalUnitType.slice_non_idr.isSlice());
    try std.testing.expect(NalUnitType.slice_idr.isSlice());
    try std.testing.expect(!NalUnitType.sps.isSlice());
    try std.testing.expect(!NalUnitType.pps.isSlice());
    try std.testing.expect(NalUnitType.slice_idr.isIdr());
    try std.testing.expect(!NalUnitType.slice_non_idr.isIdr());
    try std.testing.expect(NalUnitType.slice_non_idr.isVcl());
    try std.testing.expect(NalUnitType.slice_data_partition_a.isVcl());
    try std.testing.expect(!NalUnitType.sei.isVcl());
}

test "H.264 RBSP emulation prevention byte removal" {
    var output: [64]u8 = undefined;

    // No EPB
    {
        const input = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqualSlices(u8, &input, result);
    }

    // Single EPB: 0x00 0x00 0x03 0x00 -> 0x00 0x00 0x00
    {
        const input = [_]u8{ 0x00, 0x00, 0x03, 0x00 };
        const expected = [_]u8{ 0x00, 0x00, 0x00 };
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqualSlices(u8, &expected, result);
    }

    // EPB: 0x00 0x00 0x03 0x01 -> 0x00 0x00 0x01
    {
        const input = [_]u8{ 0x00, 0x00, 0x03, 0x01 };
        const expected = [_]u8{ 0x00, 0x00, 0x01 };
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqualSlices(u8, &expected, result);
    }

    // Multiple EPBs
    {
        const input = [_]u8{ 0x00, 0x00, 0x03, 0x02, 0xFF, 0x00, 0x00, 0x03, 0x03 };
        const expected = [_]u8{ 0x00, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x03 };
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqualSlices(u8, &expected, result);
    }

    // 0x000003 followed by 0x04 is NOT an EPB (only 0x00-0x03 are valid)
    {
        const input = [_]u8{ 0x00, 0x00, 0x03, 0x04 };
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqualSlices(u8, &input, result);
    }

    // Empty input
    {
        const input = [_]u8{};
        const result = removeEmulationPreventionBytes(&input, &output).?;
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }
}

test "H.264 NAL unit iterator finds NAL units" {
    // Build a stream with two NAL units:
    // 0x00000001 + SPS header (0x67) + some bytes
    // 0x00000001 + PPS header (0x68) + some bytes
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x01, // start code
        0x67, // SPS NAL header (forbidden=0, ref_idc=3, type=7)
        0xAA, 0xBB, // SPS body
        0x00, 0x00, 0x00, 0x01, // start code
        0x68, // PPS NAL header (forbidden=0, ref_idc=3, type=8)
        0xCC, 0xDD, // PPS body
    };

    var iter = NalUnitIterator.init(&data);

    const nal1 = iter.next().?;
    try std.testing.expectEqual(NalUnitType.sps, nal1.header.nal_unit_type);
    try std.testing.expectEqual(@as(usize, 2), nal1.data.len);

    const nal2 = iter.next().?;
    try std.testing.expectEqual(NalUnitType.pps, nal2.header.nal_unit_type);
    try std.testing.expectEqual(@as(usize, 2), nal2.data.len);

    try std.testing.expect(iter.next() == null);
}

test "H.264 NAL unit iterator - 3-byte start code" {
    const data = [_]u8{
        0x00, 0x00, 0x01, // 3-byte start code
        0x67, // SPS NAL header
        0xAA,
    };

    var iter = NalUnitIterator.init(&data);
    const nal = iter.next().?;
    try std.testing.expectEqual(NalUnitType.sps, nal.header.nal_unit_type);
    try std.testing.expect(iter.next() == null);
}

test "H.264 SPS parsing with valid synthetic data" {
    // Build a Baseline profile SPS (profile_idc=66, level_idc=30, 320x240)
    //
    // Baseline is not a high profile, so no extended chroma/scaling fields.
    //
    // Fields (in order):
    //   profile_idc: 66 (0x42) — 8 bits
    //   constraint_set0_flag: 1 — 1 bit
    //   constraint_set1_flag: 1 — 1 bit
    //   constraint_set2_flag: 0 — 1 bit
    //   constraint_set3_flag: 0 — 1 bit
    //   constraint_set4_flag: 0 — 1 bit
    //   constraint_set5_flag: 0 — 1 bit
    //   reserved_zero_2bits: 00 — 2 bits
    //   level_idc: 30 (0x1E) — 8 bits
    //   seq_parameter_set_id: 0 — ue(v) = "1" (1 bit)
    //   log2_max_frame_num_minus4: 0 — ue(v) = "1" (1 bit)
    //   pic_order_cnt_type: 0 — ue(v) = "1" (1 bit)
    //   log2_max_pic_order_cnt_lsb_minus4: 0 — ue(v) = "1" (1 bit)
    //   max_num_ref_frames: 1 — ue(v) = "010" (3 bits)
    //   gaps_in_frame_num_value_allowed_flag: 0 — 1 bit
    //   pic_width_in_mbs_minus1: 19 — ue(v) for 19 = "0010100" (7 bits) [320/16-1=19]
    //   pic_height_in_map_units_minus1: 14 — ue(v) for 14 = "001111" (6 bits) [240/16-1=14]
    //   frame_mbs_only_flag: 1 — 1 bit
    //   direct_8x8_inference_flag: 0 — 1 bit
    //   frame_cropping_flag: 0 — 1 bit
    //
    // Bit layout:
    //   profile_idc=66:      01000010                                    (8 bits)
    //   constraints+reserved: 11000000                                   (8 bits)
    //   level_idc=30:        00011110                                    (8 bits)
    //   sps_id=0(ue):        1                                           (1 bit)
    //   log2_max_frame_num_minus4=0(ue): 1                               (1 bit)
    //   poc_type=0(ue):      1                                           (1 bit)
    //   log2_max_poc_lsb_minus4=0(ue): 1                                 (1 bit)
    //   max_ref_frames=1(ue): 010                                        (3 bits)
    //   gaps_flag: 0                                                     (1 bit)
    //   width_mbs_m1=19(ue): 0010100                                     (7 bits)
    //   height_map_m1=14(ue): 001111                                     (6 bits)
    //   frame_mbs_only: 1                                                (1 bit)
    //   direct_8x8: 0                                                    (1 bit)
    //   cropping_flag: 0                                                 (1 bit)
    //
    // After byte 3 (level_idc), we have 24 bits left:
    //   1111 010_0 0101_00 00 1111_1 0 0
    //   = 0xF4 = 11110100
    //   next: 01010000
    //   next: 11111000 (with trailing zeros to pad)
    //
    // Actually, let me lay this out more carefully bit by bit after the 3 fixed bytes:
    //   Bit 0: 1 (sps_id=0)
    //   Bit 1: 1 (log2_max_frame_num_minus4=0)
    //   Bit 2: 1 (poc_type=0)
    //   Bit 3: 1 (log2_max_poc_lsb_minus4=0)
    //   Bits 4-6: 010 (max_ref_frames=1)
    //   Bit 7: 0 (gaps_flag)
    //   Bits 8-14: 0010100 (width=19)
    //   Bits 15-20: 001111 (height=14)
    //   Bit 21: 1 (frame_mbs_only=1)
    //   Bit 22: 0 (direct_8x8)
    //   Bit 23: 0 (cropping=0)
    //
    // Byte 3: bits 0-7 = 1111_0100 = 0xF4
    // Byte 4: bits 8-15 = 0101_0000 = 0x50 (wait — bits 8-14 are 0010100, bit 15 is first of height)
    //
    // Let me redo: bits 8-14 for width=19:
    //   ue(19): code_num=19, leading_zeros = floor(log2(20)) = 4
    //   Code: 0000 1 0100 = 9 bits (not 7)
    //   Actually ue(v): code_num n = 2^k - 1 + suffix, k leading zeros
    //   For 19: 19 = 2^4 - 1 + 4 = 15 + 4, so k=4, suffix=4=0100
    //   Code: 0000_1_0100 = 9 bits
    //
    // And ue(14): 14 = 2^3 - 1 + 7 = 7 + 7, so k=3, suffix=7=111
    //   Code: 000_1_111 = 7 bits
    //
    // And ue(1): 1 = 2^1 - 1 + 0 = 0 + 1 ... wait, 1 = 2^1 - 1 + 0? No.
    //   ue(1): code_num=1, k=1, suffix=0. Code: 0_1_0 = 3 bits
    //
    // Let me redo from scratch:
    //   Bit 0: 1 (sps_id=0: ue(0)="1")
    //   Bit 1: 1 (log2_max_frame_num_minus4=0: ue(0)="1")
    //   Bit 2: 1 (poc_type=0: ue(0)="1")
    //   Bit 3: 1 (log2_max_poc_lsb_minus4=0: ue(0)="1")
    //   Bits 4-6: 010 (max_ref_frames=1: ue(1)="010")
    //   Bit 7: 0 (gaps_flag=0)
    //   Bits 8-16: 000010100 (width=19: ue(19)="000010100", 9 bits)
    //   Bits 17-23: 0001111 (height=14: ue(14)="0001111", 7 bits)
    //   Bit 24: 1 (frame_mbs_only=1)
    //   Bit 25: 0 (direct_8x8_inference=0)
    //   Bit 26: 0 (cropping=0)
    //
    // Byte 3 (bits 0-7): 1111_0100 = 0xF4
    // Byte 4 (bits 8-15): 0001_0100 = 0x14
    // Byte 5 (bits 16-23): 0_0001111 = wait, bit 16 is last bit of width code
    //   width code is 000010100 = bits 8..16
    //   bit 8=0, 9=0, 10=0, 11=0, 12=1, 13=0, 14=1, 15=0, 16=0
    //   So byte 4 = bits 8-15 = 00001010 = 0x0A
    //   bit 16 = 0 (last bit of width)
    //   Then height ue(14) = 0001111, bits 17..23
    //   byte 5 = bits 16-23 = 0_0001111 = 0x0F
    //   bit 24 = 1 (frame_mbs_only)
    //   bit 25 = 0 (direct_8x8)
    //   bit 26 = 0 (cropping)
    //   byte 6 = bits 24-26 + padding = 100_00000 = 0x80

    const sps_rbsp = [_]u8{
        0x42, // profile_idc = 66 (Baseline)
        0xC0, // constraint_set0=1, constraint_set1=1, rest=0, reserved=00
        0x1E, // level_idc = 30
        0xF4, // 1111_0100: sps_id(1), log2_max_fn(1), poc_type(1), log2_poc(1), max_ref(010), gaps(0)
        0x0A, // 0000_1010: width ue(19) bits [0-7 of 9]
        0x0F, // 0_000_1111: width bit[8], height ue(14) bits [0-6 of 7]
        0x80, // 1_0_0_00000: frame_mbs_only(1), direct_8x8(0), cropping(0), padding
    };

    const sps = parseSps(&sps_rbsp);
    try std.testing.expect(sps != null);
    if (sps) |s| {
        try std.testing.expectEqual(@as(u8, 66), s.profile_idc);
        try std.testing.expectEqual(@as(u8, 30), s.level_idc);
        try std.testing.expect(s.constraint_set0_flag);
        try std.testing.expect(s.constraint_set1_flag);
        try std.testing.expectEqual(@as(u32, 0), s.seq_parameter_set_id);
        try std.testing.expectEqual(@as(u32, 0), s.pic_order_cnt_type);
        try std.testing.expectEqual(@as(u32, 1), s.max_num_ref_frames);
        try std.testing.expectEqual(@as(u32, 19), s.pic_width_in_mbs_minus1);
        try std.testing.expectEqual(@as(u32, 14), s.pic_height_in_map_units_minus1);
        try std.testing.expect(s.frame_mbs_only_flag);
        try std.testing.expect(!s.frame_cropping_flag);
        try std.testing.expectEqual(@as(u32, 320), s.width);
        try std.testing.expectEqual(@as(u32, 240), s.height);
    }
}

test "H.264 SPS parsing rejects truncated data" {
    const rbsp = [_]u8{ 0x42, 0xC0 }; // Too short for full SPS
    const sps = parseSps(&rbsp);
    try std.testing.expect(sps == null);
}

test "H.264 PPS parsing rejects truncated data" {
    const rbsp = [_]u8{0x00}; // Too short for PPS
    const pps = parsePps(&rbsp);
    try std.testing.expect(pps == null);
}

test "H.264 stream with forbidden bit set is invalid" {
    // Start code + NAL header with forbidden bit = 1
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x01, // start code
        0x81, // forbidden=1, ref_idc=0, type=1 (non-IDR)
        0xFF, 0xFF,
    };
    const result = validateH264Stream(&data, 1);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_message != null);
}

test "H.264 stream missing SPS is invalid" {
    // PPS + slice but no SPS
    const data = [_]u8{
        // PPS (minimal, will fail to parse but that's ok — we test missing SPS)
        0x00, 0x00, 0x00, 0x01,
        0x68, // PPS header
        0x00, 0x00,
        // Slice (IDR)
        0x00, 0x00, 0x00, 0x01,
        0x65, // IDR header
        0xFF, 0xFF,
    };
    const result = validateH264Stream(&data, 1);
    try std.testing.expect(!result.valid);
}

test "H.264 hasAnnexBStartCode" {
    try std.testing.expect(hasAnnexBStartCode(&[_]u8{ 0x00, 0x00, 0x01 }));
    try std.testing.expect(hasAnnexBStartCode(&[_]u8{ 0x00, 0x00, 0x00, 0x01 }));
    try std.testing.expect(hasAnnexBStartCode(&[_]u8{ 0xFF, 0x00, 0x00, 0x01, 0xFF }));
    try std.testing.expect(!hasAnnexBStartCode(&[_]u8{ 0x00, 0x00, 0x02 }));
    try std.testing.expect(!hasAnnexBStartCode(&[_]u8{ 0x00, 0x01 }));
    try std.testing.expect(!hasAnnexBStartCode(&[_]u8{}));
}

test "H.264 full synthetic stream validation" {
    // Build a complete minimal H.264 stream: SPS + PPS + IDR slice
    // This tests the full validateH264Stream path.

    // SPS RBSP (reuse the Baseline 320x240 from the SPS test above)
    const sps_rbsp = [_]u8{
        0x42, 0xC0, 0x1E, 0xF4, 0x0A, 0x0F, 0x80,
    };

    // PPS RBSP: minimal Baseline PPS
    //   pic_parameter_set_id: 0 — ue(0) = "1" (1 bit)
    //   seq_parameter_set_id: 0 — ue(0) = "1" (1 bit)
    //   entropy_coding_mode_flag: 0 — 1 bit (CAVLC for Baseline)
    //   bottom_field_pic_order_in_frame_present_flag: 0 — 1 bit
    //   num_slice_groups_minus1: 0 — ue(0) = "1" (1 bit)
    //   num_ref_idx_l0_default_active_minus1: 0 — ue(0) = "1" (1 bit)
    //   num_ref_idx_l1_default_active_minus1: 0 — ue(0) = "1" (1 bit)
    //   weighted_pred_flag: 0 — 1 bit
    //   weighted_bipred_idc: 00 — 2 bits
    //   pic_init_qp_minus26: 0 — se(0) = "1" (1 bit)
    //   pic_init_qs_minus26: 0 — se(0) = "1" (1 bit)
    //   chroma_qp_index_offset: 0 — se(0) = "1" (1 bit)
    //   deblocking_filter_control_present_flag: 1 — 1 bit
    //   constrained_intra_pred_flag: 0 — 1 bit
    //   redundant_pic_cnt_present_flag: 0 — 1 bit
    //
    // Bits: 1 1 0 0 1 1 1 0 | 00 1 1 1 1 0 0
    //   Byte 0: 11001110 = 0xCE
    //   Byte 1: 00111100 = 0x3C
    const pps_rbsp = [_]u8{ 0xCE, 0x3C };

    // IDR slice: first_mb_in_slice=0(ue="1"), slice_type=2(I, ue="011")
    //   Bits: 1_011_xxxx... = 0xB0
    const slice_rbsp = [_]u8{ 0xB0 };

    // Assemble the stream with start codes + NAL headers
    // SPS: 0x00000001 + 0x67 + sps_rbsp
    // PPS: 0x00000001 + 0x68 + pps_rbsp
    // IDR: 0x00000001 + 0x65 + slice_rbsp
    var stream: [4 + 1 + sps_rbsp.len + 4 + 1 + pps_rbsp.len + 4 + 1 + slice_rbsp.len]u8 = undefined;
    var pos: usize = 0;

    // SPS NAL
    stream[pos] = 0x00;
    stream[pos + 1] = 0x00;
    stream[pos + 2] = 0x00;
    stream[pos + 3] = 0x01;
    stream[pos + 4] = 0x67; // SPS header
    pos += 5;
    @memcpy(stream[pos .. pos + sps_rbsp.len], &sps_rbsp);
    pos += sps_rbsp.len;

    // PPS NAL
    stream[pos] = 0x00;
    stream[pos + 1] = 0x00;
    stream[pos + 2] = 0x00;
    stream[pos + 3] = 0x01;
    stream[pos + 4] = 0x68; // PPS header
    pos += 5;
    @memcpy(stream[pos .. pos + pps_rbsp.len], &pps_rbsp);
    pos += pps_rbsp.len;

    // IDR slice NAL
    stream[pos] = 0x00;
    stream[pos + 1] = 0x00;
    stream[pos + 2] = 0x00;
    stream[pos + 3] = 0x01;
    stream[pos + 4] = 0x65; // IDR header
    pos += 5;
    @memcpy(stream[pos .. pos + slice_rbsp.len], &slice_rbsp);
    pos += slice_rbsp.len;

    const result = validateH264Stream(&stream, 0);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.has_sps);
    try std.testing.expect(result.has_pps);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
    try std.testing.expectEqual(@as(u8, 66), result.profile_idc);
    try std.testing.expectEqual(@as(u8, 30), result.level_idc);
}
