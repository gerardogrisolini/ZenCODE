#!/bin/bash
# rpios-test.sh — Run ZenCODE build and tests in the Raspberry Pi OS
# container machine (Debian 13 trixie, arm64) before publishing a release.
#
# Prerequisites (one-time setup):
#   container build -t local/rpios-trixie-swift:latest \
#       -f Scripts/rpios-trixie/Containerfile Scripts/rpios-trixie/
#   container machine create local/rpios-trixie-swift:latest \
#       --name zencode-rpios --cpus 4 --memory 8G --set-default
#
# Usage:
#   Scripts/rpios-test.sh            # build + test
#   Scripts/rpios-test.sh build      # build only
#   Scripts/rpios-test.sh test       # test only
#   Scripts/rpios-test.sh shell      # interactive shell

set -euo pipefail

MACHINE="zencode-rpios"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_PATH="/tmp/zencode-build"

mode="${1:-all}"

run_in_machine() {
    container machine run -n "$MACHINE" -w "$REPO_DIR" -- "$@"
}

case "$mode" in
    build)
        echo "▶ Building ZenCODE on Raspberry Pi OS (arm64)…"
        run_in_machine swift build --build-path "$BUILD_PATH"
        ;;
    test)
        echo "▶ Testing ZenCODE on Raspberry Pi OS (arm64)…"
        run_in_machine swift test --no-parallel --build-path "$BUILD_PATH"
        ;;
    shell)
        echo "▶ Opening shell on $MACHINE…"
        container machine run -n "$MACHINE" -w "$REPO_DIR"
        ;;
    all)
        echo "▶ Building + testing ZenCODE on Raspberry Pi OS (arm64)…"
        run_in_machine swift build --build-path "$BUILD_PATH"
        echo ""
        echo "▶ Running tests…"
        run_in_machine swift test --no-parallel --build-path "$BUILD_PATH"
        ;;
    *)
        echo "Usage: $0 [build|test|shell|all]"
        exit 1
        ;;
esac

echo ""
echo "✓ Done."
