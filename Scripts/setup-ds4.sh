#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: Scripts/setup-ds4.sh /path/to/ds4 [options]

Installs the local DS4 runtime for ZenCODE without downloading DS4 or model files.

Options:
  --ds4-root DIR       DS4 source/build directory. Same as positional DIR.
  --library FILE       DS4 runtime library path. Default: <ds4-root>/libds4.dylib on macOS,
                       <ds4-root>/libds4.so elsewhere.
  --support-dir DIR    ZenCODE support directory. Default: $ZENCODE_SUPPORT_DIRECTORY or ~/.zencode.
  --skip-build         Do not build libds4.dylib; only validate and write settings.
  -h, --help           Show this help.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"
build_script="${repo_root}/Scripts/build-ds4-runtime.sh"
if [[ ! -x "$build_script" && -x "${script_dir}/build-ds4-runtime.sh" ]]; then
  build_script="${script_dir}/build-ds4-runtime.sh"
fi

ds4_root=""
library_path=""
support_dir="${ZENCODE_SUPPORT_DIRECTORY:-${HOME}/.zencode}"
skip_build=0

case "$(uname -s)" in
  Darwin)
    default_library_name="libds4.dylib"
    ;;
  *)
    default_library_name="libds4.so"
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ds4-root)
      [[ $# -ge 2 ]] || fail "missing value for --ds4-root"
      ds4_root="$2"
      shift 2
      ;;
    --library|--lib)
      [[ $# -ge 2 ]] || fail "missing value for $1"
      library_path="$2"
      shift 2
      ;;
    --support-dir)
      [[ $# -ge 2 ]] || fail "missing value for --support-dir"
      support_dir="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "unsupported option: $1"
      ;;
    *)
      if [[ -n "$ds4_root" ]]; then
        fail "unexpected argument: $1"
      fi
      ds4_root="$1"
      shift
      ;;
  esac
done

[[ -n "$ds4_root" ]] || {
  usage
  exit 2
}

absolute_dir() {
  local value="$1"
  [[ -d "$value" ]] || fail "directory not found: $value"
  (cd "$value" && pwd -P)
}

absolute_file_path() {
  local value="$1"
  local dir
  local base
  if [[ "$value" != /* ]]; then
    value="${PWD}/${value}"
  fi
  dir="$(dirname "$value")"
  base="$(basename "$value")"
  [[ -d "$dir" ]] || fail "directory not found: $dir"
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

absolute_output_dir() {
  local value="$1"
  if [[ "$value" != /* ]]; then
    value="${PWD}/${value}"
  fi
  mkdir -p "$value"
  (cd "$value" && pwd -P)
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

write_minimal_settings() {
  {
    printf '{\n'
    printf '  "ds4Root" : "%s",\n' "$(json_escape "$ds4_root")"
    printf '  "libraryPath" : "%s",\n' "$(json_escape "$library_path")"
    printf '  "version" : 1\n'
    printf '}\n'
  } > "$tmp_file"
}

write_merged_settings_with_python() {
  command -v python3 &>/dev/null || return 1
  python3 - "$settings_file" "$tmp_file" "$ds4_root" "$library_path" <<'PY'
import json
import sys

settings_file, tmp_file, ds4_root, library_path = sys.argv[1:5]
settings = {}

try:
    with open(settings_file, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        settings = loaded
except FileNotFoundError:
    pass
except Exception:
    settings = {}

settings["ds4Root"] = ds4_root
settings["libraryPath"] = library_path
settings["version"] = 1

with open(tmp_file, "w", encoding="utf-8") as handle:
    json.dump(settings, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

write_merged_settings_with_plutil() {
  [[ -f "$settings_file" ]] || return 1
  command -v plutil &>/dev/null || return 1

  cp "$settings_file" "$tmp_file"
  plutil -lint "$tmp_file" >/dev/null || return 1

  if ! plutil -replace ds4Root -string "$ds4_root" "$tmp_file"; then
    plutil -insert ds4Root -string "$ds4_root" "$tmp_file"
  fi
  if ! plutil -replace libraryPath -string "$library_path" "$tmp_file"; then
    plutil -insert libraryPath -string "$library_path" "$tmp_file"
  fi
  if ! plutil -replace version -integer 1 "$tmp_file"; then
    plutil -insert version -integer 1 "$tmp_file"
  fi
  plutil -convert json -r -o "$tmp_file" "$tmp_file"
}

write_settings() {
  if write_merged_settings_with_python; then
    return 0
  fi
  if write_merged_settings_with_plutil; then
    return 0
  fi
  write_minimal_settings
}

ds4_root="$(absolute_dir "$ds4_root")"
library_path="$(absolute_file_path "${library_path:-${ds4_root}/${default_library_name}}")"
support_dir="$(absolute_output_dir "$support_dir")"

if [[ "$skip_build" -eq 0 ]]; then
  [[ -x "$build_script" ]] || fail "build script not found or not executable: $build_script"
  "$build_script" "$ds4_root"
fi

[[ -f "$library_path" ]] || fail "DS4 runtime library not found: $library_path"

settings_dir="${support_dir}/ds4"
settings_file="${settings_dir}/settings.json"
tmp_file="${settings_file}.tmp.$$"

mkdir -p "$settings_dir"
write_settings
mv "$tmp_file" "$settings_file"

echo "DS4 configured for ZenCODE."
echo "  settings: $settings_file"
echo "  root:     $ds4_root"
echo "  library:  $library_path"
echo ""
echo "Next select the DS4 model from:"
echo "  zen --setup"
echo ""
echo "Then validate and run with:"
echo "  zen --ds4 --doctor"
echo "  zen --ds4"
