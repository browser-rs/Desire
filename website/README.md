# Desire 产品介绍页

**已部署生产：<https://desire.mankong.icu/>**（主 README 顶部与 Download
段已指向此地址）。英文页：**<https://desire.mankong.icu/en/>**。

单文件静态页：`index.html`（中文）+ `en/index.html`（英文）。无构建、无外部
依赖、零 CDN——字体全部用系统内置（Hoefler Text / 宋体 / 楷体 / SF），国内
访问无阻碍。桌面与移动端自适应，动效纯 CSS + 一段 IntersectionObserver，
支持 `prefers-reduced-motion` 与无 JS 降级（渐进增强）。

## 本地预览

```sh
cd website && python3 -m http.server 8877
# 中文 http://127.0.0.1:8877/ · 英文 http://127.0.0.1:8877/en/
```

直接双击 `index.html` 也能看（无任何网络请求）。

## SEO / GEO 清单

### 基础（2026-09-26 首版，2026-11-11 增强）

- **品牌别名**：目标检索词 = `Desire Browser` / `Desire Agent Browser`
  （英文）。两处语言版本都要同时出现这两个词：`<title>`、description、
  hero 下的英文别名行、FAQ 首条（「是同一个东西吗」）、JSON-LD
  `alternateName`。**FAQ 的 JSON-LD 与页面可见问答必须逐字一致**（改一处
  必须改另一处）。
- **两语言 + hreflang**：`/`（zh-Hans）与 `/en/`（en）互相 `rel=alternate`
  hreflang，`x-default` 指向 `/en/`；两页 canonical 各自指向自己，页脚互相
  链接。sitemap 收录两页。
- 语义化结构（header·main·section·nav·footer、h1–h2 层级、FAQ 用原生
  `<details>`）；零外链资源（单文件内联 CSS，LCP 就是正文本身）。
- `<meta name="robots" content="index, follow, max-image-preview:large,
  max-snippet:-1">`；关键词 meta 只作辅助（Google 不使用，Bing 弱使用）。
- **favicon**：`favicon-16/32/48/96/192.png` + `apple-touch-icon.png` 由
  `Assets.xcassets/AppIcon` 的 1024 图缩放而来（sips）；Google 搜索结果与
  移动端书签都需要它。**改 App 图标时重新导出这几个文件**。
- **社交卡片**：完整 Open Graph（url / site_name / locale / locale:alternate
  / image 1200×630 + 尺寸与 alt）+ Twitter `summary_large_image`。
- **结构化数据**：JSON-LD `@graph` = WebSite + Organization + SoftwareApplication
  （BrowserApplication、alternateName、price 0、featureList、screenshot、
  releaseNotes）+ FAQPage。
- **GEO（AI 引擎）**：`llms.txt`（产品事实速览）、`robots.txt` 显式放行
  GPTBot / OAI-SearchBot / ClaudeBot / PerplexityBot / Google-Extended /
  Applebot / CCBot / Bytespider、`sitemap.xml`；问答里都是可引用的具体事实
  （版本、数量），不含营销空话。

### 被搜索引擎收录（站点侧之外的动作）

技术面之外，"搜得到"主要取决于**提交 + 外链 + 时间**。做完下面这些，Google
通常在几天到几周内收录；`Desire` 这个裸词竞争极大（重名产品极多），现实目标
是品牌组合词（`Desire Browser`、`Desire Agent Browser`）与类目词（`AI agent
browser macOS`、`agentic browser`）能排上。

1. **Google Search Console（必做，一次性）**
   - 用域名邮箱登录 <https://search.google.com/search-console> → 添加资源 →
     选「域名」→ 按提示在 DNS 加一条 TXT 验证（域名在自己手里，一次搞定）。
   - 提交 sitemap：`https://desire.mankong.icu/sitemap.xml`。
   - URL 检查 → 分别对 `/` 与 `/en/` 点「请求编入索引」。
   - 之后每周看「覆盖率/页面」报告：`已编入索引` 数量是唯一可信的口径。
2. **Bing Webmaster Tools**：<https://www.bing.com/webmasters>（可从 GSC
   一键导入）→ 提交同一个 sitemap。Bing 已收录该域名，提交后更新更快。
3. **IndexNow（Bing/Yandex 即时通知）**：仓库有
   `scripts/indexnow-ping.sh`；部署后跑一次即可（脚本会先校验
   `website/<key>.txt` 在线）。**Google 不使用 IndexNow**。
4. **外链（决定排名的最大变量，需要人来发）**
   - GitHub 仓库已填：description / homepage / topics（2026-11-11）；
     README 顶部的产品页链接是 Google 最认的那条权威链接。后续涨 Star 也
     直接提升权重。
   - 发帖/收录渠道（各一次，按性价比排序）：Hacker News（Show HN）、
     Product Hunt、Reddit r/macapps + r/MacOS、V2EX / 少数派 / 掘金 / 即刻、
     AlternativeTo、Slant、MacUpdate；开源导航（awesome-macos、
     awesome-browser 等）的 PR。
   - npm 包（`@browser-rs/dpp-sdk`）README 与 `homepage` 字段也指向产品页。
   - 任何一次发帖都会带来新外链与首批真实搜索行为——Google 对"有外链 +
   - 有点击"的新站收录显著更快。

### 部署注意

`og.jpg`、`robots.txt`、`sitemap.xml`、`llms.txt`、favicon 系列、
`apple-touch-icon.png`、IndexNow key 文件（`<32位hex>.txt`）必须位于**域名根
路径**才生效；`en/index.html` 必须落在 `/en/`。若只上传了 `index.html`，
把 `website/` 整个目录同步上线（`/en/` 目前在线上会回退成中文页——说明
`en/` 还没传上去）。

## 发布与更新

生产站点已上线：**<https://desire.mankong.icu/>**。更新页面 = 把改后的
`website/` 整个目录同步到该域名的托管源（nginx 目录 / Pages 源分支均可），
无构建步骤。首次接入方式（任选其一）：

- **GitHub Pages**：仓库 Settings → Pages → Source 选 GitHub Actions，
  用官方 Static HTML 工作流把 `website/` 发布即可；或推一个只有该目录的
  `gh-pages` 分支后选 Deploy from branch。
- **任意静态托管**：nginx / Cloudflare Pages / Vercel，把整个 `website/`
  目录作为站点根，无需任何构建配置。

## 改版注意

- 版本号出现在四处（中文英雄区 CTA、中文下载区、英文英雄区、英文下载区），
  发新版时一起改；下载按钮指向 `releases/latest`。
- **新增文件的常驻清单**（导出 App 图标时别漏）：`favicon-16/32/48/96/192.png`、
  `apple-touch-icon.png`。
- 文案与产品事实对应：功能宣称全部来自 README/CHANGELOG 已落地能力，
  不要加"即将推出"类空承诺。
