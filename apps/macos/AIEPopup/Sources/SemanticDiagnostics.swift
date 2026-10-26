import Foundation
import AIEData

/// Real embedding integration on explicitly selected, empty synthetic directories only.
enum SemanticDiagnostics {
    static func runIfRequested() -> Bool {
        if runDeepScanIfRequested() { return true }
        let enhancement = CommandLine.arguments.dropFirst().first == "--verify-local-enhancement"
        guard enhancement || CommandLine.arguments.dropFirst().first == "--verify-semantic" else { return false }
        guard CommandLine.arguments.count == 3, let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"], path.hasPrefix("/") else { exit(2) }
        // Exercise the embedding-only plan without changing saved preferences or downloading models.
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
        ], forName: UserDefaults.argumentDomain)
        precondition(ScanConfiguration.semanticEnabled() && !ScanConfiguration.visionEnabled())
        precondition(!LocalRerank.isAvailable && ScanConfiguration.cloudScanPaused())
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        Task { @MainActor in
            do {
                let vision = await LocalQuickScan.shared.complete(system: "test", user: "test", images: [], maxTokens: 1)
                guard vision == nil else { throw CocoaError(.coderInvalidValue) }
                guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
                let samples = ["headings.txt": "## 行程安排", "flowchart.txt": "项目审批流程图：起点提交申请，经过主管审批和财务复核，最终归档。各步骤用箭头连接。", "onboarding.txt": "入职办理：人事登记、签署劳动合同、分配办公设备，安排导师介绍团队。",
                               "seaside.txt": "海滨度假地点，沙滩上可以游泳冲浪，欣赏大海的风景。",
                               "invoice.txt": "发票报销管理，核对金额、税率和银行收款账户，月底提交财务审批。"]
                for (name, text) in samples { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
                let files = LibraryGateway.load(roots: [root])
                guard LibraryGateway.lastError == nil else { throw CocoaError(.fileReadUnknown) }
                guard await LocalSemanticIndex.shared.indexNow(roots: [root.path]) else {
                    throw NSError(domain: "SemanticCheck", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: SemanticProgress.shared.text])
                }
                let queries = [("刚招来的人第一天该做什么", "onboarding.txt"), ("适合下海玩耍的旅游目的地", "seaside.txt"), ("流程图", "flowchart.txt")]
                for (query, expected) in queries {
                    let profile = await LocalSemanticIndex.shared.searchProfiled(query: query, roots: [root.path])
                    let vectors = profile.results
                    guard vectors.first?.path == root.appendingPathComponent(expected).path,
                          vectors.first?.kind == "paragraph" else {
                        throw NSError(domain: "SemanticCheck", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Raw passage did not rank first: \(profile.error ?? "no search error"); "
                                             + vectors.prefix(5).map { URL(fileURLWithPath: $0.path).lastPathComponent + ":" + $0.kind }.joined(separator: ",")])
                    }
                    if query == "流程图", vectors.contains(where: { $0.path == root.appendingPathComponent("headings.txt").path }) { throw CocoaError(.coderInvalidValue) }
                    let hits = LibraryGateway.search(query: query, in: files, semantic: vectors)
                    guard hits.contains(where: { $0.name == expected && $0.chunkID != nil }) else { throw CocoaError(.coderInvalidValue) }
                    print("Semantic fixture passed: \(expected), cosine \(String(format: "%.3f", vectors[0].score))")
                }
                if enhancement {
                    let file = files.first { $0.name == "onboarding.txt" }!
                    let summary = "新员工入职流程：由人事办理登记和劳动合同签署，分配办公设备，并安排导师介绍团队。"
                    let db = try AppDatabase.open()
                    let revision = try await LocalGemmaWorker.shared.revision()
                    let rawSpace = "gemma2:" + revision + ":raw-text-v1"
                    let before = try db.embeddingCoverage(spaceID: rawSpace, rootPaths: [root.path],
                        rawTextOnly: true, includeAllTextKinds: true)
                    guard ScanRecords.mutate(file, { record in
                        record["deepScan"] = ["blurb_zh": summary, "keywords_zh": ["入职流程"],
                            "parse": ["sourceHash": file.contentHash!, "model": "qwen3-vl:8b-instruct-q4_K_M",
                                      "parserVersion": "release-fixture-1"]]
                        return true
                    }) else { throw GemmaError.badResponse }
                    let updated = LibraryGateway.load(roots: [root])
                    // The normal update path must create the separate vectors; do not call indexDeepScan here.
                    guard await LocalSemanticIndex.shared.indexNow(roots: [root.path]) else { throw GemmaError.badResponse }
                    let deep = try await LocalSemanticIndex.shared.searchDeepScan(query: summary, roots: [root.path], topK: 30)
                    guard deep.first?.fileID == file.fileID, (deep.first?.score ?? 0) >= 0.70 else { throw GemmaError.badResponse }
                    let candidates = try await DeepScanSearchEnhancement.candidates(query: summary, v1: [],
                        semantic: [], files: updated, roots: [root.path])
                    guard candidates.hits.contains(where: { $0.path == file.path }), LocalBGERerank.isAvailable,
                          let ranked = await LocalBGERerank.rerank(query: summary, hits: candidates.hits, files: updated,
                            candidateLimit: DeepScanSearchEnhancement.topN, summaries: candidates.summaries),
                          ranked.first?.path == file.path else { throw GemmaError.badResponse }
                    let timedOut = await LocalBGERerank.rerank(query: summary, hits: ranked, files: updated, timeout: 0)
                    guard timedOut == nil else { throw GemmaError.badResponse }
                    let after = try db.embeddingCoverage(spaceID: rawSpace, rootPaths: [root.path],
                        rawTextOnly: true, includeAllTextKinds: true)
                    guard before.ready == after.ready, before.total == after.total else { throw GemmaError.badResponse }
                    _ = await LocalSemanticIndex.shared.indexNow(roots: [root.path])
                    let inputs = try db.deepScanEmbeddingInputs(spaceID: "gemma2:" + revision + ":deepscan-summary-v1",
                        legacySpaceID: "gemma2:" + revision + ":understanding-v1", modelID: LocalGemmaWorker.modelID,
                        modelVersion: revision, dimensions: 768, rootPaths: [root.path])
                    guard inputs.count == 1, inputs.allSatisfy(\.indexed) else { throw GemmaError.badResponse }
                    print("Release enhancement passed: automatic summary vector, independent recall, new candidate, bundled BGE Top5, timeout, idempotence, unchanged V1 coverage.")
                }
                await LocalGemmaWorker.shared.stop()
                print("Real \(LocalSemanticIndex.usesGemma ? "Gemma" : "Qwen 0.6B") checks passed; no user documents or cloud APIs used.")
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func runDeepScanIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let command = args.dropFirst().first,
              ["--index-deepscan", "--search-deepscan"].contains(command) else { return false }
        guard (command == "--index-deepscan" && args.count == 2)
                || (command == "--search-deepscan" && args.count == 4 && (Int(args[3]) ?? 0) > 0),
              let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"],
              path == AppDatabase.url.path, FileManager.default.fileExists(atPath: path) else {
            fputs("Set AIE_DATABASE_PATH to the existing database; use --index-deepscan or --search-deepscan QUERY TOP_K.\n", stderr)
            exit(2)
        }
        let roots = LibraryRoots.load().map(\.path)
        guard !roots.isEmpty else { fputs("No authorized roots; database left unchanged.\n", stderr); exit(2) }
        Task { @MainActor in
            do {
                let output: Data
                var failed = false
                if command == "--index-deepscan" {
                    let report = try await LocalSemanticIndex.shared.indexDeepScan(roots: roots)
                    output = try JSONEncoder().encode(report)
                    failed = !report.failures.isEmpty
                } else {
                    let hits = try await LocalSemanticIndex.shared.searchDeepScan(query: args[2], roots: roots, topK: Int(args[3])!)
                    output = try JSONEncoder().encode(hits)
                }
                await LocalGemmaWorker.shared.stop()
                print(String(decoding: output, as: UTF8.self))
                exit(failed ? 1 : 0)
            } catch {
                await LocalGemmaWorker.shared.stop()
                fputs(String(describing: error) + "\n", stderr)
                exit(1)
            }
        }
        RunLoop.current.run()
        return true
    }
}
