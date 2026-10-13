import Foundation
import AIEData

/// One database for the UI, scanners and explicit media jobs. Credentials remain separate.
enum AppDatabase {
    private static let lock = NSLock()
    private static var storage: ContentStore?
    private static var error: String?
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AI Everything/Index/content.sqlite")
    }
    static var lastError: String? { lock.lock(); defer { lock.unlock() }; return error }
    static func failed(_ failure: Error) {
        lock.lock(); error = "本机数据操作失败，扫描已暂停"; lock.unlock()
        AppLog.write("database: \(failure)")
        if ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"] != nil { fputs(String(describing: failure) + "\n", stderr) }
    }
    static func open() throws -> ContentStore {
        lock.lock(); defer { lock.unlock() }
        if let storage { return storage }
        let db = try ContentStore(path: url.path)
        if ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"] == nil {
            try db.recoverInterruptedJobs()
            try db.importPreferences(["kept": UserDefaults.standard.stringArray(forKey: "aie.recycleKept") ?? [],
                                      "deferred": UserDefaults.standard.stringArray(forKey: "aie.scan.deferredPaths") ?? []])
        }
        storage = db
        return db
    }
}
