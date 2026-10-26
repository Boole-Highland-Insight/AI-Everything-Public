import Foundation

/// Cloud precision judge for candidates already retrieved locally.
/// Sends one chunk excerpt and its metadata per candidate. Never sends a whole file.
enum JevRerank {
    static let candidateLimit = 30
    private static let openRouterEndpoint = URL(string: "https://openrouter.ai/api/v1/systemone")!
    static var endpoint: URL {
        let raw = ProcessInfo.processInfo.environment["AIE_JEV_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty, let url = URL(string: raw) { return url }
        return openRouterEndpoint
    }
    static var usesLocalEndpoint: Bool {
        switch endpoint.host?.lowercased() {
        case "127.0.0.1", "localhost", "::1": return true
        default: return false
        }
    }
    private static let maxConcurrent = 6
    static let textLimit = 800
    private static let snippetLimit = 260
    /// Published input price: $0.042 per million tokens. Output tokens are not billed.
    static let inputDollarsPerMillionTokens = 0.042

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private static let stateLock = NSLock()
    private static var unauthorized = false

    static var lastError: String?
    static var hasKey: Bool { apiKey != nil }

    static var authorizationFailed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unauthorized
    }

    private static func markUnauthorized() {
        stateLock.lock()
        unauthorized = true
        stateLock.unlock()
    }

    private static var apiKey: String? { GroqClient.apiKey() }

    private static var model: String {
        let value = ProcessInfo.processInfo.environment["AIE_JEV_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return "typesafe/jev-1.13" }
        return value
    }

    /// The product uses all three judgments. Setting `AIE_JEV_PROMPT=2` is retained only
    /// for controlled comparisons with the earlier two-question prompt.
    private static var promptUsesRelevance: Bool {
        ProcessInfo.processInfo.environment["AIE_JEV_PROMPT"] != "2"
    }

    struct Outcome {
        let hits: [FileHit]
        let requests: Int
        let errors: Int
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
        let dropped: Int
    }

    struct Judgment {
        let evidence: Double
        let confidence: Double
        let material: String
        let relevance: Double?
        let rankScore: Double
    }

    static func rerank(
        query: String, hits: [FileHit], files: [IndexedFile], excerptLimit: Int = textLimit,
        dropSeriouslyIrrelevant: Bool = false
    ) async -> Outcome {
        lastError = nil
        let candidates = Array(hits.prefix(candidateLimit))
        guard !candidates.isEmpty else {
            return Outcome(hits: hits, requests: 0, errors: 0, inputTokens: 0, outputTokens: 0, costUSD: 0, dropped: 0)
        }
        guard usesLocalEndpoint || apiKey != nil else {
            lastError = "未配置 OpenRouter API Key"
            return Outcome(hits: hits, requests: 0, errors: 0, inputTokens: 0, outputTokens: 0, costUSD: 0, dropped: 0)
        }

        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var judgments = [Judgment?](repeating: nil, count: candidates.count)
        var requests = 0
        var errors = 0
        var inputTokens = 0
        var outputTokens = 0
        var costUSD = 0.0
        var index = 0
        while index < candidates.count {
            if authorizationFailed { break }
            let width = usesLocalEndpoint ? 1 : maxConcurrent
            let end = min(index + width, candidates.count)
            let batch = await withTaskGroup(of: (Int, Judgment?, Int, Int, Double).self) { group in
                for offset in index..<end {
                    let hit = candidates[offset]
                    group.addTask {
                        let judged = await judge(
                            query: query, hit: hit, file: byPath[hit.path], excerptLimit: excerptLimit
                        )
                        return (
                            offset, judged.judgment, judged.inputTokens,
                            judged.outputTokens, judged.costUSD
                        )
                    }
                }
                var collected: [(Int, Judgment?, Int, Int, Double)] = []
                for await item in group { collected.append(item) }
                return collected
            }
            for (offset, judgment, input, output, cost) in batch {
                requests += 1
                inputTokens += input
                outputTokens += output
                costUSD += cost
                if let judgment {
                    judgments[offset] = judgment
                } else {
                    errors += 1
                }
            }
            index = end
        }
        let ranked = ordered(
            candidates, judgments: judgments, dropSeriouslyIrrelevant: dropSeriouslyIrrelevant)
        return Outcome(
            hits: ranked + Array(hits.dropFirst(candidates.count)),
            requests: requests, errors: errors,
            inputTokens: inputTokens, outputTokens: outputTokens, costUSD: costUSD,
            dropped: candidates.count - ranked.count
        )
    }

    /// Evidence score is the rank. Material type only nudges it.
    /// A failed call keeps a prior from the original retrieval position.
    /// Seriously irrelevant possible hits can be removed. Direct hits and failed calls stay.
    static func ordered(
        _ hits: [FileHit], judgments: [Judgment?], dropSeriouslyIrrelevant: Bool = false
    ) -> [FileHit] {
        let count = hits.count
        let visible = hits.enumerated().filter { offset, hit in
            guard dropSeriouslyIrrelevant, hit.confidenceTier == .possible else { return true }
            guard judgments.indices.contains(offset), let judgment = judgments[offset] else { return true }
            return !isSeriouslyIrrelevant(judgment)
        }
        guard visible.count > 1 else { return visible.map(\.element) }
        return visible.sorted { left, right in
            let leftScore = judgments.indices.contains(left.offset)
                ? (judgments[left.offset]?.rankScore ?? prior(index: left.offset, count: count))
                : prior(index: left.offset, count: count)
            let rightScore = judgments.indices.contains(right.offset)
                ? (judgments[right.offset]?.rankScore ?? prior(index: right.offset, count: count))
                : prior(index: right.offset, count: count)
            if leftScore != rightScore { return leftScore > rightScore }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// A direct relevance rejection is decisive; legacy two-question judgments use material/evidence.
    static func isSeriouslyIrrelevant(_ judgment: Judgment) -> Bool {
        if let relevance = judgment.relevance, relevance < 0.5 { return true }
        return judgment.material == "irrelevant" && judgment.evidence < 1
    }

    static func rankScore(evidence: Double, material: String) -> Double {
        scoredRank(evidence: evidence, material: material, relevance: nil)
    }

    private static func scoredRank(
        evidence: Double, material: String, relevance: Double?
    ) -> Double {
        let evidence = min(4, max(0, evidence))
        guard let relevance else {
            switch material {
            case "irrelevant": return evidence * 0.2
            case "duplicate": return evidence - 0.3
            case "exact_evidence": return evidence + 0.4
            default: return evidence
            }
        }
        let clampedRelevance = min(1, max(0, relevance))
        switch material {
        case "irrelevant": return clampedRelevance * 0.2
        case "duplicate": return evidence + clampedRelevance - 0.3
        case "exact_evidence": return evidence + clampedRelevance + 0.4
        default: return evidence + clampedRelevance
        }
    }

    private static func prior(index: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return 2 * Double(count - index) / Double(count)
    }

    private static func judge(
        query: String, hit: FileHit, file: IndexedFile?, excerptLimit: Int = textLimit
    ) async -> (judgment: Judgment?, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        guard usesLocalEndpoint || (apiKey != nil && !authorizationFailed) else {
            return (nil, 0, 0, 0)
        }
        let chunk = file?.chunks.first { $0.id == hit.chunkID }
        let source = chunk?.text.isEmpty == false ? chunk!.text : hit.snippet
        let excerpt = String(source.prefix(excerptLimit))
        var candidate: [String: Any] = [
            "file": hit.relative,
            "kind": hit.kind.rawValue,
            "snippet": excerpt,
            "text": excerpt,
        ]
        if let page = hit.page { candidate["page"] = page }
        var body: [String: Any] = [
            "state": [
                "query": String(query.prefix(500)),
                "candidate": candidate,
            ],
            "questions": questions(),
        ]
        body["model"] = usesLocalEndpoint ? "open-jev" : model
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, 0, 0, 0)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = usesLocalEndpoint ? 25 : 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !usesLocalEndpoint {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload

        for attempt in 0..<2 {
            if authorizationFailed { return (nil, 0, 0, 0) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    markUnauthorized()
                    lastError = "OpenRouter 拒绝了密钥（HTTP \(status)）"
                    return (nil, 0, 0, 0)
                }
                if status == 429 || (500...599).contains(status) {
                    if attempt == 0 { continue }
                    lastError = "OpenRouter HTTP \(status)"
                    return (nil, 0, 0, 0)
                }
                guard status == 200,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    lastError = "OpenRouter HTTP \(status)"
                    return (nil, 0, 0, 0)
                }
                let usage = object["usage"] as? [String: Any]
                let input = intValue(usage?["input_tokens"]) ?? 0
                let output = intValue(usage?["output_tokens"]) ?? 0
                let cost = doubleValue(usage?["cost"])
                    ?? (Double(input) * inputDollarsPerMillionTokens / 1_000_000)
                guard let judgment = parseJudgment(object["answers"]) else {
                    lastError = "OpenRouter 返回了无法读取的 Jev 判断"
                    return (nil, input, output, cost)
                }
                return (judgment, input, output, cost)
            } catch {
                if attempt == 0 { continue }
                lastError = "OpenRouter 请求失败"
                return (nil, 0, 0, 0)
            }
        }
        return (nil, 0, 0, 0)
    }

    static func questions() -> [String: Any] {
        var questions: [String: Any] = [:]
        if promptUsesRelevance {
            questions["relevance"] = [
                "type": "noul",
                "instructions": "这个候选内容是否与用户 query 直接相关？",
                "criteria": [
                    "true": "内容对得上查询的对象、事件或问题，而不是只共享题材。",
                    "false": "内容只是题材相近、同目录邻居，或不能回答这个查询。",
                ],
            ]
        }
        let unrelated = promptUsesRelevance
            ? "无关"
            : "无关：只是题材相近、同目录邻居，或不能回答这个查询。"
        questions["evidence"] = [
            "type": "score",
            "instructions": "这段内容对用户 query 的证据强度有多高？",
            "criteria": [unrelated, "轻微相关", "有用背景", "直接相关", "核心证据"],
        ]
        questions["material"] = [
            "type": "choice",
            "instructions": "这段材料相对用户 query 属于哪一类？",
            "criteria": [
                "exact_evidence": "直接包含能回答查询的事实、数字、名称或结论。",
                "supporting_context": "有助于理解，但本身不是答案。",
                "duplicate": "与更直接的材料重复，或只是同一内容的弱副本。",
                "irrelevant": "不能支持这个查询。",
            ],
        ]
        return questions
    }

    static func parseJudgment(_ value: Any?) -> Judgment? {
        guard let answers = value as? [String: Any],
              let evidenceAnswer = answers["evidence"] as? [String: Any],
              let materialAnswer = answers["material"] as? [String: Any],
              let evidence = doubleValue(evidenceAnswer["score"]),
              let material = materialAnswer["choice"] as? String
        else { return nil }
        let relevance = promptUsesRelevance
            ? doubleValue((answers["relevance"] as? [String: Any])?["noul"])
            : nil
        if promptUsesRelevance, relevance == nil { return nil }
        let confidence = doubleValue(evidenceAnswer["confidence"])
            ?? doubleValue(materialAnswer["confidence"])
            ?? 0
        return Judgment(
            evidence: evidence,
            confidence: confidence,
            material: material,
            relevance: relevance,
            rankScore: scoredRank(evidence: evidence, material: material, relevance: relevance)
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }
}
