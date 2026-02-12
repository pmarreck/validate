//! i18n string contract.
//!
//! Every locale must provide a `Strings` instance with all fields populated.
//! Missing fields in any locale file will cause a compile error.

pub const Strings = struct {
    // CLI status labels
    label_ok: [:0]const u8,
    label_warn: [:0]const u8,
    label_fail: [:0]const u8,
    label_notice: [:0]const u8,
    label_unknown: [:0]const u8,
    label_slow: [:0]const u8,

    // Summary
    summary_title: [:0]const u8,
    summary_interrupted: [:0]const u8,
    summary_valid: [:0]const u8,
    summary_invalid: [:0]const u8,
    summary_unknown: [:0]const u8,
    summary_processed: [:0]const u8,

    // Depth descriptions
    depth_structural: [:0]const u8,
    depth_full: [:0]const u8,

    // Progress / startup
    scanning_files_found: [:0]const u8, // "Scanning... %zu files found" (format string)
    found_files_to_validate: [:0]const u8, // "Found %zu files to validate." (format string)
    checking: [:0]const u8, // "Checking:" prefix

    // Misc
    full_validation_unavailable: [:0]const u8,
    via_ffmpeg_suffix: [:0]const u8,

    // Malformation descriptions (one per MalformationType variant)
    malform_pdf_garbage_after_eof: [:0]const u8,
    malform_png_ancillary_crc_error: [:0]const u8,
    malform_extension_mismatch: [:0]const u8,
    malform_pdf_trivial_encryption: [:0]const u8,
    malform_mime_wrapped_content: [:0]const u8,
    malform_pdf_jbig2_truncated: [:0]const u8,
    malform_pdf_dct_not_jpeg: [:0]const u8,
    malform_video_no_frames_decoded: [:0]const u8,
    malform_video_unsupported_profile_no_ffmpeg: [:0]const u8,
    malform_xml_undefined_entity: [:0]const u8,
    malform_rar_header_crc_mismatch: [:0]const u8,
    malform_video_mixed_nal_prefix: [:0]const u8,
    malform_pdf_missing_trailer: [:0]const u8,
    malform_pdf_trailer_missing_size: [:0]const u8,
    malform_pdf_trailer_missing_root: [:0]const u8,
    malform_magic_bytes_corrupted: [:0]const u8,
    malform_pdf_dct_truncated: [:0]const u8,
    malform_pdf_jpx_decode_failed: [:0]const u8,
    malform_pdf_ccitt_decode_failed: [:0]const u8,
    malform_pdf_flate_decode_failed: [:0]const u8,
    malform_pdf_lzw_decode_failed: [:0]const u8,
    malform_pdf_jbig2_decode_failed: [:0]const u8,

    // Promo / help
    help_entropy_shield: [:0]const u8,
};
