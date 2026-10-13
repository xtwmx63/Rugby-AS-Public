//
//  PlayerSelectionSheet.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/17.
//

import SwiftUI

struct PlayerSelectionSheet: View {
    let players: [Player]
    let title: String
    // その試合での背番号を返す(未指定なら基本番号)。nil = 背番号なし。
    // ラグビーは試合ごとに背番号が変わるため、呼び出し側が差し替えられる。
    var numberFor: ((Player) -> Int?)? = nil
    let onSelect: (Player?) -> Void
    @State private var roster = RecordingPlayerRoster()
    @State private var showOtherPlayers = false

    var body: some View {
        NavigationStack {
            List {
                Button("選手なし") {
                    onSelect(nil)
                }

                ForEach(roster.visiblePlayers(includeOthers: showOtherPlayers)) { player in
                    Button {
                        onSelect(player)
                    } label: {
                        HStack {
                            Text(roster.number(for: player).map { "#\($0)" } ?? "ー")
                                .font(.headline.monospacedDigit())
                                .frame(width: 48, alignment: .leading)

                            Text(player.name ?? "名前未設定")
                                .foregroundStyle(player.name == nil ? .secondary : .primary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !roster.others.isEmpty {
                    Button(showOtherPlayers ? "背番号ありの選手のみ表示" : "その他の選手を表示（\(roster.others.count)人）") {
                        showOtherPlayers.toggle()
                    }.frame(maxWidth: .infinity, minHeight: 44).background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                roster = RecordingPlayerRoster(players: players, numberFor: displayNumber)
                showOtherPlayers = false
            }
        }
    }

    private func displayNumber(for player: Player) -> Int? {
        if let numberFor {
            return numberFor(player)
        }
        return player.number
    }
}
