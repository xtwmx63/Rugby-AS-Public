import SwiftUI
import SwiftData
import UIKit

extension RecordingWidgetColor {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .cyan: return .cyan
        case .yellow: return .yellow
        }
    }
}

nonisolated struct RecordingSizeKey: LayoutValueKey { static let defaultValue = RecordingWidgetSize.small }

private struct RecordingGridLayout: Layout {
    var rowHeight: CGFloat = 96
    var spacing: CGFloat = 12
    var columns: Int = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cells = RecordingGridPacking.cells(sizes: subviews.map { $0[RecordingSizeKey.self] })
        let height = zip(cells, subviews.map { $0[RecordingSizeKey.self] }).map { cell, size in
            CGFloat(cell.row) * (rowHeight + spacing) + rowHeight * CGFloat(cell.height) + spacing * CGFloat(cell.height - 1)
        }.max() ?? 0
        return CGSize(width: proposal.width ?? 358, height: max(0, height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cells = RecordingGridPacking.cells(sizes: subviews.map { $0[RecordingSizeKey.self] })
        let unit = max(0, (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        for (index, cell) in cells.enumerated() {
                let size = CGSize(width: CGFloat(cell.width) * unit + CGFloat(cell.width - 1) * spacing,
                              height: CGFloat(cell.height) * rowHeight + CGFloat(cell.height - 1) * spacing)
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(cell.column) * (unit + spacing),
                                              y: bounds.minY + CGFloat(cell.row) * (rowHeight + spacing)),
                                  anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

struct RecordingWidgetGrid<Content: View>: View {
    let rowHeight: CGFloat
    let spacing: CGFloat
    let content: () -> Content

    init(rowHeight: CGFloat = 96, spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        AnyLayout(RecordingGridLayout(rowHeight: rowHeight, spacing: spacing)) {
            content()
        }
    }
}

struct RecordingStripeFill: View {
    var color: Color
    var fraction: Double = 1
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                color
                Canvas { context, size in
                    var lines = Path()
                    for x in stride(from: -size.height, through: size.width + size.height, by: 26) {
                        lines.move(to: CGPoint(x: x, y: size.height))
                        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                    }
                    context.stroke(lines, with: .color(.white.opacity(0.2)), lineWidth: 11)
                }
            }
            .frame(width: geometry.size.width * min(1, max(0, fraction)))
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


enum RecordingWidgetRoute: Identifiable {
    case scoring
    case editor
    case analysis
    case input(UUID, RecordingWidgetKind, UUID?, isNew: Bool = false)
    case review([UUID])
    var id: String {
        switch self {
        case .scoring: return "scoring"
        case .editor: return "editor"
        case .analysis: return "analysis"
        case .input(let id, let kind, _, _): return "input-" + id.uuidString + kind.rawValue
        case .review: return "review"
        }
    }
}

struct WidgetRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var store: RecordingWidgetStore
    @Query private var players: [Player]
    @Query private var teams: [Team]
    @Query private var lineups: [MatchLineup]
    @State private var route: RecordingWidgetRoute?
    @State private var showTimeline = false
    @State private var confirmFinish = false
    @State private var confirmHalf = false
    @AppStorage("recording.comfortableBoard") private var comfortableBoard = false
    let onClose: (Int, Int, Bool) -> Void

    init(match: Match, context: ModelContext, initialSeconds: Int, initialHalf: Int,
         onClose: @escaping (Int, Int, Bool) -> Void) {
        _store = StateObject(wrappedValue: RecordingWidgetStore(match: match, context: context,
                                                               initialSeconds: initialSeconds, initialHalf: initialHalf))
        self.onClose = onClose
        let home = match.homeTeamID, away = match.awayTeamID, id = match.id
        _players = Query(filter: #Predicate<Player> { $0.teamID == home || $0.teamID == away })
        _lineups = Query(filter: #Predicate<MatchLineup> { $0.matchID == id })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height * 1.5
                if landscape && (showsHeader || !boardHasClock) {
                    HStack(spacing: 10) {
                        VStack(spacing: 8) {
                            if showsHeader { landscapeHeader }
                            if !boardHasClock { clock(compact: true) }
                            Spacer(minLength: 0)
                            footer
                            Button("閉じる") { close(finished: false) }.frame(minHeight: 44)
                        }.frame(width: 190)
                        board
                    }
                } else {
                    VStack(spacing: 8) {
                        if showsHeader { header }
                        if !boardHasClock { clock() }
                        board
                        HStack(spacing: 6) {
                            footer
                            if landscape {
                                Button { close(finished: false) } label: {
                                    Image(systemName: "xmark").frame(width: 44, height: 44)
                                }.accessibilityLabel("記録画面を閉じる")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(red: 0.025, green: 0.055, blue: 0.095).ignoresSafeArea())
            .navigationTitle("試合記録").navigationBarTitleDisplayMode(.inline)
            .toolbar(verticalSizeClass == .compact ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close(finished: false) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("記録画面を閉じる")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { openEditor() } label: { Image(systemName: "square.grid.3x3.square").frame(width: 44, height: 44) }
                        .accessibilityLabel("ボードをカスタマイズ")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("画面を編集", systemImage: "square.grid.2x2") { if store.pause() { route = .editor } }
                        Button("映像タイムラインを開く", systemImage: "film.stack") { if store.pause() { showTimeline = true } }
                        Button("試合終了", systemImage: "stop.circle", role: .destructive) { confirmFinish = true }
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .accessibilityLabel("編集と試合終了")
                }
            }
            .sheet(item: $route, onDismiss: { store.refresh() }) { item in
                switch item {
                case .scoring:
                    RecordingScoringSheet(store: store, players: players, teams: teams, lineups: lineups)
                        .presentationDetents([.height(440), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .height(440)))
                        .presentationDragIndicator(.visible)
                case .editor:
                    RecordingLayoutEditor(store: store)
                case .analysis:
                    RecordingBoardAnalysis(store: store, players: players, lineups: lineups)
                case .input(let id, let kind, let widgetID, let isNew):
                    if let event = store.events.first(where: { $0.id == id }) {
                        RecordingEventEditor(store: store, event: event, kind: kind,
                            widget: store.layout.widgets.first(where: { $0.id == widgetID }), players: players, lineups: lineups,
                            isNewEvent: isNew)
                    }
                case .review(let ids):
                    NavigationStack {
                        RecordingEventList(store: store, players: players, lineups: lineups, eventIDs: ids)
                            .navigationTitle("プレーを確認").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { route = nil } } }
                    }
                }
            }
            // タイムライン側で記録を足したり消したりできるので、
            // 閉じたらこちらの控えを取り直す。
            .fullScreenCover(isPresented: $showTimeline, onDismiss: { store.refresh() }) {
                TimelineEditorView(match: store.match)
            }
            .alert("確認してください", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("閉じる", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
            .confirmationDialog("この試合を終了しますか？", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("終了する", role: .destructive) { if store.finish() { close(finished: true) } }
            }
            .confirmationDialog("前半の計測を閉じ、後半を0秒から始めますか？", isPresented: $confirmHalf, titleVisibility: .visible) {
                Button("後半に切り替える") { store.nextHalf() }
            }
            .task(id: store.nextIntervalExpiration) {
                guard let deadline = store.nextIntervalExpiration else { return }
                do {
                    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    store.reconcile()
                } catch { /* A changed deadline or a closed board cancels the previous wait. */ }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { store.refresh() } }
            .onAppear { store.reconcile(); UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    // 同じものが2つ出ないように、ボードに置いたぶんだけ上の固定表示を消す。
    // 置いていなければ今までどおりの見た目のまま。
    private var boardHasClock: Bool { store.layout.widgets.contains { $0.kind == .matchClock } }
    private var boardHasScore: Bool { store.layout.widgets.contains { $0.kind == .scoreboard } }
    // チームの切り替えは、HOMEとAWAYの両方をボードに置いてはじめて上のボタンを外す
    // (片方だけだと、もう一方のチームに切り替えられなくなるため)。
    private var boardHasTeamSwitch: Bool {
        let scopes = Set(store.layout.widgets.filter { $0.kind == .teamBadge }.map(\.scope))
        return scopes.contains(.home) && scopes.contains(.away)
    }
    private var showsHeader: Bool { !boardHasScore || !boardHasTeamSwitch }

    private var board: some View {
        VStack(spacing: 5) {
            if let flow = store.session.scoringFlow, !flow.isComplete {
                HStack {
                    Button { route = .scoring } label: {
                        Label(flow.tryID == nil ? "トライの入力を再開" : "コンバージョンを入力", systemImage: "rugbyball.fill")
                            .font(.caption.bold()).frame(minHeight: 36)
                    }
                    Spacer(minLength: 0)
                    if flow.tryID != nil {
                        Button(flow.kickSeconds == nil ? "キック時刻を記録" : "キック時刻を更新") { store.recordConversionTime(flowID: flow.id) }
                            .font(.caption.bold()).frame(minHeight: 36)
                    }
                }.padding(.horizontal, 10)
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(RecordingScoringStyle.selection, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(RecordingScoringStyle.blue.opacity(0.5), lineWidth: 1))
            }
            HStack {
                Text(store.layout.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { comfortableBoard.toggle() } label: {
                    Text(comfortableBoard ? "1画面" : "大きく").font(.caption.weight(.semibold))
                }.accessibilityLabel(comfortableBoard ? "全項目を1画面に収める" : "項目を大きく表示する")
                Button { openEditor() } label: {
                    Label("配置・見た目", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold))
                }.buttonStyle(.plain).frame(minHeight: 28)
            }
            if store.layout.widgets.isEmpty {
                Button { openEditor() } label: {
                    ContentUnavailableView("自分の記録ボードをつくる", systemImage: "square.grid.3x3.square",
                        description: Text("必要な指標を選び、好きな場所に配置できます。"))
                }.buttonStyle(.plain)
            } else {
                RecordingBoardSurface(layout: store.layout, comfortable: comfortableBoard) { widget in
                    widgetCard(widget)
                }
            }
        }
    }

    private func openEditor() { if store.pause() { route = .editor } }

    private var footer: some View {
        HStack(spacing: 6) {
            Button { store.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
            }.disabled(!store.canUndo).accessibilityLabel("ひとつ戻す")
            if let latest = store.latestEvent {
                Button { route = .input(latest.id, .note, nil) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("直前の記録").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(latest.recordingTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
            } else {
                Text("記録をタップして開始").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            Button { route = .review(store.events.filter { $0.category != "match_state" }.map(\.id)) } label: {
                Image(systemName: "list.bullet.rectangle").frame(width: 40, height: 44)
            }.accessibilityLabel("記録一覧")
            Button { route = .analysis } label: {
                Image(systemName: "chart.bar.xaxis").frame(width: 40, height: 44)
            }.accessibilityLabel("指標の集計")
        }
        .font(.system(size: 19, weight: .semibold))
        .padding(.horizontal, 6)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !boardHasTeamSwitch { teamButton(store.match.homeTeamID, label: "HOME", color: .blue) }
            if !boardHasScore { headerScore }
            if !boardHasTeamSwitch { teamButton(store.match.awayTeamID, label: "AWAY", color: .red) }
        }
    }
    private var landscapeHeader: some View {
        VStack(spacing: 6) {
            if !boardHasScore { headerScore }
            if !boardHasTeamSwitch {
                HStack(spacing: 6) {
                    teamButton(store.match.homeTeamID, label: "HOME", color: .blue)
                    teamButton(store.match.awayTeamID, label: "AWAY", color: .red)
                }
            }
        }
    }
    private var headerScore: some View {
        Text("\(store.score(teamID: store.match.homeTeamID)) – \(store.score(teamID: store.match.awayTeamID))")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).layoutPriority(1)
    }
    private func teamButton(_ id: UUID, label: String, color: Color) -> some View {
        Button { store.selectTeam(id) } label: {
            VStack(spacing: 2) {
                Text(label).font(.system(size: 11, weight: .heavy)).foregroundStyle(color).lineLimit(1)
                Text(teams.first { $0.id == id }?.name ?? "未設定")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 46)
            .background(color.opacity(store.selectedTeamID == id ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.selectedTeamID == id ? color : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityAddTraits(store.selectedTeamID == id ? .isSelected : [])
    }
    private func clock(compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button(store.session.clock.half == 0 ? "前半" : "後半") { confirmHalf = true }
                .font(.subheadline.weight(.bold)).frame(minWidth: 42, minHeight: 44).disabled(store.session.clock.half == 1)
            TimelineView(.animation(minimumInterval: 1, paused: store.session.clock.startedAt == nil)) { timeline in
                Text(RecordingFormatting.time(store.session.clock.elapsed(at: timeline.date)))
                    .font(.system(size: 25, weight: .bold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
            }
            Button { store.toggleClock() } label: {
                Group {
                    if compact {
                        Image(systemName: store.session.clock.startedAt == nil ? "play.fill" : "pause.fill")
                    } else {
                        Label(store.session.clock.startedAt == nil ? "開始" : "停止",
                              systemImage: store.session.clock.startedAt == nil ? "play.fill" : "pause.fill")
                    }
                }.font(.subheadline.bold()).frame(minHeight: 36)
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel(store.session.clock.startedAt == nil ? "開始" : "停止")
        }
        .padding(.horizontal, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func widgetCard(_ widget: RecordingWidgetDefinition) -> some View {
        RecordingLiveWidget(widget: widget, store: store, players: players, teams: teams, lineups: lineups) { selected in
            route = selected
        } openVideo: {
            if store.pause() { showTimeline = true }
        } changeHalf: {
            confirmHalf = true
        }
    }

    private func playerName(_ player: Player) -> String {
        let number = MatchNumbering.number(for: player, matchID: store.match.id, lineups: lineups).map { "\($0) " } ?? ""
        return number + (player.name?.isEmpty == false ? player.name! : "名前未設定")
    }
    private func close(finished: Bool) {
        guard store.pause() else { return }
        MatchNumbering.freezeNumbers(forMatch: store.match.id, context: store.context)
        onClose(Int(store.session.clock.elapsed(at: .now)), store.session.clock.half, finished)
        dismiss()
    }
}

/// チームのロゴ。未登録のときは盾のマークを出す(試合一覧や従来の記録画面と同じ扱い)。
struct RecordingTeamLogo: View {
    var team: Team?
    var body: some View {
        StoredImageView(name: team?.logoPath, maxDimension: 160) { image in
            image.resizable().scaledToFit().padding(2).background(Color.white)
        } placeholder: {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "shield.fill").resizable().scaledToFit().padding(7).foregroundStyle(.white.opacity(0.55))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

struct RecordingPlayerPhoto: View {
    var player: Player?
    var body: some View {
        StoredImageView(name: player?.imagePath) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack { Color.white.opacity(0.08); Image(systemName: "person.fill").resizable().scaledToFit().padding(18).foregroundStyle(.secondary) }
        }.clipped().accessibilityHidden(true)
    }
}

private extension View {
    func recordingWidgetCardBackground() -> some View {
        self
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.13, blue: 0.24),
                        Color(red: 0.03, green: 0.07, blue: 0.14)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}
