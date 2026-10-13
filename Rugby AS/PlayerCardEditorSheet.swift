// TeamViews.swift から分割。チーム画面と同じ明るい(白×紫)デザイン

import CoreImage
import PhotosUI
import SwiftData
import SwiftUI
import Vision

struct PlayerCardEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var player: Player
    let teamName: String
    let accent: Color
    let isNumberDuplicated: Bool
    // nil なら「選手を削除」を出さない(チーム画面以外から開いたとき)
    let onRequestDelete: (() -> Void)?
    // 個人成績画面から開いたときは、同じ画面へのリンクを出さない
    let showsStatsLink: Bool
    let initialImagePath: String?

    @State private var nameText: String
    @State private var kanaText: String
    @State private var romanText: String
    @State private var numberText: String
    @State private var selectedPosition: RugbyPosition?
    @State private var isFavorite: Bool
    @State private var birthDate: Date?
    @State private var heightText: String
    @State private var weightText: String
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isShowingPhotoDeleteConfirmation = false
    @State private var isShowingDiscardConfirmation = false
    @State private var isRemovingBackground = false
    @State private var backgroundRemovalError: String?
    @State private var isShowingMergeSheet = false
    @State private var isShowingLinkSheet = false
    @State private var isAddingAlias = false
    @State private var aliasDraft = ""
    @State private var isShowingSaveBeforeMerge = false

    init(
        player: Player,
        teamName: String,
        accent: Color,
        isNumberDuplicated: Bool,
        showsStatsLink: Bool = true,
        onRequestDelete: (() -> Void)? = nil
    ) {
        self._player = Bindable(wrappedValue: player)
        self.teamName = teamName
        self.accent = accent
        self.isNumberDuplicated = isNumberDuplicated
        self.showsStatsLink = showsStatsLink
        self.onRequestDelete = onRequestDelete
        self.initialImagePath = player.imagePath
        self._nameText = State(initialValue: player.name ?? "")
        self._kanaText = State(initialValue: player.nameKana ?? "")
        self._romanText = State(initialValue: player.nameRoman ?? "")
        self._numberText = State(initialValue: player.number.map(String.init) ?? "")
        self._selectedPosition = State(initialValue: player.rugbyPosition)
        self._isFavorite = State(initialValue: player.isFavorite)
        self._birthDate = State(initialValue: player.birthDate)
        self._heightText = State(initialValue: player.heightCm.map(String.init) ?? "")
        self._weightText = State(initialValue: player.weightKg.map(String.init) ?? "")
    }

    // 白い画面で文字やアイコンに使うチームの色(明るすぎる色は濃い文字色に)
    private var ink: Color { accent.prefersDarkText ? RugbyTheme.textPrimary : accent }
    // チームカラーで塗った面の上の文字色
    private var onAccent: Color { accent.prefersDarkText ? RugbyTheme.textPrimary : .white }

    private var hasUnsavedFieldChanges: Bool {
        nameText != (player.name ?? "")
            || kanaText != (player.nameKana ?? "")
            || romanText != (player.nameRoman ?? "")
            || numberText != (player.number.map(String.init) ?? "")
            || selectedPosition != player.rugbyPosition
            || isFavorite != player.isFavorite
            || birthDate != player.birthDate
            || heightText != (player.heightCm.map(String.init) ?? "")
            || weightText != (player.weightKg.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RugbyTheme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        PlayerCollectionCard(
                            player: player,
                            accent: accent,
                            isNumberDuplicated: isNumberDuplicated
                        )
                        .frame(width: 240)

                        editorFields
                        photoActions
                        aliasAndMergeSection
                        if showsStatsLink {
                            statsLink
                        }
                        if onRequestDelete != nil {
                            deleteButton
                        }
                    }
                    .padding(18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("選手を編集")
            .navigationBarTitleDisplayMode(.inline)
            // チーム画面のバーの色設定(チームカラー・白文字)を引き継がず、明るいバーにする
            .toolbarBackground(RugbyTheme.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { requestClose() }
                        .foregroundStyle(RugbyTheme.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveAndDismiss() }
                        .fontWeight(.bold)
                        .foregroundStyle(ink)
                }
            }
            .onChange(of: photoPickerItem) { _, newItem in
                handleSelectedPhoto(newItem)
            }
            .onChange(of: kanaText) { oldKana, newKana in
                // 英語表記を手で直した後は上書きしない。
                // 空、または「直す前の読みから自動生成した値のまま」のときだけ追従させる。
                let autoFromOld = PlayerNameRomanizer.roman(fromKana: oldKana)
                if romanText.isEmpty || romanText == autoFromOld {
                    romanText = PlayerNameRomanizer.roman(fromKana: newKana)
                }
            }
            .confirmationDialog(
                "写真を削除しますか？",
                isPresented: $isShowingPhotoDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("削除する", role: .destructive) { deletePhoto() }
                Button("キャンセル", role: .cancel) { }
            }
            .confirmationDialog(
                "未保存の入力があります",
                isPresented: $isShowingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("入力を破棄して閉じる", role: .destructive) {
                    dismiss()
                }
                Button("編集を続ける", role: .cancel) { }
            } message: {
                Text(
                    player.imagePath == initialImagePath
                        ? "背番号やプロフィールの入力内容は保存されません。"
                        : "背番号やプロフィールの入力内容は保存されません。写真への変更はすでに保存されています。"
                )
            }
            .sheet(isPresented: $isShowingLinkSheet) {
                PersonLinkSheet(player: player)
            }
            .sheet(isPresented: $isShowingMergeSheet) {
                PlayerMergeSheet(target: player, onMerged: reloadDrafts)
            }
            .alert("別名を追加", isPresented: $isAddingAlias) {
                TextField("例: 旧姓・大会での表記", text: $aliasDraft)
                Button("追加") {
                    let trimmed = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != player.name, !player.aliases.contains(trimmed) else { return }
                    player.aliases.append(trimmed)
                    AppPersistence.save(modelContext)
                }
                Button("キャンセル", role: .cancel) {}
            }
            .alert("先に保存してください", isPresented: $isShowingSaveBeforeMerge) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("統合すると空いている項目が統合する選手から埋まるため、入力中の内容を先に「保存」してから統合してください。")
            }
            .alert("背景を削除できませんでした", isPresented: Binding(
                get: { backgroundRemovalError != nil },
                set: { if !$0 { backgroundRemovalError = nil } }
            )) {
                Button("OK", role: .cancel) { backgroundRemovalError = nil }
            } message: {
                Text(backgroundRemovalError ?? "人物がはっきり写った写真で再度お試しください。")
            }
        }
        .preferredColorScheme(.light)
    }

    private var editorFields: some View {
        VStack(spacing: 0) {
            fieldRow(title: "背番号") {
                TextField("未設定", text: $numberText, prompt: Text("未設定").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(isNumberDuplicated ? Color.orange : RugbyTheme.textPrimary)
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "ポジション") {
                editorPositionMenu
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "お気に入り") {
                HStack {
                    Spacer()
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? Color.orange : RugbyTheme.textSecondary)
                    Toggle("", isOn: $isFavorite)
                        .labelsHidden()
                        .tint(.orange)
                }
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "名前") {
                TextField("名前（任意）", text: $nameText, prompt: Text("名前（任意）").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(RugbyTheme.textPrimary)
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "読み") {
                TextField("やまだ たろう", text: $kanaText, prompt: Text("やまだ たろう").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(RugbyTheme.textPrimary)
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "英語表記") {
                TextField("読みから自動で入力", text: $romanText, prompt: Text("読みから自動で入力").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(RugbyTheme.textPrimary)
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "生年月日") {
                if let currentBirthDate = birthDate {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)

                        if let age = Self.age(from: currentBirthDate) {
                            Text("\(age)歳")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(ink)
                        }

                        DatePicker(
                            "",
                            selection: Binding(
                                get: { currentBirthDate },
                                set: { birthDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ja_JP"))

                        Button {
                            birthDate = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(RugbyTheme.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button("未設定・タップで入力") {
                        // 初期値は学生年代の目安。ホイールで実際の日付に合わせてもらう
                        birthDate = Calendar.current.date(from: DateComponents(year: 2005, month: 4, day: 1))
                    }
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "身長") {
                HStack(spacing: 4) {
                    TextField("未設定", text: $heightText, prompt: Text("未設定").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("cm")
                        .font(.subheadline)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }

            Divider().overlay(RugbyTheme.border)

            fieldRow(title: "体重") {
                HStack(spacing: 4) {
                    TextField("未設定", text: $weightText, prompt: Text("未設定").foregroundStyle(RugbyTheme.textSecondary.opacity(0.6)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("kg")
                        .font(.subheadline)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }
            }

            Text("読み(かな)を入力すると英語表記が自動で入ります。カードの名前の下に表示されるので、綴りが違うときは英語表記を直接直してください。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)

            if isNumberDuplicated {
                Text("同じ背番号の選手が登録されています。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .profileCard()
    }

    private var editorPositionMenu: some View {
        Menu {
            Button("未設定") {
                selectedPosition = nil
            }

            Divider()

            ForEach(RugbyPosition.allCases) { position in
                Button {
                    selectedPosition = position
                } label: {
                    if selectedPosition == position {
                        Label(position.selectionLabel, systemImage: "checkmark")
                    } else {
                        Text(position.selectionLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(selectedPosition?.selectionLabel ?? "未設定")
                    .foregroundStyle(selectedPosition == nil ? RugbyTheme.textSecondary : RugbyTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(ink)
            }
        }
        .accessibilityLabel("ポジション")
        .accessibilityValue(selectedPosition?.selectionLabel ?? "未設定")
    }

    private func fieldRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RugbyTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: 72, alignment: .leading)
            content()
        }
        .frame(minHeight: 48)
    }

    private var photoActions: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Label(player.imagePath == nil ? "写真を追加" : "写真を変更", systemImage: "photo")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(RugbyTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .profileCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)

            if player.imagePath != nil {
                Button {
                    removePhotoBackground()
                } label: {
                    HStack(spacing: 9) {
                        if isRemovingBackground {
                            ProgressView().tint(onAccent)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isRemovingBackground ? "背景を削除中…" : "背景を自動で削除")
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accent, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isRemovingBackground)

                Button("写真を削除", role: .destructive) {
                    isShowingPhotoDeleteConfirmation = true
                }
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
            }

            Text("写真に関する操作はその場で保存されます。背景削除後は透明PNGになり、カードの共通背景に自然に重なります。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 別名(旧姓・表記ゆれ)と、同じチームで2人に分かれた同じ選手の統合。
    // 別名は写真と同じくその場で保存する。
    private var aliasAndMergeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("別名・統合", systemImage: "arrow.triangle.merge")
                .font(.headline.weight(.heavy))
                .foregroundStyle(RugbyTheme.textPrimary)

            if player.aliases.isEmpty {
                Text("別名はありません")
                    .font(.subheadline)
                    .foregroundStyle(RugbyTheme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(player.aliases, id: \.self) { alias in
                            HStack(spacing: 4) {
                                Text(alias)
                                Button {
                                    player.aliases.removeAll { $0 == alias }
                                    AppPersistence.save(modelContext)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(RugbyTheme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("別名「\(alias)」を外す")
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RugbyTheme.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RugbyTheme.background, in: Capsule())
                            .overlay(Capsule().stroke(RugbyTheme.border, lineWidth: 1))
                        }
                    }
                }
            }

            if player.personID != nil {
                Label("ほかのチームの登録と同一人物としてつないでいます", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RugbyTheme.textSecondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                editorChip("＋ 別名を追加") {
                    aliasDraft = ""
                    isAddingAlias = true
                }
                editorChip("同一人物としてつなぐ…") {
                    isShowingLinkSheet = true
                }
                editorChip("同じチームの選手を統合…") {
                    if hasUnsavedFieldChanges {
                        isShowingSaveBeforeMerge = true
                    } else {
                        isShowingMergeSheet = true
                    }
                }
            }
            }

            Text("旧姓や大会での表記を別名に入れておくと、公式記録の取り込みで同じ選手として扱います。移籍・代表・国体・合同チームなど別のチームの同じ人は「つなぐ」で個人成績をまとめます。別名・つなぐ・統合はその場で保存されます。")
                .font(.caption)
                .foregroundStyle(RugbyTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .profileCard()
    }

    private func editorChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(RugbyTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RugbyTheme.background, in: Capsule())
                .overlay(Capsule().stroke(RugbyTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 統合で空いていた項目が埋まったので、入力欄を選手の値で読み直す
    private func reloadDrafts() {
        nameText = player.name ?? ""
        kanaText = player.nameKana ?? ""
        romanText = player.nameRoman ?? ""
        numberText = player.number.map(String.init) ?? ""
        selectedPosition = player.rugbyPosition
        isFavorite = player.isFavorite
        birthDate = player.birthDate
        heightText = player.heightCm.map(String.init) ?? ""
        weightText = player.weightKg.map(String.init) ?? ""
    }

    private var statsLink: some View {
        NavigationLink {
            PlayerDetailView(player: player)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(ink)
                    .frame(width: 34, height: 34)
                    .background(ink.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("個人成績を見る")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(RugbyTheme.textPrimary)
                    Text("試合別・大会別の記録を確認")
                        .font(.caption)
                        .foregroundStyle(RugbyTheme.textSecondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(RugbyTheme.textSecondary)
            }
            .padding(16)
            .profileCard()
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            onRequestDelete?()
            dismiss()
        } label: {
            Label("選手を削除", systemImage: "trash")
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func saveAndDismiss() {
        let trimmedName = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        player.name = trimmedName.isEmpty ? nil : trimmedName

        let trimmedKana = kanaText.trimmingCharacters(in: .whitespacesAndNewlines)
        player.nameKana = trimmedKana.isEmpty ? nil : trimmedKana

        let trimmedRoman = romanText.trimmingCharacters(in: .whitespacesAndNewlines)
        player.nameRoman = trimmedRoman.isEmpty ? nil : trimmedRoman

        let trimmedNumber = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNumber.isEmpty {
            player.number = nil
        } else if let number = Int(trimmedNumber), number > 0 {
            player.number = number
        }

        player.rugbyPosition = selectedPosition
        player.isFavorite = isFavorite
        player.birthDate = birthDate

        let trimmedHeight = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
        player.heightCm = Int(trimmedHeight).flatMap { $0 > 0 ? $0 : nil }

        let trimmedWeight = weightText.trimmingCharacters(in: .whitespacesAndNewlines)
        player.weightKg = Int(trimmedWeight).flatMap { $0 > 0 ? $0 : nil }

        guard AppPersistence.save(modelContext) else { return }
        dismiss()
    }

    private func requestClose() {
        if hasUnsavedFieldChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    // 生年月日から現在の満年齢を計算する
    static func age(from birthDate: Date) -> Int? {
        Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    private func handleSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await MainActor.run {
                if let data, let newName = ImageStorage.save(data) {
                    replacePhoto(with: newName)
                }
                photoPickerItem = nil
            }
        }
    }

    private func removePhotoBackground() {
        guard !isRemovingBackground,
              let name = player.imagePath,
              let image = ImageStorage.image(named: name),
              let sourceData = image.pngData() else { return }

        isRemovingBackground = true
        Task {
            let outputData = await Task.detached(priority: .userInitiated) {
                try? ForegroundBackgroundRemover.removeBackground(from: sourceData)
            }.value

            await MainActor.run {
                defer { isRemovingBackground = false }
                guard let outputData, let newName = ImageStorage.savePNG(outputData) else {
                    backgroundRemovalError = "人物の輪郭を検出できませんでした。人物が大きく、背景との区別がつきやすい写真で再度お試しください。"
                    return
                }
                replacePhoto(with: newName)
            }
        }
    }

    private func replacePhoto(with newName: String) {
        SafeImageMutation.replace(old: player.imagePath, new: newName, context: modelContext,
            set: { player.imagePath = $0 }, removeImage: { ImageStorage.delete(named: $0) })
    }

    private func deletePhoto() {
        SafeImageMutation.replace(old: player.imagePath, new: nil, context: modelContext,
            set: { player.imagePath = $0 }, removeImage: { ImageStorage.delete(named: $0) })
    }
}

// MARK: - Background removal

nonisolated enum ForegroundBackgroundRemover {
    static func removeBackground(from data: Data) throws -> Data {
        guard let image = UIImage(data: data),
              let inputImage = CIImage(image: image, options: [.applyOrientationProperty: true]) else {
            throw BackgroundRemovalError.invalidImage
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: inputImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            throw BackgroundRemovalError.noForeground
        }

        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let transparentBackground = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ).cropped(to: inputImage.extent)

        let outputImage = inputImage.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: transparentBackground,
                kCIInputMaskImageKey: maskImage
            ]
        )

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(outputImage, from: inputImage.extent) else {
            throw BackgroundRemovalError.renderFailed
        }

        let output = UIImage(cgImage: cgImage)
        guard let pngData = output.pngData() else {
            throw BackgroundRemovalError.renderFailed
        }
        return pngData
    }

    private enum BackgroundRemovalError: Error {
        case invalidImage
        case noForeground
        case renderFailed
    }
}

private extension View {
    // 白いカード(チーム画面・選手詳細と同じ白い面と細い枠)
    func profileCard(cornerRadius: CGFloat = 16) -> some View {
        background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(RugbyTheme.border, lineWidth: 1))
    }
}
