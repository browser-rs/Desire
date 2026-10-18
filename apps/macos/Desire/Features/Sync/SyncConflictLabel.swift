import Foundation

/// 同步冲突条目的**可读标签提取**（v0.7.23 冲突明细；Foundation-only 进
/// harness）：服务端 LWW 回胜者的密文在本机解密后，从各域 payload 的常见
/// 形状里挑一句人能认出来的话——各域 payload 结构不同（书签 {title,url}、
/// 设置 KV {key,value}、记忆 {content}…），这里按优先级兜底，挑不出就
/// 返回 nil（调用方退回 client_id 短码）。
nonisolated enum SyncConflictLabel {

    static func label(fromPlainJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        // 书签/阅读列表形态：title（可拼 URL host 佐证）。
        if let title = object["title"] as? String, !title.isEmpty {
            if let urlString = object["url"] as? String,
               let host = URL(string: urlString)?.host, !host.isEmpty {
                return "\(title.prefix(60)) — \(host)"
            }
            return String(title.prefix(60))
        }
        // 设置 KV 形态：key = value 前缀。
        if let key = object["key"] as? String, !key.isEmpty {
            if let value = object["value"] {
                let valueText = (value as? String) ?? String(describing: value)
                return "\(key.prefix(30)) = \(valueText.prefix(30))"
            }
            return String(key.prefix(60))
        }
        // 记忆/摘要形态：content 前缀。
        if let content = object["content"] as? String, !content.isEmpty {
            return String(content.prefix(60))
        }
        // 兜底：第一个非空字符串值。
        for value in object.values {
            if let text = value as? String, !text.isEmpty {
                return String(text.prefix(60))
            }
        }
        return nil
    }
}
