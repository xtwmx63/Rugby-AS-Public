//
//  Rugby_ASApp.swift
//  Rugby AS
//
//  Created by 35 on 2026/05/17.
//

import SwiftUI
import SwiftData

@main
struct Rugby_ASApp: App {
    private var isBoardPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--recording-board-preview")
            || ProcessInfo.processInfo.arguments.contains("--design-preview")
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppStartupView(isBoardPreview: isBoardPreview)
                .preferredColorScheme(.light)
                .modifier(PersistenceErrorPresenter())
        }
    }
}

private struct AppStartupView: View {
    let isBoardPreview: Bool
    @State private var container: ModelContainer?
    @State private var failure: String?
    @State private var attempt = 0
    // 配色を変えたら画面を作り直す(色は RugbyTheme から直接読むので、作り直さないと古い色が残る)。
    // 作り直した後は、配色を選んでいた設定タブを開いたままにする
    @AppStorage(RugbyTheme.paletteKey) private var palette = RugbyPalette.navy.rawValue
    @State private var reopensSettings = false
    @State private var launchPalette = UserDefaults.standard.string(forKey: RugbyTheme.paletteKey) ?? RugbyPalette.navy.rawValue
    // 作り直すのと同じ回で判定しないと、最初のタブに戻ってしまう(onChange は作り直しの後に届くため)
    private var initialSection: String? { reopensSettings || palette != launchPalette ? "settings" : nil }

    var body: some View {
        Group {
            if let container {
                Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--design-preview") { RugbyDesignPreview() }
                else if isBoardPreview { RecordingBoardPreview().preferredColorScheme(.dark).tint(.blue) }
                else { RootTabView(initialSection: initialSection).id(palette) }
                #else
                RootTabView(initialSection: initialSection).id(palette)
                #endif
                }.modelContainer(container)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "rugbyball.fill").font(.largeTitle).foregroundStyle(RugbyTheme.accent)
                    Text("Rugby AS").font(.title2.bold())
                    if let failure {
                        Text("記録を開けませんでした").font(.headline)
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                        Button("もう一度開く") { attempt += 1 }
                    } else { ProgressView("記録を準備しています…") }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RugbyTheme.background)
            }
        }
        .tint(RugbyTheme.accent)
        .onChange(of: palette) { _, _ in reopensSettings = true }
        .task(id: attempt) {
            guard container == nil else { return }
            failure = nil
            let preview = isBoardPreview
            let loading = Task.detached(priority: .userInitiated) { try AppDataLoader.openStore(inMemory: preview) }
            do {
                let opened = try await loading.value
                ModelChangeTracker.shared.start(container: opened)
                container = opened
                // 全試合の背番号の点検が要るときは、画面を出した後に裏で行う(数十秒かかることがあるため)
                if !preview && AppDataLoader.needsFullNumberCheck {
                    Task.detached(priority: .utility) { AppDataLoader.runFullNumberCheck(container: opened) }
                }
                // 以前に取り込んだ公式記録の試合に、交代・出典などを後から入れる(開発版のみ・1回だけ)
                if !preview {
                    await OfficialRecordImporter.resyncImportedMatches(
                        container: opened, archiveURL: Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite"))
                    // 公式記録票の公開が終わって得点なしで取り込まれた試合に、試合ページの内訳から得点を入れる(1回だけ・裏で)
                    let archive = Bundle.main.url(forResource: "OfficialRecords", withExtension: "sqlite")
                    Task.detached(priority: .utility) {
                        OfficialRecordImporter.fillScoresFromBreakdown(container: opened, archiveURL: archive)
                    }
                }
            } catch { failure = error.localizedDescription }
        }
    }
}
