#!/bin/bash
# チーム・選手の統合とつなぎ込みの確認(bash Tests/run-identity-merge.sh)
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/rugby-as-identity.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
sources=(
  Models.swift VideoStorage.swift
  "Rugby AS/PlayOrigin.swift" "Rugby AS/RecordingWidgetCore.swift" "Rugby AS/RecordingBoardGeometry.swift"
  "Rugby AS/RecordingBoardViewport.swift" "Rugby AS/RecordingMetricCatalog.swift" "Rugby AS/RecordingAnalysisFilter.swift"
  "Rugby AS/AnalysisComparison.swift" "Rugby AS/AnalysisReport.swift" "Rugby AS/RecordingWidgetStore.swift" "Rugby AS/AnalysisEventRecord.swift"
  "Rugby AS/RecordingResumeState.swift" "Rugby AS/MatchStatistics.swift" "Rugby AS/MatchNumbering.swift"
  "Rugby AS/MatchListSummary.swift" "Rugby AS/ImageThumbnailDecoder.swift" "Rugby AS/MatchCSVExporter.swift"
  "Rugby AS/TournamentCSVLoader.swift" "Rugby AS/BackupImageFiles.swift" "Rugby AS/BackupManager.swift"
  "Rugby AS/AppPersistence.swift" "Rugby AS/MatchVideoClock.swift" "Rugby AS/MatchVideoTimeline.swift"
  "Rugby AS/ScoringCategory.swift" "Rugby AS/OfficialRecordsStore.swift" "Rugby AS/OfficialRecordImport.swift"
  "Rugby AS/TeamMerge.swift" "Rugby AS/PlayerMerge.swift" "Rugby AS/PersonLink.swift" "Rugby AS/DuplicateFinder.swift" "Rugby AS/TournamentCategory.swift" "Rugby AS/TournamentMeta.swift" "Rugby AS/TournamentDeletion.swift"
  "Rugby AS/TeamFolders.swift" "Rugby AS/TournamentFolders.swift"
  Tests/IdentityMergeChecks.swift
)
# 作業途中の動画まわりの変更が YouTubeVideoLink を使うことがあるので、あれば一緒に入れる
if [ -f "$project_dir/Rugby AS/YouTubeVideoLink.swift" ]; then sources+=("Rugby AS/YouTubeVideoLink.swift"); fi
paths=()
for source in "${sources[@]}"; do paths+=("$project_dir/$source"); done
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$build_dir/modules" "${paths[@]}" -o "$build_dir/IdentityMergeChecks"
"$build_dir/IdentityMergeChecks"
