import Foundation
import AIEData
import AIEMedia

/// Called only on the serial background scan queue. Shares resumable jobs with the explicit CLI.
enum LocalAudioScanner {
    static func probe(_ file: IndexedFile) -> MediaInfo? {
        let done = DispatchSemaphore(value: 0), box = MediaInfoBox()
        Task.detached {
            defer { done.signal() }
            box.value = try? await AppleMediaReader().probe(URL(fileURLWithPath: file.path))
        }
        done.wait()
        return box.value
    }

    static func scan(_ file: IndexedFile) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0), box = ResultBox()
        Task.detached {
            defer { done.signal() }
            do {
                let database = try AppDatabase.open(), relative = ScanRecords.relative(for: file)
                let id = database.analysisID(root: file.rootPath, relative: relative), owner = UUID().uuidString
                guard try database.acquireLease(recordID: id, scope: "transcript", owner: owner) else { return }
                defer { try? database.releaseLease(recordID: id, scope: "transcript", owner: owner) }
                let record = try database.analysis(root: file.rootPath, relative: relative) ?? [:]
                var previous: MediaTranscript?
                if let stored = (record["localScan"] as? [String: Any])?["mediaTranscript"] {
                    previous = try? JSONDecoder().decode(MediaTranscript.self, from: JSONSerialization.data(withJSONObject: stored))
                }
                let state = try await MediaBackend(engine: WhisperCPPEngine()).transcribe(URL(fileURLWithPath: file.path), locale: previous?.locale ?? "auto", previous: previous) { state in
                    guard try database.acquireLease(recordID: id, scope: "transcript", owner: owner) else { throw CancellationError() }
                    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                    try database.mutateAnalysis(root: file.rootPath, relative: relative) { record in
                        var local = record["localScan"] as? [String: Any] ?? [:]
                        local["mediaTranscript"] = value; record["localScan"] = local; return true
                    }
                    DispatchQueue.main.async {
                        ScanProgress.shared.message = "本机转写 \(Int(state.completedSeconds))/\(Int(state.media.duration)) 秒 · \(file.name)"
                    }
                }
                if state.status == "ready" { box.value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any] }
            } catch { AppLog.write("audio-scan: \(error.localizedDescription)") }
        }
        done.wait()
        return box.value
    }
    private final class MediaInfoBox: @unchecked Sendable { var value: MediaInfo? }
    private final class ResultBox: @unchecked Sendable { var value: [String: Any]? }
}
