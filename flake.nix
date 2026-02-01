{
	description = "Validate - Deterministic file format validation";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
	};

	outputs = { self, nixpkgs }:
		let
			systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
			forAllSystems = nixpkgs.lib.genAttrs systems;
		in {
			# Packages for Garnix/Nix builds
			packages = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
					isDarwin = pkgs.stdenv.isDarwin;
				in {
					default = pkgs.stdenv.mkDerivation {
						pname = "validate";
						version = "0.1.0";
						src = ./.;

						# libtool needed on Darwin for bundling static libraries
						nativeBuildInputs = with pkgs; [ zig ]
							++ pkgs.lib.optionals isDarwin [ darwin.cctools ];

						# Zig handles all C deps internally via build.zig
						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							zig build -Doptimize=ReleaseFast --release=fast
						'';

						installPhase = ''
							mkdir -p $out/bin
							cp zig-out/bin/validate $out/bin/
						'';

						# Skip fixup that breaks static binaries
						dontFixup = true;
					};
				});

			# Checks for `nix flake check` / Garnix
			checks = forAllSystems (system:
				let
					pkgs = import nixpkgs { inherit system; };
				in {
					build = self.packages.${system}.default;

					test = pkgs.stdenv.mkDerivation {
						pname = "validate-test";
						version = "0.1.0";
						src = ./.;

						nativeBuildInputs = with pkgs; [ zig ffmpeg ];

						buildPhase = ''
							export HOME=$TMPDIR
							export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
							zig build test
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
				in {
					default = pkgs.mkShell {
						packages = with pkgs; [
							xcodegen
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
						];
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
