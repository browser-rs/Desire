import AppKit
import SwiftUI

// 编码与正则工具（v0.8.27）：HTML 实体 / Unicode 转义 / Hex / 正则测试。
// 纯逻辑在 ToolboxCore 与 RegexToolCore（harness 覆盖）。

/// 通用"编码/解码"面板：HTML / Unicode / Hex 共用。
struct CodecToolView: View {
    let inputTitle: String
    let placeholder: String
    let encode: (String) -> String
    let decode: (String) -> Result<String, ToolboxError>

    private enum Mode: String, CaseIterable {
        case encode, decode
    }

    @State private var text = ""
    @State private var mode: Mode = .encode

    private var result: Result<String, ToolboxError> {
        switch mode {
        case .encode: return .success(text.isEmpty ? "" : encode(text))
        case .decode:
            guard !text.isEmpty else { return .success("") }
            return decode(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text(String(localized: "Encode")).tag(Mode.encode)
                Text(String(localized: "Decode")).tag(Mode.decode)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            ToolEditor(title: inputTitle, text: $text, height: 130, placeholder: placeholder)
            switch result {
            case .success(let output):
                ToolOutput(text: output)
            case .failure(let error):
                ToolErrorText(text: error.message)
            }
        }
    }
}

struct HTMLCodecToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "HTML"),
            placeholder: "<div class=\"note\">…",
            encode: { ToolboxCore.htmlEncode($0) },
            decode: { .success(ToolboxCore.htmlDecode($0)) })
    }
}

struct UnicodeCodecToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "Text"),
            placeholder: String(localized: "Type or paste text…"),
            encode: { ToolboxCore.unicodeEscape($0) },
            decode: { .success(ToolboxCore.unicodeUnescape($0)) })
    }
}

struct HexCodecToolView: View {
    var body: some View {
        CodecToolView(
            inputTitle: String(localized: "Text or hex"),
            placeholder: "68 65 6c 6c 6f",
            encode: { ToolboxCore.hexEncode($0) },
            decode: { ToolboxCore.hexDecode($0) })
    }
}

// MARK: - 正则测试

struct RegexToolView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @State private var pattern = "(\\d{4})-(\\d{2})-(\\d{2})"
    @State private var text = "Dates: 2026-10-30 and 2025-01-02."
    @State private var ignoreCase = false
    @State private var multiline = false

    private var matches: [RegexMatchResult] {
        if case .success(let values) = RegexToolCore.matches(
            pattern: pattern, in: text,
            caseInsensitive: ignoreCase, multiline: multiline) {
            return values
        }
        return []
    }

    private var error: String? {
        if case .failure(let failure) = RegexToolCore.matches(
            pattern: pattern, in: text,
            caseInsensitive: ignoreCase, multiline: multiline) {
            return failure.message
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(String(localized: "Pattern"), text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                ToolToggle(title: String(localized: "Ignore case"), isOn: $ignoreCase)
                ToolToggle(title: String(localized: "Multiline"), isOn: $multiline)
            }
            ToolEditor(title: String(localized: "Test text"), text: $text, height: 120,
                       placeholder: String(localized: "Type or paste text…"))
            if let error {
                ToolErrorText(text: error)
            } else {
                HStack(spacing: 6) {
                    Text(String(localized: "\(matches.count) match(es)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(appAccent)
                    if matches.count >= RegexToolCore.maxMatches {
                        Text(String(localized: "capped"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(matches.prefix(100).enumerated()), id: \.offset) { index, match in
                            HStack(alignment: .top, spacing: 8) {
                                Text("#\(index + 1)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(match.text.isEmpty ? String(localized: "(empty)") : match.text)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                    if match.groups.count > 1 {
                                        Text(match.groups.dropFirst().map { $0.isEmpty ? "–" : $0 }
                                            .joined(separator: " · "))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }
}
