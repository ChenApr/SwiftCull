#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/crop-smoke" \
  "$project_dir/SwiftCull/Models/PhotoEntry.swift" \
  "$project_dir/SwiftCull/Models/CropVersion.swift" \
  "$project_dir/SwiftCull/Services/CropCatalog.swift" \
  "$project_dir/SwiftCull/Services/CropImageService.swift" \
  "$project_dir/Tests/CropSmoke.swift"

SWIFTCULL_CROPS_DIRECTORY="$test_dir/crops" "$test_dir/crop-smoke"
