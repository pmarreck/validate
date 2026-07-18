# TIFF corruption-sweep — per-fixture breakdown

**Latest Bali LZW run:** 2026-07-17 against the signed shared-`lzwz`
ReleaseFast build. It requires EOD and exact decoded strip/tile extent.
**Methodology:** for each fixture, `scripts/corruption-experiment`
sniper (1-bit flip × 100 trials) and shotgun (4 KB overwrite ×
100 trials), seed=42. Detection = validate exits non-zero (FAIL).

```
fixture                       sniper%   shotgun%   codec / variant
--------                      -------   --------   ----------------
at3_1m4_01_rgb.tif                  0         57   PackBits RGB
bali.tif                           63        100   LZW palette (BE, strict EOD + exact extent)
cramps-tile.tif                     0          1   uncompressed tiled
cramps.tif                          0         91   PackBits MinIsWhite
deflate-last-strip.tiff            94         71   Deflate
fax2d.tif                          95        100   CCITT G3 1D
lzw-single-strip.tiff              80        100   LZW single-strip
minisblack-1c-8b.tiff               0          0   uncompressed grayscale
palette-1c-8b.tiff                  0          9   uncompressed palette
pc260001.tif                        0          0   uncompressed RGB
quad-lzw.tif                       10         99   LZW (old-style + KwKwK)
quad-tile.tif                       7        100   LZW tiled
rgb-3c-8b.tiff                      0          0   uncompressed RGB
strike.tif                          9        100   pre-multiplied alpha LZW
ycbcr-cat.tif                      11        100   YCbCr (JPEG-in-TIFF)
```

## Patterns

- **Uncompressed TIFFs** (pc260001 / rgb-3c-8b / minisblack-1c-8b /
  cramps-tile / palette-1c-8b): near-0% by format property. No codec
  to fail; no per-strip checksums in the spec. Honest-depth claim
  is "structural + codec-level", not "byte-level integrity" — see
  `PROJECT_OVERVIEW.md` for the policy.
- **PackBits** (cramps / at3_1m4_01_rgb): shotgun 57-91%, sniper
  near-0%. RLE control bytes are robust to single bit flips but 4
  KB sector wipes break the codec's framing.
- **LZW** (lzw-single-strip / bali / quad-lzw / quad-tile /
  strike): shotgun 99-100%; Bali's sniper rate rose 7% → 63% after
  mandatory EOD and exact decoded-extent checks. A mutation can still form a
  different valid LZW stream because TIFF has no decoded-pixel checksum.
- **Deflate** (deflate-last-strip): 94 / 71. zlib's CRC32 catches
  almost everything — the only misses are when the corruption
  lands inside a region the CRC doesn't cover.
- **CCITT G3** (fax2d): 95 / 100. T.4's EOL markers + line-by-line
  decoding catches most corruption immediately.
- **YCbCr JPEG-in-TIFF** (ycbcr-cat): 11 / 100. JPEG entropy
  coding catches shotgun robustly; sniper success depends on
  whether the flipped bit lands in scan data vs marker / quantization
  table regions.

## Verdict-tier reminder

This sweep counts FAIL exits only. WARN-tier outcomes still represent
real coverage (validate at structural depth), but they don't count
as "corruption detected" by the experiment's exit-code metric. See
`PROJECT_OVERVIEW.md` § "Shim implementer guide" for the routing
policy that determines which decoder errors land in which tier.

## How to regenerate

```bash
scripts/corruption-experiment <mode> ground_truth_examples/tiff/<file> \
  --count 100 --seed 42 --output /tmp/<file>.<mode>.tsv
```
