const std = @import("std");

// Monkey's Audio SDK 12.73 — decompress-only build. Used by validate's APE
// deep validator to decode every frame and surface per-frame CRC32 mismatches
// (the 32-bit CRC stored at the start of each frame is computed over the
// DECODED PCM samples, per APEDecompressCore.cpp::EndFrame, so structural
// validation cannot catch any payload corruption — only a real decoder can).
//
// We compile the upstream MAC SDK as a single static C++ library with
// PLATFORM_LINUX/APPLE/WINDOWS defines selecting the right shims. The
// shim.cpp file in this directory exposes a tiny `extern "C"` interface
// (validate_ape_decode_check) so the Zig validator can call into it via
// @cImport without dealing with C++ name-mangling or the IAPEDecompress
// virtual interface.

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const mac = b.dependency("mac_sdk", .{});

	const lib = b.addLibrary(.{
		.name = "ape",
		.linkage = .static,
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
			.link_libc = true,
			.link_libcpp = true,
		}),
	});

	const t = target.result;
	const platform_def: []const u8 = if (t.os.tag == .windows)
		"-DPLATFORM_WINDOWS"
	else if (t.os.tag == .macos or t.os.tag == .ios or t.os.tag == .tvos or t.os.tag == .watchos)
		"-DPLATFORM_APPLE"
	else
		"-DPLATFORM_LINUX";

	// Decompress-only subset. We exclude the encode side (APECompress*.cpp)
	// and the WAVInputSource (the encoder's only consumer of WAV files —
	// our decoder never sees a file path). MACLib.cpp still references
	// CAPECompress::CAPECompress in CreateIAPECompress, so we DO need to
	// compile the encoder source files just so the linker has all the
	// symbols, but in a static-link archive the unused encode entry points
	// will be dropped.
	//
	// Old/* are needed for legacy (v3800-v3970) APE files via the
	// APE_BACKWARDS_COMPATIBILITY path inside MACLib.cpp.
	//
	// NNFilter*.cpp arch-specific variants (AVX, AVX2, AVX512, NEON, RVV,
	// SSE2, SSE4.1, AltiVec) are skipped — only NNFilterGeneric.cpp is
	// compiled, which gives us a portable build that cross-compiles to all
	// 5 OS/arch targets without per-target asm fiddling.
	const shared_sources: []const []const u8 = &.{
		"Source/Shared/BufferIO.cpp",
		"Source/Shared/CharacterHelper.cpp",
		"Source/Shared/CircleBuffer.cpp",
		"Source/Shared/CPUFeatures.cpp",
		"Source/Shared/CRC.cpp",
		"Source/Shared/GlobalFunctions.cpp",
		"Source/Shared/MemoryIO.cpp",
		"Source/Shared/Semaphore.cpp",
		"Source/Shared/Thread.cpp",
		"Source/Shared/WholeFileIO.cpp",
	};

	const shared_unix: []const []const u8 = &.{
		"Source/Shared/StdLibFileIO.cpp",
	};
	const shared_windows: []const []const u8 = &.{
		"Source/Shared/WinFileIO.cpp",
	};

	const maclib_sources: []const []const u8 = &.{
		"Source/MACLib/APECompress.cpp",
		"Source/MACLib/APECompressCore.cpp",
		"Source/MACLib/APECompressCreate.cpp",
		"Source/MACLib/APEDecompress.cpp",
		"Source/MACLib/APEDecompressCore.cpp",
		"Source/MACLib/APEHeader.cpp",
		"Source/MACLib/APEInfo.cpp",
		"Source/MACLib/APELink.cpp",
		"Source/MACLib/APETag.cpp",
		"Source/MACLib/BitArray.cpp",
		"Source/MACLib/FloatTransform.cpp",
		"Source/MACLib/MACLib.cpp",
		"Source/MACLib/MACProgressHelper.cpp",
		"Source/MACLib/MD5.cpp",
		"Source/MACLib/NewPredictor.cpp",
		"Source/MACLib/NNFilter.cpp",
		"Source/MACLib/NNFilterGeneric.cpp",
		"Source/MACLib/Prepare.cpp",
		"Source/MACLib/UnBitArray.cpp",
		"Source/MACLib/UnBitArrayBase.cpp",
		"Source/MACLib/WAVInputSource.cpp",
		"Source/MACLib/Old/AntiPredictorExtraHighOld.cpp",
		"Source/MACLib/Old/AntiPredictorFastOld.cpp",
		"Source/MACLib/Old/AntiPredictorHighOld.cpp",
		"Source/MACLib/Old/AntiPredictorNormalOld.cpp",
		"Source/MACLib/Old/AntiPredictorOld.cpp",
		"Source/MACLib/Old/APEDecompressCoreOld.cpp",
		"Source/MACLib/Old/APEDecompressOld.cpp",
		"Source/MACLib/Old/UnBitArrayOld.cpp",
		"Source/MACLib/Old/UnMACOld.cpp",
	};

	// Arch-specific NNFilter sources. The base CNNFilter constructor
	// unconditionally references CompressNeon/DecompressNeon symbols on
	// arm/aarch64 (and the x86 variants on x86_64/x86), so we MUST
	// provide them at link time even in a generic build. We compile only
	// the matching arch's variant for the target — none cross-arch.
	const arm_sources: []const []const u8 = &.{
		"Source/MACLib/NNFilterNeon.cpp",
	};
	const x86_sources: []const []const u8 = &.{
		"Source/MACLib/NNFilterAVX2.cpp",
		"Source/MACLib/NNFilterAVX512.cpp",
		"Source/MACLib/NNFilterSSE2.cpp",
		"Source/MACLib/NNFilterSSE4.1.cpp",
	};
	const ppc_sources: []const []const u8 = &.{
		"Source/MACLib/NNFilterAltiVec.cpp",
	};
	const rv_sources: []const []const u8 = &.{
		"Source/MACLib/NNFilterRVV.cpp",
	};

	const cflags: []const []const u8 = &.{
		platform_def,
		// APE_BACKWARDS_COMPATIBILITY (legacy v3800-3970 decoder) is already
		// defined unconditionally inside Source/Shared/All.h:140.
		"-fvisibility=hidden",
		"-fno-strict-aliasing",
		"-Wno-unused-parameter",
		"-Wno-unused-variable",
		"-Wno-unused-function",
		"-Wno-unused-but-set-variable",
		"-Wno-sign-compare",
		"-Wno-implicit-fallthrough",
		"-Wno-deprecated-declarations",
		"-Wno-overloaded-virtual",
		"-Wno-format",
		"-std=c++11",
	};

	// MAC SDK Source/Shared/All.h:81 does #include <Windows.h> (capital W).
	// Zig's bundled mingw provides windows.h (lowercase) only. macOS APFS and
	// Windows NTFS are case-insensitive by default so the include resolves
	// there; case-sensitive filesystems (Linux ext4, Garnix builders) reject
	// it. Add a Windows.h shim that forwards to lowercase windows.h, on the
	// include path BEFORE the system includes for Windows targets.
	if (t.os.tag == .windows) {
		lib.addIncludePath(b.path("winshim"));
	}

	lib.addIncludePath(mac.path("Source/Shared"));
	lib.addIncludePath(mac.path("Source/MACLib"));
	lib.addIncludePath(mac.path("Shared"));

	lib.addCSourceFiles(.{
		.root = mac.path(""),
		.files = shared_sources,
		.flags = cflags,
	});
	if (t.os.tag == .windows) {
		lib.addCSourceFiles(.{
			.root = mac.path(""),
			.files = shared_windows,
			.flags = cflags,
		});
	} else {
		lib.addCSourceFiles(.{
			.root = mac.path(""),
			.files = shared_unix,
			.flags = cflags,
		});
	}
	lib.addCSourceFiles(.{
		.root = mac.path(""),
		.files = maclib_sources,
		.flags = cflags,
	});

	// Add arch-specific NNFilter sources. The x86 variants need their
	// own per-file CFLAGS (-mavx2, -mavx512dq, -msse4.1) so the
	// intrinsics they use compile against a wider feature set than the
	// rest of the library; the base library still runs on a CPU lacking
	// those instructions thanks to the runtime CPUID dispatch in
	// NNFilter.cpp.
	const arch = t.cpu.arch;
	if (arch == .arm or arch == .aarch64 or arch == .aarch64_be or arch == .thumb) {
		lib.addCSourceFiles(.{
			.root = mac.path(""),
			.files = arm_sources,
			.flags = cflags,
		});
	} else if (arch == .x86 or arch == .x86_64) {
		_ = x86_sources;
		const make_flags = struct {
			fn f(b2: *std.Build, base: []const []const u8, extra: []const []const u8) [][]const u8 {
				const out = b2.allocator.alloc([]const u8, base.len + extra.len) catch @panic("OOM");
				for (base, 0..) |s, i| out[i] = s;
				for (extra, 0..) |s, i| out[base.len + i] = s;
				return out;
			}
		};
		const sse2_flags = make_flags.f(b, cflags, &.{"-msse2"});
		const sse41_flags = make_flags.f(b, cflags, &.{"-msse4.1"});
		const avx2_flags = make_flags.f(b, cflags, &.{"-mavx2"});
		const avx512_flags = make_flags.f(b, cflags, &.{ "-mavx512dq", "-mavx512bw" });
		lib.addCSourceFile(.{ .file = mac.path("Source/MACLib/NNFilterSSE2.cpp"), .flags = sse2_flags });
		lib.addCSourceFile(.{ .file = mac.path("Source/MACLib/NNFilterSSE4.1.cpp"), .flags = sse41_flags });
		lib.addCSourceFile(.{ .file = mac.path("Source/MACLib/NNFilterAVX2.cpp"), .flags = avx2_flags });
		lib.addCSourceFile(.{ .file = mac.path("Source/MACLib/NNFilterAVX512.cpp"), .flags = avx512_flags });
	} else if (arch == .powerpc or arch == .powerpc64 or arch == .powerpc64le) {
		lib.addCSourceFiles(.{
			.root = mac.path(""),
			.files = ppc_sources,
			.flags = cflags,
		});
	} else if (arch == .riscv32 or arch == .riscv64) {
		lib.addCSourceFiles(.{
			.root = mac.path(""),
			.files = rv_sources,
			.flags = cflags,
		});
	}

	// Our shim — relative to deps/libape, not to the upstream tree.
	lib.addCSourceFile(.{
		.file = b.path("shim.cpp"),
		.flags = cflags,
	});

	lib.installHeader(b.path("shim.h"), "validate_ape_shim.h");

	b.installArtifact(lib);
}
