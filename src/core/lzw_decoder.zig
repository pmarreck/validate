//! PDF LZWDecode filter decoder.
//!
//! Decodes LZW-compressed data as specified in PDF Reference.
//! PDF uses a specific LZW variant with:
//! - Initial code size: 9 bits
//! - Clear table code: 256
//! - End of data code: 257
//! - First data code: 258
//! - Variable code width: 9 to 12 bits
//! - Early change: code width increases when table size reaches 2^n - 1
//!
//! Reference: PDF 1.7 specification, Section 7.4.4.2

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LzwDecodeError = error{
	InvalidCode,
	TableOverflow,
	UnexpectedEndOfData,
	OutOfMemory,
};

const CLEAR_TABLE: u16 = 256;
const EOD: u16 = 257;
const FIRST_CODE: u16 = 258;
const MAX_CODE: u16 = 4095; // 12-bit max
const MAX_TABLE_SIZE: usize = 4096;

/// Dictionary entry - stores string as reference to previous entry + new byte
const DictEntry = struct {
	prefix: ?u16, // Index of prefix entry, null for single-byte entries
	suffix: u8, // Last byte of this entry
	length: u16, // Total length of string this entry represents
};

/// Bit reader for variable-width codes
const BitReader = struct {
	data: []const u8,
	byte_pos: usize,
	bit_pos: u3, // 0-7, bits remaining in current byte

	fn init(data: []const u8) BitReader {
		return .{
			.data = data,
			.byte_pos = 0,
			.bit_pos = 0,
		};
	}

	/// Read n bits (9-12) as a code
	fn readCode(self: *BitReader, bits: u4) ?u16 {
		var result: u16 = 0;
		var bits_needed: u4 = bits;

		while (bits_needed > 0) {
			if (self.byte_pos >= self.data.len) {
				return null;
			}

			const current_byte = self.data[self.byte_pos];
			const bits_in_byte: u4 = @intCast(8 - @as(u4, self.bit_pos));
			const bits_to_take: u4 = @min(bits_in_byte, bits_needed);

			// Extract bits from current byte (MSB first)
			const shift: u3 = @intCast(bits_in_byte - bits_to_take);
			const mask: u8 = @as(u8, @intCast((@as(u16, 1) << bits_to_take) - 1)) << shift;
			const extracted: u8 = (current_byte & mask) >> shift;

			result = (result << bits_to_take) | extracted;
			bits_needed -= bits_to_take;

			const new_bit_pos = @as(u4, self.bit_pos) + bits_to_take;
			if (new_bit_pos >= 8) {
				self.byte_pos += 1;
				self.bit_pos = 0;
			} else {
				self.bit_pos = @intCast(new_bit_pos);
			}
		}

		return result;
	}
};

/// Decode LZW-compressed data.
/// Returns allocated buffer that caller must free.
pub fn decode(allocator: Allocator, input: []const u8) LzwDecodeError![]u8 {
	var result: std.ArrayListUnmanaged(u8) = .{};
	errdefer result.deinit(allocator);

	// Initialize dictionary with single-byte entries (0-255)
	var dict: [MAX_TABLE_SIZE]DictEntry = undefined;
	for (0..256) |i| {
		dict[i] = .{
			.prefix = null,
			.suffix = @intCast(i),
			.length = 1,
		};
	}
	// Codes 256 (clear) and 257 (EOD) are reserved but not used as entries
	var next_code: u16 = FIRST_CODE;
	var code_bits: u4 = 9;

	var reader = BitReader.init(input);
	var prev_code: ?u16 = null;

	while (true) {
		const code = reader.readCode(code_bits) orelse break;

		if (code == EOD) {
			break;
		}

		if (code == CLEAR_TABLE) {
			// Reset dictionary
			next_code = FIRST_CODE;
			code_bits = 9;
			prev_code = null;
			continue;
		}

		// Decode the current code
		if (code < next_code) {
			// Code exists in dictionary - output it
			try outputString(allocator, &result, &dict, code);

			// Add new entry: previous string + first byte of current string
			if (prev_code) |pc| {
				if (next_code <= MAX_CODE) {
					const first_byte = getFirstByte(&dict, code);
					dict[next_code] = .{
						.prefix = pc,
						.suffix = first_byte,
						.length = dict[pc].length + 1,
					};
					next_code += 1;

					// Early change: increase bits when we're about to need them
					if (next_code == (@as(u16, 1) << code_bits) - 1 and code_bits < 12) {
						code_bits += 1;
					}
				}
			}
		} else if (code == next_code) {
			// Special case: code not yet in dictionary
			// String is: previous string + first byte of previous string
			if (prev_code) |pc| {
				const first_byte = getFirstByte(&dict, pc);
				try outputString(allocator, &result, &dict, pc);
				result.append(allocator, first_byte) catch return LzwDecodeError.OutOfMemory;

				if (next_code <= MAX_CODE) {
					dict[next_code] = .{
						.prefix = pc,
						.suffix = first_byte,
						.length = dict[pc].length + 1,
					};
					next_code += 1;

					if (next_code == (@as(u16, 1) << code_bits) - 1 and code_bits < 12) {
						code_bits += 1;
					}
				}
			} else {
				return LzwDecodeError.InvalidCode;
			}
		} else {
			return LzwDecodeError.InvalidCode;
		}

		prev_code = code;
	}

	return result.toOwnedSlice(allocator) catch return LzwDecodeError.OutOfMemory;
}

/// Output the string represented by a dictionary entry
fn outputString(allocator: Allocator, result: *std.ArrayListUnmanaged(u8), dict: []const DictEntry, code: u16) LzwDecodeError!void {
	const entry = dict[code];
	const len = entry.length;

	// Ensure capacity for the string
	result.ensureUnusedCapacity(allocator, len) catch return LzwDecodeError.OutOfMemory;

	// Build string by traversing prefix chain
	const start_pos = result.items.len;
	result.items.len += len;

	var pos: usize = start_pos + len;
	var current: u16 = code;
	while (true) {
		pos -= 1;
		result.items[pos] = dict[current].suffix;
		if (dict[current].prefix) |prefix| {
			current = prefix;
		} else {
			break;
		}
	}
}

/// Get the first byte of a dictionary entry's string
fn getFirstByte(dict: []const DictEntry, code: u16) u8 {
	var current = code;
	while (dict[current].prefix) |prefix| {
		current = prefix;
	}
	return dict[current].suffix;
}

// ============ Tests ============

// Helper to pack 9-bit codes into bytes (MSB first)
fn packCodes9(codes: []const u16) [32]u8 {
	var result: [32]u8 = .{0} ** 32;
	var bit_pos: usize = 0;

	for (codes) |code| {
		// Write 9 bits MSB first
		for (0..9) |i| {
			const bit: u1 = @intCast((code >> @intCast(8 - i)) & 1);
			const byte_idx = bit_pos / 8;
			const bit_in_byte: u3 = @intCast(7 - (bit_pos % 8));
			result[byte_idx] |= @as(u8, bit) << bit_in_byte;
			bit_pos += 1;
		}
	}

	return result;
}

test "bit reader reads 9-bit codes correctly" {
	// Pack codes 65, 257 into bytes
	const codes = [_]u16{ 65, 257 };
	const encoded = packCodes9(&codes);

	var reader = BitReader.init(encoded[0..3]);

	const code1 = reader.readCode(9);
	try std.testing.expectEqual(@as(?u16, 65), code1);

	const code2 = reader.readCode(9);
	try std.testing.expectEqual(@as(?u16, 257), code2);
}

test "decode single byte" {
	const allocator = std.testing.allocator;

	// Code 65 ('A') then EOD (257)
	const codes = [_]u16{ 65, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..3]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("A", result);
}

test "decode multiple literal bytes" {
	const allocator = std.testing.allocator;

	// Codes: 65 ('A'), 66 ('B'), 67 ('C'), EOD
	const codes = [_]u16{ 65, 66, 67, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..5]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("ABC", result);
}

test "decode with dictionary reference" {
	const allocator = std.testing.allocator;

	// Encode "ABAB":
	// Code 65 ('A') -> output A, prev=65
	// Code 66 ('B') -> output B, add 258="AB", prev=66
	// Code 258 (="AB") -> output AB, add 259="BA"
	// EOD
	const codes = [_]u16{ 65, 66, 258, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..5]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("ABAB", result);
}

test "decode special case: code equals next_code" {
	const allocator = std.testing.allocator;

	// Encode "ABBA":
	// A(65) -> output A
	// B(66) -> output B, add 258=AB
	// B(66) -> output B, add 259=BB
	// A(65) -> output A, add 260=BA
	// EOD
	const codes = [_]u16{ 65, 66, 66, 65, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..6]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("ABBA", result);
}

test "decode with clear code" {
	const allocator = std.testing.allocator;

	// Clear code (256) resets the dictionary
	// Codes: 65, CLEAR(256), 66, EOD(257)
	const codes = [_]u16{ 65, 256, 66, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..5]);
	defer allocator.free(result);

	try std.testing.expectEqualStrings("AB", result);
}

test "decode empty (just EOD)" {
	const allocator = std.testing.allocator;

	const codes = [_]u16{257};
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..2]);
	defer allocator.free(result);

	try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decode binary data" {
	const allocator = std.testing.allocator;

	// Codes: 0x00, 0xFF, EOD
	const codes = [_]u16{ 0x00, 0xFF, 257 };
	const encoded = packCodes9(&codes);

	const result = try decode(allocator, encoded[0..4]);
	defer allocator.free(result);

	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0xFF }, result);
}

// ============ EarlyChange=1 regression tests ============
//
// PDF's /LZWDecode filter defaults to EarlyChange=1 (PDF spec 7.4.4.3): the
// code-width bumps one code earlier than the canonical (TIFF) algorithm. The
// width bumps when next_code reaches 2^bits - 1 (511, 1023, 2047) — not
// 2^bits (512, 1024, 2048). A decoder that uses the canonical timing will be
// off-by-one in the bit stream after the very first width bump, corrupting
// the rest of the stream. Real-world example: 12 Sparkpost invoice PDFs in
// 2023 contain a 472x96 grayscale SMask image filtered with /LZWDecode that
// crosses all three width-bump boundaries; validate previously rejected them.

test "decode crosses 9->10 bit boundary with EarlyChange=1 (PDF default)" {
	const allocator = std.testing.allocator;

	// Build a stream that adds entries 258..510 (253 entries) so that the
	// addition of entry 510 causes next_code to reach 511. Under EarlyChange=1
	// (PDF default) the width bumps from 9 to 10 bits at next_code==511 — i.e.
	// the very next code MUST be read at 10 bits. With EarlyChange=0 the bump
	// would happen one code later, so the byte stream would be misread starting
	// at code 255 (different bit alignment), yielding wrong output.
	//
	//   code 1 (9 bits): literal 0  -> prev=0, no entry added (deferred-add)
	//   code 2 (9 bits): literal 1  -> add 258="01", prev=1
	//   code 3 (9 bits): literal 2  -> add 259="12", prev=2
	//   ...
	//   code 254 (9 bits): literal 253 -> add 510="...253", next_code=511
	//                                    -> bump to 10 bits
	//   code 255 (10 bits): literal 0xAB
	//   code 256 (10 bits): EOD (257)
	var codes_buf: [256]u16 = undefined;
	var i: u16 = 0;
	while (i < 254) : (i += 1) {
		codes_buf[i] = i; // literals 0..253
	}
	codes_buf[254] = 0xAB; // 10-bit code: literal 0xAB
	codes_buf[255] = 257; // EOD at 10 bits

	const total_bits: usize = 254 * 9 + 2 * 10;
	const total_bytes = (total_bits + 7) / 8;
	const encoded = try allocator.alloc(u8, total_bytes);
	defer allocator.free(encoded);
	@memset(encoded, 0);

	var bit_pos: usize = 0;
	for (codes_buf[0..254]) |code| {
		writeBitsMSB(encoded, &bit_pos, code, 9);
	}
	for (codes_buf[254..256]) |code| {
		writeBitsMSB(encoded, &bit_pos, code, 10);
	}

	const result = try decode(allocator, encoded);
	defer allocator.free(result);

	// Expected output: literals 0, 1, 2, ..., 253, 0xAB
	try std.testing.expectEqual(@as(usize, 255), result.len);
	for (0..254) |k| {
		try std.testing.expectEqual(@as(u8, @intCast(k)), result[k]);
	}
	try std.testing.expectEqual(@as(u8, 0xAB), result[254]);
}

test "decode real-world PDF LZW stream (Sparkpost SMask)" {
	const allocator = std.testing.allocator;

	// Real /LZWDecode stream pulled from sparkpost-invoice-INV00660896.pdf,
	// object 17 (a 472x96 grayscale /SMask image). 1,585 compressed bytes
	// expand to 472*96 = 45,312 bytes. The stream uses EarlyChange=1 (PDF
	// default) and crosses all three code-width bump boundaries (9->10->11->12
	// bits). qpdf is the oracle for the expected output's SHA-256.
	const raw_hex =
		"803f9fcff81412050383c260eff864361d0f87c2a25138a45613068b466351b8e4760b1e90486452" ++
		"3924964d0b93ca6552b9649a0d1884456213399cb62d309b4e639389d4f67d3f91cf28143a25025f" ++
		"179bcd2950ca2d0a8b3da753ea55396546a957ac46a8f289952e954dacd42c363b2476ad65b453e1" ++
		"b1fae452bd5fa259ed31eb95ceed6abbde6a75bb65badf35b8dea4b75c16165b84c3626414c98df6" ++
		"277fc050f118ac76532d55cbe66498c9855b2110b066a3393d169625a4d3666f98dc7e7e1da1d4e9" ++
		"f63b39ded36d0bd5e7b5d6bc0edf2bbedf6a3817adcd2777c2a0f0f91c3c372f9969e2d778fb0dbf" ++
		"3b9f79eb75eb304e8dfba7bde0f6babe2d2f775bdfc972bc9b4ecfaea5bccef1b77d4db7b7dd61fb" ++
		"7df43f1e97cfc0811fd00c0501c0902c0d03c1104c15039ff05c1d07c2108c2509c290ac2106c2d0" ++
		"cc350dc390ec150c43100c43031ff12c4d13c511443d05c4715c5d09c5b17c6519c6915c631ac711" ++
		"cc750141b104071bc7914c8514c767f48122c6723c9125c990f49526ca128c3f1147f04c872bc4d2" ++
		"2c9f294332dcb92fcc11e4c331cc32cc8d2ac112c4b12d4c9274db37cc92f4e139c5d1f4c534cd52" ++
		"1cd93a42d394f93fc6d4050524ca93bc193cc853dd070bd1746d09475210a47b42d2912511224773" ++
		"f51b4d5234ec194f54107ced4ac0b4bd311d53941d5350d4155d594052733d0d4b54d3355157d4b5" ++
		"c5752b5775ed475950f5ac4b455775757b5558f5d57f255855b473634f96859368da750d63335635" ++
		"2d9b694236e4e16f5ab36dc170c9b6bcd160d85625957258b7653d65cad6ddd55c5c7774b97aded3" ++
		"dc47665e54cd937c5f372e03475e13c59b79d5f806072461585d1f7dde383dfd63e1b8759f8b5058" ++
		"2dd15ae115662b8c4698fe410e6355a5d389d7d91d37954e992db58956f8a6596466738d87606719" ++
		"7e4f98e539acff9167d1852b7e6618be65a0e5ba44cb974096de8159dd7a55bfa94bf9be2183677a" ++
		"367baa4e3ae5efa1e23acc71a7c99b26bd516cf286ad73e4d8e65176ed3306cdb8cd1abe375363b6" ++
		"b6e9aaef725e991fdfb9e6e1beed5c256fbfc83a2ec77ff0dc2f1ba36edb6ef1b7ea3c7e19cb643b" ++
		"5ea1a6f03ad707cc705d04ebb06b1b77437a745ca7530ef111173bc5e8fd5c6bb9ee973737c0715d" ++
		"9f19d9775de4dd9c689b177badf7d17f69b8db1b6675d373dcaf8bd1f9f0df5b2375fe1f3fe8f59e" ++
		"c435e9e9dbcd5bed503f0685ee7ab90f77f17a5f4525d26ef4bfbd77fd5f4fe3b47c9dcfcdd8fe7f" ++
		"5ff3b4781b0f988047f40180500e0240580d0107fc0781502e0640d81d03e00c0982104e0a41582d" ++
		"05e0c41981704a0d41d83d07e1041f8250707f42480a3fe144298550ae15c2181909a174318210c2" ++
		"1943586d0de0d4348710ee1e43b81308e1441184b01e1644588b0f621c488910ea2544d89d086264" ++
		"4f8a514e0dc498491462345985312e2a4368a31763046181118a3246584700e2c45a8b317232c228" ++
		"db1be334708e513a33c028d31aa23c3d8bf1ce17c7c8fd1d23fc8186b1d62140a8f111a364828672" ++
		"2a4648391b23e0cc8489311243c2c913242434989352464dc9d81b24a3bc958b71ea4f4068f72965" ++
		"44a795123e5041b9450aa4bcab9552ae4dcb396920a56c8695f28e1e4b69152fa5bc8d981306384a" ++
		"38af2ba5dcc382f32a3f4cc98933667ca597325264cb195334660cce9b118220c939bd09e64cda82" ++
		"738a62cdb9693927344f9bb31e5d4d594936674cd79e32b242cf594d3866b4d29e727a744fb8f534" ++
		"e7bcee97b3127ecfe9d541a5fcf69432be7ccfca1126282d0f8bd42a644bba1b27688d12a0746a39" ++
		"43fa293b68b4ef96f4668e437a49496374dea1728a8bcb5a512e297c6d98d1a28ad0ca4539e98c7f" ++
		"a4f4e60c5009c140a1f504a791f29dd4382b4fa044f8a6f2caa351da9b1768f52aa6b4b2a5cf2a9f" ++
		"1c6abc54a911a2a551ba47566ac56089b4ce3b55392b4b64d545ac538eb5d07aa54829b55ea715b6" ++
		"a8574ac747e6a521ae5532bb453ad55f62155b8ed576a0cf0b015bac3c38b05046c258aa85626bbd" ++
		"9091d62e12d8da4d63ec9555b33082ca4e1aff596c359bb0b68a1759db2d44ed0da4b516aa0f551a" ++
		"670eacf568a216b2cbdb483b6ba9a570aa95eeab5b6b4b6fad6d78a035ead1d73b81142e3c39b854" ++
		"fee258eb53726dbdd0a7b72ea4d40b9d57ee95c1bb304c8080";

	var raw_buf: [1585]u8 = undefined;
	const raw = try std.fmt.hexToBytes(&raw_buf, raw_hex);
	try std.testing.expectEqual(@as(usize, 1585), raw.len);

	const result = try decode(allocator, raw);
	defer allocator.free(result);

	// Image is 472 wide x 96 tall, 1 byte/pixel grayscale = 45,312 bytes
	try std.testing.expectEqual(@as(usize, 45312), result.len);

	// Verify content via SHA-256 against qpdf-decoded reference
	var hash: [32]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(result, &hash, .{});
	const expected_sha256 = [_]u8{
		0xae, 0x21, 0x45, 0x78, 0xda, 0xbe, 0xf2, 0x61,
		0x3e, 0x19, 0xc6, 0x52, 0x6e, 0x94, 0x6c, 0xce,
		0x65, 0x76, 0xef, 0xe7, 0xaf, 0x1b, 0xdd, 0x0c,
		0xb2, 0xcb, 0x8d, 0xd7, 0x3b, 0xd8, 0x59, 0xd0,
	};
	try std.testing.expectEqualSlices(u8, &expected_sha256, &hash);
}

// MSB-first bit packer used by the boundary test above.
fn writeBitsMSB(buf: []u8, bit_pos: *usize, value: u16, bits: u4) void {
	var remaining: u4 = bits;
	while (remaining > 0) {
		const byte_idx = bit_pos.* / 8;
		const bit_in_byte: u3 = @intCast(7 - (bit_pos.* % 8));
		const free_in_byte: u4 = @as(u4, bit_in_byte) + 1;
		const take: u4 = @min(remaining, free_in_byte);
		const shift_src: u4 = remaining - take;
		const chunk: u8 = @intCast((value >> shift_src) & ((@as(u16, 1) << take) - 1));
		const shift_dst: u3 = @intCast(free_in_byte - take);
		buf[byte_idx] |= chunk << shift_dst;
		bit_pos.* += take;
		remaining -= take;
	}
}
