import SwiftUI

struct FindBar: View {
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

            TextField("在页面中查找…", text: $findString)
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
                Text("未找到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("上一条", systemImage: "chevron.up") { onFindPrevious() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("下一条", systemImage: "chevron.down") { onFindNext() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("完成") { onHide() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
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
