#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/live-feature-e2e.XXXXXX")"
workspace="$tmp_root/workspace"
support_dir="$tmp_root/zencode"
log_file="$tmp_root/zencode.log"
branch_name="${ZENCODE_LIVE_FEATURE_BRANCH:-live-feature-e2e-branch}"
model_id="${ZENCODE_LIVE_MODEL:-mlx-community/Qwen3.6-35B-A3B-4bit}"
feature_id="${ZENCODE_LIVE_FEATURE_ID:-live-git-branch}"
tool_name="${ZENCODE_LIVE_TOOL_NAME:-live.git_current_branch}"
keep_tmp="${ZENCODE_LIVE_KEEP_TMP:-0}"

cleanup() {
    if [[ "$keep_tmp" != "1" ]]; then
        rm -rf "$tmp_root"
    else
        printf 'Keeping live feature E2E temp directory: %s\n' "$tmp_root" >&2
    fi
}
trap cleanup EXIT

mkdir -p "$workspace" "$support_dir"
mkdir -p "$support_dir/features"

cat > "$support_dir/agents.json" <<JSON
{
  "version": 1,
  "agents": [
    {
      "id": "00000000-0000-0000-0000-00000000e2e0",
      "name": "LiveFeatureE2E",
      "instructions": "You are running a live integration test. Use generated Swift features for reusable missing capabilities. For this test, create the requested feature with feature.scaffold, edit its Swift source with local file tools, run feature.validate, run feature.build, enable it, and then invoke the generated tool. Do not use local.exec or any git.* tool; the generated feature itself may execute git with Foundation.Process.",
      "tools": [
        "files",
        "text",
        "features"
      ],
      "skills": []
    }
  ]
}
JSON

git -C "$workspace" init -q
git -C "$workspace" config user.email "live-feature-e2e@example.invalid"
git -C "$workspace" config user.name "mlx live feature e2e"
printf 'live feature e2e\n' > "$workspace/README.md"
git -C "$workspace" add README.md
git -C "$workspace" commit -q -m "Initial commit"
git -C "$workspace" checkout -q -b "$branch_name"

prompt=$(
    cat <<PROMPT
Sviluppa e usa una feature Swift generata e verificabile.

Obiettivo:
- feature id: ${feature_id}
- tool name: ${tool_name}
- generated feature directory: ${support_dir}/features/${feature_id}
- the tool must return exactly the current Git branch name for the path received as input.

Constraints:
- Do not use local.exec.
- Do not use git.* tools.
- Use feature.scaffold to create a Swift 6.3 feature.
- When calling feature.scaffold, pass "directory": "${support_dir}/features/${feature_id}" and do not choose any other path.
- Modify the generated feature with the available local.* / text.* tools.
- The tool may use Foundation.Process internally to run git rev-parse --abbrev-ref HEAD.
- Keep the schema simple: accept {"text":"."}, where text is the path to resolve relative to the working directory.
- After the change, run feature.validate, feature.build, feature.enable.
- At the end, invoke ${tool_name} with {"text":"."}.
- The test repo is already on branch ${branch_name}.
- The final response must contain exactly:
LIVE_FEATURE_E2E_OK ${tool_name}=${branch_name}
PROMPT
)

run_args=(
    run
    zen
    --mlx
    --cwd "$workspace"
    --model "$model_id"
    --agent LiveFeatureE2E
    --max-tool-rounds "${ZENCODE_LIVE_MAX_TOOL_ROUNDS:-40}"
    --max-output-tokens "${ZENCODE_LIVE_MAX_OUTPUT_TOKENS:-12000}"
    --verbose
)

printf 'Running live feature E2E with model: %s\n' "$model_id" >&2
printf 'Workspace: %s\n' "$workspace" >&2
printf 'Support directory: %s\n' "$support_dir" >&2

set +e
(
    cd "$repo_root"
    printf '%s\n' "$prompt" | ZENCODE_SUPPORT_DIRECTORY="$support_dir" swift "${run_args[@]}"
) >"$log_file" 2>&1
exit_code=$?
set -e

if [[ "$exit_code" -ne 0 ]]; then
    printf 'zen --mlx failed with exit code %s\n' "$exit_code" >&2
    cat "$log_file" >&2
    exit "$exit_code"
fi

feature_dir="$support_dir/features/$feature_id"
package_file="$feature_dir/Package.swift"
manifest_file="$feature_dir/feature.json"
executable_file=""
while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
        executable_file="$candidate"
        break
    fi
done < <(find "$feature_dir/.build" -type f -name "$feature_id" 2>/dev/null)

if [[ ! -f "$package_file" ]]; then
    printf 'Expected generated Package.swift not found: %s\n' "$package_file" >&2
    cat "$log_file" >&2
    exit 1
fi

if [[ "$(head -n 1 "$package_file")" != "// swift-tools-version: 6.3" ]]; then
    printf 'Generated feature does not target Swift tools 6.3\n' >&2
    head -n 5 "$package_file" >&2
    exit 1
fi

if [[ ! -f "$manifest_file" ]] || ! grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true' "$manifest_file"; then
    printf 'Generated feature manifest is missing or not enabled: %s\n' "$manifest_file" >&2
    cat "$manifest_file" >&2 || true
    exit 1
fi

if [[ ! -x "$executable_file" ]]; then
    printf 'Generated feature executable is missing or not executable: %s\n' "$executable_file" >&2
    cat "$log_file" >&2
    exit 1
fi

verification_json="$(
    printf '{"text":"."}\n' |
        "$executable_file" --invoke "$tool_name" --working-directory "$workspace"
)"

if [[ "$verification_json" != *"\"ok\":true"* ]] || [[ "$verification_json" != *"\"output\":\"$branch_name\""* ]]; then
    printf 'Generated tool returned unexpected output.\n' >&2
    printf 'Invocation JSON: %s\n' "$verification_json" >&2
    cat "$log_file" >&2
    exit 1
fi

if ! grep -Fq "LIVE_FEATURE_E2E_OK ${tool_name}=${branch_name}" "$log_file"; then
    printf 'Model final answer did not contain the expected success sentinel.\n' >&2
    cat "$log_file" >&2
    exit 1
fi

printf 'LIVE_FEATURE_E2E_OK %s=%s\n' "$tool_name" "$branch_name"
printf 'Generated feature: %s\n' "$feature_dir"
