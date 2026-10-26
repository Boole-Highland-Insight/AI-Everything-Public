import Foundation
import AIEData

struct TrashItem: Identifiable, Equatable {
    let id: String
    let originalPath: String
    let name: String
    let relative: String
    let kind: FileKind
    let ext: String
    let trashedAt: Date
    let storedPath: String

    var daysLeft: Int {
        TrashBin.daysLeft(from: trashedAt)
    }

    var reason: String {
        let days = daysLeft
        if days <= 0 { return "即将清除" }
        if days >= TrashBin.keepDays { return "剩余 \(TrashBin.keepDays) 天" }
        return "剩余 \(days) 天"
    }
}

/// SQLite records journal each move before the filesystem operation. Originals are never overwritten.
enum TrashBin {
    static let keepDays = 30
    private static let fm = FileManager.default
    private static var root: URL {
        if let path = ProcessInfo.processInfo.environment["AIE_TRASH_PATH"] { return URL(fileURLWithPath: path) }
        if AIEApplicationPaths.isCleanV2 { return AIEApplicationPaths.support.appendingPathComponent("Trash") }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AI Everything/Trash")
    }
    private static var filesRoot: URL { root.appendingPathComponent("files") }
    private struct LegacyRecord: Decodable {
        let id: String, originalPath: String, name: String, relative: String, kind: String, ext: String, storedName: String
        let trashedAt: Date
    }
    static func daysLeft(from date: Date, now: Date = Date()) -> Int {
        let expiry = Calendar.current.date(byAdding: .day, value: keepDays, to: date) ?? date
        return max(0, Calendar.current.dateComponents([.day], from: now, to: expiry).day ?? 0)
    }
    private static func owner(of path: String, roots: [URL]) -> URL? {
        roots.sorted { $0.path.count > $1.path.count }.first {
            path.hasPrefix($0.path + "/") && URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }
    private static func checkedDirectory(_ id: String) throws -> URL {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/") else { throw CocoaError(.fileReadCorruptFile) }
        let parent = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let dir = parent.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: dir.path) {
            guard dir.resolvingSymlinksInPath().path.hasPrefix(parent.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        }
        return dir
    }
    private static func checkedStored(_ rec: StoredTrash) throws -> URL {
        let dir = try checkedDirectory(rec.id)
        let url = URL(fileURLWithPath: rec.storedPath)
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == dir.standardizedFileURL.resolvingSymlinksInPath().path,
              url.resolvingSymlinksInPath().path.hasPrefix(dir.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.fileReadNoPermission) }
        return url
    }
    private static func database(roots: [URL] = []) throws -> ContentStore {
        let db = try AppDatabase.open()
        try fm.createDirectory(at: filesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = "legacy-trash:" + root.path
        guard try !db.hasImported(marker) else { return db }
        let manifest = root.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifest.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([LegacyRecord].self, from: Data(contentsOf: manifest))
            for old in records {
                let itemMarker = marker + ":" + old.id
                if try db.hasImported(itemMarker) { continue }
                let dir = try checkedDirectory(old.id)
                guard old.storedName == URL(fileURLWithPath: old.storedName).lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
                let source = owner(of: old.originalPath, roots: roots) ?? URL(fileURLWithPath: old.originalPath).deletingLastPathComponent()
                let relative = String(old.originalPath.dropFirst(source.path.count + 1))
                let archiveRoot = "trash://" + old.id
                try db.ensureAnalysis(root: archiveRoot, relative: old.name) {
                    let sidecar = dir.appendingPathComponent("sidecar.json")
                    guard fm.fileExists(atPath: sidecar.path) else { return [:] }
                    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                    return value
                }
                let stored = dir.appendingPathComponent(old.storedName)
                let hash = fm.fileExists(atPath: stored.path) ? try ContentIdentity.hashFile(stored) : nil
                try db.saveTrash(StoredTrash(id: old.id, originalPath: old.originalPath, rootPath: source.path, relativePath: relative,
                    name: old.name, kind: old.kind, ext: old.ext, trashedAt: old.trashedAt.timeIntervalSince1970, storedPath: stored.path,
                    analysisID: try db.analysisIdentity(root: archiveRoot, relative: old.name), state: "trashed", contentHash: hash))
                try db.markImported(itemMarker)
            }
        }
        try db.markImported(marker)
        return db
    }
    /// Only finish operations whose outcome is unambiguous. Uncertain copies remain recoverable.
    private static func recover(_ db: ContentStore) throws {
        for rec in try db.trashRecords() {
            let stored = try checkedStored(rec), storedExists = fm.fileExists(atPath: stored.path)
            if rec.state == "moving" {
                let originalExists = fm.fileExists(atPath: rec.originalPath)
                if storedExists && !originalExists { try db.finishTrash(rec, state: "trashed") }
                else if !storedExists && originalExists { try db.finishTrash(rec, state: "cancelled") }
            } else if rec.state == "restoring", let path = rec.restorePath {
                if !storedExists && fm.fileExists(atPath: path), path.hasPrefix(rec.rootPath + "/"),
                   let expected = rec.contentHash, try ContentIdentity.hashFile(URL(fileURLWithPath: path)) == expected {
                    try db.finishTrash(rec, state: "restored", restoredRelative: String(path.dropFirst(rec.rootPath.count + 1)))
                } else if storedExists && !fm.fileExists(atPath: path) {
                    try db.finishTrash(rec, state: "trashed")
                }
            } else if rec.state == "purging" && !storedExists { try db.finishTrash(rec, state: "purged") }
        }
    }
    static func load() -> [TrashItem] {
        do {
            let db = try database(roots: ProcessInfo.processInfo.environment["AIE_TRASH_PATH"] == nil ? LibraryRoots.load() : [])
            try recover(db)
            if !AIEApplicationPaths.isCleanV2 { try sweepExpired(db) }
            return try db.trashRecords().filter { $0.state == "trashed" || $0.state == "moving" || $0.state == "restoring" }.compactMap { rec in
                let stored = try checkedStored(rec)
                guard fm.fileExists(atPath: stored.path) else { return nil }
                return TrashItem(id: rec.id, originalPath: rec.originalPath, name: rec.name, relative: rec.relativePath,
                    kind: FileKind(rawValue: rec.kind) ?? .other, ext: rec.ext, trashedAt: Date(timeIntervalSince1970: rec.trashedAt), storedPath: stored.path)
            }
        } catch { AppDatabase.failed(error); return [] }
    }
    @discardableResult static func ingest(paths: [String], files: [IndexedFile], roots: [URL]) -> [String] {
        var moved: [String] = []
        do {
            let db = try database(roots: roots)
            for path in paths {
                guard let source = owner(of: path, roots: roots), let file = files.first(where: { $0.path == path }), fm.fileExists(atPath: path) else { continue }
                let relative = String(path.dropFirst(source.path.count + 1)), id = UUID().uuidString
                let dir = try checkedDirectory(id)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(file.name)
                let rec = StoredTrash(id: id, originalPath: path, rootPath: source.path, relativePath: relative, name: file.name,
                    kind: file.kind.rawValue, ext: file.ext, trashedAt: Date().timeIntervalSince1970, storedPath: dest.path,
                    analysisID: try db.analysisIdentity(root: source.path, relative: relative), state: "moving",
                    contentHash: try ContentIdentity.hashFile(URL(fileURLWithPath: path)))
                try db.saveTrash(rec)
                try relocate(from: URL(fileURLWithPath: path), to: dest)
                try db.finishTrash(rec, state: "trashed")
                moved.append(path)
            }
        } catch { AppDatabase.failed(error) }
        return moved
    }
    static func restore(ids: [String], roots: [URL]) {
        do {
            let db = try database(roots: roots); try recover(db)
            for var rec in try db.trashRecords() where ids.contains(rec.id) && rec.state == "trashed" {
                guard owner(of: rec.originalPath, roots: roots) != nil else { continue }
                let stored = try checkedStored(rec)
                guard fm.fileExists(atPath: stored.path) else { continue }
                let dest = try availableURL(original: URL(fileURLWithPath: rec.originalPath), record: rec, db: db)
                guard owner(of: dest.path, roots: roots) != nil else { throw CocoaError(.fileWriteNoPermission) }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                rec.state = "restoring"; rec.restorePath = dest.path
                try db.saveTrash(rec)
                try relocate(from: stored, to: dest)
                try db.finishTrash(rec, state: "restored", restoredRelative: String(dest.path.dropFirst(rec.rootPath.count + 1)))
                // Legacy sidecars stay in their archived folder as migration backups.
            }
        } catch { AppDatabase.failed(error) }
    }
    static func purge(ids: [String]) {
        do { let db = try database(); try purge(ids: ids, db: db) }
        catch { AppDatabase.failed(error) }
    }
    private static func purge(ids: [String], db: ContentStore) throws {
        for var rec in try db.trashRecords() where ids.contains(rec.id) && (rec.state == "trashed" || rec.state == "purging") {
            let dir = try checkedDirectory(rec.id)
            rec.state = "purging"; try db.saveTrash(rec)
            if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
            try db.finishTrash(rec, state: "purged")
        }
    }
    static func sweepExpired() {
        do { try sweepExpired(database()) } catch { AppDatabase.failed(error) }
    }
    private static func sweepExpired(_ db: ContentStore) throws {
        let expired = try db.trashRecords().filter { $0.state == "trashed" && Date().timeIntervalSince1970 - $0.trashedAt >= Double(keepDays * 86400) }
        try purge(ids: expired.map(\.id), db: db)
    }
    private static func relocate(from: URL, to: URL) throws {
        guard !fm.fileExists(atPath: to.path) else { throw CocoaError(.fileWriteFileExists) }
        // FileManager implements cross-volume moves. Never remove/overwrite a pre-existing destination.
        try fm.moveItem(at: from, to: to)
    }
    private static func availableURL(original: URL, record: StoredTrash, db: ContentStore) throws -> URL {
        let stem = original.deletingPathExtension().lastPathComponent, ext = original.pathExtension
        for number in 0...10000 {
            let name = number == 0 ? original.lastPathComponent : stem + " 还原\(number)" + (ext.isEmpty ? "" : "." + ext)
            let url = original.deletingLastPathComponent().appendingPathComponent(name)
            let relative = String(url.path.dropFirst(record.rootPath.count + 1))
            if !fm.fileExists(atPath: url.path), try db.analysisIdentity(root: record.rootPath, relative: relative) == nil { return url }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
