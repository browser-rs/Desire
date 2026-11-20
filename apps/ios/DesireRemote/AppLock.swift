import Combine
import LocalAuthentication
import SwiftUI

/// **App 锁**（v0.8.69 Remote 优化，Face ID/设备密码）：
/// Remote 能指挥 Mac Agent 解锁敏感步骤、发完全访问指令——手机丢失即
/// 交出指挥权。开启后：app 退后台即上锁，回前台需 Face ID/设备密码解锁。
///
/// 状态机：`enabled`（用户开关，落 UserDefaults）+ `isLocked`（运行态）。
/// 解锁 = LAContext 设备属主认证（Face ID 失败自动回落设备密码）。
/// 锁屏覆盖层是**不透明全屏**（下方内容不可见——消息/产物不泄露）。
@MainActor
final class AppLock: ObservableObject {

    static let shared = AppLock()
    static let enabledKey = "remote.appLockEnabled"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// 运行态锁。首次安装默认未锁（用户在设置里主动开启后才进入锁定语义）。
    @Published private(set) var isLocked = false

    /// 本轮解锁正在认证中（防止重复弹 Face ID）。
    private var authenticating = false

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        // 开着 App 锁启动 → 直接锁定态（冷启动也保护）。
        isLocked = enabled
    }

    /// 开关切换：开 = 立即要求认证一次（确认机主本人开启）；关 = 直接放行
    /// （关闭不需要认证——手机已在主人手里）。
    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            isLocked = true
            authenticate()
        } else {
            isLocked = false
        }
    }

    /// 退后台 → 上锁（开着才锁）。
    func lockIfEnabled() {
        guard enabled else { return }
        isLocked = true
    }

    /// Face ID / 设备密码认证（懒请求权限——首次使用才触发系统弹窗）。
    func authenticate() {
        guard isLocked, !authenticating else { return }
        authenticating = true
        let context = LAContext()
        var evaluationError: NSError?
        // deviceOwnerAuthentication = Face ID 失败自动回落设备密码。
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            // 设备没有任何生物识别/密码 → 锁不住，放行（诚实降级）。
            authenticating = false
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "解锁 Desire Remote") { [weak self] success, _ in
            Task { @MainActor [weak self] in
                self?.authenticating = false
                if success { self?.isLocked = false }
            }
        }
    }
}

/// 锁屏覆盖层：全屏不透明（下方消息/产物不可见），一个解锁按钮触发认证。
struct AppLockOverlay: View {
    @EnvironmentObject var client: RemoteClient
    @ObservedObject var lock: AppLock

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.iphone")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Desire Remote 已锁定")
                    .font(.system(size: 17, weight: .semibold))
                Text("指挥 Mac Agent 前先验证是本人")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    lock.authenticate()
                } label: {
                    Label("解锁", systemImage: "faceid")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        // 覆盖层自己也需要品牌色调一致（独立 scene 语义——这里在 WindowGroup 内，
        // 继承 RootView 的 tint 即可；appAccent 双保险）。
        .preferredColorScheme(client.preferredColorScheme)
    }
}
