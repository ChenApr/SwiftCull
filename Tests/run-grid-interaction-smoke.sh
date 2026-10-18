#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

sources=()
while IFS= read -r -d '' source; do
  sources+=("$source")
done < <(find "$project_dir/SwiftCull" -name '*.swift' ! -name 'SwiftCullApp.swift' -print0)

# Run on a logged-in macOS desktop; events target only this test's window.
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "${sources[@]}" "$project_dir/Tests/GridInteractionSmoke.swift" \
  -o "$test_dir/grid-interaction-smoke"
"$test_dir/grid-interaction-smoke"
