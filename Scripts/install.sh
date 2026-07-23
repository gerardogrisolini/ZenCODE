#!/usr/bin/env bash

set -euo pipefail

# ZenCODE macOS installer
#
# Builds ZenCODE and installs the binary and bundled feature executables. When
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
CONFIG_BACKUP_DIR=""
CONFIG_SUPPORT_DIR=""
CONFIG_RELATIVE_PATHS=(
    "agents.json"
    "settings.json"
    "permissions.json"
    "AGENTS.md"
    "MEMORY.md"
    "features/state.json"
)
ORIGINAL_ARGS=("$@")

usage() {
    cat <<'EOF'
ZenCODE macOS installer

Builds ZenCODE and installs the binary and bundled feature executables. When
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

backup_existing_config_files() {
    CONFIG_SUPPORT_DIR="${ZENCODE_SUPPORT_DIRECTORY:-${HOME}/.zencode}"
    CONFIG_BACKUP_DIR="$(mktemp -d "${INSTALLER_TMPDIR%/}/zencode-config-backup.XXXXXX")"

    local relative_path
    local source_path
    local backup_path
    for relative_path in "${CONFIG_RELATIVE_PATHS[@]}"; do
        source_path="${CONFIG_SUPPORT_DIR}/${relative_path}"
        backup_path="${CONFIG_BACKUP_DIR}/${relative_path}"
        if [ -e "$source_path" ]; then
            mkdir -p "$(dirname "$backup_path")"
            cp -p "$source_path" "$backup_path"
        fi
    done
}

restore_config_files() {
    if [ -z "$CONFIG_BACKUP_DIR" ] || [ -z "$CONFIG_SUPPORT_DIR" ]; then
        return 0
    fi

    local relative_path
    local target_path
    local backup_path
    for relative_path in "${CONFIG_RELATIVE_PATHS[@]}"; do
        target_path="${CONFIG_SUPPORT_DIR}/${relative_path}"
        backup_path="${CONFIG_BACKUP_DIR}/${relative_path}"
        if [ -e "$backup_path" ]; then
            if [ ! -e "$target_path" ] || ! cmp -s "$backup_path" "$target_path"; then
                mkdir -p "$(dirname "$target_path")"
                cp -p "$backup_path" "$target_path"
                echo "Preserved existing configuration: ${target_path}"
            fi
        elif [ -e "$target_path" ]; then
            rm -f "$target_path"
            echo "Removed installer-created configuration: ${target_path}"
        fi
    done

    rm -rf "$CONFIG_BACKUP_DIR"
    CONFIG_BACKUP_DIR=""
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
    "${checkout}/Scripts/install.sh" "${ORIGINAL_ARGS[@]}"
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

echo "ZenCODE macOS installer"
echo ""

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: this script targets macOS." >&2
    echo "On Linux use Scripts/install-linux.sh." >&2
    exit 1
fi

if ! command -v swift &>/dev/null; then
    echo "Error: the Swift toolchain is required but 'swift' was not found." >&2
    echo "Install Xcode or the Apple command line tools first." >&2
    exit 1
fi

PACKAGE_DIR="$(resolve_package_dir || true)"
if [ -z "$PACKAGE_DIR" ]; then
    bootstrap_checkout
fi
SCRIPT_DIR="${PACKAGE_DIR}/Scripts"
source "${SCRIPT_DIR}/feature-catalog.sh"

backup_existing_config_files
trap restore_config_files EXIT

cd "$PACKAGE_DIR"

zencode_select_feature_products macos

echo ""
echo "Build configuration:"
echo "  config: ${BUILD_CONFIG}"
echo ""

echo "Swift toolchain:"
swift --version
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

echo ""
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
echo "Configure a provider with: zen --setup"
