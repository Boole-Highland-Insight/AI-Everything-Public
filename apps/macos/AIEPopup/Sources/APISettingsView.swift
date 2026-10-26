import SwiftUI
import AIEData
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: Self { self }
}

private enum ScanStagePage: CaseIterable, Identifiable {
    case index
    case recognition
    case semantic
    case understanding

    var id: Self { self }
}

struct APISettingsView: View {
    @MainActor static let sharedProgress = IndexingProgressDisplay()
    @ObservedObject var model: SearchModel
    @ObservedObject private var scan = ScanProgress.shared
    @ObservedObject private var semantic = SemanticProgress.shared
    @StateObject private var progress: IndexingProgressDisplay
    private let observesProgress: Bool
    init(model: SearchModel, progress: IndexingProgressDisplay? = nil,
         observesProgress: Bool = true) {
        self.model = model
        self.observesProgress = observesProgress
        _progress = StateObject(wrappedValue: progress ?? Self.sharedProgress)
    }
    @AppStorage(ScanConfiguration.planKey) private var scanPlan = "deep"
    @AppStorage(ScanConfiguration.deepPausedKey) private var deepPaused = false
    @State private var changingDeep = false
    @State private var deepSettingError: String?
    @State private var draft = ""
    @State private var saved = false
    @State private var confirmDeepRescan = false
    @State private var selectedPage: SettingsPage = .local
    @State private var selectedStage: ScanStagePage = .index
    @State private var editingKey = false
    @State private var showRecognitionFailures = false
    @State private var recognitionSkipError: String?
    @State private var showUnderstandingFailures = false
    @State private var understandingSkipError: String?
    @State private var showQuality = false
    @AppStorage("aie.search.automaticRerank") private var automaticRerank = true
    @AppStorage("aie.search.cloudJev") private var cloudJev = false
    @State private var models: [APIConfiguration.Model: String] = Dictionary(
        uniqueKeysWithValues: APIConfiguration.Model.allCases.map { ($0, $0.id) }
    )

    var body: some View {
        settingsContent
        .task(id: progressRequest) {
            if observesProgress { await progress.observe(roots: progressRoots, id: progressRequest) }
        }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(headerStatusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(headerStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(headerStatusColor.opacity(0.12), in: Capsule())
                }

                Picker("设置页面", selection: $selectedPage) {
                    Label("本机", systemImage: "desktopcomputer")
                        .tag(SettingsPage.local)
                    Label("云端", systemImage: "cloud")
                        .tag(SettingsPage.cloud)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if selectedPage == .local {
                    localSection
                } else {
                    cloudSection
                }
            }
            .font(.system(size: 13))
            .padding(18)
        }
        .frame(width: 410)
        .frame(maxHeight: 520)
        .tint(pageAccent)
        .onAppear(perform: followActiveStage)
        .onChange(of: scan.indexing) { _, indexing in
            if indexing { selectedStage = .index }
        }
        .onChange(of: scan.active) { _, lane in
            switch lane {
            case .local: selectedStage = .recognition
            case .llm: selectedStage = .understanding
            case .none: break
            }
        }
        .onChange(of: semantic.phase) { _, phase in
            if phase == .running { selectedStage = .semantic }
        }
        .confirmationDialog(
            "重新扫描全部支持的文件？",
            isPresented: $confirmDeepRescan,
            titleVisibility: .visible
        ) {
            Button("开始后台深度扫描") { model.rescanAllLocally() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧云端摘要会保留；本机深度扫描成功后，搜索优先使用新结果。原文件不会被修改。")
        }
    }

    // MARK: - 本机

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: scanPreparing ? "ellipsis.circle" : (scan.running || scan.indexing ? "waveform" : "checkmark.circle.fill"))
                    .foregroundStyle(scan.running || scan.indexing || scanPreparing ? localAccent : successAccent)
                Text("后台分析")
                    .fontWeight(.semibold)
                Spacer()
                Text(scanDetailText)
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            stageStepper
            selectedStageDetail

            HStack {
                Label(counts(.index).ready > 0 ? "已有内容可搜索" : "正在准备基础索引", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if scan.running || scan.userPaused {
                    Button {
                        model.toggleScanning()
                    } label: {
                        Label(
                            scan.userPaused ? "继续" : "暂停",
                            systemImage: scan.userPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Toggle("本地增强（DeepScan + BGE Top5）", isOn: $automaticRerank)
                .font(.system(size: 11))
                .disabled(cloudJev)
            if !AIEApplicationPaths.isCleanV2 {
                Toggle("改用云端 Jev（需 Key，会发送查询及候选内容）", isOn: $cloudJev)
                    .font(.system(size: 11))
            }
        }
    }

    private var stageStepper: some View {
        HStack(spacing: 5) {
            ForEach(Array(ScanStagePage.allCases.enumerated()), id: \.element) { index, stage in
                stageButton(stage)
                if index < ScanStagePage.allCases.count - 1 {
                    Capsule()
                        .fill(stageConnectorColor(after: stage))
                        .frame(height: 2)
                        .offset(y: -11)
                }
            }
        }
    }

    private func stageButton(_ stage: ScanStagePage) -> some View {
        let selected = selectedStage == stage
        let color = stageColor(stage)
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selectedStage = stage }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(color.opacity(selected ? 0.2 : 0.1))
                    Circle().stroke(selected ? color.opacity(0.7) : .clear, lineWidth: 1)
                    Image(systemName: stageCompleted(stage) ? "checkmark" : stageIcon(stage))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 30, height: 30)

                Text(stageTitle(stage))
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)

                HStack(spacing: 3) {
                    Text(stageStatus(stage))
                    if stageFailed(stage) > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("\(stageFailed(stage))")
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stageFailed(stage) > 0 ? warningAccent : color)
            }
            .frame(width: 82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stageTitle(stage))
        .accessibilityValue(stageStatus(stage))
    }

    @ViewBuilder private var selectedStageDetail: some View {
        switch selectedStage {
        case .index: indexDetail
        case .recognition: recognitionDetail
        case .understanding: understandingDetail
        case .semantic: semanticDetail
        }
    }

    private var deepUnderstandingControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("后台深度理解（本地 8B）", isOn: Binding(
                get: { scanPlan == LocalScanPlan.deep.rawValue },
                set: { enabled in
                    deepSettingError = nil
                    if !enabled {
                        ScanConfiguration.setBackgroundUnderstanding(false)
                        return
                    }
                    changingDeep = true
                    Task { @MainActor in
                        let ready = await LocalQuickScan.shared.activate(LocalQuickScan.preferredModel)
                        changingDeep = false
                        if ready { ScanConfiguration.setBackgroundUnderstanding(true) }
                        else { deepSettingError = "本地 8B 尚未安装，请在“深度理解 → 本机模型”中配置。" }
                    }
                }
            )).toggleStyle(.switch).disabled(changingDeep)
            HStack {
                if !understandingFailedFiles.isEmpty {
                    Button(deepStatus) {
                        withAnimation { showUnderstandingFailures.toggle() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Text(deepStatus).foregroundStyle(.secondary)
                }
                Spacer()
                if scanPlan == LocalScanPlan.deep.rawValue {
                    Button(deepPaused ? "继续 8B" : "暂停 8B") {
                        ScanConfiguration.pauseBackgroundUnderstanding(!deepPaused)
                    }.buttonStyle(.borderless)
                    if !understandingFailedFiles.isEmpty {
                        Button("重试失败项") { model.retryDeepUnderstanding() }
                            .disabled(deepPaused || scan.userPaused || scan.running)
                    }
                }
            }.font(.system(size: 11))
            if scanPlan == LocalScanPlan.deep.rawValue {
                Text(progressLoaded ? "8B 文件分析：" + counts(.understanding).summary : "正在读取当前版本的 8B 分析状态")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if scan.active == .llm, let file = scan.currentFile {
                    Text(file).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let error = deepSettingError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Text("关闭或暂停后，当前文件安全收尾；已保存分析继续可搜，Gemma 基础索引不受影响。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var progressRoots: [String] {
        model.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted()
    }
    private var progressRequest: String {
        progressRoots.joined(separator: "\n")
    }
    private var progressLoaded: Bool { progress.matches(progressRequest) }
    private var semanticLoaded: Bool { progress.semanticMatches(progressRequest) }
    private var discovered: Int { progressRoots.isEmpty ? 0 : max(scan.catalogCount, model.files.count) }
    private var parsingPending: Bool {
        !progressLoaded || scan.catalogDiscovering || scan.indexing || scan.indexFailed
            || !scan.catalogReady || !progress.count("index", discovered: discovered).settled
    }
    private func counts(_ stage: ScanStagePage) -> IndexingStageCount {
        switch stage {
        case .index: return progress.count("index", discovered: discovered)
        case .recognition:
            var value = progress.count("local", discovered: discovered)
            value.pending = max(0, value.pending - recognitionSkippedFiles.filter { !$0.deferred }.count)
            value.deferred = max(0, value.deferred - recognitionSkippedFiles.filter { $0.deferred }.count)
            value.running = value.running || (scan.active == .local && scan.currentFile != nil && scan.running)
            return value
        case .understanding:
            var value = progress.count("deep", discovered: discovered)
            value.pending = max(0, value.pending - understandingSkippedFiles.filter { !$0.deferred }.count)
            value.deferred = max(0, value.deferred - understandingSkippedFiles.filter { $0.deferred }.count)
            value.running = value.running || (scan.active == .llm && scan.currentFile != nil && scan.running)
            return value
        case .semantic:
            var value = progress.semanticCount
            value.running = semantic.rootPaths == progressRoots && semantic.phase == .running
            return value
        }
    }
    private func upstreamPending(_ stage: ScanStagePage) -> Bool {
        if stage == .semantic { return false }
        if stage == .index { return scan.catalogDiscovering || scan.indexing || !scan.catalogReady }
        if parsingPending { return true }
        return stage == .understanding && !counts(.recognition).settled
    }
    private var deepStatus: String {
        if changingDeep { return "正在检查本地模型" }
        if scanPlan != LocalScanPlan.deep.rawValue {
            return QuickScanner.isBusy ? "已关闭 · 当前任务正在收尾" : "未启用"
        }
        if deepPaused || scan.userPaused {
            return QuickScanner.isBusy ? "暂停中 · 当前任务正在收尾" : "已暂停"
        }
        if !LocalQuickScan.isInstalled { return "等待中 · 本地模型未就绪" }
        if scan.yieldingForSearch { return "等待中 · 优先响应搜索" }
        return counts(.understanding).status(upstreamPending: upstreamPending(.understanding),
                                            paused: false, loaded: progressLoaded)
    }

    private var indexDetail: some View {
        detailCard {
            stageDetailHeader(.index)
            stageProgress(.index)
            Divider()
            metricRow(
                title: "全文索引",
                icon: "text.magnifyingglass",
                value: progressLoaded ? "已发现 \(discovered) · 已落库 \(counts(.index).ready)"
                    : "已发现 \(discovered) · 已落库统计中"
            )
            Text("提取文件名、路径和直接文本并建立全文索引；已完成部分可搜索。OCR 等识别结果就绪后继续补入，不代表所有页面均已覆盖。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var recognitionSkippedFiles: [FileScanStatus] {
        guard progressLoaded else { return [] }
        return progress.snapshot?.files.filter { $0.stages["local"]?.status == "skipped" } ?? []
    }

    private var recognitionSkippedCount: Int { recognitionSkippedFiles.count }

    private var recognitionFailedFiles: [FileScanStatus] {
        guard progressLoaded else { return [] }
        return progress.snapshot?.files.filter {
            ["failed", "empty", "limited", "needs_review"].contains($0.stages["local"]?.status ?? "")
        } ?? []
    }

    private func skipRecognition(_ file: FileScanStatus) {
        do {
            let db = try AppDatabase.open()
            try db.skipRecognitionTask(path: file.path, versionID: file.versionID, rootPaths: progressRoots)
            progress.snapshot = try db.indexingFileSnapshot(rootPaths: progressRoots)
            recognitionSkipError = nil
        } catch { recognitionSkipError = "无法跳过：\(error)" }
    }

    private var recognitionDetail: some View {
        detailCard {
            stageDetailHeader(.recognition)
            stageProgress(.recognition)
            HStack(spacing: 8) {
                compactMetric(title: "待处理", value: progressLoaded ? "\(counts(.recognition).pending)" : "统计中", color: .secondary)
                compactMetric(title: "失败", value: progressLoaded ? "\(counts(.recognition).failed)" : "统计中", color: counts(.recognition).failed > 0 ? warningAccent : Color.secondary)
                compactMetric(title: "已跳过", value: progressLoaded ? "\(recognitionSkippedCount)" : "统计中", color: .secondary)
            }
            Text(progressLoaded ? counts(.recognition).summary : "正在读取当前文件版本的识别状态")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("包含 OCR、视觉分类、文字分析及转录，按当前版本文件计数；PDF 识别不代表逐页全覆盖。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if upstreamPending(.recognition) {
                Text("文件解析仍在继续，待处理数量会增加。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let file = scan.currentFile, scan.active == .local {
                Label(file, systemImage: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !recognitionFailedFiles.isEmpty {
                DisclosureGroup("失败记录", isExpanded: $showRecognitionFailures) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recognitionFailedFiles, id: \.versionID) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .help(file.relativePath)
                                Text(file.stages["local"]?.error ?? "内容识别失败")
                                    .lineLimit(2)
                                    .help(file.stages["local"]?.error ?? "内容识别失败")
                                HStack(spacing: 8) {
                                    Button("打开文件") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                    }
                                    .help("在Finder中定位此文件")
                                    Button("跳过") { skipRecognition(file) }
                                        .help("跳过此文件当前版本的内容识别")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
                .font(.system(size: 11))
            }
            if let recognitionSkipError {
                Text(recognitionSkipError).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private var understandingSkippedFiles: [FileScanStatus] {
        guard progressLoaded else { return [] }
        return progress.snapshot?.files.filter { $0.stages["deep"]?.status == "skipped" } ?? []
    }

    private var understandingSkippedCount: Int { understandingSkippedFiles.count }

    private var understandingFailedFiles: [FileScanStatus] {
        guard progressLoaded else { return [] }
        return progress.snapshot?.files.filter {
            ["failed", "empty", "limited", "needs_review"].contains($0.stages["deep"]?.status ?? "")
        } ?? []
    }

    private func skipUnderstanding(_ file: FileScanStatus) {
        do {
            let db = try AppDatabase.open()
            try db.skipDeepUnderstandingTask(path: file.path, versionID: file.versionID, rootPaths: progressRoots)
            progress.snapshot = try db.indexingFileSnapshot(rootPaths: progressRoots)
            understandingSkipError = nil
        } catch { understandingSkipError = "无法跳过：\(error)" }
    }

    private var understandingDetail: some View {
        detailCard {
            stageDetailHeader(.understanding)
            stageProgress(.understanding)
            deepUnderstandingControl

            if !understandingFailedFiles.isEmpty {
                DisclosureGroup("失败记录", isExpanded: $showUnderstandingFailures) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(understandingFailedFiles, id: \.versionID) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(URL(fileURLWithPath: file.path).lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .help(file.relativePath)
                                Text(file.stages["deep"]?.error ?? "8B深度理解失败")
                                    .lineLimit(2)
                                    .help(file.stages["deep"]?.error ?? "8B深度理解失败")
                                HStack(spacing: 8) {
                                    Button("打开文件") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                    }
                                    .help("在Finder中定位此文件")
                                    Button("跳过") { skipUnderstanding(file) }
                                        .help("仅跳过此文件当前版本的8B深度理解")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
                .font(.system(size: 11))
            }
            if understandingSkippedCount > 0 {
                Text("已跳过 \(understandingSkippedCount) 项8B深度理解")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let understandingSkipError {
                Text(understandingSkipError).font(.system(size: 11)).foregroundStyle(.orange)
            }

            Button { DeviceSetup.shared.present() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "cpu")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本机模型").foregroundStyle(.primary)
                        Text(LocalQuickScan.isInstalled ? LocalQuickScan.displayName : "尚未配置")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            DisclosureGroup(isExpanded: $showQuality) {
                qualityDetails.padding(.top, 6)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: summaryIssueCount == 0 ? "checkmark.seal.fill" : "arrow.clockwise.circle.fill")
                        .foregroundStyle(summaryIssueCount == 0 ? successAccent : warningAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分析结果")
                        Text(qualityStatusText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .font(.system(size: 11))

            HStack {
                Button("重新分析全部") { confirmDeepRescan = true }
                    .disabled(
                        !LocalQuickScan.isInstalled || !ScanConfiguration.visionEnabled()
                            || scan.running || model.files.isEmpty
                    )
                Spacer()
                Button("重新生成问题摘要") { model.repairSummaries() }
                    .disabled(
                        scan.running || summaryIssueCount == 0
                            || (!model.remoteReady && !LocalQuickScan.isInstalled)
                    )
            }
            .controlSize(.small)
        }
    }

    private var semanticDetail: some View {
        detailCard {
            stageDetailHeader(.semantic)
            stageProgress(.semantic)
            metricRow(
                title: "语义索引进度",
                icon: "point.3.connected.trianglepath.dotted",
                value: semanticSummary
            )
            Text(upstreamPending(.semantic)
                 ? "Gemma 编码原文、转录和视觉内容。上游仍在产生新内容，向量目标总数会增加；已有向量可搜索。"
                 : "Gemma 向量目标：已完成 \(counts(.semantic).ready)，待完成 \(counts(.semantic).pending)，失败 \(counts(.semantic).failed)。此计数不是 8B 文件分析进度。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("检查语义索引") { model.updateSemanticIndex(force: true) }
                .buttonStyle(.borderless)
        }
    }

    // MARK: - 云端增强

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard {
                HStack(spacing: 11) {
                    settingsIcon("key.fill", color: model.remoteReady ? successAccent : cloudAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenRouter Key").fontWeight(.semibold)
                        Text(model.remoteReady ? "已保存在这台 Mac" : "添加后即可使用云端模型")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.remoteReady {
                        Button("更新 OpenRouter Key") { editingKey = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if !model.remoteReady || editingKey {
                    SecureField("粘贴 OpenRouter Key（sk-or-…）", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    HStack {
                        Link("获取 OpenRouter Key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                            .foregroundStyle(cloudAccent)
                        Spacer()
                        if editingKey {
                            Button("取消") { editingKey = false; draft = "" }
                                .buttonStyle(.borderless)
                        }
                        Button("保存 Key", action: saveKey)
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || GroqClient.usesEnvironmentKey
                            )
                    }
                }

                if GroqClient.usesEnvironmentKey {
                    Text("当前使用启动环境中的 OPENROUTER_API_KEY。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = model.remoteSettingsError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                } else if saved {
                    Text("Key 已保存；尚未验证余额和模型权限。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            settingsCard {
                HStack(spacing: 11) {
                    settingsIcon("cpu", color: cloudAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("云端模型").fontWeight(.semibold)
                        Text("选择后自动保存")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                ForEach(Array(cloudModelRoles.enumerated()), id: \.element) { index, role in
                    if index > 0 { Divider() }
                    modelPickerRow(role)
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(cloudAccent)
                    .frame(width: 18)
                Text(LocalQuickScan.isInstalled || APIConfiguration.automaticCloudScanPaused
                    ? "后台扫描在本机完成。云端搜索只发送查询和候选片段，不上传完整文件；调用费用由你的 OpenRouter 账户承担。"
                    : "云端扫描可能发送文字摘录、缩小图片或视频抽帧；调用费用由你的 OpenRouter 账户承担。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            if model.remoteReady && !GroqClient.usesEnvironmentKey {
                HStack {
                    Spacer()
                    Button("移除 OpenRouter Key", role: .destructive) {
                        saved = false
                        editingKey = false
                        if model.clearRemoteKey() { draft = "" }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private var qualityDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("这里检查的是 AI 分析结果，不代表原文件损坏。")
                .foregroundStyle(.secondary)

            HStack {
                Text("摘要需重新生成")
                Spacer()
                Text("\(summaryIssueCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(summaryIssueCount == 0 ? successAccent : warningAccent)
            }
            if summaryIssueCount > 0 {
                Text("摘要为空、只重复文件名，或仍是占位提示。")
                    .foregroundStyle(.secondary)
                ForEach(Array(summaryIssueFiles.prefix(3)), id: \.path) { file in
                    HStack(spacing: 6) {
                        Circle().fill(warningAccent).frame(width: 4, height: 4)
                        Text(file.name).lineLimit(1)
                    }
                }
            }

            Divider()
            HStack {
                Text("内容覆盖有限")
                Spacer()
                Text("\(contentIssueCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if contentIssueCount > 0 {
                Text("常见于 PDF、图片、音频和视频：当前只覆盖可提取文字、OCR、转写或抽帧。这是范围说明，不是扫描失败。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 10))
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func settingsIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.12))
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 34, height: 34)
    }

    private func modelPickerRow(_ role: APIConfiguration.Model) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(.system(size: 11, weight: .medium))
                Text(role.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker(role.title, selection: modelSelection(for: role)) {
                ForEach(modelOptions(for: role)) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 172, alignment: .trailing)
        }
        .frame(minHeight: 35)
    }

    private func modelSelection(for role: APIConfiguration.Model) -> Binding<String> {
        Binding(
            get: { models[role] ?? role.id },
            set: { value in
                models[role] = value
                role.save(value)
                model.refresh()
            }
        )
    }

    private func modelOptions(for role: APIConfiguration.Model) -> [APIConfiguration.ModelOption] {
        var options = role.options
        let current = models[role] ?? role.id
        if !options.contains(where: { $0.id == current }) {
            let name = current.split(separator: "/").last.map(String.init) ?? current
            options.insert(APIConfiguration.ModelOption(title: "当前 · \(name)", id: current), at: 0)
        }
        return options
    }

    private func saveKey() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !GroqClient.usesEnvironmentKey else { return }
        saved = model.saveRemoteKey(draft)
        if saved { draft = ""; editingKey = false }
    }

    private var headerStatusText: String {
        selectedPage == .local ? scanStatusText : (model.remoteReady ? "Key 已设置" : "未设置 Key")
    }

    private var headerStatusColor: Color {
        selectedPage == .local ? scanStatusColor : (model.remoteReady ? successAccent : Color.secondary)
    }

    private var localAccent: Color { Color.accentColor }
    private var cloudAccent: Color { Color.accentColor }
    private var successAccent: Color { Color.green }
    private var warningAccent: Color { Color.orange }

    private var pageAccent: Color { selectedPage == .local ? localAccent : cloudAccent }

    private var cloudModelRoles: [APIConfiguration.Model] { [.scan, .reuse, .image] }

    private var scanStatusText: String {
        if progress.failed || scan.indexFailed { return "需检查" }
        if scan.userPaused { return "已暂停" }
        if scan.catalogDiscovering { return "发现文件中" }
        if parsingPending { return "解析中" }
        if !counts(.recognition).settled { return "识别待完成" }
        if ScanConfiguration.semanticEnabled(), !semanticLoaded || !counts(.semantic).settled { return "语义索引中" }
        return scanPlan == "deep" && !counts(.understanding).settled ? "基础搜索就绪" : "已就绪"
    }
    private var scanStatusColor: Color {
        if progress.failed || scan.indexFailed || scan.userPaused { return warningAccent }
        if parsingPending || !counts(.recognition).settled
            || (ScanConfiguration.semanticEnabled() && (!semanticLoaded || !counts(.semantic).settled)) { return localAccent }
        return successAccent
    }
    private var scanDetailText: String {
        if scan.catalogDiscovering { return "正在发现文件" }
        return progressLoaded ? "已发现 \(discovered) · 基础索引 \(counts(.index).ready)"
            : "已发现 \(discovered) · 基础索引统计中"
    }
    private var scanPreparing: Bool { !progressLoaded || parsingPending || !counts(.recognition).settled || (ScanConfiguration.semanticEnabled() && (!semanticLoaded || !counts(.semantic).settled)) }

    private func followActiveStage() {
        if scan.indexing { selectedStage = .index }
        else if scan.active == .local { selectedStage = .recognition }
        else if scan.active == .llm { selectedStage = .understanding }
        else if semantic.phase == .running || semantic.total > 0 { selectedStage = .semantic }
        else if scan.llmTotal > 0 { selectedStage = .understanding }
        else if scan.localTotal > 0 { selectedStage = .recognition }
    }

    private func stageTitle(_ stage: ScanStagePage) -> String {
        switch stage {
        case .index: return "文件解析"
        case .recognition: return "内容识别"
        case .understanding: return "深度理解"
        case .semantic: return "语义索引"
        }
    }

    private func stageIcon(_ stage: ScanStagePage) -> String {
        switch stage {
        case .index: return "doc.text.magnifyingglass"
        case .recognition: return "viewfinder"
        case .understanding: return "sparkles"
        case .semantic: return "point.3.connected.trianglepath.dotted"
        }
    }

    private func stageFraction(_ stage: ScanStagePage) -> Double {
        guard stage == .semantic ? semanticLoaded : progressLoaded else { return 0 }
        if stage == .recognition || (stage == .understanding && understandingSkippedCount > 0) {
            let value = counts(stage)
            let skipped = stage == .recognition ? recognitionSkippedCount : understandingSkippedCount
            let total = value.total + skipped
            let fraction = total > 0 ? Double(value.ready + skipped) / Double(total) : 0
            return stageCompleted(stage) ? fraction : min(0.99, fraction)
        }
        let fraction = counts(stage).fraction
        return stageCompleted(stage) ? fraction : min(0.99, fraction)
    }
    private func stagePercent(_ stage: ScanStagePage) -> Int {
        min(stageCompleted(stage) ? 100 : 99, Int((stageFraction(stage) * 100).rounded(.down)))
    }
    private func stageTotal(_ stage: ScanStagePage) -> Int {
        if stage == .recognition { return counts(stage).total + recognitionSkippedCount }
        if stage == .understanding { return counts(stage).total + understandingSkippedCount }
        return stage == .index ? discovered : counts(stage).total
    }
    private func stageFailed(_ stage: ScanStagePage) -> Int {
        if stage == .index && scan.indexFailed { return max(1, counts(stage).failed) }
        if stage == .semantic && semantic.rootPaths == progressRoots && semantic.phase == .unavailable { return max(1, counts(stage).failed) }
        return counts(stage).failed
    }

    private func stageActive(_ stage: ScanStagePage) -> Bool {
        switch stage {
        case .index: return scan.indexing
        case .recognition: return scan.active == .local
        case .understanding: return scan.active == .llm
        case .semantic: return semantic.phase == .running
        }
    }

    private func stageDisabled(_ stage: ScanStagePage) -> Bool {
        switch stage {
        case .understanding:
            return !ScanConfiguration.visionEnabled() || !LocalQuickScan.isInstalled
        case .semantic:
            return !ScanConfiguration.semanticEnabled()
        default:
            return false
        }
    }

    private func stageCompleted(_ stage: ScanStagePage) -> Bool {
        (stage == .semantic ? semanticLoaded : progressLoaded) && !stageDisabled(stage) && !upstreamPending(stage)
            && (counts(stage).total > 0 || (stage == .recognition && recognitionSkippedCount > 0)
                || (stage == .understanding && understandingSkippedCount > 0))
            && counts(stage).settled && stageFailed(stage) == 0
            && !(stage == .understanding && deepPaused)
    }
    private func stageStatus(_ stage: ScanStagePage) -> String {
        if stage == .understanding { return deepStatus }
        if stageDisabled(stage) { return "未启用" }
        if stage == .recognition && progressLoaded && counts(stage).running { return "处理中" }
        if (stage != .semantic && progress.failed) || stageFailed(stage) > 0 { return "需检查" }
        if stage == .semantic && stageCompleted(stage) { return "100% · 已完成" }
        if stage == .recognition && stageCompleted(stage) { return "100% · 已完成" }
        if stage == .index, scan.catalogDiscovering { return "发现中" }
        if stage == .index, scan.indexing { return progressLoaded ? "\(stagePercent(stage))%" : "统计中" }
        return counts(stage).status(upstreamPending: upstreamPending(stage),
                                    paused: scan.userPaused, loaded: stage == .semantic ? semanticLoaded : progressLoaded)
    }

    private func stageColor(_ stage: ScanStagePage) -> Color {
        if stageDisabled(stage) { return .secondary }
        if stageFailed(stage) > 0 || progress.failed { return warningAccent }
        if stageCompleted(stage) { return successAccent }
        if stageActive(stage) { return localAccent }
        return .secondary
    }

    private func stageConnectorColor(after stage: ScanStagePage) -> Color {
        stageCompleted(stage) ? successAccent.opacity(0.55) : Color.primary.opacity(0.12)
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            content()
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func stageDetailHeader(_ stage: ScanStagePage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: stageCompleted(stage) ? "checkmark.circle.fill" : stageIcon(stage))
                .foregroundStyle(stageColor(stage))
            Text(stageTitle(stage)).fontWeight(.semibold)
            Spacer()
            if stageFailed(stage) > 0 {
                Label("\(stageFailed(stage))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(warningAccent)
            }
            Group {
                if stage == .understanding, !understandingFailedFiles.isEmpty {
                    Button(stageStatus(stage)) {
                        withAnimation { showUnderstandingFailures.toggle() }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(stageStatus(stage))
                }
            }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stageColor(stage))
        }
    }

    @ViewBuilder private func stageProgress(_ stage: ScanStagePage) -> some View {
        if !stageDisabled(stage) {
            ProgressView(value: stageTotal(stage) == 0 ? 0 : stageFraction(stage), total: 1)
                .progressViewStyle(.linear)
                .tint(stageColor(stage))
        }
    }

    private func metricRow(title: String, icon: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func compactMetric(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var semanticSummary: String {
        guard semanticLoaded else { return "统计中" }
        let value = counts(.semantic)
        return "\(value.ready.formatted()) / \(value.total.formatted())"
    }

    private var summaryIssueFiles: [IndexedFile] {
        model.files.filter { $0.summaryIssue != nil }
    }

    private var summaryIssueCount: Int {
        model.files.filter { $0.summaryIssue != nil }.count
    }

    private var contentIssueCount: Int {
        model.files.filter { $0.contentIssue != nil }.count
    }

    private var qualityStatusText: String {
        if summaryIssueCount > 0 {
            return "\(summaryIssueCount) 个摘要需重新生成 · \(contentIssueCount) 个文件覆盖有限"
        }
        if contentIssueCount > 0 { return "摘要正常 · \(contentIssueCount) 个文件覆盖有限" }
        return "摘要和内容覆盖均正常"
    }
}
