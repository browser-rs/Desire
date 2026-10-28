import Foundation

/// PDF 选区复制的段落重排（v0.8.18 基础件 2）：PDF 文本层按视觉行断行，
/// 直接复制每行一个 \n；段落化 = 单换行折成空格、双换行（真段落边界）
/// 保留、行尾连字符并词。Foundation-only，进 tests/run.sh。
nonisolated enum TextParagraphize {

    nonisolated static func paragraphized(_ text: String) -> String {
        // 行尾连字符合并（latin 断词："inter-\national" → "international"）。
        var joined = text.replacingOccurrences(of: "-\n", with: "")
        // 双换行 = 真段落边界 → 占位符保护。
        joined = joined.replacingOccurrences(of: "\n\n", with: "\u{2029}")
        // 单换行（视觉断行）→ 空格。
        joined = joined.replacingOccurrences(of: "\n", with: " ")
        // 段落边界还原；压掉折行产生的连续空格。
        joined = joined.replacingOccurrences(of: "\u{2029}", with: "\n\n")
        var collapsed = ""
        var lastWasSpace = false
        for ch in joined {
            let isSpace = ch == " "
            if isSpace && lastWasSpace { continue }
            collapsed.append(ch)
            lastWasSpace = isSpace
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
