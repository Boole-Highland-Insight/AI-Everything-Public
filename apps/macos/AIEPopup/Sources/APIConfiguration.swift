import Foundation

/// Non-secret provider settings. Credentials remain in GroqClient's per-user store.
enum APIConfiguration {
    static let chatEndpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let imageEndpoint = URL(string: "https://openrouter.ai/api/v1/images")!
    static let projectURL = "https://github.com/Boole-Highland-Insight/AI-Everything-Public"

    static var automaticCloudScanPaused: Bool { ScanConfiguration.cloudScanPaused() }
    static let cloudRerankEnabled = false

    struct ModelOption: Identifiable, Hashable {
        let title: String
        let id: String
    }

    enum Model: String, CaseIterable {
        case search, scan, reuse, image

        var title: String {
            switch self {
            case .search: return "普通搜索排序"
            case .scan: return "文件理解"
            case .reuse: return "咔哒 · 文字"
            case .image: return "咔哒 · 图片"
            }
        }

        var subtitle: String {
            switch self {
            case .search: return "调整普通搜索结果的先后顺序"
            case .scan: return "使用云端扫描时理解文件内容"
            case .reuse: return "生成文字回复"
            case .image: return "生成或补全图片"
            }
        }

        var defaultID: String {
            switch self {
            case .search: return "meta-llama/llama-3.1-8b-instruct"
            case .scan: return "google/gemini-3.1-flash-lite"
            case .reuse: return "anthropic/claude-opus-5"
            case .image: return "google/gemini-3-pro-image"
            }
        }

        var id: String {
            let saved = UserDefaults.standard.string(forKey: "aie.api.model.\(rawValue)")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return saved.flatMap { $0.isEmpty ? nil : $0 } ?? defaultID
        }

        var options: [ModelOption] {
            switch self {
            case .search:
                return [
                    ModelOption(title: "Llama 3.1 8B", id: "meta-llama/llama-3.1-8b-instruct"),
                    ModelOption(title: "Gemini 3.1 Flash Lite", id: "google/gemini-3.1-flash-lite"),
                    ModelOption(title: "Qwen 3.6 Flash", id: "qwen/qwen3.6-flash"),
                ]
            case .scan:
                return [
                    ModelOption(title: "Gemini 3.1 Flash Lite", id: "google/gemini-3.1-flash-lite"),
                    ModelOption(title: "Gemini 2.5 Flash Lite", id: "google/gemini-2.5-flash-lite"),
                    ModelOption(title: "Qwen 3.6 Flash", id: "qwen/qwen3.6-flash"),
                ]
            case .reuse:
                return [
                    ModelOption(title: "Claude Opus 5", id: "anthropic/claude-opus-5"),
                    ModelOption(title: "Claude Sonnet 4.6", id: "anthropic/claude-sonnet-4.6"),
                    ModelOption(title: "GPT-5.5", id: "openai/gpt-5.5"),
                    ModelOption(title: "Gemini 3.1 Pro", id: "google/gemini-3.1-pro-preview"),
                ]
            case .image:
                return [
                    ModelOption(title: "Gemini 3 Pro Image", id: "google/gemini-3-pro-image"),
                    ModelOption(title: "Gemini 3.1 Flash Image", id: "google/gemini-3.1-flash-image"),
                    ModelOption(title: "GPT-5.4 Image", id: "openai/gpt-5.4-image-2"),
                ]
            }
        }

        func save(_ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == defaultID {
                UserDefaults.standard.removeObject(forKey: "aie.api.model.\(rawValue)")
            } else {
                UserDefaults.standard.set(clean, forKey: "aie.api.model.\(rawValue)")
            }
        }
    }
}
