import copy
import json
from pathlib import Path
import tempfile
import unittest

from rwc import parse_match, event_clock, in_scope, score_kind
from build_archive import validate_match, assemble

FIXTURE = json.loads((Path(__file__).parent / 'fixtures/rwc-1991-final.json').read_text())


class WorldCupTests(unittest.TestCase):
    def parse(self, fixture=None, stats=None):
        f = fixture or copy.deepcopy(FIXTURE)
        return parse_match(f['match'], f['event'], f['summary'], f['timeline'], stats, '2026-10-03T00:00:00Z')

    def test_historic_final(self):
        record = self.parse()
        validate_match(record, '1991 final')
        self.assertEqual((record['homeScore'], record['awayScore']), (6, 12))
        self.assertEqual((record['homeFirstHalfScore'], record['awayFirstHalfScore']), (0, 9))
        self.assertEqual(record['scoreEvents'][-1]['awayScore'], 12)
        tries = [e for e in record['scoreEvents'] if e['kind'] == 'T4']
        self.assertEqual([(e['player'], e['points']) for e in tries], [('Tony Daly', 4)])
        self.assertEqual(record['detailLevel'], 'full')
        self.assertEqual(len(record['players']), 42)
        self.assertNotIn('Ian Lambie', [p['name'] for p in record['players']])
        self.assertEqual(sum(p['role'] == '先発' for p in record['players']), 30)

    def test_summary_fallback_preserves_side_and_four_point_try(self):
        f = copy.deepcopy(FIXTURE); f['timeline'] = None
        record = self.parse(f)
        self.assertEqual((record['scoreEvents'][-1]['homeScore'], record['scoreEvents'][-1]['awayScore']), (6, 12))
        self.assertEqual(next(e for e in record['scoreEvents'] if e['kind'] == 'T4')['side'], 'away')
        self.assertEqual(record['scoreEvents'][1]['kind'], 'T4')
        self.assertEqual(record['scoreEvents'][2]['kind'], 'G')

    def test_partial_timeline_never_fabricates_cumulative_scores(self):
        f = copy.deepcopy(FIXTURE); f['timeline']['timeline'].pop()
        record = self.parse(f)
        self.assertEqual(record['detailLevel'], 'summary')
        self.assertIsNone(record['homeFirstHalfScore'])
        self.assertTrue(all(e['homeScore'] is None and e['awayScore'] is None for e in record['scoreEvents']))
        self.assertEqual(record['homeScore'], 6)
        self.assertTrue(record['omissions'])

    def test_unknown_scoring_period_does_not_invent_half_or_cumulative_scores(self):
        f = copy.deepcopy(FIXTURE)
        f['timeline']['timeline'][1]['phase'] = None
        f['timeline']['timeline'][1]['time'] = {'secs': 0}
        record = self.parse(f)
        validate_match(record, 'unknown scoring period')
        self.assertEqual(record['awayScore'], 12)
        self.assertIsNone(record['homeFirstHalfScore'])
        self.assertIsNone(record['awaySecondHalfScore'])
        self.assertTrue(all(e['homeScore'] is None and e['awayScore'] is None for e in record['scoreEvents']))
        self.assertIn('時刻・時間帯が未掲載', ' '.join(record['omissions']))

    def test_penalty_try_rules(self):
        self.assertEqual(score_kind({'type': 'PT5', 'points': 5}, 2015), ('PT5', 5))
        self.assertEqual(score_kind({'type': 'PT7', 'points': 7}, 2019), ('PT', 7))
        self.assertEqual(score_kind({'type': 'PT5', 'points': None}, 1991), ('PT4', 4))

    def test_clock_and_extra_time(self):
        self.assertEqual(event_clock({'phase': 'L2', 'time': {'secs': 3660}})['time'], '21分')
        self.assertEqual(event_clock({'phase': 'LHT', 'time': {'secs': 2400}})['time'], '0分')
        self.assertEqual(event_clock({'phase': 'L4', 'time': {'secs': 6000}})['time'], '60分')
        f = copy.deepcopy(FIXTURE)
        f['timeline']['timeline'][-1]['phase'] = 'L4'
        f['timeline']['timeline'][-1]['time']['secs'] = 6000
        record = self.parse(f)
        self.assertIsNone(record['homeSecondHalfScore'])
        self.assertEqual(record['scoreEvents'][-1]['time'], '60分')

    def test_ambiguous_substitutions_not_invented(self):
        f = copy.deepcopy(FIXTURE)
        base = dict(phase='L2', time={'secs': 3600}, teamIndex=0)
        f['timeline']['timeline'] += [dict(base, type=kind, playerId=pid) for kind, pid in
            [('Sub On', '1725'), ('Sub Off', '1485'), ('Sub On', '1766'), ('Sub Off', '1714')]]
        record = self.parse(f)
        self.assertEqual(len(record['substitutions']), 4)
        self.assertTrue(all(not (e['incoming'] and e['outgoing']) for e in record['substitutions']))

    def test_source_link_pairs_same_minute_changes_and_missing_clock(self):
        f = copy.deepcopy(FIXTURE)
        base = dict(phase=None, time={'secs': 0}, teamIndex=0)
        f['timeline']['timeline'] += [dict(base, type=kind, playerId=pid, link=link) for kind, pid, link in
            [('Sub On', '1725', 1), ('Sub Off', '1485', 1), ('Sub On', '1766', 2), ('Sub Off', '1714', 2)]]
        record = self.parse(f)
        validate_match(record, 'unknown substitution time')
        self.assertEqual(len(record['substitutions']), 2)
        self.assertTrue(all(e['incoming'] and e['outgoing'] for e in record['substitutions']))
        self.assertTrue(all(e['time'] == '' and e['period'] == '' for e in record['substitutions']))
        self.assertIn('交代時刻が未掲載', ' '.join(record['omissions']))

    def test_cancelled_matches_keep_missing_scores(self):
        f = copy.deepcopy(FIXTURE)
        f['match'].update(status='CC', scores=[0, 0])
        f['summary'] = f['timeline'] = None
        record = self.parse(f)
        self.assertIsNone(record['homeScore']); self.assertIsNone(record['awayScore'])
        self.assertEqual(record['sourceScores'], [0, 0])
        self.assertEqual(record['status'], 'cancelled')

    def test_postponed_edition_and_zero_stats(self):
        f = copy.deepcopy(FIXTURE)
        f['event'].update(label='Rugby World Cup 2021', sport='wru')
        f['match']['time'] = dict(millis=1668249000000, gmtOffset=13, label='2022-11-12')
        record = self.parse(f, {'teamStats': [{'stats': {'Tackles': 0}}, {'stats': {}}]})
        self.assertEqual((record['year'], record['season'], record['date']), (2021, '2021', '2022-11-12'))
        self.assertEqual(record['category'], 'ラグビーワールドカップ 女子')
        self.assertEqual(record['stats'], [dict(label='Tackles', home='0', away='')])
        self.assertEqual(record['kickoffUTC'], '2022-11-12T10:30:00Z')

    def test_discovery_excludes_qualifiers_and_sevens(self):
        e = copy.deepcopy(FIXTURE['event'])
        self.assertTrue(in_scope(e, 2025))
        for name in ['1991 Rugby World Cup Qualifying (Q)', 'Rugby World Cup 2023 Final Qualification Tournament', 'Rugby World Cup Sevens 2022']:
            e['label'] = name
            self.assertFalse(in_scope(e, 2025))
        e.update(label="Men's Rugby World Cup 2027", start={'label': '2027-10-01'})
        self.assertFalse(in_scope(e, 2025))

    def test_new_source_can_build_archive(self):
        record = self.parse()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'rwc.json'
            path.write_text(json.dumps(dict(matches=[record], coverage=[], errors=[])))
            assemble([path], Path(directory) / 'archive.sqlite')


if __name__ == '__main__':
    unittest.main()
