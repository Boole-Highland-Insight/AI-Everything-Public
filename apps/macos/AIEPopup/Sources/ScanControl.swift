import Foundation
import Combine

/// Cooperative pause shared by both scanning lanes. The current file is allowed to finish;
/// queued work remains in memory and is resumed by the next enqueue pass.
final class ScanControl: ObservableObject {
    static let shared = ScanControl()
    @Published private(set) var paused: Bool
    private let lock = NSLock()
    private var storedPaused: Bool
    private var interactiveUntil: TimeInterval = 0
    private var storedInteractiveRevision: UInt64 = 0
    private var heavyModelActive = false
    private var foregroundModelTasks = 0

    private init() {
        let value = UserDefaults.standard.bool(forKey: "aie.scan.userPaused")
        paused = value
        storedPaused = value
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedPaused
    }

    var isInteractiveWorkActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foregroundModelTasks > 0 || Date().timeIntervalSinceReferenceDate < interactiveUntil
    }

    func beginForegroundModelWork() {
        lock.lock(); foregroundModelTasks += 1; lock.unlock()
        noteInteractiveWork()
    }

    func endForegroundModelWork() {
        lock.lock(); foregroundModelTasks = max(0, foregroundModelTasks - 1); lock.unlock()
    }

    var interactiveRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedInteractiveRevision
    }

    var isHeavyModelActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return heavyModelActive
    }

    func setHeavyModelActive(_ value: Bool) {
        lock.lock(); heavyModelActive = value; lock.unlock()
    }

    /// Give typing and retrieval a short exclusive window. Background scanners call
    /// `waitForInteractiveWorkToSettle` between files, so an in-flight file remains atomic.
    func noteInteractiveWork(settleAfter seconds: TimeInterval = 1.2) {
        lock.lock()
        interactiveUntil = max(interactiveUntil, Date().timeIntervalSinceReferenceDate + seconds)
        storedInteractiveRevision &+= 1
        lock.unlock()
        // A new query must also cancel an older foreground 8B plan. Otherwise Ollama keeps
        // finishing the stale request and, with one inference lane, blocks the new query's
        // lightweight embedding request for several seconds.
        if LocalQuickScan.isInstalled {
            Task { await LocalQuickScan.shared.interruptForInteractiveWork() }
        }
        Task { await LocalSemanticIndex.shared.interruptForInteractiveWork() }
    }

    /// Called only from scanner utility queues. Returns false when the user paused scanning.
    func waitForInteractiveWorkToSettle() -> Bool {
        while true {
            lock.lock()
            let paused = storedPaused
            let delay = interactiveUntil - Date().timeIntervalSinceReferenceDate
            let foreground = foregroundModelTasks > 0
            lock.unlock()
            if paused { return false }
            if !foreground, delay <= 0, BackgroundResourcePolicy.allowsBackgroundModelWork { return true }
            if BackgroundResourcePolicy.pauseReason != nil {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            Thread.sleep(forTimeInterval: foreground ? 0.1 : max(0.01, min(delay, 0.1)))
        }
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        storedPaused = value
        lock.unlock()
        UserDefaults.standard.set(value, forKey: "aie.scan.userPaused")
        if Thread.isMainThread {
            paused = value
        } else {
            DispatchQueue.main.async { self.paused = value }
        }
    }
}
