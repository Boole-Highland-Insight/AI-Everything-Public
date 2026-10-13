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
    static let model = LocalScanPlan.embeddingModel
    static let endpoint = URL(string: "http://127.0.0.1:11435")!
    /// Ollama unloads idle models, and reloading cost ~1.4s on the first keystroke after a pause.
    /// The search model stays resident instead, holding 1.7-2.4 GB depending on KV cache use.
    private static let keepAlive = -1
    private var process: Process?
    private var roots: [String] = []
    private var job: Task<Void, Never>?
    private var generation = 0
    private var digest: String?
    private var queryCache: [String: [Float]] = [:]
    private var retryAfter = Date.distantPast
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private var space: String? { digest.map { "ollama:qwen3-embedding:0.6b:" + $0 + ":evidence-v1" } }
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Everything/Semantic")
    }
    func indexNow(roots requested: [String]) async -> Bool {
        update(roots: requested)
        let active = job
        await active?.value
        guard let space, let coverage = try? AppDatabase.open().embeddingCoverage(spaceID: space, rootPaths: requested) else { return false }
        return coverage.total > 0 && coverage.ready == coverage.total
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
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
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
        _ = try? await request("api/generate", body: ["model": Self.model, "keep_alive": 0])
    }

    private func request(_ route: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(route))
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else { request.timeoutInterval = 2 }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
        return object
    }
    private func ensureModel() async throws {
        if digest != nil { return }
        do { try await readModel() }
        catch {
            let executable = Self.directory.appendingPathComponent("bin/ollama")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SemanticError.notInstalled }
            if process?.isRunning != true {
                let child = Process(); child.executableURL = executable; child.arguments = ["serve"]
                var environment = ProcessInfo.processInfo.environment
                environment["OLLAMA_HOST"] = "127.0.0.1:11435"
                environment["OLLAMA_MODELS"] = Self.directory.appendingPathComponent("models").path
                environment["OLLAMA_NO_CLOUD"] = "1"
                environment["OLLAMA_NUM_PARALLEL"] = "1"
                child.environment = environment
                child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try OwnedModelProcesses.run(child); process = child
            }
            for _ in 0..<15 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
                if (try? await readModel()) != nil { return }
            }
            throw SemanticError.notInstalled
        }
    }
    private func readModel() async throws {
        let object = try await request("api/tags")
        guard let models = object["models"] as? [[String: Any]],
              let model = models.first(where: { $0["name"] as? String == Self.model }),
              let version = model["digest"] as? String, !version.isEmpty else { throw SemanticError.notInstalled }
        if digest != version {
            digest = version
            queryCache.removeAll()
        }
    }
    private func embed(_ texts: [String]) async throws -> [[Float]] {
        let expected = digest
        try await readModel()
        guard digest == expected else { queryCache.removeAll(); throw SemanticError.badResponse }
        let object = try await request("api/embed", body: ["model": Self.model, "input": texts, "truncate": false,
            // Smaller evaluation batches reduce scratch memory without truncating inputs.
            "keep_alive": Self.keepAlive, "options": ["num_ctx": 8192, "num_batch": 128]])
        guard let vectors = object["embeddings"] as? [[NSNumber]], vectors.count == texts.count else { throw SemanticError.badResponse }
        try await readModel()
        guard digest == expected else { queryCache.removeAll(); throw SemanticError.badResponse }
        let result = vectors.map { $0.map(\.floatValue) }
        guard result.allSatisfy({ $0.count == 1024 && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) }) else { throw SemanticError.badResponse }
        return result
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
            guard current == generation, !Task.isCancelled, let space else { return }
            let db = try AppDatabase.open()
            let timingKey = ScanTiming.key(stage: "semantic", model: space)
            while current == generation && !Task.isCancelled && ScanConfiguration.semanticEnabled() {
                let snapshot = roots
                let coverage = try db.embeddingCoverage(spaceID: space, rootPaths: snapshot)
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
                let capacity = try db.indexCapacity(spaceID: space)
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
                let chunks = try db.missingEmbeddings(spaceID: space, rootPaths: snapshot, limit: 8)
                if chunks.isEmpty {
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "部分片段暂不可处理 · 可点击检查重试"
                    }
                    return
                }
                let inputs = chunks.map { String(($0.tags + [$0.text, $0.summary]).joined(separator: "\n").prefix(2400)) }
                let batchStarted = ProcessInfo.processInfo.systemUptime
                let vectors: [[Float]]
                do {
                    vectors = try await embed(inputs)
                } catch let error as URLError where error.code == .cancelled {
                    guard current == generation, !Task.isCancelled else { return }
                    await MainActor.run {
                        SemanticProgress.shared.phase = .paused
                        SemanticProgress.shared.text = "优先响应搜索 · 稍后自动继续"
                    }
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                try Task.checkCancellation()
                guard current == generation && snapshot == roots else { return }
                for (chunk, vector) in zip(chunks, vectors) {
                    do {
                        try db.putEmbedding(chunkID: chunk.id, spaceID: space, modelID: Self.model, modelVersion: digest!, vector: vector,
                                            rootPaths: snapshot, expectedContentHash: chunk.contentHash)
                    } catch DataLayerError.staleVersion { continue }
                    catch DataLayerError.missingChunk { continue }
                }
                ScanTiming.record(key: timingKey, units: chunks.count,
                                  seconds: ProcessInfo.processInfo.systemUptime - batchStarted)
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
        _ = try? await embed(["预热"])
    }

    /// Diagnostics can query existing vectors without scheduling indexing or scanning.
    func prepareSearch(roots requested: [String]) async throws {
        roots = requested.sorted()
        try await ensureModel()
    }

    /// `minScore` is lowered only by the fallback pass, which has a model to filter the extra noise.
    func search(query: String, roots requested: [String], minScore: Double = 0.52) async -> [ChunkResult] {
        await searchProfiled(query: query, roots: requested, minScore: minScore).results
    }

    func searchProfiled(
        query: String, roots requested: [String], minScore: Double = 0.52
    ) async -> SemanticSearchProfile {
        let totalStarted = ProcessInfo.processInfo.systemUptime
        guard ScanConfiguration.semanticEnabled() else {
            return emptyProfile(startedAt: totalStarted, error: "semantic models disabled")
        }
        guard requested.sorted() == roots else {
            return emptyProfile(startedAt: totalStarted, error: "semantic roots changed")
        }
        guard let space else {
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
                let instruction = "Instruct: Given a file search query, retrieve relevant document passages or image descriptions.\nQuery: "
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
            let vectorOutput = try AppDatabase.open().searchVectorProfiled(
                vector, spaceID: space, rootPaths: requested, limit: 80
            )
            let thresholdStarted = ProcessInfo.processInfo.systemUptime
            let accepted = vectorOutput.matches.filter { $0.score >= minScore }
            let thresholdMilliseconds =
                (ProcessInfo.processInfo.systemUptime - thresholdStarted) * 1_000
            return SemanticSearchProfile(
                results: accepted,
                embeddingMilliseconds: embeddingMilliseconds,
                vectorDiagnostics: vectorOutput.diagnostics,
                thresholdMilliseconds: thresholdMilliseconds,
                totalMilliseconds:
                    (ProcessInfo.processInfo.systemUptime - totalStarted) * 1_000,
                queryVectorCacheHit: cacheHit,
                topKBeforeThreshold: vectorOutput.matches.count,
                topKRejectedByThreshold: vectorOutput.matches.count - accepted.count,
                highestScore: vectorOutput.diagnostics.highestScore,
                lowestAcceptedScore: accepted.last?.score,
                error: nil
            )
        } catch {
            let message = String(describing: error)
            AppLog.write("local-semantic-search: \(message)")
            return emptyProfile(startedAt: totalStarted, error: message)
        }
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
