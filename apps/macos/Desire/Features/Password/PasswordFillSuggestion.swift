import Foundation

/// 页面检测到登录表单时的“填充存档密码”提示（2026-10-22）。
///
/// 只包含**元数据**（域名/用户名/条目 id）——密码不在这里、也不在页面加载时
/// 读取。用户点“Fill”后才由 `PasswordStore.password(for:)` 读这一条 Keychain
/// （一次授权），然后注入页面。这样启动/打开登录页永远不会为每条凭据弹窗。
struct PasswordFillSuggestion: Identifiable, Equatable {
    let id: UUID
    let domain: String
    let entryID: UUID
    let username: String
}
