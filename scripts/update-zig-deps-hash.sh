#!/usr/bin/env bash
#
# Update the Zig dependencies hash in flake.nix
#
# This script fetches all Zig dependencies, computes their hash,
# and updates flake.nix if the hash has changed.
#
# Run this after modifying build.zig.zon (adding/updating dependencies).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLAKE_NIX="$PROJECT_ROOT/flake.nix"

# Colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

echo -e "${BLUE}=== Updating Zig dependencies hash ===${NC}"

# Create temp directory for fetching deps
DEPS_DIR=$(mktemp -d)
trap "rm -rf $DEPS_DIR" EXIT

echo "Fetching Zig dependencies..."
cd "$PROJECT_ROOT"

# Fetch all dependencies
HOME="$DEPS_DIR" ZIG_GLOBAL_CACHE_DIR="$DEPS_DIR/zig-cache" zig build --fetch=all 2>&1 || true

# Compute hash
echo "Computing hash..."
NEW_HASH=$(nix hash path "$DEPS_DIR/zig-cache")

# Get current hash from flake.nix
CURRENT_HASH=$(grep 'zigDepsHash = "' "$FLAKE_NIX" | sed 's/.*zigDepsHash = "\([^"]*\)".*/\1/')

if [[ "$NEW_HASH" == "$CURRENT_HASH" ]]; then
    echo -e "${GREEN}Hash unchanged: $NEW_HASH${NC}"
    exit 0
fi

echo -e "${YELLOW}Hash changed:${NC}"
echo "  Old: $CURRENT_HASH"
echo "  New: $NEW_HASH"

# Update flake.nix
sed -i.bak "s|zigDepsHash = \"$CURRENT_HASH\"|zigDepsHash = \"$NEW_HASH\"|" "$FLAKE_NIX"
rm -f "$FLAKE_NIX.bak"

echo -e "${GREEN}Updated flake.nix with new hash${NC}"

# Verify the flake still evaluates
echo "Verifying flake..."
if nix flake check --no-build 2>&1 | head -5; then
    echo -e "${GREEN}Flake verification passed${NC}"
else
    echo -e "${YELLOW}Warning: flake check had issues (may be expected for non-native systems)${NC}"
fi
