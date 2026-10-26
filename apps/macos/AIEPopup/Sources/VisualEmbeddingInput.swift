import Foundation
import AppKit
import PDFKit
import AVFoundation
import AIEData

enum VisualEmbeddingInput {
    static func renderQuery(_ url: URL) throws -> URL {
        guard let image = NSImage(contentsOf: url) else { throw GemmaError.badResponse }
        return try saveJPEG(image)
    }

    static func render(_ chunk: ChunkResult) throws -> URL {
        let source = URL(fileURLWithPath: chunk.path)
        let image: NSImage
        switch chunk.kind {
        case "visual_image":
            guard let loaded = NSImage(contentsOf: source) else { throw GemmaError.badResponse }
            image = loaded
        case "visual_page":
            guard let page = chunk.page, page > 0,
                  let document = PDFDocument(url: source),
                  let pdfPage = document.page(at: page - 1) else { throw GemmaError.badResponse }
            image = pdfPage.thumbnail(of: CGSize(width: 1120, height: 1120), for: .mediaBox)
        case "visual_frame":
            guard let seconds = chunk.startSeconds else { throw GemmaError.badResponse }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        default: throw GemmaError.badResponse
        }
        return try saveJPEG(image)
    }

    private static func saveJPEG(_ image: NSImage) throws -> URL {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.84])
        else { throw GemmaError.badResponse }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("aie-gemma-\(UUID().uuidString).jpg")
        try jpeg.write(to: target, options: .atomic)
        return target
    }
}
