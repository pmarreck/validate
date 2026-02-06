//! ALAC (Apple Lossless Audio Codec) deep decode validation.
//!
//! Pure Zig implementation based on the ALAC format specification.
//! ALAC uses LPC (Linear Predictive Coding) with Golomb-Rice coding.
//!
//! Supported inputs:
//! - Raw ALAC frames (extracted from M4A/MP4 containers)
//!
//! Validation approach:
//! 1. Parse magic cookie for decoder configuration
//! 2. Decode frames to PCM
//! 3. Report any decode errors

const std = @import("std");
const Allocator = std.mem.Allocator;
const BitReader = @import("bitstream_reader.zig").BitReader;

/// Result of ALAC deep decode validation
pub const AlacDecodeResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    frames_decoded: u32,
    samples_decoded: u64,
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,

    pub fn ok(frames: u32, samples: u64, channels: u8, rate: u32, bits: u8) AlacDecodeResult {
        return .{
            .valid = true,
            .error_message = null,
            .frames_decoded = frames,
            .samples_decoded = samples,
            .channels = channels,
            .sample_rate = rate,
            .bits_per_sample = bits,
        };
    }

    pub fn invalid(message: []const u8, frames: u32) AlacDecodeResult {
        return .{
            .valid = false,
            .error_message = message,
            .frames_decoded = frames,
            .samples_decoded = 0,
            .channels = 0,
            .sample_rate = 0,
            .bits_per_sample = 0,
        };
    }
};

/// ALAC magic cookie (decoder configuration from MP4 alac atom)
pub const AlacConfig = struct {
    frame_length: u32, // Default 4096 samples per frame
    compatible_version: u8,
    bits_per_sample: u8, // 16, 20, 24, or 32
    pb: u8, // Rice history parameter (default 40)
    mb: u8, // Rice k modifier (default 10)
    kb: u8, // Rice k shift (default 14)
    num_channels: u8,
    max_run: u16, // Max run for RLE (default 255)
    max_frame_bytes: u32,
    avg_bit_rate: u32,
    sample_rate: u32,

    /// Parse from magic cookie data (at least 24 bytes)
    pub fn parse(data: []const u8) ?AlacConfig {
        if (data.len < 24) return null;

        // ALACSpecificConfig structure:
        // frameLength (4), compatibleVersion (1), bitDepth (1),
        // pb (1), mb (1), kb (1), numChannels (1), maxRun (2),
        // maxFrameBytes (4), avgBitRate (4), sampleRate (4)

        return AlacConfig{
            .frame_length = std.mem.readInt(u32, data[0..4], .big),
            .compatible_version = data[4],
            .bits_per_sample = data[5],
            .pb = data[6],
            .mb = data[7],
            .kb = data[8],
            .num_channels = data[9],
            .max_run = std.mem.readInt(u16, data[10..12], .big),
            .max_frame_bytes = std.mem.readInt(u32, data[12..16], .big),
            .avg_bit_rate = std.mem.readInt(u32, data[16..20], .big),
            .sample_rate = std.mem.readInt(u32, data[20..24], .big),
        };
    }
};


/// ALAC decoder
pub const AlacDecoder = struct {
    config: AlacConfig,
    allocator: Allocator,
    mix_buffer_l: []i32,
    mix_buffer_r: []i32,
    predictor_buffer: []i32,

    pub fn init(allocator: Allocator, config: AlacConfig) ?AlacDecoder {
        const frame_len = config.frame_length;
        if (frame_len == 0 or frame_len > 65536) return null;

        const mix_l = allocator.alloc(i32, frame_len) catch return null;
        errdefer allocator.free(mix_l);
        const mix_r = allocator.alloc(i32, frame_len) catch return null;
        errdefer allocator.free(mix_r);
        const pred_buf = allocator.alloc(i32, frame_len) catch return null;
        errdefer allocator.free(pred_buf);

        return AlacDecoder{
            .config = config,
            .allocator = allocator,
            .mix_buffer_l = mix_l,
            .mix_buffer_r = mix_r,
            .predictor_buffer = pred_buf,
        };
    }

    pub fn deinit(self: *AlacDecoder) void {
        self.allocator.free(self.mix_buffer_l);
        self.allocator.free(self.mix_buffer_r);
        self.allocator.free(self.predictor_buffer);
    }

    /// Decode a single ALAC frame
    /// Returns number of samples decoded, or null on error
    pub fn decodeFrame(self: *AlacDecoder, frame_data: []const u8, pcm_out: []i32) ?u32 {
        var reader = BitReader.init(frame_data);

        // ALAC packet header (per Apple reference):
        // 3 bits: tag (element type - SCE=0, CPE=1, etc.)
        // 4 bits: elementInstanceTag
        // 12 bits: unusedHeader (must be 0)
        // 4 bits: headerByte containing:
        //   - bit 3: partialFrame
        //   - bits 2-1: bytesShifted
        //   - bit 0: escapeFlag

        _ = reader.readBits(3) orelse return null; // tag (element type)
        _ = reader.readBits(4) orelse return null; // elementInstanceTag
        const unused_header = reader.readBits(12) orelse return null;
        if (unused_header != 0) return null; // Must be zero

        const header_byte = reader.readBits(4) orelse return null;
        const partial_frame = (header_byte >> 3) & 1;
        _ = (header_byte >> 1) & 3; // bytes_shifted (used for 20/24/32 bit audio)
        const escape_flag = header_byte & 1;

        // Determine number of output samples
        var output_samples: u32 = self.config.frame_length;
        if (partial_frame != 0) {
            // Read 32-bit sample count (two 16-bit reads)
            const high = reader.readBits(16) orelse return null;
            const low = reader.readBits(16) orelse return null;
            output_samples = (high << 16) | low;
        }

        if (output_samples == 0 or output_samples > self.config.frame_length) {
            return null;
        }

        const num_channels = self.config.num_channels;

        if (escape_flag == 1) {
            // Uncompressed frame - raw PCM samples
            return self.decodeUncompressed(&reader, output_samples, pcm_out);
        }

        // Compressed frame - decode channels
        if (num_channels == 1) {
            // Mono
            if (!self.decodeChannel(&reader, output_samples, self.mix_buffer_l)) {
                return null;
            }
            // Copy to output
            for (0..output_samples) |i| {
                pcm_out[i] = self.mix_buffer_l[i];
            }
        } else if (num_channels == 2) {
            // Stereo with mid-side coding
            const mode_bits = reader.readBits(8) orelse return null;
            const mix_bits: u8 = @intCast((mode_bits >> 4) & 0x0F);
            const mix_res: u8 = @intCast(mode_bits & 0x0F);

            if (!self.decodeChannel(&reader, output_samples, self.mix_buffer_l)) {
                return null;
            }
            if (!self.decodeChannel(&reader, output_samples, self.mix_buffer_r)) {
                return null;
            }

            // Unmix stereo channels
            self.unmixStereo(output_samples, mix_bits, mix_res, pcm_out);
        } else {
            // Multi-channel not supported for validation
            return null;
        }

        return output_samples;
    }

    fn decodeUncompressed(self: *AlacDecoder, reader: *BitReader, samples: u32, pcm_out: []i32) ?u32 {
        const bits = self.config.bits_per_sample;
        const channels = self.config.num_channels;

        // Align to byte boundary
        reader.alignToByte();

        for (0..samples) |i| {
            for (0..channels) |c| {
                const sample_bits = reader.readBits(@intCast(bits)) orelse return null;
                // Sign extend
                const sample: i32 = signExtend(sample_bits, bits);
                pcm_out[i * channels + c] = sample;
            }
        }

        return samples;
    }

    fn decodeChannel(self: *AlacDecoder, reader: *BitReader, samples: u32, output: []i32) bool {
        // Read prediction type
        const pred_type_bits = reader.readBits(4) orelse return false;
        const pred_type: u4 = @intCast(pred_type_bits);

        // Read shift (extra bits)
        const extra_bits_raw = reader.readBits(4) orelse return false;
        const extra_bits: u4 = @intCast(extra_bits_raw);

        // Read Rice modifier
        const rice_modifier_raw = reader.readBits(3) orelse return false;
        const rice_modifier: u8 = @intCast(rice_modifier_raw);

        // Read prediction order
        const pred_order_raw = reader.readBits(5) orelse return false;
        const pred_order: u5 = @intCast(pred_order_raw);

        // Compute effective rice history multiplier (per FFmpeg: per_frame * config.pb / 4)
        const rice_hist_mult: u32 = @as(u32, rice_modifier) * @as(u32, self.config.pb) / 4;

        if (pred_type == 0) {
            // No prediction - decode residuals directly
            return self.decodeRiceResiduals(reader, samples, rice_hist_mult, extra_bits, output);
        } else if (pred_type == 1) {
            // FIR prediction
            if (pred_order > 31) return false;

            // Read prediction coefficients
            var coefs: [32]i16 = undefined;
            for (0..pred_order) |i| {
                const coef_bits = reader.readBits(16) orelse return false;
                coefs[i] = @bitCast(@as(u16, @intCast(coef_bits)));
            }

            // Decode residuals
            if (!self.decodeRiceResiduals(reader, samples, rice_hist_mult, extra_bits, self.predictor_buffer)) {
                return false;
            }

            // Apply prediction
            return self.applyPrediction(samples, pred_order, &coefs, output);
        }

        return false;
    }

    /// Decode ALAC-specific Rice/Golomb coded residuals.
    /// Based on FFmpeg's rice_decompress and Apple's ag_decode.
    fn decodeRiceResiduals(self: *AlacDecoder, reader: *BitReader, samples: u32, rice_hist_mult: u32, extra_bits: u4, output: []i32) bool {
        var history: u32 = @intCast(self.config.mb); // Initial history = mb (rice_initial_history)
        var sign_modifier: u32 = 0;
        const rice_limit: u32 = @intCast(self.config.kb);
        const bps: u32 = @intCast(self.config.bits_per_sample);

        var i: u32 = 0;
        while (i < samples) {
            // Calculate Rice parameter k = floor(log2((history >> 9) + 3))
            const k_arg: u32 = (history >> 9) + 3;
            var k: u32 = 31 - @as(u32, @clz(k_arg));
            k = @min(k, rice_limit);

            // Decode scalar value using ALAC-specific Rice variant
            var x = decodeScalar(reader, k, bps) orelse return false;

            // Apply sign modifier (from previous zero-run)
            x +%= sign_modifier;
            sign_modifier = 0;

            // Convert unsigned to signed: (x >> 1) ^ -(x & 1)
            const signed_val: i32 = @as(i32, @intCast(x >> 1)) ^ -@as(i32, @intCast(x & 1));

            // Apply extra bits shift if present
            if (extra_bits > 0) {
                const extra = reader.readBits(extra_bits) orelse return false;
                output[i] = (signed_val << extra_bits) | @as(i32, @intCast(extra));
            } else {
                output[i] = signed_val;
            }

            // Update history
            if (x > 0xFFFF) {
                history = 0xFFFF;
            } else {
                history +%= x * rice_hist_mult -% ((history * rice_hist_mult) >> 9);
            }

            // Zero-run detection: when history is small, check for run of zeros
            if ((history < 128) and (i + 1 < samples)) {
                // Calculate k for zero block using FFmpeg formula:
                // k = 7 - av_log2(history) + ((history + 16) >> 6)
                var zk: u32 = 0;
                if (history > 0) {
                    const log2_hist: u32 = 31 - @as(u32, @clz(history));
                    zk = 7 -| log2_hist;
                    zk += (history + 16) >> 6;
                } else {
                    // history == 0: av_log2(0) is undefined, but 7 - 0 + (16 >> 6) = 7
                    zk = 7 + ((0 + 16) >> 6);
                }
                zk = @min(zk, rice_limit);

                const block_size = decodeScalar(reader, zk, 16) orelse return false;

                if (block_size > 0) {
                    // Clamp to remaining samples
                    const max_block = samples - i - 1;
                    const actual_block = @min(block_size, max_block);
                    // Fill with zeros
                    const run_end = i + 1 + actual_block;
                    for (i + 1..run_end) |j| {
                        output[j] = 0;
                    }
                    i = run_end;
                }

                // sign_modifier = 1 when block_size <= 0xFFFF (includes block_size=0)
                if (block_size <= 0xFFFF) {
                    sign_modifier = 1;
                }
                history = 0;

                if (block_size > 0) continue;
            }

            i += 1;
        }

        return true;
    }

    /// ALAC-specific scalar decode (per FFmpeg's decode_scalar / Apple's dyn_get).
    /// Reads a unary prefix of 1-bits (max 9), then a binary suffix based on k.
    fn decodeScalar(reader: *BitReader, k: u32, bps: u32) ?u32 {
        // Read unary: count of consecutive 1-bits before a 0-bit, max 9
        var x: u32 = 0;
        while (x < 9) {
            const bit = reader.readBit() orelse return null;
            if (bit == 0) break;
            x += 1;
        }

        if (x > 8) {
            // Escape: read bps bits directly
            return reader.readBits(@intCast(bps));
        } else if (k != 1 and k > 0) {
            // ALAC-specific binary suffix encoding
            const extrabits = reader.peekBits(@intCast(k)) orelse return null;
            // x = x * (2^k - 1)
            x = (x << @intCast(k)) - x;
            if (extrabits > 1) {
                x += extrabits - 1;
                _ = reader.readBits(@intCast(k)) orelse return null; // consume k bits
            } else {
                // consume k-1 bits (leave last bit for next code)
                if (k > 1) {
                    _ = reader.readBits(@intCast(k - 1)) orelse return null;
                }
            }
        }
        // When k == 0 or k == 1: x is just the unary value
        return x;
    }

    fn applyPrediction(self: *AlacDecoder, samples: u32, order: u5, coefs: *const [32]i16, output: []i32) bool {
        // Copy first 'order' samples directly
        for (0..order) |i| {
            output[i] = self.predictor_buffer[i];
        }

        // Apply FIR filter
        for (order..samples) |i| {
            var sum: i64 = 0;
            for (0..order) |j| {
                sum += @as(i64, output[i - 1 - j]) * @as(i64, coefs[j]);
            }
            // Add residual and divide by 2^9
            output[i] = self.predictor_buffer[i] + @as(i32, @truncate(sum >> 9));
        }

        return true;
    }

    fn unmixStereo(self: *AlacDecoder, samples: u32, mix_bits: u8, mix_res: u8, pcm_out: []i32) void {
        for (0..samples) |i| {
            const l = self.mix_buffer_l[i];
            const r = self.mix_buffer_r[i];

            if (mix_res == 0) {
                // No mixing
                pcm_out[i * 2] = l;
                pcm_out[i * 2 + 1] = r;
            } else {
                // Mid-side to left-right
                // L = M + S, R = M - S (simplified)
                const m = l;
                const s = r;
                const shift: u5 = @intCast(mix_bits);
                pcm_out[i * 2] = m + ((s * @as(i32, mix_res)) >> shift);
                pcm_out[i * 2 + 1] = m - ((s * @as(i32, mix_res)) >> shift);
            }
        }
    }
};

/// Sign extend a value
fn signExtend(value: u32, bits: u8) i32 {
    if (bits == 0 or bits > 32) return 0;
    const shift: u5 = @intCast(32 - bits);
    return @as(i32, @bitCast(value << shift)) >> shift;
}

/// Validate ALAC audio from raw frames.
/// config_data: The 'alac' codec configuration from MP4 container
/// frames: Iterator or slice of frame data
pub fn validateAlacFrames(
    allocator: Allocator,
    config_data: []const u8,
    frames: []const []const u8,
    max_frames: u32,
) AlacDecodeResult {
    const config = AlacConfig.parse(config_data) orelse {
        return AlacDecodeResult.invalid("Invalid ALAC config", 0);
    };

    var decoder = AlacDecoder.init(allocator, config) orelse {
        return AlacDecodeResult.invalid("Failed to initialize decoder", 0);
    };
    defer decoder.deinit();

    const max_samples_per_frame = config.frame_length * config.num_channels;
    const pcm_buffer = allocator.alloc(i32, max_samples_per_frame) catch {
        return AlacDecodeResult.invalid("Memory allocation failed", 0);
    };
    defer allocator.free(pcm_buffer);

    var frames_decoded: u32 = 0;
    var total_samples: u64 = 0;

    for (frames) |frame| {
        if (frames_decoded >= max_frames) break;

        const samples = decoder.decodeFrame(frame, pcm_buffer) orelse {
            return AlacDecodeResult.invalid("Frame decode failed", frames_decoded);
        };

        frames_decoded += 1;
        total_samples += samples;
    }

    if (frames_decoded == 0) {
        return AlacDecodeResult.invalid("No frames decoded", 0);
    }

    return AlacDecodeResult.ok(
        frames_decoded,
        total_samples,
        config.num_channels,
        config.sample_rate,
        config.bits_per_sample,
    );
}

/// Validate ALAC audio from a buffer containing multiple frames.
/// This variant handles the common case of contiguous frame data.
pub fn validateAlacFromBuffer(
    allocator: Allocator,
    config_data: []const u8,
    frame_data: []const u8,
    frame_sizes: []const u32,
    max_frames: u32,
) AlacDecodeResult {
    const config = AlacConfig.parse(config_data) orelse {
        return AlacDecodeResult.invalid("Invalid ALAC config", 0);
    };

    var decoder = AlacDecoder.init(allocator, config) orelse {
        return AlacDecodeResult.invalid("Failed to initialize decoder", 0);
    };
    defer decoder.deinit();

    const max_samples_per_frame = config.frame_length * config.num_channels;
    const pcm_buffer = allocator.alloc(i32, max_samples_per_frame) catch {
        return AlacDecodeResult.invalid("Memory allocation failed", 0);
    };
    defer allocator.free(pcm_buffer);

    var frames_decoded: u32 = 0;
    var total_samples: u64 = 0;
    var offset: usize = 0;

    for (frame_sizes) |size| {
        if (frames_decoded >= max_frames) break;
        if (offset + size > frame_data.len) break;

        const frame = frame_data[offset .. offset + size];
        const samples = decoder.decodeFrame(frame, pcm_buffer) orelse {
            return AlacDecodeResult.invalid("Frame decode failed", frames_decoded);
        };

        frames_decoded += 1;
        total_samples += samples;
        offset += size;
    }

    if (frames_decoded == 0) {
        return AlacDecodeResult.invalid("No frames decoded", 0);
    }

    return AlacDecodeResult.ok(
        frames_decoded,
        total_samples,
        config.num_channels,
        config.sample_rate,
        config.bits_per_sample,
    );
}

// Tests
test "ALAC config parsing" {
    // Valid config (24 bytes)
    const config_data = [_]u8{
        0x00, 0x00, 0x10, 0x00, // frame_length = 4096
        0x00, // compatible_version
        0x10, // bits_per_sample = 16
        0x28, // pb = 40
        0x0A, // mb = 10
        0x0E, // kb = 14
        0x02, // num_channels = 2
        0x00, 0xFF, // max_run = 255
        0x00, 0x00, 0x00, 0x00, // max_frame_bytes
        0x00, 0x00, 0x00, 0x00, // avg_bit_rate
        0x00, 0x00, 0xAC, 0x44, // sample_rate = 44100
    };

    const config = AlacConfig.parse(&config_data).?;
    try std.testing.expectEqual(@as(u32, 4096), config.frame_length);
    try std.testing.expectEqual(@as(u8, 16), config.bits_per_sample);
    try std.testing.expectEqual(@as(u8, 2), config.num_channels);
    try std.testing.expectEqual(@as(u32, 44100), config.sample_rate);
}

test "ALAC config parsing rejects short data" {
    const short_data = [_]u8{ 0x00, 0x00, 0x10, 0x00 };
    try std.testing.expect(AlacConfig.parse(&short_data) == null);
}

test "BitReader basic operations" {
    const data = [_]u8{ 0b11010110, 0b10101001 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 0b1101), reader.readBits(4));
    try std.testing.expectEqual(@as(?u32, 0b0110), reader.readBits(4));
    try std.testing.expectEqual(@as(?u32, 0b1010), reader.readBits(4));
}

test "BitReader unary" {
    const data = [_]u8{ 0b00001000 }; // 4 zeros then 1
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(?u32, 4), reader.readUnaryMax(10));
}

test "sign extension" {
    try std.testing.expectEqual(@as(i32, -1), signExtend(0xFFFF, 16));
    try std.testing.expectEqual(@as(i32, -128), signExtend(0x80, 8));
    try std.testing.expectEqual(@as(i32, 127), signExtend(0x7F, 8));
    try std.testing.expectEqual(@as(i32, -1), signExtend(0xFFFFFFFF, 32));
}
