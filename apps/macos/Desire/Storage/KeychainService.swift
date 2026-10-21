import Foundation
import LocalAuthentication
import os
import Security

/// 全仓统一的 Keychain 访问（kSecClassInternetPassword 条目）。
///
/// 历史上四处各写各的（PasswordStore / AgentPreferenceStore / SyncStore /
/// RemoteControlStore）：query 组装、non-interactive 处理两两不同，Remote 的
/// service 名还硬编码——收口一处后，Keychain 相关的修复（隐窗授权、ACL 失配、
/// service 过滤）只改这里。见 CODEBASE-AUDIT ARCH-5。
///
/// **启动路径不许读 secret data**（2026-10-22 用户实测：首次安装每条不同
/// 的 key 各弹一次钥匙串授权，26 条条目 = 26 次）。macOS 的 ACL 保护的是
/// `kSecReturnData`，**只查属性（`kSecReturnAttributes`）不会弹授权**——
/// "有没有配 Key / 已保存哪些站点"一律走 `exists` / `listAttributes`；
/// 真正需要秘密时（用户点显示/复制、Agent 回合、显式同步）才 `read`，
/// 一次只读一条。`interactive: false` 只屏蔽生物识别/密码框，**挡不住
/// ACL 的"允许访问"授权窗**，别拿它当"不弹窗"的保证。
nonisolated enum KeychainService {

    private static let log = Logger(subsystem: "me.siwi.Desire", category: "keychain")

    /// 本应用条目的默认 service 属性（loadAll 枚举按它圈范围——
    /// 不过滤会扫到其他应用的 Internet Password、连环弹授权）。
    static let defaultService = "me.siwi.Desire"

    // MARK: - Read

    /// 读一条（service/server/account 过滤；`service: nil` = 不过滤 service）。
    /// `httpsOnly`：只看网站密码条目（写入时带了 kSecAttrProtocolHTTPS），
    /// 用来把 AI Key/同步令牌排除在外。
    static func read(account: String, service: String? = defaultService,
                     server: String? = nil, httpsOnly: Bool = false,
                     interactive: Bool = false) -> Data? {
        var query = baseQuery(service: service, server: server)
        query[kSecAttrAccount as String] = account
        if httpsOnly { query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationContext as String] = nonInteractiveContext() }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        log.info("read account=\(account, privacy: .public) service=\(service ?? "-", privacy: .public) server=\(server ?? "-", privacy: .public) interactive=\(interactive, privacy: .public) status=\(status, privacy: .public)")
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    static func readString(account: String, service: String? = defaultService,
                           server: String? = nil, httpsOnly: Bool = false,
                           interactive: Bool = false) -> String? {
        read(account: account, service: service, server: server,
             httpsOnly: httpsOnly, interactive: interactive)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 只查存在性——**不取 data**，不会触发 Keychain 授权。启动路径专用。
    static func exists(account: String, service: String? = defaultService,
                       server: String? = nil, httpsOnly: Bool = false) -> Bool {
        var query = baseQuery(service: service, server: server)
        query[kSecAttrAccount as String] = account
        if httpsOnly { query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS }
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        log.info("exists account=\(account, privacy: .public) service=\(service ?? "-", privacy: .public) status=\(status, privacy: .public)")
        return status == errSecSuccess
    }

    /// 枚举条目的**元数据**（server/account），不取 data、不弹授权。
    /// `httpsOnly` = 只要网站密码（AI Key/同步令牌没有 HTTPS protocol 属性）。
    static func listAttributes(service: String = defaultService,
                               httpsOnly: Bool = false) -> [(server: String, account: String)] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if httpsOnly { query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS }
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let items = result as? [[String: Any]] ?? []
        log.info("listAttributes service=\(service, privacy: .public) httpsOnly=\(httpsOnly, privacy: .public) status=\(status, privacy: .public) count=\(items.count, privacy: .public)")
        return items.compactMap { dict in
            guard let server = dict[kSecAttrServer as String] as? String,
                  let account = dict[kSecAttrAccount as String] as? String else { return nil }
            return (server, account)
        }
    }

    /// 枚举某 service 下的全部条目**并读取 data**（PasswordStore 的显式 CSV
    /// 导出用）。**会逐条触发授权**——绝不能在启动/自动路径调用。
    /// **必须带 service 过滤**；启动路径 → 非交互。
    static func readAll(service: String = defaultService,
                        httpsOnly: Bool = false) -> [(server: String, account: String, data: Data)] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if httpsOnly { query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS }
        query[kSecUseAuthenticationContext as String] = nonInteractiveContext()
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { dict in
            guard let server = dict[kSecAttrServer as String] as? String,
                  let account = dict[kSecAttrAccount as String] as? String,
                  let data = dict[kSecValueData as String] as? Data else { return nil }
            return (server, account, data)
        }
    }

    // MARK: - Write / Delete

    /// 写（先删旧条目再 Add——更新语义；返回 SecItemAdd 状态码供调用方记日志）。
    /// `server` = InternetPassword 的站点域（PasswordStore 条目）；`httpsProtocol`
    /// 补 kSecAttrProtocol（同上，保持旧条目 query 兼容）。
    @discardableResult
    static func write(_ data: Data, account: String, service: String = defaultService,
                      server: String? = nil, httpsProtocol: Bool = false) -> OSStatus {
        delete(account: account, service: service, server: server)
        var query = baseQuery(service: service, server: server)
        query[kSecAttrAccount as String] = account
        if httpsProtocol { query[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS }
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    @discardableResult
    static func write(_ string: String, account: String, service: String = defaultService,
                      server: String? = nil, httpsProtocol: Bool = false) -> OSStatus {
        write(Data(string.utf8), account: account, service: service,
              server: server, httpsProtocol: httpsProtocol)
    }

    @discardableResult
    static func delete(account: String, service: String? = defaultService,
                       server: String? = nil) -> OSStatus {
        var query = baseQuery(service: service, server: server)
        query[kSecAttrAccount as String] = account
        return SecItemDelete(query as CFDictionary)
    }

    // MARK: - Private

    private static func baseQuery(service: String?, server: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword]
        if let service { query[kSecAttrService as String] = service }
        if let server { query[kSecAttrServer as String] = server }
        return query
    }

    private static func nonInteractiveContext() -> LAContext {
        // kSecUseAuthenticationUI 已废弃；interactionNotAllowed 的 LAContext 让
        // ACL 失配直接失败而不是排隐窗授权。
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
