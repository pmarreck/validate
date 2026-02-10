const Strings = @import("strings.zig").Strings;

pub const strings = Strings{
    // CLI status labels
    .label_ok = "OK",
    .label_warn = "WARN",
    .label_fail = "FAIL",
    .label_notice = "NOTICE",
    .label_unknown = "UNKNOWN",
    .label_slow = "SLOW",

    // Summary
    .summary_title = "Summary:",
    .summary_interrupted = "Interrupted - Partial Summary:",
    .summary_valid = "Valid:",
    .summary_invalid = "Invalid:",
    .summary_unknown = "Unknown:",
    .summary_processed = "Processed:",

    // Depth descriptions
    .depth_structural = "structural",
    .depth_full = "fully validated",

    // Progress / startup
    .scanning_files_found = "Scanning... %zu files found",
    .found_files_to_validate = "Found %zu files to validate.",
    .checking = "Checking:",

    // Misc
    .full_validation_unavailable = "Full validation unavailable",
    .via_ffmpeg_suffix = "via ffmpeg",

    // Malformation descriptions
    .malform_pdf_garbage_after_eof = "non-PDF data appended after %%EOF",
    .malform_png_ancillary_crc_error = "CRC error in ancillary PNG chunk",
    .malform_extension_mismatch = "file extension doesn't match content",
    .malform_pdf_trivial_encryption = "PDF encrypted with empty password (trivial protection)",
    .malform_mime_wrapped_content = "MIME-WRAPPED GARBAGE: file has email/MIME headers prepended - some buggy web service returned multipart MIME instead of raw content!",
    .malform_pdf_jbig2_truncated = "truncated JBIG2 data in PDF image",
    .malform_pdf_dct_not_jpeg = "DCTDecode image data is not valid JPEG",
    .malform_video_no_frames_decoded = "video decoder produced no frames (player-tolerated)",
    .malform_video_unsupported_profile_no_ffmpeg = "full validation of this file requires ffmpeg (v4.0+) on PATH due to H.264 profile complexity",
    .malform_xml_undefined_entity = "XML entity reference undefined (DTD not validated)",
    .malform_rar_header_crc_mismatch = "RAR header CRC mismatch (player-tolerated)",
    .malform_video_mixed_nal_prefix = "mixed or nonstandard NAL length prefixes (repairable by remux)",
    .malform_pdf_missing_trailer = "missing trailer dictionary (reader-tolerated)",
    .malform_pdf_trailer_missing_size = "trailer missing /Size key (reader-tolerated)",
    .malform_pdf_trailer_missing_root = "trailer missing /Root key (reader-tolerated)",
    .malform_magic_bytes_corrupted = "magic bytes corrupted (identified via extension and secondary signatures)",
    .malform_pdf_dct_truncated = "embedded JPEG is truncated (reader-tolerated)",
    .malform_pdf_jpx_decode_failed = "embedded JPEG2000 decode failed (reader-tolerated)",
    .malform_pdf_ccitt_decode_failed = "embedded CCITT fax decode failed (reader-tolerated)",
    .malform_pdf_flate_decode_failed = "embedded FlateDecode stream corrupted (reader-tolerated)",
    .malform_pdf_lzw_decode_failed = "embedded LZW stream corrupted (reader-tolerated)",
    .malform_pdf_jbig2_decode_failed = "embedded JBIG2 decode failed (reader-tolerated)",
};
