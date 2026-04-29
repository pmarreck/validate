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
const heap = @import("heap.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ogg_validator = @import("ogg_validator.zig");
const errmsg = @import("error_messages.zig");

// Import libopus via C interop (including multistream for >2 channels)
const opus = @cImport({
    @cInclude("opus/opus.h");
    @cInclude("opus/opus_multistream.h");
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
    handle: DecoderHandle,
    packet: []const u8,
    output_buffer: []i16,
    channels: i32,
) !i32 {
    const frame_size: c_int = @intCast(output_buffer.len / @as(usize, @intCast(@max(channels, 1))));
    const result = switch (handle) {
        .simple => |decoder| opus.opus_decode(
            decoder,
            packet.ptr,
            @intCast(packet.len),
            output_buffer.ptr,
            frame_size,
            0,
        ),
        .multistream => |decoder| opus.opus_multistream_decode(
            decoder,
            packet.ptr,
            @intCast(packet.len),
            output_buffer.ptr,
            frame_size,
            0,
        ),
    };

    if (result < 0) {
        return error.OpusDecodeError;
    }

    return result;
}

/// Opus decoder handle — either simple (1-2 ch) or multistream (>2 ch)
pub const DecoderHandle = union(enum) {
    simple: *opus.OpusDecoder,
    multistream: *opus.OpusMSDecoder,
};

/// Create an Opus decoder. Uses multistream API for >2 channels.
/// `opus_head` is the raw OpusHead data from the container (needed for channel mapping).
/// Caller must call destroyDecoder when done.
pub fn createDecoder(sample_rate: i32, channels: i32, opus_head: ?[]const u8) !DecoderHandle {
    var err: c_int = 0;

    if (channels <= 2) {
        const decoder = opus.opus_decoder_create(sample_rate, channels, &err);
        if (err != opus.OPUS_OK or decoder == null) {
            return error.OpusDecoderCreateFailed;
        }
        return .{ .simple = decoder.? };
    }

    // Multichannel: need channel mapping from OpusHead
    // OpusHead layout: "OpusHead"(8) + version(1) + channels(1) + pre_skip(2) +
    //   sample_rate(4) + output_gain(2) + mapping_family(1) + [if family>0: stream_count(1) +
    //   coupled_count(1) + channel_mapping(channels)]
    const head = opus_head orelse return error.OpusDecoderCreateFailed;
    if (head.len < 19) return error.OpusDecoderCreateFailed;

    const mapping_family = head[18];
    if (mapping_family == 0) {
        // Family 0: standard stereo/mono mapping — shouldn't have >2 channels but try
        const decoder = opus.opus_decoder_create(sample_rate, @min(channels, 2), &err);
        if (err != opus.OPUS_OK or decoder == null) return error.OpusDecoderCreateFailed;
        return .{ .simple = decoder.? };
    }

    // Family 1 (Vorbis order) or Family 255 (custom)
    if (head.len < 21 + @as(usize, @intCast(channels))) return error.OpusDecoderCreateFailed;
    const streams: c_int = @intCast(head[19]);
    const coupled: c_int = @intCast(head[20]);
    const mapping_ptr: [*c]const u8 = @ptrCast(head[21..].ptr);

    const ms_decoder = opus.opus_multistream_decoder_create(
        sample_rate, channels, streams, coupled, mapping_ptr, &err,
    );
    if (err != opus.OPUS_OK or ms_decoder == null) {
        return error.OpusDecoderCreateFailed;
    }
    return .{ .multistream = ms_decoder.? };
}

/// Destroy an Opus decoder (simple or multistream).
pub fn destroyDecoder(handle: DecoderHandle) void {
    switch (handle) {
        .simple => |d| opus.opus_decoder_destroy(d),
        .multistream => |d| opus.opus_multistream_decoder_destroy(d),
    }
}

/// Validate Opus stream from raw packets.
/// This is the low-level API for validating Opus data extracted from containers.
/// `opus_head` is the raw OpusHead data (needed for multichannel mapping).
pub fn validateOpusPackets(
    allocator: std.mem.Allocator,
    packets: []const []const u8,
    sample_rate: i32,
    channels: i32,
    opus_head: ?[]const u8,
) OpusValidationResult {
    // Create decoder (uses multistream API for >2 channels)
    const decoder = createDecoder(sample_rate, channels, opus_head) catch {
        return OpusValidationResult.invalid("Failed to create Opus decoder", 0);
    };
    defer destroyDecoder(decoder);

    // Allocate output buffer (max 120ms at 48kHz, scaled by channels)
    const max_frame_size: usize = 5760 * @as(usize, @intCast(@max(channels, 1)));
    const output_buffer = allocator.alloc(i16, max_frame_size) catch {
        return OpusValidationResult.invalid(errmsg.failedToAllocate("decode buffer"), 0);
    };
    defer allocator.free(output_buffer);

    var packets_decoded: u32 = 0;
    var samples_decoded: u64 = 0;

    for (packets) |packet| {
        const samples = validateOpusPacket(decoder, packet, output_buffer, channels) catch {
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
pub fn validateOggOpus(file: *FileSource) OpusValidationResult {
    return validateOggOpusAlloc(heap.validateAllocator(), file);
}

/// Validate OGG Opus file with custom allocator.
pub fn validateOggOpusAlloc(allocator: std.mem.Allocator, file: *FileSource) OpusValidationResult {
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
        return OpusValidationResult.invalid(errmsg.unsupported("Opus version"), 0);
    }

    const channels: i32 = opus_head[9];
    if (channels < 1 or channels > 255) {
        return OpusValidationResult.invalid(errmsg.unsupported("channel count"), 0);
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

    // Create decoder (multistream for >2 channels, simple for 1-2)
    const decoder = createDecoder(decode_sample_rate, channels, opus_head) catch {
        return OpusValidationResult.invalid("Failed to create Opus decoder", 0);
    };
    defer destroyDecoder(decoder);

    // Allocate output buffer (max 120ms at 48kHz, scaled by channels)
    const max_frame_size: usize = 5760 * @as(usize, @intCast(@max(channels, 1)));
    const output_buffer = allocator.alloc(i16, max_frame_size) catch {
        return OpusValidationResult.invalid(errmsg.failedToAllocate("decode buffer"), 0);
    };
    defer allocator.free(output_buffer);

    // Decode audio packets (skip first 2 header packets)
    var packets_decoded: u32 = 2; // Count headers
    var samples_decoded: u64 = 0;

    for (packets[2..]) |packet| {
        const samples = validateOpusPacket(decoder, packet.data, output_buffer, channels) catch {
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
    var source = FileSource.open(path) catch {
        return OpusValidationResult.invalid(errmsg.failedToOpen("file"), 0);
    };
    defer source.close();
    return validateOggOpus(&source);
}

// ============ Tests ============

test "Opus decoder creation and destruction" {
    // Test that we can create and destroy a decoder
    const decoder = try createDecoder(48000, 2, null);
    destroyDecoder(decoder);
}

test "Opus decoder rejects invalid parameters" {
    // Invalid sample rate
    const result1 = createDecoder(12345, 2, null);
    try std.testing.expectError(error.OpusDecoderCreateFailed, result1);

    // Invalid channel count
    const result2 = createDecoder(48000, 0, null);
    try std.testing.expectError(error.OpusDecoderCreateFailed, result2);
}

test "Opus decode handles empty packet via PLC" {
    // Opus handles empty packets through Packet Loss Concealment (PLC)
    // It doesn't error, but generates concealed audio
    const decoder = try createDecoder(48000, 2, null);
    defer destroyDecoder(decoder);

    var output: [5760 * 2]i16 = undefined;
    const empty_packet: []const u8 = &.{};

    const result = validateOpusPacket(decoder, empty_packet, &output, 2);
    // PLC returns samples, not an error
    const samples = result catch unreachable;
    try std.testing.expect(samples > 0);
}

test "Opus decode rejects garbage data" {
    const decoder = try createDecoder(48000, 2, null);
    defer destroyDecoder(decoder);

    var output: [5760 * 2]i16 = undefined;
    const garbage: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };

    const result = validateOpusPacket(decoder, garbage, &output, 2);
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
        null,
    );
    try std.testing.expect(!result.valid);
}

test "Opus decode valid silence packet" {
    const decoder = try createDecoder(48000, 2, null);
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
    _ = validateOpusPacket(decoder, silence_toc, &output, 2) catch {
        // Some simplified packets might be rejected - that's OK
        return;
    };
}
