import SwiftUI
import Vision
import VisionKit

struct LoginView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        NavigationStack {
            Form {
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
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    Button {
                        client.login()
                    } label: {
                        if client.isWorking {
                            ProgressView()
                        } else {
                            Text("登录").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(client.isWorking || client.username.isEmpty || client.password.isEmpty)
                }
            }
            .navigationTitle("Desire Remote")
        }
    }
}

struct DevicesView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showScanner = false
    @State private var manualCode = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let desktop = client.desktopName {
                    // 已有配对：直接进入
                    Text(desktop).font(.title2.bold())
                    Button("打开控制台") { client.phase = .chat }
                        .buttonStyle(.borderedProminent)
                } else {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    Text("在 Mac 的 设置 → 远程 里生成配对二维码，用下面的方式导入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
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
                    VStack(spacing: 8) {
                        TextField("或粘贴二维码内容（JSON）", text: $manualCode)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("导入") { client.importPairing(manualCode) }
                            .disabled(manualCode.isEmpty)
                    }
                    .padding(.horizontal)
                }
                if let error = client.pairError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Spacer()
                Button("退出登录", role: .destructive) { client.logout() }
                    .font(.footnote)
            }
            .padding(.top, 32)
            .navigationTitle("配对设备")
            .sheet(isPresented: $showScanner) {
                ScannerSheet { raw in
                    showScanner = false
                    client.importPairing(raw)
                }
            }
        }
    }
}

/// VisionKit 扫码封装（真机可用；失败回退粘贴导入）。
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

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onRead: onRead) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onRead: (String) -> Void
        init(onRead: @escaping (String) -> Void) { self.onRead = onRead }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue {
                    Task { @MainActor in onRead(raw) }
                }
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(client.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: client.messages) { _, new in
                        if let last = new.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                inputBar
            }
            .navigationTitle(client.desktopName ?? "Desire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重新同步") { client.requestSync() }
                        Button("解除配对", role: .destructive) { client.unpair() }
                        Button("退出登录", role: .destructive) { client.logout() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(client.busy ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(client.connectionState)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if client.busy {
                Button("停止", role: .destructive) { client.sendCancel() }
                    .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("给 Agent 派个活…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { send() }
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendPrompt(text)
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.content ?? "")
                    .padding(10)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        case "tool":
            VStack(alignment: .leading, spacing: 2) {
                if let calls = message.toolCalls, !calls.isEmpty {
                    Text(calls.map { "🔧 \($0)" }.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 4) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
