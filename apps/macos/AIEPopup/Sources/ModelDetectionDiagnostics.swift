import Foundation

/// Reports which local models this Mac already has, and self-checks the reuse logic on fixtures.
/// Reads model stores only: no download, no library scan, no credentials.
enum ModelDetectionDiagnostics {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--verify-model-install" {
            guard args.count == 3 else {
                fputs("usage: AIEPopup --verify-model-install <model>\n", stderr)
                exit(2)
            }
            verifyInstall(args[2])
            return true
        }
        guard args.dropFirst().first == "--verify-model-detection" else { return false }
        if args.count == 3 {
            do { try fixtures(URL(fileURLWithPath: args[2])) }
            catch { fputs("model detection check failed: \(error)\n", stderr); exit(1) }
            print("Model detection checks passed: completeness, registry layout, link import, rejects partial copies.")
            return true
        }
        guard args.count == 2 else {
            fputs("usage: AIEPopup --verify-model-detection [/absolute/scratch/directory]\n", stderr)
            exit(2)
        }
        report()
        return true
    }

    /// Runs the real installer for one model, so a Mac that failed setup can show the actual cause.
    private static func verifyInstall(_ model: String) {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        Task {
            do {
                try await LocalModelInstaller.install(models: [(model, LocalQuickScan.pinnedDigest(model))]) { update in
                    let percent = update.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    fputs(update.phase + percent + "\n", stderr)
                }
            } catch { failure = error }
            done.signal()
        }
        done.wait()
        if let failure {
            let reason = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
            fputs("install failed: " + reason + "\n", stderr)
            fputs("log: " + LocalModelInstaller.logURL.path + "\n", stderr)
            exit(1)
        }
        print("Model ready: \(model)")
    }

    private static func report() {
        let models = [LocalQuickScan.embeddingModel] + [2, 4, 8].map { "qwen3-vl:\($0)b-instruct-q4_K_M" }
        print("private store: " + LocalModelLibrary.privateModels.path)
        let shared = LocalModelLibrary.sharedStores()
        print("other ollama stores: " + (shared.isEmpty ? "none" : shared.map(\.path).joined(separator: ", ")))
        for model in models {
            let state: String
            if LocalModelLibrary.isInstalled(model) { state = "ready (private)" }
            else if let store = shared.first(where: { LocalModelLibrary.isComplete(model, in: $0) }) {
                state = "reusable from " + store.path
            } else { state = "missing" }
            print("\(model): \(state)")
        }
    }

    private static func fixtures(_ directory: URL) throws {
        let fm = FileManager.default
        let source = directory.appendingPathComponent("source-models")
        let target = directory.appendingPathComponent("private-models")
        try? fm.removeItem(at: source)
        try? fm.removeItem(at: target)
        let model = "qwen3-vl:8b-instruct-q4_K_M"

        try write(model: model, in: source, registry: "registry.ollama.ai/library", payload: "weights")
        try expect(LocalModelLibrary.isComplete(model, in: source), "complete copy was not recognized")
        try expect(!LocalModelLibrary.isComplete(model, in: target), "empty store reported a model")

        try expect(try LocalModelLibrary.importModel(model, from: source, to: target), "import failed")
        try expect(LocalModelLibrary.isComplete(model, in: target), "imported model is incomplete")
        let linked = target.appendingPathComponent("blobs/sha256-" + digest("weights"))
        let origin = source.appendingPathComponent("blobs/sha256-" + digest("weights"))
        let sameFile = (try fm.attributesOfItem(atPath: linked.path)[.systemFileNumber] as? NSNumber)
            == (try fm.attributesOfItem(atPath: origin.path)[.systemFileNumber] as? NSNumber)
        try expect(sameFile, "import copied the weights instead of linking them")

        // A truncated blob is a failed download, not an installed model.
        let partial = directory.appendingPathComponent("partial-models")
        try? fm.removeItem(at: partial)
        try write(model: model, in: partial, registry: "registry.ollama.ai/library", payload: "weights", truncated: true)
        try expect(!LocalModelLibrary.isComplete(model, in: partial), "truncated blob counted as installed")
        try expect(try !LocalModelLibrary.importModel(model, from: partial, to: target.appendingPathComponent("x")),
                   "truncated copy was imported")

        // Stores pulled through a mirror keep the same name and tag under another registry path.
        let mirrored = directory.appendingPathComponent("mirror-models")
        try? fm.removeItem(at: mirrored)
        try write(model: model, in: mirrored, registry: "mirror.internal/ollama", payload: "mirror")
        try expect(LocalModelLibrary.isComplete(model, in: mirrored), "mirrored registry layout was not detected")
    }

    private static func write(model: String, in store: URL, registry: String,
                              payload: String, truncated: Bool = false) throws {
        let fm = FileManager.default
        let parts = model.split(separator: ":", maxSplits: 1)
        let blob = Data(payload.utf8)
        let name = "sha256-" + digest(payload)
        let blobs = store.appendingPathComponent("blobs")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try (truncated ? blob.prefix(1) : blob).write(to: blobs.appendingPathComponent(name))
        let manifest = store.appendingPathComponent("manifests/" + registry)
            .appendingPathComponent(String(parts[0])).appendingPathComponent(String(parts[1]))
        try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document: [String: Any] = [
            "config": ["digest": "sha256:" + digest(payload), "size": blob.count],
            "layers": [["digest": "sha256:" + digest(payload), "size": blob.count]],
        ]
        try JSONSerialization.data(withJSONObject: document).write(to: manifest)
    }

    private static func digest(_ text: String) -> String {
        var hash = [UInt8](repeating: 0, count: 32)
        // Deterministic fixture identifier; real manifests carry the runtime's own SHA-256.
        for (index, byte) in Array(text.utf8).enumerated() { hash[index % 32] ^= byte &+ UInt8(index % 251) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "aie.model-detection", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
