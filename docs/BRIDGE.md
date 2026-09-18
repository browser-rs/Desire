# Desire 自动化桥速查（BRIDGE.md）

启动：`open Desire.app --args --automation`（可选 `--automation-token <token>`，
之后所有请求带 `-H "Authorization: Bearer <token>"`）。

**自描述端点**：`curl http://127.0.0.1:8799/` 返回全部 60+ 端点的
方法/参数/示例（机器可读 JSON，含 SSE 事件清单）——本文件是人读版速查。

## 浏览

```bash
B=http://127.0.0.1:8799
curl -s $B/state                                   # 标签列表 + 窗口状态
curl -s -X POST $B/navigate  -d '{"url":"https://example.com"}'
sleep 1
curl -s "$B/find?q=hello"                          # 页内查找 + 计数
curl -s "$B/page/text"                             # 可见文本
curl -s "$B/page/url"                              # url/title/zoom
curl -s  $B/screenshot                             # webview 截图 → ~/desire_automation.png
```

## 标签

```bash
curl -s -X POST $B/new-tab   -d '{"url":"https://example.com","incognito":true}'
curl -s -X POST $B/switch-tab -d '{"index":1}'
curl -s -X POST $B/close-tab  -d '{"index":1}'
curl -s -X POST $B/tabs/pin   -d '{"index":0,"pinned":true}'
curl -s -X POST $B/command    -d '{"name":"reopenClosedTab"}'   # 全部菜单命令可驱动
```

## 下载

```bash
curl -s -X POST $B/downloads/pause  -d '{}'        # 暂停最近活动下载
curl -s -X POST $B/downloads/resume -d '{}'
curl -s $B/downloads | python3 -m json.tool
```

## 事件流（SSE，替代轮询）

```bash
curl -sN $B/events          # pageReady / downloadStarted / downloadCompleted /
                            # downloadFailed / approvalPending / tabOpened /
                            # tabClosed / beforeunloadPending
```

## Agent

```bash
curl -s -X POST $B/agent/send -d '{"text":"总结这个页面"}'
curl -s $B/agent/messages
curl -s $B/approvals && curl -s -X POST $B/approvals/resolve -d '{"decision":"allow_once"}'
curl -s -X POST $B/agent/tasks/create -d '{"name":"t","prompt":"…","minutes":30}'
curl -s -X POST $B/agent/tasks/fire   -d '{"name":"t"}'
```

## 表单保护（beforeunload）

```bash
curl -s "$B/beforeunload?index=0"                       # {"pending":true,…}
curl -s -X POST $B/beforeunload/resolve -d '{"leave":false}'   # 留下
curl -s -X POST $B/beforeunload/resolve -d '{"leave":true}'    # 离开
```

## 数据存储（书签/阅读列表/搜索历史/快拨/站点设置/元素屏蔽）

```bash
curl -s -X POST $B/bookmarks/add -d '{"title":"X","url":"https://a.b"}'
curl -s -X POST $B/site-settings/zoom -d '{"host":"example.com","zoom":1.5}'
curl -s -X POST $B/elements/add -d '{"selector":"nav","pattern":"example.com"}'
curl -s "$B/site-settings?host=example.com"
```

## UI 验证（免屏幕录制权限）

```bash
curl -s -X POST $B/panel -d '{"name":"downloads","show":true}'
curl -s "$B/panel/snapshot?name=downloads"        # 进程内渲染 PNG → ~/desire_panel.png
```

## 注意事项

- 窗口级命令（`/command`）遵循 key-window 语义：app 必须处于激活状态。
- 服务器默认只绑 127.0.0.1；对外暴露务必加 `--automation-token`。
- DiskStore 落盘为 500ms 防抖异步写；断言前留出时间，结束进程用
  `osascript -e 'quit app "Desire"'` 而非 `kill -9`。
