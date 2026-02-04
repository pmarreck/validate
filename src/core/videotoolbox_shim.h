/**
 * VideoToolbox C Shim - Header
 *
 * Thread-safe wrapper for Apple's VideoToolbox framework using
 * dlopen/dlsym for runtime loading.
 *
 * USAGE:
 * 1. Call vt_shim_init() once from the main thread before any validation
 * 2. Call vt_shim_validate_h264/hevc from any thread (dispatches to main)
 * 3. Check vt_shim_is_available() to see if VideoToolbox loaded successfully
 *
 * macOS only.
 */

#ifndef VIDEOTOOLBOX_SHIM_H
#define VIDEOTOOLBOX_SHIM_H

#ifdef __APPLE__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Result structure for validation
typedef struct {
    bool valid;
    uint32_t frames_decoded;
    const char* error_message;  // Static string, caller should not free
} VTShimResult;

/**
 * Initialize VideoToolbox via dlopen/dlsym.
 *
 * MUST be called from the main thread before any validation functions.
 * Can be called multiple times safely (subsequent calls are no-ops).
 *
 * @return true if VideoToolbox was loaded successfully, false otherwise
 */
bool vt_shim_init(void);

/**
 * Check if VideoToolbox has been initialized.
 *
 * @return true if vt_shim_init() has been called
 */
bool vt_shim_is_initialized(void);

/**
 * Check if VideoToolbox is available and ready to use.
 *
 * @return true if VideoToolbox loaded successfully
 */
bool vt_shim_is_available(void);

/**
 * Validate H.264 video stream using VideoToolbox.
 *
 * Thread-safe: automatically dispatches to main thread if needed.
 * Requires vt_shim_init() to have been called first.
 *
 * @param codec_private     Raw avcC box data
 * @param codec_private_size Size of avcC data
 * @param samples           Array of sample data pointers (NAL units)
 * @param sample_sizes      Array of sample sizes
 * @param num_samples       Number of samples
 * @param result            Output result structure
 */
void vt_shim_validate_h264(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
);

/**
 * Validate HEVC video stream using VideoToolbox.
 *
 * Thread-safe: automatically dispatches to main thread if needed.
 * Requires vt_shim_init() to have been called first.
 *
 * @param codec_private     Raw hvcC box data
 * @param codec_private_size Size of hvcC data
 * @param samples           Array of sample data pointers (NAL units)
 * @param sample_sizes      Array of sample sizes
 * @param num_samples       Number of samples
 * @param result            Output result structure
 */
void vt_shim_validate_hevc(
    const uint8_t* codec_private,
    size_t codec_private_size,
    const uint8_t* const* samples,
    const size_t* sample_sizes,
    size_t num_samples,
    VTShimResult* result
);

#ifdef __cplusplus
}
#endif

#endif // __APPLE__

#endif // VIDEOTOOLBOX_SHIM_H
