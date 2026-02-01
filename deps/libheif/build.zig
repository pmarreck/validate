const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libheif_src = b.dependency("libheif_src", .{});

    // Get our decoder dependencies
    const libde265_dep = b.dependency("libde265", .{
        .target = target,
        .optimize = optimize,
    });
    const dav1d_dep = b.dependency("dav1d", .{
        .target = target,
        .optimize = optimize,
    });

    // Create static library
    const lib = b.addLibrary(.{
        .name = "heif",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // C++ flags - libheif requires C++20 for defaulted comparison operators and std::map::contains
    // -DNDEBUG disables C assertions which can cause SIGABRT on Intel Linux x86_64
    const cxxflags: []const []const u8 = &.{
        "-DLIBHEIF_EXPORTS",
        "-DHAVE_VISIBILITY",
        "-DHAVE_LIBDE265=1",
        "-DHAVE_DAV1D=1",
        "-std=c++20",
        "-fvisibility=hidden",
        "-DNDEBUG",
    };

    // Core sources
    const core_sources: []const []const u8 = &.{
        "libheif/bitstream.cc",
        "libheif/box.cc",
        "libheif/error.cc",
        "libheif/context.cc",
        "libheif/file.cc",
        "libheif/file_layout.cc",
        "libheif/pixelimage.cc",
        "libheif/plugin_registry.cc",
        "libheif/nclx.cc",
        "libheif/security_limits.cc",
        "libheif/init.cc",
        "libheif/logging.cc",
        "libheif/common_utils.cc",
        "libheif/region.cc",
        "libheif/brands.cc",
        "libheif/text.cc",
    };

    // API sources
    const api_sources: []const []const u8 = &.{
        "libheif/api/libheif/heif.cc",
        "libheif/api/libheif/heif_library.cc",
        "libheif/api/libheif/heif_image.cc",
        "libheif/api/libheif/heif_color.cc",
        "libheif/api/libheif/heif_regions.cc",
        "libheif/api/libheif/heif_plugin.cc",
        "libheif/api/libheif/heif_properties.cc",
        "libheif/api/libheif/heif_items.cc",
        "libheif/api/libheif/heif_sequences.cc",
        "libheif/api/libheif/heif_tai_timestamps.cc",
        "libheif/api/libheif/heif_brands.cc",
        "libheif/api/libheif/heif_metadata.cc",
        "libheif/api/libheif/heif_aux_images.cc",
        "libheif/api/libheif/heif_entity_groups.cc",
        "libheif/api/libheif/heif_security.cc",
        "libheif/api/libheif/heif_encoding.cc",
        "libheif/api/libheif/heif_decoding.cc",
        "libheif/api/libheif/heif_image_handle.cc",
        "libheif/api/libheif/heif_context.cc",
        "libheif/api/libheif/heif_tiling.cc",
        "libheif/api/libheif/heif_uncompressed.cc",
        "libheif/api/libheif/heif_text.cc",
    };

    // Codec sources
    const codec_sources: []const []const u8 = &.{
        "libheif/codecs/decoder.cc",
        "libheif/codecs/encoder.cc",
        "libheif/codecs/hevc_boxes.cc",
        "libheif/codecs/hevc_dec.cc",
        "libheif/codecs/hevc_enc.cc",
        "libheif/codecs/avif_enc.cc",
        "libheif/codecs/avif_dec.cc",
        "libheif/codecs/avif_boxes.cc",
        "libheif/codecs/jpeg_boxes.cc",
        "libheif/codecs/jpeg_dec.cc",
        "libheif/codecs/jpeg_enc.cc",
        "libheif/codecs/jpeg2000_dec.cc",
        "libheif/codecs/jpeg2000_enc.cc",
        "libheif/codecs/jpeg2000_boxes.cc",
        "libheif/codecs/vvc_dec.cc",
        "libheif/codecs/vvc_enc.cc",
        "libheif/codecs/vvc_boxes.cc",
        "libheif/codecs/avc_boxes.cc",
        "libheif/codecs/avc_dec.cc",
        "libheif/codecs/avc_enc.cc",
    };

    // Image item sources
    const image_item_sources: []const []const u8 = &.{
        "libheif/image-items/hevc.cc",
        "libheif/image-items/avif.cc",
        "libheif/image-items/jpeg.cc",
        "libheif/image-items/jpeg2000.cc",
        "libheif/image-items/vvc.cc",
        "libheif/image-items/avc.cc",
        "libheif/image-items/mask_image.cc",
        "libheif/image-items/image_item.cc",
        "libheif/image-items/grid.cc",
        "libheif/image-items/overlay.cc",
        "libheif/image-items/iden.cc",
        "libheif/image-items/tiled.cc",
    };

    // Color conversion sources
    const color_sources: []const []const u8 = &.{
        "libheif/color-conversion/colorconversion.cc",
        "libheif/color-conversion/rgb2yuv.cc",
        "libheif/color-conversion/rgb2yuv_sharp.cc",
        "libheif/color-conversion/yuv2rgb.cc",
        "libheif/color-conversion/rgb2rgb.cc",
        "libheif/color-conversion/monochrome.cc",
        "libheif/color-conversion/hdr_sdr.cc",
        "libheif/color-conversion/alpha.cc",
        "libheif/color-conversion/chroma_sampling.cc",
    };

    // Sequence sources
    const seq_sources: []const []const u8 = &.{
        "libheif/sequences/seq_boxes.cc",
        "libheif/sequences/chunk.cc",
        "libheif/sequences/track.cc",
        "libheif/sequences/track_visual.cc",
        "libheif/sequences/track_metadata.cc",
    };

    // Plugin sources (decoder plugins + required encoder plugins compiled in)
    const plugin_sources: []const []const u8 = &.{
        "libheif/plugins/decoder_libde265.cc",
        "libheif/plugins/decoder_dav1d.cc",
        "libheif/plugins/nalu_utils.cc",
        "libheif/plugins/encoder_mask.cc", // Required - dummy encoder always needed by libheif
    };

    // Generate heif_version.h in libheif/ subdirectory
    const version_h = b.addWriteFiles();
    _ = version_h.add("libheif/heif_version.h",
        \\#ifndef LIBHEIF_HEIF_VERSION_H
        \\#define LIBHEIF_HEIF_VERSION_H
        \\#define LIBHEIF_NUMERIC_VERSION ((1<<24) | (21<<16) | (1<<8) | 0)
        \\#define LIBHEIF_VERSION "1.21.1"
        \\#define LIBHEIF_PLUGIN_DIRECTORY ""
        \\#endif
    );
    lib.addIncludePath(version_h.getDirectory());

    // Add include paths
    lib.addIncludePath(libheif_src.path(""));
    lib.addIncludePath(libheif_src.path("libheif"));
    lib.addIncludePath(libheif_src.path("libheif/api"));
    lib.addIncludePath(libheif_src.path("libheif/api/libheif"));

    // Add decoder library include paths
    const libde265_lib = libde265_dep.artifact("de265");
    const dav1d_lib = dav1d_dep.artifact("dav1d");
    lib.addIncludePath(libde265_lib.getEmittedIncludeTree());
    lib.addIncludePath(dav1d_lib.getEmittedIncludeTree());

    // Link decoder libraries
    lib.linkLibrary(libde265_lib);
    lib.linkLibrary(dav1d_lib);

    // Add source files
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = core_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = api_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = codec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = image_item_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = color_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = seq_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = libheif_src.path(""),
        .files = plugin_sources,
        .flags = cxxflags,
    });

    // Install all public headers
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif.h"), "libheif/heif.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_library.h"), "libheif/heif_library.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_image.h"), "libheif/heif_image.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_color.h"), "libheif/heif_color.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_error.h"), "libheif/heif_error.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_plugin.h"), "libheif/heif_plugin.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_properties.h"), "libheif/heif_properties.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_regions.h"), "libheif/heif_regions.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_items.h"), "libheif/heif_items.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_sequences.h"), "libheif/heif_sequences.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_tai_timestamps.h"), "libheif/heif_tai_timestamps.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_brands.h"), "libheif/heif_brands.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_metadata.h"), "libheif/heif_metadata.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_aux_images.h"), "libheif/heif_aux_images.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_entity_groups.h"), "libheif/heif_entity_groups.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_security.h"), "libheif/heif_security.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_encoding.h"), "libheif/heif_encoding.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_decoding.h"), "libheif/heif_decoding.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_image_handle.h"), "libheif/heif_image_handle.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_context.h"), "libheif/heif_context.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_tiling.h"), "libheif/heif_tiling.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_uncompressed.h"), "libheif/heif_uncompressed.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_text.h"), "libheif/heif_text.h");
    lib.installHeader(libheif_src.path("libheif/api/libheif/heif_cxx.h"), "libheif/heif_cxx.h");

    // Also install the generated version header
    const version_h_install = b.addWriteFiles();
    const version_h_path = version_h_install.add("libheif/heif_version.h",
        \\#ifndef LIBHEIF_HEIF_VERSION_H
        \\#define LIBHEIF_HEIF_VERSION_H
        \\#define LIBHEIF_NUMERIC_VERSION ((1<<24) | (21<<16) | (1<<8) | 0)
        \\#define LIBHEIF_VERSION "1.21.1"
        \\#define LIBHEIF_PLUGIN_DIRECTORY ""
        \\#endif
    );
    lib.installHeader(version_h_path, "libheif/heif_version.h");

    b.installArtifact(lib);
}
