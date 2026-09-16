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
