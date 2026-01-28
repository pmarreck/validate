const std = @import("std");
const LibtoolStep = @import("src/build/LibtoolStep.zig");

fn debugEnvEnabled(b: *std.Build) bool {
    const raw = std.process.getEnvVarOwned(b.allocator, "DEBUG") catch return false;
    defer b.allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return false;

    if (std.mem.eql(u8, trimmed, "1")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "on")) return true;

    return false;
}

pub fn build(b: *std.Build) void {
    // Standard target options - allows cross-compilation via -Dtarget=
    // Examples:
    //   zig build                          # native (current platform)
    //   zig build -Dtarget=x86_64-linux-gnu    # Linux x86_64
    //   zig build -Dtarget=x86_64-windows-gnu  # Windows x86_64
    //   zig build -Dtarget=aarch64-linux-gnu   # Linux ARM64
    var target_query = b.standardTargetOptionsQueryOnly(.{});

    // When targeting macOS, apply minimum deployment version for Xcode compatibility
    if (target_query.os_tag == null or target_query.os_tag == .macos) {
        const macos_min_major = b.option(u16, "macos-min-major", "macOS minimum deployment target major version (default: 14)") orelse 14;
        const macos_min_minor = b.option(u16, "macos-min-minor", "macOS minimum deployment target minor version (default: 0)") orelse 0;

        // Only set macOS version if we're actually targeting macOS (native or explicit)
        if (target_query.os_tag == .macos or (target_query.os_tag == null and @import("builtin").os.tag == .macos)) {
            target_query.os_version_min = .{ .semver = .{
                .major = macos_min_major,
                .minor = macos_min_minor,
                .patch = 0,
            } };
        }
    }

    const target = b.resolveTargetQuery(target_query);

    const optimize = b.standardOptimizeOption(.{});
    const deps_debug = debugEnvEnabled(b);
    const deps_optimize: std.builtin.OptimizeMode = if (deps_debug) optimize else .ReleaseFast;

    // External dependencies from build.zig.zon
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const toml_mod = toml_dep.module("toml");

    // Zigimg dependency for image format deep validation
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const zigimg_mod = zigimg_dep.module("zigimg");

    // zig-xml dependency for XML validation (0BSD license, pure Zig)
    const zigxml_dep = b.dependency("zig-xml", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const zigxml_mod = zigxml_dep.module("xml");

    // Libwebp dependency for WebP deep validation (built from source)
    const libwebp_dep = b.dependency("libwebp", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libwebp_lib = libwebp_dep.artifact("webp");

    // Libheif dependency for HEIC/AVIF deep validation (built from source with libde265 and dav1d)
    const libheif_dep = b.dependency("libheif", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libheif_lib = libheif_dep.artifact("heif");

    // OpenH264 dependency for H.264/AVC video deep validation (BSD-2, Cisco pays MPEG-LA royalties)
    const openh264_dep = b.dependency("openh264", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const openh264_lib = openh264_dep.artifact("openh264");

    // libde265 and dav1d for direct include paths (used by video_validator.zig @cImport)
    const libde265_dep = b.dependency("libde265", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libde265_lib = libde265_dep.artifact("de265");

    const dav1d_dep = b.dependency("dav1d", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const dav1d_lib = dav1d_dep.artifact("dav1d");

    // Libopus for Opus audio deep validation (BSD-3, IETF standard)
    const libopus_dep = b.dependency("libopus", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libopus_lib = libopus_dep.artifact("opus");

    // libogg for OGG container support (required by libvorbis)
    // Always ReleaseFast to avoid Zig's overflow checks triggering on libogg's bit manipulation
    const libogg_dep = b.dependency("libogg", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libogg_lib = libogg_dep.artifact("ogg");

    // Libvorbis for Vorbis audio deep validation (BSD-3, Xiph.org)
    // Always ReleaseFast to avoid Zig's overflow checks triggering on libvorbis
    const libvorbis_dep = b.dependency("libvorbis", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libvorbis_lib = libvorbis_dep.artifact("vorbis");

    // minimp3 for MP3 audio deep validation (Public Domain, header-only)
    const minimp3_dep = b.dependency("minimp3", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const minimp3_lib = minimp3_dep.artifact("minimp3");

    // libfdk-aac for AAC audio deep validation (FDK License)
    const libfdkaac_dep = b.dependency("libfdk-aac", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libfdkaac_lib = libfdkaac_dep.artifact("fdk-aac");

    // libvpx for VP8/VP9 video deep validation (BSD-3, WebM Project)
    const libvpx_dep = b.dependency("libvpx", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libvpx_lib = libvpx_dep.artifact("vpx");

    // OpenJPEG for JPEG2000 decode validation (BSD-2, used in PDFs and DCPs)
    const openjpeg_dep = b.dependency("openjpeg", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const openjpeg_lib = openjpeg_dep.artifact("openjp2");

    // libjxl for JPEG-XL decode validation (BSD-3, Google reference implementation)
    const libjxl_dep = b.dependency("libjxl", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libjxl_lib = libjxl_dep.artifact("jxl");

    // Brotli for .br file decompression validation (MIT, Google)
    const brotli_dep = b.dependency("brotli", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const brotli_lib = brotli_dep.artifact("brotli");

    // PCRE2 for regex/glob pattern matching (BSD, renerocksai/pcre2 Zig build)
    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = deps_optimize,
        .linkage = .static, // Force static linking for cross-platform builds
        .@"code-unit-width" = .@"8", // UTF-8 support
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    // libjpeg-turbo for JPEG decode validation (BSD-3, chearon/libjpeg-turbo Zig build)
    const libjpeg_turbo_dep = b.dependency("libjpeg_turbo", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libjpeg_lib = libjpeg_turbo_dep.artifact("libjpeg_turbo");

    // zlib for deflate compression/decompression (zlib license, allyourcodebase/zlib)
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const zlib_lib = zlib_dep.artifact("z");

    // sqlite3 for deep database validation (public domain, allyourcodebase/sqlite3)
    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const sqlite3_lib = sqlite3_dep.artifact("sqlite3");

    // libopenmpt for tracker format validation (BSD-3, pmarreck/openmpt Zig build)
    const libopenmpt_dep = b.dependency("libopenmpt", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libopenmpt_lib = libopenmpt_dep.artifact("openmpt");

    // Core module - validation logic
    const core_mod = b.addModule("validate_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod }, // External TOML parser for validation
            .{ .name = "zigimg", .module = zigimg_mod }, // Image format decoding for deep validation
            .{ .name = "xml", .module = zigxml_mod }, // XML validation (0BSD, ianprime0509/zig-xml)
        },
    });

    // Add PCRE2 include path (from Zig-built dependency)
    core_mod.addIncludePath(pcre2_lib.getEmittedIncludeTree());

    // Add libjpeg include path (from Zig-built dependency)
    core_mod.addIncludePath(libjpeg_lib.getEmittedIncludeTree());

    // Add libwebp include path (from Zig-built dependency)
    core_mod.addIncludePath(libwebp_lib.getEmittedIncludeTree());

    // Add libheif include path (from Zig-built dependency)
    core_mod.addIncludePath(libheif_lib.getEmittedIncludeTree());

    // Add OpenH264 include path (from Zig-built dependency)
    core_mod.addIncludePath(openh264_lib.getEmittedIncludeTree());

    // Add libde265 and dav1d include paths (for video_validator.zig @cImport)
    core_mod.addIncludePath(libde265_lib.getEmittedIncludeTree());
    core_mod.addIncludePath(dav1d_lib.getEmittedIncludeTree());

    // Add libopus include path (for opus_validator.zig @cImport)
    core_mod.addIncludePath(libopus_lib.getEmittedIncludeTree());

    // Add libogg include path (required by libvorbis for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libogg_lib.getEmittedIncludeTree());

    // Add libvorbis include path (for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libvorbis_lib.getEmittedIncludeTree());

    // Add minimp3 include path (for mp3_decode_validator.zig @cImport)
    core_mod.addIncludePath(minimp3_lib.getEmittedIncludeTree());

    // Add libfdk-aac include path (for aac_validator.zig @cImport)
    core_mod.addIncludePath(libfdkaac_lib.getEmittedIncludeTree());

    // Add libvpx include path (for vp8_vp9_validator.zig @cImport)
    core_mod.addIncludePath(libvpx_lib.getEmittedIncludeTree());

    // Add OpenJPEG include path (for jpeg2000_validator.zig @cImport)
    core_mod.addIncludePath(openjpeg_lib.getEmittedIncludeTree());

    // Add libjxl include path (for jxl_validator.zig @cImport)
    core_mod.addIncludePath(libjxl_lib.getEmittedIncludeTree());

    // Add brotli include path (for brotli_validator.zig @cImport)
    core_mod.addIncludePath(brotli_lib.getEmittedIncludeTree());

    // Add libopenmpt include path (for libopenmpt.zig @cImport)
    core_mod.addIncludePath(libopenmpt_lib.getEmittedIncludeTree());

    // Add sqlite3 include path (Zig-built dependency)
    core_mod.addIncludePath(sqlite3_lib.getEmittedIncludeTree());

    // Add zlib include path (Zig-built dependency, used in zlib.zig wrapper)
    core_mod.addIncludePath(zlib_lib.getEmittedIncludeTree());

    // FFI module - C ABI exports
    const ffi_mod = b.addModule("validate_ffi", .{
        .root_source_file = b.path("ffi/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    // Static library for FFI
    const lib = b.addLibrary(.{
        .name = "validate_core",
        .root_module = ffi_mod,
        .linkage = .static,
    });
    // Link PCRE2 into the static library (Zig-built)
    lib.linkLibrary(pcre2_lib);
    // Link zlib for robust deflate decompression (Zig-built, replaces buggy Zig std.compress.flate)
    lib.linkLibrary(zlib_lib);
    // Link libjpeg for JPEG deep validation (Zig-built)
    lib.linkLibrary(libjpeg_lib);
    // Link libwebp for WebP deep validation (built from source)
    lib.linkLibrary(libwebp_lib);
    // Link libheif for HEIC/AVIF deep validation (built from source)
    lib.linkLibrary(libheif_lib);
    // Link OpenH264 for H.264/AVC video deep validation
    lib.linkLibrary(openh264_lib);
    // Link libopus for Opus audio deep validation
    lib.linkLibrary(libopus_lib);
    // Link libogg for OGG container support (required by libvorbis)
    lib.linkLibrary(libogg_lib);
    // Link libvorbis for Vorbis audio deep validation
    lib.linkLibrary(libvorbis_lib);
    // Link minimp3 for MP3 audio deep validation
    lib.linkLibrary(minimp3_lib);
    // Link libfdk-aac for AAC audio deep validation
    lib.linkLibrary(libfdkaac_lib);
    // Link libvpx for VP8/VP9 video deep validation
    lib.linkLibrary(libvpx_lib);
    // Link OpenJPEG for JPEG2000 decode validation
    lib.linkLibrary(openjpeg_lib);
    // Link libjxl for JPEG-XL decode validation
    lib.linkLibrary(libjxl_lib);
    // Link brotli for .br file decompression validation
    lib.linkLibrary(brotli_lib);
    // Link libopenmpt for tracker format (MOD/XM/IT/S3M) deep validation (Zig-built)
    lib.linkLibrary(libopenmpt_lib);
    lib.linkLibC();
    lib.linkLibCpp(); // Required for libheif, libjxl, libopenmpt (C++ libraries)
    lib.installHeadersDirectory(b.path("ffi"), "", .{
        .include_extensions = &.{".h"},
    });

    // On macOS, use libtool to bundle all dependencies into a single "fat" static library
    // This is required for Xcode integration since static libraries don't embed their dependencies
    const is_macos = target.result.os.tag == .macos;
    if (is_macos) {
        // Collect all static library dependencies for bundling
        const lib_sources: []const std.Build.LazyPath = &.{
            lib.getEmittedBin(),
            pcre2_lib.getEmittedBin(),
            zlib_lib.getEmittedBin(),
            libjpeg_lib.getEmittedBin(),
            libwebp_lib.getEmittedBin(),
            libheif_lib.getEmittedBin(),
            openh264_lib.getEmittedBin(),
            libopus_lib.getEmittedBin(),
            libogg_lib.getEmittedBin(),
            libvorbis_lib.getEmittedBin(),
            minimp3_lib.getEmittedBin(),
            libfdkaac_lib.getEmittedBin(),
            libvpx_lib.getEmittedBin(),
            openjpeg_lib.getEmittedBin(),
            libjxl_lib.getEmittedBin(),
            brotli_lib.getEmittedBin(),
            libopenmpt_lib.getEmittedBin(),
            libde265_lib.getEmittedBin(),
            dav1d_lib.getEmittedBin(),
        };

        const libtool = LibtoolStep.create(b, .{
            .name = "validate_core",
            .out_name = "libvalidate_core.a",
            .sources = lib_sources,
        });

        // Install the bundled library
        const install_bundled = b.addInstallFileWithDir(
            libtool.output,
            .lib,
            "libvalidate_core.a",
        );
        install_bundled.step.dependOn(libtool.step);
        b.getInstallStep().dependOn(&install_bundled.step);
    } else {
        // On non-macOS platforms, install the unbundled library
        // (consumers will need to link dependencies separately)
        b.installArtifact(lib);
    }

    // Shared library (optional)
    const lib_shared = b.addLibrary(.{
        .name = "validate_core",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    // Link PCRE2 into the shared library (Zig-built)
    lib_shared.linkLibrary(pcre2_lib);
    lib_shared.linkLibrary(zlib_lib);
    // Link libjpeg for JPEG deep validation (Zig-built)
    lib_shared.linkLibrary(libjpeg_lib);
    // Link libwebp for WebP deep validation (built from source)
    lib_shared.linkLibrary(libwebp_lib);
    // Link libheif for HEIC/AVIF deep validation (built from source)
    lib_shared.linkLibrary(libheif_lib);
    // Link OpenH264 for H.264/AVC video deep validation
    lib_shared.linkLibrary(openh264_lib);
    // Link libopus for Opus audio deep validation
    lib_shared.linkLibrary(libopus_lib);
    // Link libogg for OGG container support (required by libvorbis)
    lib_shared.linkLibrary(libogg_lib);
    // Link libvorbis for Vorbis audio deep validation
    lib_shared.linkLibrary(libvorbis_lib);
    // Link minimp3 for MP3 audio deep validation
    lib_shared.linkLibrary(minimp3_lib);
    // Link libfdk-aac for AAC audio deep validation
    lib_shared.linkLibrary(libfdkaac_lib);
    // Link libvpx for VP8/VP9 video deep validation
    lib_shared.linkLibrary(libvpx_lib);
    // Link OpenJPEG for JPEG2000 decode validation
    lib_shared.linkLibrary(openjpeg_lib);
    // Link libjxl for JPEG-XL decode validation
    lib_shared.linkLibrary(libjxl_lib);
    // Link brotli for .br file decompression validation
    lib_shared.linkLibrary(brotli_lib);
    // Link libopenmpt for tracker format (MOD/XM/IT/S3M) deep validation (Zig-built)
    lib_shared.linkLibrary(libopenmpt_lib);
    lib_shared.linkLibC();
    lib_shared.linkLibCpp(); // Required for libheif, libjxl, libopenmpt (C++ libraries)
    lib_shared.installHeadersDirectory(b.path("ffi"), "", .{
        .include_extensions = &.{".h"},
    });
    const install_shared = b.addInstallArtifact(lib_shared, .{});
    const shared_step = b.step("shared", "Build shared library");
    shared_step.dependOn(&install_shared.step);

    // C CLI (FFI-based) - canonical CLI
    const cli_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_c_mod.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    cli_c_mod.addIncludePath(b.path("ffi"));

    const cli_c = b.addExecutable(.{
        .name = "validate",
        .root_module = cli_c_mod,
    });
    cli_c.linkLibrary(lib);
    cli_c.linkLibrary(sqlite3_lib);

    const install_cli = b.addInstallArtifact(cli_c, .{});
    b.getInstallStep().dependOn(&install_cli.step);

    // Run CLI
    const run_cli = b.addRunArtifact(cli_c);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }
    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cli.step);

    const bench_step = b.step("bench", "Build benchmarks");

    // Bzip2 benchmark - compares Zig implementation vs system bzip2
    const bench_bzip2_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench/bench_bzip2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    const bench_bzip2 = b.addExecutable(.{
        .name = "bench-bzip2",
        .root_module = bench_bzip2_mod,
    });
    // No external libs needed - pure Zig bzip2

    const install_bench_bzip2 = b.addInstallArtifact(bench_bzip2, .{});
    bench_step.dependOn(&install_bench_bzip2.step);

    // Fuzzing
    const fuzz_bzip2_mod = b.createModule(.{
        .root_source_file = b.path("fuzz/fuzz_stream_bzip2.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    const fuzz_bzip2 = b.addExecutable(.{
        .name = "fuzz-stream-bzip2",
        .root_module = fuzz_bzip2_mod,
    });
    // Link required libraries for core module dependencies (all Zig-built)
    fuzz_bzip2.linkLibC();
    fuzz_bzip2.linkLibrary(sqlite3_lib);
    fuzz_bzip2.linkLibrary(pcre2_lib);
    fuzz_bzip2.linkLibrary(libjpeg_lib);
    fuzz_bzip2.linkLibrary(zlib_lib);

    const install_fuzz_bzip2 = b.addInstallArtifact(fuzz_bzip2, .{});
    const fuzz_step = b.step("fuzz", "Build fuzzers");
    fuzz_step.dependOn(&install_fuzz_bzip2.step);

    // Tests
    const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this text");
    var test_filters: []const []const u8 = &.{};
    if (test_filter) |filter| {
        test_filters = &.{filter};
    }
    const windows_test_wine = b.option([]const u8, "windows-test-wine", "Path to CrossOver wine for Windows tests");
    const windows_test_bottle = b.option([]const u8, "windows-test-bottle", "CrossOver bottle name for Windows tests") orelse "windows-dev-test";

    const core_tests = b.addTest(.{
        .root_module = core_mod,
        .filters = test_filters,
    });
    // Link PCRE2 for tests (Zig-built)
    core_tests.linkLibrary(pcre2_lib);
    core_tests.linkLibrary(zlib_lib);
    // Link libjpeg for JPEG deep validation tests (Zig-built)
    core_tests.linkLibrary(libjpeg_lib);
    // Link SQLite for deep validation tests (Zig-built)
    core_tests.linkLibrary(sqlite3_lib);
    // Link libwebp for WebP deep validation tests
    core_tests.linkLibrary(libwebp_lib);
    // Link libheif for HEIC/AVIF deep validation tests (includes libde265 and dav1d)
    core_tests.linkLibrary(libheif_lib);
    // Link OpenH264 for H.264 video deep validation tests
    core_tests.linkLibrary(openh264_lib);
    // Link libopus for Opus audio deep validation tests
    core_tests.linkLibrary(libopus_lib);
    // Link libogg for OGG container support tests (required by libvorbis)
    core_tests.linkLibrary(libogg_lib);
    // Link libvorbis for Vorbis audio deep validation tests
    core_tests.linkLibrary(libvorbis_lib);
    // Link minimp3 for MP3 audio deep validation tests
    core_tests.linkLibrary(minimp3_lib);
    // Link libfdk-aac for AAC audio deep validation tests
    core_tests.linkLibrary(libfdkaac_lib);
    // Link libvpx for VP8/VP9 video deep validation tests
    core_tests.linkLibrary(libvpx_lib);
    // Link OpenJPEG for JPEG2000 decode validation tests
    core_tests.linkLibrary(openjpeg_lib);
    // Link libjxl for JPEG-XL decode validation tests
    core_tests.linkLibrary(libjxl_lib);
    // Link brotli for .br file decompression validation tests
    core_tests.linkLibrary(brotli_lib);
    // Link libopenmpt for tracker format (MOD/XM/IT/S3M) deep validation tests (Zig-built)
    core_tests.linkLibrary(libopenmpt_lib);
    core_tests.linkLibC();
    core_tests.linkLibCpp(); // Required for libheif, openh264, libjxl, libopenmpt (C++ libraries)

    const host_is_windows = b.graph.host.result.os.tag == .windows;
    const target_is_windows = target.result.os.tag == .windows;
    const run_core_tests = if (target_is_windows and !host_is_windows and windows_test_wine != null) blk: {
        const run = b.addSystemCommand(&.{
            windows_test_wine.?,
            "--bottle",
            windows_test_bottle,
            "--cx-app",
        });
        run.addFileArg(core_tests.getEmittedBin());
        run.setEnvironmentVariable("WINEDEBUG", "-all");
        break :blk run;
    } else b.addRunArtifact(core_tests);

    const ffi_tests = b.addTest(.{
        .root_module = ffi_mod,
        .filters = test_filters,
    });
    ffi_tests.linkLibrary(pcre2_lib);
    ffi_tests.linkLibrary(zlib_lib);
    ffi_tests.linkLibrary(libjpeg_lib);
    ffi_tests.linkLibrary(sqlite3_lib);
    ffi_tests.linkLibrary(libwebp_lib);
    ffi_tests.linkLibrary(libheif_lib);
    ffi_tests.linkLibrary(openh264_lib);
    ffi_tests.linkLibrary(libopus_lib);
    ffi_tests.linkLibrary(libogg_lib);
    ffi_tests.linkLibrary(libvorbis_lib);
    ffi_tests.linkLibrary(minimp3_lib);
    ffi_tests.linkLibrary(libfdkaac_lib);
    ffi_tests.linkLibrary(libvpx_lib);
    ffi_tests.linkLibrary(openjpeg_lib);
    ffi_tests.linkLibrary(libjxl_lib);
    ffi_tests.linkLibrary(brotli_lib);
    ffi_tests.linkLibrary(libopenmpt_lib);
    ffi_tests.linkLibC();
    ffi_tests.linkLibCpp();

    const run_ffi_tests = if (target_is_windows and !host_is_windows and windows_test_wine != null) blk: {
        const run = b.addSystemCommand(&.{
            windows_test_wine.?,
            "--bottle",
            windows_test_bottle,
            "--cx-app",
        });
        run.addFileArg(ffi_tests.getEmittedBin());
        run.setEnvironmentVariable("WINEDEBUG", "-all");
        break :blk run;
    } else b.addRunArtifact(ffi_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
}
