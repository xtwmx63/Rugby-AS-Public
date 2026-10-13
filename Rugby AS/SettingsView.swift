//
//  SettingsView.swift
//  Rugby AS
//
//  設定画面。デフォルト自チーム名と、全記録のバックアップ(書き出し/読み込み)。
//  値は端末設定(UserDefaults)に保存し、試合をつくる画面が参照する。
//

import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("defaultTeamName") private var defaultTeamName = ""
    @State private var isRestoreImporterPresented = false
    @State private var backupShareItem: BackupShareItem?
    // 読み込み・書き出しの進み具合(nil のときは画面を出さない)
    @State private var backupActivity: BackupActivity?
    // 書き出し完了後、進み具合の画面を閉じてから共有シートに渡すファイル
    @State private var pendingShareURL: URL?
    @AppStorage("backup.lastFileCreatedAt") private var lastFileCreatedAt = 0.0
    @AppStorage(RugbyTheme.paletteKey) private var palette = RugbyPalette.navy.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RugbyScreenHeading(
                    eyebrow: "RUGBY AS",
                    title: "設定",
                    subtitle: "チームの初期設定・配色・バックアップ。"
                )

                VStack(alignment: .leading, spacing: 12) {
                    settingsSectionHeading("チームの初期設定", caption: "PREFERENCES")

                    VStack(alignment: .leading, spacing: 10) {
                        Label("デフォルト自チーム名", systemImage: "shield.lefthalf.filled")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RugbyTheme.textPrimary)

                        TextField("例: ○○大学", text: $defaultTeamName)
                            .font(.body)
                            .foregroundStyle(RugbyTheme.textPrimary)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
                            .accessibilityLabel("デフォルト自チーム名")
                            .submitLabel(.done)

                        Text("新しい試合のホームチームに、この名前が最初から入ります。")
                            .font(.footnote)
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .rugbyCard()
                }

                VStack(alignment: .leading, spacing: 12) {
                    settingsSectionHeading("配色", caption: "APPEARANCE")
                    paletteCard
                }

                VStack(alignment: .leading, spacing: 12) {
                    settingsSectionHeading("記録を守る・引き継ぐ", caption: "BACKUP & TRANSFER")

                    VStack(spacing: 0) {
                        Button(action: exportBackup) {
                            settingsActionRow(
                                symbol: "square.and.arrow.up",
                                title: "バックアップを書き出す",
                                subtitle: "記録と写真をファイルに保存",
                                accessory: "arrow.up.right"
                            )
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        Button {
                            isRestoreImporterPresented = true
                        } label: {
                            settingsActionRow(
                                symbol: "square.and.arrow.down",
                                title: "バックアップを読み込む",
                                subtitle: "保存した記録を追加・更新"
                            )
                        }
                        .buttonStyle(.plain)

                        settingsDivider

                        NavigationLink { MediaTransferView() } label: {
                            settingsActionRow(
                                symbol: "externaldrive",
                                title: "動画を含めた移行・再接続",
                                subtitle: "動画ファイルを別の端末へ"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .rugbyCard()

                    backupStatus

                    Text("バックアップには全記録・写真・試合時間・映像の時刻合わせ・マイテンプレート・マイ分析を保存します。動画本体は「動画を含めた移行」から共有できます。読み込みは同じIDを更新し、未登録のデータを追加します。古いバックアップに無い追加情報は残します。")
                        .font(.footnote)
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .foregroundStyle(RugbyTheme.accent)
                        .accessibilityHidden(true)
                    Text("大事な大会の後は、バックアップを保存しましょう。")
                        .foregroundStyle(RugbyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(RugbyTheme.background)
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .tint(RugbyTheme.accent)
        .fileImporter(
            isPresented: $isRestoreImporterPresented,
            allowedContentTypes: [.json]
        ) { result in
            restoreBackup(from: result)
        }
        .sheet(item: $backupShareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .fullScreenCover(isPresented: Binding(
            get: { backupActivity != nil },
            set: { if !$0 { backupActivity = nil } }
        ), onDismiss: {
            // 共有シートは、進み具合の画面が閉じきってから出す(重ねて出すと表示されないため)
            if let url = pendingShareURL {
                pendingShareURL = nil
                backupShareItem = BackupShareItem(url: url)
            }
        }) {
            if let backupActivity {
                BackupProgressView(activity: backupActivity) { self.backupActivity = nil }
            }
        }
    }

    /// アプリ全体の配色。どの色も同じ濃さで、色合いだけが変わる(紫を基準に色合いを回して作る)。チームの色(試合・グラフ)は変わらない
    private var paletteCard: some View {
        let selected = RugbyPalette(rawValue: palette) ?? .navy
        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 14) {
                ForEach(RugbyPalette.allCases) { option in
                    let isSelected = option == selected
                    Button {
                        palette = option.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(option.swatch)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 16, weight: .black))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(isSelected ? RugbyTheme.highlight : Color.clear, lineWidth: 2.5).padding(-4))
                            Text(option.name.replacingOccurrences(of: "（標準）", with: ""))
                                .font(.caption2.weight(isSelected ? .bold : .regular))
                                .foregroundStyle(isSelected ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Text("見出し・ボタン・背景の色が変わります。濃さはどの色も同じです。選択中の下線などのピンクと、チームの色（試合やグラフ）はそのままです。")
                .font(.footnote)
                .foregroundStyle(RugbyTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .rugbyCard()
    }

    private func settingsSectionHeading(_ title: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RugbyTheme.textPrimary)
            Spacer(minLength: 0)
            if !dynamicTypeSize.isAccessibilitySize {
                Text(caption)
                    .font(.caption2.weight(.medium))
                    .tracking(0.7)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
            }
        }
    }

    private func settingsActionRow(
        symbol: String,
        title: String,
        subtitle: String,
        accessory: String = "chevron.right"
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(RugbyTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: accessory)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(RugbyTheme.border)
            .frame(height: 1)
    }

    private var backupStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body)
                .foregroundStyle(RugbyTheme.accent)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("最終ファイル作成")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
                if lastFileCreatedAt > 0 {
                    Text(Date(timeIntervalSince1970: lastFileCreatedAt).formatted(date: .numeric, time: .shortened))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("共有先への保存完了は、ファイルアプリなどで確認してください。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                } else {
                    Text("まだ作成されていません")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("この端末の記録をファイルに保存できます。")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
    }

    // タップされた時点でファイルを作り、出来上がったファイルを共有シートに渡す。
    // 作っているあいだは進み具合の画面を出す(記録が多いと時間がかかるため)。
    private func exportBackup() {
        guard backupActivity == nil else { return }
        backupActivity = .export()
        Task {
            await waitForProgressScreen()
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let url = try await BackupManager.writeBackupFileShowingProgress(context: modelContext) { progress in
                    backupActivity?.apply(progress)
                }
                lastFileCreatedAt = Date().timeIntervalSince1970
                pendingShareURL = url
                backupActivity = nil
            } catch {
                backupActivity?.phase = .failed("書き出しに失敗しました。空き容量を確認して、もう一度試してください。")
            }
        }
    }

    private func restoreBackup(from result: Result<URL, Error>) {
        guard case .success(let url) = result, backupActivity == nil else { return }
        backupActivity = .restore()
        Task {
            await waitForProgressScreen()
            // ファイルアプリ経由のURLは、読む前に許可の取得が必要なことがある
            let didAccess = url.startAccessingSecurityScopedResource()
            UIApplication.shared.isIdleTimerDisabled = true
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let summary = try await BackupManager.restoreShowingProgress(from: url, context: modelContext) { progress in
                    backupActivity?.apply(progress)
                }
                backupActivity?.phase = .finished(summary.message)
            } catch let error as BackupError {
                backupActivity?.phase = .failed(error.errorDescription ?? "読み込みに失敗しました。")
            } catch {
                backupActivity?.phase = .failed("読み込みに失敗しました。ファイルを確認してもう一度試してください。")
            }
        }
    }

    /// 進み具合の画面が出きってから重い処理を始める(先に始めると、画面が出る前に固まって見えるため)
    private func waitForProgressScreen() async {
        try? await Task.sleep(for: .milliseconds(450))
    }
}

// 共有シートに渡す「書き出し済みファイル」。sheet(item:) で使うため Identifiable。
private struct BackupShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// iOS 標準の共有シート(UIActivityViewController)を SwiftUI から使う薄いラッパー。
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        SettingsView()
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
