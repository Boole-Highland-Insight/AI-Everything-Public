import AppKit
import Photos
import ImageIO
import UniformTypeIdentifiers
import AIEData

/// One-time Photos authorization followed by a persistent, recent-first local snapshot queue.
/// Snapshots are analysis inputs only; this type never mutates the user's Photos library.
@MainActor final class PhotoLibrarySync: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibrarySync()
    static let connectedKey = "aie.photos.connected"

    @Published var connected = UserDefaults.standard.bool(forKey: connectedKey)
    @Published var busy = false
    @Published var status = ""
    @Published var ready = 0
    @Published var total = 0
    @Published var failed = 0

    private var observing = false
    private var generation = 0
    private var retryTimer: Timer?
    private var activeRequest: PHImageRequestID?
    @Published var downloadFromICloud = UserDefaults.standard.object(forKey: "aie.photos.downloadFromICloud") as? Bool ?? true {
        didSet { UserDefaults.standard.set(downloadFromICloud, forKey: "aie.photos.downloadFromICloud") }
    }
    private var resyncRequested = false

    func connect(startImmediately: Bool = true, completion: @escaping (URL) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authorization == .authorized || authorization == .limited else {
                    self.status = "未获得照片图库读取权限，可在系统设置中重新授权。"
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: PhotoImport.directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                } catch { self.status = "无法创建照片分析目录。"; return }
                self.connected = true
                UserDefaults.standard.set(true, forKey: Self.connectedKey)
                completion(PhotoImport.directory)
                if startImmediately { self.startObserving(); self.startSync() }
            }
        }
    }

    func resumeIfNeeded() {
        guard connected else { return }
        guard LibraryRoots.load().contains(where: {
            let path = $0.standardizedFileURL.path
            return PhotoImport.directory.path == path || PhotoImport.directory.path.hasPrefix(path + "/")
        }) else { disconnect(); return }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            disconnect()
            status = "照片图库权限已失效，后台同步已停止。"
            return
        }
        startObserving()
        startSync()
    }

    func disconnect() {
        generation += 1
        connected = false
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        retryTimer?.invalidate()
        retryTimer = nil
        if let activeRequest { PHImageManager.default().cancelImageRequest(activeRequest) }
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self); observing = false }
        resyncRequested = false
        status = "照片图库已断开；已生成的分析副本保留在本机。"
    }

    func retryFailed() {
        try? AppDatabase.open().retryPhotoAssets(rootPath: PhotoImport.directory.path)
        startSync()
    }

    func startSync() {
        guard connected else { return }
        guard !ScanControl.shared.isPaused else {
            status = "照片同步已暂停"; return
        }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { disconnect(); return }
        guard !busy else {
            resyncRequested = true
            return
        }
        retryTimer?.invalidate()
        retryTimer = nil
        busy = true
        let current = generation
        status = "正在读取照片图库清单…"
        let root = PhotoImport.directory
        DispatchQueue.global(qos: .utility).async {
            let snapshots = Self.readLibrarySnapshot(root: root)
            do {
                let pending = try AppDatabase.open().synchronizePhotoAssets(snapshots, rootPath: root.path)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.connected, self.generation == current else { self.busy = false; return }
                    self.beginExport(pending: pending, snapshots: snapshots, generation: current)
                }
            } catch {
                AppDatabase.failed(error)
                DispatchQueue.main.async { [weak self] in
                    self?.busy = false
                    self?.status = "照片队列保存失败，暂未开始分析。"
                }
            }
        }
    }

    private func beginExport(pending: [String], snapshots: [PhotoAssetSnapshot], generation current: Int) {
        let total = snapshots.count
        let revisions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.revision) })
        self.total = total
        guard !pending.isEmpty else {
            updateProgress()
            busy = false
            status = total == 0 ? "照片图库中没有可读取的静态照片。"
                : (failed > 0 ? "照片已准备 \(ready)/\(total) · \(failed) 项等待重试" : "照片已准备 \(ready)/\(total) · OCR 和模型分析另行计数")
            scheduleRetry()
            runDeferredSyncIfNeeded()
            return
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: pending, options: nil)
        var assets: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in assets[asset.localIdentifier] = asset }
        Task {
            var completed = total - pending.count
            for id in pending {
                guard connected, generation == current, !ScanControl.shared.isPaused else { break }
                guard let revision = revisions[id] else { continue }
                let capacity = try? PhotoImport.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                guard (capacity?.volumeAvailableCapacityForImportantUsage ?? 0) > 2_000_000_000 else {
                    status = "照片准备已停止：可用空间不足 2 GB。释放空间后点击同步。"
                    busy = false
                    updateProgress()
                    return
                }
                guard let asset = assets[id] else {
                    _ = try? AppDatabase.open().updatePhotoAsset(id: id, revision: revision, localStatus: "failed", error: "图库项目已不可用", retryAt: Date().addingTimeInterval(3600))
                    continue
                }
                status = "正在准备照片 \(completed + 1)/\(total) · " + (downloadFromICloud ? "允许按需从 iCloud 下载" : "仅使用本机照片")
                _ = try? AppDatabase.open().updatePhotoAsset(id: id, revision: revision, localStatus: "downloading")
                let image = await requestImage(asset: asset)
                guard connected, generation == current else { break }
                if let image {
                    let target = Self.targetURL(assetID: id, root: PhotoImport.directory)
                    let saved = await Task.detached(priority: .utility) {
                        (try? Self.writeSnapshot(image: image, to: target)) != nil
                    }.value
                    if saved {
                        _ = try? AppDatabase.open().updatePhotoAsset(id: id, revision: revision, localStatus: "ready")
                    } else {
                        _ = try? AppDatabase.open().updatePhotoAsset(
                            id: id, revision: revision, localStatus: "failed", error: "分析副本写入失败",
                            retryAt: Date().addingTimeInterval(3600)
                        )
                    }
                } else {
                    _ = try? AppDatabase.open().updatePhotoAsset(
                        id: id, revision: revision, localStatus: "failed", error: "原片暂不可读取或 iCloud 下载失败",
                        retryAt: Date().addingTimeInterval(6 * 3600)
                    )
                }
                completed += 1
                if completed.isMultiple(of: 10) || completed == total { updateProgress() }
                if resyncRequested { break }
                if ScanControl.shared.isPaused {
                    status = "照片同步已暂停 · 已准备 \(ready)/\(total)"
                    break
                }
            }
            busy = false
            updateProgress()
            guard connected, generation == current else { return }
            if ScanControl.shared.isPaused {
                status = "照片同步已暂停 · 已准备 \(ready)/\(total)"
            } else if failed > 0 {
                status = "照片已准备 \(ready)/\(total) · \(failed) 项稍后重试"
            } else {
                status = "照片已准备 \(ready)/\(total) · OCR 和模型分析另行计数"
            }
            scheduleRetry()
            runDeferredSyncIfNeeded()
        }
    }

    private func scheduleRetry() {
        guard connected, !ScanControl.shared.isPaused,
              let date = try? AppDatabase.open().nextPhotoRetry(rootPath: PhotoImport.directory.path) else { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(30, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startSync() }
        }
    }

    private func requestImage(asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = downloadFromICloud
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            let result = PhotoImageResult(continuation)
            let request = PHImageManager.default().requestImage(
                for: asset, targetSize: NSSize(width: 1600, height: 1600),
                contentMode: .aspectFit, options: options
            ) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let failed = info?[PHImageErrorKey] != nil
                if cancelled || failed { result.finish(nil); return }
                guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                guard let image else { result.finish(nil); return }
                var rect = NSRect(origin: .zero, size: image.size)
                result.finish(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            }
            activeRequest = request
            // Photos may never deliver a final image while iCloud is offline. A bounded request
            // moves the asset to a retry checkpoint instead of holding the whole queue forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) {
                if result.finish(nil) { PHImageManager.default().cancelImageRequest(request) }
            }
        }
    }

    private func updateProgress() {
        guard let progress = try? AppDatabase.open().photoQueueProgress(rootPath: PhotoImport.directory.path) else { return }
        ready = progress.ready
        total = progress.total
        failed = progress.failed
        NotificationCenter.default.post(name: .aiePhotoSnapshotsChanged, object: nil)
    }

    private func startObserving() {
        guard !observing else { return }
        PHPhotoLibrary.shared().register(self)
        observing = true
    }

    private func runDeferredSyncIfNeeded() {
        guard resyncRequested else { return }
        resyncRequested = false
        startSync()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.resyncRequested = true
            self?.startSync()
        }
    }

    nonisolated private static func readLibrarySnapshot(root: URL) -> [PhotoAssetSnapshot] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var snapshots: [PhotoAssetSnapshot] = []
        snapshots.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let captured = asset.creationDate ?? asset.modificationDate ?? .distantPast
            let modified = asset.modificationDate ?? captured
            let digest = ContentIdentity.digest(Data(asset.localIdentifier.utf8))
            let target = root.appendingPathComponent("照片-\(digest).jpg")
            snapshots.append(PhotoAssetSnapshot(
                id: asset.localIdentifier,
                path: target.path,
                name: target.lastPathComponent,
                kind: "image",
                revision: "\(modified.timeIntervalSince1970):\(asset.pixelWidth)x\(asset.pixelHeight)",
                capturedAt: captured,
                modifiedAt: modified,
                duration: asset.duration
            ))
        }
        return snapshots
    }

    nonisolated private static func targetURL(assetID: String, root: URL) -> URL {
        let digest = ContentIdentity.digest(Data(assetID.utf8))
        return root.appendingPathComponent("照片-\(digest).jpg")
    }

    nonisolated private static func writeSnapshot(image: CGImage, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }
}

/// PhotoKit callbacks can race cancellation and timeout on different queues.
private final class PhotoImageResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
    @discardableResult func finish(_ image: CGImage?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: image)
        return pending != nil
    }
}

extension Notification.Name {
    static let aiePhotoSnapshotsChanged = Notification.Name("aie.photoSnapshotsChanged")
}
