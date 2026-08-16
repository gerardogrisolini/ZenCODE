#!/usr/bin/env bash

# Shared installation helpers for the macOS and Linux/WSL installers.

# Returns success when a `swift --version` line identifies Swift 6.3 or newer.
# The comparison is numeric rather than lexicographic, so future major and
# two-digit minor versions remain valid on the Bash 3.2 shipped by macOS.
zencode_swift_version_is_supported() {
    if [ "$#" -ne 1 ]; then
        return 2
    fi

    local parsed=""
    local major=""
    local minor=""
    parsed="$(
        printf '%s\n' "$1" \
            | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' \
            | head -n 1
    )"
    if [ -z "$parsed" ]; then
        return 1
    fi

    major="${parsed%% *}"
    minor="${parsed#* }"
    [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 3 ]; }
}

zencode_require_supported_swift() {
    local version_output=""
    if ! version_output="$(swift --version 2>&1)"; then
        echo "Error: Swift is installed but could not run successfully." >&2
        return 1
    fi
    printf '%s\n' "$version_output"
    if ! zencode_swift_version_is_supported "$version_output"; then
        echo "Error: ZenCODE requires Swift 6.3 or newer." >&2
        return 1
    fi
}

# Runs an installation command directly or through the privilege escalator chosen
# by the caller. Keeping the empty case out of an array expansion matters on the
# Bash 3.2 shipped by macOS, where an empty array under `set -u` is an error.
zencode_run_install_command() {
    if [ -n "${SUDO:-}" ]; then
        "$SUDO" "$@"
    else
        "$@"
    fi
}

# Installs an executable without rewriting the inode that an already-running
# process may still be paging from. The staged file lives beside the target, so
# the final `mv` is a same-filesystem atomic rename: existing processes retain
# the old inode and new launches observe only the complete replacement.
zencode_install_executable_atomically() {
    if [ "$#" -ne 2 ]; then
        echo "Error: zencode_install_executable_atomically requires SOURCE and TARGET." >&2
        return 2
    fi

    local source_path="$1"
    local target_path="$2"
    local target_directory=""
    local target_name=""
    local staged_path=""

    target_directory="$(dirname "$target_path")"
    target_name="$(basename "$target_path")"

    # Create the staging inode in the destination directory. Besides making the
    # rename atomic, the hidden name keeps partially copied feature executables
    # out of normal runtime discovery.
    if ! staged_path="$(
        zencode_run_install_command mktemp \
            "${target_directory}/.${target_name}.install.XXXXXX"
    )"; then
        echo "Error: could not create an installation staging file for ${target_path}." >&2
        return 1
    fi

    if ! zencode_run_install_command cp "$source_path" "$staged_path"; then
        zencode_run_install_command rm -f "$staged_path" || true
        echo "Error: could not stage ${source_path} for installation." >&2
        return 1
    fi
    if ! zencode_run_install_command chmod 0755 "$staged_path"; then
        zencode_run_install_command rm -f "$staged_path" || true
        echo "Error: could not make the staged executable runnable: ${staged_path}." >&2
        return 1
    fi
    if ! zencode_run_install_command mv -f "$staged_path" "$target_path"; then
        zencode_run_install_command rm -f "$staged_path" || true
        echo "Error: could not atomically install ${target_path}." >&2
        return 1
    fi
}

# Removes the directory that older installations used for bundled feature
# executables. Optional features now live as local source packages under the
# support directory, so a stale executable there could otherwise shadow them.
#
# FEATURES_DIR is a documented environment override, so this deletion is guarded:
# it never removes the binary directory itself, a home directory, or a root path,
# and it does nothing when the directory is absent.
zencode_remove_legacy_feature_directory() {
    if [ "$#" -ne 2 ]; then
        echo "Error: zencode_remove_legacy_feature_directory requires FEATURES_DIR and INSTALL_DIR." >&2
        return 2
    fi

    local features_dir="${1%/}"
    local install_dir="${2%/}"

    if [ -z "$features_dir" ] || [ "$features_dir" = "/" ]; then
        return 0
    fi
    if [ "$features_dir" = "$install_dir" ] || [ "$features_dir" = "${HOME%/}" ]; then
        echo "Warning: refusing to remove ${features_dir} as a legacy feature directory." >&2
        return 0
    fi
    if [ ! -d "$features_dir" ]; then
        return 0
    fi

    echo "Removing legacy bundled feature executables from ${features_dir}..."
    if ! zencode_run_install_command rm -rf "$features_dir"; then
        echo "Warning: could not remove the legacy feature directory ${features_dir}." >&2
    fi
}
