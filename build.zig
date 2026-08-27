const std = @import("std");
const LibtoolStep = @import("src/build/LibtoolStep.zig");

fn debugEnvEnabled(b: *std.Build) bool {
    // 0.16: std.process.getEnvVarOwned is gone in build.zig; use the build
    // graph's environ_map (borrowed slice, no free needed).
    const raw = b.graph.environ_map.get("DEBUG") orelse return false;

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

    // Libtheora for Theora video deep validation (BSD-3, Xiph.org)
    // Always ReleaseFast to avoid Zig's overflow checks triggering on libtheora's
    // bit manipulation and integer rounding paths (same rationale as libvorbis).
    const libtheora_dep = b.dependency("libtheora", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libtheora_lib = libtheora_dep.artifact("theora");

    // minimp3 for MP3 audio deep validation (Public Domain, header-only)
    const minimp3_dep = b.dependency("minimp3", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const minimp3_lib = minimp3_dep.artifact("minimp3");

    // libvpx for VP8/VP9 video deep validation (BSD-3, WebM Project)
    // Decoder-only, generic-gnu target (no asm, no intrinsics) so it
    // cross-compiles to all 5 OS/arch targets with zero per-arch work.
    // ReleaseFast for the same reason libvorbis/libtheora are: upstream
    // code uses tight bitstream math that trips Zig's Debug overflow checks.
    const libvpx_dep = b.dependency("libvpx", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libvpx_lib = libvpx_dep.artifact("vpx");

    // libwavpack for WavPack lossless audio deep validation (BSD-3, dbry).
    // Decode-only build (no encoder, no DSD, no legacy v3, no asm). The
    // CRC of decoded samples is verified internally by the library; we
    // surface mismatches via WavpackGetNumErrors().
    const libwavpack_dep = b.dependency("libwavpack", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libwavpack_lib = libwavpack_dep.artifact("wavpack");

    // libape for Monkey's Audio (APE) deep decode validation (BSD-3, upstream
    // Monkey's Audio SDK 12.73). Decompress-only subset built with the
    // backwards-compatibility flag to cover legacy v3800-3970 files. The
    // shim exposes a single `validate_ape_decode_check` C entry point that
    // decodes every frame and returns nonzero on per-frame CRC mismatch.
    // The per-frame CRC32 is computed over decoded PCM (per
    // APEDecompressCore.cpp::EndFrame), so structural validation cannot
    // catch payload corruption — only a real decoder can.
    const libape_dep = b.dependency("libape", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    const libape_lib = libape_dep.artifact("ape");
    // OpenJPEG is fully out (v1 closure cutover): JPEG2000 validation routes
    // through tiffz.jpegz.jpeg2000.strictValidate (jp2z, pure Zig) and the
    // decode-path linkage is gated off via -Dwith-jp2-decode=false below
    // (jpegz ships 0 opj_ symbols with the gate off).

    // Brotli for .br file decompression validation (MIT, Google)
    const brotli_dep = b.dependency("brotli", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const brotli_lib = brotli_dep.artifact("brotli");

    // JPEG XL strict validation is reached through `tiffz.jpegz.jpegxl` —
    // jpegz pins the same libjxlz commit and a direct dep here created a
    // second module instance of the same root file (Zig 0.16 rejects it,
    // same failure class as the jpegz double-pin, see #32).

    // PCRE2 for regex/glob pattern matching (BSD, renerocksai/pcre2 Zig build)
    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = deps_optimize,
        .linkage = .static, // Force static linking for cross-platform builds
        .@"code-unit-width" = .@"8", // UTF-8 support
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    // jpegz: spec-complete JPEG family decoder library (MIT, pmarreck/jpegz).
    // Consumes libjpeg-turbo + openjpeg internally (Phase 1 wrapper). We use
    // the Zig module path; the C ABI is a thin scaffold today.
    //
    // Path options come from the flake (dev shell sets LIBJPEG_*_ROOT env;
    // nix-build sandbox passes the same paths via -D options on the zig build
    // invocation). When unset (raw `zig build` outside nix), jpegz's
    // linkSystemLibrary calls fall back to whatever's on the system search
    // path — works on macOS via Homebrew, breaks on bare-OS targets.
    const opt_libjpeg_inc = b.option(
        []const u8,
        "libjpeg-include",
        "Path to libjpeg-turbo headers (forwarded to jpegz)",
    ) orelse blk: {
        const v = b.graph.environ_map.get("LIBJPEG_INCLUDE_ROOT") orelse break :blk "";
        // The env var points at the nix-store `-dev` output root; the
        // actual include path is .../include.
        break :blk b.fmt("{s}/include", .{v});
    };
    const opt_libjpeg_lib = b.option(
        []const u8,
        "libjpeg-lib",
        "Path to libjpeg-turbo library directory (forwarded to jpegz)",
    ) orelse blk: {
        const v = b.graph.environ_map.get("LIBJPEG_STATIC_ROOT") orelse break :blk "";
        break :blk b.fmt("{s}/lib", .{v});
    };
    // (openjpeg include/lib options removed — JP2 decode is gated off via
    // -Dwith-jp2-decode=false; strict JP2 validation is pure-Zig jp2z.)
    // System zlib paths — forwarded to tiffz (its `linkSystemLibrary("z")`
    // call needs them on hosts where libz isn't in libSystem, i.e. all
    // non-Apple targets and Nix sandbox).
    const opt_zlib_inc = b.option(
        []const u8,
        "zlib-include",
        "Path to zlib headers (forwarded to tiffz)",
    ) orelse (b.graph.environ_map.get("ZLIB_INCLUDE_ROOT") orelse "");
    const opt_zlib_lib = b.option(
        []const u8,
        "zlib-lib",
        "Path to zlib library directory (forwarded to tiffz)",
    ) orelse (b.graph.environ_map.get("ZLIB_LIB_ROOT") orelse "");

    // jpegz is intentionally NOT a direct dependency of validate. It is reached
    // through tiffz's re-export (`@import("tiffz").jpegz`) so the whole build
    // graph contains exactly ONE jpegz module instance. Depending on jpegz here
    // AND inside tiffz created two instances of the same root file, which Zig
    // 0.16 rejects ("file exists in modules 'jpegz' and 'jpegz0'") and the nix
    // sandbox crashes on (SEGV during the Debug test compile). tiffz owns the
    // jpegz pin; validate consumes it transitively. See #32.
    // The opt_libjpeg_* / opt_openjpeg_* paths above are still forwarded to
    // tiffz (which forwards them to its jpegz) and used for the consumer-side
    // -L library search paths below.

    // tiffz: pure-Zig TIFF / DNG / NEF / NRW / CR2 / ARW structural
    // validator. Consumes jpegz.decode for Compression=7 + lossless
    // JPEG. Same option-cascade as jpegz to forward system library
    // paths in the no-libpaths/libpaths-only/full cases.
    // JP2 DECODE is disabled fleet-wide (v1 closure): jpegz drops OpenJPEG
    // entirely (0 opj_ symbols), jpeg2000.decode returns error.NotImplemented,
    // and strict JP2 validation (jp2z, pure Zig) is unaffected. tiffz forwards
    // the option verbatim since 388dee45. With the gate off, the openjpeg
    // include/lib forwarding became dead and was removed.
    const tiffz_dep = blk: {
        if (opt_libjpeg_inc.len > 0 and opt_libjpeg_lib.len > 0 and
            opt_zlib_inc.len > 0 and opt_zlib_lib.len > 0)
        {
            break :blk b.dependency("tiffz", .{
                .target = target,
                .optimize = deps_optimize,
                .@"with-jp2-decode" = false,
                .@"libjpeg-include" = opt_libjpeg_inc,
                .@"libjpeg-lib" = opt_libjpeg_lib,
                .@"zlib-include" = opt_zlib_inc,
                .@"zlib-lib" = opt_zlib_lib,
            });
        }
        if (opt_zlib_inc.len > 0 and opt_zlib_lib.len > 0) {
            break :blk b.dependency("tiffz", .{
                .target = target,
                .optimize = deps_optimize,
                .@"with-jp2-decode" = false,
                .@"zlib-include" = opt_zlib_inc,
                .@"zlib-lib" = opt_zlib_lib,
            });
        }
        break :blk b.dependency("tiffz", .{
            .target = target,
            .optimize = deps_optimize,
            .@"with-jp2-decode" = false,
        });
    };
    const tiffz_mod = tiffz_dep.module("tiffz");

    // lercz: the exact LERC C-ABI instance tiffz's module links (exported by
    // tiffz 30d92d24 as artifact "lerc"). Merged into all_c_deps so the
    // installed libvalidate_core.a OWNS its LERC link closure — before this,
    // every static consumer inherited unresolved lerc_getBlobInfo/lerc_decode
    // and had to carry its own lercz link (validate_gui did, temporarily).
    // Gated by tests/cli/lerc_link_closure.
    const lerc_lib = tiffz_dep.artifact("lerc");
    // zstdz: same closure story as lerc — tiffz's ZSTD-in-TIFF codec
    // (Compression=50000, ac381e64) references ZSTD_* through its module
    // graph; external static consumers need the exact instance merged.
    // Caught by tests/cli/lerc_link_closure before it ever shipped.
    const zstd_lib = tiffz_dep.artifact("zstd");

    // rawz: vendor-RAW semantics (PEF cutover per Einstein M3; more families
    // as rawz lands them). Built as a source module so we can inject the
    // "tiffz-parser" module from the SAME tiffz_dep instance as the full
    // validator above — Zig 0.16 one-file-one-module rule; accepting rawz's
    // named module would drag in a second tiffz instance. Recipe from
    // tiffz's 2026-08-05 parser-integration note.
    const rawz_dep = b.dependency("rawz", .{});
    const rawz_mod = b.createModule(.{
        .root_source_file = rawz_dep.path("src/lib.zig"),
        .target = target,
        .optimize = deps_optimize,
    });
    rawz_mod.addImport("tiffz", tiffz_dep.module("tiffz-parser"));

    // zlib for deflate compression/decompression (zlib license, allyourcodebase/zlib)
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const zlib_lib = zlib_dep.artifact("z");
    const zig_zlib_lib_dir = zlib_lib.getEmittedBinDirectory();
    tiffz_mod.addIncludePath(zlib_lib.getEmittedIncludeTree());
    tiffz_mod.addLibraryPath(zig_zlib_lib_dir);

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
    const z7z_mod = z7z_dep.module("z7z");

    // rarz for in-memory RAR validation through its stable C ABI. The public
    // header keeps Validate off rarz's private Zig types and exposes the
    // lossless archive-summary contract from include/rarz.h.
    const rarz_dep = b.dependency("rarz", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const rarz_mod = b.createModule(.{
        .root_source_file = rarz_dep.path("src/lib/root.zig"),
        .target = target,
        .optimize = deps_optimize,
        .link_libc = true,
    });
    // The dependency installs both a library and executable named `rarz`, so
    // dependency.artifact("rarz") is ambiguous. Build the public C-ABI library
    // from its canonical root module under a consumer-local artifact name.
    const rarz_lib = b.addLibrary(.{
        .name = "rarz_validate_consumer",
        .linkage = .static,
        .root_module = rarz_mod,
    });
    if (target.result.cpu.arch == .aarch64 and
        std.Target.aarch64.featureSetHas(target.result.cpu.features, .crc))
    {
        rarz_mod.addCSourceFile(.{
            .file = rarz_dep.path("src/lib/crc32_arm.c"),
            .flags = &.{ "-march=armv8-a+crc", "-O3" },
        });
    }

    // bzip2z for in-memory bzip2 validation (clean-room Zig implementation)
    const bzip2z_dep = b.dependency("bzip2z", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const bzip2z_mod = bzip2z_dep.module("bzip2z");

    // zstdz: Zig-enabled fork of Facebook's BSD zstd C library (Peter-controlled,
    // patches/CVE fixes flow here). Replaces std.compress.zstd usage in validators.
    const zstdz_dep = b.dependency("zstdz", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const zstdz_mod = zstdz_dep.module("zstd");

    // par2z: PAR2 packet structural verification (Peter-controlled cleanroom Zig).
    // We use only the `core` module for packet header + MD5 verification.
    const par2z_dep = b.dependency("par2z", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const par2z_core_mod = par2z_dep.module("core");

    // uchardetz: Mozilla's uchardet charset detection library, Zig-buildable fork.
    // Used by text validators to identify non-UTF-8 encodings.
    const uchardetz_dep = b.dependency("uchardetz", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const uchardetz_lib = uchardetz_dep.artifact("uchardet-static");

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


    // mini_blar extracted from BLIP to its own repo (2026-05). validate
    // only ever consumed the archive reader/verifier; the rest of BLIP
    // (which pulls in jxl) is not needed.
    const mini_blar_dep = b.dependency("mini_blar", .{
        .target = target,
        .optimize = deps_optimize,
    });
    const mini_blar_mod = mini_blar_dep.module("mini_blar");

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
            // JPEG XL strict validation via tiffz.jpegz.jpegxl (single libjxlz instance) — see #32.
            .{ .name = "bzip2z", .module = bzip2z_mod }, // bzip2 clean-room decoder/encoder
            .{ .name = "zstd", .module = zstdz_mod }, // zstd via zstdz (Peter-controlled fork of Facebook BSD zstd)
            .{ .name = "z7z", .module = z7z_mod }, // 7-Zip clean-room Zig verifier
            .{ .name = "par2_core", .module = par2z_core_mod }, // PAR2 packet parser via par2z
            .{ .name = "progrez", .module = progrez_module }, // Progress bar rendering (pure-Zig)
            .{ .name = "mini_blar", .module = mini_blar_mod }, // BLIP archive reader/verifier
            // jpegz reached via tiffz re-export (single instance) — see #32.
            .{ .name = "tiffz", .module = tiffz_mod }, // TIFF family validator (MIT, pmarreck/tiffz)
            .{ .name = "rawz", .module = rawz_mod }, // vendor-RAW semantics (PEF et al., pmarreck/rawz)
        },
    });

    // v1 production-closure hard-gate: v1_closure.zig comptime-scans the
    // REAL manifest for forbidden dependency declarations. The zon is mapped
    // in as an embeddable module so the gate reads the actual file, not a
    // copy that could drift.
    core_mod.addAnonymousImport("build_manifest", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    // Add PCRE2 include path (from Zig-built dependency)
    core_mod.addIncludePath(pcre2_lib.getEmittedIncludeTree());

    // jpegz's Zig module calls linkSystemLibrary("jpeg") and ("openjp2"),
    // and those propagate to consumers — but `addLibraryPath` on the dep's
    // internal module does NOT propagate. So add the same paths here on the
    // consumer side. Skipped when paths are empty (cross-build or system-PATH
    // fallback).
    if (opt_libjpeg_lib.len > 0) core_mod.addLibraryPath(.{ .cwd_relative = opt_libjpeg_lib });
    if (opt_zlib_lib.len > 0) core_mod.addLibraryPath(.{ .cwd_relative = opt_zlib_lib });
    // tiffz links system "z"; when no external zlib path is supplied for a
    // cross target, satisfy that -lz from validate's Zig-built zlib artifact.
    core_mod.addLibraryPath(zig_zlib_lib_dir);

    // Add libwebp include path (from Zig-built dependency)
    core_mod.addIncludePath(libwebp_lib.getEmittedIncludeTree());

    // Removed: libheif, openh264, libde265, dav1d include paths (pure-Zig validators)

    // Add libopus include path (for opus_validator.zig @cImport)
    core_mod.addIncludePath(libopus_lib.getEmittedIncludeTree());

    // Add libogg include path (required by libvorbis for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libogg_lib.getEmittedIncludeTree());

    // Add libvorbis include path (for vorbis_validator.zig @cImport)
    core_mod.addIncludePath(libvorbis_lib.getEmittedIncludeTree());

    // Add libtheora include path (for theora_decode_validator.zig @cImport)
    core_mod.addIncludePath(libtheora_lib.getEmittedIncludeTree());

    // Add minimp3 include path (for mp3_decode_validator.zig @cImport)
    core_mod.addIncludePath(minimp3_lib.getEmittedIncludeTree());

    // Add libvpx include path (for vpx_decode_validator.zig @cImport)
    core_mod.addIncludePath(libvpx_lib.getEmittedIncludeTree());

    // Add libwavpack include path (for wavpack_decode_validator.zig @cImport)
    core_mod.addIncludePath(libwavpack_lib.getEmittedIncludeTree());

    // Add libape include path (for ape_decode_validator.zig @cImport)
    core_mod.addIncludePath(libape_lib.getEmittedIncludeTree());
    // Add brotli include path (for brotli_validator.zig @cImport)
    core_mod.addIncludePath(brotli_lib.getEmittedIncludeTree());

    // Add libopenmpt include path (for libopenmpt.zig @cImport)
    core_mod.addIncludePath(libopenmpt_lib.getEmittedIncludeTree());

    // Add sqlite3 include path (Zig-built dependency)
    core_mod.addIncludePath(sqlite3_lib.getEmittedIncludeTree());

    // Add zlib include path (Zig-built dependency, used in zlib.zig wrapper)
    core_mod.addIncludePath(zlib_lib.getEmittedIncludeTree());


    // Add compact_pro C FFI headers
    core_mod.addIncludePath(compact_pro_dep.path("include"));
    // Stable rarz archive-summary C ABI.
    core_mod.addIncludePath(rarz_dep.path("include"));

    // uchardetz: header is `src/uchardet.h`. Add the dep's `src/` so
    // `@cInclude("uchardet.h")` finds it; we don't use the installed
    // `<prefix>/include/uchardet/uchardet.h` path since getEmittedIncludeTree
    // doesn't surface installFile-emitted headers.
    core_mod.addIncludePath(uchardetz_dep.path("src"));

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
        libwebp_lib,   // WebP deep validation
        libopus_lib,   // Opus audio deep validation
        libogg_lib,    // OGG container support (required by libvorbis)
        libvorbis_lib, // Vorbis audio deep validation
        libtheora_lib, // Theora video deep validation
        libvpx_lib,    // VP8/VP9 video deep validation (libvpx)
        libwavpack_lib, // WavPack lossless audio deep validation
        libape_lib,     // Monkey's Audio (APE) deep decode validation
        minimp3_lib,   // MP3 audio deep validation
        brotli_lib,    // .br file decompression validation
        libopenmpt_lib, // tracker format (MOD/XM/IT/S3M) deep validation
        cj5_lib,       // JSON5 validation (C library)
        compact_pro_lib, // Compact Pro archive validation
        uchardetz_lib,   // Mozilla uchardet — charset detection for plain-text validators
        rarz_lib,        // clean-room RAR archive verification through stable C ABI
        lerc_lib,        // LERC decode (tiffz's lercz instance) — archive owns its link closure
        zstd_lib,        // Zstandard decode (tiffz's zstdz instance) — same closure contract
    };

    // Static library for FFI
    const lib = b.addLibrary(.{
        .name = "validate_core",
        .root_module = ffi_mod,
        .linkage = .static,
    });
    // 0.16: per-module configuration (link libs, link libc, system libs) lives
    // on *Build.Module now. The "1:1 rewrite" pattern is to route through
    // compile.root_module.X(...) instead of compile.X(...).
    for (all_c_deps) |dep| lib.root_module.linkLibrary(dep);
    for (all_c_deps) |dep| lib.root_module.linkLibrary(dep);
    lib.root_module.link_libc = true;
    lib.root_module.link_libcpp = true; // Required for libjxl, libopenmpt (C++ libraries)
    // jpegz transitively requires libjpeg + openjp2 via linkSystemLibrary; add
    // search paths on the actual link target (Module addLibraryPath doesn't
    // propagate through the import graph to the final compile step's linker).
    if (opt_libjpeg_lib.len > 0) lib.root_module.addLibraryPath(.{ .cwd_relative = opt_libjpeg_lib });
    if (opt_zlib_lib.len > 0) lib.root_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib });
    lib.root_module.addLibraryPath(zig_zlib_lib_dir);
    // On Windows, ws2_32 supplies ntohs/htonl for byte-order helpers in C deps
    if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("ws2_32", .{});
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
            libwebp_lib.getEmittedBin(),
            libopus_lib.getEmittedBin(),
            libogg_lib.getEmittedBin(),
            libvorbis_lib.getEmittedBin(),
            libtheora_lib.getEmittedBin(),
            libvpx_lib.getEmittedBin(),
            libwavpack_lib.getEmittedBin(),
            libape_lib.getEmittedBin(),
            minimp3_lib.getEmittedBin(),
            brotli_lib.getEmittedBin(),
            libopenmpt_lib.getEmittedBin(),
            cj5_lib.getEmittedBin(),
            compact_pro_lib.getEmittedBin(),
            rarz_lib.getEmittedBin(),
            sqlite3_lib.getEmittedBin(),
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
        // Non-macOS: use Zig's LLVM tools to merge all dependency archives
        // into a single combined library, matching what libtool does on macOS.
        // Without this, consumers get undefined symbols for opus, openmpt, etc.
        const is_windows_target = target.result.os.tag == .windows;

        const merged_output = if (is_windows_target) blk: {
            // zig lib = llvm-lib: merges COFF .lib archives
            const merge = b.addSystemCommand(&.{ b.graph.zig_exe, "lib" });
            const output = merge.addPrefixedOutputFileArg("/out:", "validate_core.lib");
            merge.addArtifactArg(lib);
            for (all_c_deps) |dep| merge.addArtifactArg(dep);
            merge.addArtifactArg(sqlite3_lib);
            break :blk output;
        } else blk: {
            // zig ar = llvm-ar: L flag flattens input archives into one .a
            const merge = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "qcLS" });
            const output = merge.addOutputFileArg("libvalidate_core.a");
            merge.addArtifactArg(lib);
            for (all_c_deps) |dep| merge.addArtifactArg(dep);
            merge.addArtifactArg(sqlite3_lib);
            break :blk output;
        };

        const lib_name = if (is_windows_target) "validate_core.lib" else "libvalidate_core.a";
        const install_merged = b.addInstallFileWithDir(merged_output, .lib, lib_name);
        b.getInstallStep().dependOn(&install_merged.step);

        // Also install as the other naming convention for cross-platform consumers
        if (is_windows_target) {
            const install_alias = b.addInstallFileWithDir(merged_output, .lib, "libvalidate_core.a");
            b.getInstallStep().dependOn(&install_alias.step);
        }

        // Install header for consumers
        const install_hdr = b.addInstallFileWithDir(b.path("ffi/validate_core.h"), .header, "validate_core.h");
        b.getInstallStep().dependOn(&install_hdr.step);
    }

    // Shared library (optional)
    const lib_shared = b.addLibrary(.{
        .name = "validate_core",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    });
    // 0.16: route through root_module (mirrors the static lib above).
    for (all_c_deps) |dep| lib_shared.root_module.linkLibrary(dep);
    lib_shared.root_module.link_libc = true;
    lib_shared.root_module.link_libcpp = true; // Required for libjxl, libopenmpt (C++ libraries)
    lib_shared.root_module.addLibraryPath(zig_zlib_lib_dir);

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
    cli_c_mod.addIncludePath(b.path("cli"));

    const cli_c = b.addExecutable(.{
        .name = "validate",
        .root_module = cli_c_mod,
    });
    // 0.16: linkLibrary lives on Module, not Compile.
    cli_c.root_module.linkLibrary(lib);
    cli_c.root_module.linkLibrary(sqlite3_lib);
    // jpegz brings -ljpeg / -lopenjp2 to the link line; the final exe needs
    // the corresponding -L paths so those system libs resolve.
    if (opt_libjpeg_lib.len > 0) cli_c.root_module.addLibraryPath(.{ .cwd_relative = opt_libjpeg_lib });
    if (opt_zlib_lib.len > 0) cli_c.root_module.addLibraryPath(.{ .cwd_relative = opt_zlib_lib });
    cli_c.root_module.addLibraryPath(zig_zlib_lib_dir);


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
    const fuzz_step = b.step("fuzz", "Build fuzzers");

    // NOTE: tests/fuzz/fuzz_stream_bzip2.zig (the Tier-2 bzip2 round-trip harness) is
    // bit-rotted against Zig 0.16 — it uses the removed std.io reader/writer +
    // GeneralPurposeAllocator APIs and needs a std.Io.Reader/Writer migration.
    // Excluded from the build until that Tier-2 repair (FUZZ_PLAN sequencing
    // step 3). The Tier-1 whole-surface harnesses below are the current target.

    // Tier-1 whole-surface fuzz harnesses. Unlike the bzip2 round-trip fuzzer
    // (which only touches the bzip2 path), these route every input through the
    // full detect→shallow→deep dispatch, so they pull in ALL validators and
    // therefore need the complete C-dependency link set (mirrors core_tests /
    // cli_c). Helper closes over the link incantation to avoid divergence.
    const fuzzExe = struct {
        fn make(
            bld: *std.Build,
            name: []const u8,
            root: []const u8,
            mod_core: *std.Build.Module,
            tgt: std.Build.ResolvedTarget,
            opt: std.builtin.OptimizeMode,
            c_deps: []const *std.Build.Step.Compile,
            sqlite_lib: *std.Build.Step.Compile,
            jpeg_path: []const u8,
            zlib_path: []const u8,
        ) *std.Build.Step.Compile {
            const m = bld.createModule(.{
                .root_source_file = bld.path(root),
                .target = tgt,
                .optimize = opt,
                .imports = &.{.{ .name = "core", .module = mod_core }},
            });
            const exe = bld.addExecutable(.{ .name = name, .root_module = m });
            for (c_deps) |dep| exe.root_module.linkLibrary(dep);
            exe.root_module.linkLibrary(sqlite_lib);
            exe.root_module.link_libc = true;
            exe.root_module.link_libcpp = true; // libjxl, libopenmpt are C++
            if (jpeg_path.len > 0) exe.root_module.addLibraryPath(.{ .cwd_relative = jpeg_path });
            if (zlib_path.len > 0) exe.root_module.addLibraryPath(.{ .cwd_relative = zlib_path });
            if (tgt.result.os.tag == .windows) exe.root_module.linkSystemLibrary("ws2_32", .{});
            return exe;
        }
    }.make;

    const fuzz_dispatch = fuzzExe(b, "fuzz-dispatch", "tests/fuzz/fuzz_dispatch.zig", core_mod, target, optimize, all_c_deps, sqlite3_lib, opt_libjpeg_lib, opt_zlib_lib);
    fuzz_step.dependOn(&b.addInstallArtifact(fuzz_dispatch, .{}).step);

    const fuzz_sweep = fuzzExe(b, "fuzz-sweep", "tests/fuzz/fuzz_sweep.zig", core_mod, target, optimize, all_c_deps, sqlite3_lib, opt_libjpeg_lib, opt_zlib_lib);
    fuzz_step.dependOn(&b.addInstallArtifact(fuzz_sweep, .{}).step);
    // Tests
    const test_filter = b.option([]const u8, "test-filter", "Run only tests containing this text");
    var test_filters: []const []const u8 = &.{};
    if (test_filter) |filter| {
        test_filters = &.{filter};
    }
    const windows_test_wine = b.option([]const u8, "windows-test-wine", "Path to CrossOver wine for Windows tests");
    const windows_test_bottle = b.option([]const u8, "windows-test-bottle", "CrossOver bottle name for Windows tests") orelse "windows-dev-test";

    // #32 workaround + self-removing tripwire. Zig 0.16's self-hosted x86_64
    // backend SEGVs compiling the Debug-native test binary on Linux, so we force
    // the (mature) LLVM backend for the test compiles — exactly what the
    // ReleaseFast build already uses. The comptime guard makes this self-expiring:
    // when the fleet bumps Zig past 0.16, the @compileError fires so someone
    // re-verifies whether the upstream backend bug is fixed instead of silently
    // carrying this forever.
    const force_test_llvm: bool = blk: {
        const zver = @import("builtin").zig_version;
        if (zver.major == 0 and zver.minor <= 16) break :blk true;
        @compileError("Zig >0.16 detected: re-check the self-hosted x86_64 Debug-backend " ++
            "test-compile SEGV (validate #32). Build tests with -Doptimize=Debug -Dtarget=native " ++
            "on x86_64-linux WITHOUT use_llvm; if green, delete this block and the two guarded " ++
            "`use_llvm` assignments below. If it still crashes, widen this version guard.");
    };

    const core_tests = b.addTest(.{
        .root_module = core_mod,
        .filters = test_filters,
    });
    // 0.16: route through Module.
    for (all_c_deps) |dep| core_tests.root_module.linkLibrary(dep);
    core_tests.root_module.linkLibrary(sqlite3_lib); // Tests need sqlite3 directly (CLI links it separately)
    core_tests.root_module.link_libc = true;
    core_tests.root_module.link_libcpp = true; // Required for libjxl, libopenmpt (C++ libraries)
    if (force_test_llvm) core_tests.use_llvm = true; // see force_test_llvm tripwire above (#32)

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
    } else if (host_is_windows) b.addRunArtifact(core_tests) else blk: {
        // Zig 0.16's --listen test adapter can label an otherwise passing
        // native test executable as "failed command" while returning success
        // to the build graph. Execute the emitted test binary directly so its
        // real exit status is the test-step result.
        // `env` executes the emitted binary directly while accepting its lazy
        // build path as an argument (SystemCommand requires argv[0] upfront).
        const run = b.addSystemCommand(&.{"env"});
        run.addFileArg(core_tests.getEmittedBin());
        break :blk run;
    };

    const ffi_tests = b.addTest(.{
        .root_module = ffi_mod,
        .filters = test_filters,
    });
    // 0.16: route through Module.
    for (all_c_deps) |dep| ffi_tests.root_module.linkLibrary(dep);
    ffi_tests.root_module.linkLibrary(sqlite3_lib);
    ffi_tests.root_module.link_libc = true;
    ffi_tests.root_module.link_libcpp = true;
    if (force_test_llvm) ffi_tests.use_llvm = true; // see force_test_llvm tripwire above (#32)

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
    } else if (host_is_windows) b.addRunArtifact(ffi_tests) else blk: {
        const run = b.addSystemCommand(&.{"env"});
        run.addFileArg(ffi_tests.getEmittedBin());
        break :blk run;
    };

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_ffi_tests.step);
}
