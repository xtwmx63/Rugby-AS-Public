import SwiftUI

/// Links stay with the match; video bytes are streamed by YouTube's own player.
struct YouTubeLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var showValidation = false
    let onAdd: (YouTubeVideoLink) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.youtube.com/watch?v=…", text: $linkText, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("youtubeLinkField")
                    if showValidation {
                        Text("YouTubeの動画リンクを確認してください。共有ボタンからコピーしたリンクも使えます。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("YouTubeの動画リンク")
                } footer: {
                    Text("リンクを保存して、アプリ内で動画を見ながらプレーを分析できます。再生にはインターネット接続が必要です。")
                }
                Section {
                    Text("追加後、動画編集の「キックオフ」で前半・後半の開始位置を合わせると、タイムラインの動画ボタンからその場面へ移動できます。リンクの開始時刻はキックオフとして自動設定されません。")
                        .font(.footnote)
                }
            }
            .navigationTitle("YouTubeリンクを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        guard let link = YouTubeVideoLink(urlString: linkText) else {
                            showValidation = true
                            return
                        }
                        onAdd(link)
                        dismiss()
                    }
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
