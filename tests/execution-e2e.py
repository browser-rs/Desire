#!/usr/bin/env python3
"""执行肌肉端到端测试（本地专属，不进 CI——浏览器依赖在 CI runner 上会挂起）。

用法：应用先以 --automation 跑着（本机访问等级 fullAccess，无审批阻塞），然后
    python3 tests/execution-e2e.py

做法：起一个假 OpenAI 端点（SSE），**新建一个临时档案并激活**（不碰用户的档案），跑一个真实回合：
navigate 到生成的 fixture 页 → waitForText → [右键/双击/拖拽/勾选/文件编辑/OCR/PDF
/快照] 一批工具调用 → executeJS 读页面事件日志 → 终答。断言全部读**盘上会话文件**
（/agent/messages 只回 suffix(12)，长回合早段结果会被截断）。

覆盖：rightClick(contextmenu) / doubleClick(dblclick) / drag(down+moves+up) /
httpRequest（本地靶服务）/ exportPageAsPDF→readPdf（导出物文本层）/
setChecked（含幂等与读回）/ getPageSnapshot 的 checked 字段 / editFile 实际落盘 /
ocrImage / readPdf。跑完恢复档案、按内容清理测试会话与 fixture 目录。
"""
import json
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BRIDGE = "http://127.0.0.1:8799"
FAKE_PORT = 8899
API_PORT = 8898
REPO = Path(__file__).resolve().parent.parent
FIXTURE_ASSETS = REPO / "tests/fixtures/execution"

DRAG_HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>muscle fixture</title>
<style>
  body { font-family: -apple-system; padding: 24px; }
  #track { width: 400px; height: 40px; background: #eee; border-radius: 8px; position: relative; }
  #thumb { width: 40px; height: 40px; background: #c03a1a; border-radius: 8px; position: absolute; left: 0; cursor: grab; }
  #track-end { position: absolute; right: 0; top: 0; width: 8px; height: 40px; background: #999; }
  #ctx, #dbl { display: inline-block; margin-top: 20px; padding: 10px 18px; background: #333; color: #fff; border-radius: 6px; cursor: pointer; }
  #sw { display: inline-block; margin-left: 16px; padding: 6px 14px; border-radius: 14px; background: #ddd; cursor: pointer; }
  #sw[aria-checked="true"] { background: #c03a1a; color: #fff; }
</style></head>
<body>
<div id="track"><div id="thumb"></div><div id="track-end"></div></div>
<div id="ctx">右键目标</div>
<div id="dbl">双击目标</div>
<label style="display:block;margin-top:16px;"><input type="checkbox" id="agree"> 同意条款</label>
<div role="switch" id="sw" aria-checked="false" tabindex="0">开关</div>
<div id="shost" style="margin-top:16px;"></div>
<a id="dl" href="/dl/muscle-dl.txt" download="muscle-dl.txt"
   style="display:inline-block;margin-top:16px;padding:8px 14px;background:#333;color:#fff;border-radius:6px;">下载文件</a>
<script>
window.__log = [];
var dragging = false;
document.getElementById('thumb').addEventListener('mousedown', function () { dragging = true; window.__log.push('drag-down'); });
document.addEventListener('mousemove', function () { if (dragging) { window.__log.push('drag-move'); } });
document.addEventListener('mouseup', function () { if (dragging) { dragging = false; window.__log.push('drag-up'); } });
document.getElementById('ctx').addEventListener('contextmenu', function (e) { e.preventDefault(); window.__log.push('contextmenu'); });
document.getElementById('dbl').addEventListener('dblclick', function () { window.__log.push('dblclick'); });
document.getElementById('sw').addEventListener('click', function () {
  this.setAttribute('aria-checked', this.getAttribute('aria-checked') === 'true' ? 'false' : 'true');
  window.__log.push('switch:' + this.getAttribute('aria-checked'));
});
// 开放 Shadow DOM 组件（组件库站点形态）：通用工具必须能穿透。
var sr = document.getElementById('shost').attachShadow({ mode: 'open' });
sr.innerHTML = '<style>.x{color:#c03a1a}</style>' +
  '<button id="sbtn">影子按钮</button> ' +
  '<label><input type="checkbox" id="scb"> 影子勾选</label> ' +
  '<input id="sinput" placeholder="影子输入框"> ' +
  '<div id="stxt">影子文案出现啦</div>';
sr.getElementById('sbtn').addEventListener('click', function () { window.__log.push('shadow-click'); });
sr.getElementById('scb').addEventListener('click', function () { window.__log.push('shadow-check:' + this.checked); });
try {
  localStorage.setItem('muscle-ls', 'ls-value-1');
  sessionStorage.setItem('muscle-ss', 'ss-value');
  document.cookie = 'muscle-cookie=1; path=/';
} catch (e) {}
</script>
</body></html>
"""


class TinyAPI(BaseHTTPRequestHandler):
    """fixture 页 + 靶子：GET /fixture → drag.html，/dl → 附件，/hello → JSON。

    fixture 走 http 同源：file:// 页面上 `download` 属性不生效（跨源被忽略），
    点击会变成导航、把页面状态（window.__log）清掉——同源后下载不换页。"""
    html = ""
    flaky_hits = 0
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/flaky"):
            TinyAPI.flaky_hits += 1
            if TinyAPI.flaky_hits <= 1:
                # 首载：空壳文档（风控局域页形态）
                body = b"<!DOCTYPE html><html><head><title>flaky</title></head><body></body></html>"
            else:
                body = ("<!DOCTYPE html><html><head><title>flaky full</title></head><body>"
                        "<div id='flaky-ok'>FLAKY-FULL-OK 这是重载后的完整页面内容</div>"
                        "</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/fixture"):
            payload = self.html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/dl"):
            payload = b"muscle-download-ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Disposition", 'attachment; filename="muscle-dl.txt"')
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        payload = json.dumps({"ok": True, "msg": "muscle-http"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def bridge(method, path, body=None):
    req = urllib.request.Request(BRIDGE + path, method=method)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=20) as r:
        return json.loads(r.read().decode())


def sse(wfile, model, delta, finish):
    chunk = {"id": "chatcmpl-m", "object": "chat.completion.chunk", "created": int(time.time()),
             "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
    wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
    done = {"id": "chatcmpl-m", "object": "chat.completion.chunk", "created": int(time.time()),
            "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
    wfile.write(f"data: {json.dumps(done)}\n\n".encode())
    wfile.write(b"data: [DONE]\n\n")
    wfile.flush()


def call(idx, name, args):
    return {"index": idx, "id": f"call_{name}_{idx}", "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}


class Fake(BaseHTTPRequestHandler):
    fix = ""  # 由 main 填（agent workspace 下的 fixture 目录）

    def log_message(self, *a):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.loads(raw or b"{}")
        model = body.get("model", "?")
        msgs = body.get("messages") or []
        sys_text = (msgs[0].get("content") or "") if msgs else ""
        last_user_idx = max((i for i, m in enumerate(msgs) if m.get("role") == "user"), default=-1)
        mode = (msgs[last_user_idx].get("content") or "") if last_user_idx >= 0 else ""
        round_tools = [m for m in msgs[last_user_idx + 1:] if m.get("role") == "tool"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        if "conversation title" in sys_text:
            sse(self.wfile, model, {"role": "assistant", "content": "执行肌肉测试"}, "stop")
            return
        if "MUSCLE" not in mode:
            sse(self.wfile, model, {"role": "assistant", "content": "ok"}, "stop")
            return
        n = len(round_tools)
        if "MUSCLE4" in mode:
            import datetime as _dt
            due = (_dt.datetime.now() + _dt.timedelta(days=1)).replace(hour=9, minute=0, second=0)
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "addReminder", {"title": "E2E 自清理提醒", "dueDate": due.strftime("%Y-%m-%d %H:%M")})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "completeReminder", {"title": "E2E 自清理提醒"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listReminders", {"maxItems": 20})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listCalendarEvents", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE4-DONE"}, "stop")
            return
        if "MUSCLE3" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "addReminder", {"title": "参数校验用例", "dueDate": "明天九点"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE3-DONE"}, "stop")
            return
        if "MUSCLE2" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "navigate", {"url": f"http://127.0.0.1:{API_PORT}/flaky"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "getPageText", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE2-DONE"}, "stop")
            return
        if n == 0:
            # fixture 页由脚本用 /new-tab **预开成独立前台标签**——用户可能正在
            # 看视频/用别的标签，不能让交互落在他的页面上（既定纪律）。
            sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                call(0, "waitForText", {"text": "右键目标"})]}, "tool_calls")
        elif n == 1:
            sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                call(0, "click", {"selector": "#ctx", "button": "right"}),
                call(1, "click", {"selector": "#dbl", "double": True}),
                call(2, "drag", {"fromSelector": "#thumb", "toSelector": "#track-end"}),
                call(3, "setChecked", {"selector": "#agree", "checked": True}),
                call(4, "setChecked", {"selector": "#agree", "checked": True}),   # 幂等
                call(5, "setChecked", {"selector": "#agree"}),                    # 读回
                call(6, "setChecked", {"text": "开关", "checked": True}),         # aria 开关
                call(7, "editFile", {"path": f"{self.fix}/notes.txt", "find": "OLD_TOKEN", "replace": "NEW_TOKEN"}),
                call(8, "ocrImage", {"path": f"{self.fix}/probe.png"}),
                call(9, "readPdf", {"path": f"{self.fix}/probe.pdf"}),
                call(10, "getPageSnapshot", {}),
                call(11, "httpRequest", {"url": f"http://127.0.0.1:{API_PORT}/hello"}),
                call(12, "click", {"text": "影子按钮"}),
                call(13, "setChecked", {"text": "影子勾选", "checked": True}),
                call(14, "fill", {"selector": "#sinput", "value": "shadow-fill-ok"}),
                call(15, "waitForText", {"text": "影子文案出现啦"}),
                call(16, "waitForSelector", {"selector": "#sinput"}),
                call(17, "readPageStorage", {"what": "localStorage"}),
                call(18, "notify", {"title": "肌肉测试", "body": "通知通道验证", "urgent": False}),
                call(19, "copyImageToClipboard", {"path": f"{self.fix}/probe.png"}),
                # 同源 http 页上 download 属性生效：受信点击 #dl 触发真下载、
                # 不换页（后续还要读 window.__log）。
                call(20, "click", {"selector": "#dl"}),
                call(21, "readPageStorage", {"what": "cookies"}),
                call(22, "readClipboard", {}),
            ]}, "tool_calls")
        elif n == 24:
            sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                call(0, "waitForDownload", {"filenameContains": "muscle-dl", "timeoutSec": 60}),
                call(1, "exportPageAsPDF", {"path": f"{self.fix}/page.pdf"}),
                call(2, "exportPageAsWebArchive", {"path": f"{self.fix}/page.webarchive"}),
                call(3, "executeJS", {"code": "JSON.stringify(window.__log || [])"})]}, "tool_calls")
        elif n == 28:
            sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                call(0, "readPdf", {"path": f"{self.fix}/page.pdf"})]}, "tool_calls")
        else:
            sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE-DONE（工具结果 %d 个）" % n}, "stop")


def main():
    state = bridge("GET", "/state")
    workspace = state.get("agentWorkspace")
    assert workspace, "拿不到 agentWorkspace"
    fix_dir = Path(workspace) / "muscle-e2e"
    fix_dir.mkdir(parents=True, exist_ok=True)
    (fix_dir / "drag.html").write_text(DRAG_HTML)
    (fix_dir / "notes.txt").write_text("ALPHA\nOLD_TOKEN mark\nOMEGA\n")
    import shutil
    shutil.copy(FIXTURE_ASSETS / "probe.png", fix_dir / "probe.png")
    shutil.copy(FIXTURE_ASSETS / "probe.pdf", fix_dir / "probe.pdf")
    Fake.fix = str(fix_dir)
    TinyAPI.html = DRAG_HTML

    server = ThreadingHTTPServer(("127.0.0.1", FAKE_PORT), Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    api = ThreadingHTTPServer(("127.0.0.1", API_PORT), TinyAPI)
    threading.Thread(target=api.serve_forever, daemon=True).start()

    # 用**临时档案**跑测试：创建 → 激活 → 跑 → 激活回原档案 → 删除临时。
    # 绝不修改用户的档案字段（2026-10-14 实机教训：就地改活动档案再"恢复"，
    # 恢复曾把 model 写丢一次——aiProfileUpsert 更新分支是"endpoint 必填 +
    # model 无条件覆盖"，只传 model 的修复会静默 400）。
    profiles = bridge("GET", "/ai/profiles")
    original_active = next((p["id"] for p in profiles.get("profiles", []) if p.get("active")), None)
    assert original_active, f"找不到活动档案: {profiles}"
    print("原活动档案:", original_active[:8])
    created = bridge("POST", "/ai/profiles", {
        "name": "E2E Muscle（临时）",
        "endpoint": f"http://127.0.0.1:{FAKE_PORT}/v1/chat/completions",
        "model": "muscle-fake",
        "key": "fake-key",
    })
    temp_id = created.get("id")
    assert temp_id, f"临时档案创建失败: {created}"
    bridge("POST", "/ai/profiles/activate", {"id": temp_id})
    time.sleep(1.0)
    active_now = next((p["id"] for p in bridge("GET", "/ai/profiles").get("profiles", []) if p.get("active")), None)
    assert active_now == temp_id, f"激活未生效（{active_now}）——已中止，避免误发真实网关"
    print("临时档案已激活:", temp_id[:8])

    import subprocess
    prior_clipboard = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
    try:
        subprocess.run(["osascript", "-e",
                        f'set the clipboard to (read (POSIX file "{fix_dir}/probe.png") as «class PNGf»)'],
                       check=True, capture_output=True)
    except Exception as exc:
        print("剪贴板设置失败（跳过该项断言）:", exc)
    try:
        # 独立前台标签装 fixture（/new-tab 用 activeTabManager；新标签即被选中）。
        bridge("POST", "/new-tab", {"url": f"http://127.0.0.1:{API_PORT}/fixture"})
        time.sleep(1.5)
        bridge("POST", "/agent/new", {})
        before = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
        bridge("POST", "/agent/send", {"text": "MUSCLE 执行肌肉测试"})
        deadline = time.time() + 180
        final = None
        while time.time() < deadline:
            st = bridge("GET", "/agent/messages")
            fresh = [m for m in st.get("messages", [])
                     if m.get("id") not in before and m.get("role") == "assistant"]
            if fresh and not st.get("busy") and "MUSCLE-DONE" in (fresh[-1].get("content") or ""):
                final = fresh[-1]["content"]
                break
            time.sleep(1)
        assert final, "回合未在 180s 内完成"

        # 断言从盘上会话文件读全量（suffix(12) 会截断长回合）。
        time.sleep(1)
        conv_id = bridge("GET", "/agent/trace").get("conversation")
        conv_path = (Path.home() / "Library/Application Support/Desire/storage"
                     / f"conversation-{conv_id}.json")
        conv = json.loads(conv_path.read_text())
        results = [(m.get("toolCallId") or "") + " " + (m.get("content") or "")
                   for m in conv.get("messages", []) if m.get("role") == "tool"]
        print("盘上工具结果 %d 条：" % len(results))
        for r in results:
            print("  ·", r[:150])
        joined = "\n".join(results)

        checks = []
        def ok(name, cond):
            checks.append((name, bool(cond)))
            print(("✓" if cond else "✗"), name)

        ok("导航到 fixture", "/fixture" in joined)
        ok("右键触发 contextmenu", "contextmenu" in joined)
        ok("双击触发 dblclick", "dblclick" in joined)
        ok("拖拽 down/move/up 序列", ("drag-down" in joined and "drag-move" in joined and "drag-up" in joined))
        ok("setChecked 勾选", "Now checked" in joined)
        ok("setChecked 幂等", "Already checked" in joined)
        readback = next((r.split(" ", 1)[1].strip() for r in results
                         if "call_setChecked_5" in r), "")
        ok("setChecked 读回（整条=Checked）", readback == "Checked")
        ok("setChecked aria 开关", "switch:true" in joined)
        ok("快照含 checked 字段", '"checked":true' in joined)
        ok("editFile 成功", any("Edited" in r for r in results))
        ok("ocrImage 认出 42", "42" in joined)
        ok("readPdf 取到 88000", "88000" in joined)
        ok("httpRequest 收到响应", "muscle-http" in joined)
        ok("exportPageAsPDF 落盘", "Saved PDF" in joined)
        ok("页面 PDF 带文本层（readPdf 读到 fixture 文案）", "右键目标" in joined)
        ok("text 定位穿透 shadow（影子按钮）", "shadow-click" in joined)
        ok("setChecked 穿透 shadow", "shadow-check:true" in joined)
        ok("selector deep fill（shadow 输入框）", "Filled" in joined)
        ok("waitForText 穿透 shadow", "Found text" in joined)
        ok("快照包含 shadow 元素", "影子按钮" in joined and "影子输入框" in joined)
        ok("waitForSelector 深穿透", "Found element" in joined)
        ok("readPageStorage 列键", "muscle-ls" in joined and "muscle-cookie" in joined)
        ok("notify 走通知策略", ("Notification delivered" in joined or "held by policy" in joined))
        ok("copyImageToClipboard", "Image copied to clipboard" in joined)
        ok("waitForDownload 确认完成", "Download completed: muscle-dl" in joined)
        dl_file = Path.home() / "Downloads" / "muscle-dl.txt"
        ok("下载文件真实落盘", dl_file.exists() and "muscle-download-ok" in dl_file.read_text(errors="ignore"))
        ok("readClipboard 存图", "Clipboard image saved" in joined)
        import glob as _glob
        clip_files = _glob.glob(str(Path.home() / "Downloads" / "clipboard-*.png"))
        ok("剪贴板图真的落盘", len(clip_files) > 0)
        arch_file = fix_dir / "page.webarchive"
        arch_ok = False
        if arch_file.exists() and arch_file.stat().st_size > 2_000:
            try:
                import plistlib
                arch_ok = "muscle fixture" in str(plistlib.loads(arch_file.read_bytes()))
            except Exception:
                arch_ok = False
        ok("WebArchive 落盘且含页面数据", arch_ok)

        # ── 阅读列表离线缓存（关掉 fixture 标签后走离屏抓取，覆盖后台加载路径）──
        # 关掉所有 /fixture 标签（重快照收敛——关一个会挪索引，单遍快照会漏）。
        for _ in range(4):
            stale = [t for t in bridge("GET", "/state").get("tabs", [])
                     if "/fixture" in (t.get("url") or "")]
            if not stale:
                break
            for t in stale:
                bridge("POST", "/close-tab", {"index": t.get("index")})
            time.sleep(0.5)
        time.sleep(0.5)
        fixture_url = f"http://127.0.0.1:{API_PORT}/fixture"
        bridge("POST", "/reading-list/add", {"title": "muscle fixture", "url": fixture_url})
        cached = bridge("POST", "/reading-list/cache", {"url": fixture_url})
        ok("离线缓存抓取（离屏路径）", cached.get("ok") is True and cached.get("fromOpenTab") is False)
        cache_path = Path(cached.get("path") or "")
        ok("缓存文件落盘（>800B）", cache_path.exists() and cache_path.stat().st_size > 800)
        cached_parse_ok = False
        if cache_path.exists():
            try:
                import plistlib as _pl
                cached_parse_ok = "muscle fixture" in str(_pl.loads(cache_path.read_bytes()))
            except Exception:
                cached_parse_ok = False
        ok("缓存归档可解析出页面标题", cached_parse_ok)
        listed = bridge("GET", "/reading-list")
        row = next((i for i in listed.get("items", []) if i.get("url") == fixture_url), {})
        ok("列表带缓存态", row.get("cached") is True)
        bridge("POST", "/reading-list/remove", {"url": fixture_url})
        ok("删除条目联动清缓存文件", not cache_path.exists())

        # ── MUSCLE2：navigate 首载空文档自愈（/flaky 首空后满）──
        # 先开自己的空白标签——navigate 打的是"当前选中标签"，绝不能落在用户标签上。
        bridge("POST", "/new-tab", {"url": "about:blank"})
        time.sleep(1)
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE2 首载自愈探针"})
        deadline2 = time.time() + 120
        while time.time() < deadline2:
            st2 = bridge("GET", "/agent/messages")
            if not st2.get("busy") and any("MUSCLE2-DONE" in (m.get("content") or "")
                                           for m in st2.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv2_id = bridge("GET", "/agent/trace").get("conversation")
        conv2_path = (Path.home() / "Library/Application Support/Desire/storage"
                      / f"conversation-{conv2_id}.json")
        conv2 = json.loads(conv2_path.read_text())
        tools2 = [m.get("content") or "" for m in conv2.get("messages", []) if m.get("role") == "tool"]
        nav_result = next((t for t in tools2 if "Navigated to" in t), "")
        page_result = next((t for t in tools2 if "FLAKY-FULL-OK" in t), "")
        ok("navigate 首载空文档自动重载", "已自动重载一次" in nav_result)
        ok("自愈后页面内容可见", "FLAKY-FULL-OK" in page_result)

        # ── MUSCLE3：OS 协作工具参数校验（发生在授权请求之前，不弹窗）──
        status_before_m3 = bridge("GET", "/system/integrations")
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE3 OS 工具校验"})
        deadline3 = time.time() + 90
        while time.time() < deadline3:
            st3 = bridge("GET", "/agent/messages")
            if not st3.get("busy") and any("MUSCLE3-DONE" in (m.get("content") or "")
                                           for m in st3.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv3_id = bridge("GET", "/agent/trace").get("conversation")
        conv3 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv3_id}.json").read_text())
        tools3 = [m.get("content") or "" for m in conv3.get("messages", []) if m.get("role") == "tool"]
        reminder_result = next((t for t in tools3 if "dueDate" in t), "")
        ok("OS 工具拒收自然语言日期（参数前置校验）", "dueDate must be" in reminder_result)
        integrations = bridge("GET", "/system/integrations")
        # 状态无关判据：校验失败不应改变授权状态（此前写死 notDetermined，
        # 用户真机授权后成了过期断言——2026-10-15 实测踩到）。
        ok("校验失败不改变授权状态", integrations == status_before_m3)

        # ── MUSCLE4：OS 协作读写闭环（本机已授权；提醒生命周期自清理）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE4 OS 读写闭环"})
        deadline4 = time.time() + 120
        while time.time() < deadline4:
            st4 = bridge("GET", "/agent/messages")
            if not st4.get("busy") and any("MUSCLE4-DONE" in (m.get("content") or "")
                                           for m in st4.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv4_id = bridge("GET", "/agent/trace").get("conversation")
        conv4 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv4_id}.json").read_text())
        tools4 = [m.get("content") or "" for m in conv4.get("messages", []) if m.get("role") == "tool"]
        made = next((t for t in tools4 if "E2E 自清理提醒" in t and "Reminder added" in t), "")
        done = next((t for t in tools4 if t.startswith("Reminder completed")), "")
        open_list = next((t for t in tools4 if "Open reminders" in t or "No open reminders" in t), "")
        events_list = next((t for t in tools4 if "Calendar events" in t or "No calendar events" in t), "")
        ok("提醒创建（真机 · 已授权路径）", made.startswith("Reminder added"))
        ok("提醒完成闭环", done.startswith("Reminder completed"))
        ok("读回已不含完成的提醒", "E2E 自清理提醒" not in open_list)
        ok("日历读取可用（含已建测试日程）", "Desire 接入测试日程" in events_list)
        notes = (fix_dir / "notes.txt").read_text()
        ok("文件实际已改", ("NEW_TOKEN" in notes) and ("OLD_TOKEN" not in notes))
        assert all(c for _, c in checks), "存在失败项"
        print("\nexecution E2E ALL PASS（%d 项）" % len(checks))
    finally:
        # 关掉测试标签（fixture 页 + 本 fixture 服务器的残留 /dl 页）——
        # 收敛式：每次重快照，因为关一个标签会挪掉后面所有索引。
        try:
            for _ in range(4):
                stale = [t for t in bridge("GET", "/state").get("tabs", [])
                         if "/fixture" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/dl" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/flaky" in (t.get("url") or "")]
                if not stale:
                    break
                for t in stale:
                    bridge("POST", "/close-tab", {"index": t.get("index")})
                time.sleep(0.5)
        except Exception as exc:
            print("关标签跳过:", exc)
        # 清理：测试会话按内容核对后删（别碰用户的）；档案恢复并核对；fixture 目录删除。
        try:
            for f in (Path.home() / "Library/Application Support/Desire/storage").glob("conversation-*.json"):
                if "MUSCLE" in f.read_text(errors="ignore"):
                    bridge("POST", "/conversations/delete", {"id": f.stem.replace("conversation-", "")})
                    print("清理测试会话:", f.stem[:24])
        except Exception as exc:
            print("会话清理跳过:", exc)
        bridge("POST", "/ai/profiles/activate", {"id": original_active})
        time.sleep(1.0)
        back = bridge("GET", "/ai/profiles")
        active_back = next((p["id"] for p in back.get("profiles", []) if p.get("active")), None)
        assert active_back == original_active, f"原档案回切失败: {active_back}"
        deleted = bridge("POST", "/ai/profiles/delete", {"id": temp_id})
        print("临时档案已删:", deleted.get("ok", deleted))
        print("原档案已恢复:", original_active[:8])
        try:
            (Path.home() / "Downloads" / "muscle-dl.txt").unlink(missing_ok=True)
        except Exception:
            pass
        try:
            for f in _glob.glob(str(Path.home() / "Downloads" / "clipboard-*.png")):
                Path(f).unlink(missing_ok=True)
        except Exception:
            pass
        # 下载**条目**也要清（此前只删了 ~/Downloads 里的文件，下载面板里会
        # 留存历次 muscle-dl 记录，实机测试时被抓包）。
        try:
            for item in bridge("GET", "/downloads").get("downloads", []):
                if "muscle-dl" in (item.get("file") or ""):
                    bridge("POST", "/downloads/remove", {"id": item["id"]})
        except Exception:
            pass
        try:
            if prior_clipboard:
                subprocess.run(["pbcopy"], input=prior_clipboard.encode(), check=False)
            else:
                subprocess.run(["osascript", "-e", 'set the clipboard to ""'], check=False, capture_output=True)
        except Exception:
            pass
        print("（剪贴板已按原文恢复/清空——测试期间占用了它）")
        import shutil
        shutil.rmtree(fix_dir, ignore_errors=True)
        server.shutdown()
        api.shutdown()


if __name__ == "__main__":
    main()
