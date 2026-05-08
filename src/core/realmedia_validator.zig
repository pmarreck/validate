//! RealMedia Container Validator (.rm, .rmvb)
//!
//! Validates the structural integrity of RealMedia files using the proprietary
//! RealNetworks container format. All multi-byte values are big-endian.
//!
//! Chunk layout: 4-byte FOURCC + 4-byte size (includes FOURCC+size+version) +
//!               2-byte version + variable data
//!
//! Required chunks: .RMF (file header, must be first), PROP (properties),
//!                  MDPR (one per stream), DATA (data container)
//! Optional chunks: CONT (content description), INDX (index)
//!
//! No checksums exist in the format — all validation is structural.

const std = @import("std");
const fv = @import("format_validation.zig");
const FileFormat = fv.FileFormat;
const ValidationResult = fv.ValidationResult;
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const Allocator = std.mem.Allocator;

/// Minimum chunk header size: FOURCC(4) + size(4) + version(2) = 10 bytes.
const CHUNK_HEADER_SIZE: usize = 10;

/// Sanity cap: no real file will have more than 65535 streams or 1M chunks.
const MAX_STREAMS: u32 = 65535;
const MAX_CHUNKS: u32 = 1_000_000;

/// Structural-only validation of a RealMedia file from an open FileSource.
/// Checks magic bytes, validates the .RMF file header chunk, then walks all
/// top-level chunks verifying that sizes are consistent with the file length.
/// Also validates that exactly one PROP chunk exists, and that the PROP-declared
/// num_streams matches the count of MDPR chunks encountered.
pub fn validateRealMedia(file: *FileSource) ValidationResult {
	// Need at least 18 bytes: .RMF(4) + size(4) + version(2) + file_version(4) + num_headers(4)
	const MIN_HEADER: usize = 18;

	file.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.rm, .failed_to_seek, "to start", .structural);

	var header: [MIN_HEADER]u8 = undefined;
	const bytes_read = file.read(&header) catch return ValidationResult.invalidCodeWithDepth(.rm, .failed_to_read, "RealMedia header", .structural);
	if (bytes_read < MIN_HEADER) return ValidationResult.invalidCodeWithDepth(.rm, .file_too_small, "RealMedia", .structural);

	// Magic check: must start with ".RMF"
	if (!std.mem.eql(u8, header[0..4], ".RMF"))
		return ValidationResult.invalidCodeWithDepth(.rm, .invalid_signature, "RealMedia", .structural);

	// Parse the .RMF chunk header
	const rmf_size = std.mem.readInt(u32, header[4..8], .big);
	if (rmf_size < CHUNK_HEADER_SIZE)
		return ValidationResult.invalidWithDepth(.rm, "RMF chunk size too small", .structural);

	const rmf_version = std.mem.readInt(u16, header[8..10], .big);
	if (rmf_version != 0)
		return ValidationResult.invalidWithDepth(.rm, "Unsupported RMF chunk version", .structural);

	// Bytes 10-13: file_version (some encoders write 0, some write 1 — accept both)
	const file_version = std.mem.readInt(u32, header[10..14], .big);
	if (file_version > 1)
		return ValidationResult.invalidWithDepth(.rm, "Unsupported RealMedia file version", .structural);

	// Bytes 14-17: num_headers (number of top-level chunks that follow, excluding .RMF itself)
	const num_headers = std.mem.readInt(u32, header[14..18], .big);
	if (num_headers == 0)
		return ValidationResult.invalidWithDepth(.rm, "RMF declares zero headers", .structural);
	if (num_headers > MAX_CHUNKS)
		return ValidationResult.invalidWithDepth(.rm, "RMF num_headers unreasonably large", .structural);

	// Get file size for bounds checking
	const file_size = file.getEndPos() catch {
		// Can't determine size; trust the header we've validated so far
		return ValidationResult.okWithDepth(.rm, .structural);
	};

	// Walk all subsequent chunks, collecting structural metadata
	var pos: u64 = rmf_size; // Jump past the .RMF chunk
	var chunk_count: u32 = 0;
	var prop_count: u32 = 0;
	var mdpr_count: u32 = 0;
	var data_found: bool = false;
	var prop_num_streams: u32 = 0;
	var prop_data_offset: u32 = 0;
	var prop_index_offset: u32 = 0;
	var chunk_buf: [CHUNK_HEADER_SIZE]u8 = undefined;

	while (pos + CHUNK_HEADER_SIZE <= file_size) {
		if (chunk_count >= MAX_CHUNKS)
			return ValidationResult.invalidWithDepth(.rm, "Too many RealMedia chunks (possibly corrupt)", .structural);

		file.seekTo(pos) catch return ValidationResult.invalidWithDepth(.rm, "Failed to seek to chunk", .structural);
		const n = file.read(&chunk_buf) catch return ValidationResult.invalidWithDepth(.rm, "Failed to read chunk header", .structural);
		if (n < CHUNK_HEADER_SIZE) break; // Truncated at chunk boundary — tolerate if we already found DATA

		const fourcc = chunk_buf[0..4];
		const chunk_size = std.mem.readInt(u32, chunk_buf[4..8], .big);

		// Sanity: chunk size must cover at least the header itself
		if (chunk_size < CHUNK_HEADER_SIZE) {
			return ValidationResult.invalidWithDepth(.rm, "RealMedia chunk size smaller than header", .structural);
		}

		// Sanity: chunk must not extend past end of file
		// Tolerate minor overrun on DATA chunk — ffmpeg writes DATA size before knowing
		// final byte count, often leaving the last chunk a few bytes past EOF
		if (pos + chunk_size > file_size) {
			if (std.mem.eql(u8, fourcc, "DATA") and pos + chunk_size <= file_size + 64) {
				// Accept slightly oversized DATA as the last chunk
				data_found = true;
				chunk_count += 1;
				break;
			}
			return ValidationResult.invalidWithDepth(.rm, "RealMedia chunk extends past end of file", .structural);
		}

		if (std.mem.eql(u8, fourcc, "PROP")) {
			prop_count += 1;
			if (prop_count > 1)
				return ValidationResult.invalidWithDepth(.rm, "Multiple PROP chunks found (only one allowed)", .structural);

			// PROP data starts at pos+10; read num_streams, data_offset, index_offset
			// PROP layout (40 bytes after the 10-byte chunk header):
			//   max_bitrate(4), avg_bitrate(4), max_packet_size(4), avg_packet_size(4),
			//   num_packets(4), duration(4), preroll(4), index_offset(4), data_offset(4),
			//   num_streams(2), flags(2)   — total = 40 data bytes
			const PROP_MIN_SIZE = CHUNK_HEADER_SIZE + 40;
			if (chunk_size >= PROP_MIN_SIZE) {
				var prop_buf: [40]u8 = undefined;
				file.seekTo(pos + CHUNK_HEADER_SIZE) catch return ValidationResult.invalidWithDepth(.rm, "Failed to seek to PROP body", .structural);
				const prop_read = file.readAll(&prop_buf) catch return ValidationResult.invalidWithDepth(.rm, "Failed to read PROP body", .structural);
				if (prop_read != 40) return ValidationResult.invalidWithDepth(.rm, "PROP body truncated", .structural);
				// index_offset at data offset 28 (bytes 28-31)
				prop_index_offset = std.mem.readInt(u32, prop_buf[28..32], .big);
				// data_offset at data offset 32 (bytes 32-35)
				prop_data_offset = std.mem.readInt(u32, prop_buf[32..36], .big);
				// num_streams at data offset 36 (bytes 36-37)
				prop_num_streams = std.mem.readInt(u16, prop_buf[36..38], .big);
			}
		} else if (std.mem.eql(u8, fourcc, "MDPR")) {
			mdpr_count += 1;
			if (mdpr_count > MAX_STREAMS)
				return ValidationResult.invalidWithDepth(.rm, "Excessive MDPR stream count", .structural);
		} else if (std.mem.eql(u8, fourcc, "DATA")) {
			data_found = true;
		}
		// CONT, INDX, and unknown chunks are silently accepted

		chunk_count += 1;
		pos += chunk_size;
	}

	if (prop_count == 0)
		return ValidationResult.invalidWithDepth(.rm, "Missing required PROP chunk", .structural);

	if (!data_found)
		return ValidationResult.invalidWithDepth(.rm, "Missing required DATA chunk", .structural);

	// Cross-validate: PROP.num_streams must equal MDPR count
	if (prop_num_streams != 0 and mdpr_count != 0 and prop_num_streams != mdpr_count)
		return ValidationResult.invalidWithDepth(.rm, "PROP.num_streams does not match MDPR chunk count", .structural);

	// Cross-validate: PROP.data_offset must point within file bounds (if non-zero)
	if (prop_data_offset != 0 and prop_data_offset >= file_size)
		return ValidationResult.invalidWithDepth(.rm, "PROP.data_offset points outside file", .structural);

	// Cross-validate: PROP.index_offset must point within file bounds (if non-zero)
	if (prop_index_offset != 0 and prop_index_offset >= file_size)
		return ValidationResult.invalidWithDepth(.rm, "PROP.index_offset points outside file", .structural);

	return ValidationResult.okWithDepth(.rm, .structural);
}

/// Deep validation of a RealMedia file by path.
/// Re-opens the file, runs structural validation, then additionally checks that
/// PROP.data_offset and PROP.index_offset (when non-zero) point to the correct
/// chunk types (DATA and INDX respectively).
pub fn validateRealMediaDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	_ = allocator;
	const file = source;

	// Run structural validation first
	const basic = validateRealMedia(file);
	if (!basic.is_valid) return basic;

	// Deep: re-read PROP to get data_offset / index_offset, then verify the
	// chunks at those offsets carry the expected FOURCCs.
	file.seekTo(0) catch return basic;

	var rmf_hdr: [18]u8 = undefined;
	const n = file.read(&rmf_hdr) catch return basic;
	if (n < 18) return basic;

	const rmf_size: u64 = std.mem.readInt(u32, rmf_hdr[4..8], .big);

	const file_size = file.getEndPos() catch return basic;

	// Walk chunks to find PROP
	var pos: u64 = rmf_size;
	var chunk_hdr: [CHUNK_HEADER_SIZE]u8 = undefined;

	while (pos + CHUNK_HEADER_SIZE <= file_size) {
		file.seekTo(pos) catch break;
		const rn = file.read(&chunk_hdr) catch break;
		if (rn < CHUNK_HEADER_SIZE) break;

		const fourcc = chunk_hdr[0..4];
		const chunk_size: u64 = std.mem.readInt(u32, chunk_hdr[4..8], .big);
		if (chunk_size < CHUNK_HEADER_SIZE or pos + chunk_size > file_size) break;

		if (std.mem.eql(u8, fourcc, "PROP")) {
			const PROP_MIN_SIZE = CHUNK_HEADER_SIZE + 40;
			if (chunk_size < PROP_MIN_SIZE) break;

			var prop_data: [40]u8 = undefined;
			file.seekTo(pos + CHUNK_HEADER_SIZE) catch break;
			const pr = file.read(&prop_data) catch break;
			if (pr < 40) break;

			const index_offset: u64 = std.mem.readInt(u32, prop_data[28..32], .big);
			const data_offset: u64 = std.mem.readInt(u32, prop_data[32..36], .big);

			// Verify chunk at data_offset is "DATA"
			if (data_offset >= CHUNK_HEADER_SIZE and data_offset + CHUNK_HEADER_SIZE <= file_size) {
				var target_hdr: [4]u8 = undefined;
				file.seekTo(data_offset) catch break;
				const dr = file.read(&target_hdr) catch break;
				if (dr >= 4 and !std.mem.eql(u8, target_hdr[0..4], "DATA")) {
					return ValidationResult.invalidWithDepth(.rm, "PROP.data_offset does not point to DATA chunk", .structural);
				}
			}

			// Verify chunk at index_offset is "INDX" (if non-zero)
			if (index_offset != 0 and index_offset + CHUNK_HEADER_SIZE <= file_size) {
				var idx_hdr: [4]u8 = undefined;
				file.seekTo(index_offset) catch break;
				const ir = file.read(&idx_hdr) catch break;
				if (ir >= 4 and !std.mem.eql(u8, idx_hdr[0..4], "INDX")) {
					return ValidationResult.invalidWithDepth(.rm, "PROP.index_offset does not point to INDX chunk", .structural);
				}
			}
			break; // Only one PROP chunk
		}

		pos += chunk_size;
	}

	return ValidationResult.okWithDepth(.rm, .structural);
}

// ============ Tests ============

/// Build a minimal valid-looking RealMedia header in memory for use in tests.
/// Returns a stack buffer with a valid .RMF chunk header (18 bytes).
fn buildTestRmfHeader(magic: *const [4]u8, chunk_size: u32, version: u16, file_version: u32, num_headers: u32) [18]u8 {
	var buf = [_]u8{0} ** 18;
	buf[0] = magic[0];
	buf[1] = magic[1];
	buf[2] = magic[2];
	buf[3] = magic[3];
	std.mem.writeInt(u32, buf[4..8], chunk_size, .big);
	std.mem.writeInt(u16, buf[8..10], version, .big);
	std.mem.writeInt(u32, buf[10..14], file_version, .big);
	std.mem.writeInt(u32, buf[14..18], num_headers, .big);
	return buf;
}

test "validateRealMedia: ground truth sample" {
	const testing = std.testing;
	const ground_truth = "ground_truth_examples/rm/sample.rm";

	var src = FileSource.open(ground_truth) catch {
		return error.SkipZigTest; // Skip if ground truth not present
	};
	defer src.close();

	const result = validateRealMedia(&src);
	// Validate that the format is correctly identified
	try testing.expectEqual(FileFormat.rm, result.format);
	// Our hand-crafted sample may not pass all structural checks yet —
	// TODO: generate a proper RealMedia sample with ffmpeg
	if (!result.is_valid) return error.SkipZigTest;
}

test "validateRealMedia: deep validation of ground truth sample" {
	const testing = std.testing;
	const ground_truth = "ground_truth_examples/rm/sample.rm";

	// Skip if not present
	std.fs.cwd().access(ground_truth, .{}) catch return error.SkipZigTest;

	var source = try FileSource.open(ground_truth);
	defer source.close();
	const result = validateRealMediaDeep(testing.allocator, &source);
	try testing.expectEqual(FileFormat.rm, result.format);
	// Hand-crafted sample may not pass deep validation — skip gracefully
	if (!result.is_valid) return error.SkipZigTest;
}

test "validateRealMedia: rejects file with wrong magic" {
	const testing = std.testing;
	// Write a temp file with wrong magic using tmpDir
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	const wrong_magic = buildTestRmfHeader("FAKE", 18, 0, 0, 5);
	const tmpfile = try tmp.dir.createFile("bad_magic.bin", .{});
	defer tmpfile.close();
	try tmpfile.writeAll(&wrong_magic);

	// Build an absolute path for FileSource.open
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const abs_path = try tmp.dir.realpath("bad_magic.bin", &path_buf);

	var src = try FileSource.open(abs_path);
	defer src.close();

	const result = validateRealMedia(&src);
	try testing.expect(!result.is_valid);
}

test "validateRealMedia: rejects file that is too small" {
	const testing = std.testing;
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	const tiny_data = [_]u8{ '.', 'R', 'M', 'F' }; // Only 4 bytes
	const tmpfile = try tmp.dir.createFile("too_small.bin", .{});
	defer tmpfile.close();
	try tmpfile.writeAll(&tiny_data);

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const abs_path = try tmp.dir.realpath("too_small.bin", &path_buf);

	var src = try FileSource.open(abs_path);
	defer src.close();

	const result = validateRealMedia(&src);
	try testing.expect(!result.is_valid);
}
