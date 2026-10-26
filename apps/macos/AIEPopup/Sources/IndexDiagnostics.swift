import Foundation

/// Offline integration check. Requires an explicit database destination and explicit library root.
/// Does not start watchers, scanners, the UI, or model requests.
enum IndexDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        let fallback = args.dropFirst().first == "--verify-fallback"
        let catalog = args.dropFirst().first == "--verify-catalog"
        let catalogFallback = args.dropFirst().first == "--verify-catalog-fallback"
        guard args.dropFirst().first == "--verify-index" || fallback || catalog || catalogFallback else { return false }
        guard args.count == 4, let databasePath = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"],
              !databasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("usage: AIE_DATABASE_PATH=/temporary/index.sqlite AIEPopup --verify-index /library query\n", stderr)
            exit(2)
        }
        let files = catalog || catalogFallback
            ? LibraryIndex.load(roots: [URL(fileURLWithPath: args[2])])
            : LibraryGateway.load(roots: [URL(fileURLWithPath: args[2])])
        if let error = LibraryGateway.lastError { fputs(error + "\n", stderr); exit(1) }
        let hits = fallback || catalogFallback
            ? LibraryGateway.fallbackCandidates(query: args[3], in: files, semantic: [])
            : LibraryGateway.search(query: args[3], in: files)
        if let error = LibraryGateway.lastError { fputs(error + "\n", stderr); exit(1) }
        let report: [String: Any] = ["files": files.count, "chunks": files.reduce(0) { $0 + $1.chunks.count },
            "hits": hits.map {
                [
                    "name": $0.name, "snippet": $0.snippet,
                    "tier": $0.confidenceTier.rawValue,
                    "evidenceSources": $0.evidence.map(\.source.rawValue),
                    "page": $0.page as Any? ?? NSNull(),
                    "startSeconds": $0.startSeconds as Any? ?? NSNull(),
                    "endSeconds": $0.endSeconds as Any? ?? NSNull(),
                    "chunkID": $0.chunkID as Any? ?? NSNull(),
                ]
            }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        return true
    }
}
