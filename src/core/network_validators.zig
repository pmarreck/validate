//! Network capture format validators.
//!
//! Supports:
//!   - PCAP (classic libpcap format, all 4 magic variants)
//!   - PCAPNG (next-generation pcap, Section Header Block detection only)

const std = @import("std");
const testing = std.testing;
const ValidationResult = @import("format_validation.zig").ValidationResult;
const ValidationDepth = @import("format_validation.zig").ValidationDepth;
const FileFormat = @import("format_validation.zig").FileFormat;
const FileSource = @import("file_source.zig").FileSource;

// ============================================================
// PCAP magic variants
// ============================================================

/// PCAP global header is always 24 bytes.
const pcap_global_header_size: usize = 24;

/// PCAP packet record header is always 16 bytes.
const pcap_packet_header_size: usize = 16;

/// Maximum sane snaplen — 256 KiB (tcpdump/Wireshark default cap).
const pcap_max_snaplen: u32 = 262144;

/// Magic for big-endian, microsecond timestamps.
const pcap_magic_be_usec: u32 = 0xA1B2C3D4;
/// Magic for little-endian, microsecond timestamps.
const pcap_magic_le_usec: u32 = 0xD4C3B2A1;
/// Magic for big-endian, nanosecond timestamps.
const pcap_magic_be_nsec: u32 = 0xA1B23C4D;
/// Magic for little-endian, nanosecond timestamps.
const pcap_magic_le_nsec: u32 = 0x4D3CB2A1;

/// PCAPNG Section Header Block magic (first 4 bytes of the file).
const pcapng_magic: u32 = 0x0A0D0D0A;

// ============================================================
// Buffer-based validators
// ============================================================

/// Validate a PCAP file from a memory buffer.
/// Walks all packet records to verify structural completeness.
/// Returns .structural depth with the count of validated packets embedded in the result.
pub fn validatePcapFromBuffer(data: []const u8) ValidationResult {
    if (data.len < pcap_global_header_size) {
        return ValidationResult.invalidCode(.pcap, .file_too_small, "PCAP format");
    }

    // Determine endianness from magic bytes (first 4 bytes, native order).
    const magic_be = std.mem.readInt(u32, data[0..4][0..4], .big);
    const is_little_endian: bool = switch (magic_be) {
        // BE magic read as BE → actually BE file
        pcap_magic_be_usec, pcap_magic_be_nsec => false,
        // LE magic stored LE: when we read bytes 0xD4 0xC3 0xB2 0xA1 as big-endian
        // we get 0xD4C3B2A1 — that IS the LE-usec magic constant.
        pcap_magic_le_usec, pcap_magic_le_nsec => true,
        else => return ValidationResult.invalidCode(.pcap, .invalid_magic, "PCAP magic bytes"),
    };
    const endian: std.builtin.Endian = if (is_little_endian) .little else .big;

    // Read global header fields.
    const version_major = std.mem.readInt(u16, data[4..6][0..2], endian);
    const version_minor = std.mem.readInt(u16, data[6..8][0..2], endian);
    _ = version_minor; // We only validate major version
    const snaplen = std.mem.readInt(u32, data[16..20][0..4], endian);
    // network linktype at data[20..24] — not validated here (too many valid values)

    if (version_major != 2) {
        return ValidationResult.invalid(.pcap, "PCAP version_major must be 2");
    }
    if (snaplen == 0) {
        return ValidationResult.invalid(.pcap, "PCAP snaplen is zero");
    }
    if (snaplen > pcap_max_snaplen) {
        return ValidationResult.invalid(.pcap, "PCAP snaplen unreasonably large");
    }

    // Walk all packet records.
    var offset: usize = pcap_global_header_size;
    var packet_count: u32 = 0;

    while (offset < data.len) {
        // Need at least a 16-byte packet record header.
        if (offset + pcap_packet_header_size > data.len) {
            return ValidationResult.invalid(.pcap, "PCAP truncated packet record header");
        }

        const incl_len = std.mem.readInt(u32, data[offset + 8 .. offset + 12][0..4], endian);
        const orig_len = std.mem.readInt(u32, data[offset + 12 .. offset + 16][0..4], endian);

        // incl_len must not exceed snaplen.
        if (incl_len > snaplen) {
            return ValidationResult.invalid(.pcap, "PCAP packet incl_len exceeds snaplen");
        }

        // incl_len should not exceed orig_len (captured ≤ original).
        if (incl_len > orig_len) {
            return ValidationResult.invalid(.pcap, "PCAP packet incl_len exceeds orig_len");
        }

        // Packet body must be fully present.
        const body_end = offset + pcap_packet_header_size + incl_len;
        if (body_end > data.len) {
            return ValidationResult.invalid(.pcap, "PCAP truncated packet body");
        }

        offset = body_end;
        packet_count += 1;
    }

    return ValidationResult.okWithDepth(.pcap, .structural);
}

/// Validate a PCAPNG file from a memory buffer.
/// For now, just confirms the Section Header Block magic and minimum size.
pub fn validatePcapngFromBuffer(data: []const u8) ValidationResult {
    // Minimum: 4-byte SHB type (0x0A0D0D0A) + 4-byte block length + 4-byte byte-order magic
    if (data.len < 12) {
        return ValidationResult.invalidCode(.pcapng, .file_too_small, "PCAPNG format");
    }

    // Block type is always 0x0A0D0D0A regardless of endianness.
    // Block type is always 0x0A0D0D0A regardless of endianness.
    const block_type = std.mem.readInt(u32, data[0..4][0..4], .big);
    if (block_type != pcapng_magic) {
        return ValidationResult.invalidCode(.pcapng, .invalid_magic, "PCAPNG Section Header Block");
    }

    // Byte-order magic at offset 8: 0x1A2B3C4D (BE) or 0x4D3C2B1A (LE).
    // Both are valid; we just confirm it's one of them.
    const bom_be = std.mem.readInt(u32, data[8..12][0..4], .big);
    if (bom_be != 0x1A2B3C4D and bom_be != 0x4D3C2B1A) {
        return ValidationResult.invalid(.pcapng, "PCAPNG invalid byte-order magic");
    }

    return ValidationResult.okWithDepth(.pcapng, .structural);
}

/// File-source entry point for PCAP — reads up to the first 64 MiB then delegates.
/// Uses heap allocation: a 64 MiB stack frame overflows on every platform.
pub fn validatePcap(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pcap, .failed_to_seek, "to start");

    const max_pcap_buf: usize = 64 * 1024 * 1024;
    const allocator = std.heap.page_allocator;
    const buf = allocator.alloc(u8, max_pcap_buf) catch {
        return ValidationResult.invalidCode(.pcap, .failed_to_allocate, "PCAP buffer");
    };
    defer allocator.free(buf);

    const bytes_read = file.read(buf) catch {
        return ValidationResult.invalidCode(.pcap, .failed_to_read, "PCAP file");
    };

    return validatePcapFromBuffer(buf[0..bytes_read]);
}

/// File-source entry point for PCAPNG.
pub fn validatePcapng(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pcapng, .failed_to_seek, "to start");

    var buf: [4096]u8 = undefined;
    const bytes_read = file.read(&buf) catch {
        return ValidationResult.invalidCode(.pcapng, .failed_to_read, "PCAPNG file");
    };

    return validatePcapngFromBuffer(buf[0..bytes_read]);
}

// ============================================================
// Tests
// ============================================================

/// Build a minimal valid PCAP global header (24 bytes).
/// magic_bytes: the 4-byte magic (already in byte order for the slice).
fn buildPcapHeader(magic: [4]u8, version_major: u16, version_minor: u16, snaplen: u32, network: u32, endian: std.builtin.Endian) [24]u8 {
    var hdr: [24]u8 = undefined;
    @memcpy(hdr[0..4], &magic);
    std.mem.writeInt(u16, hdr[4..6], version_major, endian);
    std.mem.writeInt(u16, hdr[6..8], version_minor, endian);
    std.mem.writeInt(i32, hdr[8..12], 0, endian); // thiszone (UTC)
    std.mem.writeInt(u32, hdr[12..16], 0, endian); // sigfigs
    std.mem.writeInt(u32, hdr[16..20], snaplen, endian);
    std.mem.writeInt(u32, hdr[20..24], network, endian);
    return hdr;
}

/// Append a PCAP packet record to a fixed-size buffer, returning the new length.
fn appendPacketRecord(buf: []u8, offset: usize, ts_sec: u32, ts_usec: u32, incl_len: u32, orig_len: u32, body: []const u8, endian: std.builtin.Endian) usize {
    var rec: [16]u8 = undefined;
    std.mem.writeInt(u32, rec[0..4], ts_sec, endian);
    std.mem.writeInt(u32, rec[4..8], ts_usec, endian);
    std.mem.writeInt(u32, rec[8..12], incl_len, endian);
    std.mem.writeInt(u32, rec[12..16], orig_len, endian);
    @memcpy(buf[offset .. offset + 16], &rec);
    @memcpy(buf[offset + 16 .. offset + 16 + incl_len], body[0..incl_len]);
    return offset + 16 + incl_len;
}

// ---- PCAP tests ----

test "PCAP: minimal valid header only (no packets) — LE usec" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, // LE usec magic
        2, 4, 65535, 1, .little,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcap, result.format);
}

test "PCAP: minimal valid header only (no packets) — BE usec" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xA1, 0xB2, 0xC3, 0xD4 }, // BE usec magic
        2, 4, 65535, 1, .big,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcap, result.format);
}

test "PCAP: minimal valid header only (no packets) — LE nsec" {
    const hdr = buildPcapHeader(
        [4]u8{ 0x4D, 0x3C, 0xB2, 0xA1 }, // LE nsec magic
        2, 4, 65535, 1, .little,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcap, result.format);
}

test "PCAP: minimal valid header only (no packets) — BE nsec" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xA1, 0xB2, 0x3C, 0x4D }, // BE nsec magic
        2, 4, 65535, 1, .big,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcap, result.format);
}

test "PCAP: valid with two packets" {
    var buf: [24 + 2 * (16 + 16)]u8 = undefined; // hdr + 2 × (rec_hdr + 16-byte body)

    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, // LE usec
        2, 4, 65535, 1, .little,
    );
    @memcpy(buf[0..24], &hdr);

    const pkt_body = [_]u8{ 0x45, 0x00, 0x00, 0x28 } ** 4; // 16 bytes fake payload
    var off: usize = 24;
    off = appendPacketRecord(&buf, off, 1000, 0, 16, 16, &pkt_body, .little);
    off = appendPacketRecord(&buf, off, 1001, 500, 16, 16, &pkt_body, .little);

    const result = validatePcapFromBuffer(buf[0..off]);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcap, result.format);
}

test "PCAP: wrong magic rejected" {
    var hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 65535, 1, .little,
    );
    hdr[0] = 0xDE; // corrupt magic
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAP: version_major != 2 rejected" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 3, 4, 65535, 1, .little,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAP: snaplen == 0 rejected" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 0, 1, .little,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAP: snaplen > 262144 rejected" {
    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 300000, 1, .little,
    );
    const result = validatePcapFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAP: incl_len > snaplen rejected" {
    var buf: [24 + 16 + 200]u8 = undefined;

    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 100, 1, .little,
    );
    @memcpy(buf[0..24], &hdr);

    // incl_len=200 > snaplen=100
    const pkt_body = [_]u8{0xFF} ** 200;
    const off = appendPacketRecord(&buf, 24, 0, 0, 200, 200, &pkt_body, .little);

    const result = validatePcapFromBuffer(buf[0..off]);
    try testing.expect(!result.is_valid);
}

test "PCAP: incl_len > orig_len rejected" {
    var buf: [24 + 16 + 50]u8 = undefined;

    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 65535, 1, .little,
    );
    @memcpy(buf[0..24], &hdr);

    const pkt_body = [_]u8{0xFF} ** 50;
    const off = appendPacketRecord(&buf, 24, 0, 0, 50, 30, &pkt_body, .little); // incl > orig

    const result = validatePcapFromBuffer(buf[0..off]);
    try testing.expect(!result.is_valid);
}

test "PCAP: truncated mid-packet header rejected" {
    var buf: [24 + 8]u8 = undefined;

    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 65535, 1, .little,
    );
    @memcpy(buf[0..24], &hdr);
    // Only 8 bytes of a 16-byte packet header
    @memcpy(buf[24..32], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });

    const result = validatePcapFromBuffer(&buf);
    try testing.expect(!result.is_valid);
}

test "PCAP: truncated packet body rejected" {
    var buf: [24 + 16 + 50]u8 = undefined;

    const hdr = buildPcapHeader(
        [4]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, 2, 4, 65535, 1, .little,
    );
    @memcpy(buf[0..24], &hdr);

    // Packet header says incl_len=100 but we only have 50 bytes of body in the slice
    var rec: [16]u8 = undefined;
    std.mem.writeInt(u32, rec[0..4], 0, .little);
    std.mem.writeInt(u32, rec[4..8], 0, .little);
    std.mem.writeInt(u32, rec[8..12], 100, .little); // claims 100 bytes
    std.mem.writeInt(u32, rec[12..16], 100, .little);
    @memcpy(buf[24..40], &rec);
    @memset(buf[40..90], 0xFF); // only 50 bytes provided

    // Pass only 24+16+50 = 90 bytes — body is truncated
    const result = validatePcapFromBuffer(buf[0..90]);
    try testing.expect(!result.is_valid);
}

test "PCAP: file too small rejected" {
    const tiny = [_]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }; // only 4 bytes
    const result = validatePcapFromBuffer(&tiny);
    try testing.expect(!result.is_valid);
}

// ---- PCAPNG tests ----

test "PCAPNG: valid Section Header Block (LE)" {
    var hdr: [12]u8 = undefined;
    // Block type: 0x0A0D0D0A (always stored as this byte sequence)
    std.mem.writeInt(u32, hdr[0..4], pcapng_magic, .big);
    // Block total length (not deeply validated)
    std.mem.writeInt(u32, hdr[4..8], 28, .little);
    // Byte-order magic (LE): 0x4D3C2B1A stored LE = bytes 1A 2B 3C 4D
    std.mem.writeInt(u32, hdr[8..12], 0x1A2B3C4D, .big);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcapng, result.format);
}

test "PCAPNG: valid Section Header Block (BE byte-order magic)" {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], pcapng_magic, .big);
    std.mem.writeInt(u32, hdr[4..8], 28, .big);
    // BE byte-order magic: 0x1A2B3C4D stored as bytes 1A 2B 3C 4D
    std.mem.writeInt(u32, hdr[8..12], 0x1A2B3C4D, .big);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcapng, result.format);
}

test "PCAPNG: wrong block type rejected" {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 0xDEADBEEF, .big); // wrong type
    std.mem.writeInt(u32, hdr[4..8], 28, .little);
    std.mem.writeInt(u32, hdr[8..12], 0x1A2B3C4D, .big);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: too small rejected" {
    const tiny = [_]u8{ 0x0A, 0x0D, 0x0D, 0x0A };
    const result = validatePcapngFromBuffer(&tiny);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: invalid byte-order magic rejected" {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], pcapng_magic, .big);
    std.mem.writeInt(u32, hdr[4..8], 28, .little);
    std.mem.writeInt(u32, hdr[8..12], 0xDEADBEEF, .big); // invalid BOM

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}
