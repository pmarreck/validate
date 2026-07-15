//! PDF format validator
//!
//! Extracted from format_validation.zig. Contains structural and deep validation
//! for PDF files, including embedded image/font/file validation and telemetry.

const std = @import("std");
const runtime = @import("runtime.zig");
const Allocator = std.mem.Allocator;

const format_validation = @import("format_validation.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationDepth = format_validation.ValidationDepth;
const MalformationType = format_validation.MalformationType;
const findInBuffer = format_validation.findInBuffer;
const getenvCrossPlatform = format_validation.getenvCrossPlatform;
const FormatValidator = format_validation.FormatValidator;
const detectFormat = format_validation.detectFormat;

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on");
}

/// Opt into tolerant-mode PDF validation via VALIDATE_PDF_TOLERANT=1.
/// Tolerant mode keeps the legacy behavior of accepting a PDF even when the
/// deep validator detected known-recoverable embedded-image corruption —
/// intended for future auto-repair workflows. Default mode is strict:
/// detected corruption surfaces as a non-zero exit.
fn pdfTolerantMode() bool {
	const value = getenvCrossPlatform("VALIDATE_PDF_TOLERANT") orelse return false;
	return isTruthy(value);
}

const pdf_image_validator = @import("pdf_image_validator.zig");
const pdf_font_validator = @import("pdf_font_validator.zig");
const pdf_embedded_file_validator = @import("pdf_embedded_file_validator.zig");
const pdf_stream_validator = @import("pdf_stream_validator.zig");
const errmsg = @import("error_messages.zig");
const video_validator = @import("video_validator.zig");

const testing = std.testing;

/// Thread-local buffer for formatting the FlateDecode-failure error message
/// so it can carry runtime data (object number, byte offsets) past the
/// validator boundary without an allocation that would need ownership rules.
/// 256 bytes is well above the worst-case "<reason> in obj NNN at offset
/// 0xHHHHHHHH-0xHHHHHHHH" string. Each thread gets its own copy; one validator
/// call writes then the caller reads, so single-thread reuse is safe.
threadlocal var flate_failure_msg_buf: [256]u8 = undefined;

// ============ PDF Image Tolerance ============

pub const PdfImageTolerance = struct {
	malformations: std.EnumSet(MalformationType),
	warning: []const u8,
};

/// Categorize embedded image validation errors for potential future repair.
/// Returns tolerance info if all failures are known-recoverable types, null otherwise.
pub fn toleratedPdfImageFailures(result: pdf_image_validator.PdfImageValidationResult) ?PdfImageTolerance {
	if (result.failed_images == 0) return null;

	var malformations: std.EnumSet(MalformationType) = .{};
	var first_warning: ?[]const u8 = null;

	for (result.results) |res| {
		if (res.valid) continue;
		const msg = res.error_message orelse return null;

		// Categorize the error for potential future repair
		// Each category represents a specific type of corruption that could be fixed
		const malformation_type: ?MalformationType = blk: {
			// JBIG2 errors
			if (std.mem.indexOf(u8, msg, "Truncated JBIG2") != null) {
				break :blk .pdf_jbig2_truncated;
			}
			if (std.mem.indexOf(u8, msg, "JBIG2") != null) {
				break :blk .pdf_jbig2_decode_failed;
			}

			// DCT/JPEG errors - "Not a JPEG file" means wrong magic bytes or encrypted
			if (std.mem.startsWith(u8, msg, "Not a JPEG file")) {
				break :blk .pdf_dct_not_jpeg;
			}
			// Other JPEG errors (truncation, Huffman errors, etc.) from libjpeg-turbo
			if (res.filter == .dct_decode) {
				// Check for specific truncation indicators
				if (std.mem.indexOf(u8, msg, "Truncated") != null or
					std.mem.indexOf(u8, msg, "truncated") != null or
					std.mem.indexOf(u8, msg, "Premature end") != null or
					std.mem.indexOf(u8, msg, "Incomplete") != null or
					std.mem.indexOf(u8, msg, "Unexpected end") != null or
					std.mem.indexOf(u8, msg, "suspended") != null)
				{
					break :blk .pdf_dct_truncated;
				}
				// Any other DCT decode error is still tolerated but categorized as "not JPEG"
				break :blk .pdf_dct_not_jpeg;
			}

			// JPEG2000 errors
			if (res.filter == .jpx_decode) {
				break :blk .pdf_jpx_decode_failed;
			}

			// CCITT fax errors
			if (res.filter == .ccitt_fax_decode) {
				break :blk .pdf_ccitt_decode_failed;
			}

			// FlateDecode errors
			if (std.mem.indexOf(u8, msg, "FlateDecode") != null or
				std.mem.indexOf(u8, msg, "decompression failed") != null)
			{
				break :blk .pdf_flate_decode_failed;
			}

			// LZW errors
			if (std.mem.indexOf(u8, msg, "LZW") != null) {
				break :blk .pdf_lzw_decode_failed;
			}

			// Unknown error - don't tolerate
			break :blk null;
		};

		if (malformation_type) |mt| {
			malformations.insert(mt);
		} else {
			// Unknown error type - fail validation
			return null;
		}

		if (first_warning == null) {
			first_warning = msg;
		}
	}

	if (malformations.count() == 0) return null;

	return .{
		.malformations = malformations,
		.warning = first_warning orelse "Embedded images failed strict validation; accepted with warning",
	};
}

// ============ PDF Structural Validator ============

/// Validate PDF file structure.
pub fn validatePdf(file: *FileSource) ValidationResult {
	return validatePdfWithOptions(file, false);
}

/// Backward-compatible wrapper accepting std.fs.File (for callers not yet migrated to FileSource).
pub fn validatePdfFromFile(file: std.fs.File) ValidationResult {
	const sz = file.getEndPos() catch 0;
	var src = FileSource{ .backing = .{ .file = file }, .file_size = sz };
	return validatePdf(&src);
}

pub fn validatePdfWithOptions(file: *FileSource, skip_magic: bool) ValidationResult {
	// Check header (or skip past it if skip_magic is set)
	var header: [8]u8 = undefined;
	_ = file.read(&header) catch return ValidationResult.invalidCode(.pdf, .failed_to_read, "PDF header");

	if (!skip_magic) {
		if (!std.mem.startsWith(u8, &header, "%PDF-")) {
			return ValidationResult.invalidCode(.pdf, .invalid_value, "PDF header");
		}
	}

	// Check for %%EOF at end
	const file_size = file.getEndPos() catch {
		return ValidationResult.invalidCode(.pdf, .failed_to_get, "file size");
	};

	if (file_size < 20) {
		return ValidationResult.invalidCode(.pdf, .file_too_small, "valid PDF");
	}

	// Tiered search for %%EOF: try small window first (fast path), expand if needed
	const eof_marker = "%%EOF";
	var malformations_local: std.EnumSet(MalformationType) = .{};
	var buffer: [8192]u8 = undefined;
	var bytes_read: usize = 0;

	// First try last 1KB (covers most well-formed PDFs)
	const small_search: u64 = 1024;
	var search_start = if (file_size > small_search) file_size - small_search else 0;
	file.seekTo(search_start) catch {
		return ValidationResult.invalidCode(.pdf, .failed_to_seek, "for trailer");
	};
	bytes_read = file.read(buffer[0..small_search]) catch {
		return ValidationResult.invalidCode(.pdf, .failed_to_read, "trailer");
	};

	var eof_pos = std.mem.lastIndexOf(u8, buffer[0..bytes_read], eof_marker);

	// If not found, expand to 8KB (handles garbage-after-EOF cases)
	if (eof_pos == null and file_size > small_search) {
		const large_search: u64 = 8192;
		search_start = if (file_size > large_search) file_size - large_search else 0;
		file.seekTo(search_start) catch {
			return ValidationResult.invalidCode(.pdf, .failed_to_seek, "for trailer");
		};
		bytes_read = file.read(&buffer) catch {
			return ValidationResult.invalidCode(.pdf, .failed_to_read, "trailer");
		};
		eof_pos = std.mem.lastIndexOf(u8, buffer[0..bytes_read], eof_marker);
	}

	if (eof_pos == null) {
		return ValidationResult.invalidCode(.pdf, .missing, "%%EOF marker (truncated file)");
	}

	// Check for garbage after %%EOF (allowing only whitespace/newlines)
	// REPAIRABLE: pdf_garbage_after_eof - can be fixed by truncating at %%EOF
	const after_eof_start = eof_pos.? + eof_marker.len;
	if (after_eof_start < bytes_read) {
		const after_eof = buffer[after_eof_start..bytes_read];
		for (after_eof) |c| {
			if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0) {
				// Garbage after EOF - tolerable but warn
				malformations_local.insert(.pdf_garbage_after_eof);
				break;
			}
		}
	}

	// Check for encryption by looking for /Encrypt in trailer
	// Encrypted PDFs have limited validation since streams are encrypted
	if (findInBuffer(&buffer, bytes_read, "/Encrypt")) {
		// PDF is encrypted - we can only validate structure
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
			.validation_depth = .structural,
			.has_encrypted_content = true,
		};
	}

	if (malformations_local.count() > 0) {
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
		};
	}
	return ValidationResult.ok(.pdf);
}

/// Simple in-memory PDF magic check.
pub fn validatePdfFromBuffer(data: []const u8) ValidationResult {
	if (data.len < 5) return ValidationResult.invalid(.pdf, "File too small");
	if (std.mem.eql(u8, data[0..5], "%PDF-")) {
		return ValidationResult.ok(.pdf);
	}
	return ValidationResult.invalidCode(.pdf, .invalid_signature, "PDF");
}

// ============ PDF Deep Validation ============

const PDF_TELEMETRY_DEFAULT_SLOW_SECONDS: f64 = 5.0;

const PdfTelemetry = struct {
	enabled: bool,
	slow_threshold_ns: i128,

	fn init() PdfTelemetry {
		const env = getenvCrossPlatform("PDF_TELEMETRY") orelse {
			return .{ .enabled = false, .slow_threshold_ns = 0 };
		};
		if (!isTruthy(env)) {
			return .{ .enabled = false, .slow_threshold_ns = 0 };
		}
		var threshold_seconds = PDF_TELEMETRY_DEFAULT_SLOW_SECONDS;
		if (getenvCrossPlatform("PDF_SLOW_SECONDS")) |threshold_slice| {
			threshold_seconds = std.fmt.parseFloat(f64, threshold_slice) catch threshold_seconds;
		}
		const threshold_ns = @as(i128, @intFromFloat(threshold_seconds * 1_000_000_000.0));
		return .{ .enabled = true, .slow_threshold_ns = threshold_ns };
	}
};

fn logPdfSlow(
	telemetry: PdfTelemetry,
	label: []const u8,
	total_ns: i128,
	structural_ns: i128,
	image_ns: i128,
	font_ns: i128,
	embed_ns: i128,
	image_result: pdf_image_validator.PdfImageValidationResult,
	font_result: pdf_font_validator.FontValidationSummary,
	embed_result: pdf_embedded_file_validator.EmbeddedFileValidationSummary,
) void {
	if (!telemetry.enabled) return;
	if (total_ns < telemetry.slow_threshold_ns) return;

	const total_seconds = @as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0;
	const structural_seconds = @as(f64, @floatFromInt(structural_ns)) / 1_000_000_000.0;
	const image_seconds = @as(f64, @floatFromInt(image_ns)) / 1_000_000_000.0;
	const font_seconds = @as(f64, @floatFromInt(font_ns)) / 1_000_000_000.0;
	const embed_seconds = @as(f64, @floatFromInt(embed_ns)) / 1_000_000_000.0;

	std.debug.print(
		"PDF_SLOW path=\"{s}\" total={d:.2}s structural={d:.2}s images={d:.2}s fonts={d:.2}s embedded={d:.2}s images_total={d} images_validated={d} images_failed={d} images_skipped={d} fonts_total={d} fonts_validated={d} fonts_failed={d} fonts_skipped={d} embeds_total={d} embeds_validated={d} embeds_failed={d} embeds_skipped={d}\n",
		.{
			label,
			total_seconds,
			structural_seconds,
			image_seconds,
			font_seconds,
			embed_seconds,
			image_result.total_images,
			image_result.validated_images,
			image_result.failed_images,
			image_result.skipped_images,
			font_result.total_fonts,
			font_result.validated,
			font_result.failed,
			font_result.skipped,
			embed_result.total_files,
			embed_result.validated,
			embed_result.failed,
			embed_result.skipped,
		},
	);
}

/// Deep PDF validation by parsing and verifying the cross-reference table structure.
/// Checks startxref pointer, xref table, trailer dictionary, embedded images/fonts/files.
/// Outcome of FlateDecode content-stream validation folded back into the
/// caller's malformation / warning state. Returned by applyFlateStreamCheck.
const FlateCheckOutcome = struct {
	/// Set to non-null if the caller must return an `invalidWithDepth` result
	/// (strict mode + corruption detected). The caller is responsible for
	/// producing the ValidationResult.
	hard_fail_message: ?[]const u8 = null,
	/// Whether to insert the pdf_flate_decode_failed malformation and (in
	/// tolerant mode) continue.
	tolerated_malformation: bool = false,
	/// Warning suitable for surfacing in tolerant mode.
	tolerated_warning: ?[]const u8 = null,
	/// Informational note suitable for INFO surfacing — set when the residual
	/// FlateDecode sweep skipped streams it could not validate (e.g. encrypted
	/// PDF where bytes are post-encryption). Honors the project "no silent
	/// skip" invariant: the user is told that N streams were not deep-checked.
	skip_info_message: ?[]const u8 = null,
};

/// Run pdf_stream_validator on the already-parsed PDF buffer, folding results
/// into the caller's malformation set. Honors VALIDATE_PDF_TOLERANT=1: in
/// strict (default) mode a Flate failure surfaces as a hard fail message; in
/// tolerant mode we insert pdf_flate_decode_failed and record a warning so
/// the CLI still exits 0 with diagnostics.
fn applyFlateStreamCheck(
	allocator: Allocator,
	pdf_data: []const u8,
	image_result: pdf_image_validator.PdfImageValidationResult,
	font_result: pdf_font_validator.FontValidationSummary,
	embed_result: pdf_embedded_file_validator.EmbeddedFileValidationSummary,
) FlateCheckOutcome {
	_ = font_result;
	_ = embed_result;

	// Build exclusion set from image object numbers that were already
	// validated through the image pipeline. Font and embed validators don't
	// expose object-number lists on their summary structs; their streams are
	// a small minority of FlateDecode traffic, so we accept a small amount of
	// double-verification there in exchange for implementation simplicity.
	var excluded: std.AutoHashMapUnmanaged(u32, void) = .{};
	defer excluded.deinit(allocator);
	for (image_result.results) |r| {
		excluded.put(allocator, r.object_num, {}) catch {};
	}

	const res = pdf_stream_validator.validatePdfFlateStreams(allocator, pdf_data, &excluded);
	if (res.valid) {
		// Surface lenient-recovery as WARN if any stream needed it.
		if (res.validated_lenient > 0) {
			return .{
				.tolerated_malformation = true,
				.tolerated_warning = "PDF contains FlateDecode streams with truncated/missing zlib Adler-32 trailers (Adobe InDesign style; tolerated by all readers)",
				.skip_info_message = if (res.skipped_encrypted > 0)
					"residual FlateDecode content streams skipped — encrypted PDF, no per-stream decryption available in residual sweep"
				else
					null,
			};
		}
		if (res.skipped_encrypted > 0) {
			return .{
				.skip_info_message = "residual FlateDecode content streams skipped — encrypted PDF, no per-stream decryption available in residual sweep",
			};
		}
		return .{};
	}

	// Format a richer message that includes object number and byte-offset
	// range when we have it. Static reason text ("zlib data error...") on its
	// own forces users to re-extract the failing stream by hand to debug —
	// peter spot-checks a library and wants the info inline. The buffer is
	// thread-local so concurrent validations don't trample each other; each
	// call writes-then-the-caller-reads before the next call fires on the
	// same thread.
	const reason_str: []const u8 = if (res.first_failure) |f| blk: {
		const formatted = std.fmt.bufPrint(
			&flate_failure_msg_buf,
			"{s} in obj {d} at offset 0x{x}-0x{x}",
			.{ f.reason, f.object_num, f.stream_start, f.stream_end },
		) catch f.reason; // fall back to static string on bufPrint failure
		break :blk formatted;
	} else "FlateDecode stream inflation failed";

	if (pdfTolerantMode()) {
		return .{
			.tolerated_malformation = true,
			.tolerated_warning = reason_str,
		};
	}
	return .{ .hard_fail_message = reason_str };
}


pub fn validatePdfDeep(allocator: Allocator, source: *FileSource) ValidationResult {
	const telemetry = PdfTelemetry.init();
	const total_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;

	const file_size = source.getEndPos() catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_get, "file size", .structural);
	};

	if (file_size < 50) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .file_too_small, "valid PDF", .structural);
	}

	const structural_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;

	// Tiered search for %%EOF: try small window first (fast path), expand if needed
	const eof_marker = "%%EOF";
	var malformations_local: std.EnumSet(MalformationType) = .{};
	var warning_message: ?[]const u8 = null;
	var info_message: ?[]const u8 = null;
	var buffer: [8192]u8 = undefined;
	var bytes_read: usize = 0;
	var search_start: u64 = 0;

	// First try last 1KB (covers most well-formed PDFs)
	const small_search: usize = @min(1024, file_size);
	search_start = file_size - small_search;
	source.seekTo(search_start) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_seek, "to trailer area", .structural);
	};
	bytes_read = source.read(buffer[0..small_search]) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_read, "trailer area", .structural);
	};

	var eof_pos = std.mem.lastIndexOf(u8, buffer[0..bytes_read], eof_marker);

	// If not found, expand to 8KB (handles garbage-after-EOF cases)
	if (eof_pos == null and file_size > 1024) {
		const large_search: usize = @min(8192, file_size);
		search_start = file_size - large_search;
		source.seekTo(search_start) catch {
			return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_seek, "to trailer area", .structural);
		};
		bytes_read = source.read(buffer[0..large_search]) catch {
			return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_read, "trailer area", .structural);
		};
		eof_pos = std.mem.lastIndexOf(u8, buffer[0..bytes_read], eof_marker);
	}

	const trailer_data = buffer[0..bytes_read];

	if (eof_pos == null) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .missing, "%%EOF marker", .full);
	}

	// Check for garbage after %%EOF (allowing only whitespace/newlines)
	const after_eof_start = eof_pos.? + eof_marker.len;
	if (after_eof_start < bytes_read) {
		const after_eof = trailer_data[after_eof_start..];
		for (after_eof) |c| {
			if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0) {
				malformations_local.insert(.pdf_garbage_after_eof);
				break;
			}
		}
	}

	// Find startxref keyword
	const startxref_marker = "startxref";
	const startxref_pos = std.mem.lastIndexOf(u8, trailer_data[0..eof_pos.?], startxref_marker);
	if (startxref_pos == null) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .missing, "startxref keyword", .full);
	}

	// Parse the startxref value (number following "startxref")
	const after_startxref = startxref_pos.? + startxref_marker.len;
	const xref_offset = parseStartxrefValue(trailer_data[after_startxref..eof_pos.?]) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "startxref value", .full);
	};

	// Verify xref offset is reasonable
	if (xref_offset >= file_size) {
		return ValidationResult.invalidWithDepth(.pdf, "startxref points beyond file", .full);
	}

	// Seek to xref position and verify it's valid
	source.seekTo(xref_offset) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_seek, "to xref table", .full);
	};

	var xref_header: [20]u8 = undefined;
	const xref_bytes = source.read(&xref_header) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_read, "at startxref position", .full);
	};

	// Skip leading whitespace (some PDF writers put newlines before xref)
	var xref_start: usize = 0;
	while (xref_start < xref_bytes and (xref_header[xref_start] == '\n' or xref_header[xref_start] == '\r' or
		xref_header[xref_start] == ' ' or xref_header[xref_start] == '\t'))
	{
		xref_start += 1;
	}

	// Check for traditional xref table or xref stream
	const remaining = xref_header[xref_start..xref_bytes];
	const is_traditional_xref = remaining.len >= 4 and std.mem.startsWith(u8, remaining, "xref");
	const is_xref_stream = remaining.len >= 1 and remaining[0] >= '0' and remaining[0] <= '9';

	if (!is_traditional_xref and !is_xref_stream) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "xref structure at startxref position", .full);
	}

	// Check if this is a linearized PDF by reading start of file.
	// Read returns up to 4096 bytes — short reads on small PDFs are legitimate
	// (smallest valid PDF is ~100 bytes), so we don't gate on full-buffer here.
	var is_linearized = false;
	source.seekTo(0) catch return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_seek, "to PDF header sample", .full);
	var header_buf: [4096]u8 = undefined;
	const header_read = source.read(&header_buf) catch return ValidationResult.invalidCodeWithDepth(.pdf, .failed_to_read, "PDF header sample", .full);
	if (header_read > 0) {
		is_linearized = std.mem.indexOf(u8, header_buf[0..header_read], "/Linearized") != null;
	}

	// Find and verify trailer dictionary (for traditional xref)
	if (is_traditional_xref) {
		const trailer_keyword = std.mem.lastIndexOf(u8, trailer_data[0..startxref_pos.?], "trailer");
		if (trailer_keyword == null) {
			malformations_local.insert(.pdf_missing_trailer);
		} else {
			const after_trailer = trailer_data[trailer_keyword.?..startxref_pos.?];
			if (std.mem.indexOf(u8, after_trailer, "/Size") == null) {
				malformations_local.insert(.pdf_trailer_missing_size);
			}
			if (!is_linearized and std.mem.indexOf(u8, after_trailer, "/Root") == null) {
				malformations_local.insert(.pdf_trailer_missing_root);
			}
		}
	}

	const structural_ns = if (telemetry.enabled) runtime.nanoTimestamp() - structural_start_ns else 0;

	// Deep validation: read entire file and validate embedded content
	source.seekTo(0) catch {
		return ValidationResult.okWithDepth(.pdf, .full); // Fallback if seek fails
	};

	// Read the entire PDF for deep validation
	const max_pdf_size: u64 = 500 * 1024 * 1024; // 500 MB limit for deep validation
	if (file_size > max_pdf_size) {
		return ValidationResult.okWithDepth(.pdf, .full);
	}

	const safe_size = std.math.cast(usize, file_size) orelse {
		return ValidationResult.okWithDepth(.pdf, .full);
	};
	// A mapped or caller-owned buffer already has a lifetime extending through
	// every deep pass below. Reuse it rather than faulting and copying the whole
	// document; regular-file and Windows fallbacks retain the bounded read path.
	var copied_pdf_data: ?[]u8 = null;
	defer if (copied_pdf_data) |data| allocator.free(data);
	const pdf_data: []const u8 = source.getMappedSlice() orelse blk: {
		const owned = allocator.alloc(u8, safe_size) catch {
			return ValidationResult.okWithDepth(.pdf, .full);
		};
		copied_pdf_data = owned;

		const read_bytes = source.readAll(owned) catch {
			return ValidationResult.okWithDepth(.pdf, .full);
		};
		if (read_bytes != file_size) {
			return ValidationResult.invalidCodeWithDepth(.pdf, .incomplete, "read of PDF", .full);
		}
		break :blk owned;
	};

	// Validate embedded images
	const image_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	var image_result = pdf_image_validator.validatePdfImages(allocator, pdf_data) catch {
		return ValidationResult.okWithDepth(.pdf, .full);
	};
	const image_ns = if (telemetry.enabled) runtime.nanoTimestamp() - image_start_ns else 0;
	defer image_result.deinit(allocator);
	if (!image_result.valid) {
		if (toleratedPdfImageFailures(image_result)) |tolerated| {
			var iter = tolerated.malformations.iterator();
			while (iter.next()) |m| {
				malformations_local.insert(m);
			}
			if (warning_message == null) {
				warning_message = tolerated.warning;
			}
			// Strict (default) mode: detected corruption surfaces as FAIL.
			// Tolerant mode (VALIDATE_PDF_TOLERANT=1) keeps the legacy behavior
			// of accepting the file so future repair workflows can consume it.
			if (!pdfTolerantMode()) {
				return ValidationResult.invalidWithDepth(.pdf, tolerated.warning, .full);
			}
		} else {
			std.debug.print("PDF image validation failed. Total: {d}, Valid: {d}, Failed: {d}, Skipped: {d}\n", .{
				image_result.total_images,
				image_result.validated_images,
				image_result.failed_images,
				image_result.skipped_images,
			});
			var shown: usize = 0;
			for (image_result.results) |res| {
				if (!res.valid and shown < 10) {
					std.debug.print("  Image obj#{d} ({s}): {s}\n", .{
						res.object_num,
						@tagName(res.filter),
						res.error_message orelse "unknown error",
					});
					shown += 1;
				}
			}
			if (image_result.failed_images > 10) {
				std.debug.print("  ... and {d} more failures\n", .{image_result.failed_images - 10});
			}
			return ValidationResult.invalidWithDepth(.pdf, image_result.error_message orelse "Embedded image validation failed", .full);
		}
	}

	// Validate embedded fonts
	const font_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	const font_result = pdf_font_validator.validatePdfFonts(allocator, pdf_data);
	const font_ns = if (telemetry.enabled) runtime.nanoTimestamp() - font_start_ns else 0;
	if (!font_result.valid) {
		return ValidationResult.invalidWithDepth(.pdf, font_result.error_message orelse "Embedded font validation failed", .full);
	}
	if (font_result.failed > 0 and warning_message == null) {
		warning_message = font_result.first_error_message orelse
			"Embedded fonts failed strict validation; accepted with warning";
	}
	// "No silent skip" invariant (RULES.md): if deep font validation was
	// bypassed wholesale (encrypted PDF, key derivation failed, etc.),
	// surface the reason via INFO. Never silent.
	if (font_result.skip_reason) |reason| {
		if (info_message == null) info_message = reason;
	}

	// Validate embedded files (attachments)
	const embed_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	const embed_result = pdf_embedded_file_validator.validatePdfEmbeddedFilesBasic(allocator, pdf_data);
	const embed_ns = if (telemetry.enabled) runtime.nanoTimestamp() - embed_start_ns else 0;
	if (!embed_result.valid) {
		return ValidationResult.invalidWithDepth(.pdf, embed_result.error_message orelse "Embedded file validation failed", .full);
	}
	if (embed_result.skip_reason) |reason| {
		if (info_message == null) info_message = reason;
	}

	// Validate all remaining FlateDecode streams' zlib integrity. This
	// catches corruption inside content / form-XObject / metadata streams
	// that aren't reached by the image, font, or embedded-file validators.
	const flate_outcome = applyFlateStreamCheck(allocator, pdf_data, image_result, font_result, embed_result);
	if (flate_outcome.hard_fail_message) |msg| {
		return ValidationResult.invalidWithDepth(.pdf, msg, .full);
	}
	if (flate_outcome.tolerated_malformation) {
		malformations_local.insert(.pdf_flate_decode_failed);
		if (warning_message == null) warning_message = flate_outcome.tolerated_warning;
	}
	if (flate_outcome.skip_info_message) |info| {
		if (info_message == null) info_message = info;
	}

	const total_ns = if (telemetry.enabled) runtime.nanoTimestamp() - total_start_ns else 0;
	logPdfSlow(telemetry, "<source>", total_ns, structural_ns, image_ns, font_ns, embed_ns, image_result, font_result, embed_result);

	// Determine validation depth: downgrade to structural if any streams were
	// skipped due to exceeding decompression size limits (we can't claim full
	// validation when some streams weren't verified).
	const total_skipped_size_limit = image_result.skipped_size_limit +
		font_result.skipped_size_limit +
		embed_result.skipped_size_limit;
	const final_depth: format_validation.ValidationDepth = if (total_skipped_size_limit > 0) .structural else .full;
	if (total_skipped_size_limit > 0 and warning_message == null) {
		warning_message = "some streams skipped (exceeded decompression size limit); full validation not possible";
	}

	// All validations passed
	if (image_result.decryption_succeeded) {
		malformations_local.insert(.pdf_trivial_encryption);
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
			.warning_message = warning_message,
			.info_message = info_message,
			.validation_depth = final_depth,
			.circumvented_trivial_protection = true,
			.has_encrypted_content = true,
		};
	}
	if (malformations_local.count() > 0) {
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
			.warning_message = warning_message,
			.info_message = info_message,
			.validation_depth = final_depth,
		};
	}
	if (final_depth == .structural) {
		return ValidationResult.okWithDepthAndWarning(.pdf, .structural, warning_message orelse "some streams skipped (exceeded decompression size limit)");
	}
	if (info_message) |info| {
		return ValidationResult.okWithDepthAndInfo(.pdf, .full, info);
	}
	return ValidationResult.okWithDepth(.pdf, .full);
}

/// Deep PDF validation from a memory buffer (used for MIME-wrapped content).
pub fn validatePdfDeepFromBuffer(allocator: Allocator, pdf_data: []const u8) ValidationResult {
	const telemetry = PdfTelemetry.init();
	// Clear the per-thread lenient-recovery flag at the start of each
	// PDF validation. Set by `decompressFlate` in the image / font /
	// embedded-file paths whenever the Adobe-InDesign-style truncated-
	// Adler-32 quirk fires; read at end to surface a WARN verdict.
	pdf_image_validator.lenient_recovery_seen = false;
	const total_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	if (pdf_data.len < 50) {
		return ValidationResult.invalidWithDepth(.pdf, "PDF too small for deep validation", .structural);
	}

	// Verify PDF header
	if (!std.mem.startsWith(u8, pdf_data, "%PDF-")) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "PDF header", .structural);
	}

	var malformations_local: std.EnumSet(MalformationType) = .{};
	var warning_message: ?[]const u8 = null;
	var info_message: ?[]const u8 = null;

	const structural_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;

	// Find %%EOF marker (search from end)
	const eof_marker = "%%EOF";
	const eof_pos = std.mem.lastIndexOf(u8, pdf_data, eof_marker);
	if (eof_pos == null) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .missing, "%%EOF marker", .full);
	}

	// Check for garbage after %%EOF
	const after_eof_start = eof_pos.? + eof_marker.len;
	if (after_eof_start < pdf_data.len) {
		const after_eof = pdf_data[after_eof_start..];
		for (after_eof) |c| {
			if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0) {
				malformations_local.insert(.pdf_garbage_after_eof);
				break;
			}
		}
	}

	// Find startxref
	const startxref_marker = "startxref";
	const startxref_pos = std.mem.lastIndexOf(u8, pdf_data[0..eof_pos.?], startxref_marker);
	if (startxref_pos == null) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .missing, "startxref keyword", .full);
	}

	// Parse xref offset
	const after_startxref = startxref_pos.? + startxref_marker.len;
	const xref_offset = parseStartxrefValue(pdf_data[after_startxref..eof_pos.?]) catch {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "startxref value", .full);
	};

	// Verify xref offset is reasonable
	if (xref_offset >= pdf_data.len) {
		return ValidationResult.invalidWithDepth(.pdf, "startxref points beyond file", .full);
	}

	// Check for xref or xref stream at that position
	var xref_start: usize = std.math.cast(usize, xref_offset) orelse {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "startxref offset out of range", .full);
	};
	while (xref_start < pdf_data.len and (pdf_data[xref_start] == '\n' or pdf_data[xref_start] == '\r' or
		pdf_data[xref_start] == ' ' or pdf_data[xref_start] == '\t'))
	{
		xref_start += 1;
	}

	const is_traditional_xref = xref_start + 4 <= pdf_data.len and std.mem.startsWith(u8, pdf_data[xref_start..], "xref");
	const is_xref_stream = xref_start < pdf_data.len and pdf_data[xref_start] >= '0' and pdf_data[xref_start] <= '9';

	if (!is_traditional_xref and !is_xref_stream) {
		return ValidationResult.invalidCodeWithDepth(.pdf, .invalid_value, "xref structure at startxref position", .full);
	}

	const structural_ns = if (telemetry.enabled) runtime.nanoTimestamp() - structural_start_ns else 0;

	// Validate embedded images
	const image_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	var image_result = pdf_image_validator.validatePdfImages(allocator, pdf_data) catch {
		return ValidationResult.okWithDepth(.pdf, .full);
	};
	const image_ns = if (telemetry.enabled) runtime.nanoTimestamp() - image_start_ns else 0;
	defer image_result.deinit(allocator);
	if (!image_result.valid) {
		if (toleratedPdfImageFailures(image_result)) |tolerated| {
			var iter = tolerated.malformations.iterator();
			while (iter.next()) |m| {
				malformations_local.insert(m);
			}
			if (warning_message == null) {
				warning_message = tolerated.warning;
			}
			// Strict (default) mode: detected corruption surfaces as FAIL.
			// Tolerant mode (VALIDATE_PDF_TOLERANT=1) keeps the legacy behavior.
			if (!pdfTolerantMode()) {
				return ValidationResult.invalidWithDepth(.pdf, tolerated.warning, .full);
			}
		} else {
			return ValidationResult.invalidWithDepth(.pdf, image_result.error_message orelse "Embedded image validation failed", .full);
		}
	}

	// Validate embedded fonts
	const font_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	const font_result = pdf_font_validator.validatePdfFonts(allocator, pdf_data);
	const font_ns = if (telemetry.enabled) runtime.nanoTimestamp() - font_start_ns else 0;
	if (!font_result.valid) {
		return ValidationResult.invalidWithDepth(.pdf, font_result.error_message orelse "Embedded font validation failed", .full);
	}
	if (font_result.failed > 0 and warning_message == null) {
		warning_message = font_result.first_error_message orelse
			"Embedded fonts failed strict validation; accepted with warning";
	}
	if (font_result.skip_reason) |reason| {
		if (info_message == null) info_message = reason;
	}

	// Validate embedded files (attachments)
	const embed_start_ns = if (telemetry.enabled) runtime.nanoTimestamp() else 0;
	const embed_result = pdf_embedded_file_validator.validatePdfEmbeddedFilesBasic(allocator, pdf_data);
	const embed_ns = if (telemetry.enabled) runtime.nanoTimestamp() - embed_start_ns else 0;
	if (!embed_result.valid) {
		return ValidationResult.invalidWithDepth(.pdf, embed_result.error_message orelse "Embedded file validation failed", .full);
	}
	if (embed_result.skip_reason) |reason| {
		if (info_message == null) info_message = reason;
	}

	// Validate all remaining FlateDecode streams' zlib integrity. Same logic
	// as validatePdfDeep — honors VALIDATE_PDF_TOLERANT=1.
	const flate_outcome = applyFlateStreamCheck(allocator, pdf_data, image_result, font_result, embed_result);
	if (flate_outcome.hard_fail_message) |msg| {
		return ValidationResult.invalidWithDepth(.pdf, msg, .full);
	}
	if (flate_outcome.tolerated_malformation) {
		malformations_local.insert(.pdf_flate_decode_failed);
		if (warning_message == null) warning_message = flate_outcome.tolerated_warning;
	}
	if (flate_outcome.skip_info_message) |info| {
		if (info_message == null) info_message = info;
	}

	// Surface the Adobe-InDesign-style truncated-Adler-32 quirk as a WARN.
	// `lenient_recovery_seen` is set by decompressFlate in the image / font /
	// embedded-file paths whenever a stream's deflate body was intact but
	// the zlib trailer was missing. The pdf_stream_validator equivalent is
	// `validated_lenient` which we read at the bottom of applyFlateStreamCheck;
	// here we cover the per-component validators. Either path triggers WARN.
	if (pdf_image_validator.lenient_recovery_seen and warning_message == null) {
		warning_message = "PDF contains FlateDecode streams with truncated/missing zlib Adler-32 trailers (Adobe InDesign style; tolerated by all readers)";
	}

	const total_ns = if (telemetry.enabled) runtime.nanoTimestamp() - total_start_ns else 0;
	logPdfSlow(telemetry, "<buffer>", total_ns, structural_ns, image_ns, font_ns, embed_ns, image_result, font_result, embed_result);

	// Determine validation depth (same logic as validatePdfDeep)
	const total_skipped_size_limit = image_result.skipped_size_limit +
		font_result.skipped_size_limit +
		embed_result.skipped_size_limit;
	const final_depth: format_validation.ValidationDepth = if (total_skipped_size_limit > 0) .structural else .full;
	if (total_skipped_size_limit > 0 and warning_message == null) {
		warning_message = "some streams skipped (exceeded decompression size limit); full validation not possible";
	}

	// Check if we circumvented trivial encryption
	if (image_result.decryption_succeeded) {
		malformations_local.insert(.pdf_trivial_encryption);
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
			.warning_message = warning_message,
			.info_message = info_message,
			.validation_depth = final_depth,
			.circumvented_trivial_protection = true,
			.has_encrypted_content = true,
		};
	}

	if (malformations_local.count() > 0) {
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.malformations = malformations_local,
			.warning_message = warning_message,
			.info_message = info_message,
			.validation_depth = final_depth,
		};
	}
	if (warning_message != null) {
		return ValidationResult{
			.format = .pdf,
			.is_valid = true,
			.error_message = null,
			.warning_message = warning_message,
			.info_message = info_message,
			.validation_depth = final_depth,
		};
	}
	if (final_depth == .structural) {
		return ValidationResult.okWithDepthAndWarning(.pdf, .structural, warning_message orelse "some streams skipped (exceeded decompression size limit)");
	}
	if (info_message) |info| {
		return ValidationResult.okWithDepthAndInfo(.pdf, .full, info);
	}
	return ValidationResult.okWithDepth(.pdf, .full);
}

/// Parse the numeric value after startxref keyword
pub fn parseStartxrefValue(data: []const u8) !u64 {
	// Skip whitespace
	var i: usize = 0;
	while (i < data.len and (data[i] == ' ' or data[i] == '\n' or data[i] == '\r' or data[i] == '\t')) {
		i += 1;
	}

	if (i >= data.len) return error.InvalidFormat;

	// Parse digits
	var value: u64 = 0;
	var found_digit = false;
	while (i < data.len and data[i] >= '0' and data[i] <= '9') {
		value = value * 10 + (data[i] - '0');
		found_digit = true;
		i += 1;
	}

	if (!found_digit) return error.InvalidFormat;
	return value;
}

// ============ Tests ============

test "toleratedPdfImageFailures accepts truncated JBIG2 failures" {
	const results = [_]pdf_image_validator.ImageValidationResult{
		.{
			.object_num = 1,
			.filter = .jbig2_decode,
			.valid = false,
			.error_message = errmsg.truncated("JBIG2 globals"),
			.width = 0,
			.height = 0,
		},
	};

	const image_result = pdf_image_validator.PdfImageValidationResult{
		.valid = false,
		.total_images = 1,
		.validated_images = 0,
		.failed_images = 1,
		.skipped_images = 0,
		.results = &results,
		.error_message = "Some images failed validation",
	};

	const tolerated = toleratedPdfImageFailures(image_result);
	try std.testing.expect(tolerated != null);
	try std.testing.expect(tolerated.?.malformations.contains(.pdf_jbig2_truncated));
}

// ============================================================
// Tests moved from format_validation.zig
// ============================================================

test "detectFormat PDF" {
    const pdf_header = "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 ";
    try std.testing.expectEqual(FileFormat.pdf, detectFormat(pdf_header));
}

test "FormatValidator accepts valid PDF file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid PDF (1 empty page)
    const valid_pdf =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\2 0 obj
        \\<< /Type /Pages /Kids [3 0 R] /Count 1 >>
        \\endobj
        \\3 0 obj
        \\<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        \\endobj
        \\xref
        \\0 4
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\0000000058 00000 n
        \\0000000115 00000 n
        \\trailer
        \\<< /Size 4 /Root 1 0 R >>
        \\startxref
        \\190
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "valid.pdf", .{});
    try file.writePositionalAll(runtime.io(), valid_pdf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "valid.pdf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.pdf, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid PDF failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects corrupted PDF file" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Corrupted PDF: has header but no end marker (truncated)
    const corrupted_pdf =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\% This file is truncated - no end marker
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "corrupted.pdf", .{});
    try file.writePositionalAll(runtime.io(), corrupted_pdf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "corrupted.pdf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.pdf, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator returns structural for encrypted PDF" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Encrypted PDF with /Encrypt in trailer
    const encrypted_pdf =
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\2 0 obj
        \\<< /Type /Pages /Count 0 /Kids [] >>
        \\endobj
        \\3 0 obj
        \\<< /Filter /Standard /V 2 /Length 128 /R 3 /O (xxx) /U (xxx) /P -12 >>
        \\endobj
        \\xref
        \\0 4
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\0000000058 00000 n
        \\0000000115 00000 n
        \\trailer
        \\<< /Size 4 /Root 1 0 R /Encrypt 3 0 R >>
        \\startxref
        \\225
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "encrypted.pdf", .{});
    try file.writePositionalAll(runtime.io(), encrypted_pdf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "encrypted.pdf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.pdf, result.format);
    try std.testing.expect(result.is_valid);
    // Should be structural only since PDF is encrypted
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FormatValidator detects MIME-wrapped PDF and warns loudly" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // MIME-wrapped PDF (as might be returned by buggy web service)
    const mime_wrapped_pdf =
        \\------=_Part_1234_567890.123456789
        \\Content-Type: application/pdf; name=test.pdf
        \\Content-Disposition: inline; filename=test.pdf
        \\
        \\%PDF-1.4
        \\1 0 obj
        \\<< /Type /Catalog /Pages 2 0 R >>
        \\endobj
        \\2 0 obj
        \\<< /Type /Pages /Kids [3 0 R] /Count 1 >>
        \\endobj
        \\3 0 obj
        \\<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        \\endobj
        \\xref
        \\0 4
        \\0000000000 65535 f
        \\0000000009 00000 n
        \\0000000058 00000 n
        \\0000000115 00000 n
        \\trailer
        \\<< /Size 4 /Root 1 0 R >>
        \\startxref
        \\200
        \\%%EOF
    ;

    const file = try tmp_dir.dir.createFile(runtime.io(), "mime_wrapped.pdf", .{});
    try file.writePositionalAll(runtime.io(), mime_wrapped_pdf, 0);
    file.close(runtime.io());

    const path = try runtime.tmpRealpathAlloc(&tmp_dir, allocator, "mime_wrapped.pdf");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should detect it as PDF (from the embedded content)
    try std.testing.expectEqual(FileFormat.pdf, result.format);
    // Should be valid (the embedded PDF is valid)
    try std.testing.expect(result.is_valid);
    // Should have the MIME-wrapped malformation in the set
    try std.testing.expect(result.malformations.contains(.mime_wrapped_content));
    // Should have at least one malformation
    try std.testing.expect(result.hasMalformations());
}
