#!/bin/bash
# rpios-test.sh — Run ZenCODE build and tests in the Raspberry Pi OS
# container machine (Debian 13 trixie, arm64) before publishing a release.
#
# Prerequisites (one-time setup):
#   The image recipe targets Swift 6.4. Existing images/machines are not upgraded
#   by editing the recipe; check `container machine run -n zencode-rpios -- swift --version`
#   and explicitly rebuild/recreate or upgrade an older machine before validation.
#
#   container build -t local/rpios-trixie-swift:latest \
#       -f Scripts/rpios-trixie/Containerfile Scripts/rpios-trixie/
#   container machine create local/rpios-trixie-swift:latest \
#       --name zencode-rpios --cpus 4 --memory 8G --set-default
#
# Use it to reproduce Linux-only CI failures instead of inferring them from the
# workflow status: a green macOS run is not evidence that the Linux gate passes.
#
# Targeted runs: call the machine directly and always pass the Linux build path,
# because the repository `.build` directory is shared with macOS and holds
# incompatible artifacts:
#   container machine run -n zencode-rpios -w "$PWD" -- \
#       swift test --build-path /tmp/zencode-build [--filter <suite-or-test>]
# Quoting is not preserved through `container machine run -- bash -c`: put
# multi-step or looping shell in a script file and run that file instead.
# Concurrency and lifecycle races may not reproduce on an idle machine: when a
# test fails only in CI, rerun it under CPU contention (background busy loops
# oversubscribing the machine's cores) before concluding it is unrelated.
# When finished, stop both the machine and the BuildKit builder, a separate
# container that keeps running after the machine stops:
#   container machine stop zencode-rpios
#   container builder stop
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
