import Foundation

enum LocalGemmaInstaller {
    static func install() async throws {
        guard LocalGemmaWorker.isAvailable else { throw GemmaError.notInstalled }
    }
}
