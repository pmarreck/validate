# Thread Safety Analysis: Xiph.org Audio Libraries

**Libraries Analyzed:**
- libogg v1.3.5
- libvorbis v1.3.7
- libopus v1.5.2

**Analysis Date:** January 2026

---

## Executive Summary

| Library | Thread Safety Status | Critical Issues |
|---------|---------------------|-----------------|
| libogg | **Safe** (with caveats) | None - stateless design with const lookup tables |
| libvorbis | **Safe** (with caveats) | None in release builds; serialized instance access required |
| libopus | **Conditionally Safe** | NONTHREADSAFE_PSEUDOSTACK build option creates global state |

### Key Findings

1. **All three libraries follow a similar pattern:** separate codec state instances can be used concurrently from different threads, but a single instance must not be accessed from multiple threads simultaneously.

2. **No library provides internal synchronization** - all locking must be performed by the caller.

3. **libogg and libvorbis** have no significant thread safety issues in release builds.

4. **libopus** has a critical build-time configuration that can make it non-thread-safe (`NONTHREADSAFE_PSEUDOSTACK`).

---

## libogg v1.3.5

### Thread Safety Assessment: SAFE

libogg is a container format library with a stateless, thread-safe design.

### Global/Static State Analysis

| Location | Type | Thread-Safe? | Notes |
|----------|------|--------------|-------|
| `src/bitwise.c:27-37` | `static const unsigned long mask[]` | Yes | Read-only lookup table |
| `src/bitwise.c:36-37` | `static const unsigned int mask8B[]` | Yes | Read-only lookup table |
| `src/crctable.h:15` | `static const ogg_uint32_t crc_lookup[8][256]` | Yes | Read-only CRC table |

### Key Structures

All state is contained within user-provided structures:

- `ogg_sync_state` - Stream synchronization state
- `ogg_stream_state` - Logical bitstream state
- `oggpack_buffer` - Bit packing buffer

### Thread Safety Guarantees

1. **Multiple streams in parallel:** Different `ogg_stream_state` instances can be processed concurrently.

2. **No global mutable state:** All mutable state is confined to the caller-provided structures.

3. **No initialization required:** The library has no global initialization/shutdown routines.

### Usage Pattern

```c
// Thread 1                          // Thread 2
ogg_stream_state os1;                ogg_stream_state os2;
ogg_stream_init(&os1, serialno1);    ogg_stream_init(&os2, serialno2);
// ... use os1 ...                   // ... use os2 ...
ogg_stream_clear(&os1);              ogg_stream_clear(&os2);
```

### Recommendations

- **No changes required** - libogg is inherently thread-safe when each thread uses its own state structures.

---

## libvorbis v1.3.7

### Thread Safety Assessment: SAFE (with documented constraints)

libvorbis provides explicit thread safety documentation and follows a safe design pattern.

### Official Thread Safety Documentation

From `doc/vorbisfile/threads.html`:

> Vorbisfile's libvorbisfile may be used safely in a threading environment so long as thread access to individual OggVorbis_File instances is serialized.

**Rules:**
1. Only one thread at a time may call functions using a given `OggVorbis_File` instance
2. Multiple threads may enter libvorbisfile concurrently with different instances
3. A single instance may be used from multiple threads if access is serialized

### Global/Static State Analysis

| Location | Type | Thread-Safe? | Notes |
|----------|------|--------------|-------|
| `lib/registry.c:31-44` | `const vorbis_func_*` arrays | Yes | Read-only function tables |
| `lib/envelope.c:211-212` | `static int seq`, `static ogg_int64_t totalshift` | Yes | Inside `#if 0` block - disabled |
| `lib/mapping0.c:158-159` | `static long seq`, `static ogg_int64_t total` | Yes | Inside `#if 0` block - disabled |
| `lib/psy.c:721` | `static int seq` | Yes | Inside `#if 0` block - disabled |

### Debug Build Warning

**File:** `lib/misc.c`

When compiled with debugging memory tracking enabled, libvorbis uses a pthread mutex to protect global debug state:

```c
static pthread_mutex_t memlock=PTHREAD_MUTEX_INITIALIZER;
static void **pointers=NULL;
static long *insertlist=NULL;
// ... other debug tracking state ...
```

This is only compiled when debugging macros are defined and does not affect release builds.

### Key Structures

- `vorbis_info` - Codec configuration
- `vorbis_comment` - File metadata
- `vorbis_dsp_state` - Encoder/decoder state
- `vorbis_block` - Processing block
- `OggVorbis_File` - High-level file interface

### Recommendations

1. **Serialize access to individual instances** - Use mutexes or other synchronization when sharing a single `OggVorbis_File` between threads.

2. **Prefer separate instances** - For parallel decoding, create separate decoder instances rather than sharing.

3. **Call initialization in main thread** - As documented, call `ov_open_callbacks()` in the decode/playback thread rather than the main control thread.

---

## libopus v1.5.2

### Thread Safety Assessment: CONDITIONALLY SAFE

libopus is thread-safe **only when compiled with appropriate options**.

### Critical Build Configuration

**Location:** `celt/stack_alloc.h:38-40`

```c
#if (!defined (VAR_ARRAYS) && !defined (USE_ALLOCA) && !defined (NONTHREADSAFE_PSEUDOSTACK))
#error "Opus requires one of VAR_ARRAYS, USE_ALLOCA, or NONTHREADSAFE_PSEUDOSTACK be defined..."
#endif
```

#### Temporary Allocation Modes

| Mode | Thread-Safe? | Description |
|------|--------------|-------------|
| `VAR_ARRAYS` | **Yes** | Uses C99 variable-length arrays (VLAs) |
| `USE_ALLOCA` | **Yes** | Uses `alloca()` for stack allocation |
| `NONTHREADSAFE_PSEUDOSTACK` | **NO** | Uses global scratch buffer |

### NONTHREADSAFE_PSEUDOSTACK Details

**Location:** `celt/stack_alloc.h:118-124`

When this mode is enabled, the library uses global variables for temporary memory:

```c
#ifdef CELT_C
char *scratch_ptr=0;
char *global_stack=0;
#else
extern char *global_stack;
extern char *scratch_ptr;
#endif
```

**Impact:** Multiple concurrent codec operations will corrupt this shared memory, causing undefined behavior and potential crashes.

### Official Documentation

**File:** `include/opus.h:386-390`

```
A single codec state may only be accessed from a single thread at
a time and any required locking must be performed by the caller. Separate
streams must be decoded with separate decoder states and can be decoded
in parallel unless the library was compiled with NONTHREADSAFE_PSEUDOSTACK
defined.
```

### Global/Static State Analysis

| Location | Type | Thread-Safe? | Notes |
|----------|------|--------------|-------|
| `celt/static_modes_float.h:885-888` | `static const CELTMode * const static_mode_list[]` | Yes | Read-only mode table |
| `silk/ana_filt_bank_1.c:35-36` | `static opus_int16 A_fb1_20, A_fb1_21` | Yes | Read-only coefficients (missing `const`) |
| `celt/rate.c:42` | `static const unsigned char LOG2_FRAC_TABLE[]` | Yes | Read-only lookup table |
| `celt/cwrs.c:211-421` | Various `static const` tables | Yes | Read-only tables |
| `celt/quant_bands.c:63-140` | Various `static const` coefficients | Yes | Read-only data |

### Key Structures

- `OpusEncoder` - Encoder state (position independent, copyable)
- `OpusDecoder` - Decoder state (position independent, copyable)
- `OpusDREDDecoder` - DRED decoder state
- `OpusDRED` - DRED packet state

### Build Verification

To verify thread-safe build:

**CMake:**
```cmake
# Ensure these are NOT set:
# OPUS_NONTHREADSAFE_PSEUDOSTACK
# Check that one of these IS set:
# OPUS_VAR_ARRAYS or OPUS_USE_ALLOCA
```

**Autoconf:**
```bash
./configure
# Check config.h for VAR_ARRAYS or USE_ALLOCA
grep -E "VAR_ARRAYS|USE_ALLOCA|NONTHREADSAFE" config.h
```

### Recommendations

1. **Verify build configuration** - Ensure `NONTHREADSAFE_PSEUDOSTACK` is NOT defined.

2. **Use separate instances** - Create separate `OpusEncoder`/`OpusDecoder` instances for each thread.

3. **Serialize single-instance access** - If sharing an instance, use external locking.

4. **Check prebuilt libraries** - When using system or third-party Opus builds, verify they were compiled with thread-safe options.

---

## Code Locations Reference

### libogg

| File | Line | Description |
|------|------|-------------|
| `src/bitwise.c` | 27-37 | Static const lookup tables |
| `src/crctable.h` | 15 | CRC lookup table |
| `src/framing.c` | 133-179 | Stream state init/destroy |

### libvorbis

| File | Line | Description |
|------|------|-------------|
| `lib/registry.c` | 31-44 | Function pointer tables |
| `lib/misc.c` | 23 | Debug mutex (debug builds only) |
| `doc/vorbisfile/threads.html` | - | Official thread safety docs |

### libopus

| File | Line | Description |
|------|------|-------------|
| `celt/stack_alloc.h` | 38-40 | Build configuration check |
| `celt/stack_alloc.h` | 118-124 | Global pseudostack variables |
| `include/opus.h` | 386-390 | Thread safety documentation |
| `silk/ana_filt_bank_1.c` | 35-36 | Non-const static (read-only) |

---

## Mitigation Strategies

### For Application Developers

1. **Instance-per-thread pattern:**
   ```c
   // Each worker thread creates its own decoder
   void* decode_thread(void* arg) {
       int error;
       OpusDecoder *decoder = opus_decoder_create(48000, 2, &error);
       // ... decode using this instance ...
       opus_decoder_destroy(decoder);
       return NULL;
   }
   ```

2. **Mutex-protected shared instance:**
   ```c
   pthread_mutex_t decoder_mutex = PTHREAD_MUTEX_INITIALIZER;
   OpusDecoder *shared_decoder;

   int decode_frame(const unsigned char *data, int len, opus_int16 *pcm) {
       pthread_mutex_lock(&decoder_mutex);
       int samples = opus_decode(shared_decoder, data, len, pcm, MAX_FRAME, 0);
       pthread_mutex_unlock(&decoder_mutex);
       return samples;
   }
   ```

### For Build System Integration

1. **Verify Opus build options:**
   ```bash
   # Check for thread-safe build
   strings libopus.a | grep -i "nonthreadsafe" && echo "WARNING: Non-thread-safe build"
   ```

2. **CMake verification:**
   ```cmake
   if(OPUS_NONTHREADSAFE_PSEUDOSTACK)
       message(FATAL_ERROR "Thread-unsafe Opus build detected")
   endif()
   ```

---

## Upstream Patch Considerations

### No patches required for:
- libogg
- libvorbis

### Potential improvements for libopus:

1. **Add runtime check for thread safety:**
   ```c
   int opus_is_threadsafe(void) {
   #ifdef NONTHREADSAFE_PSEUDOSTACK
       return 0;
   #else
       return 1;
   #endif
   }
   ```

2. **Mark read-only statics as const:**
   - `silk/ana_filt_bank_1.c:35-36` - Add `const` qualifier to `A_fb1_20` and `A_fb1_21`

---

## Conclusion

All three Xiph.org audio libraries can be used safely in multi-threaded applications when:

1. Each thread uses its own codec state instances, OR
2. Access to shared instances is serialized with external locking

The primary concern is **libopus with NONTHREADSAFE_PSEUDOSTACK** - this build configuration should be avoided in any multi-threaded application. Standard builds using VLAs or alloca are thread-safe.
