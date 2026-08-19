# Validate image-parser 1.0 master plan

> **STATUS (2026-08-19): historical snapshot, partially superseded.** The
> ordered finish-line queue items 2–5 landed after this audit: tiffz good-corpus
> acceptance restored + WARN-coded findings, jpegz became the product JPEG path
> (via tiffz single-instance re-export), jp2z replaced OpenJPEG
> (`tiffz.jpegz.jpeg2000.strictValidate`, deps/openjpeg removed), libjxlz
> strict API landed and replaced stock libjxl (direct pin dropped; routed via
> tiffz.jpegz). The v1 production-closure hard-gate (src/core/v1_closure.zig)
> now makes the forbidden third-party decoders uncompilable. LIVE per-format
> status is no longer maintained here — it is generated evidence in
> `docs/CAPABILITY_MATRIX.tsv` (regenerated + diff-gated by
> `tests/cli/capability_matrix`). Still-open items from this plan (corpus
> manifest/adjudication provenance, full confusion-matrix sweep records,
> embedded-input sentinel matrix) remain tracked in PLAN.md.

Last audited: 2026-07-23 EDT  
Program owner: Einstein / Validate  
Library owners: `tiffz`, `libjxlz`, `jp2z`, `jpegz`

## Release ruling

Validate 1.0 is blocked on trustworthy library behavior for TIFF, JPEG XL,
JPEG 2000, and JPEG. A parser's CLI is useful dogfooding, but it is not a 1.0
gate when CLI work competes with:

- correct strict validity decisions;
- rich, stable, byte-located diagnostics;
- bounded operation on an image embedded inside another format;
- high, honestly classified valid/corrupt corpus coverage;
- the actual Validate integration path.

Stock decoder acceptance is an oracle datum, not proof of validity. Likewise,
rejecting every unfamiliar file is not “strictness.” Every result must retain
at least these distinct states:

1. valid;
2. valid with non-canonical/tolerated findings;
3. unsupported-valid;
4. invalid;
5. resource-limit or otherwise inconclusive.

## Evidence snapshot

The product-level measurements below used the current signed Linux Validate
binary built from source commit
`9f405ea72f21eceedd94dfce8ffb05b57993752c`. The labeled-good counts cover
every file with the format's actual image extension in the named
`ground_truth_examples` directory; README/documentation files are excluded.
The labeled-corrupt counts cover every format fixture in the corresponding
corrupt directory. The mutation rows come from the append-only run
`20260722T183936Z-9f405ea72f21-b0of1`, 100 trials per cell, seed 42.

| Format | Current product implementation | Good accepted | Corrupt rejected | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|---:|
| TIFF | `tiffz` `bcbe83b4616a…` | 10/15 | 0/5 | 0/100 | 0/100 | 0/100 |
| JPEG | Validate/libjpeg-turbo | 5/5 | 6/6 | 4/100 | 8/100 | 100/100 |
| JPEG XL | stock `libjxl` | 8/8 | 4/5 | 87/100 | 97/100 | 100/100 |
| JPEG 2000 | stock OpenJPEG | 10/10 | 0/5 | 6/100 | 5/100 | 97/100 |
| JPEG-in-TIFF/mixed | `tiffz` → `jpegz` or ordinary JPEG | 2/2 | no labeled set | 15/100 | 22/100 | 100/100 |

Canonical repository suites were also run from their observed working trees on
2026-07-23 EDT:

| Repository | `./test` result | Release interpretation |
|---|---|---|
| `tiffz` | PASS | Existing suite is green but omits the five product false-positive regressions. |
| `libjxlz` | FAIL (exit 3) | Native Brotli runtime closure, portable C test, and Windows Brotli cross-linking are broken. |
| `jp2z` | FAIL (exit 1) | Nix-clean source omits the untracked embedded fixture; linked smoke targets also report contradictory compile-failure/PASS output. |
| `jpegz` | PASS | Gate is not credited until contradictory C-smoke compile-failure/PASS output is explained or fixed. |

The libjxlz and jp2z measurements include their existing dirty worktrees. They
are not claims about the last commits, and the untracked-fixture failure is
itself proof that reproducibility must be evaluated from the clean Nix source.

Important qualifications:

- The current sweep chooses one largest fixture per format. TIFF therefore
  selected uncompressed `pc260001.tif`, where pixel bytes have no checksum,
  and incorrectly made 0% look representative of all TIFF codecs.
- Prior compressed `bali.tif` evidence was still only 7% sniper, 45% bolter,
  and 100% shotgun. Per-compression stratification is mandatory.
- Each labeled-corrupt TIFF/JP2/JXL miss is a one-byte zero mutation.
  ImageMagick accepts the missed files and renders changed pixels. Each byte
  must be mapped to the format grammar before it can be called invalid:
  a syntactically valid different image is not detectable without an external
  hash or the original, whereas a violated bitstream invariant concealed by
  a tolerant decoder is exactly what these strict libraries must catch.
- The current harness measures only mutated-input rejection. It does not
  record the source fixture's clean verdict in the same evidence record, so it
  is not yet a full confusion-matrix harness.

## Current readiness, critically assessed

### `tiffz`

Current strengths:

- cleanroom TIFF/BigTIFF architecture with caller-supplied `Source`;
- broad compression and photometric work, resource limits, findings callback;
- Validate already pins it and decodes every materialized strip/tile;
- strict LZW terminator and exact decoded-extent work exists.

Release blockers:

- [ ] Reproduce and fix all five labeled-good false rejects through
      `validateAllStripsAndTiles`: `cramps-tile.tif`,
      `deflate-last-strip.tiff`, `lzw-single-strip.tiff`,
      `quad-tile.tif`, and `ycbcr-cat.tif`.
- [ ] Add positive tests for exact decoded extent at edge tiles, final short
      strips, bilevel packed rows, planar data, and subsampled YCbCr. The exact
      extent rule must reject early termination without inventing bytes that a
      valid encoder was not required to emit.
- [ ] Adjudicate the five `rgb-3c-8b_corrupt_*` mutations. They are mutations
      of an uncompressed RGB TIFF and therefore likely valid-but-different
      pixel values, not malformed TIFFs; relabel them if so.
- [ ] Replace the single-largest-fixture TIFF sweep with per-compression and
      per-layout strata: uncompressed, PackBits, LZW, Deflate, CCITT G3/G4,
      JPEG, LERC, Zstd, stripped/tiled, classic/BigTIFF, predictor 1/2/3.
- [ ] Give terminal errors structured finding codes and useful offsets rather
      than collapsing diverse failures to “Invalid TIFF structure.”
- [ ] Prove an explicitly bounded sub-source contract for embedded TIFF/Exif:
      all absolute offsets are relative to the embedded TIFF origin, no tag or
      strip read can escape its declared length, and diagnostics can report
      both local and containing-file offsets.
- [ ] Add directed malformed fixtures for IFD cycles, overlapping/out-of-range
      arrays, count/size overflow, truncated values, duplicate/conflicting
      required tags, codec terminators, and decoded-size mismatch.
- [ ] Run the full good corpus as a mandatory regression, not just selected
      copied fixtures with different hashes.

Verdict: **not 1.0-ready**. It is already integrated, but presently rejects
one third of Validate's labeled-good TIFF corpus.

### `libjxlz`

Current strengths:

- substantial pure-Zig JXL decoder/encoder implementation;
- five checked byte-identical decode fixtures;
- two spline fixtures narrowed to `+/-1` output differences;
- explicit known-diff and known-unsupported buckets.

Release blockers:

- [ ] Restore a reproducibly green canonical suite. The 2026-07-23 `./test`
      run exited 3: native Nix test binaries lacked `libbrotlienc.so.1`,
      one C test used undeclared GNU-only `memmem`, and the x86_64-windows
      cross build could not resolve Brotli. Runtime closure, portable tests,
      and five-platform linkage precede all parser score claims.
- [ ] Create a first-class strict validation API. The repository currently has
      no `ValidationReport`, `FindingCode`, `FindingsSink`, or public
      `validate(data)` surface comparable to jpegz/jp2z.
- [ ] Expand beyond the tiny current manifest: 5 passing, 2 known-diff, and
      4 known-unsupported fixtures is not a complete JPEG XL corpus.
- [ ] Close common valid decoder gaps, especially VarDCT and blending.
      Validate cannot replace stock `libjxl` with a modular-only validator.
- [ ] Resolve the two spline `+/-1` oracle differences or prove a documented
      numerical tolerance that does not hide structural corruption.
- [ ] Run libjxlz itself over Validate's 8 labeled-good and 5 labeled-corrupt
      fixtures; the current product numbers belong to stock `libjxl`.
- [ ] Adjudicate `bicycles_corrupt_5.jxl`, the currently accepted mutation,
      against box/codestream grammar and independent decoders.
- [ ] Strictly validate JXL container boxes, extended/open-ended lengths,
      `jxlc`/`jxlp` ordering and completeness, Brotli-compressed metadata,
      ICC payloads, frame/animation/blending references, TOC/group extents,
      entropy final states, and trailing bits/bytes.
- [ ] Prove caller-bounded buffer operation and local plus host-relative
      offsets for a JXL codestream or box payload embedded by a future
      container adapter.
- [ ] Define and implement the Validate shim only after unsupported-valid and
      invalid are mechanically distinct.

Verdict: **furthest from 1.0-ready**. It is not the Validate product path and
lacks the required validation API.

### `jp2z`

Current strengths:

- public Zig decode/validate API, stable findings, C FFI, and strict deep
  validation entry point already exist;
- pure-Zig codestream/JP2 parsing, packet walking, MQ/EBCOT, inverse wavelets,
  and a deterministic ISO 15444-4 sweep;
- 22 of 57 conformance fixtures are byte-exact and one is near.

Release blockers:

- [ ] Restore a reproducibly green canonical suite. The 2026-07-23 `./test`
      run failed because the Nix-clean source omitted the untracked
      `p1_04.j2k` fixture referenced by `@embedFile`. It also exposed
      OpenJPEG-linked CLI/FFI compile failures followed by PASS output from
      smoke executables. Fixture provenance and failure propagation must be
      deterministic before any conformance score is credited.
- [ ] Resolve the current conformance scorecard: 13 decoded-but-wrong FAILs,
      20 oracle-incomparable skips, and one unsupported error leave only
      22/57 byte-exact PASS plus one NEAR.
- [ ] First fix `p1_04.j2k` (>8-bit, max absolute error 3782), then the
      12 remaining decode divergences in descending measured severity.
- [ ] Convert each skip caused by signed samples, subsampling, or dimension
      mismatch into a real comparable oracle rather than permanent exclusion.
- [ ] Support/adjudicate `p0_13.j2k` (`NoCodingParams`).
- [ ] Run jp2z itself over Validate's 10 labeled-good and 5 labeled-corrupt
      fixtures; the current product numbers belong to OpenJPEG.
- [ ] Adjudicate all five accepted `balloon_corrupt_*` mutations by JP2 box,
      tile-part, packet header, and code-block location.
- [ ] Finish strict SOT/Psot length and ordering, required EOC, reserved and
      field-range validation, coding-pass budgets, tag-tree monotonicity,
      packet under/over-read, MQ termination, and optional SOP/EPH sequence
      checks.
- [ ] Preserve exact finding offsets through JP2 boxes into raw codestream
      offsets; entropy findings currently emitted by reconstruction with
      `offset = null` are insufficient.
- [ ] Prove bounded raw-codestream/JP2-box operation for PDF `JPXDecode`, ICNS
      entries, DICOM encapsulated frames, GeoJP2, and TIFF compression
      33003/33005. No decoder callback may read adjacent container bytes.
- [ ] Replace Validate's OpenJPEG validator and PDF JPX path only after the
      strict library corpus gate passes.

Verdict: **not 1.0-ready**. The validation architecture is promising, but the
decoder currently produces materially wrong pixels on nearly a quarter of the
57-fixture conformance set and cannot honestly claim complete T.800 coverage.

### `jpegz`

Current strengths:

- the most mature strict validation API of the four;
- stable severity/code/offset findings, non-fail-fast marker walk, and
  codec-level decode-through;
- a 4,125-file real-world baseline corpus audit reached 3,837 cleanroom
  successes, 277 wrapper-only progressive files, and 11 correctly diagnosed
  mislabel/truncation cases at that historical checkpoint;
- broad baseline, progressive, lossless, arithmetic, higher-precision, and
  partial JPEG-LS cleanroom work.

Release blockers:

- [ ] Make jpegz's canonical `./test` gate internally consistent. On
      2026-07-23, Zig reported `compile exe c_smoke ... failure` with nested
      static-archive warnings, after which the C smoke test printed PASS and
      the enclosing Nix suite exited successfully. Prove this is harmless
      progress-renderer noise or fix a stale-artifact/vacuous-test path; a
      green gate may not coexist with an unexplained compile failure.
- [ ] Run `jpegz.validate` over Validate's complete labeled-good/corrupt JPEG
      corpus and preserve its actual confusion matrix. Current product results
      belong to Validate's libjpeg-turbo path.
- [ ] Integrate jpegz into ordinary JPEG and PDF `DCTDecode` validation; it is
      presently reached mainly through tiffz's JPEG-in-TIFF path.
- [ ] Decide and test strict policy for missing EOI and all other WARN findings.
      A tolerant decode warning cannot silently become a strict PASS.
- [ ] Finish or explicitly classify remaining valid variants: differential
      SOF5-7/SOF13-15, SOF11 arithmetic lossless, JPEG-LS ILV=1/restarts/four
      components, unusual lossless sampling/point transforms, and progressive
      CMYK. “Unsupported-valid” is acceptable only as an honest temporary
      state, not as full validation.
- [ ] Stratify mutation evidence into APP metadata, marker/table structure,
      entropy payload, restart intervals, padding/stuffing, and trailing data.
      JPEG has no whole-image checksum, so random entropy mutations that form a
      valid different coefficient stream cannot be detected from the file
      alone.
- [ ] Prove exact scan completion, restart sequence, padding/stuffing rules,
      table/component references, EOI policy, and no unreported recovery.
- [ ] Prove bounded use in PDF DCT streams, TIFF strips/tiles with JPEGTables,
      DNG/RAW previews, and other embedded JPEGs. Findings need both
      substream-relative and host-relative offsets.
- [ ] Resolve the current detached Git HEAD safely before committing.
- [ ] Refresh stale README/PLAN claims, including the README's obsolete
      “Greenfield. No code yet” status and contradictory completed/open
      12-bit/JP2 milestones.

Verdict: **closest to 1.0-ready as a library**, but it is not yet the ordinary
Validate JPEG path and its rare-variant/strict-policy gaps remain.

## Cross-format release gates

### A. Honest corpus and scoring gate

- [ ] Add a manifest for every good and bad fixture with source/provenance,
      license, SHA-256, expected state, format/profile features, and at least
      one independent oracle.
- [ ] Adjudicate every existing “corrupt” fixture. Never reward a parser for
      rejecting a syntactically valid, different image.
- [ ] Extend the sweep record so it first proves the clean source fixture's
      expected verdict, then records the mutated verdict.
- [ ] Emit a true confusion matrix per parser/profile:
      valid accepted, valid rejected, invalid rejected, invalid accepted,
      unsupported-valid, and inconclusive.
- [ ] Run every corpus fixture, not one largest file per extension.
- [ ] Record mutation region/semantic owner: container structure, metadata,
      codec table, entropy data, padding, unused bytes, or unknown.
- [ ] Keep the actual command name `bolter` (single-byte XOR) documented; accept
      `boltgun` as a human-facing alias if desired.
- [ ] Preserve deterministic seed, exact mutation, signed artifact, commit,
      target, and raw trial output in the append-only evidence ledger.

Minimum score policy:

- 100% acceptance of adjudicated valid fixtures for supported profiles;
- 100% rejection of directed fixtures that violate a required invariant;
- no unsupported-valid input reported as invalid;
- no crash, hang, out-of-bounds read, leak, or unbounded allocation;
- compressed-payload shotgun target at least 95%, with 99% preferred;
- sniper/bolter are reported by grammar region and codec rather than assigned
  a dishonest universal threshold where the format has no checksum.

### B. Strict diagnostic gate

- [ ] Stable machine-readable finding code, severity, local byte offset,
      containing-file byte offset, expected value/range, actual value, and
      parser context stack (box/IFD/strip/scan/tile/packet/frame).
- [ ] Accumulate multiple safe findings; stop when resynchronization is unsafe.
- [ ] Distinguish malformed input from unsupported feature and resource limit.
- [ ] Preserve all useful library findings through the Validate result/JSON/C
      APIs rather than flattening them to one string.
- [ ] Differential tests against at least two independent readers where
      available, plus mutation/property/metamorphic tests that do not share the
      parser's implementation.

### C. Embedded-input gate

Every library must accept an explicitly bounded byte source:

```text
host bytes ──> [base_offset, length] bounded view ──> parser
                         |
                         └─ findings: local offset + host offset
```

- [ ] Checked `base + length` arithmetic with overflow tests.
- [ ] Reads/seeks before base or at/after length fail without touching adjacent
      host bytes.
- [ ] Child-declared offsets are relative to the correct format origin.
- [ ] Container bytes after the image cannot satisfy a missing EOI/EOC/box/tag.
- [ ] Exact-length and deliberately adjacent-sentinel tests for buffer, mmap,
      and callback/vtable adapters.
- [ ] Nested resource budgets propagate from Validate; a tiny embedded payload
      cannot request attacker-controlled gigabytes or unlimited work.

Required integration matrix:

| Parser | Standalone | Embedded paths required before 1.0 |
|---|---|---|
| jpegz | JPEG file | PDF DCT, TIFF/JPEGTables, DNG/RAW previews |
| jp2z | JP2/J2K | PDF JPX, ICNS JP2, DICOM frames, GeoJP2; TIFF JP2 when supported |
| tiffz | TIFF/BigTIFF/DNG/RAW | Exif/TIFF payloads in JPEG/PNG/WebP/HEIF/AVIF |
| libjxlz | JXL codestream/container | bounded codestream/box adapter for any containing format; no adjacent-byte borrowing |

### D. Shipping gate

- [ ] `./test` and `./build` pass cleanly in each library.
- [ ] Validate pins exact green commits and its full suite/build pass.
- [ ] Good/corrupt corpus matrices and sniper/bolter/shotgun evidence are
      regenerated against the signed candidate.
- [ ] Cross-target builds remain green for Linux/macOS/Windows x86_64/aarch64;
      platform omissions are reported as unsupported, never silently shallow.
- [ ] Sanitizer/fuzz runs cover every public buffer/FFI validation entry point.
- [ ] All dirty-state ownership is resolved; no agent commits another agent's
      work, generated cache state, or global briefing symlink changes.
- [ ] CLI omissions, if any, are written as post-1.0 work and do not block the
      library release.

## Ordered finish-line queue

1. **Fix the test oracle first.** Implement the complete corpus manifest,
   source-validity preflight, adjudication states, and per-region evidence.
2. **tiffz false-positive emergency.** Restore 15/15 good-corpus acceptance,
   preserve strict early-terminator rejection, and stratify TIFF scores.
3. **jpegz product cutover.** Verify its own matrix, lock strict warning policy,
   then replace ordinary JPEG and PDF DCT validation without losing findings.
4. **jp2z conformance closure.** Eliminate the 13 decode divergences and 20
   incomparable skips, then cut Validate/PDF/ICNS/DICOM from OpenJPEG to jp2z.
5. **libjxlz validation productization.** Add the missing strict API, close
   VarDCT/blending/common-container gaps, widen the corpus, then replace
   Validate's stock libjxl path.
6. **Embedded matrix.** Run bounded-sentinel tests and real container fixtures
   for every required path above.
7. **Signed candidate audit.** Full matrices, sweeps, fuzz/sanitizer, all
   targets, Validate integration suite, commit/push/CI.

No project advances to the next line by declaring a milestone complete. It
advances only when the evidence named by that line is checked in and green.
