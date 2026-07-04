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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

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
                    suggestionModel.reset()
                    onNavigate(searchText)
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        suggestionModel.reset()
                    } else {
                        suggestionModel.build(query: newValue, settings: settings, bookmarks: bookmarkStore, history: historyStore)
                    }
                }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(store.dials.enumerated()), id: \.element.id) { index, dial in
                        dialCard(dial, at: index)
                    }

                    addButton()
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
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

    private func dialCard(_ dial: QuickDial, at index: Int) -> some View {
        VStack(spacing: 8) {
            if dial.icon == "globe" {
                FaviconView(urlString: dial.url, size: 36)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: dial.icon)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
            }

            Text(dial.title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .frame(width: 100, height: 110)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadowSubtle()
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
        VStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("添加")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 100, height: 110)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
