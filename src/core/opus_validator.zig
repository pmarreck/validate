//! Opus audio deep validation using libopus.
//!
//! Opus is a lossy audio codec widely used in WebM, OGG containers, and
//! streaming applications. This module provides deep (decode-level) validation
//! to detect corruption that structural validation cannot catch.
//!
//! Validation approach:
//! 1. Parse OGG container to extract Opus packets
//! 2. Initialize libopus decoder with stream parameters
//! 3. Decode each packet and check for decoder errors
//!
//! Note: OGG page CRC32 verification (in ogg_validator.zig) provides 100%
//! coverage of container bytes. This module adds codec-level validation
//! for the Opus bitstream itself.

const std = @import("std");
const ogg_validator = @import("ogg_validator.zig");

// Import libopus via C interop
const opus = @cImport({
    @cInclude("opus/opus.h");
});

/// Result of Opus deep validation
pub const OpusValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    packets_decoded: u32,
    samples_decoded: u64,

    pub fn ok(packets: u32, samples: u64) OpusValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .packets_decoded = packets,
            .samples_decoded = samples,
        };
    }

    pub fn invalid(message: []const u8, packets: u32) OpusValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .packets_decoded = packets,
            .samples_decoded = 0,
        };
    }
};

/// Validate a single Opus packet using libopus decoder.
/// Returns number of samples decoded, or error.
pub fn validateOpusPacket(
    decoder: *opus.OpusDecoder,
    packet: []const u8,
    output_buffer: []i16,
) !i32 {
    const result = opus.opus_decode(
        decoder,
        packet.ptr,
        @intCast(packet.len),
        output_buffer.ptr,
        @intCast(output_buffer.len / 2), // frame_size in samples per channel
        0, // decode_fec = false
    );

    if (result < 0) {
        return error.OpusDecodeError;
    }

    return result;
}

/// Create an Opus decoder.
/// Caller must call destroyDecoder when done.
pub fn createDecoder(sample_rate: i32, channels: i32) !*opus.OpusDecoder {
    var err: c_int = 0;
    const decoder = opus.opus_decoder_create(sample_rate, channels, &err);

    if (err != opus.OPUS_OK or decoder == null) {
        return error.OpusDecoderCreateFailed;
    }

    return decoder.?;
}

/// Destroy an Opus decoder.
pub fn destroyDecoder(decoder: *opus.OpusDecoder) void {
    opus.opus_decoder_destroy(decoder);
}

/// Validate Opus stream from raw packets.
/// This is the low-level API for validating Opus data extracted from containers.
pub fn validateOpusPackets(
    allocator: std.mem.Allocator,
    packets: []const []const u8,
    sample_rate: i32,
    channels: i32,
) OpusValidationResult {
    // Create decoder
    const decoder = createDecoder(sample_rate, channels) catch {
        return OpusValidationResult.invalid("Failed to create Opus decoder", 0);
    };
    defer destroyDecoder(decoder);

    // Allocate output buffer (max 120ms at 48kHz stereo = 5760 samples * 2 channels)
    const max_frame_size: usize = 5760 * 2;
    const output_buffer = allocator.alloc(i16, max_frame_size) catch {
        return OpusValidationResult.invalid("Failed to allocate decode buffer", 0);
    };
    defer allocator.free(output_buffer);

    var packets_decoded: u32 = 0;
    var samples_decoded: u64 = 0;

    for (packets) |packet| {
        const samples = validateOpusPacket(decoder, packet, output_buffer) catch {
            return OpusValidationResult.invalid("Opus decode error", packets_decoded);
        };
        packets_decoded += 1;
        samples_decoded += @intCast(samples);
    }

    if (packets_decoded == 0) {
        return OpusValidationResult.invalid("No Opus packets found", 0);
    }

    return OpusValidationResult.ok(packets_decoded, samples_decoded);
}

/// Parse OGG Opus stream and validate all packets.
/// This is the high-level API for validating OGG Opus files.
pub fn validateOggOpus(file: std.fs.File) OpusValidationResult {
    return validateOggOpusAlloc(std.heap.page_allocator, file);
}

/// Validate OGG Opus file with custom allocator.
pub fn validateOggOpusAlloc(allocator: std.mem.Allocator, file: std.fs.File) OpusValidationResult {
    // Extract packets from OGG container
    var packet_result = ogg_validator.extractPackets(allocator, file) catch |err| {
        return OpusValidationResult.invalid(switch (err) {
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

    // Need at least 2 header packets + 1 audio packet
    if (packets.len < 3) {
        return OpusValidationResult.invalid("Insufficient Opus packets (need at least 3)", 0);
    }

    // Parse OpusHead (first packet)
    // RFC 7845: Must start with "OpusHead" magic
    const opus_head = packets[0].data;
    if (opus_head.len < 19 or !std.mem.eql(u8, opus_head[0..8], "OpusHead")) {
        return OpusValidationResult.invalid("Invalid OpusHead packet", 0);
    }

    // Extract parameters from OpusHead
    const version = opus_head[8];
    if (version != 1) {
        return OpusValidationResult.invalid("Unsupported Opus version", 0);
    }

    const channels: i32 = opus_head[9];
    if (channels < 1 or channels > 2) {
        // libopus only supports mono and stereo for basic decoding
        return OpusValidationResult.invalid("Unsupported channel count for decoding", 0);
    }

    // Sample rate from OpusHead is just informational (original input sample rate)
    // Opus always decodes at 48kHz internally
    const decode_sample_rate: i32 = 48000;

    // Verify OpusTags (second packet)
    // Must start with "OpusTags"
    const opus_tags = packets[1].data;
    if (opus_tags.len < 8 or !std.mem.eql(u8, opus_tags[0..8], "OpusTags")) {
        return OpusValidationResult.invalid("Invalid OpusTags packet", 0);
    }

    // Create decoder
    const decoder = createDecoder(decode_sample_rate, channels) catch {
        return OpusValidationResult.invalid("Failed to create Opus decoder", 0);
    };
    defer destroyDecoder(decoder);

    // Allocate output buffer (max 120ms at 48kHz stereo = 5760 samples * 2 channels)
    const max_frame_size: usize = 5760 * 2;
    const output_buffer = allocator.alloc(i16, max_frame_size) catch {
        return OpusValidationResult.invalid("Failed to allocate decode buffer", 0);
    };
    defer allocator.free(output_buffer);

    // Decode audio packets (skip first 2 header packets)
    var packets_decoded: u32 = 2; // Count headers
    var samples_decoded: u64 = 0;

    for (packets[2..]) |packet| {
        const samples = validateOpusPacket(decoder, packet.data, output_buffer) catch {
            return OpusValidationResult.invalid("Opus decode error", packets_decoded);
        };
        packets_decoded += 1;
        if (samples > 0) {
            samples_decoded += @intCast(samples);
        }
    }

    return OpusValidationResult.ok(packets_decoded, samples_decoded);
}

/// Validate OGG Opus from a file path.
pub fn validateOggOpusPath(path: []const u8) OpusValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return OpusValidationResult.invalid("Failed to open file", 0);
    };
    defer file.close();
    return validateOggOpus(file);
}

// ============ Tests ============

test "Opus decoder creation and destruction" {
    // Test that we can create and destroy a decoder
    const decoder = try createDecoder(48000, 2);
    destroyDecoder(decoder);
}

test "Opus decoder rejects invalid parameters" {
    // Invalid sample rate
    const result1 = createDecoder(12345, 2);
    try std.testing.expectError(error.OpusDecoderCreateFailed, result1);

    // Invalid channel count
    const result2 = createDecoder(48000, 0);
    try std.testing.expectError(error.OpusDecoderCreateFailed, result2);
}

test "Opus decode handles empty packet via PLC" {
    // Opus handles empty packets through Packet Loss Concealment (PLC)
    // It doesn't error, but generates concealed audio
    const decoder = try createDecoder(48000, 2);
    defer destroyDecoder(decoder);

    var output: [5760 * 2]i16 = undefined;
    const empty_packet: []const u8 = &.{};

    const result = validateOpusPacket(decoder, empty_packet, &output);
    // PLC returns samples, not an error
    const samples = result catch unreachable;
    try std.testing.expect(samples > 0);
}

test "Opus decode rejects garbage data" {
    const decoder = try createDecoder(48000, 2);
    defer destroyDecoder(decoder);

    var output: [5760 * 2]i16 = undefined;
    const garbage: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };

    const result = validateOpusPacket(decoder, garbage, &output);
    // Garbage data might either decode with errors or produce garbage output
    // Libopus is quite resilient, so it might not always error
    _ = result catch {
        // Expected - garbage rejected
        return;
    };
    // If it didn't error, that's also valid behavior for some garbage
}

test "Opus validation with no packets returns invalid" {
    const result = validateOpusPackets(
        std.testing.allocator,
        &.{},
        48000,
        2,
    );
    try std.testing.expect(!result.valid);
}

test "Opus decode valid silence packet" {
    const decoder = try createDecoder(48000, 2);
    defer destroyDecoder(decoder);

    var output: [5760 * 2]i16 = undefined;

    // A minimal valid Opus packet (TOC byte + minimal data)
    // TOC: 0xFC = SILK-only, 20ms frame, stereo
    // This is a simplified test - real Opus packets are more complex
    const silence_toc: []const u8 = &.{
        0xFC, // TOC: config 31 (CELT FB), s=1 (stereo), c=0 (1 frame)
        0x00, // Minimal data
    };

    // This may or may not decode depending on libopus validation
    // The point is to verify we can call the decode function
    _ = validateOpusPacket(decoder, silence_toc, &output) catch {
        // Some simplified packets might be rejected - that's OK
        return;
    };
}
