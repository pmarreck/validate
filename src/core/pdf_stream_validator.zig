//! PDF FlateDecode content-stream integrity validator.
//!
//! Walks every indirect object in a PDF, and for any stream whose filter chain
//! *begins with* /FlateDecode, runs a streaming zlib inflation to verify the
//! zlib Adler-32 checksum and raw deflate integrity. Streams already validated
//! by pdf_image_validator / pdf_font_validator / pdf_embedded_file_validator
//! are skipped via an exclusion set of object numbers so we don't
//! double-work image/font/embed data.
//!
//! Integrity technique: zlib's per-block CRC + Adler-32 trailer detects any
//! byte corruption inside the compressed payload of a content stream. We
//! discard the decompressed output — this is pure verification, not parsing.
//!
//! Reference: RFC 1950 (zlib), PDF 1.7 Section 7.4.4 (FlateDecode filter).

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlib = @import("zlib.zig");
const pdf_xref_parser = @import("pdf_xref_parser.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const FlateStreamFailure = struct {
	object_num: u32,
	stream_start: usize,
	stream_end: usize,
	reason: []const u8, // static string
};

pub const PdfStreamValidationResult = struct {
	total_flate_streams: u32,
	validated: u32,
	/// Streams that decoded only via the lenient (Adobe-InDesign style)
	/// recovery path — deflate body intact but zlib trailer truncated.
	/// Caller emits a WARN verdict if this is non-zero.
	validated_lenient: u32,
	failed: u32,
	skipped_already_validated: u32,
	skipped_size_limit: u32,
	total_bytes_verified: u64,
	first_failure: ?FlateStreamFailure,
	valid: bool,
};

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

/// Skip streams whose *compressed* payload exceeds this size to avoid OOM /
/// pathological inputs. 64 MB is generous for a single content stream — most
/// real content streams are < 1 MB.
const MAX_FLATE_INPUT_BYTES: usize = 64 * 1024 * 1024;

/// Upper bound on uncompressed output tracked by inflateStreamValidate.
/// 512 MB cap prevents decompression-bomb attacks.
const MAX_DECOMPRESSED_BYTES: u64 = 512 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Walk all indirect objects in `pdf_data` and validate every /FlateDecode
/// stream's zlib integrity. `excluded_object_nums` is the set of object
/// numbers already verified by image/font/embed validators; those streams
/// are skipped to avoid redundant work.
pub fn validatePdfFlateStreams(
	allocator: Allocator,
	pdf_data: []const u8,
	excluded_object_nums: *const std.AutoHashMapUnmanaged(u32, void),
) PdfStreamValidationResult {
	var total: u32 = 0;
	var validated: u32 = 0;
	var validated_lenient: u32 = 0;
	var failed: u32 = 0;
	var skipped: u32 = 0;
	var size_skipped: u32 = 0;
	var bytes_verified: u64 = 0;
	var first_failure: ?FlateStreamFailure = null;

	// Prefer xref-driven iteration (O(M) in object count). Fall back to linear
	// scan if xref is broken — linearised/object-stream PDFs still get hit
	// because the linear fallback picks up every top-level "N G obj".
	const streams = findFlateStreams(allocator, pdf_data) catch {
		return .{
			.total_flate_streams = 0,
			.validated = 0,
			.validated_lenient = 0,
			.failed = 0,
			.skipped_already_validated = 0,
			.skipped_size_limit = 0,
			.total_bytes_verified = 0,
			.first_failure = null,
			.valid = true,
		};
	};
	defer allocator.free(streams);

	for (streams) |s| {
		total += 1;

		// Skip streams already validated by image / font / embedded-file paths.
		if (excluded_object_nums.contains(s.object_num)) {
			skipped += 1;
			continue;
		}

		if (s.stream_end <= s.stream_start) {
			skipped += 1;
			continue;
		}
		const len = s.stream_end - s.stream_start;
		if (len > MAX_FLATE_INPUT_BYTES) {
			size_skipped += 1;
			continue;
		}
		if (s.stream_end > pdf_data.len) {
			size_skipped += 1;
			continue;
		}

		const compressed = pdf_data[s.stream_start..s.stream_end];

		// A valid zlib stream begins with a 2-byte header whose first byte's
		// low 4 bits are 8 (deflate method). We do not reject on header shape
		// alone, because encrypted PDFs store FlateDecode streams that are
		// re-encrypted (no zlib header). Only actual inflate-time errors (CRC
		// / data / truncation) are treated as corruption.
		//
		// Use the lenient validator: many PDF producers (notably Adobe
		// InDesign) emit FlateDecode streams whose deflate body is intact
		// but whose zlib wrapper is missing the trailing Adler-32 checksum.
		// All major PDF readers tolerate this. The lenient path validates
		// the header, then retries as raw deflate on the body — genuine
		// corruption still fails because the deflate body itself must
		// terminate cleanly.
		const raw: bool = false;
		var lenient_used: bool = false;
		const result = zlib.inflateStreamValidateLenient(compressed, MAX_DECOMPRESSED_BYTES, raw, &lenient_used);
		if (result) |produced| {
			validated += 1;
			if (lenient_used) validated_lenient += 1;
			bytes_verified += produced;
		} else |err| switch (err) {
			zlib.ZlibError.DecompressedTooLarge => {
				// Giant legitimate stream — treat as skipped rather than failure.
				size_skipped += 1;
			},
			zlib.ZlibError.InitFailed, zlib.ZlibError.OutOfMemory => {
				// System-level; skip without failing the PDF.
				skipped += 1;
			},
			// Every other ZlibError variant is data corruption.
			else => {
				failed += 1;
				if (first_failure == null) {
					first_failure = .{
						.object_num = s.object_num,
						.stream_start = s.stream_start,
						.stream_end = s.stream_end,
						.reason = zlibErrorReason(err),
					};
				}
			},
		}
	}

	return .{
		.total_flate_streams = total,
		.validated = validated,
		.validated_lenient = validated_lenient,
		.failed = failed,
		.skipped_already_validated = skipped,
		.skipped_size_limit = size_skipped,
		.total_bytes_verified = bytes_verified,
		.first_failure = first_failure,
		.valid = failed == 0,
	};
}

fn zlibErrorReason(err: anyerror) []const u8 {
	return switch (err) {
		zlib.ZlibError.DataError => "zlib data error (CRC/Adler-32 mismatch or malformed deflate)",
		zlib.ZlibError.UnexpectedEof => "zlib stream truncated",
		zlib.ZlibError.ZlibError => "zlib stream error",
		else => "FlateDecode stream inflation failed",
	};
}

// ---------------------------------------------------------------------------
// Stream discovery
// ---------------------------------------------------------------------------

pub const FlateStream = struct {
	object_num: u32,
	stream_start: usize,
	stream_end: usize,
	/// true if the /Filter chain begins with /FlateDecode. Later filters (e.g.
	/// ASCIIHexDecode) are allowed — we only verify the zlib wrapper that sits
	/// at the bottom of the chain as the first applied filter.
	flate_first: bool,
};

fn findFlateStreams(allocator: Allocator, pdf_data: []const u8) ![]FlateStream {
	var out: std.ArrayListUnmanaged(FlateStream) = .{};
	errdefer out.deinit(allocator);

	// Try xref-driven enumeration first. It handles incremental updates via
	// /Prev chains.
	if (pdf_xref_parser.parseXrefTable(allocator, pdf_data)) |xref_mut| {
		var xref = xref_mut;
		defer xref.deinit(allocator);
		var iter = xref.entries.valueIterator();
		while (iter.next()) |entry| {
			if (!entry.in_use) continue;
			const off = std.math.cast(usize, entry.offset) orelse continue;
			if (off >= pdf_data.len) continue;
			if (parseObjectForFlate(pdf_data, off, entry.obj_num)) |fs| {
				if (fs.flate_first) {
					try out.append(allocator, fs);
				}
			}
		}
		return out.toOwnedSlice(allocator);
	}

	// Linear fallback: scan for "N G obj" patterns.
	var i: usize = 0;
	while (i + 3 <= pdf_data.len) : (i += 1) {
		if (!(pdf_data[i] == 'o' and std.mem.eql(u8, pdf_data[i .. i + 3], "obj"))) {
			continue;
		}
		if (i == 0) continue;
		if (!isWhitespace(pdf_data[i - 1])) continue;

		const obj_num = parseObjNumBeforeObj(pdf_data, i) orelse continue;
		const obj_start = locateObjStart(pdf_data, i);
		if (parseObjectForFlate(pdf_data, obj_start, obj_num)) |fs| {
			if (fs.flate_first) {
				try out.append(allocator, fs);
			}
		}
		i += 2;
	}

	return out.toOwnedSlice(allocator);
}

fn isWhitespace(c: u8) bool {
	return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0;
}

/// Given position of "obj", walk back to pull the object number.
fn parseObjNumBeforeObj(data: []const u8, obj_kw: usize) ?u32 {
	var p = obj_kw;
	while (p > 0 and isWhitespace(data[p - 1])) : (p -= 1) {}
	const gen_end = p;
	while (p > 0 and data[p - 1] >= '0' and data[p - 1] <= '9') : (p -= 1) {}
	if (p == gen_end) return null;
	while (p > 0 and isWhitespace(data[p - 1])) : (p -= 1) {}
	const obj_end = p;
	while (p > 0 and data[p - 1] >= '0' and data[p - 1] <= '9') : (p -= 1) {}
	if (p == obj_end) return null;
	const obj_str = data[p..obj_end];
	return std.fmt.parseInt(u32, obj_str, 10) catch null;
}

/// Locate the starting offset of the "N G obj" preamble given the position of
/// "obj". Returns the offset of the object number.
fn locateObjStart(data: []const u8, obj_kw: usize) usize {
	var p = obj_kw;
	while (p > 0 and isWhitespace(data[p - 1])) : (p -= 1) {}
	while (p > 0 and data[p - 1] >= '0' and data[p - 1] <= '9') : (p -= 1) {}
	while (p > 0 and isWhitespace(data[p - 1])) : (p -= 1) {}
	while (p > 0 and data[p - 1] >= '0' and data[p - 1] <= '9') : (p -= 1) {}
	return p;
}

// ---------------------------------------------------------------------------
// Per-object dictionary walker
// ---------------------------------------------------------------------------

/// Parse an indirect object starting at `offset` (pointing at "N G obj" or at
/// the object number). Returns a FlateStream if the object has a stream whose
/// decode chain begins with /FlateDecode. Returns null if the object is not a
/// stream object, has no Flate filter, or the preamble is malformed.
fn parseObjectForFlate(data: []const u8, offset: usize, obj_num: u32) ?FlateStream {
	var j = offset;
	if (j >= data.len) return null;

	// Skip "N G obj"
	j = skipDigits(data, j);
	j = skipWs(data, j);
	j = skipDigits(data, j);
	j = skipWs(data, j);
	if (j + 3 > data.len) return null;
	if (!std.mem.eql(u8, data[j .. j + 3], "obj")) return null;
	j += 3;

	var stream_length: ?u32 = null;
	var flate_first: bool = false;
	var saw_filter: bool = false;
	var stream_start: ?usize = null;
	var stream_end: ?usize = null;

	// Parse dictionary entries until we hit "stream" or "endobj"
	while (j < data.len) {
		j = skipWs(data, j);
		if (j >= data.len) break;

		// Detect "stream" (not preceded by "end")
		if (j + 6 <= data.len and std.mem.eql(u8, data[j .. j + 6], "stream") and
			(j < 3 or !std.mem.eql(u8, data[j - 3 .. j], "end")))
		{
			j += 6;
			if (j < data.len and data[j] == '\r') j += 1;
			if (j < data.len and data[j] == '\n') j += 1;
			stream_start = j;

			if (stream_length) |len| {
				var end: usize = j + len;
				if (end > data.len) end = data.len;
				stream_end = end;
			} else {
				// Length unknown (indirect reference) — search for "endstream".
				var k = j;
				while (k + 9 <= data.len) : (k += 1) {
					if (std.mem.eql(u8, data[k .. k + 9], "endstream")) {
						stream_end = k;
						break;
					}
				}
			}
			break;
		}

		// Detect "endobj"
		if (j + 6 <= data.len and std.mem.eql(u8, data[j .. j + 6], "endobj")) break;

		// Dictionary entry
		if (data[j] == '/') {
			const name_end = findNameEnd(data, j + 1);
			const name = data[j + 1 .. name_end];
			j = name_end;

			if (std.mem.eql(u8, name, "Filter")) {
				saw_filter = true;
				j = skipWs(data, j);
				if (j >= data.len) continue;
				if (data[j] == '/') {
					// Single filter
					const first_end = findNameEnd(data, j + 1);
					const first_name = data[j + 1 .. first_end];
					flate_first = std.mem.eql(u8, first_name, "FlateDecode") or
						std.mem.eql(u8, first_name, "Fl");
					j = first_end;
				} else if (data[j] == '[') {
					// Array of filters — only the first (outermost) matters.
					j += 1;
					j = skipWs(data, j);
					if (j < data.len and data[j] == '/') {
						const first_end = findNameEnd(data, j + 1);
						const first_name = data[j + 1 .. first_end];
						flate_first = std.mem.eql(u8, first_name, "FlateDecode") or
							std.mem.eql(u8, first_name, "Fl");
						j = first_end;
					}
					while (j < data.len and data[j] != ']') : (j += 1) {}
					if (j < data.len) j += 1;
				}
			} else if (std.mem.eql(u8, name, "Length")) {
				j = skipWs(data, j);
				if (j < data.len and data[j] >= '0' and data[j] <= '9') {
					const len_start = j;
					while (j < data.len and data[j] >= '0' and data[j] <= '9') : (j += 1) {}
					const len_end = j;
					// Distinguish "NNN" from "NNN 0 R" (indirect reference)
					var la = skipWs(data, j);
					var indirect = false;
					if (la < data.len and data[la] >= '0' and data[la] <= '9') {
						while (la < data.len and data[la] >= '0' and data[la] <= '9') : (la += 1) {}
						la = skipWs(data, la);
						if (la < data.len and data[la] == 'R') indirect = true;
					}
					if (!indirect) {
						stream_length = std.fmt.parseInt(u32, data[len_start..len_end], 10) catch null;
					}
				}
			}
		} else {
			j += 1;
		}
	}

	if (!saw_filter or !flate_first) return null;
	if (stream_start == null or stream_end == null) return null;

	return .{
		.object_num = obj_num,
		.stream_start = stream_start.?,
		.stream_end = stream_end.?,
		.flate_first = true,
	};
}

fn skipWs(data: []const u8, start: usize) usize {
	var i = start;
	while (i < data.len) {
		switch (data[i]) {
			' ', '\t', '\n', '\r', '\x0c', '\x00' => i += 1,
			'%' => {
				while (i < data.len and data[i] != '\n' and data[i] != '\r') : (i += 1) {}
			},
			else => break,
		}
	}
	return i;
}

fn skipDigits(data: []const u8, start: usize) usize {
	var i = start;
	while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
	return i;
}

fn findNameEnd(data: []const u8, start: usize) usize {
	var i = start;
	while (i < data.len) {
		const c = data[i];
		if (c == '/' or c == '[' or c == ']' or c == '<' or c == '>' or
			c == '(' or c == ')' or c == '{' or c == '}' or
			c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0c')
		{
			break;
		}
		i += 1;
	}
	return i;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "zlibErrorReason maps known data errors to descriptive strings" {
	try testing.expect(zlibErrorReason(zlib.ZlibError.DataError).len > 0);
	try testing.expect(zlibErrorReason(zlib.ZlibError.UnexpectedEof).len > 0);
	try testing.expect(zlibErrorReason(zlib.ZlibError.ZlibError).len > 0);
}

test "findFlateStreams returns empty for non-PDF bytes" {
	const data = "not a pdf";
	const streams = try findFlateStreams(testing.allocator, data);
	defer testing.allocator.free(streams);
	try testing.expectEqual(@as(usize, 0), streams.len);
}

test "parseObjectForFlate detects single-filter FlateDecode stream" {
	const payload = "\x78\x9c\x01\x00\x00\x00\x01\x00";
	const obj =
		"1 0 obj\n" ++
		"<< /Length 8 /Filter /FlateDecode >>\n" ++
		"stream\n" ++
		payload ++
		"\nendstream\nendobj\n";
	const res = parseObjectForFlate(obj, 0, 1);
	try testing.expect(res != null);
	try testing.expectEqual(@as(u32, 1), res.?.object_num);
	try testing.expect(res.?.flate_first);
	try testing.expectEqualStrings(payload, obj[res.?.stream_start..res.?.stream_end]);
}

test "parseObjectForFlate detects array-filter chain starting with FlateDecode" {
	const payload = "abcdefgh";
	const obj =
		"2 0 obj\n" ++
		"<< /Length 8 /Filter [ /FlateDecode /ASCIIHexDecode ] >>\n" ++
		"stream\n" ++
		payload ++
		"\nendstream\nendobj\n";
	const res = parseObjectForFlate(obj, 0, 2);
	try testing.expect(res != null);
	try testing.expect(res.?.flate_first);
}

test "parseObjectForFlate ignores non-Flate filters" {
	const payload = "xyzxyzxy";
	const obj =
		"3 0 obj\n" ++
		"<< /Length 8 /Filter /DCTDecode >>\n" ++
		"stream\n" ++
		payload ++
		"\nendstream\nendobj\n";
	const res = parseObjectForFlate(obj, 0, 3);
	try testing.expect(res == null or !res.?.flate_first);
}

test "validatePdfFlateStreams: valid Flate stream passes" {
	const allocator = testing.allocator;
	const payload_text = "Hello, world. Hello, world. Hello, world.";
	const compressed = try zlib.deflateZlib(allocator, payload_text);
	defer allocator.free(compressed);

	var pdf: std.ArrayListUnmanaged(u8) = .{};
	defer pdf.deinit(allocator);
	try pdf.appendSlice(allocator, "%PDF-1.4\n");
	try pdf.writer(allocator).print(
		"1 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n",
		.{compressed.len},
	);
	try pdf.appendSlice(allocator, compressed);
	try pdf.appendSlice(allocator, "\nendstream\nendobj\n");
	try pdf.appendSlice(allocator, "%%EOF\n");

	var empty: std.AutoHashMapUnmanaged(u32, void) = .{};
	defer empty.deinit(allocator);

	const result = validatePdfFlateStreams(allocator, pdf.items, &empty);
	try testing.expect(result.valid);
	try testing.expectEqual(@as(u32, 1), result.total_flate_streams);
	try testing.expectEqual(@as(u32, 1), result.validated);
	try testing.expectEqual(@as(u32, 0), result.failed);
}

test "validatePdfFlateStreams: corrupted Flate stream fails" {
	const allocator = testing.allocator;
	const payload_text = "Hello, world. Hello, world. Hello, world.";
	const compressed_orig = try zlib.deflateZlib(allocator, payload_text);
	defer allocator.free(compressed_orig);

	const compressed = try allocator.dupe(u8, compressed_orig);
	defer allocator.free(compressed);
	// Flip a byte mid-stream. The lenient validator (which we now use)
	// accepts the Adobe-InDesign missing-Adler-32 quirk, but it requires
	// <4 trailing bytes after Z_STREAM_END for that recovery path to
	// engage. Mid-body corruption with the original full Adler-32 trailer
	// in place looks to the lenient path like a stream that should have
	// been self-checking — so it correctly returns data_error here.
	if (compressed.len > 4) compressed[compressed.len / 2] ^= 0xFF;

	var pdf: std.ArrayListUnmanaged(u8) = .{};
	defer pdf.deinit(allocator);
	try pdf.appendSlice(allocator, "%PDF-1.4\n");
	try pdf.writer(allocator).print(
		"1 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n",
		.{compressed.len},
	);
	try pdf.appendSlice(allocator, compressed);
	try pdf.appendSlice(allocator, "\nendstream\nendobj\n");
	try pdf.appendSlice(allocator, "%%EOF\n");

	var empty: std.AutoHashMapUnmanaged(u32, void) = .{};
	defer empty.deinit(allocator);

	const result = validatePdfFlateStreams(allocator, pdf.items, &empty);
	try testing.expect(!result.valid);
	try testing.expectEqual(@as(u32, 1), result.total_flate_streams);
	try testing.expectEqual(@as(u32, 1), result.failed);
	try testing.expect(result.first_failure != null);
}

test "validatePdfFlateStreams: excluded object numbers are skipped" {
	const allocator = testing.allocator;
	const payload_text = "abc abc abc abc abc";
	const compressed = try zlib.deflateZlib(allocator, payload_text);
	defer allocator.free(compressed);

	var pdf: std.ArrayListUnmanaged(u8) = .{};
	defer pdf.deinit(allocator);
	try pdf.appendSlice(allocator, "%PDF-1.4\n");
	try pdf.writer(allocator).print(
		"1 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n",
		.{compressed.len},
	);
	try pdf.appendSlice(allocator, compressed);
	try pdf.appendSlice(allocator, "\nendstream\nendobj\n");
	try pdf.appendSlice(allocator, "%%EOF\n");

	var seen: std.AutoHashMapUnmanaged(u32, void) = .{};
	defer seen.deinit(allocator);
	try seen.put(allocator, 1, {});

	const result = validatePdfFlateStreams(allocator, pdf.items, &seen);
	try testing.expect(result.valid);
	try testing.expectEqual(@as(u32, 1), result.total_flate_streams);
	try testing.expectEqual(@as(u32, 0), result.validated);
	try testing.expectEqual(@as(u32, 1), result.skipped_already_validated);
}
