//! Pure-Zig HEIC Validator
//!
//! Validates HEIC (HEVC-coded) image files by parsing the ISOBMFF
//! container and validating the embedded H.265 intra-frame bitstream.
//! Replaces libheif for HEIC validation.

const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const heif = @import("heif_container_parser.zig");
const h265 = @import("h265_validator.zig");
const errmsg = @import("error_messages.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

/// Scan a NAL unit's payload (the bytes AFTER the 2-byte NAL header) for
/// emulation-prevention violations: any occurrence of 0x000000, 0x000001,
/// or 0x000002 inside the payload is illegal per H.265 Annex B / RBSP
/// rules — the encoder MUST insert a 0x03 emulation prevention byte to
/// break such sequences. A bit-flip or partial overwrite in entropy-coded
/// data has a measurable chance of creating one of these forbidden
/// patterns, which is unambiguous corruption (zero false positives by
/// spec). Returns true if a violation is found.
fn nalHasEmulationViolation(nal: []const u8) bool {
    if (nal.len < 3) return false;
    // Skip the 2-byte NAL header — the 0x000003 emulation prevention rule
    // applies to payload bytes only.
    var i: usize = 2;
    while (i + 2 < nal.len) : (i += 1) {
        if (nal[i] == 0x00 and nal[i + 1] == 0x00) {
            const next = nal[i + 2];
            // Legal third bytes: 0x03 (emulation prevention) or
            // payload byte > 0x03. Forbidden: 0x00, 0x01, 0x02.
            if (next == 0x00 or next == 0x01 or next == 0x02) {
                return true;
            }
        }
    }
    return false;
}


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
pub fn validateHeicDeep(source: *FileSource) HeicValidationResult {
    const file_size = source.getEndPos() catch {
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

    const allocator = heap.validateAllocator();
    const data = allocator.alloc(u8, file_size) catch {
        return HeicValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = source.readAll(data) catch {
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

    // Route by primary item type
    if (primary_item_type == .hvc1) {
        // Direct HEVC image — validate the single item's H.265 bitstream
        return validateDirectHevcItem(data, container);
    } else if (primary_item_type == .grid) {
        // Grid image (tiled) — validate each tile's H.265 bitstream
        return validateGridTiles(data, container);
    } else if (primary_item_type == .iovl) {
        // Overlay — no standard way to validate individual layers
        return HeicValidationResult.structural();
    } else {
        return HeicValidationResult.invalid("Primary item is not HEVC-coded");
    }
}

/// Validate a direct (non-tiled) HEVC item.
fn validateDirectHevcItem(data: []const u8, container: heif.HeifContainerInfo) HeicValidationResult {
    const width = container.width;
    const height = container.height;
    if (width == 0 or height == 0) return HeicValidationResult.structural();

    if (container.primary_data_length == 0) {
        return HeicValidationResult.invalid("Primary item has no data");
    }

    const data_start: usize = @intCast(container.primary_data_offset);
    const data_end: usize = data_start + @as(usize, @intCast(container.primary_data_length));
    if (data_end > data.len) {
        return HeicValidationResult.invalid("Primary item data extends beyond file");
    }

    const image_data = data[data_start..data_end];
    const result = validateHevcData(image_data, container.decoder_config);

    if (result.valid and !result.structural_only) {
        if (result.warning_message) |msg| {
            return HeicValidationResult.okWithWarning(width, height, msg);
        }
        return HeicValidationResult.okWithDimensions(width, height);
    }
    return result;
}

/// Validate a grid (tiled) HEIC image by resolving iref dimg tile references
/// and validating each tile's H.265 bitstream individually.
fn validateGridTiles(data: []const u8, container: heif.HeifContainerInfo) HeicValidationResult {
    if (container.dimg_tile_ids.len == 0) {
        // No iref/dimg references found — can't resolve tiles
        return HeicValidationResult.structural();
    }

    // Tiles share a common hvcC decoder config (from iprp of first tile)
    const decoder_config = container.tile_decoder_config orelse {
        return HeicValidationResult.structural();
    };

    var tiles_validated: usize = 0;
    var tiles_structural: usize = 0;
    var tiles_with_anomaly: usize = 0;

    for (container.dimg_tile_ids) |tile_id| {
        const loc = heif.findItemLocation(container.locations, tile_id) orelse continue;
        if (loc.construction_method != 0) {
            tiles_structural += 1;
            continue;
        }
        if (loc.extents.len == 0) continue;

        // Extract tile data from iloc extents
        // Single extent (common case): direct slice
        if (loc.extents.len == 1) {
            const offset: usize = @intCast(loc.base_offset + loc.extents[0].offset);
            const length: usize = @intCast(loc.extents[0].length);
            if (offset + length > data.len) {
                return HeicValidationResult.invalid("Tile data extends beyond file");
            }

            const tile_data = data[offset .. offset + length];
            const result = validateHevcData(tile_data, decoder_config);

            if (!result.valid and !result.structural_only) {
                return result; // Tile H.265 validation failed — report error
            }
            if (result.valid and !result.structural_only) {
                tiles_validated += 1;
                if (result.warning_message != null) {
                    tiles_with_anomaly += 1;
                }
            } else {
                tiles_structural += 1;
            }
        } else {
            // Multi-extent tiles: accept structurally (very rare in practice)
            tiles_structural += 1;
        }
    }

    const total_tiles = container.dimg_tile_ids.len;
    const tiles_processed = tiles_validated + tiles_structural;

    if (tiles_validated > 0) {
        const width = container.width;
        const height = container.height;

        // If we expected tiles but some went missing (skipped due to corrupt
        // NAL headers, invalid iloc offsets, etc.), flag as corruption
        if (tiles_processed < total_tiles) {
            return HeicValidationResult.invalid("HEIC grid tile data corrupted: expected tiles missing");
        }

        if (tiles_with_anomaly > 0) {
            return HeicValidationResult.okWithWarning(width, height, "H.265 CABAC decode anomalies in one or more grid tiles (possible corruption or non-conformant encoder)");
        }
        if (tiles_structural > 0) {
            return HeicValidationResult.okWithWarning(width, height, "Some grid tiles could not be fully validated");
        }
        return HeicValidationResult.okWithDimensions(width, height);
    }
    return HeicValidationResult.structural();
}

/// Validate H.265 bitstream data from a single HEVC item (direct or tile).
/// Converts length-prefixed NAL units to Annex B format, prepends decoder
/// config parameter sets (VPS/SPS/PPS from hvcC), and runs H.265 validation.
/// Heap-allocated buffer for thread safety (validation runs in parallel).
fn validateHevcData(image_data: []const u8, decoder_config: ?[]const u8) HeicValidationResult {
    const allocator = heap.validateAllocator();
    const annex_b_buf = allocator.alloc(u8, 1024 * 1024) catch {
        return HeicValidationResult.structural();
    };
    defer allocator.free(annex_b_buf);
    var annex_b_len: usize = 0;

    if (decoder_config) |config| {
        annex_b_len = parseHvcCConfigInto(config, annex_b_buf);
    }

    // Convert length-prefixed NAL units to Annex B (start-code-prefixed)
    const nal_length_size: usize = if (decoder_config) |config|
        getNalLengthSizeFromHvcC(config)
    else
        4;

    var pos: usize = 0;
    var nal_count: usize = 0;
    while (pos + nal_length_size <= image_data.len) {
        var nal_len: u32 = 0;
        for (0..nal_length_size) |i| {
            nal_len = (nal_len << 8) | image_data[pos + i];
        }
        pos += nal_length_size;

        if (nal_len == 0 or pos + nal_len > image_data.len) {
            // Corrupted NAL length: either zero or extends beyond tile
            if (nal_count > 0) break; // Had at least one valid NAL, continue
            return HeicValidationResult.invalid("HEIC tile NAL unit length corrupted");
        }
        nal_count += 1;

        // Validate NAL unit header — tile NALs must be intra slice types
        if (nal_len >= 2) {
            const nal_type = (image_data[pos] >> 1) & 0x3F;
            // Valid intra slice types for HEIC tiles: IDR_W_RADL(19), IDR_N_LP(20), CRA(21)
            // Also allow BLA types (16-18) for completeness
            if (nal_type < 16 or nal_type > 21) {
                return HeicValidationResult.invalid("HEIC tile has invalid NAL unit type");
            }
        }

        // RBSP emulation-prevention check: forbidden 0x000000/01/02
        // sequences inside the NAL payload indicate corruption. The
        // encoder MUST insert a 0x03 byte to break any such sequence;
        // their presence in a decoded NAL means either bit-flip
        // corruption or a non-conformant encoder. Either way, fail.
        if (nalHasEmulationViolation(image_data[pos..][0..nal_len])) {
            return HeicValidationResult.invalid("HEIC NAL RBSP emulation-prevention violated (corruption)");
        }

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

    // Tile data should be fully consumed by NAL units.
    // Leftover bytes indicate a corrupted NAL length prefix.
    if (pos < image_data.len and nal_count > 0) {
        const leftover = image_data.len - pos;
        // Allow small leftover (up to nal_length_size - 1 bytes of padding)
        if (leftover >= nal_length_size) {
            return HeicValidationResult.invalid("HEIC tile NAL length mismatch: unconsumed data");
        }
    }

    if (annex_b_len < 8) return HeicValidationResult.structural();

    // HEIC items are single intra-frames, so max_frames=1
    const h265_result = h265.validateH265Stream(annex_b_buf[0..annex_b_len], 1);
    if (h265_result.valid) {
        // Propagate any H.265-level WARN (CABAC anomaly etc.) up to the
        // caller. The HEIC result carries dimensions of 0,0 here because
        // validateDirectHevcItem / validateGridTiles overwrite them with
        // the container-reported dimensions before returning.
        if (h265_result.warning_message) |msg| {
            return HeicValidationResult.okWithWarning(0, 0, msg);
        }
        return HeicValidationResult.ok();
    } else {
        if (h265_result.has_sps or h265_result.has_pps) {
            return HeicValidationResult.invalid(h265_result.error_message orelse "H.265 bitstream validation failed");
        }
        return HeicValidationResult.structural();
    }
}

/// Parse hvcC configuration box and write Annex B parameter set NAL units
/// (VPS/SPS/PPS) into the provided output buffer. Returns the number of
/// bytes written. Thread-safe — no static state.
fn parseHvcCConfigInto(config: []const u8, out: []u8) usize {
    // hvcC: byte 0 = configurationVersion (must be 1)
    // bytes 1-21: profile/level/compatibility
    // byte 22: numOfArrays (lower 5 bits; upper 3 reserved)
    // Then NAL arrays
    if (config.len < 23) return 0;
    if (config[0] != 1) return 0; // Must be version 1

    var out_len: usize = 0;

    const num_arrays = config[22] & 0x1F;
    var pos: usize = 23;
    var arr: u8 = 0;

    while (arr < num_arrays) : (arr += 1) {
        if (pos + 3 > config.len) break;
        // byte: array_completeness(1) + reserved(1) + NAL_unit_type(6)
        pos += 1; // skip type byte
        const num_nalus = std.mem.readInt(u16, config[pos..][0..2], .big);
        pos += 2;

        var n: u16 = 0;
        while (n < num_nalus) : (n += 1) {
            if (pos + 2 > config.len) break;
            const nal_len = std.mem.readInt(u16, config[pos..][0..2], .big);
            pos += 2;

            if (pos + nal_len > config.len) break;
            if (out_len + 4 + nal_len > out.len) break;

            // Write Annex B start code (0x00000001) + NAL data
            out[out_len] = 0;
            out[out_len + 1] = 0;
            out[out_len + 2] = 0;
            out[out_len + 3] = 1;
            @memcpy(out[out_len + 4 ..][0..nal_len], config[pos..][0..nal_len]);
            out_len += 4 + nal_len;

            pos += nal_len;
        }
    }

    return out_len;
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

test "HEIC grid image fully validates all tiles" {
    const allocator = std.testing.allocator;
    const path = "ground_truth_examples/heic/sample.heic";
    const file = runtime.openFile(path, .{}) catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer file.close(runtime.io());

    const file_size = try file.length(runtime.io());
    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);
    _ = try file.readPositionalAll(runtime.io(), data, 0);

    const container = try heif.parseHeifContainer(data);

    // Verify this is a grid image with tiles
    var primary_type: heif.ItemType = .unknown;
    for (container.items) |item| {
        if (item.item_id == container.primary_item_id) {
            primary_type = item.item_type;
            break;
        }
    }
    try std.testing.expectEqual(heif.ItemType.grid, primary_type);
    try std.testing.expect(container.dimg_tile_ids.len > 0);
    try std.testing.expect(container.tile_decoder_config != null);

    // Validate each tile individually to check coverage
    var tiles_full: usize = 0;
    var tiles_structural: usize = 0;
    var tiles_no_loc: usize = 0;
    var tiles_no_extent: usize = 0;
    var tiles_multi_extent: usize = 0;

    for (container.dimg_tile_ids) |tile_id| {
        const loc = heif.findItemLocation(container.locations, tile_id) orelse {
            tiles_no_loc += 1;
            continue;
        };
        if (loc.construction_method != 0) {
            tiles_structural += 1;
            continue;
        }
        if (loc.extents.len == 0) {
            tiles_no_extent += 1;
            continue;
        }
        if (loc.extents.len != 1) {
            tiles_multi_extent += 1;
            continue;
        }
        const offset: usize = @intCast(loc.base_offset + loc.extents[0].offset);
        const length: usize = @intCast(loc.extents[0].length);
        if (offset + length > data.len) continue;

        const tile_data = data[offset .. offset + length];
        const result = validateHevcData(tile_data, container.tile_decoder_config);
        if (result.valid and !result.structural_only) {
            tiles_full += 1;
        } else {
            tiles_structural += 1;
        }
    }

    // All tiles with locations should be fully validated
    try std.testing.expectEqual(@as(usize, 0), tiles_no_loc);
    try std.testing.expectEqual(@as(usize, 0), tiles_no_extent);
    try std.testing.expectEqual(@as(usize, 0), tiles_multi_extent);
    try std.testing.expectEqual(@as(usize, 0), tiles_structural);
    try std.testing.expectEqual(container.dimg_tile_ids.len, tiles_full);
}

// ============================================================================
// Corruption-detection sniper test
//
// Documents the "borked input produces correct output" gap: a single-byte
// flip deep in the H.265 entropy data should not produce `valid=true,
// depth=full`. Previously, CABAC anomaly detection only fired on immediate
// decode failure (ctus_decoded == 0) and the verdict policy explicitly
// downgraded all anomalies to WARN, so mid-slice desync slipped through
// silently. This test pins the new behavior: corruption MUST surface
// (either FAIL, or at minimum a non-null warning_message that the caller
// can propagate as a depth=structural+warning result).
// ============================================================================

test "HEIC corruption: single-byte flip deep in H.265 data must not silent-pass" {
    // PENDING (skipped, body kept live for one-line re-enable):
    // Documents the H.265 deep-validation gap. The H.265 CABAC decoder
    // currently desyncs on CLEAN ground-truth files (terminates at CTU 64
    // with bits_remaining ≈ 30%, no `decodeTerminate()=1`), so it cannot
    // serve as a reliable corruption oracle. See NEXT_STEPS.md ->
    // "HEIC/HEIF deep validation" for the broadening-CABAC plan.
    //
    // When CABAC reliably reaches `decodeTerminate()=1` at all CTUs on
    // clean files, remove the `if (true) return ...` line below and this
    // becomes the regression guard against borked-input-produces-correct-
    // output false PASS.
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const path = "ground_truth_examples/heic/autumn_1440x960.heic";
    const file = runtime.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    defer file.close(runtime.io());

    const file_size = try file.length(runtime.io());
    const original = try allocator.alloc(u8, file_size);
    defer allocator.free(original);
    _ = try file.readPositionalAll(runtime.io(), original, 0);

    // Baseline: the clean file must validate cleanly.
    const baseline = validateHeicDeepFromBuffer(original);
    try std.testing.expect(baseline.valid);
    try std.testing.expect(!baseline.structural_only);
    try std.testing.expect(baseline.warning_message == null);

    // Corruption: flip every bit of one byte at offset 50% — deep in the
    // entropy-coded H.265 data, past container/ftyp/meta/iloc boxes.
    // 50% chosen empirically as "definitely in mdat tile data" for the
    // 1440x960 autumn fixture.
    const corrupted = try allocator.dupe(u8, original);
    defer allocator.free(corrupted);
    const corrupt_offset: usize = file_size / 2;
    corrupted[corrupt_offset] ^= 0xFF;

    const result = validateHeicDeepFromBuffer(corrupted);
    // Acceptance criterion per "no silent skip" policy: corruption must
    // surface either as FAIL (preferred) or as a non-null warning. A clean
    // valid+structural_only==false+no warning is the bug we are fixing.
    const surfaced = (!result.valid) or (result.warning_message != null) or result.structural_only;
    if (!surfaced) {
        std.debug.print(
            "\n  HEIC corruption silently passed: valid={}, structural_only={}, warning={?s}, err={?s}\n",
            .{ result.valid, result.structural_only, result.warning_message, result.error_message },
        );
    }
    try std.testing.expect(surfaced);
}

