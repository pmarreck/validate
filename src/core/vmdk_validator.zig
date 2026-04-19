//! VMDK Virtual Disk Validator (Pure Zig)
//!
//! Validates VMware Virtual Machine Disk (VMDK) files by inspecting
//! the binary header of sparse extents and text descriptor files.
//!
//! Three sub-formats are recognized:
//!   - Hosted Sparse (VMDK4): binary header with magic 0x564D444B ("VMDK" LE)
//!   - COWD (ESXi Sparse): binary header with magic 0x44574F43 ("COWD" LE)
//!   - Descriptor-only: text file beginning with "# Disk DescriptorFile"
//!
//! References:
//!   - VMware Virtual Disk Format 1.1 specification
//!   - Open Virtualization Format (OVF) standard

const std = @import("std");
const fv = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

// ============================================================================
// Constants
// ============================================================================

/// VMDK4 (Hosted Sparse) magic number — little-endian u32 at offset 0.
/// Bytes on disk: 4B 44 4D 56 → "KDMV" in ASCII, = 0x564D444B as LE u32.
pub const VMDK4_MAGIC: u32 = 0x564D444B;

/// COWD (ESXi Sparse) magic number — little-endian u32 at offset 0.
/// Bytes on disk: 43 4F 57 44 → "COWD" in ASCII.
pub const COWD_MAGIC: u32 = 0x44574F43;

/// Size of the VMDK4 binary header, in bytes.
pub const VMDK4_HEADER_SIZE: usize = 512;

/// Required value for numGTEsPerGT in a VMDK4 header.
pub const VMDK4_NUM_GTES_PER_GT: u32 = 512;

/// GD_AT_END sentinel: gdOffset field value meaning GD is appended after data.
pub const VMDK4_GD_AT_END: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Minimum COWD header size (2 KiB).
pub const COWD_HEADER_SIZE: usize = 2048;

/// Prefix that identifies a descriptor-only VMDK text file.
pub const DESCRIPTOR_HEADER: []const u8 = "# Disk DescriptorFile";

/// Flag bit: new-line detection field is valid.
pub const FLAG_NEWLINE_DETECT: u32 = 1 << 0;

/// Flag bit: redundant grain directory (RGD) is present.
pub const FLAG_RGD_PRESENT: u32 = 1 << 1;

/// Flag bit: extents use DEFLATE compression.
pub const FLAG_COMPRESSED: u32 = 1 << 16;

/// Flag bit: stream-optimized markers present.
pub const FLAG_MARKERS: u32 = 1 << 17;

// ============================================================================
// Result types
// ============================================================================

/// Sub-format detected in a VMDK file.
pub const VmdkSubFormat = enum {
    /// Hosted Sparse extent (workstation, server VMDKs)
    vmdk4,
    /// ESXi Sparse extent
    cowd,
    /// Text descriptor file (no binary extent data in this file)
    descriptor,
};

/// Compression algorithm field in a VMDK4 header.
pub const VmdkCompression = enum(u16) {
    none = 0,
    deflate = 1,
    _,
};

/// Parsed fields from a VMDK4 binary header.
pub const Vmdk4Header = struct {
    magic: u32,
    version: u32,
    flags: u32,
    capacity: u64,
    grain_size: u64,
    descriptor_offset: u64,
    descriptor_size: u64,
    num_gtes_per_gt: u32,
    rgd_offset: u64,
    gd_offset: u64,
    over_head: u64,
    unclean_shutdown: u8,
    newline_detector: [4]u8,
    compress_algorithm: VmdkCompression,

    /// Returns true if the redundant grain directory flag is set.
    pub fn hasRgd(self: Vmdk4Header) bool {
        return (self.flags & FLAG_RGD_PRESENT) != 0;
    }

    /// Returns true if DEFLATE compression is indicated.
    pub fn isCompressed(self: Vmdk4Header) bool {
        return (self.flags & FLAG_COMPRESSED) != 0 or
            self.compress_algorithm == .deflate;
    }

    /// Returns true if the GD is appended after data (stream-optimized).
    pub fn isStreamOptimized(self: Vmdk4Header) bool {
        return self.gd_offset == VMDK4_GD_AT_END;
    }
};

/// Parsed fields from a COWD binary header.
pub const CowdHeader = struct {
    magic: u32,
    version: u32,
    flags: u32,
    num_sectors: u32,
    grain_size: u32,
    gd_offset: u32,
    num_gd_entries: u32,
};

/// Validation result for a VMDK file.
pub const VmdkValidationResult = struct {
    /// Whether the file is structurally valid.
    valid: bool,
    /// Human-readable error string, or null if valid.
    error_message: ?[]const u8,
    /// Detected sub-format.
    sub_format: VmdkSubFormat,
    /// True when the uncleanShutdown byte is non-zero (disk was not safely ejected).
    unclean_shutdown: bool,
    /// True when GD/RGD parity was checked (deep validation).
    gd_verified: bool,

    /// Construct a successful result.
    pub fn ok(sub_fmt: VmdkSubFormat, unclean: bool, gd_ok: bool) VmdkValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .sub_format = sub_fmt,
            .unclean_shutdown = unclean,
            .gd_verified = gd_ok,
        };
    }

    /// Construct a failure result.
    pub fn invalid(msg: []const u8) VmdkValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .sub_format = .descriptor, // placeholder
            .unclean_shutdown = false,
            .gd_verified = false,
        };
    }

    /// Convert to the standard ValidationResult for the dispatch layer.
    pub fn toValidationResult(self: VmdkValidationResult) fv.ValidationResult {
        if (!self.valid) {
            return fv.ValidationResult.invalidWithDepth(.vmdk, self.error_message orelse "VMDK validation failed", .structural);
        }
        var result = fv.ValidationResult.okWithDepth(.vmdk, .structural);
        if (self.unclean_shutdown) {
            result.malformations.insert(.extension_mismatch); // Reuse as "dirty" indicator
        }
        return result;
    }
};

// ============================================================================
// Parsing helpers
// ============================================================================

/// Parse a VMDK4 binary header from a 512-byte buffer.
/// Returns null if the magic number does not match.
pub fn parseVmdk4Header(buf: []const u8) ?Vmdk4Header {
    if (buf.len < VMDK4_HEADER_SIZE) return null;
    const magic = std.mem.readInt(u32, buf[0..4], .little);
    if (magic != VMDK4_MAGIC) return null;

    return Vmdk4Header{
        .magic = magic,
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .flags = std.mem.readInt(u32, buf[8..12], .little),
        .capacity = std.mem.readInt(u64, buf[12..20], .little),
        .grain_size = std.mem.readInt(u64, buf[20..28], .little),
        .descriptor_offset = std.mem.readInt(u64, buf[28..36], .little),
        .descriptor_size = std.mem.readInt(u64, buf[36..44], .little),
        .num_gtes_per_gt = std.mem.readInt(u32, buf[44..48], .little),
        .rgd_offset = std.mem.readInt(u64, buf[48..56], .little),
        .gd_offset = std.mem.readInt(u64, buf[56..64], .little),
        .over_head = std.mem.readInt(u64, buf[64..72], .little),
        .unclean_shutdown = buf[72],
        .newline_detector = buf[73..77].*,
        .compress_algorithm = @enumFromInt(std.mem.readInt(u16, buf[77..79], .little)),
    };
}

/// Parse a COWD binary header from a buffer of at least 28 bytes.
/// Returns null if the magic number does not match.
pub fn parseCowdHeader(buf: []const u8) ?CowdHeader {
    if (buf.len < 28) return null;
    const magic = std.mem.readInt(u32, buf[0..4], .little);
    if (magic != COWD_MAGIC) return null;

    return CowdHeader{
        .magic = magic,
        .version = std.mem.readInt(u32, buf[4..8], .little),
        .flags = std.mem.readInt(u32, buf[8..12], .little),
        .num_sectors = std.mem.readInt(u32, buf[12..16], .little),
        .grain_size = std.mem.readInt(u32, buf[16..20], .little),
        .gd_offset = std.mem.readInt(u32, buf[20..24], .little),
        .num_gd_entries = std.mem.readInt(u32, buf[24..28], .little),
    };
}

// ============================================================================
// Core validation logic
// ============================================================================

/// Validate a VMDK4 header for internal consistency.
/// Returns an error string on failure, or null on success.
/// `file_size` is used to sanity-check metadata fields (0 = skip size checks).
fn validateVmdk4Fields(hdr: Vmdk4Header, file_size: u64) ?[]const u8 {
    // Version must be 1, 2, or 3.
    if (hdr.version < 1 or hdr.version > 3) {
        return "VMDK4: unsupported version (expected 1-3)";
    }

    // Capacity must be positive (zero-sector disk is invalid).
    if (hdr.capacity == 0) {
        return "VMDK4: capacity is zero";
    }

    // grainSize must be a power of two and in [1, 128].
    const gs = hdr.grain_size;
    if (gs == 0 or gs > 128 or (gs & (gs - 1)) != 0) {
        return "VMDK4: grainSize is not a power of 2 in [1, 128]";
    }

    // numGTEsPerGT must be 512 (required by VMware spec).
    if (hdr.num_gtes_per_gt != VMDK4_NUM_GTES_PER_GT) {
        return "VMDK4: numGTEsPerGT must be 512";
    }

    // Newline detection bytes: if FLAG_NEWLINE_DETECT is set, expect \n \x20 \r \n.
    if ((hdr.flags & FLAG_NEWLINE_DETECT) != 0) {
        const expected_nl = [4]u8{ '\n', ' ', '\r', '\n' };
        if (!std.mem.eql(u8, &hdr.newline_detector, &expected_nl)) {
            return "VMDK4: newline detection bytes are corrupt";
        }
    }

    // overHead * 512 must not exceed file size (if we know file size).
    if (file_size > 0 and !hdr.isStreamOptimized()) {
        const metadata_bytes = hdr.over_head *| 512; // saturating mul
        if (metadata_bytes > file_size) {
            return "VMDK4: overHead exceeds file size";
        }
    }

    // Padding bytes 79-511 should be zero.  We check only what we have.
    // (This is advisory — some tools leave garbage; we treat it as a warning
    //  category but do not fail on it to preserve interoperability.)

    return null; // All checks passed.
}

/// Validate a COWD header for internal consistency.
fn validateCowdFields(hdr: CowdHeader) ?[]const u8 {
    if (hdr.version != 1) {
        return "COWD: version must be 1";
    }
    if (hdr.flags != 3) {
        return "COWD: flags must be 3";
    }
    // GD is always at sector 4 for COWD.
    if (hdr.gd_offset != 4) {
        return "COWD: grain directory must be at sector 4";
    }
    return null;
}

/// Parse a VMDK text descriptor from a buffer.
/// Checks for the required "# Disk DescriptorFile" first line and validates
/// a minimal set of key-value pairs (version, CID).
/// Returns an error string on failure, or null on success.
fn validateDescriptorBuffer(buf: []const u8) ?[]const u8 {
    // Must start with the canonical header comment.
    if (!std.mem.startsWith(u8, buf, DESCRIPTOR_HEADER)) {
        return "VMDK descriptor: missing '# Disk DescriptorFile' header";
    }

    var found_version = false;
    var found_cid = false;

    var lines = std.mem.splitScalar(u8, buf, '\n');
    while (lines.next()) |raw_line| {
        // Strip trailing \r if present.
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Check for version= key.
        if (std.mem.startsWith(u8, line, "version=")) {
            found_version = true;
            const val = std.mem.trimLeft(u8, line[8..], " \t");
            if (val.len == 0) return "VMDK descriptor: empty version field";
        }

        // Check for CID= (Content ID — a hex number).
        if (std.mem.startsWith(u8, line, "CID=")) {
            found_cid = true;
            const val = std.mem.trimLeft(u8, line[4..], " \t");
            if (val.len == 0) return "VMDK descriptor: empty CID field";
            // CID should be 8 hex digits.
            for (val) |ch| {
                if (!std.ascii.isHex(ch)) return "VMDK descriptor: CID is not a valid hex value";
            }
        }
    }

    if (!found_version) return "VMDK descriptor: missing 'version' key";
    if (!found_cid) return "VMDK descriptor: missing 'CID' key";

    return null;
}

// ============================================================================
// Public validators
// ============================================================================

/// Validate a VMDK file from a byte slice (buffer-based).
/// Performs structural validation of the header/descriptor.
/// `file_size` should be the total file size for metadata bounds checking,
/// or 0 to skip file-size-dependent checks (e.g. when buf is a partial read).
pub fn validateVmdkBuffer(buf: []const u8, file_size: u64) VmdkValidationResult {
    if (buf.len < 4) {
        return VmdkValidationResult.invalid("VMDK: file too small for header");
    }

    // --- Attempt VMDK4 binary header ---
    if (parseVmdk4Header(buf)) |hdr| {
        if (validateVmdk4Fields(hdr, file_size)) |err| {
            return VmdkValidationResult.invalid(err);
        }
        const unclean = hdr.unclean_shutdown != 0;
        return VmdkValidationResult.ok(.vmdk4, unclean, false);
    }

    // --- Attempt COWD binary header ---
    if (parseCowdHeader(buf)) |hdr| {
        if (validateCowdFields(hdr)) |err| {
            return VmdkValidationResult.invalid(err);
        }
        return VmdkValidationResult.ok(.cowd, false, false);
    }

    // --- Attempt text descriptor ---
    // Descriptors are printable UTF-8; ensure no embedded NULs in first 4 bytes.
    if (buf[0] != 0 and buf[1] != 0) {
        const text_len = @min(buf.len, 4096);
        if (validateDescriptorBuffer(buf[0..text_len])) |err| {
            return VmdkValidationResult.invalid(err);
        }
        return VmdkValidationResult.ok(.descriptor, false, false);
    }

    return VmdkValidationResult.invalid("VMDK: unrecognized format (not VMDK4, COWD, or descriptor)");
}

/// Validate a VMDK file from a FileSource (streaming).
/// Reads the first 512 bytes and delegates to validateVmdkBuffer.
pub fn validateVmdk(file: *FileSource) VmdkValidationResult {
    const file_size = file.getEndPos() catch 0;

    if (file_size < 4) {
        return VmdkValidationResult.invalid("VMDK: file too small");
    }

    file.seekTo(0) catch {
        return VmdkValidationResult.invalid("VMDK: failed to seek to start");
    };

    var header_buf: [VMDK4_HEADER_SIZE]u8 = undefined;
    const bytes_read = file.readAll(&header_buf) catch {
        return VmdkValidationResult.invalid("VMDK: failed to read header");
    };

    if (bytes_read < 4) {
        return VmdkValidationResult.invalid("VMDK: header read too short");
    }

    return validateVmdkBuffer(header_buf[0..bytes_read], file_size);
}

/// Deep-validate a VMDK file by path.
/// Currently performs the same structural checks as validateVmdk, plus a
/// GD/RGD offset bounds check for VMDK4 sparse extents when the RGD flag is set.
pub fn validateVmdkDeep(allocator: std.mem.Allocator, source: *FileSource) VmdkValidationResult {
    _ = allocator; // reserved for future GD/RGT traversal

    const file_size = source.getEndPos() catch 0;

    source.seekTo(0) catch {
        return VmdkValidationResult.invalid("VMDK: failed to seek to start");
    };

    var header_buf: [VMDK4_HEADER_SIZE]u8 = undefined;
    const bytes_read = source.readAll(&header_buf) catch {
        return VmdkValidationResult.invalid("VMDK: failed to read header");
    };

    if (bytes_read < 4) {
        return VmdkValidationResult.invalid("VMDK: header read too short");
    }

    const result = validateVmdkBuffer(header_buf[0..bytes_read], file_size);
    if (!result.valid) return result;

    // Deep: for VMDK4, verify that RGD and GD offsets are within file bounds.
    if (result.sub_format == .vmdk4) {
        if (parseVmdk4Header(&header_buf)) |hdr| {
            if (hdr.hasRgd() and file_size > 0) {
                // Each offset is in 512-byte sectors; the GD occupies at least 1 sector.
                const rgd_byte = hdr.rgd_offset *| 512;
                if (rgd_byte >= file_size) {
                    return VmdkValidationResult.invalid("VMDK4: RGD offset is past end of file");
                }
                if (!hdr.isStreamOptimized()) {
                    const gd_byte = hdr.gd_offset *| 512;
                    if (gd_byte >= file_size) {
                        return VmdkValidationResult.invalid("VMDK4: GD offset is past end of file");
                    }
                }
                return VmdkValidationResult.ok(.vmdk4, hdr.unclean_shutdown != 0, true);
            }
        }
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "parseVmdk4Header - rejects wrong magic" {
    var buf: [VMDK4_HEADER_SIZE]u8 = [_]u8{0} ** VMDK4_HEADER_SIZE;
    buf[0] = 0xDE;
    buf[1] = 0xAD;
    buf[2] = 0xBE;
    buf[3] = 0xEF;
    try std.testing.expectEqual(@as(?Vmdk4Header, null), parseVmdk4Header(&buf));
}

test "parseVmdk4Header - accepts valid magic and parses fields" {
    var buf: [VMDK4_HEADER_SIZE]u8 = [_]u8{0} ** VMDK4_HEADER_SIZE;
    // Magic: 0x564D444B little-endian → bytes 4B 44 4D 56
    std.mem.writeInt(u32, buf[0..4], VMDK4_MAGIC, .little);
    // version = 1
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    // flags = FLAG_RGD_PRESENT | FLAG_NEWLINE_DETECT
    std.mem.writeInt(u32, buf[8..12], FLAG_RGD_PRESENT | FLAG_NEWLINE_DETECT, .little);
    // capacity = 2048 sectors (1 MiB)
    std.mem.writeInt(u64, buf[12..20], 2048, .little);
    // grainSize = 128 (power of 2, max)
    std.mem.writeInt(u64, buf[20..28], 128, .little);
    // numGTEsPerGT = 512
    std.mem.writeInt(u32, buf[44..48], 512, .little);
    // newline detector bytes
    buf[73] = '\n';
    buf[74] = ' ';
    buf[75] = '\r';
    buf[76] = '\n';

    const hdr = parseVmdk4Header(&buf);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(@as(u32, 1), hdr.?.version);
    try std.testing.expectEqual(@as(u64, 2048), hdr.?.capacity);
    try std.testing.expectEqual(@as(u64, 128), hdr.?.grain_size);
    try std.testing.expect(hdr.?.hasRgd());
}

test "parseCowdHeader - rejects wrong magic" {
    var buf: [COWD_HEADER_SIZE]u8 = [_]u8{0} ** COWD_HEADER_SIZE;
    try std.testing.expectEqual(@as(?CowdHeader, null), parseCowdHeader(&buf));
}

test "parseCowdHeader - accepts valid COWD header" {
    var buf: [COWD_HEADER_SIZE]u8 = [_]u8{0} ** COWD_HEADER_SIZE;
    std.mem.writeInt(u32, buf[0..4], COWD_MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little); // version
    std.mem.writeInt(u32, buf[8..12], 3, .little); // flags
    std.mem.writeInt(u32, buf[12..16], 2048, .little); // numSectors
    std.mem.writeInt(u32, buf[16..20], 128, .little); // grainSize
    std.mem.writeInt(u32, buf[20..24], 4, .little); // gdOffset = sector 4
    std.mem.writeInt(u32, buf[24..28], 512, .little); // numGDEntries

    const hdr = parseCowdHeader(&buf);
    try std.testing.expect(hdr != null);
    try std.testing.expectEqual(@as(u32, 1), hdr.?.version);
    try std.testing.expectEqual(@as(u32, 3), hdr.?.flags);
    try std.testing.expectEqual(@as(u32, 4), hdr.?.gd_offset);
}

test "validateVmdk4Fields - rejects version 0" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 0,
        .flags = 0,
        .capacity = 2048,
        .grain_size = 128,
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 0,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    try std.testing.expect(validateVmdk4Fields(hdr, 0) != null);
}

test "validateVmdk4Fields - rejects zero capacity" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = 0,
        .capacity = 0,
        .grain_size = 128,
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 0,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    try std.testing.expect(validateVmdk4Fields(hdr, 0) != null);
}

test "validateVmdk4Fields - rejects non-power-of-2 grainSize" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = 0,
        .capacity = 2048,
        .grain_size = 100, // not a power of 2
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 0,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    try std.testing.expect(validateVmdk4Fields(hdr, 0) != null);
}

test "validateVmdk4Fields - rejects wrong numGTEsPerGT" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = 0,
        .capacity = 2048,
        .grain_size = 128,
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 256, // must be 512
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 0,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    try std.testing.expect(validateVmdk4Fields(hdr, 0) != null);
}

test "validateVmdk4Fields - valid header passes all checks" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = 0,
        .capacity = 2048,
        .grain_size = 128,
        .descriptor_offset = 1,
        .descriptor_size = 20,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 128,
        .over_head = 128,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), validateVmdk4Fields(hdr, 0));
}

test "validateVmdk4Fields - detects corrupt newline bytes when flag set" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = FLAG_NEWLINE_DETECT,
        .capacity = 2048,
        .grain_size = 128,
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 0,
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0x0D, 0x0A, 0x0D, 0x0A }, // wrong — not \n \x20 \r \n
        .compress_algorithm = .none,
    };
    try std.testing.expect(validateVmdk4Fields(hdr, 0) != null);
}

test "validateVmdk4Fields - overHead exceeds file size" {
    const hdr = Vmdk4Header{
        .magic = VMDK4_MAGIC,
        .version = 1,
        .flags = 0,
        .capacity = 2048,
        .grain_size = 128,
        .descriptor_offset = 0,
        .descriptor_size = 0,
        .num_gtes_per_gt = 512,
        .rgd_offset = 0,
        .gd_offset = 0,
        .over_head = 1000, // 1000 * 512 = 512000 bytes
        .unclean_shutdown = 0,
        .newline_detector = [4]u8{ 0, 0, 0, 0 },
        .compress_algorithm = .none,
    };
    // File size smaller than overHead * 512
    try std.testing.expect(validateVmdk4Fields(hdr, 1024) != null);
}

test "validateCowdFields - rejects version != 1" {
    const hdr = CowdHeader{
        .magic = COWD_MAGIC,
        .version = 2,
        .flags = 3,
        .num_sectors = 2048,
        .grain_size = 128,
        .gd_offset = 4,
        .num_gd_entries = 512,
    };
    try std.testing.expect(validateCowdFields(hdr) != null);
}

test "validateCowdFields - rejects flags != 3" {
    const hdr = CowdHeader{
        .magic = COWD_MAGIC,
        .version = 1,
        .flags = 0,
        .num_sectors = 2048,
        .grain_size = 128,
        .gd_offset = 4,
        .num_gd_entries = 512,
    };
    try std.testing.expect(validateCowdFields(hdr) != null);
}

test "validateCowdFields - rejects gd_offset != 4" {
    const hdr = CowdHeader{
        .magic = COWD_MAGIC,
        .version = 1,
        .flags = 3,
        .num_sectors = 2048,
        .grain_size = 128,
        .gd_offset = 8, // must be 4
        .num_gd_entries = 512,
    };
    try std.testing.expect(validateCowdFields(hdr) != null);
}

test "validateDescriptorBuffer - accepts valid descriptor" {
    const desc =
        \\# Disk DescriptorFile
        \\version=1
        \\CID=aabbccdd
        \\parentCID=ffffffff
        \\createType="monolithicSparse"
        \\
        \\# Extent description
        \\RW 2048 SPARSE "sample.vmdk"
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), validateDescriptorBuffer(desc));
}

test "validateDescriptorBuffer - rejects missing header comment" {
    const desc = "version=1\nCID=aabbccdd\n";
    try std.testing.expect(validateDescriptorBuffer(desc) != null);
}

test "validateDescriptorBuffer - rejects missing CID" {
    const desc = "# Disk DescriptorFile\nversion=1\n";
    try std.testing.expect(validateDescriptorBuffer(desc) != null);
}

test "validateDescriptorBuffer - rejects missing version" {
    const desc = "# Disk DescriptorFile\nCID=aabbccdd\n";
    try std.testing.expect(validateDescriptorBuffer(desc) != null);
}

test "validateDescriptorBuffer - rejects non-hex CID" {
    const desc = "# Disk DescriptorFile\nversion=1\nCID=GGGGGGGG\n";
    try std.testing.expect(validateDescriptorBuffer(desc) != null);
}

test "validateVmdkBuffer - valid VMDK4 buffer" {
    var buf: [VMDK4_HEADER_SIZE]u8 = [_]u8{0} ** VMDK4_HEADER_SIZE;
    std.mem.writeInt(u32, buf[0..4], VMDK4_MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u64, buf[12..20], 2048, .little);
    std.mem.writeInt(u64, buf[20..28], 128, .little);
    std.mem.writeInt(u32, buf[44..48], 512, .little);

    const result = validateVmdkBuffer(&buf, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(VmdkSubFormat.vmdk4, result.sub_format);
    try std.testing.expect(!result.unclean_shutdown);
}

test "validateVmdkBuffer - detects unclean shutdown" {
    var buf: [VMDK4_HEADER_SIZE]u8 = [_]u8{0} ** VMDK4_HEADER_SIZE;
    std.mem.writeInt(u32, buf[0..4], VMDK4_MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u64, buf[12..20], 2048, .little);
    std.mem.writeInt(u64, buf[20..28], 128, .little);
    std.mem.writeInt(u32, buf[44..48], 512, .little);
    buf[72] = 1; // uncleanShutdown = 1

    const result = validateVmdkBuffer(&buf, 0);
    try std.testing.expect(result.valid); // still valid — unclean is a warning
    try std.testing.expect(result.unclean_shutdown);
}

test "validateVmdkBuffer - valid COWD buffer" {
    var buf: [COWD_HEADER_SIZE]u8 = [_]u8{0} ** COWD_HEADER_SIZE;
    std.mem.writeInt(u32, buf[0..4], COWD_MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 3, .little);
    std.mem.writeInt(u32, buf[12..16], 2048, .little);
    std.mem.writeInt(u32, buf[16..20], 128, .little);
    std.mem.writeInt(u32, buf[20..24], 4, .little);
    std.mem.writeInt(u32, buf[24..28], 512, .little);

    const result = validateVmdkBuffer(&buf, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(VmdkSubFormat.cowd, result.sub_format);
}

test "validateVmdkBuffer - valid descriptor buffer" {
    const desc =
        \\# Disk DescriptorFile
        \\version=1
        \\CID=aabbccdd
        \\parentCID=ffffffff
        \\createType="monolithicSparse"
    ;
    const result = validateVmdkBuffer(desc, 0);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(VmdkSubFormat.descriptor, result.sub_format);
}

test "validateVmdkBuffer - rejects unrecognized format" {
    const garbage = "garbage data here xxx";
    const result = validateVmdkBuffer(garbage, 0);
    try std.testing.expect(!result.valid);
}

test "validateVmdkBuffer - corrupt VMDK4 capacity zero" {
    var buf: [VMDK4_HEADER_SIZE]u8 = [_]u8{0} ** VMDK4_HEADER_SIZE;
    std.mem.writeInt(u32, buf[0..4], VMDK4_MAGIC, .little);
    std.mem.writeInt(u32, buf[4..8], 1, .little);
    std.mem.writeInt(u32, buf[8..12], 0, .little);
    std.mem.writeInt(u64, buf[12..20], 0, .little); // capacity = 0 (invalid)
    std.mem.writeInt(u64, buf[20..28], 128, .little);
    std.mem.writeInt(u32, buf[44..48], 512, .little);

    const result = validateVmdkBuffer(&buf, 0);
    try std.testing.expect(!result.valid);
}

test "ground truth - VMDK sample" {
    var source = FileSource.open("ground_truth_examples/vmdk/sample.vmdk") catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer source.close();

    const result = validateVmdk(&source);
    try std.testing.expect(result.valid);
}
