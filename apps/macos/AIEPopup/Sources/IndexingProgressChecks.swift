import Foundation
import AppKit
import SwiftUI
import AIEData

/// Explicit diagnostic only. Synthetic data and vectors; no parsers or model calls.
enum IndexingProgressChecks {
    @MainActor static func run(at path: String) -> Bool {
        do {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let root = output.appendingPathComponent("synthetic-library").path
            let dbPath = output.appendingPathComponent(UUID().uuidString + ".sqlite").path
            let db = try ContentStore(path: dbPath)
            var checks: [String] = []
            func check(_ condition: Bool, _ name: String) throws {
                guard condition else { throw NSError(domain: "ProgressChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
                checks.append(name)
            }
            func document(_ id: Int, hash: String = "v1", status: String = "ready") -> SourceDocument {
                var doc = SourceDocument(id: "fixture-\(id)", rootPath: root, path: root + "/\(id).png",
                    relativePath: "\(id).png", kind: "image", ext: "png", contentHash: "\(hash)-\(id)", size: 100, modifiedAt: 1,
                    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: ""),
                             ContentBlock(key: "visual", kind: "visual_image", text: "", summaryMethod: "visual_anchor")])
                doc.stages = [ScanStage("index", status: "ready"), ScanStage("local", status: status), ScanStage("deep", status: "pending")]
                return doc
            }
            // Restart must preserve structural children whose chunker differs from PDFKit.
            let pdfRoot = output.appendingPathComponent("pdf-library").path
            let pdfDB = try ContentStore(path: output.appendingPathComponent(UUID().uuidString + "-pdf.sqlite").path)
            let text = String(repeating: "保留全文与页码。", count: 500)
            let rootBlock = ContentBlock(key: "document", parentKey: nil, kind: "document", text: "test.pdf")
            var pdf = SourceDocument(id: "pdf", rootPath: pdfRoot, path: pdfRoot + "/test.pdf", relativePath: "test.pdf",
                kind: "document", ext: "pdf", contentHash: "same-version", size: 100, modifiedAt: 1,
                blocks: [rootBlock] + StructuralChunker.page(text, key: "pdf-3", kind: "page", page: 3, parserVersion: "pdfkit-visual-2"))
            try pdfDB.synchronize(documents: [pdf], rootPaths: [pdfRoot])
            let before = try pdfDB.chunks(rootPaths: [pdfRoot])
            let child = before.first { $0.kind == "page_text" }!
            let space = "gemma2:fixture:raw-text-v1"
            try pdfDB.putEmbedding(chunkID: child.id, spaceID: space, modelID: "fixture", modelVersion: "fixture",
                vector: [Float](repeating: 1, count: 768), rootPaths: [pdfRoot], expectedContentHash: child.contentHash)
            let restoredBlocks = try pdfDB.cachedSourceBlocks(versionID: pdf.versionID, parserVersion: "pdfkit-visual-2")!
            try check(restoredBlocks.count == pdf.blocks.count - 1, "PDF restart restores structural child blocks")
            try check(restoredBlocks.filter { $0.kind == "page_text" }.map(\.text).joined() == text, "PDF cached restart preserves full text")
            pdf.blocks = [rootBlock] + restoredBlocks
            try pdfDB.stage(documents: [pdf], rootPaths: [pdfRoot])
            try check(try pdfDB.chunks(rootPaths: [pdfRoot]).count == before.count, "Restaging cached PDF does not delete text chunks")
            try check(try pdfDB.chunk(id: child.id, rootPaths: [pdfRoot])?.page == 3 && pdfDB.embeddingCoverage(spaceID: space, rootPaths: [pdfRoot], rawTextOnly: true, includeAllTextKinds: true).ready == 1,
                "PDF restart retains existing vector and page location without model calls")
            var docs = [document(0), document(1), document(2)]
            try db.synchronize(documents: docs, rootPaths: [root])
            let progress = IndexingProgressDisplay()
            let visualSpace = "gemma2:fixture:visual-page-v1"
            let targets = try db.missingVisualEmbeddings(spaceID: visualSpace, rootPaths: [root], limit: 10)
            let vector = [Float](repeating: 1, count: 768)
            for unit in targets {
                try db.putEmbedding(chunkID: unit.id, spaceID: visualSpace, modelID: "fixture", modelVersion: "fixture",
                    vector: vector, rootPaths: [root], expectedContentHash: unit.contentHash, featureType: "visual_embedding")
            }
            progress.snapshot = try db.indexingDisplaySnapshot(rootPaths: [root])
            let completedSnapshot = progress.snapshot
            let fileOnly = try db.indexingFileSnapshot(rootPaths: [root])
            try check(fileOnly.files.count == 3 && fileOnly.semanticReady == nil,
                "File counts publish without waiting for semantic coverage")
            let semanticOnly = try db.indexingSemanticSnapshot(rootPaths: [root])
            try check(semanticOnly.ready == 3 && semanticOnly.total == 3,
                "Gemma coverage has an independent result")
            progress.requestID = root
            progress.failed = true
            try check(progress.matches(root) && progress.semanticMatches(root),
                "A transient refresh failure retains the last valid counts")
            progress.failed = false
            try check(progress.semanticCount.ready == 3 && progress.semanticCount.pending == 0, "Saved vectors counted without model invocation")
            try check(progress.semanticCount.status(upstreamPending: false, paused: false, loaded: true) == "完成", "Closed pass with all targets ready completes")
            try check(progress.semanticCount.status(upstreamPending: true, paused: false, loaded: true) == "等待新内容", "Empty downstream queue while discovery continues is not complete")
            let large = progress.count("local", discovered: 1179)
            try check(large.ready == 3 && large.pending == 1176, "New 1179-file discovery invalidates the old three-file completion")
            try check(!IndexingStageCount(ready: 1178, pending: 1).settled, "1178 of 1179 must not round to complete")
            try check(IndexingStageCount(ready: 7805, pending: 8).fraction == 0.99,
                "7805 of 7813 displays 99 percent while keeping true counts")
            try check(IndexingStageCount(ready: 7813, running: true).fraction == 0.99,
                "Running work cannot display 100 percent")
            try check(IndexingStageCount(ready: 7813).fraction == 1,
                "Only settled full coverage displays 100 percent")
            try check(IndexingStageCount(ready: 1178, pending: 1).status(upstreamPending: false, paused: false, loaded: true) != "完成", "Nearly 100 percent remains pending")
            try check(IndexingStageCount(ready: 3, running: true).status(upstreamPending: false, paused: false, loaded: true) == "处理中", "Running work prevents completion")
            try check(IndexingStageCount(ready: 3, running: true).status(upstreamPending: false, paused: true, loaded: true) == "处理中", "In-flight work stays running until it stops")
            try check(IndexingStageCount(skipped: 3).status(upstreamPending: false, paused: false, loaded: true) == "无需处理", "Unsupported is distinct from successful processing")
            try check(!IndexingStageCount(deferred: 1).settled, "Deferred work is not completed")
            try check(IndexingStageCount(ready: 3).status(upstreamPending: false, paused: true, loaded: true) == "已暂停", "Pause has its own status")
            try check(progress.semanticCount.status(upstreamPending: false, paused: false, loaded: false) == "统计中", "No restored snapshot means unknown, not complete")
            let scan = ScanProgress.shared
            scan.beginDiscovery(); let firstGeneration = scan.indexGeneration
            progress.requestID = "previous"
            try check(!progress.matches("next"), "Previous root/batch snapshot cannot complete a new batch")
            scan.beginIndexing(total: 1179); scan.updateIndexing(completed: 1179, total: 1179)
            try check(scan.indexing, "Last batch callback is not end of the full pass")
            scan.finishIndexing(completed: true)
            try check(!scan.indexing && !scan.catalogDiscovering, "Explicit pass completion closes discovery")
            scan.beginDiscovery()
            try check(scan.indexGeneration == firstGeneration + 1 && scan.catalogDiscovering, "Repeated discovery refreshes every stage")
            scan.finishIndexing(completed: false)
            try check(scan.indexFailed, "Failed parser pass cannot display complete")
            docs += (3..<1179).map { document($0, status: "pending") }
            try db.synchronize(documents: docs, rootPaths: [root])
            progress.snapshot = try db.indexingDisplaySnapshot(rootPaths: [root])
            try check(progress.snapshot?.files.count == 1179 && progress.semanticCount.total == 1179 && progress.semanticCount.ready == 3,
                "Persisting more files grows Gemma denominator and preserves existing vectors")
            try check(progress.count("local", discovered: 1179).pending == 1176, "Current-version recognition remains pending for unprocessed files")
            let reopened = try ContentStore(path: dbPath)
            let restored = try reopened.indexingDisplaySnapshot(rootPaths: [root])
            try check(restored.semanticReady == 3 && restored.semanticTotal == 1179, "Restart restores unfinished counts from SQLite")
            docs[0] = document(0, hash: "v2", status: "failed")
            docs[1] = document(1, status: "unsupported")
            try db.synchronize(documents: docs, rootPaths: [root])
            let missing = try db.missingVisualEmbeddings(spaceID: visualSpace, rootPaths: [root], limit: 1)[0]
            try db.recordVisualEmbeddingFailure(chunkID: missing.id, spaceID: visualSpace, rootPaths: [root], error: "synthetic failure")
            _ = try db.claimJob(subjectID: docs[3].versionID, jobType: "deep", inputHash: "model-protocol-hash", priority: 50, owner: "fixture")
            progress.snapshot = try db.indexingDisplaySnapshot(rootPaths: [root])
            try check(progress.semanticCount.ready == 2, "Old-version vector is excluded")
            try check(progress.semanticCount.failed == 1, "Persisted Gemma visual failure is restored")
            let local = progress.count("local", discovered: 1179)
            try check(local.failed == 1 && local.skipped == 1 && local.pending == 1176, "Failure, unsupported and pending remain separate")
            try check(local.status(upstreamPending: false, paused: false, loaded: true) == "有失败项", "Failed recognition cannot complete")
            try check(progress.count("deep", discovered: 1179).running, "8B protocol-hashed lease is recognized as running")
            try check(try reopened.indexingDisplaySnapshot(rootPaths: []).files.isEmpty, "Unauthorized or empty scope exposes no files")
            // Render the actual settings view, using the same display snapshot and four-stage layout.
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            defaults.set("semantic", forKey: ScanConfiguration.planKey)
            defaults.set(false, forKey: "aie.search.automaticRerank")
            scan.catalogCount = 1179; scan.catalogReady = true; scan.indexFailed = false
            scan.userPaused = false; scan.running = false; scan.active = .none
            let model = SearchModel(previewFiles: [])
            model.roots = [URL(fileURLWithPath: root)]
            for state in ["discovering", "parsing", "failures", "complete", "paused"] {
                progress.snapshot = state == "failures" ? try db.indexingDisplaySnapshot(rootPaths: [root]) : completedSnapshot
                scan.catalogCount = state == "complete" || state == "paused" ? 3 : 1179
                scan.userPaused = state == "paused"
                scan.catalogDiscovering = state == "discovering"
                scan.indexing = state == "parsing"
                scan.indexedFiles = 3; scan.indexTotal = scan.catalogCount
                progress.requestID = root
                let view = NSHostingView(rootView: APISettingsView(model: model, progress: progress)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
                view.frame = NSRect(x: 0, y: 0, width: 410, height: 560)
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(state + ".png"))
                }
            }
            try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks, "modelsInvoked": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("checks.json"))
            print("PASS: \(checks.count) progress checks; isolated 1179-file fixture; no model calls")
        } catch { fputs("Progress checks failed: \(error)\n", stderr); exit(1) }
        return true
    }
}
