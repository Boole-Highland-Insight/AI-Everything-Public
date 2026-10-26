import Foundation

/// Exercises the real scanner against explicitly supplied synthetic fixtures only.
enum DeepUnderstandingDiagnostics {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--verify-deep-control" else { return false }
        func isTemporaryFixture(_ path: String) -> Bool {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved.hasPrefix("/tmp/aie-deep-control-") || resolved.hasPrefix("/private/tmp/aie-deep-control-")
        }
        guard args.count == 4, ["pause", "disable", "resume", "reuse", "off"].contains(args[3]),
              let db = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"],
              isTemporaryFixture(db),
              isTemporaryFixture(args[2]) else {
            fputs("Requires isolated /tmp/aie-deep-control-* fixture and database.\n", stderr); exit(2)
        }
        let mode = args[3]
        let defaults = UserDefaults.standard
        let keys = [ScanConfiguration.planKey, ScanConfiguration.pendingKey, ScanConfiguration.deepPausedKey, "aie.scan.userPaused"]
        let saved = keys.map { defaults.object(forKey: $0) }
        func restore() {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        ScanConfiguration.setBackgroundUnderstanding(mode != "off")
        ScanControl.shared.setPaused(false)
        let root = URL(fileURLWithPath: args[2])
        let files = LibraryGateway.load(roots: [root])
        guard !files.isEmpty, files.count <= 3, LibraryGateway.lastError == nil else { restore(); exit(2) }
        func completed() -> Int {
            LibraryGateway.load(roots: [root]).filter {
                let deep = ScanRecords.read($0)?["deepScan"] as? [String: Any]
                return !(deep?["blurb_zh"] as? String ?? "").isEmpty
            }.count
        }
        let before = completed()
        let started = ProcessInfo.processInfo.systemUptime
        var requested = false
        var stopping = false
        QuickScanner.enqueueMissing(files: files) {}
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if !requested, (mode == "pause" || mode == "disable"),
               ScanProgress.shared.currentFile != nil, ScanControl.shared.isHeavyModelActive {
                requested = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if mode == "pause" { ScanConfiguration.pauseBackgroundUnderstanding(true) }
                    else { ScanConfiguration.setBackgroundUnderstanding(false) }
                    stopping = true
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed > 420 { restore(); fputs("Deep control timeout\n", stderr); exit(1) }
            guard !QuickScanner.isBusy, (!(mode == "pause" || mode == "disable") || stopping) else { return }
            let after = completed()
            let valid: Bool
            switch mode {
            case "pause": valid = after == before + 1 && after < files.count && defaults.bool(forKey: ScanConfiguration.deepPausedKey)
            case "disable": valid = after <= before + 1 && !ScanConfiguration.backgroundUnderstandingEnabled()
            case "off": valid = after == before
            default: valid = after == files.count
            }
            let report: [String: Any] = ["passed": valid, "mode": mode, "before": before, "after": after,
                "files": files.count, "seconds": elapsed, "llm_failed": ScanProgress.shared.llmFailed,
                "semantic_enabled": ScanConfiguration.semanticEnabled(), "paused": defaults.bool(forKey: ScanConfiguration.deepPausedKey)]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            restore()
            exit(valid ? 0 : 1)
        }
        withExtendedLifetime(timer) { RunLoop.current.run() }
        return true
    }
}
