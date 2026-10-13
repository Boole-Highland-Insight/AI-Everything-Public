import AppKit
import Carbon
import Combine
import SwiftUI

enum SearchShortcut: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, commandShiftF
    var id: Self { self }
    var title: String {
        switch self {
        case .optionSpace: return "⌥ 空格"
        case .controlOptionSpace: return "⌃ ⌥ 空格"
        case .commandShiftF: return "⌘ ⇧ F"
        }
    }
    var keyCode: UInt32 { self == .commandShiftF ? UInt32(kVK_ANSI_F) : UInt32(kVK_Space) }
    var modifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftF: return UInt32(cmdKey | shiftKey)
        }
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let expected: NSEvent.ModifierFlags
        switch self {
        case .optionSpace: expected = [.option]
        case .controlOptionSpace: expected = [.control, .option]
        case .commandShiftF: expected = [.command, .shift]
        }
        return UInt32(event.keyCode) == keyCode && flags == expected
    }
}

final class SearchShortcutSettings: ObservableObject {
    static let shared = SearchShortcutSettings()
    static let preferenceKey = "aie.search.shortcut"
    @Published private(set) var selected: SearchShortcut
    @Published private(set) var error: String?
    @Published private(set) var registered = false
    private var reference: EventHotKeyRef?
    private var handlerReady = false
    private let defaults: UserDefaults
    // Injection lets the conflict/recovery checks run without claiming a real global shortcut.
    private let register: (SearchShortcut, inout EventHotKeyRef?) -> OSStatus
    private let unregister: (EventHotKeyRef) -> Void

    init(defaults: UserDefaults = .standard,
         register: @escaping (SearchShortcut, inout EventHotKeyRef?) -> OSStatus = { choice, ref in
             RegisterEventHotKey(choice.keyCode, choice.modifiers,
                 EventHotKeyID(signature: OSType(0x41494531), id: 1),
                 GetApplicationEventTarget(), 0, &ref)
         }, unregister: @escaping (EventHotKeyRef) -> Void = { _ = UnregisterEventHotKey($0) }) {
        self.defaults = defaults
        self.register = register
        self.unregister = unregister
        selected = defaults.string(forKey: Self.preferenceKey).flatMap(SearchShortcut.init(rawValue:)) ?? .optionSpace
    }

    func start(handlerStatus: OSStatus) {
        handlerReady = handlerStatus == noErr
        guard handlerStatus == noErr else {
            error = "快捷键服务未能启动，请从菜单栏 AIE 打开搜索。"
            return
        }
        choose(selected)
    }

    func choose(_ choice: SearchShortcut) {
        guard handlerReady else {
            error = "快捷键服务未能启动，请从菜单栏 AIE 打开搜索。"
            return
        }
        if registered && choice == selected { error = nil; return }
        var replacement: EventHotKeyRef?
        let status = register(choice, &replacement)
        guard status == noErr, let replacement else {
            error = "\(choice.title) 未能注册，可能已被其他应用占用。请选择其他组合；菜单栏 AIE 仍可打开搜索。"
            return
        }
        if let reference { unregister(reference) }
        reference = replacement
        selected = choice
        registered = true
        error = nil
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
    }

    func stop() {
        if let reference { unregister(reference) }
        reference = nil
        registered = false
    }
}

struct SearchShortcutPicker: View {
    @ObservedObject private var shortcut = SearchShortcutSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("唤起搜索", selection: Binding(get: { shortcut.selected }, set: { shortcut.choose($0) })) {
                ForEach(SearchShortcut.allCases) { Text($0.title).tag($0) }
            }
            if let error = shortcut.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("⌥ 是 Option（Alt），⌃ 是 Control，⌘ 是 Command，⇧ 是 Shift。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
