const std = @import("std");

// libvpx 1.14.1 — decoder-only, generic-gnu target (pure C, no asm, no intrinsics).
// Config flags chosen to mirror:
//   configure --target=generic-gnu --disable-unit-tests --disable-examples
//             --disable-tools --disable-docs --disable-vp8-encoder
//             --disable-vp9-encoder --enable-vp8-decoder --enable-vp9-decoder
//             --disable-runtime-cpu-detect --enable-static --disable-shared
//             --disable-multithread
// The pre-generated config/*.h and vpx_config.c were produced by that
// configure+make and are vendored in deps/libvpx/config/ so the Zig build
// needs neither perl nor a configure step at build time.

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const vpx_src = b.dependency("vpx_src", .{});

	const lib = b.addLibrary(.{
		.name = "vpx",
		.linkage = .static,
		.root_module = b.createModule(.{
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});

	const cflags: []const []const u8 = &.{
		"-fvisibility=hidden",
		"-DHAVE_CONFIG_H=1",
		"-Wno-unused-function",
		"-Wno-unused-but-set-variable",
		"-Wno-unused-variable",
		"-Wno-sign-compare",
	};

	// The 82 C sources actually compiled by generic-gnu decoder-only libvpx.
	// Source of truth: .d files produced by `make` on the configured tree.
	const sources: []const []const u8 = &.{
		// vp8 common
		"vp8/common/alloccommon.c",
		"vp8/common/blockd.c",
		"vp8/common/dequantize.c",
		"vp8/common/entropy.c",
		"vp8/common/entropymode.c",
		"vp8/common/entropymv.c",
		"vp8/common/extend.c",
		"vp8/common/filter.c",
		"vp8/common/findnearmv.c",
		"vp8/common/generic/systemdependent.c",
		"vp8/common/idct_blk.c",
		"vp8/common/idctllm.c",
		"vp8/common/loopfilter_filters.c",
		"vp8/common/mbpitch.c",
		"vp8/common/modecont.c",
		"vp8/common/quant_common.c",
		"vp8/common/reconinter.c",
		"vp8/common/reconintra.c",
		"vp8/common/reconintra4x4.c",
		"vp8/common/rtcd.c",
		"vp8/common/setupintrarecon.c",
		"vp8/common/swapyv12buffer.c",
		"vp8/common/treecoder.c",
		"vp8/common/vp8_loopfilter.c",
		// vp8 decoder
		"vp8/decoder/dboolhuff.c",
		"vp8/decoder/decodeframe.c",
		"vp8/decoder/decodemv.c",
		"vp8/decoder/detokenize.c",
		"vp8/decoder/onyxd_if.c",
		"vp8/decoder/threading.c", // multithreaded VP8 decode (CONFIG_MULTITHREAD=1)
		"vp8/vp8_dx_iface.c",
		// vp9 common
		"vp9/common/vp9_alloccommon.c",
		"vp9/common/vp9_blockd.c",
		"vp9/common/vp9_common_data.c",
		"vp9/common/vp9_entropy.c",
		"vp9/common/vp9_entropymode.c",
		"vp9/common/vp9_entropymv.c",
		"vp9/common/vp9_filter.c",
		"vp9/common/vp9_frame_buffers.c",
		"vp9/common/vp9_idct.c",
		"vp9/common/vp9_loopfilter.c",
		"vp9/common/vp9_mvref_common.c",
		"vp9/common/vp9_pred_common.c",
		"vp9/common/vp9_quant_common.c",
		"vp9/common/vp9_reconinter.c",
		"vp9/common/vp9_reconintra.c",
		"vp9/common/vp9_rtcd.c",
		"vp9/common/vp9_scale.c",
		"vp9/common/vp9_scan.c",
		"vp9/common/vp9_seg_common.c",
		"vp9/common/vp9_thread_common.c",
		"vp9/common/vp9_tile_common.c",
		// vp9 decoder
		"vp9/decoder/vp9_decodeframe.c",
		"vp9/decoder/vp9_decodemv.c",
		"vp9/decoder/vp9_decoder.c",
		"vp9/decoder/vp9_detokenize.c",
		"vp9/decoder/vp9_dsubexp.c",
		"vp9/decoder/vp9_job_queue.c",
		"vp9/vp9_dx_iface.c",
		"vp9/vp9_iface_common.c",
		// vpx_dsp
		"vpx_dsp/bitreader.c",
		"vpx_dsp/bitreader_buffer.c",
		"vpx_dsp/intrapred.c",
		"vpx_dsp/inv_txfm.c",
		"vpx_dsp/loopfilter.c",
		"vpx_dsp/prob.c",
		"vpx_dsp/skin_detection.c",
		"vpx_dsp/vpx_convolve.c",
		"vpx_dsp/vpx_dsp_rtcd.c",
		// vpx_mem
		"vpx_mem/vpx_mem.c",
		// vpx_scale
		"vpx_scale/generic/gen_scalers.c",
		"vpx_scale/generic/vpx_scale.c",
		"vpx_scale/generic/yv12config.c",
		"vpx_scale/generic/yv12extend.c",
		"vpx_scale/vpx_scale_rtcd.c",
		// vpx_util
		"vpx_util/vpx_thread.c",
		"vpx_util/vpx_write_yuv_frame.c",
		// vpx (public API)
		"vpx/src/vpx_codec.c",
		"vpx/src/vpx_decoder.c",
		"vpx/src/vpx_encoder.c",
		"vpx/src/vpx_image.c",
		"vpx/src/vpx_tpl.c",
	};

	// Pre-generated config headers live in deps/libvpx/config/.
	// They must be on the include path BEFORE the upstream tree so the
	// #include "vpx_config.h" etc. resolve to the vendored ones rather
	// than being missing.
	lib.root_module.addIncludePath(b.path("config"));

	// Upstream source roots. libvpx's includes are consistently relative
	// to the package root (e.g. #include "vp8/common/blockd.h",
	// #include "vpx/vpx_codec.h", etc.).
	lib.root_module.addIncludePath(vpx_src.path(""));
	lib.root_module.addIncludePath(vpx_src.path("vpx"));

	lib.root_module.addCSourceFiles(.{
		.root = vpx_src.path(""),
		.files = sources,
		.flags = cflags,
	});

	// Also compile the vendored vpx_config.c which exposes the runtime
	// vpx_codec_build_config() string used by vpx_codec_iface_name().
	lib.root_module.addCSourceFiles(.{
		.root = b.path("config"),
		.files = &.{"vpx_config.c"},
		.flags = cflags,
	});

	// Install the public headers so consumers can @cImport "vpx/*.h".
	const public_headers: []const []const u8 = &.{
		"vpx/vpx_codec.h",
		"vpx/vpx_decoder.h",
		"vpx/vpx_encoder.h",
		"vpx/vpx_frame_buffer.h",
		"vpx/vpx_image.h",
		"vpx/vpx_integer.h",
		"vpx/vpx_tpl.h",
		"vpx/vpx_ext_ratectrl.h",
		"vpx/vp8.h",
		"vpx/vp8cx.h",
		"vpx/vp8dx.h",
	};
	for (public_headers) |h| {
		lib.installHeader(vpx_src.path(h), h);
	}

	b.installArtifact(lib);
}
