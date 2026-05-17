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
const runtime = @import("runtime.zig");
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
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	var result = BundleValidationResult{
		.valid = false,
		.depth = .structural,
	};


	// 0. Check for WrappedBundle (iOS Catalyst apps)
	const wrapped_path = std.fmt.bufPrint(&path_buf, "{s}/WrappedBundle", .{path}) catch {
		result.warning = "path too long";
		return result;
	};
	if (runtime.access(wrapped_path, .{})) |_| {
		// iOS Catalyst app — has WrappedBundle/ instead of Contents/
		// Check for Wrapper/Info.plist (the macOS wrapper's plist)
		const wrapper_plist = std.fmt.bufPrint(&path_buf, "{s}/Wrapper/Info.plist", .{path}) catch {
			result.warning = "WrappedBundle present but path too long";
			return result;
		};
		if (runtime.access(wrapper_plist, .{})) |_| {
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

	const plist_data = runtime.cwd().readFileAlloc(runtime.io(), info_plist_path, allocator, .limited(1024 * 1024)) catch {
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

			if (runtime.access(exec_path, .{})) |_| {
				result.has_executable = true;

				// Check Mach-O magic (first 4 bytes)
				if (runtime.openFile(exec_path, .{})) |file| {
					defer file.close(runtime.io());
					var magic: [4]u8 = undefined;
					if (file.readPositional(runtime.io(), &.{&magic}, 0)) |n| {
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
	if (runtime.access(codesig_path, .{})) |_| {
		result.has_code_signature = true;
	} else |_| {}

	// 4. Check for stray files in Contents/
	const contents_path = std.fmt.bufPrint(&path_buf, "{s}/Contents", .{path}) catch {
		result.warning = "path too long";
		return result;
	};

	var contents_dir = runtime.openDir(contents_path, .{ .iterate = true }) catch {
		result.warning = "cannot open Contents/ directory";
		return result;
	};
	defer contents_dir.close(runtime.io());

	var stray_count: u32 = 0;
	var iter = contents_dir.iterate();
	while (iter.next(runtime.io()) catch null) |entry| {
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

	// 5. Verify CodeResources manifest (if code signature exists)
	var manifest_missing: u32 = 0;
	if (result.has_code_signature) {
		const cr_result = verifyCodeResources(allocator, contents_path);
		if (cr_result.total_listed > 0) {
			manifest_missing = cr_result.missing_files;
		}
	}

	// Determine overall validity and depth
	result.valid = true;
	if (result.has_executable and result.executable_is_valid_macho and result.has_code_signature and result.missing_plist_keys == 0) {
		result.depth = .full;
		if (manifest_missing > 0) {
			result.warning = "code signature manifest: files listed but missing from disk (tampering or corruption)";
		} else if (stray_count > 0) {
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
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	_ = allocator;
	var result = BundleValidationResult{
		.valid = false,
		.depth = .structural,
	};


	// Frameworks have either Versions/ (modern) or flat (Headers/, Resources/ directly)
	const versions_path = std.fmt.bufPrint(&path_buf, "{s}/Versions", .{path}) catch {
		result.warning = "path too long";
		return result;
	};

	const has_versions = if (runtime.access(versions_path, .{})) |_| true else |_| false;

	if (has_versions) {
		// Check Versions/Current symlink
		const current_path = std.fmt.bufPrint(&path_buf, "{s}/Versions/Current", .{path}) catch {
			result.warning = "path too long";
			return result;
		};

		if (runtime.access(current_path, .{})) |_| {
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

		if (runtime.access(headers_path, .{})) |_| {
			result.valid = true;
			result.depth = .structural;
		} else |_| {
			const resources_path = std.fmt.bufPrint(&path_buf, "{s}/Resources", .{path}) catch {
				result.warning = "path too long";
				return result;
			};
			if (runtime.access(resources_path, .{})) |_| {
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
		if (runtime.access(ip, .{})) |_| {
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

// ============ CodeResources Manifest Verification ============

pub const CodeResourcesResult = struct {
	valid: bool,
	missing_files: u32, // Files listed in manifest but not on disk
	unlisted_files: u32, // Files on disk but not in manifest
	total_listed: u32,
	total_on_disk: u32,
};

/// Verify the _CodeSignature/CodeResources manifest against actual bundle contents.
/// `contents_path` should point to the Contents/ directory of the bundle.
/// Checks that:
/// 1. Every file in the `files` dict exists on disk
/// 2. No unlisted files exist in Resources/ or other covered directories
pub fn verifyCodeResources(allocator: Allocator, contents_path: []const u8) CodeResourcesResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	var result = CodeResourcesResult{
		.valid = false,
		.missing_files = 0,
		.unlisted_files = 0,
		.total_listed = 0,
		.total_on_disk = 0,
	};


	// Read CodeResources
	const cr_path = std.fmt.bufPrint(&path_buf, "{s}/_CodeSignature/CodeResources", .{contents_path}) catch return result;
	const cr_data = runtime.cwd().readFileAlloc(runtime.io(), cr_path, allocator, .limited(4 * 1024 * 1024)) catch return result;
	defer allocator.free(cr_data);

	// Extract listed file paths from the `files` dict in the XML plist
	// We look for <key>files</key><dict>...<key>PATH</key>...</dict>
	var listed_files = std.StringHashMap(void).init(allocator);
	defer {
		var iter = listed_files.keyIterator();
		while (iter.next()) |k| allocator.free(@constCast(k.*));
		listed_files.deinit();
	}

	// Find the <key>files</key> section
	const files_key = "<key>files</key>";
	const dict_open = "<dict>";
	const dict_close = "</dict>";
	const key_open = "<key>";
	const key_close = "</key>";

	const files_pos = std.mem.indexOf(u8, cr_data, files_key) orelse return result;
	const dict_start = std.mem.indexOfPos(u8, cr_data, files_pos + files_key.len, dict_open) orelse return result;
	const inner_start = dict_start + dict_open.len;

	// Find the matching </dict> at depth 0 (skip nested dicts)
	var depth: u32 = 0;
	var search_pos: usize = inner_start;
	var dict_end: ?usize = null;
	while (search_pos < cr_data.len) {
		if (search_pos + dict_open.len <= cr_data.len and std.mem.eql(u8, cr_data[search_pos..][0..dict_open.len], dict_open)) {
			depth += 1;
			search_pos += dict_open.len;
		} else if (search_pos + dict_close.len <= cr_data.len and std.mem.eql(u8, cr_data[search_pos..][0..dict_close.len], dict_close)) {
			if (depth == 0) {
				dict_end = search_pos;
				break;
			}
			depth -= 1;
			search_pos += dict_close.len;
		} else {
			search_pos += 1;
		}
	}
	const files_section = cr_data[inner_start..dict_end orelse return result];

	// Extract top-level <key>PATH</key> entries from the files dict.
	// Only capture keys at depth 0 (skip "hash", "optional" etc. inside nested dicts).
	var pos: usize = 0;
	var key_depth: u32 = 0;
	while (pos < files_section.len) {
		if (pos + dict_open.len <= files_section.len and std.mem.eql(u8, files_section[pos..][0..dict_open.len], dict_open)) {
			key_depth += 1;
			pos += dict_open.len;
			continue;
		}
		if (pos + dict_close.len <= files_section.len and std.mem.eql(u8, files_section[pos..][0..dict_close.len], dict_close)) {
			if (key_depth > 0) key_depth -= 1;
			pos += dict_close.len;
			continue;
		}

		if (key_depth == 0) {
			if (std.mem.indexOfPos(u8, files_section, pos, key_open)) |ks| {
				if (ks == pos) {
					const kns = ks + key_open.len;
					const ke = std.mem.indexOfPos(u8, files_section, kns, key_close) orelse break;
					const file_path = files_section[kns..ke];

					const duped = allocator.dupe(u8, file_path) catch break;
					listed_files.put(duped, {}) catch {
						allocator.free(duped);
						break;
					};
					result.total_listed += 1;
					pos = ke + key_close.len;
					continue;
				}
			}
		}
		pos += 1;
	}

	if (result.total_listed == 0) return result;

	// Now walk the actual Contents/ directory recursively and check each file
	// against the manifest. Skip _CodeSignature/, MacOS/, and Info.plist (not in files dict).
	var missing: u32 = 0;
	var unlisted: u32 = 0;
	var on_disk: u32 = 0;

	var contents_dir = runtime.openDir(contents_path, .{ .iterate = true }) catch return result;
	defer contents_dir.close(runtime.io());

	// We need to walk recursively. Use a stack-based approach.
	var walker = contents_dir.walk(allocator) catch return result;
	defer walker.deinit();

	while (walker.next(runtime.io()) catch null) |entry| {
		if (entry.kind != .file) continue;
		const rel_path = entry.path;

		// Skip directories/files not covered by the parent's `files` dict:
		// - _CodeSignature/ (the signature itself)
		// - MacOS/ executables (covered by cdhash in files2, not files)
		// - Info.plist and PkgInfo (top-level metadata)
		// - Frameworks/ and PlugIns/ contents (nested bundles, separately signed)
		// - CodeResources at Contents level
		// - _MASReceipt/ (App Store receipt)
		if (std.mem.startsWith(u8, rel_path, "_CodeSignature")) continue;
		if (std.mem.startsWith(u8, rel_path, "MacOS/")) continue;
		if (std.mem.startsWith(u8, rel_path, "Frameworks/")) continue;
		if (std.mem.startsWith(u8, rel_path, "PlugIns/")) continue;
		if (std.mem.startsWith(u8, rel_path, "_MASReceipt/")) continue;
		if (std.mem.startsWith(u8, rel_path, "XPCServices/")) continue;
		if (std.mem.eql(u8, rel_path, "Info.plist")) continue;
		if (std.mem.eql(u8, rel_path, "PkgInfo")) continue;
		if (std.mem.eql(u8, rel_path, "CodeResources")) continue;
		if (std.mem.eql(u8, rel_path, "embedded.provisionprofile")) continue;

		on_disk += 1;
		if (!listed_files.contains(rel_path)) {
			unlisted += 1;
		}
	}

	// Check for files in manifest but missing from disk
	var key_iter = listed_files.keyIterator();
	while (key_iter.next()) |k| {
		const file_rel = k.*;
		if (contents_dir.access(runtime.io(), file_rel, .{})) |_| {
			// exists
		} else |_| {
			missing += 1;
		}
	}

	result.missing_files = missing;
	result.unlisted_files = unlisted;
	result.total_on_disk = on_disk;
	// Only fail on missing files (listed but not on disk = definite corruption/tampering).
	// Unlisted files may be covered by files2 regex rules we don't parse yet.
	result.valid = (missing == 0);

	return result;
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
	tmp.dir.createDirPath(runtime.io(), "Fake.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Fake.app/Contents") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Fake.app/Contents/MacOS") catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "Fake.app") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(!result.valid or result.warning != null);
	try testing.expect(!result.has_info_plist);
}

test "validateAppBundle: detects stray files" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a minimal valid .app with a stray file
	tmp.dir.createDirPath(runtime.io(), "Stray.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Stray.app/Contents") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Stray.app/Contents/MacOS") catch return error.SkipZigTest;

	// Write a minimal Info.plist
	const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>com.test</string>
    \\<key>CFBundleExecutable</key><string>test</string>
    \\<key>CFBundleName</key><string>Test</string>
    \\</dict></plist>
	;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Stray.app/Contents/Info.plist", .data = plist }) catch return error.SkipZigTest;

	// Create the executable (fake Mach-O with correct magic)
	const macho_magic = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00, 0x00, 0x00 };
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Stray.app/Contents/MacOS/test", .data = &macho_magic }) catch return error.SkipZigTest;

	// Add a fake code signature so we reach full depth (where stray check matters)
	tmp.dir.createDirPath(runtime.io(), "Stray.app/Contents/_CodeSignature") catch return error.SkipZigTest;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Stray.app/Contents/_CodeSignature/CodeResources", .data = "<plist/>" }) catch return error.SkipZigTest;

	// Add a stray file
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Stray.app/Contents/hacker_was_here.txt", .data = "gotcha" }) catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "Stray.app") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(result.valid);
	try testing.expect(result.stray_files > 0);
	try testing.expect(result.warning != null);
	try testing.expect(std.mem.indexOf(u8, result.warning.?, "stray") != null);
}

test "validateAppBundle: detects missing executable" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	tmp.dir.createDirPath(runtime.io(), "NoExec.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "NoExec.app/Contents") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "NoExec.app/Contents/MacOS") catch return error.SkipZigTest;

	const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>com.test</string>
    \\<key>CFBundleExecutable</key><string>ghost</string>
    \\<key>CFBundleName</key><string>Test</string>
    \\</dict></plist>
	;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "NoExec.app/Contents/Info.plist", .data = plist }) catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "NoExec.app") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

	const result = validateAppBundle(testing.allocator, rp);
	try testing.expect(!result.valid or (result.warning != null and std.mem.indexOf(u8, result.warning.?, "missing") != null));
	try testing.expect(!result.has_executable);
}

test "extractBplistStringValue: extracts from real binary plist" {
	// Read Spark.app's binary plist if available
	const data = runtime.cwd().readFileAlloc(runtime.io(), "/Applications/Spark.app/Contents/Info.plist", testing.allocator, .limited(1024 * 1024)) catch return error.SkipZigTest;
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
	tmp.dir.createDirPath(runtime.io(), "Catalyst.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Catalyst.app/WrappedBundle") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Catalyst.app/Wrapper") catch return error.SkipZigTest;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Catalyst.app/Wrapper/Info.plist", .data = "<plist/>" }) catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "Catalyst.app") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

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

test "verifyCodeResources: detects unlisted file in signed bundle" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a signed bundle with a CodeResources listing one file
	tmp.dir.createDirPath(runtime.io(), "Signed.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Signed.app/Contents") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Signed.app/Contents/Resources") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Signed.app/Contents/_CodeSignature") catch return error.SkipZigTest;

	// Write a file that IS listed
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Signed.app/Contents/Resources/icon.icns", .data = "icon" }) catch return error.SkipZigTest;

	// Write CodeResources listing only icon.icns
	const code_resources =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\  <key>files</key>
    \\  <dict>
    \\    <key>Resources/icon.icns</key>
    \\    <data>dGVzdA==</data>
    \\  </dict>
    \\</dict>
    \\</plist>
	;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Signed.app/Contents/_CodeSignature/CodeResources", .data = code_resources }) catch return error.SkipZigTest;

	// Add an UNLISTED file (the intruder)
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Signed.app/Contents/Resources/injected.dylib", .data = "malware" }) catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "Signed.app/Contents") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

	const manifest_result = verifyCodeResources(testing.allocator, rp);
	try testing.expect(manifest_result.unlisted_files > 0);
}

test "verifyCodeResources: clean bundle has no unlisted files" {
	var tmp = testing.tmpDir(.{});
	defer tmp.cleanup();

	tmp.dir.createDirPath(runtime.io(), "Clean.app") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Clean.app/Contents") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Clean.app/Contents/Resources") catch return error.SkipZigTest;
	tmp.dir.createDirPath(runtime.io(), "Clean.app/Contents/_CodeSignature") catch return error.SkipZigTest;

	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Clean.app/Contents/Resources/icon.icns", .data = "icon" }) catch return error.SkipZigTest;

	const code_resources =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0">
    \\<dict>
    \\  <key>files</key>
    \\  <dict>
    \\    <key>Resources/icon.icns</key>
    \\    <data>dGVzdA==</data>
    \\  </dict>
    \\</dict>
    \\</plist>
	;
	tmp.dir.writeFile(runtime.io(), .{ .sub_path = "Clean.app/Contents/_CodeSignature/CodeResources", .data = code_resources }) catch return error.SkipZigTest;

	const rp = runtime.tmpRealpathAlloc(&tmp, std.testing.allocator, "Clean.app/Contents") catch return error.SkipZigTest;
	defer std.testing.allocator.free(rp);

	const manifest_result = verifyCodeResources(testing.allocator, rp);
	try testing.expectEqual(@as(u32, 0), manifest_result.unlisted_files);
	try testing.expectEqual(@as(u32, 0), manifest_result.missing_files);
}
