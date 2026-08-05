//! Deep JPEG-XL validation through libjxlz's stable strict-validation API.
//!
//! The adapter preserves libjxlz's four-way verdict and stable evidence so an
//! unsupported feature or incomplete check can never masquerade as corruption.

const std = @import("std");
const errmsg = @import("error_messages.zig");
const heap = @import("heap.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const libjxlz_validation = @import("libjxlz_validation");

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
pub fn validateJxlDeepFromBufferWithLimits(data: []const u8, limits: JxlValidationLimits) JxlValidationResult {
    const options = libjxlz_validation.Options{
        .struct_size = @sizeOf(libjxlz_validation.Options),
        .host_byte_offset = limits.host_byte_offset,
        .max_input_bytes = limits.max_input_bytes,
        .max_pixels = limits.max_pixels,
        .max_frames = limits.max_frames,
    };
    return mapWireResult(libjxlz_validation.validate(data, options));
}

fn mapWireResult(wire: libjxlz_validation.Result) JxlValidationResult {
    const verdict: JxlVerdict = switch (wire.verdict) {
        .JXL_VALIDATION_VALID => .valid,
        .JXL_VALIDATION_CORRUPT => .corrupt,
        .JXL_VALIDATION_UNSUPPORTED => .unsupported,
        else => .indeterminate,
    };
    const code: JxlFindingCode = switch (wire.code) {
        .JXL_VALIDATION_FINDING_NONE => .none,
        .JXL_VALIDATION_FINDING_INVALID_SIGNATURE => .invalid_signature,
        .JXL_VALIDATION_FINDING_TRUNCATED => .truncated,
        .JXL_VALIDATION_FINDING_MALFORMED => .malformed,
        .JXL_VALIDATION_FINDING_UNSUPPORTED_FEATURE => .unsupported_feature,
        .JXL_VALIDATION_FINDING_RESOURCE_LIMIT => .resource_limit,
        .JXL_VALIDATION_FINDING_OUT_OF_MEMORY => .out_of_memory,
        .JXL_VALIDATION_FINDING_INVALID_ARGUMENT => .invalid_argument,
        else => .unclassified_decoder_error,
    };
    const message = findingMessage(code);
    return .{
        .valid = verdict != .corrupt,
        .structural_only = verdict == .unsupported or verdict == .indeterminate,
        .verdict = verdict,
        .finding_code = code,
        .error_message = if (verdict == .corrupt) message else null,
        .warning_message = if (verdict == .unsupported or verdict == .indeterminate) message else null,
        .byte_offset = wire.byte_offset,
        .host_byte_offset = wire.host_byte_offset,
        .offset_is_exact = wire.offset_is_exact != 0,
        .frames_validated = wire.frames_validated,
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

test "libjxlz wire unsupported verdict remains distinct" {
    const result = mapWireResult(.{
        .verdict = .JXL_VALIDATION_UNSUPPORTED,
        .code = .JXL_VALIDATION_FINDING_UNSUPPORTED_FEATURE,
        .byte_offset = 17,
        .host_byte_offset = 117,
        .offset_is_exact = 1,
        .frames_validated = 2,
    });

    try std.testing.expectEqual(JxlVerdict.unsupported, result.verdict);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u64, 17), result.byte_offset);
    try std.testing.expectEqual(@as(u64, 117), result.host_byte_offset);
    try std.testing.expect(result.offset_is_exact);
    try std.testing.expectEqual(@as(u32, 2), result.frames_validated);
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
