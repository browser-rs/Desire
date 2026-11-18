import Foundation

/// 双语翻译的**批切分**（v0.8.62 批 1 全页翻译，Foundation-only 进 tests/run.sh）。
///
/// 全收集方案：一次收集页面全部可读块（上限 300），宿主按"块数 + 字符数"
/// 双闸切成小批逐批送模型——此前固定 8 块一切，长段落的一批可能远超模型
/// 单次舒适输入；现在批内累计字符超 `maxBatchChars` 即提前切批。
nonisolated enum TranslationBatching {

    struct Item {
        let id: String
        let text: String
    }

    static let maxBatchCount = 8
    static let maxBatchChars = 12_000

    /// 把已收集的块切成翻译批次。空块不产生批次；单块超 `maxBatchChars`
    /// 时自成一批（不截断——collect 侧已有单块 1200 字符上限兜底）。
    static func batches(_ items: [Item], maxCount: Int = maxBatchCount,
                        maxChars: Int = maxBatchChars) -> [[Item]] {
        var batches: [[Item]] = []
        var current: [Item] = []
        var chars = 0
        for item in items {
            let len = item.text.count
            if !current.isEmpty && (current.count >= maxCount || chars + len > maxChars) {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append(item)
            chars += len
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
