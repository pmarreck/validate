#### PDF detection by stream-filter dominance

A single "PDF detection rate" misleads. PDF is a container; its real bit-flip
detection ceiling depends on which compression filter dominates the file's
byte volume. We deep-validate every embedded stream by running it through
its codec (Flate via zlib, DCT/JPEG via libjpeg-turbo, JPX/JPEG2000 via
OpenJPEG, JBIG2 via our own decoder, CCITT via our G4 reader). What the
validator detects is bounded by what the codec rejects — not by validator
effort.

| PDF byte-mix dominance | Sniper (1-bit flip) | Shotgun (4 KB overwrite) | Why |
|---|---:|---:|---|
| Flate-dominated (text books, code/glyph data) | **~90%** | **~90%** | zlib Adler-32 catches almost every flip in compressed bytes; remaining ~10% are inside structurally-valid Flate output that's still parseable PDF. Sample: 876 KB Vonnegut text PDF, 50 rounds. |
| Mixed Flate + DCT/JPEG (illustrated text) | **~46%** | **~88%** | libjpeg's `emit_message` is now escalated so any negative-level warning ('Premature end of data segment', 'Corrupt JPEG data: bad Huffman code', 'Extraneous bytes before marker') aborts decode rather than silently continuing. Sample: 3 MB book with 296 Flate + 40 DCT streams, 100 rounds. Pre-escalation (jpeg_validator only hooked error_exit, not emit_message): sniper 20%, shotgun 85% — escalation roughly doubled sniper detection. Verified zero false-positives on a 12-PDF random NAS sample. |
| JPX / JPEG2000-dominated (photo books, picture books, archive scans) | **~0%** | **~2%** | OpenJPEG's wavelet decode degrades gracefully into visual artifacts; only flips that hit JPEG2000 markers (SOC, SIZ, COD, SOT, EOC) cause decode failure. Standalone 506 KB JP2 stream extracted from sample: 0/54 sniper, 1/46 shotgun (100 rounds, seed=42). |
| JBIG2-dominated (scanned bilevel pages) | **~0%** (expected, untested standalone) | **~few %** (expected) | Same shape as JPEG2000 — JBIG2's arithmetic coder is corruption-tolerant; only segment-header flips fail decode. Future sample-extraction needed. |
| CCITT G3/G4-dominated (faxed pages, OCR scans) | **~5-10%** (expected, untested standalone) | **medium** (expected) | Run-length coding tends to break sync more readily than JPEG2000/JBIG2 but is still not a checksum. |

**Why this is honest, not a defect.** PDF the spec has no per-stream content
hash. A PDF "fully validated" in our sense means: every stream parsed,
every codec accepted the payload, every cross-reference resolves. It does
not mean every byte's integrity is verified — that proof requires an
external mechanism the format does not carry. For codecs without a
checksum, the only ways a flip CAN fail decode are (a) it lands in a
marker/header byte the codec checks, or (b) the resulting bitstream
violates the codec's structural grammar. Most flips in entropy-coded
payload do neither.

**Where this matters.** If your authoritative copy of a PDF gets
silently flipped on disk (cosmic ray, RAID rebuild error, flash bit-rot)
and that flip lands inside a JPEG2000 page-image stream, validate will
report `OK ... PDF Document (fully validated)`. The image will still
render, just with a few visual glitches. This is the codec's design.
For real-world bit-rot protection of opaque-codec PDFs (and any other
format whose spec lacks integrity fields), pair validate with a
sidecar-parity solution like Entropy Shield (https://entropyshield.app),
which carries a dedicated whole-file or per-block hash and can repair
corruption it detects rather than just reporting it.

**Roadmap.** A future architectural refactor will introduce a
`.bounds_verified` validation depth distinct from `.full`, so
`(fully validated)` only appears when every byte is provably checked.
For PDF, the realistic top tier per filter dominance becomes:
`Flate-dominated → .full`, codec-opaque-dominated → `.bounds_verified`.
