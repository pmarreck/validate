#!/bin/bash
# Test the musl build in an Alpine Linux container
# This reproduces the CI environment locally for debugging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is required but not installed."
    exit 1
fi

echo "=== Building for x86_64-linux-musl ==="
cd "$PROJECT_ROOT"

# Build the musl binary locally first (cross-compile)
nix develop --command zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast

# Check that the binary was created
if [[ ! -f "zig-out/bin/validate" ]]; then
    echo "Error: Binary not found at zig-out/bin/validate"
    exit 1
fi

echo "=== Testing in Alpine Linux container ==="

# Run the binary in Alpine (musl-based) container
docker run --rm -v "$PROJECT_ROOT:/work:ro" -w /work alpine:latest sh -c '
    echo "Alpine Linux version:"
    cat /etc/alpine-release
    echo ""
    echo "Testing validate binary..."

    # Check binary type
    file zig-out/bin/validate || echo "(file command not available)"

    # Try to run with --version
    echo ""
    echo "Running: ./zig-out/bin/validate --version"
    ./zig-out/bin/validate --version || echo "Exit code: $?"

    # Try to run with --help
    echo ""
    echo "Running: ./zig-out/bin/validate --help"
    ./zig-out/bin/validate --help | head -20 || echo "Exit code: $?"

    # Test HEIC validation if sample exists
    if [[ -f "ground_truth_examples/heic/sample.heic" ]]; then
        echo ""
        echo "Testing HEIC deep validation..."
        echo "Running: ./zig-out/bin/validate -d ground_truth_examples/heic/sample.heic"
        ./zig-out/bin/validate -d ground_truth_examples/heic/sample.heic || echo "Exit code: $?"
    fi
'

echo ""
echo "=== Test complete ==="
