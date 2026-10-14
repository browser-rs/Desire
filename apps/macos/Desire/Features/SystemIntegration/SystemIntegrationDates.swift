import Foundation

/// OS 协作工具的日期解析与展示（纯逻辑，进 tests/run.sh）。
/// 提醒/日历工具只收**绝对时间**：三种写法（"yyyy-MM-dd HH:mm" /
/// "yyyy-MM-dd" / ISO8601）。相对说法（"明天九点"）由模型自己换算——
/// 端上不做自然语言解析，避免口径漂移。
nonisolated enum SystemIntegrationDates {

    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: text) { return iso }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 回执里的可读时间（本地时区）。
    static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
