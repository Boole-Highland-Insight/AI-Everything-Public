import Foundation
import AIEData

func cleanSearchLifecycleChecks(in temporary: URL) throws {
    let path = temporary.appendingPathComponent("clean-lifecycle.sqlite").path
    let root = temporary.appendingPathComponent("clean-library").path
    let store = try ContentStore(path: path)
    var doc = SourceDocument(id: "clean-file", rootPath: root, path: root + "/sample.txt",
                             relativePath: "sample.txt", kind: "document", ext: "txt",
                             contentHash: "revision-0", size: 100, modifiedAt: 1,
                             blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "保留分析测试")])
    try store.ensureAnalysis(root: root, relative: "sample.txt") { ["deepScan": ["blurb_zh": "保留已有分析"]] }
    var vector = [Float](repeating: 0, count: 768); vector[0] = 1
    for revision in 0..<8 {
        doc.contentHash = "revision-\(revision)"
        try store.synchronize(documents: [doc], rootPaths: [root])
        let id = ContentIdentity.chunk(versionID: doc.versionID, key: "document")
        try store.putEmbedding(chunkID: id, spaceID: "clean-test", modelID: "gemma",
                               modelVersion: "test", vector: vector, rootPaths: [root])
        try check(try sqlite(path, "SELECT count(*) FROM chunks;").trimmingCharacters(in: .whitespacesAndNewlines) == "1", "Old chunks accumulated")
        try check(try sqlite(path, "SELECT count(*) FROM features WHERE vector_blob IS NOT NULL;").trimmingCharacters(in: .whitespacesAndNewlines) == "1", "Old vectors accumulated")
        try check(try sqlite(path, "SELECT count(*) FROM search_documents_fts;").trimmingCharacters(in: .whitespacesAndNewlines) == "1", "Old FTS accumulated")
    }
    try store.restrictRoots(to: [])
    try check(try store.statistics().chunks == 0, "Revoked root retained derived chunks")
    try check(try store.analysis(root: root, relative: "sample.txt") != nil, "Retirement removed analysis")
    try store.synchronize(documents: [doc], rootPaths: [root])
    try check(try store.search(allTerms: [["保留分析"]], rootPaths: [root]).count == 1, "Same-version re-add failed to restore search")
    try store.synchronize(documents: [], rootPaths: [root])
    try check(try store.statistics().chunks == 0, "Deleted file retained derived chunks")
    try check(try sqlite(path, "PRAGMA foreign_key_check;").isEmpty, "Retirement broke foreign keys")
    try store.synchronize(documents: [doc], rootPaths: [root])
    try check(try store.statistics().chunks == 1, "Deleted file could not be re-added")
    print("Clean lifecycle: 8 revisions bounded, revoked/deleted projections retired, analysis retained, same-version re-add restored")
}
