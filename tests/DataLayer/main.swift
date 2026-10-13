import Foundation
import AIEData

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "DataChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func expectFailure(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "DataChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}
try concurrencyWorkerIfRequested()
try crashWorkerIfRequested()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aie-data-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
try scanStatusChecks(in: temporary)
let root = temporary.appendingPathComponent("library").path
let otherRoot = temporary.appendingPathComponent("other").path
let databasePath = temporary.appendingPathComponent("db/content.sqlite").path
let db = try ContentStore(path: databasePath)
var source = SourceDocument(id: "file-1", rootPath: root, path: root + "/流程.pptx", relativePath: "流程.pptx", kind: "document", ext: "pptx",
                            contentHash: "sha-v1", size: 100, modifiedAt: 1000,
                            blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "流程.pptx")])
let sidecar: [String: Any] = [
    "size": 100, "mtime": 1000,
    "localScan": ["sourceHash": "sha-v1", "presentation": ["parserVersion": "1", "coverage": "all_slide_text_and_shapes", "slides": [
        ["page": 1, "text": "封面研究报告", "tags": [], "member": "ppt/slides/slide1.xml"],
        ["page": 3, "text": "这里展示项目审批流程图与量子协同验收", "tags": ["流程图"], "member": "ppt/slides/slide3.xml"]]]],
    "quickScan": ["blurb_zh": "只介绍封面的旧摘要", "keywords_zh": ["研究"], "parse": ["sourceHash": "sha-v1", "model": "test-model", "parserVersion": "2"]],
    "scannedAt": "2026-09-08T01:00:00Z",
]
source = SidecarProjection.apply(sidecar, to: source)
try check(source.blocks.count == 3 && source.blocks[2].page == 3, "Sidecar pages not imported")
try check(source.blocks[2].summary != source.fileSummary, "File summary copied over chunk content")
try db.synchronize(documents: [source], rootPaths: [root])
let stats = try db.statistics()
let projection = try db.projectionCounts()
try check(projection.sources == 1 && projection.items == 1 && projection.contentUnits == stats.chunks &&
          projection.unitContents == stats.chunks && projection.searchDocuments == stats.chunks,
          "Content unit/search projection was not populated")
let cascadeIndexes = try sqlite(databasePath, """
    SELECT count(*) FROM sqlite_master
    WHERE type='index' AND name IN (
        'chunks_parent','content_units_parent','relations_to_subject'
    );
    """).trimmingCharacters(in: .whitespacesAndNewlines)
try check(cascadeIndexes == "3", "Cascade lookup indexes are missing")
try db.synchronize(documents: [source], rootPaths: [root])
try check(try db.statistics().chunks == stats.chunks && db.statistics().versions == 1, "Import is not idempotent")

// An interrupted batched refresh keeps the last complete snapshot searchable. Committed batches
// are safe to reuse when the same enumeration resumes.
let interruptionPath = temporary.appendingPathComponent("interruption.sqlite").path
let interruptionDB = try ContentStore(path: interruptionPath)
let oldSnapshot = SourceDocument(
    id: "old-snapshot", rootPath: root, path: root + "/old.txt", relativePath: "old.txt",
    kind: "document", ext: "txt", contentHash: "old-v1", size: 1, modifiedAt: 1,
    blocks: [
        ContentBlock(key: "document", parentKey: nil, kind: "document", text: "中断前仍然可搜索"),
        ContentBlock(key: "page-1", kind: "page", page: 1, text: "父块", parserVersion: "pdfkit-1"),
        ContentBlock(key: "line-1", parentKey: "page-1", kind: "text", page: 1,
                     text: "嵌套子块", parserVersion: "pdfkit-1"),
    ]
)
try interruptionDB.synchronize(documents: [oldSnapshot], rootPaths: [root])
try check(
    try interruptionDB.cachedSourceBlocks(
        versionID: oldSnapshot.versionID, parserVersion: "pdfkit-1"
    )?.count == 2,
    "Cached nested source blocks were duplicated"
)
let replacementSnapshot = (0..<40).map { index in
    SourceDocument(
        id: "replacement-\(index)", rootPath: root,
        path: root + "/replacement-\(index).txt", relativePath: "replacement-\(index).txt",
        kind: "document", ext: "txt", contentHash: "replacement-v1-\(index)",
        size: 1, modifiedAt: 2,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "替换快照 \(index)")]
    )
}
try interruptionDB.stage(documents: Array(replacementSnapshot.prefix(32)), rootPaths: [root])
try check(
    try interruptionDB.search(allTerms: [["中断前"]], rootPaths: [root]).count == 1,
    "Interrupted synchronization cleared the last complete snapshot"
)
try interruptionDB.stage(documents: Array(replacementSnapshot.dropFirst(32)), rootPaths: [root])
try interruptionDB.publishSnapshot(
    documentIDs: replacementSnapshot.map(\.id), rootPaths: [root]
)
try check(
    try interruptionDB.search(allTerms: [["中断前"]], rootPaths: [root]).isEmpty,
    "Completed synchronization did not retire the old snapshot"
)
let ftsIdentityMismatch = try sqlite(databasePath, """
    SELECT count(*) FROM search_documents sd
    LEFT JOIN search_documents_fts f ON f.rowid=sd.fts_rowid
    WHERE sd.fts_rowid IS NULL OR f.search_document_id<>sd.id OR f.search_document_id IS NULL;
    """).trimmingCharacters(in: .whitespacesAndNewlines)
try check(ftsIdentityMismatch == "0", "Search FTS row identities are incomplete")
try check(try db.cachedSourceBlocks(versionID: source.versionID, parserVersion: "pptx-1")?.count == 2,
          "Unchanged source blocks were not reusable")
let flowHits = try db.search(allTerms: [["流程图"]], rootPaths: [root])
try check(flowHits.count == 1 && flowHits[0].page == 3, "Chinese FTS did not locate slide 3")
try check(try db.search(allTerms: [["流程.pptx"]], rootPaths: [root]).first?.page == nil, "Filename projection search failed")
let id = flowHits[0].id
try check(try db.search(allTerms: [["量子"]], rootPaths: [root]).first?.id == id, "Chinese substring recall failed")
try check(try db.search(allTerms: [["\" OR *"]], rootPaths: [root]).isEmpty, "FTS query syntax injection")
try check(try db.chunk(id: id, rootPaths: [otherRoot]) == nil, "Chunk lookup escaped authorized roots")
try check(try db.search(allTerms: [["流程图"]], rootPaths: []).isEmpty, "Empty authorization returned content")
try db.putEmbedding(chunkID: id, spaceID: "model-v1", modelID: "model", modelVersion: "v1", vector: [1,0], rootPaths: [root])
try check(try db.searchVector([1,0], spaceID: "model-v1", rootPaths: [root]).first?.id == id, "Vector retrieval failed")
try expectFailure("Embedding dimension mismatch accepted") { try db.putEmbedding(chunkID: id, spaceID: "model-v1", modelID: "model", modelVersion: "v1", vector: [1,0,0], rootPaths: [root]) }
try expectFailure("Model spaces mixed") { try db.putEmbedding(chunkID: id, spaceID: "model-v1", modelID: "other-model", modelVersion: "v1", vector: [1,0], rootPaths: [root]) }
try db.synchronize(documents: [source], rootPaths: [root])
try check(try db.statistics().embeddings == 1, "Unchanged import discarded embeddings")
var artifact = source
artifact.id = "file-2"; artifact.path = root + "/产物.pptx"; artifact.relativePath = "产物.pptx"
try db.synchronize(documents: [source, artifact], rootPaths: [root])
try db.linkArtifact(sourceVersionID: source.versionID, artifactFileID: artifact.id, relation: "reuse", rootPaths: [root])
let oldVersion = source.versionID
source.contentHash = "sha-v2"; source.size = 101; source.modifiedAt = 1001
source.blocks = [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "流程.pptx"), ContentBlock(key: "page-1", kind: "slide", page: 1, text: "全新机器学习方案")]
source.fileSummary = "新版本"
try db.synchronize(documents: [source], rootPaths: [root])
try check(try db.search(allTerms: [["流程图"]], rootPaths: [root]).isEmpty, "Deleted/old-version chunks remained searchable")
try check(try db.chunk(id: id, rootPaths: [root]) == nil, "Stale chunk remained openable")
try check(try db.searchVector([1,0], spaceID: "model-v1", rootPaths: [root]).isEmpty, "Old vector remained searchable")
try check(try db.statistics().versions == 3, "Version history lost")
let projected = SidecarProjection.apply(sidecar, to: SourceDocument(id: source.id, rootPath: root, path: source.path, relativePath: source.relativePath,
    kind: source.kind, ext: source.ext, contentHash: "sha-v2", size: 101, modifiedAt: 1001,
    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "name")]))
try check(projected.fileSummary.isEmpty && projected.blocks.count == 1, "Stale sidecar contaminated new source version")
source.path = root + "/重命名.pptx"; source.relativePath = "重命名.pptx"
try db.synchronize(documents: [source, artifact], rootPaths: [root])
try check(try db.statistics().versions == 3, "Rename created an extra content version")
try db.linkArtifact(sourceVersionID: oldVersion, artifactFileID: artifact.id, relation: "reuse", rootPaths: [root])
var cycle = source
cycle.blocks = [ContentBlock(key: "document", parentKey: "child", kind: "document", text: "bad"), ContentBlock(key: "child", parentKey: "document", kind: "slide", text: "bad")]
try expectFailure("Cyclic hierarchy accepted") { try db.synchronize(documents: [cycle], rootPaths: [root]) }
try check(try db.search(allTerms: [["机器学习"]], rootPaths: [root]).first?.path == source.path, "Failed transaction damaged live index")
try db.restrictRoots(to: [])
try check(try db.search(allTerms: [["机器学习"]], rootPaths: [root]).isEmpty, "Root revocation waited for a file enumeration")
try db.synchronize(documents: [], rootPaths: [])
try check(try db.search(allTerms: [["流程图"]], rootPaths: [root]).isEmpty, "Revoked root leaked content")
try expectFailure("Artifact link crossed revoked roots") { try db.linkArtifact(sourceVersionID: oldVersion, artifactFileID: artifact.id, relation: "reuse", rootPaths: [root]) }
source.stages = [ScanStage("quick", status: "failed", error: "timeout", attemptedAt: "2026-09-08T02:00:00Z")]
try db.synchronize(documents: [source], rootPaths: [root])
try check(try db.statistics().failedStages == 1, "Failed scan not persisted")
let reopened = try ContentStore(path: databasePath)
try check(try reopened.search(allTerms: [["机器学习"]], rootPaths: [root]).count == 1, "Database cannot reopen")
let long = String(repeating: "段落", count: 4000) + "终点"
try check(SidecarProjection.textBlocks(long).map(\.text).joined() == long, "Chunking dropped text")
let started = Date()
for _ in 0..<100 { _ = try reopened.search(allTerms: [["机器学习"]], rootPaths: [root]) }
print("Data checks passed: legacy import, page evidence, Chinese FTS, authorization, version invalidation, embeddings, provenance, atomic rollback, reopen. 100 fixture queries: \(Int(Date().timeIntervalSince(started) * 1000)) ms")

// Independent media checkpoints remain searchable even when the video-frame analysis failed.
var audioSource = SourceDocument(id: "audio-file", rootPath: root, path: root + "/lecture.mp4", relativePath: "lecture.mp4", kind: "video", ext: "mp4",
    contentHash: "audio-v1", size: 100, modifiedAt: 1000, blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "lecture.mp4")])
let mediaRecord: [String: Any] = [
    "localScan": [
        "sourceHash": "audio-v1",
        "videoFrames": ["parserVersion": "video-samples-1", "frames": [[
            "index": 0, "startSeconds": 5.0, "endSeconds": 6.0,
            "vision": ["ocr": ["站台编号 A17"], "tags": []],
        ]]],
        "mediaTranscript": ["sourceHash": "audio-v1", "status": "partial", "parserVersion": "media-transcript-1", "segments": [
    ["index": 0, "startSeconds": 0.0, "endSeconds": 45.0, "status": "ready", "text": "专利申请流程"],
    ["index": 1, "startSeconds": 45.0, "endSeconds": 90.0, "status": "failed", "text": "不可检索失败文本"]
    ]],
    ],
    "deepScan": [
        "blurb_zh": "视频中出现一辆黄色汽车。",
        "keywords_zh": ["黄色汽车"],
        "parse": ["sourceHash": "audio-v1", "parserVersion": "video-deep-scan-2", "model": "fixture"],
        "videoSegments": [[
            "index": 0, "startSeconds": 5.0, "endSeconds": 6.0, "status": "ready",
            "blurb_zh": "画面中出现一辆黄色汽车。", "keywords_zh": ["黄色汽车"],
        ]],
    ],
]
audioSource = SidecarProjection.apply(mediaRecord, to: audioSource)
try db.synchronize(documents: [audioSource], rootPaths: [root])
let audioHits = try db.search(allTerms: [["专利申请"]], rootPaths: [root])
try check(audioHits.first?.startSeconds == 0 && audioHits.first?.endSeconds == 45, "Timestamp evidence was lost")
let frameOCRHits = try db.search(allTerms: [["站台"]], rootPaths: [root])
try check(frameOCRHits.contains { $0.kind == "frame_ocr" && $0.startSeconds == 5 },
          "Frame OCR lost its sampled time")
let frameModelHits = try db.search(allTerms: [["黄色汽车"]], rootPaths: [root])
try check(frameModelHits.contains { $0.kind == "video_segment_analysis" && $0.startSeconds == 5 },
          "Video segment description lost its sampled time")
try check(try db.search(allTerms: [["不可检索失败文本"]], rootPaths: [root]).isEmpty, "Failed transcript was indexed")
audioSource.contentHash = "audio-v2"
audioSource.blocks = [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "lecture.mp4")]
audioSource = SidecarProjection.apply(mediaRecord, to: audioSource)
try check(audioSource.blocks.count == 1, "Old audio checkpoint contaminated the new file version")
print("Media projection checks passed: timestamp evidence, partial success and stale transcript rejection.")

try analysisChecks(db, temporary: temporary)

try check(RankFusion.fuse([["a", "b"], ["b", "c"]]).first == "b", "RRF did not reward independent corroboration")
try check(RankFusion.fuse([["a", "a", "a", "b"], ["b"]]).first == "b", "Repeated chunks inflated a file's score")
try check(RankFusion.fuse([["a"], ["b"]], limit: 0).isEmpty, "RRF ignored limit")
let hybridDB = try ContentStore(path: temporary.appendingPathComponent("hybrid.sqlite").path)
var semanticDoc = SourceDocument(id: "semantic-file", rootPath: root, path: root + "/semantic.txt", relativePath: "semantic.txt",
    kind: "document", ext: "txt", contentHash: "original-bytes", size: 1, modifiedAt: 1,
    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "semantic.txt"), ContentBlock(key: "page", kind: "paragraph", text: "审批流程")])
semanticDoc.fileSummary = "旧摘要"
try hybridDB.synchronize(documents: [semanticDoc], rootPaths: [root])
let embeddingInputs = try hybridDB.missingEmbeddings(spaceID: "test-space", rootPaths: [root])
let rootInput = embeddingInputs.first { $0.kind == "document" }!
try hybridDB.putEmbedding(chunkID: rootInput.id, spaceID: "test-space", modelID: "fixture", modelVersion: "1", vector: [1,0], rootPaths: [root], expectedContentHash: rootInput.contentHash)
try check(try hybridDB.embeddingCoverage(spaceID: "test-space", rootPaths: [root]).ready == 1, "Embedding coverage incorrect")
try check(try hybridDB.understandingStatistics().features == 2,
          "Embedding was not mirrored into the feature store")
semanticDoc.fileSummary = "新的摘要包含不同语义"
try hybridDB.synchronize(documents: [semanticDoc], rootPaths: [root])
try check(try hybridDB.embeddingCoverage(spaceID: "test-space", rootPaths: [root]).ready == 0, "Summary edit did not invalidate embedding")
try check(try hybridDB.understandingStatistics().features == 1,
          "Stale embedding feature survived semantic input invalidation")
try expectFailure("Late inference overwrote changed semantic input") {
    try hybridDB.putEmbedding(chunkID: rootInput.id, spaceID: "test-space", modelID: "fixture", modelVersion: "1", vector: [1,0], rootPaths: [root], expectedContentHash: rootInput.contentHash)
}
semanticDoc.blocks.removeAll { $0.key == "page" }
try hybridDB.synchronize(documents: [semanticDoc], rootPaths: [root])
let prunedProjection = try hybridDB.projectionCounts()
try check(prunedProjection.contentUnits == 1 && prunedProjection.unitContents == 1 &&
          prunedProjection.searchDocuments == 1,
          "Removed chunks left orphaned content/search projection rows")
try check(try hybridDB.search(allTerms: [["审批流程"]], rootPaths: [root]).isEmpty,
          "Removed chunk remained searchable through an orphaned projection")
print("Hybrid checks passed: RRF, per-file deduplication, embedding coverage, semantic input invalidation and stale inference rejection.")

let streamDB = try ContentStore(path: temporary.appendingPathComponent("stream-vectors.sqlite").path)
let streamDoc = SourceDocument(
    id: "stream-file", rootPath: root, path: root + "/stream.txt",
    relativePath: "stream.txt", kind: "document", ext: "txt",
    contentHash: "stream-v1", size: 1, modifiedAt: 1,
    blocks: [
        ContentBlock(key: "document", parentKey: nil, kind: "document", text: "stream.txt"),
        ContentBlock(key: "alpha", kind: "paragraph", text: "alpha"),
        ContentBlock(key: "beta", kind: "paragraph", text: "beta"),
        ContentBlock(key: "gamma", kind: "paragraph", text: "gamma"),
    ]
)
try streamDB.synchronize(documents: [streamDoc], rootPaths: [root])
for chunk in try streamDB.missingEmbeddings(spaceID: "stream-space", rootPaths: [root]) {
    let vector: [Float]
    switch chunk.text {
    case "stream.txt": vector = [1, 0]
    case "alpha": vector = [0.9, 0.1]
    case "beta": vector = [0, 1]
    default: vector = [-1, 0]
    }
    try streamDB.putEmbedding(
        chunkID: chunk.id, spaceID: "stream-space", modelID: "fixture",
        modelVersion: "1", vector: vector, rootPaths: [root]
    )
}
let streamed = try streamDB.searchVector(
    [1, 0], spaceID: "stream-space", rootPaths: [root], limit: 2
)
try check(streamed.map(\.text) == ["stream.txt", "alpha"],
          "Bounded vector Top K changed exact ranking")
let capacity = try streamDB.indexCapacity(softLimitBytes: 1)
try check(capacity.reachedSoftLimit && capacity.semanticVectorBytes == 64,
          "Index capacity did not count versioned Float16 vectors")
let vectorBenchmark = try streamDB.benchmarkVectorIndex(rootPaths: [root], queryCount: 3, topK: 2)
try check(vectorBenchmark.backend == "sqlite-exact-cosine-v1" && vectorBenchmark.candidateCount == 4 &&
          vectorBenchmark.queryCount == 3 && vectorBenchmark.dimensions == 2 &&
          vectorBenchmark.p50Milliseconds >= 0 && vectorBenchmark.p95Milliseconds >= vectorBenchmark.p50Milliseconds,
          "Exact vector benchmark did not measure the production search path")
print("Streaming vector checks passed: exact Top K and bounded index capacity accounting.")

let budgetDB = try ContentStore(path: temporary.appendingPathComponent("semantic-budget.sqlite").path)
let budgetDocuments = [
    SourceDocument(id: "budget-image", rootPath: root, path: root + "/lake.jpg", relativePath: "lake.jpg",
                   kind: "image", ext: "jpg", contentHash: "image-v1", size: 1, modifiedAt: 4,
                   blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "湖边照片")]),
    SourceDocument(id: "budget-slides", rootPath: root, path: root + "/deck.pptx", relativePath: "deck.pptx",
                   kind: "document", ext: "pptx", contentHash: "slides-v1", size: 1, modifiedAt: 3,
                   blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "演示文稿")]),
    SourceDocument(id: "budget-text", rootPath: root, path: root + "/notes.txt", relativePath: "notes.txt",
                   kind: "document", ext: "txt", contentHash: "text-v1", size: 1, modifiedAt: 2,
                   blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "文字笔记")]),
    SourceDocument(id: "budget-media", rootPath: root, path: root + "/meeting.m4a", relativePath: "meeting.m4a",
                   kind: "audio", ext: "m4a", contentHash: "media-v1", size: 1, modifiedAt: 1,
                   blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "会议录音")]),
]
try budgetDB.synchronize(documents: budgetDocuments, rootPaths: [root])
let emptyBudget = try budgetDB.indexCapacity(spaceID: "budget-space", softLimitBytes: 1)
try check(!emptyBudget.reachedSoftLimit && emptyBudget.usedBytes > emptyBudget.softLimitBytes,
          "Non-vector SQLite pages incorrectly stopped semantic indexing")
let fairBatch = try budgetDB.missingEmbeddings(spaceID: "budget-space", rootPaths: [root], limit: 4)
try check(Set(fairBatch.map(\.fileID)) == Set(budgetDocuments.map(\.id)),
          "Content-class budget did not give the first semantic batch fair coverage")
let imageChunk = fairBatch.first { $0.fileID == "budget-image" }!
try budgetDB.putEmbedding(chunkID: imageChunk.id, spaceID: "budget-space", modelID: "fixture",
                          modelVersion: "1", vector: [1, 0], rootPaths: [root])
let budgetCapacity = try budgetDB.indexCapacity(spaceID: "budget-space", softLimitBytes: 100)
try check(budgetCapacity.semanticUsage.first(where: { $0.contentClass == .image })?.bytes == 16 &&
          budgetCapacity.semanticUsage.reduce(Int64.zero, { $0 + $1.targetBytes }) == 100,
          "Per-content semantic usage accounting is incorrect")
print("Semantic budget checks passed: vector-only limit, per-class accounting and fair first coverage.")

let projectionDB = try ContentStore(path: temporary.appendingPathComponent("projection.sqlite").path)
let filenameDoc = SourceDocument(id: "name-hit", rootPath: root, path: root + "/专项技术.pptx", relativePath: "专项技术.pptx",
    kind: "document", ext: "pptx", contentHash: "name-v1", size: 1, modifiedAt: 1,
    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "普通封面")])
let bodyDoc = SourceDocument(id: "body-hit", rootPath: root, path: root + "/普通资料.pptx", relativePath: "普通资料.pptx",
    kind: "document", ext: "pptx", contentHash: "body-v1", size: 1, modifiedAt: 1,
    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "普通资料.pptx"),
             ContentBlock(key: "slide-1", kind: "slide", page: 1, text: "专项技术")])
let ocrDoc = SourceDocument(id: "ocr-hit", rootPath: root, path: root + "/白板.png", relativePath: "白板.png",
    kind: "image", ext: "png", contentHash: "ocr-v1", size: 1, modifiedAt: 1,
    blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "白板.png"),
             ContentBlock(key: "image-ocr", kind: "image_ocr", text: "手写流程图 884209")])
try projectionDB.synchronize(documents: [filenameDoc, bodyDoc, ocrDoc], rootPaths: [root])
try check(try projectionDB.projectionCounts().searchDocuments == 5, "Search projection missed content units")
try check(try projectionDB.search(allTerms: [["专项技术"]], rootPaths: [root]).first?.fileID == "name-hit",
          "Filename field did not outrank body text")
let ocrHits = try projectionDB.search(allTerms: [["手写流程图"]], rootPaths: [root])
try check(ocrHits.first?.fileID == "ocr-hit", "OCR field was not searchable")
try check(try projectionDB.search(allTerms: [["842"]], rootPaths: [root]).first?.fileID == "ocr-hit",
          "Numeric fragments in search projection failed")
print("Projection checks passed: sources/items/content units, multi-field FTS, filename weighting, OCR and numeric fragments.")

try photoChecks(temporary)
try numericChecks(temporary)
try understandingChecks(temporary)

// Exercise the deployed v7 -> v8 path: JSON vectors are converted before compatibility
// tables are dropped, and a rollback copy is retained beside the database.
func sqlite(_ path: String, _ sql: String) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [path, sql]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "DataChecks", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "sqlite3 failed: \(text)"]
        )
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

let legacyPath = temporary.appendingPathComponent("legacy-vector.sqlite").path
let migrations: String = (1...7).map { version in
    let names = [
        "v1_layered_content", "v2_database_source", "v3_photo_queue",
        "v4_numeric_fragments", "v5_content_unit_projection",
        "v6_operational_understanding", "v7_projection_integrity",
    ]
    return "INSERT INTO grdb_migrations VALUES('\(names[version - 1])');"
}.joined()
_ = try sqlite(legacyPath, """
    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
    \(migrations)
    INSERT INTO grdb_migrations VALUES('v9_retire_legacy_chunk_fts');
    INSERT INTO grdb_migrations VALUES('v10_durable_job_scheduler');
    CREATE TABLE embedding_spaces(
        id TEXT PRIMARY KEY,model_id TEXT NOT NULL,model_version TEXT NOT NULL,
        dimensions INTEGER NOT NULL);
    CREATE TABLE embeddings(
        chunk_id TEXT NOT NULL,space_id TEXT NOT NULL,content_hash TEXT NOT NULL,
        vector BLOB NOT NULL,PRIMARY KEY(chunk_id,space_id));
    CREATE TABLE features(
        id TEXT PRIMARY KEY,subject_type TEXT NOT NULL,subject_id TEXT NOT NULL,
        feature_type TEXT NOT NULL,model_key TEXT NOT NULL,model_revision TEXT NOT NULL,
        dimensions INTEGER,metric TEXT,vector_blob BLOB,content_hash TEXT NOT NULL,
        producer_run_id TEXT,created_at DOUBLE NOT NULL,
        UNIQUE(subject_type,subject_id,feature_type,model_key,model_revision));
    INSERT INTO embedding_spaces VALUES('legacy-space','legacy-model','legacy-v1',2);
    INSERT INTO embeddings VALUES('chunk-1','legacy-space','hash-1',X'5B312C305D');
    """)
_ = try ContentStore(path: legacyPath)
try check(
    try sqlite(legacyPath, """
        SELECT hex(vector_blob)||':'||vector_format||':'||model_identifier
        FROM features WHERE feature_type='text_embedding';
        """) == "414945560101010002000000003C0000:f16-le-v1-normalized:legacy-model",
    "Legacy JSON vector was not migrated losslessly to versioned Float16"
)
try check(
    try sqlite(legacyPath, """
        SELECT count(*) FROM sqlite_master
        WHERE type='table' AND name IN ('embeddings','embedding_spaces');
        """) == "0",
    "Legacy vector tables were not retired"
)
try check(
    FileManager.default.fileExists(atPath: legacyPath + ".before-vector-f16.sqlite"),
    "Destructive vector migration did not create a rollback backup"
)
print("Vector migration checks passed: Float16 format, model metadata, rollback backup and legacy table retirement.")

let schedulerPath = temporary.appendingPathComponent("legacy-jobs.sqlite").path
let schedulerMigrations = [
    "v1_layered_content", "v2_database_source", "v3_photo_queue",
    "v4_numeric_fragments", "v5_content_unit_projection",
    "v6_operational_understanding", "v7_projection_integrity",
    "v8_float16_feature_vectors", "v9_retire_legacy_chunk_fts",
].map { "INSERT INTO grdb_migrations VALUES('\($0)');" }.joined()
_ = try sqlite(schedulerPath, """
    CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
    \(schedulerMigrations)
    CREATE TABLE jobs(
        id TEXT PRIMARY KEY,subject_type TEXT NOT NULL,subject_id TEXT NOT NULL,
        job_type TEXT NOT NULL,priority INTEGER NOT NULL,state TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,not_before DOUBLE NOT NULL DEFAULT 0,
        lease_owner TEXT,lease_expires_at DOUBLE,input_hash TEXT NOT NULL,error_code TEXT,
        created_at DOUBLE NOT NULL,updated_at DOUBLE NOT NULL,
        UNIQUE(subject_type,subject_id,job_type,input_hash));
    INSERT INTO jobs VALUES(
        'job-1','item_version','version-1','deep',50,'pending',1,0,
        NULL,NULL,'hash-1',NULL,1,1);
    """)
let schedulerDB = try ContentStore(path: schedulerPath)
let migratedJob = try schedulerDB.durableJob(id: "job-1")
try check(migratedJob?.maxAttempts == 5 && migratedJob?.checkpointJSON == nil,
          "Durable scheduler migration did not preserve legacy jobs")
try check(
    try sqlite(schedulerPath, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='jobs_claim';") == "1",
    "Durable scheduler claim index is missing"
)
print("Job scheduler migration checks passed: legacy rows, retry limits and claim index.")
