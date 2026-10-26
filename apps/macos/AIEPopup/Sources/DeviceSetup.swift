import AppKit
import SwiftUI
import Darwin

enum DeviceSetupStep: Int, CaseIterable {
    case welcome, source, device, plan, cloud, usage, preparing, ready
    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .source: return "内容来源"
        case .device: return "设备检测"
        case .plan: return "本机方案"
        case .cloud: return "可选云端"
        case .usage: return "使用方法"
        case .preparing: return "准备资料库"
        case .ready: return "开始使用"
        }
    }
}

@MainActor final class DeviceSetup: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DeviceSetup()
    static let guideContentHeight: CGFloat = 720
    private static let completionKey = "aie.onboarding.v1.completed"
    @Published var profile: DeviceProfile?
    @Published var installing = false
    @Published var message = ""
    @Published var initializationError: String?
    @Published var installError: String?
    @Published var installProgress: Double?
    @Published var installPhase = ""
    @Published var step: DeviceSetupStep = .welcome {
        didSet { if step != oldValue { resizeWindowForStep(animated: true) } }
    }
    @Published var selectedPlan: LocalScanPlan = .deep
    @Published var selectedFolders: [URL] = []
    @Published var indexedFiles = 0
    @Published var indexReady = false
    @Published var firstRun = false
    @Published var cloudKeyDraft = ""
    @Published var cloudKeySaved = false
    @Published var cloudKeyError: String?
    @Published var shortcutPracticed = false
    private var window: NSWindow?
    private var configure: (([URL]) -> Void)?
    private var finishAction: (() -> Void)?
    private var recommendationApplied = false
    var isBlockingFirstRun: Bool {
        firstRun && !UserDefaults.standard.bool(forKey: Self.completionKey) && window?.isVisible == true
    }

    @discardableResult
    func presentIfNeeded(configure: @escaping ([URL]) -> Void, finished: @escaping () -> Void) -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.completionKey) else { return false }
        presentGuide(configure: configure, finished: finished)
        return true
    }

    /// Replay keeps saved sources, model downloads and index data intact.
    func presentGuide(configure: @escaping ([URL]) -> Void, finished: @escaping () -> Void) {
        if firstRun, window?.isVisible == true { bringToFront(); return }
        firstRun = true
        self.configure = configure
        finishAction = finished
        step = .welcome
        shortcutPracticed = false
        initializationError = nil
        selectedFolders = LibraryRoots.load()
        if PhotoLibrarySync.shared.connected {
            selectedFolders = LibraryRoots.merge(existing: selectedFolders, adding: [PhotoImport.directory])
        }
        showWindow(title: "AI Everything")
        refresh()
    }

    func bringToFront() { if let window { AppWindowPresence.shared.show(window) } }

    func practiceShortcut() -> Bool {
        guard firstRun, step == .usage, window?.isVisible == true else { return false }
        shortcutPracticed = true
        bringToFront()
        return true
    }

    func present() {
        if installing { showWindow(title: "本机扫描配置"); return }
        firstRun = false
        configure = nil
        finishAction = nil
        step = .device
        selectedFolders = LibraryRoots.load()
        refresh()
        showWindow(title: "本机扫描配置")
    }

    private func showWindow(title: String) {
        if let window {
            window.title = title
            resizeWindowForStep(animated: false)
            AppWindowPresence.shared.show(window)
            return
        }
        let panel = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(setup: self)))
        panel.title = title
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        let width = min(firstRun ? 680 : 620, max(520, (visible?.width ?? 800) - 48))
        panel.setContentSize(NSSize(width: width, height: fittedContentHeight(for: step)))
        panel.contentMinSize = NSSize(width: 520, height: 460)
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()
        window = panel
        AppWindowPresence.shared.show(panel)
    }

    private func contentHeight(for step: DeviceSetupStep) -> CGFloat {
        firstRun ? Self.guideContentHeight : 540
    }

    private func fittedContentHeight(for step: DeviceSetupStep) -> CGFloat {
        let visible = (window?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return min(contentHeight(for: step), max(460, visible - 48))
    }

    private func resizeWindowForStep(animated: Bool) {
        guard let window else { return }
        let height = fittedContentHeight(for: step)
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - height) > 0.5 else { return }
        var next = content
        next.origin.y -= height - content.height
        next.size.height = height
        var frame = window.frameRect(forContentRect: next)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.maxY > visible.maxY { frame.origin.y -= frame.maxY - visible.maxY }
            if frame.minY < visible.minY { frame.origin.y += visible.minY - frame.minY }
        }
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if firstRun { skip(); return false }
        return true
    }

    func refresh() {
        Task {
            let result = await Task.detached(priority: .utility) { DeviceProfile.read() }.value
            profile = result
            if !recommendationApplied {
                // Preserve an explicit choice; new setups start with the recommended 8B plan.
                selectedPlan = ScanConfiguration.initialPlan()
                recommendationApplied = true
            }
        }
    }

    var selectedVisionModel: String? {
        selectedPlan.visionModel
    }

    func modelsAvailable(for plan: LocalScanPlan) -> Bool {
        (!LocalSemanticIndex.usesGemma || LocalGemmaWorker.isAvailable)
            && plan.models.allSatisfy { LocalModelLibrary.isAvailable($0) }
    }

    var selectedPlanInstalled: Bool {
        modelsAvailable(for: selectedPlan)
    }

    var detectedModelDescription: String? {
        guard let model = selectedVisionModel, LocalQuickScan.isAvailable(model) else { return nil }
        return model
    }

    func next() {
        switch step {
        case .welcome: step = .source
        case .device: step = .plan
        case .plan:
            if firstRun { step = .cloud }
            else { installSelectedPlan() }
        case .source: step = .device
        case .cloud: step = .usage
        case .usage: prepareLibrary()
        case .preparing: break
        case .ready: finish()
        }
    }

    func back() {
        switch step {
        case .device: step = firstRun ? .source : .device
        case .plan: step = .device
        case .source: step = .welcome
        case .cloud: step = .plan
        case .usage: step = .cloud
        default: break
        }
    }

    var cloudKeyConfigured: Bool { GroqRerank.hasKey }
    var cloudKeyFromEnvironment: Bool { GroqClient.usesEnvironmentKey }

    /// Optional: the app stays fully local without a key. Saving here only enables Jev precision
    /// search and 咔哒, never background scanning of the whole library.
    func saveCloudKey() {
        let key = cloudKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cloudKeyFromEnvironment else { return }
        if GroqRerank.saveKey(key) {
            cloudKeySaved = true
            cloudKeyError = nil
            cloudKeyDraft = ""
        } else {
            cloudKeySaved = false
            cloudKeyError = GroqClient.lastError ?? "无法保存 Key，请检查格式。"
        }
    }

    func chooseFolders() {
        LibraryRoots.pickFolders(from: window) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.selectedFolders = LibraryRoots.merge(existing: self.selectedFolders, adding: urls)
        }
    }

    func removeFolder(_ url: URL) {
        if url.standardizedFileURL == PhotoImport.directory.standardizedFileURL { PhotoLibrarySync.shared.disconnect() }
        selectedFolders.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    func addPhotoLibraryRoot(_ url: URL) {
        selectedFolders = LibraryRoots.merge(existing: selectedFolders, adding: [url])
    }

    func prepareLibrary() {
        guard !selectedFolders.isEmpty else {
            message = "请先选择至少一个文件夹。"
            return
        }
        message = "正在读取文件清单并初始化本机数据库…"
        indexReady = false
        indexedFiles = 0
        step = .preparing
        initializationError = nil
        // Apply the local-only policy before any source can be enqueued.
        installSelectedPlan()
        configure?(selectedFolders)
        PhotoLibrarySync.shared.resumeIfNeeded()
    }

    func markIndexFailed(_ error: String) {
        guard firstRun, step == .preparing else { return }
        initializationError = error
        message = "资料库初始化未完成，可以重试或先进入应用。"
    }

    func markIndexReady(fileCount: Int) {
        guard firstRun, step == .preparing else { return }
        indexedFiles = fileCount
        indexReady = true
        step = .ready
        if installing {
            message = "基础搜索已经可用；本地模型仍在后台下载。"
        } else if installError != nil {
            message = "基础搜索已经可用；本地模型尚未就绪，可以重试安装。"
        } else if selectedPlanInstalled {
            message = selectedPlan == .semantic
                ? "已启用 EmbeddingGemma 2；文字与视觉语义索引会在后台继续。"
                : "已启用 EmbeddingGemma 2 与 \(LocalQuickScan.displayName)；内容分析会在后台继续。"
        } else {
            message = selectedPlan == .semantic
                ? "基础搜索已经可用；语义索引会在后台逐步补齐。"
                : "基础搜索已经可用；内容理解与语义索引会在后台逐步补齐。"
        }
    }

    func close() {
        window?.close()
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        AppWindowPresence.shared.hide(window)
        let action = finishAction
        finishAction = nil
        firstRun = false
        action?()
    }

    func skip() {
        finish()
    }

    func resumeInstallationIfNeeded() {
        guard !installing, UserDefaults.standard.bool(forKey: ScanConfiguration.pendingKey),
              let plan = UserDefaults.standard.string(forKey: ScanConfiguration.planKey).flatMap(LocalScanPlan.init(rawValue:)) else { return }
        selectedPlan = plan
        profile = DeviceProfile.read()
        installSelectedPlan()
    }

    func installSelectedPlan() {
        guard !installing else { return }
        let plan = selectedPlan
        installError = nil
        ScanConfiguration.select(plan.rawValue, pending: true)
        NotificationCenter.default.post(name: ScanConfiguration.changed, object: nil)
        let current = DeviceProfile.read()
        profile = current
        // A copy in another Ollama installation is linked, not downloaded, so it needs no headroom.
        let reusable = modelsAvailable(for: plan)
        guard reusable || (current.freeGB ?? 0) >= plan.requiredFreeGB else {
            message = "可用空间不足；\(plan.title)至少需要约 \(plan.requiredFreeGB) GB 余量。"
            installError = message
            return
        }
        installing = true
        installProgress = nil
        installPhase = reusable ? "正在复用本机已安装的模型…" : "正在准备本地运行环境…"
        message = reusable
            ? "正在复用本机已安装的模型，无需重新下载。"
            : "正在准备\(plan.title)所需的模型；文件名和全文搜索会先可用。"
        Task {
            do {
                // Wait for previous inference to finish before switching or disabling vision.
                await LocalQuickScan.shared.unload()
                if LocalSemanticIndex.usesGemma {
                    installPhase = "正在检查 AIE 内置 EmbeddingGemma 2…"
                    try await LocalGemmaInstaller.install()
                }
                if !plan.models.isEmpty {
                    try await LocalModelInstaller.install(
                        models: plan.models.map { ($0, LocalQuickScan.pinnedDigest($0)) }
                    ) { update in
                        Task { @MainActor [weak self] in
                            self?.installPhase = update.phase
                            self?.installProgress = update.fraction
                        }
                    }
                }
                await activate(plan)
            } catch {
                installing = false
                installProgress = nil
                installError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // The detailed reason already appears next to the retry button; do not repeat it.
                message = "本地模型没有装上，基础搜索和 macOS 系统 OCR 不受影响。"
            }
        }
    }

    private func activate(_ plan: LocalScanPlan) async {
        let activated: Bool
        if let model = plan.visionModel {
            activated = await LocalQuickScan.shared.activate(model)
                && (!LocalSemanticIndex.usesGemma || LocalGemmaWorker.isAvailable)
        } else {
            activated = LocalGemmaWorker.isAvailable
        }
        installing = false
        guard activated else {
            installError = "模型尚未准备好，请重试安装。"
            message = installError!
            return
        }
        ScanConfiguration.select(plan.rawValue, pending: false)
        installProgress = 1
        installPhase = "本地模型已就绪"
        message = plan == .semantic
            ? "已启用 EmbeddingGemma 2；语义索引会在后台继续，4B / 8B 内容理解未启用。"
            : "已启用 EmbeddingGemma 2 与 \(LocalQuickScan.displayName)，内容分析会在后台继续。"
        NotificationCenter.default.post(name: ScanConfiguration.changed, object: nil)
        if !firstRun { close() }
    }

}
