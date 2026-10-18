#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
sources=(
  Models/PhotoEntry.swift Models/CropVersion.swift Models/PhotoExifInfo.swift
  Models/PhotoBorderConfiguration.swift Models/WatermarkConfiguration.swift
  Models/WatermarkFont.swift Models/WatermarkFontDownload.swift
  Services/WatermarkFontDownloads.swift Services/WatermarkCustomRenderer.swift
  Services/CropImageService.swift Services/SemiWatermarkRenderer.swift
  Services/WatermarkPresetStore.swift Services/WatermarkService.swift Services/PhotoBorderRenderer.swift
)
for index in "${!sources[@]}"; do sources[$index]="$project_dir/SwiftCull/${sources[$index]}"; done
swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "${sources[@]}" "$project_dir/Tests/WatermarkFontDownloadSmoke.swift" -o "$test_dir/font-download-smoke"
SWIFTCULL_FONT_TEST_SOURCE="$project_dir/SwiftCull/Fonts" "$test_dir/font-download-smoke"
