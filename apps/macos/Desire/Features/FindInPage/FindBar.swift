import SwiftUI

struct FindBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var findString: String
    let findMatchCount: Int
    let findCurrentIndex: Int
    var isFindFocused: FocusState<Bool>.Binding
    let onFindNext: () -> Void
    let onFindPrevious: () -> Void
    let onHide: () -> Void
    let onFindAll: () -> Void
    /// 跨标签查找（0.7.14 查找增强）：扫描其他标签中该词的匹配数，返回列表。
    /// nil = 宿主未启用（嵌入式精简形态）。
    var onScanOtherTabs: (() -> Void)? = nil
    /// 其他标签命中列表（宿主扫描后回填；FindBar 据此渲染 popover 行）。
    @State var otherTabMatches: [CrossTabFindStore.Match] = []
    @State var isScanning = false
    /// 点击命中行：宿主跳到该标签并执行查找。
    var onOpenOtherTab: ((UUID, String) -> Void)? = nil
    @State private var showOtherTabs = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in page…", text: $findString)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .focused(isFindFocused)
                .onChange(of: findString) { _, _ in
                    onFindAll()
                }
                .onSubmit { onFindNext() }
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Enter = 上一个（主流查找栏键盘流）。
                    if press.modifiers.contains(.shift) {
                        onFindPrevious()
                        return .handled
                    }
                    return .ignored
                }

            if findMatchCount > 0 && !findString.isEmpty {
                Text("\(findCurrentIndex + 1) / \(findMatchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !findString.isEmpty {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Previous", systemImage: "chevron.up") { onFindPrevious() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            Button("Next", systemImage: "chevron.down") { onFindNext() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)

            if onScanOtherTabs != nil {
                Button {
                    onScanOtherTabs?()
                    showOtherTabs = true
                } label: {
                    Image(systemName: "square.on.square.dashed")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(findString.isEmpty)
                .help("Find in other tabs")
                .popover(isPresented: $showOtherTabs, arrowEdge: .bottom) {
                    otherTabsPopover
                }
            }

            Button("Done") { onHide() }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFindFocused.wrappedValue = true }
    }

    /// 其他标签命中列表（popover）：标签名 + 匹配数，点击跳转。
    @ViewBuilder
    private var otherTabsPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Matches in other tabs")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if otherTabMatches.isEmpty {
                Text(isScanning ? "Scanning…" : "No matches in other tabs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(otherTabMatches) { m in
                    Button {
                        onOpenOtherTab?(m.tabID, findString)
                    } label: {
                        HStack(spacing: 6) {
                            Text(m.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(m.count)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

#Preview {
    FindBar(
        findString: .constant(""),
        findMatchCount: 0,
        findCurrentIndex: 0,
        isFindFocused: FocusState<Bool>().projectedValue,
        onFindNext: {}, onFindPrevious: {}, onHide: {}, onFindAll: {}
    )
}
