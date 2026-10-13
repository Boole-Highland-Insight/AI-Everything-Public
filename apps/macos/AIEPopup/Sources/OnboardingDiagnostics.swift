import AppKit
import SwiftUI

/// Renders fixture states without opening personal sources, requesting Photos permission,
/// downloading a model, or changing the user's onboarding preferences.
enum OnboardingDiagnostics {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == "--verify-onboarding-layout" else { return false }
        guard args.count == 3, args[2].hasPrefix("/") else {
            fputs("usage: AIEPopup --verify-onboarding-layout /absolute/output/directory\n", stderr)
            exit(2)
        }
        do {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let setup = DeviceSetup()
            precondition(setup.selectedPlan == .deep, "New setups must recommend 8B")
            setup.firstRun = true
            setup.profile = DeviceProfile(chip: "Intel Core i5", appleSilicon: false, memoryGiB: 16, freeGB: 80, os: "macOS 14")
            setup.selectedPlan = .balanced
            precondition(setup.selectedVisionModel == "qwen3-vl:4b-instruct-q4_K_M",
                         "The 4B plan must not become 2B or reuse an installed 8B")
            setup.selectedPlan = .semantic
            precondition(setup.selectedVisionModel == nil, "Semantic-only must not select a vision model")
            setup.selectedPlan = .deep
            precondition(setup.selectedVisionModel == "qwen3-vl:8b-instruct-q4_K_M")
            for expected in [DeviceSetupStep.source, .device, .plan, .cloud, .usage] {
                setup.next()
                precondition(setup.step == expected, "Onboarding forward navigation failed")
            }
            for expected in [DeviceSetupStep.cloud, .plan, .device, .source, .welcome] {
                setup.back()
                precondition(setup.step == expected, "Onboarding back navigation failed")
            }
            setup.selectedFolders = [URL(fileURLWithPath: "/示例资料/工作与学习")]
            let cases: [(String, DeviceSetupStep)] = [
                ("welcome", .welcome), ("welcome-small", .welcome), ("sources", .source), ("device", .device),
                ("cloud", .cloud), ("usage", .usage), ("ready", .ready),
                ("plans", .plan), ("ready-downloading", .ready),
                ("plans-semantic", .plan), ("plans-balanced", .plan),
                ("initialization-error", .preparing), ("install-error", .ready),
            ]
            for (name, step) in cases {
                let installFailed = name == "install-error"
                setup.step = step
                setup.selectedPlan = name == "plans-semantic" ? .semantic : (name == "plans-balanced" ? .balanced : .deep)
                setup.installing = name == "ready-downloading"
                setup.installPhase = "下载 Qwen3-VL 8B"
                setup.installProgress = 0.42
                setup.indexedFiles = 128
                setup.message = installFailed ? "本地模型没有装上，基础搜索和 macOS 系统 OCR 不受影响。"
                    : (step == .ready ? "基础搜索已经可用；本地模型仍在后台下载。"
                       : (step == .preparing ? "资料库初始化未完成，可以重试或先进入应用。" : ""))
                setup.initializationError = step == .preparing ? "测试：资料库目录暂不可写" : nil
                // The longest realistic failure text, so a clipped message shows up here first.
                setup.installError = installFailed
                    ? "下载 qwen3-vl:8b-instruct-q4_K_M 失败：无法解析下载地址，可能被公司网络或 DNS 拦截"
                    : nil
                for dark in [false, true] {
                let view = NSHostingView(rootView: OnboardingView(setup: setup, autoplayDemo: false)
                    .environment(\.colorScheme, dark ? .dark : .light))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let fixtureSize: NSSize
                if name == "welcome-small" {
                    fixtureSize = NSSize(width: 520, height: 460)
                } else {
                    fixtureSize = NSSize(width: 680, height: DeviceSetup.guideContentHeight)
                }
                view.frame = NSRect(origin: .zero, size: fixtureSize)
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: directory.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
                }
            }
            print("Onboarding model-plan and navigation checks passed and 26 layout fixtures rendered; no source access or model installation.")
        } catch { fputs("Onboarding layout rendering failed: \(error)\n", stderr); exit(1) }
        return true
    }
}
