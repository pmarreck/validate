const std = @import("std");

// libwavpack 5.9.0 — decode-only build, lossless mode. No DSD, no legacy v3,
// no encoder, no asm. Used by validate's WavPack deep validator to decode each
// block to PCM and surface CRC mismatches via WavpackGetNumErrors().
//
// libwavpack does NOT use config.h-style autotools probes in its source files,
// so we simply compile the upstream tree directly with a small set of -Wno-*
// flags to silence harmless warnings. No vendored config/ dir needed.

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const wavpack_src = b.dependency("wavpack_src", .{});

	const lib = b.addLibrary(.{
		.name = "wavpack",
		.linkage = .static,
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});

	const cflags: []const []const u8 = &.{
		"-fvisibility=hidden",
		"-Wno-pointer-sign",
		"-Wno-unused-function",
		"-Wno-unused-variable",
		"-Wno-unused-but-set-variable",
		"-Wno-implicit-function-declaration",
		"-Wno-sign-compare",
		// Zig uses clang which always supports __builtin_clz; this makes
		// wavpack_local.h's count_bits() take the GCC-builtin path instead
		// of falling back to MSVC's _BitScanReverse on _WIN64 (mingw-gnu
		// targets define _WIN64 but lack the MSVC intrinsic).
		"-DHAVE___BUILTIN_CLZ=1",
	};

	// Decode-only subset (lossless). Mirrors Makefile.am's
	// libwavpack_la_SOURCES minus pack_*, write_words, extra*,
	// pack_dsd, unpack_dsd, unpack3*, open_filename (filesystem
	// I/O wrappers — we use WavpackOpenFileInputEx64 with a custom
	// in-memory stream reader instead).
	const sources: []const []const u8 = &.{
		"src/common_utils.c",
		"src/decorr_utils.c",
		"src/entropy_utils.c",
		"src/open_utils.c",
		"src/open_legacy.c",
		"src/open_raw.c",
		"src/read_words.c",
		"src/tag_utils.c",
		"src/tags.c",
		"src/unpack.c",
		"src/unpack_floats.c",
		"src/unpack_seek.c",
		"src/unpack_utils.c",
	};

	lib.root_module.addIncludePath(wavpack_src.path("include"));
	lib.root_module.addIncludePath(wavpack_src.path("src"));

	lib.root_module.addCSourceFiles(.{
		.root = wavpack_src.path(""),
		.files = sources,
		.flags = cflags,
	});

	// Install the public header so consumers can @cImport "wavpack.h".
	lib.installHeader(wavpack_src.path("include/wavpack.h"), "wavpack.h");

	b.installArtifact(lib);
}
