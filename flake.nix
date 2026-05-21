{
	description = "Validate - Deterministic file format validation";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
			zigDepsHash = "sha256-P6CyEmfhm0LjW7I+cbmbDWjQfOo3vqkKUnf8kQkZYXI=";
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
								# Forward libjpeg + openjpeg paths to the jpegz dep.
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
								JPEGZ_OPTS=""
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
					windows-aarch64 = mkValidate { targetSystem = "aarch64-windows"; cross = true; };
					macos-aarch64 = mkValidate { targetSystem = "aarch64-darwin"; cross = true; };
				} else if buildSystem == "aarch64-darwin" then {
					# Cross-compile from macOS (Zig cross-compiles natively from any host)
					linux-x86_64 = mkValidate { targetSystem = "x86_64-linux"; cross = true; };
					windows-x86_64 = mkValidate { targetSystem = "x86_64-windows"; cross = true; };
					windows-aarch64 = mkValidate { targetSystem = "aarch64-windows"; cross = true; };
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

						nativeBuildInputs = with pkgs; [ zig ffmpeg coreutils ]
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
							timeout 600 zig build $JPEGZ_OPTS test 2>&1 || {
							  echo "Tests timed out or failed after 10 minutes"
							  exit 1
							}
						'';

						installPhase = ''
							mkdir -p $out
							echo "tests passed" > $out/result
						'';
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
							git
							ripgrep
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
