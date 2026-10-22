import Combine
import Foundation

/// 更新后 What's New（v0.8.0）：按构建号只自动弹一次。
///
/// 自动化启动（`--automation`）不自动弹，避免遮住桥/套件的 UI 操作；
/// 桥可显式 `POST /whatsnew/show`。Help 菜单也可随时打开。
@MainActor
final class WhatsNewStore: ObservableObject {
    static let shared = WhatsNewStore()

    @Published var isPresented = false

    private let lastSeenKey = "whatsNew.lastSeen"
    private var claimed = false

    var currentKey: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short)(\(build))"
    }

    var versionName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var hasUnseen: Bool {
        UserDefaults.standard.string(forKey: lastSeenKey) != currentKey
    }

    func presentIfNeeded() {
        guard !claimed, hasUnseen else { return }
        // 自动化/CI：别让 sheet 抢焦点（桥与套件照常跑）。
        guard !ProcessInfo.processInfo.arguments.contains("--automation") else { return }
        claimed = true
        isPresented = true
    }

    func show() {
        claimed = true
        isPresented = true
    }

    /// 用户关掉/点 Done：记为已读。Esc/点外部关闭也走这里（onDisappear）。
    func dismiss() {
        isPresented = false
        markSeen()
    }

    func markSeen() {
        UserDefaults.standard.set(currentKey, forKey: lastSeenKey)
        claimed = true
    }

    /// 测试/重新展示：清掉已读标记。
    func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: lastSeenKey)
        claimed = false
        isPresented = false
    }
}
