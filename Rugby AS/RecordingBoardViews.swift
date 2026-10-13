import SwiftUI
import SwiftData
import UIKit

extension RecordingWidgetDefinition {
    var tintColor: Color {
        guard let hex = effectiveAppearance.normalizedCustomColorHex,
              let rgb = UInt32(hex.dropFirst(), radix: 16) else { return color.color }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var inkColor: Color {
        guard effectiveAppearance.style == .filled else { return .white }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(tintColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        return r * 0.2126 + g * 0.7152 + b * 0.0722 > 0.64 ? Color(white: 0.08) : .white
    }
}

private struct RecordingCardHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 96 }
extension EnvironmentValues {
    var recordingCardHeight: CGFloat {
        get { self[RecordingCardHeightKey.self] }
        set { self[RecordingCardHeightKey.self] = newValue }
    }
}

struct RecordingBoardSurface<Content: View>: View {
    let layout: RecordingLayout
    var comfortable = false
    @ViewBuilder let content: (RecordingWidgetDefinition) -> Content
    var body: some View {
        GeometryReader { geometry in
            let cells = RecordingBoardPacking.cells(widgets: layout.widgets)
            let viewport = RecordingBoardViewport(cells: cells, size: geometry.size)
            let dense = viewport.frames.contains { $0.height < 76 || $0.width < 88 }
            if comfortable {
                let rows = cells.map { $0.row + $0.height }.max() ?? 1
                ScrollView {
                    cards(size: CGSize(width: geometry.size.width, height: max(geometry.size.height, CGFloat(rows) * 100)))
                }
            } else {
                VStack(spacing: 4) {
                    if dense {
                        Text("小さい項目があります。表示を「大きく」にするか配置を調整できます。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    GeometryReader { available in cards(size: available.size) }
                }
            }
        }
    }
    private func cards(size: CGSize) -> some View {
        let viewport = RecordingBoardViewport(cells: RecordingBoardPacking.cells(widgets: layout.widgets), size: size)
        return ZStack(alignment: .topLeading) {
                ForEach(Array(layout.widgets.enumerated()), id: \.element.id) { index, widget in
                    let frame = viewport.frames[index]
                    content(widget)
                        .environment(\.recordingCardHeight, frame.height)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct RecordingWidgetFace<Content: View>: View {
    let widget: RecordingWidgetDefinition
    var active = false
    var fraction: Double = 1
    @ViewBuilder let content: () -> Content
    init(widget: RecordingWidgetDefinition, active: Bool = false, fraction: Double = 1,
         @ViewBuilder content: @escaping () -> Content) {
        self.widget = widget; self.active = active; self.fraction = fraction; self.content = content
    }
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let compact = height < 76 || geometry.size.width < 130
            let radius = cornerRadius(height: height)
            ZStack {
                RoundedRectangle(cornerRadius: radius).fill(background)
                if active { RecordingStripeFill(color: widget.tintColor.opacity(0.55), fraction: fraction) }
                VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                    HStack(spacing: 4) {
                        if widget.effectiveAppearance.showIcon {
                            Image(systemName: widget.symbol).font(.system(size: compact ? 12 : 15, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        Text(widget.title).font(.system(size: compact ? 11 : 14, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if active { Circle().fill(.green).frame(width: 5, height: 5).accessibilityHidden(true) }
                    }
                    content()
                        .environment(\.recordingCardHeight, height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .padding(.horizontal, compact ? 8 : 11).padding(.vertical, compact ? 6 : 9)
            }
            .foregroundStyle(widget.inkColor)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: active ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: radius))
        }
    }
    private func cornerRadius(height: CGFloat) -> CGFloat {
        switch widget.effectiveAppearance.corner {
        case .square: return 3
        case .rounded: return 12
        case .pill: return min(32, height / 2)
        }
    }
    private var background: AnyShapeStyle {
        switch widget.effectiveAppearance.style {
        case .filled:
            return AnyShapeStyle(LinearGradient(colors: [widget.tintColor, widget.tintColor.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .outline: return AnyShapeStyle(Color(white: 0.055))
        case .soft: return AnyShapeStyle(widget.tintColor.opacity(0.17))
        }
    }
    private var border: Color {
        if active || widget.effectiveAppearance.style == .outline { return widget.tintColor }
        return widget.effectiveAppearance.style == .soft ? widget.tintColor.opacity(0.32) : .white.opacity(0.12)
    }
}

struct RecordingLiveWidget: View {
    let widget: RecordingWidgetDefinition
    @ObservedObject var store: RecordingWidgetStore
    let players: [Player]
    let teams: [Team]
    let lineups: [MatchLineup]
    let open: (RecordingWidgetRoute) -> Void
    let openVideo: () -> Void
    // 前半→後半の切り替えは確認してから行うので、確認画面を持つ親に任せる。
    let changeHalf: () -> Void
    @Environment(\.recordingCardHeight) private var height
    @State private var inputNumber = ""
    @State private var inputAttackUp = true
    @FocusState private var numberFocused: Bool
    private var valueFont: Font { .system(size: min(32, max(16, height * 0.29)), weight: .bold, design: .rounded) }
    private var matching: [StatEvent] { store.matchingEvents(widget) }

    var body: some View {
        Group {
            switch widget.kind {
            case .result: resultCard
            case .possession, .timed: timerCard
            case .successRate: rateCard
            case .leader: leaderCard
            case .teamBadge: teamCard
            case .matchClock: clockCard
            case .scoreboard: scoreCard
            default:
                if widget.inlineInput == true && [.number, .choice, .player, .zone].contains(widget.kind)
                    && (height >= (widget.kind == .number ? 100 : 76) || numberFocused) {
                    quickInputCard
                } else { inputCard }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var resultCard: some View {
        let summary = store.summary(widget)
        return RecordingWidgetFace(widget: widget) {
            HStack(spacing: 4) {
                Button { record(outcome: "success") } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
                        Text("\(summary.successes)").font(valueFont)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }.accessibilityLabel(widget.title + " 成功を記録")
                Rectangle().fill(widget.inkColor.opacity(0.22)).frame(width: 1)
                Button { record(outcome: "fail") } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .heavy))
                        Text("\(summary.attempts - summary.successes)").font(valueFont)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }.accessibilityLabel(widget.title + " 失敗を記録")
            }.buttonStyle(.plain)
        }
    }
    private var rateCard: some View {
        let summary = store.summary(widget)
        return Button { open(.review(matching.map(\.id))) } label: {
            RecordingWidgetFace(widget: widget) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(summary.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        .font(valueFont).monospacedDigit()
                    if height > 70 { Text("\(summary.successes)/\(summary.attempts)").font(.caption).opacity(0.75) }
                }
            }
        }.buttonStyle(.plain)
    }
    private var timerCard: some View {
        let active = store.activeInterval(widget)
        return TimelineView(.animation(minimumInterval: widget.kind == .timed ? 0.2 : 1, paused: active == nil)) { timeline in
            Button { store.activate(widget) } label: {
                RecordingWidgetFace(widget: widget, active: active != nil,
                    fraction: widget.kind == .timed ? active?.fraction(at: timeline.date) ?? 1 : 1) {
                    if widget.kind == .possession {
                        Text(RecordingFormatting.time(store.timerTotal(widget.timerTarget, at: timeline.date)))
                            .font(valueFont.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                    } else {
                        Text(active.map { String(format: "%.1f秒", $0.remaining(at: timeline.date)) } ?? "\(store.count(widget))")
                            .font(valueFont.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }.buttonStyle(.plain)
                .disabled(widget.kind == .possession && widget.timerTarget == .bip && store.session.clock.startedAt == nil)
                .accessibilityLabel(widget.title + (active == nil ? " 開始" : " 計測中、タップで停止"))
        }
    }
    private var quickInputCard: some View {
        RecordingWidgetFace(widget: widget) {
            if widget.kind == .number {
                HStack(spacing: 4) {
                    TextField(widget.unit, text: $inputNumber)
                        .keyboardType(widget.category == "carry_metres" ? .numbersAndPunctuation : .decimalPad)
                        .focused($numberFocused).textFieldStyle(.plain)
                        .accessibilityLabel(widget.title + " 数値")
                        .frame(minHeight: 44)
                    Button {
                        let normalized = inputNumber.replacingOccurrences(of: "−", with: "-")
                        if store.submitInput(widget, number: Double(normalized)) {
                            inputNumber = ""; numberFocused = false
                        }
                    } label: { Image(systemName: "checkmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(widget.title + " を記録")
                }
            } else {
                Menu {
                    if widget.kind == .choice {
                        if widget.category == "origin" {
                            ForEach(PlayOrigin.allCases, id: \.rawValue) { origin in
                                Button(origin.shortName) { store.submitInput(widget, choice: origin.rawValue) }
                            }
                        } else {
                            ForEach(widget.choices, id: \.self) { choice in
                                Button(choice) { store.submitInput(widget, choice: choice) }
                            }
                        }
                    } else if widget.kind == .player {
                        let eligible = players.filter { $0.teamID == store.teamID(for: widget) }
                        if eligible.isEmpty { Text("対象チームの選手を登録してください") }
                        ForEach(eligible) { player in
                            let number = MatchNumbering.number(for: player, matchID: store.match.id, lineups: lineups)
                            Button((number.map { "#\($0) " } ?? "") + (player.name ?? "名前未設定")) {
                                store.submitInput(widget, playerID: player.id)
                            }
                        }
                    } else {
                        Toggle("攻撃方向を上にする", isOn: $inputAttackUp)
                        ForEach(0..<9, id: \.self) { index in
                            Button(RecordingFormatting.zone(index, attackUp: inputAttackUp)) {
                                store.submitInput(widget, zone: index, attackUp: inputAttackUp)
                            }
                        }
                    }
                } label: {
                    Label(widget.attachesToLatest ? "追記する" : "選んで記録", systemImage: "chevron.down")
                        .font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityLabel(widget.title + " を選択")
            }
        }.buttonStyle(.plain)
    }

    private func record(outcome: String = "success") {
        if widget.category == "try" {
            if store.beginTry(widget) { open(.scoring) }
        } else if widget.category == "conversion", let flow = store.session.scoringFlow, !flow.isComplete {
            open(.scoring)
        } else { store.activate(widget, outcome: outcome) }
    }

    private var inputCard: some View {
        Button {
            if widget.category == "try" || widget.kind == .count { record() }
            else if widget.kind == .clip { openVideo() }
            else {
                let attaches = widget.attachesToLatest && store.latestEvent(for: widget) != nil
                if let event = store.eventForInput(widget) {
                    open(.input(event.id, widget.kind, widget.id, isNew: !attaches))
                }
            }
        } label: {
            RecordingWidgetFace(widget: widget) {
                if widget.kind == .count {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(store.count(widget))").font(valueFont).monospacedDigit()
                        Spacer(minLength: 0)
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).opacity(0.6)
                    }
                } else if widget.kind == .number {
                    let summary = store.summary(widget)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.average.map { String(format: "%g", $0) + " " + (summary.unit ?? widget.unit) } ?? "—")
                            .font(valueFont).lineLimit(1).minimumScaleFactor(0.6)
                        if height > 80 { Text(summary.hasMixedUnits ? "単位が混在" : "平均 · \(summary.numericCount)件").font(.caption2) }
                    }
                } else if widget.kind == .clip {
                    Label("再生", systemImage: "play.fill").font(.subheadline.bold())
                } else {
                    HStack {
                        Text(widget.attachesToLatest ? "追記" : "\(matching.count)件").font(valueFont)
                        Spacer(minLength: 0)
                        Image(systemName: widget.attachesToLatest ? "pencil" : "plus").font(.caption)
                    }
                }
            }
        }.buttonStyle(.plain)
    }
    // 試合時計。時間の側を押すと開始/停止、前半/後半の側を押すと後半へ切り替える。
    // 上部に固定されていたものと同じ働きを、好きな位置と大きさで置けるようにしたもの。
    private var clockCard: some View {
        TimelineView(.animation(minimumInterval: 1, paused: store.session.clock.startedAt == nil)) { timeline in
            let running = store.session.clock.startedAt != nil
            let isSecondHalf = store.session.clock.half == 1
            RecordingWidgetFace(widget: widget, active: running) {
                HStack(spacing: 6) {
                    Button { changeHalf() } label: {
                        Text(isSecondHalf ? "後半" : "前半")
                            .font(.system(size: min(16, max(11, height * 0.16)), weight: .bold))
                            .frame(minWidth: 40, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .disabled(isSecondHalf)
                    .accessibilityLabel(isSecondHalf ? "後半" : "前半、タップで後半に切り替え")
                    Button { store.toggleClock() } label: {
                        HStack(spacing: 5) {
                            Text(RecordingFormatting.time(store.session.clock.elapsed(at: timeline.date)))
                                .font(valueFont.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
                            Spacer(minLength: 0)
                            Image(systemName: running ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .heavy))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel(running ? "試合時計を止める" : "試合時計を進める")
                }.buttonStyle(.plain)
            }
        }
    }

    // 得点。合計はいつも記録から計算しているので、置き場所を変えても中身は同じ。
    private var scoreCard: some View {
        RecordingWidgetFace(widget: widget) {
            HStack(alignment: .center, spacing: 8) {
                scoreSide("HOME", value: store.score(teamID: store.match.homeTeamID), color: .blue)
                Text("–").font(valueFont).opacity(0.5)
                scoreSide("AWAY", value: store.score(teamID: store.match.awayTeamID), color: .red)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }

    private func scoreSide(_ label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 1) {
            if height > 56 {
                Text(label).font(.system(size: 10, weight: .heavy)).foregroundStyle(color).lineLimit(1)
            }
            Text("\(value)").font(valueFont.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity)
    }

    // チームのロゴと名前。押すと、そのチームが記録対象になる
    // (上のHOME/AWAYボタンと同じ働きを、好きな位置に置けるようにしたもの)。
    private var teamCard: some View {
        let id = store.teamID(for: widget)
        let team = teams.first { $0.id == id }
        let isSelected = store.selectedTeamID == id
        let logoSize = min(56, max(24, height * 0.52))
        return Button { store.selectTeam(id) } label: {
            RecordingWidgetFace(widget: widget, active: isSelected) {
                HStack(spacing: 7) {
                    RecordingTeamLogo(team: team).frame(width: logoSize, height: logoSize)
                    Text(team?.name ?? "チーム未設定")
                        .font(.system(size: min(17, max(11, height * 0.17)), weight: .bold))
                        .lineLimit(2).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.buttonStyle(.plain)
            .accessibilityLabel((team?.name ?? "チーム未設定") + (isSelected ? "、記録対象" : "、タップで記録対象にする"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var leaderCard: some View {
        let leader = store.scoringLeader(teamID: store.teamID(for: widget))
        let player = players.first { $0.id == leader?.playerID }
        return Button {
            let ids = leader?.eventIDs ?? store.events.filter {
                $0.teamID == store.teamID(for: widget) && $0.playerID == nil
                    && RecordingFormatting.score(category: $0.category, outcome: $0.outcome, widgetData: $0.widgetData) > 0
            }.map(\.id)
            open(.review(ids))
        } label: {
            RecordingWidgetFace(widget: widget) {
                HStack(spacing: 8) {
                    if height > 140 { RecordingPlayerPhoto(player: player).frame(width: 54, height: 64).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(leader.map { "\($0.points)点" } ?? "—").font(valueFont)
                        if height > 65 { Text(player?.name ?? "選手未設定").font(.caption).lineLimit(1) }
                    }
                }
            }
        }.buttonStyle(.plain)
    }
}
