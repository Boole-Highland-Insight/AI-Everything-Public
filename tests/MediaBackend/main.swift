import AIEData
import AIEMedia
import AVFoundation
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "MediaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
struct FakeReader: MediaReader {
    let videoFailure: Bool
    func probe(_ url: URL) async throws -> MediaInfo {
        MediaInfo(duration: 91.5, audioTracks: 1, videoTracks: videoFailure ? 1 : 0, readableVideoFrame: false, videoError: videoFailure ? "decode fixture" : nil)
    }
    func exportAudio(_ url: URL, segment: TranscriptSegment, destination: URL) async throws {
        try String(segment.index).write(to: destination, atomically: true, encoding: .utf8)
    }
}
actor FakeSpeech: LocalSpeechEngine {
    nonisolated let modelID = "fixture-local"
    var calls: [Int] = []
    var failIndex: Int?
    var blocked = false
    var cancel = false
    init(failIndex: Int? = nil, blocked: Bool = false, cancel: Bool = false) { self.failIndex = failIndex; self.blocked = blocked; self.cancel = cancel }
    func prepare(locale: String) throws { if blocked { throw MediaBackendError.localSpeechUnavailable } }
    func transcribe(audioURL: URL, locale: String) throws -> String {
        let index = Int(try String(contentsOf: audioURL, encoding: .utf8))!
        calls.append(index)
        if cancel { throw CancellationError() }
        if index == failIndex { throw NSError(domain: "fixture", code: 2) }
        return "专利审批流程第\(index)段"
    }
}
final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MediaTranscript] = []
    func append(_ value: MediaTranscript) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

@main enum MediaChecks {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aie-media-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("source.mp4")
        try Data("fixture".utf8).write(to: source)
        let speech = FakeSpeech(failIndex: 1)
        let snapshots = Snapshots()
        let partial = try await MediaBackend(reader: FakeReader(videoFailure: true), engine: speech).transcribe(source, locale: "en-US") { snapshots.append($0) }
        try check(partial.status == "partial" && partial.media.route == "audio", "Unreadable video did not preserve audio route")
        try check(partial.segments[1].status == "failed" && partial.segments[2].status == "ready", "One failure blocked later segments")
        try check(partial.completedSeconds == 46.5 && snapshots.count >= 7, "Partial progress not checkpointed")
        let encoded = try JSONEncoder().encode(partial)
        let checkpoint = try JSONDecoder().decode(MediaTranscript.self, from: encoded)
        let resumedSpeech = FakeSpeech()
        let resumed = try await MediaBackend(reader: FakeReader(videoFailure: false), engine: resumedSpeech).transcribe(source, locale: "en-US", previous: checkpoint) { _ in }
        let resumedCalls = await resumedSpeech.calls
        try check(resumedCalls == [1] && resumed.status == "ready", "Resume reprocessed successful segments")
        let blocked = try await MediaBackend(reader: FakeReader(videoFailure: false), engine: FakeSpeech(blocked: true)).transcribe(source, locale: "en-US") { _ in }
        try check(blocked.status == "blocked" && blocked.completedSeconds == 0, "Local engine unavailable was treated as success")
        try Data("edited fixture".utf8).write(to: source)
        let changedSpeech = FakeSpeech()
        _ = try await MediaBackend(reader: FakeReader(videoFailure: false), engine: changedSpeech).transcribe(source, locale: "en-US", previous: resumed) { _ in }
        let changedCalls = await changedSpeech.calls
        try check(changedCalls == [0,1,2], "Changed source reused stale transcript")
        var saveFailed = false
        do { _ = try await MediaBackend(reader: FakeReader(videoFailure: false), engine: FakeSpeech()).transcribe(source, locale: "en-US") { _ in throw CocoaError(.fileWriteUnknown) } }
        catch { saveFailed = true }
        try check(saveFailed, "Checkpoint write failure did not stop the job")
        let paused = try await MediaBackend(reader: FakeReader(videoFailure: false), engine: FakeSpeech(cancel: true)).transcribe(source, locale: "en-US") { _ in }
        try check(paused.status == "paused" && paused.segments[0].status == "pending", "Cancellation did not leave a resumable checkpoint")
        let plan = try SegmentPlan.make(duration: 56 * 60 + 1)
        try check(plan.last?.endSeconds == 3361 && zip(plan, plan.dropFirst()).allSatisfy { $0.endSeconds == $1.startSeconds }, "Long audio plan has gaps or truncation")
        let shortVideo = try VideoSamplePlan.make(duration: 0.8)
        try check(shortVideo == [VideoSample(index: 0, startSeconds: 0.4, endSeconds: 0.8)], "Short video sampling escaped its duration")
        let mediumVideo = try VideoSamplePlan.make(duration: 21)
        try check(mediumVideo.count == 6 && mediumVideo.first?.startSeconds == 0.5 && mediumVideo.last?.startSeconds == 20.5,
                  "Medium video sampling did not cover its full duration")
        let longVideo = try VideoSamplePlan.make(duration: 2 * 60 * 60)
        try check(longVideo.count == 8 && zip(longVideo, longVideo.dropFirst()).allSatisfy { $0.startSeconds < $1.startSeconds },
                  "Long video sampling exceeded its bound or lost ordering")

        // Real AVFoundation test: generate a short tone, export M4A, then use an MP4 extension.
        let wav = temporary.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        for i in 0..<32000 { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 440 * 2 * .pi / 16000) * 3_000) }
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        let reader = AppleMediaReader()
        let m4a = temporary.appendingPathComponent("tone.m4a")
        fputs("Checking WAV export\n", stderr)
        try await reader.exportAudio(wav, segment: TranscriptSegment(index: 0, startSeconds: 0, endSeconds: 2), destination: m4a)
        let audioMP4 = temporary.appendingPathComponent("audio-only.mp4")
        try FileManager.default.moveItem(at: m4a, to: audioMP4)
        fputs("Checking MP4 probe\n", stderr)
        let info = try await reader.probe(audioMP4)
        try check(info.audioTracks == 1 && info.videoTracks == 0 && info.route == "audio", "MP4 extension hid audio-only tracks")
        let exported = temporary.appendingPathComponent("part.m4a")
        fputs("Checking MP4 segment export\n", stderr)
        try await reader.exportAudio(audioMP4, segment: TranscriptSegment(index: 0, startSeconds: 0.5, endSeconds: 1.5), destination: exported)
        let part = try await reader.probe(exported)
        try check(abs(part.duration - 1) < 0.15, "Audio range export lost timing")
        print("Media checks passed: bounded video sampling, audio-only MP4 probe, real audio export, 56-minute plan, failed-segment resume, local-only blocking, changed-source invalidation and checkpoint errors. ASR responses are fixtures; no user media or speech service invoked.")
    }
}
