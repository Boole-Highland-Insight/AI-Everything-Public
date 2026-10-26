import Foundation

/// Debug logs are opt-in because API responses may contain file-derived text.
enum AppLog {
    private static let lock = NSLock()

    static func write(_ line: String, channel: String = "app") {
        guard ProcessInfo.processInfo.environment["AIE_DEBUG_LOGS"] == "1" else { return }
        lock.lock()
        defer { lock.unlock() }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(AIEApplicationPaths.isCleanBaseline ? "Library/Logs/AIE Clean Baseline" : "Library/Logs/AI Everything", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("\(channel).log")
            let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // Diagnostics must never prevent the app from opening.
        }
    }
}
