import AIEData
import SwiftUI

struct IndexingStageDisplay: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    let status: String
    let fraction: Double?
    var active = false
    var attention = false
}

/// A flat overview: stages can run independently, so they aren't shown as a sequential wizard.
struct IndexingOverview: View {
    let title: String
    let detail: String
    let stages: [IndexingStageDisplay]
    let paused: Bool
    let canPause: Bool
    let togglePause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if canPause {
                    Button(action: togglePause) {
                        Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.small)
                }
            }
            VStack(spacing: 16) {
                ForEach(stages) { stage in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: stage.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(stage.active ? Color.accentColor : Color.secondary)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(stage.title).fontWeight(.medium)
                                Spacer(minLength: 6)
                                Text(stage.status)
                                    .font(.system(size: 11))
                                    .foregroundStyle(stage.attention ? Color.orange : Color.secondary)
                                    .monospacedDigit()
                            }
                            if let fraction = stage.fraction, fraction < 1 || stage.active {
                                ProgressView(value: min(1, max(0, fraction)))
                                    .tint(stage.active ? Color.accentColor : Color.secondary.opacity(0.5))
                                    .controlSize(.small)
                            }
                            Text(stage.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct IndexingStatusView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var scan = ScanProgress.shared
    @ObservedObject private var semantic = SemanticProgress.shared
    @State private var records: [FileScanStatus] = []
    @State private var loaded = false
    @State private var loadError = false
    @State private var showIssues = false
    @State private var showFolders = false
    @State private var resourcePause: String?
    @State private var retrying = false

    private var roots: [String] {
        model.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted()
    }
    private var deepStage: String { LocalQuickScan.isInstalled ? "deep" : "quick" }
    private var deepEnabled: Bool {
        ScanConfiguration.visionEnabled()
            && (LocalQuickScan.isInstalled || (model.remoteReady && !APIConfiguration.automaticCloudScanPaused))
    }
    private var semanticMatches: Bool { semantic.rootPaths == roots }
    private var busy: Bool {
        scan.indexing || scan.running || (semanticMatches && semantic.phase == .running)
    }
    private var issues: [ScanIssueDisplay] {
        records.flatMap { file in
            (["local"] + (deepEnabled ? [deepStage] : [])).compactMap { stage in
                let result = file.stages[stage]
                let skipped = file.deferred || result?.status == "unsupported"
                let failed = result.map { ["failed", "empty", "limited", "needs_review"].contains($0.status) } ?? false
                guard skipped || failed else { return nil }
                return ScanIssueDisplay(
                    id: file.path + ":" + stage, path: file.path, name: file.relativePath,
                    stage: stage == "local" ? "文字识别" : "深度理解", skipped: skipped,
                    reason: file.deferred ? "已按你的设置暂缓分析"
                        : (skipped ? ScanSkipItem.reason(for: file.ext, cloud: stage == "quick")
                           : (result?.error ?? "未能完成分析，可重试"))
                )
            }
        }
    }
    private var failedCount: Int { Set(issues.filter { !$0.skipped }.map(\.path)).count }
    private var skippedCount: Int { Set(issues.filter(\.skipped).map(\.path)).count }
    private var title: String {
        if roots.isEmpty { return "添加要搜索的资料夹" }
        if loadError || scan.indexFailed { return "索引需要检查" }
        if scan.userPaused { return "后台分析已暂停" }
        if scan.indexing { return "正在建立文件索引" }
        if model.isLoading && !scan.catalogReady { return "正在发现文件" }
        if !loaded { return "正在读取索引状态" }
        if scan.yieldingForSearch { return "优先响应搜索" }
        if resourcePause != nil && busy { return "等待设备空闲" }
        if busy { return "搜索已可用，分析继续中" }
        if failedCount > 0 { return "搜索已就绪，有文件待处理" }
        return records.isEmpty ? "资料夹中暂无文件" : "搜索已就绪"
    }
    private var detail: String {
        if roots.isEmpty { return "文件保留在原处，随时可以调整搜索范围。" }
        if loadError { return "暂时无法读取统计，已保留上次结果；正在自动重试。" }
        if scan.indexFailed { return "更新未完成，已保留上次可搜索的结果。" }
        if scan.userPaused { return "已完成的索引仍可搜索，继续后处理剩余内容。" }
        if scan.yieldingForSearch { return "后台分析稍后自动继续，已完成的结果会保留。" }
        if let reason = resourcePause, busy { return reason + "，恢复后自动继续。" }
        if !loaded { return "正在恢复这次所选资料夹的进度。" }
        return "\(records.count.formatted()) 个文件 · \(roots.count) 个资料夹 · 最近文件优先"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IndexingOverview(title: title, detail: detail, stages: stages,
                             paused: scan.userPaused,
                             canPause: !roots.isEmpty && (busy || scan.userPaused),
                             togglePause: { model.toggleScanning() })
            if let file = scan.currentFile, scan.running, !scan.userPaused {
                Label(file, systemImage: "doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(file)
            }
            if !issues.isEmpty || scan.indexFailed {
                HStack {
                    Button { showIssues = true } label: {
                        Label("\(failedCount) 个失败 · \(skippedCount) 个跳过", systemImage: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if failedCount > 0 || scan.indexFailed {
                        Button(retrying ? "正在重试…" : "重试失败项") {
                            retrying = true
                            model.retryScanning()
                        }
                        .disabled(retrying || scan.userPaused || scan.running || scan.indexing)
                        .controlSize(.small)
                    }
                }
                .font(.system(size: 11))
            }
            Divider()
            DisclosureGroup("搜索范围 · \(roots.count) 个资料夹", isExpanded: $showFolders) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.roots, id: \.path) { root in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(root.lastPathComponent).lineLimit(1)
                                Text(root.path).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text("\(records.filter { $0.rootPath == root.standardizedFileURL.resolvingSymlinksInPath().path }.count) 个文件")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .help(root.path)
                    }
                    Button("添加资料夹…") { model.addFolders(from: NSApp.keyWindow) }
                        .controlSize(.small)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
        }
        .sheet(isPresented: $showIssues) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("未完成的分析").font(.headline)
                    Spacer()
                    Button("完成") { showIssues = false }.keyboardShortcut(.defaultAction)
                }
                Text("按文件统计；同一个文件可能在不同阶段有记录。原文件保留，已建立的索引仍可搜索。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                List(issues) { issue in
                    HStack(alignment: .top) {
                        Image(systemName: issue.skipped ? "minus.circle" : "exclamationmark.circle")
                            .foregroundStyle(issue.skipped ? Color.secondary : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.name).lineLimit(2)
                            Text("\(issue.stage) · \(issue.reason)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: issue.path)])
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
            .frame(width: 600, height: 420)
        }
        .task(id: roots) {
            let requested = roots
            records = []; loaded = false; loadError = false
            guard !requested.isEmpty else { loaded = true; return }
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) {
                    Result { try AppDatabase.open().scanStatus(rootPaths: requested) }
                }.value
                guard !Task.isCancelled, requested == roots else { return }
                switch result {
                case .success(let files): records = files; loaded = true; loadError = false
                case .failure: loadError = true
                }
                resourcePause = BackgroundResourcePolicy.pauseReason
                if !busy { retrying = false }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }

    private var stages: [IndexingStageDisplay] {
        var index = fileStage("index", title: "文件索引", symbol: "doc.text.magnifyingglass", active: scan.indexing)
        if scan.indexing {
            index = IndexingStageDisplay(id: "index", title: "文件索引", symbol: "doc.text.magnifyingglass",
                detail: "正在整理文件名和正文，已完成部分可先搜索", status: "\(scan.indexedFiles) / \(scan.indexTotal)",
                fraction: scan.indexTotal > 0 ? scan.indexFraction : nil, active: true)
        }
        return [index,
            fileStage("local", title: "文字识别", symbol: "viewfinder", active: scan.running && scan.active == .local),
            semanticStage,
            fileStage(deepStage, title: "深度理解", symbol: "sparkles", active: scan.running && scan.active == .llm,
                      enabled: deepEnabled)]
    }

    private func fileStage(_ stage: String, title: String, symbol: String, active: Bool, enabled: Bool = true) -> IndexingStageDisplay {
        let files = records.filter { stage == "index" || (!$0.deferred && $0.stages[stage]?.status != "unsupported") }
        let completed = files.filter { ["ready", "usable", "available"].contains($0.stages[stage]?.status ?? "") }.count
        let failed = files.filter { ["failed", "empty", "limited", "needs_review"].contains($0.stages[stage]?.status ?? "") }.count
        let pending = files.filter { !["ready", "usable", "available", "failed", "empty", "limited", "needs_review"].contains($0.stages[stage]?.status ?? "") }
        let remaining = pending.count
        var detail = ""
        var status = "\(completed) / \(files.count)"
        if !enabled { status = "未启用"; detail = "基础搜索照常可用，可在下方配置模型" }
        else if !loaded { status = "读取中"; detail = "正在读取已保存的进度" }
        else if files.isEmpty { status = "无需处理"; detail = "当前没有需要此阶段处理的文件" }
        else if active && remaining == 0 && !scan.userPaused {
            status = "更新中"
            detail = "已有结果可搜索，正在更新分析"
        }
        else if remaining == 0 {
            status = failed > 0 ? "\(failed) 个待处理" : "已完成"
            detail = "\(completed) 个完成" + (failed > 0 ? " · \(failed) 个失败，可查看原因" : "")
        } else if scan.userPaused { detail = "剩余 \(remaining) 个 · 已暂停" }
        else if scan.yieldingForSearch || resourcePause != nil {
            detail = "剩余 \(remaining) 个 · " + (resourcePause ?? "搜索结束后继续")
        } else if active {
            let modelID = stage == "local" ? "" : (LocalQuickScan.isInstalled ? LocalQuickScan.model : GroqClient.scanModel)
            let keys = pending.map { ScanTiming.key(stage: stage == "local" ? "local" : "deep", ext: $0.ext, model: modelID) }
            let work = Dictionary(grouping: keys, by: { $0 }).mapValues(\.count)
            detail = "剩余 \(remaining) 个 · " + ScanTiming.label(seconds: ScanTiming.remaining(work: work))
        } else { detail = "剩余 \(remaining) 个 · 等待后台处理" }
        if enabled, loaded, stage != "index", records.count > files.count {
            detail += " · \(records.count - files.count) 个跳过"
        }
        return IndexingStageDisplay(id: stage, title: title, symbol: symbol, detail: detail, status: status,
            fraction: enabled && loaded && !files.isEmpty ? Double(completed + failed) / Double(files.count) : nil,
            active: active && !scan.userPaused && scan.yieldingForSearch == false && resourcePause == nil,
            attention: enabled && failed > 0)
    }

    private var semanticStage: IndexingStageDisplay {
        var status = "准备中"
        var detail = "让不同说法也能找到相关内容"
        var fraction: Double?
        let enabled = ScanConfiguration.semanticEnabled()
        if !enabled { status = "未启用"; detail = "全文搜索照常可用" }
        else if semanticMatches {
            if semantic.total > 0 { fraction = Double(semantic.ready) / Double(semantic.total) }
            status = "\(semantic.ready.formatted()) / \(semantic.total.formatted()) 片段"
            switch semantic.phase {
            case .checking: status = "准备中"
            case .running:
                detail = scan.userPaused ? "已暂停，继续后处理剩余片段"
                    : ScanTiming.label(seconds: ScanTiming.remaining(work: [semantic.timingKey: max(0, semantic.total - semantic.ready)]))
            case .complete: status = semantic.total == 0 ? "无需处理" : "已完成"; detail = "\(semantic.ready.formatted()) 个内容片段可按含义搜索"
            case .paused: detail = semantic.text
            case .unavailable: status = "需检查"; detail = semantic.text
            case .disabled: status = "未启用"; detail = "全文搜索照常可用"
            }
        }
        return IndexingStageDisplay(id: "semantic", title: "语义搜索", symbol: "point.3.connected.trianglepath.dotted",
            detail: detail, status: status, fraction: fraction,
            active: enabled && semanticMatches && semantic.phase == .running && !scan.userPaused,
            attention: enabled && semanticMatches && semantic.phase == .unavailable)
    }
}

private struct ScanIssueDisplay: Identifiable {
    let id: String
    let path: String
    let name: String
    let stage: String
    let skipped: Bool
    let reason: String
}
