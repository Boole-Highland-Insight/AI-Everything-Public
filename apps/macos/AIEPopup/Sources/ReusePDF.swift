import AppKit
import CoreGraphics
import CoreText
import Foundation

enum ReusePDF {
    private static let page = CGSize(width: 595, height: 842)
    private static let margin: CGFloat = 52
    private static var contentWidth: CGFloat { page.width - margin * 2 }

    static func render(markdown: String, images: [String: Data]) -> Data? {
        let cgImages: [String: CGImage] = Dictionary(uniqueKeysWithValues: images.compactMap { name, data in
            guard let image = NSImage(data: data) else { return nil }
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return (name, cg)
        })
        let blocks = parse(markdown)
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil)
        else { return nil }

        // PDF 原点在左下、Y 向上。不要套 flipped NSGraphicsContext，否则整页倒置。
        var yTop: CGFloat = 0
        func startPage() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: page))
            yTop = page.height - margin
        }
        func finishPage() {
            ctx.endPDFPage()
        }

        startPage()
        for block in blocks {
            let gap = block.gap
            let height = block.height(width: contentWidth, images: cgImages)
            if yTop - gap - height < margin, yTop < page.height - margin - 8 {
                finishPage()
                startPage()
            }
            yTop -= gap
            let yBottom = yTop - height
            block.draw(
                in: CGRect(x: margin, y: yBottom, width: contentWidth, height: height),
                ctx: ctx,
                images: cgImages
            )
            yTop = yBottom
        }
        finishPage()
        ctx.closePDF()
        return data as Data
    }

    private enum Block {
        case title(String)
        case heading(String)
        case body(String)
        case image(String)

        var gap: CGFloat {
            switch self {
            case .title: return 0
            case .heading: return 18
            case .body: return 8
            case .image: return 12
            }
        }

        func height(width: CGFloat, images: [String: CGImage]) -> CGFloat {
            switch self {
            case .title(let t):
                return textHeight(t, font: .systemFont(ofSize: 22, weight: .semibold), width: width) + 6
            case .heading(let t):
                return textHeight(t, font: .systemFont(ofSize: 14, weight: .semibold), width: width)
            case .body(let t):
                return textHeight(t, font: .systemFont(ofSize: 11.5), width: width)
            case .image(let name):
                guard let image = images[name] else { return 0 }
                let w = CGFloat(image.width)
                let h = CGFloat(image.height)
                guard w > 0 else { return 0 }
                return min(248, width * (h / w))
            }
        }

        func draw(in rect: CGRect, ctx: CGContext, images: [String: CGImage]) {
            switch self {
            case .title(let t):
                drawText(t, font: .systemFont(ofSize: 22, weight: .semibold), color: .black, in: rect, ctx: ctx)
            case .heading(let t):
                drawText(t, font: .systemFont(ofSize: 14, weight: .semibold), color: .black, in: rect, ctx: ctx)
            case .body(let t):
                drawText(
                    t,
                    font: .systemFont(ofSize: 11.5),
                    color: NSColor(calibratedWhite: 0.18, alpha: 1),
                    in: rect,
                    ctx: ctx
                )
            case .image(let name):
                guard let image = images[name] else { return }
                ctx.saveGState()
                ctx.setFillColor(CGColor(gray: 0.96, alpha: 1))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.fillPath()
                ctx.draw(image, in: rect)
                ctx.restoreGState()
            }
        }
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var body: [String] = []
        func flush() {
            let t = body.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(.body(t)) }
            body = []
        }
        var sawTitle = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("# ") {
                flush()
                blocks.append(.title(String(line.dropFirst(2))))
                sawTitle = true
                continue
            }
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
                let text = line.hasPrefix("### ") ? String(line.dropFirst(4)) : String(line.dropFirst(3))
                if !sawTitle {
                    blocks.append(.title(text))
                    sawTitle = true
                } else {
                    blocks.append(.heading(text))
                }
                continue
            }
            if let img = imageName(in: line) {
                flush()
                blocks.append(.image(img))
                continue
            }
            body.append(line)
        }
        flush()
        return blocks
    }

    private static func imageName(in line: String) -> String? {
        guard let open = line.range(of: "]("),
              let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
        else { return nil }
        let src = String(line[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        if src.lowercased().hasPrefix("http") { return nil }
        return (src as NSString).lastPathComponent
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 0
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let attr = attributed(text, font: font, color: .black)
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            setter,
            CFRange(location: 0, length: attr.length),
            nil,
            CGSize(width: width, height: 8000),
            nil
        )
        return ceil(size.height)
    }

    private static func drawText(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, ctx: CGContext) {
        let attr = attributed(text, font: font, color: color)
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            setter,
            CFRange(location: 0, length: attr.length),
            path,
            nil
        )
        ctx.saveGState()
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}
