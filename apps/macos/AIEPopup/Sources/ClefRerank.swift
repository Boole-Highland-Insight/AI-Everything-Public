import Foundation

/// Cloudflare Workers AI comparison client for the same candidate judgments used by Jev.
/// It is only used by the explicit search benchmark and never by the interactive search path.
enum ClefRerank {
    static let inputDollarsPerMillionTokensFlash = 0.09
    static let inputDollarsPerMillionTokensFull = 0.24
    private static let maxConcurrent = 6

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private static let stateLock = NSLock()
    private static var unauthorized = false

    static var lastError: String?
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
    static var hasCredentials: Bool { endpoint != nil && apiToken != nil }

    private static var accountID: String? {
        let value = ProcessInfo.processInfo.environment["CLOUDFLARE_ACCOUNT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return value
    }

    private static var apiToken: String? {
        let value = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static var model: String {
        let value = ProcessInfo.processInfo.environment["AIE_CLEF_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "clef" ? "clef" : "clef-flash"
    }

    private static var endpoint: URL? {
        guard let accountID else { return nil }
        return URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run/@cf/cloudflare/\(model)")
    }

    private static var inputDollarsPerMillionTokens: Double {
        model == "clef" ? inputDollarsPerMillionTokensFull : inputDollarsPerMillionTokensFlash
    }

    static func rerank(
        query: String, hits: [FileHit], files: [IndexedFile],
        limit: Int, excerptLimit: Int
    ) async -> JevRerank.Outcome {
        lastError = nil
        let candidates = Array(hits.prefix(limit))
        guard !candidates.isEmpty else {
            return JevRerank.Outcome(
                hits: hits, requests: 0, errors: 0, inputTokens: 0,
                outputTokens: 0, costUSD: 0, dropped: 0
            )
        }
        guard let endpoint, let token = apiToken else {
            lastError = "未配置 Cloudflare Account ID 或 Workers AI Token"
            return JevRerank.Outcome(
                hits: hits, requests: 0, errors: 0, inputTokens: 0,
                outputTokens: 0, costUSD: 0, dropped: 0
            )
        }

        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        var judgments = [JevRerank.Judgment?](repeating: nil, count: candidates.count)
        var requests = 0
        var errors = 0
        var inputTokens = 0
        var index = 0
        while index < candidates.count {
            if authorizationFailed { break }
            let end = min(index + maxConcurrent, candidates.count)
            let batch = await withTaskGroup(
                of: (Int, JevRerank.Judgment?, Int).self
            ) { group in
                for offset in index..<end {
                    let hit = candidates[offset]
                    group.addTask {
                        let result = await judge(
                            query: query, hit: hit, file: byPath[hit.path],
                            excerptLimit: excerptLimit, endpoint: endpoint, token: token
                        )
                        return (offset, result.judgment, result.inputTokens)
                    }
                }
                var collected: [(Int, JevRerank.Judgment?, Int)] = []
                for await item in group { collected.append(item) }
                return collected
            }
            for (offset, judgment, input) in batch {
                requests += 1
                inputTokens += input
                if let judgment { judgments[offset] = judgment } else { errors += 1 }
            }
            index = end
        }
        let ranked = JevRerank.ordered(candidates, judgments: judgments)
        return JevRerank.Outcome(
            hits: ranked + Array(hits.dropFirst(candidates.count)),
            requests: requests, errors: errors, inputTokens: inputTokens,
            outputTokens: 0,
            costUSD: Double(inputTokens) * inputDollarsPerMillionTokens / 1_000_000,
            dropped: 0
        )
    }

    private static func judge(
        query: String, hit: FileHit, file: IndexedFile?, excerptLimit: Int,
        endpoint: URL, token: String
    ) async -> (judgment: JevRerank.Judgment?, inputTokens: Int) {
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
        let body: [String: Any] = [
            "model": model,
            "state": [
                "query": String(query.prefix(500)),
                "candidate": candidate,
            ],
            "questions": JevRerank.questions(),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, 0)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        for attempt in 0..<2 {
            if authorizationFailed { return (nil, 0) }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    markUnauthorized()
                    lastError = "Cloudflare 拒绝了凭据（HTTP \(status)）"
                    return (nil, 0)
                }
                if status == 429 || (500...599).contains(status) {
                    if attempt == 0 { continue }
                    lastError = "Cloudflare Workers AI HTTP \(status)"
                    return (nil, 0)
                }
                guard status == 200,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["result"] as? [String: Any]
                else {
                    lastError = "Cloudflare Workers AI HTTP \(status)"
                    return (nil, 0)
                }
                let usage = result["usage"] as? [String: Any]
                let input = intValue(usage?["input_tokens"]) ?? 0
                guard let judgment = JevRerank.parseJudgment(result["answers"]) else {
                    lastError = "Clef 返回了无法读取的判断"
                    return (nil, input)
                }
                return (judgment, input)
            } catch {
                if attempt == 0 { continue }
                lastError = "Clef 请求失败"
                return (nil, 0)
            }
        }
        return (nil, 0)
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
