import AppKit
import Foundation

/// 用户自选的搜索根。书签记住授权，不要求 Full Disk Access。
enum LibraryRoots {
    static let defaultsKey = "aie.libraryRootBookmarks"
    static let configuredKey = "aie.libraryRootsConfigured"

    static var demoURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AI-Everything-Library", isDirectory: true)
    }

    static var demoExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: demoURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--verify-library-roots" {
            let paths = load().map(\.path)
            print(String(decoding: try! JSONSerialization.data(withJSONObject: ["paths": paths, "count": paths.count]), as: UTF8.self))
            return true
        }
        guard arguments.dropFirst().first == "--set-library-roots" else { return false }
        let paths = Array(arguments.dropFirst(2))
        guard !paths.isEmpty else {
            fputs("usage: AIEPopup --set-library-roots /path/to/root [...]\n", stderr)
            return true
        }
        let urls = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            fputs("Every library root must be an existing path\n", stderr)
            return true
        }
        save(urls)
        guard load().map(\.path) == urls.map(\.path) else {
            fputs("Folder authorization verification failed; database was not opened.\n", stderr)
            exit(2)
        }
        urls.forEach { print($0.path) }
        return true
    }

    static func load() -> [URL] {
        if UserDefaults.standard.bool(forKey: configuredKey) {
            return resolveBookmarks()
        }
        if let env = ProcessInfo.processInfo.environment["AIE_LIBRARY_ROOT"], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return [url] }
        }
        return []
    }

    static func save(_ urls: [URL]) {
        UserDefaults.standard.set(true, forKey: configuredKey)
        let datas: [Data] = urls.compactMap { url in
            try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        UserDefaults.standard.set(datas, forKey: defaultsKey)
    }

    static func merge(existing: [URL], adding: [URL]) -> [URL] {
        var out = existing
        for url in adding {
            let path = url.standardizedFileURL.path
            if out.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                continue
            }
            out.removeAll { $0.path.hasPrefix(path + "/") }
            out.append(url.standardizedFileURL)
        }
        return out
    }

    static func pickFolders(from window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "开始索引"
        panel.message = "选择要搜索的文件夹。其中的照片、视频、文档和笔记都会进入索引，文件仍留在原处。"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            completion(panel.urls)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func resolveBookmarks() -> [URL] {
        guard let datas = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] else { return [] }
        var urls: [URL] = []
        var stale = false
        for data in datas {
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            urls.append(url)
        }
        // A bookmark resolution failure is not a user request to remove folders.
        // Refuse startup before SearchModel can send an incomplete scope to restrictRoots.
        guard urls.count == datas.count else {
            fputs("Saved folder authorization could not be restored; index left unchanged.\n", stderr)
            if !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
                _ = NSApplication.shared
                let alert = NSAlert()
                alert.messageText = "资料夹授权未能恢复"
                alert.informativeText = "为保护已有索引，本次不会启动扫描或清理数据库。请使用版本迁移启动器重新恢复资料夹授权。"
                alert.runModal()
            }
            exit(2)
        }
        if stale { save(urls) }
        return urls
    }
}
