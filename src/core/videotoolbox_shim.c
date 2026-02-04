/**
 * VideoToolbox C Shim with Runtime Dynamic Loading
 *
 * This shim uses dlopen/dlsym to load VideoToolbox at runtime rather than
 * link time. This avoids dyld symbol resolution issues when the module is
 * loaded from worker threads.
 *
 * THREAD SAFETY:
 * - vt_shim_init() must be called from the main thread before any validation
 * - All VideoToolbox calls are dispatched to the main queue via dispatch_sync
 *
 * macOS only - this file is not compiled on other platforms.
 */

#ifdef __APPLE__

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>

// =============================================================================
// Type Definitions (matching Apple's headers, but declared locally)
// =============================================================================

// CoreFoundation types
typedef const void* CFTypeRef;
typedef const void* CFAllocatorRef;
typedef signed long CFIndex;
typedef uint32_t OSStatus;
typedef struct __CFDictionary* CFDictionaryRef;

// CoreMedia types
typedef struct opaqueCMFormatDescription* CMFormatDescriptionRef;
typedef CMFormatDescriptionRef CMVideoFormatDescriptionRef;
typedef struct opaqueCMBlockBuffer* CMBlockBufferRef;
typedef struct opaqueCMSampleBuffer* CMSampleBufferRef;
typedef uint32_t CMBlockBufferFlags;
typedef uint32_t FourCharCode;
typedef FourCharCode CMVideoCodecType;

typedef struct {
    int64_t value;
    int32_t timescale;
    uint32_t flags;
    int64_t epoch;
} CMTime;

typedef struct {
    CMTime start;
    CMTime duration;
} CMTimeRange;

typedef struct {
    uint32_t width;
    uint32_t height;
} CMVideoDimensions;

// CoreVideo types
typedef struct __CVBuffer* CVBufferRef;
typedef CVBufferRef CVImageBufferRef;

// VideoToolbox types
typedef struct OpaqueVTDecompressionSession* VTDecompressionSessionRef;
typedef uint32_t VTDecodeFrameFlags;
typedef uint32_t VTDecodeInfoFlags;

typedef void (*VTDecompressionOutputCallback)(
    void* decompressionOutputRefCon,
    void* sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration
);

typedef struct {
    VTDecompressionOutputCallback decompressionOutputCallback;
    void* decompressionOutputRefCon;
} VTDecompressionOutputCallbackRecord;

// Constants (values from Apple headers)
#define kCMVideoCodecType_H264  0x61766331  // 'avc1'
#define kCMVideoCodecType_HEVC  0x68766331  // 'hvc1'
#define kVTDecodeFrame_EnableAsynchronousDecompression  (1 << 0)
#define noErr 0

// =============================================================================
// Function Pointer Types
// =============================================================================

// CoreFoundation
typedef void (*CFRelease_fn)(CFTypeRef cf);
typedef CFAllocatorRef (*CFAllocatorGetDefault_fn)(void);

// CoreMedia - Format Description
typedef OSStatus (*CMVideoFormatDescriptionCreateFromH264ParameterSets_fn)(
    CFAllocatorRef allocator,
    size_t parameterSetCount,
    const uint8_t* const* parameterSetPointers,
    const size_t* parameterSetSizes,
    int NALUnitHeaderLength,
    CMFormatDescriptionRef* formatDescriptionOut
);

typedef OSStatus (*CMVideoFormatDescriptionCreateFromHEVCParameterSets_fn)(
    CFAllocatorRef allocator,
    size_t parameterSetCount,
    const uint8_t* const* parameterSetPointers,
    const size_t* parameterSetSizes,
    int NALUnitHeaderLength,
    CFDictionaryRef extensions,
    CMFormatDescriptionRef* formatDescriptionOut
);

// CoreMedia - Block Buffer
typedef OSStatus (*CMBlockBufferCreateWithMemoryBlock_fn)(
    CFAllocatorRef structureAllocator,
    void* memoryBlock,
    size_t blockLength,
    CFAllocatorRef blockAllocator,
    void* customBlockSource,
    size_t offsetToData,
    size_t dataLength,
    CMBlockBufferFlags flags,
    CMBlockBufferRef* blockBufferOut
);

// CoreMedia - Sample Buffer
typedef OSStatus (*CMSampleBufferCreate_fn)(
    CFAllocatorRef allocator,
    CMBlockBufferRef dataBuffer,
    bool dataReady,
    void* makeDataReadyCallback,
    void* makeDataReadyRefcon,
    CMFormatDescriptionRef formatDescription,
    CFIndex numSamples,
    CFIndex numSampleTimingEntries,
    void* sampleTimingArray,
    CFIndex numSampleSizeEntries,
    const size_t* sampleSizeArray,
    CMSampleBufferRef* sampleBufferOut
);

// VideoToolbox
typedef OSStatus (*VTDecompressionSessionCreate_fn)(
    CFAllocatorRef allocator,
    CMVideoFormatDescriptionRef videoFormatDescription,
    CFDictionaryRef videoDecoderSpecification,
    CFDictionaryRef destinationImageBufferAttributes,
    const VTDecompressionOutputCallbackRecord* outputCallback,
    VTDecompressionSessionRef* decompressionSessionOut
);

typedef OSStatus (*VTDecompressionSessionDecodeFrame_fn)(
    VTDecompressionSessionRef session,
    CMSampleBufferRef sampleBuffer,
    VTDecodeFrameFlags decodeFlags,
    void* sourceFrameRefCon,
    VTDecodeInfoFlags* infoFlagsOut
);

typedef OSStatus (*VTDecompressionSessionWaitForAsynchronousFrames_fn)(
    VTDecompressionSessionRef session
);

typedef void (*VTDecompressionSessionInvalidate_fn)(
    VTDecompressionSessionRef session
);

// =============================================================================
// Global State
// =============================================================================

static bool g_initialized = false;
static bool g_available = false;
static void* g_cf_handle = NULL;
static void* g_cm_handle = NULL;
static void* g_vt_handle = NULL;

// Function pointers
static CFRelease_fn fp_CFRelease = NULL;
static CMVideoFormatDescriptionCreateFromH264ParameterSets_fn fp_CMVideoFormatDescriptionCreateFromH264ParameterSets = NULL;
static CMVideoFormatDescriptionCreateFromHEVCParameterSets_fn fp_CMVideoFormatDescriptionCreateFromHEVCParameterSets = NULL;
static CMBlockBufferCreateWithMemoryBlock_fn fp_CMBlockBufferCreateWithMemoryBlock = NULL;
static CMSampleBufferCreate_fn fp_CMSampleBufferCreate = NULL;
static VTDecompressionSessionCreate_fn fp_VTDecompressionSessionCreate = NULL;
static VTDecompressionSessionDecodeFrame_fn fp_VTDecompressionSessionDecodeFrame = NULL;
static VTDecompressionSessionWaitForAsynchronousFrames_fn fp_VTDecompressionSessionWaitForAsynchronousFrames = NULL;
static VTDecompressionSessionInvalidate_fn fp_VTDecompressionSessionInvalidate = NULL;

// kCFAllocatorDefault is a global variable, not a function
static CFAllocatorRef g_kCFAllocatorDefault = NULL;
// kCFAllocatorNull - special allocator that doesn't free memory
static CFAllocatorRef g_kCFAllocatorNull = NULL;

// =============================================================================
// Initialization (must be called from main thread)
// =============================================================================

static bool load_symbol(void* handle, const char* name, void** out) {
    *out = dlsym(handle, name);
    if (*out == NULL) {
        fprintf(stderr, "[VT Shim] Failed to load symbol: %s - %s\n", name, dlerror());
        return false;
    }
    return true;
}

bool vt_shim_init(void) {
    if (g_initialized) {
        return g_available;
    }

    // Must be called from main thread
    if (pthread_main_np() == 0) {
        fprintf(stderr, "[VT Shim] vt_shim_init must be called from main thread\n");
        g_initialized = true;
        g_available = false;
        return false;
    }

    // Silent initialization - enable debug output by setting VALIDATE_DEBUG=1
    bool debug = getenv("VALIDATE_DEBUG") != NULL;

    // Load CoreFoundation
    g_cf_handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    if (!g_cf_handle) {
        fprintf(stderr, "[VT Shim] Failed to load CoreFoundation: %s\n", dlerror());
        g_initialized = true;
        g_available = false;
        return false;
    }

    // Load CoreMedia
    g_cm_handle = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY);
    if (!g_cm_handle) {
        fprintf(stderr, "[VT Shim] Failed to load CoreMedia: %s\n", dlerror());
        dlclose(g_cf_handle);
        g_cf_handle = NULL;
        g_initialized = true;
        g_available = false;
        return false;
    }

    // Load VideoToolbox
    g_vt_handle = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_LAZY);
    if (!g_vt_handle) {
        fprintf(stderr, "[VT Shim] Failed to load VideoToolbox: %s\n", dlerror());
        dlclose(g_cm_handle);
        dlclose(g_cf_handle);
        g_cm_handle = NULL;
        g_cf_handle = NULL;
        g_initialized = true;
        g_available = false;
        return false;
    }

    // Load function pointers
    bool ok = true;

    // CoreFoundation
    ok = ok && load_symbol(g_cf_handle, "CFRelease", (void**)&fp_CFRelease);

    // Get kCFAllocatorDefault (it's a global variable)
    CFAllocatorRef* p_kCFAllocatorDefault = dlsym(g_cf_handle, "kCFAllocatorDefault");
    if (p_kCFAllocatorDefault) {
        g_kCFAllocatorDefault = *p_kCFAllocatorDefault;
    } else {
        fprintf(stderr, "[VT Shim] Failed to get kCFAllocatorDefault\n");
        ok = false;
    }

    // Get kCFAllocatorNull (special allocator that doesn't free memory)
    CFAllocatorRef* p_kCFAllocatorNull = dlsym(g_cf_handle, "kCFAllocatorNull");
    if (p_kCFAllocatorNull) {
        g_kCFAllocatorNull = *p_kCFAllocatorNull;
    } else {
        fprintf(stderr, "[VT Shim] Failed to get kCFAllocatorNull\n");
        ok = false;
    }

    // CoreMedia
    ok = ok && load_symbol(g_cm_handle, "CMVideoFormatDescriptionCreateFromH264ParameterSets",
                           (void**)&fp_CMVideoFormatDescriptionCreateFromH264ParameterSets);
    ok = ok && load_symbol(g_cm_handle, "CMVideoFormatDescriptionCreateFromHEVCParameterSets",
                           (void**)&fp_CMVideoFormatDescriptionCreateFromHEVCParameterSets);
    ok = ok && load_symbol(g_cm_handle, "CMBlockBufferCreateWithMemoryBlock",
                           (void**)&fp_CMBlockBufferCreateWithMemoryBlock);
    ok = ok && load_symbol(g_cm_handle, "CMSampleBufferCreate",
                           (void**)&fp_CMSampleBufferCreate);

    // VideoToolbox
    ok = ok && load_symbol(g_vt_handle, "VTDecompressionSessionCreate",
                           (void**)&fp_VTDecompressionSessionCreate);
    ok = ok && load_symbol(g_vt_handle, "VTDecompressionSessionDecodeFrame",
                           (void**)&fp_VTDecompressionSessionDecodeFrame);
    ok = ok && load_symbol(g_vt_handle, "VTDecompressionSessionWaitForAsynchronousFrames",
                           (void**)&fp_VTDecompressionSessionWaitForAsynchronousFrames);
    ok = ok && load_symbol(g_vt_handle, "VTDecompressionSessionInvalidate",
                           (void**)&fp_VTDecompressionSessionInvalidate);

    if (!ok) {
        dlclose(g_vt_handle);
        dlclose(g_cm_handle);
        dlclose(g_cf_handle);
        g_vt_handle = NULL;
        g_cm_handle = NULL;
        g_cf_handle = NULL;
        g_initialized = true;
        g_available = false;
        return false;
    }

    if (debug) {
        fprintf(stderr, "[VT Shim] Successfully loaded VideoToolbox\n");
    }
    g_initialized = true;
    g_available = true;
    return true;
}

// =============================================================================
// Result Structure
// =============================================================================

typedef struct {
    bool valid;
    uint32_t frames_decoded;
    const char* error_message;  // Static string, don't free
} VTShimResult;

// =============================================================================
// Internal Structures
// =============================================================================

// Context for decode callback
typedef struct {
    uint32_t frames_decoded;
    bool decode_error;
    OSStatus last_status;
} DecodeContext;

// Internal validation context for dispatch
typedef struct {
    const uint8_t* codec_private;
    size_t codec_private_size;
    const uint8_t* const* samples;
    const size_t* sample_sizes;
    size_t num_samples;
    VTShimResult result;
    CMVideoCodecType codec_type;
} ValidationContext;

// =============================================================================
// Decode Callback
// =============================================================================

static void decode_callback(
    void* decompressionOutputRefCon,
    void* sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration
) {
    (void)sourceFrameRefCon;
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;

    DecodeContext* ctx = (DecodeContext*)decompressionOutputRefCon;

    if (status != noErr) {
        ctx->decode_error = true;
        ctx->last_status = status;
    } else if (imageBuffer != NULL) {
        ctx->frames_decoded++;
    }
}

// =============================================================================
// Parameter Set Parsing
// =============================================================================

static uint8_t** parse_parameter_sets(
    const uint8_t* codec_private,
    size_t codec_private_size,
    size_t** sizes_out,
    size_t* count_out,
    int* nal_length_size_out,
    bool is_hevc
) {
    if (codec_private_size < 8) return NULL;

    if (is_hevc) {
        // hvcC format
        if (codec_private_size < 23) return NULL;

        *nal_length_size_out = (codec_private[21] & 0x03) + 1;
        uint8_t num_arrays = codec_private[22];

        // Count total parameter sets
        size_t total_sets = 0;
        size_t offset = 23;
        for (int i = 0; i < num_arrays && offset + 3 <= codec_private_size; i++) {
            uint16_t num_nalus = (codec_private[offset + 1] << 8) | codec_private[offset + 2];
            total_sets += num_nalus;
            offset += 3;
            for (int j = 0; j < num_nalus && offset + 2 <= codec_private_size; j++) {
                uint16_t nalu_len = (codec_private[offset] << 8) | codec_private[offset + 1];
                offset += 2 + nalu_len;
            }
        }

        if (total_sets == 0) return NULL;

        uint8_t** sets = malloc(total_sets * sizeof(uint8_t*));
        size_t* sizes = malloc(total_sets * sizeof(size_t));
        if (!sets || !sizes) {
            free(sets);
            free(sizes);
            return NULL;
        }

        // Extract parameter sets
        offset = 23;
        size_t set_idx = 0;
        for (int i = 0; i < num_arrays && offset + 3 <= codec_private_size; i++) {
            uint16_t num_nalus = (codec_private[offset + 1] << 8) | codec_private[offset + 2];
            offset += 3;
            for (int j = 0; j < num_nalus && offset + 2 <= codec_private_size; j++) {
                uint16_t nalu_len = (codec_private[offset] << 8) | codec_private[offset + 1];
                offset += 2;
                if (offset + nalu_len <= codec_private_size) {
                    sets[set_idx] = malloc(nalu_len);
                    if (sets[set_idx]) {
                        memcpy(sets[set_idx], codec_private + offset, nalu_len);
                        sizes[set_idx] = nalu_len;
                        set_idx++;
                    }
                }
                offset += nalu_len;
            }
        }

        *sizes_out = sizes;
        *count_out = set_idx;
        return sets;
    } else {
        // avcC format
        *nal_length_size_out = (codec_private[4] & 0x03) + 1;

        uint8_t num_sps = codec_private[5] & 0x1F;
        size_t offset = 6;

        // Count PPS
        size_t temp_offset = offset;
        for (int i = 0; i < num_sps && temp_offset + 2 <= codec_private_size; i++) {
            uint16_t sps_len = (codec_private[temp_offset] << 8) | codec_private[temp_offset + 1];
            temp_offset += 2 + sps_len;
        }
        uint8_t num_pps = (temp_offset < codec_private_size) ? codec_private[temp_offset] : 0;

        size_t total_sets = num_sps + num_pps;
        if (total_sets == 0) return NULL;

        uint8_t** sets = malloc(total_sets * sizeof(uint8_t*));
        size_t* sizes = malloc(total_sets * sizeof(size_t));
        if (!sets || !sizes) {
            free(sets);
            free(sizes);
            return NULL;
        }

        size_t set_idx = 0;

        // Extract SPS
        for (int i = 0; i < num_sps && offset + 2 <= codec_private_size; i++) {
            uint16_t sps_len = (codec_private[offset] << 8) | codec_private[offset + 1];
            offset += 2;
            if (offset + sps_len <= codec_private_size) {
                sets[set_idx] = malloc(sps_len);
                if (sets[set_idx]) {
                    memcpy(sets[set_idx], codec_private + offset, sps_len);
                    sizes[set_idx] = sps_len;
                    set_idx++;
                }
            }
            offset += sps_len;
        }

        // Extract PPS
        if (offset < codec_private_size) {
            num_pps = codec_private[offset++];
            for (int i = 0; i < num_pps && offset + 2 <= codec_private_size; i++) {
                uint16_t pps_len = (codec_private[offset] << 8) | codec_private[offset + 1];
                offset += 2;
                if (offset + pps_len <= codec_private_size) {
                    sets[set_idx] = malloc(pps_len);
                    if (sets[set_idx]) {
                        memcpy(sets[set_idx], codec_private + offset, pps_len);
                        sizes[set_idx] = pps_len;
                        set_idx++;
                    }
                }
                offset += pps_len;
            }
        }

        *sizes_out = sizes;
        *count_out = set_idx;
        return sets;
    }
}

static void free_parameter_sets(uint8_t** sets, size_t* sizes, size_t count) {
    if (sets) {
        for (size_t i = 0; i < count; i++) {
            free(sets[i]);
        }
        free(sets);
    }
    free(sizes);
}

// =============================================================================
// Core Validation Logic
// =============================================================================

static void do_validate(void* context) {
    ValidationContext* ctx = (ValidationContext*)context;

    if (!g_available) {
        ctx->result.valid = false;
        ctx->result.error_message = "VideoToolbox not initialized";
        ctx->result.frames_decoded = 0;
        return;
    }

    // Parse parameter sets
    size_t* param_sizes = NULL;
    size_t param_count = 0;
    int nal_length_size = 4;
    bool is_hevc = (ctx->codec_type == kCMVideoCodecType_HEVC);

    uint8_t** param_sets = parse_parameter_sets(
        ctx->codec_private, ctx->codec_private_size,
        &param_sizes, &param_count, &nal_length_size, is_hevc
    );

    if (!param_sets || param_count == 0) {
        ctx->result.valid = false;
        ctx->result.error_message = "Failed to parse codec parameters";
        ctx->result.frames_decoded = 0;
        free_parameter_sets(param_sets, param_sizes, param_count);
        return;
    }

    // Create format description
    CMFormatDescriptionRef format_desc = NULL;
    OSStatus status;

    if (is_hevc) {
        status = fp_CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            g_kCFAllocatorDefault,
            param_count,
            (const uint8_t* const*)param_sets,
            param_sizes,
            nal_length_size,
            NULL,
            &format_desc
        );
    } else {
        status = fp_CMVideoFormatDescriptionCreateFromH264ParameterSets(
            g_kCFAllocatorDefault,
            param_count,
            (const uint8_t* const*)param_sets,
            param_sizes,
            nal_length_size,
            &format_desc
        );
    }

    free_parameter_sets(param_sets, param_sizes, param_count);

    if (status != noErr || format_desc == NULL) {
        ctx->result.valid = false;
        ctx->result.error_message = "Failed to create format description";
        ctx->result.frames_decoded = 0;
        return;
    }

    // Create decoder session
    DecodeContext decode_ctx = {0};
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = decode_callback,
        .decompressionOutputRefCon = &decode_ctx
    };

    VTDecompressionSessionRef session = NULL;
    status = fp_VTDecompressionSessionCreate(
        g_kCFAllocatorDefault,
        format_desc,
        NULL,  // videoDecoderSpecification
        NULL,  // destinationImageBufferAttributes
        &callback,
        &session
    );

    if (status != noErr || session == NULL) {
        fp_CFRelease(format_desc);
        ctx->result.valid = false;
        ctx->result.error_message = "Failed to create decoder session";
        ctx->result.frames_decoded = 0;
        return;
    }

    // Decode samples
    for (size_t i = 0; i < ctx->num_samples; i++) {
        const uint8_t* sample_data = ctx->samples[i];
        size_t sample_size = ctx->sample_sizes[i];

        if (sample_size == 0) continue;

        CMBlockBufferRef block_buffer = NULL;
        status = fp_CMBlockBufferCreateWithMemoryBlock(
            g_kCFAllocatorDefault,
            (void*)sample_data,
            sample_size,
            g_kCFAllocatorNull,  // Don't free the data - we manage it
            NULL,
            0,
            sample_size,
            0,
            &block_buffer
        );

        if (status != noErr || block_buffer == NULL) continue;

        CMSampleBufferRef sample_buffer = NULL;
        size_t sample_size_array[1] = {sample_size};
        status = fp_CMSampleBufferCreate(
            g_kCFAllocatorDefault,
            block_buffer,
            true,
            NULL,
            NULL,
            format_desc,
            1,
            0,
            NULL,
            1,
            sample_size_array,
            &sample_buffer
        );

        fp_CFRelease(block_buffer);

        if (status != noErr || sample_buffer == NULL) continue;

        status = fp_VTDecompressionSessionDecodeFrame(
            session,
            sample_buffer,
            kVTDecodeFrame_EnableAsynchronousDecompression,
            NULL,
            NULL
        );

        fp_CFRelease(sample_buffer);

        if (status != noErr) {
            decode_ctx.decode_error = true;
            break;
        }
    }

    // Wait for async frames
    fp_VTDecompressionSessionWaitForAsynchronousFrames(session);

    // Cleanup
    fp_VTDecompressionSessionInvalidate(session);
    fp_CFRelease(session);
    fp_CFRelease(format_desc);

    // Set result
    if (decode_ctx.decode_error && decode_ctx.frames_decoded == 0) {
        ctx->result.valid = false;
        ctx->result.error_message = "Decode failed";
        ctx->result.frames_decoded = 0;
    } else if (decode_ctx.frames_decoded == 0) {
        ctx->result.valid = false;
        ctx->result.error_message = "No frames decoded";
        ctx->result.frames_decoded = 0;
    } else {
        ctx->result.valid = true;
        ctx->result.error_message = NULL;
        ctx->result.frames_decoded = decode_ctx.frames_decoded;
    }
}

// =============================================================================
// Thread Safety Helpers
// =============================================================================

static bool is_main_thread(void) {
    return pthread_main_np() != 0;
}

// =============================================================================
// Public API
// =============================================================================

void vt_shim_validate_h264(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
) {
    if (!g_initialized || !g_available) {
        result->valid = false;
        result->frames_decoded = 0;
        result->error_message = "VideoToolbox not initialized - call vt_shim_init() first";
        return;
    }

    ValidationContext ctx = {
        .codec_private = codec_private,
        .codec_private_size = codec_private_size,
        .samples = samples,
        .sample_sizes = sample_sizes,
        .num_samples = num_samples,
        .codec_type = kCMVideoCodecType_H264,
        .result = {.valid = false, .frames_decoded = 0, .error_message = "Not executed"}
    };

    // Try calling VideoToolbox directly from any thread.
    // The original crash was dyld symbol resolution (fixed with dlopen),
    // not VideoToolbox thread safety. Modern VT should handle this.
    do_validate(&ctx);

    *result = ctx.result;
}

void vt_shim_validate_hevc(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
) {
    if (!g_initialized || !g_available) {
        result->valid = false;
        result->frames_decoded = 0;
        result->error_message = "VideoToolbox not initialized - call vt_shim_init() first";
        return;
    }

    ValidationContext ctx = {
        .codec_private = codec_private,
        .codec_private_size = codec_private_size,
        .samples = samples,
        .sample_sizes = sample_sizes,
        .num_samples = num_samples,
        .codec_type = kCMVideoCodecType_HEVC,
        .result = {.valid = false, .frames_decoded = 0, .error_message = "Not executed"}
    };

    // Try calling VideoToolbox directly from any thread.
    do_validate(&ctx);

    *result = ctx.result;
}

bool vt_shim_is_available(void) {
    return g_available;
}

bool vt_shim_is_initialized(void) {
    return g_initialized;
}

#endif // __APPLE__
