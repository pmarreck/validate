//! H.265/HEVC CABAC Slice Data Decoder (Intra-Only, Spec-Perfect)
//!
//! Decodes CABAC-encoded slice data for H.265 intra slices per ITU-T H.265.
//! Every syntax element, context derivation, and scan order matches the spec
//! exactly — ensuring that corruption anywhere in the bitstream is detected.
//!
//! Reference: ITU-T H.265, Sections 7.3.8 through 7.3.8.11, 9.3.

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const h265_tables = @import("h265_cabac_tables.zig");
const codec_utils = @import("codec_utils.zig");
const trace = @import("trace.zig");
const heap = @import("heap.zig");
const runtime = @import("runtime.zig");

// ============================================================================
// Scan Order Tables (ITU-T H.265 Section 6.5.3)
// ============================================================================

/// Diagonal scan order for 4x4 blocks (16 positions).
/// Each entry is (x, y) in the 4x4 block. Scan goes bottom-left to top-right
/// along anti-diagonals.
const diag_scan_4x4: [16][2]u8 = .{
    .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 2, 0 },
    .{ 1, 1 }, .{ 0, 2 }, .{ 3, 0 }, .{ 2, 1 },
    .{ 1, 2 }, .{ 0, 3 }, .{ 3, 1 }, .{ 2, 2 },
    .{ 1, 3 }, .{ 3, 2 }, .{ 2, 3 }, .{ 3, 3 },
};

/// Horizontal scan order for 4x4 blocks (raster row-major).
/// Per H.265 spec section 6.5.4 — used when intra prediction mode is
/// horizontal-ish (modes 22-30, with log2_trafo_size < 4).
const horiz_scan_4x4: [16][2]u8 = .{
    .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 },
    .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 }, .{ 3, 1 },
    .{ 0, 2 }, .{ 1, 2 }, .{ 2, 2 }, .{ 3, 2 },
    .{ 0, 3 }, .{ 1, 3 }, .{ 2, 3 }, .{ 3, 3 },
};

/// Vertical scan order for 4x4 blocks (column-major).
/// Per H.265 spec section 6.5.5 — used when intra prediction mode is
/// vertical-ish (modes 6-14, with log2_trafo_size < 4).
const vert_scan_4x4: [16][2]u8 = .{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 },
    .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 1, 3 },
    .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 2, 3 },
    .{ 3, 0 }, .{ 3, 1 }, .{ 3, 2 }, .{ 3, 3 },
};

/// Horizontal sub-block scan for 2x2 sub-block arrays (used in 8x8 TBs).
const horiz_scan_2x2: [4][2]u8 = .{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };

/// Vertical sub-block scan for 2x2 sub-block arrays.
const vert_scan_2x2: [4][2]u8 = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } };

/// HEVC intra prediction mode constants (spec section 8.4.2).
const INTRA_PLANAR: u8 = 0;
const INTRA_DC: u8 = 1;
const INTRA_ANGULAR_2: u8 = 2;
const INTRA_ANGULAR_10: u8 = 10;
const INTRA_ANGULAR_26: u8 = 26;
const INTRA_ANGULAR_34: u8 = 34;

/// Scan type for residual_coding — picked per TU based on intra mode + size.
/// Per spec section 8.4.4.2.7: pred_mode==INTRA AND log2_trafo_size < 4 →
/// scan picks based on intra_pred_mode range. Otherwise always DIAG.
const ScanType = enum { diag, horiz, vert };

fn deriveScanIdx(intra_pred_mode: u8, log2_tb_size: u32) ScanType {
    if (log2_tb_size >= 4) return .diag;
    if (intra_pred_mode >= 6 and intra_pred_mode <= 14) return .vert;
    if (intra_pred_mode >= 22 and intra_pred_mode <= 30) return .horiz;
    return .diag;
}

/// Diagonal scan order for 8x8 sub-blocks within TBs.
/// Used for sub-block iteration in 16x16 and 32x32 TBs.
const diag_scan_2x2: [4][2]u8 = .{
    .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 },
};

const diag_scan_4x4_sb: [16][2]u8 = .{
    .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 2, 0 },
    .{ 1, 1 }, .{ 0, 2 }, .{ 3, 0 }, .{ 2, 1 },
    .{ 1, 2 }, .{ 0, 3 }, .{ 3, 1 }, .{ 2, 2 },
    .{ 1, 3 }, .{ 3, 2 }, .{ 2, 3 }, .{ 3, 3 },
};

const diag_scan_8x8_sb: [64][2]u8 = blk: {
    var table: [64][2]u8 = undefined;
    var idx: usize = 0;
    var diag: u8 = 0;
    while (diag < 15) : (diag += 1) {
        var y: u8 = if (diag < 8) 0 else diag - 7;
        while (y <= diag and y < 8) : (y += 1) {
            const x = diag - y;
            if (x < 8) {
                table[idx] = .{ x, y };
                idx += 1;
            }
        }
    }
    break :blk table;
};

// Spec-correct sig_coeff_flag context map per H.265 Table 9-19, mirrored
// from ffmpeg libavcodec/hevc/cabac.c:1226 (vendored in
// docs/hevc-reference/ffmpeg-hevc-cabac.c). 5 sections of 16 entries
// each, indexed by (y_local * 4 + x_local) within the 4x4 sub-block:
//   Section 0 (offset  0): 4x4 TB position lookup
//   Section 1 (offset 16): non-4x4 TB with prev_sig == 0
//   Section 2 (offset 32): non-4x4 TB with prev_sig == 1
//   Section 3 (offset 48): non-4x4 TB with prev_sig == 2
//   Section 4 (offset 64): non-4x4 TB with prev_sig == 3 (default)
const sig_ctx_idx_map = [80]u8{
    0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8,
    1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
};

/// Per-slice mutable context: depth + intra-mode maps that codingQuadtree /
/// codingUnit / transformUnit / residualCoding all need to read and write
/// for spec-correct context derivation. Heap-allocated at slice entry in
/// validateH265IntraCabac; freed when validateH265IntraCabac returns.
///
/// Both maps are optional: alloc failure → null → callers fall back to the
/// pre-spec-correct approximation rather than break. Min PU size in HEVC is
/// always 4x4 (log2 = 2), so intra_mode_map is indexed at that granularity.
const SliceCtx = struct {
    // CU depth map per min-CB (Bug #4h)
    depth_map: ?[]u8,
    pic_w_min_cbs: u32,
    pic_h_min_cbs: u32,
    log2_min_cb: u5,

    // Intra LUMA prediction mode map per min-PU (Bug #4j). Stores u8 mode
    // value 0..34 (PLANAR / DC / ANGULAR_2..34). Initialized to INTRA_DC.
    intra_mode_map: ?[]u8,
    // Intra CHROMA prediction mode map per min-PU (Bug #4k). Stored at the
    // same granularity as luma so transformUnit can look up by TB top-left.
    // For 4:2:0 the chroma mode is uniform per CU; the storeChromaMode call
    // covers the whole CU area.
    chroma_mode_map: ?[]u8,
    pic_w_min_pus: u32,
    pic_h_min_pus: u32,

    // log2_ctb_size for "above neighbor in same CTB row?" intra MPM check
    log2_ctb: u5,

    fn lookupIntraMode(self: *const SliceCtx, x_pu: u32, y_pu: u32) u8 {
        if (self.intra_mode_map) |m| {
            if (x_pu >= self.pic_w_min_pus or y_pu >= self.pic_h_min_pus) return INTRA_DC;
            const idx = @as(usize, y_pu) * self.pic_w_min_pus + x_pu;
            if (idx < m.len) return m[idx];
        }
        return INTRA_DC;
    }

    fn lookupChromaMode(self: *const SliceCtx, x_pu: u32, y_pu: u32) u8 {
        if (self.chroma_mode_map) |m| {
            if (x_pu >= self.pic_w_min_pus or y_pu >= self.pic_h_min_pus) return INTRA_DC;
            const idx = @as(usize, y_pu) * self.pic_w_min_pus + x_pu;
            if (idx < m.len) return m[idx];
        }
        return INTRA_DC;
    }

    fn storeIntraMode(self: *SliceCtx, x_pu_start: u32, y_pu_start: u32, size_in_pus: u32, mode: u8) void {
        if (self.intra_mode_map) |m| {
            self.fillMap(m, x_pu_start, y_pu_start, size_in_pus, mode);
        }
    }

    fn storeChromaMode(self: *SliceCtx, x_pu_start: u32, y_pu_start: u32, size_in_pus: u32, mode: u8) void {
        if (self.chroma_mode_map) |m| {
            self.fillMap(m, x_pu_start, y_pu_start, size_in_pus, mode);
        }
    }

    fn fillMap(self: *SliceCtx, m: []u8, x_pu_start: u32, y_pu_start: u32, size_in_pus: u32, mode: u8) void {
        var dy: u32 = 0;
        while (dy < size_in_pus) : (dy += 1) {
            const yi = y_pu_start + dy;
            if (yi >= self.pic_h_min_pus) break;
            var dx: u32 = 0;
            while (dx < size_in_pus) : (dx += 1) {
                const xi = x_pu_start + dx;
                if (xi >= self.pic_w_min_pus) break;
                const idx = @as(usize, yi) * self.pic_w_min_pus + xi;
                if (idx < m.len) m[idx] = mode;
            }
        }
    }

    fn lookupDepth(self: *const SliceCtx, x_min_cb: u32, y_min_cb: u32) u8 {
        if (self.depth_map) |dm| {
            if (x_min_cb >= self.pic_w_min_cbs or y_min_cb >= self.pic_h_min_cbs) return 0;
            const idx = @as(usize, y_min_cb) * self.pic_w_min_cbs + x_min_cb;
            if (idx < dm.len) return dm[idx];
        }
        return 0;
    }
};

/// Derive the luma intra prediction mode for a PU per spec section 8.4.2 /
/// ffmpeg libavcodec/hevc/hevcdec.c:2240-2295. Uses neighbor intra modes
/// (left and above-but-same-CTB-row) to compute the 3 MPM candidates, then
/// selects via mpm_idx or rem_intra_luma_pred_mode.
fn deriveLumaIntraMode(
    ctx: *const SliceCtx,
    x0: u32,
    y0: u32,
    prev_intra_luma_pred_flag: bool,
    mpm_idx: u32,
    rem_intra_luma_pred_mode: u32,
) u8 {
    // Min PU size = 4 (log2 = 2).
    const log2_min_pu: u5 = 2;

    var cand_left: u8 = INTRA_DC;
    if (x0 > 0) {
        const left_x_pu = (x0 - 1) >> log2_min_pu;
        const left_y_pu = y0 >> log2_min_pu;
        cand_left = ctx.lookupIntraMode(left_x_pu, left_y_pu);
    }

    var cand_up: u8 = INTRA_DC;
    if (y0 > 0) {
        // Per spec: intra mode prediction does NOT cross vertical CTB
        // boundaries — if the above neighbor is in a different CTB row,
        // treat it as INTRA_DC. y_ctb = top of current CTB row.
        const y_ctb: u32 = (y0 >> ctx.log2_ctb) << ctx.log2_ctb;
        if ((y0 - 1) >= y_ctb) {
            const above_x_pu = x0 >> log2_min_pu;
            const above_y_pu = (y0 - 1) >> log2_min_pu;
            cand_up = ctx.lookupIntraMode(above_x_pu, above_y_pu);
        }
    }

    var candidate: [3]u8 = undefined;
    if (cand_left == cand_up) {
        if (cand_left < 2) {
            candidate = .{ INTRA_PLANAR, INTRA_DC, INTRA_ANGULAR_26 };
        } else {
            candidate[0] = cand_left;
            // 2 + ((cand_left - 2 - 1 + 32) & 31)  and  2 + ((cand_left - 2 + 1) & 31)
            const left_minus_2: u32 = @as(u32, cand_left) - 2;
            candidate[1] = @intCast(2 + ((left_minus_2 + 31) & 31));
            candidate[2] = @intCast(2 + ((left_minus_2 + 1) & 31));
        }
    } else {
        candidate[0] = cand_left;
        candidate[1] = cand_up;
        if (candidate[0] != INTRA_PLANAR and candidate[1] != INTRA_PLANAR) {
            candidate[2] = INTRA_PLANAR;
        } else if (candidate[0] != INTRA_DC and candidate[1] != INTRA_DC) {
            candidate[2] = INTRA_DC;
        } else {
            candidate[2] = INTRA_ANGULAR_26;
        }
    }

    var intra_pred_mode: u8 = undefined;
    if (prev_intra_luma_pred_flag) {
        intra_pred_mode = candidate[@min(mpm_idx, 2)];
    } else {
        // Sort candidates ascending
        if (candidate[0] > candidate[1]) std.mem.swap(u8, &candidate[0], &candidate[1]);
        if (candidate[0] > candidate[2]) std.mem.swap(u8, &candidate[0], &candidate[2]);
        if (candidate[1] > candidate[2]) std.mem.swap(u8, &candidate[1], &candidate[2]);

        intra_pred_mode = @intCast(@min(rem_intra_luma_pred_mode, 31));
        var i: u8 = 0;
        while (i < 3) : (i += 1) {
            if (intra_pred_mode >= candidate[i]) intra_pred_mode += 1;
        }
    }
    return intra_pred_mode;
}

/// Derive chroma intra prediction mode per spec 8.4.2 — combines the luma
/// mode at this CU's position with intra_chroma_pred_mode (0..4):
///   0 → PLANAR, 1 → ANGULAR_26, 2 → ANGULAR_10, 3 → DC, 4 → use luma mode
/// If the resulting chroma mode equals the luma mode, override to
/// INTRA_ANGULAR_34.
fn deriveChromaIntraMode(luma_mode: u8, intra_chroma_pred_mode: u32) u8 {
    const remap = [4]u8{ INTRA_PLANAR, INTRA_ANGULAR_26, INTRA_ANGULAR_10, INTRA_DC };
    var chroma_mode: u8 = undefined;
    if (intra_chroma_pred_mode == 4) {
        chroma_mode = luma_mode;
    } else {
        chroma_mode = remap[@min(intra_chroma_pred_mode, 3)];
        if (chroma_mode == luma_mode) chroma_mode = INTRA_ANGULAR_34;
    }
    return chroma_mode;
}
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
    sign_data_hiding_enabled: bool,

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
    // Diagnostic counters — diagnostic only, no spec semantics. Used by
    // VALIDATE_TRACE_H265_CABAC to figure out which syntax-element family
    // is consuming bins. Bypass_bins counts EACH bit of decodeBypassBits.
    context_bins: u32,
    bypass_bins: u32,
    terminate_bins: u32,
    // residualCoding aggregates: counts ACROSS all calls in the slice
    residual_calls: u32,
    residual_sig_total: u32,
    residual_greater1_total: u32,
    residual_remaining_total: u32,

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
            .context_bins = 0,
            .bypass_bins = 0,
            .terminate_bins = 0,
            .residual_calls = 0,
            .residual_sig_total = 0,
            .residual_greater1_total = 0,
            .residual_remaining_total = 0,
        };
    }

    pub fn decodeBin(self: *H265CabacEngine, ctx_idx: u16) u1 {
        if (!self.valid) return 0;
        if (ctx_idx >= h265_tables.NUM_H265_CONTEXTS) {
            self.valid = false;
            return 0;
        }
        self.context_bins +%= 1;

        const p_state_idx = self.contexts[ctx_idx].p_state_idx;
        const val_mps = self.contexts[ctx_idx].val_mps;
        const r_before = self.cod_i_range;
        const v_before = self.cod_i_offset;

        const q_idx: u2 = @intCast((self.cod_i_range >> 6) & 3);
        const cod_i_range_lps: u16 = h265_tables.rangeTabLPS[p_state_idx][q_idx];

        self.cod_i_range -= cod_i_range_lps;

        var bin_val: u1 = undefined;
        var lps_path: bool = undefined;

        if (self.cod_i_offset >= self.cod_i_range) {
            bin_val = 1 - val_mps;
            lps_path = true;
            self.cod_i_offset -= self.cod_i_range;
            self.cod_i_range = cod_i_range_lps;

            if (p_state_idx == 0) {
                self.contexts[ctx_idx].val_mps = 1 - val_mps;
            }
            self.contexts[ctx_idx].p_state_idx = @intCast(h265_tables.transIdxLPS[p_state_idx]);
        } else {
            bin_val = val_mps;
            lps_path = false;
            self.contexts[ctx_idx].p_state_idx = @intCast(h265_tables.transIdxMPS[p_state_idx]);
        }

        // Cap per-bin trace at first 2000 bins per slice. Without this,
        // a single 345-CTU autumn run produces ~100MB of trace output and
        // can fill /tmp. Set VALIDATE_TRACE_H265_BINS_FULL to override.
        if (trace.isEnabled(.h265_bins) and
            (self.context_bins + self.bypass_bins + self.terminate_bins < 2000 or runtime.hasEnvVar("VALIDATE_TRACE_H265_BINS_FULL"))) {
            // Format matched to libde265 trace shape so diff lines up:
            //   "[ N] ctx=C bit=B path=MPS|LPS state_pre=S r_pre=X v_pre=Y r_post=X v_post=Y"
            // Per-bin counter (context+bypass+terminate counts combined).
            const n = self.context_bins + self.bypass_bins + self.terminate_bins;
            trace.print(.h265_bins, "[{d}] ctx={d} bit={d} path={s} state_pre={d} r_pre={x} v_pre={x} r_post={x} v_post={x}", .{
                n, ctx_idx, bin_val, if (lps_path) "LPS" else "MPS",
                (@as(u32, p_state_idx) << 1) | @as(u32, val_mps),
                r_before, v_before, self.cod_i_range, self.cod_i_offset,
            });
        }

        self.renormalize();
        return bin_val;
    }

    pub fn decodeBypass(self: *H265CabacEngine) u1 {
        if (!self.valid) return 0;
        self.bypass_bins +%= 1;
        const r_before = self.cod_i_range;
        const v_before = self.cod_i_offset;

        self.cod_i_offset = (self.cod_i_offset << 1) | self.readOneBit();

        var ret: u1 = 0;
        if (self.cod_i_offset >= self.cod_i_range) {
            self.cod_i_offset -= self.cod_i_range;
            ret = 1;
        }

        if (trace.isEnabled(.h265_bins) and
            (self.context_bins + self.bypass_bins + self.terminate_bins < 2000 or runtime.hasEnvVar("VALIDATE_TRACE_H265_BINS_FULL"))) {
            const n = self.context_bins + self.bypass_bins + self.terminate_bins;
            trace.print(.h265_bins, "[{d}] bypass bit={d} r_pre={x} v_pre={x} v_post={x}", .{
                n, ret, r_before, v_before, self.cod_i_offset,
            });
        }
        return ret;
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
        self.terminate_bins +%= 1;
        const r_before = self.cod_i_range;
        const v_before = self.cod_i_offset;

        self.cod_i_range -= 2;

        var ret: u1 = 0;
        if (self.cod_i_offset >= self.cod_i_range) {
            ret = 1;
        } else {
            self.renormalize();
        }

        if (trace.isEnabled(.h265_bins) and
            (self.context_bins + self.bypass_bins + self.terminate_bins < 2000 or runtime.hasEnvVar("VALIDATE_TRACE_H265_BINS_FULL"))) {
            const n = self.context_bins + self.bypass_bins + self.terminate_bins;
            trace.print(.h265_bins, "[{d}] term bit={d} r_pre={x} v_pre={x} r_post={x} v_post={x}", .{
                n, ret, r_before, v_before, self.cod_i_range, self.cod_i_offset,
            });
        }
        return ret;
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
// SAO (Sample Adaptive Offset) parsing — Section 7.3.8.3
// ============================================================================

fn parseSaoParams(engine: *H265CabacEngine, info: *const H265SliceDecodeInfo, rx: u32, ry: u32) void {
    if (!info.slice_sao_luma and !info.slice_sao_chroma) return;
    if (!engine.valid) return;

    // sao_merge_left_flag
    if (rx > 0) {
        const merge_left = engine.decodeBin(h265_tables.CTX_SAO_MERGE_FLAG);
        if (!engine.valid) return;
        if (merge_left == 1) return;
    }

    // sao_merge_up_flag
    if (ry > 0) {
        const merge_up = engine.decodeBin(h265_tables.CTX_SAO_MERGE_FLAG);
        if (!engine.valid) return;
        if (merge_up == 1) return;
    }

    const has_chroma = info.chroma_format_idc != 0;

    if (info.slice_sao_luma) {
        parseSaoComponentParams(engine, info);
        if (!engine.valid) return;
    }

    if (has_chroma and info.slice_sao_chroma) {
        parseSaoComponentParams(engine, info);
        if (!engine.valid) return;
    }
}

fn parseSaoComponentParams(engine: *H265CabacEngine, info: *const H265SliceDecodeInfo) void {
    if (!engine.valid) return;

    const type_bin0 = engine.decodeBin(h265_tables.CTX_SAO_TYPE_IDX);
    if (!engine.valid) return;
    if (type_bin0 == 0) return;

    const type_bin1 = engine.decodeBypass();
    if (!engine.valid) return;
    const sao_type = @as(u32, 1) + type_bin1; // 1=band, 2=edge

    // sao_offset_abs: truncated unary, bypass coded
    const max_offset: u32 = (@as(u32, 1) << @intCast(@min(info.bit_depth_luma, 10) - 5)) - 1;
    var offsets: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..4) |i| {
        if (!engine.valid) return;
        var offset_abs: u32 = 0;
        while (offset_abs < max_offset) : (offset_abs += 1) {
            if (engine.decodeBypass() == 0) break;
            if (!engine.valid) return;
        }
        offsets[i] = offset_abs;
    }

    if (sao_type == 1) {
        // Band offset: sign for non-zero offsets + band position
        for (0..4) |i| {
            if (!engine.valid) return;
            if (offsets[i] != 0) {
                _ = engine.decodeBypass();
            }
        }
        _ = engine.decodeBypassBits(5); // sao_band_position
    } else {
        // Edge offset: sao_eo_class
        _ = engine.decodeBypassBits(2);
    }
}

// ============================================================================
// Coding Quadtree — Section 7.3.8.2
// ============================================================================

fn codingQuadtree(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_cb_size: u32,
    ct_depth: u32,
    ctx: *SliceCtx,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;

    var split = false;
    const cb_size = @as(u32, 1) << @intCast(log2_cb_size);

    if (log2_cb_size > info.log2_min_cb_size) {
        // Force split if CU extends beyond picture
        if (x0 + cb_size > info.pic_width_in_luma or y0 + cb_size > info.pic_height_in_luma) {
            split = true;
        } else {
            // split_cu_flag — H.265 spec 9.3.4.2.2 ctxInc = condL + condA.
            // Neighbor CB's CtDepth > ct_depth → 1, else 0. Unavailable
            // neighbors count as depth 0. depth_map==null falls back to
            // the depth-only approximation.
            var ctx_inc: u16 = 0;
            if (ctx.depth_map != null) {
                if (x0 > 0) {
                    const left_x_min_cb: u32 = (x0 - 1) >> ctx.log2_min_cb;
                    const left_y_min_cb: u32 = y0 >> ctx.log2_min_cb;
                    if (ctx.lookupDepth(left_x_min_cb, left_y_min_cb) > ct_depth) ctx_inc += 1;
                }
                if (y0 > 0) {
                    const above_x_min_cb: u32 = x0 >> ctx.log2_min_cb;
                    const above_y_min_cb: u32 = (y0 - 1) >> ctx.log2_min_cb;
                    if (ctx.lookupDepth(above_x_min_cb, above_y_min_cb) > ct_depth) ctx_inc += 1;
                }
            } else {
                ctx_inc = @intCast(if (ct_depth > 2) @as(u32, 2) else ct_depth);
            }
            const split_flag = engine.decodeBin(h265_tables.CTX_SPLIT_CU_FLAG + ctx_inc);
            if (!engine.valid) return;
            split = split_flag == 1;
        }
    }

    if (split) {
        if (log2_cb_size == 0) {
            engine.valid = false;
            return;
        }
        const half_size = log2_cb_size - 1;
        const half = @as(u32, 1) << @intCast(half_size);
        codingQuadtree(engine, info, x0, y0, half_size, ct_depth + 1, ctx);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0 + half, y0, half_size, ct_depth + 1, ctx);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0, y0 + half, half_size, ct_depth + 1, ctx);
        if (!engine.valid) return;
        codingQuadtree(engine, info, x0 + half, y0 + half, half_size, ct_depth + 1, ctx);
    } else {
        // Leaf CB: stamp this CB's coverage into depth_map with ct_depth so
        // following CBs' split_cu_flag neighbor lookups see the right value.
        if (ctx.depth_map) |dm| {
            const cb_w_min_cbs = cb_size >> ctx.log2_min_cb;
            const x_start = x0 >> ctx.log2_min_cb;
            const y_start = y0 >> ctx.log2_min_cb;
            const depth_u8: u8 = @intCast(@min(ct_depth, 255));
            var dy: u32 = 0;
            while (dy < cb_w_min_cbs) : (dy += 1) {
                const yi = y_start + dy;
                if (yi >= ctx.pic_h_min_cbs) break;
                var dx: u32 = 0;
                while (dx < cb_w_min_cbs) : (dx += 1) {
                    const xi = x_start + dx;
                    if (xi >= ctx.pic_w_min_cbs) break;
                    const idx = @as(usize, yi) * ctx.pic_w_min_cbs + xi;
                    if (idx < dm.len) dm[idx] = depth_u8;
                }
            }
        }
        codingUnit(engine, info, x0, y0, log2_cb_size, ctx);
    }
}

// ============================================================================
// Coding Unit — Section 7.3.8.5
// ============================================================================

fn codingUnit(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_cb_size: u32,
    ctx: *SliceCtx,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;

    // cu_transquant_bypass_flag
    if (info.transquant_bypass_enabled) {
        _ = engine.decodeBin(h265_tables.CTX_CU_TRANSQUANT_BYPASS);
        if (!engine.valid) return;
    }

    // For I-slice: pred_mode is always INTRA
    // part_mode: 2Nx2N (0) or NxN (1, only at min CU size)
    var part_mode: u32 = 0;
    if (log2_cb_size == info.log2_min_cb_size) {
        const part_bin = engine.decodeBin(h265_tables.CTX_PART_MODE);
        if (!engine.valid) return;
        if (part_bin == 0) {
            part_mode = 1; // NxN (bin=0 means NxN for I-slice at min CU)
        }
    }

    // PCM check
    if (info.pcm_enabled and log2_cb_size >= info.pcm_log2_min_size and
        log2_cb_size <= info.pcm_log2_max_size)
    {
        const pcm_flag = engine.decodeTerminate();
        if (!engine.valid) return;
        if (pcm_flag == 1) {
            engine.reader.alignToByte();
            const cb_sz = @as(u32, 1) << @intCast(log2_cb_size);
            const luma_samples = cb_sz * cb_sz;
            const chroma_samples = if (info.chroma_format_idc == 1)
                luma_samples / 2
            else if (info.chroma_format_idc == 2)
                luma_samples
            else if (info.chroma_format_idc == 3)
                luma_samples * 2
            else
                0;
            const total_bits = luma_samples * info.bit_depth_luma + chroma_samples * info.bit_depth_chroma;
            _ = engine.reader.skipBits(total_bits);
            engine.* = H265CabacEngine.init(engine.reader, info.slice_qp);
            return;
        }
    }

    // Intra prediction modes — Section 7.3.8.5
    const num_pus: u32 = if (part_mode == 1) 4 else 1;
    const pu_offset: u32 = if (part_mode == 1) (@as(u32, 1) << @intCast(log2_cb_size - 1)) else (@as(u32, 1) << @intCast(log2_cb_size));

    // prev_intra_luma_pred_flag for each PU
    var prev_flags: [4]u1 = undefined;
    for (0..num_pus) |pu| {
        prev_flags[pu] = engine.decodeBin(h265_tables.CTX_PREV_INTRA_LUMA_PRED);
        if (!engine.valid) return;
    }

    // mpm_idx (when prev=1) or rem_intra_luma_pred_mode (when prev=0) per PU.
    // CAPTURE the values (previously discarded) so we can run MPM derivation
    // and store the resulting intra_pred_mode per PU into the picture-wide
    // intra mode map — feeds scan_idx for residualCoding (Bug #4j).
    var mpm_idx: [4]u32 = .{ 0, 0, 0, 0 };
    var rem_mode: [4]u32 = .{ 0, 0, 0, 0 };
    for (0..num_pus) |pu| {
        if (prev_flags[pu] == 1) {
            // mpm_idx: truncated unary, max 2 (values 0/1/2). Bin0=0 → 0;
            // bin0=1,bin1=0 → 1; bin0=1,bin1=1 → 2.
            const bin0 = engine.decodeBypass();
            if (!engine.valid) return;
            if (bin0 == 0) {
                mpm_idx[pu] = 0;
            } else {
                const bin1 = engine.decodeBypass();
                if (!engine.valid) return;
                mpm_idx[pu] = if (bin1 == 0) @as(u32, 1) else @as(u32, 2);
            }
        } else {
            // rem_intra_luma_pred_mode: 5 bypass bins (FL with max value 31)
            rem_mode[pu] = engine.decodeBypassBits(5);
            if (!engine.valid) return;
        }
    }

    // For each PU: derive intra_pred_mode + store in map (granularity 4x4).
    // Per spec, the PU positions for NxN are:
    //   pu=0: (x0,            y0)
    //   pu=1: (x0 + pu_offset, y0)
    //   pu=2: (x0,            y0 + pu_offset)
    //   pu=3: (x0 + pu_offset, y0 + pu_offset)
    const pu_x_off: [4]u32 = .{ 0, pu_offset, 0, pu_offset };
    const pu_y_off: [4]u32 = .{ 0, 0, pu_offset, pu_offset };
    var luma_modes: [4]u8 = .{ INTRA_DC, INTRA_DC, INTRA_DC, INTRA_DC };
    for (0..num_pus) |pu| {
        const pu_x = x0 + pu_x_off[pu];
        const pu_y = y0 + pu_y_off[pu];
        const mode = deriveLumaIntraMode(ctx, pu_x, pu_y, prev_flags[pu] == 1, mpm_idx[pu], rem_mode[pu]);
        luma_modes[pu] = mode;
        // Store at min-PU granularity (4x4 = log2 2)
        const pu_x_min = pu_x >> 2;
        const pu_y_min = pu_y >> 2;
        const pu_size_min_pus = pu_offset >> 2;
        ctx.storeIntraMode(pu_x_min, pu_y_min, pu_size_min_pus, mode);
    }

    // intra_chroma_pred_mode — Section 7.3.8.5 / ffmpeg cabac.c:725.
    // Binarization: bin0=0 → value 4 (use luma mode); bin0=1 + 2 bypass bins
    // → values 0/1/2/3 (high bit first). Per spec 9.3.2.5.
    // For ChromaArrayType==1 (4:2:0) — our HEIC case — one chroma_pred_mode
    // per CU and the derived chroma mode uses the luma mode at the CU's
    // TOP-LEFT position (luma_modes[0]). Store the resulting chroma mode at
    // every min-PU position the CU covers so transformUnit can look it up
    // by TB top-left coordinate.
    if (info.chroma_format_idc != 0) {
        const chroma_bin0 = engine.decodeBin(h265_tables.CTX_INTRA_CHROMA_PRED_MODE);
        if (!engine.valid) return;
        var intra_chroma_pred_mode: u32 = 4;
        if (chroma_bin0 == 1) {
            const cb_b1 = engine.decodeBypass();
            if (!engine.valid) return;
            const cb_b0 = engine.decodeBypass();
            if (!engine.valid) return;
            intra_chroma_pred_mode = (@as(u32, cb_b1) << 1) | @as(u32, cb_b0);
        }
        const chroma_mode = deriveChromaIntraMode(luma_modes[0], intra_chroma_pred_mode);
        const cu_size_min_pus = (@as(u32, 1) << @intCast(log2_cb_size)) >> 2;
        const cu_x_min = x0 >> 2;
        const cu_y_min = y0 >> 2;
        ctx.storeChromaMode(cu_x_min, cu_y_min, cu_size_min_pus, chroma_mode);
    }

    // Transform tree — Section 7.3.8.8
    const max_depth = info.max_transform_hierarchy_depth_intra;
    const effective_max_depth = if (part_mode == 1) max_depth + 1 else max_depth;
    const intra_split_flag = (part_mode == 1);
    transformTree(engine, info, x0, y0, log2_cb_size, 0, effective_max_depth, log2_cb_size, true, true, 0, intra_split_flag, ctx);
}

// ============================================================================
// Transform Tree — Section 7.3.8.8
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
    parent_cbf_cb: bool,
    parent_cbf_cr: bool,
    blk_idx: u32,
    intra_split_flag: bool,
    ctx: *SliceCtx,
) void {
    if (!engine.valid) return;
    if (x0 >= info.pic_width_in_luma or y0 >= info.pic_height_in_luma) return;

    const log2_tb_size = log2_cb_size - trafo_depth;

    // Sanity check
    if (log2_tb_size < 2 or log2_tb_size > 6) {
        engine.valid = false;
        return;
    }

    var split = false;

    if (log2_tb_size > info.log2_max_tb_size) {
        split = true;
    } else if (intra_split_flag and trafo_depth == 0) {
        // Spec section 7.3.8.8: split_transform_flag is NOT coded at the
        // top of an intra CU with NxN partition (IntraSplitFlag=1) — split
        // is forced. Reading a bin here is a phantom read that desyncs.
        split = true;
    } else if (log2_tb_size <= info.log2_min_tb_size) {
        split = false;
    } else if (trafo_depth >= max_depth) {
        split = false;
    } else {
        const ctx_inc: u16 = @intCast(if (trafo_depth > 2) @as(u32, 2) else trafo_depth);
        const split_flag = engine.decodeBin(h265_tables.CTX_SPLIT_TRANSFORM_FLAG + ctx_inc);
        if (!engine.valid) return;
        split = split_flag == 1;
    }

    // Chroma CBF flags — Section 7.3.8.8
    // cbf_cb and cbf_cr are coded when log2TrafoSize > 2 (for 4:2:0)
    // OR when trafo_depth == 0 and chroma exists.
    // For split TUs, chroma CBFs propagate to children.
    var cbf_cb: bool = parent_cbf_cb;
    var cbf_cr: bool = parent_cbf_cr;

    if (info.chroma_format_idc != 0) {
        // Chroma CBF is coded when the CHROMA TB size > min (i.e., log2_tb_size > 2 for 4:2:0)
        // For the current depth: chroma TB is log2_tb_size - 1 for 4:2:0
        // CBF is coded at levels where chroma has a valid TB
        if (log2_tb_size > 2) {
            if (trafo_depth == 0 or parent_cbf_cb) {
                const cbf_ctx: u16 = @intCast(if (trafo_depth > 4) @as(u32, 4) else trafo_depth);
                cbf_cb = engine.decodeBin(h265_tables.CTX_CBF_CHROMA + cbf_ctx) == 1;
                if (!engine.valid) return;
            }
            if (trafo_depth == 0 or parent_cbf_cr) {
                const cbf_ctx: u16 = @intCast(if (trafo_depth > 4) @as(u32, 4) else trafo_depth);
                cbf_cr = engine.decodeBin(h265_tables.CTX_CBF_CHROMA + cbf_ctx) == 1;
                if (!engine.valid) return;
            }
        }
    }

    if (split) {
        if (log2_tb_size <= 2) {
            engine.valid = false;
            return;
        }
        const half_size = @as(u32, 1) << @intCast(log2_tb_size - 1);
        // Recursive transform tree calls — IntraSplitFlag does NOT propagate
        // to children (it only excludes the depth-0 bin coding).
        transformTree(engine, info, x0, y0, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size, cbf_cb, cbf_cr, 0, false, ctx);
        if (!engine.valid) return;
        transformTree(engine, info, x0 + half_size, y0, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size, cbf_cb, cbf_cr, 1, false, ctx);
        if (!engine.valid) return;
        transformTree(engine, info, x0, y0 + half_size, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size, cbf_cb, cbf_cr, 2, false, ctx);
        if (!engine.valid) return;
        transformTree(engine, info, x0 + half_size, y0 + half_size, log2_cb_size, trafo_depth + 1, max_depth, log2_pu_size, cbf_cb, cbf_cr, 3, false, ctx);
    } else {
        transformUnit(engine, info, x0, y0, log2_tb_size, trafo_depth, blk_idx, cbf_cb, cbf_cr, ctx);
    }
}

// ============================================================================
// Transform Unit — Section 7.3.8.9
// ============================================================================

fn transformUnit(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    x0: u32,
    y0: u32,
    log2_tb_size: u32,
    trafo_depth: u32,
    blk_idx: u32,
    cbf_cb: bool,
    cbf_cr: bool,
    ctx: *SliceCtx,
) void {
    if (!engine.valid) return;

    // cbf_luma — spec Table 9-37: ctxInc = (trafoDepth == 0) ? 1 : 0.
    // Note the inversion: trafoDepth==0 uses context index 1, deeper uses 0.
    const luma_ctx: u16 = if (trafo_depth == 0) 1 else 0;
    const cbf_luma = engine.decodeBin(h265_tables.CTX_CBF_LUMA + luma_ctx) == 1;
    if (!engine.valid) return;

    // cu_qp_delta
    if (info.cu_qp_delta_enabled and (cbf_luma or cbf_cb or cbf_cr)) {
        parseCuQpDelta(engine);
        if (!engine.valid) return;
    }

    // transform_skip_flag for luma: only for 4x4 TBs (log2_tb_size == 2)
    if (info.transform_skip_enabled and cbf_luma and log2_tb_size == 2) {
        _ = engine.decodeBin(h265_tables.CTX_TRANSFORM_SKIP_FLAG); // luma
        if (!engine.valid) return;
    }

    // Chroma residual placement — spec section 7.3.8.9. For 4:2:0 with a 4x4
    // luma TB (log2_tb_size == 2), the chroma residual is shared across the
    // four 4x4-luma siblings and decoded ONCE on the last sibling
    // (blk_idx == 3) with chroma TB size 4x4 (log2=2).
    const decode_chroma_here = info.chroma_format_idc != 0 and
        (log2_tb_size > 2 or info.chroma_format_idc == 3 or blk_idx == 3);

    if (info.transform_skip_enabled and decode_chroma_here) {
        const chroma_is_4x4 = (info.chroma_format_idc != 3 and log2_tb_size == 3) or
            (info.chroma_format_idc == 3 and log2_tb_size == 2) or
            (info.chroma_format_idc != 3 and log2_tb_size == 2 and blk_idx == 3);
        if (chroma_is_4x4) {
            if (cbf_cb) {
                _ = engine.decodeBin(h265_tables.CTX_TRANSFORM_SKIP_FLAG + 1);
                if (!engine.valid) return;
            }
            if (cbf_cr) {
                _ = engine.decodeBin(h265_tables.CTX_TRANSFORM_SKIP_FLAG + 1);
                if (!engine.valid) return;
            }
        }
    }

    // Look up luma intra mode at the TB top-left position. Used for both
    // luma scan_idx and chroma scan_idx (chroma derives from co-located
    // luma in spec — we use luma directly as a reasonable approximation
    // when intra_chroma_pred_mode tracking lands; for now chroma scan
    // remains DIAG which is correct for log2 >= 4 chroma TBs).
    const luma_intra_mode: u8 = blk: {
        const pu_x_min = x0 >> 2;
        const pu_y_min = y0 >> 2;
        break :blk ctx.lookupIntraMode(pu_x_min, pu_y_min);
    };
    const luma_scan_idx = deriveScanIdx(luma_intra_mode, log2_tb_size);

    // Luma residual data
    if (cbf_luma) {
        residualCoding(engine, info, log2_tb_size, true, luma_scan_idx);
        if (!engine.valid) return;
    }

    // Chroma residual data
    if (decode_chroma_here) {
        const log2_chroma_tb: u32 = if (info.chroma_format_idc == 3)
            log2_tb_size
        else if (log2_tb_size > 2)
            log2_tb_size - 1
        else
            2;
        // Chroma scan_idx (Bug #4k): derived from the stored chroma intra
        // mode at this chroma TB's position. The chroma_mode_map is filled
        // in codingUnit during intra_chroma_pred_mode decode (and is
        // INTRA_DC by default if alloc failed). For log2_chroma_tb >= 4
        // scan_idx is always DIAG per spec, so this only matters for chroma
        // 4x4 and 8x8 TBs.
        const chroma_mode_at_tb: u8 = blk: {
            const pu_x_min = x0 >> 2;
            const pu_y_min = y0 >> 2;
            break :blk ctx.lookupChromaMode(pu_x_min, pu_y_min);
        };
        const chroma_scan_idx = deriveScanIdx(chroma_mode_at_tb, log2_chroma_tb);
        if (cbf_cb) {
            residualCoding(engine, info, log2_chroma_tb, false, chroma_scan_idx);
            if (!engine.valid) return;
        }
        if (cbf_cr) {
            residualCoding(engine, info, log2_chroma_tb, false, chroma_scan_idx);
        }
    }
}

/// Parse cu_qp_delta_abs + cu_qp_delta_sign_flag (Section 7.3.8.9)
fn parseCuQpDelta(engine: *H265CabacEngine) void {
    if (!engine.valid) return;

    // cu_qp_delta_abs: prefix (truncated unary, 2 contexts) + suffix (bypass EGk)
    const bin0 = engine.decodeBin(h265_tables.CTX_CU_QP_DELTA_ABS);
    if (!engine.valid) return;
    if (bin0 == 0) return; // delta = 0

    var prefix: u32 = 1;
    // Remaining prefix bins use context 1 (up to 5 total prefix bins)
    while (prefix < 5) : (prefix += 1) {
        const b = engine.decodeBin(h265_tables.CTX_CU_QP_DELTA_ABS + 1);
        if (!engine.valid) return;
        if (b == 0) break;
    }

    if (prefix >= 5) {
        // Suffix: bypass exp-golomb order 0
        var eg_prefix: u32 = 0;
        while (eg_prefix < 32 and engine.valid) : (eg_prefix += 1) {
            if (engine.decodeBypass() == 0) break;
        }
        if (eg_prefix > 0 and engine.valid) {
            _ = engine.decodeBypassBits(eg_prefix);
        }
    }

    if (!engine.valid) return;
    // cu_qp_delta_sign_flag
    _ = engine.decodeBypass();
}

// ============================================================================
// Residual Coding — Section 7.3.8.11 (spec-perfect)
// ============================================================================

fn residualCoding(
    engine: *H265CabacEngine,
    info: *const H265SliceDecodeInfo,
    log2_tb_size: u32,
    is_luma: bool,
    scan_idx: ScanType,
) void {
    if (!engine.valid) return;
    engine.residual_calls +%= 1;
    var tu_sig_total: u32 = 0;
    var tu_greater1_total: u32 = 0;
    var tu_remaining_total: u32 = 0;

    const tu_trace = trace.isEnabled(.h265_cabac);
    const tu_bits_in = if (tu_trace) engine.reader.remainingBits() else 0;
    const tu_seq = if (tu_trace) engine.residual_calls else 0;

    defer {
        engine.residual_sig_total +%= tu_sig_total;
        engine.residual_greater1_total +%= tu_greater1_total;
        engine.residual_remaining_total +%= tu_remaining_total;
        if (tu_trace) {
            const bits_out = engine.reader.remainingBits();
            const consumed = if (tu_bits_in >= bits_out) tu_bits_in - bits_out else 0;
            trace.print(.h265_cabac, "tu seq={d} log2={d} is_luma={} bits_in={d} consumed={d} sig={d} g1={d} rem={d} valid={}", .{
                tu_seq, log2_tb_size, is_luma, tu_bits_in, consumed,
                tu_sig_total, tu_greater1_total, tu_remaining_total, engine.valid,
            });
        }
    }

    const tb_size_clamped = std.math.clamp(log2_tb_size, 2, 5);

    // last_sig_coeff per spec section 7.3.8.11: prefix-X, prefix-Y, then
    // suffix-X, then suffix-Y. The previous implementation decoded prefix+
    // suffix for X first, then prefix+suffix for Y, which desynced the
    // bitstream for any TB where either prefix > 3 (suffix bits present).
    const last_x_prefix = decodeLastSigCoeffPrefix(engine, tb_size_clamped, is_luma, true);
    if (!engine.valid) return;
    const last_y_prefix = decodeLastSigCoeffPrefix(engine, tb_size_clamped, is_luma, false);
    if (!engine.valid) return;
    const last_x_suffix = blk: {
        const bits = lastSigCoeffSuffixBits(last_x_prefix);
        if (bits == 0) break :blk @as(u32, 0);
        const v = engine.decodeBypassBits(bits);
        if (!engine.valid) return;
        break :blk v;
    };
    const last_y_suffix = blk: {
        const bits = lastSigCoeffSuffixBits(last_y_prefix);
        if (bits == 0) break :blk @as(u32, 0);
        const v = engine.decodeBypassBits(bits);
        if (!engine.valid) return;
        break :blk v;
    };
    // Spec: for SCAN_VERT, swap last_x and last_y so subsequent scan-table
    // operations treat (x,y) as if HORIZ — vertical scan is column-major,
    // which is row-major with axes swapped. ffmpeg
    // libavcodec/hevc/cabac.c:1118 does the same FFSWAP.
    const last_x: u32 = if (scan_idx == .vert) combineLastSigCoeff(last_y_prefix, last_y_suffix) else combineLastSigCoeff(last_x_prefix, last_x_suffix);
    const last_y: u32 = if (scan_idx == .vert) combineLastSigCoeff(last_x_prefix, last_x_suffix) else combineLastSigCoeff(last_y_prefix, last_y_suffix);

    // Sub-block dimensions
    const num_sb_side = @as(u32, 1) << @intCast(tb_size_clamped - 2);
    const total_sub_blocks = num_sb_side * num_sb_side;

    // Within-sub-block scan order (4x4 positions). Per scan_idx.
    const within_sb_scan = getWithinSbScan(scan_idx);

    // Last sub-block and position within it
    const last_sb_x = last_x >> 2;
    const last_sb_y = last_y >> 2;

    // Find lastSubBlock in scan order
    var last_scan_pos: u32 = 15;
    var last_sub_block: u32 = 0;

    if (tb_size_clamped == 2) {
        // 4x4 TB: single sub-block, find position via scan-type-correct table
        last_sub_block = 0;
        last_scan_pos = 0;
        for (within_sb_scan, 0..) |pos, i| {
            if (pos[0] == @as(u8, @intCast(last_x)) and pos[1] == @as(u8, @intCast(last_y))) {
                last_scan_pos = @intCast(i);
                break;
            }
        }
    } else {
        // Find sub-block in scan order (sub-block scan tables also depend
        // on scan_idx for 8x8 TBs — 2x2 sub-block array).
        const sb_scan_pre = getSubBlockScan(num_sb_side, scan_idx);
        for (sb_scan_pre, 0..) |sb, i| {
            if (i >= total_sub_blocks) break;
            if (sb[0] == @as(u8, @intCast(last_sb_x)) and sb[1] == @as(u8, @intCast(last_sb_y))) {
                last_sub_block = @intCast(i);
                break;
            }
        }
        // Find position within sub-block (within_sb_scan).
        const local_x: u8 = @intCast(last_x & 3);
        const local_y: u8 = @intCast(last_y & 3);
        for (within_sb_scan, 0..) |pos, i| {
            if (pos[0] == local_x and pos[1] == local_y) {
                last_scan_pos = @intCast(i);
                break;
            }
        }
    }

    // Track coded sub-block flags for neighbor context derivation
    var coded_sb_flags: [64]bool = [_]bool{false} ** 64; // max 8x8 = 64 sub-blocks
    coded_sb_flags[0] = true; // DC sub-block (scan index 0) is always implicitly coded
    // Last sub-block is always coded
    if (last_sub_block < 64) coded_sb_flags[last_sub_block] = true;

    const sb_scan = getSubBlockScan(num_sb_side, scan_idx);

    // Greater1 context tracking across sub-blocks (Section 9.3.3.1.3)
    var last_greater1_ctx: u32 = 1; // ctxSet for greater1 flag
    var last_greater1_flag: bool = false; // whether any greater1 was 1 in prev sub-block

    // Iterate sub-blocks in REVERSE scan order
    var sb_scan_idx_plus1: u32 = last_sub_block + 1;
    while (sb_scan_idx_plus1 > 0) : (sb_scan_idx_plus1 -= 1) {
        if (!engine.valid) return;
        const sb_scan_idx = sb_scan_idx_plus1 - 1;

        const sb_x: u32 = if (total_sub_blocks <= 1) 0 else sb_scan[sb_scan_idx][0];
        const sb_y: u32 = if (total_sub_blocks <= 1) 0 else sb_scan[sb_scan_idx][1];

        // coded_sub_block_flag — not coded for first (DC) and last sub-block
        var coded: bool = true;
        if (sb_scan_idx > 0 and sb_scan_idx < last_sub_block) {
            // Context derivation per Section 9.3.3.1.2
            // csbfCtx = (coded right neighbor) + (coded below neighbor)
            var csb_ctx: u16 = 0;
            // Check right neighbor sub-block
            if (sb_x + 1 < num_sb_side) {
                // Find scan index of (sb_x+1, sb_y) — check if it's coded
                if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x + 1), @intCast(sb_y))) |right_idx| {
                    if (coded_sb_flags[right_idx]) csb_ctx += 1;
                }
            }
            // Check below neighbor sub-block
            if (sb_y + 1 < num_sb_side) {
                if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x), @intCast(sb_y + 1))) |below_idx| {
                    if (coded_sb_flags[below_idx]) csb_ctx += 1;
                }
            }

            const ctx_base: u16 = if (is_luma) 0 else 2;
            const ctx: u16 = h265_tables.CTX_CODED_SUB_BLOCK_FLAG + ctx_base + @min(csb_ctx, 1);
            coded = engine.decodeBin(ctx) == 1;
            if (!engine.valid) return;
            coded_sb_flags[sb_scan_idx] = coded;
        } else if (sb_scan_idx == 0) {
            coded_sb_flags[0] = true;
            coded = true;
        }

        if (!coded) continue;

        // sig_coeff_flag for each position in the 4x4 sub-block, in reverse
        // diag scan order. Spec-correct context derivation per H.265 spec
        // section 9.3.4.2.5 / ffmpeg libavcodec/hevc/cabac.c:1220-1295
        // (see docs/hevc-reference/ffmpeg-hevc-cabac.c).
        var sig_flags: [16]bool = [_]bool{false} ** 16;
        var num_sig: u32 = 0;

        // Compute prev_sig: 0..3 from right+below sub-block coded flags.
        // (Bit 0 = right-neighbor coded; bit 1 = below-neighbor coded.)
        var prev_sig: u32 = 0;
        if (sb_x + 1 < num_sb_side) {
            if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x + 1), @intCast(sb_y))) |right_idx| {
                if (coded_sb_flags[right_idx]) prev_sig = 1;
            }
        }
        if (sb_y + 1 < num_sb_side) {
            if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x), @intCast(sb_y + 1))) |below_idx| {
                if (coded_sb_flags[below_idx]) prev_sig += 2;
            }
        }

        // scf_offset and ctx_idx_map section for non-DC positions in this
        // sub-block. Spec offsets per H.265 / Table 9-15:
        //   4x4 TB:    luma 0-8,  chroma 27-35
        //   8x8 TB:    luma 9-20  (DC sb 9-11, non-DC 12-20)
        //              chroma 36-38 (DC sb 36-38)
        //   16x16+ TB: luma 21-26 (DC sb 21-23, non-DC 24-26)
        //              chroma 39-43
        // NOTE: SCAN_HORIZ/VERT scans for 8x8 luma add +6 (offsets 15-23).
        // We always assume SCAN_DIAG until intra-mode tracking lands (Bug #2h).
        var scf_offset: u32 = 0;
        var ctx_idx_map_section: u32 = 0;
        if (tb_size_clamped == 2) {
            ctx_idx_map_section = 0; // Section 0: 4x4 TB position table
            if (!is_luma) scf_offset = 27;
        } else {
            // Non-4x4 TB: prev_sig-keyed section (offset by +1 to skip the
            // 4x4 section at index 0).
            ctx_idx_map_section = (prev_sig + 1) * 16;
            if (is_luma) {
                if (sb_x > 0 or sb_y > 0) scf_offset = 3;
                if (tb_size_clamped == 3) {
                    // Luma 8x8: SCAN_DIAG → +9, SCAN_HORIZ/VERT → +15.
                    scf_offset += if (scan_idx == .diag) @as(u32, 9) else @as(u32, 15);
                } else {
                    // Luma 16x16+ always uses +21 (no scan_idx dependency).
                    scf_offset += 21;
                }
            } else {
                scf_offset = 27;
                scf_offset += if (tb_size_clamped == 3) @as(u32, 9) else @as(u32, 12);
            }
        }

        // Interior sub-blocks (csbf was DECODED as 1 — neither DC nor last)
        // imply DC=1 unless we find another sig coeff in the non-DC
        // positions. Cleared if any decoded sig_coeff_flag bin is 1.
        var implicit_dc_nonzero = sb_scan_idx > 0 and sb_scan_idx != last_sub_block;

        const first_scan_pos: u32 = if (sb_scan_idx == last_sub_block) last_scan_pos else 15;

        // Decode positions first_scan_pos..1 (DC at position 0 handled
        // separately below per spec).
        if (first_scan_pos > 0) {
            var n_pos: u32 = first_scan_pos + 1;
            while (n_pos > 1) : (n_pos -= 1) {
                if (!engine.valid) return;
                const scan_pos = n_pos - 1;
                const local_x = within_sb_scan[scan_pos][0];
                const local_y = within_sb_scan[scan_pos][1];

                // Last position in last sub-block is implicitly significant.
                if (sb_scan_idx == last_sub_block and scan_pos == last_scan_pos) {
                    sig_flags[scan_pos] = true;
                    num_sig += 1;
                    implicit_dc_nonzero = false;
                    continue;
                }

                const map_idx: u32 = @as(u32, local_y) * 4 + @as(u32, local_x);
                const table_inc: u32 = sig_ctx_idx_map[ctx_idx_map_section + map_idx];
                const full_ctx: u16 = @intCast(@as(u32, h265_tables.CTX_SIG_COEFF_FLAG) + table_inc + scf_offset);
                if (full_ctx >= h265_tables.NUM_H265_CONTEXTS) {
                    engine.valid = false;
                    return;
                }
                sig_flags[scan_pos] = engine.decodeBin(full_ctx) == 1;
                if (!engine.valid) return;
                if (sig_flags[scan_pos]) {
                    num_sig += 1;
                    implicit_dc_nonzero = false;
                }
            }
        }

        // Handle position 0 (DC of sub-block) per spec.
        if (sb_scan_idx == last_sub_block and last_scan_pos == 0) {
            // DC is the slice's last sig coeff — implicitly significant.
            sig_flags[0] = true;
            num_sig += 1;
        } else if (implicit_dc_nonzero) {
            // Interior sub-block: csbf=1 was decoded and no other sig
            // appeared. The encoder couldn't have written csbf=1 without
            // at least one nonzero coeff, so DC must be it.
            sig_flags[0] = true;
            num_sig += 1;
        } else {
            // DC sub-block (sb_scan_idx==0) or last sub-block with last>0:
            // decode DC explicitly with the spec's DC-special offset.
            //   DC sub-block: luma 0, chroma 27
            //   non-DC sub-block: scf_offset + 2
            if (!engine.valid) return;
            const dc_offset: u32 = if (sb_scan_idx == 0)
                (if (is_luma) @as(u32, 0) else @as(u32, 27))
            else
                scf_offset + 2;
            const full_ctx: u16 = @intCast(@as(u32, h265_tables.CTX_SIG_COEFF_FLAG) + dc_offset);
            if (full_ctx >= h265_tables.NUM_H265_CONTEXTS) {
                engine.valid = false;
                return;
            }
            sig_flags[0] = engine.decodeBin(full_ctx) == 1;
            if (!engine.valid) return;
            if (sig_flags[0]) num_sig += 1;
        }

        tu_sig_total += num_sig;
        if (num_sig == 0) continue;

        // coeff_abs_level_greater1_flag — Section 7.3.8.11
        // Up to 8 per sub-block, context tracking per spec Section 9.3.3.1.3
        var num_greater1: u32 = 0;
        var first_greater1_scan_pos: u32 = 16; // sentinel

        // Context set selection per Section 9.3.3.1.3
        // ctxSet depends on: sub-block index, whether previous sub-block had greater1,
        // and luma/chroma
        var ctx_set: u32 = undefined;
        if (sb_scan_idx == 0 or !is_luma) {
            ctx_set = 0;
        } else {
            ctx_set = 2;
        }
        if (last_greater1_flag and sb_scan_idx != last_sub_block) {
            ctx_set += 1;
        }
        // For chroma, only ctx_set 0 or 1
        if (!is_luma) {
            ctx_set = if (last_greater1_flag and sb_scan_idx != last_sub_block) @as(u32, 1) else @as(u32, 0);
        }

        // greater1Ctx starts at 1 within each set (0 is for flag=0 tracking)
        var greater1_ctx: u32 = 1;

        // Per-position greater1 flags. Indexed by scan_pos within the sub-block
        // (0..15). Saved so the trans_coeff_level loop (ffmpeg cabac.c:1366)
        // can interleave g1-based remaining reads with past-8 unconditional
        // remaining reads in REVERSE SCAN ORDER — critical for correct
        // rice_param trajectory (rice_param updates after each remaining;
        // wrong order = wrong rice = wrong bit count from then on).
        var g1_flags_pos: [16]bool = [_]bool{false} ** 16;
        var g1_count: u32 = 0;
        var scan_i: u32 = first_scan_pos + 1;
        while (scan_i > 0) : (scan_i -= 1) {
            if (!engine.valid) return;
            const sp = scan_i - 1;
            if (!sig_flags[sp]) continue;
            if (g1_count >= 8) break;

            // Context index: base + ctx_set*4 + greater1Ctx
            const g1_ctx_idx: u16 = h265_tables.CTX_COEFF_ABS_LEVEL_GREATER1 +
                @as(u16, @intCast(ctx_set * 4)) + @as(u16, @intCast(greater1_ctx));
            if (g1_ctx_idx >= h265_tables.NUM_H265_CONTEXTS) {
                engine.valid = false;
                return;
            }
            const g1 = engine.decodeBin(g1_ctx_idx);
            if (!engine.valid) return;

            if (g1 == 1) {
                g1_flags_pos[sp] = true;
                num_greater1 += 1;
                if (first_greater1_scan_pos == 16) first_greater1_scan_pos = sp;
                // After seeing a 1, context goes to 0 (stays there)
                greater1_ctx = 0;
            } else {
                // Increment context (max 3)
                if (greater1_ctx < 3 and greater1_ctx > 0) greater1_ctx += 1;
            }

            g1_count += 1;
        }

        tu_greater1_total += num_greater1;
        // Update cross-sub-block tracking
        last_greater1_ctx = greater1_ctx;
        last_greater1_flag = num_greater1 > 0;

        // coeff_abs_level_greater2_flag — at most 1 per sub-block
        var has_greater2: bool = false;
        if (num_greater1 > 0) {
            // Context: per spec, ctxSet determines the context
            const g2_ctx: u16 = h265_tables.CTX_COEFF_ABS_LEVEL_GREATER2 + @as(u16, @intCast(ctx_set));
            if (g2_ctx >= h265_tables.NUM_H265_CONTEXTS) {
                engine.valid = false;
                return;
            }
            has_greater2 = engine.decodeBin(g2_ctx) == 1;
            if (!engine.valid) return;
        }

        // Sign hiding — Section 7.4.9.11
        // signHidden = (lastScanPos - firstSigScanPos > 3) && sign_data_hiding_enabled
        var first_sig_scan_pos: u32 = 16;
        var last_sig_scan_pos: u32 = 0;
        for (0..16) |sp| {
            if (sig_flags[sp]) {
                if (sp < first_sig_scan_pos) first_sig_scan_pos = @intCast(sp);
                last_sig_scan_pos = @intCast(sp);
            }
        }
        const sign_hiding_active = info.sign_data_hiding_enabled and
            (last_sig_scan_pos -| first_sig_scan_pos) > 3;

        // coeff_sign_flag: bypass bins
        // If sign hiding active, decode (num_sig - 1) signs (last is inferred)
        const num_signs: u32 = if (sign_hiding_active and num_sig > 0) num_sig - 1 else num_sig;
        for (0..num_signs) |_| {
            _ = engine.decodeBypass();
            if (!engine.valid) return;
        }

        // coeff_abs_level_remaining — decode in REVERSE SCAN ORDER, one pass
        // through every sig position. Port of ffmpeg cabac.c:1366-1410 main
        // trans_coeff_level loop. The order matters: rice_param updates after
        // each remaining read, so reading the past-8 (low-scan-pos) remainings
        // before some of the high-scan-pos g1 remainings — as the old code
        // accidentally did — gives the wrong rice trajectory and corrupts the
        // bit count from then on. This is Bug #4m (was masked when bug #4l
        // gave us a different off-by-one trade).
        //
        // Per spec section 7.3.8.11:
        //   - Positions 0..7 (in reverse scan) get a remaining only when
        //     baseLevel == threshold:
        //       * If position == firstG1: threshold = 3 (matches only when
        //         g2_flag == 1, since baseLevel = 1 + g1(=1) + g2)
        //       * Other g1==1 positions: threshold = 2 (matches; baseLevel = 1+1)
        //       * g1==0 positions: baseLevel = 1, threshold = 2, no remaining
        //   - Positions 8+ (in reverse scan): always remaining; baseLevel = 1.
        var rice_param: u32 = 0;
        var sig_visited: u32 = 0;
        var r_scan_i: u32 = first_scan_pos + 1;
        var remainings_this_sb: u32 = 0;
        while (r_scan_i > 0) : (r_scan_i -= 1) {
            if (!engine.valid) return;
            const sp = r_scan_i - 1;
            if (!sig_flags[sp]) continue;
            const is_first_8 = sig_visited < 8;
            sig_visited += 1;

            var coeff_base: u32 = 1;
            var needs_remaining = false;
            if (is_first_8) {
                if (g1_flags_pos[sp]) {
                    if (sp == first_greater1_scan_pos) {
                        // firstG1: threshold 3 — needs remaining iff g2==1
                        if (has_greater2) {
                            coeff_base = 3;
                            needs_remaining = true;
                        }
                    } else {
                        // other g1==1: threshold 2, baseLevel = 1+1 = 2, matches
                        coeff_base = 2;
                        needs_remaining = true;
                    }
                }
                // g1==0 in first 8: baseLevel = 1, no remaining.
            } else {
                // Past-8: always remaining, baseLevel = 1.
                coeff_base = 1;
                needs_remaining = true;
            }

            if (!needs_remaining) continue;

            const decoded_val = decodeCoeffAbsLevelRemainingVal(engine, rice_param);
            if (!engine.valid) return;
            remainings_this_sb += 1;
            const abs_level = coeff_base + decoded_val;

            // Rice parameter update per spec 9.3.3.9 / ffmpeg cabac.c:1376.
            if (abs_level > 3 * (@as(u32, 1) << @intCast(rice_param))) {
                if (rice_param < 4) rice_param += 1;
            }
        }
        tu_remaining_total += remainings_this_sb;
    }
}

/// Get the sub-block scan table for a given sub-block dimension and scan type.
/// For 2x2 sub-block arrays (8x8 TBs), the scan order depends on scan_idx:
/// DIAG and HORIZ produce identical 2x2 scans; only VERT differs. For larger
/// sub-block arrays (16x16 and 32x32 TBs), only DIAG is valid per spec
/// (non-DIAG scans are restricted to log2_trafo_size < 4).
fn getSubBlockScan(num_sb_side: u32, scan_idx: ScanType) []const [2]u8 {
    return switch (num_sb_side) {
        1 => &[_][2]u8{.{ 0, 0 }},
        2 => switch (scan_idx) {
            .diag, .horiz => &diag_scan_2x2,
            .vert => &vert_scan_2x2,
        },
        4 => &diag_scan_4x4_sb,
        8 => &diag_scan_8x8_sb,
        else => &[_][2]u8{.{ 0, 0 }},
    };
}

/// Get the within-sub-block (4x4 coefficient positions) scan table for the
/// given scan type. Affects residualCoding's position iteration.
fn getWithinSbScan(scan_idx: ScanType) *const [16][2]u8 {
    return switch (scan_idx) {
        .diag => &diag_scan_4x4,
        .horiz => &horiz_scan_4x4,
        .vert => &vert_scan_4x4,
    };
}

/// Find the scan index of a sub-block at position (x,y).
fn findSubBlockScanIdx(scan: []const [2]u8, total: u32, x: u8, y: u8) ?u32 {
    for (scan, 0..) |sb, i| {
        if (i >= total) break;
        if (sb[0] == x and sb[1] == y) return @intCast(i);
    }
    return null;
}

/// Decode last_sig_coeff prefix only (context-coded). Spec section 7.3.8.11
/// requires prefix-X, prefix-Y, then suffix-X, then suffix-Y — calling this
/// for X and Y separately and decoding suffixes via `lastSigCoeffSuffixBits`
/// reproduces the spec interleaving.
fn decodeLastSigCoeffPrefix(engine: *H265CabacEngine, log2_tb_size: u32, is_luma: bool, is_x: bool) u32 {
    if (!engine.valid) return 0;

    // Context offset depends on TU size and luma/chroma — Table 9-38/9-39
    const ctx_offset: u16 = getLastSigCoeffCtxOffset(log2_tb_size, is_luma);
    const ctx_shift: u32 = getLastSigCoeffCtxShift(log2_tb_size, is_luma);

    // Use correct base context for X vs Y
    const base_ctx: u16 = if (is_x)
        h265_tables.CTX_LAST_SIG_COEFF_X_PREFIX
    else
        h265_tables.CTX_LAST_SIG_COEFF_Y_PREFIX;

    // Prefix: truncated unary
    const max_prefix = (log2_tb_size << 1) - 1;
    var prefix: u32 = 0;

    while (prefix < max_prefix) : (prefix += 1) {
        if (!engine.valid) return 0;
        // Context index: offset + (prefix >> shift)
        const ctx_inc: u16 = @intCast(ctx_offset + (prefix >> @intCast(ctx_shift)));
        const ctx: u16 = base_ctx + @min(ctx_inc, 17);
        const bin = engine.decodeBin(ctx);
        if (bin == 0) break;
    }
    return prefix;
}

/// Number of bypass suffix bits required for a given last_sig_coeff prefix.
/// Returns 0 for prefix ≤ 3 (no suffix).
fn lastSigCoeffSuffixBits(prefix: u32) u32 {
    if (prefix < 4) return 0;
    return (prefix >> 1) - 1;
}

/// Combine prefix + already-decoded suffix into the final last_sig_coeff_x
/// or _y value, per spec section 7.4.9.11.
fn combineLastSigCoeff(prefix: u32, suffix: u32) u32 {
    if (prefix < 2) return prefix;
    const suffix_bits = lastSigCoeffSuffixBits(prefix);
    if (suffix_bits == 0) {
        // prefix in {2, 3} — value is simply the prefix.
        return prefix;
    }
    const shift: u5 = @intCast(suffix_bits);
    return (@as(u32, 1) << shift) * (2 + (prefix & 1)) + suffix;
}

/// Context offset for last sig coeff — Table 9-38/9-39
fn getLastSigCoeffCtxOffset(log2_tb_size: u32, is_luma: bool) u16 {
    if (!is_luma) return 15; // Chroma: fixed offset
    return switch (log2_tb_size) {
        2 => 0, // 4x4: contexts 0-2
        3 => 3, // 8x8: contexts 3-5
        4 => 6, // 16x16: contexts 6-9
        5 => 10, // 32x32: contexts 10-13
        else => 0,
    };
}

/// Context shift for last sig coeff — Table 9-38/9-39
fn getLastSigCoeffCtxShift(log2_tb_size: u32, is_luma: bool) u32 {
    if (!is_luma) return 0;
    return switch (log2_tb_size) {
        2 => 0, // 4x4
        3 => 0, // 8x8
        4 => 1, // 16x16: every 2 prefix bins share a context
        5 => 1, // 32x32: every 2 prefix bins share a context
        else => 0,
    };
}

/// sig_coeff_flag context derivation — Section 9.3.3.1.4
fn getSigCoeffCtxSpec(
    local_x: u32,
    local_y: u32,
    sb_x: u32,
    sb_y: u32,
    is_luma: bool,
    log2_tb_size: u32,
    scan_pos: u32,
    coded_sb_flags: *const [64]bool,
    num_sb_side: u32,
    sb_scan: []const [2]u8,
    total_sub_blocks: u32,
) u16 {
    _ = scan_pos; // unused in spec-correct derivation; kept for API stability
    // For 4x4 TBs: position-based context, spec Table 9-19 ctxIdxMap[y][x].
    // The previous code used min(scan_pos, 8) which is the WRONG indexing
    // (scan order, not raster position) — affected the overwhelming
    // majority of TUs in typical encodes since 4x4 is the most common TU
    // size at moderate-to-high QPs. Luma ctx range 0-8; chroma ctx range
    // 27-35 per spec offsets.
    const ctx_idx_map_4x4 = [4][4]u8{
        .{ 0, 1, 4, 5 },
        .{ 2, 3, 4, 5 },
        .{ 6, 6, 8, 8 },
        .{ 7, 7, 8, 8 },
    };
    if (log2_tb_size == 2) {
        const base: u32 = ctx_idx_map_4x4[local_y][local_x];
        return @intCast(if (is_luma) base else base + 27);
    }

    // For larger TBs, context depends on position and neighbor sub-blocks
    const prev_csb_right: bool = if (sb_x + 1 < num_sb_side)
        if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x + 1), @intCast(sb_y))) |idx|
            coded_sb_flags[idx]
        else
            false
    else
        false;

    const prev_csb_below: bool = if (sb_y + 1 < num_sb_side)
        if (findSubBlockScanIdx(sb_scan, total_sub_blocks, @intCast(sb_x), @intCast(sb_y + 1))) |idx|
            coded_sb_flags[idx]
        else
            false
    else
        false;

    // sigCtx derivation per Section 9.3.3.1.4
    var sig_ctx: u32 = 0;
    const sum_xy: u32 = local_x + local_y;
    const clamped_sum: u32 = if (sum_xy > 2) 2 else sum_xy;

    if (sum_xy == 0) {
        // DC position within sub-block
        sig_ctx = 0;
    } else if (sb_x == 0 and sb_y == 0) {
        // DC sub-block (sub-block at top-left)
        sig_ctx = clamped_sum;
        if (is_luma) {
            sig_ctx += if (log2_tb_size == 3) @as(u32, 9) else @as(u32, 21);
        }
    } else {
        // Non-DC sub-block
        const prev_cg_flag: u32 = @as(u32, @intFromBool(prev_csb_right)) + @as(u32, @intFromBool(prev_csb_below));
        const base_offset: u32 = if (is_luma) (if (log2_tb_size == 3) @as(u32, 9) else @as(u32, 21)) else @as(u32, 0);
        const cg_offset: u32 = if (prev_cg_flag == 0) @as(u32, 0) else if (prev_cg_flag == 1) @as(u32, 3) else @as(u32, 6);
        sig_ctx = clamped_sum + cg_offset + base_offset;
    }

    // Offset for chroma
    if (!is_luma) {
        sig_ctx += 27;
    }

    return @intCast(if (sig_ctx > 43) @as(u32, 43) else sig_ctx);
}

/// Decode coeff_abs_level_remaining per H.265 spec section 9.3.3.10 / x265
/// encoder entropy.cpp:1877 / ffmpeg cabac.c:941.
///
/// COEF_REMAIN_BIN_REDUCTION = 3 (NOT 4!). The prefix is unbounded unary
/// terminated by a 0 bit — there is ALWAYS a terminator (the spec's TR
/// "no terminator when prefixVal >= cMax" rule turns out NOT to apply in
/// this context as both x265 and ffmpeg encode/decode it). The prior
/// implementation capped the prefix loop at 4 and used a different escape
/// formula, reading 1 fewer bit per value >= 4. Cross-verified against
/// both x265's encoder (writes 6 bits for value=4 cRP=0 — see x265
/// `writeCoefRemainExGolomb` with `((1 << (3 + length + 1)) - 2)`) and
/// ffmpeg's decoder (`prefix < 3` branch / `prefix_minus3` escape).
///
/// Bit consumption per value at cRiceParam=0:
///   0 → 1 bit  ("0")
///   1 → 2 bits ("10")
///   2 → 3 bits ("110")
///   3 → 4 bits ("1110")        ← still simple path in our terms, escape in ffmpeg's
///   4 → 6 bits ("111100")      ← was 5 in old code — 1 bit short
///   5 → 6 bits ("111101")
///   6..9   → 8 bits
///   10..17 → 10 bits           etc.
fn decodeCoeffAbsLevelRemainingVal(engine: *H265CabacEngine, rice_param: u32) u32 {
    if (!engine.valid) return 0;

    // Read unary prefix until 0 bit (or CABAC_MAX_BIN safety cap).
    const MAX_BIN: u32 = 31;
    var prefix: u32 = 0;
    while (prefix < MAX_BIN) : (prefix += 1) {
        if (engine.decodeBypass() == 0) break;
        if (!engine.valid) return 0;
    }
    if (!engine.valid) return 0;

    if (prefix < 3) {
        // Simple Rice path: value = (prefix << cRP) + cRP-bit suffix
        var suffix: u32 = 0;
        if (rice_param > 0) {
            suffix = engine.decodeBypassBits(rice_param);
            if (!engine.valid) return 0;
        }
        return (prefix << @intCast(rice_param)) + suffix;
    } else {
        // Escape: read (prefix - 3 + cRP) suffix bits.
        // value = (((1 << (prefix-3)) + 3 - 1) << cRP) + suffix
        //       = ((1 << (prefix-3)) + 2) << cRP + suffix
        const prefix_minus3 = prefix - 3;
        const suffix_bits = prefix_minus3 + rice_param;
        const suffix = engine.decodeBypassBits(suffix_bits);
        if (!engine.valid) return 0;
        return ((@as(u32, 1) << @intCast(prefix_minus3)) + 2) << @intCast(rice_param) | suffix;
    }
}


// ============================================================================
// Public API
// ============================================================================

pub const CabacDecodeResult = struct {
    ctus_decoded: u32,
    terminated_cleanly: bool, // end_of_slice_segment_flag was 1
    bits_remaining: usize, // bits left in RBSP after decode
    total_rbsp_bits: usize, // total RBSP bits (after header)
    engine_valid: bool, // CABAC engine still in valid state
    // Diagnostic counters — used by VALIDATE_TRACE_H265_CABAC to figure out
    // which syntax-element family is consuming bins. No spec semantics; safe
    // to ignore.
    context_bins: u32 = 0,
    bypass_bins: u32 = 0,
    terminate_bins: u32 = 0,
    residual_calls: u32 = 0,
    residual_sig_total: u32 = 0,
    residual_greater1_total: u32 = 0,
    residual_remaining_total: u32 = 0,
};

/// Validate CABAC-encoded slice data for an H.265 intra slice.
/// Returns detailed decode result including CTU count, termination state,
/// and bit position for corruption detection.
pub fn validateH265IntraCabac(
    rbsp: []const u8,
    header_bits: usize,
    info: *const H265SliceDecodeInfo,
) CabacDecodeResult {
    const fail_result = CabacDecodeResult{
        .ctus_decoded = 0,
        .terminated_cleanly = false,
        .bits_remaining = 0,
        .total_rbsp_bits = 0,
        .engine_valid = false,
    };

    // Helper: build a CabacDecodeResult that carries the engine's diagnostic
    // counters (context_bins, bypass_bins, etc.) in addition to the
    // verdict-level fields. Eliminates ~80 lines of struct-init duplication
    // across early returns.
    const buildResult = struct {
        fn call(eng: *const H265CabacEngine, ctus: u32, terminated: bool, bits_left: usize, total_bits: usize, valid_override: ?bool) CabacDecodeResult {
            return .{
                .ctus_decoded = ctus,
                .terminated_cleanly = terminated,
                .bits_remaining = bits_left,
                .total_rbsp_bits = total_bits,
                .engine_valid = valid_override orelse eng.valid,
                .context_bins = eng.context_bins,
                .bypass_bins = eng.bypass_bins,
                .terminate_bins = eng.terminate_bins,
                .residual_calls = eng.residual_calls,
                .residual_sig_total = eng.residual_sig_total,
                .residual_greater1_total = eng.residual_greater1_total,
                .residual_remaining_total = eng.residual_remaining_total,
            };
        }
    }.call;

    var reader = BitReader.init(rbsp);

    if (!reader.skipBits(header_bits)) return fail_result;
    reader.alignToByte();

    const cabac_start_bits = reader.remainingBits();
    // DEBUG: dump byte_pos + first 4 bytes at CABAC entry point so we can
    // verify against libde265's CABAC starting position.
    if (trace.isEnabled(.h265_bins)) {
        const byte_pos: u32 = @intCast((rbsp.len * 8 - cabac_start_bits) / 8);
        const remaining_bytes = rbsp.len -| byte_pos;
        const b0: u8 = if (remaining_bytes >= 1) rbsp[byte_pos] else 0;
        const b1: u8 = if (remaining_bytes >= 2) rbsp[byte_pos + 1] else 0;
        const b2: u8 = if (remaining_bytes >= 3) rbsp[byte_pos + 2] else 0;
        const b3: u8 = if (remaining_bytes >= 4) rbsp[byte_pos + 3] else 0;
        trace.print(.h265_bins, "CABAC_ENTRY byte_pos={d} first_bytes={x} {x} {x} {x} header_bits={d}", .{
            byte_pos, b0, b1, b2, b3, header_bits,
        });
    }

    var engine = H265CabacEngine.init(&reader, info.slice_qp);
    if (!engine.valid) return fail_result;
    if (engine.cod_i_range < 256) return fail_result;

    var ctu_rs_addr: u32 = 0;
    const total_ctus = info.pic_width_in_ctbs * info.pic_height_in_ctbs;
    if (total_ctus == 0) return fail_result;

    const max_ctus: u32 = @min(total_ctus, 1024);

    // Per-slice context maps for spec-correct context derivation:
    // - depth_map (Bug #4h): per min-CB, for split_cu_flag ctxInc
    // - intra_mode_map (Bug #4j): per min-PU (4x4), for scan_idx
    // Both alloc failures are non-fatal — callers fall back to
    // approximations when null rather than break.
    const log2_min_cb_u: u5 = @intCast(info.log2_min_cb_size);
    const min_cb_size: u32 = @as(u32, 1) << log2_min_cb_u;
    const pic_w_min_cbs: u32 = (info.pic_width_in_luma + min_cb_size - 1) >> log2_min_cb_u;
    const pic_h_min_cbs: u32 = (info.pic_height_in_luma + min_cb_size - 1) >> log2_min_cb_u;
    // Min PU size is always 4x4 in HEVC (log2_min_pu = 2).
    const pic_w_min_pus: u32 = (info.pic_width_in_luma + 3) >> 2;
    const pic_h_min_pus: u32 = (info.pic_height_in_luma + 3) >> 2;
    const slice_allocator = heap.validateAllocator();
    const depth_map: ?[]u8 = blk: {
        if (pic_w_min_cbs == 0 or pic_h_min_cbs == 0) break :blk null;
        const buf = slice_allocator.alloc(u8, @as(usize, pic_w_min_cbs) * @as(usize, pic_h_min_cbs)) catch break :blk null;
        @memset(buf, 0);
        break :blk buf;
    };
    defer if (depth_map) |dm| slice_allocator.free(dm);
    const intra_mode_map: ?[]u8 = blk: {
        if (pic_w_min_pus == 0 or pic_h_min_pus == 0) break :blk null;
        const buf = slice_allocator.alloc(u8, @as(usize, pic_w_min_pus) * @as(usize, pic_h_min_pus)) catch break :blk null;
        // Initialize all positions to INTRA_DC. Per spec, unavailable
        // neighbors (out-of-slice / not-yet-decoded) are treated as DC.
        @memset(buf, INTRA_DC);
        break :blk buf;
    };
    defer if (intra_mode_map) |m| slice_allocator.free(m);
    const chroma_mode_map: ?[]u8 = blk: {
        if (pic_w_min_pus == 0 or pic_h_min_pus == 0) break :blk null;
        const buf = slice_allocator.alloc(u8, @as(usize, pic_w_min_pus) * @as(usize, pic_h_min_pus)) catch break :blk null;
        @memset(buf, INTRA_DC);
        break :blk buf;
    };
    defer if (chroma_mode_map) |m| slice_allocator.free(m);

    var slice_ctx = SliceCtx{
        .depth_map = depth_map,
        .pic_w_min_cbs = pic_w_min_cbs,
        .pic_h_min_cbs = pic_h_min_cbs,
        .log2_min_cb = log2_min_cb_u,
        .intra_mode_map = intra_mode_map,
        .chroma_mode_map = chroma_mode_map,
        .pic_w_min_pus = pic_w_min_pus,
        .pic_h_min_pus = pic_h_min_pus,
        .log2_ctb = @intCast(info.log2_ctb_size),
    };

    const trace_cabac = trace.isEnabled(.h265_cabac);
    if (trace_cabac) trace.print(.h265_cabac, "slice_enter total_ctus={d} max_ctus={d} pic_w_ctbs={d} pic_h_ctbs={d} log2_ctb={d} rbsp_bits={d} qp={d} sao={} pcm={}", .{
        total_ctus, max_ctus, info.pic_width_in_ctbs, info.pic_height_in_ctbs, info.log2_ctb_size, cabac_start_bits, info.slice_qp, info.sao_enabled, info.pcm_enabled,
    });

    while (ctu_rs_addr < max_ctus) : (ctu_rs_addr += 1) {
        const bits_at_ctu_start = reader.remainingBits();
        if (!engine.valid) {
            if (trace_cabac) trace.print(.h265_cabac, "ctu_invalid ctu={d} bits_remain={d}", .{ ctu_rs_addr, bits_at_ctu_start });
            return buildResult(&engine, ctu_rs_addr, false, bits_at_ctu_start, cabac_start_bits, false);
        }
        if (reader.remainingBits() < 2) {
            if (trace_cabac) trace.print(.h265_cabac, "ctu_underflow ctu={d} bits_remain={d}", .{ ctu_rs_addr, bits_at_ctu_start });
            break;
        }

        const rx = ctu_rs_addr % info.pic_width_in_ctbs;
        const ry = ctu_rs_addr / info.pic_width_in_ctbs;
        if (info.log2_ctb_size > 31) return fail_result;
        const x0 = rx << @intCast(info.log2_ctb_size);
        const y0 = ry << @intCast(info.log2_ctb_size);

        if (info.sao_enabled) {
            parseSaoParams(&engine, info, rx, ry);
            if (!engine.valid) {
                if (trace_cabac) trace.print(.h265_cabac, "ctu_fail_sao ctu={d} bits_remain={d}", .{ ctu_rs_addr, reader.remainingBits() });
                return buildResult(&engine, ctu_rs_addr, false, reader.remainingBits(), cabac_start_bits, false);
            }
        }

        codingQuadtree(&engine, info, x0, y0, info.log2_ctb_size, 0, &slice_ctx);
        if (!engine.valid) {
            if (trace_cabac) trace.print(.h265_cabac, "ctu_fail_quadtree ctu={d} bits_remain={d}", .{ ctu_rs_addr, reader.remainingBits() });
            return buildResult(&engine, ctu_rs_addr, false, reader.remainingBits(), cabac_start_bits, false);
        }

        const bits_after_quadtree = reader.remainingBits();
        const terminate = engine.decodeTerminate();
        if (trace_cabac) trace.print(.h265_cabac, "ctu ctu={d}/{d} x0={d} y0={d} bits_in={d} bits_after_quadtree={d} bits_after_term={d} term={d} valid={}", .{
            ctu_rs_addr, total_ctus, x0, y0, bits_at_ctu_start, bits_after_quadtree, reader.remainingBits(), terminate, engine.valid,
        });
        if (terminate == 1) {
            return buildResult(&engine, ctu_rs_addr + 1, true, reader.remainingBits(), cabac_start_bits, null);
        }
        if (!engine.valid) return buildResult(&engine, ctu_rs_addr, false, reader.remainingBits(), cabac_start_bits, false);
    }

    if (trace_cabac) trace.print(.h265_cabac, "slice_exit_loop ctus_done={d} max={d} bits_remain={d} engine_valid={} ctx_bins={d} bypass_bins={d} term_bins={d} resid_calls={d} resid_sig={d} resid_g1={d} resid_rem={d}", .{
        ctu_rs_addr, max_ctus, reader.remainingBits(), engine.valid,
        engine.context_bins, engine.bypass_bins, engine.terminate_bins,
        engine.residual_calls, engine.residual_sig_total, engine.residual_greater1_total, engine.residual_remaining_total,
    });

    return buildResult(&engine, ctu_rs_addr, false, reader.remainingBits(), cabac_start_bits, null);
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

test "diagonal scan 4x4 covers all positions" {
    var seen = [_]bool{false} ** 16;
    for (diag_scan_4x4) |pos| {
        const idx = @as(usize, pos[1]) * 4 + pos[0];
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "diagonal scan 8x8 covers all positions" {
    var seen = [_]bool{false} ** 64;
    for (diag_scan_8x8_sb) |pos| {
        const idx = @as(usize, pos[1]) * 8 + pos[0];
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}
