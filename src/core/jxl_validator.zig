//! Deep JPEG-XL validation through the jpegz strict facade (`tiffz.jpegz`),
//! which runs the same libjxlz strict validator underneath.
//!
//! The adapter preserves the four-way verdict and stable evidence so an
//! unsupported feature or incomplete check can never masquerade as corruption.
//! jpegz is reached through tiffz's re-export so the build graph holds exactly
//! ONE libjxlz module instance (a direct dep here collided with jpegz's own
//! libjxlz pin — same failure class as the jpegz double-pin, see #32).

const std = @import("std");
const errmsg = @import("error_messages.zig");
const heap = @import("heap.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const jpegz = @import("tiffz").jpegz;

/// Threshold for warning about large image files (200MB)
const large_image_threshold: u64 = 200 * 1024 * 1024;

pub const JxlVerdict = enum {
    valid,
    corrupt,
    unsupported,
    indeterminate,
};

pub const JxlFindingCode = enum {
    none,
    invalid_signature,
    truncated,
    malformed,
    unsupported_feature,
    resource_limit,
    out_of_memory,
    invalid_argument,
    unclassified_decoder_error,
    /// This build carries no JXL validator (e.g. Windows, where Brotli is
    /// unavailable). Indeterminate, never corrupt: "could not check" is not
    /// evidence of damage.
    validator_unavailable,
};

pub const JxlValidationLimits = struct {
    host_byte_offset: u64 = 0,
    max_input_bytes: usize = 512 * 1024 * 1024,
    max_pixels: u64 = 268_435_456,
    max_frames: u32 = 65_535,
};

/// Result of deep JPEG-XL validation
pub const JxlValidationResult = struct {
    /// Legacy compatibility bit: true means "not proven corrupt." Callers
    /// making support claims must inspect `verdict` instead.
    valid: bool,
    structural_only: bool = false,
    verdict: JxlVerdict,
    finding_code: JxlFindingCode,
    error_message: ?[]const u8,
    warning_message: ?[]const u8 = null,
    byte_offset: u64 = 0,
    host_byte_offset: u64 = 0,
    offset_is_exact: bool = false,
    frames_validated: u32 = 0,
};

fn indeterminate(message: []const u8, code: JxlFindingCode) JxlValidationResult {
    return .{
        .valid = true,
        .structural_only = true,
        .verdict = .indeterminate,
        .finding_code = code,
        .error_message = null,
        .warning_message = message,
    };
}

/// Validate a JPEG-XL file by attempting full decompression.
/// Returns validation result with error details if invalid.
pub fn validateJxlDeep(source: *FileSource) JxlValidationResult {
    const file_size = source.getEndPos() catch {
        return indeterminate(errmsg.failedToGet("file size"), .unclassified_decoder_error);
    };
    const is_large_file = file_size > large_image_threshold;

    const allocator = heap.validateAllocator();
    const slurp = source.getMappedOrSlurp(allocator, 64 << 20) catch {
        return indeterminate(errmsg.failedToRead("file"), .unclassified_decoder_error);
    };
    var heap_jxl: ?[]u8 = null;
    defer if (heap_jxl) |buf| allocator.free(buf);
    const buf_slice: []const u8 = switch (slurp) {
        .mapped => |m| m,
        .heap => |b| blk: { heap_jxl = b; break :blk b; },
        .too_large => return indeterminate("JPEG XL too large for non-mmap deep validation", .resource_limit),
    };
    if (buf_slice.len != file_size) {
        return indeterminate(errmsg.incomplete("file read"), .unclassified_decoder_error);
    }

    var result = validateJxlDeepFromBuffer(buf_slice);
    if (result.verdict == .valid and is_large_file) {
        result.warning_message = "Large image file (>200MB)";
    }
    return result;
}

/// Validate JPEG-XL from memory buffer.
pub fn validateJxlDeepFromBuffer(data: []const u8) JxlValidationResult {
    return validateJxlDeepFromBufferWithLimits(data, .{});
}

/// Validate one bounded memory view while preserving strict four-way evidence.
/// Routes through jpegz's JXL facade; `jpegz.jpegxl.Options` IS libjxlz's
/// Options on JXL-capable builds, so the resource limits pass through 1:1. On
/// builds without a JXL validator (Windows/no-Brotli) the facade's Options
/// stub only carries `host_byte_offset` — the @hasField guards keep this file
/// compiling there, and the facade answers indeterminate/validator_unavailable.
pub fn validateJxlDeepFromBufferWithLimits(data: []const u8, limits: JxlValidationLimits) JxlValidationResult {
    // On JXL-capable builds `jpegz.jpegxl.Options` IS libjxlz's C-ABI Options
    // (no field defaults — every field must be named); the no-Brotli stub
    // carries only `host_byte_offset`. Branch at comptime on the ABI marker.
    const options: jpegz.jpegxl.Options = if (comptime @hasField(jpegz.jpegxl.Options, "struct_size"))
        .{
            .struct_size = @sizeOf(jpegz.jpegxl.Options),
            .host_byte_offset = limits.host_byte_offset,
            .max_input_bytes = limits.max_input_bytes,
            .max_pixels = limits.max_pixels,
            .max_frames = limits.max_frames,
        }
    else
        .{ .host_byte_offset = limits.host_byte_offset };
    const allocator = heap.validateAllocator();
    var strict = jpegz.jpegxl.validate(allocator, data, options) catch {
        return indeterminate(findingMessage(.out_of_memory).?, .out_of_memory);
    };
    defer strict.deinit(allocator);
    return mapStrictResult(&strict);
}

/// Map a jpegz FindingCode (the 180..188 JXL band) onto validate's local enum.
fn codeFromJpegz(code: ?jpegz.FindingCode) JxlFindingCode {
    const c = code orelse return .unclassified_decoder_error;
    return switch (c) {
        .jxl_invalid_signature => .invalid_signature,
        .jxl_truncated => .truncated,
        .jxl_malformed => .malformed,
        .jxl_unsupported_feature => .unsupported_feature,
        .jxl_resource_limit => .resource_limit,
        .jxl_out_of_memory => .out_of_memory,
        .jxl_invalid_argument => .invalid_argument,
        .jxl_validator_unavailable => .validator_unavailable,
        else => .unclassified_decoder_error,
    };
}

/// Flatten jpegz's StrictValidationResult (verdict + findings list) into
/// validate's stable JxlValidationResult. The scalar copies happen before the
/// caller deinits the strict result; messages are static strings owned here.
fn mapStrictResult(strict: *const jpegz.StrictValidationResult) JxlValidationResult {
    const verdict: JxlVerdict = switch (strict.verdict) {
        .valid => .valid,
        .corrupt => .corrupt,
        .unsupported => .unsupported,
        .indeterminate => .indeterminate,
    };
    var code: JxlFindingCode = if (verdict == .valid) .none else .unclassified_decoder_error;
    var byte_offset: u64 = 0;
    var host_byte_offset: u64 = 0;
    var offset_is_exact = false;
    if (strict.findings.items.len > 0) {
        const finding = strict.findings.items[0];
        if (verdict != .valid) code = codeFromJpegz(finding.code);
        byte_offset = finding.offset orelse 0;
        host_byte_offset = finding.host_offset orelse 0;
        offset_is_exact = finding.offset_is_exact;
    }
    const message = findingMessage(code);
    return .{
        .valid = verdict != .corrupt,
        .structural_only = verdict == .unsupported or verdict == .indeterminate,
        .verdict = verdict,
        .finding_code = code,
        .error_message = if (verdict == .corrupt) message else null,
        .warning_message = if (verdict == .unsupported or verdict == .indeterminate) message else null,
        .byte_offset = byte_offset,
        .host_byte_offset = host_byte_offset,
        .offset_is_exact = offset_is_exact,
        .frames_validated = strict.frames_validated,
    };
}

fn findingMessage(code: JxlFindingCode) ?[]const u8 {
    return switch (code) {
        .none => null,
        .invalid_signature => "Invalid JPEG XL signature",
        .truncated => "Truncated JPEG XL input",
        .malformed => "Malformed JPEG XL bitstream",
        .unsupported_feature => "JPEG XL feature is not supported by the strict validator",
        .resource_limit => "JPEG XL validation resource limit reached",
        .out_of_memory => "JPEG XL validation ran out of memory",
        .invalid_argument => "Invalid JPEG XL validation argument",
        .unclassified_decoder_error => "JPEG XL validator could not classify the decoder error",
        .validator_unavailable => "JPEG XL validator not available in this build",
    };
}

// Tests
test "reject invalid data with expected stderr" {
    // Test that invalid data is rejected
    const invalid_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = validateJxlDeepFromBuffer(&invalid_data);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(JxlVerdict.corrupt, result.verdict);
    try std.testing.expect(result.offset_is_exact);
    // Note: stderr message checking removed - libjxl doesn't output messages in release mode
}

test "resource-limited JXL validation is indeterminate, not corrupt" {
    const data = [_]u8{ 0xFF, 0x0A, 0x00, 0x00 };
    const result = validateJxlDeepFromBufferWithLimits(&data, .{
        .max_input_bytes = 2,
        .max_pixels = 1,
        .max_frames = 1,
    });

    try std.testing.expectEqual(JxlVerdict.indeterminate, result.verdict);
    try std.testing.expectEqual(JxlFindingCode.resource_limit, result.finding_code);
}

test "jpegz strict unsupported verdict remains distinct" {
    var findings: std.ArrayList(jpegz.StrictFinding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try findings.append(std.testing.allocator, .{
        .source = .libjxlz,
        .leaf_code = 4,
        .code = .jxl_unsupported_feature,
        .severity = .warn,
        .offset = 17,
        .host_offset = 117,
        .offset_is_exact = true,
    });
    const strict = jpegz.StrictValidationResult{
        .verdict = .unsupported,
        .format = .jpeg_xl,
        .frames_validated = 2,
        .findings = findings,
    };

    const result = mapStrictResult(&strict);

    try std.testing.expectEqual(JxlVerdict.unsupported, result.verdict);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(JxlFindingCode.unsupported_feature, result.finding_code);
    try std.testing.expect(result.warning_message != null);
    try std.testing.expectEqual(@as(u64, 17), result.byte_offset);
    try std.testing.expectEqual(@as(u64, 117), result.host_byte_offset);
    try std.testing.expect(result.offset_is_exact);
    try std.testing.expectEqual(@as(u32, 2), result.frames_validated);
}

test "jpegz validator_unavailable maps to indeterminate, never corrupt" {
    var findings: std.ArrayList(jpegz.StrictFinding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try findings.append(std.testing.allocator, .{
        .source = .libjxlz,
        .leaf_code = 188,
        .code = .jxl_validator_unavailable,
        .severity = .warn,
    });
    const strict = jpegz.StrictValidationResult{
        .verdict = .indeterminate,
        .format = .jpeg_xl,
        .findings = findings,
    };

    const result = mapStrictResult(&strict);

    try std.testing.expectEqual(JxlVerdict.indeterminate, result.verdict);
    try std.testing.expect(result.valid); // "not proven corrupt" legacy bit
    try std.testing.expect(result.structural_only);
    try std.testing.expectEqual(JxlFindingCode.validator_unavailable, result.finding_code);
    try std.testing.expect(result.warning_message != null);
    try std.testing.expect(result.error_message == null);
}

test "truncated JXL is never accepted even when libjxlz cannot type the decoder error" {
    // JXL signature but nothing else
    // JPEG-XL codestream starts with 0xFF 0x0A
    const truncated = [_]u8{ 0xFF, 0x0A, 0x00, 0x00 };
    const result = validateJxlDeepFromBuffer(&truncated);
    try std.testing.expect(result.verdict == .corrupt or result.verdict == .indeterminate);
    if (result.verdict == .indeterminate) {
        try std.testing.expectEqual(JxlFindingCode.unclassified_decoder_error, result.finding_code);
    }
}

test "reject container with truncated box and expected stderr" {
    // JPEG-XL container starts with ftyp box: 00 00 00 0C 4A 58 4C 20
    const truncated_container = [_]u8{
        0x00, 0x00, 0x00, 0x0C, // box size
        'J', 'X', 'L', ' ', // box type
        0x00, 0x00, // truncated data
    };
    const result = validateJxlDeepFromBuffer(&truncated_container);
    try std.testing.expect(!result.valid);
    // Note: stderr message checking removed - libjxl doesn't output messages in release mode
}
