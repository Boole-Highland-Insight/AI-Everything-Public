import AIEMedia
import AIEData
import Darwin
import Foundation

/// Explicit developer entry point. No scan queue, model API, settings or unrelated library is opened.
enum MediaDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--transcribe-media" else { return false }
        guard args.count == 5 else {
            fputs("usage: AIEPopup --transcribe-media /selected/library relative/file.mp4 en-US\n", stderr)
            exit(2)
        }
        let result = Completion()
        Task.detached {
            do {
                let root = URL(fileURLWithPath: args[2]).standardizedFileURL.resolvingSymlinksInPath()
                let relative = args[3]
                let source = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                      source.path.hasPrefix(root.path + "/"),
                      ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac", "flac"].contains(source.pathExtension.lowercased()) else {
                    throw NSError(domain: "AIEMedia", code: 3, userInfo: [NSLocalizedDescriptionKey: "请指定所选资料夹内的音视频文件"])
                }
                let relativePath = String(source.path.dropFirst(root.path.count + 1))
                let database = try AppDatabase.open()
                try LegacyImport.run(root: root, database: database)
                try database.ensureAnalysis(root: root.path, relative: relativePath) { [:] }
                let recordID = database.analysisID(root: root.path, relative: relativePath)
                let owner = UUID().uuidString
                guard try database.acquireLease(recordID: recordID, scope: "transcript", owner: owner) else {
                    throw NSError(domain: "AIEMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "此文件已有转写任务"])
                }
                defer { try? database.releaseLease(recordID: recordID, scope: "transcript", owner: owner) }
                let disk = try database.analysis(root: root.path, relative: relativePath) ?? [:]
                var previous: MediaTranscript?
                if let saved = (disk["localScan"] as? [String: Any])?["mediaTranscript"] {
                    previous = try JSONDecoder().decode(MediaTranscript.self, from: JSONSerialization.data(withJSONObject: saved))
                }
                let engine: any LocalSpeechEngine
                if WhisperCPPEngine.isInstalled { engine = WhisperCPPEngine() }
                else { _ = await AppleSpeechEngine.requestPermission(); engine = AppleSpeechEngine() }
                let state = try await MediaBackend(engine: engine).transcribe(source, locale: args[4], previous: previous) { snapshot in
                    let encoded = try JSONEncoder().encode(snapshot)
                    let object = try JSONSerialization.jsonObject(with: encoded)
                    guard try database.acquireLease(recordID: recordID, scope: "transcript", owner: owner) else { throw CancellationError() }
                    guard try database.mutateAnalysis(root: root.path, relative: relativePath, { record in
                        var local = record["localScan"] as? [String: Any] ?? [:]
                        local["mediaTranscript"] = object; record["localScan"] = local
                        return true
                    }) else { throw CocoaError(.fileWriteUnknown) }
                }
                let output: [String: Any] = ["status": state.status, "completedSeconds": state.completedSeconds,
                                           "durationSeconds": state.media.duration, "segments": state.segments.count,
                                           "reason": state.error ?? "", "database": AppDatabase.url.path]
                let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                result.finish(state.status == "ready" ? 0 : 1)
            } catch { fputs(error.localizedDescription + "\n", stderr); result.finish(1) }
        }
        // Speech callbacks require a running main run loop; this mode never launches the normal app.
        while result.code == nil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        exit(result.code ?? 1)
    }
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return value }
        func finish(_ code: Int32) { lock.lock(); value = code; lock.unlock() }
    }
}
