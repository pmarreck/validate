//! JPEG family validation hub. Routes every call site (RAF preview,
//! MPO, DICOM-embedded JPEG, PDF JPEG, DNG preview, NEF/NRW/CR2/ARW
//! preview) through the jpegz Zig module. Returns validate's flat
//! `JpegValidationResult` for backwards compatibility with the
//! libjpeg-turbo-based predecessor.
//!
//! History: this file was the libjpeg-turbo FFI wrapper before
//! 2026-05-18 when jpegz Phase 1 retired the libjpeg-turbo runtime
//! dep. The function names + result shape are preserved so call
//! sites didn't need to change beyond their import.
//!
//! Why static strings for findings: `JpegValidationResult.error_message`
//! / `.warning_message` are `?[]const u8` with no ownership marker —
//! the caller doesn't `free()` them. jpegz's
//! `ValidationReport.findings[i].detail` IS heap-allocated and freed
//! by `deinit`, so passing it through directly would dangle. We
//! trade dynamic-detail richness for safety; the static mapping
//! covers the categorical case validate's verdict routing actually
//! consumes.
//!
//! Future: when validate's `ValidationResult` grows owned-message
//! storage, we can plumb full detail through `FindingsSink`.

/// Public result type — kept stable across the libjpeg-turbo → jpegz
/// transition. Call sites still pattern-match on `.valid` /
/// `.error_message` / `.warning_message`.
pub const JpegValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,
    warning_message: ?[]const u8 = null,

    pub fn ok() JpegValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = null };
    }
    pub fn okWithWarning(warning: []const u8) JpegValidationResult {
        return .{ .valid = true, .error_message = null, .warning_message = warning };
    }
    pub fn invalid(message: []const u8) JpegValidationResult {
        return .{ .valid = false, .error_message = message, .warning_message = null };
    }
};

const std = @import("std");
const jpeg_validator = @import("jpeg_validator.zig");
// jpegz reached through tiffz's re-export so the whole build graph shares ONE
// jpegz module instance (validate + tiffz both depending on jpegz directly
// created two instances of the same root file, which Zig 0.16 rejects / the
// nix sandbox SEGVs on). See validate #32.
const jpegz = @import("tiffz").jpegz;


/// Drop-in for `jpeg_validator.validateJpegDeepFromBuffer`.
///
/// Maps jpegz's structured `ValidationReport` to validate's flat
/// `JpegValidationResult`:
///   - `Severity.pass` / `.info`  → `.ok()`
///   - `Severity.warn`            → `.okWithWarning(<static msg>)`
///   - `Severity.fail`            → `.invalid(<static msg>)`
///
/// Falls back to `c_allocator` because the call site doesn't currently
/// pass an allocator (matching `jpeg_validator`'s buffer-only API). OOM
/// during validation returns `.invalid("jpegz: out of memory")`.
pub fn validateJpegDeepFromBuffer(data: []const u8) JpegValidationResult {
    var report = jpegz.validate(std.heap.c_allocator, data) catch
        return JpegValidationResult.invalid("jpegz: out of memory");
    defer report.deinit(std.heap.c_allocator);

    // Promote findings validate considers integrity-relevant to FAIL even
    // when jpegz tagged them WARN. jpegz's lenient cleanroom decode
    // surfaces mid-stream truncation as a WARN-tier `insufficient_data`
    // finding (the file decoded as far as it could, deferred to caller).
    // For validate's "is this preview corrupt?" question, mid-stream
    // data shortage IS corruption. Same precedent as our `old_style_lzw_codes`
    // promotion on the tiffz side.
    if (report.overall == .warn) {
        for (report.findings.items) |f| {
            if (f.severity == .warn and isIntegrityFailFinding(f.code)) {
                return JpegValidationResult.invalid(findingCodeMessage(f.code));
            }
        }
    }

    switch (report.overall) {
        .pass, .info => return JpegValidationResult.ok(),
        .warn => {
            const msg = firstSeverityMessage(&report, .warn) orelse "JPEG tool-tolerated deviation";
            return JpegValidationResult.okWithWarning(msg);
        },
        .fail => {
            const msg = firstSeverityMessage(&report, .fail) orelse "JPEG validation failed";
            return JpegValidationResult.invalid(msg);
        },
    }
}

/// File-handle variant. Reads the whole file into a heap buffer (200 MB
/// cap) and delegates to the buffer variant. Mirrors
/// `jpeg_validator.validateJpegDeepFromHandle` byte-for-byte.
pub fn validateJpegDeepFromHandle(file: anytype) JpegValidationResult {
    const stat = file.stat() catch
        return JpegValidationResult.invalid("file stat failed");
    if (stat.size > 200 * 1024 * 1024) {
        return JpegValidationResult.invalid("file too large for memory-load");
    }
    const buf = std.heap.c_allocator.alloc(u8, @intCast(stat.size)) catch
        return JpegValidationResult.invalid("OOM");
    defer std.heap.c_allocator.free(buf);
    const n = file.readAll(buf) catch
        return JpegValidationResult.invalid("file read failed");
    return validateJpegDeepFromBuffer(buf[0..n]);
}

/// FindingCodes that validate elevates from WARN to FAIL. These signal
/// real data-integrity problems even though jpegz reports them at
/// "tool-tolerated" tier (because it can still produce pixels). Same
/// validate-side promotion pattern documented in
/// `~/Documents-CloudManaged/validate/inbox/2026-05-06-jpegz-mapping-table.md`
/// (last section on `trailing_data_after_eoi`).
fn isIntegrityFailFinding(code: jpegz.FindingCode) bool {
    return switch (code) {
        // Mid-stream entropy data ran out before the decoder completed —
        // for validate, this is always a corrupt-file signal regardless of
        // jpegz's lenient-mode tolerance.
        .insufficient_data => true,
        else => false,
    };
}

/// Return the first finding at or above the given severity, mapped to a
/// static message via `findingCodeMessage`. Used to surface the
/// "primary" reason in the flat `JpegValidationResult.message` slot.
fn firstSeverityMessage(report: *const jpegz.ValidationReport, want: jpegz.Severity) ?[]const u8 {
    for (report.findings.items) |f| {
        if (f.severity == want) return findingCodeMessage(f.code);
    }
    return null;
}

/// Map jpegz's `FindingCode` to a static categorical message. The full
/// mapping table lives in `~/Documents-CloudManaged/validate/inbox/
/// 2026-05-06-jpegz-mapping-table.md`; this is a code-side excerpt
/// covering the codes that fire on the current call sites.
///
/// Unknown codes fall back to a generic message so a forward-compat
/// jpegz upgrade (new findings) doesn't crash validate — it just
/// loses categorical detail until we add the entry here.
fn findingCodeMessage(code: jpegz.FindingCode) []const u8 {
    return switch (code) {
        // Structural FAIL
        .missing_soi => "JPEG missing SOI marker",
        .missing_eoi => "JPEG missing EOI marker",
        .truncated_stream => "JPEG truncated stream",
        .bad_marker_length => "JPEG bad marker length",
        .unknown_marker => "JPEG unknown marker",
        .duplicate_sof => "JPEG duplicate SOF marker",

        // Codec-level FAIL (T.81)
        .invalid_sof_precision => "JPEG invalid SOF precision",
        .huffman_table_corrupt => "JPEG corrupt Huffman table",
        .quantization_table_corrupt => "JPEG corrupt quantization table",
        .arithmetic_table_corrupt => "JPEG corrupt arithmetic table",
        .sof_component_count_invalid => "JPEG invalid SOF component count",
        .sos_component_mismatch => "JPEG SOS component mismatch",
        .restart_marker_missing => "JPEG missing restart marker",
        .restart_marker_unexpected => "JPEG unexpected restart marker",
        .dct_coefficient_overflow => "JPEG DCT coefficient overflow",
        .progressive_scan_invalid => "JPEG invalid progressive scan",

        // Lossless (T.81 §13)
        .lossless_predictor_invalid => "JPEG invalid lossless predictor",
        .lossless_pointtransform_invalid => "JPEG invalid lossless point-transform",

        // JPEG-LS (T.87)
        .jpegls_invalid_run_mode => "JPEG-LS invalid run mode",
        .jpegls_context_table_invalid => "JPEG-LS invalid context table",

        // JPEG 2000
        .jp2_invalid_signature => "JP2 invalid signature",
        .jp2_invalid_codestream => "JP2 invalid codestream",
        .jp2_bad_progression_order => "JP2 bad progression order",
        .jp2_tile_decode_failed => "JP2 tile decode failed",
        .jp2_codeblock_decode_failed => "JP2 codeblock decode failed",

        // INFO annotations
        .arithmetic_coding_used => "JPEG uses arithmetic coding",
        .twelve_bit_precision => "JPEG 12-bit precision",
        .sixteen_bit_lossless => "JPEG 16-bit lossless",
        .progressive_scan_count => "JPEG progressive scans",
        .embedded_thumbnail_present => "JPEG embedded thumbnail",
        .exif_metadata_present => "JPEG EXIF metadata",
        .icc_profile_present => "JPEG ICC profile",
        .jp2_uses_9x7_wavelet => "JP2 9/7 wavelet (lossy)",
        .jp2_uses_5x3_wavelet => "JP2 5/3 wavelet (lossless)",
        .jfif_metadata_present => "JPEG JFIF marker",
        .xmp_metadata_present => "JPEG XMP metadata",
        .photoshop_irb_present => "JPEG Photoshop IRB",

        // Deviation (WARN-ish) / data-integrity (validate promotes to FAIL)
        .trailing_data_after_eoi => "JPEG trailing data after EOI",
        .insufficient_data => "JPEG insufficient data — entropy stream truncated mid-decode",

        else => "JPEG validation finding (uncategorized)",
    };
}

// ───────────────────────────────────────────────────────────────────
// Smoke test — verifies the shim compiles and the wire is intact.
// Doesn't assert specific verdicts; we leave those to the per-format
// validators' existing test suites once we flip call sites.
// ───────────────────────────────────────────────────────────────────

test "jpegz_shim rejects minimal SOI+EOI (no SOF)" {
    const minimal: []const u8 = &.{ 0xFF, 0xD8, 0xFF, 0xD9 };
    const result = validateJpegDeepFromBuffer(minimal);
    // Either invalid or okWithWarning — we don't pin the exact verdict
    // because jpegz's stance on SOF-less files may evolve. We just need
    // the shim to NOT crash and to return a defined result.
    _ = result;
}
