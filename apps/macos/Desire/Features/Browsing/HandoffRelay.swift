import AppKit
import Foundation

/// **Apple Handoff 发射端**（v0.8.67 批 1，融合旗舰）：mac 上 Desire 停在
/// 某个网页 → iPhone/iPad 锁屏与多任务出现系统级"继续浏览"卡 → 点开由
/// DesireRemote 接收（接收端见 iOS DesireRemote，批 2）。
///
/// activityType 用 Safari 同款的 `BrowsingWebPage`（NSUserActivityTypeBrowsingWeb）。
/// **已知风险（规划稿标注）**：系统可能把该类型的接力卡路由给默认浏览器
/// （Safari）而不是 DesireRemote——批 1 真机实测路由归属；若被抢，换自定义
/// `me.siwi.Desire.browsing` 并在两端 Info.plist 显式声明（常量在此一处切换）。
///
/// 生命周期：正常网页导航 didFinish 时更新（查看器挂载中的 file:// 页面不
/// 广播——接力的是浏览上下文，不是本地文件）；新 activity 创建即
/// becomeCurrent，旧实例由系统语义接管（换页 = 换 activity）。
@MainActor
final class HandoffRelay {
    static let shared = HandoffRelay()

    /// Safari 同款浏览接力类型（NSUserActivityTypeBrowsingWeb = "BrowsingWebPage"）。
    /// 被系统强路由给 Safari 时切换为 "me.siwi.Desire.browsing"。
    static let activityType = NSUserActivityTypeBrowsingWeb

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
