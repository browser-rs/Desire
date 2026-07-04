import SwiftUI

@ViewBuilder
func emptyState(_ message: String) -> some View {
    VStack {
        Spacer()
        Text(message).foregroundStyle(.secondary)
        Spacer()
    }
    .frame(maxWidth: .infinity)
}

#Preview {
    emptyState("暂无数据")
}
