//! Filesystem/disk image format validators
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for ISO 9660 disk images and Apple DMG disk images.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;

const dmg_validator = @import("dmg_validator.zig");
const iso9660_parser = @import("iso9660_parser.zig");

const testing = std.testing;

// ============ ISO 9660 Validator ============

/// Validate ISO 9660 disk image structure.
pub fn validateIso(file: std.fs.File) ValidationResult {
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
pub fn validateDmg(file: std.fs.File) ValidationResult {
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

    const result = dmg_validator.validateDmgFile(file, allocator);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.dmg, result.error_message orelse "DMG validation failed", .full);
    }

    // Check if checksums were verified
    if (result.data_checksum_verified) {
        return ValidationResult.okWithDepth(.dmg, .full);
    }

    // Checksum present but not verified (large file) - structural only
    if (result.has_data_checksum) {
        return ValidationResult.okWithDepthAndWarning(.dmg, .structural, "data checksum present but not verified (large file)");
    }

    // No checksum in file - structural validation only
    return ValidationResult.okWithDepth(.dmg, .structural);
}

// ============ ISO Deep Validation ============

/// Deep validation for ISO 9660 disk images.
/// Validates volume descriptors and directory structure.
pub fn validateIsoDeep(allocator: Allocator, path: []const u8) ValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => ValidationResult.invalidWithDepth(.iso, "File not found", .structural),
            error.AccessDenied => ValidationResult.invalidWithDepth(.iso, "Access denied", .structural),
            else => ValidationResult.invalidCodeWithDepth(.iso, .failed_to_open, "file", .structural),
        };
    };
    defer file.close();

    // Get file size
    const file_size = file.getEndPos() catch {
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
        return validateIsoSignature(file);
    };
    defer allocator.free(data);

    file.seekTo(0) catch {
        return ValidationResult.invalidCodeWithDepth(.iso, .failed_to_seek, "to start", .structural);
    };

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCodeWithDepth(.iso, .failed_to_read, "file", .structural);
    };

    if (bytes_read < min_iso_size) {
        return ValidationResult.invalidCodeWithDepth(.iso, .incomplete, "read", .structural);
    }

    // Use iso9660_parser for validation
    const result = iso9660_parser.validateIso9660(data[0..bytes_read]);

    if (!result.valid) {
        return ValidationResult.invalidWithDepth(.iso, result.error_message orelse "ISO 9660 validation failed", .structural);
    }

    // No CRC/hash in ISO 9660 — volume descriptors and directory structure only
    return ValidationResult.okWithDepth(.iso, .structural);
}

/// Simple ISO signature validation (fallback for memory-constrained situations).
pub fn validateIsoSignature(file: std.fs.File) ValidationResult {
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
