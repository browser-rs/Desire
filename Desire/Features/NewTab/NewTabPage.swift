import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewTabPage: View {
    @ObservedObject var store: QuickDialStore
    @Binding var urlString: String
    var onNavigate: (String) -> Void
    @ObservedObject var suggestionModel: AddressSuggestionsModel
    @ObservedObject var bookmarkStore: BookmarkStore
    @ObservedObject var historyStore: HistoryStore
    var settings: Settings
    @State private var searchText = ""
    @State private var editingDial: QuickDial?
    @State private var editTitle = ""
    @State private var editURL = ""
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索或输入网址", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($searchFocused)
                .frame(maxWidth: 480)
                .padding(.horizontal)
                .padding(.top, 60)
                .onSubmit {
                    submitSearch()
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        suggestionModel.reset()
                    } else {
                        suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                    }
                }

            ScrollView {
                VStack(spacing: 32) {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(Array(store.dials.enumerated()), id: \.element.id) { index, dial in
                            dialCard(dial, at: index)
                        }

                        addButton()
                    }
                    .padding(.horizontal, 40)
                    .frame(maxWidth: 1100)

                    if !historyStore.entries.isEmpty {
                        recentSection(
                            title: "Recently Visited",
                            items: recentHistoryItems,
                            icon: "clock"
                        )
                    }
                }
                .padding(.top, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            if searchFocused && !suggestionModel.isEmpty {
                AddressSuggestionsView(
                    model: suggestionModel,
                    engineName: settings.searchEngine.rawValue
                ) { sug in
                    suggestionModel.reset()
                    searchText = ""
                    onNavigate(sug.url)
                }
                .padding(.horizontal, 12)
                .padding(.top, 102)
                .transition(.opacity)
            }
        }
        .popover(item: $editingDial) { dial in
            editForm(dial: dial)
        }
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suggestionModel.reset()
        onNavigate(trimmed)
    }

    private var recentHistoryItems: [(title: String, url: String)] {
        historyStore.entries.prefix(8).map { entry in
            (title: entry.title.isEmpty ? entry.url : entry.title, url: entry.url)
        }
    }

    private func recentSection(title: String, items: [(title: String, url: String)], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 40)

            VStack(spacing: 0) {
                ForEach(items, id: \.url) { item in
                    Button {
                        onNavigate(item.url)
                    } label: {
                        HStack(spacing: 10) {
                            FaviconView(urlString: item.url, size: 16)
                                .frame(width: 16, height: 16)
                            Text(item.title)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(URL(string: item.url)?.host ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 680)
                }
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
    }

    private func dialCard(_ dial: QuickDial, at index: Int) -> some View {
        VStack(spacing: 10) {
            if dial.icon == "globe" {
                FaviconView(urlString: dial.url, size: 40)
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: dial.icon)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
            }

            Text(dial.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: 110)
        }
        .frame(width: 130, height: 124)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
        )
        .shadowSubtle()
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .gesture(ExclusiveGesture(
            TapGesture(count: 2).onEnded {
                editingDial = dial
                editTitle = dial.title
                editURL = dial.url
            },
            TapGesture().onEnded {
                urlString = dial.url
                onNavigate(dial.url)
            }
        ))
        .contextMenu {
            Button("编辑") {
                editingDial = dial
                editTitle = dial.title
                editURL = dial.url
            }
            Button("删除") {
                store.delete(id: dial.id)
            }
        }
        .onDrag {
            NSItemProvider(object: NSString(string: "\(index)"))
        }
        .onDrop(of: [.text], delegate: DialDropDelegate(targetIndex: index, store: store))
    }

    private func addButton() -> some View {
        VStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 30, weight: .light))
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
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            editingDial = QuickDial(title: "", url: "")
            editTitle = ""
            editURL = ""
        }
    }

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

private struct DialDropDelegate: DropDelegate {
    let targetIndex: Int
    let store: QuickDialStore

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let str = reading as? String, let source = Int(str) else { return }
            Task { @MainActor in
                store.move(from: source, to: targetIndex)
            }
        }
        return true
    }
}
