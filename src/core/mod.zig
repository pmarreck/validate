//! Validate Core Library
//!
//! Architectural intent:
//! - This is the single source of truth for validation logic.
//! - Frontends (CLI, future wrappers) call into core via the C FFI.
//! - The core remains platform-agnostic and deterministic; I/O and UX
//!   concerns belong in adapter layers.
//!
//! Boundary summary:
//!   Frontend (CLI) -> C FFI -> Zig Core
//!
//! This module is designed to be used across FFI boundaries with a stable
//! C ABI surface and tests that enforce behavior at the core level.

const std = @import("std");
const builtin = @import("builtin");

// Re-export submodules
pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const compat = @import("compat.zig");
pub const heap = @import("heap.zig");
pub const runtime = @import("runtime.zig");
pub const memory_budget = @import("memory_budget.zig");
pub const racetrack = @import("racetrack.zig");
pub const file_source = @import("file_source.zig");
pub const format_validation = @import("format_validation.zig");
pub const test_coverage = @import("test_coverage.zig");
pub const jpeg_validator = @import("jpeg_validator.zig");
pub const tiffz_shim = @import("tiffz_shim.zig");
pub const alac_validator = @import("alac_validator.zig");
pub const ac3_validator = @import("ac3_validator.zig");
pub const dts_validator = @import("dts_validator.zig");
pub const eac3_validator = @import("eac3_validator.zig");
pub const prores_validator = @import("prores_validator.zig");
pub const prores_decoder = @import("prores_decoder.zig");
pub const video_validator = @import("video_validator.zig");
pub const h264_validator = @import("h264_syntax_validator.zig");
pub const ebml_parser = @import("ebml_parser.zig");
pub const ogg_validator = @import("ogg_validator.zig");
pub const mp3_validator = @import("mp3_validator.zig");
pub const opus_validator = @import("opus_validator.zig");
pub const vorbis_validator = @import("vorbis_validator.zig");
pub const mp3_decode_validator = @import("mp3_decode_validator.zig");
pub const vp9_validator = @import("vp9_syntax_validator.zig");
pub const jpeg2000_validator = @import("jpeg2000_validator.zig");
pub const jxl_validator = @import("jxl_validator.zig");
pub const jbig2_decoder = @import("jbig2_decoder.zig");
pub const ccitt_fax_decoder = @import("ccitt_fax_decoder.zig");
pub const pdf_image_validator = @import("pdf_image_validator.zig");
pub const resource_fork = @import("resource_fork.zig");
pub const bzip2 = @import("bzip2.zig");
pub const ascii_hex_decoder = @import("ascii_hex_decoder.zig");
pub const ascii85_decoder = @import("ascii85_decoder.zig");
pub const run_length_decoder = @import("run_length_decoder.zig");
pub const lzw_decoder = @import("lzw_decoder.zig");
pub const tiff_lzw_decoder = @import("tiff_lzw_decoder.zig");
pub const bmp_decoder = @import("bmp_decoder.zig");
pub const bagit_validator = @import("bagit_validator.zig");
pub const midi_validator = @import("midi_validator.zig");
pub const ole2_validator = @import("ole2_validator.zig");
pub const word_doc_validator = @import("word_doc_validator.zig");
pub const excel_biff8_validator = @import("excel_biff8_validator.zig");
pub const font_validator = @import("font_validator.zig");
pub const pdf_font_validator = @import("pdf_font_validator.zig");
pub const pdf_embedded_file_validator = @import("pdf_embedded_file_validator.zig");
pub const pdf_stream_validator = @import("pdf_stream_validator.zig");
pub const brotli_validator = @import("brotli_validator.zig");
pub const tracker_validator = @import("tracker_validator.zig");
pub const libopenmpt = @import("libopenmpt.zig");
pub const mpeg12_validator = @import("mpeg12_validator.zig");
pub const mpeg12_decoder = @import("mpeg12_decoder.zig");
pub const mpeg4p2_validator = @import("mpeg4p2_validator.zig");
pub const mpeg4p2_decoder = @import("mpeg4p2_decoder.zig");
pub const theora_validator = @import("theora_validator.zig");
pub const theora_decoder = @import("theora_decoder.zig");
pub const theora_decode_validator = @import("theora_decode_validator.zig");
pub const vp8_validator = @import("vp8_validator.zig");
pub const vp8_decoder = @import("vp8_decoder.zig");
pub const vpx_decode_validator = @import("vpx_decode_validator.zig");
pub const mpeg_ts_parser = @import("mpeg_ts_parser.zig");
pub const mpeg_ps_parser = @import("mpeg_ps_parser.zig");
pub const wavpack_decoder = @import("wavpack_decoder.zig");
pub const wavpack_decode_validator = @import("wavpack_decode_validator.zig");
pub const ape_decode_validator = @import("ape_decode_validator.zig");
pub const dmg_validator = @import("dmg_validator.zig");
pub const iso9660_parser = @import("iso9660_parser.zig");
pub const udf_parser = @import("udf_parser.zig");
pub const dvd_validator = @import("dvd_validator.zig");
pub const blu_ray_validator = @import("blu_ray_validator.zig");
pub const iso_validator = @import("iso_validator.zig");
pub const game_validator = @import("game_validator.zig");
pub const game_asset_validators = @import("game_asset_validators.zig");
pub const document_validators = @import("document_validators.zig");
pub const filesystem_validators = @import("filesystem_validators.zig");
pub const gpt_validator = @import("gpt_validator.zig");
pub const pe_validator = @import("pe_validator.zig");
pub const daw_validators = @import("daw_validators.zig");
pub const scientific_validators = @import("scientific_validators.zig");
pub const music_validators = @import("music_validators.zig");
pub const movie_validators = @import("movie_validators.zig");
pub const image_validators = @import("image_validators.zig");
pub const cad_3d_validators = @import("cad_3d_validators.zig");
pub const executable_validators = @import("executable_validators.zig");
pub const apple_validators = @import("apple_validators.zig");
pub const apple_media_db_validator = @import("apple_media_db_validator.zig");
pub const financial_validators = @import("financial_validators.zig");
pub const pim_validators = @import("pim_validators.zig");
pub const edi_validators = @import("edi_validators.zig");
pub const crypto_validators = @import("crypto_validators.zig");
pub const pdf_validator = @import("pdf_validator.zig");
pub const cab_validator = @import("cab_validator.zig");
pub const wim_validator = @import("wim_validator.zig");
pub const vmdk_validator = @import("vmdk_validator.zig");
pub const stuffit_validator = @import("stuffit_validator.zig");
pub const realmedia_validator = @import("realmedia_validator.zig");
pub const network_validators = @import("network_validators.zig");
pub const orf_decoder = @import("orf_decoder.zig");
pub const pef_decoder = @import("pef_decoder.zig");
pub const macos_bundle_validator = @import("macos_bundle_validator.zig");
pub const cdg_validator = @import("cdg_validator.zig");
pub const toast_validator = @import("toast_validator.zig");
pub const blar_validator = @import("blar_validator.zig");
pub const gpt_parser = @import("gpt_parser.zig");
pub const apm_parser = @import("apm_parser.zig");
pub const hfsplus_parser = @import("hfsplus_parser.zig");
pub const zlib = @import("zlib.zig");
pub const git_validator = @import("git_validator.zig");
pub const path_validation = @import("path_validation.zig");
pub const thread_pool = @import("thread_pool.zig");
pub const heic_validator = @import("heic_validator.zig");
pub const avif_validator = @import("avif_validator.zig");
pub const webp_validator = @import("webp_validator.zig");
pub const libraw_validator = @import("libraw_validator.zig");
pub const h265_validator = @import("h265_validator.zig");
pub const h264_syntax_validator = @import("h264_syntax_validator.zig");
pub const aac_syntax_validator = @import("aac_syntax_validator.zig");
pub const aac_huffman_tables = @import("aac_huffman_tables.zig");
pub const h264_cavlc_tables = @import("h264_cavlc_tables.zig");
pub const h264_cabac_tables = @import("h264_cabac_tables.zig");
pub const h264_cabac_engine = @import("h264_cabac_engine.zig");
pub const h265_cabac_tables = @import("h265_cabac_tables.zig");
pub const h265_cabac_decoder = @import("h265_cabac_decoder.zig");
pub const av1_obu_validator = @import("av1_obu_validator.zig");
pub const vp9_syntax_validator = @import("vp9_syntax_validator.zig");
pub const mp4_box_parser = @import("mp4_box_parser.zig");
pub const heif_container_parser = @import("heif_container_parser.zig");
pub const pdf_xref_parser = @import("pdf_xref_parser.zig");
pub const text_format_validators = @import("text_format_validators.zig");
pub const archive_validators = @import("archive_validators.zig");
pub const creative_validators = @import("creative_validators.zig");
pub const email_validators = @import("email_validators.zig");
pub const error_messages = @import("error_messages.zig");
pub const codec_utils = @import("codec_utils.zig");
pub const statistical_corruption = @import("statistical_corruption.zig");
pub const i18n = @import("i18n/mod.zig");
pub const progress = @import("progress.zig");
// VideoToolbox removed — all video codecs use pure-Zig syntax validators

// Version information
pub const version = struct {
    pub const major: u32 = 0;
    pub const minor: u32 = 1;
    pub const patch: u32 = 0;

    pub fn string() []const u8 {
        return "0.1.0";
    }
};

/// Returns the library version string.
pub fn getVersion() []const u8 {
    return version.string();
}

/// Pre-initialize all decoder libraries for thread safety.
/// Call this ONCE from the main thread BEFORE spawning worker threads.
/// This triggers lazy SIMD detection and global state initialization
/// in all C libraries, preventing race conditions during parallel validation.
pub fn preInit() void {
    // libjpeg-turbo preInit was removed when jpegz Phase 1 (2026-05-18)
    // retired the libjpeg-turbo runtime dep. jpegz's cleanroom decoder
    // has no lazy SIMD setup; the warmup is dead weight.
    //
    // libwebp - triggers DSP function initialization
    var webp_init_src = file_source.FileSource.fromBuffer(&[_]u8{});
    _ = webp_validator.validateWebpDeep(&webp_init_src);

    // libjxl - triggers Highway SIMD dispatch selection
    var jxl_init_src = file_source.FileSource.fromBuffer(&[_]u8{});
    _ = jxl_validator.validateJxlDeep(&jxl_init_src);

    // Note: HEIC/AVIF, H.264, H.265, AV1, VP9 all use pure-Zig validators
    // (no C library init needed). VideoToolbox has been removed.
}

test "version" {
    const v = getVersion();
    try std.testing.expectEqualStrings("0.1.0", v);
}

// Include integration tests
test {
    _ = @import("heap.zig");
    _ = @import("memory_budget.zig");
    _ = @import("racetrack.zig");
    _ = @import("concurrent_smoke.zig");
    _ = @import("file_source.zig");
    _ = @import("test_coverage.zig");
    _ = @import("dts_validator.zig");
    _ = @import("bzip2_test.zig");
    // PDF filter decoders
    _ = @import("ascii_hex_decoder.zig");
    _ = @import("ascii85_decoder.zig");
    _ = @import("run_length_decoder.zig");
    _ = @import("lzw_decoder.zig");
    _ = @import("tiff_lzw_decoder.zig");
    // Font validator
    _ = @import("font_validator.zig");
    _ = @import("pdf_font_validator.zig");
    _ = @import("pdf_embedded_file_validator.zig");
    // Image format validators
    _ = @import("jxl_validator.zig");
    _ = @import("bmp_decoder.zig");
    // Audio format validators
    _ = @import("midi_validator.zig");
    // Document format validators
    _ = @import("ole2_validator.zig");
    // MS-DOC (Word Binary) FIB + Table stream cross-validator
    _ = @import("word_doc_validator.zig");
    // MS-XLS (Excel 97-2003) BIFF8 record chain validator
    _ = @import("excel_biff8_validator.zig");
    // Compression validators
    _ = @import("brotli_validator.zig");
    // Tracker/module validators
    _ = @import("tracker_validator.zig");
    // MPEG video validators
    _ = @import("mpeg12_validator.zig");
    _ = @import("mpeg12_decoder.zig");
    // MPEG-4 Part 2 validator and decoder
    _ = @import("mpeg4p2_validator.zig");
    _ = @import("mpeg4p2_decoder.zig");
    // Theora video validator
    _ = @import("theora_validator.zig");
    // Theora decoder
    _ = @import("theora_decoder.zig");
    // Theora deep-decode validator (libtheora)
    _ = @import("theora_decode_validator.zig");
    // VP8 video validator
    _ = @import("vp8_validator.zig");
    // VP8 decoder
    _ = @import("vp8_decoder.zig");
    // VP8/VP9 deep-decode validator (libvpx)
    _ = @import("vpx_decode_validator.zig");
    // MPEG container parsers
    _ = @import("mpeg_ts_parser.zig");
    _ = @import("mpeg_ps_parser.zig");
    // WavPack structural decoder
    _ = @import("wavpack_decoder.zig");
    // WavPack deep-decode validator (libwavpack)
    _ = @import("wavpack_decode_validator.zig");
    // APE deep-decode validator (Monkey's Audio SDK)
    _ = @import("ape_decode_validator.zig");
    // DMG validator
    _ = @import("dmg_validator.zig");
    // ISO 9660 parser
    _ = @import("iso9660_parser.zig");
    // UDF parser
    _ = @import("udf_parser.zig");
    // DVD validator
    _ = @import("dvd_validator.zig");
    // Blu-ray validator
    _ = @import("blu_ray_validator.zig");
    // ISO validator (recursive file validation)
    _ = @import("iso_validator.zig");
    // Game ROM validators (NES, SNES, N64, GB, GBA, NDS, Genesis, CHD)
    _ = @import("game_validator.zig");
    _ = @import("game_asset_validators.zig");
    _ = @import("document_validators.zig");
    _ = @import("filesystem_validators.zig");
    _ = @import("gpt_validator.zig");
    // PE (Portable Executable) validator
    _ = @import("pe_validator.zig");
    // RealMedia container validator (.rm, .rmvb)
    _ = @import("realmedia_validator.zig");
    // DAW project validators (FLP, ALS, RPP)
    _ = @import("daw_validators.zig");
    // Scientific format validators (NetCDF, FITS, DICOM, FASTA, FASTQ)
    _ = @import("scientific_validators.zig");
    // Music/audio format validators (MP3, FLAC, WAV, OGG, MIDI, AC3, etc.)
    _ = @import("music_validators.zig");
    // Movie/video format validators (MP4, MKV, AVI, SWF, FLV, MPEG-TS, etc.)
    _ = @import("movie_validators.zig");
    // Image/photography format validators (PNG, JPEG, TIFF, SVG, PSD, HEIC, etc.)
    _ = @import("image_validators.zig");
    // 3D model and CAD format validators (DWG, DXF, Blender, STEP, STL, OBJ, PLY, glTF, GLB)
    _ = @import("cad_3d_validators.zig");
    // Executable/binary format validators (ELF, Mach-O, COFF, Wasm, ar)
    _ = @import("executable_validators.zig");
    // Apple/macOS format validators (Plist, DS_Store, Spotlight, AppleDouble, resource forks, ClarisWorks, MacWrite)
    _ = @import("apple_validators.zig");
    // Apple Media Library Database validator (Music.app, TV.app .musicdb/.tvdb)
    _ = @import("apple_media_db_validator.zig");
    // Financial data format validators (QBW, QBB, QDF, OFX, QIF, TXF)
    _ = @import("financial_validators.zig");
    // PIM format validators (iCalendar, vCard)
    _ = @import("pim_validators.zig");
    // EDI format validators (X12 EDI, UN/EDIFACT)
    _ = @import("edi_validators.zig");
    // Crypto/certificate format validators (PEM, DER)
    _ = @import("crypto_validators.zig");
    // BagIt (RFC 8493) bag validator
    _ = @import("bagit_validator.zig");
    // StuffIt archive validator (.sit / .sitx)
    _ = @import("stuffit_validator.zig");
    // WIM/ESD (Windows Imaging Format) validator
    _ = @import("wim_validator.zig");
    // Microsoft Cabinet archive validator
    _ = @import("cab_validator.zig");
    // VMware Virtual Disk validator
    _ = @import("vmdk_validator.zig");
    // Network capture format validators (PCAP, PCAPNG)
    _ = @import("network_validators.zig");
    // CD+Graphics karaoke validator
    _ = @import("cdg_validator.zig");
    // Roxio Toast disc image validator
    _ = @import("toast_validator.zig");
    // BLIP archive validator (.blar / .mblar)
    _ = @import("blar_validator.zig");
    // PDF format validator (structural + deep with embedded image/font/file validation)
    _ = @import("pdf_validator.zig");
    // PDF FlateDecode content-stream integrity validator (zlib inflate on every non-image Flate stream)
    _ = @import("pdf_stream_validator.zig");
    // ProRes decoder
    _ = @import("prores_decoder.zig");
    // GPT parser
    _ = @import("gpt_parser.zig");
    // APM parser
    _ = @import("apm_parser.zig");
    // HFS+ parser
    _ = @import("hfsplus_parser.zig");
    // zlib wrapper for robust deflate
    _ = @import("zlib.zig");
    // Git repository validator
    _ = @import("git_validator.zig");
    // Thread pool for parallel task execution
    _ = @import("thread_pool.zig");
    // Path validation (parallel directory traversal)
    _ = @import("path_validation.zig");
    // H.265/HEVC NAL unit validator
    _ = @import("h265_validator.zig");
    // H.264/AVC NAL unit syntax validator
    _ = @import("h264_syntax_validator.zig");
    // AAC syntax validator and Huffman tables
    _ = @import("aac_syntax_validator.zig");
    _ = @import("aac_huffman_tables.zig");
    _ = @import("h264_cavlc_tables.zig");
    _ = @import("h264_cabac_tables.zig");
    _ = @import("h264_cabac_engine.zig");
    _ = @import("h265_cabac_tables.zig");
    _ = @import("h265_cabac_decoder.zig");
    // AV1 OBU validator
    _ = @import("av1_obu_validator.zig");
    // HEIF/HEIC/AVIF container parser and validators
    _ = @import("heif_container_parser.zig");
    _ = @import("heic_validator.zig");
    _ = @import("avif_validator.zig");
    // VP9 syntax validator
    _ = @import("vp9_syntax_validator.zig");
    // MP4/ISOBMFF box parser
    _ = @import("mp4_box_parser.zig");
    // PDF xref table parser
    _ = @import("pdf_xref_parser.zig");
    // Text format validators (JSON, TOML, INI, XML, CSV, RTF, HTML, KML, plain text, UTF-8/16)
    _ = @import("text_format_validators.zig");
    // Archive/compression format validators (ZIP, Gzip, Bzip2, XZ, Zstd, RAR, 7z, Tar, PAR2, WARC)
    _ = @import("archive_validators.zig");
    // Email format validators (EML, MBOX)
    _ = @import("email_validators.zig");
    // Creative suite / Adobe / NLE format validators (Premiere Pro, InDesign, IDML, FCPXML, DaVinci Resolve, Sketch, Illustrator, EPS, After Effects)
    _ = @import("creative_validators.zig");
    // Error message templates
    _ = @import("error_messages.zig");
    // Shared codec utilities (CRC, RBSP, LEB128, etc.)
    _ = @import("codec_utils.zig");
    // Statistical corruption heuristics for raw PCM audio (mono s16 in Phase 1)
    _ = @import("statistical_corruption.zig");
    // PDF decryptor (RC4/AES decryption, string parsing, octal escapes)
    _ = @import("pdf_decryptor.zig");
    // Camera RAW decoders
    _ = @import("orf_decoder.zig");
    _ = @import("pef_decoder.zig");
    // macOS bundle validator
    _ = @import("macos_bundle_validator.zig");
    // i18n (internationalization)
    _ = @import("i18n/mod.zig");
    // Progress bar (progrez wrapper)
    _ = @import("progress.zig");
}
