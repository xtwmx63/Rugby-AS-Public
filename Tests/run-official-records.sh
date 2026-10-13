#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
archive_path="${1:-$project_dir/Rugby AS/OfficialRecords.sqlite}"
if [[ ! -f "$archive_path" ]]; then
  echo "Official archive not found: $archive_path" >&2
  echo "Build it with Tools/official_records/build_archive.py before running these checks." >&2
  exit 1
fi
build_dir="$(mktemp -d /tmp/rugby-official-regressions.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$build_dir/modules" \
  "$project_dir/Rugby AS/OfficialRecordsStore.swift" \
  "$project_dir/Tests/OfficialRecordsRegressionChecks.swift" \
  -o "$build_dir/OfficialRecordsRegressionChecks"
"$build_dir/OfficialRecordsRegressionChecks" "$archive_path"
