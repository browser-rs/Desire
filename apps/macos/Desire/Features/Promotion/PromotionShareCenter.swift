import Combine
import SwiftUI

/// 产品内分享入口的展示状态（v0.8.2）：菜单栏/Help 触发，ContentView 挂 sheet。
@MainActor
final class PromotionShareCenter: ObservableObject {
    static let shared = PromotionShareCenter()
    @Published var isPresented = false
    private init() {}

    func present() { isPresented = true }
}
