#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# With no arguments use a generated image. Optional image paths are read only.
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "$project_dir/SwiftCull/Views/Components/PhotoZoomViewport.swift" \
  "$project_dir/Tests/PreviewZoomFocusSmoke.swift" -o "$test_dir/preview-zoom-focus-smoke"
"$test_dir/preview-zoom-focus-smoke" "$@"
