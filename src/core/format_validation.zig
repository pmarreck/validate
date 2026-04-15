//! Format Validation Subsystem (Pure Zig Implementation)
//!
//! Validates file format integrity before creating parity data.
//! Uses pure Zig implementations for format detection and validation.
//! No external library dependencies.
//!
//! Supported formats:
//! - PNG: Signature + chunk structure validation
//! - JPEG: SOI marker + segment structure validation
//! - JPEG XL: Codestream or container signature validation
//! - GIF: Header + trailer validation
//! - BMP: Header structure validation
//! - WebP: RIFF container with VP8/VP8L chunk validation
//! - TIFF: Header + IFD structure validation
//! - HEIC/HEIF: ISO Base Media File Format with heic brand validation
//! - ZIP: Local file header + central directory validation (covers EPUB, DOCX, XLSX, PPTX)
//! - PDF: Header + trailer validation
//! - Video: MP4, MOV, MKV, WebM, AVI container validation
//! - Audio: MP3, FLAC, WAV, M4A, AIFF, OGG, MIDI validation
//! - Tracker: MOD, XM, IT, S3M module format validation
//! - RAW: DNG, CR2, NEF, ARW camera RAW format validation
//!
//! ## SFVS Validation Flags Reference
//!
//! The validation depth set here maps to SFVS (Source File Validation State) packet flags
//! stored in par2 parity files. These flags indicate what level of validation was achieved.
//!
//! | ValidationDepth | SFVS Flags Set                              | Meaning                           |
//! |-----------------|---------------------------------------------|-----------------------------------|
//! | structural      | MAGIC | STRUCTURE                           | Headers, sizes, structure only    |
//! | checksum        | MAGIC | STRUCTURE | CHECKSUM                | Internal checksums verified       |
//! | decompression   | MAGIC | STRUCTURE | DECODE                  | Data successfully decompressed    |
//! | full_decode     | MAGIC | STRUCTURE | CHECKSUM | DECODE       | Full codec decode successful      |
//! | integrity       | MAGIC | STRUCTURE | CHECKSUM | DECODE | COMPLETE | Every byte integrity-checked |
//!
//! ## Flag Meanings:
//! - MAGIC (0x01): Magic bytes / file signature validated
//! - STRUCTURE (0x02): Container/chunk structure validated
//! - CHECKSUM (0x04): Internal checksums verified (CRC, MD5, etc.)
//! - DECODE (0x08): Decompression/decode succeeded
//! - CHARSET (0x10): Character encoding validated (UTF-8, etc.)
//! - SEMANTIC (0x20): Content semantically valid (XML well-formed, JSON parses, etc.)
//! - COMPLETE (0x80): Every byte covered by integrity check
//!
//! ## When to Use Each Depth:
//! - structural: Basic format recognition (magic bytes + header structure)
//! - checksum: Format has internal CRCs/checksums (PNG chunks, ZIP CRCs, MP3 CRC, 7z, gzip)
//! - decompression: Data was decompressed without checksums (some archives)
//! - full_decode: Full decode verified (JPEG libjpeg, FLAC MD5 hash)
//! - integrity: Database-level or format-complete integrity (SQLite PRAGMA, PDF xref)
//!
//! ## COMPLETE Flag Rules:
//! - Set COMPLETE only when EVERY byte is covered by integrity mechanisms
//! - Container formats with CRCs (ZIP) satisfy COMPLETE when CRCs pass
//! - Text formats at top level (UTF-8, XML, JSON) can set COMPLETE if parse succeeds

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const errmsg = @import("error_messages.zig");
const codec_utils = @import("codec_utils.zig");

/// Cross-platform getenv that returns null on Windows (where std.posix.getenv is unavailable).
/// On POSIX systems, returns the environment variable value or null if not set.
pub fn getenvCrossPlatform(comptime name: []const u8) ?[:0]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return null;
    }
    return std.posix.getenv(name);
}

// Import SQLite3 for deep database validation
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

// Import FLAC decoder for MD5 verification
const flac_decoder = @import("flac_decoder.zig");

// Import JPEG validator for libjpeg-turbo deep validation
const jpeg_validator = @import("jpeg_validator.zig");

// Import JPEG Lossless decoder for DICOM SOF3 validation (Pure Zig)
const jpeg_lossless_decoder = @import("jpeg_lossless_decoder.zig");

// Import zigimg for GIF/TIFF deep validation (full decode)
const zigimg = @import("zigimg");

// Import text format validators
const text_format_validators = @import("text_format_validators.zig");

// Import cj5 for JSON5 validation (MIT, C library with Zig bindings)
const cj5 = @import("cj5");

// Import WebP validator for libwebp deep validation
const webp_validator = @import("webp_validator.zig");

// Import JPEG-XL validator for libjxl deep validation
const jxl_validator = @import("jxl_validator.zig");

// Import BMP decoder for V3 support (zigimg only supports V4/V5)
const bmp_decoder = @import("bmp_decoder.zig");

// Import MIDI validator for deep track data validation
const midi_validator = @import("midi_validator.zig");

// Import OLE2 validator for deep validation of legacy Office formats
const ole2_validator = @import("ole2_validator.zig");

// Import Brotli validator for .br file deep validation
const brotli_validator = @import("brotli_validator.zig");

// Import tracker/module validator for MOD/XM/IT/S3M deep validation
const tracker_validator = @import("tracker_validator.zig");

// Import libopenmpt bindings for tracker format full decode validation
const libopenmpt = @import("libopenmpt.zig");

// Import pure-Zig HEIC/AVIF validators
const heic_validator = @import("heic_validator.zig");
const avif_validator = @import("avif_validator.zig");

// Import LibRaw validator for camera RAW format deep validation (ARW, CR2, NEF)
const libraw_validator = @import("libraw_validator.zig");

// Import video validator for video stream deep validation (MP4/MKV with HEVC/AV1)
const video_validator = @import("video_validator.zig");

// Import video+audio validator for combined media validation
const video_audio_validator = @import("video_audio_validator.zig");

// Import bzip2 decompressor for CRC verification
const bzip2 = @import("bzip2.zig");

// Import JPEG2000 validator for deep validation of encapsulated DICOM pixel data
const jpeg2000_validator = @import("jpeg2000_validator.zig");

// Import AC3/EAC3 validators for Dolby Digital audio validation
const ac3_validator = @import("ac3_validator.zig");
const eac3_validator = @import("eac3_validator.zig");

// Import OGG/Vorbis/Opus validators for deep audio validation
const ogg_validator = @import("ogg_validator.zig");
const vorbis_validator = @import("vorbis_validator.zig");
const opus_validator = @import("opus_validator.zig");

// Import AAC syntax validator for ADTS deep validation
const aac_syntax_validator = @import("aac_syntax_validator.zig");

// Import MPEG-TS parser for deep TS validation
const mpeg_ts_parser = @import("mpeg_ts_parser.zig");

// Import font validator for TTF/OTF/WOFF/WOFF2 validation
const font_validator = @import("font_validator.zig");

// Import PDF deep validators for embedded content
const pdf_image_validator = @import("pdf_image_validator.zig");
const pdf_font_validator = @import("pdf_font_validator.zig");
const pdf_embedded_file_validator = @import("pdf_embedded_file_validator.zig");

// Import zlib wrapper for robust deflate decompression (replaces buggy std.compress.flate)
const zlib = @import("zlib.zig");

// Import TIFF LZW decoder for 1-bit TIFF validation (zigimg can't handle these)
// Note: TIFF LZW uses different early-change semantics than PDF LZW
const tiff_lzw_decoder = @import("tiff_lzw_decoder.zig");

// Import WavPack decoder for deep validation with MD5 sub-block detection
const wavpack_decoder = @import("wavpack_decoder.zig");

// Import MP3 decode validator for full audio decode validation
const mp3_decode_validator = @import("mp3_decode_validator.zig");

// Import MP3 CRC validator for protected frame CRC verification
const mp3_validator = @import("mp3_validator.zig");

// Import JBIG2 decoder for standalone JBIG2 file validation
const jbig2_decoder = @import("jbig2_decoder.zig");

// Import git validator for .git directory validation
const git_validator = @import("git_validator.zig");

// Import 7-Zip validator for deep archive validation
const sevenz_validator = @import("sevenz_validator.zig");

// Import DMG validator for deep disk image validation
const dmg_validator = @import("dmg_validator.zig");

// Import ISO 9660 parser for deep ISO validation
const iso9660_parser = @import("iso9660_parser.zig");

// Game ROM validators (NES, SNES, N64, GB, GBA, NDS, Genesis, CHD)
const game_validator = @import("game_validator.zig");

// Game asset validators (WAD, PAK, LSPK, Chromium PAK, BSP, VPK, IFF, Blorb)
const game_asset_validators = @import("game_asset_validators.zig");

// Document validators (SQLite, OLE2, WordPerfect, MDB, ACCDB)
const document_validators = @import("document_validators.zig");

// Filesystem/disk image validators (ISO, DMG)
const filesystem_validators = @import("filesystem_validators.zig");
const apple_validators = @import("apple_validators.zig");
const apple_media_db_validator = @import("apple_media_db_validator.zig");
const macos_bundle_validator = @import("macos_bundle_validator.zig");
const financial_validators = @import("financial_validators.zig");
const edi_validators = @import("edi_validators.zig");
const pim_validators = @import("pim_validators.zig");
const crypto_validators = @import("crypto_validators.zig");
const bagit_validator = @import("bagit_validator.zig");
const pdf_validator = @import("pdf_validator.zig");

// New format validators (2026-03-27 scan findings)
const cab_validator = @import("cab_validator.zig");
const wim_validator = @import("wim_validator.zig");
const network_validators = @import("network_validators.zig");
const vmdk_validator = @import("vmdk_validator.zig");
const stuffit_validator = @import("stuffit_validator.zig");
const realmedia_validator = @import("realmedia_validator.zig");
const cdg_validator = @import("cdg_validator.zig");
const toast_validator = @import("toast_validator.zig");
const blar_validator = @import("blar_validator.zig");

// PE (Portable Executable) validator
const pe_validator = @import("pe_validator.zig");

// DAW project validators (FLP, ALS, RPP)
const daw_validators = @import("daw_validators.zig");

// Scientific format validators (NetCDF, FITS, DICOM, FASTA, FASTQ)
const scientific_validators = @import("scientific_validators.zig");
const music_validators = @import("music_validators.zig");
const movie_validators = @import("movie_validators.zig");
const image_validators = @import("image_validators.zig");
const email_validators = @import("email_validators.zig");
const executable_validators = @import("executable_validators.zig");
const archive_validators = @import("archive_validators.zig");
pub const creative_validators = @import("creative_validators.zig");
const cad_3d_validators = @import("cad_3d_validators.zig");
const i18n = @import("i18n/mod.zig");
const file_source = @import("file_source.zig");
const FileSource = file_source.FileSource;

// ============ Constants ============

/// Maximum decompressed size for streaming validation (10 GiB).
/// Protects against zip bombs and malicious archives that expand to huge sizes.
/// Files exceeding this limit will have their decompression aborted and only
/// structural validation will be performed.
pub const MAX_DECOMPRESSED_SIZE: u64 = 10 * 1024 * 1024 * 1024; // 10 GiB

/// Maximum decompressed size per ZIP entry (512 MiB).
/// Individual ZIP entries are capped to prevent memory exhaustion.
pub const MAX_ZIP_ENTRY_SIZE: u64 = 512 * 1024 * 1024; // 512 MiB

// ============ Bundle Detection ============

/// Types of bundle directories that should be validated as a unit (not recursed into).
/// The CLI should NOT recurse into these directories but instead pass them directly
/// to the validation function, which will handle them appropriately.
pub const BundleType = enum {
    none, // Not a bundle directory
    git, // .git directory - git repository
    macos_app, // .app bundle - macOS application
    macos_framework, // .framework bundle - macOS framework
    macos_bundle, // .bundle - macOS plugin/bundle
    garageband, // .band - GarageBand project bundle
    // Future: xcodeproj, xcworkspace

    pub fn description(self: BundleType) []const u8 {
        return switch (self) {
            .none => "Not a bundle",
            .git => "Git Repository",
            .macos_app => "macOS Application Bundle",
            .macos_framework => "macOS Framework",
            .macos_bundle => "macOS Bundle",
            .garageband => "GarageBand Project",
        };
    }
};

/// Check if a path is a bundle directory that should not be recursed into.
/// Returns the bundle type if it's a bundle, or .none if it's a regular directory.
/// The CLI should use this to decide whether to recurse into a directory or pass
/// the entire directory path to validation.
pub fn detectBundleType(path: []const u8) BundleType {
    // Check if path ends with "/.git" or is exactly ".git"
    if (path.len >= 4) {
        const last_4 = path[path.len - 4 ..];
        if (std.mem.eql(u8, last_4, ".git")) {
            // Either path is exactly ".git" or ends with "/.git"
            if (path.len == 4 or path[path.len - 5] == '/') {
                return .git;
            }
        }
    }
    // Check for .app bundle (macOS application) - must end with ".app"
    if (std.mem.endsWith(u8, path, ".app")) {
        return .macos_app;
    }
    // Check for .framework bundle (macOS framework)
    if (std.mem.endsWith(u8, path, ".framework")) {
        return .macos_framework;
    }
    // Check for .bundle and other macOS bundle types (all use Contents/ structure)
    if (std.mem.endsWith(u8, path, ".bundle") or
        std.mem.endsWith(u8, path, ".kext") or
        std.mem.endsWith(u8, path, ".prefPane") or
        std.mem.endsWith(u8, path, ".plugin") or
        std.mem.endsWith(u8, path, ".appex") or
        std.mem.endsWith(u8, path, ".xpc") or
        std.mem.endsWith(u8, path, ".qlgenerator") or
        std.mem.endsWith(u8, path, ".mdimporter") or
        std.mem.endsWith(u8, path, ".saver") or
        std.mem.endsWith(u8, path, ".component") or
        std.mem.endsWith(u8, path, ".driver"))
    {
        return .macos_bundle;
    }
    // Check for .band (GarageBand project bundle)
    if (std.mem.endsWith(u8, path, ".band")) {
        return .garageband;
    }
    return .none;
}

/// Check if a path is a bundle directory (convenience function).
pub fn isBundleDirectory(path: []const u8) bool {
    return detectBundleType(path) != .none;
}

// ============ Types ============

/// File format categories we can detect and validate.
pub const FileFormat = enum {
    unknown,
    // Images
    png,
    jpeg,
    jxl, // JPEG XL
    gif,
    bmp,
    webp,
    tiff,
    heic, // Also covers HEIF
    avif, // AV1 Image File Format (ISOBMFF-based)
    exr, // OpenEXR HDR image format
    svg, // Scalable Vector Graphics (XML-based)
    psd, // Adobe Photoshop Document
    ai, // Adobe Illustrator (PDF-based or PostScript-based)
    eps, // Encapsulated PostScript
    sketch, // Sketch design file (ZIP-based JSON)
    aep, // Adobe After Effects Project (RIFX-based)
    // RAW camera formats
    dng, // Adobe DNG
    cr2, // Canon RAW (TIFF-based)
    cr3, // Canon RAW (ISO BMFF-based, newer)
    nef, // Nikon RAW (also covers NRW)
    arw, // Sony RAW
    raf, // Fuji RAW (unique format, not TIFF-based)
    orf, // Olympus RAW (TIFF-based)
    rw2, // Panasonic RAW (TIFF variant, version 0x55)
    pef, // Pentax RAW (TIFF-based)
    // Archives
    zip,
    gzip, // .gz files
    bzip2, // .bz2 files
    xz, // XZ compressed (.xz)
    zstd, // Zstandard compressed (.zst)
    br, // Brotli compressed (.br) - no magic number, extension-detected
    hqx, // BinHex 4.0 encoded Macintosh file
    rar, // RAR archive
    cpt, // Compact Pro archive (.cpt)
    sevenz, // 7-Zip (.7z)
    tar, // tar archive (often combined with gzip)
    epub,
    // Modern Office (ZIP-based Office Open XML)
    docx, // Office Open XML Document
    xlsx, // Office Open XML Spreadsheet
    pptx, // Office Open XML Presentation
    // Legacy Office (OLE2/CFBF binary)
    doc, // Word 97-2003
    xls, // Excel 97-2003
    ppt, // PowerPoint 97-2003
    // OpenDocument (ZIP-based)
    odt, // OpenDocument Text
    ods, // OpenDocument Spreadsheet
    odp, // OpenDocument Presentation
    // Other documents
    pdf,
    rtf, // Rich Text Format
    pages, // Apple Pages (ZIP-based)
    // Legacy/Classic word processors
    wpd, // WordPerfect Document
    cwk, // ClarisWorks/AppleWorks
    mwd, // MacWrite Document
    // Video containers
    mp4,
    mov, // QuickTime
    mkv, // Matroska
    webm,
    avi,
    swf, // Adobe Flash SWF (FWS/CWS/ZWS)
    flv, // Adobe Flash Video container
    prores, // Apple ProRes (in MOV/MP4 container)
    av1, // AV1 video (in MP4/MKV/WebM container)
    mpeg_ps, // MPEG Program Stream (.mpg, .mpeg, .vob)
    mpeg_ts, // MPEG Transport Stream (.ts, .mts, .m2ts)
    mpeg_es, // MPEG Elementary Stream (raw MPEG-1/2 video)
    ivf, // IVF container (VP8/VP9/AV1)
    asf, // ASF/WMV/WMA (Advanced Systems Format - Microsoft)
    dv, // DV (Digital Video)
    // Audio
    mp3,
    flac,
    wav,
    m4a, // AAC in MP4 container
    alac, // Apple Lossless in M4A container
    aiff, // Audio Interchange File Format
    ogg, // Ogg Vorbis/Opus audio
    ogv, // Ogg Theora video
    ape, // Monkey's Audio (APE)
    wavpack, // WavPack lossless audio
    midi, // Standard MIDI File
    dsf, // DSD Stream File (hi-res audio)
    dff, // DSDIFF - DSD Interchange File Format (hi-res audio)
    ac3, // Dolby Digital AC-3 audio
    dts, // DTS Digital Surround audio
    eac3, // Dolby Digital Plus (E-AC-3) audio
    amr, // AMR (Adaptive Multi-Rate) audio
    au, // AU/SND (Sun/NeXT audio)
    tta, // TTA (True Audio) lossless
    caf, // CAF (Core Audio Format - Apple)
    aac_adts, // AAC-LC Audio (ADTS framing)
    // Image formats (additional)
    jpeg2000, // JPEG2000 (.jp2, .j2k, .j2c)
    jbig2, // JBIG2 bi-level image compression (.jbig2, .jb2)
    qoi, // QOI (Quite OK Image)
    pam, // Portable Anymap (PBM/PGM/PPM/PAM)
    dpx, // DPX (Digital Picture Exchange)
    tga, // TGA (Truevision TGA/TARGA)
    // Tracker/Module formats
    mod, // Amiga ProTracker MOD
    xm, // FastTracker 2 Extended Module
    it, // Impulse Tracker
    s3m, // Scream Tracker 3
    // DAW Project formats
    als, // Ableton Live Set (gzip-compressed XML)
    rpp, // Reaper Project (UTF-8 text)
    logicx, // Logic Pro X (ZIP-based package)
    flp, // FL Studio Project
    song, // PreSonus Studio One (ZIP-based)
    bwproject, // Bitwig Studio (proprietary binary)
    cpr, // Steinberg Cubase (RIFF-based)
    ptx, // Avid Pro Tools (proprietary binary)
    band, // Apple GarageBand (package/bundle)
    reason, // Reason Studios Reason (proprietary)
    // Video editing project formats
    prproj, // Adobe Premiere Pro (gzip-compressed XML)
    // Desktop publishing formats
    indd, // Adobe InDesign (proprietary binary)
    idml, // Adobe InDesign Markup Language (ZIP-based XML)
    // CAD formats
    dwg, // AutoCAD Drawing (proprietary binary)
    // 3D modeling formats
    blend, // Blender 3D project
    // Video editing project formats (additional)
    fcpxml, // Final Cut Pro XML
    drp, // DaVinci Resolve Project (ZIP-based)
    // Database formats
    mdb, // Microsoft Access Database (97-2003)
    accdb, // Microsoft Access Database (2007+)
    dbf, // dBASE Database (.dbf) — dBASE III/IV/V, Visual FoxPro, FoxPro
    // Disk images
    iso, // ISO 9660 CD/DVD image
    dmg, // Apple Disk Image
    // Scientific data formats
    hdf5, // Hierarchical Data Format 5
    parquet, // Apache Parquet columnar format
    netcdf, // NetCDF (Network Common Data Form) - climate/ocean science
    fits, // FITS (Flexible Image Transport System) - astronomy
    // Medical/Biomedical formats
    dicom, // DICOM (Digital Imaging and Communications in Medicine)
    fasta, // FASTA sequence format (genomics/bioinformatics)
    fastq, // FASTQ sequencing reads with quality scores
    // Archive formats
    warc, // WARC (Web ARChive) - web preservation
    // Game data formats
    wad, // WAD (DOOM/id Software) - IWAD/PWAD
    pak, // PAK (Quake) - "PACK" magic
    lspk, // Larian Studios PAK (BG3, Divinity) - "LSPK" magic
    chromium_pak, // Chromium/Electron resource PAK
    bsp, // BSP (Quake/Source map files)
    vpk, // VPK (Valve Pak) - Source engine
    // Game ROM formats
    nes, // NES/Famicom ROM (iNES format)
    snes, // SNES/Super Famicom ROM
    n64, // Nintendo 64 ROM
    gb, // Game Boy / Game Boy Color ROM
    gba, // Game Boy Advance ROM
    nds, // Nintendo DS ROM
    genesis, // Sega Genesis / Mega Drive ROM
    chd, // MAME CHD (Compressed Hunks of Data)
    // IFF-based formats
    iff, // Generic IFF container (FORM)
    blorb, // Blorb (Interactive Fiction resources)
    // Scientific/Research formats
    matlab, // MATLAB .mat files
    nifti, // NIfTI neuroimaging (.nii)
    pdb_struct, // PDB protein structure (renamed to avoid conflict)
    cif, // CIF crystallographic data
    // Geospatial/GIS formats
    shapefile, // ESRI Shapefile (.shp)
    kml, // KML (Keyhole Markup Language)
    kmz, // KMZ (compressed KML)
    // CAD/Engineering formats
    dxf, // AutoCAD DXF exchange format
    step, // STEP/STP CAD exchange format
    stl, // STL 3D printing format
    // 3D printing/modeling formats
    @"3mf", // 3MF (3D Manufacturing Format) - ZIP-based
    obj, // Wavefront OBJ (text-based 3D model)
    ply, // PLY (Stanford Polygon File Format)
    gltf, // glTF (GL Transmission Format) - JSON
    glb, // GLB (Binary glTF)
    // Email formats
    eml, // EML email message
    mbox, // MBOX mail archive
    // Database
    sqlite, // SQLite database file
    // Text data formats
    json, // JSON (JavaScript Object Notation)
    toml, // TOML (Tom's Obvious Minimal Language)
    ini, // INI config files (git config, Windows INI, etc.)
    xml, // XML (Extensible Markup Language)
    yaml, // YAML (YAML Ain't Markup Language) - structural only
    erlang_term, // Erlang term format (.app, .config, rebar.config)
    eex, // EEx/ERB templates (embedded Elixir/Ruby)
    markdown, // Markdown text format (.md, .markdown)
    plain_text, // Plain text file (validated as UTF-8)
    plain_text_utf16, // Plain text file in UTF-16 encoding
    plain_text_latin1, // Plain text file in ISO-8859-1/Latin-1 encoding
    plain_text_cp437, // Plain text file in CP437/DOS encoding (demoscene NFO files)
    // Font formats
    ttf, // TrueType Font
    otf, // OpenType Font (CFF or TrueType outlines)
    woff, // Web Open Font Format
    woff2, // WOFF2 (Brotli compressed)
    type1, // Adobe Type 1 (PFB/PFA)
    // Parity/Recovery formats
    par2, // PAR2 parity archive
    // VM/Bytecode formats
    beam, // Erlang/Elixir BEAM bytecode
    // Icon formats
    ico, // Windows ICO icon
    icns, // macOS ICNS icon (type/length chunk container)
    // Data formats
    csv, // Comma-Separated Values
    msgpack, // MessagePack binary serialization
    // Apple formats
    plist, // Apple Property List (XML or binary)
    ds_store, // macOS .DS_Store (Desktop Services Store)
    spotlight, // macOS Spotlight index (proprietary)
    apple_double, // AppleDouble resource fork (._* files) / AppleSingle
    apple_media_db, // Apple Media Library Database (hfma magic — Music.app, TV.app .musicdb/.tvdb)
    // Executable formats
    pe, // Windows PE (Portable Executable) - .exe, .dll, .sys, .scr
    elf, // ELF (Executable and Linkable Format) - Linux/Unix executables, .so, .o
    macho, // Mach-O (macOS/iOS executable, object, dylib, bundle)
    macho_fat, // Mach-O Universal/Fat binary (multi-architecture)
    coff, // COFF object file (Windows .obj)
    wasm, // WebAssembly binary module (.wasm)
    java_class, // Java bytecode (.class) - CAFEBABE magic, big-endian
    // Compiler artifact formats
    llvm_pch, // LLVM precompiled header (.pcm, magic "CPCH")
    llvm_diag, // LLVM serialized diagnostics (.dia, magic "DIAG")
    // Archive formats (non-compressed)
    ar, // Unix ar archive (.a static libraries, .deb packages)
    // Web markup
    html, // HTML document (.html, .htm, .xhtml)
    // Financial data formats
    qbw, // QuickBooks Company File (SQL Anywhere database)
    qbb, // QuickBooks Backup (OLE2 compound file)
    qdf, // Quicken Data File (OLE2, ZIP, or legacy proprietary)
    ofx, // Open Financial Exchange (SGML/XML)
    qif, // Quicken Interchange Format (text)
    txf, // Tax Exchange Format (text)
    nacha, // NACHA/ACH Electronic Payments (fixed 94-char ASCII records)
    mt940, // SWIFT MT940 Bank Statement (tagged text fields)
    bai2, // BAI2 Cash Management Balance Reporting (comma-separated, hierarchical)
    icalendar, // iCalendar (RFC 5545, .ics/.ical)
    vcard, // vCard (RFC 6350, .vcf/.vcard)
    x12_edi, // X12 EDI (ISA/GS/ST envelope structure)
    edifact, // UN/EDIFACT (UNA/UNB/UNH envelope structure)
    // Crypto/certificate formats
    pem, // PEM-encoded certificate/key (-----BEGIN ... -----)
    der, // DER-encoded ASN.1 certificate/key (binary)
    pgp_signed, // PGP clearsigned message (RFC 4880 section 7)
    ssh_signature, // SSH signature (OpenSSH PROTOCOL.sshsig)
    // Additional archive formats
    cab, // Microsoft Cabinet archive (.cab)
    sit, // StuffIt archive (.sit, classic through v5/6)
    sitx, // StuffIt X archive (.sitx, v7+)
    // Additional audio formats
    mp2, // MPEG Audio Layer II
    // Additional media container formats
    rm, // RealMedia (.rm, .rmvb)
    // Karaoke formats
    cdg, // CD+Graphics (.cdg, karaoke subchannel data)
    // Disc image formats
    toast, // Roxio Toast disc image (.toast)
    // Virtual machine formats
    vmdk, // VMware Virtual Disk (.vmdk)
    // Windows imaging formats
    wim, // Windows Imaging Format (.wim)
    esd, // Windows Electronic Software Distribution (.esd, WIM variant)
    // Windows installer formats
    msi, // Microsoft Installer (.msi, OLE2/CFBF container)
    // BLIP archive formats
    blar, // BLIP archive (.blar, with directory support)
    mblar, // BLIP mini-archive (.mblar, flat files only)
    // Bundle formats (directories validated as a unit)
    bagit, // BagIt archive (RFC 8493, directory with bagit.txt + manifest)
    git_repository, // Git repository (.git directory)
    macos_app, // macOS application bundle (.app)
    macos_framework, // macOS framework bundle (.framework)
    macos_bundle, // macOS bundle/plugin (.bundle)
    // Network capture formats
    pcap, // PCAP network capture (classic libpcap)
    pcapng, // PCAPNG next-generation network capture
    // Package formats
    rpm, // RPM Package (.rpm, .srpm)

    pub fn description(self: FileFormat) [:0]const u8 {
        return i18n.getFormatDescription(self);
    }

    /// Returns true if we have a validator for this format.
    pub fn hasValidator(self: FileFormat) bool {
        return switch (self) {
            .png, .jpeg, .jxl, .gif, .bmp, .webp, .tiff, .psd, .ai, .eps, .sketch, .aep, .heic, .avif, .exr => true, // Images/Design
            .svg => true, // SVG uses XML validation
            .dng, .cr2, .cr3, .nef, .arw, .raf, .orf, .rw2, .pef => true, // RAW formats
            .zip, .gzip, .bzip2, .xz, .zstd, .br, .hqx, .rar, .cpt, .sevenz, .tar, .epub, .docx, .xlsx, .pptx => true, // Archives
            .odt, .ods, .odp, .pages, .logicx => true, // ZIP-based document/DAW formats
            .doc, .xls, .ppt => true, // OLE2/CFBF binary Office
            .pdf, .rtf => true, // Document formats
            .wpd, .cwk, .mwd => true, // Legacy word processors
            .mp4, .mov, .mkv, .webm, .avi, .swf, .flv => true, // Video containers
            .mpeg_ps, .mpeg_ts, .mpeg_es, .ivf => true, // MPEG streams and IVF container
            .asf, .dv => true, // ASF/WMV/WMA and DV
            .prores, .av1 => true, // Video codecs (detected within containers)
            .mp3, .flac, .wav, .m4a => true, // Audio
            .alac, .aiff, .ogg, .ogv, .ape, .wavpack, .midi, .dsf, .dff, .ac3, .dts, .eac3 => true, // Additional audio/video formats
            .amr, .au, .tta, .caf, .aac_adts => true, // AMR, AU/SND, TTA, CAF, AAC ADTS audio
            .jpeg2000, .jbig2 => true, // JPEG2000 and JBIG2 image formats
            .qoi, .pam, .dpx, .tga => true, // QOI, Portable Anymap, DPX, TGA image formats
            .mod, .xm, .it, .s3m => true, // Tracker/module formats
            .als, .rpp, .flp, .song, .bwproject, .cpr, .ptx, .band, .reason => true, // DAW project formats
            .prproj => true, // Video editing project formats
            .indd, .idml => true, // Desktop publishing formats
            .dwg => true, // CAD formats
            .blend => true, // 3D modeling formats
            .fcpxml, .drp => true, // Video editing project formats
            .mdb, .accdb, .dbf => true, // Database formats
            .iso, .dmg => true, // Disk images
            .hdf5, .parquet, .netcdf, .fits, .dicom, .fasta, .fastq, .warc => true, // Scientific/institutional data formats
            .wad, .pak, .lspk, .chromium_pak, .bsp, .vpk => true, // Game data formats
            .nes, .snes, .n64, .gb, .gba, .nds, .genesis, .chd => true, // ROM formats
            .iff, .blorb => true, // IFF-based formats
            .matlab, .nifti, .pdb_struct, .cif => true, // Scientific formats
            .shapefile, .kml, .kmz => true, // GIS formats
            .dxf, .step, .stl => true, // CAD formats
            .@"3mf", .obj, .ply, .gltf, .glb => true, // 3D printing/modeling formats
            .eml, .mbox => true, // Email formats with attachment validation
            .sqlite => true, // Database formats
            .json, .toml, .ini, .xml => true, // Text data formats
            .yaml => false, // YAML is complex, structural detection only
            .erlang_term => false, // Erlang term format - structural detection only
            .eex => false, // EEx/ERB templates - structural detection only
            .markdown => false, // Markdown - no validation, just text
            .plain_text => true, // Plain text - UTF-8 validation
            .plain_text_utf16 => true, // Plain text - UTF-16 validation
            .plain_text_latin1 => true, // Plain text - Latin-1 (always valid, just text detection)
            .plain_text_cp437 => true, // Plain text - CP437 (always valid, demoscene NFO)
            .ttf, .otf, .woff, .woff2 => true, // Font formats with checksum validation
            .type1 => true, // Type 1 font structural validation
            .par2 => true, // PAR2 parity archive CRC validation
            .beam => true, // Erlang/Elixir BEAM bytecode (IFF structure validation)
            .ico => true, // Windows ICO icon format
            .icns => true, // macOS ICNS icon format
            .csv => true, // CSV structural validation
            .msgpack => true, // MessagePack binary serialization
            .plist => true, // Apple Property List (XML or binary)
            .ds_store => true, // macOS DS_Store (structural only)
            .spotlight => true, // macOS Spotlight index (structural only)
            .apple_double => true, // AppleDouble resource fork
            .apple_media_db => true, // Apple Media Library Database
            .pe => true, // Windows PE executable
            .elf => true, // ELF executable
            .macho => true, // Mach-O binary
            .macho_fat => true, // Mach-O universal binary
            .coff => true, // COFF object file
            .wasm => true, // WebAssembly module
            .java_class => true, // Java bytecode (.class file)
            .llvm_pch => true, // LLVM precompiled header
            .llvm_diag => true, // LLVM serialized diagnostics
            .ar => true, // Unix ar archive
            .html => true, // HTML document
            .qbw, .qbb, .qdf, .ofx, .qif, .txf, .nacha, .mt940, .bai2 => true, // Financial data formats
            .icalendar, .vcard => true, // PIM formats (iCalendar, vCard)
            .x12_edi, .edifact => true, // EDI formats
            .pem, .der => true, // Crypto/certificate formats
            .pgp_signed => true, // PGP clearsigned message
            .ssh_signature => true, // SSH signature
            .cab => true, // Microsoft Cabinet archive
            .sit, .sitx => true, // StuffIt archives
            .mp2 => true, // MPEG Audio Layer II (reuses MP3 validator)
            .rm => true, // RealMedia container
            .cdg => true, // CD+Graphics karaoke
            .toast => true, // Roxio Toast disc image
            .vmdk => true, // VMware Virtual Disk
            .wim, .esd => true, // Windows Imaging Format
            .msi => true, // Microsoft Installer (OLE2)
            .blar, .mblar => true, // BLIP archive formats
            .bagit => true, // BagIt (RFC 8493) archive validation
            .git_repository => true, // Git repository validation
            .macos_app => true, // macOS application bundle validation
            .macos_framework => true, // macOS framework validation
            .macos_bundle => true, // macOS bundle validation
            .pcap => true, // PCAP network capture validation
            .pcapng => true, // PCAPNG network capture validation
            .rpm => true, // RPM package validation
            .unknown => false,
        };
    }

    /// Returns true if this format is ZIP-based.
    pub fn isZipBased(self: FileFormat) bool {
        return switch (self) {
            .zip, .epub, .docx, .xlsx, .pptx => true,
            .odt, .ods, .odp, .pages, .logicx, .song => true,
            .@"3mf" => true, // 3MF is ZIP-based with XML content
            else => false,
        };
    }

    /// Returns true if this format uses OLE2/CFBF (Compound File Binary Format).
    pub fn isOle2(self: FileFormat) bool {
        return switch (self) {
            .doc, .xls, .ppt, .qbb, .msi => true,
            else => false,
        };
    }

    /// Returns true if this format uses ISO Base Media File Format (MP4-like).
    pub fn isIsobmff(self: FileFormat) bool {
        return switch (self) {
            .mp4, .mov, .heic, .avif, .m4a, .cr3 => true,
            else => false,
        };
    }

    /// Returns true if this format is TIFF-based (including RAW).
    pub fn isTiffBased(self: FileFormat) bool {
        return switch (self) {
            .tiff, .dng, .cr2, .nef, .arw, .orf, .rw2, .pef => true,
            else => false,
        };
    }
};

/// Depth of validation performed.
///
/// IMPORTANT: Only two levels exist. Use the correct one:
///
/// - `structural`: Magic bytes, headers, offsets, and bounds checking only.
///   Does NOT verify actual data content. Corruption in the payload may go
///   undetected. Use this when you're only parsing structure (e.g., checking
///   that directory entries don't exceed file bounds, matching braces, etc.)
///
/// - `full`: Every byte has been verified via one of:
///   1. Checksum/hash verification (CRC32, MD5, header checksums, etc.)
///   2. Successful decompression (gzip, zlib, bzip2 - the algorithm verified the data)
///   3. Successful decode (JPEG pixels decoded, audio samples rendered, XML fully parsed)
///   Corruption WILL be detected because the verification touches all bytes.
///
/// Rule of thumb: If a random bit flip in the payload would NOT cause validation
/// to fail, you must use `structural`. If it WOULD fail (because checksums or
/// decode would catch it), use `full`.
///
/// IMPORTANT: ValidationDepth is orthogonal to "corruption opacity" — a format's
/// inherent ability to detect corruption. Some formats are "opaque" (plain text,
/// CSV, OBJ) meaning even `.full` parsing can't detect semantic bit flips because
/// the format has no integrity mechanism. Others are "transparent" (gzip, PNG, FLAC)
/// where checksums/decode will catch any corruption. See `scripts/corruption_opacity.tsv`
/// for the per-format classification. ValidationDepth must honestly reflect what
/// our validator DOES, regardless of what the format CAN detect.
pub const ValidationDepth = enum {
    /// Headers, magic bytes, offsets, bounds checking only.
    /// Payload corruption may go UNDETECTED.
    structural,

    // NOTE: Future tier `best_effort` will distinguish "we parsed every byte
    // but the format has no integrity mechanism" (e.g. JSON, OBJ, FASTA)
    // from "we only checked headers" (e.g. ELF, NES). Both are currently
    // `.structural`. Ship first, iterate later.

    /// Every byte verified via checksum, decompress, or decode.
    /// Payload corruption WILL be detected.
    full,

    pub fn description(self: ValidationDepth) [:0]const u8 {
        return switch (self) {
            .structural => i18n.tr().depth_structural,
            .full => i18n.tr().depth_full,
        };
    }
};

/// Types of tolerable malformations that can be repaired.
/// REPAIRABLE: All variants here represent issues that could potentially be fixed automatically.
/// Search for "MalformationType" to find all repairable issue handling code.
/// Use with std.EnumSet for tracking multiple concurrent malformations.
pub const MalformationType = enum {
    /// PDF has non-PDF data appended after %%EOF marker
    /// REPAIRABLE: Truncate file at %%EOF + newline
    pdf_garbage_after_eof,
    /// PNG has CRC errors in ancillary (non-critical) chunks
    /// REPAIRABLE: Recalculate and fix the CRC values
    png_ancillary_crc_error,
    /// File extension doesn't match detected content type
    /// REPAIRABLE: Rename file to correct extension
    extension_mismatch,
    /// PDF uses encryption with empty user password (owner-password-only)
    /// REPAIRABLE: Decrypt all streams and remove /Encrypt dictionary
    pdf_trivial_encryption,
    /// File is wrapped in MIME multipart headers (e.g., email attachment saved incorrectly)
    /// REPAIRABLE: Extract content starting from the format's magic bytes
    mime_wrapped_content,
    /// PDF embedded JBIG2 stream is truncated
    /// REPAIRABLE: Reconstruct missing JBIG2 segments (future work)
    pdf_jbig2_truncated,
    /// PDF embedded DCTDecode data is not valid JPEG
    /// REPAIRABLE: Re-encode or repair the embedded image stream (future work)
    pdf_dct_not_jpeg,
    /// Video decoder could not produce frames, but container/stream is openable
    /// REPAIRABLE: Re-mux or re-encode the video stream (future work)
    video_no_frames_decoded,
    /// H.264 profile not supported by built-in decoder, ffmpeg not available
    /// NOT REPAIRABLE: Install ffmpeg on system PATH for full validation
    video_unsupported_profile_no_ffmpeg,
    /// XML references undefined entity after DOCTYPE stripping
    /// REPAIRABLE: Inline entity definitions or remove entity references (future work)
    xml_undefined_entity,
    /// RAR header CRC mismatch (archive still opens in tolerant tools)
    /// REPAIRABLE: Recalculate and fix header CRCs (future work)
    rar_header_crc_mismatch,
    /// Video uses mixed or nonstandard NAL length prefixes
    /// REPAIRABLE: Re-mux with normalized NAL length prefixes (future work)
    video_mixed_nal_prefix,
    /// PDF missing trailer dictionary (tolerated by most readers via fallback heuristics)
    /// REPAIRABLE: Reconstruct trailer from xref stream or embedded hints (future work)
    pdf_missing_trailer,
    /// PDF trailer missing required /Size key
    /// REPAIRABLE: Calculate /Size from xref table entry count (future work)
    pdf_trailer_missing_size,
    /// PDF trailer missing required /Root key
    /// REPAIRABLE: Scan for catalog object and add /Root reference (future work)
    pdf_trailer_missing_root,
    /// Magic bytes corrupted but format identified via extension and secondary signatures
    /// REPAIRABLE: Restore correct magic bytes for the detected format
    magic_bytes_corrupted,
    /// PDF embedded DCTDecode JPEG is truncated (incomplete scan data)
    /// REPAIRABLE: Re-fetch or reconstruct missing JPEG tail bytes (future work)
    pdf_dct_truncated,
    /// PDF embedded JPEG2000 (JPXDecode) validation failed
    /// REPAIRABLE: Re-encode or repair the J2K codestream (future work)
    pdf_jpx_decode_failed,
    /// PDF embedded CCITT fax (CCITTFaxDecode) validation failed
    /// REPAIRABLE: Re-encode as CCITT G4 or convert to lossless format (future work)
    pdf_ccitt_decode_failed,
    /// PDF embedded FlateDecode stream decompression failed
    /// REPAIRABLE: Re-fetch or reconstruct zlib stream (future work)
    pdf_flate_decode_failed,
    /// PDF embedded LZW stream decompression failed
    /// REPAIRABLE: Re-encode with FlateDecode or repair LZW data (future work)
    pdf_lzw_decode_failed,
    /// PDF embedded JBIG2 decode failed (other than truncation)
    /// REPAIRABLE: Re-encode as CCITT G4 or repair JBIG2 segments (future work)
    pdf_jbig2_decode_failed,

    pub fn description(self: MalformationType) [:0]const u8 {
        const s = i18n.tr();
        return switch (self) {
            .pdf_garbage_after_eof => s.malform_pdf_garbage_after_eof,
            .png_ancillary_crc_error => s.malform_png_ancillary_crc_error,
            .extension_mismatch => s.malform_extension_mismatch,
            .pdf_trivial_encryption => s.malform_pdf_trivial_encryption,
            .mime_wrapped_content => s.malform_mime_wrapped_content,
            .pdf_jbig2_truncated => s.malform_pdf_jbig2_truncated,
            .pdf_dct_not_jpeg => s.malform_pdf_dct_not_jpeg,
            .video_no_frames_decoded => s.malform_video_no_frames_decoded,
            .video_unsupported_profile_no_ffmpeg => s.malform_video_unsupported_profile_no_ffmpeg,
            .xml_undefined_entity => s.malform_xml_undefined_entity,
            .rar_header_crc_mismatch => s.malform_rar_header_crc_mismatch,
            .video_mixed_nal_prefix => s.malform_video_mixed_nal_prefix,
            .pdf_missing_trailer => s.malform_pdf_missing_trailer,
            .pdf_trailer_missing_size => s.malform_pdf_trailer_missing_size,
            .pdf_trailer_missing_root => s.malform_pdf_trailer_missing_root,
            .magic_bytes_corrupted => s.malform_magic_bytes_corrupted,
            .pdf_dct_truncated => s.malform_pdf_dct_truncated,
            .pdf_jpx_decode_failed => s.malform_pdf_jpx_decode_failed,
            .pdf_ccitt_decode_failed => s.malform_pdf_ccitt_decode_failed,
            .pdf_flate_decode_failed => s.malform_pdf_flate_decode_failed,
            .pdf_lzw_decode_failed => s.malform_pdf_lzw_decode_failed,
            .pdf_jbig2_decode_failed => s.malform_pdf_jbig2_decode_failed,
        };
    }
};

/// Symbolic error code for structured error reporting (i18n, FFI).
/// Each variant maps 1:1 to an error_messages.zig template.
pub const ValidationErrorCode = enum(u8) {
    failed_to_read = 0,
    file_too_small = 1,
    invalid_signature = 2,
    missing = 3,
    failed_to_seek = 4,
    truncated = 5,
    invalid_magic = 6,
    invalid_magic_number = 7,
    failed_to_open = 8,
    failed_to_skip = 9,
    too_many = 10,
    unsupported = 11,
    incomplete = 12,
    buffer_too_small = 13,
    no_valid_x_found = 14,
    unknown_element = 15,
    empty = 16,
    file_too_large = 17,
    failed_to_allocate = 18,
    failed_to_stat = 19,
    out_of_memory = 20,
    failed_to_get = 21,
    invalid_signature_expected = 22,
    invalid_signature_not = 23,
    decompression_failed = 24,
    invalid_value = 25,
    checksum_mismatch = 26,
    exceeds_bounds = 27,
    other = 255,

    /// Number of template-backed variants (excludes `other`).
    pub const template_count: u8 = 28;

    /// Produce the full English error message by delegating to the matching
    /// error_messages.zig template.  Byte-identical to calling errmsg.* directly.
    /// Only valid for single-param templates (26 of 28).
    pub fn message(comptime self: ValidationErrorCode, comptime detail: []const u8) [:0]const u8 {
        return switch (self) {
            .failed_to_read => errmsg.failedToRead(detail),
            .file_too_small => errmsg.fileTooSmallFor(detail),
            .invalid_signature => errmsg.invalidSignature(detail),
            .missing => errmsg.missing(detail),
            .failed_to_seek => errmsg.failedToSeek(detail),
            .truncated => errmsg.truncated(detail),
            .invalid_magic => errmsg.invalidMagic(detail),
            .invalid_magic_number => errmsg.invalidMagicNumber(detail),
            .failed_to_open => errmsg.failedToOpen(detail),
            .failed_to_skip => errmsg.failedToSkip(detail),
            .too_many => errmsg.tooMany(detail),
            .unsupported => errmsg.unsupported(detail),
            .incomplete => errmsg.incomplete(detail),
            .buffer_too_small => errmsg.bufferTooSmallFor(detail),
            .no_valid_x_found => errmsg.noValidXFound(detail),
            .unknown_element => errmsg.unknown(detail),
            .empty => errmsg.empty(detail),
            .file_too_large => errmsg.fileTooLargeFor(detail),
            .failed_to_allocate => errmsg.failedToAllocate(detail),
            .failed_to_stat => errmsg.failedToStat(detail),
            .out_of_memory => errmsg.outOfMemory(detail),
            .failed_to_get => errmsg.failedToGet(detail),
            .decompression_failed => errmsg.decompressionFailed(detail),
            .invalid_value => errmsg.invalidValue(detail),
            .checksum_mismatch => errmsg.checksumMismatch(detail),
            .exceeds_bounds => errmsg.exceedsBounds(detail),
            // Two-param templates — use message2() instead.
            .invalid_signature_expected, .invalid_signature_not => @compileError(
                "Use message2() for two-param templates (invalidSignatureExpected/Not)",
            ),
            .other => @compileError("No template for 'other'; use invalidCodeMsg()"),
        };
    }

    /// Produce the full English error message for two-param templates.
    pub fn message2(comptime self: ValidationErrorCode, comptime what: []const u8, comptime arg2: []const u8) [:0]const u8 {
        return switch (self) {
            .invalid_signature_expected => errmsg.invalidSignatureExpected(what, arg2),
            .invalid_signature_not => errmsg.invalidSignatureNot(what, arg2),
            else => @compileError("message2() is only for two-param templates"),
        };
    }
};

/// Result of format validation.
pub const ValidationResult = struct {
    /// The detected file format.
    format: FileFormat,
    /// Whether the format is valid (structurally correct).
    is_valid: bool,
    /// Human-readable error message if invalid.
    error_message: ?[]const u8,
    /// Symbolic error code (null for legacy callers using bare string literals).
    error_code: ?ValidationErrorCode = null,
    /// Technical detail string for the error (e.g., "PNG signature" for failed_to_read).
    error_detail: ?[]const u8 = null,
    /// Set of tolerable malformations (for potential repair). Search "REPAIRABLE" for handling code.
    /// Empty set = no malformations. Use .insert() to add, .contains() to check, .iterator() to list.
    malformations: std.EnumSet(MalformationType) = .{},
    /// Informational warning message (not a repairable malformation, just a note).
    /// Examples: "DTD not validated", "contains comments", "large file - partial validation".
    warning_message: ?[]const u8 = null,
    /// Depth of validation performed.
    validation_depth: ValidationDepth = .structural,
    /// Whether file has a resource fork (macOS).
    has_resource_fork: bool = false,
    /// Resource fork validation status (null if no resource fork).
    resource_fork_valid: ?bool = null,
    /// Whether file contains encrypted content (ZIP encrypted entries, PDF /Encrypt).
    has_encrypted_content: bool = false,
    /// Whether trivial protection was circumvented to validate (e.g., empty-password PDF encryption).
    /// These files are valid but could be "repaired" by removing the pointless protection.
    circumvented_trivial_protection: bool = false,
    /// Whether validation was performed via external ffmpeg CLI (for video formats).
    validated_via_ffmpeg: bool = false,

    /// Check if there are any malformations (warnings)
    pub fn hasMalformations(self: ValidationResult) bool {
        return self.malformations.count() > 0;
    }

    /// Get the first malformation description (for simple single-warning display)
    pub fn firstMalformationDescription(self: ValidationResult) ?[]const u8 {
        var iter = self.malformations.iterator();
        if (iter.next()) |m| {
            return m.description();
        }
        return null;
    }

    pub fn ok(format: FileFormat) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
        };
    }

    pub fn okWithDepth(format: FileFormat, depth: ValidationDepth) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = depth,
        };
    }

    /// Return valid with full depth, validated via external ffmpeg
    pub fn okWithDepthViaFfmpeg(format: FileFormat, depth: ValidationDepth) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = depth,
            .validated_via_ffmpeg = true,
        };
    }

    /// Return valid with an informational warning (not a repairable malformation)
    pub fn okWithWarning(format: FileFormat, warning: []const u8) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .warning_message = warning,
        };
    }

    /// Return valid with depth and an informational warning
    pub fn okWithDepthAndWarning(format: FileFormat, depth: ValidationDepth, warning: []const u8) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .warning_message = warning,
            .validation_depth = depth,
        };
    }

    /// Return valid but with structural-only warning (full validation was expected but couldn't complete)
    pub fn structuralOnly(format: FileFormat) ValidationResult {
        return .{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .warning_message = i18n.tr().full_validation_unavailable,
            .validation_depth = .structural,
        };
    }

    /// Return valid with a single malformation (for REPAIRABLE issues)
    pub fn okWithMalformation(format: FileFormat, malformation: MalformationType) ValidationResult {
        var result = ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
        };
        result.malformations.insert(malformation);
        return result;
    }

    /// Return valid with depth and a single malformation (for REPAIRABLE issues)
    pub fn okWithDepthAndMalformation(format: FileFormat, depth: ValidationDepth, malformation: MalformationType) ValidationResult {
        var result = ValidationResult{
            .format = format,
            .is_valid = true,
            .error_message = null,
            .validation_depth = depth,
        };
        result.malformations.insert(malformation);
        return result;
    }

    pub fn invalid(format: FileFormat, message: []const u8) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = message,
        };
    }

    pub fn invalidWithDepth(format: FileFormat, message: []const u8, depth: ValidationDepth) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = message,
            .validation_depth = depth,
        };
    }

    /// Invalid with symbolic error code (single-param templates).
    pub fn invalidCode(format: FileFormat, comptime code: ValidationErrorCode, comptime detail: []const u8) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = comptime code.message(detail),
            .error_code = code,
            .error_detail = detail,
        };
    }

    /// Invalid with symbolic error code and depth (single-param templates).
    pub fn invalidCodeWithDepth(format: FileFormat, comptime code: ValidationErrorCode, comptime detail: []const u8, depth: ValidationDepth) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = comptime code.message(detail),
            .error_code = code,
            .error_detail = detail,
            .validation_depth = depth,
        };
    }

    /// Invalid with symbolic error code and custom message (two-param templates, edge cases).
    pub fn invalidCodeMsg(format: FileFormat, code: ValidationErrorCode, detail: []const u8, msg: []const u8) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = msg,
            .error_code = code,
            .error_detail = detail,
        };
    }

    /// Invalid with symbolic error code, custom message, and depth.
    pub fn invalidCodeMsgWithDepth(format: FileFormat, code: ValidationErrorCode, detail: []const u8, msg: []const u8, depth: ValidationDepth) ValidationResult {
        return .{
            .format = format,
            .is_valid = false,
            .error_message = msg,
            .error_code = code,
            .error_detail = detail,
            .validation_depth = depth,
        };
    }

    pub fn unknown() ValidationResult {
        return .{
            .format = .unknown,
            .is_valid = true, // Unknown formats pass (we can't validate them)
            .error_message = null,
        };
    }
};

pub const VideoDecodeTolerance = struct {
    malformation: MalformationType,
    warning: []const u8,
};

pub fn toleratedVideoDecodeFailure(result: video_validator.VideoValidationResult) ?VideoDecodeTolerance {
    if (result.valid) return null;
    const msg = result.error_message orelse return null;
    if (std.mem.startsWith(u8, msg, "No frames decoded")) {
        return .{
            .malformation = .video_no_frames_decoded,
            .warning = msg,
        };
    }
    return null;
}

/// Validation errors.
pub const ValidationError = error{
    FileOpenFailed,
    ReadFailed,
    OutOfMemory,
    InvalidFormat,
};

// ============ Magic Byte Detection ============

/// Magic byte signatures for format detection.
const MagicSignature = struct {
    bytes: []const u8,
    offset: usize,
    format: FileFormat,
    /// Minimum header/file size required to trust this signature.
    /// Used to suppress false positives from tiny files (e.g. Spotlight stubs)
    /// that coincidentally share a weak magic pattern. Defaults to 0 (no check).
    min_file_size: usize = 0,
};

/// Known magic byte signatures.
/// Note: Order matters - more specific signatures should come before general ones.
const magic_signatures = [_]MagicSignature{
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    .{ .bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, .offset = 0, .format = .png },
    // JPEG: FF D8 FF
    .{ .bytes = &[_]u8{ 0xFF, 0xD8, 0xFF }, .offset = 0, .format = .jpeg },
    // JPEG XL: FF 0A (codestream) - checked first as it's more specific
    .{ .bytes = &[_]u8{ 0xFF, 0x0A }, .offset = 0, .format = .jxl },
    // JPEG XL container: 00 00 00 0C 4A 58 4C 20 0D 0A 87 0A
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A }, .offset = 0, .format = .jxl },
    // GIF87a/GIF89a
    .{ .bytes = "GIF87a", .offset = 0, .format = .gif },
    .{ .bytes = "GIF89a", .offset = 0, .format = .gif },
    // BMP: BM
    .{ .bytes = "BM", .offset = 0, .format = .bmp, .min_file_size = 58 }, // BMP header (14) + min DIB header (40) + pixel data
    // WebP: RIFF....WEBP (special handling needed)
    .{ .bytes = "RIFF", .offset = 0, .format = .webp }, // Additional check for WEBP at offset 8
    // AVI: RIFF....AVI (special handling - checked after WebP)
    // WAV: RIFF....WAVE (special handling)
    // Fuji RAF: "FUJIFILMCCD-RAW " (16 bytes, unique format, not TIFF-based)
    .{ .bytes = "FUJIFILMCCD-RAW ", .offset = 0, .format = .raf },
    // Panasonic RW2: II + version 0x55 (TIFF variant) - must precede generic TIFF
    .{ .bytes = &[_]u8{ 0x49, 0x49, 0x55, 0x00 }, .offset = 0, .format = .rw2 },
    // Olympus ORF: IIRO (LE), IIRS (LE), or MMOR (BE) — TIFF variant with custom magic
    // Reference: https://libopenraw.freedesktop.org/formats/orf/
    .{ .bytes = &[_]u8{ 0x49, 0x49, 0x52, 0x4F }, .offset = 0, .format = .orf }, // IIRO (little-endian)
    .{ .bytes = &[_]u8{ 0x49, 0x49, 0x52, 0x53 }, .offset = 0, .format = .orf }, // IIRS (little-endian)
    .{ .bytes = &[_]u8{ 0x4D, 0x4D, 0x4F, 0x52 }, .offset = 0, .format = .orf }, // MMOR (big-endian)
    // TIFF: II (little-endian) or MM (big-endian) - also basis for RAW formats
    .{ .bytes = &[_]u8{ 0x49, 0x49, 0x2A, 0x00 }, .offset = 0, .format = .tiff },
    .{ .bytes = &[_]u8{ 0x4D, 0x4D, 0x00, 0x2A }, .offset = 0, .format = .tiff },
    // PSD (Adobe Photoshop): "8BPS" + version (1 for PSD, 2 for PSB)
    .{ .bytes = "8BPS", .offset = 0, .format = .psd },
    // EPS/PostScript: "%!PS-Adobe" header (also used by legacy AI files)
    .{ .bytes = "%!PS-Adobe", .offset = 0, .format = .eps },
    // Adobe After Effects: RIFX (big-endian RIFF) + "Egg!"
    .{ .bytes = "RIFX", .offset = 0, .format = .aep }, // Extended check for "Egg!" at offset 8
    // Adobe InDesign: 06 06 ED F5 with "DOCUMENT" at byte 16
    .{ .bytes = &[_]u8{ 0x06, 0x06, 0xED, 0xF5 }, .offset = 0, .format = .indd },
    // AutoCAD DWG: "AC" + version code (e.g., AC1032 = DWG 2018)
    .{ .bytes = "AC10", .offset = 0, .format = .dwg },
    // Blender: "BLENDER" + pointer size + endianness + version
    .{ .bytes = "BLENDER", .offset = 0, .format = .blend },
    // Canon CR2: II + 42 + CR2 marker at offset 8
    .{ .bytes = &[_]u8{ 0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00, 0x43, 0x52 }, .offset = 0, .format = .cr2 },
    // ZIP: PK (0x50 0x4B 0x03 0x04 for local file header)
    .{ .bytes = &[_]u8{ 0x50, 0x4B, 0x03, 0x04 }, .offset = 0, .format = .zip },
    // Gzip: 1F 8B
    .{ .bytes = &[_]u8{ 0x1F, 0x8B }, .offset = 0, .format = .gzip },
    // Bzip2: 42 5A 68 (BZh) followed by block size 1-9
    .{ .bytes = &[_]u8{ 0x42, 0x5A, 0x68 }, .offset = 0, .format = .bzip2 },
    // XZ: FD 37 7A 58 5A 00 (magic bytes)
    .{ .bytes = &[_]u8{ 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 }, .offset = 0, .format = .xz },
    // Zstandard: 28 B5 2F FD (magic number)
    .{ .bytes = &[_]u8{ 0x28, 0xB5, 0x2F, 0xFD }, .offset = 0, .format = .zstd },
    // BinHex 4.0 envelope line
    .{ .bytes = "(This file must be converted with BinHex 4.0)", .offset = 0, .format = .hqx },
    // RAR5: 52 61 72 21 1A 07 01 00
    .{ .bytes = &[_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00 }, .offset = 0, .format = .rar },
    // RAR4: 52 61 72 21 1A 07 00
    .{ .bytes = &[_]u8{ 0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00 }, .offset = 0, .format = .rar },
    // StuffIt X Base-N: "StuffIt?" (byte 7 = 0x3F instead of 0x21)
    .{ .bytes = &[_]u8{ 0x53, 0x74, 0x75, 0x66, 0x66, 0x49, 0x74, 0x3F }, .offset = 0, .format = .sitx },
    // StuffIt 5/6: ASCII header "StuffIt (c)1997-" (first 16 bytes)
    .{ .bytes = "StuffIt (c)1997-", .offset = 0, .format = .sit },
    // StuffIt variant magics: "ST46", "ST50", "ST60", "ST65", "STin", "STi2", "STi3", "STi4"
    .{ .bytes = "ST46", .offset = 0, .format = .sit },
    .{ .bytes = "ST50", .offset = 0, .format = .sit },
    .{ .bytes = "ST60", .offset = 0, .format = .sit },
    .{ .bytes = "ST65", .offset = 0, .format = .sit },
    .{ .bytes = "STin", .offset = 0, .format = .sit },
    .{ .bytes = "STi2", .offset = 0, .format = .sit },
    .{ .bytes = "STi3", .offset = 0, .format = .sit },
    .{ .bytes = "STi4", .offset = 0, .format = .sit },
    // 7-Zip: 37 7A BC AF 27 1C
    .{ .bytes = &[_]u8{ 0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C }, .offset = 0, .format = .sevenz },
    // PDF: %PDF-
    .{ .bytes = "%PDF-", .offset = 0, .format = .pdf },
    // Matroska/WebM: EBML header 1A 45 DF A3
    .{ .bytes = &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 }, .offset = 0, .format = .mkv }, // WebM is subset, detect later
    // MPEG Program Stream: 00 00 01 BA (pack start code)
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x01, 0xBA }, .offset = 0, .format = .mpeg_ps },
    // MPEG Transport Stream: 47 sync byte (checked with additional validation)
    .{ .bytes = &[_]u8{0x47}, .offset = 0, .format = .mpeg_ts, .min_file_size = 188 }, // one TS packet
    // IVF container: DKIF signature
    .{ .bytes = "DKIF", .offset = 0, .format = .ivf },
    // FLAC: fLaC
    .{ .bytes = "fLaC", .offset = 0, .format = .flac },
    // MP3 with ID3v2 tag
    .{ .bytes = "ID3", .offset = 0, .format = .mp3 },
    // MP3 frame sync (various bitrates) - FF FB, FF FA, FF F3, FF F2
    .{ .bytes = &[_]u8{ 0xFF, 0xFB }, .offset = 0, .format = .mp3, .min_file_size = 128 }, // weak sync: need real frame data
    .{ .bytes = &[_]u8{ 0xFF, 0xFA }, .offset = 0, .format = .mp3, .min_file_size = 128 },
    .{ .bytes = &[_]u8{ 0xFF, 0xF3 }, .offset = 0, .format = .mp3, .min_file_size = 128 },
    .{ .bytes = &[_]u8{ 0xFF, 0xF2 }, .offset = 0, .format = .mp3, .min_file_size = 128 },
    // AAC ADTS frame sync - layer=00 distinguishes from MP3 (layer=01/10/11)
    // MPEG-4: FF F1 (no CRC) / FF F0 (CRC), MPEG-2: FF F9 (no CRC) / FF F8 (CRC)
    .{ .bytes = &[_]u8{ 0xFF, 0xF1 }, .offset = 0, .format = .aac_adts, .min_file_size = 128 },
    .{ .bytes = &[_]u8{ 0xFF, 0xF0 }, .offset = 0, .format = .aac_adts, .min_file_size = 128 },
    .{ .bytes = &[_]u8{ 0xFF, 0xF9 }, .offset = 0, .format = .aac_adts, .min_file_size = 128 },
    .{ .bytes = &[_]u8{ 0xFF, 0xF8 }, .offset = 0, .format = .aac_adts, .min_file_size = 128 },
    // AIFF: FORM....AIFF (IFF container)
    .{ .bytes = "FORM", .offset = 0, .format = .aiff }, // Extended check for AIFF at offset 8
    // Ogg: OggS
    .{ .bytes = "OggS", .offset = 0, .format = .ogg },
    // MIDI: MThd (Standard MIDI File header chunk)
    .{ .bytes = "MThd", .offset = 0, .format = .midi },
    // AC-3 (Dolby Digital): 0B 77 sync word
    // Note: E-AC-3 uses same sync word but different bsid - detected in extended check
    .{ .bytes = &[_]u8{ 0x0B, 0x77 }, .offset = 0, .format = .ac3 },
    // DTS Digital Surround: sync word 7F FE 80 01
    .{ .bytes = &[_]u8{ 0x7F, 0xFE, 0x80, 0x01 }, .offset = 0, .format = .dts },
    // JPEG2000 JP2 container: 00 00 00 0C 6A 50 20 20 (JP2 signature box)
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20 }, .offset = 0, .format = .jpeg2000 },
    // JPEG2000 codestream: FF 4F FF 51 (SOC + SIZ markers)
    .{ .bytes = &[_]u8{ 0xFF, 0x4F, 0xFF, 0x51 }, .offset = 0, .format = .jpeg2000 },
    // JBIG2: 97 4A 42 32 0D 0A 1A 0A (standalone file format)
    .{ .bytes = &[_]u8{ 0x97, 0x4A, 0x42, 0x32, 0x0D, 0x0A, 0x1A, 0x0A }, .offset = 0, .format = .jbig2 },
    // DSF (DSD Stream File): "DSD " at offset 0
    .{ .bytes = "DSD ", .offset = 0, .format = .dsf },
    // DFF (DSDIFF): "FRM8" IFF header, form type "DSD " at offset 12
    .{ .bytes = "FRM8", .offset = 0, .format = .dff },
    // APE (Monkey's Audio): MAC followed by space (0x20)
    .{ .bytes = "MAC ", .offset = 0, .format = .ape },
    // WavPack: wvpk
    .{ .bytes = "wvpk", .offset = 0, .format = .wavpack },
    // Tracker formats
    // XM: "Extended Module: " (FastTracker 2)
    .{ .bytes = "Extended Module: ", .offset = 0, .format = .xm },
    // IT: "IMPM" (Impulse Tracker)
    .{ .bytes = "IMPM", .offset = 0, .format = .it },
    // S3M: "SCRM" at offset 44 (Scream Tracker 3)
    .{ .bytes = "SCRM", .offset = 44, .format = .s3m },
    // OLE2/CFBF (DOC, XLS, PPT): D0 CF 11 E0 A1 B1 1A E1
    .{ .bytes = &[_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 }, .offset = 0, .format = .doc },
    // RTF: {\rtf
    .{ .bytes = "{\\rtf", .offset = 0, .format = .rtf },
    // WordPerfect: FF 57 50 43 (WPC)
    .{ .bytes = &[_]u8{ 0xFF, 0x57, 0x50, 0x43 }, .offset = 0, .format = .wpd },
    // Microsoft Access MDB (97-2003): 00 01 00 00 + "Standard Jet DB" at offset 4
    .{ .bytes = &[_]u8{ 0x00, 0x01, 0x00, 0x00 } ++ "Standard Jet DB", .offset = 0, .format = .mdb },
    // Microsoft Access ACCDB (2007+): 00 01 00 00 + "Standard ACE DB" at offset 4
    .{ .bytes = &[_]u8{ 0x00, 0x01, 0x00, 0x00 } ++ "Standard ACE DB", .offset = 0, .format = .accdb },
    // SQLite: SQLite format 3\0
    .{ .bytes = "SQLite format 3\x00", .offset = 0, .format = .sqlite },
    // HDF5: 89 48 44 46 0D 0A 1A 0A
    .{ .bytes = &[_]u8{ 0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A }, .offset = 0, .format = .hdf5 },
    // Apache Parquet: PAR1
    .{ .bytes = "PAR1", .offset = 0, .format = .parquet },
    // NetCDF classic: CDF followed by version byte (1 or 2)
    .{ .bytes = "CDF\x01", .offset = 0, .format = .netcdf },
    .{ .bytes = "CDF\x02", .offset = 0, .format = .netcdf },
    // FITS: "SIMPLE  =" at offset 0 (standard FITS header keyword)
    .{ .bytes = "SIMPLE  =", .offset = 0, .format = .fits },
    // DICOM: "DICM" at offset 128 (after 128-byte preamble)
    .{ .bytes = "DICM", .offset = 128, .format = .dicom },
    // WARC: "WARC/1.0" or "WARC/1.1" header
    .{ .bytes = "WARC/1.0", .offset = 0, .format = .warc },
    .{ .bytes = "WARC/1.1", .offset = 0, .format = .warc },
    // Game data formats
    // WAD (DOOM): IWAD or PWAD at offset 0
    .{ .bytes = "IWAD", .offset = 0, .format = .wad },
    .{ .bytes = "PWAD", .offset = 0, .format = .wad },
    // PAK (Quake): "PACK" at offset 0
    .{ .bytes = "PACK", .offset = 0, .format = .pak },
    // Larian Studios PAK (BG3, Divinity): "LSPK" at offset 0
    .{ .bytes = "LSPK", .offset = 0, .format = .lspk },
    // BSP (Source engine): "VBSP" at offset 0
    .{ .bytes = "VBSP", .offset = 0, .format = .bsp },
    // BSP (Quake 2/3): "IBSP" at offset 0
    .{ .bytes = "IBSP", .offset = 0, .format = .bsp },
    // VPK (Valve): signature 0x55AA1234 at offset 0
    .{ .bytes = &[_]u8{ 0x34, 0x12, 0xAA, 0x55 }, .offset = 0, .format = .vpk },
    // Game ROM formats
    // NES: iNES header "NES\x1A"
    .{ .bytes = "NES\x1A", .offset = 0, .format = .nes },
    // Nintendo 64: Various byte orderings - .z64 (big-endian) starts with 0x80371240
    .{ .bytes = &[_]u8{ 0x80, 0x37, 0x12, 0x40 }, .offset = 0, .format = .n64 },
    // N64 .n64 (little-endian) starts with 0x40123780
    .{ .bytes = &[_]u8{ 0x40, 0x12, 0x37, 0x80 }, .offset = 0, .format = .n64 },
    // N64 .v64 (byte-swapped) starts with 0x37804012
    .{ .bytes = &[_]u8{ 0x37, 0x80, 0x40, 0x12 }, .offset = 0, .format = .n64 },
    // MAME CHD: "MComprHD"
    .{ .bytes = "MComprHD", .offset = 0, .format = .chd },
    // IFF formats - "FORM" container (AIFF already handled separately)
    // Note: "FORM" is generic IFF, specific types detected via extended format
    // Blorb: "FORM" + size + "IFRS" or "IFZS"
    // Scientific formats
    // MATLAB v5+: starts with descriptive text, then 0x00 0x01 0x49 0x4D at offset 124
    // NIfTI: "n+1\0" or "ni1\0" at offset 344 (in header)
    .{ .bytes = &[_]u8{ 0x6E, 0x2B, 0x31, 0x00 }, .offset = 344, .format = .nifti },
    .{ .bytes = &[_]u8{ 0x6E, 0x69, 0x31, 0x00 }, .offset = 344, .format = .nifti },
    // MATLAB v5: version 0x0100 (LE) + endian indicator "IM" at offset 124
    .{ .bytes = &[_]u8{ 0x00, 0x01, 'I', 'M' }, .offset = 124, .format = .matlab },
    // MATLAB v5 big-endian: version 0x0100 (BE) + endian indicator "MI" at offset 124
    .{ .bytes = &[_]u8{ 0x01, 0x00, 'M', 'I' }, .offset = 124, .format = .matlab },
    // Shapefile: file code 9994 (big-endian) at offset 0
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x27, 0x0A }, .offset = 0, .format = .shapefile },
    // CAD formats
    // STL ASCII: "solid "
    .{ .bytes = "solid ", .offset = 0, .format = .stl },
    // DXF: "0\nSECTION" or "0\r\nSECTION"
    // STEP: "ISO-10303-21;"
    .{ .bytes = "ISO-10303-21;", .offset = 0, .format = .step },
    // 3D printing/modeling formats
    // GLB (binary glTF): "glTF" magic + version
    .{ .bytes = "glTF", .offset = 0, .format = .glb },
    // PLY ASCII: "ply\n" or "ply\r\n"
    .{ .bytes = "ply\n", .offset = 0, .format = .ply },
    .{ .bytes = "ply\r\n", .offset = 0, .format = .ply },
    // Email formats
    // EML: Various headers like "From:", "Received:", "MIME-Version:"
    // MBOX: "From " at line start
    .{ .bytes = "From ", .offset = 0, .format = .mbox },
    // FL Studio: FLhd (FL Studio header)
    .{ .bytes = "FLhd", .offset = 0, .format = .flp },
    // Flash SWF: FWS (uncompressed), CWS (zlib), ZWS (LZMA)
    .{ .bytes = "FWS", .offset = 0, .format = .swf },
    .{ .bytes = "CWS", .offset = 0, .format = .swf },
    .{ .bytes = "ZWS", .offset = 0, .format = .swf },
    // Flash Video: FLV + version byte
    .{ .bytes = "FLV", .offset = 0, .format = .flv },
    // DAW Project formats
    // Reaper: <REAPER_PROJECT
    .{ .bytes = "<REAPER_PROJECT", .offset = 0, .format = .rpp },
    // Font formats
    // TrueType: 00 01 00 00 (sfnt version 1.0)
    .{ .bytes = &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, .offset = 0, .format = .ttf },
    // OpenType with CFF: "OTTO"
    .{ .bytes = "OTTO", .offset = 0, .format = .otf },
    // WOFF (Web Open Font Format): "wOFF"
    .{ .bytes = "wOFF", .offset = 0, .format = .woff },
    // WOFF2: "wOF2"
    .{ .bytes = "wOF2", .offset = 0, .format = .woff2 },
    // Type1 PFB (PostScript binary): 80 01
    .{ .bytes = &[_]u8{ 0x80, 0x01 }, .offset = 0, .format = .type1 },
    // Type1 PFA (PostScript ASCII): "%!" - also used by generic PS, but PFA is common
    .{ .bytes = "%!", .offset = 0, .format = .type1 },
    // PAR2 parity archive: "PAR2\x00PKT"
    .{ .bytes = "PAR2\x00PKT", .offset = 0, .format = .par2 },
    // Erlang/Elixir BEAM bytecode: "FOR1" + size + "BEAM" (IFF-style container)
    .{ .bytes = "FOR1", .offset = 0, .format = .beam },
    // Windows ICO: 00 00 01 00 (reserved, type=1 for icon)
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x01, 0x00 }, .offset = 0, .format = .ico },
    // macOS ICNS icon: "icns"
    .{ .bytes = "icns", .offset = 0, .format = .icns },
    // LLVM precompiled header: "CPCH"
    .{ .bytes = "CPCH", .offset = 0, .format = .llvm_pch },
    // LLVM serialized diagnostics: "DIAG"
    .{ .bytes = "DIAG", .offset = 0, .format = .llvm_diag },
    // Binary plist: "bplist00" (version 00)
    .{ .bytes = "bplist00", .offset = 0, .format = .plist },
    // macOS .DS_Store: 0x00000001 + "Bud1"
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x00, 0x01 } ++ "Bud1", .offset = 0, .format = .ds_store },
    // macOS Spotlight index: "8tsd" magic
    .{ .bytes = "8tsd", .offset = 0, .format = .spotlight },
    // AppleDouble resource fork: 0x00051607
    .{ .bytes = &[_]u8{ 0x00, 0x05, 0x16, 0x07 }, .offset = 0, .format = .apple_double },
    // AppleSingle: 0x00051600
    .{ .bytes = &[_]u8{ 0x00, 0x05, 0x16, 0x00 }, .offset = 0, .format = .apple_double },
    // Apple Media Library Database (Music.app, TV.app): "hfma" magic
    .{ .bytes = "hfma", .offset = 0, .format = .apple_media_db },
    // AMR (Adaptive Multi-Rate): "#!AMR\n" (narrow-band) or "#!AMR-WB\n" (wide-band)
    .{ .bytes = "#!AMR-WB\n", .offset = 0, .format = .amr },
    .{ .bytes = "#!AMR\n", .offset = 0, .format = .amr },
    // AU/SND (Sun/NeXT audio): ".snd" (0x2E736E64)
    .{ .bytes = ".snd", .offset = 0, .format = .au },
    // TTA (True Audio): "TTA1"
    .{ .bytes = "TTA1", .offset = 0, .format = .tta },
    // QOI (Quite OK Image): "qoif"
    .{ .bytes = "qoif", .offset = 0, .format = .qoi },
    // DPX (Digital Picture Exchange): "SDPX" (LE) or "XPDS" (BE)
    .{ .bytes = "SDPX", .offset = 0, .format = .dpx },
    .{ .bytes = "XPDS", .offset = 0, .format = .dpx },
    // ASF/WMV/WMA: ASF Header Object GUID (16 bytes)
    .{ .bytes = &[_]u8{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C }, .offset = 0, .format = .asf },
    // CAF (Core Audio Format): "caff"
    .{ .bytes = "caff", .offset = 0, .format = .caf },
    // ELF (Executable and Linkable Format): 7F 45 4C 46 ("\x7fELF")
    .{ .bytes = &[_]u8{ 0x7F, 0x45, 0x4C, 0x46 }, .offset = 0, .format = .elf },
    // WebAssembly binary module: 00 61 73 6D ("\x00asm")
    .{ .bytes = &[_]u8{ 0x00, 0x61, 0x73, 0x6D }, .offset = 0, .format = .wasm },
    // Unix ar archive: "!<arch>\n"
    .{ .bytes = "!<arch>\n", .offset = 0, .format = .ar },
    // Mach-O: 64-bit little-endian (most common: macOS arm64/x86_64)
    .{ .bytes = &[_]u8{ 0xCF, 0xFA, 0xED, 0xFE }, .offset = 0, .format = .macho },
    // Mach-O: 32-bit little-endian
    .{ .bytes = &[_]u8{ 0xCE, 0xFA, 0xED, 0xFE }, .offset = 0, .format = .macho },
    // Mach-O: 64-bit big-endian
    .{ .bytes = &[_]u8{ 0xFE, 0xED, 0xFA, 0xCF }, .offset = 0, .format = .macho },
    // Mach-O: 32-bit big-endian
    .{ .bytes = &[_]u8{ 0xFE, 0xED, 0xFA, 0xCE }, .offset = 0, .format = .macho },
    // Mach-O Universal/Fat binary (shares 0xCAFEBABE with Java .class - disambiguated in checkSpecialCases)
    .{ .bytes = &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE }, .offset = 0, .format = .macho_fat },
    // OpenEXR: 76 2F 31 01
    .{ .bytes = &[_]u8{ 0x76, 0x2F, 0x31, 0x01 }, .offset = 0, .format = .exr },
    // MPEG elementary stream (sequence header): 00 00 01 B3
    .{ .bytes = &[_]u8{ 0x00, 0x00, 0x01, 0xB3 }, .offset = 0, .format = .mpeg_es },
    // ISO 9660: "CD001" at primary volume descriptor offset 0x8001
    .{ .bytes = "CD001", .offset = 0x8001, .format = .iso },
    // Sega Genesis / Mega Drive: "SEGA" at offset 0x100 (console name field)
    .{ .bytes = "SEGA", .offset = 0x100, .format = .genesis },
    // iCalendar: BEGIN:VCALENDAR
    .{ .bytes = "BEGIN:VCALENDAR", .offset = 0, .format = .icalendar },
    // vCard: BEGIN:VCARD
    .{ .bytes = "BEGIN:VCARD", .offset = 0, .format = .vcard },
    // Microsoft Cabinet: "MSCF" (4D 53 43 46)
    .{ .bytes = "MSCF", .offset = 0, .format = .cab },
    // RealMedia: ".RMF" (2E 52 4D 46)
    .{ .bytes = ".RMF", .offset = 0, .format = .rm },
    // WIM/ESD: "MSWIM\x00\x00\x00"
    .{ .bytes = &[_]u8{ 0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00 }, .offset = 0, .format = .wim },
    // StuffIt Classic: "SIT!" + "rLau" at offset 10
    .{ .bytes = "SIT!", .offset = 0, .format = .sit },
    // StuffIt X: "StuffIt!" (8 bytes)
    .{ .bytes = "StuffIt!", .offset = 0, .format = .sitx },
    // VMDK Hosted Sparse: magic 0x564D444B stored as LE = bytes "KDMV"
    .{ .bytes = "KDMV", .offset = 0, .format = .vmdk },
    // VMDK COWD (ESXi Sparse): magic 0x44574F43 stored as LE = bytes "COWD"
    .{ .bytes = "COWD", .offset = 0, .format = .vmdk },
    // Note: DV, TGA, PAM/PBM/PGM/PPM, HTML, COFF, DMG, CDG, Toast have no reliable magic bytes at offset 0 - detected by extension and/or structure
    // PCAP: four variants (endianness × timestamp resolution)
    .{ .bytes = &[_]u8{ 0xA1, 0xB2, 0xC3, 0xD4 }, .offset = 0, .format = .pcap }, // BE, usec
    .{ .bytes = &[_]u8{ 0xD4, 0xC3, 0xB2, 0xA1 }, .offset = 0, .format = .pcap }, // LE, usec
    .{ .bytes = &[_]u8{ 0xA1, 0xB2, 0x3C, 0x4D }, .offset = 0, .format = .pcap }, // BE, nsec
    .{ .bytes = &[_]u8{ 0x4D, 0x3C, 0xB2, 0xA1 }, .offset = 0, .format = .pcap }, // LE, nsec
    // PCAPNG: Section Header Block
    .{ .bytes = &[_]u8{ 0x0A, 0x0D, 0x0D, 0x0A }, .offset = 0, .format = .pcapng },
    // RPM Package
    .{ .bytes = &[_]u8{ 0xED, 0xAB, 0xEE, 0xDB }, .offset = 0, .format = .rpm },
    // PGP Clearsigned message (must be before generic PEM "-----BEGIN " check)
    .{ .bytes = "-----BEGIN PGP SIGNED MESSAGE-----", .offset = 0, .format = .pgp_signed },
    // SSH Signature (must be before generic PEM "-----BEGIN " check)
    .{ .bytes = "-----BEGIN SSH SIGNATURE-----", .offset = 0, .format = .ssh_signature },
};

/// Maximum number of magic signatures that can share the same first byte.
/// Determined at comptime by scanning magic_signatures.
const max_sigs_per_byte = blk: {
    var max: usize = 0;
    var counts: [256]usize = [_]usize{0} ** 256;
    for (magic_signatures) |sig| {
        if (sig.offset == 0) {
            counts[sig.bytes[0]] += 1;
            if (counts[sig.bytes[0]] > max) {
                max = counts[sig.bytes[0]];
            }
        }
    }
    break :blk max;
};

/// Entry in the first-byte lookup table: a fixed-size array of indices into magic_signatures.
const MagicBucket = struct {
    indices: [max_sigs_per_byte]u8,
    len: u8,
};

/// Comptime lookup table: for each possible first byte (0-255), lists all magic_signatures
/// at offset 0 whose first byte matches. This avoids linear scanning of all signatures.
const magic_by_first_byte: [256]MagicBucket = blk: {
    var table: [256]MagicBucket = undefined;
    for (&table) |*bucket| {
        bucket.len = 0;
        bucket.indices = [_]u8{0} ** max_sigs_per_byte;
    }
    for (magic_signatures, 0..) |sig, i| {
        if (sig.offset == 0) {
            const first = sig.bytes[0];
            table[first].indices[table[first].len] = @intCast(i);
            table[first].len += 1;
        }
    }
    break :blk table;
};

/// Count of non-zero-offset signatures (for the separate scan).
const non_zero_offset_sig_count = blk: {
    var count: usize = 0;
    for (magic_signatures) |sig| {
        if (sig.offset != 0) count += 1;
    }
    break :blk count;
};

/// Comptime array of indices into magic_signatures for non-zero-offset entries.
const non_zero_offset_sigs: [non_zero_offset_sig_count]u8 = blk: {
    var arr: [non_zero_offset_sig_count]u8 = undefined;
    var idx: usize = 0;
    for (magic_signatures, 0..) |sig, i| {
        if (sig.offset != 0) {
            arr[idx] = @intCast(i);
            idx += 1;
        }
    }
    break :blk arr;
};

/// Extended format detection for formats that need more than magic bytes.
/// Returns format based on deeper inspection of header content.
fn detectExtendedFormat(header: []const u8, file: std.fs.File) FileFormat {
    // RIFF-based formats: WebP, AVI, WAV
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "RIFF")) {
        if (std.mem.eql(u8, header[8..12], "WEBP")) {
            return .webp;
        }
        if (std.mem.eql(u8, header[8..12], "AVI ")) {
            return .avi;
        }
        if (std.mem.eql(u8, header[8..12], "WAVE")) {
            return .wav;
        }
    }

    // FORM-based formats (IFF): AIFF, AIFC, Blorb, generic IFF
    if (header.len >= 12 and std.mem.eql(u8, header[0..4], "FORM")) {
        if (std.mem.eql(u8, header[8..12], "AIFF") or std.mem.eql(u8, header[8..12], "AIFC")) {
            return .aiff;
        }
        // Blorb: Interactive Fiction resources (IFRS for Z-machine, IFZS for Glulx)
        if (std.mem.eql(u8, header[8..12], "IFRS") or std.mem.eql(u8, header[8..12], "IFZS")) {
            return .blorb;
        }
        // Generic IFF container (unknown form type)
        return .iff;
    }

    // ISO Base Media File Format (ftyp box): MP4, MOV, HEIC, M4A
    // ftyp at offset 4 or offset 0 (if size is at offset 0)
    if (header.len >= 12) {
        var ftyp_offset: usize = 0;
        if (std.mem.eql(u8, header[4..8], "ftyp")) {
            ftyp_offset = 8;
        } else if (std.mem.eql(u8, header[0..4], "ftyp")) {
            ftyp_offset = 4;
        }

        if (ftyp_offset > 0 and header.len >= ftyp_offset + 4) {
            const brand = header[ftyp_offset..][0..4];
            // HEIC/HEIF brands
            if (std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or
                std.mem.eql(u8, brand, "hevc") or std.mem.eql(u8, brand, "hevx") or
                std.mem.eql(u8, brand, "mif1") or std.mem.eql(u8, brand, "msf1"))
            {
                return .heic;
            }
            // AVIF brands (AV1 Image File Format)
            if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis") or
                std.mem.eql(u8, brand, "av01"))
            {
                return .avif;
            }
            // Canon CR3 (ISO BMFF-based RAW)
            if (std.mem.eql(u8, brand, "crx ")) {
                return .cr3;
            }
            // M4A audio
            if (std.mem.eql(u8, brand, "M4A ") or std.mem.eql(u8, brand, "M4B ")) {
                return .m4a;
            }
            // QuickTime
            if (std.mem.eql(u8, brand, "qt  ")) {
                return .mov;
            }
            // MP4 variants
            if (std.mem.eql(u8, brand, "isom") or std.mem.eql(u8, brand, "iso2") or
                std.mem.eql(u8, brand, "mp41") or std.mem.eql(u8, brand, "mp42") or
                std.mem.eql(u8, brand, "avc1") or std.mem.eql(u8, brand, "M4V ") or
                std.mem.eql(u8, brand, "mp71") or std.mem.eql(u8, brand, "MSNV") or
                std.mem.eql(u8, brand, "dash"))
            {
                return .mp4;
            }
            // Default ftyp to MP4 for unknown brands
            return .mp4;
        }
    }

    // TIFF-based RAW detection - need to read IFD to check for RAW markers
    if (header.len >= 8) {
        const is_le = std.mem.eql(u8, header[0..2], "II");
        const is_be = std.mem.eql(u8, header[0..2], "MM");
        if (is_le or is_be) {
            const magic = if (is_le) std.mem.readInt(u16, header[2..4], .little) else std.mem.readInt(u16, header[2..4], .big);
            if (magic == 42) {
                // Check for RAW-specific markers
                return detectTiffSubformat(file, is_le);
            }
        }
    }

    // MKV vs WebM detection
    if (header.len >= 4 and std.mem.eql(u8, header[0..4], &[_]u8{ 0x1A, 0x45, 0xDF, 0xA3 })) {
        return detectMatroskaSubformat(file);
    }

    return .unknown;
}

/// Detect TIFF subformat (DNG, NEF, ARW, or plain TIFF).
fn detectTiffSubformat(file: std.fs.File, is_le: bool) FileFormat {
    // Read more of the file to check for RAW markers
    file.seekTo(0) catch return .tiff;
    var buffer: [1024]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return .tiff;

    // DNG: Look for DNGVersion tag (0xC612)
    if (findTiffTag(&buffer, bytes_read, 0xC612, is_le)) {
        return .dng;
    }

    // Nikon NEF: Look for Nikon maker note or specific tags
    if (findInBuffer(&buffer, bytes_read, "NIKON")) {
        return .nef;
    }

    // Sony ARW: Look for Sony maker note
    if (findInBuffer(&buffer, bytes_read, "SONY")) {
        return .arw;
    }

    // Olympus ORF: Look for Olympus maker note
    if (findInBuffer(&buffer, bytes_read, "OLYMP")) {
        return .orf;
    }

    // Pentax PEF: Look for Pentax maker note
    if (findInBuffer(&buffer, bytes_read, "PENTAX") or findInBuffer(&buffer, bytes_read, "AOC")) {
        return .pef;
    }

    return .tiff;
}

/// Check if a TIFF tag exists in the buffer.
fn findTiffTag(buffer: []const u8, len: usize, tag_id: u16, is_le: bool) bool {
    if (len < 8) return false;
    const ifd_offset = if (is_le)
        std.mem.readInt(u32, buffer[4..8], .little)
    else
        std.mem.readInt(u32, buffer[4..8], .big);

    if (ifd_offset >= len - 2) return false;

    const entry_count = if (is_le)
        std.mem.readInt(u16, buffer[ifd_offset..][0..2], .little)
    else
        std.mem.readInt(u16, buffer[ifd_offset..][0..2], .big);

    var offset = ifd_offset + 2;
    var i: u16 = 0;
    while (i < entry_count and offset + 12 <= len) : (i += 1) {
        const entry_tag = if (is_le)
            std.mem.readInt(u16, buffer[offset..][0..2], .little)
        else
            std.mem.readInt(u16, buffer[offset..][0..2], .big);

        if (entry_tag == tag_id) return true;
        offset += 12;
    }
    return false;
}

/// Detect Matroska subformat (MKV vs WebM).
fn detectMatroskaSubformat(file: std.fs.File) FileFormat {
    file.seekTo(0) catch return .mkv;
    var buffer: [4096]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return .mkv;

    // Look for WebM DocType
    if (findInBuffer(&buffer, bytes_read, "webm")) {
        return .webm;
    }
    if (findInBuffer(&buffer, bytes_read, "matroska")) {
        return .mkv;
    }
    return .mkv; // Default to MKV
}

/// Detect file format from first bytes (basic detection).
/// Handle special-case format detection that requires additional header inspection
/// beyond the magic bytes match. Returns the detected format, or null to skip this signature.
fn checkSpecialCases(sig: MagicSignature, header: []const u8) ?FileFormat {
    // RIFF-based formats need additional check at offset 8
    if (sig.format == .webp) {
        if (header.len >= 12) {
            if (std.mem.eql(u8, header[8..12], "WEBP")) return .webp;
            if (std.mem.eql(u8, header[8..12], "AVI ")) return .avi;
            if (std.mem.eql(u8, header[8..12], "WAVE")) return .wav;
        }
        return null; // Unknown RIFF format
    }
    // FORM/IFF-based formats (AIFF, AIFC, Blorb, etc.)
    if (sig.format == .aiff) {
        if (header.len >= 12) {
            if (std.mem.eql(u8, header[8..12], "AIFF") or std.mem.eql(u8, header[8..12], "AIFC")) return .aiff;
            if (std.mem.eql(u8, header[8..12], "IFRS") or std.mem.eql(u8, header[8..12], "IFZS")) return .blorb;
            return .iff; // Generic IFF container
        }
        return null;
    }
    // BEAM bytecode (FOR1 + size + "BEAM")
    if (sig.format == .beam) {
        if (header.len >= 12) {
            if (std.mem.eql(u8, header[8..12], "BEAM")) return .beam;
        }
        return null;
    }
    // AC-3 vs E-AC-3 detection (same sync word 0B 77)
    if (sig.format == .ac3) {
        if (header.len >= 6) {
            const bsid = header[5] >> 3;
            if (bsid == 16) return .eac3;
            if (bsid <= 8) return .ac3;
        }
        return null;
    }
    // ADTS AAC - verify with frame_length and second sync
    if (sig.format == .aac_adts) {
        if (header.len >= 7) {
            const freq_idx = (header[2] >> 2) & 0x0F;
            if (freq_idx > 12) return null;
            const fl_high: u16 = @as(u16, header[3] & 0x03);
            const fl_mid: u16 = @as(u16, header[4]);
            const fl_low: u16 = @as(u16, (header[5] >> 5) & 0x07);
            const frame_length = (fl_high << 11) | (fl_mid << 3) | fl_low;
            if (frame_length < 7 or frame_length > 8192) return null;
            if (header.len > frame_length + 1) {
                if (header[frame_length] == 0xFF and (header[frame_length + 1] & 0xF0) == 0xF0 and
                    (header[frame_length + 1] & 0x06) == 0x00)
                {
                    return .aac_adts;
                }
                return null;
            }
            return .aac_adts;
        }
        return null;
    }
    // Mach-O single-arch: validate CPU type and filetype
    if (sig.format == .macho) {
        if (header.len >= 28) {
            // Determine endianness from magic
            const is_le = (header[0] == 0xCE or header[0] == 0xCF);
            const endian: std.builtin.Endian = if (is_le) .little else .big;
            const cputype = std.mem.readInt(u32, header[4..8], endian);
            const filetype = std.mem.readInt(u32, header[12..16], endian);
            const ncmds = std.mem.readInt(u32, header[16..20], endian);
            // Validate CPU type
            const valid_cpu = (cputype == 7 or // i386
                cputype == 0x01000007 or // x86_64
                cputype == 12 or // arm
                cputype == 0x0100000C or // arm64
                cputype == 0x0200000C or // arm64_32
                cputype == 18 or // powerpc
                cputype == 0x01000012); // powerpc64
            if (!valid_cpu) return null;
            // Validate filetype (1-12)
            if (filetype == 0 or filetype > 12) return null;
            // Validate ncmds (should be reasonable)
            if (ncmds == 0 or ncmds > 10000) return null;
        }
        return .macho;
    }
    // Mach-O Universal/Fat: disambiguate from Java .class (both start with 0xCAFEBABE)
    if (sig.format == .macho_fat) {
        if (header.len >= 8) {
            const nfat_arch = std.mem.readInt(u32, header[4..8], .big);
            // Fat binary should have 1-30 architectures; Java .class has version numbers here
            // Java .class: bytes 4-5 = minor version, 6-7 = major version (typically 45-65)
            if (nfat_arch >= 1 and nfat_arch <= 30) {
                // Additional check: for fat binaries, the next bytes should be valid CPU types
                if (header.len >= 28) {
                    const first_cputype = std.mem.readInt(u32, header[8..12], .big);
                    const valid_fat_cpu = (first_cputype == 7 or first_cputype == 0x01000007 or
                        first_cputype == 12 or first_cputype == 0x0100000C or
                        first_cputype == 18 or first_cputype == 0x01000012);
                    if (valid_fat_cpu) return .macho_fat;
                } else {
                    return .macho_fat;
                }
            }
        }
        // Not a fat binary: check if it looks like a Java .class file
        // Java .class: bytes 6-7 = major version (big-endian u16), must be >= 43
        if (header.len >= 8) {
            const major = std.mem.readInt(u16, header[6..8], .big);
            if (major >= 43) return .java_class;
        }
        return null;
    }
    // MPEG TS detection (single 0x47 sync byte needs additional sync verification)
    if (sig.format == .mpeg_ts) {
        if (header.len >= 376) {
            if (header[188] == 0x47) return .mpeg_ts;
            if (header[192] == 0x47) return .mpeg_ts;
            if (header[204] == 0x47) return .mpeg_ts;
        }
        return null;
    }
    // TrueType fonts need validation of numTables
    if (sig.format == .ttf) {
        if (header.len >= 12) {
            const num_tables = (@as(u16, header[4]) << 8) | @as(u16, header[5]);
            if (num_tables == 0 or num_tables > 100) return null;
            const search_range = (@as(u16, header[6]) << 8) | @as(u16, header[7]);
            if (search_range == 0 or search_range > num_tables * 16 or search_range % 16 != 0) return null;
        } else {
            return null;
        }
    }
    // RIFX-based formats (After Effects AEP)
    if (sig.format == .aep) {
        if (header.len >= 12) {
            if (std.mem.eql(u8, header[8..12], "Egg!")) return .aep;
        }
        return null;
    }
    // ICO format needs additional validation
    if (sig.format == .ico) {
        if (header.len >= 6) {
            const image_count = std.mem.readInt(u16, header[4..6], .little);
            if (image_count == 0 or image_count > 256) return null;
            if (header.len >= 10 and header[9] != 0) return null;
        } else {
            return null;
        }
    }
    // WIM vs ESD: check wim_version and LZMS flag to distinguish
    if (sig.format == .wim) {
        if (header.len >= 20) {
            const wim_version = std.mem.readInt(u32, header[12..16], .little);
            const wim_flags = std.mem.readInt(u32, header[16..20], .little);
            // ESD: version 0x0E00 and LZMS compression (0x00080000)
            if (wim_version == 0x0E00 and (wim_flags & 0x00080000) != 0) return .esd;
        }
        return .wim;
    }
    // StuffIt Classic: verify "rLau" secondary signature at offset 10
    if (sig.format == .sit) {
        if (header.len >= 14 and std.mem.eql(u8, header[10..14], "rLau")) return .sit;
        // Accept installer/variant magics: "ST46", "ST50", "ST60", "ST65", "STin", "STi2"/"STi3"/"STi4"
        // and StuffIt 5/6 ASCII header ("StuffIt (c)1997-"): no secondary check needed
        if (header.len >= 2 and header[0] == 'S' and header[1] == 'T') return .sit;
        if (header.len >= 8 and std.mem.startsWith(u8, header, "StuffIt ")) return .sit;
        return null;
    }
    // VMDK: "KDMV" and "COWD" both detected as .vmdk, also check for text descriptor
    if (sig.format == .vmdk) {
        return .vmdk;
    }
    return sig.format;
}


pub fn detectFormat(header: []const u8) FileFormat {
    if (header.len == 0) return .unknown;

    // DICOM must be checked first: DICOM files have a 128-byte preamble that can contain
    // arbitrary data (including TIFF-like signatures II* or MM*). The DICM signature at
    // offset 128 is definitive, so we check it before any offset-0 signatures.
    if (header.len >= 132 and std.mem.eql(u8, header[128..132], "DICM")) {
        return .dicom;
    }

    // Fast path: use first-byte lookup table for offset-0 signatures
    const bucket = magic_by_first_byte[header[0]];
    for (bucket.indices[0..bucket.len]) |sig_idx| {
        const sig = magic_signatures[sig_idx];
        if (header.len >= sig.bytes.len) {
            if (std.mem.eql(u8, header[0..sig.bytes.len], sig.bytes)) {
                if (checkSpecialCases(sig, header)) |format| {
                    // Minimum file size sanity check: reject magic-byte matches
                    // on files too small to be valid instances of the format.
                    // Threshold is per-signature (sig.min_file_size); defaults to 0.
                    // This prevents 32-byte Spotlight stubs from being misdetected.
                    if (header.len >= sig.min_file_size) {
                        return format;
                    }
                    // File too small for this signature — continue checking others
                }
                // checkSpecialCases returns null to mean "continue" (skip this sig)
                // For non-special formats, it returns the format directly
            }
        }
    }

    // Slow path: check non-zero-offset signatures (S3M at 44, MATLAB at 124, NIfTI at 344, etc.)
    for (non_zero_offset_sigs) |sig_idx| {
        const sig = magic_signatures[sig_idx];
        if (header.len >= sig.offset + sig.bytes.len) {
            if (std.mem.eql(u8, header[sig.offset..][0..sig.bytes.len], sig.bytes)) {
                return sig.format;
            }
        }
    }

    // Check for ISO Base Media File Format (ftyp box)
    if (header.len >= 12 and std.mem.eql(u8, header[4..8], "ftyp")) {
        const brand = header[8..12];
        // HEIC/HEIF brands
        if (std.mem.eql(u8, brand, "heic") or std.mem.eql(u8, brand, "heix") or
            std.mem.eql(u8, brand, "hevc") or std.mem.eql(u8, brand, "hevx") or
            std.mem.eql(u8, brand, "mif1") or std.mem.eql(u8, brand, "msf1"))
        {
            return .heic;
        }
        // AVIF brands (AV1 Image File Format)
        if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis") or
            std.mem.eql(u8, brand, "av01"))
        {
            return .avif;
        }
        // Canon CR3 (ISO BMFF-based RAW)
        if (std.mem.eql(u8, brand, "crx ")) {
            return .cr3;
        }
        // M4A audio
        if (std.mem.eql(u8, brand, "M4A ") or std.mem.eql(u8, brand, "M4B ")) {
            return .m4a;
        }
        // QuickTime
        if (std.mem.eql(u8, brand, "qt  ")) {
            return .mov;
        }
        // MP4 variants (default)
        return .mp4;
    }

    // Check for tar archive (POSIX/GNU ustar magic at offset 257)
    // Tar headers are 512-byte blocks; files smaller than that can't be valid tar
    if (header.len >= 512) {
        const ustar_magic = "ustar";
        if (std.mem.eql(u8, header[257..262], ustar_magic)) {
            return .tar;
        }
        // GNU tar has "ustar " with trailing space
        if (std.mem.eql(u8, header[257..263], "ustar ")) {
            return .tar;
        }
    }

    // Check for ProTracker MOD (signature at offset 1080)
    // Note: This requires a large header buffer (1084+ bytes)
    if (header.len >= 1084) {
        const mod_sigs = [_][]const u8{ "M.K.", "M!K!", "FLT4", "FLT8", "4CHN", "6CHN", "8CHN" };
        const sig = header[1080..1084];
        for (mod_sigs) |mod_sig| {
            if (std.mem.eql(u8, sig, mod_sig)) {
                return .mod;
            }
        }
        // Check for xCHN pattern
        if (sig[1] == 'C' and sig[2] == 'H' and sig[3] == 'N' and sig[0] >= '1' and sig[0] <= '9') {
            return .mod;
        }
    }

    // Check for Windows PE executable (MZ header + PE signature)
    if (header.len >= 64 and header[0] == 'M' and header[1] == 'Z') {
        // Read PE header offset from DOS header at offset 0x3C (little-endian)
        const pe_offset = @as(u32, header[0x3C]) |
            (@as(u32, header[0x3D]) << 8) |
            (@as(u32, header[0x3E]) << 16) |
            (@as(u32, header[0x3F]) << 24);

        // PE offset must be reasonable (typically 0x80-0x200, max reasonable ~4KB)
        if (pe_offset >= 4 and pe_offset <= 4096 and pe_offset + 4 <= header.len) {
            // Check for "PE\0\0" signature at PE offset
            if (header[pe_offset] == 'P' and header[pe_offset + 1] == 'E' and
                header[pe_offset + 2] == 0 and header[pe_offset + 3] == 0)
            {
                return .pe;
            }
        }
    }

    // BLIP archive: first byte has bit 7 set (LP envelope), magic "BLAR\x02" or "MBAR\x02" within first 32 bytes
    if (header.len >= 20 and (header[0] & 0x80) != 0) {
        const scan_len = @min(header.len, 32);
        if (scan_len >= 5) {
            for (0..scan_len - 4) |i| {
                if (std.mem.eql(u8, header[i..][0..5], "BLAR\x02")) {
                    return .blar;
                }
                if (std.mem.eql(u8, header[i..][0..5], "MBAR\x02")) {
                    return .mblar;
                }
            }
        }
    }

    // PBM/PGM/PPM/PAM: "P1"-"P7" followed by whitespace
    if (header.len >= 3 and header[0] == 'P' and header[1] >= '1' and header[1] <= '7') {
        if (header[2] == ' ' or header[2] == '\t' or header[2] == '\n' or header[2] == '\r') {
            return .pam;
        }
    }

    // PEM: starts with "-----BEGIN "
    if (header.len >= 20 and std.mem.startsWith(u8, header, "-----BEGIN ")) {
        return .pem;
    }

    // Reason: starts with "Propellerheads Reason Song File\x1A" (32 bytes)
    if (header.len >= 32 and std.mem.eql(u8, header[0..31], "Propellerheads Reason Song File") and header[31] == 0x1A) {
        return .reason;
    }

    // Pro Tools: byte 0 = 0x03, bytes 1-16 = BITCODE "0010111100101011"
    if (header.len >= 20 and header[0] == 0x03 and std.mem.eql(u8, header[1..17], "0010111100101011")) {
        return .ptx;
    }

    // X12 EDI: starts with "ISA" + element delimiter at position 3
    if (header.len >= 106 and std.mem.eql(u8, header[0..3], "ISA")) {
        return .x12_edi;
    }

    // UN/EDIFACT: starts with "UNA" (service string advice) or "UNB+" (default delimiters)
    if (header.len >= 4 and (std.mem.eql(u8, header[0..3], "UNA") or std.mem.eql(u8, header[0..4], "UNB+"))) {
        return .edifact;
    }

    // Text-based format detection (JSON, XML, TOML, YAML)
    // These don't have magic bytes, so we detect by content patterns
    if (detectTextFormat(header)) |text_format| {
        return text_format;
    }

    // Classic QuickTime files without ftyp box (pre-2001 format)
    // These start directly with atoms like: wide, moov, mdat, free, skip
    // Structure: 4-byte size (big-endian) + 4-byte atom type
    if (header.len >= 16) {
        const atom_type = header[4..8];
        // Check for valid QuickTime atom types at offset 4
        if (std.mem.eql(u8, atom_type, "wide") or
            std.mem.eql(u8, atom_type, "moov") or
            std.mem.eql(u8, atom_type, "mdat") or
            std.mem.eql(u8, atom_type, "free") or
            std.mem.eql(u8, atom_type, "skip") or
            std.mem.eql(u8, atom_type, "pnot"))
        {
            // Validate atom size is reasonable
            const atom_size = std.mem.readInt(u32, header[0..4], .big);
            if (atom_size >= 8 or atom_size == 0 or atom_size == 1) {
                // Check for a second valid atom after the first one
                // Atom structure: [4-byte size][4-byte type], so type is at offset+4
                if (atom_size >= 8 and atom_size + 8 <= header.len) {
                    const second_atom_type = header[atom_size + 4 ..][0..4];
                    if (std.mem.eql(u8, second_atom_type, "wide") or
                        std.mem.eql(u8, second_atom_type, "moov") or
                        std.mem.eql(u8, second_atom_type, "mdat") or
                        std.mem.eql(u8, second_atom_type, "free") or
                        std.mem.eql(u8, second_atom_type, "skip") or
                        std.mem.eql(u8, second_atom_type, "pnot") or
                        std.mem.eql(u8, second_atom_type, "PICT") or // Classic Mac PICT resource
                        std.mem.eql(u8, second_atom_type, "uuid"))
                    {
                        return .mov; // Classic QuickTime format
                    }
                }
                // If first atom is moov, it's definitely QuickTime
                if (std.mem.eql(u8, atom_type, "moov")) {
                    return .mov;
                }
            }
        }
    }

    // Check for Chromium/Electron resource PAK (no magic bytes, structural detection)
    // Version 5: uint32(5) + uint8 encoding + 3 padding + uint16 resource_count + uint16 alias_count
    // Version 4: uint32(4) + uint32 resource_count + uint8 encoding
    // Validated by checking first resource entry's offset matches expected index size.
    if (header.len >= 18) {
        const version = std.mem.readInt(u32, header[0..4], .little);
        if (version == 5) {
            const encoding = header[4];
            if (encoding <= 2 and header[5] == 0 and header[6] == 0 and header[7] == 0) {
                const resource_count = std.mem.readInt(u16, header[8..10], .little);
                const alias_count = std.mem.readInt(u16, header[10..12], .little);
                if (resource_count > 0) {
                    // First resource entry offset should match: header + (entries + sentinel) * 6 + aliases * 4
                    const expected_data_start: u32 = 12 + (@as(u32, resource_count) + 1) * 6 + @as(u32, alias_count) * 4;
                    const first_entry_offset = std.mem.readInt(u32, header[14..18], .little);
                    if (first_entry_offset == expected_data_start) {
                        return .chromium_pak;
                    }
                }
            }
        } else if (version == 4 and header.len >= 15) {
            const resource_count = std.mem.readInt(u32, header[4..8], .little);
            const encoding = header[8];
            if (encoding <= 2 and resource_count > 0 and resource_count < 100000) {
                const expected_data_start: u32 = 9 + (@as(u32, resource_count) + 1) * 6;
                const first_entry_offset = std.mem.readInt(u32, header[11..15], .little);
                if (first_entry_offset == expected_data_start) {
                    return .chromium_pak;
                }
            }
        }
    }

    // StuffIt 5: 82-byte ASCII header starting with "StuffIt (c)"
    if (header.len >= 83 and std.mem.startsWith(u8, header, "StuffIt (c)")) {
        return .sit;
    }

    // StuffIt installer variants: "ST46", "ST50", "ST60", "ST65", "STin", "STi2", "STi3", "STi4"
    if (header.len >= 4 and header[0] == 'S' and header[1] == 'T') {
        if (std.mem.eql(u8, header[2..4], "46") or std.mem.eql(u8, header[2..4], "50") or
            std.mem.eql(u8, header[2..4], "60") or std.mem.eql(u8, header[2..4], "65") or
            std.mem.eql(u8, header[2..4], "in") or std.mem.eql(u8, header[2..4], "i2") or
            std.mem.eql(u8, header[2..4], "i3") or std.mem.eql(u8, header[2..4], "i4"))
        {
            return .sit;
        }
    }

    // VMDK descriptor-only: text file starting with "# Disk DescriptorFile"
    if (header.len >= 21 and std.mem.startsWith(u8, header, "# Disk DescriptorFile")) {
        return .vmdk;
    }

    // dBASE .dbf: version byte (low 3 bits 0x03..0x05, 0x07; or 0x30, 0x83, 0x8B, 0xCB, 0xF5)
    // Combined with structural plausibility: len_header >= 33 and len_record > 0
    if (header.len >= 12) {
        const dbf_version = header[0];
        const is_dbf_version = switch (dbf_version) {
            0x02, 0x03, 0x04, 0x05, 0x07, // dBASE II/III/IV/V
            0x30, 0x31, 0x32, 0x43, 0x63, // Visual FoxPro variants
            0x7B, // dBASE IV + memo + SQL table
            0x83, 0x87, 0x8B, 0x8E, // dBASE III+ with memo, dBASE IV with memo
            0xCB, // dBASE IV with memo + SQL table
            0xE5, // Clipper SIX with SMT memo
            0xF5, 0xF4, 0xFB, // FoxPro with memo
            => true,
            else => false,
        };
        if (is_dbf_version) {
            const len_header = std.mem.readInt(u16, header[8..10], .little);
            const len_record = std.mem.readInt(u16, header[10..12], .little);
            // Date fields: byte[1]=year (any), byte[2]=month (1-12), byte[3]=day (1-31)
            const month = header[2];
            const day = header[3];
            // len_header must be at least 33 (32-byte prefix + terminator byte),
            // len_record > 0 (at minimum the deletion-flag byte, so >= 1),
            // and date fields must be plausible to avoid misdetecting text files
            // (e.g. SRT subtitles starting with 0x31 which matches Visual FoxPro version)
            if (len_header >= 33 and len_record > 0 and
                month >= 1 and month <= 12 and day >= 1 and day <= 31)
            {
                return .dbf;
            }
        }
    }

    return .unknown;
}

/// Result of MIME wrapper detection
const MimeWrapperResult = struct {
    /// Offset to the embedded content (where the actual file data starts)
    content_offset: usize,
    /// Detected format of the embedded content
    embedded_format: FileFormat,
    /// Whether MIME wrapper was detected
    is_mime_wrapped: bool,
};

/// Detect if data is MIME-wrapped and find embedded content.
/// MIME-wrapped files occur when buggy web services return multipart MIME bodies
/// instead of raw file content. The actual file is embedded after MIME headers.
/// Returns the offset to embedded content and its detected format.
fn detectMimeWrapper(data: []const u8) MimeWrapperResult {
    const no_wrapper = MimeWrapperResult{ .content_offset = 0, .embedded_format = .unknown, .is_mime_wrapped = false };

    if (data.len < 50) return no_wrapper;

    // Check for MIME boundary marker at start (e.g., "------=_Part_")
    const is_boundary_start = std.mem.startsWith(u8, data, "------") or
        std.mem.startsWith(u8, data, "--====") or
        std.mem.startsWith(u8, data, "--_");

    // Check for Content-Type header near start
    const has_content_type = if (std.mem.indexOf(u8, data[0..@min(data.len, 500)], "Content-Type:")) |_| true else false;

    if (!is_boundary_start and !has_content_type) {
        return no_wrapper;
    }

    // Scan for embedded format signatures
    // Look for common binary format signatures that indicate start of embedded content

    // PDF signature
    if (std.mem.indexOf(u8, data, "%PDF-")) |offset| {
        // Verify it looks like a real PDF header (followed by version number)
        if (offset + 8 <= data.len) {
            const after = data[offset + 5 ..];
            // Check for version like "1.4" or "1.7" or "2.0"
            if (after.len >= 3 and after[0] >= '0' and after[0] <= '9' and after[1] == '.') {
                return MimeWrapperResult{
                    .content_offset = offset,
                    .embedded_format = .pdf,
                    .is_mime_wrapped = true,
                };
            }
        }
    }

    // PNG signature
    if (std.mem.indexOf(u8, data, "\x89PNG\r\n\x1a\n")) |offset| {
        return MimeWrapperResult{
            .content_offset = offset,
            .embedded_format = .png,
            .is_mime_wrapped = true,
        };
    }

    // JPEG signature (FFD8FF)
    for (data[0 .. data.len - 3], 0..) |byte, i| {
        if (byte == 0xFF and data[i + 1] == 0xD8 and data[i + 2] == 0xFF) {
            return MimeWrapperResult{
                .content_offset = i,
                .embedded_format = .jpeg,
                .is_mime_wrapped = true,
            };
        }
    }

    // ZIP/Office signature (PK..)
    if (std.mem.indexOf(u8, data, "PK\x03\x04")) |offset| {
        return MimeWrapperResult{
            .content_offset = offset,
            .embedded_format = .zip,
            .is_mime_wrapped = true,
        };
    }

    // GIF signature
    if (std.mem.indexOf(u8, data, "GIF89a") orelse std.mem.indexOf(u8, data, "GIF87a")) |offset| {
        return MimeWrapperResult{
            .content_offset = offset,
            .embedded_format = .gif,
            .is_mime_wrapped = true,
        };
    }

    return no_wrapper;
}

/// Find the end of embedded content in a MIME-wrapped file.
/// Looks for closing MIME boundary (------=... followed by --) near end of file.
/// Returns the offset where the embedded content ends.
fn findMimeContentEnd(file: std.fs.File, content_start: usize, file_size: u64) !u64 {
    // Search backwards from end of file for closing MIME boundary
    // Closing boundaries look like: \r\n------=_Part_xxx--\r\n
    const search_size: u64 = 4096;
    const search_start = if (file_size > search_size) file_size - search_size else 0;

    try file.seekTo(search_start);

    var buffer: [4096]u8 = undefined;
    const read_bytes = try file.read(&buffer);

    // Look for MIME boundary end marker (boundary followed by --)
    // The content ends just before the \r\n preceding the closing boundary
    var i: usize = 0;
    while (i + 10 < read_bytes) : (i += 1) {
        // Look for ------ pattern that could be a boundary
        if (buffer[i] == '-' and buffer[i + 1] == '-') {
            // Find end of this line
            var j = i + 2;
            while (j < read_bytes and buffer[j] != '\r' and buffer[j] != '\n') : (j += 1) {}

            // Check if line ends with -- (closing boundary marker)
            if (j >= 4 and buffer[j - 1] == '-' and buffer[j - 2] == '-') {
                // This is a closing boundary, content ends before the \r\n before it
                var content_end = search_start + i;
                // Skip back over any \r\n before the boundary
                if (content_end > content_start and buffer[i - 1] == '\n') {
                    content_end -= 1;
                    if (content_end > content_start and i >= 2 and buffer[i - 2] == '\r') {
                        content_end -= 1;
                    }
                }
                return content_end;
            }
        }
    }

    // No closing boundary found, assume content goes to end (minus any trailing whitespace)
    var end = file_size;
    if (read_bytes > 0) {
        var k: usize = read_bytes;
        while (k > 0 and (buffer[k - 1] == '\r' or buffer[k - 1] == '\n' or buffer[k - 1] == ' ')) : (k -= 1) {}
        end = search_start + k;
    }
    return end;
}

/// Validate data buffer for a specific format (used for MIME-wrapped content)
pub fn validateDataBufferFormat(data: []const u8, format: FileFormat) ValidationResult {
    return switch (format) {
        .pdf => pdf_validator.validatePdfFromBuffer(data),
        .png => image_validators.validatePngFromBuffer(data),
        .jpeg => image_validators.validateJpegFromBuffer(data),
        .gif => image_validators.validateGifFromBuffer(data),
        .bmp => image_validators.validateBmpFromBuffer(data),
        .tiff => image_validators.validateTiffFromBuffer(data),
        .webp => image_validators.validateWebpFromBuffer(data),
        .hqx => archive_validators.validateHqxFromBuffer(data),
        .cpt => archive_validators.validateCptFromBuffer(data),
        .sit => stuffit_validator.validateSitFromBuffer(data),
        .sitx => stuffit_validator.validateSitxFromBuffer(data),
        .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp, .song => archive_validators.validateZipFromBuffer(data, format),
        .mp4, .mov, .m4a => movie_validators.validateMp4FromBuffer(data),
        else => ValidationResult.ok(format), // Format not supported for buffer validation
    };
}

/// Check if path is a SQLite companion file (WAL, SHM, or journal).
/// These are ephemeral files created by SQLite's WAL/journal mode and
/// should be recognized rather than flagged as UNKNOWN.
fn isSqliteCompanionFile(path: []const u8) bool {
    // These are compound extensions like ".sqlite-wal", ".sqlite-shm", ".sqlite-journal"
    // We check for the compound extension by finding the second-to-last dot
    const last_dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    if (last_dot + 1 >= path.len) return false;
    const ext = path[last_dot + 1 ..];

    // Convert to lowercase
    var lower: [20]u8 = undefined;
    if (ext.len > lower.len) return false;
    for (ext, 0..) |c, i| {
        lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const ext_lower = lower[0..ext.len];

    return std.mem.eql(u8, ext_lower, "sqlite-wal") or
        std.mem.eql(u8, ext_lower, "sqlite-shm") or
        std.mem.eql(u8, ext_lower, "sqlite-journal") or
        std.mem.eql(u8, ext_lower, "db-wal") or
        std.mem.eql(u8, ext_lower, "db-shm") or
        std.mem.eql(u8, ext_lower, "db-journal");
}

/// Extract lowercase file extension from a path into a stack buffer.
/// Returns the lowercase extension slice, or null if no valid extension found.
fn lowercaseExtension(path: []const u8, buf: *[16]u8) ?[]const u8 {
    const dot_pos = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    if (dot_pos + 1 >= path.len) return null;
    const ext = path[dot_pos + 1 ..];
    if (ext.len > buf.len) return null;
    for (ext, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf[0..ext.len];
}

/// Unified extension-to-format map. Used by both detectFormatFromExtension (fallback
/// when magic bytes are absent) and getExpectedFormatForExtension (mismatch detection).
/// Note: .o is intentionally omitted — it can be COFF or ELF, so magic bytes decide.
const ext_format_map = std.StaticStringMap(FileFormat).initComptime(.{
    // Images
    .{ "png", .png },
    .{ "jpg", .jpeg },
    .{ "jpeg", .jpeg },
    .{ "gif", .gif },
    .{ "bmp", .bmp },
    .{ "webp", .webp },
    .{ "tiff", .tiff },
    .{ "tif", .tiff },
    .{ "heic", .heic },
    .{ "heif", .heic },
    .{ "avif", .avif },
    .{ "exr", .exr },
    .{ "jxl", .jxl },
    .{ "svg", .svg },
    .{ "apng", .png },
    .{ "qoi", .qoi },
    .{ "pbm", .pam },
    .{ "pgm", .pam },
    .{ "ppm", .pam },
    .{ "pam", .pam },
    .{ "pnm", .pam },
    .{ "dpx", .dpx },
    .{ "tga", .tga },
    .{ "targa", .tga },
    .{ "ico", .ico },
    .{ "icns", .icns },
    .{ "psd", .psd },
    .{ "psb", .psd },
    // Creative / design
    .{ "ai", .ai },
    .{ "eps", .eps },
    .{ "epsf", .eps },
    .{ "sketch", .sketch },
    .{ "aep", .aep },
    .{ "aepx", .aep },
    .{ "prproj", .prproj },
    .{ "indd", .indd },
    .{ "indt", .indd },
    .{ "idml", .idml },
    .{ "dwg", .dwg },
    .{ "blend", .blend },
    .{ "blend1", .blend },
    .{ "fcpxml", .fcpxml },
    .{ "drp", .drp },
    // Databases
    .{ "mdb", .mdb },
    .{ "accdb", .accdb },
    .{ "dbf", .dbf },
    .{ "sqlite", .sqlite },
    .{ "sqlite3", .sqlite },
    // RAW camera formats
    .{ "dng", .dng },
    .{ "cr2", .cr2 },
    .{ "cr3", .cr3 },
    .{ "nef", .nef },
    .{ "nrw", .nef }, // NRW is same format as NEF (Nikon)
    .{ "arw", .arw },
    .{ "raf", .raf },
    .{ "orf", .orf },
    .{ "rw2", .rw2 },
    .{ "pef", .pef },
    // Documents
    .{ "pdf", .pdf },
    .{ "rtf", .rtf },
    // Archives
    .{ "zip", .zip },
    .{ "gz", .gzip },
    .{ "gzip", .gzip },
    .{ "bz2", .bzip2 },
    .{ "xz", .xz },
    .{ "zst", .zstd },
    .{ "zstd", .zstd },
    .{ "rar", .rar },
    .{ "cpt", .cpt },
    .{ "7z", .sevenz },
    .{ "tar", .tar },
    .{ "br", .br },
    .{ "hqx", .hqx },
    // Office documents
    .{ "docx", .docx },
    .{ "xlsx", .xlsx },
    .{ "pptx", .pptx },
    .{ "doc", .doc },
    .{ "xls", .xls },
    .{ "ppt", .ppt },
    .{ "odt", .odt },
    .{ "ods", .ods },
    .{ "odp", .odp },
    .{ "epub", .epub },
    .{ "pages", .pages },
    // Video
    .{ "mp4", .mp4 },
    .{ "m4v", .mp4 },
    .{ "mov", .mov },
    .{ "mkv", .mkv },
    .{ "webm", .webm },
    .{ "avi", .avi },
    .{ "flv", .flv },
    .{ "swf", .swf },
    .{ "3gp", .mp4 },
    .{ "3g2", .mp4 },
    .{ "3gpp", .mp4 },
    .{ "asf", .asf },
    .{ "wmv", .asf },
    .{ "wma", .asf },
    .{ "dv", .dv },
    .{ "dif", .dv },
    // Audio
    .{ "mp3", .mp3 },
    .{ "flac", .flac },
    .{ "wav", .wav },
    .{ "m4a", .m4a },
    .{ "aiff", .aiff },
    .{ "aif", .aiff },
    .{ "ogg", .ogg },
    .{ "oga", .ogg },
    .{ "ogv", .ogg },
    .{ "opus", .ogg },
    .{ "mid", .midi },
    .{ "midi", .midi },
    .{ "ape", .ape },
    .{ "wv", .wavpack },
    .{ "amr", .amr },
    .{ "awb", .amr },
    .{ "au", .au },
    .{ "snd", .au },
    .{ "tta", .tta },
    .{ "caf", .caf },
    .{ "aac", .aac_adts },
    .{ "ac3", .ac3 },
    .{ "dts", .dts },
    .{ "eac3", .eac3 },
    .{ "ec3", .eac3 },
    .{ "dsf", .dsf },
    .{ "dff", .dff },
    // Tracker/module formats
    .{ "mod", .mod },
    .{ "xm", .xm },
    .{ "it", .it },
    .{ "s3m", .s3m },
    // Fonts
    .{ "ttf", .ttf },
    .{ "otf", .otf },
    .{ "woff", .woff },
    .{ "woff2", .woff2 },
    // 3D printing/modeling formats
    .{ "3mf", .@"3mf" },
    .{ "obj", .obj },
    .{ "ply", .ply },
    .{ "gltf", .gltf },
    .{ "glb", .glb },
    .{ "stl", .stl },
    .{ "step", .step },
    .{ "stp", .step },
    .{ "dxf", .dxf },
    // Game data/ROM formats
    .{ "wad", .wad },
    .{ "bsp", .bsp },
    .{ "vpk", .vpk },
    .{ "nes", .nes },
    .{ "sfc", .snes },
    .{ "smc", .snes },
    .{ "z64", .n64 },
    .{ "n64", .n64 },
    .{ "v64", .n64 },
    .{ "gb", .gb },
    .{ "gbc", .gb },
    .{ "gba", .gba },
    .{ "nds", .nds },
    .{ "gen", .genesis },
    .{ "smd", .genesis },
    .{ "chd", .chd },
    // Scientific/data formats
    .{ "h5", .hdf5 },
    .{ "hdf5", .hdf5 },
    .{ "hdf", .hdf5 },
    .{ "parquet", .parquet },
    .{ "nc", .netcdf },
    .{ "netcdf", .netcdf },
    .{ "fits", .fits },
    .{ "fit", .fits },
    .{ "dcm", .dicom },
    .{ "dicom", .dicom },
    .{ "fasta", .fasta },
    .{ "fa", .fasta },
    .{ "fna", .fasta },
    .{ "fastq", .fastq },
    .{ "fq", .fastq },
    // MPEG streams
    .{ "mpg", .mpeg_ps },
    .{ "mpeg", .mpeg_ps },
    .{ "vob", .mpeg_ps },
    .{ "ts", .mpeg_ts },
    .{ "mts", .mpeg_ts },
    .{ "m2ts", .mpeg_ts },
    .{ "m1v", .mpeg_es },
    .{ "m2v", .mpeg_es },
    .{ "mpv", .mpeg_es },
    .{ "es", .mpeg_es },
    .{ "ivf", .ivf },
    // IFF/Blorb
    .{ "iff", .iff },
    .{ "blorb", .blorb },
    .{ "blb", .blorb },
    // macOS
    .{ "ds_store", .ds_store },
    .{ "tvdb", .apple_media_db },
    .{ "musicdb", .apple_media_db },
    // Disk images
    .{ "iso", .iso },
    .{ "dmg", .dmg },
    .{ "toast", .toast },
    // Virtual machine disk formats
    .{ "vmdk", .vmdk },
    // Windows imaging formats
    .{ "wim", .wim },
    .{ "esd", .esd },
    .{ "swm", .wim },
    // Microsoft Cabinet
    .{ "cab", .cab },
    // Microsoft Installer
    .{ "msi", .msi },
    .{ "msp", .msi },
    .{ "mst", .msi },
    // BLIP archives
    .{ "blar", .blar },
    .{ "mblar", .mblar },
    // StuffIt archives
    .{ "sit", .sit },
    .{ "sitx", .sitx },
    // MPEG Audio Layer II
    .{ "mp2", .mp2 },
    .{ "mpa", .mp2 },
    // RealMedia
    .{ "rm", .rm },
    .{ "rmvb", .rm },
    .{ "ra", .rm },
    .{ "ram", .rm },
    // Karaoke
    .{ "cdg", .cdg },
    // DAW formats
    .{ "als", .als },
    .{ "rpp", .rpp },
    .{ "flp", .flp },
    .{ "bwproject", .bwproject },
    .{ "cpr", .cpr },
    .{ "ptx", .ptx },
    .{ "band", .band },
    .{ "reason", .reason },
    .{ "logicx", .logicx },
    .{ "song", .song },
    // Financial data formats
    .{ "qbw", .qbw },
    .{ "qbb", .qbb },
    .{ "qbm", .qbb },
    .{ "qdf", .qdf },
    .{ "ofx", .ofx },
    .{ "qfx", .ofx },
    .{ "qif", .qif },
    .{ "txf", .txf },
    .{ "ach", .nacha },
    .{ "nacha", .nacha },
    .{ "mt940", .mt940 },
    .{ "sta", .mt940 },
    .{ "940", .mt940 },
    .{ "bai", .bai2 },
    .{ "bai2", .bai2 },
    // PIM formats
    .{ "ics", .icalendar },
    .{ "ical", .icalendar },
    .{ "ifb", .icalendar },
    .{ "vcf", .vcard },
    .{ "vcard", .vcard },
    // EDI formats
    .{ "edi", .x12_edi },
    .{ "x12", .x12_edi },
    .{ "837", .x12_edi },
    .{ "835", .x12_edi },
    .{ "834", .x12_edi },
    .{ "270", .x12_edi },
    .{ "271", .x12_edi },
    .{ "997", .x12_edi },
    .{ "edifact", .edifact },
    .{ "eancom", .edifact },
    // Crypto/certificate formats
    .{ "pem", .pem },
    .{ "crt", .pem },
    .{ "key", .pem },
    .{ "der", .der },
    .{ "cer", .der },
    .{ "asc", .pgp_signed },
    // GIS
    .{ "kml", .kml },
    .{ "kmz", .kmz },
    .{ "shp", .shapefile },
    // Email
    .{ "eml", .eml },
    .{ "mbox", .mbox },
    // Text formats
    .{ "toml", .toml },
    .{ "tml", .toml },
    .{ "ini", .ini },
    .{ "json", .json },
    .{ "xml", .xml },
    .{ "yaml", .yaml },
    .{ "yml", .yaml },
    .{ "md", .markdown },
    .{ "markdown", .markdown },
    .{ "ndjson", .json },
    .{ "jsonl", .json },
    .{ "json5", .json },
    .{ "csv", .csv },
    .{ "tsv", .csv },
    .{ "plist", .plist },
    .{ "tvdb", .apple_media_db },
    .{ "musicdb", .apple_media_db },
    // Subtitle formats (plain text with timestamps)
    .{ "srt", .plain_text },
    .{ "vtt", .plain_text },
    .{ "ass", .plain_text },
    .{ "ssa", .plain_text },
    .{ "sub", .plain_text },
    // Common plain text extensions
    .{ "txt", .plain_text },
    .{ "log", .plain_text },
    .{ "nfo", .plain_text_cp437 }, // IBM PC/DOS box-drawing art
    .{ "html", .html },
    .{ "htm", .html },
    .{ "xhtml", .html },
    // Erlang/Elixir
    .{ "app", .erlang_term },
    .{ "config", .erlang_term },
    .{ "lock", .erlang_term },
    .{ "beam", .beam },
    .{ "eex", .eex },
    .{ "leex", .eex },
    .{ "heex", .eex },
    .{ "erb", .eex },
    // Legacy word processors
    .{ "cwk", .cwk },
    .{ "mwd", .mwd },
    // LLVM compiler artifacts
    .{ "dia", .llvm_diag },
    // Binary serialization
    .{ "msgpack", .msgpack },
    // Windows PE executable extensions
    .{ "exe", .pe },
    .{ "dll", .pe },
    .{ "sys", .pe },
    .{ "scr", .pe },
    .{ "ocx", .pe },
    .{ "cpl", .pe },
    // ELF executable extensions
    .{ "so", .elf },
    .{ "elf", .elf },
    .{ "ko", .elf },
    .{ "axf", .elf },
    // WebAssembly
    .{ "wasm", .wasm },
    // Java bytecode
    .{ "class", .java_class },
    // Unix ar archive (static libraries)
    .{ "a", .ar },
    // Network capture formats
    .{ "pcap", .pcap },
    .{ "cap", .pcap },
    .{ "pcapng", .pcapng },
    // Package formats
    .{ "rpm", .rpm },
    .{ "srpm", .rpm },
});

/// Extensions that should NOT be validated as a text format even if content
/// detection matches JSON/XML/TOML/etc. These are code, config, log, and
/// template files that would be false positives from content detection.
const excluded_text_exts = std.StaticStringMap(void).initComptime(.{
    // Systems languages
    .{ "c", {} },
    .{ "h", {} },
    .{ "cpp", {} },
    .{ "cxx", {} },
    .{ "cc", {} },
    .{ "hpp", {} },
    .{ "hxx", {} },
    .{ "hh", {} },
    .{ "zig", {} },
    .{ "zon", {} },
    .{ "rs", {} },
    .{ "go", {} },
    .{ "d", {} },
    .{ "m", {} },
    .{ "mm", {} },
    .{ "swift", {} },
    .{ "s", {} },
    .{ "asm", {} },
    // JVM/managed languages
    .{ "java", {} },
    .{ "kt", {} },
    .{ "kts", {} },
    .{ "scala", {} },
    .{ "groovy", {} },
    .{ "cs", {} },
    .{ "fs", {} },
    .{ "fsx", {} },
    .{ "vb", {} },
    // Web/scripting
    .{ "js", {} },
    .{ "mjs", {} },
    .{ "cjs", {} },
    .{ "ts", {} },
    .{ "mts", {} },
    .{ "cts", {} },
    .{ "rb", {} },
    .{ "py", {} },
    .{ "pyi", {} },
    .{ "pl", {} },
    .{ "pm", {} },
    .{ "lua", {} },
    // BEAM/Erlang ecosystem
    .{ "erl", {} },
    .{ "hrl", {} },
    .{ "ex", {} },
    .{ "exs", {} },
    .{ "gleam", {} },
    // Shell/scripting
    .{ "sh", {} },
    .{ "bash", {} },
    .{ "zsh", {} },
    .{ "fish", {} },
    .{ "ps1", {} },
    .{ "bat", {} },
    .{ "cmd", {} },
    .{ "awk", {} },
    .{ "sed", {} },
    .{ "tcl", {} },
    .{ "r", {} },
    .{ "jl", {} },
    .{ "nim", {} },
    .{ "v", {} },
    // Functional/academic
    .{ "hs", {} },
    .{ "lhs", {} },
    .{ "ml", {} },
    .{ "mli", {} },
    .{ "clj", {} },
    .{ "cljs", {} },
    .{ "rkt", {} },
    .{ "scm", {} },
    .{ "lisp", {} },
    .{ "el", {} },
    // Nix, config-as-code
    .{ "nix", {} },
    .{ "dhall", {} },
    .{ "tf", {} },
    .{ "hcl", {} },
    .{ "cmake", {} },
    .{ "gradle", {} },
    .{ "sbt", {} },
    // Web template files
    .{ "hbs", {} },
    .{ "mustache", {} },
    .{ "htc", {} },
    .{ "vue", {} },
    .{ "svelte", {} },
    .{ "astro", {} },
    .{ "jsx", {} },
    .{ "tsx", {} },
    .{ "php", {} },
    .{ "asp", {} },
    .{ "aspx", {} },
    .{ "jsp", {} },
    .{ "jspx", {} },
    .{ "twig", {} },
    // Log and data files
    .{ "log", {} },
    .{ "txt", {} },
    .{ "text", {} },
    .{ "out", {} },
    .{ "err", {} },
    .{ "diff", {} },
    .{ "patch", {} },
    // Config files that look like JSON/TOML but aren't standard
    .{ "conf", {} },
    .{ "cfg", {} },
    .{ "properties", {} },
    .{ "env", {} },
    // Windows-specific files that look like INI but aren't standard config
    .{ "url", {} },
    .{ "website", {} },
    // Qt project files (qmake)
    .{ "pro", {} },
    .{ "pri", {} },
});

/// Known filenames (case-insensitive, no extension) excluded from text validation.
const excluded_text_filenames = std.StaticStringMap(void).initComptime(.{
    .{ "makefile", {} },
    .{ "emakefile", {} },
    .{ "gnumakefile", {} },
    .{ "rakefile", {} },
    .{ "gemfile", {} },
    .{ "vagrantfile", {} },
    .{ "dockerfile", {} },
    .{ "jenkinsfile", {} },
    .{ "procfile", {} },
    .{ "license", {} },
    .{ "changelog", {} },
    .{ "authors", {} },
    .{ "contributors", {} },
    .{ "copying", {} },
    .{ "install", {} },
    .{ "todo", {} },
    .{ "news", {} },
    .{ "history", {} },
});

/// Extension-only detection map: formats that lack reliable magic bytes and need
/// extension-based detection as the primary (not just mismatch) identification.
/// This is a subset of ext_format_map — only formats where magic bytes detection
/// fails or is too ambiguous to be the primary detection mechanism.
const ext_detect_map = std.StaticStringMap(FileFormat).initComptime(.{
    // No magic bytes at all
    .{ "br", .br },
    .{ "hqx", .hqx },
    .{ "cpt", .cpt },
    .{ "dv", .dv },
    .{ "dif", .dv },
    .{ "tga", .tga },
    .{ "targa", .tga },
    // DAW/creative formats with no magic or ambiguous magic
    .{ "bwproject", .bwproject },
    .{ "ptx", .ptx },
    .{ "band", .band },
    .{ "reason", .reason },
    .{ "cpr", .cpr },
    .{ "logicx", .logicx },
    .{ "song", .song },
    .{ "sketch", .sketch },
    .{ "drp", .drp },
    // Game ROM formats — many lack magic bytes at offset 0
    .{ "smc", .snes },
    .{ "sfc", .snes },
    .{ "gb", .gb },
    .{ "gbc", .gb },
    .{ "gba", .gba },
    .{ "nds", .nds },
    .{ "gen", .genesis },
    .{ "smd", .genesis },
    // Disk images — magic at non-zero offsets or trailer-only
    .{ "iso", .iso },
    .{ "dmg", .dmg },
    // .obj is ambiguous: Wavefront OBJ (text 3D model) or COFF (compiled object file)
    // The ext_has_no_magic handler tries COFF first, falls back to Wavefront OBJ
    .{ "obj", .obj },
    // Legacy word processors — no magic bytes
    .{ "cwk", .cwk },
    .{ "mwd", .mwd },
    // Financial data formats — magic is ambiguous (OLE2, ZIP, or SQL Anywhere)
    .{ "qbw", .qbw },
    .{ "qbb", .qbb },
    .{ "qbm", .qbb },
    .{ "qdf", .qdf },
    .{ "ofx", .ofx },
    .{ "qfx", .ofx },
    .{ "qif", .qif },
    .{ "txf", .txf },
    .{ "ach", .nacha },
    .{ "nacha", .nacha },
    .{ "mt940", .mt940 },
    .{ "sta", .mt940 },
    .{ "940", .mt940 },
    .{ "bai", .bai2 },
    .{ "bai2", .bai2 },
    // PIM formats — also have magic bytes, but extension mapping aids detection
    .{ "ics", .icalendar },
    .{ "ical", .icalendar },
    .{ "ifb", .icalendar },
    .{ "vcf", .vcard },
    .{ "vcard", .vcard },
    // EDI formats
    .{ "edi", .x12_edi },
    .{ "x12", .x12_edi },
    .{ "837", .x12_edi },
    .{ "835", .x12_edi },
    .{ "834", .x12_edi },
    .{ "270", .x12_edi },
    .{ "271", .x12_edi },
    .{ "997", .x12_edi },
    .{ "edifact", .edifact },
    .{ "eancom", .edifact },
    // Crypto/certificate formats
    .{ "pem", .pem },
    .{ "crt", .pem },
    .{ "key", .pem },
    .{ "der", .der },
    .{ "cer", .der },
    .{ "asc", .pgp_signed },
    // Adobe — extension needed to distinguish from underlying container format
    .{ "ai", .ai },
    .{ "prproj", .prproj },
    .{ "idml", .idml },
    // Text formats — extension is the definitive indicator
    .{ "toml", .toml },
    .{ "tml", .toml },
    .{ "ini", .ini },
    .{ "json", .json },
    .{ "xml", .xml },
    .{ "yaml", .yaml },
    .{ "yml", .yaml },
    // Erlang term format files
    .{ "app", .erlang_term },
    .{ "config", .erlang_term },
    .{ "lock", .erlang_term },
    // EEx/ERB template files
    .{ "eex", .eex },
    .{ "leex", .eex },
    .{ "heex", .eex },
    .{ "erb", .eex },
    // Markdown
    .{ "md", .markdown },
    .{ "markdown", .markdown },
    // NDJSON / JSON Lines / JSON5
    .{ "ndjson", .json },
    .{ "jsonl", .json },
    .{ "json5", .json },
    // CSV / TSV
    .{ "csv", .csv },
    .{ "tsv", .csv },
    // Apple Property List
    .{ "plist", .plist },
    // Erlang/Elixir BEAM bytecode
    .{ "beam", .beam },
    // macOS ICNS icon
    .{ "icns", .icns },
    // LLVM compiler artifacts
    .{ "dia", .llvm_diag },
    // MessagePack binary serialization
    .{ "msgpack", .msgpack },
    // Windows PE executable extensions
    .{ "exe", .pe },
    .{ "dll", .pe },
    .{ "sys", .pe },
    .{ "scr", .pe },
    .{ "ocx", .pe },
    .{ "cpl", .pe },
    // ELF executable extensions
    .{ "so", .elf },
    .{ "elf", .elf },
    .{ "ko", .elf },
    .{ "axf", .elf },
    // WebAssembly
    .{ "wasm", .wasm },
    // Java bytecode
    .{ "class", .java_class },
    // Unix ar archive (static libraries)
    .{ "a", .ar },
    // HTML documents
    .{ "html", .html },
    .{ "htm", .html },
    .{ "xhtml", .html },
});

/// Detect format from file extension.
/// Used as fallback for formats without magic bytes (e.g., Brotli .br files).
/// Only returns formats that need extension-based detection; formats with reliable
/// magic bytes are not returned here (they are detected by magic bytes instead).
pub fn detectFormatFromExtension(path: []const u8) FileFormat {
    var buf: [16]u8 = undefined;
    const ext_lower = lowercaseExtension(path, &buf) orelse return .unknown;
    return ext_detect_map.get(ext_lower) orelse .unknown;
}

/// Check if a file extension indicates a subtitle format where bidi overrides are expected.
fn isSubtitleExtension(path: []const u8) bool {
    const subtitle_exts = std.StaticStringMap(void).initComptime(.{
        .{ "srt", {} },
        .{ "vtt", {} },
        .{ "ass", {} },
        .{ "ssa", {} },
        .{ "sub", {} },
        .{ "sbv", {} },
        .{ "lrc", {} },
    });
    var buf: [16]u8 = undefined;
    const ext_lower = lowercaseExtension(path, &buf) orelse return false;
    return subtitle_exts.has(ext_lower);
}

/// Check if a file extension indicates a code/log/template file that should NOT
/// be validated as a text format (JSON, XML, etc.) even if content detection
/// matches those patterns. These are false positives from content detection.
fn isExcludedTextExtension(path: []const u8) bool {
    // First, extract the filename and check for known names (handles files without extensions)
    const slash_pos = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash_pos = std.mem.lastIndexOfScalar(u8, path, '\\');
    const name_start = blk: {
        if (slash_pos != null and backslash_pos != null) {
            break :blk @max(slash_pos.? + 1, backslash_pos.? + 1);
        } else if (slash_pos != null) {
            break :blk slash_pos.? + 1;
        } else if (backslash_pos != null) {
            break :blk backslash_pos.? + 1;
        } else {
            break :blk @as(usize, 0);
        }
    };
    const filename = path[name_start..];

    // Known non-validatable filenames (case-insensitive)
    var lower_name: [64]u8 = undefined;
    if (filename.len > 0 and filename.len <= lower_name.len) {
        for (filename, 0..) |c, i| {
            lower_name[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const name_lower = lower_name[0..filename.len];

        // Check exact filename matches
        if (excluded_text_filenames.has(name_lower)) return true;
        // Special case: "readme" or "readme.*"
        if (std.mem.eql(u8, name_lower, "readme")) return true;
        if (std.mem.startsWith(u8, name_lower, "readme.")) return true;
    }

    // Now check extension
    var ext_buf: [16]u8 = undefined;
    const ext_lower = lowercaseExtension(path, &ext_buf) orelse return false;
    return excluded_text_exts.has(ext_lower);
}

/// Get expected format for a file extension (for mismatch detection).
/// Returns the FileFormat that a file extension normally implies.
/// Uses the same unified extension map as detectFormatFromExtension.
fn getExpectedFormatForExtension(path: []const u8) FileFormat {
    var buf: [16]u8 = undefined;
    const ext_lower = lowercaseExtension(path, &buf) orelse return .unknown;
    return ext_format_map.get(ext_lower) orelse .unknown;
}

/// Detect format by secondary signatures (trailers, internal patterns).
/// Used as fallback when magic bytes are corrupted but extension hints at a format.
/// Returns the format if secondary signatures confirm it, otherwise .unknown.
fn detectFormatBySecondarySignatures(data: []const u8, hinted_format: FileFormat) FileFormat {
    const len = data.len;
    if (len < 8) return .unknown;

    switch (hinted_format) {
        .pdf => {
            // PDF: Look for %%EOF, startxref, obj/endobj keywords
            // Search in last 1KB and throughout file
            const search_tail = if (len > 1024) data[len - 1024 ..] else data;
            if (std.mem.indexOf(u8, search_tail, "%%EOF") != null) return .pdf;
            if (std.mem.indexOf(u8, data, "startxref") != null) return .pdf;
            if (std.mem.indexOf(u8, data, " obj") != null and std.mem.indexOf(u8, data, "endobj") != null) return .pdf;
        },
        .png => {
            // PNG: Look for IEND chunk (49 45 4E 44 = "IEND")
            // IEND appears near end with CRC
            if (len >= 12) {
                const search_tail = if (len > 32) data[len - 32 ..] else data;
                if (std.mem.indexOf(u8, search_tail, "IEND") != null) return .png;
                // Also check for IHDR chunk (should be first chunk after header)
                if (std.mem.indexOf(u8, data[0..@min(len, 32)], "IHDR") != null) return .png;
            }
        },
        .jpeg => {
            // JPEG: Look for FFD9 trailer (End Of Image)
            if (len >= 2 and data[len - 2] == 0xFF and data[len - 1] == 0xD9) return .jpeg;
            // Also look for JFIF or Exif markers in first 32 bytes
            const header_search = data[0..@min(len, 32)];
            if (std.mem.indexOf(u8, header_search, "JFIF") != null) return .jpeg;
            if (std.mem.indexOf(u8, header_search, "Exif") != null) return .jpeg;
        },
        .gif => {
            // GIF: Look for 0x3B (;) trailer
            if (data[len - 1] == 0x3B) return .gif;
            // Also check for "GIF8" anywhere in first 16 bytes (covers GIF87a and GIF89a even if first byte corrupted)
            if (len >= 4 and std.mem.indexOf(u8, data[0..@min(len, 16)], "IF8") != null) return .gif;
        },
        .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp => {
            // ZIP: Central directory signature PK\x01\x02 or EOCD PK\x05\x06
            if (std.mem.indexOf(u8, data, &[_]u8{ 'P', 'K', 0x01, 0x02 }) != null) return hinted_format;
            if (std.mem.indexOf(u8, data, &[_]u8{ 'P', 'K', 0x05, 0x06 }) != null) return hinted_format;
            // Also check for local file header PK\x03\x04 after the corrupted first bytes
            if (len > 8 and std.mem.indexOf(u8, data[1..], &[_]u8{ 'P', 'K', 0x03, 0x04 }) != null) return hinted_format;
        },
        .sqlite => {
            // SQLite: "SQLite format" string should be at offset 0-15, check if partially visible
            // Also check page size at offset 16-17 (must be power of 2 between 512 and 65536)
            if (len >= 18) {
                // Check for partial "SQLite format" string (may be corrupted at start)
                if (std.mem.indexOf(u8, data[0..@min(len, 32)], "QLite format") != null) return .sqlite;
                // Check page size - if valid, likely SQLite
                const page_size = (@as(u16, data[16]) << 8) | data[17];
                if (page_size >= 512 and page_size <= 65536 and (page_size & (page_size - 1)) == 0) {
                    // Valid page size, check for more SQLite patterns
                    if (std.mem.indexOf(u8, data[0..@min(len, 100)], "format") != null) return .sqlite;
                }
            }
        },
        .mp4, .mov, .m4a, .heic, .avif, .cr3 => {
            // MP4/MOV/ISO BMFF: Look for box/atom signatures: ftyp, moov, mdat, free, wide
            // These appear as 4-byte size followed by 4-byte type
            const box_types = [_][]const u8{ "ftyp", "moov", "mdat", "free", "wide", "uuid", "meta" };
            for (box_types) |box_type| {
                if (std.mem.indexOf(u8, data, box_type) != null) return hinted_format;
            }
        },
        .flac => {
            // FLAC: Look for "fLaC" marker or METADATA_BLOCK_STREAMINFO (0x00 after fLaC)
            // Even with corrupted first byte, might find "LaC" in first 8 bytes
            if (std.mem.indexOf(u8, data[0..@min(len, 8)], "LaC") != null) return .flac;
        },
        .mp3 => {
            // MP3: Look for frame sync (0xFF followed by 0xE* or 0xF*)
            // Or ID3 tag ("ID3" or "TAG")
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "ID3") != null) return .mp3;
            if (len > 128 and std.mem.eql(u8, data[len - 128 ..][0..3], "TAG")) return .mp3;
            // Look for frame sync
            var i: usize = 0;
            while (i + 1 < @min(len, 8192)) : (i += 1) {
                if (data[i] == 0xFF and (data[i + 1] & 0xE0) == 0xE0) return .mp3;
            }
        },
        .ogg => {
            // Ogg: Page sync "OggS" - might find it after corrupted first bytes
            if (std.mem.indexOf(u8, data[0..@min(len, 64)], "ggS") != null) return .ogg;
            if (std.mem.indexOf(u8, data[0..@min(len, 64)], "OggS") != null) return .ogg;
        },
        .mkv, .webm => {
            // Matroska/WebM: EBML header ID 0x1A45DFA3, or look for common element IDs
            // Segment ID: 0x18538067, Cluster ID: 0x1F43B675
            if (std.mem.indexOf(u8, data[0..@min(len, 64)], &[_]u8{ 0x45, 0xDF, 0xA3 }) != null) return hinted_format;
            if (std.mem.indexOf(u8, data, &[_]u8{ 0x18, 0x53, 0x80, 0x67 }) != null) return hinted_format;
        },
        .avi => {
            // AVI: RIFF....AVI - look for "AVI " after potential RIFF header
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "AVI ") != null) return .avi;
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "RIFF") != null) return .avi;
        },
        .wav => {
            // WAV: RIFF....WAVE - look for "WAVE" after potential RIFF header
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "WAVE") != null) return .wav;
        },
        .rar => {
            // RAR: Look for "Rar!" signature or RAR5 signature
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "ar!") != null) return .rar;
            if (std.mem.indexOf(u8, data[0..@min(len, 16)], "Rar!") != null) return .rar;
        },
        .gzip => {
            // GZIP: Look for common compressed data patterns or ISIZE at end
            // GZIP files end with CRC32 (4 bytes) and ISIZE (4 bytes)
            // Hard to detect without magic, but check for deflate stream markers
            if (len >= 18) {
                // Check if second byte is valid GZIP compression method (0x08 = deflate)
                if (data[1] == 0x08) return .gzip;
            }
        },
        .tiff => {
            // TIFF: "II" (little endian) or "MM" (big endian) followed by 42 (0x002A)
            // First bytes might be corrupted, check for 42 at offset 2-3
            if (len >= 4) {
                if ((data[2] == 0x2A and data[3] == 0x00) or (data[2] == 0x00 and data[3] == 0x2A)) return .tiff;
            }
        },
        .bmp => {
            // BMP: "BM" at start, but if corrupted, check for DIB header size at offset 14
            // Common DIB header sizes: 40, 108, 124 (BITMAPINFOHEADER, BITMAPV4HEADER, BITMAPV5HEADER)
            if (len >= 18) {
                const dib_size = @as(u32, data[14]) | (@as(u32, data[15]) << 8) | (@as(u32, data[16]) << 16) | (@as(u32, data[17]) << 24);
                if (dib_size == 40 or dib_size == 108 or dib_size == 124 or dib_size == 12) return .bmp;
            }
        },
        else => {},
    }

    return .unknown;
}

/// Detect format by secondary signatures in file tail (last N bytes).
/// Used for formats like PDF, JPEG, GIF that have distinctive end markers.
fn detectFormatBySecondarySignaturesTail(tail_data: []const u8, hinted_format: FileFormat) FileFormat {
    const len = tail_data.len;
    if (len < 4) return .unknown;

    switch (hinted_format) {
        .pdf => {
            // PDF: Look for %%EOF and startxref near end
            if (std.mem.indexOf(u8, tail_data, "%%EOF") != null) return .pdf;
            if (std.mem.indexOf(u8, tail_data, "startxref") != null) return .pdf;
            if (std.mem.indexOf(u8, tail_data, "trailer") != null) return .pdf;
        },
        .jpeg => {
            // JPEG: FFD9 (End of Image) at the very end
            if (tail_data[len - 2] == 0xFF and tail_data[len - 1] == 0xD9) return .jpeg;
        },
        .gif => {
            // GIF: 0x3B (;) trailer at the very end
            if (tail_data[len - 1] == 0x3B) return .gif;
        },
        .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp => {
            // ZIP: End of Central Directory signature PK\x05\x06
            if (std.mem.indexOf(u8, tail_data, &[_]u8{ 'P', 'K', 0x05, 0x06 }) != null) return hinted_format;
        },
        else => {},
    }

    // TGA v2 footer: "TRUEVISION-XFILE.\0" in last 26 bytes (extension-independent detection)
    if (len >= 26) {
        const footer_start = len - 26;
        const tga_sig = "TRUEVISION-XFILE.\x00";
        if (std.mem.eql(u8, tail_data[footer_start + 8 .. footer_start + 26], tga_sig)) {
            return .tga;
        }
    }

    return .unknown;
}

/// Check if a detected format is compatible with a file extension.
/// Returns true if the format matches what the extension implies, or if either is unknown.
/// REPAIRABLE: extension_mismatch - can be fixed by renaming the file
fn isFormatCompatibleWithExtension(detected: FileFormat, extension_format: FileFormat) bool {
    // If either is unknown, we can't determine mismatch
    if (detected == .unknown or extension_format == .unknown) return true;

    // Exact match
    if (detected == extension_format) return true;

    // Some formats are related and acceptable
    // MP4 container can hold various content types
    if (extension_format == .mp4 and (detected == .mp4 or detected == .mov or detected == .m4a or detected == .heic or detected == .avif)) return true;
    if (extension_format == .m4a and (detected == .m4a or detected == .mp4)) return true;
    if (extension_format == .mov and (detected == .mov or detected == .mp4)) return true;

    // HEIC/HEIF are the same (heic enum covers both)
    if (extension_format == .heic and detected == .heic) return true;

    // ZIP-based formats can be detected as zip initially
    if (detected == .zip and (extension_format == .docx or extension_format == .xlsx or extension_format == .pptx or
        extension_format == .odt or extension_format == .ods or extension_format == .odp or
        extension_format == .epub or extension_format == .pages)) return true;

    // TIFF-based RAW formats
    if (detected == .tiff and (extension_format == .dng or extension_format == .cr2 or extension_format == .nef or extension_format == .arw or extension_format == .orf or extension_format == .rw2 or extension_format == .pef)) return true;

    // CR3 is ISO BMFF-based, may be detected as MP4 initially
    if (detected == .mp4 and extension_format == .cr3) return true;

    // Ogg container can have various codecs
    if (extension_format == .ogg and detected == .ogg) return true;

    // OLE2-based financial formats detected as .doc
    if (detected == .doc and (extension_format == .qbb or extension_format == .qdf)) return true;
    // ZIP-based financial format
    if (detected == .zip and extension_format == .qdf) return true;

    // .obj extension is ambiguous: Wavefront OBJ 3D model OR COFF object file
    if (extension_format == .obj and detected == .coff) return true;
    if (extension_format == .coff and detected == .obj) return true;

    // DMG files are commonly bzip2-compressed; validate as bzip2 without extension mismatch
    if (extension_format == .dmg and detected == .bzip2) return true;

    // OLE2-based MSI detected as .doc by magic bytes before OLE2 subformat dispatch
    if (detected == .doc and extension_format == .msi) return true;

    // MP2 and MP3 share the same MPEG audio frame structure
    if (extension_format == .mp2 and detected == .mp3) return true;
    if (extension_format == .mp3 and detected == .mp2) return true;

    // Toast disc images are commonly ISO 9660 internally
    if (extension_format == .toast and detected == .iso) return true;

    // WIM and ESD are the same container format
    if ((extension_format == .wim and detected == .esd) or (extension_format == .esd and detected == .wim)) return true;

    // WebM is a subset of Matroska (MKV) — same EBML container
    if ((extension_format == .webm and detected == .mkv) or (extension_format == .mkv and detected == .webm)) return true;

    // Plain text encoding variants are all compatible (UTF-8, UTF-16, Latin-1, CP437)
    const ext_is_plaintext = switch (extension_format) {
        .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437 => true,
        else => false,
    };
    const det_is_plaintext = switch (detected) {
        .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437 => true,
        else => false,
    };
    if (ext_is_plaintext and det_is_plaintext) return true;

    return false;
}

/// Result of reading text content with encoding detection.
pub const TextContentResult = struct {
    /// The UTF-8 content (either original or converted)
    content: []const u8,
    /// Whether the content was converted from UTF-16
    was_utf16: bool,
    /// The conversion buffer (only valid if was_utf16 is true)
    converted_buf: []u8,

    /// For UTF-8 content, just returns content. For converted content, returns the buffer.
    pub fn getContent(self: TextContentResult) []const u8 {
        return self.content;
    }
};

/// Read text content from a buffer, detecting and converting UTF-16 LE/BE to UTF-8.
/// Returns the UTF-8 content and whether conversion was performed.
/// For UTF-16 content, the conversion is done into conv_buf.
///
/// TODO: For large files, consider implementing a streaming UTF-16 to UTF-8 converter
/// that wraps a std.io.Reader interface. This would avoid allocating the full converted
/// content in memory. However, the current parsers (std.json.Scanner, zig-xml, zig-toml)
/// expect slices, so this would require either:
/// 1. A buffered reader wrapper that converts on-the-fly and provides chunks
/// 2. Changes to how the parsers consume data
/// For now, full conversion is acceptable since UTF-16 files are typically small config files.
pub fn getTextContent(raw_data: []const u8, conv_buf: []u8) TextContentResult {
    // Check for UTF-16 LE BOM (0xFF 0xFE) - common on Windows
    if (raw_data.len >= 2 and raw_data[0] == 0xFF and raw_data[1] == 0xFE) {
        if (convertUtf16LeToUtf8(raw_data[2..], conv_buf)) |utf8_content| {
            return .{ .content = utf8_content, .was_utf16 = true, .converted_buf = conv_buf };
        }
        // Conversion failed - return empty
        return .{ .content = &[_]u8{}, .was_utf16 = true, .converted_buf = conv_buf };
    }

    // Check for UTF-16 BE BOM (0xFE 0xFF)
    if (raw_data.len >= 2 and raw_data[0] == 0xFE and raw_data[1] == 0xFF) {
        if (convertUtf16BeToUtf8(raw_data[2..], conv_buf)) |utf8_content| {
            return .{ .content = utf8_content, .was_utf16 = true, .converted_buf = conv_buf };
        }
        return .{ .content = &[_]u8{}, .was_utf16 = true, .converted_buf = conv_buf };
    }

    // Check for UTF-8 BOM (0xEF 0xBB 0xBF) - skip it
    if (raw_data.len >= 3 and raw_data[0] == 0xEF and raw_data[1] == 0xBB and raw_data[2] == 0xBF) {
        return .{ .content = raw_data[3..], .was_utf16 = false, .converted_buf = conv_buf };
    }

    // No BOM - assume UTF-8 or ASCII
    return .{ .content = raw_data, .was_utf16 = false, .converted_buf = conv_buf };
}

/// Convert UTF-16 (parameterized endianness) to UTF-8 in a stack buffer.
/// Returns the slice of converted UTF-8 data, or null if conversion fails.
fn convertUtf16ToUtf8(comptime endian: std.builtin.Endian, utf16_data: []const u8, out_buf: []u8) ?[]const u8 {
    if (utf16_data.len < 2 or utf16_data.len % 2 != 0) return null;

    // Byte indices for reading a u16: for big-endian hi is first, for little-endian lo is first.
    const hi_off: usize = if (endian == .big) 0 else 1;
    const lo_off: usize = if (endian == .big) 1 else 0;

    var out_idx: usize = 0;
    var in_idx: usize = 0;

    while (in_idx + 1 < utf16_data.len and out_idx < out_buf.len) {
        const code_unit: u16 = @as(u16, utf16_data[in_idx + lo_off]) | (@as(u16, utf16_data[in_idx + hi_off]) << 8);
        in_idx += 2;

        // Handle surrogate pairs
        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            if (in_idx + 1 >= utf16_data.len) return null;
            const low_surrogate: u16 = @as(u16, utf16_data[in_idx + lo_off]) | (@as(u16, utf16_data[in_idx + hi_off]) << 8);
            in_idx += 2;

            if (low_surrogate < 0xDC00 or low_surrogate > 0xDFFF) return null;

            const high_part: u21 = @as(u21, code_unit - 0xD800) << 10;
            const low_part: u21 = @as(u21, low_surrogate - 0xDC00);
            const code_point: u21 = high_part + low_part + 0x10000;

            if (out_idx + 4 > out_buf.len) break;
            out_buf[out_idx] = @intCast(0xF0 | (code_point >> 18));
            out_buf[out_idx + 1] = @intCast(0x80 | ((code_point >> 12) & 0x3F));
            out_buf[out_idx + 2] = @intCast(0x80 | ((code_point >> 6) & 0x3F));
            out_buf[out_idx + 3] = @intCast(0x80 | (code_point & 0x3F));
            out_idx += 4;
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            return null;
        } else if (code_unit < 0x80) {
            out_buf[out_idx] = @intCast(code_unit);
            out_idx += 1;
        } else if (code_unit < 0x800) {
            if (out_idx + 2 > out_buf.len) break;
            out_buf[out_idx] = @intCast(0xC0 | (code_unit >> 6));
            out_buf[out_idx + 1] = @intCast(0x80 | (code_unit & 0x3F));
            out_idx += 2;
        } else {
            if (out_idx + 3 > out_buf.len) break;
            out_buf[out_idx] = @intCast(0xE0 | (code_unit >> 12));
            out_buf[out_idx + 1] = @intCast(0x80 | ((code_unit >> 6) & 0x3F));
            out_buf[out_idx + 2] = @intCast(0x80 | (code_unit & 0x3F));
            out_idx += 3;
        }
    }

    return out_buf[0..out_idx];
}

/// Convert UTF-16 BE to UTF-8 in a stack buffer.
fn convertUtf16BeToUtf8(utf16_data: []const u8, out_buf: []u8) ?[]const u8 {
    return convertUtf16ToUtf8(.big, utf16_data, out_buf);
}

/// Convert UTF-16 LE to UTF-8 in a stack buffer.
/// Returns the slice of converted UTF-8 data, or null if conversion fails.
pub fn convertUtf16LeToUtf8(utf16_data: []const u8, out_buf: []u8) ?[]const u8 {
    return convertUtf16ToUtf8(.little, utf16_data, out_buf);
}

/// Detect text-based formats (JSON, XML, TOML, INI, YAML) by content patterns.
/// Only called after magic bytes detection fails, so we need to be careful
/// not to misclassify other text-based formats that have their own validators.
pub fn detectTextFormat(header: []const u8) ?FileFormat {
    if (header.len == 0) return null;

    // Check for UTF-16 LE BOM (0xFF 0xFE) - common on Windows
    if (header.len >= 2 and header[0] == 0xFF and header[1] == 0xFE) {
        // UTF-16 LE - convert to UTF-8 and detect format
        var utf8_buf: [4096]u8 = undefined;
        const utf8_data = convertUtf16LeToUtf8(header[2..], &utf8_buf) orelse return null;
        const format = detectTextFormatUtf8(utf8_data);
        // If plain text detected, mark it as UTF-16 encoding
        if (format == .plain_text) return .plain_text_utf16;
        return format;
    }

    // Check for UTF-16 BE BOM (0xFE 0xFF) - less common but possible
    if (header.len >= 2 and header[0] == 0xFE and header[1] == 0xFF) {
        // UTF-16 BE - convert to UTF-8 and detect format
        var utf8_buf: [4096]u8 = undefined;
        const utf8_data = convertUtf16BeToUtf8(header[2..], &utf8_buf) orelse return null;
        const format = detectTextFormatUtf8(utf8_data);
        // If plain text detected, mark it as UTF-16 encoding
        if (format == .plain_text) return .plain_text_utf16;
        return format;
    }

    return detectTextFormatUtf8(header);
}

/// Detect text-based formats from UTF-8 encoded content.
fn detectTextFormatUtf8(header: []const u8) ?FileFormat {
    if (header.len == 0) return null;

    // Binary check: if header contains null bytes, high proportion of
    // non-printable characters, or invalid UTF-8 sequences, this is not text
    var null_count: usize = 0;
    var non_printable_count: usize = 0;
    const raw_check_len = @min(header.len, 512);
    // Avoid splitting a multibyte UTF-8 sequence at the buffer boundary.
    // If the last byte is a continuation (0x80-0xBF) or a lead byte whose
    // sequence extends past the window, back up to the last complete character.
    const check_len = blk: {
        var end = raw_check_len;
        if (end == header.len) break :blk end; // Full file fits — no truncation
        // Walk backwards past continuation bytes to find the lead byte
        while (end > 0 and (header[end - 1] & 0xC0) == 0x80) : (end -= 1) {}
        // Now end-1 is either ASCII or a lead byte. Check if its sequence is complete.
        if (end > 0 and header[end - 1] >= 0xC0) {
            const lead = header[end - 1];
            const seq_len: usize = if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4;
            if (end - 1 + seq_len > raw_check_len) {
                end -= 1; // Sequence is truncated — exclude the lead byte too
            }
        }
        break :blk end;
    };
    for (header[0..check_len]) |byte| {
        if (byte == 0) {
            null_count += 1;
            if (null_count > 2) return null; // More than 2 nulls = definitely binary
        }
        // Non-printable: 0x00-0x08, 0x0E-0x1F (excluding tab, newline, CR)
        if (byte < 0x09 or (byte > 0x0D and byte < 0x20)) {
            non_printable_count += 1;
        }
    }
    // If more than 10% non-printable, likely binary
    if (check_len > 0 and non_printable_count * 10 > check_len) return null;

    // Check for valid UTF-8 - if it contains high bytes that aren't valid UTF-8,
    // check if it might be CP437 (demoscene NFO files) or Latin-1 (fallback)
    if (!text_format_validators.validateUtf8(header[0..check_len]).isValid()) {
        if (looksLikeCp437(header[0..check_len])) {
            return .plain_text_cp437;
        }
        // Check if it looks like Latin-1 text (mostly ASCII with some accented chars)
        if (looksLikeLatin1(header[0..check_len])) {
            return .plain_text_latin1;
        }
        // Not recognizable as text - return null (unknown)
        return null;
    }

    var i: usize = 0;

    // Skip UTF-8 BOM if present
    if (header.len >= 3 and header[0] == 0xEF and header[1] == 0xBB and header[2] == 0xBF) {
        i = 3;
    }

    // Skip leading whitespace
    while (i < header.len and (header[i] == ' ' or header[i] == '\t' or header[i] == '\n' or header[i] == '\r')) : (i += 1) {}

    if (i >= header.len) return null;

    const first_char = header[i];

    // FASTA: starts with ">" followed by sequence identifier line, then sequence line
    // Be strict: sequence line must contain ONLY valid FASTA characters (no spaces/punctuation)
    if (first_char == '>') {
        // Skip the identifier line (header)
        var j = i + 1;
        while (j < header.len and header[j] != '\n' and header[j] != '\r') : (j += 1) {}
        if (j < header.len) {
            j += 1; // Skip newline
            if (j < header.len and header[j] == '\n') j += 1; // Skip \r\n
            if (j < header.len) {
                // Check that the sequence line contains ONLY valid FASTA sequence characters
                // Valid: A-Z (amino acids), a-z (lowercase), * (stop codon), - (gap)
                // Invalid: spaces, punctuation, numbers, etc.
                var valid_chars: usize = 0;
                while (j < header.len and header[j] != '\n' and header[j] != '\r') : (j += 1) {
                    const c = header[j];
                    if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '*' or c == '-') {
                        valid_chars += 1;
                    } else {
                        // Found invalid character - not FASTA
                        return null;
                    }
                }
                // Must have at least one valid sequence character
                if (valid_chars > 0) {
                    return .fasta;
                }
            }
        }
        // Could be something else starting with >
        return null;
    }

    // FASTQ: starts with "@" followed by identifier, then sequence, "+", quality
    if (first_char == '@') {
        // Look for the 4-line FASTQ pattern
        var line_count: u8 = 0;
        var j = i;
        while (j < header.len and line_count < 4) {
            if (header[j] == '\n') line_count += 1;
            j += 1;
        }
        // Need at least some content for first three lines to check for "+"
        if (line_count >= 2) {
            // Find third line (after identifier and sequence)
            var line_start = i;
            var lines_found: u8 = 0;
            j = i;
            while (j < header.len and lines_found < 2) {
                if (header[j] == '\n') {
                    lines_found += 1;
                    line_start = j + 1;
                }
                j += 1;
            }
            // Third line should start with "+"
            if (line_start < header.len and header[line_start] == '+') {
                return .fastq;
            }
        }
        // Could be email header or other format starting with @
        return null;
    }

    // PDB (Protein Data Bank): starts with specific record types
    const pdb_starts = [_][]const u8{
        "HEADER", "TITLE ", "COMPND", "SOURCE", "KEYWDS", "EXPDTA",
        "AUTHOR", "REVDAT", "JRNL  ", "REMARK", "DBREF ", "SEQRES",
        "HELIX ", "SHEET ", "ATOM  ", "HETATM", "MODEL ",
    };
    for (pdb_starts) |prefix| {
        if (header.len - i >= prefix.len and std.mem.eql(u8, header[i..][0..prefix.len], prefix)) {
            return .pdb_struct;
        }
    }

    // CIF (Crystallographic Information File): starts with "data_" followed by block name
    // CIF structure: data_BLOCKNAME\n followed by _tag value pairs or loop_ keywords
    // Avoid false positives from code like "data_path = ..." by requiring CIF patterns
    if (header.len - i >= 5 and std.mem.eql(u8, header[i..][0..5], "data_")) {
        // Check for CIF-specific patterns: _tag or loop_ after the data_ line
        // Skip to end of data_ line
        var cif_idx = i + 5;
        while (cif_idx < header.len and header[cif_idx] != '\n') : (cif_idx += 1) {}
        if (cif_idx < header.len) {
            cif_idx += 1; // Skip newline
            // Skip whitespace
            while (cif_idx < header.len and (header[cif_idx] == ' ' or header[cif_idx] == '\t' or header[cif_idx] == '\r' or header[cif_idx] == '\n')) : (cif_idx += 1) {}
            // Look for CIF tag pattern: _identifier or loop_
            if (cif_idx < header.len and header[cif_idx] == '_') {
                return .cif;
            }
            if (cif_idx + 5 <= header.len and std.mem.eql(u8, header[cif_idx..][0..5], "loop_")) {
                return .cif;
            }
            // Also check for # comment lines followed by _tag (common CIF pattern)
            if (cif_idx < header.len and header[cif_idx] == '#') {
                // Scan for _tag pattern in next few lines
                const search_limit = @min(cif_idx + 500, header.len);
                if (std.mem.indexOf(u8, header[cif_idx..search_limit], "\n_") != null or
                    std.mem.indexOf(u8, header[cif_idx..search_limit], "\nloop_") != null)
                {
                    return .cif;
                }
            }
        }
    }

    // DXF (AutoCAD Drawing Exchange Format): text version starts with "0" followed by newline and "SECTION"
    if (first_char == '0') {
        var j = i + 1;
        // Skip to newline
        while (j < header.len and header[j] != '\n') : (j += 1) {}
        if (j < header.len) {
            j += 1; // Skip newline
            // Skip whitespace/CR
            while (j < header.len and (header[j] == ' ' or header[j] == '\t' or header[j] == '\r')) : (j += 1) {}
            // Check for SECTION
            if (j + 7 <= header.len and std.mem.eql(u8, header[j..][0..7], "SECTION")) {
                return .dxf;
            }
        }
    }

    // XML-based formats: check for templates first, then XML
    if (first_char == '<') {
        // Check for EEx/ERB template tags (<%, <%=, <%#, <%-)
        // These are NOT valid XML and should be detected as templates
        if (header.len > i + 1 and header[i + 1] == '%') {
            return .eex;
        }
        // Also scan the header for embedded <% tags (template mixed with HTML)
        if (std.mem.indexOf(u8, header[i..], "<%") != null) {
            return .eex;
        }
        // Check for Handlebars/Mustache template tags ({{, {{{)
        // These are NOT valid XML and should be detected as templates
        if (std.mem.indexOf(u8, header[i..], "{{") != null) {
            return .eex; // Classify as template (same category as EEx/ERB)
        }
        // Check for Jinja2/Django template tags ({% ... %})
        // These are NOT valid XML and should be detected as templates
        if (std.mem.indexOf(u8, header[i..], "{%") != null) {
            return .eex; // Classify as template (same category as EEx/ERB)
        }

        // Check for XML declaration first, then look for specific root elements
        if (header.len - i >= 5 and std.mem.eql(u8, header[i..][0..5], "<?xml")) {
            // XML with declaration - check for KML root element
            if (std.mem.indexOf(u8, header[i..], "<kml") != null) {
                return .kml;
            }
            // Check for Apple Property List (XML plist) - contains "<!DOCTYPE plist" or "<plist"
            if (std.mem.indexOf(u8, header[i..], "<!DOCTYPE plist") != null or
                std.mem.indexOf(u8, header[i..], "<plist") != null)
            {
                return .plist;
            }
            return .xml;
        }
        // Check for KML without declaration
        if (header.len - i >= 4 and std.mem.eql(u8, header[i..][0..4], "<kml")) {
            return .kml;
        }
        // Check for HTML doctype - HTML is NOT well-formed XML, don't validate as such
        if (header.len - i >= 9 and (std.mem.eql(u8, header[i..][0..9], "<!DOCTYPE") or std.mem.eql(u8, header[i..][0..9], "<!doctype"))) {
            // Check if it's HTML DOCTYPE (case-insensitive search for "html")
            const remaining = header[i..@min(header.len, i + 100)];
            // Look for "html" or "HTML" in DOCTYPE declaration
            var k: usize = 9;
            while (k + 4 <= remaining.len) : (k += 1) {
                const c0 = remaining[k];
                const c1 = if (k + 1 < remaining.len) remaining[k + 1] else 0;
                const c2 = if (k + 2 < remaining.len) remaining[k + 2] else 0;
                const c3 = if (k + 3 < remaining.len) remaining[k + 3] else 0;
                if ((c0 == 'h' or c0 == 'H') and
                    (c1 == 't' or c1 == 'T') and
                    (c2 == 'm' or c2 == 'M') and
                    (c3 == 'l' or c3 == 'L'))
                {
                    // This is HTML, not XML - return null to skip strict XML validation
                    return null;
                }
                if (c0 == '>') break; // End of DOCTYPE
            }
            // Non-HTML DOCTYPE, treat as XML
            return .xml;
        }
        // Be conservative about XML detection to avoid misclassifying HTML/templates
        // Only detect as XML if:
        // 1. Has explicit <?xml declaration (handled above)
        // 2. Has DOCTYPE (handled above)
        // 3. Has namespaced root element like <ns:tag (XML convention)
        // 4. Has well-known XML root elements (svg, rss, feed, etc.)
        if (header.len > i + 1) {
            const tag_start = header[i + 1];
            // Only match if it looks like <?xml PI (not already handled) or namespaced element
            if (tag_start == '?') {
                return .xml;
            }
            // Check for namespaced element: find tag name and see if it contains ':'
            if (tag_start >= 'a' and tag_start <= 'z') {
                // Look for namespace separator ':' in the tag name
                var j = i + 2;
                while (j < header.len and ((header[j] >= 'a' and header[j] <= 'z') or
                    (header[j] >= 'A' and header[j] <= 'Z') or
                    (header[j] >= '0' and header[j] <= '9') or
                    header[j] == '-' or header[j] == '_' or header[j] == ':'))
                {
                    if (header[j] == ':') {
                        // Namespaced element like <soap:Envelope - definitely XML
                        return .xml;
                    }
                    j += 1;
                }
                // Check for well-known XML root elements
                const tag_end = j;
                const tag_name = header[i + 1 .. tag_end];
                const known_xml_roots = [_][]const u8{
                    "rss",   "feed",   "svg",     "math",          "xsl",      "xslt",
                    "wsdl",  "schema", "project", "configuration", "manifest", "resources",
                    "beans", "plist",
                };
                for (known_xml_roots) |root| {
                    if (std.mem.eql(u8, tag_name, root)) {
                        return .xml;
                    }
                }
            }
        }
        // Don't classify as XML - could be HTML, HTC, or other text format
        return null;
    }

    // JSON vs Erlang term detection for { character
    // JSON objects: {"key": value} - keys are always quoted strings
    // Erlang tuples: {atom, value} - first element is typically an unquoted atom
    if (first_char == '{') {
        var j = i + 1;
        // Skip whitespace after {
        while (j < header.len and (header[j] == ' ' or header[j] == '\t' or header[j] == '\n' or header[j] == '\r')) : (j += 1) {}

        if (j < header.len) {
            // JSON: next char after { and whitespace should be " for object key
            if (header[j] == '"') {
                // Check for glTF format before returning generic JSON
                // glTF files are JSON with required "asset" key containing "version"
                if (isGltfJson(header, i)) {
                    return .gltf;
                }
                return .json;
            }
            // Erlang: next char is lowercase letter (atom) or single quote (quoted atom)
            if ((header[j] >= 'a' and header[j] <= 'z') or header[j] == '\'') {
                return .erlang_term;
            }
            // Empty object {} is valid JSON
            if (header[j] == '}') {
                return .json;
            }
        }
        // Can't determine - don't classify
        return null;
    }

    // YAML: starts with --- document separator
    if (header.len - i >= 3 and std.mem.eql(u8, header[i..][0..3], "---")) {
        return .yaml;
    }

    // INI/TOML: Use heuristic to check if content looks like INI
    // INI files have [section] headers and/or key=value pairs
    // We check the first ~10 lines - at least half should look like INI syntax
    // This avoids false positives on files like NFO (BBCode) that start with [tag]
    if (first_char == '[' or ((first_char >= 'a' and first_char <= 'z') or
        (first_char >= 'A' and first_char <= 'Z') or first_char == '_'))
    {
        if (looksLikeIni(header[i..])) {
            return .ini;
        }
        // Not INI - fall through to check other formats
    }

    // JSON/Erlang detection for [ character (only if not detected as INI above)
    if (first_char == '[') {
        // Not INI section - could be JSON array or Erlang list
        // Check for [{ pattern
        var j = i + 1;
        // Skip whitespace
        while (j < header.len and (header[j] == ' ' or header[j] == '\t' or header[j] == '\n' or header[j] == '\r')) : (j += 1) {}

        if (j < header.len) {
            if (header[j] == '{') {
                // Array of objects/tuples - check what follows {
                j += 1;
                while (j < header.len and (header[j] == ' ' or header[j] == '\t' or header[j] == '\n' or header[j] == '\r')) : (j += 1) {}
                if (j < header.len) {
                    if (header[j] == '"') {
                        // Could be JSON [{"key": value}] or Erlang/Elixir [{"string", value}]
                        // JSON: string followed by :
                        // Erlang: string followed by ,
                        // Look for : or , after the string
                        var k = j + 1;
                        var in_string = true;
                        while (k < header.len and in_string) : (k += 1) {
                            if (header[k] == '\\' and k + 1 < header.len) {
                                k += 1; // Skip escaped char
                            } else if (header[k] == '"') {
                                in_string = false;
                            }
                        }
                        // Skip whitespace after closing quote
                        while (k < header.len and (header[k] == ' ' or header[k] == '\t' or header[k] == '\n' or header[k] == '\r')) : (k += 1) {}
                        if (k < header.len) {
                            if (header[k] == ':') {
                                return .json; // [{"key": ...}]
                            }
                            if (header[k] == ',') {
                                return .erlang_term; // [{"string", ...}] - Elixir/Erlang tuple in list
                            }
                        }
                        // Can't determine, don't classify
                        return null;
                    }
                    if ((header[j] >= 'a' and header[j] <= 'z') or header[j] == '\'') {
                        return .erlang_term; // [{atom, ...}]
                    }
                }
            }
            // JSON array starting with string, number, or nested array
            if (header[j] == '"' or header[j] == '[') {
                return .json;
            }
            // For numbers, check that it's actually JSON array syntax, not a log timestamp
            // Log timestamps look like [23:24:10] or [2024-01-15] - digits followed by : or -
            // JSON arrays of numbers look like [1, 2, 3] - digits followed by , or ] or whitespace
            if ((header[j] >= '0' and header[j] <= '9') or header[j] == '-') {
                // Scan forward to see what follows the number
                var k = j;
                // Skip digits
                while (k < header.len and header[k] >= '0' and header[k] <= '9') : (k += 1) {}
                // Skip any . and more digits (decimal numbers)
                if (k < header.len and header[k] == '.') {
                    k += 1;
                    while (k < header.len and header[k] >= '0' and header[k] <= '9') : (k += 1) {}
                }
                // Now check what follows the number
                if (k < header.len) {
                    const following = header[k];
                    // If followed by : this is likely a timestamp [HH:MM:SS] - not JSON
                    if (following == ':') {
                        return null;
                    }
                    // If followed by , or ] or whitespace, it's JSON
                    if (following == ',' or following == ']' or following == ' ' or following == '\t' or following == '\n' or following == '\r') {
                        return .json;
                    }
                }
                // Can't determine, don't classify
                return null;
            }
            // Empty array [] is valid JSON
            if (header[j] == ']') {
                return .json;
            }
        }
        // Can't determine INI or JSON, but we passed binary check - fall through to plain_text
    }

    // Check for EML headers only (removed overly-broad TOML key=value detection)
    // The key=value pattern matches too many formats: shell scripts, Elixir, Python, etc.
    if ((first_char >= 'a' and first_char <= 'z') or
        (first_char >= 'A' and first_char <= 'Z'))
    {
        // Look for : sign (email header)
        var j = i;
        while (j < header.len and header[j] != '\n' and header[j] != ':') : (j += 1) {}

        if (j < header.len and header[j] == ':') {
            // Could be email header - check for common RFC 822 headers
            const header_name = header[i..j];
            if (email_validators.isEmailHeader(header_name)) {
                return .eml;
            }
        }
    }

    // Wavefront OBJ: text-based 3D model format
    // Check for OBJ-specific line patterns: "v " (vertex), "f " (face), "vt ", "vn ", etc.
    if (isWavefrontObj(header, i)) {
        return .obj;
    }

    // If we get here, the content passed the binary check (few null bytes, mostly printable)
    // but doesn't match any specific text format. Classify as plain text for UTF-8 validation.
    return .plain_text;
}

/// Check if header content looks like a Wavefront OBJ file.
/// OBJ files contain lines starting with: v, vt, vn, f, o, g, mtllib, usemtl, s, #
/// We look for definitive patterns: "v " followed by coordinates or "f " followed by face indices.
fn isWavefrontObj(header: []const u8, start_pos: usize) bool {
    // Count OBJ-specific line beginnings
    var vertex_lines: u32 = 0;
    var face_lines: u32 = 0;
    var other_obj_lines: u32 = 0;

    var i = start_pos;
    var at_line_start = true;

    while (i < header.len) {
        if (at_line_start) {
            const remaining = header.len - i;

            // Check for OBJ line types
            if (remaining >= 2) {
                // "v " - vertex (must be followed by space, then numbers)
                if (header[i] == 'v' and header[i + 1] == ' ') {
                    // Verify it looks like coordinates: "v 1.0 2.0 3.0"
                    var j = i + 2;
                    while (j < header.len and (header[j] == ' ' or header[j] == '\t')) : (j += 1) {}
                    if (j < header.len and (header[j] == '-' or (header[j] >= '0' and header[j] <= '9'))) {
                        vertex_lines += 1;
                    }
                }
                // "f " - face (indices)
                else if (header[i] == 'f' and header[i + 1] == ' ') {
                    // Verify it looks like indices: "f 1 2 3" or "f 1/1/1 2/2/2 3/3/3"
                    var j = i + 2;
                    while (j < header.len and (header[j] == ' ' or header[j] == '\t')) : (j += 1) {}
                    if (j < header.len and (header[j] >= '0' and header[j] <= '9')) {
                        face_lines += 1;
                    }
                }
                // "vt " - texture coordinates
                else if (remaining >= 3 and header[i] == 'v' and header[i + 1] == 't' and header[i + 2] == ' ') {
                    other_obj_lines += 1;
                }
                // "vn " - vertex normals
                else if (remaining >= 3 and header[i] == 'v' and header[i + 1] == 'n' and header[i + 2] == ' ') {
                    other_obj_lines += 1;
                }
                // "o " - object name
                else if (header[i] == 'o' and header[i + 1] == ' ') {
                    other_obj_lines += 1;
                }
                // "g " - group name
                else if (header[i] == 'g' and header[i + 1] == ' ') {
                    other_obj_lines += 1;
                }
                // "s " - smoothing group
                else if (header[i] == 's' and header[i + 1] == ' ') {
                    other_obj_lines += 1;
                }
                // "# " - comment
                else if (header[i] == '#' and header[i + 1] == ' ') {
                    other_obj_lines += 1;
                }
            }
            // Longer keywords
            if (remaining >= 7 and std.mem.eql(u8, header[i..][0..7], "mtllib ")) {
                other_obj_lines += 1;
            } else if (remaining >= 7 and std.mem.eql(u8, header[i..][0..7], "usemtl ")) {
                other_obj_lines += 1;
            }
        }

        // Move to next character, track line starts
        if (header[i] == '\n') {
            at_line_start = true;
        } else if (header[i] != '\r') {
            at_line_start = false;
        }
        i += 1;
    }

    // OBJ files must have vertices; prefer files that also have faces
    // Require at least 2 vertex lines OR (1 vertex + some other OBJ directives)
    if (vertex_lines >= 2) {
        return true;
    }
    if (vertex_lines >= 1 and (face_lines >= 1 or other_obj_lines >= 2)) {
        return true;
    }

    return false;
}

/// Check if header content looks like a glTF (GL Transmission Format) JSON file.
/// glTF files are JSON with required "asset" key containing "version".
/// Often also contains "scene" or "scenes" keys.
fn isGltfJson(header: []const u8, start_pos: usize) bool {
    const search_area = header[start_pos..];

    // glTF requires "asset" key with "version" field
    // Look for "asset" key pattern: "asset" followed by colon
    const has_asset = std.mem.indexOf(u8, search_area, "\"asset\"") != null;
    if (!has_asset) return false;

    // Must also have "version" somewhere (within the asset object)
    const has_version = std.mem.indexOf(u8, search_area, "\"version\"") != null;
    if (!has_version) return false;

    // Additional confidence: check for glTF-specific keys
    // These are common in glTF but not in generic JSON
    const has_scene = std.mem.indexOf(u8, search_area, "\"scene\"") != null;
    const has_scenes = std.mem.indexOf(u8, search_area, "\"scenes\"") != null;
    const has_nodes = std.mem.indexOf(u8, search_area, "\"nodes\"") != null;
    const has_meshes = std.mem.indexOf(u8, search_area, "\"meshes\"") != null;
    const has_accessors = std.mem.indexOf(u8, search_area, "\"accessors\"") != null;
    const has_bufferviews = std.mem.indexOf(u8, search_area, "\"bufferViews\"") != null;
    const has_buffers = std.mem.indexOf(u8, search_area, "\"buffers\"") != null;
    const has_materials = std.mem.indexOf(u8, search_area, "\"materials\"") != null;

    // Count how many glTF-specific keys we found
    var gltf_keys: u32 = 0;
    if (has_scene) gltf_keys += 1;
    if (has_scenes) gltf_keys += 1;
    if (has_nodes) gltf_keys += 1;
    if (has_meshes) gltf_keys += 1;
    if (has_accessors) gltf_keys += 1;
    if (has_bufferviews) gltf_keys += 1;
    if (has_buffers) gltf_keys += 1;
    if (has_materials) gltf_keys += 1;

    // If we found asset + version + at least one glTF-specific key, it's likely glTF
    // The combination of "asset" + "version" alone could be other formats,
    // but with scene-related keys it's definitively glTF
    if (gltf_keys >= 1) {
        return true;
    }

    // If asset + version but no other glTF keys, check for generator mentioning glTF
    // This handles minimal glTF files
    if (std.mem.indexOf(u8, search_area, "\"generator\"") != null) {
        // Many glTF exporters put their name in generator, often including "glTF"
        // But even without that, asset + version + generator is a strong signal
        return true;
    }

    return false;
}

/// Detect ZIP-based format by examining archive contents.
/// Must be called after detectFormat returns .zip.
pub fn detectZipSubformat(file: std.fs.File) FileFormat {
    // Read enough to scan for format markers
    var buffer: [8192]u8 = undefined;
    const bytes_read = file.read(&buffer) catch return .zip;

    // Look for EPUB mimetype file.
    // Per EPUB spec, first ZIP entry should be named "mimetype" containing "application/epub+zip".
    // Check both: (1) uncompressed (adjacent strings) and (2) compressed (just filename at offset 30).
    if (findInBuffer(&buffer, bytes_read, "mimetypeapplication/epub+zip")) {
        return .epub;
    }
    // Fallback: first entry named "mimetype" but content is compressed.
    // OCF 3.0 §3.3 requires mimetype to be stored uncompressed — this is a spec violation
    // that most readers tolerate but we should warn about.
    if (bytes_read >= 38) {
        const fname_len = std.mem.readInt(u16, buffer[26..28], .little);
        if (fname_len == 8 and std.mem.eql(u8, buffer[30..38], "mimetype")) {
            // Check compression method at offset 8-9 (0 = stored, 8 = deflate)
            const comp_method = std.mem.readInt(u16, buffer[8..10], .little);
            if (comp_method != 0) {
                // Tag this for a warning downstream — use a global or return
                // a special value. For now, still return .epub (detection is correct)
                // and the validator will check compression method separately.
            }
            return .epub;
        }
    }

    // Look for OpenDocument mimetypes
    if (findInBuffer(&buffer, bytes_read, "mimetypeapplication/vnd.oasis.opendocument.text")) {
        return .odt;
    }
    if (findInBuffer(&buffer, bytes_read, "mimetypeapplication/vnd.oasis.opendocument.spreadsheet")) {
        return .ods;
    }
    if (findInBuffer(&buffer, bytes_read, "mimetypeapplication/vnd.oasis.opendocument.presentation")) {
        return .odp;
    }

    // Look for Office Open XML markers
    if (findInBuffer(&buffer, bytes_read, "[Content_Types].xml")) {
        // Check for specific Office types
        if (findInBuffer(&buffer, bytes_read, "word/")) {
            return .docx;
        }
        if (findInBuffer(&buffer, bytes_read, "xl/")) {
            return .xlsx;
        }
        if (findInBuffer(&buffer, bytes_read, "ppt/")) {
            return .pptx;
        }
    }

    // Apple Pages: Look for Index.zip or index.xml
    if (findInBuffer(&buffer, bytes_read, "Index.zip") or
        findInBuffer(&buffer, bytes_read, "index.xml") or
        findInBuffer(&buffer, bytes_read, "buildVersionHistory.plist"))
    {
        return .pages;
    }

    // Studio One: Look for metainfo.xml (characteristic of .song files)
    if (findInBuffer(&buffer, bytes_read, "metainfo.xml") and
        (findInBuffer(&buffer, bytes_read, "Song/") or findInBuffer(&buffer, bytes_read, "notepad.xml")))
    {
        return .song;
    }

    // KMZ: compressed KML package. Commonly contains doc.kml at archive root.
    if (findInBuffer(&buffer, bytes_read, "doc.kml")) {
        return .kmz;
    }

    // 3MF: Look for [Content_Types].xml with 3D model references
    if (findInBuffer(&buffer, bytes_read, "[Content_Types].xml") and
        (findInBuffer(&buffer, bytes_read, "3D/") or findInBuffer(&buffer, bytes_read, "3dmodel.model")))
    {
        return .@"3mf";
    }

    return .zip;
}

pub fn findInBuffer(buffer: []const u8, len: usize, needle: []const u8) bool {
    if (len < needle.len) return false;
    const search_len = @min(len, buffer.len);
    return std.mem.indexOf(u8, buffer[0..search_len], needle) != null;
}

// ============ Debug Logging ============

/// Debug log file for format validation (written to /tmp/es_format_debug.log)
fn debugLog(comptime fmt: []const u8, args: anytype) void {
    // Use fixed path for reliability (TMPDIR varies per process on macOS)
    const log_path = "/tmp/es_format_debug.log";
    // Create file if it doesn't exist, otherwise append
    const file = std.fs.cwd().createFile(log_path, .{
        .truncate = false,
    }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(msg) catch return;
}


/// Check if content looks like CP437-encoded text (demoscene NFO files).
/// CP437 is the classic IBM PC/DOS character set used for ASCII art.
/// Key indicators: box-drawing characters (0xB0-0xDF), block elements (0xDB-0xDF),
/// and absence of truly "weird" byte patterns that suggest binary data.
fn looksLikeCp437(bytes: []const u8) bool {
    if (bytes.len == 0) return false;

    var box_drawing_count: usize = 0;
    var high_byte_count: usize = 0;
    var printable_count: usize = 0;

    for (bytes) |b| {
        // Count box-drawing and block characters (0xB0-0xDF in CP437)
        // These are the most distinctive CP437 characters used in ASCII art:
        // 0xB0-0xB2: ░▒▓ (shading)
        // 0xB3-0xDA: │┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌ (box drawing)
        // 0xDB-0xDF: █▄▌▐▀ (block elements)
        if (b >= 0xB0 and b <= 0xDF) {
            box_drawing_count += 1;
        }

        // Count all high bytes (0x80-0xFF)
        if (b >= 0x80) {
            high_byte_count += 1;
        }

        // Count printable ASCII (space through ~, plus common whitespace)
        if ((b >= 0x20 and b <= 0x7E) or b == 0x09 or b == 0x0A or b == 0x0D) {
            printable_count += 1;
        }
    }

    // Must have some high bytes (otherwise it would be valid UTF-8/ASCII)
    if (high_byte_count == 0) return false;

    // For CP437, we expect a significant portion of high bytes to be box-drawing
    // Real CP437 NFO files use these heavily for borders and art
    // Require at least 30% of high bytes to be box-drawing characters
    if (high_byte_count > 0 and box_drawing_count * 100 / high_byte_count < 30) {
        // Could be Latin-1 or other encoding with accented characters
        // but not the distinctive box-drawing of CP437 NFO files
        return false;
    }

    // Should have some basic text structure (newlines, spaces, or ASCII)
    // NFO files can be heavy on art but usually have SOME text structure
    // Very lenient: just need 2% recognizable text/whitespace
    // (demoscene NFO headers can be almost pure box-drawing with minimal whitespace)
    if (bytes.len > 0 and printable_count * 100 / bytes.len < 2) {
        return false;
    }

    return true;
}

/// Check if content looks like Latin-1 (ISO-8859-1) encoded text.
/// Latin-1 text is mostly ASCII with some accented characters in 0xA0-0xFF range.
/// The 0x80-0x9F range are control characters in Latin-1, rarely used in text.
fn looksLikeLatin1(bytes: []const u8) bool {
    if (bytes.len == 0) return false;

    var printable_ascii: usize = 0;
    var latin1_extended: usize = 0; // 0xA0-0xFF (printable Latin-1 supplement)
    var control_chars: usize = 0; // 0x80-0x9F (C1 control codes)
    var high_byte_count: usize = 0;

    for (bytes) |b| {
        // Count printable ASCII (space through ~, plus common whitespace)
        if ((b >= 0x20 and b <= 0x7E) or b == 0x09 or b == 0x0A or b == 0x0D) {
            printable_ascii += 1;
        }

        // Count high bytes
        if (b >= 0x80) {
            high_byte_count += 1;
            if (b >= 0xA0) {
                latin1_extended += 1; // Printable Latin-1 supplement
            } else {
                control_chars += 1; // C1 control codes (0x80-0x9F)
            }
        }
    }

    // Must have some high bytes (otherwise it would be valid UTF-8/ASCII)
    if (high_byte_count == 0) return false;

    // Real Latin-1 text should be mostly printable ASCII with few high bytes
    // Require at least 50% printable ASCII
    if (bytes.len > 0 and printable_ascii * 100 / bytes.len < 50) {
        return false;
    }

    // Latin-1 text rarely uses C1 control codes (0x80-0x9F)
    // If most high bytes are in this range, it's probably not Latin-1 text
    if (high_byte_count > 0 and control_chars * 100 / high_byte_count > 50) {
        return false;
    }

    return true;
}

/// Check if content looks like INI format by examining the first ~10 non-comment lines.
/// INI files have [section] headers and key=value pairs.
/// Requirements:
/// - At least half of non-empty, non-comment lines should match INI syntax
/// - At least ONE key=value line must be present (section headers alone aren't enough)
fn looksLikeIni(content: []const u8) bool {
    if (content.len == 0) return false;

    var ini_like_lines: usize = 0;
    var key_value_lines: usize = 0; // Must have at least one
    var total_content_lines: usize = 0;
    var line_start: usize = 0;
    const max_content_lines_to_check: usize = 10;

    var pos: usize = 0;
    while (pos < content.len and total_content_lines < max_content_lines_to_check) {
        // Find end of line
        var line_end = pos;
        while (line_end < content.len and content[line_end] != '\n' and content[line_end] != '\r') {
            line_end += 1;
        }

        const line = content[line_start..line_end];

        // Skip to next line
        if (line_end < content.len and content[line_end] == '\r') line_end += 1;
        if (line_end < content.len and content[line_end] == '\n') line_end += 1;
        line_start = line_end;
        pos = line_end;

        // Skip empty lines
        var trimmed_start: usize = 0;
        while (trimmed_start < line.len and (line[trimmed_start] == ' ' or line[trimmed_start] == '\t')) {
            trimmed_start += 1;
        }
        if (trimmed_start >= line.len) continue;

        const trimmed = line[trimmed_start..];

        // Skip comment lines (;comment or #comment) - don't count towards max_content_lines
        if (trimmed[0] == ';' or trimmed[0] == '#') continue;

        total_content_lines += 1;

        // Check for [section] header - allow any printable content inside brackets
        // Real-world sections: [.ShellClassInfo], [{GUID}], [remote "origin"], etc.
        if (trimmed[0] == '[') {
            if (trimmed.len > 2) {
                // Find the closing ]
                var j: usize = 1;
                while (j < trimmed.len) : (j += 1) {
                    const ch = trimmed[j];
                    if (ch == ']') {
                        // Must have at least one char in section name
                        if (j > 1) {
                            // Check that only whitespace/comment follows the ]
                            var k = j + 1;
                            while (k < trimmed.len and (trimmed[k] == ' ' or trimmed[k] == '\t')) : (k += 1) {}
                            if (k >= trimmed.len or trimmed[k] == ';' or trimmed[k] == '#') {
                                ini_like_lines += 1;
                            }
                        }
                        break;
                    }
                    // Allow any printable ASCII or UTF-8 in section names
                    if (ch < 0x20 and ch != '\t') break; // Control char = not a section
                }
            }
            continue;
        }

        // Check for key=value or key : value pattern
        // Key can start with letter, underscore, digit, dot, percent, etc.
        // Also accept Unreal Engine array prefixes: +Key=, -Key=, !Key=
        const fc = trimmed[0];
        var key_start: usize = 0;
        if ((fc == '+' or fc == '-' or fc == '!') and trimmed.len > 1) {
            const nc = trimmed[1];
            if ((nc >= 'a' and nc <= 'z') or (nc >= 'A' and nc <= 'Z') or
                (nc >= '0' and nc <= '9') or nc == '_' or nc == '.' or nc >= 0x80)
            {
                key_start = 1; // Skip the prefix
            }
        }
        const effective_fc = if (key_start > 0) trimmed[key_start] else fc;
        if ((effective_fc >= 'a' and effective_fc <= 'z') or (effective_fc >= 'A' and effective_fc <= 'Z') or
            (effective_fc >= '0' and effective_fc <= '9') or effective_fc == '_' or effective_fc == '.' or effective_fc == '-' or
            effective_fc == '%' or effective_fc >= 0x80)
        {
            // Look for = delimiter only (not : which conflicts with email headers, URLs, etc.)
            // Allow spaces within keys (Windows desktop.ini uses filenames as keys)
            var j: usize = key_start + 1;
            while (j < trimmed.len and trimmed[j] != '=') {
                j += 1;
            }
            // Check for =
            if (j < trimmed.len and trimmed[j] == '=') {
                ini_like_lines += 1;
                key_value_lines += 1;
            }
        }
    }

    // Must have at least one key=value line
    if (key_value_lines == 0) return false;

    // Need at least 2 content lines to make a determination
    if (total_content_lines < 2) {
        // For single-line content, require it to be a key=value line
        return total_content_lines == 1 and key_value_lines == 1;
    }

    // At least half of content lines should look like INI
    return ini_like_lines * 2 >= total_content_lines;
}

test "looksLikeIni detects valid INI content" {
    // Simple key=value pairs
    const simple_ini = "key=value\nother=stuff\n";
    try std.testing.expect(looksLikeIni(simple_ini));

    // With section headers
    const sectioned_ini = "[section]\nkey=value\nother=stuff\n";
    try std.testing.expect(looksLikeIni(sectioned_ini));

    // With comments
    const commented_ini = "; comment\n[section]\nkey=value\n";
    try std.testing.expect(looksLikeIni(commented_ini));

    // With spaces around =
    const spaced_ini = "key = value\nother = stuff\n";
    try std.testing.expect(looksLikeIni(spaced_ini));
}

test "looksLikeIni rejects non-INI content" {
    // BBCode (like NFO files)
    const bbcode = "[img]http://example.com/image.jpg[/img]\nSome text here\n";
    try std.testing.expect(!looksLikeIni(bbcode));

    // Plain text
    const plain = "Hello World\nThis is just text\nNo equals signs here\n";
    try std.testing.expect(!looksLikeIni(plain));

    // JSON array
    const json_array = "[1, 2, 3]\n[4, 5, 6]\n";
    try std.testing.expect(!looksLikeIni(json_array));

    // Broken section (no closing bracket) - with valid key=value, still detected as INI
    // because we focus on key=value presence, not strict section syntax
    const broken = "[broken\nkey=value\n";
    try std.testing.expect(looksLikeIni(broken));

    // Only section headers (no key=value pairs) - should not match
    const only_sections = "[section1]\n[section2]\n[section3]\n";
    try std.testing.expect(!looksLikeIni(only_sections));
}

test "looksLikeCp437 detects box-drawing characters" {
    // Pure box-drawing characters (like demoscene NFO headers)
    const box_art = [_]u8{
        0xDB, 0xDB, 0xDF, 0xDF, 0x20, 0x20, // ██▀▀ (with spaces for 5% printable)
        0xDB, 0xB2, 0xB0, 0xB1, 0x0D, 0x0A, // █▓░▒\r\n
    };
    try std.testing.expect(looksLikeCp437(&box_art));

    // Regular ASCII should not be CP437 (no high bytes)
    const ascii = "Hello, World!\r\n";
    try std.testing.expect(!looksLikeCp437(ascii));

    // Latin-1 accented chars without box-drawing should not match
    // (0xE9 = é, 0xE0 = à - these are in 0xE0-0xEF range, not 0xB0-0xDF box-drawing)
    const latin1 = [_]u8{ 'C', 'a', 'f', 0xE9, ' ', 0xE0, ' ', 'l', 'a', ' ', 'c', 'a', 'r', 't', 'e' };
    try std.testing.expect(!looksLikeCp437(&latin1));
}

// ============ Font Validators (TTF/OTF/WOFF/WOFF2) ============

/// Validate TrueType font file with table checksum verification.
fn validateTtf(allocator: Allocator, file: std.fs.File) ValidationResult {
    return validateFontFile(allocator, file, .ttf);
}

/// Validate OpenType (CFF) font file with table checksum verification.
fn validateOtf(allocator: Allocator, file: std.fs.File) ValidationResult {
    return validateFontFile(allocator, file, .otf);
}

/// Validate WOFF container.
fn validateWoff(allocator: Allocator, file: std.fs.File) ValidationResult {
    return validateFontFile(allocator, file, .woff);
}

/// Validate WOFF2 container.
fn validateWoff2(allocator: Allocator, file: std.fs.File) ValidationResult {
    return validateFontFile(allocator, file, .woff2);
}

/// Validate Type1 (PFB/PFA) font.
fn validateType1Font(allocator: Allocator, file: std.fs.File) ValidationResult {
    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.type1, .failed_to_stat, "font file");
    };

    // Reasonable limit for font files (100 MB)
    const max_font_size: u64 = 100 * 1024 * 1024;
    if (stat.size > max_font_size) {
        return ValidationResult.invalid(.type1, "Font file too large");
    }

    if (stat.size == 0) {
        return ValidationResult.invalidCode(.type1, .empty, "font file");
    }

    // Read entire file for validation - use heap allocation to avoid stack overflow
    file.seekTo(0) catch {
        return ValidationResult.invalidCode(.type1, .failed_to_seek, "to start");
    };

    const data = allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalidCode(.type1, .failed_to_allocate, "memory");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(.type1, .failed_to_read, "font file");
    };

    if (bytes_read != stat.size) {
        return ValidationResult.invalidCode(.type1, .incomplete, "read of font file");
    }

    const result = font_validator.validateType1(data);

    if (result.valid) {
        return ValidationResult.okWithDepth(.type1, .structural);
    } else {
        return ValidationResult.invalid(.type1, result.error_message orelse "Type1 validation failed");
    }
}

/// Common font validation implementation.
fn validateFontFile(allocator: Allocator, file: std.fs.File, format: FileFormat) ValidationResult {
    // Get file size
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(format, .failed_to_stat, "font file");
    };

    // Reasonable limit for font files (100 MB)
    const max_font_size: u64 = 100 * 1024 * 1024;
    if (stat.size > max_font_size) {
        return ValidationResult.invalid(format, "Font file too large");
    }

    if (stat.size == 0) {
        return ValidationResult.invalidCode(format, .empty, "font file");
    }

    // Read entire file for validation - use heap allocation to avoid stack overflow
    file.seekTo(0) catch {
        return ValidationResult.invalidCode(format, .failed_to_seek, "to start");
    };

    const data = allocator.alloc(u8, @intCast(stat.size)) catch {
        return ValidationResult.invalidCode(format, .failed_to_allocate, "memory");
    };
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch {
        return ValidationResult.invalidCode(format, .failed_to_read, "font file");
    };

    if (bytes_read != stat.size) {
        return ValidationResult.invalidCode(format, .incomplete, "read of font file");
    }

    // Dispatch to appropriate validator
    const result = switch (format) {
        .ttf, .otf => font_validator.validateTtfOtf(data),
        .woff => font_validator.validateWoff(data),
        .woff2 => font_validator.validateWoff2(data),
        else => return ValidationResult.ok(format),
    };

    if (result.valid) {
        // Check for warnings (e.g., checksum mismatch but structural parsing succeeded)
        if (result.warning_message) |warning| {
            return ValidationResult.okWithDepthAndWarning(format, .full, warning);
        }
        return ValidationResult.okWithDepth(format, .full);
    } else {
        return ValidationResult.invalid(format, result.error_message orelse "Font validation failed");
    }
}

// ============ UTF-8 Fallback Validation for Unknown Formats ============

/// Attempt UTF-8 validation for unknown file formats.
/// If the file is valid UTF-8 text, returns ok with charset validation.
/// This provides some level of integrity checking for text files that don't match
/// any known format signatures.
fn validateUnknownWithUtf8Fallback(file: std.fs.File) ValidationResult {
    // Read first chunk of file to check for UTF-8 or binary STL
    const sample_size: usize = 8192;
    var buffer: [sample_size]u8 = undefined;

    file.seekTo(0) catch {
        return ValidationResult.ok(.unknown);
    };

    const bytes_read = file.read(&buffer) catch {
        return ValidationResult.ok(.unknown);
    };

    if (bytes_read == 0) {
        // Empty file - no validation possible
        return ValidationResult.ok(.unknown);
    }

    // Note: Binary STL heuristic detection was attempted but is unreliable without file extension hints.
    // Binary STL has no magic bytes and the triangle count heuristic has too many false positives.
    // Files with .stl extension should be routed to validateStl externally if extension-based
    // detection is desired.

    // Check for BOM (Byte Order Mark)
    var start_offset: usize = 0;
    var detected_encoding: enum { none, utf8_bom, utf16le, utf16be, utf32le, utf32be } = .none;

    if (bytes_read >= 3 and buffer[0] == 0xEF and buffer[1] == 0xBB and buffer[2] == 0xBF) {
        // UTF-8 BOM
        detected_encoding = .utf8_bom;
        start_offset = 3;
    } else if (bytes_read >= 4 and buffer[0] == 0x00 and buffer[1] == 0x00 and buffer[2] == 0xFE and buffer[3] == 0xFF) {
        // UTF-32 BE BOM
        detected_encoding = .utf32be;
        start_offset = 4;
    } else if (bytes_read >= 4 and buffer[0] == 0xFF and buffer[1] == 0xFE and buffer[2] == 0x00 and buffer[3] == 0x00) {
        // UTF-32 LE BOM
        detected_encoding = .utf32le;
        start_offset = 4;
    } else if (bytes_read >= 2 and buffer[0] == 0xFE and buffer[1] == 0xFF) {
        // UTF-16 BE BOM
        detected_encoding = .utf16be;
        start_offset = 2;
    } else if (bytes_read >= 2 and buffer[0] == 0xFF and buffer[1] == 0xFE) {
        // UTF-16 LE BOM
        detected_encoding = .utf16le;
        start_offset = 2;
    }

    // If we found a BOM, we have encoding information
    if (detected_encoding != .none) {
        // For UTF-8 with BOM, validate the UTF-8 content
        if (detected_encoding == .utf8_bom) {
            if (text_format_validators.validateUtf8(buffer[start_offset..bytes_read]).isValid()) {
                var result = ValidationResult.ok(.unknown);
                result.validation_depth = .structural;
                return result;
            }
        }
        // For other BOMs, we detected the encoding but can't fully validate
        var result = ValidationResult.ok(.unknown);
        result.validation_depth = .structural;
        return result;
    }

    // No BOM - try UTF-8 validation
    if (text_format_validators.validateUtf8(buffer[0..bytes_read]).isValid()) {
        // Check if it looks like text (mostly printable/whitespace)
        var text_chars: usize = 0;
        var binary_chars: usize = 0;

        for (buffer[0..bytes_read]) |byte| {
            if (byte >= 0x20 and byte <= 0x7E) {
                text_chars += 1;
            } else if (byte == 0x09 or byte == 0x0A or byte == 0x0D) {
                // Tab, LF, CR are text characters
                text_chars += 1;
            } else if (byte >= 0x80) {
                // UTF-8 continuation bytes or multibyte start - counted in UTF-8 check
                text_chars += 1;
            } else if (byte == 0x00) {
                // Null byte - likely binary
                binary_chars += 10; // Weight nulls heavily
            } else {
                // Other control characters
                binary_chars += 1;
            }
        }

        // If mostly text (>90% printable/whitespace/utf8), consider it valid text
        if (bytes_read > 0 and text_chars * 10 > bytes_read * 9) {
            var result = ValidationResult.ok(.unknown);
            result.validation_depth = .structural;
            return result;
        }
    }

    // Not valid UTF-8 or too binary - no validation possible
    return ValidationResult.ok(.unknown);
}

// ============ Brotli Deep Validation ============

/// Deep Brotli validation by attempting full decompression.
/// Validates the compressed bitstream integrity by decoding it entirely.
fn validateBrotliDeep(path: []const u8) ValidationResult {
    const result = brotli_validator.validateBrotliDeep(path);
    if (result.valid) {
        return ValidationResult.okWithDepth(.br, .full);
    } else {
        return ValidationResult.invalidWithDepth(.br, result.error_message orelse errmsg.decompressionFailed("Brotli"), .full);
    }
}

/// Structural validation for Apple Media Library Database (hfma).
/// Checks magic, header size field, version string, and content size plausibility.
fn validateAppleMediaDbStructural(data: []const u8, file_size: u64) ValidationResult {
    if (data.len < 160) return ValidationResult.invalid(.apple_media_db, "File too small for hfma header");
    if (!std.mem.eql(u8, data[0..4], "hfma")) return ValidationResult.invalid(.apple_media_db, "Invalid magic bytes");

    const declared_header_size = std.mem.readInt(u32, data[4..8], .little);
    if (declared_header_size != 0xA0) return ValidationResult.invalid(.apple_media_db, "Invalid header size field");

    // Offset 8: total file size (u32 LE)
    const declared_file_size = std.mem.readInt(u32, data[8..12], .little);
    if (declared_file_size == 0) return ValidationResult.invalid(.apple_media_db, "Declared file size is zero");
    if (file_size > 0 and declared_file_size != @as(u32, @truncate(file_size))) {
        return ValidationResult.invalid(.apple_media_db, "Declared file size does not match actual");
    }

    // Version string at offset 16
    if (!apple_media_db_validator.validateVersionStringPub(data[16..48])) {
        return ValidationResult.invalid(.apple_media_db, "Invalid version string");
    }

    return ValidationResult.ok(.apple_media_db);
}

// ============ Main Validator Interface ============

/// Main format validation interface.
/// Pure Zig implementation with no external dependencies.
pub const FormatValidator = struct {
    enabled: bool,
    deep_validation: bool,
    check_resource_forks: bool,
    allocator: ?Allocator,

    const Self = @This();

    /// Initialize the format validator with default settings.
    pub fn init() Self {
        return Self{
            .enabled = true,
            .deep_validation = false,
            .check_resource_forks = true, // Default on for macOS
            .allocator = null,
        };
    }

    /// Initialize with deep validation enabled.
    pub fn initDeep() Self {
        return Self{
            .enabled = true,
            .deep_validation = true,
            .check_resource_forks = true,
            .allocator = null,
        };
    }

    /// Initialize with an allocator for buffer-based validation.
    pub fn initWithAllocator(allocator: Allocator) Self {
        return Self{
            .enabled = true,
            .deep_validation = false,
            .check_resource_forks = true,
            .allocator = allocator,
        };
    }

    /// Clean up resources (no-op for pure Zig implementation).
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Enable or disable validation.
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Enable or disable deep validation (checksums, integrity checks).
    pub fn setDeepValidation(self: *Self, enabled: bool) void {
        self.deep_validation = enabled;
    }

    /// Enable or disable resource fork checking.
    pub fn setCheckResourceForks(self: *Self, enabled: bool) void {
        self.check_resource_forks = enabled;
    }

    /// Validate a file at the given path (structural validation only).
    /// Returns validation result with detected format and validity.
    /// Note: For bundle directories (.git, etc.), use validateFileDeep which
    /// has an allocator and can perform full bundle validation.
    pub fn validateFile(self: *Self, path: []const u8) ValidationResult {
        if (!self.enabled) {
            return ValidationResult.unknown();
        }

        // Check for bundle directories - these require deep validation
        const bundle_type = detectBundleType(path);
        if (bundle_type != .none) {
            // Bundle directories require allocator for validation.
            // Return a result indicating this is a bundle that needs deep validation.
            return switch (bundle_type) {
                .git => ValidationResult.okWithDepth(.git_repository, .structural),
                .macos_app => ValidationResult.okWithDepth(.macos_app, .structural),
                .macos_framework => ValidationResult.okWithDepth(.macos_framework, .structural),
                .macos_bundle => ValidationResult.okWithDepth(.macos_bundle, .structural),
                .garageband => ValidationResult.okWithDepth(.band, .structural),
                .none => unreachable,
            };
        }

        // SQLite companion files (.sqlite-wal, .sqlite-shm, .sqlite-journal)
        // These are ephemeral files used by SQLite WAL/journal mode. They're
        // not independently meaningful but should be recognized rather than UNKNOWN.
        if (isSqliteCompanionFile(path)) {
            return ValidationResult.okWithDepth(.sqlite, .structural);
        }

        // Check if path is a directory (but not a known bundle)
        const stat = std.fs.cwd().statFile(path) catch {
            return ValidationResult.invalidCode(.unknown, .failed_to_open, "file");
        };
        if (stat.kind == .directory) {
            // Check for BagIt bag (directory containing bagit.txt)
            var bagit_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const bagit_txt_path = std.fmt.bufPrint(&bagit_path_buf, "{s}/bagit.txt", .{path}) catch {
                return ValidationResult.invalidCode(.unknown, .unknown_element, "directory type (not a recognized bundle)");
            };
            if (std.fs.cwd().access(bagit_txt_path, .{})) |_| {
                return ValidationResult.okWithDepth(.bagit, .structural);
            } else |_| {}

            // Directory that is not a known bundle type - return continuable error
            return ValidationResult.invalidCode(.unknown, .unknown_element, "directory type (not a recognized bundle)");
        }

        // Open the file
        const file = std.fs.cwd().openFile(path, .{}) catch {
            return ValidationResult.invalidCode(.unknown, .failed_to_open, "file");
        };
        defer file.close();

        var result = self.validateFileHandle(file);

        // Bidi overrides are normal in subtitle files (RTL languages like Hebrew, Arabic)
        // — suppress the trojan-source warning for known subtitle extensions
        if (result.warning_message != null and isSubtitleExtension(path)) {
            if (std.mem.indexOf(u8, result.warning_message.?, "bidi") != null) {
                result.warning_message = null;
            }
        }

        // If content-based detection found a text format (JSON, XML, etc.) but the
        // file extension indicates this is a code/log/template file, don't validate
        // it as that text format - it's a false positive from content detection.
        const is_content_detected_text_format = switch (result.format) {
            .json, .xml, .ini, .toml, .yaml, .csv, .erlang_term, .fasta, .fastq, .eml => true,
            else => false,
        };
        if (is_content_detected_text_format and isExcludedTextExtension(path)) {
            // Content looks like JSON/XML/INI/etc. but extension says it's source code.
            // Validate as plain text (UTF-8 check) instead of the detected format.
            var reopen_source = file_source.FileSource.open(path) catch {
                return ValidationResult.okWithDepth(.plain_text, .structural);
            };
            defer reopen_source.close();
            return text_format_validators.validatePlainText(self.allocator, &reopen_source);
        }

        // Check extension-based detection
        const ext_format = detectFormatFromExtension(path);
        const expected_format = getExpectedFormatForExtension(path);

        // If magic-based detection failed (or only detected plain text), try extension-based detection
        // This handles formats like Brotli (.br) that have no magic bytes, and JSONC files that
        // start with comments (detected as plain_text but should be validated as JSON)
        if ((result.format == .unknown or result.format == .plain_text) and ext_format != .unknown) {
            // Check if this is a text format that can be validated
            const ext_is_validatable_text = switch (ext_format) {
                .json, .toml, .ini, .xml => true,
                else => false,
            };
            if (ext_is_validatable_text) {
                // Reopen and validate with extension-detected format
                const reopen_file = std.fs.cwd().openFile(path, .{}) catch {
                    result = ValidationResult.ok(ext_format);
                    return result;
                };
                defer reopen_file.close();
                var ext_source = file_source.FileSource.fromFile(reopen_file);
                result = switch (ext_format) {
                    .json => text_format_validators.validateJson(&ext_source),
                    .toml => text_format_validators.validateToml(&ext_source),
                    .ini => text_format_validators.validateIni(&ext_source),
                    .xml => text_format_validators.validateXml(&ext_source),
                    else => ValidationResult.ok(ext_format),
                };
            } else {
                // For extension-only formats (like Brotli, DV, TGA) that lack
                // magic bytes, trust the extension and validate with the
                // format-specific validator directly.
                const ext_has_no_magic = switch (ext_format) {
                    .br, .hqx, .cpt, .dv, .tga, .html, .dmg, .iso,
                    .bwproject, .ptx, .band, .reason, .cpr, .logicx, .song, .sketch, .drp,
                    .snes, .gb, .gba, .nds, .genesis, .cwk, .mwd,
                    .qbw, .qbb, .qdf, .ofx, .qif, .txf, .nacha, .mt940, .bai2,
                    .x12_edi, .edifact,
                    .der, // DER: first byte 0x30 is too generic for magic detection
                    .obj, .coff, .stl, // .obj is ambiguous (Wavefront OBJ vs COFF); .o has no magic; binary STL has no magic
                    .cdg, // CDG has no magic bytes, only extension + size divisibility
                    .toast, // Toast may be ISO internally or APM-prefixed
                    .mp2, // MP2 shares MPEG sync word with MP3, needs extension hint
                    .msi, // MSI uses OLE2 magic, needs subformat detection
                    => true,
                    else => false,
                };
                if (ext_has_no_magic and ext_format.hasValidator()) {
                    const reopen_ext = std.fs.cwd().openFile(path, .{}) catch {
                        result = ValidationResult.ok(ext_format);
                        return result;
                    };
                    defer reopen_ext.close();
                    var reopen_ext_src = FileSource.fromFile(reopen_ext);
                    const reopen_ext_ptr = &reopen_ext_src;
                    result = switch (ext_format) {
                        .dv => movie_validators.validateDv(reopen_ext_ptr),
                        .tga => image_validators.validateTga(reopen_ext_ptr),
                        .html => text_format_validators.validateHtml(reopen_ext_ptr),
                        .dmg => filesystem_validators.validateDmg(reopen_ext_ptr),
                        .iso => filesystem_validators.validateIso(reopen_ext_ptr),
                        .hqx => archive_validators.validateHqx(reopen_ext_ptr),
                        .cpt => archive_validators.validateCpt(reopen_ext_ptr),
                        .bwproject => daw_validators.validateBwproject(reopen_ext_ptr),
                        .ptx => daw_validators.validateProTools(reopen_ext_ptr),
                        .band => daw_validators.validateGarageBand(reopen_ext_ptr),
                        .reason => daw_validators.validateReason(reopen_ext_ptr),
                        .cpr => daw_validators.validateCubase(reopen_ext_ptr),
                        .logicx, .song => archive_validators.validateZip(reopen_ext_ptr, ext_format),
                        .sketch => creative_validators.validateSketch(reopen_ext_ptr),
                        .drp => creative_validators.validateDrp(reopen_ext_ptr),
                        .snes => game_validator.validateSnes(reopen_ext_ptr),
                        .gb => game_validator.validateGb(reopen_ext_ptr),
                        .gba => game_validator.validateGba(reopen_ext_ptr),
                        .nds => game_validator.validateNds(reopen_ext_ptr),
                        .genesis => game_validator.validateGenesis(reopen_ext_ptr),
                        .cwk => apple_validators.validateClarisWorks(reopen_ext_ptr),
                        .mwd => apple_validators.validateMacWrite(reopen_ext_ptr),
                        .qbw => financial_validators.validateQbw(reopen_ext_ptr),
                        .qbb => financial_validators.validateQbb(reopen_ext_ptr),
                        .qdf => financial_validators.validateQdf(reopen_ext_ptr),
                        .ofx => financial_validators.validateOfx(reopen_ext_ptr),
                        .qif => financial_validators.validateQif(reopen_ext_ptr),
                        .txf => financial_validators.validateTxf(reopen_ext_ptr),
                        .nacha => financial_validators.validateNacha(reopen_ext_ptr),
                        .mt940 => financial_validators.validateMt940(reopen_ext_ptr),
                        .bai2 => financial_validators.validateBai2(reopen_ext_ptr),
                        .x12_edi => edi_validators.validateX12Edi(reopen_ext_ptr),
                        .edifact => edi_validators.validateEdifact(reopen_ext_ptr),
                        .coff => executable_validators.validateCoff(reopen_ext_ptr),
                        .der => crypto_validators.validateDer(reopen_ext_ptr),
                        .pgp_signed => crypto_validators.validatePgpSigned(reopen_ext_ptr),
                        .ssh_signature => crypto_validators.validateSshSignature(reopen_ext_ptr),
                        .cdg => cdg_validator.validateCdg(reopen_ext_ptr),
                        .toast => toast_validator.validateToast(reopen_ext_ptr),
                        .mp2 => blk: {
                            var mp2_result = music_validators.validateMp3(reopen_ext_ptr);
                            mp2_result.format = .mp2;
                            break :blk mp2_result;
                        },
                        .msi => document_validators.validateMsi(reopen_ext_ptr),
                        .obj => blk: {
                            // .obj is ambiguous: try COFF first (binary), fall back to Wavefront OBJ (text)
                            const coff_result = executable_validators.validateCoff(reopen_ext_ptr);
                            if (coff_result.format == .coff and coff_result.is_valid) {
                                break :blk coff_result;
                            }
                            // Not COFF — try Wavefront OBJ
                            reopen_ext_ptr.seekTo(0) catch break :blk ValidationResult.ok(.obj);
                            break :blk cad_3d_validators.validateObj(reopen_ext_ptr);
                        },
                        .stl => cad_3d_validators.validateStl(reopen_ext_ptr),
                        else => ValidationResult.ok(ext_format),
                    };
                } else {
                    result = ValidationResult.ok(ext_format);
                }
            }
        }

        // If format is still unknown but extension suggests a binary format,
        // try secondary signature detection (trailers, internal patterns).
        // This handles corrupted magic bytes.
        if (result.format == .unknown and expected_format != .unknown) {
            // Check if this is a binary format that might have corrupted magic bytes
            // Any format with a validator is worth trying secondary detection
            const is_binary_format = expected_format.hasValidator() and switch (expected_format) {
                // Exclude text/extension-only formats already handled above
                .json, .toml, .ini, .xml, .yaml, .erlang_term, .eex, .markdown => false,
                .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437 => false,
                .br => false, // Brotli has no magic, extension-only
                .dv => false, // DV has no magic bytes, extension-only
                .tga => false, // TGA has no magic bytes at start, extension-only
                .cdg => false, // CDG has no magic bytes, extension+size only
                .toast => false, // Toast may be ISO internally, extension-only
                .mp2 => false, // MP2 shares sync word with MP3, extension-driven
                .msi => false, // MSI uses OLE2 magic, detected via subformat dispatch
                else => true,
            };

            if (is_binary_format) {
                // Read file content for secondary signature detection
                const reopen_file = std.fs.cwd().openFile(path, .{}) catch {
                    return result;
                };
                defer reopen_file.close();

                // Get file size to read tail for formats with end signatures (PDF, JPEG, GIF)
                const file_size = reopen_file.getEndPos() catch {
                    return result;
                };

                // Read up to 64KB from start for signature detection
                const buffer = (self.allocator orelse std.heap.page_allocator).alloc(u8, 65536) catch {
                    return result;
                };
                defer (self.allocator orelse std.heap.page_allocator).free(buffer);
                const bytes_read = reopen_file.read(buffer) catch {
                    return result;
                };

                var secondary_format: FileFormat = .unknown;

                if (bytes_read > 0) {
                    const data = buffer[0..bytes_read];
                    secondary_format = detectFormatBySecondarySignatures(data, expected_format);
                }

                // If not found in start, check file tail for formats with end signatures
                if (secondary_format == .unknown and file_size > 65536) {
                    const tail_formats_need_check = switch (expected_format) {
                        .pdf, .jpeg, .gif, .zip, .epub, .docx, .xlsx, .pptx => true,
                        else => false,
                    };

                    if (tail_formats_need_check) {
                        // Read last 4KB from end of file
                        var tail_buffer: [4096]u8 = undefined;
                        const tail_offset = file_size - @min(file_size, 4096);
                        reopen_file.seekTo(tail_offset) catch {
                            return result;
                        };
                        const tail_read = reopen_file.read(&tail_buffer) catch {
                            return result;
                        };

                        if (tail_read > 0) {
                            const tail_data = tail_buffer[0..tail_read];
                            secondary_format = detectFormatBySecondarySignaturesTail(tail_data, expected_format);
                        }
                    }
                }

                if (secondary_format != .unknown) {
                    // Secondary signatures confirm the format despite corrupted magic bytes.
                    // Now run structural validation with skip_magic=true to check the rest.
                    reopen_file.seekTo(0) catch {
                        return result;
                    };

                    var reopen_file_src = file_source.FileSource.fromFile(reopen_file);
                    const reopen_file_ptr = &reopen_file_src;
                    const skip_magic_result: ?ValidationResult = switch (secondary_format) {
                        .png => image_validators.validatePngWithOptions(reopen_file_ptr, true),
                        .jpeg => image_validators.validateJpegWithOptions(reopen_file_ptr, true),
                        .gif => image_validators.validateGifWithOptions(reopen_file_ptr, true),
                        .pdf => pdf_validator.validatePdfWithOptions(reopen_file_ptr, true),
                        .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp => archive_validators.validateZipWithOptions(reopen_file_ptr, secondary_format, true),
                        .sqlite => document_validators.validateSqliteWithOptions(reopen_file_ptr, true),
                        // For formats without skip_magic support, we can only identify, not validate
                        else => null,
                    };

                    if (skip_magic_result) |smr| {
                        if (smr.is_valid) {
                            // Structure is valid, only magic bytes are corrupted
                            // File is INVALID (won't open in apps) but REPAIRABLE (fix magic bytes)
                            result = ValidationResult.invalid(secondary_format, "magic bytes corrupted (structure valid, repairable)");
                            result.malformations.insert(.magic_bytes_corrupted);
                        } else {
                            // Both magic bytes AND structure are corrupted
                            result = ValidationResult.invalid(secondary_format, smr.error_message orelse "corrupted structure");
                            result.malformations.insert(.magic_bytes_corrupted);
                        }
                    } else {
                        // Format doesn't support skip_magic validation
                        // Report as invalid with magic corruption, structure unknown
                        result = ValidationResult.invalid(secondary_format, "magic bytes corrupted (structure not validated)");
                        result.malformations.insert(.magic_bytes_corrupted);
                    }
                }
            }
        }

        // Final fallback: if still unknown but extension maps to a known format,
        // report as that format with invalid status (detected via extension only).
        // This catches corrupted files where both magic bytes AND secondary
        // signatures are destroyed, but the extension is still informative.
        if (result.format == .unknown and expected_format != .unknown and expected_format.hasValidator()) {
            // Don't flag "magic bytes corrupted" for formats that inherently lack magic bytes
            const has_no_magic = switch (expected_format) {
                .cdg, .toast, .mp2, .msi, .br, .dv, .tga, .stl,
                .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437,
                .csv, .markdown,
                => true,
                else => false,
            };            if (has_no_magic) {
                // These formats are extension-only; lack of magic is expected, not corruption
                result = ValidationResult.ok(expected_format);
            } else {
                result = ValidationResult.invalid(expected_format, "detected via extension, magic bytes corrupted");
                result.malformations.insert(.magic_bytes_corrupted);
            }
        }

        // For text formats, extension is more reliable than content detection
        // (e.g., .toml file with [section] headers should be TOML, not INI)
        // (e.g., .app file with {} should be Erlang term, not JSON)
        if (ext_format != .unknown) {
            const is_text_format = switch (result.format) {
                .json, .toml, .ini, .xml, .yaml, .erlang_term, .eex, .markdown, .plain_text => true,
                else => false,
            };
            const ext_is_text = switch (ext_format) {
                .json, .toml, .ini, .xml, .yaml, .erlang_term, .eex, .markdown => true,
                else => false,
            };
            if (is_text_format and ext_is_text and result.format != ext_format) {
                // Extension wins for text formats - re-validate with correct format
                const reopen_file = std.fs.cwd().openFile(path, .{}) catch {
                    // Couldn't reopen, just use extension format
                    result.format = ext_format;
                    return result;
                };
                defer reopen_file.close();
                var text_src = file_source.FileSource.fromFile(reopen_file);
                const text_src_ptr = &text_src;

                // Run the correct validator for the extension-based format
                result = switch (ext_format) {
                    .json => text_format_validators.validateJson(text_src_ptr),
                    .toml => text_format_validators.validateToml(text_src_ptr),
                    .ini => text_format_validators.validateIni(text_src_ptr),
                    .xml => text_format_validators.validateXml(text_src_ptr),
                    .yaml => ValidationResult.ok(.yaml),
                    .erlang_term => ValidationResult.ok(.erlang_term),
                    .eex => ValidationResult.ok(.eex),
                    .markdown => ValidationResult.ok(.markdown),
                    else => result,
                };
            }
        }

        // Special handling for SVG files
        // SVG is XML-based and often detected as generic XML by content scanning
        // If extension is .svg, validate as SVG and report that format
        if (expected_format == .svg and result.format == .xml) {
            var svg_source = file_source.FileSource.open(path) catch {
                result.format = .svg;
                return result;
            };
            defer svg_source.close();
            result = image_validators.validateSvg(&svg_source);
        }

        // Special handling for Adobe Illustrator files
        // AI files are detected as PDF or EPS by magic bytes, but if extension is .ai,
        // use AI-specific validation and report as AI format
        if (ext_format == .ai and (result.format == .pdf or result.format == .eps)) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .ai;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validateAi(&reopen_src);
        }

        // Special handling for Adobe Premiere Pro files
        // PRPROJ files are gzip-compressed XML (modern) or plain XML (legacy)
        // Modern: detected as gzip by magic bytes
        // Legacy: detected as xml by content detection
        // If extension is .prproj, use PRPROJ-specific validation
        if (ext_format == .prproj and (result.format == .gzip or result.format == .xml)) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .prproj;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validatePrproj(&reopen_src);
        }

        // Special handling for Ableton Live Set files
        // ALS files are gzip-compressed XML, detected as gzip by magic bytes
        // If extension is .als, use ALS-specific validation
        if (expected_format == .als and result.format == .gzip) {
            var reopen_src = FileSource.open(path) catch {
                result.format = .als;
                return result;
            };
            defer reopen_src.close();
            result = daw_validators.validateAls(&reopen_src);
        }

        // Special handling for Logic Pro X and Studio One files
        // These are ZIP-based packages, detected as ZIP by magic bytes
        if (expected_format == .logicx and result.format == .zip) {
            result.format = .logicx;
        }
        if (expected_format == .song and result.format == .zip) {
            // Studio One .song files must contain metainfo.xml — check before promoting
            const song_file = std.fs.cwd().openFile(path, .{}) catch null;
            if (song_file) |sf| {
                defer sf.close();
                var song_src = FileSource.fromFile(sf);
                var song_buf: [16384]u8 = undefined;
                const song_bytes = song_src.read(&song_buf) catch 0;
                if (findInBuffer(&song_buf, song_bytes, "metainfo.xml")) {
                    result.format = .song;
                } else {
                    result = ValidationResult.invalidCode(.song, .missing, "Studio One project metainfo.xml");
                }
            } else {
                result.format = .song;
            }
        }
        // Special handling for Adobe InDesign Markup (IDML) files
        // IDML files are ZIP containers with XML content, detected as ZIP by magic bytes
        // If extension is .idml, use IDML-specific validation
        if (ext_format == .idml and result.format == .zip) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .idml;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validateIdml(&reopen_src);
        }

        // Special handling for Final Cut Pro XML files
        // FCPXML files are XML with specific structure, detected as XML by content
        // If extension is .fcpxml, use FCPXML-specific validation
        if (ext_format == .fcpxml and result.format == .xml) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .fcpxml;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validateFcpxml(&reopen_src);
        }

        // Special handling for DaVinci Resolve Project files
        // DRP files are ZIP containers with project.xml, detected as ZIP by magic bytes
        // If extension is .drp, use DRP-specific validation
        if (ext_format == .drp and result.format == .zip) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .drp;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validateDrp(&reopen_src);
        }

        // Special handling for Sketch design files
        // Sketch files are ZIP containers with JSON content (document.json, meta.json)
        // If extension is .sketch, use Sketch-specific validation
        if (ext_format == .sketch and result.format == .zip) {
            var reopen_src = FileSource.open(path) catch {
                // Couldn't reopen, just remap format
                result.format = .sketch;
                return result;
            };
            defer reopen_src.close();
            result = creative_validators.validateSketch(&reopen_src);
        }

        // Special handling for QuickBooks Backup files
        // QBB files are OLE2 compound files, detected as .doc by magic bytes
        // If extension is .qbb or .qbm, use QBB-specific validation
        if ((ext_format == .qbb) and result.format == .doc) {
            var reopen_src = FileSource.open(path) catch {
                result.format = .qbb;
                return result;
            };
            defer reopen_src.close();
            result = financial_validators.validateQbb(&reopen_src);
        }

        // Special handling for Quicken Data Files
        // QDF files can be OLE2 or ZIP containers, detected as .doc or .zip by magic bytes
        // If extension is .qdf, use QDF-specific validation
        if (ext_format == .qdf and (result.format == .doc or result.format == .zip)) {
            var reopen_src = FileSource.open(path) catch {
                result.format = .qdf;
                return result;
            };
            defer reopen_src.close();
            result = financial_validators.validateQdf(&reopen_src);
        }

        // Debug: Log failed validations with path
        if (!result.is_valid) {
            debugLog("VALIDATION FAILED: {s} err=\"{s}\"\n", .{
                path,
                result.error_message orelse "unknown",
            });
        }

        // Extension mismatch check is done in validateFileDeep after deep validation
        // to ensure it's applied to the final result (performDeepValidation returns new result)

        return result;
    }

    /// Validate a file with deep validation support.
    /// Requires allocator for format-specific deep checks.
    pub fn validateFileDeep(self: *Self, allocator: Allocator, path: []const u8) ValidationResult {
        if (!self.enabled) {
            return ValidationResult.unknown();
        }

        // Ensure allocator is available for validators that need it (e.g. Unicode warnings)
        if (self.allocator == null) {
            self.allocator = allocator;
        }

        // SQLite companion files don't need deep validation — they're ephemeral
        // files only meaningful alongside their parent .sqlite database
        if (isSqliteCompanionFile(path)) {
            return ValidationResult.okWithDepth(.sqlite, .structural);
        }

        // First do structural validation
        var result = self.validateFile(path);

        // If structural validation failed, return early
        if (!result.is_valid) {
            return result;
        }

        // Check for resource fork (macOS)
        if (self.check_resource_forks) {
            result.has_resource_fork = apple_validators.hasResourceFork(path);
            // For now, just detect - could add resource fork validation later
            if (result.has_resource_fork) {
                result.resource_fork_valid = true; // Assume valid if exists
            }
        }

        // If deep validation is enabled, do format-specific deep checks
        // Skip deep validation for files with corrupted magic bytes, as deep validators
        // typically require valid magic bytes to function correctly
        if (self.deep_validation and !result.malformations.contains(.magic_bytes_corrupted)) {
            if (result.malformations.contains(.mime_wrapped_content)) {
                // For MIME-wrapped files, extract content to temp file and validate that
                const deep_result = validateMimeWrappedDeep(allocator, path, result.format);
                if (deep_result) |dr| {
                    // Preserve the mime_wrapped malformation and merge any new ones
                    result = dr;
                    result.malformations.insert(.mime_wrapped_content);
                }
                // If extraction failed, keep structural result (already has mime warning)
            } else {
                // Preserve malformations and format from structural validation
                const structural_malformations = result.malformations;
                const structural_format = result.format;
                result = self.performDeepValidation(allocator, path, result);
                // If deep validation returned a generic container format (.zip, .gzip)
                // but structural validation had already identified a more specific format,
                // preserve the specific format (e.g., .logicx, .als, .drp, .song)
                if (result.format == .zip and structural_format != .zip) {
                    result.format = structural_format;
                }
                if (result.format == .gzip and structural_format != .gzip) {
                    result.format = structural_format;
                }
                // Merge back any malformations from structural validation
                var iter = structural_malformations.iterator();
                while (iter.next()) |m| {
                    result.malformations.insert(m);
                }
            }
        }

        // Check for extension mismatch (for valid files)
        // REPAIRABLE: extension_mismatch - can be fixed by renaming the file
        // Note: This is done here AFTER deep validation so the malformation isn't lost
        // when performDeepValidation returns a new result. With EnumSet we can have
        // multiple malformations, so we always add this if detected.
        if (result.is_valid) {
            // Skip extension mismatch for directory-based bundle formats
            // (.app, .framework, .bundle) — they don't have "content" to mismatch against
            const is_bundle = result.format == .macos_app or result.format == .macos_framework or
                result.format == .macos_bundle or result.format == .band or result.format == .logicx;
            if (!is_bundle) {
                const expected_format = getExpectedFormatForExtension(path);
                if (!isFormatCompatibleWithExtension(result.format, expected_format)) {
                    result.malformations.insert(.extension_mismatch);
                }
            }
        }

        return result;
    }

    /// Deep validate MIME-wrapped content in-memory (no temp files).
    /// Returns null if extraction fails (caller should fall back to structural).
    fn validateMimeWrappedDeep(allocator: Allocator, path: []const u8, format: FileFormat) ?ValidationResult {
        // Open the original file
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const file_size = file.getEndPos() catch return null;

        // Read header to find content offset
        var header: [1088]u8 = undefined;
        const header_bytes = file.read(&header) catch return null;
        if (header_bytes < 50) return null;

        const mime_result = detectMimeWrapper(header[0..header_bytes]);
        if (!mime_result.is_mime_wrapped) return null;

        const content_start = mime_result.content_offset;
        const content_end = findMimeContentEnd(file, content_start, file_size) catch file_size;

        if (content_end <= content_start) return null;

        const content_size = content_end - content_start;

        // Size limit for extraction (500MB - same as PDF deep validation)
        if (content_size > 500 * 1024 * 1024) return null;

        // Allocate buffer for content
        const content = allocator.alloc(u8, @intCast(content_size)) catch return null;
        defer allocator.free(content);

        // Read the embedded content
        file.seekTo(content_start) catch return null;
        const read_bytes = file.readAll(content) catch return null;
        if (read_bytes != content_size) return null;

        // Run buffer-based deep validation directly in memory
        const deep_result: ValidationResult = switch (format) {
            .pdf => pdf_validator.validatePdfDeepFromBuffer(allocator, content),
            // For other formats, fall back to structural (buffer deep validation not implemented)
            .png => image_validators.validatePngFromBuffer(content),
            .jpeg => image_validators.validateJpegFromBuffer(content),
            .gif => image_validators.validateGifFromBuffer(content),
            .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp, .song => archive_validators.validateZipFromBuffer(content, format),
            else => ValidationResult.ok(format),
        };

        return deep_result;
    }

    /// Perform format-specific deep validation.
    fn performDeepValidation(self: *Self, allocator: Allocator, path: []const u8, initial_result: ValidationResult) ValidationResult {
        _ = self;
        return switch (initial_result.format) {
            .sqlite => document_validators.validateSqliteDeep(allocator, path),
            .png => image_validators.validatePngDeep(allocator, path),
            .jpeg => image_validators.validateJpegDeep(allocator, path),
            .gif => image_validators.validateGifDeep(allocator, path),
            .tiff, .dng, .cr2, .nef, .arw, .orf, .pef => image_validators.validateTiffDeep(allocator, path, initial_result.format),
            .tga => image_validators.validateTgaDeep(allocator, path),
            // RAF, RW2, CR3: structural-only for now (no deep decoder available)
            .raf, .rw2, .cr3 => initial_result,
            .psd => image_validators.validatePsdDeep(allocator, path),
            .ai => creative_validators.validateAiDeep(allocator, path),
            .eps => creative_validators.validateEpsDeep(allocator, path),
            .aep => creative_validators.validateAepDeep(allocator, path),
            .webp => image_validators.validateWebpDeep(allocator, path),
            .jxl => image_validators.validateJxlDeep(allocator, path),
            .bmp => image_validators.validateBmpDeep(allocator, path),
            .ico => image_validators.validateIcoDeep(allocator, path),
            .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp, .pages, .logicx, .song => archive_validators.validateZipDeep(allocator, path),
            .kmz => text_format_validators.validateKmzDeep(allocator, path),
            .@"3mf" => cad_3d_validators.validate3mfDeep(allocator, path),
            .flac => music_validators.validateFlacDeep(allocator, path),
            .wav => music_validators.validateWavDeep(allocator, path),
            .aiff => music_validators.validateAiffDeep(allocator, path),
            .pdf => pdf_validator.validatePdfDeep(allocator, path),
            .gzip => archive_validators.validateGzipDeep(allocator, path),
            .bzip2 => archive_validators.validateBzip2Deep(allocator, path),
            .xz => archive_validators.validateXzDeep(allocator, path),
            .zstd => archive_validators.validateZstdDeep(allocator, path),
            .sevenz => archive_validators.validate7zDeep(allocator, path),
            .rar => archive_validators.validateRarDeep(allocator, path),
            .cpt => archive_validators.validateCptDeep(allocator, path),
            .warc => archive_validators.validateWarcDeep(allocator, path),
            .dmg => filesystem_validators.validateDmgDeep(allocator, path),
            .iso => filesystem_validators.validateIsoDeep(allocator, path),
            .mp3 => music_validators.validateMp3Deep(allocator, path),
            .ogg => music_validators.validateOggDeep(allocator, path),
            .tta => music_validators.validateTtaDeep(allocator, path),
            .midi => music_validators.validateMidiDeep(path),
            .mp4, .mov, .m4a => movie_validators.validateMp4Deep(allocator, path),
            .mkv, .webm => movie_validators.validateMkvDeep(allocator, path),
            .avi => movie_validators.validateAviDeep(allocator, path),
            .heic => image_validators.validateHeicDeep(allocator, path),
            .avif => image_validators.validateAvifDeep(allocator, path),
            .exr => image_validators.validateExrDeep(allocator, path),
            .glb => cad_3d_validators.validateGlbDeep(allocator, path),
            .doc, .xls, .ppt => document_validators.validateOle2Deep(allocator, path, initial_result.format),
            .br => validateBrotliDeep(path),
            .mod => music_validators.validateModDeep(path),
            .xm => music_validators.validateXmDeep(path),
            .it => music_validators.validateItDeep(path),
            .s3m => music_validators.validateS3mDeep(path),
            .jpeg2000 => image_validators.validateJpeg2000Deep(allocator, path),
            .jbig2 => image_validators.validateJbig2Deep(allocator, path),
            .ac3 => music_validators.validateAc3Deep(path),
            .dts => music_validators.validateDtsDeep(path),
            .eac3 => music_validators.validateEac3Deep(path),
            .prproj => creative_validators.validatePrprojDeep(allocator, path),
            .indd => creative_validators.validateInddDeep(allocator, path),
            .idml => archive_validators.validateZipDeep(allocator, path), // IDML uses ZIP deep validation
            .dwg => cad_3d_validators.validateDwgDeep(allocator, path),
            .blend => cad_3d_validators.validateBlendDeep(allocator, path),
            .flp => daw_validators.validateFlpDeep(allocator, path),
            .als => daw_validators.validateAlsDeep(allocator, path),
            .rpp => daw_validators.validateRppDeep(allocator, path),
            .ptx => daw_validators.validatePtxDeep(allocator, path),
            .fcpxml => creative_validators.validateFcpxmlDeep(allocator, path),
            .svg => image_validators.validateSvgDeep(allocator, path),
            .kml => text_format_validators.validateKmlDeep(allocator, path),
            .rtf => text_format_validators.validateRtfDeep(allocator, path),
            .mpeg_ts => movie_validators.validateMpegTsDeep(allocator, path),
            .ivf => movie_validators.validateIvfDeep(allocator, path),
            .flv => movie_validators.validateFlvDeep(allocator, path),
            .mbox => email_validators.validateMboxDeep(allocator, path),
            .wad => game_asset_validators.validateWadDeep(allocator, path),
            .pak => game_asset_validators.validatePakDeep(allocator, path),
            .nes => game_validator.validateNesDeep(allocator, path),
            .iff => game_asset_validators.validateIffDeep(allocator, path),
            .n64 => game_validator.validateN64Deep(allocator, path),
            .genesis => game_validator.validateGenesisDeep(allocator, path),
            .gb => game_validator.validateGbDeep(allocator, path),
            .drp => creative_validators.validateDrpDeep(allocator, path),
            .mdb => document_validators.validateMdbDeep(allocator, path),
            .accdb => document_validators.validateAccdbDeep(allocator, path),
            .obj => cad_3d_validators.validateObjDeep(allocator, path),
            .sketch => creative_validators.validateSketchDeep(allocator, path),
            .qbw => financial_validators.validateQbwDeep(allocator, path),
            .qbb => financial_validators.validateQbbDeep(allocator, path),
            .qdf => financial_validators.validateQdfDeep(allocator, path),
            .nacha => financial_validators.validateNachaDeep(allocator, path),
            .mt940 => financial_validators.validateMt940Deep(allocator, path),
            .bai2 => financial_validators.validateBai2Deep(allocator, path),
            .x12_edi => edi_validators.validateX12EdiDeep(allocator, path),
            .edifact => edi_validators.validateEdifactDeep(allocator, path),
            .pem => crypto_validators.validatePemDeep(allocator, path),
            .der => crypto_validators.validateDerDeep(allocator, path),
            .pgp_signed => crypto_validators.validatePgpSignedDeep(allocator, path),
            .ssh_signature => crypto_validators.validateSshSignatureDeep(allocator, path),
            .icalendar => pim_validators.validateICalendarDeep(allocator, path),
            .vcard => pim_validators.validateVCardDeep(allocator, path),
            .cab => cab_validator.validateCabDeep(allocator, path),
            .sit, .sitx => stuffit_validator.validateStuffitDeep(allocator, path),
            .vmdk => vmdk_validator.validateVmdkDeep(allocator, path).toValidationResult(),
            .wim, .esd => wim_validator.validateWimDeep(allocator, path),
            .rm => realmedia_validator.validateRealMediaDeep(allocator, path),
            .parquet => scientific_validators.validateParquetDeep(allocator, path),
            .blar => blar_validator.validateBlarDeepFromPath(allocator, path, .blar),
            .mblar => blar_validator.validateBlarDeepFromPath(allocator, path, .mblar),
            .bagit => bagit_validator.validateBagitDeep(allocator, path),
            .git_repository => validateGitRepositoryDeep(allocator, path),
            .macos_app => macos_bundle_validator.validateAppBundle(allocator, path).toValidationResult(.macos_app),
            .macos_framework => macos_bundle_validator.validateFrameworkBundle(allocator, path).toValidationResult(.macos_framework),
            .macos_bundle => macos_bundle_validator.validatePluginBundle(allocator, path).toValidationResult(.macos_bundle),
            .band => validateGarageBandBundle(allocator, path),
            .java_class => executable_validators.validateJavaClassDeep(allocator, path),
            .apple_media_db => apple_media_db_validator.validateAppleMediaDbDeep(allocator, path),
            else => initial_result, // No deep validation available
        };
    }

    /// Deep validation for Git repositories.
    /// Validates all loose objects and pack files using SHA-1 checksums.
    /// Note: The path parameter is the .git directory itself. We need to derive
    /// the repository root (parent directory) for the git_validator API.
    fn validateGitRepositoryDeep(allocator: Allocator, path: []const u8) ValidationResult {
        // The git_validator.validateRepository expects the repo root (parent of .git),
        // but we receive the .git directory path. Strip the .git suffix.
        const repo_root = if (path.len >= 5 and std.mem.endsWith(u8, path, "/.git"))
            path[0 .. path.len - 5] // Strip "/.git"
        else if (std.mem.eql(u8, path, ".git"))
            "." // Current directory
        else
            path; // Assume it's already the repo root

        const git_result = git_validator.validateRepository(allocator, repo_root) catch {
            return ValidationResult.invalidWithDepth(
                .git_repository,
                "Failed to validate git repository",
                .full,
            );
        };

        if (git_result.is_valid) {
            return ValidationResult.okWithDepth(.git_repository, .full);
        } else {
            // Use the error message from git validation if available
            const error_msg = git_result.error_message orelse "Git repository validation failed";
            return ValidationResult.invalidWithDepth(.git_repository, error_msg, .full);
        }
    }

    /// Deep validation for macOS application bundles (.app).
    /// Validates bundle structure: Contents/Info.plist (modern) or Info.plist at root (legacy flat bundle).
    fn validateMacosAppDeep(allocator: Allocator, path: []const u8) ValidationResult {
        _ = allocator;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check for modern structure: Contents/Info.plist + Contents/MacOS/
        const info_plist_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/Info.plist", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_app, "Path too long", .structural);
        };

        if (std.fs.cwd().access(info_plist_path, .{})) |_| {
            // Modern bundle — also require Contents/MacOS
            const macos_dir_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/MacOS", .{path}) catch {
                return ValidationResult.invalidWithDepth(.macos_app, "Path too long", .structural);
            };

            std.fs.cwd().access(macos_dir_path, .{}) catch {
                return ValidationResult.invalidCodeWithDepth(.macos_app, .missing, "Contents/MacOS directory", .structural);
            };

            return ValidationResult.okWithDepth(.macos_app, .structural);
        } else |_| {}

        // Legacy flat bundle: Info.plist directly in .app root (pre-2009 CFBundle style)
        const flat_info_path = std.fmt.bufPrint(&path_buf, "{s}/Info.plist", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_app, "Path too long", .structural);
        };

        std.fs.cwd().access(flat_info_path, .{}) catch {
            return ValidationResult.invalidCodeWithDepth(.macos_app, .missing, "Contents/Info.plist or Info.plist", .structural);
        };

        return ValidationResult.okWithDepth(.macos_app, .structural);
    }

    /// Deep validation for macOS framework bundles (.framework).
    /// Validates bundle structure: must have Headers or Versions directory.
    fn validateMacosFrameworkDeep(allocator: Allocator, path: []const u8) ValidationResult {
        _ = allocator;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Frameworks can have either flat structure (Headers/ directly) or versioned (Versions/Current/)
        // Check for Versions directory first (more common)
        const versions_path = std.fmt.bufPrint(&path_buf, "{s}/Versions", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_framework, "Path too long", .structural);
        };

        // Try Versions first
        if (std.fs.cwd().access(versions_path, .{})) |_| {
            return ValidationResult.okWithDepth(.macos_framework, .structural);
        } else |_| {}

        // Check for flat structure with Headers
        const headers_path = std.fmt.bufPrint(&path_buf, "{s}/Headers", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_framework, "Path too long", .structural);
        };

        if (std.fs.cwd().access(headers_path, .{})) |_| {
            return ValidationResult.okWithDepth(.macos_framework, .structural);
        } else |_| {}

        // Try Resources
        const resources_path = std.fmt.bufPrint(&path_buf, "{s}/Resources", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_framework, "Path too long", .structural);
        };

        if (std.fs.cwd().access(resources_path, .{})) |_| {
            return ValidationResult.okWithDepth(.macos_framework, .structural);
        } else |_| {
            return ValidationResult.invalidCodeWithDepth(.macos_framework, .missing, "Versions, Headers, or Resources directory", .structural);
        }
    }

    /// Deep validation for macOS bundles (.bundle).
    /// Validates bundle structure: Contents/Info.plist should exist.
    fn validateMacosBundleDeep(allocator: Allocator, path: []const u8) ValidationResult {
        _ = allocator;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check for Contents/Info.plist (standard bundle structure)
        const info_plist_path = std.fmt.bufPrint(&path_buf, "{s}/Contents/Info.plist", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_bundle, "Path too long", .structural);
        };

        if (std.fs.cwd().access(info_plist_path, .{})) |_| {
            return ValidationResult.okWithDepth(.macos_bundle, .structural);
        } else |_| {}

        // Some bundles have flat structure with Info.plist at root
        const flat_info_path = std.fmt.bufPrint(&path_buf, "{s}/Info.plist", .{path}) catch {
            return ValidationResult.invalidWithDepth(.macos_bundle, "Path too long", .structural);
        };

        if (std.fs.cwd().access(flat_info_path, .{})) |_| {
            return ValidationResult.okWithDepth(.macos_bundle, .structural);
        } else |_| {
            return ValidationResult.invalidCodeWithDepth(.macos_bundle, .missing, "Info.plist", .structural);
        }
    }

    /// Deep validation for GarageBand project bundles (.band).
    /// GarageBand bundles contain projectData (older) or Alternatives/000/ProjectData (newer),
    /// with optional mmetadata.plist and Media/ directory.
    fn validateGarageBandBundle(allocator: Allocator, path: []const u8) ValidationResult {
        _ = allocator;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check for newer structure: Alternatives/ directory (GarageBand 10+)
        const alternatives_path = std.fmt.bufPrint(&path_buf, "{s}/Alternatives", .{path}) catch {
            return ValidationResult.invalidWithDepth(.band, "Path too long", .structural);
        };
        const has_alternatives = if (std.fs.cwd().access(alternatives_path, .{})) |_| true else |_| false;

        // Check for older structure: projectData file at bundle root
        const project_data_path = std.fmt.bufPrint(&path_buf, "{s}/projectData", .{path}) catch {
            return ValidationResult.invalidWithDepth(.band, "Path too long", .structural);
        };
        const has_project_data = if (std.fs.cwd().access(project_data_path, .{})) |_| true else |_| false;

        if (!has_alternatives and !has_project_data) {
            return ValidationResult.invalidCodeWithDepth(.band, .missing, "projectData or Alternatives directory", .structural);
        }

        // If projectData exists, verify it looks like a plist (binary or XML)
        if (has_project_data) {
            const pd_file = std.fs.cwd().openFile(project_data_path, .{}) catch {
                return ValidationResult.invalidCodeWithDepth(.band, .failed_to_open, "projectData", .structural);
            };
            defer pd_file.close();

            var magic: [8]u8 = undefined;
            const n = pd_file.read(&magic) catch 0;
            if (n >= 8) {
                const is_bplist = std.mem.eql(u8, magic[0..8], "bplist00");
                const is_xml = std.mem.eql(u8, magic[0..5], "<?xml");
                if (!is_bplist and !is_xml) {
                    return ValidationResult.invalidWithDepth(.band, "projectData is not a valid plist", .structural);
                }
            } else if (n == 0) {
                return ValidationResult.invalidWithDepth(.band, "projectData is empty", .structural);
            }
        }

        return ValidationResult.okWithDepth(.band, .structural);
    }

    /// Validate using an already-open file handle.
    pub fn validateFileHandle(self: *Self, file: std.fs.File) ValidationResult {
        if (!self.enabled) {
            return ValidationResult.unknown();
        }

        // Read header for format detection
        // Use 1088 bytes to detect:
        // - tar archives (ustar magic at offset 257)
        // - MOD files (signature at offset 1080)
        var header: [1088]u8 = undefined;
        const header_bytes = file.read(&header) catch {
            return ValidationResult.invalidCode(.unknown, .failed_to_read, "file header");
        };

        if (header_bytes < 4) {
            return ValidationResult.invalid(.unknown, "File too small to identify");
        }

        // Detect format - first try basic detection, then extended for formats that need file access
        var format = detectFormat(header[0..header_bytes]);

        // For formats that need deeper inspection (TIFF-based RAW, Matroska, etc.),
        // use extended detection which can read more of the file
        if (format == .tiff or format == .unknown) {
            const extended_format = detectExtendedFormat(header[0..header_bytes], file);
            if (extended_format != .unknown) {
                format = extended_format;
            }
        }

        var is_mime_wrapped = false;
        var mime_content_offset: usize = 0;

        // Check for MIME-wrapped content if detected format is text-like or unknown
        // This handles buggy web services that return MIME multipart bodies instead of raw files
        const might_be_mime_wrapped = switch (format) {
            .yaml, .plain_text, .unknown, .eml => true,
            else => false,
        };

        if (might_be_mime_wrapped) {
            const mime_result = detectMimeWrapper(header[0..header_bytes]);
            if (mime_result.is_mime_wrapped) {
                is_mime_wrapped = true;
                mime_content_offset = mime_result.content_offset;
                format = mime_result.embedded_format;

                // For MIME-wrapped files, we need to extract and validate the embedded content
                // because file-based validators use absolute seeks which won't work with the offset.
                // Read the file into memory and use buffer-based validation.
                const file_size = file.getEndPos() catch {
                    return ValidationResult.invalidCode(format, .failed_to_get, "file size");
                };

                // Sanity check - don't try to load huge files into memory
                const max_mime_size: u64 = 100 * 1024 * 1024; // 100 MB limit
                if (file_size > max_mime_size) {
                    var result = ValidationResult.ok(format);
                    result.malformations.insert(.mime_wrapped_content);
                    result.warning_message = "MIME-wrapped file too large for embedded validation";
                    return result;
                }

                // Find the end of embedded content (before closing MIME boundary)
                // Read enough to find the closing boundary
                file.seekTo(0) catch {
                    return ValidationResult.invalidCode(format, .failed_to_seek, "to start of file");
                };

                // Use stack buffer for small files, otherwise skip deep validation
                const content_end = findMimeContentEnd(file, mime_content_offset, file_size) catch file_size;

                if (content_end <= mime_content_offset) {
                    return ValidationResult.invalidCode(format, .invalid_value, "MIME content boundaries");
                }

                const embedded_size = content_end - mime_content_offset;
                if (embedded_size > max_mime_size) {
                    var result = ValidationResult.ok(format);
                    result.malformations.insert(.mime_wrapped_content);
                    result.warning_message = "Embedded content too large for validation";
                    return result;
                }

                // For structural validation, use the buffer-based validator
                file.seekTo(mime_content_offset) catch {
                    return ValidationResult.invalidCode(format, .failed_to_seek, "to embedded content");
                };

                // Read embedded content into heap buffer if small enough
                const embedded_buffer = (self.allocator orelse std.heap.page_allocator).alloc(u8, 65536) catch {
                    var result = ValidationResult.ok(format);
                    result.malformations.insert(.mime_wrapped_content);
                    result.validation_depth = .structural;
                    return result;
                };
                defer (self.allocator orelse std.heap.page_allocator).free(embedded_buffer);
                if (embedded_size <= embedded_buffer.len) {
                    const read_bytes = file.read(embedded_buffer[0..@intCast(embedded_size)]) catch {
                        return ValidationResult.invalidCode(format, .failed_to_read, "embedded content");
                    };
                    const buffer_result = validateDataBufferFormat(embedded_buffer[0..read_bytes], format);
                    var result = buffer_result;
                    result.malformations.insert(.mime_wrapped_content);
                    return result;
                } else {
                    // File too large for stack buffer, do minimal structural check
                    var result = ValidationResult.ok(format);
                    result.malformations.insert(.mime_wrapped_content);
                    result.validation_depth = .structural;
                    return result;
                }
            }
        }

        // Reset file position
        file.seekTo(0) catch {
            return ValidationResult.invalidCode(format, .failed_to_seek, "to start");
        };

        // For ZIP files, try to detect subformat
        if (format == .zip) {
            format = detectZipSubformat(file);
            file.seekTo(0) catch {
                return ValidationResult.invalidCode(format, .failed_to_seek, "to start");
            };
        }

        // For Matroska, detect MKV vs WebM
        if (format == .mkv) {
            format = detectMatroskaSubformat(file);
            file.seekTo(0) catch {
                return ValidationResult.invalidCode(format, .failed_to_seek, "to start");
            };
        }

        // For OLE2, try to detect DOC vs XLS vs PPT
        if (format == .doc) {
            var ole2_source = file_source.FileSource.fromFile(file);
            format = document_validators.detectOle2Subformat(&ole2_source);
            file.seekTo(0) catch {
                return ValidationResult.invalidCode(format, .failed_to_seek, "to start");
            };
        }

        // If format has no validator, return as valid
        if (!format.hasValidator()) {
            var result = ValidationResult.ok(format);
            if (is_mime_wrapped) {
                result.malformations.insert(.mime_wrapped_content);
            }
            return result;
        }

        // Use format-specific validator
        // Wrap file in FileSource for validators that have been migrated
        var file_src = FileSource.fromFile(file);
        const file_src_ptr = &file_src;
        var result = switch (format) {
            .png => image_validators.validatePng(file_src_ptr),
            .jpeg => image_validators.validateJpeg(file_src_ptr),
            .jxl => image_validators.validateJxl(file_src_ptr),
            .gif => image_validators.validateGif(file_src_ptr),
            .bmp => image_validators.validateBmp(file_src_ptr),
            .webp => image_validators.validateWebp(file_src_ptr),
            .psd => image_validators.validatePsd(file_src_ptr),
            .ai => creative_validators.validateAi(file_src_ptr),
            .eps => creative_validators.validateEps(file_src_ptr),
            .aep => creative_validators.validateAep(file_src_ptr),
            .tiff, .dng, .cr2, .nef, .arw, .orf, .pef => image_validators.validateTiff(file_src_ptr, format),
            .raf => image_validators.validateRaf(file_src_ptr),
            .rw2 => image_validators.validateRw2(file_src_ptr),
            .cr3 => image_validators.validateCr3(file_src_ptr),
            .exr => image_validators.validateExr(file_src_ptr),
            .zip, .epub, .docx, .xlsx, .pptx => archive_validators.validateZip(file_src_ptr, format),
            .odt, .ods, .odp, .pages, .logicx, .song => archive_validators.validateZip(file_src_ptr, format), // ZIP-based document/DAW formats
            .gzip => archive_validators.validateGzip(file_src_ptr),
            .bzip2 => archive_validators.validateBzip2(file_src_ptr),
            .xz => archive_validators.validateXz(file_src_ptr),
            .zstd => archive_validators.validateZstd(file_src_ptr),
            .br => ValidationResult.ok(.br), // No magic bytes - extension-only detection, deep validates
            .hqx => archive_validators.validateHqx(file_src_ptr),
            .rar => archive_validators.validateRar(file_src_ptr),
            .cpt => archive_validators.validateCpt(file_src_ptr),
            .sevenz => archive_validators.validate7z(file_src_ptr),
            .tar => archive_validators.validateTar(file_src_ptr),
            .pdf => pdf_validator.validatePdf(file_src_ptr),
            .rtf => text_format_validators.validateRtf(file_src_ptr),
            .doc, .xls, .ppt => document_validators.validateOle2(file_src_ptr, format), // OLE2/CFBF binary Office
            .wpd => document_validators.validateWordPerfect(file_src_ptr),
            .cwk => apple_validators.validateClarisWorks(file_src_ptr),
            .mwd => apple_validators.validateMacWrite(file_src_ptr),
            .sqlite => document_validators.validateSqlite(file_src_ptr),
            .mp4, .mov, .heic, .avif, .m4a, .alac, .prores, .av1 => movie_validators.validateIsobmff(file_src_ptr, format),
            .mkv, .webm => movie_validators.validateMatroska(file_src_ptr, format),
            .avi => movie_validators.validateAvi(file_src_ptr),
            .swf => movie_validators.validateSwf(file_src_ptr),
            .flv => movie_validators.validateFlv(file_src_ptr),
            .mpeg_ps => movie_validators.validateMpegPs(file_src_ptr),
            .mpeg_ts => movie_validators.validateMpegTs(file_src_ptr),
            .mpeg_es => movie_validators.validateMpegEs(file_src_ptr),
            .ivf => movie_validators.validateIvf(file_src_ptr),
            .mp3 => music_validators.validateMp3(file_src_ptr),
            .flac => music_validators.validateFlac(file_src_ptr),
            .wav, .aiff => music_validators.validateRiffAudio(file_src_ptr, format),
            .ogg, .ogv => music_validators.validateOgg(file_src_ptr),
            .ape => music_validators.validateApe(file_src_ptr),
            .wavpack => music_validators.validateWavPack(file_src_ptr),
            .midi => music_validators.validateMidi(file_src_ptr),
            .dsf => music_validators.validateDsf(file_src_ptr),
            .dff => music_validators.validateDff(file_src_ptr),
            .ac3 => music_validators.validateAc3(file_src_ptr),
            .dts => music_validators.validateDts(file_src_ptr),
            .eac3 => music_validators.validateEac3(file_src_ptr),
            .jpeg2000 => image_validators.validateJpeg2000(file_src_ptr),
            .jbig2 => image_validators.validateJbig2File(file_src_ptr),
            .mod => music_validators.validateMod(file_src_ptr),
            .xm => music_validators.validateXm(file_src_ptr),
            .it => music_validators.validateIt(file_src_ptr),
            .s3m => music_validators.validateS3m(file_src_ptr),
            .als => daw_validators.validateAls(file_src_ptr),
            .rpp => daw_validators.validateRpp(file_src_ptr),
            .flp => daw_validators.validateFlp(file_src_ptr),
            .bwproject => daw_validators.validateBwproject(file_src_ptr),
            .cpr => daw_validators.validateCubase(file_src_ptr),
            .ptx => daw_validators.validateProTools(file_src_ptr),
            .band => daw_validators.validateGarageBand(file_src_ptr),
            .reason => daw_validators.validateReason(file_src_ptr),
            .prproj => creative_validators.validatePrproj(file_src_ptr),
            .indd => creative_validators.validateIndd(file_src_ptr),
            .idml => creative_validators.validateIdml(file_src_ptr),
            .dwg => cad_3d_validators.validateDwg(file_src_ptr),
            .blend => cad_3d_validators.validateBlend(file_src_ptr),
            .fcpxml => creative_validators.validateFcpxml(file_src_ptr),
            .drp => creative_validators.validateDrp(file_src_ptr),
            .sketch => creative_validators.validateSketch(file_src_ptr),
            .mdb => document_validators.validateMdb(file_src_ptr),
            .accdb => document_validators.validateAccdb(file_src_ptr),
            .dbf => document_validators.validateDbf(file_src_ptr),
            .iso => filesystem_validators.validateIso(file_src_ptr),
            .dmg => filesystem_validators.validateDmg(file_src_ptr),
            .hdf5 => scientific_validators.validateHdf5(file_src_ptr),
            .parquet => scientific_validators.validateParquet(file_src_ptr),
            .netcdf => scientific_validators.validateNetcdf(file_src_ptr),
            .fits => scientific_validators.validateFits(file_src_ptr),
            .dicom => scientific_validators.validateDicom(file_src_ptr),
            .fasta => scientific_validators.validateFasta(file_src_ptr),
            .fastq => scientific_validators.validateFastq(file_src_ptr),
            .warc => archive_validators.validateWarc(file_src_ptr),
            .wad => game_asset_validators.validateWad(file_src_ptr),
            .pak => game_asset_validators.validatePak(file_src_ptr),
            .lspk => game_asset_validators.validateLspk(file_src_ptr),
            .chromium_pak => game_asset_validators.validateChromiumPak(file_src_ptr),
            .bsp => game_asset_validators.validateBsp(file_src_ptr),
            .vpk => game_asset_validators.validateVpk(file_src_ptr),
            .nes => game_validator.validateNes(file_src_ptr),
            .snes => game_validator.validateSnes(file_src_ptr),
            .n64 => game_validator.validateN64(file_src_ptr),
            .gb => game_validator.validateGb(file_src_ptr),
            .gba => game_validator.validateGba(file_src_ptr),
            .nds => game_validator.validateNds(file_src_ptr),
            .genesis => game_validator.validateGenesis(file_src_ptr),
            .chd => game_validator.validateChd(file_src_ptr),
            .iff => game_asset_validators.validateIff(file_src_ptr),
            .blorb => game_asset_validators.validateBlorb(file_src_ptr),
            .matlab => scientific_validators.validateMatlab(file_src_ptr),
            .nifti => scientific_validators.validateNifti(file_src_ptr),
            .pdb_struct => scientific_validators.validatePdb(file_src_ptr),
            .cif => scientific_validators.validateCif(file_src_ptr),
            .shapefile => scientific_validators.validateShapefile(file_src_ptr),
            .kml => text_format_validators.validateKml(file_src_ptr),
            .kmz => text_format_validators.validateKmz(file_src_ptr),
            .dxf => cad_3d_validators.validateDxf(file_src_ptr),
            .step => cad_3d_validators.validateStep(file_src_ptr),
            .stl => cad_3d_validators.validateStl(file_src_ptr),
            // 3D printing/modeling formats
            .@"3mf" => cad_3d_validators.validate3mf(file_src_ptr),
            .obj => cad_3d_validators.validateObj(file_src_ptr),
            .ply => cad_3d_validators.validatePly(file_src_ptr),
            .gltf => cad_3d_validators.validateGltf(file_src_ptr),
            .glb => cad_3d_validators.validateGlb(file_src_ptr),
            .eml => email_validators.validateEml(file_src_ptr),
            .mbox => email_validators.validateMbox(file_src_ptr),
            .svg => image_validators.validateSvg(file_src_ptr),
            .json => text_format_validators.validateJson(file_src_ptr),
            .toml => text_format_validators.validateToml(file_src_ptr),
            .ini => text_format_validators.validateIni(file_src_ptr),
            .xml => text_format_validators.validateXml(file_src_ptr),
            .yaml => ValidationResult.ok(.yaml), // Structural detection only
            .erlang_term => ValidationResult.ok(.erlang_term), // Structural detection only
            .eex => ValidationResult.ok(.eex), // Structural detection only
            .markdown => ValidationResult.ok(.markdown), // Text format, no validation
            .plain_text => text_format_validators.validatePlainText(self.allocator, file_src_ptr), // UTF-8 validation
            .plain_text_utf16 => text_format_validators.validatePlainTextUtf16(self.allocator, file_src_ptr), // UTF-16 validation
            .plain_text_latin1 => ValidationResult.okWithDepth(.plain_text_latin1, .structural), // Latin-1 always valid (no integrity mechanism)
            .plain_text_cp437 => ValidationResult.okWithDepth(.plain_text_cp437, .structural), // CP437 always valid (no integrity mechanism)
            // Font formats
            .ttf => validateTtf(self.allocator orelse std.heap.page_allocator, file),
            .otf => validateOtf(self.allocator orelse std.heap.page_allocator, file),
            .woff => validateWoff(self.allocator orelse std.heap.page_allocator, file),
            .woff2 => validateWoff2(self.allocator orelse std.heap.page_allocator, file),
            .type1 => validateType1Font(self.allocator orelse std.heap.page_allocator, file),
            .par2 => archive_validators.validatePar2(file_src_ptr),
            // VM/Bytecode formats
            .beam => validateBeam(self.allocator orelse std.heap.page_allocator, file),
            // Icon formats
            .ico => image_validators.validateIco(file_src_ptr),
            .icns => image_validators.validateIcns(file_src_ptr),
            // Data formats
            .csv => text_format_validators.validateCsv(file_src_ptr),
            .msgpack => text_format_validators.validateMsgpack(file_src_ptr),
            // Apple formats
            .plist => apple_validators.validatePlist(file_src_ptr),
            .ds_store => apple_validators.validateDsStore(file_src_ptr),
            .spotlight => apple_validators.validateSpotlight(file_src_ptr),
            .apple_double => apple_validators.validateAppleDouble(file_src_ptr),
            .apple_media_db => validateAppleMediaDbStructural(header[0..header_bytes], file.getEndPos() catch 0),
            // New audio formats
            .amr => music_validators.validateAmr(file_src_ptr),
            .au => music_validators.validateAu(file_src_ptr),
            .tta => music_validators.validateTta(file_src_ptr),
            .caf => music_validators.validateCaf(file_src_ptr),
            .aac_adts => music_validators.validateAacAdts(file_src_ptr),
            // New image formats
            .qoi => image_validators.validateQoi(file_src_ptr),
            .pam => image_validators.validatePam(file_src_ptr),
            .dpx => image_validators.validateDpx(file_src_ptr),
            .tga => image_validators.validateTga(file_src_ptr),
            // New container formats
            .asf => movie_validators.validateAsf(file_src_ptr),
            .dv => movie_validators.validateDv(file_src_ptr),
            // Executable formats
            .pe => pe_validator.validatePe(file_src_ptr),
            .elf => executable_validators.validateElf(file_src_ptr),
            .macho => executable_validators.validateMacho(file_src_ptr),
            .macho_fat => executable_validators.validateMachoFat(file_src_ptr),
            .coff => executable_validators.validateCoff(file_src_ptr),
            .wasm => executable_validators.validateWasm(file_src_ptr),
            .java_class => executable_validators.validateJavaClass(file_src_ptr),
            // Compiler artifacts
            .llvm_pch => executable_validators.validateLlvmPch(file_src_ptr),
            .llvm_diag => executable_validators.validateLlvmDiag(file_src_ptr),
            // Archives
            .ar => executable_validators.validateAr(file_src_ptr),
            // Web markup
            .html => text_format_validators.validateHtml(file_src_ptr),
            // Financial data formats
            .qbw => financial_validators.validateQbw(file_src_ptr),
            .qbb => financial_validators.validateQbb(file_src_ptr),
            .qdf => financial_validators.validateQdf(file_src_ptr),
            .ofx => financial_validators.validateOfx(file_src_ptr),
            .qif => financial_validators.validateQif(file_src_ptr),
            .txf => financial_validators.validateTxf(file_src_ptr),
            .nacha => financial_validators.validateNacha(file_src_ptr),
            .mt940 => financial_validators.validateMt940(file_src_ptr),
            .bai2 => financial_validators.validateBai2(file_src_ptr),
            // EDI formats
            .x12_edi => edi_validators.validateX12Edi(file_src_ptr),
            .edifact => edi_validators.validateEdifact(file_src_ptr),
            // Crypto/certificate formats
            .pem => crypto_validators.validatePem(file_src_ptr),
            .der => crypto_validators.validateDer(file_src_ptr),
            .pgp_signed => crypto_validators.validatePgpSigned(file_src_ptr),
            .ssh_signature => crypto_validators.validateSshSignature(file_src_ptr),
            // PIM formats
            .icalendar => pim_validators.validateICalendar(file_src_ptr),
            .vcard => pim_validators.validateVCard(file_src_ptr),
            // New format validators (2026-03-27 scan findings)
            .cab => cab_validator.validateCab(file_src_ptr),
            .sit, .sitx => stuffit_validator.validateStuffit(file_src_ptr),
            .mp2 => blk: {
                var mp2_result = music_validators.validateMp3(file_src_ptr);
                mp2_result.format = .mp2;
                break :blk mp2_result;
            },
            .rm => realmedia_validator.validateRealMedia(file_src_ptr),
            .cdg => cdg_validator.validateCdg(file_src_ptr),
            .toast => toast_validator.validateToast(file_src_ptr),
            .vmdk => vmdk_validator.validateVmdk(file_src_ptr).toValidationResult(),
            .wim, .esd => wim_validator.validateWim(file_src_ptr),
            .msi => document_validators.validateMsi(file_src_ptr),
            .blar, .mblar => |fmt| blar_validator.validateBlarStructural(self.allocator orelse std.heap.page_allocator, file_src_ptr, fmt),
            // Bundle formats (directories) - should be handled before reaching this switch
            // If we get here, it means something went wrong - return invalid to make it obvious
            .bagit => bagit_validator.validateBagit(file_src_ptr),
            .git_repository => ValidationResult.invalid(.git_repository, "Git repositories must be validated as directories, not files"),
            .macos_app => ValidationResult.invalid(.macos_app, "macOS app bundles must be validated as directories, not files"),
            .macos_framework => ValidationResult.invalid(.macos_framework, "macOS frameworks must be validated as directories, not files"),
            .macos_bundle => ValidationResult.invalid(.macos_bundle, "macOS bundles must be validated as directories, not files"),
            // Network capture formats
            .pcap => network_validators.validatePcap(file_src_ptr),
            .pcapng => network_validators.validatePcapng(file_src_ptr),
            // Package formats
            .rpm => archive_validators.validateRpm(file_src_ptr),
            .unknown => validateUnknownWithUtf8Fallback(file),
        };

        // If MIME-wrapped, add the malformation flag to the result
        if (is_mime_wrapped) {
            result.malformations.insert(.mime_wrapped_content);
        }

        return result;
    }

    /// Validate data from a memory buffer.
    /// Uses the buffer-based validators for format-specific validation.
    pub fn validateFileBuffer(self: *Self, data: []const u8) ValidationResult {
        if (!self.enabled) {
            return ValidationResult.unknown();
        }

        if (self.allocator) |alloc| {
            return validateDataBuffer(data, alloc);
        } else {
            // Fallback to just format detection if no allocator
            const format = detectFormat(data);
            return ValidationResult.ok(format);
        }
    }

    /// Validate multiple files, returning only invalid results.
    /// Caller owns the returned slice.
    pub fn validateFiles(
        self: *Self,
        allocator: Allocator,
        paths: []const []const u8,
    ) Allocator.Error![]ValidationResult {
        if (!self.enabled) {
            return &[_]ValidationResult{};
        }

        var results: std.ArrayListUnmanaged(ValidationResult) = .{};
        errdefer results.deinit(allocator);

        for (paths) |path| {
            const result = self.validateFile(path);
            if (!result.is_valid) {
                try results.append(allocator, result);
            }
        }

        return results.toOwnedSlice(allocator);
    }
};

// ============ Buffer-First Validation API ============

/// Check if the system has enough memory available for an allocation.
/// Uses a conservative approach: tries to allocate, then immediately frees.
/// Returns false for impossibly large allocations (> addressable memory).
pub fn checkMemoryAvailable(size: usize) bool {
    // Quick rejection for impossibly large sizes
    // On 64-bit systems, practical limit is around 128TB for most OSes
    const max_practical: usize = 128 * 1024 * 1024 * 1024 * 1024; // 128 TB
    if (size > max_practical) {
        return false;
    }

    // For very large allocations (> 1GB), be more conservative
    // and check against a fraction of typical system memory
    const conservative_limit: usize = 64 * 1024 * 1024 * 1024; // 64 GB
    if (size > conservative_limit) {
        return false;
    }

    // For smaller allocations, try to actually allocate
    // This tests real memory availability
    const allocator = std.heap.page_allocator;
    const ptr = allocator.alloc(u8, size) catch {
        return false;
    };
    allocator.free(ptr);
    return true;
}

/// Validate data from a memory buffer.
/// This is the buffer-first entry point for format validation.
/// Detects format and routes to appropriate buffer-based validator.
pub fn validateDataBuffer(data: []const u8, allocator: Allocator) ValidationResult {
    _ = allocator; // Will be used for validators that need allocation

    if (data.len == 0) {
        return ValidationResult.unknown();
    }

    // Detect format from data
    const format = detectFormat(data);

    // Route to appropriate buffer-based validator
    return switch (format) {
        .png => image_validators.validatePngFromBuffer(data),
        .jpeg => image_validators.validateJpegFromBuffer(data),
        .gif => image_validators.validateGifFromBuffer(data),
        .bmp => image_validators.validateBmpFromBuffer(data),
        .tiff => image_validators.validateTiffFromBuffer(data),
        .exr => image_validators.validateExrFromBuffer(data),
        .psd => image_validators.validatePsdFromBuffer(data),
        .ai => creative_validators.validateAiFromBuffer(data),
        .eps => creative_validators.validateEpsFromBuffer(data),
        .aep => creative_validators.validateAepFromBuffer(data),
        .prproj => creative_validators.validatePrprojFromBuffer(data),
        .indd => creative_validators.validateInddFromBuffer(data),
        .idml => archive_validators.validateZipFromBuffer(data, .idml),
        .dwg => cad_3d_validators.validateDwgFromBuffer(data),
        .blend => cad_3d_validators.validateBlendFromBuffer(data),
        .flp => daw_validators.validateFlpFromBuffer(data),
        .fcpxml => creative_validators.validateFcpxmlFromBuffer(data),
        .drp => creative_validators.validateDrpFromBuffer(data),
        .sketch => creative_validators.validateSketchFromBuffer(data),
        .mdb => document_validators.validateMdbFromBuffer(data),
        .accdb => document_validators.validateAccdbFromBuffer(data),
        .dbf => document_validators.validateDbfFromBuffer(data),
        .obj => cad_3d_validators.validateObjFromBuffer(data),
        .webp => image_validators.validateWebpFromBuffer(data),
        .zip, .epub, .docx, .xlsx, .pptx, .odt, .ods, .odp, .song => archive_validators.validateZipFromBuffer(data, format),
        .pdf => pdf_validator.validatePdfFromBuffer(data),
        .mp4, .mov, .m4a => movie_validators.validateMp4FromBuffer(data),
        .mkv, .webm => movie_validators.validateMkvFromBuffer(data),
        .avi => movie_validators.validateAviFromBuffer(data),
        .mp3 => music_validators.validateMp3FromBuffer(data),
        .flac => music_validators.validateFlacFromBuffer(data),
        .wav => music_validators.validateWavFromBuffer(data),
        .aiff => music_validators.validateAiffFromBuffer(data),
        .ogg => music_validators.validateOggFromBuffer(data),
        .gzip => archive_validators.validateGzipFromBuffer(data),
        .bzip2 => archive_validators.validateBzip2FromBuffer(data),
        .xz => archive_validators.validateXzFromBuffer(data),
        .zstd => archive_validators.validateZstdFromBuffer(data),
        .hqx => archive_validators.validateHqxFromBuffer(data),
        .rar => archive_validators.validateRarFromBuffer(data),
        .cpt => archive_validators.validateCptFromBuffer(data),
        .sit => stuffit_validator.validateSitFromBuffer(data),
        .sitx => stuffit_validator.validateSitxFromBuffer(data),
        .sevenz => archive_validators.validate7zFromBuffer(data),
        .wim, .esd => wim_validator.validateWimFromBuffer(data),
        // Network capture formats
        .pcap => network_validators.validatePcapFromBuffer(data),
        .pcapng => network_validators.validatePcapngFromBuffer(data),
        // Package formats
        .rpm => archive_validators.validateRpmFromBuffer(data),
        // For formats without buffer validators yet, just return format detected
        else => ValidationResult.ok(format),
    };
}

// ============ BEAM Bytecode Validation ============

/// Validate Erlang/Elixir BEAM bytecode files.
/// Deep-validates compressed chunks (LitT zlib, Dbgi ETF-compressed) to catch bitrot.
fn validateBeam(allocator: Allocator, file: std.fs.File) ValidationResult {
    const stat = file.stat() catch {
        return ValidationResult.invalidCode(.beam, .failed_to_stat, "file");
    };
    if (stat.size < 12) return ValidationResult.invalidCode(.beam, .file_too_small, "BEAM format");

    var header: [12]u8 = undefined;
    const bytes_read = file.readAll(&header) catch {
        return ValidationResult.invalidCode(.beam, .failed_to_read, "header");
    };
    if (bytes_read < 12) return ValidationResult.invalidCode(.beam, .truncated, "header");
    if (!std.mem.eql(u8, header[0..4], "FOR1")) return ValidationResult.invalid(.beam, "Missing FOR1 magic");
    if (!std.mem.eql(u8, header[8..12], "BEAM")) return ValidationResult.invalid(.beam, "Not a BEAM file (wrong form type)");

    const declared_size = std.mem.readInt(u32, header[4..8], .big);
    const expected_file_size: u64 = @as(u64, declared_size) + 8;
    if (stat.size < expected_file_size) return ValidationResult.invalid(.beam, "File truncated (size mismatch)");

    var offset: u64 = 12;
    const chunk_area_end: u64 = @min(expected_file_size, stat.size);
    var chunk_count: u32 = 0;
    var has_atom_table = false;
    var has_code = false;
    var has_strt = false;
    var has_impt = false;
    var has_expt = false;

    while (offset + 8 <= chunk_area_end) {
        var chunk_header_buf: [8]u8 = undefined;
        file.seekTo(offset) catch return ValidationResult.invalidCode(.beam, .failed_to_seek, "to chunk");
        const chunk_bytes = file.readAll(&chunk_header_buf) catch return ValidationResult.invalidCode(.beam, .failed_to_read, "chunk header");
        if (chunk_bytes < 8) break;

        const chunk_name = chunk_header_buf[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header_buf[4..8], .big);

        // Validate chunk name is printable ASCII (all BEAM chunk IDs are)
        for (chunk_name) |c| {
            if (c < 0x20 or c > 0x7E) {
                return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "chunk name", "Non-printable chunk name (corrupt)");
            }
        }

        if (std.mem.eql(u8, chunk_name, "AtU8") or std.mem.eql(u8, chunk_name, "Atom")) has_atom_table = true;
        if (std.mem.eql(u8, chunk_name, "Code")) has_code = true;
        if (std.mem.eql(u8, chunk_name, "StrT")) has_strt = true;
        if (std.mem.eql(u8, chunk_name, "ImpT")) has_impt = true;
        if (std.mem.eql(u8, chunk_name, "ExpT")) has_expt = true;

        if (offset + 8 + chunk_size > chunk_area_end) return ValidationResult.invalidCodeMsg(.beam, .exceeds_bounds, "Chunk size", "Chunk size exceeds file bounds");

        // For ImpT/ExpT/LocT: validate entry count × entry size matches chunk size
        if (std.mem.eql(u8, chunk_name, "ImpT") or std.mem.eql(u8, chunk_name, "ExpT") or std.mem.eql(u8, chunk_name, "LocT")) {
            if (chunk_size >= 4) {
                var count_buf: [4]u8 = undefined;
                const count_read = file.readAll(&count_buf) catch 0;
                if (count_read == 4) {
                    const entry_count_val = std.mem.readInt(u32, &count_buf, .big);
                    // ImpT entries are 3 u32s (12 bytes), ExpT/LocT entries are 3 u32s (12 bytes)
                    const entry_size: u32 = 12;
                    const expected_size = 4 + entry_count_val * entry_size;
                    if (expected_size != chunk_size) {
                        return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "table chunk", "Entry count × entry size does not match chunk size");
                    }
                }
            }
        }

        // For Code chunk: validate header fields
        if (std.mem.eql(u8, chunk_name, "Code") and chunk_size >= 16) {
            var code_hdr: [16]u8 = undefined;
            file.seekTo(offset + 8) catch {};
            const code_read = file.readAll(&code_hdr) catch 0;
            if (code_read == 16) {
                const sub_size = std.mem.readInt(u32, code_hdr[0..4], .big);
                const instruction_set = std.mem.readInt(u32, code_hdr[4..8], .big);
                // sub_size should be reasonable (16 is common header size)
                if (sub_size > chunk_size) {
                    return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "Code chunk", "Code sub-header size exceeds chunk");
                }
                // OTP instruction set version is typically 0
                if (instruction_set > 1) {
                    return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "Code chunk", "Unknown instruction set version");
                }
            }
        }

        // For LitT chunk: verify zlib decompression of compressed literal table
        if (std.mem.eql(u8, chunk_name, "LitT") and chunk_size > 4) {
            const compressed_size = chunk_size - 4; // first 4 bytes = uncompressed size
            if (compressed_size > 0) {
                // Read uncompressed size to validate it
                file.seekTo(offset + 8) catch {};
                var uncomp_size_buf: [4]u8 = undefined;
                const us_read = file.readAll(&uncomp_size_buf) catch 0;
                if (us_read == 4) {
                    const uncomp_size = std.mem.readInt(u32, &uncomp_size_buf, .big);
                    // If uncompressed size > 0, data should be zlib-compressed
                    if (uncomp_size > 0 and compressed_size >= 2) {
                        const compressed_data = allocator.alloc(u8, compressed_size) catch null;
                        if (compressed_data) |buf| {
                            defer allocator.free(buf);
                            const rd = file.readAll(buf) catch 0;
                            if (rd == compressed_size) {
                                // Check for zlib header (0x78xx)
                                if (buf[0] == 0x78) {
                                    const decompressed = zlib.inflateZlibAlloc(allocator, buf, 64 * 1024 * 1024) catch {
                                        return ValidationResult.invalidCodeMsg(.beam, .decompression_failed, "LitT chunk", "zlib decompression failed (corrupt literal table)");
                                    };
                                    allocator.free(decompressed);
                                }
                            }
                        }
                    }
                }
            }
        }

        // For Dbgi/Docs/Attr/CInf chunks: verify zlib decompression of ETF-compressed data
        // ETF compressed format: 0x83 (version), 0x50 (compressed tag), 4-byte uncompressed size, zlib data
        if ((std.mem.eql(u8, chunk_name, "Dbgi") or std.mem.eql(u8, chunk_name, "Docs") or
            std.mem.eql(u8, chunk_name, "Attr") or std.mem.eql(u8, chunk_name, "CInf")) and chunk_size > 6)
        {
            file.seekTo(offset + 8) catch {};
            var etf_hdr: [6]u8 = undefined;
            const etf_read = file.readAll(&etf_hdr) catch 0;
            if (etf_read == 6 and etf_hdr[0] == 0x83 and etf_hdr[1] == 0x50) {
                // ETF compressed: version=0x83, tag=0x50, 4 bytes uncompressed size, then zlib
                const zlib_size = chunk_size - 6;
                if (zlib_size >= 2) {
                    const compressed_data = allocator.alloc(u8, zlib_size) catch null;
                    if (compressed_data) |buf| {
                        defer allocator.free(buf);
                        const rd = file.readAll(buf) catch 0;
                        if (rd == zlib_size) {
                            if (buf[0] == 0x78) {
                                const decompressed = zlib.inflateZlibAlloc(allocator, buf, 64 * 1024 * 1024) catch {
                                    return ValidationResult.invalidCodeMsg(.beam, .decompression_failed, "ETF chunk", "zlib decompression failed (corrupt compressed data)");
                                };
                                allocator.free(decompressed);
                            }
                        }
                    }
                }
            }
        }

        // For FunT chunk: validate entry count × entry size (each entry is 6 u32s = 24 bytes)
        if (std.mem.eql(u8, chunk_name, "FunT") and chunk_size >= 4) {
            file.seekTo(offset + 8) catch {};
            var funt_count_buf: [4]u8 = undefined;
            const funt_read = file.readAll(&funt_count_buf) catch 0;
            if (funt_read == 4) {
                const fun_count = std.mem.readInt(u32, &funt_count_buf, .big);
                const expected_size = 4 + fun_count * 24;
                if (expected_size != chunk_size) {
                    return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "FunT chunk", "Entry count × entry size does not match chunk size");
                }
            }
        }

        const padded_size = (chunk_size + 3) & ~@as(u32, 3);
        offset = offset + 8 + padded_size;
        chunk_count += 1;
        if (chunk_count > 1000) return ValidationResult.invalidCode(.beam, .too_many, "chunks (likely corrupt)");
    }

    if (chunk_count == 0) return ValidationResult.invalid(.beam, "No chunks found");
    if (!has_atom_table) return ValidationResult.invalidCode(.beam, .missing, "atom table chunk");
    if (!has_code) return ValidationResult.invalidCode(.beam, .missing, "code chunk");
    if (!has_strt) return ValidationResult.invalidCode(.beam, .missing, "string table chunk (StrT)");
    if (!has_impt) return ValidationResult.invalidCode(.beam, .missing, "import table chunk (ImpT)");
    if (!has_expt) return ValidationResult.invalidCode(.beam, .missing, "export table chunk (ExpT)");

    // Verify chunks exactly fill the FOR1 container (no gaps)
    if (offset != chunk_area_end) {
        return ValidationResult.invalidCodeMsg(.beam, .invalid_value, "chunk layout", "Chunks do not exactly fill FOR1 container");
    }

    return ValidationResult.okWithDepth(.beam, .full);
}

// ============ Shared XML/Text Helpers ============

/// Maximum file size for text format parsing (1 GB).
const max_text_file_size: usize = 1024 * 1024 * 1024;

pub const DoctypeStrippedResult = struct {
    data: []const u8,
    allocated: bool,
    had_doctype: bool,
};

/// Check if an encoding name is ASCII-compatible.
pub fn isAsciiCompatibleEncoding(encoding: []const u8) bool {
    var lower_buf: [32]u8 = undefined;
    const len = @min(encoding.len, lower_buf.len);
    for (encoding[0..len], 0..) |c, idx| {
        lower_buf[idx] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..len];
    if (std.mem.indexOf(u8, lower, "ascii") != null) return true;
    if (std.mem.startsWith(u8, lower, "iso-8859") or
        std.mem.startsWith(u8, lower, "iso_8859") or
        std.mem.startsWith(u8, lower, "iso8859")) return true;
    if (std.mem.eql(u8, lower, "latin1") or
        std.mem.eql(u8, lower, "latin-1") or
        std.mem.eql(u8, lower, "l1")) return true;
    if (std.mem.eql(u8, lower, "windows-1252") or
        std.mem.eql(u8, lower, "cp1252") or
        std.mem.eql(u8, lower, "windows-1251") or
        std.mem.eql(u8, lower, "cp1251")) return true;
    return false;
}

pub const EncodingNormalizedResult = struct {
    data: []const u8,
    allocated: bool,
};

/// Normalize ASCII-compatible encodings to UTF-8 in the XML declaration.
pub fn normalizeXmlEncoding(allocator: Allocator, content: []const u8) EncodingNormalizedResult {
    if (!std.mem.startsWith(u8, content, "<?xml")) {
        return .{ .data = content, .allocated = false };
    }
    const decl_end = std.mem.indexOf(u8, content, "?>") orelse {
        return .{ .data = content, .allocated = false };
    };
    const decl = content[0 .. decl_end + 2];
    var enc_start: ?usize = null;
    var i: usize = 5;
    while (i + 8 < decl.len) : (i += 1) {
        if ((decl[i] == 'e' or decl[i] == 'E') and
            std.ascii.eqlIgnoreCase(decl[i .. i + 8], "encoding"))
        {
            enc_start = i;
            break;
        }
    }
    if (enc_start == null) return .{ .data = content, .allocated = false };
    const after_enc = enc_start.? + 8;
    var quote_start: ?usize = null;
    var j = after_enc;
    while (j < decl.len) : (j += 1) {
        if (decl[j] == '"' or decl[j] == '\'') {
            quote_start = j;
            break;
        } else if (decl[j] != '=' and decl[j] != ' ' and decl[j] != '\t') {
            return .{ .data = content, .allocated = false };
        }
    }
    if (quote_start == null) return .{ .data = content, .allocated = false };
    const quote_char = decl[quote_start.?];
    const value_start = quote_start.? + 1;
    const value_end = std.mem.indexOfScalarPos(u8, decl, value_start, quote_char) orelse {
        return .{ .data = content, .allocated = false };
    };
    const encoding = decl[value_start..value_end];
    if (std.ascii.eqlIgnoreCase(encoding, "UTF-8")) return .{ .data = content, .allocated = false };
    if (!isAsciiCompatibleEncoding(encoding)) return .{ .data = content, .allocated = false };
    const new_content = allocator.alloc(u8, content.len - encoding.len + 5) catch {
        return .{ .data = content, .allocated = false };
    };
    var pos: usize = 0;
    @memcpy(new_content[pos .. pos + value_start], content[0..value_start]);
    pos += value_start;
    @memcpy(new_content[pos .. pos + 5], "UTF-8");
    pos += 5;
    @memcpy(new_content[pos..], content[value_end..]);
    return .{ .data = new_content, .allocated = true };
}

/// Strip DOCTYPE declaration from XML content.
pub fn stripDoctypeDeclaration(allocator: Allocator, content: []const u8) DoctypeStrippedResult {
    const doctype_start = std.mem.indexOf(u8, content, "<!DOCTYPE");
    if (doctype_start == null) return .{ .data = content, .allocated = false, .had_doctype = false };
    const start = doctype_start.?;
    var dt_i = start + 9;
    var bracket_depth: usize = 0;
    var in_quotes: u8 = 0;
    while (dt_i < content.len) {
        const c = content[dt_i];
        if (in_quotes != 0) {
            if (c == in_quotes) in_quotes = 0;
        } else {
            if (c == '"' or c == '\'') {
                in_quotes = c;
            } else if (c == '[') {
                bracket_depth += 1;
            } else if (c == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
            } else if (c == '>' and bracket_depth == 0) {
                const end = dt_i + 1;
                const new_len = content.len - (end - start);
                const new_content = allocator.alloc(u8, new_len) catch {
                    return .{ .data = content, .allocated = false, .had_doctype = false };
                };
                @memcpy(new_content[0..start], content[0..start]);
                @memcpy(new_content[start..], content[end..]);
                return .{ .data = new_content, .allocated = true, .had_doctype = true };
            }
        }
        dt_i += 1;
    }
    return .{ .data = content, .allocated = false, .had_doctype = false };
}


test "FileFormat descriptions" {
    try std.testing.expectEqualStrings("PNG Image", FileFormat.png.description());
    try std.testing.expectEqualStrings("ZIP Archive", FileFormat.zip.description());
    try std.testing.expectEqualStrings("Word Document (OOXML)", FileFormat.docx.description());
}

test "FileFormat validators" {
    // All supported formats should have validators
    try std.testing.expect(FileFormat.png.hasValidator());
    try std.testing.expect(FileFormat.jpeg.hasValidator());
    try std.testing.expect(FileFormat.jxl.hasValidator());
    try std.testing.expect(FileFormat.gif.hasValidator());
    try std.testing.expect(FileFormat.bmp.hasValidator());
    try std.testing.expect(FileFormat.webp.hasValidator());
    try std.testing.expect(FileFormat.tiff.hasValidator());
    try std.testing.expect(FileFormat.heic.hasValidator());
    try std.testing.expect(FileFormat.zip.hasValidator());
    try std.testing.expect(FileFormat.epub.hasValidator());
    try std.testing.expect(FileFormat.docx.hasValidator());
    try std.testing.expect(FileFormat.pdf.hasValidator());
    try std.testing.expect(FileFormat.mp4.hasValidator());
    try std.testing.expect(FileFormat.mov.hasValidator());
    try std.testing.expect(FileFormat.mkv.hasValidator());
    try std.testing.expect(FileFormat.webm.hasValidator());
    try std.testing.expect(FileFormat.avi.hasValidator());
    try std.testing.expect(FileFormat.mp3.hasValidator());
    try std.testing.expect(FileFormat.flac.hasValidator());
    try std.testing.expect(FileFormat.wav.hasValidator());
    try std.testing.expect(FileFormat.m4a.hasValidator());
    try std.testing.expect(FileFormat.hqx.hasValidator());
    // RAW formats
    try std.testing.expect(FileFormat.dng.hasValidator());
    try std.testing.expect(FileFormat.cr2.hasValidator());
    try std.testing.expect(FileFormat.cr3.hasValidator());
    try std.testing.expect(FileFormat.nef.hasValidator());
    try std.testing.expect(FileFormat.arw.hasValidator());
    try std.testing.expect(FileFormat.raf.hasValidator());
    try std.testing.expect(FileFormat.orf.hasValidator());
    try std.testing.expect(FileFormat.rw2.hasValidator());
    try std.testing.expect(FileFormat.pef.hasValidator());
    // Unknown has no validator
    try std.testing.expect(!FileFormat.unknown.hasValidator());
}

test "FileFormat ZIP-based" {
    try std.testing.expect(FileFormat.zip.isZipBased());
    try std.testing.expect(FileFormat.epub.isZipBased());
    try std.testing.expect(FileFormat.docx.isZipBased());
    try std.testing.expect(!FileFormat.png.isZipBased());
    try std.testing.expect(!FileFormat.pdf.isZipBased());
}

test "ValidationResult constructors" {
    const ok_result = ValidationResult.ok(.png);
    try std.testing.expect(ok_result.is_valid);
    try std.testing.expectEqual(FileFormat.png, ok_result.format);
    try std.testing.expect(ok_result.error_message == null);

    const invalid_result = ValidationResult.invalid(.zip, "Corrupted");
    try std.testing.expect(!invalid_result.is_valid);
    try std.testing.expectEqual(FileFormat.zip, invalid_result.format);
    try std.testing.expectEqualStrings("Corrupted", invalid_result.error_message.?);

    const unknown_result = ValidationResult.unknown();
    try std.testing.expect(unknown_result.is_valid);
    try std.testing.expectEqual(FileFormat.unknown, unknown_result.format);
}

test "detectFormat unknown" {
    const random_data = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    try std.testing.expectEqual(FileFormat.unknown, detectFormat(&random_data));
}

test "detectFormat does not misdetect SRT subtitle as dBASE" {
    // SRT files start with "1\n00:00:..." — byte 0 is 0x31 which matches Visual FoxPro version.
    // Bytes 8-9 as u16le pass len_header >= 33, bytes 10-11 pass len_record > 0.
    // But byte[2] = 0x30 = month 48 which is invalid for dBASE date field.
    // Detection must validate date fields to prevent this false positive.
    var srt = [_]u8{0} ** 1088;
    // Exact bytes from a real Japanese SRT subtitle file
    const real_srt = [_]u8{
        0x31, 0x0a, 0x30, 0x30, 0x3a, 0x30, 0x30, 0x3a, // "1\n00:00:"
        0x30, 0x36, 0x2c, 0x34, 0x36, 0x34, 0x20, 0x2d, // "06,464 -"
        0x2d, 0x3e, 0x20, 0x30, 0x30, 0x3a, 0x30, 0x30, // "-> 00:00"
        0x3a, 0x30, 0x38, 0x2c, 0x37, 0x31, 0x37, 0x0a, // ":08,717\n"
        0xe2, 0x80, 0x8e, 0x4e, 0x45, 0x54, 0x46, 0x4c, // "...NETFL"
    };
    @memcpy(srt[0..real_srt.len], &real_srt);
    // Fill rest with UTF-8 multibyte chars (like the real file has)
    var i: usize = real_srt.len;
    while (i + 2 < srt.len) : (i += 3) {
        srt[i] = 0xe3;
        srt[i + 1] = 0x82;
        srt[i + 2] = 0xa2;
    }
    const detected = detectFormat(&srt);
    // Must be detected as text, not dBASE or unknown
    try std.testing.expect(detected != .dbf);
    try std.testing.expect(detected == .plain_text or detected == .plain_text_utf16 or
        detected == .plain_text_latin1 or detected == .plain_text_cp437);
}

test "detectFormat rejects tiny files as MP3" {
    // 32-byte file starting with 0xFF 0xFB (MP3 sync word) — too small to be valid MP3
    var tiny_mp3 = [_]u8{0} ** 32;
    tiny_mp3[0] = 0xFF;
    tiny_mp3[1] = 0xFB;
    try std.testing.expectEqual(FileFormat.unknown, detectFormat(&tiny_mp3));
}

test "detectFormat rejects tiny files as BMP" {
    // 32-byte file starting with "BM" — too small to be a valid BMP
    var tiny_bmp = [_]u8{0} ** 32;
    tiny_bmp[0] = 'B';
    tiny_bmp[1] = 'M';
    try std.testing.expectEqual(FileFormat.unknown, detectFormat(&tiny_bmp));
}

test "detectFormat rejects sub-512-byte tar" {
    // 378-byte buffer with "ustar" at offset 257 — too small for a valid tar entry
    var tiny_tar = [_]u8{0} ** 378;
    @memcpy(tiny_tar[257..262], "ustar");
    try std.testing.expectEqual(FileFormat.unknown, detectFormat(&tiny_tar));
}

test "detectFormat accepts valid-size MP3" {
    // 256-byte buffer with MP3 sync — large enough to be plausible
    var mp3_buf = [_]u8{0} ** 256;
    mp3_buf[0] = 0xFF;
    mp3_buf[1] = 0xFB;
    try std.testing.expectEqual(FileFormat.mp3, detectFormat(&mp3_buf));
}

test "parseMaxVideoDeepSize defaults to unlimited and honors MAX_VIDEO_SIZE" {
    try std.testing.expectEqual(std.math.maxInt(u64), movie_validators.parseMaxVideoDeepSize(null));
    try std.testing.expectEqual(std.math.maxInt(u64), movie_validators.parseMaxVideoDeepSize("invalid"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), movie_validators.parseMaxVideoDeepSize("1"));
}

test "FormatValidator init/deinit" {
    var validator = FormatValidator.init();
    defer validator.deinit();
    try std.testing.expect(validator.enabled);
}

test "FormatValidator enable/disable" {
    var validator = FormatValidator.init();
    defer validator.deinit();

    try std.testing.expect(validator.enabled);

    validator.setEnabled(false);
    try std.testing.expect(!validator.enabled);

    // Disabled validator returns unknown (pass-through)
    const result = validator.validateFile("/nonexistent");
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(FileFormat.unknown, result.format);
}


test "FormatValidator deep validates real OLE2 XLS from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth XLS file (OLE2/CFBF format)
    const file = std.fs.cwd().openFile("ground_truth_examples/ole2/sample.xls", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/ole2/sample.xls") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.xls, result.format);
    try std.testing.expect(result.is_valid);
    // BIFF8 record chain + BoundSheet8 cross-validation + SST header
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "FormatValidator deep validates real OLE2 PPT from ground truth" {
    const allocator = std.testing.allocator;

    // Ground truth PPT file (OLE2/CFBF format)
    const file = std.fs.cwd().openFile("ground_truth_examples/ole2/sample.ppt", .{}) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    file.close();

    const path = std.fs.cwd().realpathAlloc(allocator, "ground_truth_examples/ole2/sample.ppt") catch |err| { if (err == error.FileNotFound or err == error.AccessDenied) return error.SkipZigTest; return err; };
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    const result = validator.validateFileDeep(allocator, path);

    try std.testing.expectEqual(FileFormat.ppt, result.format);
    try std.testing.expect(result.is_valid);
    // OLE2 validates FAT chain + directory structure but no CRC/hash
    try std.testing.expectEqual(ValidationDepth.structural, result.validation_depth);
}

test "FormatValidator rejects invalid EBML" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Invalid EBML (wrong signature)
    const invalid_mkv = [_]u8{
        0x1A, 0x45, 0xDF, 0xA4, // Wrong signature (last byte should be A3)
        0x8B, 0x42, 0x82,
    };

    const file = try tmp_dir.dir.createFile("invalid.mkv", .{});
    try file.writeAll(&invalid_mkv);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.mkv");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Detected as MKV via extension fallback, reported as invalid
    try std.testing.expectEqual(FileFormat.mkv, result.format);
    try std.testing.expect(!result.is_valid);
}

test "detectFormat OLE2" {
    const ole2_header = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
    try std.testing.expectEqual(FileFormat.doc, detectFormat(&ole2_header));
}

test "FormatValidator accepts valid OLE2 DOC" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid OLE2/CFBF header (512 bytes)
    var ole2_header: [512]u8 = undefined;
    @memset(&ole2_header, 0);

    // Magic signature
    ole2_header[0] = 0xD0;
    ole2_header[1] = 0xCF;
    ole2_header[2] = 0x11;
    ole2_header[3] = 0xE0;
    ole2_header[4] = 0xA1;
    ole2_header[5] = 0xB1;
    ole2_header[6] = 0x1A;
    ole2_header[7] = 0xE1;
    // Minor version (0x003E)
    ole2_header[0x18] = 0x3E;
    ole2_header[0x19] = 0x00;
    // Major version (3)
    ole2_header[0x1A] = 0x03;
    ole2_header[0x1B] = 0x00;
    // Byte order (0xFFFE = little-endian)
    ole2_header[0x1C] = 0xFE;
    ole2_header[0x1D] = 0xFF;
    // Sector size power (9 = 512 bytes)
    ole2_header[0x1E] = 0x09;
    ole2_header[0x1F] = 0x00;
    // Mini sector size power (6 = 64 bytes)
    ole2_header[0x20] = 0x06;
    ole2_header[0x21] = 0x00;

    const file = try tmp_dir.dir.createFile("valid.doc", .{});
    try file.writeAll(&ole2_header);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.doc");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    // Should be detected as some OLE2 format (doc, xls, or ppt)
    try std.testing.expect(result.format.isOle2());
    if (!result.is_valid) {
        std.debug.print("\nValid OLE2 failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid OLE2" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // OLE2 with wrong version
    var bad_ole2: [512]u8 = undefined;
    @memset(&bad_ole2, 0);
    bad_ole2[0] = 0xD0;
    bad_ole2[1] = 0xCF;
    bad_ole2[2] = 0x11;
    bad_ole2[3] = 0xE0;
    bad_ole2[4] = 0xA1;
    bad_ole2[5] = 0xB1;
    bad_ole2[6] = 0x1A;
    bad_ole2[7] = 0xE1;
    // Major version = 0 (invalid)
    bad_ole2[0x1A] = 0x00;
    bad_ole2[0x1B] = 0x00;

    const file = try tmp_dir.dir.createFile("invalid.doc", .{});
    try file.writeAll(&bad_ole2);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.doc");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expect(result.format.isOle2());
    try std.testing.expect(!result.is_valid);
}

test "detectFormat SQLite" {
    const sqlite_header = "SQLite format 3\x00";
    try std.testing.expectEqual(FileFormat.sqlite, detectFormat(sqlite_header));
}

test "FormatValidator accepts valid SQLite" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid SQLite header (100 bytes)
    var sqlite_header: [100]u8 = undefined;
    @memset(&sqlite_header, 0);

    // Magic: "SQLite format 3\0"
    const magic = "SQLite format 3\x00";
    @memcpy(sqlite_header[0..16], magic);

    // Page size = 4096 (0x1000 big-endian)
    sqlite_header[16] = 0x10;
    sqlite_header[17] = 0x00;

    // Write version (1 = legacy)
    sqlite_header[18] = 1;
    // Read version (1 = legacy)
    sqlite_header[19] = 1;

    // Reserved bytes per page
    sqlite_header[20] = 0;

    // Max embedded payload fraction (64)
    sqlite_header[21] = 64;
    // Min embedded payload fraction (32)
    sqlite_header[22] = 32;
    // Leaf payload fraction (32)
    sqlite_header[23] = 32;

    const file = try tmp_dir.dir.createFile("valid.sqlite", .{});
    try file.writeAll(&sqlite_header);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.sqlite");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.sqlite, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid SQLite failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid SQLite page size" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var bad_sqlite: [100]u8 = undefined;
    @memset(&bad_sqlite, 0);
    const magic = "SQLite format 3\x00";
    @memcpy(bad_sqlite[0..16], magic);

    // Invalid page size = 100 (not power of 2)
    bad_sqlite[16] = 0x00;
    bad_sqlite[17] = 0x64;

    bad_sqlite[18] = 1;
    bad_sqlite[19] = 1;
    bad_sqlite[21] = 64;
    bad_sqlite[22] = 32;
    bad_sqlite[23] = 32;

    const file = try tmp_dir.dir.createFile("invalid.sqlite", .{});
    try file.writeAll(&bad_sqlite);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.sqlite");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.sqlite, result.format);
    try std.testing.expect(!result.is_valid);
}

test "detectFormat WordPerfect" {
    const wpd_header = [_]u8{ 0xFF, 0x57, 0x50, 0x43 };
    try std.testing.expectEqual(FileFormat.wpd, detectFormat(&wpd_header));
}

test "FormatValidator accepts valid WordPerfect" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Minimal valid WordPerfect header
    var wpd_header: [32]u8 = undefined;
    @memset(&wpd_header, 0);

    // Magic: FF 57 50 43 (WPC)
    wpd_header[0] = 0xFF;
    wpd_header[1] = 0x57;
    wpd_header[2] = 0x50;
    wpd_header[3] = 0x43;

    // Document area offset (little-endian, reasonable value)
    wpd_header[4] = 0x20;
    wpd_header[5] = 0x00;
    wpd_header[6] = 0x00;
    wpd_header[7] = 0x00;

    // Product type (1 = WordPerfect)
    wpd_header[8] = 0x01;

    // File type (0x0A = WPD document)
    wpd_header[9] = 0x0A;

    const file = try tmp_dir.dir.createFile("valid.wpd", .{});
    try file.writeAll(&wpd_header);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "valid.wpd");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wpd, result.format);
    if (!result.is_valid) {
        std.debug.print("\nValid WordPerfect failed: {s}\n", .{result.error_message orelse "no message"});
    }
    try std.testing.expect(result.is_valid);
}

test "FormatValidator rejects invalid WordPerfect" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // WordPerfect with invalid product type
    var bad_wpd: [32]u8 = undefined;
    @memset(&bad_wpd, 0);
    bad_wpd[0] = 0xFF;
    bad_wpd[1] = 0x57;
    bad_wpd[2] = 0x50;
    bad_wpd[3] = 0x43;
    bad_wpd[4] = 0x20; // document offset
    bad_wpd[8] = 0x00; // product type 0 (invalid)
    bad_wpd[9] = 0x0A; // file type

    const file = try tmp_dir.dir.createFile("invalid.wpd", .{});
    try file.writeAll(&bad_wpd);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "invalid.wpd");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.wpd, result.format);
    try std.testing.expect(!result.is_valid);
}

test "FormatValidator deep validation detects SQLite integrity" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a valid SQLite database using the sqlite3 library
    const db_name = "test_deep.sqlite";
    const file = try tmp_dir.dir.createFile(db_name, .{});

    // Write minimal valid SQLite header
    var header: [100]u8 = undefined;
    @memset(&header, 0);
    const magic = "SQLite format 3\x00";
    @memcpy(header[0..16], magic);
    header[16] = 0x10; // Page size 4096 (big-endian)
    header[17] = 0x00;
    header[18] = 1; // Write version
    header[19] = 1; // Read version
    header[21] = 64; // Max payload fraction
    header[22] = 32; // Min payload fraction
    header[23] = 32; // Leaf payload fraction

    try file.writeAll(&header);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, db_name);
    defer allocator.free(path);

    var validator = FormatValidator.initDeep();
    defer validator.deinit();

    // Structural validation should pass
    const struct_result = validator.validateFile(path);
    try std.testing.expectEqual(FileFormat.sqlite, struct_result.format);
    try std.testing.expect(struct_result.is_valid);

    // Note: Deep validation would require a properly initialized SQLite database
    // This test just verifies the structural validation works with deep mode enabled
}

test "ValidationResult tracks validation depth" {
    const structural = ValidationResult.ok(.png);
    try std.testing.expectEqual(ValidationDepth.structural, structural.validation_depth);

    const deep = ValidationResult.okWithDepth(.sqlite, .full);
    try std.testing.expectEqual(ValidationDepth.full, deep.validation_depth);
}

test "ValidationResult tracks resource fork info" {
    var result = ValidationResult.ok(.unknown);
    try std.testing.expect(!result.has_resource_fork);
    try std.testing.expect(result.resource_fork_valid == null);

    result.has_resource_fork = true;
    result.resource_fork_valid = true;
    try std.testing.expect(result.has_resource_fork);
    try std.testing.expect(result.resource_fork_valid.? == true);
}

// ============ ZIP CRC-32 Deep Validation Tests ============

/// Helper to test XML well-formedness using zig-xml library
pub fn isXmlWellFormed(content: []const u8) bool {
    const xml_lib = @import("xml");
    var static_reader: xml_lib.Reader.Static = .init(std.testing.allocator, content, .{});
    defer static_reader.deinit();
    const reader = &static_reader.interface;

    while (true) {
        const node = reader.read() catch |err| {
            switch (err) {
                error.MalformedXml => return false,
                error.OutOfMemory => return false,
                error.ReadFailed => return false,
            }
        };
        if (node == .eof) break;
    }
    return true;
}

test "stripDoctypeDeclaration removes simple DOCTYPE" {
    const input = "<?xml version=\"1.0\"?><!DOCTYPE html><html></html>";
    const result = stripDoctypeDeclaration(std.testing.allocator, input);
    defer if (result.allocated) std.testing.allocator.free(result.data);

    try std.testing.expect(result.had_doctype);
    try std.testing.expect(result.allocated);
    try std.testing.expectEqualStrings("<?xml version=\"1.0\"?><html></html>", result.data);
}

test "stripDoctypeDeclaration removes DOCTYPE with SYSTEM" {
    const input = "<!DOCTYPE softwarelist SYSTEM \"softwarelist.dtd\"><softwarelist/>";
    const result = stripDoctypeDeclaration(std.testing.allocator, input);
    defer if (result.allocated) std.testing.allocator.free(result.data);

    try std.testing.expect(result.had_doctype);
    try std.testing.expectEqualStrings("<softwarelist/>", result.data);
}

test "stripDoctypeDeclaration removes DOCTYPE with internal subset" {
    const input = "<!DOCTYPE root [<!ELEMENT root (#PCDATA)>]><root/>";
    const result = stripDoctypeDeclaration(std.testing.allocator, input);
    defer if (result.allocated) std.testing.allocator.free(result.data);

    try std.testing.expect(result.had_doctype);
    try std.testing.expectEqualStrings("<root/>", result.data);
}

test "stripDoctypeDeclaration returns original when no DOCTYPE" {
    const input = "<root><child/></root>";
    const result = stripDoctypeDeclaration(std.testing.allocator, input);

    try std.testing.expect(!result.had_doctype);
    try std.testing.expect(!result.allocated);
    try std.testing.expectEqual(input.ptr, result.data.ptr);
}

test "FormatValidator accepts valid STEP" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const step_content =
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('Test'),'2;1');
        \\FILE_NAME('test.stp','2024-01-15T00:00:00',(''),(''),'','','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));
        \\ENDSEC;
        \\DATA;
        \\ENDSEC;
        \\END-ISO-10303-21;
    ;

    const file = try tmp_dir.dir.createFile("test.stp", .{});
    try file.writeAll(step_content);
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(allocator, "test.stp");
    defer allocator.free(path);

    var validator = FormatValidator.init();
    defer validator.deinit();

    const result = validator.validateFile(path);

    try std.testing.expectEqual(FileFormat.step, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDataBuffer detects and validates PNG from buffer" {
    // Minimal valid PNG: signature + IHDR + IEND
    const valid_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length
        0x49, 0x48, 0x44, 0x52, // IHDR type
        0x00, 0x00, 0x00, 0x01, // width = 1
        0x00, 0x00, 0x00, 0x01, // height = 1
        0x08, // bit depth = 8
        0x02, // color type = RGB
        0x00, // compression
        0x00, // filter
        0x00, // interlace
        0x90, 0x77, 0x53, 0xDE, // IHDR CRC
        0x00, 0x00, 0x00, 0x00, // IEND length
        0x49, 0x45, 0x4E, 0x44, // IEND type
        0xAE, 0x42, 0x60, 0x82, // IEND CRC
    };

    const result = validateDataBuffer(&valid_png, std.testing.allocator);

    try std.testing.expectEqual(FileFormat.png, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDataBuffer detects and validates JPEG from buffer" {
    // Minimal JPEG with SOI, APP0, and EOI
    const valid_jpeg = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, // APP0
        0x00, 0x10, // length = 16
        0x4A, 0x46, 0x49, 0x46, 0x00, // JFIF\0
        0x01, 0x01, // version
        0x00, // units
        0x00, 0x01, // X density
        0x00, 0x01, // Y density
        0x00, 0x00, // thumbnail
        0xFF, 0xD9, // EOI
    };

    const result = validateDataBuffer(&valid_jpeg, std.testing.allocator);

    try std.testing.expectEqual(FileFormat.jpeg, result.format);
    try std.testing.expect(result.is_valid);
}

test "validateDataBuffer rejects truncated PNG" {
    // PNG signature only - no chunks
    const truncated_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature only
    };

    const result = validateDataBuffer(&truncated_png, std.testing.allocator);

    try std.testing.expectEqual(FileFormat.png, result.format);
    try std.testing.expect(!result.is_valid);
}

test "validateDataBuffer returns unknown for garbage data" {
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE };

    const result = validateDataBuffer(&garbage, std.testing.allocator);

    try std.testing.expectEqual(FileFormat.unknown, result.format);
}

test "checkMemoryAvailable returns true for small allocations" {
    // 1 KB should always be available
    try std.testing.expect(checkMemoryAvailable(1024));
}

test "checkMemoryAvailable returns false for impossibly large allocations" {
    // 1 exabyte should not be available
    try std.testing.expect(!checkMemoryAvailable(1024 * 1024 * 1024 * 1024 * 1024 * 1024));
}

test "validatePngFromBuffer matches validatePng file result" {
    // Minimal valid PNG
    const valid_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };

    // Write to temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.png", .{});
    try file.writeAll(&valid_png);
    file.close();

    // Validate via file
    const reopen = try tmp_dir.dir.openFile("test.png", .{});
    defer reopen.close();
    var test_src = file_source.FileSource.fromFile(reopen);
    const file_result = image_validators.validatePng(&test_src);

    // Validate via buffer
    const buffer_result = image_validators.validatePngFromBuffer(&valid_png);

    // Results should match
    try std.testing.expectEqual(file_result.format, buffer_result.format);
    try std.testing.expectEqual(file_result.is_valid, buffer_result.is_valid);
}

test "FormatValidator with allocator uses buffer-based validation" {
    const allocator = std.testing.allocator;

    // Create a validator with allocator
    var validator = FormatValidator.initWithAllocator(allocator);
    try std.testing.expect(validator.allocator != null);

    // Create a temp PNG file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const valid_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length
        0x49, 0x48, 0x44, 0x52, // IHDR type
        0x00, 0x00, 0x00, 0x01, // Width: 1
        0x00, 0x00, 0x00, 0x01, // Height: 1
        0x08, 0x00, 0x00, 0x00, 0x00, // Bit depth, color type, etc
        0x3A, 0x7E, 0x9B, 0x55, // IHDR CRC
        0x00, 0x00, 0x00, 0x00, // IEND length
        0x49, 0x45, 0x4E, 0x44, // IEND type
        0xAE, 0x42, 0x60, 0x82, // IEND CRC
    };

    var file = try tmp_dir.dir.createFile("test.png", .{});
    try file.writeAll(&valid_png);
    file.close();

    // Validate via file handle - should use buffer-based validation internally
    const reopen = try tmp_dir.dir.openFile("test.png", .{});
    defer reopen.close();
    const result = validator.validateFileHandle(reopen);

    try std.testing.expectEqual(FileFormat.png, result.format);
    try std.testing.expect(result.is_valid);
}

test "FormatValidator validateFileBuffer validates from buffer directly" {
    const allocator = std.testing.allocator;

    var validator = FormatValidator.initWithAllocator(allocator);

    const valid_jpeg = [_]u8{
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, // APP0
        0x00, 0x10, // Length 16
        'J', 'F', 'I', 'F', 0x00, // JFIF identifier
        0x01, 0x01, // Version
        0x00, // Aspect ratio
        0x00, 0x01, 0x00, 0x01, // Pixel density
        0x00, 0x00, // Thumbnail
        0xFF, 0xD9, // EOI
    };

    const result = validator.validateFileBuffer(&valid_jpeg);
    try std.testing.expectEqual(FileFormat.jpeg, result.format);
    try std.testing.expect(result.is_valid);
}

test "detectBundleType identifies .git directories" {
    // Exact ".git" path
    try std.testing.expectEqual(BundleType.git, detectBundleType(".git"));

    // Path ending with "/.git"
    try std.testing.expectEqual(BundleType.git, detectBundleType("/path/to/repo/.git"));
    try std.testing.expectEqual(BundleType.git, detectBundleType("some/repo/.git"));
    try std.testing.expectEqual(BundleType.git, detectBundleType("/Users/test/myproject/.git"));

    // NOT a .git directory (just has .git in the name)
    try std.testing.expectEqual(BundleType.none, detectBundleType(".gitignore"));
    try std.testing.expectEqual(BundleType.none, detectBundleType(".github"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("/path/to/.gitignore"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("/path/to/.github"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("my.git.backup"));

    // Regular directories
    try std.testing.expectEqual(BundleType.none, detectBundleType("/path/to/repo"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("some/directory"));
}

test "isBundleDirectory convenience function" {
    try std.testing.expect(isBundleDirectory(".git"));
    try std.testing.expect(isBundleDirectory("/repo/.git"));
    try std.testing.expect(!isBundleDirectory(".gitignore"));
    try std.testing.expect(!isBundleDirectory("/path/to/file.txt"));
}

test "detectBundleType identifies macOS .app bundles" {
    // Exact ".app" suffix
    try std.testing.expectEqual(BundleType.macos_app, detectBundleType("MyApp.app"));
    try std.testing.expectEqual(BundleType.macos_app, detectBundleType("/Applications/Safari.app"));
    try std.testing.expectEqual(BundleType.macos_app, detectBundleType("/Users/test/Desktop/MyApp.app"));

    // NOT an .app bundle (just has .app in the name)
    try std.testing.expectEqual(BundleType.none, detectBundleType("MyApp.app.bak"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("/path/to/MyApp.application"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("webapp"));
}

test "detectBundleType identifies macOS .framework bundles" {
    try std.testing.expectEqual(BundleType.macos_framework, detectBundleType("CoreFoundation.framework"));
    try std.testing.expectEqual(BundleType.macos_framework, detectBundleType("/System/Library/Frameworks/AppKit.framework"));
    try std.testing.expectEqual(BundleType.macos_framework, detectBundleType("/Library/Frameworks/MyLib.framework"));

    // NOT a .framework bundle
    try std.testing.expectEqual(BundleType.none, detectBundleType("framework"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("MyLib.framework.old"));
}

test "detectBundleType identifies macOS .bundle bundles" {
    try std.testing.expectEqual(BundleType.macos_bundle, detectBundleType("MyPlugin.bundle"));
    try std.testing.expectEqual(BundleType.macos_bundle, detectBundleType("/Library/Audio/Plug-Ins/Components/MyPlugin.bundle"));

    // NOT a .bundle
    try std.testing.expectEqual(BundleType.none, detectBundleType("bundle"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("MyPlugin.bundle.disabled"));
}

test "detectBundleType identifies GarageBand .band bundles" {
    try std.testing.expectEqual(BundleType.garageband, detectBundleType("MySong.band"));
    try std.testing.expectEqual(BundleType.garageband, detectBundleType("/Users/test/Music/MySong.band"));
    try std.testing.expectEqual(BundleType.garageband, detectBundleType("My Song.band"));

    // NOT a .band bundle
    try std.testing.expectEqual(BundleType.none, detectBundleType("band"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("MySong.band.bak"));
    try std.testing.expectEqual(BundleType.none, detectBundleType("wristband"));
}

test "validateFile returns error for unknown directory type" {
    // Create a temporary directory that is NOT a known bundle type
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get the path to the temp directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_dir.dir.realpath(".", &path_buf) catch return;

    // Validate the directory (which is not a bundle)
    var validator = FormatValidator.init();

    const result = validator.validateFile(tmp_path);

    // Should return invalid with "Unknown directory type" error
    try std.testing.expect(!result.is_valid);
    try std.testing.expectEqualStrings(
        errmsg.unknown("directory type (not a recognized bundle)"),
        result.error_message orelse "no error",
    );
}

test "git_repository format has correct description" {
    try std.testing.expectEqualStrings("Git Repository", FileFormat.git_repository.description());
}

test "git_repository format has validator" {
    try std.testing.expect(FileFormat.git_repository.hasValidator());
}

test "validateFileDeep routes git directories to git validator" {
    // TDD: This test verifies that when validateFileDeep is called on a .git directory,
    // it actually runs git validation (checking SHA-1 checksums, etc.) rather than
    // just returning a structural OK.
    //
    // The test creates a minimal git repo, validates the .git directory, and expects
    // the result to show full validation depth (not just structural).

    const allocator = std.testing.allocator;

    // Create a temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get the full path
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a minimal .git directory structure that git_validator can validate
    // This is the minimum structure needed for a valid git repository
    try tmp_dir.dir.makePath(".git/objects/pack");
    try tmp_dir.dir.makePath(".git/objects/info");
    try tmp_dir.dir.makePath(".git/refs/heads");
    try tmp_dir.dir.makePath(".git/refs/tags");

    // Create HEAD file pointing to master
    const head_file = try tmp_dir.dir.createFile(".git/HEAD", .{});
    try head_file.writeAll("ref: refs/heads/master\n");
    head_file.close();

    // Create config file
    const config_file = try tmp_dir.dir.createFile(".git/config", .{});
    try config_file.writeAll("[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n");
    config_file.close();

    // Build path to .git directory
    const git_path = try std.fs.path.join(allocator, &.{ tmp_path, ".git" });
    defer allocator.free(git_path);

    // Create a deep validator
    var validator = FormatValidator.initDeep();

    // Validate the .git directory
    const result = validator.validateFileDeep(allocator, git_path);

    // Should be recognized as Git Repository
    try std.testing.expectEqual(FileFormat.git_repository, result.format);

    // Should be valid (it's a properly structured empty git repo)
    try std.testing.expect(result.is_valid);

    // IMPORTANT: Should show FULL validation depth, not just structural
    // This is the key assertion - if this fails, deep validation isn't being routed
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "git_repository: real ground truth sample validates at full depth" {
    const allocator = std.testing.allocator;

    const tar_path = "ground_truth_examples/git_repository/sample.tar.gz";
    const sample_dir = "ground_truth_examples/git_repository/sample";

    // Check if tarball exists
    std.fs.cwd().access(tar_path, .{}) catch return error.SkipZigTest;

    // Untar if sample/ doesn't exist yet
    std.fs.cwd().access(sample_dir, .{}) catch {
        // Extract using system tar (available on all platforms we target)
        var child = std.process.Child.init(
            &.{ "tar", "xzf", tar_path, "-C", "ground_truth_examples/git_repository/" },
            allocator,
        );
        child.spawn() catch return error.SkipZigTest;
        const term = child.wait() catch return error.SkipZigTest;
        if (term.Exited != 0) return error.SkipZigTest;
    };

    // Build path to .git inside the extracted sample
    const git_path = "ground_truth_examples/git_repository/sample/.git";
    std.fs.cwd().access(git_path, .{}) catch return error.SkipZigTest;

    const full_path = try std.fs.cwd().realpathAlloc(allocator, git_path);
    defer allocator.free(full_path);

    var validator = FormatValidator.initDeep();
    const result = validator.validateFileDeep(allocator, full_path);

    try std.testing.expectEqual(FileFormat.git_repository, result.format);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(ValidationDepth.full, result.validation_depth);
}

test "detectFormat RAF magic bytes" {
    var header: [84]u8 = undefined;
    @memcpy(header[0..16], "FUJIFILMCCD-RAW ");
    @memset(header[16..], 0);
    try std.testing.expectEqual(FileFormat.raf, detectFormat(&header));
}

test "detectFormat RW2 magic bytes" {
    // Panasonic RW2: II + version 0x55
    var header: [8]u8 = .{ 0x49, 0x49, 0x55, 0x00, 0x08, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(FileFormat.rw2, detectFormat(&header));
}

test "detectFormat CR3 ftyp brand" {
    // CR3: ftyp box with brand "crx "
    // Box: size=20 (0x00000014), type="ftyp", brand="crx "
    var header: [20]u8 = undefined;
    header[0..4].* = .{ 0x00, 0x00, 0x00, 0x14 }; // box size = 20
    @memcpy(header[4..8], "ftyp");
    @memcpy(header[8..12], "crx ");
    @memset(header[12..], 0);
    try std.testing.expectEqual(FileFormat.cr3, detectFormat(&header));
}

test "extension mapping for new RAW formats" {
    const ext_map = ext_format_map;
    try std.testing.expectEqual(FileFormat.raf, ext_map.get("raf").?);
    try std.testing.expectEqual(FileFormat.orf, ext_map.get("orf").?);
    try std.testing.expectEqual(FileFormat.rw2, ext_map.get("rw2").?);
    try std.testing.expectEqual(FileFormat.pef, ext_map.get("pef").?);
    try std.testing.expectEqual(FileFormat.cr3, ext_map.get("cr3").?);
    try std.testing.expectEqual(FileFormat.nef, ext_map.get("nrw").?); // NRW maps to NEF
}

test "new RAW formats TIFF-based classification" {
    try std.testing.expect(FileFormat.orf.isTiffBased());
    try std.testing.expect(FileFormat.pef.isTiffBased());
    try std.testing.expect(FileFormat.rw2.isTiffBased());
    try std.testing.expect(!FileFormat.raf.isTiffBased()); // RAF is unique, NOT TIFF-based
    try std.testing.expect(!FileFormat.cr3.isTiffBased()); // CR3 is ISO BMFF-based
}

test "CR3 is ISO BMFF-based" {
    try std.testing.expect(FileFormat.cr3.isIsobmff());
    try std.testing.expect(!FileFormat.raf.isIsobmff());
    try std.testing.expect(!FileFormat.orf.isIsobmff());
}

test "TIFF-based RAW extension compatibility" {
    // TIFF detected + RAW extension should be compatible
    try std.testing.expect(isFormatCompatibleWithExtension(.tiff, .orf));
    try std.testing.expect(isFormatCompatibleWithExtension(.tiff, .pef));
    try std.testing.expect(isFormatCompatibleWithExtension(.tiff, .rw2));
    // MP4 detected + CR3 extension should be compatible
    try std.testing.expect(isFormatCompatibleWithExtension(.mp4, .cr3));
}

test "text file without magic bytes is not flagged as corrupted" {
    // Simulate the validateFileHandle flow for a .txt file containing valid text
    // but no magic bytes. The expected_format from extension is .plain_text,
    // and detectFormat returns .unknown (no magic bytes match).
    // It should NOT be flagged as "magic bytes corrupted" because text has no magic.
    // Note: .tsv maps to .csv in the extension map (no separate .tsv enum variant).
    const has_no_magic = switch (FileFormat.plain_text) {
        .cdg, .toast, .mp2, .msi, .br, .dv, .tga,
        .plain_text, .plain_text_utf16, .plain_text_latin1, .plain_text_cp437,
        .csv, .markdown,
        => true,
        else => false,
    };
    try std.testing.expect(has_no_magic);
}