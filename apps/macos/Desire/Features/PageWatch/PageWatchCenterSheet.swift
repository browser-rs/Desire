import AppKit
import SwiftUI

/// 监视中心（v0.8.0）：所有 PageWatch 的状态 + 最近变化 + 一键检查/复制摘要。
struct PageWatchCenterSheet: View {
    @ObservedObject private var store = PageWatchStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var digest = PageWatchDigest.Summary(text: "", changed: 0, errors: 0, alerts: 0)
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page Watch Center")
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(store.watches.count) watched · \(digest.changed) changed · \(digest.alerts) alert(s) · \(digest.errors) error(s) in 24h")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if store.watches.isEmpty {
                Text("No page watches yet. Add one in Settings ▸ Page Watch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.watches) { watch in
                            row(watch)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(digest.text, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Digest",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await checkAll() }
                } label: {
                    if store.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check All")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isChecking || store.watches.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 540)
        .task { refreshDigest() }
        .onChange(of: store.watches) { _, _ in refreshDigest() }
    }

    private func row(_ watch: PageWatch) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateIcon(watch))
                .font(.system(size: 13))
                .foregroundStyle(stateColor(watch))
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.name)
                    .font(.system(size: 12.5, weight: .medium))
                Text(watch.url)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = watch.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let alert = watch.lastAlert, !alert.isEmpty {
                    Text(alert)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let analysis = watch.lastAnalysis, !analysis.isEmpty {
                    Text(analysis)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let value = watch.latestValue {
                    Text(format(value))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                if let changed = watch.lastChangedAt {
                    Text(changed, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let checked = watch.lastCheckedAt {
                    Text("checked")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(checked, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func stateIcon(_ watch: PageWatch) -> String {
        if (watch.lastError ?? "").isEmpty == false { return "exclamationmark.triangle.fill" }
        if (watch.lastAlertAt ?? .distantPast) > Date().addingTimeInterval(-86_400) {
            return "bell.badge.fill"
        }
        if (watch.lastChangedAt ?? .distantPast) > Date().addingTimeInterval(-86_400) {
            return "arrow.triangle.2.circlepath"
        }
        return "eye"
    }

    private func stateColor(_ watch: PageWatch) -> Color {
        if (watch.lastError ?? "").isEmpty == false { return .orange }
        return .secondary
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func refreshDigest() {
        digest = PageWatchDigest.make(watches: store.watches)
    }

    private func checkAll() async {
        for watch in store.watches {
            _ = await store.check(named: watch.name)
        }
        refreshDigest()
    }
}
