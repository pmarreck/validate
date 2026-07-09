{
	description = "Validate - Deterministic file format validation";

	inputs = {
		# Temporary pin for NixOS/nixpkgs#539430: fixes pkgsCross.ucrtAarch64
		# compiler-rt/libatomic bootstrap. Revert to
		# github:NixOS/nixpkgs/nixpkgs-unstable after the fix reaches unstable.
		nixpkgs.url = "github:pmarreck/nixpkgs/a7a4d71bff5de2da3924b6893ed95dbf4ac1e7aa";
	};

	outputs = { self, nixpkgs }:
		let
			# All systems for devShells (local development)
			# No x86_64-darwin: Apple is phasing out Rosetta; native aarch64 build suffices
			allSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;

			# Build systems (where we run builds - Linux for CI, Darwin for local)
			buildSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
			forBuildSystems = nixpkgs.lib.genAttrs buildSystems;

			# Zig target triples for cross-compilation
			# Using musl for Linux cross-compilation (better static linking support)
			zigTargets = {
				"x86_64-linux" = "x86_64-linux-musl";
				"aarch64-linux" = "aarch64-linux-musl";
				"x86_64-windows" = "x86_64-windows-gnu";
				"aarch64-windows" = "aarch64-windows-gnu";
				"x86_64-darwin" = "x86_64-macos";
				"aarch64-darwin" = "aarch64-macos";
			};

			# Pre-fetched Zig dependencies (fixed-output derivation)
			# This hash must be updated when build.zig.zon changes
			zigDepsHash = "sha256-kuybHWyHdhbF2bxSiexE+gSnRWbyHJsMwpAJLsuEVFs=";
		in {
			# Packages for Garnix/Nix builds
			packages = forBuildSystems (buildSystem:
				let
					pkgs = import nixpkgs { system = buildSystem; };
					isDarwin = pkgs.stdenv.isDarwin;

					# Fixed-output derivation to fetch Zig dependencies
					# Runs with network access due to known output hash
					zigDeps = pkgs.stdenv.mkDerivation {
						pname = "validate-zig-deps";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = with pkgs; [ zig git cacert ];

						outputHashMode = "recursive";
						outputHashAlgo = "sha256";
						outputHash = zigDepsHash;

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$out
							# Zig 0.16 needs these subdirs to pre-exist or its
							# package fetcher fails on .zip transitive deps with
							# the misleading 'failed to create temporary zip
							# file: FileNotFound' (the parent dir is missing,
							# not the file). Diagnosed 2026-05-21.
							mkdir -p $out/tmp $out/p $out/o
							export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							zig build --fetch=all
						'';

						dontInstall = true;
						dontFixup = true;
					};

					# Build function for a specific target
					mkValidate = { targetSystem ? buildSystem, cross ? false }:
						let
							zigTarget = zigTargets.${targetSystem};
							targetIsDarwin = builtins.match ".*darwin" targetSystem != null;
							targetIsWindows = builtins.match ".*windows" targetSystem != null;
							binaryName = if targetIsWindows then "validate.exe" else "validate";
							# Cross-compiled C deps (libjpeg-turbo/openjpeg/zlib) from nixpkgs
							# pkgsCross, forwarded to jpegz/tiffz so cross packages link real
							# libs (native gets host pkgs below). Reproducible, no system search.
							crossPkgsFor = {
								"aarch64-darwin" = pkgs.pkgsCross.aarch64-darwin;
								"x86_64-windows" = pkgs.pkgsCross.mingwW64;
								"aarch64-windows" = pkgs.pkgsCross.ucrtAarch64;
								"x86_64-linux" = pkgs.pkgsCross.gnu64;
								"aarch64-linux" = pkgs.pkgsCross.aarch64-multiplatform;
							};
							crossPkgs = crossPkgsFor.${targetSystem} or pkgs;
						in pkgs.stdenv.mkDerivation {
							pname = "validate-${targetSystem}";
							version = "0.1.0";
							src = ./.;

							nativeBuildInputs = with pkgs; [ zig ]
								++ pkgs.lib.optionals (isDarwin && !cross) [
									darwin.cctools
									# macOS SDK for system frameworks
									apple-sdk
								];

							# libjpeg-turbo + openjpeg are required by jpegz (Phase 1
							# wrapper around the system C libs). Forwarded to the
							# jpegz Zig dep via -Dlibjpeg-* / -Dopenjpeg-* options
							# in buildPhase below. Native builds only — cross builds
							# would need cross-compiled libjpeg/openjpeg which is
							# orthogonal and lands separately.
							buildInputs = pkgs.lib.optionals (!cross) [
								pkgs.libjpeg_turbo
								pkgs.libjpeg_turbo.dev
								pkgs.openjpeg
								pkgs.openjpeg.dev
								pkgs.zlib
								pkgs.zlib.dev
							];

							buildPhase = ''
								export HOME=$TMPDIR
								export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
								mkdir -p $ZIG_GLOBAL_CACHE_DIR
								cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
								chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
								${if cross then "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS" else ""}
								${if !cross then ''
								# Forward libjpeg + openjpeg + zlib paths to jpegz/tiffz.
								# openjpeg.h is nested under include/openjpeg-2.5/.
								LIBJPEG_DEV=${pkgs.libjpeg_turbo.dev}
								LIBJPEG_OUT=${pkgs.libjpeg_turbo.out}
								OPENJPEG_DEV=${pkgs.openjpeg.dev}
								OPENJPEG_OUT=${pkgs.openjpeg}
								ZLIB_DEV=${pkgs.zlib.dev}
								ZLIB_OUT=${pkgs.zlib.out}
								JPEGZ_OPTS="-Dlibjpeg-include=$LIBJPEG_DEV/include \
								            -Dlibjpeg-lib=$LIBJPEG_OUT/lib \
								            -Dopenjpeg-include=$OPENJPEG_DEV/include/openjpeg-2.5 \
								            -Dopenjpeg-lib=$OPENJPEG_OUT/lib \
								            -Dzlib-include=$ZLIB_DEV/include \
								            -Dzlib-lib=$ZLIB_OUT/lib"
								'' else ''
								# Forward libjpeg + openjpeg + zlib paths to jpegz/tiffz.
								# openjpeg.h is nested under include/openjpeg-2.5/.
								# Cross: forward only libjpeg + zlib (both cross-build clean).
								# NOT openjpeg: nix pkgsCross openjpeg drags libtiff->libwebp
								# whose img2webp.exe fails to cross-link under mingw. jpegz/tiffz
								# fall back to their libjpeg-only tier; validate's CORE builds its
								# OWN openjpeg (deps/openjpeg, Zig-cross-compiled) for the
								# jpeg2000_validator @cImport, so JP2 validation is unaffected.
								LIBJPEG_DEV=${crossPkgs.libjpeg_turbo.dev}
								LIBJPEG_OUT=${crossPkgs.libjpeg_turbo.out}
								ZLIB_DEV=${crossPkgs.zlib.dev}
								ZLIB_OUT=${crossPkgs.zlib.out}
								JPEGZ_OPTS="-Dlibjpeg-include=$LIBJPEG_DEV/include \
								            -Dlibjpeg-lib=$LIBJPEG_OUT/lib \
								            -Dzlib-include=$ZLIB_DEV/include \
								            -Dzlib-lib=$ZLIB_OUT/lib"
								''}
								zig build $JPEGZ_OPTS -Doptimize=ReleaseFast --release=fast ${if cross then "-Dtarget=${zigTarget}" else ""}
							'';

							installPhase = ''
								mkdir -p $out/bin $out/lib $out/include

								# Static library — build.zig merges all dependencies into one archive
								# (libtool on macOS, zig lib on Windows, zig ar on Linux)
								cp zig-out/lib/libvalidate_core.a $out/lib/ 2>/dev/null || true
								cp zig-out/lib/validate_core.lib $out/lib/ 2>/dev/null || true
								# Header is a source file in ffi/; on macOS the libtool path
								# bypasses installArtifact so zig-out/include/ may be empty.
								if [ -f zig-out/include/validate_core.h ]; then
									cp zig-out/include/validate_core.h $out/include/
								else
									cp ffi/validate_core.h $out/include/
								fi

								# Install CLI binary
								cp zig-out/bin/${binaryName} $out/bin/

								# Append integrity trailer: "VALIDATE_INTEGRITY" (18 bytes) + SHA-256 (32 bytes raw)
								# The binary verifies this at startup to detect corruption/tampering.
								binary="$out/bin/${binaryName}"
								hash_hex=$(sha256sum "$binary" | cut -d' ' -f1)
								printf 'VALIDATE_INTEGRITY' >> "$binary"
								i=0
								while [ $i -lt 64 ]; do
									byte=$(echo "$hash_hex" | cut -c$((i+1))-$((i+2)))
									printf "\\x$byte" >> "$binary"
									i=$((i+2))
								done

								# Bundle license + third-party notices with the binary. The static
								# binary merges ~20 BSD/zlib/MIT libraries whose licenses require their
								# copyright notice in binary redistributions; ship them so the sold
								# artifact carries the required attribution.
								mkdir -p $out/share/licenses/validate
								cp LICENSE $out/share/licenses/validate/ 2>/dev/null || true
								cp THIRD_PARTY_NOTICES.md $out/share/licenses/validate/ 2>/dev/null || true
								cp -r LICENSES $out/share/licenses/validate/ 2>/dev/null || true
							'';

							dontFixup = true;
						};
				in {
					# Default: native build for this system
					default = mkValidate { };
				} // (if buildSystem == "x86_64-linux" then {
					# Cross-compiled builds from Linux (for CI artifacts)
					# Only cross-compile for targets without native Garnix builders
					# Linux x86_64/aarch64 are built natively by Garnix on those platforms
					windows-x86_64 = mkValidate { targetSystem = "x86_64-windows"; cross = true; };
					# aarch64-linux CROSS output (Garnix retiring → Thelio x86_64 is THE build
					# machine; aarch64-linux must cross-compile here, no native ARM builder).
					linux-aarch64 = mkValidate { targetSystem = "aarch64-linux"; cross = true; };
					windows-aarch64 = mkValidate { targetSystem = "aarch64-windows"; cross = true; };
					# NOTE: macos-aarch64 is intentionally NOT cross-built from Linux.
					# Garnix builds it NATIVELY (the green `macos-aarch64` check), which is
					# the supported path; cross-compiling a Darwin target from Linux drags
					# in Apple-SDK deps that nixpkgs marks badPlatforms. Per the policy
					# above (cross only for targets without native builders) it's redundant.
					# See validate #32.
				} else if buildSystem == "aarch64-darwin" then {
					# Cross-compile from macOS (Zig cross-compiles natively from any host)
					linux-x86_64 = mkValidate { targetSystem = "x86_64-linux"; cross = true; };
					windows-x86_64 = mkValidate { targetSystem = "x86_64-windows"; cross = true; };
					# windows-aarch64 omitted — blocked by upstream nixpkgs aarch64-mingw
					# compiler-rt bug (see the note in the x86_64-linux branch above + #64).
				} else { }));

			# Checks for `nix flake check` / Garnix
			checks = forBuildSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					isDarwin = pkgs.stdenv.isDarwin;

					zigDeps = pkgs.stdenv.mkDerivation {
						pname = "validate-zig-deps";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = with pkgs; [ zig git cacert ];

						outputHashMode = "recursive";
						outputHashAlgo = "sha256";
						outputHash = zigDepsHash;

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$out
							# Zig 0.16 needs these subdirs to pre-exist or its
							# package fetcher fails on .zip transitive deps with
							# the misleading 'failed to create temporary zip
							# file: FileNotFound' (the parent dir is missing,
							# not the file). Diagnosed 2026-05-21.
							mkdir -p $out/tmp $out/p $out/o
							export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
							zig build --fetch=all
						'';

						dontInstall = true;
						dontFixup = true;
					};
				in {
					build = self.packages.${system}.default;

					test = pkgs.stdenv.mkDerivation {
						pname = "validate-test";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = with pkgs; [ zig ffmpeg coreutils zip ]
							++ pkgs.lib.optionals isDarwin [
								darwin.cctools
								# macOS SDK for system frameworks
								apple-sdk
							];

						# Same system libs that the main build uses — jpegz needs libjpeg/openjpeg,
						# tiffz needs zlib. Test derivation is a fresh nix sandbox so it can't
						# rely on host PATH or the dev shell's env exports.
						buildInputs = [
							pkgs.libjpeg_turbo
							pkgs.libjpeg_turbo.dev
							pkgs.openjpeg
							pkgs.openjpeg.dev
							pkgs.zlib
							pkgs.zlib.dev
						];

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							# Force non-interactive: Zig's test runner emits terminal escape
							# sequences when stderr is a TTY, which can hang in CI.
							export TERM=dumb
							LIBJPEG_DEV=${pkgs.libjpeg_turbo.dev}
							LIBJPEG_OUT=${pkgs.libjpeg_turbo.out}
							OPENJPEG_DEV=${pkgs.openjpeg.dev}
							OPENJPEG_OUT=${pkgs.openjpeg}
							ZLIB_DEV=${pkgs.zlib.dev}
							ZLIB_OUT=${pkgs.zlib.out}
							JPEGZ_OPTS="-Dlibjpeg-include=$LIBJPEG_DEV/include \
							            -Dlibjpeg-lib=$LIBJPEG_OUT/lib \
							            -Dopenjpeg-include=$OPENJPEG_DEV/include/openjpeg-2.5 \
							            -Dopenjpeg-lib=$OPENJPEG_OUT/lib \
							            -Dzlib-include=$ZLIB_DEV/include \
							            -Dzlib-lib=$ZLIB_OUT/lib"
							# Test-discovery floor (CI-honesty MFIC): zig build test is silent on
							# success, so guard the discovery invariant at the SOURCE — fail if
							# modules drop out of mod.zig's test block (the rot that hid 28 modules)
							# or tests get deleted. Deterministic grep; bites on regression.
							imp=$(sed -n '/^test {/,/^}/p' src/core/mod.zig | grep -c '_ = @import')
							decl=$(grep -rho '^test "' src | wc -l | tr -d ' ')
							echo "test-discovery floor: $imp module imports, $decl test declarations"
							if [ "$imp" -lt 140 ]; then echo "FAIL: test-block module imports ($imp) < 140 — modules dropped from discovery"; exit 1; fi
							if [ "$decl" -lt 2000 ]; then echo "FAIL: test declarations ($decl) < 2000 — tests deleted/disabled"; exit 1; fi
							timeout 1800 zig build $JPEGZ_OPTS test 2>&1 || {
							  echo "Tests timed out or failed after 30 minutes"
							  exit 1
							}
						'';

						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
					};

					# CI-honesty: run the fixture-free CLI tests + the master_report_drift
					# corruption-drift oracle against the PACKAGED binary in CI. These
					# previously lived ONLY in ./test and never ran in Garnix (the false-green).
					# Excludes fixture-dependent tests (ground_truth_examples is absent in the
					# sandbox) and ones that hardcode `nix develop` (unavailable in-sandbox).
					cli = pkgs.runCommandLocal "validate-cli-mfic" {
						nativeBuildInputs = [ pkgs.bash pkgs.luajit pkgs.coreutils ];
					} ''
						export VALIDATE_BIN=${self.packages.${system}.default}/bin/validate
						export TMPDIR=$(mktemp -d)
						root=${./.}
						fail=0
						for t in master_report_drift utf8_required_formats_reject symlink_loop_termination no_tmp_debug_log_in_release; do
							echo "=== CLI check: $t ==="
							if ! bash "$root/tests/cli/$t"; then echo "FAIL: $t"; fail=1; fi
						done
						[ "$fail" -eq 0 ] || exit 1
						touch $out
					'';

					# Fuzz regression replay (the ship gate's CI arm): build the Tier-1
					# harnesses (ReleaseSafe, bounds ON) and replay every committed
					# minimized crasher through fuzz-dispatch. Each must terminate
					# normally — a segv/abort/bus/timeout means a fixed bug regressed.
					# Self-contained: crashers live in tests/fuzz/corpus/ (no fixtures).
					fuzz = pkgs.stdenv.mkDerivation {
						pname = "validate-fuzz-replay";
						version = "0.1.0";
						src = ./.;
						nativeBuildInputs = with pkgs; [ zig coreutils ]
							++ pkgs.lib.optionals isDarwin [ darwin.cctools apple-sdk ];
						buildInputs = [
							pkgs.libjpeg_turbo pkgs.libjpeg_turbo.dev
							pkgs.openjpeg pkgs.openjpeg.dev
							pkgs.zlib pkgs.zlib.dev
						];
						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							export TERM=dumb MUTE_DEBUG_STATUS=1
							LIBJPEG_DEV=${pkgs.libjpeg_turbo.dev}
							LIBJPEG_OUT=${pkgs.libjpeg_turbo.out}
							OPENJPEG_DEV=${pkgs.openjpeg.dev}
							OPENJPEG_OUT=${pkgs.openjpeg}
							ZLIB_DEV=${pkgs.zlib.dev}
							ZLIB_OUT=${pkgs.zlib.out}
							JPEGZ_OPTS="-Dlibjpeg-include=$LIBJPEG_DEV/include \
							            -Dlibjpeg-lib=$LIBJPEG_OUT/lib \
							            -Dopenjpeg-include=$OPENJPEG_DEV/include/openjpeg-2.5 \
							            -Dopenjpeg-lib=$OPENJPEG_OUT/lib \
							            -Dzlib-include=$ZLIB_DEV/include \
							            -Dzlib-lib=$ZLIB_OUT/lib"
							timeout 1800 zig build $JPEGZ_OPTS fuzz -Doptimize=ReleaseSafe || {
							  echo "fuzz harness build failed"; exit 1; }
							replayed=0; fail=0
							for f in $(find tests/fuzz/corpus -type f ! -name '*.md'); do
								replayed=$((replayed + 1))
								timeout 60 zig-out/bin/fuzz-dispatch < "$f" >/dev/null 2>&1
								rc=$?
								case "$rc" in
									134|137|138|139|124)
										echo "REGRESSED: $f (rc=$rc)"; fail=1 ;;
								esac
							done
							echo "fuzz replay: $replayed committed crasher(s)"
							[ "$fail" -eq 0 ] || { echo "fuzz replay FAILED — a fixed crash regressed"; exit 1; }
						'';
						installPhase = ''mkdir -p $out; echo "fuzz replay clean" > $out/result'';
					};
				});

			devShells = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					isDarwin = pkgs.stdenv.isDarwin;
					pcre2Static = pkgs.pcre2.overrideAttrs (old: {
						dontDisableStatic = true;
					});
					libjpegStatic = pkgs.libjpeg_turbo.overrideAttrs (old: {
						dontDisableStatic = true;
						cmakeFlags = (old.cmakeFlags or []) ++ [
							"-DENABLE_STATIC=TRUE"
							"-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
						];
					});
					# libopenmpt for tracker format validation (MOD, XM, IT, S3M, etc.)
					libopenmptStatic = pkgs.libopenmpt.overrideAttrs (old: {
						dontDisableStatic = true;
						configureFlags = (old.configureFlags or []) ++ [
							"--enable-static"
						];
					});
					isLinux = pkgs.stdenv.isLinux;
					isX86_64Linux = system == "x86_64-linux";
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							zig
							bash
							coreutils
							git
							ripgrep
							brotli
							luajit
							tmux
							qpdf
							pcre2Static
							pcre2Static.dev
							libjpegStatic
							libjpegStatic.dev
							libopenmptStatic
							libopenmptStatic.dev
							# openjpeg for jpegz Phase 1 wrapper (JPEG 2000 decode).
							pkgs.openjpeg
							pkgs.openjpeg.dev
							sqlite
							zlib
							ffmpeg  # For testing ffmpeg fallback validation paths
							zip  # For the large-zip CRC gate (tests/cli/zip_large_entry_crc)
						] ++ pkgs.lib.optionals isDarwin [
							xcodegen
							# macOS SDK for system frameworks
							# The apple-sdk provides all frameworks needed for building
							apple-sdk
						] ++ pkgs.lib.optionals isX86_64Linux [ wineWowPackages.stable ];  # For Windows cross-testing
						shellHook = ''
							unset LD
							unset SDKROOT
							export PCRE2_STATIC_ROOT="${pcre2Static.out}"
							export PCRE2_INCLUDE_ROOT="${pcre2Static.dev}"
							export LIBJPEG_STATIC_ROOT="${libjpegStatic.out}"
							export LIBJPEG_INCLUDE_ROOT="${libjpegStatic.dev}"
							# jpegz consumes these via build.zig's -Dopenjpeg-include /
							# -Dopenjpeg-lib options. openjpeg.h is nested under
							# include/openjpeg-2.5/ in nixpkgs.
							export OPENJPEG_INC="${pkgs.openjpeg.dev}/include/openjpeg-2.5"
							export OPENJPEG_LIB="${pkgs.openjpeg}/lib"
							export LIBOPENMPT_STATIC_ROOT="${libopenmptStatic.out}"
							export LIBOPENMPT_INCLUDE_ROOT="${libopenmptStatic.dev}"
							if [ -d /Applications/Xcode.app/Contents/Developer ]; then
								export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
							fi
						'';
					};
				});
		};
}
