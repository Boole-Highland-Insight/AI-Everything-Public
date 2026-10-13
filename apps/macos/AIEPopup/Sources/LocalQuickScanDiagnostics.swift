import Foundation

/// Opt-in integration check against the installed model, an explicit fixture root and isolated DB.
/// Cloud scanning must be disabled; this does not load the user's selected library or UI.
enum LocalQuickScanDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        let command = args.dropFirst().first
        guard command == "--verify-local-quickscan" || command == "--evaluate-local-quickscan" else { return false }
        let isEvaluation = command == "--evaluate-local-quickscan"
        guard args.count == 4, args[3] == "--local-scan-only",
              let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"], !path.isEmpty,
              !FileManager.default.fileExists(atPath: path), LocalQuickScan.isInstalled else {
            fputs("Requires installed local model and new test database. Usage: AIE_DATABASE_PATH=/tmp/new.sqlite AIEPopup --evaluate-local-quickscan /test-fixtures --local-scan-only\n", stderr)
            exit(2)
        }
        var isDirectory: ObjCBool = false
        let target = URL(fileURLWithPath: args[2])
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            fputs("Fixture path does not exist\n", stderr); exit(2)
        }
        let root = isDirectory.boolValue ? target : target.deletingLastPathComponent()
        let selectedPath = isDirectory.boolValue ? nil : target.path
        func selected(_ items: [IndexedFile]) -> [IndexedFile] {
            selectedPath.map { path in items.filter { $0.path == path } } ?? items
        }
        let files = selected(LibraryGateway.load(roots: [root]))
        let maximumFileCount = isEvaluation ? 100 : 4
        guard LibraryGateway.lastError == nil, !files.isEmpty, files.count <= maximumFileCount else {
            fputs("Expected 1–\(maximumFileCount) test files and a healthy test database\n", stderr); exit(2)
        }
        let start = Date()
        QuickScanner.enqueueMissing(files: files) {
            guard !QuickScanner.isBusy else { return }
            let indexed = selected(LibraryGateway.load(roots: [root]))
            let classified = JunkClassifier.classify(indexed)
            let predictionByPath = Dictionary(uniqueKeysWithValues: classified.map { ($0.path, $0.bin.rawValue) })
            var valid = indexed.count == files.count && LibraryGateway.lastError == nil
            let results: [[String: Any]] = indexed.map { file in
                let record = ScanRecords.read(file) ?? [:]
                let deep = record["deepScan"] as? [String: Any] ?? [:]
                let parse = deep["parse"] as? [String: Any] ?? [:]
                let keywords = deep["keywords_zh"] as? [String] ?? []
                let evidence = deep["evidence_zh"] as? [String] ?? []
                let topics = deep["topics_zh"] as? [String] ?? []
                let provider = parse["provider"] as? String ?? ""
                let digest = parse["modelDigest"] as? String ?? ""
                let hits = keywords.first.map { LibraryGateway.search(query: $0, in: indexed) } ?? []
                let searchable = hits.contains { $0.path == file.path }
                let scanValid = provider == "local" && !digest.isEmpty && file.summaryIssue == nil
                    && parse["model"] as? String == LocalQuickScan.model
                    && keywords.count >= 6 && keywords.count <= 10
                    && !topics.isEmpty && !evidence.isEmpty
                valid = valid && scanValid && (isEvaluation || searchable)
                return ["file": file.name, "relative": file.relative,
                        "predictedLabel": predictionByPath[file.path] ?? "none",
                        "contentType": file.contentType,
                        "summary": file.fileSummary, "keywords": keywords,
                        "topics": topics, "evidence": evidence,
                        "completion": deep["completion_state"] as? String ?? "",
                        "completionConfidence": deep["completion_confidence"] ?? 0,
                        "completionEvidence": deep["completion_evidence_zh"] ?? [],
                        "missingParts": deep["missing_parts_zh"] ?? [],
                        "reuseAction": deep["reuse_action"] as? String ?? "",
                        "reuseReason": deep["reuse_reason_zh"] as? String ?? "",
                        "reuseConfidence": deep["reuse_confidence"] ?? 0,
                        "parserVersion": parse["parserVersion"] as? String ?? "",
                        "provider": provider, "model": parse["model"] as? String ?? "",
                        "modelDigest": digest, "searchable": searchable,
                        "attempt": record["deepScanAttempt"] ?? [:]]
            }
            let report: [String: Any] = [
                "passed": valid,
                "elapsedSeconds": Date().timeIntervalSince(start),
                "files": files.count,
                "classified": classified.count,
                "results": results,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            exit(valid ? 0 : 1)
        }
        RunLoop.current.run()
        return true
    }
}
