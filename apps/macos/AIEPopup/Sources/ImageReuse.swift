import AppKit
import Foundation

struct ImageAskChoice: Identifiable, Equatable {
    let id: String
    let title: String
}

struct ImageAsk: Equatable {
    let path: String
    let name: String
    let diagnosis: String
    let anchors: String
    let choices: [ImageAskChoice]
}

/// 图的再利用：先看缺什么、问用户，再图生图补全。原文不动。
enum ImageReuse {
    static func inspect(file: IndexedFile) async -> ImageAsk? {
        let jpegs = jpeg(from: file.path, maxEdge: 1024, quality: 0.72)
        guard !jpegs.isEmpty else {
            GroqClient.lastError = "读不到这张图"
            return nil
        }
        let canvas = CanvasProbe.inspect(path: file.path)
        var extra = ""
        if let canvas {
            extra = "本机像素：着墨 \(Int(canvas.inkRatio * 100))%，纸面 \(Int(canvas.paperRatio * 100))%"
            if canvas.mostlyBlank { extra += "，几乎空白" }
            if canvas.sparse { extra += "，内容挤在一角" }
            if canvas.sketchy { extra += "，像线稿" }
            if !canvas.layout.isEmpty { extra += "，\(canvas.layout)" }
        }
        let prompt = """
        你在做电子垃圾回收的再利用，不是搜索。先看图，用一句中文说出这是什么（主体要具体，比如猫素描、没画完的山）。
        列出画面上已经存在、补全时必须用上的笔划/字（位置+是什么）。
        再给出恰好 4 个完整方向，每个方向同时说清质感和完成范围，必须针对这张图，不要「画/照片/字」这种空话。
        四个方向要有明显差异；猫可以区分保留铅笔、轻轻上色、整理线条、完成整幅，山可以区分留白和把线稿画完。
        只返回 JSON：
        {"diagnosis":"一句观察","anchors":"已有笔划，分号分隔","choices":[{"id":"A","title":"保留铅笔质感，只补缺失线条"},{"id":"B","title":"轻轻上色，按原构图画完"},{"id":"C","title":"清理线条，保持黑白素描"},{"id":"D","title":"保留主体，完成背景与细节"}]}
        文件名：\(file.name)
        \(extra)
        摘要：\(file.llmCard)
        """
        guard let raw = await GroqClient.complete(
            system: "你给半成品图做补全前问诊。只输出 JSON。选项必须从画面长出来。",
            user: prompt,
            imageJPEGs: jpegs,
            maxTokens: 700,
            json: true,
            temperature: 0.3,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return nil }
        GroqClient.log("image-ask \(raw.prefix(240))")
        CloudUpload.mark(file, purpose: "reuse.inspect")
        return parseAsk(
            raw,
            file: file,
            fallbackDiagnosis: fallbackDiagnosis(for: file),
            fallbackAnchors: CanvasProbe.inspect(path: file.path)?.layout ?? "",
            fallbackChoices: fallbackChoices(for: file)
        )
    }

    static func complete(
        file: IndexedFile,
        ask: ImageAsk,
        picks: [String: String],
        extra: String
    ) async -> URL? {
        let refs = jpeg(from: file.path, maxEdge: 1600, quality: 0.92)
        guard let ref = refs.first else {
            GroqClient.lastError = "读不到这张图"
            return nil
        }
        var chosen: [String] = []
        if let id = picks["direction"],
           let title = ask.choices.first(where: { $0.id == id })?.title {
            chosen.append("方向：\(title)")
        } else {
            chosen.append("方向：按画面最合理的方式处理")
        }
        let custom = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { chosen.append("其他：\(custom)") }
        let canvas = CanvasProbe.inspect(path: file.path)
        let layout = canvas?.layout ?? ""
        let prompt = """
        这是图生图编辑，不是按文字新画一张。输出必须是同一张画布的完成版。

        硬性要求：
        1. 已有的每一笔、每一个字都必须用上，留在原位置，沿原笔划生长成成品。禁止把原线稿空悬在画面上当废线。
        2. 禁止在空白处另起一套新构图（例如原线在上方，却在下方新画一幅山水）。空白只能由原笔划延伸过去，或按用户明确要求留白。
        3. 不要水印、不要边框、不要把原图缩小镶嵌进新图。
        4. 原有的字保持原位置和笔迹；若要续写，接在原字后面，不要改成印刷体标题。

        已有笔划（必须用上）：\(ask.anchors.isEmpty ? "见参考图上所有已画内容" : ask.anchors)
        \(layout.isEmpty ? "" : "构图：\(layout)")
        观察：\(ask.diagnosis)
        用户选择：
        \(chosen.joined(separator: "\n"))
        """
        let aspect = aspectRatio(of: file.path)
        guard let image = await GroqClient.generateImage(
            prompt: prompt,
            referenceJPEG: ref,
            aspectRatio: aspect
        ) else { return nil }
        CloudUpload.mark(file, purpose: "reuse.complete")
        return write(image.data, ext: image.ext, nextTo: file.path)
    }

    static func summarize(original: IndexedFile, result: String) async -> String {
        let before = jpeg(from: original.path, maxEdge: 900, quality: 0.7)
        let after = jpeg(from: result, maxEdge: 900, quality: 0.7)
        guard !before.isEmpty, !after.isEmpty else { return "" }
        let prompt = """
        第一张是原文，第二张是补全结果。对照着写 2 到 4 句简体中文：留下了什么、补了什么、风格有没有变。
        只说画面里看得到的变化，不要空话，不要提文件名。
        只返回 JSON：{"summary":"..."}
        """
        guard let raw = await GroqClient.complete(
            system: "你对照原图和补全结果写修改说明。只输出 JSON。",
            user: prompt,
            imageJPEGs: before + after,
            maxTokens: 280,
            json: true,
            temperature: 0.2,
            slow: true,
            model: GroqClient.reuseModel,
            pinGroq: false,
            allowFallback: true,
            fallbacks: GroqClient.reuseFallbacks
        )         else { return "" }
        GroqClient.log("image-summary \(raw.prefix(220))")
        CloudUpload.mark(original, purpose: "reuse.summarize")
        CloudUpload.mark(path: result, like: original, purpose: "reuse.summarize")
        let obj = jsonObject(raw)
        return ((obj?["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func revise(file: IndexedFile, currentPath: String, instruction: String) async -> URL? {
        guard let reference = jpeg(from: currentPath, maxEdge: 1600, quality: 0.92).first else {
            GroqClient.lastError = "读不到当前版本"
            return nil
        }
        let request = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }
        let prompt = """
        这是对当前版本的图生图编辑。严格执行用户要求，并保留用户没有要求改变的主体、构图、文字和画布比例。
        不要另起一幅图，不要加水印或边框。
        用户要求：\(request)
        """
        guard let image = await GroqClient.generateImage(
            prompt: prompt,
            referenceJPEG: reference,
            aspectRatio: aspectRatio(of: currentPath)
        ) else { return nil }
        CloudUpload.mark(file, purpose: "reuse.revise")
        CloudUpload.mark(path: currentPath, like: file, purpose: "reuse.revise")
        return write(image.data, ext: image.ext, nextTo: currentPath)
    }

    static func parseAsk(
        _ raw: String,
        file: IndexedFile,
        fallbackDiagnosis: String,
        fallbackAnchors: String,
        fallbackChoices: [ImageAskChoice]
    ) -> ImageAsk {
        let obj = jsonObject(raw)
        var diagnosis = ((obj?["diagnosis"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let anchors = ((obj?["anchors"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var choices: [ImageAskChoice] = []
        if let rows = obj?["choices"] as? [[String: Any]] {
            for row in rows {
                let title = ((row["title"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let id = ((row["id"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard ["A", "B", "C", "D"].contains(id), !title.isEmpty else { continue }
                if !choices.contains(where: { $0.id == id }) {
                    choices.append(ImageAskChoice(id: id, title: clip(title, 30)))
                }
            }
        }
        choices.sort { $0.id < $1.id }
        if choices.count < 4 {
            choices = fallbackChoices
        }
        if diagnosis.isEmpty {
            diagnosis = fallbackDiagnosis
        }
        return ImageAsk(
            path: file.path,
            name: file.name,
            diagnosis: clip(diagnosis, 160),
            anchors: anchors.isEmpty ? fallbackAnchors : clip(anchors, 160),
            choices: Array(choices.prefix(4))
        )
    }

    private static func fallbackDiagnosis(for file: IndexedFile) -> String {
        if let stats = CanvasProbe.inspect(path: file.path) {
            if stats.mostlyBlank { return "这是一张几乎空白的画，还能补成成品。" }
            if stats.sketchy { return "这是一张线稿，还不像成品。" }
            if !stats.layout.isEmpty { return "这张图\(stats.layout)，还能补全。" }
        }
        return "这张图还能补成一份能用的成品。"
    }

    private static func fallbackChoices(for file: IndexedFile) -> [ImageAskChoice] {
        let pencil = CanvasProbe.inspect(path: file.path)?.sketchy == true
        return [
            ImageAskChoice(id: "A", title: pencil ? "保留铅笔质感，只补缺失线条" : "保留现有笔触，只补缺失部分"),
            ImageAskChoice(id: "B", title: "轻轻上色，按原构图完成"),
            ImageAskChoice(id: "C", title: "清理线条，保持简洁留白"),
            ImageAskChoice(id: "D", title: "保留主体，补足背景与细节"),
        ]
    }

    private static func write(_ data: Data, ext: String, nextTo original: String) -> URL? {
        let src = URL(fileURLWithPath: original)
        let stem = src.deletingPathExtension().lastPathComponent
        let dir = src.deletingLastPathComponent()
        var dest = dir.appendingPathComponent("\(stem) 补全.\(ext)")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = uniqueURL(dest)
        }
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            GroqClient.lastError = "无法保存新图"
            return nil
        }
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

    private static func jpeg(from path: String, maxEdge: CGFloat, quality: CGFloat) -> [Data] {
        guard let ns = NSImage(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        var rect = NSRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        let scaled = downscale(cg, maxEdge: maxEdge)
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return []
        }
        return [data]
    }

    private static func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let edge = max(w, h)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        let nw = max(Int(w * scale), 1)
        let nh = max(Int(h * scale), 1)
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    private static func aspectRatio(of path: String) -> String {
        guard let ns = NSImage(contentsOf: URL(fileURLWithPath: path)), ns.size.height > 0 else {
            return "1:1"
        }
        let r = ns.size.width / ns.size.height
        if abs(r - 1) < 0.08 { return "1:1" }
        if r >= 1.7 { return "16:9" }
        if r >= 1.2 { return "4:3" }
        if r <= 0.6 { return "9:16" }
        if r <= 0.85 { return "3:4" }
        return "1:1"
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

    private static func clip(_ text: String, _ max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= max { return t }
        return String(t.prefix(max)) + "…"
    }
}
