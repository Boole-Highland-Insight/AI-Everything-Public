import Foundation
import AIEData

/// Experimental switches are confined to the audit bundle and temporary databases.
enum SearchRuleAblationDiagnostics {
    static let mode: String? = {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.object(forInfoDictionaryKey: "AIEAuditOnly") as? Bool == true,
              env["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true,
              let mode = env["AIE_AUDIT_DRAWING_RULE"], ["A", "B"].contains(mode) else { return nil }
        return mode
    }()
    private static let directory: URL? = {
        guard mode != nil,
              let path = ProcessInfo.processInfo.environment["AIE_AUDIT_RULE_CAPTURE"],
              path.hasPrefix("/tmp/") else { return nil }
        return URL(fileURLWithPath: path)
    }()

    static func chunk(_ value: ChunkResult) -> [String: Any] {
        ["id": value.id, "path": value.relativePath, "kind": value.kind,
         "page": value.page as Any? ?? NSNull(), "score": value.score,
         "channel": value.retrievalChannel as Any? ?? NSNull(),
         "version_id": value.versionID, "text_length": value.text.count,
         "text_sha256": ContentIdentity.digest(value.text)]
    }

    static func lanes(query: String, vector: [Float], summary: [ChunkResult],
                      raw: [ChunkResult], rawTopTwo: [ChunkResult],
                      visual: [ChunkResult], accepted: [ChunkResult]) {
        guard directory != nil else { return }
        write(query: query, suffix: "lanes", value: [
            "vector_sha256": ContentIdentity.digest((try? JSONEncoder().encode(vector)) ?? Data()),
            "summary": summary.map(chunk), "raw": raw.map(chunk),
            "raw_top_two": rawTopTwo.map(chunk), "visual": visual.map(chunk),
            "accepted": accepted.map(chunk),
        ])
    }

    static func gateway(query: String, files: [IndexedFile], strict: [ChunkResult],
                        semantic: [ChunkResult], support: [String: Bool],
                        ordered: [String], strengths: [String: Int], hits: [FileHit]) {
        guard directory != nil else { return }
        let relative = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.relative) })
        write(query: query, suffix: semantic.isEmpty ? "lexical" : "hybrid", value: [
            "eligible_files": files.map(\.relative), "fts": strict.map(chunk),
            "semantic_input": semantic.map(chunk),
            "support": Dictionary(uniqueKeysWithValues: support.map { (relative[$0.key] ?? $0.key, $0.value) }),
            "ordered_files": ordered.map { relative[$0] ?? $0 },
            "strengths": Dictionary(uniqueKeysWithValues: strengths.map { (relative[$0.key] ?? $0.key, $0.value) }),
            "selected": hits.map { ["path": $0.relative, "page": $0.page as Any? ?? NSNull(),
                                   "chunk_id": $0.chunkID as Any? ?? NSNull(),
                                   "reason": $0.reason] as [String: Any] },
        ])
    }

    private static func write(query: String, suffix: String, value: [String: Any]) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var value = value
            value["query"] = query
            value["mode"] = mode
            let url = directory.appendingPathComponent(ContentIdentity.digest(query) + "-" + suffix + ".json")
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        } catch { AppLog.write("audit rule capture failed: \(error)") }
    }
}
