import Foundation
import AIEData

func understandingChecks(_ directory: URL) throws {
    let root = directory.appendingPathComponent("understanding").path
    let db = try ContentStore(path: directory.appendingPathComponent("understanding.sqlite").path)
    var image = SourceDocument(
        id: "image-a", rootPath: root, path: root + "/白板.png", relativePath: "白板.png",
        kind: "image", ext: "png", contentHash: "same-image", size: 10, modifiedAt: 1000,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "白板.png")]
    )
    let record: [String: Any] = [
        "size": 10, "mtime": 1000, "scannedAt": "2026-09-16T12:00:00.000Z",
        "localScan": [
            "sourceHash": "same-image",
            "vision": [
                "ocr": ["项目代号 884209"],
                "tags": [["id": "document", "confidence": 0.92, "zh": ["文档"]]],
                "animals": [], "peopleCount": 0, "barcodes": [],
                "canvas": [
                    "inkRatio": 0.2, "paperRatio": 0.8, "chroma": 0.1, "edgeRatio": 0.3,
                    "mostlyBlank": false, "sparse": false, "sketchy": true, "layout": "portrait",
                ],
            ],
        ],
        "deepScan": [
            "blurb_zh": "一张未完成的项目架构白板",
            "keywords_zh": ["架构"], "topics_zh": ["项目规划"],
            "entities_zh": ["北极星团队"], "evidence_zh": ["画面中有连接线"],
            "content_type_zh": "白板", "completion_state": "unfinished",
            "scene_zh": "会议室", "objects_zh": ["白板"], "actions_zh": ["绘制"],
            "visible_text_zh": ["项目代号 884209"],
            "parse": [
                "sourceHash": "same-image", "model": "qwen3-vl:8b-instruct-q4_K_M",
                "modelDigest": "fixture-digest", "parserVersion": "deep-scan-1",
                "parsedAt": "2026-09-16T12:01:00.000Z",
            ],
        ],
    ]
    image = SidecarProjection.apply(record, to: image)
    var duplicate = image
    duplicate.id = "image-b"
    duplicate.path = root + "/白板副本.png"
    duplicate.relativePath = "白板副本.png"
    try db.synchronize(documents: [image, duplicate], rootPaths: [root])

    let stats = try db.understandingStatistics()
    try check(stats.observations >= 10, "Deep/system observations were not persisted")
    try check(stats.modelRuns >= 2 && stats.jobs >= 4, "Processor runs or durable jobs were not projected")
    try check(stats.features == 2, "Version hash features were not persisted")
    try check(stats.relations == 1, "Exact duplicate relation was not created")
    try check(stats.unitContents < stats.contentUnits, "Model/system observations leaked into factual unit contents")
    try check(try db.search(allTerms: [["北极星团队"]], rootPaths: [root]).isEmpty &&
              db.entityNames(rootPaths: [root])[image.path]?.contains("北极星团队") == true,
              "Historical entity must remain stored but stay outside V1 FTS")
    try check(try db.search(allTerms: [["884209"]], rootPaths: [root]).count == 2,
              "OCR facts did not reach the search projection")

    var audio = SourceDocument(
        id: "audio", rootPath: root, path: root + "/录音.m4a", relativePath: "录音.m4a",
        kind: "audio", ext: "m4a", contentHash: "audio-hash", size: 10, modifiedAt: 1000,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "录音.m4a")]
    )
    let longTranscript = String(repeating: "普通填充内容", count: 45) + "海王星验收口令"
    audio = SidecarProjection.apply([
        "size": 10, "mtime": 1000,
        "localScan": [
            "sourceHash": "audio-hash",
            "mediaTranscript": [
                "sourceHash": "audio-hash", "status": "ready", "parserVersion": "media-transcript-1",
                "segments": [[
                    "index": 0, "startSeconds": 0.0, "endSeconds": 45.0,
                    "status": "ready", "text": longTranscript,
                ]],
            ],
        ],
    ], to: audio)
    try db.synchronize(documents: [image, duplicate, audio], rootPaths: [root])
    try check(try db.search(allTerms: [["海王星验收口令"]], rootPaths: [root]).first?.fileID == audio.id,
              "Transcript tail was searchable only through its short summary")

    let firstClaim = try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-a", leaseDuration: 10,
        checkpointJSON: #"{"phase":"prepare"}"#, now: 100
    )
    try check(firstClaim?.state == "running" && firstClaim?.attemptCount == 1,
              "Pending job was not claimed atomically")
    try check(try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-b", leaseDuration: 10, now: 105
    ) == nil, "Active lease allowed a second worker")
    try check(try db.renewJobLease(
        id: firstClaim!.id, owner: "worker-a", leaseDuration: 5,
        checkpointJSON: #"{"segment":2}"#, now: 108
    ), "Lease renewal or checkpoint write failed")
    try check(try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-b", leaseDuration: 10, now: 112
    ) == nil, "Renewed lease expired too early")
    let recovered = try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-b", leaseDuration: 10, now: 114
    )
    try check(recovered?.attemptCount == 2 && recovered?.checkpointJSON == #"{"segment":2}"#,
              "Expired job did not resume from its durable checkpoint")
    try check(try db.retryJob(
        id: recovered!.id, owner: "worker-b", errorCode: "temporary",
        retryDelay: 10, checkpointJSON: #"{"segment":3}"#, now: 115
    ), "Retry transition failed")
    try check(try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-a", now: 124
    ) == nil, "Retry ran before not_before")
    let retry = try db.claimJob(
        subjectID: audio.versionID, jobType: "deep", inputHash: audio.contentHash,
        priority: 50, owner: "worker-a", now: 125
    )
    try check(retry?.attemptCount == 3, "Eligible retry was not claimed")
    try check(try db.completeJob(id: retry!.id, owner: "worker-a", now: 126),
              "Successful job did not complete")
    let completed = try db.durableJob(id: retry!.id)
    try check(completed?.state == "succeeded" && completed?.leaseOwner == nil
              && completed?.checkpointJSON == #"{"segment":3}"#,
              "Completion lost state or checkpoint")
    let interrupted = try db.claimJob(
        subjectType: "content_unit", subjectID: "fixture-unit", jobType: "fixture-recovery",
        inputHash: "fixture-hash", priority: 1, owner: "dead-process", now: 200
    )
    let recoveredCount = try db.recoverInterruptedJobs(now: 201)
    try check(interrupted != nil && recoveredCount == 1,
              "Startup recovery did not release an interrupted claim")
    try check(try db.claimJob(
        subjectType: "content_unit", subjectID: "fixture-unit", jobType: "fixture-recovery",
        inputHash: "fixture-hash", priority: 1, owner: "new-process", now: 201
    )?.leaseOwner == "new-process", "Recovered job was not immediately claimable")

    try db.restrictRoots(to: [])
    try check(try db.sourceAuthorization(rootPath: root) == "revoked",
              "Source authorization lifecycle was not projected")
    print("Understanding checks passed: facts, observations, runs, durable claims/leases/retries/checkpoints, features, relations and lifecycle.")
}
