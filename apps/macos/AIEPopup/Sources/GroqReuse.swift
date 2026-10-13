import Foundation
import PDFKit

struct ReuseOption: Identifiable, Equatable {
    let id: String
    let title: String
}

struct ReuseProposal: Equatable {
    let path: String
    let name: String
    let brief: String
    let options: [ReuseOption]
}

struct ReuseDraft: Equatable {
    let filename: String
    let markdown: String
    let assets: [(name: String, data: Data)]
    let slides: [ReuseSlide]

    static func == (lhs: ReuseDraft, rhs: ReuseDraft) -> Bool {
        lhs.filename == rhs.filename && lhs.markdown == rhs.markdown
            && lhs.assets.map(\.name) == rhs.assets.map(\.name) && lhs.slides == rhs.slides
    }
}

enum ReusePhase: Equatable {
    case idle
    case proposing
    case choose(ReuseProposal)
    case ask(ImageAsk)
    case writing(String)
    case done(name: String, path: String)
    case failed(String)

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }

    var progress: Double {
        switch self {
        case .idle, .failed: return 0
        case .proposing: return 0.18
        case .ask, .choose: return 0.36
        case .writing: return 0.68
        case .done: return 1
        }
    }

    var stageLabel: String {
        switch self {
        case .idle: return ""
        case .proposing: return "正在看这份材料…"
        case .ask: return "选一个方向"
        case .choose: return "选一个方向"
        case .writing(let title):
            return title.hasPrefix("补全") ? "正在补全，这一步会比较久" : "正在写：\(title)"
        case .done: return "完成"
        case .failed(let message): return message
        }
    }
}

enum GroqReuse {
    static let other = ReuseOption(id: "custom", title: "自定义")

    static func propose(file: IndexedFile) async -> ReuseProposal? {
        let material = material(for: file)
        let lowerName = file.name.lowercased()
        let namedIncomplete = ["未完成", "未写完", "没画完", "半成品", "续写"]
            .contains(where: lowerName.contains)
            || lowerName.range(of: #"(^|[^a-z])wip([^a-z]|$)"#, options: .regularExpression) != nil
        let incomplete = namedIncomplete
            || (["unfinished", "incomplete"].contains(file.completionState.lowercased())
                && file.completionConfidence >= 0.82 && !file.completionEvidence.isEmpty)
        let task = incomplete
            ? "这份内容已确认不完整。三个方向都要补上缺失部分，但在完成度、语气或呈现方式上给出具体选择。缺失线索：\(file.missingParts.joined(separator: "；"))。判断证据：\(file.completionEvidence.joined(separator: "；"))。"
            : "这份内容更适合优化或再创作。给出三个保留原始事实、方向不同的打磨方案；不要把它说成未完成。"
        let prompt = """
        用户想再利用这份本地文件，而不是丢掉。
        \(task)
        根据材料给出恰好 4 个具体、互不相同、马上能动手的改写方向。
        每个 title 是一句中文，不超过 22 字，说清楚「做成什么」，不要空话。
        brief 用一句话说明这是什么。
        只返回 JSON：{"brief":"...","options":[{"id":"A","title":"..."},{"id":"B","title":"..."},{"id":"C","title":"..."},{"id":"D","title":"..."}]}
        材料：
        \(material)
        """
        guard let raw = await GroqClient.complete(
            system: "你给本地文件提供再利用方向。只输出 JSON。",
            user: prompt,
            maxTokens: 420,
            json: true,
            temperature: 0.4,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return nil }
        GroqClient.log("reuse-propose \(raw.prefix(240))")
        CloudUpload.mark(file, purpose: "reuse.propose")
        let parsed = parseProposal(raw, file: file)
        return parsed
    }

    static func generate(file: IndexedFile, option: ReuseOption, other: String) async -> ReuseDraft? {
        let direction: String
        if option.id == "custom" {
            let custom = other.trimmingCharacters(in: .whitespacesAndNewlines)
            direction = custom.isEmpty ? "按材料整理成一份可直接用的新稿" : custom
        } else {
            direction = option.title
        }
        let material = material(for: file)
        let visual = wantsVisual(direction)
        let asPDF = wantsPDF(file: file, direction: direction)
        let asPPTX = ["ppt", "pptx"].contains(file.ext)
        let formatInstruction = asPPTX
            ? "输出可编辑 PPTX 的页面结构。slides 每项是一页，title 是页标题，bullets 是本页要点；建议 4 到 12 页。markdown 同时给出完整文字备份。"
            : "正文用 Markdown 结构即可。程序会\(asPDF ? "直接生成 PDF，并把图嵌进文件" : "按原格式导出")。"
        let prompt = """
        按用户选定的方向，基于原材料写一份可直接交付的简体中文稿。
        数字只能来自材料，禁止编造，禁止使用 http/https 图片链接，禁止 example.com。
        \(visual ? "这是可视化方向：必须从材料抽出 2 到 4 组真实数据做成 charts。正文里用 {{chart:id}} 标明图放在哪。" : "若材料里有可比较的数字，也可以给 charts，并用 {{chart:id}} 占位；没有数字就不要编图。")
        \(formatInstruction) 不要自己指定 html、pdf 或外链图；filename 只写短名，不要带扩展名。
        只返回 JSON：
        {"filename":"短文件名","markdown":"正文，可用 {{chart:id}}","slides":[{"title":"页标题","bullets":["要点一","要点二"]}],"charts":[{"id":"market","title":"标题","kind":"bar|line|stat","unit":"单位","items":[{"label":"2025","value":420}]}]}
        方向：\(direction)
        材料：
        \(material)
        """
        guard let raw = await GroqClient.complete(
            system: "你把本地材料改写成新版本。图表只输出数据，不输出假图片。只输出 JSON。",
            user: prompt,
            maxTokens: 8000,
            json: true,
            temperature: 0.25,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return nil }
        GroqClient.log("reuse-gen \(raw.prefix(220))")
        CloudUpload.mark(file, purpose: "reuse.generate")
        return assembleDraft(raw, file: file, option: option, direction: direction)
    }

    static func revise(file: IndexedFile, currentPath: String, instruction: String) async -> ReuseDraft? {
        let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }
        let current = extractBody(path: currentPath)
        let isPPTX = ["ppt", "pptx"].contains(file.ext)
        let format = isPPTX
            ? "slides 必须给出修改后的完整可编辑幻灯片结构，每页包含 title 和 bullets。"
            : "markdown 必须给出修改后的完整版本，不要只返回改动片段。"
        let prompt = """
        用户正在对咔哒生成的新版本继续修改。以当前版本为基准执行要求，同时用原材料核对事实。
        不得编造原材料里没有的数字或事实。\(format)
        filename 只写短文件名，不带扩展名。
        只返回 JSON：
        {"filename":"短文件名","markdown":"修改后的完整正文","slides":[{"title":"页标题","bullets":["要点"]}],"charts":[]}
        用户要求：\(request)
        原材料：
        \(material(for: file))
        当前版本：
        \(String(current.prefix(18000)))
        """
        guard let raw = await GroqClient.complete(
            system: "你根据用户反馈继续修改已生成的文件。只输出 JSON。",
            user: prompt,
            maxTokens: 8000,
            json: true,
            temperature: 0.22,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        ) else { return nil }
        CloudUpload.mark(file, purpose: "reuse.revise")
        CloudUpload.mark(path: currentPath, like: file, purpose: "reuse.revise")
        return assembleDraft(
            raw,
            file: file,
            option: ReuseOption(id: "R", title: "继续修改"),
            direction: request
        )
    }

    static func write(_ draft: ReuseDraft, nextTo originalPath: String) -> String? {
        let dir = URL(fileURLWithPath: originalPath).deletingLastPathComponent()
        let safe = sanitize(draft.filename)
        var dest = dir.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = uniqueURL(dest)
        }
        let oldStem = (draft.filename as NSString).deletingPathExtension
        let newStem = dest.deletingPathExtension().lastPathComponent
        var markdown = draft.markdown
        var assets: [(name: String, data: Data)] = []
        for asset in draft.assets {
            let name = asset.name.replacingOccurrences(of: oldStem, with: newStem)
            markdown = markdown.replacingOccurrences(of: asset.name, with: name)
            assets.append((name: name, data: asset.data))
        }
        do {
            if dest.pathExtension.lowercased() == "pdf" {
                let images = Dictionary(uniqueKeysWithValues: assets.map { ($0.name, $0.data) })
                guard let pdf = ReusePDF.render(markdown: markdown, images: images) else {
                    GroqClient.lastError = "无法生成 PDF"
                    return nil
                }
                try pdf.write(to: dest, options: .atomic)
                return dest.path
            }
            if dest.pathExtension.lowercased() == "pptx" {
                guard ReusePPTX.render(slides: draft.slides, fallbackMarkdown: markdown, to: dest) else {
                    GroqClient.lastError = "无法生成可编辑 PPTX"
                    return nil
                }
                return dest.path
            }
            for asset in assets {
                try asset.data.write(to: dir.appendingPathComponent(asset.name), options: .atomic)
            }
            try markdown.write(to: dest, atomically: true, encoding: .utf8)
            return dest.path
        } catch {
            GroqClient.lastError = "无法写入新文件"
            return nil
        }
    }

    private static func material(for file: IndexedFile) -> String {
        var parts = [
            "文件名：\(file.name)",
            "路径：\(file.relative)",
            "类型：\(file.kind.rawValue)",
        ]
        if !file.llmCard.isEmpty { parts.append("摘要：\(file.llmCard)") }
        let body = extractBody(file)
        if !body.isEmpty { parts.append("正文摘录：\n\(body)") }
        return parts.joined(separator: "\n")
    }

    private static func extractBody(_ file: IndexedFile) -> String {
        let ext = file.ext
        let raw: String
        if ["md", "txt", "csv", "tsv", "json", "rtf"].contains(ext) {
            raw = (try? String(contentsOfFile: file.path, encoding: .utf8))
                ?? (try? String(contentsOfFile: file.path, encoding: .isoLatin1))
                ?? file.preview
        } else if ext == "pdf" {
            raw = pdfText(file.path)
        } else if ["ppt", "pptx"].contains(ext) {
            raw = PresentationReader.read(path: file.path)?.text ?? file.preview
        } else {
            raw = file.preview
        }
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 16000 { return compact }
        return String(compact.prefix(16000)) + "…"
    }

    private static func extractBody(path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "pdf" { return pdfText(path) }
        if ["ppt", "pptx"].contains(ext) {
            return PresentationReader.read(path: path)?.text ?? ""
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
            ?? ""
    }

    private static func pdfText(_ path: String) -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return "" }
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 16) {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                pages.append(text)
            }
        }
        return pages.joined(separator: "\n")
    }

    private static func parseProposal(_ raw: String, file: IndexedFile) -> ReuseProposal {
        let obj = jsonObject(raw)
        let brief = ((obj?["brief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [ReuseOption] = []
        if let arr = obj?["options"] as? [[String: Any]] {
            for item in arr {
                let id = ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = ((item["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard ["A", "B", "C", "D"].contains(id), !title.isEmpty else { continue }
                if !options.contains(where: { $0.id == id }) {
                    options.append(ReuseOption(id: id, title: clip(title, 28)))
                }
            }
        }
        options.sort { $0.id < $1.id }
        if options.count < 4 {
            options = fallbackOptions(for: file)
        }
        return ReuseProposal(
            path: file.path,
            name: file.name,
            brief: brief.isEmpty ? "可以把它做成一份新稿。" : clip(brief, 60),
            options: Array(options.prefix(4))
        )
    }

    private static func fallbackOptions(for file: IndexedFile) -> [ReuseOption] {
        switch file.kind {
        case .document, .spreadsheet:
            return [
                ReuseOption(id: "A", title: "沿关键发现做下一轮调查提纲"),
                ReuseOption(id: "B", title: "改写成一页决策备忘"),
                ReuseOption(id: "C", title: "抽出可给别人用的要点稿"),
                ReuseOption(id: "D", title: "整理成图文并茂的汇报版本"),
            ]
        case .image, .video:
            return [
                ReuseOption(id: "A", title: "写成可检索的画面说明"),
                ReuseOption(id: "B", title: "改成拍摄/素材备注"),
                ReuseOption(id: "C", title: "整理成一组可用标签"),
                ReuseOption(id: "D", title: "做成一页视觉灵感板"),
            ]
        default:
            return [
                ReuseOption(id: "A", title: "整理成结构清楚的新稿"),
                ReuseOption(id: "B", title: "抽出可执行的下一步"),
                ReuseOption(id: "C", title: "改成更短的摘要版"),
                ReuseOption(id: "D", title: "扩写成可以直接分享的版本"),
            ]
        }
    }

    private static func assembleDraft(
        _ raw: String,
        file: IndexedFile,
        option: ReuseOption,
        direction: String
    ) -> ReuseDraft {
        let obj = jsonObject(raw)
        var filename = ((obj?["filename"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var markdown = ((obj?["markdown"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty {
            let old = parsePlainDraft(raw, file: file, option: option)
            if !looksLikeJSON(old.markdown) {
                filename = old.filename
                markdown = old.markdown
            }
        }
        markdown = stripFakeImages(markdown)
        if filename.isEmpty {
            let stem = (file.name as NSString).deletingPathExtension
            filename = "\(stem) \(option.id)"
        }
        filename = sanitize(filename)
        let ext = outputExt(for: file, direction: direction)
        if (filename as NSString).pathExtension.lowercased() != ext {
            filename = ((filename as NSString).deletingPathExtension as String) + ".\(ext)"
        }
        filename = sanitize(filename)
        let stem = (filename as NSString).deletingPathExtension
        var specs = parseCharts(obj?["charts"])
        if specs.isEmpty, wantsVisual(direction) {
            specs = fallbackCharts(from: material(for: file))
        }
        var assets: [(name: String, data: Data)] = []
        for spec in specs {
            guard let png = ReuseCharts.render(spec) else { continue }
            let name = "\(stem)-\(safeToken(spec.id)).png"
            assets.append((name: name, data: png))
            let token = "{{chart:\(spec.id)}}"
            let image = "![\(spec.title)](\(name))"
            if markdown.contains(token) {
                markdown = markdown.replacingOccurrences(of: token, with: image)
            } else if markdown.contains("## \(spec.title)") {
                markdown = markdown.replacingOccurrences(of: "## \(spec.title)", with: "## \(spec.title)\n\n\(image)")
            } else {
                markdown += "\n\n### \(spec.title)\n\n\(image)\n"
            }
        }
        markdown = markdown.replacingOccurrences(
            of: #"\{\{chart:[^}]+\}\}"#,
            with: "",
            options: .regularExpression
        )
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdown = "# \(option.title)\n\n（没有生成出正文）\n"
        }
        let slides = parseSlides(obj?["slides"])
        return ReuseDraft(filename: filename, markdown: markdown, assets: assets, slides: slides)
    }

    private static func outputExt(for file: IndexedFile, direction: String) -> String {
        if ["ppt", "pptx"].contains(file.ext) { return "pptx" }
        if wantsPDF(file: file, direction: direction) { return "pdf" }
        switch file.ext {
        case "md", "txt", "csv", "tsv": return file.ext
        default:
            return file.kind == .document ? "pdf" : "md"
        }
    }

    private static func wantsPDF(file: IndexedFile, direction: String) -> Bool {
        if wantsVisual(direction) { return true }
        switch file.ext {
        case "pdf", "doc", "docx", "pages", "rtf":
            return true
        default:
            return false
        }
    }

    private static func parsePlainDraft(_ raw: String, file: IndexedFile, option: ReuseOption) -> (filename: String, markdown: String) {
        var text = stripFence(raw)
        var filename = ""
        if let line = text.split(whereSeparator: \.isNewline).first {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.uppercased().hasPrefix("FILE:") {
                filename = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let range = text.range(of: "\n") {
                    text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return (filename, text)
    }

    private static func parseCharts(_ raw: Any?) -> [ReuseChartSpec] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [ReuseChartSpec] = []
        for item in arr {
            let id = ((item["id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = ((item["title"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !title.isEmpty else { continue }
            let kind = ReuseChartSpec.Kind(rawValue: ((item["kind"] as? String) ?? "bar").lowercased()) ?? .bar
            let unit = ((item["unit"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var points: [(String, Double)] = []
            if let rows = item["items"] as? [[String: Any]] {
                for row in rows {
                    let label = ((row["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let value: Double?
                    if let n = row["value"] as? Double { value = n }
                    else if let n = row["value"] as? Int { value = Double(n) }
                    else if let n = row["value"] as? NSNumber { value = n.doubleValue }
                    else if let s = row["value"] as? String { value = Double(s) }
                    else { value = nil }
                    guard !label.isEmpty, let value, value.isFinite else { continue }
                    points.append((label, value))
                }
            }
            guard !points.isEmpty else { continue }
            out.append(ReuseChartSpec(id: id, title: title, kind: kind, unit: unit, items: points))
        }
        return Array(out.prefix(4))
    }

    private static func parseSlides(_ raw: Any?) -> [ReuseSlide] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        var slides: [ReuseSlide] = []
        for row in rows.prefix(40) {
            let title = ((row["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bullets = (row["bullets"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { String($0.prefix(260)) }
            guard !title.isEmpty || !bullets.isEmpty else { continue }
            slides.append(ReuseSlide(title: clip(title.isEmpty ? "内容" : title, 80), bullets: Array(bullets.prefix(8))))
        }
        return slides
    }

    private static func fallbackCharts(from material: String) -> [ReuseChartSpec] {
        var found: [(String, Double)] = []
        let regex = try? NSRegularExpression(pattern: #"([^\n。；;]{2,18}?)(\d+(?:\.\d+)?)\s*(亿|万|%|％)?"#)
        let ns = material as NSString
        let matches = regex?.matches(in: material, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches.prefix(12) {
            guard m.numberOfRanges >= 3 else { continue }
            let label = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let num = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var unit = ""
            if m.numberOfRanges >= 4, m.range(at: 3).location != NSNotFound {
                unit = ns.substring(with: m.range(at: 3))
            }
            guard num > 0, !label.isEmpty else { continue }
            found.append(("\(clip(label, 12))\(unit.isEmpty ? "" : unit)", num))
        }
        guard found.count >= 2 else { return [] }
        return [
            ReuseChartSpec(
                id: "key-numbers",
                title: "关键数字",
                kind: found.count <= 3 ? .stat : .bar,
                unit: "",
                items: Array(found.prefix(4))
            )
        ]
    }

    private static func wantsVisual(_ direction: String) -> Bool {
        let d = direction.lowercased()
        let keys = [
            "可视", "图表", "图示", "看板", "chart", "dashboard",
            "一页纸", "数据卡片", "幻灯",
        ]
        return keys.contains { d.contains($0) }
    }

    private static func stripFakeImages(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\(\s*https?://[^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"https?://example\.com[^\s)]*"#,
            with: "",
            options: .regularExpression
        )
        return text
    }

    private static func safeToken(_ raw: String) -> String {
        let trimmed = raw.lowercased().replacingOccurrences(
            of: #"[^a-z0-9\u4e00-\u9fff]+"#,
            with: "-",
            options: .regularExpression
        )
        return trimmed.isEmpty ? "chart" : trimmed
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        let text = stripFence(raw)
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
        return salvageJSON(text)
    }

    private static func salvageJSON(_ text: String) -> [String: Any]? {
        var out: [String: Any] = [:]
        if let filename = jsonStringField(text, key: "filename") { out["filename"] = filename }
        if let markdown = jsonStringField(text, key: "markdown") { out["markdown"] = markdown }
        if let charts = jsonArrayField(text, key: "charts") { out["charts"] = charts }
        if let slides = jsonArrayField(text, key: "slides") { out["slides"] = slides }
        return out.isEmpty ? nil : out
    }

    private static func jsonStringField(_ text: String, key: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var idx = keyRange.upperBound
        func skipWS() {
            while idx < text.endIndex, text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
        }
        skipWS()
        guard idx < text.endIndex, text[idx] == ":" else { return nil }
        idx = text.index(after: idx)
        skipWS()
        guard idx < text.endIndex, text[idx] == "\"" else { return nil }
        idx = text.index(after: idx)
        var out = ""
        var escaped = false
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
            idx = text.index(after: idx)
        }
        return out.isEmpty ? nil : out
    }

    private static func jsonArrayField(_ text: String, key: String) -> [[String: Any]]? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var idx = keyRange.upperBound
        while idx < text.endIndex, text[idx].isWhitespace || text[idx] == ":" {
            idx = text.index(after: idx)
        }
        guard idx < text.endIndex, text[idx] == "[" else { return nil }
        let start = idx
        var depth = 0
        var inString = false
        var escaped = false
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 {
                        let slice = String(text[start...idx])
                        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [[String: Any]]
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && (t.contains("\"markdown\"") || t.contains("\"filename\""))
    }

    private static func stripFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let first = text.range(of: "\n") {
                text = String(text[first.upperBound...])
            } else if let brace = text.firstIndex(of: "{") {
                text = String(text[brace...])
            }
            if let end = text.range(of: "```", options: .backwards), end.lowerBound > text.startIndex {
                text = String(text[..<end.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func sanitize(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        base = base.components(separatedBy: invalid).joined(separator: "")
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return "再利用.md" }
        return base
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 2...30 {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(ext.isEmpty ? "\(stem) 新" : "\(stem) 新.\(ext)")
    }

    private static func clip(_ text: String, _ max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
