# Desire 产品介绍页

**已部署生产：<https://desire.mankong.icu/>**（主 README 顶部与 Download
段已指向此地址）。

单文件静态页：`index.html`（无构建、无外部依赖、零 CDN——字体全部用 macOS
内置的 Hoefler Text / 宋体 / 楷体，国内访问无阻碍）。桌面与移动端自适应，
动效纯 CSS + 一段 IntersectionObserver，支持 `prefers-reduced-motion` 与
无 JS 降级（渐进增强）。

## 本地预览

```sh
cd website && python3 -m http.server 8877
# 打开 http://127.0.0.1:8877/
```

直接双击 `index.html` 也能看（无任何网络请求）。

## 发布与更新

生产站点已上线：**<https://desire.mankong.icu/>**。更新页面 = 把改后的
`index.html` 重新上传到该域名的托管源（nginx 目录 / Pages 源分支均可），
无构建步骤。首次接入方式（任选其一）：

- **GitHub Pages**：仓库 Settings → Pages → Source 选 GitHub Actions，
  用官方 Static HTML 工作流把 `website/` 发布即可；或推一个只有该目录的
  `gh-pages` 分支后选 Deploy from branch。
- **任意静态托管**：nginx / Cloudflare Pages / Vercel，把整个 `website/`
  目录作为站点根，无需任何构建配置。

## 改版注意

- 版本号出现在两处（英雄区 CTA 与下载区），发新版时一起改；下载按钮指向
  `releases/latest`，只有文件名示例（安装步骤第 1 步）写死了版本号。
- 文案与产品事实对应：功能宣称全部来自 README/CHANGELOG 已落地能力，
  不要加"即将推出"类空承诺。
