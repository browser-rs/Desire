import SwiftUI

/// Agent 体检页（Agent 窗口侧栏"体检"目的地，2026-10-10）。
/// 报告数据**全部来自 `AgentDoctor.run()`**（与桥 `GET /agent/doctor`、
/// 设置页"Agent 体检"行同一份逻辑，禁止另算一套）——这里只是把报告
/// 渲染出来：每项检查的状态图标 + 名称 + 详情，顶部汇总徽标 + 重新体检。
struct AgentDoctorView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    var onBack: () -> Void

    @State private var report: AgentDoctor.Report?
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(report.checks) { check in
                            checkRow(check)
                        }
                    }
                    .padding(12)
                }
            } else if isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Running…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 初始态（task 尚未完成的第一帧）——占位避免空白闪烁。
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await run()
        }
    }

    private func run() async {
        isRunning = true
        report = await AgentDoctor.run()
        isRunning = false
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "stethoscope")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Doctor")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let report {
                Text("\(report.passed)/\(report.checks.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(report.ok ? .green : .orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((report.ok ? Color.green : Color.orange).opacity(0.12)))
            }
            Button {
                Task { await run() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 24)
                    .opacity(isRunning ? 0.3 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .help("Recheck")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private func checkRow(_ check: AgentDoctor.Check) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(check.ok ? Color.green : Color.red)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(check.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}
