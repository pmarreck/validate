const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fdk_aac_src = b.dependency("fdk_aac_src", .{});

    // Create static library
    const lib = b.addLibrary(.{
        .name = "fdk-aac",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    // Common C++ flags
    // Note: -Wno-date-time suppresses errors about __DATE__/__TIME__ macros for reproducibility
    const cxxflags: []const []const u8 = &.{
        "-fvisibility=hidden",
        "-fno-exceptions",
        "-fno-rtti",
        "-Wno-date-time",
    };

    // Core FDK library sources (v2.0.3)
    const libFDK_sources: []const []const u8 = &.{
        "libFDK/src/FDK_bitbuffer.cpp",
        "libFDK/src/FDK_core.cpp",
        "libFDK/src/FDK_crc.cpp",
        "libFDK/src/FDK_decorrelate.cpp",
        "libFDK/src/FDK_hybrid.cpp",
        "libFDK/src/FDK_lpc.cpp",
        "libFDK/src/FDK_matrixCalloc.cpp",
        "libFDK/src/FDK_qmf_domain.cpp",
        "libFDK/src/FDK_tools_rom.cpp",
        "libFDK/src/FDK_trigFcts.cpp",
        "libFDK/src/autocorr2nd.cpp",
        "libFDK/src/dct.cpp",
        "libFDK/src/fft.cpp",
        "libFDK/src/fft_rad2.cpp",
        "libFDK/src/fixpoint_math.cpp",
        "libFDK/src/huff_nodes.cpp",
        "libFDK/src/mdct.cpp",
        "libFDK/src/nlc_dec.cpp",
        "libFDK/src/qmf.cpp",
        "libFDK/src/scale.cpp",
    };

    // System abstraction sources
    const libSYS_sources: []const []const u8 = &.{
        "libSYS/src/genericStds.cpp",
        "libSYS/src/syslib_channelMapDescr.cpp",
    };

    // AAC decoder sources (v2.0.3)
    const libAACdec_sources: []const []const u8 = &.{
        "libAACdec/src/FDK_delay.cpp",
        "libAACdec/src/aac_ram.cpp",
        "libAACdec/src/aac_rom.cpp",
        "libAACdec/src/aacdec_drc.cpp",
        "libAACdec/src/aacdec_hcr.cpp",
        "libAACdec/src/aacdec_hcr_bit.cpp",
        "libAACdec/src/aacdec_hcrs.cpp",
        "libAACdec/src/aacdec_pns.cpp",
        "libAACdec/src/aacdec_tns.cpp",
        "libAACdec/src/aacdecoder.cpp",
        "libAACdec/src/aacdecoder_lib.cpp",
        "libAACdec/src/block.cpp",
        "libAACdec/src/channel.cpp",
        "libAACdec/src/channelinfo.cpp",
        "libAACdec/src/conceal.cpp",
        "libAACdec/src/ldfiltbank.cpp",
        "libAACdec/src/pulsedata.cpp",
        "libAACdec/src/rvlc.cpp",
        "libAACdec/src/rvlcbit.cpp",
        "libAACdec/src/rvlcconceal.cpp",
        "libAACdec/src/stereo.cpp",
        "libAACdec/src/usacdec_ace_d4t64.cpp",
        "libAACdec/src/usacdec_ace_ltp.cpp",
        "libAACdec/src/usacdec_acelp.cpp",
        "libAACdec/src/usacdec_fac.cpp",
        "libAACdec/src/usacdec_lpc.cpp",
        "libAACdec/src/usacdec_lpd.cpp",
        "libAACdec/src/usacdec_rom.cpp",
    };

    // MPEG Transport decoder sources
    const libMpegTPDec_sources: []const []const u8 = &.{
        "libMpegTPDec/src/tpdec_adif.cpp",
        "libMpegTPDec/src/tpdec_adts.cpp",
        "libMpegTPDec/src/tpdec_asc.cpp",
        "libMpegTPDec/src/tpdec_drm.cpp",
        "libMpegTPDec/src/tpdec_latm.cpp",
        "libMpegTPDec/src/tpdec_lib.cpp",
    };

    // SBR decoder sources (v2.0.3)
    const libSBRdec_sources: []const []const u8 = &.{
        "libSBRdec/src/HFgen_preFlat.cpp",
        "libSBRdec/src/env_calc.cpp",
        "libSBRdec/src/env_dec.cpp",
        "libSBRdec/src/env_extr.cpp",
        "libSBRdec/src/hbe.cpp",
        "libSBRdec/src/huff_dec.cpp",
        "libSBRdec/src/lpp_tran.cpp",
        "libSBRdec/src/psbitdec.cpp",
        "libSBRdec/src/psdec.cpp",
        "libSBRdec/src/psdec_drm.cpp",
        "libSBRdec/src/psdecrom_drm.cpp",
        "libSBRdec/src/pvc_dec.cpp",
        "libSBRdec/src/sbr_deb.cpp",
        "libSBRdec/src/sbr_dec.cpp",
        "libSBRdec/src/sbr_ram.cpp",
        "libSBRdec/src/sbr_rom.cpp",
        "libSBRdec/src/sbrdec_drc.cpp",
        "libSBRdec/src/sbrdec_freq_sca.cpp",
        "libSBRdec/src/sbrdecoder.cpp",
    };

    // PCM utilities sources
    const libPCMutils_sources: []const []const u8 = &.{
        "libPCMutils/src/limiter.cpp",
        "libPCMutils/src/pcm_utils.cpp",
        "libPCMutils/src/pcmdmx_lib.cpp",
    };

    // Arithmetic coding sources
    const libArithCoding_sources: []const []const u8 = &.{
        "libArithCoding/src/ac_arith_coder.cpp",
    };

    // DRC decoder sources
    const libDRCdec_sources: []const []const u8 = &.{
        "libDRCdec/src/drcDec_gainDecoder.cpp",
        "libDRCdec/src/drcDec_reader.cpp",
        "libDRCdec/src/drcDec_rom.cpp",
        "libDRCdec/src/drcDec_selectionProcess.cpp",
        "libDRCdec/src/drcDec_tools.cpp",
        "libDRCdec/src/drcGainDec_init.cpp",
        "libDRCdec/src/drcGainDec_preprocess.cpp",
        "libDRCdec/src/drcGainDec_process.cpp",
        "libDRCdec/src/FDK_drcDecLib.cpp",
    };

    // SAC decoder sources
    const libSACdec_sources: []const []const u8 = &.{
        "libSACdec/src/sac_bitdec.cpp",
        "libSACdec/src/sac_calcM1andM2.cpp",
        "libSACdec/src/sac_dec.cpp",
        "libSACdec/src/sac_dec_conceal.cpp",
        "libSACdec/src/sac_dec_lib.cpp",
        "libSACdec/src/sac_process.cpp",
        "libSACdec/src/sac_qmf.cpp",
        "libSACdec/src/sac_reshapeBBEnv.cpp",
        "libSACdec/src/sac_rom.cpp",
        "libSACdec/src/sac_smoothing.cpp",
        "libSACdec/src/sac_stp.cpp",
        "libSACdec/src/sac_tsd.cpp",
    };

    // Add include paths
    lib.addIncludePath(fdk_aac_src.path("libAACdec/include"));
    lib.addIncludePath(fdk_aac_src.path("libFDK/include"));
    lib.addIncludePath(fdk_aac_src.path("libSYS/include"));
    lib.addIncludePath(fdk_aac_src.path("libMpegTPDec/include"));
    lib.addIncludePath(fdk_aac_src.path("libSBRdec/include"));
    lib.addIncludePath(fdk_aac_src.path("libPCMutils/include"));
    lib.addIncludePath(fdk_aac_src.path("libArithCoding/include"));
    lib.addIncludePath(fdk_aac_src.path("libDRCdec/include"));
    lib.addIncludePath(fdk_aac_src.path("libSACdec/include"));

    // Add sources
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libFDK_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libSYS_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libAACdec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libMpegTPDec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libSBRdec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libPCMutils_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libArithCoding_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libDRCdec_sources,
        .flags = cxxflags,
    });
    lib.addCSourceFiles(.{
        .root = fdk_aac_src.path(""),
        .files = libSACdec_sources,
        .flags = cxxflags,
    });

    // Install headers
    lib.installHeader(fdk_aac_src.path("libAACdec/include/aacdecoder_lib.h"), "fdk-aac/aacdecoder_lib.h");
    lib.installHeader(fdk_aac_src.path("libSYS/include/FDK_audio.h"), "fdk-aac/FDK_audio.h");
    lib.installHeader(fdk_aac_src.path("libSYS/include/genericStds.h"), "fdk-aac/genericStds.h");
    lib.installHeader(fdk_aac_src.path("libSYS/include/machine_type.h"), "fdk-aac/machine_type.h");
    lib.installHeader(fdk_aac_src.path("libSYS/include/syslib_channelMapDescr.h"), "fdk-aac/syslib_channelMapDescr.h");

    b.installArtifact(lib);
}
