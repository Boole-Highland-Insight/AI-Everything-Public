import Foundation
import Darwin

private actor BGERerankProcess {
    static let shared = BGERerankProcess()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()

    func scores(pairs: [[String]], python: URL, script: URL, cache: URL,
                deadline: Double, queued: ArchitectureAuditTrace.Span?) async -> [Double]? {
        queued?.end(count: pairs.count)
        let audit = ArchitectureAuditTrace.begin("bge_worker_request")
        defer { audit?.end(count: pairs.count) }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
              startIfNeeded(python: python, script: script, cache: cache),
              let input, let output
        else { return nil }
        var body: [String: Any] = ["pairs": pairs]
        if let audit { body["trace_id"] = audit.trace }
        guard var payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        payload.append(0x0A)
        do {
            let send = ArchitectureAuditTrace.begin("bge_pipe_write")
            try input.write(contentsOf: payload)
            send?.end(count: pairs.count)
            let responseWait = ArchitectureAuditTrace.begin("bge_response_wait")
            defer { responseWait?.end(count: pairs.count) }
            guard let response = readLine(from: output, deadline: deadline),
                  let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let scores = object["scores"] as? [Double],
                  scores.count == pairs.count, scores.allSatisfy(\.isFinite)
            else { stop(); return nil }
            if let fields = object["audit"] as? [String: Any] {
                ArchitectureAuditTrace.begin("bge_worker_report")?.end(count: pairs.count, fields: fields)
            }
            return scores
        } catch {
            stop()
            return nil
        }
    }

    private func startIfNeeded(python: URL, script: URL, cache: URL) -> Bool {
        if process?.isRunning == true { return true }
        let launch = ArchitectureAuditTrace.begin("bge_process_launch")
        defer { launch?.end() }
        stop()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = python
        process.arguments = [script.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["HF_HOME": cache.path], uniquingKeysWith: { _, new in new }
        )
        do {
            try OwnedModelProcesses.run(process)
            self.process = process
            input = inputPipe.fileHandleForWriting
            output = outputPipe.fileHandleForReading
            return true
        } catch {
            stop()
            return false
        }
    }

    private func readLine(from output: FileHandle, deadline: Double) -> Data? {
        while true {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                stop()
                return nil
            }
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = Data(outputBuffer[..<newline])
                outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
                return line
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            guard ready > 0 else { stop(); return nil }
            let data = output.availableData
            guard !data.isEmpty else {
                stop()
                return nil
            }
            outputBuffer.append(data)
        }
    }

    private func stop() {
        if process?.isRunning == true { process?.terminate() }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }
}

enum LocalBGERerank {
    private struct Runtime {
        let python: URL
        let script: URL
        let cache: URL
    }

    static var isAvailable: Bool { runtime != nil }

    static func rerank(query: String, hits: [FileHit], files: [IndexedFile],
                       candidateLimit: Int = JevRerank.candidateLimit,
                       summaries: [String: String] = [:], timeout: TimeInterval = 15) async -> [FileHit]? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let audit = ArchitectureAuditTrace.begin("bge_total")
        defer { audit?.end(count: hits.count) }
        guard let runtime else { return nil }
        let candidates = Array(hits.prefix(max(0, candidateLimit)))
        guard !candidates.isEmpty else { return hits }
        ScanControl.shared.beginForegroundModelWork()
        defer { ScanControl.shared.endForegroundModelWork() }
        if ScanControl.shared.isHeavyModelActive { await LocalQuickScan.shared.unload() }
        let context = ArchitectureAuditTrace.begin("bge_candidate_text")
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let pairs = candidates.map { hit -> [String] in
            let file = byPath[hit.path]
            let chunk = file?.chunks.first { $0.id == hit.chunkID }
            let source = chunk?.text.isEmpty == false ? chunk!.text : hit.snippet
            let passage = [
                hit.relative, hit.kind.rawValue, String(source.prefix(800)),
                String((summaries[hit.path] ?? file?.fileSummary ?? "").prefix(300)),
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            return [query, passage]
        }
        context?.end(count: pairs.count)
        guard let scores = await BGERerankProcess.shared.scores(
            pairs: pairs, python: runtime.python, script: runtime.script, cache: runtime.cache,
            deadline: deadline,
            queued: ArchitectureAuditTrace.begin("bge_actor_queue_wait")
        ) else { return nil }
        let sort = ArchitectureAuditTrace.begin("bge_score_sort")
        defer { sort?.end(count: candidates.count) }
        let ranked = zip(candidates.indices, scores).sorted {
            $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1
        }.map { candidates[$0.0] }
        return ranked + Array(hits.dropFirst(candidates.count))
    }

    private static var runtime: Runtime? {
        var root = Bundle.main.bundleURL
        for _ in 0..<8 {
            let python = root.appendingPathComponent(".build/bge-reranker-env/bin/python")
            let script = root.appendingPathComponent("tools/local_bge_rerank.py")
            let cache = root.appendingPathComponent(".build/huggingface")
            if FileManager.default.isExecutableFile(atPath: python.path),
               FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: cache.path) {
                return Runtime(python: python, script: script, cache: cache)
            }
            root.deleteLastPathComponent()
        }
        return nil
    }
}
