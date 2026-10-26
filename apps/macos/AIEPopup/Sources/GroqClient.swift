import Foundation

enum GroqClient {
    static var searchModel: String { APIConfiguration.Model.search.id }
    static var scanModel: String { APIConfiguration.Model.scan.id }
    static var scanFallbacks: [String] {
        scanModel == APIConfiguration.Model.scan.defaultID ? [
        "google/gemini-2.5-flash-lite",
        "qwen/qwen3.6-flash",
    ] : []
    }
    static var reuseModel: String { APIConfiguration.Model.reuse.id }
    static var reuseFallbacks: [String] {
        reuseModel == APIConfiguration.Model.reuse.defaultID ? [
        "anthropic/claude-sonnet-4.6",
        "openai/gpt-5.5",
        "google/gemini-3.1-pro-preview",
    ] : []
    }
    static var imageModel: String { APIConfiguration.Model.image.id }
    static var imageFallbacks: [String] {
        imageModel == APIConfiguration.Model.image.defaultID ? [
        "google/gemini-3.1-flash-image",
        "openai/gpt-5.4-image-2",
    ] : []
    }
    static let provider = "groq"

    private static let endpoint = APIConfiguration.chatEndpoint
    private static let imageEndpoint = APIConfiguration.imageEndpoint
    private static let keyDir = AIEApplicationPaths.isCleanV2
        ? AIEApplicationPaths.support
        : FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Everything", isDirectory: true)
    private static var keyFile: URL { keyDir.appendingPathComponent("openrouter.key") }

    static var lastError: String?

    static var hasKey: Bool { apiKey() != nil }

    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let raw = try? String(contentsOf: keyFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static var usesEnvironmentKey: Bool {
        !(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if trimmed.isEmpty {
                if FileManager.default.fileExists(atPath: keyFile.path) {
                    try FileManager.default.removeItem(at: keyFile)
                }
            } else {
                try trimmed.write(to: keyFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            }
            lastError = nil
            return true
        } catch {
            lastError = "无法保存 API Key，请检查当前用户的 Application Support 目录权限"
            return false
        }
    }

    @discardableResult
    static func clearKey() -> Bool { saveKey("") }

    static func complete(
        system: String,
        user: String,
        imageJPEGs: [Data] = [],
        maxTokens: Int,
        json: Bool,
        temperature: Double,
        slow: Bool,
        model: String = searchModel,
        pinGroq: Bool = true,
        allowFallback: Bool = false,
        fallbacks: [String] = [],
        onResponse: (@MainActor () -> Void)? = nil
    ) async -> String? {
        lastError = nil
        guard let key = apiKey() else {
            lastError = "未配置 OpenRouter"
            return nil
        }
        let session: URLSession
        if model == scanModel || fallbacks == scanFallbacks {
            session = scanSession
        } else if model == reuseModel || fallbacks == reuseFallbacks {
            session = reuseSession
        } else {
            session = slow ? slowSession : fastSession
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AI Everything", forHTTPHeaderField: "X-Title")
        request.setValue(APIConfiguration.projectURL, forHTTPHeaderField: "HTTP-Referer")
        let userContent: Any
        if imageJPEGs.isEmpty {
            userContent = user
        } else {
            var parts: [[String: Any]] = [
                ["type": "text", "text": user],
            ]
            for jpeg in imageJPEGs.prefix(4) {
                let b64 = jpeg.base64EncodedString()
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(b64)"],
                ])
            }
            userContent = parts
        }
        var payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        if !fallbacks.isEmpty {
            payload["models"] = fallbacks
        }
        if pinGroq && model == APIConfiguration.Model.search.defaultID {
            if allowFallback {
                payload["provider"] = [
                    "order": [provider],
                    "allow_fallbacks": true,
                ]
            } else {
                payload["provider"] = [
                    "order": [provider],
                    "only": [provider],
                    "allow_fallbacks": false,
                ]
            }
        }
        if json {
            payload["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await session.data(for: request)
            await onResponse?()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                lastError = "OpenRouter key 无效"
                return nil
            }
            if status == 402 {
                lastError = "OpenRouter 余额不足"
                return nil
            }
            guard (200..<300).contains(status) else {
                let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(180)) } ?? ""
                lastError = "OpenRouter HTTP \(status)"
                log("http \(status) \(snippet)")
                return nil
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any]
            else {
                lastError = "Groq 返回无法解析"
                return nil
            }
            if let content = message["content"] as? String {
                let modelUsed = (obj["model"] as? String) ?? model
                let reason = (choices.first?["finish_reason"] as? String) ?? ""
                log("complete \(modelUsed) finish=\(reason) chars=\(content.count)")
                return content
            }
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty {
                    let modelUsed = (obj["model"] as? String) ?? model
                    let reason = (choices.first?["finish_reason"] as? String) ?? ""
                    log("complete \(modelUsed) finish=\(reason) chars=\(text.count)")
                    return text
                }
            }
            lastError = "Groq 返回无法解析"
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            if lastError == nil { lastError = "网络失败" }
            log("error \(error.localizedDescription)")
            return nil
        }
    }

    private static let fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 14
        return URLSession(configuration: config)
    }()

    private static let slowSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 55
        return URLSession(configuration: config)
    }()

    private static let scanSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 50
        return URLSession(configuration: config)
    }()

    private static let reuseSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 140
        return URLSession(configuration: config)
    }()

    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    static func generateImage(
        prompt: String,
        referenceJPEG: Data,
        aspectRatio: String
    ) async -> (data: Data, ext: String)? {
        lastError = nil
        guard apiKey() != nil else {
            lastError = "未配置 OpenRouter"
            return nil
        }
        let models = [imageModel] + imageFallbacks
        for model in models {
            if let result = await generateImageOnce(
                model: model,
                prompt: prompt,
                referenceJPEG: referenceJPEG,
                aspectRatio: aspectRatio
            ) {
                return result
            }
        }
        if lastError == nil { lastError = "图没有生成出来" }
        return nil
    }

    private static func generateImageOnce(
        model: String,
        prompt: String,
        referenceJPEG: Data,
        aspectRatio: String
    ) async -> (data: Data, ext: String)? {
        guard let key = apiKey() else { return nil }
        var request = URLRequest(url: imageEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AI Everything", forHTTPHeaderField: "X-Title")
        request.setValue(APIConfiguration.projectURL, forHTTPHeaderField: "HTTP-Referer")
        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "aspect_ratio": aspectRatio,
            "output_format": "png",
            "input_references": [
                [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:image/jpeg;base64,\(referenceJPEG.base64EncodedString())",
                    ],
                ],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await imageSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                lastError = "OpenRouter key 无效"
                return nil
            }
            if status == 402 {
                lastError = "OpenRouter 余额不足"
                return nil
            }
            if !(200..<300).contains(status) {
                let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(180)) } ?? ""
                lastError = "OpenRouter HTTP \(status)"
                log("image-http \(status) \(model) \(snippet)")
                if let chat = await generateImageViaChat(
                    model: model,
                    prompt: prompt,
                    referenceJPEG: referenceJPEG
                ) {
                    return chat
                }
                return nil
            }
            if let parsed = parseImagePayload(data, model: model) {
                return parsed
            }
            lastError = "图返回无法解析"
            log("image-parse-fail \(model)")
            return await generateImageViaChat(
                model: model,
                prompt: prompt,
                referenceJPEG: referenceJPEG
            )
        } catch is CancellationError {
            return nil
        } catch {
            if lastError == nil { lastError = "网络失败" }
            log("image-error \(model) \(error.localizedDescription)")
            return nil
        }
    }

    private static func generateImageViaChat(
        model: String,
        prompt: String,
        referenceJPEG: Data
    ) async -> (data: Data, ext: String)? {
        guard let key = apiKey() else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AI Everything", forHTTPHeaderField: "X-Title")
        request.setValue(APIConfiguration.projectURL, forHTTPHeaderField: "HTTP-Referer")
        let payload: [String: Any] = [
            "model": model,
            "modalities": ["image", "text"],
            "temperature": 0.4,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(referenceJPEG.base64EncodedString())",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await imageSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let snippet = String(data: data, encoding: .utf8).map { String($0.prefix(160)) } ?? ""
                log("image-chat-http \(status) \(model) \(snippet)")
                return nil
            }
            return parseImagePayload(data, model: model)
        } catch {
            log("image-chat-error \(model) \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseImagePayload(_ data: Data, model: String) -> (data: Data, ext: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let rows = obj["data"] as? [[String: Any]] {
            for row in rows {
                if let parsed = decodeImageField(row["b64_json"], mediaType: row["media_type"] as? String) {
                    log("image-ok \(model) bytes=\(parsed.data.count)")
                    return parsed
                }
                if let parsed = decodeImageField(row["url"], mediaType: row["media_type"] as? String) {
                    log("image-ok \(model) bytes=\(parsed.data.count)")
                    return parsed
                }
            }
        }
        if let choices = obj["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let images = message["images"] as? [[String: Any]] {
                for image in images {
                    if let parsed = decodeImageField(
                        (image["image_url"] as? [String: Any])?["url"] ?? image["image_url"],
                        mediaType: image["media_type"] as? String
                    ) {
                        log("image-ok \(model) bytes=\(parsed.data.count)")
                        return parsed
                    }
                }
            }
            if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    if let parsed = decodeImageField(
                        (part["image_url"] as? [String: Any])?["url"] ?? part["b64_json"],
                        mediaType: part["media_type"] as? String
                    ) {
                        log("image-ok \(model) bytes=\(parsed.data.count)")
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    private static func decodeImageField(_ raw: Any?, mediaType: String?) -> (data: Data, ext: String)? {
        guard let raw else { return nil }
        var payload = ""
        if let s = raw as? String {
            payload = s
        } else if let obj = raw as? [String: Any], let s = obj["url"] as? String {
            payload = s
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }
        var ext = extFromMedia(mediaType) ?? "png"
        var b64 = payload
        if payload.hasPrefix("data:"), let comma = payload.firstIndex(of: ",") {
            let header = String(payload[..<comma])
            if header.contains("jpeg") || header.contains("jpg") { ext = "jpg" }
            else if header.contains("webp") { ext = "webp" }
            else if header.contains("png") { ext = "png" }
            b64 = String(payload[payload.index(after: comma)...])
        } else if payload.hasPrefix("http") {
            return nil
        }
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), data.count > 80 else {
            return nil
        }
        return (data, ext)
    }

    private static func extFromMedia(_ type: String?) -> String? {
        guard let type else { return nil }
        if type.contains("jpeg") || type.contains("jpg") { return "jpg" }
        if type.contains("webp") { return "webp" }
        if type.contains("png") { return "png" }
        return nil
    }

    static func log(_ line: String) {
        AppLog.write(line, channel: "api")
    }
}
