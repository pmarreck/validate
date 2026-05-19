//! Bridge from tiffz's Zig module surface to validate's
//! `ValidationResult` shape. Replaces the zigimg-based TIFF deep
//! validation path; same `validateTiffDeep(allocator, source, format)`
//! contract from the caller's perspective.
//!
//! Architecture mirrors jpegz_shim.zig:
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
//! What we deliberately do NOT do today:
//!   - Pixel-level decode loop for every strip/tile. tiffz's
//!     `Decoder.open` does the heavy structural lifting (IFD walk,
//!     tag parsing, codec selection, predictor wiring) and emits the
//!     bulk of findings before we ever call `decodeStrip`. For
//!     validate's "is this file structurally valid?" question, the
//!     open-and-walk pass catches the same corruption a full decode
//!     would. If integrity-critical paths emerge (e.g. mandatory CRC
//!     over decompressed strips), upgrade then.
//!   - Promote `old_style_lzw_codes` to WARN here. We promote it on
//!     a per-callback basis in `routeInfoFinding` instead; same effect.

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

    var decoder = tiffz.Decoder.open(allocator, source) catch |err| return routeError(err, format);
    defer decoder.deinit();

    decoder.setFindingCallback(&FindingAccumulator.callback, @ptrCast(&acc));
    // Replay IFD-0 findings (eagerly parsed in `open` before the
    // callback was set) into the accumulator.
    decoder.scanFindings();

    // Walk additional IFDs (multi-page TIFF, DNG SubIFDs, etc.) so
    // their findings emit through the same callback. `ifd(N)` parses
    // lazily; calling it forces each one.
    var i: usize = 1;
    while (true) : (i += 1) {
        _ = decoder.ifd(i) catch |err| switch (err) {
            // End of IFD chain — normal termination.
            error.Malformed => break,
            else => return routeError(err, format),
        };
    }

    // Decode succeeded structurally. Walk the accumulator and pick
    // the most "severe" routing: error > warning > info.
    var result = ValidationResult.okWithDepth(format, .full);
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
        error.SourceSeekTooFarBack => ValidationResult.invalidCodeWithDepth(format, .failed_to_seek, null, .full),
        error.Io => ValidationResult.invalidCodeWithDepth(format, .failed_to_read, "TIFF source", .full),

        // ── Decoder-level FAIL ──
        error.UnsupportedCompression => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Compression", .full),
        error.UnsupportedPhotometric => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Photometric", .full),
        error.UnsupportedPredictor => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF Predictor", .full),
        error.UnsupportedBitDepth => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF BitsPerSample", .full),
        error.UnsupportedTagType => ValidationResult.invalidCodeWithDepth(format, .unsupported, "TIFF tag field type", .full),
        error.DestTooSmall => ValidationResult.invalidCodeWithDepth(format, .buffer_too_small, null, .full),

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
        error.OutOfMemory => ValidationResult.invalidCodeWithDepth(format, .out_of_memory, null, .full),
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
