// TeamViews.swift から分割。チーム画面と同じ明るい(白×紫)デザイン

import CoreImage
import PhotosUI
import SwiftData
import SwiftUI
import Vision

// MARK: - Player editor

// MARK: - 選手情報の一括入力

// 選手が多いとき、1人ずつカードを開かずに背番号・名前・読み・英語表記を
// まとめて編集する画面。読みを入れると英語表記が自動で入る(カード編集と同じ規則:
// 英語表記を手で直してある選手は上書きしない)。
struct BulkRosterInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // 入力途中の値を保持する下書き。保存を押すまで選手データには触らない。
    private struct RosterDraft: Identifiable {
        let id: UUID
        let rowIndex: Int
        var numberText: String
        var playingPosition: RugbyPosition?
        var name: String
        var kana: String
        var roman: String
    }

    // キーボードの「次へ」で降りていく先(選手×項目)
    private enum Field: Hashable {
        case name(UUID)
        case kana(UUID)
        case roman(UUID)
    }

    private let players: [Player]
    private let accent: Color
    @State private var drafts: [RosterDraft]
    @FocusState private var focused: Field?

    init(players: [Player], accent: Color) {
        self.players = players
        self.accent = accent
        self._drafts = State(initialValue: players.enumerated().map { index, player in
            RosterDraft(
                id: player.id,
                rowIndex: index + 1,
                numberText: player.number.map(String.init) ?? "",
                playingPosition: player.rugbyPosition,
                name: player.name ?? "",
                kana: player.nameKana ?? "",
                roman: player.nameRoman ?? ""
            )
        })
    }

    // 白い画面で文字やアイコンに使うチームの色(明るすぎる色は濃い文字色に)
    private var ink: Color { accent.prefersDarkText ? RugbyTheme.textPrimary : accent }

    // 下書きの中で重複している背番号(入力しながら気づけるようにオレンジ表示)
    private var duplicatedNumbers: Set<Int> {
        var seen: Set<Int> = []
        var duplicated: Set<Int> = []
        for draft in drafts {
            guard let number = Int(draft.numberText.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if !seen.insert(number).inserted { duplicated.insert(number) }
        }
        return duplicated
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RugbyTheme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 10) {
                        Text("背番号・ポジション・名前・読み・英語表記をまとめて編集できます。読み(かな)を入れると英語表記が自動で入り、手で直した綴りはそのまま残ります。キーボードの「次へ」で下の欄に移動できます。")
                            .font(.caption)
                            .foregroundStyle(RugbyTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)

                        ForEach($drafts) { $draft in
                            draftRow($draft)
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("選手をまとめて入力")
            .navigationBarTitleDisplayMode(.inline)
            // チーム画面のバーの色設定(チームカラー・白文字)を引き継がず、明るいバーにする
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveAndDismiss() }
                        .fontWeight(.bold)
                        .foregroundStyle(ink)
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private func draftRow(_ draft: Binding<RosterDraft>) -> some View {
        let value = draft.wrappedValue
        let isDuplicated = Int(value.numberText.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { duplicatedNumbers.contains($0) } ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(value.rowIndex)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(width: 24, alignment: .leading)

                TextField("番号", text: draft.numberText, prompt: Text("番号").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isDuplicated ? Color.orange : RugbyTheme.textPrimary)
                    .frame(width: 58)
                    .frame(height: 40)
                    .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))

                bulkPositionMenu(draft.playingPosition)

                TextField("名前", text: draft.name, prompt: Text("名前").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
                    .focused($focused, equals: .name(value.id))
                    .submitLabel(.next)
                    .onSubmit { focused = .kana(value.id) }
            }

            HStack(spacing: 8) {
                Spacer().frame(width: 24)

                TextField("読み(やまだ たろう)", text: draft.kana, prompt: Text("読み(やまだ たろう)").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
                    .focused($focused, equals: .kana(value.id))
                    .submitLabel(.next)
                    .onSubmit { focused = .roman(value.id) }
            }

            HStack(spacing: 8) {
                Spacer().frame(width: 24)

                TextField("英語表記(読みから自動)", text: draft.roman, prompt: Text("英語表記(読みから自動)").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .foregroundStyle(ink)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
                    .focused($focused, equals: .roman(value.id))
                    .submitLabel(.next)
                    .onSubmit { focusNextPlayer(after: value.id) }
            }
        }
        .padding(12)
        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RugbyTheme.border, lineWidth: 1))
        // カード編集と同じ規則: 英語表記が空か「直す前の読みからの自動生成のまま」の
        // ときだけ、読みの変更に英語表記を追従させる(手動の綴りは守る)
        .onChange(of: draft.wrappedValue.kana) { oldKana, newKana in
            let autoFromOld = PlayerNameRomanizer.roman(fromKana: oldKana)
            if draft.wrappedValue.roman.isEmpty || draft.wrappedValue.roman == autoFromOld {
                draft.wrappedValue.roman = PlayerNameRomanizer.roman(fromKana: newKana)
            }
        }
    }

    private func bulkPositionMenu(
        _ selection: Binding<RugbyPosition?>
    ) -> some View {
        Menu {
            Button("未設定") {
                selection.wrappedValue = nil
            }

            Divider()

            ForEach(RugbyPosition.allCases) { position in
                Button {
                    selection.wrappedValue = position
                } label: {
                    if selection.wrappedValue == position {
                        Label(position.selectionLabel, systemImage: "checkmark")
                    } else {
                        Text(position.selectionLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selection.wrappedValue?.rawValue ?? "POS")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .black))
            }
            .font(.caption.weight(.black))
            .foregroundStyle(selection.wrappedValue == nil ? RugbyTheme.textSecondary : ink)
            .frame(width: 62, height: 40)
            .background(RugbyTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
        }
        .accessibilityLabel("ポジション")
        .accessibilityValue(selection.wrappedValue?.selectionLabel ?? "未設定")
    }

    private func focusNextPlayer(after id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              index + 1 < drafts.count else {
            focused = nil
            return
        }
        focused = .name(drafts[index + 1].id)
    }

    private func saveAndDismiss() {
        let playersByID = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        for draft in drafts {
            guard let player = playersByID[draft.id] else { continue }

            let trimmedNumber = draft.numberText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedNumber.isEmpty {
                player.number = nil
            } else if let number = Int(trimmedNumber), number > 0 {
                player.number = number
            }

            player.rugbyPosition = draft.playingPosition

            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            player.name = trimmedName.isEmpty ? nil : trimmedName

            let trimmedKana = draft.kana.trimmingCharacters(in: .whitespacesAndNewlines)
            player.nameKana = trimmedKana.isEmpty ? nil : trimmedKana

            let trimmedRoman = draft.roman.trimmingCharacters(in: .whitespacesAndNewlines)
            player.nameRoman = trimmedRoman.isEmpty ? nil : trimmedRoman
        }
        guard AppPersistence.save(modelContext) else { return }
        dismiss()
    }
}

// MARK: - かな→英語表記の自動変換

enum PlayerNameRomanizer {
    /// 読み(かな)から英語表記を作る。「ますだ ゆい」→「YUI MASUDA」。
    /// 日本語の姓名順を英語の「名 姓」順にひっくり返す。1語ならそのまま。
    /// 外国人選手など順序や綴りが違う場合は、生成後に手で直せる前提の下書き。
    static func roman(fromKana kana: String) -> String {
        // 「・」や全角スペースも区切りとして扱う
        let normalized = kana
            .replacingOccurrences(of: "・", with: " ")
            .replacingOccurrences(of: "　", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }

        // かな→ローマ字。「ゆう」→「yū」のような長音記号は普通の英字に畳む
        let latin = normalized.applyingTransform(.toLatin, reverse: false) ?? normalized
        let folded = latin.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))

        let words = folded
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.uppercased() }
        return words.reversed().joined(separator: " ")
    }
}
