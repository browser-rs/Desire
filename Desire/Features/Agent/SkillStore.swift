import Combine
import Foundation
import os

/// SKILL.md-style skill system (progressive disclosure, Claude Code style):
/// every skill is a markdown file with YAML-ish frontmatter —
///
///     ---
///     name: mux-audio-video
///     description: 用 ffmpeg 合成视频轨与音频轨
///     ---
///     (full instructions shown to the agent only when it calls useSkill)
///
/// The NAME+DESCRIPTION list rides in every agent prompt; the full body is
/// loaded on demand via the `useSkill` tool. Skills live in
/// `Application Support/Desire/skills/*.md` — users can add their own by
/// dropping files in; three working examples are seeded on first launch.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    private static let log = Log.agent

    struct Skill: Identifiable {
        let name: String
        let description: String
        let url: URL
        var id: String { name }
    }

    @Published private(set) var skills: [Skill] = []

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Desire/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        seedExamplesIfNeeded()
        reload()
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.directory, includingPropertiesForKeys: nil
        ) else { return }
        skills = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Self.parse(text, url: url)
            }
            .sorted { $0.name < $1.name }
    }

    func body(for name: String) -> String? {
        guard let skill = skills.first(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: skill.url, encoding: .utf8)
    }

    /// Parses frontmatter (`name:` / `description:`) — falls back to the
    /// file name and first non-empty line for loose files.
    static func parse(_ text: String, url: URL) -> Skill {
        var name = url.deletingPathExtension().lastPathComponent
        var description = ""

        if text.hasPrefix("---"),
           let end = text.range(of: "\n---") {
            let frontmatter = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
            for line in frontmatter.components(separatedBy: .newlines) {
                if line.hasPrefix("name:") {
                    name = line.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("description:") {
                    description = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                }
            }
        } else {
            description = text.components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
        }
        return Skill(name: name, description: description, url: url)
    }

    // MARK: - Seeded examples

    /// Seeds any missing example skill. Per-FILE check: new built-in
    /// examples reach existing installs automatically.
    private func seedExamplesIfNeeded() {
        let fm = FileManager.default
        var seeded = 0
        for (name, description, body) in Self.exampleSkills {
            let file = Self.directory.appendingPathComponent("\(name).md")
            guard !fm.fileExists(atPath: file.path) else { continue }
            try? Self.exampleText(name: name, description: description, body: body)
                .write(to: file, atomically: true, encoding: .utf8)
            seeded += 1
        }
        if seeded > 0 {
            Self.log.info("seeded \(seeded, privacy: .public) example skills")
        }
    }

    private static func exampleText(name: String, description: String, body: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---
        \(body)
        """
    }

    private static let exampleSkills: [(String, String, String)] = [
        ("clean-page-ads",
         "页面广告清理：AI 识别广告元素 → 列出候选与理由 → 用户确认 → 永久屏蔽该站",
         """
        ## 流程
        1. `findAdCandidates` 扫描当前页，拿到带**理由**的候选（class/id 关键词、跨域 iframe、
           广告联盟域名、覆盖层 z-index、标准广告位尺寸、\"广告/Sponsored\" 文案）。
        2. 把候选**讲给用户听**（第几条、多大、在哪、为什么判定），让用户挑——不要自己全选。
        3. 用户确认后调用 `blockElements {selectors:[…]}`：规则写进 ElementBlockStore，
           **立刻**注入隐藏 CSS，且以后每次打开这个站点都生效。
        4. 若某些广告是**请求级**的（候选里的 src 指向广告联盟域名），可以一并传
           `blockRequests:[\"*://ads.example.com/*\"]` 做网络层拦截。
        5. 改完让用户刷新确认；若有误伤，用 listBlockedElements / unblockElement 撤掉。
        ## 规则
        - 只屏蔽广告与覆盖层；**不要**屏蔽正文、导航、登录框（用户没确认的一律不删）。
        - 候选是启发式的：宁可少而准，报出理由让用户判断。
        """),
            ("order-food-delivery",
         "外卖点餐（美团/饿了么等）：搜索店铺 → 选菜加购 → 确认订单 → 用户支付",
         """
        ## 流程
        1. navigate 外卖平台 → waitForText 店铺列表。
        2. 按用户口味搜索店铺（getFormFields/findElements 定位搜索框）。
        3. 逐个加菜：click 加购按钮；用 askUser 确认规格选择（大小份/辣度）。
        4. 进入购物车核对明细与总价，向用户复述订单。
        5. 填地址（已有历史地址直接选；没有则 askUser）。
        6. 到支付页**停止**：askUser 请用户自行完成支付（密码/面容绝不代操作）。
        ## 规则
        - 绝不代替用户支付；金额变动必须向用户复述确认。
        """),
        ("online-shopping",
         "购物助手（淘宝/京东/拼多多等）：找品比价 → 加购/下单 → 用户支付",
         """
        ## 流程
        1. 搜索商品 → getTables/getImages 提取商品列表做结构化对比（价格/销量/评分）。
        2. 用 askUser 让用户从候选中选定商品。
        3. 选规格（颜色/尺码）→ 加购物车 或 立即购买。
        4. 结算页核对：商品、地址、优惠券（有券先申请用券）、总价。
        5. 提交订单后停在支付页，askUser 请用户支付。
        ## 规则
        - 比价结果可 writeFile 导出 CSV；支付永远由用户完成。
        """),
        ("job-application",
         "招聘网站求职/投简历（BOSS/拉勾/LinkedIn）：搜索职位 → 匹配分析 → 投递",
         """
        ## 流程
        1. 按用户的职位关键词搜索 → getTables 提取职位列表（薪资/要求/公司）。
        2. 结合记忆中的用户画像给出匹配分析，askUser 选定目标职位。
        3. 沟通/申请：已填好的简历直接投递；需要填表时 getFormFields + fill 完成姓名/经验/期望薪资（数字类字段先 askUser 确认）。
        4. 投递后 waitForText 成功提示，记录已投递列表，writeFile 汇总。
        ## 规则
        - 简历附件用 setUploadFile；期望薪资等关键数字必须 askUser 确认。
        """),
        ("prototype-design",
         "原型设计：把需求变成 HTML 高保真原型并可视化迭代",
         """
        ## 流程
        1. 和用户确认页面结构/风格（askUser：用途、目标设备、风格倾向）。
        2. writeFile(path: "prototype/page.html", content: 完整单文件 HTML —— 内联 CSS/JS，移动端优先，使用系统字体与柔和阴影)。
        3. navigate file://<工作目录>/prototype/page.html 预览。
        4. screenshot 看效果 → 按反馈迭代（每次改完重新 writeFile + navigate）。
        5. 完成后报告文件路径，说明可双击在浏览器打开。

        ## 设计规则
        - 现代简约：大留白、圆角卡片、克制配色（一个主色+中性灰）。
        - 单文件自包含，不依赖外部 CDN。
        """),
        ("automation-testing",
         "网页自动化测试：把浏览器操作变成可重复的断言并输出测试报告",
         """
        ## 流程
        1. 和用户确认测试范围，用 updatePlan 列出用例清单。
        2. 每个用例：navigate → 操作（click/fill/type）→ 断言（waitForText / getPageText 包含期望 / findElements 计数）。
        3. 记录 PASS/FAIL 与失败原因截图（screenshot）。
        4. 全部执行后 writeFile 输出 Markdown 测试报告（用例/期望/实际/结果表）。
        ## 规则
        - 断言失败先重试一次再判 FAIL（网络抖动）。
        - 涉及支付的流程只测到支付页出现为止。
        """),
        ("publish-bilibili",
         "把本地视频发布到哔哩哔哩（B站）：自动上传 + 填标题/简介/标签 + 投稿",
         """
        ## 前置
        - 用户已登录 B 站（未登录时 navigate 到 passport.bilibili.com 提示扫码）。
        - 视频文件路径已确认。

        ## 流程
        1. setUploadFile(path: "<视频绝对路径>")
        2. navigate https://member.bilibili.com/platform/upload/video/frame
        3. waitForText "上传" 后，click {text: "上传视频"} → 已锁定的文件自动提交上传。
        4. 填写稿件信息：标题（默认是文件名，按用户要求修改）、简介（contenteditable，用 fill）、分区、标签（type 后按回车逐个添加）。
        5. 按用户要求设置封面/定时发布，默认立即投稿。
        6. waitForText "投稿成功" 或 "审核中" → 向用户报告稿件链接。

        ## 注意
        - 上传大文件耗时：用 waitForText 或 wait 轮询进度，别盲等。
        - 二创/转载内容需按用户指示选择"转载"并填来源。
        """),
        ("publish-youtube",
         "Publish a local video to YouTube (Studio upload flow, title/description/audience/publish)",
         """
        ## Prerequisites
        - User is signed in (if a consent/sign-in page appears, ask the user to complete it manually).

        ## Flow
        1. setUploadFile(path: "<absolute video path>")
        2. navigate https://studio.youtube.com/channel/upload
        3. Wait for the upload dialog, then click "SELECT FILES" (or the upload arrow) → the armed file auto-submits.
        4. While uploading, fill Title (the filename becomes the default — replace per user), Description (contenteditable → fill), playlist if asked.
        5. Audience step: pick "No, it's not made for kids" (confirm with user if unclear) → Next ×3.
        6. Visibility: Public (default per user) → Publish. waitForText "Video published" → report the video link.

        ## Notes
        - Processing continues after publishing; tell the user HD quality appears once processing completes.
        """),
        ("publish-douyin",
         "把本地视频发布到抖音网页版（创作者平台上传 + 标题/封面 + 发布）",
         """
        ## 前置
        - 用户已登录抖音创作者平台（未登录提示扫码，等待完成）。

        ## 流程
        1. setUploadFile(path: "<视频绝对路径>")
        2. navigate https://creator.douyin.com/creator-micro/content/upload
        3. 点击上传区域 → 文件自动提交。
        4. 填写标题/简介（contenteditable → fill），按需设置封面、允许保存等开关。
        5. click {text: "发布"} → waitForText "发布成功" 或跳转作品管理页 → 报告结果。

        ## 注意
        - 抖音对横竖屏和时长有限制，超限会报错——把页面错误读给用户。
        """),
        ("media-pipeline",
         "媒体流水线一句话编排：提取页面视频/音频 → 下载 → 转码/抽音轨/合成",
         """
        ## 流程
        1. listPageVideos 提取当前页面的媒体（blob 播放器会嗅探出真实 CDN 地址）。
        2. 多个候选时 askUser 让用户选定（说明清晰度/格式/大小）。
        3. downloadMedia 下载到 Downloads（直接文件与 m3u8 都支持）。
        4. 按用户要求后处理（video-convert / mux-audio-video 技能）：
           转码、压缩、抽音轨、合成双轨。
        5. 报告输出路径与大小。

        ## 失败自愈
        - 下载失败/超时：换 listPageVideos 列表里的下一个源（通常有降清晰度
          备选）；m3u8 失败可试 ffmpeg 直连（runCommand ffmpeg -y -i <url> …）。
        - ffmpeg 未安装：告诉用户 runCommand brew install ffmpeg。
        - 平台限速/风控：提示用户登录后重试。
        """),
        ("mux-audio-video",
         "用 ffmpeg 把 downloadMedia 下载的 YouTube 双轨（video-only + audio-only）合成为一个带声音的完整文件",
         """
        ## 前置
        视频轨与音频轨来自 downloadMedia（YouTube 1080p+ 是 DASH 分轨）。

        ## 步骤
        1. runCommand ffprobe -v error -show_entries format=duration -of default=nw=1 <视频文件>
        2. 合成（流复制，零转码损耗）:
           runCommand ffmpeg -y -i <视频文件> -i <音频文件> -c copy -map 0:v:0 -map 1:a:0 <输出>.mkv
        3. 验证输出时长与两条输入一致，向用户报告输出路径。

        ## 注意
        - 输出用 .mkv 可避免部分 fMP4+AAC 组合的时长元数据问题。
        - 文件名包含空格时作为单个 argv 元素传入即可，无需手工加引号。
        """),
        ("video-convert",
         "用 ffmpeg 转码 / 压缩 / 抽取音轨 / 生成 GIF",
         """
        ## 常用命令模板（经 runCommand 执行）
        - 压缩到 720p: ffmpeg -y -i <输入> -vf scale=-2:720 -c:v libx264 -crf 26 -preset medium -c:a copy <输出>.mp4
        - 抽取音轨:    ffmpeg -y -i <输入> -vn -c:a libmp3lame -q:a 4 <输出>.mp3
        - 生成 GIF:    ffmpeg -y -ss <开始秒> -t <秒数> -i <输入> -vf fps=12,scale=480:-2 <输出>.gif
        - 提取片段:    ffmpeg -y -ss <开始秒> -t <秒数> -i <输入> -c copy <输出>.mp4

        ## 规则
        - 先 runCommand ffprobe 确认输入流，再选参数。
        - 转码耗时长，告诉用户预计等待。
        """),
        ("brew-tool",
         "用 Homebrew 搜索 / 安装 / 管理系统工具（brew 必须已安装）",
         """
        ## 常用命令（经 runCommand 执行）
        - 搜索:   runCommand brew search <关键词>
        - 安装:   runCommand brew install <包名>
        - 信息:   runCommand brew info <包名>
        - 清理:   runCommand brew cleanup

        ## 规则
        - 安装前必须向用户确认包名与用途。
        - 安装可能超过 2 分钟，把 timeoutSec 提高到 600。
        - 安装完成后用 resolve 过的工具名再次验证可执行。
        """),
    ]
}
