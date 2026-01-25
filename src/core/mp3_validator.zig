//! MP3 deep validation with CRC16 verification.
//!
//! MP3 frames can optionally include a CRC-16 checksum that covers:
//! - Frame header bytes 2-3 (after the sync word)
//! - Side information (17 bytes mono, 32 bytes stereo for Layer III)
//!
//! The CRC uses polynomial 0x8005 (standard CRC-16).
//!
//! MP3 Frame Header (4 bytes):
//!   Byte 0: 0xFF (sync)
//!   Byte 1: 111xxxxx (sync + version/layer/protection)
//!   Byte 2: bitrate, sample rate, padding, private
//!   Byte 3: channel mode, mode extension, copyright, original, emphasis
//!
//! If protection bit (byte 1, bit 0) is 0, a 2-byte CRC follows the header.
//!
//! Note: Most MP3 files do NOT have CRC protection. This validator
//! verifies CRCs when present, otherwise validates frame structure.

const std = @import("std");

/// Result of MP3 deep validation
pub const Mp3ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_checked: u32,
    frames_with_crc: u32,
    crc_verified: u32,

    pub fn ok(frames: u32, with_crc: u32, verified: u32) Mp3ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_checked = frames,
            .frames_with_crc = with_crc,
            .crc_verified = verified,
        };
    }

    pub fn invalid(message: []const u8, frames: u32, with_crc: u32) Mp3ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_checked = frames,
            .frames_with_crc = with_crc,
            .crc_verified = 0,
        };
    }
};

/// MP3 CRC-16 lookup table (polynomial 0x8005)
const crc16_table: [256]u16 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u16 = undefined;
    for (0..256) |i| {
        var crc: u16 = @as(u16, @intCast(i)) << 8;
        for (0..8) |_| {
            if (crc & 0x8000 != 0) {
                crc = (crc << 1) ^ 0x8005;
            } else {
                crc = crc << 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

/// Calculate MP3 CRC-16 for a buffer
pub fn mp3Crc16(data: []const u8) u16 {
    var crc: u16 = 0xFFFF;
    for (data) |byte| {
        crc = crc16_table[((crc >> 8) ^ byte) & 0xFF] ^ (crc << 8);
    }
    return crc;
}

/// MP3 bitrate table (kbps)
/// Index: bitrate_index (0-15), Column: based on version/layer
const BITRATE_TABLE = [16][5]u16{
    .{ 0, 0, 0, 0, 0 }, // free
    .{ 32, 32, 32, 32, 8 },
    .{ 64, 48, 40, 48, 16 },
    .{ 96, 56, 48, 56, 24 },
    .{ 128, 64, 56, 64, 32 },
    .{ 160, 80, 64, 80, 40 },
    .{ 192, 96, 80, 96, 48 },
    .{ 224, 112, 96, 112, 56 },
    .{ 256, 128, 112, 128, 64 },
    .{ 288, 160, 128, 144, 80 },
    .{ 320, 192, 160, 160, 96 },
    .{ 352, 224, 192, 176, 112 },
    .{ 384, 256, 224, 192, 128 },
    .{ 416, 320, 256, 224, 144 },
    .{ 448, 384, 320, 256, 160 },
    .{ 0, 0, 0, 0, 0 }, // bad
};

/// Sample rate table (Hz)
const SAMPLE_RATE_TABLE = [3][3]u32{
    .{ 44100, 22050, 11025 }, // index 0
    .{ 48000, 24000, 12000 }, // index 1
    .{ 32000, 16000, 8000 }, // index 2
};

/// Get side info size based on version and channel mode
fn getSideInfoSize(is_v1: bool, is_stereo: bool) usize {
    if (is_v1) {
        return if (is_stereo) 32 else 17;
    } else {
        return if (is_stereo) 17 else 9;
    }
}

/// Validate MP3 file with CRC verification.
/// Returns result with frame and CRC statistics.
pub fn validateMp3Crc(file: std.fs.File) Mp3ValidationResult {
    var frames_checked: u32 = 0;
    var frames_with_crc: u32 = 0;
    var crc_verified: u32 = 0;

    // Seek to beginning
    file.seekTo(0) catch {
        return Mp3ValidationResult.invalid("Failed to seek to start", 0, 0);
    };

    // Read initial header to check for ID3v2
    var header: [10]u8 = undefined;
    const header_bytes = file.read(&header) catch {
        return Mp3ValidationResult.invalid("Failed to read header", 0, 0);
    };
    if (header_bytes < 10) {
        return Mp3ValidationResult.invalid("File too small", 0, 0);
    }

    var audio_start: u64 = 0;

    // Skip ID3v2 tag if present
    if (std.mem.eql(u8, header[0..3], "ID3")) {
        const size = (@as(u32, header[6] & 0x7F) << 21) |
            (@as(u32, header[7] & 0x7F) << 14) |
            (@as(u32, header[8] & 0x7F) << 7) |
            @as(u32, header[9] & 0x7F);
        audio_start = 10 + size;
    }

    file.seekTo(audio_start) catch {
        return Mp3ValidationResult.invalid("Failed to seek past ID3", 0, 0);
    };

    // Validate frames
    const max_frames: u32 = 10000; // Sanity limit

    while (frames_checked < max_frames) {
        var frame_header: [4]u8 = undefined;
        const bytes_read = file.read(&frame_header) catch break;
        if (bytes_read < 4) break;

        // Check frame sync (11 bits: 0xFF followed by 0xE0 or higher)
        if (frame_header[0] != 0xFF or (frame_header[1] & 0xE0) != 0xE0) {
            if (frames_checked == 0) {
                return Mp3ValidationResult.invalid("Invalid frame sync", 0, 0);
            }
            break; // End of audio
        }

        // Parse header
        const version_bits = (frame_header[1] >> 3) & 0x03;
        const layer_bits = (frame_header[1] >> 1) & 0x03;
        const protection_bit = frame_header[1] & 0x01;

        const bitrate_index = (frame_header[2] >> 4) & 0x0F;
        const sample_rate_index = (frame_header[2] >> 2) & 0x03;
        const padding_bit = (frame_header[2] >> 1) & 0x01;

        const channel_mode = (frame_header[3] >> 6) & 0x03;
        const is_stereo = (channel_mode != 3); // 3 = mono

        // Validate version and layer
        if (version_bits == 1 or layer_bits == 0) {
            return Mp3ValidationResult.invalid("Reserved version/layer", frames_checked, frames_with_crc);
        }
        if (bitrate_index == 0 or bitrate_index == 15 or sample_rate_index == 3) {
            if (frames_checked == 0) {
                return Mp3ValidationResult.invalid("Invalid bitrate/sample rate", 0, 0);
            }
            break;
        }

        // Calculate parameters
        const is_v1 = (version_bits == 3);
        const layer = 4 - layer_bits;

        const bitrate_col: usize = if (is_v1) switch (layer) {
            1 => 0,
            2 => 1,
            3 => 2,
            else => 2,
        } else switch (layer) {
            1 => 3,
            else => 4,
        };
        const bitrate = BITRATE_TABLE[bitrate_index][bitrate_col];
        if (bitrate == 0) {
            return Mp3ValidationResult.invalid("Invalid bitrate", frames_checked, frames_with_crc);
        }

        const sample_rate_col: usize = switch (version_bits) {
            3 => 0,
            2 => 1,
            0 => 2,
            else => 0,
        };
        const sample_rate = SAMPLE_RATE_TABLE[sample_rate_index][sample_rate_col];
        if (sample_rate == 0) {
            return Mp3ValidationResult.invalid("Invalid sample rate", frames_checked, frames_with_crc);
        }

        // Calculate frame size
        const frame_size: usize = if (layer == 1) blk: {
            break :blk (12 * @as(usize, bitrate) * 1000 / sample_rate + padding_bit) * 4;
        } else blk: {
            const samples_per_frame: usize = if (layer == 3 and !is_v1) 72 else 144;
            break :blk samples_per_frame * @as(usize, bitrate) * 1000 / sample_rate + padding_bit;
        };

        // Handle CRC if present
        if (protection_bit == 0) {
            frames_with_crc += 1;

            // Read stored CRC (2 bytes, big-endian)
            var crc_bytes: [2]u8 = undefined;
            const crc_read = file.read(&crc_bytes) catch break;
            if (crc_read < 2) break;
            const stored_crc = std.mem.readInt(u16, &crc_bytes, .big);

            // Only Layer III has CRC verification implemented
            if (layer == 3) {
                // Read side info
                const side_info_size = getSideInfoSize(is_v1, is_stereo);
                var side_info: [32]u8 = undefined;
                const side_read = file.read(side_info[0..side_info_size]) catch break;
                if (side_read < side_info_size) break;

                // Calculate CRC over header bytes 2-3 and side info
                var crc_data: [34]u8 = undefined;
                crc_data[0] = frame_header[2];
                crc_data[1] = frame_header[3];
                @memcpy(crc_data[2 .. 2 + side_info_size], side_info[0..side_info_size]);

                const computed_crc = mp3Crc16(crc_data[0 .. 2 + side_info_size]);

                if (computed_crc != stored_crc) {
                    return Mp3ValidationResult.invalid("CRC mismatch", frames_checked, frames_with_crc);
                }
                crc_verified += 1;

                // Seek to next frame
                const remaining = frame_size - 4 - 2 - side_info_size;
                file.seekBy(@intCast(remaining)) catch break;
            } else {
                // Layer I/II - CRC covers different data, skip verification
                file.seekBy(@intCast(frame_size - 4 - 2)) catch break;
            }
        } else {
            // No CRC, skip to next frame
            file.seekBy(@intCast(frame_size - 4)) catch break;
        }

        frames_checked += 1;
    }

    if (frames_checked == 0) {
        return Mp3ValidationResult.invalid("No valid frames found", 0, 0);
    }

    return Mp3ValidationResult.ok(frames_checked, frames_with_crc, crc_verified);
}

/// Validate MP3 CRCs from a file path.
pub fn validateMp3CrcPath(path: []const u8) Mp3ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return Mp3ValidationResult.invalid("Failed to open file", 0, 0);
    };
    defer file.close();
    return validateMp3Crc(file);
}

// ============ Tests ============

test "MP3 CRC16 calculation is deterministic" {
    const data = "test data";
    const crc1 = mp3Crc16(data);
    const crc2 = mp3Crc16(data);
    try std.testing.expectEqual(crc1, crc2);
}

test "MP3 CRC16 of empty data" {
    const result = mp3Crc16("");
    // Initial value is 0xFFFF, no data processed
    try std.testing.expectEqual(@as(u16, 0xFFFF), result);
}

test "MP3 validation rejects empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile("empty.mp3", .{}) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "empty.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(!result.valid);
}

test "MP3 validation rejects garbage data" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile("garbage.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 }) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "garbage.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(!result.valid);
}

test "MP3 validation accepts valid frame without CRC" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid MP3 frame (no CRC, protection bit = 1)
    // MPEG-1 Layer III, 128kbps, 44100Hz, stereo
    var frame: [417]u8 = undefined; // 144 * 128000 / 44100 = 417 bytes

    // Frame header
    frame[0] = 0xFF; // Sync
    frame[1] = 0xFB; // MPEG-1, Layer III, no CRC (protection=1)
    frame[2] = 0x90; // 128kbps, 44100Hz, no padding
    frame[3] = 0x00; // Stereo, no emphasis

    // Fill rest with zeros (side info + main data)
    @memset(frame[4..], 0);

    const file = tmp_dir.dir.createFile("valid_nocrc.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "valid_nocrc.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.frames_checked >= 1);
    try std.testing.expectEqual(@as(u32, 0), result.frames_with_crc);
}

test "MP3 validation accepts valid frame with correct CRC" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a minimal valid MP3 frame WITH CRC
    // MPEG-1 Layer III, 128kbps, 44100Hz, stereo
    // Frame size = 417 bytes
    var frame: [417]u8 = undefined;

    // Frame header (protection bit = 0 means CRC present)
    frame[0] = 0xFF; // Sync
    frame[1] = 0xFA; // MPEG-1, Layer III, CRC protected (protection=0)
    frame[2] = 0x90; // 128kbps, 44100Hz, no padding
    frame[3] = 0x00; // Stereo, no emphasis

    // CRC placeholder (will be calculated)
    frame[4] = 0x00;
    frame[5] = 0x00;

    // Side info (32 bytes for stereo MPEG-1 Layer III)
    @memset(frame[6..38], 0);

    // Main data
    @memset(frame[38..], 0);

    // Calculate CRC over header bytes 2-3 and side info
    var crc_data: [34]u8 = undefined;
    crc_data[0] = frame[2];
    crc_data[1] = frame[3];
    @memcpy(crc_data[2..34], frame[6..38]);

    const crc = mp3Crc16(&crc_data);
    frame[4] = @truncate(crc >> 8);
    frame[5] = @truncate(crc);

    const file = tmp_dir.dir.createFile("valid_crc.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "valid_crc.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.frames_checked >= 1);
    try std.testing.expect(result.frames_with_crc >= 1);
    try std.testing.expect(result.crc_verified >= 1);
}

test "MP3 validation detects corrupted CRC" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var frame: [417]u8 = undefined;

    frame[0] = 0xFF;
    frame[1] = 0xFA; // CRC protected
    frame[2] = 0x90;
    frame[3] = 0x00;

    // Calculate correct CRC
    var crc_data: [34]u8 = undefined;
    crc_data[0] = frame[2];
    crc_data[1] = frame[3];
    @memset(crc_data[2..34], 0);

    const crc = mp3Crc16(&crc_data);
    // Write WRONG CRC
    frame[4] = @truncate((crc >> 8) ^ 0xFF);
    frame[5] = @truncate(crc);

    // Side info
    @memset(frame[6..38], 0);
    // Main data
    @memset(frame[38..], 0);

    const file = tmp_dir.dir.createFile("corrupt_crc.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "corrupt_crc.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(!result.valid);
}
