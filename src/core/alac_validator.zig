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

        // Frame header
        _ = reader.readBits(3) orelse return null; // unused
        const output_samples_raw = reader.readBits(12) orelse return null;

        // Special case: 12 bits all 1s means use config.frame_length
        const output_samples: u32 = if (output_samples_raw == 0xFFF)
            self.config.frame_length
        else
            output_samples_raw;

        if (output_samples == 0 or output_samples > self.config.frame_length) {
            return null;
        }

        _ = reader.readBits(1) orelse return null; // compatible version (0)

        const uncompressed_flag = reader.readBit() orelse return null;
        const num_channels = self.config.num_channels;

        if (uncompressed_flag == 1) {
            // Uncompressed frame - raw PCM samples
            return self.decodeUncompressed(&reader, output_samples, pcm_out);
        }

        // Compressed frame
        _ = reader.readBits(2) orelse return null; // element_type (ignored)
        _ = reader.readBits(4) orelse return null; // unused

        const has_size = reader.readBit() orelse return null;
        const has_verbatim_info = reader.readBit() orelse return null;

        // Read optional size field
        if (has_size == 1) {
            _ = reader.readBits(32) orelse return null; // output_bytes
        }

        // Read optional verbatim info (for version compatibility)
        if (has_verbatim_info == 1) {
            _ = reader.readBits(16) orelse return null;
        }

        // Decode channels
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

        if (pred_type == 0) {
            // No prediction - decode residuals directly
            return self.decodeRiceResiduals(reader, samples, rice_modifier, extra_bits, output);
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
            if (!self.decodeRiceResiduals(reader, samples, rice_modifier, extra_bits, self.predictor_buffer)) {
                return false;
            }

            // Apply prediction
            return self.applyPrediction(samples, pred_order, &coefs, output);
        }

        return false;
    }

    fn decodeRiceResiduals(self: *AlacDecoder, reader: *BitReader, samples: u32, k_modifier: u8, extra_bits: u4, output: []i32) bool {
        var history: u32 = @intCast(self.config.pb); // History starts at pb
        var sign_modifier: u32 = 0;

        var i: u32 = 0;
        while (i < samples) {
            // Calculate k from history
            var k: u32 = 31 - @clz(history >> 9) + @as(u32, k_modifier);
            if (k > 31) k = 31;

            // Read unary prefix (count of zeros)
            const q = reader.readUnaryMax(65535) orelse return false;

            // Read binary suffix
            var r: u32 = 0;
            if (k > 0) {
                r = reader.readBits(@intCast(k)) orelse return false;
            }

            // Combine
            var value: u32 = (q << @intCast(k)) + r;

            // Apply sign modifier
            value +%= sign_modifier;
            sign_modifier = 0;

            // Handle escape code
            if (value == 0xFFFF) {
                // Read extra bits directly
                const extra_val = reader.readBits(@intCast(self.config.bits_per_sample)) orelse return false;
                output[i] = signExtend(extra_val, self.config.bits_per_sample);
            } else {
                // Convert unsigned to signed (low bit is sign)
                const signed: i32 = if ((value & 1) == 1)
                    -@as(i32, @intCast((value + 1) >> 1))
                else
                    @intCast(value >> 1);

                // Add extra bits if present
                if (extra_bits > 0) {
                    const extra = reader.readBits(extra_bits) orelse return false;
                    output[i] = (signed << extra_bits) | @as(i32, @intCast(extra));
                } else {
                    output[i] = signed;
                }
            }

            // Update history
            if (value > 0xFFFF) {
                history = 0xFFFF;
            } else {
                history +%= (value * @as(u32, self.config.pb)) -% ((history * @as(u32, self.config.pb)) >> 9);
            }

            // Check for run-length encoding
            if ((history < 128) and (i + 1 < samples)) {
                // Potential RLE - read run length
                var run_k: u32 = 31 - @clz((@as(u32, self.config.max_run) -| 1) >> 9);
                if (run_k > 31) run_k = 31;
                const run_q = reader.readUnaryMax(self.config.max_run) orelse return false;
                var run_r: u32 = 0;
                if (run_k > 0) {
                    run_r = reader.readBits(@intCast(run_k)) orelse return false;
                }
                const run_length = (run_q << @intCast(run_k)) + run_r;

                if (run_length > 0) {
                    // Fill with zeros
                    const run_end = @min(i + 1 + run_length, samples);
                    for (i + 1..run_end) |j| {
                        output[j] = 0;
                    }
                    i = @intCast(run_end);
                    history = 0;
                    sign_modifier = 1;
                    continue;
                }
            }

            i += 1;
        }

        return true;
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
