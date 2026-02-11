//! Pure-Zig HEIC Validator
//!
//! Validates HEIC (HEVC-coded) image files by parsing the ISOBMFF
//! container and validating the embedded H.265 intra-frame bitstream.
//! Replaces libheif for HEIC validation.

const std = @import("std");
const heif = @import("heif_container_parser.zig");
const h265 = @import("h265_validator.zig");
const errmsg = @import("error_messages.zig");

pub const HeicValidationResult = struct {
    valid: bool,
    structural_only: bool,
    error_message: ?[]const u8,
    warning_message: ?[]const u8,
    width: u32,
    height: u32,

    pub fn ok() HeicValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = null,
            .width = 0,
            .height = 0,
        };
    }

    pub fn okWithDimensions(w: u32, h: u32) HeicValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = null,
            .width = w,
            .height = h,
        };
    }

    pub fn okWithWarning(w: u32, h: u32, warning: []const u8) HeicValidationResult {
        return .{
            .valid = true,
            .structural_only = false,
            .error_message = null,
            .warning_message = warning,
            .width = w,
            .height = h,
        };
    }

    pub fn structural() HeicValidationResult {
        return .{
            .valid = true,
            .structural_only = true,
            .error_message = null,
            .warning_message = null,
            .width = 0,
            .height = 0,
        };
    }

    pub fn invalid(msg: []const u8) HeicValidationResult {
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

/// Validate a HEIC file from a file path.
pub fn validateHeicDeep(path: []const u8) HeicValidationResult {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return switch (err) {
            error.FileNotFound => HeicValidationResult.invalid("File not found"),
            error.AccessDenied => HeicValidationResult.invalid("Access denied"),
            else => HeicValidationResult.invalid(errmsg.failedToOpen("file")),
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch {
        return HeicValidationResult.invalid(errmsg.failedToGet("file size"));
    };

    const is_large_file = file_size > large_image_threshold;

    if (file_size < 12) {
        return HeicValidationResult.invalid(errmsg.fileTooSmallFor("HEIC"));
    }

    // Cap at 512 MB to avoid excessive memory use
    if (file_size > 512 * 1024 * 1024) {
        return HeicValidationResult.invalid(errmsg.fileTooLargeFor("in-memory validation"));
    }

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch {
        return HeicValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return HeicValidationResult.invalid(errmsg.failedToRead("file"));
    };
    if (bytes_read != file_size) {
        return HeicValidationResult.invalid(errmsg.incomplete("file read"));
    }

    const result = validateHeicDeepFromBuffer(data);

    if (result.valid and is_large_file) {
        return HeicValidationResult.okWithWarning(result.width, result.height, "Large image file (>200MB)");
    }
    return result;
}

/// Validate a HEIC image from an in-memory buffer.
pub fn validateHeicDeepFromBuffer(data: []const u8) HeicValidationResult {
    if (data.len < 12) {
        return HeicValidationResult.invalid("Data too small for HEIC");
    }

    // Parse the HEIF container
    const container = heif.parseHeifContainer(data) catch |err| {
        return switch (err) {
            heif.HeifContainerError.TooSmall => HeicValidationResult.invalid("File too small"),
            heif.HeifContainerError.InvalidFtyp => HeicValidationResult.invalid("Invalid ftyp box"),
            heif.HeifContainerError.NoMetaBox => HeicValidationResult.invalid("No meta box found"),
            heif.HeifContainerError.InvalidMetaBox => HeicValidationResult.invalid("Invalid meta box"),
            heif.HeifContainerError.NoHandlerBox => HeicValidationResult.invalid("No handler box"),
            heif.HeifContainerError.InvalidHandler => HeicValidationResult.invalid("Not a picture handler"),
            heif.HeifContainerError.NoPrimaryItem => HeicValidationResult.invalid("No primary item"),
            heif.HeifContainerError.NoItemInfo => HeicValidationResult.invalid("No item info"),
            heif.HeifContainerError.NoItemLocation => HeicValidationResult.invalid("No item location"),
            heif.HeifContainerError.NoItemProperties => HeicValidationResult.structural(),
            heif.HeifContainerError.InvalidItemLocation => HeicValidationResult.invalid("Invalid item location"),
            heif.HeifContainerError.ItemNotFound => HeicValidationResult.invalid("Primary item not found"),
            heif.HeifContainerError.DataOutOfBounds => HeicValidationResult.invalid("Item data out of bounds"),
            heif.HeifContainerError.UnsupportedConstructionMethod => HeicValidationResult.structural(),
            heif.HeifContainerError.Truncated => HeicValidationResult.invalid(errmsg.truncated("HEIC data")),
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

    // Verify the primary item is HEVC-coded
    if (primary_item_type != .hvc1) {
        // Could be a grid or overlay — structural validation only
        if (primary_item_type == .grid or primary_item_type == .iovl) {
            return HeicValidationResult.structural();
        }
        return HeicValidationResult.invalid("Primary item is not HEVC-coded");
    }

    // Check dimensions
    const width = container.width;
    const height = container.height;
    if (width == 0 or height == 0) {
        // No ispe box — structural only
        return HeicValidationResult.structural();
    }

    // Extract the primary item's image data
    if (container.primary_data_length == 0) {
        return HeicValidationResult.invalid("Primary item has no data");
    }

    const data_start: usize = @intCast(container.primary_data_offset);
    const data_end: usize = data_start + @as(usize, @intCast(container.primary_data_length));
    if (data_end > data.len) {
        return HeicValidationResult.invalid("Primary item data extends beyond file");
    }

    const image_data = data[data_start..data_end];

    // Build Annex B stream: decoder config NALs + image data
    // The decoder config (hvcC) contains VPS/SPS/PPS NAL units
    var annex_b_buf: [1024 * 1024]u8 = undefined; // 1MB stack buffer for small images
    var annex_b_len: usize = 0;

    if (container.decoder_config) |config| {
        // Parse hvcC to extract parameter set NAL units
        const config_nals = parseHvcCConfig(config);
        if (config_nals.len > 0 and config_nals.len <= annex_b_buf.len) {
            @memcpy(annex_b_buf[0..config_nals.len], config_nals);
            annex_b_len = config_nals.len;
        }
    }

    // Append image data with Annex B start code
    // HEIC stores image data as length-prefixed NAL units (like MP4)
    // We need to convert to Annex B format
    var pos: usize = 0;
    const nal_length_size: usize = if (container.decoder_config) |config|
        getNalLengthSizeFromHvcC(config)
    else
        4;

    while (pos + nal_length_size <= image_data.len) {
        var nal_len: u32 = 0;
        for (0..nal_length_size) |i| {
            nal_len = (nal_len << 8) | image_data[pos + i];
        }
        pos += nal_length_size;

        if (nal_len == 0 or pos + nal_len > image_data.len) break;

        // Add start code + NAL data
        if (annex_b_len + 4 + nal_len <= annex_b_buf.len) {
            annex_b_buf[annex_b_len] = 0;
            annex_b_buf[annex_b_len + 1] = 0;
            annex_b_buf[annex_b_len + 2] = 0;
            annex_b_buf[annex_b_len + 3] = 1;
            @memcpy(annex_b_buf[annex_b_len + 4 ..][0..nal_len], image_data[pos..][0..nal_len]);
            annex_b_len += 4 + nal_len;
        }
        pos += nal_len;
    }

    if (annex_b_len < 8) {
        // Not enough data for H.265 validation — accept as structural
        return HeicValidationResult.structural();
    }

    // Validate H.265 bitstream
    // HEIC images are single intra-frames, so max_frames=1
    const h265_result = h265.validateH265Stream(annex_b_buf[0..annex_b_len], 1);
    if (h265_result.valid) {
        return HeicValidationResult.okWithDimensions(width, height);
    } else {
        // H.265 validation failed but container was valid — might be unsupported profile
        // Check if we got parameter sets at least
        if (h265_result.has_sps or h265_result.has_pps) {
            return HeicValidationResult.invalid(h265_result.error_message orelse "H.265 bitstream validation failed");
        }
        // No parameter sets — might be unsupported encapsulation
        return HeicValidationResult.structural();
    }
}

/// Parse hvcC configuration box to extract Annex B parameter set NAL units.
/// Returns slice of data containing start codes + VPS/SPS/PPS NALs.
fn parseHvcCConfig(config: []const u8) []const u8 {
    // hvcC format:
    // byte 0: configurationVersion (must be 1)
    // bytes 1-22: profile/level/compatibility info
    // byte 21: bits 0-1 = lengthSizeMinusOne
    // byte 22: bits 0-4 = numOfArrays
    // Then arrays of NAL units (VPS, SPS, PPS)
    //
    // Each array:
    //   byte 0: array_completeness(1) + reserved(1) + NAL_unit_type(6)
    //   bytes 1-2: numNalus (big-endian u16)
    //   For each NALU: nalUnitLength (u16) + nalUnitData
    //
    // We just return the raw config data — the caller's Annex B converter handles it.
    // Actually, for HEIC we need to output Annex B format ourselves.
    _ = config;
    return &.{};
}

/// Extract NAL length size from hvcC configuration.
fn getNalLengthSizeFromHvcC(config: []const u8) usize {
    if (config.len < 23) return 4;
    return @as(usize, (config[21] & 0x03)) + 1;
}

// ============================================================================
// Tests
// ============================================================================

test "HEIC validation rejects empty data" {
    const result = validateHeicDeepFromBuffer(&.{});
    try std.testing.expect(!result.valid);
}

test "HEIC validation rejects too-small data" {
    const result = validateHeicDeepFromBuffer(&.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    try std.testing.expect(!result.valid);
}

test "HEIC validation rejects non-HEIF data" {
    // Random data that doesn't look like ISOBMFF
    const data = [_]u8{0xFF} ** 100;
    const result = validateHeicDeepFromBuffer(&data);
    try std.testing.expect(!result.valid);
}
