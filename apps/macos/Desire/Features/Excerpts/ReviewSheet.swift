import SwiftUI

/// 今日回顾（v0.8.22）：逐条过到期的摘录——"记得"升档、"忘了"回到第 1 档、
/// "跳过"明天再来。内容来自 ExcerptStore，排程来自 ReviewQueueStore。
struct ReviewSheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var queue = ReviewQueueStore.shared
    @ObservedObject private var excerpts = ExcerptStore.shared
    var onClose: () -> Void

    @State private var remembered = 0
    @State private var forgotten = 0
    /// 打开时的待回顾数（用于"本次完成"的汇总；-1 = 尚未计算）。
    @State private var startDue = -1

    private var current: (entry: ReviewEntry, excerpt: Excerpt)? {
        guard let entry = queue.due.first,
              let excerpt = excerpts.excerpts.first(where: { $0.id == entry.id }) else {
            return nil
        }
        return (entry, excerpt)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let current {
                card(current.entry, current.excerpt)
            } else {
                doneState
            }
        }
        .frame(width: 520, height: 430)
        .onAppear {
            queue.sync(with: excerpts.excerpts)
            if startDue < 0 { startDue = queue.due.count }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text(String(localized: "Today's Review"))
                .font(.system(size: 13, weight: .semibold))
            Text(String(localized: "\(queue.due.count) due"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(String(localized: "Close"), action: onClose)
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func card(_ entry: ReviewEntry, _ excerpt: Excerpt) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(excerpt.kindLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Stage \(entry.stage + 1) of 5"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if entry.lapses > 0 {
                    Text(String(localized: "Forgot \(entry.lapses)x"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(excerpt.content)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                    if let note = excerpt.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(appAccent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(excerpt.title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 10) {
                Button {
                    queue.grade(id: entry.id, remembered: false)
                    forgotten += 1
                } label: {
                    Label(String(localized: "Forgot"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                Button {
                    queue.snooze(id: entry.id)
                } label: {
                    Label(String(localized: "Skip"), systemImage: "clock")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    queue.grade(id: entry.id, remembered: true)
                    remembered += 1
                } label: {
                    Label(String(localized: "Remembered"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var doneState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26))
                .foregroundStyle(appAccent)
            Text(startDue <= 0
                 ? String(localized: "Nothing due — you are all caught up.")
                 : String(localized: "Done for now."))
                .font(.system(size: 13, weight: .medium))
            if remembered + forgotten > 0 {
                Text(String(localized: "Reviewed \(remembered + forgotten) · remembered \(remembered) · forgot \(forgotten)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
