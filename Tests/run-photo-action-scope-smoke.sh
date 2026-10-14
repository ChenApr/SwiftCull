#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

swiftc -module-cache-path "$test_dir/module-cache" -o "$test_dir/photo-action-scope-smoke" \
  "$project_dir/SwiftCull/Models/PhotoEntry.swift" \
  "$project_dir/SwiftCull/Models/PhotoActionScope.swift" \
  "$project_dir/Tests/PhotoActionScopeSmoke.swift"

"$test_dir/photo-action-scope-smoke"
