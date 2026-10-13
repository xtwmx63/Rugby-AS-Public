#!/usr/bin/env python3
"""Collect source-attributed League One match facts from its official schedule.

Requires beautifulsoup4. HTML stays in the caller's cache, never in the app.
Only two requests can run concurrently; cached pages are reused unless refreshed.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin

from bs4 import BeautifulSoup

BASE = "https://league-one.jp"
_request_lock = threading.Lock()
_blocked = threading.Event()
_last_request = 0.0
_block_reason = ""
_offline = False


def request_slot():
    """One start per second for the whole host, including retries."""
    global _last_request
    with _request_lock:
        if _blocked.is_set():
            raise RuntimeError(f"Host requests paused: {_block_reason}")
        delay = max(0.0, 1.0 - (time.monotonic() - _last_request))
        if delay:
            time.sleep(delay)
        if _blocked.is_set():
            raise RuntimeError(f"Host requests paused: {_block_reason}")
        _last_request = time.monotonic()


def clean(value) -> str:
    if value is None:
        return ""
    if hasattr(value, "get_text"):
        value = value.get_text(" ", strip=True)
    return re.sub(r"\s+", " ", str(value)).strip()


def integer(value):
    value = clean(value)
    return int(value) if re.fullmatch(r"\d+", value) else None


def timestamp(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat()


def fetch(url: str, path: Path, refresh=False) -> tuple[str, str]:
    global _block_reason
    if path.exists() and not refresh:
        html = path.read_text(encoding="utf-8")
        if "</html>" in html.lower():
            return html, timestamp(path)
    if _offline:
        raise RuntimeError("Not present in local cache (offline mode)")
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(".part")
    headers_path = path.with_suffix(".headers.part")
    try:
        for attempt in range(3):
            request_slot()
            response = subprocess.run(
                ["curl", "-L", "--fail", "--compressed", "--silent", "--show-error",
                 "--connect-timeout", "20", "--max-time", "90",
                 "--dump-header", str(headers_path), "--write-out", "%{http_code}",
                 url, "-o", str(partial)], capture_output=True, text=True,
            )
            status = response.stdout.strip()
            if status == "429":
                headers = headers_path.read_text() if headers_path.exists() else ""
                retry_after = re.search(r"(?im)^retry-after:\s*(.+)$", headers)
                _block_reason = "HTTP 429; Retry-After=" + (retry_after[1].strip() if retry_after else "unspecified")
                # Stop this run, including queued requests. Never retry ahead of
                # the server's requested cooldown; the cached summaries survive.
                _blocked.set()
                raise RuntimeError(_block_reason)
            if response.returncode == 0:
                break
            if response.returncode in (5, 6):
                _block_reason = response.stderr.strip()
                _blocked.set()
                raise RuntimeError(_block_reason)
            if attempt == 2 or (status.startswith("4") and status != "408"):
                raise RuntimeError(response.stderr.strip() or f"HTTP {status}")
            time.sleep(2 ** (attempt + 1))
        html = partial.read_text(encoding="utf-8")
        if "<html" not in html.lower() or "</html>" not in html.lower():
            raise ValueError("Response is not a complete HTML page")
        partial.replace(path)
        return html, timestamp(path)
    finally:
        partial.unlink(missing_ok=True)
        headers_path.unlink(missing_ok=True)


def category(tournament: str) -> str:
    if "入替戦" in tournament:
        return "リーグワン 入替戦"
    if "プレーオフ" in tournament:
        return "リーグワン D1"
    division = re.search(r"ディビジョン\s*([123])", tournament)
    if not division:
        raise ValueError(f"Unrecognized League One competition: {tournament}")
    return f"リーグワン D{division[1]}"


def season_label(year: int) -> str:
    # The official selector uses year=2021 for the inaugural, calendar-2022 season.
    return "2022" if year == 2021 else f"{year}–{str(year + 1)[2:]}"


def schedule_date(block, round_text: str, match_id: str) -> str:
    date_parts = re.search(r"(\d{2})\.(\d{2})", clean(block.select_one(".date")))
    if not date_parts:
        raise ValueError(f"Cannot determine calendar date for {match_id}")
    month_day = f"{date_parts[1]}-{date_parts[2]}"
    code = re.search(r"\((\d{4})[^)]*\)", round_text)
    if code:
        match_date = f"{code[1]}-{month_day}"
        datetime.strptime(match_date, "%Y-%m-%d")
        return match_date
    # Older match codes (D1-M97 etc.) have no year. Use the round's explicit
    # date range, not an assumed month at which the season changes year.
    heading = block.find_previous("h2")
    bounds = re.findall(r"\d{4}\.\d{2}\.\d{2}", clean(heading))
    if bounds:
        start, end = bounds[0].replace(".", "-"), bounds[-1].replace(".", "-")
        candidates = [f"{year}-{month_day}" for year in range(int(start[:4]), int(end[:4]) + 1)
                      if start <= f"{year}-{month_day}" <= end]
        if len(candidates) == 1:
            datetime.strptime(candidates[0], "%Y-%m-%d")
            return candidates[0]
    raise ValueError(f"Cannot determine calendar date for {match_id}")


def parse_schedule(html: str, year: int, fetched_at: str) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    matches = {}
    for block in soup.select(".c-schedule"):
        anchor = block.select_one('a.btn-match-detail[href]')
        if anchor is None:
            raise ValueError("Schedule block has no match detail link")
        identifier = re.search(r"/match/(\d+)", anchor["href"])
        if not identifier:
            raise ValueError(f"Invalid match link: {anchor['href']}")
        match_id = identifier[1]
        title = block.select_one(".ttl")
        lines = [clean(item) for item in title.stripped_strings]
        tournament = lines[0]
        round_text = " ".join(lines[1:])
        match_date = schedule_date(block, round_text, match_id)
        home_score = integer(block.select_one(".game .home .score"))
        away_score = integer(block.select_one(".game .away .score"))
        status_text = clean(anchor)
        status = ("cancelled" if any(word in status_text for word in ("中止", "不成立"))
                  else "finished" if "試合終了" in status_text
                  else "scheduled" if home_score is None and away_score is None
                  else "unknown")
        matches[match_id] = {
            "id": f"leagueone:{match_id}", "source": "leagueone",
            "sourceMatchID": match_id, "season": season_label(year),
            "year": 2022 if year == 2021 else year, "category": category(tournament),
            "tournament": tournament,
            "round": re.sub(r"\s*\([^)]*\)\s*$", "", round_text),
            "date": match_date, "kickoff": clean(block.select_one(".time")),
            "venue": clean(block.select_one(".place")),
            "homeTeam": clean(block.select_one(".game .home .name.only-pc")),
            "awayTeam": clean(block.select_one(".game .away .name.only-pc")),
            "homeScore": home_score, "awayScore": away_score,
            "homeFirstHalfScore": None, "awayFirstHalfScore": None,
            "homeSecondHalfScore": None, "awaySecondHalfScore": None,
            "status": status, "sourceURL": urljoin(BASE, anchor["href"]),
            "officialRecordURL": None, "fetchedAt": fetched_at,
            "detailLevel": "summary", "players": [], "scoreEvents": [],
            "substitutions": [], "stats": [],
            "_aliases": {side: clean(block.select_one(f".game .{side} .name.only-sp"))
                         for side in ("home", "away")},
        }
    if not matches:
        raise ValueError("No League One matches found in schedule")
    return list(matches.values())


def split_time(text: str) -> tuple[str, str]:
    match = re.match(r"^(前半|後半|延長前半|延長後半)\s*(.*)$", text)
    return (match[1], match[2]) if match else ("", text)


def substitution_numbers(kind: str, numbers: str) -> tuple[int | None, int | None]:
    pair = re.fullmatch(r"(\d+)\s*→\s*(\d+)", numbers)
    if pair:
        return tuple(map(int, pair.groups()))
    # Official records include leaving the field without a replacement.
    if kind == "退出" and numbers.isdigit():
        return int(numbers), None
    raise ValueError(f"Unrecognized substitution: {kind} {numbers}")


def parse_print(html: str, summary: dict, fetched_at: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    if not soup.select_one("#info .info1") or not soup.select_one("#team .team.home"):
        raise ValueError("Official print page is missing match information/roster")
    result = copy.deepcopy(summary)
    aliases = result.pop("_aliases", {})
    for row in soup.select("#info .info1 tr"):
        cells = row.find_all(["th", "td"], recursive=False)
        for index, cell in enumerate(cells[:-1]):
            if cell.name != "th" or cells[index + 1].name != "td":
                continue
            label, value = clean(cell), clean(cells[index + 1])
            if label == "対戦日":
                date = re.search(r"\d{4}/\d{2}/\d{2}", value)
                if date:
                    result["date"] = date[0].replace("/", "-")
            elif label == "Kick off":
                result["kickoff"] = value
            elif label == "競技場":
                result["venue"] = value
    players_by_side = {}
    for side in ("home", "away"):
        table = soup.select_one(f"#team .team.{side} table")
        if not table:
            raise ValueError(f"Missing {side} roster")
        result[side + "Team"] = clean(table.select_one("th.title")) or result[side + "Team"]
        players_by_side[side] = {}
        remaining_position_rows, position = 0, ""
        for row in table.select("tr"):
            name_cell, number_cell = row.select_one("td.name"), row.select_one("td.num")
            if name_cell is None:
                continue
            position_cell = row.select_one("td.pos")
            if position_cell:
                position = clean(position_cell)
                remaining_position_rows = int(position_cell.get("rowspan", "1"))
            elif remaining_position_rows <= 0:
                position = ""
            remaining_position_rows -= 1
            number = integer(number_cell)
            # Discard physical measurements; retain only the match roster name.
            name = re.sub(r"[（(]\s*\d+\s*/.*?[）)]\s*$", "", clean(name_cell)).strip()
            if not name:
                continue
            role = "リザーブ" if position == "Re." else "先発" if position else ""
            if number_cell and "cap" in number_cell.get("class", []):
                role = f"{role}・キャプテン" if role else "キャプテン"
            result["players"].append({"side": side, "number": number, "name": name,
                                      "position": "" if position == "Re." else position,
                                      "role": role})
            players_by_side[side][number] = name
    for row in soup.select("table.score tr"):
        label = clean(row.select_one("th.tp"))
        values = [clean(cell) for cell in row.find_all("td", recursive=False)]
        if label == "計" and len(values) == 4:
            for key, value in zip(("homeFirstHalfScore", "homeSecondHalfScore",
                                   "awayFirstHalfScore", "awaySecondHalfScore"), values):
                result[key] = integer(value)
        elif label == "合計" and len(values) == 2:
            result["homeScore"], result["awayScore"] = map(integer, values)
        elif label in ("T", "G", "PT", "PG", "DG") and len(values) == 4:
            for period, offset in (("前半", 0), ("後半", 1)):
                result["stats"].append({"label": f"{period} {label}",
                                        "home": values[offset], "away": values[offset + 2]})
    for row in soup.select("table.foul tr"):
        label = clean(row.select_one("th.tp"))
        values = [clean(cell) for cell in row.find_all("td", recursive=False)]
        if label and len(values) == 4:
            for kind, offset in (("PK", 0), ("FK", 1)):
                result["stats"].append({"label": f"{label} {kind}",
                                        "home": values[offset], "away": values[offset + 2]})
    for side in ("home", "away"):
        for group, temporary in (("change", False), ("tmpchange", True)):
            for row in soup.select(f"div.{side}.{group} table tr"):
                cells = [clean(cell) for cell in row.find_all("td", recursive=False)]
                if len(cells) != 3:
                    continue
                if temporary:
                    time_text, numbers, content = cells
                    kind = "一時交替" + (f"（{content}）" if content else "")
                else:
                    kind, time_text, numbers = cells
                outgoing, incoming = substitution_numbers(kind, numbers)
                period, event_time = split_time(time_text)
                def player_label(number):
                    if number is None:
                        return ""
                    name = players_by_side[side].get(number, "")
                    return f"{number}. {name}".strip()
                result["substitutions"].append({
                    "side": side, "period": period, "time": event_time,
                    "outgoing": player_label(outgoing), "incoming": player_label(incoming),
                    "kind": kind,
                })
    # The printable table can continue across columns, with a new period header
    # halfway through either table. Process headers and rows in document order.
    period = ""
    for table in soup.select("#score table"):
        for row in table.select("tr"):
            headers = row.find_all("th", recursive=False)
            if headers:
                period = clean(headers[0])
                continue
            cells = [clean(cell) for cell in row.find_all("td", recursive=False)]
            if len(cells) != 7:
                continue
            event_time, team, player, kind, home, _, away = cells
            side = next((side for side in ("home", "away")
                         if team and team in (aliases.get(side), result[side + "Team"])), "")
            if not side:
                player_name = re.sub(r"^\d+\s*[.．]\s*", "", player)
                candidates = [side for side in ("home", "away")
                              if player_name and player_name in players_by_side[side].values()]
                if len(candidates) == 1:
                    side = candidates[0]
            result["scoreEvents"].append({
                "period": period, "time": event_time, "side": side,
                "player": player, "kind": kind,
                "homeScore": integer(home), "awayScore": integer(away),
            })
    if not result["players"]:
        raise ValueError("Official print page has no roster entries")
    result.update(officialRecordURL=summary["sourceURL"] + "/print",
                  fetchedAt=fetched_at, detailLevel="full")
    return result


def collect(year: int, cache: Path, output: Path, refresh=False, limit=None) -> dict:
    schedule_url = f"{BASE}/schedule/?year={year}"
    html, fetched_at = fetch(schedule_url, cache / f"league-schedule-{year}.html", refresh)
    summaries = parse_schedule(html, year, fetched_at)
    if limit:
        summaries = summaries[:limit]
    print(f"Discovered {len(summaries)} League One matches", flush=True)
    errors, matches = [], []

    def enrich(summary):
        if summary["status"] == "cancelled":
            result = copy.deepcopy(summary)
            result.pop("_aliases", None)
            return result, None
        url = summary["sourceURL"] + "/print"
        try:
            html, fetched_at = fetch(url, cache / f"league-print-{summary['sourceMatchID']}.html", refresh)
            return parse_print(html, summary, fetched_at), None
        except Exception as error:
            result = copy.deepcopy(summary)
            result.pop("_aliases", None)
            return result, {"url": url, "message": str(error)}

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(enrich, summary) for summary in summaries]
        for index, future in enumerate(as_completed(futures), 1):
            match, error = future.result()
            matches.append(match)
            if error:
                errors.append(error)
                print(f"ERROR {error['url']}: {error['message']}", flush=True)
            if index % 20 == 0 or index == len(summaries):
                print(f"Parsed {index}/{len(summaries)} ({len(errors)} errors)", flush=True)
    matches.sort(key=lambda match: (match["date"], match["id"]))
    discovered = Counter(match["category"] for match in summaries)
    imported = Counter(match["category"] for match in matches)
    full = Counter(match["category"] for match in matches if match["detailLevel"] == "full")
    coverage = [{"source": "leagueone", "season": season_label(year),
                 "category": category, "scheduleURL": schedule_url, "discovered": count,
                 "imported": imported[category], "fullDetails": full[category]}
                for category, count in sorted(discovered.items())]
    payload = {"matches": matches, "coverage": coverage, "errors": errors}
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)
    print(json.dumps({"output": str(output), "coverage": coverage, "errors": len(errors)},
                     ensure_ascii=False), flush=True)
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--year", type=int, default=2025)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--offline", action="store_true", help="Reparse cached HTML without any network requests")
    parser.add_argument("--limit", type=int, help="Development-only cap on match count")
    args = parser.parse_args()
    _offline = args.offline
    collect(args.year, args.cache, args.output, args.refresh, args.limit)
    if _blocked.is_set():
        parser.exit(1, f"Host requests paused: {_block_reason}\n")
