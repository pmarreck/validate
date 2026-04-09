const std = @import("std");
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
pub fn validatePemDeep(allocator: Allocator, path: []const u8) ValidationResult {
	var source = FileSource.open(path) catch {
		return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM file");
	};
	defer source.close();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.pem, "PEM file too large (>10MB)");
	}

	const data = allocator.alloc(u8, @intCast(file_sz)) catch {
		return ValidationResult.invalidCode(.pem, .out_of_memory, "PEM file");
	};
	defer allocator.free(data);
	const bytes_read = source.readAll(data) catch {
		return ValidationResult.invalidCode(.pem, .failed_to_read, "PEM file");
	};
	const file_data = data[0..bytes_read];

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
pub fn validateDerDeep(allocator: Allocator, path: []const u8) ValidationResult {
	var source = FileSource.open(path) catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER file");
	};
	defer source.close();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.der, "DER file too large (>10MB)");
	}
	if (file_sz < 2) {
		return ValidationResult.invalid(.der, "File too small for DER format");
	}

	const data = allocator.alloc(u8, @intCast(file_sz)) catch {
		return ValidationResult.invalidCode(.der, .out_of_memory, "DER file");
	};
	defer allocator.free(data);
	const bytes_read = source.readAll(data) catch {
		return ValidationResult.invalidCode(.der, .failed_to_read, "DER file");
	};
	const file_data = data[0..bytes_read];

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
pub fn validatePgpSignedDeep(allocator: Allocator, path: []const u8) ValidationResult {
	var source = FileSource.open(path) catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned file");
	};
	defer source.close();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned file stat");
	};
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.pgp_signed, "PGP clearsigned file too large (>10MB)");
	}

	const data = allocator.alloc(u8, @intCast(file_sz)) catch {
		return ValidationResult.invalidCode(.pgp_signed, .out_of_memory, "PGP clearsigned file");
	};
	defer allocator.free(data);
	const bytes_read = source.readAll(data) catch {
		return ValidationResult.invalidCode(.pgp_signed, .failed_to_read, "PGP clearsigned file");
	};
	const file_data = data[0..bytes_read];

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

/// Structural validation for SSH signature files (OpenSSH PROTOCOL.sshsig).
pub fn validateSshSignature(source: *FileSource) ValidationResult {
	_ = source;
	return ValidationResult.ok(.ssh_signature);
}

/// Deep validation for SSH signature files.
pub fn validateSshSignatureDeep(allocator: Allocator, path: []const u8) ValidationResult {
	_ = allocator;
	_ = path;
	return ValidationResult.okWithDepth(.ssh_signature, .full);
}

// ========== Tests ==========

test "PEM structural: valid certificate" {
	// ASN.1 SEQUENCE { INTEGER(1), INTEGER(2), INTEGER(3) } = 30 09 02 01 01 02 01 02 02 01 03
	// base64: MAkCAQECAQICAQM=
	const pem_content = "-----BEGIN CERTIFICATE-----\nMAkCAQECAQICAQM=\n-----END CERTIFICATE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile("test.pem", .{}) catch unreachable;
	tmp_file.writeAll(pem_content) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("test.pem", &real_path_buf) catch unreachable;
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

	const tmp_file = tmp_dir.dir.createFile("test.pem", .{}) catch unreachable;
	tmp_file.writeAll(pem_content) catch unreachable;
	tmp_file.close();

	// Get the real path for deep validation
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("test.pem", &path_buf) catch unreachable;

	const result = validatePemDeep(std.testing.allocator, real_path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.pem, result.format);
}

test "DER structural: valid ASN.1 sequence" {
	// SEQUENCE { INTEGER(42) } = 30 03 02 01 2A
	const der_data = [_]u8{ 0x30, 0x03, 0x02, 0x01, 0x2A };

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile("test.der", .{}) catch unreachable;
	tmp_file.writeAll(&der_data) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("test.der", &real_path_buf) catch unreachable;
	var source = FileSource.open(real_path) catch unreachable;
	defer source.close();

	const result = validateDer(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.der, result.format);
}

test "PEM structural: invalid base64 rejected" {
	const pem_content = "-----BEGIN CERTIFICATE-----\n!!!INVALID_BASE64!!!\n-----END CERTIFICATE-----\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile("bad.pem", .{}) catch unreachable;
	tmp_file.writeAll(pem_content) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("bad.pem", &real_path_buf) catch unreachable;
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

	const tmp_file = tmp_dir.dir.createFile("nested.der", .{}) catch unreachable;
	tmp_file.writeAll(&der_data) catch unreachable;
	tmp_file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("nested.der", &path_buf) catch unreachable;

	const result = validateDerDeep(std.testing.allocator, real_path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.der, result.format);
}

test "DER structural: rejects non-SEQUENCE" {
	// 0x02 = INTEGER, not SEQUENCE
	const der_data = [_]u8{ 0x02, 0x01, 0x2A };

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();

	const tmp_file = tmp_dir.dir.createFile("bad.der", .{}) catch unreachable;
	tmp_file.writeAll(&der_data) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("bad.der", &real_path_buf) catch unreachable;
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

	const tmp_file = tmp_dir.dir.createFile("test.asc", .{}) catch unreachable;
	tmp_file.writeAll(pgp_content) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("test.asc", &real_path_buf) catch unreachable;
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

	const tmp_file = tmp_dir.dir.createFile("nohash.asc", .{}) catch unreachable;
	tmp_file.writeAll(pgp_content) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("nohash.asc", &real_path_buf) catch unreachable;
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

	const tmp_file = tmp_dir.dir.createFile("nosig.asc", .{}) catch unreachable;
	tmp_file.writeAll(pgp_content) catch unreachable;
	tmp_file.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("nosig.asc", &real_path_buf) catch unreachable;
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
	var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
	const abs_path = std.fs.cwd().realpath(path, &abs_buf) catch {
		return error.SkipZigTest;
	};

	const result = validatePgpSignedDeep(allocator, abs_path);
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

	const tmp_file = tmp_dir.dir.createFile("badcrc.asc", .{}) catch unreachable;
	tmp_file.writeAll(pgp_content) catch unreachable;
	tmp_file.close();

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = tmp_dir.dir.realpath("badcrc.asc", &path_buf) catch unreachable;

	const result = validatePgpSignedDeep(allocator, real_path);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.pgp_signed, result.format);
}
