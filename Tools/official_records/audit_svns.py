#!/usr/bin/env python3
"""Verify an exported SVNS archive against its cached official source responses."""
import argparse
from collections import Counter
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path


def audit(cache, path):
    data = json.loads(path.read_text())
    catalog = json.loads((cache / 'catalog.json').read_text())
    records = {r['sourceMatchID']: r for r in data['matches']}
    assert len(records) == len(data['matches']), 'Duplicate source IDs'
    expected, full, partial = set(), 0, 0
    for item in catalog['events']:
        for match in item['matches']:
            if (match.get('time') or {}).get('label', '') < f"{catalog['since']}-01-01":
                continue
            identifier = match.get('matchAltId') or match['matchId']
            expected.add(identifier)
            record = records[identifier]
            assert record['year'] == item['series']['mainSeason'], identifier
            assert [record['homeTeam'], record['awayTeam']] == [t['name'] for t in match['teams']], identifier
            assert record['sourceStatus'] == match['status'], identifier
            if match['status'] in ('CC', 'X'):
                assert record['homeScore'] is record['awayScore'] is None, identifier
                continue
            assert [record['homeScore'], record['awayScore']] == match['scores'], identifier
            clock = match['time']
            if clock.get('millis') is not None:
                utc = datetime.fromtimestamp(clock['millis']/1000, timezone.utc)
                local = utc.astimezone(timezone(timedelta(hours=clock.get('gmtOffset') or 0)))
                assert (record['date'], record['kickoff']) == (local.strftime('%Y-%m-%d'), local.strftime('%H:%M')), identifier
                assert datetime.fromisoformat(record['kickoffUTC'].replace('Z', '+00:00')) == utc, identifier
            if match['status'] == 'U':
                continue
            stats = json.loads((cache / f'match-{identifier}-stats.json').read_text())
            timeline = json.loads((cache / f'match-{identifier}-timeline.json').read_text())
            team_stats = (stats or {}).get('teamStats') or []
            summary_path = cache / f'match-{identifier}-summary.json'
            summary = json.loads(summary_path.read_text()) if summary_path.exists() else None
            if not any(t.get('playerStats') for t in team_stats):
                assert summary_path.exists(), (identifier, 'missing summary fallback')
            summary_teams = (summary or {}).get('teams') or []
            for i, side in enumerate(('home', 'away')):
                roster = (team_stats[i].get('playerStats') or []) if i < len(team_stats) else []
                if not roster and i < len(summary_teams):
                    roster = (summary_teams[i].get('teamList') or {}).get('list') or []
                names = [(p.get('player') or {}).get('name', {}).get('display') for p in roster
                         if (p.get('player') or {}).get('role') in (None, 'Player')]
                names = [n for n in names if n]
                assert Counter(names) == Counter(p['name'] for p in record['players'] if p['side'] == side), identifier
            raw_scores = [e for e in (timeline or {}).get('timeline', []) if (e.get('points') or 0) > 0]
            if raw_scores:
                parsed = [e for e in record['scoreEvents'] if e['points'] > 0]
                assert len(raw_scores) == len(parsed), (identifier, 'scoring-event count')
                assert sum(e['points'] for e in raw_scores) == sum(e['points'] for e in parsed), (identifier, 'scoring values')
            source_stats = {k for t in team_stats for k in (t.get('stats') or {})}
            assert source_stats == {s['label'] for s in record['stats']}, (identifier, 'statistic labels')
            for row in record['stats']:
                for i, side in enumerate(('home', 'away')):
                    value = (team_stats[i].get('stats') or {}).get(row['label']) if i < len(team_stats) else None
                    if value is None:
                        assert row[side] == '', (identifier, row['label'])
                    elif isinstance(value, (float, int)):
                        assert float(row[side]) == value, (identifier, row['label'])
                    else:
                        assert row[side] == str(value), (identifier, row['label'])
            if record['detailLevel'] == 'full':
                for side, score in zip(('home', 'away'), match['scores']):
                    assert sum(e['points'] for e in record['scoreEvents'] if e['side'] == side) == score, identifier
                full += 1
            else:
                partial += 1
                if record['status'] == 'finished':
                    assert record['omissions'], identifier
    assert set(records) == expected, 'Schedule/export match sets differ'
    assert sum(c['imported'] for c in data['coverage']) == len(records)
    assert not any(e['message'] == '詳細レスポンス未取得' for e in data['errors']), 'Unfetched responses remain'
    print(f'PASS: {len(records)} SVNS schedule records, {full} full details, {partial} partial/unknown records; dates, teams, scores, rosters, scoring events and statistics match official caches')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    parser.add_argument('--input', required=True, type=Path)
    args = parser.parse_args()
    audit(args.cache, args.input)
