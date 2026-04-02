# Plan

Checkbox-only list of specific work items. Keep recent completions with EST timestamps; prune older completed items regularly.

## Active

### False Positive Fixes (from ~/Pictures FAILS.txt scan, 2026-04-01)
- [x] AAC silence: accept all-tiny-frames (< 8 bytes) as valid silent audio (2026-04-01 ~14:00 EST)
- [x] Minimum file size: MP3 >= 128, BMP >= 58, ADTS >= 128, MPEG-TS >= 188, Tar >= 512 (2026-04-01 ~14:30 EST)
- [x] Text formats (plain_text, csv, markdown + variants) added to has_no_magic list (2026-04-01 ~15:00 EST)

### Kaitai Struct-Guided New Format Wave
Use .ksy specs as reference docs when writing validators for these high-value formats:
- [x] java_class — Java .class bytecode (2026-04-02 ~01:30 EST)
- [ ] dex — Android DEX bytecode
- [ ] rpm — Red Hat/Fedora/SUSE packages
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