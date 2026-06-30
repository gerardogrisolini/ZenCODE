#!/usr/bin/env bash
set -euo pipefail

# ZenCODE Linux installer
#
# Builds ZenCODE and its bundled feature executables from source and installs
# them. Intended for native Linux and for Windows via WSL (Ubuntu). When
# launched outside a repository checkout, for example with curl | bash, the
# installer uses a temporary source checkout and removes it before exiting.
#
# Local MLX inference is Apple-only, so this installer never pulls in MLX/Metal
# dependencies. DS4 support is available on Linux and can be included or
# omitted at build time.
#
# Environment overrides:
#   INSTALL_DIR    Directory for the ZenCODE binary (default: /usr/local/bin)
#   FEATURES_DIR   Directory for feature executables
#                  (default: $INSTALL_DIR/zen-features)
#   BUILD_CONFIG   SwiftPM configuration: release or debug (default: release)
#   WITH_DS4       yes/no, true/false, 1/0. Prompted when unset.
#   DS4_ROOT       DS4 source/build directory used when DS4 is enabled.
#                  ZENCODE_DS4_ROOT is also accepted.
#   ZENCODE_INSTALLER_REF
#                  Git ref used by the URL installer (default: main)
#
# Flags:
#   --debug          Build with the debug configuration
#   --prefix DIR     Install the binary into DIR (sets INSTALL_DIR)
#   --with-ds4       Compile DS4 support
#   --without-ds4    Do not compile DS4 support
#   --yes            Use defaults for unanswered prompts
#   -h, --help       Show this help and exit

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
WITH_DS4="${WITH_DS4:-}"
DS4_ROOT="${ZENCODE_DS4_ROOT:-${DS4_ROOT:-}}"
ASSUME_YES=0
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

Local MLX inference is Apple-only, so this installer never pulls in MLX/Metal
dependencies. DS4 support is available on Linux and can be included or
omitted at build time.

Environment overrides:
  INSTALL_DIR    Directory for the ZenCODE binary (default: /usr/local/bin)
  FEATURES_DIR   Directory for feature executables
                 (default: $INSTALL_DIR/zen-features)
  BUILD_CONFIG   SwiftPM configuration: release or debug (default: release)
  WITH_DS4       yes/no, true/false, 1/0. Prompted when unset.
  DS4_ROOT       DS4 source/build directory used when DS4 is enabled.
                 ZENCODE_DS4_ROOT is also accepted.
  ZENCODE_INSTALLER_REF
                 Git ref used by the URL installer (default: main)
Flags:
  --debug          Build with the debug configuration
  --prefix DIR     Install the binary into DIR (sets INSTALL_DIR)
  --with-ds4       Compile DS4 support
  --without-ds4    Do not compile DS4 support
  --yes            Use defaults for unanswered prompts
  -h, --help       Show this help and exit
EOF
}

parse_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|y|on)
            printf '1'
            ;;
        0|false|no|n|off)
            printf '0'
            ;;
        *)
            return 1
            ;;
    esac
}

restore_prompt_terminal() {
    if [ -t 0 ]; then
        stty sane < /dev/tty 2>/dev/null || stty sane 2>/dev/null || true
    fi
}

prompt_bool() {
    local label="$1"
    local default_value="$2"
    local raw_value="${3:-}"
    local parsed=""
    local suffix="Y/n"

    if [ "$default_value" = "0" ]; then
        suffix="y/N"
    fi

    if [ -n "$raw_value" ]; then
        if parsed="$(parse_bool "$raw_value")"; then
            printf '%s' "$parsed"
            return 0
        fi
        echo "Error: invalid boolean value '$raw_value' for ${label}." >&2
        exit 1
    fi

    if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
        printf '%s' "$default_value"
        return 0
    fi

    restore_prompt_terminal
    while true; do
        printf '%s [%s]: ' "$label" "$suffix" >&2
        IFS= read -r answer || answer=""
        if [ -z "$answer" ]; then
            printf '%s' "$default_value"
            return 0
        fi
        if parsed="$(parse_bool "$answer")"; then
            printf '%s' "$parsed"
            return 0
        fi
        echo "Please answer yes or no." >&2
    done
}

absolute_dir() {
    local value="$1"
    case "$value" in
        "~")
            value="$HOME"
            ;;
        "~/"*)
            value="${HOME}/${value#~/}"
            ;;
    esac
    if [ ! -d "$value" ]; then
        return 1
    fi
    (cd "$value" && pwd -P)
}

default_ds4_root() {
    local candidates=(
        "${PACKAGE_DIR}/../ds4"
        "${HOME}/Projects/ds4"
        "${HOME}/projects/ds4"
        "${PACKAGE_DIR}/ds4"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            absolute_dir "$candidate"
            return 0
        fi
    done
    return 1
}

stored_ds4_root() {
    local settings_file="${ZENCODE_SUPPORT_DIRECTORY:-${HOME}/.zencode}/ds4/settings.json"
    local value=""
    if [ ! -f "$settings_file" ]; then
        return 1
    fi

    if command -v python3 &>/dev/null; then
        value="$(python3 - "$settings_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        value = json.load(handle).get("ds4Root", "")
    if isinstance(value, str):
        print(value)
except Exception:
    pass
PY
)"
    elif command -v plutil &>/dev/null; then
        value="$(plutil -extract ds4Root raw -o - "$settings_file" 2>/dev/null || true)"
    else
        value="$(sed -n 's/.*"ds4Root"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings_file" | head -n 1)"
    fi

    if [ -z "$value" ]; then
        return 1
    fi
    absolute_dir "$value"
}

preferred_ds4_root() {
    if [ -n "$DS4_ROOT" ]; then
        absolute_dir "$DS4_ROOT"
        return $?
    fi
    stored_ds4_root || default_ds4_root
}

prompt_directory() {
    local label="$1"
    local default_value="${2:-}"
    local answer=""
    local resolved=""

    if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 ]; then
        if [ -n "$default_value" ]; then
            printf '%s' "$default_value"
            return 0
        fi
        echo "Error: DS4 support requires a DS4 directory. Run interactively or set DS4_ROOT." >&2
        exit 1
    fi

    restore_prompt_terminal
    while true; do
        if [ -n "$default_value" ]; then
            printf '%s [%s]: ' "$label" "$default_value" >&2
        else
            printf '%s: ' "$label" >&2
        fi
        IFS= read -r answer || answer=""
        if [ -z "$answer" ] && [ -n "$default_value" ]; then
            printf '%s' "$default_value"
            return 0
        fi
        if [ -n "$answer" ] && resolved="$(absolute_dir "$answer")"; then
            printf '%s' "$resolved"
            return 0
        fi
        echo "Directory not found." >&2
    done
}

validate_ds4_root() {
    local ds4_root="$1"
    for header in ds4.h ds4_ssd.h; do
        if [ ! -f "${ds4_root}/${header}" ]; then
            echo "Error: ${header} not found under ${ds4_root}." >&2
            exit 1
        fi
    done
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
        --with-ds4)
            WITH_DS4=1
            shift
            ;;
        --without-ds4)
            WITH_DS4=0
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
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

cd "$PACKAGE_DIR"

DS4_DEFAULT=0
if [ -n "$DS4_ROOT" ] || preferred_ds4_root >/dev/null 2>&1; then
    DS4_DEFAULT=1
fi
WITH_DS4="$(prompt_bool "Compile DS4 support?" "$DS4_DEFAULT" "$WITH_DS4")"
if [ "$WITH_DS4" = "1" ]; then
    DS4_ROOT="$(prompt_directory "DS4 source/build directory" "$(preferred_ds4_root || true)")"
    validate_ds4_root "$DS4_ROOT"
fi

# Build ----------------------------------------------------------------------

FEATURE_PRODUCTS=(
    "search-tools-feature"
    "web-tools-feature"
    "git-tools-feature"
    "jira-tools-feature"
    "xcode-tools-feature"
    "figma-tools-feature"
)

echo "Building ZenCODE (${BUILD_CONFIG})..."
build_env=(
    "ZENCODE_BUILD_LOCAL_MLX=0"
    "ZENCODE_BUILD_DS4=${WITH_DS4}"
)
if [ "$WITH_DS4" = "1" ]; then
    build_env+=("ZENCODE_DS4_ROOT=${DS4_ROOT}")
fi

echo "Build configuration:"
echo "  config: ${BUILD_CONFIG}"
echo "  MLX:    disabled"
echo "  DS4:    $([ "$WITH_DS4" = "1" ] && echo enabled || echo disabled)"
if [ "$WITH_DS4" = "1" ]; then
    echo "  DS4 root: ${DS4_ROOT}"
fi
echo ""

env "${build_env[@]}" swift build -c "$BUILD_CONFIG" --product zen

for product in "${FEATURE_PRODUCTS[@]}"; do
    echo "Building ${product} (${BUILD_CONFIG})..."
    env "${build_env[@]}" swift build -c "$BUILD_CONFIG" --product "$product"
done

BIN_PATH="$(env "${build_env[@]}" swift build -c "$BUILD_CONFIG" --show-bin-path)"
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

if [ "$WITH_DS4" = "1" ]; then
    $SUDO mkdir -p "${INSTALL_DIR}/Scripts"
    for helper in setup-ds4.sh build-ds4-runtime.sh; do
        $SUDO cp "${SCRIPT_DIR}/${helper}" "${INSTALL_DIR}/Scripts/${helper}"
        $SUDO chmod +x "${INSTALL_DIR}/Scripts/${helper}"
    done
fi

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
echo "  MLX support  → omitted"
echo "  DS4 support  → $([ "$WITH_DS4" = "1" ] && echo included || echo omitted)"
if [ "$WITH_DS4" = "1" ]; then
    echo "  DS4 root     → ${DS4_ROOT}"
    echo "  DS4 scripts  → ${INSTALL_DIR}/Scripts/"
fi
echo ""
echo "Make sure ${INSTALL_DIR} is in your PATH."
echo ""
echo "Note: local MLX inference is Apple-only and is not available on Linux."
echo "Configure a remote provider with: zen --setup"
if [ "$WITH_DS4" = "1" ]; then
    echo "Build or locate libds4.so, then configure DS4 runtime with:"
    echo "  Scripts/setup-ds4.sh ${DS4_ROOT} --skip-build --library ${DS4_ROOT}/libds4.so"
fi
