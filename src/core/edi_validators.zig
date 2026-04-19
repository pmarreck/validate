const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const ValidationDepth = format_validation.ValidationDepth;
const FileFormat = format_validation.FileFormat;

// ─── X12 EDI ────────────────────────────────────────────────────────────────────

/// Structural validation of X12 EDI files.
/// Verifies the ISA segment header: fixed 106 characters with self-describing delimiters.
pub fn validateX12Edi(file: *FileSource) ValidationResult {
	var buf: [4096]u8 = undefined;
	const bytes_read = file.read(&buf) catch {
		return ValidationResult.invalid(.x12_edi, "Failed to read file");
	};
	if (bytes_read < 106) {
		return ValidationResult.invalid(.x12_edi, "File too short for ISA segment (minimum 106 bytes)");
	}
	const data = buf[0..bytes_read];
	return validateX12EdiFromBuffer(data);
}

/// Structural validation of X12 EDI from a buffer.
fn validateX12EdiFromBuffer(data: []const u8) ValidationResult {
	if (data.len < 106) {
		return ValidationResult.invalid(.x12_edi, "Data too short for ISA segment (minimum 106 bytes)");
	}

	// Must start with "ISA"
	if (!std.mem.eql(u8, data[0..3], "ISA")) {
		return ValidationResult.invalid(.x12_edi, "Missing ISA segment identifier");
	}

	// Element delimiter is byte at position 3 (self-describing)
	const elem_delim = data[3];

	// Segment terminator is byte at position 105
	const seg_term = data[105];

	// Validate the ISA segment has exactly 16 elements separated by elem_delim
	// ISA segment: ISA + 16 elements + segment terminator = 106 chars
	var elem_count: u32 = 0;
	var i: usize = 3; // Start after "ISA"
	while (i < 106) : (i += 1) {
		if (data[i] == elem_delim) {
			elem_count += 1;
		}
	}

	if (elem_count != 16) {
		return ValidationResult.invalid(.x12_edi, "Expected 16 element delimiters in ISA segment");
	}

	// Verify segment terminates at position 105
	if (data[105] != seg_term) {
		return ValidationResult.invalid(.x12_edi, "ISA segment terminator mismatch at position 105");
	}

	return ValidationResult.okWithDepth(.x12_edi, .structural);
}

/// Deep validation of X12 EDI: verifies envelope hierarchy and control totals.
pub fn validateX12EdiDeep(allocator: Allocator, path: []const u8) ValidationResult {
	var source = FileSource.open(path) catch {
		return ValidationResult.invalid(.x12_edi, "Failed to open file");
	};
	defer source.close();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalid(.x12_edi, "Failed to stat file");
	};

	if (file_sz < 106) {
		return ValidationResult.invalid(.x12_edi, "File too short for ISA segment");
	}

	// Cap at 10MB for safety
	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.x12_edi, "File too large for deep validation (>10MB)");
	}

	var heap_edi1: ?[]u8 = null;
	defer if (heap_edi1) |buf| allocator.free(buf);
	const data: []const u8 = if (source.getMappedSlice()) |m| m else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch {
			return ValidationResult.invalid(.x12_edi, "Out of memory");
		};
		heap_edi1 = buf;
		const n = source.readAll(buf) catch {
			return ValidationResult.invalid(.x12_edi, "Failed to read file");
		};
		break :blk buf[0..n];
	};

	if (data.len < 106) {
		return ValidationResult.invalid(.x12_edi, "Incomplete read");
	}

	return validateX12EdiDeepFromBuffer(data);
}

/// Deep validation of X12 EDI from a buffer.
fn validateX12EdiDeepFromBuffer(data: []const u8) ValidationResult {
	// First do structural validation
	const structural = validateX12EdiFromBuffer(data);
	if (!structural.is_valid) return structural;

	// Extract delimiters from ISA segment
	const elem_delim = data[3];
	const seg_term = data[105];
	// Sub-element delimiter is ISA16 (byte at position 104)

	// Extract ISA13 (interchange control number) — field 13, between delimiters 12 and 13
	const isa13 = extractX12Field(data[0..106], elem_delim, 13) orelse {
		return ValidationResult.invalid(.x12_edi, "Cannot extract ISA13 control number");
	};

	// Parse all segments after ISA
	var pos: usize = 106;
	// Skip optional segment terminator suffix (CR, LF)
	while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}

	var gs_count: u32 = 0; // Count of GS-GE groups
	var st_count: u32 = 0; // Count of ST-SE transaction sets within current GS
	var seg_count: u32 = 0; // Count of segments within current ST (including ST and SE)
	var in_gs = false;
	var in_st = false;
	var current_gs06: ?[]const u8 = null;
	var current_st02: ?[]const u8 = null;

	while (pos < data.len) {
		// Find segment terminator
		const seg_start = pos;
		while (pos < data.len and data[pos] != seg_term) : (pos += 1) {}
		if (pos >= data.len) break;

		const segment = data[seg_start..pos];
		pos += 1; // Skip segment terminator
		// Skip optional CR/LF after segment terminator
		while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}

		if (segment.len < 2) continue;

		// Get segment ID (up to first elem_delim or end of segment)
		const id_end = std.mem.indexOfScalar(u8, segment, elem_delim) orelse segment.len;
		const seg_id = segment[0..id_end];

		if (std.mem.eql(u8, seg_id, "GS")) {
			if (in_gs) {
				return ValidationResult.invalid(.x12_edi, "Nested GS segment (missing GE)");
			}
			in_gs = true;
			st_count = 0;
			current_gs06 = extractX12FieldFromSeg(segment, elem_delim, 6);
		} else if (std.mem.eql(u8, seg_id, "ST")) {
			if (!in_gs) {
				return ValidationResult.invalid(.x12_edi, "ST segment outside GS envelope");
			}
			if (in_st) {
				return ValidationResult.invalid(.x12_edi, "Nested ST segment (missing SE)");
			}
			in_st = true;
			seg_count = 1; // Count ST itself
			current_st02 = extractX12FieldFromSeg(segment, elem_delim, 2);
		} else if (std.mem.eql(u8, seg_id, "SE")) {
			if (!in_st) {
				return ValidationResult.invalid(.x12_edi, "SE segment without matching ST");
			}
			seg_count += 1; // Count SE itself

			// SE01 = segment count (ST to SE inclusive)
			if (extractX12FieldFromSeg(segment, elem_delim, 1)) |se01_str| {
				const se01 = std.fmt.parseInt(u32, se01_str, 10) catch {
					return ValidationResult.invalid(.x12_edi, "SE01 is not a valid number");
				};
				if (se01 != seg_count) {
					return ValidationResult.invalid(.x12_edi, "SE01 segment count does not match actual count");
				}
			}

			// SE02 must match ST02
			if (extractX12FieldFromSeg(segment, elem_delim, 2)) |se02| {
				if (current_st02) |st02| {
					if (!std.mem.eql(u8, se02, st02)) {
						return ValidationResult.invalid(.x12_edi, "SE02 control number does not match ST02");
					}
				}
			}

			in_st = false;
			st_count += 1;
			seg_count = 0;
		} else if (std.mem.eql(u8, seg_id, "GE")) {
			if (!in_gs) {
				return ValidationResult.invalid(.x12_edi, "GE segment without matching GS");
			}
			if (in_st) {
				return ValidationResult.invalid(.x12_edi, "GE segment while ST is still open (missing SE)");
			}

			// GE01 = count of ST-SE transaction sets
			if (extractX12FieldFromSeg(segment, elem_delim, 1)) |ge01_str| {
				const ge01 = std.fmt.parseInt(u32, ge01_str, 10) catch {
					return ValidationResult.invalid(.x12_edi, "GE01 is not a valid number");
				};
				if (ge01 != st_count) {
					return ValidationResult.invalid(.x12_edi, "GE01 transaction set count does not match actual count");
				}
			}

			// GE02 must match GS06
			if (extractX12FieldFromSeg(segment, elem_delim, 2)) |ge02| {
				if (current_gs06) |gs06| {
					if (!std.mem.eql(u8, ge02, gs06)) {
						return ValidationResult.invalid(.x12_edi, "GE02 control number does not match GS06");
					}
				}
			}

			in_gs = false;
			gs_count += 1;
		} else if (std.mem.eql(u8, seg_id, "IEA")) {
			// IEA01 = count of GS-GE functional groups
			if (extractX12FieldFromSeg(segment, elem_delim, 1)) |iea01_str| {
				const iea01 = std.fmt.parseInt(u32, iea01_str, 10) catch {
					return ValidationResult.invalid(.x12_edi, "IEA01 is not a valid number");
				};
				if (iea01 != gs_count) {
					return ValidationResult.invalid(.x12_edi, "IEA01 group count does not match actual count");
				}
			}

			// IEA02 must match ISA13
			if (extractX12FieldFromSeg(segment, elem_delim, 2)) |iea02| {
				if (!std.mem.eql(u8, std.mem.trim(u8, iea02, " "), std.mem.trim(u8, isa13, " "))) {
					return ValidationResult.invalid(.x12_edi, "IEA02 control number does not match ISA13");
				}
			}
		} else {
			// Regular data segment
			if (in_st) {
				seg_count += 1;
			}
		}
	}

	if (in_st) {
		return ValidationResult.invalid(.x12_edi, "Unterminated ST transaction set (missing SE)");
	}
	if (in_gs) {
		return ValidationResult.invalid(.x12_edi, "Unterminated GS functional group (missing GE)");
	}
	if (gs_count == 0) {
		return ValidationResult.invalid(.x12_edi, "No GS-GE functional groups found");
	}

	return ValidationResult.okWithDepth(.x12_edi, .full);
}

/// Extract field N (1-based) from ISA segment using element delimiter.
fn extractX12Field(isa: []const u8, delim: u8, field_num: u32) ?[]const u8 {
	return extractX12FieldFromSeg(isa, delim, field_num);
}

/// Extract field N (1-based) from any X12 segment using element delimiter.
fn extractX12FieldFromSeg(segment: []const u8, delim: u8, field_num: u32) ?[]const u8 {
	var count: u32 = 0;
	var start: usize = 0;
	for (segment, 0..) |byte, i| {
		if (byte == delim) {
			count += 1;
			if (count == field_num) {
				start = i + 1;
			} else if (count == field_num + 1) {
				return segment[start..i];
			}
		}
	}
	// Last field (no trailing delimiter)
	if (count == field_num and start < segment.len) {
		return segment[start..];
	}
	return null;
}

// ─── EDIFACT ────────────────────────────────────────────────────────────────────

/// EDIFACT delimiter set parsed from UNA service string advice or defaults.
const EdifactDelimiters = struct {
	component_sep: u8, // Default: ':'
	element_sep: u8, // Default: '+'
	decimal_mark: u8, // Default: '.'
	escape_char: u8, // Default: '?'
	segment_term: u8, // Default: '\''
};

const default_edifact_delimiters = EdifactDelimiters{
	.component_sep = ':',
	.element_sep = '+',
	.decimal_mark = '.',
	.escape_char = '?',
	.segment_term = '\'',
};

/// Structural validation of EDIFACT files.
/// Verifies UNA/UNB header and basic segment structure.
pub fn validateEdifact(file: *FileSource) ValidationResult {
	var buf: [4096]u8 = undefined;
	const bytes_read = file.read(&buf) catch {
		return ValidationResult.invalid(.edifact, "Failed to read file");
	};
	if (bytes_read < 4) {
		return ValidationResult.invalid(.edifact, "File too short for EDIFACT");
	}
	const data = buf[0..bytes_read];
	return validateEdifactFromBuffer(data);
}

/// Structural validation of EDIFACT from a buffer.
fn validateEdifactFromBuffer(data: []const u8) ValidationResult {
	if (data.len < 4) {
		return ValidationResult.invalid(.edifact, "Data too short for EDIFACT");
	}

	var delims = default_edifact_delimiters;
	var pos: usize = 0;

	// Parse UNA service string advice if present
	if (data.len >= 9 and std.mem.eql(u8, data[0..3], "UNA")) {
		delims.component_sep = data[3];
		delims.element_sep = data[4];
		delims.decimal_mark = data[5];
		delims.escape_char = data[6];
		// data[7] is reserved
		delims.segment_term = data[8];
		pos = 9;
		// Skip optional CR/LF after UNA
		while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}
	}

	// Must find UNB segment
	if (pos + 4 > data.len) {
		return ValidationResult.invalid(.edifact, "No UNB segment found");
	}

	if (!std.mem.eql(u8, data[pos..][0..3], "UNB")) {
		return ValidationResult.invalid(.edifact, "Expected UNB segment after UNA");
	}

	if (data[pos + 3] != delims.element_sep) {
		return ValidationResult.invalid(.edifact, "UNB segment missing element separator");
	}

	// Find end of UNB segment
	var unb_end = pos + 4;
	while (unb_end < data.len and data[unb_end] != delims.segment_term) : (unb_end += 1) {}

	if (unb_end >= data.len) {
		return ValidationResult.invalid(.edifact, "UNB segment not terminated");
	}

	return ValidationResult.okWithDepth(.edifact, .structural);
}

/// Deep validation of EDIFACT: verifies envelope hierarchy and control totals.
pub fn validateEdifactDeep(allocator: Allocator, path: []const u8) ValidationResult {
	var source = FileSource.open(path) catch {
		return ValidationResult.invalid(.edifact, "Failed to open file");
	};
	defer source.close();

	const file_sz = source.getEndPos() catch {
		return ValidationResult.invalid(.edifact, "Failed to stat file");
	};

	if (file_sz < 4) {
		return ValidationResult.invalid(.edifact, "File too short for EDIFACT");
	}

	if (file_sz > 10 * 1024 * 1024) {
		return ValidationResult.invalid(.edifact, "File too large for deep validation (>10MB)");
	}

	var heap_edi2: ?[]u8 = null;
	defer if (heap_edi2) |buf| allocator.free(buf);
	const data: []const u8 = if (source.getMappedSlice()) |m| m else blk: {
		const buf = allocator.alloc(u8, @intCast(file_sz)) catch {
			return ValidationResult.invalid(.edifact, "Out of memory");
		};
		heap_edi2 = buf;
		const n = source.readAll(buf) catch {
			return ValidationResult.invalid(.edifact, "Failed to read file");
		};
		break :blk buf[0..n];
	};

	return validateEdifactDeepFromBuffer(data);
}

/// Deep validation of EDIFACT from a buffer.
fn validateEdifactDeepFromBuffer(data: []const u8) ValidationResult {
	// First do structural validation
	const structural = validateEdifactFromBuffer(data);
	if (!structural.is_valid) return structural;

	var delims = default_edifact_delimiters;
	var pos: usize = 0;

	// Parse UNA if present
	if (data.len >= 9 and std.mem.eql(u8, data[0..3], "UNA")) {
		delims.component_sep = data[3];
		delims.element_sep = data[4];
		delims.decimal_mark = data[5];
		delims.escape_char = data[6];
		delims.segment_term = data[8];
		pos = 9;
		while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}
	}

	// Extract UNB reference number (last element before segment terminator)
	const unb_start = pos;
	var unb_end = unb_start;
	while (unb_end < data.len and data[unb_end] != delims.segment_term) : (unb_end += 1) {}
	if (unb_end >= data.len) {
		return ValidationResult.invalid(.edifact, "UNB segment not terminated");
	}

	const unb_seg = data[unb_start..unb_end];
	const unb_ref = extractEdifactLastField(unb_seg, delims.element_sep);

	pos = unb_end + 1;
	while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}

	var unh_count: u32 = 0; // Message count
	var seg_count: u32 = 0; // Segment count within current UNH
	var in_ung = false;
	var in_unh = false;
	var ung_msg_count: u32 = 0;
	var current_unh_ref: ?[]const u8 = null;
	var group_count: u32 = 0; // Count of UNG-UNE groups or bare messages

	while (pos < data.len) {
		const seg_start = pos;
		// Find segment terminator, respecting escape character
		while (pos < data.len) {
			if (data[pos] == delims.escape_char and pos + 1 < data.len) {
				pos += 2; // Skip escaped character
				continue;
			}
			if (data[pos] == delims.segment_term) break;
			pos += 1;
		}
		if (pos >= data.len) break;

		const segment = data[seg_start..pos];
		pos += 1; // Skip segment terminator
		while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) : (pos += 1) {}

		if (segment.len < 3) continue;

		// Get segment tag (up to first element separator)
		const tag_end = std.mem.indexOfScalar(u8, segment, delims.element_sep) orelse segment.len;
		const tag = segment[0..tag_end];

		if (std.mem.eql(u8, tag, "UNG")) {
			in_ung = true;
			ung_msg_count = 0;
		} else if (std.mem.eql(u8, tag, "UNH")) {
			if (in_unh) {
				return ValidationResult.invalid(.edifact, "Nested UNH (missing UNT)");
			}
			in_unh = true;
			seg_count = 1; // Count UNH itself
			current_unh_ref = extractEdifactField(segment, delims.element_sep, 1);
		} else if (std.mem.eql(u8, tag, "UNT")) {
			if (!in_unh) {
				return ValidationResult.invalid(.edifact, "UNT without matching UNH");
			}
			seg_count += 1; // Count UNT itself

			// UNT01 = segment count (UNH to UNT inclusive)
			if (extractEdifactField(segment, delims.element_sep, 1)) |unt01_str| {
				const unt01 = std.fmt.parseInt(u32, unt01_str, 10) catch {
					return ValidationResult.invalid(.edifact, "UNT segment count is not a valid number");
				};
				if (unt01 != seg_count) {
					return ValidationResult.invalid(.edifact, "UNT segment count does not match actual count");
				}
			}

			// UNT02 must match UNH reference
			if (extractEdifactField(segment, delims.element_sep, 2)) |unt02| {
				if (current_unh_ref) |unh_ref| {
					if (!std.mem.eql(u8, unt02, unh_ref)) {
						return ValidationResult.invalid(.edifact, "UNT reference does not match UNH reference");
					}
				}
			}

			in_unh = false;
			unh_count += 1;
			if (in_ung) {
				ung_msg_count += 1;
			}
		} else if (std.mem.eql(u8, tag, "UNE")) {
			if (!in_ung) {
				return ValidationResult.invalid(.edifact, "UNE without matching UNG");
			}

			// UNE01 = message count within group
			if (extractEdifactField(segment, delims.element_sep, 1)) |une01_str| {
				const une01 = std.fmt.parseInt(u32, une01_str, 10) catch {
					return ValidationResult.invalid(.edifact, "UNE message count is not a valid number");
				};
				if (une01 != ung_msg_count) {
					return ValidationResult.invalid(.edifact, "UNE message count does not match actual count");
				}
			}

			in_ung = false;
			group_count += 1;
		} else if (std.mem.eql(u8, tag, "UNZ")) {
			// UNZ01 = count of messages or groups
			if (extractEdifactField(segment, delims.element_sep, 1)) |unz01_str| {
				const unz01 = std.fmt.parseInt(u32, unz01_str, 10) catch {
					return ValidationResult.invalid(.edifact, "UNZ count is not a valid number");
				};
				// UNZ01 counts functional groups if UNG present, otherwise messages
				const expected = if (group_count > 0) group_count else unh_count;
				if (unz01 != expected) {
					return ValidationResult.invalid(.edifact, "UNZ count does not match actual count");
				}
			}

			// UNZ02 must match UNB reference
			if (extractEdifactField(segment, delims.element_sep, 2)) |unz02| {
				if (unb_ref) |ref| {
					if (!std.mem.eql(u8, std.mem.trim(u8, unz02, " "), std.mem.trim(u8, ref, " "))) {
						return ValidationResult.invalid(.edifact, "UNZ reference does not match UNB reference");
					}
				}
			}
		} else {
			if (in_unh) {
				seg_count += 1;
			}
		}
	}

	if (in_unh) {
		return ValidationResult.invalid(.edifact, "Unterminated UNH message (missing UNT)");
	}
	if (in_ung) {
		return ValidationResult.invalid(.edifact, "Unterminated UNG group (missing UNE)");
	}
	if (unh_count == 0) {
		return ValidationResult.invalid(.edifact, "No UNH-UNT messages found");
	}

	return ValidationResult.okWithDepth(.edifact, .full);
}

/// Extract field N (1-based) from an EDIFACT segment using element separator.
fn extractEdifactField(segment: []const u8, elem_sep: u8, field_num: u32) ?[]const u8 {
	var count: u32 = 0;
	var start: usize = 0;
	for (segment, 0..) |byte, i| {
		if (byte == elem_sep) {
			count += 1;
			if (count == field_num) {
				start = i + 1;
			} else if (count == field_num + 1) {
				return segment[start..i];
			}
		}
	}
	if (count == field_num and start < segment.len) {
		return segment[start..];
	}
	return null;
}

/// Extract the last element-separator-delimited field from a segment.
fn extractEdifactLastField(segment: []const u8, elem_sep: u8) ?[]const u8 {
	var last_sep: ?usize = null;
	for (segment, 0..) |byte, i| {
		if (byte == elem_sep) {
			last_sep = i;
		}
	}
	if (last_sep) |sep_pos| {
		if (sep_pos + 1 < segment.len) {
			return segment[sep_pos + 1 ..];
		}
	}
	return null;
}

// ─── Tests ──────────────────────────────────────────────────────────────────────

test "X12 EDI structural: valid ISA segment" {
	const x12_data =
		"ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*U*00501*000000001*0*P*:~" ++
		"GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
		"ST*837*0001~" ++
		"BHT*0019*00*12345*20200101*1200*CH~" ++
		"SE*3*0001~" ++
		"GE*1*1~" ++
		"IEA*1*000000001~";

	const result = validateX12EdiFromBuffer(x12_data);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.x12_edi, result.format);
	try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "X12 EDI deep: control totals match" {
	const x12_data =
		"ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*U*00501*000000001*0*P*:~" ++
		"GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
		"ST*837*0001~" ++
		"SE*2*0001~" ++
		"GE*1*1~" ++
		"IEA*1*000000001~";

	const result = validateX12EdiDeepFromBuffer(x12_data);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.x12_edi, result.format);
	try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "X12 EDI deep: control total mismatch detected" {
	const x12_data =
		"ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *200101*1200*U*00501*000000001*0*P*:~" ++
		"GS*HP*SENDER*RECEIVER*20200101*1200*1*X*005010X222A1~" ++
		"ST*837*0001~" ++
		"SE*99*0001~" ++ // Wrong segment count
		"GE*1*1~" ++
		"IEA*1*000000001~";

	const result = validateX12EdiDeepFromBuffer(x12_data);
	try std.testing.expect(!result.is_valid);
}

test "EDIFACT structural: valid UNA+UNB" {
	const edifact_data =
		"UNA:+.? '" ++
		"UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000000001'" ++
		"UNH+1+INVOIC:D:96A:UN'" ++
		"BGM+380+INV001+9'" ++
		"UNT+3+1'" ++
		"UNZ+1+00000000001'";

	const result = validateEdifactFromBuffer(edifact_data);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.edifact, result.format);
	try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "EDIFACT deep: UNT/UNZ counts match" {
	const edifact_data =
		"UNA:+.? '" ++
		"UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000000001'" ++
		"UNH+1+INVOIC:D:96A:UN'" ++
		"BGM+380+INV001+9'" ++
		"UNT+3+1'" ++
		"UNZ+1+00000000001'";

	const result = validateEdifactDeepFromBuffer(edifact_data);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.edifact, result.format);
	try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "EDIFACT deep: UNT count mismatch detected" {
	const edifact_data =
		"UNA:+.? '" ++
		"UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000000001'" ++
		"UNH+1+INVOIC:D:96A:UN'" ++
		"BGM+380+INV001+9'" ++
		"UNT+99+1'" ++ // Wrong segment count
		"UNZ+1+00000000001'";

	const result = validateEdifactDeepFromBuffer(edifact_data);
	try std.testing.expect(!result.is_valid);
}

test "EDIFACT structural: UNB without UNA uses default delimiters" {
	const edifact_data =
		"UNB+UNOC:3+SENDER+RECEIVER+200101:1200+00000000001'" ++
		"UNH+1+ORDERS:D:96A:UN'" ++
		"BGM+220+PO001+9'" ++
		"UNT+3+1'" ++
		"UNZ+1+00000000001'";

	const result = validateEdifactFromBuffer(edifact_data);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.edifact, result.format);
}

test "X12 EDI structural: invalid - file too short" {
	const result = validateX12EdiFromBuffer("ISA*short");
	try std.testing.expect(!result.is_valid);
}
