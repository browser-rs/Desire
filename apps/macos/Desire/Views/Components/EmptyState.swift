import SwiftUI

struct EmptyState: View {
    let title: String
    let systemImage: String?
    let description: String?

    init(message: String) {
        self.title = message
        self.systemImage = nil
        self.description = nil
    }

    init(title: String, systemImage: String = "tray", description: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyState(message: "暂无数据")
}
