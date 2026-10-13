// 公式記録は各団体の利用規約により、許可が取れるまで配布版(Release)に入れない。
// Xcode から実機に入れる開発版(Debug)だけで使う。データファイルも Release では同梱しない
// (project の EXCLUDED_SOURCE_FILE_NAMES)。
#if DEBUG
import SwiftUI
import SafariServices
import Combine

struct OfficialRecordsView: View {
    @StateObject private var model = OfficialRecordsModel()
    @State private var query = OfficialArchiveQuery(status: "finished")
    @State private var showsFilters = false
    @State private var showsCoverage = false
    @State private var showsTournamentImport = false
    @State private var showsBulkImport = false
    @State private var retry = 0

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("分析の前に、公式記録を調べる")
                        .font(.headline)
                    if let manifest = model.manifest {
                        Text("収録 \(manifest.matchCount.formatted())試合 · \(OfficialRecordFormatting.date(manifest.generatedAt))更新")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("日本ラグビーフットボール協会・リーグワン・トップリーグ・SVNS")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Button { showsFilters = true } label: {
                    HStack {
                        Label("絞り込み", systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        Text(query.filterCount == 0 ? "すべて" : "\(query.filterCount)件の条件")
                            .foregroundStyle(.secondary)
                    }
                }.disabled(model.options == nil)
                Button { showsTournamentImport = true } label: {
                    Label("大会ごとにまとめて取り込む", systemImage: "square.and.arrow.down.on.square")
                }.disabled(model.manifest == nil)
                Button { showsBulkImport = true } label: {
                    Label("未取り込みの試合をまとめて取り込む", systemImage: "square.stack.3d.up")
                }.disabled(model.manifest == nil)
                if query.filterCount > 0 {
                    Text(filterDescription).font(.caption).foregroundStyle(.secondary)
                    Button("絞り込みを解除") {
                        let text = query.text
                        query = OfficialArchiveQuery()
                        query.text = text
                    }
                }
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button("再読み込み") { retry += 1 }
                }
            } else if model.isLoading {
                Section { ProgressView("公式記録を検索しています…") }
            } else if model.matches.isEmpty {
                Section {
                    ContentUnavailableView(
                        "該当する試合がありません", systemImage: "magnifyingglass",
                        description: Text("チーム名・大会名や、絞り込み条件を変更してください。")
                    )
                }
            } else {
                Section {
                    ForEach(model.matches) { match in
                        NavigationLink {
                            OfficialRecordDetailView(id: match.id)
                        } label: {
                            OfficialRecordRow(match: match)
                        }
                    }
                    if model.matches.count < model.total {
                        Button {
                            Task { await model.loadMore(query: query) }
                        } label: {
                            HStack {
                                Spacer()
                                if model.isLoadingMore { ProgressView() }
                                else { Text("さらに表示（\(model.matches.count.formatted()) / \(model.total.formatted())）") }
                                Spacer()
                            }.padding(.vertical, 8)
                        }.disabled(model.isLoadingMore)
                    }
                } header: {
                    Text("検索結果 \(model.total.formatted())試合")
                } footer: {
                    Text("収録時点の公式情報です。未取得の得点は「—」と表示します。最新の情報は各試合の公式ページで確認できます。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .padContentWidth(900)
        .navigationTitle("公式記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query.text, prompt: "チーム名・大会名")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsCoverage = true } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("公式記録の収録範囲と更新日")
                .disabled(model.manifest == nil)
            }
        }
        .task(id: retry) { await model.loadMetadata() }
        .task(id: SearchTaskKey(query: query, retry: retry)) { await model.search(query: query) }
        .sheet(isPresented: $showsFilters) {
            if let options = model.options { OfficialRecordFilters(query: $query, options: options) }
        }
        .sheet(isPresented: $showsTournamentImport) { OfficialTournamentPickerView() }
        .sheet(isPresented: $showsBulkImport) { OfficialBulkImportView(filteredQuery: query) }
        .sheet(isPresented: $showsCoverage) {
            if let manifest = model.manifest { OfficialArchiveCoverageView(manifest: manifest) }
        }
    }

    private var filterDescription: String {
        [query.source.isEmpty ? "" : OfficialRecordFormatting.source(query.source), query.category,
         query.year.isEmpty ? "" : "\(query.year)年", query.season, query.tournament,
         query.status.isEmpty ? "" : OfficialRecordFormatting.status(query.status)]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private struct SearchTaskKey: Equatable {
        let query: OfficialArchiveQuery
        let retry: Int
    }
}

@MainActor
private final class OfficialRecordsModel: ObservableObject {
    @Published var manifest: OfficialArchiveManifest?
    @Published var options: OfficialArchiveOptions?
    @Published var matches: [OfficialRecordSummary] = []
    @Published var total = 0
    @Published var isLoading = true
    @Published var isLoadingMore = false
    @Published var error: String?
    private var requestID = UUID()
    private let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite")

    func loadMetadata() async {
        guard let url else { error = OfficialArchiveError.missing.localizedDescription; return }
        let task = Task.detached(priority: .userInitiated) { try OfficialRecordsStore.metadata(at: url) }
        do {
            let (manifest, options) = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            self.manifest = manifest
            self.options = options
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func search(query: OfficialArchiveQuery) async {
        let id = UUID()
        requestID = id
        isLoading = true
        isLoadingMore = false
        error = nil
        guard let url else {
            error = OfficialArchiveError.missing.localizedDescription
            isLoading = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(180))
            let task = Task.detached(priority: .userInitiated) { try OfficialRecordsStore.search(at: url, query: query) }
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard requestID == id else { return }
            matches = page.matches
            total = page.total
            isLoading = false
        } catch is CancellationError { }
        catch {
            guard requestID == id else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    func loadMore(query: OfficialArchiveQuery) async {
        guard !isLoading, !isLoadingMore, let url, matches.count < total else { return }
        let id = requestID
        let offset = matches.count
        isLoadingMore = true
        do {
            let task = Task.detached(priority: .userInitiated) {
                try OfficialRecordsStore.search(at: url, query: query, offset: offset)
            }
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard id == requestID else { return }
            matches.append(contentsOf: page.matches)
            total = page.total
            isLoadingMore = false
        } catch {
            guard id == requestID else { return }
            self.error = error.localizedDescription
            isLoadingMore = false
        }
    }
}

private struct OfficialRecordRow: View {
    let match: OfficialRecordSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(OfficialRecordFormatting.date(match.date))
                if !match.kickoff.isEmpty { Text(match.kickoff + (["svns", "rwc"].contains(match.source) ? " 現地" : "")) }
                Spacer(minLength: 4)
                Text(OfficialRecordFormatting.status(match.status))
            }.font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 5) {
                scoreLine(team: match.homeTeam, score: match.homeScore)
                scoreLine(team: match.awayTeam, score: match.awayScore)
            }

            Text([match.tournament, match.round].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(match.category)
                    .foregroundStyle(.blue)
                Text(match.detailLevel == "full" ? "詳細あり" : "試合概要")
                    .foregroundStyle(.secondary)
            }.font(.caption2)
        }.padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func scoreLine(team: String, score: Int?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(team.isEmpty ? "チーム未定" : team).font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text(OfficialRecordFormatting.score(score)).font(.title3.bold().monospacedDigit())
                .accessibilityLabel(score.map { "\($0)点" } ?? "得点未取得")
        }
    }
}

private struct OfficialRecordFilters: View {
    @Binding var query: OfficialArchiveQuery
    let options: OfficialArchiveOptions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("試合の状態", selection: $query.status) {
                        Text("すべて").tag("")
                        Text("試合終了").tag("finished")
                        Text("試合予定").tag("scheduled")
                        Text("中止・延期").tag("cancelled")
                        Text("状況未取得").tag("unknown")
                    }
                    Picker("掲載元", selection: $query.source) {
                        Text("すべて").tag("")
                        ForEach(options.sources, id: \.self) { Text(OfficialRecordFormatting.source($0)).tag($0) }
                    }
                    picker("カテゴリー", values: options.categories, selection: $query.category)
                    picker("年", values: options.years, selection: $query.year)
                    picker("シーズン", values: options.seasons, selection: $query.season)
                    picker("大会", values: options.tournaments, selection: $query.tournament)
                } footer: {
                    Text("年は、協会では掲載年、リーグワンではシーズンの開始年です。複数の条件を指定すると、すべてに一致する試合を表示します。")
                }
                Section {
                    Button("すべての絞り込みを解除") {
                        let text = query.text
                        query = OfficialArchiveQuery()
                        query.text = text
                    }.disabled(query.filterCount == 0)
                }
            }
            .navigationTitle("公式記録を絞り込む")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }

    private func picker(_ title: String, values: [String], selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("すべて").tag("")
            ForEach(values, id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.navigationLink)
    }
}

private struct OfficialArchiveCoverageView: View {
    let manifest: OfficialArchiveManifest
    @Environment(\.dismiss) private var dismiss
    @State private var sourceLink: OfficialSourceLink?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("収録試合", value: "\(manifest.matchCount.formatted())試合")
                    LabeledContent("詳細あり", value: "\(manifest.fullDetailCount.formatted())試合")
                    LabeledContent("更新日", value: OfficialRecordFormatting.date(manifest.generatedAt))
                    Text("アプリに収録された公式記録をオフラインで検索できます。掲載元の更新は、このデータベースには自動反映されません。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("このデータベースについて") }
                Section {
                    ForEach(Array(manifest.coverage.enumerated()), id: \.offset) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.element.category).font(.headline)
                            Text("\(OfficialRecordFormatting.source(item.element.source)) · \(item.element.season)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("収録 \(item.element.imported) / 掲載 \(item.element.discovered)試合 · 詳細 \(item.element.fullDetails)試合")
                                .font(.subheadline).monospacedDigit()
                            if let link = OfficialSourceLink(item.element.scheduleURL) {
                                Button("公式の日程・結果を見る") { sourceLink = link }.font(.caption)
                            }
                        }.padding(.vertical, 4)
                    }
                } header: { Text("カテゴリー別の収録範囲") } footer: {
                    Text("「詳細あり」は公式の試合詳細を取得できた試合です。同じ試合が複数のカテゴリーに含まれるため、カテゴリー別の件数の合計は収録試合数と一致しません。協会とリーグワンの両方に掲載された同じ試合は、掲載元ごとに収録しています。")
                }
                if !manifest.errors.isEmpty {
                    Section {
                        Text("取得・確認が完了していない項目が\(manifest.errors.count)件あります。試合概要のみの記録では、公式ページから詳細をご確認ください。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } header: { Text("未取得の情報") }
                }
            }
            .navigationTitle("収録範囲・出典")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .fullScreenCover(item: $sourceLink) { link in
                OfficialLinkBrowser(url: link.url) { sourceLink = nil }.ignoresSafeArea()
            }
        }
    }
}

struct OfficialRecordDetailView: View {
    let id: String
    @State private var record: OfficialRecord?
    @State private var failure: String?
    @State private var retry = 0
    @State private var sourceLink: OfficialSourceLink?
    @State private var isImportPresented = false

    var body: some View {
        List {
            if let record {
                overview(record)
                importSection(record)
                sourceSection(record)
                Section {
                    recordCoverage(record)
                } header: { Text("この試合の収録状況") }
                if !record.stats.isEmpty { statistics(record) }
                if !record.players.isEmpty { players(record) }
                if !record.scoreEvents.isEmpty { scoreEvents(record) }
                if !record.substitutions.isEmpty { substitutions(record) }
            } else if let failure {
                Section {
                    Text(failure).foregroundStyle(.secondary)
                    Button("再読み込み") { retry += 1 }
                }
            } else { ProgressView("公式記録を開いています…") }
        }
        .listStyle(.insetGrouped)
        .padContentWidth(900)
        .navigationTitle("試合の公式記録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: retry) { await load() }
        .fullScreenCover(item: $sourceLink) { link in
            OfficialLinkBrowser(url: link.url) { sourceLink = nil }.ignoresSafeArea()
        }
        .sheet(isPresented: $isImportPresented) {
            if let record { OfficialRecordImportView(record: record) }
        }
    }

    // 自分の試合として取り込む入口。得点経過がない試合は取り込めるものがないので押せなくする。
    private func importSection(_ record: OfficialRecord) -> some View {
        Section {
            Button {
                isImportPresented = true
            } label: {
                Label("この試合を取り込む", systemImage: "square.and.arrow.down")
                    .foregroundStyle(record.scoreEvents.isEmpty ? Color.secondary : Color.accentColor)
            }
            .disabled(record.scoreEvents.isEmpty)
        } footer: {
            Text(record.scoreEvents.isEmpty
                 ? "この試合は得点経過が収録されていないため取り込めません。"
                 : "得点経過とメンバー表から、自分の試合を作ります。保存する前に内容を確認できます。")
        }
    }

    private func overview(_ record: OfficialRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.tournament).font(.headline)
                Text([record.round, OfficialRecordFormatting.date(record.date),
                      record.kickoff + (["svns", "rwc"].contains(record.source) && !record.kickoff.isEmpty ? " 現地時刻" : "")]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(record.homeTeam).font(.headline)
                    Spacer(minLength: 16)
                    Text(OfficialRecordFormatting.score(record.homeScore)).font(.largeTitle.bold().monospacedDigit())
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(record.awayTeam).font(.headline)
                    Spacer(minLength: 16)
                    Text(OfficialRecordFormatting.score(record.awayScore)).font(.largeTitle.bold().monospacedDigit())
                }
                HStack {
                    Text(OfficialRecordFormatting.status(record.status))
                    Spacer()
                    Text(record.categoryMemberships.joined(separator: " · "))
                }.font(.caption).foregroundStyle(.secondary)
                if !record.venue.isEmpty { Label(record.venue, systemImage: "mappin.and.ellipse").font(.caption) }
            }.padding(.vertical, 8)
            if record.homeFirstHalfScore != nil || record.awayFirstHalfScore != nil ||
                record.homeSecondHalfScore != nil || record.awaySecondHalfScore != nil {
                pairedValue("得点", home: record.homeTeam, away: record.awayTeam).font(.caption)
                pairedValue("前半", home: OfficialRecordFormatting.score(record.homeFirstHalfScore),
                            away: OfficialRecordFormatting.score(record.awayFirstHalfScore))
                pairedValue("後半", home: OfficialRecordFormatting.score(record.homeSecondHalfScore),
                            away: OfficialRecordFormatting.score(record.awaySecondHalfScore))
            }
        } footer: { Text("得点・スタッツの「—」は未取得を示し、0とは区別しています。") }
    }

    private func sourceSection(_ record: OfficialRecord) -> some View {
        Section {
            if let link = OfficialSourceLink(record.sourceURL) {
                Button { sourceLink = link } label: { Label("公式の試合ページ", systemImage: "safari") }
            }
            if let raw = record.officialRecordURL, raw != record.sourceURL, let link = OfficialSourceLink(raw) {
                Button { sourceLink = link } label: { Label("公式記録票", systemImage: "doc.text") }
            }
            Text("\(OfficialRecordFormatting.source(record.source)) · \(OfficialRecordFormatting.date(record.fetchedAt))取得")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("出典") } footer: { Text("公式ページの閲覧にはインターネット接続が必要です。") }
    }

    private func recordCoverage(_ record: OfficialRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.detailLevel == "full" ? "試合詳細を収録" : "試合概要を収録").font(.subheadline.bold())
            Text([
                "メンバー \(record.players.isEmpty ? "未収録" : "\(record.players.count)名")",
                "得点経過 \(record.scoreEvents.isEmpty ? "未収録" : "\(record.scoreEvents.count)件")",
                "交代 \(record.substitutions.isEmpty ? "未収録" : "\(record.substitutions.count)件")",
                "スタッツ \(record.stats.isEmpty ? "未収録" : "\(record.stats.count)項目")"
            ].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            ForEach(record.omissions ?? [], id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if record.detailLevel != "full" {
                Text("詳細は公式ページでご確認ください。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statistics(_ record: OfficialRecord) -> some View {
        Section {
            pairedValue("項目", home: record.homeTeam, away: record.awayTeam).font(.caption)
            ForEach(Array(record.stats.enumerated()), id: \.offset) { item in
                pairedValue(item.element.label, home: item.element.home, away: item.element.away)
            }
        } header: { Text("公式スタッツ") }
    }

    @ViewBuilder private func players(_ record: OfficialRecord) -> some View {
        ForEach(["home", "away"], id: \.self) { side in
            let rows = record.players.filter { $0.side == side }
            if !rows.isEmpty {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.element.number.map(String.init) ?? "—")
                                .font(.subheadline.bold().monospacedDigit()).frame(minWidth: 24, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.element.name.isEmpty ? "氏名未取得" : item.element.name)
                                let note = [item.element.position, item.element.role].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 2)
                    }
                } header: { Text("メンバー · \(team(side, record: record))") }
            }
        }
    }

    private func scoreEvents(_ record: OfficialRecord) -> some View {
        Section {
            ForEach(Array(record.scoreEvents.enumerated()), id: \.offset) { item in
                let event = item.element
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text([event.period, event.time, event.kind].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline.bold())
                        Spacer(minLength: 8)
                        if event.homeScore != nil || event.awayScore != nil {
                            Text("\(OfficialRecordFormatting.score(event.homeScore)) – \(OfficialRecordFormatting.score(event.awayScore))")
                                .font(.subheadline.monospacedDigit())
                        }
                    }
                    if !event.player.isEmpty { Text(event.player).font(.subheadline) }
                    if !event.side.isEmpty { Text(team(event.side, record: record)).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        } header: { Text("得点経過") }
    }

    private func substitutions(_ record: OfficialRecord) -> some View {
        Section {
            ForEach(Array(record.substitutions.enumerated()), id: \.offset) { item in
                let change = item.element
                VStack(alignment: .leading, spacing: 6) {
                    Text([change.period, change.time, change.kind].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline.bold())
                    if change.kind == "退出" && change.incoming.isEmpty {
                        Text("OUT \(change.outgoing.isEmpty ? "未取得" : change.outgoing)").font(.subheadline)
                    } else {
                        Text("OUT \(change.outgoing.isEmpty ? "未取得" : change.outgoing) → IN \(change.incoming.isEmpty ? "未取得" : change.incoming)")
                            .font(.subheadline)
                    }
                    Text(team(change.side, record: record)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
        } header: { Text("交代") }
    }

    private func pairedValue(_ label: String, home: String, away: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(home.isEmpty ? "—" : home).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            Text(away.isEmpty ? "—" : away).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func team(_ side: String, record: OfficialRecord) -> String {
        side == "home" ? record.homeTeam : side == "away" ? record.awayTeam : "チーム未取得"
    }

    private func load() async {
        failure = nil
        guard let url = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite") else {
            failure = OfficialArchiveError.missing.localizedDescription
            return
        }
        let selectedID = id
        let task = Task.detached(priority: .userInitiated) { try OfficialRecordsStore.detail(at: url, id: selectedID) }
        do {
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            record = loaded
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }
}

private enum OfficialRecordFormatting {
    static func source(_ source: String) -> String {
        source == "jrfu" ? "日本ラグビーフットボール協会" : source == "leagueone" ? "リーグワン" : source == "topleague" ? "トップリーグ" : source == "svns" ? "HSBC SVNS" : source == "rwc" ? "World Rugby（W杯）" : source
    }

    static func status(_ status: String) -> String {
        switch status {
        case "finished": return "試合終了"
        case "scheduled": return "試合予定"
        case "cancelled": return "中止・延期"
        default: return "状況未取得"
        }
    }

    static func date(_ value: String) -> String {
        value.isEmpty ? "日付未取得" : String(value.prefix(10)).replacingOccurrences(of: "-", with: "/")
    }

    static func score(_ score: Int?) -> String { score.map(String.init) ?? "—" }
}

private struct OfficialSourceLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }

    init?(_ raw: String) {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host == "rugby-japan.jp" || host.hasSuffix(".rugby-japan.jp") ||
              host == "league-one.jp" || host.hasSuffix(".league-one.jp") ||
              host == "top-league.jp" || host.hasSuffix(".top-league.jp") ||
              host == "svns.com" || host.hasSuffix(".svns.com") ||
              host == "world.rugby" || host.hasSuffix(".world.rugby") ||
              host == "rugbyworldcup.com" || host.hasSuffix(".rugbyworldcup.com") else { return nil }
        self.url = url
    }
}

#endif
