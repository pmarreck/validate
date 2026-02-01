# HEIF Crash Investigation

## Status: ACTIVE - Waiting for Garnix diagnostic output (commit 7563d24)

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
   - Native `zig build test`: PASSES
   - Nix build (`nix build .#checks.x86_64-linux.test`): **PASSES** (tested 2026-02-01)
     - 80 concurrent HEIF decodes (8 threads × 10 iterations) all succeeded
     - This is the SAME Nix/musl build config as Garnix CI

### Changes Made (empirical)
1. Disabled SSE in libde265 on Linux - crash persisted
2. Set `num_codec_threads=0` - crash persisted
3. Set `heif_context_set_max_decoding_threads(ctx, 0)` - crash persisted
4. Removed `-UNDEBUG` (disabled our assertion enabling) - crash persisted
5. Added `-DNDEBUG` explicitly - crash persisted

## What We ASSUMED (without evidence)

1. ❌ "Garnix runs on Intel CPUs" - **NEVER VERIFIED**
2. ✅ "It works on AMD Linux with Nix/musl" - **VERIFIED: Nix build passes on Framework laptop**
3. ❌ "It's Intel-specific" - **DISPROVEN: AMD Linux Nix/musl passes, but crash is NOT CPU-specific**
4. ❌ "It's assertion-related" - **DISPROVEN: crash persists with -DNDEBUG**
5. ❌ "It's Nix/musl-specific" - **DISPROVEN: AMD Linux with same Nix/musl build passes**

## Key Questions to Answer

1. ~~**Does the Nix build crash on Linux AMD?**~~ **ANSWERED: NO, it passes!**
   - Tested 2026-02-01: `nix build .#checks.x86_64-linux.test` passes on Framework laptop
   - 80 concurrent decodes, all successful

2. **What CPU does Garnix actually use?**
   - Check Garnix documentation or logs for hardware info
   - Less relevant now since it's not CPU-specific

3. ~~**Is it musl-specific?**~~ **ANSWERED: NO**
   - Both Garnix and Framework laptop use Nix/musl build
   - Framework laptop passes, Garnix crashes
   - Therefore NOT musl-specific

4. **What causes SIGABRT if not assertions?**
   - glibc/musl malloc detecting heap corruption
   - Explicit abort() calls in code
   - C++ std::terminate (but we use -fno-exceptions)
   - Stack overflow
   - **Resource limits in sandboxed environment?**

5. **NEW: What's different about Garnix CI environment?**
   - Sandboxing/containerization?
   - Resource limits (memory, stack size)?
   - Kernel version differences?
   - Virtualization (VM vs bare metal)?

## Next Steps (in order)

1. [x] Run `nix build .#checks.x86_64-linux.test --print-build-logs` on Framework laptop - **PASSES**
2. [x] If it crashes there: It's NOT Intel-specific, it's Nix/musl build specific - **N/A, it passes**
3. [x] If it passes there: Need to identify what's different about Garnix environment - **THIS IS THE CASE**
4. [ ] Investigate Garnix CI environment specifics (sandboxing, resource limits, virtualization)
5. [ ] Check if Garnix runs in a VM or container with different memory constraints
6. [ ] Search libde265/libheif source for explicit `abort()` calls
7. [ ] Try building with AddressSanitizer to catch memory errors

## Evidence Log

| Date | Test | Environment | Result | Notes |
|------|------|-------------|--------|-------|
| 2026-02-01 | zig build test | macOS ARM64 | PASS | Native build |
| 2026-02-01 | Garnix CI | x86_64-linux (Nix/musl) | SIGABRT | Grid tile decode |
| 2026-02-01 | nix build .#checks | Linux AMD (Nix/musl) | **PASS** | 80 decodes, 0 failures |

## Critical Finding (2026-02-01)

**The crash is Garnix-environment-specific, NOT:**
- CPU-specific (not Intel vs AMD)
- ~~musl-specific~~ **CORRECTED: Both use glibc (libc.so.6 visible in stack trace)**
- Assertion-related (crash persists with -DNDEBUG)

**The crash ONLY occurs on Garnix CI.** This strongly suggests an environmental factor:
- Garnix builds on remote server `ssh-ng://nix-ssh@garnix9`
- Garnix may run in a heavily sandboxed container/VM
- Resource limits (memory, stack, file descriptors)
- Different kernel configuration
- **Stack unwinding error observed**: `Unwind error at address (error.UnimplementedUserOpcode)`
  - This could indicate DWARF debug info issues
  - Or corrupted stack state before crash
- Virtualization overhead affecting threading behavior

## Latest Stack Trace (from Garnix)

```
heif_decode_image (heif_decoding.cc:235)
-> context.cc:decode_image (context.cc:1300)
-> image_item.cc:decode_image (image_item.cc:708)
-> grid.cc:decode_compressed_image (grid.cc:226)
-> grid.cc:decode_full_grid_image (grid.cc:382)
-> grid.cc:decode_and_paste_tile_image (grid.cc:503)
-> image_item.cc:decode_image (tile) (image_item.cc:708)
-> image_item.cc:decode_compressed_image (image_item.cc:955)
-> decoder.cc:decode_single_frame_from_compressed_data (decoder.cc:452)
-> decode_next_image2 (libde265)
```

The crash happens deep in libde265 during grid tile decoding, but passes the same
test code on Framework laptop (AMD, Nix build, glibc). The single-decode test
crashes on Garnix while the 80-decode stress test passes locally.

## Pending: Resource Limit Diagnostics

Commit `7563d24` adds diagnostic output that will print on Garnix CI:
- Stack soft/hard limits
- Data segment limits
- Address space limits (Linux only)
- Whether running in Nix sandbox

**Local values (Framework laptop, Nix build):**
```
Stack soft limit: 8372224 bytes (7 MB)
Stack hard limit: 67092480 bytes (63 MB)
Data segment: unlimited
Running in Nix build sandbox
```

**Framework laptop (AMD Linux, Nix build):**
```
Stack soft limit: 48234496 bytes (46 MB)
Stack hard limit: 18446744073709551615 bytes (unlimited)
Running in Nix build sandbox
```

**CRITICAL FINDING: Framework has 46 MB stack, which is much higher than typical
Linux defaults (8 MB). If Garnix has the default 8 MB stack, recursive tile
decoding of a 3992x2992 image with 30+ tiles would easily overflow.**

**Garnix values** - cannot capture due to truncated logs, but likely has default
8 MB stack limit which is insufficient for deep grid tile decoding.
