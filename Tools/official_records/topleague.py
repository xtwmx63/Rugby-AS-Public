#!/usr/bin/env python3
"""Collect Japan Rugby Top League (2003-04 to 2020-21) facts from top-league.jp.

The Top League site is still online as an archive. Each season page lists its
competitions (league, cups, playoffs, Top Challenge, promotion/relegation,
exhibitions); each competition page lists its matches; each match page carries
the score breakdown, scoring/substitution timeline, line-ups and match facts.
The JRFU printable sheets it links to have expired, so they are not used.

Development-only (Beautiful Soup). Cached HTML stays outside the app. Requests
are serial with a pause, and HTTP 403/429 stops the run.
Run with --seasons 2020 2019 ... --cache DIR --output FILE.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time

from bs4 import BeautifulSoup

BASE = "https://www.top-league.jp"
SOURCE = "topleague"
KINDS = {"try": "T", "goal": "G", "gx": "Gx", "pg": "PG", "pgx": "PGx", "dg": "DG", "dgx": "DGx",
         "pt": "PT", "ptry": "PT", "penaltytry": "PT"}
CARDS = {"yellow": "イエローカード", "red": "レッドカード"}
# Disciplinary marks the site's legend does not explain; kept under their own names.
OTHER_MARKS = {"suspension", "accumulation", "reprimand"}
# Penalty tries were worth 5 (plus a conversion) until the 2017 law change.
LAST_FIVE_POINT_PENALTY_TRY_SEASON = 2016
POINTS = {"T": 5, "G": 2, "PT": 7, "PT5": 5, "PG": 3, "DG": 3}


def clean(value) -> str:
    if value is None:
        return ""
    text = value if isinstance(value, str) else value.get_text(" ")
    return re.sub(r"\s+", " ", text.replace("　", " ")).strip()


def integer(value):
    text = clean(value)
    return int(text) if re.fullmatch(r"\d+", text) else None


def stamp(path: Path) -> str:
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Fetcher:
    def __init__(self, cache: Path, delay=1.5, offline=False):
        self.cache, self.delay, self.offline = cache, max(1.0, delay), offline
        self.last = 0.0
        self.stopped = None
        cache.mkdir(parents=True, exist_ok=True)

    def get(self, path: str, name: str) -> tuple[str, str]:
        target = self.cache / name
        if target.exists() and "</html>" in target.read_text(encoding="utf-8", errors="replace").lower():
            return target.read_text(encoding="utf-8"), stamp(target)
        if self.offline:
            raise RuntimeError("Not present in local cache (offline mode)")
        if self.stopped:
            raise RuntimeError("Requests stopped: " + self.stopped)
        time.sleep(max(0, self.delay - (time.monotonic() - self.last)))
        partial = target.with_suffix(".partial")
        completed = subprocess.run(["curl", "--compressed", "--silent", "--show-error", "--connect-timeout", "15",
                                    "--max-time", "60", "--write-out", "%{http_code}", BASE + path, "-o", str(partial)],
                                   capture_output=True, text=True)
        self.last = time.monotonic()
        status = completed.stdout.strip()
        if status in ("403", "429"):
            self.stopped = f"HTTP {status} from {BASE + path}"
            partial.unlink(missing_ok=True)
            raise RuntimeError(self.stopped)
        if completed.returncode or status != "200":
            partial.unlink(missing_ok=True)
            raise RuntimeError(f"HTTP {status}: {clean(completed.stderr)}")
        html = partial.read_text(encoding="utf-8", errors="replace")
        if "</html>" not in html.lower():
            partial.unlink(missing_ok=True)
            raise RuntimeError("Incomplete HTML response")
        partial.replace(target)
        return html, stamp(target)


def season_label(start: int) -> str:
    return f"{start}–{str(start + 1)[2:]}"


def category(competition: str) -> str:
    if "入替戦" in competition:
        return "トップリーグ 入替戦"
    if "トップチャレンジ" in competition:
        return "トップチャレンジ"
    if re.search(r"オールスター|チャリティ|DREAM MATCH", competition, re.I):
        return "トップリーグ その他"
    return "トップリーグ"


def tournament_name(competition: str, start: int) -> str:
    # Names like "リーグ戦" need the season; "トップリーグ2021リーグ戦" already has it.
    if "トップリーグ" in competition and re.search(r"20\d\d", competition):
        return competition
    return f"ジャパンラグビートップリーグ{start}-{start + 1} {competition}"


def competitions(html: str) -> list[str]:
    ids = re.findall(r'href="/schedule/convention/(\d+)/"', html)
    return list(dict.fromkeys(ids))


def match_date(month_day: str, start: int) -> str:
    found = re.search(r"(\d{2})/(\d{2})", month_day)
    if not found:
        return ""
    month = int(found[1])
    # A season starts in late summer; January-July belong to the following year.
    year = start if month >= 8 else start + 1
    return f"{year}-{found[1]}-{found[2]}"


def parse_competition(html: str, start: int, fetched_at: str) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    section = soup.select_one("section.convention_list")
    if section is None:
        raise ValueError("Top League competition list was not found")
    heading = section.select_one("h2.hl2")
    competition = clean(heading)
    records = []
    for round_block in section.select("div.round"):
        round_name = clean(round_block.select_one(".round_title .name"))
        for row in round_block.select('tr[id^="game-"]'):
            game_id = row["id"].split("-", 1)[1]
            teams = row.select("td.teams div.team .name")
            if len(teams) != 2:
                raise ValueError(f"Incomplete game row {game_id}")
            detail = row.select_one('a[href^="/schedule/detail/"]')
            home, away = integer(row.select_one(".home.point")), integer(row.select_one(".away.point"))
            site = row.select_one("td.site a")
            audience = re.sub(r"\D", "", clean(row.select_one(".audience")))
            if detail is not None and home is not None and away is not None:
                status = "finished"
            elif re.search(r"中止|不成立", clean(row)):
                status = "cancelled"
            else:
                # The archive shows nothing for unplayed fixtures (e.g. the 2020 season); do not guess why.
                status = "unknown"
            record = dict(id=f"{SOURCE}:{game_id}", source=SOURCE, sourceMatchID=game_id,
                season=season_label(start), year=start, category=category(competition),
                categories=[category(competition)], tournament=tournament_name(competition, start),
                round=round_name, date=match_date(clean(row.select_one(".date .date")), start),
                kickoff=clean(row.select_one(".kickoff")),
                venue=(site.get("title") or clean(site)) if site else "",
                homeTeam=clean(teams[0]), awayTeam=clean(teams[1]), homeScore=home, awayScore=away,
                homeFirstHalfScore=None, awayFirstHalfScore=None, homeSecondHalfScore=None, awaySecondHalfScore=None,
                status=status, sourceURL=f"{BASE}/schedule/detail/{game_id}/", officialRecordURL=None,
                fetchedAt=fetched_at, detailLevel="summary", players=[], scoreEvents=[], substitutions=[],
                stats=[dict(label="観客数", home=audience, away=audience)] if audience else [])
            if status == "unknown":
                record["omissions"] = ["公式サイトの日程に結果・試合詳細の掲載がありません（中止等の事情は推測していません）"]
            record["_hasDetail"] = detail is not None
            records.append(record)
    if not records:
        raise ValueError(f"No matches in competition {competition}")
    return records


def parse_detail(html: str, summary: dict, fetched_at: str) -> dict:
    soup = BeautifulSoup(html, "html.parser")
    game = soup.select_one("section#game")
    if game is None or game.select_one("#score-timeline") is None:
        raise ValueError("Top League match detail was not found")
    record = dict(summary, fetchedAt=fetched_at, players=[], scoreEvents=[], substitutions=[],
                  stats=[s for s in summary["stats"] if s["label"] == "観客数"])
    record.pop("omissions", None)
    home, away = integer(game.select_one("#home-total-score")), integer(game.select_one("#away-total-score"))
    if home is not None and away is not None:
        record["homeScore"], record["awayScore"] = home, away
    for item in game.select("#score-detail li"):
        label = clean(item.select_one(".label"))
        values = [integer(x) for x in item.select(".score")]
        suffix = {"前半": "FirstHalfScore", "後半": "SecondHalfScore"}.get(label)
        if suffix and len(values) == 2:
            record["home" + suffix], record["away" + suffix] = values
        elif label and len(values) == 2:
            record["stats"].append(dict(label=f"{label} 得点", home=str(values[0] if values[0] is not None else ""),
                                        away=str(values[1] if values[1] is not None else "")))
    labels = []
    for row in game.select("#score-stats tr"):
        cells = row.find_all(["th", "td"], recursive=False)
        values = [clean(c) for c in cells]
        if len(cells) < 3 or len(cells) % 2 == 0:
            continue
        mid = len(cells) // 2
        if all(c.name == "th" for c in cells):
            labels = values[:mid]
            continue
        for index, label in enumerate(labels):
            if label in {"T", "G", "PT", "PG", "DG"} and values[mid]:
                record["stats"].append(dict(label=f"{values[mid]} {label}", home=values[index], away=values[mid + 1 + index]))
    for row in soup.select(".information table tr"):
        key, value = clean(row.find("th")), clean(row.find("td"))
        if key == "対戦日":
            found = re.search(r"(\d{4})/(\d{2})/(\d{2})", value)
            if found:
                record["date"] = f"{found[1]}-{found[2]}-{found[3]}"
        elif key == "Kick off" and value:
            record["kickoff"] = value
        elif key == "競技場" and value and not record["venue"]:
            # The schedule row carries the full ground name ("国立競技場"); this table often abbreviates it.
            record["venue"] = value
        elif key in ("天候", "グランド状態", "レフリー") and value:
            record["stats"].append(dict(label=key, home=value, away=value))
    for side in ("home", "away"):
        block = soup.select_one(f".member > div.{side}")
        if block is None:
            continue
        title = clean(block.find("h3"))
        if title:
            record[side + "Team"] = title
        for table in block.select("table"):
            reserve = "リザーブ" in clean(table.find("th"))
            position = ""
            for row in table.select("tr"):
                number, name = row.select_one("td.number"), row.select_one("td.name")
                if number is None or name is None or not clean(name):
                    continue
                if clean(row.select_one("td.position")):
                    position = clean(row.select_one("td.position"))
                record["players"].append(dict(side=side, number=integer(number), name=clean(name),
                    position="" if reserve else position, role="リザーブ" if reserve else "先発"))
    period, unknown = "前半", Counter()
    for row in soup.select("#score-timeline tr"):
        status = row.select_one("th.status")
        if status is None:
            continue
        half = status.select_one("p.half")
        if half is not None:
            text = clean(half)
            if "前半" in text and "終了" in text:
                period = "後半"
            elif "後半" in text and "終了" in text:
                period = "延長"
            continue
        time_text = clean(status.select_one("p.time")).replace("’", "").replace("'", "")
        scores = [integer(x) for x in status.select(".score")]
        for side in ("home", "away"):
            cell = row.select_one(f"td.{side}")
            if cell is None:
                continue
            classes = [c for c in cell.get("class", []) if c != side]
            if not classes:
                continue
            kind = classes[0]
            if kind == "change":
                outgoing, incoming = clean(cell.select_one("p.o")), clean(cell.select_one("p.i"))
                record["substitutions"].append(dict(side=side, period=period, time=time_text, kind="入替",
                                                    outgoing=outgoing, incoming=incoming))
            elif kind in KINDS:
                record["scoreEvents"].append(dict(period=period, time=time_text, side=side, player=clean(cell),
                    kind=KINDS[kind], homeScore=scores[0] if len(scores) == 2 else None,
                    awayScore=scores[1] if len(scores) == 2 else None))
            elif kind in CARDS or kind in OTHER_MARKS:
                label = CARDS.get(kind) or f"その他の記録（{kind}）"
                record["stats"].append(dict(label=f"{label} {period}{time_text}分" if time_text else f"{label} {period}",
                    home=clean(cell) if side == "home" else "", away=clean(cell) if side == "away" else ""))
            else:
                unknown[kind] += 1
    old_penalty_try(record)
    if unknown:
        record.setdefault("omissions", []).append(f"読み取れない経過の種類: {', '.join(f'{k}×{v}' for k, v in sorted(unknown.items()))}")
    if record["homeScore"] is not None and record["awayScore"] is not None and record["status"] != "cancelled":
        record["status"] = "finished"
    if record["players"] and record["status"] == "finished":
        record["detailLevel"] = "full"
    return record


def old_penalty_try(record):
    """Before 2017-18 a penalty try was 5 points. The site recomputes its running
    totals at 7, so they drift from the official final score; rebuild them."""
    if record["year"] > LAST_FIVE_POINT_PENALTY_TRY_SEASON or not any(e["kind"] == "PT" for e in record["scoreEvents"]):
        return
    events = [dict(e, kind="PT5") if e["kind"] == "PT" else dict(e) for e in record["scoreEvents"]]
    totals = {"home": 0, "away": 0}
    for event in events:
        totals[event["side"]] += POINTS.get(event["kind"], 0)
        event["homeScore"], event["awayScore"] = totals["home"], totals["away"]
    record["scoreEvents"] = [dict(e, kind="PT5") if e["kind"] == "PT" else e for e in record["scoreEvents"]]
    if (totals["home"], totals["away"]) == (record["homeScore"], record["awayScore"]):
        record["scoreEvents"] = events
        record.setdefault("omissions", []).append(
            "認定トライは当時のルール（5点＋ゴール）で記録。公式サイトの途中経過は7点で計算されているため、途中の累計得点は当時の点数で計算し直しています")
    else:
        record.setdefault("omissions", []).append("認定トライを含む得点経過の合計が公式の最終得点と一致しません（途中の累計得点は公式サイトの表示のまま）")


def collect(seasons, cache: Path, output: Path, offline=False, delay=1.5):
    fetcher = Fetcher(cache, delay, offline)
    previous = json.loads(output.read_text()) if output.exists() else {}
    matches = {m["id"]: m for m in previous.get("matches", [])}
    errors, coverage = {}, []
    for start in seasons:
        season_url = f"/schedule/{start}/"
        try:
            html, _ = fetcher.get(season_url, f"season-{start}.html")
        except Exception as error:
            errors[BASE + season_url] = dict(url=BASE + season_url, message=str(error))
            print(f"season {start} ERROR {error}", flush=True)
            continue
        summaries = []
        for competition in competitions(html):
            url = f"/schedule/convention/{competition}/"
            try:
                page, fetched_at = fetcher.get(url, f"convention-{competition}.html")
                summaries.extend(parse_competition(page, start, fetched_at))
            except Exception as error:
                errors[BASE + url] = dict(url=BASE + url, message=str(error))
                print(f"competition {competition} ERROR {error}", flush=True)
        print(f"season {start}: {len(summaries)} matches", flush=True)
        for index, summary in enumerate(summaries, 1):
            has_detail = summary.pop("_hasDetail")
            record = summary
            if has_detail:
                url = f"/schedule/detail/{summary['sourceMatchID']}/"
                try:
                    page, fetched_at = fetcher.get(url, f"detail-{summary['sourceMatchID']}.html")
                    record = parse_detail(page, summary, fetched_at)
                except Exception as error:
                    errors[BASE + url] = dict(url=BASE + url, message=str(error))
            matches[record["id"]] = record
            if index % 50 == 0 or index == len(summaries):
                print(f"season {start}: details {index}/{len(summaries)} errors={len(errors)}", flush=True)
        for name in sorted({s["category"] for s in summaries}):
            rows = [matches[s["id"]] for s in summaries if s["category"] == name]
            coverage.append(dict(source=SOURCE, season=season_label(start), category=name,
                                 scheduleURL=BASE + season_url, discovered=len(rows), imported=len(rows),
                                 fullDetails=sum(r["detailLevel"] == "full" for r in rows)))
        save(output, matches, coverage, previous, errors)
        if fetcher.stopped:
            break
    return matches, errors


def save(output: Path, matches, coverage, previous, errors):
    seasons = {c["season"] for c in coverage}
    kept = [c for c in previous.get("coverage", []) if c["season"] not in seasons]
    for record in matches.values():
        record.pop("_hasDetail", None)
    payload = dict(matches=sorted(matches.values(), key=lambda r: (r["date"], r["id"])),
                   coverage=sorted(kept + coverage, key=lambda c: (c["season"], c["category"])),
                   errors=list(errors.values()))
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    temporary.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seasons", type=int, nargs="+", required=True, help="Season start years, e.g. 2020 2019")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--delay", type=float, default=1.5)
    parser.add_argument("--offline", action="store_true", help="Reparse cached HTML without network requests")
    args = parser.parse_args()
    matches, errors = collect(args.seasons, args.cache, args.output, args.offline, args.delay)
    full = sum(m["detailLevel"] == "full" for m in matches.values())
    print(f"Exported {len(matches)} matches; {full} full details; {len(errors)} errors", flush=True)
    if errors:
        parser.exit(1, "Collection incomplete; cached pages are retained.\n")


if __name__ == "__main__":
    main()
