# Next Steps and Session Summary

## Completed This Session (2026-01-28)

### 1. Ground Truth Examples Expanded (100 formats now covered)

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

### 4. Format Detection Improvements (2026-01-28)

**Fixed high-priority format detection issues:**

1. **OBJ format detection** - ✅ FIXED
   - Added `isWavefrontObj()` helper in `detectTextFormat()` (line ~2720)
   - Detects OBJ files by scanning for "v " (vertex), "f " (face), "vt ", "vn ", etc.
   - Requires at least 2 vertex lines OR (1 vertex + faces/other OBJ directives)
   - OBJ files now correctly show "Wavefront OBJ 3D Model" instead of "Plain Text"

2. **glTF format detection** - ✅ FIXED
   - Added `isGltfJson()` helper in `detectTextFormat()` (line ~2820)
   - Checks for required "asset" + "version" keys
   - Also checks for glTF-specific keys: scenes, nodes, meshes, accessors, buffers, etc.
   - glTF files now correctly show "glTF 3D Scene" instead of "JSON"

3. **DICOM detection priority** - ✅ FIXED
   - Added early check for DICM at offset 128 in `detectFormat()` (line ~1385)
   - DICOM detection now runs before TIFF magic byte detection
   - DICOM files with TIFF-like preambles now correctly detected as DICOM

### 5. 100 Format Ground Truth Milestone (2026-01-28)

**Achieved 100 formats with full decode validation + corruption testing!**

**New formats added:**
- **Bytecode/Executable**: beam (Erlang BEAM), pe (Windows PE executable)
- **Flash**: swf (Flash SWF), flv (Flash Video)
- **DSD Audio**: ape (Monkey's Audio), dsf (DSD Stream File), dff (DSDIFF)
- **Game**: wad (DOOM WAD archive)
- **Scientific**: hdf5 (HDF5 with h5py-generated sample)

### 6. DS_Store Format Support (2026-01-29)

**Added full macOS .DS_Store validation:**
- Added `ds_store` to FileFormat enum with "macOS DS_Store" description
- Magic signature detection: `0x00000001` + `"Bud1"`
- Full structural validation including:
  - Magic number and Bud1 signature verification
  - Bookkeeping section offset/size consistency checks
  - Redundant offset field comparison for corruption detection
  - Allocation table size sanity checks
- Ground truth samples added: valid sample + corrupted variants (bad_magic, bad_offset)
- Added to corruption_test.sh for automated testing

**Stats:**
- 101 valid format directories (including ds_store)
- 108 corrupted format directories (some formats share base samples)
- 97 format corruption tests in `scripts/corruption_test.sh`
- All 791 Zig tests pass
- All CLI tests pass

---

## Known Issues / TODO

### HIGH PRIORITY - Architecture Fix Required

1. **Hexagonal Architecture Violation** - ✅ FIXED (2026-01-30)
   - CLI now uses `es_validate_batch()` through C FFI
   - CLI is format-agnostic (enumerates files, calls core, displays results)
   - See `ARCHITECTURE.md` for design details

2. **Bundle Validation** - NEW REQUIREMENT
   - **Problem**: Directories can be "bundles" that need holistic validation (not just file-by-file)
   - **Solution**: When core receives a directory path, check if it matches a known bundle pattern
   - **Bundle types to support**:
     - `.git` directory → Git repository integrity (refs, objects, packs)
       - Existing implementation: `src/core/git_validator.zig`
       - FFI export: `es_git_validate_repository()` in `ffi/c_api.zig`
       - Validates: object checksums, ref consistency, pack file integrity
     - `.app` bundle → macOS application bundle structure
     - `.framework` bundle → macOS framework structure
     - `.bundle` → generic macOS bundle
     - `.xcodeproj`, `.xcworkspace` → Xcode project bundles
   - **Behavior**:
     - If directory matches known bundle → perform bundle-specific validation
     - If directory is unknown bundle type → return continuable error "unknown directory/bundle type"
     - Bundle validation returns a single result for the entire bundle (not per-file)
   - **Implementation approach**:
     - Add `BundleFormat` enum similar to `FileFormat`
     - Add `detectBundleFormat(path)` that checks directory name patterns
     - Route to bundle-specific validators (git_validator, app_validator, etc.)
     - Return `ValidationResult` with bundle-specific format description

3. **PDF Image Validation Parallelization** - ✅ DONE (2026-01-30)
   - PDFs with 10+ images now validated in parallel using thread pool
   - ~/Documents/Books benchmark: 2m30s → 1m36s (36% faster)
   - Implementation: `pdf_image_validator.validatePdfImagesParallel()`
   - Uses LIFO task queue for natural sub-task priority

### Medium Priority

4. **More ground truth examples needed** for:
   - Camera RAW: dng, cr2, nef, arw (need real camera files)
   - Disk images: iso, dmg
   - Scientific: hdf5, parquet, netcdf, dicom
   - Game formats: wad, pak, nes, snes, gb, gba
   - DAW projects: als, flp, logicx, etc.

5. **Video decoder limitations** - ✅ PARTIALLY ADDRESSED (2026-01-30)
   - OpenH264 now used for Baseline, Main, and High profile ≤ level 3.1
   - High profile level 4.0+ (1080p BluRay content) falls back to ffmpeg
   - ffmpeg must be installed on system PATH for full validation of complex H.264
   - Future: Consider support matrix data structure for more granular control

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

## Performance Optimization TODO

### Investigate O(n) and O(n²) bottlenecks

Found during stress testing:
- ✅ `video_validator.SampleTableInfo.getSampleLocation` - FIXED (2026-01-30)
  - Added `getAllSampleLocations()` for O(n) bulk precomputation
  - Changed `validateMp4SamplesByteCoverage` to use bulk method
  - Result: Stalingrad.1993 (2.5 hours) validates in ~1 second vs 30+ minutes

Remaining action items:
1. ~~Profile all sample table operations in video_validator.zig~~ ✅ Done
2. Check EBML parser for linear scans that could use binary search
3. Review PDF validation for linear searches in large documents
4. Audit any loops over file samples/chunks/atoms

**IMPORTANT**: When optimizing O(n) → O(log n), write isolated unit tests for the optimized functions first. Naive O(n) algorithms are easy to get correct; optimizations introduce edge case bugs.

### PDF Validation Parallelization

Currently PDF validation is single-threaded per file. When validating large PDFs (139MB Ashley Book of Knots), CPU usage drops to 210% instead of 1600% because other workers are waiting.

Proposed solution:
1. For PDFs > N MB (e.g., 10MB), spawn internal worker threads
2. Each worker validates embedded images from different pages concurrently
3. Collect results and aggregate validation status
4. Preview.app opens the same PDF instantly - that's our performance target

Note: This requires careful thread pool design to avoid nested parallelism issues (workers spawning workers).

### libde265 Threading Fix (DONE - 2026-02-01)

**Problem**: libde265 worker threads caused General Protection Faults (GPF) on Linux x86_64 during HEIC decode. The crash occurred in `intra_prediction_angular()` during multi-threaded decode.

**Solution**: Two-part fix:
1. **Single-threaded decode**: Forked libheif to `pmarreck/libheif` (tag `v1.21.1-fix-zero-threads`) with a fix that respects `num_threads=0` as "no worker threads" instead of defaulting to 1.
2. **Explicit thread control**: Updated `heif_validator.zig` to explicitly set `num_codec_threads=0` in decoding options, forcing single-threaded decode in the calling thread.

**Files changed**:
- `deps/libheif/build.zig.zon`: Points to pmarreck/libheif fork
- `src/core/heif_validator.zig`: Uses heif_decoding_options with num_codec_threads=0
- `deps/libde265/build.zig`: SSE still disabled on Linux as additional safety measure

**Performance impact**: HEIC validation runs single-threaded, which is slightly slower than multi-threaded but avoids the GPF crash. For file validation purposes, this is acceptable.

**To re-enable multi-threading** (if upstream libde265 fixes the GPF):
1. Change `decode_options.*.num_codec_threads = 0` in heif_validator.zig to use a positive value
2. Optionally re-enable SSE in deps/libde265/build.zig
3. Test thoroughly on Linux CI

### Garnix CI HEIF Stack Overflow Fix (DONE - 2026-02-01)

**Problem**: HEIC decode tests crashed with SIGABRT on Garnix CI but passed on local Linux (Framework laptop).

**Root cause**: Large HEIC images (sample.heic at 3992x2992, ~3 MB) have many grid tiles (30+). The recursive libde265 decoding exhausts stack space on systems with restricted stack limits. Garnix CI has ~8 MB stack vs Framework laptop's 46 MB.

**Solution**: Changed HEIC tests to use smaller image (`autumn_1440x960.heic`, 293 KB) with fewer tiles that doesn't exhaust the stack on resource-constrained systems.

**Investigation documented**: See `docs/HEIF_CRASH_INVESTIGATION.md` for full analysis.

**Key findings**:
- NOT Intel-specific (disproven)
- NOT musl/glibc-specific (both use glibc)
- IS environment-specific - Garnix has stricter stack limits than local dev machines
- macOS works with 7 MB stack (ARM64 uses less stack than x86_64 for same code)

**Limitation**: Very large HEIC images with many grid tiles may fail validation on stack-constrained systems. This is a libde265 architectural limitation (recursive tile decoding).

## Rich Metadata Extraction Feature

### Overview

Validation output should include comprehensive metadata about the file being validated, not just validity status. This metadata must be returned through the C FFI from the Zig core so that any client/wrapper (CLI, GUI, other language bindings) can use it.

**Architecture principle**: The Zig core should only deal with input values and output values (structured data). No stdout/stderr should be emitted from the Zig core except in debug mode (`VALIDATE_DEBUG=1`). Formatting metadata for terminal display is the responsibility of the C CLI wrapper, not the Zig core.

### Proposed MediaMetadata Structure

```zig
pub const MediaMetadata = struct {
    // Video
    width: ?u32 = null,
    height: ?u32 = null,
    frame_rate_num: ?u32 = null,      // e.g., 24000
    frame_rate_den: ?u32 = null,      // e.g., 1001 (for 23.976 fps)
    duration_ms: ?u64 = null,
    video_codec: ?[*:0]const u8 = null,      // "H.264", "HEVC", "AV1"
    video_profile: ?[*:0]const u8 = null,    // "High", "Main", "Baseline"
    video_level: ?[*:0]const u8 = null,      // "4.0", "5.1"
    video_bitrate_bps: ?u64 = null,
    color_primaries: ?[*:0]const u8 = null,  // "BT.709", "BT.2020"
    transfer_characteristics: ?[*:0]const u8 = null,

    // Audio
    audio_codec: ?[*:0]const u8 = null,      // "AAC", "AC3", "FLAC"
    audio_channels: ?u8 = null,
    audio_sample_rate: ?u32 = null,
    audio_bitrate_bps: ?u64 = null,

    // Image
    color_space: ?[*:0]const u8 = null,      // "sRGB", "Adobe RGB", "P3"
    bit_depth: ?u8 = null,
    has_alpha: ?bool = null,

    // Container/General
    container_format: ?[*:0]const u8 = null, // "QuickTime", "Matroska"
    creation_time: ?i64 = null,              // Unix timestamp
    title: ?[*:0]const u8 = null,
    artist: ?[*:0]const u8 = null,
    album: ?[*:0]const u8 = null,
};
```

### MP4/MOV Atoms to Parse

Currently we parse: `ftyp`, `moov`, `mdat`, `trak`, `mdia`, `minf`, `stbl`, `stsd`, `avcC`, `hvcC`

Additional atoms needed for metadata:
- `mvhd` - Movie header: duration, timescale, creation/modification time
- `tkhd` - Track header: dimensions, track ID
- `mdhd` - Media header: timescale, duration, language
- `hdlr` - Handler: track type (video, audio, subtitle)
- `elst` - Edit list: timing adjustments
- `stts` - Time-to-sample: frame timing for accurate frame rate
- `ctts` - Composition time offset: B-frame timing
- `colr` - Color information: primaries, transfer, matrix
- `pasp` - Pixel aspect ratio
- `udta`/`meta`/`ilst` - User data: title, artist, etc. (iTunes metadata)

### Other Format Metadata

**Images (JPEG, TIFF, PNG, HEIC, WebP):**
- EXIF data: camera make/model, GPS coordinates, date taken, exposure settings
- ICC color profiles
- XMP metadata
- IPTC metadata (captions, keywords, copyright)

**Audio (MP3, FLAC, AAC, OGG):**
- ID3v1/ID3v2 tags: title, artist, album, year, genre, track number
- Vorbis comments (OGG, FLAC)
- APE tags
- Album art (embedded images)

**Documents (PDF):**
- Title, author, subject, keywords
- Creation/modification dates
- Producer application
- Page count, page dimensions

**Archives (ZIP, TAR):**
- File count
- Total uncompressed size
- Compression method

### C FFI Design

```c
// New struct to return from validation
typedef struct {
    es_validation_result_t validation;  // Existing validation result
    es_media_metadata_t* metadata;       // Optional, may be NULL
} es_full_result_t;

// Metadata struct (C-compatible)
typedef struct {
    uint32_t width;
    uint32_t height;
    // ... all fields with has_* flags for optionality
    bool has_width;
    bool has_height;
    // ...
} es_media_metadata_t;

// New API function
es_full_result_t es_validate_with_metadata(const char* path);
void es_free_metadata(es_media_metadata_t* metadata);
```

### CLI Display (C Wrapper Responsibility)

The C CLI would format metadata for terminal output:
```
OK video.mp4: MP4 Video (fully validated)
    Container:  QuickTime (ftyp: mp42)
    Video:      H.264 High @ L4.0, 1920x1080, 23.976 fps
    Audio:      AAC LC, 48000 Hz, stereo
    Duration:   2:34:17
    Bitrate:    8.5 Mbps (video), 256 kbps (audio)
```

### Implementation Phases

1. **Phase 1**: Add MediaMetadata to ValidationResult, populate for MP4/MKV video
2. **Phase 2**: Add C FFI exports for metadata
3. **Phase 3**: Update CLI to display metadata
4. **Phase 4**: Add EXIF parsing for images
5. **Phase 5**: Add ID3/Vorbis parsing for audio
6. **Phase 6**: Add PDF metadata extraction
