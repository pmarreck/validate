// FLAC decoder for MD5 verification
// Implements enough of the FLAC spec to decode audio and verify the MD5 hash.
// Reference: https://xiph.org/flac/format.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const Md5 = std.crypto.hash.Md5;

pub const FlacError = error{
    InvalidSync,
    InvalidBlockSize,
    InvalidSampleRate,
    InvalidChannelAssignment,
    InvalidBitsPerSample,
    InvalidSubframeType,
    InvalidFixedOrder,
    InvalidLpcOrder,
    InvalidRicePartition,
    InvalidUtf8,
    CrcMismatch,
    Truncated,
    OutOfMemory,
    Unsupported,
};

pub const StreamInfo = struct {
    min_block_size: u16,
    max_block_size: u16,
    min_frame_size: u24,
    max_frame_size: u24,
    sample_rate: u32,
    channels: u8,
    bits_per_sample: u8,
    total_samples: u64,
    md5: [16]u8,
};

pub const FrameHeader = struct {
    blocking_strategy: enum { fixed, variable },
    block_size: u32,
    sample_rate: u32,
    channel_assignment: ChannelAssignment,
    bits_per_sample: u8,
    frame_or_sample_number: u64,
};

pub const ChannelAssignment = enum(u4) {
    independent_1 = 0,
    independent_2 = 1,
    independent_3 = 2,
    independent_4 = 3,
    independent_5 = 4,
    independent_6 = 5,
    independent_7 = 6,
    independent_8 = 7,
    left_side = 8,
    side_right = 9,
    mid_side = 10,
    _,

    pub fn numChannels(self: ChannelAssignment) u8 {
        return switch (self) {
            .left_side, .side_right, .mid_side => 2,
            else => @intFromEnum(self) + 1,
        };
    }
};

/// Bit reader for reading variable-length fields from FLAC stream
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0, // 0-7, bits remaining in current byte

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn readBits(self: *BitReader, comptime n: comptime_int) FlacError!std.meta.Int(.unsigned, n) {
        // Use a wider type for accumulation to avoid shift overflow
        const Wide = if (n <= 32) u64 else u128;
        var result: Wide = 0;
        var bits_needed: u8 = n;

        while (bits_needed > 0) {
            if (self.byte_pos >= self.data.len) return FlacError.Truncated;

            const bits_available = @as(u8, 8) - @as(u8, self.bit_pos);
            const bits_to_read = @min(bits_available, bits_needed);

            // Extract bits from current byte
            const shift = bits_available - bits_to_read;
            // Use u16 for mask to avoid overflow when bits_to_read == 8
            const mask: u8 = @truncate((@as(u16, 1) << @intCast(bits_to_read)) - 1);
            const bits: Wide = @intCast((self.data[self.byte_pos] >> @intCast(shift)) & mask);

            result = (result << @intCast(bits_to_read)) | bits;
            bits_needed -= bits_to_read;

            // Update position - handle full byte reads without overflow
            const new_bit_pos = @as(u8, self.bit_pos) + bits_to_read;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = @intCast(new_bit_pos - 8);
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
        }

        return @intCast(result);
    }

    pub fn readBitsDynamic(self: *BitReader, n: u8) FlacError!u32 {
        var result: u32 = 0;
        var bits_needed = n;

        while (bits_needed > 0) {
            if (self.byte_pos >= self.data.len) return FlacError.Truncated;

            const bits_available = @as(u8, 8) - @as(u8, self.bit_pos);
            const bits_to_read = @min(bits_available, bits_needed);

            const shift = bits_available - bits_to_read;
            // Use u16 for mask to avoid overflow when bits_to_read == 8
            const mask: u8 = @truncate((@as(u16, 1) << @intCast(bits_to_read)) - 1);
            const bits: u32 = @intCast((self.data[self.byte_pos] >> @intCast(shift)) & mask);

            result = (result << @intCast(bits_to_read)) | bits;
            bits_needed -= bits_to_read;

            // Update position - handle full byte reads without overflow
            const new_bit_pos = @as(u8, self.bit_pos) + bits_to_read;
            if (new_bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = @intCast(new_bit_pos - 8);
            } else {
                self.bit_pos = @intCast(new_bit_pos);
            }
        }

        return result;
    }

    pub fn readSignedBits(self: *BitReader, n: u8) FlacError!i32 {
        const unsigned = try self.readBitsDynamic(n);
        // Sign extend
        if (n == 0) return 0;
        const sign_bit = @as(u32, 1) << @intCast(n - 1);
        if ((unsigned & sign_bit) != 0) {
            // Negative: sign extend
            const mask = @as(u32, 0xFFFFFFFF) << @intCast(n);
            return @bitCast(unsigned | mask);
        }
        return @intCast(unsigned);
    }

    /// Read unary coded value (count of 1s before a 0)
    /// Read unary-coded value (FLAC format: count 0-bits until 1-bit)
    pub fn readUnary(self: *BitReader) FlacError!u32 {
        var count: u32 = 0;
        while (true) {
            const bit = try self.readBits(1);
            if (bit == 1) return count; // Stop on 1-bit
            count += 1;
            if (count > 32) return FlacError.InvalidRicePartition;
        }
    }

    /// Read UTF-8 coded value (used for frame/sample numbers)
    pub fn readUtf8(self: *BitReader) FlacError!u64 {
        const first = try self.readBits(8);

        if ((first & 0x80) == 0) {
            return first;
        }

        var num_bytes: u8 = 0;
        var mask: u8 = 0x40;
        while ((first & mask) != 0) : (mask >>= 1) {
            num_bytes += 1;
            if (num_bytes > 6) return FlacError.InvalidUtf8;
        }

        var result: u64 = first & (mask - 1);
        for (0..num_bytes) |_| {
            const cont = try self.readBits(8);
            if ((cont & 0xC0) != 0x80) return FlacError.InvalidUtf8;
            result = (result << 6) | (cont & 0x3F);
        }

        return result;
    }

    pub fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }

    pub fn bytesConsumed(self: *const BitReader) usize {
        return if (self.bit_pos == 0) self.byte_pos else self.byte_pos + 1;
    }
};

/// FLAC decoder that computes MD5 of decoded audio
pub const FlacDecoder = struct {
    allocator: Allocator,
    stream_info: ?StreamInfo = null,
    md5: Md5 = Md5.init(.{}),
    samples_decoded: u64 = 0,
    bytes_hashed: u64 = 0,
    frames_decoded: u32 = 0,

    // Working buffers
    subframe_buffer: []i32 = &.{},
    output_buffer: []i32 = &.{}, // Interleaved output

    pub fn init(allocator: Allocator) FlacDecoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FlacDecoder) void {
        if (self.subframe_buffer.len > 0) {
            self.allocator.free(self.subframe_buffer);
        }
        if (self.output_buffer.len > 0) {
            self.allocator.free(self.output_buffer);
        }
    }

    /// Parse STREAMINFO metadata block
    pub fn parseStreamInfo(self: *FlacDecoder, data: []const u8) FlacError!void {
        if (data.len < 34) return FlacError.Truncated;

        self.stream_info = StreamInfo{
            .min_block_size = std.mem.readInt(u16, data[0..2], .big),
            .max_block_size = std.mem.readInt(u16, data[2..4], .big),
            .min_frame_size = @intCast((@as(u32, data[4]) << 16) | (@as(u32, data[5]) << 8) | data[6]),
            .max_frame_size = @intCast((@as(u32, data[7]) << 16) | (@as(u32, data[8]) << 8) | data[9]),
            .sample_rate = (@as(u32, data[10]) << 12) | (@as(u32, data[11]) << 4) | (data[12] >> 4),
            .channels = ((data[12] >> 1) & 0x7) + 1,
            .bits_per_sample = (((data[12] & 1) << 4) | (data[13] >> 4)) + 1,
            .total_samples = (@as(u64, data[13] & 0xF) << 32) |
                (@as(u64, data[14]) << 24) | (@as(u64, data[15]) << 16) |
                (@as(u64, data[16]) << 8) | data[17],
            .md5 = data[18..34].*,
        };
    }

    /// Decode a single frame and update MD5
    pub fn decodeFrame(self: *FlacDecoder, frame_data: []const u8) FlacError!usize {
        var reader = BitReader.init(frame_data);

        // Parse frame header
        const header = try self.parseFrameHeader(&reader);

        const stream_info = self.stream_info orelse return FlacError.Truncated;
        const channels = header.channel_assignment.numChannels();
        const bps = header.bits_per_sample;

        // Ensure buffers are large enough
        const needed_size = header.block_size * channels;
        if (self.subframe_buffer.len < header.block_size) {
            if (self.subframe_buffer.len > 0) {
                self.allocator.free(self.subframe_buffer);
            }
            self.subframe_buffer = self.allocator.alloc(i32, header.block_size) catch return FlacError.OutOfMemory;
        }
        if (self.output_buffer.len < needed_size) {
            if (self.output_buffer.len > 0) {
                self.allocator.free(self.output_buffer);
            }
            self.output_buffer = self.allocator.alloc(i32, needed_size) catch return FlacError.OutOfMemory;
        }

        // Decode subframes for each channel
        var channel_data: [8][]i32 = undefined;
        for (0..channels) |ch| {
            // Adjust bits per sample for side channel
            var subframe_bps = bps;
            if (header.channel_assignment == .left_side and ch == 1) {
                subframe_bps += 1; // Side channel has +1 bit
            } else if (header.channel_assignment == .side_right and ch == 0) {
                subframe_bps += 1;
            } else if (header.channel_assignment == .mid_side and ch == 1) {
                subframe_bps += 1;
            }

            try self.decodeSubframe(&reader, header.block_size, subframe_bps);
            channel_data[ch] = self.subframe_buffer[0..header.block_size];

            // Copy to output buffer position for this channel
            for (0..header.block_size) |i| {
                self.output_buffer[i * channels + ch] = self.subframe_buffer[i];
            }
        }

        // Apply channel decorrelation
        switch (header.channel_assignment) {
            .left_side => {
                // Left, Side -> Left, Right where Right = Left - Side
                for (0..header.block_size) |i| {
                    const left = self.output_buffer[i * 2];
                    const side = self.output_buffer[i * 2 + 1];
                    self.output_buffer[i * 2 + 1] = left - side;
                }
            },
            .side_right => {
                // Side, Right -> Left, Right where Left = Side + Right
                for (0..header.block_size) |i| {
                    const side = self.output_buffer[i * 2];
                    const right = self.output_buffer[i * 2 + 1];
                    self.output_buffer[i * 2] = side + right;
                }
            },
            .mid_side => {
                // Mid, Side -> Left, Right
                // Left = (Mid + Side) / 2, Right = (Mid - Side) / 2
                // But FLAC uses: Mid = (Left + Right), Side = Left - Right
                // So: Left = (Mid + Side + 1) >> 1, Right = (Mid - Side) >> 1
                for (0..header.block_size) |i| {
                    const mid = self.output_buffer[i * 2];
                    const side = self.output_buffer[i * 2 + 1];
                    // Proper mid/side decoding
                    const mid2 = mid << 1;
                    self.output_buffer[i * 2] = (mid2 | (side & 1)) +% side >> 1;
                    self.output_buffer[i * 2 + 1] = (mid2 | (side & 1)) -% side >> 1;
                }
            },
            else => {}, // Independent channels, no decorrelation needed
        }

        // Update MD5 with decoded samples
        // FLAC MD5 is computed over samples in signed little-endian format
        const bytes_per_sample = (stream_info.bits_per_sample + 7) / 8;
        var sample_bytes: [4]u8 = undefined;

        for (0..header.block_size * channels) |i| {
            const sample = self.output_buffer[i];
            // Convert to little-endian bytes
            const unsigned: u32 = @bitCast(sample);
            sample_bytes[0] = @truncate(unsigned);
            sample_bytes[1] = @truncate(unsigned >> 8);
            sample_bytes[2] = @truncate(unsigned >> 16);
            sample_bytes[3] = @truncate(unsigned >> 24);

            self.md5.update(sample_bytes[0..bytes_per_sample]);
            self.bytes_hashed += bytes_per_sample;
        }

        self.samples_decoded += header.block_size;
        self.frames_decoded += 1;

        // Align to byte boundary and skip CRC-16
        reader.alignToByte();
        _ = try reader.readBits(16); // CRC-16 (we could verify this)

        return reader.bytesConsumed();
    }

    fn parseFrameHeader(self: *FlacDecoder, reader: *BitReader) FlacError!FrameHeader {
        _ = self;

        // Sync code: 14 bits, must be 0x3FFE
        const sync = try reader.readBits(14);
        if (sync != 0x3FFE) return FlacError.InvalidSync;

        // Reserved bit
        _ = try reader.readBits(1);

        // Blocking strategy (0 = fixed, 1 = variable)
        const blocking_strategy_bit = try reader.readBits(1);
        const blocking_strategy: @TypeOf(@as(FrameHeader, undefined).blocking_strategy) = if (blocking_strategy_bit == 0) .fixed else .variable;

        // Block size (4 bits)
        const block_size_code = try reader.readBits(4);

        // Sample rate (4 bits)
        const sample_rate_code = try reader.readBits(4);

        // Channel assignment (4 bits)
        const channel_code = try reader.readBits(4);
        const channel_assignment: ChannelAssignment = @enumFromInt(channel_code);
        if (channel_code > 10) return FlacError.InvalidChannelAssignment;

        // Sample size (3 bits)
        const sample_size_code = try reader.readBits(3);

        // Reserved bit
        _ = try reader.readBits(1);

        // Frame/sample number (UTF-8 coded)
        const frame_or_sample_number = try reader.readUtf8();

        // Block size (may need extra bytes)
        const block_size: u32 = switch (block_size_code) {
            0 => return FlacError.InvalidBlockSize,
            1 => 192,
            2...5 => |n| @as(u32, 576) << @intCast(n - 2),
            6 => try reader.readBits(8) + 1,
            7 => try reader.readBits(16) + 1,
            8...15 => |n| @as(u32, 256) << @intCast(n - 8),
        };

        // Sample rate (may need extra bytes)
        const sample_rate: u32 = switch (sample_rate_code) {
            0 => 0, // Get from STREAMINFO
            1 => 88200,
            2 => 176400,
            3 => 192000,
            4 => 8000,
            5 => 16000,
            6 => 22050,
            7 => 24000,
            8 => 32000,
            9 => 44100,
            10 => 48000,
            11 => 96000,
            12 => @as(u32, try reader.readBits(8)) * 1000,
            13 => try reader.readBits(16),
            14 => @as(u32, try reader.readBits(16)) * 10,
            15 => return FlacError.InvalidSampleRate,
        };

        // Bits per sample
        const bits_per_sample: u8 = switch (sample_size_code) {
            0 => 0, // Get from STREAMINFO
            1 => 8,
            2 => 12,
            3 => return FlacError.InvalidBitsPerSample,
            4 => 16,
            5 => 20,
            6 => 24,
            7 => 32,
        };

        // CRC-8 of header
        _ = try reader.readBits(8);

        return FrameHeader{
            .blocking_strategy = blocking_strategy,
            .block_size = block_size,
            .sample_rate = sample_rate,
            .channel_assignment = channel_assignment,
            .bits_per_sample = bits_per_sample,
            .frame_or_sample_number = frame_or_sample_number,
        };
    }

    fn decodeSubframe(self: *FlacDecoder, reader: *BitReader, block_size: u32, bps: u8) FlacError!void {
        // Zero bit (padding)
        _ = try reader.readBits(1);

        // Subframe type (6 bits)
        const subframe_type = try reader.readBits(6);

        // Wasted bits per sample flag
        const has_wasted_bits = try reader.readBits(1);
        var wasted_bits: u8 = 0;
        if (has_wasted_bits == 1) {
            // Unary coded wasted bits
            wasted_bits = @intCast(try reader.readUnary() + 1);
        }

        const effective_bps = bps - wasted_bits;

        if (subframe_type == 0) {
            // CONSTANT
            const value = try reader.readSignedBits(effective_bps);
            for (self.subframe_buffer[0..block_size]) |*s| {
                s.* = value;
            }
        } else if (subframe_type == 1) {
            // VERBATIM
            for (self.subframe_buffer[0..block_size]) |*s| {
                s.* = try reader.readSignedBits(effective_bps);
            }
        } else if (subframe_type >= 8 and subframe_type <= 12) {
            // FIXED prediction
            const order: u8 = @intCast(subframe_type - 8);
            try self.decodeFixedSubframe(reader, block_size, effective_bps, order);
        } else if (subframe_type >= 32) {
            // LPC
            const order: u8 = @intCast(subframe_type - 31);
            try self.decodeLpcSubframe(reader, block_size, effective_bps, order);
        } else {
            return FlacError.InvalidSubframeType;
        }

        // Apply wasted bits
        if (wasted_bits > 0) {
            for (self.subframe_buffer[0..block_size]) |*s| {
                s.* <<= @intCast(wasted_bits);
            }
        }
    }

    fn decodeFixedSubframe(self: *FlacDecoder, reader: *BitReader, block_size: u32, bps: u8, order: u8) FlacError!void {
        // Read warm-up samples
        for (0..order) |i| {
            self.subframe_buffer[i] = try reader.readSignedBits(bps);
        }

        // Decode residual
        try self.decodeResidual(reader, block_size, order);

        // Apply fixed prediction
        const coeffs: [5][4]i32 = .{
            .{ 0, 0, 0, 0 }, // Order 0: no prediction
            .{ 1, 0, 0, 0 }, // Order 1: s[n] = s[n-1]
            .{ 2, -1, 0, 0 }, // Order 2: s[n] = 2*s[n-1] - s[n-2]
            .{ 3, -3, 1, 0 }, // Order 3
            .{ 4, -6, 4, -1 }, // Order 4
        };

        for (order..block_size) |i| {
            var prediction: i64 = 0;
            for (0..order) |j| {
                prediction += @as(i64, coeffs[order][j]) * @as(i64, self.subframe_buffer[i - 1 - j]);
            }
            self.subframe_buffer[i] +%= @intCast(prediction);
        }
    }

    fn decodeLpcSubframe(self: *FlacDecoder, reader: *BitReader, block_size: u32, bps: u8, order: u8) FlacError!void {
        // Read warm-up samples
        for (0..order) |i| {
            self.subframe_buffer[i] = try reader.readSignedBits(bps);
        }

        // Quantized linear predictor coefficient precision (4 bits)
        const precision = try reader.readBits(4);
        if (precision == 15) return FlacError.InvalidLpcOrder;
        const coeff_precision: u8 = precision + 1;

        // Quantized linear predictor coefficient shift (5 bits, signed)
        const shift_raw = try reader.readBits(5);
        const shift: i8 = if ((shift_raw & 0x10) != 0)
            @bitCast(@as(u8, @intCast(shift_raw)) | 0xE0)
        else
            @intCast(shift_raw);

        // Read LPC coefficients
        var coefficients: [32]i32 = undefined;
        for (0..order) |i| {
            coefficients[i] = try reader.readSignedBits(coeff_precision);
        }

        // Decode residual
        try self.decodeResidual(reader, block_size, order);

        // Apply LPC prediction
        for (order..block_size) |i| {
            var prediction: i64 = 0;
            for (0..order) |j| {
                prediction += @as(i64, coefficients[j]) * @as(i64, self.subframe_buffer[i - 1 - j]);
            }

            if (shift >= 0) {
                self.subframe_buffer[i] +%= @intCast(prediction >> @intCast(shift));
            } else {
                self.subframe_buffer[i] +%= @intCast(prediction << @intCast(-shift));
            }
        }
    }

    fn decodeResidual(self: *FlacDecoder, reader: *BitReader, block_size: u32, predictor_order: u8) FlacError!void {
        // Coding method (2 bits)
        const coding_method = try reader.readBits(2);
        if (coding_method > 1) return FlacError.InvalidRicePartition;

        // Partition order (4 bits)
        const partition_order = try reader.readBits(4);
        const num_partitions: u32 = @as(u32, 1) << @intCast(partition_order);

        var sample_idx: u32 = predictor_order;

        for (0..num_partitions) |partition| {
            // Rice parameter
            const rice_param = if (coding_method == 0)
                try reader.readBits(4)
            else
                try reader.readBits(5);

            // Number of samples in this partition
            const num_samples: u32 = if (partition == 0)
                (block_size >> @intCast(partition_order)) - predictor_order
            else
                block_size >> @intCast(partition_order);

            if (rice_param == (if (coding_method == 0) @as(u32, 15) else @as(u32, 31))) {
                // Escape code: unencoded samples
                const escape_bits = try reader.readBits(5);
                for (0..num_samples) |_| {
                    self.subframe_buffer[sample_idx] = try reader.readSignedBits(@intCast(escape_bits));
                    sample_idx += 1;
                }
            } else {
                // Rice coded samples
                for (0..num_samples) |_| {
                    const q = try reader.readUnary();
                    const r = try reader.readBitsDynamic(@intCast(rice_param));
                    const unsigned = (q << @intCast(rice_param)) | r;
                    // Zig-zag decode
                    const value: i32 = if ((unsigned & 1) == 1)
                        -@as(i32, @intCast((unsigned + 1) >> 1))
                    else
                        @intCast(unsigned >> 1);

                    self.subframe_buffer[sample_idx] = value;
                    sample_idx += 1;
                }
            }
        }
    }

    /// Get the final MD5 hash
    pub fn finalize(self: *FlacDecoder) [16]u8 {
        var result: [16]u8 = undefined;
        self.md5.final(&result);
        return result;
    }

    /// Check if computed MD5 matches stored MD5
    pub fn verifyMd5(self: *FlacDecoder) bool {
        const stream_info = self.stream_info orelse return false;
        const computed = self.finalize();
        return std.mem.eql(u8, &computed, &stream_info.md5);
    }
};

/// Decode a FLAC file and verify its MD5 hash.
/// Returns true if the MD5 matches, false if it doesn't, or error.
pub fn verifyFlacMd5(allocator: Allocator, file_path: []const u8) FlacError!bool {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return FlacError.Truncated;
    defer file.close();

    // Read entire file into memory for simplicity
    // (For very large files, we'd want streaming, but this works for typical FLAC files)
    const file_size = file.getEndPos() catch return FlacError.Truncated;
    if (file_size > 1024 * 1024 * 1024) return FlacError.Unsupported; // 1GB limit

    const data = allocator.alloc(u8, @intCast(file_size)) catch return FlacError.OutOfMemory;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return FlacError.Truncated;
    if (bytes_read < 42) return FlacError.Truncated; // Minimum: magic + streaminfo header + streaminfo

    // Verify magic
    if (!std.mem.eql(u8, data[0..4], "fLaC")) return FlacError.InvalidSync;

    var decoder = FlacDecoder.init(allocator);
    defer decoder.deinit();

    // Parse metadata blocks
    var pos: usize = 4;
    while (pos + 4 <= bytes_read) {
        const is_last = (data[pos] & 0x80) != 0;
        const block_type = data[pos] & 0x7F;
        const block_size = (@as(u32, data[pos + 1]) << 16) |
            (@as(u32, data[pos + 2]) << 8) | data[pos + 3];
        pos += 4;

        if (pos + block_size > bytes_read) return FlacError.Truncated;

        if (block_type == 0) {
            // STREAMINFO
            try decoder.parseStreamInfo(data[pos..][0..block_size]);
        }
        // Skip other metadata blocks

        pos += block_size;
        if (is_last) break;
    }

    // Check if MD5 is all zeros (indicates no MD5 was stored)
    if (decoder.stream_info) |info| {
        var all_zeros = true;
        for (info.md5) |b| {
            if (b != 0) {
                all_zeros = false;
                break;
            }
        }
        if (all_zeros) {
            // No MD5 to verify
            return true; // Consider it valid (can't verify)
        }
    } else {
        return FlacError.Truncated;
    }

    // Decode all frames
    while (pos + 2 <= bytes_read) {
        // Look for frame sync
        if (data[pos] == 0xFF and (data[pos + 1] & 0xFC) == 0xF8) {
            // Found frame sync, try to decode
            const frame_data = data[pos..bytes_read];
            const consumed = decoder.decodeFrame(frame_data) catch |err| {
                // If we hit end of file, that's OK
                if (err == FlacError.Truncated and decoder.samples_decoded > 0) {
                    break;
                }
                return err;
            };
            pos += consumed;
        } else {
            pos += 1;
        }
    }

    return decoder.verifyMd5();
}

// Tests
test "BitReader basic operations" {
    const data = [_]u8{ 0b10110100, 0b11000010 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(u4, 0b1011), try reader.readBits(4));
    try std.testing.expectEqual(@as(u4, 0b0100), try reader.readBits(4));
    try std.testing.expectEqual(@as(u8, 0b11000010), try reader.readBits(8));
}

test "BitReader unary" {
    // FLAC unary: count 0-bits until 1-bit
    // 00001... = 4 zeros before one
    const data = [_]u8{0b00001000};
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(u32, 4), try reader.readUnary());

    // Test zero: 1... = 0 zeros before one
    const data2 = [_]u8{0b10000000};
    var reader2 = BitReader.init(&data2);
    try std.testing.expectEqual(@as(u32, 0), try reader2.readUnary());
}

test "BitReader UTF-8 single byte" {
    const data = [_]u8{0x7F};
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0x7F), try reader.readUtf8());
}

test "BitReader UTF-8 multi byte" {
    // 0xC2 0xA9 = © (U+00A9)
    const data = [_]u8{ 0xC2, 0xA9 };
    var reader = BitReader.init(&data);
    try std.testing.expectEqual(@as(u64, 0xA9), try reader.readUtf8());
}
