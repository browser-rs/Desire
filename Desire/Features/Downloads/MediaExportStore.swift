import Combine
import Foundation
import UserNotifications

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

        enum State: String {
            case running, finished, failed, cancelled
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    /// 开始一个后台导出，**立刻**返回任务 id。
    @discardableResult
    func start(url: URL, referer: URL?, userAgent: String?, fileNameHint: String?) -> UUID {
        let id = UUID()
        let hint = fileNameHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (hint?.isEmpty == false ? hint! : (url.lastPathComponent.isEmpty ? (url.host ?? url.absoluteString) : url.lastPathComponent))
        jobs.append(Job(id: id, url: url, title: title, state: .running, startedAt: Date()))

        let task = Task { [weak self] in
            do {
                let result = try await MediaExporter.download(
                    url: url,
                    referer: referer,
                    userAgent: userAgent,
                    fileNameHint: hint
                ) { _, _ in
                    // 段级进度：面板里以"运行中"呈现即可，暂不逐段上报。
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
        var summary = "\(result.fileURL.lastPathComponent) — \(result.segmentCount) segment(s), \(result.displayBytes)"
        if !result.warnings.isEmpty {
            summary += "\n⚠️ " + result.warnings.joined(separator: "\n⚠️ ")
        }
        jobs[index].state = .finished
        jobs[index].finishedAt = Date()
        jobs[index].summary = summary
        tasks[id] = nil
        deliver(String(localized: "Download finished"), body: summary)
    }

    private func fail(id: UUID, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let text = error.localizedDescription
        jobs[index].state = .failed
        jobs[index].finishedAt = Date()
        jobs[index].summary = text
        tasks[id] = nil
        deliver(String(localized: "Download failed"), body: "\(jobs[index].title): \(text)")
    }

    private func cancelJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .cancelled
        jobs[index].finishedAt = Date()
        tasks[id] = nil
    }

    /// 通知两条路：会话备注（模型可见）+ 系统通知（用户可见）。
    private func deliver(_ title: String, body: String) {
        AgentScheduler.shared.deliveryTarget?.appendExternalNote("\(title): \(body)")
        postNotification(title: title, body: body)
    }

    // MARK: - 系统通知（懒请求授权）

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.post(center: center, title: title, body: body)
            case .notDetermined:
                // 只在第一次真正要通知时请求（TCC 懒请求约定）。
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.post(center: center, title: title, body: body)
                }
            default:
                break
            }
        }
    }

    private nonisolated static func post(center: UNUserNotificationCenter, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
