import Foundation

/// User-requested deferrals affect automatic scans only, not file search or explicit transcription.
enum ScanPolicy {
    static func isDeferred(_ file: IndexedFile) -> Bool {
        let paths = (try? AppDatabase.open().preferencePaths("deferred")) ?? []
        return paths.contains(file.path)
    }
    static func setDeferred(_ path: String, deferred: Bool) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        do { try AppDatabase.open().setPreference(path: path, name: "deferred", value: deferred) }
        catch { AppDatabase.failed(error) }
    }
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let command = args.dropFirst().first, ["--defer-scan", "--resume-scan"].contains(command) else { return false }
        guard args.count == 3, args[2].hasPrefix("/") else {
            fputs("usage: AIEPopup --defer-scan|--resume-scan /absolute/file/path\n", stderr); exit(2)
        }
        setDeferred(args[2], deferred: command == "--defer-scan")
        // SQLite commits before returning; this command never starts a scanner.
        if AppDatabase.lastError != nil { fputs("Unable to save scan preference\n", stderr); exit(1) }
        print(command == "--defer-scan" ? "Automatic scanning deferred for the file." : "Automatic scanning re-enabled for the file.")
        return true
    }
}
