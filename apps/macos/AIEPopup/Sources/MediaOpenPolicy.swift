import Foundation

enum MediaOpenPolicy {
    private static let extensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "avi",
        "mp3", "wav", "aac", "m4a", "flac",
    ]

    static func seekSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    static func shouldUseTimedPlayer(path: String, startSeconds: Double?) -> Bool {
        extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
            && seekSeconds(startSeconds) != nil
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        let value = Int(seconds)
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    static func rangeLabel(start: Double, end: Double?) -> String {
        if let end, end.isFinite, end > start {
            return "\(clock(start))–\(clock(end))"
        }
        return clock(start)
    }

    static func supportsExternalSeek(appID: String?) -> Bool {
        appID == "com.apple.QuickTimePlayerX" || appID == "com.colliderli.iina"
    }

    static func iinaURL(file: URL, seconds: Double) -> URL? {
        guard file.isFileURL, let seconds = seekSeconds(seconds) else { return nil }
        var link = URLComponents(string: "iina://open")
        link?.queryItems = [URLQueryItem(name: "url", value: file.absoluteString),
                           URLQueryItem(name: "mpv_start", value: String(seconds))]
        return link?.url
    }
}
