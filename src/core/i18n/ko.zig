const Strings = @import("strings.zig").Strings;
const i18n = @import("mod.zig");
const cli = @import("cli_aliases.zig");

pub const strings = Strings{
    // CLI status labels
    .label_ok = "OK",
    .label_warn = "\xea\xb2\xbd\xea\xb3\xa0",
    .label_fail = "\xec\x8b\xa4\xed\x8c\xa8",
    .label_notice = "\xec\x95\x8c\xeb\xa6\xbc",
    .label_unknown = "\xec\x95\x8c \xec\x88\x98 \xec\x97\x86\xec\x9d\x8c",
    .label_slow = "\xeb\x8a\x90\xeb\xa6\xbc",

    // Summary
    .summary_title = "\xec\x9a\x94\xec\x95\xbd:",
    .summary_interrupted = "\xec\xa4\x91\xeb\x8b\xa8\xeb\x90\xa8 - \xeb\xb6\x80\xeb\xb6\x84 \xec\x9a\x94\xec\x95\xbd:",
    .summary_valid = "\xec\x9c\xa0\xed\x9a\xa8:",
    .summary_invalid = "\xeb\xac\xb4\xed\x9a\xa8:",
    .summary_unknown = "\xec\x95\x8c \xec\x88\x98 \xec\x97\x86\xec\x9d\x8c:",
    .summary_processed = "\xec\xb2\x98\xeb\xa6\xac\xeb\x90\xa8:",

    // Depth descriptions
    .depth_structural = "\xea\xb5\xac\xec\xa1\xb0\xec\xa0\x81",
    .depth_full = "\xec\x99\x84\xec\xa0\x84\xed\x9e\x88 \xea\xb2\x80\xec\xa6\x9d\xeb\x90\xa8",

    // Progress / startup
    .scanning_files_found = "\xec\x8a\xa4\xec\xba\x94 \xec\xa4\x91... %zu\xea\xb0\x9c \xed\x8c\x8c\xec\x9d\xbc \xeb\xb0\x9c\xea\xb2\xac",
    .found_files_to_validate = "%zu\xea\xb0\x9c \xed\x8c\x8c\xec\x9d\xbc \xea\xb2\x80\xec\xa6\x9d \xec\x98\x88\xec\xa0\x95.",
    .checking = "\xed\x99\x95\xec\x9d\xb8 \xec\xa4\x91:",

    // Misc
    .full_validation_unavailable = "\xec\x99\x84\xec\xa0\x84\xed\x95\x9c \xea\xb2\x80\xec\xa6\x9d \xeb\xb6\x88\xea\xb0\x80",
    .via_ffmpeg_suffix = "ffmpeg \xea\xb2\xbd\xec\x9c\xa0",

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
    .help_entropy_shield = "Entropy Shield로 향후 파일 손상을 방지하세요: https://entropyshield.app",
};

pub const cli_aliases = cli.CliAliases{
    .help = "\xeb\x8f\x84\xec\x9b\x80",
    .version = "\xeb\xb2\x84\xec\xa0\x84",
    .lang = "\xec\x96\xb8\xec\x96\xb4",
    .jobs = "\xec\x9e\x91\xec\x97\x85",
    .shuffle = "\xec\x84\x9e\xea\xb8\xb0",
    .stress = "stress",
    .no_color = "\xec\x83\x89\xec\x83\x81-\xec\x97\x86\xec\x9d\x8c",
    .color = "\xec\x83\x89\xec\x83\x81",
    .simple_progress = "\xea\xb0\x84\xeb\x8b\xa8-\xec\xa7\x84\xed\x96\x89",
    .no_frontload = "\xec\x9a\xb0\xec\x84\xa0-\xec\x97\x86\xec\x9d\x8c",
    .append = "append",
    .json = "json",
    .ndjson = "ndjson",
    .about = "about",
    .max_memory = "max-memory",
    .test_coverage = "test-coverage",
    .modes = "modes",
    .shotgun_bytes = "shotgun-bytes",
};

pub const env_aliases = cli.EnvAliases{
    .ok_out = "OK_CHULRYEOK",
    .warn_out = "GYEONGGO_CHULRYEOK",
    .fail_out = "SILPAE_CHULRYEOK",
    .unknown_out = "MOREUN_CHULRYEOK",
    .slow_out = "NEURIN_CHULRYEOK",
    .debug_out = "DEBUG_CHULRYEOK",
    .begin_out = "SIJAK_CHULRYEOK",
    .max_files = "CHOIDAE_FAIL",
    .validate_debug = "VALIDATE_DEBUG",
    .no_bidi = "NO_BIDI",
    .max_memory = "MAX_MEMORY",
};

pub const format_descriptions = i18n.FormatDescriptions.init(.{
    .unknown = "Unknown", .png = "PNG Image", .jpeg = "JPEG Image", .jxl = "JPEG XL Image", .gif = "GIF Image", .bmp = "BMP Image", .webp = "WebP Image", .tiff = "TIFF Image", .heic = "HEIC/HEIF Image", .avif = "AVIF Image", .exr = "OpenEXR HDR Image", .svg = "SVG Vector Graphics", .psd = "Adobe Photoshop", .ai = "Adobe Illustrator", .eps = "Encapsulated PostScript", .sketch = "Sketch Design File", .aep = "Adobe After Effects Project", .dng = "Adobe DNG RAW", .cr2 = "Canon CR2 RAW",
    .cr3 = "Canon CR3 RAW", .nef = "Nikon RAW", .arw = "Sony RAW",
    .raf = "Fuji RAW",
    .orf = "Olympus RAW",
    .rw2 = "Panasonic RAW",
    .pef = "Pentax RAW", .zip = "ZIP Archive", .gzip = "Gzip Compressed", .bzip2 = "Bzip2 Compressed", .xz = "XZ Compressed", .zstd = "Zstandard Compressed",  .br = "Brotli Compressed", .hqx = "BinHex 4.0 Archive", .rar = "RAR Archive", .cpt = "Compact Pro Archive", .sevenz = "7-Zip Archive", .tar = "Tar Archive", .epub = "EPUB eBook", .docx = "Word Document (OOXML)", .xlsx = "Excel Spreadsheet (OOXML)", .pptx = "PowerPoint (OOXML)", .doc = "Word Document (97-2003)", .xls = "Excel Spreadsheet (97-2003)", .ppt = "PowerPoint (97-2003)", .odt = "OpenDocument Text", .ods = "OpenDocument Spreadsheet", .odp = "OpenDocument Presentation", .pdf = "PDF Document", .rtf = "Rich Text Format", .pages = "Apple Pages", .wpd = "WordPerfect Document", .cwk = "ClarisWorks/AppleWorks", .mwd = "MacWrite Document", .mp4 = "MP4 Video", .mov = "QuickTime Video", .mkv = "Matroska Video", .webm = "WebM Video", .avi = "AVI Video", .swf = "Flash SWF", .flv = "Flash Video", .prores = "Apple ProRes Video", .av1 = "AV1 Video", .mpeg_ps = "MPEG Program Stream", .mpeg_ts = "MPEG Transport Stream", .mpeg_es = "MPEG Elementary Stream", .ivf = "IVF Video Container", .asf = "ASF Media", .dv = "DV Video", .mp3 = "MP3 Audio", .flac = "FLAC Audio", .wav = "WAV Audio", .m4a = "M4A Audio", .alac = "Apple Lossless Audio", .aiff = "AIFF Audio", .ogg = "Ogg Audio", .ogv = "Ogg Video (Theora)", .ape = "Monkey's Audio", .wavpack = "WavPack Audio", .midi = "Standard MIDI File", .dsf = "DSD Stream File", .dff = "DSDIFF Audio", .ac3 = "Dolby Digital AC-3 Audio", .eac3 = "Dolby Digital Plus Audio", .amr = "AMR Audio", .au = "AU/SND Audio", .tta = "True Audio (TTA)", .caf = "CAF Audio", .aac_adts = "AAC-LC Audio (ADTS)", .jpeg2000 = "JPEG2000 Image", .jbig2 = "JBIG2 Bi-level Image", .qoi = "QOI Image", .pam = "Portable Anymap Image", .dpx = "DPX Image", .tga = "TGA Image", .mod = "ProTracker Module", .xm = "FastTracker Module", .it = "Impulse Tracker Module", .s3m = "Scream Tracker Module", .als = "Ableton Live Set", .rpp = "Reaper Project", .logicx = "Logic Pro X Project", .flp = "FL Studio Project", .song = "Studio One Project", .bwproject = "Bitwig Studio Project", .cpr = "Cubase Project", .ptx = "Pro Tools Session", .band = "GarageBand Project", .reason = "Reason Project", .prproj = "Adobe Premiere Pro Project", .indd = "Adobe InDesign Document", .idml = "Adobe InDesign Markup", .dwg = "AutoCAD Drawing", .blend = "Blender 3D Project", .fcpxml = "Final Cut Pro XML", .drp = "DaVinci Resolve Project", .mdb = "Microsoft Access Database (97-2003)", .accdb = "Microsoft Access Database", .dbf = "dBASE Database", .iso = "ISO 9660 Disk Image", .dmg = "Apple Disk Image", .hdf5 = "HDF5 Scientific Data", .parquet = "Apache Parquet Data", .netcdf = "NetCDF Scientific Data", .fits = "FITS Astronomical Data", .dicom = "DICOM Medical Image", .fasta = "FASTA Sequence", .fastq = "FASTQ Sequencing Reads", .warc = "WARC Web Archive", .wad = "DOOM WAD Archive", .pak = "Quake PAK Archive", .lspk = "Larian Studios PAK", .chromium_pak = "Chromium Resource PAK", .bsp = "BSP Map File", .vpk = "Valve PAK Archive", .nes = "NES ROM", .snes = "SNES ROM", .n64 = "Nintendo 64 ROM", .gb = "Game Boy ROM", .gba = "Game Boy Advance ROM", .nds = "Nintendo DS ROM", .genesis = "Sega Genesis ROM", .chd = "MAME CHD Image", .iff = "IFF Container", .blorb = "Blorb Interactive Fiction", .matlab = "MATLAB Data", .nifti = "NIfTI Neuroimaging", .pdb_struct = "PDB Protein Structure", .cif = "CIF Crystallographic Data", .shapefile = "ESRI Shapefile", .kml = "KML Geographic Data", .kmz = "KMZ Compressed KML", .dxf = "AutoCAD DXF", .step = "STEP CAD Model", .stl = "STL 3D Model", .@"3mf" = "3MF 3D Manufacturing", .obj = "Wavefront OBJ 3D Model", .ply = "PLY Polygon File", .gltf = "glTF 3D Scene", .glb = "GLB Binary glTF",
    .gcode = "G-code (3D Printer/CNC)", .eml = "EML Email Message", .mbox = "MBOX Mail Archive", .sqlite = "SQLite Database", .json = "JSON Data", .toml = "TOML Config", .ini = "INI Config", .xml = "XML Document", .yaml = "YAML Data", .erlang_term = "Erlang Term", .eex = "EEx/ERB Template", .markdown = "Markdown Text", .plain_text = "Plain Text (UTF-8)", .plain_text_utf16 = "Plain Text (UTF-16)", .plain_text_latin1 = "Plain Text (ISO-8859-1/Latin-1)", .plain_text_cp437 = "Plain Text (CP437/DOS)", .ttf = "TrueType Font", .otf = "OpenType Font", .woff = "WOFF Font", .woff2 = "WOFF2 Font", .type1 = "Type 1 Font", .par2 = "PAR2 Parity Archive", .beam = "Erlang/Elixir BEAM Bytecode", .ico = "Windows Icon", .csv = "CSV Data", .plist = "Apple Property List", .ds_store = "macOS DS_Store", .spotlight = "macOS Spotlight Index", .pe = "Windows PE Executable", .elf = "ELF Executable", .macho = "Mach-O Binary", .macho_fat = "Mach-O Universal Binary", .coff = "COFF Object File", .wasm = "WebAssembly Module",
    .java_class = "Java Class File", .ar = "Unix ar Archive", .html = "HTML Document", .git_repository = "Git Repository", .macos_app = "macOS Application Bundle", .macos_framework = "macOS Framework", .macos_bundle = "macOS Bundle",
    .dts = "DTS Digital Surround Audio",
    .apple_double = "AppleDouble Resource Fork",
    .apple_media_db = "Apple Media Library Database",
    .qbw = "QuickBooks Company File",
    .qbb = "QuickBooks Backup",
    .qdf = "Quicken Data File",
    .ofx = "Open Financial Exchange",
    .qif = "Quicken Interchange Format",
    .txf = "Tax Exchange Format",
    .nacha = "NACHA/ACH Electronic Payments",
    .mt940 = "SWIFT MT940 Bank Statement",
    .bai2 = "BAI2 Balance Report",
    .icalendar = "iCalendar",
    .vcard = "vCard",
    .x12_edi = "X12 EDI",
    .edifact = "UN/EDIFACT",
    .pem = "PEM Certificate/Key",
    .der = "DER Certificate/Key",
    .pgp_signed = "PGP Signed Message",
    .ssh_signature = "SSH Signature",
    .cab = "Microsoft Cabinet Archive",
    .sit = "StuffIt Archive",
    .sitx = "StuffIt X Archive",
    .mp2 = "MPEG Audio Layer II",
    .rm = "RealMedia",
    .cdg = "CD+Graphics Karaoke",
    .toast = "Roxio Toast Disc Image",
    .vmdk = "VMware Virtual Disk",
    .wim = "Windows Imaging Format",
    .esd = "Windows ESD Image",
    .msi = "Microsoft Installer",
    .blar = "BLIP Archive",
    .mblar = "BLIP Mini-Archive",
    .bagit = "BagIt",
    .icns = "macOS Icon",
    .msgpack = "MessagePack Data",
    .llvm_pch = "LLVM Precompiled Header",
    .llvm_diag = "LLVM Serialized Diagnostics",
    .pcap = "PCAP Network Capture", .pcapng = "PCAPNG Network Capture",
    .rpm = "RPM 패키지",
});

pub const error_translations = i18n.ErrorMap.initComptime(.{});
pub const warning_translations = i18n.WarningMap.initComptime(.{});
