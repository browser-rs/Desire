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
        let field = NSTextField(frame: .zero)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = "搜索或输入网址"
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
            let pasteAndGo = NSMenuItem(title: "粘贴并转到", action: #selector(pasteAndGoAction), keyEquivalent: "")
            pasteAndGo.target = self
            menu.addItem(pasteAndGo)

            menu.addItem(NSMenuItem.separator())

            let paste = NSMenuItem(title: "粘贴", action: #selector(pasteAction), keyEquivalent: "v")
            paste.target = self
            menu.addItem(paste)

            let copy = NSMenuItem(title: "复制", action: #selector(copyAction), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)

            let cut = NSMenuItem(title: "剪切", action: #selector(cutAction), keyEquivalent: "x")
            cut.target = self
            menu.addItem(cut)

            let selectAll = NSMenuItem(title: "全选", action: #selector(selectAllAction), keyEquivalent: "a")
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
