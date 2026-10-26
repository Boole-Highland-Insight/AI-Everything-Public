import Foundation
import AIEData

func semanticSchedulingChecks(in temporary: URL) throws {
    let path = temporary.appendingPathComponent("semantic-scheduling.sqlite").path
    let store = try ContentStore(path: path)
    let root = "/semantic-scheduling-fixture"
    let document = SourceDocument(
        id: "indexed", rootPath: root, path: root + "/notes.txt", relativePath: "notes.txt",
        kind: "document", ext: "txt", contentHash: "notes-v1", size: 1, modifiedAt: 1,
        blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: "notes.txt")] + (0..<2_000).map {
            ContentBlock(key: "block-\($0)", kind: "paragraph", text: "fixture \($0)")
        }
    )
    try store.synchronize(documents: [document], rootPaths: [root])
    let seed = try store.missingEmbeddings(spaceID: "fixture", rootPaths: [root], limit: 1)[0]
    try store.putEmbedding(chunkID: seed.id, spaceID: "fixture", modelID: "fixture",
                           modelVersion: "1", vector: [1, 0], rootPaths: [root])
    // Many filename-only files plus already embedded chunks reproduce the production join.
    // Seed SQL avoids spending the test's time generating unrelated search projections.
    _ = try sqlite(path, """
        WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<50000)
        INSERT INTO files(id,root_id,path,relative_path,kind,ext,present,size,modified_at)
        SELECT 'pending-'||n,r.id,r.path||'/pending-'||n,'pending-'||n,'document','txt',1,0,1
        FROM numbers CROSS JOIN roots r;
        INSERT INTO features(
            id,subject_type,subject_id,feature_type,model_key,model_revision,dimensions,metric,
            vector_blob,content_hash,created_at,vector_format,model_identifier)
        SELECT 'vector-'||c.id,'content_unit',c.id,'text_embedding','fixture','1',2,'cosine',
               x.vector_blob,c.content_hash,1,x.vector_format,'fixture'
        FROM chunks c CROSS JOIN (SELECT vector_blob,vector_format FROM features
            WHERE feature_type='text_embedding' LIMIT 1) x
        WHERE c.id NOT IN (SELECT subject_id FROM features WHERE feature_type='text_embedding')
          AND c.block_key<>'block-1999';
        """)
    let started = ProcessInfo.processInfo.systemUptime
    let batch = try store.missingEmbeddings(spaceID: "fixture", rootPaths: [root], limit: 8)
    let seconds = ProcessInfo.processInfo.systemUptime - started
    try check(batch.count == 1 && batch[0].text == "fixture 1999",
              "Semantic scheduling lost the remaining unembedded chunk")
    try check(seconds < 2, "Semantic scheduling scanned the file table per vector (\(seconds)s)")
    let searchStarted = ProcessInfo.processInfo.systemUptime
    let matches = try store.searchVector([1, 0], spaceID: "fixture", rootPaths: [root], limit: 8)
    try check(matches.count == 8 && matches.allSatisfy { $0.fileID == document.id },
              "Vector lookup lost current-file filtering")
    try check(ProcessInfo.processInfo.systemUptime - searchStarted < 2,
              "Cold vector retrieval scanned unrelated files per vector")
    print(String(format: "Semantic scheduling regression passed: 50,001 files, 2,000 vectors, %.0f ms.", seconds * 1_000))
}
