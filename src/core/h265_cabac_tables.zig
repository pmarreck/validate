//! H.265/HEVC CABAC Context Initialization Tables
//!
//! Context model initialization values for H.265 CABAC per ITU-T H.265
//! Section 9.3.2.2. The arithmetic engine (rangeTabLPS, state transitions)
//! is identical to H.264 and is imported from h264_cabac_tables.
//!
//! Init values encode slope (m) and offset (n):
//!   m = ((initValue >> 4) * 5) - 45
//!   n = ((initValue & 15) << 3) - 16
//!   preCtxState = clip(1, 126, (m * QP) >> 4 + n)
//!
//! Reference: ITU-T H.265 Tables 9-5 through 9-37, HM reference software.

const std = @import("std");
const h264_tables = @import("h264_cabac_tables.zig");

// Re-export shared arithmetic tables (identical between H.264 and H.265)
pub const rangeTabLPS = h264_tables.rangeTabLPS;
pub const transIdxLPS = h264_tables.transIdxLPS;
pub const transIdxMPS = h264_tables.transIdxMPS;

// Context Not Used sentinel
const CNU: u8 = 154;

// ============================================================================
// Context index offsets for each syntax element
// ============================================================================

// Group 0: Non-residual contexts
pub const CTX_SAO_MERGE_FLAG: u16 = 0; // 1 context
pub const CTX_SAO_TYPE_IDX: u16 = 1; // 1 context
pub const CTX_SPLIT_CU_FLAG: u16 = 2; // 3 contexts
pub const CTX_CU_TRANSQUANT_BYPASS: u16 = 5; // 1 context
pub const CTX_CU_SKIP_FLAG: u16 = 6; // 3 contexts
pub const CTX_PRED_MODE_FLAG: u16 = 9; // 1 context
pub const CTX_PART_MODE: u16 = 10; // 4 contexts
pub const CTX_PREV_INTRA_LUMA_PRED: u16 = 14; // 1 context
pub const CTX_INTRA_CHROMA_PRED_MODE: u16 = 15; // 1 context
pub const CTX_RQT_ROOT_CBF: u16 = 16; // 1 context
pub const CTX_MERGE_FLAG: u16 = 17; // 1 context
pub const CTX_MERGE_IDX: u16 = 18; // 1 context
pub const CTX_INTER_DIR: u16 = 19; // 5 contexts
pub const CTX_REF_PIC: u16 = 24; // 2 contexts
pub const CTX_MVP_FLAG: u16 = 26; // 1 context
pub const CTX_SPLIT_TRANSFORM_FLAG: u16 = 27; // 3 contexts
pub const CTX_CBF_LUMA: u16 = 30; // 2 contexts
pub const CTX_CBF_CHROMA: u16 = 32; // 5 contexts
pub const CTX_ABS_MVD_GT0: u16 = 37; // 1 context
pub const CTX_ABS_MVD_GT1: u16 = 38; // 1 context
pub const CTX_CU_QP_DELTA_ABS: u16 = 39; // 2 contexts
pub const CTX_CU_CHROMA_QP_OFFSET: u16 = 41; // 1 context
pub const CTX_TRANSFORM_SKIP_FLAG: u16 = 42; // 2 contexts
pub const CTX_EXPLICIT_RDPCM_FLAG: u16 = 44; // 2 contexts
pub const CTX_EXPLICIT_RDPCM_DIR: u16 = 46; // 2 contexts
pub const NUM_NON_RESIDUAL_CONTEXTS: u16 = 48;

// Group 1: Residual coding contexts (separate offset space)
pub const CTX_LAST_SIG_COEFF_X_PREFIX: u16 = NUM_NON_RESIDUAL_CONTEXTS + 0; // 18 contexts
pub const CTX_LAST_SIG_COEFF_Y_PREFIX: u16 = NUM_NON_RESIDUAL_CONTEXTS + 18; // 18 contexts
pub const CTX_CODED_SUB_BLOCK_FLAG: u16 = NUM_NON_RESIDUAL_CONTEXTS + 36; // 4 contexts
pub const CTX_SIG_COEFF_FLAG: u16 = NUM_NON_RESIDUAL_CONTEXTS + 40; // 44 contexts
pub const CTX_COEFF_ABS_LEVEL_GREATER1: u16 = NUM_NON_RESIDUAL_CONTEXTS + 84; // 24 contexts
pub const CTX_COEFF_ABS_LEVEL_GREATER2: u16 = NUM_NON_RESIDUAL_CONTEXTS + 108; // 6 contexts

pub const NUM_H265_CONTEXTS: u16 = NUM_NON_RESIDUAL_CONTEXTS + 114;

// ============================================================================
// Context initialization values for I-slice (initType = 0)
// From ITU-T H.265 Tables 9-5 through 9-37 / HM reference software
// ============================================================================

const init_values_i_slice: [NUM_H265_CONTEXTS]u8 = blk: {
    var vals: [NUM_H265_CONTEXTS]u8 = [_]u8{CNU} ** NUM_H265_CONTEXTS;

    // Table 9-5: sao_merge_flag
    vals[CTX_SAO_MERGE_FLAG] = 153;

    // Table 9-6: sao_type_idx
    vals[CTX_SAO_TYPE_IDX] = 200;

    // Table 9-7: split_cu_flag
    vals[CTX_SPLIT_CU_FLAG + 0] = 139;
    vals[CTX_SPLIT_CU_FLAG + 1] = 141;
    vals[CTX_SPLIT_CU_FLAG + 2] = 157;

    // Table 9-8: cu_transquant_bypass_flag
    vals[CTX_CU_TRANSQUANT_BYPASS] = 154;

    // Table 9-9: cu_skip_flag (CNU for I-slice)
    // Already CNU

    // Table 9-10: pred_mode_flag
    vals[CTX_PRED_MODE_FLAG] = 149;

    // Table 9-11: part_mode (only first context used for I-slice 2Nx2N vs NxN)
    vals[CTX_PART_MODE + 0] = 184;

    // Table 9-12: prev_intra_luma_pred_flag
    vals[CTX_PREV_INTRA_LUMA_PRED] = 184;

    // Table 9-13: intra_chroma_pred_mode
    vals[CTX_INTRA_CHROMA_PRED_MODE] = 63;

    // Table 9-14: rqt_root_cbf
    vals[CTX_RQT_ROOT_CBF] = 79;

    // Table 9-18: split_transform_flag
    vals[CTX_SPLIT_TRANSFORM_FLAG + 0] = 153;
    vals[CTX_SPLIT_TRANSFORM_FLAG + 1] = 138;
    vals[CTX_SPLIT_TRANSFORM_FLAG + 2] = 138;

    // Table 9-19: cbf_luma
    vals[CTX_CBF_LUMA + 0] = 111;
    vals[CTX_CBF_LUMA + 1] = 141;

    // Table 9-20: cbf_cb, cbf_cr
    vals[CTX_CBF_CHROMA + 0] = 94;
    vals[CTX_CBF_CHROMA + 1] = 138;
    vals[CTX_CBF_CHROMA + 2] = 182;
    vals[CTX_CBF_CHROMA + 3] = 154;
    vals[CTX_CBF_CHROMA + 4] = 154;

    // Table 9-23: cu_qp_delta_abs
    vals[CTX_CU_QP_DELTA_ABS + 0] = 154;
    vals[CTX_CU_QP_DELTA_ABS + 1] = 154;

    // Table 9-24: cu_chroma_qp_offset
    vals[CTX_CU_CHROMA_QP_OFFSET] = 154;

    // Table 9-25: transform_skip_flag
    vals[CTX_TRANSFORM_SKIP_FLAG + 0] = 139;
    vals[CTX_TRANSFORM_SKIP_FLAG + 1] = 139;

    // ---- Residual coding contexts ----

    // Table 9-28: last_sig_coeff_x_prefix (I-slice)
    const last_x_init = [18]u8{ 110, 110, 124, 110, 140, 111, 125, 111, 127, 111, 111, 111, 108, 111, CNU, CNU, CNU, CNU };
    for (last_x_init, 0..) |v, j| {
        vals[CTX_LAST_SIG_COEFF_X_PREFIX + j] = v;
    }

    // Table 9-29: last_sig_coeff_y_prefix (same as X for I-slice)
    const last_y_init = [18]u8{ 110, 110, 124, 110, 140, 111, 125, 111, 127, 111, 111, 111, 108, 111, CNU, CNU, CNU, CNU };
    for (last_y_init, 0..) |v, j| {
        vals[CTX_LAST_SIG_COEFF_Y_PREFIX + j] = v;
    }

    // Table 9-30: coded_sub_block_flag (2 luma + 2 chroma)
    vals[CTX_CODED_SUB_BLOCK_FLAG + 0] = 91;
    vals[CTX_CODED_SUB_BLOCK_FLAG + 1] = 171;
    vals[CTX_CODED_SUB_BLOCK_FLAG + 2] = 134;
    vals[CTX_CODED_SUB_BLOCK_FLAG + 3] = 141;

    // Table 9-31: sig_coeff_flag (27 luma + 17 chroma = 44)
    const sig_luma_init = [27]u8{
        111, 111, 125, 110, 110, 94, 124, 108, 124,
        107, 125, 141, 179, 153, 125, 107, 125, 141,
        179, 153, 125, 107, 125, 141, 179, 153, 125,
    };
    for (sig_luma_init, 0..) |v, j| {
        vals[CTX_SIG_COEFF_FLAG + j] = v;
    }
    const sig_chroma_init = [17]u8{
        170, 154, 139, 153, 139, 123, 123, 63, 124,
        166, 183, 140, 136, 153, 154, 166, 183,
    };
    for (sig_chroma_init, 0..) |v, j| {
        vals[CTX_SIG_COEFF_FLAG + 27 + j] = v;
    }

    // Table 9-32: coeff_abs_level_greater1_flag (24 contexts)
    const greater1_init = [24]u8{
        140, 92, 137, 138, 140, 152, 138, 139, 153, 74, 149, 92,
        139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197,
    };
    for (greater1_init, 0..) |v, j| {
        vals[CTX_COEFF_ABS_LEVEL_GREATER1 + j] = v;
    }

    // Table 9-33: coeff_abs_level_greater2_flag (6 contexts)
    const greater2_init = [6]u8{ 138, 153, 136, 167, 152, 152 };
    for (greater2_init, 0..) |v, j| {
        vals[CTX_COEFF_ABS_LEVEL_GREATER2 + j] = v;
    }

    break :blk vals;
};

// ============================================================================
// Context state (same structure as H.264)
// ============================================================================

pub const ContextState = struct {
    p_state_idx: u6, // probability state index (0..63)
    val_mps: u1, // most probable symbol (0 or 1)
};

/// Initialize all H.265 context models for a given slice QP and type.
pub fn initContexts(slice_qp: i32, is_i_slice: bool) [NUM_H265_CONTEXTS]ContextState {
    var contexts: [NUM_H265_CONTEXTS]ContextState = undefined;

    const init_values = if (is_i_slice) init_values_i_slice else init_values_i_slice; // TODO: P/B slice init values

    const qp = std.math.clamp(slice_qp, 0, 51);

    for (init_values, 0..) |init_value, i| {
        // Derive slope (m) and offset (n) from init value
        const m: i32 = @as(i32, init_value >> 4) * 5 - 45;
        const n: i32 = (@as(i32, init_value & 15) << 3) - 16;

        // Compute initial probability state
        const pre_ctx_state = std.math.clamp(((m * qp) >> 4) + n, 1, 126);

        if (pre_ctx_state <= 63) {
            contexts[i] = .{
                .p_state_idx = @intCast(63 - pre_ctx_state),
                .val_mps = 0,
            };
        } else {
            contexts[i] = .{
                .p_state_idx = @intCast(pre_ctx_state - 64),
                .val_mps = 1,
            };
        }
    }

    return contexts;
}

// ============================================================================
// Tests
// ============================================================================

test "H.265 context init values array size" {
    try std.testing.expectEqual(@as(u16, 162), NUM_H265_CONTEXTS);
}

test "H.265 context initialization produces valid states" {
    // QP 26 is a common default
    const contexts = initContexts(26, true);

    for (contexts) |ctx| {
        try std.testing.expect(ctx.p_state_idx < 64);
        try std.testing.expect(ctx.val_mps <= 1);
    }
}

test "H.265 context init edge cases" {
    // QP 0
    const ctx_0 = initContexts(0, true);
    for (ctx_0) |ctx| {
        try std.testing.expect(ctx.p_state_idx < 64);
    }

    // QP 51
    const ctx_51 = initContexts(51, true);
    for (ctx_51) |ctx| {
        try std.testing.expect(ctx.p_state_idx < 64);
    }
}

test "H.265 shared tables match H.264" {
    // rangeTabLPS should be identical
    try std.testing.expectEqual(h264_tables.rangeTabLPS[0][0], rangeTabLPS[0][0]);
    try std.testing.expectEqual(h264_tables.rangeTabLPS[63][3], rangeTabLPS[63][3]);
    try std.testing.expectEqual(h264_tables.transIdxLPS[0], transIdxLPS[0]);
    try std.testing.expectEqual(h264_tables.transIdxMPS[0], transIdxMPS[0]);
}
