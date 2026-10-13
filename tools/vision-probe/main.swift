import AppKit
import AVFoundation
import CoreImage
import Foundation
import Vision

/// Offline Vision probe: OCR, classify, animals, humans, barcodes, feature-print.
/// All requests are Vision.framework on-device. No network.

struct ProbeResult: Encodable {
    var path: String
    var kind: String
    var ocr: [String]
    var tags: [String]
    var animals: [String]
    var peopleCount: Int
    var barcodes: [String]
    var featurePrintDims: Int
    var error: String?
}

func cgImage(from url: URL) -> CGImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var rect = NSRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func extractKeyframe(video url: URL, at seconds: Double) -> CGImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    return try? generator.copyCGImage(at: time, actualTime: nil)
}

func runVision(_ image: CGImage) throws -> (
    ocr: [String],
    tags: [String],
    animals: [String],
    people: Int,
    barcodes: [String],
    fpDims: Int
) {
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

    let tags = (classifyReq.results ?? [])
        .filter { $0.confidence >= 0.25 }
        .prefix(8)
        .map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }

    let animals = (animalReq.results ?? []).compactMap { obs -> String? in
        guard let label = obs.labels.first else { return nil }
        return "\(label.identifier) \(String(format: "%.2f", label.confidence))"
    }

    let people = humanReq.results?.count ?? 0

    let barcodes = (barcodeReq.results ?? []).compactMap { obs -> String? in
        let payload = obs.payloadStringValue ?? ""
        if payload.isEmpty { return obs.symbology.rawValue }
        return "\(obs.symbology.rawValue): \(payload)"
    }

    let fpDims = fpReq.results?.first?.elementCount ?? 0
    return (ocr, Array(tags), animals, people, barcodes, fpDims)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "probe", code: 1) }
    try data.write(to: url)
}

func makeOCRCard(to url: URL) throws {
    let size = NSSize(width: 1200, height: 640)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let title = "苏格兰徒步 2026\nBen Nevis · Glencoe\n发票编号 INV-8842\nCairngorms National Park"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 42, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    title.draw(in: NSRect(x: 64, y: 80, width: 1070, height: 480), withAttributes: attrs)
    image.unlockFocus()
    try writePNG(image, to: url)
}

func makeQR(payload: String, to url: URL) throws {
    let data = Data(payload.utf8)
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
        throw NSError(domain: "probe", code: 2)
    }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard var ciImage = filter.outputImage else { throw NSError(domain: "probe", code: 3) }
    let scale = CGAffineTransform(scaleX: 12, y: 12)
    ciImage = ciImage.transformed(by: scale)
    let rep = NSCIImageRep(ciImage: ciImage)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    try writePNG(image, to: url)
}

func probeFile(_ url: URL) -> ProbeResult {
    let ext = url.pathExtension.lowercased()
    let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm"]
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "bmp", "gif"]
    var kind = "skip"
    var image: CGImage?

    if imageExts.contains(ext) {
        kind = "image"
        image = cgImage(from: url)
    } else if videoExts.contains(ext) {
        kind = "video-keyframe"
        image = extractKeyframe(video: url, at: 1.0) ?? extractKeyframe(video: url, at: 0.0)
    } else {
        return ProbeResult(
            path: url.path, kind: "skip", ocr: [], tags: [], animals: [],
            peopleCount: 0, barcodes: [], featurePrintDims: 0, error: nil
        )
    }

    guard let image else {
        return ProbeResult(
            path: url.path, kind: kind, ocr: [], tags: [], animals: [],
            peopleCount: 0, barcodes: [], featurePrintDims: 0, error: "could not load image"
        )
    }

    do {
        let r = try runVision(image)
        return ProbeResult(
            path: url.path, kind: kind, ocr: r.ocr, tags: r.tags, animals: r.animals,
            peopleCount: r.people, barcodes: r.barcodes, featurePrintDims: r.fpDims, error: nil
        )
    } catch {
        return ProbeResult(
            path: url.path, kind: kind, ocr: [], tags: [], animals: [],
            peopleCount: 0, barcodes: [], featurePrintDims: 0, error: error.localizedDescription
        )
    }
}

func collectMedia(in root: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let en = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
    ) else { return [] }
    var urls: [URL] = []
    let allow: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "m4v"]
    for case let url as URL in en {
        if url.path.contains("/scanner/") { continue }
        if allow.contains(url.pathExtension.lowercased()) { urls.append(url) }
    }
    return urls.sorted { $0.path < $1.path }
}

func markdown(from results: [ProbeResult]) -> String {
    var lines: [String] = [
        "# Vision 离线探测报告",
        "",
        "全部为本机 `Vision.framework`，无网络。",
        "",
        "| 文件 | 类型 | OCR | 分类标签 | 动物 | 人数 | 条码 |",
        "|---|---|---|---|---|---|---|",
    ]
    for r in results where r.kind != "skip" {
        let name = URL(fileURLWithPath: r.path).lastPathComponent
        func cell(_ items: [String]) -> String {
            let s = items.joined(separator: "; ").replacingOccurrences(of: "|", with: "/")
            return s.isEmpty ? "—" : s
        }
        let err = r.error.map { "ERR: \($0)" } ?? ""
        lines.append(
            "| \(name) | \(r.kind) | \(cell(r.ocr) + err) | \(cell(r.tags)) | \(cell(r.animals)) | \(r.peopleCount) | \(cell(r.barcodes)) |"
        )
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: vision-probe <library-root>\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: args[1], isDirectory: true)
let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
try makeOCRCard(to: fixtures.appendingPathComponent("ocr-card.png"))
try makeQR(payload: "AIEVERYTHING-DEMO-42", to: fixtures.appendingPathComponent("qr-demo.png"))

var targets = collectMedia(in: root)
// Keep the probe short: all photos + fixtures + first 2 videos.
let videos = targets.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
let images = targets.filter { !["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
targets = images + Array(videos.prefix(2))

var results: [ProbeResult] = []
for url in targets {
    fputs("probing \(url.lastPathComponent)\n", stderr)
    results.append(probeFile(url))
}

let report = markdown(from: results)
let reportURL = root.appendingPathComponent("vision-probe-report.md")
try report.write(to: reportURL, atomically: true, encoding: .utf8)
let jsonURL = root.appendingPathComponent("vision-probe-report.json")
let json = try JSONEncoder().encode(results)
try json.write(to: jsonURL)
print(report)
print("wrote \(reportURL.path)")
