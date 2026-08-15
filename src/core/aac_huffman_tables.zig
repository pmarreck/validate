//! AAC Spectral Huffman Codebook Tables & SWB Offset Tables
//!
//! Provides spectral Huffman decoding for AAC-LC bitstream validation.
//! Uses compact binary trees for bit-by-bit codeword decoding.
//! Only tracks bit consumption (not decoded values) since we're validating, not decoding.
//!
//! Tree encoding: each u32 entry is either:
//! - Branch: bit31=0, [30:16]=right_child_idx(bit=1), [15:0]=left_child_idx(bit=0)
//! - Leaf: bit31=1, [3:0]=sign_bits_count, [5:4]=escape_count
//!
//! Codebook data derived from ISO/IEC 14496-3 Table 4.A.2-4.A.12.
//! SWB offset data from ISO/IEC 14496-3 Table 4.110.

const BitReader = @import("bitstream_reader.zig").BitReader;

// ============================================================================
// Public Types
// ============================================================================

pub const DecodeResult = struct {
    /// Total bits consumed (codeword + sign bits + escape bits). 0 = invalid.
    bits_consumed: u16,
    valid: bool,
};

// ============================================================================
// Decode Functions
// ============================================================================

/// Decode one spectral Huffman code group from bitstream.
/// Returns total bits consumed (codeword + sign bits + escape bits), or invalid.
pub fn decodeSpectral(reader: *BitReader, codebook: u4) DecodeResult {
    if (codebook == 0 or codebook > 11) {
        return .{ .bits_consumed = 0, .valid = codebook == 0 };
    }

    const tree = getTree(codebook);
    const is_unsigned = cb_unsigned[codebook];
    const is_escape = (codebook == 11);

    // Walk the binary tree bit by bit
    var node_idx: u32 = 0;
    var bits: u16 = 0;

    while (bits < 32) { // sanity limit
        const entry = tree[node_idx];

        if (entry & 0x80000000 != 0) {
            // Leaf node
            const sign_bits: u16 = @intCast(entry & 0xF);
            const esc_count: u16 = @intCast((entry >> 4) & 0x3);

            // Read sign bits
            for (0..sign_bits) |_| {
                _ = reader.readBit() orelse return .{ .bits_consumed = 0, .valid = false };
                bits += 1;
            }

            // Read escape sequences (CB11 only)
            if (is_escape and esc_count > 0) {
                for (0..esc_count) |_| {
                    const esc_bits = readEscapeSequence(reader) orelse
                        return .{ .bits_consumed = 0, .valid = false };
                    bits += esc_bits;
                }
            }

            _ = is_unsigned; // used implicitly via tree leaf sign_bits encoding

            return .{ .bits_consumed = bits, .valid = true };
        }

        // Branch node - read one bit and follow
        const bit = reader.readBit() orelse return .{ .bits_consumed = 0, .valid = false };
        bits += 1;

        if (bit == 0) {
            node_idx = entry & 0xFFFF; // left child
        } else {
            node_idx = (entry >> 16) & 0x7FFF; // right child
        }
        if (node_idx == 0) {
            // Absent child (index 0 is the root, never a child): the walked
            // prefix is not a codeword of this codebook — invalid bitstream.
            return .{ .bits_consumed = 0, .valid = false };
        }
    }

    return .{ .bits_consumed = 0, .valid = false }; // too many bits
}

/// Read one CB11 escape sequence: count leading 1-bits (N), then read N+4 mantissa bits.
fn readEscapeSequence(reader: *BitReader) ?u16 {
    var n: u16 = 0;
    while (n < 20) { // sanity limit
        const bit = reader.readBit() orelse return null;
        if (bit == 0) break;
        n += 1;
    }
    if (n >= 20) return null;

    // Read N+4 mantissa bits
    const mantissa_bits: u6 = @intCast(n + 4);
    _ = reader.readBits(mantissa_bits) orelse return null;

    // Total bits: n+1 (for the leading 1s + terminating 0) + n+4 (mantissa)
    return n + 1 + n + 4;
}

/// Get the dimension (number of spectral values per codeword) for a codebook.
/// AAC codebook is a 4-bit field in the bitstream (`u4` range 0-15) but only
/// indices 0-11 are defined; 12-15 are reserved. Callers can forward raw
/// section_data values straight from an attacker-controlled stream, so a
/// reserved index must NOT index the 12-element table or we get a panic in
/// safe builds / UB in ReleaseFast.
pub fn cbDimension(codebook: u4) u3 {
    if (codebook > 11) return 0;
    return cb_dimension[codebook];
}

// ============================================================================
// Scalefactor Huffman Codebook (ISO 14496-3 Table 4.A.1)
//
// Binary tree with 241 entries. Each entry is [2]u8:
//   - If entry[1] == 0: leaf node, entry[0] = scalefactor index (0-120)
//   - If entry[1] != 0: internal node; for bit=0: offset += entry[0],
//     for bit=1: offset += entry[1]
//
// Returns scalefactor index (0-120). Caller computes delta = index - 60.
// ============================================================================

const sf_hcb = [241][2]u8{
    .{ 1, 2 },   .{ 60, 0 },  .{ 1, 2 },   .{ 2, 3 },   .{ 3, 4 },   .{ 59, 0 },  .{ 3, 4 },   .{ 4, 5 },
    .{ 5, 6 },   .{ 61, 0 },  .{ 58, 0 },  .{ 62, 0 },  .{ 3, 4 },   .{ 4, 5 },   .{ 5, 6 },   .{ 57, 0 },
    .{ 63, 0 },  .{ 4, 5 },   .{ 5, 6 },   .{ 6, 7 },   .{ 7, 8 },   .{ 56, 0 },  .{ 64, 0 },  .{ 55, 0 },
    .{ 65, 0 },  .{ 4, 5 },   .{ 5, 6 },   .{ 6, 7 },   .{ 7, 8 },   .{ 66, 0 },  .{ 54, 0 },  .{ 67, 0 },
    .{ 5, 6 },   .{ 6, 7 },   .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 53, 0 },  .{ 68, 0 },  .{ 52, 0 },
    .{ 69, 0 },  .{ 51, 0 },  .{ 5, 6 },   .{ 6, 7 },   .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 70, 0 },
    .{ 50, 0 },  .{ 49, 0 },  .{ 71, 0 },  .{ 6, 7 },   .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 },
    .{ 11, 12 }, .{ 72, 0 },  .{ 48, 0 },  .{ 73, 0 },  .{ 47, 0 },  .{ 74, 0 },  .{ 46, 0 },  .{ 6, 7 },
    .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 76, 0 },  .{ 75, 0 },  .{ 77, 0 },
    .{ 78, 0 },  .{ 45, 0 },  .{ 43, 0 },  .{ 6, 7 },   .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 },
    .{ 11, 12 }, .{ 44, 0 },  .{ 79, 0 },  .{ 42, 0 },  .{ 41, 0 },  .{ 80, 0 },  .{ 40, 0 },  .{ 6, 7 },
    .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 81, 0 },  .{ 39, 0 },  .{ 82, 0 },
    .{ 38, 0 },  .{ 83, 0 },  .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 12, 13 },
    .{ 13, 14 }, .{ 37, 0 },  .{ 35, 0 },  .{ 85, 0 },  .{ 33, 0 },  .{ 36, 0 },  .{ 34, 0 },  .{ 84, 0 },
    .{ 32, 0 },  .{ 6, 7 },   .{ 7, 8 },   .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 87, 0 },
    .{ 89, 0 },  .{ 30, 0 },  .{ 31, 0 },  .{ 8, 9 },   .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 12, 13 },
    .{ 13, 14 }, .{ 14, 15 }, .{ 15, 16 }, .{ 86, 0 },  .{ 29, 0 },  .{ 26, 0 },  .{ 27, 0 },  .{ 28, 0 },
    .{ 24, 0 },  .{ 88, 0 },  .{ 9, 10 },  .{ 10, 11 }, .{ 11, 12 }, .{ 12, 13 }, .{ 13, 14 }, .{ 14, 15 },
    .{ 15, 16 }, .{ 16, 17 }, .{ 17, 18 }, .{ 25, 0 },  .{ 22, 0 },  .{ 23, 0 },  .{ 15, 16 }, .{ 16, 17 },
    .{ 17, 18 }, .{ 18, 19 }, .{ 19, 20 }, .{ 20, 21 }, .{ 21, 22 }, .{ 22, 23 }, .{ 23, 24 }, .{ 24, 25 },
    .{ 25, 26 }, .{ 26, 27 }, .{ 27, 28 }, .{ 28, 29 }, .{ 29, 30 }, .{ 90, 0 },  .{ 21, 0 },  .{ 19, 0 },
    .{ 3, 0 },   .{ 1, 0 },   .{ 2, 0 },   .{ 0, 0 },   .{ 23, 24 }, .{ 24, 25 }, .{ 25, 26 }, .{ 26, 27 },
    .{ 27, 28 }, .{ 28, 29 }, .{ 29, 30 }, .{ 30, 31 }, .{ 31, 32 }, .{ 32, 33 }, .{ 33, 34 }, .{ 34, 35 },
    .{ 35, 36 }, .{ 36, 37 }, .{ 37, 38 }, .{ 38, 39 }, .{ 39, 40 }, .{ 40, 41 }, .{ 41, 42 }, .{ 42, 43 },
    .{ 43, 44 }, .{ 44, 45 }, .{ 45, 46 }, .{ 98, 0 },  .{ 99, 0 },  .{ 100, 0 }, .{ 101, 0 }, .{ 102, 0 },
    .{ 117, 0 }, .{ 97, 0 },  .{ 91, 0 },  .{ 92, 0 },  .{ 93, 0 },  .{ 94, 0 },  .{ 95, 0 },  .{ 96, 0 },
    .{ 104, 0 }, .{ 111, 0 }, .{ 112, 0 }, .{ 113, 0 }, .{ 114, 0 }, .{ 115, 0 }, .{ 116, 0 }, .{ 110, 0 },
    .{ 105, 0 }, .{ 106, 0 }, .{ 107, 0 }, .{ 108, 0 }, .{ 109, 0 }, .{ 118, 0 }, .{ 6, 0 },   .{ 8, 0 },
    .{ 9, 0 },   .{ 10, 0 },  .{ 5, 0 },   .{ 103, 0 }, .{ 120, 0 }, .{ 119, 0 }, .{ 4, 0 },   .{ 7, 0 },
    .{ 15, 0 },  .{ 16, 0 },  .{ 18, 0 },  .{ 20, 0 },  .{ 17, 0 },  .{ 11, 0 },  .{ 12, 0 },  .{ 14, 0 },
    .{ 13, 0 },
};

/// Decode one scalefactor Huffman codeword from the bitstream.
/// Returns the scalefactor index (0-120) or null if invalid/truncated.
/// The caller computes the delta as: index - 60.
pub fn decodeScalefactor(reader: *BitReader) ?u8 {
    var offset: u16 = 0;
    var bits: u16 = 0;

    while (sf_hcb[offset][1] != 0) {
        const bit = reader.readBit() orelse return null;
        offset += @as(u16, sf_hcb[offset][bit]);
        bits += 1;
        if (bits > 19) return null; // max codeword length is 19 bits
        if (offset >= sf_hcb.len) return null; // tree overflow
    }

    return sf_hcb[offset][0];
}

fn getTree(codebook: u4) []const u32 {
    return switch (codebook) {
        1 => &cb1_tree,
        2 => &cb2_tree,
        3 => &cb3_tree,
        4 => &cb4_tree,
        5 => &cb5_tree,
        6 => &cb6_tree,
        7 => &cb7_tree,
        8 => &cb8_tree,
        9 => &cb9_tree,
        10 => &cb10_tree,
        11 => &cb11_tree,
        else => &cb1_tree, // unreachable
    };
}

// ============================================================================
// SWB (Scalefactor Window Band) Offset Tables
// ISO 14496-3 Table 4.110
// ============================================================================

/// SWB offsets for ONLY_LONG_SEQUENCE (1024 samples), indexed by sampling_frequency_index
pub fn swbOffsetsLong(freq_idx: u4) []const u16 {
    const idx = @min(freq_idx, 12);
    return switch (idx) {
        0, 1 => &swb_offset_long_96,
        2 => &swb_offset_long_64,
        3, 4 => &swb_offset_long_48,
        5 => &swb_offset_long_32,
        6, 7 => &swb_offset_long_24,
        8, 9, 10 => &swb_offset_long_16,
        else => &swb_offset_long_8,
    };
}

/// SWB offsets for EIGHT_SHORT_SEQUENCE (128 samples), indexed by sampling_frequency_index
pub fn swbOffsetsShort(freq_idx: u4) []const u16 {
    const idx = @min(freq_idx, 12);
    return switch (idx) {
        0, 1 => &swb_offset_short_96,
        2 => &swb_offset_short_96, // 64 kHz uses same as 96 kHz
        3, 4, 5 => &swb_offset_short_48,
        6, 7 => &swb_offset_short_24,
        8, 9, 10 => &swb_offset_short_16,
        else => &swb_offset_short_8,
    };
}

// 96000 Hz / 88200 Hz (42 entries, 41 SFBs)
const swb_offset_long_96 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56,
    64, 72, 80, 88, 96, 108, 120, 132, 144, 156, 172, 188, 212, 240,
    276, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960, 1024,
};

// 64000 Hz (48 entries, 47 SFBs)
const swb_offset_long_64 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56,
    64, 72, 80, 88, 100, 112, 124, 140, 156, 172, 192, 216, 240, 268,
    304, 344, 384, 424, 464, 504, 544, 584, 624, 664, 704, 744, 784, 824,
    864, 904, 944, 984, 1024,
};

// 48000 Hz / 44100 Hz (50 entries, 49 SFBs)
const swb_offset_long_48 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72,
    80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292,
    320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736,
    768, 800, 832, 864, 896, 928, 1024,
};

// 32000 Hz (52 entries, 51 SFBs)
const swb_offset_long_32 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72,
    80, 88, 96, 108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292,
    320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736,
    768, 800, 832, 864, 896, 928, 960, 992, 1024,
};

// 24000 Hz / 22050 Hz (48 entries, 47 SFBs)
const swb_offset_long_24 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 52, 60, 68,
    76, 84, 92, 100, 108, 116, 124, 136, 148, 160, 172, 188, 204, 220,
    240, 260, 284, 308, 336, 364, 396, 432, 468, 508, 552, 600, 652, 704,
    768, 832, 896, 960, 1024,
};

// 16000 Hz / 12000 Hz / 11025 Hz (44 entries, 43 SFBs)
const swb_offset_long_16 = [_]u16{
    0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 100, 112, 124,
    136, 148, 160, 172, 184, 196, 212, 228, 244, 260, 280, 300, 320, 344,
    368, 396, 424, 456, 492, 532, 572, 616, 664, 716, 772, 832, 896, 960, 1024,
};

// 8000 Hz / 7350 Hz (41 entries, 40 SFBs)
const swb_offset_long_8 = [_]u16{
    0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 132, 144, 156, 172,
    188, 204, 220, 236, 252, 268, 288, 308, 328, 348, 372, 396, 420, 448,
    476, 508, 544, 580, 620, 664, 712, 764, 820, 880, 944, 1024,
};

// Short window offsets (128 samples)

// 96000 Hz / 88200 Hz / 64000 Hz (13 entries, 12 SFBs)
const swb_offset_short_96 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 92, 128,
};

// 48000 Hz / 44100 Hz / 32000 Hz (15 entries, 14 SFBs)
const swb_offset_short_48 = [_]u16{
    0, 4, 8, 12, 16, 20, 28, 36, 44, 56, 68, 80, 96, 112, 128,
};

// 24000 Hz / 22050 Hz (16 entries, 15 SFBs)
const swb_offset_short_24 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 64, 76, 92, 108, 128,
};

// 16000 Hz / 12000 Hz / 11025 Hz (16 entries, 15 SFBs)
const swb_offset_short_16 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 60, 72, 88, 108, 128,
};

// 8000 Hz / 7350 Hz (16 entries, 15 SFBs)
const swb_offset_short_8 = [_]u16{
    0, 4, 8, 12, 16, 20, 24, 28, 36, 44, 52, 60, 72, 88, 108, 128,
};

// ============================================================================
// Codebook Properties
// ============================================================================

/// Dimension (number of spectral values per codeword) for each codebook index 0-11
const cb_dimension = [12]u3{ 0, 4, 4, 4, 4, 2, 2, 2, 2, 2, 2, 2 };

/// Whether each codebook uses unsigned Huffman coding (sign bits follow codeword)
const cb_unsigned = [12]bool{ false, false, false, true, true, false, false, true, true, true, true, true };

// ============================================================================
// Spectral Huffman Codebook Binary Trees
//
// Built at comptime from the (codeword, length) REFERENCE tables in
// aac_codebook_reference.zig (transcribed from FFmpeg aactab.c, i.e.
// ISO/IEC 14496-3 Tables 4.A.2-4.A.12). Leaf metadata (sign-bit count,
// CB11 escape count) derives arithmetically from each table index per
// 14496-3 section 4.6.3.3.
//
// History: these trees were previously hand-embedded u32 literals; eight
// deep leaves (four cb9 sign counts, four cb10 branch paths) had drifted
// from the spec, so access units carrying large-magnitude spectral tuples
// — typically the FIRST frame of a loud or high-bitrate stream — failed to
// parse and produced "1 of N AAC access units could not be parsed" false
// positives on files every real decoder plays. The exhaustive differential
// test below sweeps every codeword of every codebook against the reference
// tables so any future drift is caught mechanically.
// ============================================================================

const ref = @import("aac_codebook_reference.zig");

/// Leaf metadata for the packed tree encoding: [3:0] sign-bit count
/// (unsigned codebooks emit one sign bit per nonzero tuple value) and
/// [5:4] escape count (CB11: one escape sequence per value == 16).
/// Tuple values are reconstructed from the codebook index per ISO 14496-3
/// section 4.6.3.3 (base-3 quads for CB1-4, offset pairs for CB5-11).
fn leafMeta(cb: u8, idx: usize) u32 {
    var vals: [4]i32 = .{ 0, 0, 0, 0 };
    var n: usize = 2;
    switch (cb) {
        1, 2, 3, 4 => {
            n = 4;
            var v: usize = idx;
            var k: usize = 4;
            const bias: i32 = if (cb <= 2) 1 else 0;
            while (k > 0) : (k -= 1) {
                vals[k - 1] = @as(i32, @intCast(v % 3)) - bias;
                v /= 3;
            }
        },
        5, 6 => {
            vals[0] = @as(i32, @intCast(idx / 9)) - 4;
            vals[1] = @as(i32, @intCast(idx % 9)) - 4;
        },
        7, 8 => {
            vals[0] = @intCast(idx / 8);
            vals[1] = @intCast(idx % 8);
        },
        9, 10 => {
            vals[0] = @intCast(idx / 13);
            vals[1] = @intCast(idx % 13);
        },
        11 => {
            vals[0] = @intCast(idx / 17);
            vals[1] = @intCast(idx % 17);
        },
        else => unreachable,
    }
    const is_signed = (cb == 1 or cb == 2 or cb == 5 or cb == 6);
    var sign_bits: u32 = 0;
    var esc: u32 = 0;
    for (vals[0..n]) |v| {
        if (!is_signed and v != 0) sign_bits += 1;
        if (cb == 11 and v == 16) esc += 1;
    }
    return (esc << 4) | sign_bits;
}

/// Build the packed binary decode tree for one codebook at comptime.
/// Node encoding (unchanged from the legacy arrays):
///   branch: bit31=0, [30:16] right-child index, [15:0] left-child index
///   leaf:   bit31=1, [5:4] escape count, [3:0] sign-bit count
/// Child index 0 means "no such child" (slot 0 is the root, which can never
/// be a child); decodeSpectral rejects it, which also covers codebooks whose
/// codespace is not complete. Duplicate or prefix-colliding codewords in the
/// reference data are compile errors.
fn buildTree(comptime entries: []const ref.CodeEntry, comptime cb: u8) [2 * entries.len]u32 {
    @setEvalBranchQuota(4_000_000);
    var nodes = [_]u32{0} ** (2 * entries.len);
    var node_count: u32 = 1; // slot 0 is the root branch
    for (entries, 0..) |e, idx| {
        var cur: u32 = 0;
        var i: u8 = e.len;
        while (i > 0) : (i -= 1) {
            const bit: u1 = @intCast((e.code >> @intCast(i - 1)) & 1);
            const child: u32 = if (bit == 0) nodes[cur] & 0xFFFF else (nodes[cur] >> 16) & 0x7FFF;
            if (i == 1) {
                if (child != 0) @compileError("duplicate/prefix-colliding codeword in reference table");
                const leaf: u32 = node_count;
                node_count += 1;
                nodes[leaf] = 0x80000000 | leafMeta(cb, idx);
                if (bit == 0) nodes[cur] |= leaf else nodes[cur] |= leaf << 16;
            } else {
                var next = child;
                if (next == 0) {
                    next = node_count;
                    node_count += 1;
                    if (bit == 0) nodes[cur] |= next else nodes[cur] |= next << 16;
                } else if (nodes[next] & 0x80000000 != 0) {
                    @compileError("codeword extends past an existing leaf in reference table");
                }
                cur = next;
            }
        }
    }
    return nodes;
}

const cb1_tree = buildTree(&ref.cb1, 1);
const cb2_tree = buildTree(&ref.cb2, 2);
const cb3_tree = buildTree(&ref.cb3, 3);
const cb4_tree = buildTree(&ref.cb4, 4);
const cb5_tree = buildTree(&ref.cb5, 5);
const cb6_tree = buildTree(&ref.cb6, 6);
const cb7_tree = buildTree(&ref.cb7, 7);
const cb8_tree = buildTree(&ref.cb8, 8);
const cb9_tree = buildTree(&ref.cb9, 9);
const cb10_tree = buildTree(&ref.cb10, 10);
const cb11_tree = buildTree(&ref.cb11, 11);

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "decodeSpectral CB0 returns valid with 0 bits" {
    var data = [_]u8{0xFF};
    var reader = BitReader.init(&data);
    const result = decodeSpectral(&reader, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 0), result.bits_consumed);
    try std.testing.expectEqual(@as(usize, 0), reader.getBitPosition());
}

test "decodeSpectral CB1 shortest codeword" {
    // CB1 shortest code: '0' -> (0,0,0,0), signed, no sign bits
    var data = [_]u8{0x00}; // bit 0 = '0'
    var reader = BitReader.init(&data);
    const result = decodeSpectral(&reader, 1);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 1), result.bits_consumed);
}

test "decodeSpectral CB7 unsigned with sign bits" {
    // CB7 is unsigned, shortest code '0' -> (0,0), 0 sign bits
    var data = [_]u8{0x00};
    var reader = BitReader.init(&data);
    const result = decodeSpectral(&reader, 7);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u16, 1), result.bits_consumed);
}

test "swbOffsetsLong returns correct data" {
    // freq_idx=4 (44100 Hz) -> swb_offset_long_48
    const offsets = swbOffsetsLong(4);
    try std.testing.expectEqual(@as(u16, 0), offsets[0]);
    try std.testing.expectEqual(@as(u16, 1024), offsets[offsets.len - 1]);
}

test "swbOffsetsShort returns correct data" {
    // freq_idx=4 (44100 Hz) -> swb_offset_short_48
    const offsets = swbOffsetsShort(4);
    try std.testing.expectEqual(@as(u16, 0), offsets[0]);
    try std.testing.expectEqual(@as(u16, 128), offsets[offsets.len - 1]);
}

test "cbDimension correct" {
    try std.testing.expectEqual(@as(u3, 4), cbDimension(1));
    try std.testing.expectEqual(@as(u3, 4), cbDimension(2));
    try std.testing.expectEqual(@as(u3, 2), cbDimension(5));
    try std.testing.expectEqual(@as(u3, 2), cbDimension(11));
}

test "cbDimension rejects reserved indices 12-15" {
    // AAC spec leaves codebook 12-15 reserved. Raw bitstream u4 fields can
    // forward them straight to cbDimension; the guard must keep the lookup
    // from reading past the 12-element table.
    try std.testing.expectEqual(@as(u3, 0), cbDimension(12));
    try std.testing.expectEqual(@as(u3, 0), cbDimension(13));
    try std.testing.expectEqual(@as(u3, 0), cbDimension(14));
    try std.testing.expectEqual(@as(u3, 0), cbDimension(15));
}

// ============================================================================
// Exhaustive differential tests against the independent reference tables
// (aac_codebook_reference.zig, transcribed from FFmpeg aactab.c / ISO
// 14496-3 Tables 4.A.1-4.A.12). Every codeword of every codebook must decode
// as valid and consume exactly len + sign_bits + escape_bits. Hand-built tree
// nodes that drift from the spec (the cb9/cb10 deep-leaf corruption behind
// the "1 of N AAC access units" false positives) cannot survive this sweep.
// ============================================================================

const ref_tables = @import("aac_codebook_reference.zig");

/// Derive tuple sign-bit and escape counts arithmetically from the codebook
/// index per ISO 14496-3 section 4.6.3.3 (unsigned books emit one sign bit
/// per nonzero value; CB11 additionally emits one escape per value == 16).
fn refTupleStats(cb: u8, idx: usize) struct { nz: u16, esc: u16 } {
    var vals: [4]i32 = .{ 0, 0, 0, 0 };
    var n: usize = 2;
    switch (cb) {
        1, 2, 3, 4 => {
            n = 4;
            var v: usize = idx;
            var k: usize = 4;
            const bias: i32 = if (cb <= 2) 1 else 0;
            while (k > 0) : (k -= 1) {
                vals[k - 1] = @as(i32, @intCast(v % 3)) - bias;
                v /= 3;
            }
        },
        5, 6 => {
            vals[0] = @as(i32, @intCast(idx / 9)) - 4;
            vals[1] = @as(i32, @intCast(idx % 9)) - 4;
        },
        7, 8 => {
            vals[0] = @intCast(idx / 8);
            vals[1] = @intCast(idx % 8);
        },
        9, 10 => {
            vals[0] = @intCast(idx / 13);
            vals[1] = @intCast(idx % 13);
        },
        11 => {
            vals[0] = @intCast(idx / 17);
            vals[1] = @intCast(idx % 17);
        },
        else => unreachable,
    }
    const signed = (cb == 1 or cb == 2 or cb == 5 or cb == 6);
    var nz: u16 = 0;
    var esc: u16 = 0;
    for (vals[0..n]) |v| {
        if (!signed and v != 0) nz += 1;
        if (cb == 11 and v == 16) esc += 1;
    }
    return .{ .nz = nz, .esc = esc };
}

/// Write `len` bits of `code` MSB-first into buf starting at bit 0.
fn refWriteCode(buf: []u8, code: u32, len: u8) void {
    var bitpos: usize = 0;
    var i: u8 = len;
    while (i > 0) : (i -= 1) {
        const bit: u1 = @intCast((code >> @intCast(i - 1)) & 1);
        if (bit == 1) buf[bitpos / 8] |= @as(u8, 0x80) >> @intCast(bitpos % 8);
        bitpos += 1;
    }
}

fn refCheckBook(cb: u8, entries: []const ref_tables.CodeEntry) !void {
    for (entries, 0..) |e, idx| {
        const st = refTupleStats(cb, idx);
        // Synthetic trailing bits are all zero: each sign bit reads 0, each
        // CB11 escape reads "0" + 4 zero mantissa bits (5 bits).
        const expected: u16 = @as(u16, e.len) + st.nz + 5 * st.esc;
        var buf = [_]u8{0} ** 12;
        refWriteCode(&buf, e.code, e.len);
        var reader = BitReader.init(buf[0 .. (expected + 7) / 8 + 1]);
        const r = decodeSpectral(&reader, @intCast(cb));
        if (!r.valid or r.bits_consumed != expected) {
            std.debug.print(
                "cb{d} idx={d} code=0x{x}/{d}b expected {d} bits, got valid={} consumed={d}\n",
                .{ cb, idx, e.code, e.len, expected, r.valid, r.bits_consumed },
            );
            return error.SpectralCodebookMismatch;
        }
    }
}

test "spectral Huffman trees match ISO reference on every codeword of every codebook" {
    try refCheckBook(1, &ref_tables.cb1);
    try refCheckBook(2, &ref_tables.cb2);
    try refCheckBook(3, &ref_tables.cb3);
    try refCheckBook(4, &ref_tables.cb4);
    try refCheckBook(5, &ref_tables.cb5);
    try refCheckBook(6, &ref_tables.cb6);
    try refCheckBook(7, &ref_tables.cb7);
    try refCheckBook(8, &ref_tables.cb8);
    try refCheckBook(9, &ref_tables.cb9);
    try refCheckBook(10, &ref_tables.cb10);
    try refCheckBook(11, &ref_tables.cb11);
}

test "scalefactor Huffman tree matches ISO reference on all 121 codewords" {
    for (ref_tables.scalefactor, 0..) |e, idx| {
        var buf = [_]u8{0} ** 8;
        refWriteCode(&buf, e.code, e.len);
        var reader = BitReader.init(&buf);
        const before = reader.remainingBits();
        const got = decodeScalefactor(&reader);
        const consumed = before - reader.remainingBits();
        try std.testing.expect(got != null);
        try std.testing.expectEqual(@as(u8, @intCast(idx)), got.?);
        try std.testing.expectEqual(@as(usize, e.len), consumed);
    }
}
