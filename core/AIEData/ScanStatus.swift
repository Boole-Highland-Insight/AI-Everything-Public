import Foundation
import GRDB

/// One current file and its persisted extraction results, independent of worker lifetime.
public struct FileScanStatus: Sendable {
    public let path: String
    public let versionID: String
    public let rootPath: String
    public let relativePath: String
    public let ext: String
    public let deferred: Bool
    public var stages: [String: ScanStage]
}

extension ContentStore {
    private static let recognitionSkipPrefix = "local-skipped:"
    private static let understandingSkipPrefix = "deep-skipped:"
    private static let recognitionStatusSQL = """
        CASE WHEN s.stage='local' AND s.status='pending' AND j.state IN ('failed','pending')
                  AND j.attempt_count>=j.max_attempts
             THEN 'failed' ELSE s.status END
        """

    public func isRecognitionSkipped(path: String, versionID: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_preferences WHERE path=? AND name=? AND value=1)",
                arguments: [path, Self.recognitionSkipPrefix + versionID]) ?? false
        }
    }

    public func skipRecognitionTask(path: String, versionID: String, rootPaths: [String]) throws {
        guard !rootPaths.isEmpty else { throw DataLayerError.staleVersion }
        let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
        try database.write { db in
            guard let status = try String.fetchOne(db, sql: """
                SELECT \(Self.recognitionStatusSQL) FROM files f JOIN roots r ON r.id=f.root_id
                JOIN scan_jobs s ON s.version_id=f.current_version_id AND s.stage='local'
                LEFT JOIN jobs j ON j.subject_type='item_version' AND j.subject_id=f.current_version_id
                    AND j.job_type='local'
                    AND j.input_hash=(SELECT content_hash FROM file_versions WHERE id=f.current_version_id)
                WHERE f.path=? AND f.current_version_id=? AND f.present=1 AND r.active=1
                  AND r.path IN (\(placeholders))
                """, arguments: StatementArguments([path, versionID] + rootPaths)),
                  ["failed", "empty", "limited", "needs_review"].contains(status) else {
                throw DataLayerError.invalidDocument("当前文件版本没有可跳过的识别失败项")
            }
            let running = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM jobs WHERE subject_type='item_version' AND subject_id=?
                    AND job_type='local' AND state='running' AND lease_expires_at>?)
                """, arguments: [versionID, Date().timeIntervalSince1970]) ?? false
            guard !running else { throw DataLayerError.invalidDocument("该文件正在识别，请等待当前任务结束") }
            try db.execute(sql: """
                INSERT INTO file_preferences(path,name,value) VALUES(?,?,1)
                ON CONFLICT(path,name) DO UPDATE SET value=1
                """, arguments: [path, Self.recognitionSkipPrefix + versionID])
        }
    }

    public func isDeepUnderstandingSkipped(path: String, versionID: String) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_preferences WHERE path=? AND name=? AND value=1)",
                arguments: [path, Self.understandingSkipPrefix + versionID]) ?? false
        }
    }

    public func skipDeepUnderstandingTask(path: String, versionID: String, rootPaths: [String]) throws {
        guard !rootPaths.isEmpty else { throw DataLayerError.staleVersion }
        let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
        try database.write { db in
            guard let status = try String.fetchOne(db, sql: """
                SELECT s.status FROM files f JOIN roots r ON r.id=f.root_id
                JOIN scan_jobs s ON s.version_id=f.current_version_id AND s.stage='deep'
                WHERE f.path=? AND f.current_version_id=? AND f.present=1 AND r.active=1
                  AND r.path IN (\(placeholders))
                """, arguments: StatementArguments([path, versionID] + rootPaths)),
                  ["failed", "empty", "limited", "needs_review"].contains(status) else {
                throw DataLayerError.invalidDocument("当前文件版本没有可跳过的8B失败项")
            }
            let running = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM jobs WHERE subject_type='item_version' AND subject_id=?
                    AND job_type='deep' AND state='running' AND lease_expires_at>?)
                """, arguments: [versionID, Date().timeIntervalSince1970]) ?? false
            guard !running else { throw DataLayerError.invalidDocument("该文件正在深度理解，请等待当前任务结束") }
            try db.execute(sql: """
                INSERT INTO file_preferences(path,name,value) VALUES(?,?,1)
                ON CONFLICT(path,name) DO UPDATE SET value=1
                """, arguments: [path, Self.understandingSkipPrefix + versionID])
        }
    }

    /// Historical versions and deselected roots must never inflate the visible work queue.
    /// scan_jobs has one result per version/stage; jobs can contain several model/protocol runs.
    public func scanStatus(rootPaths: [String]) throws -> [FileScanStatus] {
        guard !rootPaths.isEmpty else { return [] }
        let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.path, f.current_version_id, r.path AS root_path, f.relative_path, f.ext,
                    coalesce(p.value,0) AS deferred, coalesce(k.value,0) AS recognition_skipped,
                    coalesce(dk.value,0) AS understanding_skipped,
                    s.stage, \(Self.recognitionStatusSQL) AS status, s.error
                FROM files f JOIN roots r ON r.id=f.root_id
                LEFT JOIN scan_jobs s ON s.version_id=f.current_version_id
                    AND s.stage IN ('index','local','deep','quick')
                LEFT JOIN file_preferences p ON p.path=f.path AND p.name='deferred'
                LEFT JOIN file_preferences k ON k.path=f.path AND k.name=? || f.current_version_id
                LEFT JOIN file_preferences dk ON dk.path=f.path AND dk.name=? || f.current_version_id
                LEFT JOIN jobs j ON j.subject_type='item_version' AND j.subject_id=f.current_version_id
                    AND j.job_type='local'
                    AND j.input_hash=(SELECT content_hash FROM file_versions WHERE id=f.current_version_id)
                WHERE f.present=1 AND r.active=1 AND r.path IN (\(placeholders))
                ORDER BY f.path,s.stage
                """, arguments: StatementArguments([Self.recognitionSkipPrefix, Self.understandingSkipPrefix] + rootPaths))
            var files: [FileScanStatus] = []
            for row in rows {
                let path: String = row["path"]
                if files.last?.path != path {
                    files.append(FileScanStatus(
                        path: path, versionID: row["current_version_id"], rootPath: row["root_path"], relativePath: row["relative_path"],
                        ext: row["ext"], deferred: row["deferred"], stages: [:]
                    ))
                }
                if let stage: String = row["stage"] {
                    let skipped = stage == "local" && (row["recognition_skipped"] as Bool)
                        || stage == "deep" && (row["understanding_skipped"] as Bool)
                    files[files.count - 1].stages[stage] = ScanStage(
                        stage, status: skipped ? "skipped" : row["status"], error: row["error"]
                    )
                }
            }
            return files
        }
    }
}

/// Learns active processing time only. Callers exclude idle, paused and interrupted work.
public struct ScanTimingEstimate: Codable, Sendable {
    private struct Sample: Codable, Sendable {
        var units: Int
        var seconds: Double
    }
    private var samples: [String: Sample] = [:]

    public init() {}

    public mutating func record(key: String, units: Int = 1, seconds: Double) {
        guard units > 0, seconds.isFinite, seconds > 0 else { return }
        var sample = samples[key] ?? Sample(units: 0, seconds: 0)
        if sample.units >= 100 {
            sample.units /= 2
            sample.seconds /= 2
        }
        sample.units += units
        sample.seconds += seconds
        samples[key] = sample
    }

    /// No estimate until every remaining kind has actual measurements on this machine.
    public func remainingSeconds(work: [String: Int]) -> Double? {
        var seconds = 0.0
        for (key, count) in work where count > 0 {
            guard let sample = samples[key], sample.units >= 3 else { return nil }
            seconds += Double(count) * sample.seconds / Double(sample.units)
        }
        return seconds
    }
}

/// Read-only display snapshot; no task creation, model loading, or index writes.
public struct IndexingDisplaySnapshot: Sendable {
    public let files: [FileScanStatus]
    public let semanticReady: Int?
    public let semanticTotal: Int?
    public let semanticFailed: Int
    public let runningStages: Set<String>
}

public struct SemanticDisplaySnapshot: Sendable {
    public let ready: Int
    public let total: Int
    public let failed: Int
}

extension ContentStore {
    public func indexingFileSnapshot(rootPaths: [String]) throws -> IndexingDisplaySnapshot {
        let files = try scanStatus(rootPaths: rootPaths)
        let active = try database.read { db -> Set<String> in
            guard !rootPaths.isEmpty else { return [] }
            let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
            let active = try String.fetchAll(db, sql: """
                SELECT DISTINCT j.job_type FROM jobs j
                JOIN files f ON f.current_version_id=j.subject_id
                JOIN file_versions v ON v.id=f.current_version_id JOIN roots r ON r.id=f.root_id
                WHERE f.present=1 AND r.active=1 AND r.path IN (\(placeholders))
                  AND j.state='running'
                  AND j.lease_expires_at>?
                """, arguments: StatementArguments(rootPaths) + [Date().timeIntervalSince1970])
            return Set(active)
        }
        return IndexingDisplaySnapshot(files: files, semanticReady: nil, semanticTotal: nil,
            semanticFailed: 0, runningStages: active)
    }

    public func indexingSemanticSnapshot(rootPaths: [String]) throws -> SemanticDisplaySnapshot {
        let revision = try database.read { db -> String? in
            guard !rootPaths.isEmpty else { return nil }
            let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
            let revisions = try String.fetchAll(db, sql: """
                SELECT DISTINCT x.model_revision FROM features x
                JOIN chunks c ON c.id=x.subject_id AND c.content_hash=x.content_hash
                JOIN files f ON f.current_version_id=c.version_id JOIN roots r ON r.id=f.root_id
                WHERE f.present=1 AND r.active=1 AND r.path IN (\(placeholders))
                  AND x.subject_type='content_unit' AND x.model_key LIKE 'gemma2:%'
                  AND x.vector_format='f16-le-v1-normalized'
                LIMIT 2
                """, arguments: StatementArguments(rootPaths))
            return revisions.count == 1 ? revisions[0] : nil
        }
        // Before the first Gemma vector exists, count targets against a nonmatching space.
        // Multiple model revisions are deliberately not merged into one completion percentage.
        let prefix = "gemma2:" + (revision ?? "display-uninitialized") + ":"
        let raw = try embeddingCoverage(spaceID: prefix + "raw-text-v1", rootPaths: rootPaths,
            rawTextOnly: true, includeAllTextKinds: true)
        let visual = try visualEmbeddingCoverage(spaceID: prefix + "visual-page-v1", rootPaths: rootPaths)
        let failed = try database.read { db -> Int in
            guard !rootPaths.isEmpty else { return 0 }
            let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
            return try Int.fetchOne(db, sql: """
                SELECT count(*) FROM visual_embedding_attempts a
                JOIN chunks c ON c.id=a.chunk_id
                JOIN files f ON f.current_version_id=c.version_id JOIN roots r ON r.id=f.root_id
                WHERE f.present=1 AND r.active=1 AND r.path IN (\(placeholders)) AND a.model_key=?
                  AND NOT EXISTS(SELECT 1 FROM features x WHERE x.subject_id=c.id
                    AND x.content_hash=c.content_hash AND x.model_key=a.model_key
                    AND x.feature_type='visual_embedding' AND x.vector_format='f16-le-v1-normalized')
                """, arguments: StatementArguments(rootPaths) + [prefix + "visual-page-v1"]) ?? 0
        }
        return SemanticDisplaySnapshot(ready: raw.ready + visual.ready,
            total: raw.total + visual.total, failed: failed)
    }

    public func indexingDisplaySnapshot(rootPaths: [String]) throws -> IndexingDisplaySnapshot {
        let files = try indexingFileSnapshot(rootPaths: rootPaths)
        let semantic = try indexingSemanticSnapshot(rootPaths: rootPaths)
        return IndexingDisplaySnapshot(files: files.files, semanticReady: semantic.ready,
            semanticTotal: semantic.total, semanticFailed: semantic.failed, runningStages: files.runningStages)
    }
}
