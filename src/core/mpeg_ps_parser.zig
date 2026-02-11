//! MPEG Program Stream (PS) Parser
//!
//! This module parses MPEG-PS containers commonly used for DVDs, VOB files,
//! and file-based media. PS uses variable-length packets with start codes
//! and is simpler than Transport Stream but less resilient to errors.
//!
//! Structure:
//! - Start codes: 0x000001xx
//! - Pack header: system clock reference, mux rate
//! - System header: stream bounds, buffer sizes
//! - PES packets: audio/video elementary streams

const std = @import("std");
const errmsg = @import("error_messages.zig");

/// MPEG start code prefix
pub const START_CODE_PREFIX: [3]u8 = .{ 0x00, 0x00, 0x01 };

/// Well-known start codes
pub const StartCode = enum(u8) {
    picture_start = 0x00,
    slice_start_min = 0x01,
    slice_start_max = 0xAF,
    reserved_b0 = 0xB0,
    reserved_b1 = 0xB1,
    user_data = 0xB2,
    sequence_header = 0xB3,
    sequence_error = 0xB4,
    extension_start = 0xB5,
    reserved_b6 = 0xB6,
    sequence_end = 0xB7,
    group_start = 0xB8, // GOP
    program_end = 0xB9,
    pack_start = 0xBA,
    system_header = 0xBB,
    program_stream_map = 0xBC,
    private_stream_1 = 0xBD,
    padding_stream = 0xBE,
    private_stream_2 = 0xBF,
    audio_stream_base = 0xC0, // 0xC0-0xDF = audio streams
    video_stream_base = 0xE0, // 0xE0-0xEF = video streams
    ecm_stream = 0xF0,
    emm_stream = 0xF1,
    dsmcc_stream = 0xF2,
    iso_13522_stream = 0xF3,
    h222_type_a = 0xF4,
    h222_type_b = 0xF5,
    h222_type_c = 0xF6,
    h222_type_d = 0xF7,
    h222_type_e = 0xF8,
    ancillary_stream = 0xF9,
    sl_packetized_stream = 0xFA,
    flexmux_stream = 0xFB,
    reserved_fc = 0xFC,
    reserved_fd = 0xFD,
    reserved_fe = 0xFE,
    program_stream_directory = 0xFF,
    _,

    pub fn isVideoStream(code: u8) bool {
        return code >= 0xE0 and code <= 0xEF;
    }

    pub fn isAudioStream(code: u8) bool {
        return code >= 0xC0 and code <= 0xDF;
    }

    pub fn isPesStream(code: u8) bool {
        return code >= 0xBC;
    }
};

/// Pack header info
pub const PackHeader = struct {
    is_mpeg2: bool,
    scr: u64, // System Clock Reference (90kHz)
    scr_ext: u16, // Extension (27MHz, MPEG-2 only)
    mux_rate: u32, // In units of 50 bytes/second
    stuffing_length: u8, // MPEG-2 only
};

/// Parse pack header (after start code 0x000001BA)
pub fn parsePackHeader(data: []const u8) ?PackHeader {
    if (data.len < 8) return null;

    // Check MPEG version (bits 7-6 of first byte after start code)
    const first_byte = data[0];

    if ((first_byte & 0xC0) == 0x40) {
        // MPEG-2 pack header (14 bytes minimum)
        if (data.len < 10) return null;

        // SCR base: 3 bits + 15 bits + 15 bits = 33 bits
        // SCR extension: 9 bits
        const scr_base = (@as(u64, (data[0] >> 3) & 0x07) << 30) |
            (@as(u64, data[0] & 0x03) << 28) |
            (@as(u64, data[1]) << 20) |
            (@as(u64, (data[2] >> 3) & 0x1F) << 15) |
            (@as(u64, data[2] & 0x03) << 13) |
            (@as(u64, data[3]) << 5) |
            (@as(u64, data[4] >> 3) & 0x1F);

        const scr_ext = (@as(u16, data[4] & 0x03) << 7) | (@as(u16, data[5] >> 1) & 0x7F);

        // Mux rate: 22 bits
        const mux_rate = (@as(u32, data[6]) << 14) |
            (@as(u32, data[7]) << 6) |
            (@as(u32, data[8] >> 2) & 0x3F);

        const stuffing = data[9] & 0x07;

        return .{
            .is_mpeg2 = true,
            .scr = scr_base,
            .scr_ext = scr_ext,
            .mux_rate = mux_rate,
            .stuffing_length = stuffing,
        };
    } else if ((first_byte & 0xF0) == 0x20) {
        // MPEG-1 pack header (8 bytes)
        // SCR: 33 bits spread across bytes
        const scr = (@as(u64, (data[0] >> 1) & 0x07) << 30) |
            (@as(u64, data[1]) << 22) |
            (@as(u64, (data[2] >> 1) & 0x7F) << 15) |
            (@as(u64, data[3]) << 7) |
            (@as(u64, data[4] >> 1) & 0x7F);

        // Mux rate: 22 bits
        const mux_rate = (@as(u32, data[5] & 0x7F) << 15) |
            (@as(u32, data[6]) << 7) |
            (@as(u32, data[7] >> 1) & 0x7F);

        return .{
            .is_mpeg2 = false,
            .scr = scr,
            .scr_ext = 0,
            .mux_rate = mux_rate,
            .stuffing_length = 0,
        };
    }

    return null;
}

/// PES packet header
pub const PesHeader = struct {
    stream_id: u8,
    packet_length: u16, // 0 = unbounded (video only)
    // Optional PES header fields (MPEG-2)
    has_optional_header: bool,
    pts: ?u64, // Presentation timestamp (90kHz)
    dts: ?u64, // Decode timestamp (90kHz)
    data_offset: usize, // Offset to payload data
};

/// Parse PES packet header
pub fn parsePesHeader(data: []const u8) ?PesHeader {
    if (data.len < 6) return null;

    // Verify start code prefix
    if (data[0] != 0x00 or data[1] != 0x00 or data[2] != 0x01) {
        return null;
    }

    const stream_id = data[3];
    const packet_length = (@as(u16, data[4]) << 8) | @as(u16, data[5]);

    // Check if this stream type has optional PES header
    const has_optional = stream_id != @intFromEnum(StartCode.program_stream_map) and
        stream_id != @intFromEnum(StartCode.padding_stream) and
        stream_id != @intFromEnum(StartCode.private_stream_2) and
        stream_id != @intFromEnum(StartCode.ecm_stream) and
        stream_id != @intFromEnum(StartCode.emm_stream) and
        stream_id != @intFromEnum(StartCode.program_stream_directory) and
        stream_id != @intFromEnum(StartCode.dsmcc_stream) and
        stream_id != @intFromEnum(StartCode.h222_type_e);

    if (!has_optional or data.len < 9) {
        return .{
            .stream_id = stream_id,
            .packet_length = packet_length,
            .has_optional_header = false,
            .pts = null,
            .dts = null,
            .data_offset = 6,
        };
    }

    // Parse optional PES header (MPEG-2)
    // Byte 6: '10' + scrambling + priority + alignment + copyright + original
    // Byte 7: PTS_DTS_flags + other flags
    // Byte 8: PES_header_data_length

    const flags1 = data[6];
    const flags2 = data[7];
    const header_data_length = data[8];

    // Check for '10' marker
    if ((flags1 & 0xC0) != 0x80) {
        // Might be MPEG-1 format
        return .{
            .stream_id = stream_id,
            .packet_length = packet_length,
            .has_optional_header = false,
            .pts = null,
            .dts = null,
            .data_offset = 6,
        };
    }

    var header = PesHeader{
        .stream_id = stream_id,
        .packet_length = packet_length,
        .has_optional_header = true,
        .pts = null,
        .dts = null,
        .data_offset = 9 + header_data_length,
    };

    const pts_dts_flags = (flags2 >> 6) & 0x03;

    // Parse PTS (5 bytes)
    if ((pts_dts_flags & 0x02) != 0 and data.len >= 14) {
        const pts = (@as(u64, (data[9] >> 1) & 0x07) << 30) |
            (@as(u64, data[10]) << 22) |
            (@as(u64, (data[11] >> 1) & 0x7F) << 15) |
            (@as(u64, data[12]) << 7) |
            (@as(u64, data[13] >> 1) & 0x7F);
        header.pts = pts;

        // Parse DTS (5 more bytes)
        if ((pts_dts_flags & 0x01) != 0 and data.len >= 19) {
            const dts = (@as(u64, (data[14] >> 1) & 0x07) << 30) |
                (@as(u64, data[15]) << 22) |
                (@as(u64, (data[16] >> 1) & 0x7F) << 15) |
                (@as(u64, data[17]) << 7) |
                (@as(u64, data[18] >> 1) & 0x7F);
            header.dts = dts;
        }
    }

    return header;
}

/// Find next start code in data
pub fn findNextStartCode(data: []const u8, offset: usize) ?struct { offset: usize, code: u8 } {
    if (offset + 4 > data.len) return null;

    var pos = offset;
    while (pos + 4 <= data.len) {
        if (data[pos] == 0x00 and data[pos + 1] == 0x00 and data[pos + 2] == 0x01) {
            return .{ .offset = pos, .code = data[pos + 3] };
        }
        pos += 1;
    }

    return null;
}

/// PS file validation result
pub const PsValidationResult = struct {
    valid: bool,
    packs_parsed: u32,
    error_message: ?[]const u8,
    is_mpeg2: bool,
    video_streams: u8,
    audio_streams: u8,
    private_streams: u8,
    avg_mux_rate: u32,

    pub fn success(packs: u32, mpeg2: bool, video: u8, audio: u8, private: u8, mux_rate: u32) PsValidationResult {
        return .{
            .valid = true,
            .packs_parsed = packs,
            .error_message = null,
            .is_mpeg2 = mpeg2,
            .video_streams = video,
            .audio_streams = audio,
            .private_streams = private,
            .avg_mux_rate = mux_rate,
        };
    }

    pub fn failure(msg: []const u8) PsValidationResult {
        return .{
            .valid = false,
            .packs_parsed = 0,
            .error_message = msg,
            .is_mpeg2 = false,
            .video_streams = 0,
            .audio_streams = 0,
            .private_streams = 0,
            .avg_mux_rate = 0,
        };
    }
};

/// Validate MPEG Program Stream
pub fn validatePsStream(data: []const u8, max_packs: u32) PsValidationResult {
    if (data.len < 14) {
        return PsValidationResult.failure("Data too small for PS pack");
    }

    // Find first pack start code
    const first_pack = findNextStartCode(data, 0);
    if (first_pack == null or first_pack.?.code != @intFromEnum(StartCode.pack_start)) {
        return PsValidationResult.failure("No pack start code found");
    }

    var packs_parsed: u32 = 0;
    var is_mpeg2: bool = false;
    var video_streams: u8 = 0;
    var audio_streams: u8 = 0;
    var private_streams: u8 = 0;
    var total_mux_rate: u64 = 0;

    // Track which streams we've seen
    var video_seen = [_]bool{false} ** 16;
    var audio_seen = [_]bool{false} ** 32;

    var pos: usize = first_pack.?.offset;

    while (pos + 14 <= data.len and packs_parsed < max_packs) {
        const start_code = findNextStartCode(data, pos);
        if (start_code == null) break;

        pos = start_code.?.offset;
        const code = start_code.?.code;

        if (code == @intFromEnum(StartCode.pack_start)) {
            // Parse pack header
            if (pos + 14 <= data.len) {
                if (parsePackHeader(data[pos + 4 ..])) |pack| {
                    if (packs_parsed == 0) {
                        is_mpeg2 = pack.is_mpeg2;
                    }
                    total_mux_rate += pack.mux_rate;
                    packs_parsed += 1;
                }
            }
            pos += 4;
        } else if (code == @intFromEnum(StartCode.program_end)) {
            // End of program stream
            break;
        } else if (StartCode.isPesStream(code)) {
            // PES packet
            if (pos + 6 <= data.len) {
                if (parsePesHeader(data[pos..])) |pes| {
                    if (StartCode.isVideoStream(pes.stream_id)) {
                        const idx = pes.stream_id - 0xE0;
                        if (!video_seen[idx]) {
                            video_seen[idx] = true;
                            video_streams += 1;
                        }
                    } else if (StartCode.isAudioStream(pes.stream_id)) {
                        const idx = pes.stream_id - 0xC0;
                        if (!audio_seen[idx]) {
                            audio_seen[idx] = true;
                            audio_streams += 1;
                        }
                    } else if (pes.stream_id == @intFromEnum(StartCode.private_stream_1)) {
                        private_streams = 1;
                    }

                    // Skip to next start code
                    if (pes.packet_length > 0) {
                        pos += 6 + pes.packet_length;
                    } else {
                        pos += 6;
                    }
                } else {
                    pos += 4;
                }
            } else {
                pos += 4;
            }
        } else {
            // Other start codes (sequence headers, etc.)
            pos += 4;
        }
    }

    if (packs_parsed == 0) {
        return PsValidationResult.failure(errmsg.noValidXFound("pack headers"));
    }

    const avg_mux_rate: u32 = @intCast(total_mux_rate / packs_parsed);

    return PsValidationResult.success(
        packs_parsed,
        is_mpeg2,
        video_streams,
        audio_streams,
        private_streams,
        avg_mux_rate,
    );
}

/// Check if data looks like MPEG Program Stream
pub fn isMpegPs(data: []const u8) bool {
    if (data.len < 14) return false;

    // Look for pack start code 0x000001BA
    const start = findNextStartCode(data, 0);
    if (start == null) return false;

    if (start.?.code != @intFromEnum(StartCode.pack_start)) return false;

    // Verify pack header format
    const pack_offset = start.?.offset + 4;
    if (pack_offset >= data.len) return false;

    const first_byte = data[pack_offset];

    // MPEG-2: 01xxxxxx
    // MPEG-1: 0010xxxx
    return (first_byte & 0xC0) == 0x40 or (first_byte & 0xF0) == 0x20;
}

/// Video elementary stream extraction result
pub const VideoEsResult = struct {
    /// Extracted video elementary stream data (caller owns)
    data: []u8,
    /// Number of PES packets extracted
    pes_packets: u32,
    /// Stream ID of the video (0xE0-0xEF)
    stream_id: u8,
    /// Whether the stream is MPEG-2 (vs MPEG-1)
    is_mpeg2: bool,

    pub fn deinit(self: *VideoEsResult, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) {
            allocator.free(self.data);
        }
        self.* = undefined;
    }
};

/// Extract video elementary stream from MPEG Program Stream
/// Returns video ES data suitable for MPEG-1/2 decoder
/// Caller must call result.deinit(allocator) when done
pub fn extractVideoEs(data: []const u8, allocator: std.mem.Allocator, max_bytes: usize) !?VideoEsResult {
    // Find first video PES packet to determine stream ID
    var video_stream_id: ?u8 = null;
    var is_mpeg2: bool = false;

    // First pass: find video stream ID and count bytes needed
    var total_es_bytes: usize = 0;
    var pes_count: u32 = 0;
    var pos: usize = 0;

    while (findNextStartCode(data, pos)) |sc| {
        pos = sc.offset;

        if (sc.code == @intFromEnum(StartCode.pack_start)) {
            // Check MPEG version from pack header
            if (pos + 8 <= data.len) {
                const first_byte = data[pos + 4];
                is_mpeg2 = (first_byte & 0xC0) == 0x40;
            }
            pos += 4;
        } else if (StartCode.isVideoStream(sc.code)) {
            // Video PES packet
            if (video_stream_id == null) {
                video_stream_id = sc.code;
            }

            if (sc.code == video_stream_id.? and pos + 6 <= data.len) {
                if (parsePesHeader(data[pos..])) |pes| {
                    // Calculate payload size
                    var payload_size: usize = 0;
                    if (pes.packet_length > 0) {
                        const header_bytes = pes.data_offset - 6;
                        if (pes.packet_length > header_bytes) {
                            payload_size = pes.packet_length - header_bytes;
                        }
                    } else {
                        // Unbounded packet - find next start code
                        const next_sc = findNextStartCode(data, pos + pes.data_offset);
                        if (next_sc) |nsc| {
                            if (nsc.offset > pos + pes.data_offset) {
                                payload_size = nsc.offset - (pos + pes.data_offset);
                            }
                        } else {
                            payload_size = data.len - (pos + pes.data_offset);
                        }
                    }

                    total_es_bytes += payload_size;
                    pes_count += 1;

                    // Skip to next
                    if (pes.packet_length > 0) {
                        pos += 6 + pes.packet_length;
                    } else {
                        pos += pes.data_offset + payload_size;
                    }
                } else {
                    pos += 4;
                }
            } else {
                pos += 4;
            }
        } else if (StartCode.isPesStream(sc.code)) {
            // Other PES packet - skip it
            if (pos + 6 <= data.len) {
                if (parsePesHeader(data[pos..])) |pes| {
                    if (pes.packet_length > 0) {
                        pos += 6 + pes.packet_length;
                    } else {
                        pos += 6;
                    }
                } else {
                    pos += 4;
                }
            } else {
                pos += 4;
            }
        } else {
            pos += 4;
        }

        // Limit extraction size
        if (total_es_bytes >= max_bytes) break;
    }

    if (video_stream_id == null or total_es_bytes == 0) {
        return null;
    }

    // Second pass: extract video ES data
    const es_buffer = try allocator.alloc(u8, @min(total_es_bytes, max_bytes));
    errdefer allocator.free(es_buffer);

    var es_offset: usize = 0;
    pos = 0;

    while (findNextStartCode(data, pos)) |sc| {
        pos = sc.offset;

        if (sc.code == video_stream_id.? and pos + 6 <= data.len) {
            if (parsePesHeader(data[pos..])) |pes| {
                // Calculate payload range
                const payload_start = pos + pes.data_offset;
                var payload_end: usize = 0;

                if (pes.packet_length > 0) {
                    payload_end = pos + 6 + pes.packet_length;
                } else {
                    const next_sc = findNextStartCode(data, payload_start);
                    payload_end = if (next_sc) |nsc| nsc.offset else data.len;
                }

                // Ensure we don't overflow
                if (payload_start < payload_end and payload_end <= data.len) {
                    const payload = data[payload_start..payload_end];
                    const copy_len = @min(payload.len, es_buffer.len - es_offset);
                    if (copy_len > 0) {
                        @memcpy(es_buffer[es_offset..][0..copy_len], payload[0..copy_len]);
                        es_offset += copy_len;
                    }
                }

                if (pes.packet_length > 0) {
                    pos += 6 + pes.packet_length;
                } else {
                    pos = payload_end;
                }
            } else {
                pos += 4;
            }
        } else if (sc.code == @intFromEnum(StartCode.pack_start)) {
            pos += 4;
        } else if (StartCode.isPesStream(sc.code)) {
            if (pos + 6 <= data.len) {
                if (parsePesHeader(data[pos..])) |pes| {
                    if (pes.packet_length > 0) {
                        pos += 6 + pes.packet_length;
                    } else {
                        pos += 6;
                    }
                } else {
                    pos += 4;
                }
            } else {
                pos += 4;
            }
        } else {
            pos += 4;
        }

        if (es_offset >= es_buffer.len) break;
    }

    return VideoEsResult{
        .data = es_buffer[0..es_offset],
        .pes_packets = pes_count,
        .stream_id = video_stream_id.?,
        .is_mpeg2 = is_mpeg2,
    };
}

// Tests
test "Start code detection" {
    const data = [_]u8{ 0xFF, 0x00, 0x00, 0x01, 0xBA, 0x00, 0x00, 0x01, 0xE0 };

    const first = findNextStartCode(&data, 0);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(@as(usize, 1), first.?.offset);
    try std.testing.expectEqual(@as(u8, 0xBA), first.?.code);

    const second = findNextStartCode(&data, 5);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(@as(usize, 5), second.?.offset);
    try std.testing.expectEqual(@as(u8, 0xE0), second.?.code);
}

test "Stream type classification" {
    try std.testing.expect(StartCode.isVideoStream(0xE0));
    try std.testing.expect(StartCode.isVideoStream(0xEF));
    try std.testing.expect(!StartCode.isVideoStream(0xC0));
    try std.testing.expect(!StartCode.isVideoStream(0xF0));

    try std.testing.expect(StartCode.isAudioStream(0xC0));
    try std.testing.expect(StartCode.isAudioStream(0xDF));
    try std.testing.expect(!StartCode.isAudioStream(0xE0));
    try std.testing.expect(!StartCode.isAudioStream(0xBF));

    try std.testing.expect(StartCode.isPesStream(0xBC));
    try std.testing.expect(StartCode.isPesStream(0xE0));
    try std.testing.expect(!StartCode.isPesStream(0xB8));
}

test "PS validation rejects too small data" {
    const tiny = [_]u8{ 0x00, 0x00, 0x01, 0xBA };
    const result = validatePsStream(&tiny, 100);
    try std.testing.expect(!result.valid);
}

test "PS validation rejects non-PS data" {
    var garbage: [100]u8 = undefined;
    @memset(&garbage, 0xAB);
    const result = validatePsStream(&garbage, 100);
    try std.testing.expect(!result.valid);
}

test "isMpegPs detection - MPEG-2" {
    // MPEG-2 pack header starts with 0x44 (01xxxxxx)
    const mpeg2_pack = [_]u8{
        0x00, 0x00, 0x01, 0xBA, // Pack start code
        0x44, 0x00, 0x04, 0x00, // MPEG-2 marker + SCR
        0x04, 0x01, 0x01, 0x89, // More SCR + mux rate
        0xC3, 0xF8, // Stuffing
    };

    try std.testing.expect(isMpegPs(&mpeg2_pack));
}

test "isMpegPs detection - MPEG-1" {
    // MPEG-1 pack header starts with 0x21 (0010xxxx)
    const mpeg1_pack = [_]u8{
        0x00, 0x00, 0x01, 0xBA, // Pack start code
        0x21, 0x00, 0x01, 0x00, // MPEG-1 marker + SCR
        0x01, 0x80, 0x01, 0x00, // More SCR + mux rate
        0x00, 0x00,
    };

    try std.testing.expect(isMpegPs(&mpeg1_pack));
}

test "isMpegPs rejects non-PS" {
    const not_ps = [_]u8{ 0x00, 0x00, 0x01, 0xB3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(!isMpegPs(&not_ps)); // Sequence header, not pack
}

test "MPEG-PS ground truth - real sample" {
    // First portion of ground_truth_examples/mpeg_ps/sample.mpg
    // Generated with: ffmpeg -f lavfi -i "color=c=purple:s=160x120:d=0.2" -c:v mpeg2video -f mpeg
    // This is an MPEG-1 PS with video stream 0xE0
    const ps_sample = [_]u8{
        // Pack header (0x000001BA)
        0x00, 0x00, 0x01, 0xBA, 0x21, 0x00, 0x01, 0x00, 0x01, 0xC3, 0x33, 0x67,
        // System header (0x000001BB)
        0x00, 0x00, 0x01, 0xBB, 0x00, 0x09, 0xC3, 0x33, 0x67, 0x00, 0x21, 0xFF,
        0xE0, 0xE0, 0xE6,
        // Video PES (0x000001E0)
        0x00, 0x00, 0x01, 0xE0, 0x02, 0xD1, 0x31, 0x00, 0x03, 0x7B, 0xB1, 0x11,
        0x00, 0x03, 0x5F, 0x91,
        // Sequence header (0x000001B3)
        0x00, 0x00, 0x01, 0xB3, 0x0A, 0x00, 0x78, 0x23, 0xFF, 0xFF, 0xE0, 0x48,
    };

    // Verify it's detected as MPEG-PS
    try std.testing.expect(isMpegPs(&ps_sample));

    // Validate the stream
    const result = validatePsStream(&ps_sample, 10);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.is_mpeg2); // MPEG-1
    try std.testing.expectEqual(@as(u8, 1), result.video_streams);
}

test "extractVideoEs - basic extraction" {
    // Minimal MPEG-PS with video PES packet containing sequence header
    const ps_with_video = [_]u8{
        // Pack header
        0x00, 0x00, 0x01, 0xBA, 0x21, 0x00, 0x01, 0x00, 0x01, 0x80, 0x01, 0x00,
        // Video PES (stream 0xE0, length 0x0010 = 16 bytes)
        0x00, 0x00, 0x01, 0xE0, 0x00, 0x10,
        // PES optional header (MPEG-2 style: 0x80, flags, header_len)
        0x80, 0x00, 0x00,
        // Payload: sequence header start code + data
        0x00, 0x00, 0x01, 0xB3, 0x0A, 0x00, 0x78, 0x23, 0xFF, 0xFF, 0xE0, 0x48, 0x00,
    };

    const allocator = std.testing.allocator;
    var es_result = try extractVideoEs(&ps_with_video, allocator, 1024) orelse {
        try std.testing.expect(false); // Should not be null
        return;
    };
    defer es_result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0xE0), es_result.stream_id);
    try std.testing.expectEqual(@as(u32, 1), es_result.pes_packets);
    // Payload should contain sequence header
    try std.testing.expect(es_result.data.len > 0);
    // First 4 bytes should be sequence header start code
    if (es_result.data.len >= 4) {
        try std.testing.expectEqual(@as(u8, 0x00), es_result.data[0]);
        try std.testing.expectEqual(@as(u8, 0x00), es_result.data[1]);
        try std.testing.expectEqual(@as(u8, 0x01), es_result.data[2]);
        try std.testing.expectEqual(@as(u8, 0xB3), es_result.data[3]);
    }
}

test "extractVideoEs - returns null for non-video stream" {
    // PS with only audio
    const ps_audio_only = [_]u8{
        0x00, 0x00, 0x01, 0xBA, 0x21, 0x00, 0x01, 0x00, 0x01, 0x80, 0x01, 0x00,
        // Audio PES (stream 0xC0)
        0x00, 0x00, 0x01, 0xC0, 0x00, 0x08, 0x80, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    };

    const allocator = std.testing.allocator;
    const result = try extractVideoEs(&ps_audio_only, allocator, 1024);
    try std.testing.expect(result == null);
}
