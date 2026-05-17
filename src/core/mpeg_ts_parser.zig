//! MPEG Transport Stream (TS) Parser
//!
//! This module parses MPEG-TS containers commonly used for broadcast TV,
//! streaming, and Blu-ray. TS uses fixed 188-byte packets with PID-based
//! multiplexing to carry multiple video/audio/data streams.
//!
//! Structure:
//! - Sync byte: 0x47
//! - Header: transport_error, payload_unit_start, priority, PID, scrambling,
//!   adaptation_field_control, continuity_counter
//! - Optional adaptation field
//! - Payload (PES packets, PSI tables)

const std = @import("std");
const errmsg = @import("error_messages.zig");
const codec_utils = @import("codec_utils.zig");

/// MPEG-TS packet size
pub const TS_PACKET_SIZE: usize = 188;

/// MPEG-TS sync byte
pub const TS_SYNC_BYTE: u8 = 0x47;

/// Well-known PIDs
pub const PID_PAT: u16 = 0x0000; // Program Association Table
pub const PID_CAT: u16 = 0x0001; // Conditional Access Table
pub const PID_TSDT: u16 = 0x0002; // Transport Stream Description Table
pub const PID_NULL: u16 = 0x1FFF; // Null packet (stuffing)

/// Stream types from PMT
pub const StreamType = enum(u8) {
    reserved = 0x00,
    mpeg1_video = 0x01,
    mpeg2_video = 0x02,
    mpeg1_audio = 0x03,
    mpeg2_audio = 0x04,
    mpeg2_private_sections = 0x05,
    mpeg2_pes_private = 0x06,
    mheg = 0x07,
    mpeg2_dsmcc = 0x08,
    h222_1 = 0x09,
    dsmcc_type_a = 0x0A,
    dsmcc_type_b = 0x0B,
    dsmcc_type_c = 0x0C,
    dsmcc_type_d = 0x0D,
    mpeg2_auxiliary = 0x0E,
    aac_adts = 0x0F,
    mpeg4_visual = 0x10,
    aac_latm = 0x11,
    mpeg4_flexmux_pes = 0x12,
    mpeg4_flexmux_sections = 0x13,
    dsmcc_sdp = 0x14,
    metadata_pes = 0x15,
    metadata_sections = 0x16,
    dsmcc_data_carousel = 0x17,
    dsmcc_object_carousel = 0x18,
    sdp = 0x19,
    ipmp = 0x1A,
    h264 = 0x1B,
    h264_raw = 0x1C,
    h265 = 0x24,
    vvc = 0x33,
    av1 = 0x34,
    ac3 = 0x81,
    dts = 0x82,
    truehd = 0x83,
    eac3 = 0x84,
    dts_hd = 0x85,
    dts_hd_ma = 0x86,
    eac3_secondary = 0x87,
    _,

    pub fn isVideo(self: StreamType) bool {
        return switch (self) {
            .mpeg1_video, .mpeg2_video, .mpeg4_visual, .h264, .h264_raw, .h265, .vvc, .av1 => true,
            else => false,
        };
    }

    pub fn isAudio(self: StreamType) bool {
        return switch (self) {
            .mpeg1_audio, .mpeg2_audio, .aac_adts, .aac_latm, .ac3, .dts, .truehd, .eac3, .dts_hd, .dts_hd_ma, .eac3_secondary => true,
            else => false,
        };
    }

    pub fn name(self: StreamType) []const u8 {
        return switch (self) {
            .mpeg1_video => "MPEG-1 Video",
            .mpeg2_video => "MPEG-2 Video",
            .mpeg1_audio => "MPEG-1 Audio",
            .mpeg2_audio => "MPEG-2 Audio",
            .aac_adts => "AAC ADTS",
            .aac_latm => "AAC LATM",
            .mpeg4_visual => "MPEG-4 Visual",
            .h264 => "H.264/AVC",
            .h264_raw => "H.264 Raw",
            .h265 => "H.265/HEVC",
            .vvc => "H.266/VVC",
            .av1 => "AV1",
            .ac3 => "AC-3",
            .dts => "DTS",
            .truehd => "TrueHD",
            .eac3 => "E-AC-3",
            .dts_hd => "DTS-HD",
            .dts_hd_ma => "DTS-HD MA",
            .eac3_secondary => "E-AC-3 Secondary",
            else => "Unknown",
        };
    }
};

/// Parsed TS packet header
pub const TsPacketHeader = struct {
    sync_byte: u8,
    transport_error: bool,
    payload_unit_start: bool,
    transport_priority: bool,
    pid: u16,
    scrambling_control: u2,
    adaptation_field_control: u2,
    continuity_counter: u4,
};

/// Parse TS packet header from first 4 bytes
pub fn parseTsHeader(data: []const u8) ?TsPacketHeader {
    if (data.len < 4) return null;
    if (data[0] != TS_SYNC_BYTE) return null;

    return .{
        .sync_byte = data[0],
        .transport_error = (data[1] & 0x80) != 0,
        .payload_unit_start = (data[1] & 0x40) != 0,
        .transport_priority = (data[1] & 0x20) != 0,
        .pid = (@as(u16, data[1] & 0x1F) << 8) | @as(u16, data[2]),
        .scrambling_control = @intCast((data[3] >> 6) & 0x03),
        .adaptation_field_control = @intCast((data[3] >> 4) & 0x03),
        .continuity_counter = @intCast(data[3] & 0x0F),
    };
}

/// Adaptation field flags
pub const AdaptationField = struct {
    length: u8,
    discontinuity: bool,
    random_access: bool,
    priority: bool,
    pcr_present: bool,
    opcr_present: bool,
    splicing_point: bool,
    private_data_present: bool,
    extension_present: bool,
    pcr: ?u64, // 33-bit base + 9-bit extension (in 27MHz units)
};

/// Parse adaptation field
pub fn parseAdaptationField(data: []const u8) ?AdaptationField {
    if (data.len < 1) return null;

    const length = data[0];
    if (length == 0) {
        return .{
            .length = 0,
            .discontinuity = false,
            .random_access = false,
            .priority = false,
            .pcr_present = false,
            .opcr_present = false,
            .splicing_point = false,
            .private_data_present = false,
            .extension_present = false,
            .pcr = null,
        };
    }

    if (data.len < length + 1) return null;

    const flags = data[1];
    var field = AdaptationField{
        .length = length,
        .discontinuity = (flags & 0x80) != 0,
        .random_access = (flags & 0x40) != 0,
        .priority = (flags & 0x20) != 0,
        .pcr_present = (flags & 0x10) != 0,
        .opcr_present = (flags & 0x08) != 0,
        .splicing_point = (flags & 0x04) != 0,
        .private_data_present = (flags & 0x02) != 0,
        .extension_present = (flags & 0x01) != 0,
        .pcr = null,
    };

    // Parse PCR if present (6 bytes)
    if (field.pcr_present and length >= 7) {
        // PCR = base (33 bits) + reserved (6 bits) + extension (9 bits)
        const pcr_base = (@as(u64, data[2]) << 25) |
            (@as(u64, data[3]) << 17) |
            (@as(u64, data[4]) << 9) |
            (@as(u64, data[5]) << 1) |
            (@as(u64, data[6]) >> 7);
        const pcr_ext = (@as(u64, data[6] & 0x01) << 8) | @as(u64, data[7]);
        field.pcr = pcr_base * 300 + pcr_ext;
    }

    return field;
}

/// Get payload offset and length from TS packet
pub fn getPayloadInfo(data: []const u8) ?struct { offset: usize, length: usize } {
    if (data.len < TS_PACKET_SIZE) return null;

    const header = parseTsHeader(data) orelse return null;

    var offset: usize = 4; // After header

    // Check adaptation field control
    // 00: reserved, 01: payload only, 10: adaptation only, 11: adaptation + payload
    const afc = header.adaptation_field_control;
    if (afc == 0) return null; // Reserved
    if (afc == 2) return null; // No payload

    if (afc == 3 or afc == 2) {
        // Has adaptation field
        if (offset >= data.len) return null;
        const adaptation_length = data[offset];
        offset += 1 + adaptation_length;
    }

    if (offset >= TS_PACKET_SIZE) return null;

    return .{
        .offset = offset,
        .length = TS_PACKET_SIZE - offset,
    };
}

/// Program Association Table entry
pub const PatEntry = struct {
    program_number: u16,
    pid: u16, // PMT PID for program, or NIT PID if program_number == 0
};

/// PAT parsing result
pub const PatResult = struct {
    entries: [16]PatEntry,
    count: usize,
};

/// Parse Program Association Table
pub fn parsePat(data: []const u8) ?PatResult {
    if (data.len < 8) return null;

    // PSI header
    const table_id = data[0];
    if (table_id != 0x00) return null; // PAT table_id

    const section_syntax = (data[1] & 0x80) != 0;
    if (!section_syntax) return null;

    const section_length = (@as(u16, data[1] & 0x0F) << 8) | @as(u16, data[2]);
    if (section_length < 9) return null;

    // Skip: transport_stream_id (2), version/current (1), section_number (1), last_section (1)
    const header_size: usize = 8;
    const crc_size: usize = 4;

    if (data.len < header_size + crc_size) return null;

    var result: PatResult = .{
        .entries = undefined,
        .count = 0,
    };

    // Parse program entries (4 bytes each)
    var offset: usize = header_size;
    const end = @min(data.len - crc_size, section_length + 3 - crc_size);

    while (offset + 4 <= end and result.count < 16) {
        const program_number = (@as(u16, data[offset]) << 8) | @as(u16, data[offset + 1]);
        const pid = ((@as(u16, data[offset + 2]) & 0x1F) << 8) | @as(u16, data[offset + 3]);

        result.entries[result.count] = .{
            .program_number = program_number,
            .pid = pid,
        };
        result.count += 1;
        offset += 4;
    }

    return result;
}

/// Program stream info from PMT
pub const PmtStreamInfo = struct {
    stream_type: StreamType,
    pid: u16,
};

/// PMT parsing result
pub const PmtResult = struct {
    pcr_pid: u16,
    streams: [16]PmtStreamInfo,
    count: usize,
};

/// Parse Program Map Table
pub fn parsePmt(data: []const u8) ?PmtResult {
    if (data.len < 12) return null;

    // PSI header
    const table_id = data[0];
    if (table_id != 0x02) return null; // PMT table_id

    const section_syntax = (data[1] & 0x80) != 0;
    if (!section_syntax) return null;

    const section_length = (@as(u16, data[1] & 0x0F) << 8) | @as(u16, data[2]);
    if (section_length < 13) return null;

    // program_number (2), version/current (1), section_number (1), last_section (1)
    // PCR_PID (2, with 3 reserved bits), program_info_length (2, with 4 reserved bits)
    const pcr_pid = ((@as(u16, data[8]) & 0x1F) << 8) | @as(u16, data[9]);
    const program_info_length = ((@as(u16, data[10]) & 0x0F) << 8) | @as(u16, data[11]);

    var result: PmtResult = .{
        .pcr_pid = pcr_pid,
        .streams = undefined,
        .count = 0,
    };

    // Skip program descriptors
    var offset: usize = 12 + program_info_length;
    const crc_size: usize = 4;
    const end = @min(data.len - crc_size, section_length + 3 - crc_size);

    // Parse stream entries
    while (offset + 5 <= end and result.count < 16) {
        const stream_type: StreamType = @enumFromInt(data[offset]);
        const elementary_pid = ((@as(u16, data[offset + 1]) & 0x1F) << 8) | @as(u16, data[offset + 2]);
        const es_info_length = ((@as(u16, data[offset + 3]) & 0x0F) << 8) | @as(u16, data[offset + 4]);

        result.streams[result.count] = .{
            .stream_type = stream_type,
            .pid = elementary_pid,
        };
        result.count += 1;

        offset += 5 + es_info_length;
    }

    return result;
}

/// TS file validation result
pub const TsValidationResult = struct {
    valid: bool,
    packets_parsed: u32,
    error_message: ?[]const u8,
    programs_found: u8,
    video_streams: u8,
    audio_streams: u8,
    sync_errors: u32,
    continuity_errors: u32,

    pub fn success(packets: u32, programs: u8, video: u8, audio: u8, sync_err: u32, cont_err: u32) TsValidationResult {
        return .{
            .valid = true,
            .packets_parsed = packets,
            .error_message = null,
            .programs_found = programs,
            .video_streams = video,
            .audio_streams = audio,
            .sync_errors = sync_err,
            .continuity_errors = cont_err,
        };
    }

    pub fn failure(msg: []const u8) TsValidationResult {
        return .{
            .valid = false,
            .packets_parsed = 0,
            .error_message = msg,
            .programs_found = 0,
            .video_streams = 0,
            .audio_streams = 0,
            .sync_errors = 0,
            .continuity_errors = 0,
        };
    }
};

/// Validate MPEG-TS stream
pub fn validateTsStream(data: []const u8, max_packets: u32) TsValidationResult {
    if (data.len < TS_PACKET_SIZE) {
        return TsValidationResult.failure("Data too small for TS packet");
    }

    // Find sync byte alignment
    var offset: usize = 0;
    while (offset < @min(data.len, 188) and data[offset] != TS_SYNC_BYTE) {
        offset += 1;
    }

    if (offset >= @min(data.len, 188)) {
        return TsValidationResult.failure("No sync byte found");
    }

    // Verify sync byte pattern
    if (data.len >= offset + TS_PACKET_SIZE * 2) {
        if (data[offset + TS_PACKET_SIZE] != TS_SYNC_BYTE) {
            return TsValidationResult.failure("Invalid TS sync pattern");
        }
    }

    var packets_parsed: u32 = 0;
    var sync_errors: u32 = 0;
    var continuity_errors: u32 = 0;
    var programs_found: u8 = 0;
    var video_streams: u8 = 0;
    var audio_streams: u8 = 0;

    // Track continuity counters per PID
    var cc_tracker = [_]?u4{null} ** 8192;

    // Track PMT PIDs from PAT
    var pmt_pids = [_]u16{0} ** 16;
    var pmt_count: usize = 0;

    var pos = offset;
    while (pos + TS_PACKET_SIZE <= data.len and packets_parsed < max_packets) {
        const packet = data[pos .. pos + TS_PACKET_SIZE];

        // Check sync byte
        if (packet[0] != TS_SYNC_BYTE) {
            sync_errors += 1;
            pos += 1;
            // Try to resync
            while (pos < data.len and data[pos] != TS_SYNC_BYTE) {
                pos += 1;
            }
            continue;
        }

        const header = parseTsHeader(packet) orelse {
            pos += TS_PACKET_SIZE;
            continue;
        };

        // Check continuity counter
        if (header.pid < 8192 and header.adaptation_field_control != 0 and header.adaptation_field_control != 2) {
            if (cc_tracker[header.pid]) |last_cc| {
                const expected = (last_cc +% 1) & 0x0F;
                if (header.continuity_counter != expected and !header.transport_error) {
                    continuity_errors += 1;
                }
            }
            cc_tracker[header.pid] = header.continuity_counter;
        }

        // Parse PAT to find PMT PIDs
        if (header.pid == PID_PAT and header.payload_unit_start) {
            if (getPayloadInfo(packet)) |payload| {
                // Skip pointer field if present
                const pointer = packet[payload.offset];
                const psi_offset = payload.offset + 1 + pointer;
                if (psi_offset < TS_PACKET_SIZE) {
                    if (parsePat(packet[psi_offset..])) |pat| {
                        for (pat.entries[0..pat.count]) |entry| {
                            if (entry.program_number != 0 and pmt_count < 16) {
                                pmt_pids[pmt_count] = entry.pid;
                                pmt_count += 1;
                            }
                        }
                        programs_found = @intCast(pat.count);
                    }
                }
            }
        }

        // Parse PMT to find stream types
        for (pmt_pids[0..pmt_count]) |pmt_pid| {
            if (header.pid == pmt_pid and header.payload_unit_start) {
                if (getPayloadInfo(packet)) |payload| {
                    const pointer = packet[payload.offset];
                    const psi_offset = payload.offset + 1 + pointer;
                    if (psi_offset < TS_PACKET_SIZE) {
                        if (parsePmt(packet[psi_offset..])) |pmt| {
                            for (pmt.streams[0..pmt.count]) |stream| {
                                if (stream.stream_type.isVideo()) {
                                    video_streams += 1;
                                } else if (stream.stream_type.isAudio()) {
                                    audio_streams += 1;
                                }
                            }
                        }
                    }
                }
            }
        }

        packets_parsed += 1;
        pos += TS_PACKET_SIZE;
    }

    if (packets_parsed == 0) {
        return TsValidationResult.failure(errmsg.noValidXFound("TS packets"));
    }

    return TsValidationResult.success(
        packets_parsed,
        programs_found,
        video_streams,
        audio_streams,
        sync_errors,
        continuity_errors,
    );
}

/// Check if data looks like MPEG-TS
pub fn isMpegTs(data: []const u8) bool {
    if (data.len < TS_PACKET_SIZE * 3) return false;

    // Find first potential sync byte
    var offset: usize = 0;
    while (offset < @min(data.len, 188)) : (offset += 1) {
        if (data[offset] == TS_SYNC_BYTE) {
            // Check if there's a pattern at 188-byte intervals
            var check_offset = offset;
            var pattern_matches: usize = 0;
            while (check_offset + TS_PACKET_SIZE <= data.len and pattern_matches < 5) {
                if (data[check_offset] == TS_SYNC_BYTE) {
                    pattern_matches += 1;
                } else {
                    break;
                }
                check_offset += TS_PACKET_SIZE;
            }
            if (pattern_matches >= 3) {
                return true;
            }
        }
    }

    return false;
}

// ============================================================================
// CRC-32 for MPEG-2 PSI tables (ISO 13818-1)
// ============================================================================

/// Compute CRC-32/MPEG-2 over data. Result should be 0 when computed over
/// the section including the CRC field.
pub const crc32Mpeg2 = codec_utils.Crc32Mpeg2.hash;

/// Validate CRC-32 of a PSI section. The section includes table_id through CRC_32.
/// section_length is the value from bytes 1-2 (12 bits after section_syntax_indicator).
/// Total section size = section_length + 3 (table_id + 2 bytes of section_length field).
pub fn validatePsiCrc(section_data: []const u8) bool {
    if (section_data.len < 4) return false;

    // section_length from bytes 1-2
    const section_length = (@as(usize, section_data[1] & 0x0F) << 8) | @as(usize, section_data[2]);
    const total_len = section_length + 3;

    if (total_len > section_data.len or total_len < 7) return false;

    // CRC-32/MPEG-2 over the entire section should yield 0
    return crc32Mpeg2(section_data[0..total_len]) == 0;
}

// ============================================================================
// Deep Validation: PES assembly + stream dispatch
// ============================================================================

const aac_syntax_validator = @import("aac_syntax_validator.zig");
const ac3_validator = @import("ac3_validator.zig");
const eac3_validator = @import("eac3_validator.zig");
const h264_validator = @import("h264_syntax_validator.zig");
const mpeg12_validator = @import("mpeg12_validator.zig");
const mp3_decode_validator = @import("mp3_decode_validator.zig");
const h265_validator = @import("h265_validator.zig");

/// Result of deep MPEG-TS validation
pub const TsDeepValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    packets_parsed: u32,
    continuity_errors: u32,
    pat_crc_valid: bool,
    pmt_crc_valid: bool,
    video_streams_validated: u8,
    audio_streams_validated: u8,
    video_frames_decoded: u32,
    audio_frames_decoded: u32,

    pub fn success(
        packets: u32,
        cont_err: u32,
        pat_ok: bool,
        pmt_ok: bool,
        v_streams: u8,
        a_streams: u8,
        v_frames: u32,
        a_frames: u32,
    ) TsDeepValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .packets_parsed = packets,
            .continuity_errors = cont_err,
            .pat_crc_valid = pat_ok,
            .pmt_crc_valid = pmt_ok,
            .video_streams_validated = v_streams,
            .audio_streams_validated = a_streams,
            .video_frames_decoded = v_frames,
            .audio_frames_decoded = a_frames,
        };
    }

    pub fn failure(msg: []const u8) TsDeepValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .packets_parsed = 0,
            .continuity_errors = 0,
            .pat_crc_valid = false,
            .pmt_crc_valid = false,
            .video_streams_validated = 0,
            .audio_streams_validated = 0,
            .video_frames_decoded = 0,
            .audio_frames_decoded = 0,
        };
    }
};

/// Per-PID PES assembly buffer
const PesBuffer = struct {
    data: std.ArrayListUnmanaged(u8),
    stream_type: StreamType,
    started: bool,

    fn init(st: StreamType) PesBuffer {
        return .{
            .data = .empty,
            .stream_type = st,
            .started = false,
        };
    }

    fn deinit(self: *PesBuffer, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    fn reset(self: *PesBuffer) void {
        self.data.clearRetainingCapacity();
        self.started = false;
    }

    fn appendPayload(self: *PesBuffer, allocator: std.mem.Allocator, payload: []const u8) !void {
        try self.data.appendSlice(allocator, payload);
    }
};

/// Deep validate an MPEG-TS stream: CRC, continuity, PES assembly, stream decode
pub fn validateTsDeep(allocator: std.mem.Allocator, data: []const u8, max_packets: u32) TsDeepValidationResult {
    if (data.len < TS_PACKET_SIZE) {
        return TsDeepValidationResult.failure("Data too small for TS packet");
    }

    // Find sync alignment
    var start_offset: usize = 0;
    while (start_offset < @min(data.len, 188) and data[start_offset] != TS_SYNC_BYTE) {
        start_offset += 1;
    }
    if (start_offset >= @min(data.len, 188)) {
        return TsDeepValidationResult.failure("No sync byte found");
    }

    var packets_parsed: u32 = 0;
    var continuity_errors: u32 = 0;
    var pat_crc_valid = false;
    var pmt_crc_valid = false;

    // CC tracking
    var cc_tracker = [_]?u4{null} ** 8192;

    // PMT PIDs from PAT
    var pmt_pids = [_]u16{0} ** 16;
    var pmt_count: usize = 0;

    // Stream info from PMT: maps PID -> StreamType
    var pid_stream_type = [_]?StreamType{null} ** 8192;

    // PES assembly buffers (up to 8 elementary streams)
    var pes_buffers: [8]?PesBuffer = [_]?PesBuffer{null} ** 8;
    var pes_pids: [8]u16 = [_]u16{0} ** 8;
    var pes_count: usize = 0;
    defer {
        for (&pes_buffers) |*buf_opt| {
            if (buf_opt.*) |*buf| {
                buf.deinit(allocator);
                buf_opt.* = null;
            }
        }
    }

    var oom_during_assembly = false;

    var pos = start_offset;
    while (pos + TS_PACKET_SIZE <= data.len and packets_parsed < max_packets) {
        const packet = data[pos .. pos + TS_PACKET_SIZE];

        if (packet[0] != TS_SYNC_BYTE) {
            pos += 1;
            while (pos < data.len and data[pos] != TS_SYNC_BYTE) pos += 1;
            continue;
        }

        const header = parseTsHeader(packet) orelse {
            pos += TS_PACKET_SIZE;
            continue;
        };

        // Skip null packets
        if (header.pid == PID_NULL) {
            packets_parsed += 1;
            pos += TS_PACKET_SIZE;
            continue;
        }

        // Continuity counter check (only for packets with payload)
        if (header.pid < 8192 and (header.adaptation_field_control & 0x01) != 0) {
            if (cc_tracker[header.pid]) |last_cc| {
                const expected = (last_cc +% 1) & 0x0F;
                if (header.continuity_counter != expected and !header.transport_error) {
                    // Allow duplicate packets (same CC)
                    if (header.continuity_counter != last_cc) {
                        continuity_errors += 1;
                    }
                }
            }
            cc_tracker[header.pid] = header.continuity_counter;
        }

        // Get payload
        const payload_info = getPayloadInfo(packet) orelse {
            packets_parsed += 1;
            pos += TS_PACKET_SIZE;
            continue;
        };

        const payload = packet[payload_info.offset..][0..payload_info.length];

        // PAT parsing with CRC validation
        if (header.pid == PID_PAT and header.payload_unit_start) {
            if (payload.len > 0) {
                const pointer = payload[0];
                const psi_offset = @as(usize, 1) + pointer;
                if (psi_offset < payload.len) {
                    const psi_data = payload[psi_offset..];
                    if (validatePsiCrc(psi_data)) {
                        pat_crc_valid = true;
                    }
                    if (parsePat(psi_data)) |pat| {
                        for (pat.entries[0..pat.count]) |entry| {
                            if (entry.program_number != 0 and pmt_count < 16) {
                                pmt_pids[pmt_count] = entry.pid;
                                pmt_count += 1;
                            }
                        }
                    }
                }
            }
        }

        // PMT parsing with CRC validation
        for (pmt_pids[0..pmt_count]) |pmt_pid| {
            if (header.pid == pmt_pid and header.payload_unit_start) {
                if (payload.len > 0) {
                    const pointer = payload[0];
                    const psi_offset = @as(usize, 1) + pointer;
                    if (psi_offset < payload.len) {
                        const psi_data = payload[psi_offset..];
                        if (validatePsiCrc(psi_data)) {
                            pmt_crc_valid = true;
                        }
                        if (parsePmt(psi_data)) |pmt| {
                            for (pmt.streams[0..pmt.count]) |stream| {
                                if (stream.pid < 8192) {
                                    pid_stream_type[stream.pid] = stream.stream_type;

                                    // Create PES buffer for this stream if we don't have one
                                    if (pes_count < 8) {
                                        var already_have = false;
                                        for (pes_pids[0..pes_count]) |existing_pid| {
                                            if (existing_pid == stream.pid) {
                                                already_have = true;
                                                break;
                                            }
                                        }
                                        if (!already_have) {
                                            pes_buffers[pes_count] = PesBuffer.init(stream.stream_type);
                                            pes_pids[pes_count] = stream.pid;
                                            pes_count += 1;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // PES assembly for elementary streams
        for (0..pes_count) |i| {
            if (header.pid == pes_pids[i]) {
                if (pes_buffers[i]) |*buf| {
                    if (header.payload_unit_start) {
                        // New PES packet: strip PES header and accumulate ES data
                        buf.started = true;
                        // The payload starts with PES header when PUSI is set
                        const es_data = stripPesHeader(payload);
                        if (es_data) |es| {
                            if (buf.data.items.len + es.len <= 2 * 1024 * 1024) {
                                buf.appendPayload(allocator, es) catch {
                                    oom_during_assembly = true;
                                };
                            }
                        }
                    } else if (buf.started) {
                        // Continuation packet: append raw payload (no PES header)
                        if (buf.data.items.len + payload.len <= 2 * 1024 * 1024) {
                            buf.appendPayload(allocator, payload) catch {
                                oom_during_assembly = true;
                            };
                        }
                    }
                }
            }
        }

        packets_parsed += 1;
        pos += TS_PACKET_SIZE;
    }

    if (packets_parsed == 0) {
        return TsDeepValidationResult.failure(errmsg.noValidXFound("TS packets"));
    }

    if (oom_during_assembly) {
        return TsDeepValidationResult.failure("Out of memory during PES stream assembly");
    }

    // Now validate assembled PES streams
    var video_streams_validated: u8 = 0;
    var audio_streams_validated: u8 = 0;
    var video_frames: u32 = 0;
    var audio_frames: u32 = 0;

    for (0..pes_count) |i| {
        if (pes_buffers[i]) |*buf| {
            const es_data = buf.data.items;
            if (es_data.len == 0) continue;

            switch (buf.stream_type) {
                // Video streams
                .mpeg2_video => {
                    const result = mpeg12_validator.validateMpeg12Stream(es_data, 100);
                    if (result.valid) {
                        video_streams_validated += 1;
                        video_frames += result.pictures;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "MPEG-2 video validation failed");
                    }
                },
                .h264 => {
                    const result = h264_validator.validateH264Stream(es_data, 100);
                    if (result.valid) {
                        video_streams_validated += 1;
                        video_frames += result.frames_decoded;
                    } else {
                        const msg: []const u8 = if (result.error_message) |e| std.mem.span(e) else "H.264 validation failed";
                        return TsDeepValidationResult.failure(msg);
                    }
                },
                .h265 => {
                    const result = h265_validator.validateH265Stream(es_data, 100);
                    if (result.valid) {
                        video_streams_validated += 1;
                        video_frames += result.frames_decoded;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "H.265/HEVC validation failed");
                    }
                },
                // Audio streams
                .aac_adts => {
                    const result = aac_syntax_validator.validateAdtsStream(es_data);
                    if (result.valid) {
                        audio_streams_validated += 1;
                        audio_frames += result.frames_checked;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "AAC ADTS validation failed");
                    }
                },
                .aac_latm => {
                    const result = aac_syntax_validator.validateLatmStream(es_data);
                    if (result.valid) {
                        audio_streams_validated += 1;
                        audio_frames += result.frames_checked;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "AAC LATM validation failed");
                    }
                },
                .ac3 => {
                    const result = ac3_validator.validateAc3Stream(es_data, 100);
                    if (result.valid) {
                        audio_streams_validated += 1;
                        audio_frames += result.frames_validated;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "AC-3 validation failed");
                    }
                },
                .eac3, .eac3_secondary => {
                    const result = eac3_validator.validateEac3Stream(es_data, 100);
                    if (result.valid) {
                        audio_streams_validated += 1;
                        audio_frames += result.frames_validated;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "E-AC-3 validation failed");
                    }
                },
                .mpeg1_audio, .mpeg2_audio => {
                    const result = mp3_decode_validator.validateMp3DecodeBuffer(es_data);
                    if (result.valid) {
                        audio_streams_validated += 1;
                        audio_frames += result.frames_decoded;
                    } else {
                        return TsDeepValidationResult.failure(result.error_message orelse "MPEG audio validation failed");
                    }
                },
                else => {
                    // Unsupported stream type — count as validated if we have data
                    if (buf.stream_type.isVideo()) {
                        video_streams_validated += 1;
                    } else if (buf.stream_type.isAudio()) {
                        audio_streams_validated += 1;
                    }
                },
            }
        }
    }

    // If we have continuity errors, report as invalid
    if (continuity_errors > 0) {
        return TsDeepValidationResult.failure("Continuity counter errors detected");
    }

    return TsDeepValidationResult.success(
        packets_parsed,
        continuity_errors,
        pat_crc_valid,
        pmt_crc_valid,
        video_streams_validated,
        audio_streams_validated,
        video_frames,
        audio_frames,
    );
}

/// Strip PES header from assembled PES data, returning the elementary stream payload.
/// PES format: 00 00 01 stream_id PES_length(2) [optional header(variable)] payload
fn stripPesHeader(pes_data: []const u8) ?[]const u8 {
    if (pes_data.len < 9) return null;

    // Check PES start code: 00 00 01
    if (pes_data[0] != 0x00 or pes_data[1] != 0x00 or pes_data[2] != 0x01) return null;

    // stream_id at byte 3 (0xE0-0xEF = video, 0xC0-0xDF = audio, 0xBD = private)
    const stream_id = pes_data[3];

    // For audio/video streams, there's a PES header extension
    if ((stream_id >= 0xC0 and stream_id <= 0xEF) or stream_id == 0xBD) {
        // PES_header_data_length at byte 8
        if (pes_data.len < 9) return null;
        const header_data_len = pes_data[8];
        const es_start = @as(usize, 9) + header_data_len;
        if (es_start >= pes_data.len) return null;
        return pes_data[es_start..];
    }

    // For other stream types, payload starts at byte 6
    return if (pes_data.len > 6) pes_data[6..] else null;
}

// Tests
test "TS packet header parsing" {
    // Construct a TS packet header
    // Sync: 0x47
    // TEI=0, PUSI=1, Priority=0, PID=0x100 (256)
    // Scrambling=0, AFC=1 (payload only), CC=5
    const header_bytes = [_]u8{
        0x47, // Sync
        0x41, // 0100 0001 = TEI=0, PUSI=1, Priority=0, PID high=1
        0x00, // PID low = 0 -> PID = 0x100
        0x15, // 0001 0101 = Scrambling=0, AFC=1, CC=5
    };

    const header = parseTsHeader(&header_bytes);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(TS_SYNC_BYTE, header.?.sync_byte);
    try std.testing.expect(!header.?.transport_error);
    try std.testing.expect(header.?.payload_unit_start);
    try std.testing.expect(!header.?.transport_priority);
    try std.testing.expectEqual(@as(u16, 0x100), header.?.pid);
    try std.testing.expectEqual(@as(u2, 0), header.?.scrambling_control);
    try std.testing.expectEqual(@as(u2, 1), header.?.adaptation_field_control);
    try std.testing.expectEqual(@as(u4, 5), header.?.continuity_counter);
}

test "TS packet header - PAT PID" {
    const pat_header = [_]u8{ 0x47, 0x40, 0x00, 0x10 };
    const header = parseTsHeader(&pat_header);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(PID_PAT, header.?.pid);
}

test "TS packet header - null packet" {
    const null_header = [_]u8{ 0x47, 0x1F, 0xFF, 0x10 };
    const header = parseTsHeader(&null_header);
    try std.testing.expect(header != null);
    try std.testing.expectEqual(PID_NULL, header.?.pid);
}

test "TS validation rejects too small data" {
    const tiny = [_]u8{ 0x47, 0x00, 0x00 };
    const result = validateTsStream(&tiny, 100);
    try std.testing.expect(!result.valid);
}

test "TS validation rejects non-TS data" {
    var garbage: [200]u8 = undefined;
    for (&garbage) |*b| {
        b.* = 0xAB;
    }
    const result = validateTsStream(&garbage, 100);
    try std.testing.expect(!result.valid);
}

test "Stream type classification" {
    try std.testing.expect(StreamType.h264.isVideo());
    try std.testing.expect(StreamType.mpeg2_video.isVideo());
    try std.testing.expect(!StreamType.ac3.isVideo());

    try std.testing.expect(StreamType.ac3.isAudio());
    try std.testing.expect(StreamType.aac_adts.isAudio());
    try std.testing.expect(!StreamType.h264.isAudio());
}

test "isMpegTs detection" {
    // Create fake TS data with sync bytes at 188-byte intervals
    var ts_data: [188 * 4]u8 = undefined;
    @memset(&ts_data, 0xFF);
    ts_data[0] = 0x47;
    ts_data[188] = 0x47;
    ts_data[376] = 0x47;
    ts_data[564] = 0x47;

    try std.testing.expect(isMpegTs(&ts_data));

    // Non-TS data
    var non_ts: [188 * 4]u8 = undefined;
    @memset(&non_ts, 0xAB);
    try std.testing.expect(!isMpegTs(&non_ts));
}

test "MPEG-TS ground truth - real sample validation" {
    // First two TS packets from ground_truth_examples/mpeg_ts/sample.ts
    // Generated with: ffmpeg -f lavfi -i "color=c=yellow:s=160x120:d=0.2" -c:v mpeg2video -f mpegts
    // Note: isMpegTs requires 3 sync bytes, so we test validation directly
    const ts_sample = [_]u8{
        // First packet (188 bytes) - SDT packet
        0x47, 0x40, 0x11, 0x10, 0x00, 0x42, 0xf0, 0x25, 0x00, 0x01, 0xc1, 0x00,
        0x00, 0xff, 0x01, 0xff, 0x00, 0x01, 0xfc, 0x80, 0x14, 0x48, 0x12, 0x01,
        0x06, 0x46, 0x46, 0x6d, 0x70, 0x65, 0x67, 0x09, 0x53, 0x65, 0x72, 0x76,
        0x69, 0x63, 0x65, 0x30, 0x31, 0x77, 0x7c, 0x43, 0xca, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        // Second packet (188 bytes) - PAT
        0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00,
        0x00, 0x00, 0x01, 0xf0, 0x00, 0x2a, 0xb1, 0x04, 0xb2, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        // Third packet (188 bytes) - PMT
        0x47, 0x50, 0x00, 0x10, 0x00, 0x02, 0xb0, 0x12, 0x00, 0x01, 0xc1, 0x00,
        0x00, 0xe1, 0x00, 0xf0, 0x00, 0x02, 0xe1, 0x00, 0xf0, 0x00, 0x9e, 0x8b,
        0x23, 0xd1, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };

    // Verify it's detected as MPEG-TS (now with 3 packets)
    try std.testing.expect(isMpegTs(&ts_sample));

    // Validate the stream
    const result = validateTsStream(&ts_sample, 10);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 3), result.packets_parsed);
    try std.testing.expectEqual(@as(u32, 0), result.sync_errors);
}
