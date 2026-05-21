# TIFF corruption-sweep — per-fixture breakdown

**Latest run:** 2026-05-21 against validate `0d4b6cc74` (post-tiffz
bump to 579f133b + shim refactor to `Decoder.validateAllStripsAndTiles`).
**Methodology:** for each fixture, `scripts/corruption-experiment`
sniper (1-bit flip × 100 trials) and shotgun (4 KB overwrite ×
100 trials), seed=42. Detection = validate exits non-zero.

## Current numbers

```
fixture                       sniper%   shotgun%   codec / variant
--------                      -------   --------   ----------------
at3_1m4_01_rgb.tif                  0         57   PackBits RGB
bali.tif                            0          1   LZW palette (BE)
cramps-tile.tif                     0          1   uncompressed tiled
cramps.tif                          0         91   PackBits MinIsWhite
deflate-last-strip.tiff             3          4   Deflate
fax2d.tif                           5          0   CCITT G3 1D
lzw-single-strip.tiff              80        100   LZW single-strip
minisblack-1c-8b.tiff               0          0   uncompressed grayscale
palette-1c-8b.tiff                  0          9   uncompressed palette
pc260001.tif                        0          0   uncompressed RGB
quad-lzw.tif                        0          0   LZW (old-style + KwKwK-at-boundary)
quad-tile.tif                       0          0   LZW tiled
rgb-3c-8b.tiff                      0          0   uncompressed RGB
strike.tif                          1          0   pre-multiplied alpha LZW
ycbcr-cat.tif                       0          4   YCbCr (JPEG-in-TIFF)
```

## Important: numbers are LOWER than they could be

When I first ran the corruption sweep on 2026-05-21 with an
experimental shim patch that routed `error.Malformed` →
`routeError` (FAIL), compressed-TIFF detection ran 57-100%.
Validate's actual shim (the one shipped) routes `error.Malformed` →
`strip_decode_failed` (WARN at structural depth) so the *file isn't
FAIL'd* — that was a deliberate "be friendly to unsupported variants"
call.

The cost: corruption-experiment counts FAIL exit codes only, so a
WARN-on-codec-failure outcome looks identical to OK from outside.
That's why bali.tif shotgun shows 1% here vs the 100% I measured
with the experimental FAIL routing.

## What's catchable today (per file family)

- **Uncompressed TIFFs** (pc260001 / rgb-3c-8b / minisblack-1c-8b /
  cramps-tile / palette-1c-8b): near 0% by format property — no
  codec to fail, no per-strip checksums in the spec. Honest-depth
  claim is "structural + codec-level", not "byte-level integrity"
  (per validate's `PROJECT_OVERVIEW.md`).
- **PackBits** (cramps / at3_1m4_01_rgb): shotgun 57-91%, sniper
  near-0%. PackBits' RLE control bytes are mostly robust to
  single-bit flips but a 4 KB sector wipe usually breaks the
  control / data alignment enough that the codec emits past the
  expected strip size (the one exception path that still routes
  to FAIL via `error.DestTooSmall` past the 64 MiB cap or similar
  resource boundary).
- **LZW** (lzw-single-strip / bali / quad-lzw / quad-tile /
  strike): lzw-single-strip stays high (80 / 100) because its
  strip data is small enough that codec errors propagate the
  `error.SourceShortRead` / `error.DestTooSmall` path that DOES
  route to FAIL. Other LZW fixtures' codec-rejections hit
  `error.Malformed` → WARN → exit 0 → "not detected" by the
  experiment.
- **Deflate** (deflate-last-strip): 3 / 4. CRC32 inside zlib does
  catch most corruption, but the resulting error is `Malformed`
  which → WARN → exit 0.
- **CCITT G3** (fax2d): 5 / 0. Similar — codec catches the breakage
  but `Malformed` → WARN.

## The categorization decision (what validate may want to revisit)

The shim's current routing in `src/core/tiffz_shim.zig`:

```zig
.OutOfMemory, .LimitExceeded*, .SourceTooShort, .SourceShortRead
    => return routeError(err, format),    // FAIL
.DestTooSmall after cap, .Malformed, .UnsupportedCompression,
    .UnsupportedPhotometric, ... (catch-all)
    => strip_decode_failed = true,         // WARN
```

The catch-all WARN is "safe" — it doesn't FAIL files validate's
own tester is uncertain about. But it also means **real-codec-
rejection corruption** (the thing tiffz's codecs are explicitly
designed to catch) shows up as a soft WARN rather than a hard FAIL.

Possible refinement: split `error.Malformed` into "codec rejected
input" vs "unsupported variant", route the former to FAIL, keep the
latter as WARN. Today they're the same `tiffz.Error.Malformed` —
no signal to distinguish, so the shim has to choose one routing.

Two ways forward:

1. **Validate-side:** flip `error.Malformed` from WARN to FAIL in
   the shim. Catches corruption (shotgun probably 60-100% across
   compressed TIFFs based on my earlier measurements). Risk: a
   file in an LZW / Deflate / etc. variant that tiffz hasn't
   covered yet would FAIL instead of WARN. Today the only known
   case is `strike.tif`'s pre-multiplied-alpha presentation choice
   (a photometric layer issue, not a codec rejection) — strike's
   actual LZW decode succeeds, so it wouldn't be affected.

2. **Tiffz-side:** split `error.Malformed` into
   `error.CodecRejected` and `error.UnsupportedVariant`. Then
   validate's shim can route them differently without ambiguity.
   Bigger surface change (touches the public Error set).

(1) is the smaller move; (2) is the cleaner long-term shape.

## quad-lzw.tif specifically

Goes from WARN-at-structural (pre-2026-05-21, tiffz codec failed
strip 24) to WARN-at-full (post-tiffz `579f133b`, codec decodes
clean; `old_style_lzw_codes` finding still routes to WARN per
existing policy). Corruption detection on this file follows the
LZW pattern above — near-0% in the current shim, would jump to
~70-100% under routing (1).

## How to regenerate

```bash
scripts/corruption-experiment <mode> ground_truth_examples/tiff/<file> \
  --count 100 --seed 42 --output /tmp/<file>.<mode>.tsv
```
