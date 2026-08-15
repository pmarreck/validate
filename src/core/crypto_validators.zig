const std = @import("std");
const runtime = @import("runtime.zig");
const heap = @import("heap.zig");
const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const Allocator = std.mem.Allocator;

/// ASN.1 Tag-Length-Value parsed result.
const Asn1Tlv = struct {
	tag: u8,
	length: usize,
	value_offset: usize, // offset where value bytes start
	total_len: usize, // tag + length-field bytes + value bytes
};

/// Parse an ASN.1 DER Tag-Length-Value at the given offset.
/// Returns null if the data is too short or the encoding is invalid.
fn parseAsn1Tlv(data: []const u8) ?Asn1Tlv {
	if (data.len < 2) return null;
	const tag = data[0];
	_ = tag; // used via caller
	const len_byte = data[1];

	if (len_byte < 0x80) {
		// Short form: length is the byte itself
		const value_offset: usize = 2;
		const length: usize = len_byte;
		if (data.len < value_offset + length) return null;
		return .{
			.tag = data[0],
			.length = length,
			.value_offset = value_offset,
			.total_len = value_offset + length,
		};
	} else if (len_byte == 0x80) {
		// Indefinite length — not valid in DER
		return null;
	} else {
		// Long form: low 7 bits = number of subsequent length bytes
		const num_len_bytes: usize = len_byte & 0x7F;
		if (num_len_bytes > 4) return null; // Refuse unreasonably large length fields
		const value_offset: usize = 2 + num_len_bytes;
		if (data.len < value_offset) return null;

		var length: usize = 0;
		for (0..num_len_bytes) |i| {
			length = (length << 8) | data[2 + i];
		}
		if (data.len < value_offset + length) return null;
		return .{
			.tag = data[0],
			.length = length,
			.value_offset = value_offset,
			.total_len = value_offset + length,
		};
	}
}

/// Recursively validate ASN.1 DER TLV structures.
/// Returns true if all TLVs are well-formed and consistent.
fn validateAsn1Recursive(data: []const u8, max_depth: usize) bool {
	if (max_depth == 0) return false; // prevent stack overflow
	if (data.len == 0) return true; // empty is fine (end of content)

	const tlv = parseAsn1Tlv(data) orelse return false;

	// If this is a constructed type (bit 5 set), recurse into its value
	if (tlv.tag & 0x20 != 0) {
		const value = data[tlv.value_offset..][0..tlv.length];
		if (!validateAsn1Recursive(value, max_depth - 1)) return false;
	}

	// Check remaining data after this TLV
	if (data.len > tlv.total_len) {
		return validateAsn1Recursive(data[tlv.total_len..], max_depth);
	}

	return true;
}

// ========== PEM Validator ==========

/// Check if a byte is valid base64 (alphabet + padding + whitespace).
fn isBase64Byte(b: u8) bool {
	return switch (b) {
		'A'...'Z', 'a'...'z', '0'...'9', '+', '/', '=' => true,
		' ', '\t', '\n', '\r' => true, // whitespace
		else => false,
	};
}

/// Structural PEM validation: verify BEGIN/END markers and base64 content.
pub fn validatePem(file: *FileSource) ValidationResult {
	var buf: [8192]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.pem, .failed_to_seek, "PEM header");
	};
	const bytes_read = file.readAll(&buf) catch {
		return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM header");
	};
	if (bytes_read < 20) {
		return ValidationResult.invalid(.pem, "File too small for PEM format");
	}
	const data = buf[0..bytes_read];

	// Must start with "-----BEGIN "
	const begin_prefix = "-----BEGIN ";
	if (!std.mem.startsWith(u8, data, begin_prefix)) {
		return ValidationResult.invalid(.pem, "Missing PEM BEGIN marker");
	}

	// Find the label (text between "-----BEGIN " and "-----")
	const after_begin = data[begin_prefix.len..];
	const label_end = std.mem.indexOf(u8, after_begin, "-----") orelse {
		return ValidationResult.invalid(.pem, "Malformed PEM BEGIN line");
	};
	if (label_end == 0) {
		return ValidationResult.invalid(.pem, "Empty PEM label");
	}
	const label = after_begin[0..label_end];

	// Look for matching END marker
	const end_marker_start = "-----END ";
	const end_search_start = begin_prefix.len + label_end + 5; // past the "-----"
	if (end_search_start >= data.len) {
		return ValidationResult.invalid(.pem, "No content after PEM BEGIN marker");
	}

	// Build expected end marker
	var end_buf: [256]u8 = undefined;
	if (end_marker_start.len + label.len + 5 > end_buf.len) {
		return ValidationResult.invalid(.pem, "PEM label too long");
	}
	@memcpy(end_buf[0..end_marker_start.len], end_marker_start);
	@memcpy(end_buf[end_marker_start.len..][0..label.len], label);
	@memcpy(end_buf[end_marker_start.len + label.len ..][0..5], "-----");
	const expected_end = end_buf[0 .. end_marker_start.len + label.len + 5];

	const end_pos = std.mem.indexOf(u8, data[end_search_start..], expected_end) orelse {
		return ValidationResult.invalid(.pem, "Missing matching PEM END marker");
	};

	// Verify base64 content between BEGIN line end and END marker
	// Find end of BEGIN line (after the trailing "-----")
	const begin_line_end_pos = begin_prefix.len + label_end + 5;
	const content_start = begin_line_end_pos;
	const content_end = end_search_start + end_pos;

	if (content_end > content_start) {
		const content = data[content_start..content_end];
		// Skip leading whitespace
		var i: usize = 0;
		while (i < content.len and (content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
		// RFC 1421 / OpenSSL encapsulated headers (Proc-Type:, DEK-Info:) for
		// password-encrypted / legacy keys sit between the BEGIN line and a
		// blank line. They contain ':'/',' (not base64), so skip the header
		// block up to its terminating blank line before the base64 check.
		const first_nl = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
		if (std.mem.indexOfScalar(u8, content[i..first_nl], ':') != null) {
			while (i < content.len) {
				const le = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
				var line = content[i..le];
				if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
				i = if (le < content.len) le + 1 else le;
				if (line.len == 0) break;
			}
		}
		// Check that remaining content is valid base64
		for (content[i..]) |b| {
			if (!isBase64Byte(b)) {
				return ValidationResult.invalid(.pem, "Invalid base64 content in PEM block");
			}
		}
	}

	return ValidationResult.okWithDepth(.pem, .structural);
}

/// Deep PEM validation: decode base64, parse inner ASN.1 DER structure.
pub fn validatePemDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.pem, "PEM file too large (>10MB)");
	}

	var heap_buf1: ?[]u8 = null;
	defer if (heap_buf1) |buf| allocator.free(buf);
	const file_data: []const u8 = if (source.getMappedSlice()) |mapped|
		mapped
	else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch return ValidationResult.invalidCode(.pem, .out_of_memory, "PEM file");
		heap_buf1 = buf;
		const n = source.readAll(buf) catch return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM file");
		break :blk buf[0..n];
	};

	// Parse all PEM blocks
	var blocks_found: usize = 0;
	var pos: usize = 0;
	const begin_prefix = "-----BEGIN ";

	while (pos < file_data.len) {
		// Find next BEGIN marker
		const begin_idx = std.mem.indexOf(u8, file_data[pos..], begin_prefix) orelse break;
		const abs_begin = pos + begin_idx;

		// Extract label
		const after_begin = file_data[abs_begin + begin_prefix.len ..];
		const label_end = std.mem.indexOf(u8, after_begin, "-----") orelse {
			return ValidationResult.invalid(.pem, "Malformed PEM BEGIN line");
		};
		if (label_end == 0) {
			return ValidationResult.invalid(.pem, "Empty PEM label");
		}
		const label = after_begin[0..label_end];

		// Build expected END marker
		var end_buf: [256]u8 = undefined;
		const end_marker_start = "-----END ";
		if (end_marker_start.len + label.len + 5 > end_buf.len) {
			return ValidationResult.invalid(.pem, "PEM label too long");
		}
		@memcpy(end_buf[0..end_marker_start.len], end_marker_start);
		@memcpy(end_buf[end_marker_start.len..][0..label.len], label);
		@memcpy(end_buf[end_marker_start.len + label.len ..][0..5], "-----");
		const expected_end = end_buf[0 .. end_marker_start.len + label.len + 5];

		// Find END marker
		const content_start = abs_begin + begin_prefix.len + label_end + 5;
		if (content_start >= file_data.len) {
			return ValidationResult.invalid(.pem, "No content after PEM BEGIN marker");
		}
		const end_pos = std.mem.indexOf(u8, file_data[content_start..], expected_end) orelse {
			return ValidationResult.invalid(.pem, "Missing matching PEM END marker");
		};

		// Extract and decode base64 content
		const b64_data = file_data[content_start .. content_start + end_pos];

		// Strip whitespace to get pure base64
		var clean_b64 = allocator.alloc(u8, b64_data.len) catch {
			return ValidationResult.invalidCode(.pem, .out_of_memory, "base64 buffer");
		};
		defer allocator.free(clean_b64);
		var clean_len: usize = 0;
		for (b64_data) |b| {
			if (b != '\n' and b != '\r' and b != ' ' and b != '\t') {
				clean_b64[clean_len] = b;
				clean_len += 1;
			}
		}

		// Decode base64
		if (clean_len == 0) {
			return ValidationResult.invalid(.pem, "Empty PEM block content");
		}

		const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(clean_b64[0..clean_len]) catch {
			return ValidationResult.invalid(.pem, "Invalid base64 length in PEM block");
		};
		const decoded = allocator.alloc(u8, decoded_size) catch {
			return ValidationResult.invalidCode(.pem, .out_of_memory, "decoded buffer");
		};
		defer allocator.free(decoded);
		std.base64.standard.Decoder.decode(decoded, clean_b64[0..clean_len]) catch {
			return ValidationResult.invalid(.pem, "Invalid base64 encoding in PEM block");
		};

		// Validate ASN.1 DER structure
		const der_data = decoded;
		if (der_data.len < 2) {
			return ValidationResult.invalid(.pem, "Decoded PEM content too small for ASN.1");
		}
		const outer_tlv = parseAsn1Tlv(der_data) orelse {
			return ValidationResult.invalid(.pem, "Invalid ASN.1 structure in PEM block");
		};
		if (outer_tlv.tag != 0x30) {
			return ValidationResult.invalid(.pem, "PEM block does not contain ASN.1 SEQUENCE");
		}
		if (outer_tlv.total_len != der_data.len) {
			return ValidationResult.invalid(.pem, "ASN.1 length mismatch in PEM block");
		}

		// For certificates, verify 3 top-level elements
		if (std.mem.eql(u8, label, "CERTIFICATE")) {
			const seq_content = der_data[outer_tlv.value_offset..][0..outer_tlv.length];
			var elem_count: usize = 0;
			var elem_pos: usize = 0;
			while (elem_pos < seq_content.len) {
				const elem_tlv = parseAsn1Tlv(seq_content[elem_pos..]) orelse {
					return ValidationResult.invalid(.pem, "Invalid ASN.1 element in certificate");
				};
				elem_count += 1;
				elem_pos += elem_tlv.total_len;
			}
			if (elem_count != 3) {
				return ValidationResult.invalid(.pem, "Certificate SEQUENCE should contain exactly 3 elements");
			}
		}

		// Recursively validate ASN.1 structure
		if (!validateAsn1Recursive(der_data, 10)) {
			return ValidationResult.invalid(.pem, "Malformed ASN.1 DER structure in PEM block");
		}

		blocks_found += 1;
		pos = content_start + end_pos + expected_end.len;
	}

	if (blocks_found == 0) {
		return ValidationResult.invalid(.pem, "No PEM blocks found");
	}

	return ValidationResult.okWithDepth(.pem, .full);
}

// ========== PGP ASCII Armor Validator (RFC 4880 §6.2) ==========

/// Validate PGP ASCII-armored data: key blocks, detached signatures, armored
/// messages. Checks the BEGIN/END label pair, armor headers, base64 body, an
/// OpenPGP packet-tag sanity bit on the decoded payload, and — when the
/// optional "=XXXX" line is present — verifies the CRC-24 over the decoded
/// bytes (full depth). GnuPG ≥ 2.4 omits the CRC line; such files validate at
/// structural depth. Distinct from validatePgpSigned (clearsigned messages).
pub fn validatePgpArmor(source: *FileSource) ValidationResult {
	const alloc = heap.validateAllocator();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.pgp_armor, .failed_to_get, "file size");
	};
	if (file_sz < 30) {
		return ValidationResult.invalid(.pgp_armor, "File too small for PGP armor");
	}
	if (file_sz > 32 * 1024 * 1024) {
		// Resource cap, not damage evidence.
		var capped = ValidationResult.okWithDepthAndWarning(.pgp_armor, .structural, "PGP armor too large for full validation");
		capped.verdict = .indeterminate;
		return capped;
	}

	var heap_buf: ?[]u8 = null;
	defer if (heap_buf) |buf| alloc.free(buf);
	const data: []const u8 = if (source.getMappedSlice()) |mapped|
		mapped
	else blk: {
		const buf = alloc.alloc(u8, @intCast(file_sz)) catch return ValidationResult.invalidCode(.pgp_armor, .out_of_memory, "PGP armor file");
		heap_buf = buf;
		source.seekTo(0) catch return ValidationResult.invalidCode(.pgp_armor, .failed_to_seek, "to start");
		const n = source.readAll(buf) catch return ValidationResult.invalidCode(.pgp_armor, .failed_to_read, "PGP armor file");
		break :blk buf[0..n];
	};

	return validatePgpArmorBuffer(alloc, data);
}

fn validatePgpArmorBuffer(allocator: Allocator, data: []const u8) ValidationResult {
	const begin_prefix = "-----BEGIN ";
	if (!std.mem.startsWith(u8, data, begin_prefix) or !std.mem.startsWith(u8, data[begin_prefix.len..], "PGP ")) {
		return ValidationResult.invalid(.pgp_armor, "Missing PGP armor BEGIN marker");
	}

	// Label runs to the closing dashes: "PGP PUBLIC KEY BLOCK", "PGP SIGNATURE", ...
	const after_begin = data[begin_prefix.len..];
	const label_end = std.mem.indexOf(u8, after_begin, "-----") orelse {
		return ValidationResult.invalid(.pgp_armor, "Malformed PGP armor BEGIN line");
	};
	const label = after_begin[0..label_end];

	// Matching END marker with the SAME label.
	var end_buf: [256]u8 = undefined;
	const end_marker_start = "-----END ";
	if (end_marker_start.len + label.len + 5 > end_buf.len) {
		return ValidationResult.invalid(.pgp_armor, "PGP armor label too long");
	}
	@memcpy(end_buf[0..end_marker_start.len], end_marker_start);
	@memcpy(end_buf[end_marker_start.len..][0..label.len], label);
	@memcpy(end_buf[end_marker_start.len + label.len ..][0..5], "-----");
	const expected_end = end_buf[0 .. end_marker_start.len + label.len + 5];

	const content_start = begin_prefix.len + label_end + 5;
	if (content_start >= data.len) {
		return ValidationResult.invalid(.pgp_armor, "No content after PGP armor BEGIN marker");
	}
	const end_pos = std.mem.indexOf(u8, data[content_start..], expected_end) orelse {
		return ValidationResult.invalid(.pgp_armor, "Missing matching PGP armor END marker");
	};
	const content = data[content_start .. content_start + end_pos];

	// Collect base64 body and the optional CRC-24 line.
	var b64_buf = allocator.alloc(u8, content.len) catch {
		return ValidationResult.invalidCode(.pgp_armor, .out_of_memory, "PGP armor base64 buffer");
	};
	defer allocator.free(b64_buf);
	var b64_len: usize = 0;
	var declared_crc: ?[]const u8 = null;

	var lines_iter = std.mem.splitScalar(u8, content, '\n');
	while (lines_iter.next()) |raw_line| {
		var line = raw_line;
		if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
		if (line.len == 0) continue;
		// Armor headers (Version:, Comment:, Charset:, Hash:) contain ": ".
		if (std.mem.indexOf(u8, line, ": ") != null) continue;

		if (line[0] == '=') {
			// CRC-24 line: '=' followed by exactly 4 base64 chars.
			if (line.len != 5) {
				return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid CRC-24 line format");
			}
			for (line[1..5]) |b| {
				if (!isBase64Byte(b) or b == '=' or b == ' ' or b == '\t') {
					return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid CRC-24 line format");
				}
			}
			declared_crc = line[1..5];
		} else {
			for (line) |b| {
				if (!isBase64Byte(b)) {
					return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid base64 content");
				}
			}
			@memcpy(b64_buf[b64_len..][0..line.len], line);
			b64_len += line.len;
		}
	}

	if (b64_len == 0) {
		return ValidationResult.invalid(.pgp_armor, "PGP armor: no base64 content found");
	}

	// Decode the body; base64 damage surfaces here even without a CRC line.
	const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_len]) catch {
		return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid base64 length");
	};
	const decoded = allocator.alloc(u8, decoded_size) catch {
		return ValidationResult.invalidCode(.pgp_armor, .out_of_memory, "PGP armor decoded buffer");
	};
	defer allocator.free(decoded);
	std.base64.standard.Decoder.decode(decoded, b64_buf[0..b64_len]) catch {
		return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid base64 encoding");
	};

	// RFC 4880 §4.2: every OpenPGP packet header has bit 7 set.
	if (decoded.len == 0 or (decoded[0] & 0x80) == 0) {
		return ValidationResult.invalid(.pgp_armor, "PGP armor: decoded data is not an OpenPGP packet stream");
	}

	if (declared_crc) |crc_str| {
		const computed_crc = computeCrc24(decoded);
		var crc_decoded: [3]u8 = undefined;
		std.base64.standard.Decoder.decode(&crc_decoded, crc_str) catch {
			return ValidationResult.invalid(.pgp_armor, "PGP armor: invalid CRC-24 base64 encoding");
		};
		const declared_value: u24 = @intCast((@as(u32, crc_decoded[0]) << 16) | (@as(u32, crc_decoded[1]) << 8) | @as(u32, crc_decoded[2]));
		if (computed_crc != declared_value) {
			return ValidationResult.invalid(.pgp_armor, "PGP armor: CRC-24 checksum mismatch");
		}
		// CRC verified over every decoded byte: full depth.
		return ValidationResult.okWithDepth(.pgp_armor, .full);
	}

	// Modern armor without the (deprecated) CRC line: structure verified only.
	return ValidationResult.okWithDepth(.pgp_armor, .structural);
}

// ========== DER Validator ==========

/// Structural DER validation: verify ASN.1 SEQUENCE tag and length.
pub fn validateDer(file: *FileSource) ValidationResult {
	var buf: [4096]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.der, .failed_to_seek, "DER header");
	};
	const bytes_read = file.readAll(&buf) catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER header");
	};
	if (bytes_read < 2) {
		return ValidationResult.invalid(.der, "File too small for DER format");
	}
	const data = buf[0..bytes_read];

	// Must start with 0x30 (SEQUENCE)
	if (data[0] != 0x30) {
		return ValidationResult.invalid(.der, "Not an ASN.1 SEQUENCE (expected tag 0x30)");
	}

	// Parse the outer TLV
	const tlv = parseAsn1Tlv(data) orelse {
		return ValidationResult.invalid(.der, "Invalid ASN.1 length encoding");
	};

	// Verify declared length is consistent with file size
	const file_sz = file.getEndPos() catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER file stat");
	};
	if (tlv.total_len != file_sz) {
		// Allow up to a few trailing bytes (some tools append newlines)
		if (tlv.total_len > file_sz) {
			return ValidationResult.invalid(.der, "ASN.1 declared length exceeds file size");
		}
		if (file_sz - tlv.total_len > 2) {
			return ValidationResult.invalid(.der, "Significant trailing data after ASN.1 structure");
		}
	}

	return ValidationResult.okWithDepth(.der, .structural);
}

/// Deep DER validation: recursively verify all ASN.1 TLV structures.
pub fn validateDerDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.der, "DER file too large (>10MB)");
	}
	if (file_sz < 2) {
		return ValidationResult.invalid(.der, "File too small for DER format");
	}

	var heap_buf2: ?[]u8 = null;
	defer if (heap_buf2) |buf| allocator.free(buf);
	const file_data: []const u8 = if (source.getMappedSlice()) |mapped|
		mapped
	else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch return ValidationResult.invalidCode(.der, .out_of_memory, "DER file");
		heap_buf2 = buf;
		const n = source.readAll(buf) catch return ValidationResult.invalidCode(.der, .failed_to_read, "DER file");
		break :blk buf[0..n];
	};

	// Must start with 0x30 (SEQUENCE)
	if (file_data[0] != 0x30) {
		return ValidationResult.invalid(.der, "Not an ASN.1 SEQUENCE (expected tag 0x30)");
	}

	// Parse outer TLV
	const outer_tlv = parseAsn1Tlv(file_data) orelse {
		return ValidationResult.invalid(.der, "Invalid ASN.1 length encoding");
	};

	// Length must match file size (allow up to 2 trailing bytes)
	if (outer_tlv.total_len > file_data.len) {
		return ValidationResult.invalid(.der, "ASN.1 declared length exceeds file size");
	}
	if (file_data.len > outer_tlv.total_len + 2) {
		return ValidationResult.invalid(.der, "Significant trailing data after ASN.1 structure");
	}

	// Recursively validate all nested TLVs
	if (!validateAsn1Recursive(file_data[0..outer_tlv.total_len], 10)) {
		return ValidationResult.invalid(.der, "Malformed ASN.1 DER structure");
	}

	return ValidationResult.okWithDepth(.der, .full);
}

/// Compute CRC-24 per RFC 4880 section 6.1.
/// Polynomial: 0x1864CFB, initial value: 0xB704CE.
fn computeCrc24(data: []const u8) u24 {
	var crc: u32 = 0xB704CE;
	for (data) |byte| {
		crc ^= @as(u32, byte) << 16;
		for (0..8) |_| {
			crc <<= 1;
			if (crc & 0x1000000 != 0) {
				crc ^= 0x1864CFB;
			}
		}
	}
	return @intCast(crc & 0xFFFFFF);
}

/// Check if a Hash: header algorithm name is valid per RFC 4880.
fn isValidPgpHashAlgo(name: []const u8) bool {
	const valid = [_][]const u8{
		"SHA256", "SHA512", "SHA384", "SHA224", "SHA1",
		"RIPEMD160", "MD5",
	};
	for (valid) |v| {
		if (std.mem.eql(u8, name, v)) return true;
	}
	return false;
}

/// Parse the Hash: header value, validating algorithm names.
/// Returns the raw algorithm string on success, null on failure.
fn parsePgpHashHeader(header_area: []const u8) ?[]const u8 {
	// Find the line starting with "Hash: "
	const hash_prefix = "Hash: ";
	if (!std.mem.startsWith(u8, header_area, hash_prefix)) return null;
	const after_prefix = header_area[hash_prefix.len..];
	// Find end of line
	const eol = std.mem.indexOf(u8, after_prefix, "\n") orelse after_prefix.len;
	const hash_value = after_prefix[0..eol];
	if (hash_value.len == 0) return null;

	// Validate each comma-separated algorithm name
	var rest = hash_value;
	while (rest.len > 0) {
		const comma = std.mem.indexOf(u8, rest, ",");
		const algo = if (comma) |c| rest[0..c] else rest;
		if (!isValidPgpHashAlgo(algo)) return null;
		rest = if (comma) |c| rest[c + 1 ..] else &[_]u8{};
	}
	return hash_value;
}

/// Structural validation for PGP clearsigned messages (RFC 4880 section 7).
/// Checks header, Hash: line, blank separator, signature armor markers,
/// base64 content, and CRC-24 line presence.
pub fn validatePgpSigned(source: *FileSource) ValidationResult {
	var buf: [8192]u8 = undefined;
	source.seekTo(0) catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_seek, "PGP clearsigned header");
	};
	const bytes_read = source.readAll(&buf) catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned header");
	};
	if (bytes_read < 40) {
		return ValidationResult.invalid(.pgp_signed, "File too small for PGP clearsigned format");
	}
	const data = buf[0..bytes_read];

	// 1. Must start with the clearsigned header
	const begin_marker = "-----BEGIN PGP SIGNED MESSAGE-----\n";
	if (!std.mem.startsWith(u8, data, begin_marker)) {
		return ValidationResult.invalid(.pgp_signed, "Missing PGP clearsigned header marker");
	}
	const after_header = data[begin_marker.len..];

	// 2. Must have Hash: header with valid algorithm(s)
	// Find the blank line that separates headers from body
	const blank_line = std.mem.indexOf(u8, after_header, "\n\n") orelse {
		return ValidationResult.invalid(.pgp_signed, "Missing blank line separator after Hash header");
	};
	const header_area = after_header[0..blank_line];
	if (parsePgpHashHeader(header_area) == null) {
		return ValidationResult.invalid(.pgp_signed, "Missing or invalid Hash: header in PGP clearsigned message");
	}

	// 3. Find signature block markers
	const sig_begin = "-----BEGIN PGP SIGNATURE-----";
	const sig_begin_pos = std.mem.indexOf(u8, data, sig_begin) orelse {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing BEGIN PGP SIGNATURE marker");
	};

	const sig_end = "-----END PGP SIGNATURE-----";
	const after_sig_begin = data[sig_begin_pos + sig_begin.len ..];
	if (std.mem.indexOf(u8, after_sig_begin, sig_end) == null) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing END PGP SIGNATURE marker");
	}

	// 4. Validate base64 content and CRC line between signature markers
	// Skip past the BEGIN line and any armor headers
	const sig_content_start = sig_begin_pos + sig_begin.len;
	const sig_end_pos = sig_begin_pos + sig_begin.len + std.mem.indexOf(u8, after_sig_begin, sig_end).?;
	const sig_content = data[sig_content_start..sig_end_pos];

	// Find CRC line (= followed by exactly 4 base64 chars)
	var found_crc = false;
	var found_base64_content = false;
	var lines_iter = std.mem.splitScalar(u8, sig_content, '\n');
	while (lines_iter.next()) |line| {
		// Skip empty lines and armor headers (Version:, Comment:, etc.)
		if (line.len == 0) continue;
		if (std.mem.indexOf(u8, line, ": ") != null) continue;

		if (line.len >= 1 and line[0] == '=') {
			// CRC line: = followed by exactly 4 base64 chars
			if (line.len == 5) {
				for (line[1..5]) |b| {
					if (!isBase64Byte(b) or b == '=' or b == ' ' or b == '\t' or b == '\n' or b == '\r') {
						return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid CRC-24 line format");
					}
				}
				found_crc = true;
			} else {
				return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid CRC-24 line format");
			}
		} else {
			// Base64 content line
			for (line) |b| {
				if (!isBase64Byte(b)) {
					return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid base64 content");
				}
			}
			found_base64_content = true;
		}
	}

	if (!found_base64_content) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: no base64 content found");
	}
	if (!found_crc) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing CRC-24 checksum line");
	}

	return ValidationResult.okWithDepth(.pgp_signed, .structural);
}

/// Deep validation for PGP clearsigned messages.
/// Performs all structural checks, then decodes base64, verifies CRC-24,
/// and checks for valid PGP signature packet tag.
pub fn validatePgpSignedDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.pgp_signed, "PGP clearsigned file too large (>10MB)");
	}

	var heap_buf3: ?[]u8 = null;
	defer if (heap_buf3) |buf| allocator.free(buf);
	const file_data: []const u8 = if (source.getMappedSlice()) |mapped|
		mapped
	else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch return ValidationResult.invalidCode(.pgp_signed, .out_of_memory, "PGP clearsigned file");
		heap_buf3 = buf;
		const n = source.readAll(buf) catch return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned file");
		break :blk buf[0..n];
	};

	// 1. Verify clearsigned header
	const begin_marker = "-----BEGIN PGP SIGNED MESSAGE-----\n";
	if (!std.mem.startsWith(u8, file_data, begin_marker)) {
		return ValidationResult.invalid(.pgp_signed, "Missing PGP clearsigned header marker");
	}
	const after_header = file_data[begin_marker.len..];

	// 2. Parse and validate Hash: header
	const blank_line = std.mem.indexOf(u8, after_header, "\n\n") orelse {
		return ValidationResult.invalid(.pgp_signed, "Missing blank line separator after Hash header");
	};
	const header_area = after_header[0..blank_line];
	const hash_algo = parsePgpHashHeader(header_area) orelse {
		return ValidationResult.invalid(.pgp_signed, "Missing or invalid Hash: header in PGP clearsigned message");
	};

	// 3. Find signature block
	const sig_begin = "-----BEGIN PGP SIGNATURE-----";
	const sig_begin_pos = std.mem.indexOf(u8, file_data, sig_begin) orelse {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing BEGIN PGP SIGNATURE marker");
	};
	const sig_end = "-----END PGP SIGNATURE-----";
	const after_sig_begin = file_data[sig_begin_pos + sig_begin.len ..];
	const sig_end_offset = std.mem.indexOf(u8, after_sig_begin, sig_end) orelse {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing END PGP SIGNATURE marker");
	};
	const sig_content = after_sig_begin[0..sig_end_offset];

	// 4. Extract base64 content (excluding armor headers and CRC line)
	var b64_buf = allocator.alloc(u8, sig_content.len) catch {
		return ValidationResult.invalidCode(.pgp_signed, .out_of_memory, "PGP base64 buffer");
	};
	defer allocator.free(b64_buf);
	var b64_len: usize = 0;
	var declared_crc: ?[]const u8 = null;

	var lines_iter = std.mem.splitScalar(u8, sig_content, '\n');
	while (lines_iter.next()) |line| {
		if (line.len == 0) continue;
		// Skip armor headers (contain ": ")
		if (std.mem.indexOf(u8, line, ": ") != null) continue;

		if (line.len >= 1 and line[0] == '=') {
			// CRC line
			if (line.len == 5) {
				declared_crc = line[1..5];
			} else {
				return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid CRC-24 line format");
			}
		} else {
			// Base64 content - append
			@memcpy(b64_buf[b64_len..][0..line.len], line);
			b64_len += line.len;
		}
	}

	if (b64_len == 0) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: no base64 content found");
	}

	const crc_str = declared_crc orelse {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: missing CRC-24 checksum line");
	};

	// 5. Decode base64
	const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_buf[0..b64_len]) catch {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid base64 length");
	};
	const decoded = allocator.alloc(u8, decoded_size) catch {
		return ValidationResult.invalidCode(.pgp_signed, .out_of_memory, "PGP decoded buffer");
	};
	defer allocator.free(decoded);
	std.base64.standard.Decoder.decode(decoded, b64_buf[0..b64_len]) catch {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid base64 encoding");
	};

	// 6. Compute CRC-24 and compare
	const computed_crc = computeCrc24(decoded);

	// Decode the declared CRC from base64 (4 base64 chars = 3 bytes = 24 bits)
	var crc_decoded: [3]u8 = undefined;
	std.base64.standard.Decoder.decode(&crc_decoded, crc_str) catch {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid CRC-24 base64 encoding");
	};
	const declared_crc_value: u24 = @intCast((@as(u32, crc_decoded[0]) << 16) | (@as(u32, crc_decoded[1]) << 8) | @as(u32, crc_decoded[2]));

	if (computed_crc != declared_crc_value) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: CRC-24 checksum mismatch");
	}

	// 7. Verify PGP signature packet tag
	if (decoded.len < 1) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: decoded data too short");
	}
	const tag_byte = decoded[0];
	// Old format: 0x88 (1-byte length) or 0x89 (2-byte length) for tag 2
	// New format: 0xC2 (tag 2) or 0xC3 (tag 3 with partial body)
	const valid_tags = [_]u8{ 0x88, 0x89, 0xC2, 0xC3 };
	var valid_tag = false;
	for (valid_tags) |vt| {
		if (tag_byte == vt) {
			valid_tag = true;
			break;
		}
	}
	if (!valid_tag) {
		return ValidationResult.invalid(.pgp_signed, "PGP signature block: invalid PGP packet tag (expected signature packet)");
	}

	// Map hash algorithm to a static warning message string.
	const warning_message = mapHashAlgoToWarning(hash_algo);

	return ValidationResult.okWithDepthAndWarning(.pgp_signed, .full, warning_message);}

/// Map hash algorithm string to a static warning message string.
fn mapHashAlgoToWarning(algo: []const u8) []const u8 {
	if (std.mem.eql(u8, algo, "SHA256")) return "PGP clearsigned, SHA256";
	if (std.mem.eql(u8, algo, "SHA512")) return "PGP clearsigned, SHA512";
	if (std.mem.eql(u8, algo, "SHA384")) return "PGP clearsigned, SHA384";
	if (std.mem.eql(u8, algo, "SHA224")) return "PGP clearsigned, SHA224";
	if (std.mem.eql(u8, algo, "SHA1")) return "PGP clearsigned, SHA1";
	if (std.mem.eql(u8, algo, "RIPEMD160")) return "PGP clearsigned, RIPEMD160";
	if (std.mem.eql(u8, algo, "MD5")) return "PGP clearsigned, MD5";
	// For comma-separated multi-algo, return a generic message
	return "PGP clearsigned, multiple hash algorithms";
}

/// Read a length-prefixed SSH wire string (u32 BE length + bytes).
/// Returns the string value and total bytes consumed, or null if data is too short.
fn readSshString(data: []const u8) ?struct { value: []const u8, consumed: usize } {
	if (data.len < 4) return null;
	const len = std.mem.readInt(u32, data[0..4], .big);
	if (data.len < 4 + len) return null;
	return .{ .value = data[4..][0..len], .consumed = 4 + len };
}

/// Map SSH key type + hash algorithm + namespace to a static warning string.
/// For common combinations we return a comptime-known string; for uncommon ones
/// we use a thread-local buffer so the returned slice has stable lifetime.
fn mapSshSigWarning(key_type: []const u8, hash_algo: []const u8, namespace: []const u8) []const u8 {
	// Common key types
	const is_ed25519 = std.mem.eql(u8, key_type, "ssh-ed25519");
	const is_rsa = std.mem.eql(u8, key_type, "ssh-rsa");
	const is_ecdsa256 = std.mem.eql(u8, key_type, "ecdsa-sha2-nistp256");
	const is_ecdsa384 = std.mem.eql(u8, key_type, "ecdsa-sha2-nistp384");

	// Common namespaces
	const is_file = std.mem.eql(u8, namespace, "file");
	const is_git = std.mem.eql(u8, namespace, "git");

	// Common hash algos
	const is_sha256 = std.mem.eql(u8, hash_algo, "sha256");
	const is_sha512 = std.mem.eql(u8, hash_algo, "sha512");

	// ed25519 combinations
	if (is_ed25519 and is_sha512 and is_file) return "SSH sig ssh-ed25519/sha512 ns=file";
	if (is_ed25519 and is_sha256 and is_file) return "SSH sig ssh-ed25519/sha256 ns=file";
	if (is_ed25519 and is_sha512 and is_git) return "SSH sig ssh-ed25519/sha512 ns=git";
	if (is_ed25519 and is_sha256 and is_git) return "SSH sig ssh-ed25519/sha256 ns=git";

	// RSA combinations
	if (is_rsa and is_sha512 and is_file) return "SSH sig ssh-rsa/sha512 ns=file";
	if (is_rsa and is_sha256 and is_file) return "SSH sig ssh-rsa/sha256 ns=file";
	if (is_rsa and is_sha512 and is_git) return "SSH sig ssh-rsa/sha512 ns=git";
	if (is_rsa and is_sha256 and is_git) return "SSH sig ssh-rsa/sha256 ns=git";

	// ECDSA P-256 combinations
	if (is_ecdsa256 and is_sha256 and is_file) return "SSH sig ecdsa-sha2-nistp256/sha256 ns=file";
	if (is_ecdsa256 and is_sha256 and is_git) return "SSH sig ecdsa-sha2-nistp256/sha256 ns=git";
	if (is_ecdsa256 and is_sha512 and is_file) return "SSH sig ecdsa-sha2-nistp256/sha512 ns=file";
	if (is_ecdsa256 and is_sha512 and is_git) return "SSH sig ecdsa-sha2-nistp256/sha512 ns=git";

	// ECDSA P-384 combinations
	if (is_ecdsa384 and is_sha256 and is_file) return "SSH sig ecdsa-sha2-nistp384/sha256 ns=file";
	if (is_ecdsa384 and is_sha256 and is_git) return "SSH sig ecdsa-sha2-nistp384/sha256 ns=git";
	if (is_ecdsa384 and is_sha512 and is_file) return "SSH sig ecdsa-sha2-nistp384/sha512 ns=file";
	if (is_ecdsa384 and is_sha512 and is_git) return "SSH sig ecdsa-sha2-nistp384/sha512 ns=git";

	// Fallback: use a thread-local buffer for the formatted string
	const S = struct {
		threadlocal var buf: [256]u8 = undefined;
	};
	const result = std.fmt.bufPrint(&S.buf, "SSH sig {s}/{s} ns={s}", .{ key_type, hash_algo, namespace }) catch {
		return "SSH sig (unknown)";
	};
	return result;
}

/// Structural validation for SSH signature files (OpenSSH PROTOCOL.sshsig).
/// Checks armor markers (BEGIN/END) and valid base64 content between them.
pub fn validateSshSignature(source: *FileSource) ValidationResult {
	var buf: [8192]u8 = undefined;
	source.seekTo(0) catch {
		return ValidationResult.invalidCode(.ssh_signature, .failed_to_seek, "SSH signature header");
	};
	const bytes_read = source.readAll(&buf) catch {
		return ValidationResult.invalidCode(.ssh_signature, .failed_to_read, "SSH signature header");
	};
	if (bytes_read < 30) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: file too small");
	}
	const data = buf[0..bytes_read];

	// 1. Must start with BEGIN marker
	const begin_marker = "-----BEGIN SSH SIGNATURE-----\n";
	if (!std.mem.startsWith(u8, data, begin_marker)) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: missing BEGIN marker");
	}

	// 2. Must have END marker
	const end_marker = "-----END SSH SIGNATURE-----";
	const end_pos = std.mem.indexOf(u8, data[begin_marker.len..], end_marker) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: missing END marker");
	};

	// 3. Validate base64 content between markers
	const content = data[begin_marker.len..][0..end_pos];
	var i: usize = 0;
	// Skip leading whitespace
	while (i < content.len and (content[i] == '\n' or content[i] == '\r')) : (i += 1) {}
	for (content[i..]) |b| {
		if (!isBase64Byte(b)) {
			return ValidationResult.invalid(.ssh_signature, "SSH signature: invalid base64 content");
		}
	}

	return ValidationResult.okWithDepth(.ssh_signature, .structural);
}

/// Deep validation for SSH signature files (OpenSSH PROTOCOL.sshsig wire format).
/// Decodes base64, then parses the SSHSIG binary structure: magic, version,
/// public key blob, namespace, reserved, hash algorithm, and signature blob.
pub fn validateSshSignatureDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.ssh_signature, .failed_to_read, "SSH signature file stat");
	};
	if (file_sz > 1 * 1024 * 1024) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: file too large (>1MB)");
	}

	var heap_buf4: ?[]u8 = null;
	defer if (heap_buf4) |buf| allocator.free(buf);
	const file_data: []const u8 = if (source.getMappedSlice()) |mapped|
		mapped
	else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch return ValidationResult.invalidCode(.ssh_signature, .out_of_memory, "SSH signature file");
		heap_buf4 = buf;
		const n = source.readAll(buf) catch return ValidationResult.invalidCode(.ssh_signature, .failed_to_read, "SSH signature file");
		break :blk buf[0..n];
	};

	// 1. Find armor markers
	const begin_marker = "-----BEGIN SSH SIGNATURE-----\n";
	if (!std.mem.startsWith(u8, file_data, begin_marker)) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: missing BEGIN marker");
	}
	const end_marker = "-----END SSH SIGNATURE-----";
	const after_begin = file_data[begin_marker.len..];
	const end_pos = std.mem.indexOf(u8, after_begin, end_marker) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: missing END marker");
	};

	// 2. Extract and clean base64 content
	const b64_data = after_begin[0..end_pos];
	var clean_b64 = allocator.alloc(u8, b64_data.len) catch {
		return ValidationResult.invalidCode(.ssh_signature, .out_of_memory, "SSH signature base64 buffer");
	};
	defer allocator.free(clean_b64);
	var clean_len: usize = 0;
	for (b64_data) |b| {
		if (b != '\n' and b != '\r' and b != ' ' and b != '\t') {
			clean_b64[clean_len] = b;
			clean_len += 1;
		}
	}

	if (clean_len == 0) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: empty base64 content");
	}

	// 3. Decode base64
	const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(clean_b64[0..clean_len]) catch {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: invalid base64 length");
	};
	const decoded = allocator.alloc(u8, decoded_size) catch {
		return ValidationResult.invalidCode(.ssh_signature, .out_of_memory, "SSH signature decoded buffer");
	};
	defer allocator.free(decoded);
	std.base64.standard.Decoder.decode(decoded, clean_b64[0..clean_len]) catch {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: invalid base64 encoding");
	};

	// 4. Parse SSHSIG wire format
	var pos: usize = 0;

	// Magic: "SSHSIG" (6 bytes)
	if (decoded.len < 6) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: decoded data too short for magic");
	}
	if (!std.mem.eql(u8, decoded[0..6], "SSHSIG")) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: invalid magic (expected SSHSIG)");
	}
	pos = 6;

	// Version: u32 BE, must be 1
	if (decoded.len < pos + 4) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated version field");
	}
	const version = std.mem.readInt(u32, decoded[pos..][0..4], .big);
	if (version != 1) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: unsupported version (expected 1)");
	}
	pos += 4;

	// Public key blob (length-prefixed string)
	const pubkey = readSshString(decoded[pos..]) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated public key blob");
	};
	// Extract key type from within the public key blob
	const key_type_str = readSshString(pubkey.value) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated key type in public key");
	};
	if (key_type_str.value.len == 0) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: empty key type");
	}
	pos += pubkey.consumed;

	// Namespace (length-prefixed string, must be non-empty)
	const namespace = readSshString(decoded[pos..]) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated namespace");
	};
	if (namespace.value.len == 0) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: empty namespace");
	}
	pos += namespace.consumed;

	// Reserved (length-prefixed string, any length OK including 0)
	const reserved = readSshString(decoded[pos..]) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated reserved field");
	};
	pos += reserved.consumed;

	// Hash algorithm (length-prefixed string, must be sha256 or sha512)
	const hash_algo = readSshString(decoded[pos..]) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated hash algorithm");
	};
	if (!std.mem.eql(u8, hash_algo.value, "sha256") and !std.mem.eql(u8, hash_algo.value, "sha512")) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: unsupported hash algorithm (expected sha256 or sha512)");
	}
	pos += hash_algo.consumed;

	// Signature blob (length-prefixed string)
	const sig_blob = readSshString(decoded[pos..]) orelse {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: truncated signature blob");
	};
	// The signature blob should itself contain at least a key type string
	if (readSshString(sig_blob.value) == null) {
		return ValidationResult.invalid(.ssh_signature, "SSH signature: malformed signature blob");
	}

	// Build warning message with key type, hash algo, and namespace
	const warning_message = mapSshSigWarning(key_type_str.value, hash_algo.value, namespace.value);

	return ValidationResult.okWithDepthAndWarning(.ssh_signature, .full, warning_message);
}

// ========== Tests ==========

test "PEM structural: valid certificate" {
	// ASN.1 SEQUENCE { INTEGER(1), INTEGER(2), INTEGER(3) } = 30 09 02 01 01 02 01 02 02 01 03
	// base64: MAkCAQECAQICAQM=
	const pem_content = "-----BEGIN CERTIFICATE-----\nMAkCAQECAQICAQM=\n-----END CERTIFICATE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "test.pem", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pem_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.pem") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePem(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.pem, result.format);
}

test "PEM deep: ASN.1 structure valid" {
	// SEQUENCE { INTEGER(1), INTEGER(2), INTEGER(3) }
	// DER: 30 09 02 01 01 02 01 02 02 01 03
	// base64: MAkCAQECAQICAQM=
	const pem_content = "-----BEGIN PRIVATE KEY-----\nMAkCAQECAQICAQM=\n-----END PRIVATE KEY-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "test.pem", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pem_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	// Get the real path for deep validation
	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.pem") catch unreachable;
	defer std.testing.allocator.free(real_path);

	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();
	const result = validatePemDeep(std.testing.allocator, &source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.pem, result.format);
}

test "DER structural: valid ASN.1 sequence" {
	// SEQUENCE { INTEGER(42) } = 30 03 02 01 2A
	const der_data = [_]u8{ 0x30, 0x03, 0x02, 0x01, 0x2A };

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "test.der", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), &der_data, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.der") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validateDer(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.der, result.format);
}

test "PEM structural: encrypted key with RFC 1421 headers accepted" {
	// Password-encrypted / legacy OpenSSL keys carry Proc-Type / DEK-Info
	// encapsulated headers after the BEGIN line. validatePem must skip them
	// before the base64 check (regression for Validate-GUI false positive on
	// npm public-encrypt / parse-asn1 fixtures).
	const pem_content =
		"-----BEGIN RSA PRIVATE KEY-----\n" ++
		"Proc-Type: 4,ENCRYPTED\n" ++
		"DEK-Info: DES-EDE3-CBC,0123456789ABCDEF\n" ++
		"\n" ++
		"MIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Q\n" ++
		"uKUpRKfFLfRYC9AIKjbJTWit+CqvjSFmbaY=\n" ++
		"-----END RSA PRIVATE KEY-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "enc.pem", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pem_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "enc.pem") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePem(&source);
	try std.testing.expect(result.is_valid);
}

test "PEM structural: invalid base64 rejected" {
	const pem_content = "-----BEGIN CERTIFICATE-----\n!!!INVALID_BASE64!!!\n-----END CERTIFICATE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "bad.pem", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pem_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "bad.pem") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePem(&source);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.pem, result.format);
}

test "DER deep: recursive ASN.1 validation" {
	// SEQUENCE { SEQUENCE { INTEGER(1) }, INTEGER(2) }
	// Inner: 30 03 02 01 01
	// Outer: 30 08 30 03 02 01 01 02 01 02
	const der_data = [_]u8{ 0x30, 0x08, 0x30, 0x03, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02 };

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "nested.der", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), &der_data, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "nested.der") catch unreachable;
	defer std.testing.allocator.free(real_path);

	var source_der = FileSource.open(real_path) catch unreachable;
	defer source_der.close();
	const result = validateDerDeep(std.testing.allocator, &source_der);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.der, result.format);
}

test "DER structural: rejects non-SEQUENCE" {
	// 0x02 = INTEGER, not SEQUENCE
	const der_data = [_]u8{ 0x02, 0x01, 0x2A };

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "bad.der", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), &der_data, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "bad.der") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validateDer(&source);
	try std.testing.expect(!result.is_valid);
}

test "ASN.1 TLV parser: long-form length" {
	// SEQUENCE with 2-byte long form length: 30 82 01 00 ... (256 bytes of value)
	var data: [260]u8 = undefined;
	data[0] = 0x30; // SEQUENCE
	data[1] = 0x82; // long form, 2 bytes
	data[2] = 0x01; // high byte = 1
	data[3] = 0x00; // low byte = 0 => length = 256
	@memset(data[4..], 0x00);

	const tlv = parseAsn1Tlv(&data) orelse {
		try std.testing.expect(false); // should not be null
		return;
	};
	try std.testing.expectEqual(@as(usize, 256), tlv.length);
	try std.testing.expectEqual(@as(usize, 4), tlv.value_offset);
	try std.testing.expectEqual(@as(usize, 260), tlv.total_len);
}

// ========== PGP Clearsigned Validator Tests ==========

test "PGP clearsigned: magic detection" {
	const detectFormat = format_validation.detectFormat;
	const header = "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA256\n";
	try std.testing.expectEqual(FileFormat.pgp_signed, detectFormat(header));
}

test "PGP clearsigned: structural valid" {
	const pgp_content =
		"-----BEGIN PGP SIGNED MESSAGE-----\n" ++
		"Hash: SHA256\n" ++
		"\n" ++
		"Hello, world!\n" ++
		"-----BEGIN PGP SIGNATURE-----\n" ++
		"\n" ++
		"iQEzBAABCAAdFiEEaaaa\n" ++
		"=abcd\n" ++
		"-----END PGP SIGNATURE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "test.asc", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pgp_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.asc") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePgpSigned(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
	try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "PGP clearsigned: missing Hash header fails structural" {
	const pgp_content =
		"-----BEGIN PGP SIGNED MESSAGE-----\n" ++
		"\n" ++
		"Hello, world!\n" ++
		"-----BEGIN PGP SIGNATURE-----\n" ++
		"\n" ++
		"iQEzBAABCAAdFiEEaaaa\n" ++
		"=abcd\n" ++
		"-----END PGP SIGNATURE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "nohash.asc", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pgp_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "nohash.asc") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePgpSigned(&source);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
}

test "PGP clearsigned: no signature block fails structural" {
	const pgp_content =
		"-----BEGIN PGP SIGNED MESSAGE-----\n" ++
		"Hash: SHA256\n" ++
		"\n" ++
		"Hello, world!\n" ++
		"This message has no signature block.\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "nosig.asc", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pgp_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "nosig.asc") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validatePgpSigned(&source);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
}

test "PGP clearsigned: ground truth deep validation" {
	const allocator = std.testing.allocator;
	// Try to locate the ground truth sample
	const path = "ground_truth_examples/pgp_signed/sample.asc";

	// Use std.fs.cwd() to get the absolute path
	const abs_path = path;

	var source = FileSource.open(abs_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validatePgpSignedDeep(allocator, &source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	// Should have a warning_message with hash algorithm
	try std.testing.expect(result.warning_message != null);
}

test "PGP clearsigned: bad CRC fails deep validation" {
	const allocator = std.testing.allocator;

	// Valid structure but the CRC line is deliberately wrong
	const pgp_content =
		"-----BEGIN PGP SIGNED MESSAGE-----\n" ++
		"Hash: SHA256\n" ++
		"\n" ++
		"Test body content.\n" ++
		"-----BEGIN PGP SIGNATURE-----\n" ++
		"\n" ++
		"iEYEARECAAYFAlJMgc4ACgkQ\n" ++
		"=ZZZZ\n" ++
		"-----END PGP SIGNATURE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "badcrc.asc", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), pgp_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "badcrc.asc") catch unreachable;
	defer std.testing.allocator.free(real_path);

	var source2 = FileSource.open(real_path) catch unreachable;
	defer source2.close();
	const result = validatePgpSignedDeep(allocator, &source2);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
}

// ========== SSH Signature Validator Tests ==========

test "SSH signature: magic detection" {
	const detectFormat = format_validation.detectFormat;
	const header = "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH";
	try std.testing.expectEqual(FileFormat.ssh_signature, detectFormat(header));
}

test "SSH signature: structural valid" {
	// Valid SSH signature file with proper armor markers and base64 content
	const ssh_sig_content =
		"-----BEGIN SSH SIGNATURE-----\n" ++
		"U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgobeUYXifFFQpB2asxySyR4e0/i\n" ++
		"sUUUPV6EmP9mGeEtIAAAAEZmlsZQAAAAAAAAAGc2hhNTEyAAAAUwAAAAtzc2gtZWQyNTUx\n" ++
		"OQAAAECxRzTNZZ7FbpNxTV0Irdh6rpsIHdXqmQloH5EqZC/Okup5Bov+Q505GtafadCmJo\n" ++
		"A2qlIpZW+hTiIjbY3B2FUC\n" ++
		"-----END SSH SIGNATURE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "test.sig", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), ssh_sig_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "test.sig") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validateSshSignature(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.ssh_signature, result.format);
	try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
}

test "SSH signature: no end marker fails structural" {
	const ssh_sig_content =
		"-----BEGIN SSH SIGNATURE-----\n" ++
		"U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTk=\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "noend.sig", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), ssh_sig_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "noend.sig") catch unreachable;
	defer std.testing.allocator.free(real_path);
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validateSshSignature(&source);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.ssh_signature, result.format);
}

test "SSH signature: ground truth deep validation" {
	const allocator = std.testing.allocator;
	const path = "ground_truth_examples/ssh_signature/sample.sig";

	const abs_path = path;

	var source = FileSource.open(abs_path) catch return error.SkipZigTest;
	defer source.close();
	const result = validateSshSignatureDeep(allocator, &source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.ssh_signature, result.format);
	try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	// Should have a warning_message with key type, hash algo, and namespace
	try std.testing.expect(result.warning_message != null);
	try std.testing.expectEqualStrings("SSH sig ssh-ed25519/sha512 ns=file", result.warning_message.?);
}

test "SSH signature: bad inner magic fails deep validation" {
	const allocator = std.testing.allocator;

	// Valid armor wrapping garbage content (not starting with SSHSIG magic)
	// This is just base64 of "BADSIG\x00\x00\x00\x01..." — wrong magic
	const bad_content =
		"-----BEGIN SSH SIGNATURE-----\n" ++
		"QkFEU0lHAAAAAQAAAAA=\n" ++
		"-----END SSH SIGNATURE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile(runtime.io(), "badmagic.sig", .{}) catch unreachable;
	tmp_file.writePositionalAll(runtime.io(), bad_content, 0) catch unreachable;
	tmp_file.close(runtime.io());

	const real_path = runtime.tmpRealpathAlloc(&tmp_dir, std.testing.allocator, "badmagic.sig") catch unreachable;
	defer std.testing.allocator.free(real_path);

	var source2 = FileSource.open(real_path) catch unreachable;
	defer source2.close();
	const result = validateSshSignatureDeep(allocator, &source2);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.ssh_signature, result.format);
}

test "PGP armored key with valid CRC-24 validates full; corruption is caught" {
	const allocator = std.testing.allocator;

	// Synthesize a minimal armored block: BEGIN line, armor header, blank
	// line, base64 body, CRC-24 line, matching END line (RFC 4880 §6.2).
	// First byte 0x98 = old-format public-key packet tag (bit 7 set, §4.2).
	const payload = "\x98\x28not-a-real-key-but-crc-covers-these-bytes";
	var b64_buf: [128]u8 = undefined;
	const b64 = std.base64.standard.Encoder.encode(&b64_buf, payload);
	const crc = computeCrc24(payload);
	const crc_bytes = [3]u8{ @intCast((crc >> 16) & 0xFF), @intCast((crc >> 8) & 0xFF), @intCast(crc & 0xFF) };
	var crc_b64_buf: [8]u8 = undefined;
	const crc_b64 = std.base64.standard.Encoder.encode(&crc_b64_buf, &crc_bytes);

	var armor_buf: [512]u8 = undefined;
	const armor = try std.fmt.bufPrint(&armor_buf,
		"-----BEGIN PGP PUBLIC KEY BLOCK-----\nVersion: test\n\n{s}\n={s}\n-----END PGP PUBLIC KEY BLOCK-----\n",
		.{ b64, crc_b64 });

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	{
		const f = try tmp_dir.dir.createFile(runtime.io(), "key.asc", .{});
		try f.writePositionalAll(runtime.io(), armor, 0);
		f.close(runtime.io());
		const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "key.asc");
		defer allocator.free(path);
		var src = try FileSource.open(path);
		defer src.close();
		const result = validatePgpArmor(&src);
		try std.testing.expect(result.is_valid);
		try std.testing.expectEqual(FileFormat.pgp_armor, result.format);
		try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
	}
	{
		// Flip one base64 body byte: CRC-24 must catch it.
		var corrupt_buf: [512]u8 = undefined;
		@memcpy(corrupt_buf[0..armor.len], armor);
		const body_off = std.mem.indexOf(u8, armor, "\n\n").? + 2;
		corrupt_buf[body_off] = if (corrupt_buf[body_off] == 'A') 'B' else 'A';
		const f = try tmp_dir.dir.createFile(runtime.io(), "corrupt.asc", .{});
		try f.writePositionalAll(runtime.io(), corrupt_buf[0..armor.len], 0);
		f.close(runtime.io());
		const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "corrupt.asc");
		defer allocator.free(path);
		var src = try FileSource.open(path);
		defer src.close();
		try std.testing.expect(!validatePgpArmor(&src).is_valid);
	}
	{
		// END label must match the BEGIN label.
		var mismatch_buf: [640]u8 = undefined;
		const mismatched = try std.fmt.bufPrint(&mismatch_buf,
			"-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n{s}\n={s}\n-----END PGP PRIVATE KEY BLOCK-----\n",
			.{ b64, crc_b64 });
		const f = try tmp_dir.dir.createFile(runtime.io(), "mismatch.asc", .{});
		try f.writePositionalAll(runtime.io(), mismatched, 0);
		f.close(runtime.io());
		const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "mismatch.asc");
		defer allocator.free(path);
		var src = try FileSource.open(path);
		defer src.close();
		try std.testing.expect(!validatePgpArmor(&src).is_valid);
	}
	{
		// GnuPG >= 2.4 omits the CRC line: still valid, structural depth.
		var nocrc_buf: [512]u8 = undefined;
		const nocrc = try std.fmt.bufPrint(&nocrc_buf,
			"-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n{s}\n-----END PGP PUBLIC KEY BLOCK-----\n",
			.{b64});
		const f = try tmp_dir.dir.createFile(runtime.io(), "nocrc.asc", .{});
		try f.writePositionalAll(runtime.io(), nocrc, 0);
		f.close(runtime.io());
		const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "nocrc.asc");
		defer allocator.free(path);
		var src = try FileSource.open(path);
		defer src.close();
		const result = validatePgpArmor(&src);
		try std.testing.expect(result.is_valid);
		try std.testing.expectEqual(format_validation.ValidationDepth.structural, result.validation_depth);
	}
}
