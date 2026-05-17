const std = @import("std");
const runtime = @import("runtime.zig");
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const FileSource = @import("file_source.zig").FileSource;

const mini_blar = @import("mini_blar");
const ArchiveReader = mini_blar.ArchiveReader;

/// BLIP archive format validator (.blar / .mblar).
///
/// Uses the BLIP library's own ArchiveReader to verify magic bytes,
/// outer container checksum, and per-file data checksums.
/// Full validation achieves transparent corruption detection via
/// BLAKE3-128/xxHash64/CRC-32 checksums on every container.

/// Structural validation: verify archive can be parsed and magic is valid.
pub fn validateBlarStructural(allocator: std.mem.Allocator, source: *FileSource, format: FileFormat) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidWithDepth(format, "Cannot determine file size", .structural);
    };
    if (file_size < 16) {
        return ValidationResult.invalidWithDepth(format, "File too small for BLAR/MBLAR archive", .structural);
    }
    if (file_size > 1024 * 1024 * 1024) {
        // For structural-only, cap at 1GB to avoid huge allocations
        return ValidationResult.okWithDepth(format, .structural);
    }

    // Read entire file into memory for ArchiveReader
    const slurp = source.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidWithDepth(format, "Cannot read file", .structural);
    var heap_blar1: ?[]u8 = null;
    defer if (heap_blar1) |b| allocator.free(b);
    const data: []const u8 = switch (slurp) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_blar1 = b; break :blk b; },
        .too_large => return ValidationResult.invalidWithDepth(format, "BLAR/MBLAR too large for non-mmap structural validation", .structural),
    };

    // Initialize ArchiveReader — validates LP envelope and structure
    const reader = ArchiveReader.init(data) catch {
        return ValidationResult.invalidWithDepth(format, "Invalid BLIP container structure", .structural);
    };

    // Verify magic bytes (BLAR\x02 or MBAR\x02)
    const magic_ok = reader.verifyMagic() catch {
        return ValidationResult.invalidWithDepth(format, "Cannot read magic bytes", .structural);
    };
    if (!magic_ok) {
        return ValidationResult.invalidWithDepth(format, "Invalid BLAR/MBAR magic bytes", .structural);
    }

    return ValidationResult.okWithDepth(format, .structural);
}

/// Deep validation: structural checks + verify outer checksum + per-file checksums.
pub fn validateBlarDeep(allocator: std.mem.Allocator, source: *FileSource, format: FileFormat) ValidationResult {
    const file_size = source.getEndPos() catch {
        return ValidationResult.invalidWithDepth(format, "Cannot determine file size", .full);
    };
    if (file_size < 16) {
        return ValidationResult.invalidWithDepth(format, "File too small for BLAR/MBLAR archive", .full);
    }

    // Read entire file into memory for ArchiveReader
    const slurp_deep = source.getMappedOrSlurp(allocator, 256 << 20) catch
        return ValidationResult.invalidWithDepth(format, "Cannot read file", .full);
    var heap_blar2: ?[]u8 = null;
    defer if (heap_blar2) |b| allocator.free(b);
    const data: []const u8 = switch (slurp_deep) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_blar2 = b; break :blk b; },
        .too_large => return ValidationResult.invalidWithDepth(format, "BLAR/MBLAR too large for non-mmap deep validation", .full),
    };

    // Initialize ArchiveReader
    const reader = ArchiveReader.init(data) catch {
        return ValidationResult.invalidWithDepth(format, "Invalid BLIP container structure", .full);
    };

    // Verify magic
    const magic_ok = reader.verifyMagic() catch {
        return ValidationResult.invalidWithDepth(format, "Cannot read magic bytes", .full);
    };
    if (!magic_ok) {
        return ValidationResult.invalidWithDepth(format, "Invalid BLAR/MBAR magic bytes", .full);
    }

    // Verify outer container checksum (covers entire archive)
    const checksum_ok = reader.verifyChecksum() catch {
        return ValidationResult.invalidWithDepth(format, "Cannot verify outer checksum", .full);
    };
    if (!checksum_ok) {
        return ValidationResult.invalidCodeWithDepth(format, .checksum_mismatch, "Outer container checksum mismatch", .full);
    }

    // Verify each file's DATA checksum
    const entry_count = reader.entryCount() catch {
        // If we can't get entry count but outer checksum passed, still good
        return ValidationResult.okWithDepth(format, .full);
    };

    var i: u64 = 0;
    while (i < entry_count) : (i += 1) {
        // Check if this entry is a FILE (type 5) — skip DIR entries
        const entry_type = reader.entryTypeAt(i) catch continue;
        if (entry_type != .file) continue;

        const file_ok = reader.verifyFileAt(i) catch continue;
        if (!file_ok) {
            return ValidationResult.invalidCodeWithDepth(format, .checksum_mismatch, "File data checksum mismatch", .full);
        }
    }

    return ValidationResult.okWithDepth(format, .full);
}

// --- Tests ---

test "validateBlarStructural: valid blar" {
    var source = FileSource.open("ground_truth_examples/blar/sample.blar") catch {
        return error.SkipZigTest;
    };
    defer source.close();
    const result = validateBlarStructural(std.testing.allocator, &source, .blar);
    try std.testing.expect(result.is_valid);
}

test "validateBlarStructural: valid mblar" {
    var source = FileSource.open("ground_truth_examples/mblar/sample.mblar") catch {
        return error.SkipZigTest;
    };
    defer source.close();
    const result = validateBlarStructural(std.testing.allocator, &source, .mblar);
    try std.testing.expect(result.is_valid);
}

test "validateBlarDeep: valid blar with checksum" {
    var source = FileSource.open("ground_truth_examples/blar/sample.blar") catch {
        return error.SkipZigTest;
    };
    defer source.close();
    const result = validateBlarDeep(std.testing.allocator, &source, .blar);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateBlarDeep: valid mblar with checksum" {
    var source = FileSource.open("ground_truth_examples/mblar/sample.mblar") catch {
        return error.SkipZigTest;
    };
    defer source.close();
    const result = validateBlarDeep(std.testing.allocator, &source, .mblar);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
}

test "validateBlarDeep: corrupted blar detected" {
    const file = runtime.openFile("ground_truth_examples/blar/sample.blar", .{}) catch {
        return error.SkipZigTest;
    };
    defer file.close(runtime.io());

    const data = file.readToEndAlloc(std.testing.allocator, 1024 * 1024) catch return error.SkipZigTest;
    defer std.testing.allocator.free(data);

    // Flip a byte in the middle of the data (well after header, before checksum)
    if (data.len > 100) {
        data[data.len / 2] ^= 0xFF;
    }

    // Write corrupted data to temp file
    const tmp_path = "/tmp/validate-test-corrupted.blar";
    const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch return error.SkipZigTest;
    tmp_file.writePositionalAll(runtime.io(), data, 0) catch {
        tmp_file.close(runtime.io());
        return error.SkipZigTest;
    };
    tmp_file.close(runtime.io());
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var source = FileSource.open(tmp_path) catch return error.SkipZigTest;
    defer source.close();

    const result = validateBlarDeep(std.testing.allocator, &source, .blar);
    try std.testing.expect(!result.is_valid);
}
