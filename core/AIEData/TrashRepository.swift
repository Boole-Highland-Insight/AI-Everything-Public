import Foundation
import GRDB

public struct StoredTrash: Sendable {
    public let id: String
    public let originalPath: String
    public let rootPath: String
    public let relativePath: String
    public let name: String
    public let kind: String
    public let ext: String
    public let trashedAt: Double
    public let storedPath: String
    public let analysisID: String?
    public var state: String
    public var restorePath: String?
    public let contentHash: String?
    public init(id: String, originalPath: String, rootPath: String, relativePath: String, name: String, kind: String, ext: String,
                trashedAt: Double, storedPath: String, analysisID: String?, state: String, restorePath: String? = nil, contentHash: String? = nil) {
        self.id = id; self.originalPath = originalPath; self.rootPath = rootPath; self.relativePath = relativePath; self.name = name
        self.kind = kind; self.ext = ext; self.trashedAt = trashedAt; self.storedPath = storedPath; self.analysisID = analysisID
        self.state = state; self.restorePath = restorePath; self.contentHash = contentHash
    }
}

extension ContentStore {
    public func analysisIdentity(root: String, relative: String) throws -> String? {
        try database.read { db in try String.fetchOne(db, sql: "SELECT id FROM analysis_records WHERE root_path=? AND relative_path=?", arguments: [root,relative]) }
    }
    public func saveTrash(_ record: StoredTrash) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO trash_records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,restore_path=excluded.restore_path",
                           arguments: [record.id,record.originalPath,record.rootPath,record.relativePath,record.name,record.kind,record.ext,
                                       record.trashedAt,record.storedPath,record.analysisID,record.state,record.restorePath,record.contentHash])
        }
    }
    public func trashRecords() throws -> [StoredTrash] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trash_records WHERE state NOT IN ('restored','purged','cancelled') ORDER BY trashed_at DESC").map { row in
                StoredTrash(id: row["id"], originalPath: row["original_path"], rootPath: row["root_path"], relativePath: row["relative_path"],
                            name: row["name"], kind: row["kind"], ext: row["ext"], trashedAt: row["trashed_at"], storedPath: row["stored_path"],
                            analysisID: row["analysis_id"], state: row["state"], restorePath: row["restore_path"], contentHash: row["content_hash"])
            }
        }
    }
    public func finishTrash(_ record: StoredTrash, state: String, restoredRelative: String? = nil) throws {
        try database.write { db in
            if state == "restored", let relative = restoredRelative, let id = record.analysisID {
                try self.moveAnalysis(id, root: record.rootPath, relative: relative, db: db)
                // Filesystem identity may be reassigned by the next enumeration, but preferences follow the managed move.
                let path = record.rootPath + "/" + relative
                try db.execute(sql: "UPDATE OR IGNORE file_preferences SET path=? WHERE path=?", arguments: [path,record.originalPath])
            }
            if state == "trashed", let id = record.analysisID {
                try self.moveAnalysis(id, root: "trash://" + record.id, relative: record.name, db: db)
            }
            if state == "trashed", let id = record.analysisID {
                try db.execute(sql: "UPDATE files SET present=0 WHERE id=(SELECT file_id FROM analysis_records WHERE id=?) AND path=?", arguments: [id,record.originalPath])
            }
            try db.execute(sql: "UPDATE trash_records SET state=? WHERE id=?", arguments: [state,record.id])
        }
    }
}
