import AppKit

/// Windows preserve menu-bar activation without a Dock entry.
final class AppWindowPresence: NSObject {
    static let shared = AppWindowPresence()
    private let windows = NSHashTable<NSWindow>.weakObjects()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    func show(_ window: NSWindow) {
        windows.add(window)
        NSApp.setActivationPolicy(.accessory)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide(_ window: NSWindow?) {
        guard let window else { return }
        window.orderOut(nil)
        windows.remove(window)
        refresh()
    }

    @objc private func willClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
        refresh()
    }

    private func refresh() {
        NSApp.setActivationPolicy(.accessory)
    }
}
