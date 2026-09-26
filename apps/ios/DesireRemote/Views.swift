import SwiftUI
import Vision
import VisionKit

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        switch client.phase {
        case .login:
            LoginView()
        case .devices:
            DevicesView()
        case .chat:
            ChatView()
        }
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
                client.phase = .chat
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

// MARK: - 控制台（聊天）

struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var draft = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                if client.messages.isEmpty {
                    emptyState
                } else {
                    messageList
                }
                inputBar
            }
            .navigationTitle(client.desktopName ?? "Desire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                RemoteSettingsView()
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(client.busy ? Color.orange : (client.connectionState == "已连接" ? Color.green : Color.secondary))
                .frame(width: 8, height: 8)
            Text(client.connectionState)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if client.busy {
                ProgressView().controlSize(.mini)
                Button("停止", role: .destructive) { client.sendCancel() }
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.tint.opacity(0.7))
            Text("给 Agent 派个活").font(.headline)
            Text("指令会立即送达 Mac，Agent 在本地执行，\n这里实时显示对话与工具轨迹。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(client.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 6).id("bottom-anchor")
                }
                .padding()
            }
            .onChange(of: client.messages) { _, new in
                if let last = new.last {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if client.queuedOffline {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full")
                    Text("已排队，Mac 上线后自动送达")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
            }
            quickChips
            HStack(alignment: .bottom, spacing: 10) {
            TextField("给 Agent 派个活…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            sendButton
        }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 常用指令快捷 chips
    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["继续", "总结当前页面", "再检查一遍结果"], id: \.self) { chip in
                    Button { send(chip) } label: { Text(chip) }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                        .disabled(client.busy)
                }
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if client.busy {
            Button(role: .destructive) {
                client.sendCancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                    .opacity(draftIsEmpty ? 0.35 : 1)
            }
            .disabled(draftIsEmpty)
        }
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ override: String? = nil) {
        let text = (override ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendPrompt(text)
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var reasoningExpanded = false

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 48)
                Text(message.content ?? "")
                    .padding(12)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
            }
        case "tool":
            VStack(alignment: .leading, spacing: 4) {
                if let calls = message.toolCalls, !calls.isEmpty {
                    ForEach(calls, id: \.self) { call in
                        Label(call, systemImage: "wrench.and.screwdriver")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 4)
        default:
            VStack(alignment: .leading, spacing: 6) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup(isExpanded: $reasoningExpanded) {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    } label: {
                        Text("思考过程").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
