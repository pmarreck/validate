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

    // Removed: libheif, openh264, libde265, dav1d — replaced by pure-Zig validators

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

    // Removed: libvpx — replaced by pure-Zig VP9 syntax validator (VP8 was already pure Zig)

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

    // cj5 dependency for JSON5 validation (C library with Zig bindings)
    const cj5_dep = b.dependency("cj5", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const cj5_lib = cj5_dep.artifact("cj5");
    const cj5_mod = cj5_dep.module("cj5");

    // z7z cleanroom 7-Zip implementation (pmarreck/z7z)
    const z7z_dep = b.dependency("z7z", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const z7z_lib = z7z_dep.artifact("libz7z");

    // rarz for in-memory RAR validation (clean-room Zig implementation)
    const rarz_dep = b.dependency("rarz", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const rarz_mod = b.createModule(.{
        .root_source_file = rarz_dep.path("src/lib/root.zig"),
        .target = target,
        .optimize = deps_optimize,
    });
    // rarz needs ARM hardware CRC32 C helper on aarch64
    if (target.result.cpu.arch == .aarch64) {
        rarz_mod.addCSourceFile(.{
            .file = rarz_dep.path("src/lib/crc32_arm.c"),
            .flags = &.{ "-march=armv8-a+crc", "-O3" },
        });
    }

    // compact_pro for in-memory Compact Pro (.cpt) archive validation (C FFI)
    const compact_pro_dep = b.dependency("compact_pro", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const compact_pro_lib = compact_pro_dep.artifact("compact_pro");

    // progrez for progress bar rendering (pure-Zig core, no FFI)
    const progrez_dep = b.dependency("progrez", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const progrez_module = progrez_dep.module("progrez_core");

    // LibRaw for camera RAW format validation (LGPL-2.1, phcreery/LibRaw-zig)
    const libraw_dep = b.dependency("libraw", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const libraw_lib = libraw_dep.artifact("libraw_clib");
    const libraw_mod = libraw_dep.module("libraw");

    // Core module - validation logic
    const core_mod = b.addModule("validate_core", .{
        .root_source_file = b.path("src/core/mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml_mod }, // External TOML parser for validation
            .{ .name = "zigimg", .module = zigimg_mod }, // Image format decoding for deep validation
            .{ .name = "xml", .module = zigxml_mod }, // XML validation (0BSD, ianprime0509/zig-xml)
            .{ .name = "cj5", .module = cj5_mod }, // JSON5 validation (MIT, septag/cj5 fork)
            .{ .name = "libraw", .module = libraw_mod }, // Camera RAW validation (LGPL-2.1)
            .{ .name = "rarz", .module = rarz_mod }, // RAR clean-room parser/validator
            .{ .name = "progrez", .module = progrez_module }, // Progress bar rendering (pure-Zig)
        },
    });

    // Add PCRE2 include path (from Zig-built dependency)
    core_mod.addIncludePath(pcre2_lib.getEmittedIncludeTree());

    // Add libjpeg include path (from Zig-built dependency)
    core_mod.addIncludePath(libjpeg_lib.getEmittedIncludeTree());

    // Add libwebp include path (from Zig-built dependency)
    core_mod.addIncludePath(libwebp_lib.getEmittedIncludeTree());

    // Removed: libheif, openh264, libde265, dav1d include paths (pure-Zig validators)

    // Add libopus include path (for opus_validator.zig @cImport)
    core_mod.addIncludePath(libopus_lib.getEmittedIncludeTree());

    // Add libogg include path (required by libvorbis for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libogg_lib.getEmittedIncludeTree());

    // Add libvorbis include path (for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libvorbis_lib.getEmittedIncludeTree());

    // Add minimp3 include path (for mp3_decode_validator.zig @cImport)
    core_mod.addIncludePath(minimp3_lib.getEmittedIncludeTree());

    // Removed: libvpx include path (pure-Zig VP9 validator, VP8 is already pure Zig)

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

    // Add libraw include path (for camera RAW validation)
    core_mod.addIncludePath(libraw_lib.getEmittedIncludeTree());

    // Add z7z include path (for sevenz_validator.zig @cImport)
    core_mod.addIncludePath(z7z_dep.path("include"));

    // Add compact_pro C FFI headers
    core_mod.addIncludePath(compact_pro_dep.path("include"));

    // Add src/core include path for any remaining C headers
    core_mod.addIncludePath(b.path("src/core"));

    // FFI module - C ABI exports
    const ffi_mod = b.addModule("validate_ffi", .{
        .root_source_file = b.path("ffi/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    // All C library dependencies that must be linked into any binary using core_mod.
    // Defined once to avoid divergence between static lib, shared lib, tests, and fuzzers.
    const all_c_deps: []const *std.Build.Step.Compile = &.{
        pcre2_lib,     // regex/glob matching
        zlib_lib,      // deflate decompression (replaces buggy std.compress.flate)
        libjpeg_lib,   // JPEG decode validation
        libwebp_lib,   // WebP deep validation
        libopus_lib,   // Opus audio deep validation
        libogg_lib,    // OGG container support (required by libvorbis)
        libvorbis_lib, // Vorbis audio deep validation
        minimp3_lib,   // MP3 audio deep validation
        openjpeg_lib,  // JPEG2000 decode validation
        libjxl_lib,    // JPEG-XL decode validation
        brotli_lib,    // .br file decompression validation
        libopenmpt_lib, // tracker format (MOD/XM/IT/S3M) deep validation
        cj5_lib,       // JSON5 validation (C library)
        libraw_lib,    // camera RAW format validation (LGPL-2.1)
        z7z_lib,       // 7-Zip archive deep validation (z7z cleanroom)
        compact_pro_lib, // Compact Pro archive validation
    };

    // Static library for FFI
    const lib = b.addLibrary(.{
        .name = "validate_core",
        .root_module = ffi_mod,
        .linkage = .static,
    });
    for (all_c_deps) |dep| lib.linkLibrary(dep);
    lib.linkLibC();
    lib.linkLibCpp(); // Required for libjxl, libopenmpt (C++ libraries)
    // On Windows, LibRaw uses ntohs/htons/htonl/ntohl from ws2_32
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("ws2_32");
    }

    lib.installHeadersDirectory(b.path("ffi"), "", .{
        .include_extensions = &.{".h"},
    });

    // On macOS, use libtool to bundle all dependencies into a single "fat" static library
    // This is required for Xcode integration since static libraries don't embed their dependencies
    // Note: Only do this for native macOS builds - libtool isn't available when cross-compiling
    const is_macos = target.result.os.tag == .macos;
    const is_native_macos = is_macos and @import("builtin").os.tag == .macos;
    if (is_native_macos) {
        // Collect all static library dependencies for bundling
        const lib_sources: []const std.Build.LazyPath = &.{
            lib.getEmittedBin(),
            pcre2_lib.getEmittedBin(),
            zlib_lib.getEmittedBin(),
            libjpeg_lib.getEmittedBin(),
            libwebp_lib.getEmittedBin(),
            libopus_lib.getEmittedBin(),
            libogg_lib.getEmittedBin(),
            libvorbis_lib.getEmittedBin(),
            minimp3_lib.getEmittedBin(),
            openjpeg_lib.getEmittedBin(),
            libjxl_lib.getEmittedBin(),
            brotli_lib.getEmittedBin(),
            libopenmpt_lib.getEmittedBin(),
            cj5_lib.getEmittedBin(),
            compact_pro_lib.getEmittedBin(),
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
    for (all_c_deps) |dep| lib_shared.linkLibrary(dep);
    lib_shared.linkLibC();
    lib_shared.linkLibCpp(); // Required for libjxl, libopenmpt (C++ libraries)

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
    for (all_c_deps) |dep| core_tests.linkLibrary(dep);
    core_tests.linkLibrary(sqlite3_lib); // Tests need sqlite3 directly (CLI links it separately)
    core_tests.linkLibC();
    core_tests.linkLibCpp(); // Required for libjxl, libopenmpt (C++ libraries)

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
    for (all_c_deps) |dep| ffi_tests.linkLibrary(dep);
    ffi_tests.linkLibrary(sqlite3_lib);
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
