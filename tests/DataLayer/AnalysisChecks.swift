import Foundation
import AIEData

func analysisChecks(_ db: ContentStore, temporary: URL) throws {
    let metadata: [String: Any] = ["localScan": ["ocr": ["第一行", "第二行"], "confidence": 0.49365243315696716, "pages": 3,
        "decimal": NSDecimalNumber(string: "0.090338235294096195"), "ready": true, "empty": [], "null": NSNull(), "huge": NSNumber(value: UInt64.max)],
        "cloudUpload": ["uploadedAt": "fixture"], "provenance": ["sourceVersionID": "version-1"],
        "mediaTranscript": ["segments": [["index": 0, "status": "ready", "text": "已完成片段"]]]]
    try db.ensureAnalysis(root: "/fixture", relative: "old.pptx", fileID: "identity-1") { metadata }
    try db.ensureAnalysis(root: "/fixture", relative: "old.pptx") { fatalError("Existing analysis reread legacy input") }
    let restored = try db.analysis(root: "/fixture", relative: "old.pptx")!
    try check((restored["localScan"] as? [String: Any])?["confidence"] as? Double == 0.49365243315696716, "Floating point precision lost")
    try check(((restored["localScan"] as? [String: Any])?["decimal"] as? NSDecimalNumber)?.stringValue == "0.090338235294096195", "Decimal precision lost")
    let originalBytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    try check(try JSONSerialization.data(withJSONObject: restored, options: [.sortedKeys]) == originalBytes, "Typed fields did not round trip")
    let token = try db.changeToken()
    try expectFailure("Invalid analysis value committed") {
        try db.mutateAnalysis(root: "/fixture", relative: "old.pptx") { $0["invalid"] = Double.nan; return true }
    }
    try check(try db.changeToken() == token, "Failed field transaction changed revision")
    try db.ensureAnalysis(root: "/fixture", relative: "renamed.pptx", fileID: "identity-1") { fatalError("Rename lost metadata") }
    try check(try db.analysis(root: "/fixture", relative: "old.pptx") == nil, "Rename left duplicate analysis")
    try check(try db.analysis(root: "/fixture", relative: "renamed.pptx")?["cloudUpload"] != nil, "Rename lost cloud marker")
    try check(try db.acquireLease(recordID: "fixture", scope: "transcript", owner: "first"), "Lease not granted")
    try check(try !db.acquireLease(recordID: "fixture", scope: "transcript", owner: "second"), "Duplicate job admitted")
    try db.releaseLease(recordID: "fixture", scope: "transcript", owner: "second")
    try check(try !db.acquireLease(recordID: "fixture", scope: "transcript", owner: "second"), "Nonowner released lease")
    try db.releaseLease(recordID: "fixture", scope: "transcript", owner: "first")
    try check(try db.acquireLease(recordID: "fixture", scope: "transcript", owner: "second"), "Released lease unavailable")
    try db.importPreferences(["kept": ["/fixture/old.pptx"]])
    try db.setPreference(path: "/fixture/old.pptx", name: "kept", value: false)
    try db.importPreferences(["kept": ["/fixture/old.pptx"]])
    try check(try db.preferencePaths("kept").isEmpty, "Legacy preferences reimported on every launch")
    let identity = try db.analysisIdentity(root: "/fixture", relative: "renamed.pptx")
    let trash = StoredTrash(id: "trash-1", originalPath: "/fixture/renamed.pptx", rootPath: "/fixture", relativePath: "renamed.pptx",
        name: "renamed.pptx", kind: "document", ext: "pptx", trashedAt: 100, storedPath: "/trash/renamed.pptx", analysisID: identity, state: "moving")
    try db.saveTrash(trash); try db.finishTrash(trash, state: "trashed")
    try check(try db.analysis(root: "/fixture", relative: "renamed.pptx") == nil, "Trashed analysis retained live path")
    try db.ensureAnalysis(root: "/fixture", relative: "renamed.pptx", fileID: "new-identity") { ["new": true] }
    try db.finishTrash(trash, state: "restored", restoredRelative: "renamed 还原1.pptx")
    try check(try db.analysisIdentity(root: "/fixture", relative: "renamed 还原1.pptx") == identity, "Restore changed analysis identity")
    try check(try db.analysis(root: "/fixture", relative: "renamed 还原1.pptx")?["provenance"] != nil, "Restore lost provenance")
    try check(try db.analysis(root: "/fixture", relative: "renamed.pptx")?["new"] as? Bool == true, "Restore clobbered new file metadata")
    let replacement = SourceDocument(id: "replacement", rootPath: "/fixture", path: "/fixture/renamed.pptx", relativePath: "renamed.pptx",
        kind: "document", ext: "pptx", contentHash: "replacement-hash", size: 1, modifiedAt: 1,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "replacementretained")])
    try db.synchronize(documents: [replacement], rootPaths: ["/fixture"])
    let oldTrash = StoredTrash(id: "old-trash", originalPath: replacement.path, rootPath: "/fixture", relativePath: "renamed.pptx",
        name: "renamed.pptx", kind: "document", ext: "pptx", trashedAt: 1, storedPath: "/trash/old", analysisID: nil, state: "trashed")
    try db.saveTrash(oldTrash); try db.finishTrash(oldTrash, state: "purged")
    try check(try db.search(allTerms: [["replacementretained"]], rootPaths: ["/fixture"]).count == 1, "Purging old trash hid a new file at the same path")
    let backup = temporary.appendingPathComponent("backup.sqlite").path
    try db.backup(to: backup)
    let copy = try ContentStore(path: backup)
    try check(try copy.analysis(root: "/fixture", relative: "renamed 还原1.pptx")?["mediaTranscript"] != nil, "Backup lost checkpoints")
    let text = "# 第一节\n" + String(repeating: "这是段落。\n\n", count: 350) + "# 第二节\n" + String(repeating: "👨‍👩‍👧‍👦长词", count: 700)
    let chunks = StructuralChunker.text(text)
    try check(chunks.map(\.text).joined() == text, "Chunking changed original characters")
    try check(chunks.allSatisfy { !$0.text.isEmpty && $0.text.count <= 1600 }, "Chunk limit exceeded")
    try check(chunks.contains { $0.text.hasPrefix("# 第二节") }, "Heading did not start a chunk")
    var offset = 0
    for chunk in chunks {
        let location = try JSONSerialization.jsonObject(with: Data(chunk.locationJSON!.utf8)) as! [String: Any]
        try check(location["characterStart"] as? Int == offset, "Chunk start offset incorrect")
        offset += chunk.text.count
        try check(location["characterEnd"] as? Int == offset, "Chunk end offset incorrect")
    }
    let pages = StructuralChunker.page(text, key: "slide-3", kind: "slide", page: 3, tags: ["流程图"], parserVersion: "fixture")
    try check(pages[0].text.isEmpty && pages[0].tags == ["流程图"], "Long-page parent lost tags")
    try check(pages.dropFirst().allSatisfy { $0.page == 3 && $0.parentKey == "slide-3" }, "Page subchunks lost locator")
    try check(pages.dropFirst().map(\.text).joined() == text, "Page chunks dropped text")
    print("Analysis checks passed: lossless typed fields, rollback, rename, leases, preferences, trash identities, backup, structural chunks.")
}

func concurrencyWorkerIfRequested() throws {
    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "--analysis-worker" else { return }
    let db = try ContentStore(path: args[2])
    try db.ensureAnalysis(root: "/fixture", relative: "shared") { ["cloudUpload": ["marker": "preserved"], "provenance": ["source": "fixture"]] }
    for _ in 0..<100 {
        try db.mutateAnalysis(root: "/fixture", relative: "shared") { record in
            record["count"] = ((record["count"] as? NSNumber)?.intValue ?? 0) + 1
            record[args[3]] = true
            return true
        }
    }
    exit(0)
}
