# OpenH264 Decoder Thread Safety Analysis

**Analysis Date:** 2026-01-29
**OpenH264 Version:** Latest from https://github.com/cisco/openh264 (cloned 2026-01-29)
**Author:** Claude Code Analysis

---

## Executive Summary

The OpenH264 (Cisco) H.264 decoder library is **NOT thread-safe for concurrent use of a single decoder instance** from multiple threads. However, **multiple independent decoder instances can be safely used in parallel from different threads**, as each instance maintains its own isolated state.

The library does provide optional internal multi-threading for parallel slice decoding within a single frame, but this is internal to the decoder and managed through its own synchronization primitives.

### Key Findings

| Category | Risk Level | Summary |
|----------|------------|---------|
| Global/Static Variables | LOW | Only read-only lookup tables; no mutable globals |
| Instance-Level State | HIGH | No external synchronization on decoder instance |
| Internal Threading | MEDIUM | Has race condition bugs on non-Apple platforms |
| Thread-Local Storage | NONE | Not used |
| Multiple Instances | SAFE | Independent instances are thread-safe |

---

## Detailed Analysis

### 1. Global Variables and Static State

**Location:** `codec/decoder/core/src/decoder_data_tables.cpp`, `codec/decoder/core/inc/vlc_decoder.h`

The OpenH264 decoder uses several global constant tables that are **read-only** and therefore thread-safe:

- `g_kuiVlcTable_*` - VLC decoding lookup tables
- `g_kuiAlphaTable`, `g_kiBetaTable`, `g_kiTc0Table` - Deblocking filter tables
- `g_kMaxPos`, `g_kMaxC2`, `g_kBlockCat2CtxOffset*` - CABAC context tables

These are declared as `static const` and initialized at compile time, posing no thread safety risk.

**Assessment:** SAFE - All global state is read-only constant data.

### 2. Decoder Instance State (SWelsDecoderContext)

**Location:** `codec/decoder/core/inc/decoder_context.h` (lines 306-520)

Each decoder instance (`ISVCDecoder`) maintains a large context structure `SWelsDecoderContext` containing:

```cpp
typedef struct TagWelsDecoderContext {
  // Input buffers
  SDataBuffer sRawData;
  SDataBuffer sSavedData;

  // Configuration
  SDecodingParam* pParam;
  uint32_t uiCpuFlag;

  // Picture buffers
  PPicture pDec;
  PPicture pTempDec;
  SRefPic sRefPic;
  PPicBuff pPicBuff;

  // Parameter sets (SPS/PPS)
  SWelsDecoderSpsPpsCTX sSpsPpsCtx;

  // ... many more fields
} SWelsDecoderContext;
```

**Critical Issue:** None of these fields are protected by mutexes for external access. Concurrent calls to `DecodeFrame2()` or `DecodeFrameNoDelay()` on the same decoder instance will cause data races.

**Assessment:** UNSAFE - Each decoder instance must be accessed from only one thread at a time, or protected by external synchronization.

### 3. Decoder Class (CWelsDecoder) Member Variables

**Location:** `codec/decoder/plus/inc/welsDecoderExt.h` (lines 117-141)

The `CWelsDecoder` class contains shared state:

```cpp
class CWelsDecoder : public ISVCDecoder {
private:
  welsCodecTrace* m_pWelsTrace;
  uint32_t m_uiDecodeTimeStamp;
  int32_t m_iThreadCount;
  PPicBuff m_pPicBuff;
  WELS_MUTEX m_csDecoder;           // Internal mutex
  SWelsDecSemphore m_sIsBusy;       // Thread coordination
  SPictInfo m_sPictInfoList[16];    // Picture reordering buffer
  SPictReoderingStatus m_sReoderingStatus;
  // ...
};
```

The `m_csDecoder` mutex exists but is **only used internally** for coordinating the library's own worker threads, not for protecting external API calls.

**Assessment:** UNSAFE for concurrent external API calls on same instance.

### 4. Internal Multi-Threading Implementation

**Location:** `codec/decoder/core/src/wels_decoder_thread.cpp`, `codec/decoder/plus/src/welsDecoderExt.cpp`

OpenH264 supports optional internal multi-threading for slice-parallel decoding. This is enabled via:

```cpp
int32_t threadCount = 2; // or more
decoder->SetOption(DECODER_OPTION_NUM_OF_THREADS, &threadCount);
```

#### 4.1 Race Condition Bug in Semaphore Implementation (Non-Apple Platforms)

**Location:** `codec/decoder/core/src/wels_decoder_thread.cpp` (lines 265-283)

```cpp
void SemRelease (SWelsDecSemphore* s, long* o_pPrevCount) {
  long prevcount;
#ifdef __APPLE__
  pthread_mutex_lock (& (s->m));
  prevcount = s->v;
  if (s->v < s->max)
    s->v += 1;
  pthread_cond_signal (& (s->e));
  pthread_mutex_unlock (& (s->m));
#else
  // BUG: No mutex protection on non-Apple platforms!
  prevcount = s->v;       // RACE: read without lock
  if (s->v < s->max)
    s->v += 1;            // RACE: write without lock
  sem_post (s->e);
#endif
  // ...
}
```

**Issue:** On Linux and other non-Apple POSIX platforms, `SemRelease` reads and writes `s->v` without holding the mutex, while `SemWait` also accesses `s->v` without the mutex. This can cause:
- Lost increments (counter undercount)
- Race between the value check and the semaphore post
- Potential deadlock or livelock in edge cases

**Severity:** MEDIUM - May cause occasional thread coordination issues under heavy multi-threaded decoding load.

#### 4.2 Event Wait Race Condition

**Location:** `codec/decoder/core/src/wels_decoder_thread.cpp` (lines 147-158)

```cpp
void EventReset (SWelsDecEvent* e) {
  pthread_mutex_lock (& (e->m));
  e->isSignaled = 0;
  pthread_mutex_unlock (& (e->m));
}

void EventPost (SWelsDecEvent* e) {
  pthread_mutex_lock (& (e->m));
  pthread_cond_broadcast (& (e->c));
  e->isSignaled = 1;
  pthread_mutex_unlock (& (e->m));
}
```

The event implementation is properly synchronized with mutex protection. No issue here.

### 5. Thread-Local Storage

**Assessment:** OpenH264 does not use any thread-local storage (`__thread`, `thread_local`, or platform TLS APIs). All state is either:
- Global read-only constants
- Per-instance mutable state

### 6. Initialization and Shutdown Safety

**Location:** `codec/decoder/core/src/decoder.cpp`, `codec/decoder/plus/src/welsDecoderExt.cpp`

#### 6.1 WelsCreateDecoder / WelsDestroyDecoder

```cpp
long WelsCreateDecoder (ISVCDecoder** ppDecoder) {
  if (NULL == ppDecoder) {
    return ERR_INVALID_PARAMETERS;
  }
  *ppDecoder = new CWelsDecoder();
  // ...
}

void WelsDestroyDecoder (ISVCDecoder* pDecoder) {
  if (NULL != pDecoder) {
    delete (CWelsDecoder*)pDecoder;
  }
}
```

**Assessment:** These functions are safe when:
- Each decoder pointer is managed by a single thread
- No concurrent calls to decode while destroying

**Risk:** Destroying a decoder while another thread is using it will cause undefined behavior.

#### 6.2 Initialize / Uninitialize

**Location:** `codec/decoder/plus/src/welsDecoderExt.cpp` (lines 260-283)

```cpp
long CWelsDecoder::Initialize (const SDecodingParam* pParam) {
  // ... opens decoder threads, allocates memory
  iRet = InitDecoder (pParam);
}

long CWelsDecoder::Uninitialize() {
  UninitDecoder();
  return ERR_NONE;
}
```

**Assessment:** Must not be called concurrently with decode operations or with each other.

### 7. Picture Buffer Management

**Location:** `codec/decoder/core/src/decoder.cpp` (lines 63-291)

Picture buffers (`PPicBuff`) are managed with reference counting:

```cpp
// In decoder_context.h
typedef struct TagPicture {
  // ...
  int32_t iRefCount;
  // ...
} SPicture;
```

**Issue:** The `iRefCount` field is accessed without atomic operations or mutex protection in some paths, particularly in the picture reordering code (`BufferingReadyPicture`, `ReleaseBufferedReadyPictureReorder`).

**Severity:** LOW when using single-threaded decoding, MEDIUM when using multi-threaded mode.

---

## Specific Code Locations of Concern

### Critical Locations

| File | Line(s) | Issue |
|------|---------|-------|
| `wels_decoder_thread.cpp` | 265-283 | SemRelease race condition on non-Apple |
| `welsDecoderExt.cpp` | 992-1022 | BufferingReadyPicture accesses m_sPictInfoList without external sync |
| `welsDecoderExt.cpp` | 1024-1090 | ReleaseBufferedReadyPictureReorder modifies shared state |
| `decoder_context.h` | 516 | pCsDecoder mutex exists but not used for external API protection |

### Low-Risk Static Variables

| File | Description |
|------|-------------|
| `parse_mb_syn_cabac.cpp:42-48` | Static const CABAC tables |
| `deblocking.cpp:144-194` | Static const deblocking tables |
| `cabac_decoder.cpp:35` | Static const MVD bin position table |

---

## Recommended Mitigations

### For Library Users (Your Application)

1. **One Thread Per Decoder Instance**
   ```cpp
   // SAFE: Each thread has its own decoder
   void decodeThread(const uint8_t* data, int len) {
       ISVCDecoder* decoder = nullptr;
       WelsCreateDecoder(&decoder);
       decoder->Initialize(&params);
       // ... use decoder ...
       decoder->Uninitialize();
       WelsDestroyDecoder(decoder);
   }
   ```

2. **External Mutex for Shared Decoder**
   ```cpp
   // SAFE: Protect shared decoder with mutex
   class ThreadSafeDecoder {
       ISVCDecoder* m_decoder;
       std::mutex m_mutex;
   public:
       DECODING_STATE decode(const uint8_t* data, int len, uint8_t** dst, SBufferInfo* info) {
           std::lock_guard<std::mutex> lock(m_mutex);
           return m_decoder->DecodeFrame2(data, len, dst, info);
       }
   };
   ```

3. **Avoid Internal Multi-Threading if Possible**
   - Set `DECODER_OPTION_NUM_OF_THREADS` to 0 or 1 to disable internal threading
   - Use multiple decoder instances instead for parallelism

### For Upstream Patches

1. **Fix SemRelease Race Condition**

   The non-Apple path in `SemRelease` should use mutex protection:
   ```cpp
   void SemRelease (SWelsDecSemphore* s, long* o_pPrevCount) {
     long prevcount;
     pthread_mutex_lock (& (s->m));  // Add mutex protection
     prevcount = s->v;
     if (s->v < s->max)
       s->v += 1;
   #ifdef __APPLE__
     pthread_cond_signal (& (s->e));
   #else
     sem_post (s->e);
   #endif
     pthread_mutex_unlock (& (s->m));
     // ...
   }
   ```

2. **Document Thread Safety Guarantees**

   The OpenH264 documentation should explicitly state:
   - Single decoder instance is NOT thread-safe
   - Multiple independent instances ARE thread-safe
   - Internal multi-threading is optional and has known issues

---

## Documented Thread Safety Guarantees

### From Official Documentation

The OpenH264 README.md states:
> "Decoder Features: Single thread for all slices"

This confirms the decoder is designed for single-threaded operation by default, though internal multi-threading can be enabled.

### Implicit Guarantees

Based on code analysis:
- **Global state:** Thread-safe (read-only)
- **Per-instance state:** NOT thread-safe (no synchronization)
- **Multiple instances:** Thread-safe (no shared mutable state between instances)

---

## Conclusion

The OpenH264 decoder library can be safely used in multi-threaded applications by following these guidelines:

1. **Create separate decoder instances for each thread** - This is the safest and recommended approach
2. **Use external locking if sharing a decoder** - Wrap all API calls in a mutex
3. **Avoid or be cautious with internal multi-threading** - The `DECODER_OPTION_NUM_OF_THREADS` feature has race conditions on non-Apple platforms

No upstream patches are strictly required for safe usage if the above guidelines are followed. However, the semaphore race condition in `wels_decoder_thread.cpp` should ideally be reported and fixed upstream for users who rely on internal multi-threading.

---

## References

- OpenH264 GitHub Repository: https://github.com/cisco/openh264
- Source files analyzed:
  - `/codec/decoder/plus/src/welsDecoderExt.cpp`
  - `/codec/decoder/plus/inc/welsDecoderExt.h`
  - `/codec/decoder/core/inc/decoder_context.h`
  - `/codec/decoder/core/src/decoder.cpp`
  - `/codec/decoder/core/src/wels_decoder_thread.cpp`
  - `/codec/decoder/core/inc/wels_decoder_thread.h`
  - `/codec/common/src/WelsThreadLib.cpp`
  - `/codec/common/inc/WelsThreadLib.h`
  - `/codec/api/wels/codec_api.h`
