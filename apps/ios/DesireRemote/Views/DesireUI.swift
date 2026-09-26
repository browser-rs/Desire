import SwiftUI

/// 全站视觉 token 与基础组件（UI 重做后统一从这里取，不再各页各写一套）。
///
/// 设计取向：贴近 iOS 原生 —— 系统色 / 系统字体 / `insetGrouped` 分组观感，
/// 不做自定义画风的"网页感"卡片。所有页面共用同一套圆角、间距、图标徽章。
enum DesireUI {
    /// 朱砂品牌色（与 Mac 端「欲」字印章一致）。深色模式提亮一档。
    static let brand = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.36, blue: 0.20, alpha: 1)
            : UIColor(red: 0.75, green: 0.23, blue: 0.10, alpha: 1)
    })

    /// 统一圆角：卡片 14、行内小元素 10。
    static let cardCorner: CGFloat = 14
    static let chipCorner: CGFloat = 10

    /// 页面内容左右边距。
    static let pagePadding: CGFloat = 16

    /// 卡片内边距。
    static let cardPadding: CGFloat = 14

    /// 图标徽章尺寸（列表行左侧）。
    static let badgeSize: CGFloat = 32

    /// 分组卡片底色。
    static var cardFill: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    /// 分组之间的底色（页面背景）。
    static var pageFill: Color { Color(uiColor: .systemGroupedBackground) }

    /// 次级文本色（数值、说明）。
    static var subtle: Color { .secondary }
}

// MARK: - 容器

extension View {
    /// 统一卡片容器：圆角 + 分组底色 + 无阴影（iOS 原生分组观感）。
    func desireCard(padding: CGFloat = DesireUI.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                    .fill(DesireUI.cardFill)
            )
    }

    /// 可点击整行的卡片（带内容形状，保证空白处也能点）。
    func desireTappableCard(padding: CGFloat = DesireUI.cardPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous)
                    .fill(DesireUI.cardFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesireUI.cardCorner, style: .continuous))
    }

    /// 页面级外边距。
    func desirePagePadding() -> some View {
        self.padding(.horizontal, DesireUI.pagePadding)
    }
}

// MARK: - 图标徽章

/// 统一样式的图标徽章（列表行左侧 / 磁贴图标），替代各处零散的
/// `Circle().fill(...)` 与 `RoundedRectangle().fill(...)` 混用。
struct DesireIconBadge: View {
    let icon: String
    var tint: Color = DesireUI.brand
    var size: CGFloat = DesireUI.badgeSize
    /// 实心（白图标）还是淡底着色图标。
    var filled: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 列表行

/// 导航行：徽章 + 标题/副标题 + 尾部数值 + chevron。
/// 全站「进得去」的行都用它，保证信息密度与对齐一致。
struct DesireNavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = DesireUI.brand
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            DesireIconBadge(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 数值行：左标题右值（`LabeledContent` 的统一外观）。
struct DesireValueRow: View {
    let title: String
    let value: String
    var valueColor: Color = .secondary
    var mono: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 14, design: .monospaced) : .system(size: 14))
                .foregroundStyle(valueColor)
        }
    }
}

/// 导航行 → 目标页（整行可点，带 chevron）。放进 `DesireSection` 里逐个排列。
struct DesireNavLink<Destination: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tint: Color = DesireUI.brand
    var showsChevron: Bool = true
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            DesireNavRow(icon: icon, title: title, subtitle: subtitle,
                         value: value, tint: tint, showsChevron: showsChevron)
                .padding(.horizontal, DesireUI.cardPadding)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 统计方块

/// 统计小方块（Agent 用量/状态概览用）。
struct DesireStatTile: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = DesireUI.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // 轻填充：这些瓦片是嵌在卡片里的，用卡片同色会糊成一块
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

// MARK: - 分区标题

struct DesireSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 空状态

/// 统一空状态（图标 + 标题 + 说明 + 可选操作按钮）。
struct DesireEmptyState<Action: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 14) {
            DesireIconBadge(icon: icon, tint: .secondary, size: 56)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension DesireEmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

// MARK: - 区块包装

/// 带标题的卡片区块（页面里成组出现的内容都用它，避免"裸卡片乱堆"）。
struct DesireSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesireSectionHeader(title: title, subtitle: subtitle)
            VStack(spacing: 0) {
                content()
            }
            .desireCard(padding: 0)
        }
    }
}

/// 卡片内的分隔线（缩进对齐文本，不含图标列）。
struct DesireRowDivider: View {
    var leading: CGFloat = DesireUI.cardPadding

    var body: some View {
        Divider()
            .padding(.leading, leading)
    }
}

// MARK: - 格式化

extension DesireUI {
    /// 大数字缩写（与桌面 `AgentUsage.formatTokens` 同口径）。
    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// 毫秒 → 人读（<1s 给整数毫秒，否则给秒）。
    static func formatMs(_ ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms.rounded()))ms" }
        return String(format: "%.1fs", ms / 1000)
    }

    /// 金额（nil = 有未定价的调用，总额不完整 → 返回 nil 由调用方决定怎么显示）。
    static func formatUSD(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "$%.4f", value)
    }

    /// 秒 → 人读时长。
    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f秒", seconds) }
        if seconds < 3600 { return String(format: "%.0f分", seconds / 60) }
        return String(format: "%.1f小时", seconds / 3600)
    }
}
