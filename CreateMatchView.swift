//
//  CreateMatchView.swift
//  Rugby AS
//
//  Created by Codex on 2026/05/17.
//

import SwiftData
import SwiftUI

struct CreateMatchView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tournament.officialName) private var tournaments: [Tournament]
    @Query(sort: \Team.name) private var teams: [Team]

    @AppStorage("lastMatchDateTimestamp") private var lastMatchDateTimestamp = Date().timeIntervalSince1970
    // 設定画面で入力した自チーム名。ホームチームの初期値に使う
    @AppStorage("defaultTeamName") private var defaultTeamName = ""

    @State private var selectedTournamentID: UUID?
    @State private var newTournamentName = ""
    @State private var selectedHomeTeamID: UUID?
    @State private var newHomeTeamName = ""
    @State private var selectedAwayTeamID: UUID?
    @State private var newAwayTeamName = ""
    @State private var playedAt = Date()
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    @State private var recordingMatch: Match?

    var body: some View {
        Form {
            Section {
                RugbyScreenHeading(
                    eyebrow: "NEW MATCH",
                    title: "試合をつくる",
                    subtitle: "大会と対戦チームを選択。選手は後から追加できます。"
                )
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 12, leading: 4, bottom: 4, trailing: 4))
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("大会を選択", selection: $selectedTournamentID) {
                    Text("新規作成").tag(UUID?.none)
                    ForEach(tournaments) { tournament in
                        Text(tournament.officialName).tag(Optional(tournament.id))
                    }
                }
                .frame(minHeight: 44)

                if selectedTournamentID == nil {
                    TextField("大会の正式名称を入力", text: $newTournamentName)
                        .accessibilityLabel("新しい大会の正式名称")
                        .frame(minHeight: 44)
                        .submitLabel(.next)
                }
            } header: {
                sectionHeading("大会", symbol: "trophy")
            } footer: {
                Text("登録済みの大会を選ぶか、新しい大会名を入力してください。")
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .listRowBackground(RugbyTheme.surface)
            .listRowSeparatorTint(RugbyTheme.border)

            Section {
                TeamSelectionFields(
                    title: "ホーム",
                    eyebrow: "HOME",
                    selectedTeamID: $selectedHomeTeamID,
                    newTeamName: $newHomeTeamName,
                    teams: teams
                )

                TeamSelectionFields(
                    title: "アウェイ",
                    eyebrow: "AWAY",
                    selectedTeamID: $selectedAwayTeamID,
                    newTeamName: $newAwayTeamName,
                    teams: teams
                )
            } header: {
                sectionHeading("対戦チーム", symbol: "person.3")
            }
            .listRowBackground(RugbyTheme.surface)
            .listRowSeparatorTint(RugbyTheme.border)

            Section {
                DatePicker("日付", selection: $playedAt, displayedComponents: .date)
                    .frame(minHeight: 44)
            } header: {
                sectionHeading("試合日", symbol: "calendar")
            }
            .listRowBackground(RugbyTheme.surface)

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: canSave ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(canSave ? RugbyTheme.accent : RugbyTheme.textSecondary)
                            .accessibilityHidden(true)
                        Text(saveGuidance)
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.footnote)
                    .padding(.bottom, 4)

                    Button {
                        saveMatch(shouldStartRecording: true)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .accessibilityHidden(true)
                            Text("保存して記録開始")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(RugbyPrimaryButtonStyle())
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)

                    Button {
                        saveMatch(shouldStartRecording: false)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                            Text("保存のみ")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(canSave ? RugbyTheme.textPrimary : RugbyTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .background(RugbyTheme.background)
        .foregroundStyle(RugbyTheme.textPrimary)
        .tint(RugbyTheme.accent)
        .navigationTitle("試合をつくる")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") {
                    dismiss()
                }
            }
        }
        .onAppear {
            playedAt = Date(timeIntervalSince1970: lastMatchDateTimestamp)
            applyDefaultTeamNameIfNeeded()
        }
        .alert(alertTitle, isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "入力内容を確認してください。")
        }
        .navigationDestination(item: $recordingMatch) { match in
            // 記録の前にスタメン/リザーブを登録する画面を挟む。
            // メンバー登録画面から記録画面を選択する。
            LineupRegistrationView(match: match)
        }
    }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(RugbyTheme.accent)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(RugbyTheme.textPrimary)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        .padding(.bottom, 4)
    }

    private var saveGuidance: String {
        if !isDifferentTeamSelection {
            return "ホームとアウェイには、別のチームを選んでください。"
        }

        var missingFields: [String] = []
        if !hasTournament { missingFields.append("大会") }
        if !hasHomeTeam { missingFields.append("ホームチーム") }
        if !hasAwayTeam { missingFields.append("アウェイチーム") }
        if !missingFields.isEmpty {
            return "\(missingFields.joined(separator: "・"))を入力または選択すると保存できます。"
        }

        return "記録開始の前に、メンバーを登録できます。保存だけして、後から記録を始めることもできます。"
    }

    // 設定の自チーム名をホームチームに最初から入れておく(毎回入力させない)。
    // 既に同名のチームが登録済みならそれを選択、なければ新規名として入れる。
    private func applyDefaultTeamNameIfNeeded() {
        let name = trimmed(defaultTeamName)
        guard !name.isEmpty,
              selectedHomeTeamID == nil,
              trimmed(newHomeTeamName).isEmpty else { return }

        if let existing = teams.first(where: { $0.name == name }) {
            selectedHomeTeamID = existing.id
        } else {
            newHomeTeamName = name
        }
    }

    private var canSave: Bool {
        hasTournament && hasHomeTeam && hasAwayTeam && isDifferentTeamSelection
    }

    private var hasTournament: Bool {
        selectedTournamentID != nil || !trimmed(newTournamentName).isEmpty
    }

    private var hasHomeTeam: Bool {
        selectedHomeTeamID != nil || !trimmed(newHomeTeamName).isEmpty
    }

    private var hasAwayTeam: Bool {
        selectedAwayTeamID != nil || !trimmed(newAwayTeamName).isEmpty
    }

    private var isDifferentTeamSelection: Bool {
        if let selectedHomeTeamID, let selectedAwayTeamID {
            return selectedHomeTeamID != selectedAwayTeamID
        }
        return true
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }

    private func saveMatch(shouldStartRecording: Bool) {
        guard canSave else {
            showAlert(title: "保存できませんでした", message: "大会、ホームチーム、アウェイチームを入力してください。")
            return
        }

        let tournament = selectedTournament() ?? createTournament()
        let homeTeam = selectedTeam(id: selectedHomeTeamID) ?? createTeam(name: trimmed(newHomeTeamName))
        let awayTeam = selectedTeam(id: selectedAwayTeamID) ?? createTeam(name: trimmed(newAwayTeamName))

        guard homeTeam.id != awayTeam.id else {
            showAlert(title: "保存できませんでした", message: "ホームとアウェイには別のチームを選んでください。")
            return
        }

        let match = Match(
            tournamentID: tournament.id,
            homeTeamID: homeTeam.id,
            awayTeamID: awayTeam.id,
            playedAt: playedAt
        )
        modelContext.insert(match)
        lastMatchDateTimestamp = playedAt.timeIntervalSince1970

        do {
            try modelContext.save()
            if shouldStartRecording {
                recordingMatch = match
            } else {
                dismiss()
            }
        } catch {
            showAlert(title: "保存できませんでした", message: "保存中にエラーが起きました。")
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }

    private func selectedTournament() -> Tournament? {
        guard let selectedTournamentID else { return nil }
        return tournaments.first { $0.id == selectedTournamentID }
    }

    private func selectedTeam(id: UUID?) -> Team? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    private func createTournament() -> Tournament {
        let tournament = Tournament(officialName: trimmed(newTournamentName))
        modelContext.insert(tournament)
        return tournament
    }

    private func createTeam(name: String) -> Team {
        let team = Team(name: name)
        modelContext.insert(team)
        for number in 1...15 {
            modelContext.insert(Player(teamID: team.id, number: number))
        }
        return team
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TeamSelectionFields: View {
    let title: String
    let eyebrow: String
    @Binding var selectedTeamID: UUID?
    @Binding var newTeamName: String
    let teams: [Team]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(eyebrow)
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(RugbyTheme.accent)
                    .accessibilityHidden(true)
                Text("\(title)チーム")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            Picker("チームを選択", selection: $selectedTeamID) {
                Text("新規作成").tag(UUID?.none)
                ForEach(teams) { team in
                    Text(team.name).tag(Optional(team.id))
                }
            }
            .frame(minHeight: 44)
            .accessibilityLabel("\(title)チームを選択")
            .accessibilityValue(teams.first(where: { $0.id == selectedTeamID })?.name ?? "新規作成")

            if selectedTeamID == nil {
                TextField("\(title)チーム名を入力", text: $newTeamName)
                    .accessibilityLabel("新しい\(title)チーム名")
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { Rectangle().fill(RugbyTheme.border).frame(height: 1) }
                    .submitLabel(.next)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack {
        CreateMatchView()
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
