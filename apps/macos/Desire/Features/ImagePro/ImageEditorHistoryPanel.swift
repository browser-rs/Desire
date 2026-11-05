import SwiftUI

/// 历史面板（v0.8.46 重写）：Original + 已执行动作；点击回退到该步。
struct ImageEditorHistoryPanel: View {
    @ObservedObject private var session: ImageEditorSession
    @ObservedObject private var document: ImageEditorDocument
    @Environment(\.appAccent) private var appAccent

    init(session: ImageEditorSession) {
        _session = ObservedObject(wrappedValue: session)
        _document = ObservedObject(wrappedValue: session.document)
    }

    private var entries: [String] {
        [String(localized: "Original State")] + document.historyTitles
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entries.enumerated().reversed()), id: \.offset) { index, title in
                        let isCurrent = index == entries.count - 1
                        Button {
                            document.undo(toDepth: index)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isCurrent ? "arrowtriangle.right.fill"
                                                            : "circle.fill")
                                    .font(.system(size: isCurrent ? 7 : 4))
                                    .foregroundStyle(isCurrent ? AnyShapeStyle(appAccent)
                                                               : AnyShapeStyle(.tertiary))
                                    .frame(width: 10)
                                Text(title)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(appAccent)
                                                   : AnyShapeStyle(.primary))
                        .disabled(index > entries.count - 1)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            HStack(spacing: 10) {
                Text(verbatim: "\(document.historyTitles.count) step\(document.historyTitles.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if document.redoCount > 0 {
                    Text(verbatim: "\(document.redoCount) redo")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
