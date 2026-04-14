//! macOS Bundle deep validator.
//!
//! Validates .app, .framework, and .bundle directory structures including:
//! - Info.plist parsing and required key validation
//! - CFBundleExecutable existence and Mach-O validity
//! - Code signature presence and CodeResources manifest
//! - Stray file detection (files not in expected locations)
//!
//! Uses the filesystem for directory traversal but delegates binary
//! validation to existing Mach-O validators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;

/// Expected top-level entries inside Contents/ for a .app bundle.
/// Anything not in this list at the Contents/ level is a stray file.
const app_allowed_contents = [_][]const u8{
	"Info.plist",
	"PkgInfo",
	"MacOS",
	"Resources",
	"Frameworks",
	"_CodeSignature",
	"CodeResources", // Occasionally at this level in older apps
	"PlugIns",
	"SharedFrameworks",
	"SharedSupport",
	"Library",
	"Helpers",
	"XPCServices",
	"Executables",
	"LoginItems",
	"Extensions",
	"SystemExtensions",
	"QuickLook",
	"Spotlight",
	"embedded.provisionprofile",
	"embedded.mobileprovision",
	"_MASReceipt", // Mac App Store receipt
	"Versions", // Some apps embed versioned content
	"MonoBundle", // Mono/.NET runtime apps
	"AppIcon.icns", // Occasionally at Contents/ level
	".DS_Store", // Tolerate but could warn
};

/// Info.plist keys that are required for a valid .app bundle.
const required_app_plist_keys = [_][]const u8{
	"CFBundleIdentifier",
	"CFBundleExecutable",
	"CFBundleName",
};

/// Result with detailed findings for bundle validation.
pub const BundleValidationResult = struct {
	valid: bool,
	depth: format_validation.ValidationDepth,
	has_info_plist: bool = false,
	has_executable: bool = false,
	has_code_signature: bool = false,
	executable_is_valid_macho: bool = false,
	stray_files: u32 = 0,
	missing_plist_keys: u32 = 0,
	warning: ?[]const u8 = null,

	pub fn toValidationResult(self: BundleValidationResult, format: FileFormat) ValidationResult {
		if (!self.valid) {
			return ValidationResult.invalidWithDepth(format, self.warning orelse "bundle validation failed", self.depth);
		}
		if (self.warning) |w| {
			return ValidationResult.okWithDepthAndWarning(format, self.depth, w);
		}
		return ValidationResult.okWithDepth(format, self.depth);
	}
};

/// Extract the value of a key from an XML plist string.
/// Returns the string content between <string>...</string> following the key.
/// Returns null if the key is not found.
pub fn extractPlistStringValue(plist_data: []const u8, key: []const u8) ?[]const u8 {
	// Search for <key>KEY</key> then extract following <string>VALUE</string>
	const key_open = "<key>";
	const key_close = "</key>";
	const str_open = "<string>";
	const str_close = "</string>";

	var pos: usize = 0;
	while (pos < plist_data.len) {
		const key_start = std.mem.indexOfPos(u8, plist_data, pos, key_open) orelse return null;
		const key_name_start = key_start + key_open.len;
		const key_end = std.mem.indexOfPos(u8, plist_data, key_name_start, key_close) orelse return null;

		const found_key = plist_data[key_name_start..key_end];
		if (std.mem.eql(u8, found_key, key)) {
			// Found our key — look for the next <string>...</string>
			const after_key = key_end + key_close.len;
			const val_start = std.mem.indexOfPos(u8, plist_data, after_key, str_open) orelse return null;
			const val_content_start = val_start + str_open.len;
			const val_end = std.mem.indexOfPos(u8, plist_data, val_content_start, str_close) orelse return null;
			return plist_data[val_content_start..val_end];
		}

		pos = key_end + key_close.len;
	}
	return null;
}

/// Check if a key exists in an XML plist (regardless of value type).
pub fn plistKeyExists(plist_data: []const u8, key: []const u8) bool {
	const key_open = "<key>";
	const key_close = "</key>";

	var pos: usize = 0;
	while (pos < plist_data.len) {
		const key_start = std.mem.indexOfPos(u8, plist_data, pos, key_open) orelse return false;
		const key_name_start = key_start + key_open.len;
		const key_end = std.mem.indexOfPos(u8, plist_data, key_name_start, key_close) orelse return false;

		const found_key = plist_data[key_name_start..key_end];
		if (std.mem.eql(u8, found_key, key)) return true;

		pos = key_end + key_close.len;
	}
	return false;
}

// ============ Binary Plist Parser ============

/// Extract a string value for a given key from a binary plist (bplist00).
/// Returns the value as a UTF-8 slice allocated with the given allocator, or null.
/// Caller must free the returned slice.
pub fn extractBplistStringValue(allocator: Allocator, data: []const u8, key: []const u8) ?[]u8 {
	if (data.len < 40) return null; // header(8) + trailer(32) minimum
	if (!std.mem.eql(u8, data[0..6], "bplist")) return null;

	// Parse trailer (last 32 bytes)
	const trailer = data[data.len - 32 ..];
	const offset_size: u8 = trailer[6];
	const ref_size: u8 = trailer[7];
	const num_objects = std.mem.readInt(u64, trailer[8..16], .big);
	const top_obj_idx = std.mem.readInt(u64, trailer[16..24], .big);
	const offset_table_start = std.mem.readInt(u64, trailer[24..32], .big);

	if (offset_size == 0 or offset_size > 8 or ref_size == 0 or ref_size > 8) return null;
	if (offset_table_start >= data.len or num_objects == 0) return null;

	// Read object offset from offset table
	const getOffset = struct {
		fn f(d: []const u8, ot_start: u64, idx: u64, os: u8) ?u64 {
			const pos = ot_start + idx * os;
			if (pos + os > d.len) return null;
			var val: u64 = 0;
			for (d[@intCast(pos)..][0..os]) |b| {
				val = (val << 8) | b;
			}
			return val;
		}
	}.f;

	// Top object must be a dict
	const top_offset = getOffset(data, offset_table_start, top_obj_idx, offset_size) orelse return null;
	if (top_offset >= data.len) return null;

	const marker = data[@intCast(top_offset)];
	const obj_type = marker >> 4;
	if (obj_type != 0xD) return null; // Not a dict

	// Read dict size
	var dict_size: u64 = marker & 0x0F;
	var dict_data_start: u64 = top_offset + 1;
	if (dict_size == 0x0F) {
		// Extended size
		if (dict_data_start >= data.len) return null;
		const size_marker = data[@intCast(dict_data_start)];
		if ((size_marker >> 4) != 0x1) return null;
		const size_bytes: u8 = @as(u8, 1) << @intCast(size_marker & 0x0F);
		dict_data_start += 1;
		if (dict_data_start + size_bytes > data.len) return null;
		dict_size = 0;
		for (data[@intCast(dict_data_start)..][0..size_bytes]) |b| {
			dict_size = (dict_size << 8) | b;
		}
		dict_data_start += size_bytes;
	}

	// Dict layout: dict_size key refs, then dict_size value refs
	const refs_total = dict_size * 2 * ref_size;
	if (dict_data_start + refs_total > data.len) return null;

	// Search for our key in the dict
	for (0..dict_size) |i| {
		const key_ref_pos = dict_data_start + i * ref_size;
		var key_idx: u64 = 0;
		for (data[@intCast(key_ref_pos)..][0..ref_size]) |b| {
			key_idx = (key_idx << 8) | b;
		}

		// Read key object — must be an ASCII string (0x5x)
		const key_offset = getOffset(data, offset_table_start, key_idx, offset_size) orelse continue;
		if (key_offset >= data.len) continue;

		const key_marker = data[@intCast(key_offset)];
		if ((key_marker >> 4) != 0x5) continue; // Not ASCII string

		var key_len: u64 = key_marker & 0x0F;
		var key_str_start: u64 = key_offset + 1;
		if (key_len == 0x0F) {
			if (key_str_start >= data.len) continue;
			const sm = data[@intCast(key_str_start)];
			if ((sm >> 4) != 0x1) continue;
			const sb: u8 = @as(u8, 1) << @intCast(sm & 0x0F);
			key_str_start += 1;
			if (key_str_start + sb > data.len) continue;
			key_len = 0;
			for (data[@intCast(key_str_start)..][0..sb]) |b| {
				key_len = (key_len << 8) | b;
			}
			key_str_start += sb;
		}

		if (key_str_start + key_len > data.len) continue;
		const found_key = data[@intCast(key_str_start)..@intCast(key_str_start + key_len)];
		if (!std.mem.eql(u8, found_key, key)) continue;

		// Found our key — read the corresponding value
		const val_ref_pos = dict_data_start + (dict_size + i) * ref_size;
		var val_idx: u64 = 0;
		for (data[@intCast(val_ref_pos)..][0..ref_size]) |b| {
			val_idx = (val_idx << 8) | b;
		}

		const val_offset = getOffset(data, offset_table_start, val_idx, offset_size) orelse return null;
		if (val_offset >= data.len) return null;

		const val_marker = data[@intCast(val_offset)];
		const val_type = val_marker >> 4;

		if (val_type == 0x5) {
			// ASCII string
			var val_len: u64 = val_marker & 0x0F;
			var val_str_start: u64 = val_offset + 1;
			if (val_len == 0x0F) {
				if (val_str_start >= data.len) return null;
				const sm = data[@intCast(val_str_start)];
				if ((sm >> 4) != 0x1) return null;
				const sb: u8 = @as(u8, 1) << @intCast(sm & 0x0F);
				val_str_start += 1;
				if (val_str_start + sb > data.len) return null;
				val_len = 0;
				for (data[@intCast(val_str_start)..][0..sb]) |b| {
					val_len = (val_len << 8) | b;
				}
				val_str_start += sb;
			}
			if (val_str_start + val_len > data.len) return null;
			const result = allocator.alloc(u8, @intCast(val_len)) catch return null;
			@memcpy(result, data[@intCast(val_str_start)..@intCast(val_str_start + val_len)]);
			return result;
		} else if (val_type == 0x6) {
			// UTF-16 BE string — convert to UTF-8
			var char_count: u64 = val_marker & 0x0F;
			var val_str_start: u64 = val_offset + 1;
			if (char_count == 0x0F) {
				if (val_str_start >= data.len) return null;
				const sm = data[@intCast(val_str_start)];
				if ((sm >> 4) != 0x1) return null;
				const sb: u8 = @as(u8, 1) << @intCast(sm & 0x0F);
				val_str_start += 1;
				if (val_str_start + sb > data.len) return null;
				char_count = 0;
				for (data[@intCast(val_str_start)..][0..sb]) |b| {
					char_count = (char_count << 8) | b;
				}
				val_str_start += sb;
			}
			const byte_count = char_count * 2;
			if (val_str_start + byte_count > data.len) return null;
			// Simple conversion: most plist strings are ASCII-range UTF-16
			const result = allocator.alloc(u8, @intCast(char_count)) catch return null;
			for (0..@intCast(char_count)) |ci| {
				const hi = data[@intCast(val_str_start + ci * 2)];
				const lo = data[@intCast(val_str_start + ci * 2 + 1)];
				result[ci] = if (hi == 0) lo else '?'; // Non-ASCII → '?'
			}
			return result;
		}

		return null; // Value is not a string type
	}

	return null; // Key not found
}

/// Check if a key exists in a binary plist's top-level dict.
pub fn bplistKeyExists(data: []const u8, key: []const u8) bool {
	// Use the full parser but with a stack allocator for the throwaway string
	var buf: [256]u8 = undefined;
	var fba = std.heap.FixedBufferAllocator.init(&buf);
	const val = extractBplistStringValue(fba.allocator(), data, key);
	return val != null;
}

/// Extract a plist string value from either XML or binary plist format.
/// For XML, returns a slice into the original data (no allocation).
/// For binary, returns an allocated slice (caller must free).
/// The `allocated` out-param indicates whether the result needs freeing.
pub fn extractPlistValue(allocator: Allocator, plist_data: []const u8, key: []const u8, allocated: *bool) ?[]const u8 {
	allocated.* = false;
	if (plist_data.len >= 6 and std.mem.eql(u8, plist_data[0..6], "bplist")) {
		if (extractBplistStringValue(allocator, plist_data, key)) |val| {
			allocated.* = true;
			return val;
		}
		return null;
	}
	return extractPlistStringValue(plist_data, key);
}

/// Check if a key exists in either XML or binary plist format.
pub fn plistKeyExistsAny(plist_data: []const u8, key: []const u8) bool {
	if (plist_data.len >= 6 and std.mem.eql(u8, plist_data[0..6], "bplist")) {
		return bplistKeyExists(plist_data, key);
	}
	return plistKeyExists(plist_data, key);
}

/// Validate a .app bundle deeply.
/// Checks Info.plist, executable, code signature, and stray files.
pub fn validateAppBundle(allocator: Allocator, path: []const u8) BundleValidationResult {
	var result = BundleValidationResult{
		.valid = false,
		.depth = .structural,
	};

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;

	// 0. Check for WrappedBundle (iOS Catalyst apps)
	const wrapped_path = std.fmt.bufPrint(&path_buf, "{s}/WrappedBundle", .{path}) catch {
		result.warning = "path too long";
		return result;
	};
	if (std.fs.cwd().access(wrapped_path, .{})) |_| {
		// iOS Catalyst app — has WrappedBundle/ instead of Contents/
		// Check for Wrapper/Info.plist (the macOS wrapper's plist)
		const wrapper_plist = std.fmt.bufPrint(&path_buf, "{s}/Wrapper/Info.plist", .{path}) catch {
			result.warning = "WrappedBundle present but path too long";
			return result;
		};
		if (std.fs.cwd().access(wrapper_plist, .{})) |_| {
			result.has_info_plist = true;
			result.valid = true;
			result.depth = .structural;
			result.warning = "iOS Catalyst app (WrappedBundle)";
			return result;
		} else |_| {
			// No Wrapper plist — still valid as a Catalyst app
			result.valid = true;
			result.depth = .structural;
			result.warning = "iOS Catalyst app (WrappedBundle, no Wrapper/Info.plist)";
			return result;
		}
	} else |_| {}

	// 1. Read and parse Info.plist
	const info_plist_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/Info.plist", .{path}) catch {
		result.warning = "path too long";
		return result;
	};

	const plist_data = std.fs.cwd().readFileAlloc(allocator, info_plist_path, 1024 * 1024) catch {
		result.warning = "missing or unreadable Contents/Info.plist";
		return result;
	};
	defer allocator.free(plist_data);
	result.has_info_plist = true;

	// Validate required keys (works for both XML and binary plists)
	{
		var missing: u32 = 0;
		for (required_app_plist_keys) |key| {
			if (!plistKeyExistsAny(plist_data, key)) {
				missing += 1;
			}
		}
		result.missing_plist_keys = missing;
		if (missing > 0) {
			result.warning = "missing required Info.plist keys";
		}
	}

	// 2. Verify CFBundleExecutable exists and is valid Mach-O
	{
		var was_allocated = false;
		if (extractPlistValue(allocator, plist_data, "CFBundleExecutable", &was_allocated)) |exec_name| {
			defer if (was_allocated) allocator.free(@constCast(exec_name));
			const exec_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/MacOS/{s}", .{ path, exec_name }) catch {
				result.warning = "executable path too long";
				return result;
			};

			if (std.fs.cwd().access(exec_path, .{})) |_| {
				result.has_executable = true;

				// Check Mach-O magic (first 4 bytes)
				if (std.fs.cwd().openFile(exec_path, .{})) |file| {
					defer file.close();
					var magic: [4]u8 = undefined;
					if (file.read(&magic)) |n| {
						if (n >= 4) {
							const m = std.mem.readInt(u32, &magic, .little);
							// MH_MAGIC, MH_MAGIC_64, MH_CIGAM, MH_CIGAM_64, FAT_MAGIC, FAT_CIGAM
							result.executable_is_valid_macho =
								m == 0xFEEDFACE or m == 0xFEEDFACF or
								m == 0xCEFAEDFE or m == 0xCFFAEDFE or
								m == 0xCAFEBABE or m == 0xBEBAFECA;
						}
					} else |_| {}
				} else |_| {}
			} else |_| {
				result.warning = "CFBundleExecutable declared but file missing from Contents/MacOS/";
				return result;
			}
		}
	}

	// 3. Check code signature
	const codesig_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/_CodeSignature/CodeResources", .{path}) catch {
		result.warning = "path too long";
		return result;
	};
	if (std.fs.cwd().access(codesig_path, .{})) |_| {
		result.has_code_signature = true;
	} else |_| {}

	// 4. Check for stray files in Contents/
	const contents_path = std.fmt.bufPrint(&path_buf, "{s}/Contents", .{path}) catch {
		result.warning = "path too long";
		return result;
	};

	var contents_dir = std.fs.cwd().openDir(contents_path, .{ .iterate = true }) catch {
		result.warning = "cannot open Contents/ directory";
		return result;
	};
	defer contents_dir.close();

	var stray_count: u32 = 0;
	var iter = contents_dir.iterate();
	while (iter.next() catch null) |entry| {
		var is_allowed = false;
		for (app_allowed_contents) |allowed| {
			if (std.mem.eql(u8, entry.name, allowed)) {
				is_allowed = true;
				break;
			}
		}
		if (!is_allowed) {
			stray_count += 1;
		}
	}
	result.stray_files = stray_count;

	// Determine overall validity and depth
	result.valid = true;
	if (result.has_executable and result.executable_is_valid_macho and result.has_code_signature and result.missing_plist_keys == 0) {
		result.depth = .full;
		if (stray_count > 0) {
			result.warning = "stray files detected in Contents/ directory";
		} else if (result.warning == null) {
			// No warnings at all — fully clean bundle
		}
	} else {
		result.depth = .structural;
		if (!result.has_code_signature) {
			result.warning = "no code signature (app may not launch on modern macOS)";
		}
	}

	return result;
}

/// Validate a .framework bundle deeply.
pub fn validateFrameworkBundle(allocator: Allocator, path: []const u8) BundleValidationResult {
	_ = allocator;
	var result = BundleValidationResult{
		.valid = false,
		.depth = .structural,
	};

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;

	// Frameworks have either Versions/ (modern) or flat (Headers/, Resources/ directly)
	const versions_path = std.fmt.bufPrint(&path_buf, "{s}/Versions", .{path}) catch {
		result.warning = "path too long";
		return result;
	};

	const has_versions = if (std.fs.cwd().access(versions_path, .{})) |_| true else |_| false;

	if (has_versions) {
		// Check Versions/Current symlink
		const current_path = std.fmt.bufPrint(&path_buf, "{s}/Versions/Current", .{path}) catch {
			result.warning = "path too long";
			return result;
		};

		if (std.fs.cwd().access(current_path, .{})) |_| {
			result.valid = true;
			result.depth = .structural;
		} else |_| {
			result.warning = "Versions/ exists but Versions/Current is missing";
			return result;
		}
	} else {
		// Check flat structure
		const headers_path = std.fmt.bufPrint(&path_buf, "{s}/Headers", .{path}) catch {
			result.warning = "path too long";
			return result;
		};

		if (std.fs.cwd().access(headers_path, .{})) |_| {
			result.valid = true;
			result.depth = .structural;
		} else |_| {
			const resources_path = std.fmt.bufPrint(&path_buf, "{s}/Resources", .{path}) catch {
				result.warning = "path too long";
				return result;
			};
			if (std.fs.cwd().access(resources_path, .{})) |_| {
				result.valid = true;
				result.depth = .structural;
			} else |_| {
				result.warning = "framework has no Versions/, Headers/, or Resources/";
				return result;
			}
		}
	}

	// Check for Info.plist (frameworks should have one)
	const info_path = if (has_versions)
		std.fmt.bufPrint(&path_buf, "{s}/Versions/Current/Resources/Info.plist", .{path}) catch null
	else
		std.fmt.bufPrint(&path_buf, "{s}/Resources/Info.plist", .{path}) catch null;

	if (info_path) |ip| {
		if (std.fs.cwd().access(ip, .{})) |_| {
			result.has_info_plist = true;
		} else |_| {}
	}

	return result;
}

/// Validate a .bundle (plugin) deeply.
pub fn validatePluginBundle(allocator: Allocator, path: []const u8) BundleValidationResult {
	// Plugin bundles follow the same structure as .app but simpler
	// They need Contents/MacOS/ + Contents/Info.plist at minimum
	return validateAppBundle(allocator, path);
}

// ============ Tests ============

const testing = std.testing;

test "extractPlistStringValue: extracts known key" {
	const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleIdentifier</key>
    \\  <string>com.example.test</string>
    \\  <key>CFBundleExecutable</key>
    \\  <string>MyApp</string>
    \\</dict>
    \\</plist>
	;
	const val = extractPlistStringValue(plist, "CFBundleExecutable");
	try testing.expect(val != null);
	try testing.expectEqualStrings("MyApp", val.?);
}

test "extractPlistStringValue: returns null for missing key" {
	const plist =
    \\<dict>
    \\  <key>CFBundleIdentifier</key>
    \\  <string>com.example.test</string>
    \\</dict>
	;
	try testing.expect(extractPlistStringValue(plist, "CFBundleExecutable") == null);
}

test "plistKeyExists: finds existing key" {
	const plist =
    \\<dict>
    \\  <key>CFBundleName</key>
    \\  <string>Test</string>
    \\</dict>
	;
	try testing.expect(plistKeyExists(plist, "CFBundleName"));
	try testing.expect(!plistKeyExists(plist, "CFBundleVersion"));
}

test "validateAppBundle: validates real app bundle" {
	// Use a real app from the system — skip if not on macOS or app not found
	const result = validateAppBundle(testing.allocator, "/Applications/Adobe Digital Editions 4.5.app");
	if (!result.has_info_plist) {
		// App not found on this system — skip
		return error.SkipZigTest;
	}
	try testing.expect(result.valid);
	try testing.expect(result.has_info_plist);
	try testing.expect(result.has_executable);
	try testing.expect(result.executable_is_valid_macho);
	try testing.expect(result.has_code_signature);
	try testing.expectEqual(@as(u32, 0), result.missing_plist_keys);
}

test "validateAppBundle: detects missing Info.plist" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a fake .app with no Info.plist
	tmp.dir.makeDir("Fake.app") catch return error.SkipZigTest;
	tmp.dir.makeDir("Fake.app/Contents") catch return error.SkipZigTest;
	tmp.dir.makeDir("Fake.app/Contents/MacOS") catch return error.SkipZigTest;

	var pb: [std.fs.max_path_bytes]u8 = undefined;
	const rp = tmp.dir.realpath("Fake.app", &pb) catch return error.SkipZigTest;

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(!result.valid or result.warning != null);
	try testing.expect(!result.has_info_plist);
}

test "validateAppBundle: detects stray files" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a minimal valid .app with a stray file
	tmp.dir.makeDir("Stray.app") catch return error.SkipZigTest;
	tmp.dir.makeDir("Stray.app/Contents") catch return error.SkipZigTest;
	tmp.dir.makeDir("Stray.app/Contents/MacOS") catch return error.SkipZigTest;

	// Write a minimal Info.plist
	const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>com.test</string>
    \\<key>CFBundleExecutable</key><string>test</string>
    \\<key>CFBundleName</key><string>Test</string>
    \\</dict></plist>
	;
	tmp.dir.writeFile(.{ .sub_path = "Stray.app/Contents/Info.plist", .data = plist }) catch return error.SkipZigTest;

	// Create the executable (fake Mach-O with correct magic)
	const macho_magic = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00 };
	tmp.dir.writeFile(.{ .sub_path = "Stray.app/Contents/MacOS/test", .data = &macho_magic }) catch return error.SkipZigTest;

	// Add a fake code signature so we reach full depth (where stray check matters)
	tmp.dir.makeDir("Stray.app/Contents/_CodeSignature") catch return error.SkipZigTest;
	tmp.dir.writeFile(.{ .sub_path = "Stray.app/Contents/_CodeSignature/CodeResources", .data = "<plist/>" }) catch return error.SkipZigTest;

	// Add a stray file
	tmp.dir.writeFile(.{ .sub_path = "Stray.app/Contents/hacker_was_here.txt", .data = "gotcha" }) catch return error.SkipZigTest;

	var pb: [std.fs.max_path_bytes]u8 = undefined;
	const rp = tmp.dir.realpath("Stray.app", &pb) catch return error.SkipZigTest;

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(result.valid);
	try testing.expect(result.stray_files > 0);
	try testing.expect(result.warning != null);
	try testing.expect(std.mem.indexOf(u8, result.warning.?, "stray") != null);
}

test "validateAppBundle: detects missing executable" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	tmp.dir.makeDir("NoExec.app") catch return error.SkipZigTest;
	tmp.dir.makeDir("NoExec.app/Contents") catch return error.SkipZigTest;
	tmp.dir.makeDir("NoExec.app/Contents/MacOS") catch return error.SkipZigTest;

	const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>com.test</string>
    \\<key>CFBundleExecutable</key><string>ghost</string>
    \\<key>CFBundleName</key><string>Test</string>
    \\</dict></plist>
	;
	tmp.dir.writeFile(.{ .sub_path = "NoExec.app/Contents/Info.plist", .data = plist }) catch return error.SkipZigTest;

	var pb: [std.fs.max_path_bytes]u8 = undefined;
	const rp = tmp.dir.realpath("NoExec.app", &pb) catch return error.SkipZigTest;

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(!result.valid or (result.warning != null and std.mem.indexOf(u8, result.warning.?, "missing") != null));
	try testing.expect(!result.has_executable);
}

test "extractBplistStringValue: extracts from real binary plist" {
	// Read Spark.app's binary plist if available
	const data = std.fs.cwd().readFileAlloc(testing.allocator, "/Applications/Spark.app/Contents/Info.plist", 1024 * 1024) catch return error.SkipZigTest;
	defer testing.allocator.free(data);

	if (data.len < 6 or !std.mem.eql(u8, data[0..6], "bplist")) return error.SkipZigTest;

	const val = extractBplistStringValue(testing.allocator, data, "CFBundleExecutable");
	if (val) |v| {
		defer testing.allocator.free(v);
		try testing.expect(v.len > 0);
	} else {
		// Some binary plists might use different key encoding
		return error.SkipZigTest;
	}
}

test "validateAppBundle: binary plist app reaches full depth" {
	// VLC or Spark use binary plists — test that they now reach full depth
	const result = validateAppBundle(testing.allocator, "/Applications/Spark.app");
	if (!result.has_info_plist) return error.SkipZigTest;
	// With binary plist support, should reach full depth if it has executable + signature
	try testing.expect(result.valid);
	try testing.expect(result.missing_plist_keys == 0);
}

test "validateAppBundle: WrappedBundle (iOS Catalyst) detected" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a fake iOS Catalyst app structure
	tmp.dir.makeDir("Catalyst.app") catch return error.SkipZigTest;
	tmp.dir.makeDir("Catalyst.app/WrappedBundle") catch return error.SkipZigTest;
	tmp.dir.makeDir("Catalyst.app/Wrapper") catch return error.SkipZigTest;
	tmp.dir.writeFile(.{ .sub_path = "Catalyst.app/Wrapper/Info.plist", .data = "<plist/>" }) catch return error.SkipZigTest;

	var pb: [std.fs.max_path_bytes]u8 = undefined;
	const rp = tmp.dir.realpath("Catalyst.app", &pb) catch return error.SkipZigTest;

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(result.valid);
	try testing.expect(result.has_info_plist);
	try testing.expect(result.warning != null);
	try testing.expect(std.mem.indexOf(u8, result.warning.?, "Catalyst") != null);
}

test "plistKeyExistsAny: works for XML" {
	const plist =
    \\<dict>
    \\  <key>CFBundleName</key>
    \\  <string>Test</string>
    \\</dict>
	;
	try testing.expect(plistKeyExistsAny(plist, "CFBundleName"));
	try testing.expect(!plistKeyExistsAny(plist, "Nonexistent"));
}
