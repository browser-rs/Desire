import SwiftUI

struct FindBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var findString: String
    let findMatchCount: Int
    let findCurrentIndex: Int
    var isFindFocused: FocusState<Bool>.Binding
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    let onHide: () -> Void
    let onFindAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in page…", text: $findString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused(isFindFocused)
                .onChange(of: findString) { _, _ in
                    onFindAll()
                }
                .onSubmit { onFindNext() }

            if findMatchCount > 0 && !findString.isEmpty {
                Text("\(findCurrentIndex + 1) / \(findMatchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !findString.isEmpty {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Previous", systemImage: "chevron.up") { onFindPrevious() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("Next", systemImage: "chevron.down") { onFindNext() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("Done") { onHide() }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFindFocused.wrappedValue = true }
    }
}

#Preview {
    FindBar(
        findString: .constant(""),
        findMatchCount: 0,
        findCurrentIndex: 0,
        isFindFocused: FocusState<Bool>().projectedValue,
        onFindNext: {}, onFindPrevious: {}, onHide: {}, onFindAll: {}
    )
}
