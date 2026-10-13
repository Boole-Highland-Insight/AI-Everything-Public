import Foundation
import AIEData

func numericChecks(_ directory: URL) throws {
    let root = directory.appendingPathComponent("numeric").path
    let db = try ContentStore(path: directory.appendingPathComponent("numeric.sqlite").path)
    func doc(_ id: String, _ text: String) -> SourceDocument {
        SourceDocument(id: id, rootPath: root, path: root + "/" + id + ".txt", relativePath: id + ".txt", kind: "document", ext: "txt",
            contentHash: id, size: 1, modifiedAt: 1,
            blocks: [ContentBlock(key: "document", parentKey: nil, kind: "document", text: id),
                     ContentBlock(key: "page", kind: "page", page: 4, text: text)])
    }
    let id = doc("employee", "员工工号 EMP-12844209")
    let unrelated = doc("unrelated", "其他号码 84411 和 442")
    let wide = doc("wide", "全角编号 ９８４４２０７")
    try db.synchronize(documents: [id, unrelated, wide], rootPaths: [root])
    for query in ["128", "844", "209", "44", "12844209", "８４４"] {
        try check(try db.search(allTerms: [[query]], rootPaths: [root]).contains { $0.path == id.path && $0.page == 4 }, "Numeric fragment missed: " + query)
    }
    let hits = try db.search(allTerms: [["8442"]], rootPaths: [root])
    try check(hits.contains { $0.path == id.path } && hits.contains { $0.path == wide.path }, "Interior/full-width identifiers missing")
    try check(!hits.contains { $0.path == unrelated.path }, "Disconnected digit grams falsely matched")
    try check(try db.search(allTerms: [["工号"], ["844"]], rootPaths: [root]).count == 1, "Text + number conjunction broken")
    try check(try db.search(allTerms: [["8442", "其他"]], rootPaths: [root]).contains { $0.path == unrelated.path }, "Numeric/text synonym OR broken")
    try check(try db.search(allTerms: [["844"]], rootPaths: []).isEmpty, "Numeric query escaped root scope")
    try db.synchronize(documents: [unrelated], rootPaths: [root])
    try check(try db.search(allTerms: [["8442"]], rootPaths: [root]).isEmpty, "Old numeric versions remained searchable")
    print("Numeric checks passed: prefixes, interior/suffix fragments, full-width digits, OCR/page evidence, AND/OR, disconnected-gram rejection and removed files.")
}
