/**
 * VideoToolbox C Shim for Thread-Safe Video Validation
 *
 * This shim exists because Zig's extern declarations for macOS frameworks
 * cause dyld symbol resolution at module load time, leading to crashes.
 * By keeping all VideoToolbox code in C, we get predictable symbol resolution
 * and can use GCD's dispatch_sync for thread safety.
 *
 * THREAD SAFETY:
 * All VideoToolbox calls are dispatched to the main queue via dispatch_sync.
 * This ensures the framework's thread requirements are met regardless of
 * which thread calls these functions.
 *
 * macOS only - this file is not compiled on other platforms.
 */

#ifdef __APPLE__

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <pthread.h>

#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

// Result structure passed back to Zig
typedef struct {
    bool valid;
    uint32_t frames_decoded;
    const char* error_message;  // Static string, don't free
} VTShimResult;

// Context for decode callback
typedef struct {
    uint32_t frames_decoded;
    bool decode_error;
    OSStatus last_status;
} DecodeContext;

// Decode callback - called for each decoded frame
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

// Parse avcC/hvcC to extract parameter sets
// Returns array of parameter set data, sets count and nal_length_size
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

// Internal validation function - runs on main thread
static void do_validate(void* context) {
    ValidationContext* ctx = (ValidationContext*)context;

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
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault,
            param_count,
            (const uint8_t* const*)param_sets,
            param_sizes,
            nal_length_size,
            NULL,
            &format_desc
        );
    } else {
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault,
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
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        format_desc,
        NULL,  // videoDecoderSpecification
        NULL,  // destinationImageBufferAttributes
        &callback,
        &session
    );

    if (status != noErr || session == NULL) {
        CFRelease(format_desc);
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
        status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault,
            (void*)sample_data,
            sample_size,
            kCFAllocatorNull,  // Don't free the data
            NULL,
            0,
            sample_size,
            0,
            &block_buffer
        );

        if (status != noErr || block_buffer == NULL) continue;

        CMSampleBufferRef sample_buffer = NULL;
        size_t sample_size_array[1] = {sample_size};
        status = CMSampleBufferCreate(
            kCFAllocatorDefault,
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

        CFRelease(block_buffer);

        if (status != noErr || sample_buffer == NULL) continue;

        status = VTDecompressionSessionDecodeFrame(
            session,
            sample_buffer,
            kVTDecodeFrame_EnableAsynchronousDecompression,
            NULL,
            NULL
        );

        CFRelease(sample_buffer);

        if (status != noErr) {
            decode_ctx.decode_error = true;
            break;
        }
    }

    // Wait for async frames
    VTDecompressionSessionWaitForAsynchronousFrames(session);

    // Cleanup
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    CFRelease(format_desc);

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

// Check if we're on the main thread
static bool is_main_thread(void) {
    return pthread_main_np() != 0;
}

// Public API: Validate H.264 stream
// Thread-safe: automatically dispatches to main thread if needed
void vt_shim_validate_h264(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
) {
    ValidationContext ctx = {
        .codec_private = codec_private,
        .codec_private_size = codec_private_size,
        .samples = samples,
        .sample_sizes = sample_sizes,
        .num_samples = num_samples,
        .codec_type = kCMVideoCodecType_H264,
        .result = {.valid = false, .frames_decoded = 0, .error_message = "Not executed"}
    };

    if (is_main_thread()) {
        do_validate(&ctx);
    } else {
        dispatch_sync_f(dispatch_get_main_queue(), &ctx, do_validate);
    }

    *result = ctx.result;
}

// Public API: Validate HEVC stream
// Thread-safe: automatically dispatches to main thread if needed
void vt_shim_validate_hevc(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
) {
    ValidationContext ctx = {
        .codec_private = codec_private,
        .codec_private_size = codec_private_size,
        .samples = samples,
        .sample_sizes = sample_sizes,
        .num_samples = num_samples,
        .codec_type = kCMVideoCodecType_HEVC,
        .result = {.valid = false, .frames_decoded = 0, .error_message = "Not executed"}
    };

    if (is_main_thread()) {
        do_validate(&ctx);
    } else {
        dispatch_sync_f(dispatch_get_main_queue(), &ctx, do_validate);
    }

    *result = ctx.result;
}

// Public API: Check if VideoToolbox is available
bool vt_shim_is_available(void) {
    return true;  // Always available on macOS
}

#endif // __APPLE__
