import Foundation
import AIEData

func gemmaFeatureChecks(in temporary: URL) throws {
    let root = temporary.appendingPathComponent("gemma-library").path
    let db = try ContentStore(path: temporary.appendingPathComponent("gemma.sqlite").path)
    func document(_ name: String, hash: String, block: ContentBlock) -> SourceDocument {
        SourceDocument(id: name, rootPath: root, path: root + "/" + name,
                       relativePath: name, kind: "document",
                       ext: String(name.split(separator: ".").last ?? ""),
                       contentHash: hash, size: 100, modifiedAt: 1,
                       blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: name), block])
    }
    var image = document("photo.png", hash: "photo-v1",
                         block: ContentBlock(key: "visual-image", kind: "visual_image", text: "",
                                             summaryMethod: "visual_anchor"))
    let pdf = document("chart.pdf", hash: "chart-v1",
                       block: ContentBlock(key: "visual-page-3", kind: "visual_page", page: 3,
                                           text: "", summaryMethod: "visual_anchor"))
    let video = document("clip.mp4", hash: "clip-v1",
                         block: ContentBlock(key: "visual-frame-1", kind: "visual_frame",
                                             startSeconds: 12, endSeconds: 13, text: "",
                                             summaryMethod: "visual_anchor"))
    try db.synchronize(documents: [image, pdf, video], rootPaths: [root])
    let visualSpace = "gemma2:revision:visual-page-v1"
    let pending = try db.missingVisualEmbeddings(spaceID: visualSpace, rootPaths: [root], limit: 10)
    try check(pending.count == 3, "Visual candidates did not include image, PDF page and video frame")
    try check(try db.visualEmbeddingCoverage(spaceID: visualSpace, rootPaths: [root]).total == 3,
              "Visual coverage counted the wrong source units")
    let page = pending.first { $0.kind == "visual_page" }!
    try db.recordVisualEmbeddingFailure(chunkID: page.id, spaceID: visualSpace, rootPaths: [root], error: "test")
    try check(try db.missingVisualEmbeddings(spaceID: visualSpace, rootPaths: [root], limit: 10).count == 2,
              "Failed visual item was retried before its backoff")
    var vector = [Float](repeating: 0, count: 768)
    vector[0] = 1
    for chunk in pending {
        vector[0] = chunk.kind == "visual_page" ? 0 : 1
        vector[1] = chunk.kind == "visual_page" ? 1 : 0
        try db.putEmbedding(chunkID: chunk.id, spaceID: visualSpace, modelID: "gemma",
                            modelVersion: "revision", vector: vector, rootPaths: [root],
                            expectedContentHash: chunk.contentHash, featureType: "visual_embedding")
    }
    try db.clearVisualEmbeddingFailure(chunkID: page.id, spaceID: visualSpace)
    try check(try db.visualEmbeddingCoverage(spaceID: visualSpace, rootPaths: [root]).ready == 3,
              "Visual coverage did not detect completed vectors")
    let pageHit = try db.searchVectorProfiled([Float](repeating: 0, count: 1) + [1]
        + [Float](repeating: 0, count: 766), spaceID: visualSpace, rootPaths: [root],
        featureType: "visual_embedding").matches.first
    try check(pageHit?.page == 3 && pageHit?.kind == "visual_page",
              "Gemma visual search lost the PDF page anchor")
    try check(try db.searchVectorProfiled(vector, spaceID: visualSpace, rootPaths: [root]).matches.isEmpty,
              "Visual vectors leaked into the text channel")
    try db.putEmbedding(chunkID: page.id, spaceID: visualSpace, modelID: "gemma",
                        modelVersion: "revision", vector: vector, rootPaths: [root],
                        expectedContentHash: page.contentHash, featureType: "text_embedding")
    let visualCount = try db.searchVectorProfiled(vector, spaceID: visualSpace, rootPaths: [root],
                                                  featureType: "visual_embedding").matches.count
    let textCount = try db.searchVectorProfiled(vector, spaceID: visualSpace, rootPaths: [root],
                                                featureType: "text_embedding").matches.count
    let visualCountAgain = try db.searchVectorProfiled(vector, spaceID: visualSpace, rootPaths: [root],
                                                       featureType: "visual_embedding").matches.count
    try check(visualCount == 3 && textCount == 1 && visualCountAgain == 3,
              "Alternating visual and text vector searches mixed their cached candidates")
    image.contentHash = "photo-v2"
    try db.synchronize(documents: [image, pdf, video], rootPaths: [root])
    try check(try db.visualEmbeddingCoverage(spaceID: visualSpace, rootPaths: [root]).ready == 2,
              "An old image vector remained current after the file changed")
}
