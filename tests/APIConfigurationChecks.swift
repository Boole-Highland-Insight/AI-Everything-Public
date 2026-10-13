import Foundation

@main
enum APIConfigurationChecks {
    static func main() {
        let suite = "aie-scan-checks-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        precondition(ScanConfiguration.visionEnabled(in: isolated))
        precondition(ScanConfiguration.semanticEnabled(in: isolated))
        let expectedModels = [
            ["qwen3-embedding:0.6b"],
            ["qwen3-embedding:0.6b", "qwen3-vl:4b-instruct-q4_K_M"],
            ["qwen3-embedding:0.6b", "qwen3-vl:8b-instruct-q4_K_M"],
        ]
        precondition(LocalScanPlan.allCases.map(\.models) == expectedModels)
        for plan in LocalScanPlan.allCases {
            ScanConfiguration.select(plan.rawValue, pending: true, in: isolated)
            precondition(!ScanConfiguration.semanticEnabled(in: isolated))
            precondition(!ScanConfiguration.visionEnabled(in: isolated))
            precondition(ScanConfiguration.cloudScanPaused(in: isolated))
            // A restored settings reader must keep an interrupted installation pending.
            let restored = UserDefaults(suiteName: suite)!
            precondition(restored.bool(forKey: ScanConfiguration.pendingKey))
            precondition(ScanConfiguration.selectedVisionModel(in: restored) == plan.visionModel)
            ScanConfiguration.select(plan.rawValue, pending: false, in: isolated)
            precondition(ScanConfiguration.semanticEnabled(in: restored))
            precondition(ScanConfiguration.visionEnabled(in: restored) == (plan != .semantic))
            precondition(ScanConfiguration.cloudScanPaused(in: restored))
        }
        // Legacy model-free users must not start running embeddings after this upgrade.
        ScanConfiguration.select("light", pending: false, in: isolated)
        precondition(!ScanConfiguration.visionEnabled(in: isolated))
        precondition(!ScanConfiguration.semanticEnabled(in: isolated))
        precondition(ScanConfiguration.cloudScanPaused(in: isolated))
        ScanConfiguration.select("balanced", pending: true, in: isolated)
        precondition(!ScanConfiguration.visionEnabled(in: isolated))
        precondition(ScanConfiguration.cloudScanPaused(in: isolated))
        ScanConfiguration.select("balanced", pending: false, in: isolated)
        precondition(ScanConfiguration.visionEnabled(in: isolated))
        precondition(ScanConfiguration.cloudScanPaused(in: isolated))
        // Process-local overrides: no Key is read, no preferences are written, no network calls.
        func use(_ values: [String: String]) {
            UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        }
        use([
            "aie.api.model.search": "vendor/search-test",
            "aie.api.model.scan": "  vendor/scan-test  ",
            "aie.api.model.reuse": "vendor/reuse-test",
            "aie.api.model.image": "vendor/image-test",
        ])
        precondition(GroqClient.searchModel == "vendor/search-test")
        precondition(GroqClient.scanModel == "vendor/scan-test")
        precondition(GroqClient.reuseModel == "vendor/reuse-test")
        precondition(GroqClient.imageModel == "vendor/image-test")
        precondition(GroqClient.scanFallbacks.isEmpty)
        precondition(GroqClient.reuseFallbacks.isEmpty)
        precondition(GroqClient.imageFallbacks.isEmpty)

        use(Dictionary(uniqueKeysWithValues: APIConfiguration.Model.allCases.map {
            ("aie.api.model.\($0.rawValue)", " \n ")
        }))
        for role in APIConfiguration.Model.allCases {
            precondition(role.id == role.defaultID)
        }
        precondition(!GroqClient.scanFallbacks.isEmpty)
        precondition(!GroqClient.reuseFallbacks.isEmpty)
        precondition(!GroqClient.imageFallbacks.isEmpty)
        precondition(APIConfiguration.chatEndpoint.scheme == "https")
        precondition(APIConfiguration.chatEndpoint.host == "openrouter.ai")
        print("API configuration checks passed: fixed model plans, semantic-only isolation, pending installation persistence, legacy opt-out, cloud policy (no credentials or network used).")
    }
}
