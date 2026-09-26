import SwiftUI

/// 工具审批条：Agent 挂起等你放行时显示（对应桌面 ToolApprovalBar）。
/// 三档风险配色一致：只读绿 / 改变状态橙 / 执行代码红；
/// dangerous 档不提供「始终允许」（桌面同规则：每次都必须确认）。
struct RemoteApprovalBar: View {
    let approval: RemoteApproval
    let onDecision: (RemoteApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: riskIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(riskColor)
                Text("工具审批")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(approval.riskDisplay)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(riskColor.opacity(0.15)))
                    .foregroundStyle(riskColor)
            }
            Text(approval.tool)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { onDecision(.allowOnce) } label: {
                    Text("允许一次")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(riskColor)

                Button { onDecision(.alwaysAllow) } label: {
                    Text("始终允许")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(approval.dangerous)

                Button { onDecision(.deny) } label: {
                    Text("拒绝")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .controlSize(.small)
            if approval.dangerous {
                Text("执行代码类操作每次都需要单独确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(riskColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(riskColor.opacity(0.3), lineWidth: 0.8)
        )
    }

    private var riskIcon: String {
        switch approval.risk {
        case "readonly":   "checkmark.circle.fill"
        case "dangerous":  "exclamationmark.shield.fill"
        default:           "exclamationmark.triangle.fill"
        }
    }

    private var riskColor: Color {
        switch approval.risk {
        case "readonly":   .green
        case "dangerous":  .red
        default:           .orange
        }
    }
}

/// Agent 反问卡：Agent 用 askUser 挂起等你回答。
/// 选项行（"A) xxx" / "1、xxx"）化作一键作答；自由文本在下方输入条输入
/// （输入条此时切到「作答模式」，避免同屏两个输入框）。
struct RemoteQuestionCard: View {
    let question: RemoteQuestion
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RootView.brand)
                Text("Agent 需要你的回答")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(question.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            let options = Self.options(in: question.text)
            if !options.isEmpty {
                VStack(spacing: 5) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onAnswer(option)
                        } label: {
                            Text(option)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RootView.brand)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(RootView.brand.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(RootView.brand.opacity(0.3), lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("点选上面的选项，或在下方输入你的回答")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RootView.brand.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(RootView.brand.opacity(0.3), lineWidth: 0.8)
        )
    }

    /// 识别 "A) xxx" / "1、xxx" / "B: xxx" 形式的选项行。
    private static func options(in text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter {
                $0.range(of: "^\\s*([A-D1-4])[)\\.、:]\\s*\\S+", options: .regularExpression) != nil
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
