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
        /// SKILL.md / 单文件 md 的路径（body 读取源）。
        let url: URL
        /// **目录 skill**（2026-10-02 多文件支持）：目录根（含附属
        /// scripts/references）。单文件 skill 为 nil。
        let directory: URL?
        var id: String { name }

        init(name: String, description: String, url: URL, directory: URL? = nil) {
            self.name = name
            self.description = description
            self.url = url
            self.directory = directory
        }
    }

    /// 目录内 SKILL.md 之外的附属文件（相对路径 + 绝对路径），供 useSkill
    /// 结果列出、模型用 readFile 按需读取。
    static func companionFiles(in directory: URL) -> [(relative: String, absolute: String)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in en {
            let rel = url.path.dropFirst(directory.path.count + 1)
            if rel == "SKILL.md" { continue }
            out.append((String(rel), url.path))
        }
        return out.sorted { $0.0 < $1.0 }.map { (relative: $0.0, absolute: $0.1) }
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
        var loaded: [Skill] = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return Self.parse(text, url: url)
            }
        // **目录 skill**（多文件支持）：`<name>/SKILL.md`——附属文件经
        // useSkill 列出、readFile 按需读取。单文件与目录同名时目录优先
        // （目录是更完整的形态）。
        for dir in files where dir.hasDirectoryPath {
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            // 目录 skill 的 name = **目录名**（frontmatter name 若与目录名
            // 不同以目录名为准——目录即身份，附属文件相对它解析）。
            let description = Self.parse(text, url: skillFile).description
            let skill = Skill(name: dir.lastPathComponent,
                              description: description,
                              url: skillFile,
                              directory: dir)
            loaded.removeAll { $0.name == skill.name }
            loaded.append(skill)
        }
        skills = loaded.sorted { $0.name < $1.name }
    }

    // MARK: - 导入（zip / 目录 / 单 md，2026-10-02 多文件配套）

    enum ImportError: LocalizedError {
        case unsupported
        case noSkill
        case unpack(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: "Only .zip archives, skill directories, or .md files can be imported"
            case .noSkill: "No SKILL.md or .md file found in the package"
            case .unpack(let detail): "Couldn't unpack: \(detail)"
            }
        }
    }

    /// 统一导入入口：zip 解包（ditto）、目录直装、单 md 拷贝。技能名 =
    /// SKILL.md frontmatter name / 目录名 / 文件名。同名 = 覆盖更新。
    @discardableResult
    func importArchive(at url: URL) throws -> Skill {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.noSkill
        }
        let staging = fm.temporaryDirectory
            .appendingPathComponent("skill-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var sourceDir: URL?
        var singleFile: URL?
        if isDir.boolValue {
            // 目录：SKILL.md 在根 = 目录 skill；单 md = 散文件
            if fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
                sourceDir = url
            } else {
                let mds = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension.lowercased() == "md" } ?? []
                guard let md = mds.first else { throw ImportError.noSkill }
                singleFile = md
            }
        } else if url.pathExtension.lowercased() == "zip" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", url.path, staging.path]
            let errPipe = Pipe()
            proc.standardError = errPipe
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ImportError.unpack(String(err.suffix(200)))
            }
            // 解包后：根 SKILL.md / 根单 md / 唯一子目录的 SKILL.md
            if fm.fileExists(atPath: staging.appendingPathComponent("SKILL.md").path) {
                sourceDir = staging
            } else {
                let children = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
                let subdirs = children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }
                let withSkill = subdirs.first {
                    fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
                }
                if let withSkill {
                    sourceDir = withSkill
                } else {
                    let mds = children.filter { $0.pathExtension.lowercased() == "md" }
                    guard let md = mds.first else { throw ImportError.noSkill }
                    singleFile = md
                }
            }
        } else if url.pathExtension.lowercased() == "md" {
            singleFile = url
        } else {
            throw ImportError.unsupported
        }

        // 落位：目录整拷 / 单 md 拷贝；同名先删（= 更新）。
        let installed: Skill
        if let dir = sourceDir {
            // 技能名 = SKILL.md frontmatter name（有则用）；否则目录名。
            let skillFile = dir.appendingPathComponent("SKILL.md")
            let text = try String(contentsOf: skillFile, encoding: .utf8)
            let frontmatterName = Self.parse(text, url: skillFile).name
            let name = (frontmatterName != skillFile.lastPathComponent)
                ? frontmatterName : dir.lastPathComponent
            let target = Self.directory.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: dir, to: target)
            let description = Self.parse(text, url: skillFile).description
            installed = Skill(name: name, description: description,
                              url: target.appendingPathComponent("SKILL.md"), directory: target)
        } else if let md = singleFile {
            let text = try String(contentsOf: md, encoding: .utf8)
            let parsed = Self.parse(text, url: md)
            // parse 回落的名字 = md 文件名（可能是 imported.md 这种无语义名）
            // —— 无 frontmatter name 时用源文件名（去扩展名）。
            let finalName = parsed.name == md.lastPathComponent
                ? md.deletingPathExtension().lastPathComponent
                : parsed.name
            let target = Self.directory.appendingPathComponent("\(finalName).md")
            try text.write(to: target, atomically: true, encoding: .utf8)
            installed = Skill(name: finalName, description: parsed.description, url: target)
        } else {
            throw ImportError.noSkill
        }
        reload()
        Self.log.info("skill imported: \(installed.name, privacy: .public) (\(installed.directory != nil ? "directory" : "file", privacy: .public))")
        return installed
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

        ## 批量（列表页）
        - 卡片**在列表页内直接播放**的（feed/瀑布流）：downloadAllPageVideos
          一次入队当前页全部嗅探到的视频。
        - 每项要**进详情页**才有视频的：先滚动/翻页收集详情页地址清单，
          askUser 确认清单，再 downloadVideoList（隐藏浏览器逐页解析，
          Cloudflare 自动过；交互式验证会先自动点击，不成才弹窗给用户）。
        - 两者都不等待：listBatchDownloads 查进度，批次完成会通知。
        - **队列管理用 manageBatchDownloads**：暂停/恢复整批、skip 掉排队中
          的单项、向既有批次追加新任务（去重、序号接续）。
        - **失败项不要用 downloadMedia 单独补**（会把文件散落到 Downloads
          根目录）——引擎会在同批同文件夹自动重试（换新签名地址）；自动
          重试耗尽后用 retryBatchDownloads 重跑失败项。
        - **磁盘保护是自动的**：剩余空间低于预留线（默认 5GB，可改）会挂起
          整批并提醒用户，空间恢复后自动续跑；不用你盯。
        - 命名/保存位置遵循用户偏好（默认清洗标题、落 ~/Downloads/<host>/）；
          用户表达过偏好的用 naming/folderName 参数传下去，引擎会记住并写入
          长期记忆。

        ## 失败自愈
        - 下载失败/超时：换 listPageVideos 列表里的下一个源（通常有降清晰度备选）。
        - **HLS 不需要手动跑 ffmpeg**：downloadMedia 自己判定——装了 ffmpeg 就直接
          下载并转封装成 MP4（含音轨分离的站点）；没装 / 是直播 / ffmpeg 失败则回退
          内置下载器，内置路径产出 TS 时若机器上有 ffmpeg 还会自动转成 MP4。
        - 产物是 `.ts` 才说明这台机器没装 ffmpeg：建议用户
          `runCommand brew install ffmpeg`，装完重下即可拿到 MP4。
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
        ("create-dpp-adapter",
         "为任意网站创建 DPP 适配包：让智能体在该站读结构化数据、执行声明动作（用户说「帮我适配这个网站」时使用）",
         """
        ## 核心原则：先问清楚，再动手
        大站点功能很多（文章/评论/点赞/收藏/个人页/消息…），**不是全部都要适配**。
        用户说"帮我适配这个站"时，先弄清他要什么，不要自作主张全站适配。
        ## 流程
        1. **澄清需求**（askUser）：在目标站点的典型页面上用 executeJS 探查页面
           有哪些功能块（正文/列表/评论/点赞/收藏/表单…），把**可适配的能力清单**
           列给用户——「这个站点我可以适配：A 文章阅读、B 评论浏览、C 点赞、
           D 发评论。你要哪些？」让用户勾选，不要替用户决定。
        2. **逐项验证**：只对用户选中的功能做 DOM 探查——对标题/正文/列表项/按钮
           逐个试 document.querySelector('候选选择器')，确认取得到内容。选择器
           保守多候选（逗号并列），覆盖常见 class 改版。
        3. **范围确认**（askUser）：适配范围二选一让用户定——整站通用（hosts 全域）
           还是仅特定页面（pathPrefixes，如只文章页 /post/）。大站点强烈建议
           按页面类型拆多个包（各包独立启停，改版互不影响）。
        4. 生成 saveDPPAdapter：views 只含用户要的功能；用户要的动作（点赞/
           评论/收藏…）声明进 actions，run 步骤用已验证的选择器，effects 如实
           标注（persist/出站 = 强制审批，绝不为了省事标 local）。
        5. 落盘后告知用户：对新加载页面生效（原生声明优先，本包只补空白）；
           persist/outbound 动作每次使用仍需批准；后续不想要可在设置里停用。
        ## 规则
        - **先问后做**：功能清单让用户勾选；范围（全站/页面类型）让用户定。
          用户明确说"全部"才做全站。
        - 只声明验证过的选择器与动作；没验证的宁可不写。
        - 选择器探测先试语义化 class（[class*=title]），再试结构（h1、article）。
        - SPA 站点：路由切换后重查一次，视图要兼容多个路由形态时用多候选。
        - 不确定就参考内置包（juejin/v2ex/cnblogs/hackernews/wikipedia/stackoverflow）。
        """),
        ("promotion",
         "运营/自推广：按既定目标为 Desire 或用户的账号起草并发布推广内容（技术社区帖/沸点/短文），发布前必须用户确认，发后记录数据并沉淀经验",
         """
        ## 何时用
        用户说「推广/宣传/推销」「按运营目标发帖」「给新版本写篇介绍」时。

        ## 流程
        1. promotionBrief 拿运营工作台：目标与进度、**账号**、待审草稿、已发清单
           （避免重复选题）、**历史经验**（必读——先人的坑别重踩）、版本与链接。
           没有目标就先 askUser 定一个（标题/领域/平台/条数/截止），用 promotionGoal 建好再动笔。
           还没定题时：先头脑风暴 3-5 个选题存进选题库（promotionSave status=idea，只给标题+平台），让用户挑。
        2. **事实底稿**：用 readFile/runCommand 读仓库 CHANGELOG.md（最新版本段）与
           docs/，只写查得到的事实——版本号、功能名、链接；产品页
           desire.mankong.icu 的能力清单可作参考。
        3. **起草**：按平台改写（参考历史经验里的平台偏好）。技术长文（掘金/博客园）：
           解决什么问题 → 怎么用 → 真实代码片段；社区短帖（V2EX/沸点）：一段话说清 + 链接；
           英文社区（Hacker News/Reddit）：English, technical angle first, no marketing tone。
           草稿完整贴给用户看，askUser 确认或按反馈改。
        4. **发布**（出站不可逆、逐次审批）：用浏览器已登录的会话——有 DPP 适配包
           走适配动作（如 juejin-compose 的发沸点/写文章），没有就 navigate 到发布页
           用 fill/click 填标题与正文；提交前把最终稿再给用户过目一眼。
        5. promotionSave 记录三态流水线：选题 idea → 草稿 draft（用 `id` 可直接把选题更新
           为草稿；想排期就带 `plannedFor: yyyy-MM-dd`）→ 发布 published + URL。
        6. **数据回收**：隔一段时间回访帖子页（适配包视图或 getPageText 读浏览/点赞/
           评论数），promotionMetrics 写回——**多采几次**才形成增长曲线（快照序列）。
        7. **周报**：promotionReport 生成周报底稿（目标进度/账号增长/本周表现/选题草稿/
           新增经验），补上「下周建议」后交付用户；日常采集与每周复盘可让用户开
           「运营」页里的两个自动化开关。

        ## 规则
        - 事实纪律：只写 CHANGELOG/仓库/产品页里验证过的内容；不虚构数据、
          不编用户评价、不承诺时间表。
        - 语气：真诚的技术分享（讲清它解决什么问题），不是广告腔；同一平台
          避免重复发同一内容；尊重站点版规（别刷屏）。
        - **发布三步不能省**：起草 → 用户确认 → 提交。persist/outbound 的适配动作
          每次都会弹审批——这是设计，不是阻碍。
        - 一帖聚焦一两个功能（先读 CHANGELOG 最新段挑），别罗列全部能力。
        """),
        ("media-operations",
         "自媒体运营专项：账号数据追踪、内容排期产出、发布与互动、复盘沉淀经验（用户说「运营我的账号/涨粉/做内容」时使用）",
         """
        ## 何时用
        用户说「运营我的 XX 账号」「涨粉」「做内容/排期」「回复评论」时。
        **这是替用户运营他自己账号的专项**（与 promotion 技能的区别：那个推广
        Desire，这个经营用户的账号）。

        ## 流程
        1. promotionBrief 读工作台：目标（domain=media）、账号与最新数据、经验。
           没有账号先 promotionAccountSave 建档（platform/handle/url，domain 传 media）；
           没有目标先 askUser 定（涨粉目标/内容方向/条数/周期）后 promotionGoal 建档。
        2. **采集基线**：navigate 账号主页（创作中心/个人页）读 粉丝/浏览 数字，
           promotionAccountMetrics 记一条——**从建档起就定期采**，趋势是运营的命根。
        3. **内容排期**：按目标定 3-5 个选题（结合历史经验与账号定位），列给
           askUser 挑；每个选题给出平台形态（长文/图文/短动态）与发布时机建议。
        4. **创作与发布**：选题先入选题库（status=idea）让用户挑；挑中的立为草稿
           （status=draft，可带 plannedFor 排期）→ 用户确认 → 发布 → promotionSave
           更新为 published + URL。配合「运营」页的每日采集/每周复盘开关，
           定期用 promotionReport 出周报。
        5. **互动**：按用户要求回复评论/私信（getComments 读、fill+click 回）；
           对外回复前把回复文本给用户看（站内语气规范/避免翻车）。
        6. **复盘**：对比账号/帖子快照增长，把「什么内容、什么时候发、效果如何」
           写成 promotionLesson（可复用的才写）；每周可用「运营复盘」定时任务自动跑。

        ## 规则
        - 数据只从页面实读，不估算不编造（粉丝数、阅读数一律现场取）。
        - 涨粉靠内容质量与持续产出，不刷量、不做互赞互粉这类违规操作。
        - 评论区互动保持人设一致（问用户要语气偏好，存进账号 note）。
        - 一条内容先给事实与大纲让用户拍板，别直接生成万字长文让用户改。
        """),
        ("ecommerce-operations",
         "电商运营专项：商品/库存/价格巡检、订单与评价关注、竞品比价、数据复盘（用户说「运营我的店」「盯着价格/库存/差评」时使用）",
         """
        ## 何时用
        用户说「运营我的店/宝贝」「盯价格」「看库存」「回评价」「比价」时。

        ## 流程
        1. promotionBrief 读工作台：目标（domain=ecommerce）、店铺账号、经验。
           先 promotionAccountSave 建档（店铺，domain 传 ecommerce）；目标由
           askUser 定（盯什么：价格/库存/差评/销量）。
        2. **巡检（读）**：navigate 商家后台/商品页——列表页用 getTables/getPageText
           （有 DPP 适配包用适配视图）读 价格/库存/销量/评价；每次采完用
           promotionMetrics（帖子台账）或 promotionAccountMetrics（店铺）记快照。
           **长期盯价/盯库存**：建议用户在「页面监视」里给商品页加一条（URL + 间隔 +
           AI 分析），到点自动比对变化并通知——比每天人工看省事。
        3. **变动处置要用户点头**：改价、下架、改标题这类写操作**必须**先列出
           「当前值 → 建议值 + 理由」给 askUser，批准后才动手（走站点自家界面
           的 fill/click；persist 类动作照走审批链）。
        4. **评价**：新差评/咨询优先处理——读出来、拟好回复给用户过目再发；
           连续性问题（某规格老被吐槽）写进 promotionLesson。
        5. **比价**：竞品页用 crewDispatch 并行比价（多个链接各派一个 worker），
           汇总价差与活动后写入台账。
        6. **复盘**：销量/价格/评价的趋势写成经验，供选品与定价参考。

        ## 规则
        - **绝不自作主张改动商品**（价、库存、上下架全是钱）：建议 → 用户确认 → 执行。
        - 支付/账务页面只读不填；任何涉及资金的确认一律交还用户本人。
        - 数据只从页面实读；比价结果标注采集时间（价格会变）。
        - 店铺后台多标签操作时注意账号切换（别把 A 店的操作做到 B 店）。
        """),
    ]
}
