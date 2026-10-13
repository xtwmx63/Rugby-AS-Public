#!/usr/bin/env python3
"""Independently check an RWC export against cached official schedule/detail facts."""
import argparse
from collections import Counter
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path


def audit(cache, export):
    data = json.loads(export.read_text())
    records = {r['sourceMatchID']: r for r in data['matches']}
    assert len(records) == len(data['matches']), 'Duplicate official match IDs'
    expected, counts = set(), Counter()
    complete, partial = 0, 0
    for event in json.loads((cache / 'catalog.json').read_text()):
        for match in event['matches']:
            identifier = match.get('matchAltId') or match['matchId']
            expected.add(identifier)
            record = records[identifier]
            counts[(event['event']['sport'], record['season'])] += 1
            assert [record['homeTeam'], record['awayTeam']] == [t['name'] for t in match['teams']], identifier
            if record['status'] == 'cancelled':
                assert record['homeScore'] is record['awayScore'] is None, identifier
                continue
            assert [record['homeScore'], record['awayScore']] == match['scores'], identifier
            clock = match['time']
            local = datetime.fromtimestamp(clock['millis']/1000, timezone.utc).astimezone(timezone(timedelta(hours=clock.get('gmtOffset') or 0)))
            assert (record['date'], record['kickoff']) == (local.strftime('%Y-%m-%d'), local.strftime('%H:%M')), identifier
            summary = json.loads((cache / f'match-{identifier}-summary.json').read_text())
            timeline = json.loads((cache / f'match-{identifier}-timeline.json').read_text())
            stats = json.loads((cache / f'match-{identifier}-stats.json').read_text())
            for kind, source in [('summary', summary), ('timeline', timeline), ('stats', stats)]:
                if source and source.get('match'):
                    assert source['match']['scores'] == match['scores'], (identifier, kind, 'schedule/detail scores differ')
            if summary and summary.get('teams'):
                for i, side in enumerate(('home', 'away')):
                    source_players = (summary['teams'][i].get('teamList') or {}).get('list') or []
                    names = [(p.get('player') or {}).get('name', {}).get('display') for p in source_players
                             if (p.get('player') or {}).get('role') in (None, 'Player')]
                    names = [n for n in names if n]
                    if names:
                        assert Counter(names) == Counter(p['name'] for p in record['players'] if p['side'] == side), identifier
            raw_scores = [e for e in (timeline or {}).get('timeline', []) if (e.get('points') or 0) > 0]
            if raw_scores:
                parsed = [e for e in record['scoreEvents'] if e['points'] > 0]
                assert len(raw_scores) == len(parsed), (identifier, 'scoring-event count')
                assert sum(e['points'] for e in raw_scores) == sum(e['points'] for e in parsed), (identifier, 'historical points')
            if record['detailLevel'] == 'full':
                for side, score in zip(('home', 'away'), match['scores']):
                    assert sum(e['points'] for e in record['scoreEvents'] if e['side'] == side) == score, identifier
                complete += 1
            else:
                partial += 1
                assert record['omissions'], identifier
    assert set(records) == expected, 'Schedule/export match set differs'
    assert sum(c['imported'] for c in data['coverage']) == len(records)
    print(f'PASS: {len(records)} official schedules, {complete} complete details, {partial} partial details; 3 source endpoints checked per played match')
    for (sport, season), count in sorted(counts.items()):
        print(sport, season, count)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    parser.add_argument('--input', required=True, type=Path)
    args = parser.parse_args()
    audit(args.cache, args.input)
