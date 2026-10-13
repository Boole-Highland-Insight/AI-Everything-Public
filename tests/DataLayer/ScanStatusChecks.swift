import Foundation
import AIEData

func scanStatusChecks(in temporary: URL) throws {
    let path = temporary.appendingPathComponent("scan-status.sqlite").path
    let store = try ContentStore(path: path)
    let root = temporary.appendingPathComponent("scan-status-library").path
    let other = temporary.appendingPathComponent("scan-status-other").path
    func document(_ id: String, hash: String = "v1", rootPath: String? = nil,
                  status: String = "ready") -> SourceDocument {
        let directory = rootPath ?? root
        var doc = SourceDocument(id: id, rootPath: directory, path: directory + "/" + id + ".txt",
            relativePath: id + ".txt", kind: "document", ext: "txt", contentHash: hash,
            size: 100, modifiedAt: 1,
            blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: id)])
        doc.stages = [ScanStage("index", status: "ready"), ScanStage("local", status: status),
                      ScanStage("deep", status: status, error: status == "failed" ? "test failure" : nil)]
        return doc
    }
    let original = document("changed")
    let removed = document("removed")
    let unrelated = document("other", rootPath: other)
    try store.synchronize(documents: [original, removed, unrelated], rootPaths: [root, other])
    let current = document("changed", hash: "v2", status: "pending")
    let failed = document("failed", status: "failed")
    let unsupported = document("unsupported", status: "unsupported")
    let deferred = document("deferred", status: "pending")
    try store.synchronize(documents: [current, failed, unsupported, deferred, unrelated], rootPaths: [root, other])
    try store.setPreference(path: deferred.path, name: "deferred", value: true)
    // Model/protocol retries create extra job rows. They must not create extra visible files.
    _ = try store.claimJob(subjectID: current.versionID, jobType: "deep", inputHash: "model-a", priority: 50, owner: "a")
    _ = try store.claimJob(subjectID: current.versionID, jobType: "deep", inputHash: "model-b", priority: 50, owner: "b")
    let status = try store.scanStatus(rootPaths: [root])
    try check(status.count == 4, "Scan status counted historical, missing or unselected files")
    try check(status.first { $0.path == current.path }?.stages["deep"]?.status == "pending",
              "A previous version's completed scan leaked into current progress")
    try check(status.first { $0.path == failed.path }?.stages["deep"]?.error == "test failure",
              "Scan failure reason was not restored")
    try check(status.first { $0.path == unsupported.path }?.stages["deep"]?.status == "unsupported",
              "Unsupported files were counted as pending")
    try check(status.first { $0.path == deferred.path }?.deferred == true, "User deferral was lost")
    let reopened = try ContentStore(path: path)
    try check(try reopened.scanStatus(rootPaths: [root]).count == 4, "Scan status was not durable across reopen")
    try check(try store.scanStatus(rootPaths: []).isEmpty, "An empty selection exposed all roots")
    try store.restrictRoots(to: [other])
    try check(try store.scanStatus(rootPaths: [root]).isEmpty, "Deselected root remained in scan status")

    var timing = ScanTimingEstimate()
    try check(timing.remainingSeconds(work: ["local:pdf": 10]) == nil, "ETA invented a speed without samples")
    timing.record(key: "local:pdf", seconds: 12)
    timing.record(key: "local:pdf", seconds: 18)
    try check(timing.remainingSeconds(work: ["local:pdf": 10]) == nil, "ETA trusted too few samples")
    timing.record(key: "local:pdf", seconds: 15)
    try check(timing.remainingSeconds(work: ["local:pdf": 10]) == 150, "ETA did not use measured processing time")
    timing.record(key: "local:pdf", units: 0, seconds: 10000)
    timing.record(key: "local:pdf", seconds: .infinity)
    try check(timing.remainingSeconds(work: ["local:pdf": 10]) == 150, "Invalid samples corrupted ETA")
    try check(timing.remainingSeconds(work: ["local:pdf": 10, "deep:pdf": 1]) == nil,
              "ETA reused a speed from another model or stage")
    let restored = try JSONDecoder().decode(ScanTimingEstimate.self, from: JSONEncoder().encode(timing))
    try check(restored.remainingSeconds(work: ["local:pdf": 10]) == 150, "Measured speed did not survive restart")
    try check(restored.remainingSeconds(work: [:]) == 0, "An empty queue retained an ETA")
}
