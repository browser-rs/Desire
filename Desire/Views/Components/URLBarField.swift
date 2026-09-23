import AppKit
import SwiftUI
import os

struct URLBarField: NSViewRepresentable {
    /// Posted (object: nil) to make the focused URL field select its whole
    /// text. The old ⌘L path called `selectText:` on whatever NSTextField
    /// happened to be first responder — including unrelated text fields.
    static let selectAllNotification = Notification.Name("URLBarField.selectAll")

    @Binding var text: String
    /// 由 NSTextField 的**真实编辑事件**维护（见 Coordinator 的
    /// controlTextDidBegin/EndEditing）。此前这里是 `FocusState<Bool>.Binding`，
    /// 但地址栏是 NSViewRepresentable、自己调 `becomeFirstResponder()`——
    /// SwiftUI 的 FocusState 不认这种焦点，于是它**永远是 false**：
    /// 候补下拉不显示、聚焦高亮不亮、聚焦时播种 URL/失焦重置也都失效。
    @Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onPasteAndGo: () -> Void
    /// Consumes a suggestion-list arrow move. Return `true` when handled
    /// (the field then leaves the caret alone); `false` lets up/down move
    /// the caret as usual — e.g. when the suggestion list is empty.
    var onMoveSelection: (Int) -> Bool
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
        context.coordinator.textField = field
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: Self.selectAllNotification, object: nil, queue: .main
        ) { [weak field] _ in
            field?.selectText(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // The field editor is always an NSTextView; typed as such because
        // `hasMarkedText()` (IME state) lives on NSTextInputClient, not NSText.
        let editor = nsView.currentEditor() as? NSTextView
        // Never rewrite the text while an IME composition is in flight —
        // that would destroy the marked pinyin range mid-typing.
        let composing = editor?.hasMarkedText() ?? false
        if !composing, nsView.stringValue != text {
            context.coordinator.isSyncingFromSwiftUI = true
            nsView.stringValue = text
            context.coordinator.isSyncingFromSwiftUI = false
        }
        // Focus only on the false→true transition. Calling becomeFirstResponder
        // on every render (the old behavior) fought the field editor while typing.
        if isFocused, !context.coordinator.wasFocused {
            nsView.becomeFirstResponder()
        }
        context.coordinator.wasFocused = isFocused
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLBarField
        let menu: NSMenu
        weak var textField: NSTextField?
        /// Last SwiftUI-side focus state, to detect transitions.
        var wasFocused = false
        /// 我们在 `updateNSView` 里同步 `stringValue` 时，AppKit 会**同步**回调
        /// `controlTextDidChange`——那是在 SwiftUI 的更新事务内部，写 @State / 发布
        /// @Published 会报 "Modifying state during view update" /
        /// "Publishing changes from within view updates"（实测一次聚焦三条）。
        /// 用这个标志把"自己引发的变化"挡掉：它不需要重建候选。
        var isSyncingFromSwiftUI = false
        var observer: NSObjectProtocol?

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

        func controlTextDidBeginEditing(_ obj: Notification) {
            // 这个通知是 `updateNSView` 里 `becomeFirstResponder()` **同步**发出来的，
            // 所以在 SwiftUI 更新事务里 → 跳一帧再改状态。
            Task { @MainActor in if !parent.isFocused { parent.isFocused = true } }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            Task { @MainActor in if parent.isFocused { parent.isFocused = false } }
        }

        @objc func submit() {
            // Sync the field's current value to the binding before
            // navigating — IME / autocorrect can commit the final text
            // between the last controlTextDidChange and the submit action.
            if let field = textField, field.stringValue != parent.text {
                parent.text = field.stringValue
            }
            parent.onSubmit()
        }

        @objc func pasteAndGoAction() {
            parent.onPasteAndGo()
        }

        @objc func pasteAction() {
            guard let field = textField, let editor = field.currentEditor() else { return }
            editor.paste(nil)
        }

        @objc func copyAction() {
            guard let field = textField, let editor = field.currentEditor() else { return }
            editor.copy(nil)
        }

        @objc func cutAction() {
            guard let field = textField, let editor = field.currentEditor() else { return }
            editor.cut(nil)
        }

        @objc func selectAllAction() {
            guard let field = textField, let editor = field.currentEditor() else { return }
            editor.selectAll(nil)
        }

        func controlTextDidChange(_ obj: Notification) {
            // 自己同步 stringValue 引发的变化：忽略（见 isSyncingFromSwiftUI）
            guard !isSyncingFromSwiftUI else { return }
            guard let field = obj.object as? NSTextField else { return }
            let newValue = field.stringValue
            parent.text = newValue
            // Skip suggestion rebuilds while an IME composition is active:
            // marked pinyin fragments would churn the dropdown on every
            // keystroke. The committed text fires its own change event.
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.onTextChange(newValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return parent.onMoveSelection(-1)
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return parent.onMoveSelection(1)
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
