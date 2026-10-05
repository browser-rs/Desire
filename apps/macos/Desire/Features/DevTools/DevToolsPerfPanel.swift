import AppKit
import SwiftUI

/// DevTools「Performance」页签（0.6.4，轻量只读）：
/// 当前标签的 DOM 节点数 / long task 计数与耗时 / 挂起状态——数据来自
/// page-perf.js（每 5s 上报）与 Tab 挂起标志。不做 flame graph（Web
/// Inspector 自带的重活不重复，见路线图 0.6.4）。
struct PerformancePanel: View {
    /// Optional 拆开观察：Tab 自身是 ObservableObject，Optional 不满足。
    @ObservedObject var tab: Tab
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Group {
            content(tab)
        }
    }

    private func content(_ tab: Tab) -> some View {
        List {
            Section("当前指标") {
                metricRow("DOM 节点数", "\(tab.browser.lastDomNodeCount)",
                          detail: tab.browser.lastDomNodeCount > 25_000 ? "超过大页面阈值（后台标签会被挂起）" : nil,
                          warn: tab.browser.lastDomNodeCount > 25_000)
                metricRow("Long tasks（>50ms）", "\(tab.browser.lastLongTaskCount)",
                          detail: "累计 \(tab.browser.lastLongTaskMs)ms",
                          warn: tab.browser.lastLongTaskCount > 50)
                metricRow("状态", tab.isSuspended ? "已挂起（切回即恢复）" : "活跃",
                          detail: tab.isSuspended ? "挂起保快照，点击标签秒回" : nil,
                          warn: false)
            }
            Section {
                Text("指标由 page-perf.js 每 5 秒上报（代理指标：WebKit 不提供 per-tab 内存）。刷新页面会清零 long task 计数。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func metricRow(_ title: String, _ value: String, detail: String?, warn: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(warn ? Color.orange : .primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
