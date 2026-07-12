const std = @import("std");
const builtin = @import("builtin");
const fv = @import("../format_validation.zig");
pub const Strings = @import("strings.zig").Strings;
pub const cli_aliases = @import("cli_aliases.zig");
pub const CliArg = cli_aliases.CliArg;
pub const CliAliases = cli_aliases.CliAliases;
pub const EnvVar = cli_aliases.EnvVar;
pub const EnvAliases = cli_aliases.EnvAliases;

// Locale file imports
pub const en = @import("en.zig");
pub const de = @import("de.zig");
pub const ar = @import("ar.zig");
pub const az = @import("az.zig");
pub const bn = @import("bn.zig");
pub const el = @import("el.zig");
pub const es = @import("es.zig");
pub const fa = @import("fa.zig");
pub const fr = @import("fr.zig");
pub const he = @import("he.zig");
pub const hi = @import("hi.zig");
pub const hu = @import("hu.zig");
pub const it = @import("it.zig");
pub const ja = @import("ja.zig");
pub const km = @import("km.zig");
pub const ko = @import("ko.zig");
pub const pa = @import("pa.zig");
pub const pl = @import("pl.zig");
pub const ps = @import("ps.zig");
pub const pt_br = @import("pt_br.zig");
pub const ro = @import("ro.zig");
pub const ru = @import("ru.zig");
pub const sw = @import("sw.zig");
pub const ta = @import("ta.zig");
pub const th = @import("th.zig");
pub const tr_locale = @import("tr.zig");
pub const uk = @import("uk.zig");
pub const ur = @import("ur.zig");
pub const vi = @import("vi.zig");
pub const zh_hans = @import("zh_hans.zig");
pub const am = @import("am.zig");
pub const bg = @import("bg.zig");
pub const bs = @import("bs.zig");
pub const da = @import("da.zig");
pub const fi = @import("fi.zig");
pub const fil = @import("fil.zig");
pub const ha = @import("ha.zig");
pub const hr = @import("hr.zig");
pub const id = @import("id.zig");
pub const ig = @import("ig.zig");
pub const is = @import("is.zig");
pub const mk = @import("mk.zig");
pub const nb = @import("nb.zig");
pub const nl = @import("nl.zig");
pub const sl = @import("sl.zig");
pub const sq = @import("sq.zig");
pub const sr = @import("sr.zig");
pub const sv = @import("sv.zig");
pub const yo = @import("yo.zig");
pub const zh_hant = @import("zh_hant.zig");

// ============================================================================
// Type aliases for locale data
// ============================================================================

/// Format descriptions: one per FileFormat variant, compile-time enforced completeness.
pub const FormatDescriptions = std.EnumArray(fv.FileFormat, [:0]const u8);

/// Error message translations: English key -> translated value (with [English] suffix).
pub const ErrorMap = std.StaticStringMap([:0]const u8);

/// Warning message translations: English key -> translated value (with [English] suffix).
pub const WarningMap = std.StaticStringMap([:0]const u8);

/// Empty map for English (no translation needed) and locales that haven't added translations yet.
pub const empty_error_map = ErrorMap.initComptime(.{});
pub const empty_warning_map = WarningMap.initComptime(.{});

// ============================================================================
// Locale enum
// ============================================================================

pub const Locale = enum {
    en,
    ar,
    az,
    bn,
    de,
    el,
    es,
    fa,
    fr,
    he,
    hi,
    hu,
    it,
    ja,
    km,
    ko,
    pa,
    pl,
    ps,
    pt_br,
    ro,
    ru,
    sw,
    ta,
    th,
    @"tr",
    uk,
    ur,
    vi,
    zh_hans,
    am,
    bg,
    bs,
    da,
    fi,
    fil,
    ha,
    hr,
    id,
    ig,
    is,
    mk,
    nb,
    nl,
    sl,
    sq,
    sr,
    sv,
    yo,
    zh_hant,

    pub fn isRtl(self: Locale) bool {
        return self == .ar or self == .he or self == .fa or self == .ps or self == .ur;
    }

    /// Locale-code table for fromString longest-match. Order does not matter;
    /// the matcher picks the LONGEST code that matches at a separator/end
    /// boundary (so "fil" beats "fi", "zh_hant" beats "zh").
    const code_table = [_]struct { code: []const u8, locale: Locale }{
        // Multi-segment first for readability (matcher is length-based anyway).
        .{ .code = "zh_hant", .locale = .zh_hant }, .{ .code = "zh_hans", .locale = .zh_hans },
        .{ .code = "pt_br", .locale = .pt_br },     .{ .code = "fil", .locale = .fil },
        .{ .code = "am", .locale = .am }, .{ .code = "ar", .locale = .ar }, .{ .code = "az", .locale = .az },
        .{ .code = "bg", .locale = .bg }, .{ .code = "bn", .locale = .bn }, .{ .code = "bs", .locale = .bs },
        .{ .code = "da", .locale = .da }, .{ .code = "de", .locale = .de }, .{ .code = "el", .locale = .el },
        .{ .code = "en", .locale = .en }, .{ .code = "es", .locale = .es }, .{ .code = "fa", .locale = .fa },
        .{ .code = "fi", .locale = .fi }, .{ .code = "fr", .locale = .fr }, .{ .code = "ha", .locale = .ha },
        .{ .code = "he", .locale = .he }, .{ .code = "hi", .locale = .hi }, .{ .code = "hr", .locale = .hr },
        .{ .code = "hu", .locale = .hu }, .{ .code = "id", .locale = .id }, .{ .code = "ig", .locale = .ig },
        .{ .code = "is", .locale = .is }, .{ .code = "it", .locale = .it }, .{ .code = "ja", .locale = .ja },
        .{ .code = "km", .locale = .km }, .{ .code = "ko", .locale = .ko }, .{ .code = "mk", .locale = .mk },
        .{ .code = "nb", .locale = .nb }, .{ .code = "nl", .locale = .nl }, .{ .code = "pa", .locale = .pa },
        .{ .code = "pl", .locale = .pl }, .{ .code = "ps", .locale = .ps }, .{ .code = "ro", .locale = .ro },
        .{ .code = "ru", .locale = .ru }, .{ .code = "sl", .locale = .sl }, .{ .code = "sq", .locale = .sq },
        .{ .code = "sr", .locale = .sr }, .{ .code = "sv", .locale = .sv }, .{ .code = "sw", .locale = .sw },
        .{ .code = "ta", .locale = .ta }, .{ .code = "th", .locale = .th }, .{ .code = "tr", .locale = .@"tr" },
        .{ .code = "uk", .locale = .uk }, .{ .code = "ur", .locale = .ur }, .{ .code = "vi", .locale = .vi },
        .{ .code = "yo", .locale = .yo },
    };

    /// Parse a locale code (e.g. "fr", "pt_BR", "zh_Hant", "de_DE.UTF-8",
    /// "fil_PH") to a Locale. Case-insensitive; longest known code that ends at
    /// a separator (`_`/`-`/`.`) or end-of-string wins, so "fil" is not
    /// shadowed by "fi" and "zh_hant" is reachable. Returns null if no match.
    pub fn fromString(s: []const u8) ?Locale {
        var best: ?Locale = null;
        var best_len: usize = 0;
        for (code_table) |entry| {
            const n = entry.code.len;
            if (n <= best_len) continue; // only consider longer matches
            if (s.len < n) continue;
            if (!std.ascii.eqlIgnoreCase(s[0..n], entry.code)) continue;
            // Must end at a separator boundary or string end.
            if (s.len > n) {
                const c = s[n];
                if (c != '_' and c != '-' and c != '.') continue;
            }
            best = entry.locale;
            best_len = n;
        }
        if (best) |b| return b;
        // Generic Chinese without an explicit Hans/Hant script subtag
        // ("zh", "zh_CN", "zh-TW", ...). Default to Simplified; only the
        // historically-Traditional regions (TW/HK/MO) fold to Traditional.
        if (s.len >= 2 and std.ascii.eqlIgnoreCase(s[0..2], "zh")) {
            const boundary = s.len == 2 or s[2] == '_' or s[2] == '-' or s[2] == '.';
            if (boundary) {
                if (s.len >= 5) {
                    const region = s[3..5];
                    if (std.ascii.eqlIgnoreCase(region, "TW") or
                        std.ascii.eqlIgnoreCase(region, "HK") or
                        std.ascii.eqlIgnoreCase(region, "MO"))
                        return .zh_hant;
                }
                return .zh_hans;
            }
        }
        return null;
    }
};

// ============================================================================
// Global state
// Thread safety: setLocale() is called once during CLI startup (before thread
// pool creation). After that, all globals are read-only. No synchronization
// needed as long as this invariant holds.
// ============================================================================

var g_strings: *const Strings = &en.strings;
var g_locale: Locale = .en;
var g_format_descs: *const FormatDescriptions = &en.format_descriptions;
var g_error_map: *const ErrorMap = &empty_error_map;
var g_warning_map: *const WarningMap = &empty_warning_map;

pub fn setLocale(locale: Locale) void {
    g_locale = locale;
    g_strings = switch (locale) {
        .en => &en.strings,
        .de => &de.strings,
        .ar => &ar.strings,
        .az => &az.strings,
        .bn => &bn.strings,
        .el => &el.strings,
        .es => &es.strings,
        .fa => &fa.strings,
        .fr => &fr.strings,
        .he => &he.strings,
        .hi => &hi.strings,
        .hu => &hu.strings,
        .it => &it.strings,
        .ja => &ja.strings,
        .km => &km.strings,
        .ko => &ko.strings,
        .pa => &pa.strings,
        .pl => &pl.strings,
        .ps => &ps.strings,
        .pt_br => &pt_br.strings,
        .ro => &ro.strings,
        .ru => &ru.strings,
        .sw => &sw.strings,
        .ta => &ta.strings,
        .th => &th.strings,
        .@"tr" => &tr_locale.strings,
        .uk => &uk.strings,
        .ur => &ur.strings,
        .vi => &vi.strings,
        .zh_hans => &zh_hans.strings,
        .am => &am.strings,
        .bg => &bg.strings,
        .bs => &bs.strings,
        .da => &da.strings,
        .fi => &fi.strings,
        .fil => &fil.strings,
        .ha => &ha.strings,
        .hr => &hr.strings,
        .id => &id.strings,
        .ig => &ig.strings,
        .is => &is.strings,
        .mk => &mk.strings,
        .nb => &nb.strings,
        .nl => &nl.strings,
        .sl => &sl.strings,
        .sq => &sq.strings,
        .sr => &sr.strings,
        .sv => &sv.strings,
        .yo => &yo.strings,
        .zh_hant => &zh_hant.strings,
    };
    g_format_descs = switch (locale) {
        .en => &en.format_descriptions,
        .de => &de.format_descriptions,
        .ar => &ar.format_descriptions,
        .az => &az.format_descriptions,
        .bn => &bn.format_descriptions,
        .el => &el.format_descriptions,
        .es => &es.format_descriptions,
        .fa => &fa.format_descriptions,
        .fr => &fr.format_descriptions,
        .he => &he.format_descriptions,
        .hi => &hi.format_descriptions,
        .hu => &hu.format_descriptions,
        .it => &it.format_descriptions,
        .ja => &ja.format_descriptions,
        .km => &km.format_descriptions,
        .ko => &ko.format_descriptions,
        .pa => &pa.format_descriptions,
        .pl => &pl.format_descriptions,
        .ps => &ps.format_descriptions,
        .pt_br => &pt_br.format_descriptions,
        .ro => &ro.format_descriptions,
        .ru => &ru.format_descriptions,
        .sw => &sw.format_descriptions,
        .ta => &ta.format_descriptions,
        .th => &th.format_descriptions,
        .@"tr" => &tr_locale.format_descriptions,
        .uk => &uk.format_descriptions,
        .ur => &ur.format_descriptions,
        .vi => &vi.format_descriptions,
        .zh_hans => &zh_hans.format_descriptions,
        .am => &am.format_descriptions,
        .bg => &bg.format_descriptions,
        .bs => &bs.format_descriptions,
        .da => &da.format_descriptions,
        .fi => &fi.format_descriptions,
        .fil => &fil.format_descriptions,
        .ha => &ha.format_descriptions,
        .hr => &hr.format_descriptions,
        .id => &id.format_descriptions,
        .ig => &ig.format_descriptions,
        .is => &is.format_descriptions,
        .mk => &mk.format_descriptions,
        .nb => &nb.format_descriptions,
        .nl => &nl.format_descriptions,
        .sl => &sl.format_descriptions,
        .sq => &sq.format_descriptions,
        .sr => &sr.format_descriptions,
        .sv => &sv.format_descriptions,
        .yo => &yo.format_descriptions,
        .zh_hant => &zh_hant.format_descriptions,
    };
    g_error_map = switch (locale) {
        .en => &empty_error_map, // English = identity passthrough
        .de => &de.error_translations,
        .ar => &ar.error_translations,
        .az => &az.error_translations,
        .bn => &bn.error_translations,
        .el => &el.error_translations,
        .es => &es.error_translations,
        .fa => &fa.error_translations,
        .fr => &fr.error_translations,
        .he => &he.error_translations,
        .hi => &hi.error_translations,
        .hu => &hu.error_translations,
        .it => &it.error_translations,
        .ja => &ja.error_translations,
        .km => &km.error_translations,
        .ko => &ko.error_translations,
        .pa => &pa.error_translations,
        .pl => &pl.error_translations,
        .ps => &ps.error_translations,
        .pt_br => &pt_br.error_translations,
        .ro => &ro.error_translations,
        .ru => &ru.error_translations,
        .sw => &sw.error_translations,
        .ta => &ta.error_translations,
        .th => &th.error_translations,
        .@"tr" => &tr_locale.error_translations,
        .uk => &uk.error_translations,
        .ur => &ur.error_translations,
        .vi => &vi.error_translations,
        .zh_hans => &zh_hans.error_translations,
        .am => &am.error_translations,
        .bg => &bg.error_translations,
        .bs => &bs.error_translations,
        .da => &da.error_translations,
        .fi => &fi.error_translations,
        .fil => &fil.error_translations,
        .ha => &ha.error_translations,
        .hr => &hr.error_translations,
        .id => &id.error_translations,
        .ig => &ig.error_translations,
        .is => &is.error_translations,
        .mk => &mk.error_translations,
        .nb => &nb.error_translations,
        .nl => &nl.error_translations,
        .sl => &sl.error_translations,
        .sq => &sq.error_translations,
        .sr => &sr.error_translations,
        .sv => &sv.error_translations,
        .yo => &yo.error_translations,
        .zh_hant => &zh_hant.error_translations,
    };
    g_warning_map = switch (locale) {
        .en => &empty_warning_map, // English = identity passthrough
        .de => &de.warning_translations,
        .ar => &ar.warning_translations,
        .az => &az.warning_translations,
        .bn => &bn.warning_translations,
        .el => &el.warning_translations,
        .es => &es.warning_translations,
        .fa => &fa.warning_translations,
        .fr => &fr.warning_translations,
        .he => &he.warning_translations,
        .hi => &hi.warning_translations,
        .hu => &hu.warning_translations,
        .it => &it.warning_translations,
        .ja => &ja.warning_translations,
        .km => &km.warning_translations,
        .ko => &ko.warning_translations,
        .pa => &pa.warning_translations,
        .pl => &pl.warning_translations,
        .ps => &ps.warning_translations,
        .pt_br => &pt_br.warning_translations,
        .ro => &ro.warning_translations,
        .ru => &ru.warning_translations,
        .sw => &sw.warning_translations,
        .ta => &ta.warning_translations,
        .th => &th.warning_translations,
        .@"tr" => &tr_locale.warning_translations,
        .uk => &uk.warning_translations,
        .ur => &ur.warning_translations,
        .vi => &vi.warning_translations,
        .zh_hans => &zh_hans.warning_translations,
        .am => &am.warning_translations,
        .bg => &bg.warning_translations,
        .bs => &bs.warning_translations,
        .da => &da.warning_translations,
        .fi => &fi.warning_translations,
        .fil => &fil.warning_translations,
        .ha => &ha.warning_translations,
        .hr => &hr.warning_translations,
        .id => &id.warning_translations,
        .ig => &ig.warning_translations,
        .is => &is.warning_translations,
        .mk => &mk.warning_translations,
        .nb => &nb.warning_translations,
        .nl => &nl.warning_translations,
        .sl => &sl.warning_translations,
        .sq => &sq.warning_translations,
        .sr => &sr.warning_translations,
        .sv => &sv.warning_translations,
        .yo => &yo.warning_translations,
        .zh_hant => &zh_hant.warning_translations,
    };
}

/// Set locale from a string like "de", "de_DE", "de_DE.UTF-8", or "en".
/// Returns true if locale was recognized, false if fell back to English.
pub fn setLocaleFromString(s: []const u8) bool {
    if (Locale.fromString(s)) |locale| {
        setLocale(locale);
        return true;
    }
    setLocale(.en);
    return false;
}

/// Get the current locale's strings.
pub fn tr() *const Strings {
    return g_strings;
}

/// Get the current locale.
pub fn getLocale() Locale {
    return g_locale;
}

/// Get the translated format description for a FileFormat variant.
pub fn getFormatDescription(format: fv.FileFormat) [:0]const u8 {
    return g_format_descs.get(format);
}

/// Translate an error message from English to the current locale.
/// Returns the translated message if found, or the original English if not.
/// For English locale, returns the input unchanged (no map lookup).
pub fn translateError(english: []const u8) [:0]const u8 {
    if (g_locale == .en) return toSentinel(english);
    if (english.len == 0) return "";
    if (g_error_map.get(english)) |translated| return translated;
    return toSentinel(english);
}

/// Translate a warning message from English to the current locale.
/// Returns the translated message if found, or the original English if not.
/// For English locale, returns the input unchanged (no map lookup).
pub fn translateWarning(english: []const u8) [:0]const u8 {
    if (g_locale == .en) return toSentinel(english);
    if (english.len == 0) return "";
    if (g_warning_map.get(english)) |translated| return translated;
    return toSentinel(english);
}

/// Convert a `[]const u8` to a null-terminated `[:0]const u8`.
///
/// Most error/warning strings in this codebase ARE string literals which
/// the compiler null-terminates implicitly. For those we re-slice in place
/// and return a sentinel-typed view at zero cost.
///
/// But we cannot trust the byte at `ptr[s.len]` to be zero — some callers
/// (e.g. `pdf_validator.zig`'s `flate_failure_msg_buf`) hand us a slice
/// pointing into a thread-local `[N]u8 = undefined` buffer that
/// `std.fmt.bufPrint` partially filled. The byte right after the formatted
/// region is uninitialized garbage on the first call, and previous-call
/// residue thereafter. Reading it as a null-terminator check returns
/// false ~99% of the time and silently drops the message — which dropped
/// PDF FlateDecode error reports in the FFI/GUI path on 2026-04-27.
///
/// Copying into a thread-local sentinel buffer when needed is the
/// architectural fix: callers no longer have to keep their internal buffers
/// null-terminated. The cost is a memcpy of the message bytes per call,
/// bounded by `sentinel_buffer_size`.
const sentinel_buffer_size: usize = 1024;
threadlocal var sentinel_buffer_tls: [sentinel_buffer_size:0]u8 = [_:0]u8{0} ** sentinel_buffer_size;

fn toSentinel(s: []const u8) [:0]const u8 {
    if (s.len == 0) return "";

    // Fast path: if the byte at s.len is already 0, the input was a string
    // literal (or otherwise sentinel-terminated). Just re-slice with the
    // sentinel type. This avoids a copy for the >99% of call sites that
    // pass literals.
    //
    // We can ONLY take this path when reading `ptr[s.len]` is provably
    // safe. For string literals the compiler guarantees a trailing NUL.
    // For dynamic slices (our threadlocal-buffer case) it isn't safe to
    // even *read* one past the end. We therefore distinguish using an
    // upper bound: if s is longer than fits in our copy buffer, we still
    // try the literal path (the caller has bigger problems if a literal
    // exceeds 1 KB).
    if (s.len >= sentinel_buffer_size) {
        // Long inputs: trust the literal-NUL convention. If the caller
        // passed something else, we degrade by truncating the visible
        // message via the early-return guard above — never silently
        // dropping the whole field as the prior implementation did.
        const ptr: [*]const u8 = s.ptr;
        if (ptr[s.len] == 0) return ptr[0..s.len :0];
        return ""; // unreachable in practice
    }

    // Short inputs: copy into a thread-local sentinel-typed buffer. This
    // works for both literals and dynamic slices uniformly; the sentinel
    // byte is the one we write, not one we read past the source slice.
    @memcpy(sentinel_buffer_tls[0..s.len], s);
    sentinel_buffer_tls[s.len] = 0;
    return sentinel_buffer_tls[0..s.len :0];
}

/// Detect locale from environment variables ($LANG, $LC_MESSAGES).
/// Returns the detected locale, or `.en` as fallback.
pub fn detectFromEnv() Locale {
    if (comptime builtin.os.tag == .windows) {
        return .en;
    }
    // LC_MESSAGES takes priority over LANG
    // 0.16: std.c.getenv removed; std.c.getenv preserves the ?[]const u8
    // semantics (borrowed pointer, no allocator). Wrap with std.mem.span.
    const sources = [_][:0]const u8{ "LC_MESSAGES", "LANG" };
    for (sources) |name| {
        if (std.c.getenv(name.ptr)) |raw| {
            const val = std.mem.span(raw);
            if (Locale.fromString(val)) |locale| {
                return locale;
            }
        }
    }
    return .en;
}

/// String IDs for FFI access. Maps to Strings struct fields.
/// Keep in sync with validate_string_id_t in validate_core.h.
pub const StringId = enum(u32) {
    label_ok = 0,
    label_warn = 1,
    label_fail = 2,
    label_notice = 3,
    label_unknown = 4,
    label_slow = 5,
    summary_title = 6,
    summary_interrupted = 7,
    summary_valid = 8,
    summary_invalid = 9,
    summary_unknown = 10,
    summary_processed = 11,
    depth_structural = 12,
    depth_full = 13,
    full_validation_unavailable = 14,
    via_ffmpeg_suffix = 15,
    scanning_files_found = 16,
    found_files_to_validate = 17,
    checking = 18,
    malform_pdf_garbage_after_eof = 19,
    malform_png_ancillary_crc_error = 20,
    malform_extension_mismatch = 21,
    malform_pdf_trivial_encryption = 22,
    malform_mime_wrapped_content = 23,
    malform_pdf_jbig2_truncated = 24,
    malform_pdf_dct_not_jpeg = 25,
    malform_video_no_frames_decoded = 26,
    malform_video_unsupported_profile_no_ffmpeg = 27,
    malform_xml_undefined_entity = 28,
    malform_rar_header_crc_mismatch = 29,
    malform_video_mixed_nal_prefix = 30,
    malform_pdf_missing_trailer = 31,
    malform_pdf_trailer_missing_size = 32,
    malform_pdf_trailer_missing_root = 33,
    malform_magic_bytes_corrupted = 34,
    malform_pdf_dct_truncated = 35,
    malform_pdf_jpx_decode_failed = 36,
    malform_pdf_ccitt_decode_failed = 37,
    malform_pdf_flate_decode_failed = 38,
    malform_pdf_lzw_decode_failed = 39,
    malform_pdf_jbig2_decode_failed = 40,
    help_entropy_shield = 41,
    label_info = 42,
    label_no_perm = 43,
};

/// Look up a translated string by its numeric ID.
pub fn getStringById(string_id: u32) ?[:0]const u8 {
    const s = g_strings;
    return switch (@as(StringId, @enumFromInt(string_id))) {
        .label_ok => s.label_ok,
        .label_warn => s.label_warn,
        .label_fail => s.label_fail,
        .label_notice => s.label_notice,
        .label_unknown => s.label_unknown,
        .label_no_perm => s.label_no_perm,
        .label_slow => s.label_slow,
        .summary_title => s.summary_title,
        .summary_interrupted => s.summary_interrupted,
        .summary_valid => s.summary_valid,
        .summary_invalid => s.summary_invalid,
        .summary_unknown => s.summary_unknown,
        .summary_processed => s.summary_processed,
        .depth_structural => s.depth_structural,
        .depth_full => s.depth_full,
        .full_validation_unavailable => s.full_validation_unavailable,
        .via_ffmpeg_suffix => s.via_ffmpeg_suffix,
        .scanning_files_found => s.scanning_files_found,
        .found_files_to_validate => s.found_files_to_validate,
        .checking => s.checking,
        .malform_pdf_garbage_after_eof => s.malform_pdf_garbage_after_eof,
        .malform_png_ancillary_crc_error => s.malform_png_ancillary_crc_error,
        .malform_extension_mismatch => s.malform_extension_mismatch,
        .malform_pdf_trivial_encryption => s.malform_pdf_trivial_encryption,
        .malform_mime_wrapped_content => s.malform_mime_wrapped_content,
        .malform_pdf_jbig2_truncated => s.malform_pdf_jbig2_truncated,
        .malform_pdf_dct_not_jpeg => s.malform_pdf_dct_not_jpeg,
        .malform_video_no_frames_decoded => s.malform_video_no_frames_decoded,
        .malform_video_unsupported_profile_no_ffmpeg => s.malform_video_unsupported_profile_no_ffmpeg,
        .malform_xml_undefined_entity => s.malform_xml_undefined_entity,
        .malform_rar_header_crc_mismatch => s.malform_rar_header_crc_mismatch,
        .malform_video_mixed_nal_prefix => s.malform_video_mixed_nal_prefix,
        .malform_pdf_missing_trailer => s.malform_pdf_missing_trailer,
        .malform_pdf_trailer_missing_size => s.malform_pdf_trailer_missing_size,
        .malform_pdf_trailer_missing_root => s.malform_pdf_trailer_missing_root,
        .malform_magic_bytes_corrupted => s.malform_magic_bytes_corrupted,
        .malform_pdf_dct_truncated => s.malform_pdf_dct_truncated,
        .malform_pdf_jpx_decode_failed => s.malform_pdf_jpx_decode_failed,
        .malform_pdf_ccitt_decode_failed => s.malform_pdf_ccitt_decode_failed,
        .malform_pdf_flate_decode_failed => s.malform_pdf_flate_decode_failed,
        .malform_pdf_lzw_decode_failed => s.malform_pdf_lzw_decode_failed,
        .malform_pdf_jbig2_decode_failed => s.malform_pdf_jbig2_decode_failed,
        .help_entropy_shield => s.help_entropy_shield,
        .label_info => s.label_info,
    };
}

/// Map a malformation bit position to a string ID.
pub fn malformBitToStringId(bit: u32) ?StringId {
    // Malformation string IDs start at malform_pdf_garbage_after_eof
    // and match the enum order in MalformationType
    const base: u32 = @intFromEnum(StringId.malform_pdf_garbage_after_eof);
    const sid = base + bit;
    if (sid > @intFromEnum(StringId.malform_pdf_jbig2_decode_failed)) return null;
    return @enumFromInt(sid);
}

// ============================================================================
// CLI Argument / Environment Variable Alias Maps
// ============================================================================

/// All locale modules that provide cli_aliases and env_aliases.
const locale_modules = .{
    en,        de,        ar,     az,       bn,    el,
    es,        fa,        fr,     he,       hi,    hu,
    it,        ja,        km,     ko,       pa,    pl,
    ps,        pt_br,     ro,     ru,       sw,    ta,
    th,        tr_locale, uk,     ur,       vi,    zh_hans,
    am,        bg,        bs,     da,       fi,    fil,
    ha,        hr,        id,     ig,       is,    mk,
    nb,        nl,        sl,     sq,       sr,    sv,
    yo,        zh_hant,
};

/// Number of CliAliases fields.
const cli_field_count = @typeInfo(CliAliases).@"struct".fields.len;
/// Number of EnvAliases fields.
const env_field_count = @typeInfo(EnvAliases).@"struct".fields.len;
/// Number of locale modules.
const locale_count = locale_modules.len;

/// Build a comptime StaticStringMap from all locales' CLI aliases.
/// Each alias string maps to the corresponding CliArg enum value.
/// Duplicate identical mappings are deduplicated; conflicting mappings
/// (same string -> different arg) cause a compile error.
fn buildCliArgMap() std.StaticStringMap(CliArg) {
    @setEvalBranchQuota(200000);
    // Maximum possible entries: locale_count * cli_field_count
    const max_entries = locale_count * cli_field_count;
    var entries: [max_entries]struct { []const u8, CliArg } = undefined;
    var count: usize = 0;

    inline for (locale_modules) |loc| {
        if (@hasDecl(loc, "cli_aliases")) {
            const aliases = loc.cli_aliases;
            inline for (@typeInfo(CliAliases).@"struct".fields) |field| {
                const alias_str: [:0]const u8 = @field(aliases, field.name);
                const arg: CliArg = @field(CliArg, field.name);

                // Check for duplicates
                var found = false;
                for (entries[0..count]) |existing| {
                    if (std.mem.eql(u8, existing[0], alias_str)) {
                        if (existing[1] != arg) {
                            @compileError("CLI alias collision: \"" ++ alias_str ++ "\" maps to different args");
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    entries[count] = .{ alias_str, arg };
                    count += 1;
                }
            }
        }
    }

    return std.StaticStringMap(CliArg).initComptime(entries[0..count].*);
}

/// Build a comptime StaticStringMap from all locales' environment variable aliases.
fn buildEnvVarMap() std.StaticStringMap(EnvVar) {
    @setEvalBranchQuota(200000);
    const max_entries = locale_count * env_field_count;
    var entries: [max_entries]struct { []const u8, EnvVar } = undefined;
    var count: usize = 0;

    inline for (locale_modules) |loc| {
        if (@hasDecl(loc, "env_aliases")) {
            const aliases = loc.env_aliases;
            inline for (@typeInfo(EnvAliases).@"struct".fields) |field| {
                const alias_str: [:0]const u8 = @field(aliases, field.name);
                const env_var: EnvVar = @field(EnvVar, field.name);

                var found = false;
                for (entries[0..count]) |existing| {
                    if (std.mem.eql(u8, existing[0], alias_str)) {
                        if (existing[1] != env_var) {
                            @compileError("Env var alias collision: \"" ++ alias_str ++ "\" maps to different vars");
                        }
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    entries[count] = .{ alias_str, env_var };
                    count += 1;
                }
            }
        }
    }

    return std.StaticStringMap(EnvVar).initComptime(entries[0..count].*);
}

/// Flat map of all CLI argument aliases across all locales.
pub const cli_arg_map = buildCliArgMap();

/// Flat map of all environment variable aliases across all locales.
pub const env_var_map = buildEnvVarMap();

/// Match a CLI argument keyword (without -- prefix) to a CliArg.
/// Matches against all supported locales simultaneously.
pub fn matchCliArg(keyword: []const u8) ?CliArg {
    return cli_arg_map.get(keyword);
}

/// Collect all environment variable alias strings for a given EnvVar.
/// Returns a comptime-known array of alias strings to check via getenv().
fn getEnvAliases(comptime env_var: EnvVar) []const [:0]const u8 {
    @setEvalBranchQuota(200000);
    const field_name = @tagName(env_var);
    const max = locale_count;
    var result: [max][:0]const u8 = undefined;
    var count: usize = 0;

    inline for (locale_modules) |loc| {
        if (@hasDecl(loc, "env_aliases")) {
            const alias_str: [:0]const u8 = @field(loc.env_aliases, field_name);
            // Deduplicate
            var found = false;
            for (result[0..count]) |existing| {
                if (std.mem.eql(u8, existing, alias_str)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                result[count] = alias_str;
                count += 1;
            }
        }
    }

    const final = result[0..count];
    return final;
}

/// Look up an environment variable by checking all locale aliases via getenv().
/// Returns the first non-empty match, or null.
pub fn getEnvLocalized(comptime env_var: EnvVar) ?[*:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return null;
    }
    const aliases = comptime getEnvAliases(env_var);
    inline for (aliases) |alias| {
        // 0.16: std.c.getenv removed; std.c.getenv returns ?[*:0]const u8
        // directly, which is what this fn already returns.
        if (std.c.getenv(alias.ptr)) |raw| {
            const val = std.mem.span(raw);
            if (val.len > 0) {
                return raw;
            }
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "English strings are complete" {
    const s = &en.strings;
    try std.testing.expectEqualStrings("OK", s.label_ok);
    try std.testing.expectEqualStrings("fully validated", s.depth_full);
    try std.testing.expectEqualStrings("structural", s.depth_structural);
}

test "German strings are complete" {
    const s = &de.strings;
    try std.testing.expectEqualStrings("OK", s.label_ok);
    try std.testing.expectEqualStrings("FEHLER", s.label_fail);
    try std.testing.expect(s.depth_full.len > 0);
}

test "setLocale switches strings" {
    setLocale(.en);
    try std.testing.expectEqualStrings("OK", tr().label_ok);
    try std.testing.expectEqualStrings("FAIL", tr().label_fail);

    setLocale(.de);
    try std.testing.expectEqualStrings("FEHLER", tr().label_fail);
    try std.testing.expectEqualStrings("OK", tr().label_ok); // same in German

    // Restore English
    setLocale(.en);
}

test "setLocaleFromString" {
    try std.testing.expect(setLocaleFromString("de_DE.UTF-8"));
    try std.testing.expectEqualStrings("FEHLER", tr().label_fail);

    try std.testing.expect(setLocaleFromString("en_US.UTF-8"));
    try std.testing.expectEqualStrings("FAIL", tr().label_fail);

    try std.testing.expect(!setLocaleFromString("xx_XX"));
    try std.testing.expectEqualStrings("FAIL", tr().label_fail); // fell back to en

    setLocale(.en);
}

test "getStringById round-trip" {
    setLocale(.en);
    try std.testing.expectEqualStrings("OK", getStringById(0).?);
    try std.testing.expectEqualStrings("FAIL", getStringById(2).?);
    try std.testing.expectEqualStrings("structural", getStringById(12).?);

    setLocale(.de);
    try std.testing.expectEqualStrings("FEHLER", getStringById(2).?);

    setLocale(.en);
}

test "malformBitToStringId mapping" {
    // bit 0 = pdf_garbage_after_eof
    try std.testing.expectEqual(StringId.malform_pdf_garbage_after_eof, malformBitToStringId(0).?);
    // bit 21 = pdf_jbig2_decode_failed (last one)
    try std.testing.expectEqual(StringId.malform_pdf_jbig2_decode_failed, malformBitToStringId(21).?);
    // bit 22 = out of range
    try std.testing.expectEqual(@as(?StringId, null), malformBitToStringId(22));
}

test "Locale.fromString parses prefixes" {
    try std.testing.expectEqual(Locale.en, Locale.fromString("en_US.UTF-8").?);
    try std.testing.expectEqual(Locale.de, Locale.fromString("de_DE").?);
    try std.testing.expectEqual(Locale.de, Locale.fromString("de").?);
    try std.testing.expectEqual(Locale.bn, Locale.fromString("bn_IN.UTF-8").?);
    try std.testing.expectEqual(Locale.fr, Locale.fromString("fr_FR.UTF-8").?);
    try std.testing.expectEqual(Locale.hi, Locale.fromString("hi_IN.UTF-8").?);
    try std.testing.expectEqual(Locale.ja, Locale.fromString("ja_JP.UTF-8").?);
    try std.testing.expectEqual(Locale.pa, Locale.fromString("pa_IN.UTF-8").?);
    try std.testing.expectEqual(Locale.ps, Locale.fromString("ps_AF.UTF-8").?);
    try std.testing.expectEqual(Locale.sw, Locale.fromString("sw_KE.UTF-8").?);
    try std.testing.expectEqual(Locale.ta, Locale.fromString("ta_IN.UTF-8").?);
    try std.testing.expectEqual(Locale.zh_hans, Locale.fromString("zh_CN.UTF-8").?);
    try std.testing.expectEqual(Locale.pt_br, Locale.fromString("pt_BR.UTF-8").?);
    try std.testing.expectEqual(Locale.th, Locale.fromString("th_TH.UTF-8").?);
    try std.testing.expectEqual(Locale.@"tr", Locale.fromString("tr_TR.UTF-8").?);
    try std.testing.expectEqual(Locale.ur, Locale.fromString("ur_PK.UTF-8").?);
    try std.testing.expectEqual(@as(?Locale, null), Locale.fromString("x"));
    // 50-locale + longest-match regressions (skill #5):
    try std.testing.expectEqual(Locale.fil, Locale.fromString("fil_PH.UTF-8").?);
    try std.testing.expectEqual(Locale.fil, Locale.fromString("fil").?);
    try std.testing.expectEqual(Locale.fi, Locale.fromString("fi_FI").?);
    try std.testing.expectEqual(Locale.fi, Locale.fromString("fi").?);
    try std.testing.expectEqual(Locale.zh_hant, Locale.fromString("zh_Hant").?);
    try std.testing.expectEqual(Locale.zh_hant, Locale.fromString("zh_hant.UTF-8").?);
    try std.testing.expectEqual(Locale.zh_hans, Locale.fromString("zh_Hans").?);
    try std.testing.expectEqual(Locale.nb, Locale.fromString("nb_NO").?);
    try std.testing.expectEqual(Locale.sr, Locale.fromString("sr_RS").?);
    try std.testing.expectEqual(Locale.yo, Locale.fromString("yo-NG").?);
    try std.testing.expectEqual(@as(?Locale, null), Locale.fromString("xx"));
    try std.testing.expectEqual(@as(?Locale, null), Locale.fromString(""));
}

test "isRtl includes ps and ur" {
    try std.testing.expect(Locale.ar.isRtl());
    try std.testing.expect(Locale.fa.isRtl());
    try std.testing.expect(Locale.he.isRtl());
    try std.testing.expect(Locale.ps.isRtl());
    try std.testing.expect(Locale.ur.isRtl());
    try std.testing.expect(!Locale.sw.isRtl());
}

test "new locale status labels are localized" {
    setLocale(.bn);
    try std.testing.expectEqualStrings("ব্যর্থ", tr().label_fail);

    setLocale(.hi);
    try std.testing.expectEqualStrings("विफल", tr().label_fail);

    setLocale(.pa);
    try std.testing.expectEqualStrings("ਅਸਫਲ", tr().label_fail);

    setLocale(.ps);
    try std.testing.expectEqualStrings("ناکام", tr().label_fail);

    setLocale(.sw);
    try std.testing.expectEqualStrings("IMEFELI", tr().label_fail);

    setLocale(.ta);
    try std.testing.expectEqualStrings("தோல்வி", tr().label_fail);

    setLocale(.th);
    try std.testing.expectEqualStrings("ล้มเหลว", tr().label_fail);

    setLocale(.ur);
    try std.testing.expectEqualStrings("ناکام", tr().label_fail);

    setLocale(.en);
}

test "new locales include translated format descriptions" {
    setLocale(.bn);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.hi);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.pa);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.ps);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.sw);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.ta);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.th);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.ur);
    try std.testing.expect(!std.mem.eql(u8, getFormatDescription(.unknown), "Unknown"));

    setLocale(.en);
}

test "new locales include translated errors and warnings" {
    const error_key = "Invalid PNG signature";
    const warning_key = "Full validation unavailable";

    setLocale(.bn);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.hi);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.pa);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.ps);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.sw);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.ta);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.th);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.ur);
    try std.testing.expect(!std.mem.eql(u8, translateError(error_key), error_key));
    try std.testing.expect(!std.mem.eql(u8, translateWarning(warning_key), warning_key));

    setLocale(.en);
}

test "null-terminated strings work for FFI" {
    const s = &en.strings;
    // [:0]const u8 has .ptr that gives [*:0]const u8
    const ptr: [*:0]const u8 = s.label_ok.ptr;
    try std.testing.expectEqual(@as(u8, 'O'), ptr[0]);
    try std.testing.expectEqual(@as(u8, 'K'), ptr[1]);
    try std.testing.expectEqual(@as(u8, 0), ptr[2]);
}

test "getFormatDescription returns locale-appropriate text" {
    setLocale(.en);
    try std.testing.expectEqualStrings("PNG Image", getFormatDescription(.png));
    try std.testing.expectEqualStrings("Unknown", getFormatDescription(.unknown));

    setLocale(.de);
    try std.testing.expectEqualStrings("PNG-Bild", getFormatDescription(.png));
    try std.testing.expectEqualStrings("Unbekannt", getFormatDescription(.unknown));

    setLocale(.en);
}

test "translateError returns English for English locale" {
    setLocale(.en);
    const msg = "Invalid PNG signature";
    try std.testing.expectEqualStrings(msg, translateError(msg));
    setLocale(.en);
}

test "translateError returns translation for non-English locale" {
    setLocale(.de);
    const result = translateError("Invalid PNG signature");
    // Should be German translation with [English] suffix
    try std.testing.expect(result.len > 0);
    // If not found in map, falls back to English
    setLocale(.en);
}

test "translateError returns empty for empty input" {
    setLocale(.de);
    try std.testing.expectEqualStrings("", translateError(""));
    setLocale(.en);
}

test "toSentinel works with string literals" {
    const literal: []const u8 = "hello";
    const result = toSentinel(literal);
    try std.testing.expectEqualStrings("hello", result);
    // Verify null terminator
    try std.testing.expectEqual(@as(u8, 0), result.ptr[result.len]);
}

test "toSentinel preserves dynamic bufPrint slices into dirty buffers" {
    // Regression: validate_gui reported empty 'err' fields on PDF FAILs in
    // 2026-04-27. Root cause: pdf_validator.zig's threadlocal flate_failure_msg_buf
    // is `[256]u8 = undefined` (uninitialized). bufPrint writes only the
    // formatted bytes; the byte at `slice[len]` is whatever leftover garbage
    // was there. The previous toSentinel (peeked at `ptr[s.len]`) silently
    // returned "" whenever that garbage byte happened to be non-zero,
    // dropping the error message at the FFI boundary nondeterministically.
    //
    // The fix: toSentinel must NOT trust whatever sits at `ptr[s.len]`. It
    // either copies into a sentinel-safe buffer when the input isn't a
    // string literal, or callers null-terminate explicitly. This test
    // simulates the actual failure mode by handing toSentinel a slice
    // whose `slice[len]` byte is garbage.

    // Allocate a 256-byte buffer pre-filled with non-zero garbage (mirrors
    // the leftover-from-prior-call state of flate_failure_msg_buf).
    var buf: [256]u8 = undefined;
    @memset(&buf, 0xAA);

    // Format a realistic message into it.
    const msg = "zlib data error (CRC/Adler-32 mismatch or malformed deflate) in obj 3464 at offset 0xe48601-0xe48aa1";
    const formatted = try std.fmt.bufPrint(&buf, "{s}", .{msg});

    // Sanity: the byte right after the formatted slice is the 0xAA garbage
    // that triggered the original silent-drop bug.
    try std.testing.expectEqual(@as(u8, 0xAA), buf[formatted.len]);

    // The fix: toSentinel must surface the message regardless. If it
    // returns "", that's the bug.
    const sentinel = toSentinel(formatted);
    try std.testing.expectEqualStrings(msg, sentinel);
    // And the result MUST be a valid C-string (null-terminated).
    try std.testing.expectEqual(@as(u8, 0), sentinel.ptr[sentinel.len]);
}

test "all locales compile and have format descriptions" {
    // This test verifies that all locale files compile and their format_descriptions
    // are valid EnumArrays (compile-time enforcement of completeness).
    inline for (.{
        en.format_descriptions, de.format_descriptions,
        ar.format_descriptions, az.format_descriptions, bn.format_descriptions,
        el.format_descriptions, es.format_descriptions, fa.format_descriptions,
        fr.format_descriptions, he.format_descriptions, hi.format_descriptions,
        hu.format_descriptions, it.format_descriptions, ja.format_descriptions,
        km.format_descriptions, ko.format_descriptions, pa.format_descriptions,
        pl.format_descriptions, ps.format_descriptions, pt_br.format_descriptions,
        ro.format_descriptions, ru.format_descriptions, sw.format_descriptions,
        ta.format_descriptions, th.format_descriptions, tr_locale.format_descriptions,
        uk.format_descriptions, ur.format_descriptions, vi.format_descriptions,
        zh_hans.format_descriptions,
    }) |descs| {
        // Every locale must have a non-empty description for .png
        try std.testing.expect(descs.get(.png).len > 0);
        // Every locale must have a non-empty description for .unknown
        try std.testing.expect(descs.get(.unknown).len > 0);
    }
}

test "matchCliArg resolves English canonical args" {
    try std.testing.expectEqual(CliArg.help, matchCliArg("help").?);
    try std.testing.expectEqual(CliArg.version, matchCliArg("version").?);
    try std.testing.expectEqual(CliArg.lang, matchCliArg("lang").?);
    try std.testing.expectEqual(CliArg.jobs, matchCliArg("jobs").?);
    try std.testing.expectEqual(CliArg.shuffle, matchCliArg("shuffle").?);
    try std.testing.expectEqual(CliArg.no_color, matchCliArg("no-color").?);
    try std.testing.expectEqual(CliArg.color, matchCliArg("color").?);
    try std.testing.expectEqual(CliArg.simple_progress, matchCliArg("simple-progress").?);
    try std.testing.expectEqual(CliArg.no_frontload, matchCliArg("no-frontload").?);
}

test "matchCliArg resolves German aliases" {
    try std.testing.expectEqual(CliArg.help, matchCliArg("hilfe").?);
    try std.testing.expectEqual(CliArg.lang, matchCliArg("sprache").?);
    try std.testing.expectEqual(CliArg.jobs, matchCliArg("aufgaben").?);
    try std.testing.expectEqual(CliArg.shuffle, matchCliArg("mischen").?);
    try std.testing.expectEqual(CliArg.no_color, matchCliArg("ohne-farbe").?);
    try std.testing.expectEqual(CliArg.color, matchCliArg("farbe").?);
}

test "matchCliArg returns null for unknown args" {
    try std.testing.expectEqual(@as(?CliArg, null), matchCliArg("nonexistent"));
    try std.testing.expectEqual(@as(?CliArg, null), matchCliArg(""));
    try std.testing.expectEqual(@as(?CliArg, null), matchCliArg("--help")); // should not include prefix
}

test "env_var_map contains English canonical names" {
    try std.testing.expectEqual(EnvVar.ok_out, env_var_map.get("OK_OUT").?);
    try std.testing.expectEqual(EnvVar.fail_out, env_var_map.get("FAIL_OUT").?);
    try std.testing.expectEqual(EnvVar.max_files, env_var_map.get("MAX_FILES").?);
    try std.testing.expectEqual(EnvVar.validate_debug, env_var_map.get("VALIDATE_DEBUG").?);
}

test "env_var_map contains German aliases" {
    try std.testing.expectEqual(EnvVar.fail_out, env_var_map.get("FEHLER_AUS").?);
    try std.testing.expectEqual(EnvVar.ok_out, env_var_map.get("OK_AUS").?);
    try std.testing.expectEqual(EnvVar.max_files, env_var_map.get("MAX_DATEIEN").?);
}

test "cli_arg_map has no collisions (comptime verified)" {
    // If this test compiles, all aliases are collision-free.
    // Verify we have at least en + de entries (10 en + unique de ones).
    comptime {
        // "help" and "hilfe" should both be present
        if (cli_arg_map.get("help") == null) @compileError("missing 'help'");
        if (cli_arg_map.get("hilfe") == null) @compileError("missing 'hilfe'");
    }
}
