import Foundation
import AIEData

/// Replays the frozen 58-query text suite through AIE's actual index writer and retriever.
enum GemmaTextEvaluation {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--evaluate-gemma-text" else { return false }
        let args = CommandLine.arguments
        guard args.count == 6,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL.path
        let manifest = URL(fileURLWithPath: args[3])
        let corpus = URL(fileURLWithPath: args[4])
        let output = URL(fileURLWithPath: args[5])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let records = try String(contentsOf: corpus, encoding: .utf8).split(separator: "\n").compactMap {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }
                let groups = Dictionary(grouping: records) { $0["path"] as? String ?? "" }
                let documents: [SourceDocument] = groups.compactMap { path, rows in
                    guard !path.isEmpty else { return nil }
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    let id = ContentIdentity.digest(path)
                    var blocks = [ContentBlock(key: "document", parentKey: nil, kind: "document", text: name)]
                    for row in rows {
                        guard let chunkID = row["id"] as? String,
                              let text = row["text"] as? String,
                              let kind = row["kind"] as? String else { continue }
                        blocks.append(ContentBlock(key: "benchmark-" + chunkID, kind: kind,
                                                   page: row["page"] as? Int, text: text))
                    }
                    let hash = ContentIdentity.digest(blocks.map(\.text).joined(separator: "\n"))
                    return SourceDocument(id: id, rootPath: root, path: root + "/" + path,
                                          relativePath: path, kind: "document",
                                          ext: String(name.split(separator: ".").last ?? ""),
                                          contentHash: hash, size: Int64(blocks.map { $0.text.utf8.count }.reduce(0, +)),
                                          modifiedAt: 1, blocks: blocks)
                }
                let db = try AppDatabase.open()
                try db.synchronize(documents: documents, rootPaths: [root])
                guard await LocalSemanticIndex.shared.indexNow(roots: [root]) else { throw GemmaError.badResponse }
                let files: [IndexedFile] = documents.map { document in
                    let name = URL(fileURLWithPath: document.path).lastPathComponent
                    let body = document.blocks.map(\.text).joined(separator: " ")
                    var file = IndexedFile(path: document.path, name: name, relative: document.relativePath,
                                           kind: LibraryIndex.kind(for: document.ext), ext: document.ext,
                                           mtime: Date(timeIntervalSince1970: 1), haystack: body,
                                           preview: String(body.prefix(120)), thumbPath: nil,
                                           rootPath: root, size: Int(document.size), hasBarcode: false,
                                           isScreenshot: false, llmLine: name, llmCard: name,
                                           uploadedToCloud: false)
                    file.fileID = document.id
                    file.versionID = document.versionID
                    return file
                }
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
                let cases = json?["cases"] as? [[String: Any]] ?? []
                var rows: [[String: Any]] = [], durations: [Double] = []
                for item in cases {
                    guard let query = item["query"] as? String, let expected = item["expected"] as? String,
                          let id = item["id"] as? String else { continue }
                    let started = ProcessInfo.processInfo.systemUptime
                    let hits = await LocalSemanticIndex.shared.search(query: query, roots: [root])
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    durations.append(elapsed)
                    let paths = Array(NSOrderedSet(array: hits.map(\.relativePath))) as? [String] ?? []
                    let rank = paths.firstIndex { $0 == expected || $0.hasSuffix("/" + expected) }
                    let hybrid = LibraryGateway.search(query: query, in: files, semantic: hits, limit: 120)
                    let hybridRank = hybrid.firstIndex { $0.relative == expected || $0.relative.hasSuffix("/" + expected) }
                    rows.append(["id": id, "query": query, "expected": expected,
                                 "rank": rank.map { $0 + 1 } as Any? ?? NSNull(),
                                 "hybrid_rank": hybridRank.map { $0 + 1 } as Any? ?? NSNull(),
                                 "elapsed_ms": elapsed, "top5": Array(paths.prefix(5))])
                }
                let ranks = rows.compactMap { $0["rank"] as? Int }
                let hybridRanks = rows.compactMap { $0["hybrid_rank"] as? Int }
                let sorted = Array(durations.dropFirst()).sorted()
                let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
                let report: [String: Any] = ["chunks": records.count, "files": documents.count,
                                             "queries": rows.count, "top1": ranks.filter { $0 == 1 }.count,
                                             "top5": ranks.filter { $0 <= 5 }.count,
                                             "hybrid_top1": hybridRanks.filter { $0 == 1 }.count,
                                             "hybrid_top5": hybridRanks.filter { $0 <= 5 }.count,
                                             "cold_ms": durations.first as Any? ?? NSNull(),
                                             "warm_p95_ms": p95, "cases": rows]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
                print(String(decoding: data, as: UTF8.self).prefix(450))
                exit(rows.count == 58 ? 0 : 1)
            } catch { fputs("Gemma text evaluation: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }
}
