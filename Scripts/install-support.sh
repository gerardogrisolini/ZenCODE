#!/usr/bin/env bash

# Shared installation helpers for the macOS and Linux/WSL installers.

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
