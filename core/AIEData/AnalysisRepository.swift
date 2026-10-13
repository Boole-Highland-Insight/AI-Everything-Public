import Foundation
import CoreFoundation
import GRDB

/// Scanner results are stored as typed relational values, not serialized JSON documents.
/// This preserves heterogeneous Vision/model fields while chunks and semantics have dedicated tables.
extension ContentStore {
    public func analysisID(root: String, relative: String) -> String { ContentIdentity.digest(root + "/" + relative) }

    public func ensureAnalysis(root: String, relative: String, fileID: String? = nil,
                               legacy: () throws -> [String: Any]) throws {
        try database.write { db in
            let id = UUID().uuidString
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM analysis_records WHERE root_path=? AND relative_path=?", arguments: [root,relative]) {
                if let fileID { try db.execute(sql: "UPDATE analysis_records SET file_id=? WHERE id=?", arguments: [fileID,existing]) }
                return
            }
            // Same-root rename: move the existing analysis identity instead of re-importing old files.
            if let fileID, let old = try String.fetchOne(db, sql: "SELECT id FROM analysis_records WHERE file_id=? AND root_path=?", arguments: [fileID,root]) {
                try self.moveAnalysis(old, root: root, relative: relative, db: db)
                return
            }
            let record = try legacy()
            try db.execute(sql: "INSERT INTO analysis_records(id,root_path,relative_path,file_id) VALUES(?,?,?,?)", arguments: [id,root,relative,fileID])
            try self.writeAnalysis(record, id: id, db: db)
            try db.execute(sql: "INSERT OR IGNORE INTO migration_imports VALUES(?,?,?)", arguments: ["analysis:" + id,Date().timeIntervalSince1970,try Int.fetchOne(db, sql: "SELECT count(*) FROM analysis_fields WHERE record_id=?", arguments: [id]) ?? 0])
        }
    }

    public func analysis(root: String, relative: String) throws -> [String: Any]? {
        try database.read { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM analysis_records WHERE root_path=? AND relative_path=?", arguments: [root,relative]) else { return nil }
            return try self.readAnalysis(id: id, db: db)
        }
    }

    @discardableResult public func mutateAnalysis(root: String, relative: String,
                                                  _ body: (inout [String: Any]) throws -> Bool) throws -> Bool {
        try database.write { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM analysis_records WHERE root_path=? AND relative_path=?", arguments: [root,relative]) else { throw DataLayerError.invalidDocument("Analysis not initialized") }
            var record = try self.readAnalysis(id: id, db: db)
            guard try body(&record) else { return false }
            try self.writeAnalysis(record, id: id, db: db)
            return true
        }
    }

    func readAnalysis(id: String, db: Database) throws -> [String: Any] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM analysis_fields WHERE record_id=? ORDER BY ordinal", arguments: [id])
        let children = Dictionary(grouping: rows, by: { ($0["parent_id"] as Int?) ?? -1 })
        func value(_ row: Row) -> Any {
            let id: Int = row["node_id"]; let type: String = row["value_type"]; let text: String = row["text_value"] ?? ""
            switch type {
            case "object": return Dictionary(uniqueKeysWithValues: (children[id] ?? []).map { ($0["name"] as String, value($0)) })
            case "array": return (children[id] ?? []).map(value)
            case "bool": return text == "1"
            case "integer":
                if let number = Int64(text) { return NSNumber(value: number) }
                if let number = UInt64(text) { return NSNumber(value: number) }
                return NSDecimalNumber(string: text)
            case "real": return Double(text) ?? 0
            case "decimal": return NSDecimalNumber(string: text)
            case "null": return NSNull()
            default: return text
            }
        }
        guard let root = children[-1]?.first else { return [:] }
        return value(root) as? [String: Any] ?? [:]
    }

    func writeAnalysis(_ record: [String: Any], id: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM analysis_fields WHERE record_id=?", arguments: [id])
        var next = 0
        func write(_ value: Any, parent: Int?, name: String?, ordinal: Int, depth: Int) throws {
            guard depth < 100 else { throw DataLayerError.invalidDocument("Analysis nesting exceeds limit") }
            let node = next; next += 1
            var type = "string"; var text: String?
            if value is [String: Any] { type = "object" }
            else if value is [Any] { type = "array" }
            else if value is NSNull { type = "null" }
            else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { type = "bool"; text = number.boolValue ? "1" : "0" }
                else if number is NSDecimalNumber {
                    guard number != NSDecimalNumber.notANumber else { throw DataLayerError.invalidDocument("Invalid decimal analysis value") }
                    type = "decimal"; text = number.stringValue
                }
                else {
                    guard number.doubleValue.isFinite else { throw DataLayerError.invalidDocument("Non-finite analysis value") }
                    type = ["f", "d"].contains(String(cString: number.objCType)) ? "real" : "integer"
                    text = type == "real" ? String(number.doubleValue) : number.stringValue
                }
            } else if let string = value as? String { text = string }
            else { throw DataLayerError.invalidDocument("Unsupported analysis field type") }
            try db.execute(sql: "INSERT INTO analysis_fields VALUES(?,?,?,?,?,?,?)", arguments: [id,node,parent,name,ordinal,type,text])
            if let object = value as? [String: Any] {
                for (order, key) in object.keys.sorted().enumerated() { try write(object[key]!, parent: node, name: key, ordinal: order, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for (order, child) in array.enumerated() { try write(child, parent: node, name: nil, ordinal: order, depth: depth + 1) }
            }
        }
        try write(record, parent: nil, name: nil, ordinal: 0, depth: 0)
        try db.execute(sql: "UPDATE analysis_records SET revision=revision+1 WHERE id=?", arguments: [id])
    }

    func moveAnalysis(_ id: String, root: String, relative: String, db: Database) throws {
        // IDs remain stable across moves; lookup is by root/path, not by recomputing the ID afterwards.
        try db.execute(sql: "UPDATE analysis_records SET root_path=?,relative_path=?,revision=revision+1 WHERE id=?", arguments: [root,relative,id])
    }

    public func changeToken() throws -> Int64 {
        try database.read { db in try Int64.fetchOne(db, sql: "SELECT coalesce(sum(revision),0) FROM analysis_records") ?? 0 }
    }
    public func preferencePaths(_ name: String) throws -> Set<String> {
        try database.read { db in Set(try String.fetchAll(db, sql: "SELECT path FROM file_preferences WHERE name=? AND value=1", arguments: [name])) }
    }
    public func setPreference(path: String, name: String, value: Bool) throws {
        try database.write { db in try db.execute(sql: "INSERT INTO file_preferences VALUES(?,?,?) ON CONFLICT(path,name) DO UPDATE SET value=excluded.value", arguments: [path,name,value]) }
    }
    public func importPreferences(_ values: [String: [String]]) throws {
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_imports WHERE source='preferences-v1'") == 0 else { return }
            for (name, paths) in values { for path in paths { try db.execute(sql: "INSERT OR IGNORE INTO file_preferences VALUES(?,?,1)", arguments: [path,name]) } }
            try db.execute(sql: "INSERT INTO migration_imports VALUES('preferences-v1',?,0)", arguments: [Date().timeIntervalSince1970])
        }
    }
    public func acquireLease(recordID: String, scope: String, owner: String) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "INSERT INTO work_leases VALUES(?,?,?,?) ON CONFLICT(record_id,scope) DO UPDATE SET owner=excluded.owner,expires_at=excluded.expires_at WHERE work_leases.expires_at < ? OR work_leases.owner=excluded.owner",
                           arguments: [recordID,scope,owner,Date().timeIntervalSince1970 + 600,Date().timeIntervalSince1970])
            return db.changesCount == 1
        }
    }
    public func releaseLease(recordID: String, scope: String, owner: String) throws {
        try database.write { db in try db.execute(sql: "DELETE FROM work_leases WHERE record_id=? AND scope=? AND owner=?", arguments: [recordID,scope,owner]) }
    }
    public func backup(to path: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        try database.backup(to: DatabaseQueue(path: path))
    }
    public func compactCopy(to path: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        do {
            try database.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [path])
            }
            let copy = try DatabaseQueue(path: path)
            let valid = try copy.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
                    && Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
            }
            guard valid else { throw DataLayerError.invalidDocument("Compacted database failed integrity checks") }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? fm.removeItem(atPath: path)
            throw error
        }
    }
}

extension ContentStore {
    public func hasImported(_ source: String) throws -> Bool {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM migration_imports WHERE source=?", arguments: [source]) == 1 }
    }
    public func markImported(_ source: String) throws {
        try database.write { db in try db.execute(sql: "INSERT OR IGNORE INTO migration_imports VALUES(?,?,0)", arguments: [source,Date().timeIntervalSince1970]) }
    }
}
