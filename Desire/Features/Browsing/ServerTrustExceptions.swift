import Foundation

/// 会话级服务器证书信任例外（自签名/本地 HTTPS）。
///
/// 为什么存在：一次页面加载会对同一主机发起**多次**挑战（主框架 + 每个子资源
/// + 重定向）。没有记忆时每次挑战都弹证书警告 sheet——本地自签名站（PVE/
/// 路由器/内网服务）弹窗成灾（用户实测"疯狂弹窗"）。Chrome 的语义 =
/// 用户点过一次"仍然继续"后，本会话内该主机不再询问。
///
/// 会话级（不持久化）：重启后重新询问——证书例外是安全敏感决定，持久化
/// 需要配套的管理 UI（查看/撤销），那部分还没做。
@MainActor
final class ServerTrustExceptions {
    static let shared = ServerTrustExceptions()
    private init() {}

    /// 用户已点过"仍然继续"的主机。
    private var grantedHosts: Set<String> = []
    /// 正在展示决策窗的主机（同主机的后续挑战排队等第一次的决定）。
    private var presentingHosts: Set<String> = []
    /// 排队中的挑战：host → [(serverTrust, completionHandler)]。
    private var queued: [String: [(SecTrust, @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)]] = [:]

    func isGranted(_ host: String) -> Bool { grantedHosts.contains(host) }

    /// 用户点了"仍然继续"——主机入例外，放行全部排队挑战。
    func grant(_ host: String) {
        grantedHosts.insert(host)
        flush(host, granted: true)
    }

    /// 用户点了"取消"——放行（取消）全部排队挑战。
    func deny(_ host: String) {
        flush(host, granted: false)
    }

    /// 同主机已有决策窗在展示时返回 true（调用方应把挑战挂进队列）；
    /// 否则占用展示槽并返回 false。
    func claimPresentation(_ host: String) -> Bool {
        if presentingHosts.contains(host) { return true }
        presentingHosts.insert(host)
        return false
    }

    /// 该主机的挑战已不再展示（决策窗被系统关掉等边缘态）。
    func endPresentation(_ host: String) {
        presentingHosts.remove(host)
    }

    func queue(host: String, trust: SecTrust, completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        queued[host, default: []].append((trust, completionHandler))
    }

    private func flush(_ host: String, granted: Bool) {
        presentingHosts.remove(host)
        let pending = queued.removeValue(forKey: host) ?? []
        for (trust, handler) in pending {
            if granted {
                handler(.useCredential, URLCredential(trust: trust))
            } else {
                handler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
