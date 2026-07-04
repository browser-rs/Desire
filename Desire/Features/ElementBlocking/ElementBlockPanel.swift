import SwiftUI

struct ElementBlockPanel: View {
    @ObservedObject var store: ElementBlockStore
    var onStartPicker: () -> Void
    var onClose: () -> Void

    @State private var showAddSheet = false
    @State private var newPattern = ""
    @State private var newCss = ""
    @State private var newXpath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("元素拦截").font(.headline)
                Spacer()
                Button("页面选取") { onStartPicker(); onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("添加规则") { showAddSheet = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("关闭", action: onClose)
            }
            .padding()

            if store.rules.isEmpty {
                EmptyState(message: "暂无拦截规则")
            } else {
                List {
                    ForEach(store.rules) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(rule.urlPattern)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(rule.createdAt.formatted(date: .numeric, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(rule.cssSelector)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            if let x = rule.xpath {
                                Text(x)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .contextMenu {
                            Button("删除", role: .destructive) { store.remove(id: rule.id) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 400)
        .sheet(isPresented: $showAddSheet) {
            VStack(spacing: 12) {
                Text("添加拦截规则").font(.headline)
                TextField("URL 模式（如 example.com, * 为全部）", text: $newPattern)
                TextField("CSS 选择器", text: $newCss)
                TextField("XPath（可选）", text: $newXpath)
                HStack {
                    Button("取消") { showAddSheet = false }
                    Button("添加") {
                        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
                        let css = newCss.trimmingCharacters(in: .whitespaces)
                        guard !pattern.isEmpty, !css.isEmpty else { return }
                        let xpath = newXpath.trimmingCharacters(in: .whitespaces)
                        store.add(cssSelector: css, xpath: xpath.isEmpty ? nil : xpath, urlPattern: pattern)
                        newPattern = ""; newCss = ""; newXpath = ""
                        showAddSheet = false
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty || newCss.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(width: 380)
        }
    }
}

#Preview {
    ElementBlockPanel(store: ElementBlockStore(), onStartPicker: {}, onClose: {})
}
