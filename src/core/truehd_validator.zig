//! TrueHD / MLP (Meridian Lossless Packing) deep validation (Pure Zig).
//!
//! Dolby TrueHD is the lossless codec on Blu-ray discs; MLP is its DVD-Audio
//! ancestor. Both share the access-unit bitstream framing validated here.
//!
//! Validates access units (AUs) by checking the 4-byte AU header, the XOR
//! parity that covers the AU header plus the substream directory, the
//! CRC-16-protected major sync header, per-substream parity/CRC-8 checkdata
//! tails, and exact AU chaining (next AU begins at cur + length words × 2).
//! This is frame-boundary + header-integrity validation, NOT a lossless
//! decode.
//!
//! Reference: ffmpeg libavcodec/mlp_parse.c (ff_mlp_read_major_sync),
//! mlpdec.c (read_access_unit), mlp.c (ff_mlp_checksum16, ff_mlp_checksum8,
//! ff_mlp_calculate_parity) — all read verbatim 2026-08-14. Both checksum
//! formulas were additionally verified byte-exact against an ffmpeg-decoded
//! Blu-ray TrueHD carve before being encoded here.

const std = @import("std");
const runtime = @import("runtime.zig");
const errmsg = @import("error_messages.zig");

/// TrueHD major sync format sync word (big-endian, at byte 4 of a sync AU)
const FORMAT_SYNC_TRUEHD: u32 = 0xF8726FBA;
/// MLP (DVD-Audio) major sync format sync word
const FORMAT_SYNC_MLP: u32 = 0xF8726FBB;
/// The two format syncs differ only in bit 0 — mask to match either
const FORMAT_SYNC_MASK: u32 = 0xFFFFFFFE;

/// Maximum substream count ffmpeg will decode (MAX_SUBSTREAMS, mlp.h);
/// TrueHD Atmos uses 4, MLP is limited to 2.
const MAX_SUBSTREAMS: u8 = 4;
/// Highest legal sample rate (MAX_SAMPLERATE = 4 × 48000, mlp.h)
const MAX_SAMPLE_RATE: u32 = 192000;
/// How far into the buffer to hunt for the first major sync. Raw captures
/// may carry leading junk, but a legitimate stream syncs almost immediately.
const MAX_SYNC_SCAN_BYTES: usize = 64 * 1024;
/// Minimum major sync header size (mlp_get_major_sync_size base, before
/// TrueHD extension blocks expand it)
const MAJOR_SYNC_BASE_SIZE: usize = 28;

/// CRC-16 table for the major sync checksum, poly 0x002D, generated exactly
/// like ffmpeg's av_crc_init(le=0, bits=16): entries are byte-swapped so the
/// running state stays byte-swapped too (see mlpCrc16).
const crc16_2d_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]u16 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| {
            const feedback = (c & 0x8000_0000) != 0;
            c <<= 1;
            if (feedback) c ^= 0x002D << 16;
        }
        // av_bswap32; low 16 bits of c are always zero, so this is exact
        table[i] = @truncate(@byteSwap(c));
    }
    break :blk table;
};

/// CRC-8 table for substream checkdata, poly 0x63, generated exactly like
/// ffmpeg's av_crc_init(le=0, bits=8).
const crc8_63_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| {
            const feedback = (c & 0x8000_0000) != 0;
            c <<= 1;
            if (feedback) c ^= 0x63 << 24;
        }
        table[i] = @truncate(c >> 24);
    }
    break :blk table;
};

/// Byte-swapped-state CRC-16 (poly 0x002D, init 0) replicating ffmpeg's
/// av_crc over its crc_2D table byte-for-byte; the value it returns is the
/// byte-swapped remainder, which is what the stream stores (little-endian).
fn mlpCrc16(data: []const u8) u16 {
    var crc: u16 = 0;
    for (data) |b| {
        const idx: u8 = @as(u8, @truncate(crc)) ^ b;
        crc = crc16_2d_table[idx] ^ (crc >> 8);
    }
    return crc;
}

/// MSB-first CRC-8 (poly 0x63) replicating ffmpeg's av_crc over crc_63;
/// ff_mlp_checksum8 seeds it with 0x3C.
fn mlpCrc8(data: []const u8, init: u8) u8 {
    var crc: u8 = init;
    for (data) |b| {
        crc = crc8_63_table[crc ^ b];
    }
    return crc;
}

/// XOR of all bytes (ff_mlp_calculate_parity without the word-at-a-time
/// optimization — same result).
fn calculateParity(data: []const u8) u8 {
    var parity: u8 = 0;
    for (data) |b| parity ^= b;
    return parity;
}

/// The AU parity rule from mlpdec.c: XOR of the check nibble's own nibble
/// fold must come out 0xF.
fn parityFoldOk(parity: u8) bool {
    return (((parity >> 4) ^ parity) & 0x0F) == 0x0F;
}

/// mlp_samplerate from mlp_parse.h: 0xF is invalid (0); bit 3 selects the
/// 44.1 kHz family, low 3 bits are a power-of-two multiplier.
fn sampleRateFromRatebits(ratebits: u4) u32 {
    if (ratebits == 0xF) return 0;
    const base: u32 = if ((ratebits & 0x8) != 0) 44100 else 48000;
    return base << @intCast(ratebits & 0x7);
}

/// Per-bit channel counts for the TrueHD 13-bit channel map
/// (thd_chancount, mlp_parse.h): LR C LFE LRs LRvh LRc LRrs Cs Ts LRsd LRw Cvh LFE2
const thd_chancount = [13]u8{ 2, 1, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 1 };

/// truehd_channels from mlp_parse.h: sum of channel counts for each set bit
/// of the channel-arrangement map.
fn truehdChannelCount(chanmap: u13) u8 {
    var channels: u8 = 0;
    for (thd_chancount, 0..) |count, i| {
        if ((chanmap >> @intCast(i)) & 1 != 0) channels += count;
    }
    return channels;
}

/// MLP (stream type 0xBB) channel counts by 5-bit channel arrangement
/// (mlp_channels, mlp_parse.c); 0 marks arrangements the table leaves
/// undefined — reported as-is, not treated as corruption (ffmpeg doesn't
/// reject them either; restart headers carry the authoritative layout).
const mlp_channels = [32]u8{
    1, 2, 3, 4, 3, 4, 5, 3, 4, 5, 4, 5, 6, 4, 5, 4,
    5, 6, 5, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/// MLP quantization word sizes (mlp_quants, mlp_parse.c); 0 = invalid code
const mlp_quants = [16]u8{ 16, 20, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub const MajorSyncError = error{
    TooShort,
    BadFormatSync,
    ChecksumMismatch,
    BadSampleRate,
    BadQuantization,
    BadSubstreamCount,
};

/// Parsed major sync info — the subset of ff_mlp_read_major_sync's
/// MLPHeaderInfo that frame validation needs.
pub const TrueHdMajorSyncInfo = struct {
    stream_type: u8, // 0xBA = TrueHD, 0xBB = MLP
    header_size: usize, // 28 base, TrueHD extension blocks expand it
    format_info: u32, // the 32-bit word after the format sync (ratebits + channel maps)
    sample_rate: u32,
    channels: u8,
    num_substreams: u8,
};

/// Parse and verify a major sync header (data starts at the format sync).
/// Mirrors ff_mlp_read_major_sync: size from mlp_get_major_sync_size, then
/// the CRC-16 check (coverage [0, size-4), XOR the LE16 at size-4, compare
/// against the LE16 stored at size-2), then field plausibility per mlpdec.c.
pub fn parseMajorSync(data: []const u8) MajorSyncError!TrueHdMajorSyncInfo {
    if (data.len < MAJOR_SYNC_BASE_SIZE) return error.TooShort;

    const sync = std.mem.readInt(u32, data[0..4], .big);
    if ((sync & FORMAT_SYNC_MASK) != FORMAT_SYNC_TRUEHD) return error.BadFormatSync;
    const stream_type: u8 = @truncate(sync & 0xFF);

    // TrueHD-only extension blocks grow the header (mlp_get_major_sync_size)
    var header_size: usize = MAJOR_SYNC_BASE_SIZE;
    if (sync == FORMAT_SYNC_TRUEHD and (data[25] & 1) != 0) {
        header_size += 2 + @as(usize, data[26] >> 4) * 2;
    }
    if (data.len < header_size) return error.TooShort;

    var checksum = mlpCrc16(data[0 .. header_size - 4]);
    checksum ^= std.mem.readInt(u16, data[header_size - 4 ..][0..2], .little);
    if (checksum != std.mem.readInt(u16, data[header_size - 2 ..][0..2], .little)) {
        return error.ChecksumMismatch;
    }

    const format_info = std.mem.readInt(u32, data[4..8], .big);

    var ratebits: u4 = undefined;
    var channels: u8 = 0;
    if (stream_type == 0xBA) {
        // TrueHD: ratebits(4) pad(4) cm0(2) cm1(2) chanarr1(5) cm2(2) chanarr2(13)
        ratebits = @truncate(data[4] >> 4);
        const chanarr1: u5 = @truncate(((@as(u16, data[5]) & 0x0F) << 1) | (data[6] >> 7));
        const chanarr2: u13 = @truncate(((@as(u16, data[6]) & 0x1F) << 8) | data[7]);
        // ffmpeg's parser prefers the 13-bit stream-2 map when present
        channels = if (chanarr2 != 0) truehdChannelCount(chanarr2) else truehdChannelCount(chanarr1);
    } else {
        // MLP: quant1(4) quant2(4) ratebits1(4) ratebits2(4) skip(11) chanarr(5)
        const group1_bits = mlp_quants[data[4] >> 4];
        const group2_bits = mlp_quants[data[4] & 0x0F];
        if (group1_bits == 0) return error.BadQuantization;
        if (group2_bits > group1_bits) return error.BadQuantization;
        ratebits = @truncate(data[5] >> 4);
        const ratebits2: u4 = @truncate(data[5] & 0x0F);
        const rate2 = sampleRateFromRatebits(ratebits2);
        if (rate2 != 0 and rate2 != sampleRateFromRatebits(ratebits)) return error.BadSampleRate;
        channels = mlp_channels[data[7] & 0x1F];
    }

    const sample_rate = sampleRateFromRatebits(ratebits);
    if (sample_rate == 0 or sample_rate > MAX_SAMPLE_RATE) return error.BadSampleRate;

    // num_substreams: 4 bits at bit offset 128 (byte 16, high nibble)
    const num_substreams: u8 = data[16] >> 4;
    if (num_substreams == 0) return error.BadSubstreamCount;
    if (num_substreams > MAX_SUBSTREAMS) return error.BadSubstreamCount;
    if (stream_type == 0xBB and num_substreams > 2) return error.BadSubstreamCount;

    return TrueHdMajorSyncInfo{
        .stream_type = stream_type,
        .header_size = header_size,
        .format_info = format_info,
        .sample_rate = sample_rate,
        .channels = channels,
        .num_substreams = num_substreams,
    };
}

/// Validate a raw TrueHD/MLP bitstream from a buffer.
/// Anchors on the first major sync, then walks access units verifying the
/// AU header + substream-directory parity, major sync CRC and cross-unit
/// parameter stability, substream checkdata tails, and exact chaining.
/// A truncated final AU is tolerated like dts_validator's truncated frame.
pub fn validateTrueHdStream(data: []const u8, max_units: u32) TrueHdValidationResult {
    if (data.len < 12) {
        return TrueHdValidationResult.invalid("Data too small for TrueHD", 0);
    }

    // Anchor: find the first AU carrying a major sync (format sync sits at
    // AU offset 4), scanning a bounded prefix the way ffmpeg's parser hunts
    // for 0xF8726FBA/BB before locking on.
    var pos: usize = 0;
    var found_sync = false;
    while (pos + 8 <= data.len and pos < MAX_SYNC_SCAN_BYTES) : (pos += 1) {
        if ((std.mem.readInt(u32, data[pos + 4 ..][0..4], .big) & FORMAT_SYNC_MASK) == FORMAT_SYNC_TRUEHD) {
            found_sync = true;
            break;
        }
    }
    if (!found_sync) {
        return TrueHdValidationResult.invalid(errmsg.noValidXFound("TrueHD major sync"), 0);
    }

    var units_validated: u32 = 0;
    var stream_type: u8 = 0;
    var first_sync_word: u32 = 0;
    var first_format_info: u32 = 0;
    var num_substreams: u8 = 0;
    var sample_rate: u32 = 0;
    var channels: u8 = 0;

    while (units_validated < max_units and pos + 4 <= data.len) {
        const au_word = std.mem.readInt(u16, data[pos..][0..2], .big);
        const au_len = @as(usize, au_word & 0x0FFF) * 2;
        if (au_len < 4) {
            return TrueHdValidationResult.invalid("TrueHD access unit length invalid (data corruption)", units_validated);
        }

        // Major sync detection + verification
        var header_size: usize = 4;
        var is_major_sync = false;
        if (pos + 8 <= data.len and
            (std.mem.readInt(u32, data[pos + 4 ..][0..4], .big) & FORMAT_SYNC_MASK) == FORMAT_SYNC_TRUEHD)
        {
            is_major_sync = true;
            const msi = parseMajorSync(data[pos + 4 ..]) catch |err| switch (err) {
                error.TooShort => {
                    // Major sync truncated at the buffer's end — tolerated
                    // like a truncated final frame once something validated.
                    if (units_validated > 0) break;
                    return TrueHdValidationResult.invalid("TrueHD access unit extends beyond data", 0);
                },
                error.BadFormatSync => return TrueHdValidationResult.invalid("TrueHD major sync malformed (data corruption)", units_validated),
                error.ChecksumMismatch => return TrueHdValidationResult.invalid("TrueHD major sync checksum mismatch (data corruption)", units_validated),
                error.BadSampleRate => return TrueHdValidationResult.invalid("TrueHD major sync has invalid sample rate", units_validated),
                error.BadQuantization => return TrueHdValidationResult.invalid("MLP major sync has invalid quantization", units_validated),
                error.BadSubstreamCount => return TrueHdValidationResult.invalid("TrueHD major sync has invalid substream count", units_validated),
            };
            const sync_word = std.mem.readInt(u32, data[pos + 4 ..][0..4], .big);
            if (units_validated == 0) {
                stream_type = msi.stream_type;
                first_sync_word = sync_word;
                first_format_info = msi.format_info;
                num_substreams = msi.num_substreams;
                sample_rate = msi.sample_rate;
                channels = msi.channels;
            } else if (sync_word != first_sync_word or
                msi.format_info != first_format_info or
                msi.num_substreams != num_substreams)
            {
                // Cross-unit consistency: the format sync, the format-info
                // word (ratebits + channel maps), and the substream count are
                // fixed for the life of a stream; any drift is corruption.
                return TrueHdValidationResult.invalid("TrueHD major sync parameters changed mid-stream (data corruption)", units_validated);
            }
            header_size += msi.header_size;
        }

        // Substream directory: one 16-bit entry per substream (+16 bits when
        // the TrueHD-only extra word is flagged), carrying flags and the
        // cumulative end offset of each substream's data (in 16-bit words).
        var dir_pos = pos + header_size;
        var dir_size: usize = 0;
        var substream_ends: [MAX_SUBSTREAMS]usize = undefined;
        var substream_checked: [MAX_SUBSTREAMS]bool = undefined;
        var prev_end: usize = 0;
        var truncated = false;
        for (0..num_substreams) |i| {
            if (dir_pos + 2 > data.len) {
                truncated = true;
                break;
            }
            const entry = std.mem.readInt(u16, data[dir_pos..][0..2], .big);
            const extraword = (entry & 0x8000) != 0;
            const nonrestart = (entry & 0x4000) != 0;
            const checkdata = (entry & 0x2000) != 0;
            const end_bytes = @as(usize, entry & 0x0FFF) * 2;
            dir_pos += 2;
            dir_size += 2;
            if (extraword) {
                if (stream_type == 0xBB) {
                    return TrueHdValidationResult.invalid("MLP substream directory has forbidden extra word (data corruption)", units_validated);
                }
                if (dir_pos + 2 > data.len) {
                    truncated = true;
                    break;
                }
                dir_pos += 2;
                dir_size += 2;
            }
            // mlpdec.c: nonrestart_substr must be the complement of
            // is_major_sync_unit — equality is corruption.
            if (nonrestart == is_major_sync) {
                return TrueHdValidationResult.invalid("TrueHD substream restart flag inconsistent (data corruption)", units_validated);
            }
            if (end_bytes < prev_end) {
                return TrueHdValidationResult.invalid("TrueHD substream directory ends out of order (data corruption)", units_validated);
            }
            substream_ends[i] = end_bytes;
            substream_checked[i] = checkdata;
            prev_end = end_bytes;
        }
        if (truncated) {
            if (units_validated > 0) break; // truncated final AU — tolerated
            return TrueHdValidationResult.invalid("TrueHD access unit extends beyond data", 0);
        }

        if (au_len < header_size + dir_size) {
            return TrueHdValidationResult.invalid("TrueHD access unit too small for headers (data corruption)", units_validated);
        }
        if (prev_end > au_len - header_size - dir_size) {
            return TrueHdValidationResult.invalid("TrueHD substream directory exceeds access unit (data corruption)", units_validated);
        }

        // AU parity (mlpdec.c): XOR over the 4-byte AU header and the
        // substream directory — the major sync body is excluded; the check
        // nibble is chosen so the nibble fold comes out 0xF.
        const parity = calculateParity(data[pos..][0..4]) ^
            calculateParity(data[pos + header_size ..][0..dir_size]);
        if (!parityFoldOk(parity)) {
            return TrueHdValidationResult.invalid("TrueHD access unit parity mismatch (data corruption)", units_validated);
        }

        // Exact chaining: this AU ends at pos + au_len and the next one must
        // begin right there. A truncated final AU is tolerated once at least
        // one unit validated.
        if (pos + au_len > data.len) {
            if (units_validated > 0) break;
            return TrueHdValidationResult.invalid("TrueHD access unit extends beyond data", 0);
        }

        // Substream checkdata tails: when flagged, a substream's last two
        // bytes are an XOR-parity byte (stored ^ parity == 0xA9) and a CRC-8
        // byte — the only integrity coverage the payload bytes get.
        const payload = data[pos + header_size + dir_size .. pos + au_len];
        var start: usize = 0;
        for (0..num_substreams) |i| {
            const end = substream_ends[i];
            const ss_len = end - start;
            if (substream_checked[i] and ss_len >= 4) {
                const ss = payload[start..end];
                const ss_parity = calculateParity(ss[0 .. ss_len - 2]);
                if ((ss_parity ^ ss[ss_len - 2]) != 0xA9) {
                    return TrueHdValidationResult.invalid("TrueHD substream parity mismatch (data corruption)", units_validated);
                }
                const ss_crc = mlpCrc8(ss[0 .. ss_len - 3], 0x3C) ^ ss[ss_len - 3];
                if (ss_crc != ss[ss_len - 1]) {
                    return TrueHdValidationResult.invalid("TrueHD substream checksum mismatch (data corruption)", units_validated);
                }
            }
            start = end;
        }

        units_validated += 1;
        pos += au_len;
    }

    if (units_validated == 0) {
        return TrueHdValidationResult.invalid(errmsg.noValidXFound("TrueHD access units"), 0);
    }

    return TrueHdValidationResult.ok(units_validated, sample_rate, channels);
}

/// TrueHD validation result
pub const TrueHdValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    units_validated: u32,
    sample_rate: u32,
    channels: u8,

    pub fn ok(units: u32, sample_rate: u32, channels: u8) TrueHdValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .units_validated = units,
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn invalid(msg: []const u8, units: u32) TrueHdValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .units_validated = units,
            .sample_rate = 0,
            .channels = 0,
        };
    }
};

// ============ Tests ============

/// Build a 28-byte TrueHD major sync header: stereo (channel map 1), one to
/// four substreams, CBR, no extension blocks. The checksum is produced with
/// the module's mlpCrc16, whose formula was verified byte-exact against an
/// ffmpeg-decoded Blu-ray carve before use — the synthetic fixture therefore
/// matches what a real encoder writes.
fn testMakeMajorSync(buf: []u8, ratebits: u4, num_substreams: u4) void {
    std.debug.assert(buf.len == MAJOR_SYNC_BASE_SIZE);
    @memset(buf, 0);
    buf[0] = 0xF8;
    buf[1] = 0x72;
    buf[2] = 0x6F;
    buf[3] = 0xBA;
    buf[4] = @as(u8, ratebits) << 4; // ratebits + 4 reserved bits
    buf[5] = 0x00; // cm0=0 cm1=0, chanarr1 bits 4-1 = 0
    buf[6] = 0x80; // chanarr1 bit0 = 1 (stereo), cm2=0, chanarr2 high bits 0
    buf[7] = 0x01; // chanarr2 = 1 (stereo)
    buf[8] = 0xB7; // signature bytes observed at this offset in real streams
    buf[9] = 0x52;
    buf[14] = 0x00; // is_vbr=0, peak_bitrate high bits
    buf[15] = 0x40; // peak_bitrate = 0x0040
    buf[16] = @as(u8, num_substreams) << 4;
    // bytes 17-23 reserved zero; byte 25 bit 0 = 0 keeps header at 28 bytes;
    // bytes 24-25 are the XOR word (zero here), 26-27 the stored checksum
    const checksum = mlpCrc16(buf[0..24]);
    buf[26] = @truncate(checksum & 0xFF);
    buf[27] = @truncate(checksum >> 8);
}

/// Build one complete 64-byte synthetic access unit: AU header, optional
/// major sync, a single-substream directory entry (no checkdata), varied
/// payload, and the check nibble solved so the AU parity folds to 0xF —
/// exactly the rule read_access_unit (mlpdec.c) enforces.
fn testMakeAu(buf: []u8, with_sync: bool, ratebits: u4, seed: u8) void {
    std.debug.assert(buf.len == 64);
    buf[0] = 0x00; // check nibble solved below; AU length = 32 words (64 bytes)
    buf[1] = 0x20;
    buf[2] = 0x12; // input_timing (arbitrary)
    buf[3] = seed;
    var dir_off: usize = 4;
    if (with_sync) {
        testMakeMajorSync(buf[4..32], ratebits, 1);
        dir_off = 32;
    }
    const payload_off = dir_off + 2;
    const end_words: u16 = @intCast((buf.len - payload_off) / 2);
    // entry: extraword=0, nonrestart = !is_major_sync (mlpdec's rule), checkdata=0
    const flags: u8 = if (with_sync) 0x00 else 0x40;
    buf[dir_off] = flags | @as(u8, @truncate(end_words >> 8));
    buf[dir_off + 1] = @truncate(end_words & 0xFF);
    for (buf[payload_off..], 0..) |*b, i| b.* = @truncate(i *% 37 +% seed);
    // Solve the check nibble: parity covers AU header + directory only
    const parity = calculateParity(buf[0..4]) ^ calculateParity(buf[dir_off..][0..2]);
    buf[0] |= (((parity >> 4) ^ parity ^ 0x0F) & 0x0F) << 4;
}

/// Build a 64-byte non-sync AU whose single substream carries checkdata:
/// the last two payload bytes hold the parity byte (stored ^ parity == 0xA9)
/// and the CRC-8 checksum byte, per ff_mlp_checksum8 / mlpdec.c.
fn testMakeAuWithCheckdata(buf: []u8, seed: u8) void {
    std.debug.assert(buf.len == 64);
    buf[0] = 0x00;
    buf[1] = 0x20; // 32 words = 64 bytes
    buf[2] = 0x12;
    buf[3] = seed;
    const dir_off: usize = 4;
    const payload_off = dir_off + 2;
    const ss_len = buf.len - payload_off; // 58
    const end_words: u16 = @intCast(ss_len / 2);
    // extraword=0, nonrestart=1, checkdata=1
    buf[dir_off] = 0x60 | @as(u8, @truncate(end_words >> 8));
    buf[dir_off + 1] = @truncate(end_words & 0xFF);
    for (buf[payload_off..], 0..) |*b, i| b.* = @truncate(i *% 41 +% seed);
    const ss = buf[payload_off..][0..ss_len];
    // parity byte at ss[len-2]: stored ^ parity(ss[0..len-2]) must equal 0xA9
    ss[ss_len - 2] = calculateParity(ss[0 .. ss_len - 2]) ^ 0xA9;
    // checksum byte at ss[len-1]: crc8(init 0x3C) over len-3 bytes, XOR byte at len-3
    ss[ss_len - 1] = mlpCrc8(ss[0 .. ss_len - 3], 0x3C) ^ ss[ss_len - 3];
    const parity = calculateParity(buf[0..4]) ^ calculateParity(buf[dir_off..][0..2]);
    buf[0] |= (((parity >> 4) ^ parity ^ 0x0F) & 0x0F) << 4;
}

test "TrueHD validates ground truth sample" {
    const file = runtime.openFile("ground_truth_examples/truehd/sample.thd", .{}) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer file.close(runtime.io());

    const __sz_data = file.length(runtime.io()) catch return error.SkipZigTest;
    if (__sz_data > 10 * 1024 * 1024) return error.SkipZigTest;
    const data = std.testing.allocator.alloc(u8, @intCast(__sz_data)) catch return error.SkipZigTest;
    _ = file.readPositionalAll(runtime.io(), data, 0) catch return error.SkipZigTest;
    defer std.testing.allocator.free(data);

    const result = validateTrueHdStream(data, 100);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.units_validated > 0);
    try std.testing.expectEqual(@as(u32, 48000), result.sample_rate);
}

test "TrueHD rejects empty data" {
    const result = validateTrueHdStream(&[_]u8{}, 10);
    try std.testing.expect(!result.valid);
}

test "TrueHD rejects garbage data" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 8;
    const result = validateTrueHdStream(&garbage, 10);
    try std.testing.expect(!result.valid);
}

test "TrueHD major sync header parsing" {
    var msync: [28]u8 = undefined;
    testMakeMajorSync(&msync, 0, 1);
    const info = try parseMajorSync(&msync);
    try std.testing.expectEqual(@as(u8, 0xBA), info.stream_type);
    try std.testing.expectEqual(@as(usize, 28), info.header_size);
    try std.testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), info.channels);
    try std.testing.expectEqual(@as(u8, 1), info.num_substreams);
}

test "TrueHD accepts synthetic AU chain with major sync" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], false, 0, 0x33);

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 3), result.units_validated);
    try std.testing.expectEqual(@as(u32, 48000), result.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), result.channels);
}

test "TrueHD single-bit AU header corruption trips parity" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], false, 0, 0x33);
    // Flip one bit in the third AU's input_timing — covered only by parity
    stream[128 + 2] ^= 0x04;

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.units_validated);
}

test "TrueHD length-field corruption breaks chaining" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], false, 0, 0x33);
    // XOR bits 1 and 5 of the second AU's length byte: the nibble-fold parity
    // is unchanged (both nibbles flip identically), so only the chaining /
    // downstream structure checks can catch the walk landing mid-payload.
    stream[64 + 1] ^= 0x22;

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
}

test "TrueHD major sync bit flip trips checksum" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], false, 0, 0x33);
    // Flip one bit in the peak_bitrate field: the major sync body is NOT
    // covered by the AU parity, so only the CRC-16 can catch this.
    stream[4 + 15] ^= 0x10;

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
}

test "TrueHD truncated final AU tolerated" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], false, 0, 0x33);

    const result = validateTrueHdStream(stream[0 .. 192 - 10], 10);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.units_validated);
}

test "TrueHD major sync parameter change mid-stream rejected" {
    var stream: [192]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11); // 48 kHz
    testMakeAu(stream[64..128], false, 0, 0x22);
    testMakeAu(stream[128..192], true, 1, 0x33); // 96 kHz — valid CRC, wrong params

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(u32, 2), result.units_validated);
}

test "TrueHD zero substream count rejected" {
    var stream: [128]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAu(stream[64..128], false, 0, 0x22);
    // Patch num_substreams to 0 and re-bless the major sync checksum, so the
    // field check itself (not the CRC) must reject it. The AU parity does not
    // cover the major sync body, so it needs no compensation.
    stream[4 + 16] = 0x00;
    const checksum = mlpCrc16(stream[4 .. 4 + 24]);
    stream[4 + 26] = @truncate(checksum & 0xFF);
    stream[4 + 27] = @truncate(checksum >> 8);

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
}

test "TrueHD substream checkdata verified" {
    var stream: [128]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAuWithCheckdata(stream[64..128], 0x22);

    const good = validateTrueHdStream(&stream, 10);
    try std.testing.expect(good.valid);
    try std.testing.expectEqual(@as(u32, 2), good.units_validated);

    // Corrupt one payload byte: it is outside the AU header/directory parity
    // coverage, so only the substream checkdata tail can catch it.
    stream[64 + 20] ^= 0x01;
    const bad = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!bad.valid);
}

test "TrueHD substream checksum catches parity-compensated corruption" {
    var stream: [128]u8 = undefined;
    testMakeAu(stream[0..64], true, 0, 0x11);
    testMakeAuWithCheckdata(stream[64..128], 0x22);
    // Flip a payload bit AND the same bit of the stored parity byte: the
    // substream parity check is blinded, leaving the CRC-8 as the only
    // tripwire for this corruption.
    stream[64 + 20] ^= 0x01;
    stream[64 + 62] ^= 0x01;

    const result = validateTrueHdStream(&stream, 10);
    try std.testing.expect(!result.valid);
}
