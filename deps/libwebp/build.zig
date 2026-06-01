const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libwebp_src = b.dependency("libwebp_src", .{});

    // Create static library for decoder
    const lib = b.addLibrary(.{
        .name = "webp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Common C flags
    const cflags: []const []const u8 = &.{
        "-DWEBP_USE_THREAD",
        "-fvisibility=hidden",
    };

    // Decoder source files
    const dec_sources: []const []const u8 = &.{
        "src/dec/alpha_dec.c",
        "src/dec/buffer_dec.c",
        "src/dec/frame_dec.c",
        "src/dec/idec_dec.c",
        "src/dec/io_dec.c",
        "src/dec/quant_dec.c",
        "src/dec/tree_dec.c",
        "src/dec/vp8_dec.c",
        "src/dec/vp8l_dec.c",
        "src/dec/webp_dec.c",
    };

    // DSP sources (core + portable fallbacks)
    const dsp_sources: []const []const u8 = &.{
        "src/dsp/alpha_processing.c",
        "src/dsp/cpu.c",
        "src/dsp/dec.c",
        "src/dsp/dec_clip_tables.c",
        "src/dsp/filters.c",
        "src/dsp/lossless.c",
        "src/dsp/rescaler.c",
        "src/dsp/upsampling.c",
        "src/dsp/yuv.c",
    };

    // SIMD-optimized DSP sources (will use runtime CPU detection)
    const dsp_simd_sources: []const []const u8 = &.{
        "src/dsp/alpha_processing_sse2.c",
        "src/dsp/alpha_processing_sse41.c",
        "src/dsp/dec_sse2.c",
        "src/dsp/dec_sse41.c",
        "src/dsp/filters_sse2.c",
        "src/dsp/lossless_sse2.c",
        "src/dsp/lossless_sse41.c",
        "src/dsp/rescaler_sse2.c",
        "src/dsp/upsampling_sse2.c",
        "src/dsp/upsampling_sse41.c",
        "src/dsp/yuv_sse2.c",
        "src/dsp/yuv_sse41.c",
    };

    // NEON sources for ARM
    const dsp_neon_sources: []const []const u8 = &.{
        "src/dsp/alpha_processing_neon.c",
        "src/dsp/dec_neon.c",
        "src/dsp/filters_neon.c",
        "src/dsp/lossless_neon.c",
        "src/dsp/rescaler_neon.c",
        "src/dsp/upsampling_neon.c",
        "src/dsp/yuv_neon.c",
    };

    // Utility sources
    const utils_sources: []const []const u8 = &.{
        "src/utils/bit_reader_utils.c",
        "src/utils/color_cache_utils.c",
        "src/utils/filters_utils.c",
        "src/utils/huffman_utils.c",
        "src/utils/palette.c",
        "src/utils/quant_levels_dec_utils.c",
        "src/utils/random_utils.c",
        "src/utils/rescaler_utils.c",
        "src/utils/thread_utils.c",
        "src/utils/utils.c",
    };

    // Demux sources — needed to walk ANMF animation frames for per-frame
    // validation of animated WebP (VP8X+ANIM). Depends only on the decoder
    // + utils units already built here.
    const demux_sources: []const []const u8 = &.{
        "src/demux/demux.c",
    };

    // Add all sources
    lib.root_module.addCSourceFiles(.{
        .root = libwebp_src.path(""),
        .files = dec_sources,
        .flags = cflags,
    });

    lib.root_module.addCSourceFiles(.{
        .root = libwebp_src.path(""),
        .files = dsp_sources,
        .flags = cflags,
    });

    lib.root_module.addCSourceFiles(.{
        .root = libwebp_src.path(""),
        .files = utils_sources,
        .flags = cflags,
    });

    lib.root_module.addCSourceFiles(.{
        .root = libwebp_src.path(""),
        .files = demux_sources,
        .flags = cflags,
    });

    // Add SIMD sources based on target architecture
    const cpu_arch = target.result.cpu.arch;
    if (cpu_arch == .x86_64 or cpu_arch == .x86) {
        lib.root_module.addCSourceFiles(.{
            .root = libwebp_src.path(""),
            .files = dsp_simd_sources,
            .flags = cflags,
        });
    } else if (cpu_arch == .aarch64 or cpu_arch == .arm) {
        lib.root_module.addCSourceFiles(.{
            .root = libwebp_src.path(""),
            .files = dsp_neon_sources,
            .flags = cflags,
        });
    }

    // Add include paths
    lib.root_module.addIncludePath(libwebp_src.path(""));
    lib.root_module.addIncludePath(libwebp_src.path("src"));

    // Install headers
    lib.installHeader(libwebp_src.path("src/webp/decode.h"), "webp/decode.h");
    lib.installHeader(libwebp_src.path("src/webp/types.h"), "webp/types.h");
    lib.installHeader(libwebp_src.path("src/webp/demux.h"), "webp/demux.h");
    lib.installHeader(libwebp_src.path("src/webp/mux_types.h"), "webp/mux_types.h");

    b.installArtifact(lib);

    // Export module for Zig code that wants to use the C API
    _ = b.addModule("webp", .{
        .root_source_file = b.path("webp.zig"),
        .target = target,
        .optimize = optimize,
    });
}
