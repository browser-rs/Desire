import Foundation

/// 占位文本生成——纯逻辑。
nonisolated enum LoremCore {
    private static let enWords = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
        "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
        "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris", "nisi", "aliquip", "ex", "ea", "commodo",
        "consequat", "duis", "aute", "irure", "in", "reprehenderit", "voluptate",
        "velit", "esse", "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint",
        "occaecat", "cupidatat", "non", "proident", "sunt", "culpa", "qui", "officia",
        "deserunt", "mollit", "anim", "id", "est", "laborum",
    ]
    private static let zhWords = [
        "在设计", "系统", "界面", "交互", "用户", "数据", "流程", "结构", "功能",
        "体验", "反馈", "优化", "方案", "文档", "规范", "协作", "测试", "部署",
        "性能", "安全", "需求", "分析", "设计", "开发", "迭代", "产品", "效率",
        "质量", "成本", "资源", "配置", "管理", "服务", "平台", "框架", "模块",
        "组件", "接口", "协议", "标准", "模式", "策略", "目标", "结果", "过程",
    ]

    static func paragraphs(count: Int = 3, chinese: Bool = false) -> [String] {
        let words = chinese ? zhWords : enWords
        var generator = SystemRandomNumberGenerator()
        return (0..<max(1, count)).map { _ in
            let sentenceCount = Int.random(in: 3...5, using: &generator)
            let sentences = (0..<sentenceCount).map { _ -> String in
                let wordCount = Int.random(in: 8...18, using: &generator)
                let words = (0..<wordCount).map { _ in words.randomElement(using: &generator)! }
                let sentence = words.joined(separator: chinese ? "" : " ")
                return chinese ? sentence + "。" : sentence.capitalized + "."
            }
            return sentences.joined(separator: chinese ? "" : " ")
        }
    }
}
