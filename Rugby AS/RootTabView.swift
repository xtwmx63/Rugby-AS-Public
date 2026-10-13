import SwiftUI

/// アプリの一番外側。下のタブで画面を切り替える。
/// タブごとに自分の画面の積み重ね(NavigationStack)を持つので、
/// 別のタブへ行って戻っても、見ていた画面やスクロール位置がそのまま残る。
struct RootTabView: View {
    private enum Tab: Hashable {
        case matches, teams, analysis, officialRecords, settings
    }

    @State private var selection: Tab = .matches

    init(initialSection: String? = nil) {
        let initial: Tab
        switch initialSection {
        case "teams": initial = .teams
        case "analysis": initial = .analysis
        case "settings": initial = .settings
        default: initial = .matches
        }
        _selection = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selection) {
            ContentView()
                .tabItem { Label("試合一覧", systemImage: "trophy") }
                .tag(Tab.matches)

            NavigationStack { TeamListView() }
                .tabItem { Label("チーム", systemImage: "person.3") }
                .tag(Tab.teams)

            NavigationStack { AnalysisWorkspaceView() }
                .tabItem { Label("分析", systemImage: "chart.bar.xaxis") }
                .tag(Tab.analysis)

            #if DEBUG
            // 配布版には入れない(OfficialRecordsView.swift の冒頭を参照)
            NavigationStack { OfficialRecordsView() }
                .tabItem { Label("公式記録", systemImage: "books.vertical") }
                .tag(Tab.officialRecords)
            #endif

            NavigationStack { SettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(RugbyTheme.accent)
        .toolbarBackground(RugbyTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.light, for: .tabBar)
    }
}
