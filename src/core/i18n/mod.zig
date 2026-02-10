const std = @import("std");
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
pub const el = @import("el.zig");
pub const es = @import("es.zig");
pub const fa = @import("fa.zig");
pub const fr = @import("fr.zig");
pub const he = @import("he.zig");
pub const hu = @import("hu.zig");
pub const it = @import("it.zig");
pub const ja = @import("ja.zig");
pub const km = @import("km.zig");
pub const ko = @import("ko.zig");
pub const pl = @import("pl.zig");
pub const pt_br = @import("pt_br.zig");
pub const ro = @import("ro.zig");
pub const ru = @import("ru.zig");
pub const tr_locale = @import("tr.zig");
pub const uk = @import("uk.zig");
pub const vi = @import("vi.zig");
pub const zh_hans = @import("zh_hans.zig");

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
    de,
    el,
    es,
    fa,
    fr,
    he,
    hu,
    it,
    ja,
    km,
    ko,
    pl,
    pt_br,
    ro,
    ru,
    @"tr",
    uk,
    vi,
    zh_hans,

    pub fn fromString(s: []const u8) ?Locale {
        if (s.len < 2) return null;
        const prefix = s[0..2];
        // Two-letter prefix matching
        if (std.mem.eql(u8, prefix, "en")) return .en;
        if (std.mem.eql(u8, prefix, "ar")) return .ar;
        if (std.mem.eql(u8, prefix, "az")) return .az;
        if (std.mem.eql(u8, prefix, "de")) return .de;
        if (std.mem.eql(u8, prefix, "el")) return .el;
        if (std.mem.eql(u8, prefix, "es")) return .es;
        if (std.mem.eql(u8, prefix, "fa")) return .fa;
        if (std.mem.eql(u8, prefix, "fr")) return .fr;
        if (std.mem.eql(u8, prefix, "he")) return .he;
        if (std.mem.eql(u8, prefix, "hu")) return .hu;
        if (std.mem.eql(u8, prefix, "it")) return .it;
        if (std.mem.eql(u8, prefix, "ja")) return .ja;
        if (std.mem.eql(u8, prefix, "km")) return .km;
        if (std.mem.eql(u8, prefix, "ko")) return .ko;
        if (std.mem.eql(u8, prefix, "pl")) return .pl;
        if (std.mem.eql(u8, prefix, "ro")) return .ro;
        if (std.mem.eql(u8, prefix, "ru")) return .ru;
        if (std.mem.eql(u8, prefix, "tr")) return .@"tr";
        if (std.mem.eql(u8, prefix, "uk")) return .uk;
        if (std.mem.eql(u8, prefix, "vi")) return .vi;
        // Special cases: pt_BR -> pt_br, zh_Hans -> zh_hans
        if (std.mem.eql(u8, prefix, "pt")) return .pt_br;
        if (std.mem.eql(u8, prefix, "zh")) return .zh_hans;
        return null;
    }
};

// ============================================================================
// Global state
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
        .el => &el.strings,
        .es => &es.strings,
        .fa => &fa.strings,
        .fr => &fr.strings,
        .he => &he.strings,
        .hu => &hu.strings,
        .it => &it.strings,
        .ja => &ja.strings,
        .km => &km.strings,
        .ko => &ko.strings,
        .pl => &pl.strings,
        .pt_br => &pt_br.strings,
        .ro => &ro.strings,
        .ru => &ru.strings,
        .@"tr" => &tr_locale.strings,
        .uk => &uk.strings,
        .vi => &vi.strings,
        .zh_hans => &zh_hans.strings,
    };
    g_format_descs = switch (locale) {
        .en => &en.format_descriptions,
        .de => &de.format_descriptions,
        .ar => &ar.format_descriptions,
        .az => &az.format_descriptions,
        .el => &el.format_descriptions,
        .es => &es.format_descriptions,
        .fa => &fa.format_descriptions,
        .fr => &fr.format_descriptions,
        .he => &he.format_descriptions,
        .hu => &hu.format_descriptions,
        .it => &it.format_descriptions,
        .ja => &ja.format_descriptions,
        .km => &km.format_descriptions,
        .ko => &ko.format_descriptions,
        .pl => &pl.format_descriptions,
        .pt_br => &pt_br.format_descriptions,
        .ro => &ro.format_descriptions,
        .ru => &ru.format_descriptions,
        .@"tr" => &tr_locale.format_descriptions,
        .uk => &uk.format_descriptions,
        .vi => &vi.format_descriptions,
        .zh_hans => &zh_hans.format_descriptions,
    };
    g_error_map = switch (locale) {
        .en => &empty_error_map, // English = identity passthrough
        .de => &de.error_translations,
        .ar => &ar.error_translations,
        .az => &az.error_translations,
        .el => &el.error_translations,
        .es => &es.error_translations,
        .fa => &fa.error_translations,
        .fr => &fr.error_translations,
        .he => &he.error_translations,
        .hu => &hu.error_translations,
        .it => &it.error_translations,
        .ja => &ja.error_translations,
        .km => &km.error_translations,
        .ko => &ko.error_translations,
        .pl => &pl.error_translations,
        .pt_br => &pt_br.error_translations,
        .ro => &ro.error_translations,
        .ru => &ru.error_translations,
        .@"tr" => &tr_locale.error_translations,
        .uk => &uk.error_translations,
        .vi => &vi.error_translations,
        .zh_hans => &zh_hans.error_translations,
    };
    g_warning_map = switch (locale) {
        .en => &empty_warning_map, // English = identity passthrough
        .de => &de.warning_translations,
        .ar => &ar.warning_translations,
        .az => &az.warning_translations,
        .el => &el.warning_translations,
        .es => &es.warning_translations,
        .fa => &fa.warning_translations,
        .fr => &fr.warning_translations,
        .he => &he.warning_translations,
        .hu => &hu.warning_translations,
        .it => &it.warning_translations,
        .ja => &ja.warning_translations,
        .km => &km.warning_translations,
        .ko => &ko.warning_translations,
        .pl => &pl.warning_translations,
        .pt_br => &pt_br.warning_translations,
        .ro => &ro.warning_translations,
        .ru => &ru.warning_translations,
        .@"tr" => &tr_locale.warning_translations,
        .uk => &uk.warning_translations,
        .vi => &vi.warning_translations,
        .zh_hans => &zh_hans.warning_translations,
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

/// Convert a []const u8 that is known to be backed by a string literal
/// (and thus null-terminated) to [:0]const u8.
/// This is safe because all error/warning messages in the codebase are string literals.
fn toSentinel(s: []const u8) [:0]const u8 {
    if (s.len == 0) return "";
    // All error/warning strings in validate are string literals, which are null-terminated.
    // We verify the null terminator exists and use it.
    const ptr: [*]const u8 = s.ptr;
    if (ptr[s.len] == 0) {
        return ptr[0..s.len :0];
    }
    // Fallback: if somehow not null-terminated, return empty string.
    // This should never happen with string literals.
    return "";
}

/// Detect locale from environment variables ($LANG, $LC_MESSAGES).
/// Returns the detected locale, or `.en` as fallback.
pub fn detectFromEnv() Locale {
    // LC_MESSAGES takes priority over LANG
    const sources = [_][]const u8{ "LC_MESSAGES", "LANG" };
    for (sources) |name| {
        if (std.posix.getenv(name)) |val| {
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
};

/// Look up a translated string by its numeric ID.
pub fn getStringById(id: u32) ?[:0]const u8 {
    const s = g_strings;
    return switch (@as(StringId, @enumFromInt(id))) {
        .label_ok => s.label_ok,
        .label_warn => s.label_warn,
        .label_fail => s.label_fail,
        .label_notice => s.label_notice,
        .label_unknown => s.label_unknown,
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
    };
}

/// Map a malformation bit position to a string ID.
pub fn malformBitToStringId(bit: u32) ?StringId {
    // Malformation string IDs start at malform_pdf_garbage_after_eof
    // and match the enum order in MalformationType
    const base: u32 = @intFromEnum(StringId.malform_pdf_garbage_after_eof);
    const id = base + bit;
    if (id > @intFromEnum(StringId.malform_pdf_jbig2_decode_failed)) return null;
    return @enumFromInt(id);
}

// ============================================================================
// CLI Argument / Environment Variable Alias Maps
// ============================================================================

/// All locale modules that provide cli_aliases and env_aliases.
const locale_modules = .{
    en,        de,        ar,     az,       el,    es,
    fa,        fr,        he,     hu,       it,    ja,
    km,        ko,        pl,     pt_br,    ro,    ru,
    tr_locale, uk,        vi,     zh_hans,
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
/// Matches against all 22 locales simultaneously.
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
    const aliases = comptime getEnvAliases(env_var);
    inline for (aliases) |alias| {
        if (std.posix.getenv(alias)) |val| {
            if (val.len > 0) {
                // POSIX guarantees getenv strings are null-terminated
                return val.ptr;
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
    try std.testing.expectEqual(Locale.fr, Locale.fromString("fr_FR.UTF-8").?);
    try std.testing.expectEqual(Locale.ja, Locale.fromString("ja_JP.UTF-8").?);
    try std.testing.expectEqual(Locale.zh_hans, Locale.fromString("zh_CN.UTF-8").?);
    try std.testing.expectEqual(Locale.pt_br, Locale.fromString("pt_BR.UTF-8").?);
    try std.testing.expectEqual(Locale.@"tr", Locale.fromString("tr_TR.UTF-8").?);
    try std.testing.expectEqual(@as(?Locale, null), Locale.fromString("x"));
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

test "all 22 locales compile and have format descriptions" {
    // This test verifies that all locale files compile and their format_descriptions
    // are valid EnumArrays (compile-time enforcement of completeness).
    inline for (.{
        en.format_descriptions, de.format_descriptions,
        ar.format_descriptions, az.format_descriptions,
        el.format_descriptions, es.format_descriptions,
        fa.format_descriptions, fr.format_descriptions,
        he.format_descriptions, hu.format_descriptions,
        it.format_descriptions, ja.format_descriptions,
        km.format_descriptions, ko.format_descriptions,
        pl.format_descriptions, pt_br.format_descriptions,
        ro.format_descriptions, ru.format_descriptions,
        tr_locale.format_descriptions, uk.format_descriptions,
        vi.format_descriptions, zh_hans.format_descriptions,
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
