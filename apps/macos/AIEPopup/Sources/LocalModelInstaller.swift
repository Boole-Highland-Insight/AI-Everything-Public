import Foundation

/// Installs the private runtime and its models without depending on developer tooling.
/// The download itself runs here rather than in a helper script, so a Mac without Xcode
/// Command Line Tools (and therefore without a working `python3`) can still finish setup.
enum LocalModelInstaller {
    struct Update {
        let phase: String
        let fraction: Double?
    }

    enum Failure: LocalizedError {
        case runtimeScriptMissing
        case runtimeInstallFailed(String)
        case runtimeUnavailable
        case downloadFailed(model: String, reason: String)
        case digestMismatch(model: String)

        var errorDescription: String? {
            switch self {
            case .runtimeScriptMissing:
                return "安装程序不完整，缺少本机运行环境脚本，请重新安装 AI Everything。"
            case .runtimeInstallFailed(let reason):
                return "本机运行环境安装失败：\(reason)"
            case .runtimeUnavailable:
                return "本机模型服务没有启动成功，请重试；若仍失败请重启 Mac 后再试。"
            case .downloadFailed(let model, let reason):
                return "下载 \(model) 失败：\(reason)"
            case .digestMismatch(let model):
                return "\(model) 的文件校验不一致，可能下载被网络中转改写，请重试。"
            }
        }
    }

    private static let endpoint = URL(string: "http://" + AIEApplicationPaths.ollamaHost)!
    private static let lock = NSLock()
    private static var server: Process?

    private static var semanticHome: URL {
        AIEApplicationPaths.support.appendingPathComponent("Semantic")
    }
    private static var runtime: URL { semanticHome.appendingPathComponent("bin/ollama") }
    static var logURL: URL {
        AIEApplicationPaths.support.appendingPathComponent("model-install.log")
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Long enough for a multi-gigabyte pull, but still fails instead of hanging forever.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    static func install(models: [(name: String, digest: String?)],
                        update: @escaping (Update) -> Void) async throws {
        try await ensureRuntime(update: update)
        try await ensureServer()
        for model in models {
            try await install(model: model.name, expected: model.digest, update: update)
        }
    }

    private static func install(model: String, expected: String?,
                                update: @escaping (Update) -> Void) async throws {
        if let digest = await installedDigest(model) {
            if expected == nil || digest == expected { return }
        } else if (try? LocalModelLibrary.importFromSharedStore(model)) == true {
            update(Update(phase: "正在复用本机已安装的 \(model)", fraction: nil))
            if let digest = await installedDigest(model), expected == nil || digest == expected { return }
        }
        update(Update(phase: "正在下载 \(model)", fraction: nil))
        try await pull(model: model, update: update)
        guard let digest = await installedDigest(model) else {
            throw Failure.downloadFailed(model: model, reason: "下载完成但本机服务未能加载模型")
        }
        guard expected == nil || digest == expected else { throw Failure.digestMismatch(model: model) }
    }

    private static func pull(model: String, update: @escaping (Update) -> Void) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { throw Failure.downloadFailed(model: model, reason: describe(error)) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.downloadFailed(model: model, reason: "本机模型服务拒绝了下载请求")
        }
        var finished = false
        do {
            for try await line in bytes.lines {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let failure = row["error"] as? String {
                    throw Failure.downloadFailed(model: model, reason: describe(remote: failure))
                }
                if let total = (row["total"] as? NSNumber)?.doubleValue,
                   let completed = (row["completed"] as? NSNumber)?.doubleValue, total > 0 {
                    update(Update(phase: "正在下载 \(model)", fraction: min(1, max(0, completed / total))))
                }
                if row["status"] as? String == "success" { finished = true }
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.downloadFailed(model: model, reason: describe(error))
        }
        guard finished else {
            throw Failure.downloadFailed(model: model, reason: "下载在完成前中断，请检查网络后重试")
        }
    }

    private static func installedDigest(_ model: String) async -> String? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]],
              let entry = models.first(where: { $0["name"] as? String == model }),
              let digest = entry["digest"] as? String, !digest.isEmpty else { return nil }
        return digest
    }

    private static func ensureRuntime(update: @escaping (Update) -> Void) async throws {
        guard !FileManager.default.isExecutableFile(atPath: runtime.path) else { return }
        guard let script = Bundle.main.url(forResource: "setup_local_semantic", withExtension: "sh") else {
            throw Failure.runtimeScriptMissing
        }
        update(Update(phase: "正在准备本机运行环境…", fraction: nil))
        let log = try openLog()
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        // The script only installs the runtime here; models are downloaded natively below so the
        // whole setup no longer needs python3, which is absent until Command Line Tools exist.
        environment["AIE_SEMANTIC_HOME"] = semanticHome.path
        environment["LC_ALL"] = "C"
        environment.removeValue(forKey: "OPENROUTER_API_KEY")
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        do { try process.run() } catch { throw Failure.runtimeInstallFailed(describe(error)) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        guard process.terminationStatus == 0,
              FileManager.default.isExecutableFile(atPath: runtime.path) else {
            throw Failure.runtimeInstallFailed(logTail())
        }
    }

    private static func ensureServer() async throws {
        if await serverReachable() { return }
        startServerIfNeeded()
        for _ in 0..<40 {
            if await serverReachable() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw Failure.runtimeUnavailable
    }

    private static func startServerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard server?.isRunning != true else { return }
        let child = Process()
        child.executableURL = runtime
        child.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = AIEApplicationPaths.ollamaHost
        environment["OLLAMA_MODELS"] = LocalModelLibrary.privateModels.path
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? OwnedModelProcesses.run(child)
        server = child
    }

    private static func serverReachable() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func openLog() throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        return handle
    }

    /// The last meaningful script output, short enough for a dialog and free of the user's paths.
    private static func logTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "未知错误" }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd() { try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0) }
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "未知错误" }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%") }
        guard !lines.isEmpty else { return "未知错误" }
        return describe(remote: lines.suffix(2).joined(separator: " / "))
    }

    private static func describe(_ error: Error) -> String {
        let failure = error as NSError
        switch failure.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "网络连接中断"
        case NSURLErrorTimedOut:
            return "网络超时"
        default:
            return describe(remote: failure.localizedDescription)
        }
    }

    /// Map runtime and network messages onto something a non-developer can act on.
    private static func describe(remote message: String) -> String {
        let text = message.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
        let lowered = text.lowercased()
        if lowered.contains("checksum mismatch") {
            return "安装包校验不一致，通常是公司网络或代理改写了下载内容"
        }
        if lowered.contains("no such host") || lowered.contains("could not resolve") {
            return "无法解析下载地址，可能被公司网络或 DNS 拦截"
        }
        if lowered.contains("certificate") || lowered.contains("tls") {
            return "下载连接的证书被拦截，通常是公司网络代理"
        }
        if lowered.contains("connection refused") || lowered.contains("timed out") || lowered.contains("timeout") {
            return "连接下载服务超时，请检查网络或代理设置"
        }
        if lowered.contains("no space") || lowered.contains("disk") {
            return "磁盘空间不足"
        }
        return String(text.prefix(220))
    }
}
