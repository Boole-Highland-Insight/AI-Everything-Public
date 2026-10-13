import AIEData
import Foundation

/// Small performance samples, without filenames or content. Model changes get fresh estimates.
enum ScanTiming {
    private static let lock = NSLock()
    private static let storageKey = "aie.scan.timings.v1"
    private static var estimate = UserDefaults.standard.data(forKey: storageKey)
        .flatMap { try? JSONDecoder().decode(ScanTimingEstimate.self, from: $0) } ?? ScanTimingEstimate()

    static func key(stage: String, ext: String = "", model: String = "") -> String {
        "\(stage):\(model):\(ext)"
    }

    static func record(key: String, units: Int = 1, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        estimate.record(key: key, units: units, seconds: seconds)
        if let data = try? JSONEncoder().encode(estimate) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func remaining(work: [String: Int]) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return estimate.remainingSeconds(work: work)
    }

    static func label(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "正在估算时间" }
        if seconds < 60 { return "预计不到 1 分钟" }
        if seconds < 3600 { return "预计还需 \(Int(ceil(seconds / 60))) 分钟" }
        let hours = Int(ceil(seconds / 1800))
        return "预计还需 \(String(format: "%.1f", Double(hours) / 2)) 小时"
    }
}
