import AppKit
import SwiftUI

// MARK: - Settings Background

/// Wraps the page content with a soft, consistent background that matches
/// the new tab page's surface — so navigating between Settings pages doesn't
/// produce a visual jump.
struct SettingsPageBackground: ViewModifier {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(
                        colors: [
                            appAccent.opacity(0.05),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                }
                .ignoresSafeArea()
            )
    }
}

extension View {
    func settingsPageBackground() -> some View {
        modifier(SettingsPageBackground())
    }
}

// MARK: - Settings Container

/// Settings 组件的 title/subtitle 以 String 传入(调用点几乎全是字面
/// 量),渲染时按该串作为 key 查字符串目录。目录缺失或传入的是运行时
/// 拼接的动态串(statusLine 等)时原样返回——查表失败无损。
func localizedSettingText(_ value: String) -> String {
    String(localized: String.LocalizationValue(value))
}

/// Centers a column of settings sections and gives them a consistent
/// max width, padding, and scroll behaviour.
struct SettingsContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Settings Section Card

/// A grouped card of related settings rows. Replaces the system `Form`
/// grouped style with a hand-tuned look that matches the rest of the app.
struct SettingsSection<Content: View>: View {
    let title: String?
    let subtitle: String?
    let icon: String?
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        icon: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || subtitle != nil {
                header
                    .padding(.bottom, 10)
            }

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(localizedSettingText(title))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                if let subtitle {
                    Text(localizedSettingText(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Settings Row

/// A horizontal row inside a `SettingsSection` with optional leading icon,
/// title, subtitle, and a trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder let trailing: Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(localizedSettingText(title))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(localizedSettingText(subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

// MARK: - Toggle Row

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    @Binding var isOn: Bool

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Picker Row

struct SettingsPickerRow<Item: Hashable>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    @Binding var selection: Item
    let options: [Item]
    let label: (Item) -> String

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        selection: Binding<Item>,
        options: [Item],
        label: @escaping (Item) -> String
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { item in
                    Text(localizedSettingText(label(item))).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

// MARK: - Action Row

struct SettingsActionRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let buttonTitle: String
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    init(
        _ title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        buttonTitle: String,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.buttonTitle = buttonTitle
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        SettingsRow(title, subtitle: subtitle, systemImage: systemImage) {
            SettingsCapsuleButton(
                buttonTitle,
                style: isDestructive ? .destructive : .prominent,
                isDisabled: isDisabled,
                action: action
            )
        }
    }
}

// MARK: - Capsule Button

/// 设置里唯一的胶囊按钮规格（12pt medium / 水平 12 垂直 5 / 圆角胶囊）。
///
/// 此前各行自己手搓按钮底色，同一个页面里出现过 5 种近似色（`.tint` 0.18、
/// accent 0.18、secondary 0.18 / 0.10、accent 0.14），看起来像不同人做的。
/// 需要"次要"按钮就用 `.secondary`，需要危险操作用 `.destructive`。
struct SettingsCapsuleButton: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color

    enum Style {
        case prominent
        case secondary
        case destructive
    }

    let title: String
    var systemImage: String? = nil
    var style: Style = .prominent
    var isDisabled: Bool = false
    let action: () -> Void

    private var foreground: Color {
        switch style {
        case .prominent: appAccent
        case .secondary: .primary
        case .destructive: .red
        }
    }

    private var fill: Color {
        switch style {
        case .prominent: appAccent.opacity(0.14)
        case .secondary: Color.secondary.opacity(0.10)
        case .destructive: Color.red.opacity(0.12)
        }
    }

    init(
        _ title: String,
        systemImage: String? = nil,
        style: Style = .prominent,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(localizedSettingText(title))
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .foregroundStyle(foreground)
            .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    enum Kind {
        case success
        case warning
        case error
        case info
        case neutral

        var color: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            case .info: .accentColor
            case .neutral: .secondary
            }
        }

        var icon: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .info: "info.circle.fill"
            case .neutral: "circle.fill"
            }
        }
    }

    let text: String
    let kind: Kind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(kind.color.opacity(0.12))
        )
    }
}

// MARK: - Provider Card

/// Used by the AI settings to pick between provider kinds.
struct ProviderCard: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : appAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isSelected
                                  ? appAccent
                                  : appAccent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? appAccent : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? appAccent.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1.0 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? appAccent.opacity(0.5)
                            : Color.secondary.opacity(0.12),
                        lineWidth: isSelected ? 1.0 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

// MARK: - Text Field Style

/// Consistent rounded text field for inline settings.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var width: CGFloat? = nil
    /// 安全输入时在框内右侧显示"眼睛"切换明文/密文
    var secureToggle: Bool = false

    @State private var revealSecure = false

    var body: some View {
        Group {
            if isSecure && !revealSecure {
                SecureField(localizedSettingText(placeholder), text: $text)
            } else {
                TextField(localizedSettingText(placeholder), text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .overlay(alignment: .trailing) {
            if secureToggle {
                Button {
                    revealSecure.toggle()
                } label: {
                    Image(systemName: revealSecure ? "eye.slash" : "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
        }
    }
}

// MARK: - Form Metrics

/// 表单类排布的共享尺寸（标签列宽 + 配套的分隔线缩进）。
enum SettingsMetrics {
    /// 表单标签列宽度
    static let fieldLabelWidth: CGFloat = 92
    /// 表单行分隔线的左缩进 = 卡片内边距 14 + 标签列 92 + 行内间距 12
    static let fieldDividerLeading: CGFloat = 118
}

// MARK: - Form Field Row

/// 表单行的统一排布：**固定宽度的标签列 + 撑满剩余宽度的控件**。
///
/// `SettingsRow` 是"标题在左、控件贴最右"的排布——适合开关/按钮行；但用在
/// 表单（用户名 / 密码 / 服务器）上会出现"标签和输入框之间一大片空白"，输入框
/// 还被挤成固定小宽度、各页宽度互不相同（240 / 200 / 100）。表单一律用本行，
/// 标签列对齐、控件撑满，整页宽度自然统一。
struct SettingsFieldRow<Field: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let field: Field

    init(_ title: String, subtitle: String? = nil, @ViewBuilder field: () -> Field) {
        self.title = title
        self.subtitle = subtitle
        self.field = field()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(localizedSettingText(title))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: SettingsMetrics.fieldLabelWidth, alignment: .leading)
                // 与输入框内首行文字基线对齐（输入框自带 6pt 内边距）
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                field
                if let subtitle {
                    Text(localizedSettingText(subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Submit Button

/// 表单提交按钮：整行宽的实心强调色按钮。
///
/// 设置页其它地方一律用 `SettingsCapsuleButton`（浅底胶囊），整页都是浅色小控件
/// 时**没有视觉焦点**；提交是页面里唯一的主动作，用实心按钮把视线收在一处。
struct SettingsSubmitButton: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color

    let title: String
    var isDisabled: Bool = false
    var isWorking: Bool = false
    let action: () -> Void

    init(
        _ title: String,
        isDisabled: Bool = false,
        isWorking: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isDisabled = isDisabled
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(localizedSettingText(title))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appAccent.opacity(isDisabled ? 0.35 : 0.92))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - Row Divider

/// Use this between `SettingsRow` children of a section to get a subtle
/// divider that doesn't cross the rounded card corners.
struct SettingsRowDivider: View {
    /// 左侧缩进。默认 14（贴齐卡片内边距）；表单行用
    /// `SettingsMetrics.fieldDividerLeading`，分隔线才会从输入框左边缘起。
    var leading: CGFloat = 14

    var body: some View {
        Divider()
            .padding(.leading, leading)
    }
}
