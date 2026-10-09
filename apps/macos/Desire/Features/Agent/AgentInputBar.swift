import SwiftUI

/// Bottom input area for the AI panel. A single rounded capsule that
/// auto-grows with content, with an inline send button and a context
/// strip above (question prompt / quick action shortcut).
struct AgentInputBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var text: String
    let isProcessing: Bool
    let awaitingQuestion: Bool
    let canSubmit: Bool
    /// User-attached image data URIs awaiting send (vision input).
    var attachments: [String] = []
    var onAddAttachment: () -> Void = {}
    var onRemoveAttachment: (Int) -> Void = { _ in }
    var onSubmit: () -> Void
    /// Stops a running agent turn. While processing, the send button turns
    /// into a stop button and routes here.
    var onCancel: () -> Void = {}
    var onCancelQuestion: () -> Void
    @FocusState.Binding var isFocused: Bool
    /// 输入历史翻阅（↑/↓）。返回要填入的文本；nil = 没有可翻的。
    /// **只在输入框为空或正在翻阅时接管方向键**，否则让 TextEditor 自己移动光标。
    var onHistoryUp: (() -> String?)?
    var onHistoryDown: (() -> String?)?
    /// 正在翻阅历史（由调用方维护）：为空时按 ↓ 应该回到空白草稿。
    var isBrowsingHistory: Bool = false
    /// Voice input manager — nil hides the mic button.
    var voiceManager: VoiceInputManager? = nil
    /// Model/provider switcher capsule — right group, next to send.
    var modelMenu: AnyView = AnyView(EmptyView())
    /// 思考等级下拉（🧠 等级 ⌄）— 模型选择器**右侧**（用户参照主流客户端布局）。
    var thinkingMenu: AnyView = AnyView(EmptyView())
    /// 上下文占用 chip（gauge %）— 模型选择器**左侧**；同源 store.contextFraction。
    var contextChip: AnyView = AnyView(EmptyView())
    /// Inline FULL ACCESS toggle pill — left utility group.
    var fullAccessPill: AnyView = AnyView(EmptyView())
    /// 会话级临时指令按钮（sparkles）：nil 隐藏；点击弹编辑（面板侧管理）。
    /// 指令活跃时由面板在输入框上方显示指令条，这里只是入口。
    var onSessionDirective: (() -> Void)? = nil
    /// 指令活跃态（按钮高亮提示）。
    var isSessionDirectiveActive: Bool = false

    @State private var isHoveringSend = false
    /// slash 候选菜单：输入以 "/" 开头且尚无参数空格时弹出（过滤命令）。
    @State private var slashHighlight = 0
    @State private var slashDismissed = false

    // MARK: - Slash 候选菜单

    private var slashPrefix: String? {
        guard text.hasPrefix("/"), !text.contains(" "), !slashDismissed else { return nil }
        return String(text.dropFirst()).lowercased()
    }
    private var slashSuggestions: [(command: String, description: String)] {
        guard let prefix = slashPrefix else { return [] }
        return AgentSlashParsing.suggestions(prefix: prefix)
    }
    private var slashMenuVisible: Bool { !slashSuggestions.isEmpty }
    private var slashEffectiveIndex: Int {
        guard !slashSuggestions.isEmpty else { return 0 }
        return min(max(slashHighlight, 0), slashSuggestions.count - 1)
    }

    /// Enter：已敲完整命令 → 直接执行；否则补全高亮候选（保留已输入的参数）。
    private func completeSlash(at index: Int? = nil) {
        let idx = index ?? slashEffectiveIndex
        guard slashSuggestions.indices.contains(idx) else { return }
        let selected = slashSuggestions[idx].command
        text = "/" + selected + " "
        slashHighlight = 0
        slashDismissed = false
    }

    var body: some View {
        VStack(spacing: 6) {
            if awaitingQuestion {
                contextStrip
            }
            if !attachments.isEmpty {
                attachmentStrip
            }
            inputCapsule
            voiceStatusLine
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(inputBackground)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    // MARK: - Context strip

    private var contextStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble.fill")
                .font(.system(size: 11))
                .foregroundStyle(appAccent)
            Text("Asking about this page")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: onCancelQuestion)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(appAccent.opacity(0.10))
        )
        .overlay(
            Capsule().stroke(appAccent.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Attachments

    /// Thumbnails of pending image attachments with remove buttons.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // 快照枚举：删除附件会让数组变短，`attachments.indices` 当 id 时
                // SwiftUI 可能拿旧下标去取新数组（Index out of range）。
                ForEach(Array(attachments.enumerated()), id: \.offset) { idx, uri in
                    attachmentThumb(uri: uri, index: idx)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func attachmentThumb(uri: String, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let data = imageData(uri), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            }
            Button {
                onRemoveAttachment(index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove")
        }
        .padding(.trailing, 5)
    }

    private func imageData(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:image/"),
              let comma = uri.firstIndex(of: ","),
              let base64 = uri[uri.index(after: comma)...].removingPercentEncoding else { return nil }
        return Data(base64Encoded: String(base64))
    }

    // MARK: - Input capsule

    private var inputCapsule: some View {
        VStack(spacing: 0) {
            if slashMenuVisible {
                slashMenu
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        // 与 TextEditor 的 padding + 它的原生文本内缩对齐，
                        // 光标不会压在占位文字上（编辑器上边距改大后这里跟着调）。
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    // 上边距比下边大：单行时文字不要贴着边框（用户实测反馈）。
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .frame(minHeight: 32, maxHeight: 120)
                    .onKeyPress(.upArrow) {
                        // slash 菜单可见时 ↑ 移动高亮（优先于历史翻阅）。
                        if slashMenuVisible {
                            slashHighlight = max(0, slashEffectiveIndex - 1)
                            return .handled
                        }
                        // 空输入框（或已在翻阅）时把 ↑ 交给历史；否则保留光标移动。
                        guard text.isEmpty || isBrowsingHistory else { return .ignored }
                        guard let recalled = onHistoryUp?() else { return .ignored }
                        text = recalled
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        if slashMenuVisible {
                            slashHighlight = min(slashSuggestions.count - 1, slashEffectiveIndex + 1)
                            return .handled
                        }
                        guard isBrowsingHistory else { return .ignored }
                        text = onHistoryDown?() ?? ""
                        return .handled
                    }
                    .onKeyPress(keys: [.return]) { press in
                        // Mainstream chat semantics: Enter sends,
                        // Shift+Enter inserts a newline, ⌘+Return is
                        // handled upstream.
                        if press.modifiers.contains(.shift)
                            || press.modifiers.contains(.command) {
                            return .ignored
                        }
                        // slash 菜单可见：已敲完整命令 → 直接执行；否则补全
                        // 高亮候选（保留已输入的参数文本），菜单随之关闭。
                        if slashMenuVisible {
                            if AgentSlashParsing.parse(text) != nil {
                                Task { @MainActor in onSubmit() }
                            } else {
                                completeSlash()
                            }
                            return .handled
                        }
                        // **不能直接同步提交**：SwiftUI 的 `.onKeyPress` 处理器在更新
                        // 事务里执行，而提交会写一堆 `@Published`，于是每条写入都报
                        // "Publishing changes from within view updates"（用户实测：
                        // 一次回车刷出 59 条）。跳到下一个主线程回合再发。
                        Task { @MainActor in onSubmit() }
                        return .handled
                    }
            }

            // Controls live in their OWN full-width row below the text —
            // beside a greedy TextEditor they'd all bunch to the right.
            // 统一间距：相邻控件一律 6pt（此前 4/6 混用，看起来忽紧忽松）。
            // 右侧组按用户要求"上下文用量 · 模型 · 思考等级"三件排开（参照
            // 主流客户端：gauge% 在模型左侧、🧠 等级在右侧）。
            HStack(spacing: 6) {
                fullAccessPill
                attachButton
                directiveButton
                micButton
                Spacer(minLength: 6)
                contextChip
                modelMenu
                thinkingMenu
                sendButton
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }

    /// Shows listening indicator or voice input errors.
    @ViewBuilder
    // MARK: - Slash 候选菜单

    private var slashMenu: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(slashSuggestions.enumerated()), id: \.element.command) { index, suggestion in
                    Button {
                        completeSlash(at: index)
                        isFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("/\(suggestion.command)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(suggestion.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            index == slashEffectiveIndex
                                ? AnyShapeStyle(.tint.opacity(0.15))
                                : AnyShapeStyle(.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    @ViewBuilder
    private var voiceStatusLine: some View {
        if let vm = voiceManager {
            if let err = vm.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(err)
                        .font(.system(size: 11))
                        .lineLimit(2)
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            } else if vm.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("正在聆听… 说话即可")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
    }

    /// Opens the image picker (panel handled by the parent).
    /// 输入栏控件的**共同规格**：26pt 高、同一描边与底色。
    /// 此前是"20pt 胶囊 + 28pt 圆钮 + 三种描边"，一行里四种观感（用户反馈"和谐一点"）。
    private enum Control {
        static let size: CGFloat = 26
        static let fill = Color(nsColor: .controlBackgroundColor).opacity(0.6)
        static let stroke = Color(nsColor: .separatorColor).opacity(0.4)
        static let strokeWidth: CGFloat = 0.5
    }

    private var attachButton: some View {
        Button(action: onAddAttachment) {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: Control.size, height: Control.size)
                .background(Circle().fill(Control.fill))
                .overlay(Circle().stroke(Control.stroke, lineWidth: Control.strokeWidth))
        }
        .buttonStyle(.plain)
        .help("Attach image ( vision models)")
    }

    private var directiveButton: some View {
        Button {
            onSessionDirective?()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSessionDirectiveActive ? AnyShapeStyle(appAccent) : AnyShapeStyle(Color.secondary))
                .frame(width: Control.size, height: Control.size)
                .background(Circle().fill(Control.fill))
                .overlay(Circle().stroke(Control.stroke, lineWidth: Control.strokeWidth))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Session instruction (this conversation only)"))
    }

    @ViewBuilder
    private var micButton: some View {
        if let vm = voiceManager {
            Button {
                vm.toggle()
            } label: {
                Circle()
                    .fill(Control.fill)
                    .frame(width: Control.size, height: Control.size)
                    .overlay(
                        Image(systemName: vm.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(vm.isRecording ? Color.red : Color.secondary)
                    )
                    .overlay(
                        Circle().stroke(Control.stroke, lineWidth: Control.strokeWidth)
                    )
            }
            .buttonStyle(.plain)
            .help(vm.isRecording ? "Stop listening" : "Voice input")
        }
    }

    /// Stop is only the button's role when there is nothing to send — typed
    /// text takes priority and goes to the queue instead.
    private var showsStop: Bool { isProcessing && !canSubmit }

    private var sendButton: some View {
        Button {
            if showsStop {
                onCancel()
            } else {
                onSubmit()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(sendFill)
                    .frame(width: Control.size, height: Control.size)
                Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(sendForeground)
            }
        }
        .buttonStyle(.plain)
        .disabled(!showsStop && !canSubmit)
        .help(showsStop ? "Stop (Esc)" : (isProcessing ? "Queue message" : "Send (⏎)"))
        .onHover { isHoveringSend = $0 }
        .animation(.hoverFast, value: isHoveringSend)
    }

    // MARK: - Background

    private var inputBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(0.0),
                    Color(nsColor: .controlBackgroundColor).opacity(0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Computed

    private var placeholder: String {
        awaitingQuestion ? String(localized: "Ask about this page…") : String(localized: "Ask Agent…")
    }

    private var borderColor: Color {
        isFocused
            ? appAccent.opacity(0.55)
            : Color(nsColor: .separatorColor).opacity(0.6)
    }

    private var sendFill: Color {
        if showsStop { return Color.red.opacity(0.85) }
        if !canSubmit { return Control.fill }        // 与其他控件同一底色（禁用态不突兀）
        if isHoveringSend { return appAccent.opacity(0.85) }
        return appAccent
    }

    private var sendForeground: Color {
        if showsStop { return .white }
        if !canSubmit { return Color.secondary.opacity(0.4) }
        return .white
    }
}
