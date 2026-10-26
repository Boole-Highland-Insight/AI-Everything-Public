import Foundation
import Combine
import AIEData

/// Presentation only: combines persisted current-version work with the current catalog pass.
struct IndexingStageCount {
    var ready = 0
    var pending = 0
    var failed = 0
    var skipped = 0
    var deferred = 0
    var running = false
    var total: Int { ready + pending + failed }
    var settled: Bool { pending == 0 && failed == 0 && deferred == 0 && !running }
    var fraction: Double { total > 0 ? (settled && ready == total ? 1 : min(0.99, Double(ready) / Double(total))) : 0 }
    var summary: String {
        "完成 \(ready) · 待处理 \(pending) · 失败 \(failed) · 不适用 \(skipped)"
            + (deferred > 0 ? " · 暂缓 \(deferred)" : "")
    }
    func status(upstreamPending: Bool, paused: Bool, loaded: Bool) -> String {
        guard loaded else { return "统计中" }
        if failed > 0 { return "有失败项" }
        if running { return "处理中" }
        if paused { return "已暂停" }
        if pending > 0 { return "待处理" }
        if upstreamPending { return "等待新内容" }
        if deferred > 0 { return "有暂缓项" }
        return total == 0 ? "无需处理" : "完成"
    }
}

@MainActor final class IndexingProgressDisplay: ObservableObject {
    @Published var snapshot: IndexingDisplaySnapshot?
    @Published var semanticSnapshot: SemanticDisplaySnapshot?
    @Published var requestID = ""
    @Published var failed = false
    private var fileRevision = 0

    func matches(_ id: String) -> Bool { snapshot != nil && requestID == id }
    func semanticMatches(_ id: String) -> Bool {
        requestID == id && (semanticSnapshot != nil || snapshot?.semanticReady != nil)
    }

    func observe(roots: [String], id: String) async {
        if requestID != id {
            requestID = id; snapshot = nil; semanticSnapshot = nil; failed = false; fileRevision += 1
        }
        async let files: Void = observeFiles(roots: roots, id: id)
        async let semantics: Void = observeSemantics(roots: roots, id: id)
        _ = await (files, semantics)
    }

    private func observeFiles(roots: [String], id: String) async {
        while !Task.isCancelled {
            let result = await Task.detached(priority: .utility) {
                Result { try AppDatabase.open().indexingFileSnapshot(rootPaths: roots) }
            }.value
            guard !Task.isCancelled, requestID == id else { return }
            switch result {
            case .success(let value):
                if snapshot?.files.map(\.path) != value.files.map(\.path) {
                    fileRevision += 1
                    semanticSnapshot = nil
                }
                snapshot = value; failed = false
            case .failure: failed = true
            }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }

    private func observeSemantics(roots: [String], id: String) async {
        while !Task.isCancelled {
            let revision = fileRevision
            let result = await Task.detached(priority: .utility) {
                Result { try AppDatabase.open().indexingSemanticSnapshot(rootPaths: roots) }
            }.value
            guard !Task.isCancelled, requestID == id else { return }
            if case .success(let value) = result, revision == fileRevision { semanticSnapshot = value }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        }
    }

    func count(_ stage: String, discovered: Int) -> IndexingStageCount {
        guard let snapshot else { return IndexingStageCount(pending: discovered) }
        var count = IndexingStageCount(pending: max(0, discovered - snapshot.files.count),
                                       running: snapshot.runningStages.contains(stage))
        for file in snapshot.files {
            let state = file.stages[stage]?.status ?? "pending"
            if stage != "index", file.deferred { count.deferred += 1 }
            else if state == "unsupported" { count.skipped += 1 }
            else if ["ready", "usable", "available"].contains(state) { count.ready += 1 }
            else if ["failed", "empty", "limited", "needs_review"].contains(state) { count.failed += 1 }
            else { count.pending += 1 }
        }
        return count
    }

    var semanticCount: IndexingStageCount {
        let ready = semanticSnapshot?.ready ?? snapshot?.semanticReady ?? 0
        let total = semanticSnapshot?.total ?? snapshot?.semanticTotal ?? 0
        let failed = min(semanticSnapshot?.failed ?? snapshot?.semanticFailed ?? 0, max(0, total - ready))
        return IndexingStageCount(ready: ready, pending: max(0, total - ready - failed), failed: failed)
    }
}
