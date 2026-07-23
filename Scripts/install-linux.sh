#!/usr/bin/env bash

set -euo pipefail

# ZenCODE Linux installer
#
# Builds ZenCODE and its bundled feature executables from source and installs
# them. Intended for native Linux and for Windows via WSL (Ubuntu). When
# launched outside a repository checkout, for example with curl | bash, the
# installer uses a temporary source checkout and removes it before exiting. If
# Swift is unavailable, it bootstraps the latest stable toolchain with Swiftly
# before resolving the checkout or starting a build.
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
#   --ref REF        Git ref (tag/branch/commit) the URL installer checks out
#                    (overrides ZENCODE_INSTALLER_REF). For a reproducible
#                    install pass an immutable ref such as a tag vX.Y.Z or a
#                    full commit SHA. The default 'main' is a moving ref and
#                    produces a development build.
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
Swift:
  Reuses Swift already on PATH. If absent, installs the latest stable Swift
  toolchain with Swiftly using the official Linux installation flow.
Flags:
  --debug          Build with the debug configuration
  --prefix DIR     Install the binary into DIR (sets INSTALL_DIR)
  --ref REF        Git ref (tag/branch/commit) the URL installer checks out
                   (overrides ZENCODE_INSTALLER_REF). For a reproducible
                   install pass an immutable ref such as a tag vX.Y.Z or a
                   full commit SHA. The default 'main' is a moving ref and
                   produces a development build.
  -h, --help       Show this help and exit
EOF
}

# Warn when the URL installer is pinned to a moving ref. An immutable ref
# (tag vX.Y.Z or a full commit SHA) is required for a reproducible install;
# 'main' (or any branch) advances over time and yields a development build.
warn_if_mobile_ref() {
    local ref="$1"
    if printf '%s' "$ref" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Installing immutable release ref: ${ref}"
    elif printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
        echo "Installing immutable commit ref: ${ref}"
    else
        echo "Warning: ref '${ref}' is a moving ref; this produces a development build." >&2
        echo "         For a reproducible install pass --ref vX.Y.Z or a full commit SHA." >&2
    fi
}

swiftly_home_dir() {
    if [ -n "${SWIFTLY_HOME_DIR:-}" ]; then
        printf '%s\n' "$SWIFTLY_HOME_DIR"
    elif [ -n "${XDG_DATA_HOME:-}" ]; then
        printf '%s/swiftly\n' "${XDG_DATA_HOME%/}"
    elif [ -n "${HOME:-}" ]; then
        printf '%s/.local/share/swiftly\n' "${HOME%/}"
    else
        echo "Error: HOME, XDG_DATA_HOME, or SWIFTLY_HOME_DIR must be set to install Swift." >&2
        return 1
    fi
}

bootstrap_swiftly() (
    SWIFTLY_TMP_ROOT=""
    local swiftly_archive=""
    local swiftly_binary=""
    local architecture=""

    if ! command -v curl &>/dev/null; then
        echo "Error: curl is required to download Swiftly when Swift is not installed." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi
    if ! command -v tar &>/dev/null; then
        echo "Error: tar is required to extract Swiftly when Swift is not installed." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi
    if ! command -v mktemp &>/dev/null; then
        echo "Error: mktemp is required to create temporary files for the Swift installation." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi

    if ! SWIFTLY_TMP_ROOT="$(mktemp -d "${INSTALLER_TMPDIR%/}/zencode-swiftly.XXXXXX")"; then
        echo "Error: could not create a temporary directory for the Swift installation under ${INSTALLER_TMPDIR}." >&2
        echo "Set TMPDIR or ZENCODE_INSTALLER_TMPDIR to a writable directory and retry." >&2
        exit 1
    fi

    # This variable outlives function-local scope; the trap itself is scoped to
    # the subshell, so it cannot replace bootstrap_checkout's trap.
    trap 'rm -rf "$SWIFTLY_TMP_ROOT" || true' EXIT

    if ! architecture="$(uname -m)" || [ -z "$architecture" ]; then
        echo "Error: could not determine the system architecture for the Swiftly download." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi

    swiftly_archive="${SWIFTLY_TMP_ROOT}/swiftly-${architecture}.tar.gz"
    swiftly_binary="${SWIFTLY_TMP_ROOT}/swiftly"

    echo "Swift was not found; installing the latest stable Swift toolchain with Swiftly..."
    if ! curl --fail --location --silent --show-error \
        --output "$swiftly_archive" \
        "https://download.swift.org/swiftly/linux/swiftly-${architecture}.tar.gz"; then
        echo "Error: failed to download Swiftly for architecture ${architecture} from download.swift.org." >&2
        echo "Check your network connection; this architecture may not be supported. See https://www.swift.org/install/linux/." >&2
        exit 1
    fi
    if ! tar -xzf "$swiftly_archive" -C "$SWIFTLY_TMP_ROOT"; then
        echo "Error: failed to extract the Swiftly archive." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi
    if [ ! -x "$swiftly_binary" ]; then
        echo "Error: the Swiftly archive did not contain an executable named 'swiftly'." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        exit 1
    fi

    # Avoid prompting or consuming the rest of a curl | bash input stream.
    if ! "$swiftly_binary" init --quiet-shell-followup --assume-yes < /dev/null; then
        echo "Error: Swiftly could not initialize the Swift toolchain." >&2
        echo "See https://www.swift.org/install/linux/ for platform requirements and manual instructions." >&2
        exit 1
    fi
)

ensure_swift_toolchain() {
    local swiftly_home=""
    local swiftly_env=""

    if command -v swift &>/dev/null; then
        return 0
    fi

    if ! bootstrap_swiftly; then
        return 1
    fi

    if ! swiftly_home="$(swiftly_home_dir)"; then
        return 1
    fi
    swiftly_env="${swiftly_home}/env.sh"
    if [ ! -f "$swiftly_env" ]; then
        echo "Error: Swiftly did not create ${swiftly_env}." >&2
        echo "See https://www.swift.org/install/linux/ for manual installation instructions." >&2
        return 1
    fi

    # shellcheck disable=SC1090
    if ! source "$swiftly_env"; then
        echo "Error: could not load the Swiftly environment from ${swiftly_env}." >&2
        return 1
    fi
    hash -r

    if ! command -v swiftly &>/dev/null; then
        echo "Error: Swiftly was initialized but is not available after loading ${swiftly_env}." >&2
        return 1
    fi
    if ! command -v swift &>/dev/null; then
        echo "Swiftly is configured but no Swift toolchain is active; installing latest..."
        if ! swiftly install latest --use --assume-yes < /dev/null; then
            echo "Error: Swiftly could not install the latest Swift toolchain." >&2
            echo "See https://www.swift.org/install/linux/ for platform requirements and manual instructions." >&2
            return 1
        fi
        hash -r
    fi

    if ! command -v swift &>/dev/null; then
        echo "Error: Swiftly completed but 'swift' is still unavailable." >&2
        echo "See https://www.swift.org/install/linux/ for platform requirements and manual instructions." >&2
        return 1
    fi
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

# Clone REPO_URL at REF into DEST. A full 40-hex commit SHA cannot be used with
# `git clone --branch`, so fetch it explicitly; tags and branches use a shallow
# branch clone. This keeps an explicit immutable ref (tag/commit) robust.
checkout_ref() {
    local repo_url="$1"
    local ref="$2"
    local dest="$3"

    if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
        git init --quiet "$dest"
        git -C "$dest" remote add origin "$repo_url"
        if ! git -C "$dest" fetch --depth 1 origin "$ref"; then
            echo "Error: could not fetch commit ${ref} from ${repo_url}." >&2
            echo "       Ensure the commit exists and is reachable." >&2
            exit 1
        fi
        git -C "$dest" checkout --quiet FETCH_HEAD
    else
        git clone --depth 1 --branch "$ref" "$repo_url" "$dest"
    fi
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

    warn_if_mobile_ref "$REPO_REF"
    echo "Downloading ZenCODE installer checkout (ref: ${REPO_REF})..."
    checkout_ref "$REPO_URL" "$REPO_REF" "$checkout"
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
        --ref)
            if [ "$#" -lt 2 ]; then
                echo "Error: --ref requires a git ref argument." >&2
                exit 1
            fi
            REPO_REF="$2"
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

if ! ensure_swift_toolchain; then
    exit 1
fi

echo "Swift toolchain:"
if ! swift --version; then
    echo "Error: Swift is installed but could not run successfully." >&2
    echo "See https://www.swift.org/install/linux/ for platform requirements and manual instructions." >&2
    exit 1
fi
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

# Remove the obsolete executable from installations created by older releases.
# Xcode's MCP service is unavailable on Linux, so retaining this bundled feature
# would make runtime discovery expose an unusable tool provider.
$SUDO rm -f "${FEATURES_DIR}/xcode-tools-feature"

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
