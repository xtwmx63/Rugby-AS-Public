"""Regression cases found in official schedule/print formats; synthetic facts."""
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
import leagueone

STAMP = "2026-09-24T00:00:00Z"
SCHEDULE = '''<div class="c-schedule"><h3 class="ttl">NTTリーグワン 2025-26 ディビジョン1<br>第5節 (2026D10501)</h3>
<p class="date">01.17 土</p><p class="time">14:00</p><p class="place">Ground</p>
<ul class="game"><li class="home"><p class="name only-pc">Home</p><p class="name only-sp">H</p><p class="score">5</p></li>
<li class="away"><p class="name only-pc">Away</p><p class="name only-sp">A</p><p class="score">0</p></li></ul>
<a class="btn-match-detail" href="/match/123">詳細情報 (試合終了)</a></div>'''
PRINT = '''<section id="info"><table class="info1"><tr><th>対戦日</th><td>2026/01/17</td></tr></table></section>
<section id="team"><div class="team home"><table><tr><th class="title">Home</th></tr>
<tr><td class="num">11</td><td class="name">Player A（180/90/25）</td><td class="pos">WTB</td></tr></table></div>
<div class="team away"><table><tr><th class="title">Away</th></tr><tr><td class="num">10</td><td class="name">Player B（180/90/25）</td><td class="pos">SO</td></tr></table></div>
<table class="score"><tr><td>5</td><td>0</td><th class="tp">計</th><td>0</td><td>0</td></tr><tr><td>5</td><th class="tp">合計</th><td>0</td></tr></table></section>
<section id="change"><div class="home change"><table><tr><td>退出</td><td>後半40分</td><td>11</td></tr></table></div></section>
<section id="score"><table><tr><th>前半</th><th>チーム名</th><th>#.Name</th><th>種</th><th>H</th><th></th><th>V</th></tr>
<tr><td>2分</td><td>H</td><td>11.Player A</td><td>T</td><td>5</td><td>-</td><td>0</td></tr></table>
<table><tr><td>3分</td><td>H</td><td>11.Player A</td><td>Gx</td><td>5</td><td>-</td><td>0</td></tr></table></section>'''


class LeagueOneTests(unittest.TestCase):
    def summary(self):
        return leagueone.parse_schedule(SCHEDULE, 2025, STAMP)[0]

    def test_season_start_is_not_calendar_date_year(self):
        record = self.summary()
        self.assertEqual((record['year'], record['season'], record['date']), (2025, '2025–26', '2026-01-17'))
        self.assertEqual(record['awayScore'], 0)
        missing = leagueone.parse_schedule(SCHEDULE.replace('class="score">0', 'class="score">'), 2025, STAMP)[0]
        self.assertIsNone(missing['awayScore'])

    def test_withdrawal_does_not_discard_the_whole_match(self):
        record = leagueone.parse_print(PRINT, self.summary(), STAMP)
        self.assertEqual(record['detailLevel'], 'full')
        self.assertEqual(record['substitutions'][0]['incoming'], '')
        self.assertEqual(record['substitutions'][0]['outgoing'], '11. Player A')
        self.assertEqual(record['players'][0]['name'], 'Player A')
        self.assertEqual(record['awayFirstHalfScore'], 0)

    def test_old_match_codes_use_the_round_calendar_range(self):
        schedule = SCHEDULE.replace('(2026D10501)', '(D1-M9)')
        for day, bounds, expected in [
            ('12.17', '2022.12.17〜2022.12.18', '2022-12-17'),
            ('01.17', '2023.01.14〜2023.01.17', '2023-01-17'),
            ('01.01', '2022.12.31〜2023.01.01', '2023-01-01'),
        ]:
            with self.subTest(day=day):
                html = f'<h2 class="ttl">第1節 ({bounds})</h2>' + schedule.replace('01.17', day)
                record = leagueone.parse_schedule(html, 2022, STAMP)[0]
                self.assertEqual((record['year'], record['season'], record['date']),
                                 (2022, '2022–23', expected))
        with self.assertRaises(ValueError):
            leagueone.parse_schedule(schedule, 2022, STAMP)
        with self.assertRaises(ValueError):
            leagueone.parse_schedule('<h2>2023.02.01〜2023.02.02</h2>' + schedule, 2022, STAMP)

    def test_inaugural_season_uses_2022_despite_selector_key_2021(self):
        html = '<h2>第1節 (2022.01.17〜2022.01.18)</h2>' + SCHEDULE.replace('(2026D10501)', '(D1-M1)')
        record = leagueone.parse_schedule(html, 2021, STAMP)[0]
        self.assertEqual((record['year'], record['season'], record['date']),
                         (2022, '2022', '2022-01-17'))

    def test_cancelled_match_retains_summary_without_fetching_empty_print(self):
        html = SCHEDULE.replace('試合終了', '中止').replace('class="score">5', 'class="score">').replace('class="score">0', 'class="score">')
        with tempfile.TemporaryDirectory() as directory, patch.object(leagueone, 'fetch', return_value=(html, STAMP)) as fetch:
            payload = leagueone.collect(2025, Path(directory), Path(directory) / 'records.json')
        self.assertEqual(fetch.call_count, 1)
        self.assertEqual(payload['errors'], [])
        record = payload['matches'][0]
        self.assertEqual((record['status'], record['detailLevel']), ('cancelled', 'summary'))
        self.assertIsNone(record['homeScore'])
        self.assertEqual(record['players'], [])
        self.assertNotIn('_aliases', record)

    def test_scoring_continuation_keeps_period_and_missed_kicks(self):
        record = leagueone.parse_print(PRINT, self.summary(), STAMP)
        self.assertEqual([(e['period'],e['side'],e['kind']) for e in record['scoreEvents']],
                         [('前半','home','T'),('前半','home','Gx')])

    def test_unrecognized_replacement_is_reported(self):
        with self.assertRaises(ValueError):
            leagueone.parse_print(PRINT.replace('<td>退出</td>', '<td>入替</td>'), self.summary(), STAMP)


if __name__ == '__main__':
    unittest.main()
