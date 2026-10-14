import Foundation

/// 运营领域（专项支持，2026-10-14）：推广 / 自媒体运营 / 电商运营。
/// 目标、账号、经验都带域标签——diff 面板按域区分，digest 给 Agent 标注，
/// 内置技能（media-operations / ecommerce-operations / promotion）各管一域。
enum OperationDomain: String, Codable, CaseIterable, Hashable {
    case promotion
    case media
    case ecommerce

    nonisolated var label: String {
        switch self {
        case .promotion: return String(localized: "Promotion")
        case .media: return String(localized: "Creator")
        case .ecommerce: return String(localized: "E-commerce")
        }
    }
}
