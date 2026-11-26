import Foundation

/// **下载规则的表单投影**（v0.8.79 批 3，Foundation-only 进 tests/run.sh）。
///
/// DPP Studio 的下载规则有两个入口：字段表单与 JSON 编辑。**JSON 是唯一真相**——
/// 表单只是受控字段的读写视图，切换/保存时都经过这里的同一套规则：
///
/// - `draft(from:)`：规则 → 表单（数字以字符串呈现，空 = 用默认值）；
/// - `rules(from:preserving:)`：表单 → 规则（**保留**实测画像、修订史与打磨记录——
///   用户在 Studio 里改一个连接数，不该把站点学到的速度证据清掉）；
/// - `parse(json:)` / `json(_:)`：JSON 入口的往返；
/// - `validate(_:)`：与 `saveDPPAdapter` 共用的同一套校验（引擎/每页数/detail/排除正则）。
///
/// 规则段是顶层类型：嵌在 extension 里的类型会被推成主 actor 隔离（见
/// `DPPAdapter+Download.swift` 的说明）。
nonisolated struct DPPDownloadRulesDraft: Equatable {
    /// `regex:<pattern>` 或 `selector:<css>@<attr>`；空 = 没写（保存会报错）。
    var detail = ""
    /// "" = 按命中数；one / many。
    var perPage = ""
    /// "" = auto（交给研判）；parallel / ffmpeg / builtin。
    var engine = ""
    /// 数字以字符串呈现：空 = 用默认值。
    var connections = ""
    var tokenMinutes = ""
    var exclude: [String] = []
}

nonisolated enum DPPDownloadRulesEditing {

    // MARK: - 表单 ↔ 规则

    static func draft(from rules: DPPDownloadRules?) -> DPPDownloadRulesDraft {
        var draft = DPPDownloadRulesDraft()
        guard let rules else { return draft }
        draft.detail = rules.detail ?? ""
        draft.perPage = rules.perPageRule?.rawValue ?? ""
        draft.engine = rules.enginePreference?.rawValue ?? ""
        draft.connections = rules.connections.map(String.init) ?? ""
        draft.tokenMinutes = rules.tokenMinutes.map(String.init) ?? ""
        draft.exclude = rules.exclude ?? []
        return draft
    }

    /// 表单 → 规则。`preserving` 是编辑前的规则（实测画像/修订史/`listView` 等
    /// 表单不暴露的字段原样保留）。返回的 `errors` 非空时不应当落盘。
    static func rules(from draft: DPPDownloadRulesDraft,
                      preserving existing: DPPDownloadRules? = nil) -> (rules: DPPDownloadRules, errors: [String]) {
        var rules = existing ?? DPPDownloadRules()
        var errors: [String] = []

        let detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        rules.detail = detail.isEmpty ? nil : detail

        let perPage = draft.perPage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rules.perPage = perPage.isEmpty ? nil : perPage

        let engine = draft.engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rules.engine = engine.isEmpty ? nil : engine

        let connections = draft.connections.trimmingCharacters(in: .whitespacesAndNewlines)
        if connections.isEmpty {
            rules.connections = nil
        } else if let value = Int(connections) {
            rules.connections = max(DPPDownloadRules.minConnections, min(64, value))
        } else {
            errors.append("download.connections must be a whole number")
        }

        let tokenMinutes = draft.tokenMinutes.trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenMinutes.isEmpty {
            rules.tokenMinutes = nil
        } else if let value = Int(tokenMinutes) {
            rules.tokenMinutes = max(DPPDownloadRules.minTokenMinutes, min(24 * 60, value))
        } else {
            errors.append("download.tokenMinutes must be a whole number")
        }

        let exclude = draft.exclude
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        rules.exclude = exclude.isEmpty ? nil : exclude

        errors += validate(rules)
        return (rules, errors)
    }

    // MARK: - JSON

    static func json(_ rules: DPPDownloadRules) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rules),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// JSON → 规则。空文本 = 没有下载段（nil 且无错误）。解码失败给一条可读错误。
    static func parse(json text: String) -> (rules: DPPDownloadRules?, error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return (nil, nil) }
        guard let data = trimmed.data(using: .utf8) else {
            return (nil, "Download rules JSON is not valid text.")
        }
        do {
            return (try JSONDecoder().decode(DPPDownloadRules.self, from: data), nil)
        } catch {
            return (nil, "Download rules JSON is invalid: \(error.localizedDescription)")
        }
    }

    // MARK: - 校验（与 saveDPPAdapter 同一套）

    /// 错误文案与 `saveDPPAdapter` 的下载段校验一致——表单、JSON、智能体三条
    /// 入口对同一份规则给出同一个结论。
    static func validate(_ rules: DPPDownloadRules) -> [String] {
        var errors: [String] = []
        if let engine = rules.engine, !engine.isEmpty,
           DownloadRouting.EnginePreference.parse(engine) == nil {
            errors.append("download.engine must be auto / parallel / ffmpeg / builtin")
        }
        if let perPage = rules.perPage, DPPDownloadRules.PerPage(rawValue: perPage.lowercased()) == nil {
            errors.append("download.perPage must be \"one\" or \"many\"")
        }
        guard let detail = rules.detailRule() else {
            errors.append("download.detail is required — \"regex:<pattern>\" or \"selector:<css>@<attr>\"")
            return errors
        }
        if case .regex(let pattern) = detail, (try? NSRegularExpression(pattern: pattern)) == nil {
            errors.append("download.detail regex is invalid: \(pattern)")
        }
        for pattern in rules.exclude ?? [] where (try? NSRegularExpression(pattern: pattern)) == nil {
            errors.append("download.exclude has an invalid regex: \(pattern)")
        }
        return errors
    }

    // MARK: - 只读展示

    /// 实测画像的一句话摘要（Studio 只读展示）。nil = 还没学到 / 样本不足。
    static func measuredSummary(_ measured: DPPDownloadRules.Measured?) -> String? {
        guard let measured, measured.samples >= DPPDownloadRules.measuredMinSamples else { return nil }
        let format = String(localized: "Measured %@ MB/s single · %@ MB/s over %lld connections (%lld samples)")
        return String(format: format,
                      String(format: "%.2f", measured.singleBytesPerSecond / 1_048_576),
                      String(format: "%.2f", measured.parallelBytesPerSecond / 1_048_576),
                      measured.connections, measured.samples)
    }
}

extension DPPAdapter {

    /// 可分享的导出副本（v0.8.79 批 3）：保留**规则与协议体**，剥离
    /// 本地溯源（sourceURL / installedAt / verifiedAt）与遥测（实测画像、
    /// 修订史、最近命中/失败）——导出的包换一台机器导入后是同一份行为。
    nonisolated func exportedCopy() -> DPPAdapter {
        var out = self
        out.sourceURL = nil
        out.installedAt = nil
        out.verifiedAt = nil
        if var rules = out.download {
            rules.measured = nil
            rules.lastMatchAt = nil
            rules.lastFailureAt = nil
            rules.lastError = nil
            rules.consecutiveFailures = nil
            rules.revisions = nil
            out.download = rules
        }
        return out
    }
}
