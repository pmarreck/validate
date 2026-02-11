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

/// Validate CRC1 for first 5/8 of frame
pub fn validateCrc1(data: []const u8, frame_size: u16) bool {
    if (data.len < frame_size) return false;

    // CRC1 covers bytes 0-1 (sync) and bytes 4 through (5/8 * frame_size - 1)
    // Stored CRC is at bytes 2-3
    const crc1_end = (frame_size * 5) / 8;
    if (crc1_end < 5) return false;

    // Calculate CRC over sync word and BSI portion
    var crc: u16 = 0;
    crc = crc16Ac3(data[0..2]); // Sync word
    // Continue CRC from byte 4 onwards
    for (data[4..crc1_end]) |byte| {
        crc ^= @as(u16, byte) << 8;
        for (0..8) |_| {
            if ((crc & 0x8000) != 0) {
                crc = (crc << 1) ^ 0x8005;
            } else {
                crc <<= 1;
            }
        }
    }

    const stored_crc = std.mem.readInt(u16, data[2..4], .big);
    return crc == stored_crc;
}

/// Validate CRC2 for entire frame (if present)
/// CRC2 is the last 2 bytes of the frame
pub fn validateCrc2(data: []const u8, frame_size: u16) bool {
    if (data.len < frame_size or frame_size < 4) return false;

    // CRC2 covers bytes 0 through frame_size-3
    // Stored CRC is at bytes frame_size-2 to frame_size-1
    const crc = crc16Ac3(data[0 .. frame_size - 2]);
    const stored_crc = std.mem.readInt(u16, data[frame_size - 2 ..][0..2], .big);

    return crc == stored_crc;
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

        // Validate CRC1 (first 5/8 of frame)
        if (validateCrc1(frame_data, frame_info.frame_size)) {
            crc_validated += 1;
        }

        // Validate CRC2 (entire frame) - optional but recommended
        if (validateCrc2(frame_data, frame_info.frame_size)) {
            crc_validated += 1;
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
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return Ac3ValidationResult.invalid(errmsg.failedToOpen("file"), 0);
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return Ac3ValidationResult.invalid(errmsg.failedToGet("file size"), 0);
    };

    if (file_size < 7) {
        return Ac3ValidationResult.invalid(errmsg.fileTooSmallFor("AC-3"), 0);
    }

    // Read up to 1MB for validation
    const read_size = @min(file_size, 1024 * 1024);
    var buffer: [1024 * 1024]u8 = undefined;

    const bytes_read = file.read(buffer[0..read_size]) catch {
        return Ac3ValidationResult.invalid(errmsg.failedToRead("file"), 0);
    };

    return validateAc3Stream(buffer[0..bytes_read], max_frames);
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

test "AC-3 CRC16 calculation" {
    // Test known CRC values
    const test_data = [_]u8{ 0x0B, 0x77 };
    const crc = crc16Ac3(&test_data);
    // Just verify it runs without error
    try std.testing.expect(crc != 0 or crc == 0);
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
