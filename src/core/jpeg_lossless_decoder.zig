//! JPEG Lossless Decoder (ITU-T T.81 SOF3) - Pure Zig Implementation
//!
//! This module provides a cleanroom decoder for lossless JPEG images (SOF marker 0xC3).
//! Used primarily for DICOM medical imaging with transfer syntaxes:
//! - 1.2.840.10008.1.2.4.57 (JPEG Lossless, Non-Hierarchical)
//! - 1.2.840.10008.1.2.4.70 (JPEG Lossless, Non-Hierarchical, First-Order Prediction)
//!
//! Unlike lossy JPEG (which uses DCT), lossless JPEG uses:
//! - Predictive coding (7 prediction modes)
//! - Huffman entropy coding
//! - Support for 1-16 bit precision
//!
//! Reference: ITU-T T.81 (09/92) - https://www.w3.org/Graphics/JPEG/itu-t81.pdf
//! Implementation based on public specification, cleanroom design.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errmsg = @import("error_messages.zig");

// ============ JPEG Markers ============

pub const Marker = struct {
	pub const SOI: u16 = 0xFFD8; // Start of Image
	pub const EOI: u16 = 0xFFD9; // End of Image
	pub const SOF3: u8 = 0xC3; // Start of Frame - Lossless (sequential)
	pub const SOF7: u8 = 0xC7; // Differential lossless (sequential)
	pub const SOF11: u8 = 0xCB; // Lossless (arithmetic)
	pub const SOF15: u8 = 0xCF; // Differential lossless (arithmetic)
	pub const DHT: u8 = 0xC4; // Define Huffman Table
	pub const SOS: u8 = 0xDA; // Start of Scan
	pub const DRI: u8 = 0xDD; // Define Restart Interval
	pub const RST0: u8 = 0xD0; // Restart markers 0-7
	pub const RST7: u8 = 0xD7;
	pub const APP0: u8 = 0xE0; // Application markers
	pub const APP15: u8 = 0xEF;
	pub const COM: u8 = 0xFE; // Comment
};

// ============ Error Types ============

pub const JpegLosslessError = error{
	InvalidSignature,
	UnexpectedEndOfData,
	InvalidMarker,
	InvalidHuffmanTable,
	InvalidFrameHeader,
	InvalidScanHeader,
	UnsupportedPrecision,
	UnsupportedFrameCount,
	UnsupportedMarker,
	HuffmanDecodeError,
	OutOfMemory,
	DataCorruption,
};

// ============ Huffman Table ============

/// Maximum Huffman code length (ITU-T T.81 limits to 16)
const MAX_HUFFMAN_CODE_LEN = 16;

/// Huffman table for one component
pub const HuffmanTable = struct {
	/// Number of codes for each length (1-16)
	code_counts: [MAX_HUFFMAN_CODE_LEN]u8,
	/// Starting index for codes of each length
	code_start: [MAX_HUFFMAN_CODE_LEN + 1]u16,
	/// Huffman codes sorted by length
	codes: [256]u16,
	/// Values (SSSS) for each code
	values: [256]u8,
	/// Total number of codes
	total_codes: u16,
	/// Maximum code length used
	max_code_len: u8,
	/// Fast lookup table (8-bit)
	lookup: [256]u8, // Value for 8-bit prefix, or 0xFF if not found
	lookup_len: [256]u8, // Code length for 8-bit prefix

	pub fn init() HuffmanTable {
		return HuffmanTable{
			.code_counts = [_]u8{0} ** MAX_HUFFMAN_CODE_LEN,
			.code_start = [_]u16{0} ** (MAX_HUFFMAN_CODE_LEN + 1),
			.codes = [_]u16{0} ** 256,
			.values = [_]u8{0} ** 256,
			.total_codes = 0,
			.max_code_len = 0,
			.lookup = [_]u8{0xFF} ** 256,
			.lookup_len = [_]u8{0} ** 256,
		};
	}

	/// Build Huffman codes from the length/value specification
	pub fn buildFromSpec(counts: []const u8, vals: []const u8) JpegLosslessError!HuffmanTable {
		var table = HuffmanTable.init();

		if (counts.len != MAX_HUFFMAN_CODE_LEN) {
			return JpegLosslessError.InvalidHuffmanTable;
		}

		// Copy counts and compute total
		var total: u16 = 0;
		for (counts, 0..) |c, i| {
			table.code_counts[i] = c;
			total += c;
			if (c > 0) {
				table.max_code_len = @intCast(i + 1);
			}
		}
		table.total_codes = total;

		if (total > 256 or vals.len < total) {
			return JpegLosslessError.InvalidHuffmanTable;
		}

		// Generate Huffman codes (ITU-T T.81 Figure C.1)
		var code: u16 = 0;
		var k: u16 = 0;

		for (0..MAX_HUFFMAN_CODE_LEN) |len_idx| {
			table.code_start[len_idx] = k;

			for (0..table.code_counts[len_idx]) |_| {
				table.codes[k] = code;
				table.values[k] = vals[k];
				k += 1;
				code += 1;
			}

			code <<= 1; // Left shift for next length
		}
		table.code_start[MAX_HUFFMAN_CODE_LEN] = k;

		// Build 8-bit fast lookup table
		for (0..MAX_HUFFMAN_CODE_LEN) |len_idx| {
			if (len_idx >= 8) break; // Only build lookup for codes <= 8 bits
			const len: u4 = @intCast(len_idx + 1);

			const start = table.code_start[len_idx];
			const end = table.code_start[len_idx + 1];

			for (start..end) |code_idx| {
				const huff_code = table.codes[code_idx];
				const value = table.values[code_idx];

				// Generate all 8-bit patterns that start with this code
				// shift is 0-7 (since len is 1-8), fits in u4 for u16 shift
				const shift: u4 = @intCast(8 - len);
				const base: u8 = @intCast(huff_code << shift);
				const count: u16 = @as(u16, 1) << shift;

				for (0..count) |offset| {
					const idx = base + @as(u8, @intCast(offset));
					table.lookup[idx] = value;
					table.lookup_len[idx] = len;
				}
			}
		}

		return table;
	}
};

// ============ Bit Reader ============

/// Bit-level reader for entropy-coded data
pub const BitReader = struct {
	data: []const u8,
	pos: usize,
	bit_pos: u3, // 0-7, bits remaining in current byte

	pub fn init(data: []const u8) BitReader {
		return BitReader{
			.data = data,
			.pos = 0,
			.bit_pos = 0,
		};
	}

	/// Read a single bit
	pub fn readBit(self: *BitReader) JpegLosslessError!u1 {
		if (self.pos >= self.data.len) {
			return JpegLosslessError.UnexpectedEndOfData;
		}

		const bit: u1 = @intCast((self.data[self.pos] >> (7 - @as(u3, self.bit_pos))) & 1);
		self.bit_pos +%= 1;
		if (self.bit_pos == 0) {
			self.pos += 1;
		}

		return bit;
	}

	/// Read multiple bits (up to 16)
	pub fn readBits(self: *BitReader, count: u5) JpegLosslessError!u16 {
		if (count == 0) return 0;

		var result: u16 = 0;
		for (0..count) |_| {
			result = (result << 1) | @as(u16, try self.readBit());
		}
		return result;
	}

	/// Peek at next 16 bits without advancing (for fast Huffman lookup)
	pub fn peek16(self: *const BitReader) u16 {
		var result: u24 = 0;

		// Read up to 3 bytes to get 16+ bits
		for (0..3) |i| {
			if (self.pos + i < self.data.len) {
				result = (result << 8) | self.data[self.pos + i];
			}
		}

		// Shift to get the 16 bits starting at bit_pos
		// Cast bit_pos to u8 first since 8-0=8 doesn't fit in u3
		const shift: u5 = @intCast(8 - @as(u8, self.bit_pos));
		return @truncate(result >> shift);
	}

	/// Advance by n bits
	pub fn advance(self: *BitReader, n: u5) void {
		const total_bits = @as(usize, self.bit_pos) + n;
		self.pos += total_bits / 8;
		self.bit_pos = @intCast(total_bits % 8);
	}

	/// Check if more data available
	pub fn hasMore(self: *const BitReader) bool {
		return self.pos < self.data.len or self.bit_pos > 0;
	}
};

// ============ Frame Info ============

/// JPEG frame information from SOF marker
pub const FrameInfo = struct {
	precision: u8, // Sample precision (1-16 bits)
	height: u16,
	width: u16,
	num_components: u8, // 1 for grayscale, 3 for RGB
};

/// Scan information from SOS marker
pub const ScanInfo = struct {
	num_components: u8,
	predictor: u8, // Selection value (1-7)
	point_transform: u8, // Point transform (usually 0)
};

// ============ Validation Result ============

pub const ValidationResult = struct {
	valid: bool,
	frame_info: ?FrameInfo,
	error_message: ?[]const u8,

	pub fn ok(info: FrameInfo) ValidationResult {
		return .{ .valid = true, .frame_info = info, .error_message = null };
	}

	pub fn invalid(msg: []const u8) ValidationResult {
		return .{ .valid = false, .frame_info = null, .error_message = msg };
	}
};

// ============ Decoder ============

/// Decode SSSS and pixel difference from Huffman-coded stream
fn decodePixelDifference(reader: *BitReader, table: *const HuffmanTable) JpegLosslessError!i32 {
	// Fast path: try 8-bit lookup
	const peek8: u8 = @truncate(reader.peek16() >> 8);
	var ssss: u8 = table.lookup[peek8];

	if (ssss != 0xFF) {
		// Found in lookup table (lookup_len stores values 1-8, fits in u5)
		reader.advance(@intCast(table.lookup_len[peek8]));
	} else {
		// Slow path: decode bit by bit
		var code: u16 = 0;
		var len: u5 = 0;

		while (len < table.max_code_len) {
			code = (code << 1) | @as(u16, try reader.readBit());
			len += 1;

			// Check if this code exists at this length
			const start = table.code_start[len - 1];
			const end = table.code_start[len];

			for (start..end) |idx| {
				if (table.codes[idx] == code) {
					ssss = table.values[idx];
					break;
				}
			}
			if (ssss != 0xFF) break;
		}

		if (ssss == 0xFF) {
			return JpegLosslessError.HuffmanDecodeError;
		}
	}

	// Decode the difference value based on SSSS
	if (ssss == 0) return 0; // No difference

	if (ssss == 16) {
		// Special case: 16-bit difference = 32768
		return 32768;
	}

	// SSSS must be 1-15 at this point (valid for lossless JPEG)
	if (ssss > 16) return JpegLosslessError.HuffmanDecodeError;

	// Read SSSS additional bits (ssss is 1-15, fits in u5)
	const ssss_u5: u5 = @intCast(ssss);
	const extra_bits = try reader.readBits(ssss_u5);

	// Convert to signed difference (ITU-T T.81 Section H.1.2.2)
	// ssss is at least 1 here, so ssss-1 is at least 0
	const shift_for_half: u4 = @intCast(ssss - 1);
	const half: u16 = @as(u16, 1) << shift_for_half;
	if (extra_bits < half) {
		// Negative: extra_bits - (2^ssss - 1)
		const mask: i32 = (@as(i32, 1) << ssss_u5) - 1;
		return @as(i32, extra_bits) - mask;
	} else {
		return @as(i32, extra_bits);
	}
}

/// Remove byte stuffing (FF 00 -> FF) from entropy-coded data
fn removeByteStuffing(allocator: Allocator, data: []const u8) ![]u8 {
	// First pass: count output size
	var output_size: usize = 0;
	var i: usize = 0;
	while (i < data.len) {
		if (data[i] == 0xFF and i + 1 < data.len) {
			if (data[i + 1] == 0x00) {
				// Stuffed byte: output single FF
				output_size += 1;
				i += 2;
				continue;
			} else if (data[i + 1] == 0xD9) {
				// EOI marker: stop
				break;
			}
		}
		output_size += 1;
		i += 1;
	}

	// Second pass: copy data
	const output = try allocator.alloc(u8, output_size);
	var j: usize = 0;
	i = 0;
	while (i < data.len and j < output_size) {
		if (data[i] == 0xFF and i + 1 < data.len) {
			if (data[i + 1] == 0x00) {
				output[j] = 0xFF;
				j += 1;
				i += 2;
				continue;
			} else if (data[i + 1] == 0xD9) {
				break;
			}
		}
		output[j] = data[i];
		j += 1;
		i += 1;
	}

	return output;
}

/// Validate a lossless JPEG buffer (SOF3/SOF7/SOF11/SOF15)
/// For validation, we parse the structure and decode a portion of the image.
pub fn validateLosslessJpeg(allocator: Allocator, data: []const u8) ValidationResult {
	// Minimum size: SOI (2) + SOF (11+) + DHT (19+) + SOS (8+) + EOI (2) = ~42 bytes
	if (data.len < 20) {
		return ValidationResult.invalid("Data too small for JPEG");
	}

	// Check SOI marker
	if (data[0] != 0xFF or data[1] != 0xD8) {
		return ValidationResult.invalid(errmsg.missing("SOI marker (0xFFD8)"));
	}

	var pos: usize = 2;
	var frame_info: ?FrameInfo = null;
	var scan_info: ?ScanInfo = null;
	var huffman_tables: [4]?HuffmanTable = [_]?HuffmanTable{null} ** 4;
	var entropy_start: usize = 0;

	// Parse markers
	while (pos + 2 <= data.len) {
		// Find marker
		if (data[pos] != 0xFF) {
			return ValidationResult.invalid("Expected marker (0xFF)");
		}

		// Skip padding FFs
		while (pos + 1 < data.len and data[pos + 1] == 0xFF) {
			pos += 1;
		}

		if (pos + 2 > data.len) break;

		const marker = data[pos + 1];
		pos += 2;

		// Handle markers without length (RST, EOI)
		if (marker == 0xD9) {
			// EOI - end of image
			break;
		}
		if (marker >= 0xD0 and marker <= 0xD7) {
			// RST markers - no length
			continue;
		}
		if (marker == 0x01 or marker == 0xFF) {
			// TEM or padding
			continue;
		}

		// Read marker length
		if (pos + 2 > data.len) {
			return ValidationResult.invalid(errmsg.truncated("marker length"));
		}
		const length = (@as(u16, data[pos]) << 8) | data[pos + 1];
		if (length < 2 or pos + length > data.len) {
			return ValidationResult.invalid("Invalid marker length");
		}

		const segment_data = data[pos + 2 .. pos + length];
		const segment_end = pos + length;

		// Process marker
		switch (marker) {
			Marker.SOF3, Marker.SOF7 => {
				// Lossless frame (Huffman coding)
				if (segment_data.len < 6) {
					return ValidationResult.invalid("SOF segment too small");
				}
				frame_info = FrameInfo{
					.precision = segment_data[0],
					.height = (@as(u16, segment_data[1]) << 8) | segment_data[2],
					.width = (@as(u16, segment_data[3]) << 8) | segment_data[4],
					.num_components = segment_data[5],
				};

				// Validate precision (1-16 for lossless)
				if (frame_info.?.precision < 1 or frame_info.?.precision > 16) {
					return ValidationResult.invalid("Invalid precision (must be 1-16)");
				}

				// Validate dimensions
				if (frame_info.?.width == 0 or frame_info.?.height == 0) {
					return ValidationResult.invalid("Invalid dimensions");
				}

				// Validate component count
				if (frame_info.?.num_components == 0 or frame_info.?.num_components == 2 or frame_info.?.num_components > 4) {
					return ValidationResult.invalid("Invalid component count");
				}
			},
			Marker.SOF11, Marker.SOF15 => {
				// Arithmetic coding - not supported yet
				return ValidationResult.invalid("Arithmetic coding not supported");
			},
			Marker.DHT => {
				// Define Huffman Table
				var dht_pos: usize = 0;
				while (dht_pos + 17 <= segment_data.len) {
					const table_spec = segment_data[dht_pos];
					const table_class = (table_spec >> 4) & 0x0F; // 0 = DC, 1 = AC
					const table_id = table_spec & 0x0F;

					if (table_class > 1 or table_id > 3) {
						return ValidationResult.invalid("Invalid Huffman table specification");
					}

					// Read 16 length counts
					const counts = segment_data[dht_pos + 1 .. dht_pos + 17];

					// Count total values
					var total_values: usize = 0;
					for (counts) |c| {
						total_values += c;
					}

					if (dht_pos + 17 + total_values > segment_data.len) {
						return ValidationResult.invalid(errmsg.truncated("Huffman table"));
					}

					const values = segment_data[dht_pos + 17 .. dht_pos + 17 + total_values];

					// Build Huffman table
					const table = HuffmanTable.buildFromSpec(counts, values) catch {
						return ValidationResult.invalid("Invalid Huffman table");
					};

					// Store table (use table_id for simplicity)
					huffman_tables[table_id] = table;

					dht_pos += 17 + total_values;
				}
			},
			Marker.SOS => {
				// Start of Scan
				if (segment_data.len < 4) {
					return ValidationResult.invalid("SOS segment too small");
				}

				const num_components = segment_data[0];
				const header_size = 1 + num_components * 2 + 3;

				if (segment_data.len < header_size) {
					return ValidationResult.invalid("SOS segment too small");
				}

				scan_info = ScanInfo{
					.num_components = num_components,
					.predictor = segment_data[header_size - 3],
					.point_transform = segment_data[header_size - 1] & 0x0F,
				};

				// Entropy-coded data follows
				entropy_start = segment_end;
			},
			Marker.DRI => {
				// Restart interval - supported but not commonly used in DICOM
			},
			else => {
				// APP markers, COM, etc. - skip
			},
		}

		pos = segment_end;

		// If we have SOS, entropy data follows
		if (scan_info != null) break;
	}

	// Validate we have required info
	if (frame_info == null) {
		return ValidationResult.invalid(errmsg.missing("SOF marker"));
	}
	if (scan_info == null) {
		return ValidationResult.invalid(errmsg.missing("SOS marker"));
	}

	// Check we have at least one Huffman table
	var has_table = false;
	for (huffman_tables) |t| {
		if (t != null) {
			has_table = true;
			break;
		}
	}
	if (!has_table) {
		return ValidationResult.invalid(errmsg.missing("Huffman table"));
	}

	// Validate by decoding some pixels
	if (entropy_start > 0 and entropy_start < data.len) {
		const entropy_data = data[entropy_start..];

		// Remove byte stuffing
		const clean_data = removeByteStuffing(allocator, entropy_data) catch {
			return ValidationResult.invalid("Memory allocation failed");
		};
		defer allocator.free(clean_data);

		if (clean_data.len < 4) {
			return ValidationResult.invalid("Entropy data too small");
		}

		// Get first available Huffman table
		var table: *const HuffmanTable = undefined;
		for (&huffman_tables) |*t| {
			if (t.* != null) {
				table = &(t.*.?);
				break;
			}
		}

		// Try to decode a few pixels to verify integrity
		var reader = BitReader.init(clean_data);
		const fi = frame_info.?;
		const pixels_to_decode = @min(fi.width * 10, 1000); // Decode up to 10 rows or 1000 pixels

		for (0..pixels_to_decode) |_| {
			_ = decodePixelDifference(&reader, table) catch {
				return ValidationResult.invalid("Huffman decode error");
			};

			if (!reader.hasMore()) break;
		}
	}

	return ValidationResult.ok(frame_info.?);
}

/// Check if data is a lossless JPEG (SOF3/SOF7/SOF11/SOF15)
pub fn isLosslessJpeg(data: []const u8) bool {
	if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) {
		return false;
	}

	// Scan for SOF marker
	var pos: usize = 2;
	while (pos + 4 < data.len) {
		if (data[pos] == 0xFF) {
			const marker = data[pos + 1];
			// SOF3, SOF7, SOF11, SOF15 are lossless
			if (marker == 0xC3 or marker == 0xC7 or marker == 0xCB or marker == 0xCF) {
				return true;
			}
			// SOF0, SOF1, SOF2 are lossy baseline/progressive
			if (marker == 0xC0 or marker == 0xC1 or marker == 0xC2) {
				return false;
			}
			// Skip segment
			if (marker != 0x00 and marker != 0xFF and marker != 0xD8 and marker != 0xD9 and
				!(marker >= 0xD0 and marker <= 0xD7))
			{
				if (pos + 4 <= data.len) {
					const len = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
					pos += 2 + len;
					continue;
				}
			}
		}
		pos += 1;
	}

	return false;
}

// ============ Tests ============

test "HuffmanTable.buildFromSpec basic" {
	// Simple table: code 0 = value 0, code 10 = value 1, code 11 = value 2
	const counts = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
	const values = [_]u8{ 0, 1, 2 };

	const table = try HuffmanTable.buildFromSpec(&counts, &values);

	try std.testing.expectEqual(@as(u16, 3), table.total_codes);
	try std.testing.expectEqual(@as(u8, 2), table.max_code_len);
}

test "BitReader basic" {
	const data = [_]u8{ 0b10110100, 0b11001010 };
	var reader = BitReader.init(&data);

	// Read individual bits
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
	try std.testing.expectEqual(@as(u1, 1), try reader.readBit());

	// Read multiple bits
	try std.testing.expectEqual(@as(u16, 0b0100), try reader.readBits(4));
}

test "isLosslessJpeg detection" {
	// SOF3 marker in a minimal JPEG structure
	const lossless_data = [_]u8{
		0xFF, 0xD8, // SOI
		0xFF, 0xC3, // SOF3 (lossless)
		0x00, 0x0B, // Length
		0x08, // Precision
		0x00, 0x10, // Height
		0x00, 0x10, // Width
		0x01, // Components
		0x01, 0x11, 0x00, // Component spec
	};

	try std.testing.expect(isLosslessJpeg(&lossless_data));

	// SOF0 (baseline) should return false
	const baseline_data = [_]u8{
		0xFF, 0xD8, // SOI
		0xFF, 0xC0, // SOF0 (baseline)
		0x00, 0x0B,
		0x08,
		0x00, 0x10,
		0x00, 0x10,
		0x01,
		0x01, 0x11, 0x00,
	};

	try std.testing.expect(!isLosslessJpeg(&baseline_data));
}
