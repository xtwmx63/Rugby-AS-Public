//
//  TournamentDetailView.swift
//  Rugby AS
//
//  大会の詳細。一般的なスポーツアプリのように、見出しの下のタブで
//  順位表・選手成績(トライ/得点ランキング)・試合・チームを切り替えて見る。数値は保存値でなく常にStatEventから再計算する
//  (後から記録を直しても自動で正しくなる、このアプリの基本方針)。
//

import SwiftData
import SwiftUI

struct TournamentDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let tournament: Tournament

    // この大会と同じシリーズの大会の試合だけを、開いたときと保存があったときに読む
    // (全試合・全選手を読むと、公式記録の取り込みで試合2万・選手4万になり、開くたびに重かった)
    @State private var allMatches: [Match] = []
    @State private var playersByID: [UUID: Player] = [:]
    // 得点になる成功記録(とコンバージョンは失敗も)を、画面を開いたときと保存があったときに1回読んで値として持つ。
    // (@Query だと切り替えのたびにデータベースを読み直していて、シリーズ通算の切り替えが重かった)
    @State private var scoringRows: [ScoringRow] = []

    private struct ScoringRow {
        let matchID: UUID
        let teamID: UUID?
        let playerID: UUID?
        let points: Int
        let isTry: Bool
        let isConversion: Bool
        let isSuccess: Bool
    }

    private func loadScoringRows() {
        let tournamentIDs = seriesTournaments(firstDates: [:]).map(\.id) + [tournament.id]
        allMatches = (try? modelContext.fetch(FetchDescriptor<Match>(predicate: #Predicate { tournamentIDs.contains($0.tournamentID) }))) ?? []
        let matchIDs = allMatches.map(\.id)
        let categories = ScoringRules.categories
        // 条件は単純にして読み、得点の種類はここで絞る(複雑な条件はビルドが遅くなるため)
        let events = ((try? modelContext.fetch(FetchDescriptor<StatEvent>(predicate: #Predicate { matchIDs.contains($0.matchID) }))) ?? [])
            .filter { ($0.outcome == "success" && categories.contains($0.category)) || $0.category == "conversion" }
        let playerIDs = Array(Set(events.compactMap(\.playerID)))
        let players = playerIDs.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { playerIDs.contains($0.id) }))) ?? []
        playersByID = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scoringRows = events.map {
            let success = $0.outcome == "success"
            return ScoringRow(matchID: $0.matchID, teamID: $0.teamID, playerID: $0.playerID,
                              points: success ? ScoringRules.points(category: $0.category, widgetData: $0.widgetData) : 0,
                              isTry: $0.category == ScoringCategory.tryScore.rawValue,
                              isConversion: $0.category == ScoringCategory.conversion.rawValue,
                              isSuccess: success)
        }
    }
    @Query private var teams: [Team]
    @Query private var allTournaments: [Tournament]

    @State private var isEditorPresented = false
    // true = 同じシリーズの大会をまとめた「シリーズ通算」を表示する
    @State private var showsSeries = false
    // 切り替えボタンの表示だけ先に変え、重い集計・画面の組み立ては次のフレームで行う(押した感触を軽くするため)
    @State private var pickerShowsSeries = false
    @State private var editingInclusion = false
    @State private var editingSeries = false
    // シリーズ通算では試合が多いので、最初は新しい試合だけ出す(画面の組み立てを軽くするため)
    @State private var showsAllMatches = false
    private static let initialMatchLimit = 20

    /// 見出しの下のタブ。表示中のタブの中身だけを組み立てる(画面が短く、軽くなる)
    private enum DetailTab: String, CaseIterable, Identifiable {
        case standings = "順位表"
        case players = "選手成績"
        case matches = "試合"
        case teams = "チーム"
        var id: Self { self }
    }
    @State private var tab: DetailTab = .standings
    /// コンバージョン成功率ランキングの対象(何本以上蹴った選手か)。数本だけで100%の選手が上位に来ないように
    @AppStorage("tournament.conversionRateMinKicks") private var conversionMinKicks = 5
    private static let conversionMinKickOptions = [3, 5, 10]

    /// 1位カードを押したときに開く選手
    @State private var leaderPlayerID: UUID?

    var body: some View {
        // 集計は1回の表示につき1回だけ行い、各部分には結果を渡す
        // (以前は得点を1つ参照するたびに全記録を集計し直していて、シリーズ通算で重くなっていた)
        let data = makeSnapshot()
        return List {
            headerSection(data)
            Section {
                Picker("表示", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            switch tab {
            case .standings:
                standingsSection(data)
                if data.isSeriesMode { seriesBreakdownSection(data) }
            case .players:
                leaderSection(title: "トライ", systemImage: "rugbyball.fill", entries: data.tryRanking, unit: "トライ")
                leaderSection(title: "得点", systemImage: "star.fill", entries: data.pointsRanking, unit: "点")
                leaderSection(title: "コンバージョン成功", systemImage: "scope", entries: data.conversionRanking, unit: "本",
                              footer: "キッカーが記録されたコンバージョンだけを数えています。右は成功/蹴った本数。")
                leaderSection(title: "コンバージョン成功率", systemImage: "percent", entries: data.conversionRateRanking, unit: "%",
                              footer: "\(conversionMinKicks)本以上蹴った選手が対象です(見出しの「\(conversionMinKicks)本以上」で変えられます)。同じ成功率なら蹴った本数が多い順。",
                              empty: "\(conversionMinKicks)本以上蹴った選手がまだいません。",
                              showsKickThreshold: true)
            case .matches:
                matchesTab(data)
            case .teams:
                participatingTeamsSection(data)
            }
        }
        .onChange(of: showsSeries) { _, _ in showsAllMatches = false }
        .onAppear(perform: loadScoringRows)
        .onReceive(ModelSaveSignal.didSave) { _ in loadScoringRows() }
        .task(id: pickerShowsSeries) {
            guard pickerShowsSeries != showsSeries else { return }
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showsSeries = pickerShowsSeries }
        }
        .navigationTitle(data.isSeriesMode ? (tournament.seriesName ?? tournament.officialName) : tournament.officialName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditorPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("この大会を編集")
            }
            // 大会CSVは1大会ずつ(シリーズ通算では出さない)
            if !data.isSeriesMode {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(
                    item: TournamentCSVExportRequest(
                        container: modelContext.container,
                        tournamentID: tournament.id,
                        tournamentName: tournament.officialName
                    ),
                    preview: SharePreview("\(tournament.officialName) 全試合CSV")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(data.matches.isEmpty)
                .accessibilityLabel("この大会のCSVを書き出す")
            }
            }
        }
        .navigationDestination(item: $leaderPlayerID) { playerID in
            if let player = playersByID[playerID] {
                PlayerDetailView(player: player)
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            TournamentEditorView(tournament: tournament)
        }
        .sheet(isPresented: $editingSeries) {
            SeriesMembershipEditor(baseTournament: tournament)
        }
        .sheet(isPresented: $editingInclusion) {
            // いま表示中の範囲(この大会、またはシリーズ通算)の試合だけを選び直す
            StatsInclusionEditor(matchIDs: Set(data.matches.map(\.id)))
        }
    }

    // MARK: - 見出し（ロゴ・名前・年度・形式・表示範囲）

    private func headerSection(_ data: Snapshot) -> some View {
        Section {
            HStack(spacing: 14) {
                logoView
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.isSeriesMode ? (tournament.seriesName ?? tournament.officialName) : tournament.officialName)
                        .font(.headline)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        if let year = tournament.year {
                            metaChip("\(String(year))年度")
                        }
                        if let gender = RugbyGender.displayName(for: tournament.genderRaw) {
                            metaChip(gender)
                        }
                        if let variant = RugbyVariant.displayName(for: tournament.variantRaw) {
                            metaChip(variant)
                        }
                        if let format = TournamentFormat.displayName(for: tournament.formatRaw) {
                            metaChip(format)
                        }
                    }
                    scopeMenu(data)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } footer: {
            if data.isSeriesMode {
                Text("\(data.seriesTournaments.count)大会を合算: " + data.seriesTournaments.map(shortName).joined(separator: "・"))
            }
        }
    }

    /// 「この大会 ▾ / シリーズ通算 ▾」。表示範囲の切り替えとシリーズの編集をまとめたメニュー
    private func scopeMenu(_ data: Snapshot) -> some View {
        let count = data.seriesTournaments.count
        return Menu {
            if count > 1 {
                Picker("表示範囲", selection: $pickerShowsSeries) {
                    Text("この大会").tag(false)
                    Text("シリーズ通算（\(count)大会）").tag(true)
                }
            }
            Button {
                editingSeries = true
            } label: {
                Label(count > 1 ? "シリーズにまとめる大会を選び直す" : "ほかの大会とシリーズにまとめる",
                      systemImage: "rectangle.stack.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(data.isSeriesMode ? "シリーズ通算（\(count)大会）" : (count > 1 ? "この大会" : "シリーズなし"))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .accessibilityLabel("表示範囲とシリーズ")
    }

    @ViewBuilder
    private var logoView: some View {
        StoredImageView(name: tournament.logoPath, maxDimension: 192) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } placeholder: {
            Image(systemName: "trophy.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    // MARK: - シリーズ(同じシリーズ名の大会をまとめて見る)

    private var seriesKey: String? {
        guard let name = tournament.seriesName else { return nil }
        let key = OfficialRecordImporter.nameKey(name)
        return key.isEmpty ? nil : key
    }

    /// 同じシリーズの大会。最初の試合が早い順(試合がなければ名前順で後ろ)。
    private func seriesTournaments(firstDates: [UUID: Date]) -> [Tournament] {
        guard let seriesKey else { return [tournament] }
        return allTournaments
            .filter { $0.seriesName.map(OfficialRecordImporter.nameKey) == seriesKey }
            .sorted { (firstDates[$0.id] ?? .distantFuture, $0.officialName) < (firstDates[$1.id] ?? .distantFuture, $1.officialName) }
    }

    /// シリーズ名を除いた大会の短い名前(例: 「第1戦熊谷大会」)
    private func shortName(_ item: Tournament) -> String {
        let name = item.officialName.replacingOccurrences(of: "セブンスシリーズ", with: "セブンズシリーズ")
        if let series = item.seriesName?.trimmingCharacters(in: .whitespaces), !series.isEmpty, name.hasPrefix(series) {
            let rest = name.dropFirst(series.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        if let range = name.range(of: "シリーズ[\\s　]*(19|20)[0-9]{2}", options: .regularExpression) {
            let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return name
    }

    /// シリーズ通算のときの、チーム × 大会の成績表(勝-分-敗と得失点差)
    private func seriesBreakdownSection(_ data: Snapshot) -> some View {
        let countedByTournament = Dictionary(grouping: data.counted, by: \.tournamentID)
        let perTournament = data.seriesTournaments.map { item in
            (item, Dictionary(uniqueKeysWithValues: computeStandings(countedByTournament[item.id] ?? [], scores: data.scores).map { ($0.id, $0) }))
        }
        return Section {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("チーム").frame(width: 120, alignment: .leading)
                        ForEach(perTournament, id: \.0.id) { item, _ in
                            Text(shortName(item)).lineLimit(2).frame(width: 84, alignment: .center)
                        }
                        Text("通算").frame(width: 64, alignment: .center)
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    ForEach(data.standings) { total in
                        GridRow {
                            Text(total.name).font(.caption.weight(.semibold)).lineLimit(2).frame(width: 120, alignment: .leading)
                            ForEach(perTournament, id: \.0.id) { _, table in
                                breakdownCell(table[total.id]).frame(width: 84)
                            }
                            breakdownCell(total).frame(width: 64)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("大会ごとの成績", systemImage: "tablecells")
        } footer: {
            Text("上段は勝-分-敗、下段は得失点差。「—」はその大会に試合がないチームです。公式のシリーズポイント(各大会の順位で付く点)は計算していません。")
        }
    }

    @ViewBuilder
    private func breakdownCell(_ standing: TeamStanding?) -> some View {
        if let standing {
            VStack(spacing: 1) {
                Text("\(standing.wins)-\(standing.draws)-\(standing.losses)")
                    .font(.caption.weight(.bold).monospacedDigit())
                Text(standing.diff > 0 ? "+\(standing.diff)" : "\(standing.diff)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(standing.diff > 0 ? .green : (standing.diff < 0 ? .red : .secondary))
            }
        } else {
            Text("—").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 出場チーム

    @ViewBuilder
    private func participatingTeamsSection(_ data: Snapshot) -> some View {
        let enteredIDs = Set(data.isSeriesMode ? data.seriesTournaments.flatMap(\.teamIDs) : tournament.teamIDs)
        let entered = teams
            .filter { enteredIDs.contains($0.id) }
            .sorted { $0.name < $1.name }

        if entered.isEmpty {
            Section {
                Text("出場チームが登録されていません。右上の設定から登録できます。")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(entered) { team in
                    HStack(spacing: 10) {
                        teamThumbnail(for: team)
                        Text(team.name)
                        if let category = team.category, !category.isEmpty {
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Label("出場チーム（\(entered.count)）", systemImage: "person.3.fill")
            }
        }
    }

    @ViewBuilder
    private func teamThumbnail(for team: Team) -> some View {
        StoredImageView(name: team.logoPath, maxDimension: 96) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } placeholder: {
            Image(systemName: "shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }

    // MARK: - 順位表(チーム成績)

    private func standingsSection(_ data: Snapshot) -> some View {
        let standings = data.standings
        return Section {
            if standings.isEmpty {
                Text("試合がまだありません")
                    .foregroundStyle(.secondary)
            } else {
                // 見出し行
                HStack(spacing: 8) {
                    Text("#").frame(width: 22)
                    Text("チーム").frame(maxWidth: .infinity, alignment: .leading)
                    Text("試合").frame(width: 34)
                    Text("勝-分-敗").frame(width: 62)
                    Text("得失").frame(width: 44, alignment: .trailing)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)

                ForEach(Array(standings.enumerated()), id: \.element.id) { index, standing in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .foregroundStyle(index == 0 ? Color.yellow : .secondary)
                            .frame(width: 22)

                        teamThumbnail(for: standing.team)

                        Text(standing.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(standing.played)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34)

                        Text("\(standing.wins)-\(standing.draws)-\(standing.losses)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .frame(width: 62)

                        Text(standing.diff > 0 ? "+\(standing.diff)" : "\(standing.diff)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(standing.diff > 0 ? .green : (standing.diff < 0 ? .red : .secondary))
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: {
            Label("順位表", systemImage: "list.number")
        } footer: {
            if !standings.isEmpty {
                Text("勝ち数→得失点差の順で並べています。")
            }
        }
    }

    // MARK: - 選手成績(1位を大きく、2・3位は小さく、続きは「すべて見る」)

    private func leaderSection(title: String, systemImage: String, entries: [RankingEntry], unit: String,
                               footer: String = "選手が記録された得点だけを数えています。",
                               empty: String = "選手が記録された得点がまだありません",
                               showsKickThreshold: Bool = false) -> some View {
        Section {
            if let first = entries.first {
                // 矢印を出さず、カードを行いっぱいに広げる(押すと選手詳細へ)
                Button {
                    leaderPlayerID = first.id
                } label: {
                    LeaderCard(name: first.playerName, teamName: first.teamName, value: first.value, unit: unit,
                               detail: first.detail,
                               imagePath: first.playerImagePath, number: first.number, teamColorHex: first.teamColorHex)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                ForEach(Array(entries.dropFirst().prefix(2).enumerated()), id: \.element.id) { index, entry in
                    playerLink(entry.id) { rankingRow(entry, rank: index + 2, unit: unit) }
                }
            } else {
                Text(empty)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if showsKickThreshold {
                    Menu {
                        Picker("対象", selection: $conversionMinKicks) {
                            ForEach(Self.conversionMinKickOptions, id: \.self) { Text("\($0)本以上蹴った選手").tag($0) }
                        }
                    } label: {
                        Text("\(conversionMinKicks)本以上 ▾").font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                }
                // 対象が3人以下でも一覧(成績の詳細)を開けるように、1人でもいれば出す
                if !entries.isEmpty {
                    NavigationLink {
                        fullRanking(title: title, entries: entries, unit: unit)
                    } label: {
                        Text("すべて見る").font(.caption.weight(.semibold))
                    }
                    .textCase(nil)
                }
            }
        } footer: {
            if entries.first != nil || showsKickThreshold { Text(footer) }
        }
    }

    private func rankingRow(_ entry: RankingEntry, rank: Int, unit: String) -> some View {
        HStack(spacing: 10) {
            rankBadge(rank)
            playerThumbnail(imagePath: entry.playerImagePath, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.playerName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.teamName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(entry.value)")
                        .font(.title3.weight(.black).monospacedDigit())
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = entry.detail {
                    Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「すべて見る」で開く、記録のある選手全員の一覧
    private func fullRanking(title: String, entries: [RankingEntry], unit: String) -> some View {
        List {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                playerLink(entry.id) { rankingRow(entry, rank: index + 1, unit: unit) }
            }
        }
        .navigationTitle(title + "ランキング（\(entries.count)人）")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func playerLink<Label: View>(_ playerID: UUID, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink {
            if let player = playersByID[playerID] {
                PlayerDetailView(player: player)
            }
        } label: {
            label()
        }
    }

    // 1位=金、2位=銀、3位=銅の丸バッジ
    private func rankBadge(_ rank: Int) -> some View {
        let color: Color = switch rank {
        case 1: .yellow
        case 2: Color(white: 0.72)
        case 3: .orange
        default: Color.secondary.opacity(0.25)
        }
        // 丸の大きさはいつも同じ(写真や名前の位置がずれないように)。3けた以上は文字を小さくして収める
        return Text("\(rank)")
            .font(.system(size: rank >= 100 ? 10 : 13, weight: .black).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(rank <= 3 ? .black : .primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color))
    }

    // MARK: - 試合(日付ごと)

    @ViewBuilder
    private func matchesTab(_ data: Snapshot) -> some View {
        let all = data.matches
        let limited = !showsAllMatches && all.count > Self.initialMatchLimit
        let shown = limited ? Array(all.prefix(Self.initialMatchLimit)) : all
        let calendar = Calendar.current
        let days = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.playedAt) }
            .sorted { $0.key > $1.key }

        Section {
            if all.isEmpty {
                Text("試合がまだありません").foregroundStyle(.secondary)
            } else {
                Button {
                    editingInclusion = true
                } label: {
                    Label("集計に含める試合を選ぶ", systemImage: "checklist")
                }
            }
        } footer: {
            if all.contains(where: \.isExcludedFromStats) {
                Text("「集計対象外」の試合は、順位表・選手成績・大会CSVに含めません。")
            }
        }
        ForEach(days, id: \.key) { day, matches in
            Section {
                ForEach(matches.sorted { $0.playedAt < $1.playedAt }) { match in
                    NavigationLink {
                        MatchSummaryView(match: match)
                    } label: {
                        matchRow(match, data: data)
                    }
                }
            } header: {
                let names = data.isSeriesMode
                    ? Array(Set(matches.compactMap { data.shortNames[$0.tournamentID] })).sorted() : []
                Text(Self.dayFormatter.string(from: day) + (names.isEmpty ? "" : "  " + names.joined(separator: "・")))
                    .textCase(nil)
            }
        }
        if limited {
            Section {
                Button("すべての試合を表示（\(all.count)試合）") { showsAllMatches = true }
            }
        }
    }

    /// 「チーム名 [スコア] チーム名」の1行。勝ったほうを太字にする
    private func matchRow(_ match: Match, data: Snapshot) -> some View {
        let homeScore = data.score(match.id, match.homeTeamID)
        let awayScore = data.score(match.id, match.awayTeamID)

        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(teamName(for: match.homeTeamID))
                    .fontWeight(homeScore > awayScore ? .bold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("\(homeScore) - \(awayScore)")
                    .font(.subheadline.weight(.black).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
                Text(teamName(for: match.awayTeamID))
                    .fontWeight(awayScore > homeScore ? .bold : .regular)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            if match.isExcludedFromStats {
                Text("集計対象外").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 集計

    private struct RankingEntry: Identifiable {
        let id: UUID
        let playerName: String
        let playerImagePath: String?
        let teamName: String
        let teamColorHex: String?
        let number: Int?
        let value: Int
        /// 数字の補足(例: 「10/12本」)
        var detail: String? = nil
    }

    private struct TeamStanding: Identifiable {
        let id: UUID
        let team: Team?
        let name: String
        var played = 0
        var wins = 0
        var draws = 0
        var losses = 0
        var scored = 0
        var conceded = 0
        var diff: Int { scored - conceded }
    }

    /// 1回の表示で使う集計結果
    private struct Snapshot {
        let seriesTournaments: [Tournament]
        let isSeriesMode: Bool
        /// 表示範囲の試合(新しい順)。試合一覧には全部出す
        let matches: [Match]
        /// 順位表・ランキングに数える試合(集計対象外は除く)
        let counted: [Match]
        /// 試合ごと・チームごとの得点 [試合ID: [チームID: 点]]
        let scores: [UUID: [UUID: Int]]
        let standings: [TeamStanding]
        let tryRanking: [RankingEntry]
        let pointsRanking: [RankingEntry]
        let conversionRanking: [RankingEntry]
        let conversionRateRanking: [RankingEntry]
        let shortNames: [UUID: String]

        func score(_ matchID: UUID, _ teamID: UUID) -> Int { scores[matchID]?[teamID] ?? 0 }
    }

    private func makeSnapshot() -> Snapshot {
        let firstDates = Dictionary(allMatches.map { ($0.tournamentID, $0.playedAt) }, uniquingKeysWith: min)
        let series = seriesTournaments(firstDates: firstDates)
        let isSeriesMode = showsSeries && series.count > 1
        let scopeIDs: Set<UUID> = isSeriesMode ? Set(series.map(\.id)) : [tournament.id]
        let matches = allMatches.filter { scopeIDs.contains($0.tournamentID) }.sorted { $0.playedAt > $1.playedAt }
        let counted = matches.filter { !$0.isExcludedFromStats }
        let matchIDs = Set(matches.map(\.id))
        let countedIDs = Set(counted.map(\.id))

        // 全記録を1回だけ見て、得点表とランキングをまとめて作る
        var scores: [UUID: [UUID: Int]] = [:]
        var tries: [UUID: Int] = [:]
        var points: [UUID: Int] = [:]
        var kicksMade: [UUID: Int] = [:]
        var kicksTaken: [UUID: Int] = [:]
        for event in scoringRows where matchIDs.contains(event.matchID) {
            // コンバージョンは失敗も数える(成功率の分母)。キッカーが記録されたものだけ
            if event.isConversion, let playerID = event.playerID, countedIDs.contains(event.matchID) {
                kicksTaken[playerID, default: 0] += 1
                if event.isSuccess { kicksMade[playerID, default: 0] += 1 }
            }
            let value = event.points
            guard value > 0 else { continue }
            if let teamID = event.teamID { scores[event.matchID, default: [:]][teamID, default: 0] += value }
            // 選手が記録された得点だけランキングに入れる(集計対象外の試合は除く)
            if let playerID = event.playerID, countedIDs.contains(event.matchID) {
                points[playerID, default: 0] += value
                if event.isTry { tries[playerID, default: 0] += 1 }
            }
        }
        var kickDetail: [UUID: String] = [:]
        var exactRate: [UUID: Double] = [:]
        for (playerID, taken) in kicksTaken {
            let made = kicksMade[playerID] ?? 0
            kickDetail[playerID] = "\(made)/\(taken)本"
            // 成功率は対象本数以上蹴った選手だけ。並びは正確な率→蹴った本数→名前
            if taken >= conversionMinKicks { exactRate[playerID] = Double(made) / Double(taken) }
        }
        let rateEntries = rankingEntries(exactRate.mapValues { Int(($0 * 100).rounded()) }, detail: kickDetail)
            .sorted { lhs, rhs in
                let l = exactRate[lhs.id] ?? 0, r = exactRate[rhs.id] ?? 0
                if l != r { return l > r }
                let lt = kicksTaken[lhs.id] ?? 0, rt = kicksTaken[rhs.id] ?? 0
                if lt != rt { return lt > rt }
                return lhs.playerName < rhs.playerName
            }
        return Snapshot(
            seriesTournaments: series, isSeriesMode: isSeriesMode, matches: matches, counted: counted,
            scores: scores, standings: computeStandings(counted, scores: scores),
            tryRanking: rankingEntries(tries), pointsRanking: rankingEntries(points),
            conversionRanking: rankingEntries(kicksMade.filter { $0.value > 0 }, detail: kickDetail),
            conversionRateRanking: rateEntries,
            shortNames: isSeriesMode ? Dictionary(uniqueKeysWithValues: series.map { ($0.id, shortName($0)) }) : [:])
    }

    private func computeStandings(_ matches: [Match], scores: [UUID: [UUID: Int]]) -> [TeamStanding] {
        var table: [UUID: TeamStanding] = [:]
        let teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func entry(for teamID: UUID) -> TeamStanding {
            table[teamID] ?? TeamStanding(
                id: teamID,
                team: teamsByID[teamID],
                name: teamsByID[teamID]?.name ?? teamName(for: teamID)
            )
        }

        for match in matches {
            let homeScore = scores[match.id]?[match.homeTeamID] ?? 0
            let awayScore = scores[match.id]?[match.awayTeamID] ?? 0

            var home = entry(for: match.homeTeamID)
            var away = entry(for: match.awayTeamID)

            home.played += 1
            away.played += 1
            home.scored += homeScore
            home.conceded += awayScore
            away.scored += awayScore
            away.conceded += homeScore

            if homeScore > awayScore {
                home.wins += 1
                away.losses += 1
            } else if homeScore < awayScore {
                away.wins += 1
                home.losses += 1
            } else {
                home.draws += 1
                away.draws += 1
            }

            table[home.id] = home
            table[away.id] = away
        }

        return table.values.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            return $0.diff > $1.diff
        }
    }

    // 記録のある選手全員(多い順、同じ数なら名前順)。カードには上位3人、「すべて見る」で全員を出す。
    // 選手と所属チームは辞書で引く(選手数が多くても重くならないように)
    private func rankingEntries(_ totals: [UUID: Int], detail: [UUID: String] = [:]) -> [RankingEntry] {
        let teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return totals.compactMap { playerID, total -> RankingEntry? in
            guard let player = playersByID[playerID] else { return nil }
            return RankingEntry(
                id: playerID,
                playerName: player.name ?? player.number.map { "#\($0)" } ?? "名前未設定",
                playerImagePath: player.imagePath,
                teamName: teamName(for: player.teamID),
                teamColorHex: teamsByID[player.teamID]?.displayColorHex,
                number: player.number,
                value: total,
                detail: detail[playerID]
            )
        }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.playerName < $1.playerName }
    }

    // MARK: - 小さな部品

    private func teamName(for teamID: UUID) -> String {
        teams.first { $0.id == teamID }?.name ?? "チーム未設定"
    }

    @ViewBuilder
    private func teamThumbnail(for team: Team?) -> some View {
        StoredImageView(name: team?.logoPath, maxDimension: 96) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } placeholder: {
            Image(systemName: "shield.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func playerThumbnail(imagePath: String?, size: CGFloat) -> some View {
        StoredImageView(name: imagePath, maxDimension: size * 3) { image in
            image
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } placeholder: {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(size > 40 ? .title3 : .caption)
                        .foregroundStyle(.secondary)
                )
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E)"
        return formatter
    }()
}

#Preview {
    NavigationStack {
        TournamentDetailView(tournament: Tournament(officialName: "サンプル大会"))
    }
    .modelContainer(for: [
        Team.self,
        Player.self,
        Tournament.self,
        Match.self,
        StatEvent.self,
        MatchLineup.self,
        Substitution.self
    ], inMemory: true)
}
