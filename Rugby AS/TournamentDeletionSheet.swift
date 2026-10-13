//
//  TournamentDeletionSheet.swift
//  Rugby AS
//
//  大会を試合ごとまとめて削除する確認画面。消える件数と、
//  この大会にしか出ていないチーム・選手を見せ、チームごとに外せる。
//

import SwiftData
import SwiftUI

struct TournamentDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let tournament: Tournament

    @State private var plan: TournamentDeletion.Plan?
    // 大会名は開いたときに控える(削除した直後の描き直しで、消した大会を読まないため)
    @State private var tournamentName = ""
    @State private var teamIDsToDelete = Set<UUID>()
    @State private var deletesOnlyHerePlayers = true
    @State private var isConfirming = false

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    Section {
                        row("試合", "\(plan.matchIDs.count)試合")
                        row("記録", "\(plan.eventCount)件")
                        row("メンバー表", "\(plan.lineupCount)件")
                        row("交代", "\(plan.substitutionCount)件")
                    } header: {
                        Text("「\(tournamentName)」と一緒に消えるもの")
                            .textCase(nil)
                    } footer: {
                        Text("試合の動画やキックオフ合わせの設定も消えます。")
                    }

                    if !plan.onlyHereTeams.isEmpty {
                        Section {
                            ForEach(plan.onlyHereTeams) { team in
                                Button {
                                    if teamIDsToDelete.contains(team.id) { teamIDsToDelete.remove(team.id) }
                                    else { teamIDsToDelete.insert(team.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: teamIDsToDelete.contains(team.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(teamIDsToDelete.contains(team.id) ? Color.red : RugbyTheme.textSecondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(team.name)
                                                .foregroundStyle(RugbyTheme.textPrimary)
                                            Text("選手 \(plan.onlyHereTeamPlayerCount[team.id] ?? 0)人")
                                                .font(.caption)
                                                .foregroundStyle(RugbyTheme.textSecondary)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("この大会にしか出ていないチーム（選手名簿ごと削除）")
                                .textCase(nil)
                        } footer: {
                            Text("自分のチームなど残したいものは、チェックを外してください。ほかの大会にも出ているチームは消えません。")
                        }
                    }

                    if !plan.onlyHerePlayers.isEmpty {
                        Section {
                            Toggle(isOn: $deletesOnlyHerePlayers) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("残るチームの、この大会にしか出ていない選手も削除")
                                    Text(playerPreview(plan.onlyHerePlayers))
                                        .font(.caption)
                                        .foregroundStyle(RugbyTheme.textSecondary)
                                        .lineLimit(3)
                                }
                            }
                            .tint(.red)
                        } footer: {
                            Text("\(plan.onlyHerePlayers.count)人。ほかの試合にも出ている選手や、試合に出ていない選手は消えません。")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            isConfirming = true
                        } label: {
                            Label("大会をまとめて削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.bold)
                        }
                    } footer: {
                        Text("元に戻せません。心配なときは先に設定からバックアップを書き出してください。")
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("大会を削除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .onAppear(perform: load)
            .confirmationDialog("本当に削除しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("削除する", role: .destructive) { performDeletion() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(RugbyTheme.textSecondary)
        }
    }

    private func playerPreview(_ players: [Player]) -> String {
        let names = players.prefix(5).map(\.rosterDisplayName)
        return names.joined(separator: "、") + (players.count > 5 ? " ほか" : "")
    }

    private var confirmMessage: String {
        guard let plan else { return "" }
        var parts = ["\(plan.matchIDs.count)試合と記録"]
        if !teamIDsToDelete.isEmpty { parts.append("\(teamIDsToDelete.count)チーム") }
        if deletesOnlyHerePlayers && !plan.onlyHerePlayers.isEmpty { parts.append("\(plan.onlyHerePlayers.count)人の選手") }
        return "「\(tournamentName)」と、" + parts.joined(separator: "・") + "を削除します。元に戻せません。"
    }

    private func load() {
        guard plan == nil else { return }
        tournamentName = tournament.officialName
        do {
            let loaded = try TournamentDeletion.plan(for: tournament, context: modelContext)
            plan = loaded
            teamIDsToDelete = Set(loaded.onlyHereTeams.map(\.id))
        } catch {
            AppPersistence.report(error)
            dismiss()
        }
    }

    private func performDeletion() {
        guard let plan, !tournament.isDeleted else { return }
        let players = deletesOnlyHerePlayers ? Set(plan.onlyHerePlayers.map(\.id)) : []
        let succeeded = TournamentDeletion.delete(
            tournament,
            teamIDsToDelete: teamIDsToDelete,
            playerIDsToDelete: players,
            context: modelContext,
            removeImage: { ImageStorage.delete(named: $0) },
            afterMatchesDeleted: { matchIDs in
                // 試合一覧の削除と同じく、試合ごとの動画と時計の設定も消す
                for matchID in matchIDs {
                    VideoStorage.deleteVideo(for: matchID)
                    MatchClockSettingsCleanup.removeSettings(for: matchID)
                }
            }
        )
        if succeeded { dismiss() }
    }
}
