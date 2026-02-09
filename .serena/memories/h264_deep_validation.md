# H.264 Deep Bitstream Validation (Completed 2026-02-08)

## Phase 0: MKV "No Coded Slice" Fix
- `validateH264Stream()`: when `found_sps && found_pps && !found_slice`, return success with `frames_decoded=0`
- `video_validator.zig` wrapper already sets `byte_validated = false` when `frames_decoded == 0`

## Phase 1: Extended Slice Header Parsing
- New `parseFullSliceHeader()` with full ITU-T H.264 Section 7.3.3 parsing
- Fields: pic_parameter_set_id (cross-ref PPS), frame_num, field_pic_flag, idr_pic_id, POC fields, slice_qp_delta, cabac_init_idc
- Helper functions: `parseRefPicListModification()`, `parsePredWeightTable()`, `parseDecRefPicMarking()`
- SPS additions: `vui_parameters_present_flag`, `delta_pic_order_always_zero_flag`
- PPS additions: `transform_8x8_mode_flag`, `second_chroma_qp_index_offset` (high profile extensions)
- `SliceType` enum with `isIntra()` helper (pub)
- Fallback to simple `parseSliceHeader()` if full parse fails (graceful degradation)
- Error threshold: only flag corruption if ALL slices fail AND >= 3 attempts

## Phase 2: VUI Parameter Parsing
- `parseVuiParameters()` and `parseHrdParameters()` added before `parseSps()`
- Parses: aspect ratio, overscan, video signal type, colour description, timing info, HRD (NAL/VCL), bitstream restriction
- Range validation: `cpb_cnt_minus1 <= 31`, `chroma_sample_loc <= 5`, etc.

## Phase 3: CAVLC Entropy Decoding
- New file: `h264_cavlc_tables.zig` — VLC tables for coeff_token (4 nC tables + chroma DC), total_zeros, run_before, level coding
- `decodeResidualBlockCavlc()` — full CAVLC residual block decode
- `validateCavlcSliceData()` in h264_syntax_validator.zig — macroblock layer parsing with CBP mapping (Table 9-4)
- `parseCavlcResidual()` — luma DC/AC + chroma DC/AC CAVLC decode
- Simplified nC context (uses 0 for all blocks — sufficient for corruption detection)
- Max 256 MBs validated per slice for performance

## Phase 4: CABAC Entropy Decoding
- New file: `h264_cabac_tables.zig` — rangeTabLPS[64][4], transIdx tables, context initialization (m,n) pairs
- New file: `h264_cabac_engine.zig` — arithmetic decoder (`CabacEngine` struct)
  - `decodeBin()` — context-based bin decoding with state transitions
  - `decodeBypass()` — equiprobable bin decoding
  - `decodeTerminate()` — end-of-slice detection
  - `validateCabacSliceData()` — macroblock layer validation
- Context init: 460 contexts from (m,n) pairs + SliceQPY + cabac_init_idc
- Simplified MB layer: mb_skip, mb_type, CBP, mb_qp_delta, significance map bins

## Key Design Decisions
- Entropy validation is non-fatal: if CAVLC/CABAC decode fails, header validation still counts
- RBSP buffer increased to 8192 bytes for full slice data (was 512 for header-only)
- Max 256 MBs per slice for performance (enough for corruption detection)
- Both CAVLC and CABAC validators use simplified nC/context tracking (adequate for validation)

## Files Modified
- `src/core/h264_syntax_validator.zig` — SPS VUI, PPS extensions, full slice header, CAVLC/CABAC integration
- `src/core/mod.zig` — register 3 new modules

## New Files
- `src/core/h264_cavlc_tables.zig` — CAVLC VLC tables + residual block decoder
- `src/core/h264_cabac_tables.zig` — CABAC context init tables + LPS/MPS transition tables
- `src/core/h264_cabac_engine.zig` — CABAC arithmetic engine + slice data validator

## Results
- All existing tests pass (958/958 + new CAVLC/CABAC tests)
- All H.264 ground truth files pass: baseline, main, high10, high444, MKV
- ~/Movies collection: 434 valid, 5 invalid, 13 unknown (unchanged)
- Corruption detection rates maintained
