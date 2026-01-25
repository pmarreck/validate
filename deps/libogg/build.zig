const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ogg_src = b.dependency("ogg_src", .{});

    // Create static library
    const lib = b.addLibrary(.{
        .name = "ogg",
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

    // OGG sources
    const ogg_sources: []const []const u8 = &.{
        "src/bitwise.c",
        "src/framing.c",
    };

    // Generate config_types.h
    const config_h = b.addWriteFiles();
    const config_types_path = config_h.add("ogg/config_types.h", config_types_h);
    lib.addIncludePath(config_h.getDirectory());

    // Add include paths
    lib.addIncludePath(ogg_src.path("include"));

    // Add sources
    lib.addCSourceFiles(.{
        .root = ogg_src.path(""),
        .files = ogg_sources,
        .flags = cflags,
    });

    // Install headers (including generated config_types.h)
    lib.installHeader(ogg_src.path("include/ogg/ogg.h"), "ogg/ogg.h");
    lib.installHeader(ogg_src.path("include/ogg/os_types.h"), "ogg/os_types.h");
    lib.installHeader(config_types_path, "ogg/config_types.h");

    b.installArtifact(lib);
}

const config_types_h =
    \\/* Auto-generated config_types.h for libogg */
    \\#ifndef __CONFIG_TYPES_H__
    \\#define __CONFIG_TYPES_H__
    \\
    \\#include <stdint.h>
    \\
    \\typedef int16_t ogg_int16_t;
    \\typedef uint16_t ogg_uint16_t;
    \\typedef int32_t ogg_int32_t;
    \\typedef uint32_t ogg_uint32_t;
    \\typedef int64_t ogg_int64_t;
    \\typedef uint64_t ogg_uint64_t;
    \\
    \\#endif
;
