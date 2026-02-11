//! Pure-Zig AVIF Validator
//!
//! Validates AVIF (AV1-coded) image files by parsing the ISOBMFF
//! container and validating the embedded AV1 intra-frame bitstream.
//! Replaces libheif for AVIF validation.

const std = @import("std");
const heif = @import("heif_container_parser.zig");
const av1 = @import("av1_obu_validator.zig");
const errmsg = @import("error_messages.zig");

pub const AvifValidationResult = struct {
    valid: bool,
    structural_only: bool,
    error_message: ?[]const u8,
    warning_message: ?[]const u8,
    width: u32,
    height: u32,

    pub fn ok() AvifValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = null,
            .width = 0,
            .height = 0,
        };
    }

    pub fn okWithDimensions(w: u32, h: u32) AvifValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = null,
            .width = w,
            .height = h,
        };
    }

    pub fn okWithWarning(w: u32, h: u32, warning: []const u8) AvifValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = warning,
            .width = w,
            .height = h,
        };
    }

    pub fn structural() AvifValidationResult {
        return .{
            .valid = true,
            .structural_only = true,
            .error_message = null,
            .warning_message = null,
            .width = 0,
            .height = 0,
        };
    }

    pub fn invalid(msg: []const u8) AvifValidationResult {
        return .{
            .valid = false,
            .structural_only = false,
            .error_message = msg,
            .warning_message = null,
            .width = 0,
            .height = 0,
        };
    }
};

const large_image_threshold: u64 = 200 * 1024 * 1024; // 200 MB

/// Validate an AVIF file from a file path.
pub fn validateAvifDeep(path: []const u8) AvifValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => AvifValidationResult.invalid("File not found"),
            error.AccessDenied => AvifValidationResult.invalid("Access denied"),
            else => AvifValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return AvifValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    const is_large_file = file_size > large_image_threshold;

    if (file_size < 12) {
        return AvifValidationResult.invalid(errmsg.fileTooSmallFor("AVIF"));
    }

    // Cap at 512 MB
    if (file_size > 512 * 1024 * 1024) {
        return AvifValidationResult.invalid(errmsg.fileTooLargeFor("in-memory validation"));
    }

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch {
        return AvifValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return AvifValidationResult.invalid(errmsg.failedToRead("file"));
    };
    if (bytes_read != file_size) {
        return AvifValidationResult.invalid(errmsg.incomplete("file read"));
    }

    const result = validateAvifDeepFromBuffer(data);

    if (result.valid and is_large_file) {
        return AvifValidationResult.okWithWarning(result.width, result.height, "Large image file (>200MB)");
    }
    return result;
}

/// Validate an AVIF image from an in-memory buffer.
pub fn validateAvifDeepFromBuffer(data: []const u8) AvifValidationResult {
    if (data.len < 12) {
        return AvifValidationResult.invalid("Data too small for AVIF");
    }

    // Parse the HEIF container
    const container = heif.parseHeifContainer(data) catch |err| {
        return switch (err) {
            heif.HeifContainerError.TooSmall => AvifValidationResult.invalid("File too small"),
            heif.HeifContainerError.InvalidFtyp => AvifValidationResult.invalid("Invalid ftyp box"),
            heif.HeifContainerError.NoMetaBox => AvifValidationResult.invalid("No meta box found"),
            heif.HeifContainerError.InvalidMetaBox => AvifValidationResult.invalid("Invalid meta box"),
            heif.HeifContainerError.NoHandlerBox => AvifValidationResult.invalid("No handler box"),
            heif.HeifContainerError.InvalidHandler => AvifValidationResult.invalid("Not a picture handler"),
            heif.HeifContainerError.NoPrimaryItem => AvifValidationResult.invalid("No primary item"),
            heif.HeifContainerError.NoItemInfo => AvifValidationResult.invalid("No item info"),
            heif.HeifContainerError.NoItemLocation => AvifValidationResult.invalid("No item location"),
            heif.HeifContainerError.NoItemProperties => AvifValidationResult.structural(),
            heif.HeifContainerError.InvalidItemLocation => AvifValidationResult.invalid("Invalid item location"),
            heif.HeifContainerError.ItemNotFound => AvifValidationResult.invalid("Primary item not found"),
            heif.HeifContainerError.DataOutOfBounds => AvifValidationResult.invalid("Item data out of bounds"),
            heif.HeifContainerError.UnsupportedConstructionMethod => AvifValidationResult.structural(),
            heif.HeifContainerError.Truncated => AvifValidationResult.invalid(errmsg.truncated("AVIF data")),
        };
    };

    // Look up primary item type from items list
    var primary_item_type: heif.ItemType = .unknown;
    for (container.items) |item| {
        if (item.item_id == container.primary_item_id) {
            primary_item_type = item.item_type;
            break;
        }
    }

    // Verify the primary item is AV1-coded
    if (primary_item_type != .av01) {
        // Could be a grid or overlay — structural validation only
        if (primary_item_type == .grid or primary_item_type == .iovl) {
            return AvifValidationResult.structural();
        }
        return AvifValidationResult.invalid("Primary item is not AV1-coded");
    }

    // Check dimensions
    const width = container.width;
    const height = container.height;
    if (width == 0 or height == 0) {
        return AvifValidationResult.structural();
    }

    // Extract the primary item's image data
    if (container.primary_data_length == 0) {
        return AvifValidationResult.invalid("Primary item has no data");
    }

    const data_start: usize = @intCast(container.primary_data_offset);
    const data_end: usize = data_start + @as(usize, @intCast(container.primary_data_length));
    if (data_end > data.len) {
        return AvifValidationResult.invalid("Primary item data extends beyond file");
    }

    const image_data = data[data_start..data_end];

    // Build OBU stream: decoder config + image data
    // For AVIF, the av1C config box contains an AV1 Sequence Header OBU
    // and the image data contains a single frame's OBUs

    // First try: validate the image data as a standalone AV1 OBU stream
    // The image data should contain sequence header + frame OBUs
    var combined_buf: [2 * 1024 * 1024]u8 = undefined; // 2MB stack buffer
    var combined_len: usize = 0;

    // Prepend av1C sequence header OBU if available
    if (container.decoder_config) |config| {
        if (config.len >= 4) {
            // av1C format: marker(1) + version(7) + seq_profile(3) + seq_level_idx(5) + ...
            // The config box is followed by configOBUs which are raw OBUs
            // In practice, bytes 0-3 are the fixed header and bytes 4+ are OBUs
            const obu_data = config[4..];
            if (obu_data.len > 0 and obu_data.len <= combined_buf.len) {
                @memcpy(combined_buf[0..obu_data.len], obu_data);
                combined_len = obu_data.len;
            }
        }
    }

    // Append image data (raw AV1 OBUs)
    if (combined_len + image_data.len <= combined_buf.len) {
        @memcpy(combined_buf[combined_len..][0..image_data.len], image_data);
        combined_len += image_data.len;
    } else if (image_data.len <= combined_buf.len) {
        // Config too large, try just image data
        @memcpy(combined_buf[0..image_data.len], image_data);
        combined_len = image_data.len;
    }

    if (combined_len < 4) {
        return AvifValidationResult.structural();
    }

    // Validate AV1 OBU stream
    // AVIF images are single frames, so max_frames=1
    const av1_result = av1.validateAv1Stream(combined_buf[0..combined_len], 1);
    if (av1_result.valid) {
        return AvifValidationResult.okWithDimensions(width, height);
    } else {
        // AV1 validation failed but container was valid
        if (av1_result.has_sequence_header) {
            const msg: []const u8 = if (av1_result.error_message) |e| std.mem.span(e) else "AV1 bitstream validation failed";
            return AvifValidationResult.invalid(msg);
        }
        // No sequence header — might be unsupported encapsulation
        return AvifValidationResult.structural();
    }
}

// ============================================================================
// Tests
// ============================================================================

test "AVIF validation rejects empty data" {
    const result = validateAvifDeepFromBuffer(&.{});
    try std.testing.expect(!result.valid);
}

test "AVIF validation rejects too-small data" {
    const result = validateAvifDeepFromBuffer(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expect(!result.valid);
}

test "AVIF validation rejects non-HEIF data" {
    const data = [_]u8{0xFF} ** 100;
    const result = validateAvifDeepFromBuffer(&data);
    try std.testing.expect(!result.valid);
}
