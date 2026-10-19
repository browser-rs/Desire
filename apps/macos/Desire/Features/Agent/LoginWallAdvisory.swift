import Foundation

/// 登录墙指引（v0.7.24）：抽取 0 条目且页面明显是登录墙时，给模型一句**可行动**
/// 指引，而不是干巴巴的空列表（此前模型会盲目重试或换策略，白烧回合）。
/// 判定**宽松**（只是附加文案、不改变数据路径）：可见密码框优先，其次登录词。
/// 纯逻辑（Foundation-only，进 harness）。
nonisolated enum LoginWallAdvisory {
    static func advise(hasVisiblePasswordField: Bool, hasLoginWords: Bool) -> String? {
        if hasVisiblePasswordField {
            return "\n(0 items and the page shows a visible password field — this looks like a login wall. "
                + "Ask the user to log in to the site in the browser first, then retry pageExtract. "
                + "Do not keep retrying or switch strategies while logged out.)"
        }
        if hasLoginWords {
            return "\n(0 items and the page text mentions sign-in/login — if this content requires an account, "
                + "log in first, then retry.)"
        }
        return nil
    }
}
