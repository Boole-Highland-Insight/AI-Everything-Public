import Foundation
import AIEData

func rawTextEmbeddingChecks(in temporary: URL) throws {
    let root = temporary.appendingPathComponent("raw-library").path
    let db = try ContentStore(path: temporary.appendingPathComponent("raw.sqlite").path)
    func document(_ name: String, ext: String, hash: String, block: ContentBlock) -> SourceDocument {
        SourceDocument(
            id: name, rootPath: root, path: root + "/" + name,
            relativePath: name, kind: "document", ext: ext,
            contentHash: hash, size: 100, modifiedAt: 1,
            blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: name), block]
        )
    }
    let txt = document("notes.txt", ext: "txt", hash: "txt-v1",
                       block: ContentBlock(key: "text-0", kind: "paragraph", text: "固定主网络参数，通过独立记忆模块吸收新信息。"))
    let md = document("notes.md", ext: "md", hash: "md-v1",
                      block: ContentBlock(key: "text-0", kind: "paragraph", text: "另一份资料讨论如何避免重新训练主模型。"))
    var pdf = document("paper.pdf", ext: "pdf", hash: "pdf-v1",
                       block: ContentBlock(key: "pdf-63", kind: "page", page: 63,
                                           text: "第六十三页说明通过更新独立记忆模块学习新知识。"))
    let excluded = document("slides.pptx", ext: "pptx", hash: "ppt-v1",
                            block: ContentBlock(key: "slide-1", kind: "slide", page: 1,
                                                text: "第一版暂不建立幻灯片原文向量。"))
    try db.synchronize(documents: [txt, md, pdf, excluded], rootPaths: [root])

    let space = "raw-text-check"
    let pending = try db.missingEmbeddings(spaceID: space, rootPaths: [root], rawTextOnly: true)
    try check(pending.count == 3 && Set(pending.map(\.relativePath)) == Set(["notes.txt", "notes.md", "paper.pdf"]),
              "Existing TXT, Markdown, and PDF chunks were not selected for raw embedding")
    try check(pending.first(where: { $0.relativePath == "paper.pdf" })?.page == 63,
              "PDF source page was lost before embedding")
    try check(try db.embeddingCoverage(spaceID: space, rootPaths: [root], rawTextOnly: true).total == 3,
              "Raw embedding coverage included the wrong chunks")
    for chunk in pending {
        let vector: [Float] = chunk.relativePath == "notes.txt" ? [1, 0, 0]
            : (chunk.relativePath == "notes.md" ? [0, 1, 0] : [0, 0, 1])
        try db.putEmbedding(chunkID: chunk.id, spaceID: space, modelID: "test", modelVersion: "v1",
                            vector: vector, rootPaths: [root], expectedContentHash: chunk.contentHash)
    }
    try check(try db.embeddingCoverage(spaceID: space, rootPaths: [root], rawTextOnly: true).ready == 3,
              "Raw embedding coverage did not detect completed vectors")
    let pdfChunk = try db.searchVector([0, 0, 1], spaceID: space, rootPaths: [root]).first
    try check(pdfChunk?.relativePath == "paper.pdf" && pdfChunk?.page == 63 && pdfChunk?.text.contains("记忆模块") == true,
              "Raw vector retrieval did not retain passage and page evidence")

    pdf.contentHash = "pdf-v2"
    pdf.blocks[1].text = "更新后的论文正文讨论另一种方法。"
    try db.synchronize(documents: [txt, md, pdf, excluded], rootPaths: [root])
    let remaining = try db.missingEmbeddings(spaceID: space, rootPaths: [root], rawTextOnly: true)
    try check(remaining.count == 1 && remaining[0].relativePath == "paper.pdf",
              "Changed PDF content did not request a fresh raw vector")
    try check(try db.searchVector([0, 0, 1], spaceID: space, rootPaths: [root]).allSatisfy { $0.relativePath != "paper.pdf" },
              "Vector from an old PDF version remained searchable")

    var historical = document("history.txt", ext: "txt", hash: "history-v1",
                              block: ContentBlock(key: "old-analysis", kind: "semantic_analysis",
                                                  text: "onlyhistoric8bterm legacy summary content"))
    historical.fileSummary = "onlyhistoric8bterm legacy file summary"
    try db.synchronize(documents: [txt, md, pdf, excluded, historical], rootPaths: [root])
    let derived = try db.chunks(rootPaths: [root]).first { $0.kind == "semantic_analysis" }!
    try db.putEmbedding(chunkID: derived.id, spaceID: space, modelID: "test", modelVersion: "v1",
                        vector: [0, 0, 1], rootPaths: [root], expectedContentHash: derived.contentHash)
    try check(try db.search(allTerms: [["onlyhistoric8bterm"]], rootPaths: [root]).isEmpty,
              "Historical summary text leaked into V1 FTS")
    try check(try db.searchVectorProfiled([0, 0, 1], spaceID: space, rootPaths: [root],
                                          v1RawTextOnly: true).matches.allSatisfy { $0.kind != "semantic_analysis" },
              "Historical summary vector leaked into V1 Gemma retrieval")
}
