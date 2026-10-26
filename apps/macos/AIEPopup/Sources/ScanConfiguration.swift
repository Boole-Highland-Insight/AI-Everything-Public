import Foundation

enum LocalScanPlan: String, CaseIterable, Identifiable {
    case semantic, balanced, deep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .semantic: return "语义索引"
        case .balanced: return "轻量理解"
        case .deep: return "深度理解"
        }
    }
    var subtitle: String {
        switch self {
        case .semantic: return "Gemma 索引原文、OCR 和图片；复用已有分析，不运行新的 8B 分析"
        case .balanced: return "加入 4B 模型，生成内容摘要与图片描述"
        case .deep: return "使用 8B 模型分析内容，占用更多内存与扫描时间"
        }
    }
    var visionModel: String? {
        switch self {
        case .semantic: return nil
        case .balanced: return "qwen3-vl:4b-instruct-q4_K_M"
        case .deep: return "qwen3-vl:8b-instruct-q4_K_M"
        }
    }
    var models: [String] {
        [visionModel].compactMap { $0 }
    }
    var requiredFreeGB: Int {
        switch self {
        case .semantic: return 2
        case .balanced: return 7
        case .deep: return 10
        }
    }
}

/// Explicit onboarding choices override legacy auto-detection, without changing older installs.
enum ScanConfiguration {
    static let changed = Notification.Name("aie.scanConfigurationChanged")
    static let planKey = "aie.scan.plan"
    static let pendingKey = "aie.scan.installPending"
    static let deepPausedKey = "aie.scan.deepPaused"
    static func initialPlan(in defaults: UserDefaults = .standard) -> LocalScanPlan {
        defaults.string(forKey: planKey).flatMap(LocalScanPlan.init(rawValue:)) ?? .deep
    }
    static func backgroundUnderstandingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: planKey) == LocalScanPlan.deep.rawValue
    }
    static func backgroundUnderstandingCanRun(in defaults: UserDefaults = .standard) -> Bool {
        visionEnabled(in: defaults) && !defaults.bool(forKey: deepPausedKey)
    }
    /// A daily setting change does not install models or rebuild the content index.
    static func setBackgroundUnderstanding(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        select(enabled ? LocalScanPlan.deep.rawValue : LocalScanPlan.semantic.rawValue, pending: false, in: defaults)
        defaults.set(false, forKey: deepPausedKey)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["backgroundOnly": true])
    }
    static func pauseBackgroundUnderstanding(_ paused: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(paused, forKey: deepPausedKey)
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["backgroundOnly": true])
    }
    static let allowIndexGrowthKey = "aie.index.allowBeyondSoftLimit"
    static func semanticEnabled(in defaults: UserDefaults = .standard) -> Bool {
        // Keep the old model-free choice disabled until the user explicitly picks a new plan.
        defaults.string(forKey: planKey) != "light" && !defaults.bool(forKey: pendingKey)
    }
    static func visionEnabled(in defaults: UserDefaults = .standard) -> Bool {
        semanticEnabled(in: defaults) && defaults.string(forKey: planKey) != LocalScanPlan.semantic.rawValue
    }
    static func selectedVisionModel(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: planKey).flatMap(LocalScanPlan.init(rawValue:))?.visionModel
    }
    static func cloudScanPaused(in defaults: UserDefaults = .standard) -> Bool {
        // Choosing a local plan never authorizes automatic uploads, even while it downloads.
        defaults.string(forKey: planKey) != nil || CommandLine.arguments.contains("--local-scan-only")
    }
    static func allowsIndexGrowthBeyondSoftLimit(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allowIndexGrowthKey)
    }
    static func select(_ plan: String, pending: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(plan, forKey: planKey)
        defaults.set(pending, forKey: pendingKey)
    }
}
