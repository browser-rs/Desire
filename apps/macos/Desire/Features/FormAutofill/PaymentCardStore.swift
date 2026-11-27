import Combine
import Foundation
import Security

/// 支付卡保险库（v0.8.82，本机 only）：
/// - 卡号存 Keychain（account `payment-card-<uuid>`），元数据存 DiskStore；
/// - **CVV 没有字段、不读取、不写入**；
/// - 只在用户点“填充卡”时读卡号，列表/设置不读机密；
/// - 不进同步、不做导出（v1 边界，设计评审记录在 docs）。
@MainActor
final class PaymentCardStore: ObservableObject {
    static let shared = PaymentCardStore()
    @Published private(set) var cards: [PaymentCard] = []

    private let key = "paymentCardsMeta"
    private let service = "me.siwi.Desire"

    private init() {
        cards = DiskStore.load([PaymentCard].self, key: key) ?? []
    }

    func add(label: String, cardholder: String, number: String,
             expiryMonth: Int, expiryYear: Int) throws -> PaymentCard {
        let raw = PaymentCardNumber.digits(number)
        guard PaymentCardNumber.luhnValid(raw) else {
            throw CardError.invalidNumber
        }
        guard !cardholder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CardError.missingName
        }
        guard PaymentCardNumber.expiryValid(month: expiryMonth, year: expiryYear) else {
            throw CardError.invalidExpiry
        }
        let card = PaymentCard(
            id: UUID(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            cardholder: cardholder.trimmingCharacters(in: .whitespacesAndNewlines),
            brand: PaymentCardNumber.brand(raw),
            last4: PaymentCardNumber.last4(raw),
            expiryMonth: expiryMonth,
            expiryYear: expiryYear < 100 ? 2000 + expiryYear : expiryYear,
            createdAt: Date())
        let status = KeychainService.write(raw, account: account(card.id), service: service)
        guard status == errSecSuccess else { throw CardError.keychain(status) }
        cards.insert(card, at: 0)
        save()
        return card
    }

    func delete(_ card: PaymentCard) {
        KeychainService.delete(account: account(card.id), service: service)
        cards.removeAll { $0.id == card.id }
        save()
    }

    /// 显式填充动作才读卡号（一次一条）。
    func number(for card: PaymentCard, interactive: Bool = true) -> String? {
        KeychainService.readString(account: account(card.id), service: service,
                                   interactive: interactive)
    }

    /// dom-tools.js 的 `__desireFillCard(card)` 页面脚本；读不到卡号返回 nil。
    func fillScript(for cardID: UUID) -> String? {
        guard let card = cards.first(where: { $0.id == cardID }),
              let number = number(for: card) else { return nil }
        let exp = String(format: "%02d/%02d", card.expiryMonth, card.expiryYear % 100)
        let payload = "{number:\(JSString.literal(number)),holder:\(JSString.literal(card.cardholder)),"
            + "exp:\(JSString.literal(exp)),month:\(JSString.literal(String(format: "%02d", card.expiryMonth))),"
            + "year:\(JSString.literal(String(format: "%02d", card.expiryYear % 100)))}"
        return """
        (function() {
            var card = \(payload);
            if (typeof __desireFillCard === 'function') {
                __desireFillCard(card);
            }
        })();
        """
    }

    private func account(_ id: UUID) -> String { "payment-card-\(id.uuidString)" }

    private func save() {
        DiskStore.save(cards, key: key)
    }

    enum CardError: LocalizedError {
        case invalidNumber
        case missingName
        case invalidExpiry
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidNumber: String(localized: "Card number is invalid.")
            case .missingName: String(localized: "Cardholder name is required.")
            case .invalidExpiry: String(localized: "Expiry date is invalid or already past.")
            case .keychain: String(localized: "Could not save the card number to the keychain.")
            }
        }
    }
}
