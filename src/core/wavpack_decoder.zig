//! WavPack Decoder (Pure Zig)
//!
//! Deep validation decoder for WavPack lossless audio.
//! WavPack uses CRC32 for block integrity and can optionally store MD5 of source audio.
//!
//! WavPack format:
//! - Files contain one or more blocks
//! - Each block starts with "wvpk" signature
//! - Block header (32 bytes) followed by sub-blocks
//! - CRC32 covers the decoded audio samples
//! - Optional MD5 metadata sub-block for full file verification
//!
//! Reference: WavPack Technical Specification (wavpack.com)

const std = @import("std");
const errmsg = @import("error_messages.zig");

// ============================================================================
// Constants
// ============================================================================

/// WavPack block signature
pub const WAVPACK_SIGNATURE = "wvpk";

/// Sub-block IDs
pub const SubBlockId = enum(u8) {
    dummy = 0x00,
    wave_header = 0x01,
    wave_trailer = 0x02,
    wave_channel_mask = 0x03,
    channel_info = 0x04,
    decorrelation_terms = 0x05,
    decorrelation_weights = 0x06,
    decorrelation_samples = 0x07,
    entropy_vars = 0x08,
    hybrid_profile = 0x09,
    shaping_weights = 0x0A,
    float_info = 0x0B,
    int32_info = 0x0C,
    bitstream = 0x0D,
    bitstream_long = 0x0E,
    multichannel_config = 0x0F,
    channel_identities = 0x10,
    sample_rate = 0x11,
    alt_header = 0x12,
    alt_trailer = 0x13,
    alt_extension = 0x14,
    md5_checksum = 0x26, // MD5 of original audio
    _,
};

/// Block flags bit positions
pub const BlockFlags = struct {
    pub const BYTES_PER_SAMPLE_MASK: u32 = 0x03; // bits 0-1
    pub const MONO_FLAG: u32 = 0x04; // bit 2
    pub const HYBRID_FLAG: u32 = 0x08; // bit 3
    pub const JOINT_STEREO: u32 = 0x10; // bit 4
    pub const CROSS_DECORR: u32 = 0x20; // bit 5
    pub const HYBRID_SHAPE: u32 = 0x40; // bit 6
    pub const FLOAT_DATA: u32 = 0x80; // bit 7
    pub const INT32_DATA: u32 = 0x100; // bit 8
    pub const HYBRID_BITRATE: u32 = 0x200; // bit 9
    pub const HYBRID_BALANCE: u32 = 0x400; // bit 10
    pub const INITIAL_BLOCK: u32 = 0x800; // bit 11
    pub const FINAL_BLOCK: u32 = 0x1000; // bit 12
    pub const LEFT_SHIFT_MASK: u32 = 0x3E000; // bits 13-17
    pub const MAX_MAG_MASK: u32 = 0x7C0000; // bits 18-22
    pub const SAMPLE_RATE_MASK: u32 = 0x7800000; // bits 23-26
    pub const FALSE_STEREO: u32 = 0x40000000; // bit 30
    pub const DSD_FLAG: u32 = 0x80000000; // bit 31
};

/// Standard sample rates
pub const SAMPLE_RATES = [_]u32{
    6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000,
    32000, 44100, 48000, 64000, 88200, 96000, 192000, 0,
};

// ============================================================================
// Types
// ============================================================================

/// WavPack block header (32 bytes)
pub const BlockHeader = struct {
    signature: [4]u8, // "wvpk"
    block_size: u32, // Size of block minus 8 bytes
    version: u16, // Typically 0x402 to 0x410
    track_number: u8,
    index_flags: u8,
    total_samples: u32, // Total samples in file (0 = unknown)
    block_index: u32, // Sample index of first sample in block
    block_samples: u32, // Number of samples in this block
    flags: u32, // Various encoding flags
    crc: u32, // CRC of decoded audio samples

    pub fn getBytesPerSample(self: BlockHeader) u2 {
        return @intCast(self.flags & BlockFlags.BYTES_PER_SAMPLE_MASK);
    }

    pub fn isMono(self: BlockHeader) bool {
        return (self.flags & BlockFlags.MONO_FLAG) != 0;
    }

    pub fn isHybrid(self: BlockHeader) bool {
        return (self.flags & BlockFlags.HYBRID_FLAG) != 0;
    }

    pub fn isInitialBlock(self: BlockHeader) bool {
        return (self.flags & BlockFlags.INITIAL_BLOCK) != 0;
    }

    pub fn isFinalBlock(self: BlockHeader) bool {
        return (self.flags & BlockFlags.FINAL_BLOCK) != 0;
    }

    pub fn getSampleRateIndex(self: BlockHeader) u4 {
        return @intCast((self.flags & BlockFlags.SAMPLE_RATE_MASK) >> 23);
    }

    pub fn getSampleRate(self: BlockHeader) u32 {
        const index = self.getSampleRateIndex();
        if (index < SAMPLE_RATES.len) {
            return SAMPLE_RATES[index];
        }
        return 0;
    }
};

/// Sub-block header
pub const SubBlock = struct {
    id: u8, // Sub-block ID (lower 5 bits) + flags
    word_size: u32, // Size in 16-bit words
    data: []const u8,

    pub fn getId(self: SubBlock) SubBlockId {
        return @enumFromInt(self.id & 0x1F);
    }

    pub fn isOddSize(self: SubBlock) bool {
        return (self.id & 0x40) != 0;
    }

    pub fn isLargeSize(self: SubBlock) bool {
        return (self.id & 0x80) != 0;
    }
};

/// Deep validation result
pub const WavPackDeepValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    blocks_validated: u32,
    samples_validated: u64,
    has_md5: bool,
    md5_verified: bool, // If MD5 present and matches
    channels: u8,
    sample_rate: u32,
    bits_per_sample: u8,

    pub fn ok(blocks: u32, samples: u64, md5: bool, md5_ok: bool, ch: u8, sr: u32, bps: u8) WavPackDeepValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .blocks_validated = blocks,
            .samples_validated = samples,
            .has_md5 = md5,
            .md5_verified = md5_ok,
            .channels = ch,
            .sample_rate = sr,
            .bits_per_sample = bps,
        };
    }

    pub fn invalid(msg: []const u8) WavPackDeepValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .blocks_validated = 0,
            .samples_validated = 0,
            .has_md5 = false,
            .md5_verified = false,
            .channels = 0,
            .sample_rate = 0,
            .bits_per_sample = 0,
        };
    }
};

// ============================================================================
// Block Parsing
// ============================================================================

/// Parse WavPack block header
pub fn parseBlockHeader(data: []const u8) ?BlockHeader {
    if (data.len < 32) return null;

    // Check signature
    if (!std.mem.eql(u8, data[0..4], WAVPACK_SIGNATURE)) return null;

    return BlockHeader{
        .signature = data[0..4].*,
        .block_size = std.mem.readInt(u32, data[4..8], .little),
        .version = std.mem.readInt(u16, data[8..10], .little),
        .track_number = data[10],
        .index_flags = data[11],
        .total_samples = std.mem.readInt(u32, data[12..16], .little),
        .block_index = std.mem.readInt(u32, data[16..20], .little),
        .block_samples = std.mem.readInt(u32, data[20..24], .little),
        .flags = std.mem.readInt(u32, data[24..28], .little),
        .crc = std.mem.readInt(u32, data[28..32], .little),
    };
}

/// Parse sub-block header
pub fn parseSubBlock(data: []const u8) ?SubBlock {
    if (data.len < 2) return null;

    const id = data[0];
    const is_large = (id & 0x80) != 0;

    var word_size: u32 = 0;
    var header_size: usize = 0;

    if (is_large) {
        if (data.len < 4) return null;
        // 24-bit word size (little-endian)
        word_size = @as(u32, data[1]) | (@as(u32, data[2]) << 8) | (@as(u32, data[3]) << 16);
        header_size = 4;
    } else {
        word_size = data[1];
        header_size = 2;
    }

    const byte_size = word_size * 2;
    const odd_size = (id & 0x40) != 0;
    const actual_size: usize = if (odd_size) byte_size - 1 else byte_size;

    if (data.len < header_size + actual_size) return null;

    return SubBlock{
        .id = id,
        .word_size = word_size,
        .data = data[header_size .. header_size + actual_size],
    };
}

/// Iterate through sub-blocks in a WavPack block
pub fn iterateSubBlocks(block_data: []const u8) SubBlockIterator {
    return SubBlockIterator{
        .data = block_data,
        .pos = 32, // Skip block header
    };
}

pub const SubBlockIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn next(self: *SubBlockIterator) ?SubBlock {
        if (self.pos >= self.data.len) return null;

        const sub = parseSubBlock(self.data[self.pos..]) orelse return null;

        const is_large = (sub.id & 0x80) != 0;
        const header_size: usize = if (is_large) 4 else 2;
        const byte_size = sub.word_size * 2;

        self.pos += header_size + byte_size;

        return sub;
    }
};

// ============================================================================
// Deep Validation
// ============================================================================

/// Deep validate WavPack stream
pub fn validateWavPackDeep(data: []const u8, max_blocks: u32) WavPackDeepValidationResult {
    if (data.len < 32) {
        return WavPackDeepValidationResult.invalid("Data too small for WavPack");
    }

    var blocks_validated: u32 = 0;
    var samples_validated: u64 = 0;
    var has_md5 = false;
    var md5_verified = false;
    var channels: u8 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u8 = 0;
    var stored_md5: ?[16]u8 = null;

    var pos: usize = 0;

    while (pos < data.len and blocks_validated < max_blocks) {
        // Parse block header
        const header = parseBlockHeader(data[pos..]) orelse break;

        // Validate version
        if (header.version < 0x400 or header.version > 0x500) {
            return WavPackDeepValidationResult.invalid("Invalid WavPack version");
        }

        // Validate block size
        const block_total_size = header.block_size + 8; // block_size is size minus 8
        if (pos + block_total_size > data.len) {
            return WavPackDeepValidationResult.invalid("Block extends past file end");
        }

        // Extract info from first block
        if (blocks_validated == 0) {
            sample_rate = header.getSampleRate();
            bits_per_sample = (@as(u8, header.getBytesPerSample()) + 1) * 8;
            channels = if (header.isMono()) 1 else 2;
        }

        // Iterate through sub-blocks looking for MD5
        var iter = iterateSubBlocks(data[pos .. pos + block_total_size]);
        while (iter.next()) |sub| {
            if (sub.getId() == .md5_checksum) {
                if (sub.data.len >= 16) {
                    has_md5 = true;
                    stored_md5 = sub.data[0..16].*;
                }
            }
        }

        // The CRC in the header is for the decoded audio samples
        // We can't verify it without full decoding, but we validate structure
        samples_validated += header.block_samples;
        blocks_validated += 1;

        pos += block_total_size;
    }

    if (blocks_validated == 0) {
        return WavPackDeepValidationResult.invalid(errmsg.noValidXFound("blocks"));
    }

    // MD5 verification would require full decode + hash comparison
    // For structural validation, we just note if MD5 is present
    if (has_md5 and stored_md5 != null) {
        // MD5 present but we don't have full audio decode to verify
        // Mark as "has_md5" but not "verified" unless we implement full decode
        md5_verified = false;
    }

    return WavPackDeepValidationResult.ok(
        blocks_validated,
        samples_validated,
        has_md5,
        md5_verified,
        channels,
        sample_rate,
        bits_per_sample,
    );
}

/// Validate WavPack file
pub fn validateWavPackFile(file: std.fs.File, max_blocks: u32, allocator: std.mem.Allocator) WavPackDeepValidationResult {
    // Get file size
    const file_size = file.getEndPos() catch {
        return WavPackDeepValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < 32) {
        return WavPackDeepValidationResult.invalid(errmsg.fileTooSmallFor("WavPack"));
    }

    // Read file into memory (limited to reasonable size)
    const max_size: usize = 100 * 1024 * 1024; // 100MB limit
    const read_size: usize = @min(file_size, max_size);

    file.seekTo(0) catch {
        return WavPackDeepValidationResult.invalid("Failed to seek");
    };

    const data = allocator.alloc(u8, read_size) catch {
        return WavPackDeepValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return WavPackDeepValidationResult.invalid(errmsg.failedToRead("file"));
    };

    return validateWavPackDeep(data[0..bytes_read], max_blocks);
}

// ============================================================================
// Tests
// ============================================================================

test "parseBlockHeader - valid header" {
    var header_bytes: [32]u8 = undefined;

    // Signature
    @memcpy(header_bytes[0..4], "wvpk");

    // Block size (100 bytes after header = 92 + 8)
    std.mem.writeInt(u32, header_bytes[4..8], 92, .little);

    // Version 0x407
    std.mem.writeInt(u16, header_bytes[8..10], 0x407, .little);

    // Track number and index flags
    header_bytes[10] = 0;
    header_bytes[11] = 0;

    // Total samples
    std.mem.writeInt(u32, header_bytes[12..16], 44100, .little);

    // Block index
    std.mem.writeInt(u32, header_bytes[16..20], 0, .little);

    // Block samples
    std.mem.writeInt(u32, header_bytes[20..24], 1024, .little);

    // Flags: stereo, 16-bit (bps index 1), sample rate index 9 (44100)
    // bits_per_sample = 1, mono = 0, sample_rate_index = 9
    const flags: u32 = 0x01 | (9 << 23);
    std.mem.writeInt(u32, header_bytes[24..28], flags, .little);

    // CRC
    std.mem.writeInt(u32, header_bytes[28..32], 0xDEADBEEF, .little);

    const header = parseBlockHeader(&header_bytes);
    try std.testing.expect(header != null);

    try std.testing.expectEqual(@as(u32, 92), header.?.block_size);
    try std.testing.expectEqual(@as(u16, 0x407), header.?.version);
    try std.testing.expectEqual(@as(u32, 1024), header.?.block_samples);
    try std.testing.expect(!header.?.isMono());
    try std.testing.expectEqual(@as(u32, 44100), header.?.getSampleRate());
}

test "parseBlockHeader - rejects invalid signature" {
    var header_bytes: [32]u8 = undefined;
    @memcpy(header_bytes[0..4], "RIFF"); // Wrong signature
    @memset(header_bytes[4..32], 0);

    const header = parseBlockHeader(&header_bytes);
    try std.testing.expect(header == null);
}

test "parseSubBlock - small sub-block" {
    // ID = 0x05 (decorrelation_terms), size = 3 words (6 bytes)
    const sub_data = [_]u8{
        0x05, // ID
        0x03, // Word size (3 words = 6 bytes)
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // Data
    };

    const sub = parseSubBlock(&sub_data);
    try std.testing.expect(sub != null);

    try std.testing.expectEqual(SubBlockId.decorrelation_terms, sub.?.getId());
    try std.testing.expectEqual(@as(u32, 3), sub.?.word_size);
    try std.testing.expectEqual(@as(usize, 6), sub.?.data.len);
}

test "parseSubBlock - large sub-block" {
    // ID = 0x8D (large bitstream), size = 0x100 words
    const sub_data = [_]u8{
        0x8D, // ID with large flag
        0x00, 0x01, 0x00, // 24-bit word size (0x100 = 256 words)
    } ++ [_]u8{0xAA} ** (256 * 2); // 512 bytes of data

    const sub = parseSubBlock(&sub_data);
    try std.testing.expect(sub != null);

    try std.testing.expectEqual(SubBlockId.bitstream, sub.?.getId());
    try std.testing.expect(sub.?.isLargeSize());
    try std.testing.expectEqual(@as(u32, 256), sub.?.word_size);
}

test "validateWavPackDeep - minimal valid file" {
    var file_data: [100]u8 = undefined;

    // Block header
    @memcpy(file_data[0..4], "wvpk");
    std.mem.writeInt(u32, file_data[4..8], 92, .little); // block_size
    std.mem.writeInt(u16, file_data[8..10], 0x407, .little); // version
    file_data[10] = 0; // track
    file_data[11] = 0; // index flags
    std.mem.writeInt(u32, file_data[12..16], 44100, .little); // total samples
    std.mem.writeInt(u32, file_data[16..20], 0, .little); // block index
    std.mem.writeInt(u32, file_data[20..24], 1024, .little); // block samples
    const flags: u32 = 0x01 | (9 << 23); // 16-bit, 44100 Hz
    std.mem.writeInt(u32, file_data[24..28], flags, .little);
    std.mem.writeInt(u32, file_data[28..32], 0, .little); // CRC

    // Pad with sub-block data (dummy)
    @memset(file_data[32..100], 0);

    const result = validateWavPackDeep(&file_data, 100);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 1), result.blocks_validated);
    try std.testing.expectEqual(@as(u64, 1024), result.samples_validated);
    try std.testing.expectEqual(@as(u8, 2), result.channels);
    try std.testing.expectEqual(@as(u32, 44100), result.sample_rate);
}

test "validateWavPackDeep - rejects too small" {
    const small_data = [_]u8{0} ** 10;
    const result = validateWavPackDeep(&small_data, 100);
    try std.testing.expect(!result.valid);
}

test "validateWavPackDeep - rejects invalid version" {
    var file_data: [32]u8 = undefined;

    @memcpy(file_data[0..4], "wvpk");
    std.mem.writeInt(u32, file_data[4..8], 24, .little);
    std.mem.writeInt(u16, file_data[8..10], 0x300, .little); // Too old version
    @memset(file_data[10..32], 0);

    const result = validateWavPackDeep(&file_data, 100);
    try std.testing.expect(!result.valid);
}

test "ground truth - WavPack sample" {
    // Read real WavPack file for validation
    const file = std.fs.cwd().openFile("ground_truth_examples/wavpack/sample.wv", .{}) catch |err| {
        // Skip test if ground truth sample not available
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const allocator = std.testing.allocator;
    const result = validateWavPackFile(file, 100, allocator);

    try std.testing.expect(result.valid);
    try std.testing.expect(result.blocks_validated >= 1);
    try std.testing.expect(result.samples_validated > 0);
    try std.testing.expectEqual(@as(u32, 44100), result.sample_rate);
    try std.testing.expectEqual(@as(u8, 1), result.channels); // Mono file
}
