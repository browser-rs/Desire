import SwiftUI

struct AIPanel: View {
    @ObservedObject var store: AISessionStore
    @State private var inputText = ""
    @State private var showActions = true
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if store.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            if !store.messages.isEmpty {
                Divider()
            }

            if store.awaitingQuestion {
                awaitingQuestionBar
            } else if showActions && !store.isProcessing {
                quickActions
            }

            inputBar
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("AI Assistant")
                .font(.headline)
            Spacer()
            Text(store.preference.model)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80)
            if store.isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    if let action = store.currentAction {
                        Text(action)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !store.messages.isEmpty {
                Button { store.clear() } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("AI Assistant")
                .font(.title3).fontWeight(.semibold)

            Text("Ask questions, summarize pages,\ntranslate content, and more.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            VStack(spacing: 6) {
                ForEach(AIQuickAction.allCases, id: \.title) { action in
                    Button {
                        store.performQuickAction(action)
                        showActions = false
                    } label: {
                        Label(action.title, systemImage: action.icon)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .separatorColor).opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.messages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                    }
                    if let last = store.messages.last,
                       last.role == .assistant,
                       let tcs = last.toolCalls, !tcs.isEmpty,
                       store.isProcessing {
                        toolExecutionProgress
                            .id("tool-progress")
                    }
                }
                .padding(10)
            }
            .onChange(of: store.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.streamingVersion) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var toolExecutionProgress: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.5)
            if let action = store.currentAction {
                Text("Running \(action)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Executing tools…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .separatorColor).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            ForEach(AIQuickAction.allCases, id: \.title) { action in
                Button {
                    store.performQuickAction(action)
                    showActions = false
                } label: {
                    Label(action.title, systemImage: action.icon)
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .separatorColor).opacity(0.15))
                .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var awaitingQuestionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("What would you like to know about this page?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Cancel") {
                store.awaitingQuestion = false
                store.cancel()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextEditor(text: $inputText)
                .font(.system(size: 12))
                .frame(minHeight: 28, maxHeight: 80)
                .focused($isInputFocused)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .overlay(alignment: .leading) {
                    if inputText.isEmpty {
                        Text("Ask AI...")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSubmit ? Color.accentColor : Color(nsColor: .separatorColor))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var canSubmit: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isProcessing
    }

    @ViewBuilder
    private func messageRow(_ msg: AIMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(msg.content ?? "")
                        .font(.system(size: 13))
                        .padding(10)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    copyButton(msg.content ?? "")
                }
            }
        case .assistant:
            let isError = msg.content?.hasPrefix("Error:") == true
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if isError {
                        errorContent(msg.content ?? "")
                    } else if let text = msg.content, !text.isEmpty {
                        MarkdownRendererView(text: text)
                    }
                    if let tcs = msg.toolCalls {
                        toolCallList(tcs)
                    }
                    if !isError && (msg.content?.isEmpty ?? true) && (msg.toolCalls?.isEmpty ?? true) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(maxWidth: .infinity, minHeight: 20)
                    }
                }
                .padding(10)
                .background(Color(nsColor: isError ? .systemRed : .controlBackgroundColor).opacity(isError ? 0.06 : 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    isError
                        ? RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 0.5)
                        : nil
                )
                Spacer(minLength: 40)
            }
            .overlay(alignment: .bottomTrailing) {
                if let text = msg.content, !text.isEmpty, !isError {
                    copyButton(text)
                        .offset(x: -4, y: 2)
                }
            }
        case .tool:
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.adjustable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(msg.content?.prefix(120) ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .separatorColor).opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Spacer()
            }
        case .system:
            EmptyView()
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Copy message")
    }

    @ViewBuilder
    private func errorContent(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func toolCallList(_ tcs: [AIToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(tcs) { tc in
                HStack(spacing: 4) {
                    Image(systemName: "wrench")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(tc.function.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = store.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func submit() {
        let text = inputText
        inputText = ""
        showActions = false
        if store.awaitingQuestion {
            store.sendFollowUp(text)
        } else {
            store.sendMessage(text)
        }
    }
}
