import SwiftUI

/// Inline card for the agent's mid-task questions (askUser tool): shows the
/// question with a text field for the answer.
struct AgentQuestionCard: View {
    let question: String
    let onAnswer: (String) -> Void

    @State private var answer = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text("Agent 需要你的确认")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            Text(question)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
                    .background(Capsule().fill(Color.accentColor))
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.7)
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
