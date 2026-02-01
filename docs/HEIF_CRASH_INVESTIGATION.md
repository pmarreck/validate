# HEIF Crash Investigation

## Status: ACTIVE

## What We KNOW (with evidence)

### From CI Logs (empirical)
1. **Signal**: SIGABRT (signal 6) - NOT SIGSEGV
2. **Test that crashes**: `FormatValidator deep validates real HEIC from ground truth`
3. **File**: `ground_truth_examples/heic/sample.heic`
4. **Build environment**: Garnix CI, x86_64-linux, Nix build with musl
5. **Stack trace** (from CI logs):
   ```
   heif_decode_image
   -> context.cc:decode_image
   -> image_item.cc:decode_image
   -> grid.cc:decode_full_grid_image
   -> grid.cc:decode_and_paste_tile_image
   -> image_item.cc:decode_image (tile)
   -> decoder.cc:decode_single_frame_from_compressed_data
   -> decode_next_image2 (libde265)
   ```
6. **Crash occurs**: During grid tile decoding, not container parsing

### From Local Testing (empirical)
1. **macOS ARM64** (M-series Mac): Tests PASS
2. **macOS x86_64** (Intel Mac): Unknown - not tested
3. **Linux AMD (Framework laptop)**:
   - Native `zig build test`: PASSES (but this is NOT the same as Nix build)
   - Nix build (`nix build .#checks.x86_64-linux.test`): **NOT TESTED**

### Changes Made (empirical)
1. Disabled SSE in libde265 on Linux - crash persisted
2. Set `num_codec_threads=0` - crash persisted
3. Set `heif_context_set_max_decoding_threads(ctx, 0)` - crash persisted
4. Removed `-UNDEBUG` (disabled our assertion enabling) - crash persisted
5. Added `-DNDEBUG` explicitly - crash persisted

## What We ASSUMED (without evidence)

1. ❌ "Garnix runs on Intel CPUs" - **NEVER VERIFIED**
2. ❌ "It works on AMD Linux" - **Only tested native zig build, NOT Nix/musl build**
3. ❌ "It's Intel-specific" - **Based on assumption #1 and #2**
4. ❌ "It's assertion-related" - **Disproven: crash persists with -DNDEBUG**

## Key Questions to Answer

1. **Does the Nix build crash on Linux AMD?**
   - Test: Run `nix build .#checks.x86_64-linux.test` on Framework laptop
   - This uses the SAME build config as Garnix

2. **What CPU does Garnix actually use?**
   - Check Garnix documentation or logs for hardware info

3. **Is it musl-specific?**
   - The Nix build uses musl libc, native zig build uses glibc
   - This could explain the difference

4. **What causes SIGABRT if not assertions?**
   - glibc/musl malloc detecting heap corruption
   - Explicit abort() calls in code
   - C++ std::terminate (but we use -fno-exceptions)
   - Stack overflow

## Next Steps (in order)

1. [ ] Run `nix build .#checks.x86_64-linux.test --print-build-logs` on Framework laptop
2. [ ] If it crashes there: It's NOT Intel-specific, it's Nix/musl build specific
3. [ ] If it passes there: Need to identify what's different about Garnix environment
4. [ ] Search libde265/libheif source for explicit `abort()` calls
5. [ ] Try building with AddressSanitizer to catch memory errors

## Evidence Log

| Date | Test | Environment | Result | Notes |
|------|------|-------------|--------|-------|
| 2026-02-01 | zig build test | macOS ARM64 | PASS | Native build |
| 2026-02-01 | Garnix CI | x86_64-linux (Nix/musl) | SIGABRT | Grid tile decode |
| 2026-02-01 | ??? | Linux AMD (Nix/musl) | **UNTESTED** | Critical test |
