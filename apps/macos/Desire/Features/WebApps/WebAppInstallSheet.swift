import AppKit
import SwiftUI

/// 安装当前站点为 Web App（v0.8.0）：名称可编辑、登录会话可共享。
struct WebAppInstallSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var name: String
    @State private var shareSession = false

    init(url: URL, suggestedName: String) {
        self.url = url
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install as Web App")
                .font(.system(size: 16, weight: .semibold))
            Text(url.absoluteString)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Toggle("Share sign-in with the main browser", isOn: $shareSession)
            Text(shareSession
                 ? "Uses the main browser's cookies — you stay signed in."
                 : "Uses an isolated data store — sign in once inside the app.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Install") { install() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func install() {
        guard let app = WebAppStore.shared.add(
            url: url, name: name, shareSession: shareSession) else { return }
        dismiss()
        openWindow(id: "webapp", value: app.id)
    }
}
