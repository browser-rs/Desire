import SwiftUI

/// 新设备接入引导 sheet（v0.7.23）：设置 → Sync 的"接入引导"入口 + 首次登录
/// 后自动弹一次。内容 = 四步 checklist，完成度从 store 实时派生（见
/// `SyncOnboardingSteps`），本视图零业务逻辑。
struct SyncOnboardingSheet: View {
    @ObservedObject var store: SyncStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SyncOnboardingChecklist(store: store)
            HStack {
                Spacer()
                Button(localizedSettingText("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// checklist 本体——独立一层供离屏快照（`/panel/snapshot?name=syncchecklist`）
/// 直接渲染（sheet 壳子需要窗口，快照走不到）。
struct SyncOnboardingChecklist: View {
    @ObservedObject var store: SyncStore
    @State private var syncing = false

    private var account: String? {
        if case .signedIn(let username) = store.authState { return username }
        return nil
    }

    private var steps: [SyncOnboardingSteps.Step] {
        SyncOnboardingSteps.derive(
            account: account,
            hasKey: store.hasSyncKey,
            fingerprint: store.syncKeyFingerprint,
            enabledCount: SyncDomain.allCases.filter { store.isEnabled($0) }.count,
            lastSyncAt: store.lastSyncAt,
            now: Date()
        )
    }

    var body: some View {
        SettingsSection(
            title: localizedSettingText("Device Setup"),
            subtitle: localizedSettingText("Four steps to bring this Mac fully online. States update as you go."),
            icon: "checklist"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { SettingsRowDivider() }
                    SetupStepRow(
                        step: step,
                        isSyncing: store.isSyncing || syncing,
                        onSyncNow: {
                            syncing = true
                            Task {
                                await store.syncNow()
                                syncing = false
                            }
                        }
                    )
                }
            }
        }
    }
}

/// 单步行：状态圆点 + 标题 + 详情（事实插值）+ 可选动作。
private struct SetupStepRow: View {
    let step: SyncOnboardingSteps.Step
    let isSyncing: Bool
    let onSyncNow: () -> Void

    private var title: String {
        switch step.id {
        case .signIn: return localizedSettingText("Account")
        case .key: return localizedSettingText("Sync Key")
        case .categories: return localizedSettingText("Sync Categories")
        case .firstSync: return localizedSettingText("First Sync")
        }
    }

    private var detail: String {
        switch step.id {
        case .signIn:
            if let account = step.fact {
                return String(localized: "Signed in as \(account)")
            }
            return String(localized: "Sign in below to link this Mac.")
        case .key:
            if step.isDone {
                return String(localized: "End-to-end encrypted — the server cannot read your synced data.")
            }
            return String(localized: "Restores automatically from your account password after sign-in.")
        case .categories:
            if let count = step.fact {
                return String(localized: "\(count) categories enabled — adjust anytime below.")
            }
            return String(localized: "Pick at least one category below.")
        case .firstSync:
            if let when = step.fact {
                return String(localized: "Last sync: \(when).")
            }
            return String(localized: "Run one sync to verify the whole chain.")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(step.isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if step.id == .key, step.isDone, let fingerprint = step.fact {
                    Text(fingerprint)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            if step.id == .firstSync, !step.isDone {
                SettingsCapsuleButton(
                    "Sync Now",
                    isDisabled: isSyncing,
                    action: onSyncNow
                )
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}
