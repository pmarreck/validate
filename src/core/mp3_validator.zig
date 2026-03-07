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
const errmsg = @import("error_messages.zig");

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

/// Get Layer I bit allocation size in bits.
/// Layer I: 4 bits per subband, 32 subbands.
/// Joint stereo with bound B: B subbands × 2 channels + (32-B) subbands × 1 = (B + 32) × 4 bits.
/// Normal stereo/dual: 32 × 2 × 4 = 256 bits. Mono: 32 × 4 = 128 bits.
fn getLayer1AllocBits(channel_mode: u2, mode_extension: u2) usize {
    const nch: usize = if (channel_mode == 3) 1 else 2; // 3 = mono
    if (channel_mode == 1) { // joint stereo
        // bound = (mode_extension + 1) * 4  (4, 8, 12, 16)
        // But for Layer I, bound can also be 32 (no joint stereo subbands)
        const bound: usize = (@as(usize, mode_extension) + 1) * 4;
        return (bound * 2 + (32 - bound)) * 4;
    }
    return 32 * nch * 4;
}

/// Layer II bit allocation table selection per ISO 11172-3 Table 3-B.2.
/// Returns: number of subbands (sblimit) and bits-per-allocation (nbal) array.
/// The allocation table depends on bitrate_per_channel and sample_rate.
const Layer2AllocTable = struct {
    sblimit: usize,
    /// Number of bits for each subband's allocation entry.
    /// Max 30 subbands for Layer II.
    nbal: [30]u4,
};

/// Select Layer II allocation table based on bitrate per channel (kbps) and sample rate (Hz).
/// Per ISO 11172-3 Table 3-B.2a/b/c/d, the table is selected based on:
/// - bitrate_per_channel and sample_rate for MPEG-1
/// - Always table B.2d for MPEG-2/2.5 (low sample rates)
fn getLayer2AllocTable(bitrate_per_channel: u32, sample_rate: u32, is_v1: bool) Layer2AllocTable {
    if (!is_v1) {
        // MPEG-2/2.5: 30 subbands, all 4-bit allocation
        return .{
            .sblimit = 30,
            .nbal = .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4 },
        };
    }

    // MPEG-1 table selection per ISO 11172-3 Table 3-B.2
    if (sample_rate == 48000) {
        if (bitrate_per_channel >= 96) {
            // Table B.2a: 27 subbands
            return .{
                .sblimit = 27,
                .nbal = .{ 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0 },
            };
        } else {
            // Table B.2b: 30 subbands (all 4-bit)
            return .{
                .sblimit = 30,
                .nbal = .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4 },
            };
        }
    } else if (sample_rate == 44100) {
        if (bitrate_per_channel >= 96) {
            // Table B.2a: 27 subbands
            return .{
                .sblimit = 27,
                .nbal = .{ 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0 },
            };
        } else if (bitrate_per_channel >= 56) {
            // Table B.2b: 30 subbands (all 4-bit)
            return .{
                .sblimit = 30,
                .nbal = .{ 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4 },
            };
        } else {
            // Table B.2c: 8 subbands (2-bit allocation)
            return .{
                .sblimit = 8,
                .nbal = .{ 4, 4, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            };
        }
    } else {
        // 32000 Hz
        if (bitrate_per_channel >= 56) {
            // Table B.2a: 27 subbands
            return .{
                .sblimit = 27,
                .nbal = .{ 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 0, 0 },
            };
        } else {
            // Table B.2d: 12 subbands
            return .{
                .sblimit = 12,
                .nbal = .{ 4, 4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            };
        }
    }
}

/// Get Layer II bit allocation size in bits.
/// Joint stereo: subbands below bound have separate allocations per channel,
/// subbands at/above bound share one allocation.
fn getLayer2AllocBits(table: Layer2AllocTable, channel_mode: u2, mode_extension: u2) usize {
    const nch: usize = if (channel_mode == 3) 1 else 2; // 3 = mono
    var total_bits: usize = 0;

    if (channel_mode == 1) { // joint stereo
        const bound: usize = (@as(usize, mode_extension) + 1) * 4;
        for (0..table.sblimit) |sb| {
            const bits = @as(usize, table.nbal[sb]);
            if (bits == 0) continue;
            if (sb < bound) {
                total_bits += bits * 2; // separate per channel
            } else {
                total_bits += bits; // shared
            }
        }
    } else {
        for (0..table.sblimit) |sb| {
            const bits = @as(usize, table.nbal[sb]);
            total_bits += bits * nch;
        }
    }
    return total_bits;
}

/// Compute CRC-16 over header bytes 2-3 and the bit allocation data
/// for Layer I or Layer II frames. The CRC uses polynomial 0x8005,
/// init 0xFFFF, MSB-first — same as Layer III.
fn computeLayerCrc(header_23: [2]u8, alloc_data: []const u8, alloc_bits: usize) u16 {
    // CRC over header bytes 2-3
    var crc: u16 = 0xFFFF;
    crc = crc16_table[((crc >> 8) ^ header_23[0]) & 0xFF] ^ (crc << 8);
    crc = crc16_table[((crc >> 8) ^ header_23[1]) & 0xFF] ^ (crc << 8);

    // CRC over allocation bits (bit-by-bit for partial byte at end)
    const full_bytes = alloc_bits / 8;
    const remaining_bits = alloc_bits % 8;

    for (alloc_data[0..full_bytes]) |byte| {
        crc = crc16_table[((crc >> 8) ^ byte) & 0xFF] ^ (crc << 8);
    }

    // Handle remaining bits (MSB-first, pad with zeros)
    if (remaining_bits > 0 and full_bytes < alloc_data.len) {
        // Mask out unused low bits and process as full byte
        const mask: u8 = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
        const partial = alloc_data[full_bytes] & mask;
        crc = crc16_table[((crc >> 8) ^ partial) & 0xFF] ^ (crc << 8);
    }

    return crc;
}

/// Validate MP3 file with CRC verification.
/// Returns result with frame and CRC statistics.
pub fn validateMp3Crc(file: std.fs.File) Mp3ValidationResult {
    var frames_checked: u32 = 0;
    var frames_with_crc: u32 = 0;
    var crc_verified: u32 = 0;

    // Seek to beginning
    file.seekTo(0) catch {
        return Mp3ValidationResult.invalid(errmsg.failedToSeek("to start"), 0, 0);
    };

    // Read initial header to check for ID3v2
    var header: [10]u8 = undefined;
    const header_bytes = file.read(&header) catch {
        return Mp3ValidationResult.invalid(errmsg.failedToRead("header"), 0, 0);
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
        return Mp3ValidationResult.invalid(errmsg.failedToSeek("past ID3"), 0, 0);
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

            if (layer == 3) {
                // Layer III: CRC covers header bytes 2-3 + side information
                const side_info_size = getSideInfoSize(is_v1, is_stereo);
                var side_info: [32]u8 = undefined;
                const side_read = file.read(side_info[0..side_info_size]) catch break;
                if (side_read < side_info_size) break;

                var crc_data: [34]u8 = undefined;
                crc_data[0] = frame_header[2];
                crc_data[1] = frame_header[3];
                @memcpy(crc_data[2 .. 2 + side_info_size], side_info[0..side_info_size]);

                const computed_crc = mp3Crc16(crc_data[0 .. 2 + side_info_size]);

                if (computed_crc != stored_crc) {
                    return Mp3ValidationResult.invalid("CRC mismatch", frames_checked, frames_with_crc);
                }
                crc_verified += 1;

                const remaining = frame_size - 4 - 2 - side_info_size;
                file.seekBy(@intCast(remaining)) catch break;
            } else {
                // Layer I/II: CRC covers header bytes 2-3 + bit allocation table
                const chan_mode: u2 = @intCast((frame_header[3] >> 6) & 0x03);
                const mode_ext: u2 = @intCast((frame_header[3] >> 4) & 0x03);

                const alloc_bits = if (layer == 1) blk: {
                    break :blk getLayer1AllocBits(chan_mode, mode_ext);
                } else blk: {
                    const bitrate_per_ch: u32 = if (is_stereo) @as(u32, bitrate) / 2 else @as(u32, bitrate);
                    const alloc_table = getLayer2AllocTable(bitrate_per_ch, sample_rate, is_v1);
                    break :blk getLayer2AllocBits(alloc_table, chan_mode, mode_ext);
                };

                const alloc_bytes = (alloc_bits + 7) / 8;
                if (alloc_bytes > 128) {
                    // Sanity check — allocation table can't exceed this
                    file.seekBy(@intCast(frame_size - 4 - 2)) catch break;
                } else {
                    var alloc_buf: [128]u8 = undefined;
                    const alloc_read = file.read(alloc_buf[0..alloc_bytes]) catch break;
                    if (alloc_read < alloc_bytes) break;

                    const computed_crc = computeLayerCrc(
                        .{ frame_header[2], frame_header[3] },
                        alloc_buf[0..alloc_bytes],
                        alloc_bits,
                    );

                    if (computed_crc != stored_crc) {
                        return Mp3ValidationResult.invalid("CRC mismatch", frames_checked, frames_with_crc);
                    }
                    crc_verified += 1;

                    const remaining = frame_size - 4 - 2 - alloc_bytes;
                    file.seekBy(@intCast(remaining)) catch break;
                }
            }
        } else {
            // No CRC, skip to next frame
            file.seekBy(@intCast(frame_size - 4)) catch break;
        }

        frames_checked += 1;
    }

    if (frames_checked == 0) {
        return Mp3ValidationResult.invalid(errmsg.noValidXFound("frames"), 0, 0);
    }

    return Mp3ValidationResult.ok(frames_checked, frames_with_crc, crc_verified);
}

/// Validate MP3 CRCs from a file path.
pub fn validateMp3CrcPath(path: []const u8) Mp3ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return Mp3ValidationResult.invalid(errmsg.failedToOpen("file"), 0, 0);
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

test "Layer I allocation bits calculation" {
    // Mono: 32 subbands × 4 bits = 128
    try std.testing.expectEqual(@as(usize, 128), getLayer1AllocBits(3, 0));
    // Stereo: 32 × 2 × 4 = 256
    try std.testing.expectEqual(@as(usize, 256), getLayer1AllocBits(0, 0));
    // Joint stereo, bound=4 (mode_ext=0): (4*2 + 28) * 4 = 144
    try std.testing.expectEqual(@as(usize, 144), getLayer1AllocBits(1, 0));
    // Joint stereo, bound=16 (mode_ext=3): (16*2 + 16) * 4 = 192
    try std.testing.expectEqual(@as(usize, 192), getLayer1AllocBits(1, 3));
}

test "Layer II allocation table selection" {
    // MPEG-1, 48kHz, high bitrate → Table B.2a (27 subbands)
    const t1 = getLayer2AllocTable(96, 48000, true);
    try std.testing.expectEqual(@as(usize, 27), t1.sblimit);
    try std.testing.expectEqual(@as(u4, 4), t1.nbal[0]); // first subband
    try std.testing.expectEqual(@as(u4, 2), t1.nbal[12]); // mid subband

    // MPEG-1, 44100Hz, low bitrate → Table B.2c (8 subbands)
    const t2 = getLayer2AllocTable(32, 44100, true);
    try std.testing.expectEqual(@as(usize, 8), t2.sblimit);

    // MPEG-2 → always 30 subbands, all 4-bit
    const t3 = getLayer2AllocTable(64, 24000, false);
    try std.testing.expectEqual(@as(usize, 30), t3.sblimit);
    try std.testing.expectEqual(@as(u4, 4), t3.nbal[29]);
}

test "Layer II allocation bits calculation" {
    const table = getLayer2AllocTable(96, 48000, true); // Table B.2a, 27 subbands

    // Mono: sum of nbal[0..27]
    const mono_bits = getLayer2AllocBits(table, 3, 0);
    // Table B.2a: 3×4 + 8×3 + 15×2 = 12 + 24 + 30? Let me compute...
    // nbal = {4,4,4, 3,3,3,3,3,3,3,3,3, 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2}
    // = 3*4 + 9*3 + 15*2 = 12 + 27 + 30 = 69
    try std.testing.expectEqual(@as(usize, 69), mono_bits);

    // Stereo (non-joint): 69 * 2 = 138
    try std.testing.expectEqual(@as(usize, 138), getLayer2AllocBits(table, 0, 0));
}

test "MP3 Layer I CRC verification with valid frame" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MPEG-1 Layer I, 384kbps, 44100Hz, mono, CRC protected
    // Byte 1: 111_11_11_0 = 0xFE (sync, MPEG-1, Layer I, CRC present)
    // Byte 2: 1100_00_0_0 = 0xC0 (bitrate_idx=12→384k, sr_idx=0→44100, pad=0, priv=0)
    // Byte 3: 11_00_0_0_00 = 0xC0 (channel=3→mono, mode_ext=0, copy=0, orig=0, emph=0)
    // Frame size = (12 * 384000 / 44100 + 0) * 4 = 104 * 4 = 416
    var frame: [416]u8 = undefined;
    frame[0] = 0xFF;
    frame[1] = 0xFE; // MPEG-1, Layer I, CRC protected
    frame[2] = 0xC0; // 384kbps, 44100Hz, no padding
    frame[3] = 0xC0; // mono

    // CRC placeholder at bytes 4-5
    frame[4] = 0;
    frame[5] = 0;

    // Bit allocation: mono = 32 subbands × 4 bits = 128 bits = 16 bytes
    @memset(frame[6..22], 0x55);
    @memset(frame[22..], 0);

    // Compute CRC over header[2..4] + allocation[6..22]
    const computed = computeLayerCrc(.{ frame[2], frame[3] }, frame[6..22], 128);
    frame[4] = @truncate(computed >> 8);
    frame[5] = @truncate(computed);

    const file = tmp_dir.dir.createFile("layer1_crc.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "layer1_crc.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.frames_with_crc >= 1);
    try std.testing.expect(result.crc_verified >= 1);
}

test "MP3 Layer I CRC detects corruption" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var frame: [416]u8 = undefined;
    frame[0] = 0xFF;
    frame[1] = 0xFE; // MPEG-1, Layer I, CRC
    frame[2] = 0xC0; // 384kbps, 44100Hz
    frame[3] = 0xC0; // mono

    @memset(frame[6..22], 0x55);
    @memset(frame[22..], 0);

    const computed = computeLayerCrc(.{ frame[2], frame[3] }, frame[6..22], 128);
    frame[4] = @truncate(computed >> 8);
    frame[5] = @truncate(computed);

    // Corrupt the allocation data AFTER CRC was computed
    frame[10] = 0xAA;

    const file = tmp_dir.dir.createFile("layer1_corrupt.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "layer1_corrupt.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(!result.valid);
}

test "MP3 Layer II CRC verification with valid frame" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MPEG-1 Layer II, 128kbps, 44100Hz, stereo, CRC protected
    // Byte 1: 111_11_10_0 = 0xFC (sync, MPEG-1, Layer II, CRC present)
    // Byte 2: 1001_00_0_0 = 0x90 (bitrate_idx=9→160k, sr_idx=0→44100, pad=0, priv=0)
    // Byte 3: 00_00_0_0_00 = 0x00 (stereo, mode_ext=0, copy=0, orig=0, emph=0)
    // bitrate_per_channel = 160/2 = 80 → Table B.2b (30 subbands, all 4-bit)
    // alloc_bits = 30 * 2 * 4 = 240 bits = 30 bytes
    // Frame size = 144 * 160000 / 44100 = 522 bytes
    var frame: [522]u8 = undefined;
    frame[0] = 0xFF;
    frame[1] = 0xFC; // MPEG-1, Layer II, CRC protected
    frame[2] = 0x90; // 160kbps, 44100Hz
    frame[3] = 0x00; // stereo

    frame[4] = 0;
    frame[5] = 0;

    // Bit allocation: 30 subbands × 2 channels × 4 bits = 240 bits = 30 bytes
    @memset(frame[6..36], 0x33);
    @memset(frame[36..], 0);

    const computed = computeLayerCrc(.{ frame[2], frame[3] }, frame[6..36], 240);
    frame[4] = @truncate(computed >> 8);
    frame[5] = @truncate(computed);

    const file = tmp_dir.dir.createFile("layer2_crc.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "layer2_crc.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.frames_with_crc >= 1);
    try std.testing.expect(result.crc_verified >= 1);
}

test "MP3 Layer II CRC detects corruption" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var frame: [522]u8 = undefined;
    frame[0] = 0xFF;
    frame[1] = 0xFC; // MPEG-1, Layer II, CRC
    frame[2] = 0x90; // 160kbps, 44100Hz
    frame[3] = 0x00; // stereo

    @memset(frame[6..36], 0x33);
    @memset(frame[36..], 0);

    const computed = computeLayerCrc(.{ frame[2], frame[3] }, frame[6..36], 240);
    frame[4] = @truncate(computed >> 8);
    frame[5] = @truncate(computed);

    // Corrupt allocation data
    frame[20] = 0xFF;

    const file = tmp_dir.dir.createFile("layer2_corrupt.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&frame) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "layer2_corrupt.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3CrcPath(path);
    try std.testing.expect(!result.valid);
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
