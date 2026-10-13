import Foundation
import AIEData

/// Scanner-facing database adapter. Dictionaries are transient API values, never JSON files.
enum ScanRecords {
    static func relative(for file: IndexedFile) -> String {
        String(file.path.dropFirst(file.rootPath.count + 1))
    }
    static func read(_ file: IndexedFile) -> [String: Any]? { read(root: URL(fileURLWithPath: file.rootPath), relative: relative(for: file)) }
    static func read(root: URL, relative: String) -> [String: Any]? {
        do {
            let db = try AppDatabase.open()
            try db.ensureAnalysis(root: root.path, relative: relative) { [:] }
            return try db.analysis(root: root.path, relative: relative)
        } catch { AppDatabase.failed(error); return nil }
    }
    @discardableResult static func mutate(_ file: IndexedFile, _ body: (inout [String: Any]) -> Bool) -> Bool {
        mutate(root: URL(fileURLWithPath: file.rootPath), relative: relative(for: file), body)
    }
    @discardableResult static func mutate(root: URL, relative: String, _ body: (inout [String: Any]) -> Bool) -> Bool {
        do {
            let db = try AppDatabase.open()
            try db.ensureAnalysis(root: root.path, relative: relative) { [:] }
            return try db.mutateAnalysis(root: root.path, relative: relative, body)
        } catch { AppDatabase.failed(error); return false }
    }
}
