const std = @import("std");
pub const Strings = @import("strings.zig").Strings;
pub const en = @import("en.zig");
pub const de = @import("de.zig");

pub const Locale = enum {
    en,
    de,

    pub fn fromString(s: []const u8) ?Locale {
        if (s.len >= 2) {
            const prefix = s[0..2];
            if (std.mem.eql(u8, prefix, "en")) return .en;
            if (std.mem.eql(u8, prefix, "de")) return .de;
        }
        return null;
    }
};

var g_strings: *const Strings = &en.strings;

pub fn setLocale(locale: Locale) void {
    g_strings = switch (locale) {
        .en => &en.strings,
        .de => &de.strings,
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
    try std.testing.expectEqual(@as(?Locale, null), Locale.fromString("fr"));
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
