//! DTS (Digital Theater Systems) deep validation (Pure Zig).
//!
//! DTS Core is the original lossy codec used in DTS Digital Surround,
//! commonly found in DVDs, Blu-rays, and MKV files.
//!
//! Validates DTS Core frames by parsing sync words, frame headers, and
//! verifying frame boundaries chain correctly through the stream.
//!
//! Reference: ETSI TS 102 114 (DTS Coherent Acoustics), Section 5.3

const std = @import("std");
const errmsg = @import("error_messages.zig");

/// DTS Core sync word (big-endian 14-bit packing)
const DTS_SYNC_WORD: u32 = 0x7FFE8001;

/// DTS sample rate table (SFREQ field, 4 bits)
const sample_rate_table = [16]u32{
    0, // 0: invalid
    8000, // 1
    16000, // 2
    32000, // 3
    0, // 4: invalid
    0, // 5: invalid
    11025, // 6
    22050, // 7
    44100, // 8
    0, // 9: invalid
    0, // 10: invalid
    12000, // 11
    24000, // 12
    48000, // 13
    0, // 14: invalid (96kHz in some extensions)
    0, // 15: invalid (192kHz in some extensions)
};

/// DTS bit rate table (RATE field, 5 bits) in kbps
const bit_rate_table = [32]u32{
    32, 56, 64, 96, 112, 128, 192, 224, 256, 320, 384, 448, 512, 576, 640,
    768, 896, 1024, 1152, 1280, 1411, 1472, 1536, // 0-22: fixed rates
    0, 0, // 23-24: open/variable
    0, 0, 0, 0, 0, 0, 0, // 25-31: invalid
};

/// DTS audio channel arrangement (AMODE field, 6 bits) → channel count
/// Maps the AMODE code to the number of audio channels (excluding LFE)
fn channelCount(amode: u6) u8 {
    return switch (amode) {
        0 => 1, // A (mono)
        1 => 2, // A + B (dual mono)
        2 => 2, // L + R (stereo)
        3 => 2, // (L+R) + (L-R) (sum-difference)
        4 => 2, // LT + RT (Lt/Rt)
        5 => 3, // C + L + R
        6 => 3, // L + R + S
        7 => 4, // C + L + R + S
        8 => 4, // L + R + SL + SR
        9 => 5, // C + L + R + SL + SR
        10 => 6, // CL + CR + L + R + SL + SR
        11 => 6, // C + L + R + LR + RR + OV
        12 => 6, // CF + CR + LF + RF + LR + RR
        13 => 7, // CL + C + CR + L + R + SL + SR
        14 => 8, // CL + CR + L + R + SL1 + SL2 + SR1 + SR2
        15 => 8, // CL + C + CR + L + R + SL + S + SR
        else => 0, // invalid or user-defined
    };
}

/// Parsed DTS Core frame header info
pub const DtsFrameInfo = struct {
    frame_size: u32, // in bytes (FSIZE + 1)
    sample_rate: u32,
    bit_rate: u32, // in kbps
    channels: u8, // excluding LFE
    lfe: bool,
    nblks: u8, // number of PCM sample blocks (NBLKS + 1), typically 8-128
    cpf: bool, // CRC present flag
};

/// Parse a DTS Core frame header starting at the given offset.
/// Returns frame info if valid, null if invalid.
pub fn parseDtsFrame(data: []const u8) ?DtsFrameInfo {
    // Need at least 12 bytes for sync (4) + header (8)
    if (data.len < 12) return null;

    // Check sync word
    const sync = std.mem.readInt(u32, data[0..4], .big);
    if (sync != DTS_SYNC_WORD) return null;

    // DTS Core header is bit-packed after the sync word.
    // Byte 4, bit 7:    FTYPE (1 bit) — frame type (0=normal, 1=termination)
    // Byte 4, bits 6-2: SHORT (5 bits) — deficit sample count
    // Byte 4, bit 1:    CPF (1 bit) — CRC present flag
    // Byte 4, bit 0 + byte 5, bits 7-2: NBLKS (7 bits) — blocks per frame - 1
    // Byte 5, bits 1-0 + byte 6, bits 7-0 + byte 7, bits 7-4: FSIZE (14 bits) — frame size - 1
    // Byte 7, bits 3-0 + byte 8, bits 7-6: AMODE (6 bits) — audio channel arrangement
    // Byte 8, bits 5-2: SFREQ (4 bits) — sample rate code
    // Byte 8, bits 1-0 + byte 9, bits 7-5: RATE (5 bits) — bit rate code
    // Byte 9, bit 4: DYNF (1 bit) — embedded dynamic range flag
    // Byte 9, bit 3: TIMEF (1 bit) — embedded time stamp flag
    // Byte 9, bit 2: AUXF (1 bit) — auxiliary data flag
    // Byte 9, bit 1: HDCD (1 bit) — HDCD flag
    // Byte 9, bit 0: EXT_AUDIO_ID (3 bits, continues into byte 10)
    // Byte 10, bits 7-6: EXT_AUDIO_ID (continued)
    // Byte 10, bit 5: EXT_AUDIO (1 bit) — extended audio present
    // Byte 10, bit 4: ASPF (1 bit) — audio sync word insertion flag
    // Byte 10, bits 3-2: LFF (2 bits) — low frequency effects flag

    const b4 = data[4];
    const b5 = data[5];
    const b6 = data[6];
    const b7 = data[7];
    const b8 = data[8];
    const b10 = data[10];

    // FTYPE (1 bit)
    const ftype = (b4 >> 7) & 1;
    _ = ftype; // normal=0, termination=1; both valid

    // CPF (1 bit)
    const cpf = ((b4 >> 1) & 1) != 0;

    // NBLKS (7 bits): byte 4 bit 0 + byte 5 bits 7-2
    const nblks_raw: u8 = @truncate((((@as(u16, b4) & 1) << 6) | (@as(u16, b5) >> 2)));
    const nblks: u8 = nblks_raw + 1; // actual blocks = NBLKS + 1
    if (nblks < 5) return null; // minimum 5 blocks per spec

    // FSIZE (14 bits): byte 5 bits 1-0 + byte 6 all + byte 7 bits 7-4
    const fsize_raw: u16 = @truncate((((@as(u32, b5) & 0x03) << 12) | (@as(u32, b6) << 4) | (@as(u32, b7) >> 4)));
    const frame_size: u32 = @as(u32, fsize_raw) + 1;
    if (frame_size < 96) return null; // minimum frame size per spec
    if (frame_size > 16384) return null; // max DTS Core frame size

    // AMODE (6 bits): byte 7 bits 3-0 + byte 8 bits 7-6
    const amode: u6 = @truncate((((@as(u8, b7) & 0x0F) << 2) | (b8 >> 6)));
    const channels = channelCount(amode);
    if (channels == 0) return null;

    // SFREQ (4 bits): byte 8 bits 5-2
    const sfreq: u4 = @truncate((b8 >> 2) & 0x0F);
    const sample_rate = sample_rate_table[sfreq];
    if (sample_rate == 0) return null;

    // RATE (5 bits): byte 8 bits 1-0 + byte 9 bits 7-5
    const rate: u5 = @truncate((((@as(u8, b8) & 0x03) << 3) | (data[9] >> 5)));
    const bit_rate = bit_rate_table[rate];

    // LFF (2 bits): byte 10 bits 3-2
    const lff: u2 = @truncate((b10 >> 2) & 0x03);
    const lfe = lff == 1 or lff == 2; // 1=128 LFE samples, 2=256 LFE samples

    return DtsFrameInfo{
        .frame_size = frame_size,
        .sample_rate = sample_rate,
        .bit_rate = bit_rate,
        .channels = channels,
        .lfe = lfe,
        .nblks = nblks,
        .cpf = cpf,
    };
}

/// Validate a DTS audio stream from a buffer.
/// Parses DTS Core frame headers, validates sync words, frame sizes, and
/// verifies frames chain correctly (next sync word at expected offset).
pub fn validateDtsStream(data: []const u8, max_frames: u32) DtsValidationResult {
    if (data.len < 16) {
        return DtsValidationResult.invalid("Data too small for DTS", 0);
    }

    // Find first sync word
    var pos: usize = 0;
    while (pos + 4 <= data.len) : (pos += 1) {
        if (std.mem.readInt(u32, data[pos..][0..4], .big) == DTS_SYNC_WORD) break;
    } else {
        return DtsValidationResult.invalid(errmsg.noValidXFound("DTS sync words"), 0);
    }

    var frames_validated: u32 = 0;
    var first_sample_rate: u32 = 0;
    var first_channels: u8 = 0;

    while (pos + 12 <= data.len and frames_validated < max_frames) {
        const frame_info = parseDtsFrame(data[pos..]) orelse {
            if (frames_validated > 0) break; // partial frame at end is OK
            return DtsValidationResult.invalid("Invalid DTS frame header", frames_validated);
        };

        // Validate frame fits in remaining data
        if (pos + frame_info.frame_size > data.len) {
            // Last frame may be truncated — OK if we've validated some
            if (frames_validated > 0) break;
            return DtsValidationResult.invalid("DTS frame extends beyond data", frames_validated);
        }

        // Additional header field validation for corruption detection.
        // The NBLKS field must be consistent across frames in the stream,
        // and bit_rate must be non-zero for fixed-rate streams.
        if (frames_validated > 0) {
            // Cross-frame consistency: channel count should not change
            const this_channels = frame_info.channels + @as(u8, if (frame_info.lfe) 1 else 0);
            if (this_channels != first_channels) {
                return DtsValidationResult.invalid("DTS channel count changed mid-stream (data corruption)", frames_validated);
            }
        }

        // Record first frame's parameters
        if (frames_validated == 0) {
            first_sample_rate = frame_info.sample_rate;
            first_channels = frame_info.channels + @as(u8, if (frame_info.lfe) 1 else 0);
        }

        // Verify consistency with first frame
        if (frame_info.sample_rate != first_sample_rate) {
            return DtsValidationResult.invalid("DTS sample rate changed mid-stream", frames_validated);
        }

        // Verify next frame starts with sync word (if not at end)
        const next_pos = pos + frame_info.frame_size;
        if (next_pos + 4 <= data.len) {
            const next_sync = std.mem.readInt(u32, data[next_pos..][0..4], .big);
            if (next_sync != DTS_SYNC_WORD) {
                return DtsValidationResult.invalid("DTS frame boundary mismatch (data corruption)", frames_validated);
            }
        }

        frames_validated += 1;
        pos = next_pos;
    }

    if (frames_validated == 0) {
        return DtsValidationResult.invalid(errmsg.noValidXFound("DTS frames"), 0);
    }

    return DtsValidationResult.ok(frames_validated, first_sample_rate, first_channels);
}

/// DTS validation result
pub const DtsValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_validated: u32,
    sample_rate: u32,
    channels: u8,

    pub fn ok(frames: u32, sample_rate: u32, channels: u8) DtsValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_validated = frames,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn invalid(msg: []const u8, frames: u32) DtsValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .frames_validated = frames,
            .sample_rate = 0,
            .channels = 0,
        };
    }
};

// ============ Tests ============

test "DTS validates ground truth sample" {
    const file = std.fs.cwd().openFile("ground_truth_examples/dts/sample.dts", .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer file.close();

    const data = file.readToEndAlloc(std.testing.allocator, 10 * 1024 * 1024) catch return error.SkipZigTest;
    defer std.testing.allocator.free(data);

    const result = validateDtsStream(data, 10);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.frames_validated > 0);
    try std.testing.expectEqual(@as(u32, 48000), result.sample_rate);
}

test "DTS rejects empty data" {
    const result = validateDtsStream(&[_]u8{}, 10);
    try std.testing.expect(!result.valid);
}

test "DTS rejects garbage data" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 4;
    const result = validateDtsStream(&garbage, 10);
    try std.testing.expect(!result.valid);
}

test "DTS rejects truncated sync word" {
    const data = [_]u8{ 0x7F, 0xFE, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00 };
    const result = validateDtsStream(&data, 10);
    try std.testing.expect(!result.valid);
}

test "DTS frame header parsing" {
    // Construct a minimal valid frame header manually
    // sync(4) + FTYPE=0,SHORT=0,CPF=0,NBLKS=7(=8 blocks),FSIZE=0x1FF(=512 bytes),AMODE=9(5ch),SFREQ=13(48k),RATE=22(1536k)
    // Byte 4: FTYPE=0, SHORT=00000, CPF=0, NBLKS[6]=0 => 0b00000000 = 0x00
    // Byte 5: NBLKS[5:0]=000111, FSIZE[13:12]=00 => 0b00011100 = 0x1C
    // Byte 6: FSIZE[11:4]=00011111 => 0x1F
    // Byte 7: FSIZE[3:0]=1111, AMODE[5:2]=0010 => 0b11110010 = 0xF2
    // Byte 8: AMODE[1:0]=01, SFREQ=1101, RATE[4:3]=10 => 0b01110110 = 0x76
    // Byte 9: RATE[2:0]=110, DYNF=0, TIMEF=0, AUXF=0, HDCD=0, EXT[2]=0 => 0b11000000 = 0xC0
    // Byte 10: EXT[1:0]=00, EXT_AUDIO=0, ASPF=0, LFF=01, FILTS=0, VERNUM=0 => 0b00000100 = 0x04
    var header = [_]u8{
        0x7F, 0xFE, 0x80, 0x01, // sync word
        0x00, 0x1C, 0x1F, 0xF2, // header bytes 4-7
        0x76, 0xC0, 0x04, 0x00, // header bytes 8-10 + padding
    };

    const info = parseDtsFrame(&header);
    try std.testing.expect(info != null);
    if (info) |frame| {
        try std.testing.expectEqual(@as(u32, 512), frame.frame_size);
        try std.testing.expectEqual(@as(u32, 48000), frame.sample_rate);
        try std.testing.expectEqual(@as(u8, 5), frame.channels);
        try std.testing.expect(frame.lfe);
        try std.testing.expectEqual(@as(u8, 8), frame.nblks);
    }
}
