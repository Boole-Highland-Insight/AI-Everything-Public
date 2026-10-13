import Foundation

enum BackgroundResourcePolicy {
    static var pauseReason: String? {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return "低电量模式" }
        switch process.thermalState {
        case .serious, .critical:
            return "设备温度较高"
        default:
            return nil
        }
    }

    static var allowsBackgroundModelWork: Bool { pauseReason == nil }
}
