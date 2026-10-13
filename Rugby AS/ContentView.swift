//
//  ContentView.swift
//  Rugby AS
//
//  Created by 35 on 2026/05/17.
//

import Combine
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Match.playedAt, order: .reverse) private var matches: [Match]
    @Query private var teams: [Team]
    @Query private var tournaments: [Tournament]
    @Environment(\.scenePhase) private var scenePhase
    @State private var tallies: [UUID: MatchListTally] = [:]
    @State private var summaryRevision = 0
    @State private var isListVisible = false
    // 得点の控え(前回の結果)がまだ無く、全試合を数えている間だけ true。控えがあれば待たせない
    @State private var isLoadingSummary = true
    @State private var didLoadTallyCache = false
    @State private var hasTallyCache = false
    // 控えを読み終えたか。読んでいる一瞬は「読み込んでいます」を出さない(毎回出ると気になるため)
    @State private var checkedTallyCache = false
    @State private var summaryError: String?
    @State private var isShowingCreateMatch = false
    @State private var matchPendingDeletion: Match?
    @State private var selectedFilter: MatchFilter = .all
    @State private var searchText = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedMatch: Match?
    @State private var isTournamentListPresented = false
    @State private var isStreamSplitPresented = false
    // カレンダーで選んだ日(その日の0時)。nil なら全部の日の試合を出す
    @State private var selectedDay: Date?
    @State private var isCalendarPresented = false
    // カテゴリー(トップ・大学など)と 7人制/15人制 の絞り込み(大会の設定を見る)
    @State private var competitionFilter = CompetitionFilter()

    private var canRefreshSummary: Bool {
        isListVisible && selectedMatch == nil
            && !isShowingCreateMatch && !isTournamentListPresented && !isStreamSplitPresented
            && !isCalendarPresented
    }

    /// 一覧の絞り込み・月ごとのまとまり・件数。試合が2万を超えるので、画面を描くたびには計算せず、
    /// 条件や記録が変わったときに1回だけ作って使い回す(以前は描くたびに全試合を8回なめていた)。
    private struct ListModel {
        var groups: [(key: String, title: String, matches: [Match])] = []
        var counts: [MatchFilter: Int] = [:]
        var visibleCount = 0
        var teamsByID: [UUID: Team] = [:]
        var tournamentNames: [UUID: String] = [:]
    }

    private struct ListInputs: Equatable {
        let matchCount: Int
        let search: String
        let filter: MatchFilter
        let day: Date?
        let competition: CompetitionFilter
        let talliesRevision: Int
        let dataRevision: Int
    }

    @State private var listModel = ListModel()
    @State private var talliesRevision = 0
    @State private var dataRevision = 0

    private var listInputs: ListInputs {
        ListInputs(matchCount: matches.count, search: searchText, filter: selectedFilter, day: selectedDay,
                   competition: competitionFilter, talliesRevision: talliesRevision, dataRevision: dataRevision)
    }

    private func rebuildList() {
        var model = ListModel()
        model.teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tournamentsByID = Dictionary(tournaments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.tournamentNames = tournamentsByID.mapValues(\.officialName)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendar = Calendar.current
        var all = 0, recording = 0, finished = 0
        var grouped: [String: [Match]] = [:]
        var keyOrder: [String] = []
        for match in matches {
            all += 1
            let isFinished = tallies[match.id]?.isFinished
            if isFinished == true { finished += 1 } else if isFinished == false { recording += 1 }
            if !query.isEmpty {
                let home = model.teamsByID[match.homeTeamID]?.name ?? "チーム未設定"
                let away = model.teamsByID[match.awayTeamID]?.name ?? "チーム未設定"
                let tournament = model.tournamentNames[match.tournamentID] ?? "大会未設定"
                guard home.localizedStandardContains(query) || away.localizedStandardContains(query)
                        || tournament.localizedStandardContains(query) else { continue }
            }
            if let selectedDay, !calendar.isDate(match.playedAt, inSameDayAs: selectedDay) { continue }
            if competitionFilter.isActive && !competitionFilter.matches(tournamentsByID[match.tournamentID]) { continue }
            switch selectedFilter {
            case .all: break
            case .recording: guard isFinished == false else { continue }
            case .finished: guard isFinished == true else { continue }
            }
            let components = calendar.dateComponents([.year, .month], from: match.playedAt)
            let key = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            if grouped[key] == nil { keyOrder.append(key) }
            grouped[key, default: []].append(match)
            model.visibleCount += 1
        }
        model.counts = [.all: all, .recording: recording, .finished: finished]
        model.groups = grouped.keys.sorted(by: >).compactMap { key in
            guard let matches = grouped[key], let first = matches.first else { return nil }
            return (key, monthTitle(for: first.playedAt), matches)
        }
        listModel = model
    }

    private enum MatchFilter: String, CaseIterable, Identifiable {
        case all
        case recording
        case finished

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "すべて"
            case .recording: return "記録中"
            case .finished: return "終了"
            }
        }
    }

    // 長い画面定義に修飾を足すとビルドが極端に遅くなるため、外側で包む
    var body: some View {
        content
            .onChange(of: listInputs, initial: true) { _, _ in rebuildList() }
            .onReceive(ModelSaveSignal.didSave) { _ in dataRevision += 1 }
    }

    private var content: some View {
        NavigationStack {
            ZStack {
                RugbyTheme.surface.ignoresSafeArea()
                VStack(spacing: 0) {
                    topHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                        .padContentWidth(760)
                        .background(RugbyTheme.header, ignoresSafeAreaEdges: [])
                    List {
                    Section {
                        if !matches.isEmpty {
                            VStack(spacing: 12) {
                                searchField
                                filterBar(tallies)
                                CompetitionFilterMenus(filter: $competitionFilter,
                                                       categories: tournaments.compactMap(\.category))
                                if let selectedDay {
                                    dayBar(selectedDay)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        if isLoadingSummary && checkedTallyCache && !matches.isEmpty {
                            ProgressView("得点を読み込んでいます…")
                                .font(.caption)
                                .tint(RugbyTheme.accent)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        if let summaryError {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(summaryError, systemImage: "exclamationmark.circle")
                                    .font(.subheadline)
                                Button("再読み込み") { summaryRevision += 1 }
                                    .buttonStyle(.bordered)
                            }
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .listRowBackground(RugbyTheme.surface)
                        }
                        if matches.isEmpty {
                            emptyState
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else if !isLoadingSummary && summaryError == nil && listModel.visibleCount == 0 {
                            VStack(spacing: 4) {
                                RugbyEmptyState(symbol: "magnifyingglass", title: "該当する試合がありません",
                                    message: "チーム名・大会名や、記録状況・日付の条件を変えてみてください。")
                                Button("すべての試合を表示") {
                                    searchText = ""
                                    selectedFilter = .all
                                    selectedDay = nil
                                    competitionFilter = CompetitionFilter()
                                }
                                .buttonStyle(.bordered)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }

                    ForEach(listModel.groups, id: \.key) { group in
                        Section {
                            ForEach(group.matches) { match in
                                matchRow(match)
                            }
                        } header: {
                            HStack {
                                Text(group.title).font(.subheadline.weight(.bold))
                                Spacer()
                                Text("\(group.matches.count)試合").font(.caption.monospacedDigit())
                            }
                            .foregroundStyle(RugbyTheme.textPrimary)
                            .textCase(nil)
                            .padding(.vertical, 8)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .padContentWidth(760)
                .background(RugbyTheme.background)
                }
            }
            .onAppear { isListVisible = true; summaryRevision += 1 }
            .onDisappear { isListVisible = false }
            .task(id: canRefreshSummary ? summaryRevision : nil) {
                guard canRefreshSummary else { return }
                await refreshSummary()
            }
            // 保存されたら、変わった試合を ModelChangeTracker が覚えるので、その合図で数え直す
            .onReceive(NotificationCenter.default.publisher(for: ModelChangeTracker.didRecord).receive(on: DispatchQueue.main)) { _ in
                if canRefreshSummary { summaryRevision += 1 }
            }
            .onChange(of: selectedMatch?.id) { _, id in ModelChangeTracker.shared.activeMatchID = id }
            .onChange(of: matches.count) { _, _ in
                if canRefreshSummary { summaryRevision += 1 }
            }
            .onChange(of: scenePhase) { _, value in
                if value == .active && canRefreshSummary { summaryRevision += 1 }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedMatch) { match in
                // 試合の中(サマリー・メンバー登録)は画面下に独自のボタンがあるのでタブを隠す
                matchDestination(for: match, tallies: tallies)
                    .toolbar(.hidden, for: .tabBar)
            }
            .sheet(isPresented: $isShowingCreateMatch) {
                NavigationStack {
                    CreateMatchView()
                }
            }
            .padFullScreenSheet(isPresented: $isTournamentListPresented) {
                TournamentListView()
            }
            .padFullScreenSheet(isPresented: $isStreamSplitPresented) {
                StreamSplitView()
            }
            .padFullScreenSheet(isPresented: $isCalendarPresented) {
                MatchCalendarView(matchCountsByDay: matchCountsByDay, selectedDay: selectedDay) { day in
                    selectedDay = day
                }
            }
            .alert(
                "この試合を削除しますか？",
                isPresented: Binding(
                    get: { matchPendingDeletion != nil },
                    set: { if !$0 { matchPendingDeletion = nil } }
                ),
                presenting: matchPendingDeletion
            ) { match in
                Button("削除する", role: .destructive) {
                    deleteMatch(match)
                }
                Button("キャンセル", role: .cancel) { }
            } message: { match in
                Text(deletionMessage(for: match))
            }
        }
    }

    private func matchRow(_ match: Match) -> some View {
        let totals = tally(match, in: tallies)
        return Button { selectedMatch = match } label: {
            MatchCard(
                match: match, tournamentName: tournamentName(for: match),
                homeTeam: team(for: match.homeTeamID), awayTeam: team(for: match.awayTeamID),
                isFinished: totals.isFinished,
                homeScore: totals.homeScore, awayScore: totals.awayScore,
                homeFirstHalfScore: totals.homeFirstHalf, awayFirstHalfScore: totals.awayFirstHalf,
                homeSecondHalfScore: totals.homeSecondHalf, awaySecondHalfScore: totals.awaySecondHalf
            )
        }
        .buttonStyle(.plain)
        .disabled(tallies[match.id] == nil)
        .redacted(reason: tallies[match.id] == nil ? .placeholder : [])
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("削除", role: .destructive) { matchPendingDeletion = match }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            RugbyEmptyState(symbol: "rugbyball", title: "最初の一戦を、ここから。",
                message: "得点だけでも、選手ごとのプレーでも。\n記録の詳しさは、あとから変えられます。")
            Button { isShowingCreateMatch = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("試合を作成")
                }
            }
            .buttonStyle(RugbyPrimaryButtonStyle())
        }
        .padding(.bottom, 32)
    }

    private var topHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rugbyball.fill")
                Text("RUGBY AS").font(.caption.weight(.heavy)).tracking(1.5)
                Spacer()
                if !matches.isEmpty {
                    Button { isCalendarPresented = true } label: {
                        Image(systemName: "calendar")
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("カレンダーで日付を選ぶ")
                }
                Menu {
                    Button { isTournamentListPresented = true } label: {
                        Label("大会一覧", systemImage: "trophy")
                    }
                    Button { isStreamSplitPresented = true } label: {
                        Label("配信を試合ごとに分ける", systemImage: "scissors")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("大会・動画のメニュー")
            }
            .foregroundStyle(RugbyTheme.onAccent)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
            layout {
                Text("試合一覧")
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !matches.isEmpty {
                    Button { isShowingCreateMatch = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("作成")
                        }
                        .fixedSize()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(RugbyTheme.header)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("試合を作成")
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(RugbyTheme.textSecondary)
            TextField("チーム・大会を検索", text: $searchText)
                .font(.subheadline)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityLabel("チーム名・大会名で試合を検索")
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索をクリア")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, searchText.isEmpty ? 14 : 0)
        .frame(minHeight: 46)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
    }

    private func filterBar(_ tallies: [UUID: MatchListTally]) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(MatchFilter.allCases) { filter in
                let isSelected = selectedFilter == filter
                Button { selectedFilter = filter } label: {
                    HStack(spacing: 6) {
                        Text(filter.title).font(.subheadline.weight(.semibold))
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text(isLoadingSummary && filter != .all ? "–" : "\(count(for: filter, tallies: tallies))")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .opacity(0.7)
                        }
                    }
                    .foregroundStyle(isSelected ? RugbyTheme.onAccent : RugbyTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(isSelected ? RugbyTheme.accent : RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(filter.title)
                .accessibilityValue(isLoadingSummary && filter != .all ? "読み込み中" : "\(count(for: filter, tallies: tallies))試合")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// 日付を選んでいるときに出す「‹ 9月10日(木) › ✕」の帯。
    /// ‹ › は試合のある前後の日へ飛ぶ(試合のない日は飛ばす)。
    private func dayBar(_ day: Date) -> some View {
        let days = matchDays
        let previous = days.last { $0 < day }
        let next = days.first { $0 > day }
        return HStack(spacing: 0) {
            Button { selectedDay = previous } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(previous == nil)
            .accessibilityLabel("試合のある前の日")
            Button { isCalendarPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                    Text(dayTitle(day))
                        .font(.headline.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel("\(dayTitle(day))。カレンダーを開く")
            Button { selectedDay = next } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(next == nil)
            .accessibilityLabel("試合のある次の日")
            Button { selectedDay = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("日付の絞り込みを解除")
        }
        .buttonStyle(.plain)
        .foregroundStyle(RugbyTheme.accent)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
    }

    /// 日(その日の0時)ごとの試合数。カレンダーに出す
    private var matchCountsByDay: [Date: Int] {
        let calendar = Calendar.current
        return matches.reduce(into: [:]) { counts, match in
            counts[calendar.startOfDay(for: match.playedAt), default: 0] += 1
        }
    }

    /// 試合のある日(古い順)
    private var matchDays: [Date] {
        Set(matches.map { Calendar.current.startOfDay(for: $0.playedAt) }).sorted()
    }

    // 例: 9月10日(木)。今年でなければ年も付ける(和暦設定の端末でも西暦で出す)
    private func dayTitle(_ day: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        let weekday = ["日", "月", "火", "水", "木", "金", "土"][(parts.weekday ?? 1) - 1]
        let text = "\(parts.month ?? 0)月\(parts.day ?? 0)日(\(weekday))"
        let thisYear = calendar.component(.year, from: Date())
        return parts.year == thisYear ? text : "\(parts.year ?? 0)年" + text
    }

    @ViewBuilder
    private func matchDestination(for match: Match, tallies: [UUID: MatchListTally]) -> some View {
        if tally(match, in: tallies).isFinished {
            MatchSummaryView(match: match)
        } else {
            LineupRegistrationView(match: match)
        }
    }

    private func count(for filter: MatchFilter, tallies: [UUID: MatchListTally]) -> Int {
        listModel.counts[filter] ?? 0
    }

    private func team(for id: UUID) -> Team? {
        listModel.teamsByID[id] ?? teams.first { $0.id == id }
    }

    private func teamName(for id: UUID) -> String {
        team(for: id)?.name ?? "チーム未設定"
    }

    private func tournamentName(for match: Match) -> String {
        listModel.tournamentNames[match.tournamentID]
            ?? tournaments.first { $0.id == match.tournamentID }?.officialName ?? "大会未設定"
    }

    /// 得点を数える。まず前回の控えを出し、前回から変わった試合(と控えに無い試合)だけ数え直す。
    /// 取り込みなどで全体が変わったときは全試合を数え直すが、控えがあれば画面は待たせない。
    private func refreshSummary() async {
        summaryError = nil
        if !didLoadTallyCache {
            didLoadTallyCache = true
            if let cached = await Task.detached(priority: .userInitiated, operation: { MatchListTallyCache.load() }).value {
                tallies = cached
                talliesRevision += 1
                hasTallyCache = true
                isLoadingSummary = false
            }
            checkedTallyCache = true
        } else {
            // 保存が続けて起きたとき(取り込み・まとめての変更)に、そのたびに数え直さないよう少し待つ。
            // 待っている間に次の保存が来たら、この回は取り消されて次の回だけが数える
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
        }
        let pending = MatchWorkStore.pending(.tallies)
        let sides = matches.map { MatchListSide(id: $0.id, home: $0.homeTeamID, away: $0.awayTeamID) }
        let full = !hasTallyCache || pending.all
        let targets = full ? sides : sides.filter { pending.matchIDs.contains($0.id) || tallies[$0.id] == nil }
        guard full || !targets.isEmpty else {
            if !pending.matchIDs.isEmpty { MatchWorkStore.clear(pending, from: .tallies) }   // 消えた試合の分
            isLoadingSummary = false
            return
        }
        isLoadingSummary = !hasTallyCache
        let container = modelContext.container
        let storeURL = container.configurations.first?.url
        let loading = Task.detached(priority: full ? .utility : .userInitiated) {
            // 全試合を数え直すときは、保存先のファイルを直接読む(約0.1秒。SwiftData だと数秒〜数十秒かかる)
            if full, let fast = MatchListFastTally.load(storeURL: storeURL, sides: targets) { return fast }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try MatchListSummary.load(context: context, sides: targets, onlyListed: !full)
        }
        do {
            let values = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            try Task.checkCancellation()
            if full {
                tallies = values
            } else {
                tallies.merge(values) { _, new in new }
            }
            talliesRevision += 1
            hasTallyCache = true
            isLoadingSummary = false
            MatchWorkStore.clear(pending, from: .tallies)
            let snapshot = tallies
            Task.detached(priority: .utility) { MatchListTallyCache.save(snapshot) }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            summaryError = "得点を読み込めませんでした。再読み込みしてください。"
            isLoadingSummary = false
        }
    }

    private func tally(_ match: Match, in tallies: [UUID: MatchListTally]) -> MatchListTally {
        tallies[match.id] ?? MatchListTally()
    }

    private func monthTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) &&
            calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return "今月の試合"
        }
        let month = calendar.component(.month, from: date)
        return "\(calendar.component(.year, from: date))年\(month)月"
    }

    private func dateText(_ date: Date) -> String {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) + " (\(weekday))"
    }

    private func deletionMessage(for match: Match) -> String {
        let date = match.playedAt.formatted(date: .numeric, time: .omitted)
        return "\(teamName(for: match.homeTeamID)) vs \(teamName(for: match.awayTeamID))\n\(date)\n\n記録したスタッツもすべて削除され、元に戻せません。"
    }

    private func deleteMatch(_ match: Match) {
        let matchID = match.id
        SafeDeletion.match(match, context: modelContext) {
            VideoStorage.deleteVideo(for: matchID)
            MatchClockSettingsCleanup.removeSettings(for: matchID)
        }
    }
}

private struct MatchCard: View {
    let match: Match
    let tournamentName: String
    let homeTeam: Team?
    let awayTeam: Team?
    let isFinished: Bool
    let homeScore: Int
    let awayScore: Int
    let homeFirstHalfScore: Int
    let awayFirstHalfScore: Int
    let homeSecondHalfScore: Int
    let awaySecondHalfScore: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var scoreSize = 20.0

    var body: some View {
        VStack(spacing: 12) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            headerLayout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tournamentName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(match.playedAt.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP"))))
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                HStack(spacing: 5) {
                    Image(systemName: isFinished ? "checkmark" : "record.circle")
                    Text(isFinished ? "終了" : "記録中")
                }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isFinished ? RugbyTheme.textSecondary : RugbyTheme.highlight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isFinished ? RugbyTheme.background : RugbyTheme.highlight.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 16) {
                    accessibleTeamScore(homeTeam, score: homeScore, fallback: .cyan)
                    accessibleTeamScore(awayTeam, score: awayScore, fallback: .orange)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    teamIdentity(homeTeam, fallback: .cyan)
                    // Reserve identical three-digit slots in every card. Team names
                    // and score digit counts must not resize the score or its frame.
                    HStack(spacing: 0) {
                        scoreCell(homeScore)
                        Text("–")
                            .font(.system(size: scoreSize * 0.8, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: scoreSize * 0.7)
                        scoreCell(awayScore)
                    }
                    .fixedSize()
                    .background(RugbyTheme.header, in: RoundedRectangle(cornerRadius: 6))
                    teamIdentity(awayTeam, fallback: .orange)
                }
            }
            Rectangle().fill(RugbyTheme.border).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack {
                    halfScores
                    Spacer(minLength: 8)
                    destinationLabel
                }
                VStack(alignment: .leading, spacing: 12) {
                    halfScores
                    destinationLabel
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RugbyTheme.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tournamentName)、\(match.playedAt.formatted(date: .abbreviated, time: .omitted))、\(homeTeam?.name ?? "チーム未設定") \(homeScore) 対 \(awayScore) \(awayTeam?.name ?? "チーム未設定")、\(isFinished ? "終了" : "記録中")")
        .accessibilityValue("前半 \(homeFirstHalfScore) 対 \(awayFirstHalfScore)、後半 \(homeSecondHalfScore) 対 \(awaySecondHalfScore)")
        .accessibilityHint(isFinished ? "試合サマリーを開きます" : "メンバー登録と記録を開きます")
    }

    private func scoreCell(_ score: Int) -> some View {
        Text("\(score)")
            .font(.system(size: scoreSize, weight: .heavy).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(width: scoreSize * 2.2, height: scoreSize * 2.0)
    }

    private var halfScores: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text("前半  \(homeFirstHalfScore)–\(awayFirstHalfScore)")
            Text("後半  \(homeSecondHalfScore)–\(awaySecondHalfScore)")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(RugbyTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var destinationLabel: some View {
        HStack(spacing: 6) {
            Text(isFinished ? "サマリー" : "記録を続ける")
            Image(systemName: "chevron.right")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isFinished ? RugbyTheme.textSecondary : RugbyTheme.accent)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func teamIdentity(_ team: Team?, fallback: Color) -> some View {
        VStack(spacing: 6) {
            teamLogo(team, fallback: fallback)
            Text(team?.name ?? "チーム未設定")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func accessibleTeamScore(_ team: Team?, score: Int, fallback: Color) -> some View {
        HStack(spacing: 12) {
            teamLogo(team, fallback: fallback)
            Text(team?.name ?? "チーム未設定").font(.headline)
            Spacer(minLength: 4)
            Text("\(score)").font(.title.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(RugbyTheme.textPrimary)
    }

    private func teamLogo(_ team: Team?, fallback: Color) -> some View {
        let color = team?.displayColor ?? fallback
        return StoredImageView(name: team?.logoPath, maxDimension: 160) { image in
            image.resizable().scaledToFit().padding(5)
        } placeholder: {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 36, height: 36)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            Team.self,
            Player.self,
            Tournament.self,
            Match.self,
            StatEvent.self,
            Substitution.self
        ], inMemory: true)
}
