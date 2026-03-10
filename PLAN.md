# Plan

Checkbox-only list of specific work items. Keep recent completions with EST timestamps; prune older completed items regularly.

## Active

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
- [ ] BagIt (Library of Congress digital preservation) — SHA-256/512 manifest verification, directory bundle
- [ ] X12 EDI (healthcare/supply chain) — segment/group/interchange control totals
- [ ] EDIFACT (international trade) — UNT/UNE/UNZ control totals
- [ ] iCalendar (.ics) — RFC 5545, VEVENT/VTIMEZONE/RRULE
- [ ] vCard (.vcf) — RFC 6350, structured properties
- [ ] PEM/DER — ASN.1 structure, X.509 certificate fields
- [ ] Ground truth samples (synthetic, flagged for future real-world replacement)
- [ ] Wire up detection, dispatch, FFI, i18n, corruption_opacity

### Future: CDC-Segmented Parity for Virtual Manifests
- [ ] Design: Content-Defined Chunking (CDC) hashes recorded per-file BEFORE par2 parity computation
- [ ] When a file changes, identify unchanged CDC chunks by hash to reconstruct a "virtual original"
- [ ] Reduces par2's perceived damage from "entire file changed" to "just the delta chunks differ"
- [ ] Effectively makes par2 content-aware without modifying par2 itself
- [ ] Par2 block sizes align to CDC chunk boundaries rather than fixed offsets

### Depth Honesty Audit
- [ ] Future: Add `best_effort` tier to distinguish "parsed every byte, no integrity mechanism" from "only checked headers"

### High-Priority Validation Gaps (Stub-Only Formats)
These formats return WARN — recognized but NO real corruption detection:
- [ ] `bwproject` (Bitwig Studio) — proprietary, undocumented
- [ ] `cpr` (Cubase) — RIFF header only, needs chunk parsing
- [ ] `ptx` (Pro Tools) — proprietary, undocumented
- [ ] `band` (GarageBand) — proprietary, macOS bundle
- [ ] `reason` (Reason Studios) — proprietary, undocumented
- [ ] `cwk` (ClarisWorks/AppleWorks) — obsolete, magic bytes only
- [ ] `mwd` (MacWrite) — obsolete, version bytes only
- [ ] `bsp` (Quake/Source BSP) — version whitelist only, needs lump parsing
- [ ] `vpk` (Valve PAK) — magic + tree bounds only, needs tree/entry parsing

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
