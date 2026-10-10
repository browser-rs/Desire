import Combine
import Foundation

/// DPP 第三方适配包仓库（2026-10-10）：`Application Support/Desire/
/// DPPAdapters/*.json`。每包一个文件，启停状态独立持久化（UserDefaults
/// `dpp.adapter.disabled`——包文件本体保持"作者原样"，启停不污染文件）。
/// 解析接入点：`WebView.Coordinator.parsePageProtocol` 页面无原生声明时
/// 按本 store 的索引查适配。
@MainActor
final class DPPAdapterStore: ObservableObject {
    static let shared = DPPAdapterStore()

    @Published private(set) var adapters: [DPPAdapter] = []
    /// 加载失败的文件（文件名 → 原因），设置页透出。
    @Published private(set) var loadErrors: [String: String] = [:]
    /// 装载来源目录里的 adapter name → 文件名（启停/删除要定位文件）。
    private var fileNames: [String: String] = [:]

    private static let disabledKey = "dpp.adapter.disabled"
    private var disabled: Set<String> = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Desire/DPPAdapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? [])
        reload()
    }

    func isEnabled(_ adapter: DPPAdapter) -> Bool {
        !disabled.contains(adapter.name)
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        if enabled {
            disabled.remove(name)
        } else {
            disabled.insert(name)
        }
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        objectWillChange.send()
    }

    /// host+url 命中的**第一个启用**适配器（文件名排序决定优先级——
    /// 稳定、可预期；同名场景极少，先不做包内优先级配置）。
    func adapter(for url: URL) -> DPPAdapter? {
        adapters
            .filter { isEnabled($0) && $0.matches(url: url) }
            .min { $0.name < $1.name }
    }

    // MARK: - 加载

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil
        ) else { return }
        var loaded: [DPPAdapter] = []
        var errors: [String: String] = [:]
        var filesByName: [String: String] = [:]
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url) else {
                errors[url.lastPathComponent] = "unreadable"
                continue
            }
            let (adapter, error) = DPPAdapter.decode(data)
            if let adapter {
                // 同名包后加载的覆盖（目录名即身份，与 SkillStore 同语义）。
                loaded.removeAll { $0.name == adapter.name }
                loaded.append(adapter)
                filesByName[adapter.name] = url.lastPathComponent
            } else {
                errors[url.lastPathComponent] = error ?? "invalid"
            }
        }
        adapters = loaded.sorted { $0.name < $1.name }
        loadErrors = errors
        fileNames = filesByName
    }

    // MARK: - 导入 / 删除

    /// 导入一个适配包文件（拷进目录；同名 = 覆盖更新）。
    func importFile(at source: URL) throws -> DPPAdapter {
        let data = try Data(contentsOf: source)
        let (adapter, error) = DPPAdapter.decode(data)
        guard let adapter else {
            throw ImportError.invalid(error ?? "invalid")
        }
        let target = Self.directory.appendingPathComponent("\(adapter.name).json")
        try data.write(to: target, options: .atomic)
        reload()
        return adapter
    }

    /// 从 URL 安装社区适配包（http(s) 直链 JSON；同名 = 覆盖更新）。
    /// 社区分发的最小闭环：仓库 docs/dpp-adapters/ 的 GitHub raw 链接、
    /// 任何静态托管都能当包源。http 不落地（协议降级拒收）。
    @discardableResult
    func installFromURL(_ urlString: String) async throws -> DPPAdapter {
        guard let url = URL(string: urlString),
              url.scheme == "https" || url.scheme == "http" else {
            throw ImportError.invalid("URL must be http(s)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ImportError.invalid("server returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard data.count < 2_000_000 else {
            throw ImportError.invalid("package over 2MB — not a declaration")
        }
        let (adapter, error) = DPPAdapter.decode(data)
        guard let adapter else {
            throw ImportError.invalid(error ?? "invalid")
        }
        let target = Self.directory.appendingPathComponent("\(adapter.name).json")
        try data.write(to: target, options: .atomic)
        reload()
        return adapter
    }

    func remove(_ name: String) {
        if let file = fileNames[name] {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(file))
        }
        disabled.remove(name)
        UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.disabledKey)
        reload()
    }

    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "Invalid adapter package: \(detail)"
            }
        }
    }
}
