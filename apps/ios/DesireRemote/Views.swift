import MarkdownUI
import SwiftUI
import Vision
import VisionKit

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    /// 朱砂品牌色（与 Mac 端「欲」字印章一致）
    static let brand = Color(red: 0.75, green: 0.23, blue: 0.10)

    var body: some View {
        Group {
            switch client.phase {
            case .login:
                LoginView()
            case .devices:
                DevicesView()
            case .sessions:
                SessionsView()
            case .chat:
                ChatView()
            }
        }
        .tint(Self.brand)
        .preferredColorScheme(client.preferredColorScheme)
    }
}

// MARK: - 登录

struct LoginView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.red.opacity(0.9))
                            Text("欲")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Desire Remote").font(.headline)
                            Text("远程对话 Mac 上的 Agent").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("服务器") {
                    TextField("https://api.mankong.icu/v9", text: $client.serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Desire 账号") {
                    TextField("用户名", text: $client.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $client.password)
                }
                if let error = client.loginError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                Section {
                    Button {
                        client.login()
                    } label: {
                        HStack {
                            Spacer()
                            if client.isWorking {
                                ProgressView()
                            } else {
                                Text("登录").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(client.isWorking || client.username.isEmpty || client.password.isEmpty)
                }
                Section {
                    Text("工作全部在 Mac 本地执行：手机只负责派活、看进度、解锁敏感步骤。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Desire Remote")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 配对

struct DevicesView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showScanner = false
    @State private var manualCode = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let desktop = client.desktopName {
                        pairedCard(desktop)
                    } else {
                        unpairedCard
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("配对设备")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("退出登录", role: .destructive) { client.logout() }
                        .font(.footnote)
                }
            }
            .sheet(isPresented: $showScanner) {
                ScannerSheet { raw in
                    showScanner = false
                    client.importPairing(raw)
                }
            }
        }
    }

    @ViewBuilder
    private func pairedCard(_ desktop: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(desktop).font(.title3.bold())
            Button {
                client.phase = .sessions
            } label: {
                Label("打开控制台", systemImage: "message.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var unpairedCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("与你的 Mac 配对").font(.title3.bold())
            Text("在 Mac 的 设置 → 远程 里生成配对二维码，扫码或粘贴导入。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showScanner = true
            } label: {
                Label("扫码配对", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!DataScannerViewController.isAvailable)
            if !DataScannerViewController.isAvailable {
                Text("相机不可用（模拟器/无权限）——可粘贴二维码内容").font(.caption2).foregroundStyle(.secondary)
            }
            TextField("粘贴二维码内容（JSON）", text: $manualCode)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("导入") { client.importPairing(manualCode) }
                .disabled(manualCode.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 会话列表（聊天记录，结构照 IrsClawApp SessionListView）

struct SessionsView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if client.sessions.isEmpty {
                    emptyState
                } else {
                    sessionsList
                }
            }
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        client.newSession()
                    } label: {
                        Label("新建会话", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { client.requestSessions() }
            .sheet(isPresented: $showSettings) { RemoteSettingsView() }
            .onAppear {
                if client.connectionState != "已连接" { client.appForegrounded() }
                client.requestSessions()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("还没有会话").font(.title3.weight(.semibold))
                Text("在 Mac 上打开 Agent 面板开始一轮对话，\n这里会实时出现。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("刷新") { client.requestSessions() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionsList: some View {
        List {
            Section {
                ForEach(client.sessions) { session in
                    SessionRowCard(session: session,
                                   isSelected: session.id == client.selectedSessionID)
                        .contentShape(Rectangle())
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onTapGesture { client.selectSession(session.id) }
                }
            } header: {
                Text(client.desktopName ?? "Mac 上的会话")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .padding(.leading, 4)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct SessionRowCard: View {
    let session: RemoteClient.RemoteSessionInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(RootView.brand.opacity(0.9))
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if session.busy {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("工作中").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text("\(session.count) 条消息").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(RootView.brand)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - 控制台（聊天）

struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    @StateObject private var voice = VoiceInputService()

    var body: some View {
        NavigationStack {
            ZStack {
                // 全屏消息层：从屏幕顶到输入栏，全程可滚
                Group {
                    if client.messages.isEmpty {
                        emptyState
                    } else {
                        messageList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 顶部漂浮状态条（不是栏块，悬浮在内容之上）
                VStack {
                    floatingTopBar
                    Spacer()
                }

                // 底部漂浮输入区
                VStack {
                    Spacer()
                    inputArea
                }
            }
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { RemoteSettingsView() }
        }
    }

    // MARK: 顶部漂浮状态条（全屏聊天：无栏块，仅悬浮元素）

    private var floatingTopBar: some View {
        HStack(spacing: 8) {
            Button {
                client.requestSessions()
                client.phase = .sessions
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(RootView.brand)
                Text("欲").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            Text(client.desktopName ?? "Desire")
                .font(.footnote.weight(.semibold)).lineLimit(1)
            HStack(spacing: 4) {
                Circle()
                    .fill(client.busy ? .orange : (client.connectionState == "已连接" ? .green : .secondary))
                    .frame(width: 6, height: 6)
                Text(client.busy ? "工作中" : client.connectionState)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if client.busy {
                Button { client.sendCancel() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: 顶部（自定义，最大化内容区）

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.9))
                Text("欲").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.desktopName ?? "Desire")
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(client.busy ? .orange : (client.connectionState == "已连接" ? .green : .secondary))
                        .frame(width: 6, height: 6)
                    Text(client.connectionState).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if client.busy {
                Button { client.sendCancel() } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(.red)
                }
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 34)).foregroundStyle(RootView.brand.opacity(0.85))
            Text("给 Agent 派个活").font(.subheadline.weight(.semibold))
            Text("指令立即送达 Mac，Agent 在本地执行")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(client.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 52)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onChange(of: client.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: 漂浮输入区（深色可见的实体胶囊；建议卡片在空态里）

    private var inputArea: some View {
        VStack(spacing: 8) {
            if client.queuedOffline {
                Label("已排队，Mac 上线后自动送达", systemImage: "tray.full")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if voice.isRecording {
                recordingBar
            } else if client.messages.isEmpty {
                HStack(spacing: 8) {
                    ForEach(["继续", "总结当前页面"], id: \.self) { chip in
                        Button { send(chip) } label: {
                            Text(chip).font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                micButton.padding(.bottom, 4).padding(.leading, 2)
                TextField("给 Agent 派个活…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($inputFocused)
                    .padding(.vertical, 9)
                sendButton.padding(.bottom, 3).padding(.trailing, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
                    .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 5)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var recordingBar: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("听写中…").font(.caption.weight(.medium)).foregroundStyle(.red)
            if !voice.transcribedText.isEmpty {
                Text(voice.transcribedText)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("完成") { voice.stop() }.font(.caption.bold())
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color.red.opacity(0.08), in: Capsule())
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var sendButton: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if client.busy {
            Button { client.sendCancel() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 32))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
        } else {
            Button { send() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(empty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint))
            }
            .disabled(empty)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: empty)
        }
    }

    @ViewBuilder
    private var micButton: some View {
        Button {
            if voice.isRecording {
                voice.stop()
            } else {
                voice.start()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(voice.isRecording ? Color.red.opacity(0.15) : Color.primary.opacity(0.06))
                    .frame(width: 32, height: 32)
                Image(systemName: voice.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(voice.isRecording ? .red : .secondary)
            }
        }
        .disabled(client.busy || !voice.isAvailable)
        .onChange(of: voice.transcribedText) { _, text in
            if voice.isRecording, !text.isEmpty { draft = text }
        }
    }

    private func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendPrompt(text)
        if override == nil { draft = "" }
    }
}

// MARK: - 气泡（头像 + 卡片，参考 IrsClawApp 视觉语言）

private struct RemoteAvatar: View {
    let icon: String
    let colors: [Color]

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded = false
    @State private var toolExpanded = false

    var body: some View {
        switch message.role {
        case "user":
            if (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else {
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 40)
                Text(message.content ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor)
                    )
                    .foregroundStyle(.white)
                RemoteAvatar(icon: "person.fill", colors: [.blue, .cyan])
            }
            }
        case "tool":
            if (message.toolCalls ?? []).isEmpty,
               (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyView()
            } else {
            HStack(alignment: .top, spacing: 8) {
                RemoteAvatar(icon: "wrench.and.screwdriver.fill", colors: [.gray, .secondary])
                VStack(alignment: .leading, spacing: 4) {
                    if let calls = message.toolCalls, !calls.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { toolExpanded.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "wrench.and.screwdriver")
                                Text(calls.joined(separator: " · "))
                                    .lineLimit(1)
                                Image(systemName: toolExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    if toolExpanded, let content = message.content,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(content)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Spacer(minLength: 20)
            }
            }
        default:
            HStack(alignment: .top, spacing: 8) {
                RemoteAvatar(icon: "sparkles", colors: [.purple, .pink])
                VStack(alignment: .leading, spacing: 6) {
                    if let reasoning = message.reasoning, !reasoning.isEmpty {
                        DisclosureGroup(isExpanded: $reasoningExpanded) {
                            Text(reasoning)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 2)
                        } label: {
                            Label("思考过程", systemImage: "brain")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color(.tertiarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let content = message.content,
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownTextView(text: content)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(.tertiarySystemBackground))
                            )
                    }
                }
                Spacer(minLength: 20)
            }
        }
    }
}

// MARK: - 设置

struct RemoteSettingsView: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL: String = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("服务器地址", text: $serverURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("修改后需退出登录并重新登录才生效。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("保存服务器地址") {
                        client.saveServerURL(serverURL)
                        saved = true
                    }
                    .disabled(serverURL.isEmpty)
                }
                Section("外观") {
                    Picker("主题", selection: $client.appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("账号") {
                    LabeledContent("用户名", value: client.savedUsername)
                    Button("退出登录", role: .destructive) {
                        client.logout()
                        dismiss()
                    }
                }
                Section {
                    Button("解除与 Mac 的配对", role: .destructive) {
                        client.unpair()
                        dismiss()
                    }
                } footer: {
                    Text("解除后需在 Mac 上重新扫码配对。已同步到服务器的数据不受影响。")
                }
                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                    LabeledContent("状态", value: client.connectionState)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                serverURL = client.serverURL
            }
            .onChange(of: saved) { _, isSaved in
                if isSaved {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        saved = false
                    }
                }
            }
        }
    }
}

// MARK: - VisionKit 扫码（真机；DataScannerViewController 必须显式 startScanning）

struct ScannerSheet: UIViewControllerRepresentable {
    let onRead: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // DataScannerViewController 不可继承（非 open），启动扫描放这里
        if !context.coordinator.started {
            context.coordinator.started = true
            try? uiViewController.startScanning()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onRead: onRead) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRead: (String) -> Void
        private var didFire = false
        fileprivate var started = false
        init(onRead: @escaping (String) -> Void) { self.onRead = onRead }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFire else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue,
                   !raw.isEmpty {
                    didFire = true
                    onRead(raw)
                    return
                }
            }
        }
    }
}

// MARK: - Markdown 渲染（MarkdownUI，主题照 IrsClawApp MarkdownTextView）

struct MarkdownTextView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    private var bubbleTheme: Theme {
        // 边距收紧到气泡内合适的呼吸感；表格横向滚动（手机宽度放不下）
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.35))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.2))
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.08))
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(0.95))
                    }
                    .markdownMargin(top: 6, bottom: 6)
            }
            .codeBlock { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(.em(0.92))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        colorScheme == .dark ? Color(rgba: 0xffff_ff14) : Color(rgba: 0x1b1f_230d)
                    )
                    .markdownMargin(top: 8, bottom: 8)
            }
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollBounceBehavior(.basedOnSize)
                .markdownTableBorderStyle(.init(
                    color: colorScheme == .dark ? Color(rgba: 0x4244_4eff) : Color(rgba: 0xe4e4_e8ff)
                ))
                .markdownTableBackgroundStyle(.alternatingRows(
                    colorScheme == .dark ? Color(rgba: 0x1819_1dff) : .white,
                    colorScheme == .dark ? Color(rgba: 0x2526_2aff) : Color(rgba: 0xf7f7_f9ff)
                ))
                .markdownMargin(top: 8, bottom: 12)
            }
            .thematicBreak {
                Divider()
                    .markdownMargin(top: 12, bottom: 12)
            }
    }

    var body: some View {
        // 不加 .id(text)：流式更新时每个 token 都会换文本，加 id 会整棵重建、
        // 未闭合的 Markdown 闪成空/原文。外层 ForEach 已按 message.id 稳定身份。
        Markdown(text)
            .markdownTheme(bubbleTheme)
            .textSelection(.enabled)
    }
}
