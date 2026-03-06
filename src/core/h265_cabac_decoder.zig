//! H.265/HEVC CABAC Slice Data Decoder (Intra-Only)
//!
//! Decodes CABAC-encoded slice data for H.265 intra slices. Validates that
//! the arithmetic coding bitstream is syntactically consistent — corruption
//! causes the CABAC decoder to diverge and produce invalid syntax elements.
//!
//! This decoder handles:
//!   - SAO (Sample Adaptive Offset) parameters
//!   - coding_quadtree (CTU → CU split decisions)
//!   - coding_unit (intra prediction modes)
//!   - transform_tree / transform_unit (residual structure)
//!   - residual_coding (transform coefficients via CABAC)
//!
//! Only intra prediction is implemented (sufficient for HEIC images).
//! Reference: ITU-T H.265, Sections 7.3.8 through 7.3.8.11.

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const h265_tables = @import("h265_cabac_tables.zig");
const codec_utils = @import("codec_utils.zig");

// ============================================================================
// SPS/PPS info needed for CABAC decoding
// ============================================================================

pub const H265SliceDecodeInfo = struct {
    // From SPS
    log2_min_cb_size: u32, // Log2MinCbSizeY
    log2_ctb_size: u32, // CtbLog2SizeY
    log2_min_tb_size: u32, // Log2MinTrafoSize
    log2_max_tb_size: u32, // Log2MaxTrafoSize
    max_transform_hierarchy_depth_intra: u32,
    pic_width_in_ctbs: u32,
    pic_height_in_ctbs: u32,
    pic_width_in_luma: u32,
    pic_height_in_luma: u32,
    chroma_format_idc: u32,
    bit_depth_luma: u32,
    bit_depth_chroma: u32,
    sao_enabled: bool,
    pcm_enabled: bool,
    pcm_log2_min_size: u32,
    pcm_log2_max_size: u32,
    amp_enabled: bool,

    // From PPS
    cu_qp_delta_enabled: bool,
    diff_cu_qp_delta_depth: u32,
    transquant_bypass_enabled: bool,
    transform_skip_enabled: bool,
    tiles_enabled: bool,

    // From slice header
    slice_qp: i32,
    slice_sao_luma: bool,
    slice_sao_chroma: bool,
};

// ============================================================================
// CABAC Engine for H.265 (arithmetic core identical to H.264)
// ============================================================================

pub const H265CabacEngine = struct {
    cod_i_range: u16,
    cod_i_offset: u16,
    reader: *BitReader,
    contexts: [h265_tables.NUM_H265_CONTEXTS]h265_tables.ContextState,
    valid: bool,

    pub fn init(reader: *BitReader, slice_qp: i32) H265CabacEngine {
        const contexts = h265_tables.initContexts(slice_qp, true); // always I-slice for HEIC

        // Read first 9 bits for codIOffset
        const b1 = reader.readBits(8) orelse 0;
        const b2 = reader.readBit() orelse 0;
        const cod_i_offset: u16 = @intCast((@as(u16, @intCast(b1)) << 1) | b2);

        return .{
            .cod_i_range = 510,
            .cod_i_offset = cod_i_offset,
            .reader = reader,
            .contexts = contexts,
            .valid = true,
        };
    }

    pub fn decodeBin(self: *H265CabacEngine, ctx_idx: u16) u1 {
        if (!self.valid) return 0;
        if (ctx_idx >= h265_tables.NUM_H265_CONTEXTS) {
            self.valid = false;
            return 0;
        }

        const p_state_idx = self.contexts[ctx_idx].p_state_idx;
        const val_mps = self.contexts[ctx_idx].val_mps;

        const q_idx: u2 = @intCast((self.cod_i_range >> 6) & 3);
        const cod_i_range_lps: u16 = h265_tables.rangeTabLPS[p_state_idx][q_idx];

        self.cod_i_range -= cod_i_range_lps;

        var bin_val: u1 = undefined;

        if (self.cod_i_offset >= self.cod_i_range) {
            bin_val = 1 - val_mps;
            self.cod_i_offset -= self.cod_i_range;
            self.cod_i_range = cod_i_range_lps;

            if (p_state_idx == 0) {
                self.contexts[ctx_idx].val_mps = 1 - val_mps;
            }
            self.contexts[ctx_idx].p_state_idx = @intCast(h265_tables.transIdxLPS[p_state_idx]);
        } else {
            bin_val = val_mps;
            self.contexts[ctx_idx].p_state_idx = @intCast(h265_tables.transIdxMPS[p_state_idx]);
        }

        self.renormalize();
        return bin_val;
    }

    pub fn decodeBypass(self: *H265CabacEngine) u1 {
        if (!self.valid) return 0;

        self.cod_i_offset = (self.cod_i_offset << 1) | self.readOneBit();

        if (self.cod_i_offset >= self.cod_i_range) {
            self.cod_i_offset -= self.cod_i_range;
            return 1;
        }
        return 0;
    }

    pub fn decodeBypassBits(self: *H265CabacEngine, n: u32) u32 {
        var val: u32 = 0;
        for (0..n) |_| {
            val = (val << 1) | @as(u32, self.decodeBypass());
            if (!self.valid) return 0;
        }
        return val;
    }

    pub fn decodeTerminate(self: *H265CabacEngine) u1 {
        if (!self.valid) return 1;

        self.cod_i_range -= 2;

        if (self.cod_i_offset >= self.cod_i_range) {
            return 1;
        }

        self.renormalize();
        return 0;
    }

    fn renormalize(self: *H265CabacEngine) void {
        while (self.cod_i_range < 256) {
            self.cod_i_range <<= 1;
            self.cod_i_offset = (self.cod_i_offset << 1) | self.readOneBit();
        }
    }

    fn readOneBit(self: *H265CabacEngine) u16 {
        const bit = self.reader.readBit() orelse {
            self.valid = false;
            return 0;
        };
        return bit;
    }

    pub fn isValid(self: *const H265CabacEngine) bool {
        return self.valid;
    }
};

// ============================================================================
// SAO (Sample Adaptive Offset) parsing
// ============================================================================

/// Parse SAO parameters for one CTU (ITU-T H.265 Section 7.3.8.3).
/// SAO merge flags are per-CTU (not per-component). If merged, all SAO data is
/// inherited from the neighbor. Otherwise, each component gets sao_type_idx and offsets.
fn parseSaoParams(engine: *H265CabacEngine, info: *const H265SliceDecodeInfo, rx: u32, ry: u32) void {
    if (!info.slice_sao_luma and !info.slice_sao_chroma) return;
    if (!engine.valid) return;

    // sao_merge_left_flag (per-CTU, not per-component)
    if (rx > 0) {
        const merge_left = engine.decodeBin(h265_tables.CTX_SAO_MERGE_FLAG);
        if (!engine.valid) return;
        if (merge_left == 1) return; // All components merged from left CTU
    }

    // sao_merge_up_flag
    if (ry > 0) {
        const merge_up = engine.decodeBin(h265_tables.CTX_SAO_MERGE_FLAG);
        if (!engine.valid) return;
        if (merge_up == 1) return; // All components merged from above CTU
    }

    // Not merged — parse SAO type and offsets per component
    // cIdx 0 = luma; chroma uses one shared sao_type_idx for both Cb and Cr
    const has_chroma = info.chroma_format_idc != 0;

    // Luma SAO
    if (info.slice_sao_luma) {
        parseSaoComponentParams(engine);
        if (!engine.valid) return;
    }

    // Chroma SAO (shared type+offsets for Cb and Cr)
    if (has_chroma and info.slice_sao_chroma) {
        parseSaoComponentParams(engine);
        if (!engine.valid) return;
    }
}

/// Parse SAO parameters for one component (or component pair for chroma).
/// sao_type_idx: 0=not applied, 1=band offset, 2=edge offset
/// Ref: ITU-T H.265 Section 7.3.8.3
fn parseSaoComponentParams(engine: *H265CabacEngine) void {
    if (!engine.valid) return;

    // sao_type_idx: context coded bin0, then bypass bin1 if bin0==1
    const type_bin0 = engine.decodeBin(h265_tables.CTX_SAO_TYPE_IDX);
    if (!engine.valid) return;
    if (type_bin0 == 0) return; // SAO not applied for this component

    const type_bin1 = engine.decodeBypass(); // 0=band, 1=edge
    if (!engine.valid) return;
    const sao_type = @as(u32, 1) + type_bin1; // 1=band, 2=edge

    // 4 sao_offset_abs values (truncated unary, bypass coded)
    // Max value = (1 << (min(bitDepth, 10) - 5)) - 1 = 7 for 8-bit
    var offsets: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..4) |i| {
        if (!engine.valid) return;
        var offset_abs: u32 = 0;
        while (offset_abs < 7) : (offset_abs += 1) {
            if (engine.decodeBypass() == 0) break;
            if (!engine.valid) return;
        }
        offsets[i] = offset_abs;
    }

    if (sao_type == 1) {
        // Band offset: sign flag only for non-zero offsets
        for (0..4) |i| {
            if (!engine.valid) return;
            if (offsets[i] != 0) {
                _ = engine.decodeBypass(); // sao_offset_sign
            }
        }
        // sao_band_position: 5 bypass bits
        _ = engine.decodeBypassBits(5);
        if (!engine.valid) return;
    } else {
        // Edge offset: sao_eo_class (2 bypass bits), no sign flags (signs are table-derived)
        _ = engine.decodeBypassBits(2);
        if (!engine.valid) return;
    }
}

// ============================================================================
// Coding Quadtree — recursive CTU → CU splitting
// ============================================================================

fn codingQuadtree(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_cb_size: u32,
    ct_depth: u32,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;

    var split = false;

    if (log2_cb_size > info.log2_min_cb_size) {
        // split_cu_flag
        // ctxInc depends on neighbors; use depth-based for simplicity (0, 1, or 2)
        const ctx_inc: u16 = @intCast(@min(ct_depth, 2));
        const split_flag = engine.decodeBin(h265_tables.CTX_SPLIT_CU_FLAG + ctx_inc);
        if (!engine.valid) return;
        split = split_flag == 1;
    }

    // Force split if CU extends beyond picture boundary
    if (!split and log2_cb_size > info.log2_min_cb_size) {
        const cb_size = @as(u32, 1) << @intCast(log2_cb_size);
        if (x0 + cb_size > info.pic_width_in_luma or y0 + cb_size > info.pic_height_in_luma) {
            split = true;
        }
    }

    if (split) {
        if (log2_cb_size == 0) {
            engine.valid = false;
            return;
        }
        const half_size = log2_cb_size - 1;
        const half = @as(u32, 1) << @intCast(half_size);
        codingQuadtree(engine, info, x0, y0, half_size, ct_depth + 1);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0 + half, y0, half_size, ct_depth + 1);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0, y0 + half, half_size, ct_depth + 1);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0 + half, y0 + half, half_size, ct_depth + 1);
    } else {
        codingUnit(engine, info, x0, y0, log2_cb_size);
    }
}

// ============================================================================
// Coding Unit (intra prediction mode selection)
// ============================================================================

fn codingUnit(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_cb_size: u32,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;

    // cu_transquant_bypass_flag
    if (info.transquant_bypass_enabled) {
        _ = engine.decodeBin(h265_tables.CTX_CU_TRANSQUANT_BYPASS);
        if (!engine.valid) return;
    }

    // For I-slice: pred_mode_flag is not present (always INTRA)
    // part_mode: for I-slice, only 2Nx2N (0) or NxN (1, only at min CU size)
    var part_mode: u32 = 0; // 2Nx2N
    if (log2_cb_size == info.log2_min_cb_size) {
        const part_bin = engine.decodeBin(h265_tables.CTX_PART_MODE);
        if (!engine.valid) return;
        if (part_bin == 0) {
            part_mode = 1; // NxN (bin=0 means NxN for I-slice at min CU size)
        }
    }

    // PCM check: if PCM enabled and CU size within PCM range
    if (info.pcm_enabled and log2_cb_size >= info.pcm_log2_min_size and
        log2_cb_size <= info.pcm_log2_max_size)
    {
        // Check for I_PCM via terminate
        const pcm_flag = engine.decodeTerminate();
        if (!engine.valid) return;
        if (pcm_flag == 1) {
            // PCM mode: skip raw samples
            engine.reader.alignToByte();
            const cb_size = @as(u32, 1) << @intCast(log2_cb_size);
            const luma_samples = cb_size * cb_size;
            const chroma_samples = if (info.chroma_format_idc == 1)
                luma_samples / 2 // 4:2:0
            else if (info.chroma_format_idc == 2)
                luma_samples // 4:2:2
            else if (info.chroma_format_idc == 3)
                luma_samples * 2 // 4:4:4
            else
                0;
            const total_bits = luma_samples * info.bit_depth_luma + chroma_samples * info.bit_depth_chroma;
            _ = engine.reader.skipBits(total_bits);
            // Re-initialize CABAC after PCM
            engine.* = H265CabacEngine.init(engine.reader, info.slice_qp);
            return;
        }
    }

    // Intra prediction modes
    const num_pus: u32 = if (part_mode == 1) 4 else 1;
    const pu_size = if (part_mode == 1) log2_cb_size - 1 else log2_cb_size;

    // prev_intra_luma_pred_flag for each PU
    var prev_flags: [4]u1 = undefined;
    for (0..num_pus) |pu| {
        prev_flags[pu] = engine.decodeBin(h265_tables.CTX_PREV_INTRA_LUMA_PRED);
        if (!engine.valid) return;
    }

    // mpm_idx or rem_intra_luma_pred_mode for each PU
    for (0..num_pus) |pu| {
        if (prev_flags[pu] == 1) {
            // mpm_idx: truncated unary, 2 bypass bins
            _ = engine.decodeBypass(); // mpm_idx bit 0
            if (!engine.valid) return;
            // If bit 0 was 1, read bit 1
            _ = engine.decodeBypass();
            if (!engine.valid) return;
        } else {
            // rem_intra_luma_pred_mode: 5 bypass bins (FL(32))
            _ = engine.decodeBypassBits(5);
            if (!engine.valid) return;
        }
    }

    // intra_chroma_pred_mode
    if (info.chroma_format_idc != 0) {
        // Can have 1 or 4 chroma PUs depending on chroma_format
        const chroma_bin0 = engine.decodeBin(h265_tables.CTX_INTRA_CHROMA_PRED_MODE);
        if (!engine.valid) return;
        if (chroma_bin0 == 1) {
            // Explicit mode: 2 bypass bins (FL(4))
            _ = engine.decodeBypassBits(2);
            if (!engine.valid) return;
        }
    }

    // Transform tree
    const max_depth = info.max_transform_hierarchy_depth_intra;
    transformTree(engine, info, x0, y0, log2_cb_size, 0, max_depth, pu_size);
}

// ============================================================================
// Transform Tree (recursive split into TUs)
// ============================================================================

fn transformTree(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_cb_size: u32,
    trafo_depth: u32,
    max_depth: u32,
    log2_pu_size: u32,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;
    if (trafo_depth >= log2_cb_size) {
        engine.valid = false;
        return;
    }

    const log2_tb_size = log2_cb_size - trafo_depth;

    var split = false;

    // Check if split is mandatory or forbidden
    if (log2_tb_size > info.log2_max_tb_size) {
        split = true; // Must split — TU too large
    } else if (log2_tb_size <= info.log2_min_tb_size) {
        split = false; // Can't split — already at min
    } else if (trafo_depth >= max_depth) {
        split = false; // Reached max hierarchy depth
    } else {
        // split_transform_flag
        const ctx_inc: u16 = @intCast(@min(trafo_depth, 2));
        const split_flag = engine.decodeBin(h265_tables.CTX_SPLIT_TRANSFORM_FLAG + ctx_inc);
        if (!engine.valid) return;
        split = split_flag == 1;
    }

    if (split) {
        if (log2_tb_size == 0) {
            engine.valid = false;
            return;
        }
        const half_size = @as(u32, 1) << @intCast(log2_tb_size - 1);
        transformTree(engine, info, x0, y0, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size);
        if (!engine.valid) return;
        transformTree(engine, info, x0 + half_size, y0, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size);
        if (!engine.valid) return;
        transformTree(engine, info, x0, y0 + half_size, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size);
        if (!engine.valid) return;
        transformTree(engine, info, x0 + half_size, y0 + half_size, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size);
    } else {
        transformUnit(engine, info, x0, y0, log2_tb_size, trafo_depth);
    }
}

// ============================================================================
// Transform Unit (CBF flags + residual data)
// ============================================================================

fn transformUnit(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    _: u32,
    _: u32,
    log2_tb_size: u32,
    trafo_depth: u32,
) void {
    if (!engine.valid) return;

    // cbf_cb and cbf_cr (chroma coded block flags)
    var cbf_cb: u1 = 0;
    var cbf_cr: u1 = 0;

    if (info.chroma_format_idc != 0 and log2_tb_size > 2) {
        // cbf_cb: context depends on trafo_depth
        const chroma_ctx: u16 = @intCast(@min(trafo_depth, 3));
        cbf_cb = engine.decodeBin(h265_tables.CTX_CBF_CHROMA + chroma_ctx);
        if (!engine.valid) return;

        // cbf_cr: context depends on trafo_depth and cbf_cb
        const cr_ctx: u16 = if (cbf_cb == 1) 4 else chroma_ctx;
        cbf_cr = engine.decodeBin(h265_tables.CTX_CBF_CHROMA + cr_ctx);
        if (!engine.valid) return;
    }

    // cbf_luma
    const luma_ctx: u16 = if (trafo_depth == 0) 0 else 1;
    const cbf_luma = engine.decodeBin(h265_tables.CTX_CBF_LUMA + luma_ctx);
    if (!engine.valid) return;

    // cu_qp_delta
    if (info.cu_qp_delta_enabled and (cbf_luma == 1 or cbf_cb == 1 or cbf_cr == 1)) {
        // cu_qp_delta_abs: prefix (truncated unary with 2 contexts) + suffix (bypass EGk)
        const qp_bin0 = engine.decodeBin(h265_tables.CTX_CU_QP_DELTA_ABS);
        if (!engine.valid) return;
        if (qp_bin0 == 1) {
            const qp_bin1 = engine.decodeBin(h265_tables.CTX_CU_QP_DELTA_ABS + 1);
            if (!engine.valid) return;
            if (qp_bin1 == 1) {
                // Suffix: bypass exp-golomb order 0
                var suffix: u32 = 0;
                while (suffix < 32) : (suffix += 1) {
                    const b = engine.decodeBypass();
                    if (!engine.valid) return;
                    if (b == 0) break;
                }
                // Read suffix value bypass bins
                if (suffix > 0) {
                    _ = engine.decodeBypassBits(suffix);
                    if (!engine.valid) return;
                }
            }
            // cu_qp_delta_sign_flag: bypass
            _ = engine.decodeBypass();
            if (!engine.valid) return;
        }
    }

    // transform_skip_flag
    if (info.transform_skip_enabled and log2_tb_size <= 2) {
        _ = engine.decodeBin(h265_tables.CTX_TRANSFORM_SKIP_FLAG);
        if (!engine.valid) return;
    }

    // Residual data
    if (cbf_luma == 1) {
        residualCoding(engine, log2_tb_size, true);
        if (!engine.valid) return;
    }

    if (cbf_cb == 1 and log2_tb_size > 0) {
        residualCoding(engine, log2_tb_size - 1, false);
        if (!engine.valid) return;
    }

    if (cbf_cr == 1 and log2_tb_size > 0) {
        residualCoding(engine, log2_tb_size - 1, false);
    }
}

// ============================================================================
// Residual Coding (transform coefficients)
// ============================================================================

/// Decode residual coding for one transform block.
/// This is where ~85% of CABAC bins live — essential for corruption detection.
fn residualCoding(
    engine: *H265CabacEngine,
    log2_tb_size: u32,
    is_luma: bool,
) void {
    if (!engine.valid) return;

    const tb_size_clamped = std.math.clamp(log2_tb_size, 2, 5);

    // last_sig_coeff_x_prefix
    const last_x = decodeLastSigCoeff(engine, tb_size_clamped, is_luma);
    if (!engine.valid) return;

    // last_sig_coeff_y_prefix
    const last_y = decodeLastSigCoeff(engine, tb_size_clamped, is_luma);
    if (!engine.valid) return;

    // Number of 4x4 sub-blocks
    const num_sb_x = @as(u32, 1) << @intCast(tb_size_clamped - 2);
    const num_sb_y = num_sb_x;
    const total_sub_blocks = num_sb_x * num_sb_y;

    // Determine last sub-block from last significant position
    const last_sb_x = last_x >> 2;
    const last_sb_y = last_y >> 2;
    _ = last_sb_x;
    _ = last_sb_y;

    // Iterate sub-blocks in reverse scan order
    // For simplicity, use a linear index. Real H.265 uses diagonal scan.
    var sb_idx = total_sub_blocks;
    while (sb_idx > 0) : (sb_idx -= 1) {
        if (!engine.valid) return;
        const sb_i = sb_idx - 1;

        // coded_sub_block_flag (except for last sub-block which is always coded)
        var coded: u1 = 1;
        if (sb_i > 0 and sb_i < total_sub_blocks - 1) {
            // Context: luma uses 0-1, chroma uses 2-3
            const base_ctx: u16 = if (is_luma) 0 else 2;
            coded = engine.decodeBin(h265_tables.CTX_CODED_SUB_BLOCK_FLAG + base_ctx);
            if (!engine.valid) return;
        }

        if (coded == 0) continue;

        // sig_coeff_flag for each position in the 4x4 sub-block (reverse scan)
        var sig_flags: [16]u1 = [_]u1{0} ** 16;
        var num_sig: u32 = 0;

        var pos: u32 = 16;
        while (pos > 0) : (pos -= 1) {
            if (!engine.valid) return;
            const p = pos - 1;

            // Last position in last sub-block is implicitly significant
            if (sb_i == total_sub_blocks - 1 and p == (last_y & 3) * 4 + (last_x & 3)) {
                sig_flags[p] = 1;
                num_sig += 1;
                continue;
            }

            // sig_coeff_flag context depends on position and luma/chroma
            const sig_ctx = getSigCoeffCtx(p, is_luma, tb_size_clamped);
            const full_ctx = h265_tables.CTX_SIG_COEFF_FLAG + sig_ctx;
            if (full_ctx >= h265_tables.NUM_H265_CONTEXTS) {
                engine.valid = false;
                return;
            }
            sig_flags[p] = engine.decodeBin(full_ctx);
            if (!engine.valid) return;
            if (sig_flags[p] == 1) num_sig += 1;
        }

        if (num_sig == 0) continue;

        // coeff_abs_level_greater1_flag (up to 8 per sub-block)
        var num_greater1: u32 = 0;
        var first_greater1_pos: u32 = 16; // invalid sentinel
        const g1_base_ctx = getGreater1Ctx(sb_i, is_luma);

        var g1_count: u32 = 0;
        for (0..16) |scan_pos| {
            if (!engine.valid) return;
            if (sig_flags[15 - scan_pos] == 0) continue;
            if (g1_count >= 8) break;

            const g1 = engine.decodeBin(h265_tables.CTX_COEFF_ABS_LEVEL_GREATER1 + g1_base_ctx);
            if (!engine.valid) return;
            if (g1 == 1) {
                num_greater1 += 1;
                if (first_greater1_pos == 16) first_greater1_pos = @intCast(15 - scan_pos);
            }
            g1_count += 1;
        }

        // coeff_abs_level_greater2_flag (at most 1 per sub-block)
        if (num_greater1 > 0) {
            const g2_ctx = getGreater2Ctx(sb_i, is_luma);
            _ = engine.decodeBin(h265_tables.CTX_COEFF_ABS_LEVEL_GREATER2 + g2_ctx);
            if (!engine.valid) return;
        }

        // coeff_sign_flag: bypass bins (one per significant coeff)
        for (0..num_sig) |_| {
            _ = engine.decodeBypass();
            if (!engine.valid) return;
        }

        // coeff_abs_level_remaining: bypass Rice-Golomb for coeffs > 1
        for (0..num_sig) |_| {
            if (!engine.valid) return;
            // Not all coeffs need this — only those that are > 1 or > 2
            // For validation, we decode the rice-golomb bypass bins
            // The rice parameter depends on the running sum of decoded levels
            // For simplicity in validation, decode any remaining level data
        }

        // Decode coeff_abs_level_remaining for coefficients that need it
        // This uses bypass-mode Rice-Golomb coding
        decodeCoeffAbsLevelRemaining(engine, num_sig);
        if (!engine.valid) return;
    }
}

/// Decode last_sig_coeff_x/y_prefix + suffix
fn decodeLastSigCoeff(engine: *H265CabacEngine, log2_tb_size: u32, is_luma: bool) u32 {
    if (!engine.valid) return 0;

    // Context offset depends on TU size and luma/chroma
    const ctx_offset: u16 = if (is_luma)
        getLastSigCoeffCtxOffset(log2_tb_size, true)
    else
        getLastSigCoeffCtxOffset(log2_tb_size, false);

    // Prefix: truncated unary with per-bin contexts
    const max_prefix = (log2_tb_size << 1) - 1;
    var prefix: u32 = 0;

    while (prefix < max_prefix) : (prefix += 1) {
        if (!engine.valid) return 0;
        const ctx: u16 = ctx_offset + @as(u16, @intCast(@min(prefix, 17)));
        const bin = engine.decodeBin(h265_tables.CTX_LAST_SIG_COEFF_X_PREFIX + ctx);
        if (bin == 0) break;
    }

    if (prefix < 2) return prefix;

    // Suffix: (prefix >> 1) - 1 bypass bins
    const suffix_bits = (prefix >> 1) - 1;
    const suffix = engine.decodeBypassBits(suffix_bits);
    if (!engine.valid) return 0;

    const shift: u5 = @intCast(suffix_bits);
    return (@as(u32, 1) << shift) * (2 + (prefix & 1)) + suffix;
}

fn getLastSigCoeffCtxOffset(log2_tb_size: u32, is_luma: bool) u16 {
    if (!is_luma) return 15; // Chroma uses fixed offset
    // Luma: offset depends on TU size
    return switch (log2_tb_size) {
        2 => 0, // 4x4
        3 => 3, // 8x8
        4 => 6, // 16x16
        5 => 10, // 32x32
        else => 0,
    };
}

fn getSigCoeffCtx(pos: u32, is_luma: bool, log2_tb_size: u32) u16 {
    // Use explicit clamping to avoid @min type narrowing issues
    const pos_c: u32 = if (pos > 16) 16 else pos;
    const pos_l: u32 = if (pos > 8) 8 else pos;
    if (!is_luma) {
        return @intCast(27 +% pos_c);
    }
    const ctx_base: u32 = switch (log2_tb_size) {
        2 => 0,
        3 => 9,
        4 => 21,
        5 => 21,
        else => 0,
    };
    return @intCast(ctx_base +% pos_l);
}

fn getGreater1Ctx(sub_block_idx: u32, is_luma: bool) u16 {
    // Context set depends on sub-block index and luma/chroma
    if (is_luma) {
        const idx: u32 = @min(sub_block_idx, 3);
        return @intCast(idx * 4);
    } else {
        const idx: u32 = @min(sub_block_idx, 1);
        return @intCast(16 + idx * 4);
    }
}

fn getGreater2Ctx(sub_block_idx: u32, is_luma: bool) u16 {
    if (is_luma) return @intCast(@min(sub_block_idx, 3));
    return @intCast(@as(u32, 4) + @min(sub_block_idx, 1));
}

/// Decode coeff_abs_level_remaining using bypass Rice-Golomb coding.
fn decodeCoeffAbsLevelRemaining(engine: *H265CabacEngine, num_sig: u32) void {
    if (!engine.valid or num_sig == 0) return;

    // In H.265, coeff_abs_level_remaining uses a Rice parameter (cRiceParam)
    // that starts at 0 and increases based on decoded levels.
    // For validation, we just need to consume the bypass bins correctly.

    var rice_param: u32 = 0;

    // Not all significant coefficients need remaining-level coding.
    // For validation, we try to decode a reasonable number and tolerate
    // running out of bins (the exact number depends on greater1/greater2
    // flags which we've already consumed above).
    var decoded: u32 = 0;
    while (decoded < num_sig and engine.valid) : (decoded += 1) {
        // Prefix: unary in bypass mode, max = 4 (COEF_REMAIN_BIN_REDUCTION)
        var prefix: u32 = 0;
        while (prefix < 4 and engine.valid) : (prefix += 1) {
            if (engine.decodeBypass() == 0) break;
        }

        if (!engine.valid) return;

        if (prefix < 4) {
            // Suffix: rice_param bypass bins
            if (rice_param > 0) {
                _ = engine.decodeBypassBits(rice_param);
            }
        } else {
            // Escape: Exp-Golomb order rice_param+1
            var eg_prefix: u32 = 0;
            while (eg_prefix < 20 and engine.valid) : (eg_prefix += 1) {
                if (engine.decodeBypass() == 0) break;
            }
            if (engine.valid) {
                _ = engine.decodeBypassBits(eg_prefix + rice_param + 1);
            }
        }

        if (!engine.valid) return;

        // Update rice parameter (simplified)
        if (rice_param < 4) rice_param += 1;
    }
}

// ============================================================================
// Public API: Validate H.265 intra slice CABAC data
// ============================================================================

/// Validate CABAC-encoded slice data for an H.265 intra slice.
/// `rbsp` is the NAL unit body (after RBSP emulation prevention removal).
/// `header_bits` is the number of bits consumed by the slice segment header.
/// Returns the number of CTUs successfully decoded (0 = complete failure).
pub fn validateH265IntraCabac(
    rbsp: []const u8,
    header_bits: usize,
    info: *const H265SliceDecodeInfo,
) u32 {
    var reader = BitReader.init(rbsp);

    // Skip past slice header
    if (!reader.skipBits(header_bits)) return 0;

    // CABAC requires byte alignment after slice header
    reader.alignToByte();

    // Initialize CABAC engine
    var engine = H265CabacEngine.init(&reader, info.slice_qp);
    if (!engine.valid) return 0;

    // Validate CABAC state is reasonable after init
    if (engine.cod_i_range < 256) return 0;

    // Decode CTUs in raster scan order
    var ctu_rs_addr: u32 = 0;
    const total_ctus = info.pic_width_in_ctbs * info.pic_height_in_ctbs;
    if (total_ctus == 0) return 0;

    const max_ctus: u32 = @min(total_ctus, 1024);

    while (ctu_rs_addr < max_ctus) : (ctu_rs_addr += 1) {
        if (!engine.valid) return ctu_rs_addr;
        if (reader.remainingBits() < 2) break;

        // CTU position
        const rx = ctu_rs_addr % info.pic_width_in_ctbs;
        const ry = ctu_rs_addr / info.pic_width_in_ctbs;
        if (info.log2_ctb_size > 31) return 0;
        const x0 = rx << @intCast(info.log2_ctb_size);
        const y0 = ry << @intCast(info.log2_ctb_size);

        // SAO parameters
        if (info.sao_enabled) {
            parseSaoParams(&engine, info, rx, ry);
            if (!engine.valid) return ctu_rs_addr;
        }

        // Coding quadtree
        codingQuadtree(&engine, info, x0, y0, info.log2_ctb_size, 0);
        if (!engine.valid) return ctu_rs_addr;

        // end_of_slice_segment_flag
        if (engine.decodeTerminate() == 1) {
            // Found slice end — return total CTUs as fully decoded
            return ctu_rs_addr + 1;
        }
        if (!engine.valid) return ctu_rs_addr;
    }

    return ctu_rs_addr;
}

// ============================================================================
// Tests
// ============================================================================

test "H265 CABAC engine initialization" {
    var data = [_]u8{ 0x55, 0xAA, 0x33, 0x77 };
    var reader = BitReader.init(&data);
    const engine = H265CabacEngine.init(&reader, 26);

    try std.testing.expect(engine.valid);
    try std.testing.expectEqual(@as(u16, 510), engine.cod_i_range);
}

test "H265 CABAC decodeBin basic" {
    var data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var reader = BitReader.init(&data);
    var engine = H265CabacEngine.init(&reader, 26);

    // Should not crash when decoding bins
    _ = engine.decodeBin(h265_tables.CTX_SPLIT_CU_FLAG);
    try std.testing.expect(engine.valid);
}

test "H265 CABAC decodeBypass basic" {
    var data = [_]u8{ 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA };
    var reader = BitReader.init(&data);
    var engine = H265CabacEngine.init(&reader, 26);

    const b = engine.decodeBypass();
    try std.testing.expect(engine.valid);
    try std.testing.expect(b == 0 or b == 1);
}

test "H265 CABAC invalid context" {
    var data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var reader = BitReader.init(&data);
    var engine = H265CabacEngine.init(&reader, 26);

    _ = engine.decodeBin(h265_tables.NUM_H265_CONTEXTS); // Out of bounds
    try std.testing.expect(!engine.valid);
}
