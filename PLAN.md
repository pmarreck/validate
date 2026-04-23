# Plan

Checkbox-only list of specific work items. Keep recent completions with EST timestamps; prune older completed items regularly.

## Active

### Dependency Updates
- [x] Update z7z to latest — ZSTD codec support (2026-04-16)
- [x] Update compact_pro, sqlite3, zlib (2026-04-16)

### Build / Packaging
- [x] Windows packages ship validate_core.lib with all deps bundled via zig lib (2026-04-17 ~10:00 EST)
- [x] Add windows-aarch64 to CI matrix (2026-04-17 ~10:20 EST)

### Memory Optimization (16GB laptops OOM on large scans)

Root cause: many validators allocate heap copies of mmap'd data, and decompression materializes
full output. Combined with thread pool concurrency, this causes multi-GB RSS spikes.

#### Phase 0: Infrastructure — DONE 2026-04-18
- [x] FileSource.getMappedSlice() + getMappedRange() (2026-04-18 EST)
- [x] validate_system_memory() / validate_set_max_memory() FFI (2026-04-18 EST)
- [x] --max-memory / MAX_MEMORY env var support (2026-04-18 EST)
- [x] --jobs / -j CLI flag (already existed)
- [ ] Streaming zlib inflate API (deferred to Phase 2)
- [ ] Runtime memory pressure throttling (deferred to Phase 4)

#### Phase 1: Double-buffer elimination — DONE 2026-04-18 (26 commits)
All validators that used FileSource + file-size heap allocation now use mmap
zero-copy with heap fallback. Saves ~200MB heap per 200MB file per thread.
Files refactored: text_format_validators, apple_validators, pe_validator,
archive_validators, document_validators, movie_validators, scientific_validators,
game_asset_validators, image_validators, email_validators, game_validator,
crypto_validators, creative_validators, cad_3d_validators, pim_validators,
edi_validators, blar_validator, sevenz_validator, music_validators,
flac_decoder, dmg_validator.

#### FUTURE: FileSource refactor (130 deep validators)
Refactor all validate*Deep(path) functions to take *FileSource instead of path.
Unlocks: zero-copy test-coverage, validate-from-buffer FFI, cleaner architecture.
When doing Phase 2/3 refactors, prefer changing to *FileSource at the same time.

#### Phase 2: Streaming decompression (medium risk, high impact on archives/PDFs)
Replace full-output inflate with streaming chunked validation.

- [ ] `pdf_image_validator.zig` — inflateZlibAllocWithRatio → stream (lines ~123, 134)
- [ ] `pdf_font_validator.zig` — inflateZlibAllocWithRatio → stream (lines ~600, 611)
- [ ] `pdf_embedded_file_validator.zig` — inflateZlibAllocWithRatio → stream (lines ~372, 382)
- [ ] `git_validator.zig` — loose object inflate 100MB → stream (line ~340)
- [ ] `apple_media_db_validator.zig` — 64MB inflate → stream (line ~80)
- [ ] `movie_validators.zig` — metadata inflate → stream (line ~482)
- [ ] `font_validator.zig` — table inflate → stream (line ~439)
- [ ] `format_validation.zig` — BEAM chunk inflate 64MB → stream (lines ~6821-6858)
- [ ] `image_validators.zig` — EXR scanline inflate 16MB/block → per-scanline (line ~1264)
- [ ] `image_validators.zig` — PSD ZIP inflate up to 500MB → stream (lines ~1777-1779)

#### Phase 3: Critical large-allocation fixes
These can cause OOM on their own with a single large file.

- [ ] `flac_decoder.zig` — TWO full file allocations (lines ~686, 770) → stream frame-by-frame
- [ ] `image_validators.zig` — 200MB compressed buffer (line ~1758) → streaming decode
- [ ] `ebml_parser.zig` — 10 frame-collection allocations → streaming frame parser
- [ ] `jbig2_decoder.zig` — row allocation × height → scanline buffer reuse
- [ ] `mpeg_ps_parser.zig` — ES buffer allocation → bounded streaming

#### Phase 4: CLI memory management
- [ ] Auto-detect system RAM, default --max-memory to total_ram/2
- [ ] Large file semaphore: files > 50MB limited to 2 concurrent slots
- [ ] Adaptive thread scaling: monitor RSS, reduce active workers under pressure

### False Positive Fixes (from ~/Pictures FAILS.txt scan, 2026-04-01)
- [x] AAC silence: accept all-tiny-frames (< 8 bytes) as valid silent audio (2026-04-01 ~14:00 EST)
- [x] Minimum file size: MP3 >= 128, BMP >= 58, ADTS >= 128, MPEG-TS >= 188, Tar >= 512 (2026-04-01 ~14:30 EST)
- [x] Text formats (plain_text, csv, markdown + variants) added to has_no_magic list (2026-04-01 ~15:00 EST)

### False Positive Fixes (from real-world scan, 2026-04-10)
- [x] ESD reserved region: skip reserved-region zero-check for ESD (version 0x0E00) — 18 files (2026-04-10 ~21:40 EST)
- [x] CAB Authenticode: allow cbCabinet < file_size when RESERVE_PRESENT flag set — 10 files (2026-04-10 ~21:45 EST)
- [x] MP3 post-ID3 scan: increase frame sync scan limit from 4KB to 128KB — 8 audiobooks (2026-04-10 ~21:40 EST)
- [x] Binary STL detection: add .stl to ext_has_no_magic + has_no_magic + dispatch — 1 file (2026-04-10 ~21:45 EST)
- [x] Pre-UDIF DMG: detect Apple Driver Map (0x4552) + APM validation — 2 files (2026-04-10 ~21:45 EST)

### Self-Extracting Archive Detection
- [x] Detect shell script + binary payload pattern in validatePlainText — shebang + >=5 non-blank lines + binary-to-EOF = WARN (2026-04-10 ~22:00 EST)

### Decompression Honesty: Ratio-Based Corruption Detection + Depth Downgrade
- [x] DecompressResult tagged union in zlib.zig with ratio-aware inflate variants (2026-04-11 ~21:30 EST)
- [x] PDF font validator: ratio-aware decompression, skip reason tracking (2026-04-11 ~21:40 EST)
- [x] PDF image validator: ratio-aware decompression, skip reason tracking (2026-04-11 ~21:40 EST)
- [x] PDF embedded file validator: ratio-aware decompression, skip reason tracking (2026-04-11 ~21:40 EST)
- [x] PDF deep validation: downgrade depth to structural when streams exceed size limit (2026-04-11 ~22:00 EST)

### Kaitai Struct-Guided New Format Wave
Use .ksy specs as reference docs when writing validators for these high-value formats:
- [x] java_class — Java .class bytecode (2026-04-02 ~01:30 EST)
- [ ] dex — Android DEX bytecode
- [x] rpm — Red Hat/Fedora/SUSE packages (2026-04-01 ~23:30 EST)
- [ ] cpio — Inside every rpm and initramfs
- [ ] windows_lnk_file — Windows shortcuts (.lnk)
- [ ] regf — Windows registry hives
- [ ] windows_evt_log — Windows event logs
- [ ] windows_minidump — Windows crash dumps (.dmp)
- [x] pcap — Network packet captures (2026-04-01 ~22:30 EST)
- [x] dbf — dBASE database (Shapefile companion) (2026-04-01 ~15:00 EST)
- [ ] xar — macOS .pkg installer archives
- [ ] dos_mz — DOS MZ executables (PE stub)
- [ ] openpgp_message — PGP encrypted/signed messages
- [ ] ssh_public_key — SSH .pub files
- [ ] wmf — Windows Metafile vector images
- [ ] python_pyc — Python compiled bytecode
- [ ] ext2 — Linux ext2/3/4 filesystem images
- [ ] vfat — FAT12/16/32 filesystem images
- [ ] luks — Linux encrypted disk headers
- [ ] vdi — VirtualBox disk images
- [ ] systemd_journal — systemd journal logs
- [ ] lzh — LHA archive (still used in Japan)
- [ ] pcx — Legacy PCX bitmap image
- [ ] minecraft_nbt — Minecraft Named Binary Tag
- [ ] nitf — National Imagery Transmission Format
- [ ] gcode — G-code for 3D printers/CNC (RS-274 + Marlin/RepRap/Klipper flavors); line-based commands, validatable parameters
- [x] Studio One .song: Add `metainfo.xml` presence check — validates ZIP structure then requires Studio One-specific content (2026-03-29 ~11:30 EST)

### Real-World Scan Findings (2026-03-27)

#### Extension/Detection Tweaks
- [x] DMG+bzip2: Accept .dmg files with bzip2 magic bytes without extension-mismatch warning (2026-03-27 ~15:00 EST)
- [x] MSI/OLE2 disambiguation: Add MSI as recognized OLE2/CFBF subtype with stream-name detection (2026-03-27 ~15:00 EST)

#### New Format Support (from 23K unknowns across 283K-file scan)
- [x] MP2 — MPEG Audio Layer II; reuses MP3 frame validator with format tag override (2026-03-27 ~15:00 EST)
- [x] VMDK — VMware virtual disk; VMDK4/COWD/descriptor sub-format detection + structural validation (2026-03-27 ~15:00 EST)
- [x] CAB — Microsoft Cabinet archive; full header/folder/file structure walk + XOR-fold checksum verification (2026-03-27 ~15:00 EST)
- [x] ESD/WIM — Windows Imaging Format; 208-byte header validation, version/flag discrimination, resource header bounds checking (2026-03-27 ~15:00 EST)
- [x] StuffIt (.sit/.sitx) — Classic v1-4.5 (SIT! magic + CRC-16/IBM), v5 (82-byte text header + CCITT CRC), StuffIt X (element stream) (2026-03-27 ~15:00 EST)
- [x] Toast — Roxio Toast disc image; APM DDR detection + ISO 9660 PVD validation + Application Identifier check (2026-03-27 ~15:00 EST)
- [x] CDG — CD+Graphics karaoke; packet size divisibility, CDG command analysis, tile coordinate bounds checking (2026-03-27 ~15:00 EST)
- [x] RealMedia (.rm) — Chunk-based container walk; .RMF/PROP/MDPR/CONT/DATA/INDX structure validation, num_streams cross-check (2026-03-27 ~15:00 EST)
  - [x] Generated proper RealMedia ground truth with ffmpeg; fixed DATA chunk overrun tolerance (2026-03-29 ~22:00 EST)

### Financial Format Validators
- [ ] Find QBB ground-truth sample (QuickBooks Backup)

### Thread Safety Audit
- [x] Comprehensive review of all validators for non-thread-safe patterns — 146 files audited, all safe (2026-03-07 EST)
  - git_validator.zig: mutex correctly used around git_available cache
  - progress.zig: globals only accessed from main thread (CLI event loop)
  - i18n/mod.zig: setLocale() called once at startup before thread pool creation, read-only thereafter
  - All other validators: stack-local vars only, no shared mutable state
- [x] Fix HEIC `validateHevcData` 1MB stack buffer → heap allocation (2026-03-07 EST)
- [x] Fix HEIC `parseHvcCConfig` static buffer → write-into-caller-buffer (2026-03-07 EST)

### Inbox Review (from entropy_shield agent + strict coverage harness)
- [x] Rich error struct architecture — already implemented: `ValidationErrorCode` enum (28 variants) in `ValidationResult.error_code`, exposed via FFI as `err_code` tag name + `err_detail` (2026-03-07 EST)
- [x] Forward compatibility for enum additions — already implemented: explicit u8 values, append-only, `template_count` for comptime sync (2026-03-07 EST)
- [x] Phoenix template `package.json` classification — already implemented: `containsTemplateMarkers()` detects EEx/ERB `<%`/`%>` in JSON files (2026-03-07 EST)
- [x] Review strict_format_coverage results — 3 `corruption_detection_failed` formats (bai2, mt940, nacha) reclassified as `mixed` (control totals protect amounts but not all text bytes) (2026-03-07 EST)
- [x] Review corruption_opacity classifications — all classifications verified accurate (2026-03-07 EST)

### Unverified Checksum Gaps (audit 2026-03-07)
- [N/A] WavPack per-block CRC-32 — CRC covers decoded audio samples, requires full audio decode (infeasible without decoder)
- [N/A] APE (Monkey's Audio) frame MD5s — requires full audio decode (infeasible without decoder)
- [x] AAC LATM StreamMuxConfig CRC-8 — poly 0x1D, init 0xFF, bit-level over StreamMuxConfig range (2026-03-07 EST)
- [x] MP3 Layer I/II CRC-16 — same poly as Layer III, covers header[2..4] + bit allocation table (2026-03-07 EST)

### Wave 1: Archival Format Validators (design: docs/plans/2026-02-28-wave1-archival-formats-design.md)
- [x] BagIt (Library of Congress digital preservation) — SHA-256/512 manifest verification, directory bundle (completed 2026-03-12 EST)
- [x] X12 EDI (healthcare/supply chain) — segment/group/interchange control totals (completed 2026-03-12 EST)
- [x] EDIFACT (international trade) — UNT/UNE/UNZ control totals (completed 2026-03-12 EST)
- [x] iCalendar (.ics) — RFC 5545, VEVENT/VTIMEZONE/RRULE (completed 2026-03-12 EST)
- [x] vCard (.vcf) — RFC 6350, structured properties (completed 2026-03-12 EST)
- [x] PEM/DER — ASN.1 structure, X.509 certificate fields (completed 2026-03-12 EST)
- [x] Ground truth samples (synthetic, flagged for future real-world replacement) (completed 2026-03-12 EST)
- [x] Wire up detection, dispatch, FFI, i18n, corruption_opacity (completed 2026-03-12 EST)

### PDF Deep Validation Improvements (from docscan findings, 2026-04-11)
- [x] Fix octal escape overflow in pdf_decryptor.zig — widen u8 to u16 (2026-04-11 ~22:50 EST)
- [x] Replace unchecked @intCast with std.math.cast in pdf_validator/pdf_xref_parser — 5 sites, 6 tests (2026-04-11 ~23:00 EST)
- [x] Add font stream decompression cache + deduplication — prevent OOM on many-font PDFs (2026-04-11 ~23:00 EST)
- [x] Audit for use-after-free on dict key pointers in pdf_font_validator — SAFE (all slices point into stable raw buffer) (2026-04-11 ~22:30 EST)
- [ ] ToUnicode CMap validation — verify valid Unicode codepoints, well-formed hex, range consistency
- [ ] Font /Encoding consistency check — detect encoding mismatches between declaration and usage
- [ ] Content stream font reference validation — verify Tf operators resolve to /Resources /Font entries
- [ ] Cross-reference completeness — detect dangling references and unreachable objects
- [ ] Report detected text encoding in PDF validation result (e.g., WinAnsi, Identity-H, custom CMap)

### macOS Bundle Deep Validation
- [x] Parse Info.plist and validate required keys (CFBundleIdentifier, CFBundleExecutable, CFBundleName, etc.) (2026-04-14)
- [x] Verify declared CFBundleExecutable exists in Contents/MacOS/ and is a valid Mach-O binary (2026-04-14)
- [x] Validate code signature presence — warns "may not launch on modern macOS" if missing (2026-04-14)
- [x] Manifest completeness check: detect stray files in Contents/ not in expected allowlist (2026-04-14)
- [x] Binary plist parser — extract keys from bplist00 format (trailer/offset table/object table) (2026-04-14)
- [x] WrappedBundle (iOS Catalyst) app detection — structural validation (2026-04-14)
- [x] Skip extension-mismatch warning for directory-based bundle formats (2026-04-14)
- [ ] .framework: validate Versions/Current symlink target exists, Headers/ contains valid headers
- [ ] .bundle: validate plugin structure (Contents/MacOS/ executable + Info.plist)
- [ ] CodeResources manifest verification: parse _CodeSignature/CodeResources, verify all listed files exist and no unlisted files present
- [ ] Additional macOS bundle types to detect and validate:
  - [ ] .kext (kernel extensions)
  - [ ] .prefPane (System Preferences/Settings panes)
  - [ ] .plugin (generic plugins — QuickLook, Spotlight, etc.)
  - [ ] .appex (app extensions — widgets, share extensions)
  - [ ] .xpc (XPC services)
  - [ ] .qlgenerator (QuickLook generators)
  - [ ] .mdimporter (Spotlight importers)
  - [ ] .saver (screensavers)
  - [ ] .component (Audio Units)
  - [ ] .driver (I/O Kit drivers)

### Depth Honesty Audit
- [ ] Future: Add `best_effort` tier to distinguish "parsed every byte, no integrity mechanism" from "only checked headers"

### High-Priority Validation Gaps (Stub-Only Formats)
These formats return WARN — recognized but NO real corruption detection:
- [ ] `bwproject` (Bitwig Studio) — proprietary, undocumented
- [x] `cpr` (Cubase) — RIFF chunk tree walking with bounds checking (2026-03-29 ~23:00 EST)
- [x] `ptx` (Pro Tools) — XOR decryption (clean-room from ptformat) + ZMARK block structure walk (2026-03-30 ~01:00 EST)
- [x] `band` (GarageBand) — macOS bundle validation: projectData/Alternatives detection + plist header check (2026-03-30 ~01:00 EST)
- [x] `reason` (Reason Studios) — real magic "Propellerheads Reason Song File\x1A" + IFF chunk walk (2026-03-30 ~00:30 EST)
- [ ] `cwk` (ClarisWorks/AppleWorks) — obsolete, magic bytes only
- [ ] `mwd` (MacWrite) — obsolete, version bytes only
- [x] `bsp` (Quake/Source BSP) — full lump directory parsing, bounds + overlap detection (2026-03-29 ~23:00 EST)
- [x] `vpk` (Valve PAK) — full tree walk, 0xFFFF terminators, v2 section size cross-validation (2026-03-29 ~23:00 EST)

### Ground-Truth Sample Coverage
- [ ] `song` (Studio One) — needs Peter to provide sample
- [x] 3 abort traps fixed in zigimg fork (52c4b9a: LZW, PackBits, strip reader crash fixes) (2026-03-07 EST)

### Future Investigation: Kaitai Struct as Reference Library
- [ ] Use .ksy specs (https://github.com/kaitai-io/kaitai_struct_formats) as reference when writing new validators
  - 170-200+ format specs in YAML covering archives, images, media, executables, filesystems, etc.
  - Format gallery: https://formats.kaitai.io/
  - **No Zig or C target** — closest are C++/STL and Rust, impractical for pure-Zig FFI
  - **Parsing != validation**: lacks checksum verification, bitstream entropy decoding, semantic cross-field validation
  - **Best use: .ksy YAML as machine-readable format documentation** (field offsets, types, enums, valid ranges)
  - Not worth integrating as a dependency (GPLv3 compiler, code-gen build step, structural-only parsing)

## Recently Completed
- [x] OLE2 DIFAT/mini-FAT validation: unused DIFAT entries + mini-FAT bounds check, XLS 3/5 → 5/5 (transparent) (2026-03-10 EST)
- [x] TAR data block padding validation: POSIX zero-fill check, 3/5 → 4/5 (2026-03-10 EST)
- [x] Shapefile opacity reclassified: mixed → transparent (5/5 confirmed) (2026-03-10 EST)
- [x] HDF5 Fletcher-32 chunk checksum verification: FADB scanning + per-chunk validation, 1/5 → 3/5 (2026-03-10 EST)
- [x] WARC SHA-1 block digest verification: regenerated sample with digests, 1/5 → 4/5 (2026-03-10 EST)
- [x] AppleDouble format detection via magic bytes (2026-03-10 EST)
- [x] N64 CRC validation: unified CIC variant support (6101/6102/6103/6105/6106) with auto-detection, 266/266 real-world ROMs pass (2026-03-10 EST)
- [x] Genesis magic-byte detection: "SEGA" at offset 0x100, enables 790+ .bin ROM validation (2026-03-10 EST)
- [x] GIF structural validation: sub-block chain + block type + extension parsing (2026-03-10 EST)
- [x] HDF5 v2/3 sample promoted to primary for corruption testing, 0/5 → 1/5 (2026-03-10 EST)
- [x] Opacity reclassification: BEAM (mixed→transparent), pdb_struct (opaque→transparent) — harness confirms 5/5 detection for both (2026-03-09 EST)
- [x] ICNS deep validation: embedded PNG CRC-32 verification, 5/5 corruption detection (2026-03-09 EST)
- [x] XLS record type validation: 140+ known BIFF8 types, 3/5 → 4/5 corruption detection (2026-03-09 EST)
- [x] TAR end-of-archive zero block validation, 2/5 → 3/5 corruption detection (2026-03-09 EST)
- [x] Dependency updates: rarz (CRC32 hw accel) + switch sevenz → z7z cleanroom (2026-03-07 EST)
- [x] HEIC stack overflow fix — thread-safe heap allocation (2026-03-07 EST)
- [x] Corruption detection improvements: FLAC CRC, WebP RIFF, ASF, HDF5, DOC, SQLite, JPEG (2026-03-07 EST)
- [x] HEIC CABAC deep validation: full H.265 CABAC per-tile decoder (2026-03-06 EST)
- [x] MS-DOC deep decode: PCD physical offset verification + PlcBte validation (2026-03-05 EST)
- [x] MS-XLS deep decode: SST strings, formula tokens, cell records (2026-03-05 EST)
- [x] Corruption detection experiment: sniper/shotgun framework, full survey of 20+ formats (2026-03-05 EST)

## Future / Roadmap

### Memory Pressure: Parallel Validation of Large Files
- [ ] Per-worker memory cap: skip full decode and fall back to structural if single file exceeds N MB
- [ ] Expose recommended-threads-for-memory-budget API (e.g., given 8GB RAM, suggest 4 threads max for RAW photos)
- [ ] Investigate whether ArenaAllocator backed by page_allocator returns memory to OS promptly on deinit
- [ ] Consider madvise(MADV_FREE) hint after arena deinit for more aggressive page reclaim
- [ ] Profile peak memory with 8 threads × 50MB RAW files — is it 8×50MB = 400MB peak, or does arena growth cause more?

### Infrastructure: Ground Truth Samples Migration
- [ ] Move test samples to external private location
- [ ] Symlink or fetch script to make samples available locally
- [ ] Update .gitignore as needed
- [ ] Purge binary history from validate repo via git filter-repo
- [ ] Add ground truth for EVERY format and variant we parse (multiple examples per format)
- [ ] Track sample provenance (source URL, license, camera model, etc.) in a manifest

### Infrastructure: Built-in Corruption Coverage Testing

**Shipped:**
- [x] `validate --test-coverage <file>` runs in-memory corruption rounds and reports detection rate (2026-04-18 EST)
- [x] Corruption modes in-memory: sniper, shotgun, header, tail, zeroed, xor (2026-04-18 EST)
- [x] Per-mode detection-rate table in CLI output (2026-04-18 EST)
- [x] ANSI 256-color heatmap of undetected-corruption density across file (2026-04-18 EST)
- [x] Per-round event log (mode/offset/bit/size/detected) available via `VALIDATE_COVERAGE_TRACE=1` (2026-04-19 EST)
- [x] Deterministic replay via `VALIDATE_SEED=N` (2026-04-19 EST)

**Remaining — full spec, execute in order:**

1. [x] CLI `--modes sniper,shotgun` (comma-sep English names, default = all 6 current modes). Plus FFI param `uint32_t modes_bitmask` (bit N = CorruptionMode N; 0 = all). (2026-04-20 EST, commit 0727a74)
2. [x] CLI `--shotgun-bytes N` (default 4096; clamped to `[1, 1 MiB]`). Applies to shotgun/header/tail/zeroed/xor; also threaded through FFI. (2026-04-20 EST, commit 0727a74)
3. [x] Confidence intervals: 95% Wilson interval on `detected/total` per mode. Table gained `95% CI` column. (2026-04-20 EST)
4. [x] **Memory optimization — restore-only-corrupted-region**: alloc work buffer once, memcpy `original` once. Per round: apply corruption, validate, `@memcpy(work[off..off+size], original[off..off+size])`. Debug-build sentinel-hash (1 KiB outside corrupted range) catches any validator that writes to its read-only input. Full-resync every 64 rounds. (2026-04-20 EST)
5. [x] CLI `--no-heatmap` flag + terminal-width-aware heatmap (ioctl TIOCGWINSZ on Unix, GetConsoleScreenBufferInfo on Windows; clamped to [40, 200]; 0 disables). (2026-04-20 EST)
6. [x] CLI `--per-mode-heatmap` rendering one labeled bar per active mode (normalized independently; FFI emits heatmap_<mode> keys). (2026-04-20 EST)
7. [x] Multi-threaded rounds: CLI `--coverage-jobs N` (0 = auto = CPU count, capped at 16; 1 = single-threaded). Each worker: own FormatValidator, own working buffer, PRNG seeded `seed + worker_id`, independent event buffer. Results merged into a synthesized CoverageResult. Measured 6.8× speedup on a 10 MB bz2 (31s → 4.5s) at auto-detect on M4 Mac. (2026-04-20 EST)
8. [x] `sparse-noise` mode (opt-in only): flip every Nth bit (N ∈ [1, 31]) across a K-byte region. Default-excluded; requires `--modes sparse-noise`. (2026-04-20 EST)
9. [x] `boundary` mode (opt-in only): concentrates corruption on structurally-critical regions — magic/header (first 64 B), footer (last 64 B), or a 4 KiB-aligned boundary in the interior. Format-agnostic v1; per-format landmark tables (MKV segment tail, ZIP EOCD, JPEG SOI/EOI) are future work. Bit 7 in FFI modes_bitmask. Measured 40% detection vs ~10% for plain shotgun on mpeg4p2 — structural concentration works. (2026-04-20 EST)

10. [ ] *Future*: format-specific boundary landmark tables for high-value formats (ZIP EOCD, PNG IEND, JPEG EOI, MKV segment end). Replace the generic block-boundary heuristic with per-format knowledge where the leverage pays off. Separate PR.

Sign-off: English-only mode names; boundary + sparse-noise opt-in; Debug-build sentinel-hash guard for restore optimization. (Peter 2026-04-20 EST)

### Pre-Launch Corruption Detection Audit (2026-04-23)

Findings from the 6-agent audit captured in `docs/corruption-detection-report.md`. Priority order.

P0 — validator bugs hiding detection:
- [ ] PDF: make `toleratedPdfImageFailures` opt-in (`--repair-mode`) or change CLI to exit non-zero on non-empty `malformations`. Current code silently reclassifies every detected JPEG/Flate/CCITT corruption as `is_valid=true`. Expected lift: 0% → ~55-70% sniper on `nasa_satellite_images_1976.pdf`. Code: `src/core/pdf_validator.zig:43-128, :491, :670`.
- [ ] BMP: 0%/0% despite "fully validated" label — trace why the zigimg BMP decoder either doesn't run or doesn't propagate errors. `src/core/image_validators.zig` (find `validateBmp*`).
- [ ] NRW: add embedded JPEG preview decode path (mirror the DNG/RAF pattern). Currently labeled fully-validated but behaves like TIFF-structural.
- [ ] CLI print bug: video samples print `(fully validated)` even when internal result is `validation_depth=.structural`. Audit `src/core/video_validator.zig:800-826` → rendering path.

P1 — sample replacements (validator already strong, sample picks a weak codec path):
- [ ] Replace `ground_truth_examples/mov/sample.mov` with an H.264 (`avc1`) .mov — current sample is MPEG-4 Part 2 which only has header-level validation. Expected: 6% → ~65-70% shotgun.
- [ ] Replace `ground_truth_examples/webm/jellyfish_360_10s.webm` with a VP9+Opus file — current is VP8 (header-only). Expected: 2% → ~88% shotgun.
- [ ] Replace `ground_truth_examples/avi/generated_testsrc.avi` with MJPEG or H.264 AVI. Expected: 4% → 60-90% shotgun.
- [ ] Add RLE-compressed PSD sample alongside the current RAW one so the strong code path is exercised.
- [ ] Add ZIP/ZIPS compressed EXR sample alongside the NONE-compressed one.

P1 — ground-truth sourcing (too small for shotgun sweep today):
- [ ] DOCX/XLSX/PPTX from Apache Tika `testWORD_various.docx` / `testEXCEL.xlsx` / `testPPT_various.pptx` (Apache 2.0)
- [ ] ODT/ODS/ODP regenerated from Tika files via `libreoffice --headless --convert-to`
- [ ] RTF from Apache Tika `testRTFVarious.rtf`
- [ ] EML from Apache Tika `testRFC822_multipart`
- [ ] MBOX trimmed Enron excerpt or Apache James sample
- [ ] QOI `dice.qoi` from phoboslab/qoi (MIT)
- [ ] ICO multi-res favicon from Wikimedia Commons (CC0)
- [ ] SVG from W3C SVG 1.1 Test Suite
- [ ] Pages authored locally (no permissive public corpus exists)

P2 — deeper validation where format permits:
- [ ] WOFF/WOFF2 origChecksum verification after Flate / Brotli decompress
- [ ] RAF preview-coverage diagnostic: add a smaller Fuji RAF to the sweep alongside the 208 MB one so preview-decode coverage shows up distinctly in the table

P2 — regeneration tooling:
- [ ] Script that walks `docs/corruption-sweep-results/*.tsv` and emits `docs/corruption-detection-report.md` with per-row git-blame dates. Prevents the drift that produced the two conflicting tables we just reconciled.

### Statistical Corruption Detection for Raw Audio/Video Data
For formats without checksums (AU, AMR, CAF, DPX, etc.), use heuristic analysis to detect likely corruption in raw data sections:

- **Temporal discontinuity detection**: sliding-window variance to flag sudden uncorrelated jumps in sample values (real audio has temporal correlation; corruption doesn't)
- **Single-sample outlier with bit-flip diagnosis**: compute statistical unlikelihood of sample[n] given a window of preceding samples. If it exceeds a tolerance AND flipping any single bit in that sample's bytes produces a value that IS statistically probable (fits the local trend), report it as a diagnosed single-bit error with the exact bit identified. This is forensic-grade — not just "something's wrong" but "bit 15 at offset 0x4A02 is flipped."
- **Zero-run analysis**: extended silence in the middle of non-silent audio is suspicious; context-aware detection distinguishing track gaps from corruption
- **Stuck-value detection**: runs of identical non-zero samples (register latch / bus error patterns)
- **Spectral anomaly**: FFT windows to detect unnaturally flat spectra (white noise from bit errors) or DC offsets
- **Sector-aligned weighting**: at known sample rate + bit depth + channels, calculate `corrupted_samples = sector_size / (channels * bytes_per_sample)` for common physical media sector sizes (512B HDD, 2048B DVD, 2352B CD, 4KB/16KB SSD). Statistical anomalies that are approximately sector-width or a multiple (±16 bytes tolerance for header offsets and controller scatter/gather) are weighted as extra-suspect — this is the signature of physical media failure, not encoding artifact.
- **Synthesized audio caveat**: square waves, FM synthesis, and other digital sources CAN have extreme single-sample transitions intentionally. Outlier detection should be weighted by surrounding context (±10 samples smooth = suspicious spike; surrounding samples also extreme = intentional waveform). Sensitivity should be configurable.
- Report as WARN (heuristic, not certain) rather than FAIL
- Applicable to: AU, AMR, CAF, WAV (raw PCM), AIFF, DSD, DPX (raw pixel data), PAM/PBM/PGM/PPM (raw pixel data)
- This would be a genuinely novel validation tier between structural and full
- Module: `src/core/statistical_corruption.zig` with configurable sensitivity