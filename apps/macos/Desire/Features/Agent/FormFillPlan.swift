import Foundation

/// 表单作业纯逻辑（v0.8.4 P2）：字段映射 → pageAction 步骤 DSL。
/// Agent 工具 fillForm 用它把结构化字段转成 pageAction 可执行的步骤。
/// Foundation-only，进 harness。
nonisolated enum FormFillPlan {
    struct Field: Equatable {
        var selector: String
        var value: String
        var kind: Kind

        enum Kind: String, Codable {
            case text
            case select
            case checkbox
        }
    }

    /// 把字段列表转成 pageAction 步骤 JSON 字符串。
    /// text/textarea → fill；select → select；checkbox → click（勾选/取消）。
    static func steps(fields: [Field]) -> String? {
        guard !fields.isEmpty else { return nil }
        var steps: [[String: Any]] = []
        for field in fields {
            switch field.kind {
            case .text:
                steps.append(["fill": [field.selector: field.value]])
            case .select:
                steps.append(["select": [field.selector: field.value]])
            case .checkbox:
                // checkbox 勾选/取消由值决定：非空 = 勾选。
                if !field.value.isEmpty {
                    steps.append(["click": field.selector])
                }
            }
        }
        guard !steps.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: steps) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 从 HTML 表单自动检测字段选择器（executeJS 用；此处纯映射）。
    /// Agent 在页面上 executeJS 获取表单结构后，把检测结果传入此函数
    /// 生成 saveDPPAdapter 兼容的 views.actions 声明。
    static func detectFields(_ formHTML: String) -> [String] {
        // 常见表单元素选择器优先级（保守多候选）。
        let selectors = [
            "input[type='text']", "input[type='email']", "input[type='tel']",
            "input[type='url']", "input[type='number']", "input[type='search']",
            "input:not([type])", "textarea", "select",
            "[contenteditable='true']",
        ]
        return selectors
    }
}
