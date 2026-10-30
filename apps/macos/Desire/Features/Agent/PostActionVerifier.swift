import Foundation

/// 动作后核验（v0.8.25）：副作用动作执行后对比页面指纹，给模型明确的
/// `[verify]` 结论——不再只靠模型自觉写 verificationNote。
///
/// 纯逻辑（判定/文案）在这里，指纹采集在 BrowserToolProvider（WebKit）。
nonisolated enum PostActionVerdict: String, Sendable {
    case navigated
    case changed
    case unchanged
    case unknown
}

nonisolated enum PostActionVerifier {
    /// 需要核验的工具：改变页面状态或有导航意图的。
    static let tools: Set<String> = [
        "click", "clickAt", "type", "fill", "fillForm", "fillLogin",
        "pressKey", "select", "setChecked", "setUploadFile", "drag",
        "navigate", "goBack", "goForward", "submit",
    ]

    struct Fingerprint: Equatable, Sendable {
        var url: String
        var title: String
        var textLength: Int
        var nodeCount: Int
    }

    static func verdict(before: Fingerprint?, after: Fingerprint?) -> PostActionVerdict {
        guard let before, let after else { return .unknown }
        if before.url != after.url { return .navigated }
        if before.title != after.title
            || before.textLength != after.textLength
            || before.nodeCount != after.nodeCount {
            return .changed
        }
        return .unchanged
    }

    /// 登录表单提示（v0.8.25）：页面出现密码输入框时给模型明确的两条路——
    /// 请用户处理（Peek）或建议导入当前登录态（cookies 快照）。
    static func loginHint(hasPasswordField: Bool) -> String {
        guard hasPasswordField else { return "" }
        return "\n[hint] this page has a login form — if you need the user's session, call requestUserHelp (they can log in via Peek) or suggest importing cookies from the current profile (/cookies/seed). Do not type passwords yourself."
    }

    /// 追加到工具结果尾部的观察行（模型与轨迹都看得到）。
    static func annotation(_ verdict: PostActionVerdict) -> String {
        switch verdict {
        case .navigated:
            return "\n[verify] page navigated after this action"
        case .changed:
            return "\n[verify] page changed after this action"
        case .unchanged:
            return "\n[verify] page unchanged after this action — check whether it took effect"
        case .unknown:
            return ""
        }
    }
}
