"""Collector regression tests using small, synthetic markup fixtures."""
import unittest

import jrfu


SCHEDULE = '''<div class="game-schedule"><div class="game-card"><a href="/match/123">
<div class="date">01.02</div><div class="start">12:30</div><div class="headline">Example Cup</div>
<div class="team home"><span class="name">Home</span></div><div class="scoreboard">
<div class="score">12</div><div class="score">0</div></div>
<div class="team away"><span class="name">Away</span></div><div class="stadium">Ground</div>
</a></div></div>'''


PRINT = '''<header><h2>Example Cup Final</h2></header>
<section id="info"><table><tr><th>対戦日</th><td>2025/01/02 （木）</td><th>Kick off</th><td>12:31</td></tr></table></section>
<section id="team"><div class="team home"><table><tr><th class="title">Home</th></tr>
<tr><td class="num">3</td><td class="name">Player A（180/100/21）<div class="in_team">University</div></td><td class="pos" rowspan="2">FW</td></tr>
<tr><td class="num">6</td><td class="name">Player B（180/100/22）</td></tr>
<tr><td class="num">22</td><td class="name">Player C（180/100/22）</td><td class="pos">Re.</td></tr>
</table></div><div class="team away"><table><tr><th class="title">Away</th></tr></table></div>
<table class="score"><tr><th class="ha">前半</th><th class="ha">後半</th><th></th><th>前半</th><th>後半</th></tr>
<tr><td>1</td><td>1</td><th>T</th><td>0</td><td>0</td></tr>
<tr><td>7</td><td>5</td><th>計</th><td>0</td><td>0</td></tr>
<tr><td>12</td><th>合計</th><td>0</td></tr></table></section>
<section id="score"><div><table><tr><th>前半</th><th>Team</th><th>Name</th><th>Type</th><th>H</th><th></th><th>A</th></tr>
<tr><td>2分</td><td>Home</td><td>3.Player A</td><td>T</td><td>5</td><td>-</td><td>0</td></tr></table></div>
<div><table><tr><td>3分</td><td>Home</td><td>6.Player B</td><td>G</td><td>7</td><td>-</td><td>0</td></tr>
<tr><th>後半</th><th>Team</th><th>Name</th><th>Type</th><th>H</th><th></th><th>A</th></tr>
<tr><td>8分</td><td>Home</td><td>3.Player A</td><td>Gx</td><td>12</td><td>-</td><td>0</td></tr></table></div></section>
<section id="change"><div class="home change"><table><tr><th>種類</th><th>時間</th><th>番号</th></tr>
<tr><td>入替</td><td>後半1分</td><td>3 → 22</td></tr></table></div></section>'''


OVERVIEW = '''<div class="game-scoreboard"><div class="game"><div class="team home"><span class="name">Home</span></div>
<div class="scoreboard"><div class="score">52</div><div class="vs"><table class="detailScore">
<tr class="first"><td>21</td><th>前半</th><td>7</td></tr><tr class="second"><td>31</td><th>後半</th><td>0</td></tr></table>
<div class="status -fulltime">試合終了</div></div><div class="score">7</div></div></div>
<table class="scoreStats"><tr><th>T</th><th>G</th><th>PT</th><th>PG</th><th>DG</th><th> </th><th>T</th><th>G</th><th>PT</th><th>PG</th><th>DG</th></tr>
<tr><td>3</td><td>3</td><td>0</td><td>0</td><td>0</td><td class="half">前半 </td><td>1</td><td>1</td><td>0</td><td>0</td><td>0</td></tr>
<tr><td>5</td><td>3</td><td>0</td><td>0</td><td>0</td><td class="half">後半 </td><td>0</td><td>0</td><td>0</td><td>0</td><td>0</td></tr></table></div>
<div class="l-full game-info"><table><tr><td class="-w30">対戦日</td><td>2020/01/02 （木） </td></tr>
<tr><td class="-w30">Kick off</td><td>12:20</td></tr><tr><td class="-w30">競技場</td><td>秩父宮ラグビー場</td></tr></table></div>'''


class CollectorTests(unittest.TestCase):
    def summary(self):
        return jrfu.parse_schedule(SCHEDULE, 2025, "大学", "2026-09-24T00:00:00Z")[0]

    def test_numeric_category_slugs(self):
        self.assertEqual(jrfu.categories('<option value="/schedule/u20">U20日本代表</option>'), {"u20": "U20日本代表"})

    def test_primary_category_is_specific_in_both_completion_orders(self):
        specific = dict(self.summary(), category="大学", categories=["大学"])
        broad = dict(specific, category="その他", categories=["その他"])
        for first, second in ((specific, broad), (broad, specific)):
            result = jrfu.preferred_summary(first, second)
            self.assertEqual(result["category"], "大学")
            self.assertEqual(set(result["categories"]), {"大学", "その他"})

    def test_zero_score_and_missing_scores_are_distinct(self):
        self.assertEqual(self.summary()["awayScore"], 0)
        record = jrfu.parse_schedule(SCHEDULE.replace('class="score">12', 'class="score">').replace('class="score">0', 'class="score">'), 2025, "大学")[0]
        self.assertIsNone(record["homeScore"])
        self.assertIsNone(record["awayScore"])
        self.assertEqual(record["status"], "scheduled")

    def test_print_scores_players_and_cross_column_events(self):
        record = jrfu.parse_print(PRINT, self.summary())
        self.assertEqual(record["homeFirstHalfScore"], 7)
        self.assertEqual(record["awaySecondHalfScore"], 0)
        self.assertEqual(record["players"][0]["name"], "Player A")
        self.assertEqual(record["players"][1]["position"], "FW")
        self.assertEqual(record["players"][2]["role"], "リザーブ")
        self.assertEqual([x["period"] for x in record["scoreEvents"]], ["前半", "前半", "後半"])
        self.assertEqual(record["scoreEvents"][-1]["kind"], "Gx")
        self.assertEqual(record["substitutions"][0]["incoming"], "Player C")

    def test_sevens_blank_position_means_starter(self):
        # 7人制の表は行ごとに Pos. のセルがあり、空欄が先発。上の行の「Re.」を引き継がない
        sevens = PRINT.replace(
            '<tr><td class="num">3</td><td class="name">Player A（180/100/21）<div class="in_team">University</div></td><td class="pos" rowspan="2">FW</td></tr>\n'
            '<tr><td class="num">6</td><td class="name">Player B（180/100/22）</td></tr>\n'
            '<tr><td class="num">22</td><td class="name">Player C（180/100/22）</td><td class="pos">Re.</td></tr>',
            '<tr><td class="num">1</td><td class="name">Player A（160/60/21）</td><td class="pos">Re.</td></tr>\n'
            '<tr><td class="num">2</td><td class="name">Player B（160/60/22）</td><td class="pos"></td></tr>\n'
            '<tr><td class="num">3</td><td class="name">Player C（160/60/22）</td><td class="pos"></td></tr>')
        record = jrfu.parse_print(sevens, self.summary())
        self.assertEqual([p["role"] for p in record["players"]], ["リザーブ", "先発", "先発"])
        self.assertEqual(record["players"][1]["position"], "")

    def test_expired_record_keeps_match_page_breakdown(self):
        with self.assertRaisesRegex(ValueError, "掲載期間"):
            jrfu.parse_print('<html><title>コンテンツの掲載期間が終了しました</title></html>', self.summary())
        record = jrfu.parse_overview(OVERVIEW, self.summary(), "2026-10-04T00:00:00Z")
        self.assertEqual(record["detailLevel"], "summary")
        self.assertEqual((record["homeScore"], record["awayScore"]), (52, 7))
        self.assertEqual((record["homeFirstHalfScore"], record["awayFirstHalfScore"]), (21, 7))
        self.assertEqual(record["awaySecondHalfScore"], 0)
        self.assertEqual(record["date"], "2020-01-02")
        self.assertEqual(record["venue"], "秩父宮ラグビー場")
        self.assertIn(dict(label="後半 T", home="5", away="0"), record["stats"])
        self.assertEqual(len(record["stats"]), 10)
        self.assertEqual(record["players"], [])

    def test_not_an_official_record_is_rejected(self):
        with self.assertRaises(ValueError):
            jrfu.parse_print('<html><title>Not Found</title></html>', self.summary())


if __name__ == "__main__":
    unittest.main()
