import Foundation

/// Tab-to-Search 关键字匹配核（v0.8.6）：输入文本**恰好**是某个引擎的可用
/// 关键字时返回它（内置引擎 id / 自定义引擎名 / 自定义 keyword，大小写不
/// 敏感），否则 nil。带空格或空串不算——Tab 补全只发生在"刚打完关键字"
/// 那一刻。Foundation-only，进 tests/run.sh。
nonisolated enum TabToSearch {
    static func keyword(in text: String,
                        customEngines: [(name: String, keyword: String?)]) -> String? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !word.contains(" ") else { return nil }
        for engine in SearchEngine.allCases where word == engine.rawValue.lowercased() {
            return engine.rawValue.lowercased()
        }
        for engine in customEngines {
            if word == engine.name.lowercased() { return engine.name.lowercased() }
            if let kw = engine.keyword?.lowercased(), !kw.isEmpty, word == kw { return kw }
        }
        return nil
    }
}
