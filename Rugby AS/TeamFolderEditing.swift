//
//  TeamFolderEditing.swift
//  Rugby AS
//
//  マイフォルダの中身を決めるシート。チームに付ける印は Team.category(1チーム1フォルダ)。
//  ほかのマイフォルダに入っているチームを選ぶと、こちらへ移る。
//

import SwiftData
import SwiftUI

struct TeamFolderMemberPicker: View {
    let folderName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Team.name) private var teams: [Team]

    @State private var selected: Set<UUID> = []
    @State private var didLoad = false
    @State private var searchText = ""

    private var shownTeams: [Team] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = teams.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return query.isEmpty ? sorted : sorted.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shownTeams) { team in
                        row(team)
                    }
                } header: {
                    Text("\(selected.count)チームを選択中")
                        .textCase(nil)
                } footer: {
                    Text("1つのチームが入れるマイフォルダは1つです。ほかのフォルダに入っているチームを選ぶと、こちらへ移ります。チームを1つも入れないフォルダは残りません。")
                }
            }
            .searchable(text: $searchText, prompt: "チームを検索")
            .navigationTitle(folderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                // 開いたときに今入っているチームを選んだ状態にする(1回だけ)
                guard !didLoad else { return }
                didLoad = true
                selected = Set(teams.filter { TeamFolderIndex.myFolderName(of: $0) == folderName }.map(\.id))
            }
        }
    }

    private func row(_ team: Team) -> some View {
        let isSelected = selected.contains(team.id)
        let otherFolder = TeamFolderIndex.myFolderName(of: team).flatMap { $0 == folderName ? nil : $0 }
        return Button {
            if isSelected { selected.remove(team.id) } else { selected.insert(team.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? RugbyTheme.accent : RugbyTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.name)
                        .foregroundStyle(RugbyTheme.textPrimary)
                    if let otherFolder {
                        Text(isSelected ? "「\(otherFolder)」から移ります" : "今は「\(otherFolder)」")
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        for team in teams {
            let isIn = TeamFolderIndex.myFolderName(of: team) == folderName
            if selected.contains(team.id) {
                if !isIn { team.category = folderName }
            } else if isIn {
                team.category = nil
            }
        }
        guard AppPersistence.save(modelContext) else { return }
        dismiss()
    }
}
