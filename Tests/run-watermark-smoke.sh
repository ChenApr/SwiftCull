#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/watermark-smoke" \
  "$project_dir/SwiftCull/Models/PhotoEntry.swift" \
  "$project_dir/SwiftCull/Models/CropVersion.swift" \
  "$project_dir/SwiftCull/Models/PhotoExifInfo.swift" \
  "$project_dir/SwiftCull/Models/WatermarkConfiguration.swift" \
  "$project_dir/SwiftCull/Models/WatermarkFont.swift" \
  "$project_dir/SwiftCull/Services/WatermarkCustomRenderer.swift" \
  "$project_dir/SwiftCull/Services/CropImageService.swift" \
  "$project_dir/SwiftCull/Services/SemiWatermarkRenderer.swift" \
  "$project_dir/SwiftCull/Services/WatermarkPresetStore.swift" \
  "$project_dir/SwiftCull/Services/WatermarkService.swift" \
  "$project_dir/Tests/WatermarkServiceSmoke.swift"

SWIFTCULL_WATERMARK_LOGOS_DIR="$project_dir/SwiftCull/Resources/WatermarkLogos" \
SWIFTCULL_WATERMARK_FONTS_DIR="$project_dir/SwiftCull/Fonts" \
  "$test_dir/watermark-smoke"
