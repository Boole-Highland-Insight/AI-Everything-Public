import Foundation
import GRDB

public struct PhotoAssetSnapshot: Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let kind: String
    public let revision: String
    public let capturedAt: Date
    public let modifiedAt: Date
    public let duration: Double

    public init(id: String, path: String, name: String, kind: String, revision: String,
                capturedAt: Date, modifiedAt: Date, duration: Double) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.revision = revision
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.duration = duration
    }
}

public struct PhotoQueueProgress: Sendable {
    public let ready: Int
    public let pending: Int
    public let failed: Int
    public let total: Int
}

public extension ContentStore {
    /// Reconciles an authorized Photos snapshot and returns assets whose local analysis image
    /// still needs to be materialized. Removed assets immediately lose `present` visibility.
    func synchronizePhotoAssets(_ assets: [PhotoAssetSnapshot], rootPath: String) throws -> [String] {
        guard Set(assets.map(\.id)).count == assets.count,
              Set(assets.map(\.path)).count == assets.count,
              assets.allSatisfy({ $0.path.hasPrefix(rootPath + "/") && !$0.revision.isEmpty
                  && !$0.path.split(separator: "/").contains("..") }) else {
            throw DataLayerError.invalidDocument("Invalid Photos snapshot")
        }
        return try database.write { db in
            try db.execute(sql: "UPDATE photo_assets SET present=0 WHERE root_path=?", arguments: [rootPath])
            for asset in assets {
                try db.execute(sql: """
                    INSERT INTO photo_assets(
                        asset_id,root_path,path,name,kind,revision,captured_at,modified_at,duration,
                        present,local_status,deep_status,error,retry_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,1,'pending','pending',NULL,0)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        root_path=excluded.root_path,path=excluded.path,name=excluded.name,kind=excluded.kind,
                        local_status=CASE WHEN photo_assets.revision<>excluded.revision THEN 'pending' ELSE photo_assets.local_status END,
                        deep_status=CASE WHEN photo_assets.revision<>excluded.revision THEN 'pending' ELSE photo_assets.deep_status END,
                        error=CASE WHEN photo_assets.revision<>excluded.revision THEN NULL ELSE photo_assets.error END,
                        retry_at=CASE WHEN photo_assets.revision<>excluded.revision THEN 0 ELSE photo_assets.retry_at END,
                        revision=excluded.revision,captured_at=excluded.captured_at,
                        modified_at=excluded.modified_at,duration=excluded.duration,present=1
                    """, arguments: [
                        asset.id, rootPath, asset.path, asset.name, asset.kind, asset.revision,
                        asset.capturedAt.timeIntervalSince1970, asset.modifiedAt.timeIntervalSince1970, asset.duration
                    ])
            }
            return try String.fetchAll(db, sql: """
                SELECT asset_id FROM photo_assets
                WHERE root_path=? AND present=1 AND local_status<>'ready' AND retry_at<=?
                ORDER BY captured_at DESC, asset_id
                """, arguments: [rootPath, Date().timeIntervalSince1970])
        }
    }

    @discardableResult
    func updatePhotoAsset(id: String, revision: String, localStatus: String, error: String? = nil, retryAt: Date? = nil) throws -> Bool {
        guard ["pending", "downloading", "ready", "failed"].contains(localStatus) else {
            throw DataLayerError.invalidDocument("Invalid Photos queue state")
        }
        return try database.write { db in
            try db.execute(
                sql: "UPDATE photo_assets SET local_status=?,error=?,retry_at=? WHERE asset_id=? AND revision=? AND present=1",
                arguments: [localStatus, error, retryAt?.timeIntervalSince1970 ?? 0, id, revision]
            )
            return db.changesCount == 1
        }
    }

    /// Old snapshots stay on disk until explicitly removed, but stale or deleted assets must
    /// stop appearing in search. Unknown paths are legacy, manually imported copies.
    func excludedPhotoPaths(rootPath: String) throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT path FROM photo_assets WHERE root_path=? AND (present=0 OR local_status<>'ready')", arguments: [rootPath]))
        }
    }

    func nextPhotoRetry(rootPath: String) throws -> Date? {
        try database.read { db in
            try Double.fetchOne(db, sql: "SELECT min(retry_at) FROM photo_assets WHERE root_path=? AND present=1 AND local_status='failed'", arguments: [rootPath])
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    func retryPhotoAssets(rootPath: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE photo_assets SET retry_at=0 WHERE root_path=? AND present=1 AND local_status='failed'", arguments: [rootPath])
        }
    }

    func photoQueueProgress(rootPath: String) throws -> PhotoQueueProgress {
        try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    sum(CASE WHEN local_status='ready' THEN 1 ELSE 0 END) AS ready,
                    sum(CASE WHEN local_status='pending' OR local_status='downloading' THEN 1 ELSE 0 END) AS pending,
                    sum(CASE WHEN local_status='failed' THEN 1 ELSE 0 END) AS failed,
                    count(*) AS total
                FROM photo_assets WHERE root_path=? AND present=1
                """, arguments: [rootPath])
            return PhotoQueueProgress(
                ready: row?["ready"] ?? 0,
                pending: row?["pending"] ?? 0,
                failed: row?["failed"] ?? 0,
                total: row?["total"] ?? 0
            )
        }
    }
}
