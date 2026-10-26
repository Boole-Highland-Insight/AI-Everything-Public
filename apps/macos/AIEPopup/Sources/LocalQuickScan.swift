import Foundation

/// Dedicated loopback-only vision client for background QuickScan.
/// Uses the private Ollama runtime for background vision understanding.
actor LocalQuickScan {
    static let shared = LocalQuickScan()
    static let preferredModel = "qwen3-vl:8b-instruct-q4_K_M"
    private static let legacyModel = "qwen2.5vl:7b-q4_K_M"
    private static let bundledModels = [
        preferredModel, legacyModel, "qwen3-vl:2b-instruct-q4_K_M",
        "qwen3-vl:4b-instruct-q4_K_M",
    ]
    /// Pinned manifest digests; a download that does not match them is rejected.
    private static let pinnedDigests = [
        "qwen3-vl:2b-instruct-q4_K_M": "ea422f1e73652a95479954d8572d3c8c6022f628ce2d38a1a04aae1b7f2d5300",
        "qwen3-vl:4b-instruct-q4_K_M": "ee4b975b58c17ce268cd19d40db35d5edc64603035d2ffc1fee1968eb0947f7b",
        "qwen3-vl:8b-instruct-q4_K_M": "0533d74300e4f9bc367d675d4e64ffd073d50ff16a2b4096cc2e8a1cf8c96319",
    ]
    static func pinnedDigest(_ model: String) -> String? { pinnedDigests[model] }
    private static let selectionLock = NSLock()
    private static var selectedModel = ScanConfiguration.selectedVisionModel() ?? (
        [UserDefaults.standard.string(forKey: "aie.localScan.model")].compactMap { $0 }
        + LocalModelLibrary.compatibleVisionModels().map(\.name)
        + bundledModels
    ).first { isCompatible($0) && LocalModelLibrary.isAvailable($0) } ?? preferredModel
    static var model: String {
        selectionLock.lock(); defer { selectionLock.unlock() }
        return selectedModel
    }
    static var displayName: String { displayName(for: model) }
    static func displayName(for model: String) -> String {
        if model.lowercased().hasPrefix("qwen3.5:") { return "Qwen3.5 \(model.split(separator: ":").last ?? "")" }
        if model == legacyModel { return "Qwen2.5-VL 7B" }
        if model.contains(":2b-") { return "Qwen3-VL 2B Instruct" }
        if model.contains(":4b-") { return "Qwen3-VL 4B Instruct" }
        return "Qwen3-VL 8B Instruct"
    }
    static func isCompatible(_ model: String) -> Bool {
        let name = model.lowercased()
        return bundledModels.contains(model) || name.hasPrefix("qwen3.5:")
    }
    private static func select(_ model: String) {
        selectionLock.lock(); defer { selectionLock.unlock() }
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "aie.localScan.model")
    }
    // Actor methods are reentrant while awaiting HTTP. Serialize inference, unload and model
    // activation so a download cannot switch the model halfway through an existing request.
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
    func activate(_ model: String) async -> Bool {
        guard Self.isCompatible(model), Self.isInstalled(model) else { return false }
        await acquire(); defer { release() }
        if model != Self.model { await unloadCurrent(); modelDigest = nil }
        Self.select(model)
        return true
    }
    static let endpoint = URL(string: "http://" + AIEApplicationPaths.ollamaHost)!

    private var process: Process?
    private var modelDigest: String?
    struct Completion {
        let content: String
        let model: String
        let digest: String
    }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 720
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static var directory: URL {
        AIEApplicationPaths.support.appendingPathComponent("Semantic")
    }

    nonisolated static var isInstalled: Bool { LocalModelLibrary.isInstalled(model) }

    nonisolated static func isInstalled(_ candidate: String) -> Bool {
        LocalModelLibrary.isInstalled(candidate)
    }

    /// Installed privately, or present in another Ollama installation this Mac already has.
    nonisolated static func isAvailable(_ candidate: String) -> Bool {
        LocalModelLibrary.isAvailable(candidate)
    }

    /// Unload only the vision model; never start a runtime just to release memory.
    func unload() async {
        await acquire(); defer { release() }
        await unloadCurrent()
    }

    /// Cancel only requests owned by the deep scanner's private session. The scanner detects
    /// the interaction revision and returns the interrupted file to its queue.
    func interruptForInteractiveWork() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    private func unloadCurrent() async {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.model, "keep_alive": 0])
        do {
            let (_, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode != 200 {
                AppLog.write("local-quickscan: unload failed; idle expiry remains active")
            }
        } catch {
            AppLog.write("local-quickscan: unload unavailable; idle expiry remains active")
        }
    }

    /// `schema` overrides the deep-scan response shape for callers with a different contract.
    func complete(system: String, user: String, images: [Data], maxTokens: Int,
                  schema: [String: Any]? = nil,
                  allowDuringInteractiveWork: Bool = false,
                  contextTokens: Int = 8192, keepAlive: String = "30s") async -> Completion? {
        let auditID = ArchitectureAuditTrace.enabled ? (ArchitectureAuditTrace.traceID ?? UUID().uuidString) : nil
        let auditQueue = ArchitectureAuditTrace.begin("vision_llm_queue", id: auditID)
        await acquire(); defer { release() }
        auditQueue?.end()
        let auditCall = ArchitectureAuditTrace.begin("vision_llm_total", id: auditID)
        defer { auditCall?.end(count: images.count, fields: ["max_tokens": maxTokens, "context_tokens": contextTokens]) }
        guard !Task.isCancelled, ScanConfiguration.visionEnabled(),
              allowDuringInteractiveWork || !ScanControl.shared.isInteractiveWorkActive else { return nil }
        if LocalSemanticIndex.usesGemma {
            let handoff = ArchitectureAuditTrace.begin("vision_llm_gemma_unload", id: auditID)
            ScanControl.shared.setHeavyModelActive(true)
            await LocalSemanticIndex.shared.unload()
            handoff?.end()
        }
        defer { if LocalSemanticIndex.usesGemma { ScanControl.shared.setHeavyModelActive(false) } }
        do {
            guard allowDuringInteractiveWork || !ScanControl.shared.isInteractiveWorkActive else { return nil }
            let auditReady = ArchitectureAuditTrace.begin("vision_llm_runtime_ready", id: auditID)
            try await ensureReady()
            auditReady?.end()
            guard let digest = modelDigest else { return nil }
            var userMessage: [String: Any] = ["role": "user", "content": user]
            if !images.isEmpty {
                userMessage["images"] = images.prefix(4).map { $0.base64EncodedString() }
            }
            let format: [String: Any] = schema ?? [
                "type": "object",
                "properties": [
                    "blurb_zh": [
                        "type": "string",
                        "description": "一到三句基于明确证据的中文摘要，不重复关键词",
                    ],
                    "keywords_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 6,
                        "maxItems": 10,
                    ],
                    "topics_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 1,
                        "maxItems": 5,
                    ],
                    "entities_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 12,
                    ],
                    "evidence_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "minItems": 1,
                        "maxItems": 6,
                    ],
                    "content_type_zh": ["type": "string"],
                    "completion_state": [
                        "type": "string",
                        "enum": ["complete", "unfinished", "unknown"],
                    ],
                    "completion_confidence": [
                        "type": "number",
                        "minimum": 0,
                        "maximum": 1,
                    ],
                    "completion_evidence_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 4,
                    ],
                    "missing_parts_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 4,
                    ],
                    "reuse_action": [
                        "type": "string",
                        "enum": ["none", "continue", "complete", "polish", "recreate"],
                    ],
                    "reuse_reason_zh": ["type": "string"],
                    "reuse_confidence": [
                        "type": "number",
                        "minimum": 0,
                        "maximum": 1,
                    ],
                    "scene_zh": ["type": "string"],
                    "objects_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 12,
                    ],
                    "actions_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 8,
                    ],
                    "visible_text_zh": [
                        "type": "array",
                        "items": ["type": "string"],
                        "maxItems": 12,
                    ],
                ],
                "required": [
                    "blurb_zh", "keywords_zh", "topics_zh", "entities_zh",
                    "evidence_zh", "content_type_zh", "completion_state",
                    "completion_confidence", "completion_evidence_zh", "missing_parts_zh",
                    "reuse_action", "reuse_reason_zh", "reuse_confidence",
                    "scene_zh", "objects_zh", "actions_zh", "visible_text_zh",
                ],
                "additionalProperties": false,
            ]
            let payload: [String: Any] = [
                "model": Self.model,
                "stream": false,
                "format": format,
                // Scans stay warm for 30s. Search passes 0s so the 8B does not sit beside the embedding model.
                "keep_alive": LocalSemanticIndex.usesGemma ? "0s" : keepAlive,
                "messages": [
                    ["role": "system", "content": system],
                    userMessage,
                ],
                "options": [
                    "temperature": 0,
                    "num_predict": maxTokens,
                    "num_ctx": contextTokens,
                ],
            ]
            var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            // Background file analysis must yield while the user searches. Foreground search
            // planning and verification use the same local model and explicitly opt in here.
            guard allowDuringInteractiveWork || !ScanControl.shared.isInteractiveWorkActive else { return nil }
            let auditHTTP = ArchitectureAuditTrace.begin("vision_llm_http", id: auditID)
            var auditHTTPFinished = false
            defer { if !auditHTTPFinished { auditHTTP?.end(count: images.count, fields: ["completed": false]) } }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["done"] as? Bool == true,
                  let actualModel = object["model"] as? String, actualModel == Self.model,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.isEmpty
            else {
                AppLog.write("local-quickscan: invalid response")
                return nil
            }
            var durations: [String: Any] = [:]
            for key in ["total_duration", "load_duration", "prompt_eval_duration", "eval_duration",
                        "prompt_eval_count", "eval_count"] {
                if let value = object[key] as? NSNumber { durations[key] = value }
            }
            auditHTTP?.end(count: images.count, fields: durations)
            auditHTTPFinished = true
            guard (try? await hasModel()) == true, modelDigest == digest else { return nil }
            return Completion(content: content, model: actualModel, digest: digest)
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.write("local-quickscan: \(error)")
            return nil
        }
    }

    private func ensureReady() async throws {
        guard Self.isInstalled else { throw LocalQuickScanError.notInstalled }
        // A refused connection means the private service needs starting, not that scanning failed.
        if (try? await hasModel()) == true { return }

        let executable = Self.directory.appendingPathComponent("bin/ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalQuickScanError.notInstalled
        }
        if process?.isRunning != true {
            let child = Process()
            child.executableURL = executable
            child.arguments = ["serve"]
            var environment = ProcessInfo.processInfo.environment
            environment["OLLAMA_HOST"] = AIEApplicationPaths.ollamaHost
            environment["OLLAMA_MODELS"] = Self.directory.appendingPathComponent("models").path
            environment["OLLAMA_NO_CLOUD"] = "1"
            environment["OLLAMA_NUM_PARALLEL"] = "1"
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try OwnedModelProcesses.run(child)
            process = child
        }
        for _ in 0..<30 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
            if (try? await hasModel()) == true { return }
        }
        throw LocalQuickScanError.unavailable
    }

    private func hasModel() async throws -> Bool {
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return false }
        guard let model = models.first(where: { ($0["name"] as? String) == Self.model }),
              let digest = model["digest"] as? String, !digest.isEmpty else { return false }
        modelDigest = digest
        return true
    }
}

private enum LocalQuickScanError: Error {
    case notInstalled
    case unavailable
}
