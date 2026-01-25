//! Vorbis audio deep validation using libvorbis.
//!
//! Vorbis is a lossy audio codec commonly used in OGG containers.
//! This module provides deep (decode-level) validation to detect
//! corruption that structural validation cannot catch.
//!
//! Validation approach:
//! 1. Parse OGG container to extract Vorbis packets
//! 2. Initialize libvorbis decoder with stream parameters
//! 3. Decode each packet and check for decoder errors
//!
//! Note: OGG page CRC32 verification (in ogg_validator.zig) provides 100%
//! coverage of container bytes. This module adds codec-level validation
//! for the Vorbis bitstream itself.

const std = @import("std");
const ogg_validator = @import("ogg_validator.zig");

// Import libvorbis via C interop
const vorbis = @cImport({
    @cInclude("vorbis/codec.h");
    @cInclude("vorbis/vorbisfile.h");
});

/// Result of Vorbis deep validation
pub const VorbisValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    packets_decoded: u32,
    samples_decoded: u64,

    pub fn ok(packets: u32, samples: u64) VorbisValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .packets_decoded = packets,
            .samples_decoded = samples,
        };
    }

    pub fn invalid(message: []const u8, packets: u32) VorbisValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .packets_decoded = packets,
            .samples_decoded = 0,
        };
    }
};

/// Vorbis decoder state
pub const VorbisDecoder = struct {
    vi: vorbis.vorbis_info,
    vc: vorbis.vorbis_comment,
    vd: vorbis.vorbis_dsp_state,
    vb: vorbis.vorbis_block,
    initialized: bool,

    pub fn init() VorbisDecoder {
        var decoder: VorbisDecoder = undefined;
        vorbis.vorbis_info_init(&decoder.vi);
        vorbis.vorbis_comment_init(&decoder.vc);
        decoder.initialized = false;
        return decoder;
    }

    pub fn deinit(self: *VorbisDecoder) void {
        if (self.initialized) {
            _ = vorbis.vorbis_block_clear(&self.vb);
            vorbis.vorbis_dsp_clear(&self.vd);
        }
        vorbis.vorbis_comment_clear(&self.vc);
        vorbis.vorbis_info_clear(&self.vi);
    }

    /// Submit a header packet (info, comment, or codebook)
    /// packet_no: 0 for identification, 1 for comment, 2 for setup
    pub fn submitHeader(self: *VorbisDecoder, packet: []const u8, packet_no: u8) !void {
        var op: vorbis.ogg_packet = undefined;
        op.packet = @constCast(packet.ptr);
        op.bytes = @intCast(packet.len);
        // b_o_s must be 1 for the first (identification) header packet
        op.b_o_s = if (packet_no == 0) 1 else 0;
        op.e_o_s = 0;
        op.granulepos = -1;
        op.packetno = packet_no;

        const result = vorbis.vorbis_synthesis_headerin(&self.vi, &self.vc, &op);
        if (result < 0) {
            return error.VorbisHeaderError;
        }
    }

    /// Initialize synthesis after headers are submitted
    pub fn initSynthesis(self: *VorbisDecoder) !void {
        if (vorbis.vorbis_synthesis_init(&self.vd, &self.vi) != 0) {
            return error.VorbisSynthesisInitError;
        }
        if (vorbis.vorbis_block_init(&self.vd, &self.vb) != 0) {
            return error.VorbisBlockInitError;
        }
        self.initialized = true;
    }

    /// Decode an audio packet
    pub fn decodePacket(self: *VorbisDecoder, packet: []const u8) !i32 {
        if (!self.initialized) {
            return error.VorbisNotInitialized;
        }

        var op: vorbis.ogg_packet = undefined;
        op.packet = @constCast(packet.ptr);
        op.bytes = @intCast(packet.len);
        op.b_o_s = 0;
        op.e_o_s = 0;
        op.granulepos = -1;
        op.packetno = 0;

        if (vorbis.vorbis_synthesis(&self.vb, &op) != 0) {
            return error.VorbisSynthesisError;
        }

        if (vorbis.vorbis_synthesis_blockin(&self.vd, &self.vb) != 0) {
            return error.VorbisBlockInError;
        }

        // Get PCM output
        var pcm: [*c][*c]f32 = undefined;
        const samples = vorbis.vorbis_synthesis_pcmout(&self.vd, &pcm);
        if (samples > 0) {
            _ = vorbis.vorbis_synthesis_read(&self.vd, samples);
        }

        return samples;
    }
};

/// Validate OGG Vorbis file using libvorbis decode.
/// This validates both container (via OGG CRCs) and codec (via decode).
pub fn validateOggVorbis(file: std.fs.File) VorbisValidationResult {
    return validateOggVorbisAlloc(std.heap.page_allocator, file);
}

/// Validate OGG Vorbis file with custom allocator.
pub fn validateOggVorbisAlloc(allocator: std.mem.Allocator, file: std.fs.File) VorbisValidationResult {
    // Extract packets from OGG container
    var packet_result = ogg_validator.extractPackets(allocator, file) catch |err| {
        return VorbisValidationResult.invalid(switch (err) {
            error.TruncatedPageHeader => "Truncated OGG page header",
            error.InvalidOggSignature => "Invalid OGG signature",
            error.UnsupportedOggVersion => "Unsupported OGG version",
            error.TruncatedSegmentTable => "Truncated OGG segment table",
            error.TruncatedPageData => "Truncated OGG page data",
            else => "Failed to extract OGG packets",
        }, 0);
    };
    defer packet_result.deinit(allocator);

    const packets = packet_result.packets;

    // Need at least 3 header packets + 1 audio packet
    if (packets.len < 4) {
        return VorbisValidationResult.invalid("Insufficient Vorbis packets (need at least 4)", 0);
    }

    // Verify Vorbis identification header (packet 0)
    // Must start with 0x01 followed by "vorbis"
    if (packets[0].data.len < 7 or
        packets[0].data[0] != 0x01 or
        !std.mem.eql(u8, packets[0].data[1..7], "vorbis"))
    {
        return VorbisValidationResult.invalid("Invalid Vorbis identification header", 0);
    }

    // Verify comment header (packet 1)
    // Must start with 0x03 followed by "vorbis"
    if (packets[1].data.len < 7 or
        packets[1].data[0] != 0x03 or
        !std.mem.eql(u8, packets[1].data[1..7], "vorbis"))
    {
        return VorbisValidationResult.invalid("Invalid Vorbis comment header", 0);
    }

    // Verify setup header (packet 2)
    // Must start with 0x05 followed by "vorbis"
    if (packets[2].data.len < 7 or
        packets[2].data[0] != 0x05 or
        !std.mem.eql(u8, packets[2].data[1..7], "vorbis"))
    {
        return VorbisValidationResult.invalid("Invalid Vorbis setup header", 0);
    }

    // Initialize decoder and submit headers
    var decoder = VorbisDecoder.init();
    defer decoder.deinit();

    // Submit the 3 header packets
    decoder.submitHeader(packets[0].data, 0) catch {
        return VorbisValidationResult.invalid("Failed to parse Vorbis identification header", 0);
    };
    decoder.submitHeader(packets[1].data, 1) catch {
        return VorbisValidationResult.invalid("Failed to parse Vorbis comment header", 1);
    };
    decoder.submitHeader(packets[2].data, 2) catch {
        return VorbisValidationResult.invalid("Failed to parse Vorbis setup header", 2);
    };

    // Initialize synthesis
    decoder.initSynthesis() catch {
        return VorbisValidationResult.invalid("Failed to initialize Vorbis synthesis", 3);
    };

    // Decode audio packets
    var packets_decoded: u32 = 3; // Count headers
    var samples_decoded: u64 = 0;

    for (packets[3..]) |packet| {
        const samples = decoder.decodePacket(packet.data) catch {
            return VorbisValidationResult.invalid("Vorbis decode error", packets_decoded);
        };
        packets_decoded += 1;
        if (samples > 0) {
            samples_decoded += @intCast(samples);
        }
    }

    return VorbisValidationResult.ok(packets_decoded, samples_decoded);
}

/// Validate OGG Vorbis from a file path.
pub fn validateOggVorbisPath(path: []const u8) VorbisValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return VorbisValidationResult.invalid("Failed to open file", 0);
    };
    defer file.close();
    return validateOggVorbis(file);
}

// ============ Tests ============

test "Vorbis decoder init and deinit" {
    var decoder = VorbisDecoder.init();
    defer decoder.deinit();

    // Just verify we can create and destroy without crashing
    try std.testing.expect(!decoder.initialized);
}

test "Vorbis decoder rejects garbage header" {
    var decoder = VorbisDecoder.init();
    defer decoder.deinit();

    const garbage: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = decoder.submitHeader(garbage, 0);
    try std.testing.expectError(error.VorbisHeaderError, result);
}

test "Vorbis decoder rejects empty header" {
    var decoder = VorbisDecoder.init();
    defer decoder.deinit();

    const empty: []const u8 = &.{};
    const result = decoder.submitHeader(empty, 0);
    try std.testing.expectError(error.VorbisHeaderError, result);
}

test "Vorbis decode without init fails" {
    var decoder = VorbisDecoder.init();
    defer decoder.deinit();

    const data: []const u8 = &.{ 0x01, 0x02, 0x03, 0x04 };
    const result = decoder.decodePacket(data);
    try std.testing.expectError(error.VorbisNotInitialized, result);
}

test "Vorbis validation with invalid file returns error" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a file with garbage data
    const file = tmp_dir.dir.createFile("garbage.ogg", .{ .read = true }) catch unreachable;
    _ = file.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF }) catch unreachable;
    file.close();

    const path = tmp_dir.dir.realpathAlloc(std.testing.allocator, "garbage.ogg") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateOggVorbisPath(path);
    // Currently returns "not implemented" but still tests the path
    try std.testing.expect(!result.valid);
}
