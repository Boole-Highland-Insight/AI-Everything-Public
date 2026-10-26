import Foundation

/// Reads Ollama-format model stores. AI Everything keeps its own private store, but the same Mac
/// may already hold the model through a normal Ollama installation. Importing hard-links the
/// existing blobs instead of downloading several gigabytes again.
enum LocalModelLibrary {
    struct Model: Equatable {
        let name: String
        let store: URL
    }

    static var privateModels: URL {
        AIEApplicationPaths.support.appendingPathComponent("Semantic/models")
    }

    /// Model stores that belong to other Ollama installations, newest conventions first.
    static func sharedStores() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var stores: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !configured.isEmpty {
            stores.append(URL(fileURLWithPath: configured))
        }
        stores.append(home.appendingPathComponent(".ollama/models"))
        stores.append(URL(fileURLWithPath: "/usr/share/ollama/.ollama/models"))
        let ours = privateModels.standardizedFileURL.path
        var seen = Set<String>()
        return stores.filter {
            let path = $0.standardizedFileURL.path
            return path != ours && seen.insert(path).inserted && FileManager.default.fileExists(atPath: path)
        }
    }

    static func isInstalled(_ model: String) -> Bool { isComplete(model, in: privateModels) }

    /// A complete copy anywhere on this Mac, including other Ollama installations.
    static func isAvailable(_ model: String) -> Bool {
        isInstalled(model) || sharedStores().contains { isComplete(model, in: $0) }
    }

    /// Enumerates every complete Ollama model instead of checking only names bundled by this app.
    static func models(includePrivate: Bool = true) -> [Model] {
        let stores = (includePrivate ? [privateModels] : []) + sharedStores()
        var result: [Model] = []
        var seen = Set<String>()
        for store in stores {
            let root = store.appendingPathComponent("manifests")
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let manifest as URL in walker {
                guard (try? manifest.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let name = modelName(manifest: manifest, root: root),
                      seen.insert(name.lowercased()).inserted,
                      isComplete(name, in: store) else { continue }
                result.append(Model(name: name, store: store))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Qwen3.5 is natively multimodal. Qwen3-VL and the legacy Qwen2.5-VL family are also usable.
    static func compatibleVisionModels() -> [Model] {
        models().filter {
            let name = $0.name.lowercased()
            return name.hasPrefix("qwen3.5:") || name.hasPrefix("qwen3-vl:")
                || name.hasPrefix("qwen2.5vl:")
        }
    }

    /// Link an existing copy into the private store. Returns false when no complete copy exists.
    @discardableResult
    static func importFromSharedStore(_ model: String) throws -> Bool {
        guard !isInstalled(model) else { return true }
        guard let source = sharedStores().first(where: { isComplete(model, in: $0) }) else { return false }
        return try importModel(model, from: source, to: privateModels)
    }

    @discardableResult
    static func importModel(_ model: String, from source: URL, to target: URL) throws -> Bool {
        guard isComplete(model, in: source), let manifest = manifestURL(model, in: source),
              let entries = blobEntries(manifest: manifest) else { return false }
        let fm = FileManager.default
        let targetBlobs = target.appendingPathComponent("blobs")
        try fm.createDirectory(at: targetBlobs, withIntermediateDirectories: true)
        for entry in entries {
            let destination = targetBlobs.appendingPathComponent(entry.name)
            if fm.fileExists(atPath: destination.path) { continue }
            let origin = source.appendingPathComponent("blobs").appendingPathComponent(entry.name)
            let staged = targetBlobs.appendingPathComponent("." + UUID().uuidString)
            // Hard links keep one copy of multi-gigabyte weights on disk; a separate volume falls
            // back to a real copy so the private runtime never depends on the other installation.
            do { try fm.linkItem(at: origin, to: staged) }
            catch { try fm.copyItem(at: origin, to: staged) }
            do { try fm.moveItem(at: staged, to: destination) }
            catch {
                try? fm.removeItem(at: staged)
                guard fm.fileExists(atPath: destination.path) else { throw error }
            }
        }
        guard let destination = libraryManifestURL(model, in: target) else { return false }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: manifest).write(to: destination, options: .atomic)
        return isComplete(model, in: target)
    }

    static func isComplete(_ model: String, in store: URL) -> Bool {
        guard let manifest = manifestURL(model, in: store),
              let entries = blobEntries(manifest: manifest) else { return false }
        let blobs = store.appendingPathComponent("blobs")
        return entries.allSatisfy { entry in
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: blobs.appendingPathComponent(entry.name).path
            ), let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            return entry.size <= 0 || size == entry.size
        }
    }

    private static func libraryManifestURL(_ model: String, in store: URL) -> URL? {
        let parts = model.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return store
            .appendingPathComponent("manifests/registry.ollama.ai/library")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
    }

    /// Manifests normally live under `registry.ollama.ai/library`, but a store pulled through a
    /// mirror keeps the same name and tag under a different registry path.
    private static func manifestURL(_ model: String, in store: URL) -> URL? {
        let parts = model.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let suffix = "/" + parts[0] + "/" + parts[1]
        let direct = store
            .appendingPathComponent("manifests/registry.ollama.ai/library")
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let root = store.appendingPathComponent("manifests")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let candidate as URL in walker where candidate.path.hasSuffix(suffix) {
            if (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return candidate
            }
        }
        return nil
    }

    private static func modelName(manifest: URL, root: URL) -> String? {
        let relative = manifest.path.replacingOccurrences(of: root.path + "/", with: "")
        let parts = relative.split(separator: "/")
        guard parts.count >= 4 else { return nil }
        // <registry>/<namespace...>/<model>/<tag>; preserve non-library namespaces.
        let namespace = parts.dropFirst().dropLast(2)
        let model = parts[parts.count - 2]
        let tag = parts.last!
        let prefix = namespace == ["library"] ? "" : namespace.joined(separator: "/") + "/"
        return prefix + model + ":" + tag
    }

    private static func blobEntries(manifest: URL) -> [(name: String, size: Int64)]? {
        guard let data = try? Data(contentsOf: manifest),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var entries: [(name: String, size: Int64)] = []
        func append(_ layer: Any?) {
            guard let layer = layer as? [String: Any], let digest = layer["digest"] as? String,
                  digest.hasPrefix("sha256:"), digest.count > 7 else { return }
            entries.append((
                name: "sha256-" + digest.dropFirst(7),
                size: (layer["size"] as? NSNumber)?.int64Value ?? -1
            ))
        }
        append(object["config"])
        for layer in object["layers"] as? [Any] ?? [] { append(layer) }
        return entries.isEmpty ? nil : entries
    }
}
