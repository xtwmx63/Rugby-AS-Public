#!/usr/bin/env python3
"""Collect structured JRFU facts for explicitly selected calendar years.

Uses only Python's standard library and curl. Cached HTML is local input, never
bundled in the app. No player profiles, photographs or narrative reports are
downloaded. Run with --years 2025 2026 --cache DIR --output FILE.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.parse import urljoin

BASE = "https://www.rugby-japan.jp"

# Broad schedule indexes deliberately repeat more specific categories. A stable
# primary category prevents asynchronous download order from changing searches.
CATEGORY_PRIORITY = {"その他": 0, "セブンズ": 10, "大学": 20, "高校": 20, "中学": 20,
    "高専": 20, "女子": 20, "U20日本代表": 30, "U23日本代表": 30,
    "15人制男子日本代表": 30, "15人制女子日本代表": 30, "男子セブンズ日本代表": 30,
    "女子セブンズ日本代表": 30, "JAPAN_XV": 30}


def preferred_summary(previous, candidate):
    if previous is None:
        return candidate
    key = lambda record: (CATEGORY_PRIORITY.get(record["category"], 20), record["category"])
    chosen = candidate if key(candidate) > key(previous) else previous
    memberships = set(previous.get("categories", [previous["category"]])) | set(candidate.get("categories", [candidate["category"]]))
    return dict(chosen, categories=sorted(memberships))


def clean(value):
    return re.sub(r"\s+", " ", value).strip()


class Node:
    def __init__(self, tag="root", attrs=(), parent=None):
        self.tag, self.attrs, self.parent = tag, dict(attrs), parent
        self.children = []

    def text(self, direct=False):
        return clean("".join(c if isinstance(c, str) else ("" if direct else c.text() + " ") for c in self.children))

    def has(self, cls):
        return cls in self.attrs.get("class", "").split()

    def findall(self, tag=None, cls=None, id=None):
        found = []
        for node in self.children:
            if isinstance(node, str):
                continue
            if (tag is None or node.tag == tag) and (cls is None or node.has(cls)) and (id is None or node.attrs.get("id") == id):
                found.append(node)
            found.extend(node.findall(tag, cls, id))
        return found

    def find(self, tag=None, cls=None, id=None):
        return next(iter(self.findall(tag, cls, id)), Node())


class Tree(HTMLParser):
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.root = self.current = Node()
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        # JRFU's display pages occasionally omit cell closing tags.
        if tag in {"td", "th"} and self.current.tag in {"td", "th"}:
            self.current = self.current.parent
        if tag == "tr":
            ancestor = self.current
            while ancestor.parent and ancestor.tag not in {"tr", "table"}:
                ancestor = ancestor.parent
            if ancestor.tag == "tr":
                self.current = ancestor.parent
        node = Node(tag, attrs, self.current)
        self.current.children.append(node)
        if tag not in self.VOID:
            self.current = node

    def handle_endtag(self, tag):
        ancestor = self.current
        while ancestor.parent and ancestor.tag != tag:
            ancestor = ancestor.parent
        if ancestor.parent:
            self.current = ancestor.parent

    def handle_data(self, text):
        self.current.children.append(text)


def integer(value):
    value = clean(value)
    return int(value) if re.fullmatch(r"\d+", value) else None


def cells(row):
    return [c for c in row.children if isinstance(c, Node) and c.tag in {"td", "th"}]


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def fetched_stamp(path):
    return datetime.fromtimestamp(Path(path).stat().st_mtime, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def categories(html):
    result = {}
    for option in Tree(html).root.findall("option"):
        url = option.attrs.get("value", "")
        if re.fullmatch(r"/schedule/[a-z0-9-]+", url):
            result[url.rsplit("/", 1)[1]] = option.text()
    if not result:
        raise ValueError("JRFU category selector was not found")
    return result


def parse_schedule(html, year, category, fetched_at=None):
    root = Tree(html).root
    records = []
    for card in root.findall(cls="game-card"):
        link = next((a for a in card.findall("a") if re.fullmatch(r"/match/\d+", a.attrs.get("href", ""))), None)
        if link is None:
            continue
        match_id = link.attrs["href"].split("/")[-1]
        raw_date = card.find(cls="date").text()
        md = re.search(r"(\d{1,2})[./](\d{1,2})", raw_date)
        scores = card.find(cls="scoreboard").findall(cls="score")
        home_score = integer(scores[0].text()) if scores else None
        away_score = integer(scores[1].text()) if len(scores) > 1 else None
        home = card.find(cls="home").find(cls="name").text()
        away = card.find(cls="away").find(cls="name").text()
        record = dict(id="jrfu:" + match_id, source="jrfu", sourceMatchID=match_id,
            season=str(year), year=year, category=category, categories=[category],
            tournament=card.find(cls="headline").text(), round="",
            date=f"{year}-{int(md[1]):02}-{int(md[2]):02}" if md else "",
            kickoff=card.find(cls="start").text(), venue=card.find(cls="stadium").text(),
            homeTeam=home, awayTeam=away, homeScore=home_score, awayScore=away_score,
            homeFirstHalfScore=None, awayFirstHalfScore=None, homeSecondHalfScore=None, awaySecondHalfScore=None,
            status="finished" if home_score is not None and away_score is not None else "scheduled",
            sourceURL=BASE + link.attrs["href"], officialRecordURL=None,
            fetchedAt=fetched_at or stamp(), detailLevel="summary", players=[], scoreEvents=[], substitutions=[], stats=[])
        if re.search(r"中止|延期|不成立", card.text()):
            record["status"] = "cancelled"
        if not home or not away or not md:
            raise ValueError(f"Incomplete schedule card for {match_id}")
        records.append(record)
    # Distinguish legitimate empty categories from changed markup.
    if not root.findall(cls="game-schedule"):
        raise ValueError("JRFU schedule container was not found")
    return records


def period_time(value):
    match = re.match(r"(延長前半|延長後半|前半|後半)(.*)", value)
    return (match[1], match[2].strip()) if match else ("", value)


def parse_print(html, summary, fetched_at=None):
    root = Tree(html).root
    if "コンテンツの掲載期間が終了しました" in root.find("title").text():
        raise ValueError(EXPIRED_NOTE)
    team_section = root.find(id="team")
    if not team_section.children or not root.find(id="info").children:
        raise ValueError("JRFU official record tables were not found")
    record = dict(summary)
    record.update(players=[], scoreEvents=[], substitutions=[], stats=[],
                  officialRecordURL=summary["sourceURL"] + "/print", fetchedAt=fetched_at or stamp(), detailLevel="full")
    title = root.find("header").find("h2").text()
    if title:
        record["tournament"] = title
    for row in root.find(id="info").findall("tr"):
        row_cells = cells(row)
        for index, cell in enumerate(row_cells[:-1]):
            if cell.tag != "th":
                continue
            value = row_cells[index + 1].text()
            if cell.text() == "対戦日":
                found = re.search(r"\d{4}/\d{2}/\d{2}", value)
                if found:
                    record["date"] = found[0].replace("/", "-")
            elif cell.text() == "Kick off":
                record["kickoff"] = value
            elif cell.text() == "競技場" and value:
                record["venue"] = value
    side_names = {}
    for side in ("home", "away"):
        team = team_section.find(cls=side)
        title = team.find("th", cls="title").text()
        if title:
            record[side + "Team"] = title
        side_names[record[side + "Team"]] = side
        side_names[summary[side + "Team"]] = side
        position = ""
        for row in team.findall("tr"):
            number = integer(row.find("td", cls="num").text())
            name_cell = row.find("td", cls="name")
            if number is None or not name_cell.children:
                continue
            name = re.sub(r"[（(][^）)]*\d[^）)]*[）)]\s*$", "", name_cell.text(direct=True)).strip()
            # 15人制の表は「FW」「Re.」などを rowspan で数行まとめて書くので、セルのない行は上の区分を引き継ぐ。
            # 7人制の表は行ごとにセルがあり、空欄=先発・「Re.」=リザーブ(空欄を引き継ぎと読むと先発がリザーブになる)。
            pos_cell = row.find("td", cls="pos")
            if pos_cell.tag == "td":
                position = pos_cell.text()
            if name:
                record["players"].append(dict(side=side, number=number, name=name,
                    position="" if position == "Re." else position,
                    role="リザーブ" if position == "Re." else "先発"))
    score_table = team_section.find("table", cls="score")
    half_labels = []
    for row in score_table.findall("tr"):
        cs = cells(row)
        values = [c.text() for c in cs]
        if cs and cs[0].has("ha"):
            half_labels = values[:len(values)//2]
        if len(cs) == 3 and values[1] == "合計":
            record["homeScore"], record["awayScore"] = integer(values[0]), integer(values[2])
        if len(cs) >= 5 and len(cs) % 2 == 1:
            mid = len(cs)//2
            label = values[mid]
            if label == "計":
                for index, half in enumerate(half_labels):
                    suffix = {"前半": "FirstHalfScore", "後半": "SecondHalfScore"}.get(half)
                    if suffix:
                        record["home" + suffix] = integer(values[index])
                        record["away" + suffix] = integer(values[mid + 1 + index])
                    else:
                        record["stats"].append(dict(label=f"{half} 得点", home=values[index], away=values[mid + 1 + index]))
            elif label in {"T", "G", "PT", "PG", "DG"}:
                for index, half in enumerate(half_labels):
                    record["stats"].append(dict(label=f"{half} {label}", home=values[index], away=values[mid + 1 + index]))
    for row in team_section.find("table", cls="foul").findall("tr"):
        values = [c.text() for c in cells(row)]
        if len(values) == 5 and values[2] in {"前半", "後半", "合計", "延長前半", "延長後半"}:
            for index, label in enumerate(("PK", "FK")):
                record["stats"].append(dict(label=f"{values[2]} {label}", home=values[index], away=values[index + 3]))
    period = ""
    for row in root.find(id="score").findall("tr"):
        cs = cells(row)
        values = [c.text() for c in cs]
        if len(cs) != 7:
            continue
        if cs[0].tag == "th":
            period = values[0]
            continue
        record["scoreEvents"].append(dict(period=period, time=values[0],
            side=side_names.get(values[1], ""), player=re.sub(r"^\d+[.．]\s*", "", values[2]),
            kind=values[3], homeScore=integer(values[4]), awayScore=integer(values[6])))
    player_names = {(p["side"], str(p["number"])): p["name"] for p in record["players"]}
    for block in root.find(id="change").findall("div"):
        side = "home" if block.has("home") else "away" if block.has("away") else None
        if side is None:
            continue
        for row in block.findall("tr"):
            cs = cells(row)
            if len(cs) != 3 or cs[0].tag == "th":
                continue
            values = [c.text() for c in cs]
            kind, timing, numbers = values if block.has("change") else ("一時交替", values[0], values[1])
            if block.has("tmpchange") and values[2]:
                kind += " " + values[2]
            outgoing, separator, incoming = numbers.partition("→")
            period, at = period_time(timing)
            outgoing, incoming = outgoing.strip(), incoming.strip()
            record["substitutions"].append(dict(side=side, period=period, time=at, kind=kind,
                outgoing=player_names.get((side, outgoing), outgoing), incoming=player_names.get((side, incoming), incoming)))
    # An empty printable pre-match sheet is not a completed result.
    if record["status"] != "cancelled" and record["homeScore"] is not None and record["awayScore"] is not None:
        record["status"] = "finished"
    if not record["homeTeam"] or not record["awayTeam"]:
        raise ValueError("Official record has no team names")
    return record


EXPIRED_NOTE = "JRFU掲載期間終了：試合概要のみ収録（公式記録票は公開終了）"
OVERVIEW_NOTE = "JRFU掲載期間終了：公式記録票は公開終了のため、試合ページの前後半得点とT/G/PT/PG/DGのみ収録"


def parse_overview(html, summary, fetched_at=None):
    """Read the score breakdown that the plain match page keeps after the
    printable record expires. Members and scoring timelines are not on it, so
    the record stays a summary."""
    root = Tree(html).root
    board = root.find(cls="game-scoreboard")
    if not board.children:
        raise ValueError("JRFU match scoreboard was not found")
    record = dict(summary, fetchedAt=fetched_at or stamp(), stats=[],
                  omissions=["公式記録票の掲載が終了しているため、メンバー表・得点経過・交代は未収録（前後半の得点と得点内訳のみ）"])
    scores = board.find(cls="scoreboard").findall("div", cls="score")
    if len(scores) == 2:
        home, away = integer(scores[0].text()), integer(scores[1].text())
        if home is not None and away is not None:
            record["homeScore"], record["awayScore"] = home, away
    for row in board.find("table", cls="detailScore").findall("tr"):
        values = [c.text() for c in cells(row)]
        if len(values) != 3:
            continue
        suffix = {"前半": "FirstHalfScore", "後半": "SecondHalfScore"}.get(values[1])
        if suffix:
            record["home" + suffix], record["away" + suffix] = integer(values[0]), integer(values[2])
        elif values[1]:
            record["stats"].append(dict(label=f"{values[1]} 得点", home=values[0], away=values[2]))
    labels = []
    for row in board.find("table", cls="scoreStats").findall("tr"):
        cs = cells(row)
        values = [c.text() for c in cs]
        if len(cs) < 3 or len(cs) % 2 == 0:
            continue
        mid = len(cs) // 2
        if all(c.tag == "th" for c in cs):
            labels = values[:mid]
            continue
        half = values[mid]
        for index, label in enumerate(labels):
            if label in {"T", "G", "PT", "PG", "DG"} and half:
                record["stats"].append(dict(label=f"{half} {label}", home=values[index], away=values[mid + 1 + index]))
    for row in root.find(cls="game-info").findall("tr"):
        values = [c.text() for c in cells(row)]
        if len(values) != 2:
            continue
        if values[0] == "対戦日":
            found = re.search(r"\d{4}/\d{2}/\d{2}", values[1])
            if found:
                record["date"] = found[0].replace("/", "-")
        elif values[0] == "Kick off" and values[1]:
            record["kickoff"] = values[1]
        elif values[0] == "競技場" and values[1]:
            record["venue"] = values[1]
    if board.find(cls="status").has("-fulltime") and record["status"] != "cancelled" \
            and record["homeScore"] is not None and record["awayScore"] is not None:
        record["status"] = "finished"
    return record


class Fetcher:
    def __init__(self, cache, delay=1.0, timeout=50, offline=False):
        self.cache, self.delay, self.timeout = Path(cache), max(1.0, delay), timeout
        self.offline = offline
        self.lock, self.last_request, self.rate_limited = threading.Lock(), 0.0, False
        self.cache.mkdir(parents=True, exist_ok=True)

    def get(self, url, filename):
        path = self.cache / filename
        if path.exists():
            html = path.read_text(encoding="utf-8")
            if "</html>" in html.lower():
                return html
        if self.offline:
            raise RuntimeError("Not present in local cache (offline mode)")
        temporary = path.with_suffix(".partial")
        # One network request at a time across every worker. HTTP 429 opens a
        # circuit breaker for this run; pending tasks use summaries and must not
        # continue consuming the origin's rate limit.
        with self.lock:
            if self.rate_limited:
                raise RuntimeError("Deferred: JRFU rate limit stopped further requests in this run")
            time.sleep(max(0, self.delay - (time.monotonic() - self.last_request)))
            headers = path.with_suffix(".headers")
            completed = subprocess.run(["curl", "-L", "--fail", "--compressed", "--silent", "--show-error",
                "--connect-timeout", "15", "--max-time", str(self.timeout), "--dump-header", str(headers),
                url, "--output", str(temporary)], capture_output=True, text=True)
            self.last_request = time.monotonic()
            if completed.returncode:
                response_headers = headers.read_text(errors="replace") if headers.exists() else ""
                if re.search(r"HTTP/\S+\s+429\b", response_headers):
                    self.rate_limited = True
                    retry = re.search(r"^retry-after:\s*(.+)$", response_headers, re.I | re.M)
                    wait = retry[1].strip() if retry else "not supplied"
                    raise RuntimeError(f"HTTP 429: collection stopped; Retry-After: {wait}. Retry only after the source cooldown.")
                raise RuntimeError(clean(completed.stderr)[-350:])
        html = temporary.read_text(encoding="utf-8")
        if "</html>" not in html.lower():
            raise ValueError("Incomplete HTML response")
        temporary.replace(path)
        return html


def save(output, records, coverage, errors):
    by_id = {r["id"]: r for r in records}
    for entry in coverage:
        ids = entry.pop("_ids", []) if "_ids" in entry else []
        if ids:
            entry["imported"] = sum(i in by_id for i in ids)
            entry["fullDetails"] = sum(by_id[i]["detailLevel"] == "full" for i in ids if i in by_id)
            entry["_ids"] = ids
    payload = dict(matches=sorted(by_id.values(), key=lambda r: (r["date"], r["id"]), reverse=True),
        coverage=[{k: v for k, v in c.items() if not k.startswith("_")} for c in coverage], errors=errors)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(output)


def collect(args):
    fetcher = Fetcher(args.cache, args.delay, args.timeout, args.offline)
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    previous_records = {r["id"]: r for r in previous.get("matches", [])}
    errors = {e["url"]: e for e in previous.get("errors", [])}
    records, coverage = {}, []
    index = fetcher.get(BASE + "/schedule/", "index.html")
    cats = categories(index)
    jobs = [(year, slug, label) for year in args.years for slug, label in cats.items()]

    def schedule_job(job):
        year, slug, label = job
        url = f"{BASE}/schedule/{slug}?y={year}"
        filename = f"schedule-{slug}-{year}.html"
        html = fetcher.get(url, filename)
        return parse_schedule(html, year, label, fetched_stamp(fetcher.cache / filename)), url

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = {pool.submit(schedule_job, job): job for job in jobs}
        for future in as_completed(pending):
            year, slug, label = pending[future]
            url = f"{BASE}/schedule/{slug}?y={year}"
            entry = dict(source="jrfu", season=str(year), category=label, scheduleURL=url, discovered=0, imported=0, fullDetails=0)
            try:
                found, _ = future.result()
                entry.update(discovered=len(found), imported=len(found), _ids=[r["id"] for r in found])
                for record in found:
                    records[record["id"]] = preferred_summary(records.get(record["id"]), record)
                errors.pop(url, None)
                print(f"schedule {year} {label}: {len(found)}", flush=True)
            except Exception as exc:
                errors[url] = dict(url=url, message=str(exc))
                # A transient failed listing must not erase previously fetched
                # records or turn a known nonempty category into an empty one.
                retained = [r for r in previous_records.values()
                            if r["year"] == year and label in r.get("categories", [r["category"]])]
                entry.update(discovered=len(retained), imported=len(retained), _ids=[r["id"] for r in retained])
                for record in retained:
                    records[record["id"]] = preferred_summary(records.get(record["id"]), record)
                print(f"schedule ERROR {url}: {exc}", flush=True)
            coverage.append(entry)
    for match_id, summary in list(records.items()):
        previous_record = previous_records.get(match_id)
        if previous_record and previous_record["detailLevel"] == "full":
            records[match_id] = dict(previous_record, category=summary["category"], categories=summary["categories"], season=summary["season"], year=summary["year"])
    save(args.output, list(records.values()), coverage, list(errors.values()))
    print(f"discovered {len(records)} unique matches across {len(coverage)} year/categories", flush=True)
    if args.schedule_only:
        return

    def detail_job(summary):
        url = summary["sourceURL"] + "/print"
        filename = f"print-{summary['sourceMatchID']}.html"
        if not (fetcher.cache / filename).exists() and url in errors and not args.retry_failed:
            return summary
        html = fetcher.get(url, filename)
        try:
            return parse_print(html, summary, fetched_stamp(fetcher.cache / filename))
        except ValueError as exc:
            if str(exc) != EXPIRED_NOTE:
                raise
        # The printable sheet expired; the plain match page still has the score breakdown.
        overview = f"match-{summary['sourceMatchID']}.html"
        html = fetcher.get(summary["sourceURL"], overview)
        result = parse_overview(html, summary, fetched_stamp(fetcher.cache / overview))
        errors[url] = dict(url=url, message=OVERVIEW_NOTE)
        return result

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = {pool.submit(detail_job, r): r for r in records.values()}
        for index, future in enumerate(as_completed(pending), 1):
            summary = pending[future]
            try:
                result = future.result()
                records[result["id"]] = result
                if result["detailLevel"] == "full":
                    errors.pop(summary["sourceURL"] + "/print", None)
            except Exception as exc:
                url = summary["sourceURL"] + "/print"
                errors[url] = dict(url=url, message=str(exc))
            if index % 25 == 0 or index == len(pending):
                save(args.output, list(records.values()), coverage, list(errors.values()))
                print(f"details {index}/{len(pending)} full={sum(r['detailLevel'] == 'full' for r in records.values())} errors={len(errors)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--years", nargs="+", type=int, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workers", type=int, choices=(1, 2), default=2)
    parser.add_argument("--delay", type=float, default=1.0, help="Minimum pause after each request; at least 1 second")
    parser.add_argument("--timeout", type=int, default=50)
    parser.add_argument("--schedule-only", action="store_true")
    parser.add_argument("--offline", action="store_true", help="Parse only local cached HTML; never request the network")
    parser.add_argument("--retry-failed", action="store_true", help="Explicitly retry previously failed details after a source cooldown")
    collect(parser.parse_args())


if __name__ == "__main__":
    main()
