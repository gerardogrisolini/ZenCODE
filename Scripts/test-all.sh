#!/bin/bash
# test-all.sh — Run all SwiftPM package tests, including catalog features.
#
# Usage:
#   Scripts/test-all.sh [--jobs N|-j N] [--scratch-root DIR] [--serial]
#                       [--only NAME[,NAME...]]... [--help]
#   Scripts/test-all.sh --only zencron,git-tools --jobs 2
#   Scripts/test-all.sh --scratch-root /tmp/zencode-linux-build
#
# Two package jobs are used by default: each feature can also compile the root
# package, so more concurrent builds can exhaust CPU and memory. Test cases run
# in parallel unless --serial is specified. On Linux, use a separate scratch
# root when repository .build directories are shared with macOS: their artifacts
# are incompatible (see rpios-test.sh). Logs are retained in a temporary folder.
# The catalog and package descriptions are parsed with Swift/Foundation, already
# required by this repository, avoiding an extra dependency such as jq.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/test-all.sh [options]

  -j, --jobs N        Maximum concurrent package jobs (default: 2)
  --scratch-root DIR  Separate SwiftPM scratch directory per package
  --serial            Disable parallel test-case execution (diagnostics)
  --only NAME[,NAME]  Select packages; repeatable (root, zencron, zenapp,
                      or feature IDs from feature-catalog.json)
  --help              Show this help
EOF
}

error() { echo "Error: $*" >&2; exit 1; }

jobs=2
scratch_root=''
serial=0
only_count=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --jobs|-j)
            [ "$#" -ge 2 ] || error "$1 requires a positive integer"
            case "$2" in ''|*[!0-9]*) error "$1 requires a positive integer" ;; esac
            # Bound the value before arithmetic, including on 32-bit shells.
            case "$2" in *[!0]* ) ;; *) error "$1 requires a positive integer" ;; esac
            [ "${#2}" -le 4 ] || error "$1 is too large"
            jobs=$((10#$2))
            shift 2 ;;
        --scratch-root)
            [ "$#" -ge 2 ] && [ -n "$2" ] || error '--scratch-root requires a directory'
            scratch_root=$2
            shift 2 ;;
        --serial) serial=1; shift ;;
        --only)
            [ "$#" -ge 2 ] && [ -n "$2" ] || error '--only requires a package name'
            case "$2" in ,*|*,|*,,*) error "invalid --only list: $2" ;; esac
            IFS=',' read -r -a requested <<< "$2"
            for name in "${requested[@]}"; do
                only_names[$only_count]=$name
                only_count=$((only_count + 1))
            done
            shift 2 ;;
        *) error "unknown option: $1 (use --help)" ;;
    esac
done

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "$scratch_root" ]; then
    mkdir -p "$scratch_root"
    scratch_root=$(cd "$scratch_root" && pwd)
fi
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/zencode-test-all.XXXXXXXX")
echo "Logs: $log_dir"

# Track direct worker processes and terminate their descendants before the worker.
# SwiftPM itself spawns compiler and test processes; killing only its shell would
# leave builds running after Ctrl-C. ps/awk are available on macOS and Linux.
active_count=0
terminate_tree() {
    local parent=$1 child
    for child in $(ps -A -o pid= -o ppid= | awk -v p="$parent" '$2 == p { print $1 }'); do
        terminate_tree "$child"
    done
    kill -TERM "$parent" 2>/dev/null || :
}
interrupt() {
    trap '' INT TERM
    echo "Interrupted; stopping package jobs..." >&2
    local i=0
    while [ "$i" -lt "$active_count" ]; do
        terminate_tree "${active_pids[$i]}"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$active_count" ]; do
        wait "${active_pids[$i]}" 2>/dev/null || :
        i=$((i + 1))
    done
    exit 130
}
trap interrupt INT TERM

catalog="$repo_dir/Sources/ZenPackageMetadata/feature-catalog.json"
packages="$log_dir/packages.tsv"
printf 'root\t.\ttrue\nzencron\tSources/ZenCRON\ttrue\nzenapp\tSources/ZenApp\tfalse\n' > "$packages"
if ! swift - "$catalog" >> "$packages" 2> "$log_dir/catalog.log" <<'SWIFT'
import Foundation

struct Catalog: Decodable { let features: [Feature] }
struct Feature: Decodable {
    let id: String
    let sourceRelativePath: String
    let isInstalledOnLinux: Bool
}
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for feature in catalog.features {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !feature.id.isEmpty, feature.id != ".", feature.id != "..",
          feature.id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          !feature.sourceRelativePath.contains("\t"), !feature.sourceRelativePath.contains("\n"),
          !feature.sourceRelativePath.isEmpty else {
        fatalError("Invalid feature ID or path in catalog: \(feature.id)")
    }
    print("\(feature.id)\t\(feature.sourceRelativePath)\t\(feature.isInstalledOnLinux)")
}
SWIFT
then
    error "cannot read feature catalog; see $log_dir/catalog.log"
fi

# Reject unknown selections before launching any package jobs.
i=0
while [ "$i" -lt "$only_count" ]; do
    name=${only_names[$i]}
    if ! awk -F '\t' -v name="$name" '$1 == name { found = 1 } END { exit !found }' "$packages"; then
        error "unknown package '$name' (see $catalog for feature IDs)"
    fi
    i=$((i + 1))
done

case "$(uname -s)" in
    Darwin) linux=0 ;;
    Linux) linux=1 ;;
    *) error 'only macOS and Linux are supported' ;;
esac

run_package() {
    local name=$1 path=$2 log="$log_dir/$1.log" result="$log_dir/$1.result"
    local start end elapsed rc count description has_tests
    start=$(date +%s)
    description="$log_dir/$name.description.json"
    rc=0
    # Avoid expanding empty arrays under Bash 3.2's nounset behavior.
    if [ -n "$scratch_root" ]; then
        swift package --package-path "$path" --scratch-path "$scratch_root/$name" describe --type json > "$description" 2> "$log" || rc=$?
    else
        swift package --package-path "$path" describe --type json > "$description" 2> "$log" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        has_tests=$(swift - "$description" 2>> "$log" <<'SWIFT'
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let targets = package["targets"] as? [[String: Any]] else {
    fatalError("Package description must contain targets")
}
print(targets.contains { ($0["type"] as? String) == "test" } ? "yes" : "no")
SWIFT
        ) || rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ "$has_tests" = no ]; then
        end=$(date +%s)
        printf 'SKIP|%s|-\n' "$((end - start))" > "$result.tmp"
    else
        if [ "$rc" -eq 0 ]; then
            # Construct arguments incrementally, without empty-array expansion.
            set -- test --package-path "$path"
            if [ -n "$scratch_root" ]; then set -- "$@" --scratch-path "$scratch_root/$name"; fi
            if [ "$serial" -eq 1 ]; then set -- "$@" --no-parallel; fi
            swift "$@" >> "$log" 2>&1 || rc=$?
        fi
        end=$(date +%s)
        elapsed=$((end - start))
        # A package can have several test bundles, each with its own summary
        # line: report the sum of their test counts.
        count=$(sed -nE 's/.*Test run with ([0-9]+) tests? .* (passed|failed).*/\1/p' "$log" \
            | awk '{ total += $1 } END { if (NR > 0) print total }')
        count=${count:--}
        if [ "$rc" -eq 0 ]; then
            printf 'PASS|%s|%s\n' "$elapsed" "$count" > "$result.tmp"
        else
            printf 'FAIL|%s|%s\n' "$elapsed" "$count" > "$result.tmp"
        fi
    fi
    mv "$result.tmp" "$result"
}

# Collect any finished worker, rather than waiting for the oldest one. This
# keeps the concurrency limit useful even when package durations differ.
collect_finished() {
    local i=0 name status duration count
    while [ "$i" -lt "$active_count" ]; do
        name=${active_names[$i]}
        if [ ! -f "$log_dir/$name.result" ] && ! kill -0 "${active_pids[$i]}" 2>/dev/null; then
            wait "${active_pids[$i]}" || :
            if [ ! -f "$log_dir/$name.result" ]; then
                echo 'Package worker terminated unexpectedly.' >> "$log_dir/$name.log"
                printf 'FAIL|0|-\n' > "$log_dir/$name.result"
            fi
        fi
        if [ -f "$log_dir/$name.result" ]; then
            wait "${active_pids[$i]}" || :
            IFS='|' read -r status duration count < "$log_dir/$name.result"
            echo "$status $name (${duration}s)"
            active_count=$((active_count - 1))
            if [ "$i" -lt "$active_count" ]; then
                active_names[$i]=${active_names[$active_count]}
                active_pids[$i]=${active_pids[$active_count]}
            fi
        else
            i=$((i + 1))
        fi
    done
}

selected="$log_dir/selected.tsv"
summary_packages="$log_dir/summary.tsv"
: > "$selected"
: > "$summary_packages"
while IFS=$'\t' read -r name relative_path on_linux; do
    selected_name=0
    if [ "$only_count" -eq 0 ]; then
        selected_name=1
    else
        i=0
        while [ "$i" -lt "$only_count" ]; do
            if [ "${only_names[$i]}" = "$name" ]; then selected_name=1; break; fi
            i=$((i + 1))
        done
    fi
    [ "$selected_name" -eq 1 ] || continue
    printf '%s\t%s\n' "$name" "$relative_path" >> "$summary_packages"
    if [ "$linux" -eq 1 ] && [ "$on_linux" != true ]; then
        echo "SKIP $name (not available on Linux)"
        printf 'SKIP|0|-\n' > "$log_dir/$name.result"
        continue
    fi
    printf '%s\t%s\n' "$name" "$relative_path" >> "$selected"
done < "$packages"

while IFS=$'\t' read -r name relative_path; do
    while [ "$active_count" -ge "$jobs" ]; do
        collect_finished
        if [ "$active_count" -ge "$jobs" ]; then sleep 1; fi
    done
    echo "START $name"
    run_package "$name" "$repo_dir/$relative_path" &
    active_pids[$active_count]=$!
    active_names[$active_count]=$name
    active_count=$((active_count + 1))
done < "$selected"
while [ "$active_count" -gt 0 ]; do
    collect_finished
    if [ "$active_count" -gt 0 ]; then sleep 1; fi
done

printf '\nSummary:\n'
failed=0
while IFS=$'\t' read -r name relative_path; do
    IFS='|' read -r status duration count < "$log_dir/$name.result"
    printf '%-4s %-24s %5ss  tests: %s' "$status" "$name" "$duration" "$count"
    if [ "$status" = FAIL ]; then
        printf '  log: %s' "$log_dir/$name.log"
        failed=1
    fi
    printf '\n'
done < "$summary_packages"
exit "$failed"
