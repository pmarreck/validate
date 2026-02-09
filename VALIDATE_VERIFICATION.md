# Format Validation Verification Checklist

Systematic verification that each supported format correctly validates good files and rejects corrupted files.

**Methodology:**
- Valid Example: Ground truth file validates successfully
- Corrupt 1-5: File with single null byte at random position is rejected
- Needs Inquiry: Format is resilient to single-byte corruption (e.g., audio samples may tolerate value changes)

## Legend
- [x] Verified passing
- [ ] Not yet tested
- [?] Needs further inquiry (corruption didn't cause rejection)
- [-] No ground truth example available

---

## Images

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| png | Image | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| jpeg | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| jxl | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| gif | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| bmp | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| webp | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| tiff | Image | Structural | [x] | [x] | [x] | [x] | [x] | [x] | |
| heic | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| avif | Image | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| jpeg2000 | Image | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| exr | Image | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| svg | Vector | XML Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| psd | Design | RLE Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| ai | Design | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| eps | Design | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| sketch | Design | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| aep | Design | RIFX | [-] | [-] | [-] | [-] | [-] | [-] | |
| ico | Icon | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |

## RAW Camera Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| dng | RAW | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| cr2 | RAW | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| nef | RAW | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| arw | RAW | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |

## Audio

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| mp3 | Audio | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| flac | Audio | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| wav | Audio | Structural | [x] | [x] | [x] | [x] | [x] | [x] | |
| m4a | Audio | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| alac | Audio | Structural | [x] | [x] | [x] | [x] | [x] | [x] | |
| aiff | Audio | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| ogg | Audio | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| ape | Audio | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| wavpack | Audio | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| midi | Audio | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| dsf | Audio | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| dff | Audio | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| ac3 | Audio | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| eac3 | Audio | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |

## Tracker/Module Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| mod | Tracker | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| xm | Tracker | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| it | Tracker | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| s3m | Tracker | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |

## Video

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| mp4 | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| mov | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| mkv | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| webm | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| avi | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| swf | Video | Decompress | [-] | [-] | [-] | [-] | [-] | [-] | |
| flv | Video | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| prores | Video | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| ogv | Video | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |

## Archives & Compression

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| zip | Archive | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| gzip | Compression | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| bzip2 | Compression | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| xz | Compression | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| zstd | Compression | Decompress | [-] | [-] | [-] | [-] | [-] | [-] | |
| br | Compression | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| rar | Archive | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |
| sevenz | Archive | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| tar | Archive | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| epub | Archive | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| par2 | Parity | Checksum | [x] | [x] | [x] | [x] | [x] | [x] | |

## Office Documents - Modern (OOXML)

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| docx | Document | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| xlsx | Spreadsheet | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| pptx | Presentation | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |

## Office Documents - Legacy (OLE2)

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| doc | Document | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| xls | Spreadsheet | Structural | [x] | [x] | [x] | [x] | [x] | [x] | |
| ppt | Presentation | Structural | [x] | [x] | [x] | [x] | [x] | [x] | |

## OpenDocument Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| odt | Document | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| ods | Spreadsheet | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| odp | Presentation | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |

## Other Documents

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| pdf | Document | Full Decode | [x] | [x] | [x] | [x] | [x] | [x] | |
| rtf | Document | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| pages | Document | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| wpd | Document | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| cwk | Document | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| mwd | Document | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Database Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| sqlite | Database | Integrity | [x] | [x] | [x] | [x] | [x] | [x] | |
| mdb | Database | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| accdb | Database | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## DAW Project Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| als | DAW | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| rpp | DAW | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| logicx | DAW | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| flp | DAW | Full Decode | [-] | [-] | [-] | [-] | [-] | [-] | |
| song | DAW | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |
| bwproject | DAW | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| cpr | DAW | RIFF | [-] | [-] | [-] | [-] | [-] | [-] | |
| ptx | DAW | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| band | DAW | Bundle | [-] | [-] | [-] | [-] | [-] | [-] | |
| reason | DAW | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Video Editing Projects

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| prproj | Video Edit | Gzip XML | [-] | [-] | [-] | [-] | [-] | [-] | |
| fcpxml | Video Edit | XML Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| drp | Video Edit | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |

## CAD & Engineering

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| dwg | CAD | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| dxf | CAD | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| step | CAD | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| stl | 3D Print | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## 3D Modeling

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| blend | 3D Model | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| obj | 3D Model | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| gltf | 3D Model | JSON Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| glb | 3D Model | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| ply | 3D Model | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| @"3mf" | 3D Model | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |

## Disk Images

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| iso | Disk Image | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| dmg | Disk Image | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |

## Scientific & Research Data

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| hdf5 | Scientific | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| parquet | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| netcdf | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| fits | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| matlab | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| nifti | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| fasta | Bioinformatics | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| fastq | Bioinformatics | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| dicom | Medical | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |

## GIS/Geospatial

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| shapefile | GIS | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| kml | GIS | XML Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| kmz | GIS | ZIP CRC | [-] | [-] | [-] | [-] | [-] | [-] | |

## Game Data Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| wad | Game Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| pak | Game Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| bsp | Game Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| vpk | Game Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Game ROM Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| nes | ROM | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| snes | ROM | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| n64 | ROM | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| gb | ROM | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| gba | ROM | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| nds | ROM | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| genesis | ROM | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| chd | ROM | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Font Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| ttf | Font | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| otf | Font | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| woff | Font | Checksum | [-] | [-] | [-] | [-] | [-] | [-] | |
| woff2 | Font | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| type1 | Font | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Text & Data Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| json | Data | Full Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| toml | Data | Full Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| yaml | Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| xml | Data | Tag Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| csv | Data | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |
| plist | Data | Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| ini | Data | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| plain_text | Text | UTF-8 | [-] | [-] | [-] | [-] | [-] | [-] | |
| markdown | Text | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| erlang_term | Data | Parse | [-] | [-] | [-] | [-] | [-] | [-] | |
| eex | Template | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Email Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| eml | Email | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| mbox | Email | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## IFF-Based Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| iff | Container | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| blorb | IF Resource | Integrity | [-] | [-] | [-] | [-] | [-] | [-] | |

## Specialized Formats

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| beam | Bytecode | IFF | [-] | [-] | [-] | [-] | [-] | [-] | |
| pe | Executable | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |
| warc | Web Archive | Structural | [-] | [-] | [-] | [-] | [-] | [-] | |

## Other

| Format | Type | Level | Valid | C1 | C2 | C3 | C4 | C5 | Inquiry |
|--------|------|-------|-------|----|----|----|----|----| --------|
| jbig2 | Image | Embedded | [-] | [-] | [-] | [-] | [-] | [-] | JBIG2 is embedded in PDF, not standalone |

---

## Summary

- **Total Formats**: 125+
- **With Ground Truth**: 116 formats with valid examples
- **With Corruption Tests**: 121 formats with corruption test files
- **Needs Inquiry**: 0
- **Missing Examples**: Game ROMs (NES, SNES, N64, GB, GBA, NDS, Genesis, CHD) — seeking public domain homebrew

### Note on C Library Removal (2026-02-07)

Six C library dependencies were replaced with pure-Zig validators:
- OpenH264 → `h264_syntax_validator.zig` + `h264_cavlc_tables.zig` + `h264_cabac_engine.zig`
- libde265 → `h265_validator.zig`
- dav1d → `av1_obu_validator.zig`
- libvpx → `vp9_syntax_validator.zig`
- libheif → `heif_container_parser.zig` + `heic_validator.zig` + `avif_validator.zig`
- libfdk-aac → `aac_syntax_validator.zig`

All existing ground truth tests continue to pass with the pure-Zig implementations.

---

*Last updated: 2026-02-09*
*Ground truth in ground_truth_examples/, corruption tests via scripts/corruption_test.sh*
