//! C API exports for Validate core
//!
//! This module exports the stable-ish C ABI functions defined in validate_core.h

const std = @import("std");
const core = @import("core");
const errors = core.errors;
const format_validation = core.format_validation;
const git_validator = core.git_validator;
const path_validation = core.path_validation;

// Version string (null-terminated, static)
const version_string: [:0]const u8 = core.version.string() ++ "";

/// Opaque format validator handle
pub const FormatValidator = struct {
	validator: format_validation.FormatValidator,
	deep: bool,
	arena: std.heap.ArenaAllocator,
};

/// File format enum (matches C enum)
pub const FileFormat = enum(c_int) {
	unknown = 0,
	png = 1,
	jpeg = 2,
	gif = 3,
	bmp = 4,
	webp = 5,
	tiff = 6,
	zip = 7,
	epub = 8,
	docx = 9,
	xlsx = 10,
	pptx = 11,
	pdf = 12,

	pub fn fromCore(format: format_validation.FileFormat) FileFormat {
		return switch (format) {
			.unknown => .unknown,
			.png => .png,
			.jpeg => .jpeg,
			.gif => .gif,
			.bmp => .bmp,
			.webp => .webp,
			.tiff => .tiff,
			.zip => .zip,
			.epub => .epub,
			.docx => .docx,
			.xlsx => .xlsx,
			.pptx => .pptx,
			.pdf => .pdf,
			// Additional formats not yet exposed in C API map to unknown.
			else => .unknown,
		};
	}
};

/// Validation result structure (matches C struct)
pub const ValidationResult = extern struct {
	format: FileFormat,
	is_valid: c_int,
	error_message: ?[*:0]const u8,
};

/// Validation depth enum (matches core ValidationDepth)
pub const ValidationDepth = enum(c_int) {
	structural = 0,
	full = 1,
};

/// Malformation types (bit positions for malformation bitset)
pub const Malformation = enum(c_int) {
	pdf_garbage_after_eof = 0,
	png_ancillary_crc_error = 1,
	extension_mismatch = 2,
	pdf_trivial_encryption = 3,
	mime_wrapped_content = 4,
	pdf_jbig2_truncated = 5,
	pdf_dct_not_jpeg = 6,
	video_no_frames_decoded = 7,
	xml_undefined_entity = 8,
	rar_header_crc_mismatch = 9,
	video_mixed_nal_prefix = 10,
	pdf_missing_trailer = 11,
	pdf_trailer_missing_size = 12,
	pdf_trailer_missing_root = 13,
	magic_bytes_corrupted = 14,
};

/// Extended validation result (strings valid until next call on same validator)
pub const ValidationResultEx = extern struct {
	format_description: ?[*:0]const u8,
	is_valid: c_int,
	is_unknown: c_int,
	error_message: ?[*:0]const u8,
	warning_message: ?[*:0]const u8,
	validation_depth: ValidationDepth,
	malformation_bits: u64,
    circumvented_trivial_protection: c_int,
    validated_via_ffmpeg: c_int,
};

/// Aggregate validation counts
pub const ValidationCounts = extern struct {
    valid_count: usize,
    invalid_count: usize,
    unknown_count: usize,
};

/// Per-file validation callback (strings valid until next callback on same validator)
pub const ValidationCallback = ?*const fn (
    user_data: ?*anyopaque,
    display_path: [*:0]const u8,
    result: *const ValidationResultEx,
    elapsed_seconds: f64,
) callconv(.c) void;

/// Git repository validation result
pub const GitValidationResult = extern struct {
	is_valid: c_int,
	objects_checked: u32,
	objects_valid: u32,
	objects_corrupt: u32,
	packs_checked: u32,
	packs_valid: u32,
};

// ========== Bundle Directory Patterns ==========
//
// Glob patterns for directories that should be validated as bundles (not recursed into).
// The CLI should fetch these once at startup and use them to filter directories during enumeration.
// If a directory matches any of these patterns, pass it directly to validation instead of recursing.

/// Static array of glob patterns for bundle directories.
/// These are null-terminated strings. The array itself is terminated by a null pointer.
/// Patterns use standard glob syntax: ** matches any path component(s), * matches within a component.
const bundle_patterns = [_][*:0]const u8{
    "**/.git",
    // Future patterns:
    // "**/*.app",
    // "**/*.framework",
    // "**/*.bundle",
    // "**/*.xcodeproj",
    // "**/*.xcworkspace",
};

/// Sentinel-terminated array for C compatibility
const bundle_patterns_sentinel: [bundle_patterns.len + 1]?[*:0]const u8 = blk: {
    var result: [bundle_patterns.len + 1]?[*:0]const u8 = undefined;
    for (bundle_patterns, 0..) |p, i| {
        result[i] = p;
    }
    result[bundle_patterns.len] = null; // Sentinel
    break :blk result;
};

/// Get the list of glob patterns for bundle directories.
/// CLI should call this once at startup and use the patterns to filter directories.
/// Returns: Null-terminated array of null-terminated glob pattern strings.
///          The array and strings are static constants (do not free).
/// Example patterns: "**/.git", "**/*.app"
export fn validate_get_bundle_patterns() [*]const ?[*:0]const u8 {
    return &bundle_patterns_sentinel;
}

/// Get the number of bundle patterns (convenience function).
export fn validate_get_bundle_pattern_count() usize {
    return bundle_patterns.len;
}

fn copyZ(allocator: std.mem.Allocator, value: []const u8) ![*:0]const u8 {
	const buf = try allocator.allocSentinel(u8, value.len, 0);
	@memcpy(buf, value);
	return @ptrCast(buf.ptr);
}

fn copyZOpt(allocator: std.mem.Allocator, value: ?[]const u8) !?[*:0]const u8 {
	if (value) |v| {
		return try copyZ(allocator, v);
	}
	return null;
}

const CallbackContext = struct {
    validator: *FormatValidator,
    callback: ValidationCallback,
    user_data: ?*anyopaque,
};

fn onValidation(
    ctx: ?*anyopaque,
    display_path: []const u8,
    result: format_validation.ValidationResult,
    elapsed_seconds: f64,
) void {
    const cb_ctx: *CallbackContext = @ptrCast(@alignCast(ctx orelse return));
    const callback = cb_ctx.callback orelse return;

    _ = cb_ctx.validator.arena.reset(.free_all);
    const allocator = cb_ctx.validator.arena.allocator();

    const display_z = copyZ(allocator, display_path) catch return;
    const desc_z = copyZ(allocator, result.format.description()) catch return;
    const err_z = copyZOpt(allocator, result.error_message) catch return;
    const warning_z = copyZOpt(allocator, result.warning_message) catch return;

    var malformation_bits: u64 = 0;
    var iter = result.malformations.iterator();
    while (iter.next()) |m| {
        malformation_bits |= (@as(u64, 1) << @as(u6, @intCast(@intFromEnum(m))));
    }

    const ex_result = ValidationResultEx{
        .format_description = desc_z,
        .is_valid = if (result.is_valid) 1 else 0,
        .is_unknown = if (result.format == .unknown) 1 else 0,
        .error_message = err_z,
        .warning_message = warning_z,
        .validation_depth = switch (result.validation_depth) {
            .structural => .structural,
            .full => .full,
        },
        .malformation_bits = malformation_bits,
        .circumvented_trivial_protection = if (result.circumvented_trivial_protection) 1 else 0,
        .validated_via_ffmpeg = if (result.validated_via_ffmpeg) 1 else 0,
    };

    callback(cb_ctx.user_data, display_z, &ex_result, elapsed_seconds);
}

threadlocal var tl_desc_buf: [256]u8 = undefined;

fn copyToThreadLocal(value: []const u8) [*:0]const u8 {
	const max_len = tl_desc_buf.len - 1;
	const len = @min(value.len, max_len);
	@memcpy(tl_desc_buf[0..len], value[0..len]);
	tl_desc_buf[len] = 0;
	return @ptrCast(tl_desc_buf[0..].ptr);
}

/// Returns the library version string.
export fn core_version() [*:0]const u8 {
	return version_string.ptr;
}

/// Pre-initialize all decoder libraries for thread safety.
/// Call this ONCE from the main thread BEFORE spawning worker threads.
/// This triggers lazy SIMD detection and global state initialization
/// in all C libraries, preventing race conditions during parallel validation.
export fn core_preinit() void {
	core.preInit();
}

/// Returns the last error message.
export fn core_last_error() ?[*:0]const u8 {
	if (errors.last_error) |err| {
		return err.message;
	}
	return null;
}

/// Clears the last error.
export fn core_clear_error() void {
	errors.clearLastError();
}

/// Creates a new format validator.
export fn format_validator_create(out: *?*FormatValidator) i32 {
	const v = std.heap.page_allocator.create(FormatValidator) catch {
		errors.setLastError(.internal_out_of_memory, "Failed to allocate format validator", .{});
		return 9002;
	};
	v.* = .{
		.validator = format_validation.FormatValidator.init(),
		.deep = false,
		.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
	};
	out.* = v;
	return 0;
}

/// Creates a new deep format validator.
export fn format_validator_create_deep(out: *?*FormatValidator) i32 {
	const v = std.heap.page_allocator.create(FormatValidator) catch {
		errors.setLastError(.internal_out_of_memory, "Failed to allocate format validator", .{});
		return 9002;
	};
	v.* = .{
		.validator = format_validation.FormatValidator.initDeep(),
		.deep = true,
		.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
	};
	out.* = v;
	return 0;
}

/// Destroys a format validator.
export fn format_validator_destroy(validator: ?*FormatValidator) void {
	const v = validator orelse return;
	v.validator.deinit();
	v.arena.deinit();
	std.heap.page_allocator.destroy(v);
}

/// Enables or disables format validation.
export fn format_validator_set_enabled(validator: ?*FormatValidator, enabled: c_int) void {
	const v = validator orelse return;
	v.validator.setEnabled(enabled != 0);
}

/// Checks if format validation is enabled.
export fn format_validator_is_enabled(validator: ?*const FormatValidator) c_int {
	const v = validator orelse return 0;
	return if (v.validator.enabled) 1 else 0;
}

/// Validates a file at the given path.
export fn format_validate_file(
	validator: ?*FormatValidator,
	path: ?[*:0]const u8,
	out: *ValidationResult,
) i32 {
	const v = validator orelse {
		errors.setLastError(.internal_unexpected, "NULL validator handle", .{});
		return 9001;
	};

	const p = path orelse {
		errors.setLastError(.validation_invalid_path, "NULL path", .{});
		return 9001;
	};

	const path_slice = std.mem.span(p);
	const result = v.validator.validateFile(path_slice);

	out.* = .{
		.format = FileFormat.fromCore(result.format),
		.is_valid = if (result.is_valid) 1 else 0,
		.error_message = if (result.error_message) |msg| @ptrCast(msg.ptr) else null,
	};

	return 0;
}

/// Validates a file and returns extended results.
/// Strings in ValidationResultEx are valid until next call on same validator.
export fn format_validate_file_ex(
	validator: ?*FormatValidator,
	path: ?[*:0]const u8,
	out: *ValidationResultEx,
) i32 {
	const v = validator orelse {
		errors.setLastError(.internal_unexpected, "NULL validator handle", .{});
		return 9001;
	};

	const p = path orelse {
		errors.setLastError(.validation_invalid_path, "NULL path", .{});
		return 9001;
	};

	_ = v.arena.reset(.free_all);
	const allocator = v.arena.allocator();

	const path_slice = std.mem.span(p);
	const result = if (v.deep)
		v.validator.validateFileDeep(allocator, path_slice)
	else
		v.validator.validateFile(path_slice);

	const desc_z = copyZ(allocator, result.format.description()) catch {
		errors.setLastError(.internal_out_of_memory, "Failed to allocate format description", .{});
		return 9002;
	};

	const err_z = copyZOpt(allocator, result.error_message) catch {
		errors.setLastError(.internal_out_of_memory, "Failed to allocate error message", .{});
		return 9002;
	};

	const warning_z = copyZOpt(allocator, result.warning_message) catch {
		errors.setLastError(.internal_out_of_memory, "Failed to allocate warning message", .{});
		return 9002;
	};

	var malformation_bits: u64 = 0;
	var iter = result.malformations.iterator();
	while (iter.next()) |m| {
		malformation_bits |= (@as(u64, 1) << @as(u6, @intCast(@intFromEnum(m))));
	}

	out.* = .{
		.format_description = desc_z,
		.is_valid = if (result.is_valid) 1 else 0,
		.is_unknown = if (result.format == .unknown) 1 else 0,
		.error_message = err_z,
		.warning_message = warning_z,
		.validation_depth = switch (result.validation_depth) {
			.structural => .structural,
			.full => .full,
		},
		.malformation_bits = malformation_bits,
		.circumvented_trivial_protection = if (result.circumvented_trivial_protection) 1 else 0,
		.validated_via_ffmpeg = if (result.validated_via_ffmpeg) 1 else 0,
	};

	return 0;
}

/// Validates a file or directory tree using parallel workers.
export fn format_validate_path_parallel(
	validator: ?*FormatValidator,
	path: ?[*:0]const u8,
	jobs: usize,
	callback: ValidationCallback,
	user_data: ?*anyopaque,
	out_counts: *ValidationCounts,
) i32 {
	const v = validator orelse {
		errors.setLastError(.internal_unexpected, "NULL validator handle", .{});
		return 9001;
	};

	const p = path orelse {
		errors.setLastError(.validation_invalid_path, "NULL path", .{});
		return 9001;
	};

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const path_slice = std.mem.span(p);

	var ctx = CallbackContext{
		.validator = v,
		.callback = callback,
		.user_data = user_data,
	};

	const counts = path_validation.validatePathParallel(
		allocator,
		v.validator,
		path_slice,
		if (jobs == 0) null else jobs,
		if (callback == null) null else onValidation,
		if (callback == null) null else @as(?*anyopaque, @ptrCast(&ctx)),
	) catch |err| {
		// Always include error name in the message for better debugging
		const err_name = @errorName(err);
		switch (err) {
			error.FileNotFound => errors.setLastError(.validation_invalid_path, "Path not found", .{}),
			error.AccessDenied => errors.setLastError(.io_permission_denied, "Access denied ({s})", .{err_name}),
			error.Unsupported => errors.setLastError(.validation_invalid_path, "Unsupported path type", .{}),
			else => errors.setLastError(.internal_unexpected, "Failed to validate path ({s})", .{err_name}),
		}
		return 9001;
	};

	out_counts.* = .{
		.valid_count = counts.valid,
		.invalid_count = counts.invalid,
		.unknown_count = counts.unknown,
	};

	return 0;
}

/// Validation options for parallel path validation
pub const ValidationOptions = extern struct {
	/// Number of worker threads (0 = auto-detect based on CPU count)
	jobs: usize = 0,
	/// Shuffle file order before validation (helps expose race conditions)
	shuffle: c_int = 0,
	/// Random seed for shuffling (0 = use system time)
	seed: u64 = 0,
};

/// Validates a file or directory tree using parallel workers with extended options.
export fn format_validate_path_parallel_ex(
	validator: ?*FormatValidator,
	path: ?[*:0]const u8,
	options: *const ValidationOptions,
	callback: ValidationCallback,
	user_data: ?*anyopaque,
	out_counts: *ValidationCounts,
) i32 {
	const v = validator orelse {
		errors.setLastError(.internal_unexpected, "NULL validator handle", .{});
		return 9001;
	};

	const p = path orelse {
		errors.setLastError(.validation_invalid_path, "NULL path", .{});
		return 9001;
	};

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const path_slice = std.mem.span(p);

	var ctx = CallbackContext{
		.validator = v,
		.callback = callback,
		.user_data = user_data,
	};

	const zig_options = path_validation.ValidationOptions{
		.jobs = options.jobs,
		.shuffle = options.shuffle != 0,
		.seed = options.seed,
	};

	const counts = path_validation.validatePathParallelEx(
		allocator,
		v.validator,
		path_slice,
		zig_options,
		if (callback == null) null else onValidation,
		if (callback == null) null else @as(?*anyopaque, @ptrCast(&ctx)),
	) catch |err| {
		const err_name = @errorName(err);
		switch (err) {
			error.FileNotFound => errors.setLastError(.validation_invalid_path, "Path not found", .{}),
			error.AccessDenied => errors.setLastError(.io_permission_denied, "Access denied ({s})", .{err_name}),
			error.Unsupported => errors.setLastError(.validation_invalid_path, "Unsupported path type", .{}),
			else => errors.setLastError(.internal_unexpected, "Failed to validate path ({s})", .{err_name}),
		}
		return 9001;
	};

	out_counts.* = .{
		.valid_count = counts.valid,
		.invalid_count = counts.invalid,
		.unknown_count = counts.unknown,
	};

	return 0;
}

/// Gets description for a malformation type.
export fn malformation_description(malformation: Malformation) [*:0]const u8 {
	const desc: [:0]const u8 = switch (malformation) {
		.pdf_garbage_after_eof => "non-PDF data appended after %%EOF" ++ "",
		.png_ancillary_crc_error => "CRC error in ancillary PNG chunk" ++ "",
		.extension_mismatch => "file extension doesn't match content" ++ "",
		.pdf_trivial_encryption => "PDF encrypted with empty password (trivial protection)" ++ "",
		.mime_wrapped_content => "MIME-WRAPPED GARBAGE: file has email/MIME headers prepended - some buggy web service returned multipart MIME instead of raw content!" ++ "",
		.pdf_jbig2_truncated => "truncated JBIG2 data in PDF image" ++ "",
		.pdf_dct_not_jpeg => "DCTDecode image data is not valid JPEG" ++ "",
		.video_no_frames_decoded => "video decoder produced no frames (player-tolerated)" ++ "",
		.video_mixed_nal_prefix => "mixed or nonstandard NAL length prefixes (repairable by remux)" ++ "",
		.xml_undefined_entity => "XML entity reference undefined (DTD not validated)" ++ "",
		.rar_header_crc_mismatch => "RAR header CRC mismatch (player-tolerated)" ++ "",
		.pdf_missing_trailer => "missing trailer dictionary (reader-tolerated)" ++ "",
		.pdf_trailer_missing_size => "trailer missing /Size key (reader-tolerated)" ++ "",
		.pdf_trailer_missing_root => "trailer missing /Root key (reader-tolerated)" ++ "",
		.magic_bytes_corrupted => "magic bytes corrupted (identified via extension and secondary signatures)" ++ "",
	};
	return desc.ptr;
}

/// Gets the description for a file format.
export fn file_format_description(format: FileFormat) [*:0]const u8 {
	const desc = switch (format) {
		.unknown => "Unknown",
		.png => "PNG Image",
		.jpeg => "JPEG Image",
		.gif => "GIF Image",
		.bmp => "BMP Image",
		.webp => "WebP Image",
		.tiff => "TIFF Image",
		.zip => "ZIP Archive",
		.epub => "EPUB eBook",
		.docx => "Word Document",
		.xlsx => "Excel Spreadsheet",
		.pptx => "PowerPoint Presentation",
		.pdf => "PDF Document",
	};
	return @ptrCast(desc.ptr);
}

/// Checks if a format has a validator.
export fn file_format_has_validator(format: FileFormat) c_int {
	const core_format: format_validation.FileFormat = switch (format) {
		.unknown => .unknown,
		.png => .png,
		.jpeg => .jpeg,
		.gif => .gif,
		.bmp => .bmp,
		.webp => .webp,
		.tiff => .tiff,
		.zip => .zip,
		.epub => .epub,
		.docx => .docx,
		.xlsx => .xlsx,
		.pptx => .pptx,
		.pdf => .pdf,
	};
	return if (core_format.hasValidator()) 1 else 0;
}

// ========== Git Repository Validation ==========

export fn git_validate_repository(
	path: ?[*:0]const u8,
	out: *GitValidationResult,
	error_buf: ?[*]u8,
	error_buf_len: usize,
) i32 {
	const p = path orelse {
		errors.setLastError(.validation_invalid_path, "NULL path", .{});
		return 5001;
	};

	if (error_buf) |buf| {
		if (error_buf_len > 0) {
			buf[0] = 0;
		}
	}

	const path_slice = std.mem.span(p);
	const result = git_validator.validateRepository(std.heap.page_allocator, path_slice) catch {
		errors.setLastError(.internal_unexpected, "Git validation failed", .{});
		return 9001;
	};

	out.* = .{
		.is_valid = if (result.is_valid) 1 else 0,
		.objects_checked = result.objects_checked,
		.objects_valid = result.objects_valid,
		.objects_corrupt = result.objects_corrupt,
		.packs_checked = result.packs_checked,
		.packs_valid = result.packs_valid,
	};

	if (error_buf) |buf| {
		if (error_buf_len > 0) {
			if (result.error_message) |msg| {
				const len = @min(msg.len, error_buf_len - 1);
				@memcpy(buf[0..len], msg[0..len]);
				buf[len] = 0;
			}
		}
	}

	return 0;
}

// ========== New Simplified API (Hexagonal Architecture) ==========
// See ARCHITECTURE.md for design rationale.

const thread_pool = core.thread_pool;

/// Owned validation result - caller must free with free_result().
pub const OwnedResult = extern struct {
    format_description: ?[*:0]u8,
    is_valid: c_int,
    is_unknown: c_int,
    error_message: ?[*:0]u8,
    warning_message: ?[*:0]u8,
    validation_depth: ValidationDepth,
    malformation_bits: u64,
    circumvented_trivial_protection: c_int,
    validated_via_ffmpeg: c_int,
    elapsed_seconds: f64,
};

/// Batch item - file path with caller-provided ID
pub const BatchItem = extern struct {
    path: ?[*:0]const u8,
    id: u32,
};

/// Progress callback type - may be called many times per file
pub const ProgressCallback = ?*const fn (
    context: ?*anyopaque,
    file_id: u32,
    current: usize,
    total: usize,
    unit: [*:0]const u8,
) callconv(.c) void;

/// Result callback type - called once per file when complete
pub const ResultCallback = ?*const fn (
    context: ?*anyopaque,
    file_id: u32,
    path: [*:0]const u8,
    result: *OwnedResult,
) callconv(.c) void;

/// Allocate and copy a string for owned result
fn allocOwnedString(allocator: std.mem.Allocator, value: []const u8) ?[*:0]u8 {
    const buf = allocator.allocSentinel(u8, value.len, 0) catch return null;
    @memcpy(buf, value);
    return buf.ptr;
}

/// Allocate and copy an optional string for owned result
fn allocOwnedStringOpt(allocator: std.mem.Allocator, value: ?[]const u8) ?[*:0]u8 {
    if (value) |v| {
        return allocOwnedString(allocator, v);
    }
    return null;
}

/// Create an owned result from a validation result
fn createOwnedResult(allocator: std.mem.Allocator, result: format_validation.ValidationResult, elapsed: f64) ?*OwnedResult {
    const owned = allocator.create(OwnedResult) catch return null;

    const desc = allocOwnedString(allocator, result.format.description()) orelse {
        allocator.destroy(owned);
        return null;
    };

    var malformation_bits: u64 = 0;
    var iter = result.malformations.iterator();
    while (iter.next()) |m| {
        malformation_bits |= (@as(u64, 1) << @as(u6, @intCast(@intFromEnum(m))));
    }

    owned.* = .{
        .format_description = desc,
        .is_valid = if (result.is_valid) 1 else 0,
        .is_unknown = if (result.format == .unknown) 1 else 0,
        .error_message = allocOwnedStringOpt(allocator, result.error_message),
        .warning_message = allocOwnedStringOpt(allocator, result.warning_message),
        .validation_depth = switch (result.validation_depth) {
            .structural => .structural,
            .full => .full,
        },
        .malformation_bits = malformation_bits,
        .circumvented_trivial_protection = if (result.circumvented_trivial_protection) 1 else 0,
        .validated_via_ffmpeg = if (result.validated_via_ffmpeg) 1 else 0,
        .elapsed_seconds = elapsed,
    };

    return owned;
}

/// Validate a single file (new simplified API).
export fn validate(
    path: ?[*:0]const u8,
    file_id: u32,
    num_threads: c_int,
    progress_callback: ProgressCallback,
    context: ?*anyopaque,
) ?*OwnedResult {
    _ = num_threads; // TODO: Use for format-specific parallelism
    _ = file_id; // TODO: Pass to progress callback
    _ = progress_callback; // TODO: Implement progress reporting
    _ = context;

    const p = path orelse {
        errors.setLastError(.validation_invalid_path, "NULL path", .{});
        return null;
    };

    const path_slice = std.mem.span(p);

    // Use arena for intermediate allocations during validation
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start_ns = std.time.nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(arena.allocator(), path_slice);
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Create owned result (uses page_allocator for the result itself)
    return createOwnedResult(std.heap.page_allocator, result, elapsed_seconds);
}

/// Batch validation context
const BatchContext = struct {
    result_callback: ResultCallback,
    progress_callback: ProgressCallback,
    user_context: ?*anyopaque,
    allocator: std.mem.Allocator,
    halt_error: ?errors.ErrorCode = null,
};

/// Task for batch validation
const BatchTask = struct {
    path: []const u8,
    file_id: u32,
};

/// Execute a single validation task
fn executeBatchTask(task: BatchTask, ctx_ptr: ?*anyopaque) void {
    const ctx: *BatchContext = @ptrCast(@alignCast(ctx_ptr orelse return));
    const result_callback = ctx.result_callback orelse return;

    // Check for halt condition
    if (ctx.halt_error != null) return;

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    // TODO: Pass progress_callback to validator for per-file progress
    _ = ctx.progress_callback;

    const start_ns = std.time.nanoTimestamp();
    var validator = format_validation.FormatValidator.initDeep();
    const result = validator.validateFileDeep(arena.allocator(), task.path);
    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    // Create owned result
    const owned = createOwnedResult(std.heap.page_allocator, result, elapsed_seconds) orelse {
        ctx.halt_error = .internal_out_of_memory;
        return;
    };

    // Create null-terminated path for callback
    const path_z = ctx.allocator.allocSentinel(u8, task.path.len, 0) catch {
        free_result(owned);
        ctx.halt_error = .internal_out_of_memory;
        return;
    };
    defer ctx.allocator.free(path_z[0 .. task.path.len + 1]);
    @memcpy(path_z, task.path);

    // Call user callback with file_id (serialized - ThreadPool handles this)
    result_callback(ctx.user_context, task.file_id, path_z.ptr, owned);
}

/// Validate multiple files in parallel (new simplified API).
export fn validate_batch(
    items: ?[*]const BatchItem,
    count: usize,
    num_threads: c_int,
    result_callback: ResultCallback,
    progress_callback: ProgressCallback,
    context: ?*anyopaque,
) c_int {
    const item_array = items orelse {
        errors.setLastError(.validation_invalid_path, "NULL items array", .{});
        return 5001;
    };

    if (count == 0) {
        return 0; // Nothing to do
    }

    const actual_threads: usize = if (num_threads <= 0)
        thread_pool.getOuterJobCount() // Use 2/3 of CPUs, leaving room for inner parallelism
    else
        @intCast(num_threads);

    // Pre-init decoder libraries
    core.preInit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var batch_ctx = BatchContext{
        .result_callback = result_callback,
        .progress_callback = progress_callback,
        .user_context = context,
        .allocator = std.heap.page_allocator,
        .halt_error = null,
    };

    // Use ThreadPool for parallel execution
    const Pool = thread_pool.ThreadPool(BatchTask, void);
    const pool = Pool.create(
        allocator,
        actual_threads,
        executeBatchTask,
        @ptrCast(&batch_ctx),
        {}, // No result callback (void result type)
        {},
    ) catch {
        errors.setLastError(.internal_out_of_memory, "Failed to create thread pool", .{});
        return 9002;
    };
    defer pool.destroy();

    // Submit all tasks
    for (0..count) |i| {
        const item = item_array[i];
        const path_ptr = item.path orelse continue; // Skip null paths
        const path_slice = std.mem.span(path_ptr);
        pool.submit(.{ .path = path_slice, .file_id = item.id }) catch {
            pool.shutdown();
            pool.wait();
            errors.setLastError(.internal_out_of_memory, "Failed to submit task", .{});
            return 9002;
        };

        // Check for halt error
        if (batch_ctx.halt_error != null) {
            break;
        }
    }

    pool.shutdown();
    pool.wait();

    // Check if we halted due to error
    if (batch_ctx.halt_error) |halt_err| {
        switch (halt_err) {
            .internal_out_of_memory => {
                errors.setLastError(.internal_out_of_memory, "Out of memory during batch validation", .{});
                return 9002;
            },
            else => {
                errors.setLastError(.internal_unexpected, "Batch validation halted", .{});
                return 9001;
            },
        }
    }

    return 0;
}

/// Free an owned validation result.
export fn free_result(result: ?*OwnedResult) void {
    const r = result orelse return;
    const allocator = std.heap.page_allocator;

    if (r.format_description) |desc| {
        const len = std.mem.len(desc);
        allocator.free(desc[0 .. len + 1]);
    }
    if (r.error_message) |msg| {
        const len = std.mem.len(msg);
        allocator.free(msg[0 .. len + 1]);
    }
    if (r.warning_message) |msg| {
        const len = std.mem.len(msg);
        allocator.free(msg[0 .. len + 1]);
    }
    allocator.destroy(r);
}

/// Get default thread count for batch validation.
/// Returns 2/3 of CPU cores, leaving room for inner parallelism (PDF image validation).
/// Pass 0 or negative to validate_batch() to use this default.
export fn get_default_threads() c_int {
    return @intCast(thread_pool.getOuterJobCount());
}

// ========== Tests ==========

test "core_version" {
    const v = core_version();
    const version_slice = std.mem.span(v);
    try std.testing.expectEqualStrings(core.version.string(), version_slice);
}

test "validate single file" {
    // Just test that the function doesn't crash with a nonexistent file
    const result = validate("/nonexistent/path/test.txt", 0, 0, null, null);
    if (result) |r| {
        try std.testing.expectEqual(@as(c_int, 0), r.is_valid);
        free_result(r);
    }
}

test "get_default_threads" {
    const threads = get_default_threads();
    try std.testing.expect(threads >= 1);
}

// ========== Bundle Pattern Tests ==========

test "validate_get_bundle_patterns returns patterns" {
    const patterns = validate_get_bundle_patterns();

    // Should have at least one pattern
    try std.testing.expect(patterns[0] != null);

    // First pattern should be "**/.git"
    const first_pattern = std.mem.span(patterns[0].?);
    try std.testing.expectEqualStrings("**/.git", first_pattern);
}

test "validate_get_bundle_pattern_count returns correct count" {
    const count = validate_get_bundle_pattern_count();
    try std.testing.expect(count >= 1); // At least .git pattern

    // Should match actual patterns array
    const patterns = validate_get_bundle_patterns();
    var actual_count: usize = 0;
    while (patterns[actual_count] != null) : (actual_count += 1) {}
    try std.testing.expectEqual(count, actual_count);
}
