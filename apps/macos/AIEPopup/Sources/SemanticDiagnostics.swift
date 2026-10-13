import Foundation
import AIEData

/// Real embedding integration on explicitly selected, empty synthetic directories only.
enum SemanticDiagnostics {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--verify-semantic" else { return false }
        guard CommandLine.arguments.count == 3, let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"], path.hasPrefix("/") else { exit(2) }
        // Exercise the embedding-only plan without changing saved preferences or downloading models.
        UserDefaults.standard.setVolatileDomain([
            ScanConfiguration.planKey: LocalScanPlan.semantic.rawValue,
            ScanConfiguration.pendingKey: false,
        ], forName: UserDefaults.argumentDomain)
        precondition(ScanConfiguration.semanticEnabled() && !ScanConfiguration.visionEnabled())
        precondition(!LocalRerank.isAvailable && ScanConfiguration.cloudScanPaused())
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL.resolvingSymlinksInPath()
        Task { @MainActor in
            do {
                let vision = await LocalQuickScan.shared.complete(system: "test", user: "test", images: [], maxTokens: 1)
                guard vision == nil else { throw CocoaError(.coderInvalidValue) }
                guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw CocoaError(.fileWriteFileExists) }
                let samples = ["headings.txt": "## 行程安排", "flowchart.txt": "项目审批流程图：起点提交申请，经过主管审批和财务复核，最终归档。各步骤用箭头连接。", "onboarding.txt": "入职办理：人事登记、签署劳动合同、分配办公设备，安排导师介绍团队。",
                               "seaside.txt": "海滨度假地点，沙滩上可以游泳冲浪，欣赏大海的风景。",
                               "invoice.txt": "发票报销管理，核对金额、税率和银行收款账户，月底提交财务审批。"]
                for (name, text) in samples { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
                let files = LibraryGateway.load(roots: [root])
                guard LibraryGateway.lastError == nil else { throw CocoaError(.fileReadUnknown) }
                guard await LocalSemanticIndex.shared.indexNow(roots: [root.path]) else { throw CocoaError(.featureUnsupported) }
                let queries = [("刚招来的人第一天该做什么", "onboarding.txt"), ("适合下海玩耍的旅游目的地", "seaside.txt"), ("流程图", "flowchart.txt")]
                for (query, expected) in queries {
                    let vectors = await LocalSemanticIndex.shared.search(query: query, roots: [root.path])
                    guard vectors.first?.path == root.appendingPathComponent(expected).path else { throw NSError(domain: "SemanticCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Semantic fixture did not rank the relevant passage first"]) }
                    if query == "流程图", vectors.contains(where: { $0.path == root.appendingPathComponent("headings.txt").path }) { throw CocoaError(.coderInvalidValue) }
                    let hits = LibraryGateway.search(query: query, in: files, semantic: vectors)
                    guard hits.contains(where: { $0.name == expected && $0.chunkID != nil }) else { throw CocoaError(.coderInvalidValue) }
                    print("Semantic fixture passed: \(expected), cosine \(String(format: "%.3f", vectors[0].score))")
                }
                print("Real 0.6B-only embedding checks passed; vision and local reranking disabled; no user documents or cloud APIs used.")
                exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        RunLoop.current.run()
        return true
    }
}
