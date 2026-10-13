import SafariServices
import SwiftUI

/// 公式記録から取り込んだ試合の、公式の試合ページと公式記録表へのリンク。
/// アプリ内のブラウザ(Safari の画面)で開くので、見終わったら閉じれば試合詳細に戻れる。
/// 開けるのは公式記録のサイト(日本ラグビーフットボール協会・リーグワン・トップリーグ・SVNS・World Rugby)だけ。
struct OfficialMatchLinks: View {
    let pageURL: String?
    let sheetURL: String?
    @State private var opened: OfficialLink?

    private var links: [OfficialLink] {
        [OfficialLink(pageURL, title: "公式試合記録", symbol: "safari"),
         OfficialLink(sheetURL, title: "公式記録表", symbol: "doc.text")].compactMap { $0 }
    }

    var body: some View {
        if !links.isEmpty {
            HStack(spacing: 8) {
                ForEach(links) { link in
                    Button { opened = link } label: {
                        HStack(spacing: 6) {
                            Image(systemName: link.symbol)
                            Text(link.title).lineLimit(1).minimumScaleFactor(0.8)
                            Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RugbyTheme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RugbyTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(RugbyTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("公式サイトをアプリ内で開きます")
                }
            }
            // iPad でもシートの小さな枠にせず、画面いっぱいに開く。閉じるのは Safari の「完了」
            .fullScreenCover(item: $opened) { link in
                OfficialLinkBrowser(url: link.url) { opened = nil }.ignoresSafeArea()
            }
        }
    }
}

private struct OfficialLink: Identifiable {
    let url: URL
    let title: String
    let symbol: String
    var id: String { url.absoluteString }

    init?(_ raw: String?, title: String, symbol: String) {
        guard let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host == "rugby-japan.jp" || host.hasSuffix(".rugby-japan.jp")
                || host == "league-one.jp" || host.hasSuffix(".league-one.jp")
                || host == "top-league.jp" || host.hasSuffix(".top-league.jp")
                || host == "svns.com" || host.hasSuffix(".svns.com")
                || host == "rugbyworldcup.com" || host.hasSuffix(".rugbyworldcup.com")
                || host == "world.rugby" || host.hasSuffix(".world.rugby") else { return nil }
        self.url = url
        self.title = title
        self.symbol = symbol
    }
}

struct OfficialLinkBrowser: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    /// 「完了」を押したら画面を閉じる(全画面表示は自分で閉じる必要がある)
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onDone() }
    }
}
