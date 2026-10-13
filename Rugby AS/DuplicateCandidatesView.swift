//
//  DuplicateCandidatesView.swift
//  Rugby AS
//
//  チーム一覧から開く「重複の候補」。同じチーム・同じ人が2つに分かれていそうな組を並べ、
//  組ごとに「統合する」「同一人物としてつなぐ」「別人」を選ぶ。出場時期を並べるので、
//  重なっていなければ移籍、重なっていれば代表・国体など、と判断の手がかりになる。
//  候補が多いときは、種類の切り替え・検索で絞り、「選択」でまとめて「つなぐ」「別人」にできる
//  (統合は向きを1組ずつ確かめたいので、まとめてはしない)。
//

import SwiftData
import SwiftUI

struct DuplicateCandidatesView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var candidates: [DuplicateFinder.Candidate] = []
    @State private var teamsByID: [UUID: Team] = [:]
    @State private var playersByID: [UUID: Player] = [:]
    @State private var activity: [UUID: DuplicateFinder.Activity] = [:]
    @State private var tournamentNames: [UUID: String] = [:]
    @State private var hasLoaded = false
    @State private var loadGeneration = 0
    @State private var pendingTeamMerge: PendingTeamMerge?
    @State private var pendingPlayerMerge: PendingPlayerMerge?
    @State private var blockedMessage: String?
    // どちらを残すかを選ぶ画面に出している組と、選んだ結果(画面を閉じてから確認を出す)
    @State private var choosing: DuplicateFinder.Candidate?
    @State private var chosen: (candidate: DuplicateFinder.Candidate, keptID: UUID)?
    // まとめて操作
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    @State private var kindFilter: DuplicateFinder.Kind?
    @State private var searchText = ""
    @State private var pendingBulk: BulkAction?
    @State private var isConfirmingRestore = false

    private enum BulkAction: String, Identifiable {
        case link, dismiss
        var id: String { rawValue }
    }

    /// 種類と検索で絞った候補
    private var visibleCandidates: [DuplicateFinder.Candidate] {
        let key = DuplicateFinder.key(searchText)
        return candidates.filter { candidate in
            (kindFilter == nil || candidate.kind == kindFilter)
                && (key.isEmpty || [candidate.firstID, candidate.secondID].contains { searchKeys($0, kind: candidate.kind).contains { $0.contains(key) } })
        }
    }

    private func searchKeys(_ id: UUID, kind: DuplicateFinder.Kind) -> [String] {
        if kind == .team, let team = teamsByID[id] {
            return ([team.name] + team.aliases).map(DuplicateFinder.key)
        }
        guard let player = playersByID[id] else { return [] }
        return ([player.name, player.nameKana, teamsByID[player.teamID]?.name].compactMap { $0 } + player.aliases)
            .map(DuplicateFinder.key)
    }

    private var selectedCandidates: [DuplicateFinder.Candidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private var selectedLinkable: [DuplicateFinder.Candidate] {
        selectedCandidates.filter { $0.kind == .playerOtherTeam }
    }

    private struct PendingTeamMerge: Identifiable {
        let source: Team
        let target: Team
        let impact: TeamMerge.Impact
        var id: UUID { source.id }
    }

    private struct PendingPlayerMerge: Identifiable {
        let source: Player
        let target: Player
        let impact: PlayerMerge.Impact
        var id: UUID { source.id }
    }

    private var candidateList: some View {
        List {
            Section {
                Text("同じチーム・同じ選手が2つに分かれていそうな組です。自動ではまとめないので、組ごとに確かめて選んでください。「別人」を選んだ組は次から出ません。")
                    .font(.footnote)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            if !hasLoaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("候補を探しています…（選手が多いと少し時間がかかります）")
                            .font(.footnote)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                }
            }
            if hasLoaded && candidates.isEmpty {
                Section {
                    Text("重複の候補はありません")
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }
            if !candidates.isEmpty {
                Section {
                    Picker("種類", selection: $kindFilter) {
                        Text("すべて \(candidates.count)").tag(DuplicateFinder.Kind?.none)
                        Text("チーム \(count(.team))").tag(Optional(DuplicateFinder.Kind.team))
                        Text("同じチーム \(count(.playerSameTeam))").tag(Optional(DuplicateFinder.Kind.playerSameTeam))
                        Text("ほかのチーム \(count(.playerOtherTeam))").tag(Optional(DuplicateFinder.Kind.playerOtherTeam))
                    }
                    .pickerStyle(.menu)
                    if !searchText.isEmpty || kindFilter != nil {
                        Text("\(visibleCandidates.count)組を表示中")
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                }
            }
            candidateSection("チーム", kind: .team,
                             footer: "大会ごとの表記の違い・名前の変更など。対戦したことのあるチームどうしは出しません。")
            candidateSection("同じチームの選手", kind: .playerSameTeam,
                             footer: "誤字・表記ゆれ・苗字の変化など。同じ試合に2人とも出ている組は出しません。")
            candidateSection("ほかのチームの選手", kind: .playerOtherTeam,
                             footer: "移籍・代表・国体・合同チームなど。チームごとの登録は残したまま「同一人物としてつなぐ」と、個人成績でまとめて見られます。同姓同名の別人もいるので、出場時期などで確かめてください。")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RugbyTheme.background)
        .navigationTitle("重複の候補")
        .navigationBarTitleDisplayMode(.inline)
    }

    var body: some View {
        bulkDecorated(mergeDecorated(candidateList))
    }

    // 検索・選択・まとめて操作の確認
    private func bulkDecorated(_ content: some View) -> some View {
        content
        .searchable(text: $searchText, prompt: "チーム名・選手名・読みで絞り込む")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("「別人」にした組を候補に戻す（\(DuplicateFinder.dismissedIDs().count)組）") {
                        isConfirmingRestore = true
                    }
                    .disabled(DuplicateFinder.dismissedIDs().isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("その他")
                if !candidates.isEmpty {
                    Button(isSelecting ? "完了" : "選択") {
                        isSelecting.toggle()
                        if !isSelecting { selectedIDs = [] }
                    }
                    .fontWeight(isSelecting ? .bold : .regular)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !candidates.isEmpty { bulkBar }
        }
        .onChange(of: candidates.isEmpty) { _, isEmpty in
            // 候補がなくなったら選択をやめる(「選択」ボタンも消えるため)
            if isEmpty { isSelecting = false; selectedIDs = [] }
        }
        .confirmationDialog(
            pendingBulk == .link ? "まとめて同一人物としてつなぎますか？" : "まとめて別人にしますか？",
            isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
            titleVisibility: .visible,
            presenting: pendingBulk
        ) { action in
            switch action {
            case .link:
                Button("\(selectedLinkable.count)組をつなぐ") { performBulkLink() }
            case .dismiss:
                Button("\(selectedCandidates.count)組を別人にする", role: .destructive) { performBulkDismiss() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { action in
            switch action {
            case .link:
                Text("選んだ「ほかのチームの選手」の組を同一人物としてつなぎます。チームごとの登録はそのままで、あとから1人ずつ外せます。"
                     + (selectedCandidates.count > selectedLinkable.count ? "（チームと同じチームの選手の組はつなげないので含めません）" : ""))
            case .dismiss:
                Text("選んだ組を候補から外し、次からも出しません。右上の「…」から候補に戻せます。")
            }
        }
        .confirmationDialog("「別人」にした組を候補に戻しますか？", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
            Button("候補に戻す") {
                DuplicateFinder.restoreDismissed()
                load()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("統合・つなぐは元に戻りません。「別人」の印だけを消します。")
        }
    }

    // 読み込みと、統合の確認
    private func mergeDecorated(_ content: some View) -> some View {
        content
        .onAppear(perform: load)
        .onReceive(ModelSaveSignal.didSave) { _ in load() }
        .sheet(item: $choosing, onDismiss: requestChosenMerge) { candidate in
            MergeChoiceSheet(
                heading: candidate.kind == .team ? "残すチームを選ぶ" : "残す選手を選ぶ",
                first: option(candidate.kind, candidate.firstID),
                second: option(candidate.kind, candidate.secondID)
            ) { keptID in
                chosen = (candidate, keptID)
            }
        }
        .confirmationDialog(
            "チームを統合しますか？",
            isPresented: Binding(get: { pendingTeamMerge != nil }, set: { if !$0 { pendingTeamMerge = nil } }),
            titleVisibility: .visible,
            presenting: pendingTeamMerge
        ) { merge in
            Button("「\(merge.source.name)」を「\(merge.target.name)」に統合", role: .destructive) {
                TeamMerge.merge(merge.source, into: merge.target, context: modelContext,
                                removeImage: { ImageStorage.delete(named: $0) })
            }
            Button("キャンセル", role: .cancel) {}
        } message: { merge in
            let impact = merge.impact
            Text("""
            残す: \(merge.target.name)（\(DuplicateFinder.periodText(activity[merge.target.id]))）
            消える: \(merge.source.name)（\(DuplicateFinder.periodText(activity[merge.source.id]))）
            試合 \(impact.matches)・選手 \(impact.players)人・記録 \(impact.events)件・メンバー表 \(impact.lineups)件・大会 \(impact.tournaments) を付け替え、消える方の名前は別名として残します。元に戻せません。心配なときは先に設定からバックアップを書き出してください。
            """)
        }
        .confirmationDialog(
            "選手を統合しますか？",
            isPresented: Binding(get: { pendingPlayerMerge != nil }, set: { if !$0 { pendingPlayerMerge = nil } }),
            titleVisibility: .visible,
            presenting: pendingPlayerMerge
        ) { merge in
            Button("「\(numbered(merge.source))」を「\(numbered(merge.target))」に統合", role: .destructive) {
                PlayerMerge.merge(merge.source, into: merge.target, context: modelContext,
                                  removeImage: { ImageStorage.delete(named: $0) })
            }
            Button("キャンセル", role: .cancel) {}
        } message: { merge in
            let impact = merge.impact
            Text("""
            残す: \(playerSummary(merge.target))
            消える: \(playerSummary(merge.source))
            試合 \(impact.matches)・記録 \(impact.events)件・メンバー表 \(impact.lineups)件・交代 \(impact.substitutions)件 を付け替え、消える方の名前は別名として残します。元に戻せません。
            """)
        }
        .alert("統合できません", isPresented: Binding(get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(blockedMessage ?? "")
        }
    }

    // MARK: - 一覧

    @ViewBuilder
    private func candidateSection(_ title: String, kind: DuplicateFinder.Kind, footer: String) -> some View {
        let rows = visibleCandidates.filter { $0.kind == kind }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { candidate in
                    candidateRow(candidate)
                        .listRowBackground(selectedIDs.contains(candidate.id) ? RugbyTheme.accentSoft : RugbyTheme.surface)
                }
            } header: {
                HStack {
                    Text("\(title)（\(rows.count)）")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textSecondary)
                    Spacer()
                    if isSelecting {
                        let allSelected = rows.allSatisfy { selectedIDs.contains($0.id) }
                        Button(allSelected ? "選択を解除" : "すべて選択") {
                            if allSelected { rows.forEach { selectedIDs.remove($0.id) } }
                            else { rows.forEach { selectedIDs.insert($0.id) } }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .textCase(nil)
            } footer: {
                Text(footer)
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: DuplicateFinder.Candidate) -> some View {
        if isSelecting {
            Button {
                if selectedIDs.contains(candidate.id) { selectedIDs.remove(candidate.id) }
                else { selectedIDs.insert(candidate.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedIDs.contains(candidate.id) ? RugbyTheme.accent : RugbyTheme.textSecondary)
                        .padding(.top, 2)
                    candidateDetails(candidate, showsActions: false)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedIDs.contains(candidate.id) ? .isSelected : [])
        } else {
            candidateDetails(candidate, showsActions: true)
        }
    }

    private func candidateDetails(_ candidate: DuplicateFinder.Candidate, showsActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(candidate.reason)
                .font(.caption.weight(.bold))
                .foregroundStyle(RugbyTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RugbyTheme.accentSoft, in: Capsule())
            entityLine(candidate.kind, candidate.firstID)
            entityLine(candidate.kind, candidate.secondID)
            if showsActions {
                actions(candidate)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - まとめて操作

    private func count(_ kind: DuplicateFinder.Kind) -> Int {
        candidates.filter { $0.kind == kind }.count
    }

    private var bulkBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(selectedIDs.count)組を選択中")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Spacer()
                let allVisibleSelected = !visibleCandidates.isEmpty && visibleCandidates.allSatisfy { selectedIDs.contains($0.id) }
                Button(allVisibleSelected ? "選択を解除" : "表示中をすべて選択") {
                    if allVisibleSelected { selectedIDs = [] }
                    else { selectedIDs.formUnion(visibleCandidates.map(\.id)) }
                }
                .font(.subheadline)
            }
            HStack(spacing: 10) {
                Button {
                    pendingBulk = .link
                } label: {
                    Label("つなぐ（\(selectedLinkable.count)）", systemImage: "link")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(RugbyTheme.accent)
                .disabled(selectedLinkable.isEmpty)

                Button {
                    pendingBulk = .dismiss
                } label: {
                    Label("別人（\(selectedIDs.count)）", systemImage: "person.2.slash")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(RugbyTheme.textSecondary)
                .disabled(selectedIDs.isEmpty)
            }
            .font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func performBulkLink() {
        let pairs = selectedLinkable.compactMap { candidate -> (Player, Player)? in
            guard let a = playersByID[candidate.firstID], let b = playersByID[candidate.secondID] else { return nil }
            return (a, b)
        }
        let linkedIDs = Set(selectedLinkable.map(\.id))
        if PersonLink.linkAll(pairs, context: modelContext) > 0 {
            selectedIDs.subtract(linkedIDs)
        }
    }

    private func performBulkDismiss() {
        let chosen = selectedCandidates
        DuplicateFinder.dismissAll(chosen)
        let ids = Set(chosen.map(\.id))
        candidates.removeAll { ids.contains($0.id) }
        selectedIDs = []
    }

    private func entityLine(_ kind: DuplicateFinder.Kind, _ id: UUID) -> some View {
        let title: String
        let subtitle: String
        let color: Color
        if kind == .team, let team = teamsByID[id] {
            title = team.name
            subtitle = team.aliases.isEmpty ? "" : "別名: " + team.aliases.joined(separator: "、")
            color = team.displayColor
        } else if let player = playersByID[id] {
            let team = teamsByID[player.teamID]
            title = player.rosterDisplayName + (player.number.map { "  #\($0)" } ?? "")
            subtitle = [team?.name, player.nameKana].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・")
            color = team?.displayColor ?? RugbyTheme.textSecondary
        } else {
            title = "—"; subtitle = ""; color = RugbyTheme.textSecondary
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .team ? "shield.lefthalf.filled" : "person.fill")
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineLimit(2)
                }
                Text(DuplicateFinder.periodText(activity[id]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                if let tournaments = DuplicateFinder.tournamentText(activity[id], names: tournamentNames) {
                    Text(tournaments)
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ candidate: DuplicateFinder.Candidate) -> some View {
        HStack(spacing: 8) {
            switch candidate.kind {
            case .team, .playerSameTeam:
                Button("統合する…") { choosing = candidate }
                    .buttonStyle(.bordered)
            case .playerOtherTeam:
                if let a = playersByID[candidate.firstID], let b = playersByID[candidate.secondID] {
                    Button("同一人物としてつなぐ") {
                        PersonLink.link(a, with: b, context: modelContext)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button("別人") {
                DuplicateFinder.dismiss(candidate)
                candidates.removeAll { $0.id == candidate.id }
            }
            .buttonStyle(.bordered)
            .tint(RugbyTheme.textSecondary)
        }
        .font(.subheadline.weight(.semibold))
        .tint(RugbyTheme.accent)
    }

    // MARK: - 操作

    private func requestTeamMerge(source: Team, target: Team) {
        do {
            let impact = try TeamMerge.impact(of: source, into: target, context: modelContext)
            if impact.matchesBetween > 0 {
                blockedMessage = TeamMerge.MergeError.playedEachOther(impact.matchesBetween).errorDescription
            } else {
                pendingTeamMerge = PendingTeamMerge(source: source, target: target, impact: impact)
            }
        } catch { AppPersistence.report(error) }
    }

    private func requestPlayerMerge(source: Player, target: Player) {
        do {
            let impact = try PlayerMerge.impact(of: source, into: target, context: modelContext)
            if impact.matchesTogether > 0 {
                blockedMessage = PlayerMerge.MergeError.playedTogether(impact.matchesTogether).errorDescription
            } else {
                pendingPlayerMerge = PendingPlayerMerge(source: source, target: target, impact: impact)
            }
        } catch { AppPersistence.report(error) }
    }

    // MARK: - 読み込み

    /// 候補探しは裏で行う(全選手・全試合を見るので、画面の処理の中で行うと固まる)。
    /// 続けて保存されたときは、前の読み込みをやめて最後の1回だけ使う
    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let container = modelContext.container
        let dismissed = DuplicateFinder.dismissedIDs()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.loadScreen(container: container, dismissed: dismissed)
            }.value
            guard generation == loadGeneration else { return }
            // 画面で使うチームは全部(1,000ほど)、選手は候補に出る人だけ読む
            let teams = (try? modelContext.fetch(FetchDescriptor<Team>())) ?? []
            let ids = Array(Set(result.candidates.flatMap { [$0.firstID, $0.secondID] }))
            let players = ids.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<Player>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            teamsByID = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            playersByID = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            tournamentNames = result.tournamentNames
            activity = result.activity
            candidates = result.candidates
            // なくなった候補(統合・つないだ組など)の選択は外す
            selectedIDs.formIntersection(candidates.map(\.id))
            hasLoaded = true
        }
    }

    // MARK: - どちらを残すか

    /// 選ぶ画面に出す、見分けるための情報
    private func option(_ kind: DuplicateFinder.Kind, _ id: UUID) -> MergeChoiceSheet.Option {
        var lines: [String] = []
        if kind == .team, let team = teamsByID[id] {
            if !team.aliases.isEmpty { lines.append("別名: " + team.aliases.joined(separator: "、")) }
            lines.append(DuplicateFinder.periodText(activity[id]))
            if let text = DuplicateFinder.tournamentText(activity[id], names: tournamentNames) { lines.append(text) }
            let playerCount = (try? modelContext.fetchCount(FetchDescriptor<Player>(predicate: #Predicate { $0.teamID == id }))) ?? 0
            lines.append("選手 \(playerCount)人")
            return .init(id: id, title: team.name, symbol: "shield.lefthalf.filled", color: team.displayColor, lines: lines)
        }
        guard let player = playersByID[id] else {
            return .init(id: id, title: "—", symbol: "person.fill", color: RugbyTheme.textSecondary, lines: [])
        }
        let team = teamsByID[player.teamID]
        lines.append([player.number.map { "#\($0)" } ?? "背番号なし", team?.name].compactMap { $0 }.joined(separator: "・"))
        let profile = [player.nameKana, player.rugbyPosition?.name].compactMap { $0 }.filter { !$0.isEmpty }
        if !profile.isEmpty { lines.append(profile.joined(separator: "・")) }
        if !player.aliases.isEmpty { lines.append("別名: " + player.aliases.joined(separator: "、")) }
        lines.append(DuplicateFinder.periodText(activity[id]))
        if let text = DuplicateFinder.tournamentText(activity[id], names: tournamentNames) { lines.append(text) }
        return .init(id: id, title: player.rosterDisplayName, symbol: "person.fill",
                     color: team?.displayColor ?? RugbyTheme.textSecondary, lines: lines)
    }

    /// ボタンに出す選手名(同姓同名でも分かるよう背番号を付ける)
    private func numbered(_ player: Player) -> String {
        player.rosterDisplayName + (player.number.map { " #\($0)" } ?? "")
    }

    /// 確認に出す選手の見分け(例: 佐藤花子 #10・5試合・2025/4/1〜2025/12/1)
    private func playerSummary(_ player: Player) -> String {
        player.rosterDisplayName + (player.number.map { " #\($0)" } ?? "")
            + "（" + DuplicateFinder.periodText(activity[player.id]) + "）"
    }

    /// 選ぶ画面を閉じたあとに、選んだ方を残す統合の確認を出す
    private func requestChosenMerge() {
        guard let chosen else { return }
        self.chosen = nil
        let candidate = chosen.candidate
        let otherID = candidate.firstID == chosen.keptID ? candidate.secondID : candidate.firstID
        switch candidate.kind {
        case .team:
            if let target = teamsByID[chosen.keptID], let source = teamsByID[otherID] {
                requestTeamMerge(source: source, target: target)
            }
        case .playerSameTeam:
            if let target = playersByID[chosen.keptID], let source = playersByID[otherID] {
                requestPlayerMerge(source: source, target: target)
            }
        case .playerOtherTeam:
            break
        }
    }
}
