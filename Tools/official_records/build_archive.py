#!/usr/bin/env python3
"""Validate collector JSON and atomically assemble the bundled official archive.

Usage:
  python3 Tools/official_records/build_archive.py \
    --input jrfu.json --input leagueone.json --output 'Rugby AS/OfficialRecords.sqlite'

No network access or third-party dependencies are needed. Existing output is only
replaced after the complete new database passes SQLite integrity checks. Repeated
source IDs keep a full record over a summary, then the latest fetchedAt version.
"""

import argparse
from datetime import date, datetime, timezone
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
from urllib.parse import urlparse


TEXT_COLUMNS = (
    "id", "source", "sourceMatchID", "season", "category", "tournament", "round",
    "date", "kickoff", "venue", "homeTeam", "awayTeam", "status", "sourceURL",
    "fetchedAt", "detailLevel",
)
SCORE_COLUMNS = (
    "homeScore", "awayScore", "homeFirstHalfScore", "awayFirstHalfScore",
    "homeSecondHalfScore", "awaySecondHalfScore",
)
SUMMARY_COLUMNS = TEXT_COLUMNS + ("year",) + SCORE_COLUMNS + ("officialRecordURL",)
CHILD_FIELDS = {
    "players": ("side", "number", "name", "position", "role"),
    "scoreEvents": ("period", "time", "side", "player", "kind", "homeScore", "awayScore"),
    "substitutions": ("side", "period", "time", "outgoing", "incoming", "kind"),
    "stats": ("label", "home", "away"),
}
CHILD_TABLES = {"players": "players", "scoreEvents": "score_events", "substitutions": "substitutions", "stats": "statistics"}
SOURCE_HOSTS = {
    "rwc": ("world.rugby", "rugbyworldcup.com", "api.wr-rims-prod.pulselive.com"),
    "jrfu": ("rugby-japan.jp",),
    "leagueone": ("league-one.jp",),
    "topleague": ("top-league.jp",),
    "svns": ("svns.com", "world.rugby", "api.wr-rims-prod.pulselive.com"),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nullable_integer(value, context):
    require(value is None or (type(value) is int and value >= 0), context + " must be a nonnegative integer or null")


def timestamp(value, context):
    require(isinstance(value, str), context + " must be an ISO8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError(context + " must be an ISO8601 timestamp") from error
    require(parsed.tzinfo is not None and parsed.utcoffset().total_seconds() == 0, context + " must be UTC")
    return parsed


def official_url(value, source, context):
    require(isinstance(value, str), context + " must be a URL string")
    parsed = urlparse(value)
    host = (parsed.hostname or "").lower()
    require(parsed.scheme in ("https", "http") and any(host == suffix or host.endswith("." + suffix)
            for suffix in SOURCE_HOSTS.get(source, ())),
            context + " must point to the stated official source")


def validate_match(record, context):
    require(isinstance(record, dict), context + " must be an object")
    for field in TEXT_COLUMNS:
        require(isinstance(record.get(field), str), f"{context}.{field} must be a string")
    require(record["source"] in SOURCE_HOSTS, context + ".source is unsupported")
    require(bool(record["sourceMatchID"]) and record["id"] == record["source"] + ":" + record["sourceMatchID"],
            context + ".id must match source:sourceMatchID")
    require(type(record.get("year")) is int, context + ".year must be an integer")
    require(record["status"] in ("finished", "scheduled", "cancelled", "unknown"), context + ".status is unsupported")
    require(record["detailLevel"] in ("full", "summary"), context + ".detailLevel is unsupported")
    memberships = record.get("categories", [record["category"]])
    require(isinstance(memberships, list) and bool(memberships), context + ".categories must be a nonempty array")
    require(all(isinstance(value, str) and bool(value.strip()) for value in memberships),
            context + ".categories must contain nonempty strings")
    require(len(memberships) == len(set(memberships)), context + ".categories must not contain duplicates")
    require(record["category"] in memberships, context + ".categories must include the primary category")
    if record["date"]:
        require(bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", record["date"])), context + ".date must use YYYY-MM-DD")
        try:
            date.fromisoformat(record["date"])
        except ValueError as error:
            raise ValueError(context + ".date is not a valid calendar date") from error
    for field in SCORE_COLUMNS:
        require(field in record, f"{context}.{field} is missing; use null for an unknown score")
        nullable_integer(record[field], f"{context}.{field}")
    official_url(record["sourceURL"], record["source"], context + ".sourceURL")
    require("officialRecordURL" in record, context + ".officialRecordURL is missing; use null if unavailable")
    if record["officialRecordURL"] is not None:
        official_url(record["officialRecordURL"], record["source"], context + ".officialRecordURL")
    timestamp(record["fetchedAt"], context + ".fetchedAt")
    for collection, fields in CHILD_FIELDS.items():
        rows = record.get(collection)
        require(isinstance(rows, list), f"{context}.{collection} must be an array")
        for index, row in enumerate(rows):
            label = f"{context}.{collection}[{index}]"
            require(isinstance(row, dict), label + " must be an object")
            for field in fields:
                require(field in row, f"{label}.{field} is missing")
                if field in ("number", "homeScore", "awayScore"):
                    nullable_integer(row[field], f"{label}.{field}")
                else:
                    require(isinstance(row[field], str), f"{label}.{field} must be a string")
            if "side" in row:
                allowed = ("home", "away", "") if collection == "scoreEvents" else ("home", "away")
                require(row["side"] in allowed, label + ".side is unsupported")


def validate_coverage(entry, context):
    require(isinstance(entry, dict), context + " must be an object")
    for field in ("source", "season", "category", "scheduleURL"):
        require(isinstance(entry.get(field), str), f"{context}.{field} must be a string")
    require(entry["source"] in SOURCE_HOSTS, context + ".source is unsupported")
    official_url(entry["scheduleURL"], entry["source"], context + ".scheduleURL")
    for field in ("discovered", "imported", "fullDetails"):
        require(type(entry.get(field)) is int and entry[field] >= 0, f"{context}.{field} must be a nonnegative integer")
    require(entry["fullDetails"] <= entry["imported"] <= entry["discovered"], context + " has inconsistent counts")


def json_text(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)


def load_inputs(paths):
    matches, coverage, errors = {}, {}, {}
    duplicate_count = 0
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        require(isinstance(data, dict), str(path) + " must contain a JSON object")
        for key in ("matches", "coverage", "errors"):
            require(isinstance(data.get(key), list), f"{path}: {key} must be an array")
        for index, record in enumerate(data["matches"]):
            validate_match(record, f"{path}: matches[{index}]")
            record = dict(record, categories=list(record.get("categories", [record["category"]])))
            previous = matches.get(record["id"])
            if previous is None:
                matches[record["id"]] = record
            else:
                duplicate_count += 1
                def rank(row):
                    return (row["detailLevel"] == "full", timestamp(row["fetchedAt"], "fetchedAt"),
                            sum(len(row[key]) for key in CHILD_FIELDS))
                if rank(record) >= rank(previous):
                    matches[record["id"]] = record
                chosen = matches[record["id"]]
                memberships = set(previous["categories"]) | set(record["categories"])
                chosen["categories"] = [chosen["category"]] + sorted(memberships - {chosen["category"]})
        for index, entry in enumerate(data["coverage"]):
            validate_coverage(entry, f"{path}: coverage[{index}]")
            key = tuple(entry[field] for field in ("source", "season", "category", "scheduleURL"))
            if key in coverage:
                # Re-running the same input must not double a coverage count.
                for field in ("discovered", "imported", "fullDetails"):
                    coverage[key][field] = max(coverage[key][field], entry[field])
            else:
                coverage[key] = dict(entry)
        for index, error in enumerate(data["errors"]):
            require(isinstance(error, dict) and all(isinstance(error.get(field), str) for field in ("url", "message")),
                    f"{path}: errors[{index}] must have string url and message")
            errors[(error["url"], error["message"])] = {"url": error["url"], "message": error["message"]}
    require(bool(matches), "No matches found; refusing to replace the archive with an empty database")
    return list(matches.values()), [coverage[key] for key in sorted(coverage)], list(errors.values()), duplicate_count


def assemble(inputs, output, detail_tables=False):
    require(all(path.resolve() != output.resolve() for path in inputs), "The output cannot overwrite a collector input")
    matches, coverage, errors, duplicate_count = load_inputs(inputs)
    matches.sort(key=lambda row: row["id"])
    manifest = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "coverage": coverage,
        "errors": errors,
        "matchCount": len(matches),
        "fullDetailCount": sum(row["detailLevel"] == "full" for row in matches),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=output.parent)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        connection = sqlite3.connect(temporary)
        try:
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA journal_mode = DELETE")
            connection.execute("PRAGMA user_version = 1")
            declarations = ["id TEXT PRIMARY KEY NOT NULL"] + [f'"{field}" TEXT NOT NULL' for field in TEXT_COLUMNS if field != "id"]
            declarations += ["year INTEGER NOT NULL"] + [f'"{field}" INTEGER' for field in SCORE_COLUMNS]
            declarations += ["officialRecordURL TEXT", "payload TEXT NOT NULL"]
            connection.execute("CREATE TABLE matches (" + ",".join(declarations) + ")")
            connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            connection.execute("CREATE TABLE match_categories (matchID TEXT NOT NULL REFERENCES matches(id), category TEXT NOT NULL, PRIMARY KEY(matchID, category))")
            connection.execute("CREATE INDEX match_categories_category ON match_categories(category, matchID)")
            connection.execute("CREATE INDEX matches_recent ON matches(date DESC, kickoff DESC, id)")
            connection.execute("CREATE INDEX matches_scope ON matches(source, year, category, date DESC)")
            connection.execute("CREATE INDEX matches_category ON matches(category, date DESC)")
            connection.execute("CREATE INDEX matches_season ON matches(season, date DESC)")
            connection.execute("CREATE INDEX matches_tournament ON matches(tournament, date DESC)")
            # The app reads only matches/match_categories/metadata and decodes details from payload.
            # The per-row detail tables duplicate payload, so they are built only on request.
            child_fields = CHILD_FIELDS if detail_tables else {}
            for collection, fields in child_fields.items():
                columns = ["match_id TEXT NOT NULL REFERENCES matches(id)", "ordinal INTEGER NOT NULL"]
                columns += [f'"{field}" INTEGER' if field in ("number", "homeScore", "awayScore") else f'"{field}" TEXT NOT NULL' for field in fields]
                columns += ["PRIMARY KEY(match_id, ordinal)"]
                connection.execute(f"CREATE TABLE {CHILD_TABLES[collection]} (" + ",".join(columns) + ")")
            names = SUMMARY_COLUMNS + ("payload",)
            placeholders = ",".join("?" for _ in names)
            insert_sql = "INSERT INTO matches (" + ",".join('"' + field + '"' for field in names) + ") VALUES (" + placeholders + ")"
            with connection:
                for match in matches:
                    connection.execute(insert_sql, [match[field] for field in SUMMARY_COLUMNS] + [json_text(match)])
                    connection.executemany("INSERT INTO match_categories VALUES (?, ?)",
                        [(match["id"], category) for category in match["categories"]])
                    for collection, fields in child_fields.items():
                        placeholders = ",".join("?" for _ in range(len(fields) + 2))
                        connection.executemany(f"INSERT INTO {CHILD_TABLES[collection]} VALUES ({placeholders})",
                            [(match["id"], index, *(row[field] for field in fields)) for index, row in enumerate(match[collection])])
                connection.execute("INSERT INTO metadata VALUES ('manifest', ?)", (json_text(manifest),))
            require(connection.execute("PRAGMA integrity_check").fetchone() == ("ok",), "SQLite integrity check failed")
            require(connection.execute("PRAGMA foreign_key_check").fetchall() == [], "SQLite foreign key check failed")
        finally:
            connection.close()
        temporary.chmod(0o644)
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"Built {output}: {len(matches)} matches, {manifest['fullDetailCount']} details, {len(coverage)} coverage entries, {len(errors)} source errors; deduplicated {duplicate_count} IDs")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, action="append", required=True, help="Collector JSON; repeat for each source")
    parser.add_argument("--output", type=Path, required=True, help="Path to the SQLite archive")
    parser.add_argument("--detail-tables", action="store_true",
                        help="Also build players/score_events/substitutions/statistics tables for external analysis (not used by the app)")
    args = parser.parse_args()
    try:
        assemble(args.input, args.output, args.detail_tables)
    except (ValueError, OSError, sqlite3.Error) as error:
        parser.exit(1, f"Archive build failed: {error}\n")


if __name__ == "__main__":
    main()
