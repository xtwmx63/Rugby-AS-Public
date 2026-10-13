import SwiftUI
import Combine
import WebKit

/// YouTube の秒数だけを扱う。試合時計への変換は呼び出し側の MatchVideoTimeline で行う。
@MainActor
final class YouTubePlayerController: ObservableObject {
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoID: String?

    var onTimeChange: ((Double) -> Void)?
    var onDurationChange: ((Double) -> Void)?
    var onPlaybackChange: ((Bool) -> Void)?
    var onEnded: (() -> Void)?

    private weak var webView: WKWebView?
    private var pageNavigation: WKNavigation?
    private var pageID = UUID().uuidString
    private var isReady = false
    private var pendingSeconds: Double = 0
    private var wantsPlayback = false
    private var commandID = 0
    private var loadingTimeout: Task<Void, Never>?

    func load(videoID: String, startSeconds: Double = 0, autoplay: Bool = false) {
        guard videoID.count == 11,
              videoID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            stop()
            errorMessage = "YouTubeリンクを確認してください。"
            return
        }
        let changed = self.videoID != videoID
        let needsReload = changed || errorMessage != nil
        self.videoID = videoID
        pendingSeconds = boundedSeconds(startSeconds, useDuration: !changed)
        wantsPlayback = autoplay
        setTime(pendingSeconds)
        if changed {
            duration = 0
            onDurationChange?(0)
        }
        errorMessage = nil
        if needsReload {
            loadPage()
        } else if isReady {
            sendCommand("seek")
        }
    }

    /// 読み込み中でも最後に選んだ位置と再生指示を保持する。
    func seek(to seconds: Double, autoplay: Bool) {
        guard videoID != nil else { return }
        pendingSeconds = boundedSeconds(seconds)
        wantsPlayback = autoplay
        setTime(pendingSeconds)
        if isReady { sendCommand("seek") }
    }

    func play() {
        guard videoID != nil else { return }
        wantsPlayback = true
        if isReady { sendCommand("play") }
    }

    func pause() {
        wantsPlayback = false
        if isReady { sendCommand("pause") }
        setPlaying(false)
    }

    func stop() {
        loadingTimeout?.cancel()
        loadingTimeout = nil
        pageID = UUID().uuidString
        pageNavigation = nil
        isReady = false
        videoID = nil
        wantsPlayback = false
        pendingSeconds = 0
        errorMessage = nil
        setPlaying(false)
        setTime(0)
        duration = 0
        onDurationChange?(0)
        onTimeChange = nil
        onDurationChange = nil
        onPlaybackChange = nil
        onEnded = nil
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body style='background:black'></body></html>", baseURL: nil)
    }

    func retry() {
        guard videoID != nil else { return }
        errorMessage = nil
        pendingSeconds = currentSeconds
        loadPage()
    }

    var externalPlaybackURL: URL? {
        guard let videoID else { return nil }
        var parts = URLComponents(string: "https://www.youtube.com/watch")
        parts?.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "t", value: String(Int(currentSeconds.rounded(.down))))
        ]
        return parts?.url
    }

    fileprivate func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        if videoID != nil { loadPage() }
    }

    fileprivate func detach(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        loadingTimeout?.cancel()
        loadingTimeout = nil
        pageID = UUID().uuidString
        pageNavigation = nil
        isReady = false
        pendingSeconds = currentSeconds
        wantsPlayback = false
        self.webView = nil
        // UIViewRepresentable の破棄中に SwiftUI の状態を同期変更しない。
        Task { @MainActor [weak self] in
            guard let self, self.webView == nil else { return }
            self.setPlaying(false)
        }
    }

    private func boundedSeconds(_ seconds: Double, useDuration: Bool = true) -> Double {
        guard seconds.isFinite else { return 0 }
        // Int 変換と JavaScript への安全な受け渡しも兼ねる。
        let value = min(max(0, seconds), 315_360_000)
        return useDuration && duration > 0 ? min(value, duration) : value
    }

    private func loadPage() {
        loadingTimeout?.cancel()
        isReady = false
        pageID = UUID().uuidString
        commandID = 0
        setPlaying(false)
        guard let webView, let videoID else { return }
        // YouTube 公式のモバイル埋め込み仕様に従い、アプリ自身の Bundle ID を使う。
        // https://developers.google.com/youtube/terms/required-minimum-functionality#embedded-player-api-client-identity
        guard let bundleID = Bundle.main.bundleIdentifier?.lowercased(),
              let baseURL = URL(string: "https://\(bundleID)"),
              let configuration = json([
                "videoID": videoID, "pageID": pageID, "origin": baseURL.absoluteString
              ]) else {
            errorMessage = "YouTubeプレーヤーを準備できませんでした。"
            return
        }
        pageNavigation = webView.loadHTMLString(Self.html(configuration: configuration), baseURL: baseURL)
        let expectedPageID = pageID
        loadingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self,
                  self.pageID == expectedPageID, !self.isReady else { return }
            self.errorMessage = "YouTubeを読み込めませんでした。通信環境を確認して、再読み込みしてください。"
        }
    }

    private func sendCommand(_ action: String) {
        guard isReady, let webView, let videoID else { return }
        commandID += 1
        guard let payload = json([
            "action": action, "videoID": videoID, "seconds": pendingSeconds,
            "autoplay": wantsPlayback, "commandID": commandID, "pageID": pageID
        ]) else { return }
        let expectedPageID = pageID
        webView.evaluateJavaScript("window.rugbyYouTubeCommand(\(payload));") { [weak self, weak webView] _, error in
            guard let self, self.webView === webView, self.pageID == expectedPageID,
                  error != nil else { return }
            self.errorMessage = "YouTubeの操作に失敗しました。再読み込みしてください。"
            self.setPlaying(false)
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let data = message.body as? [String: Any],
              data["pageID"] as? String == pageID,
              let event = data["event"] as? String else { return }
        if event == "ready" {
            loadingTimeout?.cancel()
            loadingTimeout = nil
            isReady = true
            errorMessage = nil
            sendCommand("load")
            return
        }
        if event == "failure" {
            errorMessage = "YouTubeを読み込めませんでした。通信環境を確認して、再読み込みしてください。"
            setPlaying(false)
            return
        }
        guard (data["commandID"] as? Int ?? 0) >= commandID else { return }
        switch event {
        case "time":
            if let seconds = data["seconds"] as? Double, seconds.isFinite {
                pendingSeconds = boundedSeconds(seconds)
                setTime(pendingSeconds)
            }
            if let value = data["duration"] as? Double, value.isFinite, value > 0, value != duration {
                duration = value
                onDurationChange?(value)
            }
        case "state":
            let state = data["state"] as? Int ?? -1
            setPlaying(state == 1)
            if state == 1 {
                wantsPlayback = true
                errorMessage = nil
            } else if state == 2 || state == 0 {
                wantsPlayback = false
            }
            if state == 0 { onEnded?() }
        case "error":
            setPlaying(false)
            switch data["code"] as? Int {
            case 100:
                errorMessage = "動画が削除されたか、非公開になっています。"
            case 101, 150:
                errorMessage = "この動画はアプリ内での再生が許可されていません。YouTubeで開いてください。"
            case 153:
                errorMessage = "YouTubeがアプリ内での再生を確認できませんでした。再読み込みするか、YouTubeで開いてください。"
            default:
                errorMessage = "YouTube動画を再生できませんでした。再読み込みするか、YouTubeで開いてください。"
            }
        case "autoplayBlocked":
            wantsPlayback = false
            setPlaying(false)
            errorMessage = "動画内の再生ボタンを押すと、選んだ位置から再生できます。"
        default:
            break
        }
    }

    fileprivate func navigationFailed(in webView: WKWebView, navigation: WKNavigation? = nil) {
        guard self.webView === webView else { return }
        if let navigation, navigation !== pageNavigation { return }
        guard videoID != nil else { return }
        loadingTimeout?.cancel()
        isReady = false
        setPlaying(false)
        errorMessage = "YouTubeを読み込めませんでした。通信環境を確認して、再読み込みしてください。"
    }

    private func setTime(_ seconds: Double) {
        currentSeconds = seconds
        onTimeChange?(seconds)
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        onPlaybackChange?(playing)
    }

    private func json(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func html(configuration: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000}body{overflow:hidden}iframe{border:0}</style>
        </head><body><div id="player"></div><script>
        const config = \(configuration);
        let player, ready = false, commandID = 0, interval, seekingTo = null, seekDeadline = 0;
        function send(event, values = {}) {
            window.webkit.messageHandlers.rugbyYouTube.postMessage(
                Object.assign({event, pageID: config.pageID, commandID}, values));
        }
        function sample() {
            if (!ready || !player || !player.getCurrentTime) return;
            let seconds = player.getCurrentTime();
            if (seekingTo !== null) {
                const state = player.getPlayerState();
                if (Math.abs(seconds - seekingTo) > 1.5 &&
                    (Date.now() < seekDeadline || state === -1 || state === 5)) {
                    seconds = seekingTo;
                } else seekingTo = null;
            }
            send('time', {seconds, duration: player.getDuration()});
        }
        window.rugbyYouTubeCommand = function(command) {
            if (!ready || command.pageID !== config.pageID) return;
            commandID = command.commandID;
            if (command.action === 'load' || command.action === 'seek') {
                seekingTo = command.seconds;
                seekDeadline = Date.now() + 5000;
                if (command.action === 'load') {
                    const video = {videoId: command.videoID, startSeconds: command.seconds};
                    if (command.autoplay) player.loadVideoById(video);
                    else player.cueVideoById(video);
                } else {
                    player.seekTo(command.seconds, true);
                    if (command.autoplay) player.playVideo();
                    else player.pauseVideo();
                }
            } else if (command.action === 'play') player.playVideo();
            else if (command.action === 'pause') player.pauseVideo();
        };
        window.onYouTubeIframeAPIReady = function() {
            player = new YT.Player('player', {
                width: '100%', height: '100%', videoId: config.videoID,
                playerVars: {playsinline: 1, controls: 1, autoplay: 0, origin: config.origin, hl: 'ja'},
                events: {
                    onReady: function() {
                        ready = true;
                        const frame = player.getIframe();
                        frame.setAttribute('allow', 'autoplay; encrypted-media; picture-in-picture; fullscreen');
                        send('ready');
                        interval = setInterval(sample, 250);
                    },
                    onStateChange: function(event) { sample(); send('state', {state: event.data}); },
                    onError: function(event) { send('error', {code: event.data}); },
                    onAutoplayBlocked: function() { send('autoplayBlocked'); }
                }
            });
        };
        window.addEventListener('pagehide', function() {
            clearInterval(interval);
            if (player && player.destroy) player.destroy();
        });
        const script = document.createElement('script');
        script.src = 'https://www.youtube.com/iframe_api';
        script.onerror = function() { send('failure'); };
        document.head.appendChild(script);
        </script></body></html>
        """
    }
}

/// プレーヤーの上に独自の操作や案内を重ねず、YouTube 標準の操作をそのまま使う。
struct YouTubePlayerView: View {
    @ObservedObject var controller: YouTubePlayerController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            YouTubeWebView(controller: controller)
                .frame(minWidth: 200, minHeight: 200)
            if let message = controller.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.caption)
                    HStack(spacing: 20) {
                        Button("再読み込み") { controller.retry() }
                        if let url = controller.externalPlaybackURL {
                            Link(destination: url) {
                                Label("YouTubeで開く", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.pause() }
        }
    }
}

private struct YouTubeWebView: UIViewRepresentable {
    let controller: YouTubePlayerController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "rugbyYouTube")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.controller?.detach(uiView)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "rugbyYouTube")
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var controller: YouTubePlayerController?

        init(controller: YouTubePlayerController) { self.controller = controller }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            controller?.receive(message)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            controller?.navigationFailed(in: webView, navigation: navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            controller?.navigationFailed(in: webView, navigation: navigation)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            controller?.navigationFailed(in: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
