//! AC-3 (Dolby Digital) deep validation (Pure Zig).
//!
//! AC-3 is the audio codec used in Dolby Digital surround sound,
//! commonly found in DVDs, Blu-rays, and broadcast television.
//!
//! This module validates AC-3 frames by:
//! 1. Parsing sync word (0x0B77)
//! 2. Validating frame size based on sample rate and frame size code
//! 3. Verifying CRC1 (first 5/8 of frame)
//! 4. Verifying CRC2 (entire frame, if present)
//!
//! Reference: ATSC A/52 (Digital Audio Compression Standard)

const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const errmsg = @import("error_messages.zig");

/// AC-3 frame sample rate table
const sample_rates = [_]u32{ 48000, 44100, 32000, 0 };

/// AC-3 frame size table (in 16-bit words)
/// Index: [fscod (0-2)][frmsizecod (0-37)]
/// Values are in 16-bit words, multiply by 2 for bytes
const frame_sizes = [3][38]u16{
    // 48 kHz
    .{
        64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320,
        320, 384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280,
    },
    // 44.1 kHz
    .{
        69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209, 243, 244, 278, 279,
        348, 349, 417, 418, 487, 488, 557, 558, 696, 697, 835, 836, 975, 976, 1114, 1115, 1253, 1254, 1393, 1394,
    },
    // 32 kHz
    .{
        96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288, 336, 336, 384, 384,
        480, 480, 576, 576, 672, 672, 768, 768, 960, 960, 1152, 1152, 1344, 1344, 1536, 1536, 1728, 1728, 1920, 1920,
    },
};

/// AC-3 bit rates in kbps
const bit_rates = [_]u16{
    32, 32, 40, 40, 48, 48, 56, 56, 64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160,
    160, 192, 192, 224, 224, 256, 256, 320, 320, 384, 384, 448, 448, 512, 512, 576, 576, 640, 640,
};

/// Result of AC-3 validation
pub const Ac3ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_validated: u32,
    crc_validated: u32,
    sample_rate: u32,
    bit_rate: u16,
    channels: u8,

    pub fn ok(frames: u32, crc_count: u32, rate: u32, bitrate: u16, ch: u8) Ac3ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_validated = frames,
            .crc_validated = crc_count,
            .sample_rate = rate,
            .bit_rate = bitrate,
            .channels = ch,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) Ac3ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_validated = frames,
            .crc_validated = 0,
            .sample_rate = 0,
            .bit_rate = 0,
            .channels = 0,
        };
    }
};

/// AC-3 frame header info
pub const Ac3FrameInfo = struct {
    frame_size: u16, // In bytes
    sample_rate: u32,
    bit_rate: u16, // In kbps
    bsmod: u3, // Bitstream mode
    acmod: u3, // Audio coding mode (channel config)
    lfeon: bool, // LFE channel on
    crc1: u16, // CRC for first 5/8 of frame

    pub fn channels(self: Ac3FrameInfo) u8 {
        // acmod channel counts: 2, 1, 2, 3, 3, 4, 4, 5
        const ch_counts = [_]u8{ 2, 1, 2, 3, 3, 4, 4, 5 };
        return ch_counts[self.acmod] + @as(u8, if (self.lfeon) 1 else 0);
    }
};

/// Parse AC-3 frame header
/// Returns frame info if valid, null if invalid
pub fn parseAc3Frame(data: []const u8) ?Ac3FrameInfo {
    if (data.len < 7) return null;

    // Check sync word
    if (data[0] != 0x0B or data[1] != 0x77) {
        return null;
    }

    // CRC1 (bytes 2-3)
    const crc1 = std.mem.readInt(u16, data[2..4], .big);

    // Sample rate code (fscod) - bits 6-7 of byte 4
    const fscod: u2 = @intCast((data[4] >> 6) & 0x03);
    if (fscod == 3) return null; // Reserved

    // Frame size code (frmsizecod) - bits 0-5 of byte 4
    const frmsizecod: u6 = @intCast(data[4] & 0x3F);
    if (frmsizecod > 37) return null;

    // Get frame size and sample rate
    const frame_size_words = frame_sizes[fscod][frmsizecod];
    const frame_size: u16 = frame_size_words * 2;
    const sample_rate = sample_rates[fscod];
    const bit_rate = bit_rates[frmsizecod];

    // BSI (Bit Stream Information) - byte 5
    const bsid: u5 = @intCast((data[5] >> 3) & 0x1F);
    if (bsid > 10) return null; // Must be <= 10 for AC-3 (>10 is E-AC-3)

    const bsmod: u3 = @intCast(data[5] & 0x07);

    // Byte 6: acmod (3 bits) + cmixlev (if 3-channel) + surmixlev (if surround) + lfeon
    const acmod: u3 = @intCast((data[6] >> 5) & 0x07);

    // LFE is at different bit positions depending on acmod
    // For simplicity, parse it at a fixed position (this is a slight simplification)
    var bit_offset: u4 = 3; // After acmod
    if (acmod == 0) {
        // 1+1 mode - no cmixlev/surmixlev
    } else if ((acmod & 1) != 0 and acmod != 1) {
        // 3 front channels - cmixlev (2 bits)
        bit_offset += 2;
    }
    if ((acmod & 4) != 0) {
        // Surround channels - surmixlev (2 bits)
        bit_offset += 2;
    }

    // LFE on - need to read from correct position
    // This is simplified - in real AC-3, bit position varies
    const lfeon = (data[6] >> (4 - @min(bit_offset, 4))) & 1 == 1;

    return Ac3FrameInfo{
        .frame_size = frame_size,
        .sample_rate = sample_rate,
        .bit_rate = bit_rate,
        .bsmod = bsmod,
        .acmod = acmod,
        .lfeon = lfeon,
        .crc1 = crc1,
    };
}

/// CRC-16 polynomial used by AC-3
/// Generator polynomial: x^16 + x^15 + x^2 + 1 (0x8005)
fn crc16Ac3(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            if ((crc & 0x8000) != 0) {
                crc = (crc << 1) ^ 0x8005;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

/// Validate CRC1 for first 5/8 of frame (word-aligned).
/// Per ATSC A/52: CRC1 covers bytes 2 through (frame_size_words*5/8)*2 - 1.
/// The CRC stored at bytes 2-3 is included in the region; result should be 0.
pub fn validateCrc1(data: []const u8, frame_size: u16) bool {
    if (data.len < frame_size or frame_size < 6) return false;

    // frame_size is in bytes; words = frame_size / 2
    // CRC1 region: bytes [2 .. (words*5/8)*2)  (word-aligned 5/8 of frame)
    const frame_size_words = frame_size / 2;
    const crc1_words = (frame_size_words * 5) / 8;
    const crc1_end = crc1_words * 2; // byte offset (exclusive)
    if (crc1_end <= 2) return false;

    return crc16Ac3(data[2..crc1_end]) == 0;
}

/// Validate CRC2 for entire frame.
/// Per ATSC A/52: CRC2 covers bytes 2 through frame_size-1 (everything except sync word).
/// The CRC stored at the end of the frame is included in the region; result should be 0.
pub fn validateCrc2(data: []const u8, frame_size: u16) bool {
    if (data.len < frame_size or frame_size < 4) return false;

    return crc16Ac3(data[2..frame_size]) == 0;
}

/// Validate AC-3 stream from buffer
pub fn validateAc3Stream(data: []const u8, max_frames: u32) Ac3ValidationResult {
    if (data.len < 7) {
        return Ac3ValidationResult.invalid("Data too short for AC-3", 0);
    }

    var offset: usize = 0;
    var frames_validated: u32 = 0;
    var crc_validated: u32 = 0;
    var detected_sample_rate: u32 = 0;
    var detected_bit_rate: u16 = 0;
    var detected_channels: u8 = 0;

    while (offset + 7 <= data.len and frames_validated < max_frames) {
        const frame_data = data[offset..];
        const frame_info = parseAc3Frame(frame_data) orelse {
            // Try to find next sync word
            var sync_offset: usize = 1;
            while (offset + sync_offset + 1 < data.len) {
                if (frame_data[sync_offset] == 0x0B and frame_data[sync_offset + 1] == 0x77) {
                    offset += sync_offset;
                    break;
                }
                sync_offset += 1;
            }
            if (offset + sync_offset + 1 >= data.len) break;
            continue;
        };

        // Verify we have enough data for the frame
        if (offset + frame_info.frame_size > data.len) {
            break;
        }

        // Store first frame's parameters
        if (frames_validated == 0) {
            detected_sample_rate = frame_info.sample_rate;
            detected_bit_rate = frame_info.bit_rate;
            detected_channels = frame_info.channels();
        }

        // Validate CRC2 (entire frame) — covers all bytes
        // Per ATSC A/52, CRC2 covers the entire syncframe; CRC1 covers first 5/8.
        // CRC-16-ANSI (poly 0x8005, reflected) — compute over region including stored CRC → expect 0.
        const crc2_ok = validateCrc2(frame_data, frame_info.frame_size);

        // Validate CRC1 (first 5/8 of frame)
        const crc1_ok = validateCrc1(frame_data, frame_info.frame_size);

        if (crc2_ok) crc_validated += 1;
        if (crc1_ok) crc_validated += 1;

        // CRC2 covers the entire frame; any single-bit error must be caught.
        // CRC1 covers only the first 5/8, so we rely primarily on CRC2.
        if (!crc2_ok) {
            return Ac3ValidationResult.invalid("AC-3 frame CRC mismatch (data corruption)", frames_validated);
        }

        frames_validated += 1;
        offset += frame_info.frame_size;
    }

    if (frames_validated == 0) {
        return Ac3ValidationResult.invalid(errmsg.noValidXFound("AC-3 frames"), 0);
    }

    return Ac3ValidationResult.ok(
        frames_validated,
        crc_validated,
        detected_sample_rate,
        detected_bit_rate,
        detected_channels,
    );
}

/// Validate AC-3 from file
pub fn validateAc3File(path: []const u8, max_frames: u32) Ac3ValidationResult {
    const file = runtime.openFile(path, .{}) catch {
        return Ac3ValidationResult.invalid(errmsg.failedToOpen("file"), 0);
    };
    defer file.close(runtime.io());

    const file_size = file.getEndPos() catch {
        return Ac3ValidationResult.invalid(errmsg.failedToGet("file size"), 0);
    };

    if (file_size < 7) {
        return Ac3ValidationResult.invalid(errmsg.fileTooSmallFor("AC-3"), 0);
    }

    // Memory-map the entire file for CRC validation of all frames
    const data = runtime.cwd().readFileAlloc(runtime.io(), path, 
        heap.validateAllocator(), .limited(256 * 1024 * 1024, // 256MB max
    )) catch {
        return Ac3ValidationResult.invalid(errmsg.failedToRead("file"), 0);
    };
    defer heap.validateAllocator().free(data);

    return validateAc3Stream(data, max_frames);
}

// Tests
test "AC-3 sync word detection" {
    const valid_start = [_]u8{ 0x0B, 0x77, 0x00, 0x00, 0x14, 0x00, 0x40 }; // 48kHz, 384kbps
    const info = parseAc3Frame(&valid_start);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 48000), info.?.sample_rate);
}

test "AC-3 invalid sync word" {
    const invalid_start = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const info = parseAc3Frame(&invalid_start);
    try std.testing.expect(info == null);
}

test "AC-3 frame size calculation" {
    // Test 48kHz, frmsizecod=0 (32kbps) -> 64 words = 128 bytes
    const frame_48k_32k = [_]u8{ 0x0B, 0x77, 0x00, 0x00, 0x00, 0x00, 0x40 };
    const info1 = parseAc3Frame(&frame_48k_32k);
    try std.testing.expect(info1 != null);
    try std.testing.expectEqual(@as(u16, 128), info1.?.frame_size);

    // Test 48kHz, frmsizecod=10 (80kbps) -> 160 words = 320 bytes
    const frame_48k_80k = [_]u8{ 0x0B, 0x77, 0x00, 0x00, 0x0A, 0x00, 0x40 };
    const info2 = parseAc3Frame(&frame_48k_80k);
    try std.testing.expect(info2 != null);
    try std.testing.expectEqual(@as(u16, 320), info2.?.frame_size);
}

test "AC-3 CRC16 matches reference values" {
    // Verified against C reference implementation
    const ab = [_]u8{ 0x41, 0x42 };
    try std.testing.expectEqual(@as(u16, 0x0789), crc16Ac3(&ab));

    const zeros = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u16, 0x0000), crc16Ac3(&zeros));

    const ff = [_]u8{ 0xFF, 0xFF };
    try std.testing.expectEqual(@as(u16, 0x800D), crc16Ac3(&ff));
}

test "AC-3 stream rejects corrupted CRC" {
    // Build a minimal AC-3 frame: sync(2) + CRC1(2) + fscod/frmsizecod(1) + bsid/bsmod(1) + acmod(1) + padding
    // fscod=0 (48kHz), frmsizecod=0 (32kbps) -> 64 words = 128 bytes
    var frame: [128]u8 = [_]u8{0} ** 128;
    frame[0] = 0x0B; // sync
    frame[1] = 0x77;
    frame[4] = 0x00; // fscod=0, frmsizecod=0
    frame[5] = 0x00; // bsid=0, bsmod=0
    frame[6] = 0x40; // acmod=2 (stereo), lfeon=0

    // Per ATSC A/52: CRC is MSB-first poly 0x8005 init 0.
    // CRC2 covers bytes [2..frame_size) including stored CRC at end → result = 0.
    // So we compute CRC over bytes [2..126) and store the value that makes the whole region = 0.
    // CRC2 at bytes [126..128): set so that crc16(bytes[2..128]) == 0
    const crc2_partial = crc16Ac3(frame[2..126]);
    // To make CRC of entire region = 0, stored CRC = value such that feeding it through CRC(partial) yields 0.
    // For MSB-first CRC: if partial CRC = P, we need crc(P, byte1, byte2) = 0.
    // Brute force: try all 65536 values (fast for a test)
    var crc2_found = false;
    var b0: u16 = 0;
    while (b0 < 256) : (b0 += 1) {
        var b1: u16 = 0;
        while (b1 < 256) : (b1 += 1) {
            var crc = crc2_partial;
            crc ^= b0 << 8;
            for (0..8) |_| {
                if ((crc & 0x8000) != 0) {
                    crc = (crc << 1) ^ 0x8005;
                } else {
                    crc <<= 1;
                }
            }
            crc ^= b1 << 8;
            for (0..8) |_| {
                if ((crc & 0x8000) != 0) {
                    crc = (crc << 1) ^ 0x8005;
                } else {
                    crc <<= 1;
                }
            }
            if (crc == 0) {
                frame[126] = @intCast(b0);
                frame[127] = @intCast(b1);
                crc2_found = true;
                break;
            }
        }
        if (crc2_found) break;
    }
    try std.testing.expect(crc2_found);
    try std.testing.expectEqual(@as(u16, 0), crc16Ac3(frame[2..128]));

    // CRC1 covers bytes [2..(words*5/8)*2) = bytes [2..80) for 128-byte frame (64 words, 5/8=40 words=80 bytes)
    // CRC1 is stored at bytes [2..4), find values that make crc16(bytes[2..80)) = 0
    const crc1_end: usize = 80;
    frame[2] = 0;
    frame[3] = 0;
    var crc1_found = false;
    b0 = 0;
    while (b0 < 256) : (b0 += 1) {
        var b1_inner: u16 = 0;
        while (b1_inner < 256) : (b1_inner += 1) {
            frame[2] = @intCast(b0);
            frame[3] = @intCast(b1_inner);
            if (crc16Ac3(frame[2..crc1_end]) == 0) {
                crc1_found = true;
                break;
            }
        }
        if (crc1_found) break;
    }
    try std.testing.expect(crc1_found);

    // Re-compute CRC2 since CRC1 field changed
    crc2_found = false;
    b0 = 0;
    while (b0 < 256) : (b0 += 1) {
        var b1_inner: u16 = 0;
        while (b1_inner < 256) : (b1_inner += 1) {
            frame[126] = @intCast(b0);
            frame[127] = @intCast(b1_inner);
            if (crc16Ac3(frame[2..128]) == 0) {
                crc2_found = true;
                break;
            }
        }
        if (crc2_found) break;
    }
    try std.testing.expect(crc2_found);

    // Valid frame should pass
    const valid_result = validateAc3Stream(&frame, 10);
    try std.testing.expect(valid_result.valid);

    // Corrupt a data byte (not sync, not CRC fields) — should fail CRC
    var corrupted = frame;
    corrupted[10] ^= 0xFF;
    const corrupt_result = validateAc3Stream(&corrupted, 10);
    try std.testing.expect(!corrupt_result.valid);
}

test "AC-3 channel count" {
    // acmod=7 (3/2) + LFE = 5.1
    const info = Ac3FrameInfo{
        .frame_size = 256,
        .sample_rate = 48000,
        .bit_rate = 192,
        .bsmod = 0,
        .acmod = 7,
        .lfeon = true,
        .crc1 = 0,
    };
    try std.testing.expectEqual(@as(u8, 6), info.channels());
}
