import AppKit
import SwiftUI

/// 内置工具集合页（v0.8.27 重构）：`desire://tools`。
/// 左侧按分类分组 + 收藏/最近使用 + 搜索；右侧是工具详情或全部工具卡片网格。
/// 工具清单集中在 ToolboxCatalog（新增工具 = 加 case + switch 一行）。
struct ToolsPageView: View {
    @Environment(\.appAccent) private var appAccent: Color
    var initialTool: String? = nil

    /// 大屏布局（v0.8.33）：详情与首页各自限宽并**居中**——此前两者都
    /// 靠左（maxWidth 900/940 + alignment .leading），2560pt 窗口右侧留下
    /// 一大片空白；首页网格也只会排 4 列。
    private enum Layout {
        static let detailMaxWidth: CGFloat = 1120
        static let homeMaxWidth: CGFloat = 1560
        static let cardMinWidth: CGFloat = 230
        static let cardMaxWidth: CGFloat = 360
    }

    @State private var query = ""
    @State private var selected: ToolID?
    @ObservedObject private var usage = ToolboxUsageStore.shared
    @ObservedObject private var handoff = ToolboxHandoff.shared
    @State private var showQuickSwitcher = false

    init(initialTool: String? = nil) {
        self.initialTool = initialTool
        if let id = Self.match(initialTool) {
            _selected = State(initialValue: id)
        } else {
            _selected = State(initialValue: nil)
        }
    }

    /// 深链参数按小写匹配：desire://tools 会把 param 小写化
    /// （InternalPages.parse），驼峰 rawValue（excelColumn/videoEditor）
    /// 必须大小写不敏感地找回来。
    private static func match(_ raw: String?) -> ToolID? {
        guard let raw, !raw.isEmpty else { return nil }
        let needle = raw.lowercased()
        return ToolID.allCases.first { $0.rawValue.lowercased() == needle }
    }

    private var filtered: [ToolID] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return ToolID.allCases.filter { $0.searchText.lowercased().contains(needle) }
    }

    var body: some View {
        // 原生 NSSplitView：拖动由 AppKit 处理，SwiftUI 不随每帧重建。
        ToolboxSplitView(sidebar: sidebar, content: content)
        .onAppear {
            if let id = Self.match(initialTool) { select(id) }
        }
        .onChange(of: initialTool) { _, newValue in
            if let id = Self.match(newValue) { select(id) }
        }
        .onChange(of: handoff.requestToken) { _, _ in
            if let tool = handoff.takeRequestedTool() { select(tool) }
        }
        .overlay {
            if showQuickSwitcher {
                ToolboxQuickSwitcher(
                    tools: prioritizedTools,
                    onSelect: { tool in
                        select(tool)
                        showQuickSwitcher = false
                    },
                    onClose: { showQuickSwitcher = false })
            }
        }
    }

    /// 收藏 → 最近 → 全部（去重），快切浮层用这个顺序。
    private var prioritizedTools: [ToolID] {
        var seen = Set<String>()
        var result: [ToolID] = []
        for raw in usage.favorites + usage.recents {
            guard let tool = ToolID(rawValue: raw), seen.insert(tool.rawValue).inserted else {
                continue
            }
            result.append(tool)
        }
        for tool in ToolID.allCases where seen.insert(tool.rawValue).inserted {
            result.append(tool)
        }
        return result
    }

    // MARK: - 左栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Toolbox"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    selected = nil
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(selected == nil ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(String(localized: "All tools"))
                Button {
                    showQuickSwitcher = true
                } label: {
                    Image(systemName: "command")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .help(String(localized: "Quick switcher (⌘K)"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "Search tools…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        sectionHeader(String(localized: "Results"))
                        if filtered.isEmpty {
                            Text(String(localized: "No matching tools"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        ForEach(filtered) { tool in
                            sidebarRow(tool)
                        }
                    } else {
                        if !favoriteTools.isEmpty {
                            sectionHeader(String(localized: "Favorites"), icon: "star.fill")
                            ForEach(favoriteTools) { tool in
                                sidebarRow(tool)
                            }
                        }
                        if !recentTools.isEmpty {
                            sectionHeader(String(localized: "Recent"))
                            ForEach(recentTools) { tool in
                                sidebarRow(tool)
                            }
                        }
                        ForEach(ToolCategory.allCases) { category in
                            let tools = ToolID.allCases.filter { $0.category == category }
                            if !tools.isEmpty {
                                sectionHeader(category.title)
                                ForEach(tools) { tool in
                                    sidebarRow(tool)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var favoriteTools: [ToolID] {
        usage.favorites.compactMap { ToolID(rawValue: $0) }
    }

    private var recentTools: [ToolID] {
        usage.recents.compactMap { ToolID(rawValue: $0) }
            .filter { !usage.isFavorite($0.rawValue) }
    }

    private func sectionHeader(_ title: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func sidebarRow(_ tool: ToolID) -> some View {
        let active = selected == tool
        return Button {
            select(tool)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tool.icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(active ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                Text(tool.title)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? AnyShapeStyle(appAccent) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if usage.isFavorite(tool.rawValue) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(appAccent.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? appAccent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧

    @ViewBuilder
    private var content: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(selected)
                    toolView(selected)
                }
                .padding(24)
                .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            homeGrid
        }
    }

    private func detailHeader(_ tool: ToolID) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(appAccent.opacity(0.14))
                Image(systemName: tool.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(appAccent)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(tool.title)
                        .font(.system(size: 19, weight: .semibold))
                    Text(tool.category.title)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
                Text(tool.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("desire://tools/\(tool.rawValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button {
                usage.toggleFavorite(tool.rawValue)
            } label: {
                Image(systemName: usage.isFavorite(tool.rawValue) ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(usage.isFavorite(tool.rawValue)
                                     ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Favorite"))
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func toolView(_ tool: ToolID) -> some View {
        switch tool {
        case .hash: HashToolView()
        case .timestamp: TimestampToolView()
        case .base64: Base64ToolView()
        case .url: URLCodecToolView()
        case .json: JSONToolView()
        case .text: TextToolView()
        case .number: NumberToolView()
        case .uuid: UUIDToolView()
        case .color: ColorToolView()
        case .qr: QRCodeToolView()
        case .password: PasswordToolView()
        case .jwt: JWTToolView()
        case .mortgage: MortgageToolView()
        case .savings: SavingsToolView()
        case .percent: PercentToolView()
        case .scientific: ScientificToolView()
        case .bmi: BMIToolView()
        case .date: DateToolView()
        case .units: UnitsToolView()
        case .html: HTMLCodecToolView()
        case .unicode: UnicodeCodecToolView()
        case .hex: HexCodecToolView()
        case .regex: RegexToolView()
        case .random: RandomToolView()
        case .imageConvert: ImageConvertToolView()
        case .morse: MorseToolView()
        case .dataURI: DataURIToolView()
        case .width: WidthToolView()
        case .csvJSON: CSVJSONToolView()
        case .diff: DiffToolView()
        case .xml: XMLToolView()
        case .sql: SQLToolView()
        case .urlParse: URLParseToolView()
        case .cidr: CIDRToolView()
        case .httpStatus: HTTPStatusToolView()
        case .mime: MIMEToolView()
        case .userAgent: UserAgentToolView()
        case .cron: CronToolView()
        case .aes: AESToolView()
        case .hmac: HMACToolView()
        case .fileHash: FileHashToolView()
        case .idCard: IDCardToolView()
        case .luhn: LuhnToolView()
        case .roman: RomanToolView()
        case .excelColumn: ExcelColumnToolView()
        case .crc32: CRC32ToolView()
        case .sha3: SHA3ToolView()
        case .base58: Base58ToolView()
        case .regexReplace: RegexReplaceToolView()
        case .markdown: MarkdownToolView()
        case .ascii: ASCIIToolView()
        case .lorem: LoremToolView()
        case .httpHeaders: HTTPHeadersToolView()
        case .fileInfo: FileInfoToolView()
        case .discount: DiscountToolView()
        case .billSplit: BillSplitToolView()
        case .barcode: BarcodeToolView()
        case .videoEditor: VideoEditorToolView()
        case .audioEditor: AudioEditorToolView()
        case .pdfMerge: PDFMergeToolView()
        case .pdfSplit: PDFSplitToolView()
        case .pdfRotate: PDFRotateToolView()
        case .pdfToImages: PDFToImagesToolView()
        case .imagesToPDF: ImagesToPDFToolView()
        case .imageOCR: ImageOCRToolView()
        case .subtitle: SubtitleToolView()
        case .base32: Base32ToolView()
        case .totp: TOTPToolView()
        case .jsonPath: JSONPathToolView()
        case .structuredData: StructuredDataToolView()
        case .chmod: ChmodToolView()
        case .floatBits: FloatBitsToolView()
        case .ulid: ULIDToolView()
        case .timezone: TimeZoneToolView()
        case .zhConvert: ZhConvertToolView()
        case .pinyin: PinyinToolView()
        case .zhTypography: ZhTypographyToolView()
        case .contrast: ContrastToolView()
        case .qrDecode: QRDecodeToolView()
        case .batchRename: BatchRenameToolView()
        case .archive: ArchiveToolView()
        }
    }

    private var homeGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(localized: "All tools"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(String(localized: "\(ToolID.allCases.count) tools · everything runs on this Mac"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(ToolCategory.allCases) { category in
                    let tools = ToolID.allCases.filter { $0.category == category }
                    if !tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: category.icon)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(appAccent)
                                Text(category.title)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(tools.count)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMinWidth,
                                                                    maximum: Layout.cardMaxWidth),
                                                          spacing: 12)],
                                      alignment: .leading, spacing: 12) {
                                ForEach(tools) { tool in
                                    toolCard(tool)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: Layout.homeMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func toolCard(_ tool: ToolID) -> some View {
        ToolCardView(tool: tool,
                     isFavorite: usage.isFavorite(tool.rawValue),
                     accent: appAccent) {
            select(tool)
        }
    }

    private func select(_ tool: ToolID) {
        selected = tool
        usage.record(tool.rawValue)
    }
}

/// 首页工具卡（悬停高亮；收藏角标）。
private struct ToolCardView: View {
    let tool: ToolID
    let isFavorite: Bool
    let accent: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(hovering ? 0.2 : 0.12))
                    Image(systemName: tool.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(tool.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(accent)
                        }
                    }
                    Text(tool.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.secondary.opacity(0.09) : Color.secondary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// ⌘K 工具快切（v0.8.33）：搜索 + ↑↓ + 回车；收藏/最近在列表最前。
private struct ToolboxQuickSwitcher: View {
    let tools: [ToolID]
    let onSelect: (ToolID) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private var results: [ToolID] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(tools.prefix(12)) }
        return Array(tools.filter { $0.searchText.lowercased().contains(needle) }.prefix(12))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 8) {
                TextField(String(localized: "Search tools…"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit {
                        if results.indices.contains(selectedIndex) {
                            onSelect(results[selectedIndex])
                        }
                    }
                if results.isEmpty {
                    Text(String(localized: "No matching tools"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.offset) { index, tool in
                                Button {
                                    onSelect(tool)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: tool.icon)
                                            .font(.system(size: 11))
                                            .frame(width: 16)
                                            .foregroundStyle(.secondary)
                                        Text(tool.title)
                                            .font(.system(size: 12, weight: index == selectedIndex
                                                          ? .semibold : .regular))
                                        Spacer(minLength: 6)
                                        Text(tool.category.title)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(index == selectedIndex
                                              ? Color.secondary.opacity(0.14) : Color.clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
                Text(String(localized: "↑↓ to choose · Return to open · Esc to close"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onExitCommand { onClose() }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(0, results.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            if results.indices.contains(selectedIndex) {
                onSelect(results[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}
