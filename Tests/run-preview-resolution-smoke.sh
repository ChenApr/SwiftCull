#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
    "$project_dir/SwiftCull/Models/PhotoEntry.swift" \
    "$project_dir/SwiftCull/Models/CropVersion.swift" \
    "$project_dir/SwiftCull/Models/FilterOptions.swift" \
    "$project_dir/SwiftCull/Services/CropImageService.swift" \
    "$project_dir/SwiftCull/Services/PhotoPreviewService.swift" \
    "$project_dir/Tests/PreviewResolutionSmoke.swift" -o "$test_dir/preview-resolution-smoke"
"$test_dir/preview-resolution-smoke"
