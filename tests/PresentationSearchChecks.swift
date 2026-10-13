import Foundation

@main enum PresentationSearchChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let path = root.appendingPathComponent("sample.pptx").path
        let doc = PresentationReader.read(path: path)!
        precondition(doc.slides.count == 3)
        precondition(doc.slides.map(\.member) == ["ppt/slides/slide1.xml", "ppt/slides/slide10.xml", "ppt/slides/slide2.xml"])
        precondition(doc.slides[1].text.contains("提交审批 & 归档"))
        precondition(doc.slides[1].tags.contains("流程图"))
        precondition(doc.slides[2].tags.isEmpty, "Number badges alone must not be labelled flowcharts")
        precondition(doc.preview(limit: 8000).contains("量子协同验收"), "Preview must include later slides")
        // End-to-end persisted page search and legacy migration run in check_gateway.sh.
        let files = LibraryIndex.load(root: root)
        precondition(files.count == 1 && files[0].path == path)
        precondition(PresentationReader.read(path: root.appendingPathComponent("missing.pptx").path) == nil)
        let progress = ScanProgress()
        progress.beginLocal(scanned: 10, remaining: 1, skipped: 2)
        progress.completeLocalOne(success: false, file: "bad.pptx")
        progress.localFinished()
        progress.beginLLM(scanned: 8, remaining: 2, skipped: 4)
        progress.completeLLMOne(success: true)
        progress.completeLLMOne(success: false, file: "clip.mp4", reason: "未能读取视频帧")
        progress.finish(wrote: 1)
        precondition(progress.localScanned == 10 && progress.localFailed == 1)
        precondition(progress.llmScanned == 9 && progress.llmFailed == 1 && progress.llmSkipped == 4)
        precondition(progress.showDone && progress.title.contains("失败") && progress.failures.count == 2)
        let suiteName = "aie.scan-recovery-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ScanRecovery.begin(lane: .llm, scanned: 3, remaining: 2, failed: 0, skipped: 1,
                           defaults: defaults, now: 100)
        ScanRecovery.update(lane: .llm, scanned: 4, remaining: 1, failed: 0, skipped: 1,
                            currentFile: "fixture.pptx", defaults: defaults, now: 101)
        let recovered = ScanRecovery.interruptedSnapshot(for: .llm, defaults: defaults, now: 102)
        precondition(recovered?.scanned == 4 && recovered?.remaining == 1 && recovered?.currentFile == "fixture.pptx")
        ScanRecovery.markPaused(.llm, defaults: defaults, now: 103)
        precondition(ScanRecovery.interruptedSnapshot(for: .llm, defaults: defaults, now: 104) == nil)
        ScanRecovery.begin(lane: .local, scanned: 1, remaining: 1, failed: 0, skipped: 0,
                           defaults: defaults, now: 100)
        precondition(ScanRecovery.interruptedSnapshot(
            for: .local, defaults: defaults, now: 100 + ScanRecovery.staleAfter + 1) == nil)
        print("Presentation checks passed: slide evidence, metadata enumeration, scan failures and recovery checkpoints.")
    }
}
