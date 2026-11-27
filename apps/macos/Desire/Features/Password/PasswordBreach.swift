import CryptoKit
import Foundation

/// **泄露检查的纯逻辑**（v0.8.80，Foundation + CryptoKit，进 tests/run.sh）。
///
/// HIBP 的 k-匿名协议：本机算密码的 SHA-1，**只把前 5 位十六进制**发给服务端
/// （`/range/5BAA6`），服务端返回该前缀下所有已知泄露哈希的**后 35 位 + 次数**；
/// 本机再比对完整后缀。明文与完整哈希都不出本机——同前缀的空间有 16^5 ≈ 100 万条，
/// 服务端无法反推你在查哪一个。
nonisolated enum PasswordBreach {
    static let defaultBase = URL(string: "https://api.pwnedpasswords.com")!
    static let prefixLength = 5

    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// 发给服务端的前缀（大写 5 位）。
    static func prefix(of password: String) -> String {
        String(sha1Hex(password).prefix(prefixLength)).uppercased()
    }

    /// 只在本机比对的剩余 35 位。
    static func suffix(of password: String) -> String {
        String(sha1Hex(password).dropFirst(prefixLength)).uppercased()
    }

    /// `/range/<前缀>`。`base` 可注入（E2E 用本地假端点；默认是 HIBP）。
    static func rangeURL(for password: String, base: URL = defaultBase) -> URL {
        base.appendingPathComponent("range").appendingPathComponent(prefix(of: password))
    }

    /// 解析 range 响应（每行 `后缀:次数`，大小写不敏感）；返回该密码的泄露次数，
    /// nil = 响应里没有这个哈希（未在已知泄露中出现）。
    static func breachCount(for password: String, rangeResponse: String) -> Int? {
        let want = suffix(of: password)
        for line in rangeResponse.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == want,
                  let count = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            return count
        }
        return nil
    }

    /// 录入/粘贴的整条网址 → 主机名（`https://www.Example.com/login` → `example.com`）。
    /// 密码编辑表单与测试共用。
    static func normalizedDomain(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    /// 按前缀分组：同一个前缀的密码只发一次请求。
    static func grouped(_ passwords: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for password in passwords {
            out[prefix(of: password), default: []].append(password)
        }
        return out
    }
}
