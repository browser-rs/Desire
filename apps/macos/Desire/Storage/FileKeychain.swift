import Foundation

/// **封闭启动下的钥匙串后端**（v0.8.76 批 4，Foundation-only 进 tests/run.sh）。
///
/// `--data-dir` 此前只隔离文件存储与偏好，钥匙串是共享的——而共享的代价不是
/// "假 Key 写进登录钥匙串"这么轻：v0.8.0 起全部 AI Key 与同步令牌合并存在
/// **同一个**条目里，读写都是整条读—改—写。封闭实例因此会读出用户的全部密钥，
/// 再把那个条目整个重写一遍——条目被哪个进程重建，访问控制名单的属主就换成谁。
///
/// 现在 `StorageRoot.isOverridden` 时 `KeychainService` 全部走这里：数据目录下的
/// `keychain/` 一条记录一个 JSON 文件。**明文**——里面只会有测试用的假凭据，
/// 真实钥匙串零接触（读也不读）。匹配语义照搬系统钥匙串的查询：
/// service / server / account 三个可选过滤，`httpsOnly` 只看带 HTTPS 协议属性的条目。
nonisolated final class FileKeychain: @unchecked Sendable {

    static let shared = FileKeychain()

    struct Record: Codable, Equatable, Sendable {
        var service: String
        var server: String?
        var account: String
        var httpsOnly: Bool
        var data: Data
        var updatedAt: Date
    }

    /// 默认目录 = `<data-dir>/keychain/`。
    static var defaultDirectory: URL {
        StorageRoot.directory.appendingPathComponent("keychain", isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    // MARK: - 查询（与 KeychainService 同名同义）

    func read(account: String, service: String? = nil, server: String? = nil,
              httpsOnly: Bool = false) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().first {
            matches($0, service: service, server: server, account: account, httpsOnly: httpsOnly)
        }?.data
    }

    func exists(account: String, service: String? = nil, server: String? = nil,
                httpsOnly: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().contains {
            matches($0, service: service, server: server, account: account, httpsOnly: httpsOnly)
        }
    }

    /// 枚举元数据（server/account）。与系统钥匙串一致：没有 server 的条目
    /// （AI Key、同步令牌）不在此列。
    func listAttributes(service: String? = nil, httpsOnly: Bool = false) -> [(server: String, account: String)] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().compactMap { record in
            guard matches(record, service: service, server: nil, account: nil, httpsOnly: httpsOnly),
                  let server = record.server else { return nil }
            return (server, record.account)
        }
    }

    func readAll(service: String? = nil, httpsOnly: Bool = false) -> [(server: String, account: String, data: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().compactMap { record in
            guard matches(record, service: service, server: nil, account: nil, httpsOnly: httpsOnly),
                  let server = record.server else { return nil }
            return (server, record.account, record.data)
        }
    }

    // MARK: - 写 / 删

    /// 更新语义（同一 service/server/account 只留一条）。返回是否落盘。
    @discardableResult
    func write(_ data: Data, account: String, service: String? = nil, server: String? = nil,
               httpsProtocol: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = Record(service: service ?? "", server: server, account: account,
                            httpsOnly: httpsProtocol, data: data, updatedAt: Date())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(record).write(
                to: directory.appendingPathComponent(
                    Self.fileName(service: service, server: server, account: account)),
                options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 删除（不带协议过滤——与 `SecItemDelete` 的查询一致）。返回是否删掉了东西。
    @discardableResult
    func delete(account: String, service: String? = nil, server: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let victims = loadAll().filter {
            matches($0, service: service, server: server, account: account, httpsOnly: false)
        }
        var removed = false
        for record in victims {
            let name = Self.fileName(service: record.service.isEmpty ? nil : record.service,
                                     server: record.server, account: record.account)
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed = true
            }
        }
        return removed
    }

    /// 清空（仅测试用）。
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - 内部

    private func matches(_ record: Record, service: String?, server: String?, account: String?,
                         httpsOnly: Bool) -> Bool {
        if let service, record.service != service { return false }
        if let server, record.server != server { return false }
        if let account, record.account != account { return false }
        if httpsOnly && !record.httpsOnly { return false }
        return true
    }

    private func loadAll() -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Record.self, from: data)
        }
    }

    /// 文件名 = `service ␁ server ␁ account` 的 base64url。三元组唯一 → 一条记录一个
    /// 文件；超长（长账号/长域名）时截断并接内容摘要，避免撞文件名长度上限。
    static func fileName(service: String?, server: String?, account: String) -> String {
        let composite = (service ?? "") + "\u{1}" + (server ?? "") + "\u{1}" + account
        var name = Data(composite.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if name.count > 180 {
            name = String(name.prefix(150)) + "-" + digest(composite)
        }
        return name + ".json"
    }

    /// FNV-1a 64 位，十六进制。只为区分超长文件名，不做安全用途。
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in text.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
