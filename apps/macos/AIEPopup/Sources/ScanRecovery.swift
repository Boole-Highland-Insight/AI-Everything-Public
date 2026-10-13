import Foundation

enum ScanRecoveryLane: String, Codable {
    case local
    case llm

    var storageKey: String { "aie.scan.recovery.\(rawValue).v1" }
}

/// Tiny durable checkpoints for user-visible interruption recovery. The real source of truth stays
/// in sidecars and SQLite: on relaunch the scanners still recompute the missing work from completed
/// analysis records. This snapshot only explains to the user that the new run is resuming a prior one.
enum ScanRecovery {
    struct Snapshot: Codable {
        let lane: ScanRecoveryLane
        var scanned: Int
        var remaining: Int
        var failed: Int
        var skipped: Int
        var currentFile: String?
        var updatedAt: TimeInterval
        var pausedByUser: Bool
    }

    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    static func begin(lane: ScanRecoveryLane, scanned: Int, remaining: Int, failed: Int, skipped: Int,
                      defaults: UserDefaults = .standard, now: TimeInterval = Date().timeIntervalSince1970) {
        save(Snapshot(
            lane: lane,
            scanned: scanned,
            remaining: remaining,
            failed: failed,
            skipped: skipped,
            currentFile: nil,
            updatedAt: now,
            pausedByUser: false
        ), defaults: defaults)
    }

    static func update(lane: ScanRecoveryLane, scanned: Int, remaining: Int, failed: Int, skipped: Int,
                       currentFile: String?, defaults: UserDefaults = .standard,
                       now: TimeInterval = Date().timeIntervalSince1970) {
        var snapshot = load(lane, defaults: defaults) ?? Snapshot(
            lane: lane,
            scanned: scanned,
            remaining: remaining,
            failed: failed,
            skipped: skipped,
            currentFile: currentFile,
            updatedAt: now,
            pausedByUser: false
        )
        snapshot.scanned = scanned
        snapshot.remaining = remaining
        snapshot.failed = failed
        snapshot.skipped = skipped
        snapshot.currentFile = currentFile
        snapshot.updatedAt = now
        snapshot.pausedByUser = false
        save(snapshot, defaults: defaults)
    }

    static func markPaused(_ lane: ScanRecoveryLane, defaults: UserDefaults = .standard,
                           now: TimeInterval = Date().timeIntervalSince1970) {
        guard var snapshot = load(lane, defaults: defaults) else { return }
        snapshot.pausedByUser = true
        snapshot.updatedAt = now
        save(snapshot, defaults: defaults)
    }

    static func finish(_ lane: ScanRecoveryLane, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lane.storageKey)
    }

    static func interruptedSnapshot(for lane: ScanRecoveryLane, defaults: UserDefaults = .standard,
                                    now: TimeInterval = Date().timeIntervalSince1970) -> Snapshot? {
        guard let snapshot = load(lane, defaults: defaults), snapshot.remaining > 0,
              !snapshot.pausedByUser else { return nil }
        if now - snapshot.updatedAt > staleAfter {
            finish(lane, defaults: defaults)
            return nil
        }
        return snapshot
    }

    private static func load(_ lane: ScanRecoveryLane, defaults: UserDefaults) -> Snapshot? {
        guard let data = defaults.data(forKey: lane.storageKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func save(_ snapshot: Snapshot, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshot.lane.storageKey)
    }
}
