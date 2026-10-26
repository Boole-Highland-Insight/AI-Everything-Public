import Foundation
import Darwin

struct DeviceProfile {
    let chip: String
    let appleSilicon: Bool
    let memoryGiB: Int
    let freeGB: Int?
    let os: String
    static func read() -> DeviceProfile {
        func sysString(_ key: String) -> String? {
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
            return String(cString: bytes)
        }
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        let chip = sysString("machdep.cpu.brand_string") ?? (arm == 1 ? "Apple Silicon" : "Intel / x86")
        #if arch(arm64)
        let apple = true
        #else
        // Also identify Apple Silicon when this executable is running under Rosetta.
        let apple = arm == 1 || chip.hasPrefix("Apple ")
        #endif
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return DeviceProfile(chip: chip,
            appleSilicon: apple, memoryGiB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            freeGB: values?.volumeAvailableCapacity.map { $0 / 1_000_000_000 },
            os: ProcessInfo.processInfo.operatingSystemVersionString)
    }
    var reason: String {
        if !appleSilicon { return "Intel 使用 CPU 推理，4B / 8B 扫描可能较慢。可选择仅使用 Gemma 的语义索引。" }
        if memoryGiB < 16 { return "内存较少，建议选择语义索引以减少后台占用。三档模型均在本机运行。" }
        return "三档模型均在本机运行。8B 是默认推荐；想减少后台占用，可以选择 4B 或仅使用 Gemma。"
    }
}
