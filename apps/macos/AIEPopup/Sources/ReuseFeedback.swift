import Foundation

/// User decisions stay with the exact content version. A changed file can be assessed again.
enum ReuseFeedback {
    static func begin(_ file: IndexedFile) {
        update(file, action: "started") { feedback in
            feedback["sessionActive"] = true
        }
    }

    static func markNotDraft(_ file: IndexedFile) {
        update(file, action: "not_draft") { feedback in
            feedback["notDraft"] = true
        }
    }

    static func markResolved(_ file: IndexedFile, resultPath: String) {
        update(file, action: "completed") { feedback in
            feedback["resolved"] = true
            feedback["resultPath"] = resultPath
            feedback["currentResultPath"] = resultPath
            feedback["sessionActive"] = true
        }
    }

    static func markCurrentResult(_ file: IndexedFile, resultPath: String, detail: String) {
        update(file, action: "revised") { feedback in
            feedback["resolved"] = true
            feedback["currentResultPath"] = resultPath
            feedback["sessionActive"] = true
            feedback["detail"] = String(detail.prefix(500))
        }
    }

    static func close(_ file: IndexedFile) {
        update(file, action: "closed") { feedback in
            feedback["sessionActive"] = false
        }
    }

    static func record(_ file: IndexedFile, action: String, detail: String = "") {
        update(file, action: action) { feedback in
            if !detail.isEmpty { feedback["detail"] = String(detail.prefix(500)) }
        }
    }

    private static func update(
        _ file: IndexedFile,
        action: String,
        body: (inout [String: Any]) -> Void
    ) {
        guard let hash = file.contentHash, !hash.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ScanRecords.mutate(file) { record in
            var feedback = record["reuseFeedback"] as? [String: Any] ?? [:]
            if feedback["sourceHash"] as? String != hash {
                feedback = ["sourceHash": hash]
            }
            body(&feedback)
            feedback["lastAction"] = action
            feedback["classifierVersion"] = "reuse-safe-1"
            feedback["updatedAt"] = iso.string(from: Date())
            feedback["updatedAtEpoch"] = Date().timeIntervalSince1970
            var history = feedback["history"] as? [[String: Any]] ?? []
            history.append(["action": action, "at": iso.string(from: Date())])
            feedback["history"] = Array(history.suffix(20))
            record["reuseFeedback"] = feedback
            return true
        }
    }
}
