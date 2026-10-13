//
//  StreamSplitView.swift
//  Rugby AS
//
//  1日中まわっている配信(セブンズなど)の長い動画を、試合ごとの短い動画に切り出す画面。
//
//  使い方:
//  1. 長い動画を1本選ぶ(写真App / ファイルApp のどちらでも可)
//  2. 再生しながら「ここから」「ここまで」を押して試合の区間を作る
//  3. 区間ごとに、どの試合の動画にするかを決める(その場で新しい試合も作れる)
//  4. まとめて書き出す。切り出した動画は各試合に自動で紐づく
//
//  データの持ち方は今までと同じ(1試合が自分の動画を持つ)。
//  そのためタイムライン編集もハイライト書き出しもそのまま動く。
//

import AVFoundation
import AVKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// 写真Appから選んだ動画をアプリ内に保存するための受け皿
private struct SplitImportedMovie: Transferable, Sendable {
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let name = try VideoStorage.save(from: received.file)
            return SplitImportedMovie(fileName: name)
        }
    }
}

// 切り出す1区間 = 1試合ぶん
private struct SplitSegment: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var matchID: UUID?
    var isDone = false

    var duration: Double { max(0, end - start) }
}

struct StreamSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Match.playedAt, order: .reverse) private var matches: [Match]
    @Query private var teams: [Team]

    // 元動画
    @State private var sourceURL: URL?
    // 写真Appから取り込んだ場合のファイル名。作業後に削除できるよう控えておく
    @State private var importedSourceName: String?
    @State private var isSecurityScoped = false

    @State private var photoItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isCreateMatchPresented = false

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?

    @State private var pendingStart: Double?
    @State private var segments: [SplitSegment] = []

    @State private var isImportingSource = false
    @State private var importProgress: Double = 0
    @State private var exportingIndex: Int?
    @State private var exportProgress: Double = 0
    @State private var finishedCount = 0
    @State private var errorMessage: String?

    private var isExporting: Bool { exportingIndex != nil }

    private var assignedSegments: [SplitSegment] {
        segments.filter { $0.matchID != nil && !$0.isDone && $0.duration > 0.5 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isImportingSource {
                    importingView
                } else if sourceURL == nil {
                    sourcePickerView
                } else {
                    editorView
                }
            }
            .navigationTitle("配信を試合ごとに分ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { close() }
                        .disabled(isExporting || isImportingSource)
                }
            }
        }
        .interactiveDismissDisabled(isExporting || isImportingSource)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.movie]
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $isCreateMatchPresented) {
            NavigationStack {
                CreateMatchView()
            }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: photoItem) { _, newValue in
            if let newValue {
                importFromPhotos(newValue)
            }
        }
        .onDisappear { teardownPlayer() }
    }

    // MARK: - 動画を選ぶ

    private var sourcePickerView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "scissors")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("長い配信の動画を1本選びます")
                .font(.headline)

            Text("選んだあと、再生しながら試合ごとの区間を作ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .videos) {
                    Label("写真Appから選ぶ", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("ファイルAppから選ぶ", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.secondary.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                Text("ファイルAppから選ぶと、長い動画をコピーせずに使えます(空き容量の節約になります)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()
        }
        .padding()
    }

    private var importingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: importProgress)
                .padding(.horizontal, 40)
            Text("動画を読み込んでいます… \(Int(importProgress * 100))%")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("長い動画では時間がかかります。画面を閉じずにお待ちください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - 区間を作る

    private var editorView: some View {
        VStack(spacing: 0) {
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 210)
                    .background(Color.black)
            }

            playbackControls

            Divider()

            segmentList

            exportBar
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(timeText(currentTime))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                Spacer()
                Text(timeText(duration))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { seek(to: $0) }
                ),
                in: 0...max(1, duration)
            )

            // 12時間の動画ではスライダーだけでは合わせられないので、送り戻しを置く
            HStack(spacing: 8) {
                skipButton("-10分", seconds: -600)
                skipButton("-1分", seconds: -60)
                skipButton("-10秒", seconds: -10)
                skipButton("+10秒", seconds: 10)
                skipButton("+1分", seconds: 60)
                skipButton("+10分", seconds: 600)
            }

            HStack(spacing: 10) {
                Button {
                    pendingStart = currentTime
                } label: {
                    Label("ここから", systemImage: "flag")
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                Button {
                    addSegment()
                } label: {
                    Label("ここまで", systemImage: "flag.checkered")
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(pendingStart == nil ? Color.secondary.opacity(0.12) : Color.accentColor)
                        .foregroundStyle(pendingStart == nil ? Color.secondary : Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(pendingStart == nil || isExporting)
            }

            if let pendingStart {
                Text("開始: \(timeText(pendingStart)) — 終わりの位置で「ここまで」を押します")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func skipButton(_ title: String, seconds: Double) -> some View {
        Button {
            seek(to: currentTime + seconds)
        } label: {
            Text(title)
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var segmentList: some View {
        List {
            if segments.isEmpty {
                Text("まだ区間がありません。再生しながら「ここから」「ここまで」を押してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach($segments) { $segment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(timeText(segment.start)) 〜 \(timeText(segment.end))")
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                        Text("(\(durationText(segment.duration)))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if segment.isDone {
                            Label("完了", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    }

                    Menu {
                        ForEach(matches) { match in
                            Button(matchLabel(match)) {
                                segment.matchID = match.id
                            }
                        }
                        Divider()
                        Button("新しい試合を作る…") {
                            isCreateMatchPresented = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.right.circle")
                            Text(assignedLabel(for: segment))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(isExporting || segment.isDone)

                    if exportingIndex == segments.firstIndex(where: { $0.id == segment.id }) {
                        ProgressView(value: exportProgress)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                guard !isExporting else { return }
                segments.remove(atOffsets: offsets)
            }
        }
        .listStyle(.plain)
    }

    private var exportBar: some View {
        VStack(spacing: 8) {
            if finishedCount > 0 && !isExporting {
                Text("\(finishedCount)本を書き出して試合に紐づけました。")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }

            if importedSourceName != nil && !isExporting && finishedCount > 0 {
                Button("元の長い動画を端末から削除する") {
                    deleteImportedSource()
                }
                .font(.footnote)
                .foregroundStyle(.red)
            }

            Button {
                Task { await exportAll() }
            } label: {
                Text(
                    isExporting
                        ? "書き出し中… (\(finishedCount + 1)/\(assignedSegments.count + finishedCount))"
                        : "\(assignedSegments.count)本を書き出す"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(assignedSegments.isEmpty || isExporting ? Color.secondary.opacity(0.2) : Color.accentColor)
                .foregroundStyle(assignedSegments.isEmpty || isExporting ? Color.secondary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(assignedSegments.isEmpty || isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 区間の操作

    private func addSegment() {
        guard let start = pendingStart else { return }
        let end = currentTime
        guard end - start > 0.5 else {
            errorMessage = "区間が短すぎます。終わりの位置をもう少し後ろにしてください。"
            return
        }
        segments.append(SplitSegment(start: start, end: end))
        segments.sort { $0.start < $1.start }
        pendingStart = nil
    }

    private func assignedLabel(for segment: SplitSegment) -> String {
        guard let matchID = segment.matchID,
              let match = matches.first(where: { $0.id == matchID }) else {
            return "割り当て先の試合を選ぶ"
        }
        return matchLabel(match)
    }

    private func matchLabel(_ match: Match) -> String {
        let home = teams.first(where: { $0.id == match.homeTeamID })?.name ?? "未設定"
        let away = teams.first(where: { $0.id == match.awayTeamID })?.name ?? "未設定"
        let date = match.playedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        return "\(date) \(home) vs \(away)"
    }

    // MARK: - 再生

    private func seek(to seconds: Double) {
        let clamped = min(max(0, seconds), max(0, duration))
        currentTime = clamped
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func preparePlayer(url: URL) async {
        let asset = AVURLAsset(url: url)
        let loadedDuration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(loadedDuration)

        await MainActor.run {
            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            duration = seconds.isFinite && seconds > 0 ? seconds : 0
            player = newPlayer
            timeObserver = newPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                queue: .main
            ) { time in
                currentTime = CMTimeGetSeconds(time)
            }
        }
    }

    private func teardownPlayer() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        if isSecurityScoped, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
            isSecurityScoped = false
        }
    }

    private func close() {
        teardownPlayer()
        dismiss()
    }

    // MARK: - 取り込み

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "この動画を読み込む権限がありませんでした。"
                return
            }
            isSecurityScoped = true
            sourceURL = url
            Task { await preparePlayer(url: url) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func importFromPhotos(_ item: PhotosPickerItem) {
        isImportingSource = true
        importProgress = 0

        Task {
            do {
                guard let movie = try await item.loadTransferable(type: SplitImportedMovie.self),
                      let url = VideoStorage.url(named: movie.fileName) else {
                    throw NSError(
                        domain: "StreamSplit",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "動画を読み込めませんでした。"]
                    )
                }
                await preparePlayer(url: url)
                await MainActor.run {
                    importedSourceName = movie.fileName
                    sourceURL = url
                    isImportingSource = false
                    photoItem = nil
                }
            } catch {
                await MainActor.run {
                    isImportingSource = false
                    photoItem = nil
                    errorMessage = "動画を読み込めませんでした。空き容量を確認してもう一度試してください。"
                }
            }
        }
    }

    private func deleteImportedSource() {
        guard let importedSourceName else { return }
        teardownPlayer()
        VideoStorage.delete(named: importedSourceName)
        self.importedSourceName = nil
        sourceURL = nil
        segments = []
        finishedCount = 0
    }

    // MARK: - 書き出し

    private func exportAll() async {
        guard let sourceURL else { return }

        let targets = segments.enumerated().filter {
            $0.element.matchID != nil && !$0.element.isDone && $0.element.duration > 0.5
        }

        for (index, segment) in targets {
            await MainActor.run {
                exportingIndex = index
                exportProgress = 0
            }

            do {
                let exportedURL = try await exportRange(
                    from: sourceURL,
                    start: segment.start,
                    duration: segment.duration
                )
                defer { try? FileManager.default.removeItem(at: exportedURL) }
                let savedName = try await Task.detached(priority: .userInitiated) {
                    try VideoStorage.save(from: exportedURL)
                }.value

                if let matchID = segment.matchID {
                    VideoStorage.appendVideoNames([savedName], for: matchID)
                }

                await MainActor.run {
                    segments[index].isDone = true
                    finishedCount += 1
                }
            } catch {
                await MainActor.run {
                    exportingIndex = nil
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "書き出しに失敗しました。空き容量を確認してください。"
                }
                return
            }
        }

        await MainActor.run {
            exportingIndex = nil
            exportProgress = 0
        }
    }

    // 指定した区間を切り出して、一時ファイルのURLを返す。
    //
    // まず「作り直さずに切る」方式(パススルー)を試す。
    // 元の画質のまま、12時間の動画からでも数秒で終わるのが利点。
    // 対応できない動画のときだけ、作り直して切り出す方式に切り替える(時間がかかる)。
    private func exportRange(
        from url: URL,
        start: Double,
        duration: Double
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )

        for fileType in [AVFileType.mp4, AVFileType.mov] {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("split-\(UUID().uuidString).\(fileType == .mp4 ? "mp4" : "mov")")
            try? FileManager.default.removeItem(at: outputURL)

            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                break
            }
            session.outputURL = outputURL
            session.outputFileType = fileType
            session.timeRange = timeRange

            let progressTask = Task {
                while !Task.isCancelled {
                    let value = Double(session.progress)
                    await MainActor.run { exportProgress = value }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            progressTask.cancel()

            if session.status == .completed {
                return outputURL
            }
            try? FileManager.default.removeItem(at: outputURL)
        }

        // パススルーが使えなかった場合は、作り直して切り出す
        let piece = HighlightPiece(
            url: url,
            startSeconds: start,
            durationSeconds: duration
        )
        return try await HighlightExporter.export(
            pieces: [piece],
            fileName: "split-\(UUID().uuidString).mp4"
        ) { progress in
            exportProgress = progress
        }
    }

    // MARK: - 表示用

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0秒" }
        let total = Int(seconds)
        if total < 60 { return "\(total)秒" }
        return "\(total / 60)分\(total % 60)秒"
    }
}
