const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libde265_src = b.dependency("libde265_src", .{});

    const is_windows = target.result.os.tag == .windows;

    // Create static library
    const lib = b.addLibrary(.{
        .name = "de265",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // Platform-specific C++ flags
    // Note: -UNDEBUG enables assertions for debugging crashes on Linux
    const cxxflags: []const []const u8 = if (is_windows) &.{
        "-DLIBDE265_EXPORTS",
        "-DHAVE_STDINT_H",
        "-DHAVE_ALIGNED_ALLOC", // Use aligned_alloc on Windows
        "-fvisibility=hidden",
        "-fno-exceptions", // libde265 doesn't use exceptions
        "-UNDEBUG", // Enable assertions for debugging
    } else &.{
        "-DLIBDE265_EXPORTS",
        "-DHAVE_STDINT_H",
        "-DHAVE_POSIX_MEMALIGN", // Use posix_memalign on POSIX (macOS/Linux)
        "-fvisibility=hidden",
        "-fno-exceptions", // libde265 doesn't use exceptions
        "-UNDEBUG", // Enable assertions for debugging
    };

    // Core decoder sources
    const core_sources: []const []const u8 = &.{
        "libde265/alloc_pool.cc",
        "libde265/bitstream.cc",
        "libde265/cabac.cc",
        "libde265/configparam.cc",
        "libde265/contextmodel.cc",
        "libde265/de265.cc",
        "libde265/deblock.cc",
        "libde265/decctx.cc",
        "libde265/dpb.cc",
        "libde265/fallback-dct.cc",
        "libde265/fallback-motion.cc",
        "libde265/fallback.cc",
        "libde265/image-io.cc",
        "libde265/image.cc",
        "libde265/intrapred.cc",
        "libde265/md5.cc",
        "libde265/motion.cc",
        "libde265/nal-parser.cc",
        "libde265/nal.cc",
        "libde265/pps.cc",
        "libde265/quality.cc",
        "libde265/refpic.cc",
        "libde265/sao.cc",
        "libde265/scan.cc",
        "libde265/sei.cc",
        "libde265/slice.cc",
        "libde265/sps.cc",
        "libde265/threads.cc",
        "libde265/transform.cc",
        "libde265/util.cc",
        "libde265/visualize.cc",
        "libde265/vps.cc",
        "libde265/vui.cc",
    };

    // SSE-optimized sources for x86
    const sse_sources: []const []const u8 = &.{
        "libde265/x86/sse.cc",
        "libde265/x86/sse-dct.cc",
        "libde265/x86/sse-motion.cc",
    };

    // Add core sources
    lib.addCSourceFiles(.{
        .root = libde265_src.path(""),
        .files = core_sources,
        .flags = cxxflags,
    });

    // Add Windows condition variable implementation
    if (is_windows) {
        lib.addCSourceFiles(.{
            .root = libde265_src.path(""),
            .files = &.{"extra/win32cond.c"},
            .flags = &.{"-fvisibility=hidden"},
        });
        // Add extra/ to include path for win32cond.h
        lib.addIncludePath(libde265_src.path("extra"));
    }

    // Add SIMD sources based on target architecture and feature set
    //
    // IMPORTANT: SSE is disabled on Linux due to a bug in libde265 v1.0.15 that causes
    // General Protection Faults (GPF) during HEIC decoding. The crash occurs in
    // intra_prediction_angular() in intrapred.h during multi-threaded decode.
    // This affects both musl and glibc builds on x86_64 Linux.
    //
    // Upstream issue: https://github.com/strukturag/libde265/issues (needs filing)
    //
    // FUTURE OPTIMIZATION: Re-enable SSE on Linux once the upstream bug is fixed.
    // The fallback C++ code works correctly but is slower than SSE-optimized paths.
    // To re-enable, change `is_linux` below back to just checking for musl.
    const cpu_arch = target.result.cpu.arch;
    const cpu_features = target.result.cpu.features;
    const is_linux = target.result.os.tag == .linux;
    const has_sse4_1 = !is_linux and (cpu_arch == .x86_64 or cpu_arch == .x86) and
        std.Target.x86.featureSetHas(cpu_features, .sse4_1);

    if (has_sse4_1) {
        const sse_flags: []const []const u8 = if (is_windows) &.{
            "-DLIBDE265_EXPORTS",
            "-DHAVE_STDINT_H",
            "-DHAVE_ALIGNED_ALLOC",
            "-fvisibility=hidden",
            "-fno-exceptions",
            "-msse4.1",
            "-DHAVE_SSE4_1",
        } else &.{
            "-DLIBDE265_EXPORTS",
            "-DHAVE_STDINT_H",
            "-DHAVE_POSIX_MEMALIGN",
            "-fvisibility=hidden",
            "-fno-exceptions",
            "-msse4.1",
            "-DHAVE_SSE4_1",
        };

        lib.addCSourceFiles(.{
            .root = libde265_src.path(""),
            .files = sse_sources,
            .flags = sse_flags,
        });
    }

    // Add include paths
    lib.addIncludePath(libde265_src.path(""));
    lib.addIncludePath(libde265_src.path("libde265"));
    lib.addIncludePath(b.path(".")); // For generated de265-version.h

    // Generate de265-version.h in libde265/ subdirectory
    const version_h = b.addWriteFiles();
    _ = version_h.add("libde265/de265-version.h",
        \\#ifndef LIBDE265_VERSION_H
        \\#define LIBDE265_VERSION_H
        \\#define LIBDE265_NUMERIC_VERSION 0x01000f00
        \\#define LIBDE265_VERSION "1.0.15"
        \\#endif
    );
    lib.addIncludePath(version_h.getDirectory());

    // Install headers - both the main header and version header
    lib.installHeader(libde265_src.path("libde265/de265.h"), "libde265/de265.h");

    // Also install the generated version header
    const version_h_install = b.addWriteFiles();
    const version_h_path = version_h_install.add("libde265/de265-version.h",
        \\#ifndef LIBDE265_VERSION_H
        \\#define LIBDE265_VERSION_H
        \\#define LIBDE265_NUMERIC_VERSION 0x01000f00
        \\#define LIBDE265_VERSION "1.0.15"
        \\#endif
    );
    lib.installHeader(version_h_path, "libde265/de265-version.h");

    b.installArtifact(lib);
}
