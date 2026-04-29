//! Pure-Zig AVIF Validator
//!
//! Validates AVIF (AV1-coded) image files by parsing the ISOBMFF
//! container and validating the embedded AV1 intra-frame bitstream.
//! Replaces libheif for AVIF validation.

const std = @import("std");
const heap = @import("heap.zig");
const heif = @import("heif_container_parser.zig");
const av1 = @import("av1_obu_validator.zig");
const errmsg = @import("error_messages.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

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
pub fn validateAvifDeep(source: *FileSource) AvifValidationResult {
    const file_size = source.getEndPos() catch {
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

    const allocator = heap.validateAllocator();
    const data = allocator.alloc(u8, file_size) catch {
        return AvifValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = source.readAll(data) catch {
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

    // Route by primary item type
    if (primary_item_type == .av01) {
        // Direct AV1 image — validate the single item's AV1 bitstream
        return validateDirectAv1Item(data, container);
    } else if (primary_item_type == .grid) {
        // Grid image (tiled) — validate each tile's AV1 bitstream
        return validateAvifGridTiles(data, container);
    } else if (primary_item_type == .iovl) {
        return AvifValidationResult.structural();
    } else {
        return AvifValidationResult.invalid("Primary item is not AV1-coded");
    }
}

/// Validate a direct (non-tiled) AV1 item.
fn validateDirectAv1Item(data: []const u8, container: heif.HeifContainerInfo) AvifValidationResult {
    const width = container.width;
    const height = container.height;
    if (width == 0 or height == 0) return AvifValidationResult.structural();

    if (container.primary_data_length == 0) {
        return AvifValidationResult.invalid("Primary item has no data");
    }

    const data_start: usize = @intCast(container.primary_data_offset);
    const data_end: usize = data_start + @as(usize, @intCast(container.primary_data_length));
    if (data_end > data.len) {
        return AvifValidationResult.invalid("Primary item data extends beyond file");
    }

    const image_data = data[data_start..data_end];
    const result = validateAv1Data(image_data, container.decoder_config);

    if (result.valid and !result.structural_only) {
        return AvifValidationResult.okWithDimensions(width, height);
    }
    return result;
}

/// Validate a grid (tiled) AVIF image by resolving iref dimg tile references
/// and validating each tile's AV1 bitstream individually.
fn validateAvifGridTiles(data: []const u8, container: heif.HeifContainerInfo) AvifValidationResult {
    if (container.dimg_tile_ids.len == 0) {
        return AvifValidationResult.structural();
    }

    const decoder_config = container.tile_decoder_config orelse {
        return AvifValidationResult.structural();
    };

    var tiles_validated: usize = 0;
    var tiles_structural: usize = 0;

    for (container.dimg_tile_ids) |tile_id| {
        const loc = heif.findItemLocation(container.locations, tile_id) orelse continue;
        if (loc.construction_method != 0) {
            tiles_structural += 1;
            continue;
        }
        if (loc.extents.len == 0) continue;

        if (loc.extents.len == 1) {
            const offset: usize = @intCast(loc.base_offset + loc.extents[0].offset);
            const length: usize = @intCast(loc.extents[0].length);
            if (offset + length > data.len) {
                return AvifValidationResult.invalid("Tile data extends beyond file");
            }

            const tile_data = data[offset .. offset + length];
            const result = validateAv1Data(tile_data, decoder_config);

            if (!result.valid and !result.structural_only) {
                return result;
            }
            if (result.valid and !result.structural_only) {
                tiles_validated += 1;
            } else {
                tiles_structural += 1;
            }
        } else {
            tiles_structural += 1;
        }
    }

    if (tiles_validated > 0) {
        const width = container.width;
        const height = container.height;
        if (tiles_structural > 0) {
            return AvifValidationResult.okWithWarning(width, height, "Some grid tiles could not be fully validated");
        }
        return AvifValidationResult.okWithDimensions(width, height);
    }
    return AvifValidationResult.structural();
}

/// Validate AV1 OBU stream data from a single AVIF item (direct or tile).
/// Prepends av1C config OBUs (sequence header) to the image data and
/// validates the combined stream.
fn validateAv1Data(image_data: []const u8, decoder_config: ?[]const u8) AvifValidationResult {
    const max_combined = 2 * 1024 * 1024;
    const combined_buf = heap.validateAllocator().alloc(u8, max_combined) catch {
        return AvifValidationResult.structural();
    };
    defer heap.validateAllocator().free(combined_buf);
    var combined_len: usize = 0;

    // Prepend av1C sequence header OBU if available
    if (decoder_config) |config| {
        if (config.len >= 4) {
            // av1C: bytes 0-3 are fixed header, bytes 4+ are configOBUs
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
        @memcpy(combined_buf[0..image_data.len], image_data);
        combined_len = image_data.len;
    }

    if (combined_len < 4) return AvifValidationResult.structural();

    // AVIF images are single frames, so max_frames=1
    const av1_result = av1.validateAv1Stream(combined_buf[0..combined_len], 1);
    if (av1_result.valid) {
        return AvifValidationResult.ok();
    } else {
        if (av1_result.has_sequence_header) {
            const msg: []const u8 = if (av1_result.error_message) |e| std.mem.span(e) else "AV1 bitstream validation failed";
            return AvifValidationResult.invalid(msg);
        }
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

test "validateAv1Data does not blow the stack on small thread" {
    // Regression test: validateAv1Data previously used a 2MB stack buffer
    // which crashed on worker threads with 512KB-1MB stacks.
    // Run the function on a thread with a small (256KB) stack to verify
    // it no longer stack-overflows.
    const Thread = std.Thread;
    const thread = try Thread.spawn(.{ .stack_size = 256 * 1024 }, struct {
        fn run() void {
            // Minimal valid-looking AV1 data (will fail validation but must not crash)
            const fake_av1 = [_]u8{ 0x0A, 0x0D, 0x00, 0x00, 0x00, 0x24, 0x4F, 0x7E, 0x7F, 0x00, 0x68, 0x83, 0x00, 0x83, 0x02 };
            const result = validateAv1Data(&fake_av1, null);
            // We don't care if it's valid — only that it didn't segfault
            _ = result;
        }
    }.run, .{});
    thread.join();
}
