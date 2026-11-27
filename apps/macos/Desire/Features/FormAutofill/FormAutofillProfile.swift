import Foundation

/// 地址自动填充档案（v0.8.80）：加了 id / label，用于多档案保存与切换。
/// 旧数据是**不含 id/label** 的单档案 JSON——自定义解码保证能读进。
struct FormAutofillProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// 用户起的名字（"家"/"公司"）；空 = 用姓名显示。
    var label: String = ""
    var givenName: String = ""
    var familyName: String = ""
    var email: String = ""
    var phone: String = ""
    var organization: String = ""
    var streetAddress: String = ""
    var city: String = ""
    var state: String = ""
    var zipCode: String = ""
    var country: String = ""

    /// 显示名：label 优先，否则姓名，否则"未命名档案"。
    var displayName: String {
        if !label.isEmpty { return label }
        let full = fullName
        return full.isEmpty ? String(localized: "Unnamed profile") : full
    }

    var fullName: String {
        [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var summary: String {
        [fullName, email, [city, country].filter { !$0.isEmpty }.joined(separator: ", ")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        givenName = (try? c.decodeIfPresent(String.self, forKey: .givenName)) ?? ""
        familyName = (try? c.decodeIfPresent(String.self, forKey: .familyName)) ?? ""
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        phone = (try? c.decodeIfPresent(String.self, forKey: .phone)) ?? ""
        organization = (try? c.decodeIfPresent(String.self, forKey: .organization)) ?? ""
        streetAddress = (try? c.decodeIfPresent(String.self, forKey: .streetAddress)) ?? ""
        city = (try? c.decodeIfPresent(String.self, forKey: .city)) ?? ""
        state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        zipCode = (try? c.decodeIfPresent(String.self, forKey: .zipCode)) ?? ""
        country = (try? c.decodeIfPresent(String.self, forKey: .country)) ?? ""
    }
}
