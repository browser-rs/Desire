import AppKit
import SwiftUI

// 内置页面视图（v0.8.27）：about / 兜底索引页。
// 面板类页面（设置/下载/Agent…）不在标签里渲染——深链只负责唤起对应面板。

/// desire://about：版本与运行环境摘要。
struct AboutPageView: View {
    @Environment(\.appAccent) private var appAccent: Color
    var onOpen: (InternalDestination) -> Void

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var isAutomation: Bool {
        ProcessInfo.processInfo.arguments.contains("--automation")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Desire \(versionText)")
                            .font(.system(size: 20, weight: .semibold))
                        Text(String(localized: "A browser that does more of the work."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    row(String(localized: "macOS"), ProcessInfo.processInfo.operatingSystemVersionString, mono: false)
                    row(String(localized: "Built-in tools"), "\(ToolID.allCases.count)", mono: false)
                    row(String(localized: "Automation bridge"),
                        isAutomation ? "http://127.0.0.1:8799" : String(localized: "Not running"),
                        mono: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        WhatsNewStore.shared.show()
                    } label: {
                        Label(String(localized: "What's New"), systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/browser-rs/Desire/releases")!)
                    } label: {
                        Label(String(localized: "Release Notes"), systemImage: "safari")
                    }
                    .buttonStyle(.plain)
                    Button {
                        onOpen(InternalPages.destination(for: .fallback))
                    } label: {
                        Label(String(localized: "All internal pages"), systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 11.5))
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func row(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// desire:// 兜底索引页：列出全部内置页面，点击直达。
struct InternalPagesIndexView: View {
    @Environment(\.appAccent) private var appAccent: Color
    var onOpen: (InternalDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(appAccent)
                    Text(String(localized: "Internal Pages"))
                        .font(.system(size: 19, weight: .semibold))
                }
                Text(String(localized: "desire:// links open built-in pages. Unknown pages land here — pick one:"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(InternalPageKind.all, id: \.rawValue) { page in
                        Button {
                            onOpen(InternalPages.destination(for: page))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(appAccent)
                                    .frame(width: 18)
                                Text(page.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                Spacer()
                                Text("desire://\(page.rawValue)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
