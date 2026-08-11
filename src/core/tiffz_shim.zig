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
            // A Compression=7 strip whose embedded JPEG failed strict jpegz
            // validation: byte corruption inside the payload, not a coverage
            // gap — a normal decoder would render it visibly wrong. FAIL.
            error.JpegInTiffPayload,
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
    var first_info: ?[]const u8 = null;
    for (acc.findings.items) |entry| {
        const routed = routeInfoFinding(entry.code);
        switch (routed) {
            .info => |msg| if (first_info == null) {
                first_info = msg;
            },
            .warning => |msg| if (first_warning == null) {
                first_warning = msg;
            },
        }
    }
    if (first_warning) |warning| {
        // WARN describes a tolerated deviation and intentionally takes
        // precedence over a normal-format observation.
        result.warning_message = warning;
    } else if (result.warning_message == null) {
        if (first_info) |info| result.info_message = info;
    }
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
        error.IfdChainCycle => ValidationResult.invalidCodeWithDepth(format, .invalid_value, "TIFF IFD chain cycle (next-IFD offset revisits a parsed IFD)", .full),
        error.SourceTooShort => ValidationResult.invalidCodeWithDepth(format, .file_too_small, "TIFF header", .full),
        error.SourceShortRead => ValidationResult.invalidCodeWithDepth(format, .truncated, "TIFF strip/tile data", .full),
        error.SourceSeekTooFarBack => ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, "TIFF source", .full),
        error.Io => ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "TIFF source", .full),
        // Strict jpegz validation rejected an embedded JPEG strip/tile
        // (Compression=7). Corruption inside the payload, distinct from a
        // malformed TIFF container.
        error.JpegInTiffPayload => ValidationResult.invalidCodeWithDepth(format, .invalid_value, "embedded JPEG payload (Compression=7 strip)", .full),

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
/// validate's policy (e.g. `old_style_lzw_codes`). The first INFO is
/// surfaced through `ValidationResult.info_message` unless a WARN is present.
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
        .lerc_compression => .{ .info = "LERC-in-TIFF (Compression=34887)" },
        .cfa_pattern_present => .{ .info = "CFA mosaic raw (DNG / TIFF-EP)" },
        .opcode_list_present => .{ .info = "DNG opcode list" },
        .jpeg_in_tiff => .{ .info = "JPEG-in-TIFF (Compression=7)" },
        .tiled_layout => .{ .info = "tiled layout" },
        .planar_separate => .{ .info = "separate planar configuration" },
        // libtiff-tolerated deviations (codes 13-15, Peter's 2026-08-01
        // ruling): readable but non-spec → accept with WARN, never silent
        // validity. Code 13 carries a u32 LE excess-byte payload; rendering
        // the exact N is a recorded follow-up (messages here are static).
        .final_strip_padding_tolerated => .{ .warning = "final TIFF strip padded beyond image rows (libtiff-tolerated)" },
        .lzw_missing_eod_tolerated => .{ .warning = "TIFF LZW stream ends at exact extent without EOD terminator (libtiff-tolerated)" },
        .tiled_geometry_via_strip_tags_tolerated => .{ .warning = "tiled TIFF stores geometry via strip tags (libtiff-tolerated)" },
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

    /// C-callable callback wired to `Decoder.setFindingCallback` (the
    /// 99deeb89 nested-findings ABI: identity is `(source_decoder,
    /// finding_code)`, offsets/mapped-code are presence-flagged).
    ///
    /// Only tiffz-source findings (source_decoder == 1) enter the
    /// InfoFinding routing table — a jpegz/jp2z/libjxlz leaf code shares
    /// numeric space with nothing here, so treating it as an InfoFinding
    /// would fabricate meaning. Embedded-decoder corruption still FAILs
    /// through `error.JpegInTiffPayload`; surfacing the nested finding's
    /// specific cause text is a recorded follow-up.
    pub fn callback(
        userdata: ?*anyopaque,
        source_decoder: i32,
        finding_code: i32,
        mapped_finding_code: i32,
        verdict: i32,
        byte_offset: u64,
        host_byte_offset: u64,
        metadata_flags: u32,
        payload: ?[*]const u8,
        payload_len: usize,
    ) callconv(.c) void {
        _ = mapped_finding_code;
        _ = verdict;
        _ = byte_offset;
        _ = host_byte_offset;
        _ = metadata_flags;
        _ = payload;
        _ = payload_len;
        const tiffz_source: i32 = 1; // TIFFZ_SOURCE_TIFFZ
        if (source_decoder != tiffz_source) return;
        const self: *FindingAccumulator = @ptrCast(@alignCast(userdata.?));
        const code: tiffz.findings.InfoFinding = @enumFromInt(@as(u32, @intCast(finding_code)));
        // OOM during accumulation is silent — the decode itself is
        // unaffected, we just lose that one INFO finding.
        self.findings.append(self.allocator, .{ .code = code }) catch {};
    }
};

test "tiffz_shim: invalid TIFF magic returns invalid" {
    const result = validateTiffDeepBuffer(std.testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, FileFormat.tiff);
    try std.testing.expect(!result.is_valid);
}

test "tiffz_shim: LZW strip without EOD is accepted with libtiff-tolerated WARN" {
    // 8×1 1-bit TIFF, one LZW strip. Its bitstream contains CLEAR + literal
    // 0xAA, then only byte-alignment padding: TIFF 6.0 requires EOD before
    // the physical end of the strip, but the stream produces exactly the
    // bounded extent before clean EOF — the case libtiff tolerates. Peter's
    // 2026-08-01 ruling: readable-but-nonconformant data libtiff allows →
    // accept + WARN (tiffz finding 14), never FAIL and never silent validity.
    // (History: pre-ruling this asserted invalid; tiffz@99deeb89 implements
    // the tolerated classifier and this test asserts the WARN routing.)
    const bytes = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0, 0,
        8, 0,
        // ImageWidth = 8, ImageLength = 1, BitsPerSample = 1.
        0x00, 0x01, 0x04, 0x00, 1, 0, 0, 0, 8, 0, 0, 0,
        0x01, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x02, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // Compression = LZW, PhotometricInterpretation = MinisBlack.
        0x03, 0x01, 0x03, 0x00, 1, 0, 0, 0, 5, 0, 0, 0,
        0x06, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // StripOffsets = 110, RowsPerStrip = 1, StripByteCounts = 3.
        0x11, 0x01, 0x04, 0x00, 1, 0, 0, 0, 110, 0, 0, 0,
        0x16, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x17, 0x01, 0x04, 0x00, 1, 0, 0, 0, 3, 0, 0, 0,
        0, 0, 0, 0, // no next IFD
        // CLEAR(256), literal 0xAA, no EOD(257).
        0x80, 0x2A, 0x80,
    };

    const result = validateTiffDeepBuffer(std.testing.allocator, &bytes, .tiff);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqualStrings(
        "TIFF LZW stream ends at exact extent without EOD terminator (libtiff-tolerated)",
        result.warning_message orelse return error.TestExpectedEqual,
    );
}

test "tiffz_shim: LERC strip reaches full validation" {
    // Independent tiffz fixture: 16×16 8-bit grayscale LERC2 v4 with no
    // post-filter. The older tiffz pin reports Compression=34887 as
    // unsupported; this proves validate actually walks the new codec rather
    // than merely accepting its TIFF header.
    const fixture_base64 =
        "SUkqAAgAAAANAAABAwABAAAAEAAAAAEBAwABAAAAEAAAAAIBAwABAAAACAAAAAMBAwABAAAAR4gA" ++
        "AAYBAwABAAAAAQAAABEBBAABAAAAJAEAABUBAwABAAAAAQAAABYBAwABAAAAEAAAABcBBAABAAAA" ++
        "MgEAABwBAwABAAAAAQAAAFMBAwABAAAAAQAAAICkAgByAAAAsgAAAPLFBAACAAAAqgAAAAAAAAAE" ++
        "AAAAAAAAADxHREFMTWV0YWRhdGE+CiAgPEl0ZW0gbmFtZT0iQ09NUFJFU1NJT05fUkVWRVJTSUJJ" ++
        "TElUWSIgZG9tYWluPSJJTUFHRV9TVFJVQ1RVUkUiPkxPU1NMRVNTPC9JdGVtPgo8L0dEQUxNZXRh" ++
        "ZGF0YT4KAExlcmMyIAQAAAACg6A8EAAAABAAAAABAAAAAAEAAAgAAAAyAQAAAQAAAAAAAAAAAOA/" ++
        "AAAAAAAAAAAAAAAAAEBoQAAAAAAAwgAAAQCHQICAYEAoGA6QiGRCqVguoJBoRCqZTrCYbEar2W7A" ++
        "oHBILBqP0Kh0Sq1ar+CweEwum8/wuHxOr9vvBQiHQICAYEAoGA6QiGRCqVguoJBoRCqZTrCYbEar" ++
        "2W7AoHBILBqP0Kh0Sq1ar+CweEwum8/wuHxOr9vvAYCHQEKAMCAUCAdChDAhVAgXQogwIpQIJ0KM" ++
        "MCPUCDdCkDAkFAlHQpQwJVQJV0KYMCaUCWdCnDAn1Al3BYSGQD7gB77gDz7iJ77iLz7kR77kTz7m" ++
        "Z77mbz7oh77ojz7qp77qrz7sx77szz7u577u7w=="
    ;
    var bytes: [598]u8 = undefined;
    try std.base64.standard.Decoder.decode(&bytes, fixture_base64);

    const result = validateTiffDeepBuffer(std.testing.allocator, &bytes, .tiff);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(format_validation.ValidationDepth.full, result.validation_depth);
    try std.testing.expectEqualStrings("LERC-in-TIFF (Compression=34887)", result.info_message orelse return error.TestExpectedEqual);
}

test "tiffz_shim: LERC compression finding is informational" {
    const routed = routeInfoFinding(.lerc_compression);
    switch (routed) {
        .info => |message| try std.testing.expectEqualStrings("LERC-in-TIFF (Compression=34887)", message),
        .warning => return error.TestUnexpectedResult,
    }
}
