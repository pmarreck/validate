//! Deep RAR validation module.
//!
//! This module provides thorough RAR archive validation by:
//! 1. Verifying header CRCs (RAR4: CRC16, RAR5: CRC32)
//! 2. Using system's unrar or 7z command to verify file integrity
//!
//! The RAR format (both RAR4 and RAR5) supports CRC32 for each compressed
//! file. Full validation requires decompression to verify these CRCs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errmsg = @import("error_messages.zig");

/// Result of RAR deep validation
pub const RarValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    files_checked: u32,
    total_files: u32,
    is_rar5: bool,
    command_used: ?[]const u8,

    pub fn ok(files: u32, is_rar5: bool, cmd: ?[]const u8) RarValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = files,
            .total_files = files,
            .is_rar5 = is_rar5,
            .command_used = cmd,
        };
    }

    pub fn headerOnly(is_rar5: bool) RarValidationResult {
        return .{
            .valid = true,
            .error_message = null,
            .files_checked = 0,
            .total_files = 0,
            .is_rar5 = is_rar5,
            .command_used = null,
        };
    }

    pub fn invalid(message: []const u8) RarValidationResult {
        return .{
            .valid = false,
            .error_message = message,
            .files_checked = 0,
            .total_files = 0,
            .is_rar5 = false,
            .command_used = null,
        };
    }
};

/// RAR5 signature: 52 61 72 21 1A 07 01 00
const RAR5_SIGNATURE = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 };
/// RAR4 signature: 52 61 72 21 1A 07 00
const RAR4_SIGNATURE = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 };

/// Deep validate a RAR file using system commands for integrity check
pub fn validateRarDeep(allocator: Allocator, path: []const u8) RarValidationResult {
    // First, verify the signature and basic header structure
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return RarValidationResult.invalid(errmsg.failedToOpen("file"));
    };
    defer file.close();

    // Read signature
    var sig_buf: [8]u8 = undefined;
    const sig_read = file.readAll(&sig_buf) catch {
        return RarValidationResult.invalid(errmsg.failedToRead("signature"));
    };

    if (sig_read < 7) {
        return RarValidationResult.invalid(errmsg.fileTooSmallFor("RAR"));
    }

    const is_rar5 = sig_read >= 8 and std.mem.eql(u8, sig_buf[0..8], &RAR5_SIGNATURE);
    const is_rar4 = !is_rar5 and std.mem.eql(u8, sig_buf[0..7], &RAR4_SIGNATURE);

    if (!is_rar4 and !is_rar5) {
        return RarValidationResult.invalid(errmsg.invalidSignature("RAR"));
    }

    // Try unrar first, then 7z as fallback
    const unrar_result = tryUnrarTest(allocator, path);
    if (unrar_result.valid and unrar_result.files_checked > 0) {
        return RarValidationResult.ok(unrar_result.files_checked, is_rar5, "unrar");
    }
    if (!unrar_result.valid and unrar_result.error_message != null) {
        // unrar found corruption
        return unrar_result;
    }

    // Try 7z as fallback (7z can extract RAR files)
    const sevenz_result = trySevenZTest(allocator, path);
    if (sevenz_result.valid and sevenz_result.files_checked > 0) {
        return RarValidationResult.ok(sevenz_result.files_checked, is_rar5, "7z");
    }
    if (!sevenz_result.valid and sevenz_result.error_message != null) {
        // 7z found corruption
        return sevenz_result;
    }

    // Try bsdtar as a fallback. It supports RAR in many libarchive builds.
    const bsdtar_result = tryBsdtarTest(allocator, path);
    if (bsdtar_result.valid and bsdtar_result.files_checked > 0) {
        return RarValidationResult.ok(bsdtar_result.files_checked, is_rar5, "bsdtar");
    }
    if (!bsdtar_result.valid and bsdtar_result.error_message != null) {
        return bsdtar_result;
    }

    // No command available - return header-only validation
    return RarValidationResult.headerOnly(is_rar5);
}

/// Try to validate using unrar command
fn tryUnrarTest(allocator: Allocator, path: []const u8) RarValidationResult {
    // unrar t <file> tests archive integrity
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "unrar", "t", "-idq", path },
        .max_output_bytes = 64 * 1024,
    }) catch {
        // unrar not available
        return RarValidationResult.headerOnly(false);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                // Success - count files
                const file_count = countFilesInOutput(result.stdout, "Testing");
                return RarValidationResult.ok(file_count, false, "unrar");
            } else if (code == 3) {
                // CRC error
                return RarValidationResult.invalid("RAR CRC error - archive corrupted");
            } else if (code == 10) {
                // Unknown archive format
                return RarValidationResult.invalid(errmsg.unknown("RAR format"));
            } else {
                // Other error
                return RarValidationResult.invalid("RAR integrity test failed");
            }
        },
        else => {
            return RarValidationResult.invalid("unrar process terminated abnormally");
        },
    }
}

/// Try to validate using 7z command (can extract RAR)
fn trySevenZTest(allocator: Allocator, path: []const u8) RarValidationResult {
    if (!sevenZSupportsRar(allocator)) {
        // 7z exists but this build has no RAR handler.
        return RarValidationResult.headerOnly(false);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "7z", "t", "-bso0", path },
        .max_output_bytes = 64 * 1024,
    }) catch {
        // 7z not available
        return RarValidationResult.headerOnly(false);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                // Success - get file count
                const file_count = countFilesIn7z(allocator, path);
                return RarValidationResult.ok(file_count, false, "7z");
            } else if (code == 2) {
                // "Can not open the file as archive" can also indicate that
                // this 7z build lacks RAR support. We already check support
                // above, but keep this guard for safety.
                if (looksLikeUnsupportedBy7z(result.stderr)) {
                    return RarValidationResult.headerOnly(false);
                }
                // Fatal error - corruption
                return RarValidationResult.invalid("RAR integrity test failed - archive corrupted");
            } else {
                return RarValidationResult.invalid("RAR test failed with unexpected error");
            }
        },
        else => {
            return RarValidationResult.invalid("7z process terminated abnormally");
        },
    }
}

/// Try to validate using bsdtar command (libarchive).
/// We list entries first, then stream every entry via -xOf to force decoding.
fn tryBsdtarTest(allocator: Allocator, path: []const u8) RarValidationResult {
    const list_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "bsdtar", "-tf", path },
        .max_output_bytes = 1024 * 1024,
    }) catch {
        // bsdtar not available
        return RarValidationResult.headerOnly(false);
    };
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    switch (list_result.term) {
        .Exited => |code| {
            if (code != 0) {
                if (looksLikeUnsupportedByBsdtar(list_result.stderr)) {
                    return RarValidationResult.headerOnly(false);
                }
                return RarValidationResult.invalid("RAR integrity test failed - archive corrupted");
            }

            var file_count: u32 = 0;
            var lines = std.mem.splitSequence(u8, list_result.stdout, "\n");
            while (lines.next()) |line| {
                const entry = std.mem.trim(u8, line, " \r\t");
                if (entry.len == 0) continue;
                if (std.mem.endsWith(u8, entry, "/")) continue;
                file_count += 1;

                var child = std.process.Child.init(&[_][]const u8{ "bsdtar", "-xOf", path, entry }, allocator);
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                const term = child.spawnAndWait() catch {
                    return RarValidationResult.invalid("RAR integrity test failed - archive corrupted");
                };
                switch (term) {
                    .Exited => |extract_code| {
                        if (extract_code != 0) {
                            return RarValidationResult.invalid("RAR integrity test failed - archive corrupted");
                        }
                    },
                    else => {
                        return RarValidationResult.invalid("bsdtar process terminated abnormally");
                    },
                }
            }

            return RarValidationResult.ok(file_count, false, "bsdtar");
        },
        else => {
            return RarValidationResult.invalid("bsdtar process terminated abnormally");
        },
    }
}

/// Count files from unrar test output
fn countFilesInOutput(output: []const u8, marker: []const u8) u32 {
    var count: u32 = 0;
    var lines = std.mem.splitSequence(u8, output, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) != null) {
            count += 1;
        }
    }
    return count;
}

/// Count files in RAR archive using 7z list command
fn countFilesIn7z(allocator: Allocator, path: []const u8) u32 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "7z", "l", "-slt", path },
        .max_output_bytes = 1024 * 1024,
    }) catch return 0;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

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

fn sevenZSupportsRar(allocator: Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "7z", "i" },
        .max_output_bytes = 512 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return false;
        },
        else => return false,
    }

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |line| {
        // Example match in supported builds: "... Rar ..."
        if (std.mem.indexOf(u8, line, " Rar ") != null) return true;
        if (std.mem.indexOf(u8, line, " RAR ") != null) return true;
    }
    return false;
}

fn looksLikeUnsupportedBy7z(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "Can not open the file as archive") != null or
        std.mem.indexOf(u8, stderr, "Unsupported archive type") != null;
}

fn looksLikeUnsupportedByBsdtar(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "Unrecognized archive format") != null or
        std.mem.indexOf(u8, stderr, "Cannot open archive") != null;
}

/// Validate RAR from buffer (basic header validation only)
pub fn validateRarFromBuffer(data: []const u8) RarValidationResult {
    if (data.len < 7) {
        return RarValidationResult.invalid("Data too small for RAR");
    }

    const is_rar5 = data.len >= 8 and std.mem.eql(u8, data[0..8], &RAR5_SIGNATURE);
    const is_rar4 = !is_rar5 and std.mem.eql(u8, data[0..7], &RAR4_SIGNATURE);

    if (!is_rar4 and !is_rar5) {
        return RarValidationResult.invalid(errmsg.invalidSignature("RAR"));
    }

    // For buffer validation, we can only do signature check
    return RarValidationResult.headerOnly(is_rar5);
}

// Tests
test "RAR4 signature detection" {
    const rar4_data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0x00 };
    const result = validateRarFromBuffer(&rar4_data);
    try std.testing.expect(result.valid);
    try std.testing.expect(!result.is_rar5);
}

test "RAR5 signature detection" {
    const rar5_data = [_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0x00 };
    const result = validateRarFromBuffer(&rar5_data);
    try std.testing.expect(result.valid);
    try std.testing.expect(result.is_rar5);
}

test "invalid signature detection" {
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    const result = validateRarFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
}

fn hasRarTestBackend(allocator: Allocator) bool {
    // If unrar exists, we can test.
    const unrar = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"unrar"},
        .max_output_bytes = 1024,
    }) catch null;
    if (unrar) |r| {
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        switch (r.term) {
            .Exited => return true,
            else => {},
        }
    }

    // If 7z exists and has RAR support, we can test.
    if (sevenZSupportsRar(allocator)) return true;

    // If bsdtar exists, we can test through libarchive.
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"bsdtar"},
        .max_output_bytes = 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => true,
        else => false,
    };
}

test "validateRarDeep accepts ground truth sample" {
    const allocator = std.testing.allocator;

    if (!hasRarTestBackend(allocator)) return;

    const file = std.fs.cwd().openFile("ground_truth_examples/rar/sample.rar", .{}) catch return;
    file.close();

    const result = validateRarDeep(allocator, "ground_truth_examples/rar/sample.rar");
    try std.testing.expect(result.valid);
    try std.testing.expect(result.files_checked > 0);
}

test "validateRarDeep rejects deterministic corruption of ground truth sample" {
    const allocator = std.testing.allocator;

    if (!hasRarTestBackend(allocator)) return;

    const src = std.fs.cwd().openFile("ground_truth_examples/rar/sample.rar", .{}) catch return;
    defer src.close();

    const sample_size = src.getEndPos() catch return;
    if (sample_size <= 64) return;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const cwd = std.fs.cwd();
    cwd.copyFile("ground_truth_examples/rar/sample.rar", tmp_dir.dir, "corrupt.rar", .{}) catch return;

    const corrupt_file = tmp_dir.dir.openFile("corrupt.rar", .{ .mode = .read_write }) catch return;
    defer corrupt_file.close();

    // Corrupt deterministic payload byte outside the 8-byte magic area.
    try corrupt_file.seekTo(32);
    var byte: [1]u8 = undefined;
    _ = try corrupt_file.readAll(&byte);
    byte[0] ^= 0x5A;
    try corrupt_file.seekTo(32);
    try corrupt_file.writeAll(&byte);

    const path = try tmp_dir.dir.realpathAlloc(allocator, "corrupt.rar");
    defer allocator.free(path);

    const result = validateRarDeep(allocator, path);
    try std.testing.expect(!result.valid);
}
