import SwiftUI

/// Inline card for the agent's mid-task questions (askUser tool): shows the
/// question with a text field for the answer.
struct AgentQuestionCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let question: String
    let onAnswer: (String) -> Void

    @State private var answer = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(appAccent)
                Text("Agent 需要你的确认")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            Text(question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // Option detection: lines like "A) xxx" / "1、xxx" become
            // one-tap answer chips.
            let options = question.components(separatedBy: "\n").filter {
                $0.range(of: "^\\s*([A-D1-4])[)\\.、:]\\s*\\S+", options: .regularExpression) != nil
            }
            if !options.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onAnswer(option.trimmingCharacters(in: .whitespaces))
                        } label: {
                            Text(option.trimmingCharacters(in: .whitespaces))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(appAccent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(appAccent.opacity(0.10))
                                )
                                .overlay(
                                    Capsule().stroke(appAccent.opacity(0.35), lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("输入你的回答…", text: $answer)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFieldFocused)
                    .onSubmit { submit() }
                Button("回答", action: submit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(appAccent))
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appAccent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(appAccent.opacity(0.3), lineWidth: 0.7)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAnswer(trimmed)
        answer = ""
    }
}
