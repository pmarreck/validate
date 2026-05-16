const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vorbis_src = b.dependency("vorbis_src", .{});
    const libogg_dep = b.dependency("libogg", .{
        .target = target,
        .optimize = optimize,
    });
    const libogg_lib = libogg_dep.artifact("ogg");

    // Create static library
    const lib = b.addLibrary(.{
        .name = "vorbis",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Common C flags
    const cflags: []const []const u8 = &.{
        "-fvisibility=hidden",
    };

    // Vorbis decoder sources (we only need the decoder for validation)
    const vorbis_sources: []const []const u8 = &.{
        "lib/analysis.c",
        "lib/bitrate.c",
        "lib/block.c",
        "lib/codebook.c",
        "lib/envelope.c",
        "lib/floor0.c",
        "lib/floor1.c",
        "lib/info.c",
        "lib/lookup.c",
        "lib/lpc.c",
        "lib/lsp.c",
        "lib/mapping0.c",
        "lib/mdct.c",
        "lib/psy.c",
        "lib/registry.c",
        "lib/res0.c",
        "lib/sharedbook.c",
        "lib/smallft.c",
        "lib/synthesis.c",
        "lib/vorbisfile.c",
        "lib/window.c",
    };

    // Add include paths
    lib.root_module.addIncludePath(vorbis_src.path("include"));
    lib.root_module.addIncludePath(vorbis_src.path("lib"));
    lib.root_module.addIncludePath(libogg_lib.getEmittedIncludeTree());

    // Add sources
    lib.root_module.addCSourceFiles(.{
        .root = vorbis_src.path(""),
        .files = vorbis_sources,
        .flags = cflags,
    });

    // Link libogg
    lib.root_module.linkLibrary(libogg_lib);

    // Install headers
    lib.installHeader(vorbis_src.path("include/vorbis/codec.h"), "vorbis/codec.h");
    lib.installHeader(vorbis_src.path("include/vorbis/vorbisfile.h"), "vorbis/vorbisfile.h");
    lib.installHeader(vorbis_src.path("include/vorbis/vorbisenc.h"), "vorbis/vorbisenc.h");

    b.installArtifact(lib);
}
