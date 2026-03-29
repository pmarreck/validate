const std = @import("std");
const fv = @import("format_validation.zig");
const FileFormat = fv.FileFormat;
const ValidationResult = fv.ValidationResult;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const Allocator = std.mem.Allocator;

/// Validate CD+Graphics (.cdg) karaoke file structure.
/// CDG files are raw subchannel data from Red Book audio CDs — a flat stream of
/// 24-byte packets with no header or magic bytes. Validation relies on file size
/// divisibility, packet command byte analysis, and tile coordinate bounds checking.
pub fn validateCdg(file: *FileSource) ValidationResult {
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCodeWithDepth(.cdg, .failed_to_get, "file size", .structural);
	};

	// CDG files must be an exact multiple of 24 bytes (packet size)
	if (file_size == 0) return ValidationResult.invalidWithDepth(.cdg, "File is empty", .structural);
	if (file_size % 24 != 0) return ValidationResult.invalidWithDepth(.cdg, "File size not a multiple of 24 bytes (CDG packet size)", .structural);

	const total_packets = file_size / 24;

	// Sanity: warn if extremely short (< 1 second = 300 packets = 7200 bytes)
	// but don't fail — very short CDG files are technically valid

	// Read and analyze packets
	file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.cdg, .failed_to_seek, "to start", .structural);

	var buf: [24 * 256]u8 = undefined; // Read 256 packets at a time
	var cdg_command_count: u64 = 0;
	var invalid_tile_count: u64 = 0;
	var packets_read: u64 = 0;
	const max_packets_to_check = @min(total_packets, 10000); // Check up to 10K packets

	while (packets_read < max_packets_to_check) {
		const batch: usize = @intCast(@min(256, max_packets_to_check - packets_read));
		const bytes_needed: usize = batch * 24;
		const bytes_read = file.read(buf[0..bytes_needed]) catch break;
		if (bytes_read < 24) break;

		const packets_in_batch: usize = bytes_read / 24;
		for (0..packets_in_batch) |i| {
			const pkt = buf[i * 24 ..][0..24];
			const command = pkt[0] & 0x3F;

			if (command == 0x09) {
				cdg_command_count += 1;
				const instruction = pkt[1] & 0x3F;

				// Validate tile coordinates for Tile Block commands
				if (instruction == 6 or instruction == 38) { // Tile Block Normal/XOR
					const row = pkt[4] & 0x1F;
					const col = pkt[5] & 0x3F;
					if (row > 17 or col > 49) {
						invalid_tile_count += 1;
					}
				}
			}
			packets_read += 1;
		}
	}

	// A valid CDG file should have at least some CDG command packets
	// (command & 0x3F == 0x09). A file with zero CDG commands is likely not a CDG file.
	if (cdg_command_count == 0) {
		return ValidationResult.invalidWithDepth(.cdg, "No CDG command packets found (all packets are null/timing)", .structural);
	}

	// If more than 10% of tile commands have invalid coordinates, flag corruption
	if (invalid_tile_count > 0 and cdg_command_count > 0) {
		const tile_ratio = (invalid_tile_count * 100) / cdg_command_count;
		if (tile_ratio > 10) {
			return ValidationResult.invalidWithDepth(.cdg, "Excessive invalid tile coordinates in CDG packets", .structural);
		}
	}

	return ValidationResult.okWithDepth(.cdg, .structural);
}

// ============ Tests ============

const testing = std.testing;

fn tmpCdgFile(tmp_dir: *std.testing.TmpDir, name: []const u8, data: []const u8) !FileSource {
	{
		const wf = try tmp_dir.dir.createFile(name, .{});
		defer wf.close();
		try wf.writeAll(data);
	}
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const path = try tmp_dir.dir.realpath(name, &path_buf);
	return FileSource.open(path);
}

test "validateCdg: valid ground truth file validates successfully" {
	// Use the pre-generated ground truth CDG sample
	var file = FileSource.open("ground_truth_examples/cdg/sample.cdg") catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer file.close();
	const result = validateCdg(&file);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.cdg, result.format);
}

test "validateCdg: reject file not multiple of 24" {
	var data: [100]u8 = undefined;
	@memset(&data, 0);
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var source = try tmpCdgFile(&tmp, "bad.cdg", &data);
	defer source.close();
	const result = validateCdg(&source);
	try testing.expect(!result.is_valid);
}

test "validateCdg: reject file with no CDG commands" {
	var data: [24 * 100]u8 = undefined;
	@memset(&data, 0);
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var source = try tmpCdgFile(&tmp, "null.cdg", &data);
	defer source.close();
	const result = validateCdg(&source);
	try testing.expect(!result.is_valid);
}

