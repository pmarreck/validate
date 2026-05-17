//! WavPack deep decode validation using libwavpack 5.9.0.
//!
//! Decodes every block to PCM samples and checks libwavpack's internal
//! CRC verifier (`WavpackGetNumErrors`). This is the only honest path to
//! WavPack byte-level validation: the per-block CRC32 in the .wv header
//! is computed over decoded samples, not over the compressed bitstream
//! (confirmed in dbry/WavPack `src/unpack.c` line 508).
//!
//! Architecture: we wrap an in-memory buffer with a WavpackStreamReader64
//! callback table so libwavpack never touches the filesystem. The
//! validate core caller already has the file mapped or read; we just
//! hand it a slice. The decode loop discards PCM output (we don't need
//! to render audio), and only checks `crc_errors > 0` at the end.
//!
//! Notes on detection mechanics (verified in libwavpack source):
//! - When a block fails its checksum sub-block (`ID_BLOCK_CHECKSUM` /
//!   `WavpackVerifySingleBlock`), the lib silently sets `block_samples=0`
//!   and continues, filling missing samples with silence. The corruption
//!   surfaces via `WavpackGetNumErrors() > 0`, NOT through the error
//!   message string.
//! - When a block decodes but the post-decode CRC over PCM (`wphdr.crc`)
//!   doesn't match the recomputed CRC, `wpc->crc_errors++` is incremented.
//! - When the file is truncated or otherwise unrecoverable mid-stream,
//!   the decoded sample count comes up short of `WavpackGetNumSamples64`.

const std = @import("std");
const runtime = @import("runtime.zig");
const builtin = @import("builtin");

const wp = @cImport({
	@cInclude("wavpack.h");
});

/// Result of a WavPack deep decode validation pass.
pub const WavPackDecodeResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	blocks_decoded: u32,
	samples_decoded: u64,
	expected_samples: i64, // -1 if unknown (streaming-only file)
	crc_errors: u32,
	channels: u8,
	sample_rate: u32,
	bits_per_sample: u8,

	pub fn ok(blocks: u32, samples: u64, expected: i64, ch: u8, sr: u32, bps: u8) WavPackDecodeResult {
		return .{
			.valid = true,
			.error_message = null,
			.blocks_decoded = blocks,
			.samples_decoded = samples,
			.expected_samples = expected,
			.crc_errors = 0,
			.channels = ch,
			.sample_rate = sr,
			.bits_per_sample = bps,
		};
	}

	pub fn invalid(message: []const u8) WavPackDecodeResult {
		return .{
			.valid = false,
			.error_message = message,
			.blocks_decoded = 0,
			.samples_decoded = 0,
			.expected_samples = -1,
			.crc_errors = 0,
			.channels = 0,
			.sample_rate = 0,
			.bits_per_sample = 0,
		};
	}
};

// In-memory stream backing libwavpack's WavpackStreamReader64. Layout
// matches what the callbacks below expect — see mem_read_bytes etc.
const MemStream = extern struct {
	data: [*]const u8,
	size: i64,
	pos: i64,
	pushed_back: c_int,
	pushed_byte: c_int,
};

fn memReadBytes(id: ?*anyopaque, data: ?*anyopaque, bcount: i32) callconv(.c) i32 {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	var dst: [*]u8 = @ptrCast(data.?);
	var remaining: i32 = bcount;
	var out: i32 = 0;

	if (s.pushed_back != 0 and remaining > 0) {
		dst[0] = @intCast(s.pushed_byte & 0xff);
		s.pushed_back = 0;
		dst += 1;
		remaining -= 1;
		out += 1;
	}

	const avail_i64: i64 = s.size - s.pos;
	const avail: i32 = if (avail_i64 < 0) 0 else if (avail_i64 > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(avail_i64);
	const to_copy: i32 = if (remaining < avail) remaining else avail;
	if (to_copy > 0) {
		@memcpy(dst[0..@intCast(to_copy)], s.data[@intCast(s.pos)..@intCast(s.pos + to_copy)]);
		s.pos += to_copy;
		out += to_copy;
	}
	return out;
}

fn memWriteBytes(id: ?*anyopaque, data: ?*anyopaque, bcount: i32) callconv(.c) i32 {
	_ = id;
	_ = data;
	_ = bcount;
	return 0;
}

fn memGetPos(id: ?*anyopaque) callconv(.c) i64 {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	return s.pos - @as(i64, @intCast(s.pushed_back));
}

fn memSetPosAbs(id: ?*anyopaque, pos: i64) callconv(.c) c_int {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	if (pos < 0 or pos > s.size) return -1;
	s.pos = pos;
	s.pushed_back = 0;
	return 0;
}

fn memSetPosRel(id: ?*anyopaque, delta: i64, mode: c_int) callconv(.c) c_int {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	const base: i64 = switch (mode) {
		0 => 0, // SEEK_SET
		1 => s.pos - @as(i64, @intCast(s.pushed_back)), // SEEK_CUR
		2 => s.size, // SEEK_END
		else => return -1,
	};
	const newpos = base + delta;
	if (newpos < 0 or newpos > s.size) return -1;
	s.pos = newpos;
	s.pushed_back = 0;
	return 0;
}

fn memPushBackByte(id: ?*anyopaque, c: c_int) callconv(.c) c_int {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	if (s.pushed_back != 0) return -1; // EOF
	s.pushed_back = 1;
	s.pushed_byte = c;
	return c;
}

fn memGetLength(id: ?*anyopaque) callconv(.c) i64 {
	const s: *MemStream = @ptrCast(@alignCast(id.?));
	return s.size;
}

fn memCanSeek(id: ?*anyopaque) callconv(.c) c_int {
	_ = id;
	return 1;
}

fn memTruncate(id: ?*anyopaque) callconv(.c) c_int {
	_ = id;
	return 0;
}

fn memClose(id: ?*anyopaque) callconv(.c) c_int {
	_ = id;
	return 0;
}

const mem_reader: wp.WavpackStreamReader64 = .{
	.read_bytes = &memReadBytes,
	.write_bytes = &memWriteBytes,
	.get_pos = &memGetPos,
	.set_pos_abs = &memSetPosAbs,
	.set_pos_rel = &memSetPosRel,
	.push_back_byte = &memPushBackByte,
	.get_length = &memGetLength,
	.can_seek = &memCanSeek,
	.truncate_here = &memTruncate,
	.close = &memClose,
};

/// Decode every block of the WavPack file at `bytes` and report whether
/// libwavpack flagged any CRC errors. Returns invalid if the file is
/// unparseable (open failed) or any block fails CRC verification.
pub fn validateWavPackDecode(allocator: std.mem.Allocator, bytes: []const u8) !WavPackDecodeResult {
	if (bytes.len < 32) return WavPackDecodeResult.invalid("WavPack file too small");

	var stream = MemStream{
		.data = bytes.ptr,
		.size = @intCast(bytes.len),
		.pos = 0,
		.pushed_back = 0,
		.pushed_byte = 0,
	};

	// libwavpack stores its error message in a caller-supplied 80-byte buffer.
	var err_buf: [80]u8 = std.mem.zeroes([80]u8);

	// Cast away const on the stream reader pointer — libwavpack's API takes
	// it non-const for backwards-compat reasons but never mutates it.
	var reader_mut: wp.WavpackStreamReader64 = mem_reader;
	const wpc_opt = wp.WavpackOpenFileInputEx64(
		&reader_mut,
		@ptrCast(&stream),
		null,
		&err_buf,
		0,
		0,
	);
	if (wpc_opt == null) {
		// Copy the error message into our allocator since err_buf is stack-local.
		const slen = std.mem.indexOfScalar(u8, &err_buf, 0) orelse err_buf.len;
		const msg = try allocator.dupe(u8, err_buf[0..slen]);
		return WavPackDecodeResult{
			.valid = false,
			.error_message = msg,
			.blocks_decoded = 0,
			.samples_decoded = 0,
			.expected_samples = -1,
			.crc_errors = 0,
			.channels = 0,
			.sample_rate = 0,
			.bits_per_sample = 0,
		};
	}
	defer _ = wp.WavpackCloseFile(wpc_opt);
	const wpc = wpc_opt.?;

	const channels: c_int = wp.WavpackGetNumChannels(wpc);
	const bps: c_int = wp.WavpackGetBytesPerSample(wpc);
	const expected_samples: i64 = wp.WavpackGetNumSamples64(wpc);
	const sample_rate: c_uint = wp.WavpackGetSampleRate(wpc);
	const bits_per_sample: c_int = wp.WavpackGetBitsPerSample(wpc);

	if (channels < 1 or channels > 8 or bps < 1 or bps > 4) {
		return WavPackDecodeResult.invalid("WavPack header: implausible channel/bps");
	}

	// Decode in 4096-sample chunks. Each chunk needs `channels * 4` bytes
	// per sample (libwavpack always returns int32 samples regardless of
	// stored bits-per-sample).
	const chunk_samples: u32 = 4096;
	const buf_len: usize = @as(usize, @intCast(channels)) * chunk_samples;
	const samples_buf = try allocator.alloc(i32, buf_len);
	defer allocator.free(samples_buf);

	var total_decoded: u64 = 0;
	var blocks_decoded: u32 = 0;
	const max_iterations: u64 = (1 << 32); // bound for safety
	var iterations: u64 = 0;
	while (iterations < max_iterations) : (iterations += 1) {
		const got = wp.WavpackUnpackSamples(wpc, samples_buf.ptr, chunk_samples);
		if (got == 0) break;
		total_decoded += got;
		blocks_decoded += 1; // not literally blocks, but decode iterations
	}

	const num_errors_raw = wp.WavpackGetNumErrors(wpc);
	const num_errors: u32 = if (num_errors_raw < 0) 0 else @intCast(num_errors_raw);

	// Drift between expected and actual sample counts indicates either
	// a corrupt block (silenced + filled to length) or a truncated stream
	// (short count). Either way it's a validation failure.
	const sample_count_mismatch = expected_samples > 0 and
		@as(i64, @intCast(total_decoded)) != expected_samples;

	if (num_errors > 0 or sample_count_mismatch) {
		return WavPackDecodeResult{
			.valid = false,
			.error_message = if (num_errors > 0)
				"WavPack block CRC mismatch"
			else
				"WavPack decoded sample count mismatch",
			.blocks_decoded = blocks_decoded,
			.samples_decoded = total_decoded,
			.expected_samples = expected_samples,
			.crc_errors = num_errors,
			.channels = @intCast(channels),
			.sample_rate = @intCast(sample_rate),
			.bits_per_sample = @intCast(bits_per_sample),
		};
	}

	return WavPackDecodeResult.ok(
		blocks_decoded,
		total_decoded,
		expected_samples,
		@intCast(channels),
		@intCast(sample_rate),
		@intCast(bits_per_sample),
	);
}

// ============================================================================
// Tests
// ============================================================================

test "validateWavPackDecode rejects too-small input" {
	const tiny = [_]u8{0} ** 16;
	const r = try validateWavPackDecode(std.testing.allocator, &tiny);
	try std.testing.expect(!r.valid);
}

test "validateWavPackDecode rejects garbage" {
	const garbage = [_]u8{0xff} ** 256;
	const r = try validateWavPackDecode(std.testing.allocator, &garbage);
	try std.testing.expect(!r.valid);
	if (r.error_message) |m| std.testing.allocator.free(m);
}

test "ground truth - WavPack corpus_xorshift validates clean" {
	const path = "ground_truth_examples/wavpack/corpus_xorshift.wv";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	const bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 16 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	const r = try validateWavPackDecode(std.testing.allocator, bytes);
	try std.testing.expect(r.valid);
	try std.testing.expect(r.samples_decoded > 0);
	try std.testing.expectEqual(@as(u32, 0), r.crc_errors);
}

test "ground truth - WavPack sample.wv validates clean" {
	const path = "ground_truth_examples/wavpack/sample.wv";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	const bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 16 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	const r = try validateWavPackDecode(std.testing.allocator, bytes);
	try std.testing.expect(r.valid);
	try std.testing.expect(r.samples_decoded > 0);
}

test "WavPack mid-block bit flip is caught" {
	const path = "ground_truth_examples/wavpack/corpus_xorshift.wv";
	const f = runtime.openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
		else => return err,
	};
	defer f.close(runtime.io());
	var bytes = blk: { const __sz = try f.length(runtime.io()); if (__sz > 16 * 1024 * 1024) return error.StreamTooLong; const __b = try std.testing.allocator.alloc(u8, @intCast(__sz)); _ = try f.readPositionalAll(runtime.io(), __b, 0); break :blk __b; };
	defer std.testing.allocator.free(bytes);

	if (bytes.len < 60_000) return error.SkipZigTest;
	bytes[50_000] ^= 0xff;

	const r = try validateWavPackDecode(std.testing.allocator, bytes);
	try std.testing.expect(!r.valid);
}
