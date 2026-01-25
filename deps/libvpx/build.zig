const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libvpx_src = b.dependency("libvpx_src", .{});

    // Create static library for decoder only
    const lib = b.addLibrary(.{
        .name = "vpx",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Generate config headers
    const config_files = b.addWriteFiles();
    _ = config_files.add("vpx_config.h", vpx_config_h);
    _ = config_files.add("vpx_config.c", vpx_config_c);
    _ = config_files.add("vpx_config.asm", ""); // Empty, not needed for C-only build
    _ = config_files.add("vpx_version.h", vpx_version_h);
    lib.addIncludePath(config_files.getDirectory());

    // Generate RTCD headers (runtime CPU detection - all C fallbacks)
    const rtcd_files = b.addWriteFiles();
    _ = rtcd_files.add("vpx_dsp_rtcd.h", vpx_dsp_rtcd_h);
    _ = rtcd_files.add("vpx_scale_rtcd.h", vpx_scale_rtcd_h);
    _ = rtcd_files.add("vp8_rtcd.h", vp8_rtcd_h);
    _ = rtcd_files.add("vp9_rtcd.h", vp9_rtcd_h);
    lib.addIncludePath(rtcd_files.getDirectory());

    // Common C flags for generic build (no SIMD)
    const cflags: []const []const u8 = &.{
        "-DHAVE_CONFIG_H=1",
        "-fvisibility=hidden",
        "-fno-strict-aliasing",
    };

    // Add include paths
    lib.addIncludePath(libvpx_src.path(""));

    // VPX common sources
    const vpx_sources: []const []const u8 = &.{
        "vpx/src/vpx_codec.c",
        "vpx/src/vpx_decoder.c",
        "vpx/src/vpx_image.c",
    };

    // VPX memory sources
    const vpx_mem_sources: []const []const u8 = &.{
        "vpx_mem/vpx_mem.c",
    };

    // VPX util sources
    const vpx_util_sources: []const []const u8 = &.{
        "vpx_util/vpx_thread.c",
    };

    // VPX scale sources (C-only) - vpx_scale.c excluded (has VP8-only code)
    const vpx_scale_sources: []const []const u8 = &.{
        "vpx_scale/generic/gen_scalers.c",
        // "vpx_scale/generic/vpx_scale.c", // VP8-only scale functions
        "vpx_scale/generic/yv12config.c",
        "vpx_scale/generic/yv12extend.c",
    };

    // VPX DSP sources (C-only, no SIMD)
    const vpx_dsp_sources: []const []const u8 = &.{
        "vpx_dsp/bitreader.c",
        "vpx_dsp/bitreader_buffer.c",
        "vpx_dsp/intrapred.c",
        "vpx_dsp/inv_txfm.c",
        "vpx_dsp/loopfilter.c",
        "vpx_dsp/prob.c",
        "vpx_dsp/vpx_convolve.c",
        "vpx_dsp/vpx_dsp_rtcd.c",
    };

    // VP8 disabled for simpler build - only VP9 decoder
    // VP8 common sources (unused)
    // VP8 decoder sources (unused)

    // VP9 common sources
    const vp9_common_sources: []const []const u8 = &.{
        "vp9/common/vp9_alloccommon.c",
        "vp9/common/vp9_blockd.c",
        "vp9/common/vp9_common_data.c",
        "vp9/common/vp9_entropy.c",
        "vp9/common/vp9_entropymode.c",
        "vp9/common/vp9_entropymv.c",
        "vp9/common/vp9_filter.c",
        "vp9/common/vp9_frame_buffers.c",
        "vp9/common/vp9_idct.c",
        "vp9/common/vp9_loopfilter.c",
        "vp9/common/vp9_mvref_common.c",
        "vp9/common/vp9_pred_common.c",
        "vp9/common/vp9_quant_common.c",
        "vp9/common/vp9_reconinter.c",
        "vp9/common/vp9_reconintra.c",
        "vp9/common/vp9_rtcd.c",
        "vp9/common/vp9_scale.c",
        "vp9/common/vp9_scan.c",
        "vp9/common/vp9_seg_common.c",
        "vp9/common/vp9_thread_common.c",
        "vp9/common/vp9_tile_common.c",
    };

    // VP9 decoder sources
    const vp9_decoder_sources: []const []const u8 = &.{
        "vp9/decoder/vp9_decodeframe.c",
        "vp9/decoder/vp9_decodemv.c",
        "vp9/decoder/vp9_decoder.c",
        "vp9/decoder/vp9_detokenize.c",
        "vp9/decoder/vp9_dsubexp.c",
        "vp9/decoder/vp9_job_queue.c",
    };

    // Add all source files
    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vpx_sources,
        .flags = cflags,
    });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vpx_mem_sources,
        .flags = cflags,
    });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vpx_util_sources,
        .flags = cflags,
    });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vpx_scale_sources,
        .flags = cflags,
    });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vpx_dsp_sources,
        .flags = cflags,
    });

    // VP8 disabled for simpler build - only VP9 decoder
    // lib.addCSourceFiles(.{
    //     .root = libvpx_src.path(""),
    //     .files = vp8_common_sources,
    //     .flags = cflags,
    // });

    // lib.addCSourceFiles(.{
    //     .root = libvpx_src.path(""),
    //     .files = vp8_decoder_sources,
    //     .flags = cflags,
    // });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vp9_common_sources,
        .flags = cflags,
    });

    lib.addCSourceFiles(.{
        .root = libvpx_src.path(""),
        .files = vp9_decoder_sources,
        .flags = cflags,
    });

    // Link pthread
    lib.linkSystemLibrary("pthread");

    // Install headers
    lib.installHeader(libvpx_src.path("vpx/vpx_codec.h"), "vpx/vpx_codec.h");
    lib.installHeader(libvpx_src.path("vpx/vpx_decoder.h"), "vpx/vpx_decoder.h");
    lib.installHeader(libvpx_src.path("vpx/vpx_frame_buffer.h"), "vpx/vpx_frame_buffer.h");
    lib.installHeader(libvpx_src.path("vpx/vpx_image.h"), "vpx/vpx_image.h");
    lib.installHeader(libvpx_src.path("vpx/vpx_integer.h"), "vpx/vpx_integer.h");
    lib.installHeader(libvpx_src.path("vpx/vp8.h"), "vpx/vp8.h");
    lib.installHeader(libvpx_src.path("vpx/vp8dx.h"), "vpx/vp8dx.h");

    b.installArtifact(lib);
}

// vpx_config.h - minimal config for C-only decoder build
const vpx_config_h =
    \\/* Auto-generated vpx_config.h for Zig build - C-only decoder */
    \\#ifndef VPX_CONFIG_H
    \\#define VPX_CONFIG_H
    \\
    \\#define RESTRICT
    \\#define INLINE inline
    \\
    \\/* Decoder only - VP9 only for simpler build */
    \\#define CONFIG_VP8_DECODER 0
    \\#define CONFIG_VP9_DECODER 1
    \\#define CONFIG_VP8_ENCODER 0
    \\#define CONFIG_VP9_ENCODER 0
    \\
    \\/* Multithread support */
    \\#define CONFIG_MULTITHREAD 1
    \\
    \\/* Size and bit depth */
    \\#define CONFIG_SIZE_LIMIT 0
    \\#define CONFIG_VP9_HIGHBITDEPTH 0
    \\
    \\/* Postprocessing */
    \\#define CONFIG_VP8_POSTPROC 0
    \\#define CONFIG_VP9_POSTPROC 0
    \\#define CONFIG_POSTPROC 0
    \\
    \\/* Error concealment */
    \\#define CONFIG_ERROR_CONCEALMENT 0
    \\
    \\/* Temporal denoising */
    \\#define CONFIG_VP9_TEMPORAL_DENOISING 0
    \\
    \\/* Spatial resampling */
    \\#define CONFIG_SPATIAL_RESAMPLING 0
    \\
    \\/* Runtime CPU detection disabled - pure C */
    \\#define CONFIG_RUNTIME_CPU_DETECT 0
    \\
    \\/* No SIMD intrinsics */
    \\#define HAVE_NEON 0
    \\#define HAVE_NEON_ASM 0
    \\#define HAVE_MIPS32 0
    \\#define HAVE_DSPR2 0
    \\#define HAVE_MSA 0
    \\#define HAVE_MMX 0
    \\#define HAVE_SSE 0
    \\#define HAVE_SSE2 0
    \\#define HAVE_SSE3 0
    \\#define HAVE_SSSE3 0
    \\#define HAVE_SSE4_1 0
    \\#define HAVE_AVX 0
    \\#define HAVE_AVX2 0
    \\#define HAVE_AVX512 0
    \\#define HAVE_VSX 0
    \\#define HAVE_MMI 0
    \\#define HAVE_LSX 0
    \\#define HAVE_LASX 0
    \\
    \\/* Standard library features */
    \\#define HAVE_PTHREAD_H 1
    \\#define HAVE_UNISTD_H 1
    \\
    \\/* Architecture - generic */
    \\#define ARCH_ARM 0
    \\#define ARCH_MIPS 0
    \\#define ARCH_X86 0
    \\#define ARCH_X86_64 0
    \\#define ARCH_PPC 0
    \\#define ARCH_LOONGARCH 0
    \\
    \\/* VP9 features */
    \\#define CONFIG_COEFFICIENT_RANGE_CHECKING 0
    \\#define CONFIG_VP9_SUPERFRAME 1
    \\
    \\/* Shared library (disabled) */
    \\#define CONFIG_SHARED 0
    \\#define CONFIG_STATIC 1
    \\
    \\/* OS features */
    \\#define CONFIG_OS_SUPPORT 1
    \\#define CONFIG_GCC 1
    \\
    \\/* Debug features (disabled) */
    \\#define CONFIG_DEBUG 0
    \\#define CONFIG_UNIT_TESTS 0
    \\
    \\/* Internal features */
    \\#define CONFIG_INTERNAL_STATS 0
    \\#define CONFIG_WEBM_IO 0
    \\#define CONFIG_LIBYUV 0
    \\
    \\#endif /* VPX_CONFIG_H */
;

// vpx_config.c - config source file
const vpx_config_c =
    \\/* Auto-generated vpx_config.c */
    \\#include "vpx_config.h"
    \\static const char* const cfg = "Zig build - decoder only";
    \\const char *vpx_codec_build_config(void) { return cfg; }
;

// vpx_version.h
const vpx_version_h =
    \\/* Auto-generated vpx_version.h */
    \\#ifndef VPX_VERSION_H
    \\#define VPX_VERSION_H
    \\#define VERSION_MAJOR 1
    \\#define VERSION_MINOR 15
    \\#define VERSION_PATCH 0
    \\#define VERSION_EXTRA ""
    \\#define VERSION_PACKED ((VERSION_MAJOR << 16) | (VERSION_MINOR << 8) | (VERSION_PATCH))
    \\#define VERSION_STRING_NOSP "v1.15.0"
    \\#define VERSION_STRING " v1.15.0"
    \\#endif /* VPX_VERSION_H */
;

// vpx_dsp_rtcd.h - C-only function declarations
const vpx_dsp_rtcd_h =
    \\/* Auto-generated vpx_dsp_rtcd.h - C implementations only */
    \\#ifndef VPX_DSP_RTCD_H
    \\#define VPX_DSP_RTCD_H
    \\
    \\#ifdef RTCD_C
    \\#define RTCD_EXTERN
    \\#else
    \\#define RTCD_EXTERN extern
    \\#endif
    \\
    \\#include "vpx/vpx_integer.h"
    \\#include "vpx_dsp/vpx_dsp_common.h"
    \\#include "vpx_dsp/vpx_filter.h"
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* Convolution / interpolation */
    \\void vpx_convolve_copy_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve_copy vpx_convolve_copy_c
    \\
    \\void vpx_convolve_avg_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve_avg vpx_convolve_avg_c
    \\
    \\void vpx_convolve8_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8 vpx_convolve8_c
    \\
    \\void vpx_convolve8_horiz_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8_horiz vpx_convolve8_horiz_c
    \\
    \\void vpx_convolve8_vert_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8_vert vpx_convolve8_vert_c
    \\
    \\void vpx_convolve8_avg_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8_avg vpx_convolve8_avg_c
    \\
    \\void vpx_convolve8_avg_horiz_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8_avg_horiz vpx_convolve8_avg_horiz_c
    \\
    \\void vpx_convolve8_avg_vert_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_convolve8_avg_vert vpx_convolve8_avg_vert_c
    \\
    \\void vpx_scaled_2d_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_2d vpx_scaled_2d_c
    \\
    \\void vpx_scaled_horiz_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_horiz vpx_scaled_horiz_c
    \\
    \\void vpx_scaled_vert_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_vert vpx_scaled_vert_c
    \\
    \\void vpx_scaled_avg_2d_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_avg_2d vpx_scaled_avg_2d_c
    \\
    \\void vpx_scaled_avg_horiz_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_avg_horiz vpx_scaled_avg_horiz_c
    \\
    \\void vpx_scaled_avg_vert_c(const uint8_t *src, ptrdiff_t src_stride, uint8_t *dst, ptrdiff_t dst_stride, const InterpKernel *filter, int x0_q4, int x_step_q4, int y0_q4, int y_step_q4, int w, int h);
    \\#define vpx_scaled_avg_vert vpx_scaled_avg_vert_c
    \\
    \\/* Loop filter */
    \\void vpx_lpf_vertical_16_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_vertical_16 vpx_lpf_vertical_16_c
    \\
    \\void vpx_lpf_vertical_16_dual_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_vertical_16_dual vpx_lpf_vertical_16_dual_c
    \\
    \\void vpx_lpf_vertical_8_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_vertical_8 vpx_lpf_vertical_8_c
    \\
    \\void vpx_lpf_vertical_8_dual_c(uint8_t *s, int pitch, const uint8_t *blimit0, const uint8_t *limit0, const uint8_t *thresh0, const uint8_t *blimit1, const uint8_t *limit1, const uint8_t *thresh1);
    \\#define vpx_lpf_vertical_8_dual vpx_lpf_vertical_8_dual_c
    \\
    \\void vpx_lpf_vertical_4_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_vertical_4 vpx_lpf_vertical_4_c
    \\
    \\void vpx_lpf_vertical_4_dual_c(uint8_t *s, int pitch, const uint8_t *blimit0, const uint8_t *limit0, const uint8_t *thresh0, const uint8_t *blimit1, const uint8_t *limit1, const uint8_t *thresh1);
    \\#define vpx_lpf_vertical_4_dual vpx_lpf_vertical_4_dual_c
    \\
    \\void vpx_lpf_horizontal_16_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_horizontal_16 vpx_lpf_horizontal_16_c
    \\
    \\void vpx_lpf_horizontal_16_dual_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_horizontal_16_dual vpx_lpf_horizontal_16_dual_c
    \\
    \\void vpx_lpf_horizontal_8_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_horizontal_8 vpx_lpf_horizontal_8_c
    \\
    \\void vpx_lpf_horizontal_8_dual_c(uint8_t *s, int pitch, const uint8_t *blimit0, const uint8_t *limit0, const uint8_t *thresh0, const uint8_t *blimit1, const uint8_t *limit1, const uint8_t *thresh1);
    \\#define vpx_lpf_horizontal_8_dual vpx_lpf_horizontal_8_dual_c
    \\
    \\void vpx_lpf_horizontal_4_c(uint8_t *s, int pitch, const uint8_t *blimit, const uint8_t *limit, const uint8_t *thresh);
    \\#define vpx_lpf_horizontal_4 vpx_lpf_horizontal_4_c
    \\
    \\void vpx_lpf_horizontal_4_dual_c(uint8_t *s, int pitch, const uint8_t *blimit0, const uint8_t *limit0, const uint8_t *thresh0, const uint8_t *blimit1, const uint8_t *limit1, const uint8_t *thresh1);
    \\#define vpx_lpf_horizontal_4_dual vpx_lpf_horizontal_4_dual_c
    \\
    \\/* Intra prediction - all sizes */
    \\/* 4x4 */
    \\void vpx_d207_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d207_predictor_4x4 vpx_d207_predictor_4x4_c
    \\void vpx_d45_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d45_predictor_4x4 vpx_d45_predictor_4x4_c
    \\void vpx_d63_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d63_predictor_4x4 vpx_d63_predictor_4x4_c
    \\void vpx_d117_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d117_predictor_4x4 vpx_d117_predictor_4x4_c
    \\void vpx_d135_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d135_predictor_4x4 vpx_d135_predictor_4x4_c
    \\void vpx_d153_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d153_predictor_4x4 vpx_d153_predictor_4x4_c
    \\void vpx_dc_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_predictor_4x4 vpx_dc_predictor_4x4_c
    \\void vpx_dc_128_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_128_predictor_4x4 vpx_dc_128_predictor_4x4_c
    \\void vpx_dc_left_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_left_predictor_4x4 vpx_dc_left_predictor_4x4_c
    \\void vpx_dc_top_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_top_predictor_4x4 vpx_dc_top_predictor_4x4_c
    \\void vpx_h_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_h_predictor_4x4 vpx_h_predictor_4x4_c
    \\void vpx_tm_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_tm_predictor_4x4 vpx_tm_predictor_4x4_c
    \\void vpx_v_predictor_4x4_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_v_predictor_4x4 vpx_v_predictor_4x4_c
    \\/* 8x8 */
    \\void vpx_d207_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d207_predictor_8x8 vpx_d207_predictor_8x8_c
    \\void vpx_d45_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d45_predictor_8x8 vpx_d45_predictor_8x8_c
    \\void vpx_d63_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d63_predictor_8x8 vpx_d63_predictor_8x8_c
    \\void vpx_d117_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d117_predictor_8x8 vpx_d117_predictor_8x8_c
    \\void vpx_d135_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d135_predictor_8x8 vpx_d135_predictor_8x8_c
    \\void vpx_d153_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d153_predictor_8x8 vpx_d153_predictor_8x8_c
    \\void vpx_dc_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_predictor_8x8 vpx_dc_predictor_8x8_c
    \\void vpx_dc_128_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_128_predictor_8x8 vpx_dc_128_predictor_8x8_c
    \\void vpx_dc_left_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_left_predictor_8x8 vpx_dc_left_predictor_8x8_c
    \\void vpx_dc_top_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_top_predictor_8x8 vpx_dc_top_predictor_8x8_c
    \\void vpx_h_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_h_predictor_8x8 vpx_h_predictor_8x8_c
    \\void vpx_tm_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_tm_predictor_8x8 vpx_tm_predictor_8x8_c
    \\void vpx_v_predictor_8x8_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_v_predictor_8x8 vpx_v_predictor_8x8_c
    \\/* 16x16 */
    \\void vpx_d207_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d207_predictor_16x16 vpx_d207_predictor_16x16_c
    \\void vpx_d45_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d45_predictor_16x16 vpx_d45_predictor_16x16_c
    \\void vpx_d63_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d63_predictor_16x16 vpx_d63_predictor_16x16_c
    \\void vpx_d117_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d117_predictor_16x16 vpx_d117_predictor_16x16_c
    \\void vpx_d135_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d135_predictor_16x16 vpx_d135_predictor_16x16_c
    \\void vpx_d153_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d153_predictor_16x16 vpx_d153_predictor_16x16_c
    \\void vpx_dc_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_predictor_16x16 vpx_dc_predictor_16x16_c
    \\void vpx_dc_128_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_128_predictor_16x16 vpx_dc_128_predictor_16x16_c
    \\void vpx_dc_left_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_left_predictor_16x16 vpx_dc_left_predictor_16x16_c
    \\void vpx_dc_top_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_top_predictor_16x16 vpx_dc_top_predictor_16x16_c
    \\void vpx_h_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_h_predictor_16x16 vpx_h_predictor_16x16_c
    \\void vpx_tm_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_tm_predictor_16x16 vpx_tm_predictor_16x16_c
    \\void vpx_v_predictor_16x16_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_v_predictor_16x16 vpx_v_predictor_16x16_c
    \\/* 32x32 */
    \\void vpx_d207_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d207_predictor_32x32 vpx_d207_predictor_32x32_c
    \\void vpx_d45_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d45_predictor_32x32 vpx_d45_predictor_32x32_c
    \\void vpx_d63_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d63_predictor_32x32 vpx_d63_predictor_32x32_c
    \\void vpx_d117_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d117_predictor_32x32 vpx_d117_predictor_32x32_c
    \\void vpx_d135_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d135_predictor_32x32 vpx_d135_predictor_32x32_c
    \\void vpx_d153_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_d153_predictor_32x32 vpx_d153_predictor_32x32_c
    \\void vpx_dc_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_predictor_32x32 vpx_dc_predictor_32x32_c
    \\void vpx_dc_128_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_128_predictor_32x32 vpx_dc_128_predictor_32x32_c
    \\void vpx_dc_left_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_left_predictor_32x32 vpx_dc_left_predictor_32x32_c
    \\void vpx_dc_top_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_dc_top_predictor_32x32 vpx_dc_top_predictor_32x32_c
    \\void vpx_h_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_h_predictor_32x32 vpx_h_predictor_32x32_c
    \\void vpx_tm_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_tm_predictor_32x32 vpx_tm_predictor_32x32_c
    \\void vpx_v_predictor_32x32_c(uint8_t *dst, ptrdiff_t stride, const uint8_t *above, const uint8_t *left);
    \\#define vpx_v_predictor_32x32 vpx_v_predictor_32x32_c
    \\
    \\/* Inverse transforms */
    \\void vpx_idct4x4_16_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct4x4_16_add vpx_idct4x4_16_add_c
    \\
    \\void vpx_idct4x4_1_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct4x4_1_add vpx_idct4x4_1_add_c
    \\
    \\void vpx_idct8x8_64_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct8x8_64_add vpx_idct8x8_64_add_c
    \\
    \\void vpx_idct8x8_12_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct8x8_12_add vpx_idct8x8_12_add_c
    \\
    \\void vpx_idct8x8_1_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct8x8_1_add vpx_idct8x8_1_add_c
    \\
    \\void vpx_idct16x16_256_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct16x16_256_add vpx_idct16x16_256_add_c
    \\
    \\void vpx_idct16x16_38_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct16x16_38_add vpx_idct16x16_38_add_c
    \\
    \\void vpx_idct16x16_10_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct16x16_10_add vpx_idct16x16_10_add_c
    \\
    \\void vpx_idct16x16_1_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct16x16_1_add vpx_idct16x16_1_add_c
    \\
    \\void vpx_idct32x32_1024_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct32x32_1024_add vpx_idct32x32_1024_add_c
    \\
    \\void vpx_idct32x32_135_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct32x32_135_add vpx_idct32x32_135_add_c
    \\
    \\void vpx_idct32x32_34_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct32x32_34_add vpx_idct32x32_34_add_c
    \\
    \\void vpx_idct32x32_1_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_idct32x32_1_add vpx_idct32x32_1_add_c
    \\
    \\void vpx_iwht4x4_16_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_iwht4x4_16_add vpx_iwht4x4_16_add_c
    \\
    \\void vpx_iwht4x4_1_add_c(const tran_low_t *input, uint8_t *dest, int stride);
    \\#define vpx_iwht4x4_1_add vpx_iwht4x4_1_add_c
    \\
    \\void vpx_dsp_rtcd(void);
    \\static INLINE void vpx_rtcd(void) { vpx_dsp_rtcd(); }
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#include "vpx_config.h"
    \\
    \\#ifdef RTCD_C
    \\static void setup_rtcd_internal(void) {}
    \\#endif
    \\
    \\#endif /* VPX_DSP_RTCD_H */
;

// vpx_scale_rtcd.h - C-only scale functions
const vpx_scale_rtcd_h =
    \\/* Auto-generated vpx_scale_rtcd.h - C implementations only */
    \\#ifndef VPX_SCALE_RTCD_H
    \\#define VPX_SCALE_RTCD_H
    \\
    \\#ifdef RTCD_C
    \\#define RTCD_EXTERN
    \\#else
    \\#define RTCD_EXTERN extern
    \\#endif
    \\
    \\struct yv12_buffer_config;
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\void vpx_extend_frame_borders_c(struct yv12_buffer_config *ybf);
    \\#define vpx_extend_frame_borders vpx_extend_frame_borders_c
    \\
    \\void vpx_extend_frame_inner_borders_c(struct yv12_buffer_config *ybf);
    \\#define vpx_extend_frame_inner_borders vpx_extend_frame_inner_borders_c
    \\
    \\void vpx_yv12_copy_frame_c(const struct yv12_buffer_config *src_bc, struct yv12_buffer_config *dst_bc);
    \\#define vpx_yv12_copy_frame vpx_yv12_copy_frame_c
    \\
    \\void vpx_yv12_copy_y_c(const struct yv12_buffer_config *src_ybc, struct yv12_buffer_config *dst_ybc);
    \\#define vpx_yv12_copy_y vpx_yv12_copy_y_c
    \\
    \\void vpx_yv12_copy_u_c(const struct yv12_buffer_config *src_bc, struct yv12_buffer_config *dst_bc);
    \\#define vpx_yv12_copy_u vpx_yv12_copy_u_c
    \\
    \\void vpx_yv12_copy_v_c(const struct yv12_buffer_config *src_bc, struct yv12_buffer_config *dst_bc);
    \\#define vpx_yv12_copy_v vpx_yv12_copy_v_c
    \\
    \\void vpx_scale_rtcd(void);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#include "vpx_config.h"
    \\
    \\#ifdef RTCD_C
    \\static void setup_rtcd_internal(void) {}
    \\#endif
    \\
    \\#endif /* VPX_SCALE_RTCD_H */
;

// vp8_rtcd.h - VP8 C-only functions
const vp8_rtcd_h =
    \\/* Auto-generated vp8_rtcd.h - C implementations only */
    \\#ifndef VP8_RTCD_H
    \\#define VP8_RTCD_H
    \\
    \\#ifdef RTCD_C
    \\#define RTCD_EXTERN
    \\#else
    \\#define RTCD_EXTERN extern
    \\#endif
    \\
    \\struct blockd;
    \\struct macroblockd;
    \\struct loop_filter_info;
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* Dequantization */
    \\void vp8_dequantize_b_c(struct blockd *, short *DQC);
    \\#define vp8_dequantize_b vp8_dequantize_b_c
    \\
    \\void vp8_dequant_idct_add_c(short *input, short *dq, unsigned char *dest, int stride);
    \\#define vp8_dequant_idct_add vp8_dequant_idct_add_c
    \\
    \\void vp8_dequant_idct_add_y_block_c(short *q, short *dq, unsigned char *dst, int stride, char *eobs);
    \\#define vp8_dequant_idct_add_y_block vp8_dequant_idct_add_y_block_c
    \\
    \\void vp8_dequant_idct_add_uv_block_c(short *q, short *dq, unsigned char *dst_u, unsigned char *dst_v, int stride, char *eobs);
    \\#define vp8_dequant_idct_add_uv_block vp8_dequant_idct_add_uv_block_c
    \\
    \\/* Loop filter */
    \\void vp8_loop_filter_mbv_c(unsigned char *y_ptr, unsigned char *u_ptr, unsigned char *v_ptr, int y_stride, int uv_stride, struct loop_filter_info *lfi);
    \\#define vp8_loop_filter_mbv vp8_loop_filter_mbv_c
    \\
    \\void vp8_loop_filter_bv_c(unsigned char *y_ptr, unsigned char *u_ptr, unsigned char *v_ptr, int y_stride, int uv_stride, struct loop_filter_info *lfi);
    \\#define vp8_loop_filter_bv vp8_loop_filter_bv_c
    \\
    \\void vp8_loop_filter_mbh_c(unsigned char *y_ptr, unsigned char *u_ptr, unsigned char *v_ptr, int y_stride, int uv_stride, struct loop_filter_info *lfi);
    \\#define vp8_loop_filter_mbh vp8_loop_filter_mbh_c
    \\
    \\void vp8_loop_filter_bh_c(unsigned char *y_ptr, unsigned char *u_ptr, unsigned char *v_ptr, int y_stride, int uv_stride, struct loop_filter_info *lfi);
    \\#define vp8_loop_filter_bh vp8_loop_filter_bh_c
    \\
    \\void vp8_loop_filter_simple_mbv_c(unsigned char *y_ptr, int y_stride, const unsigned char *blimit);
    \\#define vp8_loop_filter_simple_mbv vp8_loop_filter_simple_mbv_c
    \\
    \\void vp8_loop_filter_simple_mbh_c(unsigned char *y_ptr, int y_stride, const unsigned char *blimit);
    \\#define vp8_loop_filter_simple_mbh vp8_loop_filter_simple_mbh_c
    \\
    \\void vp8_loop_filter_simple_bv_c(unsigned char *y_ptr, int y_stride, const unsigned char *blimit);
    \\#define vp8_loop_filter_simple_bv vp8_loop_filter_simple_bv_c
    \\
    \\void vp8_loop_filter_simple_bh_c(unsigned char *y_ptr, int y_stride, const unsigned char *blimit);
    \\#define vp8_loop_filter_simple_bh vp8_loop_filter_simple_bh_c
    \\
    \\/* Predict functions */
    \\void vp8_intra4x4_predict_c(unsigned char *src_ptr, int src_stride, int b_mode, unsigned char *dst_ptr, int dst_stride);
    \\#define vp8_intra4x4_predict vp8_intra4x4_predict_c
    \\
    \\void vp8_dc_only_idct_add_c(short input_dc, unsigned char *pred_ptr, int pred_stride, unsigned char *dst_ptr, int dst_stride);
    \\#define vp8_dc_only_idct_add vp8_dc_only_idct_add_c
    \\
    \\void vp8_copy_mem16x16_c(unsigned char *src, int src_stride, unsigned char *dst, int dst_stride);
    \\#define vp8_copy_mem16x16 vp8_copy_mem16x16_c
    \\
    \\void vp8_copy_mem8x8_c(unsigned char *src, int src_stride, unsigned char *dst, int dst_stride);
    \\#define vp8_copy_mem8x8 vp8_copy_mem8x8_c
    \\
    \\void vp8_copy_mem8x4_c(unsigned char *src, int src_stride, unsigned char *dst, int dst_stride);
    \\#define vp8_copy_mem8x4 vp8_copy_mem8x4_c
    \\
    \\void vp8_build_intra_predictors_mby_s_c(struct macroblockd *x, unsigned char *yabove_row, unsigned char *yleft, int left_stride, unsigned char *ypred_ptr, int y_stride);
    \\#define vp8_build_intra_predictors_mby_s vp8_build_intra_predictors_mby_s_c
    \\
    \\void vp8_build_intra_predictors_mbuv_s_c(struct macroblockd *x, unsigned char *uabove_row, unsigned char *vabove_row, unsigned char *uleft, unsigned char *vleft, int left_stride, unsigned char *upred_ptr, unsigned char *vpred_ptr, int pred_stride);
    \\#define vp8_build_intra_predictors_mbuv_s vp8_build_intra_predictors_mbuv_s_c
    \\
    \\/* Interpolation */
    \\void vp8_sixtap_predict16x16_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_sixtap_predict16x16 vp8_sixtap_predict16x16_c
    \\
    \\void vp8_sixtap_predict8x8_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_sixtap_predict8x8 vp8_sixtap_predict8x8_c
    \\
    \\void vp8_sixtap_predict8x4_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_sixtap_predict8x4 vp8_sixtap_predict8x4_c
    \\
    \\void vp8_sixtap_predict4x4_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_sixtap_predict4x4 vp8_sixtap_predict4x4_c
    \\
    \\void vp8_bilinear_predict16x16_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_bilinear_predict16x16 vp8_bilinear_predict16x16_c
    \\
    \\void vp8_bilinear_predict8x8_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_bilinear_predict8x8 vp8_bilinear_predict8x8_c
    \\
    \\void vp8_bilinear_predict8x4_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_bilinear_predict8x4 vp8_bilinear_predict8x4_c
    \\
    \\void vp8_bilinear_predict4x4_c(unsigned char *src_ptr, int src_pixels_per_line, int xoffset, int yoffset, unsigned char *dst_ptr, int dst_pitch);
    \\#define vp8_bilinear_predict4x4 vp8_bilinear_predict4x4_c
    \\
    \\void vp8_short_idct4x4llm_c(short *input, unsigned char *pred_ptr, int pred_stride, unsigned char *dst_ptr, int dst_stride);
    \\#define vp8_short_idct4x4llm vp8_short_idct4x4llm_c
    \\
    \\void vp8_short_inv_walsh4x4_c(short *input, short *mb_dqcoeff);
    \\#define vp8_short_inv_walsh4x4 vp8_short_inv_walsh4x4_c
    \\
    \\void vp8_short_inv_walsh4x4_1_c(short *input, short *mb_dqcoeff);
    \\#define vp8_short_inv_walsh4x4_1 vp8_short_inv_walsh4x4_1_c
    \\
    \\void vp8_rtcd(void);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#include "vpx_config.h"
    \\
    \\#ifdef RTCD_C
    \\static void setup_rtcd_internal(void) {}
    \\#endif
    \\
    \\#endif /* VP8_RTCD_H */
;

// vp9_rtcd.h - VP9 C-only functions
const vp9_rtcd_h =
    \\/* Auto-generated vp9_rtcd.h - C implementations only */
    \\#ifndef VP9_RTCD_H
    \\#define VP9_RTCD_H
    \\
    \\#ifdef RTCD_C
    \\#define RTCD_EXTERN
    \\#else
    \\#define RTCD_EXTERN extern
    \\#endif
    \\
    \\#include "vpx/vpx_integer.h"
    \\#include "vp9/common/vp9_common.h"
    \\#include "vp9/common/vp9_enums.h"
    \\#include "vp9/common/vp9_filter.h"
    \\
    \\struct macroblockd;
    \\
    \\#ifdef __cplusplus
    \\extern "C" {
    \\#endif
    \\
    \\/* Intra prediction */
    \\void vp9_iht4x4_16_add_c(const tran_low_t *input, uint8_t *dest, int stride, int tx_type);
    \\#define vp9_iht4x4_16_add vp9_iht4x4_16_add_c
    \\
    \\void vp9_iht8x8_64_add_c(const tran_low_t *input, uint8_t *dest, int stride, int tx_type);
    \\#define vp9_iht8x8_64_add vp9_iht8x8_64_add_c
    \\
    \\void vp9_iht16x16_256_add_c(const tran_low_t *input, uint8_t *dest, int stride, int tx_type);
    \\#define vp9_iht16x16_256_add vp9_iht16x16_256_add_c
    \\
    \\void vp9_highbd_iht4x4_16_add_c(const tran_low_t *input, uint16_t *dest, int stride, int tx_type, int bd);
    \\#define vp9_highbd_iht4x4_16_add vp9_highbd_iht4x4_16_add_c
    \\
    \\void vp9_highbd_iht8x8_64_add_c(const tran_low_t *input, uint16_t *dest, int stride, int tx_type, int bd);
    \\#define vp9_highbd_iht8x8_64_add vp9_highbd_iht8x8_64_add_c
    \\
    \\void vp9_highbd_iht16x16_256_add_c(const tran_low_t *input, uint16_t *dest, int stride, int tx_type, int bd);
    \\#define vp9_highbd_iht16x16_256_add vp9_highbd_iht16x16_256_add_c
    \\
    \\void vp9_rtcd(void);
    \\
    \\#ifdef __cplusplus
    \\}
    \\#endif
    \\
    \\#include "vpx_config.h"
    \\
    \\#ifdef RTCD_C
    \\static void setup_rtcd_internal(void) {}
    \\#endif
    \\
    \\#endif /* VP9_RTCD_H */
;
