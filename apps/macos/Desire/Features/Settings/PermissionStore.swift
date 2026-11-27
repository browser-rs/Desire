import Combine
import Foundation

@MainActor
class PermissionStore: ObservableObject {
    @Published private(set) var rules: [PermissionRule] = []
    /// 被本站规则拦掉的弹窗次数（v0.8.80）：供桥断言"规则真的执行了"，不靠
    /// WebKit 对无手势 window.open 的平台行为作判据。
    @Published private(set) var popupBlocks: Int = 0

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.permissionRules"

    init() {
        if let decoded = DiskStore.load([PermissionRule].self, key: key) {
            rules = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = AppPrefs.defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PermissionRule].self, from: data) {
            rules = decoded
            save()
            AppPrefs.defaults.removeObject(forKey: key)
        }
    }

    func decision(for host: String, type: PermissionType) -> PermissionDecision? {
        rules.first(where: { $0.host == host && $0.type == type })?.decision
    }

    func set(host: String, type: PermissionType, decision: PermissionDecision) {
        rules.removeAll { $0.host == host && $0.type == type }
        rules.append(PermissionRule(host: host, type: type, decision: decision))
        save()
    }

    /// 三态写入口（v0.8.80）：nil = 删除该条规则（回到"每次询问"）。
    func set(_ decision: PermissionDecision?, host: String, type: PermissionType) {
        guard let decision else { return remove(host: host, type: type) }
        set(host: host, type: type, decision: decision)
    }

    /// 摄像头行：写单类规则，并让联合权限（cameraAndMicrophone）保持一致
    /// （两者都允许才允许，任一拒绝即拒绝）。
    func setCamera(_ decision: PermissionDecision?, host: String) {
        set(decision, host: host, type: .camera)
        syncCombined(host: host)
    }

    /// 麦克风行：同上。
    func setMicrophone(_ decision: PermissionDecision?, host: String) {
        set(decision, host: host, type: .microphone)
        syncCombined(host: host)
    }

    private func syncCombined(host: String) {
        let combined = PermissionMatrix.combinedDecision(
            camera: decision(for: host, type: .camera),
            microphone: decision(for: host, type: .microphone))
        set(combined, host: host, type: .cameraAndMicrophone)
    }

    func notePopupBlocked() {
        popupBlocks += 1
    }

    /// 弹窗是否放行（未设置 = 允许，保持既有行为）。
    func popupsAllowed(for host: String) -> Bool {
        decision(for: host, type: .popups) != .deny
    }

    /// 本站是否拦截剪贴板读取（默认不拦——平台已经要求用户手势）。
    func clipboardReadBlocked(for host: String) -> Bool {
        decision(for: host, type: .clipboardRead) == .deny
    }

    func remove(host: String) {
        rules.removeAll { $0.host == host }
        save()
    }

    func remove(host: String, type: PermissionType) {
        rules.removeAll { $0.host == host && $0.type == type }
        save()
    }

    func removeAll(type: PermissionType) {
        rules.removeAll { $0.type == type }
        save()
    }

    func removeAll() {
        rules.removeAll()
        save()
    }

    /// 隐私面板矩阵单元格的三态循环写入口（未设置 → 允许 → 拒绝 → 未设置）。
    func cycle(host: String, type: PermissionType) {
        switch PermissionMatrix.cycled(decision(for: host, type: type)) {
        case .some(let d): set(host: host, type: type, decision: d)
        case nil: remove(host: host, type: type)
        }
    }

    private func save() {
        DiskStore.save(rules, key: key)
    }
}
