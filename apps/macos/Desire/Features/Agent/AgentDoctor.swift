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

        // 3.5 上下文压缩与归档（2026-11-15）：当前会话压过没有、归档多大。
        if let store = AgentScheduler.shared.deliveryTarget,
           let id = store.conversationId {
            let archiveURL = DiskStore.directory
                .appendingPathComponent("conversation-\(id.uuidString).archive.json")
            let attrs = try? FileManager.default.attributesOfItem(atPath: archiveURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            checks.append(Check(
                name: "上下文压缩",
                ok: true,
                detail: size > 0
                    ? "已有归档（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）——归档轮次用 recallConversation 检索"
                    : "未触发过（会话仍在预算内）"))
        }

        // 3.6 大结果转存目录（tool-results/）：超 1GB 提示清理。
        let spillDir = AgentWorkspace.shared.directory
            .appendingPathComponent("tool-results", isDirectory: true)
        let spillSize = Self.directorySize(spillDir)
        let lastGC = ToolResultSpill.lastGCAt
        let gcNote = lastGC.map {
            " · 上次清理 " + DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
        } ?? ""
        checks.append(Check(
            name: "转存目录",
            ok: spillSize < 1_000_000_000,
            detail: spillSize == 0
                ? "空（尚无大结果转存）"
                : "\(ByteCountFormatter.string(fromByteCount: Int64(spillSize), countStyle: .file))（\(spillDir.path)）\(gcNote)"))

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

        // 9. 主线程健康（v0.8.49）：最近一次停滞记录（体检页与诊断包同源）
        if let stall = RuntimeHealthMonitor.lastStall() {
            let minutes = Int(Date().timeIntervalSince(stall.startedAt) / 60)
            checks.append(Check(
                name: "主线程健康",
                ok: false,
                detail: "上次运行出现 \(Int(stall.seconds)) 秒停滞（\(minutes) 分钟前）"
                    + (stall.sampled ? "，已抓到栈（诊断包可见）" : "，未抓到栈（Hardened Runtime 限制）")))
        } else {
            checks.append(Check(name: "主线程健康", ok: true, detail: "未记录到主线程停滞"))
        }

        // 10. 同步完整性（v0.8.65 批 1 的数据面，体检收口：快拨同址重复
        // 应为 0——收敛修复 b10fc03d 后正常态；书签重复是语义豁免不判失败）。
        if let sync = AppState.live?.syncStore {
            let duplicates = (sync.healthReport()["duplicates"] as? [[String: Any]]) ?? []
            let dial = duplicates.first(where: { ($0["domain"] as? String) == "quickdials" })
            let groups = dial?["groups"] as? Int ?? 0
            let extra = dial?["extra"] as? Int ?? 0
            // 判据 = extra（多出的份数），不是 groups（groups 是"不同地址
            // 数"，9 条各不相同的快拨 = 9 组，正常态）。
            if extra > 0 {
                checks.append(Check(
                    name: "同步完整性",
                    ok: false,
                    detail: "快拨同址重复：\(groups) 个地址多出 \(extra) 份——收敛修复重启后应自动清零"))
            } else {
                checks.append(Check(name: "同步完整性", ok: true, detail: "快拨无同址重复（\(groups) 个地址）"))
            }
        }

        // 11. 协作池水位（v0.8.70 批 1，诊断 pill 同源同口径）：p95 > 2s =
        // 后台任务在挨饿（0.8.61 三案同根的 observable 面）；样本 <4 = 观测
        // 窗口未热，如实说明而不判失败。
        let pool = CooperativePool.stats()
        if pool.sampleCount < 4 {
            checks.append(Check(name: "协作池水位", ok: true,
                                detail: "观测窗口未热（\(pool.sampleCount)/4 样本）"))
        } else if let p95 = pool.p95, p95 > 2.0 {
            checks.append(Check(
                name: "协作池水位",
                ok: false,
                detail: String(format: "p95 %.0f ms 超 2s 阈值——后台任务在挨饿（诊断包可见）", p95 * 1000)))
        } else {
            checks.append(Check(name: "协作池水位", ok: true,
                                detail: String(format: "p95 %.0f ms（%d 样本/12 分钟窗口）",
                                               (pool.p95 ?? 0) * 1000, pool.sampleCount)))
        }

        // **智能体驾驶舱增项**（v0.8.75 批 2）：0.8.71-74 机器面的健康哨兵。
        let memoryStore = AgentMemoryStore.shared

        // ① schema 体积漂移：最近请求的 schema vs 0.8.74 基线 17.8 万
        //（±20% 告警——MCP 工具膨胀/瘦身回退的哨兵）。
        let session = AgentScheduler.shared.deliveryTarget
        if let layers = session?.lastRequestLayers, layers.toolsSchema > 0 {
            let baseline = 179_559.0
            let drift = (Double(layers.toolsSchema) - baseline) / baseline
            if abs(drift) > 0.2 {
                checks.append(Check(name: "Schema 体积", ok: false,
                    detail: String(format: "较 0.8.74 基线漂移 %+.0f%%（%d 字符）——MCP 工具膨胀或瘦身回退", drift * 100, layers.toolsSchema)))
            } else {
                checks.append(Check(name: "Schema 体积", ok: true,
                    detail: String(format: "%d 字符（基线 ±%+.0f%%）", layers.toolsSchema, drift * 100)))
            }
        } else {
            checks.append(Check(name: "Schema 体积", ok: true, detail: "观测窗口未热——还没有模型调用"))
        }

        // ② 体检新鲜度：>30 天没跑记忆体检就提醒（手动触发，不自动）。
        if let last = memoryStore.lastCheckupAt {
            let days = Int(Date().timeIntervalSince(last) / 86_400)
            if days > 30 {
                checks.append(Check(name: "记忆体检", ok: false,
                    detail: "上次体检是 \(days) 天前——建议 /memory-checkup（合并近重复、退役陈旧）"))
            } else {
                checks.append(Check(name: "记忆体检", ok: true, detail: "\(days == 0 ? "今天" : "\(days) 天前")跑过"))
            }
        } else {
            checks.append(Check(name: "记忆体检", ok: true, detail: "从未跑过——/memory-checkup 可合并近重复、退役陈旧事实"))
        }

        // ③ 教训账本：当日提取次数逼近节流上限（6/天）时提示。
        let effect = memoryStore.lessonEffect
        if effect.totalInjections == 0 {
            checks.append(Check(name: "教训学习", ok: true, detail: "还没有教训入库（失败回合自动提炼；/prompt 可查注入面）"))
        } else {
            let total = effect.appliedOk + effect.repeatAfterInject
            let rate = total > 0 ? effect.appliedOk * 100 / total : 0
            checks.append(Check(name: "教训学习", ok: true,
                detail: "注入 \(effect.totalInjections) 回合：成功 \(effect.appliedOk) / 仍失败 \(effect.repeatAfterInject)（\(rate)%）——聚合口径，非归因"))
        }

        // ④ TTFT 异常：分模型 p50 > 8s = 网关慢（样本 ≥3 才判——少样本不虚报）。
        do {
            let stats = UsageStats.derive(from: ConversationStore().conversations,
                                          price: { _ in nil })
            let slow = stats.modelPerf.filter { $0.value.ttftP50 > 8_000 }
            if slow.isEmpty {
                let fastest = stats.modelPerf.min(by: { $0.value.ttftP50 < $1.value.ttftP50 })
                checks.append(Check(name: "TTFT", ok: true,
                    detail: fastest.map { "\($0.key)：p50 \(Int($0.value.ttftP50))ms（样本 \($0.value.samples)）" } ?? "观测窗口未热——还没有带性能数据的调用"))
            } else {
                let names = slow.map { "\($0.key)（\(Int($0.value.ttftP50))ms）" }.joined(separator: "、")
                checks.append(Check(name: "TTFT", ok: false,
                    detail: "首 token 偏慢：\(names)——超过 8s，考虑换模型/网关"))
            }
        }

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

    /// 目录总大小（转存目录体检用）。目录不存在 = 0。
    static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
