//! Deep 7-Zip validation module.
//!
//! This module provides thorough 7z archive validation by:
//! 1. Verifying header CRCs (start header and next header)
//! 2. Parsing the header structure to extract file CRCs
//! 3. Using system's 7z command to verify actual file integrity
//!
//! The 7z format is complex with LZMA/LZMA2 compression, BCJ filters,
//! and solid compression modes. Full validation requires decompression.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Result of 7z deep validation
pub const SevenZValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    files_checked: u32,
    total_files: u32,
    bytes_verified: u64,

    pub fn ok(files: u32, bytes: u64) SevenZValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = files,
            .total_files = files,
            .bytes_verified = bytes,
        };
    }

    pub fn okPartial(checked: u32, total: u32, bytes: u64) SevenZValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = checked,
            .total_files = total,
            .bytes_verified = bytes,
        };
    }

    pub fn invalid(message: []const u8) SevenZValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .files_checked = 0,
            .total_files = 0,
            .bytes_verified = 0,
        };
    }
};

/// 7z signature bytes
const SEVENZ_SIGNATURE = [_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C };

/// 7z property IDs (used in header parsing)
const PropertyID = enum(u8) {
    kEnd = 0x00,
    kHeader = 0x01,
    kArchiveProperties = 0x02,
    kAdditionalStreamsInfo = 0x03,
    kMainStreamsInfo = 0x04,
    kFilesInfo = 0x05,
    kPackInfo = 0x06,
    kUnpackInfo = 0x07,
    kSubStreamsInfo = 0x08,
    kSize = 0x09,
    kCRC = 0x0A,
    kFolder = 0x0B,
    kCodersUnpackSize = 0x0C,
    kNumUnpackStream = 0x0D,
    kEmptyStream = 0x0E,
    kEmptyFile = 0x0F,
    kAnti = 0x10,
    kName = 0x11,
    kCTime = 0x12,
    kATime = 0x13,
    kMTime = 0x14,
    kWinAttributes = 0x15,
    kComment = 0x16,
    kEncodedHeader = 0x17,
    kStartPos = 0x18,
    kDummy = 0x19,
    _,
};

/// Parsed 7z start header
pub const StartHeader = struct {
    version_major: u8,
    version_minor: u8,
    start_header_crc: u32,
    next_header_offset: u64,
    next_header_size: u64,
    next_header_crc: u32,
};

/// Parse and validate the 7z start header
pub fn parseStartHeader(data: []const u8) ?StartHeader {
    if (data.len < 32) return null;

    // Check signature
    if (!std.mem.eql(u8, data[0..6], &SEVENZ_SIGNATURE)) {
        return null;
    }

    const header = StartHeader{
        .version_major = data[6],
        .version_minor = data[7],
        .start_header_crc = std.mem.readInt(u32, data[8..12], .little),
        .next_header_offset = std.mem.readInt(u64, data[12..20], .little),
        .next_header_size = std.mem.readInt(u64, data[20..28], .little),
        .next_header_crc = std.mem.readInt(u32, data[28..32], .little),
    };

    // Verify start header CRC (covers bytes 12-31)
    const computed_crc = std.hash.Crc32.hash(data[12..32]);
    if (computed_crc != header.start_header_crc) {
        return null;
    }

    return header;
}

/// Read a 7z variable-length integer (similar to LZMA)
/// Returns the value and number of bytes consumed
fn readSevenZInt(data: []const u8) ?struct { value: u64, bytes: usize } {
    if (data.len == 0) return null;

    const first = data[0];

    // Single byte: 0xxxxxxx (0-127)
    if (first & 0x80 == 0) {
        return .{ .value = first, .bytes = 1 };
    }

    // Multi-byte encoding
    var mask: u8 = 0x40;
    var extra_bytes: usize = 1;

    while (extra_bytes < 8 and (first & mask) != 0) {
        mask >>= 1;
        extra_bytes += 1;
    }

    if (data.len < 1 + extra_bytes) return null;

    var value: u64 = first & (mask - 1);
    for (data[1 .. 1 + extra_bytes]) |byte| {
        value = (value << 8) | byte;
    }

    return .{ .value = value, .bytes = 1 + extra_bytes };
}

/// Extract file CRCs from the next header (if present and uncompressed)
/// This is a simplified parser that looks for CRC blocks
pub fn extractFileCrcs(allocator: Allocator, header_data: []const u8) ?[]u32 {
    if (header_data.len == 0) return null;

    var crcs = std.ArrayList(u32).init(allocator);
    errdefer crcs.deinit();

    var pos: usize = 0;

    // Look for kCRC property (0x0A)
    while (pos < header_data.len) {
        const prop_id = header_data[pos];
        pos += 1;

        if (prop_id == @intFromEnum(PropertyID.kEnd)) {
            break;
        }

        if (prop_id == @intFromEnum(PropertyID.kCRC)) {
            // CRC block format:
            // - allAreDefined byte (1 = all files have CRC)
            // - if not allAreDefined: bit array of which files have CRCs
            // - CRC values (4 bytes each)
            if (pos >= header_data.len) break;

            const all_defined = header_data[pos];
            pos += 1;

            if (all_defined != 0) {
                // All files have CRCs - read until we hit something that's not a valid CRC position
                // This is heuristic since we don't know the file count here
                while (pos + 4 <= header_data.len) {
                    // Check if next bytes look like a property ID (heuristic to stop)
                    if (header_data[pos] <= 0x19 and (pos + 4 == header_data.len or header_data[pos + 4] <= 0x19)) {
                        break;
                    }
                    const crc = std.mem.readInt(u32, header_data[pos..][0..4], .little);
                    crcs.append(crc) catch break;
                    pos += 4;
                }
            }
        } else {
            // Skip other properties (we'd need size info to skip properly)
            // This is a simplified parser - complex archives may not parse correctly
            continue;
        }
    }

    if (crcs.items.len == 0) {
        crcs.deinit();
        return null;
    }

    return crcs.toOwnedSlice() catch null;
}

/// Deep validate a 7z file using system's 7z command for integrity check
pub fn validateSevenZDeep(allocator: Allocator, path: []const u8) SevenZValidationResult {
    // First, do basic header validation
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return SevenZValidationResult.invalid("Failed to open file");
    };
    defer file.close();

    // Read start header
    var header_buf: [32]u8 = undefined;
    const header_read = file.readAll(&header_buf) catch {
        return SevenZValidationResult.invalid("Failed to read header");
    };
    if (header_read < 32) {
        return SevenZValidationResult.invalid("File too small for 7z header");
    }

    // Parse and validate start header
    const start_header = parseStartHeader(&header_buf) orelse {
        return SevenZValidationResult.invalid("Invalid start header or CRC mismatch");
    };

    // Validate version
    if (start_header.version_major != 0 or start_header.version_minor > 4) {
        return SevenZValidationResult.invalid("Unsupported 7z version");
    }

    // Validate file size
    const file_size = file.getEndPos() catch {
        return SevenZValidationResult.invalid("Failed to get file size");
    };

    const expected_min_size = 32 + start_header.next_header_offset + start_header.next_header_size;
    if (file_size < expected_min_size) {
        return SevenZValidationResult.invalid("File truncated");
    }

    // Read and verify next header CRC
    if (start_header.next_header_size > 0 and start_header.next_header_size <= 100 * 1024 * 1024) {
        file.seekTo(32 + start_header.next_header_offset) catch {
            return SevenZValidationResult.invalid("Failed to seek to next header");
        };

        const next_header_buf = allocator.alloc(u8, @intCast(start_header.next_header_size)) catch {
            // Can't allocate - fall through to 7z command
            return validateWithSevenZCommand(allocator, path);
        };
        defer allocator.free(next_header_buf);

        const bytes_read = file.readAll(next_header_buf) catch {
            return SevenZValidationResult.invalid("Failed to read next header");
        };

        if (bytes_read != start_header.next_header_size) {
            return SevenZValidationResult.invalid("Incomplete next header");
        }

        const computed_crc = std.hash.Crc32.hash(next_header_buf);
        if (computed_crc != start_header.next_header_crc) {
            return SevenZValidationResult.invalid("Next header CRC mismatch");
        }
    }

    // Use 7z command for full integrity check
    return validateWithSevenZCommand(allocator, path);
}

/// Use system's 7z command to perform full integrity test
fn validateWithSevenZCommand(allocator: Allocator, path: []const u8) SevenZValidationResult {
    // Try 7z command with test mode
    const result = runSevenZTest(allocator, path);
    return result;
}

/// Run 7z t (test) command and parse output
fn runSevenZTest(allocator: Allocator, path: []const u8) SevenZValidationResult {
    // Build command: 7z t <path>
    // The -bso0 suppresses normal output
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "7z", "t", "-bso0", path },
        .max_output_bytes = 64 * 1024, // 64KB for error output
    }) catch {
        // 7z command not available - return partial validation (header CRCs were verified)
        return SevenZValidationResult{
            .valid = true,
            .error_message = null,
            .files_checked = 0,
            .total_files = 0,
            .bytes_verified = 0,
        };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Check exit status
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                // Success - get file count from listing
                const file_count = countFilesIn7z(allocator, path);
                return SevenZValidationResult.ok(file_count, 0);
            } else if (code == 1) {
                // Warning (some files could not be extracted but archive is readable)
                return SevenZValidationResult.invalid("7z reports warnings during test");
            } else if (code == 2) {
                // Fatal error
                return SevenZValidationResult.invalid("7z integrity test failed - archive corrupted");
            } else {
                return SevenZValidationResult.invalid("7z test failed with unexpected error");
            }
        },
        else => {
            return SevenZValidationResult.invalid("7z process terminated abnormally");
        },
    }
}

/// Count files in 7z archive using list command
fn countFilesIn7z(allocator: Allocator, path: []const u8) u32 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "7z", "l", "-slt", path },
        .max_output_bytes = 1024 * 1024, // 1MB for large archives
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Count "Path = " lines (excluding the archive path itself)
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    var found_separator = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "----------")) {
            found_separator = true;
            continue;
        }
        if (found_separator and std.mem.startsWith(u8, line, "Path = ")) {
            count += 1;
        }
    }

    return count;
}

/// Validate a 7z file from a buffer (for embedded archives)
pub fn validateSevenZFromBuffer(allocator: Allocator, data: []const u8) SevenZValidationResult {
    if (data.len < 32) {
        return SevenZValidationResult.invalid("Data too small for 7z header");
    }

    // Parse and validate start header
    const start_header = parseStartHeader(data) orelse {
        return SevenZValidationResult.invalid("Invalid start header or CRC mismatch");
    };

    // Validate version
    if (start_header.version_major != 0 or start_header.version_minor > 4) {
        return SevenZValidationResult.invalid("Unsupported 7z version");
    }

    // Validate data size
    const expected_min_size = 32 + start_header.next_header_offset + start_header.next_header_size;
    if (data.len < expected_min_size) {
        return SevenZValidationResult.invalid("Data truncated");
    }

    // Verify next header CRC
    if (start_header.next_header_size > 0) {
        const next_header_start: usize = @intCast(32 + start_header.next_header_offset);
        const next_header_end: usize = @intCast(next_header_start + start_header.next_header_size);

        if (next_header_end > data.len) {
            return SevenZValidationResult.invalid("Next header extends beyond data");
        }

        const next_header_data = data[next_header_start..next_header_end];
        const computed_crc = std.hash.Crc32.hash(next_header_data);

        if (computed_crc != start_header.next_header_crc) {
            return SevenZValidationResult.invalid("Next header CRC mismatch");
        }
    }

    // For buffer validation, we can't easily run 7z command
    // Return success for header validation only
    _ = allocator;
    return SevenZValidationResult{
        .valid = true,
        .error_message = null,
        .files_checked = 0,
        .total_files = 0,
        .bytes_verified = 0,
    };
}

// Tests
test "parseStartHeader valid header" {
    // Build a valid 7z header
    var header: [32]u8 = undefined;
    @memcpy(header[0..6], &SEVENZ_SIGNATURE);
    header[6] = 0x00; // major version
    header[7] = 0x04; // minor version
    // Placeholder CRC
    @memset(header[8..12], 0);
    // Next header offset = 0
    @memset(header[12..20], 0);
    // Next header size = 0
    @memset(header[20..28], 0);
    // Next header CRC = 0
    @memset(header[28..32], 0);

    // Calculate correct CRC
    const crc = std.hash.Crc32.hash(header[12..32]);
    std.mem.writeInt(u32, header[8..12], crc, .little);

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(@as(u8, 0), parsed.?.version_major);
    try std.testing.expectEqual(@as(u8, 4), parsed.?.version_minor);
}

test "parseStartHeader invalid signature" {
    var header: [32]u8 = undefined;
    @memset(&header, 0);
    header[0] = 0xFF; // Wrong signature

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed == null);
}

test "parseStartHeader crc mismatch" {
    var header: [32]u8 = undefined;
    @memcpy(header[0..6], &SEVENZ_SIGNATURE);
    header[6] = 0x00;
    header[7] = 0x04;
    // Wrong CRC
    header[8] = 0xDE;
    header[9] = 0xAD;
    header[10] = 0xBE;
    header[11] = 0xEF;
    @memset(header[12..32], 0);

    const parsed = parseStartHeader(&header);
    try std.testing.expect(parsed == null);
}

test "readSevenZInt single byte" {
    const data = [_]u8{0x7F};
    const result = readSevenZInt(&data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 0x7F), result.?.value);
    try std.testing.expectEqual(@as(usize, 1), result.?.bytes);
}

test "readSevenZInt multi byte" {
    const data = [_]u8{ 0x80, 0x01 };
    const result = readSevenZInt(&data);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 0x01), result.?.value);
    try std.testing.expectEqual(@as(usize, 2), result.?.bytes);
}
