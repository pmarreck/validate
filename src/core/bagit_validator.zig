const std = @import("std");
const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const Allocator = std.mem.Allocator;

/// Structural validator for BagIt (RFC 8493) bags.
/// Reads and validates the bagit.txt tag file: version line + encoding line.
pub fn validateBagit(file: *FileSource) ValidationResult {
	var buf: [4096]u8 = undefined;
	file.seekTo(0) catch {
		return ValidationResult.invalidCode(.bagit, .failed_to_seek, "bagit.txt");
	};
	const bytes_read = file.readAll(&buf) catch {
		return ValidationResult.invalidCode(.bagit, .failed_to_read, "bagit.txt");
	};
	if (bytes_read == 0) {
		return ValidationResult.invalidCode(.bagit, .file_too_small, "bagit.txt is empty");
	}
	const content = buf[0..bytes_read];

	// Split into lines (handle both \n and \r\n)
	var first_line_end: usize = 0;
	while (first_line_end < content.len and content[first_line_end] != '\n') : (first_line_end += 1) {}
	if (first_line_end == 0) {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "bagit.txt first line is empty");
	}

	var first_line = content[0..first_line_end];
	// Strip trailing \r
	if (first_line.len > 0 and first_line[first_line.len - 1] == '\r') {
		first_line = first_line[0 .. first_line.len - 1];
	}

	// First line must be "BagIt-Version: X.Y"
	const version_prefix = "BagIt-Version: ";
	if (!std.mem.startsWith(u8, first_line, version_prefix)) {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "missing BagIt-Version line");
	}
	const version_str = first_line[version_prefix.len..];

	// Validate version format: major.minor (numeric)
	const dot_pos = std.mem.indexOf(u8, version_str, ".") orelse {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "invalid version format (no dot)");
	};
	const major = version_str[0..dot_pos];
	const minor = version_str[dot_pos + 1 ..];
	if (major.len == 0 or minor.len == 0) {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "invalid version format (empty component)");
	}
	_ = std.fmt.parseInt(u32, major, 10) catch {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "non-numeric major version");
	};
	_ = std.fmt.parseInt(u32, minor, 10) catch {
		return ValidationResult.invalidCode(.bagit, .invalid_signature, "non-numeric minor version");
	};

	// Second line should exist (encoding declaration) but is not strictly required for structural validity
	// We accept the bag as structurally valid if the version line is correct.

	return ValidationResult.okWithDepth(.bagit, .structural);
}

/// Deep validator for BagIt bags. Verifies all file hashes listed in the manifest.
/// `path` is either the bag directory or the path to bagit.txt within it.
pub fn validateBagitDeep(allocator: Allocator, path: []const u8) ValidationResult {
	// Derive bag directory from path
	const bag_dir_path = if (std.mem.endsWith(u8, path, "/bagit.txt") or std.mem.endsWith(u8, path, "\\bagit.txt"))
		path[0 .. path.len - "/bagit.txt".len]
	else if (std.mem.endsWith(u8, path, "bagit.txt") and path.len == "bagit.txt".len)
		"."
	else
		path;

	var bag_dir = std.fs.cwd().openDir(bag_dir_path, .{}) catch {
		return ValidationResult.invalidCode(.bagit, .failed_to_read, "cannot open bag directory");
	};
	defer bag_dir.close();

	// Check data/ subdirectory exists
	var data_dir = bag_dir.openDir("data", .{}) catch {
		return ValidationResult.invalidCode(.bagit, .invalid_value, "missing data/ subdirectory");
	};
	data_dir.close();

	// Try to find a manifest file: manifest-sha256.txt, manifest-sha512.txt, manifest-md5.txt
	const Algorithm = enum { sha256, sha512, md5 };
	const manifest_names = [_]struct { name: []const u8, alg: Algorithm }{
		.{ .name = "manifest-sha256.txt", .alg = .sha256 },
		.{ .name = "manifest-sha512.txt", .alg = .sha512 },
		.{ .name = "manifest-md5.txt", .alg = .md5 },
	};

	var manifest_file: ?std.fs.File = null;
	var chosen_alg: Algorithm = .sha256;
	for (manifest_names) |entry| {
		if (bag_dir.openFile(entry.name, .{})) |f| {
			manifest_file = f;
			chosen_alg = entry.alg;
			break;
		} else |_| {}
	}

	const mf = manifest_file orelse {
		return ValidationResult.invalidCode(.bagit, .invalid_value, "no manifest file found");
	};
	defer mf.close();

	// Read entire manifest
	const manifest_content = mf.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
		return ValidationResult.invalidCode(.bagit, .failed_to_read, "manifest file");
	};
	defer allocator.free(manifest_content);

	// Parse and verify each line
	var line_iter = std.mem.splitScalar(u8, manifest_content, '\n');
	var files_checked: usize = 0;
	while (line_iter.next()) |raw_line| {
		// Strip \r
		const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
			raw_line[0 .. raw_line.len - 1]
		else
			raw_line;

		if (line.len == 0) continue;

		// RFC 8493: "<hex_hash>  <filepath>" (two spaces separator)
		const sep = std.mem.indexOf(u8, line, "  ") orelse {
			return ValidationResult.invalidCodeMsg(.bagit, .invalid_value, line, "manifest line missing double-space separator");
		};
		const expected_hex = line[0..sep];
		const file_path = line[sep + 2 ..];
		if (file_path.len == 0) {
			return ValidationResult.invalidCodeMsg(.bagit, .invalid_value, line, "manifest line has empty file path");
		}

		// Open and hash the file
		const target_file = bag_dir.openFile(file_path, .{}) catch {
			return ValidationResult.invalidCodeMsg(.bagit, .checksum_mismatch, file_path, "file listed in manifest not found");
		};
		const target_size = target_file.getEndPos() catch {
			target_file.close();
			return ValidationResult.invalidCodeMsg(.bagit, .failed_to_read, file_path, "failed to get file size for hashing");
		};
		var target_source = FileSource{ .backing = .{ .file = target_file }, .file_size = target_size };
		defer target_source.close();

		// Stream-hash the file and compare against the expected digest
		const match = switch (chosen_alg) {
			.sha256 => verifyFileHash(std.crypto.hash.sha2.Sha256, &target_source, expected_hex),
			.sha512 => verifyFileHash(std.crypto.hash.sha2.Sha512, &target_source, expected_hex),
			.md5 => verifyFileHash(std.crypto.hash.Md5, &target_source, expected_hex),
		} catch {
			return ValidationResult.invalidCodeMsg(.bagit, .failed_to_read, file_path, "failed to read file for hashing");
		};

		if (!match) {
			return ValidationResult.invalidCodeMsg(.bagit, .checksum_mismatch, file_path, switch (chosen_alg) {
				.sha256 => "BagIt manifest SHA-256 hash mismatch",
				.sha512 => "BagIt manifest SHA-512 hash mismatch",
				.md5 => "BagIt manifest MD5 hash mismatch",
			});
		}
		files_checked += 1;
	}

	if (files_checked == 0) {
		return ValidationResult.invalidCode(.bagit, .invalid_value, "manifest is empty");
	}

	return ValidationResult.okWithDepth(.bagit, .full);
}

/// Streaming file hash verification. Reads the file in 64 KB chunks to avoid
/// loading the entire file into memory, then compares the computed hex digest
/// against the expected hex string.
fn verifyFileHash(comptime Hash: type, file: *FileSource, expected_hex: []const u8) !bool {
	var hasher = Hash.init(.{});
	const buf = std.heap.page_allocator.alloc(u8, 65536) catch return error.OutOfMemory;
	defer std.heap.page_allocator.free(buf);
	while (true) {
		const n = try file.read(buf);
		if (n == 0) break;
		hasher.update(buf[0..n]);
	}
	var digest: [Hash.digest_length]u8 = undefined;
	hasher.final(&digest);
	const computed = std.fmt.bytesToHex(digest, .lower);
	return std.mem.eql(u8, &computed, expected_hex);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "BagIt structural: valid bagit.txt" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = try tmp.dir.realpath("bagit.txt", &real_path_buf);
	var source = try FileSource.open(real_path);
	defer source.close();

	const result = validateBagit(&source);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.bagit, result.format);
	try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "BagIt structural: missing version line" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "Not a valid bagit file\n" });

	var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const real_path = try tmp.dir.realpath("bagit.txt", &real_path_buf);
	var source = try FileSource.open(real_path);
	defer source.close();

	const result = validateBagit(&source);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.bagit, result.format);
}

test "BagIt deep: verify SHA-256 manifest" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create bag structure
	try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });
	try tmp.dir.makePath("data");

	const payload = "Hello, BagIt!\n";
	try tmp.dir.writeFile(.{ .sub_path = "data/test.txt", .data = payload });

	// Compute SHA-256 of payload
	var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
	const hex = std.fmt.bytesToHex(digest, .lower);

	// Write manifest
	var manifest_buf: [256]u8 = undefined;
	const manifest_content = std.fmt.bufPrint(&manifest_buf, "{s}  data/test.txt\n", .{@as([]const u8, &hex)}) catch unreachable;
	try tmp.dir.writeFile(.{ .sub_path = "manifest-sha256.txt", .data = manifest_content });

	// Get real path to the bag directory
	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const bag_path = try tmp.dir.realpath(".", &path_buf);

	const result = validateBagitDeep(std.testing.allocator, bag_path);
	try std.testing.expect(result.is_valid);
	try std.testing.expectEqual(FileFormat.bagit, result.format);
	try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "BagIt deep: hash mismatch detected" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create bag structure
	try tmp.dir.writeFile(.{ .sub_path = "bagit.txt", .data = "BagIt-Version: 1.0\nTag-File-Character-Encoding: UTF-8\n" });
	try tmp.dir.makePath("data");
	try tmp.dir.writeFile(.{ .sub_path = "data/test.txt", .data = "actual content\n" });

	// Write manifest with WRONG hash
	try tmp.dir.writeFile(.{ .sub_path = "manifest-sha256.txt", .data = "0000000000000000000000000000000000000000000000000000000000000000  data/test.txt\n" });

	var path_buf: [std.fs.max_path_bytes]u8 = undefined;
	const bag_path = try tmp.dir.realpath(".", &path_buf);

	const result = validateBagitDeep(std.testing.allocator, bag_path);
	try std.testing.expect(!result.is_valid);
	try std.testing.expectEqual(FileFormat.bagit, result.format);
}
