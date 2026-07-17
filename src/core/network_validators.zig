//! Network capture format validators.
//!
//! Supports:
//!   - PCAP (classic libpcap format, all 4 magic variants)
//!   - PCAPNG (next-generation pcap, full block framing walk)

const std = @import("std");
const heap = @import("heap.zig");
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
/// Every PCAPNG block has a type, total length, and duplicate trailing length.
const pcapng_min_block_size: usize = 12;
/// A Section Header Block adds BOM, version, and section-length fields.
const pcapng_min_section_header_size: usize = 28;
/// Byte-order magic interpreted as a big-endian integer.
const pcapng_byte_order_magic: u32 = 0x1A2B3C4D;
const pcapng_byte_order_magic_swapped: u32 = 0x4D3C2B1A;

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

/// Maps a PCAPNG byte-order magic to the endianness of its containing section.
/// Section Header Blocks are self-describing, so multi-section captures may
/// deliberately switch byte order without making their following blocks invalid.
fn pcapngEndianFromBom(bom: []const u8) ?std.builtin.Endian {
    const bom_be = std.mem.readInt(u32, bom[0..4], .big);
    return switch (bom_be) {
        pcapng_byte_order_magic => .big,
        pcapng_byte_order_magic_swapped => .little,
        else => null,
    };
}

/// Validates all PCAPNG block framing in a buffer.
/// It verifies every declared block size and its duplicated trailing length,
/// while intentionally leaving opaque packet payload bytes to packet dissectors.
pub fn validatePcapngFromBuffer(data: []const u8) ValidationResult {
    if (data.len < pcapng_min_section_header_size) {
        return ValidationResult.invalidCode(.pcapng, .file_too_small, "PCAPNG format");
    }

    var offset: usize = 0;
    var endian: std.builtin.Endian = undefined;
    var is_first_block = true;

    while (offset < data.len) {
        const remaining = data.len - offset;
        if (remaining < 8) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated block header");
        }

        // Section Header Block type is byte-order invariant because all four
        // bytes are symmetric. A subsequent SHB begins a new section.
        const is_section_header = std.mem.readInt(u32, data[offset..][0..4], .big) == pcapng_magic;
        if (is_first_block and !is_section_header) {
            return ValidationResult.invalidCode(.pcapng, .invalid_magic, "PCAPNG Section Header Block");
        }

        if (is_section_header) {
            if (remaining < pcapng_min_section_header_size) {
                return ValidationResult.invalid(.pcapng, "PCAPNG truncated Section Header Block");
            }
            endian = pcapngEndianFromBom(data[offset + 8 .. offset + 12]) orelse
                return ValidationResult.invalid(.pcapng, "PCAPNG invalid byte-order magic");
        }

        const total_length = std.mem.readInt(u32, data[offset + 4 .. offset + 8][0..4], endian);
        const total_length_usize: usize = total_length;
        const minimum_length = if (is_section_header) pcapng_min_section_header_size else pcapng_min_block_size;
        if (total_length_usize < minimum_length or total_length_usize % 4 != 0) {
            return ValidationResult.invalid(.pcapng, "PCAPNG invalid block total length");
        }

        const block_end = std.math.add(usize, offset, total_length_usize) catch
            return ValidationResult.invalid(.pcapng, "PCAPNG block total length overflows file");
        if (block_end > data.len) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated block body");
        }

        const trailing_length = std.mem.readInt(u32, data[block_end - 4 .. block_end][0..4], endian);
        if (trailing_length != total_length) {
            return ValidationResult.invalid(.pcapng, "PCAPNG block length does not match trailing length");
        }

        offset = block_end;
        is_first_block = false;
    }

    return ValidationResult.okWithDepth(.pcapng, .structural);
}

/// File-source entry point for PCAP — reads up to the first 64 MiB then delegates.
/// Uses heap allocation: a 64 MiB stack frame overflows on every platform.
pub fn validatePcap(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pcap, .failed_to_seek, "to start");

    const max_pcap_buf: usize = 64 * 1024 * 1024;
    const allocator = heap.validateAllocator();
    const buf = allocator.alloc(u8, max_pcap_buf) catch {
        return ValidationResult.invalidCode(.pcap, .failed_to_allocate, "PCAP buffer");
    };
    defer allocator.free(buf);

    const bytes_read = file.read(buf) catch {
        return ValidationResult.invalidCode(.pcap, .failed_to_read, "PCAP file");
    };

    return validatePcapFromBuffer(buf[0..bytes_read]);
}

/// Walks PCAPNG block framing across an entire file without buffering capture
/// payloads. Each block costs its header, possible Section Header BOM, and
/// trailing length: bounded memory even for multi-gigabyte captures.
pub fn validatePcapng(file: *FileSource) ValidationResult {
    file.seekTo(0) catch return ValidationResult.invalidCode(.pcapng, .failed_to_seek, "to start");

    if (file.file_size < pcapng_min_section_header_size) {
        return ValidationResult.invalidCode(.pcapng, .file_too_small, "PCAPNG format");
    }

    var header: [12]u8 = undefined;
    var trailer: [4]u8 = undefined;
    var offset: u64 = 0;
    var endian: std.builtin.Endian = undefined;
    var is_first_block = true;

    while (offset < file.file_size) {
        const remaining = file.file_size - offset;
        if (remaining < 8) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated block header");
        }

        file.seekTo(offset) catch return ValidationResult.invalidCode(.pcapng, .failed_to_seek, "PCAPNG block header");
        const header_bytes_read = file.readAll(header[0..8]) catch {
            return ValidationResult.invalidCode(.pcapng, .failed_to_read, "PCAPNG block header");
        };
        if (header_bytes_read != 8) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated block header");
        }

        const is_section_header = std.mem.readInt(u32, header[0..4], .big) == pcapng_magic;
        if (is_first_block and !is_section_header) {
            return ValidationResult.invalidCode(.pcapng, .invalid_magic, "PCAPNG Section Header Block");
        }

        if (is_section_header) {
            if (remaining < pcapng_min_section_header_size) {
                return ValidationResult.invalid(.pcapng, "PCAPNG truncated Section Header Block");
            }
            const bom_bytes_read = file.readAll(header[8..12]) catch {
                return ValidationResult.invalidCode(.pcapng, .failed_to_read, "PCAPNG byte-order magic");
            };
            if (bom_bytes_read != 4) {
                return ValidationResult.invalid(.pcapng, "PCAPNG truncated Section Header Block");
            }
            endian = pcapngEndianFromBom(header[8..12]) orelse
                return ValidationResult.invalid(.pcapng, "PCAPNG invalid byte-order magic");
        }

        const total_length = std.mem.readInt(u32, header[4..8], endian);
        const total_length_u64: u64 = total_length;
        const minimum_length: u64 = if (is_section_header) pcapng_min_section_header_size else pcapng_min_block_size;
        if (total_length_u64 < minimum_length or total_length_u64 % 4 != 0) {
            return ValidationResult.invalid(.pcapng, "PCAPNG invalid block total length");
        }

        const block_end = std.math.add(u64, offset, total_length_u64) catch
            return ValidationResult.invalid(.pcapng, "PCAPNG block total length overflows file");
        if (block_end > file.file_size) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated block body");
        }

        file.seekTo(block_end - 4) catch return ValidationResult.invalidCode(.pcapng, .failed_to_seek, "PCAPNG trailing block length");
        const trailer_bytes_read = file.readAll(&trailer) catch {
            return ValidationResult.invalidCode(.pcapng, .failed_to_read, "PCAPNG trailing block length");
        };
        if (trailer_bytes_read != trailer.len) {
            return ValidationResult.invalid(.pcapng, "PCAPNG truncated trailing block length");
        }
        const trailing_length = std.mem.readInt(u32, &trailer, endian);
        if (trailing_length != total_length) {
            return ValidationResult.invalid(.pcapng, "PCAPNG block length does not match trailing length");
        }

        offset = block_end;
        is_first_block = false;
    }

    return ValidationResult.okWithDepth(.pcapng, .structural);
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

/// Appends a standards-shaped Section Header Block for framing tests.
fn appendPcapngSectionHeader(buf: []u8, offset: usize, endian: std.builtin.Endian) usize {
    const end = offset + pcapng_min_section_header_size;
    std.mem.writeInt(u32, buf[offset..][0..4], pcapng_magic, .big);
    std.mem.writeInt(u32, buf[offset + 4 ..][0..4], pcapng_min_section_header_size, endian);
    std.mem.writeInt(u32, buf[offset + 8 ..][0..4], pcapng_byte_order_magic, endian);
    std.mem.writeInt(u16, buf[offset + 12 ..][0..2], 1, endian);
    std.mem.writeInt(u16, buf[offset + 14 ..][0..2], 0, endian);
    std.mem.writeInt(i64, buf[offset + 16 ..][0..8], -1, endian);
    std.mem.writeInt(u32, buf[end - 4 ..][0..4], pcapng_min_section_header_size, endian);
    return end;
}

/// Appends an opaque extension block; only universal PCAPNG framing is asserted.
fn appendPcapngBlock(buf: []u8, offset: usize, block_type: u32, total_length: u32, endian: std.builtin.Endian) usize {
    const end = offset + total_length;
    std.mem.writeInt(u32, buf[offset..][0..4], block_type, endian);
    std.mem.writeInt(u32, buf[offset + 4 ..][0..4], total_length, endian);
    std.mem.writeInt(u32, buf[end - 4 ..][0..4], total_length, endian);
    return end;
}

test "PCAPNG: mismatched trailing block length rejected" {
    // A complete little-endian Section Header Block followed by a complete
    // Interface Description Block.  The duplicate length at the end of the
    // IDB is deliberately corrupt; the former magic/BOM-only validator
    // accepted it, but full framing must reject it.
    var capture: [48]u8 = [_]u8{0} ** 48;
    _ = appendPcapngSectionHeader(&capture, 0, .little);
    _ = appendPcapngBlock(&capture, 28, 1, 20, .little);
    std.mem.writeInt(u32, capture[44..48], 16, .little); // should be 20

    const result = validatePcapngFromBuffer(&capture);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: valid Section Header Block (LE)" {
    var hdr: [pcapng_min_section_header_size]u8 = undefined;
    _ = appendPcapngSectionHeader(&hdr, 0, .little);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcapng, result.format);
}

test "PCAPNG: valid Section Header Block (BE byte-order magic)" {
    var hdr: [pcapng_min_section_header_size]u8 = undefined;
    _ = appendPcapngSectionHeader(&hdr, 0, .big);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(result.is_valid);
    try testing.expectEqual(FileFormat.pcapng, result.format);
}

test "PCAPNG: extension blocks and a later section may change byte order" {
    var capture: [28 + 12 + 28]u8 = [_]u8{0} ** (28 + 12 + 28);
    var offset = appendPcapngSectionHeader(&capture, 0, .little);
    offset = appendPcapngBlock(&capture, offset, 0x0000BEEF, pcapng_min_block_size, .little);
    offset = appendPcapngSectionHeader(&capture, offset, .big);

    try testing.expectEqual(capture.len, offset);
    const result = validatePcapngFromBuffer(&capture);
    try testing.expect(result.is_valid);
}

test "PCAPNG: file source reaches corrupt framing beyond its old 4 KiB window" {
    const extension_length = 4096;
    var capture: [pcapng_min_section_header_size + extension_length]u8 = [_]u8{0} ** (pcapng_min_section_header_size + extension_length);
    const extension_offset = appendPcapngSectionHeader(&capture, 0, .little);
    _ = appendPcapngBlock(&capture, extension_offset, 0x0000BEEF, extension_length, .little);
    std.mem.writeInt(u32, capture[capture.len - 4 .. capture.len], extension_length - 4, .little);

    var source = FileSource.fromBuffer(&capture);
    const result = validatePcapng(&source);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: wrong block type rejected" {
    var hdr: [pcapng_min_section_header_size]u8 = [_]u8{0} ** pcapng_min_section_header_size;
    std.mem.writeInt(u32, hdr[0..4], 0xDEADBEEF, .big); // wrong type
    std.mem.writeInt(u32, hdr[4..8], 28, .little);
    std.mem.writeInt(u32, hdr[8..12], pcapng_byte_order_magic, .little);
    std.mem.writeInt(u32, hdr[24..28], 28, .little);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: too small rejected" {
    const tiny = [_]u8{ 0x0A, 0x0D, 0x0D, 0x0A };
    const result = validatePcapngFromBuffer(&tiny);
    try testing.expect(!result.is_valid);
}

test "PCAPNG: invalid byte-order magic rejected" {
    var hdr: [pcapng_min_section_header_size]u8 = [_]u8{0} ** pcapng_min_section_header_size;
    std.mem.writeInt(u32, hdr[0..4], pcapng_magic, .big);
    std.mem.writeInt(u32, hdr[4..8], 28, .little);
    std.mem.writeInt(u32, hdr[8..12], 0xDEADBEEF, .big); // invalid BOM
    std.mem.writeInt(u32, hdr[24..28], 28, .little);

    const result = validatePcapngFromBuffer(&hdr);
    try testing.expect(!result.is_valid);
}
