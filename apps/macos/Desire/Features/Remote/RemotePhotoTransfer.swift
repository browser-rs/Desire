import Foundation

/// **手机发图分片聚合**（v0.8.69 批 1，Foundation-only 进 tests/run.sh）：
/// push 帧硬限 32KB——图片 base64 切 ~24KB 片分帧传输，Mac 端按 id 聚齐
/// 落盘。状态机抽纯逻辑（RemoteControlStore 只做 IO 与帧路由）。
nonisolated enum RemotePhotoTransfer {

    /// 单张图片的聚合器（一张图 = 一个 id）。
    struct Accumulator {
        let total: Int
        let name: String
        private var parts: [Int: Data] = [:]

        /// total 至少 1；文件名清洗掉路径分隔与控制字符（防穿越/防畸形名）。
        init?(total: Int, name: String) {
            let cleaned = Self.sanitizedFileName(name)
            guard total >= 1, !cleaned.isEmpty else { return nil }
            self.total = total
            self.name = cleaned
        }

        /// 收片；返回 false = 无效（越界序号/重复片且内容不同——重复同内容幂等）。
        mutating func add(chunk idx: Int, data: Data) -> Bool {
            guard idx >= 0, idx < total else { return false }
            if let existing = parts[idx] {
                return existing == data   // 重传同片幂等
            }
            parts[idx] = data
            return true
        }

        var receivedCount: Int { parts.count }
        var isComplete: Bool { parts.count >= total }

        /// 聚齐时按序号拼出全量（未聚齐返回 nil）。
        var assembled: Data? {
            guard isComplete else { return nil }
            return (0..<total).compactMap { parts[$0] }.reduce(Data(), +)
        }

        /// 文件名清洗：去路径成分与控制字符，保留字母/数字/点/横线/下划线/
        /// 中文等常见字符；空结果给默认名。
        static func sanitizedFileName(_ raw: String) -> String {
            let base = (raw as NSString).lastPathComponent
            let allowed = CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: ".-_ "))
            let cleaned = base
                .components(separatedBy: allowed.inverted)
                .joined()
                .trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty { return "photo.jpg" }
            return cleaned
        }

        /// 落盘名：<时间戳>-<清洗后的名>（时间戳由调用方传，便于测试）。
        static func uploadFileName(name: String, stamp: String) -> String {
            "\(stamp)-\(sanitizedFileName(name))"
        }
    }
}
