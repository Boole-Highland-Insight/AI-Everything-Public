import Foundation
import CryptoKit

/// Owns one AIE-bundled llama.cpp process. Text requests reuse the current mode;
/// image requests switch the single process to their visual token budget.
actor LocalGemmaWorker {
    static let shared = LocalGemmaWorker()
    static let dimensions = 768
    static let modelID = "embeddinggemma-2-Q8_0"

    private var process: Process?
    private var startingProcess: Process?
    private var port: Int?
    private var apiKey: String?
    private var imageBudget: Int?
    private var busy = false
    private var backgroundActive = false
    private var backgroundInterrupted = false
    private var modelVersion: String?
    private var modelStamp: String?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration)
    }()

    static var modelDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["AIE_GEMMA_MODELS_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: "aie.gemma.modelsPath"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("GemmaModels"),
           modelFilesAvailable(in: bundled) { return bundled }
        return AIEApplicationPaths.support.appendingPathComponent("Semantic/Models")
    }

    static var executable: URL? {
        return Bundle.main.resourceURL?.appendingPathComponent("GemmaRuntime/llama-server")
    }

    static var isAvailable: Bool {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        return modelFilesAvailable(in: modelDirectory)
    }

    private static func modelFilesAvailable(in directory: URL) -> Bool {
        ["embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf"].allSatisfy {
            FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// A model revision is shared by text and image vectors only for this tested GGUF pair.
    func revision() throws -> String {
        let audit = ArchitectureAuditTrace.begin("gemma_model_revision")
        defer { audit?.end() }
        let directory = Self.modelDirectory
        let names = ["embeddinggemma-2-Q8_0.gguf", "mmproj-embeddinggemma-2-Q8_0.gguf"]
        let urls = names.map { directory.appendingPathComponent($0) }
        let stamps = try urls.map { url -> String in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return url.path + ":\(attributes[.size] ?? ""):\(attributes[.modificationDate] ?? "")"
        }.joined(separator: "|")
        if stamps == modelStamp, let modelVersion { return modelVersion }
        stop()
        var hash = SHA256()
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw GemmaError.notInstalled }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        }
        let version = hash.finalize().map { String(format: "%02x", $0) }.joined()
        modelVersion = version
        modelStamp = stamps
        return version
    }

    func text(_ values: [String], background: Bool = false) async throws -> [[Float]] {
        try await request(values.map { $0 as Any }, imageBudget: nil, background: background)
    }

    func image(_ paths: [String], budget: Int, background: Bool = false) async throws -> [[Float]] {
        let inputs = try paths.map { path -> Any in
            let url = URL(fileURLWithPath: path)
            let bytes = try Data(contentsOf: url)
            let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            return ["content": [["type": "image_url",
                                 "image_url": ["url": "data:\(mime);base64,\(bytes.base64EncodedString())"]]]]
        }
        return try await request(inputs, imageBudget: budget, background: background)
    }

    func interruptBackground() {
        if backgroundActive {
            backgroundInterrupted = true
            stop()
        }
    }

    func stop() {
        if let startingProcess, startingProcess.isRunning {
            startingProcess.terminate()
            startingProcess.waitUntilExit()
        }
        startingProcess = nil
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        port = nil
        apiKey = nil
        imageBudget = nil
    }

    private func request(_ inputs: [Any], imageBudget requestedBudget: Int?, background: Bool) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        var succeeded = false
        let auditRequest = ArchitectureAuditTrace.begin("gemma_request")
        defer { auditRequest?.end(count: inputs.count, fields: ["background": background, "image_budget": requestedBudget ?? 0, "succeeded": succeeded]) }
        let auditQueue = ArchitectureAuditTrace.begin("gemma_queue_wait")
        while busy {
            try Task.checkCancellation()
            if !background && backgroundActive { interruptBackground() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if background && (ScanControl.shared.isInteractiveWorkActive || ScanControl.shared.isHeavyModelActive) {
            throw CancellationError()
        }
        busy = true
        auditQueue?.end()
        backgroundActive = background
        backgroundInterrupted = false
        defer { busy = false; backgroundActive = false; backgroundInterrupted = false }
        try await startIfNeeded(imageBudget: requestedBudget)
        guard let port, let apiKey else { throw GemmaError.notInstalled }
        let body = try JSONSerialization.data(withJSONObject: ["model": "embeddinggemma-2", "input": inputs])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/embeddings")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let auditHTTP = ArchitectureAuditTrace.begin("gemma_http_encode")
        var httpFinished = false
        defer { if !httpFinished { auditHTTP?.end(count: inputs.count, fields: ["completed": false]) } }
        let (data, response) = try await session.data(for: request)
        httpFinished = true
        auditHTTP?.end(count: inputs.count, fields: ["completed": true])
        let auditDecode = ArchitectureAuditTrace.begin("gemma_response_decode")
        defer { auditDecode?.end(count: inputs.count) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = result["data"] as? [[String: Any]], rows.count == inputs.count else {
            throw GemmaError.badResponse
        }
        let vectors = try rows.sorted { ($0["index"] as? Int ?? -1) < ($1["index"] as? Int ?? -1) }.map { row -> [Float] in
            guard let numbers = row["embedding"] as? [NSNumber], numbers.count == Self.dimensions else {
                throw GemmaError.badResponse
            }
            return numbers.map(\.floatValue)
        }
        guard vectors.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw GemmaError.badResponse }
        succeeded = true
        return vectors
    }

    private func startIfNeeded(imageBudget requestedBudget: Int?) async throws {
        if process?.isRunning == true && (requestedBudget == nil || requestedBudget == imageBudget) { return }
        let auditStart = ArchitectureAuditTrace.begin("gemma_worker_start_health")
        defer { auditStart?.end(fields: ["image_budget": requestedBudget ?? 0]) }
        stop()
        guard let executable = Self.executable,
              FileManager.default.isExecutableFile(atPath: executable.path),
              Self.isAvailable else { throw GemmaError.notInstalled }
        for _ in 0..<4 {
            if backgroundInterrupted { throw CancellationError() }
            let candidatePort = Int.random(in: 20_000...60_000)
            let candidateKey = UUID().uuidString + UUID().uuidString
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--model", Self.modelDirectory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf").path,
                               "--embedding", "--host", "127.0.0.1", "--port", String(candidatePort),
                               "--api-key", candidateKey, "--cors-origins", "localhost", "--no-ui",
                               "--parallel", "1", "--ctx-size", "4096",
                               "--batch-size", "2048", "--ubatch-size", "2048"]
                + (requestedBudget == nil ? ["--n-gpu-layers", "0"] : [])
                + (requestedBudget.map { ["--mmproj", Self.modelDirectory.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf").path,
                                          "--image-max-tokens", String($0)] } ?? ["--no-mmproj"])
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try OwnedModelProcesses.run(child)
            startingProcess = child
            var health = URLRequest(url: URL(string: "http://127.0.0.1:\(candidatePort)/health")!)
            health.setValue("Bearer \(candidateKey)", forHTTPHeaderField: "Authorization")
            do {
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if backgroundInterrupted { throw CancellationError() }
                    guard child.isRunning else { break }
                    if let (_, response) = try? await session.data(for: health),
                       (response as? HTTPURLResponse)?.statusCode == 200 {
                        startingProcess = nil
                        process = child
                        port = candidatePort
                        apiKey = candidateKey
                        imageBudget = requestedBudget
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch {
                if child.isRunning { child.terminate(); child.waitUntilExit() }
                startingProcess = nil
                throw error
            }
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            startingProcess = nil
        }
        throw GemmaError.notInstalled
    }
}

enum GemmaError: Error { case notInstalled, badResponse }
