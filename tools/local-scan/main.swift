import AppKit
import AVFoundation
import Foundation
import NaturalLanguage
import PDFKit
import Speech
import Vision

/// Force localScan for a library root: Vision / AVFoundation / Speech / NaturalLanguage.
/// Skips Core ML, Metal, PhotoKit. Does not overwrite quickScan.

let tagZh: [String: [String]] = [
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

let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff"]
let videoExts: Set<String> = ["mp4", "mov", "m4v"]
let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "flac"]
let textExts: Set<String> = ["txt", "md", "csv", "tsv", "json"]
let pdfExts: Set<String> = ["pdf"]
let officeExts: Set<String> = ["docx", "pptx"]

func log(_ msg: String) {
    fputs(msg + "\n", stderr)
}

func loadJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func writeJSON(_ obj: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

func sidecarURL(root: URL, rel: String) -> URL {
    root.appendingPathComponent("scanner").appendingPathComponent(rel + ".json")
}

func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let edge = max(w, h)
    guard edge > maxEdge else { return image }
    let scale = maxEdge / edge
    let nw = max(Int(w * scale), 1)
    let nh = max(Int(h * scale), 1)
    guard let ctx = CGContext(
        data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

func cgFromImageFile(_ url: URL) -> CGImage? {
    guard let ns = NSImage(contentsOf: url) else { return nil }
    var rect = NSRect(origin: .zero, size: ns.size)
    guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    return downscale(cg, maxEdge: 960)
}

func videoFrame(_ url: URL) -> CGImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 640)
    let t1 = CMTime(seconds: 1, preferredTimescale: 600)
    if let cg = try? generator.copyCGImage(at: t1, actualTime: nil) { return cg }
    let t0 = CMTime(seconds: 0, preferredTimescale: 600)
    return try? generator.copyCGImage(at: t0, actualTime: nil)
}

func pdfPageImage(_ url: URL) -> CGImage? {
    guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
    let thumb = page.thumbnail(of: CGSize(width: 960, height: 960), for: .mediaBox)
    var rect = NSRect(origin: .zero, size: thumb.size)
    return thumb.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func pdfText(_ url: URL) -> String {
    guard let doc = PDFDocument(url: url) else { return "" }
    var parts: [String] = []
    for i in 0..<min(doc.pageCount, 8) {
        if let s = doc.page(at: i)?.string, !s.isEmpty { parts.append(s) }
    }
    return String(parts.joined(separator: "\n").prefix(6000))
}

func runVision(_ image: CGImage) throws -> [String: Any] {
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
        tags.append(["id": ident, "confidence": Double(obs.confidence), "zh": zh])
        searchable.append(ident)
        searchable.append(contentsOf: zh)
        if tags.count >= 8 { break }
    }

    let animals = (animalReq.results ?? []).compactMap { $0.labels.first.map { $0.identifier } }
    searchable.append(contentsOf: animals)
    let people = humanReq.results?.count ?? 0
    if people > 0 {
        searchable.append("人")
        searchable.append("people")
    }
    let barcodes = (barcodeReq.results ?? []).compactMap { $0.payloadStringValue }.filter { !$0.isEmpty }
    searchable.append(contentsOf: barcodes)
    var seen = Set<String>()
    let text = searchable.filter { seen.insert($0).inserted }.joined(separator: " ")
    return [
        "ocr": ocr,
        "tags": tags,
        "animals": animals,
        "peopleCount": people,
        "barcodes": barcodes,
        "featurePrintDims": fpReq.results?.first?.elementCount ?? 0,
        "searchableText": text,
    ]
}

func visionOrError(_ image: CGImage?) -> [String: Any] {
    guard let image else {
        return ["error": "could not load", "searchableText": ""]
    }
    do {
        return try runVision(image)
    } catch {
        return ["error": error.localizedDescription, "searchableText": ""]
    }
}

func runNL(_ text: String) -> [String: Any] {
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

func unzipMember(_ path: String, member: String) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments = ["-p", path, member]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return "" }
    // Read while unzip runs: a slide XML may exceed the pipe buffer.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return "" }
    guard let xml = String(data: data, encoding: .utf8) else { return "" }
    let stripped = xml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    return String(
        stripped.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(4000)
    )
}

func clipAudio(_ url: URL, maxSeconds: Double) -> (URL, Bool) {
    let asset = AVURLAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    if duration.isNaN || duration <= maxSeconds { return (url, false) }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        return (url, false)
    }
    session.outputURL = tmp
    session.outputFileType = .m4a
    session.timeRange = CMTimeRange(
        start: .zero,
        duration: CMTime(seconds: maxSeconds, preferredTimescale: 600)
    )
    let sem = DispatchSemaphore(value: 0)
    session.exportAsynchronously { sem.signal() }
    _ = sem.wait(timeout: .now() + 60)
    if session.status == .completed { return (tmp, true) }
    return (url, false)
}

func transcribe(_ url: URL) -> [String: Any] {
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        ?? SFSpeechRecognizer()
    guard let recognizer else {
        return ["error": "no recognizer", "searchableText": ""]
    }
    if !recognizer.isAvailable {
        return ["error": "recognizer unavailable", "searchableText": ""]
    }
    let (clip, clipped) = clipAudio(url, maxSeconds: 45)
    defer {
        if clipped { try? FileManager.default.removeItem(at: clip) }
    }
    let request = SFSpeechURLRecognitionRequest(url: clip)
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    request.shouldReportPartialResults = false
    let sem = DispatchSemaphore(value: 0)
    var transcript = ""
    var err: String?
    let task = recognizer.recognitionTask(with: request) { result, error in
        if let result { transcript = result.bestTranscription.formattedString }
        if let error { err = error.localizedDescription }
        if result?.isFinal == true || error != nil { sem.signal() }
    }
    if sem.wait(timeout: .now() + 75) == .timedOut {
        task.cancel()
        if err == nil { err = "timeout" }
    }
    var out: [String: Any] = [
        "transcript": transcript,
        "onDevice": recognizer.supportsOnDeviceRecognition,
        "locale": recognizer.locale.identifier,
        "clippedSeconds": clipped ? 45 : 0,
        "searchableText": transcript,
    ]
    if let err { out["error"] = err }
    return out
}

func mergeRecord(root: URL, file: URL, kind: String, local: [String: Any]) {
    let rel = String(file.path.dropFirst(root.path.count + 1))
    let dest = sidecarURL(root: root, rel: rel)
    var record = loadJSON(dest)
    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    record["version"] = 1
    record["sourceRelative"] = rel
    record["kind"] = kind
    record["size"] = size
    record["mtime"] = mtime
    record["hash"] = "\(size)-\(mtime)"
    record["scannedAt"] = iso.string(from: Date())
    record["keyframes"] = [] as [Any]
    var existingLocal = record["localScan"] as? [String: Any] ?? [:]
    for (k, v) in local { existingLocal[k] = v }
    record["localScan"] = existingLocal
    record.removeValue(forKey: "vision")
    record.removeValue(forKey: "provider")
    record.removeValue(forKey: "llm")
    record.removeValue(forKey: "matrixScanner")
    record.removeValue(forKey: "caption")
    record.removeValue(forKey: "summary")
    do {
        try writeJSON(record, to: dest)
        log("ok  \(rel)")
    } catch {
        log("fail \(rel) \(error.localizedDescription)")
    }
}

func collect(root: URL) -> [URL] {
    guard let en = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var urls: [URL] = []
    for case let url as URL in en {
        if url.path.contains("/scanner/") { continue }
        let name = url.lastPathComponent
        if name.hasPrefix("vision-probe-report") || name == "README.md" { continue }
        let ext = url.pathExtension.lowercased()
        if imageExts.contains(ext) || videoExts.contains(ext) || audioExts.contains(ext)
            || textExts.contains(ext) || pdfExts.contains(ext) || officeExts.contains(ext)
        {
            urls.append(url)
        }
    }
    return urls.sorted { $0.path < $1.path }
}

func scanFile(_ file: URL, root: URL, trySpeech: Bool) {
    let ext = file.pathExtension.lowercased()
    if imageExts.contains(ext) {
        mergeRecord(root: root, file: file, kind: "image", local: [
            "vision": visionOrError(cgFromImageFile(file)),
        ])
    } else if videoExts.contains(ext) {
        mergeRecord(root: root, file: file, kind: "video", local: [
            "vision": visionOrError(videoFrame(file)),
        ])
    } else if audioExts.contains(ext) {
        var speech: [String: Any]
        if trySpeech {
            log("speech \(file.lastPathComponent)…")
            speech = transcribe(file)
        } else {
            speech = ["error": "skipped", "searchableText": ""]
        }
        mergeRecord(root: root, file: file, kind: "audio", local: ["speech": speech])
    } else if pdfExts.contains(ext) {
        let text = pdfText(file)
        mergeRecord(root: root, file: file, kind: "document", local: [
            "vision": visionOrError(pdfPageImage(file)),
            "naturalLanguage": runNL(text),
        ])
    } else if officeExts.contains(ext) {
        let member = ext == "docx" ? "word/document.xml" : "ppt/slides/slide1.xml"
        let text = unzipMember(file.path, member: member)
        mergeRecord(root: root, file: file, kind: "document", local: [
            "naturalLanguage": runNL(text),
        ])
    } else if textExts.contains(ext) {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let kind = ext == "csv" || ext == "tsv" ? "spreadsheet" : (ext == "json" ? "other" : "document")
        mergeRecord(root: root, file: file, kind: kind, local: [
            "naturalLanguage": runNL(text),
        ])
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: local-scan <library-root> [--audio-only]\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: args[1], isDirectory: true)
let audioOnly = args.contains("--audio-only")
let files = collect(root: root)
let nonAudio = audioOnly ? [] : files.filter { !audioExts.contains($0.pathExtension.lowercased()) }
let audio = files.filter { audioExts.contains($0.pathExtension.lowercased()) }
log("files \(files.count) (non-audio \(nonAudio.count), audio \(audio.count))")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

DispatchQueue.global(qos: .userInitiated).async {
    for file in nonAudio {
        scanFile(file, root: root, trySpeech: false)
    }
    log("non-audio done")
    DispatchQueue.global(qos: .userInitiated).async {
        log("speech auth \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        for file in audio {
            scanFile(file, root: root, trySpeech: true)
        }
        log("done")
        exit(0)
    }
}

app.run()
