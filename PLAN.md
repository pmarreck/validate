# PLAN

Active work first; recent completions for continuity; long-range design notes
at the bottom. Older completed sections were rolled up — full history lives in
`git log`.

---

> **Mid-session handoff:** If you are starting fresh after a context wipe, read
> [`NEXT_STEPS.md`](NEXT_STEPS.md) first. It captures the unfinished HEIC/HEIF
> CABAC-desync investigation (#62), the still-pending PDF per-stream
> decryption work (#64), debug tooling guidance, and the recommended path
> forward.

## Active queue

### ⏸ RESUME HERE — fleet wind-down / Thelio migration (2026-07-06→08)
All fuzz work is GREEN + pushed (`yolo` @ this commit). Fleet moved off this Mac
(now a darwin-build appliance); SCM is going **git-native** (jj abandoned per Peter
2026-07-08 — on the Thelio use plain `git`, the block-git hook won't be there).
**Exact resume state:** 11 crashers fixed reproduce-first (9 validate in-tree
[mpeg_ts, jbig2, h265, AVI, mpeg12, PAK, FLAC, PDF-xref] + 2 rarz UB) + rarz enum
fix + rarz ReleaseSafe test-flip + 2 blessed dep fixes (rarz filter-type, jpegz #9
IDCT). Dependency chain is panic-free; the sweep still surfaces validate's own
long-tail (last = PDF-xref `parseTrailerDict` OOB #10).
**Immediate next steps (in order):**
1. Re-bump `.rarz` → `b920d603` (rarz owner landed A/B/C; steps in the rarz item below).
2. Resume the deterministic sweep (`./fuzz` or `zig-out/bin/fuzz-sweep --iters N
   <corpus>`, seed 1592652030) — NO carve-outs; Debug-trace each (ReleaseSafe line
   #s are inlining-misattributed), fix (saturating `+|` / `@as(u64,…)` widen / bounds
   check), reproduce-first test or corpus replay, commit, push. Goal: sweep CLEAN = ship gate.
3. (i)-merge queue: a241→a17d→aba8→ae02→afa34 (hold a0ff/thumbs_db).
### Fuzzing — Tier-1 whole-surface suite LIVE, grinding crashers (2026-06-24)
Built per `docs/FUZZ_PLAN.md`: `tests/fuzz/` harnesses (dispatch + stdin +
deterministic seeded sweep), two-tier oracle (robustness always; gzip-CRC
detection probe proven non-vacuous), `./fuzz` runner, ReleaseSafe nix build,
CI replay (`checks.fuzz`) of committed crashers. Ship stays ReleaseFast.
Crashers found + fixed (reproduce-first), each committed to `tests/fuzz/corpus/`:
- [x] mpeg_ts `getPayloadInfo` u8 overflow on adaptation_length 0xFF (unit test)
- [x] jbig2 `parseSegmentHeader` double-free on truncated data-length (unit test)
- [x] h265 CABAC `residualCoding` abs_level u32 overflow (corpus replay)
- [x] AVI `(chunk_size+1)` u32 overflow ×8 sites → widened to u64 (corpus replay)
- [x] mpeg12 `parseSequenceExtension` size-extension overflow — u12 size fields
  too small for the 14-bit value+extension; widened to u14 (unit test)
- [x] PAK `validatePakDeep` `dir_offset+dir_size` / `file_offset+file_len` u32
  overflow → widened to u64 (unit test)
- [x] FLAC `decodeLpcSubframe` LPC reconstruction — checked `@intCast(i64→i32)`
  panicked on corrupt input; → `@truncate` (matches the `+%=` modular add;
  corruption still caught by frame CRC-16 / stream MD5). Corpus replay (~64 KB).
- [x] PDF xref `parseTrailerDict` index-out-of-bounds — after `i = skipWs(data, i)`
  the entry loop read `data[i]` without re-checking bounds; skipWs can reach
  `data.len` (trailing whitespace / maxout'd dict) → OOB. Added `if (i >= data.len)
  break;`. Fuzz-found max-out-ing an Adobe Illustrator (PDF) sample. Unit test +
  corpus (`tests/fuzz/corpus/pdf/trailer_dict_oob.ai`, 372 B). [9 in-tree fixes now]
- [x] **tiffz→9a2c18e9 BLESSED bump DONE** — jpegz #9 (IDCT overflow) fixed via chain;
  DNG reproducer now decodes clean → INVALID (finding 58); ./test green; pushed.
  Last known DEPENDENCY panic dead (rarz ×3 + jpegz ×2). rarz A/B/C reassigned to a
  dedicated rarz owner agent — HANDS OFF ~/Code/rarz.
- [x] **rarz dependency crash FIXED** (Einstein FIX-NOW ruling 2026-07-01) — corrupt
  RAR5 filter descriptor → `@enumFromInt(u3)` on `FilterType` (only 4 of 8 values)
  → "invalid enum value" panic (Debug/ReleaseSafe) / silent UB (ReleaseFast) in
  `rarz .../unpack50.zig:306`. Fixed in the rarz sibling with
  `std.enums.fromInt(...) orelse return error.InvalidData` (NOTE: `std.meta.intToEnum`
  is gone in 0.16 → `std.enums.fromInt`). rarz yolo `6406ef8e` (pushed); validate
  `.rarz` pin bumped + hashes refreshed; crasher in `tests/fuzz/corpus/rar/`.
  - **✅ secondary finding #1 FIXED (Einstein-authorized 2026-07-01):** flipped rarz's
    unit-test build to **ReleaseSafe** (was ReleaseFast → masked UB); that unmasked 2
    crashers, both fixed reproduce-first (existing tests are the oracle): unpack50
    `byte_count` u2→u8 (guard ran after the narrowing cast); lz `copyMatch` bulk-@memcpy
    physical-non-overlap guard (distance==buffer.len aliased src==dst). rarz yolo
    `a29b2b3b`; validate `.rarz` pin re-bumped + zigDepsHash refreshed; ./test green.
    NOTE (fleet pattern Einstein is recording): sibling libs whose tests run ReleaseFast
    are false-green for the UB class.
  - **secondary finding #2 (shipped WIP + red intermediate commit):** Einstein ACCEPTed
    (tested+green, force-push blocked); flagged to Peter. Process note: build each commit
    before pushing.
- [ ] **NEXT COMMIT CYCLE — re-bump `.rarz` → `b920d603`** (Einstein 2026-07-02, routine,
  NOT sweep-blocking). rarz owner-agent landed all 3 fixes (A harness / B fixture / C the
  real multi-volume split-file CRC bug); rarz yolo `b920d603`, master ./test green in-env +
  sandboxed checks pass. Action: bump url→b920d603, refetch `.rarz.hash` (`zig fetch`),
  refresh `zigDepsHash` (fakeHash→nix-reports trick), ./test, commit+push. validate's RAR
  path was never affected (bug was in rarz's `t` command: authoritative CRC lives in the
  LAST volume part, was compared against the FIRST). **MFIC lesson (worth internalizing):**
  producer==checker round-trip tests (writer+verifier same author, same wrong assumption)
  HID it — now fixed with embedded official-rar fixtures as an INDEPENDENT oracle. HANDS
  OFF ~/Code/rarz (owner agent's repo).
- [x] **rarz A/B/C DONE by the dedicated rarz owner agent** (reassigned by Peter 2026-07-02).
  = 6 failed suites, but ALL of tonight's work EXONERATED — my fixes are correct).
  ⚠ Verification-scope lesson: I claimed rarz "green" from `zig build test` +
  validate `./test` but never ran rarz's **master `./test`** (zig units + 10 CLI
  suites). "Pushed green" must mean the MASTER suite, in-env, going forward.
  Do in order (all in `~/Code/rarz`), each verified via `nix develop -c ./test`:
  - **A (harness, pre-existing, ~min):** `./test` runs CLI suites bare (unrar only in
    devshell → interop fails) + suites use `set -euo pipefail` and `fail(){ ((errors++)); }`
    (`((errors++))` from 0 returns nonzero → `set -e` aborts). Fix: run CLI suites under
    `nix develop -c`; strip `set -e`/pipefail; `errors=$((errors+1))`. (Aligns w/ Peter's
    test-script rules.)
  - **B (MINE, minor):** `fuzz_filter_type_invalid.rar` sits in `tests/fixtures/` whose
    Interop Gate A has an implicit all-valid contract → flags the deliberately-invalid
    fixture. Move to `tests/fixtures/invalid/` (my regression test INLINES the bytes, so
    no path repoint needed) OR teach Gate A to skip `fuzz_*`. Verify Gate A's sweep scope.
  - **C (REAL pre-existing bug, reproduce-first):** multi-volume verify false-INVALID —
    `rarz t tests/fixtures/rar5_vol_store.part1.rar` → "payload CRC32 mismatch" on a VALID
    archive (unrar oracle: All OK; baseline 507922c5 fails identically). Verify path
    miscomputes CRC across the volume span. Committed fixture IS the reproducer (will now
    FAIL loudly once A unhides the suite → red-before-green). validate paid product
    UNAFFECTED (reports the fixture OK). Curiosity poke (non-urgent): what does validate's
    "fully validated" mean for a .part1 whose payload spans 6 volumes?
  - Then the (i)-merge queue: a241→a17d→aba8→ae02→afa34 (hold a0ff/thumbs_db).
- [ ] **TOP MORNING ITEM — tiffz chain bump (BLESSED by Einstein 2026-07-02), unblocks
  the CLEAN sweep.** jpegz owner fixed #9 (IDCT wrapping-with-detection, byte-exact vs
  libjpeg-turbo oracle; the 16MB DNG reproducer now decodes with NO panic and emits
  finding 58 `dct_coefficient_overflow`=FAIL). Also carries a jpegls 16-bit threshold
  correctness fix. Steps:
  1. Bump `.tiffz` pin → `9a2c18e9c5` (full: refetch; NOTE a ~3-min overnight window may
     yield an empty placeholder `28863b7e` — real rev is `9a2c18e9`; carries jpegz
     `cc844e274a057e1bb1fb278ab27cab8da15582b3` via `tiffz.jpegz`, no double-bump).
     Refresh `zigDepsHash` (fakeHash→nix-reports-real trick; the helper is stale-prone).
     tiffz's own zigDepsHash ref = `sha256-ai54zBb6VeSkOBGG5xscMp5PBjvCQeMgW9CbuxGybss=`.
  2. Replay `~/validate-fuzz-repros/jpegz9-idct-overflow-via-dng.bin` → expect no panic,
     verdict INVALID (58 is FAIL-severity). Full `./test`. Commit + push. Ping Einstein.
  3. Optional 2-line polish: add `.dct_coefficient_overflow => "JPEG DCT coefficient
     overflow (corrupt entropy data)"` to `findingCodeMessage` (jpeg_validator.zig) —
     currently falls to generic else; no elevation needed (58 already FAIL at source).
  4. THEN resume the sweep — **zero KNOWN panics remain** (rarz ×3 + jpegz ×2 fixed);
     gate = CLEAN, NO carve-outs (the DNG carve-out dies with this bump).
- [ ] **CONTINUE the sweep** (deterministic, seed 1592652030 default): the
  maxout/splice operators keep surfacing unchecked u32 size/length arithmetic
  across validators — expect more of the same class. Re-run `./fuzz` (or
  `zig-out/bin/fuzz-sweep --iters N <corpus>`), Debug-trace each (ReleaseSafe
  line #s are inlining-misattributed — always confirm with a Debug build),
  fix (saturating `+|` or `@as(u64, …)` widening), reproduce-first test or
  corpus replay, commit, push. Goal: sweep runs CLEAN (ship gate) → ping Einstein.
  Also vary `--seed` to widen coverage; consider an AFL++/honggfuzz coverage run.
- [ ] **AFTER sweep is clean — bump tiffz pin `→ 0d4898c5`** (Einstein ruling
  2026-06-26, gated on sweep-clean). Picks up 5 new jpegz JPEG corruption
  findings via the `tiffz.jpegz` re-export (quantization_table_corrupt,
  sof_component_count_invalid, sos_component_mismatch, progressive/lossless SOS,
  arithmetic_table_corrupt) + a Linux-CI FOD fix. Update `.tiffz` pin, refresh
  `zigDepsHash` (fakeHash trick), `./build` + `./test`, push. Then re-sweep —
  the new finding-paths are fresh untrusted-input surface. Note archived:
  `inbox/processed/2026-06-26-tiffz-jpegz-bump-0d4898c5.md`.
### Corruption report: generated + Bolter column + UTF-8 re-sweep — DONE (2026-06-22)

- [x] **UTF-8 text re-sweep** on validate_gui's new ≥12 KB multibyte fixtures:
      JSON 47→43/100/100, TOML 37→42/100/100, XML 64→52/100/100, HTML 2→22/100/100,
      Plain Text 0→0/0/95 (sniper/bolter/shotgun). — 2026-06-22
- [x] **Fixed CSV silent-pass bug** — `.csv` (UTF-8-required) was omitted from the
      extension-remap dispatch and skipped its UTF-8 check; even a 4 KB random
      overwrite passed as OK. CSV now 0/0/0 → 26/100/100. Guarded by new MFIC
      set-classifier `tests/cli/utf8_required_formats_reject`. — 2026-06-22
- [x] **Report is now generated** — `scripts/generate-corruption-report` (8-col with
      Bolter; flag>env>default paths; `n/a` never blank). Sidecar bootstrapped via
      one-shot `scripts/migrate-report-to-sidecar`. Wave 2026-04-25b heading dissolved
      (13 rows → proper sections), CPT moved Audio→Archive. — 2026-06-22
- [x] **Full bolter sweep** across the corpus (5→145 bolter TSVs); fixed latent
      `corruption-sweep` no-op (`find` → `find -L` on the ground_truth symlink). — 2026-06-22
- [ ] Send validate_pics the 14 category assignments; ready their bolter i18n pass.
- [ ] (held per Peter) RAW preview-JPEG decode across the family (#43) — revisit
      after the above; then re-adjust those RAW numbers.

### Windows x86_64 — COMPILE-parity (2026-06-22); runtime NOT verified in CI

**Honest status (CI-honesty reconcile 2026-06-24):** x86_64-windows is
cross-COMPILED with the full feature set (real JPEG-in-TIFF + JPEG2000 deep
validation), and Garnix *builds* the `.exe` — but **CI never runs it** (no wine
runtime test; the `Test` step runs `checks.test` only for `package == default`,
i.e. the host platform). So "full parity" means **feature/compile parity**, not
runtime-verified-on-Windows. Linux/macOS DO run the full suite. windows-aarch64
has **no binary at all** (upstream nixpkgs aarch64-mingw compiler-rt bug — see
below). Follow-up: a wine smoke test, or keep this honest marking.

x86_64-windows upgraded C-floor → **full parity** (real JPEG-in-TIFF + JPEG2000
deep validation) by driving the jpegz A-track through the pin chain:
jpegz `f60da91f` (vendored openjpeg, lazy; Mode-2 RGB cleanroom fix) → tiffz
`059ff38b` (cleanroom JPEG-in-TIFF, libjpeg dropped) → validate `3312e276`.
Also fixed: file_source.zig Windows `currentPathAlloc` (0.16), libraw moving
`#master` → commit-pinned. All Garnix checks GREEN.

- [x] x86_64-windows: compile-parity, Garnix BUILDS the .exe (not runtime-tested).
      Linux/macOS run the full suite green. — 2026-06-22
- [ ] windows-aarch64: **scope-cut** (`ec8c06d7`) — blocked by upstream nixpkgs
      aarch64-w64-mingw32 compiler-rt libatomic/pthread.h bug (NixOS/nixpkgs#534236;
      not validate code). Re-add when upstream fixes it. Mirrors macos-aarch64 cut.
### Licensing — offline Ed25519 verifier (raised 2026-06-14; Paddle launch-critical)

Contract v1 locked with `mecha_llc_website` (issuer = mecha-commerce Worker;
verifier = validate app, offline). Wire: `b64url_nopad(payload).b64url_nopad(sig)`,
sign/verify over the left ASCII bytes, no `alg` field. **Email-only gate**
(ASCII-lower exact); `name` is display/audit-only (dropped name-matching to kill
a JS↔Zig Unicode-casing divergence). `kid`-selected pubkeys, injected `today`.

- [x] `src/core/license.zig` pure core + 16 tests (happy + every error branch,
      incl. real payload-substitution → bad_signature). Registered in mod.zig.
      Zig suite green via `nix build .#checks.test`. — 2026-06-14
- [ ] C-FFI `mecha_license_verify` + C-CLI dogfood; error_code → bilingual i18n.
- [x] Pin to shared `license_vectors.json` (issuer-authored differential MFIC
      oracle, vendored as `src/core/fixtures/license_vectors.json`): verify()
      reordered to the contract error precedence, `expected_product` now optional,
      dates range-checked, email trimmed. All 18 vector cases agree. — 2026-06-15
- [ ] Embed real per-product pubkeys+kids once mecha-commerce generates them
      (vectors use a test key); production keys arrive via inbox.
### Memory subsystem (raised 2026-04-28; two concurrent runs OOM'd 128 GB Mac)

**Status as of 2026-05-01.** Profiling harness, `heap.validateAllocator`,
`page_allocator` sweep (~110 sites / 26 files), `FileSource.getMappedOrSlurp`,
budget-gated work queue (`VALIDATE_MEMORY_BUDGET`), FLAC streaming refactor,
bzip2 stream + bzip2z dep, HEIF parser thread-safety, concurrent stress harness,
racetrack allocator (codec-internal-only), cleanroom dep migrations
(bzip2z / zstdz / par2z / uchardetz), and the inbox note to validate_gui all
landed. Awaiting validate_gui's reply on UI shape.

Step-by-step queue (in order, easiest / highest-ROI first):

- [ ] **1. Library threading lockdown** in `cli/main.c` — `OMP_NUM_THREADS=1`,
  `OPJ_NUM_THREADS=1`, equivalent for libheif / libavif / libdav1d. ~5-line
  change at `main()` entry. Eliminates uncontrolled internal-threading spikes
  from C codecs that bypass our work queue. Smallest, lowest-risk.
- [ ] **2. Convert `*FromBuffer` shadow validators to take `*FileSource`** —
  audit (2026-05-01) found ~30 internal `*FromBuffer(data: []const u8)` entry
  points called by their `*FileSource` counterpart only after slurping.
  Examples: `validateWebpDeepFromBuffer`, `validateFlpFromBuffer`,
  `validateCubaseFromBuffer`, `validatePrprojFromBuffer`,
  `validateInddFromBuffer`, `validateFcpxmlFromBuffer`, `validateDrpFromBuffer`,
  `validateSketchFromBuffer`, `validateAiFromBuffer`, `validateEpsFromBuffer`,
  `validateAepFromBuffer`, `validatePdfFromBuffer`, `validatePdfDeepFromBuffer`,
  `validateMdbFromBuffer`, `validateAccdbFromBuffer`, `validateDbfFromBuffer`,
  `validateJavaClassFromBuffer`, `validateSevenZFromBuffer`. Each independent
  and small. Eliminates the last set of internal "load whole file into RAM" hot
  paths in the validation core.
- [ ] **3. Per-task arena allocator** — wrap each task in
  `std.heap.ArenaAllocator(parent)` so all per-validator allocations get
  reclaimed wholesale on `arena.deinit()`. Eliminates cross-task fragmentation;
  contains C-library leaks (libavif/libheif). Foundation for tighter budget
  accounting (per-task peak = arena size). ~50 lines in
  `ffi/c_api.zig`'s `executeBatchTask`.
- [ ] **4. Streaming refactor of remaining codecs** — JPEG (libjpeg-turbo
  `jpeg_stdio_src`), PNG (libpng `set_progressive_read_fn`), zlib (loop-pump),
  Vorbis (`ov_read_callbacks`), Opus. Libraries already support streaming;
  validate just needs to plumb it. Goal: O(input_window + decoder_state)
  regardless of file size.
- [ ] **5. Big-allocation diversion** — any single allocation past ~budget/4
  goes to `mmap` instead of the managed allocator. Removes "giants" from the
  budget pool so they don't crowd small tasks. Lowest priority since the
  budget queue already handles this via the starvation rule (oversized tasks
  admitted alone), but cleaner per-byte accounting.
- [ ] **6. validate_gui memory-budget UI integration** — wait for their reply
  on `../validate_gui/inbox/memory-budget-setting-2026-04-29.md`, then any
  follow-up they request from us (real-time RSS meter via FFI?).

### Deferred detection upgrades

- [ ] **NRW/NEF/CR2/ARW preview-JPEG decode (IFD-based).** Two prior approaches
  insufficient: `libraw_unpack_thumb` only extracts JPEG bytes without decoding
  them; DNG-style SOI-scan-and-libjpeg-turbo-decode false-positives on Nikon
  NRW sensor noise (16 KB threshold insufficient). Third attempt needs to parse
  the TIFF IFD for the canonical `PreviewImageStart`/`PreviewImageLength` tag
  (or equivalent MakerNote) and decode only at that offset. Helper
  `scanAndValidatePreviewJpegs` in `image_validators.zig` is retained for the
  IFD-based implementation. Expected lift: 0% → ~15-30% shotgun on
  NEF/NRW/CR2/ARW.
- [ ] **CR2 0%/0% investigation.** Format-detection fix landed (4db099de) and
  IFD preview decode landed (a2542f5), but `canon_eos_40d_sraw2.cr2` still has
  no detection — the sample's 3 FFD8FFXX SOI sequences are all marker `c4`
  (DHT). Either `validateJpegBufferForDng`'s marker whitelist (DB + E0..EF) is
  rejecting them or the JPEGs are Huffman-resilient at the bit-flip level.
  Needs targeted instrumentation.
- [ ] **CLI ValidationDepth third tier.** Add `.bounds_verified` between
  `.structural` and `.full`; audit every validator's return. Affects BMP, most
  RAW, video containers with weak codecs. Architectural — deferred post-launch.
- [ ] **RAF preview-coverage diagnostic.** Add a smaller Fuji RAF to the sweep
  alongside the 208 MB one so preview-decode coverage shows up distinctly in
  the table.
- [ ] **PDF perf re-measure.** Re-measure 14 MB JPX-dominated PDF after
  thread-budget fix. May still be slow due to repeated full xref+stream
  resolution per round — caching the structural parse and only re-decoding
  images would cut cost.
- [ ] **Sparkline heatmap mode.** `--heatmap-style {grid|sparkline|none}` —
  one row of unicode block-elements per file, more compact than the grid for
  terminals with limited vertical space.

### Sample-sourcing gaps

- [ ] **Pages** — needs Peter to author locally; no permissive public corpus.
- [ ] **Larger ground-truth samples** for APE, WavPack, 7z, ZIP, Gzip, Bzip2,
  XZ, Zstd, RAR, CAB so shotgun mode can run (current samples all < 4 KB).
- [ ] **Directory-format sweep harness** for bagit, git_repository,
  macos_app/bundle/framework, spotlight, band, logicx (single-file
  `corruption-experiment` can't probe these).
- [ ] **18 missing-sample enums** with neither ground truth nor sweep: ivf,
  ogv, song, sevenz, sitx, qbb, msi, ppt, dbf, pcap, pcapng, gcode, esd,
  llvm_diag, llvm_pch, msgpack, br, rpm.

### Statistical WARN tier (deferred follow-up, raised 2026-04-27)

- [ ] **Image-pixel statistical WARN tier** for codecs without integrity
  guarantees. Pattern proven for raw audio in `src/core/statistical_corruption.zig`
  (synth-flat pre-classifier + AR(2) residual + bit-flip rescue +
  sector-alignment bonus) for WAV s16 PCM. Extend the same shape to **decoded
  image pixels** so JPEG2000/JBIG2/JPEG-tolerated corruption surfaces as a
  heuristic WARN rather than silently passing. Inputs: post-decode pixel
  statistics (adjacent-pixel-difference distribution outliers, sub-band
  coefficient magnitude spikes, color-channel cross-correlation breaks),
  block-boundary discontinuities (DCT 8x8 vs JPEG2000 codeblock), and
  physical-media error signatures (sector-aligned ~512B / 2KB / 4KB anomaly
  clusters). WARN not FAIL — heuristic. Opt-out behind `VALIDATE_NO_HEURISTIC=1`
  for zero-false-positive runs.

### Open question

- [ ] **Upstream Zig stdlib zstd bug** (raised 2026-05-01 during cleanroom-deps
  perf audit). Reproducer is fully deterministic and minimal:

  ```bash
  # Build a ~135 MB base64 stream and zstd-compress it (~102 MB output)
  head -c $((100 * 1024 * 1024)) /dev/urandom | base64 > /tmp/medium.txt
  zstd /tmp/medium.txt -o /tmp/medium.txt.zst
  # Reference decoder (Facebook zstd C library) decompresses cleanly:
  zstd -t /tmp/medium.txt.zst        # exit 0
  # std.compress.zstd in Zig 0.15.2 fails:
  #   error.ReadFailed → "Decompression failed - corrupt data"
  ```

  Switching validate to zstdz (Peter's Zig-enabled fork of Facebook's reference
  C library) both fixed correctness AND went **6.86× faster** on a 500 MB →
  47 KB decompressed-large input (787 ms → 115 ms).

  **Filing constraint:** the Zig BDFL has stated publicly that LLM-generated
  bug reports / PRs are unwelcome. Options: (a) file under Peter's name as a
  hand-written report (the *bug* is real regardless of how the reproducer was
  found); (b) reduce the reproducer to a single Zig test-mode unit-test and
  submit that as a failing-test PR (cleaner shape than prose); (c) leave it
  alone — already routed around it via zstdz; downstream Zig users will hit it
  themselves eventually. Open question — Peter to decide.

  Workaround already in place: `archive_validators.validateZstdDeep` uses
  zstdz's C library binding via `@import("zstd")`. No regression risk to
  validate from leaving the upstream bug unfiled.

---

## Recent completions (continuity)

### 2026-05-03

- [x] **PDF font validator: per-stream empty-password decryption.** Restored
  deep font validation on encrypted PDFs by mirroring `pdf_image_validator`'s
  decrypt-then-validate pattern. Replaces the wholesale skip from afeea3d8
  with `pdf_decryptor.parseEncryptionParams` + `tryEmptyPassword` + per-stream
  `decryptStream`. Fonts in Ghostscript-style "trivial protection" PDFs run
  full CFF / Type1 / sfnt validation again. Non-empty passwords or unsupported
  variants (V5+ / AES-256) fall back to silent skip — DRM-locked PDFs are not
  validation failures. Added `src/core/fixtures/encrypted_v1r2_with_font.pdf`
  (5.7 KB) plus regression tests for both the deep-validation success path
  and the unparseable-/Encrypt skip path.

### 2026-05-02

- [x] **Windows Thumbs.db detection.** Added `thumbs_db` FileFormat variant.
  Detection driven by `Catalog` UTF-16LE stream in CFBF root, checked first
  in `detectOle2InBuffer` so Thumbs.db stops misclassifying as Word Document
  with the spurious "OLE2 container has no WordDocument stream" warning.
  Fixture: `src/core/fixtures/thumbs_db_sample.db` (13312 bytes).
- [x] **FLAC false-positive fix (lalalai-split).** `BitReader.readUnary`
  artificial cap of 32 lifted — FLAC spec imposes no upper bound on Rice unary
  coding length; real-world 16-bit FLACs from lalalai's stem-splitter
  legitimately need counts > 32. Cap raised to 2^24 as a sanity-only guard;
  reader returns Truncated when bits exhaust naturally. Added unit tests for
  unary counts 33 and 64 plus a real-frame regression fixture
  (`src/core/fixtures/lalalai_frame_175.flac`, 7 KB).

### 2026-04-28 → 2026-05-01 — Memory subsystem groundwork

Profiling harness `scripts/profile-memory`; `heap.validateAllocator()` managed
surface (b7cce2df); `page_allocator` sweep ~110 sites across 26 files
(b7cce2df + 8c7fd1f2); `FileSource.getMappedOrSlurp` collapsed 9 sites in
`image_validators` (37e7414f) with non-mmap fallback capped at 64 MB heap
slurp; budget-gated work queue + `VALIDATE_MEMORY_BUDGET` env (b65b5d5d);
FLAC streaming refactor (406c3919); bzip2 discard-writer + bzip2z dep
(1dd4dace + 6dd2573b); HEIF parser thread-safety (`threadlocal var` on
StaticBufs, d4a7e8f2); concurrent stress harness `src/core/concurrent_smoke.zig`
(b40d079d); racetrack allocator `src/core/racetrack.zig` (ac6003a6) — fixed-
buffer bump allocator with sliding-window invariant, deployed inside codec
internals only; cleanroom dep migrations (bzip2z 6dd2573b, zstdz e6802691
6.86× perf + correctness, par2z 739bb7ce, uchardetz 26f89ef3); inbox note to
validate_gui (`../validate_gui/inbox/memory-budget-setting-2026-04-29.md`).

### 2026-04-23 → 2026-04-27 — Pre-launch corruption-detection audit

Detailed work captured in `docs/corruption-detection-report.md` and individual
commits. Highlights:

- **P0** — PDF tolerant-image-failure mode made opt-in (c304f36); BMP
  reclassified docs-only (no checksums to verify); CR2 detection branch added
  (4db099de).
- **P1 sample replacements** — H.264 MOV (jellyfish_h264.mov, 6%→75%),
  VP9+Opus WebM (jellyfish_vp9_opus.webm, 2%→55%), MJPEG AVI (4%→93%), RLE PSD
  (7%→50%), ZIP-compressed EXR. Apache Tika sourcing for DOCX, XLSX, PPTX,
  ODT, ODS, ODP, RTF, EML, MBOX. Local generation for QOI, ICO, SVG.
- **P2 deeper validation** — libvpx 1.14.1 integrated for VP8/VP9 full-decode
  (f8c38ec8), VP8 needed `VP8D_GET_FRAME_CORRUPTED` query because error
  concealment silently patches bit flips. libtheora 1.2.0 integrated
  (8614b97e). WOFF/WOFF2 origChecksum verification confirmed already wired.
- **P2 launch-prep follow-ups** — `--test-coverage` CLI defaults switched to
  sniper+shotgun / 1000 rounds (b4388f1e); README VP8 callout (5b131e27);
  adaptive Wilson CI early-stop with `--early-stop-radius` flag; per-file
  progress indicator (807e0528); 4-tier env-detected heatmap palette
  (67354680); thread-budget propagation `--coverage-jobs N` setting
  `VALIDATE_INNER_JOBS = cpus/N` (13bdc474); JPEG2000 / JBIG2 / JPEG warning
  escalation in PDFs (a3960722) lifted JPEG-mixed PDF sniper ~20% → ~46%.
- **P2 regen tooling** — `docs/corruption-detection-report.md` is now GENERATED
  by `scripts/generate-corruption-report` (TSV numbers + `…/generated/` sidecar
  prose; 8-col incl. Bolter; `n/a` never blank; report path/corpus env-overridable).
  `tests/cli/master_report_drift` is now a regeneration-idempotence guard
  (committed report must equal a fresh regen). The old hand-audit
  `scripts/audit-corruption-report` was retired 2026-06-22 (superseded).

### 2026-04-25 — Format Coverage Chew-Through

Measured corruption detection for the 125 formats validate claimed to support
but had no sweep data. Mapped 227 ground-truth dirs vs 104 swept formats →
125-format gap. Categorized samples by size: 7 ≥ 4 KB (full sweep), 19 in
1-4 KB range (sniper-only), 98 < 1 KB (sniper-only). Built parallel harness;
ran 117 sniper sweeps + 6 shotgun sweeps → 123 new TSVs in
`docs/corruption-sweep-results/`. Generated 117 new master-report rows. APE
deep decode validation (luckynight.ape full-decoder-driven CRC32; vendored
Monkey's Audio SDK 12.73 BSD-3 as `deps/libape/`). KMZ + VP8 sample mis-pick
fixes.

---

## Statistical Corruption Detection — long-range design notes

For formats without checksums (AU, AMR, CAF, DPX, etc.), heuristic analysis
of raw data sections:

- **Temporal discontinuity detection**: sliding-window variance to flag sudden
  uncorrelated jumps in sample values (real audio has temporal correlation;
  corruption doesn't).
- **Single-sample outlier with bit-flip diagnosis**: compute statistical
  unlikelihood of `sample[n]` given a window of preceding samples. If it
  exceeds tolerance AND flipping any single bit in that sample's bytes
  produces a value that IS statistically probable (fits the local trend),
  report it as a diagnosed single-bit error with the exact bit identified.
  Forensic-grade — not just "something's wrong" but "bit 15 at offset 0x4A02
  is flipped".
- **Zero-run analysis**: extended silence in the middle of non-silent audio
  is suspicious; context-aware detection distinguishing track gaps from
  corruption.
- **Stuck-value detection**: runs of identical non-zero samples (register
  latch / bus error patterns).
- **Spectral anomaly**: FFT windows to detect unnaturally flat spectra (white
  noise from bit errors) or DC offsets.
- **Sector-aligned weighting**: at known sample rate + bit depth + channels,
  calculate `corrupted_samples = sector_size / (channels * bytes_per_sample)`
  for common physical media sector sizes (512B HDD, 2048B DVD, 2352B CD,
  4KB/16KB SSD). Statistical anomalies that are approximately sector-width or
  a multiple (±16 bytes tolerance for header offsets and controller
  scatter/gather) are weighted as extra-suspect — physical media failure
  signature, not encoding artifact.
- **Synthesized audio caveat**: square waves, FM synthesis, and other digital
  sources CAN have extreme single-sample transitions intentionally. Outlier
  detection should be weighted by surrounding context (±10 samples smooth =
  suspicious spike; surrounding samples also extreme = intentional waveform).
  Sensitivity should be configurable.
- Report as WARN (heuristic, not certain) rather than FAIL.
- Applicable to: AU, AMR, CAF, WAV (raw PCM), AIFF, DSD, DPX (raw pixel data),
  PAM/PBM/PGM/PPM (raw pixel data).
- A genuinely novel validation tier between structural and full.
- Module: `src/core/statistical_corruption.zig` with configurable sensitivity.
