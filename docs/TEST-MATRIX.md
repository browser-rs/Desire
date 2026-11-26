# 下载链路测试形态矩阵（v0.8.79）

> 0.8.77 的事故教训：并发套件只测"干净的未加密流"，而线上流的密钥文件名触发了 ffmpeg 的扩展名
> 安全检查——本地合成必败、回退重下，整个版本带着缺陷发出去。**发版测试的输入形态必须覆盖
> "线上必然出现"的组合**，不是测试越多越好，而是**每一类形态都有断言**。

维护规则：新增一种输入形态（新站点行为、新协议特性）→ 在本表加一行并指向断言；断言缺失 = 不许发版。

| # | 形态 | 线上为什么会出现 | 断言位置 | 状态 |
|---|------|------------------|----------|------|
| 1 | 未加密 VOD HLS（媒体播放列表 / master 多档） | 常见形态；master 需要挑档 | `tests/parallel-hls-e2e.py` 普通点播探测/下载、码率上限挑档；`tests/batch-content-e2e.py` 各页 | ✅ |
| 2 | AES-128 加密，密钥文件名非白名单（`key.ts`） | CDN 常把 key 命名成 .ts/.bin；ffmpeg 9 扩展名检查会拦 | `parallel-hls-e2e.py` 加密流 5 项（合成成功、无回退、音视频齐全） | ✅ |
| 3 | 音轨分离（`EXT-X-MEDIA` 独立音轨） | 影视站常用；按单变体并发抓会丢声音 | `parallel-hls-e2e.py` 探测·音轨分离 + 下载后音轨仍在 | ✅ |
| 4 | 字节切片（`EXT-X-BYTERANGE`） | 单文件按区间切片的 CDN | `parallel-hls-e2e.py` 探测·字节切片（ffmpeg 直连）+ 下载完整；无 ffmpeg 时诚实失败 | ✅ |
| 5 | 直播（播放列表无 `ENDLIST`），含窗口滑动 | 直播/时移；绝不能交 ffmpeg 从头读；窗口会前进 | `parallel-hls-e2e.py` 探测·直播 + 只导出当前可用分片；滑窗直播（`/live-slide`）第二次导出取到新窗口的分片、不复用旧窗口 | ✅ |
| 6 | SAMPLE-AES | 部分平台加密；内置路径不认 | `parallel-hls-e2e.py` 探测·SAMPLE-AES（方法 = ffmpeg 直连、原因点名加密） | ✅ |
| 7 | 直链文件（mp4 等） | 部分站点给直链 | `parallel-hls-e2e.py` 探测·直链（大小/可续传）；batch-content 直链页 | ✅ |
| 8 | 网页不是媒体地址 | 模型可能拿详情页去探测 | `parallel-hls-e2e.py` 探测·网页（直说并指向 resolveVideos） | ✅ |
| 9 | 无 ffmpeg 的机器 | 用户机器不一定装 | `parallel-hls-e2e.py --expect-no-ffmpeg`（12/14 项，含加密/字节切片） | ✅ |
| 10 | 多视频页 + 懒加载播放器 | 详情页一页多部 | `batch-content-e2e.py` 多视频页展开（02/02-2/02-3）、任务表 7 条 | ✅ |
| 11 | 同页多部 + 跨批次重跑 | 用户重开批次 | `batch-content-e2e.py` 跨批次去重（全部按"已下载过"跳过；同页多部不误跳） | ✅ |
| 12 | 签名地址中途过期 | 长片下载必遇 | `batch-content-e2e.py` 过期→重新解析→续传（分片不重抓） | ✅ |
| 13 | 站点规则命中 / 落空 | 适配器规则与页面改版 | `batch-content-e2e.py` 规则命中（aaa/ccc/eee）、落空回退（ddd）、打磨回写（有效期/修订/备份） | ✅ |
| 14 | 手写下载命令（`.m3u8` 交给 ffmpeg/curl/脚本） | 模型习惯自己写脚本 | `tests/main.swift` `looksLikeHandWrittenDownload` 单测；runCommand 附提醒（回合级，假模型探针） | ✅ |
| 15 | DPP 适配器导入 / 命中 / 徽标 | 外挂适配是常态 | `/protocol/inspect` 的 `adapter` 字段（自动）；工具栏徽标（截图，手动）；导入后自动重解析；`tests/dpp-adapter-e2e.py` 导入/导出/重新导入往返 + Studio 表单快照 | ⚠️ 徽标为手动截图 |
| 16 | 跨重启续传 | 用户退出/崩溃后重开 | `tests/resume-after-restart-e2e.py`（quit→重启→续传→已抓分片不再请求） | ✅ |
| 17 | 批次取消 / 恢复 / 分卷 | 用户操作 | `tests/execution-e2e.py`（恢复/取消）；batch-content 分卷落点 | ✅ |
| 18 | 站点实测画像复用（7 天内 ≥2 样本） | 用户定调「不是每个都要测速」 | `batch-content-e2e.py` 画像批（删产物→重跑用画像、日志无「测速」、实测回写适配器） | ✅ |
| 19 | 适配器导出（剥离遥测）/ 重新导入 | 分享/备份站点规则 | `tests/dpp-adapter-e2e.py`（遥测与本地溯源剥离、规则与协议体往返一致、来源戳幂等） | ✅ |

**发版前必跑**：`bash tests/run.sh` + `tests/parallel-hls-e2e.py`（两轮：正常 / `--expect-no-ffmpeg`）
+ `tests/batch-content-e2e.py`（需前台）+ `tests/dpp-adapter-e2e.py` + `tests/resume-after-restart-e2e.py`
+ `tests/release-smoke.py`。核实图里 ⚠️ 的一行用截图确认。
