//! AV1 Open Bitstream Unit (OBU) Validator (Pure Zig)
//!
//! Structural validation for AV1 (AOMedia Video 1) bitstreams. Parses OBU
//! headers, sequence headers, and frame headers to detect corruption without
//! full pixel decoding. Implements relevant portions of the AV1 specification
//! (AOMedia Video Codec 1.0).
//!
//! Supported inputs:
//! - Raw AV1 OBU streams (e.g., from .obu files or Annex B)
//! - Individual AV1 samples extracted from MP4/MKV containers
//!
//! This is a pure-Zig implementation with no external C dependencies.

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const codec_utils = @import("codec_utils.zig");

// ============================================================================
// OBU Types (AV1 spec section 6.2.2)
// ============================================================================

pub const ObuType = enum(u4) {
    reserved_0 = 0,
    sequence_header = 1,
    temporal_delimiter = 2,
    frame_header = 3,
    tile_group = 4,
    metadata = 5,
    frame = 6, // frame_header + tile_group combined
    redundant_frame_header = 7,
    tile_list = 8,
    padding = 15,
    _, // unknown/reserved
};

// ============================================================================
// Frame Types (AV1 spec section 6.8.2)
// ============================================================================

pub const FrameType = enum(u2) {
    key_frame = 0,
    inter_frame = 1,
    intra_only_frame = 2,
    s_frame = 3,
};

// ============================================================================
// Validation Result Types
// ============================================================================

pub const Av1ValidationResult = struct {
    valid: bool,
    error_message: ?[*:0]const u8,
    frames_decoded: u32,
    has_sequence_header: bool,
    width: u32,
    height: u32,
    profile: u8,
    level: u8,

    pub fn ok(frames: u32, w: u32, h: u32, prof: u8, lvl: u8) Av1ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .has_sequence_header = true,
            .width = w,
            .height = h,
            .profile = prof,
            .level = lvl,
        };
    }

    pub fn invalid(msg: [*:0]const u8) Av1ValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_decoded = 0,
            .has_sequence_header = false,
            .width = 0,
            .height = 0,
            .profile = 0,
            .level = 0,
        };
    }
};

pub const Av1SampleResult = struct {
    valid: bool,
    error_message: ?[*:0]const u8,
    has_frame: bool,
    frame_type: ?FrameType,

    pub fn ok_frame(ft: FrameType) Av1SampleResult {
        return .{
            .valid = true,
            .error_message = null,
            .has_frame = true,
            .frame_type = ft,
        };
    }

    pub fn ok_no_frame() Av1SampleResult {
        return .{
            .valid = true,
            .error_message = null,
            .has_frame = false,
            .frame_type = null,
        };
    }

    pub fn invalid(msg: [*:0]const u8) Av1SampleResult {
        return .{
            .valid = false,
            .error_message = msg,
            .has_frame = false,
            .frame_type = null,
        };
    }
};

// ============================================================================
// Parsed Sequence Header
// ============================================================================

const SequenceHeader = struct {
    profile: u8,
    level: u8,
    tier: u8,
    still_picture: bool,
    reduced_still_picture_header: bool,
    width: u32,
    height: u32,
    enable_order_hint: bool,
    order_hint_bits: u8,
    frame_id_numbers_present: bool,
    delta_frame_id_length: u8,
    additional_frame_id_length: u8,
    enable_superres: bool,
    enable_cdef: bool,
    enable_restoration: bool,
    film_grain_params_present: bool,
    seq_force_screen_content_tools: u8,
    seq_force_integer_mv: u8,
};

// ============================================================================
// OBU Header
// ============================================================================

const ObuHeader = struct {
    obu_type: ObuType,
    has_extension: bool,
    has_size_field: bool,
    temporal_id: u3,
    spatial_id: u2,
};

// ============================================================================
// LEB128 Decoder (AV1 spec section 4.10.5)
// ============================================================================

const readLeb128 = codec_utils.readLeb128;

// ============================================================================
// OBU Header Parser
// ============================================================================

/// Parse an OBU header from the data at the given position.
/// Advances pos past the header bytes (1 or 2 bytes).
fn parseObuHeader(data: []const u8, pos: *usize) ?ObuHeader {
    if (pos.* >= data.len) return null;

    const header_byte = data[pos.*];
    pos.* += 1;

    // obu_forbidden_bit (1 bit) - must be 0
    const forbidden_bit = (header_byte >> 7) & 1;
    if (forbidden_bit != 0) return null;

    // obu_type (4 bits)
    const obu_type_raw: u4 = @intCast((header_byte >> 3) & 0x0F);
    const obu_type: ObuType = @enumFromInt(obu_type_raw);

    // obu_extension_flag (1 bit)
    const has_extension = ((header_byte >> 2) & 1) != 0;

    // obu_has_size_field (1 bit)
    const has_size_field = ((header_byte >> 1) & 1) != 0;

    // obu_reserved_1bit (1 bit) - must be 0
    const reserved = header_byte & 1;
    if (reserved != 0) return null;

    var temporal_id: u3 = 0;
    var spatial_id: u2 = 0;

    if (has_extension) {
        if (pos.* >= data.len) return null;
        const ext_byte = data[pos.*];
        pos.* += 1;

        temporal_id = @intCast((ext_byte >> 5) & 0x07);
        spatial_id = @intCast((ext_byte >> 3) & 0x03);
        // extension_reserved_3bits (3 bits) - should be 0 but we don't reject
    }

    return .{
        .obu_type = obu_type,
        .has_extension = has_extension,
        .has_size_field = has_size_field,
        .temporal_id = temporal_id,
        .spatial_id = spatial_id,
    };
}

// ============================================================================
// Sequence Header Parser (AV1 spec section 5.5.1)
// ============================================================================

/// Parse a sequence header OBU payload.
fn parseSequenceHeader(payload: []const u8) ?SequenceHeader {
    var reader = BitReader.init(payload);

    // seq_profile (3 bits)
    const profile_raw = reader.readBits(3) orelse return null;
    const profile: u8 = @intCast(profile_raw);
    if (profile > 2) return null; // Only profiles 0, 1, 2 are defined

    // still_picture (1 bit)
    const still_picture = (reader.readBit() orelse return null) != 0;

    // reduced_still_picture_header (1 bit)
    const reduced_still_picture_header = (reader.readBit() orelse return null) != 0;

    // reduced_still_picture_header requires still_picture
    if (reduced_still_picture_header and !still_picture) return null;

    var level: u8 = 0;
    var tier: u8 = 0;

    if (reduced_still_picture_header) {
        // seq_level_idx[0] (5 bits)
        level = @intCast(reader.readBits(5) orelse return null);
        // seq_tier[0] is implicitly 0
        tier = 0;
    } else {
        // timing_info_present_flag
        const timing_info_present = (reader.readBit() orelse return null) != 0;
        if (timing_info_present) {
            // timing_info()
            // num_units_in_display_tick (32 bits)
            _ = reader.readBits(32) orelse return null;
            // time_scale (32 bits)
            _ = reader.readBits(32) orelse return null;
            // equal_picture_interval (1 bit)
            const equal_picture_interval = (reader.readBit() orelse return null) != 0;
            if (equal_picture_interval) {
                // num_ticks_per_picture_minus_1 (uvlc)
                _ = readUvlc(&reader) orelse return null;
            }

            // decoder_model_info_present_flag (1 bit)
            const decoder_model_info_present = (reader.readBit() orelse return null) != 0;
            if (decoder_model_info_present) {
                // decoder_model_info()
                // buffer_delay_length_minus_1 (5 bits)
                _ = reader.readBits(5) orelse return null;
                // num_units_in_decoding_tick (32 bits)
                _ = reader.readBits(32) orelse return null;
                // buffer_removal_time_length_minus_1 (5 bits)
                _ = reader.readBits(5) orelse return null;
                // frame_presentation_time_length_minus_1 (5 bits)
                _ = reader.readBits(5) orelse return null;
            }
        }

        // initial_display_delay_present_flag (1 bit)
        const initial_display_delay_present = (reader.readBit() orelse return null) != 0;

        // operating_points_cnt_minus_1 (5 bits)
        const op_count_m1 = reader.readBits(5) orelse return null;
        const op_count = op_count_m1 + 1;

        for (0..op_count) |i| {
            // operating_point_idc (12 bits)
            _ = reader.readBits(12) orelse return null;

            // seq_level_idx (5 bits)
            const op_level = reader.readBits(5) orelse return null;
            if (i == 0) {
                level = @intCast(op_level);
            }

            // seq_tier (1 bit) if level > 7
            if (op_level > 7) {
                const op_tier = reader.readBit() orelse return null;
                if (i == 0) {
                    tier = op_tier;
                }
            }

            // If decoder_model_info_present (we skip this complexity for structural validation)
            // We already consumed timing_info and decoder_model_info above; AV1 spec says
            // decoder_model_present_for_this_op is only present if decoder_model_info was present.
            // For structural validation we parse the operating points but skip decoder model params.

            if (initial_display_delay_present) {
                // initial_display_delay_present_for_this_op (1 bit)
                const has_delay = (reader.readBit() orelse return null) != 0;
                if (has_delay) {
                    // initial_display_delay_minus_1 (4 bits)
                    _ = reader.readBits(4) orelse return null;
                }
            }
        }
    }

    // frame_width_bits_minus_1 (4 bits)
    const frame_width_bits_m1 = reader.readBits(4) orelse return null;
    const frame_width_bits: u6 = @intCast(frame_width_bits_m1 + 1);

    // frame_height_bits_minus_1 (4 bits)
    const frame_height_bits_m1 = reader.readBits(4) orelse return null;
    const frame_height_bits: u6 = @intCast(frame_height_bits_m1 + 1);

    // max_frame_width_minus_1
    const max_frame_width_m1 = reader.readBits(frame_width_bits) orelse return null;
    const width = max_frame_width_m1 + 1;

    // max_frame_height_minus_1
    const max_frame_height_m1 = reader.readBits(frame_height_bits) orelse return null;
    const height = max_frame_height_m1 + 1;

    // Sanity checks on dimensions
    if (width == 0 or height == 0) return null;
    if (width > 65536 or height > 65536) return null;

    var frame_id_numbers_present: bool = false;
    var delta_frame_id_length: u8 = 0;
    var additional_frame_id_length: u8 = 0;

    if (!reduced_still_picture_header) {
        // frame_id_numbers_present_flag (1 bit)
        frame_id_numbers_present = (reader.readBit() orelse return null) != 0;
        if (frame_id_numbers_present) {
            // delta_frame_id_length_minus_2 (4 bits)
            delta_frame_id_length = @intCast((reader.readBits(4) orelse return null) + 2);
            // additional_frame_id_length_minus_1 (3 bits)
            additional_frame_id_length = @intCast((reader.readBits(3) orelse return null) + 1);
        }
    }

    // use_128x128_superblock (1 bit)
    _ = reader.readBit() orelse return null;
    // enable_filter_intra (1 bit)
    _ = reader.readBit() orelse return null;
    // enable_intra_edge_filter (1 bit)
    _ = reader.readBit() orelse return null;

    var enable_order_hint: bool = false;
    var order_hint_bits: u8 = 0;
    var seq_force_screen_content_tools: u8 = 2; // SELECT_SCREEN_CONTENT_TOOLS
    var seq_force_integer_mv: u8 = 2; // SELECT_INTEGER_MV

    if (!reduced_still_picture_header) {
        // enable_interintra_compound (1 bit)
        _ = reader.readBit() orelse return null;
        // enable_masked_compound (1 bit)
        _ = reader.readBit() orelse return null;
        // enable_warped_motion (1 bit)
        _ = reader.readBit() orelse return null;
        // enable_dual_filter (1 bit)
        _ = reader.readBit() orelse return null;

        // enable_order_hint (1 bit)
        enable_order_hint = (reader.readBit() orelse return null) != 0;

        if (enable_order_hint) {
            // enable_jnt_comp (1 bit)
            _ = reader.readBit() orelse return null;
            // enable_ref_frame_mvs (1 bit)
            _ = reader.readBit() orelse return null;
        }

        // seq_choose_screen_content_tools (1 bit)
        const seq_choose_screen_content_tools = (reader.readBit() orelse return null) != 0;
        if (seq_choose_screen_content_tools) {
            seq_force_screen_content_tools = 2; // SELECT_SCREEN_CONTENT_TOOLS
        } else {
            seq_force_screen_content_tools = @intCast(reader.readBit() orelse return null);
        }

        if (seq_force_screen_content_tools > 0) {
            // seq_choose_integer_mv (1 bit)
            const seq_choose_integer_mv = (reader.readBit() orelse return null) != 0;
            if (seq_choose_integer_mv) {
                seq_force_integer_mv = 2; // SELECT_INTEGER_MV
            } else {
                seq_force_integer_mv = @intCast(reader.readBit() orelse return null);
            }
        } else {
            seq_force_integer_mv = 2; // SELECT_INTEGER_MV
        }

        if (enable_order_hint) {
            // order_hint_bits_minus_1 (3 bits)
            order_hint_bits = @intCast((reader.readBits(3) orelse return null) + 1);
        }
    }

    // enable_superres (1 bit)
    const enable_superres = (reader.readBit() orelse return null) != 0;
    // enable_cdef (1 bit)
    const enable_cdef = (reader.readBit() orelse return null) != 0;
    // enable_restoration (1 bit)
    const enable_restoration = (reader.readBit() orelse return null) != 0;

    // color_config
    if (!parseColorConfig(&reader, profile)) return null;

    // film_grain_params_present (1 bit)
    const film_grain_params_present = (reader.readBit() orelse return null) != 0;

    return .{
        .profile = profile,
        .level = level,
        .tier = tier,
        .still_picture = still_picture,
        .reduced_still_picture_header = reduced_still_picture_header,
        .width = width,
        .height = height,
        .enable_order_hint = enable_order_hint,
        .order_hint_bits = order_hint_bits,
        .frame_id_numbers_present = frame_id_numbers_present,
        .delta_frame_id_length = delta_frame_id_length,
        .additional_frame_id_length = additional_frame_id_length,
        .enable_superres = enable_superres,
        .enable_cdef = enable_cdef,
        .enable_restoration = enable_restoration,
        .film_grain_params_present = film_grain_params_present,
        .seq_force_screen_content_tools = seq_force_screen_content_tools,
        .seq_force_integer_mv = seq_force_integer_mv,
    };
}

// ============================================================================
// Color Config Parser (AV1 spec section 5.5.2)
// ============================================================================

fn parseColorConfig(reader: *BitReader, profile: u8) bool {
    // high_bitdepth (1 bit)
    const high_bitdepth = (reader.readBit() orelse return false) != 0;

    if (profile == 2 and high_bitdepth) {
        // twelve_bit (1 bit)
        _ = reader.readBit() orelse return false;
    }

    var mono_chrome: bool = false;
    if (profile != 1) {
        // mono_chrome (1 bit)
        mono_chrome = (reader.readBit() orelse return false) != 0;
    }

    // color_description_present_flag (1 bit)
    const color_description_present = (reader.readBit() orelse return false) != 0;

    var color_primaries: u8 = 2; // CP_UNSPECIFIED
    var transfer_characteristics: u8 = 2; // TC_UNSPECIFIED
    var matrix_coefficients: u8 = 2; // MC_UNSPECIFIED

    if (color_description_present) {
        color_primaries = @intCast(reader.readBits(8) orelse return false);
        transfer_characteristics = @intCast(reader.readBits(8) orelse return false);
        matrix_coefficients = @intCast(reader.readBits(8) orelse return false);
    }

    if (mono_chrome) {
        // color_range (1 bit)
        _ = reader.readBit() orelse return false;
        // subsampling_x = 1, subsampling_y = 1 (implicit for mono)
        // No chroma_sample_position, no separate_uv_delta_q
        return true;
    }

    if (color_primaries == 1 and transfer_characteristics == 13 and matrix_coefficients == 0) {
        // sRGB/BT.709: color_range=1, subsampling=0,0
        // color_range is implicit 1 for this case
    } else {
        // color_range (1 bit)
        _ = reader.readBit() orelse return false;

        if (profile == 0) {
            // subsampling_x = 1, subsampling_y = 1 (implicit for profile 0)
        } else if (profile == 1) {
            // subsampling_x = 0, subsampling_y = 0 (implicit for profile 1)
        } else {
            // profile 2
            if (high_bitdepth) {
                // subsampling_x (1 bit)
                const subsampling_x = (reader.readBit() orelse return false) != 0;
                if (subsampling_x) {
                    // subsampling_y (1 bit)
                    _ = reader.readBit() orelse return false;
                }
            }
            // else subsampling_x = 1, subsampling_y = 0 (implicit)
        }

        // For 4:2:0 (subsampling_x=1, subsampling_y=1): chroma_sample_position (2 bits)
        // We need to determine effective subsampling to know if we read this field.
        // For profile 0: always 4:2:0, so read it.
        // For profile 2 with certain conditions: may be 4:2:0.
        // For simplicity, read chroma_sample_position for profile 0 always.
        if (profile == 0) {
            _ = reader.readBits(2) orelse return false;
        }
    }

    // separate_uv_delta_q (1 bit)
    _ = reader.readBit() orelse return false;

    return true;
}

// ============================================================================
// UVLC Decoder (AV1 spec section 4.10.3)
// ============================================================================

/// Read an unsigned variable-length coded integer (used for some timing fields).
fn readUvlc(reader: *BitReader) ?u32 {
    // Count leading zeros
    var leading_zeros: u32 = 0;
    while (true) {
        const bit = reader.readBit() orelse return null;
        if (bit != 0) break;
        leading_zeros += 1;
        if (leading_zeros > 32) return null;
    }
    if (leading_zeros >= 32) return null;
    if (leading_zeros == 0) return 0;
    // Read the value bits
    const value = reader.readBits(@intCast(leading_zeros)) orelse return null;
    return value + (@as(u32, 1) << @intCast(leading_zeros)) - 1;
}

// ============================================================================
// Simplified Frame Header Parser (AV1 spec section 5.9)
// ============================================================================

const FrameHeaderInfo = struct {
    frame_type: FrameType,
    show_frame: bool,
    show_existing_frame: bool,
};

/// Parse just enough of the frame header to determine frame type and visibility.
fn parseFrameHeaderSimplified(payload: []const u8, seq: *const SequenceHeader) ?FrameHeaderInfo {
    var reader = BitReader.init(payload);

    if (seq.reduced_still_picture_header) {
        // Implicit: show_existing_frame = false, frame_type = KEY_FRAME, show_frame = true
        return .{
            .frame_type = .key_frame,
            .show_frame = true,
            .show_existing_frame = false,
        };
    }

    // show_existing_frame (1 bit)
    const show_existing_frame = (reader.readBit() orelse return null) != 0;

    if (show_existing_frame) {
        // frame_to_show_map_idx (3 bits)
        _ = reader.readBits(3) orelse return null;
        return .{
            .frame_type = .inter_frame, // Type doesn't matter for existing frame
            .show_frame = true,
            .show_existing_frame = true,
        };
    }

    // frame_type (2 bits)
    const frame_type_raw: u2 = @intCast(reader.readBits(2) orelse return null);
    const frame_type: FrameType = @enumFromInt(frame_type_raw);

    // show_frame (1 bit)
    const show_frame = (reader.readBit() orelse return null) != 0;

    return .{
        .frame_type = frame_type,
        .show_frame = show_frame,
        .show_existing_frame = false,
    };
}

// ============================================================================
// Main Stream Validator
// ============================================================================

/// Validate an AV1 OBU stream. Iterates through OBU units, parsing sequence
/// headers and counting frames. Returns validation result with stream metadata.
///
/// max_frames: Maximum number of frames to validate (0 = validate all).
pub fn validateAv1Stream(data: []const u8, max_frames: u32) Av1ValidationResult {
    if (data.len == 0) {
        return Av1ValidationResult.invalid("AV1: empty data");
    }

    if (data.len < 2) {
        return Av1ValidationResult.invalid("AV1: data too small for OBU header");
    }

    var pos: usize = 0;
    var seq_header: ?SequenceHeader = null;
    var frames_decoded: u32 = 0;
    var obu_count: u32 = 0;

    while (pos < data.len) {
        // Parse OBU header
        const header = parseObuHeader(data, &pos) orelse {
            if (obu_count == 0) {
                return Av1ValidationResult.invalid("AV1: invalid first OBU header");
            }
            // Trailing garbage after valid OBUs is tolerable in some contexts
            break;
        };
        obu_count += 1;

        // Determine OBU payload size
        var obu_size: u64 = 0;
        if (header.has_size_field) {
            obu_size = readLeb128(data, &pos) orelse {
                return Av1ValidationResult.invalid("AV1: truncated LEB128 OBU size");
            };
        } else {
            // OBU extends to end of data
            obu_size = data.len - pos;
        }

        // Validate that OBU payload fits in remaining data
        if (pos + obu_size > data.len) {
            return Av1ValidationResult.invalid("AV1: OBU size exceeds available data");
        }

        const payload_start = pos;
        const payload_end = pos + @as(usize, @intCast(obu_size));
        const payload = data[payload_start..payload_end];

        // Process OBU by type
        switch (header.obu_type) {
            .sequence_header => {
                seq_header = parseSequenceHeader(payload) orelse {
                    return Av1ValidationResult.invalid("AV1: invalid sequence header");
                };
            },
            .frame_header => {
                if (seq_header) |*seq| {
                    const fh = parseFrameHeaderSimplified(payload, seq) orelse {
                        return Av1ValidationResult.invalid("AV1: invalid frame header");
                    };
                    if (fh.show_frame or fh.show_existing_frame) {
                        frames_decoded += 1;
                    }
                } else {
                    return Av1ValidationResult.invalid("AV1: frame header before sequence header");
                }

                if (max_frames > 0 and frames_decoded >= max_frames) break;
            },
            .frame => {
                // Frame OBU contains frame_header + tile_group
                if (seq_header) |*seq| {
                    const fh = parseFrameHeaderSimplified(payload, seq) orelse {
                        return Av1ValidationResult.invalid("AV1: invalid frame OBU");
                    };
                    if (fh.show_frame or fh.show_existing_frame) {
                        frames_decoded += 1;
                    }
                } else {
                    return Av1ValidationResult.invalid("AV1: frame OBU before sequence header");
                }

                if (max_frames > 0 and frames_decoded >= max_frames) break;
            },
            .temporal_delimiter, .metadata, .tile_group, .tile_list, .padding, .redundant_frame_header => {
                // Skip these OBU types
            },
            .reserved_0 => {
                return Av1ValidationResult.invalid("AV1: reserved OBU type 0");
            },
            _ => {
                // Unknown OBU type - skip but don't reject (forward compatibility)
            },
        }

        // Advance position past OBU payload
        pos = payload_end;
    }

    // Final validation checks
    if (obu_count == 0) {
        return Av1ValidationResult.invalid("AV1: no OBUs found");
    }

    const seq = seq_header orelse {
        return Av1ValidationResult.invalid("AV1: no sequence header found");
    };

    // For non-still pictures, require at least one frame
    if (!seq.still_picture and frames_decoded == 0) {
        return Av1ValidationResult.invalid("AV1: no frames found in non-still-picture stream");
    }

    return Av1ValidationResult.ok(
        frames_decoded,
        seq.width,
        seq.height,
        seq.profile,
        seq.level,
    );
}

// ============================================================================
// Single Sample Validator (for MP4/MKV containers)
// ============================================================================

/// Validate a single AV1 sample (as extracted from MP4/MKV). A sample may
/// contain one or more OBUs (typically temporal_delimiter + frame_header +
/// tile_group, or a single frame OBU).
pub fn validateAv1Sample(data: []const u8) Av1SampleResult {
    if (data.len == 0) {
        return Av1SampleResult.invalid("AV1 sample: empty data");
    }

    var pos: usize = 0;
    var has_frame: bool = false;
    var frame_type: ?FrameType = null;
    var obu_count: u32 = 0;

    while (pos < data.len) {
        const header = parseObuHeader(data, &pos) orelse {
            if (obu_count == 0) {
                return Av1SampleResult.invalid("AV1 sample: invalid OBU header");
            }
            break;
        };
        obu_count += 1;

        var obu_size: u64 = 0;
        if (header.has_size_field) {
            obu_size = readLeb128(data, &pos) orelse {
                return Av1SampleResult.invalid("AV1 sample: truncated LEB128 size");
            };
        } else {
            obu_size = data.len - pos;
        }

        if (pos + obu_size > data.len) {
            return Av1SampleResult.invalid("AV1 sample: OBU size exceeds data");
        }

        const payload = data[pos..pos + @as(usize, @intCast(obu_size))];

        switch (header.obu_type) {
            .frame_header, .frame => {
                has_frame = true;
                // For sample validation without sequence header context,
                // parse what we can from the frame header
                if (payload.len >= 1) {
                    var reader = BitReader.init(payload);
                    // show_existing_frame (1 bit)
                    const show_existing = (reader.readBit() orelse {
                        return Av1SampleResult.invalid("AV1 sample: truncated frame header");
                    }) != 0;

                    if (!show_existing) {
                        // frame_type (2 bits)
                        const ft_raw: u2 = @intCast(reader.readBits(2) orelse {
                            return Av1SampleResult.invalid("AV1 sample: truncated frame type");
                        });
                        frame_type = @enumFromInt(ft_raw);
                    } else {
                        frame_type = .inter_frame;
                    }
                }
            },
            .temporal_delimiter, .metadata, .tile_group, .tile_list, .padding,
            .sequence_header, .redundant_frame_header,
            => {
                // Valid OBU types in a sample
            },
            .reserved_0 => {
                return Av1SampleResult.invalid("AV1 sample: reserved OBU type 0");
            },
            _ => {
                // Unknown but tolerated
            },
        }

        pos += @as(usize, @intCast(obu_size));
    }

    if (obu_count == 0) {
        return Av1SampleResult.invalid("AV1 sample: no OBUs found");
    }

    if (has_frame) {
        return Av1SampleResult.ok_frame(frame_type orelse .key_frame);
    }
    return Av1SampleResult.ok_no_frame();
}

// ============================================================================
// Tests
// ============================================================================

test "AV1 OBU stream validation rejects empty data" {
    const result = validateAv1Stream(&[_]u8{}, 0);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.error_message != null);
}

test "AV1 OBU stream rejects too-small data" {
    const result = validateAv1Stream(&[_]u8{0x00}, 0);
    try std.testing.expect(!result.valid);
    // Single byte with forbidden_bit=0, type=0 (reserved) should fail
}

test "AV1 LEB128 decoding" {
    // Test value 0: single byte 0x00
    {
        const data = [_]u8{0x00};
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, 0), val);
        try std.testing.expectEqual(@as(usize, 1), pos);
    }

    // Test value 127: single byte 0x7F
    {
        const data = [_]u8{0x7F};
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, 127), val);
        try std.testing.expectEqual(@as(usize, 1), pos);
    }

    // Test value 128: two bytes 0x80 0x01
    {
        const data = [_]u8{ 0x80, 0x01 };
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, 128), val);
        try std.testing.expectEqual(@as(usize, 2), pos);
    }

    // Test value 300: two bytes (300 = 0x80|0x2C, 0x02 = 0xAC, 0x02)
    {
        const data = [_]u8{ 0xAC, 0x02 };
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, 300), val);
        try std.testing.expectEqual(@as(usize, 2), pos);
    }

    // Test truncated LEB128 (continuation bit set but no more data)
    {
        const data = [_]u8{0x80};
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, null), val);
    }

    // Test empty data
    {
        const data = [_]u8{};
        var pos: usize = 0;
        const val = readLeb128(&data, &pos);
        try std.testing.expectEqual(@as(?u64, null), val);
    }
}

test "AV1 OBU header parsing" {
    // Test forbidden bit rejection
    {
        // 0x80 = forbidden_bit=1, type=0, no extension, no size, reserved=0
        const data = [_]u8{0x80};
        var pos: usize = 0;
        const header = parseObuHeader(&data, &pos);
        try std.testing.expect(header == null);
    }

    // Test reserved bit rejection
    {
        // 0x09 = forbidden=0, type=1(seq_header), ext=0, size=0, reserved=1
        const data = [_]u8{0x09};
        var pos: usize = 0;
        const header = parseObuHeader(&data, &pos);
        try std.testing.expect(header == null);
    }

    // Test valid sequence header OBU header (no extension, with size)
    {
        // 0x0A = forbidden=0, type=1(0001), ext=0, size=1, reserved=0
        const data = [_]u8{0x0A};
        var pos: usize = 0;
        const header = parseObuHeader(&data, &pos);
        try std.testing.expect(header != null);
        try std.testing.expectEqual(ObuType.sequence_header, header.?.obu_type);
        try std.testing.expect(!header.?.has_extension);
        try std.testing.expect(header.?.has_size_field);
    }

    // Test valid frame OBU header with extension
    {
        // 0x34 = forbidden=0, type=6(0110), ext=1, size=0, reserved=0
        // Extension byte: temporal_id=2 (010), spatial_id=1 (01), reserved=000 => 0b01001000 = 0x48
        const data = [_]u8{ 0x34, 0x48 };
        var pos: usize = 0;
        const header = parseObuHeader(&data, &pos);
        try std.testing.expect(header != null);
        try std.testing.expectEqual(ObuType.frame, header.?.obu_type);
        try std.testing.expect(header.?.has_extension);
        try std.testing.expect(!header.?.has_size_field);
        try std.testing.expectEqual(@as(u3, 2), header.?.temporal_id);
        try std.testing.expectEqual(@as(u2, 1), header.?.spatial_id);
    }

    // Test temporal delimiter OBU header
    {
        // 0x12 = forbidden=0, type=2(0010), ext=0, size=1, reserved=0
        const data = [_]u8{0x12};
        var pos: usize = 0;
        const header = parseObuHeader(&data, &pos);
        try std.testing.expect(header != null);
        try std.testing.expectEqual(ObuType.temporal_delimiter, header.?.obu_type);
    }
}

test "AV1 sequence header parsing with synthetic data" {
    // Construct a minimal valid sequence header for Profile 0, 320x240
    // Using reduced_still_picture_header for simplicity
    //
    // Bit layout:
    //   seq_profile = 0 (3 bits: 000)
    //   still_picture = 0 (1 bit: 0)    -- not actually still, but reduced_still overrides
    //   reduced_still_picture_header = 1 (1 bit: 1)
    //   -- Wait, reduced_still requires still_picture=1. Let's set still_picture=1.
    //
    // Corrected:
    //   seq_profile = 0 (3 bits: 000)
    //   still_picture = 1 (1 bit: 1)
    //   reduced_still_picture_header = 1 (1 bit: 1)
    //   seq_level_idx[0] = 1 (5 bits: 00001)
    //   frame_width_bits_minus_1 = 8 (4 bits: 1000) → 9 bits for width
    //   frame_height_bits_minus_1 = 7 (4 bits: 0111) → 8 bits for height
    //   max_frame_width_minus_1 = 319 (9 bits: 100111111)
    //   max_frame_height_minus_1 = 239 (8 bits: 11101111)
    //   use_128x128_superblock = 0 (1 bit: 0)
    //   enable_filter_intra = 0 (1 bit: 0)
    //   enable_intra_edge_filter = 0 (1 bit: 0)
    //   enable_superres = 0 (1 bit: 0)
    //   enable_cdef = 0 (1 bit: 0)
    //   enable_restoration = 0 (1 bit: 0)
    //   color_config:
    //     high_bitdepth = 0 (1 bit: 0)
    //     mono_chrome = 0 (1 bit: 0)  (profile 0, not profile 1)
    //     color_description_present = 0 (1 bit: 0)
    //     color_range = 0 (1 bit: 0)
    //     (profile 0 → subsampling 4:2:0 implicit)
    //     chroma_sample_position = 0 (2 bits: 00)
    //     separate_uv_delta_q = 0 (1 bit: 0)
    //   film_grain_params_present = 0 (1 bit: 0)
    //
    // Bits in sequence:
    //   000 1 1 00001 1000 0111 100111111 11101111 0 0 0 0 0 0 0 0 0 0 00 0 0
    //
    // Group into bytes (MSB first):
    //   00011 00001 1000 0111 100111111 11101111 00 0000 000 00 0 0
    //   Bit 0: 0
    //   Bit 1: 0
    //   Bit 2: 0
    //   Bit 3: 1
    //   Bit 4: 1
    //   Bit 5: 0
    //   Bit 6: 0
    //   Bit 7: 0
    //   => Byte 0: 0b00011000 = 0x18
    //
    //   Bit 8: 0
    //   Bit 9: 1
    //   Bit 10: 1 (frame_width_bits_minus_1 = 8 = 1000)
    //   Bit 11: 0
    //   Bit 12: 0
    //   Bit 13: 0 (frame_height_bits_minus_1 = 7 = 0111)
    //   Bit 14: 0
    //   Bit 15: 1
    //   => Byte 1: 0b01100001 = 0x61
    //
    //   Bit 16: 1
    //   Bit 17: 1 (max_frame_width_minus_1 = 319 = 100111111, 9 bits)
    //   Bit 18: 1
    //   Bit 19: 0
    //   Bit 20: 0
    //   Bit 21: 1
    //   Bit 22: 1
    //   Bit 23: 1
    //   => Byte 2: 0b11100111 = 0xE7

    //   Wait, let me redo this more carefully. Let me lay out every bit position.
    //
    //   Bits 0-2: seq_profile = 000
    //   Bit 3: still_picture = 1
    //   Bit 4: reduced_still_picture_header = 1
    //   Bits 5-9: seq_level_idx = 00001
    //   Bits 10-13: frame_width_bits_minus_1 = 1000
    //   Bits 14-17: frame_height_bits_minus_1 = 0111
    //   Bits 18-26: max_frame_width_minus_1 = 100111111 (319)
    //   Bits 27-34: max_frame_height_minus_1 = 11101111 (239)
    //   Bit 35: use_128x128_superblock = 0
    //   Bit 36: enable_filter_intra = 0
    //   Bit 37: enable_intra_edge_filter = 0
    //   Bit 38: enable_superres = 0
    //   Bit 39: enable_cdef = 0
    //   Bit 40: enable_restoration = 0
    //   Bit 41: high_bitdepth = 0
    //   Bit 42: mono_chrome = 0
    //   Bit 43: color_description_present = 0
    //   Bit 44: color_range = 0
    //   Bits 45-46: chroma_sample_position = 00
    //   Bit 47: separate_uv_delta_q = 0
    //   Bit 48: film_grain_params_present = 0
    //
    // Total: 49 bits = 7 bytes (with 7 padding bits)

    // Byte 0 (bits 0-7): 000 1 1 000 = 0x18
    // Byte 1 (bits 8-15): 01 1000 01 = 0x61
    // Byte 2 (bits 16-23): 11 10011 1 = 0xE7
    //   Wait, let me be more precise:
    //   Bit 5=0,6=0,7=0 (first 3 of seq_level_idx=00001)
    //   So byte 0: bits 0-7 = 0,0,0,1,1,0,0,0 = 0x18 ✓
    //
    //   Bit 8=0 (4th of level), bit 9=1 (5th of level)
    //   Bit 10=1,11=0,12=0,13=0 (frame_width_bits_minus_1=8=1000)
    //   Bit 14=0,15=1 (first 2 of frame_height_bits_minus_1=7=0111)
    //   Byte 1: 0,1,1,0,0,0,0,1 = 0x61 ✓
    //
    //   Bit 16=1,17=1 (last 2 of frame_height_bits_minus_1=0111)
    //   Bit 18-26: max_frame_width_minus_1=319=100111111
    //   Bit 18=1,19=0,20=0,21=1,22=1,23=1
    //   Byte 2: 1,1,1,0,0,1,1,1 = 0xE7 ✓
    //
    //   Bit 24=1,25=1,26=1 (last 3 of width)
    //   Bit 27-34: max_frame_height_minus_1=239=11101111
    //   Bit 27=1,28=1,29=1,30=0,31=1
    //   Byte 3: 1,1,1,1,1,1,0,1 = 0xFD
    //
    //   Bit 32=1,33=1,34=1 (last 3 of height)
    //   Bit 35=0 (use_128x128_superblock)
    //   Bit 36=0 (enable_filter_intra)
    //   Bit 37=0 (enable_intra_edge_filter)
    //   Bit 38=0 (enable_superres)
    //   Bit 39=0 (enable_cdef)
    //   Byte 4: 1,1,1,0,0,0,0,0 = 0xE0
    //
    //   Bit 40=0 (enable_restoration)
    //   Bit 41=0 (high_bitdepth)
    //   Bit 42=0 (mono_chrome)
    //   Bit 43=0 (color_description_present)
    //   Bit 44=0 (color_range)
    //   Bit 45=0,46=0 (chroma_sample_position)
    //   Bit 47=0 (separate_uv_delta_q)
    //   Byte 5: 0,0,0,0,0,0,0,0 = 0x00
    //
    //   Bit 48=0 (film_grain_params_present)
    //   Byte 6: 0,0,0,0,0,0,0,0 = 0x00

    const seq_header_payload = [_]u8{ 0x18, 0x61, 0xE7, 0xFD, 0xE0, 0x00, 0x00 };

    const seq = parseSequenceHeader(&seq_header_payload);
    try std.testing.expect(seq != null);

    const s = seq.?;
    try std.testing.expectEqual(@as(u8, 0), s.profile);
    try std.testing.expectEqual(@as(u8, 1), s.level);
    try std.testing.expectEqual(@as(u32, 320), s.width);
    try std.testing.expectEqual(@as(u32, 240), s.height);
    try std.testing.expect(s.still_picture);
    try std.testing.expect(s.reduced_still_picture_header);
}

test "AV1 validates stream with sequence header and frame" {
    // Build a minimal valid AV1 stream with:
    // 1. Temporal delimiter OBU
    // 2. Sequence header OBU (Profile 0, 320x240, reduced_still=true, still_picture=true)
    // 3. Frame OBU (show_existing_frame=0, frame_type=KEY_FRAME, show_frame=1)

    // Temporal delimiter OBU: header=0x12 (type=2, has_size=1), size=0
    // Sequence header OBU: header=0x0A (type=1, has_size=1), size=7, payload as above
    // Frame OBU: header=0x32 (type=6(0110), ext=0, size=1, reserved=0), size=LEB(N), payload

    // For the frame OBU in a reduced_still_picture_header context:
    // The frame header is implicit (key_frame, show_frame=true).
    // But we still need a minimal frame payload. Since reduced_still_picture_header
    // makes the frame header implicit, we just need some tile data.
    // Let's provide a small dummy payload.

    // Actually, let's use non-reduced for the frame header test so we can exercise frame parsing.
    // Use reduced_still_picture_header = true (still picture), so frame header is implicit.

    // With reduced_still_picture_header, the frame header parsing returns:
    // frame_type=key_frame, show_frame=true, show_existing_frame=false
    // So we just need any frame OBU with any payload.

    var stream: [32]u8 = undefined;
    var off: usize = 0;

    // Temporal delimiter OBU
    stream[off] = 0x12; // type=2, has_size=1
    off += 1;
    stream[off] = 0x00; // LEB128 size = 0
    off += 1;

    // Sequence header OBU
    stream[off] = 0x0A; // type=1, has_size=1
    off += 1;
    stream[off] = 0x07; // LEB128 size = 7
    off += 1;
    // Sequence header payload (from previous test)
    const seq_payload = [_]u8{ 0x18, 0x61, 0xE7, 0xFD, 0xE0, 0x00, 0x00 };
    @memcpy(stream[off .. off + seq_payload.len], &seq_payload);
    off += seq_payload.len;

    // Frame OBU (type=6, has_size=1)
    // 0x32 = forbidden=0, type=6(0110), ext=0, size=1, reserved=0
    stream[off] = 0x32;
    off += 1;
    stream[off] = 0x02; // LEB128 size = 2 (2 bytes of dummy tile data)
    off += 1;
    // Dummy frame payload (doesn't matter much for reduced_still, but provide some bytes)
    stream[off] = 0x00;
    off += 1;
    stream[off] = 0x00;
    off += 1;

    const result = validateAv1Stream(stream[0..off], 0);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.has_sequence_header);
    try std.testing.expectEqual(@as(u32, 320), result.width);
    try std.testing.expectEqual(@as(u32, 240), result.height);
    try std.testing.expectEqual(@as(u8, 0), result.profile);
    try std.testing.expectEqual(@as(u8, 1), result.level);
    try std.testing.expectEqual(@as(u32, 1), result.frames_decoded);
}

test "AV1 rejects stream without sequence header" {
    // Frame OBU without preceding sequence header
    var stream: [8]u8 = undefined;
    stream[0] = 0x32; // Frame OBU, type=6, has_size=1
    stream[1] = 0x02; // size=2
    stream[2] = 0x00;
    stream[3] = 0x00;

    const result = validateAv1Stream(stream[0..4], 0);
    try std.testing.expect(!result.valid);
}

test "AV1 sample validation" {
    // Test a sample with a frame OBU
    // Frame OBU header: type=6, has_size=1, no extension
    // 0x32 = forbidden=0, type=6(0110), ext=0, size=1, reserved=0
    var sample: [8]u8 = undefined;
    sample[0] = 0x32; // Frame OBU
    sample[1] = 0x03; // LEB128 size = 3
    // Frame header bits: show_existing_frame=0, frame_type=00(KEY), show_frame=1
    // Bits: 0 00 1 xxxx = 0b00010000 = 0x10
    sample[2] = 0x10;
    sample[3] = 0x00;
    sample[4] = 0x00;

    const result = validateAv1Sample(sample[0..5]);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.has_frame);
    try std.testing.expectEqual(FrameType.key_frame, result.frame_type.?);
}

test "AV1 sample rejects empty data" {
    const result = validateAv1Sample(&[_]u8{});
    try std.testing.expect(!result.valid);
}

test "AV1 sample with temporal delimiter only" {
    // Temporal delimiter OBU: type=2, has_size=1, size=0
    var sample: [2]u8 = undefined;
    sample[0] = 0x12; // type=2, has_size=1
    sample[1] = 0x00; // size=0

    const result = validateAv1Sample(sample[0..2]);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.has_frame);
}

test "AV1 rejects forbidden bit" {
    // 0x80 = forbidden_bit=1
    const result = validateAv1Stream(&[_]u8{ 0x80, 0x00 }, 0);
    try std.testing.expect(!result.valid);
}

test "AV1 sequence header rejects invalid profile" {
    // Profile 3 (invalid): 011 in first 3 bits
    // Byte 0: 0110 0000 = 0x60 (profile=3, still=0, reduced=0...)
    // This should fail in parseSequenceHeader because profile > 2
    var payload = [_]u8{ 0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const seq = parseSequenceHeader(&payload);
    try std.testing.expect(seq == null);
}

test "AV1 max_frames limit" {
    // Build a stream with sequence header + 3 frame OBUs, validate only 2
    var stream: [64]u8 = undefined;
    var off: usize = 0;

    // Sequence header OBU
    stream[off] = 0x0A; // type=1, has_size=1
    off += 1;
    stream[off] = 0x07; // size=7
    off += 1;
    const seq_payload = [_]u8{ 0x18, 0x61, 0xE7, 0xFD, 0xE0, 0x00, 0x00 };
    @memcpy(stream[off .. off + seq_payload.len], &seq_payload);
    off += seq_payload.len;

    // Add 3 frame OBUs (reduced_still: frame header is implicit key + show)
    for (0..3) |_| {
        stream[off] = 0x32; // Frame OBU type=6, has_size=1
        off += 1;
        stream[off] = 0x01; // size=1
        off += 1;
        stream[off] = 0x00; // dummy payload
        off += 1;
    }

    const result = validateAv1Stream(stream[0..off], 2);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.frames_decoded);
}
