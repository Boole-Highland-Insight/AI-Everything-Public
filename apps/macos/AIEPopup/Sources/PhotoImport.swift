import AppKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import AIEData

/// User-selected Photos snapshots only. No enumeration or writes to the Photos library.
@MainActor final class PhotoImport: NSObject, ObservableObject, PHPickerViewControllerDelegate {
    static let shared = PhotoImport()
    @Published var busy = false
    @Published var status = ""
    private var window: NSWindow?
    private var completion: ((URL) -> Void)?
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Everything/Photo Imports", isDirectory: true)
    }
    nonisolated static func contains(_ path: String) -> Bool {
        path.hasPrefix(directory.path + "/")
    }
    func present(completion: @escaping (URL) -> Void) {
        guard !busy else { return }
        guard LocalQuickScan.isInstalled else {
            status = "请先安装本地扫描模型，再导入照片。"
            return
        }
        if let window { AppWindowPresence.shared.show(window); return }
        self.completion = completion
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 100
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        let panel = NSWindow(contentViewController: picker)
        panel.title = "选择照片 · 每批最多 100 张"
        panel.setContentSize(NSSize(width: 760, height: 560))
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        AppWindowPresence.shared.show(panel)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        window?.close()
        window = nil
        guard !results.isEmpty else { completion = nil; return }
        busy = true
        let done = completion
        completion = nil
        Task {
            var imported = 0
            var failed = 0
            for (index, result) in results.enumerated() {
                status = "正在准备照片 \(index + 1)/\(results.count)（iCloud 原片可能需要下载）"
                let ok = await withCheckedContinuation { continuation in
                    result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                        guard let url else { continuation.resume(returning: false); return }
                        do {
                            _ = try Self.writeSnapshot(from: url, to: Self.directory)
                            continuation.resume(returning: true)
                        } catch { continuation.resume(returning: false) }
                    }
                }
                if ok { imported += 1 } else { failed += 1 }
            }
            status = "已导入 \(imported) 张分析副本" + (failed > 0 ? "，\(failed) 张失败，可重新选择重试" : "，即将本地扫描")
            busy = false
            if imported > 0 { done?(Self.directory) }
        }
    }
    /// Downsample through ImageIO instead of decoding and retaining full-resolution originals.
    nonisolated static func writeSnapshot(from url: URL, to directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Stable pixel snapshot identity deduplicates repeated imports without exposing asset IDs.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).jpg")
        try (data as Data).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let hash = try ContentIdentity.hashFile(temporary)
        let target = directory.appendingPathComponent("照片-\(hash).jpg")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        return target
    }
}

/// File-only check: does not open or request access to a Photos library.
enum PhotoImportDiagnostics {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--verify-photo-import" else { return false }
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let source = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aie-photo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let before = try ContentIdentity.hashFile(source)
            let first = try PhotoImport.writeSnapshot(from: source, to: root)
            let second = try PhotoImport.writeSnapshot(from: source, to: root)
            let img = CGImageSourceCreateWithURL(first as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(img, 0, nil)! as NSDictionary
            let width = props[kCGImagePropertyPixelWidth] as! Int
            let height = props[kCGImagePropertyPixelHeight] as! Int
            let after = try ContentIdentity.hashFile(source)
            let passed = first == second && max(width, height) <= 1600 && before == after
            print("photo snapshot: passed=\(passed) width=\(width) height=\(height), duplicate import stable, original unchanged")
            if !passed { exit(1) }
        } catch { fputs("Photo snapshot check failed: \(error)\n", stderr); exit(1) }
        return true
    }
}
