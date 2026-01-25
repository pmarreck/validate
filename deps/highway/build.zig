const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const highway_src = b.dependency("highway_src", .{});

    // Create static library for highway
    const lib = b.addLibrary(.{
        .name = "hwy",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // C++ flags for highway
    const cxxflags: []const []const u8 = &.{
        "-std=c++17",
        "-fvisibility=hidden",
        "-DHWY_COMPILE_ONLY_STATIC",
    };

    // Highway source files
    const hwy_sources: []const []const u8 = &.{
        "hwy/abort.cc",
        "hwy/aligned_allocator.cc",
        "hwy/nanobenchmark.cc",
        "hwy/per_target.cc",
        "hwy/print.cc",
        "hwy/targets.cc",
        "hwy/timer.cc",
    };

    // Contrib sources (needed by libjxl)
    const contrib_sources: []const []const u8 = &.{
        "hwy/contrib/sort/vqsort.cc",
    };

    lib.addCSourceFiles(.{
        .root = highway_src.path(""),
        .files = hwy_sources,
        .flags = cxxflags,
    });

    lib.addCSourceFiles(.{
        .root = highway_src.path(""),
        .files = contrib_sources,
        .flags = cxxflags,
    });

    // Add include paths
    lib.addIncludePath(highway_src.path(""));

    // Install headers (highway is largely header-only)
    lib.installHeadersDirectory(highway_src.path("hwy"), "hwy", .{});

    b.installArtifact(lib);
}
