import AppKit
import SwiftUI

/// Keep IME composition in the native field editor, outside search result updates.
struct SearchInput: NSViewRepresentable {
    @Binding var text: String
    var suggestion: AITabSuggestion?
    var acceptSuggestion: () -> Bool
    var moveSuggestion: (Int) -> Bool
    var dismissSuggestion: () -> Bool
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputContainer {
        let container = InputContainer()
        let field = container.input
        field.placeholderString = "搜一切"
        field.setAccessibilityLabel("搜一切")
        field.stringValue = text
        field.delegate = context.coordinator
        container.updateGhost(prefix: text, suggestion: suggestion)
        return container
    }

    func updateNSView(_ container: InputContainer, context: Context) {
        context.coordinator.parent = self
        let field = container.input
        // Result list redraws must never replace marked text or reset its selection.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
        container.updateGhost(prefix: text, suggestion: suggestion)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchInput
        init(_ parent: SearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            // Marked Pinyin text is intentionally not published to SwiftUI yet, but it still
            // needs to make background scanning yield immediately.
            ScanControl.shared.noteInteractiveWork()
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                return parent.acceptSuggestion()
            case #selector(NSResponder.moveUp(_:)):
                return parent.moveSuggestion(-1)
            case #selector(NSResponder.moveDown(_:)):
                return parent.moveSuggestion(1)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.dismissSuggestion()
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            default:
                return false
            }
        }
    }

    final class InputContainer: NSView {
        let input = InputField()
        private let ghost = NSTextField()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            for field in [ghost, input] {
                field.font = .systemFont(ofSize: 18)
                field.isBezeled = false
                field.drawsBackground = false
                field.focusRingType = .none
                field.cell?.usesSingleLineMode = true
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            }
            ghost.isEditable = false
            ghost.isSelectable = false
            ghost.isEnabled = false
            input.isEditable = true
            input.isSelectable = true
            addSubview(ghost)
            addSubview(input)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            ghost.frame = bounds
            input.frame = bounds
        }

        func updateGhost(prefix: String, suggestion: AITabSuggestion?) {
            guard (input.currentEditor() as? NSTextView)?.hasMarkedText() != true,
                  let suggestion else {
                ghost.stringValue = ""
                return
            }
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == prefix, !trimmed.isEmpty else {
                ghost.stringValue = ""
                return
            }
            let suffix = suggestion.suffix(after: trimmed)
            guard !suffix.isEmpty else {
                ghost.stringValue = ""
                return
            }
            let font = NSFont.systemFont(ofSize: 18)
            let text = NSMutableAttributedString(
                string: prefix,
                attributes: [.font: font, .foregroundColor: NSColor.clear]
            )
            text.append(NSAttributedString(
                string: suffix,
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            ))
            ghost.attributedStringValue = text
        }
    }

    final class InputField: NSTextField {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
                  let key = event.charactersIgnoringModifiers?.lowercased() else {
                return super.performKeyEquivalent(with: event)
            }
            let action: Selector?
            switch key {
            case "a": action = #selector(NSText.selectAll(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "v": action = #selector(NSText.paste(_:))
            case "z": action = flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
            default: action = nil
            }
            guard let action else { return super.performKeyEquivalent(with: event) }
            return NSApp.sendAction(action, to: nil, from: self)
                || super.performKeyEquivalent(with: event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
