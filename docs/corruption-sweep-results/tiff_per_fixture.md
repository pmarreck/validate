# TIFF corruption-sweep — per-fixture breakdown

**Run:** 2026-05-21, validate at commit `95c68195a` (TIFF deep-validation
patch — actually decodes strips + tiles via tiffz).
**Methodology:** for each fixture, `scripts/corruption-experiment`
sniper (1-bit flip × 100 trials) and shotgun (4 KB overwrite ×
100 trials), seed=42.
**Why this exists:** `tiff_sniper.tsv` / `tiff_shotgun.tsv` capture the
canonical "largest TIFF fixture" run on `pc260001.tif` per the
sweep script's logic, but `pc260001.tif` is uncompressed RGB —
near-zero detection isn't a tiffz limitation, it's a TIFF-format
property (no per-strip checksums, uncompressed bytes ARE the format).
This table shows the variation across TIFF flavors where the format
*does* admit codec-level detection.

```
fixture                       sniper%   shotgun%   codec / variant
--------                      -------   --------   ----------------
at3_1m4_01_rgb.tif                  0         57   PackBits RGB
bali.tif                            8        100   BigTIFF + LZW palette
cramps-tile.tif                     0          1   uncompressed tiled
cramps.tif                          0         91   PackBits MinIsWhite
deflate-last-strip.tiff            96        100   Deflate
fax2d.tif                          95        100   CCITT G3 1D
lzw-single-strip.tiff              80        100   LZW (already strong)
minisblack-1c-8b.tiff               0          0   uncompressed grayscale
palette-1c-8b.tiff                  0          9   uncompressed palette
pc260001.tif                        0          0   uncompressed RGB
quad-lzw.tif                      100        100   LZW (NB: failing baseline — strip 24 fails clean-file decode; coverage gap)
quad-tile.tif                       7        100   LZW tiled
rgb-3c-8b.tiff                      0          0   uncompressed RGB
strike.tif                          9        100   pre-multiplied alpha LZW
ycbcr-cat.tif                      11        100   YCbCr (JPEG-in-TIFF)
```

## Patterns

- **Compressed TIFFs** → shotgun detection 57–100%, sniper 7–96%.
  Codec rejects malformed input naturally. Deflate (CRC32 internal)
  + CCITT G3 (line-by-line EOL anchors) lead the pack on sniper.
- **Uncompressed TIFFs** → near-0% in both modes. Pixel bytes are
  the format; there's no codec to fail. Detecting bit-level changes
  here would need an external integrity primitive (sidecar hash,
  filesystem metadata) outside TIFF proper. Validate's
  `PROJECT_OVERVIEW.md` honest-depth note captures this.
- **quad-lzw.tif** shows as 100/100 but it's a *false positive
  baseline* — the clean file also fails strip-decode in tiffz's
  current LZW codec at strip 24 (pre-existing coverage gap;
  routed to WARN via `old_style_lzw_codes` finding routing).
  Real detection rate is undefined until tiffz's LZW handles this
  file's specific variant combo. Tracking on tiffz's side.

## How to regenerate

```bash
# Sniper sweep
scripts/corruption-experiment sniper ground_truth_examples/tiff/<file> \
  --count 100 --seed 42 --output /tmp/<file>.sniper.tsv

# Shotgun sweep
scripts/corruption-experiment shotgun ground_truth_examples/tiff/<file> \
  --count 100 --seed 42 --output /tmp/<file>.shotgun.tsv
```

Or use `scripts/corruption-sweep` for the canonical
"one-largest-file-per-format" runs.
