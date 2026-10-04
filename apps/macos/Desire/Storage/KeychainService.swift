import Foundation
import LocalAuthentication
import Security

/// 全仓统一的 Keychain 访问（kSecClassInternetPassword 条目）。
///
/// 历史上四处各写各的（PasswordStore / AgentPreferenceStore / SyncStore /
/// RemoteControlStore）：query 组装、non-interactive 处理两两不同，Remote 的
/// service 名还硬编码——收口一处后，Keychain 相关的修复（隐窗授权、ACL 失配、
/// service 过滤）只改这里。见 CODEBASE-AUDIT ARCH-5。
///
/// **非交互读**（`interactive: false`）：启动、脱敏这类用户不在场路径必须
/// 非交互——条目 ACL 认不出当前构建（adhoc 重建换 cdhash）时，交互读会向
/// SecurityAgent 申请授权，而那个授权窗可能永远不渲染（隐窗排队，2026-09-24
/// 实测：`SecItemCopyMatching` 同步等它 = 主线程启动即卡死，v0.3.13 同样中招）。
/// 失败成 nil/空，调用方按"未配置"呈现，用户在场时再交互读/重存。
nonisolated enum KeychainService {

    /// 本应用条目的默认 service 属性（loadAll 枚举按它圈范围——
    /// 不过滤会扫到其他应用的 Internet Password、连环弹授权）。
    static let defaultService = "me.siwi.Desire"

    // MARK: - Read

    /// 读一条（service/server/account 过滤；`service: nil` = 不过滤 service，
    /// 仅 PasswordStore 的按域名查找走这一形态，别用于新代码）。
    static func read(account: String, service: String? = defaultService,
                     server: String? = nil, interactive: Bool = false) -> Data? {
        var query = baseQuery(service: service, server: server)
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationContext as String] = nonInteractiveContext() }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    static func readString(account: String, service: String? = defaultService,
                           server: String? = nil, interactive: Bool = false) -> String? {
        read(account: account, service: service, server: server, interactive: interactive)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 枚举某 service 下的全部条目（PasswordStore.loadAll 用）。
    /// **必须带 service 过滤**；启动路径 → 非交互。
    static func readAll(service: String = defaultService) -> [(server: String, account: String, data: Data)] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
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
