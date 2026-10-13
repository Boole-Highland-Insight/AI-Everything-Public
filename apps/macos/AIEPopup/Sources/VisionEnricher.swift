import AppKit
import AIEData
import AIEMedia
import AVFoundation
import Foundation
import NaturalLanguage
import PDFKit
import Speech
import Vision

/// 后台按类型写 SQLite 分析记录的 `localScan`：图/视频 Vision，音频 Speech，文本 NaturalLanguage。
/// 视频帧只在内存里解码，不落盘。增量：已有当前解析器结果且 size/mtime 未变则跳过。
enum VisionEnricher {
    private static let workQueue = DispatchQueue(label: "aie.vision", qos: .utility)
    private static let lock = NSLock()
    private static var running = false
    private static var pending: [IndexedFile] = []
    private static var pendingPaths = Set<String>()
    private static var onTick: (() -> Void)?
    private static var onComplete: (() -> Void)?
    private static var wroteThisRun = 0
    private static var reloadWork: DispatchWorkItem?
    private static let workerID = "local-scan-" + UUID().uuidString

    static var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    static let mediaExts: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff",
        "mp4", "mov", "m4v",
        "pdf", "txt", "md", "csv", "tsv", "json", "docx", "pptx", "xlsx", "xml", "msg", "rar", "zip", "7z", "tar", "gz",
        "m4a", "mp3", "wav", "aac", "flac",
    ]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v"]
    private static let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "flac"]
    private static let textExts: Set<String> = ["txt", "md", "csv", "tsv", "json"]
    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff",
    ]

    private static let tagZh: [String: [String]] = [
        "adult": ["成人"],
        "animal": ["动物"],
        "arch": ["拱门", "拱"],
        "art": ["艺术"],
        "beach": ["海滩", "沙滩"],
        "blue_sky": ["蓝天"],
        "botanical": ["植物园"],
        "branch": ["树枝"],
        "brick": ["砖"],
        "bridge": ["桥"],
        "building": ["建筑"],
        "car": ["车", "汽车"],
        "castle": ["城堡"],
        "cat": ["猫"],
        "cityscape": ["城市", "城景"],
        "cliff": ["悬崖", "峭壁"],
        "clothing": ["衣服", "服装"],
        "cloudy": ["多云", "阴天"],
        "consumer_electronics": ["电子产品", "手机"],
        "conveyance": ["交通工具", "船"],
        "crowd": ["人群"],
        "decoration": ["装饰"],
        "desert": ["沙漠"],
        "document": ["文档"],
        "dog": ["狗"],
        "dome": ["圆顶", "穹顶"],
        "door": ["门"],
        "fence": ["围栏", "篱笆"],
        "ferns": ["蕨", "蕨类"],
        "flag": ["旗", "旗帜"],
        "foliage": ["树叶"],
        "forest": ["森林", "林间"],
        "frozen": ["冰", "冻"],
        "grass": ["草"],
        "greenhouse": ["温室", "植物园"],
        "hat": ["帽子"],
        "haze": ["薄雾", "雾"],
        "hill": ["山丘"],
        "horse": ["马"],
        "indoor": ["室内"],
        "island": ["岛"],
        "jacket": ["外套", "夹克", "冲锋衣"],
        "lake": ["湖", "湖泊"],
        "land": ["陆地", "地面"],
        "liquid": ["液体"],
        "machine": ["机器"],
        "material": ["材质"],
        "mountain": ["山", "雪山", "山脉"],
        "ocean": ["海", "海洋"],
        "outdoor": ["户外", "室外"],
        "people": ["人", "人物"],
        "pier": ["码头", "栈桥"],
        "plant": ["植物"],
        "portal": ["门洞", "入口"],
        "printed_page": ["印刷页", "纸页"],
        "rainbow": ["彩虹"],
        "river": ["河"],
        "road": ["路", "道路"],
        "road_other": ["路"],
        "rocks": ["岩石"],
        "screenshot": ["截图"],
        "sky": ["天空"],
        "snow": ["雪", "雪山", "积雪"],
        "street": ["街道"],
        "structure": ["建筑", "结构"],
        "vegetation": ["植被"],
        "water": ["水"],
        "water_body": ["水体"],
        "window": ["窗"],
        "wood_natural": ["木头", "原木"],
        "wood_processed": ["木材"],
    ]

    static func enqueueMissing(
        files: [IndexedFile],
        tick: (() -> Void)? = nil,
        done: @escaping () -> Void
    ) {
        guard LibraryGateway.lastError == nil else { DispatchQueue.main.async(execute: done); return }
        let excluded = files.filter { !mediaExts.contains($0.ext) || ScanPolicy.isDeferred($0) }.map {
            ScanSkipItem(path: $0.relative, reason: ScanPolicy.isDeferred($0) ? "已按用户要求暂缓扫描" : ScanSkipItem.reason(for: $0.ext, cloud: false))
        }
        DispatchQueue.main.async { ScanProgress.shared.localSkippedFiles = excluded }
        let fresh = files.filter { needsScan(file: $0) }
        lock.lock()
        onTick = tick
        onComplete = done
        var added = 0
        for file in fresh where !pendingPaths.contains(file.path) {
            pending.append(file)
            pendingPaths.insert(file.path)
            added += 1
        }
        pending.sort(by: ScanOrder.precedes)
        let already = running
        let remaining = pending.count
        let supportedCount = files.count - excluded.count
        let skipped = files.count - supportedCount
        let scanned = max(0, supportedCount - remaining)
        if already {
            lock.unlock()
            if added > 0 {
                DispatchQueue.main.async {
                    ScanProgress.shared.addLocalRemaining(added)
                }
            }
            return
        }
        guard !pending.isEmpty else {
            let complete = onComplete
            let localDone = scanned
            lock.unlock()
            DispatchQueue.main.async {
                ScanProgress.shared.beginLocal(scanned: localDone, remaining: 0, skipped: skipped)
                ScanProgress.shared.localFinished()
                complete?()
            }
            return
        }
        running = true
        wroteThisRun = 0
        lock.unlock()

        let start = {
            ScanProgress.shared.beginLocal(scanned: scanned, remaining: remaining, skipped: skipped)
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
            if ScanControl.shared.isPaused {
                running = false
                lock.unlock()
                DispatchQueue.main.async { ScanProgress.shared.pauseByUser() }
                return
            }
            guard !pending.isEmpty else {
                pendingPaths.removeAll()
                running = false
                let complete = onComplete
                lock.unlock()
                DispatchQueue.main.async {
                    ScanProgress.shared.localFinished()
                    complete?()
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

            let durableJob: DurableJob?
            var claimFailed = false
            if let versionID = file.versionID, let inputHash = file.contentHash {
                do {
                    durableJob = try AppDatabase.open().claimJob(
                        subjectID: versionID, jobType: "local", inputHash: inputHash,
                        priority: 80, owner: workerID, leaseDuration: 2 * 60 * 60,
                        checkpointJSON: #"{"phase":"scan"}"#
                    )
                } catch {
                    AppLog.write("local scan job claim: \(error)")
                    claimFailed = true
                    durableJob = nil
                }
                guard durableJob != nil else {
                    if !claimFailed {
                        let id = ContentIdentity.digest(versionID + ":local:" + inputHash)
                        if let job = try? AppDatabase.open().durableJob(id: id),
                           job.state == "pending", job.attemptCount < job.maxAttempts {
                            scheduleRetry(file, after: max(1, job.notBefore - Date().timeIntervalSince1970))
                        }
                    }
                    lock.lock(); pendingPaths.remove(file.path); lock.unlock()
                    DispatchQueue.main.async {
                        ScanProgress.shared.completeLocalOne(success: !claimFailed, file: file.relative)
                    }
                    continue
                }
            } else {
                durableJob = nil
            }

            DispatchQueue.main.async {
                let p = ScanProgress.shared
                p.currentFile = file.relative
                p.message = p.recoveredInterruption ? "已从上次中断处恢复 · 正在扫描 \(file.relative)" : "正在扫描 \(file.relative)"
                ScanRecovery.update(
                    lane: .local,
                    scanned: p.localScanned,
                    remaining: p.localRemaining,
                    failed: p.localFailed,
                    skipped: p.localSkipped,
                    currentFile: file.relative
                )
            }
            let root = URL(fileURLWithPath: file.rootPath, isDirectory: true)
            let scanStarted = ProcessInfo.processInfo.systemUptime
            let ok = scanOne(root: root, file: file)
            if ok {
                ScanTiming.record(key: ScanTiming.key(stage: "local", ext: file.ext),
                                  seconds: ProcessInfo.processInfo.systemUptime - scanStarted)
            }
            if let durableJob {
                if ok {
                    _ = try? AppDatabase.open().completeJob(
                        id: durableJob.id, owner: workerID,
                        checkpointJSON: #"{"phase":"complete"}"#
                    )
                } else {
                    _ = try? AppDatabase.open().retryJob(
                        id: durableJob.id, owner: workerID, errorCode: "local_scan_failed",
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
                ScanProgress.shared.completeLocalOne(success: ok, file: file.relative)
            }
            scheduleIndexReload()
        }
    }

    private static func scheduleIndexReload() {
        DispatchQueue.main.async {
            reloadWork?.cancel()
            let work = DispatchWorkItem {
                VisionEnricher.lock.lock()
                let tick = VisionEnricher.onTick
                VisionEnricher.lock.unlock()
                tick?()
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

    private static func needsScan(file: IndexedFile) -> Bool {
        guard mediaExts.contains(file.ext), !ScanPolicy.isDeferred(file) else { return false }
        guard let obj = ScanRecords.read(file) else { return false }
        if audioExts.contains(file.ext), let transcript = (obj["localScan"] as? [String: Any])?["mediaTranscript"] as? [String: Any],
           transcript["sourceHash"] as? String == file.contentHash, transcript["status"] as? String == "ready" { return false }
        if let local = obj["localScan"] as? [String: Any], let hash = local["sourceHash"] as? String, let current = file.contentHash, hash != current { return true }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? -1
        let mtime = Int(file.mtime.timeIntervalSince1970)
        let oldSize = obj["size"] as? Int ?? (obj["size"] as? NSNumber)?.intValue ?? -2
        let oldMtime = obj["mtime"] as? Int ?? (obj["mtime"] as? NSNumber)?.intValue ?? -2
        if oldSize != size || abs(oldMtime - mtime) > 1 {
            // 体积没变且该类型字段已在，只是 mtime 抖动，不重扫。
            if oldSize == size {
                let local = obj["localScan"] as? [String: Any]
                if imageExts.contains(file.ext), local?["vision"] != nil {
                    return false
                }
                if videoExts.contains(file.ext),
                   let samples = local?["videoFrames"] as? [String: Any],
                   samples["parserVersion"] as? String == VideoSamplePlan.parserVersion { return false }
                if audioExts.contains(file.ext),
                   local?["speech"] != nil {
                    return false
                }
            }
            return true
        }
        let local = obj["localScan"] as? [String: Any] ?? [:]
        if local.values.contains(where: { ($0 as? [String: Any])?["error"] != nil }) { return true }
        if StructuredFileReader.extensions.contains(file.ext) {
            return (local["structuredFile"] as? [String: Any])?["parserVersion"] as? String != StructuredFileReader.version
        }
        if file.ext == "xlsx" {
            let spreadsheet = local["spreadsheet"] as? [String: Any]
            return spreadsheet?["parserVersion"] as? String != SpreadsheetReader.version
        }
        if file.ext == "pptx" {
            let presentation = local["presentation"] as? [String: Any]
            return presentation?["parserVersion"] as? String != PresentationReader.version
        }
        if imageExts.contains(file.ext) {
            return local["vision"] == nil
        }
        if videoExts.contains(file.ext) {
            guard let samples = local["videoFrames"] as? [String: Any] else { return true }
            if samples["parserVersion"] as? String != VideoSamplePlan.parserVersion { return true }
            guard let media = local["media"] as? [String: Any],
                  let audioTracks = (media["audioTracks"] as? NSNumber)?.intValue
            else { return true }
            if audioTracks > 0 {
                let transcript = local["mediaTranscript"] as? [String: Any]
                let currentHash = file.contentHash ?? local["sourceHash"] as? String
                return transcript?["sourceHash"] as? String != currentHash
                    || transcript?["status"] as? String != "ready"
            }
            return false
        }
        if audioExts.contains(file.ext) {
            return true
        }
        if file.ext == "pdf" {
            return local["vision"] == nil || local["naturalLanguage"] == nil
        }
        if textExts.contains(file.ext) || file.ext == "docx" || file.ext == "pptx" {
            return local["naturalLanguage"] == nil
        }
        return false
    }

    @discardableResult
    private static func scanOne(root: URL, file: IndexedFile) -> Bool {
        guard AppDatabase.lastError == nil else { return false }
        let url = URL(fileURLWithPath: file.path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let sizeNum = attrs[.size] as? NSNumber
        else { return false }
        let size = sizeNum.intValue
        let mtime = Int(file.mtime.timeIntervalSince1970)

        guard let existing = ScanRecords.read(file) else { return false }
        guard let sourceHash = try? ContentIdentity.hashFile(url) else { return false }

        var localUpdate: [String: Any] = ["sourceHash": sourceHash]
        var kind = file.kind.rawValue
        if imageExts.contains(file.ext) {
            kind = "image"
            localUpdate["vision"] = visionOrError(loadImage(url: url, ext: file.ext))
        } else if videoExts.contains(file.ext) {
            kind = "video"
            let existingLocal = existing["localScan"] as? [String: Any] ?? [:]
            let cachedSamples = existingLocal["videoFrames"] as? [String: Any]
            let samples = existingLocal["sourceHash"] as? String == sourceHash
                && cachedSamples?["parserVersion"] as? String == VideoSamplePlan.parserVersion
                ? cachedSamples!
                : analyzeVideoFrames(url)
            localUpdate["videoFrames"] = samples
            if let first = (samples["frames"] as? [[String: Any]])?.first?["vision"] {
                localUpdate["vision"] = first
            }
            guard let media = LocalAudioScanner.probe(file),
                  let mediaRecord = jsonObject(media)
            else { return false }
            localUpdate["media"] = mediaRecord
            if media.audioTracks > 0 {
                DispatchQueue.main.async {
                    ScanProgress.shared.message = "准备本机转写 · \(file.name)"
                }
                if let transcript = LocalAudioScanner.scan(file) {
                    localUpdate["mediaTranscript"] = transcript
                }
            }
        } else if audioExts.contains(file.ext) {
            kind = "audio"
            guard let transcript = LocalAudioScanner.scan(file) else { return false }
            localUpdate["mediaTranscript"] = transcript
        } else if file.ext == "pdf" {
            kind = "document"
            localUpdate["vision"] = visionOrError(pdfPageImage(url))
            localUpdate["naturalLanguage"] = runNL(pdfText(url))
        } else if StructuredFileReader.extensions.contains(file.ext) {
            guard let document = StructuredFileReader.read(path: url.path) else { return false }
            localUpdate["structuredFile"] = document.record
            localUpdate["naturalLanguage"] = runNL(document.preview(limit: 32000))
        } else if file.ext == "xlsx" {
            kind = "spreadsheet"
            guard let spreadsheet = SpreadsheetReader.read(path: url.path) else { return false }
            localUpdate["spreadsheet"] = spreadsheet.record
            localUpdate["naturalLanguage"] = runNL(spreadsheet.preview(limit: 32000))
        } else if file.ext == "pptx" {
            kind = "document"
            guard let presentation = PresentationReader.read(path: url.path) else { return false }
            localUpdate["presentation"] = presentation.record
            localUpdate["naturalLanguage"] = runNL(presentation.text)
        } else if file.ext == "docx" {
            kind = "document"
            let member = "word/document.xml"
            localUpdate["naturalLanguage"] = runNL(unzipMember(url.path, member: member))
        } else if textExts.contains(file.ext) {
            kind = (file.ext == "csv" || file.ext == "tsv") ? "spreadsheet" : (file.ext == "json" ? "other" : "document")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            localUpdate["naturalLanguage"] = runNL(text)
        }

        guard (try? ContentIdentity.hashFile(url)) == sourceHash else { return false }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record: [String: Any] = existing
        record["version"] = 1
        record["sourceRelative"] = ScanRecords.relative(for: file)
        record["kind"] = kind
        record["size"] = size
        record["mtime"] = mtime
        record["hash"] = "\(size)-\(mtime)"
        record["scannedAt"] = iso.string(from: Date())
        record["keyframes"] = [] as [Any]

        var local = (existing["localScan"] as? [String: Any]) ?? [:]
        for (key, value) in localUpdate { local[key] = value }
        record["localScan"] = local

        if record["quickScan"] == nil {
            if let existingQuick = existing["quickScan"] as? [String: Any] {
                record["quickScan"] = existingQuick
            } else if let existingSummary = existing["summary"] as? [String: Any] {
                record["quickScan"] = existingSummary
            } else if let existingCaption = existing["caption"] as? [String: Any] {
                record["quickScan"] = existingCaption
            } else if let imported = existing["matrixScanner"] as? [String: Any] {
                var quick: [String: Any] = [:]
                if let blurb = imported["blurb_zh"] { quick["blurb_zh"] = blurb }
                if let keys = imported["keywords_zh"] { quick["keywords_zh"] = keys }
                if let parse = imported["parse"] { quick["parse"] = parse }
                if !quick.isEmpty { record["quickScan"] = quick }
            } else if let llm = existing["llm"] as? [String: Any],
                      let analysis = llm["analysis"] as? [String: Any] {
                record["quickScan"] = ["en": analysis]
            }
        }

        record.removeValue(forKey: "summary")
        record.removeValue(forKey: "caption")
        record.removeValue(forKey: "vision")
        record.removeValue(forKey: "provider")
        record.removeValue(forKey: "llm")
        record.removeValue(forKey: "matrixScanner")

        let written = ScanRecords.mutate(file) { disk in
            // Merge only fields owned by this scanner. Cloud markers, provenance and a newer
            // QuickScan result may have been written while the system analysis was running.
            for key in ["version", "sourceRelative", "kind", "size", "mtime", "hash", "scannedAt", "keyframes"] {
                disk[key] = record[key]
            }
            var diskLocal = disk["localScan"] as? [String: Any] ?? [:]
            for (key, value) in localUpdate { diskLocal[key] = value }
            disk["localScan"] = diskLocal
            if disk["quickScan"] == nil { disk["quickScan"] = record["quickScan"] }
            for key in ["summary", "caption", "vision", "provider", "llm", "matrixScanner"] { disk.removeValue(forKey: key) }
            return true
        }
        let analysisFailed = localUpdate.values.contains { ($0 as? [String: Any])?["error"] != nil }
        return written && !analysisFailed
    }

    private static func loadImage(url: URL, ext: String) -> CGImage? {
        guard let ns = NSImage(contentsOf: url) else { return nil }
        var rect = NSRect(origin: .zero, size: ns.size)
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return downscale(cg, maxEdge: 960)
    }

    private static func analyzeVideoFrames(_ url: URL) -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard let plan = try? VideoSamplePlan.make(duration: duration) else {
            return [
                "parserVersion": VideoSamplePlan.parserVersion,
                "duration": duration,
                "frames": [] as [Any],
                "error": "invalid video duration",
            ]
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        var frames: [[String: Any]] = []
        for sample in plan {
            let requested = CMTime(seconds: sample.startSeconds, preferredTimescale: 600)
            var actual = CMTime.invalid
            guard let image = try? generator.copyCGImage(at: requested, actualTime: &actual),
                  let vision = try? runVision(image)
            else { continue }
            let actualSeconds = CMTimeGetSeconds(actual)
            let start = actualSeconds.isFinite ? actualSeconds : sample.startSeconds
            frames.append([
                "index": sample.index,
                "startSeconds": start,
                "endSeconds": min(duration, start + 1),
                "vision": vision,
            ])
        }
        var result: [String: Any] = [
            "parserVersion": VideoSamplePlan.parserVersion,
            "duration": duration,
            "frames": frames,
        ]
        if frames.isEmpty { result["error"] = "could not load video frames" }
        return result
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

    private static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func runVision(_ image: CGImage) throws -> [String: Any] {
        let ocrReq = VNRecognizeTextRequest()
        ocrReq.recognitionLevel = .accurate
        ocrReq.usesLanguageCorrection = true
        ocrReq.recognitionLanguages = ["zh-Hans", "en-US"]
        let classifyReq = VNClassifyImageRequest()
        let animalReq = VNRecognizeAnimalsRequest()
        let humanReq = VNDetectHumanRectanglesRequest()
        humanReq.upperBodyOnly = false
        let barcodeReq = VNDetectBarcodesRequest()
        let fpReq = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([ocrReq, classifyReq, animalReq, humanReq, barcodeReq, fpReq])

        let ocr = (ocrReq.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tags: [[String: Any]] = []
        var searchable: [String] = []
        searchable.append(contentsOf: ocr)
        for obs in (classifyReq.results ?? []) where obs.confidence >= 0.25 {
            let ident = obs.identifier
            let zh = tagZh[ident] ?? []
            tags.append([
                "id": ident,
                "confidence": Double(obs.confidence),
                "zh": zh,
            ])
            searchable.append(ident)
            searchable.append(contentsOf: zh)
            if tags.count >= 8 { break }
        }

        let animals = (animalReq.results ?? []).compactMap { obs -> String? in
            obs.labels.first.map { "\($0.identifier)" }
        }
        searchable.append(contentsOf: animals)

        let people = humanReq.results?.count ?? 0
        if people > 0 {
            searchable.append("人")
            searchable.append("people")
        }

        let barcodes = (barcodeReq.results ?? []).compactMap { obs -> String? in
            if let payload = obs.payloadStringValue, !payload.isEmpty { return payload }
            return nil
        }
        searchable.append(contentsOf: barcodes)

        var seen = Set<String>()
        let text = searchable.filter { seen.insert($0).inserted }.joined(separator: " ")
        let canvas = CanvasProbe.stats(from: image)
        return [
            "ocr": ocr,
            "tags": tags,
            "animals": animals,
            "peopleCount": people,
            "barcodes": barcodes,
            "featurePrintDims": fpReq.results?.first?.elementCount ?? 0,
            "searchableText": text,
            "canvas": [
                "inkRatio": canvas.inkRatio,
                "paperRatio": canvas.paperRatio,
                "chroma": canvas.chroma,
                "edgeRatio": canvas.edgeRatio,
                "mostlyBlank": canvas.mostlyBlank,
                "sparse": canvas.sparse,
                "sketchy": canvas.sketchy,
                "layout": canvas.layout,
            ],
        ]
    }

    private static func visionOrError(_ image: CGImage?) -> [String: Any] {
        guard let image else {
            return ["error": "could not load", "searchableText": ""]
        }
        do {
            return try runVision(image)
        } catch {
            return ["error": error.localizedDescription, "searchableText": ""]
        }
    }

    private static func pdfPageImage(_ url: URL) -> CGImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let thumb = page.thumbnail(of: CGSize(width: 960, height: 960), for: .mediaBox)
        var rect = NSRect(origin: .zero, size: thumb.size)
        return thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func pdfText(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for i in 0..<min(doc.pageCount, 8) {
            if let s = doc.page(at: i)?.string, !s.isEmpty { parts.append(s) }
        }
        return String(parts.joined(separator: "\n").prefix(6000))
    }

    private static func runNL(_ text: String) -> [String: Any] {
        let sample = String(text.prefix(4000))
        let rec = NLLanguageRecognizer()
        rec.processString(sample)
        let lang = rec.dominantLanguage?.rawValue ?? ""
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sample
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { range, _ in
            let tok = String(sample[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tok.count >= 2 { tokens.append(tok) }
            return tokens.count < 60
        }
        var seen = Set<String>()
        let uniq = tokens.filter { seen.insert($0.lowercased()).inserted }
        var searchable = uniq
        if !lang.isEmpty { searchable.insert(lang, at: 0) }
        return [
            "language": lang,
            "tokens": Array(uniq.prefix(40)),
            "searchableText": searchable.joined(separator: " "),
        ]
    }

    private static func unzipMember(_ path: String, member: String) -> String {
        guard let data = ArchiveEntryReader.data(path: path, member: member),
              let xml = String(data: data, encoding: .utf8) else { return "" }
        let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return String(
            stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(4000)
        )
    }

    private static func transcribeAudio(_ url: URL) -> [String: Any] {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted, .notDetermined:
            return ["error": "speech not authorized", "searchableText": ""]
        default:
            break
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
        guard let recognizer else {
            return ["error": "no recognizer", "searchableText": ""]
        }
        if !recognizer.isAvailable || !recognizer.supportsOnDeviceRecognition {
            return ["error": "recognizer unavailable", "searchableText": ""]
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let sem = DispatchSemaphore(value: 0)
        var transcript = ""
        var err: String?
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result { transcript = result.bestTranscription.formattedString }
            if let error { err = error.localizedDescription }
            if result?.isFinal == true || error != nil { sem.signal() }
        }
        if sem.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            if err == nil { err = "timeout" }
        }
        var out: [String: Any] = [
            "transcript": transcript,
            "onDevice": recognizer.supportsOnDeviceRecognition,
            "locale": recognizer.locale.identifier,
            "searchableText": transcript,
        ]
        if let err { out["error"] = err }
        return out
    }
}
