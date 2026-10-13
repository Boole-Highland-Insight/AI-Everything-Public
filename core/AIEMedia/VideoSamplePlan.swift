import Foundation

public struct VideoSample: Codable, Equatable, Sendable {
    public let index: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(index: Int, startSeconds: Double, endSeconds: Double) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public enum VideoSamplePlan {
    public static let parserVersion = "video-samples-1"

    public static func make(
        duration: Double,
        maxSamples: Int = 8,
        targetSpacing: Double = 5
    ) throws -> [VideoSample] {
        guard duration.isFinite, duration > 0,
              maxSamples > 0, targetSpacing.isFinite, targetSpacing > 0
        else { throw MediaBackendError.invalidDuration }

        if duration <= 1 {
            return [VideoSample(index: 0, startSeconds: duration / 2, endSeconds: duration)]
        }

        let first = min(0.5, duration / 2)
        let last = max(first, duration - 0.5)
        let count = min(maxSamples, max(2, Int(ceil(duration / targetSpacing)) + 1))
        guard count > 1, last - first >= 0.25 else {
            return [VideoSample(index: 0, startSeconds: first, endSeconds: min(duration, first + 1))]
        }

        return (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            let start = first + (last - first) * fraction
            return VideoSample(
                index: index,
                startSeconds: start,
                endSeconds: min(duration, start + 1)
            )
        }
    }
}
