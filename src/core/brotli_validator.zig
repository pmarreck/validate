//! Deep Brotli validation using libbrotli.
//!
//! This module provides Brotli decompression validation by actually decoding
//! the compressed data and detecting any errors in the bitstream.
//!
//! Uses Google's Brotli reference decoder which validates:
//! - Brotli stream format integrity
//! - Huffman code validity
//! - Dictionary reference correctness
//! - Block type consistency
//! - Distance code validity
//!
//! ## Note on Detection
//! Brotli files (.br) have NO magic number. Detection must be done
//! via file extension. The format is self-delimiting but the header
//! uses variable-length encoding that cannot be reliably distinguished
//! from random data without attempting full decompression.

const std = @import("std");
const errmsg = @import("error_messages.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

const c = @cImport({
	@cInclude("brotli/decode.h");
});

/// Result of deep Brotli validation
pub const BrotliValidationResult = struct {
	valid: bool,
	error_message: ?[]const u8,
	decompressed_size: ?usize,

	pub fn ok(size: usize) BrotliValidationResult {
		return .{ .valid = true, .error_message = null, .decompressed_size = size };
	}

	pub fn invalid(message: []const u8) BrotliValidationResult {
		return .{ .valid = false, .error_message = message, .decompressed_size = null };
	}
};

/// Maximum decompressed size we'll attempt (1GB).
/// Brotli can have extreme compression ratios with crafted data.
const MAX_DECOMPRESSED_SIZE: usize = 1024 * 1024 * 1024;

/// Initial output buffer size (1MB).
const INITIAL_OUTPUT_SIZE: usize = 1024 * 1024;

/// Validate a Brotli file by attempting full decompression.
/// Returns validation result with error details if invalid.
pub fn validateBrotliDeep(source: *FileSource) BrotliValidationResult {
	// Get file size
	const file_size = source.getEndPos() catch {
		return BrotliValidationResult.invalid(errmsg.failedToGet("file size"));
	};

	// Limit to reasonable size (100MB compressed - brotli can be highly compressive)
	if (file_size > 100 * 1024 * 1024) {
		return BrotliValidationResult.invalid(errmsg.fileTooLargeFor("deep validation"));
	}

	if (file_size == 0) {
		return BrotliValidationResult.invalid("File is empty");
	}

	// Allocate buffer using C allocator for consistency with C library
	const buffer = std.c.malloc(file_size) orelse {
		return BrotliValidationResult.invalid("Memory allocation failed");
	};
	defer std.c.free(buffer);

	// Read entire file
	const buf_slice: []u8 = @as([*]u8, @ptrCast(buffer))[0..file_size];
	const bytes_read = source.readAll(buf_slice) catch {
		return BrotliValidationResult.invalid(errmsg.failedToRead("file"));
	};
	if (bytes_read != file_size) {
		return BrotliValidationResult.invalid(errmsg.incomplete("file read"));
	}

	return validateBrotliDeepFromBuffer(buf_slice);
}

/// Validate Brotli from memory buffer using streaming decoder.
/// This handles unknown output sizes by using BrotliDecoderDecompressStream.
pub fn validateBrotliDeepFromBuffer(data: []const u8) BrotliValidationResult {
	if (data.len == 0) {
		return BrotliValidationResult.invalid(errmsg.empty("input"));
	}

	// Create streaming decoder
	const state = c.BrotliDecoderCreateInstance(null, null, null);
	if (state == null) {
		return BrotliValidationResult.invalid("Failed to create decoder");
	}
	defer c.BrotliDecoderDestroyInstance(state);

	// Set up input
	var available_in: usize = data.len;
	var next_in: [*c]const u8 = data.ptr;

	// Allocate output buffer
	const output_buffer = std.c.malloc(INITIAL_OUTPUT_SIZE) orelse {
		return BrotliValidationResult.invalid("Memory allocation failed");
	};
	defer std.c.free(output_buffer);

	var total_out: usize = 0;
	const output_size: usize = INITIAL_OUTPUT_SIZE;

	// Decompress using streaming API
	while (true) {
		var available_out: usize = output_size;
		var next_out: [*c]u8 = @ptrCast(output_buffer);

		const result = c.BrotliDecoderDecompressStream(
			state,
			&available_in,
			&next_in,
			&available_out,
			&next_out,
			&total_out,
		);

		switch (result) {
			c.BROTLI_DECODER_RESULT_SUCCESS => {
				// Successfully decompressed
				return BrotliValidationResult.ok(total_out);
			},
			c.BROTLI_DECODER_RESULT_ERROR => {
				// Get specific error code
				const error_code = c.BrotliDecoderGetErrorCode(state);
				return BrotliValidationResult.invalid(getErrorMessage(error_code));
			},
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT => {
				return BrotliValidationResult.invalid(errmsg.truncated("Brotli stream"));
			},
			c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT => {
				// Check if we're exceeding size limit
				if (total_out >= MAX_DECOMPRESSED_SIZE) {
					return BrotliValidationResult.invalid("Decompressed size exceeds limit");
				}

				// For validation, we don't need to store the output - just
				// reset the buffer pointers and continue decompressing
				// (effectively discarding the output but still validating)
			},
			else => {
				return BrotliValidationResult.invalid(errmsg.unknown("decoder result"));
			},
		}
	}
}

/// Convert Brotli error code to human-readable message
fn getErrorMessage(error_code: c.BrotliDecoderErrorCode) []const u8 {
	return switch (error_code) {
		c.BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_NIBBLE => "Format error: exuberant nibble",
		c.BROTLI_DECODER_ERROR_FORMAT_RESERVED => "Format error: reserved bits set",
		c.BROTLI_DECODER_ERROR_FORMAT_EXUBERANT_META_NIBBLE => "Format error: exuberant meta-nibble",
		c.BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET => "Format error: invalid simple Huffman alphabet",
		c.BROTLI_DECODER_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME => "Format error: invalid simple Huffman code (same symbol)",
		c.BROTLI_DECODER_ERROR_FORMAT_CL_SPACE => "Format error: code length space overflow",
		c.BROTLI_DECODER_ERROR_FORMAT_HUFFMAN_SPACE => "Format error: Huffman space overflow",
		c.BROTLI_DECODER_ERROR_FORMAT_CONTEXT_MAP_REPEAT => "Format error: context map repeat overflow",
		c.BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_1 => "Format error: invalid block length [1]",
		c.BROTLI_DECODER_ERROR_FORMAT_BLOCK_LENGTH_2 => "Format error: invalid block length [2]",
		c.BROTLI_DECODER_ERROR_FORMAT_TRANSFORM => "Format error: invalid transform",
		c.BROTLI_DECODER_ERROR_FORMAT_DICTIONARY => "Format error: invalid dictionary reference",
		c.BROTLI_DECODER_ERROR_FORMAT_WINDOW_BITS => "Format error: invalid window bits",
		c.BROTLI_DECODER_ERROR_FORMAT_PADDING_1 => "Format error: invalid padding [1]",
		c.BROTLI_DECODER_ERROR_FORMAT_PADDING_2 => "Format error: invalid padding [2]",
		c.BROTLI_DECODER_ERROR_FORMAT_DISTANCE => "Format error: invalid distance code",
		c.BROTLI_DECODER_ERROR_DICTIONARY_NOT_SET => "Dictionary not set",
		c.BROTLI_DECODER_ERROR_INVALID_ARGUMENTS => "Invalid arguments",
		c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES => "Memory allocation failed: context modes",
		c.BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS => "Memory allocation failed: tree groups",
		c.BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP => "Memory allocation failed: context map",
		c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1 => "Memory allocation failed: ring buffer [1]",
		c.BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2 => "Memory allocation failed: ring buffer [2]",
		c.BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES => "Memory allocation failed: block type trees",
		c.BROTLI_DECODER_ERROR_UNREACHABLE => "Unreachable code",
		else => errmsg.unknown("Brotli error"),
	};
}

// Tests
test "reject empty input" {
	const result = validateBrotliDeepFromBuffer(&[_]u8{});
	try std.testing.expect(!result.valid);
	try std.testing.expectEqualStrings("Empty input", result.error_message.?);
}

test "reject invalid data" {
	// Random bytes that are not valid Brotli
	const invalid = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
	const result = validateBrotliDeepFromBuffer(&invalid);
	try std.testing.expect(!result.valid);
	// Should get some error - format or truncation
	try std.testing.expect(result.error_message != null);
}

test "validate minimal Brotli stream" {
	// Minimal valid Brotli stream encoding empty string
	// WBITS=10 (00), ISLAST=1, ISEMPTY=1, followed by padding
	// This is: 0x06 (empty last block with window bits 10)
	const empty_brotli = [_]u8{0x06};
	const result = validateBrotliDeepFromBuffer(&empty_brotli);
	try std.testing.expect(result.valid);
	try std.testing.expectEqual(@as(usize, 0), result.decompressed_size.?);
}

test "validate simple Brotli stream" {
	// Pre-compressed "Hello" using brotli at quality 0
	// Generated with brotli -q 0 and recorded as byte literals.
	const hello_brotli = [_]u8{
		0x0b, 0x02, 0x80, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x03,
	};
	const result = validateBrotliDeepFromBuffer(&hello_brotli);
	try std.testing.expect(result.valid);
	try std.testing.expectEqual(@as(usize, 5), result.decompressed_size.?);
}

test "reject truncated stream" {
	// Start of a valid Brotli stream but truncated
	const truncated = [_]u8{ 0x0b, 0x02, 0x80, 0x48 };
	const result = validateBrotliDeepFromBuffer(&truncated);
	try std.testing.expect(!result.valid);
}
