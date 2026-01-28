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
pub const EsFormatValidator = struct {
	validator: format_validation.FormatValidator,
	deep: bool,
	arena: std.heap.ArenaAllocator,
};

/// File format enum (matches C enum)
pub const EsFileFormat = enum(c_int) {
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

	pub fn fromCore(format: format_validation.FileFormat) EsFileFormat {
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
pub const EsValidationResult = extern struct {
	format: EsFileFormat,
	is_valid: c_int,
	error_message: ?[*:0]const u8,
};

/// Validation depth enum (matches core ValidationDepth)
pub const EsValidationDepth = enum(c_int) {
	structural = 0,
	full = 1,
};

/// Malformation types (bit positions for malformation bitset)
pub const EsMalformation = enum(c_int) {
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
pub const EsValidationResultEx = extern struct {
	format_description: ?[*:0]const u8,
	is_valid: c_int,
	is_unknown: c_int,
	error_message: ?[*:0]const u8,
	warning_message: ?[*:0]const u8,
	validation_depth: EsValidationDepth,
	malformation_bits: u64,
    circumvented_trivial_protection: c_int,
};

/// Aggregate validation counts
pub const EsValidationCounts = extern struct {
    valid_count: usize,
    invalid_count: usize,
    unknown_count: usize,
};

/// Per-file validation callback (strings valid until next callback on same validator)
pub const EsValidationCallback = ?*const fn (
    user_data: ?*anyopaque,
    display_path: [*:0]const u8,
    result: *const EsValidationResultEx,
    elapsed_seconds: f64,
) callconv(.c) void;

/// Git repository validation result
pub const EsGitValidationResult = extern struct {
	is_valid: c_int,
	objects_checked: u32,
	objects_valid: u32,
	objects_corrupt: u32,
	packs_checked: u32,
	packs_valid: u32,
};

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
    validator: *EsFormatValidator,
    callback: EsValidationCallback,
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

    const ex_result = EsValidationResultEx{
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
export fn es_core_version() [*:0]const u8 {
	return version_string.ptr;
}

/// Returns the last error message.
export fn es_core_last_error() ?[*:0]const u8 {
	if (errors.last_error) |err| {
		return err.message;
	}
	return null;
}

/// Clears the last error.
export fn es_core_clear_error() void {
	errors.clearLastError();
}

/// Creates a new format validator.
export fn es_format_validator_create(out: *?*EsFormatValidator) i32 {
	const v = std.heap.page_allocator.create(EsFormatValidator) catch {
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
export fn es_format_validator_create_deep(out: *?*EsFormatValidator) i32 {
	const v = std.heap.page_allocator.create(EsFormatValidator) catch {
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
export fn es_format_validator_destroy(validator: ?*EsFormatValidator) void {
	const v = validator orelse return;
	v.validator.deinit();
	v.arena.deinit();
	std.heap.page_allocator.destroy(v);
}

/// Enables or disables format validation.
export fn es_format_validator_set_enabled(validator: ?*EsFormatValidator, enabled: c_int) void {
	const v = validator orelse return;
	v.validator.setEnabled(enabled != 0);
}

/// Checks if format validation is enabled.
export fn es_format_validator_is_enabled(validator: ?*const EsFormatValidator) c_int {
	const v = validator orelse return 0;
	return if (v.validator.enabled) 1 else 0;
}

/// Validates a file at the given path.
export fn es_format_validate_file(
	validator: ?*EsFormatValidator,
	path: ?[*:0]const u8,
	out: *EsValidationResult,
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
		.format = EsFileFormat.fromCore(result.format),
		.is_valid = if (result.is_valid) 1 else 0,
		.error_message = if (result.error_message) |msg| @ptrCast(msg.ptr) else null,
	};

	return 0;
}

/// Validates a file and returns extended results.
/// Strings in EsValidationResultEx are valid until next call on same validator.
export fn es_format_validate_file_ex(
	validator: ?*EsFormatValidator,
	path: ?[*:0]const u8,
	out: *EsValidationResultEx,
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
	};

	return 0;
}

/// Validates a file or directory tree using parallel workers.
export fn es_format_validate_path_parallel(
	validator: ?*EsFormatValidator,
	path: ?[*:0]const u8,
	jobs: usize,
	callback: EsValidationCallback,
	user_data: ?*anyopaque,
	out_counts: *EsValidationCounts,
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
		switch (err) {
			error.FileNotFound => errors.setLastError(.validation_invalid_path, "Path not found", .{}),
			error.AccessDenied => errors.setLastError(.io_permission_denied, "Access denied", .{}),
			error.Unsupported => errors.setLastError(.validation_invalid_path, "Unsupported path type", .{}),
			else => errors.setLastError(.internal_unexpected, "Failed to validate path", .{}),
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
export fn es_malformation_description(malformation: EsMalformation) [*:0]const u8 {
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
export fn es_file_format_description(format: EsFileFormat) [*:0]const u8 {
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
export fn es_file_format_has_validator(format: EsFileFormat) c_int {
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

export fn es_git_validate_repository(
	path: ?[*:0]const u8,
	out: *EsGitValidationResult,
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

test "es_core_version" {
	const v = es_core_version();
	const version_slice = std.mem.span(v);
	try std.testing.expectEqualStrings(core.version.string(), version_slice);
}
