import SwiftUI

/// 输入栏的上下文占用 chip：摆在模型选择器左侧（思考等级在右侧）。
/// 数据与头部状态行**同源**（`AgentSessionStore.contextFraction`，口径 =
/// compactForContext 的字符数 / 预算），不另算一套。60% 橙、85% 红。
struct AgentContextChip: View {
    @ObservedObject var store: AgentSessionStore
    /// 点击弹出 /context 内容（v0.8.75 批 1）：占用构成、压缩状态、分层账
    /// 一眼可见——不再需要打字才能查。popover 而非 sheet：轻、Esc/点外即关。
    @State private var showOverview = false

    var body: some View {
        // **常显**：0% 也是有效信息（用户明确要求三件套常在——曾按"≥2% 才显示"
        // 做，新对话直接看不见这个 chip，用户截图追问"上下文容量也没有啊"）。
        HStack(spacing: 3) {
            Image(systemName: store.contextFraction >= 0.6 ? "exclamationmark.triangle.fill" : "gauge.medium")
                .font(.system(size: 9))
            Text(verbatim: "\(Int((store.contextFraction * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .help(helpText)
        .onTapGesture { showOverview = true }
        .popover(isPresented: $showOverview, arrowEdge: .bottom) {
            AgentContextOverviewPanel(text: store.contextOverviewText())
        }
    }

    private var color: Color {
        if store.contextFraction >= 0.85 { return .red }
        if store.contextFraction >= 0.6 { return .orange }
        return .secondary
    }

    private var helpText: String {
        var text = String(localized: "Context") + String(format: " %d%%", Int((store.contextFraction * 100).rounded()))
        if store.lastPromptTokens > 0 {
            text += String(format: " · ≈%.1fk tokens", Double(store.lastPromptTokens) / 1000)
        }
        if store.contextFraction >= 0.6 {
            text += " · " + String(localized: "Context is getting long — /new starts a fresh conversation")
        }
        return text
    }
}

/// /context 内容的 popover 面板（v0.8.75 批 1）：独立子视图——主 body 复杂度
/// 会让编译器 type-check 超时（既有坑）。
private struct AgentContextOverviewPanel: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context overview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 430)
    }
}
