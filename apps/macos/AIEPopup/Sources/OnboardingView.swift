import SwiftUI

struct OnboardingView: View {
    @ObservedObject var setup: DeviceSetup
    var autoplayDemo = true
    @ObservedObject private var photoLibrary = PhotoLibrarySync.shared
    @ObservedObject private var shortcut = SearchShortcutSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if setup.firstRun, setup.step != .welcome {
                HStack(spacing: 7) {
                    Text(setup.step.title)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    ForEach(0..<DeviceSetupStep.allCases.count, id: \.self) { index in
                        Capsule()
                            .fill(index <= setup.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.18))
                            .frame(width: index == setup.step.rawValue ? 24 : 7, height: 7)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: setup.step)
                    }

                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
            }

            GeometryReader { geometry in
                ScrollView {
                    Group {
                        switch setup.step {
                        case .welcome: welcome
                        case .device: device
                        case .plan: plans
                        case .source: sources
                        case .cloud: cloud
                        case .usage: usage
                        case .preparing: preparing
                        case .ready: ready
                        }
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: max(0, geometry.size.height - 44),
                        alignment: pageAlignment
                    )
                    .padding(.horizontal, 34)
                    .padding(.vertical, 22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollIndicators(.visible)
            }

            if setup.step != .preparing {
                Divider().padding(.horizontal, 28)
                footer
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("AI Everything")
                    .font(.system(size: 28, weight: .semibold))
                Text("搜索文件，也让旧内容有新的可能。")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            OnboardingDemoView(active: setup.firstRun, autoplay: autoplayDemo)

            HStack(alignment: .top, spacing: 18) {
                welcomeFeature("text.magnifyingglass", title: "按含义搜索",
                               detail: "不必记住文件名\n描述内容就能找")
                Divider().frame(height: 80)
                welcomeFeature("arrow.triangle.2.circlepath", title: "静默后台解析",
                               detail: "增量更新，随时暂停\n下次接着处理")
                Divider().frame(height: 80)
                welcomeFeature("sparkles", title: "咔哒再利用",
                               detail: "补全、优化与再创作\n对比新旧，继续修改")
            }

            Label("本机索引 · 原件保留 · 再创作按需连接云端", systemImage: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private func welcomeFeature(_ symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 20)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var device: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle("检测这台 Mac", detail: "只读取芯片、内存、系统版本和可用空间，不查看个人文件。")
            if let p = setup.profile {
                VStack(spacing: 0) {
                    metric("芯片", p.chip, symbol: "cpu")
                    Divider().padding(.leading, 42)
                    metric("内存", "\(p.memoryGiB) GB", symbol: "memorychip")
                    Divider().padding(.leading, 42)
                    metric("可用空间", p.freeGB.map { "\($0) GB" } ?? "无法读取", symbol: "internaldrive")
                    Divider().padding(.leading, 42)
                    metric("系统", p.os, symbol: "macwindow")
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
                Text(p.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                ProgressView("正在检测设备…")
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private var plans: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle(
                "选择扫描方案",
                detail: "Gemma 负责文字与视觉索引；本地 8B 可在后台补充内容理解。"
            )
            if AIEApplicationPaths.isCleanV2 {
                Toggle("开启后台深度理解（本地 8B）", isOn: Binding(
                    get: { setup.selectedPlan == .deep },
                    set: { setup.selectedPlan = $0 ? .deep : .semantic }
                ))
                .toggleStyle(.checkbox)
                Text("可取消；Gemma、全文索引和 OCR 仍可使用。首次使用默认开启，之后保留你的选择。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(setup.selectedPlanInstalled ? "所选模型已安装" : "继续后安装所选模型")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
            ForEach(LocalScanPlan.allCases) { plan in
                Button {
                    setup.selectedPlan = plan
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: setup.selectedPlan == plan ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(setup.selectedPlan == plan ? Color.accentColor : Color.secondary)
                            .font(.system(size: 18))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Text(plan.title).font(.system(size: 14, weight: .semibold))
                                if plan == .deep {
                                    Text("推荐").badgeStyle()
                                }
                                Spacer(minLength: 4)
                                Text(planSize(plan))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(plan.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(planRows(plan), id: \.self) { row in
                                    Text(row)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(13)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Color.primary.opacity(setup.selectedPlan == plan ? 0.055 : 0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(Color.primary.opacity(setup.selectedPlan == plan ? 0.3 : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .disabled(setup.installing)
            }
            }
            installStatus
            if setup.selectedPlan == .deep, setup.profile?.appleSilicon == false {
                Label("Intel 运行 8B 可能较慢；想减少后台占用，可以选择语义索引。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("选择内容来源", detail: "选择要建立资料库的文件夹或照片图库。不需要完全磁盘访问权限。")
            if !setup.selectedFolders.isEmpty {
                Label(
                    "原文件保留在原处。已有扫描结果会继续使用，只处理新增或变化的内容。",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Button {
                setup.chooseFolders()
            } label: {
                Label(setup.selectedFolders.isEmpty ? "选择文件夹…" : "添加更多文件夹…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            Button {
                photoLibrary.connect(startImmediately: false) { setup.addPhotoLibraryRoot($0) }
            } label: {
                Label(photoLibrary.connected ? "照片图库已连接" : "连接照片图库…", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(photoLibrary.busy || photoLibrary.connected)

            Toggle("允许从 iCloud 下载待分析照片", isOn: $photoLibrary.downloadFromICloud)
                .font(.system(size: 12))
            if setup.selectedFolders.isEmpty {
                Text("至少选择一个文件夹，或先连接照片图库。AI Everything 只会索引这里列出的来源。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(setup.selectedFolders, id: \.path) { url in
                            HStack {
                                Image(systemName: PhotoImport.contains(url.path) ? "photo.stack.fill" : "folder.fill")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).fontWeight(.medium)
                                    Text(url.path).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer()
                                Button { setup.removeFolder(url) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                        }
                    }
                }
                .frame(height: min(CGFloat(setup.selectedFolders.count) * 58, 250))
            }
            Text(photoLibrary.status.isEmpty
                 ? "照片图库只需授权一次，之后会在后台增量同步；最近拍摄的照片优先。"
                 : photoLibrary.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("云端增强（可选）", detail: "不填也能正常使用：搜索、打开和本机分析全部在这台 Mac 上完成。")

            if setup.cloudKeyFromEnvironment {
                Label("当前使用启动环境中的 OPENROUTER_API_KEY。", systemImage: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if setup.cloudKeyConfigured {
                Label("已配置 API Key，可继续下一步。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                SecureField("粘贴 OpenRouter API Key（sk-or-…）", text: $setup.cloudKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { setup.saveCloudKey() }
                HStack {
                    Link("前往 openrouter.ai 获取 Key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                    Spacer()
                    Button("保存 Key") { setup.saveCloudKey() }
                        .disabled(setup.cloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = setup.cloudKeyError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("填写后可使用：").font(.system(size: 12, weight: .medium))
                Label("Jev 自动整理：搜索时判断候选是否真正相关", systemImage: "scope")
                Label("候选整理：自动扩大范围，再由 Jev 判断可能结果", systemImage: "magnifyingglass.circle")
                Label("咔哒：对你选中的文件生成新版本或补全内容", systemImage: "sparkles")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Text("调用费用由你的 OpenRouter 账户承担。Key 只保存在这台 Mac，可随时在设置中移除。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle("随时找到你的内容", detail: "搜索窗口关闭后，应用会留在菜单栏，后台索引继续。")
            SearchShortcutPicker()
            Label(setup.shortcutPracticed ? "快捷键测试成功" : "现在按一下所选快捷键，试试能否唤起应用",
                  systemImage: setup.shortcutPracticed ? "checkmark.circle.fill" : "keyboard")
                .font(.system(size: 12))
                .foregroundStyle(setup.shortcutPracticed ? Color.green : Color.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                usageRow("输入", "文件名、关键词，或用一句话描述要找的内容")
                usageRow("↑ ↓ 选择 · ↩ 打开", "选中结果后打开；PDF 和视频优先定位到命中位置")
                usageRow("空格 · ⌘ ↩", "查看选中内容 · 在访达中显示原文件")
                usageRow("输入框内 ↩", "确认当前搜索；可能结果会继续补充，并由 Jev 自动整理")
                usageRow("Esc", "收起搜索；点击菜单栏 AIE 可再次打开")
            }
            Divider()
            LaunchAtLoginToggle()
        }
    }

    private func usageRow(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(key).fontWeight(.medium).frame(width: 130, alignment: .leading)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12))
    }

    private var preparing: some View {
        VStack(spacing: 18) {
            if setup.initializationError != nil {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
            } else { ProgressView().controlSize(.large) }
            Text(setup.initializationError == nil ? "正在准备你的资料库" : "资料库准备遇到问题")
                .font(.system(size: 22, weight: .semibold))
            Text(setup.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let error = setup.initializationError {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                HStack {
                    Button("重试初始化") { setup.prepareLibrary() }
                    Button("先进入应用") { setup.skip() }
                }
            }
            installStatus
            if setup.initializationError == nil {
                Button("先进入应用，后台继续准备") { setup.skip() }.buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("先建立文件清单和基础全文索引", systemImage: "checkmark.circle")
                Label("OCR 与内容理解随后在后台继续", systemImage: "arrow.clockwise.circle")
                Label("不必等待全部文件扫描完成", systemImage: "bolt.circle")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.green)
            Text("搜索已就绪")
                .font(.system(size: 24, weight: .semibold))
            Text("已发现 \(setup.indexedFiles) 个文件。文件名搜索、打开和预览已就绪。")
                .multilineTextAlignment(.center)
            Text(setup.message)
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            installStatus
            VStack(alignment: .leading, spacing: 10) {
                Label("内容索引可能仍在进行，进度可随时查看", systemImage: "arrow.clockwise")
                Label("右键菜单栏 AIE，查看进度或暂停扫描", systemImage: "menubar.rectangle")
                Label(shortcut.registered ? "下次按 \(shortcut.selected.title) 打开搜索" : "下次点击菜单栏 AIE 打开搜索", systemImage: "keyboard")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            Text("关闭窗口会收起 Dock 图标；退出应用会停止扫描。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var installStatus: some View {
        if setup.installing {
            if let progress = setup.installProgress {
                ProgressView(value: progress) {
                    Text("\(setup.installPhase) · \(Int(progress * 100))%")
                }
            } else { ProgressView(setup.installPhase).controlSize(.small) }
        }
        if let error = setup.installError {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            Button("重试模型安装") { setup.installSelectedPlan() }
        }
    }

    private var footer: some View {
        HStack {
            if setup.firstRun, setup.step != .welcome, setup.step.rawValue < DeviceSetupStep.preparing.rawValue {
                Button { setup.back() } label: {
                    Label("上一步", systemImage: "chevron.left")
                        .frame(minWidth: 78, minHeight: 22)
                }
                .buttonStyle(.bordered)
            } else if setup.step == .device {
                Button("重新检测") { setup.refresh() }
                    .buttonStyle(.bordered)
                    .disabled(setup.installing)
            } else if setup.step.rawValue > DeviceSetupStep.device.rawValue,
                      setup.step.rawValue < DeviceSetupStep.preparing.rawValue {
                Button { setup.back() } label: {
                    Label("上一步", systemImage: "chevron.left")
                        .frame(minWidth: 78, minHeight: 22)
                }
                    .buttonStyle(.bordered)
                    .disabled(setup.installing)
            }
            Spacer()
            if !setup.message.isEmpty, setup.step == .plan {
                Text(setup.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Button { setup.next() } label: {
                HStack(spacing: 8) {
                    Text(nextTitle)
                    if nextTitle == "下一步" { Image(systemName: "chevron.right") }
                }
                .frame(minWidth: 90, minHeight: 22)
            }
                .buttonStyle(.borderedProminent)
                .disabled(nextDisabled)
        }
        .controlSize(.large)
        .font(.system(size: 13, weight: .medium))
    }

    private var pageAlignment: Alignment {
        switch setup.step {
        case .source: return .topLeading
        case .welcome, .preparing, .ready: return .center
        case .device, .plan, .cloud, .usage: return .leading
        }
    }

    private var nextTitle: String {
        switch setup.step {
        case .welcome: return "开始设置"
        case .device: return "下一步"
        case .plan:
            if setup.firstRun { return "下一步" }
            return setup.selectedPlanInstalled ? "沿用已安装组合" : "安装所选组合"
        case .source, .cloud: return "下一步"
        case .usage:
            if !setup.selectedPlanInstalled { return "建立资料库并安装模型" }
            return "准备资料库"
        case .ready: return "开始使用"
        case .preparing: return ""
        }
    }

    private var nextDisabled: Bool {
        if setup.step == .ready { return false }
        return (!setup.firstRun && setup.installing) || (setup.step == .device && setup.profile == nil)
            || (setup.step == .source && setup.selectedFolders.isEmpty)
    }

    private func pageTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ name: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).lineLimit(1)
        }
        .padding(.vertical, 11)
    }

    private func planRows(_ plan: LocalScanPlan) -> [String] {
        var rows = ["语义搜索：EmbeddingGemma 2（文字与视觉）"]
        if let vision = plan.visionModel {
            rows.append("内容理解：\(LocalQuickScan.displayName(for: vision))")
        }
        return rows
    }

    private func planSize(_ plan: LocalScanPlan) -> String {
        if setup.modelsAvailable(for: plan) { return "已安装" }
        switch plan {
        case .semantic:
            return "需安装 Gemma"
        case .balanced:
            return "下载约 \(downloadSize(4)) GB"
        case .deep:
            return "下载约 6.7 GB"
        }
    }

    private func resourceLine(size: Int) -> String {
        let free = setup.profile?.freeGB.map { "当前可用 \($0) GB" } ?? "当前可用空间未知"
        return "下载约 \(downloadSize(size)) GB · 建议余量 \(requiredSpace(size)) GB · 运行占用约 \(memoryUse(size)) · 首次约 \(installTime(size)) · \(free)"
    }

    private func downloadSize(_ size: Int) -> String {
        switch size {
        case 2: return "2.5"
        case 4: return "3.9"
        case 8: return "6.7"
        default: return "6.7"
        }
    }

    private func requiredSpace(_ size: Int) -> Int {
        switch size {
        case 8: return 10
        case 4: return 7
        default: return 5
        }
    }

    private func memoryUse(_ size: Int) -> String {
        switch size {
        case 2: return "2–3 GB"
        case 4: return "4–6 GB"
        case 8: return "6–9 GB"
        default: return "6–9 GB"
        }
    }

    private func installTime(_ size: Int) -> String {
        switch size {
        case 2: return "5–15 分钟"
        case 4: return "10–25 分钟"
        case 8: return "20–60 分钟"
        default: return "20–60 分钟"
        }
    }
}

private extension View {
    func badgeStyle() -> some View {
        self
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
