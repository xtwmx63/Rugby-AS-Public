#!/usr/bin/env python3
"""Collect World Rugby's public SVNS records, retaining source IDs and omissions.

Raw responses stay in a caller-provided cache, outside the app. Requests share a
host-wide start interval; HTTP 429/403 stops the run. An offline run uses only
cached responses. The IRB/HSBC Sevens World Series, the old Sevens Series and current SVNS series are covered.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from collections import defaultdict
import math
import json
from pathlib import Path
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


def series_in_scope(series, since):
    name = series['name']
    return (series['mainSeason'] >= since and series['sport'] in ('mrs', 'wrs')
            and ('SVNS' in name or (('Sevens Series' in name or 'Sevens World Series' in name)
                                    and 'Challenger' not in name)))


def discover(client, since):
    series = client.get('/series?pageSize=100', 'series-all')
    all_series = list(series['content'])
    for page in range(1, series['pageInfo']['numPages']):
        all_series.extend(client.get(f'/series?pageSize=100&page={page}', f'series-page-{page}')['content'])
    selected = [s for s in all_series if series_in_scope(s, since)]
    events, coverage = {}, []
    by_series = {str(s[key]): s for s in selected for key in ('id', 'altId')}
    for sport in ('mrs', 'wrs'):
        first = client.get(f'/event?sport={sport}&pageSize=100', f'events-{sport}-0')
        pages = [first]
        for page in range(1, first['pageInfo']['numPages']):
            pages.append(client.get(f'/event?sport={sport}&pageSize=100&page={page}', f'events-{sport}-{page}'))
        for page in pages:
            for event in page['content']:
                if (event.get('end') or event.get('start') or {}).get('label', '') < f'{since}-01-01':
                    continue
                series = by_series.get(str(event.get('seriesId'))) or by_series.get(str(event.get('seriesAltId')))
                # Women's 2021 replacement events retain their own official names.
                if not series and since <= 2021 and event['label'].startswith('Fast Four 2021'):
                    series = {'name': 'Fast Four 2021', 'mainSeason': 2021, 'sport': 'wrs'}
                if series:
                    events[event['altId'] or event['id']] = {'event': event, 'series': series}
    for series in selected:
        coverage.append({'series': series, 'eventCount': sum(e['series'] == series for e in events.values())})
    catalog = {'since': since, 'series': coverage, 'events': [], 'errors': []}

    def schedule(item):
        event = item['event']
        identifier = event.get('altId') or event['id']
        data = client.get(f"/event/{identifier}/schedule", f"schedule-{event['id']}")
        return dict(item, matches=data['matches'], event=data['event'])

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(schedule, item): item for item in events.values()}
        for future in as_completed(futures):
            item = futures[future]
            try:
                catalog['events'].append(future.result())
            except Exception as error:
                catalog['errors'].append({'url': f"{API}/event/{item['event']['id']}/schedule", 'message': str(error)})
    catalog['events'].sort(key=lambda x: (x['event']['start']['label'], x['event']['id']))
    save_json(client.cache / 'catalog.json', catalog)
    print(f"Discovered {len(catalog['events'])} events, {sum(len(e['matches']) for e in catalog['events'])} match entries; {len(catalog['errors'])} errors", flush=True)
    return catalog


def download(client, catalog):
    matches = {m['matchId']: m for event in catalog['events'] for m in event['matches']
               if (m.get('time') or {}).get('label', '') >= f"{catalog['since']}-01-01"}
    errors = []

    def details(match):
        if match['status'] in ('U', 'CC', 'X'):
            return
        identifier = match.get('matchAltId') or match['matchId']
        stats = client.get(f'/match/{identifier}/stats', f'match-{identifier}-stats')
        client.get(f'/match/{identifier}/timeline', f'match-{identifier}-timeline')
        if not any(team.get('playerStats') for team in (stats or {}).get('teamStats', [])):
            client.get(f'/match/{identifier}/summary', f'match-{identifier}-summary')

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(details, m): m for m in matches.values()}
        for index, future in enumerate(as_completed(futures), 1):
            match = futures[future]
            try:
                future.result()
            except Exception as error:
                entry = {'url': f"{API}/match/{match['matchId']}", 'message': str(error)}
                errors.append(entry)
                print('ERROR', entry, flush=True)
            if index % 50 == 0 or index == len(matches):
                progress = {'processed': index, 'total': len(matches), 'errors': errors,
                            'updatedAt': datetime.now(timezone.utc).isoformat()}
                save_json(client.cache / 'download-progress.json', progress)
                print(f"Downloaded {index}/{len(matches)} matches ({len(errors)} errors)", flush=True)
    return errors



SIDES = ('home', 'away')
SCORE_TYPES = {'T5': ('T', 5), 'PT5': ('PT', 7), 'PT7': ('PT', 7),
               'C2': ('G', 2), 'Miss Con': ('Gx', 0), 'P3': ('PG', 3),
               'D3': ('DG', 3), 'Miss Pen': ('PGx', 0), 'Miss Drop': ('DGx', 0)}
PERIODS = {'L1': '前半', 'LHT': '後半', 'L2': '後半', 'L3': '延長前半', 'L4': '延長後半'}


def person_name(player):
    return (player.get('name') or {}).get('display') or ''


def event_clock(event):
    phase = event.get('phase') or ''
    seconds = (event.get('time') or {}).get('secs')
    # Half-time changes belong to the start of the second half. Legacy clocks
    # sometimes carry 14:00 here; that is not a 7-minute second-half change.
    if phase not in PERIODS or seconds is None:
        return dict(period='', time='', matchSeconds=seconds, sourcePhase=phase)
    relative = 0 if phase == 'LHT' else max(0, seconds - (420 if phase != 'L1' else 0))
    return {'period': PERIODS.get(phase, phase), 'time': f'{math.ceil(relative / 60)}分',
            'matchSeconds': seconds, 'sourcePhase': phase}


def parse_match(match, event, series, stats, timeline, summary, fetched_at):
    identifier = str(match.get('matchAltId') or match['matchId'])
    gender = '女子' if series['sport'] == 'wrs' else '男子'
    category = 'HSBC SVNS ' + gender
    clock = match.get('time') or {}
    utc = datetime.fromtimestamp(clock['millis'] / 1000, timezone.utc) if clock.get('millis') is not None else None
    local = utc.astimezone(timezone(timedelta(hours=clock.get('gmtOffset') or 0))) if utc else None
    scores = match.get('scores') or [None, None]
    if match.get('status') in ('CC', 'X'):
        scores = [None, None]
    teams = match.get('teams') or [{}, {}]
    record = dict(id='svns:' + identifier, source='svns', sourceMatchID=identifier,
        season=str(series['mainSeason']), year=series['mainSeason'], category=category,
        tournament=event['label'] + ' ' + gender + ' ' + event['start']['label'],
        seriesName=series['name'] + ' ' + gender,
        round=' / '.join(filter(None, [match.get('eventPhase'), match.get('description')])),
        date=local.strftime('%Y-%m-%d') if local else clock.get('label', ''),
        kickoff=local.strftime('%H:%M') if local else '',
        kickoffUTC=utc.isoformat(timespec='seconds').replace('+00:00', 'Z') if utc else None,
        venue=', '.join(filter(None, [(match.get('venue') or {}).get(k) for k in ('name', 'city', 'country')])),
        homeTeam=teams[0].get('name') or '', awayTeam=teams[1].get('name') or '',
        homeScore=scores[0], awayScore=scores[1],
        homeFirstHalfScore=None, awayFirstHalfScore=None, homeSecondHalfScore=None, awaySecondHalfScore=None,
        status={'C': 'finished', 'U': 'scheduled', 'X': 'cancelled', 'CC': 'cancelled'}.get(match.get('status'), 'unknown'),
        sourceURL='https://www.svns.com/en/match/' + identifier, officialRecordURL=None,
        fetchedAt=fetched_at, detailLevel='summary', players=[], scoreEvents=[], substitutions=[], stats=[],
        sourceStatus=match.get('status'), sourceScores=match.get('scores'),
        sourceEventID=event.get('altId') or event['id'], sourceSeriesID=series.get('altId') or series.get('id'),
        omissions=[])
    names = {}
    team_stats = (stats or {}).get('teamStats') or []
    summary_teams = (summary or {}).get('teams') or []
    for index, side in enumerate(SIDES):
        roster = team_stats[index].get('playerStats') or [] if index < len(team_stats) else []
        if not roster and index < len(summary_teams):
            roster = (summary_teams[index].get('teamList') or {}).get('list') or []
        for item in roster:
            player = item.get('player') or {}
            name = person_name(player)
            if not name or player.get('role') not in (None, 'Player'):
                continue
            for key in ('id', 'altId'):
                if player.get(key):
                    names[(index, str(player[key]))] = name
            number = str(item.get('number') or '')
            position = item.get('position') or ''
            role = 'リザーブ' if position == 'Rep' else ('先発' if position in ('For', 'Bck', 'Back') else '')
            record['players'].append(dict(side=side, number=int(number) if number.isdigit() else None,
                name=name, position={'For': 'FW', 'Bck': 'BK', 'Back': 'BK', 'Rep': ''}.get(position, position),
                role=role, sourcePlayerID=player.get('altId') or player.get('id'), statistics=item.get('stats') or {}))
    keys = sorted({key for team in team_stats for key in (team.get('stats') or {})})
    def stat_value(index, key):
        value = (team_stats[index].get('stats') or {}).get(key) if index < len(team_stats) else None
        return '' if value is None else (str(int(value)) if isinstance(value, (int, float)) and value == int(value) else str(value))
    record['stats'] = [dict(label=key, home=stat_value(0, key), away=stat_value(1, key)) for key in keys]
    source_events = (timeline or {}).get('timeline') or []
    scoring = [e for e in source_events if e.get('type') in SCORE_TYPES]
    if not scoring:
        for index, team in enumerate(summary_teams):
            for rows in (team.get('scoring') or {}).values():
                # The per-team summary is authoritative; its nested teamIndex
                # uses a different ordering in some official responses.
                scoring.extend(dict(e, teamIndex=index) for e in rows if e.get('type') in SCORE_TYPES)
    def order(e):
        return (list(PERIODS).index(e['phase']) if e.get('phase') in PERIODS else 99,
                (e.get('time') or {}).get('secs') or 0,
                0 if e['type'] in ('T5', 'PT5', 'PT7') else 1,
                (e.get('timestamp') or {}).get('millis') or 0)
    total, first = [0, 0], [0, 0]
    unknown_points = any((e.get('points') or 0) > 0 and e.get('type') not in SCORE_TYPES for e in source_events)
    for e in sorted(scoring, key=order):
        index = e.get('teamIndex')
        kind, points = SCORE_TYPES[e['type']]
        if isinstance(e.get('points'), (int, float)):
            points = int(e['points'])
        if kind == 'PT' and points != 7:
            kind = f'PT{points}'
        if index in (0, 1):
            total[index] += points
            if e.get('phase') == 'L1':
                first[index] += points
        else:
            unknown_points = True
        record['scoreEvents'].append(dict(event_clock(e), side=SIDES[index] if index in (0, 1) else '',
            player=names.get((index, str(e.get('playerAltId') or e.get('playerId'))), ''), kind=kind, points=points,
            homeScore=total[0], awayScore=total[1]))
    complete = not unknown_points and total == scores and bool(source_events or scoring)
    timed = all(e.get('phase') in PERIODS and (e.get('time') or {}).get('secs') is not None for e in scoring)
    if complete and timed:
        record.update(homeFirstHalfScore=first[0], awayFirstHalfScore=first[1])
        if not any(e.get('phase') in ('L3', 'L4') for e in scoring):
            record.update(homeSecondHalfScore=total[0] - first[0], awaySecondHalfScore=total[1] - first[1])
    else:
        # Incomplete timelines cannot establish an intermediate cumulative score.
        for item in record['scoreEvents']:
            item['homeScore'] = item['awayScore'] = None
        if not complete and record['status'] == 'finished':
            record['omissions'].append('得点経過が最終得点と一致しない、または未掲載')
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
            for e in rows:
                is_on = e['type'] == 'Sub On'
                record['substitutions'].append(dict(event_clock(e), side=SIDES[index],
                    incoming=name(e) if is_on else '', outgoing='' if is_on else name(e), kind='入場' if is_on else '退出'))
    if any(not row['time'] for row in record['substitutions']):
        record['omissions'].append('一部の交代時刻が未掲載（時刻不明の交代は取り込み対象外）')
    if record['status'] == 'finished':
        if not all(any(p['side'] == side for p in record['players']) for side in SIDES):
            record['omissions'].append('一部または両チームのメンバー表が未掲載')
        if not record['omissions']:
            record['detailLevel'] = 'full'
    return record


def export(client, catalog, output):
    records, errors = {}, list(catalog['errors'])
    for item in catalog['events']:
        for match in item['matches']:
            if (match.get('time') or {}).get('label', '') < f"{catalog['since']}-01-01":
                continue
            identifier = match.get('matchAltId') or match['matchId']
            details, paths = {}, []
            for kind in ('stats', 'timeline', 'summary'):
                path = client.cache / f'match-{identifier}-{kind}.json'
                if path.exists():
                    details[kind] = json.loads(path.read_text())
                    paths.append(path)
            if match['status'] not in ('U', 'CC', 'X'):
                required = ['stats', 'timeline']
                if 'stats' in details and not any(t.get('playerStats') for t in (details['stats'] or {}).get('teamStats', [])):
                    required.append('summary')
                for kind in required:
                    if kind not in details:
                        errors.append(dict(url=f'{API}/match/{identifier}/{kind}', message='詳細レスポンス未取得'))
            paths.append(client.cache / f"schedule-{item['event']['id']}.json")
            fetched_at = datetime.fromtimestamp(max(p.stat().st_mtime for p in paths), timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')
            record = parse_match(match, item['event'], item['series'], details.get('stats'),
                                 details.get('timeline'), details.get('summary'), fetched_at)
            records[record['id']] = record
            for omission in record['omissions']:
                errors.append(dict(url=record['sourceURL'], message=omission))
    groups = defaultdict(list)
    for record in records.values():
        groups[(record['season'], record['category'])].append(record)
    coverage = [dict(source='svns', season=season, category=category,
                     scheduleURL='https://www.svns.com/en/fixtures-and-results',
                     discovered=len(rows), imported=len(rows), fullDetails=sum(r['detailLevel'] == 'full' for r in rows))
                for (season, category), rows in sorted(groups.items())]
    save_json(output, dict(matches=list(records.values()), coverage=coverage, errors=errors))
    print(f"Exported {len(records)} matches; {sum(r['detailLevel'] == 'full' for r in records.values())} full details; {len(errors)} omissions", flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    parser.add_argument('--since', default=2021, type=int)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--download-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.download_only and not args.output:
        parser.error('--output is required unless --download-only is set')
    client = Client(args.cache, args.offline)
    catalog = discover(client, args.since)
    errors = download(client, catalog) if not args.offline and not client.stopped.is_set() else []
    if args.output:
        export(client, catalog, args.output)
    if client.stopped.is_set() or catalog['errors'] or errors:
        parser.exit(1, 'Collection incomplete; cached records are retained.\n')
