import Foundation

/// 写了一半的诗、短稿：回收标记 + 和图一样的选项补全。原文不动。
enum TextReuse {
    static func shouldHandle(_ file: IndexedFile) -> Bool {
        guard ["md", "txt", "rtf"].contains(file.ext) else { return false }
        let name = file.name.lowercased()
        if name.contains("续写") || name.contains("未完") || name.contains("未写完")
            || name.contains("半成品")
            || name.range(of: #"(^|[^a-z])wip([^a-z]|$)"#, options: .regularExpression) != nil {
            return true
        }
        let state = file.completionState.lowercased()
        return ["unfinished", "incomplete"].contains(state)
            && file.completionConfidence >= 0.82
            && !file.completionEvidence.isEmpty
    }

    static func inspect(file: IndexedFile) async -> ImageAsk? {
        let body = DraftText.body(file)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            GroqClient.lastError = "这篇几乎是空的"
            return nil
        }
        let prompt = """
        你在做电子垃圾回收的再利用，不是搜索。这是一份可能写了一半的本地文稿（诗、词、短记、未完成的段落）。
        用一句中文说出这是什么。列出已经写好、补全时必须保留的原句。
        再给出恰好 4 个完整方向，每个方向同时说清语气和完成范围，必须针对这篇文字。
        四个方向要有明显差异。诗可以区分沿原语气续写、写得更克制、补成完整一首、只补停下的几行。
        只返回 JSON：
        {"diagnosis":"一句观察","anchors":"必须保留的原句，分号分隔","choices":[{"id":"A","title":"沿原语气，只补停下的几行"},{"id":"B","title":"沿原语气，补成完整一篇"},{"id":"C","title":"更克制地续写，保留原句"},{"id":"D","title":"更温暖地收束成完整版本"}]}
        文件名：\(file.name)
        正文：
        \(body)
        """
        guard let raw = await GroqClient.complete(
            system: "你给写了一半的文稿做补全前问诊。只输出 JSON。选项必须从原文长出来。",
            user: prompt,
            maxTokens: 700,
            json: true,
            temperature: 0.3,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return nil }
        GroqClient.log("text-ask \(raw.prefix(240))")
        CloudUpload.mark(file, purpose: "reuse.inspect")
        return ImageReuse.parseAsk(
            raw,
            file: file,
            fallbackDiagnosis: fallbackDiagnosis(for: file, body: body),
            fallbackAnchors: clip(body, 120),
            fallbackChoices: fallbackChoices(for: file, body: body)
        )
    }

    static func complete(
        file: IndexedFile,
        ask: ImageAsk,
        picks: [String: String],
        extra: String
    ) async -> URL? {
        let body = DraftText.body(file, limit: 8000)
        var chosen: [String] = []
        if let id = picks["direction"],
           let title = ask.choices.first(where: { $0.id == id })?.title {
            chosen.append("方向：\(title)")
        } else {
            chosen.append("方向：按原文最合理的方式补完")
        }
        let custom = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { chosen.append("其他：\(custom)") }
        let prompt = """
        把这份未完成的文稿补成可直接用的简体中文成品。不要另起一篇无关的新作。

        硬性要求：
        1. 已经写好的句子必须保留，原顺序、原措辞，不要改成说明书或标题党。
        2. 在原文停下的地方接着写，补上缺失的行或段。
        3. 若是诗，保持原有的行距、节奏和语气；不要改成散文分析。
        4. 不要解释你做了什么，不要加作者注。

        必须保留：\(ask.anchors.isEmpty ? "见原文所有已写内容" : ask.anchors)
        观察：\(ask.diagnosis)
        用户选择：
        \(chosen.joined(separator: "\n"))
        原文：
        \(body)
        只返回 JSON：{"filename":"短文件名，不要扩展名","markdown":"补全后的全文"}
        """
        guard let raw = await GroqClient.complete(
            system: "你把写了一半的文稿补完。只输出 JSON。",
            user: prompt,
            maxTokens: 3500,
            json: true,
            temperature: 0.4,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return nil }
        GroqClient.log("text-gen \(raw.prefix(220))")
        CloudUpload.mark(file, purpose: "reuse.complete")
        return write(raw, nextTo: file.path, ext: file.ext.isEmpty ? "md" : file.ext)
    }

    static func summarize(original: IndexedFile, result: String) async -> String {
        let before = (try? String(contentsOfFile: original.path, encoding: .utf8)) ?? ""
        let after = (try? String(contentsOfFile: result, encoding: .utf8)) ?? ""
        guard !before.isEmpty, !after.isEmpty else { return "" }
        let prompt = """
        第一段是原文，第二段是补全结果。对照写 2 到 4 句简体中文：留下了哪些原句、补了什么、语气有没有变。
        不要空话，不要提文件名。
        只返回 JSON：{"summary":"..."}
        原文：
        \(clip(before, 1800))
        补全：
        \(clip(after, 1800))
        """
        guard let raw = await GroqClient.complete(
            system: "你对照原文和补全结果写修改说明。只输出 JSON。",
            user: prompt,
            maxTokens: 280,
            json: true,
            temperature: 0.2,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return "" }
        GroqClient.log("text-summary \(raw.prefix(220))")
        CloudUpload.mark(original, purpose: "reuse.summarize")
        CloudUpload.mark(path: result, like: original, purpose: "reuse.summarize")
        let obj = jsonObject(raw)
        return ((obj?["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func write(_ raw: String, nextTo original: String, ext: String) -> URL? {
        let obj = jsonObject(raw)
        let markdown = ((obj?["markdown"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var filename = ((obj?["filename"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty {
            GroqClient.lastError = "没有写出正文"
            return nil
        }
        let src = URL(fileURLWithPath: original)
        if filename.isEmpty {
            filename = src.deletingPathExtension().lastPathComponent + " 补全"
        }
        filename = sanitize(filename)
        if (filename as NSString).pathExtension.lowercased() != ext {
            filename = ((filename as NSString).deletingPathExtension as String) + ".\(ext)"
        }
        let dir = src.deletingLastPathComponent()
        var dest = dir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = uniqueURL(dest)
        }
        do {
            try markdown.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        } catch {
            GroqClient.lastError = "无法保存新稿"
            return nil
        }
    }

    private static func fallbackDiagnosis(for file: IndexedFile, body: String) -> String {
        if file.name.contains("诗") || DraftText.looksLikeVerse(body) {
            return "这是一首还没写完的诗。"
        }
        return "这是一份写了一半的稿，还能补完。"
    }

    private static func fallbackChoices(for file: IndexedFile, body: String) -> [ImageAskChoice] {
        let verse = file.name.contains("诗") || DraftText.looksLikeVerse(body)
        return [
            ImageAskChoice(id: "A", title: verse ? "沿原语气，只补未写完的几行" : "沿原语气，只补没写完的部分"),
            ImageAskChoice(id: "B", title: verse ? "保留原句，补成完整一首" : "保留原句，整理成完整一篇"),
            ImageAskChoice(id: "C", title: "写得更克制，保持原有节奏"),
            ImageAskChoice(id: "D", title: "写得更温暖，收束成完整版本"),
        ]
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let first = text.range(of: "\n") {
                text = String(text[first.upperBound...])
            }
            if let end = text.range(of: "```", options: .backwards), end.lowerBound > text.startIndex {
                text = String(text[..<end.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            let slice = String(text[start...end])
            if let data = slice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        base = base.components(separatedBy: invalid).joined(separator: "")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "补全.txt" : base
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 2...30 {
            let candidate = dir.appendingPathComponent("\(stem) \(i).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem) 新.\(ext)")
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}

enum DraftText {
    static func reason(for file: IndexedFile) -> String? {
        guard ["md", "txt", "rtf"].contains(file.ext) else { return nil }
        let name = file.name.lowercased()
        if name.contains("合同") || name.contains("清单") || name.contains("计划") { return nil }
        if name.contains("诗") || name.contains("词") { return "像没写完的诗" }
        let body = self.body(file)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeVerse(trimmed) { return "像写了一半的诗" }
        if file.size > 0, file.size < 280 { return "正文过短，像写了一半" }
        if looksUnfinishedProse(trimmed) { return "写到一半就停了" }
        return nil
    }

    static func body(_ file: IndexedFile, limit: Int = 4000) -> String {
        let raw = (try? String(contentsOfFile: file.path, encoding: .utf8))
            ?? (try? String(contentsOfFile: file.path, encoding: .isoLatin1))
            ?? file.preview
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= limit { return t }
        return String(t.prefix(limit)) + "…"
    }

    static func looksLikeVerse(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, lines.count <= 24 else { return false }
        let listed = lines.filter {
            $0.hasPrefix("-") || $0.hasPrefix("*") || $0.hasPrefix("#") || $0.contains("：") || $0.contains(":")
        }
        if listed.count * 2 >= lines.count { return false }
        let avg = lines.map(\.count).reduce(0, +) / max(lines.count, 1)
        guard avg <= 22 else { return false }
        let last = lines.last ?? ""
        let ended = last.hasSuffix("。") || last.hasSuffix("！") || last.hasSuffix("？")
            || last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")
        return !ended
    }

    private static func looksUnfinishedProse(_ text: String) -> Bool {
        guard text.count >= 12, text.count <= 400 else { return false }
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = last.hasSuffix("。") || last.hasSuffix("！") || last.hasSuffix("？")
            || last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")
        return !ended
    }
}
