import Foundation

/// 支付卡元数据（v0.8.82）：**卡号不在这个结构里**——只存 Keychain，
/// 这里保留品牌/末四位/有效期用于列表与填充前确认；CVV 永不落盘。
nonisolated struct PaymentCard: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var cardholder: String
    var brand: String
    var last4: String
    var expiryMonth: Int
    var expiryYear: Int
    var createdAt: Date

    var displayName: String {
        label.isEmpty ? "\(brand) · \(last4)" : label
    }

    var summary: String {
        String(format: "%@ ···· %@ · %02d/%02d", brand, last4, expiryMonth, expiryYear % 100)
    }
}

/// 卡号校验/品牌（纯逻辑，进 harness）。不做联网 BIN 查询。
nonisolated enum PaymentCardNumber {
    static func digits(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    static func luhnValid(_ raw: String) -> Bool {
        let digits = digits(raw)
        guard digits.count >= 12, digits.count <= 19 else { return false }
        var sum = 0
        for (offset, char) in digits.reversed().enumerated() {
            guard var value = char.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    static func brand(_ raw: String) -> String {
        let digits = digits(raw)
        if digits.hasPrefix("4") { return "Visa" }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "Amex" }
        if let firstTwo = Int(digits.prefix(2)), (51...55).contains(firstTwo) { return "Mastercard" }
        if let firstFour = Int(digits.prefix(4)), (2221...2720).contains(firstFour) {
            return "Mastercard"
        }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") { return "Discover" }
        if digits.hasPrefix("35") { return "JCB" }
        if digits.hasPrefix("62") { return "UnionPay" }
        return "Card"
    }

    static func last4(_ raw: String) -> String {
        String(digits(raw).suffix(4))
    }

    static func expiryValid(month: Int, year: Int, now: Date = Date()) -> Bool {
        guard (1...12).contains(month) else { return false }
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        let fullYear = year < 100 ? 2000 + year : year
        guard fullYear >= currentYear, fullYear <= currentYear + 30 else { return false }
        return fullYear > currentYear || month >= currentMonth
    }
}
