import SwiftUI

enum RecordingScoringStyle {
    static let background = Color(red: 0.045, green: 0.075, blue: 0.125)
    static let surface = Color(red: 0.085, green: 0.125, blue: 0.19)
    static let blue = Color(red: 0.145, green: 0.365, blue: 0.88)
    static let selection = Color(red: 0.075, green: 0.17, blue: 0.34)
    static let green = Color(red: 0.075, green: 0.48, blue: 0.29)
    static let red = Color(red: 0.73, green: 0.18, blue: 0.24)
}

/// The short detent leaves the board interactive; dismissal folds, rather than discards, input.
struct RecordingScoringSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: RecordingWidgetStore
    let players: [Player]
    let teams: [Team]
    let lineups: [MatchLineup]
    @State private var confirmCancel = false
    @State private var confirmDecline = false
    @State private var confirmPenaltyTry = false
    @State private var correctKickTime = false
    @State private var kickTimeText = ""
    @State private var playerRoster = RecordingPlayerRoster()
    @State private var showOtherPlayers = false

    var body: some View {
        Group {
            if let flow = store.session.scoringFlow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(flow)
                        if flow.isComplete { completion(flow) }
                        else {
                            playerPicker(flow)
                            if flow.tryID == nil { tryControls(flow) }
                            else { conversionControls(flow) }
                        }
                    }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 16)
                }
            } else {
                ContentUnavailableView("入力を終了しました", systemImage: "checkmark.circle")
            }
        }
        .background(RecordingScoringStyle.background)
        .tint(RecordingScoringStyle.blue)
        .preferredColorScheme(.dark)
        .onAppear { preparePlayerRoster() }
        .onChange(of: store.session.scoringFlow?.teamID) { _, _ in preparePlayerRoster() }
        .onChange(of: store.session.scoringFlow?.tryID) { _, _ in showOtherPlayers = false }
        .confirmationDialog("トライ入力を取り消す", isPresented: $confirmCancel, titleVisibility: .visible) {
            if let flow = store.session.scoringFlow {
                Button("誤操作による取消（元の計測に戻す）", role: .destructive) {
                    if store.cancelTry(flowID: flow.id, accidental: true) { dismiss() }
                }
                Button("判定による取消（現在の計測を維持）", role: .destructive) {
                    if store.cancelTry(flowID: flow.id, accidental: false) { dismiss() }
                }
            }
        }
        .confirmationDialog("コンバージョンを辞退しますか？", isPresented: $confirmDecline, titleVisibility: .visible) {
            if let flow = store.session.scoringFlow {
                Button("辞退を確定", role: .destructive) { _ = store.declineConversion(flowID: flow.id) }
            }
        } message: { Text("トライの5点を残し、キックの記録は作成しません。") }
        .confirmationDialog(store.session.scoringFlow?.tryID == nil ? "認定トライとして記録" : "認定トライへ変更",
                            isPresented: $confirmPenaltyTry, titleVisibility: .visible) {
            if let flow = store.session.scoringFlow {
                Button(flow.tryID == nil ? "認定トライを記録" : "認定トライに変更", role: .destructive) { _ = store.recordPenaltyTry(flowID: flow.id) }
                Button("戻る", role: .cancel) { }
            }
        } message: {
            if let flow = store.session.scoringFlow { Text(penaltyTryMessage(flow)) }
        }
        .alert("キック時刻を修正", isPresented: $correctKickTime) {
            TextField("分:秒", text: $kickTimeText).keyboardType(.numbersAndPunctuation)
            Button("修正を保存") {
                if let flow = store.session.scoringFlow {
                    store.correctConversionTime(flowID: flow.id, clockText: kickTimeText)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: { Text("キックした時点の試合時計を「07:38」の形式で入力してください。") }
        .alert("確認してください", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("閉じる", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    private func heading(_ flow: RecordingScoringFlow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label(flow.penaltyTryID != nil ? "認定トライ" : flow.tryID == nil ? "トライ" : "コンバージョン",
                      systemImage: flow.penaltyTryID != nil ? "checkmark.seal.fill" : flow.tryID == nil ? "rugbyball.fill" : "scope")
                    .font(.title2.bold())
                Text((teams.first { $0.id == flow.teamID }?.name ?? "未設定") + " · " + time(flow.half, flow.seconds))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { dismiss() } label: {
                Label(flow.isComplete ? "閉じる" : "折りたたむ", systemImage: "chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).frame(minHeight: 44)
                    .background(RecordingScoringStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
        }
    }

    private func playerPicker(_ flow: RecordingScoringFlow) -> some View {
        let selection = flow.tryID == nil ? flow.scorerID : flow.kickerID
        let eligible = playerRoster.visiblePlayers(includeOthers: showOtherPlayers, selectedPlayerID: selection)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(flow.tryID == nil ? "得点者を選択" : "キッカーを選択").font(.subheadline.bold())
                Spacer(minLength: 4)
                if !playerRoster.others.isEmpty {
                    Button { showOtherPlayers.toggle() } label: {
                        Text(showOtherPlayers ? "番号ありのみ" : "その他（\(playerRoster.others.count)）")
                            .font(.caption.weight(.semibold)).frame(minHeight: 36)
                    }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                        .accessibilityLabel(showOtherPlayers ? "背番号ありの選手のみ表示" : "その他の選手を表示、\(playerRoster.others.count)人")
                }
                Button { store.setScoringPlayer(nil, flowID: flow.id) } label: {
                    HStack(spacing: 4) {
                        if selection == nil { Image(systemName: "checkmark").fontWeight(.bold) }
                        Text("選手未指定")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(selection == nil ? 1 : 0.65))
                        .padding(.horizontal, 8).frame(minHeight: 36)
                        .background(selection == nil ? RecordingScoringStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == nil ? RecordingScoringStyle.blue : .clear, lineWidth: 1))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == nil ? .isSelected : [])
            }
            if eligible.isEmpty {
                Text(playerRoster.others.isEmpty ? "選手未指定で記録し、試合後に設定できます。" : "背番号が登録された選手がいません。「その他」から選択できます。")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 64)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(eligible) { player in
                            let selected = selection == player.id
                            Button { store.setScoringPlayer(player.id, flowID: flow.id) } label: {
                                VStack(spacing: 4) {
                                    RecordingPlayerPhoto(player: player).frame(width: 58, height: 58).clipShape(Circle())
                                        .overlay(Circle().stroke(selected ? RecordingScoringStyle.blue : Color.white.opacity(0.12), lineWidth: selected ? 3 : 1))
                                        .overlay(alignment: .topTrailing) {
                                            if selected {
                                                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                                                    .foregroundStyle(.white).frame(width: 20, height: 20)
                                                    .background(RecordingScoringStyle.blue, in: Circle())
                                                    .overlay(Circle().stroke(RecordingScoringStyle.background, lineWidth: 2))
                                                    .offset(x: 3, y: -2)
                                            }
                                        }
                                    Text(playerRoster.number(for: player).map { "#\($0)" } ?? "—")
                                        .font(.caption.bold()).foregroundStyle(.white)
                                    Text(player.name?.isEmpty == false ? player.name! : "名前未設定")
                                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                                        .lineLimit(2).multilineTextAlignment(.center).frame(height: 28, alignment: .top)
                                }.frame(width: 72).padding(.horizontal, 4).padding(.vertical, 7)
                                    .background(selected ? RecordingScoringStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? RecordingScoringStyle.blue : .clear, lineWidth: 2))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }.padding(2)
                }
            }
        }
    }

    private func preparePlayerRoster() {
        guard let flow = store.session.scoringFlow else { return }
        playerRoster = RecordingPlayerRoster(players: players, teamID: flow.teamID, matchID: store.match.id, lineups: lineups)
        showOtherPlayers = false
    }

    private func tryControls(_ flow: RecordingScoringFlow) -> some View {
        VStack(spacing: 8) {
            HStack {
                Label("起点：" + (PlayOrigin.displayName(for: flow.origin) ?? "未指定"), systemImage: "flag")
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("その他") {
                    Button("認定トライとして記録") { confirmPenaltyTry = true }
                }.foregroundStyle(.white.opacity(0.8))
                Button("取消", role: .destructive) { confirmCancel = true }
            }.font(.subheadline).frame(minHeight: 36)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { originButtons(flow) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    originButtons(flow)
                }
            }
            Button { store.confirmTry(flowID: flow.id) } label: {
                VStack(spacing: 3) {
                    Text("確定してコンバージョンへ").font(.headline)
                    Text("トライを記録（+5点）").font(.caption).foregroundStyle(.white.opacity(0.85))
                }.frame(maxWidth: .infinity, minHeight: 60)
                    .background(RecordingScoringStyle.green, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white)
        }
    }

    private func originButtons(_ flow: RecordingScoringFlow) -> some View {
        ForEach(PlayOrigin.allCases) { origin in
            let selected = flow.origin == origin.rawValue
            Button {
                store.setTryOrigin(selected ? nil : origin.rawValue, flowID: flow.id)
            } label: {
                Text(origin.shortName)
                    .font(.system(size: 13, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                    .background(selected ? RecordingScoringStyle.blue : RecordingScoringStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.white.opacity(0.35) : Color.white.opacity(0.10), lineWidth: 1))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityLabel(origin.displayName)
                .accessibilityHint(selected ? "再度タップすると選択を解除します" : "トライの起点に設定します")
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func conversionControls(_ flow: RecordingScoringFlow) -> some View {
        VStack(spacing: 10) {
            Button { store.recordConversionTime(flowID: flow.id) } label: {
                HStack {
                    Label(flow.kickSeconds == nil ? "キック時刻を記録" : "キック時刻を更新", systemImage: "stopwatch")
                    Spacer(minLength: 4)
                    if let seconds = flow.kickSeconds { Text(time(flow.kickHalf ?? flow.half, seconds)).monospacedDigit() }
                }.font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(minHeight: 52)
                    .background(RecordingScoringStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(RecordingScoringStyle.blue.opacity(0.8), lineWidth: 1))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                resultButton("成功（+2点）", color: RecordingScoringStyle.green, success: true, flow: flow)
                resultButton("失敗（0点）", color: RecordingScoringStyle.red, success: false, flow: flow)
            }.disabled(flow.kickSeconds == nil)
            HStack {
                Text(flow.kickSeconds == nil ? "キック時刻の記録後、結果を選択して確定" : "時刻は再タップで更新・結果を選択して確定")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu("その他") {
                    if let seconds = flow.kickSeconds {
                        Button("キック時刻を修正") {
                            kickTimeText = RecordingFormatting.time(Double(seconds)); correctKickTime = true
                        }
                    }
                    Button("トライの訂正：認定トライへ変更") { confirmPenaltyTry = true }
                    Button("コンバージョンを辞退", role: .destructive) { confirmDecline = true }
                }
                    .font(.caption).foregroundStyle(.white.opacity(0.8)).frame(minHeight: 32)
            }
        }
    }

    private func resultButton(_ title: String, color: Color, success: Bool, flow: RecordingScoringFlow) -> some View {
        Button { store.completeConversion(flowID: flow.id, success: success) } label: {
            Text(title).font(.headline).foregroundStyle(.white.opacity(flow.kickSeconds == nil ? 0.4 : 1)).frame(maxWidth: .infinity, minHeight: 52)
                .background(flow.kickSeconds == nil ? RecordingScoringStyle.surface : color, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
            .foregroundStyle(.white).buttonStyle(.plain)
    }

    private func completion(_ flow: RecordingScoringFlow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(flow.penaltyTryID != nil ? "認定トライを記録しました（+7点）"
                        : flow.conversionDeclined ? "コンバージョン辞退を記録しました" : "コンバージョンを記録しました",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Spacer(minLength: 4)
                if flow.penaltyTryID == nil {
                    Menu("その他") {
                        Button("トライの訂正：認定トライへ変更") { confirmPenaltyTry = true }
                    }.font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            if flow.penaltyTryID != nil {
                Text("認定トライは選手の得点になりません。コンバージョンは行いません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let id = flow.conversionID, let event = store.events.first(where: { $0.id == id }) {
                Text((event.outcome == "success" ? "成功（+2点）" : "失敗（0点）") + " · " + time(event.half, event.seconds))
                    .font(.subheadline.monospacedDigit())
                playerPicker(flow)
                Text("キッカーはここで設定できます。試合後は記録一覧から修正できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { dismiss() } label: {
                Text("記録画面に戻る").font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(RecordingScoringStyle.blue, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    /// 変更で何が起きるかを先に見せる(記録が消えることを確定前に分かるようにする)
    private func penaltyTryMessage(_ flow: RecordingScoringFlow) -> String {
        let team = teams.first { $0.id == flow.teamID }?.name ?? "未設定"
        var lines = [team + "・" + time(flow.half, flow.seconds)]
        guard flow.tryID != nil else {
            lines.append("認定トライ（+7点）として記録します。")
            lines.append("得点者とコンバージョンは記録しません。")
            return lines.joined(separator: "\n")
        }
        let conversion = flow.conversionID.flatMap { id in store.events.first { $0.id == id } }
        if conversion?.outcome == "success" {
            lines.append("通常トライ5点＋キック2点 → 認定トライ7点")
            lines.append("トライとキックの記録を取り消します。チーム合計は変わりません。")
        } else {
            lines.append("通常トライ5点 → 認定トライ7点")
            lines.append(conversion == nil ? "トライの記録を取り消し、コンバージョン待ちを終了します。"
                         : "トライとキック（失敗）の記録を取り消します。")
        }
        return lines.joined(separator: "\n")
    }

    private func time(_ half: Int, _ seconds: Int) -> String {
        (half == 0 ? "前半 " : "後半 ") + RecordingFormatting.time(Double(seconds))
    }
}
