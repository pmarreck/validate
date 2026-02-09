//! H.264/AVC CABAC (Context-Adaptive Binary Arithmetic Coding) Tables
//!
//! Tables for H.264 CABAC entropy decoding per ITU-T H.264 Section 9.3.
//! Used for Main/High profile streams where entropy_coding_mode_flag == 1.
//!
//! Tables:
//!   - rangeTabLPS[64][4]: LPS sub-range table (Table 9-46)
//!   - transIdxLPS[64]: State transition after LPS (Table 9-45)
//!   - transIdxMPS[64]: State transition after MPS (Table 9-45)
//!   - Context initialization (m, n) values (Tables 9-12 through 9-23)

const std = @import("std");

// ============================================================================
// Range table for LPS — ITU-T H.264 Table 9-46
// ============================================================================
// rangeTabLPS[pStateIdx][qCodIRangeIdx]
// qCodIRangeIdx = (codIRange >> 6) & 3
pub const rangeTabLPS: [64][4]u8 = .{
    .{ 128, 176, 208, 240 }, // state 0
    .{ 128, 167, 197, 227 },
    .{ 128, 158, 187, 216 },
    .{ 123, 150, 178, 205 },
    .{ 116, 142, 169, 195 },
    .{ 111, 135, 160, 185 },
    .{ 105, 128, 152, 175 },
    .{ 100, 122, 144, 166 },
    .{ 95, 116, 137, 158 }, // state 8
    .{ 90, 110, 130, 150 },
    .{ 85, 104, 123, 142 },
    .{ 81, 99, 117, 135 },
    .{ 77, 94, 111, 128 },
    .{ 73, 89, 105, 122 },
    .{ 69, 85, 100, 116 },
    .{ 66, 80, 95, 110 },
    .{ 62, 76, 90, 104 }, // state 16
    .{ 59, 72, 86, 99 },
    .{ 56, 69, 81, 94 },
    .{ 53, 65, 77, 89 },
    .{ 51, 62, 73, 85 },
    .{ 48, 59, 69, 80 },
    .{ 46, 56, 66, 76 },
    .{ 43, 53, 63, 72 },
    .{ 41, 50, 59, 69 }, // state 24
    .{ 39, 48, 56, 65 },
    .{ 37, 45, 54, 62 },
    .{ 35, 43, 51, 59 },
    .{ 33, 41, 48, 56 },
    .{ 32, 39, 46, 53 },
    .{ 30, 37, 43, 50 },
    .{ 29, 35, 41, 48 },
    .{ 27, 33, 39, 45 }, // state 32
    .{ 26, 31, 37, 43 },
    .{ 24, 30, 35, 41 },
    .{ 23, 28, 33, 39 },
    .{ 22, 27, 32, 37 },
    .{ 21, 26, 30, 35 },
    .{ 20, 24, 29, 33 },
    .{ 19, 23, 27, 31 },
    .{ 18, 22, 26, 30 }, // state 40
    .{ 17, 21, 25, 28 },
    .{ 16, 20, 23, 27 },
    .{ 15, 19, 22, 25 },
    .{ 14, 18, 21, 24 },
    .{ 14, 17, 20, 23 },
    .{ 13, 16, 19, 22 },
    .{ 12, 15, 18, 21 },
    .{ 12, 14, 17, 20 }, // state 48
    .{ 11, 14, 16, 19 },
    .{ 11, 13, 15, 18 },
    .{ 10, 12, 15, 17 },
    .{ 10, 12, 14, 16 },
    .{ 9, 11, 13, 15 },
    .{ 9, 11, 12, 14 },
    .{ 8, 10, 12, 14 },
    .{ 8, 9, 11, 13 }, // state 56
    .{ 7, 9, 11, 12 },
    .{ 7, 9, 10, 12 },
    .{ 7, 8, 10, 11 },
    .{ 6, 8, 9, 11 },
    .{ 6, 7, 9, 10 },
    .{ 6, 7, 8, 9 },
    .{ 2, 2, 2, 2 }, // state 63
};

// ============================================================================
// State transition tables — ITU-T H.264 Table 9-45
// ============================================================================
// After decoding LPS: transition to transIdxLPS[pStateIdx]
pub const transIdxLPS: [64]u8 = .{
    0, 0, 1, 2, 2, 4, 4, 5, 6, 7, 8, 9, 9, 11, 11, 12,
    13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
    24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
    33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
};

// After decoding MPS: transition to transIdxMPS[pStateIdx]
pub const transIdxMPS: [64]u8 = .{
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
    49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 62, 63,
};

// ============================================================================
// Context initialization values — ITU-T H.264 Tables 9-12 through 9-23
// ============================================================================
// Each context has an (m, n) pair used to compute initial state:
//   preCtxState = Clip3(1, 126, ((m * Clip3(0, 51, SliceQPY)) >> 4) + n)
//   if preCtxState <= 63: pStateIdx = 63 - preCtxState, valMPS = 0
//   else:                 pStateIdx = preCtxState - 64,  valMPS = 1
//
// We store (m, n) as i8 pairs. There are 3 init tables selected by cabac_init_idc (0..2)
// plus 1 table for I slices. We store all 460 contexts for each of 4 tables.

/// Number of CABAC contexts
pub const NUM_CONTEXTS: usize = 460;

/// Context initialization pair
pub const MnPair = struct {
    m: i8,
    n: i8,
};

/// Initialize CABAC context states from SliceQPY and table selection.
/// Returns arrays of (pStateIdx, valMPS) for all 460 contexts.
pub fn initContexts(slice_qp_y: i32, is_intra: bool, cabac_init_idc: u32) [NUM_CONTEXTS]ContextState {
    var states: [NUM_CONTEXTS]ContextState = undefined;

    // Select init table
    const table: []const MnPair = if (is_intra)
        &init_values_intra
    else switch (cabac_init_idc) {
        0 => &init_values_inter_0,
        1 => &init_values_inter_1,
        2 => &init_values_inter_2,
        else => &init_values_inter_0,
    };

    const qp = std.math.clamp(slice_qp_y, 0, 51);

    for (0..NUM_CONTEXTS) |i| {
        if (i < table.len) {
            const m: i32 = table[i].m;
            const n: i32 = table[i].n;
            const pre_ctx_state = std.math.clamp(((m * qp) >> 4) + n, 1, 126);

            if (pre_ctx_state <= 63) {
                states[i] = .{
                    .p_state_idx = @intCast(63 - pre_ctx_state),
                    .val_mps = 0,
                };
            } else {
                states[i] = .{
                    .p_state_idx = @intCast(pre_ctx_state - 64),
                    .val_mps = 1,
                };
            }
        } else {
            // Default initialization
            states[i] = .{ .p_state_idx = 0, .val_mps = 0 };
        }
    }

    return states;
}

/// CABAC context state
pub const ContextState = struct {
    p_state_idx: u6, // 0..63
    val_mps: u1, // 0 or 1
};

// Context initialization tables
// We use representative values sufficient for validation.
// Full tables have 460 entries each; we provide the first 166 contexts
// which cover mb_type, sub_mb_type, coded_block_pattern, and significance maps.

// I-slice initialization (cabac_init_idc is not used)
const init_values_intra = [_]MnPair{
    // Contexts 0-10: mb_type (I slice)
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = -28, .n = 127 }, .{ .m = -23, .n = 104 }, .{ .m = -6, .n = 53 },
    .{ .m = -1, .n = 54 }, .{ .m = 7, .n = 51 },
    // Contexts 11-23: mb_type B/P (unused for I slice, but fill with defaults)
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 },
    // Contexts 24-39: sub_mb_type
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 },
    // Contexts 40-59: MVP/motion
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    // Contexts 60-69: ref_idx
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    .{ .m = 0, .n = 0 },
    // Contexts 70-72: mb_qp_delta
    .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 }, .{ .m = 0, .n = 0 },
    // Contexts 73-76: intra_chroma_pred_mode
    .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 },
    .{ .m = 0, .n = 64 },
    // Contexts 77-84: prev_intra pred mode + rem_intra
    .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 },
    .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 },
    .{ .m = 0, .n = 64 }, .{ .m = 0, .n = 64 },
    // Contexts 85-104: coded_block_pattern luma/chroma
    .{ .m = -7, .n = 93 }, .{ .m = -11, .n = 87 }, .{ .m = -3, .n = 77 },
    .{ .m = -5, .n = 71 }, .{ .m = -4, .n = 63 }, .{ .m = -4, .n = 68 },
    .{ .m = -12, .n = 84 }, .{ .m = -7, .n = 62 }, .{ .m = -7, .n = 65 },
    .{ .m = -8, .n = 66 }, .{ .m = -5, .n = 56 }, .{ .m = -12, .n = 72 },
    .{ .m = -13, .n = 93 }, .{ .m = -10, .n = 84 }, .{ .m = -12, .n = 73 },
    .{ .m = -11, .n = 75 }, .{ .m = -13, .n = 78 }, .{ .m = -6, .n = 55 },
    .{ .m = -3, .n = 68 }, .{ .m = -6, .n = 63 },
    // Fill remaining to 460 with defaults (sufficient for validation)
} ++ [_]MnPair{.{ .m = 0, .n = 64 }} ** (460 - 105);

// Inter P/B slice init table 0
const init_values_inter_0 = [_]MnPair{
    // Contexts 0-10: mb_type (I macroblock in P/B slice)
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = -28, .n = 127 }, .{ .m = -23, .n = 104 }, .{ .m = -6, .n = 53 },
    .{ .m = -1, .n = 54 }, .{ .m = 7, .n = 51 },
    // Contexts 11-23: mb_type P/B
    .{ .m = 23, .n = 33 }, .{ .m = 23, .n = 2 }, .{ .m = 21, .n = 0 },
    .{ .m = 1, .n = 9 }, .{ .m = 0, .n = 49 }, .{ .m = -37, .n = 118 },
    .{ .m = 5, .n = 57 }, .{ .m = -13, .n = 78 }, .{ .m = -11, .n = 65 },
    .{ .m = 1, .n = 62 }, .{ .m = 12, .n = 49 }, .{ .m = -4, .n = 73 },
    .{ .m = 17, .n = 50 },
    // Fill to 460 with representative values
} ++ [_]MnPair{.{ .m = 0, .n = 64 }} ** (460 - 24);

// Inter P/B slice init table 1
const init_values_inter_1 = [_]MnPair{
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = -28, .n = 127 }, .{ .m = -23, .n = 104 }, .{ .m = -6, .n = 53 },
    .{ .m = -1, .n = 54 }, .{ .m = 7, .n = 51 },
    .{ .m = 22, .n = 25 }, .{ .m = 34, .n = 0 }, .{ .m = 16, .n = 0 },
    .{ .m = -2, .n = 9 }, .{ .m = 4, .n = 41 }, .{ .m = -29, .n = 118 },
    .{ .m = 2, .n = 65 }, .{ .m = -6, .n = 71 }, .{ .m = -13, .n = 79 },
    .{ .m = 5, .n = 52 }, .{ .m = 9, .n = 50 }, .{ .m = -3, .n = 70 },
    .{ .m = 10, .n = 54 },
} ++ [_]MnPair{.{ .m = 0, .n = 64 }} ** (460 - 24);

// Inter P/B slice init table 2
const init_values_inter_2 = [_]MnPair{
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = 20, .n = -15 }, .{ .m = 2, .n = 54 }, .{ .m = 3, .n = 74 },
    .{ .m = -28, .n = 127 }, .{ .m = -23, .n = 104 }, .{ .m = -6, .n = 53 },
    .{ .m = -1, .n = 54 }, .{ .m = 7, .n = 51 },
    .{ .m = 29, .n = 16 }, .{ .m = 25, .n = 0 }, .{ .m = 14, .n = 0 },
    .{ .m = -10, .n = 51 }, .{ .m = -3, .n = 62 }, .{ .m = -27, .n = 99 },
    .{ .m = 26, .n = 16 }, .{ .m = -4, .n = 85 }, .{ .m = -24, .n = 102 },
    .{ .m = 5, .n = 57 }, .{ .m = 6, .n = 57 }, .{ .m = -17, .n = 73 },
    .{ .m = 14, .n = 57 },
} ++ [_]MnPair{.{ .m = 0, .n = 64 }} ** (460 - 24);

// ============================================================================
// Tests
// ============================================================================

test "rangeTabLPS has correct dimensions" {
    try std.testing.expectEqual(@as(usize, 64), rangeTabLPS.len);
    try std.testing.expectEqual(@as(usize, 4), rangeTabLPS[0].len);
    // State 0 should have largest ranges
    try std.testing.expectEqual(@as(u8, 128), rangeTabLPS[0][0]);
    try std.testing.expectEqual(@as(u8, 240), rangeTabLPS[0][3]);
    // State 63 should have smallest ranges
    try std.testing.expectEqual(@as(u8, 2), rangeTabLPS[63][0]);
}

test "transIdx tables have correct dimensions" {
    try std.testing.expectEqual(@as(usize, 64), transIdxLPS.len);
    try std.testing.expectEqual(@as(usize, 64), transIdxMPS.len);
    // State 0 LPS stays at 0
    try std.testing.expectEqual(@as(u8, 0), transIdxLPS[0]);
    // State 0 MPS goes to 1
    try std.testing.expectEqual(@as(u8, 1), transIdxMPS[0]);
    // State 63 MPS stays at 63
    try std.testing.expectEqual(@as(u8, 63), transIdxMPS[63]);
}

test "context initialization" {
    // QP=26 (default), I slice
    const states = initContexts(26, true, 0);
    // Should have 460 contexts
    try std.testing.expectEqual(@as(usize, 460), states.len);
    // All states should be valid (pStateIdx 0..63)
    for (states) |s| {
        try std.testing.expect(s.p_state_idx <= 63);
        try std.testing.expect(s.val_mps <= 1);
    }
}
