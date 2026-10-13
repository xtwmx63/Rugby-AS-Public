// 公式記録と同じく、許可が取れるまで配布版(Release)には入れない(OfficialRecordsView.swift の冒頭を参照)。
#if DEBUG
import SwiftData
import SwiftUI

/// 大会(段階をまとめたもの)を選ぶ画面。選ぶと、その大会の試合をまとめて取り込む確認画面へ進む。
struct OfficialTournamentPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [OfficialTournamentGroup] = []
    @State private var searchText = ""
    @State private var failure: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Text(failure).foregroundStyle(.secondary)
                } else if isLoading {
                    ProgressView("大会を読み込んでいます…")
                } else {
                    Section {
                        ForEach(filteredGroups) { group in
                            NavigationLink {
                                OfficialTournamentImportView(group: group)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name).font(.subheadline.bold()).lineLimit(3)
                                    Text("\(String(group.year))年度 · 終了\(group.finishedCount)試合"
                                         + (group.stages.count > 1 ? " · \(group.stages.count)段階" : "")
                                         + " · \(period(group))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 2)
                            }
                        }
                    } footer: {
                        Text("「予選リーグ」「準決勝」など段階ごとに分かれている大会は、1つの大会にまとめています。")
                    }
                }
            }
            .navigationTitle("大会をまとめて取り込む")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "大会名")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task { await load() }
        }
    }

    private var filteredGroups: [OfficialTournamentGroup] {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        return groups.filter { group in words.allSatisfy { group.name.localizedCaseInsensitiveContains($0) } }
    }

    private func period(_ group: OfficialTournamentGroup) -> String {
        let first = group.firstDate.replacingOccurrences(of: "-", with: "/")
        let last = group.lastDate.replacingOccurrences(of: "-", with: "/")
        return first == last ? first : "\(first)〜\(last.suffix(5))"
    }

    private func load() async {
        guard let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else {
            failure = OfficialArchiveError.missing.localizedDescription
            isLoading = false
            return
        }
        do {
            let stages = try await Task.detached(priority: .userInitiated) { try OfficialRecordsStore.tournamentStages(at: url) }.value
            // 終わった試合がない大会(これからの予定だけ)は取り込めないので出さない
            groups = OfficialTournamentGrouping.groups(from: stages).filter { $0.finishedCount > 0 }
        } catch {
            failure = error.localizedDescription
        }
        isLoading = false
    }
}

/// 1つの大会の試合を一覧で確認し、選んだ試合をまとめて保存する画面。
struct OfficialTournamentImportView: View {
    let group: OfficialTournamentGroup

    private struct Item: Identifiable {
        let id: String
        var draft: OfficialImportDraft
        let stage: String
        let isDuplicate: Bool
        var isSelected: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var teams: [Team]
    @Query private var matches: [Match]
    @State private var items: [Item] = []
    @State private var skippedCount = 0
    @State private var tournamentName = ""
    @State private var includesLineups = true
    @State private var isLoading = true
    @State private var failure: String?
    @State private var loadFailure: String?
    @State private var savedCount: Int?

    var body: some View {
        List {
            if isLoading {
                ProgressView("試合を読み込んでいます…")
            } else if let loadFailure {
                Text(loadFailure).foregroundStyle(.secondary)
            } else {
                Section {
                    LabeledContent("大会") {
                        TextField("大会名", text: $tournamentName).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("年度", value: String(group.year))
                    Toggle("メンバー表も取り込む", isOn: $includesLineups)
                } footer: {
                    Text("選んだ試合は、すべてこの大会に入ります。チームと選手は、同じ名前のものが既にあれば使い回します。")
                }
                Section {
                    ForEach($items) { $item in
                        Button { item.isSelected.toggle() } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("試合（\(selectedCount) / \(items.count)件を取り込む）")
                        Spacer()
                        Button(selectedCount == items.count ? "すべて外す" : "すべて選ぶ") {
                            let select = selectedCount != items.count
                            for index in items.indices { items[index].isSelected = select }
                        }.font(.caption).textCase(nil)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("タップで取り込む／取り込まないを切り替えます。すでに取り込んだと思われる試合は、最初から外しています。")
                        if skippedCount > 0 { Text("予定・中止など、終了していない試合\(skippedCount)件は含めません。") }
                        if mismatchCount > 0 { Text("⚠️ の試合は、得点経過の合計が公式スコアと合いません。取り込み後にプレー一覧で確認してください。") }
                    }
                }
            }
        }
        .navigationTitle("取り込みの確認")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("\(selectedCount)試合を保存") { save() }
                    .disabled(isLoading || selectedCount == 0
                              || tournamentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { await load() }
        .alert("保存できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { }
        } message: { Text(failure ?? "") }
        .alert("取り込みました", isPresented: Binding(get: { savedCount != nil }, set: { if !$0 { savedCount = nil } })) {
            Button("閉じる") { dismiss() }
        } message: { Text("\(savedCount ?? 0)試合を「\(tournamentName)」に追加しました。試合一覧や大会の画面から開けます。") }
    }

    private var selectedCount: Int { items.filter(\.isSelected).count }
    private var mismatchCount: Int { items.filter { $0.draft.matchesOfficialScore == false }.count }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.draft.playedAt.formatted(.dateTime.month().day())).monospacedDigit()
                    if !item.stage.isEmpty { Text(item.stage).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(item.draft.homeTeamName).lineLimit(1)
                    Text("\(item.draft.score(side: "home")) - \(item.draft.score(side: "away"))").bold().monospacedDigit()
                    Text(item.draft.awayTeamName).lineLimit(1)
                }.font(.subheadline)
                if item.isDuplicate {
                    Label("同じ日の同じ対戦が既にあります", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                } else if item.draft.matchesOfficialScore == false {
                    Label("公式スコア \(item.draft.officialHomeScore ?? 0) - \(item.draft.officialAwayScore ?? 0) と合いません", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(item.isSelected ? 1 : 0.45)
        .contentShape(Rectangle())
    }

    private func load() async {
        tournamentName = group.name
        guard let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else {
            loadFailure = OfficialArchiveError.missing.localizedDescription
            isLoading = false
            return
        }
        do {
            let stages = group.stages, years = group.years
            let records = try await Task.detached(priority: .userInitiated) {
                try OfficialRecordsStore.records(at: url, tournaments: stages, years: years)
            }.value
            let finished = records.filter { $0.status == "finished" }
            skippedCount = records.count - finished.count
            items = finished.map { record in
                let draft = OfficialRecordImporter.draft(from: record)
                let duplicate = OfficialRecordImporter.hasSameDayMatch(draft, teams: teams, matches: matches)
                return Item(id: record.id, draft: draft, stage: OfficialTournamentGrouping.stageName(record.tournament),
                            isDuplicate: duplicate, isSelected: !duplicate)
            }
        } catch {
            loadFailure = error.localizedDescription
        }
        isLoading = false
    }

    private func save() {
        let drafts = items.filter(\.isSelected).map { item -> OfficialImportDraft in
            var draft = item.draft
            draft.tournamentName = tournamentName
            draft.year = group.year   // 年末年始をまたいでも、大会は始まった年度で1つにする
            draft.includesLineups = includesLineups && !draft.members.isEmpty
            return draft
        }
        do {
            try OfficialRecordImporter.saveAll(drafts, context: modelContext)
            savedCount = drafts.count
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Preview only IDs and counts, then load/save small chunks for large archives.
struct OfficialBulkImportView: View {
    let filteredQuery: OfficialArchiveQuery
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var usesFilter = false
    @State private var includesLineups = true
    @State private var pendingIDs: [String] = []
    @State private var duplicateCount = 0
    @State private var partialCount = 0
    @State private var mismatchCount = 0
    @State private var scanned = 0
    @State private var total = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var stopRequested = false
    @State private var processed = 0
    @State private var saved = 0
    @State private var failure: String?
    @State private var result: String?
    @State private var refresh = UUID()
    @State private var continuesInBackground = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("取り込む範囲", selection: $usesFilter) {
                        Text("すべての公式記録").tag(false)
                        Text("現在の絞り込み範囲").tag(true)
                    }
                    .disabled(isSaving)
                    Toggle("メンバー表も取り込む", isOn: $includesLineups).disabled(isSaving)
                } footer: {
                    Text("終了した試合のうち、未取り込みのものを追加します。大会ごとに分けて保存し、既存の試合は変更しません。動画は含みません。")
                }
                if isLoading {
                    Section {
                        ProgressView("未取り込みの試合を確認中…")
                        if total > 0 { Text("\(scanned) / \(total)試合を確認").font(.caption) }
                    }
                } else {
                    Section {
                        LabeledContent("新しく取り込む試合", value: "\(pendingIDs.count)試合")
                        LabeledContent("取り込み済み・同じ対戦を除外", value: "\(duplicateCount)試合")
                        if partialCount > 0 { LabeledContent("一部情報が未掲載", value: "\(partialCount)試合") }
                        if mismatchCount > 0 { LabeledContent("得点経過の確認が必要", value: "\(mismatchCount)試合") }
                    } footer: {
                        Text("未掲載の情報は補完しません。得点経過が公式スコアと合わない試合は、取り込み後に確認・修正できます。")
                    }
                    if isSaving {
                        Section {
                            ProgressView(value: Double(processed), total: Double(max(1, pendingIDs.count)))
                            Text("\(processed) / \(pendingIDs.count)試合を処理・\(saved)試合を保存")
                            Button(stopRequested ? "停止しています…" : "ここで停止") { stopRequested = true }
                                .disabled(stopRequested)
                        } footer: {
                            Text(continuesInBackground
                                 ? "ホームに戻ったり画面を消したりしても取り込みを続けます。進み具合はロック画面などにも表示され、そこから止めることもできます。停止しても保存済みの試合は残り、次回は残りを取り込めます。"
                                 : "取り込み中は画面が自動で消えないようにしています。アプリを離れると少しで止まります(保存済みの試合は残り、次回は残りを取り込めます)。")
                        }
                    } else if let result {
                        Section {
                            Text(result)
                            Button("未取り込みの試合を再確認") { refresh = UUID() }
                        }
                    } else if failure == nil {
                        Section {
                            if pendingIDs.isEmpty {
                                Text("この範囲に未取り込みの終了済み試合はありません。")
                            } else {
                                Button("未取り込みの\(pendingIDs.count)試合を取り込む") {
                                    isSaving = true
                                    Task { await save() }
                                }.bold()
                            }
                        }
                    }
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                        if !isSaving { Button("未取り込みの試合を再確認") { refresh = UUID() } }
                    }
                }
            }
            .navigationTitle("未取り込みをまとめて追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }.disabled(isSaving)
                }
            }
            .task(id: "\(usesFilter)-\(refresh)") { await load() }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func load() async {
        isLoading = true
        failure = nil; result = nil
        pendingIDs = []; duplicateCount = 0; partialCount = 0; mismatchCount = 0
        scanned = 0; total = 0
        guard let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else {
            failure = OfficialArchiveError.missing.localizedDescription
            isLoading = false
            return
        }
        do {
            var duplicates = try OfficialRecordImporter.DuplicateIndex(context: modelContext)
            // A selected status is respected; only completed records can be imported.
            var query = usesFilter ? filteredQuery : OfficialArchiveQuery()
            if query.status.isEmpty { query.status = "finished" }
            let scope = query
            var offset = 0
            while true {
                try Task.checkCancellation()
                let pageOffset = offset
                let (page, records) = try await Task.detached(priority: .userInitiated) {
                    let page = try OfficialRecordsStore.search(at: url, query: scope, offset: pageOffset)
                    let records = try OfficialRecordsStore.records(at: url, ids: page.matches.filter { $0.status == "finished" }.map(\.id))
                    return (page, records)
                }.value
                try Task.checkCancellation()
                total = page.total
                for record in records {
                    let draft = OfficialRecordImporter.draft(from: record)
                    if duplicates.contains(draft) { duplicateCount += 1; continue }
                    duplicates.insert(draft)
                    pendingIDs.append(record.id)
                    if record.detailLevel != "full" { partialCount += 1 }
                    if draft.matchesOfficialScore == false { mismatchCount += 1 }
                }
                offset += page.matches.count
                scanned = offset
                if offset >= page.total || page.matches.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            isLoading = false
        } catch is CancellationError { }
        catch {
            failure = error.localizedDescription
            isLoading = false
        }
    }

    private func save() async {
        stopRequested = false; saved = 0; processed = 0; failure = nil; result = nil
        defer { isSaving = false }
        guard let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else {
            failure = OfficialArchiveError.missing.localizedDescription
            return
        }
        do {
            // Persist pending personal edits before opening the isolated import context.
            guard AppPersistence.save(modelContext) else {
                failure = "編集中のデータを保存できませんでした。もう一度お試しください。"
                return
            }
            // ホームに戻っても続けられるようにする(iOS やユーザーに止められたら「停止」と同じ扱い)
            let session = LongImportSession(title: "公式記録を取り込み中", total: pendingIDs.count) { stopRequested = true }
            session.start()
            continuesInBackground = session.runsInBackground
            var succeeded = false
            defer { session.finish(success: succeeded) }
            let worker = await OfficialBulkImportWorker.make(container: modelContext.container)
            let batchSize = OfficialBulkImportWorker.batchSize
            for start in stride(from: 0, to: pendingIDs.count, by: batchSize) {
                if stopRequested || Task.isCancelled { break }
                let ids = Array(pendingIDs[start..<min(start + batchSize, pendingIDs.count)])
                saved += try await worker.saveBatch(archiveURL: url, ids: ids, includesLineups: includesLineups)
                processed += ids.count
                session.update(completed: processed, subtitle: "\(processed) / \(pendingIDs.count)試合")
                await Task.yield()
            }
            succeeded = processed >= pendingIDs.count
            result = "\(saved)試合を保存しました。" + (processed < pendingIDs.count ? "残りは再確認して続けて取り込めます。" : "試合一覧や大会の画面から開けます。")
        } catch {
            failure = "\(saved)試合は保存済みです。残りを取り込めませんでした。再確認して続きから取り込めます。\n" + error.localizedDescription
        }
    }
}
#endif
