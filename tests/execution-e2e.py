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
</script>
</body></html>
"""


class TinyAPI(BaseHTTPRequestHandler):
    """httpRequest 工具的靶子：GET /hello → JSON。"""
    def log_message(self, *a):
        pass

    def do_GET(self):
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
            ]}, "tool_calls")
        elif n == 13:
            sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                call(0, "exportPageAsPDF", {"path": f"{self.fix}/page.pdf"}),
                call(1, "executeJS", {"code": "JSON.stringify(window.__log || [])"})]}, "tool_calls")
        elif n == 15:
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

    try:
        # 独立前台标签装 fixture（/new-tab 用 activeTabManager；新标签即被选中）。
        bridge("POST", "/new-tab", {"url": f"file://{fix_dir}/drag.html"})
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

        ok("导航到 fixture", "drag.html" in joined)
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
        notes = (fix_dir / "notes.txt").read_text()
        ok("文件实际已改", ("NEW_TOKEN" in notes) and ("OLD_TOKEN" not in notes))
        assert all(c for _, c in checks), "存在失败项"
        print("\nexecution E2E ALL PASS（%d 项）" % len(checks))
    finally:
        # 关掉 fixture 标签（按 URL 找；用户自己的标签不动）。
        try:
            st = bridge("GET", "/state")
            for t in st.get("tabs", []):
                if "muscle-e2e" in (t.get("url") or ""):
                    bridge("POST", "/close-tab", {"index": t.get("index")})
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
        import shutil
        shutil.rmtree(fix_dir, ignore_errors=True)
        server.shutdown()
        api.shutdown()


if __name__ == "__main__":
    main()
