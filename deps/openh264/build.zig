const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openh264_src = b.dependency("openh264_src", .{});

    // Create static library
    const lib = b.addLibrary(.{
        .name = "openh264",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // C++ flags for OpenH264
    const cxxflags: []const []const u8 = &.{
        "-DHAVE_PTHREAD",
        "-fvisibility=hidden",
        "-fno-strict-aliasing",
        "-std=c++11",
    };

    // Decoder core sources (codec/decoder/core/src/)
    const decoder_core_sources: []const []const u8 = &.{
        "codec/decoder/core/src/au_parser.cpp",
        "codec/decoder/core/src/bit_stream.cpp",
        "codec/decoder/core/src/cabac_decoder.cpp",
        "codec/decoder/core/src/deblocking.cpp",
        "codec/decoder/core/src/decode_mb_aux.cpp",
        "codec/decoder/core/src/decode_slice.cpp",
        "codec/decoder/core/src/decoder.cpp",
        "codec/decoder/core/src/decoder_core.cpp",
        "codec/decoder/core/src/decoder_data_tables.cpp",
        "codec/decoder/core/src/error_concealment.cpp",
        "codec/decoder/core/src/fmo.cpp",
        "codec/decoder/core/src/get_intra_predictor.cpp",
        "codec/decoder/core/src/manage_dec_ref.cpp",
        "codec/decoder/core/src/memmgr_nal_unit.cpp",
        "codec/decoder/core/src/mv_pred.cpp",
        "codec/decoder/core/src/parse_mb_syn_cabac.cpp",
        "codec/decoder/core/src/parse_mb_syn_cavlc.cpp",
        "codec/decoder/core/src/pic_queue.cpp",
        "codec/decoder/core/src/rec_mb.cpp",
        "codec/decoder/core/src/wels_decoder_thread.cpp",
    };

    // Decoder plus sources (codec/decoder/plus/src/)
    const decoder_plus_sources: []const []const u8 = &.{
        "codec/decoder/plus/src/welsDecoderExt.cpp",
    };

    // Common sources (codec/common/src/)
    const common_sources: []const []const u8 = &.{
        "codec/common/src/WelsTaskThread.cpp",
        "codec/common/src/WelsThread.cpp",
        "codec/common/src/WelsThreadLib.cpp",
        "codec/common/src/WelsThreadPool.cpp",
        "codec/common/src/common_tables.cpp",
        "codec/common/src/copy_mb.cpp",
        "codec/common/src/cpu.cpp",
        "codec/common/src/crt_util_safe_x.cpp",
        "codec/common/src/deblocking_common.cpp",
        "codec/common/src/expand_pic.cpp",
        "codec/common/src/intra_pred_common.cpp",
        "codec/common/src/mc.cpp",
        "codec/common/src/memory_align.cpp",
        "codec/common/src/sad_common.cpp",
        "codec/common/src/utils.cpp",
        "codec/common/src/welsCodecTrace.cpp",
    };

    // Add include paths
    // Note: OpenH264 headers include each other without path prefixes (e.g., #include "codec_def.h")
    lib.addIncludePath(openh264_src.path("codec/api/wels"));
    lib.addIncludePath(openh264_src.path("codec/common/inc"));
    lib.addIncludePath(openh264_src.path("codec/decoder/core/inc"));
    lib.addIncludePath(openh264_src.path("codec/decoder/plus/inc"));

    // Add source files
    lib.addCSourceFiles(.{
        .root = openh264_src.path(""),
        .files = decoder_core_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = openh264_src.path(""),
        .files = decoder_plus_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = openh264_src.path(""),
        .files = common_sources,
        .flags = cxxflags,
    });

    // Install public API headers
    lib.installHeader(openh264_src.path("codec/api/wels/codec_api.h"), "wels/codec_api.h");
    lib.installHeader(openh264_src.path("codec/api/wels/codec_app_def.h"), "wels/codec_app_def.h");
    lib.installHeader(openh264_src.path("codec/api/wels/codec_def.h"), "wels/codec_def.h");
    lib.installHeader(openh264_src.path("codec/api/wels/codec_ver.h"), "wels/codec_ver.h");

    b.installArtifact(lib);
}
