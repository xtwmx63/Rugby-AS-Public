# Official records import contract (v1)

Collectors emit a JSON object with `matches` (array), `coverage` (array) and `errors` (array).
Only structured match facts are retained, not site prose, images or match reports.

Every match has these keys (camelCase):

- `id`: source-prefixed stable ID, e.g. `jrfu:27761` / `leagueone:12345`
- `source`: `jrfu` / `leagueone` / `svns` / `rwc`
- `sourceMatchID`: string
- `season`: display label, e.g. `2025` / `2025–26`
- `year`: integer, JRFU calendar listing year or League One season start year. The inaugural League One season is `season="2022"`, `year=2022`, although the official schedule selector uses `year=2021`.
- `category`: source's category display label (League One: `リーグワン D1`, `リーグワン D2`, `リーグワン D3`, `リーグワン 入替戦`)
- `categories`: optional array of all observed category memberships, including `category`. Omission defaults to `[category]`; category searches use the `match_categories(matchID, category)` relation.
- `tournament`, `round`, `date` (YYYY-MM-DD), `kickoff` (string), `venue`, `homeTeam`, `awayTeam`: strings; unavailable optional text is empty
- `homeScore`, `awayScore`, `homeFirstHalfScore`, `awayFirstHalfScore`, `homeSecondHalfScore`, `awaySecondHalfScore`: nullable integers; never invent zero for missing
- `status`: `finished`, `scheduled`, `cancelled`, `unknown`
- `sourceURL`: canonical official match detail URL
- `officialRecordURL`: official printable/record URL if present, otherwise null
- `fetchedAt`: UTC ISO8601 string
- `detailLevel`: `full` (parsed official match details), `summary` (only schedule facts)
- `players`: array of {`side`: `home`/`away`, `number`: nullable integer, `name`: string, `position`: string, `role`: string}
- `scoreEvents`: array of {`period`: string, `time`: string, `side`: `home`/`away`/empty, `player`: string, `kind`: string, `homeScore`: nullable integer, `awayScore`: nullable integer}
- `substitutions`: array of {`side`: `home`/`away`, `period`: string, `time`: string, `outgoing`: string, `incoming`: string, `kind`: string}
  A source-recorded `退出` without a replacement has an empty `incoming`; do not invent a player.
- `stats`: array of {`label`: string, `home`: string, `away`: string}; only source supplied values

Coverage entries: {`source`, `season`, `category`, `scheduleURL`: strings, `discovered`, `imported`, `fullDetails`: integers}. Errors contain {`url`, `message`}. Collections must be deduplicated by source+match ID. Collectors preserve schedule-only entries when detail fetch/parsing fails, with explicit errors.

SQLite archive: `matches` table has the summary keys above through `detailLevel` as columns (except `sourceMatchID` optional to query), plus `payload` TEXT containing the complete record JSON. `metadata` table has `key` TEXT PRIMARY KEY, `value` TEXT. `manifest` key is JSON: {`schemaVersion`: 1, `generatedAt`: ISO8601, `coverage`: [...], `errors`: [...], `matchCount`: integer, `fullDetailCount`: integer}.

Bundled resource: `Rugby AS/OfficialRecords.sqlite`. Swift must use an independent read-only SQLite connection, never the user's SwiftData database. Search reads summary columns; details decode payload on demand. Importing into personal match records goes through a reviewed draft (`Rugby AS/OfficialRecordImport.swift`, `OfficialRecordImportView.swift`); the archive itself is never modified.

## World Rugby / Rugby World Cup

`source="rwc"` uses World Rugby's stable match UUID as `sourceMatchID` and
`rwc:<UUID>` as `id`. The public numeric/UUID match-page ID is retained in
`sourceURL`; `sourceEventID` identifies the official tournament. Men's and women's
15-a-side World Cup finals tournaments are included; qualifiers, sevens and future
editions are excluded. `year` and `season` mean the named edition: the women's
2021 edition has `year=2021` with actual match dates in 2022.

Optional fields used by overseas records:

- `kickoffUTC`: absolute kickoff in UTC; `date` and `kickoff` use the source's local
  GMT offset. Import uses UTC to avoid treating a UK kickoff as Japanese time.
- `omissions`: source limitations shown on the detail/import screens.
- `sourceStatus`, `sourceScores`: raw schedule status/scores. Cancelled fixtures
  have nullable public score fields even if the source assigns a 0–0 standings result.
- Score events may carry `points`, `matchSeconds`, `sourcePhase`. `T4`, `PT4` and
  `PT5` retain historical scoring; `PT` means the current seven-point penalty try.
  Incomplete scoring timelines retain events but clear cumulative/half scores.
  Extra-time scores are never labelled as a regulation second-half total.

The personal-record importer keeps normal `try` / `penalty_try` categories for
analysis. Non-current point values are stored per event in existing `widgetData`
(`RecordingEventDetails.officialPoints` + `officialScoringCategory`), so no
SwiftData schema change is required. Score calculations validate this pair; changing
the event category falls back to its normal points. Existing events without the
optional metadata keep today's scoring. Backups already preserve `widgetData`.
