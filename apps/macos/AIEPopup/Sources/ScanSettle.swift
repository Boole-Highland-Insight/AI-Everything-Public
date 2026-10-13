import Foundation

/// 新文件还在拷贝时不扫。用当前磁盘 size/mtime，不用索引里的旧快照。
enum ScanSettle {
    private static let lock = NSLock()
    private static var lastSize: [String: Int] = [:]
    private static var deferrals: [String: Int] = [:]

    static func ready(path: String) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        let age = Date().timeIntervalSince(mtime)
        lock.lock()
        defer { lock.unlock() }
        if lastSize[path] != size {
            lastSize[path] = size
            deferrals[path] = 0
            return false
        }
        if age >= 1.2 { return true }
        let n = (deferrals[path] ?? 0) + 1
        deferrals[path] = n
        return n >= 10
    }

    static func wait() {
        Thread.sleep(forTimeInterval: 0.45)
    }

    static func clear(_ path: String) {
        lock.lock()
        lastSize.removeValue(forKey: path)
        deferrals.removeValue(forKey: path)
        lock.unlock()
    }
}
