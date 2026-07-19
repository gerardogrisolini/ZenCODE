#!/usr/bin/env bash

set -euo pipefail

# ZenCODE Linux installer
#
# Builds ZenCODE and its bundled feature executables from source and installs
# them. Intended for native Linux and for Windows via WSL (Ubuntu). When
# launched outside a repository checkout, for example with curl | bash, the
# installer uses a temporary source checkout and removes it before exiting.
#
# Environment overrides:
#   INSTALL_DIR    Directory for the ZenCODE binary (default: /usr/local/bin)
#   FEATURES_DIR   Directory for feature executables
#                  (default: $INSTALL_DIR/zen-features)
#   BUILD_CONFIG   SwiftPM configuration: release or debug (default: release)
#   ZENCODE_INSTALLER_REF
#                  Git ref used by the URL installer (default: main)
#
# Flags:
#   --debug          Build with the debug configuration
#   --prefix DIR     Install the binary into DIR (sets INSTALL_DIR)
#   -h, --help       Show this help and exit

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
REPO_URL="${ZENCODE_INSTALLER_REPO:-https://github.com/gerardogrisolini/ZenCODE.git}"
REPO_REF="${ZENCODE_INSTALLER_REF:-main}"
INSTALLER_TMPDIR="${ZENCODE_INSTALLER_TMPDIR:-${TMPDIR:-/tmp}}"
BOOTSTRAP_TMP_ROOT=""
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
ZenCODE Linux installer

Builds ZenCODE and its bundled feature executables from source and installs
them. Intended for native Linux and for Windows via WSL (Ubuntu). When
launched outside a repository checkout, for example with curl | bash, the
installer uses a temporary source checkout and removes it before exiting.

Environment overrides:
  INSTALL_DIR    Directory for the ZenCODE binary (default: /usr/local/bin)
  FEATURES_DIR   Directory for feature executables
                 (default: $INSTALL_DIR/zen-features)
  BUILD_CONFIG   SwiftPM configuration: release or debug (default: release)
  ZENCODE_INSTALLER_REF
                 Git ref used by the URL installer (default: main)
Flags:
  --debug          Build with the debug configuration
  --prefix DIR     Install the binary into DIR (sets INSTALL_DIR)
  -h, --help       Show this help and exit
EOF
}

resolve_package_dir() {
    local script_source="${BASH_SOURCE[0]:-$0}"
    local script_dir=""
    local package_dir=""

    if [ -z "$script_source" ] || [ ! -f "$script_source" ]; then
        return 1
    fi

    script_dir="$(cd "$(dirname "$script_source")" && pwd -P)"
    package_dir="$(cd "${script_dir}/.." && pwd -P)"

    if [ ! -f "${package_dir}/Package.swift" ]; then
        return 1
    fi

    printf '%s\n' "$package_dir"
}

bootstrap_checkout() {
    local checkout=""
    local status=0

    if ! command -v git &>/dev/null; then
        echo "Error: Git is required to install ZenCODE from the URL installer." >&2
        exit 1
    fi

    BOOTSTRAP_TMP_ROOT="$(mktemp -d "${INSTALLER_TMPDIR%/}/zencode-installer.XXXXXX")"
    checkout="${BOOTSTRAP_TMP_ROOT}/ZenCODE"
    trap 'rm -rf "$BOOTSTRAP_TMP_ROOT"' EXIT

    echo "Downloading ZenCODE installer checkout..."
    git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$checkout"
    echo ""

    set +e
    "${checkout}/Scripts/install-linux.sh" "${ORIGINAL_ARGS[@]}"
    status=$?
    set -e
    exit "$status"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debug)
            BUILD_CONFIG="debug"
            shift
            ;;
        --prefix)
            if [ "$#" -lt 2 ]; then
                echo "Error: --prefix requires a directory argument." >&2
                exit 1
            fi
            INSTALL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1'." >&2
            usage >&2
            exit 1
            ;;
    esac
done

FEATURES_DIR="${FEATURES_DIR:-${INSTALL_DIR}/zen-features}"

echo "ZenCODE Linux installer"
echo ""

# Sanity checks --------------------------------------------------------------

if [ "$(uname -s)" != "Linux" ]; then
    echo "Error: this script targets Linux (including Windows via WSL)." >&2
    echo "On macOS use Scripts/install.sh instead." >&2
    exit 1
fi

if ! command -v swift &>/dev/null; then
    echo "Error: the Swift toolchain is required but 'swift' was not found." >&2
    echo "Install Swift for Linux from https://www.swift.org/install/linux/" >&2
    exit 1
fi

echo "Swift toolchain:"
swift --version
echo ""

# Resolve the package root (the directory that contains Package.swift) -------

PACKAGE_DIR="$(resolve_package_dir || true)"
if [ -z "$PACKAGE_DIR" ]; then
    bootstrap_checkout
fi
SCRIPT_DIR="${PACKAGE_DIR}/Scripts"
source "${SCRIPT_DIR}/feature-catalog.sh"

cd "$PACKAGE_DIR"

# Build ----------------------------------------------------------------------

zencode_select_feature_products linux

echo "Build configuration:"
echo "  config: ${BUILD_CONFIG}"
echo ""

echo "Building ZenCODE (${BUILD_CONFIG})..."
swift build -c "$BUILD_CONFIG" --product zen

for product in "${FEATURE_PRODUCTS[@]}"; do
    echo "Building ${product} (${BUILD_CONFIG})..."
    swift build -c "$BUILD_CONFIG" --product "$product"
done

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"
if [ ! -x "${BIN_PATH}/zen" ]; then
    echo "Error: build did not produce ${BIN_PATH}/zen." >&2
    exit 1
fi

echo ""

# Install --------------------------------------------------------------------

# Use sudo only when the target directories are not writable by this user.
SUDO=""
if ! mkdir -p "$INSTALL_DIR" "$FEATURES_DIR" 2>/dev/null; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        echo "Error: cannot create ${INSTALL_DIR} or ${FEATURES_DIR}, and sudo was not found." >&2
        exit 1
    fi
fi
if [ -z "$SUDO" ] && { [ ! -w "$INSTALL_DIR" ] || [ ! -w "$FEATURES_DIR" ]; }; then
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
    else
        echo "Error: ${INSTALL_DIR} or ${FEATURES_DIR} is not writable, and sudo was not found." >&2
        exit 1
    fi
fi

echo "Installing to ${INSTALL_DIR}..."
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO mkdir -p "$FEATURES_DIR"

$SUDO cp "${BIN_PATH}/zen" "${INSTALL_DIR}/zen"
$SUDO chmod +x "${INSTALL_DIR}/zen"

for product in "${FEATURE_PRODUCTS[@]}"; do
    if [ -x "${BIN_PATH}/${product}" ]; then
        $SUDO cp "${BIN_PATH}/${product}" "${FEATURES_DIR}/${product}"
        $SUDO chmod +x "${FEATURES_DIR}/${product}"
    else
        echo "Warning: ${product} was not built, skipping." >&2
    fi
done

echo ""
echo "✓ ZenCODE installed successfully!"
echo ""
echo "  zen        → ${INSTALL_DIR}/zen"
echo "  features     → ${FEATURES_DIR}/"
echo ""
echo "Make sure ${INSTALL_DIR} is in your PATH."
echo ""
echo "Configure a remote provider with: zen --setup"
