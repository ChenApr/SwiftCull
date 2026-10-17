#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc=size=320x240:rate=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 6 -c:v libx264 -pix_fmt yuv420p -c:a aac \
  "$test_dir/source.mov"

swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/live-photo-smoke" \
  "$project_dir/SwiftCull/Services/LivePhotoService.swift" \
  "$project_dir/SwiftCull/Services/LivePhotoMOVWriter.swift" \
  "$project_dir/Tests/LivePhotoSmoke.swift"

"$test_dir/live-photo-smoke" "$test_dir/source.mov" "$test_dir"
