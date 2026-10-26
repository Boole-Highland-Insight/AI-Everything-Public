import Foundation

/// Clean Baseline packaging supplies an absolute data directory. Ordinary builds retain their paths.
enum AIEApplicationPaths {
    static var isCleanV2: Bool { ["local.aieverything.cleanv2", "local.aieverything.cleanv2.deepcontrol", "local.aieverything.cleanv2.progress"].contains(Bundle.main.bundleIdentifier ?? "") }
    static var isCleanBaseline: Bool { isCleanV2 || Bundle.main.bundleIdentifier == "local.aieverything.cleanbaseline" }
    static var support: URL {
        if isCleanBaseline {
            guard let path = Bundle.main.object(forInfoDictionaryKey: "AIECleanDataDirectory") as? String,
                  path.hasPrefix("/") else { fatalError("Clean Baseline requires its isolated data directory") }
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Everything")
    }
    static var ollamaHost: String { if Bundle.main.bundleIdentifier == "local.aieverything.cleanv2.progress" { return "127.0.0.1:11475" }; if Bundle.main.bundleIdentifier == "local.aieverything.cleanv2.deepcontrol" { return "127.0.0.1:11465" }; return isCleanV2 ? "127.0.0.1:11455" : (isCleanBaseline ? "127.0.0.1:11445" : "127.0.0.1:11435") }
    static func configure() {
        UserDefaults.standard.register(defaults: ["aie.search.automaticRerank": true,
                                                   DeepScanSearchEnhancement.topNKey: 5,
                                                   "aie.search.cloudJev": false])
        guard isCleanBaseline else { return }
        if let path = ProcessInfo.processInfo.environment["AIE_DATABASE_PATH"] {
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            let production = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AI Everything").resolvingSymlinksInPath().path
            guard !target.hasPrefix(production + "/") else {
                fputs("Clean Baseline refuses the production database.\n", stderr); exit(2)
            }
        }
        let defaults = UserDefaults.standard
        if isCleanV2 {
            defaults.register(defaults: ["aie.search.automaticRerank": true,
                                         DeepScanSearchEnhancement.topNKey: 5])
        }
        let initializedKey = isCleanV2 ? "aie.cleanV2.initialized" : "aie.cleanBaseline.initialized"
        if !defaults.bool(forKey: initializedKey) {
            if let data = try? Data(contentsOf: support.appendingPathComponent("preferences.plist")),
               let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                for (key, value) in values where key.hasPrefix("aie.") { defaults.set(value, forKey: key) }
            }
            defaults.removeObject(forKey: "aie.gemma.modelsPath")
            defaults.set("gemma", forKey: "aie.embedding.engine")
            if defaults.string(forKey: ScanConfiguration.planKey) == nil {
                defaults.set("deep", forKey: ScanConfiguration.planKey)
            }
            defaults.set(false, forKey: "aie.scan.installPending")
            defaults.set(!isCleanV2, forKey: "aie.scan.userPaused")
            if isCleanV2 { defaults.set(true, forKey: "aie.search.automaticRerank") }
            defaults.set(true, forKey: initializedKey)
        }
    }
}
