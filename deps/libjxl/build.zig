const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libjxl_src = b.dependency("libjxl_src", .{});

    // Get our dependencies
    const brotli_dep = b.dependency("brotli", .{
        .target = target,
        .optimize = optimize,
    });
    const highway_dep = b.dependency("highway", .{
        .target = target,
        .optimize = optimize,
    });

    // Create static library
    const lib = b.addLibrary(.{
        .name = "jxl",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // C++ flags for libjxl
    const cxxflags: []const []const u8 = &.{
        "-std=c++17",
        "-fvisibility=hidden",
        "-DJXL_INTERNAL_LIBRARY_BUILD",
        "-DJXL_STATIC_DEFINE",
        "-DJXL_THREADS_STATIC_DEFINE",
        // Disable external CMS (lcms2) - use internal sRGB fallback
        "-DJPEGXL_ENABLE_SKCMS=0",
        // Use scalar-only Highway to avoid SIMD template issues with Zig's clang
        "-DHWY_COMPILE_ONLY_SCALAR",
    };

    // Decoder sources (from jxl_lists.cmake JPEGXL_INTERNAL_DEC_SOURCES)
    const dec_sources: []const []const u8 = &.{
        "jxl/ac_strategy.cc",
        "jxl/alpha.cc",
        "jxl/ans_common.cc",
        "jxl/blending.cc",
        "jxl/box_content_decoder.cc",
        "jxl/chroma_from_luma.cc",
        "jxl/coeff_order.cc",
        "jxl/color_encoding_internal.cc",
        "jxl/compressed_dc.cc",
        "jxl/convolve_separable5.cc",
        "jxl/convolve_slow.cc",
        "jxl/convolve_symmetric3.cc",
        "jxl/convolve_symmetric5.cc",
        "jxl/dct_scales.cc",
        "jxl/dec_ans.cc",
        "jxl/dec_cache.cc",
        "jxl/dec_context_map.cc",
        "jxl/dec_external_image.cc",
        "jxl/dec_frame.cc",
        "jxl/dec_group.cc",
        "jxl/dec_group_border.cc",
        "jxl/dec_huffman.cc",
        "jxl/dec_modular.cc",
        "jxl/dec_noise.cc",
        "jxl/dec_patch_dictionary.cc",
        "jxl/dec_xyb.cc",
        "jxl/decode.cc",
        "jxl/decode_to_jpeg.cc",
        "jxl/entropy_coder.cc",
        "jxl/epf.cc",
        "jxl/fields.cc",
        "jxl/frame_header.cc",
        "jxl/headers.cc",
        "jxl/huffman_table.cc",
        "jxl/icc_codec.cc",
        "jxl/icc_codec_common.cc",
        "jxl/image.cc",
        "jxl/image_bundle.cc",
        "jxl/image_metadata.cc",
        "jxl/image_ops.cc",
        "jxl/loop_filter.cc",
        "jxl/luminance.cc",
        "jxl/memory_manager_internal.cc",
        "jxl/modular/encoding/dec_ma.cc",
        "jxl/modular/encoding/encoding.cc",
        "jxl/modular/modular_image.cc",
        "jxl/modular/transform/palette.cc",
        "jxl/modular/transform/rct.cc",
        "jxl/modular/transform/squeeze.cc",
        "jxl/modular/transform/transform.cc",
        "jxl/opsin_params.cc",
        "jxl/passes_state.cc",
        "jxl/quant_weights.cc",
        "jxl/quantizer.cc",
        "jxl/render_pipeline/low_memory_render_pipeline.cc",
        "jxl/render_pipeline/render_pipeline.cc",
        "jxl/render_pipeline/simple_render_pipeline.cc",
        "jxl/render_pipeline/stage_blending.cc",
        "jxl/render_pipeline/stage_chroma_upsampling.cc",
        "jxl/render_pipeline/stage_cms.cc",
        "jxl/render_pipeline/stage_epf.cc",
        "jxl/render_pipeline/stage_from_linear.cc",
        "jxl/render_pipeline/stage_gaborish.cc",
        "jxl/render_pipeline/stage_noise.cc",
        "jxl/render_pipeline/stage_patches.cc",
        "jxl/render_pipeline/stage_splines.cc",
        "jxl/render_pipeline/stage_spot.cc",
        "jxl/render_pipeline/stage_to_linear.cc",
        "jxl/render_pipeline/stage_tone_mapping.cc",
        "jxl/render_pipeline/stage_upsampling.cc",
        "jxl/render_pipeline/stage_write.cc",
        "jxl/render_pipeline/stage_xyb.cc",
        "jxl/render_pipeline/stage_ycbcr.cc",
        "jxl/simd_util.cc",
        "jxl/splines.cc",
        "jxl/toc.cc",
    };

    // JPEG reconstruction sources
    const jpeg_sources: []const []const u8 = &.{
        "jxl/jpeg/dec_jpeg_data.cc",
        "jxl/jpeg/dec_jpeg_data_writer.cc",
        "jxl/jpeg/jpeg_data.cc",
    };

    // CMS sources are DISABLED - we don't build with lcms2
    // libjxl will use internal sRGB fallback instead

    // Thread sources
    const thread_sources: []const []const u8 = &.{
        "threads/thread_parallel_runner.cc",
        "threads/thread_parallel_runner_internal.cc",
    };

    // Generate version header
    const version_h = b.addWriteFiles();
    _ = version_h.add("jxl/jxl_export.h",
        \\#ifndef JXL_JXL_EXPORT_H
        \\#define JXL_JXL_EXPORT_H
        \\#ifdef JXL_STATIC_DEFINE
        \\#  define JXL_EXPORT
        \\#  define JXL_NO_EXPORT
        \\#else
        \\#  define JXL_EXPORT __attribute__((visibility("default")))
        \\#  define JXL_NO_EXPORT __attribute__((visibility("hidden")))
        \\#endif
        \\#define JXL_DEPRECATED __attribute__ ((__deprecated__))
        \\#define JXL_DEPRECATED_EXPORT JXL_EXPORT JXL_DEPRECATED
        \\#endif
    );
    _ = version_h.add("jxl/version.h",
        \\#ifndef JXL_VERSION_H
        \\#define JXL_VERSION_H
        \\#define JPEGXL_MAJOR_VERSION 0
        \\#define JPEGXL_MINOR_VERSION 11
        \\#define JPEGXL_PATCH_VERSION 1
        \\#define JPEGXL_COMPUTE_NUMERIC_VERSION(major,minor,patch) ((major)*1000000+(minor)*1000+(patch))
        \\#define JPEGXL_NUMERIC_VERSION JPEGXL_COMPUTE_NUMERIC_VERSION(JPEGXL_MAJOR_VERSION,JPEGXL_MINOR_VERSION,JPEGXL_PATCH_VERSION)
        \\#endif
    );
    _ = version_h.add("jxl/jxl_threads_export.h",
        \\#ifndef JXL_THREADS_EXPORT_H
        \\#define JXL_THREADS_EXPORT_H
        \\#ifdef JXL_THREADS_STATIC_DEFINE
        \\#  define JXL_THREADS_EXPORT
        \\#else
        \\#  define JXL_THREADS_EXPORT __attribute__((visibility("default")))
        \\#endif
        \\#endif
    );
    _ = version_h.add("jxl/jxl_cms_export.h",
        \\#ifndef JXL_CMS_EXPORT_H
        \\#define JXL_CMS_EXPORT_H
        \\#ifdef JXL_CMS_STATIC_DEFINE
        \\#  define JXL_CMS_EXPORT
        \\#else
        \\#  define JXL_CMS_EXPORT __attribute__((visibility("default")))
        \\#endif
        \\#endif
    );
    lib.addIncludePath(version_h.getDirectory());

    // Install generated headers so they're available to consumers
    lib.installHeadersDirectory(version_h.getDirectory(), "", .{});

    // Add include paths - sources use "lib/jxl/..." paths so we need root
    lib.addIncludePath(libjxl_src.path(""));
    lib.addIncludePath(libjxl_src.path("lib"));
    lib.addIncludePath(libjxl_src.path("lib/include"));

    // Add dependency include paths and link
    const brotli_lib = brotli_dep.artifact("brotli");
    const highway_lib = highway_dep.artifact("hwy");
    lib.addIncludePath(brotli_lib.getEmittedIncludeTree());
    lib.addIncludePath(highway_lib.getEmittedIncludeTree());
    lib.linkLibrary(brotli_lib);
    lib.linkLibrary(highway_lib);

    // Add source files - all paths are relative to lib/ directory
    lib.addCSourceFiles(.{
        .root = libjxl_src.path("lib"),
        .files = dec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libjxl_src.path("lib"),
        .files = jpeg_sources,
        .flags = cxxflags,
    });
    // CMS sources omitted - using internal sRGB fallback
    lib.addCSourceFiles(.{
        .root = libjxl_src.path("lib"),
        .files = thread_sources,
        .flags = cxxflags,
    });

    // Install public headers
    lib.installHeader(libjxl_src.path("lib/include/jxl/decode.h"), "jxl/decode.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/decode_cxx.h"), "jxl/decode_cxx.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/types.h"), "jxl/types.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/memory_manager.h"), "jxl/memory_manager.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/parallel_runner.h"), "jxl/parallel_runner.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/codestream_header.h"), "jxl/codestream_header.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/color_encoding.h"), "jxl/color_encoding.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/cms_interface.h"), "jxl/cms_interface.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/stats.h"), "jxl/stats.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/thread_parallel_runner.h"), "jxl/thread_parallel_runner.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/thread_parallel_runner_cxx.h"), "jxl/thread_parallel_runner_cxx.h");
    lib.installHeader(libjxl_src.path("lib/include/jxl/cms.h"), "jxl/cms.h");

    b.installArtifact(lib);
}
