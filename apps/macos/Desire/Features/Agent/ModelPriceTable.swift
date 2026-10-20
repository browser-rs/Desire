import Foundation

/// 模型单价表的导入/导出（v0.7.26）：纯逻辑（Foundation-only，进 harness）。
/// 规范形状 = `{"modelId": {"inputPerMTok": n, "outputPerMTok": n}}`（与内部
/// Codable 一致，往返无损）；导入也接受 `input`/`output`（或 `in`/`out`）简写：
/// 手写 JSON 时不必记内部字段名。负值钳到 0；不认识/非对象条目跳过。
nonisolated enum ModelPriceTable {
    /// 导出用**桥同款形状** `{model: {input, output}}`（`/ai/prices` 的 models
    /// 参数就是它）——同一份文件 UI 导入与桥 POST 都能直接用。
    static func exportJSON(_ prices: [String: ModelPrice]) -> String {
        var table: [String: [String: Double]] = [:]
        for (model, price) in prices {
            guard price.isKnown else { continue }
            table[model] = ["input": price.inputPerMTok, "output": price.outputPerMTok]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: table,
                options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 非法 JSON 返回 nil；解析结果为空也返回 nil（避免"导入成功但什么都没变"）。
    static func parseJSON(_ text: String) -> [String: ModelPrice]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: ModelPrice] = [:]
        for (rawModel, value) in object {
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let fields = value as? [String: Any] else { continue }
            func number(_ keys: [String]) -> Double {
                for key in keys {
                    if let value = fields[key] as? Double { return value }
                    if let value = fields[key] as? Int { return Double(value) }
                    if let value = fields[key] as? String, let parsed = Double(value) { return parsed }
                }
                return 0
            }
            let input = max(0, number(["inputPerMTok", "input", "in"]))
            let output = max(0, number(["outputPerMTok", "output", "out"]))
            out[model] = ModelPrice(inputPerMTok: input, outputPerMTok: output)
        }
        return out.isEmpty ? nil : out
    }

    /// 合并：导入项覆盖同名键，未提及的保留（导入是"补/改"，不是"整表替换"）。
    static func merge(existing: [String: ModelPrice],
                      imported: [String: ModelPrice]) -> [String: ModelPrice] {
        var merged = existing
        for (model, price) in imported {
            merged[model] = price
        }
        return merged
    }
}
