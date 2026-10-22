import SwiftUI

/// Web Apps 管理器（v0.8.0）：打开/卸载已安装的站点窗口。
struct WebAppsPanel: View {
    @ObservedObject private var store = WebAppStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Apps")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sites installed as standalone windows.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if store.apps.isEmpty {
                Text("No web apps yet. Open a site, then use ⋯ → Install as Web App…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.apps) { app in
                            row(app)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 540, height: 420)
    }

    private func row(_ app: WebApp) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                Text(app.host + (app.shareSession ? " · shared sign-in" : " · isolated")
                     + lastVisitSuffix(app))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu(String(localized: "Open")) {
                Button(String(localized: "Resume Last Page")) {
                    openWindow(id: "webapp", value: app.id)
                    dismiss()
                }
                .disabled(app.lastURL == nil)
                Button(String(localized: "Start Page")) {
                    store.clearLastVisit(id: app.id)
                    openWindow(id: "webapp", value: app.id)
                    dismiss()
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 11))
            Button("Delete", role: .destructive) {
                store.remove(app)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private func lastVisitSuffix(_ app: WebApp) -> String {
        guard let last = app.lastVisitedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return " · \(formatter.localizedString(for: last, relativeTo: Date()))"
    }
}
