//! Bounded PDF LZWDecode adapter over the shared `tiffz.lzwz` core.
//!
//! PDF consumers own their output-memory policy, while `lzwz` owns every
//! format-sensitive LZW concern: bit order, EarlyChange width growth,
//! dictionary references, and the mandatory EOD check. Growing-and-retrying
//! the caller buffer keeps the core allocation-free without reintroducing a
//! second decoder or allowing an unbounded decompression allocation.

const std = @import("std");
const lzwz = @import("tiffz").lzwz;
const Allocator = std.mem.Allocator;

pub const DecodeError = error{
	MalformedCode,
	IncompleteSource,
	OutputTooLarge,
	OutOfMemory,
};

const MIN_INITIAL_OUTPUT_BYTES: usize = 4 * 1024;
const MAX_INITIAL_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

/// Decodes PDF's default LZWDecode filter under a caller-owned output cap.
///
/// PDF defaults `EarlyChange` to 1, which is `lzwz`'s early-width profile.
/// The allocation grows geometrically only after the shared core proves the
/// current buffer is insufficient, bounding total allocations by `max_output`
/// and preserving a precise `OutputTooLarge` outcome for decompression bombs.
pub fn decodePdf(allocator: Allocator, input: []const u8, max_output: usize) DecodeError![]u8 {
	const profile = lzwz.Profile.pdf(true);
	var capacity = initialCapacity(input.len, max_output);

	while (true) {
		const output = allocator.alloc(u8, capacity) catch return error.OutOfMemory;
		const report = lzwz.decode(profile, input, output) catch |err| switch (err) {
			error.DestTooSmall => {
				allocator.free(output);
				if (capacity == max_output) return error.OutputTooLarge;
				capacity = growCapacity(capacity, max_output);
				continue;
			},
			error.MalformedCode => {
				allocator.free(output);
				return error.MalformedCode;
			},
			error.IncompleteSource => {
				allocator.free(output);
				return error.IncompleteSource;
			},
			// `decode()` does not use the count-only exact-extent sink, but
			// preserve a conservative invalid-stream classification if the
			// shared core's public error set grows through this adapter.
			error.DecodedLengthMismatch => {
				allocator.free(output);
				return error.MalformedCode;
			},
		};

		return allocator.realloc(output, report.decoded_len) catch {
			allocator.free(output);
			return error.OutOfMemory;
		};
	}
}

/// Chooses a small working set for ordinary streams while starting large
/// enough for a typical PDF image so retries are logarithmically bounded.
fn initialCapacity(input_len: usize, max_output: usize) usize {
	if (max_output == 0) return 0;
	const scaled = std.math.mul(usize, input_len, 64) catch max_output;
	const desired = @min(MAX_INITIAL_OUTPUT_BYTES, @max(MIN_INITIAL_OUTPUT_BYTES, scaled));
	return @min(desired, max_output);
}

fn growCapacity(capacity: usize, max_output: usize) usize {
	const doubled = std.math.mul(usize, capacity, 2) catch max_output;
	return @min(doubled, max_output);
}

test "decodePdf decodes a complete PDF LZW stream" {
	const decoded = try decodePdf(std.testing.allocator, &.{ 0x20, 0xc0, 0x40 }, 1024);
	defer std.testing.allocator.free(decoded);

	try std.testing.expectEqualStrings("A", decoded);
}

test "decodePdf rejects physical EOF before PDF EOD" {
	try std.testing.expectError(
		error.IncompleteSource,
		decodePdf(std.testing.allocator, &.{ 0x20, 0x80 }, 1024),
	);
}

test "decodePdf enforces its caller-owned output cap" {
	// 9-bit codes: 65 ('A'), 66 ('B'), 67 ('C'), EOD (257), MSB-first.
	try std.testing.expectError(
		error.OutputTooLarge,
		decodePdf(std.testing.allocator, &.{ 0x20, 0x90, 0x88, 0x70, 0x10 }, 2),
	);
}
