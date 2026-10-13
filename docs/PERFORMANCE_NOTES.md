# Performance changes — 2026-09-19

The startup list previously observed every StatEvent and rebuilt all scores on each redraw, including while a recording screen was open. Startup also fetched all historical events to freeze player numbers and walked every video file on the UI thread.

Changes:

- Open the existing SwiftData store and prepare legacy number snapshots on a background task. Show a responsive loading/error screen during preparation; never replace or erase the store on failure.
- Load only successful scoring events and finished markers for the match list, projecting only the fields needed for the score. Fetch in batches using a private context and return value summaries. Refresh when the list reappears or saved data changes; cancel when it is hidden. Analysis, team and settings screens are constructed on navigation.
- Limit per-match number snapshots to that match. Startup snapshot lookup excludes events without players and does not fetch event JSON.
- Stop clock redraws when paused; running clocks update once per second and short timed clips update five times per second. Schedule the next clip deadline instead of polling continuously. Keep exact saved durations.
- Index recording events by team/category, reuse card summaries and scoring leaders, suppress unchanged refresh notifications, and use dictionary lookup for Undo restoration.
- Decode display-sized images on a background queue. Bound decoded image cache cost to 32 MB and keep original files intact. Set video backup exclusion on its directory rather than visiting every video.
- Reuse metric definitions, prepare combined filters once per collection and share grouped summaries between report rows and export.

Validation:

- 118 regression checks passed, including edits/Undo/cache refresh, timer deadline accuracy, scoped number snapshots, image orientation/transparency and analysis equivalence.
- A 5,005-event fixture fetched 4 relevant records for the match-list score; its summary took 0.0034 seconds on the development machine. This is a synthetic query check, not a measurement of iPhone startup time.
- Debug and iPhone Release builds passed. Simulator normal startup, existing match scores and navigation to/from analysis were checked.
- An Instruments launch comparison could not start on the device and was cancelled; no measured before/after startup speedup is claimed.

The updated Release was installed in place on iPhone 14 Pro. Launch succeeded and repeated device process snapshots confirmed the app remained running (PID 3585). A console attachment timed out, so no device UI response-time number is claimed. Details are recorded in IMPLEMENTATION_PROGRESS.md.

## Concurrency warning follow-up — 2026-09-20

- Recording JSON values and layout sizing are explicitly nonisolated, Sendable values. The decoded-details cache uses thread-safe NSCache with immutable boxes. UI stores retain main-actor isolation.
- Background removal remains on its existing detached worker. CSV escaping is a pure nonisolated operation. Highlight progress stays on the main actor without redundant awaits.
- Tournament CSV creates and uses its own context entirely inside a background worker. It fetches only the selected tournament's events/lineups, groups them once by match, and returns only a Sendable filename/text value. The only main-actor input is a copy of the metric labels.
- Device-specific iPad previews use PreviewProvider so their device/orientation modifiers work. Xcode's actual recommendations were applied: dead code stripping and string catalog symbol generation; the Swift language mode and actor-checking settings were preserved.
- All 120 regression checks passed, including two new background tournament CSV checks for output equivalence and an empty tournament. Xcode's Debug build succeeded with an empty Issue Navigator; the separate full Simulator Debug build also passed without source warnings.
- The full iOS Release build and strict signature verification passed. Command-line build logs retain only the toolchain's notice that App Intents metadata extraction is skipped because this app has no AppIntents dependency. Logs: `/tmp/rugby-as-warnings-debug.log`, `/tmp/rugby-as-warnings-release.log`, `/tmp/rugby-as-warnings-tests.log`.
- This follow-up is not installed on the iPhone: both registered devices were unavailable during verification. The previously installed performance build remains unchanged on the device.

## Large official-record data — 2026-10-05

After importing official records the store holds about 21,300 matches, 41,800 players, 241,000 plays and 460,000 lineup rows. Measured with that data (simulator / Mac):

- Analysis froze the app for over 90 seconds because it fetched every play, lineup row and player on the main thread. `AnalysisWorkspaceLoader` (a ModelActor) now loads plays once, keeps them until a save is signalled, and returns display values only. First open about 20 s with a progress state, later changes are near instant; the saved-report screen shares the loader. Lists draw the newest 50 matches / top 100 players and state the totals.
- Startup ran a whole-store lineup-number sweep (about 22 s on a Mac) and recounted every match score (about 7 s) on every launch, and the list recounted again each time it reappeared, disabling all rows meanwhile. `ModelChangeTracker` records which matches change on each save (`MatchWorkStore`, persisted in UserDefaults; large or unidentifiable changes become a full pass). Startup checks numbers only for changed matches; a full sweep runs once, in the background, after the UI appears. Match scores are cached in `MatchListTallies.v1.json`, shown immediately and recounted only for changed matches. Second launch shows the scored list at once.
- Backup restore runs in stages with a progress page; the final save of 800,000 rows still takes about a minute and cannot be split.

## Analysis screen freeze — 2026-10-12

The analysis screen ("分析・比較") still froze the whole app on first open and on every condition change. A sample of the running app (simulator, real data: 21,300 matches, 305,000 plays) showed `AnalysisWorkspaceLoader.compute` running on the main thread: a SwiftData `@ModelActor` runs on the main thread on this OS even when it is created from a detached task (checked with a small standalone program), so the "background" work blocked taps, including tab switches.

Changes:

- `AnalysisWorkspaceLoader` is now a plain `actor` that makes its own `ModelContext` per call (the same pattern as the tournament CSV and match-list workers). A regression check asserts it runs off the main thread.
- One loader is shared by the analysis screen, the report screen and the player page (`AnalysisLoaderStore`), so loaded plays are reused across visits; it is invalidated on every save.
- Matches are kept as value rows (`AnalysisMatchRow`). Only the rows that are shown are aggregated: the newest 50 matches and the top 100 players (`AnalysisComparison.topPlayerRows`, same order as before), and only those players are fetched (previously all 17,000).
- `RecordingMetricAggregation.summary` counts in one pass instead of filtering and copying the plays four times (same results).

Measured on the Mac (optimized build, same data): first open 3.5 s → 1.7 s, changing a condition 2.0 s → 0.3 s, report 0.9 s → 0.4 s. In the simulator the tab switch and metric changes respond immediately and no loader frames appear on the main thread. Not yet measured on an iPhone.
