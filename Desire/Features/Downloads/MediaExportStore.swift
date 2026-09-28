import Combine
import Foundation
@preconcurrency import UserNotifications

/// 后台媒体导出：`downloadMedia` 工具的执行体。
///
/// 此前这个工具**阻塞 agent 循环**直到导出结束——HLS 视频动辄几分钟，面板上就是
/// "一直在等待"，用户既不能继续对话，也看不到别的进度。现在工具立刻返回任务 id，
/// 导出在后台跑；完成/失败时：① 往当前会话追加一条 system 备注（面板不渲染 system
/// 消息，但模型下一轮看得到）；② 发一条系统通知（**首次完成时才请求授权**，见
/// AGENTS 的 TCC 懒请求约定）。
@MainActor
final class MediaExportStore: ObservableObject {
    static let shared = MediaExportStore()

    struct Job: Identifiable {
        let id: UUID
        let url: URL
        var title: String
        var state: State
        let startedAt: Date
        var finishedAt: Date?
        /// 成功：文件名 + 段数 + 体积；失败：错误描述。
        var summary: String?
        /// 批量任务的逐条结果不单独通知（批次汇总时统一说）。
        var isSilent: Bool = false

        enum State: String {
            case running, finished, failed, cancelled
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 单文件任务结束后的回调（批量引擎用它认领结果并推进队列）。
    private var completions: [UUID: (JobOutcome) -> Void] = [:]
    /// 段级/秒级进度回调（批量引擎转成快照里的 item progress）。
    private var progressHandlers: [UUID: (Int, Int, MediaExporter.ProgressUnit) -> Void] = [:]

    private init() {}

    /// 一个后台导出任务的终局。
    enum JobOutcome {
        case finished(MediaExporter.Result)
        case failed(Error)
        case cancelled
    }

    /// 开始一个后台导出，**立刻**返回任务 id。
    ///
    /// - Parameter folderName: 相对保存根目录的子目录（批量下载按批次
    ///   归档用），nil = 直接落根目录。
    /// - Parameter baseDirectory: 保存根目录（用户偏好的自定义位置），nil = ~/Downloads。
    /// - Parameter notify: false 时不发系统通知/会话备注（批量任务由
    ///   BatchMediaExportStore 统一汇总，逐条通知太吵）。
    /// - Parameter completion: 终局回调（终局后触发一次）。
    /// - Parameter progressHandler: 进度（done, total, 单位）——批量引擎
    ///   用来在快照里暴露逐项进度。
    @discardableResult
    func start(
        url: URL,
        referer: URL?,
        userAgent: String?,
        fileNameHint: String?,
        folderName: String? = nil,
        baseDirectory: String? = nil,
        notify: Bool = true,
        completion: ((JobOutcome) -> Void)? = nil,
        progressHandler: ((Int, Int, MediaExporter.ProgressUnit) -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        let hint = fileNameHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (hint?.isEmpty == false ? hint! : (url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent))
        jobs.append(Job(id: id, url: url, title: title, state: .running, startedAt: Date(), isSilent: !notify))
        trimSettledJobs()
        if let completion { completions[id] = completion }
        if let progressHandler { progressHandlers[id] = progressHandler }

        let task = Task { [weak self] in
            do {
                let result = try await MediaExporter.download(
                    url: url,
                    referer: referer,
                    userAgent: userAgent,
                    fileNameHint: hint,
                    folderName: folderName,
                    baseDirectory: baseDirectory
                ) { [weak self] done, total, unit in
                    self?.progressHandlers[id]?(done, total, unit)
                }
                self?.finish(id: id, result: result)
            } catch is CancellationError {
                self?.cancelJob(id: id)
            } catch let error as URLError where error.code == .cancelled {
                self?.cancelJob(id: id)
            } catch {
                self?.fail(id: id, error: error)
            }
        }
        tasks[id] = task
        return id
    }

    /// PERF-8：jobs 只增不裁——批量重度用户列表无限增长。超 100 条时裁最旧
    /// 的**终态**任务（running 绝不裁）。
    private func trimSettledJobs() {
        guard jobs.count > 100 else { return }
        let settled = jobs.filter { $0.state != .running }
        let toRemove = Set(settled.prefix(jobs.count - 100).map(\.id))
        guard !toRemove.isEmpty else { return }
        jobs.removeAll { toRemove.contains($0.id) }
    }

    func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    var activeCount: Int {
        jobs.filter { $0.state == .running }.count
    }

    // MARK: - 完成 / 失败

    private func finish(id: UUID, result: MediaExporter.Result) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        var summary = "\(result.fileURL.lastPathComponent) — \(result.displayDetail), \(result.displayBytes)"
        if let verification = result.verification {
            summary += ", verified \(verification)"
        }
        if !result.warnings.isEmpty {
            summary += "\n⚠️ " + result.warnings.joined(separator: "\n⚠️ ")
        }
        jobs[index].state = .finished
        jobs[index].finishedAt = Date()
        jobs[index].summary = summary
        tasks[id] = nil
        progressHandlers[id] = nil
        settle(id: id, outcome: .finished(result))
        if notifyEnabled(id) {
            deliverNote(String(localized: "Download finished"), body: summary)
        }
    }

    private func fail(id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let text = error.localizedDescription
        jobs[index].state = .failed
        jobs[index].finishedAt = Date()
        jobs[index].summary = text
        tasks[id] = nil
        progressHandlers[id] = nil
        settle(id: id, outcome: .failed(error))
        if notifyEnabled(id) {
            deliverNote(String(localized: "Download failed"), body: "\(jobs[index].title): \(text)")
        }
    }

    private func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        jobs[index].finishedAt = Date()
        tasks[id] = nil
        progressHandlers[id] = nil
        settle(id: id, outcome: .cancelled)
    }

    /// 触发一次性终局回调（终局路径必经，防止续两次）。
    private func settle(id: UUID, outcome: JobOutcome) {
        guard let completion = completions.removeValue(forKey: id) else { return }
        completion(outcome)
    }

    /// `notify: false` 的任务不发通知——批量任务的逐条结果由
    /// BatchMediaExportStore 汇总成一条，逐条通知太吵。
    private func notifyEnabled(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        return !jobs[index].isSilent
    }

    /// 通知两条路：会话备注（模型可见）+ 系统通知（用户可见）。
    /// internal：批量引擎（BatchMediaExportStore）的批次级汇总复用同一条
    /// 通道（含 TCC 懒请求授权），不另起一套通知代码。
    func deliverNote(_ title: String, body: String) {
        AgentScheduler.shared.deliveryTarget?.appendExternalNote("\(title): \(body)")
        postNotification(title: title, body: body)
    }

    // MARK: - 系统通知（懒请求授权）

    private func postNotification(title: String, body: String) {
        // 不把 `UNUserNotificationCenter`（非 Sendable）捕获进 @Sendable 回调里——
        // 这几层闭包都在别的队列上跑，需要时各自取一次 `.current()`。
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.post(title: title, body: body)
            case .notDetermined:
                // 只在第一次真正要通知时请求（TCC 懒请求约定）。
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.post(title: title, body: body)
                }
            default:
                break
            }
        }
    }

    private nonisolated static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
