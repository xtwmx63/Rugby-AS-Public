"""Top League collector tests using small synthetic markup fixtures."""
import unittest

import topleague


COMPETITION = '''<section class="convention_list"><h2 id="convention-1" class="hl2"><a href="/schedule/convention/1/">リーグ戦</a></h2>
<div class="round open"><h3 class="round_title open_close"><span class="name">第1節</span><span class="date">01/01(木)</span></h3>
<table class="games"><tr id="game-1"><td class="date"><span class="date">09/13</span><span class="kickoff">15:30</span></td>
<td class="site"><a href="/map/detail/17/" title="国立競技場">国立</a></td><td class="teams">
<div class="team"><a><span class="name">サントリー</span></a></div><div class="info"><a class="score" href="/schedule/detail/1/">
<span class="home point">54</span><span class="vs">-</span><span class="away point">31</span></a><div class="audience">観客数：35,000人</div></div>
<div class="team"><a><span class="name">神戸製鋼</span></a></div></td><td class="buttons"><a class="detail" href="/schedule/detail/1/">試合詳細</a></td></tr>
<tr id="game-2"><td class="date"><span class="date">01/14</span><span class="kickoff">13:00</span></td><td class="site"><a title="花園">花園</a></td>
<td class="teams"><div class="team"><a><span class="name">近鉄</span></a></div><div class="info"></div>
<div class="team"><a><span class="name">NEC</span></a></div></td></tr></table></div></section>'''

DETAIL = '''<section id="game"><div class="scores"><div id="home-total-score" class="home score">28</div>
<div id="away-total-score" class="away score">25</div><ul id="score-detail" class="half">
<li><span class="label">前半</span><div class="home score">13</div><div class="away score">22</div></li>
<li><span class="label">後半</span><div class="home score">12</div><div class="away score">3</div></li>
<li><span class="label">延長 前半</span><div class="home score">3</div><div class="away score">0</div></li></ul></div>
<table id="score-stats" class="stats"><tr><th>T</th><th>G</th><th>PT</th><th>PG</th><th>DG</th><th class="half"></th><th>T</th><th>G</th><th>PT</th><th>PG</th><th>DG</th></tr>
<tr><td>1</td><td>1</td><td>0</td><td>2</td><td>0</td><td>前半</td><td>3</td><td>2</td><td>0</td><td>1</td><td>0</td></tr></table>
<table id="score-timeline" class="timeline">
<tr><td class="home try"><a>選手A</a></td><th class="status"><p class="time">5’</p><p class="scores"><span class="score">5</span><span class="vs">-</span><span class="score">0</span></p></th><td class="away"></td></tr>
<tr><td class="home gx"><a>選手B</a></td><th class="status"><p class="time">6’</p><p class="scores"><span class="score">5</span><span class="vs">-</span><span class="score">0</span></p></th><td class="away"></td></tr>
<tr><td class="home"></td><th class="status"><p class="time">20’</p><p class="scores"><span class="score">5</span><span class="vs">-</span><span class="score">0</span></p></th><td class="away yellow"><a>選手Y</a></td></tr>
<tr><td class="home"></td><th class="status"><p class="half"><span>前半</span><span>終了</span></p></th><td class="away"></td></tr>
<tr><td class="home change"><p class="o"><a>選手A</a></p><p class="i"><a>選手C</a></p></td><th class="status"><p class="time">10’</p><p class="scores"><span class="score">5</span><span class="vs">-</span><span class="score">0</span></p></th><td class="away"></td></tr>
<tr><td class="home"></td><th class="status"><p class="half"><span>後半</span><span>終了</span></p></th><td class="away"></td></tr>
<tr><td class="home pg"><a>選手B</a></td><th class="status"><p class="time">5’</p><p class="scores"><span class="score">28</span><span class="vs">-</span><span class="score">25</span></p></th><td class="away"></td></tr>
</table></section>
<div class="member"><div class="home"><h3>サントリーサンゴリアス</h3><table class="starting"><tr><th colspan="3">スターティングメンバー</th></tr>
<tr><td class="position">FW</td><td class="number">1</td><td class="name"><a>選手A</td></tr>
<tr><td class="position"></td><td class="number">2</td><td class="name"><a>選手D</td></tr></table>
<table class="starting"><tr><th colspan="3">リザーブメンバー</th></tr><tr><td class="position"></td><td class="number">16</td><td class="name in"><a>選手C</td></tr></table></div>
<div class="away"><h3>神戸製鋼 コベルコスティーラーズ</h3><table class="starting"><tr><th colspan="3">スターティングメンバー</th></tr>
<tr><td class="position">FW</td><td class="number">1</td><td class="name"><a>選手E</td></tr></table></div></div>
<div class="information"><table><tr><th>対戦日</th><td>2019/01/05(土)</td></tr><tr><th>Kick off</th><td>12:00</td></tr>
<tr><th>競技場</th><td>秩父宮</td></tr><tr><th>レフリー</th><td>審判X</td></tr></table></div>'''


class TopLeagueTests(unittest.TestCase):
    def rows(self):
        return topleague.parse_competition(COMPETITION, 2003, "2026-10-05T00:00:00Z")

    def test_competition_rows(self):
        played, unplayed = self.rows()
        self.assertEqual(played["tournament"], "ジャパンラグビートップリーグ2003-2004 リーグ戦")
        self.assertEqual((played["date"], played["season"], played["year"]), ("2003-09-13", "2003–04", 2003))
        self.assertEqual((played["homeScore"], played["awayScore"], played["status"]), (54, 31, "finished"))
        self.assertEqual(played["venue"], "国立競技場")
        self.assertIn(dict(label="観客数", home="35000", away="35000"), played["stats"])
        # January belongs to the second calendar year; an unplayed fixture is not guessed to be cancelled.
        self.assertEqual(unplayed["date"], "2004-01-14")
        self.assertEqual((unplayed["status"], unplayed["homeScore"]), ("unknown", None))
        self.assertTrue(unplayed["omissions"])

    def test_categories_and_names(self):
        self.assertEqual(topleague.category("トップリーグ入替戦"), "トップリーグ 入替戦")
        self.assertEqual(topleague.category("トップチャレンジシリーズ"), "トップチャレンジ")
        self.assertEqual(topleague.category("トップリーグ オールスター"), "トップリーグ その他")
        self.assertEqual(topleague.category("プレーオフトーナメント マイクロソフトカップ"), "トップリーグ")
        self.assertEqual(topleague.tournament_name("トップリーグ2021リーグ戦", 2020), "トップリーグ2021リーグ戦")

    def test_detail_with_extra_time(self):
        record = topleague.parse_detail(DETAIL, self.rows()[0], "2026-10-05T00:00:00Z")
        self.assertEqual(record["detailLevel"], "full")
        self.assertEqual((record["homeScore"], record["awayScore"]), (28, 25))
        self.assertEqual((record["homeFirstHalfScore"], record["awaySecondHalfScore"]), (13, 3))
        self.assertIn(dict(label="延長 前半 得点", home="3", away="0"), record["stats"])
        self.assertEqual([e["kind"] for e in record["scoreEvents"]], ["T", "Gx", "PG"])
        self.assertEqual([e["period"] for e in record["scoreEvents"]], ["前半", "前半", "延長"])
        self.assertEqual(record["substitutions"][0], dict(side="home", period="後半", time="10", kind="入替",
                                                           outgoing="選手A", incoming="選手C"))
        self.assertEqual([(p["role"], p["position"]) for p in record["players"] if p["side"] == "home"],
                         [("先発", "FW"), ("先発", "FW"), ("リザーブ", "")])
        self.assertEqual(record["homeTeam"], "サントリーサンゴリアス")
        self.assertEqual((record["date"], record["kickoff"], record["venue"]), ("2019-01-05", "12:00", "国立競技場"))
        self.assertTrue(any(s["label"].startswith("イエローカード") and s["away"] == "選手Y" for s in record["stats"]))
        self.assertNotIn("omissions", record)

    def test_old_penalty_try_is_five_points(self):
        old = DETAIL.replace('<td class="home try"><a>選手A</a>', '<td class="home pt"><a>ペナルティトライ</a>')
        old = old.replace('<td class="home gx"><a>選手B</a></td><th class="status"><p class="time">6’</p><p class="scores"><span class="score">5</span>',
                          '<td class="home goal"><a>選手B</a></td><th class="status"><p class="time">6’</p><p class="scores"><span class="score">9</span>')
        summary = dict(self.rows()[0], year=2016)
        record = topleague.parse_detail(old.replace(">28</div>", ">10</div>", 1).replace(">25</div>", ">0</div>", 1), summary, "x")
        self.assertEqual([(e["kind"], e["homeScore"]) for e in record["scoreEvents"]], [("PT5", 5), ("G", 7), ("PG", 10)])
        self.assertTrue(any("5点" in note for note in record["omissions"]))
        modern = topleague.parse_detail(old, dict(self.rows()[0], year=2017), "x")
        self.assertEqual(modern["scoreEvents"][0]["kind"], "PT")

    def test_missing_detail_is_rejected(self):
        with self.assertRaises(ValueError):
            topleague.parse_detail("<html></html>", self.rows()[0], "x")


if __name__ == "__main__":
    unittest.main()
