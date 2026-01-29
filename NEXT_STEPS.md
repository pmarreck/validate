# Next Steps and Session Summary

## Completed This Session (2026-01-28)

### 1. Ground Truth Examples Expanded (91 formats now covered)

Added valid samples and corrupted variants for:
- **Text formats**: markdown, plain_text, plist, erlang_term, eex
- **Scientific**: fasta, fastq, fits
- **CAD/3D**: stl, dxf, step, ply, glb, 3mf, iff
- **Geographic**: kml, kmz
- **Archives**: warc, mbox
- **Audio**: aiff
- **Other**: eps, svg, eml, ico

All added to `scripts/corruption_test.sh` - run with `bash scripts/corruption_test.sh`

### 2. PDF Image Validation Fix

**Problem**: PDFs with slightly malformed embedded images (like the Warhammer 40k Codex) were failing validation even though they open fine in Preview.app.

**Solution**: Expanded `toleratedPdfImageFailures()` in `src/core/format_validation.zig:911-990` to handle more error types with warnings instead of hard failures.

**New MalformationType values added** (lines 705-722):
- `pdf_dct_truncated` - embedded JPEG is truncated
- `pdf_jpx_decode_failed` - JPEG2000 decode failed
- `pdf_ccitt_decode_failed` - CCITT fax decode failed
- `pdf_flate_decode_failed` - FlateDecode stream corrupted
- `pdf_lzw_decode_failed` - LZW stream corrupted
- `pdf_jbig2_decode_failed` - JBIG2 decode failed (generic)

Each is documented as REPAIRABLE for future repair features.

### 3. Video Validation Depth Label Fix

**Problem**: Videos showing "fully validated" when 0 frames were actually decoded (openh264 couldn't decode them, but VLC plays them fine).

**Solution**: Changed depth to `structural` when `frames_decoded == 0`:
```zig
const depth: ValidationDepth = if (video_result.frames_decoded > 0 and video_result.byte_validated) .full else .structural;
```

Applied to MP4, MKV, and AVI validators (lines ~18336, ~18464, ~18528).

---

## Known Issues / TODO

### High Priority

1. **OBJ format detection** - Currently detected as "Plain Text" instead of "Wavefront OBJ"
   - File: `src/core/format_validation.zig` (detectFormat function)
   - Need to add OBJ-specific detection based on "v ", "vt ", "vn ", "f " lines

2. **glTF format detection** - Currently detected as "JSON" instead of "glTF"
   - File: `src/core/format_validation.zig`
   - Need to check for `"asset"` and `"scene"` or `"scenes"` keys in JSON

3. **DICOM detection priority** - Some DICOM files have TIFF-like preambles (II* at offset 0) causing misdetection
   - DICM signature at offset 128 should take priority
   - File: `src/core/format_validation.zig` (magic byte detection order)

### Medium Priority

4. **More ground truth examples needed** for:
   - Camera RAW: dng, cr2, nef, arw (need real camera files)
   - Disk images: iso, dmg
   - Scientific: hdf5, parquet, netcdf, dicom
   - Game formats: wad, pak, nes, snes, gb, gba
   - DAW projects: als, flp, logicx, etc.

5. **Video decoder limitations** - openh264 can't decode some valid H.264 streams
   - Consider adding ffmpeg/libavcodec as alternative decoder
   - Or document which H.264 profiles are supported

### Low Priority

6. **Repair features** - All the new MalformationType values are documented as REPAIRABLE
   - Future work to actually implement repair for each type

---

## File Locations Reference

- **Format validation**: `src/core/format_validation.zig`
- **PDF image validator**: `src/core/pdf_image_validator.zig`
- **Video validator**: `src/core/video_validator.zig`
- **H.264 validator**: `src/core/h264_validator.zig`
- **Ground truth samples**: `ground_truth_examples/`
- **Corrupted samples**: `ground_truth_examples/corrupted/`
- **Corruption test script**: `scripts/corruption_test.sh`

## Build & Test Commands

```bash
./build                              # Full build with tests
./test                               # Run all tests
bash scripts/corruption_test.sh     # Run corruption detection tests
./zig-out/bin/validate <file>        # Validate a single file
VALIDATE_DEBUG=1 ./zig-out/bin/validate <dir>  # Debug mode (prints START/END for each file)
```
