import AppKit
import SwiftUI

/// 首启动引导（0.3.8）：三步——欢迎定位 / 默认浏览器 / Agent 配置入口。
/// 只在首次启动出现（desire.onboardingDone），完成后不再打扰。
struct OnboardingView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    enum Step: Int {
        case welcome = 0, defaultBrowser = 1, agent = 2
    }

    @State private var step: Step = .welcome
    @State private var isDefault = false
    /// 完成后置位并关窗（DesireApp 传入）。
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 步骤指示
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == step.rawValue ? appAccent : Color.secondary.opacity(0.25))
                        .frame(width: i == step.rawValue ? 22 : 8, height: 4)
                        .animation(.controlSpring, value: step)
                }
            }
            .padding(.top, 26)

            Group {
                switch step {
                case .welcome: welcomePage
                case .defaultBrowser: defaultBrowserPage
                case .agent: agentPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 24)

            HStack {
                if step.rawValue > 0 {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(step == .agent ? "Get Started" : "Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                if step == .welcome {
                    Button("Skip") { finish() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 22)
        }
        .frame(width: 480, height: 380)
        .onAppear(perform: checkDefaultBrowser)
    }

    private func advance() {
        if step == .agent {
            finish()
        } else {
            step = Step(rawValue: step.rawValue + 1) ?? .agent
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "desire.onboardingDone")
        onFinish()
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe.badge.arrow.clockwise")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(appAccent)
            Text("Welcome to Desire")
                .font(.system(size: 24, weight: .bold))
            Text("An AI-native browser: the app itself is an execution environment for agents — a localhost automation bridge, an MCP server, and a built-in Agent with 20+ tools.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultBrowserPage: some View {
        VStack(spacing: 14) {
            Image(systemName: isDefault ? "checkmark.seal.fill" : "globe.badge.chevron.backward")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isDefault ? .green : appAccent)
            Text("Make Desire Your Default Browser")
                .font(.system(size: 19, weight: .semibold))
            Text(isDefault
                 ? "Desire is your default browser — links open here."
                 : "Links from other apps will open in Desire.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !isDefault {
                Button("Set as Default Browser…") { setAsDefaultBrowser() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                StatusPill(text: "Default", kind: .success)
            }
        }
    }

    private var agentPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(appAccent)
            Text("Meet Your Agent")
                .font(.system(size: 19, weight: .semibold))
            Text("Open the agent panel (⌘') and ask it to browse, extract, monitor, or download for you. Configure a cloud model or use on-device models in Settings ▸ Agent.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Configure Agent in Settings…") {
                finish()
                postCommand(.showSettings)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Default browser

    private func checkDefaultBrowser() {
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) {
            isDefault = appURL == Bundle.main.bundleURL
        }
    }

    private func setAsDefaultBrowser() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
            Task { @MainActor in
                if error == nil {
                    NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { _ in
                        Task { @MainActor in checkDefaultBrowser() }
                    }
                }
            }
        }
    }

    private func postCommand(_ command: BrowserCommand) {
        CommandBus.shared.send(command)
    }
}
