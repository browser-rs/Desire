import SwiftUI

/// 登录页（未登录相位）。服务器地址不在此露出（设置页可选覆盖）。
struct LoginView: View {
    @EnvironmentObject var client: RemoteClient
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    private var canSubmit: Bool {
        !client.isWorking
            && !client.username.trimmingCharacters(in: .whitespaces).isEmpty
            && !client.password.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    brandHeader
                    credentialCard
                    if let error = client.loginError {
                        errorBanner(error)
                    }
                    loginButton
                    footnote
                }
                .desirePagePadding()
                .padding(.top, 40)
                .padding(.bottom, 30)
            }
            .background(DesireUI.pageFill.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var brandHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [DesireUI.brand, DesireUI.brand.opacity(0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("欲")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .shadow(color: DesireUI.brand.opacity(0.25), radius: 10, y: 4)

            VStack(spacing: 4) {
                Text("Desire Remote")
                    .font(.system(size: 22, weight: .semibold))
                Text("远程对话 Mac 上的 Agent")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 6)
    }

    private var credentialCard: some View {
        VStack(spacing: 0) {
            fieldRow(icon: "person", title: "用户名") {
                TextField("Desire 账号", text: $client.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
            }
            Divider().padding(.leading, 46)
            fieldRow(icon: "lock", title: "密码") {
                SecureField("密码", text: $client.password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSubmit { client.login() } }
            }
        }
        .desireCard(padding: 0)
    }

    private func fieldRow<Content: View>(
        icon: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                content()
                    .font(.system(size: 15))
            }
        }
        .padding(.horizontal, DesireUI.cardPadding)
        .padding(.vertical, 11)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
            Text(message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    private var loginButton: some View {
        Button {
            focused = nil
            client.login()
        } label: {
            HStack(spacing: 8) {
                if client.isWorking { ProgressView().tint(.white) }
                Text(client.isWorking ? "登录中…" : "登录")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                    .fill(canSubmit ? DesireUI.brand : Color.secondary.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private var footnote: some View {
        Text("工作全部在 Mac 本地执行：手机只负责派活、看进度、解锁敏感步骤。")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
    }
}
