import AppKit
import SwiftUI

enum IndexingStatusDiagnostics {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--verify-indexing-layout" else { return false }
        guard args.count == 3, args[2].hasPrefix("/") else {
            fputs("usage: AIEPopup --verify-indexing-layout /absolute/output/directory\n", stderr)
            exit(2)
        }
        do {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["running", "paused", "complete", "failures", "empty"] {
                let paused = name == "paused"
                let done = name == "complete" || name == "failures"
                let empty = name == "empty"
                let title = paused ? "后台分析已暂停" : (done ? "搜索已就绪" : (empty ? "添加要搜索的资料夹" : "搜索已可用，分析继续中"))
                var stages = [
                    IndexingStageDisplay(id: "index", title: "文件索引", symbol: "doc.text.magnifyingglass",
                        detail: empty ? "当前没有需要此阶段处理的文件" : "1,449 个完成", status: empty ? "无需处理" : "已完成", fraction: empty ? nil : 1),
                    IndexingStageDisplay(id: "local", title: "文字识别", symbol: "viewfinder",
                        detail: "1,304 个完成 · 145 个跳过", status: "已完成", fraction: 1),
                    IndexingStageDisplay(id: "semantic", title: "语义搜索", symbol: "point.3.connected.trianglepath.dotted",
                        detail: paused ? "已暂停，继续后处理剩余片段" : (done ? "27,662 个内容片段可按含义搜索" : "预计还需 18 分钟"),
                        status: done ? "已完成" : "24,082 / 27,662 片段", fraction: done ? 1 : 0.87, active: !done && !paused),
                    IndexingStageDisplay(id: "deep", title: "深度理解", symbol: "sparkles",
                        detail: paused ? "剩余 206 个 · 已暂停" : (done ? (name == "failures" ? "1,298 个完成 · 6 个失败，可查看原因 · 145 个跳过" : "1,304 个完成 · 145 个跳过") : "剩余 206 个 · 预计还需 42 分钟 · 145 个跳过"),
                        status: name == "failures" ? "6 个待处理" : (done ? "已完成" : "1,098 / 1,304"),
                        fraction: done ? 1 : 0.84, active: !done && !paused, attention: name == "failures"),
                ]
                if empty {
                    stages = stages.map {
                        IndexingStageDisplay(id: $0.id, title: $0.title, symbol: $0.symbol,
                            detail: "选择资料夹后开始建立索引", status: "无需处理", fraction: nil)
                    }
                }
                for dark in [false, true] {
                    let content = IndexingOverview(title: title,
                        detail: paused ? "已完成的索引仍可搜索，继续后处理剩余内容。" : (empty ? "文件保留在原处，随时可以调整搜索范围。" : "1,449 个文件 · 3 个资料夹 · 最近文件优先"),
                        stages: stages, paused: paused, canPause: !empty && (!done || paused), togglePause: {})
                        .font(.system(size: 13)).padding(18).frame(width: 430)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let view = NSHostingView(rootView: content)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let height = max(380, view.fittingSize.height)
                    view.frame = NSRect(x: 0, y: 0, width: 430, height: height)
                    view.layoutSubtreeIfNeeded()
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try png.write(to: directory.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
                }
            }
            print("Indexing layout: 10 fixtures rendered without opening personal sources or starting models.")
        } catch { fputs("Indexing layout failed: \(error)\n", stderr); exit(1) }
        return true
    }
}
