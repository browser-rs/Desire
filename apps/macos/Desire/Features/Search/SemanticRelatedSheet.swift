import SwiftUI

/// "查找相关"的请求载体（Identifiable 供 `.sheet(item:)`）。
struct SemanticRelatedRequest: Identifiable {
    let id = UUID()
    /// 头部显示的名字（摘录标题 / 书签名 / 高亮引文开头）。
    var title: String
    /// 用于检索的原文（内容 + 备注 / 标题 + 标签）。
    var query: String
    /// 排除自己那条（避免"相关"里出现当前条目）。
    var excludingID: String?
}

/// 相关条目小窗（v0.8.22 批二）：从摘录/书签/高亮行打开，列出跨源语义近邻。
///
/// 为什么不直接打开集中搜索：同一窗口同一时刻只能呈现一个 sheet，而这些入口
/// 本身就在 sheet 里——再开集中搜索会被系统丢弃。这里用独立小窗给出同样
/// 的"跨源近邻"，点一条直接在应用内打开来源。
struct SemanticRelatedSheet: View {
    let request: SemanticRelatedRequest
    @Environment(\.dismiss) private var dismiss
    @State private var hits: [SemanticIndexStore.Hit] = []
    @State private var loading = true
    @State private var indexOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Related Saved Items"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(request.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(width: 460, height: 360)
        .task {
            let store = SemanticIndexStore.shared
            indexOff = !store.isEnabled
            guard store.isEnabled else {
                loading = false
                return
            }
            let raw = await store.searchAsync(query: request.query, limit: 16)
            hits = raw.filter { hit in
                hit.id != request.excludingID
                    && hit.source != .conversation
                    && Self.isOpenable(hit.subtitle)
            }
            loading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if indexOff {
            emptyState(icon: "sparkles",
                       text: String(localized: "Semantic search is off. Turn it on in Settings › Search & Index."))
        } else if hits.isEmpty {
            emptyState(icon: "magnifyingglass",
                       text: String(localized: "Nothing related found yet."))
        } else {
            List(hits, id: \.id) { hit in
                Button {
                    open(hit)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: hit.source))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.title.isEmpty ? hit.subtitle : hit.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(hit.snippet)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(String(format: "%.2f", Double(hit.score)))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static func isOpenable(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("file://")
    }

    private func open(_ hit: SemanticIndexStore.Hit) {
        TabSessionCoordinator.shared.activeTabManager?
            .addTab(url: hit.subtitle, makeActive: true)
        dismiss()
    }

    private func icon(for source: SemanticSource) -> String {
        switch source {
        case .history: return "clock"
        case .bookmark: return "bookmark"
        case .excerpt: return "text.quote"
        case .highlight: return "highlighter"
        case .conversation: return "bubble.left.and.bubble.right"
        }
    }
}
