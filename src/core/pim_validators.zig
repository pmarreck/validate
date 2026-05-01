const std = @import("std");
const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const Allocator = std.mem.Allocator;

/// Known iCalendar component types per RFC 5545 + common extensions.
const known_ical_components = [_][]const u8{
	"VCALENDAR",
	"VEVENT",
	"VTODO",
	"VJOURNAL",
	"VFREEBUSY",
	"VTIMEZONE",
	"VALARM",
	"STANDARD",
	"DAYLIGHT",
};

/// Check if a component name is a known iCalendar component type.
fn isKnownIcalComponent(name: []const u8) bool {
	for (known_ical_components) |known| {
		if (std.mem.eql(u8, name, known)) return true;
	}
	return false;
}

/// Skip optional UTF-8 BOM (EF BB BF) and leading whitespace.
/// Returns the index of the first non-BOM, non-whitespace byte.
fn skipBomAndWhitespace(data: []const u8) usize {
	var i: usize = 0;
	// Skip UTF-8 BOM
	if (data.len >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF) {
		i = 3;
	}
	// Skip whitespace
	while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\r' or data[i] == '\n')) {
		i += 1;
	}
	return i;
}

/// Iterator over content lines in iCalendar/vCard data.
/// Handles both CRLF and bare LF line endings, and line folding (RFC 5545 §3.1).
const LineIterator = struct {
	data: []const u8,
	pos: usize,

	fn init(data: []const u8) LineIterator {
		return .{ .data = data, .pos = 0 };
	}

	/// Returns the next unfolded content line, or null at end of data.
	fn next(self: *LineIterator) ?[]const u8 {
		if (self.pos >= self.data.len) return null;

		const start = self.pos;
		// Find end of logical line (handling folding: CRLF/LF followed by space/tab continues the line)
		var end = start;
		while (end < self.data.len) {
			if (self.data[end] == '\r' and end + 1 < self.data.len and self.data[end + 1] == '\n') {
				// CRLF — check for folding
				if (end + 2 < self.data.len and (self.data[end + 2] == ' ' or self.data[end + 2] == '\t')) {
					// Folded line — skip CRLF + whitespace and continue
					end += 3;
					continue;
				}
				self.pos = end + 2;
				return self.data[start..end];
			} else if (self.data[end] == '\n') {
				// Bare LF — check for folding
				if (end + 1 < self.data.len and (self.data[end + 1] == ' ' or self.data[end + 1] == '\t')) {
					end += 2;
					continue;
				}
				self.pos = end + 1;
				return self.data[start..end];
			}
			end += 1;
		}
		// Last line without trailing newline
		self.pos = end;
		if (end > start) return self.data[start..end];
		return null;
	}
};

/// Validates iCalendar structural integrity (RFC 5545).
/// Checks for BEGIN:VCALENDAR, VERSION:2.0, PRODID, and at least one component.
pub fn validateICalendar(file: *FileSource) ValidationResult {
	var buf: [8192]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.icalendar, .failed_to_seek, "iCalendar header");
	};
	const n = file.readAll(&buf) catch {
		return ValidationResult.invalidCode(.icalendar, .failed_to_read, "iCalendar header");
	};
	if (n == 0) {
		return ValidationResult.invalidCode(.icalendar, .file_too_small, "empty file");
	}
	const data = buf[0..n];

	// Skip BOM and whitespace
	const start = skipBomAndWhitespace(data);
	if (start >= data.len) {
		return ValidationResult.invalidCode(.icalendar, .file_too_small, "only whitespace/BOM");
	}

	// Must start with BEGIN:VCALENDAR
	const remaining = data[start..];
	if (!std.mem.startsWith(u8, remaining, "BEGIN:VCALENDAR")) {
		return ValidationResult.invalidCode(.icalendar, .invalid_magic, "missing BEGIN:VCALENDAR");
	}

	// Scan for VERSION:2.0
	var found_version = false;
	var found_prodid = false;
	var found_component = false;

	if (std.mem.indexOf(u8, data, "VERSION:2.0") != null or
		std.mem.indexOf(u8, data, "VERSION: 2.0") != null)
	{
		found_version = true;
	}

	if (std.mem.indexOf(u8, data, "PRODID:") != null) {
		found_prodid = true;
	}

	// Check for at least one component
	const components = [_][]const u8{ "BEGIN:VEVENT", "BEGIN:VTODO", "BEGIN:VJOURNAL", "BEGIN:VFREEBUSY", "BEGIN:VTIMEZONE" };
	for (components) |comp| {
		if (std.mem.indexOf(u8, data, comp) != null) {
			found_component = true;
			break;
		}
	}

	if (!found_version) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "missing VERSION:2.0");
	}
	if (!found_prodid) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "missing PRODID property");
	}
	if (!found_component) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "no VEVENT/VTODO/VJOURNAL/VFREEBUSY/VTIMEZONE component");
	}

	return ValidationResult.okWithDepth(.icalendar, .structural);
}

/// Validate a datetime string in iCalendar format.
/// Accepts: YYYYMMDD, YYYYMMDDTHHMMSS, YYYYMMDDTHHMMSSZ
fn isValidIcalDatetime(value: []const u8) bool {
	// Minimum: YYYYMMDD (8 chars)
	if (value.len < 8) return false;

	// Check date portion is all digits
	for (value[0..8]) |c| {
		if (c < '0' or c > '9') return false;
	}

	if (value.len == 8) return true; // YYYYMMDD

	// YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ
	if (value.len < 15) return false;
	if (value[8] != 'T') return false;

	for (value[9..15]) |c| {
		if (c < '0' or c > '9') return false;
	}

	if (value.len == 15) return true; // YYYYMMDDTHHMMSS
	if (value.len == 16 and value[15] == 'Z') return true; // YYYYMMDDTHHMMSSZ

	return false;
}

/// Deep validation for iCalendar files (RFC 5545).
/// Verifies balanced BEGIN/END nesting, known component types, datetime formats,
/// and proper VCALENDAR envelope.
pub fn validateICalendarDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_size = source.getEndPos() catch {
		return ValidationResult.invalidCode(.icalendar, .failed_to_read, "failed to get file size");
	};

	if (file_size == 0) {
		return ValidationResult.invalidCode(.icalendar, .file_too_small, "empty file");
	}

	// Cap at 10 MB for safety
	if (file_size > 10 * 1024 * 1024) {
		// Too large to read entirely — fall back to structural
		return ValidationResult.okWithDepth(.icalendar, .structural);
	}

	const slurp_ical = source.getMappedOrSlurp(allocator, 64 << 20) catch
		return ValidationResult.invalidCode(.icalendar, .failed_to_read, "failed to read file");
	var heap_pim1: ?[]u8 = null;
	defer if (heap_pim1) |b| allocator.free(b);
	const content: []const u8 = switch (slurp_ical) {
		.mapped => |m| m,
		.heap => |b| blk: { heap_pim1 = b; break :blk b; },
		.too_large => return ValidationResult.okWithDepth(.icalendar, .structural),
	};

	// Skip BOM and whitespace
	const start = skipBomAndWhitespace(content);
	if (start >= content.len) {
		return ValidationResult.invalidCode(.icalendar, .file_too_small, "only whitespace/BOM");
	}

	// Must start with BEGIN:VCALENDAR
	if (!std.mem.startsWith(u8, content[start..], "BEGIN:VCALENDAR")) {
		return ValidationResult.invalidCode(.icalendar, .invalid_magic, "missing BEGIN:VCALENDAR");
	}

	// Verify file ends with END:VCALENDAR (possibly followed by CRLF/LF/whitespace)
	const trimmed = std.mem.trimRight(u8, content, " \t\r\n");
	if (!std.mem.endsWith(u8, trimmed, "END:VCALENDAR")) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "missing END:VCALENDAR at end of file");
	}

	// Verify balanced BEGIN/END nesting and known component types
	var nesting_depth: usize = 0;
	var first_component_is_vcalendar = false;
	var lines = LineIterator.init(content[start..]);

	while (lines.next()) |line| {
		if (std.mem.startsWith(u8, line, "BEGIN:")) {
			const component_name = line[6..];
			// Strip any trailing CR for mixed line endings
			const clean_name = std.mem.trimRight(u8, component_name, "\r");
			if (!isKnownIcalComponent(clean_name)) {
				return ValidationResult.invalidCode(.icalendar, .invalid_value, "unknown component type");
			}
			if (nesting_depth == 0) {
				if (std.mem.eql(u8, clean_name, "VCALENDAR")) {
					first_component_is_vcalendar = true;
				} else {
					return ValidationResult.invalidCode(.icalendar, .invalid_value, "VCALENDAR must be outermost component");
				}
			}
			nesting_depth += 1;
		} else if (std.mem.startsWith(u8, line, "END:")) {
			if (nesting_depth == 0) {
				return ValidationResult.invalidCode(.icalendar, .invalid_value, "END without matching BEGIN");
			}
			nesting_depth -= 1;
		} else if (std.mem.startsWith(u8, line, "DTSTART:") or std.mem.startsWith(u8, line, "DTSTART;")) {
			// Validate datetime format for DTSTART
			if (std.mem.startsWith(u8, line, "DTSTART:")) {
				const dt_value = std.mem.trimRight(u8, line[8..], "\r");
				if (dt_value.len > 0 and !isValidIcalDatetime(dt_value)) {
					return ValidationResult.invalidCode(.icalendar, .invalid_value, "invalid DTSTART datetime format");
				}
			}
			// DTSTART;...VALUE=DATE:YYYYMMDD handled by property params, skip for now
		} else if (std.mem.startsWith(u8, line, "DTEND:") or std.mem.startsWith(u8, line, "DTEND;")) {
			if (std.mem.startsWith(u8, line, "DTEND:")) {
				const dt_value = std.mem.trimRight(u8, line[6..], "\r");
				if (dt_value.len > 0 and !isValidIcalDatetime(dt_value)) {
					return ValidationResult.invalidCode(.icalendar, .invalid_value, "invalid DTEND datetime format");
				}
			}
		}
	}

	if (nesting_depth != 0) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "unbalanced BEGIN/END nesting");
	}

	if (!first_component_is_vcalendar) {
		return ValidationResult.invalidCode(.icalendar, .invalid_value, "VCALENDAR must be outermost component");
	}

	return ValidationResult.okWithDepth(.icalendar, .full);
}

/// Validates vCard structural integrity (RFC 6350 / RFC 2426 / vCard 2.1).
/// Checks for BEGIN:VCARD and VERSION property.
pub fn validateVCard(file: *FileSource) ValidationResult {
	var buf: [4096]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.vcard, .failed_to_seek, "vCard header");
	};
	const n = file.readAll(&buf) catch {
		return ValidationResult.invalidCode(.vcard, .failed_to_read, "vCard header");
	};
	if (n == 0) {
		return ValidationResult.invalidCode(.vcard, .file_too_small, "empty file");
	}
	const data = buf[0..n];

	// Skip BOM
	const start = skipBomAndWhitespace(data);
	if (start >= data.len) {
		return ValidationResult.invalidCode(.vcard, .file_too_small, "only whitespace/BOM");
	}

	const remaining = data[start..];
	if (!std.mem.startsWith(u8, remaining, "BEGIN:VCARD")) {
		return ValidationResult.invalidCode(.vcard, .invalid_magic, "missing BEGIN:VCARD");
	}

	// Scan for VERSION
	if (std.mem.indexOf(u8, data, "VERSION:4.0") != null or
		std.mem.indexOf(u8, data, "VERSION:3.0") != null or
		std.mem.indexOf(u8, data, "VERSION:2.1") != null)
	{
		return ValidationResult.okWithDepth(.vcard, .structural);
	}

	return ValidationResult.invalidCode(.vcard, .invalid_value, "missing VERSION property (expected 2.1, 3.0, or 4.0)");
}

/// Deep validation for vCard files (RFC 6350 / RFC 2426).
/// Verifies balanced BEGIN/END pairs, required properties per version, and property line format.
pub fn validateVCardDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const file_size = source.getEndPos() catch {
		return ValidationResult.invalidCode(.vcard, .failed_to_read, "failed to get file size");
	};

	if (file_size == 0) {
		return ValidationResult.invalidCode(.vcard, .file_too_small, "empty file");
	}

	// Cap at 10 MB
	if (file_size > 10 * 1024 * 1024) {
		return ValidationResult.okWithDepth(.vcard, .structural);
	}

	const slurp_vcard = source.getMappedOrSlurp(allocator, 64 << 20) catch
		return ValidationResult.invalidCode(.vcard, .failed_to_read, "failed to read file");
	var heap_pim2: ?[]u8 = null;
	defer if (heap_pim2) |b| allocator.free(b);
	const content: []const u8 = switch (slurp_vcard) {
		.mapped => |m| m,
		.heap => |b| blk: { heap_pim2 = b; break :blk b; },
		.too_large => return ValidationResult.okWithDepth(.vcard, .structural),
	};

	// Skip BOM
	const start = skipBomAndWhitespace(content);
	if (start >= content.len) {
		return ValidationResult.invalidCode(.vcard, .file_too_small, "only whitespace/BOM");
	}

	// Must start with BEGIN:VCARD
	if (!std.mem.startsWith(u8, content[start..], "BEGIN:VCARD")) {
		return ValidationResult.invalidCode(.vcard, .invalid_magic, "missing BEGIN:VCARD");
	}

	// Verify file ends with END:VCARD
	const trimmed = std.mem.trimRight(u8, content, " \t\r\n");
	if (!std.mem.endsWith(u8, trimmed, "END:VCARD")) {
		return ValidationResult.invalidCode(.vcard, .invalid_value, "missing END:VCARD at end of file");
	}

	// Parse all cards — verify balanced BEGIN/END, version, required properties
	var in_card = false;
	var card_count: usize = 0;
	var version: enum { none, v21, v30, v40 } = .none;
	var has_fn = false;
	var has_n = false;
	var lines = LineIterator.init(content[start..]);

	while (lines.next()) |line| {
		const clean = std.mem.trimRight(u8, line, "\r");
		if (clean.len == 0) continue;

		if (std.mem.eql(u8, clean, "BEGIN:VCARD")) {
			if (in_card) {
				return ValidationResult.invalidCode(.vcard, .invalid_value, "nested BEGIN:VCARD");
			}
			in_card = true;
			version = .none;
			has_fn = false;
			has_n = false;
			continue;
		}

		if (std.mem.eql(u8, clean, "END:VCARD")) {
			if (!in_card) {
				return ValidationResult.invalidCode(.vcard, .invalid_value, "END:VCARD without BEGIN");
			}

			// Check required properties based on version
			switch (version) {
				.v40 => {
					if (!has_fn) {
						return ValidationResult.invalidCode(.vcard, .invalid_value, "VERSION:4.0 requires FN property");
					}
				},
				.v30 => {
					if (!has_fn) {
						return ValidationResult.invalidCode(.vcard, .invalid_value, "VERSION:3.0 requires FN property");
					}
					if (!has_n) {
						return ValidationResult.invalidCode(.vcard, .invalid_value, "VERSION:3.0 requires N property");
					}
				},
				.v21, .none => {},
			}

			in_card = false;
			card_count += 1;
			continue;
		}

		if (!in_card) continue;

		// Validate property line format: NAME;PARAMS:VALUE or NAME:VALUE
		// Must contain a colon (properties always have name:value)
		if (std.mem.indexOfScalar(u8, clean, ':') == null) {
			// Allow empty/whitespace-only lines and folded continuation lines
			const is_blank = blk: {
				for (clean) |c| {
					if (c != ' ' and c != '\t') break :blk false;
				}
				break :blk true;
			};
			if (!is_blank) {
				return ValidationResult.invalidCode(.vcard, .invalid_value, "property line missing colon separator");
			}
			continue;
		}

		// Detect version
		if (std.mem.eql(u8, clean, "VERSION:4.0")) {
			version = .v40;
		} else if (std.mem.eql(u8, clean, "VERSION:3.0")) {
			version = .v30;
		} else if (std.mem.eql(u8, clean, "VERSION:2.1")) {
			version = .v21;
		}

		// Check for required properties (handle both NAME:VALUE and NAME;PARAMS:VALUE)
		if (std.mem.startsWith(u8, clean, "FN:") or std.mem.startsWith(u8, clean, "FN;")) {
			has_fn = true;
		}
		if (std.mem.startsWith(u8, clean, "N:") or std.mem.startsWith(u8, clean, "N;")) {
			has_n = true;
		}
	}

	if (in_card) {
		return ValidationResult.invalidCode(.vcard, .invalid_value, "unterminated BEGIN:VCARD");
	}

	if (card_count == 0) {
		return ValidationResult.invalidCode(.vcard, .invalid_value, "no complete VCARD found");
	}

	return ValidationResult.okWithDepth(.vcard, .full);
}

// ===== Tests =====

test "iCalendar structural: valid VCALENDAR" {
	const data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//Test//EN\r\nBEGIN:VEVENT\r\nDTSTART:20250101T120000Z\r\nDTEND:20250101T130000Z\r\nSUMMARY:Test Event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
	// Write to temp file
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const wf = try tmp_dir.dir.createFile("test.ics", .{});
	try wf.writeAll(data);
	wf.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = try tmp_dir.dir.realpath("test.ics", &real_path_buf);
	var source = try FileSource.open(real_path);
	defer source.close();

	const result = validateICalendar(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.icalendar, result.format);
}

test "iCalendar deep: balanced nesting" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//Test//EN\r\nBEGIN:VEVENT\r\nDTSTART:20250101T120000Z\r\nDTEND:20250101T130000Z\r\nSUMMARY:Test Event\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.ics", .data = data });

	// Get the real path for the deep validator
	const real_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.ics");
	defer std.testing.allocator.free(real_path);

	var src = try FileSource.open(real_path);
	defer src.close();
	const result = validateICalendarDeep(std.testing.allocator, &src);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.icalendar, result.format);
}

test "vCard structural: valid VCARD v4" {
	const data = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:John Doe\r\nN:Doe;John;;;\r\nEND:VCARD\r\n";
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const wf = try tmp_dir.dir.createFile("test.vcf", .{});
	try wf.writeAll(data);
	wf.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = try tmp_dir.dir.realpath("test.vcf", &real_path_buf);
	var source = try FileSource.open(real_path);
	defer source.close();

	const result = validateVCard(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.vcard, result.format);
}

test "vCard deep: required properties present" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const data = "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:John Doe\r\nN:Doe;John;;;\r\nEND:VCARD\r\n";
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.vcf", .data = data });

	const real_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.vcf");
	defer std.testing.allocator.free(real_path);

	var src = try FileSource.open(real_path);
	defer src.close();
	const result = validateVCardDeep(std.testing.allocator, &src);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.vcard, result.format);
}

test "vCard deep: v3 requires N and FN" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	// Missing N property — should fail for v3.0
	const data = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:John Doe\r\nEND:VCARD\r\n";
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.vcf", .data = data });

	const real_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.vcf");
	defer std.testing.allocator.free(real_path);

	var src = try FileSource.open(real_path);
	defer src.close();
	const result = validateVCardDeep(std.testing.allocator, &src);
	try std.testing.expect(!result.is_valid);
}

test "iCalendar deep: invalid datetime rejected" {
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const data = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Test//EN\r\nBEGIN:VEVENT\r\nDTSTART:not-a-date\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n";
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.ics", .data = data });

	const real_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, "test.ics");
	defer std.testing.allocator.free(real_path);

	var src = try FileSource.open(real_path);
	defer src.close();
	const result = validateICalendarDeep(std.testing.allocator, &src);
	try std.testing.expect(!result.is_valid);
}

test "iCalendar with bare LF line endings" {
	const data = "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\nBEGIN:VEVENT\nDTSTART:20250101T120000Z\nSUMMARY:Test\nEND:VEVENT\nEND:VCALENDAR\n";
	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	const wf = try tmp_dir.dir.createFile("test.ics", .{});
	try wf.writeAll(data);
	wf.close();

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = try tmp_dir.dir.realpath("test.ics", &real_path_buf);
	var source = try FileSource.open(real_path);
	defer source.close();

	const result = validateICalendar(&source);
	try std.testing.expect(result.is_valid);
}
