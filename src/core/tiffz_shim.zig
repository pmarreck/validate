//! Bridge from tiffz's Zig module surface to validate's
//! `ValidationResult` shape. Replaces the zigimg-based TIFF deep
//! validation path; same `validateTiffDeep(allocator, source, format)`
//! contract from the caller's perspective.
//!
//! Architecture mirrors jpeg_validator.zig:
//!   - `validateTiffDeepBuffer(buffer)` is the integration entry point;
//!     `validateTiffDeep` in `image_validators.zig` calls it after
//!     slurping/mmap'ing the buffer.
//!   - INFO findings come through tiffz's callback API; we accumulate
//!     them in a per-call `FindingAccumulator` and drain them into the
//!     `ValidationResult.warning_message` / `info_message` slots after
//!     decode completes.
//!   - Terminal errors map through `routeError` to validate's
//!     `ValidationErrorCode` taxonomy.
//!
//! What we ALSO do (added 2026-05-21 after tiffz reported the original
//! shim claimed structural validation was enough — empirically wasn't):
//!   - Decode every strip and every tile of every materialized IFD.
//!     `Decoder.open` + the IFD walk only inspect ~200 bytes of
//!     header / IFD metadata; the bulk of the file is strip / tile
//!     data, invisible until the codec actually runs. tiffz's
//!     corruption-sweep on `ground_truth_examples/tiff/` shows
//!     structural-only catches ~0% of compressed-TIFF corruption,
//!     versus 57-100% with strips actually decoded.
//!   - Promote `old_style_lzw_codes` to WARN here. We promote it on
//!     a per-callback basis in `routeInfoFinding` instead; same effect.
//!
//! Caveat — UNCOMPRESSED TIFFs (and BMP, raw PCM, etc.): wire bytes
//! ARE the format. There is no codec to fail and no per-strip checksum
//! in the TIFF spec, so byte-level integrity of uncompressed strip
//! data is genuinely outside the format's scope. validate's depth tier
//! for uncompressed-codec TIFFs is "structural + codec-level", not
//! "byte-level integrity". Detecting bit-flips inside uncompressed
//! strip bytes would need an external integrity primitive (sidecar
//! hash, FS metadata, etc.).

const std = @import("std");
const tiffz = @import("tiffz");
const format_validation = @import("format_validation.zig");
const ValidationResult = format_validation.ValidationResult;
const FileFormat = format_validation.FileFormat;
const ValidationErrorCode = format_validation.ValidationErrorCode;

/// Validate a TIFF / TIFF-family buffer through tiffz's structural
/// walker. Returns a validate-native `ValidationResult` carrying the
/// supplied `format` (TIFF / NEF / NRW / CR2 / ARW / DNG / etc.) and
/// the accumulated INFO + WARN findings on success, or a categorical
/// FAIL on terminal error.
pub fn validateTiffDeepBuffer(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    format: FileFormat,
) ValidationResult {
    var handle = tiffz.source.BufferHandle.init(buffer);
    const source = tiffz.Source.fromBuffer(&handle);

    var acc = FindingAccumulator.init(allocator);
    defer acc.deinit();

    var decoder = tiffz.Decoder.openWithLimits(allocator, source, .{
        // Cap the convenience method's internal scratch growth at
        // 64 MiB to preserve the original strip-decode patch's
        // memory ceiling. Larger TIFFs hit DestTooSmall, route
        // through the WARN path, and validate degrades to structural
        // depth rather than allocating gigabytes.
        .max_decompressed_strip_bytes = 64 * 1024 * 1024,
    }) catch |err| return routeError(err, format);
    defer decoder.deinit();

    decoder.setFindingCallback(&FindingAccumulator.callback, @ptrCast(&acc));
    // Replay IFD-0 findings (eagerly parsed in `open` before the
    // callback was set) into the accumulator.
    decoder.scanFindings();

    // Walk additional IFDs (multi-page TIFF, DNG SubIFDs, etc.) so
    // their findings emit through the same callback. `ifd(N)` parses
    // lazily and grows the count on each successful parse; iterate
    // until ifdCount() stops growing or a parse errors out.
    var i: usize = 1;
    while (i < decoder.ifdCount() + 1) : (i += 1) {
        _ = decoder.ifd(i) catch |err| switch (err) {
            // InvalidArgument = ran past the end of the IFD chain
            // (decoder reached next_ifd_offset==0). Normal termination.
            error.InvalidArgument => break,
            // Malformed = next IFD entry was structurally bad. Also a
            // graceful termination for our purposes — earlier IFDs
            // parsed successfully and accumulated their findings.
            error.Malformed => break,
            else => return routeError(err, format),
        };
    }

    // Decode every strip and tile of every materialized IFD so the codec
    // layer actually sees the bulk-data bytes. Without this loop, the
    // open + IFD walk above only inspects ~200 bytes of header/IFD entries
    // and corruption in the rest of the file slips past silently — tiffz
    // measured 0% detection on most compressed TIFFs vs 57-100% with the
    // loop in place. See module docstring caveat re: uncompressed TIFFs.
    //
    // Scratch buffer grows on-demand (doubling, capped at 64 MiB) when a
    // strip/tile decode reports DestTooSmall. Starting at 4 MiB handles
    // every fixture in ground_truth_examples/tiff/; the doubling path
    // covers large scientific / whole-slide-pathology TIFFs without
    // forcing callers to pre-compute strip sizes.
    //
    // Strip/tile decode errors are tracked but NOT propagated as FAIL —
    // per Peter's "any detectable discrepancy → WARN, but only FAIL if a
    // normal decoder would render visibly wrong" heuristic: a normal
    // decoder (libtiff with LZWFixupTags-style backward-compat) accepts
    // some files tiffz currently rejects (e.g., quad-lzw.tif's old-style
    // LZW codes — tiffz's deferred LZWFixupTags issue). We surface the
    // gap as WARN at structural depth so clean-but-uncovered files don't
    // FAIL while still flagging that full validation didn't happen.
    // Per tiffz 2026-05-21 ship: a single library call decodes every
    // strip + tile of every materialized IFD. Internally grows the
    // dest buffer (1 MiB start, doubles on DestTooSmall, capped at
    // limits.max_decompressed_strip_bytes). Replaces the ~60-line
    // inline loop the original strip-decode patch used.
    var strip_decode_failed: bool = false;
    {
        var ws = tiffz.Workspace.init(allocator);
        defer ws.deinit();
        decoder.validateAllStripsAndTiles(&ws) catch |err| switch (err) {
            // Real terminal failures + corruption: surface as FAIL.
            // Per Peter 2026-05-21: a WARN is for malformations that
            // are the tolerated result of some encoder's quirk (e.g.
            // old-style LZW codes — tiffz still decodes them and
            // emits the `old_style_lzw_codes` finding for WARN
            // routing); a FAIL is for malformations too great to
            // decode OR byte corruption (cosmic rays / sector
            // failures / network glitches / etc.). tiffz's
            // `error.Malformed` is the latter — codec saw input it
            // genuinely couldn't make sense of.
            error.Malformed,
            error.OutOfMemory,
            error.LimitExceededIfdCount,
            error.LimitExceededTagCount,
            error.LimitExceededStripCount,
            error.LimitExceededTagValueBytes,
            error.LimitExceededDimension,
            error.LimitExceededTotalSamples,
            error.LimitExceededCodecScratch,
            error.LimitExceededCompressedStripBytes,
            error.LimitExceededDecompressedStripBytes,
            error.SourceTooShort,
            error.SourceShortRead,
            => return routeError(err, format),
            // Genuine tiffz coverage gaps (variants the decoder
            // doesn't support yet): WARN at structural depth so
            // clean-but-uncovered files don't FAIL while still
            // flagging that full validation didn't happen.
            // Includes UnsupportedCompression, UnsupportedPhotometric,
            // UnsupportedPredictor, UnsupportedBitDepth,
            // UnsupportedTagType, DestTooSmall past the
            // max_decompressed_strip_bytes cap, etc.
            else => {
                strip_decode_failed = true;
            },
        };
    }

        // Decode succeeded structurally. Walk the accumulator and pick
    // the most "severe" routing: error > warning > info.
    const final_depth: format_validation.ValidationDepth = if (strip_decode_failed) .structural else .full;
    var result = ValidationResult.okWithDepth(format, final_depth);
    if (strip_decode_failed and result.warning_message == null) {
        result.warning_message = "TIFF strip/tile decode hit unsupported codec or malformed data; structural validation only (likely tiffz coverage gap such as LZWFixupTags-style old-style LZW codes)";
    }
    var first_warning: ?[]const u8 = null;
    for (acc.findings.items) |entry| {
        const routed = routeInfoFinding(entry.code);
        switch (routed) {
            .info => {}, // PASS-tier observation; no slot in flat ValidationResult today.
            .warning => |msg| if (first_warning == null) {
                first_warning = msg;
            },
        }
    }
    if (first_warning) |w| result.warning_message = w;
    return result;
}

/// Map a tiffz Zig error to validate's `ValidationErrorCode` taxonomy.
/// Mirror of `routeStatus` in tiffz's mapping doc but on the Zig error
/// set rather than the C `tiffz_status_t` enum.
fn routeError(err: tiffz.Error, format: FileFormat) ValidationResult {
    return switch (err) {
        // ── Structural FAIL ──
        error.InvalidArgument => ValidationResult.invalidCodeWithDepth(format, .invalid_value, "tiffz API argument", .full),
        error.Malformed => ValidationResult.invalidCodeWithDepth(format, .invalid_value, "TIFF structure", .full),
        error.SourceTooShort => ValidationResult.invalidCodeWithDepth(format, .file_too_small, "TIFF header", .full),
        error.SourceShortRead => ValidationResult.invalidCodeWithDepth(format, .truncated, "TIFF strip/tile data", .full),
        error.SourceSeekTooFarBack => ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "TIFF source", .full),
        error.Io => ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "TIFF source", .full),

        // ── Decoder-level FAIL ──
        error.UnsupportedCompression => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Compression", .full),
        error.UnsupportedPhotometric => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Photometric", .full),
        error.UnsupportedPredictor => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Predictor", .full),
        error.UnsupportedBitDepth => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF BitsPerSample", .full),
        error.UnsupportedTagType => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF tag field type", .full),
        error.DestTooSmall => ValidationResult.invalidCodeWithDepth(format, .buffer_too_small, "tiffz output", .full),

        // ── Resource-limit FAIL ──
        error.LimitExceededIfdCount,
        error.LimitExceededTagCount,
        error.LimitExceededStripCount,
        => ValidationResult.invalidCodeWithDepth(format, .too_many, "TIFF structure", .full),
        error.LimitExceededTagValueBytes,
        error.LimitExceededDimension,
        error.LimitExceededTotalSamples,
        error.LimitExceededCodecScratch,
        error.LimitExceededCompressedStripBytes,
        error.LimitExceededDecompressedStripBytes,
        => ValidationResult.invalidCodeWithDepth(format, .exceeds_bounds, "TIFF resource", .full),

        // ── Allocation / internal ──
        error.OutOfMemory => ValidationResult.invalidCodeWithDepth(format, .out_of_memory, "during TIFF decode", .full),
        error.Bug => ValidationResult.invalidWithDepth(format, "tiffz internal invariant violated", .full),
    };
}

/// Routing for INFO-tier findings. Some get promoted to WARN per
/// validate's policy (e.g. `old_style_lzw_codes`). The flat
/// `ValidationResult` doesn't have a dynamic info_message slot today,
/// so PASS-tier observations are silently dropped — but the typed
/// finding still flows through the accumulator so future enhancements
/// can plumb them.
fn routeInfoFinding(code: tiffz.findings.InfoFinding) RoutedFinding {
    return switch (code) {
        .bigtiff_format => .{ .info = "BigTIFF (64-bit offsets)" },
        .multi_ifd_chain => .{ .info = "multi-IFD TIFF" },
        // Per the 2026-05-18 tiffz Q2 reply: validate-side WARN promotion
        // because the file is technically non-spec (only decodes thanks
        // to libtiff-style heuristic).
        .old_style_lzw_codes => .{ .warning = "TIFF uses legacy LZW codes (off-by-one from spec); decoded via libtiff-style heuristic — file is technically non-spec" },
        .pre_multiplied_alpha => .{ .info = "associated alpha (ExtraSamples=1)" },
        .predictor_applied => .{ .info = "TIFF Predictor applied" },
        .geotiff_tags_present => .{ .info = "GeoTIFF tags present" },
        .cfa_pattern_present => .{ .info = "CFA mosaic raw (DNG / TIFF-EP)" },
        .opcode_list_present => .{ .info = "DNG opcode list" },
        .jpeg_in_tiff => .{ .info = "JPEG-in-TIFF (Compression=7)" },
        .tiled_layout => .{ .info = "tiled layout" },
        .planar_separate => .{ .info = "separate planar configuration" },
        _ => .{ .info = "unknown tiffz finding code" },
    };
}

const RoutedFinding = union(enum) {
    info: []const u8,
    warning: []const u8,
};

/// Per-call accumulator that the tiffz callback appends to. Drains on
/// `deinit`. Not thread-safe; one accumulator per `validateTiffDeepBuffer`
/// call.
const FindingAccumulator = struct {
    findings: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    const Entry = struct {
        code: tiffz.findings.InfoFinding,
    };

    pub fn init(allocator: std.mem.Allocator) FindingAccumulator {
        return .{ .findings = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *FindingAccumulator) void {
        self.findings.deinit(self.allocator);
    }

    /// C-callable callback wired to `Decoder.setFindingCallback`. The
    /// `userdata` is a `*FindingAccumulator`; `finding_id` is the
    /// `InfoFinding` enum value cast to `i32`.
    pub fn callback(
        userdata: ?*anyopaque,
        finding_id: i32,
        payload: ?[*]const u8,
        payload_len: usize,
    ) callconv(.c) void {
        _ = payload;
        _ = payload_len;
        const self: *FindingAccumulator = @ptrCast(@alignCast(userdata.?));
        const code: tiffz.findings.InfoFinding = @enumFromInt(@as(u32, @intCast(finding_id)));
        // OOM during accumulation is silent — the decode itself is
        // unaffected, we just lose that one INFO finding.
        self.findings.append(self.allocator, .{ .code = code }) catch {};
    }
};

test "tiffz_shim: invalid TIFF magic returns invalid" {
    const result = validateTiffDeepBuffer(std.testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, FileFormat.tiff);
    try std.testing.expect(!result.is_valid);
}
