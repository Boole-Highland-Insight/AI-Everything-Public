import AppKit
import SwiftUI
import PDFKit

/// Exports the shipping views with synthetic files, for the bundled onboarding video.
/// Preview models do not read saved roots or keys, schedule searches, or call cloud services.
enum OnboardingDemoExport {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--export-onboarding-demo" else { return false }
        guard args.count == 3, args[2].hasPrefix("/") else { exit(2) }
        do {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = directory.appendingPathComponent("周末旅行计划.pdf")
            let result = directory.appendingPathComponent("周末旅行计划 完善版.pdf")
            try document(at: original, completed: false)
            try document(at: result, completed: true)
            let textOriginal = directory.appendingPathComponent("周末旅行计划.txt")
            let textResult = directory.appendingPathComponent("周末旅行计划 完善版.txt")
            try """
            杭州周末旅行计划

            想做的事
            逛西湖，留半天看展，不想把行程排得太满。

            周六
            10:00 抵达后先放下行李。
            11:00 在西湖边慢慢走，找一家小店午餐。
            下午：沿湖散步，拍几张照片。

            周日
            上午去美术馆，之后……

            还要补：返程安排、出行清单。
            """
                .write(to: textOriginal, atomically: true, encoding: .utf8)
            try """
            杭州周末旅行计划

            想做的事
            逛西湖、看一场展，也给散步和休息留白。

            周六 · 湖边慢下来
            10:00 抵达后放下行李。
            11:00 沿西湖散步，午餐就近选择。
            14:00 找一家小店休息，傍晚再拍照。

            周日 · 看展与返程
            上午睡到自然醒，再去美术馆。
            午后留出用餐、取行李和前往车站的时间。
            根据已购买的车次安排返程，不赶最后一刻。

            出行清单
            □ 证件、充电器、轻便雨具、舒适的鞋
            □ 出发前确认天气与展馆开放、预约信息
            □ 核对返程车次，预留交通缓冲时间
            """
                .write(to: textResult, atomically: true, encoding: .utf8)
            let imageOriginal = directory.appendingPathComponent("小猫草稿.png")
            let imageResult = directory.appendingPathComponent("小猫草稿 完善版.png")
            try image(at: imageOriginal, completed: false)
            try image(at: imageResult, completed: true)
            let file = IndexedFile(path: textOriginal.path, name: textOriginal.lastPathComponent,
                relative: textOriginal.lastPathComponent, kind: .document, ext: "txt", mtime: Date(),
                haystack: "周末旅行计划 草稿", preview: "周末去杭州，想逛西湖，也想留半天看展。第二天的安排还没写完。",
                thumbPath: nil, rootPath: directory.path, size: 2048, hasBarcode: false,
                isScreenshot: false, llmLine: "未完成的周末旅行计划", llmCard: "", uploadedToCloud: false)
            for dark in [false, true] {
                let folder = directory.appendingPathComponent(dark ? "dark" : "light")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let model = SearchModel(previewFiles: [file])
                model.hits = [FileHit(path: file.path, name: file.name, relative: file.relative,
                    kind: .document, ext: "pdf", mtime: file.mtime, reason: "内容匹配", score: 90,
                    snippet: file.preview, highlights: ["杭州", "第二天"], thumbPath: nil,
                    uploadedToCloud: false, confidenceTier: .direct)]
                model.selected = file.path
                for (index, query) in ["旅", "旅行", "旅行计", "旅行计划"].enumerated() {
                    model.query = query
                    try render(SearchPanelView(model: model, onDismiss: {}), size: NSSize(width: 620, height: 480),
                               dark: dark, to: folder.appendingPathComponent("search-\(index).png"))
                }
                model.reusePhase = .choose(ReuseProposal(path: file.path, name: file.name,
                    brief: "一份还没写完的杭州周末计划，可以沿着这些方向继续。",
                    options: [ReuseOption(id: "A", title: "补齐两天行程，留出休息时间"),
                              ReuseOption(id: "B", title: "整理成一页出行清单"),
                              ReuseOption(id: "C", title: "改成适合分享的旅行手账"),
                              ReuseOption(id: "D", title: "整理成带预算的轻量攻略")]))
                try render(ReuseSessionView(model: model), size: NSSize(width: 480, height: 540),
                           dark: dark, to: folder.appendingPathComponent("reuse-choice.png"))
                model.reusePicks = ["direction": "B"]
                model.reusePhase = .ask(ImageAsk(
                    path: file.path,
                    name: "小猫草稿.png",
                    diagnosis: "一张还没画完的小猫铅笔线稿，轮廓清楚，但身体和背景仍有留白。",
                    anchors: "头部轮廓与耳朵；眼睛和鼻子；左侧前爪线条",
                    choices: [
                        ImageAskChoice(id: "A", title: "保留铅笔质感，只补缺失线条"),
                        ImageAskChoice(id: "B", title: "轻轻上色，按原构图完成"),
                        ImageAskChoice(id: "C", title: "清理线条，保持黑白素描"),
                        ImageAskChoice(id: "D", title: "保留主体，补足背景与细节"),
                    ]
                ))
                try render(ReuseSessionView(model: model), size: NSSize(width: 480, height: 540),
                           dark: dark, to: folder.appendingPathComponent("reuse-ask.png"))
                model.reusePhase = .done(name: result.lastPathComponent, path: result.path)
                model.reuseSummary = "保留西湖与看展的想法，补齐第二天安排和出行清单。原文件保留，可以继续修改新版。"
                model.reuseFollowUp = "把第二天的行程再放松一点"
                try render(ReuseSessionView(model: model), size: NSSize(width: 1040, height: 700),
                           dark: dark, to: folder.appendingPathComponent("reuse-compare.png"))

                let textFile = IndexedFile(path: textOriginal.path, name: textOriginal.lastPathComponent,
                    relative: textOriginal.lastPathComponent, kind: .document, ext: "txt", mtime: Date(),
                    haystack: "周末旅行计划 草稿", preview: "第二天的安排还没有写完。", thumbPath: nil,
                    rootPath: directory.path, size: 1024, hasBarcode: false, isScreenshot: false,
                    llmLine: "未完成的周末旅行计划", llmCard: "", uploadedToCloud: false)
                let textModel = SearchModel(previewFiles: [textFile])
                textModel.reusePhase = .done(name: textResult.lastPathComponent, path: textResult.path)
                textModel.reuseSummary = "沿用原有想法，补齐周日安排和出行清单；不虚构车次或展览信息。"
                textModel.reuseFollowUp = "把第二天的安排再放松一点"
                try render(ReuseSessionView(model: textModel), size: NSSize(width: 1040, height: 700),
                           dark: dark, to: folder.appendingPathComponent("reuse-compare-text.png"))

                let imageFile = IndexedFile(path: imageOriginal.path, name: imageOriginal.lastPathComponent,
                    relative: imageOriginal.lastPathComponent, kind: .image, ext: "png", mtime: Date(),
                    haystack: "小猫 草稿", preview: "一张没画完的小猫线稿。", thumbPath: imageOriginal.path,
                    rootPath: directory.path, size: 2048, hasBarcode: false, isScreenshot: false,
                    llmLine: "未完成的小猫线稿", llmCard: "", uploadedToCloud: false)
                let imageModel = SearchModel(previewFiles: [imageFile])
                imageModel.reusePhase = .done(name: imageResult.lastPathComponent, path: imageResult.path)
                imageModel.reuseSummary = "保留原构图，补齐身体线条并加入克制的淡色。"
                try render(ReuseSessionView(model: imageModel), size: NSSize(width: 1040, height: 700),
                           dark: dark, to: folder.appendingPathComponent("reuse-compare-image.png"))
            }
            print("Exported real search and reuse views with synthetic documents; no model calls or saved settings changed.")
        } catch { fputs("Demo export failed: \(error)\n", stderr); exit(1) }
        return true
    }

    @MainActor private static func render<V: View>(_ content: V, size: NSSize, dark: Bool, to url: URL) throws {
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        // Let native text fields and Quick Look document previews finish laying out.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.makeFirstResponder(nil)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        window.close()
    }

    private static func document(at url: URL, completed: Bool) throws {
        let image = NSImage(size: NSSize(width: 600, height: 780), flipped: true) { bounds in
            NSColor.white.setFill(); bounds.fill()
            func line(_ text: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
                (text as NSString).draw(in: NSRect(x: 46, y: y, width: 508, height: 60), withAttributes: [
                    .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                    .foregroundColor: NSColor.black,
                ])
            }
            line("周末旅行计划", y: 48, size: 30, bold: true)
            line("杭州 · 两天一夜", y: 98, size: 16)
            line("第一天 / 西湖慢走", y: 164, size: 22, bold: true)
            line("上午到达，沿湖散步，午后找一家小店休息。", y: 207, size: 17)
            line("傍晚看日落，晚上尝尝本地菜。", y: 244, size: 17)
            line("第二天 / 看展与返程", y: 324, size: 22, bold: true)
            if completed {
                line("睡到自然醒，上午去美术馆看展。", y: 367, size: 17)
                line("午后留出自由时间，傍晚从容返程。", y: 404, size: 17)
                line("出发前准备", y: 492, size: 22, bold: true)
                line("确认展馆开放时间，预约车票与住宿。", y: 536, size: 17)
                line("带上充电器、雨伞和一双舒服的鞋。", y: 573, size: 17)
            } else {
                line("待补充：看展时间、返程安排、出行清单。", y: 367, size: 17)
            }
            return true
        }
        let document = PDFDocument()
        guard let page = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
        document.insert(page, at: 0)
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func image(at url: URL, completed: Bool) throws {
        let size = NSSize(width: 720, height: 520)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: 220, y: 180))
        outline.line(to: NSPoint(x: 270, y: 330))
        outline.line(to: NSPoint(x: 330, y: 270))
        outline.line(to: NSPoint(x: 390, y: 330))
        outline.line(to: NSPoint(x: 440, y: 180))
        outline.curve(to: NSPoint(x: 220, y: 180), controlPoint1: NSPoint(x: 450, y: 80), controlPoint2: NSPoint(x: 210, y: 80))
        outline.lineWidth = completed ? 5 : 2
        (completed ? NSColor.systemBlue.withAlphaComponent(0.55) : NSColor.darkGray).setStroke()
        outline.stroke()
        if completed {
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            outline.fill()
        }
        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
