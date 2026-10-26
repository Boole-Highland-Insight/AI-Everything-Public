import Foundation
#if canImport(AIEData)
import AIEData
#endif
import NaturalLanguage
import CoreServices

enum FileKind: String, Equatable {
    case image, video, audio, document, spreadsheet, code, archive, other
}

struct FileHit: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let relative: String
    let kind: FileKind
    let ext: String
    let mtime: Date
    let reason: String
    let score: Int
    let snippet: String
    let highlights: [String]
    let thumbPath: String?
    var uploadedToCloud: Bool
    var chunkID: String? = nil
    var page: Int? = nil
    var startSeconds: Double? = nil
    var endSeconds: Double? = nil
    var confidenceTier: SearchConfidenceTier = .possible
    var evidence: [SearchEvidence] = []
}

struct IndexedChunk {
    let id: String
    let versionID: String
    let page: Int?
    let text: String
    let tags: [String]
    let summary: String
    let kind: String
    var startSeconds: Double? = nil
    var endSeconds: Double? = nil
    var locationJSON: String? = nil
}

struct IndexedFile {
    let path: String
    let name: String
    let relative: String
    let kind: FileKind
    let ext: String
    let mtime: Date
    var haystack: String
    var preview: String
    let thumbPath: String?
    let rootPath: String
    let size: Int
    var hasBarcode: Bool
    var isScreenshot: Bool
    /// 一行摘要，给 Groq 第一段圈候选。
    var llmLine: String
    /// 稍完整的内容卡片，给 Groq 第二段确认。
    var llmCard: String
    /// 源文件内容曾发给云端大模型（再利用）。QuickScan 不置位。
    var uploadedToCloud: Bool
    var fileID: String? = nil
    var versionID: String? = nil
    var contentHash: String? = nil
    var chunks: [IndexedChunk] = []
    var summaryIssue: String? = nil
    var contentIssue: String? = nil
    var fileSummary = ""
    var browseSummary = ""
    var lastOpenedAt: Date? = nil
    var entityNames: [String] = []
    var contentType = ""
    var completionState = ""
    var completionConfidence = 0.0
    var completionEvidence: [String] = []
    var missingParts: [String] = []
    var reuseAction = ""
    var reuseReason = ""
    var reuseConfidence = 0.0
    var reuseDismissed = false
    var reuseResolved = false
    var reuseSessionActive = false
    var reuseResultPath: String? = nil
    var reuseFeedbackUpdatedAt: Date? = nil
    var isGeneratedArtifact = false
}

enum LibraryIndex {
    static func kind(for ext: String) -> FileKind {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff", "avif":
            return .image
        case "mp4", "mov", "m4v", "webm", "avi":
            return .video
        case "mp3", "wav", "aac", "m4a", "flac":
            return .audio
        case "csv", "tsv", "xlsx", "xls":
            return .spreadsheet
        case "pdf", "doc", "docx", "ppt", "pptx", "txt", "md", "rtf", "pages":
            return .document
        case "json", "py", "js", "ts", "swift", "go", "rs":
            return .code
        case "zip", "tar", "gz", "7z":
            return .archive
        default:
            return .other
        }
    }

    static func load(roots: [URL]) -> [IndexedFile] {
        let many = roots.count > 1
        var files: [IndexedFile] = []
        for root in roots {
            files.append(contentsOf: load(root: root, prefixRootName: many))
        }
        return files
    }

    static func load(root: URL, prefixRootName: Bool = false) -> [IndexedFile] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [IndexedFile] = []
        for case let enumeratedURL as URL in en {
            let url = enumeratedURL.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path + "/") else { continue }
            if url.path.contains("/scanner/") { continue }
            let name = url.lastPathComponent
            if name.hasPrefix("vision-probe-report") { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
            ]),
                  values.isRegularFile == true
            else { continue }

            let rel = String(url.path.dropFirst(root.path.count + 1))
            let displayRel = prefixRootName ? "\(root.lastPathComponent)/\(rel)" : rel
            let ext = url.pathExtension.lowercased()
            let kind = kind(for: ext)
            let extra = ""
            let analysisPlaceholder: [String: Any]? = nil
            let aliases: String
            switch kind {
            case .image: aliases = "照片 图片"
            case .video: aliases = "视频 影片 录像 短片"
            case .spreadsheet: aliases = "表格 报表"
            case .document: aliases = "合同 文档"
            default: aliases = ""
            }
            let hay0 = "\(name)\n\(rel)\n\(root.lastPathComponent)\n\(kind.rawValue)\n\(ext)\n\(aliases)\n\(extra)"
            let hay = (hay0 + "\n" + zhAliases(in: hay0)).lowercased()
            let preview = extra
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let llm = llmPayload(obj: analysisPlaceholder, relative: displayRel, name: name, kind: kind)
            let hints = junkHints(obj: analysisPlaceholder)
            files.append(
                IndexedFile(
                    path: url.path,
                    name: name,
                    relative: displayRel,
                    kind: kind,
                    ext: ext,
                    mtime: values.contentModificationDate ?? .distantPast,
                    haystack: hay,
                    preview: preview,
                    thumbPath: url.path,
                    rootPath: root.path,
                    size: values.fileSize ?? 0,
                    hasBarcode: hints.barcode,
                    isScreenshot: hints.screenshot,
                    llmLine: llm.line,
                    llmCard: llm.card,
                    uploadedToCloud: isCloudMarked(analysisPlaceholder),
                    lastOpenedAt: lastOpenedDate(url)
                )
            )
        }
        return files
    }

    private static func lastOpenedDate(_ url: URL) -> Date? {
        // Spotlight's user-facing last-used time; filesystem access time would also
        // change when our scanner reads a file and must not drive scan priority.
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func applyAnalysis(_ record: [String: Any], to file: inout IndexedFile) {
        let hints = junkHints(obj: record)
        file.hasBarcode = hints.barcode; file.isScreenshot = hints.screenshot
        file.uploadedToCloud = isCloudMarked(record)
        let deep = record["deepScan"] as? [String: Any] ?? [:]
        file.entityNames = strings(deep["entities_zh"], limit: 24)
        file.contentType = (deep["content_type_zh"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        file.completionState = (deep["completion_state"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        file.completionConfidence = number(deep["completion_confidence"])
        file.completionEvidence = strings(deep["completion_evidence_zh"], limit: 4)
        file.missingParts = strings(deep["missing_parts_zh"], limit: 4)
        file.reuseAction = (deep["reuse_action"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        file.reuseReason = (deep["reuse_reason_zh"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        file.reuseConfidence = number(deep["reuse_confidence"])
        let feedback = record["reuseFeedback"] as? [String: Any] ?? [:]
        let provenance = record["provenance"] as? [String: Any] ?? [:]
        file.isGeneratedArtifact = provenance["relation"] as? String == "reuse"
        let feedbackHash = feedback["sourceHash"] as? String ?? ""
        if !feedbackHash.isEmpty, feedbackHash == file.contentHash {
            file.reuseDismissed = feedback["notDraft"] as? Bool == true
            file.reuseResolved = feedback["resolved"] as? Bool == true
            file.reuseSessionActive = feedback["sessionActive"] as? Bool == true
            file.reuseResultPath = feedback["currentResultPath"] as? String
                ?? feedback["resultPath"] as? String
            if let epoch = feedback["updatedAtEpoch"] as? NSNumber {
                file.reuseFeedbackUpdatedAt = Date(timeIntervalSince1970: epoch.doubleValue)
            } else if let stamp = feedback["updatedAt"] as? String {
                file.reuseFeedbackUpdatedAt = ISO8601DateFormatter().date(from: stamp)
            }
        }
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? Double { return min(max(value, 0), 1) }
        if let value = value as? Int { return min(max(Double(value), 0), 1) }
        if let value = value as? NSNumber { return min(max(value.doubleValue, 0), 1) }
        return 0
    }

    private static func strings(_ value: Any?, limit: Int) -> [String] {
        (value as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0.prefix(240)) }
    }

    static func isCloudMarked(_ record: [String: Any]?) -> Bool {
        let cloud = record?["cloudUpload"] as? [String: Any] ?? [:]
        return !(cloud["uploadedAt"] as? String ?? "").isEmpty || !(cloud["purposes"] as? [String] ?? []).isEmpty
    }

    static func semanticHit(file: IndexedFile, rank: Int, query: String) -> FileHit {
        hit(file: file, reason: "语义", score: max(12, 40 - rank), compiled: compile(query))
    }

    private static func llmPayload(
        obj: [String: Any]?,
        relative: String,
        name: String,
        kind: FileKind
    ) -> (line: String, card: String) {
        let kindZh: String
        switch kind {
        case .image: kindZh = "图片"
        case .video: kindZh = "视频"
        case .audio: kindZh = "音频"
        case .document: kindZh = "文档"
        case .spreadsheet: kindZh = "表格"
        default: kindZh = kind.rawValue
        }
        var blurb = ""
        var keywords: [String] = []
        var localBits: [String] = []
        if let deep = obj?["deepScan"] as? [String: Any],
           !(deep["blurb_zh"] as? String ?? "").isEmpty {
            blurb = deep["blurb_zh"] as? String ?? ""
            for key in ["keywords_zh", "topics_zh", "entities_zh", "objects_zh", "actions_zh"] {
                keywords += deep[key] as? [String] ?? []
            }
        } else if let quick = obj?["quickScan"] as? [String: Any] {
            blurb = (quick["blurb_zh"] as? String) ?? ""
            if let keys = quick["keywords_zh"] as? [String] { keywords = keys }
        }
        if let local = obj?["localScan"] as? [String: Any] {
            if let vis = local["vision"] as? [String: Any] {
                if let text = vis["searchableText"] as? String, !text.isEmpty {
                    localBits.append(text)
                }
                if let ocr = vis["ocr"] {
                    var ocrParts: [String] = []
                    collectStrings(from: ocr, into: &ocrParts)
                    if !ocrParts.isEmpty { localBits.append("OCR " + ocrParts.joined(separator: " ")) }
                }
            }
            if let nl = local["naturalLanguage"] as? [String: Any],
               let text = nl["searchableText"] as? String, !text.isEmpty {
                localBits.append(text)
            }
            if let speech = local["speech"] as? [String: Any],
               let text = speech["searchableText"] as? String, !text.isEmpty {
                localBits.append(text)
            }
        }
        let localJoined = localBits
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let summary = blurb.isEmpty ? localJoined : blurb
        let lineCore = summary.isEmpty ? name : summary
        let line = clip("\(relative) · \(kindZh) · \(lineCore)", max: 220)
        var cardParts = ["\(relative)（\(kindZh)）"]
        if !blurb.isEmpty { cardParts.append(clip(blurb, max: 280)) }
        if !keywords.isEmpty { cardParts.append("关键词：" + keywords.prefix(8).joined(separator: "、")) }
        if blurb.isEmpty, !localJoined.isEmpty { cardParts.append(clip(localJoined, max: 220)) }
        return (line, cardParts.joined(separator: " | "))
    }

    private static func junkHints(obj: [String: Any]?) -> (barcode: Bool, screenshot: Bool) {
        guard let vis = (obj?["localScan"] as? [String: Any])?["vision"] as? [String: Any] else {
            return (false, false)
        }
        var barcodes: [String] = []
        if let raw = vis["barcodes"] { collectStrings(from: raw, into: &barcodes) }
        var screenshot = false
        if let tags = vis["tags"] as? [[String: Any]] {
            screenshot = tags.contains { ($0["id"] as? String) == "screenshot" }
        }
        return (!barcodes.isEmpty, screenshot)
    }

    /// 英文标签的中文别名；中文摘要从数据库分析记录读取。
    static func zhAliases(in text: String) -> String {
        let low = text.lowercased()
        var out: [String] = []
        let table: [(String, String)] = [
            ("botanical garden", "植物园"),
            ("indoor garden", "室内花园 植物园"),
            ("greenhouse", "温室 暖房 植物园 花房"),
            ("botanical", "植物园 植物"),
            ("fern", "蕨 蕨类"),
            ("edinburgh castle", "爱丁堡城堡"),
            ("edinburgh", "爱丁堡"),
            ("scotland", "苏格兰"),
            ("glencoe", "格伦科"),
            ("highlands", "高地"),
            ("tower bridge", "塔桥 伦敦塔桥"),
            ("river thames", "泰晤士河"),
            ("london", "伦敦"),
            ("castle", "城堡"),
            ("mosque", "清真寺"),
            ("fishing", "钓鱼 捕鱼"),
            ("desert", "沙漠"),
            ("sand dune", "沙丘"),
            ("stadium", "球场 体育场"),
            ("murrayfield", "默里菲尔德"),
        ]
        for (en, zh) in table where low.contains(en) {
            out.append(zh)
        }
        return out.joined(separator: " ")
    }

    private static func collectStrings(from any: Any, into parts: inout [String]) {
        if let text = any as? String {
            if !text.isEmpty { parts.append(text) }
        } else if let arr = any as? [Any] {
            for item in arr { collectStrings(from: item, into: &parts) }
        } else if let dict = any as? [String: Any] {
            for (key, value) in dict {
                if ["hash", "sourceHash", "importedFrom", "model", "provider"].contains(key) { continue }
                collectStrings(from: value, into: &parts)
            }
        }
    }

    static func search(query: String, in files: [IndexedFile], limit: Int = 40) -> [FileHit] {
        let compiled = compile(query)
        guard !compiled.tokens.isEmpty || !compiled.anyOf.isEmpty || compiled.allowsUnfilteredBrowse else {
            return []
        }
        var results: [FileHit] = []
        for file in files {
            if let kinds = compiled.kinds, !kinds.contains(file.kind) { continue }
            if let ext = compiled.ext, file.ext != ext { continue }
            var score = 0
            var reason = "路径"
            if compiled.tokens.isEmpty, compiled.anyOf.isEmpty {
                score = 1
                reason = compiled.kinds == nil ? "全部" : "类型"
            } else {
                let nameLow = file.name.lowercased()
                var ok = true
                for token in compiled.tokens {
                    if hayContains(token, in: nameLow) || aliases(of: token).contains(where: { hayContains($0, in: nameLow) }) {
                        score += 8
                        reason = "文件名"
                    } else if tokenHits(token, in: file.haystack) {
                        score += 2
                        if reason == "路径" { reason = "索引" }
                    } else {
                        ok = false
                        break
                    }
                }
                if ok, !compiled.anyOf.isEmpty {
                    let hit = compiled.anyOf.contains { tokenHits($0, in: file.haystack) || hayContains($0, in: nameLow) }
                    if hit {
                        score += 2
                        if reason == "路径" { reason = "索引" }
                    } else {
                        ok = false
                    }
                }
                if !ok { continue }
            }
            if reason == "文件名", !compiled.tokens.allSatisfy({ token in aliases(of: token).contains { hayContains($0, in: file.name.lowercased()) } }) { reason = "索引" }
            if compiled.kinds != nil { score += 3 }
            results.append(hit(file: file, reason: reason, score: score, compiled: compiled))
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.mtime > $1.mtime
        }
        if results.count > limit { results = Array(results.prefix(limit)) }
        return results
    }

    private static func hit(file: IndexedFile, reason: String, score: Int, compiled: CompiledQuery) -> FileHit {
        let snip = makeSnippet(file: file, compiled: compiled)
        var marks = snip.highlights
        for needle in snippetNeedles(compiled) where file.name.localizedCaseInsensitiveContains(needle) {
            if !marks.contains(needle) { marks.append(needle) }
        }
        return FileHit(
            path: file.path, name: file.name, relative: file.relative,
            kind: file.kind, ext: file.ext, mtime: file.mtime,
            reason: reason, score: score,
            snippet: snip.text,
            highlights: marks,
            thumbPath: file.thumbPath,
            uploadedToCloud: file.uploadedToCloud,
            chunkID: snip.chunkID,
            page: snip.page,
            startSeconds: snip.startSeconds,
            endSeconds: snip.endSeconds
        )
    }

    static func recentSnippet(_ file: IndexedFile) -> String {
        if !file.browseSummary.isEmpty { return "文件摘要 · " + clip(file.browseSummary, max: 72) }
        if let body = file.chunks.first(where: { $0.kind != "document" && !$0.text.isEmpty }) { return "原文 · " + clip(body.text, max: 72) }
        return "文件信息 · " + file.name
    }

    private static func makeSnippet(file: IndexedFile, compiled: CompiledQuery) -> (
        text: String, highlights: [String], chunkID: String?, page: Int?,
        startSeconds: Double?, endSeconds: Double?
    ) {
        let source = file.preview.isEmpty ? file.haystack : file.preview
        let needles = snippetNeedles(compiled)
        let ranked = file.chunks.filter { $0.kind != "document" }.map { chunk -> (IndexedChunk, Int) in
            let content = ([chunk.text, chunk.summary] + chunk.tags).joined(separator: "\n").lowercased()
            return (chunk, needles.reduce(0) { $0 + (content.contains($1.lowercased()) ? 1 : 0) })
        }.filter { $0.1 > 0 }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return ($0.0.page ?? 0) < ($1.0.page ?? 0)
        }
        if let chunk = ranked.first?.0 {
            let content = (chunk.tags + [chunk.text]).joined(separator: " ")
            let excerpt = firstSnippet(in: content, needles: needles) ?? clip(content, max: 72)
            let text: String
            if let sheet = sheetLocation(chunk.locationJSON) { text = sheet + " · " }
            else if let page = chunk.page { text = "第 \(page) 页 · " }
            else if let start = chunk.startSeconds, let end = chunk.endSeconds {
                func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
                text = "\(time(start))–\(time(end)) · "
            } else { text = "" }
            return (
                text + excerpt, needles.filter { excerpt.localizedCaseInsensitiveContains($0) },
                chunk.id, chunk.page, chunk.startSeconds, chunk.endSeconds
            )
        }
        let text = firstSnippet(in: source, needles: needles) ?? clip(source, max: 72)
        let hits = needles.filter { text.range(of: $0, options: .caseInsensitive) != nil }
        return (text, hits, nil, nil, nil, nil)
    }

    private static func snippetNeedles(_ compiled: CompiledQuery) -> [String] {
        var needles = compiled.tokens + compiled.anyOf
        for token in compiled.tokens {
            needles.append(contentsOf: aliases(of: token))
        }
        needles = needles.filter { $0.count >= 2 }
        let preferCJK = needles.contains { $0.contains(where: isCJK) }
        needles.sort { a, b in
            let ac = a.contains(where: isCJK)
            let bc = b.contains(where: isCJK)
            if preferCJK, ac != bc { return ac && !bc }
            return a.count > b.count
        }
        var seen = Set<String>()
        return needles.filter { seen.insert($0.lowercased()).inserted }
    }

    static func sheetLocation(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let location = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let member = location["archiveMember"] as? String { return "包内文件：" + member }
        guard let sheet = location["sheet"] as? String, let start = location["rowStart"] as? Int,
              let end = location["rowEnd"] as? Int else { return nil }
        return "工作表：\(sheet) · 第 \(start)–\(end) 行"
    }

    static func evidenceSnippet(_ text: String, needles: [String]) -> String {
        firstSnippet(in: text, needles: needles) ?? clip(text, max: 90)
    }

    private static func firstSnippet(in text: String, needles: [String], radius: Int = 18) -> String? {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !compact.isEmpty else { return nil }
        for needle in needles {
            if let range = compact.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = compact.index(range.lowerBound, offsetBy: -radius, limitedBy: compact.startIndex) ?? compact.startIndex
                let end = compact.index(range.upperBound, offsetBy: radius, limitedBy: compact.endIndex) ?? compact.endIndex
                var piece = String(compact[start..<end]).trimmingCharacters(in: .whitespaces)
                if start != compact.startIndex { piece = "…" + piece }
                if end != compact.endIndex { piece = piece + "…" }
                return piece
            }
        }
        return nil
    }

    private static func clip(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func tokenHits(_ token: String, in haystack: String) -> Bool {
        aliases(of: token).contains { hayContains($0, in: haystack) }
    }

    /// 英文按词边界，避免 sea 命中 research / search。
    private static func hayContains(_ needle: String, in hay: String) -> Bool {
        if needle.isEmpty { return false }
        if let number = NumericSearch.term(needle) { return NumericSearch.contains(number, in: hay) }
        if needle.contains(where: isCJK) {
            return hay.contains(needle)
        }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b"
        return hay.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func aliases(of token: String) -> [String] {
        let groups: [[String]] = [
            ["手绘", "素描", "速写", "铅笔画", "线稿", "sketch", "sketches", "hand-drawn", "pencil drawing"],
            ["英语", "英文", "english"],
            ["听力", "听力练习", "listening", "ielts"],
            ["钓鱼", "捕鱼", "钓鱼竿", "fishing"],
            ["海边", "海滨", "海岸", "海滩", "海景", "pier", "waterfront", "beach", "sea"],
            ["植物园", "温室", "greenhouse", "botanical"],
            ["城堡", "castle"],
            ["徒步", "hiking"],
            ["日记", "笔记", "游记", "blog", "diary", "journal"],
            ["猫图", "猫", "小猫", "猫咪", "cat", "kitten"],
            ["伤疤", "伤痕", "疤痕", "伤口", "scar", "scars"],
        ]
        if token.count < 2 { return [token] }
        if let group = groups.first(where: { $0.contains(token) }) {
            return group
        }
        return [token]
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func cjkPieces(_ token: String) -> [String] {
        let chars = Array(token)
        let hasCJK = chars.contains(where: isCJK)
        guard hasCJK, chars.count >= 2 else { return [token] }
        var parts: [String] = []
        var i = 0
        while i < chars.count {
            let remain = chars.count - i
            let take = remain == 3 ? 3 : min(2, remain)
            parts.append(String(chars[i..<(i + take)]))
            i += take
        }
        return parts.filter { $0.count >= 2 }
    }

    struct CompiledQuery {
        var tokens: [String]
        var anyOf: [String]
        var kinds: [FileKind]?
        var ext: String?
        var allowsUnfilteredBrowse: Bool
        var numericTerms: [String] { tokens.compactMap(NumericSearch.term) }
        var isIdentifierQuery: Bool { !tokens.isEmpty && numericTerms.count == tokens.count && anyOf.isEmpty }
    }

    static func compile(_ raw: String) -> CompiledQuery {
        let trimmed = NumericSearch.normalized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return CompiledQuery(tokens: [], anyOf: [], kinds: nil, ext: nil, allowsUnfilteredBrowse: false)
        }

        var kinds: [FileKind]?
        var ext: String?
        var rest = trimmed

        let catImagePattern = #"猫图|猫咪图|小猫图|猫的图|猫图片|猫照片|cat\s+(image|photo|picture)|kitten\s+(image|photo|picture)"#
        if trimmed.range(of: catImagePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            kinds = [.image]
        } else if trimmed.range(of: #"照片|图片|photo|image"#, options: [.regularExpression, .caseInsensitive]) != nil {
            kinds = [.image]
        } else if trimmed.range(of: #"视频|影片|录像|短片|video|movie|mp4|mov"#, options: [.regularExpression, .caseInsensitive]) != nil {
            kinds = [.video]
        } else if trimmed.range(of: #"表格|报表|csv|excel|xlsx"#, options: [.regularExpression, .caseInsensitive]) != nil {
            kinds = [.spreadsheet]
        } else if trimmed.range(of: #"合同|文档|pdf|docx"#, options: [.regularExpression, .caseInsensitive]) != nil {
            kinds = [.document]
        }

        if let match = trimmed.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,4}\b"#, options: .regularExpression) {
            let candidate = String(trimmed[match]).dropFirst().lowercased()
            if ["pdf", "doc", "docx", "ppt", "pptx", "txt", "md", "rtf", "pages", "png", "jpg", "jpeg",
                "webp", "heic", "mp4", "mov", "m4v", "csv", "tsv", "xls", "xlsx"].contains(candidate) {
                ext = candidate
            }
        }

        rest = rest.replacingOccurrences(
            of: #"所有|全部|最近的|最近|找一下|搜一下|搜索|查找|打开|帮我|给我|看看|一下"#,
            with: " ",
            options: .regularExpression
        )
        rest = rest.replacingOccurrences(
            of: #"照片|图片|视频|影片|录像|短片|表格|报表|合同|文档|文件"#,
            with: " ",
            options: .regularExpression
        )
        rest = rest.replacingOccurrences(
            of: catImagePattern,
            with: "猫",
            options: [.regularExpression, .caseInsensitive]
        )
        rest = rest.replacingOccurrences(
            of: #"\b(photos?|images?|videos?|movies?|clips?|mp4|mov)\b"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let stop: Set<String> = [
            "搜", "找", "看", "的", "个", "些", "在", "file", "files",
            "photo", "photos", "image", "images", "video", "videos",
            "movie", "movies", "mp4", "mov",
            "很多", "好多", "非常", "地方", "那里", "哪里", "一下",
        ]
        var tokens = queryTokens(rest).filter { token in
            let searchableSingleCJK = token.count == 1 && token.first.map(isCJK) == true
            return (token.count >= 2 || searchableSingleCJK) && token != ext && !stop.contains(token)
        }
        var anyOf: [String] = []
        let compact = rest.filter { !$0.isWhitespace && !$0.isPunctuation }
        if compact.contains("水") || tokens.contains(where: { $0.contains("水") }) {
            anyOf.append(contentsOf: [
                "湖", "湖泊", "湖水", "湖边", "湖景", "水面", "水体",
                "海", "海边", "海滩", "海水", "海浪", "海洋", "海滨",
                "water", "lake", "ocean", "pier", "beach",
            ])
            tokens.removeAll { $0.contains("水") }
        }
        var seen = Set<String>()
        anyOf = anyOf.filter { seen.insert($0).inserted }
        let explicitBrowse = trimmed.range(
            of: #"所有|全部|最近"#, options: .regularExpression
        ) != nil
        let allowsUnfilteredBrowse = tokens.isEmpty && anyOf.isEmpty
            && (kinds != nil || ext != nil || explicitBrowse)
        return CompiledQuery(
            tokens: tokens, anyOf: anyOf, kinds: kinds, ext: ext,
            allowsUnfilteredBrowse: allowsUnfilteredBrowse
        )
    }

    private static func queryTokens(_ raw: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = raw
        var words: [String] = []
        tokenizer.enumerateTokens(in: raw.startIndex..<raw.endIndex) { range, _ in
            let word = String(raw[range]).lowercased()
            if word.contains(where: isCJK) && word.count >= 4 {
                words.append(contentsOf: cjkPieces(word))
            } else if !word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty {
                words.append(word)
            }
            return true
        }
        if words.isEmpty {
            words = raw.lowercased()
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .map(String.init)
        }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }
}
