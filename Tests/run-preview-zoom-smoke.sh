#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

sources=()
while IFS= read -r -d '' source; do
  sources+=("$source")
done < <(find "$project_dir/SwiftCull" -name '*.swift' ! -name 'SwiftCullApp.swift' -print0)

# Native zoom and progressive loading use generated images, with no personal photos.
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "${sources[@]}" \
  "$project_dir/Tests/PreviewZoomSmoke.swift" -o "$test_dir/preview-zoom-smoke"
"$test_dir/preview-zoom-smoke"
