import AIEData
import AVFoundation
import Foundation

public protocol MediaReader: Sendable {
    func probe(_ url: URL) async throws -> MediaInfo
    func exportAudio(_ url: URL, segment: TranscriptSegment, destination: URL) async throws
}

public struct AppleMediaReader: MediaReader {
    public init() {}
    public func probe(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaBackendError.invalidDuration }
        var frame = false; var videoError: String?
        if !video.isEmpty {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            do {
                _ = try generator.copyCGImage(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600), actualTime: nil)
                frame = true
            } catch { let error = error as NSError; videoError = "\(error.domain) (\(error.code))" }
        }
        return MediaInfo(duration: duration, audioTracks: audio.count, videoTracks: video.count, readableVideoFrame: frame, videoError: videoError)
    }
    public func exportAudio(_ url: URL, segment: TranscriptSegment, destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw MediaBackendError.noAudio }
        // Select the first audio track explicitly. Never mix commentary/alternate language tracks.
        let composition = AVMutableComposition()
        guard let output = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw MediaBackendError.exportFailed }
        let range = CMTimeRange(start: CMTime(seconds: segment.startSeconds, preferredTimescale: 600),
                                duration: CMTime(seconds: segment.endSeconds - segment.startSeconds, preferredTimescale: 600))
        try output.insertTimeRange(range, of: track, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw MediaBackendError.exportFailed }
        exporter.outputURL = destination; exporter.outputFileType = .m4a
        let cancellation = ExportCancellation(exporter)
        let timeout = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in exporter.exportAsynchronously { continuation.resume() } }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? MediaBackendError.exportFailed }
    }
}

/// AVAssetExportSession allows cancellation from another thread; isolate that single operation.
private final class ExportCancellation: @unchecked Sendable {
    let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func cancel() { exporter.cancelExport() }
}

/// Explicit, resumable local jobs. Merely indexing a library never starts this backend.
public actor MediaBackend {
    private let reader: any MediaReader
    private let engine: any LocalSpeechEngine
    private var active = Set<String>()
    public init(reader: any MediaReader = AppleMediaReader(), engine: any LocalSpeechEngine = AppleSpeechEngine()) {
        self.reader = reader; self.engine = engine
    }
    public func transcribe(_ url: URL, locale: String, previous: MediaTranscript? = nil,
                           checkpoint: @Sendable (MediaTranscript) throws -> Void) async throws -> MediaTranscript {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard active.insert(url.path).inserted else { throw NSError(domain: "AIEMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "此文件已有转写任务"]) }
        defer { active.remove(url.path) }
        let hash = try ContentIdentity.hashFile(url)
        let info = try await reader.probe(url)
        guard info.audioTracks > 0 else { throw MediaBackendError.noAudio }
        let plan = try SegmentPlan.make(duration: info.duration)
        var state = MediaTranscript(sourceHash: hash, locale: locale, model: engine.modelID, media: info, segments: plan)
        if let previous, previous.sourceHash == hash, previous.locale == locale,
           previous.model == engine.modelID, previous.parserVersion == state.parserVersion {
            guard previous.segments.count == plan.count,
                  zip(previous.segments, plan).allSatisfy({ $0.index == $1.index && $0.startSeconds == $1.startSeconds && $0.endSeconds == $1.endSeconds }) else {
                throw MediaBackendError.invalidCheckpoint
            }
            state = previous
        }
        // Completed checkpoints are usable even if the speech model later becomes unavailable.
        if state.segments.allSatisfy({ $0.status == "ready" }) { state.status = "ready"; state.error = nil; try checkpoint(state); return state }
        do { try await engine.prepare(locale: locale) }
        catch { state.status = "blocked"; state.error = error.localizedDescription; try checkpoint(state); return state }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aie-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        state.status = "running"; state.error = nil; try checkpoint(state)
        for index in state.segments.indices where state.segments[index].status != "ready" {
            let audio = temporary.appendingPathComponent("segment.m4a")
            state.segments[index].status = "running"; state.segments[index].error = nil
            try checkpoint(state)
            do {
                try Task.checkCancellation()
                guard try ContentIdentity.hashFile(url) == hash else { throw MediaBackendError.sourceChanged }
                try await reader.exportAudio(url, segment: state.segments[index], destination: audio)
                let text = try await engine.transcribe(audioURL: audio, locale: locale)
                try Task.checkCancellation()
                guard try ContentIdentity.hashFile(url) == hash else { throw MediaBackendError.sourceChanged }
                state.segments[index].text = text
                state.segments[index].status = "ready"
            } catch is CancellationError {
                state.segments[index].status = "pending"; state.status = "paused"
                try checkpoint(state); return state
            } catch MediaBackendError.sourceChanged {
                state.status = "source_changed"; state.error = MediaBackendError.sourceChanged.localizedDescription
                try checkpoint(state); return state
            } catch {
                state.segments[index].status = "failed"; state.segments[index].error = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: audio)
            state.updatedAt = ISO8601DateFormatter().string(from: Date())
            // Persist outside the processing catch: a failed save must stop the job, not skip a checkpoint.
            try checkpoint(state)
        }
        state.status = state.segments.allSatisfy { $0.status == "ready" } ? "ready" : "partial"
        try checkpoint(state)
        return state
    }
}
