# 公式記録データベース

> **配布について:** 日本ラグビーフットボール協会・リーグワンの利用規約では、掲載情報の複製・配布に事前の許可が必要です。そのため、このリポジトリには収集したデータ（`OfficialRecords.sqlite`）を含めていません。公式記録タブは開発版(Debug)だけで有効になり、App Store 用の Release ビルドには含めません（画面は `#if DEBUG`、DBは Release の `EXCLUDED_SOURCE_FILE_NAMES` で除外）。

Rugby ASの「公式記録」は、公式サイトに掲載された試合の事実情報を検索するための、アプリ同梱のSQLiteデータベースです。個人の試合・チーム・選手を保存するSwiftDataとは別に、読み取り専用で開きます。試合詳細の「この試合を取り込む」から、内容を確認したうえで自分の試合として保存できます。

## DBファイルの扱い

`Rugby AS/OfficialRecords.sqlite` は Git で管理していません（`.gitignore` 済み）。手元で使う場合は、下の「再取得と再生成」の手順で各自作成してください。DBがない状態では開発版(Debug)のビルドが「ファイルがない」で失敗します（Release版はもともとDBを含みません）。

## 収録範囲

- 日本ラグビーフットボール協会：2003〜2026年の全カテゴリーの日程・結果一覧からたどれる試合（2002年以前は掲載なし）。2020年以前の大半は公式記録票の掲載が終わっているため、試合ページの前後半得点と得点内訳（T/G/PT/PG/DG）までです。
- リーグワン：2022、2022–23、2023–24、2024–25、2025–26の全5シーズンのD1・D2・D3・入替戦。D1にはプレーオフを含みます。
- ジャパンラグビートップリーグ（リーグワンの前身）：2003–04〜2020–21の全18シーズン。リーグ戦・マイクロソフトカップ／プレーオフ・ワイルドカード・カップ戦・順位決定・入替戦・トップチャレンジ・オールスター等を含みます。
- ラグビーワールドカップ：男子1987〜2023年、女子1991〜2025年の各10大会（公式掲載分）。
- HSBC SVNS：第1回の1999–2000年シーズン〜2026年の男女（旧IRB/HSBC Sevens World Series、旧Sevens Seriesを含む）。2014年シーズン以前は公式APIに詳細がない試合が大半で、概要のみです。
- 掲載元に記録がないカテゴリー、地方協会のみが掲載している試合、別年度の試合は含みません。
- 予定試合も収録できますが、アプリの初期表示は「試合終了」のみです。

出典は [JRFU](https://www.rugby-japan.jp/schedule/)、[リーグワン](https://league-one.jp/schedule/?year=2025)、[トップリーグ](https://www.top-league.jp/schedule/)、[World Rugby／W杯](https://www.rugbyworldcup.com/en/past-tournaments)、[HSBC SVNS](https://www.svns.com/en/fixtures-and-results)。各試合は公式の試合ID、ページURL、記録票URL、取得日時を保持します。具体的な収録件数・未取得情報はDBの `metadata` テーブルにある `manifest` と、アプリ内「収録範囲・出典」で確認できます。

### 2021〜2024年の追加取得（2026-09-28）

全14カテゴリー×4年の日程一覧から、重複を除いた2,435試合を追加しました。

| 掲載年 | 試合数 | 詳細あり | 掲載終了による概要のみ |
| --- | ---: | ---: | ---: |
| 2021 | 493 | 10 | 483 |
| 2022 | 600 | 582 | 18 |
| 2023 | 685 | 685 | 0 |
| 2024 | 657 | 657 | 0 |
| 合計 | 2,435 | 1,934 | 501 |

概要のみの501試合は公式記録票が「コンテンツの掲載期間が終了しました」に転送されるため、日程一覧に残る試合結果と公式リンクを保存しています。詳細を推測で補完していません。通信エラー23試合は再取得して解消しました。

既存のJRFU 2025・2026年分とリーグワン2025–26シーズンの1,408試合は全項目を保持し、この時点の同梱DBは計3,843試合（詳細あり3,342試合）でした。追加した詳細1,934試合のメンバー数・得点経過は取得元HTMLとの照合で問題なく、同梱DBの全件読み取り・年度等の絞り込み・整合性確認も通過しています。

### リーグワンの過去全シーズンを追加（2026-10-01）

2022年の開幕以降、未収録だった4シーズンの749試合を追加しました。

| シーズン | 試合数 | 詳細あり | 中止・不成立（概要のみ） |
| --- | ---: | ---: | ---: |
| 2022 | 178 | 150 | 28 |
| 2022–23 | 174 | 168 | 6 |
| 2023–24 | 174 | 173 | 1 |
| 2024–25 | 223 | 223 | 0 |
| 追加合計 | 749 | 714 | 35 |

既存の2025–26シーズン223試合と合わせ、リーグワンは全5シーズン・972試合です。D1〜D3、D1プレーオフ、入替戦を含みます。中止・不成立の35試合は公式日程の状態とリンクを保持し、欠損得点を0点に置き換えていません。初期表示は「試合終了」のため、中止試合を見るには状態の絞り込みを変更します。

既存3,843試合の全項目を保持したまま、同梱DBは計4,592試合（詳細あり4,056試合）になりました。追加714試合の詳細は公式HTMLのメンバー数・得点経過・最終得点と照合し、全749試合の日付・最終得点も日程一覧と一致しています。追加分の取得エラーは0件です。既存のJRFU掲載終了501件の情報は保持しています。全件読み取り・検索・絞り込み・DB整合性検証、既存の機能テスト、iOSシミュレーター向けビルドと更新DBの同梱確認も通過しました。

## 保存している項目

大会、カテゴリー、掲載年／シーズン、日付、キックオフ、会場、両チーム、得点と前後半の得点、メンバー表、得点経過、交代、公式記録票のT/G/PT/PG/DG・PK/FK等です。映像、写真、記事本文、選手の身体情報は収集対象にしていません。独自分析のポゼッション等は公式記録に値がない限り補いません。

同じJRFU試合が「高校」「その他」等に重複掲載されるため、試合は掲載元と公式IDで一意にし、カテゴリー所属は複数保持します。どの所属カテゴリーからでも検索できます。掲載元が異なるレコードを推測で結合する処理はありません。欠損得点はSQL `NULL`、実際の0点は整数 `0` です。

`detailLevel=full` は公式記録票の対象項目を解析できたことを表し、すべての項目が必ず掲載されているという意味ではありません。取得できない記録票は `summary` とし、概要と公式リンクを保持します。選手の退出に交代相手がない場合は、架空のIN選手を追加しません。

## 再取得と再生成

収集ツールのみPython 3とcurlを使います。リーグワンのHTML解析用Beautiful Soupは開発環境だけで使い、iOSアプリには追加しません。

```sh
python3 -m venv /tmp/rugby-official-venv
/tmp/rugby-official-venv/bin/pip install -r Tools/official_records/requirements.txt

/tmp/rugby-official-venv/bin/python Tools/official_records/jrfu.py \
  --years 2021 2022 2023 2024 2025 2026 --cache /tmp/rugby-official-cache/jrfu \
  --output /tmp/rugby-official-cache/jrfu.json --workers 1 --delay 1.5

for year in 2021 2022 2023 2024 2025; do
  /tmp/rugby-official-venv/bin/python Tools/official_records/leagueone.py \
    --year "$year" --cache /tmp/rugby-official-cache \
    --output "/tmp/rugby-official-cache/leagueone-$year.json" || break
done

python3 Tools/official_records/build_archive.py \
  --input /tmp/rugby-official-cache/jrfu.json \
  --input /tmp/rugby-official-cache/leagueone-2021.json \
  --input /tmp/rugby-official-cache/leagueone-2022.json \
  --input /tmp/rugby-official-cache/leagueone-2023.json \
  --input /tmp/rugby-official-cache/leagueone-2024.json \
  --input /tmp/rugby-official-cache/leagueone-2025.json \
  --output 'Rugby AS/OfficialRecords.sqlite'
```

リーグワンの `--year` は公式サイトの選択値です。初年度だけは `2021` を指定すると2022シーズンになり、DBには `season=2022`、`year=2022` として保存します。2022–23以降はシーズン開始年を指定します。古い日程の試合番号には西暦がないため、節見出しの日付範囲から開催年を読み取ります。中止・不成立の試合は日程の概要を保持し、記録票の取得対象から除きます。

キャッシュは同じページの再取得を避けるためのものです。最新の公開内容を取得し直す場合は、新しいキャッシュフォルダを使います。中断後は同じフォルダとJSON出力先で再実行できます。JRFUの過去の失敗を再試行するには、サイトの待機時間を守った後で `--retry-failed` を指定します。HTTP 429ではその実行の追加取得を停止し、制限回避は行いません。どちらの収集ツールも `--offline` でキャッシュの再解析だけを実行できます。

**再取得のあとは必ず `build_archive.py` をもう一度実行してください。** アプリが読むのは生成済みの `OfficialRecords.sqlite` だけなので、JSON を取り直しても生成し直さないと反映されません（2026-09-24 に、429 で取れなかった743試合が取り直し済みなのに「概要のみ」のまま残っていたのはこれが原因）。

生成処理は不正な入力・空のデータセットを拒否し、一時DBの整合性確認後に完成品を置き換えます。更新後は件数・エラー・代表試合を確認し、ビルドしてください。生HTMLや個別の収集JSONはアプリに同梱しません。

## 検証

```sh
/tmp/rugby-official-venv/bin/python -m unittest discover \
  -s Tools/official_records -p 'test_*.py'
bash Tests/run-official-records.sh
bash Tests/run-regressions.sh

/tmp/rugby-official-venv/bin/python Tools/official_records/audit_sources.py \
  --source jrfu --input /tmp/rugby-official-cache/jrfu.json \
  --cache /tmp/rugby-official-cache/jrfu
for year in 2021 2022 2023 2024 2025; do
  /tmp/rugby-official-venv/bin/python Tools/official_records/audit_sources.py \
    --source leagueone --input "/tmp/rugby-official-cache/leagueone-$year.json" \
    --cache /tmp/rugby-official-cache || break
done
```

公式記録の統合テストは、同梱した実データの全件デコード、得点のNULLと0、カテゴリー複数所属、各フィルター、ページ送り、SQL特殊文字、読み取り前後のファイル不変を確認します。元ページとの照合は、氏名のあるメンバー数・得点経過の行数・得点推移・最終得点を別途検証します。詳細なJSON契約は [SCHEMA.md](SCHEMA.md)。

SQLiteには `matches`、`match_categories`、`players`、`score_events`、`substitutions`、`statistics`、`metadata` があり、別の分析環境でも直接読み取れます。子テーブルの選手は試合単位の登録情報であり、同姓同名を横断的な人物IDに統合していません。

### ラグビーワールドカップの過去大会（2026-10-03）

World Rugbyの公開記録から、男子は第1回の1987年〜2023年、女子は第1回の1991年〜2025年の各10大会を追加しました。対象は15人制W杯本大会です。予選、セブンズW杯、将来の大会は含みません。初期の女子大会を含め、件数は公式APIに大会の試合として掲載されている範囲です。

| 男子大会 | 掲載試合数 | 女子大会 | 掲載試合数 |
| --- | ---: | --- | ---: |
| 1987 | 32 | 1991 | 22 |
| 1991 | 32 | 1994 | 31 |
| 1995 | 32 | 1998 | 40 |
| 1999 | 41 | 2002 | 32 |
| 2003 | 48 | 2006 | 30 |
| 2007 | 48 | 2010 | 30 |
| 2011 | 48 | 2014 | 30 |
| 2015 | 48 | 2017 | 30 |
| 2019 | 48 | 2021（開催2022年） | 26 |
| 2023 | 48 | 2025 | 32 |
| 合計 | 425 | 合計 | 303 |

既存4,592試合を全項目保持したまま、W杯728試合を追加し、同梱DBは計5,320試合になりました。W杯分は詳細622試合・一部情報未掲載等の103試合・中止3試合です。取得エラーは再試行で0件になりました。未掲載・不一致の注記は139件（1試合に複数の注記を含む）を保持しています。メンバー登録30,756件、得点経過10,880件、交代・入退出7,222件、チームスタッツ55,716項目を収録しました。

全728試合には2019年の中止3試合を含みます。中止は通常スコアをNULLにし、公式の0–0扱いは元データとして別に保持します。女子2021大会は、大会年を2021、試合日を実際の2022年として保持します。

[公式の過去大会一覧](https://www.rugbyworldcup.com/en/past-tournaments)を出典画面に載せ、各試合にはWorld Rugbyの公式試合ページと公式ID、取得日時を保存します。取得元は `https://api.wr-rims-prod.pulselive.com/rugby/v3` の公開 `event` / `schedule` / `match/{id}/summary` / `timeline` / `stats` です。アプリには抽出した試合情報だけを入れ、APIの生レスポンス、選手の生年月日・身長・体重、スタッフ情報は含めません。

1987・1991年の4点トライ、旧ルールの認定トライ（4点・5点）は、公式記録の値を保ちます。「自分の試合」へ取り込む際も、その得点をイベントの付加情報として保存し、試合一覧・サマリー・大会・チーム／選手ランキングで同じ点数を使います。集計用のトライ種別は従来のままなので、トライ数には通常どおり数えられます。現行ルールの記録は変更しません。

得点経過が最終結果と一致しない場合、または時刻・時間帯が未掲載の場合は、途中の累計得点や前後半得点を推測で埋めず、制限を明記します。アプリ側のプレー記録は時間帯・時刻を必須とするため、時刻不明の得点を個人の試合に取り込む際は、時間帯不明なら仮に後半、時刻不明なら0分に置くことを確認画面で説明します。前後半別の集計や得点グラフには確認・修正が必要です。延長を含む試合では、延長得点を通常の後半得点と混ぜて表示しません。同時刻に複数人が交代して対応関係が不明な場合は、架空の交代ペアを作りません。名簿は男女15人制を区別し、開催地の時刻は元のUTC時刻とともに保持します。

既存の公式記録と同様、W杯データも開発版(Debug)だけに同梱します。

#### 再取得・追加方法

W杯の収集ツールはPython標準ライブラリとcurlだけで動きます。

```sh
python3 Tools/official_records/rwc.py \
  --cache /tmp/rugby-official-cache/rwc --through 2025 \
  --output /tmp/rugby-official-cache/rwc.json
```

1.5秒以上の間隔を空け、公式APIの50件/分という上限を下回るペースで取得します。403/429はその実行を停止します。再試行時は公式の待機時間を守り、同じキャッシュを使って再開してください。`--offline` はキャッシュのみの再解析です。取得失敗時は概要と取得漏れを残し、未掲載の情報を生成しません。

既存の収集JSONが手元にない場合は、同梱DBの全レコード・収録範囲・取得エラーをJSONへ保存してから、新しいソースと合わせて再生成できます。

```sh
python3 - <<'PY'
import json, sqlite3
from pathlib import Path
with sqlite3.connect('file:Rugby AS/OfficialRecords.sqlite?mode=ro', uri=True) as db:
    manifest = json.loads(db.execute("SELECT value FROM metadata WHERE key='manifest'").fetchone()[0])
    matches = [json.loads(row[0]) for row in db.execute('SELECT payload FROM matches')]
Path('/tmp/rugby-official-cache/existing.json').write_text(json.dumps(
    dict(matches=matches, coverage=manifest['coverage'], errors=manifest['errors']), ensure_ascii=False))
PY
python3 Tools/official_records/build_archive.py \
  --input /tmp/rugby-official-cache/existing.json \
  --input /tmp/rugby-official-cache/rwc.json \
  --output 'Rugby AS/OfficialRecords.sqlite'
python3 Tools/official_records/audit_rwc.py \
  --cache /tmp/rugby-official-cache/rwc --input /tmp/rugby-official-cache/rwc.json
bash Tests/run-official-records.sh
bash Tests/run-regressions.sh
```

初期大会・現代大会とも、日程の対戦・日時・最終得点、メンバー名、得点イベント数、当時の得点値を元レスポンスと照合します。再生成前後の既存レコードを全件比較し、他ソースの内容が変わっていないことも確認してください。

### HSBC SVNSをアプリに反映（2026-10-03）

2021〜2026年の男女2,884試合を追加し、JRFU・リーグワン・W杯と合わせて全8,204試合を検索・取り込みできます。収録範囲は取得済みの公式日程93大会（男女別）です。

最終取得では通信エラー0件、詳細2,796試合、一部情報未掲載等の終了済み81試合、中止5試合、公式日程の状態が未確定の2試合です。メンバー登録68,512件、得点経過33,507件、交代・入退出29,085件、チームスタッツ56,221項目を収録しました。未掲載・不一致の注記92件はそのまま保持しています。

2024年マドリード女子のSpain–Poland（5月31日）、New Zealand–USA（6月1日）は、公式日程の状態が前半のままのため、終了済みと推測せず「不明」としています。公式に掲載された対戦・スコア・詳細は保存しています。

| シーズン | 男子 | 女子 | 合計 |
| --- | ---: | ---: | ---: |
| 2021 | 68 | 20 | 88 |
| 2022 | 383 | 186 | 569 |
| 2023 | 491 | 238 | 729 |
| 2024 | 260 | 260 | 520 |
| 2025 | 208 | 208 | 416 |
| 2026 | 281 | 281 | 562 |
| 合計 | 1,691 | 1,193 | 2,884 |

旧HSBC World Rugby Sevens Seriesを含みます。2021年女子は公式のFast Four 2大会です。2026年はSVNS Series・SVNS 2・SVNS 3・World Championshipを含みます。五輪・セブンズW杯・Challenger Sevens Seriesはこの追加の対象外です。大会名・シリーズ名は元の区分を保持します。

「掲載元：HSBC SVNS」「カテゴリー：HSBC SVNS 男子／女子」、シーズン・大会名で絞り込めます。チームは男女7人制として取り込み、15人制や異なる性別の名簿との混同を避けます。背番号の大小で先発を決めず、公式のポジション・役割を使います。試合日と時刻は開催地表示、取り込み日時はUTCから端末の時間帯へ変換します。

延長の得点を通常の後半得点として表示せず、時刻・時間帯不明の記録には注記を残します。複数交代は、元データの対応IDまたは同時刻の1対1対応が確認できる場合だけ組にします。未掲載の情報や公式スコアとの不一致は補完せず、概要と取得できた詳細を保存します。中止5試合はスコアをNULLで保存します。開発版(Debug)限定という既存の取り扱いは変えません。

#### 再取得と再生成

```sh
python3 Tools/official_records/svns.py \
  --cache /tmp/rugby-official-cache/svns --since 2021 \
  --output /tmp/rugby-official-cache/svns.json

python3 Tools/official_records/build_archive.py \
  --input /tmp/rugby-official-cache/svns-existing.json \
  --input /tmp/rugby-official-cache/svns.json \
  --output 'Rugby AS/OfficialRecords.sqlite'

python3 Tools/official_records/audit_svns.py \
  --cache /tmp/rugby-official-cache/svns --input /tmp/rugby-official-cache/svns.json
bash Tests/run-official-records.sh
bash Tests/run-regressions.sh
```

`svns-existing.json` はSVNS追加直前の既存5,320試合と収録範囲・注記を保存した入力です。再生成では、SVNS以外の最新データと新しいSVNSのJSONを組み合わせてください。古いSVNS入りDBをそのまま重ねると、既存の重複処理（詳細あり優先）により、訂正した概要レコードより古い詳細レコードが選ばれる場合があります。キャッシュだけを解析し直す場合は収集コマンドに `--offline` を付けます。

取得は1.5秒以上の間隔を空け、403/429時には停止します。`audit_svns.py` は、全試合の日程・対戦・スコア・現地日時・UTC、メンバー名、得点イベント数と点数、チームスタッツを元の公開レスポンスと照合します。取り込みテストではW杯とSVNSの詳細レコードすべてについて、取り込む得点が公式の最終結果と一致することを確認します。

### 未取り込みの試合を一括追加

開発版の「公式記録」→「未取り込みの試合をまとめて取り込む」から、全収録範囲または現在の絞り込み範囲（年度・掲載元・カテゴリー等）の終了済み試合を追加できます。取り込み前に追加数、重複除外数、一部情報未掲載・得点不一致の件数を表示します。メンバー表の有無を選べ、大会の区分は保持します。

公式IDで取り込み済みを判定します。公式IDのない既存試合や別掲載元の同一試合は、日付と対戦チーム（別名を含む）でも除外します。同じ掲載元でIDが異なる同日対戦は、セブンズの再対戦などがあるため別試合として扱います。

詳細の読み込み・下書き変換・保存は、画面処理と分離した専用の保存処理で行い、80試合ずつ確定します。モデルや保存コンテキストはその処理内に閉じ込め、画面には件数だけを返します。進捗表示と停止操作があり、停止・失敗前に保存した分は保持します。再確認すると保存済みを除外して続きから取り込めます。失敗した処理単位は取り消し、個人の編集中データを巻き戻しません。動画の追加取得は行いません。

### JRFU・SVNSを第1回まで遡って追加（2026-10-04〜05）

JRFUは2003〜2020年を1年ずつ、SVNSは1999–2000年シーズン〜2020年を1年ずつ遡って取得しました。取得エラーは0件です。

| 掲載元 | 追加した試合 | 詳細あり | 備考 |
| --- | ---: | ---: | --- |
| JRFU 2003〜2020年 | 6,009 | 246 | 掲載終了の試合は試合ページの前後半得点・T/G/PT/PG/DG・正確な日付と会場 |
| HSBC SVNS 2000〜2020年シーズン | 9,652 | 3,968 | 2015〜2020年はほぼ全試合が詳細あり、2014年以前は大半が概要のみ |

JRFUの公式記録票（`/match/{id}/print`）は掲載期間が終わると掲載終了ページへ転送されます。その場合 `jrfu.py` は通常の試合ページ（`/match/{id}`）を読み、前後半得点・得点内訳・日付・キックオフ・会場を保存します（`detailLevel=summary`、注記つき）。メンバー表・得点経過・交代は推測しません。2021年の概要のみ483試合もこの方法で補い、477試合に前後半得点が入りました。日程一覧のスコアが誤っていた8試合と、空欄だった14試合は、前後半の合計・得点内訳と一致する試合ページの値になっています。試合ページの最終得点と得点内訳が2点ずれる試合が45件あり（認定トライのゴールを二重に数えているとみられる）、最終得点は公式の値のまま保持しています。

`svns.py` は名前に「Sevens World Series」を含む旧シリーズも対象にしました。`--since` はシーズンと試合日の両方で絞るため、遡るときは年を1つずつ下げて再実行します（キャッシュ済みの分は取り直しません）。

既存のリーグワン・W杯・JRFU 2022年以降の4,827試合は全項目が変わらないことを、既存のSVNS 2,884試合は得点と詳細の有無が変わらないことを確認しました。同梱DBは計23,865試合（詳細あり11,688試合）です。

```sh
# 年ごとに取得（JRFUは1年30分前後。1回の実行は数年までにする）
python3 Tools/official_records/jrfu.py --years 2020 --cache /tmp/rugby-official-cache/jrfu \
  --output /tmp/rugby-official-cache/jrfu-2020.json --workers 1 --delay 1.5
python3 Tools/official_records/svns.py --cache /tmp/rugby-official-cache/svns --since 1999 \
  --output /tmp/rugby-official-cache/svns-since1999.json

# 既存DBからSVNSとJRFU 2021年を除いた入力を作り、新しい分と合わせて再生成
python3 Tools/official_records/build_archive.py --input existing-base.json \
  --input /tmp/rugby-official-cache/jrfu-2003.json ... --input /tmp/rugby-official-cache/jrfu-2021.json \
  --input /tmp/rugby-official-cache/svns-since1999.json --output 'Rugby AS/OfficialRecords.sqlite'
```

### トップリーグ全18シーズンを追加（2026-10-05）

リーグワンの前身であるジャパンラグビートップリーグを、公式サイト（[top-league.jp](https://www.top-league.jp/schedule/)、アーカイブとして公開継続中）から2020–21シーズンを先頭に1シーズンずつ遡って取得しました。取得エラーは0件です。

| 区分 | 試合数 |
| --- | ---: |
| トップリーグ（リーグ戦・カップ・プレーオフ等） | 1,858 |
| トップチャレンジ | 99 |
| 入替戦 | 40 |
| その他（オールスター・チャリティ等） | 8 |
| 合計 | 2,005（詳細あり1,932） |

各試合ページから、最終・前後半・延長の得点、T/G/PT/PG/DG、得点と交代の経過、先発・リザーブのメンバー表、日付・キックオフ・会場、観客数・天候・グランド状態・レフリー、イエロー／レッドカードを保存します。リンク先のJRFU公式記録票は掲載終了のため使いません。掲載元IDは `topleague:{試合詳細ID}`、シーズンは `2003–04` の形、`year` はシーズン開始年です。

- 2016–17シーズンまでの認定トライは当時のルールどおり5点（ゴールは別に2点）として `PT5` で記録します。公式サイトの途中経過は7点で計算されているため、該当の109試合は途中の累計得点を当時の点数で計算し直しました（注記つき）。最終得点は公式の値です。
- 2019–20シーズン（トップリーグ2020）の63試合は、日程に結果も詳細もありません。中止の事情を推測せず状態は「不明」とし、注記を付けています。2020–21の中止4試合は公式表示どおり「中止」です。
- 凡例にない規律の印（suspension・accumulation・reprimand）は意味を推測せず、「その他の記録（suspension）」のように元の区分名で保存します。
- 詳細あり1,932試合はすべて、得点経過の合計・最後の累計が公式の最終得点と一致し、取り込み下書きの得点も公式の最終得点と一致します（`Tests/run-regressions.sh`）。

```sh
# シーズン開始年を指定（新しい順に遡る）。キャッシュ済みのページは取り直しません
python3 Tools/official_records/topleague.py --seasons 2020 2019 2018 \
  --cache /tmp/rugby-official-cache/topleague --output /tmp/rugby-official-cache/topleague.json
# --offline でキャッシュだけを解析し直す（Beautiful Soup が必要。requirements.txt）
```

トップリーグより前（1948〜2003年の全国社会人ラグビーフットボール大会、地域社会人リーグ）は、JRFUのデジタルミュージアムにトーナメント表の画像があるだけで、試合単位の文字データを公開している公式の掲載元は見つかっていません（2026-10-05時点）。
