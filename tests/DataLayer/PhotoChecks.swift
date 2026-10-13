import Foundation
import AIEData

func photoChecks(_ directory: URL) throws {
    let db = try ContentStore(path: directory.appendingPathComponent("photos.sqlite").path)
    let root = directory.appendingPathComponent("photos").path
    func asset(_ id: String, revision: String = "1", date: Double = 1) -> PhotoAssetSnapshot {
        PhotoAssetSnapshot(id: id, path: root + "/" + id + ".jpg", name: id, kind: "image", revision: revision,
                           capturedAt: Date(timeIntervalSince1970: date), modifiedAt: Date(timeIntervalSince1970: date), duration: 0)
    }
    let old = asset("old"), recent = asset("recent", date: 2)
    try check(try db.synchronizePhotoAssets([old, recent], rootPath: root) == ["recent", "old"], "Photos queue ignored capture order")
    try check(try db.updatePhotoAsset(id: "old", revision: "1", localStatus: "ready"), "Photo checkpoint failed")
    try db.updatePhotoAsset(id: "recent", revision: "1", localStatus: "failed", error: "offline", retryAt: Date().addingTimeInterval(3600))
    try check(try db.synchronizePhotoAssets([old, recent], rootPath: root).isEmpty, "Retry backoff ignored or completed asset rescanned")
    try check(try db.nextPhotoRetry(rootPath: root) != nil, "Failed photo has no retry wakeup")
    try check(try db.photoQueueProgress(rootPath: root).ready == 1 && db.photoQueueProgress(rootPath: root).failed == 1, "Failed photos counted as synchronized")
    try db.retryPhotoAssets(rootPath: root)
    try check(try db.synchronizePhotoAssets([old, recent], rootPath: root) == ["recent"], "Manual retry failed")
    let edited = asset("old", revision: "2")
    try check(try db.synchronizePhotoAssets([edited], rootPath: root) == ["old"], "Edited photo was not invalidated")
    try check(try !db.updatePhotoAsset(id: "old", revision: "1", localStatus: "ready"), "Old download overwrote new photo revision")
    try check(try !db.updatePhotoAsset(id: "recent", revision: "1", localStatus: "ready"), "Deleted photo revived by late callback")
    try check(try db.excludedPhotoPaths(rootPath: root) == Set([old.path, recent.path]), "Stale or deleted photo still searchable")
    try expectFailure("Duplicate photo IDs corrupted snapshot") { _ = try db.synchronizePhotoAssets([edited, edited], rootPath: root) }
    try expectFailure("Photo path escaped root") { _ = try db.synchronizePhotoAssets([edited], rootPath: root + "/nested") }
    try check(try db.photoQueueProgress(rootPath: root).total == 1, "Rejected snapshot changed queue")
    try db.updatePhotoAsset(id: "old", revision: "2", localStatus: "downloading")
    let reopened = try ContentStore(path: directory.appendingPathComponent("photos.sqlite").path)
    try check(try reopened.synchronizePhotoAssets([edited], rootPath: root) == ["old"], "Interrupted photo download did not resume on restart")
    print("Photo checks passed: recent-first queue, checkpoints, retry backoff, restart, revisions, deletion and rejected snapshots.")
}
