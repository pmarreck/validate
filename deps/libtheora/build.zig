const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const theora_src = b.dependency("theora_src", .{});
    const libogg_dep = b.dependency("libogg", .{
        .target = target,
        .optimize = optimize,
    });
    const libogg_lib = libogg_dep.artifact("ogg");

    // Create static library (decoder-only)
    const lib = b.addLibrary(.{
        .name = "theora",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Theora is a C99 library, but some versions of gcc/clang default to modes
    // that expose conversion warnings/errors. We only need the decoder subset.
    //
    // Encoder sources are intentionally excluded. apiwrapper.c / info.c /
    // internal.c / state.c / bitpack.c / huffdec.c / idct.c / quant.c /
    // fragment.c / decode.c / decinfo.c / decapiwrapper.c / dequant.c are the
    // decoder core. encoder_disabled.c provides stubbed encoder entry points
    // so any encoder API calls return TH_EIMPL without pulling in the encoder.
    const cflags: []const []const u8 = &.{
        "-fvisibility=hidden",
        // Theora's asm guards use `#if defined(OC_*_ASM)`, not value checks,
        // so we simply don't define them. Keeping NDEBUG on for perf.
        "-DNDEBUG",
    };

    // Decoder-only C sources (from xiph/theora 1.2.0 lib/)
    const theora_sources: []const []const u8 = &.{
        "lib/apiwrapper.c",
        "lib/bitpack.c",
        "lib/decapiwrapper.c",
        "lib/decinfo.c",
        "lib/decode.c",
        "lib/dequant.c",
        "lib/fragment.c",
        "lib/huffdec.c",
        "lib/idct.c",
        "lib/info.c",
        "lib/internal.c",
        "lib/quant.c",
        "lib/state.c",
        // Stubs return TH_EIMPL for encoder calls so we don't need encoder code.
        "lib/encoder_disabled.c",
    };

    lib.addIncludePath(theora_src.path("include"));
    lib.addIncludePath(theora_src.path("lib"));
    lib.addIncludePath(libogg_lib.getEmittedIncludeTree());

    lib.addCSourceFiles(.{
        .root = theora_src.path(""),
        .files = theora_sources,
        .flags = cflags,
    });

    lib.linkLibrary(libogg_lib);

    // Install headers (public API only)
    lib.installHeader(theora_src.path("include/theora/codec.h"), "theora/codec.h");
    lib.installHeader(theora_src.path("include/theora/theora.h"), "theora/theora.h");
    lib.installHeader(theora_src.path("include/theora/theoradec.h"), "theora/theoradec.h");
    lib.installHeader(theora_src.path("include/theora/theoraenc.h"), "theora/theoraenc.h");

    b.installArtifact(lib);
}
