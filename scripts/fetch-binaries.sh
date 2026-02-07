#!/usr/bin/env bash
# Fetch pre-built binaries from Garnix cache into result/<target>/ symlinks.
# The result/ directory is gitignored.
# Run after each push to get the latest CI-built binaries.

set -euo pipefail
cd "$(dirname "$0")/.."

FLAKE="${1:-github:pmarreck/validate}"

targets=(
  linux-x86_64
  linux-aarch64
  macos-x86_64
  macos-aarch64
  windows-x86_64
)

mkdir -p result

for target in "${targets[@]}"; do
  echo "Fetching $target..."
  store_path=$(nix build "${FLAKE}#packages.x86_64-linux.${target}" --no-link --print-out-paths 2>&1 | tail -1)
  # Atomically update symlink
  ln -sfn "$store_path" "result/${target}"
  bin=$(find "result/${target}/bin" -maxdepth 1 -type f 2>/dev/null | head -1)
  if [ -n "$bin" ]; then
    size=$(du -h "$bin" | cut -f1)
    echo "  -> result/${target}/bin/$(basename "$bin") ($size)"
  fi
done

echo ""
echo "Done. Binaries:"
for target in "${targets[@]}"; do
  ls result/${target}/bin/* 2>/dev/null | sed 's/^/  /'
done
