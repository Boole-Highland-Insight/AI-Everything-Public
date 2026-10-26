import Foundation

@main enum DeepUnderstandingConfigurationChecks {
    static func main() {
        if CommandLine.arguments.count == 5 {
            let d = UserDefaults(suiteName: CommandLine.arguments[2])!
            precondition(d.string(forKey: ScanConfiguration.planKey) == CommandLine.arguments[3])
            precondition(d.bool(forKey: ScanConfiguration.deepPausedKey) == (CommandLine.arguments[4] == "true"))
            return
        }
        let suite = "aie.deep-control-checks." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        func verifyRestart(plan: String, paused: Bool) {
            d.synchronize()
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--read", suite, plan, String(paused)]
            try! child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
        }
        let initial = ScanConfiguration.initialPlan(in: d)
        precondition(initial == .deep)
        ScanConfiguration.setBackgroundUnderstanding(false, in: d)
        precondition(ScanConfiguration.semanticEnabled(in: d) && !ScanConfiguration.visionEnabled(in: d))
        verifyRestart(plan: "semantic", paused: false)
        let reopened = UserDefaults(suiteName: suite)!
        precondition(reopened.string(forKey: ScanConfiguration.planKey) == "semantic")
        ScanConfiguration.setBackgroundUnderstanding(true, in: d)
        precondition(ScanConfiguration.backgroundUnderstandingCanRun(in: d))
        ScanConfiguration.pauseBackgroundUnderstanding(true, in: d)
        precondition(!ScanConfiguration.backgroundUnderstandingCanRun(in: d) && ScanConfiguration.semanticEnabled(in: d))
        precondition(UserDefaults(suiteName: suite)!.bool(forKey: ScanConfiguration.deepPausedKey))
        verifyRestart(plan: "deep", paused: true)
        ScanConfiguration.pauseBackgroundUnderstanding(false, in: d)
        precondition(ScanConfiguration.backgroundUnderstandingCanRun(in: d))
        ScanConfiguration.setBackgroundUnderstanding(false, in: d)
        precondition(!ScanConfiguration.backgroundUnderstandingCanRun(in: d) && ScanConfiguration.semanticEnabled(in: d))
        print("PASS: new setup default; opt out; saved off; enable; pause; resume; persistence; Gemma independent")
    }
}
