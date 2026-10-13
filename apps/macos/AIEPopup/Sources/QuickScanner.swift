import AppKit
import AIEData
import AIEMedia
import AVFoundation
import Foundation
import PDFKit

/// 后台模型扫描：本机模型写入独立 `deepScan`，云端兼容路径继续写 `quickScan`。
/// 文本/图片走自动扫描；视频 ffmpeg 风格抽帧（AVFoundation，每 5 秒最多 4 帧）再交给同一模型。
enum QuickScanner {
    private struct ScanResult {
        let blurb: String
        let keywords: [String]
        let fields: [String: Any]
    }

    private static let workQueue = DispatchQueue(label: "aie.quickscan", qos: .utility)
    private static let lock = NSLock()
    private static var running = false
    private static var pending: [IndexedFile] = []
    private static var pendingPaths = Set<String>()
    private static var onIdle: (() -> Void)?
    private static var wroteThisRun = 0
    // Accessed only by the serial scan queue. Never contains model response text or credentials.
    private static var failureReason = ""
    private static var attemptSourceHash = ""
    private static var resultModel = ""
    private static var resultProvider = ""
    private static var resultModelDigest = ""
    private static var reloadWork: DispatchWorkItem?
    // Queue-local cache: exact byte-for-byte duplicates reuse a successful local deep scan.
    private static var deepScanCache: [String: [String: Any]] = [:]
    private static let workerID = "quickscan-" + UUID().uuidString

    private static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff",
    ]
    private static let textExts: Set<String> = ["txt", "md", "csv", "tsv", "json"]
    private static let officeExts: Set<String> = ["docx", "pptx", "xlsx"]
    private static let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "flac"]

    private static let frameInterval: Double = 5
    private static let maxFrames = 4
    private static let textLimit = 8000
    private static let deepParserVersion = "deep-scan-2"
    private static let videoSegmentParserVersion = "video-deep-scan-2"

    static var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    static func enqueueMissing(
        files: [IndexedFile],
        repairSummaries: Bool = false,
        forceLocalDeepScan: Bool = false,
        done: @escaping () -> Void
    ) {
        guard LibraryGateway.lastError == nil else { DispatchQueue.main.async(execute: done); return }
        guard ScanConfiguration.visionEnabled() else {
            DispatchQueue.main.async {
                ScanProgress.shared.finish(wrote: 0)
                ScanProgress.shared.message = "基础分析已就绪 · 模型任务未启用"
                done()
            }
            return
        }
        let hasLocalModel = LocalQuickScan.isInstalled
        let excluded = files.filter {
            !supports($0.ext) || ScanPolicy.isDeferred($0) || (PhotoImport.contains($0.path) && !hasLocalModel)
        }.map {
            ScanSkipItem(
                path: $0.relative,
                reason: PhotoImport.contains($0.path) && !hasLocalModel
                    ? "照片图库只进行本机处理；安装本地视觉模型后再做深度理解"
                    : (ScanPolicy.isDeferred($0)
                        ? "已按用户要求暂缓扫描"
                        : ScanSkipItem.reason(for: $0.ext, cloud: !hasLocalModel))
            )
        }
        DispatchQueue.main.async { ScanProgress.shared.llmSkippedFiles = excluded }
        if APIConfiguration.automaticCloudScanPaused && !hasLocalModel {
            let supported = files.filter {
                supports($0.ext) && !ScanPolicy.isDeferred($0) && !PhotoImport.contains($0.path)
            }
            let pending = supported.filter { needsScan(file: $0) }.count
            DispatchQueue.main.async {
                ScanProgress.shared.pauseLLM(scanned: supported.count - pending, pending: pending, skipped: excluded.count)
                done()
            }
            return
        }
        guard hasLocalModel || GroqClient.hasKey else {
            DispatchQueue.main.async {
                ScanProgress.shared.finish(wrote: 0)
                done()
            }
            return
        }
        let supported = files.filter {
            supports($0.ext) && !ScanPolicy.isDeferred($0) && (!PhotoImport.contains($0.path) || hasLocalModel)
        }
        let skipped = files.count - supported.count
        let fresh = supported.filter {
            (forceLocalDeepScan && hasLocalModel) || needsScan(file: $0) || (repairSummaries && $0.summaryIssue != nil)
        }
        lock.lock()
        onIdle = done
        var added = 0
        for file in fresh where !pendingPaths.contains(file.path) {
            pending.append(file)
            pendingPaths.insert(file.path)
            added += 1
        }
        pending.sort(by: ScanOrder.precedes)
        let already = running
        let remaining = pending.count
        if already {
            lock.unlock()
            if added > 0 {
                DispatchQueue.main.async {
                    ScanProgress.shared.addLLMRemaining(added)
                }
            }
            return
        }
        guard !pending.isEmpty else {
            let idle = onIdle
            lock.unlock()
            DispatchQueue.main.async {
                ScanProgress.shared.beginLLM(
                    scanned: supported.count, remaining: 0, skipped: skipped,
                    usesLocalModel: hasLocalModel
                )
                ScanProgress.shared.finish(wrote: 0)
                idle?()
            }
            return
        }
        running = true
        wroteThisRun = 0
        deepScanCache.removeAll()
        lock.unlock()

        let start = {
            ScanProgress.shared.beginLLM(
                scanned: max(0, supported.count - remaining),
                remaining: remaining, skipped: skipped, usesLocalModel: hasLocalModel
            )
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.sync(execute: start)
        }
        workQueue.async { drain() }
    }

    private static func drain() {
        while true {
            let yielding = ScanControl.shared.isInteractiveWorkActive
            if yielding {
                DispatchQueue.main.async { ScanProgress.shared.setYieldingForSearch(true) }
            }
            _ = ScanControl.shared.waitForInteractiveWorkToSettle()
            if yielding {
                DispatchQueue.main.async { ScanProgress.shared.setYieldingForSearch(false) }
            }
            lock.lock()
            if ScanControl.shared.isPaused || !ScanConfiguration.visionEnabled() {
                let paused = ScanControl.shared.isPaused
                lock.unlock()
                let released = DispatchSemaphore(value: 0)
                Task { await LocalQuickScan.shared.unload(); released.signal() }
                released.wait()
                lock.lock()
                running = false
                lock.unlock()
                DispatchQueue.main.async {
                    if paused { ScanProgress.shared.pauseByUser() }
                    else { ScanProgress.shared.finish(wrote: 0) }
                }
                return
            }
            guard !pending.isEmpty else {
                let wrote = wroteThisRun
                pendingPaths.removeAll()
                let idle = onIdle
                lock.unlock()
                // Stay on the serial scan queue until unloading completes so a newly
                // enqueued scan cannot race an old queue's unload request. No UI lock is held.
                if LocalQuickScan.isInstalled {
                    let released = DispatchSemaphore(value: 0)
                    Task {
                        await LocalQuickScan.shared.unload()
                        released.signal()
                    }
                    released.wait()
                }
                lock.lock()
                if !pending.isEmpty {
                    lock.unlock()
                    continue
                }
                running = false
                lock.unlock()
                DispatchQueue.main.async {
                    ScanProgress.shared.finish(wrote: wrote)
                    idle?()
                }
                return
            }
            let file = pending.removeFirst()
            lock.unlock()
            guard LibraryGateway.allowsScanning(file) else {
                lock.lock(); pendingPaths.remove(file.path); lock.unlock()
                continue
            }

            if !ScanSettle.ready(path: file.path) {
                lock.lock()
                pending.append(file)
                pendingPaths.insert(file.path)
                lock.unlock()
                ScanSettle.wait()
                continue
            }

            let video = videoExts.contains(file.ext)
            let jobType = LocalQuickScan.isInstalled ? "deep" : "quick"
            let durableJob: DurableJob?
            var claimError: String?
            if let versionID = file.versionID, let inputHash = file.contentHash {
                let scanProtocol = LocalQuickScan.isInstalled
                    ? "\(video ? videoSegmentParserVersion : deepParserVersion):\(LocalQuickScan.model)"
                    : "quick-scan-2:\(GroqClient.scanModel)"
                let durableInputHash = ContentIdentity.digest(inputHash + ":" + scanProtocol)
                do {
                    durableJob = try AppDatabase.open().claimJob(
                        subjectID: versionID, jobType: jobType, inputHash: durableInputHash,
                        priority: 50, owner: workerID, leaseDuration: 2 * 60 * 60,
                        checkpointJSON: #"{"phase":"scan"}"#
                    )
                } catch {
                    AppLog.write("quickscan job claim: \(error)")
                    claimError = "后台任务暂时无法领取"
                    durableJob = nil
                }
                guard durableJob != nil else {
                    if claimError == nil {
                        let id = ContentIdentity.digest(versionID + ":" + jobType + ":" + durableInputHash)
                        if let job = try? AppDatabase.open().durableJob(id: id),
                           job.state == "pending", job.attemptCount < job.maxAttempts {
                            scheduleRetry(file, after: max(1, job.notBefore - Date().timeIntervalSince1970))
                        }
                    }
                    lock.lock(); pendingPaths.remove(file.path); lock.unlock()
                    DispatchQueue.main.async {
                        ScanProgress.shared.completeLLMOne(
                            success: claimError == nil, file: file.relative,
                            reason: claimError ?? ""
                        )
                    }
                    continue
                }
            } else {
                durableJob = nil
            }

            DispatchQueue.main.async {
                let p = ScanProgress.shared
                p.currentFile = file.relative
                let action = video ? "抽帧扫描" : "自动扫描"
                p.message = p.recoveredInterruption ? "已从上次中断处恢复 · \(action) \(file.relative)" : "\(action) \(file.relative)"
                ScanRecovery.update(
                    lane: .llm,
                    scanned: p.llmScanned,
                    remaining: p.llmRemaining,
                    failed: p.llmFailed,
                    skipped: p.llmSkipped,
                    currentFile: file.relative
                )
            }
            failureReason = "模型未返回有效摘要（网络、服务响应或格式问题）"
            attemptSourceHash = ""
            resultModel = ""
            resultProvider = ""
            resultModelDigest = ""
            let interactionRevision = ScanControl.shared.interactiveRevision
            let scanStarted = ProcessInfo.processInfo.systemUptime
            let ok = scanOne(file)
            if ok {
                ScanTiming.record(
                    key: ScanTiming.key(stage: "deep", ext: file.ext,
                                        model: LocalQuickScan.isInstalled ? LocalQuickScan.model : GroqClient.scanModel),
                    seconds: ProcessInfo.processInfo.systemUptime - scanStarted
                )
            }
            if !ok, LocalQuickScan.isInstalled,
               ScanControl.shared.interactiveRevision != interactionRevision {
                if let durableJob {
                    _ = try? AppDatabase.open().releaseJob(
                        id: durableJob.id, owner: workerID,
                        checkpointJSON: #"{"phase":"yielded_for_search"}"#
                    )
                }
                lock.lock()
                pending.append(file)
                pending.sort(by: ScanOrder.precedes)
                lock.unlock()
                DispatchQueue.main.async {
                    ScanProgress.shared.currentFile = nil
                    ScanProgress.shared.message = "已让搜索优先 · 当前文件稍后继续"
                }
                continue
            }
            let reason = failureReason
            ScanRecords.mutate(file) { record in
                let attemptKey = LocalQuickScan.isInstalled ? "deepScanAttempt" : "quickScanAttempt"
                record[attemptKey] = ["status": ok ? "ready" : "failed",
                    "reason": ok ? "" : reason, "sourceHash": attemptSourceHash, "attemptedAt": ISO8601DateFormatter().string(from: Date())]
                return true
            }
            if let durableJob {
                if ok {
                    _ = try? AppDatabase.open().completeJob(
                        id: durableJob.id, owner: workerID,
                        checkpointJSON: #"{"phase":"complete"}"#
                    )
                } else {
                    _ = try? AppDatabase.open().retryJob(
                        id: durableJob.id, owner: workerID, errorCode: reason,
                        retryDelay: 5 * 60, checkpointJSON: #"{"phase":"retry"}"#
                    )
                    if durableJob.attemptCount < durableJob.maxAttempts {
                        scheduleRetry(file, after: 5 * 60 + 1)
                    }
                }
            }
            ScanSettle.clear(file.path)
            lock.lock()
            pendingPaths.remove(file.path)
            if ok { wroteThisRun += 1 }
            lock.unlock()
            DispatchQueue.main.async {
                ScanProgress.shared.completeLLMOne(success: ok, file: file.relative, reason: reason)
            }
            scheduleIndexReload()
        }
    }

    private static func scheduleIndexReload() {
        DispatchQueue.main.async {
            reloadWork?.cancel()
            let work = DispatchWorkItem {
                QuickScanner.lock.lock()
                let idle = QuickScanner.onIdle
                QuickScanner.lock.unlock()
                idle?()
            }
            reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    private static func scheduleRetry(_ file: IndexedFile, after delay: TimeInterval) {
        workQueue.asyncAfter(deadline: .now() + max(1, delay)) {
            lock.lock()
            if !pendingPaths.contains(file.path) {
                pending.append(file)
                pendingPaths.insert(file.path)
                pending.sort(by: ScanOrder.precedes)
            }
            let shouldStart = !running && !pending.isEmpty
            if shouldStart { running = true }
            lock.unlock()
            if shouldStart { drain() }
        }
    }

    static func supports(_ ext: String) -> Bool {
        audioExts.contains(ext) || StructuredFileReader.extensions.contains(ext) || imageExts.contains(ext) || videoExts.contains(ext)
            || textExts.contains(ext) || officeExts.contains(ext) || ext == "pdf"
    }

    private static func needsScan(file: IndexedFile) -> Bool {
        guard supports(file.ext) else { return false }
        guard let obj = ScanRecords.read(file) else { return false }
        if obj.isEmpty { return true }
        let size = obj["size"] as? Int ?? (obj["size"] as? NSNumber)?.intValue
        if let size {
            let mtime = obj["mtime"] as? Int ?? (obj["mtime"] as? NSNumber)?.intValue ?? -2
            let nowSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? file.size
            let nowMtime = Int(file.mtime.timeIntervalSince1970)
            if size != nowSize || (mtime != -2 && abs(mtime - nowMtime) > 1) {
                return true
            }
        }
        let sectionName = LocalQuickScan.isInstalled ? "deepScan" : "quickScan"
        if let scan = obj[sectionName] as? [String: Any] {
            let parse = scan["parse"] as? [String: Any] ?? [:]
            if let hash = parse["sourceHash"] as? String, let current = file.contentHash, hash != current { return true }
            if sectionName == "deepScan", parse["model"] as? String != LocalQuickScan.model { return true }
            if sectionName == "deepScan", !videoExts.contains(file.ext),
               parse["parserVersion"] as? String != deepParserVersion { return true }
            if videoExts.contains(file.ext), sectionName == "deepScan",
               parse["parserVersion"] as? String != videoSegmentParserVersion { return true }
            let blurb = (scan["blurb_zh"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !blurb.isEmpty { return false }
        }
        return true
    }

    @discardableResult
    private static func scanOne(_ file: IndexedFile) -> Bool {
        if PhotoImport.contains(file.path), !LocalQuickScan.isInstalled {
            failureReason = "照片图库副本仅允许本地扫描，请安装本地模型"
            return false
        }
        guard AppDatabase.lastError == nil else { failureReason = "数据库不可用"; return false }
        let url = URL(fileURLWithPath: file.path)
        guard let sourceHash = try? ContentIdentity.hashFile(url) else { failureReason = "无法读取原文件"; return false }
        attemptSourceHash = sourceHash
        if LocalQuickScan.isInstalled, let cached = deepScanCache[sourceHash] {
            failureReason = "复用扫描结果时无法保存记录"
            return ScanRecords.mutate(file) { record in
                record["deepScan"] = cached
                if record["version"] == nil { record["version"] = 1 }
                if record["sourceRelative"] == nil { record["sourceRelative"] = ScanRecords.relative(for: file) }
                return true
            }
        }
        var transcriptFallback = false
        let result: ScanResult?
        if audioExts.contains(file.ext) {
            let local = ScanRecords.read(file)?["localScan"] as? [String: Any] ?? [:]
            guard let transcript = local["mediaTranscript"] as? [String: Any],
                  transcript["sourceHash"] as? String == sourceHash, transcript["status"] as? String == "ready",
                  let segments = transcript["segments"] as? [[String: Any]] else { failureReason = "需先完成本机音频转写"; return false }
            let width = max(1, (textLimit - 100) / max(1, segments.count))
            let text = segments.compactMap { ($0["text"] as? String).map { String($0.prefix(width)) } }.joined(separator: "\n")
            transcriptFallback = true
            result = describeText(file: file, text: "以下为本机音频转写摘录：\n" + text)
        } else if videoExts.contains(file.ext) {
            if LocalQuickScan.isInstalled {
                result = describeVideoSegments(file: file, url: url, sourceHash: sourceHash)
            } else {
                let frames = videoFrames(url)
                let local = ScanRecords.read(file)?["localScan"] as? [String: Any] ?? [:]
                if frames.isEmpty, let speech = local["mediaTranscript"] as? [String: Any],
                   speech["sourceHash"] as? String == sourceHash, speech["status"] as? String == "ready",
                   let segments = speech["segments"] as? [[String: Any]], !segments.isEmpty {
                    let width = max(1, (textLimit - 100) / segments.count)
                    let excerpts = segments.compactMap { ($0["text"] as? String).map { String($0.prefix(width)) } }.joined(separator: "\n")
                    guard !excerpts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { failureReason = "音轨中没有可用于摘要的转写文字"; return false }
                    transcriptFallback = true
                    result = describeText(file: file, text: "以下为各音频段的转写摘录，请勿推断未提供内容：\n" + excerpts)
                } else {
                    result = describeVision(file: file, url: url, frames: frames, modality: "video")
                }
            }
        } else if imageExts.contains(file.ext) {
            result = describeVision(file: file, url: url, frames: imageJPEGs(url, maxEdge: 768), modality: "image")
        } else if file.ext == "pdf" {
            let frames = pdfJPEGs(url)
            let preview = pdfText(url)
            let visualResult = describeVision(
                file: file,
                url: url,
                frames: frames,
                modality: "pdf",
                extraText: preview
            )
            // Dense papers can occasionally exhaust a multimodal structured response.
            // Their extracted text is still sufficient for a grounded semantic record.
            result = visualResult ?? describeText(file: file, text: "以下为 PDF 前四页正文摘录：\n" + preview)
        } else {
            result = describeText(file: file, url: url)
        }
        guard let result else { return false }
        let clean = result.blurb.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if let issue = ContentQuality.summaryIssue(clean, filename: file.name) {
            failureReason = "摘要未通过质量检查：" + issue
            return false
        }

        guard (try? ContentIdentity.hashFile(url)) == sourceHash else { failureReason = "文件在分析期间发生变化，等待重新扫描"; return false }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parse: [String: Any] = [
            "status": "ready",
            "scanLevel": resultProvider == "local" ? "deep" : "quick",
            "parserVersion": resultProvider == "local"
                ? (videoExts.contains(file.ext) ? videoSegmentParserVersion : deepParserVersion)
                : "2",
            "sourceHash": sourceHash,
            "model": resultModel.isEmpty ? GroqClient.scanModel : resultModel,
            "provider": resultProvider.isEmpty ? "openrouter" : resultProvider,
            "parsedAt": iso.string(from: Date()),
        ]
        if transcriptFallback { parse["coverage"] = "transcript_excerpts" }
        if !resultModelDigest.isEmpty { parse["modelDigest"] = resultModelDigest }
        failureReason = "摘要已生成，但无法保存扫描记录"
        var savedScan: [String: Any]?
        let saved = ScanRecords.mutate(file) { record in
            let sectionName = resultProvider == "local" ? "deepScan" : "quickScan"
            var scan = result.fields
            scan["blurb_zh"] = clean
            scan["keywords_zh"] = result.keywords
            scan["parse"] = parse
            record[sectionName] = scan
            if sectionName == "deepScan" { savedScan = scan }
            if record["version"] == nil { record["version"] = 1 }
            if record["sourceRelative"] == nil { record["sourceRelative"] = ScanRecords.relative(for: file) }
            return true
        }
        if saved, let savedScan { deepScanCache[sourceHash] = savedScan }
        return saved
    }

    private static func describeText(file: IndexedFile, url: URL) -> ScanResult? {
        let preview: String
        if StructuredFileReader.extensions.contains(file.ext) {
            preview = StructuredFileReader.read(path: url.path)?.preview(limit: textLimit) ?? ""
        } else if file.ext == "xlsx" {
            preview = SpreadsheetReader.read(path: url.path)?.preview(limit: textLimit) ?? ""
        } else if file.ext == "pptx" {
            preview = PresentationReader.read(path: url.path)?.preview(limit: textLimit) ?? ""
        } else if file.ext == "docx" {
            preview = unzipMember(url.path, member: "word/document.xml")
        } else {
            preview = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return describeText(file: file, text: preview)
    }

    private static func describeVideoSegments(
        file: IndexedFile,
        url: URL,
        sourceHash: String
    ) -> ScanResult? {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard let plan = try? VideoSamplePlan.make(duration: duration) else {
            failureReason = "无法读取有效视频时长"
            return nil
        }
        let existing = ScanRecords.read(file)?["deepScan"] as? [String: Any] ?? [:]
        let existingParse = existing["parse"] as? [String: Any] ?? [:]
        let canResume = existingParse["parserVersion"] as? String == videoSegmentParserVersion
            && existingParse["sourceHash"] as? String == sourceHash
            && existingParse["model"] as? String == LocalQuickScan.model
        var byIndex: [Int: [String: Any]] = [:]
        if canResume {
            for segment in existing["videoSegments"] as? [[String: Any]] ?? [] {
                if let index = segment["index"] as? Int, segment["status"] as? String == "ready" {
                    byIndex[index] = segment
                }
            }
            resultModel = existingParse["model"] as? String ?? LocalQuickScan.model
            resultModelDigest = existingParse["modelDigest"] as? String ?? ""
            resultProvider = "local"
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        for sample in plan where byIndex[sample.index] == nil {
            guard (try? ContentIdentity.hashFile(url)) == sourceHash else {
                failureReason = "文件在分析期间发生变化，等待重新扫描"
                return nil
            }
            let requested = CMTime(seconds: sample.startSeconds, preferredTimescale: 600)
            var actual = CMTime.invalid
            guard let image = try? generator.copyCGImage(at: requested, actualTime: &actual),
                  let jpeg = jpegData(image, quality: 0.7)
            else { continue }
            let actualSeconds = CMTimeGetSeconds(actual)
            let start = actualSeconds.isFinite ? actualSeconds : sample.startSeconds
            let clock = String(format: "%02d:%02d", Int(start) / 60, Int(start) % 60)
            guard let result = describeVision(
                file: file,
                url: url,
                frames: [jpeg],
                modality: "video frame",
                extraText: "这是视频在 \(clock)（第 \(sample.index + 1)/\(plan.count) 个采样点）的单帧。只描述这一帧明确可见的内容。"
            ) else { return nil }
            var segment = result.fields
            segment["index"] = sample.index
            segment["startSeconds"] = start
            segment["endSeconds"] = min(duration, start + 1)
            segment["status"] = "ready"
            byIndex[sample.index] = segment

            let ordered = byIndex.values.sorted {
                ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
            }
            let checkpointParse: [String: Any] = [
                "status": ordered.count == plan.count ? "ready" : "partial",
                "parserVersion": videoSegmentParserVersion,
                "sourceHash": sourceHash,
                "model": resultModel,
                "provider": "local",
                "modelDigest": resultModelDigest,
                "parsedAt": ISO8601DateFormatter().string(from: Date()),
            ]
            guard ScanRecords.mutate(file, { record in
                var deep = record["deepScan"] as? [String: Any] ?? [:]
                deep["videoSegments"] = ordered
                deep["parse"] = checkpointParse
                record["deepScan"] = deep
                return true
            }) else {
                failureReason = "视频分段已生成，但无法保存扫描断点"
                return nil
            }
            DispatchQueue.main.async {
                ScanProgress.shared.message = "画面理解 \(ordered.count)/\(plan.count) · \(file.name)"
            }
        }

        let segments = byIndex.values.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }
        guard !segments.isEmpty else {
            failureReason = "未能读取视频采样帧"
            return nil
        }
        func strings(_ key: String) -> [String] {
            var seen = Set<String>()
            return segments.flatMap { $0[key] as? [String] ?? [] }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let blurbs = segments.compactMap { ($0["blurb_zh"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !blurbs.isEmpty else {
            failureReason = "视频采样帧没有有效描述"
            return nil
        }
        var fields: [String: Any] = [
            "blurb_zh": blurbs.joined(separator: "；"),
            "keywords_zh": Array(strings("keywords_zh").prefix(10)),
            "topics_zh": Array(strings("topics_zh").prefix(5)),
            "entities_zh": Array(strings("entities_zh").prefix(12)),
            "evidence_zh": Array(strings("evidence_zh").prefix(6)),
            "objects_zh": Array(strings("objects_zh").prefix(12)),
            "actions_zh": Array(strings("actions_zh").prefix(8)),
            "visible_text_zh": Array(strings("visible_text_zh").prefix(12)),
            "videoSegments": segments,
            "completion_state": "unknown",
        ]
        let scenes = segments.compactMap { $0["scene_zh"] as? String }.filter { !$0.isEmpty }
        fields["scene_zh"] = scenes.joined(separator: "；")
        return ScanResult(
            blurb: fields["blurb_zh"] as! String,
            keywords: fields["keywords_zh"] as! [String],
            fields: fields
        )
    }

    private static func describeText(file: IndexedFile, text preview: String) -> ScanResult? {
        let clipped = String(preview.prefix(textLimit))
        guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failureReason = "未提取到可扫描的正文"
            return nil
        }
        let system = """
        你是本机文件深度扫描助手。只能根据给出的文本预览提取可检索语义，不要 markdown。
        输出内容包括：中文事实摘要、6到10个关键词、1到5个主题、实体、1到6条具体证据、内容类型，以及完成状态 complete/unfinished/unknown。
        完成状态必须同时给出 0 到 1 的置信度、最多4条可在原文中定位的完成度证据、最多4项确实缺少的内容。不要把“还能优化”当成“未完成”。
        另给出一个 reuse_action：none/continue/complete/polish/recreate，以及对应理由和 0 到 1 的置信度。complete 表示补齐缺失部分，只能用于 unfinished；完整内容适合打磨时必须用 polish/recreate，不适合再利用时用 none。
        scene_zh、objects_zh、actions_zh、visible_text_zh 用于视觉内容；纯文本时 scene_zh 设为空字符串，其余设为空数组。
        摘要可以一到三句。实体和证据必须能在预览中找到依据；不要根据文件名猜测。预览不足以判断是否完成时必须写 unknown。
        音频转写应总结对话主题和具体信息。不要输出无效占位或 schema 以外字段。
        """
        let user = "文件名：\(file.name)\n路径：\(file.relative)\n\n文本预览：\n\(clipped)"
        return callModel(system: system, user: user, images: [], maxTokens: 700)
    }

    private static func describeVision(
        file: IndexedFile,
        url: URL,
        frames: [Data],
        modality: String,
        extraText: String = ""
    ) -> ScanResult? {
        guard !frames.isEmpty else {
            failureReason = "未能读取图片或视频帧"
            return nil
        }
        let system = """
        你是本机多模态文件深度扫描助手。只能根据画面和提供的正文摘录提取可检索语义，不要 markdown。
        输出内容包括：中文事实摘要、6到10个关键词、1到5个主题、实体、1到6条具体证据、内容类型、完成状态 complete/unfinished/unknown，
        以及场景 scene_zh、明确可见的对象 objects_zh、动作 actions_zh、可辨认文字 visible_text_zh。
        完成状态必须同时给出 0 到 1 的置信度、最多4条画面或页面证据、最多4项确实缺少的内容。另给出 reuse_action：none/continue/complete/polish/recreate、理由和置信度；complete 表示补齐缺失部分，只能用于 unfinished。完整插画、线稿或设计适合再创作时用 polish/recreate，不适合时用 none。
        普通照片、截图、扫描文档不能因为留白或构图简单就判 unfinished；插画、线稿、手绘、设计稿、白板和示意图只有存在明确未完成证据时才可判 unfinished。
        摘要可以一到三句。只记录有明确证据的内容；看不清就描述线条、构图或写空数组，不要把抽象线条猜成具体物体。
        多页或多帧输入只代表抽样，不能据此声称覆盖完整文件；无法判断是否完成时写 unknown。不要输出 schema 以外字段。
        """
        var user = "文件：\(file.name)，类型：\(modality)。请根据画面生成一句可检索的中文摘要和关键词。"
        let extra = extraText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            user += "\n\n正文摘录：\n" + String(extra.prefix(2000))
        }
        return callModel(system: system, user: user, images: frames, maxTokens: 700)
    }

    private static func callModel(
        system: String,
        user: String,
        images: [Data],
        maxTokens: Int
    ) -> ScanResult? {
        let sem = DispatchSemaphore(value: 0)
        var raw: String?
        let useLocal = LocalQuickScan.isInstalled
        let requestTask = Task {
            if useLocal {
                for attempt in 0..<2 {
                    let response = await LocalQuickScan.shared.complete(
                        system: system,
                        user: user,
                        images: images,
                        maxTokens: maxTokens
                    )
                    if let response,
                       let parsed = extractJSON(response.content),
                       !(parsed["blurb_zh"] as? String ?? "")
                           .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        raw = response.content
                        resultModel = response.model
                        resultModelDigest = response.digest
                        resultProvider = "local"
                        break
                    }
                    failureReason = response == nil
                        ? "本地模型未返回响应（已自动重试）"
                        : "本地模型返回的结构化摘要无效（已自动重试）"
                    if attempt == 0, !Task.isCancelled,
                       !ScanControl.shared.isInteractiveWorkActive {
                        continue
                    }
                    break
                }
            } else {
                guard !APIConfiguration.automaticCloudScanPaused else { sem.signal(); return }
                raw = await GroqClient.complete(
                    system: system,
                    user: user,
                    imageJPEGs: images,
                    maxTokens: maxTokens,
                    json: false,
                    temperature: 0.2,
                    slow: true,
                    model: GroqClient.scanModel,
                    pinGroq: false,
                    allowFallback: true,
                    fallbacks: GroqClient.scanFallbacks
                )
                if raw != nil {
                    resultModel = GroqClient.scanModel
                    resultProvider = "openrouter"
                }
            }
            sem.signal()
        }
        let timeout: DispatchTime = .now() + (useLocal ? 720 : 52)
        if sem.wait(timeout: timeout) == .timedOut {
            requestTask.cancel()
            failureReason = useLocal ? "本地模型请求超时，可重试" : "模型请求超时（52 秒），可重试"
            GroqClient.log("quick-scan timeout")
            return nil
        }
        guard let raw, let parsed = extractJSON(raw) else {
            GroqClient.log("quick-scan parse-fail \(GroqClient.lastError ?? "")")
            return nil
        }
        func strings(_ key: String, limit: Int) -> [String] {
            (parsed[key] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(limit)
                .map { String($0.prefix(160)) }
        }
        let blurb = (parsed["blurb_zh"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = strings("keywords_zh", limit: 10)
        guard !blurb.isEmpty else { return nil }
        var fields = parsed
        fields["keywords_zh"] = keywords
        fields["topics_zh"] = strings("topics_zh", limit: 5)
        fields["entities_zh"] = strings("entities_zh", limit: 12)
        fields["evidence_zh"] = strings("evidence_zh", limit: 6)
        fields["objects_zh"] = strings("objects_zh", limit: 12)
        fields["actions_zh"] = strings("actions_zh", limit: 8)
        fields["visible_text_zh"] = strings("visible_text_zh", limit: 12)
        let state = parsed["completion_state"] as? String ?? "unknown"
        fields["completion_state"] = ["complete", "unfinished", "unknown"].contains(state) ? state : "unknown"
        func score(_ key: String) -> Double {
            let value: Double
            if let n = parsed[key] as? Double { value = n }
            else if let n = parsed[key] as? NSNumber { value = n.doubleValue }
            else if let n = parsed[key] as? Int { value = Double(n) }
            else { value = 0 }
            return min(max(value, 0), 1)
        }
        fields["completion_confidence"] = score("completion_confidence")
        fields["completion_evidence_zh"] = strings("completion_evidence_zh", limit: 4)
        fields["missing_parts_zh"] = strings("missing_parts_zh", limit: 4)
        let action = (parsed["reuse_action"] as? String ?? "none").lowercased()
        fields["reuse_action"] = ["none", "continue", "complete", "polish", "recreate"].contains(action) ? action : "none"
        fields["reuse_reason_zh"] = String((parsed["reuse_reason_zh"] as? String ?? "").prefix(240))
        fields["reuse_confidence"] = score("reuse_confidence")
        GroqClient.log("quick-scan ok \(blurb.prefix(80))")
        return ScanResult(blurb: blurb, keywords: keywords, fields: fields)
    }

    private static func extractJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end
        else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func videoFrames(_ url: URL) -> [Data] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        var positions: [Double] = []
        var t = max(0.5, frameInterval)
        while positions.count < maxFrames && (duration <= 0 || t < duration) {
            positions.append(t)
            t += frameInterval
        }
        if positions.isEmpty {
            positions = [max(0.5, duration > 0 ? duration * 0.2 : 1.0)]
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        var frames: [Data] = []
        for seek in positions {
            let time = CMTime(seconds: seek, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil),
                  let jpeg = jpegData(cg, quality: 0.7)
            else { continue }
            frames.append(jpeg)
        }
        return frames
    }

    private static func imageJPEGs(_ url: URL, maxEdge: CGFloat) -> [Data] {
        guard let ns = NSImage(contentsOf: url) else { return [] }
        var rect = NSRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        let scaled = downscale(cg, maxEdge: maxEdge)
        guard let jpeg = jpegData(scaled, quality: 0.72) else { return [] }
        return [jpeg]
    }

    private static func pdfJPEGs(_ url: URL) -> [Data] {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return [] }
        let thumb = page.thumbnail(of: CGSize(width: 768, height: 768), for: .mediaBox)
        var rect = NSRect(origin: .zero, size: thumb.size)
        guard let cg = thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let jpeg = jpegData(cg, quality: 0.72)
        else { return [] }
        return [jpeg]
    }

    private static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for i in 0..<min(doc.pageCount, 4) {
            if let s = doc.page(at: i)?.string, !s.isEmpty { parts.append(s) }
        }
        return String(parts.joined(separator: "\n").prefix(4000))
    }

    private static func unzipMember(_ path: String, member: String) -> String {
        guard let data = ArchiveEntryReader.data(path: path, member: member),
              let xml = String(data: data, encoding: .utf8) else { return "" }
        let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return String(
            stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(textLimit)
        )
    }

    private static func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let edge = max(w, h)
        guard edge > maxEdge else { return image }
        let scale = maxEdge / edge
        let nw = max(Int(w * scale), 1)
        let nh = max(Int(h * scale), 1)
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
