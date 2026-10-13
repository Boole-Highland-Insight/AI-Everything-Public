import Foundation
import AIEData

func crashWorkerIfRequested() throws {
    let args = CommandLine.arguments
    guard args.count == 5, args[1] == "--crash-worker" else { return }
    let db = try ContentStore(path: args[2])
    let root = "/isolated-crash-fixture"
    let old = SourceDocument(id: "old", rootPath: root, path: root + "/old.txt", relativePath: "old.txt",
        kind: "document", ext: "txt", contentHash: "old-hash", size: 1, modifiedAt: 1,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "中断前的资料仍可搜索")])
    let fresh = SourceDocument(id: "new", rootPath: root, path: root + "/new.txt", relativePath: "new.txt",
        kind: "document", ext: "txt", contentHash: "new-hash", size: 1, modifiedAt: 2,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "恢复后完成的新资料")])
    if args[4] == "write" {
        try db.synchronize(documents: [old], rootPaths: [root])
        let job = try db.claimJob(subjectID: old.versionID, jobType: "deep", inputHash: old.contentHash,
            priority: 1, owner: "killed-worker", leaseDuration: 600,
            checkpointJSON: #"{"segment":2}"#, now: 100)
        try check(job != nil, "Failed to claim crash fixture job")
        try db.stage(documents: [fresh], rootPaths: [root])
        try Data("ready".utf8).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        while true { Thread.sleep(forTimeInterval: 1) }
    }
    try check(try db.search(allTerms: [["中断前"]], rootPaths: [root]).count == 1,
              "SIGKILL lost the previously published searchable snapshot")
    try check(try db.recoverInterruptedJobs(now: 101) == 1, "Running job was not recovered")
    let resumed = try db.claimJob(subjectID: old.versionID, jobType: "deep", inputHash: old.contentHash,
        priority: 1, owner: "restarted-worker", now: 101)
    try check(resumed?.checkpointJSON == #"{"segment":2}"# && resumed?.attemptCount == 2,
              "Restart lost checkpoint or attempt history")
    try check(try db.completeJob(id: resumed!.id, owner: "restarted-worker", now: 102), "Resume failed")
    try db.stage(documents: [fresh], rootPaths: [root])
    try db.publishSnapshot(documentIDs: [fresh.id], rootPaths: [root])
    try check(try db.search(allTerms: [["恢复后"]], rootPaths: [root]).count == 1,
              "Resuming the staged batch duplicated or lost searchable content")
    try check(try db.search(allTerms: [["中断前"]], rootPaths: [root]).isEmpty, "Old snapshot was not retired")
    print("SIGKILL recovery passed: previous snapshot, durable checkpoint, re-claim, replay and publish.")
    exit(0)
}
