import SwiftUI
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

private struct MissingVideoSlot: Identifiable {
    let matchID: UUID
    let fileName: String
    var id: String { matchID.uuidString + fileName }
}

struct MediaTransferView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Match.playedAt, order: .reverse) private var matches: [Match]
    @Query private var teams: [Team]
    @AppStorage("backup.lastFileCreatedAt") private var lastFileCreatedAt = 0.0
    @State private var selectedSlot: MissingVideoSlot?
    @State private var importing = false
    @State private var working = false
    @State private var message: String?
    @State private var share: MediaTransferShare?
    @State private var revision = 0

    // 動画のある試合だけを見る(試合が2万あるので、全試合を1つずつ調べると重い)。並びは新しい試合から
    private var videoMatches: [(match: Match, names: [String])] {
        let map = VideoStorage.videoNamesByMatch
        guard !map.isEmpty else { return [] }
        return matches.compactMap { match in map[match.id].map { (match, $0) } }
    }
    private var missing: [MissingVideoSlot] {
        let _ = revision
        return videoMatches.flatMap { item in
            item.names.filter { !VideoStorage.isAvailable(named: $0) }
                .map { MissingVideoSlot(matchID: item.match.id, fileName: $0) }
        }
    }
    private var localURLs: [URL] {
        var seen = Set<String>()
        return videoMatches.flatMap(\.names)
            .filter { seen.insert($0).inserted }.compactMap { VideoStorage.url(named: $0) }
    }
    private func matchTitle(_ id: UUID) -> String {
        guard let match = matches.first(where: { $0.id == id }) else { return "試合" }
        let home = teams.first { $0.id == match.homeTeamID }?.name ?? "HOME"
        let away = teams.first { $0.id == match.awayTeamID }?.name ?? "AWAY"
        return match.playedAt.formatted(date: .numeric, time: .omitted) + " " + home + " vs " + away
    }

    var body: some View {
        List {
            Section {
                LabeledContent("端末にある動画", value: "\(localURLs.count)本")
                LabeledContent("再接続が必要", value: "\(missing.count)件")
                Button {
                    do {
                        let backup = try BackupManager.writeBackupFile(context: context)
                        share = MediaTransferShare(urls: [backup] + localURLs)
                        lastFileCreatedAt = Date().timeIntervalSince1970
                    } catch { message = error.localizedDescription }
                } label: { Label("記録＋端末にある動画を共有", systemImage: "square.and.arrow.up") }
            } header: { Text("別の端末へ持ち出す") } footer: {
                Text("共有先で「ファイルに保存」などを選び、JSONと動画を一緒に保管してください。端末にない動画は含まれません。YouTubeリンクと時刻合わせはJSONに含まれます。移行先では先にJSONを読み込み、下の一覧から同じ元動画を選びます。")
            }
            Section {
                if missing.isEmpty {
                    Label("未接続の動画はありません", systemImage: "checkmark.circle")
                }
                ForEach(missing) { slot in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(matchTitle(slot.matchID)).font(.headline)
                        Text(slot.fileName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("同じ元動画を選んで再接続") { selectedSlot = slot; importing = true }
                    }
                }
            } header: { Text("動画を再接続する") } footer: {
                Text("編集・短縮していない同じ動画を選んでください。元のファイル名で保存し、前後半の時刻合わせや各プレーの映像参照を引き継ぎます。すでにある動画は上書きしません。")
            }
            if working { ProgressView("動画を確認・コピーしています…") }
        }
        .disabled(working)
        .navigationTitle("動画を含めた移行").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie]) { result in
            guard let slot = selectedSlot else { return }
            selectedSlot = nil
            switch result {
            case .failure(let error): message = error.localizedDescription
            case .success(let url):
                working = true
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() }; working = false }
                    do {
                        let asset = AVURLAsset(url: url)
                        guard try await asset.load(.isPlayable) else { throw VideoStorageError.copyFailed }
                        try await Task.detached(priority: .userInitiated) {
                            try VideoStorage.recover(from: url, as: slot.fileName)
                        }.value
                        revision += 1
                        message = "動画を再接続しました。記録とキックオフの時刻合わせを引き継ぎました。"
                    } catch { message = "再接続できませんでした。元動画と空き容量を確認してください。\n" + error.localizedDescription }
                }
            }
        }
        .sheet(item: $share) { MediaTransferShareSheet(urls: $0.urls) }
        .alert("動画の移行", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }
}

private struct MediaTransferShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}
private struct MediaTransferShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
