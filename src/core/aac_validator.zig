//! AAC deep decode validation using libfdk-aac.
//!
//! This module provides full-decode validation for AAC audio by actually
//! decoding the audio data using the Fraunhofer FDK AAC library.
//!
//! Supported inputs:
//! - ADTS streams (standalone .aac files)
//! - Raw AAC access units (extracted from MP4/MKV containers)
//!
//! Validation approach:
//! 1. Initialize decoder with appropriate transport format
//! 2. Feed data and decode frames
//! 3. Report any decode errors

const std = @import("std");

// Import libfdk-aac via C interop
const aac = @cImport({
    @cInclude("fdk-aac/aacdecoder_lib.h");
});

/// Result of AAC deep decode validation
pub const AacDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,
    samples_decoded: u64,
    channels: u8,
    sample_rate: u32,

    pub fn ok(frames: u32, samples: u64, channels: u8, rate: u32) AacDecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .samples_decoded = samples,
            .channels = channels,
            .sample_rate = rate,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) AacDecodeResult {
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

/// Transport format for AAC decoder
pub const TransportFormat = enum {
    /// ADTS bitstream (standalone .aac files)
    adts,
    /// Raw AAC access units (extracted from MP4/MKV)
    raw,
    /// LATM with muxConfigPresent
    latm,
};

/// AAC decoder wrapper
pub const AacDecoder = struct {
    handle: aac.HANDLE_AACDECODER,

    /// Initialize decoder for given transport format
    pub fn init(transport: TransportFormat) ?AacDecoder {
        const tt: aac.TRANSPORT_TYPE = switch (transport) {
            .adts => aac.TT_MP4_ADTS,
            .raw => aac.TT_MP4_RAW,
            .latm => aac.TT_MP4_LATM_MCP1,
        };

        const handle = aac.aacDecoder_Open(tt, 1); // 1 layer
        if (handle == null) {
            return null;
        }

        return AacDecoder{ .handle = handle };
    }

    /// Deinitialize decoder
    pub fn deinit(self: *AacDecoder) void {
        if (self.handle != null) {
            aac.aacDecoder_Close(self.handle);
            self.handle = null;
        }
    }

    /// Configure decoder with raw ASC (Audio Specific Config) data
    /// Required for TT_MP4_RAW format
    pub fn configureRaw(self: *AacDecoder, asc_data: []const u8) bool {
        var buf_ptr: [*c]u8 = @constCast(asc_data.ptr);
        var buf_size: c_uint = @intCast(asc_data.len);

        const err = aac.aacDecoder_ConfigRaw(self.handle, &buf_ptr, &buf_size);
        return err == aac.AAC_DEC_OK;
    }

    /// Fill decoder input buffer
    /// Returns number of bytes consumed, or null on error
    pub fn fill(self: *AacDecoder, data: []const u8) ?usize {
        var buf_ptr: [*c]u8 = @constCast(data.ptr);
        var buf_size: c_uint = @intCast(data.len);
        var bytes_valid: c_uint = buf_size;

        const err = aac.aacDecoder_Fill(self.handle, &buf_ptr, &buf_size, &bytes_valid);
        if (err != aac.AAC_DEC_OK) {
            return null;
        }

        return data.len - @as(usize, bytes_valid);
    }

    /// Decode one frame
    /// Returns samples decoded, or error info
    pub const DecodeResult = union(enum) {
        success: struct {
            samples: u32,
            channels: u8,
            sample_rate: u32,
        },
        need_more_bits,
        sync_error,
        decode_error: aac.AAC_DECODER_ERROR,
    };

    pub fn decodeFrame(self: *AacDecoder, pcm: []i16) DecodeResult {
        const err = aac.aacDecoder_DecodeFrame(
            self.handle,
            pcm.ptr,
            @intCast(pcm.len),
            0, // flags
        );

        if (err == aac.AAC_DEC_OK) {
            const info = aac.aacDecoder_GetStreamInfo(self.handle);
            if (info == null) {
                return .{ .decode_error = aac.AAC_DEC_UNKNOWN };
            }

            return .{
                .success = .{
                    .samples = @intCast(info.*.frameSize),
                    .channels = @intCast(info.*.numChannels),
                    .sample_rate = @intCast(info.*.sampleRate),
                },
            };
        } else if (err == aac.AAC_DEC_NOT_ENOUGH_BITS) {
            return .need_more_bits;
        } else if (err == aac.AAC_DEC_TRANSPORT_SYNC_ERROR) {
            return .sync_error;
        } else {
            return .{ .decode_error = err };
        }
    }
};

/// Maximum PCM output buffer size (8 channels * 2048 samples * 2 bytes)
pub const MAX_PCM_BUFFER_SIZE = 8 * 2048;

/// Validate ADTS AAC file by full decode.
pub fn validateAacAdts(file: std.fs.File) AacDecodeResult {
    var decoder = AacDecoder.init(.adts) orelse {
        return AacDecodeResult.invalid("Failed to create AAC decoder", 0);
    };
    defer decoder.deinit();

    return decodeAacStream(file, &decoder);
}

/// Validate raw AAC access units with ASC configuration.
pub fn validateAacRaw(data: []const u8, asc: []const u8) AacDecodeResult {
    var decoder = AacDecoder.init(.raw) orelse {
        return AacDecodeResult.invalid("Failed to create AAC decoder", 0);
    };
    defer decoder.deinit();

    // Configure with ASC
    if (!decoder.configureRaw(asc)) {
        return AacDecodeResult.invalid("Failed to configure AAC decoder with ASC", 0);
    }

    return decodeAacBuffer(data, &decoder);
}

/// Internal: decode AAC stream from file
fn decodeAacStream(file: std.fs.File, decoder: *AacDecoder) AacDecodeResult {
    var frames_decoded: u32 = 0;
    var samples_decoded: u64 = 0;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;

    // Get file size
    const stat = file.stat() catch {
        return AacDecodeResult.invalid("Failed to stat file", 0);
    };
    const file_size = stat.size;

    if (file_size == 0) {
        return AacDecodeResult.invalid("Empty file", 0);
    }

    if (file_size > 500 * 1024 * 1024) { // 500MB limit
        return AacDecodeResult.invalid("File too large for decode validation", 0);
    }

    // Seek to start
    file.seekTo(0) catch {
        return AacDecodeResult.invalid("Failed to seek to start", 0);
    };

    // Read and decode in chunks
    const chunk_size: usize = 64 * 1024; // 64KB chunks
    var buffer: [chunk_size]u8 = undefined;
    var pcm: [MAX_PCM_BUFFER_SIZE]i16 = undefined;
    var consecutive_sync_errors: u32 = 0;

    while (true) {
        // Read more data
        const bytes_read = file.read(&buffer) catch {
            return AacDecodeResult.invalid("Failed to read file", frames_decoded);
        };

        if (bytes_read == 0) {
            break;
        }

        // Fill decoder buffer
        var offset: usize = 0;
        while (offset < bytes_read) {
            const consumed = decoder.fill(buffer[offset..bytes_read]) orelse {
                return AacDecodeResult.invalid("Failed to fill decoder buffer", frames_decoded);
            };
            offset += consumed;

            // Try to decode frames
            while (true) {
                const result = decoder.decodeFrame(&pcm);
                switch (result) {
                    .success => |info| {
                        frames_decoded += 1;
                        samples_decoded += info.samples;
                        consecutive_sync_errors = 0;

                        // Capture format info from first successful decode
                        if (channels == 0) {
                            channels = info.channels;
                            sample_rate = info.sample_rate;
                        }
                    },
                    .need_more_bits => break,
                    .sync_error => {
                        consecutive_sync_errors += 1;
                        if (consecutive_sync_errors > 100) {
                            return AacDecodeResult.invalid("Too many sync errors", frames_decoded);
                        }
                        break;
                    },
                    .decode_error => |err| {
                        // Some errors are recoverable
                        if (err == aac.AAC_DEC_CRC_ERROR) {
                            return AacDecodeResult.invalid("AAC CRC error", frames_decoded);
                        }
                        if (err == aac.AAC_DEC_DECODE_FRAME_ERROR) {
                            return AacDecodeResult.invalid("AAC frame decode error", frames_decoded);
                        }
                        // Try to continue for other errors
                        break;
                    },
                }
            }
        }
    }

    if (frames_decoded == 0) {
        return AacDecodeResult.invalid("No valid AAC frames found", 0);
    }

    return AacDecodeResult.ok(frames_decoded, samples_decoded, channels, sample_rate);
}

/// Internal: decode AAC from memory buffer
fn decodeAacBuffer(data: []const u8, decoder: *AacDecoder) AacDecodeResult {
    var frames_decoded: u32 = 0;
    var samples_decoded: u64 = 0;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;

    if (data.len == 0) {
        return AacDecodeResult.invalid("Empty data", 0);
    }

    var pcm: [MAX_PCM_BUFFER_SIZE]i16 = undefined;
    var consecutive_sync_errors: u32 = 0;

    // Fill decoder buffer with all data
    var offset: usize = 0;
    while (offset < data.len) {
        const consumed = decoder.fill(data[offset..]) orelse {
            return AacDecodeResult.invalid("Failed to fill decoder buffer", frames_decoded);
        };
        if (consumed == 0) break;
        offset += consumed;
    }

    // Decode all frames
    while (true) {
        const result = decoder.decodeFrame(&pcm);
        switch (result) {
            .success => |info| {
                frames_decoded += 1;
                samples_decoded += info.samples;
                consecutive_sync_errors = 0;

                if (channels == 0) {
                    channels = info.channels;
                    sample_rate = info.sample_rate;
                }
            },
            .need_more_bits => break,
            .sync_error => {
                consecutive_sync_errors += 1;
                if (consecutive_sync_errors > 100) {
                    return AacDecodeResult.invalid("Too many sync errors", frames_decoded);
                }
            },
            .decode_error => |err| {
                if (err == aac.AAC_DEC_CRC_ERROR) {
                    return AacDecodeResult.invalid("AAC CRC error", frames_decoded);
                }
                if (err == aac.AAC_DEC_DECODE_FRAME_ERROR) {
                    return AacDecodeResult.invalid("AAC frame decode error", frames_decoded);
                }
                break;
            },
        }
    }

    if (frames_decoded == 0) {
        return AacDecodeResult.invalid("No valid AAC frames found", 0);
    }

    return AacDecodeResult.ok(frames_decoded, samples_decoded, channels, sample_rate);
}

/// Validate AAC decode from a file path (assumes ADTS format).
pub fn validateAacDecodePath(path: []const u8) AacDecodeResult {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return AacDecodeResult.invalid("Failed to open file", 0);
    };
    defer file.close();
    return validateAacAdts(file);
}

// ============ Tests ============

test "AAC decoder init/deinit" {
    var decoder = AacDecoder.init(.adts) orelse {
        return error.DecoderInitFailed;
    };
    defer decoder.deinit();
    // Just verify we can create without crashing
}

test "AAC validation rejects empty data" {
    var decoder = AacDecoder.init(.adts) orelse {
        return error.DecoderInitFailed;
    };
    defer decoder.deinit();

    const result = decodeAacBuffer(&.{}, &decoder);
    try std.testing.expect(!result.valid);
}

test "AAC validation rejects garbage data" {
    var decoder = AacDecoder.init(.adts) orelse {
        return error.DecoderInitFailed;
    };
    defer decoder.deinit();

    const garbage: []const u8 = &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33 };
    const result = decodeAacBuffer(garbage, &decoder);
    try std.testing.expect(!result.valid);
}
