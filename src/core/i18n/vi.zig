const Strings = @import("strings.zig").Strings;
const i18n = @import("mod.zig");
const cli = @import("cli_aliases.zig");

pub const strings = Strings{
    // CLI status labels
    .label_ok = "OK",
    .label_warn = "C\xe1\xba\xa2NH B\xc3\x81O",
    .label_fail = "L\xe1\xbb\x96I",
    .label_notice = "TH\xc3\x94NG B\xc3\x81O",
    .label_unknown = "KH\xc3\x94NG X\xc3\x81C \xc4\x90\xe1\xbb\x8aNH",
    .label_slow = "CH\xe1\xba\xa8M",

    // Summary
    .summary_title = "T\xc3\xb3m t\xe1\xba\xaft:",
    .summary_interrupted = "\xc4\x90\xc3\xa3 ng\xe1\xba\xaft - T\xc3\xb3m t\xe1\xba\xaft m\xe1\xbb\x99t ph\xe1\xba\xa7n:",
    .summary_valid = "H\xe1\xbb\xa3p l\xe1\xbb\x87:",
    .summary_invalid = "Kh\xc3\xb4ng h\xe1\xbb\xa3p l\xe1\xbb\x87:",
    .summary_unknown = "Kh\xc3\xb4ng x\xc3\xa1c \xc4\x91\xe1\xbb\x8bnh:",
    .summary_processed = "\xc4\x90\xc3\xa3 x\xe1\xbb\xad l\xc3\xbd:",

    // Depth descriptions
    .depth_structural = "c\xe1\xba\xa5u tr\xc3\xbac",
    .depth_full = "\xc4\x91\xc3\xa3 x\xc3\xa1c th\xe1\xbb\xb1c \xc4\x91\xe1\xba\xa7y \xc4\x91\xe1\xbb\xa7",

    // Progress / startup
    .scanning_files_found = "\xc4\x90ang qu\xc3\xa9t... \xc4\x91\xc3\xa3 t\xc3\xacm th\xe1\xba\xa5y %zu t\xe1\xbb\x87p",
    .found_files_to_validate = "%zu t\xe1\xbb\x87p c\xe1\xba\xa7n x\xc3\xa1c th\xe1\xbb\xb1c.",
    .checking = "Ki\xe1\xbb\x83m tra:",

    // Misc
    .full_validation_unavailable = "X\xc3\xa1c th\xe1\xbb\xb1c \xc4\x91\xe1\xba\xa7y \xc4\x91\xe1\xbb\xa7 kh\xc3\xb4ng kh\xe1\xba\xa3 d\xe1\xbb\xa5ng",
    .via_ffmpeg_suffix = "qua ffmpeg",

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
    .help_entropy_shield = "Ngăn chặn hỏng tệp trong tương lai với Entropy Shield: https://entropyshield.app",
};

pub const cli_aliases = cli.CliAliases{
    .help = "tro-giup",
    .version = "phien-ban",
    .lang = "ngon-ngu",
    .jobs = "cong-viec",
    .shuffle = "xao-tron",
    .stress = "stress",
    .no_color = "khong-mau",
    .color = "mau",
    .simple_progress = "tien-trinh-don-gian",
    .no_frontload = "khong-uu-tien",
    .append = "append",
};

pub const env_aliases = cli.EnvAliases{
    .ok_out = "OK_XUAT",
    .warn_out = "CANH_BAO_XUAT",
    .fail_out = "LOI_XUAT",
    .unknown_out = "CHUA_BIET_XUAT",
    .slow_out = "CHAM_XUAT",
    .debug_out = "DEBUG_XUAT",
    .begin_out = "BAT_DAU_XUAT",
    .max_files = "TOI_DA_FILE",
    .validate_debug = "VALIDATE_DEBUG",
    .no_bidi = "NO_BIDI",
};

pub const format_descriptions = i18n.FormatDescriptions.init(.{
    .unknown = "Unknown", .png = "PNG Image", .jpeg = "JPEG Image", .jxl = "JPEG XL Image", .gif = "GIF Image", .bmp = "BMP Image", .webp = "WebP Image", .tiff = "TIFF Image", .heic = "HEIC/HEIF Image", .avif = "AVIF Image", .exr = "OpenEXR HDR Image", .svg = "SVG Vector Graphics", .psd = "Adobe Photoshop", .ai = "Adobe Illustrator", .eps = "Encapsulated PostScript", .sketch = "Sketch Design File", .aep = "Adobe After Effects Project", .dng = "Adobe DNG RAW", .cr2 = "Canon RAW", .nef = "Nikon RAW", .arw = "Sony RAW", .zip = "ZIP Archive", .gzip = "Gzip Compressed", .bzip2 = "Bzip2 Compressed", .xz = "XZ Compressed", .zstd = "Zstandard Compressed",  .br = "Brotli Compressed", .hqx = "BinHex 4.0 Archive", .rar = "RAR Archive", .cpt = "Compact Pro Archive", .sevenz = "7-Zip Archive", .tar = "Tar Archive", .epub = "EPUB eBook", .docx = "Word Document (OOXML)", .xlsx = "Excel Spreadsheet (OOXML)", .pptx = "PowerPoint (OOXML)", .doc = "Word Document (97-2003)", .xls = "Excel Spreadsheet (97-2003)", .ppt = "PowerPoint (97-2003)", .odt = "OpenDocument Text", .ods = "OpenDocument Spreadsheet", .odp = "OpenDocument Presentation", .pdf = "PDF Document", .rtf = "Rich Text Format", .pages = "Apple Pages", .wpd = "WordPerfect Document", .cwk = "ClarisWorks/AppleWorks", .mwd = "MacWrite Document", .mp4 = "MP4 Video", .mov = "QuickTime Video", .mkv = "Matroska Video", .webm = "WebM Video", .avi = "AVI Video", .swf = "Flash SWF", .flv = "Flash Video", .prores = "Apple ProRes Video", .av1 = "AV1 Video", .mpeg_ps = "MPEG Program Stream", .mpeg_ts = "MPEG Transport Stream", .mpeg_es = "MPEG Elementary Stream", .ivf = "IVF Video Container", .asf = "ASF Media", .dv = "DV Video", .mp3 = "MP3 Audio", .flac = "FLAC Audio", .wav = "WAV Audio", .m4a = "M4A Audio", .alac = "Apple Lossless Audio", .aiff = "AIFF Audio", .ogg = "Ogg Audio", .ogv = "Ogg Video (Theora)", .ape = "Monkey's Audio", .wavpack = "WavPack Audio", .midi = "Standard MIDI File", .dsf = "DSD Stream File", .dff = "DSDIFF Audio", .ac3 = "Dolby Digital AC-3 Audio", .eac3 = "Dolby Digital Plus Audio", .amr = "AMR Audio", .au = "AU/SND Audio", .tta = "True Audio (TTA)", .caf = "CAF Audio", .aac_adts = "AAC-LC Audio (ADTS)", .jpeg2000 = "JPEG2000 Image", .jbig2 = "JBIG2 Bi-level Image", .qoi = "QOI Image", .pam = "Portable Anymap Image", .dpx = "DPX Image", .tga = "TGA Image", .mod = "ProTracker Module", .xm = "FastTracker Module", .it = "Impulse Tracker Module", .s3m = "Scream Tracker Module", .als = "Ableton Live Set", .rpp = "Reaper Project", .logicx = "Logic Pro X Project", .flp = "FL Studio Project", .song = "Studio One Project", .bwproject = "Bitwig Studio Project", .cpr = "Cubase Project", .ptx = "Pro Tools Session", .band = "GarageBand Project", .reason = "Reason Project", .prproj = "Adobe Premiere Pro Project", .indd = "Adobe InDesign Document", .idml = "Adobe InDesign Markup", .dwg = "AutoCAD Drawing", .blend = "Blender 3D Project", .fcpxml = "Final Cut Pro XML", .drp = "DaVinci Resolve Project", .mdb = "Microsoft Access Database (97-2003)", .accdb = "Microsoft Access Database", .dbf = "dBASE Database", .iso = "ISO 9660 Disk Image", .dmg = "Apple Disk Image", .hdf5 = "HDF5 Scientific Data", .parquet = "Apache Parquet Data", .netcdf = "NetCDF Scientific Data", .fits = "FITS Astronomical Data", .dicom = "DICOM Medical Image", .fasta = "FASTA Sequence", .fastq = "FASTQ Sequencing Reads", .warc = "WARC Web Archive", .wad = "DOOM WAD Archive", .pak = "Quake PAK Archive", .lspk = "Larian Studios PAK", .chromium_pak = "Chromium Resource PAK", .bsp = "BSP Map File", .vpk = "Valve PAK Archive", .nes = "NES ROM", .snes = "SNES ROM", .n64 = "Nintendo 64 ROM", .gb = "Game Boy ROM", .gba = "Game Boy Advance ROM", .nds = "Nintendo DS ROM", .genesis = "Sega Genesis ROM", .chd = "MAME CHD Image", .iff = "IFF Container", .blorb = "Blorb Interactive Fiction", .matlab = "MATLAB Data", .nifti = "NIfTI Neuroimaging", .pdb_struct = "PDB Protein Structure", .cif = "CIF Crystallographic Data", .shapefile = "ESRI Shapefile", .kml = "KML Geographic Data", .kmz = "KMZ Compressed KML", .dxf = "AutoCAD DXF", .step = "STEP CAD Model", .stl = "STL 3D Model", .@"3mf" = "3MF 3D Manufacturing", .obj = "Wavefront OBJ 3D Model", .ply = "PLY Polygon File", .gltf = "glTF 3D Scene", .glb = "GLB Binary glTF", .eml = "EML Email Message", .mbox = "MBOX Mail Archive", .sqlite = "SQLite Database", .json = "JSON Data", .toml = "TOML Config", .ini = "INI Config", .xml = "XML Document", .yaml = "YAML Data", .erlang_term = "Erlang Term", .eex = "EEx/ERB Template", .markdown = "Markdown Text", .plain_text = "Plain Text (UTF-8)", .plain_text_utf16 = "Plain Text (UTF-16)", .plain_text_latin1 = "Plain Text (ISO-8859-1/Latin-1)", .plain_text_cp437 = "Plain Text (CP437/DOS)", .ttf = "TrueType Font", .otf = "OpenType Font", .woff = "WOFF Font", .woff2 = "WOFF2 Font", .type1 = "Type 1 Font", .par2 = "PAR2 Parity Archive", .beam = "Erlang/Elixir BEAM Bytecode", .ico = "Windows Icon", .csv = "CSV Data", .plist = "Apple Property List", .ds_store = "macOS DS_Store", .spotlight = "macOS Spotlight Index", .pe = "Windows PE Executable", .elf = "ELF Executable", .macho = "Mach-O Binary", .macho_fat = "Mach-O Universal Binary", .coff = "COFF Object File", .wasm = "WebAssembly Module",
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
    .rpm = "Gói RPM",
});

pub const error_translations = i18n.ErrorMap.initComptime(.{});
pub const warning_translations = i18n.WarningMap.initComptime(.{});
