# 办公文件支持矩阵（v0.8.26）

应用内直开（拖入 / 地址栏 / 最近本地文件）与 Agent 工具使用同一套端上管道，
不依赖 Office、不上传文件。

| 类型 | 直接查看 | 编辑 | 转换 / 导出 | Agent 工具 |
|---|---|---|---|---|
| PDF | PDF 工作台（大纲/缩略图/批注/搜索/表单） | 批注 | → md/txt/docx/rtf/html | readPdf / pdfPageScreenshot / mergePDFs / splitPDF |
| Word .docx/.doc | 文档查看器（textutil 保结构） | 只读（可导出 CSV 表格数据） | → pdf | readDocument / convertDocument |
| RTF / ODT / HTML | 文档查看器 | 只读 | → pdf | readDocument |
| PowerPoint .pptx | 演示文稿查看器（标题/要点/备注） | 只读 | → md/txt/html/docx/rtf/pdf | readPresentation |
| 表格 .xlsx/.csv/.tsv | 表格查看器（多工作表/排序/筛选/编辑） | xlsx 缓存值单元格、csv/tsv 单元格 | → md/csv/tsv/xlsx | readSpreadsheet / editSpreadsheet / tableExport |
| 图片 png/jpg/heic/tiff/gif/webp | 图片编辑器（裁剪/旋转/调色/标注/OCR） | 编辑 + 历史 | → png/jpeg/heic/tiff；图片 → pdf | convertImage / ocrImage |
| 压缩包 .zip | 压缩包查看器（条目列表/预览/多选解压） | — | 解压全部 / 解压所选；zipFiles 打包 | listArchive / unzipArchive / zipFiles |
| JSON .json/.jsonl/.ndjson/.geojson | JSON 查看器（语法着色） | 格式化/压缩/键排序后保存（.bak） | → csv/xlsx/md/txt | formatJSON |

**JSON 工作台**：查看器工具条可直接切换格式化 / 压缩 / 键排序 / 缩进档位；
状态条显示字节数、行数、合法性；解析失败显示行号列号并在顶部告警条给出原因。
保存会先把原文件复制为 `.bak`；导出 CSV/Excel 需要数组形态（对象数组 / 数组的数组）。

**演示文稿**：只支持 .pptx（OOXML）。旧版二进制 .ppt 会提示另存为 .pptx。
备注页来自 `ppt/notesSlides`，页码/页脚占位符会被过滤。

**边界**：xlsx 写入只写值不写公式；pptx 读取不渲染版式/主题/图片（文本大纲）；
zip 只支持 .zip（rar/7z 不支持）；HEIC 导出失败会回退 PNG。
