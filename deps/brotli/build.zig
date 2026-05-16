const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const brotli_src = b.dependency("brotli_src", .{});

    // Create static library for brotli common + decoder
    const lib = b.addLibrary(.{
        .name = "brotli",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const cflags: []const []const u8 = &.{
        "-fvisibility=hidden",
    };

    // Common sources
    const common_sources: []const []const u8 = &.{
        "c/common/constants.c",
        "c/common/context.c",
        "c/common/dictionary.c",
        "c/common/platform.c",
        "c/common/shared_dictionary.c",
        "c/common/transform.c",
    };

    // Decoder sources
    const dec_sources: []const []const u8 = &.{
        "c/dec/bit_reader.c",
        "c/dec/decode.c",
        "c/dec/huffman.c",
        "c/dec/state.c",
    };

    // Encoder sources (needed for some libjxl features)
    const enc_sources: []const []const u8 = &.{
        "c/enc/backward_references.c",
        "c/enc/backward_references_hq.c",
        "c/enc/bit_cost.c",
        "c/enc/block_splitter.c",
        "c/enc/brotli_bit_stream.c",
        "c/enc/cluster.c",
        "c/enc/command.c",
        "c/enc/compound_dictionary.c",
        "c/enc/compress_fragment.c",
        "c/enc/compress_fragment_two_pass.c",
        "c/enc/dictionary_hash.c",
        "c/enc/encode.c",
        "c/enc/encoder_dict.c",
        "c/enc/entropy_encode.c",
        "c/enc/fast_log.c",
        "c/enc/histogram.c",
        "c/enc/literal_cost.c",
        "c/enc/memory.c",
        "c/enc/metablock.c",
        "c/enc/static_dict.c",
        "c/enc/utf8_util.c",
    };

    lib.root_module.addCSourceFiles(.{
        .root = brotli_src.path(""),
        .files = common_sources,
        .flags = cflags,
    });

    lib.root_module.addCSourceFiles(.{
        .root = brotli_src.path(""),
        .files = dec_sources,
        .flags = cflags,
    });

    lib.root_module.addCSourceFiles(.{
        .root = brotli_src.path(""),
        .files = enc_sources,
        .flags = cflags,
    });

    // Add include paths
    lib.root_module.addIncludePath(brotli_src.path("c/include"));

    // Install headers
    lib.installHeader(brotli_src.path("c/include/brotli/decode.h"), "brotli/decode.h");
    lib.installHeader(brotli_src.path("c/include/brotli/encode.h"), "brotli/encode.h");
    lib.installHeader(brotli_src.path("c/include/brotli/port.h"), "brotli/port.h");
    lib.installHeader(brotli_src.path("c/include/brotli/shared_dictionary.h"), "brotli/shared_dictionary.h");
    lib.installHeader(brotli_src.path("c/include/brotli/types.h"), "brotli/types.h");

    b.installArtifact(lib);
}
