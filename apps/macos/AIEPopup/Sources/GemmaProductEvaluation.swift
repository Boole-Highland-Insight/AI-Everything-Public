import Foundation
import AIEData

/// Scores the frozen visual suite through AIE's semantic actor and Hybrid search adapter.
enum GemmaProductEvaluation {
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--evaluate-gemma-product" else { return false }
        let args = CommandLine.arguments
        guard args.count == 7,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let mapping = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))) ?? [:]
        let textRows = (try? String(contentsOfFile: args[4], encoding: .utf8))?.split(separator: "\n").dropFirst() ?? []
        let imageRows = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[5])))) as? [[String: String]] ?? []
        let output = URL(fileURLWithPath: args[6])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do { try await evaluate(root: root, mapping: mapping, textRows: textRows,
                                    imageRows: imageRows, output: output) }
            catch { fputs("Gemma evaluation: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    @MainActor private static func evaluate(root: URL, mapping: [String: String],
                                            textRows: ArraySlice<Substring>, imageRows: [[String: String]],
                                            output: URL) async throws {
                let files = LibraryGateway.load(roots: [root])
                guard LibraryGateway.lastError == nil else { throw GemmaError.badResponse }
                try await LocalSemanticIndex.shared.prepareSearch(roots: [root.path])
                var textResults: [[String: Any]] = [], imageResults: [[String: Any]] = []
                var textTimes: [Double] = [], imageTimes: [Double] = []
                for line in textRows {
                    let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard columns.count >= 4 else { continue }
                    let started = ProcessInfo.processInfo.systemUptime
                    let semantic = await LocalSemanticIndex.shared.search(query: columns[3], roots: [root.path])
                    let hits = LibraryGateway.search(query: columns[3], in: files, semantic: semantic, limit: 120)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    textTimes.append(elapsed)
                    let expected = Set(columns[1].split(separator: ",").compactMap { mapping[String($0)] })
                    let rank = hits.firstIndex { expected.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
                    let visual = semantic.filter { $0.retrievalChannel == "visual" }
                        .sorted { $0.score > $1.score }
                    let directRank = visual.firstIndex { expected.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
                    let top5: [[String: Any]] = hits.prefix(5).map { hit in
                        ["name": hit.name, "sources": hit.evidence.map(\.source.rawValue),
                         "page": hit.page as Any? ?? NSNull()]
                    }
                    let result: [String: Any] = ["id": columns[0], "category": columns[2],
                                                 "rank": rank.map { $0 + 1 } as Any? ?? NSNull(),
                                                 "elapsed_ms": elapsed,
                                                 "direct_visual_rank": directRank.map { $0 + 1 } as Any? ?? NSNull(),
                                                 "ranked_names": hits.map(\.name),
                                                 "top5": top5]
                    textResults.append(result)
                }
                for row in imageRows {
                    guard let id = row["id"], let path = row["image"],
                          let relevant = row["relevant_ids"] else { continue }
                    let started = ProcessInfo.processInfo.systemUptime
                    let semantic = try await LocalSemanticIndex.shared.search(imageURL: URL(fileURLWithPath: path),
                                                                              roots: [root.path])
                    let hits = LibraryGateway.visualCandidates(semantic, in: files)
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    imageTimes.append(elapsed)
                    let expected = Set(relevant.split(separator: ",").compactMap { mapping[String($0)] })
                    let rank = hits.firstIndex { expected.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }
                    imageResults.append(["id": id, "rank": rank.map { $0 + 1 } as Any? ?? NSNull(),
                                         "elapsed_ms": elapsed, "top5": hits.prefix(5).map(\.name)])
                }
                let textRanks = textResults.compactMap { $0["rank"] as? Int }
                let directRanks = textResults.compactMap { $0["direct_visual_rank"] as? Int }
                let imageRanks = imageResults.compactMap { $0["rank"] as? Int }
                let textSummary: [String: Any] = ["questions": textResults.count,
                                       "top1": textRanks.filter { $0 == 1 }.count,
                                       "top5": textRanks.filter { $0 <= 5 }.count,
                                       "direct_visual_top1": directRanks.filter { $0 == 1 }.count,
                                       "direct_visual_top5": directRanks.filter { $0 <= 5 }.count,
                                       "cold_ms": textTimes.first as Any? ?? NSNull(),
                                       "warm_p50_ms": percentile(Array(textTimes.dropFirst()), 0.5) as Any? ?? NSNull(),
                                       "warm_p95_ms": percentile(Array(textTimes.dropFirst()), 0.95) as Any? ?? NSNull()]
                let imageSummary: [String: Any] = ["questions": imageResults.count,
                                       "top1": imageRanks.filter { $0 == 1 }.count,
                                       "top5": imageRanks.filter { $0 <= 5 }.count,
                                       "p95_ms": percentile(imageTimes, 0.95) as Any? ?? NSNull()]
                let report: [String: Any] = [
                    "text_to_visual": textSummary,
                    "image_to_image": imageSummary,
                    "questions": textResults, "image_questions": imageResults,
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
                print(String(decoding: data, as: UTF8.self).prefix(600))
                exit(textResults.count == 95 && imageResults.count == 13 ? 0 : 1)
    }
}
