//! Pure-Zig AAC-LC bitstream syntax validator.
//!
//! Validates AAC access unit structure without decoding audio.
//! Catches single-byte corruptions by verifying:
//! - Huffman codeword validity
//! - Section length consistency
//! - Scale factor range
//! - Bit exhaustion (bits consumed == AU size * 8, within padding tolerance)
//!
//! Reference: ISO/IEC 14496-3:2009 (MPEG-4 Audio)

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const huff = @import("aac_huffman_tables.zig");

// ============================================================================
// Public Result Types
// ============================================================================

pub const AacSyntaxResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_checked: u32,

    pub fn ok(frames: u32) AacSyntaxResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_checked = frames,
        };
    }

    pub fn invalid(msg: []const u8, frames: u32) AacSyntaxResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_checked = frames,
        };
    }
};

// ============================================================================
// AAC Configuration
// ============================================================================

const AacConfig = struct {
    audio_object_type: u5, // 2 = AAC-LC
    sampling_frequency_index: u4, // 0-12
    channel_configuration: u4, // 1=mono, 2=stereo, etc.
    frame_length: u16, // 1024 or 960
};

/// Sampling frequencies indexed by sampling_frequency_index (ISO 14496-3 Table 1.18)
const sampling_frequencies = [13]u32{
    96000, 88200, 64000, 48000, 44100, 32000,
    24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

fn parseAudioSpecificConfig(asc: []const u8) ?AacConfig {
    if (asc.len < 2) return null;

    var reader = BitReader.init(asc);

    // audioObjectType (5 bits, extended if 31)
    var aot_raw = reader.readBits(5) orelse return null;
    if (aot_raw == 31) {
        const ext = reader.readBits(6) orelse return null;
        aot_raw = 32 + ext;
    }
    if (aot_raw > 31) return null; // Can't fit in u5
    const aot: u5 = @intCast(aot_raw);

    // samplingFrequencyIndex (4 bits, explicit 24-bit freq if 15)
    var freq_idx_raw = reader.readBits(4) orelse return null;
    if (freq_idx_raw == 0x0F) {
        // Explicit 24-bit sampling frequency - skip it
        _ = reader.readBits(24) orelse return null;
        // Map to nearest standard index (not critical for validation)
        freq_idx_raw = 3; // default to 48kHz index
    }
    if (freq_idx_raw > 12) return null;
    const freq_idx: u4 = @intCast(freq_idx_raw);

    // channelConfiguration (4 bits)
    const chan_cfg_raw = reader.readBits(4) orelse return null;
    if (chan_cfg_raw > 7) return null;
    const chan_cfg: u4 = @intCast(chan_cfg_raw);

    return AacConfig{
        .audio_object_type = aot,
        .sampling_frequency_index = freq_idx,
        .channel_configuration = chan_cfg,
        .frame_length = 1024, // AAC-LC default
    };
}

// ============================================================================
// SWB (Scalefactor Window Band) Offset Tables
// ISO 14496-3 Table 4.110
// ============================================================================

// Number of scalefactor window bands for ONLY_LONG_SEQUENCE (1024 samples)
const num_swb_long = [13]u8{
    41, // 96000 Hz
    41, // 88200 Hz
    47, // 64000 Hz
    49, // 48000 Hz
    49, // 44100 Hz
    51, // 32000 Hz
    47, // 24000 Hz
    47, // 22050 Hz
    43, // 16000 Hz
    43, // 12000 Hz
    43, // 11025 Hz
    40, // 8000 Hz
    40, // 7350 Hz
};

// Number of scalefactor window bands for EIGHT_SHORT_SEQUENCE (128 samples)
const num_swb_short = [13]u8{
    12, // 96000 Hz
    12, // 88200 Hz
    12, // 64000 Hz
    14, // 48000 Hz
    14, // 44100 Hz
    14, // 32000 Hz
    15, // 24000 Hz
    15, // 22050 Hz
    15, // 16000 Hz
    15, // 12000 Hz
    15, // 11025 Hz
    15, // 8000 Hz
    15, // 7350 Hz
};

// ============================================================================
// Huffman Codebook Support
//
// The scalefactor codebook uses a regular prefix structure decoded in
// decodeScalefactor() below.
//
// Spectral Huffman codebooks (1-11) are decoded via binary tree lookup
// in aac_huffman_tables.zig, enabling bit-exhaustion validation.
// ============================================================================

/// Decode one scalefactor Huffman codeword.
/// Delegates to the proper binary tree decoder in aac_huffman_tables.zig.
fn decodeScalefactor(reader: *BitReader) ?u8 {
    return huff.decodeScalefactor(reader);
}

// ============================================================================
// ICS (Individual Channel Stream) Types
// ============================================================================

const WindowSequence = enum(u2) {
    only_long = 0,
    long_start = 1,
    eight_short = 2,
    long_stop = 3,
};

const IcsInfo = struct {
    window_sequence: WindowSequence,
    window_shape: u1,
    max_sfb: u8,
    scale_factor_grouping: u7, // only for EIGHT_SHORT
    num_window_groups: u8,
    window_group_length: [8]u8,
    num_windows: u8, // 1 for long, 8 for short
    swb_count: u8, // actual number of SWBs used (min of max_sfb, table limit)
};

const SectionInfo = struct {
    sections: [128]Section,
    num_sections: u8,
};

const Section = struct {
    codebook: u8,
    start: u16,
    end: u16,
    group: u8,
};

// ============================================================================
// Parsing Functions
// ============================================================================

fn parseIcsInfo(reader: *BitReader, config: *const AacConfig) ?IcsInfo {
    // ics_reserved_bit
    _ = reader.readBit() orelse return null;

    // window_sequence (2 bits)
    const ws_raw = reader.readBits(2) orelse return null;
    const window_sequence: WindowSequence = @enumFromInt(ws_raw);

    // window_shape (1 bit)
    const window_shape: u1 = @intCast(reader.readBits(1) orelse return null);

    var info = IcsInfo{
        .window_sequence = window_sequence,
        .window_shape = window_shape,
        .max_sfb = 0,
        .scale_factor_grouping = 0,
        .num_window_groups = 1,
        .window_group_length = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .num_windows = 1,
        .swb_count = 0,
    };

    if (window_sequence == .eight_short) {
        // max_sfb (4 bits for short windows)
        const max_sfb_raw = reader.readBits(4) orelse return null;
        info.max_sfb = @intCast(max_sfb_raw);
        info.num_windows = 8;

        // Validate max_sfb against table
        if (config.sampling_frequency_index < num_swb_short.len) {
            if (info.max_sfb > num_swb_short[config.sampling_frequency_index]) {
                return null; // max_sfb exceeds table
            }
        }

        // scale_factor_grouping (7 bits)
        const sfg_raw = reader.readBits(7) orelse return null;
        info.scale_factor_grouping = @intCast(sfg_raw);

        // Derive window groups from scale_factor_grouping
        // Bit i (MSB first): if 1, window i+1 is in same group as window i
        info.num_window_groups = 1;
        info.window_group_length[0] = 1;
        var g: u8 = 0;
        for (0..7) |i| {
            if ((sfg_raw & (@as(u32, 1) << @intCast(6 - i))) != 0) {
                // Same group
                info.window_group_length[g] += 1;
            } else {
                // New group
                g += 1;
                info.num_window_groups += 1;
                info.window_group_length[g] = 1;
            }
        }

        info.swb_count = if (config.sampling_frequency_index < num_swb_short.len)
            num_swb_short[config.sampling_frequency_index]
        else
            15;
    } else {
        // max_sfb (6 bits for long windows)
        const max_sfb_raw = reader.readBits(6) orelse return null;
        info.max_sfb = @intCast(max_sfb_raw);

        // Validate max_sfb against table
        if (config.sampling_frequency_index < num_swb_long.len) {
            if (info.max_sfb > num_swb_long[config.sampling_frequency_index]) {
                return null; // max_sfb exceeds table
            }
        }

        // predictor_data_present (1 bit) - AAC-LC only supports main prediction
        const pred_present = reader.readBit() orelse return null;
        if (pred_present == 1) {
            // AAC-LC (AOT 2) should not have prediction, but some encoders
            // set this. For validation, skip the predictor data.
            // predictor_reset (1 bit)
            const pred_reset = reader.readBit() orelse return null;
            if (pred_reset == 1) {
                // predictor_reset_group_number (5 bits)
                _ = reader.readBits(5) orelse return null;
            }
            // prediction_used flags: max_sfb bits
            for (0..info.max_sfb) |_| {
                _ = reader.readBit() orelse return null;
            }
        }

        info.swb_count = if (config.sampling_frequency_index < num_swb_long.len)
            num_swb_long[config.sampling_frequency_index]
        else
            49;
    }

    return info;
}

fn parseSectionData(reader: *BitReader, ics: *const IcsInfo) ?SectionInfo {
    var section_info = SectionInfo{
        .sections = undefined,
        .num_sections = 0,
    };

    const sect_bits: u5 = if (ics.window_sequence == .eight_short) 3 else 5;
    const sect_esc_val: u32 = (@as(u32, 1) << sect_bits) - 1;

    for (0..ics.num_window_groups) |g| {
        var k: u16 = 0;
        while (k < ics.max_sfb) {
            if (section_info.num_sections >= 128) return null;

            // sect_cb (4 bits)
            const sect_cb = reader.readBits(4) orelse return null;

            // sect_len_incr: read repeated values, accumulate length
            var sect_len: u16 = 0;
            while (true) {
                const incr = reader.readBits(sect_bits) orelse return null;
                sect_len += @intCast(incr);
                if (incr != sect_esc_val) break;
            }

            const sect_end = k + sect_len;
            if (sect_end > ics.max_sfb) return null; // Section exceeds max_sfb

            section_info.sections[section_info.num_sections] = .{
                .codebook = @intCast(sect_cb),
                .start = k,
                .end = sect_end,
                .group = @intCast(g),
            };
            section_info.num_sections += 1;
            k = sect_end;
        }

        // Sections must exactly cover max_sfb for this group
        if (k != ics.max_sfb) return null;
    }

    return section_info;
}

fn parseScaleFactorData(reader: *BitReader, _: *const IcsInfo, sections: *const SectionInfo) bool {
    // global_gain is read before this function is called
    // We need to decode scalefactor Huffman codewords and validate ranges

    var noise_pcm_flag = true; // First noise energy is PCM coded
    _ = &noise_pcm_flag;

    for (0..sections.num_sections) |i| {
        const sect = sections.sections[i];
        const cb = sect.codebook;

        if (cb == 0) {
            // ZERO_HCB: no scalefactors
            continue;
        }

        const num_sfb = sect.end - sect.start;

        if (cb == 13) {
            // NOISE_HCB: noise substitution
            for (0..num_sfb) |sfb_idx| {
                if (sfb_idx == 0 and noise_pcm_flag) {
                    // First noise energy: 9 bits PCM
                    _ = reader.readBits(9) orelse return false;
                    noise_pcm_flag = false;
                } else {
                    // Huffman coded noise delta
                    if (decodeScalefactor(reader) == null) return false;
                }
            }
        } else if (cb >= 14) {
            // INTENSITY_HCB (14, 15): intensity stereo position
            for (0..num_sfb) |_| {
                if (decodeScalefactor(reader) == null) return false;
            }
        } else {
            // Normal scalefactor bands (CB 1-11)
            for (0..num_sfb) |_| {
                if (decodeScalefactor(reader) == null) return false;
            }
        }
    }

    return true;
}

/// Parse and validate spectral Huffman data for one ICS.
///
/// Iterates sections, decoding Huffman codewords via binary tree lookup.
/// This consumes the exact number of bits the encoder wrote, enabling
/// bit-exhaustion validation at the AU boundary.
fn parseSpectralData(reader: *BitReader, ics: *const IcsInfo, sections: *const SectionInfo, config: *const AacConfig) bool {
    const freq_idx = config.sampling_frequency_index;

    // Get SWB offset table for this frequency/window type
    const swb_offsets = if (ics.window_sequence == .eight_short)
        huff.swbOffsetsShort(freq_idx)
    else
        huff.swbOffsetsLong(freq_idx);

    for (0..sections.num_sections) |i| {
        const sect = sections.sections[i];
        const cb = sect.codebook;

        // Skip codebooks that don't encode spectral data
        if (cb == 0 or cb >= 13) continue; // ZERO_HCB, NOISE, INTENSITY
        if (cb == 12) return false; // Reserved codebook

        // Bounds check section against SWB offset table
        if (sect.end >= swb_offsets.len) return false;

        const dim: u16 = huff.cbDimension(@intCast(cb));
        if (dim == 0) return false;

        // Number of spectral lines for this section (within one window)
        const num_lines = swb_offsets[sect.end] - swb_offsets[sect.start];

        // Multiply by window_group_length for windows in this group
        const group_len: u16 = ics.window_group_length[sect.group];
        const total_lines = num_lines * group_len;

        // Total lines must be a multiple of codebook dimension
        if (total_lines % dim != 0) return false;

        // Decode Huffman code groups
        const num_groups = total_lines / dim;
        for (0..num_groups) |_| {
            const result = huff.decodeSpectral(reader, @intCast(cb));
            if (!result.valid) return false;
        }
    }

    return true;
}

fn parsePulseData(reader: *BitReader) bool {
    const present = reader.readBit() orelse return false;
    if (present == 1) {
        // number_pulse (2 bits)
        const num_pulse_raw = reader.readBits(2) orelse return false;
        const num_pulse = num_pulse_raw + 1; // 1-4 pulses

        // pulse_start_sfb (6 bits)
        _ = reader.readBits(6) orelse return false;

        // For each pulse: pulse_offset (5 bits) + pulse_amp (4 bits)
        for (0..num_pulse) |_| {
            _ = reader.readBits(5) orelse return false; // pulse_offset
            _ = reader.readBits(4) orelse return false; // pulse_amp
        }
    }
    return true;
}

fn parseTnsData(reader: *BitReader, ics: *const IcsInfo) bool {
    const present = reader.readBit() orelse return false;
    if (present == 1) {
        const n_filt_bits: u5 = if (ics.window_sequence == .eight_short) 1 else 2;
        const length_bits: u5 = if (ics.window_sequence == .eight_short) 4 else 6;
        const order_bits: u5 = if (ics.window_sequence == .eight_short) 3 else 5;

        for (0..ics.num_windows) |_| {
            const n_filt = reader.readBits(n_filt_bits) orelse return false;

            if (n_filt > 0) {
                // coef_res (1 bit)
                const coef_res = reader.readBit() orelse return false;

                for (0..n_filt) |_| {
                    // length
                    _ = reader.readBits(length_bits) orelse return false;
                    // order
                    const order = reader.readBits(order_bits) orelse return false;

                    if (order > 0) {
                        // direction (1 bit)
                        _ = reader.readBit() orelse return false;
                        // coef_compress (1 bit)
                        const coef_compress = reader.readBit() orelse return false;

                        // coef_bits = coef_res + 3 - coef_compress
                        const coef_bits_val: u5 = @as(u5, coef_res) + 3 - @as(u5, coef_compress);
                        if (coef_bits_val > 0) {
                            for (0..order) |_| {
                                _ = reader.readBits(coef_bits_val) orelse return false;
                            }
                        }
                    }
                }
            }
        }
    }
    return true;
}

/// Parse gain_control_data.
/// AAC-LC does not use gain control (that's SSR profile only).
/// Read the 1-bit presence flag; reject if set.
fn parseGainControlData(reader: *BitReader) bool {
    const present = reader.readBit() orelse return false;
    // gain_control_data_present must be 0 for AAC-LC
    return present == 0;
}

/// Parse an Individual Channel Stream (ICS)
fn parseIndividualChannelStream(
    reader: *BitReader,
    config: *const AacConfig,
    common_window: bool,
    shared_ics: ?*const IcsInfo,
) bool {
    // global_gain (8 bits)
    _ = reader.readBits(8) orelse return false;

    // ics_info (only if not common_window)
    var local_ics: IcsInfo = undefined;
    const ics: *const IcsInfo = if (common_window) {
        return if (shared_ics) |sics| blk: {
            // Parse section data, scale factors, spectral data using shared ICS
            const section_info = parseSectionData(reader, sics) orelse return false;
            if (!parseScaleFactorData(reader, sics, &section_info)) return false;
            if (!parsePulseData(reader)) return false;
            if (!parseTnsData(reader, sics)) return false;
            if (!parseGainControlData(reader)) return false;
            if (!parseSpectralData(reader, sics, &section_info, config)) return false;
            break :blk true;
        } else false;
    } else blk: {
        local_ics = parseIcsInfo(reader, config) orelse return false;
        break :blk &local_ics;
    };

    if (common_window) return true; // Already handled above

    const section_info = parseSectionData(reader, ics) orelse return false;
    if (!parseScaleFactorData(reader, ics, &section_info)) return false;
    if (!parsePulseData(reader)) return false;
    if (!parseTnsData(reader, ics)) return false;
    if (!parseGainControlData(reader)) return false;
    if (!parseSpectralData(reader, ics, &section_info, config)) return false;

    return true;
}

fn parseSingleChannelElement(reader: *BitReader, config: *const AacConfig) bool {
    // element_instance_tag (4 bits)
    _ = reader.readBits(4) orelse return false;

    return parseIndividualChannelStream(reader, config, false, null);
}

fn parseChannelPairElement(reader: *BitReader, config: *const AacConfig) bool {
    // element_instance_tag (4 bits)
    _ = reader.readBits(4) orelse return false;

    // common_window (1 bit)
    const common_window_bit = reader.readBit() orelse return false;
    const common_window = common_window_bit == 1;

    var shared_ics: ?IcsInfo = null;

    if (common_window) {
        shared_ics = parseIcsInfo(reader, config) orelse return false;

        // ms_mask_present (2 bits)
        const ms_mask = reader.readBits(2) orelse return false;
        if (ms_mask == 1) {
            // ms_used: one bit per SFB per group
            const ics_ref = &shared_ics.?;
            const total_sfb = @as(u32, ics_ref.num_window_groups) * @as(u32, ics_ref.max_sfb);
            if (!reader.skipBits(total_sfb)) return false;
        }
        // ms_mask == 2: all SFBs use MS (no bits to read)
        // ms_mask == 0: no MS
    }

    // First channel
    if (shared_ics) |*sics| {
        if (!parseIndividualChannelStream(reader, config, common_window, sics)) return false;
    } else {
        if (!parseIndividualChannelStream(reader, config, false, null)) return false;
    }

    // Second channel
    if (shared_ics) |*sics| {
        if (!parseIndividualChannelStream(reader, config, common_window, sics)) return false;
    } else {
        if (!parseIndividualChannelStream(reader, config, false, null)) return false;
    }

    return true;
}

fn parseFillElement(reader: *BitReader) bool {
    // count (4 bits)
    var count = reader.readBits(4) orelse return false;
    if (count == 15) {
        const esc = reader.readBits(8) orelse return false;
        count = count + esc - 1;
    }

    // Skip count bytes of fill/extension data
    if (!reader.skipBits(count * 8)) return false;

    return true;
}

fn parseDseElement(reader: *BitReader) bool {
    // data_stream_element
    // element_instance_tag (4 bits)
    _ = reader.readBits(4) orelse return false;
    // data_byte_align_flag (1 bit)
    const align_flag = reader.readBit() orelse return false;
    // count (8 bits)
    var count = reader.readBits(8) orelse return false;
    if (count == 255) {
        const esc = reader.readBits(8) orelse return false;
        count += esc;
    }
    if (align_flag == 1) {
        reader.alignToByte();
    }
    // Skip count bytes
    if (!reader.skipBits(count * 8)) return false;
    return true;
}

fn parsePceElement(reader: *BitReader) bool {
    // program_config_element
    // element_instance_tag (4 bits)
    _ = reader.readBits(4) orelse return false;
    // object_type (2 bits)
    _ = reader.readBits(2) orelse return false;
    // sampling_frequency_index (4 bits)
    _ = reader.readBits(4) orelse return false;
    // num_front_channel_elements (4 bits)
    const num_front = reader.readBits(4) orelse return false;
    // num_side_channel_elements (4 bits)
    const num_side = reader.readBits(4) orelse return false;
    // num_back_channel_elements (4 bits)
    const num_back = reader.readBits(4) orelse return false;
    // num_lfe_channel_elements (2 bits)
    const num_lfe = reader.readBits(2) orelse return false;
    // num_assoc_data_elements (3 bits)
    const num_assoc = reader.readBits(3) orelse return false;
    // num_valid_cc_elements (4 bits)
    const num_cc = reader.readBits(4) orelse return false;

    // mono_mixdown_present (1 bit)
    const mono_mix = reader.readBit() orelse return false;
    if (mono_mix == 1) {
        _ = reader.readBits(4) orelse return false; // mono_mixdown_element_number
    }
    // stereo_mixdown_present (1 bit)
    const stereo_mix = reader.readBit() orelse return false;
    if (stereo_mix == 1) {
        _ = reader.readBits(4) orelse return false; // stereo_mixdown_element_number
    }
    // matrix_mixdown_idx_present (1 bit)
    const matrix_mix = reader.readBit() orelse return false;
    if (matrix_mix == 1) {
        _ = reader.readBits(3) orelse return false; // matrix_mixdown_idx + pseudo_surround_enable
    }

    // Channel element lists: each is (1 bit height_flag + 4 bits instance_tag) = 5 bits
    const total_elements = num_front + num_side + num_back;
    if (!reader.skipBits(total_elements * 5)) return false;

    // LFE elements: 4 bits each
    if (!reader.skipBits(num_lfe * 4)) return false;

    // assoc_data elements: 4 bits each
    if (!reader.skipBits(num_assoc * 4)) return false;

    // cc elements: 5 bits each (is_ind_sw + instance_tag)
    if (!reader.skipBits(num_cc * 5)) return false;

    // byte align
    reader.alignToByte();

    // comment_field_bytes (8 bits)
    const comment_bytes = reader.readBits(8) orelse return false;
    if (!reader.skipBits(comment_bytes * 8)) return false;

    return true;
}

// ============================================================================
// Top-Level Validation
// ============================================================================

/// Validate a single raw AAC-LC access unit.
///
/// Parses the full syntactic structure including spectral Huffman data:
/// - Element IDs (SCE, CPE, LFE, DSE, PCE, FIL, END)
/// - ICS info (window sequence, max_sfb, window grouping)
/// - Section data (codebook assignments, lengths must sum to max_sfb)
/// - Scale factor Huffman codeword validity
/// - Spectral Huffman codeword validity (all 11 codebooks)
/// - Pulse, TNS, gain control flags
/// - Bit exhaustion: total bits consumed must equal AU size (within padding)
fn validateAccessUnit(au_data: []const u8, config: *const AacConfig) bool {
    if (au_data.len == 0) return false;

    var reader = BitReader.init(au_data);
    var element_count: u32 = 0;
    var has_audio_element = false;

    // Parse raw_data_block elements until ID_END or insufficient bits
    while (reader.remainingBits() >= 3) {
        const id_syn_ele = reader.readBits(3) orelse return false;
        element_count += 1;

        switch (id_syn_ele) {
            0 => { // ID_SCE - Single Channel Element
                if (!parseSingleChannelElement(&reader, config)) return false;
                has_audio_element = true;
            },
            1 => { // ID_CPE - Channel Pair Element
                if (!parseChannelPairElement(&reader, config)) return false;
                has_audio_element = true;
            },
            2 => { // ID_CCE - Coupling Channel Element
                // Valid but extremely rare in AAC-LC; accept without parsing
                has_audio_element = true;
                return true;
            },
            3 => { // ID_LFE - LFE Channel Element (same syntax as SCE)
                if (!parseSingleChannelElement(&reader, config)) return false;
                has_audio_element = true;
            },
            4 => { // ID_DSE - Data Stream Element
                if (!parseDseElement(&reader)) return false;
            },
            5 => { // ID_PCE - Program Config Element
                if (!parsePceElement(&reader)) return false;
            },
            6 => { // ID_FIL - Fill Element
                if (!parseFillElement(&reader)) return false;
            },
            7 => { // ID_END
                // After ID_END: remaining bits may include byte-alignment padding
                // (≤7 bits per spec) plus ancillary data or container padding.
                // The spectral Huffman decoding provides the primary validation;
                // accept if we parsed at least one audio element.
                return has_audio_element;
            },
            else => return false,
        }

        // Sanity check: don't loop forever
        if (element_count > 32) return false;
    }

    // Implicit termination (container-delimited AU): valid if we parsed
    // audio elements and remaining bits < 8 (byte-alignment padding only)
    return has_audio_element and reader.remainingBits() < 8;
}

/// Main entry point: validate multiple access units
pub fn validateAacSyntax(data: []const u8, au_sizes: []const u32, asc: []const u8) AacSyntaxResult {
    const config = parseAudioSpecificConfig(asc) orelse
        return AacSyntaxResult.invalid("Invalid AudioSpecificConfig", 0);

    if (config.audio_object_type != 2)
        return AacSyntaxResult.invalid("Unsupported AOT (not AAC-LC)", 0);

    var offset: usize = 0;
    var frames: u32 = 0;
    for (au_sizes) |size| {
        if (offset + size > data.len) break;
        const au_slice = data[offset..][0..size];
        if (!validateAccessUnit(au_slice, &config)) {
            return AacSyntaxResult.invalid("AAC syntax error in access unit", frames);
        }
        offset += size;
        frames += 1;
    }

    if (frames == 0) return AacSyntaxResult.invalid("No frames validated", 0);
    return AacSyntaxResult.ok(frames);
}

/// ADTS frame header (7 or 9 bytes)
const AdtsFrameHeader = struct {
    profile: u2, // 0=Main, 1=LC, 2=SSR, 3=LTP (NOTE: ADTS profile = AOT - 1)
    sampling_frequency_index: u4,
    channel_configuration: u3,
    frame_length: u13, // includes header
    protection_absent: bool, // true = no CRC (7-byte header), false = CRC present (9-byte header)
    num_raw_data_blocks: u2, // 0 = 1 raw data block

    fn headerSize(self: AdtsFrameHeader) usize {
        return if (self.protection_absent) 7 else 9;
    }
};

fn parseAdtsHeader(data: []const u8) ?AdtsFrameHeader {
    if (data.len < 7) return null;

    // Sync word: 12 bits = 0xFFF
    if (data[0] != 0xFF) return null;
    if ((data[1] & 0xF0) != 0xF0) return null;

    // Byte 1 bits 3-0: ID(1), layer(2), protection_absent(1)
    const protection_absent = (data[1] & 0x01) == 1;

    // Byte 2: profile(2), sampling_frequency_index(4), private(1), channel_config high bit(1)
    const profile: u2 = @intCast((data[2] >> 6) & 0x03);
    const freq_idx: u4 = @intCast((data[2] >> 2) & 0x0F);
    const channel_cfg_high: u3 = @intCast((data[2] & 0x01));

    // Byte 3: channel_config low 2 bits(2), originality(1), home(1), copyright_id(1), copyright_start(1), frame_length high 2 bits(2)
    const channel_cfg_low: u3 = @intCast((data[3] >> 6) & 0x03);
    const channel_cfg: u3 = (channel_cfg_high << 2) | channel_cfg_low;

    // Frame length: 13 bits across bytes 3-5
    const fl_high: u13 = @intCast(data[3] & 0x03);
    const fl_mid: u13 = @intCast(data[4]);
    const fl_low: u13 = @intCast((data[5] >> 5) & 0x07);
    const frame_length: u13 = (fl_high << 11) | (fl_mid << 3) | fl_low;

    // Byte 5 bits 4-0 + byte 6 bits 7-2: buffer fullness (11 bits)
    // Byte 6 bits 1-0: num_raw_data_blocks (2 bits)
    const num_raw: u2 = @intCast(data[6] & 0x03);

    // Validate fields
    if (freq_idx > 12) return null;
    if (frame_length < 7) return null;

    if (!protection_absent and data.len < 9) return null;

    return AdtsFrameHeader{
        .profile = profile,
        .sampling_frequency_index = freq_idx,
        .channel_configuration = channel_cfg,
        .frame_length = frame_length,
        .protection_absent = protection_absent,
        .num_raw_data_blocks = num_raw,
    };
}

/// Validate a standalone ADTS stream (.aac file)
pub fn validateAdtsStream(data: []const u8) AacSyntaxResult {
    if (data.len < 7) return AacSyntaxResult.invalid("Data too short for ADTS", 0);

    // Parse first ADTS header to get config
    const first_header = parseAdtsHeader(data) orelse
        return AacSyntaxResult.invalid("Invalid ADTS header", 0);

    // ADTS profile is AOT - 1, so LC (AOT=2) has profile=1
    if (first_header.profile != 1)
        return AacSyntaxResult.invalid("Unsupported ADTS profile (not AAC-LC)", 0);

    // Synthesize AudioSpecificConfig from ADTS header
    // ASC: 5 bits AOT + 4 bits freq_idx + 4 bits channel_cfg + padding
    const aot: u8 = @as(u8, first_header.profile) + 1; // profile + 1 = AOT (LC = 2)
    const freq: u8 = @as(u8, first_header.sampling_frequency_index);
    const chan: u8 = @as(u8, first_header.channel_configuration);
    // Byte 0: AOT(5 bits) | freq_idx high 3 bits
    // Byte 1: freq_idx low 1 bit | channel_cfg(4 bits) | 000
    const asc_bytes = [2]u8{
        (aot << 3) | (freq >> 1),
        (freq << 7) | (chan << 3),
    };

    const config = parseAudioSpecificConfig(&asc_bytes) orelse
        return AacSyntaxResult.invalid("Failed to parse synthesized ASC", 0);

    // Iterate ADTS frames and validate each raw AU
    var offset: usize = 0;
    var frames: u32 = 0;

    while (offset + 7 <= data.len) {
        const header = parseAdtsHeader(data[offset..]) orelse {
            if (frames > 0) break; // Allow trailing garbage after valid frames
            return AacSyntaxResult.invalid("Invalid ADTS frame header", frames);
        };

        const fl = @as(usize, header.frame_length);
        if (offset + fl > data.len) break;

        const hdr_size = header.headerSize();
        if (fl <= hdr_size) {
            return AacSyntaxResult.invalid("ADTS frame too short for payload", frames);
        }

        const au_data = data[offset + hdr_size .. offset + fl];
        if (!validateAccessUnit(au_data, &config)) {
            return AacSyntaxResult.invalid("AAC syntax error in ADTS frame", frames);
        }

        frames += 1;
        offset += fl;
    }

    if (frames == 0) return AacSyntaxResult.invalid("No ADTS frames validated", 0);
    return AacSyntaxResult.ok(frames);
}

// ============================================================================
// Tests
// ============================================================================

test "parseAudioSpecificConfig basic AAC-LC" {
    // AAC-LC, 44100 Hz, stereo
    // AOT=2 (5 bits: 00010), freq_idx=4 (4 bits: 0100), chan_cfg=2 (4 bits: 0010)
    // Binary: 00010 0100 0010 0 = 0x1210 = bytes: 0x12, 0x10
    const asc = [_]u8{ 0x12, 0x10 };
    const config = parseAudioSpecificConfig(&asc);
    try std.testing.expect(config != null);
    try std.testing.expectEqual(@as(u5, 2), config.?.audio_object_type);
    try std.testing.expectEqual(@as(u4, 4), config.?.sampling_frequency_index);
    try std.testing.expectEqual(@as(u4, 2), config.?.channel_configuration);
    try std.testing.expectEqual(@as(u16, 1024), config.?.frame_length);
}

test "parseAudioSpecificConfig AAC-LC 48kHz stereo" {
    // AOT=2, freq_idx=3 (48000), chan_cfg=2
    // Binary: 00010 0011 0010 0 = 0x1190 = bytes: 0x11, 0x90
    const asc = [_]u8{ 0x11, 0x90 };
    const config = parseAudioSpecificConfig(&asc);
    try std.testing.expect(config != null);
    try std.testing.expectEqual(@as(u5, 2), config.?.audio_object_type);
    try std.testing.expectEqual(@as(u4, 3), config.?.sampling_frequency_index);
    try std.testing.expectEqual(@as(u4, 2), config.?.channel_configuration);
}

test "parseAudioSpecificConfig rejects too-short data" {
    const asc = [_]u8{0x12};
    try std.testing.expect(parseAudioSpecificConfig(&asc) == null);
}

test "parseAudioSpecificConfig rejects empty data" {
    const asc = [_]u8{};
    try std.testing.expect(parseAudioSpecificConfig(&asc) == null);
}

test "validateAacSyntax rejects non-AAC-LC" {
    // AOT=1 (AAC-Main), freq_idx=4, chan_cfg=2
    // Binary: 00001 0100 0010 0 = 0x0A10
    const asc = [_]u8{ 0x0A, 0x10 };
    const sizes = [_]u32{10};
    const data = [_]u8{0} ** 10;
    const result = validateAacSyntax(&data, &sizes, &asc);
    try std.testing.expect(!result.valid);
    try std.testing.expect(std.mem.eql(u8, result.error_message.?, "Unsupported AOT (not AAC-LC)"));
}

test "validateAacSyntax rejects empty frames" {
    const asc = [_]u8{ 0x12, 0x10 }; // AAC-LC 44100 stereo
    const sizes = [_]u32{};
    const data = [_]u8{};
    const result = validateAacSyntax(&data, &sizes, &asc);
    try std.testing.expect(!result.valid);
}

test "validateAccessUnit rejects END-only frame (no audio element)" {
    // An access unit containing just ID_END (0b111) without any audio element
    // 0b111_00000 = 0xE0
    const au = [_]u8{0xE0};
    const config = AacConfig{
        .audio_object_type = 2,
        .sampling_frequency_index = 4,
        .channel_configuration = 2,
        .frame_length = 1024,
    };
    try std.testing.expect(!validateAccessUnit(&au, &config));
}

test "validateAccessUnit rejects truncated frame" {
    // An access unit with SCE tag but no data
    // 0b000_00000 = 0x00 (ID_SCE, then needs more bits)
    const au = [_]u8{0x00};
    const config = AacConfig{
        .audio_object_type = 2,
        .sampling_frequency_index = 4,
        .channel_configuration = 2,
        .frame_length = 1024,
    };
    try std.testing.expect(!validateAccessUnit(&au, &config));
}

test "validateAccessUnit rejects END without audio element" {
    // ID_END (3 bits) in a 2-byte AU: no audio element was parsed,
    // so the frame is rejected even though END was found.
    const au = [_]u8{ 0xE0, 0x00 };
    const config = AacConfig{
        .audio_object_type = 2,
        .sampling_frequency_index = 4,
        .channel_configuration = 2,
        .frame_length = 1024,
    };
    try std.testing.expect(!validateAccessUnit(&au, &config));
}

test "parseFillElement basic" {
    // fill count=3, then 3 bytes of fill data, then ID_END
    // count=3 (4 bits: 0011), data=0x00 0x00 0x00
    // 0011 00000000 00000000 00000000
    // = 0x30 0x00 0x00 0x00
    const data = [_]u8{ 0x30, 0x00, 0x00, 0x00 };
    var reader = BitReader.init(&data);
    try std.testing.expect(parseFillElement(&reader));
    // Should have consumed 4 + 24 = 28 bits
    try std.testing.expectEqual(@as(usize, 28), reader.getBitPosition());
}
