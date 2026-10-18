#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

current_hooks_path="$(git config --get core.hooksPath || true)"
if [[ -n "$current_hooks_path" && "$current_hooks_path" != ".githooks" ]]; then
    echo "Existing core.hooksPath: $current_hooks_path. Keep it and integrate .githooks/commit-msg manually." >&2
    exit 1
fi

if [[ -z "$current_hooks_path" ]]; then
    current_hooks_dir="$(git rev-parse --git-path hooks)"
    for existing_hook in "$current_hooks_dir"/*; do
        [[ "$existing_hook" == *.sample ]] && continue
        if [[ -f "$existing_hook" && -x "$existing_hook" ]]; then
            echo "Existing Git hook: $existing_hook. Integrate .githooks/commit-msg manually." >&2
            exit 1
        fi
    done
fi

if [[ ! -x .githooks/commit-msg ]]; then
    echo "Missing executable .githooks/commit-msg." >&2
    exit 1
fi

git config --local core.hooksPath .githooks
echo "Commit message validation enabled for this repository."
