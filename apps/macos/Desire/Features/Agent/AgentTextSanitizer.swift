import Foundation

/// 页面派生文本进**系统提示结构段**前的消毒（0.7.4 安全轮）。
/// Foundation-only（进 tests/run.sh）。
///
/// 注意与 page_context 围栏的分工：那整段是声明的数据区（带 UNTRUSTED
/// 围栏标记），不需要逐字符串消毒；这里管的是"页面文本混进结构段"的
/// 散点（窗口标题等）——换行能在段内伪造新条目/新段，尖括号能伪造
/// 标签边界，都必须在拼进 prompt 前压掉。
nonisolated enum AgentTextSanitizer {

    /// 压平换行（→空格）、尖括号换全角样的 ‹›、长度封顶。
    static func pageText(_ text: String, max: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
        return String(flat.prefix(max))
    }
}
