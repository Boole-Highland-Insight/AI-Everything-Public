import Foundation
import AIEData

/// One policy for source selection, independent of the retriever that found a file.
enum EvidencePolicy {
    private static let expressions = NSCache<NSString, NSRegularExpression>()
    static func isModelDerived(_ kind: String) -> Bool {
        kind == "semantic_analysis"
            || kind == "video_segment_analysis"
            || kind == "system_visual_labels"
    }
    static func coverage(_ text: String, query: LibraryIndex.CompiledQuery) -> Double {
        let groups = query.tokens.map(LibraryIndex.aliases) + (query.anyOf.isEmpty ? [] : [query.anyOf])
        guard !groups.isEmpty else { return 0 }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let matched = groups.filter { group in group.contains { needle in
            let needle = needle.lowercased()
            if let number = NumericSearch.term(needle) { return NumericSearch.contains(number, in: text) }
            if needle.unicodeScalars.contains(where: { (0x4e00...0x9fff).contains($0.value) }) { return folded.contains(needle) }
            let key = needle as NSString
            let expression: NSRegularExpression
            if let cached = expressions.object(forKey: key) { expression = cached }
            else {
                guard let compiled = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b") else { return false }
                expressions.setObject(compiled, forKey: key)
                expression = compiled
            }
            return expression.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
        }}.count
        return Double(matched) / Double(groups.count)
    }
    static func priority(_ chunk: ChunkResult, cosine: Double, query: LibraryIndex.CompiledQuery,
                         ranked: Bool = false) -> Double {
        let lexical = coverage((chunk.tags + [chunk.text]).joined(separator: " "), query: query)
        let semantic = ranked || cosine >= 0.52
        if chunk.kind == "document" { return 0.5 + max(lexical, ranked ? 0.5 : cosine) }
        if isModelDerived(chunk.kind) {
            let anchor = chunk.startSeconds == nil ? 0.0 : 0.2
            if lexical >= 1 { return 1.5 + cosine + anchor }
            if semantic { return 1.25 + (ranked ? 0.5 : cosine) + anchor }
            if lexical > 0 { return 1 + lexical + anchor }
            return 0
        }
        // Relevant body always beats a root summary; avoid choosing an arbitrary unrelated body.
        if lexical >= 1 { return 5 + cosine }
        if semantic { return 3 + (ranked ? 0.5 : cosine) + lexical * 0.2 }
        if lexical > 0 { return 2 + lexical }
        return 0
    }
    static func hit(file: IndexedFile, chunk: IndexedChunk, query: String, reason: String,
                    needles preparedNeedles: [String]? = nil) -> FileHit {
        let root = chunk.kind == "document"
        let needles = preparedNeedles ?? LibraryIndex.compile(query).tokens.flatMap(LibraryIndex.aliases)
        let source: String, label: String
        if root {
            source = file.fileSummary
            label = source.isEmpty ? "文件信息 · " : "文件摘要 · "
        } else {
            source = chunk.text.isEmpty ? chunk.summary : chunk.text
            if let location = LibraryIndex.sheetLocation(chunk.locationJSON) { label = location + " · " }
            else if let page = chunk.page { label = "第 \(page) 页 · " }
            else if let start = chunk.startSeconds, let end = chunk.endSeconds {
                label = String(format: "%02d:%02d–%02d:%02d · ", Int(start)/60, Int(start)%60, Int(end)/60, Int(end)%60)
            } else { label = "原文 · " }
        }
        let excerpt = source.isEmpty ? file.name : LibraryIndex.evidenceSnippet(source, needles: needles)
        return FileHit(path: file.path, name: file.name, relative: file.relative, kind: file.kind, ext: file.ext, mtime: file.mtime,
                       reason: reason, score: 20, snippet: label + excerpt, highlights: needles.filter { excerpt.localizedCaseInsensitiveContains($0) },
                       thumbPath: file.thumbPath, uploadedToCloud: file.uploadedToCloud, chunkID: chunk.id, page: chunk.page,
                       startSeconds: chunk.startSeconds, endSeconds: chunk.endSeconds)
    }
    static func fallback(file: IndexedFile, original: FileHit) -> FileHit {
        FileHit(path: original.path, name: original.name, relative: original.relative, kind: original.kind, ext: original.ext, mtime: original.mtime,
                reason: original.reason, score: original.score,
                snippet: file.fileSummary.isEmpty ? "文件信息 · " + file.name : "文件摘要 · " + String(file.fileSummary.prefix(90)), highlights: [],
                thumbPath: original.thumbPath, uploadedToCloud: original.uploadedToCloud)
    }
}
