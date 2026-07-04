import SwiftUI

struct EmptyState: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    EmptyState(message: "暂无数据")
}
