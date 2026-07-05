import SwiftUI

struct AIPanel: View {
    @ObservedObject var store: AISessionStore
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI Assistant")
                    .font(.headline)
                Spacer()
                if store.isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button("Clear") { store.clear() }
                    .buttonStyle(.plain)
                    .disabled(store.messages.isEmpty)
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.messages) { msg in
                            messageRow(msg)
                                .id(msg.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: store.messages.count) { _ in
                    if let last = store.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 4) {
                TextField("Ask AI...", text: $inputText)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                Button("Send", action: submit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isProcessing)
            }
            .padding(8)
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer()
                Text(msg.content ?? "")
                    .padding(8)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(6)
            }
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let text = msg.content, !text.isEmpty {
                        Text(text)
                    }
                    if let tcs = msg.toolCalls {
                        ForEach(tcs, id: \.id) { tc in
                            HStack(spacing: 4) {
                                Image(systemName: "wrench")
                                Text(tc.function.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                Spacer()
            }
        case .tool:
            HStack {
                Text(msg.content?.prefix(200) ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        case .system:
            EmptyView()
        }
    }

    private func submit() {
        let text = inputText
        inputText = ""
        store.sendMessage(text)
    }
}
