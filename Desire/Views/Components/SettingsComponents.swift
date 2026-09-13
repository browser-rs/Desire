import AppKit
import SwiftUI

// MARK: - Settings Background

/// Wraps the page content with a soft, consistent background that matches
/// the new tab page's surface — so navigating between Settings pages doesn't
/// produce a visual jump.
struct SettingsPageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.05),
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
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                if let subtitle {
                    Text(subtitle)
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
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
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
                    Text(label(item)).tag(item)
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
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isDestructive
                                  ? Color.red.opacity(0.12)
                                  : Color.accentColor.opacity(0.14))
                    )
                    .foregroundStyle(isDestructive ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
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
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isSelected
                                  ? Color.accentColor
                                  : Color.accentColor.opacity(0.12))
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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.08)
                          : Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1.0 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.5)
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

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
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
    }
}

// MARK: - Row Divider

/// Use this between `SettingsRow` children of a section to get a subtle
/// divider that doesn't cross the rounded card corners.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 14)
    }
}
