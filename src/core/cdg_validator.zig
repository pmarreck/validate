const std = @import("std");
const runtime = @import("runtime.zig");
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
		const wf = try tmp_dir.dir.createFile(runtime.io(), name, .{});
		defer wf.close(runtime.io());
		try wf.writePositionalAll(runtime.io(), data, 0);
	}
	const path = try runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, name);
	defer std.testing.allocator.free(path);
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

// Builds a CDG-structured byte sequence whose bytes are dominated by high
// values (0x80–0xFF). Real CDG files often retain the original CD subchannel
// P/Q parity bits in the high two bits, which makes the raw bytes look like
// CP437/Latin-1 box-drawing characters. The content sniffer will classify
// such a file as plain_text_cp437 unless the dispatcher consults the
// extension. This is the bit-for-bit shape we need to defend against.
fn buildHighBitCdg(out: []u8) void {
	std.debug.assert(out.len % 24 == 0);
	const total = out.len / 24;
	var i: usize = 0;
	while (i < total) : (i += 1) {
		const pkt = out[i * 24 ..][0..24];
		// Every 6th packet is a real CDG command (cmd 0x09, instr 6 = TILE_BLOCK)
		if (i % 6 == 0) {
			pkt[0] = 0x89; // 0x80 | 0x09  (subcode P set, command low6 = 0x09)
			pkt[1] = 0x86; // 0x80 | 0x06  (subcode P set, instruction = 6)
			// Tile coords inside legal range
			pkt[4] = 0x80 | 0x05; // row = 5
			pkt[5] = 0x80 | 0x10; // col = 16
			// Remaining data + parity bytes — high-bit-rich filler
			var j: usize = 2;
			while (j < 24) : (j += 1) {
				if (j == 4 or j == 5) continue;
				pkt[j] = 0xB8;
			}
		} else {
			// Non-CDG slot: command low6 != 0 and != 9 (mimics the Casinos
			// pattern where bytes 0x38/0x39/etc dominate). High-bit set so
			// the file looks textual (CP437) to the content sniffer.
			pkt[0] = 0xB8;
			pkt[1] = 0xB8;
			var j: usize = 2;
			while (j < 24) : (j += 1) pkt[j] = 0xB8;
		}
	}
}

test "validateCdg: accepts high-bit (CP437-looking) packet stream" {
	// Many real-world CDG rips keep the CD subchannel parity bits in the high
	// two bits, so every byte is >= 0x80. With the low 6 bits stripped the
	// stream still parses as valid CDG. The validator must accept this.
	var buf: [24 * 600]u8 = undefined;
	buildHighBitCdg(&buf);
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var source = try tmpCdgFile(&tmp, "highbit.cdg", &buf);
	defer source.close();
	const result = validateCdg(&source);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.cdg, result.format);
}

test "FormatValidator: high-bit CDG file is classified as cdg, not plain_text_cp437" {
	// Regression test for the dispatch bug that produced 50 false-positive
	// WARNs of the form "WARN foo.cdg: Plain Text (CP437/DOS) [extension
	// doesn't match content]". When magic-byte sniffing classifies a CDG
	// file as plain_text_cp437/latin1/utf16, the dispatcher must still
	// consult the .cdg extension and run validateCdg.
	const FormatValidator = fv.FormatValidator;
	const MalformationType = fv.MalformationType;

	var buf: [24 * 600]u8 = undefined;
	buildHighBitCdg(&buf);

	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	{
		const wf = try tmp.dir.createFile(runtime.io(), "highbit.cdg", .{});
		defer wf.close(runtime.io());
		try wf.writePositionalAll(runtime.io(), &buf, 0);
	}
	const path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "highbit.cdg");
	defer std.testing.allocator.free(path);

	var validator = FormatValidator.init();
	defer validator.deinit();
	const result = validator.validateFile(path);

	try testing.expectEqual(FileFormat.cdg, result.format);
	try testing.expect(result.is_valid);
	try testing.expect(!result.malformations.contains(MalformationType.extension_mismatch));
}
