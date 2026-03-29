const std = @import("std");
const fv = @import("format_validation.zig");
const FileFormat = fv.FileFormat;
const ValidationResult = fv.ValidationResult;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const Allocator = std.mem.Allocator;

/// Validate Roxio Toast (.toast) disc image structure.
/// Toast files are typically ISO 9660 images, sometimes prefixed with an Apple
/// Partition Map (APM). Detection relies on APM DDR signature at offset 0 ("ER")
/// and/or ISO 9660 PVD "CD001" at offset 0x8001. The Application Identifier
/// field in the PVD may contain "TOAST ISO 9660 BUILDER" for provenance.
pub fn validateToast(file: *FileSource) ValidationResult {
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCodeWithDepth(.toast, .failed_to_get, "file size", .structural);
	};

	if (file_size < 2048) {
		return ValidationResult.invalidCodeWithDepth(.toast, .file_too_small, "Toast disc image", .structural);
	}

	file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.toast, .failed_to_seek, "to start", .structural);

	// Read enough for APM DDR + ISO 9660 PVD check
	// PVD is at sector 16 (offset 0x8000) for 2048-byte sectors
	const pvd_offset: u64 = 0x8000;
	var header: [2]u8 = undefined;
	const header_read = file.read(&header) catch return ValidationResult.invalidCodeWithDepth(.toast, .failed_to_read, "Toast header", .structural);
	if (header_read < 2) return ValidationResult.invalidCodeWithDepth(.toast, .file_too_small, "Toast", .structural);

	var has_apm = false;
	var has_iso = false;

	// Check for APM Driver Descriptor Record: "ER" (0x4552) at offset 0
	if (header[0] == 0x45 and header[1] == 0x52) {
		has_apm = true;

		// Validate APM block size (offset 2-3, big-endian)
		var blk_buf: [2]u8 = undefined;
		const blk_read = file.read(&blk_buf) catch return ValidationResult.okWithDepth(.toast, .structural);
		if (blk_read >= 2) {
			const block_size = std.mem.readInt(u16, &blk_buf, .big);
			// Valid block sizes: 512 or 2048
			if (block_size != 512 and block_size != 2048) {
				return ValidationResult.invalidWithDepth(.toast, "Invalid APM block size (expected 512 or 2048)", .structural);
			}
		}
	}

	// Check for ISO 9660 Primary Volume Descriptor at offset 0x8001
	if (file_size > pvd_offset + 6) {
		file.seekTo(pvd_offset) catch return ValidationResult.okWithDepth(.toast, .structural);
		var pvd_header: [6]u8 = undefined;
		const pvd_read = file.read(&pvd_header) catch return ValidationResult.okWithDepth(.toast, .structural);
		if (pvd_read >= 6) {
			// PVD: type=0x01 at offset 0, "CD001" at offset 1, version=0x01 at offset 5
			if (pvd_header[0] == 0x01 and std.mem.eql(u8, pvd_header[1..6], "CD001")) {
				has_iso = true;
			}
		}
	}

	if (!has_apm and !has_iso) {
		return ValidationResult.invalidWithDepth(.toast, "No APM header or ISO 9660 PVD found", .structural);
	}

	// Optionally check for Toast Application Identifier string in PVD
	// The Application Identifier is at PVD offset 883 (absolute: 0x8000 + 883 = 0x8373)
	if (has_iso and file_size > pvd_offset + 1011) {
		file.seekTo(pvd_offset + 883) catch return ValidationResult.okWithDepth(.toast, .structural);
		var app_id_buf: [128]u8 = undefined;
		const app_id_read = file.read(&app_id_buf) catch return ValidationResult.okWithDepth(.toast, .structural);
		if (app_id_read >= 32) {
			// Check for Toast builder signature (informational, doesn't affect validation)
			if (std.mem.startsWith(u8, &app_id_buf, "TOAST ISO 9660 BUILDER")) {
				// Confirmed Toast provenance — still return .toast format
			}
		}
	}

	// If we have ISO 9660, cross-check volume size vs file size
	if (has_iso and file_size > pvd_offset + 84) {
		file.seekTo(pvd_offset + 80) catch return ValidationResult.okWithDepth(.toast, .structural);
		var vol_size_buf: [8]u8 = undefined;
		const vol_size_read = file.read(&vol_size_buf) catch return ValidationResult.okWithDepth(.toast, .structural);
		if (vol_size_read >= 8) {
			// Volume space size is a both-endian u32 at PVD+80 (LE first, BE second)
			const vol_sectors = std.mem.readInt(u32, vol_size_buf[0..4], .little);
			// Logical block size is at PVD+128 but typically 2048
			const expected_size: u64 = @as(u64, vol_sectors) * 2048;
			// Allow some tolerance (padding, APM prefix)
			if (expected_size > 0 and file_size < expected_size / 2) {
				return ValidationResult.invalidWithDepth(.toast, "File truncated (volume size exceeds file size)", .structural);
			}
		}
	}

	return ValidationResult.okWithDepth(.toast, .structural);
}

// ============ Tests ============

const testing = std.testing;

fn tmpToastFile(tmp_dir: *std.testing.TmpDir, name: []const u8, data: []const u8) !FileSource {
	{
		const wf = try tmp_dir.dir.createFile(name, .{});
		defer wf.close();
		try wf.writeAll(data);
	}
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath(name, &path_buf);
	return FileSource.open(path);
}

test "validateToast: reject too-small file" {
	var data: [100]u8 = undefined;
	@memset(&data, 0);
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var source = try tmpToastFile(&tmp, "tiny.toast", &data);
	defer source.close();
	const result = validateToast(&source);
	try testing.expect(!result.is_valid);
}

test "validateToast: valid ground truth" {
	var file = FileSource.open("ground_truth_examples/toast/sample.toast") catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer file.close();
	const result = validateToast(&file);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.toast, result.format);
}
