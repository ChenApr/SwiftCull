#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Compile the real store and its dependencies; exclude only the SwiftUI app entry point.
sources=()
while IFS= read -r -d '' source; do
  sources+=("$source")
done < <(find "$project_dir/SwiftCull" -name '*.swift' ! -name 'SwiftCullApp.swift' -print0)

swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "${sources[@]}" "$project_dir/Tests/DataIntegritySmoke.swift" \
  -o "$test_dir/data-integrity-smoke"
"$test_dir/data-integrity-smoke"
