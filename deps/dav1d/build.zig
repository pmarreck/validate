const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dav1d_src = b.dependency("dav1d_src", .{});

    const is_windows = target.result.os.tag == .windows;

    // Create static library
    const lib = b.addLibrary(.{
        .name = "dav1d",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Core decoder sources (architecture-independent)
    const core_sources: []const []const u8 = &.{
        "src/cdf.c",
        "src/cpu.c",
        "src/ctx.c",
        "src/data.c",
        "src/decode.c",
        "src/dequant_tables.c",
        "src/getbits.c",
        "src/intra_edge.c",
        "src/itx_1d.c",
        "src/lf_mask.c",
        "src/lib.c",
        "src/log.c",
        "src/mem.c",
        "src/msac.c",
        "src/obu.c",
        "src/pal.c",
        "src/picture.c",
        "src/qm.c",
        "src/ref.c",
        "src/refmvs.c",
        "src/scan.c",
        "src/tables.c",
        "src/thread_task.c",
        "src/warpmv.c",
        "src/wedge.c",
    };

    // Template sources that get compiled for each bitdepth
    const tmpl_sources: []const []const u8 = &.{
        "src/cdef_apply_tmpl.c",
        "src/cdef_tmpl.c",
        "src/fg_apply_tmpl.c",
        "src/filmgrain_tmpl.c",
        "src/ipred_prepare_tmpl.c",
        "src/ipred_tmpl.c",
        "src/itx_tmpl.c",
        "src/lf_apply_tmpl.c",
        "src/loopfilter_tmpl.c",
        "src/looprestoration_tmpl.c",
        "src/lr_apply_tmpl.c",
        "src/mc_tmpl.c",
        "src/recon_tmpl.c",
    };

    // ARM64 specific sources
    const arm64_c_sources: []const []const u8 = &.{
        "src/arm/cpu.c",
    };

    // ARM64 assembly sources (common for both 8 and 16 bit)
    const arm64_asm_common: []const []const u8 = &.{
        "src/arm/64/itx.S",
        "src/arm/64/looprestoration_common.S",
        "src/arm/64/msac.S",
        "src/arm/64/refmvs.S",
    };

    // ARM64 assembly sources for 8-bit
    const arm64_asm_8bit: []const []const u8 = &.{
        "src/arm/64/cdef.S",
        "src/arm/64/filmgrain.S",
        "src/arm/64/ipred.S",
        "src/arm/64/loopfilter.S",
        "src/arm/64/looprestoration.S",
        "src/arm/64/mc.S",
        "src/arm/64/mc_dotprod.S",
    };

    // ARM64 assembly sources for 16-bit
    const arm64_asm_16bit: []const []const u8 = &.{
        "src/arm/64/cdef16.S",
        "src/arm/64/filmgrain16.S",
        "src/arm/64/ipred16.S",
        "src/arm/64/itx16.S",
        "src/arm/64/loopfilter16.S",
        "src/arm/64/looprestoration16.S",
        "src/arm/64/mc16.S",
        "src/arm/64/mc16_sve.S",
    };

    // x86_64 specific C sources
    const x86_c_sources: []const []const u8 = &.{
        "src/x86/cpu.c",
    };

    // Generate config.h based on both CPU arch and OS
    const config_h = b.addWriteFiles();
    const cpu_arch = target.result.cpu.arch;

    if (is_windows) {
        if (cpu_arch == .x86_64) {
            _ = config_h.add("config.h", config_h_windows_x86_64);
        } else {
            _ = config_h.add("config.h", config_h_windows_generic);
        }
    } else if (cpu_arch == .aarch64) {
        _ = config_h.add("config.h", config_h_aarch64);
    } else if (cpu_arch == .x86_64) {
        _ = config_h.add("config.h", config_h_x86_64);
    } else {
        _ = config_h.add("config.h", config_h_generic);
    }
    lib.addIncludePath(config_h.getDirectory());

    // Generate vcs_version.h
    const vcs_h = b.addWriteFiles();
    _ = vcs_h.add("vcs_version.h",
        \\#define DAV1D_VERSION "1.5.3"
    );
    lib.addIncludePath(vcs_h.getDirectory());

    // Add include paths
    lib.addIncludePath(dav1d_src.path(""));
    lib.addIncludePath(dav1d_src.path("include"));
    lib.addIncludePath(dav1d_src.path("include/dav1d"));
    lib.addIncludePath(dav1d_src.path("src"));

    const is_macos = target.result.os.tag == .macos;

    // Define architecture-specific flags
    if (cpu_arch == .aarch64) {
        // ARM64 specific flags
        const cflags_aarch64: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DHAVE_PTHREAD_SETNAME_NP=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
            "-fomit-frame-pointer",
        };

        const cflags_8bit_aarch64: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DHAVE_PTHREAD_SETNAME_NP=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
            "-fomit-frame-pointer",
            "-DBITDEPTH=8",
        };

        const cflags_16bit_aarch64: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DHAVE_PTHREAD_SETNAME_NP=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
            "-fomit-frame-pointer",
            "-DBITDEPTH=16",
        };

        // PREFIX adds underscore to symbols - only needed on macOS (Mach-O format)
        // Linux ELF uses undecorated symbol names
        const asm_flags: []const []const u8 = if (is_macos) &.{
            "-DHAVE_ASM=1",
            "-DARCH_AARCH64=1",
            "-DCONFIG_8BPC=1",
            "-DCONFIG_16BPC=1",
            "-DPREFIX",
        } else &.{
            "-DHAVE_ASM=1",
            "-DARCH_AARCH64=1",
            "-DCONFIG_8BPC=1",
            "-DCONFIG_16BPC=1",
        };

        // Add core sources
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = core_sources,
            .flags = cflags_aarch64,
        });

        // Add ARM64 C sources
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = arm64_c_sources,
            .flags = cflags_aarch64,
        });

        // Add template sources for 8-bit
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = tmpl_sources,
            .flags = cflags_8bit_aarch64,
        });

        // Add template sources for 16-bit
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = tmpl_sources,
            .flags = cflags_16bit_aarch64,
        });

        // Add ARM64 assembly
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = arm64_asm_common,
            .flags = asm_flags,
        });
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = arm64_asm_8bit,
            .flags = asm_flags,
        });
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = arm64_asm_16bit,
            .flags = asm_flags,
        });
    } else if (cpu_arch == .x86_64 or cpu_arch == .x86) {
        if (is_windows) {
            // Windows x86/x86_64 flags
            const cflags_win_x86: []const []const u8 = &.{
                "-DHAVE_ALIGNED_ALLOC=1",
                "-DHAVE_IO_H=1",
                "-DHAVE_C11_GENERIC=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
                "-D_WIN32",
            };

            const cflags_8bit_win_x86: []const []const u8 = &.{
                "-DHAVE_ALIGNED_ALLOC=1",
                "-DHAVE_IO_H=1",
                "-DHAVE_C11_GENERIC=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
                "-D_WIN32",
                "-DBITDEPTH=8",
            };

            const cflags_16bit_win_x86: []const []const u8 = &.{
                "-DHAVE_ALIGNED_ALLOC=1",
                "-DHAVE_IO_H=1",
                "-DHAVE_C11_GENERIC=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
                "-D_WIN32",
                "-DBITDEPTH=16",
            };

            // Add core sources
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = core_sources,
                .flags = cflags_win_x86,
            });

            // Add x86 C sources
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = x86_c_sources,
                .flags = cflags_win_x86,
            });

            // Add Windows threading implementation
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = &.{"src/win32/thread.c"},
                .flags = cflags_win_x86,
            });

            // Add template sources for 8-bit
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = tmpl_sources,
                .flags = cflags_8bit_win_x86,
            });

            // Add template sources for 16-bit
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = tmpl_sources,
                .flags = cflags_16bit_win_x86,
            });
        } else {
            // POSIX x86/x86_64 flags (no ASM without NASM)
            const cflags_x86: []const []const u8 = &.{
                "-DHAVE_POSIX_MEMALIGN=1",
                "-DHAVE_UNISTD_H=1",
                "-DHAVE_SYS_TYPES_H=1",
                "-DHAVE_CLOCK_GETTIME=1",
                "-DHAVE_DLSYM=1",
                "-DHAVE_C11_GENERIC=1",
                "-DHAVE_PTHREAD_SETNAME_NP=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
            };

            const cflags_8bit_x86: []const []const u8 = &.{
                "-DHAVE_POSIX_MEMALIGN=1",
                "-DHAVE_UNISTD_H=1",
                "-DHAVE_SYS_TYPES_H=1",
                "-DHAVE_CLOCK_GETTIME=1",
                "-DHAVE_DLSYM=1",
                "-DHAVE_C11_GENERIC=1",
                "-DHAVE_PTHREAD_SETNAME_NP=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
                "-DBITDEPTH=8",
            };

            const cflags_16bit_x86: []const []const u8 = &.{
                "-DHAVE_POSIX_MEMALIGN=1",
                "-DHAVE_UNISTD_H=1",
                "-DHAVE_SYS_TYPES_H=1",
                "-DHAVE_CLOCK_GETTIME=1",
                "-DHAVE_DLSYM=1",
                "-DHAVE_C11_GENERIC=1",
                "-DHAVE_PTHREAD_SETNAME_NP=1",
                "-DNDEBUG",
                "-fvisibility=hidden",
                "-fomit-frame-pointer",
                "-DBITDEPTH=16",
            };

            // Add core sources
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = core_sources,
                .flags = cflags_x86,
            });

            // Add x86 C sources
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = x86_c_sources,
                .flags = cflags_x86,
            });

            // Add template sources for 8-bit
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = tmpl_sources,
                .flags = cflags_8bit_x86,
            });

            // Add template sources for 16-bit
            lib.addCSourceFiles(.{
                .root = dav1d_src.path(""),
                .files = tmpl_sources,
                .flags = cflags_16bit_x86,
            });
        }
    } else {
        // Generic fallback
        const cflags_generic: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
        };

        const cflags_8bit_generic: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
            "-DBITDEPTH=8",
        };

        const cflags_16bit_generic: []const []const u8 = &.{
            "-DHAVE_POSIX_MEMALIGN=1",
            "-DHAVE_UNISTD_H=1",
            "-DHAVE_SYS_TYPES_H=1",
            "-DHAVE_CLOCK_GETTIME=1",
            "-DHAVE_DLSYM=1",
            "-DHAVE_C11_GENERIC=1",
            "-DNDEBUG",
            "-fvisibility=hidden",
            "-DBITDEPTH=16",
        };

        // Add core sources
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = core_sources,
            .flags = cflags_generic,
        });

        // Add template sources for 8-bit
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = tmpl_sources,
            .flags = cflags_8bit_generic,
        });

        // Add template sources for 16-bit
        lib.addCSourceFiles(.{
            .root = dav1d_src.path(""),
            .files = tmpl_sources,
            .flags = cflags_16bit_generic,
        });
    }

    // Link pthread on non-Windows platforms
    if (!is_windows) {
        lib.linkSystemLibrary("pthread");
    }

    // Install headers
    lib.installHeader(dav1d_src.path("include/dav1d/dav1d.h"), "dav1d/dav1d.h");
    lib.installHeader(dav1d_src.path("include/dav1d/common.h"), "dav1d/common.h");
    lib.installHeader(dav1d_src.path("include/dav1d/data.h"), "dav1d/data.h");
    lib.installHeader(dav1d_src.path("include/dav1d/headers.h"), "dav1d/headers.h");
    lib.installHeader(dav1d_src.path("include/dav1d/picture.h"), "dav1d/picture.h");
    lib.installHeader(dav1d_src.path("include/dav1d/version.h"), "dav1d/version.h");

    b.installArtifact(lib);
}

// Config headers for different architectures
const config_h_aarch64 =
    \\/* Auto-generated config.h for dav1d - aarch64 */
    \\#ifndef DAV1D_CONFIG_H
    \\#define DAV1D_CONFIG_H
    \\
    \\#define CONFIG_8BPC 1
    \\#define CONFIG_16BPC 1
    \\#define CONFIG_LOG 0
    \\#define CONFIG_MACOS_KPERF 0
    \\
    \\#define ARCH_AARCH64 1
    \\#define ARCH_ARM 0
    \\#define ARCH_X86 0
    \\#define ARCH_X86_64 0
    \\#define ARCH_X86_32 0
    \\#define ARCH_PPC64LE 0
    \\#define ARCH_RISCV 0
    \\#define ARCH_RV32 0
    \\#define ARCH_RV64 0
    \\#define ARCH_LOONGARCH 0
    \\#define ARCH_LOONGARCH32 0
    \\#define ARCH_LOONGARCH64 0
    \\
    \\#define HAVE_ASM 1
    \\#define HAVE_AS_FUNC 0
    \\
    \\#define ENDIANNESS_BIG 0
    \\
    \\#define HAVE_POSIX_MEMALIGN 1
    \\#define HAVE_MEMALIGN 0
    \\#define HAVE_ALIGNED_ALLOC 0
    \\
    \\#define HAVE_CLOCK_GETTIME 1
    \\#define HAVE_DLSYM 1
    \\
    \\#define HAVE_SYS_TYPES_H 1
    \\#define HAVE_UNISTD_H 1
    \\#define HAVE_IO_H 0
    \\
    \\#define HAVE_PTHREAD_NP_H 0
    \\#define HAVE_GETAUXVAL 0
    \\#define HAVE_ELF_AUX_INFO 0
    \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETNAME_NP 1
    \\#define HAVE_PTHREAD_SET_NAME_NP 0
    \\
    \\#define HAVE_C11_GENERIC 1
    \\
    \\#define TRIM_DSP_FUNCTIONS 1
    \\
    \\#endif /* DAV1D_CONFIG_H */
;

const config_h_x86_64 =
    \\/* Auto-generated config.h for dav1d - x86_64 */
    \\#ifndef DAV1D_CONFIG_H
    \\#define DAV1D_CONFIG_H
    \\
    \\#define CONFIG_8BPC 1
    \\#define CONFIG_16BPC 1
    \\#define CONFIG_LOG 0
    \\#define CONFIG_MACOS_KPERF 0
    \\
    \\#define ARCH_AARCH64 0
    \\#define ARCH_ARM 0
    \\#define ARCH_X86 1
    \\#define ARCH_X86_64 1
    \\#define ARCH_X86_32 0
    \\#define ARCH_PPC64LE 0
    \\#define ARCH_RISCV 0
    \\#define ARCH_RV32 0
    \\#define ARCH_RV64 0
    \\#define ARCH_LOONGARCH 0
    \\#define ARCH_LOONGARCH32 0
    \\#define ARCH_LOONGARCH64 0
    \\
    \\#define HAVE_ASM 0
    \\#define HAVE_AS_FUNC 0
    \\
    \\#define ENDIANNESS_BIG 0
    \\
    \\#define HAVE_POSIX_MEMALIGN 1
    \\#define HAVE_MEMALIGN 0
    \\#define HAVE_ALIGNED_ALLOC 0
    \\
    \\#define HAVE_CLOCK_GETTIME 1
    \\#define HAVE_DLSYM 1
    \\
    \\#define HAVE_SYS_TYPES_H 1
    \\#define HAVE_UNISTD_H 1
    \\#define HAVE_IO_H 0
    \\
    \\#define HAVE_PTHREAD_NP_H 0
    \\#define HAVE_GETAUXVAL 0
    \\#define HAVE_ELF_AUX_INFO 0
    \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETNAME_NP 1
    \\#define HAVE_PTHREAD_SET_NAME_NP 0
    \\
    \\#define HAVE_C11_GENERIC 1
    \\
    \\#define TRIM_DSP_FUNCTIONS 1
    \\
    \\#endif /* DAV1D_CONFIG_H */
;

const config_h_generic =
    \\/* Auto-generated config.h for dav1d - generic */
    \\#ifndef DAV1D_CONFIG_H
    \\#define DAV1D_CONFIG_H
    \\
    \\#define CONFIG_8BPC 1
    \\#define CONFIG_16BPC 1
    \\#define CONFIG_LOG 0
    \\#define CONFIG_MACOS_KPERF 0
    \\
    \\#define ARCH_AARCH64 0
    \\#define ARCH_ARM 0
    \\#define ARCH_X86 0
    \\#define ARCH_X86_64 0
    \\#define ARCH_X86_32 0
    \\#define ARCH_PPC64LE 0
    \\#define ARCH_RISCV 0
    \\#define ARCH_RV32 0
    \\#define ARCH_RV64 0
    \\#define ARCH_LOONGARCH 0
    \\#define ARCH_LOONGARCH32 0
    \\#define ARCH_LOONGARCH64 0
    \\
    \\#define HAVE_ASM 0
    \\#define HAVE_AS_FUNC 0
    \\
    \\#define ENDIANNESS_BIG 0
    \\
    \\#define HAVE_POSIX_MEMALIGN 1
    \\#define HAVE_MEMALIGN 0
    \\#define HAVE_ALIGNED_ALLOC 0
    \\
    \\#define HAVE_CLOCK_GETTIME 1
    \\#define HAVE_DLSYM 1
    \\
    \\#define HAVE_SYS_TYPES_H 1
    \\#define HAVE_UNISTD_H 1
    \\#define HAVE_IO_H 0
    \\
    \\#define HAVE_PTHREAD_NP_H 0
    \\#define HAVE_GETAUXVAL 0
    \\#define HAVE_ELF_AUX_INFO 0
    \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETNAME_NP 0
    \\#define HAVE_PTHREAD_SET_NAME_NP 0
    \\
    \\#define HAVE_C11_GENERIC 1
    \\
    \\#define TRIM_DSP_FUNCTIONS 1
    \\
    \\#endif /* DAV1D_CONFIG_H */
;

const config_h_windows_x86_64 =
    \\/* Auto-generated config.h for dav1d - Windows x86_64 */
    \\#ifndef DAV1D_CONFIG_H
    \\#define DAV1D_CONFIG_H
    \\
    \\#define CONFIG_8BPC 1
    \\#define CONFIG_16BPC 1
    \\#define CONFIG_LOG 0
    \\#define CONFIG_MACOS_KPERF 0
    \\
    \\#define ARCH_AARCH64 0
    \\#define ARCH_ARM 0
    \\#define ARCH_X86 1
    \\#define ARCH_X86_64 1
    \\#define ARCH_X86_32 0
    \\#define ARCH_PPC64LE 0
    \\#define ARCH_RISCV 0
    \\#define ARCH_RV32 0
    \\#define ARCH_RV64 0
    \\#define ARCH_LOONGARCH 0
    \\#define ARCH_LOONGARCH32 0
    \\#define ARCH_LOONGARCH64 0
    \\
    \\#define HAVE_ASM 0
    \\#define HAVE_AS_FUNC 0
    \\
    \\#define ENDIANNESS_BIG 0
    \\
    \\#define HAVE_POSIX_MEMALIGN 0
    \\#define HAVE_MEMALIGN 0
    \\#define HAVE_ALIGNED_ALLOC 1
    \\
    \\#define HAVE_CLOCK_GETTIME 0
    \\#define HAVE_DLSYM 0
    \\
    \\#define HAVE_SYS_TYPES_H 0
    \\#define HAVE_UNISTD_H 0
    \\#define HAVE_IO_H 1
    \\
    \\#define HAVE_PTHREAD_NP_H 0
    \\#define HAVE_GETAUXVAL 0
    \\#define HAVE_ELF_AUX_INFO 0
    \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETNAME_NP 0
    \\#define HAVE_PTHREAD_SET_NAME_NP 0
    \\
    \\#define HAVE_C11_GENERIC 1
    \\
    \\#define TRIM_DSP_FUNCTIONS 1
    \\
    \\#endif /* DAV1D_CONFIG_H */
;

const config_h_windows_generic =
    \\/* Auto-generated config.h for dav1d - Windows generic */
    \\#ifndef DAV1D_CONFIG_H
    \\#define DAV1D_CONFIG_H
    \\
    \\#define CONFIG_8BPC 1
    \\#define CONFIG_16BPC 1
    \\#define CONFIG_LOG 0
    \\#define CONFIG_MACOS_KPERF 0
    \\
    \\#define ARCH_AARCH64 0
    \\#define ARCH_ARM 0
    \\#define ARCH_X86 0
    \\#define ARCH_X86_64 0
    \\#define ARCH_X86_32 0
    \\#define ARCH_PPC64LE 0
    \\#define ARCH_RISCV 0
    \\#define ARCH_RV32 0
    \\#define ARCH_RV64 0
    \\#define ARCH_LOONGARCH 0
    \\#define ARCH_LOONGARCH32 0
    \\#define ARCH_LOONGARCH64 0
    \\
    \\#define HAVE_ASM 0
    \\#define HAVE_AS_FUNC 0
    \\
    \\#define ENDIANNESS_BIG 0
    \\
    \\#define HAVE_POSIX_MEMALIGN 0
    \\#define HAVE_MEMALIGN 0
    \\#define HAVE_ALIGNED_ALLOC 1
    \\
    \\#define HAVE_CLOCK_GETTIME 0
    \\#define HAVE_DLSYM 0
    \\
    \\#define HAVE_SYS_TYPES_H 0
    \\#define HAVE_UNISTD_H 0
    \\#define HAVE_IO_H 1
    \\
    \\#define HAVE_PTHREAD_NP_H 0
    \\#define HAVE_GETAUXVAL 0
    \\#define HAVE_ELF_AUX_INFO 0
    \\#define HAVE_PTHREAD_GETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETAFFINITY_NP 0
    \\#define HAVE_PTHREAD_SETNAME_NP 0
    \\#define HAVE_PTHREAD_SET_NAME_NP 0
    \\
    \\#define HAVE_C11_GENERIC 1
    \\
    \\#define TRIM_DSP_FUNCTIONS 1
    \\
    \\#endif /* DAV1D_CONFIG_H */
;
