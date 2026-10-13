import Foundation
import Combine

struct ScanSkipItem: Identifiable {
    let path: String
    let reason: String
    var id: String { path }
    static func reason(for ext: String, cloud: Bool) -> String {
        switch ext {
        case "m4a", "mp3", "wav", "aac", "flac": return cloud ? "音频不进入自动云端扫描" : "音频转写需单独启动，未加入自动扫描"
        case "xls": return "旧版 XLS 尚未支持，请另存为 XLSX"
        case "msg", "eml": return "未启用邮件文件正文解析"
        case "rar", "zip", "7z", "tar", "gz": return "不自动展开压缩包扫描"
        case "xml": return "尚未接入 XML 正文扫描"
        default: return "此格式尚未接入内容扫描"
        }
    }
}

/// 两行进度：端侧原文提取和模型语义扫描。有新文件时先走端侧。
final class ScanProgress: ObservableObject {
    static let shared = ScanProgress()

    @Published var cloudPaused = false
    @Published var running = false
    @Published var localScanned = 0
    @Published var localRemaining = 0
    @Published var llmScanned = 0
    @Published var llmRemaining = 0
    @Published var localFailed = 0
    @Published var llmFailed = 0
    @Published var localSkipped = 0
    @Published var llmSkipped = 0
    @Published var failures: [String] = []
    @Published var localSkippedFiles: [ScanSkipItem] = []
    @Published var llmSkippedFiles: [ScanSkipItem] = []
    @Published var currentFile: String?
    @Published var message = ""
    @Published var showDone = false
    @Published var active: Lane = .none
    @Published var catalogReady = false
    @Published var catalogCount = 0
    @Published var userPaused = UserDefaults.standard.bool(forKey: "aie.scan.userPaused")
    @Published var prominent = true
    @Published var recoveredInterruption = false
    @Published var yieldingForSearch = false
    @Published var llmUsesLocalModel = false
    @Published var indexing = false
    @Published var indexFailed = false
    @Published var indexedFiles = 0
    @Published var indexTotal = 0
    private var llmFailureMessages: [String: String] = [:]

    enum Lane {
        case none, local, llm
    }

    var localTotal: Int {
        localScanned + localRemaining + localFailed
    }

    var llmTotal: Int {
        llmScanned + llmRemaining + llmFailed
    }

    var localFraction: Double {
        guard localTotal > 0 else { return 0 }
        return Double(localScanned) / Double(localTotal)
    }

    var llmFraction: Double {
        guard llmTotal > 0 else { return 0 }
        return Double(llmScanned) / Double(llmTotal)
    }

    var localPercent: Int { Int((localFraction * 100).rounded()) }
    var llmPercent: Int { Int((llmFraction * 100).rounded()) }

    var indexFraction: Double {
        guard indexTotal > 0 else { return 0 }
        return Double(indexedFiles) / Double(indexTotal)
    }

    var indexPercent: Int { Int((indexFraction * 100).rounded()) }

    var title: String {
        if userPaused { return "扫描已暂停 · 基础搜索仍可使用" }
        if indexFailed { return "内容索引失败 · 已保留上次可用结果" }
        if indexing { return "已可搜索 · 正在建立内容索引" }
        if yieldingForSearch { return "搜索使用中 · 后台扫描正在让路" }
        if running {
            if recoveredInterruption { return "已恢复上次中断 · 内容继续分析" }
            if catalogReady { return "已可搜索 · 内容仍在分析" }
            switch active {
            case .local: return "扫描 · 端侧"
            case .llm: return llmUsesLocalModel ? "扫描 · 本机深度" : "扫描 · 云端模型"
            case .none: return "扫描"
            }
        }
        if localFailed + llmFailed > 0 { return "扫描结束 · 有失败项" }
        if cloudPaused { return "本机扫描完成 · 云端扫描已暂停" }
        return localSkipped + llmSkipped > 0 ? "扫描结束 · 有未处理项" : "扫描已完成"
    }

    func setCatalogReady(count: Int) {
        catalogReady = true
        catalogCount = count
    }

    func beginIndexing(total: Int) {
        indexing = total > 0
        indexFailed = false
        indexedFiles = 0
        indexTotal = total
        if indexing { message = "正在准备内容索引…" }
    }

    func updateIndexing(completed: Int, total: Int) {
        indexing = completed < total
        indexedFiles = min(max(0, completed), total)
        indexTotal = total
        if indexing { message = "内容索引 \(indexedFiles)/\(indexTotal)" }
    }

    func finishIndexing(completed: Bool) {
        if completed { indexedFiles = indexTotal }
        indexing = false
        indexFailed = !completed
        if indexFailed { message = "内容索引失败，搜索继续使用上次完整快照。" }
    }

    func setProminent(_ value: Bool) {
        if running, prominent, !value { return }
        prominent = value
    }

    func pauseByUser() {
        let lane = active
        userPaused = true
        running = false
        yieldingForSearch = false
        active = .none
        currentFile = nil
        recoveredInterruption = false
        switch lane {
        case .local: ScanRecovery.markPaused(.local)
        case .llm: ScanRecovery.markPaused(.llm)
        case .none: break
        }
        message = "当前文件处理完成后已暂停；继续时会从队列恢复。"
        showDone = true
    }

    func resumeByUser() {
        userPaused = false
        showDone = false
        message = "正在恢复后台分析…"
    }

    func setYieldingForSearch(_ value: Bool) {
        yieldingForSearch = value
        if value {
            message = "优先响应输入和检索，空闲后自动继续。"
        }
    }

    fileprivate var doneHide: DispatchWorkItem?

    func beginLocal(scanned: Int, remaining: Int, skipped: Int = 0) {
        doneHide?.cancel()
        let recovered = ScanRecovery.interruptedSnapshot(for: .local)
        ScanRecovery.begin(lane: .local, scanned: scanned, remaining: remaining, failed: 0, skipped: skipped)
        running = true
        yieldingForSearch = false
        showDone = false
        active = .local
        recoveredInterruption = recovered != nil && remaining > 0
        localFailed = 0
        llmFailed = 0
        llmFailureMessages.removeAll()
        failures = []
        localSkipped = skipped
        localScanned = scanned
        localRemaining = remaining
        currentFile = nil
        if recoveredInterruption {
            message = "检测到上次端侧扫描中断，正在从剩余 \(remaining) 项继续…"
        } else {
            message = remaining == 0 ? "端侧已是最新" : "端侧扫描进行中…"
        }
    }

    func pauseLLM(scanned: Int, pending: Int, skipped: Int) {
        llmScanned = scanned
        llmSkipped = skipped
        finish(wrote: 0)
        cloudPaused = true
        llmRemaining = pending
        showDone = true
    }

    func beginLLM(scanned: Int, remaining: Int, skipped: Int = 0, usesLocalModel: Bool = false) {
        doneHide?.cancel()
        let recovered = ScanRecovery.interruptedSnapshot(for: .llm)
        ScanRecovery.begin(lane: .llm, scanned: scanned, remaining: remaining, failed: 0, skipped: skipped)
        running = true
        yieldingForSearch = false
        showDone = false
        active = .llm
        llmUsesLocalModel = usesLocalModel
        recoveredInterruption = recovered != nil && remaining > 0
        cloudPaused = false
        llmFailed = 0
        llmFailureMessages.removeAll()
        llmSkipped = skipped
        llmScanned = scanned
        llmRemaining = remaining
        currentFile = nil
        if recoveredInterruption {
            message = "检测到上次模型扫描中断，正在从剩余 \(remaining) 项继续…"
        } else {
            message = remaining == 0
                ? (llmUsesLocalModel ? "本机深度扫描已是最新" : "云端扫描已是最新")
                : (llmUsesLocalModel ? "本机深度扫描进行中…" : "云端扫描进行中…")
        }
    }

    func addLocalRemaining(_ n: Int) {
        localRemaining += n
        if n > 0, active == .none { active = .local }
    }

    func addLLMRemaining(_ n: Int) {
        llmRemaining += n
        if n > 0, active != .local { active = .llm }
    }

    func completeLocalOne(success: Bool = true, file: String = "") {
        if localRemaining > 0 { localRemaining -= 1 }
        if success { localScanned += 1 } else {
            localFailed += 1
            failures.append("\(file)：本机分析或保存失败")
        }
        ScanRecovery.update(
            lane: .local,
            scanned: localScanned,
            remaining: localRemaining,
            failed: localFailed,
            skipped: localSkipped,
            currentFile: nil
        )
    }

    func completeLLMOne(success: Bool = true, file: String = "", reason: String = "") {
        if llmRemaining > 0 { llmRemaining -= 1 }
        if success {
            llmScanned += 1
            if let previous = llmFailureMessages.removeValue(forKey: file),
               let index = failures.firstIndex(of: previous) {
                failures.remove(at: index)
            }
        } else {
            let message = "\(file)：\(reason)"
            if let previous = llmFailureMessages.updateValue(message, forKey: file),
               let index = failures.firstIndex(of: previous) {
                failures[index] = message
            } else {
                failures.append(message)
            }
        }
        llmFailed = llmFailureMessages.count
        ScanRecovery.update(
            lane: .llm,
            scanned: llmScanned,
            remaining: llmRemaining,
            failed: llmFailed,
            skipped: llmSkipped,
            currentFile: nil
        )
    }

    func localFinished() {
        localRemaining = 0
        ScanRecovery.finish(.local)
        if active == .local {
            currentFile = nil
            recoveredInterruption = false
            message = "端侧完成，接着内容理解扫描…"
        }
    }

    func finish(wrote: Int) {
        let lane = active
        running = false
        yieldingForSearch = false
        active = .none
        currentFile = nil
        recoveredInterruption = false
        localRemaining = 0
        llmRemaining = 0
        switch lane {
        case .local: ScanRecovery.finish(.local)
        case .llm: ScanRecovery.finish(.llm)
        case .none: break
        }
        message = wrote == 0 && localScanned + llmScanned == 0 ? "没有需要扫描的文件。" : "扫描完成。"
        showDone = wrote > 0 || localScanned > 0 || llmScanned > 0 || !failures.isEmpty || localSkipped + llmSkipped > 0
        guard failures.isEmpty, localSkipped + llmSkipped == 0 else { return }
        let hide = DispatchWorkItem { [weak self] in
            self?.showDone = false
        }
        doneHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: hide)
    }
}
