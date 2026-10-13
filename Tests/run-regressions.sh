#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /tmp/rugby-as-regressions.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$build_dir/modules" \
  "$project_dir/Models.swift" \
  "$project_dir/Rugby AS/PlayOrigin.swift" \
  "$project_dir/Rugby AS/RecordingWidgetCore.swift" \
  "$project_dir/Rugby AS/RecordingBoardGeometry.swift" \
  "$project_dir/Rugby AS/RecordingBoardViewport.swift" \
  "$project_dir/Rugby AS/RecordingMetricCatalog.swift" \
  "$project_dir/Rugby AS/RecordingAnalysisFilter.swift" \
  "$project_dir/Rugby AS/AnalysisComparison.swift" \
  "$project_dir/Rugby AS/AnalysisReport.swift" \
  "$project_dir/Rugby AS/AnalysisWorkspaceData.swift" \
  "$project_dir/Rugby AS/ModelSaveSignal.swift" \
  "$project_dir/Rugby AS/ModelChangeTracker.swift" \
  "$project_dir/Tests/ChangeTrackingRegressionChecks.swift" \
  "$project_dir/Tests/BreakdownImportChecks.swift" \
  "$project_dir/Rugby AS/RecordingWidgetStore.swift" \
  "$project_dir/Rugby AS/AnalysisEventRecord.swift" \
  "$project_dir/Rugby AS/RecordingResumeState.swift" \
  "$project_dir/Rugby AS/MatchStatistics.swift" \
  "$project_dir/Rugby AS/MatchNumbering.swift" \
  "$project_dir/Rugby AS/MatchListSummary.swift" \
  "$project_dir/Rugby AS/TeamPerformance.swift" \
  "$project_dir/Rugby AS/ImageThumbnailDecoder.swift" \
  "$project_dir/Rugby AS/MatchCSVExporter.swift" \
  "$project_dir/Rugby AS/TournamentCSVLoader.swift" \
  "$project_dir/Rugby AS/BackupImageFiles.swift" \
  "$project_dir/Rugby AS/BackupManager.swift" \
  "$project_dir/Rugby AS/AppPersistence.swift" \
  "$project_dir/VideoStorage.swift" \
  "$project_dir/Rugby AS/YouTubeVideoLink.swift" \
  "$project_dir/Rugby AS/MatchVideoClock.swift" \
  "$project_dir/Rugby AS/MatchVideoTimeline.swift" \
  "$project_dir/Rugby AS/ScoringCategory.swift" \
  "$project_dir/Rugby AS/OfficialRecordsStore.swift" \
  "$project_dir/Rugby AS/OfficialRecordImport.swift" \
  "$project_dir/Rugby AS/OfficialHeadToHead.swift" \
  "$project_dir/Rugby AS/TournamentCategory.swift" \
  "$project_dir/Rugby AS/TournamentMeta.swift" \
  "$project_dir/Tests/RecordingRegressionChecks.swift" \
  "$project_dir/Tests/BoardRegressionChecks.swift" \
  "$project_dir/Tests/MetricRegressionChecks.swift" \
  "$project_dir/Tests/RecordingInputRegressionChecks.swift" \
  "$project_dir/Tests/ScoringFlowRegressionChecks.swift" \
  "$project_dir/Tests/RecordingPerformanceRegressionChecks.swift" \
  "$project_dir/Tests/StartupPerformanceRegressionChecks.swift" \
  "$project_dir/Tests/ImageThumbnailRegressionChecks.swift" \
  "$project_dir/Tests/AnalysisPerformanceRegressionChecks.swift" \
  "$project_dir/Tests/RecordingIntegrationChecks.swift" \
  "$project_dir/Tests/BackupRegressionChecks.swift" \
  "$project_dir/Tests/MatchStatisticsRegressionChecks.swift" \
  "$project_dir/Tests/TeamPerformanceRegressionChecks.swift" \
  "$project_dir/Tests/VideoTimingRegressionChecks.swift" \
  "$project_dir/Tests/YouTubeRegressionChecks.swift" \
  "$project_dir/Tests/AnalysisFilterRegressionChecks.swift" \
  "$project_dir/Tests/PersistenceRegressionChecks.swift" \
  "$project_dir/Tests/AnalysisComparisonRegressionChecks.swift" \
  "$project_dir/Tests/AnalysisReportRegressionChecks.swift" \
  "$project_dir/Tests/TournamentCSVRegressionChecks.swift" \
  "$project_dir/Tests/OfficialImportRegressionChecks.swift" \
  "$project_dir/Tests/StatsExclusionRegressionChecks.swift" \
  -o "$build_dir/RecordingRegressionChecks"
"$build_dir/RecordingRegressionChecks"
