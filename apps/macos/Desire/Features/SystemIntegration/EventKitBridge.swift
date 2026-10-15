import EventKit
import Foundation

/// OS 级协作（2026-10-15）：把"帮我记个提醒 / 加进日历"落到系统「提醒事项」与
/// 「日历」。授权按既定纪律**懒请求**（只在工具真的要用时弹窗），请求带 30 秒
/// 超时——系统弹窗可能永远不渲染（adhoc 构建的已知形态），绝不能无限挂起回合。
/// 超时后弹窗仍在，用户稍后点「允许」即对后续调用生效。
@MainActor
enum EventKitBridge {

    enum Kind {
        case reminder
        case event
    }

    enum Access: String {
        case granted, denied, restricted, notDetermined
    }

    enum RequestOutcome {
        case granted
        case denied
        case timedOut
    }

    private static let store = EKEventStore()

    // MARK: - 授权

    static func access(_ kind: Kind) -> Access {
        let raw = EKEventStore.authorizationStatus(for: kind == .reminder ? .reminder : .event)
        switch raw {
        case .fullAccess, .authorized, .writeOnly:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// 懒请求 + 30 秒超时（超时返回 .timedOut，弹窗不主动关）。
    static func request(_ kind: Kind) async -> RequestOutcome {
        switch access(kind) {
        case .granted: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined:
            break
        }
        /// 只在主 actor 上读写（两个 resume 来源都固定回主 actor）。
        final class Gate: @unchecked Sendable {
            var done = false
        }
        let gate = Gate()
        return await withCheckedContinuation { continuation in
            let finish: @MainActor (RequestOutcome) -> Void = { outcome in
                guard !gate.done else { return }
                gate.done = true
                continuation.resume(returning: outcome)
            }
            // 两个 resume 来源都固定回主 actor 执行——gate 无需锁。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                finish(.timedOut)
            }
            let completion: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in
                Task { @MainActor in finish(granted ? .granted : .denied) }
            }
            if kind == .reminder {
                store.requestFullAccessToReminders(completion: completion)
            } else {
                store.requestFullAccessToEvents(completion: completion)
            }
        }
    }

    /// 可用性闸：nil = 可用；非 nil = 直接可返回给模型的 `Error:` 文案。
    static func ensuringAccess(_ kind: Kind) async -> String? {
        switch await request(kind) {
        case .granted:
            return nil
        case .denied:
            let item = kind == .reminder ? "提醒事项" : "日历"
            return "Error: 用户未授权访问「\(item)」——需在 系统设置 ▸ 隐私与安全性 ▸ \(item) 里为 Desire 打开后重试。"
        case .timedOut:
            let item = kind == .reminder ? "提醒事项" : "日历"
            return "Error: 「\(item)」的授权弹窗还在等待确认（已等 30 秒）——请在系统弹窗里点「允许」后重试。"
        }
    }

    // MARK: - 提醒

    static func addReminder(title: String, notes: String?, due: Date?, listName: String?) async -> String {
        if let problem = await ensuringAccess(.reminder) { return problem }
        guard !title.isEmpty else { return "Error: missing title" }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        if let notes, !notes.isEmpty { reminder.notes = notes }
        reminder.calendar = matchList(named: listName) ?? store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return "Error: save failed — \(error.localizedDescription)"
        }
        var line = "Reminder added: \(title)"
        if let due { line += " · due \(SystemIntegrationDates.describe(due))（已带闹钟）" }
        if let list = reminder.calendar?.title, !list.isEmpty { line += " · list \(list)" }
        return line
    }

    static func listReminders(limit: Int) async -> String {
        if let problem = await ensuringAccess(.reminder) { return problem }
        let open = await fetchOpenReminders()
            .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        guard !open.isEmpty else { return "No open reminders." }
        let cap = min(max(1, limit), 40)
        let lines = open.prefix(cap).map { reminder -> String in
            var line = "· \(reminder.title ?? "(untitled)")"
            if let due = reminder.dueDateComponents?.date { line += " — due \(SystemIntegrationDates.describe(due))" }
            if let list = reminder.calendar?.title, !list.isEmpty { line += " [\(list)]" }
            return line
        }
        return "Open reminders (\(open.count), showing \(min(cap, open.count))):\n" + lines.joined(separator: "\n")
    }

    // MARK: - 日历

    static func addEvent(title: String, start: Date, end: Date?, durationMinutes: Int?,
                         location: String?, notes: String?, calendarName: String?) async -> String {
        if let problem = await ensuringAccess(.event) { return problem }
        guard !title.isEmpty else { return "Error: missing title" }
        let resolvedEnd: Date = end
            ?? start.addingTimeInterval(TimeInterval(max(5, durationMinutes ?? 60)) * 60)
        guard resolvedEnd > start else { return "Error: end must be after start" }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = resolvedEnd
        if let location, !location.isEmpty { event.location = location }
        if let notes, !notes.isEmpty { event.notes = notes }
        event.calendar = matchList(named: calendarName) ?? store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return "Error: save failed — \(error.localizedDescription)"
        }
        var line = "Event added: \(title) · \(SystemIntegrationDates.describe(start)) – \(SystemIntegrationDates.describe(resolvedEnd))"
        if let calendar = event.calendar?.title, !calendar.isEmpty { line += " · calendar \(calendar)" }
        return line
    }

    /// 提醒完成："带伞那条标完成"。匹配 open 且标题包含（大小写不敏感）——
    /// 多条命中不猜、列出来让模型问用户。
    static func completeReminder(title: String) async -> String {
        if let problem = await ensuringAccess(.reminder) { return problem }
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return "Error: missing title" }
        let open = await fetchOpenReminders()
        let matches = open.filter { ($0.title ?? "").lowercased().contains(wanted) }
        if matches.isEmpty { return "No open reminder matches '\(title)'." }
        if matches.count > 1 {
            let lines = matches.prefix(8).map { "· \($0.title ?? "(untitled)")" }
            return "Error: \(matches.count) open reminders match '\(title)' — be more specific:\n" + lines.joined(separator: "\n")
        }
        let reminder = matches[0]
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            return "Error: save failed — \(error.localizedDescription)"
        }
        var line = "Reminder completed: \(reminder.title ?? title)"
        if let due = reminder.dueDateComponents?.date { line += "（原 due \(SystemIntegrationDates.describe(due))）" }
        return line
    }

    /// 某时间窗内的日历事件（默认由调用方给窗；升序、cap）。
    static func listEvents(from: Date, to: Date, limit: Int) async -> String {
        if let problem = await ensuringAccess(.event) { return problem }
        guard to > from else { return "Error: 'to' must be after 'from'" }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else {
            return "No calendar events between \(SystemIntegrationDates.describe(from)) and \(SystemIntegrationDates.describe(to))."
        }
        let cap = min(max(1, limit), 50)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        let lines = events.prefix(cap).map { event -> String in
            var line = "· \(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate)) \(event.title ?? "(untitled)")"
            if let calendar = event.calendar?.title, !calendar.isEmpty { line += " [\(calendar)]" }
            if let location = event.location, !location.isEmpty { line += " @\(location)" }
            return line
        }
        return "Calendar events (\(events.count), showing \(min(cap, events.count))) \(SystemIntegrationDates.describe(from)) → \(SystemIntegrationDates.describe(to)):\n" + lines.joined(separator: "\n")
    }

    private static func fetchOpenReminders() async -> [EKReminder] {
        let reminderStore = store
        let all: [EKReminder] = await withCheckedContinuation { continuation in
            let predicate = reminderStore.predicateForReminders(in: nil)
            reminderStore.fetchReminders(matching: predicate) { reminders in
                let compacted = (reminders ?? []).compactMap { $0 }
                Task { @MainActor in continuation.resume(returning: compacted) }
            }
        }
        return all.filter { !$0.isCompleted }
    }

    // MARK: - 列表匹配

    /// 按名称匹配提醒列表（title 大小写不敏感）；nil = 用默认列表。
    private static func matchList(named name: String?) -> EKCalendar? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendars = store.calendars(for: .reminder) + store.calendars(for: .event)
        return calendars.first { $0.title.lowercased() == wanted }
    }
}
