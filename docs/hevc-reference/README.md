# HEVC Spec Reference (ffmpeg copies)

These are unmodified copies of selected files from ffmpeg's HEVC decoder,
included as a SPEC-CORRECT reference implementation for the H.265 CABAC
work in this project. The validate decoder (in `src/core/h265_*`) is being
incrementally aligned with the behaviour shown here.

## Files

| File | ffmpeg path | Purpose |
|---|---|---|
| `ffmpeg-hevc-cabac.c` | `libavcodec/hevc/cabac.c` | CABAC entropy decoding (the gold standard for context derivation) |
| `ffmpeg-hevc-hevcdec.c` | `libavcodec/hevc/hevcdec.c` | High-level HEVC decode (coding_unit, transform_tree, scan_idx derivation) |
| `ffmpeg-hevc-hevcdec.h` | `libavcodec/hevc/hevcdec.h` | Types + constants |
| `ffmpeg-hevc-data.{c,h}` | `libavcodec/hevc/data.{c,h}` | Scan tables, etc. |

## Source

Fetched 2026-05-21 from ffmpeg 8.0.1 via:
```
nix-build '<nixpkgs>' -A ffmpeg.src --no-link
```
which produced `/nix/store/sbyac78hbnsgvmb13ky1k9663v4w7p62-ffmpeg` (subject to GC).

## License

Original files are LGPL-2.1+ — see `LICENSE-ffmpeg-LGPL21.txt`. Validate
itself is not LGPL; these copies are for reference only and not built into
the validate binary.

## Notable references

- sig_coeff_flag context derivation: `ffmpeg-hevc-cabac.c:1220-1295`
  (the `ctx_idx_map` table at line 1226 is the spec table from H.265
  Table 9-19, structured as `4x4 | prev_sig=0 | prev_sig=1 | prev_sig=2 | default`).
- last_significant_coeff_xy_prefix_decode: `ffmpeg-hevc-cabac.c:866-890`
  (confirms spec X-prefix then Y-prefix order before any suffixes).
- cbf_luma / cbf_cb_cr: `ffmpeg-hevc-cabac.c:826-835`
  (cbf_luma uses `!trafo_depth`, cbf_cb/cr uses `trafo_depth`).
- coeff_abs_level_remaining: `ffmpeg-hevc-cabac.c:941-968`.
- scan_idx derivation from intra prediction mode: `ffmpeg-hevc-hevcdec.c:1320-1385`
  (SCAN_VERT for intra modes 6-14, SCAN_HORIZ for 22-30, all only when
  log2_trafo_size < 4 and pred_mode == INTRA).
