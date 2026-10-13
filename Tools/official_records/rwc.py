#!/usr/bin/env python3
"""Collect the official men's and women's Rugby World Cup archive (15-a-side).

Only match facts are exported. Raw API responses stay outside the application.
HTTP 403/429 stops collection; cached responses support resumable/offline builds.
"""
from __future__ import annotations
import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
import json
import math
from pathlib import Path
import re
import subprocess
import threading
import time

API = "https://api.wr-rims-prod.pulselive.com/rugby/v3"


def save_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.part')
    temporary.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n')
    temporary.replace(path)


class Client:
    def __init__(self, cache, offline=False, delay=1.5):
        self.cache, self.offline, self.delay = cache, offline, delay
        self.lock, self.stopped = threading.Lock(), threading.Event()
        self.last_request = 0.0

    def get(self, endpoint, name):
        path = self.cache / (name + '.json')
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:
                if self.offline:
                    raise
        if self.offline:
            raise RuntimeError('Not present in local cache (offline mode)')
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix('.download')
        headers = path.with_suffix('.headers')
        try:
            for attempt in range(3):
                with self.lock:
                    if self.stopped.is_set():
                        raise RuntimeError('Host requests stopped; inspect the first HTTP error')
                    time.sleep(max(0, self.delay - (time.monotonic() - self.last_request)))
                    self.last_request = time.monotonic()
                response = subprocess.run([
                    'curl', '--compressed', '--silent', '--show-error', '--connect-timeout', '15',
                    '--max-time', '45', '-H', 'account: worldrugby', '--dump-header', str(headers),
                    '--write-out', '%{http_code}', API + endpoint, '-o', str(partial)
                ], capture_output=True, text=True)
                status = response.stdout.strip()
                if status in ('429', '403'):
                    self.stopped.set()
                    raise RuntimeError(f'HTTP {status}; host requests stopped: ' + headers.read_text())
                if response.returncode == 0 and status == '200':
                    body = partial.read_text()
                    value = json.loads(body) if body.strip() else None
                    save_json(path, value)
                    return value
                if status.startswith('4') or attempt == 2:
                    raise RuntimeError(f'HTTP {status}: {response.stderr.strip()}')
                time.sleep(2 ** (attempt + 1))
        finally:
            partial.unlink(missing_ok=True)
            headers.unlink(missing_ok=True)


def in_scope(event, through):
    return (event.get('sport') in ('mru', 'wru')
            and re.fullmatch(r"(?:(?:Men's|Women's) )?Rugby World Cup \d{4}", event.get('label', '')) is not None
            and int(event['start']['label'][:4]) <= through)


def discover(client, through):
    selected = {}
    for sport in ('mru', 'wru'):
        first = client.get(f'/event?sport={sport}&pageSize=100', f'events-{sport}-100-0')
        pages = [first]
        for page in range(1, first['pageInfo']['numPages']):
            pages.append(client.get(f'/event?sport={sport}&pageSize=100&page={page}', f'events-{sport}-100-{page}'))
        for page in pages:
            for event in page['content']:
                if in_scope(event, through):
                    selected[event['id']] = event
    if not selected:
        raise ValueError('No World Cup tournaments discovered')
    catalog = []
    # A missing schedule is fatal: never silently build an archive missing a tournament.
    for event in sorted(selected.values(), key=lambda e: (e['sport'], e['start']['label'])):
        identifier = event.get('altId') or event['id']
        data = client.get(f'/event/{identifier}/schedule', f"schedule-{event['id']}")
        if not data.get('matches'):
            raise ValueError(f"Empty schedule: {event['label']}")
        catalog.append(data)
    save_json(client.cache / 'catalog.json', catalog)
    return catalog


def download(client, catalog):
    matches = {m['matchId']: m for event in catalog for m in event['matches'] if m['status'] == 'C'}
    jobs = [(m, kind) for m in matches.values() for kind in ('summary', 'timeline', 'stats')]
    errors = []
    def fetch(job):
        match, kind = job
        identifier = match.get('matchAltId') or match['matchId']
        client.get(f'/match/{identifier}/{kind}', f'match-{identifier}-{kind}')
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {executor.submit(fetch, job): job for job in jobs}
        for count, future in enumerate(as_completed(futures), 1):
            match, kind = futures[future]
            try:
                future.result()
            except Exception as error:
                errors.append(dict(url=f"{API}/match/{match['matchId']}/{kind}", message=str(error)))
            if count % 50 == 0 or count == len(jobs):
                print(f'Downloaded {count}/{len(jobs)} endpoints; {len(errors)} errors', flush=True)
    return errors


SIDES = ('home', 'away')
PHASES = {'L1': '前半', 'LHT': '後半', 'L2': '後半', 'L3': '延長前半', 'L4': '延長後半', 'L5': '延長サドンデス'}
POSITIONS = {'HK': 'HO', 'SR': 'LO', 'N8': 'NO.8', 'FH': 'SO', 'CE': 'CTB', 'WI': 'WTB', 'Rep': '', '?': ''}
SCORE_TYPES = {'T5': ('T', 5), 'T4': ('T', 4), 'PT5': ('PT', 5), 'PT7': ('PT', 7),
               'C2': ('G', 2), 'P3': ('PG', 3), 'D3': ('DG', 3),
               'Miss Con': ('Gx', 0), 'Miss Pen': ('PGx', 0), 'Miss Drop': ('DGx', 0)}


def event_clock(event):
    phase = event.get('phase') or ''
    seconds = (event.get('time') or {}).get('secs')
    # The importer folds extra time into the second half; retain cumulative
    # second-half minutes so a 100th-minute score is imported at 40 + 60, not 40 + 10.
    if phase not in PHASES:
        return dict(period='', time='', matchSeconds=seconds, sourcePhase=phase)
    relative = 0 if phase == 'LHT' else max(0, seconds - (0 if phase == 'L1' else 2400)) if seconds is not None else None
    return dict(period=PHASES.get(phase, phase), time=f'{math.ceil(relative / 60)}分' if relative is not None else '',
                matchSeconds=seconds, sourcePhase=phase)


def score_kind(event, year):
    kind, default = SCORE_TYPES[event['type']]
    supplied = event.get('points')
    points = int(supplied) if isinstance(supplied, (int, float)) else default
    if supplied is None and kind in ('T', 'PT') and year <= 1991:
        points = 4
    # Old penalty tries still required a separate conversion, unlike today's 7 points.
    # Distinct display kinds prevent the personal-record importer treating them as 7.
    if kind == 'T' and points != 5:
        kind = f'T{points}'
    elif kind == 'PT' and points != 7:
        kind = f'PT{points}'
    return kind, points


def parse_match(match, event, summary, timeline, stats, fetched_at):
    identifier = str(match.get('matchAltId') or match['matchId'])
    season = re.search(r'\d{4}$', event['label']).group()
    gender = '女子' if event['sport'] == 'wru' else '男子'
    clock = match.get('time') or {}
    utc = datetime.fromtimestamp(clock['millis'] / 1000, timezone.utc) if clock.get('millis') is not None else None
    local = utc.astimezone(timezone(timedelta(hours=clock.get('gmtOffset') or 0))) if utc else None
    scores = list(match.get('scores') or [None, None])
    status = {'C': 'finished', 'U': 'scheduled', 'CC': 'cancelled', 'X': 'cancelled'}.get(match.get('status'), 'unknown')
    if status == 'cancelled':
        scores = [None, None]
    teams = match['teams']
    record = dict(id='rwc:' + identifier, source='rwc', sourceMatchID=identifier,
        season=season, year=int(season), category='ラグビーワールドカップ ' + gender,
        tournament=gender + 'ラグビーワールドカップ' + season,
        round=' / '.join(filter(None, [match.get('eventPhase'), match.get('description')])),
        date=local.strftime('%Y-%m-%d') if local else clock.get('label', ''),
        kickoff=local.strftime('%H:%M') if local else '',
        kickoffUTC=utc.isoformat(timespec='seconds').replace('+00:00', 'Z') if utc else None,
        venue=', '.join(filter(None, [(match.get('venue') or {}).get(k) for k in ('name', 'city', 'country')])),
        homeTeam=teams[0].get('name') or '', awayTeam=teams[1].get('name') or '',
        homeScore=scores[0], awayScore=scores[1], homeFirstHalfScore=None, awayFirstHalfScore=None,
        homeSecondHalfScore=None, awaySecondHalfScore=None, status=status,
        sourceURL='https://www.world.rugby/match/' + str(match['matchId']), officialRecordURL=None,
        fetchedAt=fetched_at, detailLevel='summary', players=[], scoreEvents=[], substitutions=[], stats=[],
        sourceEventID=event.get('altId') or event['id'], sourceStatus=match.get('status'), sourceScores=match.get('scores'),
        omissions=[])
    names = {}
    summary_teams = (summary or {}).get('teams') or []
    team_stats = (stats or {}).get('teamStats') or []
    for index, side in enumerate(SIDES):
        roster = (summary_teams[index].get('teamList') or {}).get('list') or [] if index < len(summary_teams) else []
        if not roster and index < len(team_stats):
            roster = team_stats[index].get('playerStats') or []
        for row in roster:
            player = row.get('player') or {}
            if player.get('role') not in (None, 'Player'):
                continue  # Historical lineups also contain coaches and team staff.
            name = (player.get('name') or {}).get('display') or ''
            if not name:
                continue
            for key in ('id', 'altId'):
                if player.get(key):
                    names[(index, str(player[key]))] = name
            position = row.get('position') or ''
            number = str(row.get('number') or '')
            record['players'].append(dict(side=side, number=int(number) if number.isdigit() else None,
                name=name, position=POSITIONS.get(position, position),
                role='リザーブ' if position == 'Rep' else ('先発' if position and position != '?' else ''),
                sourcePlayerID=player.get('altId') or player.get('id')))
    record['players'] = sorted(record['players'], key=lambda p: (p['side'] != 'home', p['number'] or 999, p['name']))
    source_events = (timeline or {}).get('timeline') or []
    scoring = [e for e in source_events if e.get('type') in SCORE_TYPES]
    if not scoring:
        for index, team in enumerate(summary_teams):
            for rows in (team.get('scoring') or {}).values():
                scoring.extend(dict(e, teamIndex=index) for e in rows if e.get('type') in SCORE_TYPES)
    # API timestamps for old same-minute tries and conversions reflect migration
    # order, not play order. Use a stable try-before-conversion tie break.
    def order(e):
        return (list(PHASES).index(e['phase']) if e.get('phase') in PHASES else 99,
                (e.get('time') or {}).get('secs') or 0,
                0 if e['type'] in ('T5', 'T4', 'PT5', 'PT7') else 1)
    total, first = [0, 0], [0, 0]
    unknown = any((e.get('points') or 0) > 0 and e.get('type') not in SCORE_TYPES for e in source_events)
    for e in sorted(scoring, key=order):
        index = e.get('teamIndex')
        kind, points = score_kind(e, int(season))
        if index in (0, 1):
            total[index] += points
            if e.get('phase') == 'L1':
                first[index] += points
        else:
            unknown = True
        record['scoreEvents'].append(dict(event_clock(e), side=SIDES[index] if index in (0, 1) else '',
            player=names.get((index, str(e.get('playerAltId') or e.get('playerId'))), ''),
            kind=kind, points=points, homeScore=total[0], awayScore=total[1]))
    complete = not unknown and total == scores and bool(scoring or source_events)
    timed = all(e.get('phase') in PHASES and (e.get('time') or {}).get('secs') is not None for e in scoring)
    if complete and timed:
        record.update(homeFirstHalfScore=first[0], awayFirstHalfScore=first[1])
        # Do not report extra-time points as a regulation second-half score.
        if not any(e.get('phase') in ('L3', 'L4', 'L5') for e in scoring):
            record.update(homeSecondHalfScore=total[0]-first[0], awaySecondHalfScore=total[1]-first[1])
    elif status == 'finished':
        for row in record['scoreEvents']:
            row['homeScore'] = row['awayScore'] = None
        if not complete:
            record['omissions'].append('得点経過が未掲載、または最終得点と不一致（中間得点は未確定）')
    if scoring and not timed:
        record['omissions'].append('一部得点の時刻・時間帯が未掲載（中間得点・前後半得点は未確定）')
    changes = defaultdict(list)
    for e in source_events:
        if e.get('type') in ('Sub On', 'Sub Off') and e.get('teamIndex') in (0, 1):
            changes[(e.get('phase'), (e.get('time') or {}).get('secs'), e['teamIndex'], e.get('link'))].append(e)
    for (_, _, index, _), rows in changes.items():
        incoming = [e for e in rows if e['type'] == 'Sub On']
        outgoing = [e for e in rows if e['type'] == 'Sub Off']
        def name(e):
            return names.get((index, str(e.get('playerAltId') or e.get('playerId'))), '')
        if len(incoming) == len(outgoing) == 1:
            record['substitutions'].append(dict(event_clock(rows[0]), side=SIDES[index],
                incoming=name(incoming[0]), outgoing=name(outgoing[0]), kind='交代'))
        else:
            # Multiple changes at one minute do not identify the replacement pair.
            for e in rows:
                on = e['type'] == 'Sub On'
                record['substitutions'].append(dict(event_clock(e), side=SIDES[index],
                    incoming=name(e) if on else '', outgoing='' if on else name(e), kind='入場' if on else '退出'))
    if any(not row['time'] for row in record['substitutions']):
        record['omissions'].append('一部の交代時刻が未掲載（時刻不明の交代は取り込み対象外）')
    def value(index, key):
        v = (team_stats[index].get('stats') or {}).get(key) if index < len(team_stats) else None
        return '' if v is None else str(int(v)) if isinstance(v, (int, float)) and v == int(v) else str(v)
    keys = sorted({k for team in team_stats for k in (team.get('stats') or {})})
    record['stats'] = [dict(label=k, home=value(0, k), away=value(1, k)) for k in keys]
    if status == 'finished':
        if not all(any(p['side'] == side for p in record['players']) for side in SIDES):
            record['omissions'].append('一部または両チームのメンバー表が未掲載')
        if not record['omissions']:
            record['detailLevel'] = 'full'
    return record


def export(client, catalog, output, fetch_errors=()):
    records, coverage, errors = {}, [], list(fetch_errors)
    for data in catalog:
        event = data['event']
        rows = []
        schedule_path = client.cache / f"schedule-{event['id']}.json"
        for match in data['matches']:
            identifier = match.get('matchAltId') or match['matchId']
            details, paths = {}, [schedule_path]
            for kind in ('summary', 'timeline', 'stats'):
                path = client.cache / f'match-{identifier}-{kind}.json'
                if path.exists():
                    details[kind] = json.loads(path.read_text())
                    paths.append(path)
                elif match['status'] == 'C':
                    errors.append(dict(url=f'{API}/match/{identifier}/{kind}', message='詳細レスポンス未取得'))
            fetched = datetime.fromtimestamp(max(p.stat().st_mtime for p in paths), timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
            record = parse_match(match, event, details.get('summary'), details.get('timeline'), details.get('stats'), fetched)
            records[record['id']] = record
            rows.append(record)
            errors.extend(dict(url=record['sourceURL'], message=m) for m in record['omissions'])
        sample = rows[0]
        coverage.append(dict(source='rwc', season=sample['season'], category=sample['category'],
            scheduleURL='https://www.rugbyworldcup.com/en/past-tournaments',
            discovered=len(rows), imported=len(rows), fullDetails=sum(r['detailLevel'] == 'full' for r in rows)))
    save_json(output, dict(matches=list(records.values()), coverage=coverage, errors=errors))
    print(f'Exported {len(records)} matches; {len(errors)} omissions/errors', flush=True)
    return list(records.values())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--through', default=datetime.now(timezone.utc).year, type=int)
    parser.add_argument('--delay', default=1.5, type=float)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    if args.delay < 1.5:
        parser.error('--delay must be at least 1.5 seconds')
    client = Client(args.cache, args.offline, args.delay)
    catalog = discover(client, args.through)
    errors = [] if args.offline else download(client, catalog)
    export(client, catalog, args.output, errors)
    if errors or client.stopped.is_set():
        parser.exit(1, 'Collection incomplete; cached records are retained.\n')
