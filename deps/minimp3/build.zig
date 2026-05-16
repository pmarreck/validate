const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const minimp3_src = b.dependency("minimp3_src", .{});

    // Create static library
    // minimp3 is header-only, but we compile it into a lib for linking
    const lib = b.addLibrary(.{
        .name = "minimp3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Generate implementation file
    const impl_file = b.addWriteFiles();
    _ = impl_file.add("minimp3_impl.c", minimp3_impl_c);

    // Common C flags
    const cflags: []const []const u8 = &.{
        "-fvisibility=hidden",
        "-DMINIMP3_IMPLEMENTATION",
    };

    // Add implementation source
    lib.root_module.addCSourceFile(.{
        .file = impl_file.getDirectory().path(b, "minimp3_impl.c"),
        .flags = cflags,
    });

    // Add include path to minimp3 header
    lib.root_module.addIncludePath(minimp3_src.path(""));

    // Install header
    lib.installHeader(minimp3_src.path("minimp3.h"), "minimp3.h");
    lib.installHeader(minimp3_src.path("minimp3_ex.h"), "minimp3_ex.h");

    b.installArtifact(lib);
}

const minimp3_impl_c =
    \\/* minimp3 implementation file */
    \\#define MINIMP3_IMPLEMENTATION
    \\#include "minimp3.h"
;
