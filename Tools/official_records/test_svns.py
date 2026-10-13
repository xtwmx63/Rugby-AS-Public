import unittest
from svns import parse_match, event_clock, series_in_scope
from build_archive import validate_match


class SVNSTests(unittest.TestCase):
    def fixture(self):
        match = dict(matchId='42', matchAltId='match-42', status='C', scores=[7, 0],
                     time=dict(millis=1631980800000, gmtOffset=-7, label='2021-09-18'),
                     teams=[dict(name='Japan 7s'), dict(name='Fiji 7s')])
        event = dict(id='1', altId='event-1', label='Sevens Series 2022 - Dubai', start=dict(label='2021-11-26'))
        series = dict(name='Sevens Series 2022', mainSeason=2022, sport='wrs')
        stats = dict(teamStats=[dict(stats={'Tries': 1}, playerStats=[dict(player=dict(id='p1', name=dict(display='A')),
                            number='23', position='For', stats={})]),
                    dict(stats={'Tries': 0}, playerStats=[dict(player=dict(id='p2', name=dict(display='B')),
                            number='12', position='Rep', stats={})])])
        timeline = dict(timeline=[dict(type='T5', phase='L2', time=dict(secs=648), teamIndex=0, playerId='p1', points=5),
                                  dict(type='C2', phase='L2', time=dict(secs=690), teamIndex=0, playerId='p1', points=2)])
        return match, event, series, stats, timeline

    def parse(self, values):
        return parse_match(*values, None, '2026-10-02T00:00:00Z')

    def test_timezone_gender_clock_and_roster(self):
        record = self.parse(self.fixture())
        validate_match(record, 'fixture')
        self.assertEqual((record['date'], record['kickoff'], record['kickoffUTC']),
                         ('2021-09-18', '09:00', '2021-09-18T16:00:00Z'))
        self.assertEqual(record['season'], '2022')
        self.assertEqual(record['category'], 'HSBC SVNS 女子')
        self.assertIn('女子 2021-11-26', record['tournament'])
        self.assertEqual(record['players'][0]['role'], '先発')  # number 23 is still a starter
        self.assertEqual(record['players'][1]['role'], 'リザーブ')
        self.assertEqual(record['scoreEvents'][0]['time'], '4分')
        self.assertEqual(record['scoreEvents'][0]['matchSeconds'], 648)
        self.assertEqual(record['homeFirstHalfScore'], 0)
        self.assertEqual(record['homeSecondHalfScore'], 7)
        self.assertEqual(record['detailLevel'], 'full')

    def test_missing_is_not_zero_or_invented(self):
        values = list(self.fixture()); values[3] = values[4] = None
        record = self.parse(values)
        self.assertEqual(record['detailLevel'], 'summary')
        self.assertIsNone(record['homeFirstHalfScore'])
        self.assertEqual(record['players'], [])
        self.assertEqual(len(record['omissions']), 2)
        values = list(self.fixture()); values[0]['status'] = 'CC'; values[0]['scores'] = [0, 0]
        record = self.parse(values)
        self.assertEqual(record['status'], 'cancelled')
        self.assertIsNone(record['homeScore'])
        self.assertEqual(record['sourceScores'], [0, 0])

    def test_source_score_mismatch_is_preserved_and_flagged(self):
        values = self.fixture(); values[0]['scores'] = [12, 0]
        record = self.parse(values)
        self.assertEqual(record['homeScore'], 12)
        self.assertEqual(len(record['scoreEvents']), 2)
        self.assertIsNone(record['scoreEvents'][0]['homeScore'])
        self.assertEqual(record['detailLevel'], 'summary')
        self.assertTrue(record['omissions'])

    def test_ambiguous_substitutions_not_paired(self):
        values = self.fixture()
        for kind in ('Sub On', 'Sub On', 'Sub Off', 'Sub Off'):
            values[4]['timeline'].append(dict(type=kind, phase='L2', time=dict(secs=500), teamIndex=0, playerId='p1'))
        record = self.parse(values)
        self.assertEqual(len(record['substitutions']), 4)
        self.assertTrue(all(not r['incoming'] or not r['outgoing'] for r in record['substitutions']))
        values[4]['timeline'] = values[4]['timeline'][:2] + values[4]['timeline'][3:5]
        record = self.parse(values)
        self.assertEqual(len(record['substitutions']), 1)
        self.assertEqual(record['substitutions'][0]['kind'], '交代')

    def test_extra_time_and_half_time(self):
        self.assertEqual(event_clock(dict(phase='L3', time=dict(secs=993)))['time'], '10分')
        self.assertEqual(event_clock(dict(phase='LHT', time=dict(secs=840)))['time'], '0分')

    def test_unknown_source_phase_does_not_invent_time_or_halves(self):
        values = self.fixture()
        values[4]['timeline'][0]['phase'] = 'C'
        record = self.parse(values)
        validate_match(record, 'unknown clock')
        self.assertEqual(record['homeScore'], 7)
        self.assertIsNone(record['homeFirstHalfScore'])
        self.assertIsNone(record['homeSecondHalfScore'])
        self.assertTrue(all(e['homeScore'] is None for e in record['scoreEvents']))
        self.assertEqual(record['scoreEvents'][-1]['time'], '')
        self.assertTrue(any('時刻・時間帯' in message for message in record['omissions']))

    def test_extra_time_not_reported_as_regulation_second_half(self):
        values = self.fixture()
        values[4]['timeline'][0].update(phase='L3', time={'secs': 900})
        values[4]['timeline'][1].update(phase='L3', time={'secs': 930})
        record = self.parse(values)
        self.assertEqual(record['homeFirstHalfScore'], 0)
        self.assertIsNone(record['homeSecondHalfScore'])
        self.assertEqual(record['scoreEvents'][-1]['homeScore'], 7)

    def test_linked_substitutions_and_unpublished_clock(self):
        values = self.fixture()
        for kind, link in [('Sub On', 10), ('Sub Off', 10), ('Sub On', 20), ('Sub Off', 20)]:
            values[4]['timeline'].append(dict(type=kind, phase='C', time=dict(secs=0), teamIndex=0, playerId='p1', link=link))
        record = self.parse(values)
        self.assertEqual(len(record['substitutions']), 2)
        self.assertTrue(all(e['incoming'] and e['outgoing'] for e in record['substitutions']))
        self.assertTrue(all(e['time'] == '' for e in record['substitutions']))
        self.assertTrue(any('交代時刻' in message for message in record['omissions']))

    def test_same_clock_try_before_conversion_and_actual_points(self):
        values = self.fixture()
        values[4]['timeline'][0]['time'] = values[4]['timeline'][1]['time']
        values[4]['timeline'].reverse()
        record = self.parse(values)
        self.assertEqual([e['kind'] for e in record['scoreEvents']], ['T', 'G'])
        self.assertEqual([e['points'] for e in record['scoreEvents']], [5, 2])

    def test_series_scope(self):
        for name in ('Sevens Series 2021', "Women's Sevens Series 2022", 'HSBC SVNS 2 2026',
                     '1999-00 IRB Sevens World Series', '2014-15 HSBC Mens Sevens World Series'):
            self.assertTrue(series_in_scope(dict(name=name, mainSeason=2022, sport='wrs'), 2021))
        for name in ('Olympic Games 2021', 'Challenger Sevens Series 2022'):
            self.assertFalse(series_in_scope(dict(name=name, mainSeason=2022, sport='wrs'), 2021))


if __name__ == '__main__':
    unittest.main()
