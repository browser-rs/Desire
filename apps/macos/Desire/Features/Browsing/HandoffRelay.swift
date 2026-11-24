import AppKit
import Foundation

/// **Apple Handoff 发射端**（v0.8.67 批 1，融合旗舰）：mac 上 Desire 停在
/// 某个网页 → iPhone/iPad 锁屏与多任务出现系统级"继续浏览"卡 → 点开由
/// DesireRemote 接收（接收端见 iOS DesireRemote，批 2）。
///
/// activityType 默认用 Safari 同款的 `BrowsingWebPage`
/// （NSUserActivityTypeBrowsingWeb）。**已知风险（规划稿标注）**：系统可能把
/// 该类型的接力卡路由给默认浏览器（Safari）而不是 DesireRemote——预案 =
/// UserDefaults 覆盖键 `handoff.activityType`（v0.8.68 批 1）：真机实测被抢时
/// `defaults write me.siwi.Desire handoff.activityType me.siwi.Desire.browsing`
/// 一键切换（无需改代码发版；两端的 Info.plist 已同时声明两个类型，
/// 下一次导航即生效——update 时现读，无需重启）。
///
/// 生命周期：正常网页导航 didFinish 时更新（查看器挂载中的 file:// 页面不
/// 广播——接力的是浏览上下文，不是本地文件）；新 activity 创建即
/// becomeCurrent，旧实例由系统语义接管（换页 = 换 activity）。
@MainActor
final class HandoffRelay {
    static let shared = HandoffRelay()

    /// 覆盖键（UserDefaults "handoff.activityType"）。空/未设 = 默认。
    static let overrideKey = "handoff.activityType"
    /// 被系统强路由给 Safari 时切到这个自定义类型。
    static let fallbackType = "me.siwi.Desire.browsing"

    /// 当前生效的 activityType：defaults 覆盖优先，默认 Safari 同款
    /// （NSUserActivityTypeBrowsingWeb = "BrowsingWebPage"）。每次 update
    /// 现读——改 defaults 后下一页导航即生效。
    static var activityType: String {
        let overridden = AppPrefs.defaults.string(forKey: overrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let overridden, !overridden.isEmpty {
            return overridden
        }
        return NSUserActivityTypeBrowsingWeb
    }

    /// 强引用：becomeCurrent 后 activity 仍在有效期，不能被释放掉。
    private var activity: NSUserActivity?

    func update(url: URL, title: String?) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = title ?? url.host
        activity.webpageURL = url
        activity.requiredUserInfoKeys = [Self.activityType]
        activity.addUserInfoEntries(from: [
            NSUserActivityTypeBrowsingWeb: url.absoluteString,
        ])
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        self.activity = activity
        activity.becomeCurrent()
    }
}
