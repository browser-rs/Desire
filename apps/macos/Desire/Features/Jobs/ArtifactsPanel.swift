import AppKit
import SwiftUI

extension Notification.Name {
    /// 打开产物中心（Toolbar 拥有 sheet 状态；desire://artifacts、Jobs 面板
    /// 跳转与菜单/工具面共用）。
    static let openArtifactsPanel = Notification.Name("desire.artifacts.open")
}

/// 产物中心（v0.8.57 批 1）：跨 Job 的产物统一视图——ArtifactIndex 从
/// JobStore **派生**（不另存状态），按 今天/本周/更早 分组 + 类型过滤。
/// 行右键：Finder 显示 / 拷贝路径（发送到…/再加工随批 3）。
struct ArtifactsPanel: View {
    @ObservedObject private var store = JobStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kindFilter: ArtifactIndex.Kind?
    /// 路径 → 现查的文件尺寸/存在性（派生层不碰盘，面板层补）。
    @State private var sizes: [String: Int?] = [:]
    @State private var missing: Set<String> = []

    private var items: [ArtifactIndex.Item] {
        ArtifactIndex.filter(
            ArtifactIndex.derive(from: store.allJobs),
            kind: kindFilter, withinDays: 30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Artifacts")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(items.count) items from finished jobs (last 30 days)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                kindFilterMenu
            }
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No artifacts yet — batch jobs list their outputs here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ArtifactIndex.groups(items), id: \.key) { group in
                            section(group)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    private var kindFilterMenu: some View {
        Menu {
            Button(String(localized: "All kinds")) { kindFilter = nil }
            ForEach(ArtifactIndex.Kind.displayOrder, id: \.rawValue) { kind in
                Button(kind.title) { kindFilter = kind }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(kindFilter?.title ?? String(localized: "All kinds"))
                    .font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func section(_ group: (key: String, items: [ArtifactIndex.Item])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(groupTitle(group.key))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(group.items) { item in
                row(item)
            }
        }
    }

    private func groupTitle(_ key: String) -> String {
        switch key {
        case "today": return String(localized: "Today")
        case "week": return String(localized: "This Week")
        default: return String(localized: "Earlier")
        }
    }

    private func row(_ item: ArtifactIndex.Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(item.kind))
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(itemName(item))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(item.kind.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    if missing.contains(item.path) {
                        Text(String(localized: "Missing"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.red)
                    } else if let size = sizes[item.path], let size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Text("· \(item.jobTitle)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Show in Finder")) { reveal(item) }
            Button(String(localized: "Copy Path")) { copyPath(item) }
        }
        .onAppear { enrich(item) }
    }

    private func itemName(_ item: ArtifactIndex.Item) -> String {
        (item.path as NSString).lastPathComponent
    }

    private func icon(_ kind: ArtifactIndex.Kind) -> String {
        switch kind {
        case .folder: return "folder"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .data: return "tablecells"
        case .other: return "doc"
        }
    }

    /// 现查尺寸/存在性（只对首次出现的路径做一次 stat）。
    private func enrich(_ item: ArtifactIndex.Item) {
        guard sizes[item.path] == nil, !missing.contains(item.path) else { return }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
        if !exists {
            missing.insert(item.path)
            return
        }
        if isDir.boolValue {
            sizes[item.path] = nil
            return
        }
        sizes[item.path] = try? FileManager.default.attributesOfItem(
            atPath: item.path)[.size] as? Int
    }

    private func reveal(_ item: ArtifactIndex.Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    private func copyPath(_ item: ArtifactIndex.Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }
}
