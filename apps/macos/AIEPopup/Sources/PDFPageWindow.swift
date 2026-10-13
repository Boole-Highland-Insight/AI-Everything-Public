import AppKit
import PDFKit

/// Opens a PDF at the page carried by search evidence, without depending on Preview automation.
final class PDFPageWindow: NSObject, NSWindowDelegate {
    static let shared = PDFPageWindow()
    private var window: NSWindow?
    private var pdfView: PDFView?

    var isVisible: Bool { window?.isVisible == true }

    @discardableResult
    func show(url: URL, page: Int?) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        if window == nil { setup() }
        guard let window, let pdfView else { return false }
        pdfView.document = document
        let index = min(max((page ?? 1) - 1, 0), max(document.pageCount - 1, 0))
        if let pdfPage = document.page(at: index) {
            pdfView.go(to: pdfPage)
        }
        if let page, page > 0 {
            window.title = "\(url.lastPathComponent) · 第 \(page) 页"
        } else {
            window.title = url.lastPathComponent
        }
        AppWindowPresence.shared.show(window)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func close() {
        AppWindowPresence.shared.hide(window)
    }

    private func setup() {
        let frame = NSRect(x: 0, y: 0, width: 820, height: 640)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let view = PDFView(frame: frame)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.center()
        self.window = window
        self.pdfView = view
    }

    func windowWillClose(_ notification: Notification) {
        pdfView?.document = nil
    }
}
