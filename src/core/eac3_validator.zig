//! E-AC-3 (Enhanced AC-3 / Dolby Digital Plus) deep validation (Pure Zig).
//!
//! E-AC-3 is an extension of AC-3 (Dolby Digital) with higher bit rates,
//! more channels (up to 7.1), and improved coding efficiency.
//!
//! Key differences from AC-3:
//! - bsid (bit stream ID) = 16 (vs ≤10 for AC-3)
//! - Different frame size calculation (frmsiz field)
//! - Support for dependent substreams
//! - Higher bit rates (up to 6.144 Mbps)
//!
//! Reference: ETSI TS 102 366 (Digital Audio Compression)

const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const BitReader = @import("bitstream_reader.zig").BitReader;
const errmsg = @import("error_messages.zig");

/// E-AC-3 sample rate table
const sample_rates = [_]u32{ 48000, 44100, 32000, 0 };

/// E-AC-3 reduced sample rates (fscod2)
const reduced_sample_rates = [_]u32{ 24000, 22050, 16000, 0 };

/// Number of audio blocks per syncframe for numblkscod
const num_blocks_table = [_]u8{ 1, 2, 3, 6 };

/// Result of E-AC-3 validation
pub const Eac3ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_validated: u32,
    crc_validated: u32,
    sample_rate: u32,
    channels: u8,
    substreams: u8,

    pub fn ok(frames: u32, crc_count: u32, rate: u32, ch: u8, subs: u8) Eac3ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_validated = frames,
            .crc_validated = crc_count,
            .sample_rate = rate,
            .channels = ch,
            .substreams = subs,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) Eac3ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_validated = frames,
            .crc_validated = 0,
            .sample_rate = 0,
            .channels = 0,
            .substreams = 0,
        };
    }
};

/// E-AC-3 stream type
pub const StreamType = enum(u2) {
    independent = 0, // Type 0: Independent substream
    dependent = 1, // Type 1: Dependent substream
    independent_reenc = 2, // Type 2: Independent substream (re-encoded)
    reserved = 3,
};

/// E-AC-3 frame header info
pub const Eac3FrameInfo = struct {
    frame_size: u16, // In bytes (includes sync word)
    sample_rate: u32,
    num_blocks: u8, // Audio blocks per frame (1, 2, 3, or 6)
    acmod: u3, // Audio coding mode
    lfeon: bool, // LFE channel on
    strmtyp: StreamType, // Stream type
    substreamid: u3, // Substream ID
    bsid: u5, // Bit stream ID (should be 16 for E-AC-3)

    pub fn channels(self: Eac3FrameInfo) u8 {
        // acmod channel counts: 2, 1, 2, 3, 3, 4, 4, 5
        const ch_counts = [_]u8{ 2, 1, 2, 3, 3, 4, 4, 5 };
        return ch_counts[self.acmod] + @as(u8, if (self.lfeon) 1 else 0);
    }

    pub fn samplesPerFrame(self: Eac3FrameInfo) u32 {
        // Each audio block = 256 samples
        return @as(u32, self.num_blocks) * 256;
    }
};


/// Parse E-AC-3 frame header
pub fn parseEac3Frame(data: []const u8) ?Eac3FrameInfo {
    // Minimum: 2 bytes sync + 4 bytes (29 bits of header fields)
    if (data.len < 6) return null;

    // Check sync word (same as AC-3)
    if (data[0] != 0x0B or data[1] != 0x77) {
        return null;
    }

    var reader = BitReader.init(data[2..]);

    // strmtyp (2 bits)
    const strmtyp_bits = reader.readBits(2) orelse return null;
    const strmtyp: StreamType = @enumFromInt(strmtyp_bits);

    // substreamid (3 bits)
    const substreamid: u3 = @intCast(reader.readBits(3) orelse return null);

    // frmsiz (11 bits) - frame size in 16-bit words minus 1
    const frmsiz = reader.readBits(11) orelse return null;
    const frame_size: u16 = @intCast((frmsiz + 1) * 2);

    if (frame_size < 8 or frame_size > 8192) {
        return null;
    }

    // fscod (2 bits) - sample rate code
    const fscod: u2 = @intCast(reader.readBits(2) orelse return null);

    var sample_rate: u32 = undefined;
    var num_blocks: u8 = undefined;

    if (fscod == 3) {
        // fscod2 (2 bits) - reduced sample rate
        const fscod2: u2 = @intCast(reader.readBits(2) orelse return null);
        if (fscod2 == 3) return null;
        sample_rate = reduced_sample_rates[fscod2];
        num_blocks = 6; // Always 6 blocks for reduced sample rates
    } else {
        sample_rate = sample_rates[fscod];
        // numblkscod (2 bits)
        const numblkscod: u2 = @intCast(reader.readBits(2) orelse return null);
        num_blocks = num_blocks_table[numblkscod];
    }

    // acmod (3 bits)
    const acmod: u3 = @intCast(reader.readBits(3) orelse return null);

    // lfeon (1 bit)
    const lfeon = (reader.readBits(1) orelse return null) == 1;

    // bsid (5 bits) - should be 16 for E-AC-3
    const bsid: u5 = @intCast(reader.readBits(5) orelse return null);
    if (bsid != 16) {
        return null; // Not E-AC-3
    }

    return Eac3FrameInfo{
        .frame_size = frame_size,
        .sample_rate = sample_rate,
        .num_blocks = num_blocks,
        .acmod = acmod,
        .lfeon = lfeon,
        .strmtyp = strmtyp,
        .substreamid = substreamid,
        .bsid = bsid,
    };
}

/// CRC-16 polynomial (same as AC-3)
fn crc16(data: []const u8) u16 {
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

/// Validate CRC for E-AC-3 frame.
/// Per ETSI TS 102 366: CRC-16 MSB-first poly 0x8005 init 0 over bytes [2..frame_size).
/// The CRC stored at the end of the frame is included in the region; result should be 0.
pub fn validateCrc(data: []const u8, frame_size: u16) bool {
    if (data.len < frame_size or frame_size < 4) return false;

    return crc16(data[2..frame_size]) == 0;
}

/// Validate E-AC-3 stream from buffer
pub fn validateEac3Stream(data: []const u8, max_frames: u32) Eac3ValidationResult {
    if (data.len < 8) {
        return Eac3ValidationResult.invalid("Data too short for E-AC-3", 0);
    }

    var offset: usize = 0;
    var frames_validated: u32 = 0;
    var crc_validated: u32 = 0;
    var detected_sample_rate: u32 = 0;
    var detected_channels: u8 = 0;
    var max_substreamid: u8 = 0;

    while (offset + 8 <= data.len and frames_validated < max_frames) {
        const frame_data = data[offset..];

        // Check sync word
        if (frame_data[0] != 0x0B or frame_data[1] != 0x77) {
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
        }

        // Check if it's E-AC-3 (bsid = 16) or AC-3 (bsid ≤ 10)
        // bsid is at byte offset 5, bits 3-7
        if (frame_data.len < 6) break;
        const bsid = (frame_data[5] >> 3) & 0x1F;

        if (bsid == 16) {
            // E-AC-3 frame
            const frame_info = parseEac3Frame(frame_data) orelse {
                offset += 2;
                continue;
            };

            if (offset + frame_info.frame_size > data.len) {
                break;
            }

            // Store first frame's parameters
            if (frames_validated == 0) {
                detected_sample_rate = frame_info.sample_rate;
                detected_channels = frame_info.channels();
            }

            // Track max substream ID
            if (frame_info.substreamid > max_substreamid) {
                max_substreamid = frame_info.substreamid;
            }

            // Validate CRC — reject frame on failure
            if (validateCrc(frame_data, frame_info.frame_size)) {
                crc_validated += 1;
            } else {
                return Eac3ValidationResult.invalid("E-AC-3 frame CRC mismatch (data corruption)", frames_validated);
            }

            frames_validated += 1;
            offset += frame_info.frame_size;
        } else if (bsid <= 10) {
            // This is an AC-3 frame, skip it (or validate separately)
            // Get AC-3 frame size
            const fscod: u2 = @intCast((frame_data[4] >> 6) & 0x03);
            const frmsizecod: u6 = @intCast(frame_data[4] & 0x3F);
            if (fscod < 3 and frmsizecod <= 37) {
                const ac3_sizes = [3][38]u16{
                    .{ 64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320, 384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280 },
                    .{ 69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209, 243, 244, 278, 279, 348, 349, 417, 418, 487, 488, 557, 558, 696, 697, 835, 836, 975, 976, 1114, 1115, 1253, 1254, 1393, 1394 },
                    .{ 96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288, 336, 336, 384, 384, 480, 480, 576, 576, 672, 672, 768, 768, 960, 960, 1152, 1152, 1344, 1344, 1536, 1536, 1728, 1728, 1920, 1920 },
                };
                const frame_size = ac3_sizes[fscod][frmsizecod] * 2;
                offset += frame_size;
            } else {
                offset += 2;
            }
        } else {
            // Unknown bsid
            offset += 2;
        }
    }

    if (frames_validated == 0) {
        return Eac3ValidationResult.invalid(errmsg.noValidXFound("E-AC-3 frames"), 0);
    }

    return Eac3ValidationResult.ok(
        frames_validated,
        crc_validated,
        detected_sample_rate,
        detected_channels,
        max_substreamid + 1,
    );
}

/// Validate E-AC-3 from file
pub fn validateEac3File(path: []const u8, max_frames: u32) Eac3ValidationResult {
    // Read entire file for CRC validation of all frames
    const data = runtime.cwd().readFileAlloc(runtime.io(), path, 
        heap.validateAllocator(), .limited(256 * 1024 * 1024, // 256MB max
    )) catch {
        return Eac3ValidationResult.invalid(errmsg.failedToRead("file"), 0);
    };
    defer heap.validateAllocator().free(data);

    if (data.len < 8) {
        return Eac3ValidationResult.invalid(errmsg.fileTooSmallFor("E-AC-3"), 0);
    }

    return validateEac3Stream(data, max_frames);
}

// Tests
test "E-AC-3 sync word detection" {
    // Minimal E-AC-3 header with bsid=16
    // strmtyp=0, substreamid=0, frmsiz=255 (512 bytes), fscod=0 (48kHz), numblkscod=3 (6 blocks)
    // acmod=7 (3/2), lfeon=1, bsid=16
    const header = [_]u8{
        0x0B, 0x77, // sync
        0x00, 0xFF, // strmtyp(2) + substreamid(3) + frmsiz(11) = 0x00FF
        0x0F, // fscod(2) + numblkscod(2) + acmod(3) + lfeon(1) = 00 11 111 1
        0x80, // bsid(5) + ... = 10000 ...
    };
    const info = parseEac3Frame(&header);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u32, 48000), info.?.sample_rate);
    try std.testing.expectEqual(@as(u5, 16), info.?.bsid);
}

test "E-AC-3 rejects AC-3 frames" {
    // AC-3 frame with bsid=8
    const ac3_header = [_]u8{
        0x0B, 0x77, // sync
        0x00, 0x00, // CRC
        0x00, // fscod + frmsizecod
        0x40, // bsid=8 (0100 0...)
        0x00,
        0x00,
    };
    const info = parseEac3Frame(&ac3_header);
    try std.testing.expect(info == null);
}

test "E-AC-3 frame size calculation" {
    // frmsiz = 0x0FF (255), frame_size = (255+1)*2 = 512 bytes
    const header = [_]u8{
        0x0B, 0x77,
        0x00, 0xFF, // frmsiz = 255
        0x0F,
        0x80, // bsid = 16
    };
    const info = parseEac3Frame(&header);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(u16, 512), info.?.frame_size);
}

test "E-AC-3 channel count" {
    const info = Eac3FrameInfo{
        .frame_size = 512,
        .sample_rate = 48000,
        .num_blocks = 6,
        .acmod = 7, // 3/2 (5 channels)
        .lfeon = true, // +1 LFE
        .strmtyp = .independent,
        .substreamid = 0,
        .bsid = 16,
    };
    try std.testing.expectEqual(@as(u8, 6), info.channels()); // 5.1
}

test "E-AC-3 samples per frame" {
    const info = Eac3FrameInfo{
        .frame_size = 512,
        .sample_rate = 48000,
        .num_blocks = 6,
        .acmod = 7,
        .lfeon = true,
        .strmtyp = .independent,
        .substreamid = 0,
        .bsid = 16,
    };
    try std.testing.expectEqual(@as(u32, 1536), info.samplesPerFrame()); // 6 * 256
}
