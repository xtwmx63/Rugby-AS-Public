import Foundation

enum YouTubeRegressionChecks {
    private enum Failure: Error { case failed(String) }
    private static let videoID = "AbC_12-xyZ9"
    private static var sourceName: String { "youtube-" + videoID }

    static func run() throws {
        try acceptsSupportedLinks()
        try parsesTimestampFormats()
        try rejectsInvalidLinks()
        try preservesSourceIdentityAndSafeWatchURLs()
        try removesLinksWithoutLosingMissingLocalVideos()
        try mapsYouTubeAnchorsThroughTheMatchClock()
        try retainsOnlyValidCachedDurations()
        print("PASS: 7 YouTube regression checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }

    private static func acceptsSupportedLinks() throws {
        for url in [
            "https://www.youtube.com/watch?v=\(videoID)&si=shared",
            "https://youtube.com/watch?v=\(videoID)",
            "http://m.youtube.com/watch?v=\(videoID)",
            "https://music.youtube.com/watch?v=\(videoID)",
            "https://youtu.be/\(videoID)?si=shared",
            "https://www.youtube.com/embed/\(videoID)",
            "https://www.youtube-nocookie.com/embed/\(videoID)",
            "https://youtube-nocookie.com/embed/\(videoID)",
            "https://youtube.com/live/\(videoID)",
            "https://youtube.com/shorts/\(videoID)/",
            "  youtu.be/\(videoID)\n"
        ] {
            let link = YouTubeVideoLink(urlString: url)
            try expect(link?.videoID == videoID && link?.sourceName == sourceName && link?.startSeconds == 0,
                       "Supported YouTube link must retain its exact case-sensitive identifier: \(url)")
        }
    }

    private static func parsesTimestampFormats() throws {
        for (suffix, seconds) in [
            ("?t=93", 93.0), ("?t=93s", 93), ("?t=1m33s", 93),
            ("?start=1h2m3s", 3723), ("?t=1h", 3600), ("?start=12.5", 12.5),
            ("#t=2m", 120), ("#start=23s", 23), ("#1m30s", 90),
            ("?t=12&start=99#t=33", 12), ("?si=shared#t=35", 35), ("?t=0", 0)
        ] {
            try expect(YouTubeVideoLink(urlString: "https://youtu.be/\(videoID)" + suffix)?.startSeconds == seconds,
                       "Timestamp must parse to seconds, preferring query t: \(suffix)")
        }
    }

    private static func rejectsInvalidLinks() throws {
        for url in [
            "", "\(videoID)", "javascript:alert(1)",
            "https://notyoutube.com/watch?v=\(videoID)",
            "https://youtube.com.evil.example/watch?v=\(videoID)",
            "https://youtube.com@evil.example/watch?v=\(videoID)",
            "https://evil.example@youtube.com/watch?v=\(videoID)",
            "https://youtube.com:444/watch?v=\(videoID)",
            "ftp://youtube.com/watch?v=\(videoID)",
            "https://youtube.com/redirect?v=\(videoID)",
            "https://youtube.com/watch?v=tooShort",
            "https://youtube.com/watch?v=\(videoID)&v=Other_Id123",
            "https://youtube.com/watch?v=日本語の動画ID0000",
            "https://youtube.com/watch?v=AbC_12-xyZ!",
            "https://youtu.be/\(videoID)/extra",
            "https://youtube-nocookie.com/watch?v=\(videoID)",
            "https://youtu.be/\(videoID) extra",
            "https://youtu.be/\(videoID)?t=-3", "https://youtu.be/\(videoID)?t=NaN",
            "https://youtu.be/\(videoID)?t=1e5", "https://youtu.be/\(videoID)?t=1m2h",
            "https://youtu.be/\(videoID)?t=", "https://youtu.be/\(videoID)?t=999999999999h",
            "https://youtu.be/\(videoID)?t=5&t=6", "https://youtu.be/\(videoID)#t=invalid"
        ] {
            try expect(YouTubeVideoLink(urlString: url) == nil, "Invalid or unrelated URLs must not become playable sources: \(url)")
        }
    }

    private static func preservesSourceIdentityAndSafeWatchURLs() throws {
        try expect(VideoStorage.isSafeFileName(sourceName), "YouTube references must fit the existing backup filename validation")
        try expect(YouTubeVideoLink.videoID(forSourceName: sourceName) == videoID, "Source identity must round-trip")
        for name in [videoID, "youtube-", sourceName + ".mov", "../" + sourceName] {
            try expect(YouTubeVideoLink.videoID(forSourceName: name) == nil, "Local names and malformed references are not YouTube sources")
        }
        let link = YouTubeVideoLink(urlString: YouTubeVideoLink.watchURL(videoID: videoID, at: 89.75).absoluteString)
        try expect(link?.videoID == videoID && link?.startSeconds == 89, "External player link must use the requested source position")
        for seconds in [Double.nan, .infinity, -1] {
            try expect(YouTubeVideoLink(urlString: YouTubeVideoLink.watchURL(videoID: videoID, at: seconds).absoluteString)?.startSeconds == 0,
                       "Malformed seek positions must produce a safe watch URL")
        }
    }

    private static func removesLinksWithoutLosingMissingLocalVideos() throws {
        let key = "matchVideoFileNamesByMatchID"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let matchID = UUID(), legacyMatchID = UUID()
        UserDefaults.standard.set([legacyMatchID.uuidString: "legacy.mov"], forKey: key)
        try expect(VideoStorage.videoNames(for: legacyMatchID) == ["legacy.mov"], "Pre-array local video mappings remain readable")
        VideoStorage.setVideoNames(["missing.mov", sourceName, "second.mov"], for: matchID)
        try expect(VideoStorage.isAvailable(named: sourceName) && VideoStorage.url(named: sourceName) == nil,
                   "YouTube is available for playback but never a local media file")
        let kept = VideoStorage.preservingMissingNames(edited: ["second.mov"], stored: VideoStorage.videoNames(for: matchID), exists: { $0 == "second.mov" })
        try expect(kept == ["missing.mov", "second.mov"], "Explicitly removed links must not return as missing files; missing local slots must remain")
        VideoStorage.removeVideoName(sourceName, for: matchID)
        try expect(VideoStorage.videoNames(for: matchID) == ["missing.mov", "second.mov"], "Removing one link must retain local video order")
        VideoStorage.setVideoNames([sourceName], for: matchID)
        VideoStorage.deleteVideos(for: matchID)
        try expect(VideoStorage.videoNames(for: matchID).isEmpty && VideoStorage.videoNames(for: legacyMatchID) == ["legacy.mov"],
                   "Deleting a linked match clears its references without touching other matches")
    }

    private static func mapsYouTubeAnchorsThroughTheMatchClock() throws {
        let second = "youtube-Zyx_98-AbC1"
        let settings = MatchClockSettings(firstHalfSeconds: 420, secondHalfSeconds: 420,
            stoppages: [.init(half: 0, clockSecond: 60, durationSeconds: 20)], halfTimeSeconds: 180)
        let clock = MatchVideoClock(settings: settings, videoNames: [sourceName, second],
            anchors: [0: .init(fileName: sourceName, seconds: 100), 1: .init(fileName: second, seconds: 900)])
        let firstPlay = clock.videoPosition(half: 0, seconds: 120)
        let secondPlay = clock.videoPosition(half: 1, seconds: 120)
        try expect(firstPlay?.fileName == sourceName && firstPlay?.at == 240, "First-half YouTube seek includes kickoff and stopped time")
        try expect(secondPlay?.fileName == second && secondPlay?.at == 1020, "Second-half seek uses that half's YouTube source and kickoff")
        let timeline = MatchVideoTimeline(clock: clock, videos: [
            .init(fileName: sourceName, start: 0, end: 600), .init(fileName: second, start: 612, end: 2412)
        ])
        try expect(timeline.position(half: 1, seconds: 120) == 1632, "YouTube scene follows the same timeline source-offset mapping as local video")
        let restored = timeline.time(at: 1632)
        try expect(restored?.half == 1 && restored?.seconds == 120, "YouTube positions round-trip to the recorded match clock")
    }

    private static func retainsOnlyValidCachedDurations() throws {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(11))
        let key = "youtube.duration." + id
        defer { UserDefaults.standard.removeObject(forKey: key) }
        try expect(YouTubeVideoLink.cachedDuration(videoID: id) == nil, "Missing cache must stay optional after a backup restore")
        YouTubeVideoLink.cacheDuration(7512.5, videoID: id)
        for seconds in [Double.nan, .infinity, 0, -1] { YouTubeVideoLink.cacheDuration(seconds, videoID: id) }
        try expect(YouTubeVideoLink.cachedDuration(videoID: id) == 7512.5, "Invalid player updates must not replace a known duration")
    }
}
