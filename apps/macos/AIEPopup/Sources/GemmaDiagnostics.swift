import Foundation
import AIEData
import Combine
import AppKit
import SwiftUI

/// Isolated end-to-end check for Gemma indexing and the real Hybrid search adapter.
enum GemmaDiagnostics {
    static func runIfRequested() -> Bool {
        if CommandLine.arguments.dropFirst().first == "--audit-index-samples" { return indexSamplesIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--benchmark-search-ui" { return searchTimingIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--stress-gemma" { return stressIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--verify-gemma-ui" { return uiIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--verify-gemma-video" { return videoIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--verify-gemma-fusion" { return fusionIfRequested() }
        if CommandLine.arguments.dropFirst().first == "--verify-gemma-migration" {
            guard ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
            do {
                let db = try AppDatabase.open()
                let stats = try db.statistics()
                print("Migrated isolated database: \(stats.embeddings) embeddings")
                exit(0)
            } catch { fputs("Gemma migration: \(error)\n", stderr); exit(1) }
        }
        guard CommandLine.arguments.dropFirst().first == "--verify-gemma" else { return false }
        guard CommandLine.arguments.count == 4,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let query = CommandLine.arguments[3]
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let files = LibraryGateway.load(roots: [root])
                guard LibraryGateway.lastError == nil else { throw GemmaError.badResponse }
                let complete = await LocalSemanticIndex.shared.indexNow(roots: [root.path])
                let profile = await LocalSemanticIndex.shared.searchProfiled(query: query, roots: [root.path])
                let hybrid = LibraryGateway.search(query: query, in: files, semantic: profile.results)
                let image = files.first { $0.kind.rawValue == "image" }.map { URL(fileURLWithPath: $0.path) }
                let imageMatches: [ChunkResult]
                if let image { imageMatches = try await LocalSemanticIndex.shared.search(imageURL: image, roots: [root.path]) }
                else { imageMatches = [] }
                let imageHits = LibraryGateway.visualCandidates(imageMatches, in: files)
                let db = try AppDatabase.open()
                let version = try await LocalGemmaWorker.shared.revision()
                let coverage = try db.visualEmbeddingCoverage(spaceID: "gemma2:" + version + ":visual-page-v1",
                                                              rootPaths: [root.path])
                let report: [String: Any] = [
                    "complete": complete, "files": files.count, "visual_ready": coverage.ready,
                    "visual_total": coverage.total, "semantic_error": profile.error as Any? ?? NSNull(),
                    "semantic_ms": profile.totalMilliseconds,
                    "hybrid": hybrid.prefix(5).map { ["name": $0.name, "page": $0.page as Any? ?? NSNull(),
                                                      "sources": $0.evidence.map(\.source.rawValue)] },
                    "image": imageHits.prefix(5).map { ["name": $0.name, "page": $0.page as Any? ?? NSNull()] },
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(complete && coverage.ready > 0 && !imageHits.isEmpty ? 0 : 1)
            } catch { fputs("Gemma diagnostic: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func indexSamplesIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4, ArchitectureAuditTrace.enabled,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.deep.rawValue,
            ScanConfiguration.pendingKey: false, "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        guard LocalQuickScan.isInstalled else { exit(2) }
        Task.detached {
            let files = LibraryGateway.load(roots: [root])
            var rows: [[String: Any]] = []
            for kind in [FileKind.image, .document, .video] {
                guard let file = files.first(where: { $0.kind == kind && (kind != .document || $0.ext == "pdf") }) else { continue }
                let id = UUID().uuidString
                ArchitectureAuditTrace.$traceID.withValue(id) {
                    let local = VisionEnricher.auditScan(file)
                    // Force only the selected temporary-copy deep record to measure actual calls.
                    ScanRecords.mutate(file) { record in record.removeValue(forKey: "deepScan"); return true }
                    let deep = QuickScanner.auditScan(file)
                    rows.append(["kind": kind.rawValue, "trace_id": id, "local_ok": local, "deep_ok": deep])
                }
            }
            let report: [String: Any] = ["samples": rows, "scope": "Controlled scanner calls; temporary DB only; not scheduler throughput"]
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                ArchitectureAuditTrace.flush()
                exit(0)
            } catch { exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func stressIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 5,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let query = args[3]
        let output = URL(fileURLWithPath: args[4])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let files = LibraryGateway.load(roots: [root])
                guard LibraryGateway.lastError == nil else { throw GemmaError.badResponse }
                try await LocalSemanticIndex.shared.prepareSearch(roots: [root.path])
                await LocalSemanticIndex.shared.warmUp()
                await LocalSemanticIndex.shared.update(roots: [root.path], force: true)
                let db = try AppDatabase.open()
                let version = try await LocalGemmaWorker.shared.revision()
                let space = "gemma2:" + version + ":visual-page-v1"
                var rows: [[String: Any]] = []
                let variants = ["原图", "原页面", "技术图", "结构图", "示意图", "资料页",
                                "报告页", "多模态", "页面内容", "编码器", "解码器", "排列方式"]
                for variant in variants {
                    try await Task.sleep(nanoseconds: 7_000_000_000)
                    let coverage = try db.visualEmbeddingCoverage(spaceID: space, rootPaths: [root.path])
                    ScanControl.shared.noteInteractiveWork(settleAfter: 1)
                    let started = ProcessInfo.processInfo.systemUptime
                    let actualQuery = query + " " + variant
                    let semantic = await LocalSemanticIndex.shared.searchProfiled(query: actualQuery, roots: [root.path])
                    let hits = LibraryGateway.search(query: actualQuery, in: files, semantic: semantic.results)
                    rows.append(["visual_ready": coverage.ready, "visual_total": coverage.total,
                                 "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                                 "semantic_ms": semantic.totalMilliseconds,
                                 "error": semantic.error as Any? ?? NSNull(),
                                 "top": hits.first?.name as Any? ?? NSNull()])
                }
                await LocalSemanticIndex.shared.stopAndUnload()
                let sorted = rows.compactMap { $0["milliseconds"] as? Double }.sorted()
                let warm = rows.dropFirst().compactMap { $0["milliseconds"] as? Double }.sorted()
                let finalCoverage = try db.visualEmbeddingCoverage(spaceID: space, rootPaths: [root.path])
                let report: [String: Any] = ["queries": rows, "p50_ms": sorted[sorted.count / 2],
                                             "p95_ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
                                             "warm_p95_ms": warm[min(warm.count - 1, Int(ceil(Double(warm.count) * 0.95)) - 1)],
                                             "visual_ready_after": finalCoverage.ready]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                print("Gemma stress report: \(output.path)")
                exit(0)
            } catch { fputs("Gemma stress: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func searchTimingIfRequested() -> Bool {
        let args = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment
        let live = environment["AIE_BENCHMARK_CURRENT_APP"] == "1"
            && Bundle.main.bundleIdentifier == "local.aieverything.cleanv2.progress"
            && environment["AIE_DATABASE_PATH"] == AIEApplicationPaths.support.appendingPathComponent("Index/content.sqlite").path
        guard args.count == 5,
              environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true || live else { exit(2) }
        let roots = (live && args[2] == "--current-roots" ? LibraryRoots.load()
            : [URL(fileURLWithPath: args[2])]).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !roots.isEmpty else { exit(2) }
        let rootPaths = roots.map(\.path)
        let input = URL(fileURLWithPath: args[3])
        let output = URL(fileURLWithPath: args[4])
        let auditEnvironment = ProcessInfo.processInfo.environment
        let auditBGE = auditEnvironment["AIE_AUDIT_BGE"] == "1"
        guard !auditBGE || LocalBGERerank.isAvailable else { exit(2) }
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
            "aie.search.automaticRerank": auditBGE,
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let queries = try JSONDecoder().decode([String].self, from: Data(contentsOf: input))
                let indexed = LibraryGateway.load(roots: roots)
                guard LibraryGateway.lastError == nil else { throw GemmaError.badResponse }
                let model = SearchModel(indexedFiles: indexed, roots: roots)
                var window: NSWindow?
                if auditEnvironment["AIE_AUDIT_RENDER"] == "1" {
                    let panel = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 620, height: 500),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    panel.title = "AIE isolated architecture audit"
                    panel.contentView = NSHostingView(rootView: SearchPanelView(model: model, onDismiss: {}))
                    panel.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    window = panel
                }
                // Settle the audit window's initial onAppear refresh before measured input.
                if window != nil { try await Task.sleep(nanoseconds: 200_000_000) }
                func resultRows(_ hits: [FileHit]) -> [[String: Any]] {
                    hits.map { hit in
                        ["path": hit.relative, "page": hit.page as Any? ?? NSNull(),
                         "chunk_id": hit.chunkID as Any? ?? NSNull(),
                         "sources": hit.evidence.map(\.source.rawValue),
                         "evidence": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(hit.evidence))) ?? [],
                         "tier": hit.confidenceTier.rawValue, "score": hit.score, "reason": hit.reason,
                         "start_seconds": hit.startSeconds as Any? ?? NSNull(),
                         "end_seconds": hit.endSeconds as Any? ?? NSNull(),
                         "snippet_sha256": ContentIdentity.digest(hit.snippet),
                         "highlights_sha256": ContentIdentity.digest(hit.highlights.joined(separator: "\u{0}"))]
                    }
                }
                let auditVisual = auditEnvironment["AIE_AUDIT_VISUAL"] == "1"
                var visualInput: URL?
                if auditVisual {
                    let db = try AppDatabase.open()
                    let version = try await LocalGemmaWorker.shared.revision()
                    let candidates = try db.searchVectorProfiled(
                        Array(repeating: Float(1), count: 768),
                        spaceID: "gemma2:" + version + ":visual-page-v1",
                        rootPaths: rootPaths, limit: 120, featureType: "visual_embedding").matches
                    if let page = candidates.first(where: { $0.kind == "visual_page" }) {
                        visualInput = try VisualEmbeddingInput.render(page)
                    }
                    guard visualInput != nil else { throw GemmaError.badResponse }
                }
                defer { if let visualInput { try? FileManager.default.removeItem(at: visualInput) } }
                var rows: [[String: Any]] = []
                let passes = Int(auditEnvironment["AIE_AUDIT_PASSES"] ?? "") ?? 2
                for pass in 0..<max(1, min(passes, 10)) {
                    for query in queries {
                        model.query = ""
                        var visualTask: Task<Void, Never>?
                        if let visualInput {
                            while ScanControl.shared.isInteractiveWorkActive {
                                try await Task.sleep(nanoseconds: 100_000_000)
                            }
                            visualTask = Task {
                                _ = try? await LocalGemmaWorker.shared.image(
                                    [visualInput.path], budget: 1120, background: true)
                            }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                        let started = ProcessInfo.processInfo.systemUptime
                        var firstMilliseconds: Double?
                        var firstResults: [[String: Any]] = []
                        let observation = model.$hits.sink { hits in
                            if firstMilliseconds == nil, !hits.isEmpty, model.hasActiveQuery {
                                firstMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                                firstResults = resultRows(hits)
                            }
                        }
                        model.query = query
                        while model.searchInProgress && ProcessInfo.processInfo.systemUptime - started < 30 {
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                        observation.cancel()
                        guard !model.searchInProgress else { throw GemmaError.badResponse }
                        let total = (ProcessInfo.processInfo.systemUptime - started) * 1000
                        var trace: Any = NSNull()
                        if let finished = model.lastSearchTrace {
                            trace = try JSONSerialization.jsonObject(with: JSONEncoder().encode(finished))
                        }
                        let row: [String: Any] = [
                            "query": query, "pass": pass,
                            "first_ms": firstMilliseconds as Any? ?? NSNull(),
                            "complete_ms": total, "trace": trace,
                            "paths": model.hits.map(\.relative),
                            "first_results": firstResults, "final_results": resultRows(model.hits),
                        ]
                        rows.append(row)
                        await visualTask?.value
                        // Allow SwiftUI's onAppear probe to run before the next input.
                        if window != nil { try await Task.sleep(nanoseconds: 40_000_000) }
                    }
                }
                if auditEnvironment["AIE_AUDIT_RULE_CAPTURE"] != nil,
                   SearchRuleAblationDiagnostics.mode != nil {
                    for query in queries {
                        let semantic = await LocalSemanticIndex.shared.search(query: query, roots: rootPaths,
                            minScore: LocalRerank.precisionWideMinScore, candidateLimit: 1000)
                        _ = LibraryGateway.search(query: query, in: model.files, semantic: semantic, limit: 1000)
                    }
                }
                var comparisons: [[String: Any]] = []
                if auditEnvironment["AIE_AUDIT_COMPARE_EVIDENCE"] == "1" {
                    // Freeze candidates once: both implementations receive identical inputs.
                    for query in queries {
                        let semantic = await LocalSemanticIndex.shared.search(
                            query: query, roots: rootPaths, minScore: LocalRerank.precisionWideMinScore,
                            candidateLimit: 1000)
                        let stale = try semantic.map { chunk -> ChunkResult in
                            var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chunk)) as! [String: Any]
                            value["id"] = "audit-stale-" + chunk.id
                            value["versionID"] = "audit-stale-version"
                            return try JSONDecoder().decode(ChunkResult.self, from: JSONSerialization.data(withJSONObject: value))
                        }
                        for (name, candidates, files) in [
                            ("lexical", [], model.files), ("hybrid", semantic, model.files),
                            ("duplicate_candidates", semantic + semantic, model.files),
                            ("stale_after_valid", semantic + stale, model.files),
                            ("restricted_snapshot", semantic, Array(model.files.prefix(1)))] {
                            let before = LibraryGateway.search(query: query, in: files,
                                semantic: candidates, limit: 1000, reuseEvidence: false)
                            let after = LibraryGateway.search(query: query, in: files,
                                semantic: candidates, limit: 1000, reuseEvidence: true)
                            let repeatedBefore = LibraryGateway.search(query: query, in: files,
                                semantic: candidates, limit: 1000, reuseEvidence: false)
                            comparisons.append(["query": query, "case": name,
                                "baseline_repeat_equal": before == repeatedBefore,
                                "baseline_repeat": resultRows(repeatedBefore),
                                "equal_file_hits": before == after,
                                "only_allowed_paths": after.allSatisfy { hit in files.contains { $0.path == hit.path } },
                                "no_stale_chunk": after.allSatisfy { !($0.chunkID?.hasPrefix("audit-stale-") ?? false) },
                                "before": resultRows(before), "after": resultRows(after)])
                        }
                    }
                }
                var thresholdRows: [[String: Any]] = []
                if live {
                    for query in queries {
                        let candidates = await LocalSemanticIndex.shared.searchProfiled(query: query, roots: rootPaths).results
                        let kept = candidates.filter {
                            $0.retrievalChannel == "raw_text" ? $0.score >= 0.70
                                : ($0.retrievalChannel == "visual" && $0.score >= 0.65)
                        }
                        thresholdRows.append(["query": query, "kept": kept.count,
                            "paths": LibraryGateway.search(query: query, in: model.files, semantic: kept).map(\.relative)])
                    }
                }
                let profile = await LocalSemanticIndex.shared.searchProfiled(
                    query: queries.first ?? "", roots: rootPaths)
                let profileReport: [String: Double] = [
                    "embedding_ms": profile.embeddingMilliseconds,
                    "vector_ms": profile.vectorDiagnostics?.totalMilliseconds ?? 0,
                    "detail_ms": profile.vectorDiagnostics?.detailReadMilliseconds ?? 0,
                    "cosine_ms": profile.vectorDiagnostics?.cosineMilliseconds ?? 0,
                    "candidate_ms": profile.vectorDiagnostics?.candidateReadMilliseconds ?? 0,
                    "fusion_ms": profile.thresholdMilliseconds,
                    "total_ms": profile.totalMilliseconds,
                ]
                let report: [String: Any] = [
                    "files": model.files.count, "queries": rows, "profile": profileReport,
                    "threshold_0_70_0_65": thresholdRows,
                    "evidence_comparisons": comparisons,
                    "scope": "SearchModel publication timing; excludes drawing and initial catalog loading",
                    "bge": auditBGE, "visual_competition": auditVisual, "render_probe": window != nil,
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                print("Search timing: \(output.path)")
                ArchitectureAuditTrace.flush()
                window?.orderOut(nil)
                exit(0)
            } catch { fputs("Search timing: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func uiIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 6,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        let image = URL(fileURLWithPath: args[4])
        let output = URL(fileURLWithPath: args[5])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let model = SearchModel()
                model.roots = [root]
                LibraryGateway.selectRoots([root])
                model.files = LibraryGateway.load(roots: [root])
                try await LocalSemanticIndex.shared.prepareSearch(roots: [root.path])
                model.query = args[3]
                for _ in 0..<300 where model.fastSearching {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let textHits = model.hits.prefix(5).map { ["name": $0.name,
                                                           "sources": $0.evidence.map(\.source.rawValue),
                                                           "page": $0.page as Any? ?? NSNull()] as [String: Any] }
                model.beginImageSearch(image)
                for _ in 0..<300 where model.fastSearching {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let imageHits = model.hits.prefix(5).map { ["name": $0.name,
                                                            "sources": $0.evidence.map(\.source.rawValue)] }
                let report: [String: Any] = ["text_hits": textHits, "image_hits": imageHits,
                                             "status": model.status]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                print("Gemma SearchModel report: \(output.path)")
                exit(textHits.isEmpty || imageHits.isEmpty ? 1 : 0)
            } catch { fputs("Gemma UI model: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func videoIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let source = URL(fileURLWithPath: args[2]).standardizedFileURL
        let root = source.deletingLastPathComponent().path
        let output = URL(fileURLWithPath: args[3])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                let document = SourceDocument(
                    id: ContentIdentity.digest(source.path), rootPath: root, path: source.path,
                    relativePath: source.lastPathComponent, kind: "video", ext: "mp4",
                    contentHash: ContentIdentity.digest("video-frame-fixture-v1"), size: 1,
                    modifiedAt: 1, blocks: [
                        ContentBlock(key: "document", parentKey: nil, kind: "document", text: source.lastPathComponent),
                        ContentBlock(key: "visual-frame-1", kind: "visual_frame", startSeconds: 1,
                                     endSeconds: 2, text: "", summaryMethod: "visual_anchor")])
                let db = try AppDatabase.open()
                try db.synchronize(documents: [document], rootPaths: [root])
                guard await LocalSemanticIndex.shared.indexNow(roots: [root]) else { throw GemmaError.badResponse }
                let version = try await LocalGemmaWorker.shared.revision()
                let space = "gemma2:" + version + ":visual-page-v1"
                guard let frame = try db.searchVectorProfiled(
                    [Float](repeating: 1, count: 768), spaceID: space, rootPaths: [root],
                    limit: 1, featureType: "visual_embedding").matches.first else { throw GemmaError.badResponse }
                let image = try VisualEmbeddingInput.render(frame)
                defer { try? FileManager.default.removeItem(at: image) }
                let matches = try await LocalSemanticIndex.shared.search(imageURL: image, roots: [root])
                let result: [String: Any] = ["name": matches.first?.relativePath as Any? ?? NSNull(),
                                             "start_seconds": matches.first?.startSeconds as Any? ?? NSNull(),
                                             "end_seconds": matches.first?.endSeconds as Any? ?? NSNull(),
                                             "source": matches.first?.retrievalChannel as Any? ?? NSNull()]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                print(String(describing: result))
                exit(matches.first?.startSeconds == 1 ? 0 : 1)
            } catch { fputs("Gemma video: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }

    private static func fusionIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.count == 4,
              ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"]?.hasPrefix("/tmp/") == true else { exit(2) }
        let source = URL(fileURLWithPath: args[2]).standardizedFileURL
        let root = source.deletingLastPathComponent().path
        let output = URL(fileURLWithPath: args[3])
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
            "aie.embedding.engine": "gemma",
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            do {
                var document = SourceDocument(
                    id: ContentIdentity.digest(source.path), rootPath: root, path: source.path,
                    relativePath: source.lastPathComponent, kind: "image", ext: source.pathExtension,
                    contentHash: ContentIdentity.digest("fusion-fixture-v1"), size: 1,
                    modifiedAt: 1, blocks: [
                        ContentBlock(key: "document", parentKey: nil, kind: "document", text: source.lastPathComponent),
                        ContentBlock(key: "ocr", kind: "image_ocr", text: "Microsoft Teams 蓝色聊天窗口"),
                        ContentBlock(key: "visual-image", kind: "visual_image", text: "",
                                     summaryMethod: "visual_anchor")])
                document.fileSummary = "8B 视觉摘要：电脑屏幕显示 Microsoft Teams 的聊天窗口"
                let db = try AppDatabase.open()
                try db.synchronize(documents: [document], rootPaths: [root])
                guard await LocalSemanticIndex.shared.indexNow(roots: [root]) else { throw GemmaError.badResponse }
                let semantic = await LocalSemanticIndex.shared.search(query: "Teams 蓝色聊天窗口", roots: [root])
                var file = IndexedFile(path: source.path, name: source.lastPathComponent,
                                       relative: source.lastPathComponent, kind: .image,
                                       ext: source.pathExtension, mtime: Date(timeIntervalSince1970: 1),
                                       haystack: "Microsoft Teams 蓝色聊天窗口", preview: document.fileSummary,
                                       thumbPath: nil, rootPath: root, size: 1, hasBarcode: false,
                                       isScreenshot: true, llmLine: document.fileSummary,
                                       llmCard: document.fileSummary, uploadedToCloud: false)
                file.fileID = document.id
                file.versionID = document.versionID
                file.fileSummary = document.fileSummary
                let hits = LibraryGateway.search(query: "Teams 蓝色聊天窗口", in: [file], semantic: semantic)
                let channels = Set(semantic.compactMap(\.retrievalChannel))
                let sources = Set(hits.first?.evidence.map(\.source.rawValue) ?? [])
                let result: [String: Any] = ["channels": channels.sorted(), "sources": sources.sorted(),
                                             "top": hits.first?.name as Any? ?? NSNull()]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                print(String(describing: result))
                exit(channels.isSuperset(of: ["summary", "visual", "raw_text"])
                     && sources.isSuperset(of: ["summary", "visual", "semantic"]) ? 0 : 1)
            } catch { fputs("Gemma fusion: \(error)\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }
}
