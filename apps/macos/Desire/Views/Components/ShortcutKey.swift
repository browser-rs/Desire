import AppKit
import SwiftUI

/// A single keyboard key chip. Used in the shortcuts editor to render
/// bindings like ⌘ ⇧ T as a row of distinguishable keys.
struct ShortcutKey: View {
    let label: String
    var isModifier: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(isModifier ? Color.secondary : Color.primary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            )
    }
}

/// Renders a full shortcut like ⌘ ⇧ T as a row of `ShortcutKey` chips.
struct ShortcutKeySequence: View {
    let display: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                ShortcutKey(label: part, isModifier: isModifier(part))
            }
        }
    }

    private var parts: [String] {
        // Split into single grapheme clusters (so ⌘ ⇧ ⌥ ⌃ each count as one).
        display.map { String($0) }
    }

    private func isModifier(_ s: String) -> Bool {
        ["⌘", "⇧", "⌥", "⌃"].contains(s)
    }
}
