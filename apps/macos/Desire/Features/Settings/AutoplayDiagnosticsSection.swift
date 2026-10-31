import SwiftUI

/// 自动播放诊断（v0.8.32 专项）：全局档/参与度 Top/站点覆写/暂停 oracle
/// 事件一条线。与统一日志（Log.autoplay）同源互证。
struct AutoplayDiagnosticsSection: View {
    @ObservedObject private var engagement = MediaEngagementStore.shared
    @ObservedObject private var oracle = AutoplayDiagnosticsStore.shared
    private var appState: AppState? { AppState.live }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                globalCard
                engagementCard
                oracleCard
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var globalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Autoplay")
                .font(.system(size: 13, weight: .semibold))
            Text("Global: \(appState?.settings.autoPlayPolicy.rawValue ?? "-") · pre-seeded hosts get unmuted autoplay; per-site overrides win.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var engagementCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Media Engagement (top hosts)")
                .font(.system(size: 13, weight: .semibold))
            if engagement.hosts.isEmpty {
                Text("No media playback recorded yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let top = engagement.hosts.sorted { $0.value.playSeconds > $1.value.playSeconds }.prefix(10)
                ForEach(Array(top), id: \.key) { host, record in
                    HStack {
                        Text(host).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(MediaEngagementCore.score(for: record) >= 0.5 ? "★" : "")
                            .foregroundStyle(appAccentTint)
                        Text(String(format: "%.0fs · %d×", record.playSeconds, record.playCount))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var oracleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pause Oracle (recent)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { oracle.clear() }
                    .controlSize(.mini)
            }
            if oracle.entries.isEmpty {
                Text("No pauses recorded — playback behaved.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(oracle.entries.prefix(20)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text("\(entry.timeText) [\(entry.kind)] \(entry.actor)")
                                .font(.system(size: 10.5, weight: .medium))
                            Spacer()
                        }
                        Text(entry.detail).font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var appAccentTint: Color { Color(nsColor: .controlAccentColor) }
}
