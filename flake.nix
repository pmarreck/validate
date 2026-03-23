{
	description = "Validate - Deterministic file format validation";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			# All systems for devShells (local development)
			allSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs allSystems;

			# Build systems (where we run builds - Linux for CI, Darwin for local)
			buildSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
			forBuildSystems = nixpkgs.lib.genAttrs buildSystems;

			# Zig target triples for cross-compilation
			# Using musl for Linux cross-compilation (better static linking support)
			zigTargets = {
				"x86_64-linux" = "x86_64-linux-musl";
				"aarch64-linux" = "aarch64-linux-musl";
				"x86_64-windows" = "x86_64-windows-gnu";
				"x86_64-darwin" = "x86_64-macos";
				"aarch64-darwin" = "aarch64-macos";
			};

			# Pre-fetched Zig dependencies (fixed-output derivation)
			# This hash must be updated when build.zig.zon changes
			zigDepsHash = "sha256-EzaT/Q7Ik+dA3i8R3arY5mc08OSq7eHuFO9pS/fILfs=";
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

							buildPhase = ''
								export HOME=$TMPDIR
								export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
								mkdir -p $ZIG_GLOBAL_CACHE_DIR
								cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
								chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
								${if cross then "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS" else ""}
								zig build -Doptimize=ReleaseFast --release=fast ${if cross then "-Dtarget=${zigTarget}" else ""}
							'';

							installPhase = ''
								mkdir -p $out/bin
								cp zig-out/bin/${binaryName} $out/bin/
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
					macos-x86_64 = mkValidate { targetSystem = "x86_64-darwin"; cross = true; };
					macos-aarch64 = mkValidate { targetSystem = "aarch64-darwin"; cross = true; };
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

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							mkdir -p $ZIG_GLOBAL_CACHE_DIR
							cp -r ${zigDeps}/* $ZIG_GLOBAL_CACHE_DIR/
							chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
							# Timeout after 10 minutes to prevent CI hangs
							timeout 600 zig build test || {
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
