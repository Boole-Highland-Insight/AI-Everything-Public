import AppKit

/// The in-app player always keeps the evidence time. External seeking depends on the default player.
enum MediaExternalOpener {
    static func title(url: URL, seconds: Double) -> String {
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let name = app?.deletingPathExtension().lastPathComponent ?? "默认播放器"
        if MediaOpenPolicy.supportsExternalSeek(appID: app.flatMap { Bundle(url: $0)?.bundleIdentifier }) {
            return "用 \(name) 从 \(MediaOpenPolicy.clock(seconds)) 打开"
        }
        return "用 \(name) 打开原文件"
    }

    static func open(url: URL, seconds: Double, endSeconds: Double?) {
        guard FileManager.default.fileExists(atPath: url.path),
              let seconds = MediaOpenPolicy.seekSeconds(seconds) else {
            showFailure("文件已移动或无法读取。请在 Finder 中确认位置后重新搜索。")
            return
        }
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let appID = app.flatMap { Bundle(url: $0)?.bundleIdentifier }
        if appID == "com.colliderli.iina", let link = MediaOpenPolicy.iinaURL(file: url, seconds: seconds) {
            if !NSWorkspace.shared.open(link) { fallback(url: url, seconds: seconds, endSeconds: endSeconds) }
        } else if appID == "com.apple.QuickTimePlayerX" {
            openQuickTime(url: url, seconds: seconds, endSeconds: endSeconds)
        } else if !NSWorkspace.shared.open(url) {
            showFailure("默认播放器未能打开此文件。请在 Finder 中选择其他播放器。")
        }
    }

    private static func openQuickTime(url: URL, seconds: Double, endSeconds: Double?) {
        // Pass paths as argv; filenames must never become executable AppleScript.
        let script = """
        on run argv
            set targetFile to POSIX file (item 1 of argv)
            set targetTime to (item 2 of argv as integer) / 1000
            with timeout of 25 seconds
                tell application id "com.apple.QuickTimePlayerX"
                    activate
                    set targetDocument to open targetFile
                    if targetTime ≥ duration of targetDocument then error "The indexed time is beyond the recording"
                    set current time of targetDocument to targetTime
                    play targetDocument
                end tell
            end timeout
        end run
        """
        guard seconds < Double(Int.max) / 1000 else {
            fallback(url: url, seconds: seconds, endSeconds: endSeconds)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, url.path, String(Int(seconds * 1000))]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { task in
            guard task.terminationStatus != 0 else { return }
            DispatchQueue.main.async { fallback(url: url, seconds: seconds, endSeconds: endSeconds) }
        }
        do { try process.run() }
        catch { fallback(url: url, seconds: seconds, endSeconds: endSeconds) }
    }

    private static func fallback(url: URL, seconds: Double, endSeconds: Double?) {
        // Do not silently claim an external jump succeeded after automation was denied.
        let alert = NSAlert()
        alert.messageText = "播放器未能跳到命中位置"
        alert.informativeText = "可能未获得控制播放器的权限。你可以在 AI Everything 中从 \(MediaOpenPolicy.clock(seconds)) 播放，或打开原文件自行定位。"
        alert.addButton(withTitle: "在应用内播放")
        alert.addButton(withTitle: "打开原文件")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            MediaTimeWindow.shared.show(url: url, startSeconds: seconds, endSeconds: endSeconds)
        case .alertSecondButtonReturn:
            if !NSWorkspace.shared.open(url) { showFailure("无法打开原文件，请检查文件是否仍在原位置。") }
        default: break
        }
    }

    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法打开媒体文件"
        alert.informativeText = message
        alert.runModal()
    }
}
