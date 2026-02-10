const Strings = @import("strings.zig").Strings;

pub const strings = Strings{
    // CLI-Statusbeschriftungen
    .label_ok = "OK",
    .label_warn = "WARNUNG",
    .label_fail = "FEHLER",
    .label_notice = "HINWEIS",
    .label_unknown = "UNBEKANNT",
    .label_slow = "LANGSAM",

    // Zusammenfassung
    .summary_title = "Zusammenfassung:",
    .summary_interrupted = "Unterbrochen - Teilzusammenfassung:",
    .summary_valid = "G\xc3\xbcltig:",
    .summary_invalid = "Ung\xc3\xbcltig:",
    .summary_unknown = "Unbekannt:",
    .summary_processed = "Verarbeitet:",

    // Tiefenbeschreibungen
    .depth_structural = "strukturell",
    .depth_full = "vollst\xc3\xa4ndig validiert",

    // Fortschritt / Start
    .scanning_files_found = "Suche... %zu Dateien gefunden",
    .found_files_to_validate = "%zu Dateien zur Validierung gefunden.",
    .checking = "Pr\xc3\xbcfe:",

    // Sonstiges
    .full_validation_unavailable = "Vollst\xc3\xa4ndige Validierung nicht verf\xc3\xbcgbar",
    .via_ffmpeg_suffix = "\xc3\xbcber ffmpeg",

    // Fehlbildungsbeschreibungen
    .malform_pdf_garbage_after_eof = "Nicht-PDF-Daten nach %%EOF angeh\xc3\xa4ngt",
    .malform_png_ancillary_crc_error = "CRC-Fehler in optionalem PNG-Chunk",
    .malform_extension_mismatch = "Dateiendung stimmt nicht mit Inhalt \xc3\xbcberein",
    .malform_pdf_trivial_encryption = "PDF mit leerem Passwort verschl\xc3\xbcsselt (trivialer Schutz)",
    .malform_mime_wrapped_content = "MIME-VERPACKTER M\xc3\x9cLL: Datei hat E-Mail/MIME-Header vorangestellt \xe2\x80\x93 ein fehlerhafter Webdienst lieferte Multipart-MIME statt Rohdaten!",
    .malform_pdf_jbig2_truncated = "abgeschnittene JBIG2-Daten im PDF-Bild",
    .malform_pdf_dct_not_jpeg = "DCTDecode-Bilddaten sind kein g\xc3\xbcltiges JPEG",
    .malform_video_no_frames_decoded = "Video-Decoder hat keine Frames erzeugt (vom Player toleriert)",
    .malform_video_unsupported_profile_no_ffmpeg = "Vollst\xc3\xa4ndige Validierung erfordert ffmpeg (v4.0+) im PATH wegen H.264-Profilkomplexit\xc3\xa4t",
    .malform_xml_undefined_entity = "XML-Entity-Referenz undefiniert (DTD nicht validiert)",
    .malform_rar_header_crc_mismatch = "RAR-Header-CRC-Abweichung (vom Player toleriert)",
    .malform_video_mixed_nal_prefix = "Gemischte oder nicht standardkonforme NAL-L\xc3\xa4ngenpr\xc3\xa4fixe (durch Remux reparierbar)",
    .malform_pdf_missing_trailer = "Fehlendes Trailer-Dictionary (vom Reader toleriert)",
    .malform_pdf_trailer_missing_size = "Trailer fehlt /Size-Schl\xc3\xbcssel (vom Reader toleriert)",
    .malform_pdf_trailer_missing_root = "Trailer fehlt /Root-Schl\xc3\xbcssel (vom Reader toleriert)",
    .malform_magic_bytes_corrupted = "Magic Bytes besch\xc3\xa4digt (identifiziert \xc3\xbcber Dateiendung und sekund\xc3\xa4re Signaturen)",
    .malform_pdf_dct_truncated = "Eingebettetes JPEG ist abgeschnitten (vom Reader toleriert)",
    .malform_pdf_jpx_decode_failed = "Eingebettetes JPEG2000-Dekodieren fehlgeschlagen (vom Reader toleriert)",
    .malform_pdf_ccitt_decode_failed = "Eingebettetes CCITT-Fax-Dekodieren fehlgeschlagen (vom Reader toleriert)",
    .malform_pdf_flate_decode_failed = "Eingebetteter FlateDecode-Stream besch\xc3\xa4digt (vom Reader toleriert)",
    .malform_pdf_lzw_decode_failed = "Eingebetteter LZW-Stream besch\xc3\xa4digt (vom Reader toleriert)",
    .malform_pdf_jbig2_decode_failed = "Eingebettetes JBIG2-Dekodieren fehlgeschlagen (vom Reader toleriert)",
};
