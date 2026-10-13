import AppKit
import Carbon

@main enum DesktopBehaviorChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        precondition(
            NSApp.activationPolicy() == .accessory || NSApp.setActivationPolicy(.accessory),
            "Match the app's menu-bar launch policy"
        )
        let domain = "aie.desktop-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var released: [EventHotKeyRef] = []
        var conflict = false
        var count = 0
        let settings = SearchShortcutSettings(defaults: defaults, register: { _, ref in
            if conflict { return OSStatus(eventHotKeyExistsErr) }
            count += 1
            ref = EventHotKeyRef(bitPattern: count)
            return noErr
        }, unregister: { released.append($0) })
        settings.start(handlerStatus: -1)
        precondition(!settings.registered && settings.error != nil && count == 0)
        settings.start(handlerStatus: noErr)
        precondition(settings.registered && settings.selected == .optionSpace)
        conflict = true
        settings.choose(.commandShiftF)
        precondition(settings.selected == .optionSpace && released.isEmpty && settings.error != nil)
        precondition(defaults.string(forKey: SearchShortcutSettings.preferenceKey) == "optionSpace")
        conflict = false
        settings.choose(.controlOptionSpace)
        precondition(settings.selected == .controlOptionSpace && released.count == 1 && settings.error == nil)
        settings.choose(.controlOptionSpace)
        precondition(count == 2, "Re-selecting the active shortcut must not unregister it")
        settings.stop()
        precondition(released.count == 2 && !settings.registered)
        let restored = SearchShortcutSettings(defaults: defaults)
        precondition(restored.selected == .controlOptionSpace)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .option, .capsLock], timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        precondition(SearchShortcut.controlOptionSpace.matches(key))
        precondition(!SearchShortcut.optionSpace.matches(key) && !SearchShortcut.commandShiftF.matches(key))

        let presence = AppWindowPresence.shared
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: first.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        presence.show(first)
        precondition(NSApp.activationPolicy() == .regular)
        presence.show(second)
        presence.hide(first)
        precondition(NSApp.activationPolicy() == .regular, "A second window must retain the Dock entry")
        second.close()
        precondition(NSApp.activationPolicy() == .accessory)
        presence.show(first)
        first.miniaturize(nil)
        precondition(NSApp.activationPolicy() == .regular, "Minimized windows need a Dock entry for restoration")
        presence.hide(first)
        precondition(NSApp.activationPolicy() == .accessory)
        presence.show(first)
        first.close()
        precondition(NSApp.activationPolicy() == .accessory)

        let owned = Process(); owned.executableURL = URL(fileURLWithPath: "/bin/sleep"); owned.arguments = ["30"]
        let external = Process(); external.executableURL = owned.executableURL; external.arguments = ["30"]
        try external.run()
        defer { if external.isRunning { external.terminate() } }
        try OwnedModelProcesses.run(owned)
        OwnedModelProcesses.stop()
        let deadline = Date().addingTimeInterval(3)
        while owned.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(!owned.isRunning && external.isRunning, "Quit must only terminate app-owned services")
        let late = Process(); late.executableURL = owned.executableURL; late.arguments = ["30"]
        do { try OwnedModelProcesses.run(late); fatalError("Service started after shutdown") }
        catch is CancellationError {} catch { throw error }
        print("Desktop checks passed: shortcut conflict, persistence, replacement, handler failure; Dock multiple-window, minimize, reopen and close; owned-service shutdown and late-start prevention.")
    }
}
