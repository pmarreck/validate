//! Microsoft Cabinet (.cab) archive validator.
//!
//! Validates the MSCF binary format: header reserved fields, version, sizes,
//! folder/file entry offsets, and CFDATA block checksums (XOR-fold algorithm).

const std = @import("std");
const runtime = @import("runtime.zig");
const fv = @import("format_validation.zig");
const FileFormat = fv.FileFormat;
const ValidationResult = fv.ValidationResult;
const ValidationDepth = fv.ValidationDepth;
const fs = @import("file_source.zig");
const FileSource = fs.FileSource;
const Allocator = std.mem.Allocator;

// ─── CAB constants ────────────────────────────────────────────────────────────

const CAB_MAGIC = "MSCF";
const CAB_VERSION_MAJOR: u8 = 1;
const CAB_VERSION_MINOR: u8 = 3;
const CAB_HEADER_SIZE: usize = 36;

// Flag bits in the flags field
const FLAG_PREV_CABINET: u16 = 0x0001;
const FLAG_NEXT_CABINET: u16 = 0x0002;
const FLAG_RESERVE_PRESENT: u16 = 0x0004;

// ─── Checksum helper ──────────────────────────────────────────────────────────

/// Compute the CAB XOR-fold checksum over `data`, seeded by `seed`.
/// Full 4-byte chunks are read as little-endian u32 and XOR'd together.
/// Any trailing 1–3 bytes are combined into one word using big-endian byte
/// ordering within the partial word (most-significant byte at lowest index).
/// This matches the Microsoft Cabinet SDK CSUMCompute algorithm.
/// A stored checksum of 0 means "not checksummed" — callers should skip verification.
fn cabChecksum(seed: u32, data: []const u8) u32 {
	var acc: u32 = seed;
	const full_words = data.len / 4;
	for (0..full_words) |wi| {
		acc ^= std.mem.readInt(u32, data[wi * 4 ..][0..4], .little);
	}
	// Trailing 1–3 bytes — big-endian ordering within the partial word
	const rem = data.len & 3;
	if (rem > 0) {
		const base = full_words * 4;
		var word: u32 = 0;
		for (0..rem) |j| {
			word |= @as(u32, data[base + j]) << @intCast((rem - 1 - j) * 8);
		}
		acc ^= word;
	}
	return acc;
}

// ─── Structural validator ─────────────────────────────────────────────────────

/// Validate a Microsoft Cabinet (.cab) file structurally.
/// Checks magic, reserved fields, version, sizes, and walks CFFOLDER and CFFILE
/// entries to verify all offsets are within file bounds.
pub fn validateCab(file: *FileSource) ValidationResult {
	file.seekTo(0) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "to start");

	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.cab, .failed_to_get, "file size");
	};

	// Minimum: 36-byte fixed header + 8-byte CFFOLDER + minimal CFFILE
	if (file_size < CAB_HEADER_SIZE + 8 + 16 + 1) {
		return ValidationResult.invalidCode(.cab, .file_too_small, "CAB header");
	}

	var hdr: [CAB_HEADER_SIZE]u8 = undefined;
	const got = file.readAll(&hdr) catch {
		return ValidationResult.invalidCode(.cab, .failed_to_read, "CAB header");
	};
	if (got < CAB_HEADER_SIZE) {
		return ValidationResult.invalidCode(.cab, .truncated, "CAB header");
	}

	// Magic "MSCF"
	if (!std.mem.eql(u8, hdr[0..4], CAB_MAGIC)) {
		return ValidationResult.invalidCode(.cab, .invalid_signature, "MSCF magic");
	}

	// reserved1, reserved2, reserved3 must be zero
	if (std.mem.readInt(u32, hdr[4..8], .little) != 0) {
		return ValidationResult.invalidCode(.cab, .invalid_value, "reserved1 field (must be 0)");
	}
	if (std.mem.readInt(u32, hdr[0x0C..0x10], .little) != 0) {
		return ValidationResult.invalidCode(.cab, .invalid_value, "reserved2 field (must be 0)");
	}
	if (std.mem.readInt(u32, hdr[0x14..0x18], .little) != 0) {
		return ValidationResult.invalidCode(.cab, .invalid_value, "reserved3 field (must be 0)");
	}

	// Version must be 1.3
	if (hdr[0x19] != CAB_VERSION_MAJOR or hdr[0x18] != CAB_VERSION_MINOR) {
		return ValidationResult.invalidWithDepth(.cab, "CAB version must be 1.3", .structural);
	}

	// cbCabinet: total cabinet size vs actual file size.
	// Signed (Authenticode) CABs have a digital signature appended AFTER the
	// cabinet proper, so cb_cabinet < file_size is expected when RESERVE_PRESENT
	// is set.  We read the flags field early (it's already in our header buffer)
	// to make the distinction.
	const cb_cabinet = std.mem.readInt(u32, hdr[8..12], .little);
	const early_flags = std.mem.readInt(u16, hdr[0x1E..0x20], .little);
	if (cb_cabinet > file_size) {
		return ValidationResult.invalidWithDepth(.cab, "cbCabinet exceeds actual file size (truncated)", .structural);
	}
	if (cb_cabinet < file_size and (early_flags & FLAG_RESERVE_PRESENT == 0)) {
		return ValidationResult.invalidWithDepth(.cab, "cbCabinet does not match actual file size", .structural);
	}

	// coffFiles: offset to first CFFILE entry must be within file
	const coff_files = std.mem.readInt(u32, hdr[0x10..0x14], .little);
	if (coff_files >= file_size) {
		return ValidationResult.invalidCode(.cab, .exceeds_bounds, "coffFiles offset");
	}

	const c_folders = std.mem.readInt(u16, hdr[0x1A..0x1C], .little);
	const c_files = std.mem.readInt(u16, hdr[0x1C..0x1E], .little);
	const flags = std.mem.readInt(u16, hdr[0x1E..0x20], .little);

	if (c_folders == 0) {
		return ValidationResult.invalidCode(.cab, .invalid_value, "cFolders (must be >= 1)");
	}
	if (c_files == 0) {
		return ValidationResult.invalidCode(.cab, .invalid_value, "cFiles (must be >= 1)");
	}

	// Parse optional reserve fields if RESERVE_PRESENT
	var cb_cf_header: u16 = 0;
	var cb_cf_folder: u8 = 0;
	// cb_cf_data is per-CFDATA extra (we don't need it for structural checks)
	var after_hdr: u64 = CAB_HEADER_SIZE;

	if (flags & FLAG_RESERVE_PRESENT != 0) {
		// 4 bytes: cbCFHeader(u16), cbCFFolder(u8), cbCFData(u8)
		if (after_hdr + 4 > file_size) {
			return ValidationResult.invalidCode(.cab, .file_too_small, "CAB reserve fields");
		}
		var res: [4]u8 = undefined;
		file.seekTo(after_hdr) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "reserve fields");
		_ = file.readAll(&res) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "reserve fields");
		cb_cf_header = std.mem.readInt(u16, res[0..2], .little);
		cb_cf_folder = res[2];
		// res[3] is cbCFData (per-CFDATA extra bytes)
		after_hdr += 4 + cb_cf_header;
	}

	// Handle prev/next cabinet name strings in header (skip over them for offset tracking)
	// These appear in the extended header area; we don't need to parse them for structural validation,
	// but we need to know that the CFFOLDER entries begin right after.
	// Per spec: if PREV_CABINET or NEXT_CABINET, null-terminated strings follow the reserve area.
	// For structural validation we rely on the stored offsets rather than re-deriving them.

	// Walk CFFOLDER entries
	// Each CFFOLDER is 8 bytes + cbCFFolder extra bytes
	const folder_entry_size: u64 = 8 + cb_cf_folder;
	var folder_offset: u64 = after_hdr;

	for (0..c_folders) |_| {
		if (folder_offset + 8 > file_size) {
			return ValidationResult.invalidCode(.cab, .exceeds_bounds, "CFFOLDER entry");
		}
		var fdr: [8]u8 = undefined;
		file.seekTo(folder_offset) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFFOLDER");
		_ = file.readAll(&fdr) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "CFFOLDER");

		const coff_cab_start = std.mem.readInt(u32, fdr[0..4], .little);
		if (coff_cab_start >= file_size) {
			return ValidationResult.invalidCode(.cab, .exceeds_bounds, "CFFOLDER coffCabStart");
		}

		folder_offset += folder_entry_size;
	}

	// Walk CFFILE entries
	var file_offset: u64 = coff_files;
	for (0..c_files) |_| {
		if (file_offset + 16 > file_size) {
			return ValidationResult.invalidCode(.cab, .exceeds_bounds, "CFFILE entry");
		}
		var cff: [16]u8 = undefined;
		file.seekTo(file_offset) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFFILE");
		_ = file.readAll(&cff) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "CFFILE");

		const i_folder = std.mem.readInt(u16, cff[8..10], .little);
		// iFolder values 0xFFFD/FFFE/FFFF are special (spanning), treat as valid
		if (i_folder < 0xFFFD and i_folder >= c_folders) {
			return ValidationResult.invalidCode(.cab, .invalid_value, "CFFILE iFolder out of range");
		}

		// Skip the NUL-terminated filename
		file_offset += 16;
		var null_found = false;
		const scan: u64 = file_offset;
		// Scan up to 256 bytes for the null terminator
		var name_buf: [256]u8 = undefined;
		const to_scan: usize = @intCast(@min(256, file_size - scan));
		if (to_scan == 0) {
			return ValidationResult.invalidCode(.cab, .truncated, "CFFILE filename");
		}
		file.seekTo(scan) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFFILE filename");
		const scanned = file.readAll(name_buf[0..to_scan]) catch {
			return ValidationResult.invalidCode(.cab, .failed_to_read, "CFFILE filename");
		};
		for (name_buf[0..scanned], 0..) |b, idx| {
			if (b == 0) {
				file_offset = scan + idx + 1;
				null_found = true;
				break;
			}
		}
		if (!null_found) {
			return ValidationResult.invalidCode(.cab, .truncated, "CFFILE filename (no null terminator)");
		}
	}

	return ValidationResult.okWithDepth(.cab, .structural);
}

// ─── Deep validator ───────────────────────────────────────────────────────────

/// Deep-validate a Microsoft Cabinet (.cab) file: structural checks plus
/// verification of all CFDATA block checksums (XOR-fold algorithm).
/// Skips checksum verification for blocks where the stored checksum is 0.
pub fn validateCabDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	_ = allocator;
	const file = source;

	// Run structural validation first
	const structural = validateCab(file);
	if (!structural.is_valid) return structural;

	// Now walk all CFFOLDER entries and verify CFDATA block checksums.
	file.seekTo(0) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "to start for deep");

	var hdr: [CAB_HEADER_SIZE]u8 = undefined;
	_ = file.readAll(&hdr) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "header for deep");

	const c_folders = std.mem.readInt(u16, hdr[0x1A..0x1C], .little);
	const flags = std.mem.readInt(u16, hdr[0x1E..0x20], .little);

	var cb_cf_header: u16 = 0;
	var cb_cf_folder: u8 = 0;
	var cb_cf_data: u8 = 0;
	var after_hdr: u64 = CAB_HEADER_SIZE;

	if (flags & FLAG_RESERVE_PRESENT != 0) {
		var res: [4]u8 = undefined;
		file.seekTo(after_hdr) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "reserve");
		_ = file.readAll(&res) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "reserve");
		cb_cf_header = std.mem.readInt(u16, res[0..2], .little);
		cb_cf_folder = res[2];
		cb_cf_data = res[3];
		after_hdr += 4 + cb_cf_header;
	}

	const file_size = file.getEndPos() catch return ValidationResult.invalidCode(.cab, .failed_to_get, "file size");
	const folder_entry_size: u64 = 8 + cb_cf_folder;

	var folder_offset: u64 = after_hdr;
	for (0..c_folders) |_| {
		var fdr: [8]u8 = undefined;
		file.seekTo(folder_offset) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFFOLDER deep");
		_ = file.readAll(&fdr) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "CFFOLDER deep");

		const coff_cab_start = std.mem.readInt(u32, fdr[0..4], .little);
		const c_cfdata = std.mem.readInt(u16, fdr[4..6], .little);

		// Walk each CFDATA block for this folder
		// CFDATA header: 4 (csum) + 2 (cbData) + 2 (cbUncomp) + cb_cf_data = 8 + cb_cf_data bytes
		const cfdata_hdr_size: u64 = 8 + cb_cf_data;
		var data_offset: u64 = coff_cab_start;

		for (0..c_cfdata) |_| {
			if (data_offset + cfdata_hdr_size > file_size) {
				return ValidationResult.invalidCode(.cab, .exceeds_bounds, "CFDATA header");
			}
			var dh: [8]u8 = undefined;
			file.seekTo(data_offset) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFDATA");
			_ = file.readAll(&dh) catch return ValidationResult.invalidCode(.cab, .failed_to_read, "CFDATA header");

			const stored_csum = std.mem.readInt(u32, dh[0..4], .little);
			const cb_data = std.mem.readInt(u16, dh[4..6], .little);

			if (data_offset + cfdata_hdr_size + cb_data > file_size) {
				return ValidationResult.invalidCode(.cab, .exceeds_bounds, "CFDATA compressed payload");
			}

			// Verify checksum when non-zero.
			// Per [MS-CAB] spec: stored_csum == CSUMCompute(ab, cbData, CSUMCompute(&cbData_cbUncomp, 4, 0))
			// i.e. inner = checksum of the 4-byte sub-header (bytes 4..8, seed=0),
			//      outer = checksum of compressed data (cbData bytes, seed=inner).
			if (stored_csum != 0) {
				// Step 1: inner = cabChecksum(seed=0, dh[4..8])
				const inner = cabChecksum(0, dh[4..8]);
				// Step 2: outer = cabChecksum(seed=inner, compressed_data)
				// We stream in 4-byte-aligned chunks to avoid partial-tail mid-stream.
				// Only the last read can have a non-4-byte length.
				const data_start = data_offset + cfdata_hdr_size;
				var acc: u32 = inner;
				var remaining: u64 = cb_data;
				var read_pos: u64 = data_start;
				var chunk_buf: [4096]u8 = undefined;
				while (remaining > 0) {
					// Read a 4-byte aligned chunk (so tail handling only at the very end).
					var chunk_len: usize = @intCast(@min(remaining, chunk_buf.len));
					// Align to 4-byte boundary unless this is the last chunk
					if (remaining > chunk_buf.len) {
						chunk_len &= ~@as(usize, 3); // round down to multiple of 4
						if (chunk_len == 0) chunk_len = 4;
					}
					file.seekTo(read_pos) catch return ValidationResult.invalidCode(.cab, .failed_to_seek, "CFDATA payload");
					const got2 = file.readAll(chunk_buf[0..chunk_len]) catch {
						return ValidationResult.invalidCode(.cab, .failed_to_read, "CFDATA payload");
					};
					if (got2 != chunk_len) {
						return ValidationResult.invalidCode(.cab, .truncated, "CFDATA payload");
					}
					acc = cabChecksum(acc, chunk_buf[0..got2]);
					read_pos += got2;
					remaining -= got2;
				}

				if (acc != stored_csum) {
					return ValidationResult.invalidCodeWithDepth(.cab, .checksum_mismatch, "CFDATA block", .full);
				}
			}

			data_offset += cfdata_hdr_size + cb_data;
		}

		folder_offset += folder_entry_size;
	}

	return ValidationResult.okWithDepth(.cab, .full);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "validateCab: valid CAB ground truth" {
	var file = FileSource.open("ground_truth_examples/cab/sample.cab") catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer file.close();
	const result = validateCab(&file);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.cab, result.format);
	try testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "validateCabDeep: valid CAB ground truth deep" {
	var source = FileSource.open("ground_truth_examples/cab/sample.cab") catch |err| {
		if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
		return err;
	};
	defer source.close();
	const result = validateCabDeep(testing.allocator, &source);
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.cab, result.format);
	// Depth is checksum (CFDATA checksums verified) or structural if no checksums present
	try testing.expect(result.validation_depth == .full or result.validation_depth == .structural);
}

/// Helper: write `data` to a temp file and open it as FileSource.
/// Returns the FileSource (caller calls close()) and path buf is populated.
fn tmpCabFile(tmp_dir: *std.testing.TmpDir, name: []const u8, data: []const u8) !FileSource {
	{
		const wf = try tmp_dir.dir.createFile(runtime.io(), name, .{});
		defer wf.close(runtime.io());
		try wf.writePositionalAll(runtime.io(), data, 0);
	}
	const path = try runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, name);
	defer std.testing.allocator.free(path);
	return FileSource.open(path);
}

test "validateCab: truncated file rejected" {
	// Only 10 bytes — too small to be a CAB
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	const data = [_]u8{ 0x4D, 0x53, 0x43, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
	var source = try tmpCabFile(&tmp, "tiny.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: wrong magic rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	// 101-byte file but wrong magic
	var data = [_]u8{0} ** 101;
	data[0] = 'X';
	data[1] = 'X';
	data[2] = 'X';
	data[3] = 'X';
	var source = try tmpCabFile(&tmp, "bad_magic.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: non-zero reserved1 rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	// Build a header with reserved1 != 0; 64 bytes
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	// reserved1 = 1 (non-zero, should fail)
	data[4] = 0x01;
	// cbCabinet = 64 (matches our array length)
	data[8] = 64;
	// version minor=3, major=1
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	var source = try tmpCabFile(&tmp, "res1.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: wrong version rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	// cbCabinet = 64
	data[8] = 64;
	// version minor=2, major=1 (wrong minor, should be 3)
	data[0x18] = 0x02;
	data[0x19] = 0x01;
	var source = try tmpCabFile(&tmp, "ver.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: cbCabinet mismatch rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	// cbCabinet = 99 but file is 64 bytes → mismatch
	data[8] = 99;
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	var source = try tmpCabFile(&tmp, "sz.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: signed CAB with cbCabinet < file_size accepted when RESERVE_PRESENT" {
	// Simulate an Authenticode-signed CAB: cbCabinet points to the cabinet proper,
	// but the file has extra signature bytes appended after. RESERVE_PRESENT is set.
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Build a minimal valid CAB header (36 bytes) + reserve fields (4 bytes) +
	// 1 CFFOLDER (8 bytes) + 1 CFFILE (16 bytes + 1 NUL filename) = 65 bytes of cabinet data.
	// Then append 16 bytes of fake Authenticode signature.
	const cab_size: u32 = 65; // the cabinet proper size
	const total_size: usize = 65 + 16; // file on disk includes signature
	var data = [_]u8{0} ** total_size;

	// Magic "MSCF"
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';

	// reserved1 = 0 (already zero)

	// cbCabinet = 65 (cabinet proper, NOT total file size)
	data[8] = cab_size;
	data[9] = 0;
	data[10] = 0;
	data[11] = 0;

	// reserved2 at 0x0C = 0 (already zero)

	// coffFiles at 0x10 = 48 (36 hdr + 4 reserve + 8 folder entry)
	data[0x10] = 48;

	// reserved3 at 0x14 = 0 (already zero)

	// version minor=3, major=1
	data[0x18] = 0x03;
	data[0x19] = 0x01;

	// cFolders = 1
	data[0x1A] = 0x01;

	// cFiles = 1
	data[0x1C] = 0x01;

	// flags = FLAG_RESERVE_PRESENT (0x0004)
	data[0x1E] = 0x04;

	// Reserve fields at offset 36: cbCFHeader=0, cbCFFolder=0, cbCFData=0
	// (4 bytes, all zero — already zero)

	// CFFOLDER at offset 40: coffCabStart points to CFDATA area
	data[40] = 56; // coffCabStart = 56 (within bounds)
	data[41] = 0;
	data[42] = 0;
	data[43] = 0;
	// cCFData = 0 (no data blocks)
	data[44] = 0;
	data[45] = 0;
	// typeCompress = 0 (NONE)
	data[46] = 0;
	data[47] = 0;

	// CFFILE at offset 48: 16 bytes header + NUL-terminated filename
	// cbFile (u32) = 0
	data[48] = 0;
	// uoffFolderStart (u32) = 0
	data[52] = 0;
	// iFolder (u16) = 0
	data[56] = 0;
	// date (u16), time (u16), attribs (u16) — leave zero
	// Filename starts at offset 64, just a NUL byte
	data[64] = 0;

	// Bytes 65..80 are fake Authenticode signature (non-zero to be realistic)
	for (65..total_size) |i| {
		data[i] = 0xAB;
	}

	var source = try tmpCabFile(&tmp, "signed.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	// Signed CAB with RESERVE_PRESENT and cb_cabinet < file_size should be ACCEPTED
	try testing.expect(result.is_valid);
	try testing.expectEqual(FileFormat.cab, result.format);
}

test "validateCab: cbCabinet > file_size always rejected (truncated)" {
	// cbCabinet claims more than file size — always invalid regardless of flags
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	// cbCabinet = 200, file is only 64 bytes
	data[8] = 200;
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	// flags = RESERVE_PRESENT (shouldn't help — file is truncated)
	data[0x1E] = 0x04;
	var source = try tmpCabFile(&tmp, "trunc_signed.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: cbCabinet < file_size WITHOUT RESERVE_PRESENT rejected" {
	// Extra bytes after cabinet but no RESERVE_PRESENT flag — should be rejected
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	const cab_size: u32 = 64;
	const total_size: usize = 80; // 16 extra bytes
	var data = [_]u8{0} ** total_size;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	// cbCabinet = 64 but file is 80
	data[8] = @intCast(cab_size);
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	// flags = 0 (NO RESERVE_PRESENT)
	data[0x1E] = 0x00;
	var source = try tmpCabFile(&tmp, "extra_no_flag.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}


test "validateCab: zero cFolders rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	data[8] = 64;
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	data[0x10] = 36; // coffFiles = 36
	data[0x1A] = 0x00; // cFolders = 0 (invalid)
	data[0x1C] = 0x01; // cFiles = 1
	var source = try tmpCabFile(&tmp, "nofld.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "validateCab: zero cFiles rejected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	var data = [_]u8{0} ** 64;
	data[0] = 'M';
	data[1] = 'S';
	data[2] = 'C';
	data[3] = 'F';
	data[8] = 64;
	data[0x18] = 0x03;
	data[0x19] = 0x01;
	data[0x10] = 36;
	data[0x1A] = 0x01; // cFolders = 1
	data[0x1C] = 0x00; // cFiles = 0 (invalid)
	var source = try tmpCabFile(&tmp, "nofile.cab", &data);
	defer source.close();
	const result = validateCab(&source);
	try testing.expect(!result.is_valid);
}

test "cabChecksum: known values" {
	// Empty slice → 0
	try testing.expectEqual(@as(u32, 0), cabChecksum(0, &[_]u8{}));

	// Single 4-byte chunk (LE): bytes 0x04 0x03 0x02 0x01 → u32 LE = 0x01020304
	try testing.expectEqual(@as(u32, 0x01020304), cabChecksum(0, &[_]u8{ 0x04, 0x03, 0x02, 0x01 }));

	// Two identical words XOR to 0
	try testing.expectEqual(@as(u32, 0), cabChecksum(0, &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04 }));

	// Seed carries through
	try testing.expectEqual(@as(u32, 0x01020304 ^ 0x0000_0001), cabChecksum(1, &[_]u8{ 0x04, 0x03, 0x02, 0x01 }));

	// 3 trailing bytes: big-endian within partial word → bytes [0x21,0x5c,0x6e] → word = 0x215c6e
	try testing.expectEqual(@as(u32, 0x215c6e), cabChecksum(0, &[_]u8{ 0x21, 0x5c, 0x6e }));

	// Ground-truth CFDATA checksum verification:
	// hdr4 = cbData(0x0f,0x00) + cbUncomp(0x0f,0x00) → checksum = 0x000F000F
	const hdr4 = [_]u8{ 0x0f, 0x00, 0x0f, 0x00 };
	const inner = cabChecksum(0, &hdr4);
	try testing.expectEqual(@as(u32, 0x000F000F), inner);
	// payload = "Hello, World!\n" (literal backslash n, 15 bytes)
	const payload = "Hello, World!\\n";
	const outer = cabChecksum(inner, payload);
	try testing.expectEqual(@as(u32, 0x5F0E6729), outer);
}

test "validateCabDeep: corrupt CFDATA checksum rejected" {
	// Load the ground truth file, read it, flip a byte in the compressed data area,
	// save to a temp file, then deep-validate — expect checksum failure.
	const orig_path = "ground_truth_examples/cab/sample.cab";
	var orig_file = FileSource.open(orig_path) catch |err| {
		if (err == error.FileNotFound) return error.SkipZigTest;
		return err;
	};
	defer orig_file.close();

	const file_size = orig_file.getEndPos() catch return error.SkipZigTest;
	if (file_size > 4096) return error.SkipZigTest;

	var buf: [4096]u8 = undefined;
	const n = orig_file.readAll(buf[0..@intCast(file_size)]) catch return error.SkipZigTest;
	if (n != file_size) return error.SkipZigTest;

	// Locate CFDATA start dynamically via CFFOLDER coffCabStart (offset 0x24 in fixed header)
	const coff_cab_start = std.mem.readInt(u32, buf[0x24..0x28], .little);
	if (coff_cab_start + 8 > n) return error.SkipZigTest;

	const stored_csum = std.mem.readInt(u32, buf[coff_cab_start..][0..4], .little);
	if (stored_csum == 0) return error.SkipZigTest; // no checksum → can't test corruption

	// Flip a byte inside the compressed payload (first byte after 8-byte CFDATA header)
	const flip_offset = coff_cab_start + 8;
	if (flip_offset >= n) return error.SkipZigTest;
	buf[flip_offset] ^= 0xFF;

	// Write corrupt bytes to a temp file and deep-validate it
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();
	{
		const wf = try tmp.dir.createFile(runtime.io(), "corrupt.cab", .{});
		defer wf.close(runtime.io());
		try wf.writePositionalAll(runtime.io(), buf[0..n], 0);
	}
	const tmp_path = try runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "corrupt.cab");
	defer std.testing.allocator.free(tmp_path);

	// Structural pass should succeed (magic/header unchanged)
	var struct_src = try FileSource.open(tmp_path);
	defer struct_src.close();
	const struct_result = validateCab(&struct_src);
	try testing.expect(struct_result.is_valid);

	// Deep pass should fail on the bad checksum
	var deep_src = try FileSource.open(tmp_path);
	defer deep_src.close();
	const deep_result = validateCabDeep(testing.allocator, &deep_src);
	try testing.expect(!deep_result.is_valid);
}
