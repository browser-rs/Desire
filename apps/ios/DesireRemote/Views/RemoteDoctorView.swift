import SwiftUI

/// 体检与同步健康（v0.8.80 批 4）：Mac 的 Agent 体检、同步状态/冲突/设备、
/// DPP 适配器启停。全部只读或显式开关，修复动作仍在 Mac 上做。
struct RemoteDoctorView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        List {
            doctorSection
            syncSection
            adaptersSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("体检与同步")
        .onAppear {
            client.requestDoctor()
            client.requestSyncHealth()
            client.requestAdapters()
        }
        .refreshable {
            client.requestDoctor()
            client.requestSyncHealth()
            client.requestAdapters()
        }
    }

    private var doctorSection: some View {
        Section {
            if let doctor = client.doctor {
                HStack(spacing: 10) {
                    DesireIconBadge(
                        icon: doctor.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        tint: doctor.ok ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doctor.ok ? "全部通过" : "有问题需要处理")
                            .font(.headline)
                        Text("\(doctor.passed)/\(doctor.total) 项通过")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(doctor.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(check.ok ? .green : .red)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.name).font(.subheadline.weight(.medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在体检（含端点连通性，约需几秒）…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            DesireSectionHeader(title: "Agent 体检", subtitle: "与 Mac 设置页同一份检查")
        }
    }

    private var syncSection: some View {
        Section {
            if let sync = client.syncHealth {
                DesireValueRow(title: "状态",
                               value: sync.signedIn ? (sync.syncing ? "同步中…" : "已登录") : "未登录",
                               valueColor: sync.lastError == nil ? .secondary : .red)
                if let username = sync.username {
                    DesireValueRow(title: "账号", value: username)
                }
                DesireValueRow(title: "上次同步", value: relative(sync.lastSyncAt))
                if let error = sync.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(sync.domains ?? []) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(row.ok ? .green : .red)
                        Text(row.domain).font(.caption)
                        Spacer()
                        Text(row.error ?? (row.at.map { relativeText($0) } ?? "—"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ForEach(sync.conflicts ?? []) { conflict in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("冲突 · \(conflict.domain)")
                            .font(.caption.weight(.medium))
                        Text(conflict.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let devices = sync.devices, !devices.isEmpty {
                    ForEach(devices) { device in
                        HStack(spacing: 6) {
                            Image(systemName: device.platform.contains("ios") ? "iphone" : "desktopcomputer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(device.name).font(.caption)
                            Spacer()
                            Text(device.revoked ? "已吊销" : relative(device.lastSeenAt))
                                .font(.caption2)
                                .foregroundStyle(device.revoked ? .red : .secondary)
                        }
                    }
                }
                if let error = sync.devicesError, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            } else {
                Text("正在读取同步状态…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            DesireSectionHeader(title: "同步健康", subtitle: "与 Mac 设置页同源")
        }
    }

    private var adaptersSection: some View {
        Section {
            if let frame = client.adapters {
                if frame.adapters.isEmpty {
                    Text("没有安装 DPP 适配器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(frame.adapters) { adapter in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { adapter.enabled && !adapter.autoDisabled },
                            set: { client.toggleAdapter(name: adapter.name, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(adapter.name).font(.subheadline.weight(.medium))
                                Text(adapter.hosts.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(adapter.autoDisabled)
                        if adapter.autoDisabled {
                            Text("连续失败已自动禁用——在 Mac 上核对站点改版后再启用")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if let error = adapter.lastError, !error.isEmpty {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
                if let errors = frame.loadErrors, !errors.isEmpty {
                    ForEach(errors.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(errors[key] ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Text("正在读取适配器…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            DesireSectionHeader(title: "DPP 适配器", subtitle: "启停与健康；修改包内容仍在 Mac")
        }
    }

    private func relative(_ epoch: Double?) -> String {
        guard let epoch else { return "—" }
        return relativeText(epoch)
    }

    private func relativeText(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
