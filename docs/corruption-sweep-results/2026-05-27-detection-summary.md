# Corruption Detection Sweep — 2026-05-27

Detection rates measured by `scripts/corruption-experiment` against a freshly-built `validate` binary, 100 trials per (format, mode), seed 42.

- **sniper**  — single-bit flip at a random byte offset
- **bolter**  — single byte XOR'd with `0xFF` (flips all 8 bits of one byte)
- **shotgun** — overwrite 4096 consecutive bytes with random data

Confidence intervals are 95% Wilson half-widths. `n/a` means the fixture was too small for that mode (shotgun needs ≥4096 bytes).

## 1. PDF

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `pdf` | `nasa_satellite_images_1976.pdf` | 22300 KB | 28.0% ±8.7 | 28.0% ±8.7 | 72.0% ±8.7 |

## 2. H.264

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `mkv_h264` | `h264_aac.mkv` | 29 KB | 95.0% ±4.5 | 96.0% ±4.1 | 100.0% ±1.8 |
| `mov_h264` | `jellyfish_h264.mov` | 1022 KB | 1.0% ±2.6 | 1.0% ±2.6 | 75.0% ±8.4 |
| `mp4_h264` | `bigbuckbunny_360_10s.mp4` | 967 KB | 0.0% ±1.8 | 0.0% ±1.8 | 39.0% ±9.4 |

## 3. H.265

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `heic` | `sample.heic` | 2924 KB | 0.0% ±1.8 | 0.0% ±1.8 | 4.0% ±4.1 |
| `mkv_h265` | `h265_aac.mkv` | 30 KB | 87.0% ±6.6 | 84.0% ±7.2 | 99.0% ±2.6 |
| `mp4_h265` | `h265_main.mp4` | 13 KB | 2.0% ±3.2 | 3.0% ±3.7 | 95.0% ±4.5 |

## 4. Common images

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `avif` | `butterfly.avif` | 85 KB | 0.0% ±1.8 | 0.0% ±1.8 | 1.0% ±2.6 |
| `bmp` | `sample.bmp` | 900 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `gif` | `animated_sample.gif` | 400 KB | 9.0% ±5.7 | 35.0% ±9.2 | 100.0% ±1.8 |
| `ico` | `sample.ico` | 226 KB | 63.0% ±9.3 | 54.0% ±9.6 | 70.0% ±8.8 |
| `jpeg` | `w3c_exif_420.jpg` | 750 KB | 4.0% ±4.1 | 8.0% ±5.4 | 100.0% ±1.8 |
| `jpeg2k` | `balloon_eciRGB_icc.jp2` | 1820 KB | 6.0% ±4.8 | 5.0% ±4.5 | 97.0% ±3.7 |
| `jxl` | `animation_icos4d.jxl` | 344 KB | 87.0% ±6.6 | 97.0% ±3.7 | 100.0% ±1.8 |
| `png` | `generated_plasma.png` | 336 KB | 100.0% ±1.8 | 100.0% ±1.8 | 100.0% ±1.8 |
| `qoi` | `sample.qoi` | 22 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `tga` | `sample.tga` | 11 KB | 25.0% ±8.4 | 27.0% ±8.6 | 100.0% ±1.8 |
| `tiff` | `pc260001.tif` | 914 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `webp` | `google_gallery_3.webp` | 198 KB | 83.0% ±7.3 | 82.0% ±7.5 | 84.0% ±7.2 |

## 5. Office + iWork

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `doc` | `word95_large.doc` | 589 KB | 2.0% ±3.2 | 2.0% ±3.2 | 2.0% ±3.2 |
| `docx` | `sample.docx` | 13 KB | 87.0% ±6.6 | 82.0% ±7.5 | 100.0% ±1.8 |
| `keynote` | `sample.key` | 64 KB | 99.0% ±2.6 | 100.0% ±1.8 | 100.0% ±1.8 |
| `numbers` | `sample.numbers` | 64 KB | 100.0% ±1.8 | 99.0% ±2.6 | 100.0% ±1.8 |
| `odp` | `sample.odp` | 23 KB | 97.0% ±3.7 | 98.0% ±3.2 | 100.0% ±1.8 |
| `ods` | `sample.ods` | 8 KB | 88.0% ±6.4 | 88.0% ±6.4 | 100.0% ±1.8 |
| `odt` | `sample.odt` | 23 KB | 96.0% ±4.1 | 98.0% ±3.2 | 100.0% ±1.8 |
| `pages` | `sample.pages` | 56 KB | 100.0% ±1.8 | 99.0% ±2.6 | 100.0% ±1.8 |
| `pptx` | `sample.pptx` | 35 KB | 93.0% ±5.2 | 97.0% ±3.7 | 100.0% ±1.8 |
| `xls` | `poi_formula.xls` | 174 KB | 22.0% ±8.0 | 24.0% ±8.3 | 96.0% ±4.1 |
| `xlsx` | `sample.xlsx` | 10 KB | 82.0% ±7.5 | 83.0% ±7.3 | 100.0% ±1.8 |

## 6. Pro + medical

| Format | File | Size | sniper | bolter | shotgun |
|---|---|---:|---:|---:|---:|
| `arw` | `sony_ilce_7s.arw` | 6016 KB | 0.0% ±1.8 | 4.0% ±4.1 | 15.0% ±7.0 |
| `cr2` | `canon_eos_40d_sraw2.cr2` | 5669 KB | 2.0% ±3.2 | 1.0% ±2.6 | 6.0% ±4.8 |
| `cr3` | `sample.CR3` | 15346 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `dicom` | `CT_small.dcm` | 38 KB | 7.0% ±5.2 | 9.0% ±5.7 | 20.0% ±7.8 |
| `dng` | `L1006922_leica_M11.DNG` | 77028 KB | 3.0% ±3.7 | 3.0% ±3.7 | 3.0% ±3.7 |
| `dpx` | `sample.dpx` | 1801 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `exr` | `zip_plasma.exr` | 388 KB | 1.0% ±2.6 | 0.0% ±1.8 | 100.0% ±1.8 |
| `fits` | `sample.fits` | 683 KB | 0.0% ±1.8 | 0.0% ±1.8 | 2.0% ±3.2 |
| `nef` | `nikon_coolscan_iv.nef` | 2150 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `orf` | `PB120976.ORF` | 13657 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |
| `psd` | `rle_plasma.psd` | 1804 KB | 2.0% ±3.2 | 2.0% ±3.2 | 50.0% ±9.6 |
| `raf` | `DSCF0652_fuji_GFX_100.RAF` | 203194 KB | 0.0% ±1.8 | 0.0% ±1.8 | 2.0% ±3.2 |
| `rw2` | `panasonic_16-9.RW2` | 10621 KB | 0.0% ±1.8 | 0.0% ±1.8 | 0.0% ±1.8 |

---

Reproduce: `scripts/corruption-sweep-categories --count 100 --seed 42`
