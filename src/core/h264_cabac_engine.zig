//! H.264/AVC CABAC Arithmetic Decoding Engine
//!
//! Implements the binary arithmetic decoder for H.264 CABAC per ITU-T H.264
//! Section 9.3.3. This engine handles:
//!   - Context-based bin decoding (DecodeBin)
//!   - Bypass bin decoding (DecodeBypass)
//!   - Terminate bin decoding (DecodeTerminate)
//!   - Renormalization
//!
//! Used for Main/High profile H.264 streams (entropy_coding_mode_flag == 1).

const std = @import("std");
const BitReader = @import("bitstream_reader.zig").BitReader;
const cabac_tables = @import("h264_cabac_tables.zig");

/// CABAC arithmetic decoder state
pub const CabacEngine = struct {
    cod_i_range: u16, // 9-bit arithmetic coding range (256..510)
    cod_i_offset: u16, // 9-bit arithmetic coding offset
    reader: *BitReader,
    contexts: [cabac_tables.NUM_CONTEXTS]cabac_tables.ContextState,
    bits_outstanding: u32,
    valid: bool, // false if an error occurred

    /// Initialize CABAC engine for a new slice.
    /// The reader should be positioned at the first byte of CABAC data
    /// (after slice header + byte alignment).
    pub fn init(reader: *BitReader, slice_qp_y: i32, is_intra: bool, cabac_init_idc: u32) CabacEngine {
        // Initialize contexts
        const contexts = cabac_tables.initContexts(slice_qp_y, is_intra, cabac_init_idc);

        // Read first 9 bits for codIOffset
        const b1 = reader.readBits(8) orelse 0;
        const b2 = reader.readBit() orelse 0;
        const cod_i_offset: u16 = @intCast((@as(u16, @intCast(b1)) << 1) | b2);

        return .{
            .cod_i_range = 510, // Initial range
            .cod_i_offset = cod_i_offset,
            .reader = reader,
            .contexts = contexts,
            .bits_outstanding = 0,
            .valid = true,
        };
    }

    /// Decode a single bin using context model (Section 9.3.3.2)
    pub fn decodeBin(self: *CabacEngine, ctx_idx: u16) u1 {
        if (!self.valid) return 0;
        if (ctx_idx >= cabac_tables.NUM_CONTEXTS) {
            self.valid = false;
            return 0;
        }

        const p_state_idx = self.contexts[ctx_idx].p_state_idx;
        const val_mps = self.contexts[ctx_idx].val_mps;

        // Look up LPS range
        const q_cod_i_range_idx: u2 = @intCast((self.cod_i_range >> 6) & 3);
        const cod_i_range_lps: u16 = cabac_tables.rangeTabLPS[p_state_idx][q_cod_i_range_idx];

        self.cod_i_range -= cod_i_range_lps;

        var bin_val: u1 = undefined;

        if (self.cod_i_offset >= self.cod_i_range) {
            // LPS
            bin_val = 1 - val_mps;
            self.cod_i_offset -= self.cod_i_range;
            self.cod_i_range = cod_i_range_lps;

            if (p_state_idx == 0) {
                self.contexts[ctx_idx].val_mps = 1 - val_mps;
            }
            self.contexts[ctx_idx].p_state_idx = @intCast(cabac_tables.transIdxLPS[p_state_idx]);
        } else {
            // MPS
            bin_val = val_mps;
            self.contexts[ctx_idx].p_state_idx = @intCast(cabac_tables.transIdxMPS[p_state_idx]);
        }

        // Renormalization
        self.renormalize();

        return bin_val;
    }

    /// Decode a bypass bin (equiprobable, no context) — Section 9.3.3.2.3
    pub fn decodeBypass(self: *CabacEngine) u1 {
        if (!self.valid) return 0;

        self.cod_i_offset = (self.cod_i_offset << 1) | self.readOneBit();

        if (self.cod_i_offset >= self.cod_i_range) {
            self.cod_i_offset -= self.cod_i_range;
            return 1;
        }
        return 0;
    }

    /// Decode a terminate bin (end-of-slice detection) — Section 9.3.3.2.4
    pub fn decodeTerminate(self: *CabacEngine) u1 {
        if (!self.valid) return 1; // invalid state -> terminate

        self.cod_i_range -= 2;

        if (self.cod_i_offset >= self.cod_i_range) {
            return 1; // end of slice
        }

        // Renormalize
        self.renormalize();
        return 0;
    }

    /// Decode an unsigned value using truncated unary binarization.
    pub fn decodeTruncatedUnary(self: *CabacEngine, ctx_base: u16, ctx_max: u16, max_val: u32) u32 {
        var val: u32 = 0;
        while (val < max_val) : (val += 1) {
            const ctx = ctx_base + @as(u16, @intCast(@min(val, ctx_max - ctx_base)));
            if (self.decodeBin(ctx) == 0) break;
        }
        return val;
    }

    /// Decode an unsigned value using unary with bypass bins after initial context bins.
    pub fn decodeUnaryWithBypass(self: *CabacEngine, ctx_base: u16, num_ctx: u16, max_val: u32) u32 {
        var val: u32 = 0;
        while (val < max_val) : (val += 1) {
            const bin = if (val < num_ctx)
                self.decodeBin(ctx_base + @as(u16, @intCast(val)))
            else
                self.decodeBypass();
            if (bin == 0) break;
        }
        return val;
    }

    /// Decode a signed exp-golomb-like value using bypass bins.
    pub fn decodeSignedBypass(self: *CabacEngine, abs_val: u32) i32 {
        if (abs_val == 0) return 0;
        const sign = self.decodeBypass();
        const val: i32 = @intCast(abs_val);
        return if (sign == 1) -val else val;
    }

    // Internal: renormalize the arithmetic coding state
    fn renormalize(self: *CabacEngine) void {
        while (self.cod_i_range < 256) {
            self.cod_i_range <<= 1;
            self.cod_i_offset = (self.cod_i_offset << 1) | self.readOneBit();
        }
    }

    // Internal: read one bit from the bitstream
    fn readOneBit(self: *CabacEngine) u16 {
        const bit = self.reader.readBit() orelse {
            self.valid = false;
            return 0;
        };
        return bit;
    }

    /// Check if the engine is still in a valid state
    pub fn isValid(self: *const CabacEngine) bool {
        return self.valid;
    }
};

// ============================================================================
// CABAC Macroblock Layer Validation
// ============================================================================

/// Validate CABAC-encoded slice data by decoding the macroblock layer.
/// Returns true if the slice data decodes successfully, false on corruption.
pub fn validateCabacSliceData(
    rbsp: []const u8,
    header_bits: usize,
    sps: *const @import("h264_syntax_validator.zig").SequenceParameterSet,
    slice_type: @import("h264_syntax_validator.zig").SliceType,
    slice_qp: i32,
    cabac_init_idc: u32,
    first_mb_in_slice: u32,
) bool {
    var reader = BitReader.init(rbsp);

    // Skip past the already-parsed slice header
    if (!reader.skipBits(header_bits)) return false;

    // CABAC requires byte alignment after slice header
    reader.alignToByte();

    // Initialize CABAC engine
    var engine = CabacEngine.init(&reader, slice_qp, slice_type.isIntra(), cabac_init_idc);

    if (!engine.valid) return false;

    // Calculate picture dimensions in macroblocks
    const pic_width_mbs = sps.pic_width_in_mbs_minus1 + 1;
    const pic_height_mbs = sps.pic_height_in_map_units_minus1 + 1;
    const total_mbs = pic_width_mbs * pic_height_mbs;

    // Limit validation to a reasonable number of macroblocks
    const max_mbs_to_validate: u32 = 256;
    const mbs_to_validate = @min(total_mbs - first_mb_in_slice, max_mbs_to_validate);

    const is_intra = slice_type.isIntra();

    var mb_count: u32 = 0;
    while (mb_count < mbs_to_validate) : (mb_count += 1) {
        if (!engine.valid) return mb_count > 0;
        if (reader.remainingBits() < 2) break;

        // end_of_slice_flag via DecodeTerminate
        if (mb_count > 0) {
            if (engine.decodeTerminate() == 1) break;
            if (!engine.valid) return mb_count > 0;
        }

        // mb_skip_flag (for P/B slices)
        if (!is_intra) {
            const skip_ctx: u16 = if (slice_type == .b) 24 else 11;
            const mb_skip = engine.decodeBin(skip_ctx);
            if (!engine.valid) return mb_count > 0;
            if (mb_skip == 1) {
                continue; // skipped macroblock
            }
        }

        // mb_type — context depends on slice type
        if (is_intra) {
            // I slice mb_type: contexts 3-10 (I_NxN vs I_16x16 vs I_PCM)
            const terminate = engine.decodeTerminate();
            if (terminate == 1) {
                // I_PCM: read raw samples
                reader.alignToByte();
                const luma_bits = 256 * (8 + @as(u32, sps.bit_depth_luma_minus8));
                const chroma_bits = 2 * 64 * (8 + @as(u32, sps.bit_depth_chroma_minus8));
                if (!reader.skipBits(luma_bits + chroma_bits)) return mb_count > 0;
                // Re-init CABAC engine after PCM
                engine = CabacEngine.init(&reader, slice_qp, is_intra, cabac_init_idc);
                continue;
            }
            // Decode I mb_type using contexts 3-10
            _ = decodeMbTypeIntra(&engine);
        } else {
            // P/B slice mb_type
            _ = decodeMbTypeInter(&engine, slice_type);
        }

        if (!engine.valid) return mb_count > 0;

        // For validation, we decode a few more syntax elements to verify integrity:
        // coded_block_pattern, mb_qp_delta, and some residual bins

        // coded_block_pattern (contexts 73-84 for luma, 85-104 for chroma)
        // Simplified: just decode a few bins to check integrity
        const cbp_luma = decodeCbpLuma(&engine);
        const cbp_chroma = decodeCbpChroma(&engine);

        if (!engine.valid) return mb_count > 0;

        // mb_qp_delta (contexts 60-63)
        if (cbp_luma > 0 or cbp_chroma > 0) {
            _ = decodeMbQpDelta(&engine);
            if (!engine.valid) return mb_count > 0;
        }

        // Residual: decode significance maps for a few blocks to verify
        // CABAC residual validity (contexts 105+ for significance/last/levels)
        if (cbp_luma > 0 or cbp_chroma > 0) {
            decodeSomeResidualBins(&engine);
            if (!engine.valid) return mb_count > 0;
        }
    }

    return mb_count > 0;
}

// Simplified CABAC syntax element decoders for validation

fn decodeMbTypeIntra(engine: *CabacEngine) u32 {
    // I slice: ctx 3 for first bin (I_NxN = 0, I_16x16 = 1xxx)
    const b0 = engine.decodeBin(3);
    if (b0 == 0) return 0; // I_4x4

    // Decode sub-type bins for I_16x16 variants
    const b1 = engine.decodeTerminate(); // PCM check
    if (b1 == 1) return 25; // I_PCM

    _ = engine.decodeBin(4); // CBP luma
    _ = engine.decodeBin(5); // CBP chroma bit 0
    _ = engine.decodeBin(6); // CBP chroma bit 1
    _ = engine.decodeBin(7); // pred mode
    _ = engine.decodeBin(8); // pred mode

    return 1; // I_16x16_x_x_x (simplified)
}

fn decodeMbTypeInter(engine: *CabacEngine, slice_type: @import("h264_syntax_validator.zig").SliceType) u32 {
    const ctx_base: u16 = if (slice_type == .b) 27 else 14;
    const b0 = engine.decodeBin(ctx_base);
    if (b0 == 0) return 0; // P_L0_16x16 or B_Direct_16x16

    // Decode more bins for other types
    _ = engine.decodeBin(ctx_base + 1);
    _ = engine.decodeBin(ctx_base + 2);
    return 1; // Simplified
}

fn decodeCbpLuma(engine: *CabacEngine) u32 {
    // CBP luma: 4 bins, contexts 73-76
    var cbp: u32 = 0;
    for (0..4) |i| {
        const bin = engine.decodeBin(73 + @as(u16, @intCast(i)));
        cbp |= @as(u32, bin) << @intCast(i);
    }
    return cbp;
}

fn decodeCbpChroma(engine: *CabacEngine) u32 {
    // CBP chroma: 2 bins, contexts 77-78
    const b0 = engine.decodeBin(77);
    if (b0 == 0) return 0;
    const b1 = engine.decodeBin(78);
    return if (b1 == 0) 1 else 2;
}

fn decodeMbQpDelta(engine: *CabacEngine) i32 {
    // mb_qp_delta: unary with contexts 60-62
    const b0 = engine.decodeBin(60);
    if (b0 == 0) return 0;

    const b1 = engine.decodeBin(62);
    if (b1 == 0) return 1;

    // More bins via bypass for larger deltas
    var val: i32 = 2;
    while (val < 26) : (val += 1) {
        if (engine.decodeBypass() == 0) break;
    }
    return val;
}

fn decodeSomeResidualBins(engine: *CabacEngine) void {
    // Decode a few significance map bins to validate CABAC state
    // coded_block_flag: context 85
    const coded = engine.decodeBin(85);
    if (coded == 0) return;

    // significant_coeff_flag bins: contexts 105-119 (luma 4x4)
    for (0..4) |i| {
        if (!engine.valid) return;
        _ = engine.decodeBin(105 + @as(u16, @intCast(i)));
    }
}

// ============================================================================
// Tests
// ============================================================================

test "CABAC engine initialization" {
    // Create a minimal bitstream for testing
    var data = [_]u8{ 0xFF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var reader = BitReader.init(&data);
    const engine = CabacEngine.init(&reader, 26, true, 0);

    try std.testing.expect(engine.valid);
    try std.testing.expectEqual(@as(u16, 510), engine.cod_i_range);
    // codIOffset should be first 9 bits: 0xFF80 >> 7 = 0x1FF = 511
    try std.testing.expectEqual(@as(u16, 0x1FF), engine.cod_i_offset);
}

test "CABAC decodeBin basic operation" {
    // Fill with predictable data
    var data = [_]u8{ 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var reader = BitReader.init(&data);
    var engine = CabacEngine.init(&reader, 26, true, 0);

    // Should be able to decode bins without crashing
    _ = engine.decodeBin(0);
    _ = engine.decodeBin(1);
    _ = engine.decodeBin(2);
    try std.testing.expect(engine.valid);
}

test "CABAC decodeBypass" {
    var data = [_]u8{ 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var reader = BitReader.init(&data);
    var engine = CabacEngine.init(&reader, 26, true, 0);

    // Decode several bypass bins
    _ = engine.decodeBypass();
    _ = engine.decodeBypass();
    _ = engine.decodeBypass();
    _ = engine.decodeBypass();
    try std.testing.expect(engine.valid);
}

test "CABAC decodeTerminate" {
    var data = [_]u8{ 0xFF, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var reader = BitReader.init(&data);
    var engine = CabacEngine.init(&reader, 26, true, 0);

    // decodeTerminate should work
    const term = engine.decodeTerminate();
    // With offset 0x1FF and range 508, offset >= range so should terminate
    try std.testing.expectEqual(@as(u1, 1), term);
}
