# v0.8.43 规划稿（2026-11-04）—— 图片编辑收官 + 阅读器 3.0 + 四主题常规

> v0.8.41–42 把图片编辑做成了专业级（管线/图层/修复刷/套索/魔棒/LUT/AI/批量/水印/
> EXIF）。本版收尾编辑器余项（透视校正/拼图合成/几何非破坏化/快捷键全流程/
> 回发 Remote）+ 新增阅读器 3.0（逐段朗读 TTS / 翻译对照 / 全文搜索升级）+
> 四主题常规。体量适中、独立可发版。

## 一、现状核实

图片编辑器余项（从 v0.8.41/42 推迟）：
- 透视校正（四角拖拽 → CIPerspectiveCorrection）——体量大，一直推迟。
- 拼图合成（水平/垂直拼接，gap 可调）。
- 几何非破坏化（rotate/crop/resize 改成管线操作，不再一次性烙图）。
- 快捷键全流程（V/M/L/W/B/E + ⌘⇧E + 空格临时原图）。
- 回发 Remote（编辑完成 → sendToPhone）。
- 社交尺寸裁剪预设（已落地，不再重复）。

阅读器现状（v0.8.34–36）：
- EPUB/TXT/CBZ/MOBI/AZW3/FB2 + 分页阅读器 + 3D 翻页。
- 双语翻译对照（迭代 2）、逐词朗读 TTS（迭代 2）、全文搜索（迭代 2）。
- 笔记/书签/划词高亮/摘录（v0.8.35/37）。

## 二、目标

1. 图片编辑器正式收官（透视 + 拼图 + 几何管线化 + 快捷键 + 回发 Remote）。
2. 阅读器 3.0：逐段朗读（按段落高亮跳转）、双语翻译对照升级、全文搜索升级。
3. 四主题常规覆盖。

## 三、四主题

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 阅读器 3.0（逐段朗读 + 段落高亮跳转 + 翻译对照升级） |
| ② Agent 基础 | 图片编辑 Agent 工具族补齐（`cropImage`/`flipImage`/`resizeImage`） |
| ③ 融合 | 编辑完成回发 Remote（kind=edited，从编辑器直接推）；阅读器高亮同步升级 |
| ④ 替人干活 | 拼图合成 + 透视校正（一键操作 + Agent 工具）；批量水印已完成不再重复 |

## 四、Track A：图片编辑收官

### A1. 透视校正

- 工具栏「Perspective」→ 画布四角拖拽手柄（overlay 蓝色角标）。
- `CIPerspectiveCorrection` 单应性矫正（输入四角归一化坐标）。
- 应用 = 烙图（可撤销）。
- 验收：斜拍文件/白板 → 拖四角 → 输出正面视角无黑角。

### A2. 拼图合成

- `ImageMergeCore`：水平/垂直拼接，对齐边、gap（0–20px，白色填充）、
  高度/宽度自动对齐（短边缩放）。
- Agent 工具 `mergeImages(paths[], direction, gap)`：返回输出路径。
- 验收：两张不同高度图水平拼接 → 短边等高缩放，gap 可见可调。

### A3. 几何非破坏化

- pipeline op 新增 `.geometry`（rotate90 cw/ccw、flipH/V、crop rect、resize）。
- 渲染器有序应用几何 + 调节 + 滤镜 + 选区。
- 撤销/重做与历史面板跟随管线快照（不再直接 push CGImage）。
- 验收：旋转 → 调节 → 裁剪 → 撤销回旋转前，调节参数保留。

### A4. 快捷键全流程 + 回发 Remote

- V 选择 / M 马赛克 / L 套索 / W 魔棒 / B 画笔 / E 清选区 / ⌘⇧E 导出 /
  空格临时原图（已落地，改为确认面板列出）。
- 回发 Remote：保存/导出后「Send to Phone」按钮（已落地，确认面板不再重复）。

## 五、Track B：阅读器 3.0

### B1. 逐段朗读

- TTS 按段落而非逐词：段落高亮 + 播放完成后自动跳下一段。
- 段落边界检测（DOM `<p>`/`<div>` 或 PDF 文本块）。
- 播放/暂停/上一段/下一段按钮固定在阅读器底部。
- 语速/音调可调。

### B2. 翻译对照升级

- 现有双语翻译（迭代 2）从"逐词弹窗"升级为"段落后插入翻译段"（-inline）。
- 翻译缓存（同一段落不重复请求）；清除翻译按钮。
- 验收：EPUB 双语对照 → 段落高亮/隐藏/清除。

### B3. 全文搜索升级

- 搜索结果点击跳转 + 上下文预览（当前只有列表跳转）。
- 搜索高亮在页面上可见（标记 `<mark>`）。

## 六、Track C：Agent 工具族补齐

- `cropImage(path, x, y, w, h)`
- `flipImage(path, direction)`
- `resizeImage(path, width, height)`
- 全部走 Agent 工作区路径校验；`write: true`。

## 七、批次

- **批 1**：A3 几何非破坏化 + A4 快捷键确认/回发 Remote。
- **批 2**：A1 透视校正 + A2 拼图合成 + C Agent 工具补齐。
- **批 3**：B1 逐段朗读 + B2 翻译对照升级 + B3 全文搜索升级。
- 全程 harness 纯逻辑测试同步；每批 Debug/Release 零警告。

## 八、不做

- 生成式 inpaint/扩展填充；通道级调色；RAW 开发。
- 阅读器书内绘图（canvas 注入）；视频内嵌字幕翻译。

## 九、发版口径

- 用户说「发」才发；CHANGELOG 只用 `scripts/changelog.py add`。
- 发版前：harness + Debug/Release clean 零警告 + 编辑器/阅读器手测验收清单。

## 进度（2026-11-04）

- **批 1（几何非破坏化）完成**：pipeline op 新增 `.geometry`（rotate90cw/ccw、
  flipH/V），渲染器有序应用几何 + 调节 + 滤镜 + 选区；编辑器 rotate/flip 按钮
  接入管线。快捷键与回发 Remote 均已在前版确认可用（⌘⇧E 导出、Send to Phone
  按钮已落地）。harness 2776/0，Debug/Release clean 零警告。
- **批 2（透视/拼图/Agent 补齐）下一批**。

## 进度（2026-11-05）

- **批 1（几何非破坏化）完成**：pipeline op `.geometry` + 渲染器有序应用 + 编辑器
  rotate/flip 接入管线。harness 2776/0，Debug/Release 零警告。
- **批 2（透视/拼图/Agent 补齐）完成**：`ImagePerspective`（CIPerspectiveCorrection）
  + `ImageMergeCore`（水平/垂直/gap）+ Agent `cropImage`/`flipImage`/`resizeImage`/
  `mergeImages` 四工具 + 定义/分派/风险分级。harness 2776/0，Debug/Release 零警告。
- **批 3（阅读器 3.0）下一批**。
