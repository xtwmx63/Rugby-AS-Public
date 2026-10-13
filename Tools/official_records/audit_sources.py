#!/usr/bin/env python3
"""Compare collected facts to locally cached official HTML (no network)."""
import argparse
import json
from pathlib import Path
import re
from bs4 import BeautifulSoup


def audit(payload, cache, prefix):
    checked, problems = 0, []
    for match in payload['matches']:
        if match['detailLevel'] != 'full':
            continue
        html = cache / f"{prefix}{match['sourceMatchID']}.html"
        soup = BeautifulSoup(html.read_text(encoding='utf-8'), 'html.parser')
        roster = 0
        for cell in soup.select('#team .team td.name'):
            # Blank roster slots may contain only the site's (0/0/0) placeholder.
            value = cell.get_text(' ', strip=True)
            if value and not re.fullmatch(r'[（(][\d\s/]+[）)]', value):
                roster += 1
        events = sum(len(row.find_all('td', recursive=False)) == 7 for row in soup.select('#score tr'))
        if roster != len(match['players']):
            problems.append((match['id'], 'roster count', roster, len(match['players'])))
        if events != len(match['scoreEvents']):
            problems.append((match['id'], 'scoring row count', events, len(match['scoreEvents'])))
        score = {'home': 0, 'away': 0}
        for event in match['scoreEvents']:
            points = {'T': 5, 'G': 2, 'PG': 3, 'DG': 3, 'PT': 7,
                      'Gx': 0, 'PGx': 0, 'DGx': 0}.get(event['kind'])
            if event['side'] not in score or points is None:
                problems.append((match['id'], 'unrecognized scoring event', event))
                continue
            score[event['side']] += points
            if [score['home'], score['away']] != [event['homeScore'], event['awayScore']]:
                problems.append((match['id'], 'running score', event))
        if match['scoreEvents'] and [score['home'], score['away']] != [match['homeScore'], match['awayScore']]:
            problems.append((match['id'], 'final score', score))
        checked += 1
    return checked, problems


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--source', choices=['jrfu', 'leagueone'], required=True)
    args = parser.parse_args()
    data = json.loads(args.input.read_text(encoding='utf-8'))
    checked, problems = audit(data, args.cache, 'print-' if args.source == 'jrfu' else 'league-print-')
    print(json.dumps({'source': args.source, 'checkedFullRecords': checked, 'problems': problems}, ensure_ascii=False, indent=2))
    raise SystemExit(1 if problems else 0)
