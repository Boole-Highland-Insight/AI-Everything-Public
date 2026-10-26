import Foundation
import Combine
import AIEData

struct SemanticSearchProfile {
    let results: [ChunkResult]
    let embeddingMilliseconds: Double
    let vectorDiagnostics: VectorSearchDiagnostics?
    let thresholdMilliseconds: Double
    let totalMilliseconds: Double
    let queryVectorCacheHit: Bool
    let topKBeforeThreshold: Int
    let topKRejectedByThreshold: Int
    let highestScore: Double?
    let lowestAcceptedScore: Double?
    let error: String?
}

struct DeepScanIndexReport: Codable {
    let space: String
    let total: Int
    let generated: Int
    let reused: Int
    let skipped: Int
    let failures: [String]
}

@MainActor final class SemanticProgress: ObservableObject {
    enum Phase { case checking, running, paused, complete, unavailable, disabled }
    static let shared = SemanticProgress()
    @Published var text = "语义索引待检查"
    @Published var revision = 0
    @Published var phase: Phase = .checking
    @Published var ready = 0
    @Published var total = 0
    @Published var rootPaths: [String] = []
    @Published var timingKey = ""
}

/// A loopback-only embedding client. A missing runtime/model never blocks lexical search.
actor LocalSemanticIndex {
    static let shared = LocalSemanticIndex()
    static let usesGemma = true
    private var roots: [String] = []
    private var job: Task<Void, Never>?
    private var generation = 0
    private var digest: String?
    private var queryCache: [String: [Float]] = [:]
    private var retryAfter = Date.distantPast
    private static let indexedSemanticMethods = [
        "file_summary",
        "local_multimodal_deep_scan",
        "local_multimodal_video_segment",
    ]
    private var space: String? { digest.map {
        "gemma2:" + $0 + ":understanding-v1"
    } }
    private var rawSpace: String? { digest.map {
        "gemma2:" + $0 + ":raw-text-v1"
    } }
    private var visualSpace: String? { digest.map { "gemma2:" + $0 + ":visual-page-v1" } }
    func indexNow(roots requested: [String]) async -> Bool {
        update(roots: requested)
        let active = job
        await active?.value
        guard let space, let rawSpace, let db = try? AppDatabase.open(),
              let raw = try? db.embeddingCoverage(
                spaceID: rawSpace, rootPaths: requested, rawTextOnly: true,
                includeAllTextKinds: Self.usesGemma)
        else { return false }
        let summary: (ready: Int, total: Int) = Self.usesGemma ? (0, 0) : ((try? db.embeddingCoverage(
            spaceID: space, rootPaths: requested, semanticMethods: Self.indexedSemanticMethods)) ?? (0, 0))
        let visual = Self.usesGemma && visualSpace != nil
            ? try? db.visualEmbeddingCoverage(spaceID: visualSpace!, rootPaths: requested) : nil
        if Self.usesGemma && visual == nil { return false }
        return summary.total + raw.total + (visual?.total ?? 0) > 0
            && summary.ready == summary.total && raw.ready == raw.total
            && (visual == nil || visual!.ready == visual!.total)
    }
    func update(roots requested: [String], force: Bool = false) {
        let requested = requested.sorted()
        if roots != requested {
            generation += 1; job?.cancel(); job = nil; roots = requested
        }
        guard ScanConfiguration.semanticEnabled(), !roots.isEmpty else {
            Task { @MainActor in SemanticProgress.shared.phase = .disabled }
            return
        }
        guard job == nil, force || Date() >= retryAfter else { return }
        let current = generation
        job = Task { await self.build(generation: current) }
    }

    func interruptForInteractiveWork() {
        Task { await LocalGemmaWorker.shared.interruptBackground() }
    }
    func stopAndUnload() async {
        generation += 1
        let previous = job
        previous?.cancel()
        job = nil
        await previous?.value
        queryCache.removeAll()
        await unload()
        await MainActor.run {
            SemanticProgress.shared.text = "轻量模式 · 全文检索可用"
            SemanticProgress.shared.phase = .disabled
        }
    }

    /// Drops the resident embedding weights. The next search loads them again.
    /// Search planning must call this first: the vector model is otherwise pinned, and the 8B loads beside it.
    func unload() async {
        await LocalGemmaWorker.shared.stop()
    }

    private func ensureModel() async throws {
        if !LocalGemmaWorker.isAvailable { try await LocalGemmaInstaller.install() }
        let version = try await LocalGemmaWorker.shared.revision()
        if digest != version { digest = version; queryCache.removeAll() }
    }

    private func embed(_ texts: [String], background: Bool = false) async throws -> [[Float]] {
        try await LocalGemmaWorker.shared.text(texts, background: background)
    }
    private func build(generation current: Int) async {
        defer { if current == generation { job = nil } }
        do {
            let requested = roots
            await MainActor.run {
                let progress = SemanticProgress.shared
                if progress.rootPaths != requested { progress.ready = 0; progress.total = 0 }
                progress.rootPaths = requested
                progress.phase = .checking
            }
            try await ensureModel()
            guard current == generation, !Task.isCancelled, let space, let rawSpace else { return }
            let db = try AppDatabase.open()
            let timingKey = ScanTiming.key(stage: "semantic", model: space)
            var preferRaw = true
            var preferVisual = true
            while current == generation && !Task.isCancelled && ScanConfiguration.semanticEnabled() {
                if ScanControl.shared.isInteractiveWorkActive || ScanControl.shared.isHeavyModelActive {
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "优先响应搜索 · 稍后自动继续"
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                let snapshot = roots
                // Large-library bookkeeping must not occupy the actor that handles queries.
                let visualSpace = self.visualSpace
                let coverage = try await Task.detached(priority: .utility) {
                    let summary = Self.usesGemma ? (ready: 0, total: 0) : try db.embeddingCoverage(
                        spaceID: space, rootPaths: snapshot,
                        semanticMethods: Self.indexedSemanticMethods
                    )
                    let raw = try db.embeddingCoverage(
                        spaceID: rawSpace, rootPaths: snapshot, rawTextOnly: true,
                        includeAllTextKinds: Self.usesGemma
                    )
                    let visual = try visualSpace.map { try db.visualEmbeddingCoverage(spaceID: $0, rootPaths: snapshot) }
                    return (ready: summary.ready + raw.ready + (visual?.ready ?? 0),
                            total: summary.total + raw.total + (visual?.total ?? 0),
                            summaryPending: summary.ready < summary.total,
                            rawPending: raw.ready < raw.total,
                            visualPending: (visual?.ready ?? 0) < (visual?.total ?? 0))
                }.value
                guard current == generation, !Task.isCancelled else { return }
                await MainActor.run {
                    let progress = SemanticProgress.shared
                    progress.ready = coverage.ready
                    progress.total = coverage.total
                    progress.timingKey = timingKey
                    progress.text = "语义索引 \(coverage.ready)/\(coverage.total)"
                    progress.phase = coverage.ready == coverage.total ? .complete : .running
                }
                if coverage.ready == coverage.total {
                    await MainActor.run { SemanticProgress.shared.revision += 1 }
                    return
                }
                if ScanControl.shared.isPaused {
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "语义索引已暂停 · 继续后从剩余片段恢复"
                    }
                    return
                }
                if let reason = BackgroundResourcePolicy.pauseReason {
                    await MainActor.run {
                        SemanticProgress.shared.text = "语义索引已暂停 · \(reason)"
                        SemanticProgress.shared.phase = .paused
                    }
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let capacity = try await Task.detached(priority: .utility) {
                    try db.indexCapacity()
                }.value
                guard current == generation, !Task.isCancelled else { return }
                if ScanControl.shared.isInteractiveWorkActive { continue }
                if capacity.reachedSoftLimit,
                   !ScanConfiguration.allowsIndexGrowthBeyondSoftLimit() {
                    let used = Double(capacity.semanticVectorBytes) / 1_073_741_824
                    await MainActor.run {
                        SemanticProgress.shared.text = String(
                            format: "语义索引已暂停 · 向量 %.2f GB，达到 1.6 GB 软上限", used
                        )
                        SemanticProgress.shared.phase = .paused
                    }
                    return
                }
                if let visualSpace, coverage.visualPending,
                   (preferVisual || !coverage.rawPending && !coverage.summaryPending) {
                    let candidates = try await Task.detached(priority: .utility) {
                        try db.missingVisualEmbeddings(spaceID: visualSpace, rootPaths: snapshot, limit: 1)
                    }.value
                    if let chunk = candidates.first {
                        let started = ProcessInfo.processInfo.systemUptime
                        do {
                            let image = try await Task.detached(priority: .utility) {
                                try VisualEmbeddingInput.render(chunk)
                            }.value
                            defer { try? FileManager.default.removeItem(at: image) }
                            try Task.checkCancellation()
                            if ScanControl.shared.isInteractiveWorkActive || ScanControl.shared.isHeavyModelActive { continue }
                            let budget = chunk.kind == "visual_page" ? 1120 : 280
                            let vector = try await LocalGemmaWorker.shared.image([image.path], budget: budget, background: true)[0]
                            try Task.checkCancellation()
                            try db.putEmbedding(chunkID: chunk.id, spaceID: visualSpace,
                                                modelID: LocalGemmaWorker.modelID, modelVersion: digest!,
                                                vector: vector, rootPaths: snapshot,
                                                expectedContentHash: chunk.contentHash,
                                                featureType: "visual_embedding")
                            try db.clearVisualEmbeddingFailure(chunkID: chunk.id, spaceID: visualSpace)
                            ScanTiming.record(key: timingKey + ":visual", units: 1,
                                              seconds: ProcessInfo.processInfo.systemUptime - started)
                        } catch is CancellationError { continue }
                        catch DataLayerError.staleVersion { continue }
                        catch DataLayerError.missingChunk { continue }
                        catch {
                            if ScanControl.shared.isInteractiveWorkActive || ScanControl.shared.isHeavyModelActive { continue }
                            try db.recordVisualEmbeddingFailure(chunkID: chunk.id, spaceID: visualSpace,
                                                                rootPaths: snapshot, error: String(describing: error))
                        }
                        preferVisual = false
                        continue
                    }
                    if !coverage.rawPending && !coverage.summaryPending {
                        await MainActor.run {
                            SemanticProgress.shared.phase = .paused
                            SemanticProgress.shared.text = "部分视觉页面待重试 · 稍后继续"
                        }
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                }
                let targetRaw = coverage.rawPending && (preferRaw || !coverage.summaryPending)
                if !coverage.rawPending && !coverage.summaryPending {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let targetSpace = targetRaw ? rawSpace : space
                let chunks = try await Task.detached(priority: .utility) {
                    try db.missingEmbeddings(
                        spaceID: targetSpace, rootPaths: snapshot, limit: 8,
                        semanticMethods: targetRaw ? nil : Self.indexedSemanticMethods,
                        rawTextOnly: targetRaw, includeAllTextKinds: Self.usesGemma
                    )
                }.value
                guard current == generation, !Task.isCancelled else { return }
                if chunks.isEmpty {
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "部分片段暂不可处理 · 可点击检查重试"
                    }
                    return
                }
                let inputs = chunks.map { chunk in
                    if targetRaw { return String(chunk.text.prefix(2400)) }
                    let evidence = chunk.kind == "document"
                        ? [chunk.summary] + chunk.tags
                        : [chunk.summary, chunk.text] + chunk.tags
                    return String(evidence.filter { !$0.isEmpty }.joined(separator: "\n").prefix(2400))
                }
                let modelInputs = inputs.map { "title: none | text: " + $0 }
                let batchStarted = ProcessInfo.processInfo.systemUptime
                let vectors: [[Float]]
                do {
                    vectors = try await embed(modelInputs, background: true)
                } catch let error as URLError where error.code == .cancelled {
                    guard current == generation, !Task.isCancelled else { return }
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "优先响应搜索 · 稍后自动继续"
                    }
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                } catch {
                    if Self.usesGemma && (ScanControl.shared.isInteractiveWorkActive || ScanControl.shared.isHeavyModelActive) {
                        try await Task.sleep(nanoseconds: 200_000_000)
                        continue
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard current == generation && snapshot == roots else { return }
                for (chunk, vector) in zip(chunks, vectors) {
                    do {
                        try db.putEmbedding(chunkID: chunk.id, spaceID: targetSpace,
                                            modelID: LocalGemmaWorker.modelID,
                                            modelVersion: digest!, vector: vector,
                                            rootPaths: snapshot, expectedContentHash: chunk.contentHash)
                    } catch DataLayerError.staleVersion { continue }
                    catch DataLayerError.missingChunk { continue }
                }
                ScanTiming.record(key: timingKey, units: chunks.count,
                                  seconds: ProcessInfo.processInfo.systemUptime - batchStarted)
                preferRaw.toggle()
                preferVisual = true
            }
        } catch is CancellationError { }
        catch {
            guard current == generation else { return }
            retryAfter = Date(timeIntervalSinceNow: 30)
            AppLog.write("local-semantic: \(error)")
            let message = error is SemanticError ? "本地模型未就绪 · 请检查安装" : "语义索引暂停 · 可点击检查重试"
            await MainActor.run {
                SemanticProgress.shared.text = message
                SemanticProgress.shared.phase = .unavailable
            }
        }
    }
    /// Opening the panel loads the model, so the first typed query is not the one that waits for it.
    /// Leaves the selected roots and any running index job untouched.
    func warmUp() async {
        guard ScanConfiguration.semanticEnabled() else { return }
        guard (try? await ensureModel()) != nil else { return }
        _ = try? await embed(["task: search result | query: 预热"])
    }

    /// Diagnostics can query existing vectors without scheduling indexing or scanning.
    func prepareSearch(roots requested: [String]) async throws {
        let audit = ArchitectureAuditTrace.begin("semantic_prepare")
        defer { audit?.end() }
        let requested = requested.sorted()
        if roots != requested {
            generation += 1
            job?.cancel()
            job = nil
            roots = requested
        }
        try await ensureModel()
    }

    /// Explicit opt-in only: never scheduled by the V1 indexer or used by its search lanes.
    func indexDeepScan(roots requested: [String]) async throws -> DeepScanIndexReport {
        guard LocalGemmaWorker.isAvailable else { throw GemmaError.notInstalled }
        let revision = try await LocalGemmaWorker.shared.revision()
        let deepSpace = "gemma2:" + revision + ":deepscan-summary-v1"
        let db = try AppDatabase.open()
        let inputs = try db.deepScanEmbeddingInputs(
            spaceID: deepSpace, legacySpaceID: "gemma2:" + revision + ":understanding-v1",
            modelID: LocalGemmaWorker.modelID, modelVersion: revision,
            dimensions: LocalGemmaWorker.dimensions, rootPaths: requested)
        var generated = 0
        var reused = 0
        var failures: [String] = []
        func store(_ chunk: ChunkResult, _ vector: [Float]) throws {
            try db.putEmbedding(chunkID: chunk.id, spaceID: deepSpace,
                                modelID: LocalGemmaWorker.modelID, modelVersion: revision,
                                vector: vector, rootPaths: requested, expectedContentHash: chunk.contentHash)
        }
        // understanding-v1 used this same document summary + tags prompt, model and content hash.
        for input in inputs where !input.indexed && input.vector != nil {
            try Task.checkCancellation()
            do { try store(input.chunk, input.vector!); reused += 1 }
            catch { failures.append(input.chunk.path + ": " + String(describing: error)) }
        }
        let missing = inputs.filter { !$0.indexed && $0.vector == nil }
        for offset in stride(from: 0, to: missing.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(missing[offset..<min(offset + 4, missing.count)])
            let texts = batch.map { input in
                let evidence = ([input.chunk.summary] + input.chunk.tags).filter { !$0.isEmpty }
                return "title: none | text: " + String(evidence.joined(separator: "\n").prefix(2400))
            }
            do {
                let vectors = try await LocalGemmaWorker.shared.text(texts)
                for (input, vector) in zip(batch, vectors) {
                    do { try store(input.chunk, vector); generated += 1 }
                    catch { failures.append(input.chunk.path + ": " + String(describing: error)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures += batch.map { $0.chunk.path + ": " + String(describing: error) }
            }
        }
        return DeepScanIndexReport(space: deepSpace, total: inputs.count, generated: generated,
                                   reused: reused, skipped: inputs.filter(\.indexed).count, failures: failures)
    }

    /// Independent cosine Top K. No V1 lanes, fusion, display thresholds or reranker are involved.
    func searchDeepScan(query: String, roots requested: [String], topK: Int,
                        readOnly: Bool = false) async throws -> [ChunkResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, topK > 0 else { return [] }
        guard LocalGemmaWorker.isAvailable else { throw GemmaError.notInstalled }
        let revision = try await LocalGemmaWorker.shared.revision()
        let deepSpace = "gemma2:" + revision + ":deepscan-summary-v1"
        let db = try AppDatabase.open(readOnly: readOnly)
        let eligible = try db.deepScanEmbeddingInputs(
            spaceID: deepSpace, legacySpaceID: "gemma2:" + revision + ":understanding-v1",
            modelID: LocalGemmaWorker.modelID, modelVersion: revision,
            dimensions: LocalGemmaWorker.dimensions, rootPaths: requested)
        let ids = Set(eligible.filter(\.indexed).map { $0.chunk.id })
        guard !ids.isEmpty else { return [] }
        let key = "gemma2:" + revision + ":understanding-v1:" + query
        let vector: [Float]
        if let cached = queryCache[key] {
            vector = cached
        } else {
            vector = try await LocalGemmaWorker.shared.text(["task: search result | query: " + String(query.prefix(1000))])[0]
            if queryCache.count >= 64 { queryCache.removeAll() }
            queryCache[key] = vector
        }
        try Task.checkCancellation()
        return Array(try db.searchVector(vector, spaceID: deepSpace, rootPaths: requested,
                                        limit: eligible.count).filter { ids.contains($0.id) }.prefix(topK))
            .map { $0.from("deepscan") }
    }

    /// Keep the first pass recall-oriented; the caller selects the display threshold.
    func search(query: String, roots requested: [String], minScore: Double = 0.50,
                candidateLimit: Int? = nil) async -> [ChunkResult] {
        await searchProfiled(query: query, roots: requested, minScore: minScore, candidateLimit: candidateLimit).results
    }

    func search(imageURL: URL, roots requested: [String]) async throws -> [ChunkResult] {
        guard Self.usesGemma else { return [] }
        try await ensureModel()
        guard let visualSpace else { return [] }
        let image = try await Task.detached(priority: .userInitiated) {
            try VisualEmbeddingInput.renderQuery(imageURL)
        }.value
        defer { try? FileManager.default.removeItem(at: image) }
        let vector = try await LocalGemmaWorker.shared.image([image.path], budget: 280)[0]
        let db = try AppDatabase.open()
        return try db.searchVectorProfiled(vector, spaceID: visualSpace, rootPaths: requested,
                                           limit: 120, featureType: "visual_embedding").matches
            .map { $0.from("visual") }
    }

    func searchProfiled(
        query: String, roots requested: [String], minScore: Double = 0.50, candidateLimit: Int? = nil
    ) async -> SemanticSearchProfile {
        let audit = ArchitectureAuditTrace.begin("semantic_total")
        defer { audit?.end() }
        let totalStarted = ProcessInfo.processInfo.systemUptime
        guard ScanConfiguration.semanticEnabled() else {
            return emptyProfile(startedAt: totalStarted, error: "semantic models disabled")
        }
        guard requested.sorted() == roots else {
            return emptyProfile(startedAt: totalStarted, error: "semantic roots changed")
        }
        guard let space, let rawSpace else {
            return emptyProfile(startedAt: totalStarted, error: "semantic model space unavailable")
        }
        guard !query.isEmpty else {
            return emptyProfile(startedAt: totalStarted, error: "empty semantic query")
        }
        do {
            let key = space + ":" + query
            let vector: [Float]
            let cacheHit: Bool
            let embeddingStarted = ProcessInfo.processInfo.systemUptime
            if let cached = queryCache[key] {
                vector = cached
                cacheHit = true
            } else {
                let instruction = "task: search result | query: "
                vector = try await embed([instruction + String(query.prefix(1000))])[0]
                if queryCache.count >= 64 { queryCache.removeAll() }
                queryCache[key] = vector
                cacheHit = false
            }
            let embeddingMilliseconds =
                (ProcessInfo.processInfo.systemUptime - embeddingStarted) * 1_000
            try Task.checkCancellation()
            guard requested.sorted() == roots else {
                return emptyProfile(startedAt: totalStarted, error: "semantic roots changed")
            }
            let db = try AppDatabase.open()
            let auditSummary = ArchitectureAuditTrace.begin("vector_summary")
            let vectorOutput = Self.usesGemma ? Self.emptyVectorOutput() : try db.searchVectorProfiled(
                vector, spaceID: space, rootPaths: requested, limit: candidateLimit ?? 80
            )
            auditSummary?.end(count: vectorOutput.matches.count, fields: Self.auditFields(vectorOutput.diagnostics))
            let auditRaw = ArchitectureAuditTrace.begin("vector_raw")
            let rawOutput = try db.searchVectorProfiled(
                vector, spaceID: rawSpace, rootPaths: requested, limit: candidateLimit ?? 160,
                v1RawTextOnly: Self.usesGemma
            )
            auditRaw?.end(count: rawOutput.matches.count, fields: Self.auditFields(rawOutput.diagnostics))
            let auditVisual = ArchitectureAuditTrace.begin("vector_visual")
            let visualOutput = Self.usesGemma && visualSpace != nil
                ? try db.searchVectorProfiled(vector, spaceID: visualSpace!, rootPaths: requested,
                                              limit: candidateLimit ?? 120, featureType: "visual_embedding") : nil
            auditVisual?.end(count: visualOutput?.matches.count ?? 0,
                             fields: visualOutput.map { Self.auditFields($0.diagnostics) } ?? [:])
            let thresholdStarted = ProcessInfo.processInfo.systemUptime
            let auditFusion = ArchitectureAuditTrace.begin("semantic_file_dedup_rrf")
            let summary = vectorOutput.matches
            let rawAboveThreshold = rawOutput.matches
            var rawPerFile: [String: Int] = [:]
            let raw = rawAboveThreshold.filter { chunk in
                guard rawPerFile[chunk.path, default: 0] < 2 else { return false }
                rawPerFile[chunk.path, default: 0] += 1
                return true
            }
            let lanes = [summary.map { $0.from("summary") }, raw.map { $0.from("raw_text") },
                         (visualOutput?.matches ?? []).map { $0.from("visual") }]
            let paths = RankFusion.fuse(lanes.map { $0.map(\.path) }, limit: candidateLimit ?? 120)
            let accepted = paths.flatMap { path in
                lanes.compactMap { lane in lane.first(where: { $0.path == path }) }
            }
            let summaryDiagnostics = vectorOutput.diagnostics
            let rawDiagnostics = rawOutput.diagnostics
            let visualDiagnostics = visualOutput?.diagnostics
            let diagnostics = VectorSearchDiagnostics(
                scannedVectors: summaryDiagnostics.scannedVectors + rawDiagnostics.scannedVectors + (visualDiagnostics?.scannedVectors ?? 0),
                connectionWaitMilliseconds: summaryDiagnostics.connectionWaitMilliseconds + rawDiagnostics.connectionWaitMilliseconds + (visualDiagnostics?.connectionWaitMilliseconds ?? 0),
                metadataReadMilliseconds: summaryDiagnostics.metadataReadMilliseconds + rawDiagnostics.metadataReadMilliseconds + (visualDiagnostics?.metadataReadMilliseconds ?? 0),
                candidateReadMilliseconds: summaryDiagnostics.candidateReadMilliseconds + rawDiagnostics.candidateReadMilliseconds + (visualDiagnostics?.candidateReadMilliseconds ?? 0),
                cosineMilliseconds: summaryDiagnostics.cosineMilliseconds + rawDiagnostics.cosineMilliseconds + (visualDiagnostics?.cosineMilliseconds ?? 0),
                detailReadMilliseconds: summaryDiagnostics.detailReadMilliseconds + rawDiagnostics.detailReadMilliseconds + (visualDiagnostics?.detailReadMilliseconds ?? 0),
                totalMilliseconds: summaryDiagnostics.totalMilliseconds + rawDiagnostics.totalMilliseconds + (visualDiagnostics?.totalMilliseconds ?? 0),
                highestScore: accepted.first?.score,
                lowestTopScore: [summaryDiagnostics.lowestTopScore, rawDiagnostics.lowestTopScore, visualDiagnostics?.lowestTopScore]
                    .compactMap { $0 }.min()
            )
            auditFusion?.end(count: accepted.count, fields: ["query_cache_hit": cacheHit])
            let thresholdMilliseconds =
                (ProcessInfo.processInfo.systemUptime - thresholdStarted) * 1_000
            SearchRuleAblationDiagnostics.lanes(query: query, vector: vector,
                summary: vectorOutput.matches, raw: rawOutput.matches, rawTopTwo: raw,
                visual: visualOutput?.matches ?? [], accepted: accepted)
            return SemanticSearchProfile(
                results: accepted,
                embeddingMilliseconds: embeddingMilliseconds,
                vectorDiagnostics: diagnostics,
                thresholdMilliseconds: thresholdMilliseconds,
                totalMilliseconds:
                    (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000,
                queryVectorCacheHit: cacheHit,
                topKBeforeThreshold: vectorOutput.matches.count + rawOutput.matches.count + (visualOutput?.matches.count ?? 0),
                topKRejectedByThreshold: vectorOutput.matches.count + rawOutput.matches.count
                    - summary.count - rawAboveThreshold.count,
                highestScore: diagnostics.highestScore,
                lowestAcceptedScore: accepted.last?.score,
                error: nil
            )
        } catch {
            let message = String(describing: error)
            AppLog.write("local-semantic-search: \(message)")
            return emptyProfile(startedAt: totalStarted, error: message)
        }
    }

    private static func auditFields(_ d: VectorSearchDiagnostics) -> [String: Any] {
        ["scanned": d.scannedVectors, "sql_connection_wait_ms": d.connectionWaitMilliseconds,
         "metadata_ms": d.metadataReadMilliseconds, "vector_read_ms": d.candidateReadMilliseconds,
         "cosine_ms": d.cosineMilliseconds, "detail_sql_ms": d.detailReadMilliseconds]
    }

    private static func emptyVectorOutput() -> VectorSearchOutput {
        VectorSearchOutput(matches: [], diagnostics: VectorSearchDiagnostics(
            scannedVectors: 0, connectionWaitMilliseconds: 0, metadataReadMilliseconds: 0,
            candidateReadMilliseconds: 0, cosineMilliseconds: 0, detailReadMilliseconds: 0,
            totalMilliseconds: 0, highestScore: nil, lowestTopScore: nil
        ))
    }

    private func emptyProfile(startedAt: TimeInterval, error: String) -> SemanticSearchProfile {
        SemanticSearchProfile(
            results: [], embeddingMilliseconds: 0, vectorDiagnostics: nil,
            thresholdMilliseconds: 0,
            totalMilliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            queryVectorCacheHit: false, topKBeforeThreshold: 0,
            topKRejectedByThreshold: 0, highestScore: nil,
            lowestAcceptedScore: nil, error: error
        )
    }
    enum SemanticError: Error { case notInstalled, badResponse }
}
