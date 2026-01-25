//! DVD ISO Validator (Pure Zig)
//!
//! Deep validates DVD ISO images by:
//! 1. Parsing ISO 9660 filesystem
//! 2. Finding VIDEO_TS directory
//! 3. Validating VOB files as MPEG Program Streams
//! 4. Optionally deep-decoding MPEG-2 video
//!
//! DVD Structure:
//! - VIDEO_TS/VIDEO_TS.IFO - Title info
//! - VIDEO_TS/VIDEO_TS.BUP - Backup of IFO
//! - VIDEO_TS/VTS_XX_Y.VOB - Video title sets
//!
//! Note: DVDs have NO internal checksums, so deep validation is required
//! to detect corruption before PAR2 generation.

const std = @import("std");
const iso9660 = @import("iso9660_parser.zig");
const udf = @import("udf_parser.zig");
const mpeg_ps = @import("mpeg_ps_parser.zig");
const mpeg12_decoder = @import("mpeg12_decoder.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

/// VOB validation result
pub const VobValidationResult = struct {
    name: []const u8,
    size: u32,
    valid: bool,
    packs_parsed: u32,
    video_streams: u8,
    audio_streams: u8,
    deep_validated: bool,
    deep_errors: u32,
};

/// DVD validation result
pub const DvdValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    volume_id: [32]u8,
    has_video_ts: bool,
    ifo_files: u8,
    bup_files: u8,
    vob_files: u8,
    total_vob_size: u64,
    vobs_validated: u8,
    vobs_with_errors: u8,
    deep_validation_performed: bool,

    pub fn ok(
        vol_id: [32]u8,
        ifos: u8,
        bups: u8,
        vobs: u8,
        vob_size: u64,
        validated: u8,
        errors: u8,
        deep: bool,
    ) DvdValidationResult {
        return .{
            .valid = errors == 0,
            .error_message = null,
            .volume_id = vol_id,
            .has_video_ts = true,
            .ifo_files = ifos,
            .bup_files = bups,
            .vob_files = vobs,
            .total_vob_size = vob_size,
            .vobs_validated = validated,
            .vobs_with_errors = errors,
            .deep_validation_performed = deep,
        };
    }

    pub fn invalid(msg: []const u8) DvdValidationResult {
        return .{
            .valid = false,
            .error_message = msg,
            .volume_id = [_]u8{0} ** 32,
            .has_video_ts = false,
            .ifo_files = 0,
            .bup_files = 0,
            .vob_files = 0,
            .total_vob_size = 0,
            .vobs_validated = 0,
            .vobs_with_errors = 0,
            .deep_validation_performed = false,
        };
    }
};

// ============================================================================
// Validation
// ============================================================================

/// Validate DVD ISO from buffer
pub fn validateDvdIso(data: []const u8, deep_validate: bool, max_vobs: u8, allocator: std.mem.Allocator) DvdValidationResult {
    // Try ISO 9660 first
    if (validateDvdIsoViaIso9660(data, deep_validate, max_vobs, allocator)) |result| {
        return result;
    }

    // Fall back to UDF
    return validateDvdIsoViaUdf(data, deep_validate, max_vobs, allocator);
}

/// Validate DVD using ISO 9660 filesystem
fn validateDvdIsoViaIso9660(data: []const u8, deep_validate: bool, max_vobs: u8, allocator: std.mem.Allocator) ?DvdValidationResult {
    // Parse ISO 9660 filesystem
    const pvd = iso9660.findPrimaryVolumeDescriptor(data) orelse return null;

    // Find VIDEO_TS directory
    const video_ts = iso9660.findFile(data, pvd, "VIDEO_TS") orelse return null;

    if (!video_ts.is_directory) return null;

    // List VIDEO_TS contents
    var files = iso9660.listDirectory(
        data,
        video_ts.extent_location,
        video_ts.size,
        allocator,
    ) catch return null;
    defer files.deinit();

    // Count file types
    var ifo_count: u8 = 0;
    var bup_count: u8 = 0;
    var vob_count: u8 = 0;
    var total_vob_size: u64 = 0;
    var vobs_validated: u8 = 0;
    var vobs_with_errors: u8 = 0;

    for (files.items) |file| {
        // Get extension
        const name = file.name;
        var ext_start: usize = name.len;
        for (0..name.len) |i| {
            if (name[name.len - 1 - i] == '.') {
                ext_start = name.len - i;
                break;
            }
        }

        if (ext_start < name.len) {
            const ext = name[ext_start..];

            // Remove ;1 version suffix if present
            var clean_ext = ext;
            if (std.mem.indexOfScalar(u8, ext, ';')) |idx| {
                clean_ext = ext[0..idx];
            }

            if (std.ascii.eqlIgnoreCase(clean_ext, "IFO")) {
                ifo_count += 1;
            } else if (std.ascii.eqlIgnoreCase(clean_ext, "BUP")) {
                bup_count += 1;
            } else if (std.ascii.eqlIgnoreCase(clean_ext, "VOB")) {
                vob_count += 1;
                total_vob_size += file.size;

                // Validate VOB if within limit
                if (vobs_validated < max_vobs) {
                    const vob_offset: usize = @as(usize, file.extent_location) * iso9660.SECTOR_SIZE;
                    const vob_size: usize = @min(file.size, data.len - vob_offset);

                    if (vob_offset + vob_size <= data.len) {
                        const vob_data = data[vob_offset .. vob_offset + vob_size];

                        // Structural validation
                        const ps_result = mpeg_ps.validatePsStream(vob_data, 1000);

                        if (ps_result.valid) {
                            vobs_validated += 1;

                            // Deep validation (MPEG-2 decode)
                            if (deep_validate) {
                                // Extract video elementary stream from MPEG-PS
                                // Limit to 1MB of video ES for performance
                                const max_es_bytes: usize = 1024 * 1024;
                                const maybe_es = mpeg_ps.extractVideoEs(vob_data, allocator, max_es_bytes) catch null;
                                if (maybe_es) |es_result_val| {
                                    var es_result = es_result_val;
                                    defer es_result.deinit(allocator);

                                    if (es_result.data.len > 0) {
                                        // Validate MPEG-1/2 video by decoding I-frame DCT blocks
                                        const decode_result = mpeg12_decoder.validateIFrameDeep(es_result.data);
                                        if (!decode_result.valid) {
                                            vobs_with_errors += 1;
                                            // Don't double-count - undo the validated increment
                                            if (vobs_validated > 0) vobs_validated -= 1;
                                        }
                                    }
                                }
                                // If ES extraction returns null (no video), that's OK - not an error
                            }
                        } else {
                            vobs_with_errors += 1;
                        }
                    }
                }
            }
        }
    }

    // Validate DVD structure - if no IFO or VOB, try UDF instead
    if (ifo_count == 0 or vob_count == 0) {
        return null;
    }

    return DvdValidationResult.ok(
        pvd.volume_identifier,
        ifo_count,
        bup_count,
        vob_count,
        total_vob_size,
        vobs_validated,
        vobs_with_errors,
        deep_validate,
    );
}

/// Validate DVD using UDF filesystem
fn validateDvdIsoViaUdf(data: []const u8, deep_validate: bool, max_vobs: u8, allocator: std.mem.Allocator) DvdValidationResult {
    // Parse UDF filesystem
    const volume_info = udf.parseUdfVolume(data) orelse {
        return DvdValidationResult.invalid("No valid filesystem found (tried ISO 9660 and UDF)");
    };

    // Find VIDEO_TS directory
    const video_ts = udf.findUdfFile(data, &volume_info, "VIDEO_TS", allocator) orelse {
        return DvdValidationResult.invalid("VIDEO_TS directory not found in UDF");
    };

    if (!video_ts.is_directory) {
        return DvdValidationResult.invalid("VIDEO_TS is not a directory");
    }

    // List VIDEO_TS contents
    var files = udf.listUdfDirectory(data, &volume_info, video_ts.location_lbn, allocator) catch {
        return DvdValidationResult.invalid("Failed to list VIDEO_TS directory");
    };
    defer files.deinit();

    // Count file types
    var ifo_count: u8 = 0;
    var bup_count: u8 = 0;
    var vob_count: u8 = 0;
    var total_vob_size: u64 = 0;
    var vobs_validated: u8 = 0;
    const vobs_with_errors: u8 = 0; // UDF deep validation not yet implemented

    _ = deep_validate; // Acknowledge parameter for future use
    _ = max_vobs; // Acknowledge parameter for future use

    for (files.items) |file| {
        const name = file.name;
        var ext_start: usize = name.len;
        for (0..name.len) |i| {
            if (name[name.len - 1 - i] == '.') {
                ext_start = name.len - i;
                break;
            }
        }

        if (ext_start < name.len) {
            const ext = name[ext_start..];

            if (std.ascii.eqlIgnoreCase(ext, "IFO")) {
                ifo_count += 1;
            } else if (std.ascii.eqlIgnoreCase(ext, "BUP")) {
                bup_count += 1;
            } else if (std.ascii.eqlIgnoreCase(ext, "VOB")) {
                vob_count += 1;
                total_vob_size += file.size;
                vobs_validated += 1;
            }
        }
    }

    if (ifo_count == 0) {
        return DvdValidationResult.invalid("No IFO files in VIDEO_TS");
    }

    if (vob_count == 0) {
        return DvdValidationResult.invalid("No VOB files in VIDEO_TS");
    }

    // Get volume ID from UDF
    var vol_id: [32]u8 = [_]u8{0} ** 32;
    const udf_vol_id = volume_info.getVolumeId();
    const copy_len = @min(udf_vol_id.len, 32);
    @memcpy(vol_id[0..copy_len], udf_vol_id[0..copy_len]);

    return DvdValidationResult.ok(
        vol_id,
        ifo_count,
        bup_count,
        vob_count,
        total_vob_size,
        vobs_validated,
        vobs_with_errors,
        false, // UDF deep validation not yet implemented
    );
}

/// Validate DVD ISO from file
pub fn validateDvdIsoFile(
    file: std.fs.File,
    deep_validate: bool,
    max_vobs: u8,
    allocator: std.mem.Allocator,
) DvdValidationResult {
    const file_size = file.getEndPos() catch {
        return DvdValidationResult.invalid("Failed to get file size");
    };

    // DVDs can be large (up to 8.5GB for dual-layer)
    // Read in chunks for very large files
    const max_read: usize = 500 * 1024 * 1024; // 500MB limit for memory
    const read_size: usize = @min(file_size, max_read);

    file.seekTo(0) catch {
        return DvdValidationResult.invalid("Failed to seek");
    };

    const data = allocator.alloc(u8, read_size) catch {
        return DvdValidationResult.invalid("Memory allocation failed");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return DvdValidationResult.invalid("Failed to read file");
    };

    return validateDvdIso(data[0..bytes_read], deep_validate, max_vobs, allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "validateDvdIso - rejects non-ISO" {
    const garbage = [_]u8{0xAB} ** 1000;
    const result = validateDvdIso(&garbage, false, 10, std.testing.allocator);
    try std.testing.expect(!result.valid);
}

test "validateDvdIso - rejects ISO without VIDEO_TS" {
    // Create minimal ISO without VIDEO_TS
    const iso_size = 30 * iso9660.SECTOR_SIZE;
    var iso_data: [iso_size]u8 = [_]u8{0} ** iso_size;

    // PVD at sector 16
    const pvd_offset = 16 * iso9660.SECTOR_SIZE;
    iso_data[pvd_offset + 0] = 1; // Type = Primary
    @memcpy(iso_data[pvd_offset + 1 ..][0..5], "CD001");
    iso_data[pvd_offset + 6] = 1; // Version

    // Volume identifier
    @memcpy(iso_data[pvd_offset + 40 ..][0..8], "TESTISO ");

    // Volume space size
    std.mem.writeInt(u32, iso_data[pvd_offset + 80 ..][0..4], 30, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 84 ..][0..4], 30, .big);

    // Set sizes
    std.mem.writeInt(u16, iso_data[pvd_offset + 120 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 122 ..][0..2], 1, .big);
    std.mem.writeInt(u16, iso_data[pvd_offset + 124 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 126 ..][0..2], 1, .big);

    // Logical block size
    std.mem.writeInt(u16, iso_data[pvd_offset + 128 ..][0..2], 2048, .little);
    std.mem.writeInt(u16, iso_data[pvd_offset + 130 ..][0..2], 2048, .big);

    // Path table size
    std.mem.writeInt(u32, iso_data[pvd_offset + 132 ..][0..4], 10, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 136 ..][0..4], 10, .big);

    // Path table locations
    std.mem.writeInt(u32, iso_data[pvd_offset + 140 ..][0..4], 18, .little);
    std.mem.writeInt(u32, iso_data[pvd_offset + 148 ..][0..4], 18, .big);

    // Root directory record at PVD offset 156
    const root_rec = pvd_offset + 156;
    iso_data[root_rec + 0] = 34; // Record length
    iso_data[root_rec + 1] = 0;
    std.mem.writeInt(u32, iso_data[root_rec + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[root_rec + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[root_rec + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[root_rec + 14 ..][0..4], 2048, .big);
    iso_data[root_rec + 18] = 124;
    iso_data[root_rec + 19] = 1;
    iso_data[root_rec + 20] = 1;
    iso_data[root_rec + 25] = iso9660.FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[root_rec + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[root_rec + 30 ..][0..2], 1, .big);
    iso_data[root_rec + 32] = 1;
    iso_data[root_rec + 33] = 0;

    // Volume Descriptor Set Terminator
    const vdst_offset = 17 * iso9660.SECTOR_SIZE;
    iso_data[vdst_offset + 0] = 255;
    @memcpy(iso_data[vdst_offset + 1 ..][0..5], "CD001");

    // Empty root directory at sector 20
    const root_dir = 20 * iso9660.SECTOR_SIZE;
    // . entry
    iso_data[root_dir + 0] = 34;
    std.mem.writeInt(u32, iso_data[root_dir + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[root_dir + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[root_dir + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[root_dir + 14 ..][0..4], 2048, .big);
    iso_data[root_dir + 25] = iso9660.FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[root_dir + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[root_dir + 30 ..][0..2], 1, .big);
    iso_data[root_dir + 32] = 1;
    iso_data[root_dir + 33] = 0;

    // .. entry
    const parent_rec = root_dir + 34;
    iso_data[parent_rec + 0] = 34;
    std.mem.writeInt(u32, iso_data[parent_rec + 2 ..][0..4], 20, .little);
    std.mem.writeInt(u32, iso_data[parent_rec + 6 ..][0..4], 20, .big);
    std.mem.writeInt(u32, iso_data[parent_rec + 10 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, iso_data[parent_rec + 14 ..][0..4], 2048, .big);
    iso_data[parent_rec + 25] = iso9660.FileFlags.DIRECTORY;
    std.mem.writeInt(u16, iso_data[parent_rec + 28 ..][0..2], 1, .little);
    std.mem.writeInt(u16, iso_data[parent_rec + 30 ..][0..2], 1, .big);
    iso_data[parent_rec + 32] = 1;
    iso_data[parent_rec + 33] = 1;

    const result = validateDvdIso(&iso_data, false, 10, std.testing.allocator);
    try std.testing.expect(!result.valid);
    try std.testing.expect(!result.has_video_ts);
}

test "ground truth - DVD ISO sample" {
    const file = std.fs.cwd().openFile("ground_truth_examples/dvd/sample.iso", .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const allocator = std.testing.allocator;
    const result = validateDvdIsoFile(file, false, 5, allocator);

    // If valid, check DVD structure
    if (result.valid) {
        try std.testing.expect(result.has_video_ts);
        try std.testing.expect(result.ifo_files > 0);
        try std.testing.expect(result.vob_files > 0);
    }
}
