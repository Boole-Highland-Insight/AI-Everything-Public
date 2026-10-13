import AppKit
import Foundation

struct ReuseChartSpec {
    enum Kind: String {
        case bar, line, stat
    }

    let id: String
    let title: String
    let kind: Kind
    let unit: String
    let items: [(label: String, value: Double)]
}

enum ReuseCharts {
    static func render(_ spec: ReuseChartSpec) -> Data? {
        let items = spec.items.filter { $0.value.isFinite }.prefix(8)
        guard !items.isEmpty else { return nil }
        let kind = items.count <= 2 && spec.kind != .line ? ReuseChartSpec.Kind.stat : spec.kind
        switch kind {
        case .stat:
            return drawStat(title: spec.title, unit: spec.unit, items: Array(items))
        case .line:
            return drawLine(title: spec.title, unit: spec.unit, items: Array(items))
        case .bar:
            return drawBar(title: spec.title, unit: spec.unit, items: Array(items))
        }
    }

    private static func drawBar(title: String, unit: String, items: [(label: String, value: Double)]) -> Data? {
        canvas(width: 880, height: 420) { size in
            fillBackground(size)
            drawHeader(title: title, unit: unit, width: size.width, height: size.height)
            let maxVal = max(items.map(\.value).max() ?? 1, 0.001)
            let plot = CGRect(x: 48, y: 56, width: size.width - 96, height: size.height - 132)
            let gap: CGFloat = 18
            let barW = max(28, (plot.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count))
            for (i, item) in items.enumerated() {
                let h = CGFloat(item.value / maxVal) * plot.height
                let x = plot.minX + CGFloat(i) * (barW + gap)
                let y = plot.minY
                let rect = CGRect(x: x, y: y, width: barW, height: max(h, 4))
                NSColor(calibratedWhite: 0.18, alpha: 0.88).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                drawText(
                    format(item.value),
                    at: CGPoint(x: x + barW / 2, y: y + h + 8),
                    font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    color: NSColor(calibratedWhite: 0.25, alpha: 1),
                    align: .center,
                    width: barW + 16
                )
                drawText(
                    item.label,
                    at: CGPoint(x: x + barW / 2, y: 22),
                    font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    color: NSColor(calibratedWhite: 0.38, alpha: 1),
                    align: .center,
                    width: barW + 12
                )
            }
        }
    }

    private static func drawLine(title: String, unit: String, items: [(label: String, value: Double)]) -> Data? {
        canvas(width: 880, height: 420) { size in
            fillBackground(size)
            drawHeader(title: title, unit: unit, width: size.width, height: size.height)
            let maxVal = max(items.map(\.value).max() ?? 1, 0.001)
            let minVal = min(items.map(\.value).min() ?? 0, 0)
            let span = max(maxVal - minVal, 0.001)
            let plot = CGRect(x: 56, y: 64, width: size.width - 112, height: size.height - 140)
            let path = NSBezierPath()
            path.lineWidth = 2.5
            var dots: [CGPoint] = []
            for (i, item) in items.enumerated() {
                let x = plot.minX + (items.count == 1 ? plot.width / 2 : plot.width * CGFloat(i) / CGFloat(items.count - 1))
                let y = plot.minY + CGFloat((item.value - minVal) / span) * plot.height
                let p = CGPoint(x: x, y: y)
                dots.append(p)
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
                drawText(
                    item.label,
                    at: CGPoint(x: x, y: 22),
                    font: NSFont.systemFont(ofSize: 11),
                    color: NSColor(calibratedWhite: 0.38, alpha: 1),
                    align: .center,
                    width: 100
                )
            }
            NSColor(calibratedWhite: 0.18, alpha: 0.9).setStroke()
            path.stroke()
            for p in dots {
                let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
                dot.fill()
            }
        }
    }

    private static func drawStat(title: String, unit: String, items: [(label: String, value: Double)]) -> Data? {
        canvas(width: 880, height: 280) { size in
            fillBackground(size)
            drawHeader(title: title, unit: unit, width: size.width, height: size.height)
            let colW = size.width / CGFloat(max(items.count, 1))
            for (i, item) in items.enumerated() {
                let cx = colW * (CGFloat(i) + 0.5)
                drawText(
                    format(item.value),
                    at: CGPoint(x: cx, y: size.height * 0.42),
                    font: NSFont.systemFont(ofSize: 44, weight: .medium),
                    color: NSColor(calibratedWhite: 0.12, alpha: 1),
                    align: .center,
                    width: colW - 24
                )
                drawText(
                    item.label,
                    at: CGPoint(x: cx, y: 48),
                    font: NSFont.systemFont(ofSize: 13),
                    color: NSColor(calibratedWhite: 0.38, alpha: 1),
                    align: .center,
                    width: colW - 24
                )
            }
        }
    }

    private static func canvas(width: Int, height: Int, draw: (CGSize) -> Void) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width * Int(scale),
            pixelsHigh: height * Int(scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        draw(CGSize(width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func fillBackground(_ size: CGSize) {
        NSColor(calibratedWhite: 0.955, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    }

    private static func drawHeader(title: String, unit: String, width: CGFloat, height: CGFloat) {
        drawText(
            title,
            at: CGPoint(x: 48, y: height - 42),
            font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            color: NSColor(calibratedWhite: 0.12, alpha: 1),
            align: .left,
            width: width - 200
        )
        if !unit.isEmpty {
            drawText(
                unit,
                at: CGPoint(x: width - 48, y: height - 42),
                font: NSFont.systemFont(ofSize: 12),
                color: NSColor(calibratedWhite: 0.45, alpha: 1),
                align: .right,
                width: 160
            )
        }
    }

    private enum Align { case left, center, right }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        font: NSFont,
        color: NSColor,
        align: Align,
        width: CGFloat
    ) {
        let para = NSMutableParagraphStyle()
        switch align {
        case .left: para.alignment = .left
        case .center: para.alignment = .center
        case .right: para.alignment = .right
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        let x: CGFloat
        switch align {
        case .left: x = point.x
        case .center: x = point.x - width / 2
        case .right: x = point.x - width
        }
        (text as NSString).draw(in: CGRect(x: x, y: point.y, width: width, height: 52), withAttributes: attrs)
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) >= 10 {
            return String(Int(value.rounded()))
        }
        let n = NSNumber(value: value)
        let f = NumberFormatter()
        f.maximumFractionDigits = abs(value) < 10 ? 1 : 0
        f.minimumFractionDigits = 0
        return f.string(from: n) ?? "\(value)"
    }
}
