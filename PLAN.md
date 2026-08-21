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

- [ ] **SEPT 1 FOUNDING BETA — validate owns engine/integration (Code
      decision note, 2026-08-21, URGENT):** free 15-participant Mecha
      Validate Founding Beta launches 2026-09-01; a named freeze commit +
      its versioned capability matrix define every honest v1 claim. Freeze
      recommendation **2026-08-27 17:00 EDT — awaiting Peter approval**
      (the one Peter-only decision). "As much as technically possible" =
      broadest set passing release controls at freeze; every gap ships
      marked partial/structural-only/unsupported, never a slipped date
      (candor ruling 2026-08-19). Paddle/payment out of scope (beta free;
      $49.99 applies to later paid release). Launch-critical order:
      1. A/V streaming conversions (ogg family, vp9_webm agents resumed
         2026-08-21 14:10 EDT; h265_mp4 LANDED bc065a5c8; mkv_cc owed after
         vp9) — resident rows ship honestly if not converted by freeze.
      2. Admission refuse-guard (batchscale agent resumed; OOM2 rule:
         single file estimate > total budget -> REFUSED indeterminate/
         resource_cap, never unbounded admission) + parallel enumeration.
      3. LERC link closure (blocked on tiffz lercz artifact export —
         dependency note sent 2026-08-21; then consumer regression +
         re-pin + all_c_deps).
      4. Freeze-week: regenerate capability matrix at freeze commit, full
         sweep evidence refresh, Peter wording review of the matrix (his
         ruling #6), validate_gui field acceptance re-run (98k-file
         Downloads scan), five-target CI green at the freeze SHA.
      Einstein replied-to with critical path + pins (see
      ~/Code/inbox/2026-08-21-from-validate-beta-critical-path...). NOT
      launch-critical, deferred: pdfz phase 2 (#33), --capabilities
      emitter, corrupt-mutant adjudication backlog.

- [x] **Spot-check six multi-gigabyte ZIP compressed-size mismatch INVALIDs
      (Peter, 2026-08-20):** inspect local headers, central-directory records,
      ZIP64 extras, and data descriptors for the three Rick and Morty archives,
      Venom, The Batman, and Assassin's Creed Syndicate; compare current
      Validate with independent archive readers. Diagnose only unless Peter
      asks for a fix. Result: all six are stale-backend false positives. Every
      archive uses legal ZIP64 central-directory `0xFFFFFFFF` sentinels whose
      `0x0001` extras carry the resolved 64-bit sizes; `zipdetails` found zero
      compressed-size mismatches after resolution. Current Validate
      `c104bc0b3` fully CRC-validated all six, and independent `unzip -tq`
      passed all six, including the 22 GB archive. Commit `1aaddf082` fixed
      this exact raw-sentinel comparison and is in the GUI's new pin.
      Completed 2026-08-20 15:20 EDT. Curiosity poke: streaming writers may
      place zero or sentinel sizes in local headers and put the authoritative
      sizes in data descriptors or ZIP64 records, so direct local/central
      equality is not a valid invariant in every general-purpose-bit-flag mode.

- [x] **Spot-check five GUI ZIP extra-field WARNs (Peter, 2026-08-20):**
      inspect local/central extra-field records for ColorOracleJar, Darktide Mod
      Loader, Easiest Piston Lock, and the two DOCX files; compare independent
      archive readers and current Validate; confirm the exact Validate revision
      loaded by validate_gui. Diagnose only unless Peter asks for a fix.
      Result: all five WARNs are false positives from the old backend. Raw
      header walks found zero malformed chains; the differences are standard
      Info-ZIP Unix metadata, central-only NTFS timestamps, and local-only OOXML
      growth hints. Current CLI `c104bc0b3` and three independent readers accept
      every file. validate_gui pinned `c104bc0b3`; its local `f0dee6c21` fix
      links lercz and produces a fresh backend that returns `valid=T` with an
      empty warning for all five files. The active Downloads scan remains on
      the old dev server until it finishes, after which the GUI can replace it.
      Completed 2026-08-20 12:03 EDT; fresh-backend confirmation received
      2026-08-20 12:50 EDT.
      Curiosity poke: aggregate local/central lengths may legally differ, while
      a malformed record or conflicting same-ID payload can still justify WARN.

- [x] **Give validate_gui a current validate commit to pin (Peter,
      2026-08-19):** after the active h265 conversion is green, landed, and
      pushed, send validate_gui the exact `yolo` commit via LLMsend and state
      that its ancestry includes the encrypted-PDF fix. Curiosity poke:
      sending an unpushed SHA would leave the consumer unable to fetch it, so
      verify remote reachability before the handoff. Result: GUI lockfile now
      pins pushed Validate `c104bc0b3`; its local `f0dee6c21` server build and
      integration tests are green. Live replacement waits for the running
      Downloads scan. Completed 2026-08-20 12:50 EDT.

- [ ] **Make Validate's installed core archive own its LERC link closure
      (Einstein handoff, 2026-08-20):** wait for tiffz to export its existing
      lercz artifact under a stable public name, then first add a consumer
      regression that reproduces the unresolved `lerc_getBlobInfo` /
      `lerc_decode` link. Re-pin tiffz, add the artifact to `all_c_deps`, and
      prove a valid LERC-in-TIFF FFI call links and runs using only the
      installed `libvalidate_core` consumer contract. Audit unresolved symbols
      and run the full test/build_all/Nix/CI gates before giving validate_gui
      the exact pushed SHA so it can remove its temporary direct lercz pin.
      Blocked on tiffz's pushed green export commit. Curiosity poke: an `nm`
      audit can look clean while the installed consumer contract still omits a
      transitive archive, so acceptance requires a real external link and call.

- [x] **Spot-check `ACES - Extra Slots-44902.zip` WARN validity (Peter,
      2026-08-19):** inspect the local and central ZIP headers plus an
      independent reader for the reported extra-field length mismatch;
      determine whether WARN is evidence-backed or a false positive. Diagnose
      only unless Peter asks for a fix. Result: stale false positive from a
      pre-`1aaddf082` binary/scan; LFHs legally carry no extras while CDs
      carry valid 36-byte NTFS timestamp extras. Current signed old/new review
      binaries return fully validated with no warning; unzip, 7-Zip, and
      bsdtar agree. Completed 2026-08-19 17:42 EDT. Curiosity poke: ZIP permits local and
      central extra fields to carry different field sets, so unequal aggregate
      lengths alone may be legal even when a same-ID payload mismatch is not.

- [x] **Audit and recoverably clean stale validate sibling directories (Peter,
      2026-08-19):** inspect `~/Code/validate-archive-streaming`,
      `validate-image-streaming`, `validate-mac-perf`, `validate-wip-snapshots`,
      and `validate_pics` for dirty/untracked files, commits unique from `yolo`,
      remotes, and live erected-agent references. Preserve any useful work;
      move only proven-redundant directories to system Trash, then prune stale
      worktree registrations without deleting unique branches. Result: the
      archive commit is patch-equivalent to `yolo`; image/mac are ancestors
      with symlink-only dirt; the WIP snapshot reconstructs exactly to commit
      `af3d2ebe`; every regular `validate_pics` file is already a reachable Git
      object. All five directories and the three linked-worktree admin records
      are preserved under
      `~/.Trash/validate-stale-20260819-1844EDT/`; all three branch refs remain.
      Completed 2026-08-19 18:44 EDT. Curiosity poke: a clean worktree can still
      be the sole reference to commits or artifacts absent from `yolo`, so
      directory cleanliness alone is insufficient evidence.

- [ ] **A/V streaming conversions (Peter ruling 2026-08-19: "relentlessly pursue",
      sniper/bolter/shotgun no-regression as the FP/FN acceptance bar):**
      h265_mp4 is complete: MP4 samples now decode through bounded 8MiB Annex-B
      windows, H.265 scratch uses reclaiming allocation, all 12 real-cgroup
      ceiling families passed, and 720 seeded old/new corruption trials matched
      exactly. Remaining worktrees cover the Ogg family and vp9_webm; mkv_cc is
      also owed after its first witness disproved the inferred `streams` row.
      Each conversion flips its manifest row in the conversion commit; ceiling
      gate plus family sweep before/after are acceptance. h265_mp4 completed
      2026-08-19 19:12 EDT. Curiosity poke: FFI task arenas make `free()` a
      no-op, so any new per-sample or growable scratch must use the reclaiming
      allocator or an equivalent bounded custody pattern.
- [ ] **Batch-scale (#28, agent in flight):** >=2x admission multiplier (first
      commit), decoded-size-aware admission + wedge-class isolation, parallel
      work-stealing directory enumeration. Inputs: validate_gui RSS probes in
      inbox/2026-08-15-attachments-rss-growth/.
- [ ] **pdfz extraction phase 1 (Peter 2026-08-19: NOW, PRIVATE repo):** agent
      scaffolding ~/Code/pdfz (local-only, no remote until coordinator review;
      GitHub repo created private afterwards). Phase 2 (validate re-pins pdfz,
      deletes in-tree PDF stack) comes after phase-1 review + private-dep
      fetch design.
- [x] **Capability matrix v1 (absorbs Image Parser 1.0 plan, task #6):**
      `docs/CAPABILITY_MATRIX.tsv` is now GENERATED evidence —
      `scripts/generate-capability-matrix` (LuaJIT) joins the FileFormat enum +
      maxAchievableDepth (parsed from source), witnessed per-format verdicts
      from running the binary over the 1157-file ground-truth corpus, opacity
      classes, and the streaming manifest; 247 formats, honest statuses
      (deep/partial/structural-ceiling/unwitnessed/detection-only).
      `tests/cli/capability_matrix` gates freshness (regen+diff), completeness
      (independent enum extraction), streaming agreement, and status
      vocabulary; tamper-tested (freshness check witnessed biting).
      IMAGE_PARSER_1_0_MASTER_PLAN.md banner-marked as historical. Follow-ups:
      `--capabilities` emitter in the binary for GUI/help (post-integration),
      sweep_evidence column join to docs/coverage-evidence/runs.tsv, matrix
      wording review by Peter before sales use. Backlog the matrix surfaced
      mechanically: ape 2/3 labeled-good (1 rejected — false positive?), avif
      corrupt 0/5 rejected, aiff/ar/accdb witnessed structural though deep
      achievable, several unwitnessed formats (alac dir detected as other
      tokens). Completed 2026-08-19 13:05 EDT.
- [x] **Watchmen featurette AAC verification (2026-08-19):** all 15 Ultimate
      Cut featurette MKVs now VALID with the #26 AAC fix — the "1 of 50 AAC
      access units" false-positive class confirmed dead on its last
      outstanding real-world cluster. Completed 2026-08-19 12:52 EDT.

- [x] **#31 vp9_webm streaming conversion (Peter, 2026-08-19):** VP8/VP9 in
      MKV/WebM on mapped sources now decodes from zero-copy frame refs into
      the mmap (`collectAllFrameRefs`; shared walk extracted as
      `walkTrackFrames`) instead of `collectAllFrames` copying every
      compressed frame into anonymous memory. libvpx instance count is capped
      by a 256MiB decoder-memory budget (`maxDecodersForDims`, from track
      dims); budget-capped instances get libvpx row-mt internal threads
      (cpu/instances, ≤4). Ceiling gate: 2GiB WebM at 512MiB cgroup went
      OOM rc=137 → rc=0 in 45s, peak RssAnon ~200MiB. Detection: 450/450
      per-trial verdicts byte-identical (sniper 108/150, bolter 100/150,
      shotgun 132/150 on jellyfish_vp9_opus.webm, seed 42); mkv slot still
      150/150 ×3 modes; 10/10 known-good webm+mkv clean. Root cause of the
      h265_mkv-vs-vp9_webm split: ffmpeg writes cluster CRC-32 for matroska
      (CRC fast path streams) but NOT for webm (decode fallback copied the
      file). SIDE FINDINGS: (a) mkv_cc first witnessed on Thelio — the
      inferred `streams` was WRONG (mkvmerge writes no cluster CRCs; h264
      decode path still copies frames); row corrected to `resident` per the
      manifest's own rule — flip back only WITH an h264-path conversion.
      (b) sweep slot `webm` was silently excluded since the identity
      self-check landed (no webm→mkv equivalence); table entry added.
      Non-mapped sources (Windows/mmap-fail/>8GB) still take the copying
      path — a future conversion. Completed 2026-08-19 EDT.

- [x] **Publish the Mecha Validate v1 integration contract:** define a
      machine-readable capability/result schema with the exact capability
      states `strict`, `partial`, `structural`, `unsupported`, and `blocked`,
      plus terminal `valid`, `corrupt`, and `indeterminate` semantics. Require
      stable nested source/finding/offset evidence and provide a mechanically
      validated matrix that GUI and sales consumers can ingest without
      turning pending format work into a launch claim. Curiosity poke: a
      schema can validate shape while still permitting an unsupported format
      to masquerade as strict, so semantic cross-field invariants must bite.
      Completed 2026-08-05 02:42 EDT.
  - [x] Consume rarz's exact promoted archive-summary API at
        `1ce99ef9da3d382efc2bfbb918408674082a311d`, preserve its accounting
        counts, and map incomplete evidence to `indeterminate`/WARN rather
        than OK or FAIL.
  - [x] Record jp2z's promoted pure-Zig strict leaf without bypassing the
        jpegz facade; promote it only when the exact consumer dependency path
        is closure-safe. Keep rawz blocked on tiffz's parser-only module and
        jpegz pending until exact promotion. Consume libjxlz's promoted exact
        strict API, but keep JPEG XL non-claimable until the existing valid
        `bicycles.jxl` fixture stops returning indeterminate.
  - [x] Add a first-party production-closure audit and aggregate public
        sniper/bolter/shotgun evidence with exact source commits and honest
        denominators. Curiosity poke: mutation survival can represent a valid
        alternate codestream, so sensitivity is not automatically a false
        negative count.

- [x] **RAW coverage + nomenclature doc (Peter, 2026-08-05):** authored
      `~/Code/rawz/docs/RAW_COVERAGE_AND_NOMENCLATURE.md` — container-vs-payload
      two-layer model (answers "is RAW a child of TIFF?": neither), shared
      `<container>/<payload>/<depth>@<source>` nomenclature with a 0-5 depth
      ladder, per-format gap matrix (hypothetical ceiling | first-party now |
      third-party delta), licensing analysis (libraw/rawspeed oracle-only; RE
      legal; Nikon WB-encryption + patent caveats), and a leverage-ordered
      roadmap. Notified rawz. Completed 2026-08-05 13:11 EDT. Open decisions for
      Peter recorded in §7 (launch RAW posture; libraw transition; CR3 priority).

- [x] **URGENT re-pin rarz `1ce99ef` → `bf6840c` (rarz, 2026-08-05):** fixes
      FOUR false-positive classes — x86 program archives, RAR4 >4MB, RAR4
      multi-volume, encrypted RAR4 store entries — that make validate condemn
      GOOD archives. Recompile-only: `rarz_verify_archive_summary` gained
      `uint32_t encrypted_entry_count` at END (do NOT add to accounting sum —
      it's a property, counted separately in one outcome bucket). Post-fix
      unrar agreement 21/21 (was 2/18). Ships correctness; prioritize over the
      codec cutover. Completed 2026-08-11 15:20 EDT: full `./test` green, no
      consumer code change needed (validate ignores the appended
      `encrypted_entry_count` tail; accounting invariant untouched). rarz has
      newer commits (`71ff42d` unpack20 fixes) with no verification note yet —
      candidate for the NEXT bump, not this one.

- [x] **2026-08-14 landing day — ALL PUSHED** (`e5b6b28ad` on origin/yolo;
      combined gate green 16:41). Two operational discoveries: harness-tracked
      background tasks were being reaped mid-run (detached-subshell + Monitor
      pattern survives — use it for long gates), and `corruption_sweep_ledger`
      flaked ONCE in-sequence under build-storm load (passes isolated + in
      dev-shell + in the gate4 rerun; joins the order/load-nondeterminism
      investigation with memory_budget/racetrack, task #21's session).
      Landed: `1cf47fb07` JP2 cutover via tiffz `388dee45`→jpegz `919571df`→
      jp2z `1b29e0c` + lzwz 0.3.0, openjpeg 100% removed (-Dwith-jp2-decode=
      false; balloon fixture valid/fully-validated matching oracle);
      `ec14e2003` TrueHD/MLP validator (agent-built, witnessed red, 1909/0,
      caught a cmp-proven bit-flip ffmpeg misses; Iron Man WARN closed);
      `e5b6b28ad` merge of mutation-hardening (28 dd sites → self-verifying
      mutate_bytes; rm_safe shadows truncate too — witnessed red). Earlier,
      pushed: `816037f8f` rarz bf6840c (ACK to rarz sent 08-14 — was pinned
      all along), `240228dcf` DTS-HD EXSS fix, `ade1e0c46` lockfile+PE.
      rarz `71ff42d`+ unpack20 fixes = next-bump candidate awaiting their
      verification note. libjpeg-turbo removal (old task D) + closure proof
      (E) + hard-gate (F) fold into #15's hard-gate work.

- [x] **2026-08-15 scan-triage + fanout day — SIX landings pushed through
      `3b3ea4137`:** Peter's full-scan triage convicted ~125 of ~150 "invalid"
      rows as false positives via oracles (exiftool/unzip/gs/ffmpeg/file).
      Landed: `36781c00d` dangling-symlink WARN (~60 rows); `1aaddf082`
      ZIP64 sentinel resolution — CD sentinels vs real LFH sizes, offsets
      >2GiB sentinel everything (~35 movie zips un-condemned; extra-field
      WARN re-grounded in APPNOTE 4.5.1); `516ec190d` hermetic ledger
      provenance controls (the flake needed a DIRTY tree — died the moment
      the tree went clean; closes flake 3/3); `aa7086484`+`24c656079`
      batch-scale (bounded submission O(N)→5.4KB with mutation-controlled
      test; "55KB/file leak" root-caused as NO-leak — concurrent residency +
      stat.size under-reservation, starring a 64MB JXL at 2.07GB/12min;
      event-driven sync tests); `3b3ea4137` A/V streaming proof harness
      (SPLIT reality: h264/mp4+h265/mkv+most audio stream via evictable
      pages; h265/mp4, vp9, theora, opus/vorbis-ogg resident; expectations
      manifest = claim-implies-proof; growing ladder documented).
      In flight: #26 (PDF flate + AAC 1-of-N, both oracle-convicted),
      #27 (verdict-tier honesty + detection identity + GIF-trailer WARN
      under the tolerance doctrine).
      OPERATIONAL LESSON: long detached gates must run under `setsid`
      (tty SIGINT reached ordinary detached subshells — the entire
      kill-mystery lineage was signal propagation; two gate runs died
      "interrupted by the user" before the fix, third passed clean).
      Open ship-posture question for Peter: v1 with honest resident-family
      manifest + ≥2x admission multiplier vs converting codec families
      pre-ship (#23 conversions).

- [x] **#15 RAW cutover + hard-gate COMPLETE (2026-08-15, pushed through
      `94f630e9d`):** rawz `2d030cf7` integrated (one-instance tiffz-parser
      injection); PEF cut over TDD (PackBits-decode-before-extent-check fixed
      a real false-positive class, witnessed red `b31d2bbf4`); LibRaw removed
      from every build with measured per-family delta — zero false rejects,
      one honest CR2 full→structural interim (tiffz false-Malformed escalated
      with exiftool oracle evidence, regression-pinned) — `90a4dd7f7`; comptime
      manifest hard-gate + blessed-hash control file + closure audit
      (`94f630e9d`, witnessed red via present-pattern probe; two bring-up
      lessons recorded: eval-branch quota, flake untracked-file invisibility).
      Task #10 (RAW analysis) closed as absorbed by rawz ownership + the
      RAW_COVERAGE_AND_NOMENCLATURE doc. Remaining RAW work lives with rawz
      (per-family milestones) and the capability matrix.
      NOTE: local bare `zig build` (Debug, devcache incremental) SEGVs on this
      tree while all nix builds pass — separate investigation, likely stale
      incremental cache or Debug-mode compiler bug; nix is the gate authority.

- [ ] (superseded — completed above as #15) **v1 codec production-closure cutover (Peter, 2026-08-05):** repin
      jpegz/tiffz/rawz and remove the non-Peter-owned `openjpeg`,
      `libjpeg-turbo`, and `libraw` runtime/build paths so the shipped closure
      is first-party only (Einstein item 6). Ordered, green-gated increments —
      dep removal cannot precede the code that uses those libs, so the code
      reroute leads each removal:
  - [x] **A. Bump tiffz `bcbe83b4` → `99deeb89`** (completed 2026-08-11 ~15:50
        EDT, full suite green; witnessed-red: the pin flipped the missing-EOD
        TIFF case from FAIL to accept+WARN exactly per Peter's 2026-08-01
        libtiff-tolerance ruling, and the old strict test caught it before the
        contract update). (Supersedes the
        abandoned 8fe6524 WIP; tiffz-requested 2026-08-11). Brings code-13 u32
        excess-byte payload AND jpegz `98824e7b` with `validateAny` whole-family
        facade. NOT additive: jpegz's internal libjxlz pin (same commit
        `5e8f9d6` we pinned directly) collides as a duplicate module instance,
        so this increment atomically: bumps tiffz, reroutes
        `jxl_validator.zig` through `tiffz.jpegz.jpegxl` (Options passes
        through 1:1; @hasField guards cover the Windows no-Brotli stub;
        `jxl_validator_unavailable`→indeterminate), and deletes the direct
        `.libjxlz` zon dep + build.zig module. Package hash
        `tiffz-0.1.0-qutJAfiZdgGjBg5qJBm_FPybjwLmhpSc6g-lFxSyvpPk`.
  - [ ] **B. (STAGED, BLOCKED on jpegz) JP2 openjpeg → jpegz strict.** All
        three call sites rerouted (image deep, PDF JPX, DICOM fragments);
        jpeg2000_validator.zig + deps/openjpeg Trashed; ported fixture tests
        pass; Zig units fully green (1892/0 on the quiet run). BLOCKED
        uncommitted: format_roundtrip caught jpegz mapping
        `jp2_uses_9x7_wavelet` (standard lossy CDF 9/7) to CORRUPT — a clean
        labeled-good JP2 false-rejected (`balloon_eciRGB_icc.jp2`). Escalated
        to jpegz 2026-08-11 with reproducer + ask (map capability-gap leaves
        to `unsupported`); ALSO asked jpegz for a `-Dwith-jp2-decode=false`
        gate on their unconditional openjp2 module linkage (needed for
        closure task E/F). Lands on the fixed jpegz→tiffz→validate pin chain.
        THE ONE RE-PIN NOW BUNDLES (2026-08-14): jp2z `1b29e0c`
        (entropy_under_read fix; our balloon fixture is now a must-accept
        control in their gate) + jpegz ≥`a8b79dab` (-Dwith-jp2-decode=false,
        18→0 opj_ symbols) + lzwz `0.3.0`/`c8f1c9a4` (consume ONLY through
        tiffz — no second direct dep; retain strict PDF/GIF IncompleteSource
        coverage, allocation-free GIF exact extent, TIFF warning 14, single
        shared decoder identity). Wait for tiffz's new SHA, pin once, full
        suite, land #14 same day.
        Original plan follows:
  - [ ] **B-orig. JP2 openjpeg → jpegz strict.** Reroute
        `image_validators.validateJpeg2000Deep` (currently calls the
        openjpeg-`@cImport` `jpeg2000_validator.zig`) and the PDF JPX path to
        `tiffz.jpegz.jpeg2000.strictValidate` (pure-Zig via jp2z; jpegz's
        `jpeg2000.decode` still routes to openjpeg but lazy analysis keeps it
        unlinked once nothing calls it). TDD: JP2 known-good/known-bad through
        the public API. Then delete the `openjpeg` zon dep, all build.zig
        openjpeg wiring, `deps/openjpeg`, and the flake openjpeg inputs.
        jpegz also offered a caller-supplied format hint for
        destroyed-signature JP2s (sniff can't route them) — request it when
        wiring this.
  - [ ] **C. RAW libraw → rawz + tiffz-structural.** Add rawz `2d030cf7`
        (hash `rawz-0.1.0-sAg3Opc2AQByM2uPDUcILtbUC0hqym4oFQnXet4xu8CJ`),
        inject `tiffz_dep.module("tiffz-parser")` from the SAME tiffz instance
        (one-instance rule). Cut PEF per Einstein M3 (Compression 32773 →
        tiffz; 65535 → rawz Huffman). Then delete `libraw` zon dep,
        `libraw_validator.zig`, build.zig libraw wiring, flake libraw. MEASURE
        the RAW verdict delta (which families drop libraw-structural →
        tiffz-structural or unsupported) and record it honestly; STOP+report if
        a family loses all validation unexpectedly.
  - [ ] **D. Drop libjpeg-turbo forwarding** once nothing needs the libjpeg
        oracle (jpegz `-Dwith-libjpeg-oracle=false`); remove flake
        libjpeg_turbo inputs across the 4 dev-shells.
  - [ ] **E. Prove the Nix production closure** excludes openjpeg/libraw/
        libjpeg artifacts (matches rawz/jpegz closure gates).
  - [ ] **F. v1.0 hard-gate (Peter, 2026-08-06, "physics over policy"):**
        `src/core/v1_closure.zig` comptime `@compileError` on any oracle-only
        decoder in the production module graph (libraw, openjpeg, libjpeg-turbo,
        rawspeed, …), flags set by build.zig from the real graph; `-Doracle=true`
        is the only (non-shippable) way to pull them in. Layer 2 = Nix
        runtime-closure grep. Forbidden set is a blessed-hash CONTROL FILE (MFIC);
        it GROWS as first-party replacements land. Design in rawz doc §8.
  - Note: tiffz code 13 (`final_strip_padding_tolerated`) ships PRESENCE-ONLY in
    `8fe6524`; render "excess unknown" until tiffz's u32-payload follow-up pin.

- [ ] **Tier-0 RAW deep via jpegz (Peter-approved 2026-08-06):** wire DNG + CR2
      lossless-JPEG sensor payloads through jpegz (DNG `partial`→`deep`, CR2
      `unsupported`→`deep`), zero RE, zero licensing risk. Cross-project
      (tiffz owns DNG container; CR2 = tiffz container + Canon lossless JPEG →
      jpegz). Coordinate seam with tiffz/jpegz. See rawz doc §6 Tier 0.

- [x] **DTS-HD EXSS false positive FIXED (`240228dcf`, 2026-08-14 ~10:55 EDT):**
      the walker knew only core sync 0x7FFE8001; every DTS-HD MA stream's EXSS
      substreams (0x64582025) read as "frame boundary mismatch" — 4/4 of
      Peter's DTS-HD MA movies condemned, all healthy (ffmpeg oracle clean on
      a 10MB carve). Fixed via EXSS header walk (ETSI TS 102 114 E.4 size
      fields); witnessed red + corrupted-size must-reject + roundtrip 236/236.
      Follow-ups: TrueHD/MLP validation (task #20), scan-parallelism
      starvation (task #21).

- [x] **Cargo.lock + PE subtype LANDED (`ade1e0c46`, 2026-08-14 ~14:40 EDT,
      pushed):** lockfile basename dispatch (Cargo.lock→toml etc., rebar.lock
      keeps erlang_term, unclaimed .lock→content detection) + PE
      `format_variant` token rendering "Windows PE Executable (dll|exe|drv)"
      (Peter: keep long i18n base). Witnessed reds + 236/236 roundtrip +
      real-world spot checks in the commit message. Original diagnosis:

- [ ] (superseded) **Cargo.lock misdetected as erlang_term (Peter, 2026-08-13):** the bare
      extension tables at `format_validation.zig:3196`/`:3484` map `lock` →
      erlang_term — right for rebar.lock only; Cargo.lock (TOML), flake.lock
      (JSON), yarn.lock, Gemfile.lock all mis-classify. Reproduced:
      `--json` gives `format:"erlang_term", valid:true` on Peter's
      futures-channel Cargo.lock. Fix with basename-aware/content-first .lock
      dispatch; TDD as classifier over a lockfile SET (must-match AND
      must-not-match sides), witnessed red. Standalone commit once the tree
      unblocks (same file as the held JP2 cutover).

- [ ] **Concurrency-test nondeterminism under load (observed 2026-08-11):**
      two DIFFERENT timing-flavored tests failed on consecutive full-suite
      runs — `memory_budget.test "observed acquire reports one real admission
      wait"` (TestExpectedEqual), then `racetrack.test "acquire blocks then
      unblocks on head advance"` (TestUnexpectedResult) — each passing in the
      other run; both runs shared the box with parallel nix builds. Our own
      testing principles forbid timing-dependent tests (inject clocks, use
      callbacks). Root-cause both: either the tests encode a real race (smash
      it per debugging philosophy) or they depend on wall-clock scheduling and
      need deterministic synchronization. Not caused by the codec cutover
      (neither module touched).

- [ ] **Drive the four image-parser dependencies to 1.0:** execute
      [`docs/IMAGE_PARSER_1_0_MASTER_PLAN.md`](docs/IMAGE_PARSER_1_0_MASTER_PLAN.md)
      for `tiffz`, `libjxlz`, `jp2z`, and `jpegz`. Library correctness,
      strict findings, bounded embedded inputs, and honest corpus matrices are
      mandatory; parser CLIs may be deferred. Current red flags include TIFF
      rejecting 5/15 labeled-good files, jp2z only 22/57 byte-exact
      conformance fixtures, and libjxlz lacking a strict validation API.
      Curiosity poke: never improve “corrupt detection” by rejecting valid or
      unsupported-valid files, and never call valid-but-different entropy
      mutations detectable without an external integrity primitive.

- [ ] **TDD archive and codec strictness audit:** inventory every archive and
      embedded compression decoder, document its terminal-marker, decoded-size,
      checksum, and trailing-byte invariants, then tighten any path that accepts
      a malformed stream as successful. The first remediation is the bold
      `lzwz` extraction: one strict, profile-configured decoder shared by PDF,
      GIF, and `tiffz`; delete Validate's TIFF fallback and every private LZW
      dictionary implementation after consumer tests are green. The oracle
      records the discovered contradiction: PDF, TIFF fallback, and `tiffz`
      all advertise an incomplete-stream error but treat physical EOF before
      EOD/EOI as success. Require terminator proof and require every TIFF
      strip/tile to produce its exact declared pixel-byte extent before
      remeasuring sniper/bolter/shotgun coverage. Curiosity poke: a byte
      mutation can legitimately form a different valid stream, but a decoder
      must never turn a missing required invariant into a PASS merely because
      it reached physical EOF. Record each accepted compatibility exception
      separately as WARN rather than silently weakening FAIL logic.
  - [x] Pin the strict `tiffz` terminator fix and add the downstream 1-bit
        TIFF missing-EOD regression, so the Validate-to-`tiffz` deep path
        proves incomplete LZW strips are invalid. Full suite green 2026-07-17
        18:20 EDT.
  - [x] Move TIFF, PDF, and GIF onto the one profile-configured `lzwz` core;
        delete Validate's private LZW decoders; require EOD/EOI and exact
        declared extent where available. Curiosity poke answered: physical EOF
        cannot substitute for a required terminator, while a different
        structurally valid stream remains an honest limit without a checksum.
        Signed `bali.tif` 100-trial seed-42 evidence improved 7% → 63%
        sniper and 45% → 93% bolter, retaining 100% shotgun; clean
        one-worker ReleaseFast mean was statistically neutral (804.8 ms →
        808.7 ms, 20 runs). Full `./test` and `./build` green.
        Completed 2026-07-17 19:35 EDT.
  - [x] Pin `tiffz` M12 LERC support and exercise an independent LERC2 TIFF
        through the existing full strip/tile decode path. Route its per-IFD
        `Compression=34887` finding as the approved INFO observation, never a
        WARN/FAIL; bundle lercz's Apache-2.0 text and Esri patent NOTICE.
        Fresh signed one-worker ReleaseFast `bali.tif` timing: 790.6 ms ± 2.2
        ms (20 runs), versus the prior comparable 808.7 ms sample; this is a
        regression check, not a causal LERC speed claim.
        Completed 2026-07-19 11:54 EDT.
  - [x] Explain in the README why corruption validation sometimes needs strict
        decoder rewrites/wrappers rather than reader-tolerant libraries, using
        the shared LZW repair and measured sensitivity change as evidence.
        Completed 2026-07-18 01:27 EDT.
  - [ ] Define a machine-readable composite-format coverage matrix and render
        it as separate public coverage sections: TIFF, PDF, ISO BMFF,
        Matroska/WebM, ZIP-derived documents, and DICOM. Keep email/web
        containers out of scope. ZIP-derived document rows must show inherited
        ZIP container evidence separately from any future recursive document
        semantics; candidate cells may never masquerade as measured coverage.
        Curiosity poke: a kitchen-sink fixture finds composition faults but
        cannot replace per-path fixtures or stratified mutation evidence.
  - [ ] Restore deep-validation parity across all five release targets, or
        reduce the product claim before a differing target ships. The public
        coverage table now reports mutation mode and date, not a misleading
        generic platform column. Curiosity poke: a platform-specific library
        omission is a product defect, not a footnote to a supposedly portable
        integrity verdict.
  - [ ] Replace the coverage report's latest-TSV/frozen-fallback model with
        immutable, section-owned evidence manifests and append-only run history.
        Each published rate must name its fixture identity/hash, raw trial TSV,
        seed/count/mode, signed binary hash, source commit, host/target, and
        date; a candidate, inherited-container result, structural-only path,
        or missing measurement must render as such rather than as a percentage.
        Re-sweep the full corpus after the three-month implementation interval,
        retain prior comparable runs, and display only evidence-backed deltas.
        Curiosity poke: a changed fixture or mutation policy creates a new
        series, never an apparent improvement over an incomparable baseline.
    - [x] Lock the append-only run-ledger schema before writing a new sweep:
          require exact raw-TSV location/hash, fixture identity/hash, mutation
          policy, signed-binary identity/hash, source commit, target, host,
          and UTC timestamp; reject duplicate run/series/mode rows. Completed
          2026-07-18 19:54 EDT.
    - [x] Bind each corruption trial to an explicit `VALIDATE_BIN`, so a
          signed artifact can be both executed and recorded rather than a
          PATH/default binary being measured by accident. Completed 2026-07-18
          20:00 EDT.
    - [x] Replace flat, overwrite-prone sweep outputs with signed-binary
          verified `runs/<run-id>/` raw TSVs and an append-only provenance
          ledger. An interrupted run may only be resumed without replacing a
          raw TSV; duplicate run IDs otherwise fail. Completed 2026-07-18
          20:15 EDT.
    - [x] Make the sweep writer create an immutable per-run raw-evidence
          directory and append only complete, hash-bound provenance rows;
          reject accidental run-ID reuse while allowing an interrupted run to
          resume without replacing trials. Completed 2026-07-19 10:59 EDT.
    - [x] **TDD remove byte-at-a-time signed-binary verification:** the
          96.9 MB integrity preflight must stream the body excluding its
          50-byte trailer, not issue one `dd bs=1` read per byte. Curiosity
          poke: preserve exact trailer verification while using a
          deterministic operation-level regression rather than a flaky timing
          threshold. Discovered 2026-07-22 14:02 EDT; focused regression
          and full `./test` green 2026-07-22 14:33 EDT. Measured clean
          preflight: 517 ms, versus the prior byte-at-a-time implementation
          still running after more than 2.5 minutes.
    - [ ] **TDD preserve historical raw coverage measurements:** import every
          recoverable legacy raw TSV into a separately typed historical ledger
          with exact rate/seed/trial/raw-hash fields and explicit unknown
          artifact/source/host/fixture-hash provenance. Render it as a dated
          baseline, including honestly missing bolter cells, never as an
          equivalent signed-current measurement. Curiosity poke: a reused
          filename or changed fixture must start a distinct series rather than
          fabricate a performance or sensitivity delta.
        - [x] Recover and reproducibly import 655 unique legacy raw
              measurements: 654 trial-bearing and one explicit no-trials row.
              Exact root/date-directory copies are deduplicated only when their
              date, series, mode, and raw SHA-256 agree; all absent provenance
              remains literal `unknown`. Completed 2026-07-22 16:53 EDT.
        - [ ] Render the typed historical ledger as a dated baseline with
              `n/a` for absent mechanisms and no comparison delta unless the
              current signed fixture and mutation policy are comparable.

- [x] **Remeasure and, if needed, deepen TIFF validation:** establish current
      sniper/bolter/shotgun rates against the published `pc260001.tif` corpus
      fixture using a signed build. Curiosity poke: uncompressed pixels have no
      intrinsic checksum, but every IFD, strip/tile index, and compressed codec
      stream must still be walked without calling ordinary photographs corrupt.
      Completed 2026-07-17 14:42 EDT: replaced the mislabelled Olympus RAW
      fixture with clean LZW TIFF `bali.tif`; independent 100-trial,
      seed-42 sweeps measured 7% / 45% / 100%. The report generator now
      prefers sample-qualified evidence over stale generic fixture TSVs.

- [x] **TDD deepen PCAPNG structural validation and remeasure coverage:** walk
      every block through its declared size and duplicated trailing length,
      including byte-order changes at subsequent Section Header Blocks, without
      buffering capture payloads. Curiosity poke: extension blocks and a
      multi-section capture are valid, but a corrupt length must never cause an
      overflow, a partial read, or a false PASS. Record fresh deterministic
      sniper/bolter/shotgun rates before updating the public coverage claim.
      Completed 2026-07-17 13:26 EDT: 10% / 8% / 100% over three independent
      100-trial, seed-42 sweeps of the 9,648-byte corpus capture; coverage's
      in-memory dispatch is regression-tested against disk validation.

- [x] **Restore Windows ARM64 GitHub Actions coverage:** prove the forked
      `windows-aarch64` Nix package builds from Linux, then add it to the CI
      matrix as an artifact-build target. Curiosity poke: Windows binaries are
      not executable on the Linux runner, so the workflow must not pretend to
      run the native test suite there. The forked package produced a PE32+
      Windows ARM64 binary in 2m43s. Completed 2026-07-16 08:55 EDT.

- [x] **TDD keep the format round-trip oracle runnable in its clean Nix shell:**
      enumerate the private corpus with a symlink-following, sorted `find`,
      reject zero scanned formats, and exclude reader-audit namespaces from the
      clean-format contract. Curiosity poke answered: deliberate malformed
      audit fixtures remain targeted regressions, while the independent
      normal-corpus shotgun gate scanned 236 families with zero failures.
      Completed 2026-07-15 23:09 EDT.

- [x] **TDD make the completion-backpressure test deterministic on all hosts:**
      hold the producer at the observed full-queue boundary, prove the active
      waiter/high-water state, then release it for a real condition-variable
      wait and verify the completed-wait accounting. Curiosity poke: completed
      wait events increment only after resumption, so no assertion may mistake
      an active wait for a completed one. Completed 2026-07-15 22:25 EDT.

- [ ] **Framework Regis corpus verdict audit:** analyze the 2026-07-15
      validation TSV in place on `framework-nixos`; aggregate every FAIL/WARN,
      then differentially inspect deterministic representative FAIL/WARN/PASS
      samples with independent format readers. Curiosity poke: a PASS is not
      evidence by itself—separate validator blind spots from formats for which
      no independent oracle exists, and never copy confidential documents or
      paths into the repository. First-pass evidence: qpdf + Ghostscript
      accept sampled PDF JBIG2-global, missing-EOF, and recoverable-Flate
      defects; libjpeg-turbo accepts missing-EOI JPEGs; LibreOffice accepts
      DBFs without their terminal marker; DCMTK and GDCM accept sampled DICOM
      VR cases. These belong to narrow WARN classifications, while malformed
      ZIP CRCs, PNGs, corrupt-Huffman JPEGs, and unsupported WPD type 17 stay
      FAIL. The inverse check found valid-labelled MP4s with H.264 decode
      failures plus valid-labelled ZIPs with malformed extra-field lengths:
      both are priority false-negative remediations. An apparent
      external-media MP4 failure was only an unavailable source path and needs
      a self-contained fixture before it can motivate a rule.
  - [x] Preserve a minimal, neutral-named private fixture set in
        `../validate_gui/ground_truth_examples/` with checksums and an
        independent-reader evidence manifest. Curiosity poke: the manifest
        must never reveal case-file paths or names, and a copied byte stream
        must hash-identically to the observed original. Completed 2026-07-15
        21:08 EDT.
  - [x] TDD classify only externally reader-accepted, specifically diagnosed
        PDF JBIG2-global discrepancies as WARN, retaining physically
        truncated/unreadable global streams as FAIL. Curiosity poke: no
        broad `"JBIG2"` string match may demote an unrelated decoder error.
        Completed 2026-07-15 21:08 EDT.
  - [x] TDD surface a stable, optional PDF diagnostic cause and byte offset to
        C/GUI callers without extending a caller-owned ABI struct. Curiosity
        poke: an offset must identify its coordinate system (PDF byte versus
        embedded-stream byte) and absent offsets must be representable.
        Completed 2026-07-15 21:08 EDT.
  - [x] Document evidence-backed false-positive candidates and priority
        false-negative gaps (MP4 semantic decode/external media; ZIP extra
        field lengths), then add one regression at a time before remediation.
        Completed 2026-07-15 21:08 EDT.

- [x] **TDD make the canonical Zig test gate report native test failures:**
      replace the Zig 0.16 `--listen` adapter only if direct emitted-binary
      execution proves it preserves test filtering and propagates real exits.
      Curiosity poke: retain the existing Wine path for Windows cross-tests
      and never turn a test-runner diagnostic into a false-green CI result.
      Completed 2026-07-15 21:34 EDT.

- [x] **Deep code review:** completed a 13-dimension, evidence-based audit of
      current `yolo`, emphasizing validated performance and backpressure hot
      paths; consolidated verified findings in `CODE_REVIEW.md`. Curiosity
      poke answered: critical defects and actual O(n²)/worker-output costs are
      separated from intentional deep-validation work. Began 2026-07-14 14:13
      EDT; completed 2026-07-14 14:43 EDT.

- [x] **TDD/review critical #1 — make active-batch telemetry lifetime safe:**
      replaced raw publication of stack-local budget/debug state with a
      mutex-backed snapshot lease, so retirement cannot race a polling getter
      that has borrowed active-batch state. The deterministic regression holds
      a lease while a second thread attempts retirement, then proves teardown
      completes and subsequent polling is inactive. Curiosity poke answered:
      the lock is confined to infrequent telemetry publication/polling and
      teardown; validation workers retain their hot path and all counters keep
      their existing exact snapshot semantics. Focused test, sandboxed Nix
      check, package build, and full CLI sweep green. Completed 2026-07-14
      15:43 EDT.
- [x] **TDD/review critical #2 — reject a live-file short read safely:**
      `FileSource.getMappedOrSlurp` now returns `UnexpectedEof` on an
      undersized read, letting its existing cleanup free the original
      allocation length rather than returning a shortened owning slice. The
      regression captures 128 bytes, truncates to 8 before the read, uses a
      64-byte `DivertingAllocator` boundary, and proves both explicit
      non-clean I/O outcome and zero remaining large allocation. Curiosity
      poke answered: a growing file still reads its initially bounded prefix;
      only a shrink violates the established ownership contract. Focused test,
      full `./test`, and `./build` green. Completed 2026-07-14 16:12 EDT.
- [x] **TDD/review critical #3 — make batch delivery exhaustive or fail:**
      result serialization now atomically records terminal OOM in the shared
      batch delivery state; workers may skip a callback only after doing so,
      and the waiting caller returns `VALIDATE_ERR_OUT_OF_MEMORY` rather than
      successful completion. The injected failing-allocator regression proves
      the non-success terminal status. Curiosity poke answered: the new
      atomic is written only on the OOM branch and read only after pool drain,
      retaining the deep-validation and successful-callback hot paths.
      Focused test, full `./test`, and `./build` green. Completed 2026-07-14
      22:56 EDT.

- [x] **LibRaw CDDL-1.0 election:** recorded Peter's selected LibRaw license,
      bundled the canonical CDDL-1.0 text, and made the release inventory
      reject a missing, ambiguous, or altered election. Curiosity poke
      answered: the election applies only to LibRaw and does not weaken
      validate's BSL GUI/API restrictions. Completed 2026-07-12 20:22 EDT.

- [x] **Core NOPERM verdict:** classify only normalized OS
      `AccessDenied`/`PermissionDenied` as `access=NOPERM`; retain
      `valid=F`/`unknown=F` for ABI compatibility; add separate core/CLI
      counts, grey presentation, and FFI/JSON coverage. Curiosity poke
      answered: missing/broken paths remain FAIL and a real access denial never
      affects the validation-failure exit status. Completed 2026-07-12 18:48 EDT.
- [x] **Coordinate NOPERM with validate_gui:** pinned core
      `986778c606628e3b2c27120d3fdd9bc0d55ea14a` in GUI commit `12bc254`,
      with real direct and streamed backend-to-GUI OS-denial frame tests.
      Curiosity poke answered: exact `access=NOPERM` wins before legacy
      `valid=F`/`err` handling; no error-text heuristic is accepted. Completed
      2026-07-12 19:11 EDT.

- [x] TDD replace the overlapping 240+ formats rollover with an in-page, wide categorized format list; make 240+ and conditional TRY IT! stat cards smooth-scroll anchors to that list and the fresh prerelease downloads beneath it. Curiosity poke answered: no tooltip or hover reflow remains; missing or expired releases render no dead TRY IT! anchor, and 50-locale parity stays enforced. Completed 2026-07-12 16:09 EDT.
- [x] Replace the retired Garnix and hard-coded Mechatron README badges with the public dynamic `validate` Mechatron Prime endpoint, linking clicks to the Mechatron image/about page. Completed 2026-07-11 22:59 EDT.

### validate.pics GUI prerelease publishing (2026-07-11)

- [x] TDD update the five-platform downloads layout: keep the Linux pair
      together, place both Windows variants together in the final row, retire
      the dead header purchase CTA, and move Detection Coverage into the main
      content. Curiosity poke answered: the fixed mobile header now contains
      only its brand and locale control, so it cannot wrap over the title; the
      five-card desktop layout remains balanced without hover-driven reflow.
      Peter approved full desktop and 390px mobile captures. Completed
      2026-07-14 10:50 EDT.
- [x] TDD add generated `windows-aarch64` manifest support as a fifth release
      platform, labelled **Windows ARM64**. Curiosity poke answered: the
      site renderer remains strict and dormant until `validate_gui` atomically
      publishes a fresh signed URL; no manual/speculative link was rendered.
      Also repair the publish gate's test discovery for the deliberately
      glob-disabled shell environment. Completed 2026-07-13 19:46 EDT.
- [x] TDD a strict `current_releases.toml` reader: accept only the four published platform keys and fresh HTTPS SigV4 URLs; render only present, unexpired links. Curiosity poke answered: malformed, duplicate, or expired data never becomes an HTML download link. Completed 2026-07-11 16:43 EDT.
- [x] Add `./publish-validate-pics`: use a clean worktree at current `origin/yolo`, run the site generator and its tests against the sibling release file, commit only generated `docs/`, and push; keep `./build` network-free and independent. Curiosity poke answered: it preserves a developer's dirty checkout and fails before publishing stale links. Completed 2026-07-11 16:43 EDT.
- [x] Add fully localized homepage download copy across the existing 50 enforce-phase catalogs, regenerate `docs/`, and run focused site plus full project tests. Curiosity poke answered: test English, German, Arabic/RTL, absent platforms, escaped URLs, stale inputs, and root-invocation portability. Completed 2026-07-11 16:43 EDT.
- [x] Obtain Peter's visual sign-off for the rendered desktop/mobile download cards, then commit and push the focused site work. Completed 2026-07-11 17:28 EDT.
- [x] TDD permission-tolerant release generation: an inaccessible sibling manifest warns and omits downloads for regular site generation, while `publish-validate-pics --check` still refuses to publish without readable fresh links. Curiosity poke answered: missing input stays silent, denied input emits a warning, malformed input remains fatal, and expired input remains publisher-ineligible. Completed 2026-07-11 18:44 EDT.
### Deep-validation performance continuation (2026-07-10)

- [x] **TDD/review critical #4 — bounded startup selection:**
      replaced recursive last-element Lomuto P90 selection with iterative
      three-way introselect: median-of-three normal pivots, equal-value middle
      partitioning, and a median-of-medians fallback after the depth budget.
      The actual CLI translation unit is compiled into a deterministic 100k
      ascending/descending/equal operation-count oracle. Its ascending case
      fell from 949,995,000 to 3,561,387 comparisons (99.625% fewer), with a
      40N cap that rejects the former ~9,500N path without timing dependence.
      The repaired 14-file CLI regression proves default scattering executes,
      keeps both large files separated, and preserves exact result membership
      against `--no-frontload`. Focused Nix checks, full `./test`, and
      `./build` green. Completed 2026-07-15 01:00 EDT.
- [x] **TDD/review critical #5 — keep completion I/O off
      validation workers:** completed results now cross a preallocated bounded
      FIFO (`max(2, 2 × workers)`) to one dedicated completion executor; begin
      callbacks remain freely concurrent and no begin/result pairing or
      cross-file ordering is implied. A latch-driven ABI test blocks the first
      completion callback, proves the queue reaches capacity two with a worker
      waiting, then releases it and verifies all four owned results and an OK
      batch status. The additive ABI v2.2 snapshot and `HEAP_FRAG_DEBUG`
      `[SCHED]` line expose cumulative/per-window worker wait ns/events,
      current waiters, and high-water without overwriting an older caller's
      scheduler struct. Curiosity poke answered: result memory is bounded and
      exact delivery remains mandatory; a separate real-corpus normal/@null/
      slow-sink measurement remains queued once local disk contention clears.
      Focused tests, full `./test`, and `./build` green. Completed 2026-07-15
      01:30 EDT.
- [x] **TDD foundation for critical #5 — bounded generic completion queue:**
      replaced the generic pool's allocating, LIFO result list with a
      preallocated FIFO capped at `max(2, 2 × workers)`. A latch-driven test
      blocks its callback, fills the two-slot queue, observes a producer wait
      event and high-water mark of two, then releases it and proves all four
      results arrive. This establishes bounded memory and worker wait-ns
      telemetry before `validate_batch` adopts the result type. Focused test,
      full `./test`, and `./build` green. Completed 2026-07-15 01:18 EDT.
- [x] **TDD/review redundant deep re-open:** structural and deep validation
      now share one regular-file descriptor. `FileSource` explicitly models
      borrowed ownership, preserving POSIX mmap while a non-mmap fallback never
      closes the caller's FD. A regression proves both borrowed source modes
      leave the descriptor open; a text parity test and disk-vs-memory corrupt
      PDF differential retain verdict/depth behavior. On the identical
      512-file RAM-resident text fixture, canonical ReleaseFast binaries both
      returned success while path `openat` fell 1,024→512 and path stats
      2,561→2,049: 1,024 fewer path syscalls (−28.6%). Completed 2026-07-15
      02:09 EDT.
- [x] **TDD/add immutable enumeration sizes to the batch ABI:** added additive
      ABI v2.3 `validate_batch_sized()` with positional `size_t` discovery
      metadata and `SIZE_MAX` unknown sentinel; retained `validate_batch()`
      unchanged. The CLI passes its already-reordered immutable enumeration
      sizes, so admission, large-file gating, and diagnostics avoid two extra
      stats per known path while an actual opened file remains authoritative
      for validation. The red regression proves a supplied size defeats the
      missing-path 1 MiB stat fallback, and the bounded-callback test exercises
      the public entry point. On the fixed 512-file RAM fixture, old/current
      JSON results were byte-identical; `openat` stayed 547 while path stats
      fell 3,091→2,067, exactly −1,024 (−28.1% total path syscalls).
      Single-worker CPU/wall/RSS sample was 0.65/0.48/26.91s/5,160KiB before
      and 0.64/0.49/26.81s/3,116KiB after—metadata counts are the accepted
      stable evidence, not the noisy wall-time difference. Curiosity poke
      answered: the sample revealed a separate 50ms-per-task admission delay,
      queued next. Completed 2026-07-15 08:29 EDT.
- [x] **TDD/remove single-worker RSS-admission cadence tax:** added the pure
      sampler-delay policy: after a first sample, only a pressured batch or a
      batch with more than one potential worker retains the 50ms cadence. An
      unpressured lone worker instead samples immediately, while the policy
      regression explicitly retains both pressure and concurrent-worker
      delays. On the fixed 512-file RAM fixture, byte-identical results went
      from 26.58s wall / 0.65s user / 0.25s system to 0.88s / 0.67s / 0.16s:
      wall −96.7% with no validation work removed. `HEAP_FRAG_DEBUG` confirmed
      the false `rss_pressure` total fell 24,998,974,773ns / 499 events → 0,
      with every other scheduler wait category remaining zero. Curiosity poke
      answered: one-worker immediate samples are bounded cheap RSS reads;
      pressured and concurrent paths keep centralized cadence. Completed
      2026-07-15 08:40 EDT.
- [x] **TDD/remove mapped deep-PDF document copy:** `validatePdfDeep()` now
      reuses `FileSource.getMappedSlice()` for POSIX mmap and caller-owned
      buffers, retaining the existing bounded allocation/read/short-read path
      for non-mappable and Windows sources. A counting-allocator regression
      requires zero document-sized allocations while a corrupt Flate stream
      still FAILs. Normal/corrupt disk-vs-buffer, encrypted/font unit paths,
      and the full suite remain green. The canonical 22.8 MiB NASA PDF,
      100 rounds/mode, seed 42, strict single-worker coverage gate kept exact
      Sniper/Bolter/Shotgun sensitivity (21/100, 33/100, 74/100) while peak
      RSS fell 27.5%, 28.1%, and 26.0% respectively; wall time stayed flat
      because every deep decode remains intact. Curiosity poke answered: the
      slice lifetime is tied to `FileSource`, and fallback behavior retains
      the previous complete-read contract. Completed 2026-07-15 10:11 EDT.
- [ ] **Profile then TDD/unify repeated deep-PDF discovery:** share immutable
      PDF object/stream discovery (including JBIG2 globals) between
      image/font/embedded/residual passes. Curiosity poke: preserve every
      decode and malformed-xref fallback; accept only after differential
      normal/malformed/encrypted/font-heavy tests and PDF telemetry prove less
      scanning and re-inflation.
- [ ] **Measure platform-specific deep I/O before changing it:** profile real
      Windows x64/Arm64 `FileSource` positional reads and bounded-slurp depth
      downgrades; add a correctly-owned Windows mapping adapter only if the
      evidence warrants its complexity. Curiosity poke: a mapping failure must
      retain the present bounded fallback and depth parity.
- [x] TDD the long-run small-file throughput fix: replaced the CLI completion callback's `file_id`→size linear scan with an O(1), ID-indexed size lookup; added a deterministic probe-count classifier over a deliberately reordered set so an N² regression fails without timing dependence. The scan control proved 2,080 ID comparisons for 64 completions; the direct map proves 64 probes and the correct 2,080 bytes. Completed 2026-07-11 14:53 EDT.
- [ ] After the current local disk contention clears, measure a 100k+ small-file fixed window with scheduler wait ns, process CPU/RSS/threads, and the persistent host-pressure recorder. Curiosity poke: distinguish callback lookup serialization from RSS or memory-budget gating before proposing a resumable batch boundary.
- [x] Close the pushed backpressure commit's CI run: macOS aarch64 and both Linux targets passed build + full tests; Windows failed before compilation while fetching pinned PCRE2 (`HttpConnectionClosing`). Leave code unchanged and use the final push as the clean retry. Completed 2026-07-10 13:35 EDT.
- [x] Evaluate format-aware SQLite admission on a fixed 42-file / 14.446-GiB deep workload. Rejected despite exact verdict/depth parity: memory wait fell 136.6e9→0 ns, but wall improved only 0.96%, RSS wait rose 212.4e9→244.5e9 ns, and peak RSS worsened 5.5%. Implementation removed. Completed 2026-07-10 11:51 EDT.
- [x] Evaluate a static `CPU / outer_jobs` PDF inner cap. It was excellent on the 12-worker 42-file stress workload (wall −11.1%, CPU −53.6%, RSS −54.4%, exact deep-result parity) but rejected on the full auto workload: only 4–7 sequential PDFs ran, files fell 9,958→4,276 and bytes 17.69→0.41 GiB despite RSS 11.89→2.05 GiB. Completed 2026-07-10 12:20 EDT.
- [x] Evaluate shared nested-token variants. Both preserved exact results but serialized long PDFs or starved the two giant SQLite tasks: first-claimer wall 222.41s; fair-waiting wall 146.52s versus 95.27s control. Implementations removed. Completed 2026-07-10 12:43 EDT.
- [x] TDD a batch-aware nested PDF policy: cap outer workers to queued files, bind the actual batch width to each worker, retain standalone CPU/3 fan-out, and balance nested fan-out against a measured square-root contender ceiling. Keep the sequential deep image path when only one inner job is available. Completed 2026-07-10 13:05 EDT.
- [x] Measure the identical RAM-resident 42-file workload and full 595,792-file fixed window with CPU/wall, peak RSS, threads, bytes, all scheduler wait ns, and exact verdict/depth differential comparison. The 42 normalized result sets were identical; wall −13.73%, CPU time −52.72%, peak RSS −48.92%, peak threads −82.79%. Completed 2026-07-10 13:10 EDT.
- [x] Re-run the fixed Mac Documents window and retain only the multi-metric winner. Versus the contemporary control: files +25.45%, average CPU +15.37%, peak RSS −5.33%, peak threads −18.98%, physical reads −11.25%; deep-validation behavior is unchanged. Completed 2026-07-10 13:27 EDT.
- [ ] Run `./test` and `./build_all`, commit/push the known-good optimization, update `validate_gui`, run its full suite, push, and watch the fresh CI retry. Curiosity poke: distinguish another dependency fetch failure from a compile/runtime regression.
- [ ] Profile the next dominant validator/allocator owner from measured task time and memory, then repeat the TDD + differential + benchmark cycle. Curiosity poke: prefer asymptotic/I/O reductions over allocator micro-tuning, and verify that C-library shortcuts do not reduce decode depth.

### Scheduler evidence on complete Mac Documents corpus (2026-07-09)

- [x] Add DEBUG-only thread-pool snapshots: cumulative and per-report-window wait time in ns for `queue_empty`, `memory_budget`, and the FFI RSS-pressure throttle; surface them through `HEAP_FRAG_DEBUG` without default hot-loop clock reads. TDD green. Completed 2026-07-09 22:05 EDT.
- [x] Run a fresh ReleaseFast `validate --jobs 0` sample against `/home/pmarreck/perf-corpora/mac-documents` with 5-second scheduler/heap diagnostics and independent process sampling. The intentionally terminated 185-second sample is preserved in `~/perf-results/validate/20260709T215239EDT-mac-documents-rss-scheduler`. Completed 2026-07-09 22:05 EDT.
- [x] Analyze the sample before proposing allocator, arena, or queue changes: queue-empty time stayed at a 1.16s startup total; RSS-pressure throttling reached 5.15e12 aggregate ns (about 86 worker-minutes) with 70/85 waiters; memory admission was only 2.19s. Completed 2026-07-09 22:05 EDT.
- [x] Choose a remediation: replace the per-task 500ms RSS sleep with centralized, hysteretic admission before memory reservation. Release bounded permit batches from conservative measured headroom so a low-RSS wake cannot stampede all workers or needlessly serialize small-file throughput. Completed 2026-07-10 09:00 EDT.
- [x] TDD: add a generic pre-execution admission hook to ThreadPool and a deterministic RSS-gate policy test (high→hold, low→bounded admissions). The hook runs before memory-budget reservation; interrupt makes the gate return so the existing task-entry interrupt check skips work. Full `./test` green. Completed 2026-07-10 09:35 EDT.
- [x] Implement the RSS admission gate and remove the timeout throttle; retain per-window nanosecond wait diagnostics. The single sampler, active-aware permits, pressure relief, and one-task escape are correctness behavior independent of DEBUG. Full `./test` green. Completed 2026-07-10 10:54 EDT.
- [x] Measure the same Mac Documents workload before/after and preserve rejected candidates. Accepted result: 12,831→9,958 files (−22.39%) while peak RSS fell 26.46→11.89 GiB (−55.06%); files/peak-GiB improved 72.71%. The repeated control matched the prior-day ~12.7k-file result. JSONL + report committed under `bench/results/` and `docs/performance/`. Completed 2026-07-10 11:00 EDT.

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
- [ ] **Profile strict UTF-8 SIMD fast path.** Evaluate simdutf-style
  ASCII/UTF-8 validation only after recording representative text-validation
  CPU profiles. A SIMD acceptance may skip the scalar validator; every SIMD
  rejection must replay the existing scalar path to retain exact first-error
  offsets and Unicode-warning semantics. Differential malformed-input tests
  and scalar-vs-SIMD benchmarks are both ship gates. Curiosity poke: files
  with warning-worthy but valid Unicode must never become a fast-path blind
  spot.
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
