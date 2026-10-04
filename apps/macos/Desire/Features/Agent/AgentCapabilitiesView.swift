import SwiftUI

/// Full-height showcase of the AI agent's capabilities: the always-on
/// abilities (voice, vision, page context, routing) plus EVERY registered
/// tool — built-ins and MCP-bridged alike — grouped by category with risk
/// badges. Data comes from the live tool registry, so the page always
/// matches what the agent can actually do.
struct AgentCapabilitiesView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    var onBack: () -> Void

    @State private var searchText = ""

    private var allTools: [AgentToolDef] {
        BrowserToolProvider.toolDefs + MCPStore.shared.toolDefs
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    abilitiesSection
                    toolsSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            HoverIcon(systemName: "chevron.left", action: onBack, help: "Back")
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Agent 能力")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(allTools.count) 个工具")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索工具", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Built-in abilities (not tools)

    private var abilitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常驻能力")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(Self.abilities.enumerated()), id: \.offset) { index, ability in
                    HStack(spacing: 10) {
                        Image(systemName: ability.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appAccent)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(appAccent.opacity(0.10))
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ability.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(ability.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    if index < Self.abilities.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            )
        }
    }

    // MARK: - Tool registry

    @ViewBuilder
    private var toolsSection: some View {
        let filtered = filteredGroups
        VStack(alignment: .leading, spacing: 8) {
            Text("浏览器工具")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            if filtered.isEmpty {
                Text("没有匹配的工具")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            ForEach(filtered, id: \.category) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: group.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(group.category) · \(group.tools.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(group.tools.enumerated()), id: \.element.function.name) { index, tool in
                            toolRow(tool)
                            if index < group.tools.count - 1 {
                                SettingsRowDivider()
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    )
                }
            }
        }
    }

    private func toolRow(_ tool: AgentToolDef) -> some View {
        let risk = ToolRisk.classify(tool.function.name)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.function.name)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                Text(tool.function.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            StatusPill(text: risk.label, kind: risk.pillKind)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(tool.function.description)
    }

    // MARK: - Grouping / filtering

    private struct ToolGroup {
        let category: String
        let icon: String
        let tools: [AgentToolDef]
    }

    private var filteredGroups: [ToolGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var byCategory: [String: [AgentToolDef]] = [:]
        for tool in allTools {
            if !query.isEmpty {
                let haystack = (tool.function.name + " " + tool.function.description).lowercased()
                guard haystack.contains(query) else { continue }
            }
            let category = Self.category(for: tool.function.name)
            byCategory[category, default: []].append(tool)
        }
        return Self.categoryOrder.compactMap { category in
            guard let tools = byCategory[category], !tools.isEmpty else { return nil }
            return ToolGroup(category: category, icon: Self.categoryIcons[category] ?? "wrench.and.screwdriver", tools: tools)
        }
    }

    private static let categoryOrder = [
        "页面读取", "页面操作", "导航与标签", "媒体提取", "收藏与剪贴板", "系统与技能", "浏览器设置", "其他",
    ]

    private static let categoryIcons = [
        "页面读取": "doc.text.magnifyingglass",
        "页面操作": "cursorarrow.click.2",
        "导航与标签": "square.on.square",
        "媒体提取": "play.rectangle",
        "收藏与剪贴板": "doc.on.clipboard",
        "浏览器设置": "gearshape",
        "系统与技能": "terminal",
        "其他": "wrench.and.screwdriver",
    ]

    private static func category(for toolName: String) -> String {
        for (category, names) in categoryMap where names.contains(toolName) {
            return category
        }
        return "其他"   // MCP-bridged tools land here
    }

    private static let categoryMap: [String: Set<String>] = [
        "页面读取": [
            "getPageSnapshot", "getPageText", "getPageHTML", "getPageTitle",
            "getSelectedText", "readTab", "getComments", "getConversation",
            "getFormFields", "getPageLinks", "extract", "findElements",
            "getTables", "getImages", "getPageMeta", "getElementHTML",
            "getNetworkLog",
        ],
        "页面操作": [
            "renderDiagram",
            "askUser",
            "click", "clickAt", "hover", "focus", "fill", "select", "scroll",
            "pressKey", "type", "highlight", "waitForElement", "waitForText",
            "wait", "executeJS", "toggleReaderMode", "toggleDarkMode",
            "zoomIn", "zoomOut", "resetZoom", "togglePictureInPicture",
            "toggleResponsiveMode", "listBlockedElements", "unblockElement",
        ],
        "导航与标签": [
            "navigate", "newTab", "listTabs", "switchTab", "closeTab",
            "closeOtherTabs", "reopenLastClosedTab", "duplicateTab",
            "goBack", "goForward", "listTabGroups", "addTabToGroup",
            "removeTabFromGroup", "listContainers",
        ],
        "媒体提取": [
            "listPageVideos", "downloadMedia", "screenshot", "screenshotElement",
            "setUploadFile",
            "startRecording", "stopRecording",
        ],
        "收藏与剪贴板": [
            "addBookmark", "listBookmarks", "removeBookmark",
            "addToReadingList", "copyToClipboard", "readClipboard",
            "saveAsPDF", "printPage", "addQuickDial", "listQuickDials",
            "removeQuickDial", "getHistory", "clearHistory", "listDownloads",
        ],
        "浏览器设置": [
            "setSearchEngine", "toggleAdBlocking", "toggleTrackingProtection",
            "toggleSidebar", "listPlugins", "togglePlugin",
        ],
        "系统与技能": [
            "runCommand", "useSkill", "listSkills", "writeFile",
            "readFile", "listDirectory",
        ],
    ]

    private static let abilities: [(icon: String, title: String, subtitle: String)] = [
        ("mic.fill", "语音输入", "实时语音转文字，说完自动发送指令"),
        ("eye", "视觉理解", "截图看屏 + 拖拽图片提问，视觉模型直接读图"),
        ("doc.text.magnifyingglass", "自动页面上下文", "每轮请求自动携带当前页面摘要（设置中可关闭）"),
        ("arrow.triangle.branch", "智能模型路由", "云端 / 端侧 / 本地模型按任务复杂度自动选择"),
        ("brain.head.profile", "长期记忆", "自动提取用户偏好与习惯，跨会话生效，可在记忆页查看和删除"),
        ("clock.arrow.circlepath", "会话记忆", "对话持久化保存，长对话自动生成摘要用于跨会话回忆"),
        ("puzzlepiece.extension", "MCP 扩展工具", "接入外部工具服务器，动态扩充上方工具表"),
        ("terminal", "系统命令执行", "运行 ffmpeg / brew / python3 等本地 CLI（白名单 + 每次批准）"),
        ("books.vertical", "技能系统", "SKILL.md 技能库按需加载完整操作手册"),
    ]
}

private extension ToolRisk {
    var label: String {
        switch self {
        case .readonly: "安全"
        case .sideEffect: "需批准"
        case .dangerous: "每次确认"
        }
    }

    var pillKind: StatusPill.Kind {
        switch self {
        case .readonly: .success
        case .sideEffect: .warning
        case .dangerous: .error
        }
    }
}
