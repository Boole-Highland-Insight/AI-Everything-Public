import Foundation

public struct MediaInfo: Codable, Sendable {
    public let duration: Double
    public let audioTracks: Int
    public let videoTracks: Int
    public let readableVideoFrame: Bool
    public let videoError: String?
    public var route: String {
        if audioTracks > 0 { return readableVideoFrame ? "audio_and_video" : "audio" }
        return readableVideoFrame ? "video" : "unreadable"
    }
    public init(duration: Double, audioTracks: Int, videoTracks: Int, readableVideoFrame: Bool, videoError: String? = nil) {
        self.duration = duration; self.audioTracks = audioTracks; self.videoTracks = videoTracks
        self.readableVideoFrame = readableVideoFrame; self.videoError = videoError
    }
}

public struct TranscriptSegment: Codable, Sendable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public var text: String
    public var status: String
    public var error: String?
    public init(index: Int, startSeconds: Double, endSeconds: Double, text: String = "", status: String = "pending", error: String? = nil) {
        self.index = index; self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.text = text; self.status = status; self.error = error
    }
}

public struct MediaTranscript: Codable, Sendable {
    public var parserVersion = "media-transcript-1"
    public let sourceHash: String
    public let locale: String
    public let model: String
    public let media: MediaInfo
    public var segments: [TranscriptSegment]
    public var status: String
    public var error: String?
    public var updatedAt: String
    public var completedSeconds: Double { segments.filter { $0.status == "ready" }.reduce(0) { $0 + $1.endSeconds - $1.startSeconds } }
    public init(sourceHash: String, locale: String, model: String, media: MediaInfo, segments: [TranscriptSegment], status: String = "pending") {
        self.sourceHash = sourceHash; self.locale = locale; self.model = model; self.media = media; self.segments = segments
        self.status = status; updatedAt = ISO8601DateFormatter().string(from: Date())
    }
}

public enum MediaBackendError: LocalizedError {
    case invalidDuration, noAudio, localSpeechUnavailable, speechPermission, exportFailed, sourceChanged, invalidCheckpoint
    public var errorDescription: String? {
        switch self {
        case .invalidDuration: return "无法读取有效媒体时长"
        case .noAudio: return "文件没有可读取的音轨"
        case .localSpeechUnavailable: return "当前系统或语言未提供可用的本机语音识别；不会转为云端调用"
        case .speechPermission: return "需要在系统隐私设置中允许语音识别"
        case .exportFailed: return "无法导出此段音频"
        case .sourceChanged: return "原文件发生变化，已停止转写；请重新启动任务"
        case .invalidCheckpoint: return "转写断点与当前分段规则不一致"
        }
    }
}

/// ASR providers can be replaced with Whisper without changing checkpoints or the data-layer adapter.
public protocol LocalSpeechEngine: Sendable {
    var modelID: String { get }
    func prepare(locale: String) async throws
    func transcribe(audioURL: URL, locale: String) async throws -> String
}

public enum SegmentPlan {
    /// Fixed bounded windows for v1. These are processing windows, not linguistic sentence boundaries.
    public static func make(duration: Double, width: Double = 45) throws -> [TranscriptSegment] {
        guard duration.isFinite, duration > 0, width.isFinite, width >= 1, duration / width <= 100_000 else { throw MediaBackendError.invalidDuration }
        return (0..<Int(ceil(duration / width))).map { index in
            TranscriptSegment(index: index, startSeconds: Double(index) * width, endSeconds: min(duration, Double(index + 1) * width))
        }
    }
}
