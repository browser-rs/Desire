import AppKit
import SwiftUI

struct URLBarField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var onSubmit: () -> Void
    var onPasteAndGo: () -> Void
    var onMoveSelection: (Int) -> Void
    var onEscape: () -> Void
    var onTextChange: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = URLTextField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = NSColor.labelColor
        field.placeholderString = String(localized: "Search or enter address")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.menu = context.coordinator.menu
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if isFocused.wrappedValue {
            nsView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLBarField
        let menu: NSMenu

        required init(_ parent: URLBarField) {
            self.parent = parent
            self.menu = NSMenu(title: "URL Bar")
            super.init()
            let pasteAndGo = NSMenuItem(title: String(localized: "Paste and Go"), action: #selector(pasteAndGoAction), keyEquivalent: "")
            pasteAndGo.target = self
            menu.addItem(pasteAndGo)

            menu.addItem(NSMenuItem.separator())

            let paste = NSMenuItem(title: String(localized: "Paste"), action: #selector(pasteAction), keyEquivalent: "v")
            paste.target = self
            menu.addItem(paste)

            let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(copyAction), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)

            let cut = NSMenuItem(title: String(localized: "Cut"), action: #selector(cutAction), keyEquivalent: "x")
            cut.target = self
            menu.addItem(cut)

            let selectAll = NSMenuItem(title: String(localized: "Select All"), action: #selector(selectAllAction), keyEquivalent: "a")
            selectAll.target = self
            menu.addItem(selectAll)
        }

        @objc func submit() {
            parent.onSubmit()
        }

        @objc func pasteAndGoAction() {
            parent.onPasteAndGo()
        }

        @objc func pasteAction() {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }

        @objc func copyAction() {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }

        @objc func cutAction() {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        }

        @objc func selectAllAction() {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue
            parent.text = newValue
            parent.onTextChange(newValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onMoveSelection(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onMoveSelection(1)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

/// NSTextField that draws no focus ring and keeps its field editor transparent,
/// so it can sit inside a SwiftUI Capsule without producing a nested "blue box + black box" look.
final class URLTextField: NSTextField {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        clearEditorBackground()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        clearEditorBackground()
        return ok
    }

    private func clearEditorBackground() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.backgroundColor = .clear
        editor.drawsBackground = true
        editor.textColor = NSColor.labelColor
        editor.perform(#selector(setter: NSTextView.insertionPointColor), with: NSColor.labelColor)
    }
}
