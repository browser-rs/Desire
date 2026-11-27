import Foundation

/// 冲突解决审计（v0.8.83）：动作之后记录"谁在什么时候把哪条冲突选了哪边"，
/// 只存标签（不含明文密码/卡号；冲突域本身只有书签/快拨/阅读列表）。
/// 本机保留最近 100 条，设置页可查看/清空，桥 `GET /sync/conflicts/audit` 只读。
nonisolated struct SyncConflictAuditEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var at: Date
    var domain: String
    var label: String
    /// "local" = 采用本地并重推；"remote" = 保留服务端胜者。
    var resolution: String
    /// "applied" / "kept-remote" / "failed"。
    var result: String
    var deviceName: String
}
