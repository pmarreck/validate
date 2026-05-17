//! MP3 deep decode validation using minimp3.
//!
//! This module provides full-decode validation for MP3 files by actually
//! decoding the audio data using the minimp3 library (public domain).
//!
//! This complements mp3_validator.zig which only verifies CRC16 checksums.
//! Full decode validation catches corruption that:
//! 1. CRCs don't cover (only ~4 bytes/frame covered by MP3 CRC)
//! 2. Is in the audio data itself (Huffman codes, quantized values)
//!
//! Validation approach:
//! 1. Parse MP3 file to find frames
//! 2. Decode each frame using minimp3
//! 3. Report any decode errors

const std = @import("std");
const runtime = @import("runtime.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const errmsg = @import("error_messages.zig");

// Import minimp3 via C interop
const mp3 = @cImport({
    @cInclude("minimp3.h");
});

/// Result of MP3 deep decode validation
pub const Mp3DecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,
    samples_decoded: u64,
    channels: u8,
    sample_rate: u32,

    pub fn ok(frames: u32, samples: u64, channels: u8, rate: u32) Mp3DecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .samples_decoded = samples,
            .channels = channels,
            .sample_rate = rate,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) Mp3DecodeResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_decoded = frames,
            .samples_decoded = 0,
            .channels = 0,
            .sample_rate = 0,
        };
    }
};

/// MP3 decoder wrapper
pub const Mp3Decoder = struct {
    dec: mp3.mp3dec_t,
    frame_info: mp3.mp3dec_frame_info_t,

    /// Initialize decoder
    pub fn init() Mp3Decoder {
        var decoder: Mp3Decoder = undefined;
        mp3.mp3dec_init(&decoder.dec);
        decoder.frame_info = std.mem.zeroes(mp3.mp3dec_frame_info_t);
        return decoder;
    }

    /// Decode a single frame
    /// Returns number of samples decoded (0 = skip/invalid, >0 = success)
    pub fn decodeFrame(self: *Mp3Decoder, input: []const u8, pcm: []i16) i32 {
        return mp3.mp3dec_decode_frame(
            &self.dec,
            input.ptr,
            @intCast(input.len),
            pcm.ptr,
            &self.frame_info,
        );
    }

    /// Get number of channels from last decoded frame
    pub fn getChannels(self: *const Mp3Decoder) u8 {
        return @intCast(self.frame_info.channels);
    }

    /// Get sample rate from last decoded frame
    pub fn getSampleRate(self: *const Mp3Decoder) u32 {
        return @intCast(self.frame_info.hz);
    }

    /// Get frame size in bytes from last decoded frame
    pub fn getFrameBytes(self: *const Mp3Decoder) usize {
        return @intCast(self.frame_info.frame_bytes);
    }
};

/// Validate MP3 file by full decode.
pub fn validateMp3Decode(file: *FileSource) Mp3DecodeResult {
    var decoder = Mp3Decoder.init();
    var frames_decoded: u32 = 0;
    var samples_decoded: u64 = 0;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;

    // Get file size
    const file_size = file.getEndPos() catch {
        return Mp3DecodeResult.invalid(errmsg.failedToStat("file"), 0);
    };

    if (file_size == 0) {
        return Mp3DecodeResult.invalid(errmsg.empty("file"), 0);
    }

    if (file_size > 500 * 1024 * 1024) { // 500MB limit
        return Mp3DecodeResult.invalid(errmsg.fileTooLargeFor("decode validation"), 0);
    }

    // Seek to start
    file.seekTo(0) catch {
        return Mp3DecodeResult.invalid(errmsg.failedToSeek("to start"), 0);
    };

    // Read file in chunks
    const chunk_size: usize = 64 * 1024; // 64KB chunks
    var buffer: [chunk_size + mp3.MINIMP3_MAX_SAMPLES_PER_FRAME * 2]u8 = undefined;
    var pcm: [mp3.MINIMP3_MAX_SAMPLES_PER_FRAME]i16 = undefined;

    var buffer_len: usize = 0;
    var eof = false;

    while (true) {
        // Refill buffer if needed
        if (buffer_len < mp3.MINIMP3_MAX_SAMPLES_PER_FRAME * 2 and !eof) {
            // Move remaining data to start
            if (buffer_len > 0) {
                std.mem.copyForwards(u8, buffer[0..buffer_len], buffer[chunk_size - buffer_len .. chunk_size]);
            }

            // Read more data
            const bytes_read = file.read(buffer[buffer_len..chunk_size]) catch {
                return Mp3DecodeResult.invalid(errmsg.failedToRead("file"), frames_decoded);
            };
            if (bytes_read == 0) {
                eof = true;
            }
            buffer_len += bytes_read;
        }

        if (buffer_len == 0) {
            break;
        }

        // Try to decode a frame
        const samples = decoder.decodeFrame(buffer[0..buffer_len], &pcm);

        const frame_bytes = decoder.getFrameBytes();
        if (frame_bytes == 0) {
            // No valid frame found, skip 1 byte
            if (buffer_len > 0) {
                buffer_len -= 1;
                std.mem.copyForwards(u8, buffer[0..buffer_len], buffer[1 .. buffer_len + 1]);
            }
            continue;
        }

        // Move past consumed bytes
        if (frame_bytes <= buffer_len) {
            buffer_len -= frame_bytes;
            std.mem.copyForwards(u8, buffer[0..buffer_len], buffer[frame_bytes .. frame_bytes + buffer_len]);
        }

        if (samples > 0) {
            frames_decoded += 1;
            samples_decoded += @intCast(samples);

            // Capture format info from first successful decode
            if (channels == 0) {
                channels = decoder.getChannels();
                sample_rate = decoder.getSampleRate();
            }
        }
    }

    if (frames_decoded == 0) {
        return Mp3DecodeResult.invalid(errmsg.noValidXFound("MP3 frames"), 0);
    }

    return Mp3DecodeResult.ok(frames_decoded, samples_decoded, channels, sample_rate);
}

/// Validate MP3 decode from a file path.
pub fn validateMp3DecodePath(path: []const u8) Mp3DecodeResult {
    var source = FileSource.open(path) catch {
        return Mp3DecodeResult.invalid(errmsg.failedToOpen("file"), 0);
    };
    defer source.close();
    return validateMp3Decode(&source);
}

/// Validate MP3 data from an in-memory buffer (for MPEG-TS PES streams, etc.)
pub fn validateMp3DecodeBuffer(data: []const u8) Mp3DecodeResult {
    if (data.len == 0) {
        return Mp3DecodeResult.invalid(errmsg.empty("buffer"), 0);
    }

    var decoder = Mp3Decoder.init();
    var frames_decoded: u32 = 0;
    var samples_decoded: u64 = 0;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;

    var offset: usize = 0;
    var consecutive_failures: u32 = 0;

    while (offset < data.len) {
        const remaining = data[offset..];
        if (remaining.len < 4) break;

        var pcm: [mp3.MINIMP3_MAX_SAMPLES_PER_FRAME]i16 = undefined;
        const samples = decoder.decodeFrame(remaining, &pcm);
        const frame_bytes = decoder.getFrameBytes();

        if (frame_bytes == 0) {
            // No valid frame found, skip 1 byte
            offset += 1;
            consecutive_failures += 1;
            if (consecutive_failures > 4096) {
                // Too much garbage data
                break;
            }
            continue;
        }

        consecutive_failures = 0;
        offset += frame_bytes;

        if (samples > 0) {
            frames_decoded += 1;
            samples_decoded += @intCast(samples);

            if (channels == 0) {
                channels = decoder.getChannels();
                sample_rate = decoder.getSampleRate();
            }
        }
    }

    if (frames_decoded == 0) {
        return Mp3DecodeResult.invalid(errmsg.noValidXFound("MP3 frames"), 0);
    }

    return Mp3DecodeResult.ok(frames_decoded, samples_decoded, channels, sample_rate);
}

// ============ Tests ============

test "MP3 decoder init" {
    const decoder = Mp3Decoder.init();
    // Just verify we can create without crashing
    _ = decoder;
}

test "MP3 decode empty buffer returns no samples" {
    var decoder = Mp3Decoder.init();
    var pcm: [mp3.MINIMP3_MAX_SAMPLES_PER_FRAME]i16 = undefined;

    const samples = decoder.decodeFrame(&.{}, &pcm);
    try std.testing.expectEqual(@as(i32, 0), samples);
}

test "MP3 decode garbage returns no samples" {
    var decoder = Mp3Decoder.init();
    var pcm: [mp3.MINIMP3_MAX_SAMPLES_PER_FRAME]i16 = undefined;

    const garbage: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const samples = decoder.decodeFrame(garbage, &pcm);
    // Garbage should not decode to valid frames
    try std.testing.expectEqual(@as(i32, 0), samples);
}

test "MP3 validation rejects empty file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile(runtime.io(), "empty.mp3", .{}) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "empty.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3DecodePath(path);
    try std.testing.expect(!result.valid);
}

test "MP3 validation rejects garbage file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = tmp_dir.dir.createFile(runtime.io(), "garbage.mp3", .{ .read = true }) catch unreachable;
    _ = file.write(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 }) catch unreachable;
    file.close(runtime.io());

    const path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "garbage.mp3") catch unreachable;
    defer std.testing.allocator.free(path);

    const result = validateMp3DecodePath(path);
    try std.testing.expect(!result.valid);
}
