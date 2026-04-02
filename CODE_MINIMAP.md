# validate Code Minimap

Purpose: quick map of project structure and file purposes. This file should only describe structure and purpose (no issues/TODOs).

## Repository Layout
```
./
├── .github/workflows/  CI workflows (cross-platform builds)
├── src/                Zig validation core
├── ffi/                C ABI exports + header
├── cli/                C CLI wrapper (validate)
├── tests/              Test assets and integration tests
├── bench/              Benchmarks
├── fuzz/               Fuzz targets
├── deps/               Zig dependency build helpers
├── build               Build+test wrapper (nix develop aware)
├── test-windows         Windows test runner via CrossOver/Wine
├── build.zig           Zig build configuration
├── build.zig.zon       Zig dependency lock
├── flake.nix           Nix dev shell
└── *.md                Project documentation
```

## Core (src/)
| Path | Purpose |
|------|---------|
| `src/core/` | Validation logic and format support |
| `src/build/` | Zig build helpers (libtool bundling) |
| `src/core/path_validation.zig` | Parallel path validation with bundle-aware enumeration (.git directories validated as units, not recursed into); honors `MAX_FILES` |
| `src/core/thread_pool.zig` | Thread pool with O(1) ring-buffer work queue (head/len circular buffer with doubling growth), replacing prior O(n) ArrayList dequeue |
| `src/core/format_validation.zig` | Core infrastructure (~6.5K lines): `FileFormat`/`ValidationResult`/`ValidationDepth` types, `detectFormat()` magic-byte detection, `extensionToFormat()` mapping, `FormatValidator` dispatch interface, bundle detection, font wrappers, BEAM validator, shared XML/text helpers, buffer validation API. All domain-specific validators extracted to separate files. |
| `src/core/archive_validators.zig` | ZIP (structural + deep CRC-32), Gzip, Bzip2, XZ, Zstd, RAR, 7-Zip, Tar (full multi-entry header checksums), PAR2, WARC, Brotli, BinHex/HQX. ZIP-based format content checks: EPUB (META-INF/container.xml), DOCX/XLSX/PPTX ([Content_Types].xml + subdir), Studio One .song (metainfo.xml) || `src/core/image_validators.zig` | PNG (CRC-32 deep), JPEG, GIF, BMP, TIFF, WebP, JXL, SVG, EXR (full scanline decompression + offset monotonicity), PSD, PAM, DPX, RAW (DNG/CR2/NEF/ARW) |
| `src/core/music_validators.zig` | WAV, FLAC, MP3, OGG, AIFF, WavPack, APE, DSD (DSF/DFF), AC3, EAC3 (full-file CRC), MIDI, Tracker (MOD/XM/IT/S3M), AMR, AU, TTA, CAF, AAC ADTS |
| `src/core/movie_validators.zig` | MP4, MKV, AVI (RIFF chunk chain + idx1 index), MOV, FLV, WebM, SWF, ASF, DV (full DIF sequence validation), HEIC, AVIF, MPEG-TS |
| `src/core/text_format_validators.zig` | JSON, CSV, TOML, INI, XML, RTF, HTML, KML, plain text, Unicode, CP437 detection |
| `src/core/scientific_validators.zig` | FITS (checksum), DICOM, NetCDF, FASTA, FASTQ, HDF5 (superblock + OHDR/OCHK Jenkins checksum chain), Parquet, MATLAB, NIfTI, PDB (MASTER record cross-validation), CIF, Shapefile |
| `src/core/creative_validators.zig` | Premiere (PRPROJ), InDesign (INDD/IDML), FCPXML, DaVinci (DRP), Sketch, AI, EPS, AEP, PostScript |
| `src/core/cad_3d_validators.zig` | DWG, DXF, STEP, STL, OBJ, PLY, glTF/GLB, Blender, 3MF |
| `src/core/email_validators.zig` | EML, MBOX (with attachment extraction + validation) |
| `src/core/executable_validators.zig` | ELF, Mach-O, COFF, Wasm, Java .class, AR |
| `src/core/pdf_validator.zig` | PDF (structural + deep xref/image/font validation), AI, EPS, AEP, PostScript |
| `src/core/game_validator.zig` | NES, SNES, N64, GB, GBA, NDS, Genesis, CHD, IFF, Blorb |
| `src/core/daw_validators.zig` | FLP, ALS, RPP, Cubase CPR (RIFF chunk walk), Pro Tools PTX (XOR decrypt + ZMARK blocks), GarageBand .band (bundle), Reason (IFF chunks); Bitwig stub only |
| `src/core/pe_validator.zig` | Windows PE executables |
| `src/core/game_asset_validators.zig` | BSP (lump directory parsing + overlap detection), VPK (tree walk + 0xFFFF terminators), WAD, PAK, Chromium PAK, LSPK |
| `src/core/cab_validator.zig` | Microsoft Cabinet archive — MSCF header, CFFOLDER/CFFILE structure walk, CFDATA XOR-fold checksum verification |
| `src/core/wim_validator.zig` | WIM/ESD — 208-byte header, version discrimination, resource header bounds, integrity table validation |
| `src/core/vmdk_validator.zig` | VMware Virtual Disk — VMDK4/COWD/descriptor-only sub-format detection + header field validation |
| `src/core/stuffit_validator.zig` | StuffIt — Classic v1-4.5 (SIT! + CRC-16/IBM), v5 (CCITT CRC), StuffIt X element stream |
| `src/core/realmedia_validator.zig` | RealMedia — .RMF chunk-based walk, PROP/MDPR/CONT/DATA/INDX, num_streams cross-check |
| `src/core/cdg_validator.zig` | CD+Graphics — packet size divisibility, CDG command analysis, tile coordinate bounds |
| `src/core/toast_validator.zig` | Roxio Toast — APM DDR detection + ISO 9660 PVD validation |
| `src/core/blar_validator.zig` | BLIP archive (.blar/.mblar) — uses BLIP library ArchiveReader for LP envelope, magic, outer+per-file checksums (BLAKE3-128/xxHash64/CRC-32) || `src/core/financial_validators.zig` | QBW (QuickBooks Company File, SQL Anywhere + legacy MAUI), QBB (QuickBooks Backup, OLE2), QDF (Quicken Data File, OLE2/ZIP/legacy), OFX (Open Financial Exchange, SGML/XML), QIF (Quicken Interchange Format, text), TXF (Tax Exchange Format, text), NACHA/ACH (fixed 94-char records, entry hash + batch/file integrity), MT940 SWIFT (tagged fields, balance arithmetic), BAI2 (cascading control totals at account/group/file) |
| `src/core/codec_utils.zig` | Shared codec utilities: `Crc32Normal(init,xorout)` comptime-parameterized MSB-first CRC-32 (instantiated as `Crc32Ogg`/`Crc32Mpeg2`/`Crc32Bzip2`), `crc16Ccitt` (RAR4+BinHex), `removeEmulationPreventionBytes` (H.264/H.265 RBSP), `findAnnexBStartCode`, `readLeb128`, `readLe`/`readBe` endian helpers. Consumed by: ebml_parser, ogg_validator, mpeg_ts_parser, bzip2, archive_validators, format_validation, h264_syntax_validator, h265_validator, av1_obu_validator, video_validator |
| `src/core/progress.zig` | C FFI wrapper around progrez library — global ProgrezState + TerminalCaps, exports `validate_progress_{init,detect_caps,set_determinate,set_indeterminate,update,render_line}` for cli/main.c |
| `src/core/i18n/mod.zig` | i18n locale registry/switching, locale detection from env/CLI prefixes, translated string accessors, and cross-locale CLI/env alias maps (30 locales) |
| `src/core/i18n/{bn,hi,pa,ps,sw,ta,th,ur}.zig` | Locale data modules for Bengali/Hindi/Punjabi/Pashto/Swahili/Tamil/Thai/Urdu including core UI strings, full format description catalog, and error/warning translation maps |
| `src/core/git_validator.zig` | Git repository validation using SHA-1 checksums for loose objects, pack files, and index files |
| `src/core/video_validator.zig` | Video container parsing + codec decode validation (MP4/MKV/AVI), MKV byte-coverage with mixed NAL-length handling and debug envs (`MKV_BYTE_DEBUG`, `MKV_BYTE_DEBUG_OUT`, `MKV_BYTE_DEBUG_FRAME_OUT`) |
| `src/core/font_validator.zig` | Standalone font validation (TTF/OTF/CFF/Type1/WOFF/WOFF2) with per-table checksums, whole-file checkSumAdjustment, WOFF zlib decompression + origChecksum verification, and checksum fallback to structural parsing for clearer errors |
| `src/core/pdf_font_validator.zig` | Extracts/validates embedded PDF fonts using strict checksums while reporting warnings instead of failing PDFs |
| `src/core/pdf_image_validator.zig` | PDF embedded image extraction and validation (JPEG, JBIG2, JPEG2000, CCITT) |
| `src/core/pdf_xref_parser.zig` | PDF xref table/stream parser for O(M) object lookup (traditional tables + xref streams + /Prev chain) |
| `src/core/mp4_box_parser.zig` | Shared MP4/ISOBMFF box parsing utilities (readMp4BoxHeader, findChildBox) |
| `src/core/video_audio_validator.zig` | MP4/MKV audio+video stream validation (AAC, ALAC, MP3, FLAC, AC-3 in containers) |
| `src/core/archive_validators.zig` | Archive/compression validation (ZIP/Gzip/Bzip2/XZ/Zstd/RAR/CPT/7z/TAR/PAR2/WARC/RPM), including deep ZIP CRC checks, PAR2 packet MD5 verification, `rarz` in-memory RAR validation, `compact_pro` C FFI-backed CPT validation, WARC deep validation with SHA-1 digest verification (Base32 decode + WARC-Block-Digest), and RPM lead+header+index structure validation |
| `src/core/rar_validator.zig` | Legacy external-tool RAR deep-validation helper (`unrar`/`7z`/`bsdtar`) retained in tree; primary runtime path now uses `rarz` via `archive_validators.zig` |
| `src/core/h264_syntax_validator.zig` | Pure Zig H.264 NAL/SPS/PPS/slice header parser with full VUI and extension support |
| `src/core/h264_cavlc_tables.zig` | H.264 CAVLC entropy decoder (coeff_token, total_zeros, run_before, level VLC) |
| `src/core/h264_cabac_engine.zig` | H.264 CABAC arithmetic engine with context model initialization |
| `src/core/h264_cabac_tables.zig` | H.264 CABAC tables (rangeTabLPS, transIdx, context init values) |
| `src/core/h265_validator.zig` | Pure Zig H.265/HEVC NAL unit parser with VPS/SPS/PPS validation + CABAC decode dispatch |
| `src/core/h265_cabac_decoder.zig` | H.265 CABAC arithmetic decoder for intra slices (split_cu, transform_tree, residual coding with diagonal scan) |
| `src/core/h265_cabac_tables.zig` | H.265 CABAC context models (162 contexts: 48 non-residual + 114 residual), re-exports H.264 arithmetic tables |
| `src/core/av1_obu_validator.zig` | Pure Zig AV1 OBU structural validator (sequence header, frame header, tile group) |
| `src/core/vp9_syntax_validator.zig` | Pure Zig VP9 frame header parser |
| `src/core/heif_container_parser.zig` | HEIF ISOBMFF meta-box parsing (ftyp/hdlr/pitm/iinf/iloc/iprp/iref) for HEIC and AVIF; supports grid images via iref dimg tile reference resolution |
| `src/core/heic_validator.zig` | HEIC validation: HEIF container → hvcC NALs → h265_validator + per-tile CABAC decode; supports grid images via iref dimg; NAL length/type validation, tile count checks |
| `src/core/avif_validator.zig` | AVIF validation: HEIF container → av1C OBUs → av1_obu_validator; supports grid (tiled) images by validating each tile's AV1 bitstream via iref dimg references |
| `src/core/aac_syntax_validator.zig` | AAC-LC bitstream validator (raw AU, ADTS, LATM/LOAS) with Huffman spectral decode |
| `src/core/aac_huffman_tables.zig` | AAC Huffman trees (scalefactor + 11 spectral codebooks) and SWB offset tables |
| `src/core/mpeg_ts_parser.zig` | MPEG-TS demuxer with PAT/PMT CRC-32, CC tracking, PES assembly + stream dispatch |
| `src/core/mp3_decode_validator.zig` | MP3 frame decoder (file and buffer-based) with Huffman + IMDCT validation |
| `src/core/error_messages.zig` | 25 comptime error message template functions (failedToRead, truncated, invalidSignature, etc.) replacing ~2076 string literals |
| `src/core/text_format_validators.zig` | Text format validation (JSON, CSV, TOML, INI, XML, RTF, HTML, KML, plain text, Unicode) |
| `src/core/scientific_validators.zig` | Scientific format validation (FITS, DICOM, NetCDF, FASTA, FASTQ) with honest depth reporting |
| `src/core/music_validators.zig` | Audio format validation (WAV, FLAC, MP3, OGG, AIFF, WavPack, APE, DSD, AC3, EAC3, MIDI, Tracker); WAV/AIFF float PCM deep validation with IEEE 754 NaN/Inf corruption detection |
| `src/core/flac_decoder.zig` | FLAC audio decoder with MD5 verification + per-frame CRC-8 (header, poly 0x07) and CRC-16 (frame, poly 0x8005) integrity checks |
| `src/core/movie_validators.zig` | Video container validation (MP4, MKV, AVI, MOV, FLV, WebM, SWF, ASF, DV, IVF) with depth downgrade on unvalidated audio; IVF deep validation via VP9/AV1 codec dispatch; FLV deep validation via H.264 AVCC→Annex B + AAC stream decode; ASF deep validation walks header child objects + Data Object GUID/packet chain |
| `src/core/image_validators.zig` | Image format validation (PNG, JPEG, GIF, BMP, TIFF, WebP, JXL, SVG, EXR, PSD, PAM, DPX, QOI, TGA, DNG, ICO); ICO deep validation dispatches embedded PNG entries to CRC-32 verification; WebP full RIFF chunk chain walk; PSD exhaustive RLE decode + ZIP decompression |
| `src/core/cad_3d_validators.zig` | 3D/CAD format validation (DWG, DXF, STEP, STL, OBJ, PLY, glTF/GLB, Blender); PLY binary deep validation with float NaN/Inf + face index range checking |
| `src/core/creative_validators.zig` | Creative suite validation (Premiere, InDesign, IDML, FCPXML, DaVinci, Sketch, AI, EPS, AEP) |
| `src/core/email_validators.zig` | Email format validation (EML, MBOX) |
| `src/core/executable_validators.zig` | Binary executable validation (ELF, Mach-O, COFF, Wasm, Java .class bytecode, AR) |
| `src/core/pe_validator.zig` | Windows PE executable validation (DOS header, COFF, optional header, section table) |
| `src/core/daw_validators.zig` | DAW project validation (FLP, ALS, RPP, Cubase CPR RIFF chunk walk, Pro Tools PTX XOR-decrypt+block-walk, GarageBand bundle, Reason IFF-walk) || `src/core/game_validator.zig` | Game ROM validation (NES, SNES, N64 w/ CIC auto-detection, GB, GBA, NDS, Genesis, CHD) |
| `src/core/financial_validators.zig` | Financial format validation (QBW, QBB, QDF, OFX, QIF, TXF) |
| `src/core/ole2_validator.zig` | OLE2/CFBF compound document validator — header, FAT, DIFAT, directory; `readNamedStream()` extracts streams by name via FAT/mini-FAT chains |
| `src/core/document_validators.zig` | Document/database format validation — SQLite (page size + B-tree walk), OLE2 dispatch (DOC/XLS/PPT), WordPerfect, MDB/ACCDB (Access), dBASE .dbf (version byte + field descriptor cross-validation) |
| `src/core/word_doc_validator.zig` | MS-DOC (Word 97-2003) deep validator — FIB parsing, 31 fc/lcb Table stream cross-validation pairs (stylesheet, fonts, bookmarks, fields, revision marks, doc properties), CLX/Piece Table with full PCD decode (FcCompressed physical offset verification), PlcBteChpx/PlcBtePapx CP monotonicity + BTE page number bounds; Word 6/95 falls back to structural |
| `src/core/excel_biff8_validator.zig` | MS-XLS (Excel 97-2003) deep validator — BIFF8 record chain parsing, BoundSheet8 offset cross-validation, SST header consistency; older BIFF/encrypted files fall back to structural |
| `src/core/bagit_validator.zig` | BagIt (RFC 8493) archive validation — structural (bagit.txt format) + deep (SHA-256/SHA-512/MD5 manifest verification of payload files) |
| `src/core/edi_validators.zig` | EDI format validation — X12 (ISA self-describing delimiters, SE/GE/IEA control totals) + EDIFACT (UNA/UNB parsing, UNT/UNZ counts) |
| `src/core/pim_validators.zig` | PIM format validation — iCalendar (RFC 5545 BEGIN/END nesting, VERSION/PRODID, component validation) + vCard (RFC 6350 envelope, version-specific required properties) |
| `src/core/network_validators.zig` | Network capture format validation — PCAP (all 4 magic variants: BE/LE × usec/nsec, version check, snaplen bounds, full packet record walk) + PCAPNG (SHB magic + byte-order magic detection) |
| `src/core/crypto_validators.zig` | Crypto format validation — PEM (header/footer matching, base64, ASN.1 DER inside) + DER (ASN.1 TLV recursive parsing with depth limit) |
| `src/core/ebml_parser.zig` | EBML/Matroska container parser with CRC-32 verification (uses `std.hash.Crc32` via codec_utils consolidation) |

## FFI (ffi/)
| Path | Purpose |
|------|---------|
| `ffi/c_api.zig` | C ABI surface for validation |
| `ffi/validate_core.h` | C header for the ABI |

## CLI (cli/)
| Path | Purpose |
|------|---------|
| `cli/main.c` | CLI wrapper around the C FFI, SLOW warnings, and memory telemetry (env `MEM_TELEMETRY`) |

## Tests (tests/)
| Path | Purpose |
|------|---------|
| `tests/fixtures/` | Validation test fixtures |
| `tests/cli/` | CLI integration tests (bash), including archive discrimination checks (`rar_validation`, `cpt_validation`) over valid + 5 deterministic corrupted fixtures |
| `scripts/strict_format_coverage` | Deterministic strict coverage harness: enumerates `hasValidator()` formats, maps ground-truth samples (including extension-aware KMZ mapping), validates valid-path behavior, runs 5 seeded non-magic corruption checks (with per-format protected prefixes, including HQX envelope protection), and classifies failures via `corruption_opacity` policy |
| `scripts/corruption-experiment` | LuaJIT statistical corruption detection estimator — sniper (single-bit flip) and shotgun (4KB overwrite) modes with seeded PCG32, Wilson CI, early stopping, TSV output |

## Documentation
| File | Purpose |
|------|---------|
| `PLAN.md` | Checkbox-only work list |
| `PROJECT_OVERVIEW.md` | Goals and terminology |
| `RULES.md` | Non-negotiable project rules |
| `DOCUMENTATION_GUIDE.md` | Doc locations and writing rules |
| `ROADMAP.md` | Fairly certain future goals |
| `PERF_EXPERIMENTS.md` | Performance experiment log and results |
| `ZIG_RECENT_API_CHANGES_2025.md` | Zig 0.14–0.15 API quick reference for current code |
| `inbox/strict_format_coverage.tsv` | Machine-readable strict per-format audit output (`format`, sample path, valid result, C1..C5, status, opacity, notes) |
| `inbox/strict_format_coverage.md` | Human-readable strict per-format audit checklist/report generated by harness |
| `scripts/corruption_opacity.tsv` | Source-controlled per-format corruption-opacity policy map consumed by strict harness (`transparent` default, `mixed`, `opaque`) |
