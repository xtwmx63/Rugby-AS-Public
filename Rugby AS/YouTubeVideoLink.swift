import Foundation

/// A YouTube source uses the same stable identifier as local video references, so
/// kickoff anchors and backups can keep using the existing match video schema.
struct YouTubeVideoLink: Equatable, Sendable {
    nonisolated let videoID: String
    nonisolated let startSeconds: Double

    nonisolated var sourceName: String { "youtube-" + videoID }

    nonisolated init?(urlString: String) {
        let input = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.utf8.count <= 4096,
              !input.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let absolute = input.contains("://") ? input : "https://" + input
        guard let components = URLComponents(string: absolute),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.port == nil
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let path = Array(parts.last == "" ? parts.dropLast() : parts)
        let query = components.queryItems ?? []
        let identifier: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            identifier = path.count == 1 ? String(path[0]) : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if path == ["watch"] {
                let videos = query.filter { $0.name == "v" }
                identifier = videos.count == 1 ? videos[0].value : nil
            } else if path.count == 2, ["embed", "live", "shorts"].contains(String(path[0])) {
                identifier = String(path[1])
            } else {
                identifier = nil
            }
        case "youtube-nocookie.com", "www.youtube-nocookie.com":
            identifier = path.count == 2 && path[0] == "embed" ? String(path[1]) : nil
        default:
            return nil
        }
        guard let identifier, Self.isValidVideoID(identifier) else { return nil }

        var timestamp: String?
        for name in ["t", "start"] {
            let items = query.filter { $0.name == name }
            guard items.count <= 1 else { return nil }
            if let item = items.first, timestamp == nil {
                guard let value = item.value else { return nil }
                timestamp = value
            }
        }
        if timestamp == nil, let fragment = components.fragment, !fragment.isEmpty {
            let fragmentItems = URLComponents(string: "https://youtube.com/?" + fragment)?.queryItems ?? []
            for name in ["t", "start"] {
                let items = fragmentItems.filter { $0.name == name }
                guard items.count <= 1 else { return nil }
                if let item = items.first, timestamp == nil {
                    guard let value = item.value else { return nil }
                    timestamp = value
                }
            }
            // Older YouTube links also used a bare time fragment, e.g. #1m30s.
            if timestamp == nil, fragment.first?.isNumber == true { timestamp = fragment }
        }
        let start: Double
        if let timestamp {
            guard let seconds = Self.parseTime(timestamp) else { return nil }
            start = seconds
        } else {
            start = 0
        }
        videoID = identifier
        startSeconds = start
    }

    nonisolated static func videoID(forSourceName sourceName: String) -> String? {
        guard sourceName.hasPrefix("youtube-") else { return nil }
        let identifier = String(sourceName.dropFirst("youtube-".count))
        return isValidVideoID(identifier) ? identifier : nil
    }

    nonisolated static func watchURL(videoID: String, at seconds: Double) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        let position = seconds.isFinite ? min(max(0, seconds), maximumSeconds) : 0
        components.queryItems = [.init(name: "v", value: videoID), .init(name: "t", value: String(Int(position)) + "s")]
        return components.url!
    }

    /// Only a convenience for the next visit; the source and timing anchors are
    /// persisted separately and work without this optional cache after restore.
    nonisolated static func cachedDuration(videoID: String) -> Double? {
        guard isValidVideoID(videoID) else { return nil }
        let seconds = UserDefaults.standard.double(forKey: durationKey(videoID))
        return seconds.isFinite && seconds > 0 && seconds <= maximumSeconds ? seconds : nil
    }

    nonisolated static func cacheDuration(_ seconds: Double, videoID: String) {
        guard isValidVideoID(videoID), seconds.isFinite, seconds > 0, seconds <= maximumSeconds else { return }
        UserDefaults.standard.set(seconds, forKey: durationKey(videoID))
    }

    nonisolated private static let maximumSeconds = 2_147_483_647.0

    nonisolated private static func durationKey(_ videoID: String) -> String { "youtube.duration." + videoID }

    nonisolated private static func isValidVideoID(_ identifier: String) -> Bool {
        identifier.utf8.count == 11 && identifier.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    nonisolated private static func parseTime(_ value: String) -> Double? {
        let value = value.lowercased()
        if value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
           let seconds = Double(value), seconds.isFinite, seconds <= maximumSeconds { return seconds }
        guard !value.isEmpty,
              value.range(of: #"^(?:[0-9]+h)?(?:[0-9]+m)?(?:[0-9]+(?:\.[0-9]+)?s)?$"#, options: .regularExpression) != nil
        else { return nil }
        var number = ""
        var seconds = 0.0
        for character in value {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let amount = Double(number) else { return nil }
                seconds += amount * (character == "h" ? 3600 : character == "m" ? 60 : 1)
                number = ""
            }
        }
        return seconds.isFinite && seconds <= maximumSeconds ? seconds : nil
    }
}
