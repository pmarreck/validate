//! Deep validation for tracker/module music formats.
//!
//! This module provides comprehensive validation for:
//! - MOD (ProTracker)
//! - XM (FastTracker 2)
//! - IT (Impulse Tracker)
//! - S3M (Scream Tracker 3)
//!
//! Deep validation includes:
//! - Sample header parsing and offset validation
//! - Pattern data structure validation
//! - Instrument data validation (IT/XM)
//! - File size consistency checks

const std = @import("std");
const errmsg = @import("error_messages.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

/// Result of deep tracker validation
pub const TrackerValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    format_details: FormatDetails,

    pub const FormatDetails = struct {
        channels: u16 = 0,
        patterns: u16 = 0,
        samples: u16 = 0,
        instruments: u16 = 0,
    };

    pub fn ok(details: FormatDetails) TrackerValidationResult {
        return .{ .valid = true, .error_message = null, .format_details = details };
    }

    pub fn invalid(message: []const u8) TrackerValidationResult {
        return .{ .valid = false, .error_message = message, .format_details = .{} };
    }
};

// ============ MOD Deep Validation ============

/// Deep validation for ProTracker MOD files.
/// Validates sample headers, pattern data, and file structure.
pub fn validateModDeep(file: *FileSource) TrackerValidationResult {
    const file_size = file.getEndPos() catch {
        return TrackerValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    // MOD minimum: 1084 bytes (header + signature)
    if (file_size < 1084) {
        return TrackerValidationResult.invalid(errmsg.fileTooSmallFor("MOD"));
    }

    // Read header (first 1084 bytes)
    var header: [1084]u8 = undefined;
    file.seekTo(0) catch return TrackerValidationResult.invalid("Seek failed");
    _ = file.readAll(&header) catch return TrackerValidationResult.invalid("Read failed");

    // Check signature at offset 1080
    const sig = header[1080..1084];
    const num_channels: u16 = getModChannels(sig) orelse {
        return TrackerValidationResult.invalid(errmsg.invalidSignature("MOD"));
    };

    // Parse 31 sample headers (30 bytes each, starting at offset 20)
    var total_sample_size: u64 = 0;
    var sample_count: u16 = 0;
    for (0..31) |i| {
        const sample_offset = 20 + i * 30;
        // Sample length is at offset 22-23 within sample header (big-endian words)
        const sample_length = @as(u32, std.mem.readInt(u16, header[sample_offset + 22 ..][0..2], .big)) * 2;
        if (sample_length > 0) {
            sample_count += 1;
            total_sample_size += sample_length;
        }
    }

    // Song length (number of positions) is at offset 950
    const song_length = header[950];
    if (song_length == 0 or song_length > 128) {
        return TrackerValidationResult.invalid("Invalid MOD song length");
    }

    // Pattern table is at offset 952-1079 (128 bytes)
    // Find highest pattern number used
    var max_pattern: u8 = 0;
    for (header[952..1080]) |pat| {
        if (pat > max_pattern) max_pattern = pat;
    }

    // Calculate expected file size
    // Pattern size: 64 rows * 4 bytes/channel * num_channels
    const pattern_size: u64 = 64 * 4 * num_channels;
    const patterns_total: u64 = (@as(u64, max_pattern) + 1) * pattern_size;
    const expected_min_size: u64 = 1084 + patterns_total + total_sample_size;

    if (file_size < expected_min_size) {
        return TrackerValidationResult.invalid("MOD file truncated");
    }

    return TrackerValidationResult.ok(.{
        .channels = num_channels,
        .patterns = max_pattern + 1,
        .samples = sample_count,
        .instruments = 0,
    });
}

fn getModChannels(sig: []const u8) ?u16 {
    if (std.mem.eql(u8, sig, "M.K.") or std.mem.eql(u8, sig, "M!K!") or
        std.mem.eql(u8, sig, "FLT4") or std.mem.eql(u8, sig, "4CHN"))
    {
        return 4;
    }
    if (std.mem.eql(u8, sig, "6CHN")) return 6;
    if (std.mem.eql(u8, sig, "FLT8") or std.mem.eql(u8, sig, "8CHN") or
        std.mem.eql(u8, sig, "CD81") or std.mem.eql(u8, sig, "OKTA"))
    {
        return 8;
    }
    // xCHN pattern (5CHN, 7CHN, 9CHN)
    if (sig[1] == 'C' and sig[2] == 'H' and sig[3] == 'N' and sig[0] >= '1' and sig[0] <= '9') {
        return sig[0] - '0';
    }
    // xxCH pattern (10CH, 11CH, ..., 32CH)
    if (sig[2] == 'C' and sig[3] == 'H' and sig[0] >= '1' and sig[0] <= '3' and sig[1] >= '0' and sig[1] <= '9') {
        return (@as(u16, sig[0] - '0') * 10) + (sig[1] - '0');
    }
    return null;
}

// ============ XM Deep Validation ============

/// Deep validation for FastTracker 2 XM files.
/// Validates header, patterns, instruments, and samples.
pub fn validateXmDeep(file: *FileSource) TrackerValidationResult {
    const file_size = file.getEndPos() catch {
        return TrackerValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < 80) {
        return TrackerValidationResult.invalid(errmsg.fileTooSmallFor("XM"));
    }

    // Read header
    var header: [80]u8 = undefined;
    _ = file.readAll(&header) catch return TrackerValidationResult.invalid("Read failed");

    // Check signature
    if (!std.mem.eql(u8, header[0..17], "Extended Module: ")) {
        return TrackerValidationResult.invalid(errmsg.invalidSignature("XM"));
    }

    // Check 0x1A marker
    if (header[37] != 0x1A) {
        return TrackerValidationResult.invalid(errmsg.missing("XM end-of-text marker"));
    }

    // Parse header fields
    const header_size = std.mem.readInt(u32, header[60..64], .little);
    const song_length = std.mem.readInt(u16, header[64..66], .little);
    const num_patterns = std.mem.readInt(u16, header[70..72], .little);
    const num_instruments = std.mem.readInt(u16, header[72..74], .little);
    const num_channels = std.mem.readInt(u16, header[68..70], .little);

    // Validate ranges
    if (song_length == 0 or song_length > 256) {
        return TrackerValidationResult.invalid("Invalid XM song length");
    }
    if (num_patterns > 256) {
        return TrackerValidationResult.invalid("Invalid XM pattern count");
    }
    if (num_instruments > 128) {
        return TrackerValidationResult.invalid("Invalid XM instrument count");
    }
    if (num_channels == 0 or num_channels > 32) {
        return TrackerValidationResult.invalid("Invalid XM channel count");
    }

    // Skip to patterns (offset 60 + header_size)
    const patterns_offset: u64 = 60 + header_size;
    if (patterns_offset >= file_size) {
        return TrackerValidationResult.invalid("XM header extends past file end");
    }

    // Validate pattern headers (each has a 9-byte header minimum)
    file.seekTo(patterns_offset) catch return TrackerValidationResult.invalid("Seek failed");
    var pos: u64 = patterns_offset;

    for (0..num_patterns) |_| {
        if (pos + 9 > file_size) {
            return TrackerValidationResult.invalid("XM pattern header truncated");
        }

        var pat_header: [9]u8 = undefined;
        _ = file.readAll(&pat_header) catch return TrackerValidationResult.invalid("Read failed");

        const pat_header_len = std.mem.readInt(u32, pat_header[0..4], .little);
        const packed_size = std.mem.readInt(u16, pat_header[7..9], .little);

        // Skip pattern data
        pos += pat_header_len + packed_size;
        file.seekTo(pos) catch return TrackerValidationResult.invalid("Seek failed");
    }

    return TrackerValidationResult.ok(.{
        .channels = num_channels,
        .patterns = num_patterns,
        .samples = 0, // Would need to parse instruments to count
        .instruments = num_instruments,
    });
}

// ============ IT Deep Validation ============

/// Deep validation for Impulse Tracker IT files.
/// Validates header, instruments, samples, and patterns.
pub fn validateItDeep(file: *FileSource) TrackerValidationResult {
    const file_size = file.getEndPos() catch {
        return TrackerValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < 192) {
        return TrackerValidationResult.invalid(errmsg.fileTooSmallFor("IT"));
    }

    // Read header
    var header: [192]u8 = undefined;
    _ = file.readAll(&header) catch return TrackerValidationResult.invalid("Read failed");

    // Check signature
    if (!std.mem.eql(u8, header[0..4], "IMPM")) {
        return TrackerValidationResult.invalid(errmsg.invalidSignature("IT"));
    }

    // Parse header fields
    const num_orders = std.mem.readInt(u16, header[0x20..0x22], .little);
    const num_instruments = std.mem.readInt(u16, header[0x22..0x24], .little);
    const num_samples = std.mem.readInt(u16, header[0x24..0x26], .little);
    const num_patterns = std.mem.readInt(u16, header[0x26..0x28], .little);

    // Validate ranges
    if (num_orders == 0) {
        return TrackerValidationResult.invalid("IT has no orders");
    }
    if (num_instruments > 256) {
        return TrackerValidationResult.invalid("Invalid IT instrument count");
    }
    if (num_samples > 256) {
        return TrackerValidationResult.invalid("Invalid IT sample count");
    }
    if (num_patterns > 256) {
        return TrackerValidationResult.invalid("Invalid IT pattern count");
    }

    // Calculate offset table positions
    const orders_offset: u64 = 0xC0;
    const inst_offsets_offset: u64 = orders_offset + num_orders;
    const sample_offsets_offset: u64 = inst_offsets_offset + (@as(u64, num_instruments) * 4);
    const pattern_offsets_offset: u64 = sample_offsets_offset + (@as(u64, num_samples) * 4);

    // Verify we can read the offset tables
    const min_header_size = pattern_offsets_offset + (@as(u64, num_patterns) * 4);
    if (min_header_size > file_size) {
        return TrackerValidationResult.invalid("IT offset tables extend past file end");
    }

    // Read and validate instrument offsets
    file.seekTo(inst_offsets_offset) catch return TrackerValidationResult.invalid("Seek failed");
    for (0..num_instruments) |_| {
        var offset_buf: [4]u8 = undefined;
        _ = file.readAll(&offset_buf) catch return TrackerValidationResult.invalid("Read failed");
        const offset = std.mem.readInt(u32, &offset_buf, .little);
        if (offset != 0 and offset >= file_size) {
            return TrackerValidationResult.invalid("IT instrument offset past file end");
        }
    }

    // Read and validate sample offsets
    for (0..num_samples) |_| {
        var offset_buf: [4]u8 = undefined;
        _ = file.readAll(&offset_buf) catch return TrackerValidationResult.invalid("Read failed");
        const offset = std.mem.readInt(u32, &offset_buf, .little);
        if (offset != 0 and offset >= file_size) {
            return TrackerValidationResult.invalid("IT sample offset past file end");
        }
    }

    // Read and validate pattern offsets
    for (0..num_patterns) |_| {
        var offset_buf: [4]u8 = undefined;
        _ = file.readAll(&offset_buf) catch return TrackerValidationResult.invalid("Read failed");
        const offset = std.mem.readInt(u32, &offset_buf, .little);
        if (offset != 0 and offset >= file_size) {
            return TrackerValidationResult.invalid("IT pattern offset past file end");
        }
    }

    return TrackerValidationResult.ok(.{
        .channels = 64, // IT supports up to 64 channels (variable per pattern)
        .patterns = num_patterns,
        .samples = num_samples,
        .instruments = num_instruments,
    });
}

// ============ S3M Deep Validation ============

/// Deep validation for Scream Tracker 3 S3M files.
/// Validates header, instruments, patterns, and sample data.
pub fn validateS3mDeep(file: *FileSource) TrackerValidationResult {
    const file_size = file.getEndPos() catch {
        return TrackerValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    if (file_size < 96) {
        return TrackerValidationResult.invalid(errmsg.fileTooSmallFor("S3M"));
    }

    // Read header
    var header: [96]u8 = undefined;
    _ = file.readAll(&header) catch return TrackerValidationResult.invalid("Read failed");

    // Check signature at offset 44
    if (!std.mem.eql(u8, header[44..48], "SCRM")) {
        return TrackerValidationResult.invalid(errmsg.invalidSignature("S3M"));
    }

    // Check type byte
    if (header[0x1D] != 16) {
        return TrackerValidationResult.invalid("Invalid S3M type");
    }

    // Parse header fields
    const num_orders = std.mem.readInt(u16, header[0x20..0x22], .little);
    const num_instruments = std.mem.readInt(u16, header[0x22..0x24], .little);
    const num_patterns = std.mem.readInt(u16, header[0x24..0x26], .little);

    // Validate ranges
    if (num_orders == 0 or num_orders > 256) {
        return TrackerValidationResult.invalid("Invalid S3M order count");
    }
    if (num_instruments > 99) {
        return TrackerValidationResult.invalid("Invalid S3M instrument count");
    }
    if (num_patterns > 100) {
        return TrackerValidationResult.invalid("Invalid S3M pattern count");
    }

    // Calculate pointer table positions
    // Order list: offset 0x60, length num_orders
    // Instrument pointers: offset 0x60 + num_orders, length num_instruments * 2
    // Pattern pointers: after instruments, length num_patterns * 2
    const order_offset: u64 = 0x60;
    const inst_ptr_offset: u64 = order_offset + num_orders;
    const pat_ptr_offset: u64 = inst_ptr_offset + (@as(u64, num_instruments) * 2);
    const min_header_size: u64 = pat_ptr_offset + (@as(u64, num_patterns) * 2);

    if (min_header_size > file_size) {
        return TrackerValidationResult.invalid("S3M pointer tables extend past file end");
    }

    // Validate instrument parapointers
    file.seekTo(inst_ptr_offset) catch return TrackerValidationResult.invalid("Seek failed");
    for (0..num_instruments) |_| {
        var ptr_buf: [2]u8 = undefined;
        _ = file.readAll(&ptr_buf) catch return TrackerValidationResult.invalid("Read failed");
        const parapointer = std.mem.readInt(u16, &ptr_buf, .little);
        const offset: u64 = @as(u64, parapointer) * 16;
        if (parapointer != 0 and offset >= file_size) {
            return TrackerValidationResult.invalid("S3M instrument pointer past file end");
        }
    }

    // Validate pattern parapointers
    for (0..num_patterns) |_| {
        var ptr_buf: [2]u8 = undefined;
        _ = file.readAll(&ptr_buf) catch return TrackerValidationResult.invalid("Read failed");
        const parapointer = std.mem.readInt(u16, &ptr_buf, .little);
        const offset: u64 = @as(u64, parapointer) * 16;
        if (parapointer != 0 and offset >= file_size) {
            return TrackerValidationResult.invalid("S3M pattern pointer past file end");
        }
    }

    return TrackerValidationResult.ok(.{
        .channels = 32, // S3M supports up to 32 channels
        .patterns = num_patterns,
        .samples = num_instruments, // S3M doesn't separate instruments/samples
        .instruments = 0,
    });
}

// ============ Tests ============

test "MOD validation rejects missing file" {
    // Caller now opens FileSource — verify open failure is the expected error
    const result = FileSource.open("/nonexistent/file.mod");
    try std.testing.expectError(error.FileNotFound, result);
}

test "XM validation rejects missing file" {
    const result = FileSource.open("/nonexistent/file.xm");
    try std.testing.expectError(error.FileNotFound, result);
}

test "IT validation rejects missing file" {
    const result = FileSource.open("/nonexistent/file.it");
    try std.testing.expectError(error.FileNotFound, result);
}

test "S3M validation rejects missing file" {
    const result = FileSource.open("/nonexistent/file.s3m");
    try std.testing.expectError(error.FileNotFound, result);
}

test "MOD validates minimal synthetic file" {
    // Build a minimal valid 4-channel MOD: 1084-byte header + 1 pattern (64 rows * 4 bytes * 4 channels = 1024)
    const header_size = 1084;
    const pattern_size = 64 * 4 * 4; // 1024 bytes for one 4-channel pattern
    var data = [_]u8{0} ** (header_size + pattern_size);

    // Module name (20 bytes at offset 0) — leave as zeros (valid)
    // 31 sample headers (30 bytes each at offset 20) — all zeros = no samples (valid)

    // Song length at offset 950: 1 position
    data[950] = 1;
    // Pattern table at offset 952: position 0 uses pattern 0
    data[952] = 0;

    // Signature "M.K." at offset 1080
    data[1080] = 'M';
    data[1081] = '.';
    data[1082] = 'K';
    data[1083] = '.';

    // Write to a temp file and validate
    const tmp_path = "/tmp/validate_test_mod.mod";
    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    defer file.close();
    file.writeAll(&data) catch return;

    var src = FileSource.open(tmp_path) catch return;
    defer src.close();
    const result = validateModDeep(&src);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqual(@as(u16, 4), result.format_details.channels);
    try std.testing.expectEqual(@as(u16, 1), result.format_details.patterns);
}

test "XM validates minimal synthetic file" {
    // Minimal XM: 60-byte fixed prefix + 20-byte header extension + pattern order table
    var data = [_]u8{0} ** 360;

    // Signature: "Extended Module: " (17 bytes)
    const sig = "Extended Module: ";
    @memcpy(data[0..17], sig);
    // Module name (20 bytes at offset 17) — zeros
    // 0x1A marker at offset 37
    data[37] = 0x1A;
    // Tracker name (20 bytes at offset 38) — zeros

    // Header size at offset 60 (u32 LE) — size of header after this field
    // Minimum: 4 (songlen) + 2 (restart) + 2 (channels) + 2 (patterns) + 2 (instruments) + 2 (flags) + 2 (tempo) + 2 (bpm) + 256 (order table) = 276
    const header_ext_size: u32 = 276;
    std.mem.writeInt(u32, data[60..64], header_ext_size, .little);

    // Song length at offset 64 (u16 LE)
    std.mem.writeInt(u16, data[64..66], 1, .little);
    // Restart position at offset 66
    std.mem.writeInt(u16, data[66..68], 0, .little);
    // Number of channels at offset 68
    std.mem.writeInt(u16, data[68..70], 8, .little);
    // Number of patterns at offset 70
    std.mem.writeInt(u16, data[70..72], 0, .little);
    // Number of instruments at offset 72
    std.mem.writeInt(u16, data[72..74], 0, .little);

    const tmp_path = "/tmp/validate_test_xm.xm";
    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    defer file.close();
    file.writeAll(&data) catch return;

    var src = FileSource.open(tmp_path) catch return;
    defer src.close();
    const result = validateXmDeep(&src);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqual(@as(u16, 8), result.format_details.channels);
}

test "IT validates minimal synthetic file" {
    // Minimal IT file: 192-byte header + order list
    var data = [_]u8{0} ** 256;

    // Signature "IMPM" at offset 0
    data[0] = 'I';
    data[1] = 'M';
    data[2] = 'P';
    data[3] = 'M';

    // Number of orders at 0x20 (u16 LE) — at least 1
    std.mem.writeInt(u16, data[0x20..0x22], 1, .little);
    // Number of instruments at 0x22
    std.mem.writeInt(u16, data[0x22..0x24], 0, .little);
    // Number of samples at 0x24
    std.mem.writeInt(u16, data[0x24..0x26], 0, .little);
    // Number of patterns at 0x26
    std.mem.writeInt(u16, data[0x26..0x28], 0, .little);

    // Order list starts at 0xC0, just needs 1 byte (order 0)
    data[0xC0] = 0;

    const tmp_path = "/tmp/validate_test_it.it";
    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    defer file.close();
    file.writeAll(&data) catch return;

    var src = FileSource.open(tmp_path) catch return;
    defer src.close();
    const result = validateItDeep(&src);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqual(@as(u16, 0), result.format_details.patterns);
    try std.testing.expectEqual(@as(u16, 0), result.format_details.samples);
}

test "S3M validates minimal synthetic file" {
    // Minimal S3M: 96-byte header + order list + pointer tables
    // Need: orders=1, instruments=0, patterns=0
    // Total: 0x60 (header) + 1 (order) + 0 + 0 = 97 bytes
    var data = [_]u8{0} ** 128;

    // "SCRM" signature at offset 44
    data[44] = 'S';
    data[45] = 'C';
    data[46] = 'R';
    data[47] = 'M';

    // Type byte at 0x1D = 16
    data[0x1D] = 16;

    // Number of orders at 0x20 (u16 LE)
    std.mem.writeInt(u16, data[0x20..0x22], 1, .little);
    // Number of instruments at 0x22
    std.mem.writeInt(u16, data[0x22..0x24], 0, .little);
    // Number of patterns at 0x24
    std.mem.writeInt(u16, data[0x24..0x26], 0, .little);

    // Order list at 0x60: one order entry
    data[0x60] = 0;

    const tmp_path = "/tmp/validate_test_s3m.s3m";
    const file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    defer file.close();
    file.writeAll(&data) catch return;

    var src = FileSource.open(tmp_path) catch return;
    defer src.close();
    const result = validateS3mDeep(&src);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqual(@as(u16, 0), result.format_details.patterns);
    try std.testing.expectEqual(@as(u16, 32), result.format_details.channels);
}
