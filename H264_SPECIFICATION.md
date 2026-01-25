# H.264/AVC Decoder Implementation Specification

**Version:** 1.0
**Date:** January 2026
**Author:** EntropyShield Project
**License Compliance:** This specification references ONLY non-GPL sources (ITU-T H.264 spec, BSD-licensed JM reference, academic papers)

---

## 1. Executive Summary

### 1.1 What is H.264/AVC?

H.264/AVC (Advanced Video Coding), also known as MPEG-4 Part 10, is the most widely deployed video compression standard in the world. Developed jointly by ITU-T Video Coding Experts Group (VCEG) and ISO/IEC Moving Picture Experts Group (MPEG), it achieves significant compression efficiency improvements over previous standards while maintaining reasonable decoder complexity.

### 1.2 Why We Need Our Own Decoder

The current codebase uses Cisco's OpenH264 for H.264 validation (`h264_validator.zig`), which:
- Only supports Baseline, Extended, and Main profiles (not High profiles)
- Cannot validate High 10, High 4:2:2, or High 4:4:4 Predictive content
- Is an external C++ dependency adding complexity to builds

A pure-Zig implementation provides:
- **Full profile support** including all High profiles (10-bit, 4:2:2, 4:4:4)
- **Consistent architecture** with existing pure-Zig decoders (VP8, MPEG-1/2, MPEG-4 Part 2, ProRes, Theora)
- **Validation-focused design** - decode enough to verify bitstream integrity without full pixel reconstruction
- **No external dependencies** - simpler builds, single source of truth

### 1.3 Scope

This specification covers implementation of a complete H.264/AVC decoder supporting:

| Profile | Level | Bit Depth | Chroma Format | Purpose |
|---------|-------|-----------|---------------|---------|
| Baseline | All | 8-bit | 4:2:0 | Mobile, real-time |
| Main | All | 8-bit | 4:2:0 | Broadcast, streaming |
| Extended | All | 8-bit | 4:2:0 | Streaming with SP/SI |
| High | All | 8-bit | 4:2:0 | HD broadcast, Blu-ray |
| High 10 | All | 10-bit | 4:2:0 | Professional video |
| High 4:2:2 | All | 10-bit | 4:2:2 | Professional, broadcast |
| High 4:4:4 Predictive | All | 14-bit | 4:4:4 | Professional, lossless |

**Out of scope:** Encoding, SVC (Scalable), MVC (Multiview/3D)

---

## 2. Architecture Overview

### 2.1 Decoder Pipeline

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           H.264 DECODER PIPELINE                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Input NAL Stream                                                            │
│       │                                                                      │
│       ▼                                                                      │
│  ┌─────────────────────┐                                                     │
│  │   NAL Unit Parser   │  Detect start codes, extract NAL units              │
│  │   (Annex B / AVCC)  │  Handle emulation prevention bytes                  │
│  └──────────┬──────────┘                                                     │
│             │                                                                │
│             ▼                                                                │
│  ┌─────────────────────┐   ┌─────────────────────┐                           │
│  │   SPS Parser        │   │   PPS Parser        │                           │
│  │   (profile, level,  │   │   (entropy mode,    │                           │
│  │    dimensions,      │◄──│    quant params,    │                           │
│  │    frame ordering)  │   │    deblock params)  │                           │
│  └──────────┬──────────┘   └──────────┬──────────┘                           │
│             │                         │                                      │
│             └────────────┬────────────┘                                      │
│                          ▼                                                   │
│  ┌─────────────────────────────────────────┐                                 │
│  │           Slice Header Parser           │                                 │
│  │   (slice type, QP, reference lists)     │                                 │
│  └──────────────────┬──────────────────────┘                                 │
│                     │                                                        │
│                     ▼                                                        │
│  ┌─────────────────────────────────────────┐                                 │
│  │          Entropy Decoder                │                                 │
│  │   ┌─────────────┐  ┌─────────────┐      │                                 │
│  │   │   CAVLC     │  │   CABAC     │      │  Profile-dependent              │
│  │   │ (Baseline)  │  │ (Main/High) │      │                                 │
│  │   └─────────────┘  └─────────────┘      │                                 │
│  └──────────────────┬──────────────────────┘                                 │
│                     │                                                        │
│                     ▼                                                        │
│  ┌─────────────────────────────────────────┐                                 │
│  │        Inverse Quantization             │                                 │
│  │   QP-dependent scaling, scaling lists   │                                 │
│  └──────────────────┬──────────────────────┘                                 │
│                     │                                                        │
│                     ▼                                                        │
│  ┌─────────────────────────────────────────┐                                 │
│  │        Inverse Transform                │                                 │
│  │   ┌──────────┐  ┌──────────┐            │                                 │
│  │   │ 4x4 DCT  │  │ 8x8 DCT  │  (High)    │                                 │
│  │   └──────────┘  └──────────┘            │                                 │
│  │   ┌──────────────────────────┐          │                                 │
│  │   │ 4x4 Hadamard (DC luma)  │           │                                 │
│  │   │ 2x2 Hadamard (DC chroma)│           │                                 │
│  │   └──────────────────────────┘          │                                 │
│  └──────────────────┬──────────────────────┘                                 │
│                     │                                                        │
│                     ▼                                                        │
│  ┌────────────────────────────────────────┐                                  │
│  │           Prediction                   │                                  │
│  │   ┌──────────────────────────┐         │                                  │
│  │   │  Intra Prediction        │         │                                  │
│  │   │  (9 modes 4x4, 4 modes   │         │                                  │
│  │   │   16x16, 4 modes 8x8)    │         │                                  │
│  │   └──────────────────────────┘         │                                  │
│  │   ┌──────────────────────────┐         │                                  │
│  │   │  Inter Prediction        │         │                                  │
│  │   │  (Motion compensation,   │         │                                  │
│  │   │   sub-pixel interp,      │         │                                  │
│  │   │   B-frame bidir)         │         │                                  │
│  │   └──────────────────────────┘         │                                  │
│  └──────────────────┬─────────────────────┘                                  │
│                     │                                                        │
│                     ▼                                                        │
│  ┌────────────────────────────────────────┐                                  │
│  │         Deblocking Filter              │                                  │
│  │   Adaptive edge filter, in-loop        │                                  │
│  └──────────────────┬─────────────────────┘                                  │
│                     │                                                        │
│                     ▼                                                        │
│              Decoded Picture                                                 │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Module Organization

```
es-core/src/core/
├── h264/
│   ├── mod.zig              # Module root, re-exports
│   ├── types.zig            # Common types (SPS, PPS, SliceHeader, etc.)
│   ├── nal_parser.zig       # NAL unit extraction, RBSP conversion
│   ├── sps_parser.zig       # SPS parsing for all profiles
│   ├── pps_parser.zig       # PPS parsing
│   ├── slice_parser.zig     # Slice header parsing
│   ├── cavlc.zig            # CAVLC entropy decoder
│   ├── cabac.zig            # CABAC entropy decoder
│   ├── inverse_quant.zig    # Inverse quantization
│   ├── transform.zig        # Inverse transforms (4x4, 8x8, Hadamard)
│   ├── intra_prediction.zig # Intra prediction modes
│   ├── inter_prediction.zig # Motion compensation
│   ├── deblock.zig          # Deblocking filter
│   ├── decoder.zig          # Main decoder orchestration
│   └── validator.zig        # High-level validation API
└── h264_validator.zig       # Updated wrapper (replaces OpenH264)
```

---

## 3. Existing Codebase Assets

### 3.1 Reusable Infrastructure

The EntropyShield codebase already contains extensive infrastructure that can be leveraged for H.264 decoding:

#### 3.1.1 BitReader (`es-core/src/core/bitstream_reader.zig`)

**Comprehensive MSB-first bit reader with H.264-specific methods already implemented:**

```zig
pub const BitReader = struct {
    data: []const u8,
    bit_pos: usize,

    // Already implemented for H.264:
    pub fn readExpGolomb(self: *BitReader) ?u32          // Unsigned Exp-Golomb (ue(v))
    pub fn readSignedExpGolomb(self: *BitReader) ?i32   // Signed Exp-Golomb (se(v))
    pub fn readBits(self: *BitReader, count: u6) ?u32   // Fixed-length bits (u(n))
    pub fn readBit(self: *BitReader) ?u1                // Single bit (f(1))
    pub fn peekBits(self: *BitReader, count: u6) ?u32   // Peek without consuming
    pub fn skipBits(self: *BitReader, count: usize) bool // Skip bits
    pub fn alignToByte(self: *BitReader) void           // Byte alignment
    pub fn remainingBits(self: *const BitReader) usize  // Bits left
};
```

**Status:** Ready to use, extensively tested.

#### 3.1.2 8x8 DCT Infrastructure

**From `mpeg12_decoder.zig` and `prores_decoder.zig`:**

```zig
// Zigzag scan order (same as H.264)
pub const zigzag_scan = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, ... };

// 8x8 DCT types
pub const DctBlock = [64]i32;
pub const PixelBlock = [64]i16;

// IDCT (needs modification for H.264's integer approximation)
pub fn inverseDct8x8(coeffs: *const DctBlock) PixelBlock;

// Quantization matrices
pub const default_intra_quant = [64]u8{ ... };
```

**Status:** Partial reuse - H.264 uses integer DCT approximation, not exact DCT.

#### 3.1.3 VLC Tables Pattern

**From `mpeg4p2_decoder.zig` - VLC decoding pattern:**

```zig
const VlcEntry = struct {
    code: u16,
    len: u4,
    run: u6,
    level: u6,
};

// VLC lookup pattern usable for CAVLC tables
pub fn decodeVlc(reader: *BitReader, table: []const VlcEntry) ?VlcEntry {
    const peek = reader.peekBits(16) orelse return null;
    for (table) |entry| {
        const shifted = peek >> @intCast(16 - entry.len);
        if (shifted == entry.code) {
            _ = reader.readBits(entry.len);
            return entry;
        }
    }
    return null;
}
```

**Status:** Pattern reusable for CAVLC implementation.

#### 3.1.4 Boolean/Arithmetic Decoder

**From `vp8_decoder.zig` - Context-adaptive arithmetic coding:**

```zig
pub const BoolDecoder = struct {
    data: []const u8,
    pos: usize,
    value: u32,
    range: u32,
    count: i32,

    pub fn readBool(self: *BoolDecoder, prob: u8) ?bool;
    pub fn readBit(self: *BoolDecoder) ?bool;
    pub fn readLiteral(self: *BoolDecoder, n: u5) ?u32;
};
```

**Status:** CABAC uses similar principles but different state machine. Useful as reference.

#### 3.1.5 Motion Vector Handling

**From `mpeg4p2_decoder.zig`:**

```zig
pub const MotionVector = struct {
    x: i16,
    y: i16,
};

pub fn predictMotionVector(mv_a: MotionVector, mv_b: MotionVector, mv_c: MotionVector) MotionVector;
pub fn median3(a: i16, b: i16, c: i16) i16;
```

**Status:** Pattern reusable, H.264 uses similar median prediction.

#### 3.1.6 Macroblock Decoding Structure

**From `mpeg4p2_decoder.zig`:**

```zig
pub const MacroblockDecodeResult = struct {
    success: bool,
    error_message: ?[]const u8,
    is_intra: bool,
    has_motion: bool,
    blocks_decoded: u8,
};
```

**Status:** Pattern directly applicable.

### 3.2 Reference Implementations in Codebase

The codebase contains complete decoder implementations for reference:

| Codec | File | Key Similarities to H.264 |
|-------|------|---------------------------|
| VP8 | `vp8_decoder.zig` | Boolean/arithmetic coding, 4x4 WHT, context adaptation |
| MPEG-1/2 | `mpeg12_decoder.zig` | VLC tables, 8x8 DCT, slice structure |
| MPEG-4 Part 2 | `mpeg4p2_decoder.zig` | DC/AC prediction, motion vectors, macroblock types |
| ProRes | `prores_decoder.zig` | Rice coding, quantization matrices |
| Theora | `theora_decoder.zig` | Token-based Huffman, 8x8 DCT |

---

## 4. Detailed Component Specifications

### 4.1 NAL Unit Parser

#### 4.1.1 NAL Unit Types

```zig
pub const NalUnitType = enum(u5) {
    unspecified = 0,
    coded_slice_non_idr = 1,     // Coded slice of a non-IDR picture
    coded_slice_data_partition_a = 2,
    coded_slice_data_partition_b = 3,
    coded_slice_data_partition_c = 4,
    coded_slice_idr = 5,         // Coded slice of an IDR picture
    sei = 6,                     // Supplemental enhancement information
    sps = 7,                     // Sequence parameter set
    pps = 8,                     // Picture parameter set
    access_unit_delimiter = 9,
    end_of_sequence = 10,
    end_of_stream = 11,
    filler_data = 12,
    sps_extension = 13,
    prefix_nal_unit = 14,
    subset_sps = 15,
    depth_parameter_set = 16,
    // 17-18: reserved
    coded_slice_auxiliary = 19,
    coded_slice_extension = 20,
    coded_slice_extension_depth = 21,
    // 22-23: reserved
    // 24-31: unspecified
    _,
};
```

#### 4.1.2 NAL Unit Header

```zig
pub const NalUnitHeader = struct {
    forbidden_zero_bit: u1,      // Must be 0
    nal_ref_idc: u2,             // Reference importance (0-3)
    nal_unit_type: NalUnitType,  // NAL unit type (5 bits)
};

pub fn parseNalHeader(byte: u8) ?NalUnitHeader {
    if ((byte & 0x80) != 0) return null;  // forbidden_zero_bit must be 0
    return .{
        .forbidden_zero_bit = 0,
        .nal_ref_idc = @intCast((byte >> 5) & 0x03),
        .nal_unit_type = @enumFromInt(byte & 0x1F),
    };
}
```

#### 4.1.3 Start Code Detection (Annex B)

```zig
pub const StartCodeResult = struct {
    position: usize,
    length: u2,  // 3 or 4 bytes
};

/// Find next start code (0x000001 or 0x00000001)
pub fn findStartCode(data: []const u8, offset: usize) ?StartCodeResult {
    if (offset + 3 > data.len) return null;

    var i = offset;
    while (i + 3 <= data.len) : (i += 1) {
        // Check for 3-byte start code
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            // Check if this is actually a 4-byte start code
            if (i > 0 and data[i - 1] == 0) {
                return .{ .position = i - 1, .length = 4 };
            }
            return .{ .position = i, .length = 3 };
        }
    }
    return null;
}
```

#### 4.1.4 Emulation Prevention Byte Removal

H.264 RBSP (Raw Byte Sequence Payload) uses emulation prevention bytes to avoid accidental start codes:

```zig
/// Convert NAL unit bytes to RBSP by removing emulation prevention bytes
/// Pattern: 0x00 0x00 0x03 XX -> 0x00 0x00 XX (where XX is 0x00, 0x01, 0x02, or 0x03)
pub fn nalToRbsp(allocator: Allocator, nal_data: []const u8) ![]u8 {
    var output = try ArrayList(u8).initCapacity(allocator, nal_data.len);
    errdefer output.deinit();

    var i: usize = 0;
    while (i < nal_data.len) {
        if (i + 2 < nal_data.len and
            nal_data[i] == 0 and
            nal_data[i + 1] == 0 and
            nal_data[i + 2] == 3)
        {
            // Emulation prevention byte found
            output.appendAssumeCapacity(0);
            output.appendAssumeCapacity(0);
            i += 3;  // Skip the 0x03
        } else {
            output.appendAssumeCapacity(nal_data[i]);
            i += 1;
        }
    }

    return output.toOwnedSlice();
}
```

### 4.2 SPS (Sequence Parameter Set) Parser

#### 4.2.1 Profile Identification

```zig
pub const ProfileIdc = enum(u8) {
    baseline = 66,           // Constrained Baseline
    main = 77,               // Main Profile
    extended = 88,           // Extended Profile
    high = 100,              // High Profile
    high_10 = 110,           // High 10 Profile
    high_422 = 122,          // High 4:2:2 Profile
    high_444_predictive = 244, // High 4:4:4 Predictive Profile
    cavlc_444_intra = 44,    // CAVLC 4:4:4 Intra Profile
    // Additional profiles
    scalable_baseline = 83,
    scalable_high = 86,
    multiview_high = 118,
    stereo_high = 128,
    _,
};
```

#### 4.2.2 SPS Structure

```zig
pub const SequenceParameterSet = struct {
    // Profile and level
    profile_idc: ProfileIdc,
    constraint_set_flags: u6,   // constraint_set0_flag through constraint_set5_flag
    level_idc: u8,
    seq_parameter_set_id: u8,   // 0-31

    // Chroma format (High profiles)
    chroma_format_idc: u2,      // 0=monochrome, 1=4:2:0, 2=4:2:2, 3=4:4:4
    separate_colour_plane_flag: bool,  // Only when chroma_format_idc == 3
    bit_depth_luma_minus8: u4,         // 0-6 (8-14 bit)
    bit_depth_chroma_minus8: u4,       // 0-6 (8-14 bit)
    qpprime_y_zero_transform_bypass_flag: bool,
    seq_scaling_matrix_present_flag: bool,
    scaling_lists_4x4: ?[6][16]u8,     // 6 lists for 4x4
    scaling_lists_8x8: ?[6][64]u8,     // Up to 6 lists for 8x8

    // Frame dimensions
    log2_max_frame_num_minus4: u5,
    pic_order_cnt_type: u2,
    log2_max_pic_order_cnt_lsb_minus4: u5,  // When pic_order_cnt_type == 0
    delta_pic_order_always_zero_flag: bool,  // When pic_order_cnt_type == 1
    offset_for_non_ref_pic: i32,             // When pic_order_cnt_type == 1
    offset_for_top_to_bottom_field: i32,     // When pic_order_cnt_type == 1
    num_ref_frames_in_pic_order_cnt_cycle: u8,
    offset_for_ref_frame: ?[]i32,            // Array of offsets

    // Reference frames
    max_num_ref_frames: u8,
    gaps_in_frame_num_value_allowed_flag: bool,

    // Picture dimensions in macroblocks
    pic_width_in_mbs_minus1: u16,
    pic_height_in_map_units_minus1: u16,
    frame_mbs_only_flag: bool,
    mb_adaptive_frame_field_flag: bool,  // When !frame_mbs_only_flag

    direct_8x8_inference_flag: bool,

    // Cropping
    frame_cropping_flag: bool,
    frame_crop_left_offset: u16,
    frame_crop_right_offset: u16,
    frame_crop_top_offset: u16,
    frame_crop_bottom_offset: u16,

    // VUI parameters
    vui_parameters_present_flag: bool,
    vui_parameters: ?VuiParameters,

    // Computed values
    pub fn width(self: *const SequenceParameterSet) u32 {
        const base = (@as(u32, self.pic_width_in_mbs_minus1) + 1) * 16;
        if (!self.frame_cropping_flag) return base;
        const sub_width_c: u32 = if (self.chroma_format_idc == 3) 1 else 2;
        return base - (self.frame_crop_left_offset + self.frame_crop_right_offset) * sub_width_c;
    }

    pub fn height(self: *const SequenceParameterSet) u32 {
        const mb_height = (@as(u32, self.pic_height_in_map_units_minus1) + 1);
        const base = mb_height * (if (self.frame_mbs_only_flag) @as(u32, 16) else 32);
        if (!self.frame_cropping_flag) return base;
        const sub_height_c: u32 = if (self.chroma_format_idc == 3 and !self.frame_mbs_only_flag) 1 else 2;
        return base - (self.frame_crop_top_offset + self.frame_crop_bottom_offset) * sub_height_c *
               (if (self.frame_mbs_only_flag) @as(u32, 2) else 1);
    }
};
```

#### 4.2.3 SPS Parsing Algorithm

```zig
pub fn parseSps(rbsp: []const u8) !SequenceParameterSet {
    var reader = BitReader.init(rbsp);

    var sps: SequenceParameterSet = undefined;

    // Profile and level
    sps.profile_idc = @enumFromInt(reader.readBits(8) orelse return error.Truncated);
    sps.constraint_set_flags = @intCast(reader.readBits(6) orelse return error.Truncated);
    _ = reader.readBits(2);  // reserved_zero_2bits
    sps.level_idc = @intCast(reader.readBits(8) orelse return error.Truncated);
    sps.seq_parameter_set_id = @intCast(reader.readExpGolomb() orelse return error.Truncated);

    // Profile-specific parsing
    if (isHighProfile(sps.profile_idc)) {
        sps.chroma_format_idc = @intCast(reader.readExpGolomb() orelse return error.Truncated);
        if (sps.chroma_format_idc == 3) {
            sps.separate_colour_plane_flag = (reader.readBit() orelse return error.Truncated) == 1;
        }
        sps.bit_depth_luma_minus8 = @intCast(reader.readExpGolomb() orelse return error.Truncated);
        sps.bit_depth_chroma_minus8 = @intCast(reader.readExpGolomb() orelse return error.Truncated);
        sps.qpprime_y_zero_transform_bypass_flag = (reader.readBit() orelse return error.Truncated) == 1;
        sps.seq_scaling_matrix_present_flag = (reader.readBit() orelse return error.Truncated) == 1;

        if (sps.seq_scaling_matrix_present_flag) {
            try parseScalingLists(&reader, &sps);
        }
    } else {
        sps.chroma_format_idc = 1;  // 4:2:0 for Baseline/Main
        sps.bit_depth_luma_minus8 = 0;
        sps.bit_depth_chroma_minus8 = 0;
    }

    // Continue with remaining SPS fields...
    sps.log2_max_frame_num_minus4 = @intCast(reader.readExpGolomb() orelse return error.Truncated);
    sps.pic_order_cnt_type = @intCast(reader.readExpGolomb() orelse return error.Truncated);

    // ... (complete implementation follows ITU-T H.264 Section 7.3.2.1.1)

    return sps;
}

fn isHighProfile(profile: ProfileIdc) bool {
    return switch (profile) {
        .high, .high_10, .high_422, .high_444_predictive, .cavlc_444_intra => true,
        else => false,
    };
}
```

### 4.3 PPS (Picture Parameter Set) Parser

```zig
pub const PictureParameterSet = struct {
    pic_parameter_set_id: u8,           // 0-255
    seq_parameter_set_id: u8,           // References SPS
    entropy_coding_mode_flag: bool,     // false=CAVLC, true=CABAC
    bottom_field_pic_order_in_frame_present_flag: bool,

    // Slice groups (FMO)
    num_slice_groups_minus1: u8,
    slice_group_map_type: ?u3,
    // ... additional slice group fields

    num_ref_idx_l0_default_active_minus1: u5,
    num_ref_idx_l1_default_active_minus1: u5,
    weighted_pred_flag: bool,
    weighted_bipred_idc: u2,
    pic_init_qp_minus26: i8,            // -26 to +25
    pic_init_qs_minus26: i8,
    chroma_qp_index_offset: i8,         // -12 to +12
    deblocking_filter_control_present_flag: bool,
    constrained_intra_pred_flag: bool,
    redundant_pic_cnt_present_flag: bool,

    // Extended for High profiles
    transform_8x8_mode_flag: bool,
    pic_scaling_matrix_present_flag: bool,
    scaling_lists_4x4: ?[6][16]u8,
    scaling_lists_8x8: ?[6][64]u8,
    second_chroma_qp_index_offset: i8,
};
```

### 4.4 Slice Header Parser

```zig
pub const SliceType = enum(u4) {
    p = 0,      // P slice
    b = 1,      // B slice
    i = 2,      // I slice
    sp = 3,     // SP slice (Extended profile)
    si = 4,     // SI slice (Extended profile)
    p_all = 5,  // P slice (all macroblocks)
    b_all = 6,  // B slice (all macroblocks)
    i_all = 7,  // I slice (all macroblocks)
    sp_all = 8, // SP slice (all macroblocks)
    si_all = 9, // SI slice (all macroblocks)

    pub fn isPSlice(self: SliceType) bool {
        return self == .p or self == .p_all or self == .sp or self == .sp_all;
    }

    pub fn isBSlice(self: SliceType) bool {
        return self == .b or self == .b_all;
    }

    pub fn isISlice(self: SliceType) bool {
        return self == .i or self == .i_all or self == .si or self == .si_all;
    }
};

pub const SliceHeader = struct {
    first_mb_in_slice: u32,
    slice_type: SliceType,
    pic_parameter_set_id: u8,
    colour_plane_id: ?u2,               // When separate_colour_plane_flag
    frame_num: u16,
    field_pic_flag: bool,
    bottom_field_flag: bool,
    idr_pic_id: ?u16,                   // When IDR

    // Picture order count
    pic_order_cnt_lsb: ?u16,
    delta_pic_order_cnt_bottom: ?i32,
    delta_pic_order_cnt: [2]i32,

    // Reference picture lists
    num_ref_idx_l0_active_minus1: u5,
    num_ref_idx_l1_active_minus1: u5,
    ref_pic_list_modification_flag_l0: bool,
    ref_pic_list_modification_flag_l1: bool,

    // Prediction weights
    luma_log2_weight_denom: ?u3,
    chroma_log2_weight_denom: ?u3,
    // ... weight tables

    // Reference picture marking
    no_output_of_prior_pics_flag: bool,
    long_term_reference_flag: bool,
    adaptive_ref_pic_marking_mode_flag: bool,

    slice_qp_delta: i8,
    sp_for_switch_flag: bool,
    slice_qs_delta: i8,

    // Deblocking
    disable_deblocking_filter_idc: u2,
    slice_alpha_c0_offset_div2: i8,
    slice_beta_offset_div2: i8,

    slice_group_change_cycle: ?u32,
};
```

### 4.5 Entropy Decoding

#### 4.5.1 CAVLC (Context-Adaptive Variable-Length Coding)

CAVLC is used in Baseline and Extended profiles, and optionally in Main/High.

```zig
pub const CavlcDecoder = struct {
    reader: *BitReader,

    /// Decode residual coefficients for a 4x4 block
    pub fn decodeResidualBlock4x4(
        self: *CavlcDecoder,
        block_type: BlockType,
        max_num_coeff: u8,
        nC: i8,  // Context: number of non-zero coeffs in neighbors
    ) !CavlcBlockResult {
        // 1. Decode coeff_token (total_coeffs, trailing_ones)
        const coeff_token = try self.decodeCoeffToken(nC);

        if (coeff_token.total_coeffs == 0) {
            return .{ .coeffs = [_]i32{0} ** 16, .non_zero = 0 };
        }

        // 2. Decode trailing ones signs (up to 3)
        var levels: [16]i32 = undefined;
        var level_idx: u8 = 0;

        for (0..coeff_token.trailing_ones) |_| {
            const sign = self.reader.readBit() orelse return error.Truncated;
            levels[level_idx] = if (sign == 1) -1 else 1;
            level_idx += 1;
        }

        // 3. Decode remaining levels
        var suffix_length: u4 = if (coeff_token.total_coeffs > 10 and coeff_token.trailing_ones < 3) 1 else 0;

        while (level_idx < coeff_token.total_coeffs) {
            const level = try self.decodeLevel(suffix_length);
            levels[level_idx] = level;
            level_idx += 1;

            // Update suffix_length
            if (suffix_length == 0) suffix_length = 1;
            if (@abs(level) > (3 << (suffix_length - 1)) and suffix_length < 6) {
                suffix_length += 1;
            }
        }

        // 4. Decode total_zeros (if total_coeffs < max_num_coeff)
        var total_zeros: u8 = 0;
        if (coeff_token.total_coeffs < max_num_coeff) {
            total_zeros = try self.decodeTotalZeros(coeff_token.total_coeffs, max_num_coeff);
        }

        // 5. Decode run_before for each coefficient
        var run_before: [16]u8 = [_]u8{0} ** 16;
        var zeros_left = total_zeros;

        for (0..coeff_token.total_coeffs - 1) |i| {
            if (zeros_left > 0) {
                run_before[i] = try self.decodeRunBefore(zeros_left);
                zeros_left -= run_before[i];
            }
        }
        run_before[coeff_token.total_coeffs - 1] = zeros_left;

        // 6. Arrange coefficients in scan order
        var coeffs: [16]i32 = [_]i32{0} ** 16;
        var pos: u8 = 0;

        for (0..coeff_token.total_coeffs) |i| {
            pos += run_before[coeff_token.total_coeffs - 1 - i];
            coeffs[pos] = levels[coeff_token.total_coeffs - 1 - i];
            pos += 1;
        }

        return .{
            .coeffs = coeffs,
            .non_zero = coeff_token.total_coeffs,
        };
    }

    // VLC tables for coeff_token
    const CoeffToken = struct {
        total_coeffs: u5,
        trailing_ones: u2,
    };

    fn decodeCoeffToken(self: *CavlcDecoder, nC: i8) !CoeffToken {
        // Table selection based on nC
        // nC < 2: Table 9-5(a)
        // 2 <= nC < 4: Table 9-5(b)
        // 4 <= nC < 8: Table 9-5(c)
        // nC >= 8: Fixed 6-bit code
        // nC == -1 (chroma DC): Table 9-5(d)
        // nC == -2 (chroma DC 4:2:2): Table 9-5(e)

        // Implementation uses VLC lookup tables from ITU-T H.264 Section 9.2.1
        // ...
    }
};
```

#### 4.5.2 CABAC (Context-Adaptive Binary Arithmetic Coding)

CABAC provides 10-15% better compression than CAVLC but is computationally intensive.

```zig
pub const CabacDecoder = struct {
    reader: *BitReader,

    // Arithmetic decoding state
    codIRange: u16,      // 256-510
    codIOffset: u16,     // Current value being decoded

    // Context models (464 contexts for H.264)
    contexts: [460]CabacContext,

    const CabacContext = struct {
        pStateIdx: u7,    // Probability state (0-63)
        valMPS: u1,       // Most Probable Symbol value
    };

    pub fn init(rbsp: []const u8, initial_qp: u6, slice_type: SliceType) CabacDecoder {
        var decoder = CabacDecoder{
            .reader = BitReader.init(rbsp),
            .codIRange = 510,
            .codIOffset = 0,
            .contexts = undefined,
        };

        // Initialize contexts based on slice type and QP
        decoder.initContextModels(initial_qp, slice_type);

        // Read initial 9 bits for codIOffset
        decoder.codIOffset = @intCast(decoder.reader.readBits(9) orelse 0);

        return decoder;
    }

    /// Decode a single binary decision
    pub fn decodeBin(self: *CabacDecoder, ctx_idx: u16) u1 {
        const ctx = &self.contexts[ctx_idx];
        const qRangeIdx = (self.codIRange >> 6) & 3;
        const pStateIdx = ctx.pStateIdx;

        // Table 9-45: rangeTabLPS
        const rangeLPS = rangeTabLPS[pStateIdx][qRangeIdx];

        self.codIRange -= rangeLPS;

        if (self.codIOffset >= self.codIRange) {
            // LPS path
            self.codIOffset -= self.codIRange;
            self.codIRange = rangeLPS;

            // Update context
            if (pStateIdx == 0) {
                ctx.valMPS = 1 - ctx.valMPS;
            }
            ctx.pStateIdx = transIdxLPS[pStateIdx];

            self.renormD();
            return 1 - ctx.valMPS;
        } else {
            // MPS path
            ctx.pStateIdx = transIdxMPS[pStateIdx];
            self.renormD();
            return ctx.valMPS;
        }
    }

    /// Decode bypass bin (equiprobable)
    pub fn decodeBypass(self: *CabacDecoder) u1 {
        self.codIOffset = (self.codIOffset << 1) | @as(u16, self.reader.readBit() orelse 0);

        if (self.codIOffset >= self.codIRange) {
            self.codIOffset -= self.codIRange;
            return 1;
        }
        return 0;
    }

    /// Decode terminate bin (end of slice check)
    pub fn decodeTerminate(self: *CabacDecoder) u1 {
        self.codIRange -= 2;

        if (self.codIOffset >= self.codIRange) {
            return 1;  // End of slice_data
        }

        self.renormD();
        return 0;
    }

    fn renormD(self: *CabacDecoder) void {
        while (self.codIRange < 256) {
            self.codIRange <<= 1;
            self.codIOffset = (self.codIOffset << 1) | @as(u16, self.reader.readBit() orelse 0);
        }
    }

    // Transition tables (ITU-T H.264 Tables 9-45 through 9-48)
    const rangeTabLPS: [64][4]u8 = .{
        .{ 128, 176, 208, 240 }, // pStateIdx = 0
        .{ 128, 167, 197, 227 }, // pStateIdx = 1
        // ... complete table from spec
    };

    const transIdxLPS: [64]u7 = .{ 0, 0, 1, 2, 2, 4, 4, 5, ... };
    const transIdxMPS: [64]u7 = .{ 1, 2, 3, 4, 5, 6, 7, 8, ... };
};
```

### 4.6 Inverse Quantization

```zig
/// H.264 uses level-based quantization with QP 0-51
pub const InverseQuantizer = struct {
    /// Scaling factors for 4x4 transform
    const v_mat_4x4: [6][3]u16 = .{
        .{ 10, 16, 13 },  // QP % 6 = 0
        .{ 11, 18, 14 },  // QP % 6 = 1
        .{ 13, 20, 16 },  // QP % 6 = 2
        .{ 14, 23, 18 },  // QP % 6 = 3
        .{ 16, 25, 20 },  // QP % 6 = 4
        .{ 18, 29, 23 },  // QP % 6 = 5
    };

    /// Position class for 4x4 matrix
    const pos_class_4x4: [16]u8 = .{
        0, 2, 0, 2,
        2, 1, 2, 1,
        0, 2, 0, 2,
        2, 1, 2, 1,
    };

    /// Dequantize a 4x4 block
    pub fn dequantize4x4(
        coeffs: *[16]i32,
        qp: u6,
        is_intra: bool,
        scaling_list: ?*const [16]u8,
    ) void {
        const qp_div6 = qp / 6;
        const qp_mod6 = qp % 6;

        for (0..16) |i| {
            if (coeffs[i] != 0) {
                const scale: u32 = if (scaling_list) |list|
                    @as(u32, list[i]) * v_mat_4x4[qp_mod6][pos_class_4x4[i]]
                else
                    @as(u32, v_mat_4x4[qp_mod6][pos_class_4x4[i]]) * 16;

                const level: i32 = coeffs[i];
                const shift: u5 = @intCast(qp_div6);

                if (is_intra or i > 0) {
                    coeffs[i] = (level * @as(i32, @intCast(scale))) << shift;
                } else {
                    // DC coefficient for inter (special handling)
                    coeffs[i] = (level * @as(i32, @intCast(scale)) * 16) << shift;
                }
            }
        }
    }

    /// Dequantize an 8x8 block (High profile)
    pub fn dequantize8x8(
        coeffs: *[64]i32,
        qp: u6,
        is_intra: bool,
        scaling_list: ?*const [64]u8,
    ) void {
        // Similar pattern with 8x8 scaling factors
        // ...
    }
};
```

### 4.7 Inverse Transform

#### 4.7.1 4x4 Integer DCT

```zig
/// H.264 4x4 inverse integer transform
/// Based on ITU-T H.264 Section 8.5.12
pub fn inverseTransform4x4(coeffs: *[16]i32) [16]i16 {
    var d: [16]i32 = undefined;
    var f: [16]i32 = undefined;

    // Horizontal (row) transform
    for (0..4) |i| {
        const e0 = coeffs[i * 4 + 0] + coeffs[i * 4 + 2];
        const e1 = coeffs[i * 4 + 0] - coeffs[i * 4 + 2];
        const e2 = (coeffs[i * 4 + 1] >> 1) - coeffs[i * 4 + 3];
        const e3 = coeffs[i * 4 + 1] + (coeffs[i * 4 + 3] >> 1);

        d[i * 4 + 0] = e0 + e3;
        d[i * 4 + 1] = e1 + e2;
        d[i * 4 + 2] = e1 - e2;
        d[i * 4 + 3] = e0 - e3;
    }

    // Vertical (column) transform
    for (0..4) |j| {
        const g0 = d[0 * 4 + j] + d[2 * 4 + j];
        const g1 = d[0 * 4 + j] - d[2 * 4 + j];
        const g2 = (d[1 * 4 + j] >> 1) - d[3 * 4 + j];
        const g3 = d[1 * 4 + j] + (d[3 * 4 + j] >> 1);

        f[0 * 4 + j] = g0 + g3;
        f[1 * 4 + j] = g1 + g2;
        f[2 * 4 + j] = g1 - g2;
        f[3 * 4 + j] = g0 - g3;
    }

    // Final scaling and rounding
    var pixels: [16]i16 = undefined;
    for (0..16) |i| {
        pixels[i] = @intCast(@divTrunc(f[i] + 32, 64));
    }

    return pixels;
}
```

#### 4.7.2 8x8 Integer DCT (High Profile)

```zig
/// H.264 8x8 inverse integer transform
/// Based on ITU-T H.264 Section 8.5.12
pub fn inverseTransform8x8(coeffs: *[64]i32) [64]i16 {
    var d: [64]i32 = undefined;
    var f: [64]i32 = undefined;

    // Row transform
    for (0..8) |i| {
        const a = &coeffs[i * 8];

        const e0 = a[0] + a[4];
        const e1 = -a[3] + a[5] - a[7] - (a[7] >> 1);
        const e2 = a[0] - a[4];
        const e3 = a[1] + a[7] - a[3] - (a[3] >> 1);
        const e4 = (a[2] >> 1) - a[6];
        const e5 = -a[1] + a[7] + a[5] + (a[5] >> 1);
        const e6 = a[2] + (a[6] >> 1);
        const e7 = a[3] + a[5] + a[1] + (a[1] >> 1);

        const f0 = e0 + e6;
        const f1 = e1 + (e7 >> 2);
        const f2 = e2 + e4;
        const f3 = e3 + (e5 >> 2);
        const f4 = e2 - e4;
        const f5 = (e3 >> 2) - e5;
        const f6 = e0 - e6;
        const f7 = e7 - (e1 >> 2);

        d[i * 8 + 0] = f0 + f7;
        d[i * 8 + 1] = f2 + f5;
        d[i * 8 + 2] = f4 + f3;
        d[i * 8 + 3] = f6 + f1;
        d[i * 8 + 4] = f6 - f1;
        d[i * 8 + 5] = f4 - f3;
        d[i * 8 + 6] = f2 - f5;
        d[i * 8 + 7] = f0 - f7;
    }

    // Column transform (similar pattern)
    // ...

    // Final scaling
    var pixels: [64]i16 = undefined;
    for (0..64) |i| {
        pixels[i] = @intCast(@divTrunc(f[i] + 32, 64));
    }

    return pixels;
}
```

#### 4.7.3 Hadamard Transforms

```zig
/// 4x4 Hadamard transform for luma DC (16x16 intra)
pub fn inverseHadamard4x4(dc_coeffs: *[16]i32) void {
    var temp: [16]i32 = undefined;

    // Horizontal
    for (0..4) |i| {
        const a = dc_coeffs[i * 4 + 0];
        const b = dc_coeffs[i * 4 + 1];
        const c = dc_coeffs[i * 4 + 2];
        const d_val = dc_coeffs[i * 4 + 3];

        temp[i * 4 + 0] = a + b + c + d_val;
        temp[i * 4 + 1] = a + b - c - d_val;
        temp[i * 4 + 2] = a - b - c + d_val;
        temp[i * 4 + 3] = a - b + c - d_val;
    }

    // Vertical
    for (0..4) |j| {
        const a = temp[0 * 4 + j];
        const b = temp[1 * 4 + j];
        const c = temp[2 * 4 + j];
        const d_val = temp[3 * 4 + j];

        dc_coeffs[0 * 4 + j] = a + b + c + d_val;
        dc_coeffs[1 * 4 + j] = a + b - c - d_val;
        dc_coeffs[2 * 4 + j] = a - b - c + d_val;
        dc_coeffs[3 * 4 + j] = a - b + c - d_val;
    }
}

/// 2x2 Hadamard transform for chroma DC
pub fn inverseHadamard2x2(dc_coeffs: *[4]i32) void {
    const a = dc_coeffs[0];
    const b = dc_coeffs[1];
    const c = dc_coeffs[2];
    const d = dc_coeffs[3];

    dc_coeffs[0] = a + b + c + d;
    dc_coeffs[1] = a - b + c - d;
    dc_coeffs[2] = a + b - c - d;
    dc_coeffs[3] = a - b - c + d;
}
```

### 4.8 Intra Prediction

#### 4.8.1 4x4 Luma Intra Prediction Modes

```zig
pub const IntraMode4x4 = enum(u4) {
    vertical = 0,
    horizontal = 1,
    dc = 2,
    diagonal_down_left = 3,
    diagonal_down_right = 4,
    vertical_right = 5,
    horizontal_down = 6,
    vertical_left = 7,
    horizontal_up = 8,
};

pub fn intraPrediction4x4(
    mode: IntraMode4x4,
    above: [8]u8,    // Samples from above (A-H)
    left: [4]u8,     // Samples from left (I-L)
    top_left: u8,    // Sample at top-left (M)
) [16]u8 {
    var pred: [16]u8 = undefined;

    switch (mode) {
        .vertical => {
            for (0..4) |y| {
                for (0..4) |x| {
                    pred[y * 4 + x] = above[x];
                }
            }
        },
        .horizontal => {
            for (0..4) |y| {
                for (0..4) |x| {
                    pred[y * 4 + x] = left[y];
                }
            }
        },
        .dc => {
            var sum: u16 = 0;
            for (above[0..4]) |s| sum += s;
            for (left) |s| sum += s;
            const dc: u8 = @intCast((sum + 4) >> 3);
            for (&pred) |*p| p.* = dc;
        },
        .diagonal_down_left => {
            // Prediction from top-right direction
            for (0..4) |y| {
                for (0..4) |x| {
                    if (x == 3 and y == 3) {
                        pred[y * 4 + x] = @intCast((above[6] + 3 * above[7] + 2) >> 2);
                    } else {
                        pred[y * 4 + x] = @intCast((above[x + y] + 2 * above[x + y + 1] + above[x + y + 2] + 2) >> 2);
                    }
                }
            }
        },
        // ... remaining 5 modes
        else => {},
    }

    return pred;
}
```

#### 4.8.2 16x16 Luma Intra Prediction Modes

```zig
pub const IntraMode16x16 = enum(u2) {
    vertical = 0,
    horizontal = 1,
    dc = 2,
    plane = 3,
};

pub fn intraPrediction16x16(
    mode: IntraMode16x16,
    above: [16]u8,
    left: [16]u8,
    top_left: u8,
) [256]u8 {
    var pred: [256]u8 = undefined;

    switch (mode) {
        .vertical => {
            for (0..16) |y| {
                for (0..16) |x| {
                    pred[y * 16 + x] = above[x];
                }
            }
        },
        .horizontal => {
            for (0..16) |y| {
                for (0..16) |x| {
                    pred[y * 16 + x] = left[y];
                }
            }
        },
        .dc => {
            var sum: u32 = 0;
            for (above) |s| sum += s;
            for (left) |s| sum += s;
            const dc: u8 = @intCast((sum + 16) >> 5);
            for (&pred) |*p| p.* = dc;
        },
        .plane => {
            // Complex plane prediction
            var H: i32 = 0;
            var V: i32 = 0;

            for (0..8) |i| {
                H += (@as(i32, i) + 1) * (@as(i32, above[8 + i]) - @as(i32, above[6 - i]));
                V += (@as(i32, i) + 1) * (@as(i32, left[8 + i]) - @as(i32, left[6 - i]));
            }

            const a = 16 * (@as(i32, above[15]) + @as(i32, left[15]));
            const b = (5 * H + 32) >> 6;
            const c = (5 * V + 32) >> 6;

            for (0..16) |y| {
                for (0..16) |x| {
                    const val = (a + b * (@as(i32, x) - 7) + c * (@as(i32, y) - 7) + 16) >> 5;
                    pred[y * 16 + x] = @intCast(std.math.clamp(val, 0, 255));
                }
            }
        },
    }

    return pred;
}
```

### 4.9 Inter Prediction (Motion Compensation)

```zig
pub const InterPredictor = struct {
    ref_frames: [16]?*DecodedFrame,

    /// 6-tap interpolation filter for half-pel luma
    const luma_filter: [6]i16 = .{ 1, -5, 20, 20, -5, 1 };

    /// Bilinear interpolation for quarter-pel luma
    pub fn interpolateLuma(
        ref: *const DecodedFrame,
        x: i32,          // Quarter-pel x position
        y: i32,          // Quarter-pel y position
        block_width: u8,
        block_height: u8,
        out: []u8,
    ) void {
        const frac_x = @as(u2, @intCast(x & 3));
        const frac_y = @as(u2, @intCast(y & 3));
        const int_x = x >> 2;
        const int_y = y >> 2;

        if (frac_x == 0 and frac_y == 0) {
            // Integer position - direct copy
            for (0..block_height) |dy| {
                for (0..block_width) |dx| {
                    const src_y = int_y + @as(i32, @intCast(dy));
                    const src_x = int_x + @as(i32, @intCast(dx));
                    out[dy * block_width + dx] = ref.getLumaSample(src_x, src_y);
                }
            }
        } else if (frac_y == 0) {
            // Horizontal interpolation only
            interpolateHorizontal(ref, int_x, int_y, frac_x, block_width, block_height, out);
        } else if (frac_x == 0) {
            // Vertical interpolation only
            interpolateVertical(ref, int_x, int_y, frac_y, block_width, block_height, out);
        } else {
            // Diagonal interpolation
            interpolateDiagonal(ref, int_x, int_y, frac_x, frac_y, block_width, block_height, out);
        }
    }

    fn interpolateHorizontal(
        ref: *const DecodedFrame,
        int_x: i32,
        int_y: i32,
        frac_x: u2,
        width: u8,
        height: u8,
        out: []u8,
    ) void {
        if (frac_x == 2) {
            // Half-pel: 6-tap filter
            for (0..height) |dy| {
                for (0..width) |dx| {
                    var sum: i32 = 0;
                    for (0..6) |i| {
                        const sx = int_x + @as(i32, @intCast(dx)) + @as(i32, @intCast(i)) - 2;
                        sum += @as(i32, luma_filter[i]) * @as(i32, ref.getLumaSample(sx, int_y + @as(i32, @intCast(dy))));
                    }
                    out[dy * width + dx] = @intCast(std.math.clamp((sum + 16) >> 5, 0, 255));
                }
            }
        } else {
            // Quarter-pel: average of integer and half-pel
            // ...
        }
    }

    /// Chroma interpolation (bilinear)
    pub fn interpolateChroma(
        ref: *const DecodedFrame,
        x: i32,          // Eighth-pel x position
        y: i32,          // Eighth-pel y position
        block_width: u8,
        block_height: u8,
        out_cb: []u8,
        out_cr: []u8,
    ) void {
        const frac_x = x & 7;
        const frac_y = y & 7;
        const int_x = x >> 3;
        const int_y = y >> 3;

        // Bilinear interpolation
        for (0..block_height) |dy| {
            for (0..block_width) |dx| {
                const sx = int_x + @as(i32, @intCast(dx));
                const sy = int_y + @as(i32, @intCast(dy));

                const a = ref.getChromaSample(.cb, sx, sy);
                const b = ref.getChromaSample(.cb, sx + 1, sy);
                const c = ref.getChromaSample(.cb, sx, sy + 1);
                const d = ref.getChromaSample(.cb, sx + 1, sy + 1);

                const val = (8 - frac_x) * (8 - frac_y) * @as(u32, a) +
                           frac_x * (8 - frac_y) * @as(u32, b) +
                           (8 - frac_x) * frac_y * @as(u32, c) +
                           frac_x * frac_y * @as(u32, d);

                out_cb[dy * block_width + dx] = @intCast((val + 32) >> 6);
            }
        }
        // Repeat for Cr
    }
};
```

### 4.10 Deblocking Filter

```zig
pub const DeblockingFilter = struct {
    /// Filter strength parameters from slice header
    alpha_offset: i8,
    beta_offset: i8,

    /// Apply deblocking to a macroblock
    pub fn filterMacroblock(
        self: *DeblockingFilter,
        mb: *Macroblock,
        neighbors: MacroblockNeighbors,
        qp_y: u6,
        qp_c: u6,
    ) void {
        // Vertical edges (left to right)
        for (0..4) |edge| {
            self.filterVerticalEdgeLuma(mb, edge, neighbors, qp_y);
        }
        for (0..2) |edge| {
            self.filterVerticalEdgeChroma(mb, edge, neighbors, qp_c);
        }

        // Horizontal edges (top to bottom)
        for (0..4) |edge| {
            self.filterHorizontalEdgeLuma(mb, edge, neighbors, qp_y);
        }
        for (0..2) |edge| {
            self.filterHorizontalEdgeChroma(mb, edge, neighbors, qp_c);
        }
    }

    /// Calculate boundary strength (bS)
    fn calculateBs(
        p_mb: *const Macroblock,
        q_mb: *const Macroblock,
        p_block: u4,
        q_block: u4,
    ) u3 {
        // bS = 4 if either block is intra and edge is MB boundary
        // bS = 3 if either block is intra
        // bS = 2 if either block has coded residual
        // bS = 1 if MVs differ by >= 4 quarter-pels or different ref frames
        // bS = 0 otherwise

        if (p_mb.is_intra or q_mb.is_intra) {
            return 4;  // Actually 3 or 4 depending on edge
        }

        if (p_mb.coded_block_pattern[p_block] or q_mb.coded_block_pattern[q_block]) {
            return 2;
        }

        // Check motion vector difference
        const mv_p = p_mb.mv[p_block];
        const mv_q = q_mb.mv[q_block];

        if (@abs(mv_p.x - mv_q.x) >= 4 or @abs(mv_p.y - mv_q.y) >= 4) {
            return 1;
        }

        if (p_mb.ref_idx[p_block] != q_mb.ref_idx[q_block]) {
            return 1;
        }

        return 0;
    }

    /// Alpha and beta threshold tables (ITU-T H.264 Table 8-16)
    const alpha_table: [52]u8 = .{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        4, 4, 5, 6, 7, 8, 9, 10, 12, 13, 15, 17, 20, 22, 25, 28,
        32, 36, 40, 45, 50, 56, 63, 71, 80, 90, 101, 113, 127, 144, 162, 182,
        203, 226, 255, 255,
    };

    const beta_table: [52]u8 = .{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 6, 6, 7, 7, 8, 8,
        9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
        17, 17, 18, 18,
    };

    fn filterSamples(
        p: *[4]u8,  // Samples on P side (p[3], p[2], p[1], p[0] closest to edge)
        q: *[4]u8,  // Samples on Q side (q[0], q[1], q[2], q[3] closest to edge)
        bS: u3,
        qp: u6,
    ) void {
        const index_a = std.math.clamp(@as(i32, qp) + self.alpha_offset, 0, 51);
        const index_b = std.math.clamp(@as(i32, qp) + self.beta_offset, 0, 51);

        const alpha = alpha_table[@intCast(index_a)];
        const beta = beta_table[@intCast(index_b)];

        // Check filter conditions
        if (@abs(@as(i16, p[0]) - @as(i16, q[0])) >= alpha) return;
        if (@abs(@as(i16, p[1]) - @as(i16, p[0])) >= beta) return;
        if (@abs(@as(i16, q[1]) - @as(i16, q[0])) >= beta) return;

        if (bS < 4) {
            // Normal filtering
            // ...
        } else {
            // Strong filtering (bS == 4)
            // ...
        }
    }
};
```

### 4.11 Profile-Specific Features

| Feature | Baseline | Main | Extended | High | High 10 | High 4:2:2 | High 4:4:4 |
|---------|----------|------|----------|------|---------|------------|------------|
| CAVLC | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| CABAC | No | Yes | No | Yes | Yes | Yes | Yes |
| B slices | No | Yes | Yes | Yes | Yes | Yes | Yes |
| Weighted prediction | No | Yes | Yes | Yes | Yes | Yes | Yes |
| Data partitioning | No | No | Yes | No | No | No | No |
| SI/SP slices | No | No | Yes | No | No | No | No |
| 8x8 transform | No | No | No | Yes | Yes | Yes | Yes |
| 8x8 intra prediction | No | No | No | Yes | Yes | Yes | Yes |
| Scaling matrices | Default | Default | Default | Custom | Custom | Custom | Custom |
| Chroma format | 4:2:0 | 4:2:0 | 4:2:0 | 4:2:0 | 4:2:0 | 4:2:2 | 4:4:4 |
| Bit depth | 8 | 8 | 8 | 8 | 10 | 10 | 14 |
| Monochrome | No | No | No | Yes | Yes | Yes | Yes |
| Lossless mode | No | No | No | No | No | No | Yes |

---

## 5. Data Structures

### 5.1 Core Types

```zig
/// Decoded picture buffer entry
pub const DecodedFrame = struct {
    allocator: Allocator,

    // Plane data
    y_plane: []u8,      // Luma samples
    cb_plane: []u8,     // Chroma Cb samples
    cr_plane: []u8,     // Chroma Cr samples

    // Dimensions
    width: u16,
    height: u16,
    stride_y: u16,
    stride_c: u16,

    // Reference info
    poc: i32,                    // Picture order count
    frame_num: u16,
    is_reference: bool,
    is_long_term: bool,
    long_term_frame_idx: u8,

    pub fn init(allocator: Allocator, sps: *const SequenceParameterSet) !DecodedFrame;
    pub fn deinit(self: *DecodedFrame) void;
    pub fn getLumaSample(self: *const DecodedFrame, x: i32, y: i32) u8;
    pub fn getChromaSample(self: *const DecodedFrame, plane: ChromaPlane, x: i32, y: i32) u8;
};

/// Decoded Picture Buffer
pub const Dpb = struct {
    frames: [16]?*DecodedFrame,
    num_ref_frames: u8,

    pub fn getRefPicList(self: *const Dpb, slice_type: SliceType) [16]?*DecodedFrame;
    pub fn markAsReference(self: *Dpb, frame: *DecodedFrame, marking: RefPicMarking) void;
    pub fn outputFrame(self: *Dpb, poc: i32) ?*DecodedFrame;
};

/// Macroblock data
pub const Macroblock = struct {
    mb_type: MbType,
    is_intra: bool,
    transform_size_8x8_flag: bool,

    // Coefficients (before IDCT)
    luma_dc: [16]i32,
    luma_ac: [16][16]i32,
    chroma_dc_cb: [4]i32,
    chroma_dc_cr: [4]i32,
    chroma_ac_cb: [4][16]i32,
    chroma_ac_cr: [4][16]i32,

    // Prediction modes
    intra_modes_4x4: [16]IntraMode4x4,
    intra_mode_16x16: IntraMode16x16,
    intra_mode_chroma: IntraModeChroma,

    // Motion vectors (for each 4x4 sub-block)
    mv_l0: [16]MotionVector,
    mv_l1: [16]MotionVector,
    ref_idx_l0: [4]i8,
    ref_idx_l1: [4]i8,

    // Coded block pattern
    cbp_y: u4,
    cbp_c: u2,

    qp: u6,
};
```

### 5.2 Validation Result Types

```zig
/// Result of H.264 stream validation
pub const H264ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,

    // Statistics
    frames_decoded: u32,
    slices_decoded: u32,
    macroblocks_decoded: u32,

    // Stream info
    profile: ?ProfileIdc,
    level: ?u8,
    width: u16,
    height: u16,
    chroma_format: u2,
    bit_depth: u8,

    // Frame types
    i_frames: u32,
    p_frames: u32,
    b_frames: u32,

    pub fn ok(stats: ValidationStats) H264ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            // ...fill stats
        };
    }

    pub fn invalid(message: []const u8) H264ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            // ...zero stats
        };
    }
};
```

---

## 6. Testing Strategy

### 6.1 Unit Tests

#### 6.1.1 Component Tests

```zig
// NAL parsing tests
test "NAL start code detection - 3 byte" { ... }
test "NAL start code detection - 4 byte" { ... }
test "Emulation prevention byte removal" { ... }

// SPS parsing tests
test "Parse Baseline SPS" { ... }
test "Parse Main SPS" { ... }
test "Parse High SPS with scaling matrices" { ... }
test "Parse High 10 SPS" { ... }
test "Parse High 4:2:2 SPS" { ... }
test "Parse High 4:4:4 Predictive SPS" { ... }

// CAVLC tests
test "CAVLC coeff_token decode nC=0" { ... }
test "CAVLC level decode suffix_length=0" { ... }
test "CAVLC total_zeros decode" { ... }
test "CAVLC run_before decode" { ... }
test "CAVLC full 4x4 block decode" { ... }

// CABAC tests
test "CABAC arithmetic decode MPS" { ... }
test "CABAC arithmetic decode LPS" { ... }
test "CABAC context initialization" { ... }
test "CABAC mb_type decode I-slice" { ... }

// Transform tests
test "4x4 IDCT DC-only block" { ... }
test "4x4 IDCT general block" { ... }
test "8x8 IDCT DC-only block" { ... }
test "4x4 Hadamard inverse" { ... }
test "2x2 Hadamard inverse" { ... }

// Prediction tests
test "Intra 4x4 vertical mode" { ... }
test "Intra 4x4 horizontal mode" { ... }
test "Intra 4x4 DC mode" { ... }
test "Intra 16x16 plane mode" { ... }
test "Motion compensation half-pel horizontal" { ... }
test "Motion compensation quarter-pel diagonal" { ... }

// Deblocking tests
test "Calculate boundary strength intra edge" { ... }
test "Calculate boundary strength inter edge" { ... }
test "Filter samples bS=4" { ... }
```

### 6.2 Integration Tests

```zig
// Synthetic bitstreams
test "Decode minimal I-frame only stream" { ... }
test "Decode I+P frame stream" { ... }
test "Decode I+P+B frame stream" { ... }

// Profile-specific streams
test "Decode Baseline profile stream" { ... }
test "Decode Main profile stream with CABAC" { ... }
test "Decode High profile stream with 8x8 transform" { ... }
test "Decode High 10 profile 10-bit stream" { ... }
```

### 6.3 Conformance Testing

Use ITU-T conformance test vectors (non-GPL):

- **Source:** ITU-T H.264 conformance test streams
- **Location:** `es-core/ground_truth_examples/h264/`
- **Vectors to include:**
  - `BA1_Sony_D` - Baseline Level 1
  - `BA2_Sony_F` - Baseline Level 2
  - `BAMQ1_JVC_C` - Baseline MBAFF
  - `CAPM3_Sony_D` - Main Profile CABAC
  - `CVPCMNL1_SVA_C` - Main Profile slice groups
  - `HCBP1_HHI_A` - High Profile Baseline subset
  - `HCMP1_HHI_A` - High Profile Main subset

### 6.4 Fuzzing Strategy

```zig
// Fuzz targets
pub fn fuzzNalParser(data: []const u8) void;
pub fn fuzzSpsParser(data: []const u8) void;
pub fn fuzzCavlcDecoder(data: []const u8) void;
pub fn fuzzCabacDecoder(data: []const u8) void;
pub fn fuzzFullDecoder(data: []const u8) void;
```

---

## 7. Effort Estimates

### 7.1 Component Breakdown

| Component | Complexity | Estimated Days | Dependencies |
|-----------|------------|----------------|--------------|
| NAL Parser | Low | 2 | BitReader (exists) |
| SPS Parser | Medium | 3 | NAL Parser |
| PPS Parser | Low | 1 | SPS Parser |
| Slice Header Parser | Medium | 3 | PPS Parser |
| CAVLC Decoder | High | 5 | Slice Parser |
| CABAC Decoder | Very High | 8 | Slice Parser |
| Inverse Quantization | Medium | 2 | - |
| 4x4 Transform | Low | 1 | Existing DCT code |
| 8x8 Transform | Medium | 2 | 4x4 Transform |
| Hadamard Transforms | Low | 1 | - |
| Intra Prediction 4x4 | Medium | 3 | - |
| Intra Prediction 16x16 | Low | 1 | - |
| Intra Prediction 8x8 | Medium | 2 | (High profile) |
| Inter Prediction | High | 5 | Reference frames |
| Deblocking Filter | High | 4 | Decoded MBs |
| Reference Picture Management | High | 4 | DPB |
| Frame Assembly | Medium | 3 | All above |
| Validation API | Low | 2 | Decoder |
| Testing | Medium | 5 | All above |

### 7.2 Total Estimate

| Phase | Days | Notes |
|-------|------|-------|
| Baseline Profile | 25-30 | Core decoder + CAVLC |
| Main Profile | 8-10 | Add CABAC + B-frames |
| High Profile | 8-10 | Add 8x8 transforms |
| High 10/4:2:2/4:4:4 | 5-7 | Bit depth + chroma format changes |
| Testing & Polish | 10-15 | Conformance, fuzzing |
| **Total** | **56-72 days** | ~3-4 months with testing |

### 7.3 Risk Factors

| Risk | Impact | Mitigation |
|------|--------|------------|
| CABAC complexity | High | Start with CAVLC-only Baseline |
| B-frame reference management | Medium | Defer B-frames to phase 2 |
| High 4:4:4 lossless mode | Medium | Implement last |
| Conformance edge cases | Medium | Iterative testing |

---

## 8. References

### 8.1 Primary Specifications (Non-GPL)

1. **ITU-T Recommendation H.264** (04/2017)
   - "Advanced video coding for generic audiovisual services"
   - Official specification document
   - Available from ITU-T website

2. **ISO/IEC 14496-10**
   - MPEG-4 Part 10: Advanced Video Coding
   - Equivalent to H.264

### 8.2 BSD-Licensed Reference Software

1. **JM Reference Software**
   - Joint Model reference implementation
   - BSD-3-Clause license
   - Source: https://vcgit.hhi.fraunhofer.de/jvet/JM
   - Note: Reference for algorithm understanding only

2. **OpenH264** (Cisco)
   - BSD-2-Clause license
   - Already in use in codebase
   - Source: https://github.com/cisco/openh264
   - Note: Currently used for validation

### 8.3 Academic Papers

1. "Overview of the H.264/AVC Video Coding Standard"
   - Wiegand et al., IEEE TCSVT, July 2003

2. "Context-based adaptive binary arithmetic coding in the H.264/AVC video compression standard"
   - Marpe et al., IEEE TCSVT, July 2003

3. "H.264/MPEG-4 AVC Video Compression Tutorial"
   - Iain Richardson, Vcodex

### 8.4 Online Resources (Non-GPL)

1. **Vcodex H.264 White Paper**
   - https://www.vcodex.com/h264.html
   - Free educational resource

2. **Xiph.org Video Wiki**
   - https://wiki.xiph.org/Main_Page
   - General video codec information

3. **MultimediaWiki**
   - https://wiki.multimedia.cx/
   - Format documentation

---

## 9. Appendix: Existing Codebase Files for Reference

### 9.1 Directly Reusable

| File | What to Reuse |
|------|---------------|
| `bitstream_reader.zig` | Full BitReader with Exp-Golomb |
| `mpeg12_decoder.zig` | 8x8 IDCT pattern, zigzag order |
| `vp8_decoder.zig` | Arithmetic decoder pattern |
| `mpeg4p2_decoder.zig` | VLC tables, motion vectors |

### 9.2 Pattern Reference

| File | Pattern to Study |
|------|------------------|
| `prores_decoder.zig` | Slice structure, quantization |
| `theora_decoder.zig` | Token-based coefficient decoding |
| `flac_decoder.zig` | Rice coding (similar to H.264 CAVLC) |

### 9.3 Integration Points

| File | Integration |
|------|-------------|
| `h264_validator.zig` | Replace with pure-Zig decoder |
| `format_validation.zig` | Add H.264 to deep validation |
| `video_validator.zig` | Container extraction for H.264 |

---

**Document Version History:**

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01 | Initial specification |

---

*This specification was created referencing only ITU-T H.264, BSD-licensed software, and academic papers. No GPL-licensed code (FFmpeg, x264, etc.) was referenced or consulted.*
