import AppKit
import QuickLookUI

final class FilePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FilePreview()

    private var url: URL?

    var isVisible: Bool {
        QLPreviewPanel.shared()?.isVisible == true
    }

    func show(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        url = URL(fileURLWithPath: path)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        QLPreviewPanel.shared()?.close()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/")) as QLPreviewItem
    }
}
