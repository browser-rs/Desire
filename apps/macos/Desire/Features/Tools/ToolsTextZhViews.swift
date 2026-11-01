import AppKit
import SwiftUI

// 中文/时间工具视图（v0.8.33 批次三）：时区、简繁、拼音、中文排版。
// 逻辑在 TimeZoneCore / ZhTextCore。

private struct ZhToolField: View {
    let title: String
    @Binding var text: String
    var width: CGFloat = 220

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
        }
    }
}

// MARK: - 时区

private enum TimeZoneMode: String, CaseIterable, Identifiable {
    case now, custom
    var id: String { rawValue }
}

struct TimeZoneToolView: View {
    @State private var sourceID = TimeZone.current.identifier
    @State private var targetID = "UTC"
    @State private var mode: TimeZoneMode = .now
    @State private var date = Date()

    private var sourceZone: TimeZone { TimeZone(identifier: sourceID) ?? .gmt }
    private var targetZone: TimeZone { TimeZone(identifier: targetID) ?? .gmt }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                zonePicker(title: String(localized: "From"), selection: $sourceID)
                zonePicker(title: String(localized: "To"), selection: $targetID)
            }
            Picker("", selection: $mode) {
                Text(String(localized: "Now")).tag(TimeZoneMode.now)
                Text(String(localized: "Custom time")).tag(TimeZoneMode.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            if mode == .custom {
                DatePicker("", selection: $date,
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Text(String(localized: "The picked wall time is interpreted in the source zone."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if mode == .now {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    resultView(instant: context.date)
                }
            } else {
                resultView(instant: instantForPickedWallClock)
            }
        }
    }

    private func zonePicker(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(TimeZoneCore.identifiers, id: \.self) { identifier in
                    Text(identifier).tag(identifier)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 260)
        }
    }

    private var instantForPickedWallClock: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return TimeZoneCore.instant(wallClock: components, in: sourceZone)
    }

    @ViewBuilder
    private func resultView(instant: Date?) -> some View {
        if let instant {
            VStack(alignment: .leading, spacing: 2) {
                DataLine(label: String(localized: "Source"), value: TimeZoneCore.formatted(instant, in: sourceZone))
                DataLine(label: String(localized: "Target"), value: TimeZoneCore.formatted(instant, in: targetZone))
                DataLine(label: String(localized: "Source offset"),
                         value: "\(TimeZoneCore.offsetString(for: sourceZone, at: instant))"
                            + (sourceZone.isDaylightSavingTime(for: instant) ? " · DST" : ""))
                DataLine(label: String(localized: "Target offset"),
                         value: "\(TimeZoneCore.offsetString(for: targetZone, at: instant))"
                            + (targetZone.isDaylightSavingTime(for: instant) ? " · DST" : ""))
                let difference = TimeZoneCore.differenceHours(
                    from: sourceZone, to: targetZone, at: instant)
                DataLine(label: String(localized: "Difference"),
                         value: String(format: "%+.1f h", difference))
            }
        } else {
            ToolErrorText(text: String(localized: "That wall time does not exist in the source time zone (daylight-saving gap)."))
        }
    }
}

private struct DataLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 简繁

private enum ZhConvertDirection: String, CaseIterable, Identifiable {
    case toTraditional, toSimplified
    var id: String { rawValue }
}

struct ZhConvertToolView: View {
    @State private var direction: ZhConvertDirection = .toTraditional
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $direction) {
                Text(String(localized: "Simplified → Traditional")).tag(ZhConvertDirection.toTraditional)
                Text(String(localized: "Traditional → Simplified")).tag(ZhConvertDirection.toSimplified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            ToolEditor(title: String(localized: "Input"), text: $input, height: 120)
            Button(String(localized: "Convert")) { convert() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(input.isEmpty)
            ToolOutput(text: output)
            Text(String(localized: "Conversion is character-level; check proper names and one-to-many cases."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func convert() {
        switch direction {
        case .toTraditional:
            output = ZhTextCore.simplifiedToTraditional(input)
        case .toSimplified:
            output = ZhTextCore.traditionalToSimplified(input)
        }
    }
}

// MARK: - 拼音

struct PinyinToolView: View {
    @State private var style: ZhTextCore.PinyinStyle = .toneMarks
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $style) {
                ForEach(ZhTextCore.PinyinStyle.allCases) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            ToolEditor(title: String(localized: "Input"), text: $input, height: 100)
            Button(String(localized: "Convert")) {
                output = ZhTextCore.pinyin(input, style: style)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(input.isEmpty)
            ToolOutput(text: output)
        }
    }
}

// MARK: - 中文排版

struct ZhTypographyToolView: View {
    @State private var input = ""
    @State private var output = ""
    @State private var spacing = true
    @State private var removeCJKSpace = true
    @State private var punctuation = true
    @State private var trimTrailing = true
    @State private var collapseBlankLines = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ToolToggle(title: String(localized: "CJK/Latin spacing"), isOn: $spacing)
                ToolToggle(title: String(localized: "Remove spaces between CJK"),
                           isOn: $removeCJKSpace)
                ToolToggle(title: String(localized: "Full-width punctuation"),
                           isOn: $punctuation)
                ToolToggle(title: String(localized: "Trim trailing spaces"),
                           isOn: $trimTrailing)
                ToolToggle(title: String(localized: "Collapse blank lines"),
                           isOn: $collapseBlankLines)
            }
            ToolEditor(title: String(localized: "Input"), text: $input, height: 140)
            Button(String(localized: "Clean Up")) {
                var options: ZhTextCore.TypographyOptions = []
                if spacing { options.insert(.cjkLatinSpacing) }
                if removeCJKSpace { options.insert(.removeCJKSpace) }
                if punctuation { options.insert(.fullWidthPunctuation) }
                if trimTrailing { options.insert(.trimTrailing) }
                if collapseBlankLines { options.insert(.collapseBlankLines) }
                output = ZhTextCore.typography(input, options: options)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(input.isEmpty)
            ToolOutput(text: output)
        }
    }
}
