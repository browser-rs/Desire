import Foundation
import os
@preconcurrency import UserNotifications

/// Agent 体检（doctor）：一次性自检报告——
/// 活动模型档案与端点可达性、旁路/备用档案有效性、MCP 连接、ffmpeg、
/// 钩子语法、技能风险、通知授权、心跳状态。桥 `GET /agent/doctor` 与
/// 设置页"Agent 体检"行共用同一份逻辑，禁止另算一套。
@MainActor
enum AgentDoctor {
    struct Check: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    struct Report: Equatable {
        let checks: [Check]
        var passed: Int { checks.filter(\.ok).count }
        var ok: Bool { checks.allSatisfy(\.ok) }
    }

    static func run() async -> Report {
        var checks: [Check] = []
        let preference = AppState.live?.aiPreference

        // 1. 活动模型档案：配置 + 端点可达（任何 HTTP 响应都算可达，含 401/404）
        if let preference, let active = preference.activeProfile {
            let keyOK = preference.hasAPIKey
            checks.append(Check(
                name: "模型服务",
                ok: true,
                detail: "\(active.name) · \(active.model.isEmpty ? "未选模型" : active.model) · \(keyOK ? "Key 已配置" : "未配置 Key")"))
            let reachable = await Self.reachable(active.endpoint)
            checks.append(Check(
                name: "端点可达",
                ok: reachable,
                detail: reachable ? active.host : "3 秒内无响应：\(active.host)（若配了代理，确认代理放行该域名）"))
        } else {
            checks.append(Check(name: "模型服务", ok: false, detail: "没有活动档案"))
        }

        // 2. 旁路 / 备用档案有效性（指向的档案还在不在）
        if let preference {
            if let bid = preference.bypassProfileID {
                let valid = preference.profiles.contains(where: { $0.id == bid })
                checks.append(Check(name: "旁路档案", ok: valid,
                                    detail: valid ? "已配置（标题/记忆整理走它）" : "指向的档案不存在——旁路调用已回落主模型"))
            }
            if let fid = preference.fallbackProfileID {
                let valid = preference.profiles.contains(where: { $0.id == fid })
                checks.append(Check(name: "备用档案", ok: valid,
                                    detail: valid ? "已配置（瞬态失败自动切换）" : "指向的档案不存在——容灾已失效"))
            }
        }

        // 3. MCP 服务器连接
        let mcpServers = MCPStore.shared.servers
        if mcpServers.isEmpty {
            checks.append(Check(name: "MCP 服务器", ok: true, detail: "未配置（可选项）"))
        } else {
            let statuses = MCPStore.shared.statuses
            let connected = mcpServers.filter { statuses[$0.id] == "connected" }.count
            checks.append(Check(name: "MCP 服务器", ok: connected == mcpServers.count,
                                detail: "\(connected)/\(mcpServers.count) 台已连接"))
        }

        // 4. ffmpeg（HLS 直连 MP4 的前置）
        let fm = FileManager.default
        let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                           "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        let ffmpeg = ffmpegPaths.contains { fm.fileExists(atPath: $0) }
        checks.append(Check(name: "ffmpeg", ok: ffmpeg,
                            detail: ffmpeg ? "已安装（HLS 直下 MP4 可用）" : "未安装（brew install ffmpeg 后视频直连可用）"))

        // 5. 钩子语法
        let hooks = AgentHooksStore.shared
        let broken = hooks.files.filter { $0.hasError != nil }.count
        checks.append(Check(name: "生命周期钩子", ok: broken == 0,
                            detail: !hooks.isEnabled ? "已停用"
                                : "\(hooks.files.count) 个文件，\(broken) 个语法错误"))

        // 6. 技能与风险
        let skills = SkillStore.shared.skills
        var riskySkills = 0
        for skill in skills {
            if let body = SkillStore.shared.body(for: skill.name),
               SkillScanner.summary(for: body) != nil { riskySkills += 1 }
        }
        checks.append(Check(name: "技能", ok: true,
                            detail: "\(skills.count) 个，其中 \(riskySkills) 个含风险形态"))

        // 7. 通知授权（例行提醒的前置）
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                cont.resume(returning: ok)
            }
        }
        checks.append(Check(name: "通知授权", ok: granted,
                            detail: granted ? "已授权" : "未授权（首次发送通知时再请求）"))

        // 8. 心跳
        let heartbeat = HeartbeatStore.shared
        checks.append(Check(name: "心跳巡检", ok: true,
                            detail: heartbeat.isEnabled ? "每 \(heartbeat.intervalMinutes) 分钟" : "未启用（设置页 AI 区可开）"))

        return Report(checks: checks)
    }

    /// 端点可达性：GET 基地址，任何 HTTP 响应（含 401/404）都算"网络通"。
    static func reachable(_ urlString: String) async -> Bool {
        guard var comps = URLComponents(string: urlString) else { return false }
        comps.path = ""
        comps.query = nil
        guard let url = comps.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return response is HTTPURLResponse
    }
}
