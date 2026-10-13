//
//  BackupProgressView.swift
//  Rugby AS
//
//  バックアップの読み込み・書き出しのあいだ全画面に出す「進み具合」の画面。
//  大きなファイルは時間がかかるので、止まっている(フリーズした)のではなく
//  動いていることが分かるように、段階の一覧・進み具合のバー・経過時間を出す。
//  (Mobbin で見た LINE のバックアップ画面の「見出し+バー+%」、Brink の取り込み画面の
//   「いまの件数」、Glow の「段階の一覧」を組み合わせた)
//
//  段階の途中で重い処理が続くあいだは数字が止まることがあるが、今の段階の
//  くるくる(ProgressView)は描画側で回り続けるので、動いていることは伝わる。
//

import SwiftUI

/// いま進んでいる読み込み・書き出しの状態
struct BackupActivity: Equatable {
    enum Kind: Equatable { case restore, export }
    enum Phase: Equatable {
        case running
        case finished(String)
        case failed(String)
    }

    struct Step: Equatable {
        var title: String
        var detail: String?
    }

    var kind: Kind
    var steps: [Step]
    var current = 0
    /// 今の段階で反映し終えた件数と全件数(件数が分かる段階だけ)
    var currentDone: Int?
    var currentTotal: Int?
    var phase = Phase.running
    var startedAt = Date()

    static func restore() -> BackupActivity {
        BackupActivity(kind: .restore, steps: [
            Step(title: "ファイルを開く"),
            Step(title: "中身を確かめる"),
            Step(title: "写真・ロゴを準備する"),
            Step(title: "チーム・選手を反映する"),
            Step(title: "大会・試合を反映する"),
            Step(title: "記録・メンバー表を反映する"),
            Step(title: "保存する"),
        ])
    }

    static func export() -> BackupActivity {
        BackupActivity(kind: .export, steps: [
            Step(title: "記録と写真を集める"),
            Step(title: "1つのファイルにまとめる"),
            Step(title: "ファイルを保存する"),
        ])
    }

    /// 読み込みの進み具合を、画面の段階と件数に置き換える
    mutating func apply(_ progress: BackupRestoreProgress) {
        let index: Int
        switch progress.stage {
        case .reading: index = 0
        case .checking: index = 1
        case .images: index = 2
        case .teamsAndPlayers: index = 3
        case .tournamentsAndMatches: index = 4
        case .records: index = 5
        case .saving: index = 6
        }
        current = index
        currentDone = progress.done
        currentTotal = progress.total
        if let bytes = progress.fileBytes { steps[1].detail = Self.size(bytes) }
        if let counts = progress.counts {
            steps[2].detail = counts.images > 0 ? "写真・ロゴ \(Self.number(counts.images))枚" : "なし"
            steps[3].detail = Self.joined([("チーム", counts.teams, ""), ("選手", counts.players, "人")])
            steps[4].detail = Self.joined([("大会", counts.tournaments, ""), ("試合", counts.matches, "")])
            steps[5].detail = Self.joined([("記録", counts.records, "件"), ("メンバー表・交代", counts.lineups, "件")])
        }
    }

    /// 書き出しの進み具合を、画面の段階と件数に置き換える
    mutating func apply(_ progress: BackupExportProgress) {
        currentDone = nil
        currentTotal = nil
        switch progress.stage {
        case .collecting: current = 0
        case .encoding: current = 1
        case .writing: current = 2
        }
        if let counts = progress.counts {
            steps[0].detail = Self.joined([("選手", counts.players, "人"), ("試合", counts.matches, ""),
                                           ("写真・ロゴ", counts.images, "枚")])
        }
        if let bytes = progress.fileBytes { steps[1].detail = Self.size(bytes) }
    }

    /// バーの長さ(終わった段階の割合に、今の段階の進み具合を足す)
    var fraction: Double {
        switch phase {
        case .running, .failed:
            var within = 0.0
            if let done = currentDone, let total = currentTotal, total > 0 {
                within = min(1, Double(done) / Double(total))
            }
            return (Double(current) + within) / Double(max(1, steps.count))
        case .finished: return 1
        }
    }

    /// 今の段階の件数(例: 120,000 / 241,366件)。多いときだけ出す
    var currentCountText: String? {
        guard let done = currentDone, let total = currentTotal, total >= 1_000 else { return nil }
        return "\(Self.number(done)) / \(Self.number(total))件"
    }

    private static func number(_ value: Int) -> String { value.formatted(.number) }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func joined(_ parts: [(String, Int, String)]) -> String {
        let shown = parts.filter { $0.1 > 0 }.map { "\($0.0) \(number($0.1))\($0.2)" }
        return shown.isEmpty ? "なし" : shown.joined(separator: "・")
    }
}

struct BackupProgressView: View {
    let activity: BackupActivity
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            header
                .padding(.bottom, 28)
            stepList
                .rugbyCard()
            Spacer(minLength: 24)
            footer
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RugbyTheme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    // MARK: - 見出し

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 84, height: 84)
                Image(systemName: iconName)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(iconForeground)
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .multilineTextAlignment(.center)

            if case .running = activity.phase {
                progressBar
            } else {
                Text(resultMessage)
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 8) {
            ProgressView(value: activity.fraction)
                .tint(RugbyTheme.accent)
                .animation(.easeInOut(duration: 0.35), value: activity.fraction)
            HStack(alignment: .firstTextBaseline) {
                Text(activity.steps[activity.current].title + "…")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count = activity.currentCountText {
                    Text(count)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text("\(Int((activity.fraction * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(RugbyTheme.textSecondary)
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 段階の一覧

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(activity.steps.enumerated()), id: \.offset) { index, step in
                stepRow(index: index, step: step)
                if index < activity.steps.count - 1 {
                    Rectangle().fill(RugbyTheme.border).frame(height: 1).padding(.leading, 36)
                }
            }
        }
    }

    private func stepRow(index: Int, step: BackupActivity.Step) -> some View {
        let state = stepState(index)
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(RugbyTheme.accent)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                        .tint(RugbyTheme.accent)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(RugbyTheme.fixedRed)
                case .waiting:
                    Circle()
                        .stroke(RugbyTheme.textSecondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(state == .active ? .bold : .semibold))
                    .foregroundStyle(state == .waiting ? RugbyTheme.textSecondary : RugbyTheme.textPrimary)
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.accessibilityText)
    }

    private enum StepState {
        case done, active, waiting, failed

        var accessibilityText: String {
            switch self {
            case .done: "完了"
            case .active: "処理中"
            case .waiting: "待機中"
            case .failed: "失敗"
            }
        }
    }

    private func stepState(_ index: Int) -> StepState {
        switch activity.phase {
        case .finished: return .done
        case .failed: return index < activity.current ? .done : (index == activity.current ? .failed : .waiting)
        case .running: return index < activity.current ? .done : (index == activity.current ? .active : .waiting)
        }
    }

    // MARK: - 下の案内とボタン

    @ViewBuilder
    private var footer: some View {
        switch activity.phase {
        case .running:
            VStack(spacing: 8) {
                // 1秒ごとに経過時間を進める。止まっていないことの目印になる
                TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                    Label("経過 " + elapsed(until: context.date), systemImage: "clock")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
                Text("完了するまでアプリを閉じないでください。大きなファイルは数分かかることがあります。処理中は画面が自動で暗くなりません。")
                    .font(.footnote)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .finished, .failed:
            Button(action: onClose) {
                Text("OK")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(RugbyTheme.onAccent)
                    .background(RugbyTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func elapsed(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(activity.startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 状態ごとの見た目

    private var title: String {
        switch (activity.kind, activity.phase) {
        case (.restore, .running): "バックアップを読み込んでいます"
        case (.restore, .finished): "読み込みが完了しました"
        case (.restore, .failed): "読み込めませんでした"
        case (.export, .running): "バックアップを書き出しています"
        case (.export, .finished): "書き出しが完了しました"
        case (.export, .failed): "書き出せませんでした"
        }
    }

    private var resultMessage: String {
        switch activity.phase {
        case .running: ""
        case .finished(let message), .failed(let message): message
        }
    }

    private var iconName: String {
        switch activity.phase {
        case .running: activity.kind == .restore ? "square.and.arrow.down" : "square.and.arrow.up"
        case .finished: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var iconBackground: Color {
        if case .failed = activity.phase { return RugbyTheme.fixedRed.opacity(0.12) }
        return RugbyTheme.accentSoft
    }

    private var iconForeground: Color {
        if case .failed = activity.phase { return RugbyTheme.fixedRed }
        return RugbyTheme.accent
    }
}

#Preview("読み込み中") {
    var activity = BackupActivity.restore()
    activity.current = 3
    activity.steps[1].detail = "34.1 MB"
    activity.steps[2].detail = "写真・ロゴ 245枚"
    activity.steps[3].detail = "選手 250人"
    return BackupProgressView(activity: activity) {}
}

#Preview("完了") {
    var activity = BackupActivity.restore()
    activity.phase = .finished("チーム0件・選手250件・大会0件・試合0件・記録0件を読み込みました。")
    return BackupProgressView(activity: activity) {}
}
