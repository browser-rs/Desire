import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewTabPage: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: QuickDialStore
    @Binding var urlString: String
    var onNavigate: (String) -> Void
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    /// 地址栏正在编辑时，本页的候补下拉让位——两份列表同时出现是用户报的
    /// "这两块不应该同时触发"。
    var isUrlBarEditing: Bool = false
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var historyStore: HistoryStore
    var settings: Settings
    @State private var searchText = ""
    @State private var editingDial: QuickDial?
    @State private var editTitle = ""
    @State private var editURL = ""
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 20)]
    private let contentMaxWidth: CGFloat = 980

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 56)

            searchField
                .padding(.bottom, 36)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    quickDialsSection

                    if !historyStore.entries.isEmpty {
                        recentSection
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: contentMaxWidth, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundGradient)
        .overlay(alignment: .top) {
            if searchFocused && !isUrlBarEditing && !suggestionModel.isEmpty {
                AddressSuggestionsView(
                    model: suggestionModel,
                    engineName: settings.effectiveEngineName
                ) { sug in
                    suggestionModel.reset()
                    searchText = ""
                    onNavigate(sug.url)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .padding(.top, 102)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .popover(item: $editingDial) { dial in
            editForm(dial: dial)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索或输入网址", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { submitSearch() }
                // ↑/↓ 在候选列表里选、Esc 收起列表。此前**完全没有键盘处理**
                // （模型和列表都支持高亮，只是没人调用），用户报"不能用键盘上下选择"。
                // 注：`.onKeyPress` 的回调在 SwiftUI 更新事务里执行，直接改 model 会报
                // "Publishing changes from within view updates"（见 AGENTS.md），
                // 所以这里跳一帧再写。
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.escape) {
                    guard !suggestionModel.isEmpty else { return .ignored }
                    Task { @MainActor in suggestionModel.reset() }
                    return .handled
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        suggestionModel.reset()
                    } else {
                        suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                    }
                }
                .onChange(of: searchFocused) { _, focused in
                    if !focused { suggestionModel.reset() }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    // MARK: - Quick Dials

    private var quickDialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "常用网站", icon: "square.grid.2x2")

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(store.dials.enumerated()), id: \.element.id) { index, dial in
                    QuickDialCard(
                        dial: dial,
                        index: index,
                        onNavigate: {
                            urlString = dial.url
                            onNavigate(dial.url)
                        },
                        onEdit: {
                            editingDial = dial
                            editTitle = dial.title
                            editURL = dial.url
                        },
                        onDelete: { store.delete(id: dial.id) },
                        onDragProvider: { NSItemProvider(object: NSString(string: "\(index)")) },
                        onDropAt: { target in
                            DialDropDelegate(targetIndex: target, store: store)
                        }
                    )
                }

                addButton
            }
        }
    }

    private var addButton: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .light))
            Text("添加")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: 130, height: 124)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            editingDial = QuickDial(title: "", url: "")
            editTitle = ""
            editURL = ""
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: "最近访问", icon: "clock")

            VStack(spacing: 6) {
                ForEach(recentEntries) { entry in
                    RecentVisitedCard(entry: entry) {
                        onNavigate(entry.url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentEntries: [RecentEntry] {
        historyStore.entries.prefix(8).map { entry in
            RecentEntry(
                id: entry.id,
                title: entry.title.isEmpty ? (URL(string: entry.url)?.host ?? entry.url) : entry.title,
                url: entry.url,
                host: URL(string: entry.url)?.host ?? entry.url
            )
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    appAccent.opacity(0.06),
                    .clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Actions

    /// 候选列表内的键盘选择。返回 `.handled` 才不让方向键去动光标；
    /// 列表为空时交还给文本域（跟地址栏那边的约定一致）。
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !suggestionModel.isEmpty else { return .ignored }
        Task { @MainActor in suggestionModel.moveSelection(by: delta) }
        return .handled
    }

    private func submitSearch() {
        // 回车优先打开**键盘高亮的候选**。第 0 行就是"搜索 / 前往 输入的内容"，
        // 所以没动过高亮时（刚输入完直接回车）行为与以前完全一致；
        // 用 ↑/↓ 选到书签、历史、其它建议时，回车就打开那一条。
        if let selected = suggestionModel.selected() {
            suggestionModel.reset()
            searchText = ""
            onNavigate(selected.url)
            return
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suggestionModel.reset()
        onNavigate(trimmed)
    }

    // MARK: - Edit Form

    private func editForm(dial: QuickDial) -> some View {
        VStack(spacing: 12) {
            TextField("标题", text: $editTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            TextField("网址", text: $editURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

            HStack(spacing: 12) {
                Button("取消") {
                    editingDial = nil
                }
                .keyboardShortcut(.escape)

                Button("保存") {
                    let trimmedTitle = editTitle.trimmingCharacters(in: .whitespaces)
                    let trimmedURL = editURL.trimmingCharacters(in: .whitespaces)
                    guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }

                    if store.dials.contains(where: { $0.id == dial.id }) {
                        store.update(id: dial.id, title: trimmedTitle, url: trimmedURL)
                    } else {
                        store.add(title: trimmedTitle, url: trimmedURL)
                    }
                    editingDial = nil
                }
                .keyboardShortcut(.return)
                .disabled(editTitle.trimmingCharacters(in: .whitespaces).isEmpty
                          || editURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
