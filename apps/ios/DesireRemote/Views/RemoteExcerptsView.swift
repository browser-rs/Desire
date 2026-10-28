import SwiftUI

/// 摘录（v0.8.18）：Mac 摘录库的手机视图——阅读高亮/PDF 批注/划选的
/// 统一沉淀，一键在 Mac 上打开来源。
struct RemoteExcerptsView: View {
    @EnvironmentObject var client: RemoteClient

    private func kindLabel(_ kind: String) -> String {
        switch kind {
        case "readerHighlight": return "阅读"
        case "pdfAnnotation": return "PDF"
        default: return "网页"
        }
    }

    private func kindIcon(_ kind: String) -> String {
        switch kind {
        case "readerHighlight": return "book"
        case "pdfAnnotation": return "doc.richtext"
        default: return "safari"
        }
    }

    var body: some View {
        List {
            if client.excerpts.isEmpty {
                Text("Mac 摘录库还是空的——在 Mac 上划词点「摘录」、保存阅读高亮或 PDF 批注即可沉淀到这里")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.excerpts) { excerpt in
                VStack(alignment: .leading, spacing: 5) {
                    Text(excerpt.content)
                        .font(.subheadline)
                        .lineLimit(4)
                    HStack(spacing: 6) {
                        Image(systemName: kindIcon(excerpt.kind))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(kindLabel(excerpt.kind))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(excerpt.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    client.openExcerpt(excerpt.source)
                }
            }
        }
        .navigationTitle("摘录")
        .onAppear { client.requestExcerpts() }
        .refreshable { client.requestExcerpts() }
    }
}
