import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
    case local
    case cloud

    var id: Self { self }
}

private enum ScanStagePage: CaseIterable, Identifiable {
    case index
    case recognition
    case understanding

    var id: Self { self }
}

struct APISettingsView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject private var scan = ScanProgress.shared
    @ObservedObject private var semantic = SemanticProgress.shared
    @AppStorage(ScanConfiguration.allowIndexGrowthKey) private var allowIndexGrowth = false
    @State private var draft = ""
    @State private var saved = false
    @State private var confirmDeepRescan = false
    @State private var selectedPage: SettingsPage = .local
    @State private var selectedStage: ScanStagePage = .index
    @State private var editingKey = false
    @State private var showRecognitionFailures = false
    @State private var showQuality = false
    @State private var models: [APIConfiguration.Model: String] = Dictionary(
        uniqueKeysWithValues: APIConfiguration.Model.allCases.map { ($0, $0.id) }
    )

    var body: some View {
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
                Label("搜索已可用", systemImage: "checkmark.circle.fill")
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
        }
    }

    private var indexDetail: some View {
        detailCard {
            stageDetailHeader(.index)
            stageProgress(.index)
            Divider()
            metricRow(
                title: "全文索引",
                icon: "text.magnifyingglass",
                value: scan.indexTotal > 0 ? "\(scan.indexedFiles) / \(scan.indexTotal)" : "等待"
            )
            metricRow(title: "语义索引", icon: "point.3.connected.trianglepath.dotted", value: semanticSummary)
            HStack {
                Button("检查语义索引") { model.updateSemanticIndex(force: true) }
                    .buttonStyle(.borderless)
                Spacer()
                Toggle("扩展容量", isOn: $allowIndexGrowth)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .onChange(of: allowIndexGrowth) { _, enabled in
                        if enabled { model.updateSemanticIndex(force: true) }
                    }
            }
        }
    }

    private var recognitionDetail: some View {
        detailCard {
            stageDetailHeader(.recognition)
            stageProgress(.recognition)
            HStack(spacing: 8) {
                compactMetric(title: "剩余", value: "\(scan.localRemaining)", color: .secondary)
                compactMetric(title: "失败", value: "\(scan.localFailed)", color: scan.localFailed > 0 ? warningAccent : Color.secondary)
            }
            if let file = scan.currentFile, scan.active == .local {
                Label(file, systemImage: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if scan.localFailed > 0 {
                DisclosureGroup("失败记录", isExpanded: $showRecognitionFailures) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(scan.failures.prefix(4)), id: \.self) { failure in
                            Text(failure).lineLimit(2)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                }
                .font(.system(size: 11))
            }
        }
    }

    private var understandingDetail: some View {
        detailCard {
            stageDetailHeader(.understanding)
            stageProgress(.understanding)

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
        if scan.userPaused { return "已暂停" }
        if scan.indexFailed { return "需处理" }
        if scan.indexing { return "索引中" }
        if scan.active == .local { return "识别中" }
        if scan.active == .llm { return "理解中" }
        if scanPreparing { return "准备中" }
        return scan.running ? "运行中" : "已完成"
    }

    private var scanStatusColor: Color {
        if scan.userPaused || scan.indexFailed { return warningAccent }
        if scan.indexing || scan.running || scanPreparing { return localAccent }
        return successAccent
    }

    private var scanDetailText: String {
        if scan.indexing { return "\(scan.indexedFiles) / \(scan.indexTotal) 个文件" }
        if scan.active == .local { return "剩余 \(scan.localRemaining) 项" }
        if scan.active == .llm { return "剩余 \(scan.llmRemaining) 项" }
        if scanPreparing { return "正在准备任务" }
        return scan.catalogCount > 0 ? "\(scan.catalogCount) 个文件" : "等待文件"
    }

    private var scanPreparing: Bool {
        !scan.userPaused && !scan.indexFailed && !scan.indexing
            && scan.indexTotal > 0 && scan.indexFraction >= 0.999
            && scan.localTotal == 0
    }

    private func followActiveStage() {
        if scan.indexing { selectedStage = .index }
        else if scan.active == .local { selectedStage = .recognition }
        else if scan.active == .llm { selectedStage = .understanding }
        else if scan.llmTotal > 0 { selectedStage = .understanding }
        else if scan.localTotal > 0 { selectedStage = .recognition }
    }

    private func stageTitle(_ stage: ScanStagePage) -> String {
        switch stage {
        case .index: return "内容索引"
        case .recognition: return "文字识别"
        case .understanding: return "深度理解"
        }
    }

    private func stageIcon(_ stage: ScanStagePage) -> String {
        switch stage {
        case .index: return "doc.text.magnifyingglass"
        case .recognition: return "viewfinder"
        case .understanding: return "sparkles"
        }
    }

    private func stageFraction(_ stage: ScanStagePage) -> Double {
        switch stage {
        case .index: return scan.indexFraction
        case .recognition: return scan.localFraction
        case .understanding: return scan.llmFraction
        }
    }

    private func stagePercent(_ stage: ScanStagePage) -> Int {
        switch stage {
        case .index: return scan.indexPercent
        case .recognition: return scan.localPercent
        case .understanding: return scan.llmPercent
        }
    }

    private func stageTotal(_ stage: ScanStagePage) -> Int {
        switch stage {
        case .index: return scan.indexTotal
        case .recognition: return scan.localTotal
        case .understanding: return scan.llmTotal
        }
    }

    private func stageFailed(_ stage: ScanStagePage) -> Int {
        switch stage {
        case .index: return scan.indexFailed ? 1 : 0
        case .recognition: return scan.localFailed
        case .understanding: return scan.llmFailed
        }
    }

    private func stageActive(_ stage: ScanStagePage) -> Bool {
        switch stage {
        case .index: return scan.indexing
        case .recognition: return scan.active == .local
        case .understanding: return scan.active == .llm
        }
    }

    private func stageDisabled(_ stage: ScanStagePage) -> Bool {
        stage == .understanding
            && (!ScanConfiguration.visionEnabled() || !LocalQuickScan.isInstalled)
    }

    private func stageCompleted(_ stage: ScanStagePage) -> Bool {
        stageTotal(stage) > 0 && stageFraction(stage) >= 0.999 && stageFailed(stage) == 0
    }

    private func stageStatus(_ stage: ScanStagePage) -> String {
        if stageDisabled(stage) { return "未启用" }
        if stage == .index, scan.indexFailed { return "失败" }
        if stageTotal(stage) == 0 { return "等待" }
        if stageCompleted(stage) { return "完成" }
        return "\(stagePercent(stage))%"
    }

    private func stageColor(_ stage: ScanStagePage) -> Color {
        if stage == .index, scan.indexFailed { return warningAccent }
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
            Text(stageStatus(stage))
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
        let value = semantic.text
        if value == "语义索引待检查" { return "待检查" }
        if value.hasPrefix("语义索引 ") { return String(value.dropFirst("语义索引 ".count)) }
        return value
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
