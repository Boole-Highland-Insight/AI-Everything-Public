import AppKit
import Foundation

/// 便宜像素信号：空白画布、线稿、构图缺一块。给回收「未完成」用，不进 search 热路径。
enum CanvasProbe {
    struct Stats {
        let inkRatio: Double
        let paperRatio: Double
        let chroma: Double
        let edgeRatio: Double
        let mostlyBlank: Bool
        let sparse: Bool
        let sketchy: Bool
        /// 例如「着墨在上方，下方大片空白」
        let layout: String
    }

    static func draftReason(for file: IndexedFile) -> String? {
        guard file.kind == .image else { return nil }
        if file.hasBarcode || file.isScreenshot { return nil }
        if looksPrinted(file) { return nil }
        let name = file.name.lowercased()
        if name.contains("未完成") || name.contains("没画完") { return "文件名写了未完成" }
        if name.contains("半成品") { return "文件名是半成品" }
        if name.contains("草稿") || name.contains("速写") || name.contains("草图") { return "像未完成的画" }
        if name.contains("线稿") || name.contains("wip") || name.contains("sketch") {
            return "文件名像草稿图"
        }
        guard let stats = inspect(path: file.path) else { return nil }
        if stats.mostlyBlank { return "画布几乎是空的，像没画完" }
        if stats.sparse { return "只有几笔，像半成品画" }
        if !stats.layout.isEmpty, stats.sketchy {
            return stats.layout + "，像没画完"
        }
        if stats.sketchy, stats.paperRatio > 0.62 {
            return "纸上的线稿，还不像成品"
        }
        if isHalfWriting(ocrLines(for: file)) {
            return "图上的字像写了一半"
        }
        return nil
    }

    static func inspect(path: String) -> Stats? {
        guard let ns = NSImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var rect = NSRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        return stats(from: cg)
    }

    static func stats(from image: CGImage) -> Stats {
        let maxEdge: CGFloat = 160
        let w0 = CGFloat(image.width)
        let h0 = CGFloat(image.height)
        let edge = max(w0, h0)
        let scale = edge > maxEdge ? maxEdge / edge : 1
        let w = max(Int(w0 * scale), 1)
        let h = max(Int(h0 * scale), 1)
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return emptyStats()
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return emptyStats() }
        let rep = NSBitmapImageRep(cgImage: scaled)
        let rw = rep.pixelsWide
        let rh = rep.pixelsHigh

        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            if c.alphaComponent < 0.08 { return false }
            let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            return luma < 0.88
        }

        var ink = 0
        var paper = 0
        var chromaSum = 0.0
        var minX = rw, minY = rh, maxX = 0, maxY = 0
        var hBands = [0, 0, 0]
        var vBands = [0, 0, 0]
        for y in 0..<rh {
            for x in 0..<rw {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.alphaComponent < 0.08 { continue }
                if !isInk(x, y) {
                    paper += 1
                    continue
                }
                ink += 1
                chromaSum += max(c.redComponent, c.greenComponent, c.blueComponent)
                    - min(c.redComponent, c.greenComponent, c.blueComponent)
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
                // NSBitmapImageRep：y=0 是画面顶部
                hBands[min(2, y * 3 / max(rh, 1))] += 1
                vBands[min(2, x * 3 / max(rw, 1))] += 1
            }
        }

        var edges = 0
        if ink > 0 {
            for y in 1..<(rh - 1) {
                for x in 1..<(rw - 1) {
                    guard isInk(x, y) else { continue }
                    if !isInk(x - 1, y) || !isInk(x + 1, y) || !isInk(x, y - 1) || !isInk(x, y + 1) {
                        edges += 1
                    }
                }
            }
        }

        let covered = max(ink + paper, 1)
        let ratio = Double(ink) / Double(covered)
        let paperRatio = Double(paper) / Double(covered)
        let chroma = ink > 0 ? chromaSum / Double(ink) : 0
        let edgeRatio = ink > 0 ? Double(edges) / Double(ink) : 0
        var bbox = 1.0
        if ink > 0, maxX >= minX, maxY >= minY {
            bbox = Double((maxX - minX + 1) * (maxY - minY + 1)) / Double(max(rw * rh, 1))
        }
        let mostlyBlank = ratio < 0.03
        let sparse = ratio < 0.12 && bbox < 0.38
        let gray = chroma < 0.16
        let lineLike = edgeRatio >= 0.20
        let layout = layoutHint(hBands: hBands, vBands: vBands, ink: ink)
        let sketchy = paperRatio >= 0.42 && gray && (lineLike || mostlyBlank || sparse || !layout.isEmpty)
        return Stats(
            inkRatio: ratio,
            paperRatio: paperRatio,
            chroma: chroma,
            edgeRatio: edgeRatio,
            mostlyBlank: mostlyBlank,
            sparse: sparse,
            sketchy: sketchy,
            layout: layout
        )
    }

    private static func emptyStats() -> Stats {
        Stats(
            inkRatio: 1, paperRatio: 0, chroma: 1, edgeRatio: 0,
            mostlyBlank: false, sparse: false, sketchy: false, layout: ""
        )
    }

    private static func layoutHint(hBands: [Int], vBands: [Int], ink: Int) -> String {
        guard ink >= 8 else { return "" }
        func share(_ n: Int) -> Double { Double(n) / Double(ink) }
        let top = share(hBands[0])
        let midH = share(hBands[1])
        let bottom = share(hBands[2])
        let left = share(vBands[0])
        let right = share(vBands[2])
        if top > 0.58, bottom < 0.14 { return "着墨在上方，下方大片空白" }
        if bottom > 0.58, top < 0.14 { return "着墨在下方，上方大片空白" }
        if left > 0.58, right < 0.14 { return "着墨在左侧，右侧大片空白" }
        if right > 0.58, left < 0.14 { return "着墨在右侧，左侧大片空白" }
        if midH < 0.10, top > 0.25, bottom > 0.25 { return "中间空着，上下各有一截" }
        return ""
    }

    private static func looksPrinted(_ file: IndexedFile) -> Bool {
        let lines = ocrLines(for: file)
        if lines.count >= 8 { return true }
        let obj = ScanRecords.read(file) ?? [:]
        let vis = (obj["localScan"] as? [String: Any])?["vision"] as? [String: Any]
        if let tags = vis?["tags"] as? [[String: Any]] {
            return tags.contains {
                let id = ($0["id"] as? String) ?? ""
                return id == "printed_page" || id == "document"
            }
        }
        return false
    }

    private static func ocrLines(for file: IndexedFile) -> [String] {
        let obj = ScanRecords.read(file) ?? [:]
        let vis = (obj["localScan"] as? [String: Any])?["vision"] as? [String: Any]
        guard let raw = vis?["ocr"] as? [String] else { return [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func isHalfWriting(_ lines: [String]) -> Bool {
        guard lines.count >= 1, lines.count <= 6 else { return false }
        let text = lines.joined(separator: "")
        let chars = text.filter { $0 != " " && $0 != "\n" }
        guard chars.count >= 6, chars.count <= 80 else { return false }
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = last.hasSuffix("。") || last.hasSuffix("！") || last.hasSuffix("？")
            || last.hasSuffix(".") || last.hasSuffix("!") || last.hasSuffix("?")
        return !ended
    }
}
