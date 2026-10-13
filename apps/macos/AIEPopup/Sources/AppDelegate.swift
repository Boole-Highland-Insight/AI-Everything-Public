import AppKit
import Carbon
import Combine
import SwiftUI

extension Notification.Name {
    static let aieTogglePanel = Notification.Name("aieTogglePanel")
}

private func aieHotKeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ theEvent: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .aieTogglePanel, object: nil)
    }
    return noErr
}

@main
enum AIEMain {
    static func main() {
        if LibraryRoots.runIfRequested()
            || OnboardingDemoExport.runIfRequested()
            || IndexingStatusDiagnostics.runIfRequested()
            || OnboardingDiagnostics.runIfRequested() || ModelDetectionDiagnostics.runIfRequested()
            || PhotoImportDiagnostics.runIfRequested() || LocalQuickScanDiagnostics.runIfRequested()
            || SearchAuditDiagnostics.runIfRequested() || SearchEvaluationDiagnostics.runIfRequested()
            || SemanticDiagnostics.runIfRequested() || VectorIndexDiagnostics.runIfRequested()
            || StorageDiagnostics.runIfRequested() || JunkClassifierDiagnostics.runIfRequested()
            || ReusePPTXDiagnostics.runIfRequested() || AITabDiagnostics.runIfRequested()
            || ScanPolicy.runIfRequested() || MediaDiagnostics.runIfRequested()
            || IndexDiagnostics.runIfRequested() { return }
        AppLog.write("main-entered")
        let app = NSApplication.shared
        AppLog.write("got-app")
        let delegate = AppDelegate.shared
        AppLog.write("got-delegate")
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        delegate.start()
        AppLog.write("start-returned")
        app.run()
    }
}

final class AIEWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AIEScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 不画轨道，避免右边一条深色槽
    }

    override func drawKnob() {
        var rect = rect(for: .knob).insetBy(dx: 4.5, dy: 3)
        if rect.width < 3 { rect.size.width = 3 }
        if rect.height < 16 { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2)
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        path.fill()
    }
}

final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        polishScrollers(in: self)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.polishScrollers(in: self)
        }
    }

    override func layout() {
        super.layout()
        polishScrollers(in: self)
    }

    private func polishScrollers(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.scrollerStyle = .overlay
            scroll.scrollerKnobStyle = .light
            scroll.autohidesScrollers = true
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = true
            scroll.verticalScrollElasticity = .allowed
            if !(scroll.verticalScroller is AIEScroller) {
                let scroller = AIEScroller()
                scroller.controlSize = .mini
                scroller.scrollerStyle = .overlay
                scroll.verticalScroller = scroller
            }
        }
        view.subviews.forEach { polishScrollers(in: $0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private var started = false
    private var launchRoutingComplete = false
    private var configurationWindowBlocking = false
    private var statusItem: NSStatusItem?
    private var panel: NSWindow?
    private var scanWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var reuseWindow: NSWindow?
    private var model = SearchModel()
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var shortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        registerHotKey()
        NotificationCenter.default.addObserver(
            forName: .aieTogglePanel, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if DeviceSetup.shared.practiceShortcut() { return }
                self?.showPanel()
            }
        }
        model.$reusePhase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if phase.isActive {
                    self.presentReuseWindow()
                } else {
                    self.dismissReuseWindow()
                }
            }
            .store(in: &cancellables)
        // 窗口必须在 run loop + 激活之后再创建，否则会落到不可见的 Space
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let onboarding = DeviceSetup.shared.presentIfNeeded(
                configure: { [weak self] urls in self?.model.configureInitialSources(urls) },
                finished: { [weak self] in
                    self?.configurationWindowBlocking = false
                    self?.model.loadAsync()
                    self?.showPanel()
                }
            )
            self.configurationWindowBlocking = onboarding
            self.launchRoutingComplete = true
            if !onboarding { self.model.loadAsync(); self.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let minimized = NSApp.windows.first(where: { $0.isMiniaturized }) {
                AppWindowPresence.shared.show(minimized)
            } else { showPanel() }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopWatching()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        SearchShortcutSettings.shared.stop()
        OwnedModelProcesses.stop()
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let show = NSMenuItem(
            title: "显示搜索窗口",
            action: #selector(showPanel),
            keyEquivalent: "l"
        )
        show.target = self
        appMenu.addItem(show)
        let scan = NSMenuItem(
            title: "后台扫描…",
            action: #selector(showScanWindow),
            keyEquivalent: ""
        )
        scan.target = self
        appMenu.addItem(scan)
        let folders = NSMenuItem(
            title: "选择资料夹…",
            action: #selector(pickFolders),
            keyEquivalent: "o"
        )
        folders.target = self
        appMenu.addItem(folders)
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let tutorial = appMenu.addItem(withTitle: "重新打开新手引导…", action: #selector(showOnboarding), keyEquivalent: "")
        tutorial.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "退出 AI Everything",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "AIE"
        item.button?.toolTip = "点击搜索 · 右键打开菜单"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type != .rightMouseUp { showPanel(); return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "打开搜索", action: #selector(showPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "后台扫描…", action: #selector(showScanWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: ScanControl.shared.isPaused ? "继续扫描" : "暂停扫描",
                     action: #selector(toggleScanning), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "重新打开新手引导…", action: #selector(showOnboarding), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AI Everything", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { statusItem?.menu = nil }

    @objc private func toggleScanning() { model.toggleScanning() }

    @MainActor @objc func showSettings() {
        guard !configurationWindowBlocking else { DeviceSetup.shared.bringToFront(); return }
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: APISettingsView(model: model)))
            window.title = "AI Everything 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 430, height: 600))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        if let settingsWindow { AppWindowPresence.shared.show(settingsWindow) }
    }

    @MainActor @objc func showOnboarding() {
        hidePanel()
        AppWindowPresence.shared.hide(settingsWindow)
        configurationWindowBlocking = true
        DeviceSetup.shared.presentGuide(
            configure: { [weak self] urls in self?.model.configureInitialSources(urls) },
            finished: { [weak self] in
                self?.configurationWindowBlocking = false
                self?.model.loadAsync()
                self?.showPanel()
            }
        )
    }

    private func setupPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let rect = NSRect(
            x: visible.midX - 310,
            y: visible.midY - 240,
            width: 620,
            height: 480
        )
        let window = AIEWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "AI Everything"
        window.level = .floating
        window.sharingType = .readWrite
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let root = SearchPanelView(model: model, onDismiss: { [weak self] in
            self?.hidePanel()
        })
        let host = ClearHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 480)
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setContentSize(NSSize(width: 620, height: 480))

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let eventWindow = event.window ?? NSApp.keyWindow
            if MediaTimeWindow.shared.owns(eventWindow) {
                if event.keyCode == 53 {
                    MediaTimeWindow.shared.close()
                    return nil
                }
                // Keep Space and arrow keys in AVPlayerView; they must not select another search result.
                return event
            }
            if eventWindow === self.reuseWindow {
                return self.handleReuseKey(event)
            }
            guard self.panel?.isVisible == true, eventWindow === self.panel else { return event }
            // Candidate navigation and confirmation belong to the input method.
            if let editor = eventWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            if eventWindow?.firstResponder is NSTextView, self.model.tabSuggestion != nil {
                if event.keyCode == 53, self.model.dismissTabSuggestion() { return nil }
                if event.keyCode == 125, self.model.moveTabSuggestion(1) { return nil }
                if event.keyCode == 126, self.model.moveTabSuggestion(-1) { return nil }
                let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 48, flags.isEmpty,
                   self.model.acceptTabSuggestion() { return nil }
            }
            if event.keyCode == 53 {
                if FilePreview.shared.isVisible, !self.model.reusePhase.isActive {
                    FilePreview.shared.close()
                    return nil
                }
                if self.model.recycleMode {
                    self.model.toggleRecycle()
                    return nil
                }
                self.hidePanel()
                return nil
            }
            if event.keyCode == 49 {
                if MediaTimeWindow.shared.isVisible {
                    MediaTimeWindow.shared.close()
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.panel?.makeFirstResponder(nil)
                    return nil
                }
                if PDFPageWindow.shared.isVisible {
                    PDFPageWindow.shared.close()
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.panel?.makeFirstResponder(nil)
                    return nil
                }
                if FilePreview.shared.isVisible {
                    FilePreview.shared.close()
                    self.panel?.makeKeyAndOrderFront(nil)
                    self.panel?.makeFirstResponder(nil)
                    return nil
                }
                if self.model.recycleMode {
                    self.model.previewSelected()
                    return nil
                }
                if !(eventWindow?.firstResponder is NSTextView) {
                    _ = self.model.openSelected()
                    return nil
                }
                return event
            }
            if FilePreview.shared.isVisible {
                return event
            }
            if event.keyCode == 125 {
                eventWindow?.makeFirstResponder(nil)
                self.model.moveSelection(1)
                return nil
            }
            if event.keyCode == 126 {
                eventWindow?.makeFirstResponder(nil)
                self.model.moveSelection(-1)
                return nil
            }
            if event.keyCode == 36 {
                if event.modifierFlags.contains(.command) {
                    self.model.revealSelected()
                } else if eventWindow?.firstResponder is NSTextView {
                    MainActor.assumeIsolated {
                        if self.model.handleReturn() { self.hidePanel() }
                    }
                } else {
                    _ = self.model.openSelected()
                }
                return nil
            }
            return event
        }
        self.panel = window
    }

    private func setupScanWindow() {
        let window = AIEWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "后台扫描"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        let root = BackgroundScanView(model: model, onDismiss: { [weak self] in
            self?.hideScanWindow()
        })
        let host = ClearHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 430, height: 540)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        scanWindow = window
    }

    private func handleReuseKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            if FilePreview.shared.isVisible {
                FilePreview.shared.close()
                return nil
            }
            if case .done = model.reusePhase {
                model.finishReuse()
            } else {
                model.cancelReuse()
            }
            return nil
        }
        if FilePreview.shared.isVisible {
            return event
        }
        if case .choose(let proposal) = model.reusePhase {
            if reuseWindow?.firstResponder is NSTextView {
                return event
            }
            let map: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D"]
            if let letter = map[event.keyCode],
               let option = proposal.options.first(where: { $0.id == letter }) {
                model.pickReuse(option)
                return nil
            }
        }
        return event
    }

    func presentReuseWindow() {
        if reuseWindow == nil { setupReuseWindow() }
        guard let reuseWindow else { return }
        let size: NSSize
        if case .done = model.reusePhase {
            size = NSSize(width: 1040, height: 700)
        } else {
            size = NSSize(width: 480, height: 540)
        }
        reuseWindow.setContentSize(size)
        if !reuseWindow.isVisible {
            var frame = NSRect(x: 80, y: 80, width: size.width, height: size.height)
            if let panel, panel.isVisible {
                frame.origin = NSPoint(
                    x: panel.frame.maxX + 12,
                    y: panel.frame.maxY - size.height
                )
                if let screen = panel.screen ?? NSScreen.main {
                    let vis = screen.visibleFrame
                    if frame.maxX > vis.maxX {
                        frame.origin.x = panel.frame.minX - size.width - 12
                    }
                    if frame.minY < vis.minY {
                        frame.origin.y = vis.minY + 20
                    }
                }
            } else if let screen = NSScreen.main ?? NSScreen.screens.first {
                let vis = screen.visibleFrame
                frame.origin = NSPoint(
                    x: vis.midX - size.width / 2 + 80,
                    y: vis.midY - size.height / 2
                )
            }
            reuseWindow.setFrame(frame, display: true)
        }
        AppWindowPresence.shared.show(reuseWindow)
    }

    private func dismissReuseWindow() {
        AppWindowPresence.shared.hide(reuseWindow)
    }

    private func setupReuseWindow() {
        let window = AIEWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "咔哒一下"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 540)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        // The titled window supplies the outer corners; its content must meet the title bar squarely.
        let host = NSHostingView(rootView: ReuseSessionView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 540)
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        reuseWindow = window
    }

    @objc func showPanel() {
        guard launchRoutingComplete else { return }
        guard !configurationWindowBlocking else {
            MainActor.assumeIsolated { DeviceSetup.shared.bringToFront() }
            return
        }
        if panel == nil { setupPanel() }
        guard let panel else { return }
        model.refresh()
        Task.detached(priority: .utility) { await LocalSemanticIndex.shared.warmUp() }
        let size = NSSize(width: 620, height: 480)
        panel.setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: panel.frame.width,
                height: panel.frame.height
            )
            panel.setFrame(frame, display: true)
        } else {
            panel.center()
        }
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.deminiaturize(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        aieLog("showPanel visible=\(panel.isVisible) occluded=\(panel.occlusionState.contains(.visible)) alpha=\(panel.alphaValue) frame=\(NSStringFromRect(panel.frame))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
            guard let panel else { return }
            AppDelegate.shared.aieLog("later visible=\(panel.isVisible) occluded=\(panel.occlusionState.contains(.visible))")
        }
    }

    @objc func showScanWindow() {
        guard launchRoutingComplete, !configurationWindowBlocking else { return }
        if scanWindow == nil { setupScanWindow() }
        guard let scanWindow else { return }
        scanWindow.setContentSize(NSSize(width: 430, height: 540))
        if !scanWindow.isVisible {
            if let panel, panel.isVisible {
                var origin = NSPoint(x: panel.frame.maxX + 12, y: panel.frame.maxY - scanWindow.frame.height)
                if let visible = panel.screen?.visibleFrame, origin.x + scanWindow.frame.width > visible.maxX {
                    origin.x = panel.frame.minX - scanWindow.frame.width - 12
                }
                scanWindow.setFrameOrigin(origin)
            } else {
                scanWindow.center()
            }
        }
        AppWindowPresence.shared.show(scanWindow)
    }

    func hideScanWindow() {
        AppWindowPresence.shared.hide(scanWindow)
    }

    fileprivate func aieLog(_ line: String) {
        AppLog.write(line)
    }

    @objc private func pickFolders() {
        showPanel()
        model.addFolders(from: panel)
    }

    private func hidePanel() {
        if !model.reusePhase.isActive {
            FilePreview.shared.close()
        }
        panel?.orderOut(nil)
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            aieHotKeyCallback,
            1,
            &eventType,
            nil,
            &hotKeyHandler
        )

        SearchShortcutSettings.shared.start(handlerStatus: handlerStatus)
        // Accessibility-generated key events can be delivered directly to the active app,
        // bypassing Carbon's system-wide hotkey routing. Keep the same shortcut in-app too.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let shortcut = SearchShortcutSettings.shared
            guard shortcut.registered, shortcut.selected.matches(event) else { return event }
            NotificationCenter.default.post(name: .aieTogglePanel, object: nil)
            return nil
        }
    }
}
