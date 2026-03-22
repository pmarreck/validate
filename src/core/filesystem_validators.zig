//! Filesystem/disk image format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for ISO 9660 disk images and Apple DMG disk images.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;

const dmg_validator = @import("dmg_validator.zig");
const iso9660_parser = @import("iso9660_parser.zig");

const testing = std.testing;

// ============ ISO 9660 Validator ============

/// Validate ISO 9660 disk image structure.
pub fn validateIso(file: *FileSource) ValidationResult {
    // First check for Apple Driver Map (0x4552 'ER') + Apple Partition Map (0x504D 'PM').
    // These are macOS disk images (HFS/HFS+) often named .iso but not ISO 9660.
    file.seekTo(0) catch return ValidationResult.invalidCode(.iso, .failed_to_seek, "to start");
    var apple_check: [0x202]u8 = undefined;
    if (file.readAll(&apple_check)) |n| {
        if (n >= 8 and apple_check[0] == 0x45 and apple_check[1] == 0x52 and
            // Validate block size is reasonable (512, 1024, 2048, or 4096)
            (std.mem.readInt(u16, apple_check[2..4], .big) == 512 or
            std.mem.readInt(u16, apple_check[2..4], .big) == 1024 or
            std.mem.readInt(u16, apple_check[2..4], .big) == 2048 or
            std.mem.readInt(u16, apple_check[2..4], .big) == 4096))
        {
            var result = ValidationResult.okWithDepth(.iso, .structural);
            result.warning_message = "Apple Disk Image (HFS/HFS+) detected, not ISO 9660; recommended extension: .img or .dmg";
            return result;
        }
    } else |_| {}

    // ISO 9660 has "CD001" at offset 0x8001 (32769) for primary volume descriptor
    file.seekTo(0x8001) catch return ValidationResult.invalidCode(.iso, .failed_to_seek, "to volume descriptor");

    var descriptor: [5]u8 = undefined;
    const desc_read = file.read(&descriptor) catch return ValidationResult.invalidCode(.iso, .failed_to_read, "volume descriptor");

    if (desc_read < 5) {
        return ValidationResult.invalidCode(.iso, .file_too_small, "ISO 9660");
    }

    // Check for "CD001" identifier
    if (!std.mem.eql(u8, &descriptor, "CD001")) {
        return ValidationResult.invalidCode(.iso, .invalid_signature, "ISO 9660");
    }

    // No CRC/hash — signature check only
    return ValidationResult.okWithDepth(.iso, .structural);
}

// ============ Apple DMG Validator ============

/// Validate Apple Disk Image structure.
pub fn validateDmg(file: *FileSource) ValidationResult {
    // DMG has "koly" trailer at end of file (last 512 bytes contain the trailer)
    const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.dmg, .failed_to_get, "file size");

    if (file_size < 512) {
        return ValidationResult.invalidCode(.dmg, .file_too_small, "DMG");
    }

    // Seek to last 512 bytes where koly trailer should be
    file.seekTo(file_size - 512) catch return ValidationResult.invalidCode(.dmg, .failed_to_seek, "to trailer");

    var trailer: [512]u8 = undefined;
    const trailer_read = file.read(&trailer) catch return ValidationResult.invalidCode(.dmg, .failed_to_read, "DMG trailer");

    if (trailer_read < 512) {
        return ValidationResult.invalidCode(.dmg, .failed_to_read, "full trailer");
    }

    // Look for "koly" signature at start of trailer
    if (!std.mem.eql(u8, trailer[0..4], "koly")) {
        return ValidationResult.invalidCode(.dmg, .invalid_signature, "DMG");
    }

    // No CRC/hash — signature check only
    return ValidationResult.okWithDepth(.dmg, .structural);
}

// ============ DMG Deep Validation ============

/// Deep validation for DMG (Apple Disk Image) files.
/// Validates koly block structure and checksums.
pub fn validateDmgDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.dmg, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.dmg, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.dmg, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    var dmg_source = FileSource.fromFile(file);
    const result = dmg_validator.validateDmgFile(&dmg_source, allocator);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.dmg, result.error_message orelse "DMG validation failed", .full);
    }

    // Check if checksums were verified
    const any_checksum_verified = result.data_checksum_verified or result.master_checksum_verified;
    if (any_checksum_verified) {
        return ValidationResult.okWithDepth(.dmg, .full);
    }

    // Checksum present but not verified (large file) - structural only
    if (result.has_data_checksum or result.has_master_checksum) {
        return ValidationResult.okWithDepthAndWarning(.dmg, .structural, "checksum(s) present but not verified (large file)");
    }

    // No checksum in file - structural validation only
    return ValidationResult.okWithDepth(.dmg, .structural);
}

// ============ ISO Deep Validation ============

/// Deep validation for ISO 9660 disk images.
/// Validates volume descriptors and directory structure.
pub fn validateIsoDeep(allocator: Allocator, path: []const u8) ValidationResult {
    var source = FileSource.open(path) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.iso, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.iso, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.iso, .failed_to_open, "file", .structural),
        };
    };
    defer source.close();

    // Get file size
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidCodeWithDepth(.iso, .failed_to_get, "file size", .structural);
    };

    // ISO 9660 minimum: 32KB system area + at least one volume descriptor sector
    const min_iso_size: u64 = 32 * 1024 + 2048;
    if (file_size < min_iso_size) {
        return ValidationResult.invalidCodeWithDepth(.iso, .file_too_small, "ISO 9660", .structural);
    }

    // Read enough data for validation (volume descriptors + root directory)
    // Volume descriptors start at sector 16 (offset 0x8000)
    const max_read: usize = @min(@as(usize, @intCast(file_size)), 64 * 1024 * 1024); // Cap at 64MB for memory
    const data = allocator.alloc(u8, max_read) catch {
        // Fall back to signature-only validation
        return validateIsoSignature(&source);
    };
    defer allocator.free(data);

    source.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.iso, .failed_to_seek, "to start", .structural);
    };

    const bytes_read = source.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.iso, .failed_to_read, "file", .structural);
    };

    if (bytes_read < min_iso_size) {
        return ValidationResult.invalidCodeWithDepth(.iso, .incomplete, "read", .structural);
    }

    // Check for Apple Driver Map (0x4552 'ER' at offset 0 with valid block size).
    // These are macOS disk images (classic HFS/HFS+) often misnamed as .iso.
    if (bytes_read >= 8 and data[0] == 0x45 and data[1] == 0x52 and
        (std.mem.readInt(u16, data[2..4], .big) == 512 or
        std.mem.readInt(u16, data[2..4], .big) == 1024 or
        std.mem.readInt(u16, data[2..4], .big) == 2048 or
        std.mem.readInt(u16, data[2..4], .big) == 4096))
    {
        var apple_result = ValidationResult.okWithDepth(.iso, .structural);
        apple_result.warning_message = "Apple Disk Image (HFS/HFS+) detected, not ISO 9660; recommended extension: .img or .dmg";
        return apple_result;
    }

    // Use iso9660_parser for validation
    const result = iso9660_parser.validateIso9660(data[0..bytes_read], file_size);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.iso, result.error_message orelse "ISO 9660 validation failed", .structural);
    }

    // No CRC/hash in ISO 9660 — volume descriptors and directory structure only
    return ValidationResult.okWithDepth(.iso, .structural);
}

/// Simple ISO signature validation (fallback for memory-constrained situations).
pub fn validateIsoSignature(file: *FileSource) ValidationResult {
    // ISO 9660 has "CD001" at offset 0x8001 (32769) for primary volume descriptor
    file.seekTo(0x8001) catch return ValidationResult.invalidCode(.iso, .failed_to_seek, "to volume descriptor");

    var descriptor: [5]u8 = undefined;
    const desc_read = file.read(&descriptor) catch return ValidationResult.invalidCode(.iso, .failed_to_read, "volume descriptor");

    if (desc_read < 5) {
        return ValidationResult.invalidCode(.iso, .file_too_small, "ISO 9660");
    }

    if (!std.mem.eql(u8, &descriptor, "CD001")) {
        return ValidationResult.invalidCode(.iso, .invalid_signature, "ISO 9660");
    }

    return ValidationResult.okWithDepth(.iso, .structural);
}

// ============================================================
// Tests
// ============================================================

test "ISO structural: valid synthetic ISO with CD001 signature" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // ISO 9660 has "CD001" at offset 0x8001 (byte 32769)
    // Volume descriptor type byte at 0x8000, then "CD001" at 0x8001
    const header_size = 0x8001 + 5;
    var data: [header_size]u8 = [_]u8{0} ** header_size;
    // Primary volume descriptor type = 1 at offset 0x8000
    data[0x8000] = 0x01;
    // "CD001" at offset 0x8001
    @memcpy(data[0x8001..0x8006], "CD001");

    try tmp.dir.writeFile(.{ .sub_path = "test.iso", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.iso", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateIso(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(format_validation.FileFormat.iso, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "ISO structural: missing CD001 rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const header_size = 0x8001 + 5;
    var data: [header_size]u8 = [_]u8{0} ** header_size;
    // Write wrong signature
    @memcpy(data[0x8001..0x8006], "XXXXX");

    try tmp.dir.writeFile(.{ .sub_path = "test.iso", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.iso", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateIso(&source);
    try testing.expect(!result.is_valid);
    try testing.expectEqual(format_validation.FileFormat.iso, result.format);
}

test "ISO structural: file too small rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // File smaller than offset 0x8001 + 5
    const small_data = [_]u8{0} ** 100;
    try tmp.dir.writeFile(.{ .sub_path = "test.iso", .data = &small_data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.iso", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateIso(&source);
    try testing.expect(!result.is_valid);
}

test "ISO structural: ground truth sample.iso" {
    var source = FileSource.open("ground_truth_examples/iso/sample.iso") catch {
        return; // Skip if file doesn't exist
    };
    defer source.close();

    const result = validateIso(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(format_validation.FileFormat.iso, result.format);
}

test "ISO deep: ground truth sample.iso" {
    const allocator = testing.allocator;

    // Just check file exists
    std.fs.cwd().access("ground_truth_examples/iso/sample.iso", .{}) catch return;

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/iso/sample.iso") catch return;
    defer allocator.free(path);

    const result = validateIsoDeep(allocator, path);
    try testing.expect(result.is_valid);
    try testing.expectEqual(format_validation.FileFormat.iso, result.format);
    try testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "DMG structural: valid synthetic DMG with koly trailer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // DMG has "koly" at the start of the last 512 bytes
    var data: [1024]u8 = [_]u8{0} ** 1024;
    // Write "koly" at offset 512 (= 1024 - 512)
    @memcpy(data[512..516], "koly");

    try tmp.dir.writeFile(.{ .sub_path = "test.dmg", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.dmg", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateDmg(&source);
    try testing.expect(result.is_valid);
    try testing.expectEqual(format_validation.FileFormat.dmg, result.format);
}

test "DMG structural: missing koly rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: [1024]u8 = [_]u8{0} ** 1024;
    // No "koly" signature

    try tmp.dir.writeFile(.{ .sub_path = "test.dmg", .data = &data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.dmg", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateDmg(&source);
    try testing.expect(!result.is_valid);
}

test "DMG structural: file too small rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const small_data = [_]u8{0} ** 100;
    try tmp.dir.writeFile(.{ .sub_path = "test.dmg", .data = &small_data });

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp.dir.realpath("test.dmg", &real_path_buf);
    var source = try FileSource.open(real_path);
    defer source.close();

    const result = validateDmg(&source);
    try testing.expect(!result.is_valid);
}
