import AppKit
import Foundation

/// Opens a presentation at the page carried by search evidence.
///
/// Keynote has no public URL fragment for slide navigation, so page jumps use its
/// AppleScript dictionary. If Keynote is unavailable or automation is denied, the
/// file still opens through the user's default application.
enum PresentationOpener {
    @discardableResult
    static func open(
        path: String,
        page: Int?,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "webp", "heic", "bmp", "gif", "tif", "tiff"].contains(ext) {
            FilePreview.shared.show(path: path)
            return true
        }
        if MediaOpenPolicy.shouldUseTimedPlayer(path: path, startSeconds: startSeconds),
           let startSeconds = MediaOpenPolicy.seekSeconds(startSeconds),
           MediaTimeWindow.shared.show(
               url: url, startSeconds: startSeconds, endSeconds: endSeconds
           ) {
            return true
        }
        if ext == "pdf" {
            if PDFPageWindow.shared.show(url: url, page: page) { return true }
            return NSWorkspace.shared.open(url)
        }
        guard ["ppt", "pptx"].contains(ext),
              let page, page > 0,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil,
              !path.contains("\n"), !path.contains("\r")
        else {
            return NSWorkspace.shared.open(url)
        }

        let escapedPath = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        set targetPath to "\(escapedPath)"
        set targetPage to \(page)
        tell application id "com.apple.iWork.Keynote"
            activate
            open POSIX file targetPath
            repeat 50 times
                if (count of documents) > 0 then exit repeat
                delay 0.1
            end repeat
            if (count of documents) = 0 then error "Keynote did not open the presentation"
            tell front document
                set slideCount to count of slides
                if slideCount > 0 then
                    if targetPage > slideCount then set targetPage to slideCount
                    set current slide to slide targetPage
                end if
            end tell
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if result == nil || error != nil {
                AppLog.write("keynote-open: automation failed \(error ?? [:])")
                DispatchQueue.main.async {
                    _ = NSWorkspace.shared.open(url)
                }
            }
        }
        return true
    }
}
