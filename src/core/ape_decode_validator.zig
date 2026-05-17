//! APE deep decode validation using vendored Monkey's Audio SDK 12.73.
//!
//! Decodes every frame of an APE bitstream and surfaces per-frame CRC32
//! mismatches. The CRC stored at the start of each APE frame is
//! computed over the DECODED PCM samples (per
//! APEDecompressCore.cpp::EndFrame in the upstream SDK), so structural
//! validation cannot reach it — only a real decoder can.
//!
//! Architecture: we hand the upstream library a CMemoryIO over our
//! caller-provided byte slice. The library never touches the
//! filesystem. The decode loop discards the PCM output (we don't need
//! to render audio); the C shim returns a status code that distinguishes
//! corruption modes (CRC mismatch, decode error, truncation, MD5
//! mismatch).
//!
//! Why a shim? The upstream API is C++ (IAPEDecompress is a virtual
//! interface). Wrapping it in a thin `extern "C"` function in shim.cpp
//! lets us @cImport from Zig without dragging name-mangled C++ symbols
//! into the validator. Mirrors the libwavpack vendor pattern exactly.

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");

const ape = @cImport({
	@cInclude("validate_ape_shim.h");
});

/// Result of an APE deep decode validation pass.
pub const ApeDecodeResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	blocks_decoded: i64,
	file_version: i32,

	pub fn ok(blocks: i64, version: i32) ApeDecodeResult {
		return .{
			.valid = true,
			.error_message = null,
			.blocks_decoded = blocks,
			.file_version = version,
		};
	}

	pub fn invalid(message: []const u8) ApeDecodeResult {
		return .{
			.valid = false,
			.error_message = message,
			.blocks_decoded = 0,
			.file_version = 0,
		};
	}
};

/// Decode every frame of the APE file at `bytes` and report whether the
/// per-frame CRC32-over-decoded-PCM verification passed. Returns invalid
/// if the file is unparseable, decode fails, the CRC doesn't match, or
/// the stream is truncated short of the declared total block count.
pub fn validateApeDecode(bytes: []const u8) ApeDecodeResult {
	if (bytes.len < 64) return ApeDecodeResult.invalid("APE file too small");

	var total_blocks: i64 = 0;
	var file_version: c_int = 0;
	const rc = ape.validate_ape_decode_check(
		bytes.ptr,
		bytes.len,
		&total_blocks,
		&file_version,
	);

	return switch (rc) {
		0 => ApeDecodeResult.ok(total_blocks, @intCast(file_version)),
		-1 => ApeDecodeResult.invalid("APE: open failed (corrupt or unsupported header)"),
		-2 => ApeDecodeResult.invalid("APE: bitstream decode failure"),
		-3 => ApeDecodeResult.invalid("APE: per-frame CRC32 mismatch"),
		-4 => ApeDecodeResult.invalid("APE: descriptor MD5 mismatch over decoded PCM"),
		-5 => ApeDecodeResult.invalid("APE: decoded sample count mismatch (truncated stream)"),
		else => ApeDecodeResult.invalid("APE: unknown decoder failure"),
	};
}

// ============================================================================
// Tests
// ============================================================================

test "validateApeDecode rejects too-small input" {
	const tiny = [_]u8{0} ** 16;
	const r = validateApeDecode(&tiny);
	try std.testing.expect(!r.valid);
}

test "validateApeDecode rejects garbage" {
	const garbage = [_]u8{0xff} ** 256;
	const r = validateApeDecode(&garbage);
	try std.testing.expect(!r.valid);
}

test "ground truth - APE corpus_synthetic validates clean" {
	const path = "ground_truth_examples/ape/corpus_synthetic.ape";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	const bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 16 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	const r = validateApeDecode(bytes);
	if (!r.valid) {
		std.debug.print("corpus_synthetic.ape rejected: {s}\n", .{r.error_message orelse "<no message>"});
	}
	try std.testing.expect(r.valid);
}

test "ground truth - APE sample.ape validates clean" {
	const path = "ground_truth_examples/ape/sample.ape";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	const bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 32 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	const r = validateApeDecode(bytes);
	if (!r.valid) {
		std.debug.print("sample.ape rejected: {s}\n", .{r.error_message orelse "<no message>"});
	}
	try std.testing.expect(r.valid);
}

test "APE mid-frame bit flip is caught" {
	const path = "ground_truth_examples/ape/corpus_synthetic.ape";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	var bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 16 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	if (bytes.len < 12_000) return error.SkipZigTest;
	// Skip past header/seek table and flip a byte deep in the bitstream.
	bytes[bytes.len - 2000] ^= 0xff;

	const r = validateApeDecode(bytes);
	try std.testing.expect(!r.valid);
}
