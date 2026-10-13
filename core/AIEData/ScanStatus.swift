import Foundation
import GRDB

/// One current file and its persisted extraction results, independent of worker lifetime.
public struct FileScanStatus: Sendable {
    public let path: String
    public let rootPath: String
    public let relativePath: String
    public let ext: String
    public let deferred: Bool
    public var stages: [String: ScanStage]
}

extension ContentStore {
    /// Historical versions and deselected roots must never inflate the visible work queue.
    /// scan_jobs has one result per version/stage; jobs can contain several model/protocol runs.
    public func scanStatus(rootPaths: [String]) throws -> [FileScanStatus] {
        guard !rootPaths.isEmpty else { return [] }
        let placeholders = rootPaths.map { _ in "?" }.joined(separator: ",")
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.path, r.path AS root_path, f.relative_path, f.ext,
                    coalesce(p.value,0) AS deferred, s.stage, s.status, s.error
                FROM files f JOIN roots r ON r.id=f.root_id
                LEFT JOIN scan_jobs s ON s.version_id=f.current_version_id
                    AND s.stage IN ('index','local','deep','quick')
                LEFT JOIN file_preferences p ON p.path=f.path AND p.name='deferred'
                WHERE f.present=1 AND r.active=1 AND r.path IN (\(placeholders))
                ORDER BY f.path,s.stage
                """, arguments: StatementArguments(rootPaths))
            var files: [FileScanStatus] = []
            for row in rows {
                let path: String = row["path"]
                if files.last?.path != path {
                    files.append(FileScanStatus(
                        path: path, rootPath: row["root_path"], relativePath: row["relative_path"],
                        ext: row["ext"], deferred: row["deferred"], stages: [:]
                    ))
                }
                if let stage: String = row["stage"] {
                    files[files.count - 1].stages[stage] = ScanStage(
                        stage, status: row["status"], error: row["error"]
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
