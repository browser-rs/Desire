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
ocrImage / readPdf / readDocument(docx) / readSpreadsheet(xlsx/csv，含错类型 Error: 口径) /
pinTab+muteTab+setZoom+moveTab（listTabs 状态标记复查）/
newWindow+saveWorkspace+openIncognitoTab+restoreWorkspace+deleteWorkspace（MUSCLE8 全在
新窗口里做，用户窗口零触碰）/ renameTabGroup+deleteHistory（MUSCLE9，只碰 fixture 标签
与 127.0.0.1 记录）/ splitView+unsplitView+collapseTabGroup（MUSCLE10）/ 收件箱（MUSCLE11：
手造待回复会话→/inbox 命中→删文件消失；强制免打扰→notify 被扣→补推→消失，策略原样复原）/
归档会话（MUSCLE12：手造归档→列表→在新窗口恢复→复核标记 URL→关窗）/
readURL（MUSCLE13：已开标签路径/离屏路径/坏 URL 口径，且不开新标签）/
数值盯梢（MUSCLE14：建监视→基线→改价→跨线告警→列表→删除）/
每站缩放记忆（MUSCLE15：清零→设 150→同站导航保持→reset 后清除）/
朗读工具（MUSCLE16：readAloud 传文本→/speech 在讲→stopSpeaking→停；无 text 从 /article 提取、回执带标题）/
会话预算（MUSCLE17：假端点 usage 推到 460/500 → warning；续跑 → 停在步骤边界 + 档位阶梯前进）/
热点选题（MUSCLE18：readURL 读热榜→promotionSave idea×2（目标/来源带齐）→listSkills 带 hot-topics；
桥 /promotion/review 一键安排每日选题采集并撤销）/
阅读列表批量摘要（MUSCLE19：两篇入库→桥按 urls 触发→条目带摘要（含页面实读回显）→只动指定条目→删除收尾）/
双语对照（MUSCLE23：桥开启 → 假端点分块翻译回填 → 节点计数/序号对齐/关闭清零）/\n书签导入去重（MUSCLE22：HTML 解析 + 撞库/组内划分 + skipDuplicates/keepAll 落库）/\n站点字体（MUSCLE21：桥设 16px+Songti → 内联 10px 被抬、作者字体不被覆盖 → 清覆盖原值还原）/\n备忘录工具（MUSCLE20：addNote 缺标题 / searchNotes 太短 → Error 约定；真调用会弹 TCC 自动化授权，套件只走校验路径）。
跑完恢复档案、按内容清理测试会话与 fixture 目录。
"""
import contextlib
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

    price_hits = 0

    def do_GET(self):
        if self.path.startswith("/price"):
            TinyAPI.price_hits += 1
            price = "1,299.00" if TinyAPI.price_hits <= 1 else "1,150.00"
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'><title>price probe</title></head>"
                    f"<body><h1>商品页</h1><div class='price'>¥{price}</div></body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
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
        if self.path.startswith("/article"):
            # 朗读提取器（MUSCLE16）的靶页：article 容器 + 长段落（≥100 字
            # 才够打分阈值；标题供工具回执复述）。
            paras = "".join(
                f"<p>第 {i} 段：这是用于朗读功能自测的中文正文段落，"
                "形状与真实文章一致，句子足够长以便语音合成器有内容可念。</p>"
                for i in range(1, 7))
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
                    "<title>Article Fixture</title></head><body>"
                    "<nav>导航噪音</nav>"
                    f"<article><h1>Article Fixture</h1>{paras}</article>"
                    "</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/rlpage"):
            which = "MUSCLE19P1" if self.path.startswith("/rlpage1") else "MUSCLE19P2"
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
                    f"<title>RL Page {which}</title></head><body>"
                    f"<article><h1>{which} 测试文章</h1>"
                    f"<p>{which} 正文段落一：用于验证批量摘要取文与模型回显的标记内容，"
                    "句子足够长以便正文提取阈值通过。</p>"
                    f"<p>{which} 正文段落二：再来一段以确保提取器选中正文容器而不是导航。</p>"
                    "</article></body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/hotlist"):
            # 热点选题（MUSCLE18）的靶页：热榜形态（标题 + 若干长段落），
            # readURL 的正文提取按"body 长段落"回退即可整页读出。
            items = "".join(
                f"<p>MUSCLE18HOT 话题 {i}：某框架 {i}.0 发布引发迁移讨论，实测兼容性与性能差异（热度 {100 + i * 37}）</p>"
                for i in range(1, 6))
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
                    "<title>Hot List Fixture</title></head><body>"
                    f"<h1>今日热榜</h1>{items}</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/bipage"):
            # 双语对照（MUSCLE23）的靶页：标题 + 三段英文正文（≥12 字符门槛）。
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
                    "<title>Bilingual Fixture</title></head><body><article>"
                    "<h1>Reading Practice</h1>"
                    "<p>The quick brown fox jumps over the lazy dog every single morning before breakfast.</p>"
                    "<p>Distributed systems fail in interesting ways when the network partitions last.</p>"
                    "<p>A small paragraph that should also be picked up by the collector without trouble.</p>"
                    "</article></body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/fontpage"):
            # 站点字体（MUSCLE21）的靶页：内联 10px 小字 / 无字体段落 /
            # 自带 Monlo 的段落（验证抬升、注入、作者优先三条）。
            body = ("<!DOCTYPE html><html><head><meta charset='utf-8'>"
                    "<title>Font Fixture</title></head><body>"
                    "<p id='tiny' style='font-size:10px'>tiny text</p>"
                    "<p id='plain'>plain paragraph</p>"
                    "<p id='authored' style='font-family:Menlo'>authored</p>"
                    "</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
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
    tab_index = 0   # MUSCLE7：fixture 标签当前位次（main 现查）
    move_to = 0     # MUSCLE7：moveTab 的目标位次
    split_partner = 0  # MUSCLE10：分屏右栏标签位次
    archive_file = ""  # MUSCLE12：手造归档文件名

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
        if "阅读助理" in sys_text:
            # 批量摘要的旁路调用（MUSCLE19）：把收到的页面标记回显进摘要——
            # 摘要里出现标记 = 正文真的流到了模型（不是空稿摘要）。
            marker = next((p for p in ("MUSCLE19P1", "MUSCLE19P2") if p in (msgs[-1].get("content") or "")), "?")
            sse(self.wfile, model, {"role": "assistant", "content": f"摘要回显：{marker} 的主旨与要点。"}, "stop")
            return
        if "DESIRE_BILINGUAL_TRANSLATE" in sys_text:
            # 双语对照（MUSCLE23）的旁路翻译调用：按编号行回 JSON 数组，
            # 每条 "译(<n>) <原文>"——DOM 插入的断言靠这个前缀与序号。
            user_text = msgs[-1].get("content") or ""
            out = []
            for l in user_text.split("\n"):
                if not l.strip():
                    continue
                num, _, text = l.partition(". ")
                out.append(f"译({num or '?'}) {text}")
            sse(self.wfile, model, {"role": "assistant", "content": json.dumps(out, ensure_ascii=False)}, "stop")
            return
        if "MUSCLE" not in mode:
            sse(self.wfile, model, {"role": "assistant", "content": "ok"}, "stop")
            return
        n = len(round_tools)
        if "MUSCLE5" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "splitPDF", {"path": f"{self.fix}/probe3.pdf", "pages": "2",
                                         "output": f"{self.fix}/split.pdf"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "mergePDFs", {"paths": [f"{self.fix}/probe.pdf", f"{self.fix}/probe3.pdf"],
                                          "output": f"{self.fix}/merged.pdf"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readPdf", {"path": f"{self.fix}/merged.pdf"})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readPdf", {"path": f"{self.fix}/split.pdf"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE5-DONE"}, "stop")
            return
        if "MUSCLE6" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readDocument", {"path": f"{self.fix}/doc.docx"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readSpreadsheet", {"path": f"{self.fix}/quote.xlsx"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readSpreadsheet", {"path": f"{self.fix}/orders.csv"})]}, "tool_calls")
            elif n == 3:
                # 错类型：docx 工具读 xlsx → 必须走 Error: 约定并指对工具
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readDocument", {"path": f"{self.fix}/quote.xlsx"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE6-DONE"}, "stop")
            return
        if "MUSCLE7" in mode:
            idx = self.tab_index
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabs", {})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "pinTab", {"index": idx}),
                    call(1, "muteTab", {"index": idx}),
                    call(2, "setZoom", {"percent": 125})]}, "tool_calls")
            elif n == 4:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "moveTab", {"from": idx, "to": self.move_to}),
                    call(1, "listTabs", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE7-DONE"}, "stop")
            return
        if "MUSCLE8" in mode:
            if "MUSCLE8A" in mode:
                # 回合 A：开新窗口并加载 fixture 页
                if n == 0:
                    sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                        call(0, "newWindow", {"url": f"http://127.0.0.1:{API_PORT}/fixture"})]}, "tool_calls")
                else:
                    sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE8A-DONE"}, "stop")
                return
            # 回合 B：新窗口里跑工作区闭环（deliveryTarget 已是新窗口的会话）
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "saveWorkspace", {"name": "E2E-MUSCLE8"}),
                    call(1, "openIncognitoTab", {"url": f"http://127.0.0.1:{API_PORT}/hello"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listWorkspaces", {}),
                    call(1, "listTabs", {})]}, "tool_calls")
            elif n == 4:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "restoreWorkspace", {"name": "E2E-MUSCLE8"})]}, "tool_calls")
            elif n == 5:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabs", {}),
                    call(1, "listWorkspaces", {})]}, "tool_calls")
            elif n == 7:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "deleteWorkspace", {"name": "E2E-MUSCLE8"})]}, "tool_calls")
            elif n == 8:
                # 最后一步：关掉本会话所在窗口（测试窗口自清理；窗口一关回合
                # 可能收不到最终消息——断言只依赖已落盘的工具结果）。
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "closeWindow", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE8-DONE"}, "stop")
            return
        if "MUSCLE9" in mode:
            if n == 0:
                # 先切回 fixture 标签（标签组操作带在"当前标签"上，别动用户的）
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "switchTab", {"index": self.tab_index}),
                    call(1, "addTabToGroup", {"groupName": "E2E 组"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "renameTabGroup", {"groupName": "E2E 组", "newName": "E2E 组（改名）"}),
                    call(1, "deleteHistory", {"domain": "127.0.0.1"})]}, "tool_calls")
            elif n == 4:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabGroups", {}), call(1, "getHistory", {"count": 50})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE9-DONE"}, "stop")
            return
        if "MUSCLE10" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "splitView", {"index": self.split_partner})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "collapseTabGroup", {"groupName": "E2E 组（改名）", "collapsed": True}),
                    call(1, "listTabGroups", {})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "unsplitView", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE10-DONE"}, "stop")
            return
        if "MUSCLE15" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "resetZoom", {})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "setZoom", {"percent": 150})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "navigate", {"url": f"http://127.0.0.1:{API_PORT}/hello"})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabs", {})]}, "tool_calls")
            elif n == 4:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "resetZoom", {})]}, "tool_calls")
            elif n == 5:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "navigate", {"url": f"http://127.0.0.1:{API_PORT}/flaky"})]}, "tool_calls")
            elif n == 6:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabs", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE15-DONE"}, "stop")
            return
        if "MUSCLE16A" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readAloud", {"text": "这是朗读功能的自测文本，朗读工具会把这段文字用端上语音合成念出来。" * 12})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE16A-DONE"}, "stop")
            return
        if "MUSCLE16B" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "stopSpeaking", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE16B-DONE"}, "stop")
            return
        if "MUSCLE16C" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "navigate", {"url": f"http://127.0.0.1:{API_PORT}/article"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readAloud", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE16C-DONE"}, "stop")
            return
        if "MUSCLE17" in mode and body.get("tools") and "自评者" not in sys_text:
            # 会话预算（v0.7.18）：每个真实回合的回复都带 usage（400+60）——
            # 只在**带 tools 的回合请求**上记账，标题/记忆/自评等旁路调用
            # 不带 tools，天然不计入，测试的用量算术因此是确定的。
            def sse_usage(finish_reason):
                # usage 块必须在 [DONE] 之前——解析器遇到 [DONE] 即 break。
                chunk = {"id": "chatcmpl-m", "object": "chat.completion.chunk",
                         "created": int(time.time()), "model": model,
                         "choices": [], "usage": {"prompt_tokens": 400, "completion_tokens": 60}}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                done = {"id": "chatcmpl-m", "object": "chat.completion.chunk",
                        "created": int(time.time()), "model": model,
                        "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}]}
                self.wfile.write(f"data: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
                self.wfile.flush()
            if "MUSCLE17A" in mode and n == 0:
                # 手写 delta 块（sse() 自带 [DONE]，usage 必须在它之前）。
                c = {"id": "chatcmpl-m", "object": "chat.completion.chunk",
                     "created": int(time.time()), "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": "MUSCLE17A-OK"},
                                  "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
                sse_usage("stop")
            elif "MUSCLE17A" in mode:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE17A-DONE"}, "stop")
            elif "MUSCLE17B" in mode and n == 0:
                c = {"id": "chatcmpl-m", "object": "chat.completion.chunk",
                     "created": int(time.time()), "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call(0, "listTabs", {})]},
                                  "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
                sse_usage("tool_calls")
            elif "MUSCLE17B" in mode:
                # 到不了这里（第二次迭代会被预算门控拦住）——留着做反证。
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE17B-DONE"}, "stop")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE17-DONE"}, "stop")
            return
        if "MUSCLE18" in mode and body.get("tools") and "自评者" not in sys_text:
            hot_url = f"http://127.0.0.1:{API_PORT}/hotlist"
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readURL", {"url": hot_url})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "promotionSave", {"platform": "热榜源", "title": "MUSCLE18 选题一",
                                              "body": f"切入角度：迁移成本实测对比 + 来源: {hot_url}",
                                              "status": "idea", "goal": "MUSCLE18 选题目标"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "promotionSave", {"platform": "热榜源", "title": "MUSCLE18 选题二",
                                              "body": f"切入角度：性能拆解教程 + 来源: {hot_url}",
                                              "status": "idea"})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listSkills", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE18-DONE"}, "stop")
            return
        if "MUSCLE20" in mode and body.get("tools") and "自评者" not in sys_text:
            # 备忘录工具（v0.7.19）：只验参数校验路径——真调用会触发「Desire 想
            # 控制备忘录」TCC 弹窗（用户在场点一次即可），套件里绝不发起
            # AppleEvent（"参数校验先于授权"惯例，同提醒事项首轮 E2E）。
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "addNote", {"body": "只有正文没有标题"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "searchNotes", {"query": "x"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE20-DONE"}, "stop")
            return
        if "MUSCLE14" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "addPageWatch", {"name": "E2E 价格", "url": f"http://127.0.0.1:{API_PORT}/price",
                                             "selector": ".price", "numericSelector": ".price",
                                             "intervalMinutes": 30, "alertBelow": 1200})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "checkPageWatch", {"name": "E2E 价格"})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "checkPageWatch", {"name": "E2E 价格"})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listPageWatches", {}),
                    call(1, "removePageWatch", {"name": "E2E 价格"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE14-DONE"}, "stop")
            return
        if "MUSCLE13" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readURL", {"url": f"http://127.0.0.1:{API_PORT}/flaky"})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readURL", {"url": f"http://127.0.0.1:{API_PORT}/hello", "includeLinks": False})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "readURL", {"url": "not a url"})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE13-DONE"}, "stop")
            return
        if "MUSCLE12" in mode:
            if "MUSCLE12A" in mode:
                if n == 0:
                    sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                        call(0, "newWindow", {})]}, "tool_calls")
                else:
                    sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE12A-DONE"}, "stop")
                return
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listArchivedSessions", {})]}, "tool_calls")
            elif n == 1:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "restoreArchivedSession", {"file": self.archive_file})]}, "tool_calls")
            elif n == 2:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listTabs", {})]}, "tool_calls")
            elif n == 3:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "closeWindow", {})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE12-DONE"}, "stop")
            return
        if "MUSCLE11" in mode:
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "notify", {"title": "收件箱 E2E", "body": "这条应被扣下", "urgent": False})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE11-DONE"}, "stop")
            return
        # 注意顺序：MUSCLE4CLEAN 是 MUSCLE4 的超串，必须先判。
        if "MUSCLE4CLEAN" in mode:
            import datetime as _dt
            ev_day = (_dt.datetime.now() + _dt.timedelta(days=1)).strftime("%Y-%m-%d")
            if n == 0:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "deleteCalendarEvent", {"title": "E2E 自清理日程", "date": ev_day})]}, "tool_calls")
            else:
                sse(self.wfile, model, {"role": "assistant", "content": "MUSCLE4CLEAN-DONE"}, "stop")
            return
        if "MUSCLE4" in mode:
            import datetime as _dt
            due = (_dt.datetime.now() + _dt.timedelta(days=1)).replace(hour=9, minute=0, second=0)
            ev_start = (_dt.datetime.now() + _dt.timedelta(days=1)).replace(hour=10, minute=0, second=0)
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
                # 自建自删（别再依赖用户日历里的既有事件——2026-10-17 起
                # 该断言用自己创建的 "E2E 自清理日程" 验证，删除步骤顺带把
                # dangerous 审批闸门也走了一遍（测试侧经 /approvals 放行））。
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "addCalendarEvent", {"title": "E2E 自清理日程",
                                                 "start": ev_start.strftime("%Y-%m-%d %H:%M"),
                                                 "durationMinutes": 60})]}, "tool_calls")
            elif n == 4:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "listCalendarEvents", {})]}, "tool_calls")
            elif n == 5:
                sse(self.wfile, model, {"role": "assistant", "tool_calls": [
                    call(0, "deleteCalendarEvent", {"title": "E2E 自清理日程",
                                                    "date": ev_start.strftime("%Y-%m-%d")})]}, "tool_calls")
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
    shutil.copy(FIXTURE_ASSETS / "probe3.pdf", fix_dir / "probe3.pdf")
    # v20 文档/表格 fixture：docx 由 textutil 打包（系统转换器），xlsx 手写
    # 最小工作簿（zip + XML——不需要 Excel），csv 含引号/逗号/中文。
    (fix_dir / "doc.txt").write_text(
        "Desire 文档读取 fixture\n\nDOC-MARKER-ALPHA 第一段正文\nDOC-MARKER-BETA 第二段正文\n")
    import subprocess as _sp
    _sp.run(["textutil", "-convert", "docx", "-output", str(fix_dir / "doc.docx"),
             str(fix_dir / "doc.txt")], check=True, capture_output=True)
    (fix_dir / "orders.csv").write_text(
        'name,qty,note\n"ACME, Inc.",12,"含逗号, 引号"\nBeta,3,ok\n')
    import zipfile as _zip
    _shared = ('<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
               '<si><t>商品</t></si><si><t>价格</t></si></sst>')
    _sheet = ('<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<sheetData>'
              '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
              '<row r="2"><c r="A2" t="inlineStr"><is><t>样品A</t></is></c><c r="B2"><v>19.9</v></c></row>'
              '<row r="3"><c r="A3" t="inlineStr"><is><t>样品B</t></is></c><c r="B3"><v>35</v></c></row>'
              '</sheetData></worksheet>')
    _wb = ('<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
           'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
           '<sheets><sheet name="报价单" sheetId="1" r:id="rId1"/></sheets></workbook>')
    with _zip.ZipFile(fix_dir / "quote.xlsx", "w") as _z:
        _z.writestr("xl/sharedStrings.xml", _shared)
        _z.writestr("xl/worksheets/sheet1.xml", _sheet)
        _z.writestr("xl/workbook.xml", _wb)
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
    # MUSCLE17 的预算恢复值：测试真正改过预算才回填，中途失败不回填（不碰用户设置）。
    _orig_budget = None
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

        # ── MUSCLE4：OS 协作读写闭环（本机已授权；提醒+日程全自清理）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE4 OS 读写闭环"})
        deadline4 = time.time() + 150
        while time.time() < deadline4:
            ap4 = bridge("GET", "/approvals")
            if ap4.get("pending"):
                # deleteCalendarEvent 是 dangerous：测试侧替用户放行一次
                # （顺带覆盖桥审批闸门的真实路径）。
                bridge("POST", "/approvals/resolve", {"decision": "allow_once"})
                time.sleep(0.5)
                continue
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
        event_added = next((t for t in tools4 if t.startswith("Event added: E2E 自清理日程")), "")
        event_deleted = next((t for t in tools4 if t.startswith("Event deleted: E2E 自清理日程")), "")
        ok("提醒创建（真机 · 已授权路径）", made.startswith("Reminder added"))
        ok("提醒完成闭环", done.startswith("Reminder completed"))
        ok("读回已不含完成的提醒", "E2E 自清理提醒" not in open_list)
        ok("日历写入 + 读取可用（自建事件读回）",
           event_added != "" and "E2E 自清理日程" in events_list)
        ok("日历删除走 dangerous 审批并落地（测试侧放行）", event_deleted != "")

        # ── MUSCLE5：PDF 合并 / 抽页（结构级，文本层保留）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE5 PDF 工具链"})
        deadline5 = time.time() + 120
        while time.time() < deadline5:
            st5 = bridge("GET", "/agent/messages")
            if not st5.get("busy") and any("MUSCLE5-DONE" in (m.get("content") or "")
                                           for m in st5.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv5_id = bridge("GET", "/agent/trace").get("conversation")
        conv5 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv5_id}.json").read_text())
        tools5 = [m.get("content") or "" for m in conv5.get("messages", []) if m.get("role") == "tool"]
        split_result = next((t for t in tools5 if t.startswith("Extracted")), "")
        merge_result = next((t for t in tools5 if t.startswith("Merged")), "")
        merged_read = next((t for t in tools5 if t.startswith("PDF text (4 page")), "")
        split_read = next((t for t in tools5 if t.startswith("PDF text (1 page")), "")
        ok("抽页成功（第 2 页）", split_result.startswith("Extracted 1 page(s)"))
        ok("合并成功（1+3=4 页）", merge_result.startswith("Merged 2 PDFs"))
        ok("合并产物含两源文本层", "88000" in merged_read and "PAGE-ONE-ALPHA" in merged_read)
        ok("抽页产物是正确的那一页", "PAGE-TWO-BRAVO" in split_read and "PAGE-ONE-ALPHA" not in split_read)
        notes = (fix_dir / "notes.txt").read_text()
        ok("文件实际已改", ("NEW_TOKEN" in notes) and ("OLD_TOKEN" not in notes))

        # ── MUSCLE6：文档/表格读取（docx / xlsx / csv + 错类型 Error: 约定）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE6 文档表格读取"})
        deadline6 = time.time() + 120
        while time.time() < deadline6:
            st6 = bridge("GET", "/agent/messages")
            if not st6.get("busy") and any("MUSCLE6-DONE" in (m.get("content") or "")
                                           for m in st6.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv6_id = bridge("GET", "/agent/trace").get("conversation")
        conv6 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv6_id}.json").read_text())
        tools6 = [m.get("content") or "" for m in conv6.get("messages", []) if m.get("role") == "tool"]
        doc_out = next((t for t in tools6 if t.startswith("Document text (docx")), "")
        xlsx_out = next((t for t in tools6 if t.startswith('Spreadsheet "报价单"')), "")
        csv_out = next((t for t in tools6 if 'Spreadsheet "orders.csv"' in t), "")
        wrong_out = next((t for t in tools6 if t.startswith("Error:")), "")
        ok("docx 取文（两端标记句都在）", "DOC-MARKER-ALPHA" in doc_out and "DOC-MARKER-BETA" in doc_out)
        ok("xlsx 表名/表头/数值（缓存值）", "报价单" in xlsx_out and "商品" in xlsx_out
           and "19.9" in xlsx_out and "样品B" in xlsx_out)
        ok("csv 引号字段正确切分", "ACME, Inc." in csv_out and "含逗号, 引号" in csv_out)
        ok("错类型走 Error: 约定并指对工具", wrong_out.startswith("Error:") and "readSpreadsheet" in wrong_out)

        # ── MUSCLE7：标签治理（pin / mute / move / setZoom + listTabs 状态标记）──
        state7 = bridge("GET", "/state")
        fixture_idx = next((t.get("index") for t in state7.get("tabs", [])
                            if "/flaky" in (t.get("url") or "")), None)
        assert fixture_idx is not None, "找不到 fixture 标签（/flaky）"
        Fake.tab_index = fixture_idx
        Fake.move_to = fixture_idx - 1 if fixture_idx > 0 else fixture_idx + 1
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE7 标签治理"})
        deadline7 = time.time() + 120
        while time.time() < deadline7:
            st7 = bridge("GET", "/agent/messages")
            if not st7.get("busy") and any("MUSCLE7-DONE" in (m.get("content") or "")
                                           for m in st7.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv7_id = bridge("GET", "/agent/trace").get("conversation")
        conv7 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv7_id}.json").read_text())
        tools7 = [m.get("content") or "" for m in conv7.get("messages", []) if m.get("role") == "tool"]
        baseline = next((l for t in tools7 for l in (t or "").splitlines()
                         if l.startswith(f"[{fixture_idx}]")), "")
        pin_out = next((t for t in tools7 if t.startswith("Pinned tab")), "")
        mute_out = next((t for t in tools7 if t.startswith("Muted tab")), "")
        zoom_out = next((t for t in tools7 if t.startswith("Zoom set to")), "")
        move_out = next((t for t in tools7 if t.startswith("Moved tab")), "")
        final_out = tools7[-1] if tools7 else ""
        ok("listTabs 基线无状态标记", bool(baseline) and "[pinned" not in baseline and "[muted" not in baseline)
        ok("pinTab 落地", pin_out.startswith(f"Pinned tab {fixture_idx}"))
        ok("muteTab 落地（劫持式静音）", mute_out.startswith(f"Muted tab {fixture_idx}") and "blocked" in mute_out)
        ok("setZoom 落到 125%", zoom_out == "Zoom set to 125%")
        ok("moveTab 落到目标位", move_out.startswith(f"Moved tab {fixture_idx} → {Fake.move_to}"))
        final_line = next((l for l in final_out.splitlines() if l.startswith(f"[{Fake.move_to}]")), "")
        ok("listTabs 复查：标记齐 + 位次正确",
           "[pinned,muted,zoom 125%]" in final_line and "/flaky" in final_line)

        # ── MUSCLE8：窗口/工作区/隐私标签（全部在**新窗口**里做）──
        # 回合 A 开新窗口（新窗口即 key → deliveryTarget 切到它的会话），
        # 回合 B 的 save/restore 都在新窗口的 tabManager 上跑——用户窗口零触碰。
        def windows_live():
            """真实可见的窗口（关掉的窗口会滞留为不可见的会话条目）。"""
            data = bridge("GET", "/agent/windows")
            wins = data.get("windows", []) if isinstance(data, dict) else data
            return [w for w in wins if w.get("windowVisible")]

        def window_count():
            return len(windows_live())

        wins_before = window_count()
        # 回合 A 里新窗口一开就是 key → deliveryTarget 立刻切到新窗口的会话，
        # /agent/trace 跟着走。先记下**当前**（用户窗口）会话 id，事后按 id
        # 取它的 conversationId 读盘。
        old_session_id = next((w["id"] for w in windows_live() if w.get("isNewest")), None)
        assert old_session_id, "找不到当前窗口的会话 id"
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE8A 新窗口"})
        deadlineA = time.time() + 60
        while time.time() < deadlineA:
            stA = bridge("GET", "/agent/messages")
            if not stA.get("busy") and any("MUSCLE8A-DONE" in (m.get("content") or "")
                                           for m in stA.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(2)   # 等 deliveryTarget 落到新窗口会话
        convA_id = next((w.get("conversationId") or "" for w in windows_live()
                         if w["id"] == old_session_id), "")
        assert convA_id, "回合 A 的会话没有 conversationId"
        convA = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{convA_id}.json").read_text())
        newwin_out = next((m.get("content") or "" for m in convA.get("messages", [])
                           if m.get("role") == "tool"), "")
        wins_after = window_count()
        ok("newWindow 开窗并加载 fixture", newwin_out.startswith("Opened a new window with")
           and f"127.0.0.1:{API_PORT}/fixture" in newwin_out)
        ok("窗口数增加", wins_after == wins_before + 1)
        if wins_after != wins_before + 1:
            # 硬中止：没有新窗口就继续的话，MUSCLE8B 的工作区替换/关窗会
            # 全部落在**用户窗口**上（2026-10-15 实测踩过一次）。
            raise AssertionError("MUSCLE8A 没有开出新窗口——跳过 MUSCLE8B（避免误伤用户窗口）")
        # 投递目标确实切到新窗口（背后是"新窗口成为 key"这件事）
        new_session_id = next((w["id"] for w in windows_live() if w.get("isNewest")), None)
        if new_session_id is None or new_session_id == old_session_id:
            raise AssertionError("新窗口没有取得投递目标——MUSCLE8B 会跑进用户窗口，中止")

        # 回合 B：新窗口的会话里做工作区闭环
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE8B 工作区闭环"})
        deadlineB = time.time() + 120
        while time.time() < deadlineB:
            stB = bridge("GET", "/agent/messages")
            msgsB = stB.get("messages", []) if isinstance(stB, dict) else []
            if any("MUSCLE8-DONE" in (m.get("content") or "") for m in msgsB):
                break
            # closeWindow 是最后一步：窗口一关就没有最终消息了，等
            # "Deleted workspace" 出现即可（后续 closeWindow 不影响断言）。
            if any("Deleted workspace" in (m.get("content") or "") for m in msgsB):
                break
            time.sleep(1)
        time.sleep(2)   # 等 closeWindow 落地 + 会话文件 flush
        # **按新窗口会话 id 读盘**：回合 B 的最后一步是 closeWindow——

        # 窗口一关 deliveryTarget 就挪回别的窗口，/agent/trace（跟 deliveryTarget）
        # 会读到别人的会话（2026-10-15 实测：断言全红而工具其实全对）。
        # 会话条目在窗口关闭后仍短暂在列（hidden），带 conversationId。
        convB_id = next((w.get("conversationId") or ""
                         for w in bridge("GET", "/agent/windows").get("windows", [])
                         if w["id"] == new_session_id), "")
        assert convB_id, "新窗口会话没有 conversationId"
        convB = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{convB_id}.json").read_text())
        toolsB = [m.get("content") or "" for m in convB.get("messages", []) if m.get("role") == "tool"]
        save_out = next((t for t in toolsB if t.startswith('Saved workspace "E2E-MUSCLE8"')), "")
        incog_out = next((t for t in toolsB if "private tab" in t), "")
        ws_list_1 = next((t for t in toolsB if "E2E-MUSCLE8 —" in t), "")
        tabs_after_incog = next((t for t in toolsB if "[incognito]" in t), "")
        if not tabs_after_incog:
            print("MUSCLE8 诊断：未找到 [incognito] 标记；listTabs 候选输出 →",
                  [t[:160] for t in toolsB if t.startswith("[0]")][:3])
        restore_out = next((t for t in toolsB if t.startswith('Restored workspace "E2E-MUSCLE8"')), "")
        restore_idx = toolsB.index(restore_out) if restore_out in toolsB else -1
        tabs_after_restore = next((t for t in toolsB[restore_idx + 1:]
                                   if t.startswith("[0]") and "—" in t), "") if restore_idx >= 0 else ""
        ws_list_2 = [t for t in toolsB if "tab(s) — saved" in t or t == "No workspaces saved"]
        delete_out = next((t for t in toolsB if t.startswith('Deleted workspace "E2E-MUSCLE8"')), "")
        ws_after_delete = bridge("GET", "/workspaces").get("workspaces", [])
        ok("saveWorkspace 快照（2 个标签）", save_out.startswith('Saved workspace "E2E-MUSCLE8" (2 tab(s))'))
        ok("openIncognitoTab 开隐私标签", incog_out.startswith("Opened a private tab") and "not recorded" in incog_out)
        ok("listWorkspaces 含快照", "E2E-MUSCLE8 — 2 tab(s)" in ws_list_1)
        ok("listTabs 显示 incognito 标记", "[incognito]" in tabs_after_incog)
        ok("restoreWorkspace 替换为快照（隐私标签消失）",
           restore_out.startswith('Restored workspace "E2E-MUSCLE8"')
           and "previous tabs were replaced" in restore_out
           and tabs_after_restore != "" and "[incognito]" not in tabs_after_restore
           and len(tabs_after_restore.splitlines()) == 2)
        # 删除后的"不在列表"用**桥端点**核（回合内的 listWorkspaces 输出
        # 都发生在删除之前——拿它当删除后的证据是刻舟求剑）。
        ok("deleteWorkspace 后列表不含快照",
           delete_out == 'Deleted workspace "E2E-MUSCLE8"'
           and all(w.get("name") != "E2E-MUSCLE8" for w in ws_after_delete))
        # 窗口自清理：closeWindow（回合最后一步）后活窗口数回落
        win_deadline = time.time() + 8
        while time.time() < win_deadline and window_count() != wins_before:
            time.sleep(0.5)
        ok("closeWindow 后活窗口数回落", window_count() == wins_before)

        # ── MUSCLE9：标签组改名 + 历史定向清理（都只碰 fixture 相关对象）──
        # fixture 标签在用户窗口里；MUSCLE8 刚关掉测试窗口，/state 的活动窗口
        # 归属可能有一瞬没落定——重试几拍并打印现场。
        fix_idx9 = None
        for _attempt in range(6):
            st9 = bridge("GET", "/state")
            fix_idx9 = next((t.get("index") for t in st9.get("tabs", [])
                             if "/fixture" in (t.get("url") or "") or "/flaky" in (t.get("url") or "")), None)
            if fix_idx9 is not None:
                break
            time.sleep(0.5)
        assert fix_idx9 is not None, (
            "找不到 fixture 标签（MUSCLE9 要切回它）；/state tabs="
            + str([(t.get("index"), t.get("url")) for t in st9.get("tabs", [])]))
        Fake.tab_index = fix_idx9
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE9 标签组与历史清理"})
        deadline9 = time.time() + 120
        while time.time() < deadline9:
            st9b = bridge("GET", "/agent/messages")
            if not st9b.get("busy") and any("MUSCLE9-DONE" in (m.get("content") or "")
                                            for m in st9b.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv9_id = bridge("GET", "/agent/trace").get("conversation")
        conv9 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                            / f"conversation-{conv9_id}.json").read_text())
        tools9 = [m.get("content") or "" for m in conv9.get("messages", []) if m.get("role") == "tool"]
        group_add = next((t for t in tools9 if "to group: E2E 组" in t), "")
        group_rename = next((t for t in tools9 if t.startswith("Renamed group")), "")
        hist_delete = next((t for t in tools9 if t.startswith("Removed")), "")
        groups_list = next((t for t in tools9 if "E2E 组（改名）" in t), "")
        # getHistory 的结果必须取**删除之后**那条（写在前面的 deleteHistory
        # 自己也含 "127.0.0.1"，按内容搜会抓错——实测踩过）
        hist_idx = tools9.index(hist_delete) if hist_delete in tools9 else -1
        history_out = next((t for t in (tools9[hist_idx + 1:] if hist_idx >= 0 else [])
                            if "— http" in t or t == "No history entries"), "")
        removed_n = 0
        if hist_delete:
            with contextlib.suppress(Exception):
                removed_n = int(hist_delete.split()[1])
        ok("标签组创建并入组（fixture 标签）", group_add.startswith("Created and added to group: E2E 组"))
        ok("标签组改名", group_rename == 'Renamed group "E2E 组" → "E2E 组（改名）"')
        # listTabGroups 行格式："<name> (N tabs): ..."——旧名后跟 " ("，而
        # 新名是 "E2E 组（改名） ("，两者不互相误匹配。
        ok("listTabGroups 显示新名", "E2E 组（改名）" in groups_list and "E2E 组 (" not in groups_list)
        ok("deleteHistory 按域名删除（≥1 条）",
           hist_delete.startswith("Removed ") and "domain 127.0.0.1" in hist_delete and removed_n >= 1)
        ok("删除后 getHistory 不再含该域名", "127.0.0.1" not in history_out)

        # ── MUSCLE10：分屏 + 标签组折叠（fixture 标签为左栏；右栏用 user tab 0，
        #    只是显示、可逆，随后解除）──
        st10 = bridge("GET", "/state")
        fix10 = next((t.get("index") for t in st10.get("tabs", [])
                      if "/fixture" in (t.get("url") or "") or "/flaky" in (t.get("url") or "")), None)
        assert fix10 is not None, "找不到 fixture 标签（MUSCLE10 需要它做左栏）"
        other10 = next((t.get("index") for t in st10.get("tabs", []) if t.get("index") != fix10), None)
        assert other10 is not None, "没有第二个标签可做右栏"
        # 先把当前标签切到 fixture（分屏左栏 = 选中标签）
        bridge("POST", "/switch-tab", {"index": fix10})
        time.sleep(0.5)
        Fake.split_partner = other10
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE10 分屏与组折叠"})
        deadline10 = time.time() + 120
        while time.time() < deadline10:
            st10b = bridge("GET", "/agent/messages")
            if not st10b.get("busy") and any("MUSCLE10-DONE" in (m.get("content") or "")
                                             for m in st10b.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv10_id = bridge("GET", "/agent/trace").get("conversation")
        conv10 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv10_id}.json").read_text())
        tools10 = [m.get("content") or "" for m in conv10.get("messages", []) if m.get("role") == "tool"]
        split_out = next((t for t in tools10 if t.startswith("Split view:")), "")
        collapse_out = next((t for t in tools10 if t.startswith("Collapsed tab group")), "")
        unsplit_out = next((t for t in tools10 if t in ("Left split view", "Not in split view")), "")
        ok("splitView 进入分屏（右栏到位）", split_out.startswith("Split view:")
           and f"right pane = tab {other10}" in split_out)
        ok("collapseTabGroup 折叠", collapse_out == 'Collapsed tab group "E2E 组（改名）"')
        ok("unsplitView 解除分屏", unsplit_out == "Left split view")
        # 桥面复核：分屏已解除 + 组折叠态已持久化
        split_state = bridge("GET", "/split")
        groups_state = bridge("GET", "/tab-groups").get("groups", [])
        grouped = next((g for g in groups_state if g.get("name") == "E2E 组（改名）"), {})
        ok("桥复核：分屏已解除", split_state.get("partner") in (None, "") or split_state.get("partner") is None)
        ok("桥复核：组折叠态已存", grouped.get("collapsed") is True)

        # ── MUSCLE11：收件箱（手造待回复会话 + 强制扣通知→补推）──
        import uuid as _uuid
        storage = Path.home() / "Library/Application Support/Desire/storage"
        fab_id = str(_uuid.uuid4()).upper()
        now_ref = time.time() - 978307200  # ReferenceDate 秒（手造会话的既定手法）
        fab = {
            "id": fab_id, "title": "INBOX-E2E 待回复", "createdAt": now_ref - 60,
            "updatedAt": now_ref, "inputHistory": [], "turnActive": False,
            "messages": [
                {"id": str(_uuid.uuid4()).upper(), "role": "user",
                 "content": "INBOX-E2E 在等回复", "createdAt": now_ref - 60},
                {"id": str(_uuid.uuid4()).upper(), "role": "user",
                 "content": "INBOX-E2E 最后这条没有回复", "createdAt": now_ref},
            ],
        }
        fab_path = storage / f"conversation-{fab_id}.json"
        fab_path.write_text(json.dumps(fab, ensure_ascii=False))
        time.sleep(1)
        inbox1 = bridge("GET", "/inbox")
        fab_rows = [it for sec in inbox1.get("sections", []) for it in sec.get("items", [])
                    if it.get("conversationId") == fab_id]
        ok("收件箱：待回复会话进入 action 节",
           bool(fab_rows) and fab_rows[0].get("kind") == "unanswered"
           and "没有回复" in (fab_rows[0].get("detail") or "")
           and inbox1.get("actionCount", 0) >= 1)
        fab_path.unlink(missing_ok=True)
        time.sleep(1)
        inbox2 = bridge("GET", "/inbox")
        ok("收件箱：删文件后不再列出",
           not any(it.get("conversationId") == fab_id
                   for sec in inbox2.get("sections", []) for it in sec.get("items", [])))

        # 被扣通知：临时强制免打扰 → notify(routine) → 进收件箱 → 补推 → 消失
        policy_before = bridge("GET", "/notifications/policy").get("policy", {})
        bridge("POST", "/notifications/policy",
               {"quietHoursEnabled": True, "quietStart": "00:00", "quietEnd": "23:59"})
        try:
            bridge("POST", "/agent/new", {})
            bridge("POST", "/agent/send", {"text": "MUSCLE11 收件箱扣通知"})
            deadline11 = time.time() + 90
            while time.time() < deadline11:
                st11 = bridge("GET", "/agent/messages")
                if not st11.get("busy") and any("MUSCLE11-DONE" in (m.get("content") or "")
                                                for m in st11.get("messages", [])):
                    break
                time.sleep(1)
            time.sleep(1.5)
            inbox3 = bridge("GET", "/inbox")
            held_rows = [it for sec in inbox3.get("sections", []) for it in sec.get("items", [])
                         if it.get("kind") == "heldNotification"]
            ok("收件箱：被扣通知聚合一行", bool(held_rows) and "1" in (held_rows[0].get("title") or ""))
            bridge("POST", "/notifications/flush")
            time.sleep(0.8)
            inbox4 = bridge("GET", "/inbox")
            ok("收件箱：补推后 held 行消失",
               not any(it.get("kind") == "heldNotification"
                       for sec in inbox4.get("sections", []) for it in sec.get("items", [])))
        finally:
            bridge("POST", "/notifications/policy", {
                "quietHoursEnabled": policy_before.get("quietHoursEnabled", False),
                "quietStart": policy_before.get("quietStart", "23:00"),
                "quietEnd": policy_before.get("quietEnd", "08:00"),
                "dailyRoutineLimit": policy_before.get("dailyRoutineLimit", 12),
            })
        # ── MUSCLE12：归档会话（手造归档 → 列表 → 在新窗口恢复 → 复核 → 关窗）──
        arch_dir = Path.home() / "Library/Application Support/Desire/session-archives"
        arch_dir.mkdir(parents=True, exist_ok=True)
        arch_name = f"archived-session-E2E12-{int(time.time())}.json"
        (arch_dir / arch_name).write_text(json.dumps({
            "tabs": [
                {"url": f"http://127.0.0.1:{API_PORT}/archive-marker",
                 "isOnNewTabPage": False, "isPinned": False},
                {"url": None, "isOnNewTabPage": True, "isPinned": False},
            ],
            "selectedIndex": 0,
        }, ensure_ascii=False))
        Fake.archive_file = arch_name
        listed = bridge("GET", "/session-archives").get("archives", [])
        arch_row = next((a for a in listed if a.get("file") == arch_name), {})
        ok("桥：归档列表含手造条目（2 标签）",
           arch_row.get("tabs") == 2
           and any("/archive-marker" in u for u in arch_row.get("urls", [])))
        # 回合 A：开测试窗口（用户窗口里跑）；回合 B：在测试窗口里恢复归档
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE12A 开窗"})
        deadlineA12 = time.time() + 60
        while time.time() < deadlineA12:
            stA12 = bridge("GET", "/agent/messages")
            if not stA12.get("busy") and any("MUSCLE12A-DONE" in (m.get("content") or "")
                                             for m in stA12.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(2)
        # 不按 windowVisible 筛：不带 URL 的新窗口展示原生新标签页（无 webview），
        # 活性信号对它天然为 false——用 isNewest（工具会 makeKey）判定新窗。
        all12 = bridge("GET", "/agent/windows").get("windows", [])
        new12 = next((w["id"] for w in all12 if w.get("isNewest")), None)
        assert new12 and new12 != old_session_id, "MUSCLE12A 没有开出新窗口（中止避免误伤）"
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE12 归档恢复"})
        deadline12 = time.time() + 120
        while time.time() < deadline12:
            st12 = bridge("GET", "/agent/messages")
            if not st12.get("busy") and any("MUSCLE12-DONE" in (m.get("content") or "")
                                            for m in st12.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(2)
        conv12_id = next((w.get("conversationId") or ""
                          for w in bridge("GET", "/agent/windows").get("windows", [])
                          if w["id"] == new12), "")
        conv12 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv12_id}.json").read_text())
        tools12 = [m.get("content") or "" for m in conv12.get("messages", []) if m.get("role") == "tool"]
        list12 = next((t for t in tools12 if arch_name in t), "")
        restore12 = next((t for t in tools12 if t.startswith("Restored archived session")), "")
        tabs12 = next((t for t in tools12 if "/archive-marker" in t and t.startswith("[0]")), "")
        ok("listArchivedSessions 列出条目（2 标签）", "2 tab(s)" in list12 and arch_name in list12)
        ok("restoreArchivedSession 恢复（替换窗口标签）",
           restore12.startswith("Restored archived session") and "2 tab(s) now open" in restore12)
        ok("恢复后的标签含归档标记 URL", "/archive-marker" in tabs12)
        # 窗口收尾（closeWindow 留住 finally 的兜底）
        win_deadline12 = time.time() + 8
        while time.time() < win_deadline12 and len(windows_live()) > wins_before:
            time.sleep(0.5)
        ok("MUSCLE12 测试窗口已关闭", len(windows_live()) <= wins_before)
        # ── MUSCLE13：readURL 离屏取正文（不开标签）──
        st13 = bridge("GET", "/state")
        tabs13_before = len(st13.get("tabs", []))
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE13 readURL 离屏取文"})
        deadline13 = time.time() + 120
        while time.time() < deadline13:
            st13b = bridge("GET", "/agent/messages")
            if not st13b.get("busy") and any("MUSCLE13-DONE" in (m.get("content") or "")
                                             for m in st13b.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv13_id = bridge("GET", "/agent/trace").get("conversation")
        conv13 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv13_id}.json").read_text())
        tools13 = [m.get("content") or "" for m in conv13.get("messages", []) if m.get("role") == "tool"]
        open13 = next((t for t in tools13 if "(from the open tab)" in t), "")
        offscreen13 = next((t for t in tools13 if "(loaded off-screen)" in t), "")
        bad13 = next((t for t in tools13 if t.startswith("Error:")), "")
        time.sleep(0.5)
        tabs13_after = len(bridge("GET", "/state").get("tabs", []))
        ok("readURL 走已开标签路径（含正文）",
           open13.startswith("Page text (from the open tab)")
           and ("右键目标" in open13 or "FLAKY-FULL-OK" in open13 or "flaky" in open13))
        ok("readURL 离屏路径（JSON 靶服务正文）",
           offscreen13.startswith("Page text (loaded off-screen)") and "muscle-http" in offscreen13)
        ok("readURL 坏 URL 走 Error: 约定", bad13.startswith("Error:"))
        ok("readURL 不开新标签", tabs13_after == tabs13_before)
        # ── MUSCLE14：数值盯梢（fixture 改价 → 历史 + 跨线告警）──
        TinyAPI.price_hits = 0
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE14 数值盯梢"})
        deadline14 = time.time() + 150
        while time.time() < deadline14:
            st14 = bridge("GET", "/agent/messages")
            if not st14.get("busy") and any("MUSCLE14-DONE" in (m.get("content") or "")
                                            for m in st14.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv14_id = bridge("GET", "/agent/trace").get("conversation")
        conv14 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv14_id}.json").read_text())
        tools14 = [m.get("content") or "" for m in conv14.get("messages", []) if m.get("role") == "tool"]
        add14 = next((t for t in tools14 if "Added page watch" in t), "")
        check14a = next((t for t in tools14 if t.startswith("Checked «E2E 价格»") and "latest value" in t), "")
        alert14 = next((t for t in tools14 if "alert:" in t and "Dropped below" in t), "")
        list14 = next((t for t in tools14 if "numbers: latest" in t), "")
        remove14 = next((t for t in tools14 if t.startswith("Removed page watch")), "")
        watch_left = [w for w in bridge("GET", "/watches").get("watches", []) if w.get("name") == "E2E 价格"]
        ok("addPageWatch 建数值监视", add14.startswith("Added page watch") and ".price" in add14)
        ok("基线读数记录（1,299）", "1299" in check14a.replace(",", ""))
        ok("改价后跨线告警（低于 1200）",
           alert14 != "" and "Dropped below" in alert14 and "1150" in alert14.replace(",", ""))
        ok("listPageWatches 带数值面与告警",
           "numbers: latest 1150" in list14.replace(",", "") and "last alert:" in list14)
        ok("removePageWatch 清干净（桥复核）", remove14 != "" and not watch_left)
        # ── MUSCLE15：每站缩放记忆（工具/菜单改的缩放下次导航不再被压回去）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE15 每站缩放记忆"})
        deadline15 = time.time() + 150
        while time.time() < deadline15:
            st15 = bridge("GET", "/agent/messages")
            if not st15.get("busy") and any("MUSCLE15-DONE" in (m.get("content") or "")
                                            for m in st15.get("messages", [])):
                break
            time.sleep(1)
        time.sleep(1)
        conv15_id = bridge("GET", "/agent/trace").get("conversation")
        conv15 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv15_id}.json").read_text())
        tools15 = [m.get("content") or "" for m in conv15.get("messages", []) if m.get("role") == "tool"]
        reset15 = next((t for t in tools15 if t == "Zoom reset to 100%"), "")
        set15 = next((t for t in tools15 if t == "Zoom set to 150%"), "")
        after_nav = next((t for t in tools15 if "/hello" in t and "zoom 150%" in t), "")
        ok("resetZoom 清零基线", reset15 == "Zoom reset to 100%")
        ok("setZoom 150 生效", set15 == "Zoom set to 150%")
        ok("同站导航后缩放被应用回来（150% 保持）", after_nav != "")
        final_lists = [t for t in tools15 if t.startswith("[0]")]
        # 只看当前标签（/flaky 那行）——旧写法扫全窗口所有标签行，别家标签的
        # zoom 标记会把结论污染成偶发假阳（2026-10-17 run2 实测）。
        current_line = next((ln for ln in final_lists[-1].splitlines() if "/flaky" in ln), "") if final_lists else ""
        cleared = current_line != "" and "zoom" not in current_line.lower()
        ok("reset 后站点记忆清除（再导航不带上缩放）", bool(cleared))
        # ── MUSCLE16：朗读工具（端上 TTS；/speech 观察在讲/停了）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE16A 朗读这段"})
        deadline16 = time.time() + 150
        while time.time() < deadline16:
            st16 = bridge("GET", "/agent/messages")
            if not st16.get("busy") and any("MUSCLE16A-DONE" in (m.get("content") or "")
                                            for m in st16.get("messages", [])):
                break
            time.sleep(1)
        conv16_id = bridge("GET", "/agent/trace").get("conversation")
        conv16 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv16_id}.json").read_text())
        tools16 = [m.get("content") or "" for m in conv16.get("messages", []) if m.get("role") == "tool"]
        read16 = next((t for t in tools16 if t.startswith("Reading aloud")), "")
        ok("readAloud 文本路径回执", read16 != "" and "chars" in read16)
        ok("朗读中（/speech speaking）", bridge("GET", "/speech").get("speaking") is True)
        bridge("POST", "/agent/send", {"text": "MUSCLE16B 停"})
        deadline16b = time.time() + 150
        while time.time() < deadline16b:
            st16b = bridge("GET", "/agent/messages")
            if not st16b.get("busy") and any("MUSCLE16B-DONE" in (m.get("content") or "")
                                             for m in st16b.get("messages", [])):
                break
            time.sleep(1)
        ok("stopSpeaking 后停住（/speech speaking=false）",
           bridge("GET", "/speech").get("speaking") is False)
        # 无 text：从当前页提取正文朗读（/article fixture；标题进回执）
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE16C 念这篇"})
        deadline16c = time.time() + 150
        while time.time() < deadline16c:
            st16c = bridge("GET", "/agent/messages")
            if not st16c.get("busy") and any("MUSCLE16C-DONE" in (m.get("content") or "")
                                             for m in st16c.get("messages", [])):
                break
            time.sleep(1)
        conv16c_id = bridge("GET", "/agent/trace").get("conversation")
        conv16c = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                              / f"conversation-{conv16c_id}.json").read_text())
        tools16c = [m.get("content") or "" for m in conv16c.get("messages", []) if m.get("role") == "tool"]
        page16 = next((t for t in tools16c if t.startswith("Reading aloud")), "")
        ok("readAloud 页面提取路径（回执带标题）", "Article Fixture" in page16)
        ok("页面路径也在讲", bridge("GET", "/speech").get("speaking") is True)
        bridge("POST", "/speech/stop", {})
        time.sleep(0.5)
        ok("桥 /speech/stop 收尾（speaking=false）", bridge("GET", "/speech").get("speaking") is False)
        # ── MUSCLE17：会话预算与超支提醒（假端点 usage 推过阈值）──
        old_budget = bridge("GET", "/agent/budget").get("budget", 0)
        _orig_budget = old_budget
        bridge("POST", "/agent/budget", {"tokens": 500})
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE17A 预算预警"})
        deadline17 = time.time() + 150
        while time.time() < deadline17:
            st17 = bridge("GET", "/agent/messages")
            if not st17.get("busy") and any("MUSCLE17A-DONE" in (m.get("content") or "")
                                            for m in st17.get("messages", [])):
                break
            time.sleep(1)
        b17 = bridge("GET", "/agent/budget")
        ok("预算：首轮用满 460/500 → state=warning",
           b17.get("state") == "warning" and b17.get("used", 0) >= 460 and b17.get("percent", 0) >= 92)
        bridge("POST", "/agent/send", {"text": "MUSCLE17B 续跑"})
        deadline17b = time.time() + 150
        while time.time() < deadline17b:
            st17b = bridge("GET", "/agent/messages")
            if not st17b.get("busy") and any("预算已用尽" in (m.get("content") or "")
                                             for m in st17b.get("messages", [])):
                break
            time.sleep(1)
        conv17_id = bridge("GET", "/agent/trace").get("conversation")
        conv17 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv17_id}.json").read_text())
        msgs17 = conv17.get("messages", [])
        notice17 = next((m.get("content") or "" for m in msgs17 if "预算已用尽" in (m.get("content") or "")), "")
        tools17 = [m for m in msgs17 if m.get("role") == "tool"]
        ok("预算：超档后回合停在步骤边界并提示（含 920/500）",
           "920" in notice17 and "500" in notice17)
        ok("预算：第二次迭代被拦住（没有 B-DONE）",
           not any("MUSCLE17B-DONE" in (m.get("content") or "") for m in msgs17))
        ok("预算：停机前只执行了一次工具（listTabs）", len(tools17) == 1)
        b17b = bridge("GET", "/agent/budget")
        ok("预算：档位阶梯前进（stopLevel=2，下一档 1000）",
           b17b.get("stopLevel") == 2 and b17b.get("used", 0) >= 920)
        # ── MUSCLE18：热点选题（readURL 读热榜 → 提炼 → 选题库 + 一键安排每日采集）──
        goal18 = bridge("POST", "/promotion/goal", {"title": "MUSCLE18 选题目标", "objective": "E2E"})
        goal18_id = (goal18.get("goal") or {}).get("id", "")
        ok("选题：测试目标已建", goal18_id != "")
        sched18 = bridge("POST", "/promotion/review", {"kind": "dailyTopics"})
        tasks18 = bridge("GET", "/agent/tasks").get("tasks", [])
        ok("选题：桥一键安排每日选题采集",
           sched18.get("ok") is True
           and any(("选题" in (t.get("name") or "")) or ("scout" in (t.get("name") or "").lower())
                   for t in tasks18))
        bridge("POST", "/promotion/review", {"kind": "dailyTopics", "action": "remove"})
        tasks18b = bridge("GET", "/agent/tasks").get("tasks", [])
        ok("选题：撤销后任务消失",
           not any(("选题" in (t.get("name") or "")) or ("scout" in (t.get("name") or "").lower())
                   for t in tasks18b))
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE18 找热点选题"})
        deadline18 = time.time() + 150
        while time.time() < deadline18:
            st18 = bridge("GET", "/agent/messages")
            if not st18.get("busy") and any("MUSCLE18-DONE" in (m.get("content") or "")
                                            for m in st18.get("messages", [])):
                break
            time.sleep(1)
        conv18_id = bridge("GET", "/agent/trace").get("conversation")
        conv18 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv18_id}.json").read_text())
        tools18 = [m.get("content") or "" for m in conv18.get("messages", []) if m.get("role") == "tool"]
        read18 = next((t for t in tools18 if "MUSCLE18HOT" in t), "")
        ok("选题：readURL 实读热榜页（话题进正文）", read18 != "" and "热榜" in read18)
        skills18 = next((t for t in tools18 if "hot-topics" in t), "")
        ok("选题：listSkills 带 hot-topics 内置剧本", skills18 != "")
        state18 = bridge("GET", "/promotion/state")
        posts18 = [p for p in state18.get("posts", []) if (p.get("title") or "").startswith("MUSCLE18 选题")]
        idea1 = next((p for p in posts18 if p.get("title") == "MUSCLE18 选题一"), {})
        idea2 = next((p for p in posts18 if p.get("title") == "MUSCLE18 选题二"), {})
        ok("选题：两条 idea 入库", idea1.get("status") == "idea" and idea2.get("status") == "idea")
        ok("选题：领域随目标关联（goalID 带齐）", idea1.get("goalID") == goal18_id)
        ok("选题：来源链接在正文（带热榜页 URL）",
           f"127.0.0.1:{API_PORT}/hotlist" in (idea1.get("body") or "")
           and f"127.0.0.1:{API_PORT}/hotlist" in (idea2.get("body") or ""))
        # ── MUSCLE19：阅读列表批量摘要（readURL 取文 + 旁路模型摘要 → 条目字段）──
        page19a = f"http://127.0.0.1:{API_PORT}/rlpage1"
        page19b = f"http://127.0.0.1:{API_PORT}/rlpage2"
        before19 = {i.get("url"): i.get("summary") for i in bridge("GET", "/reading-list").get("items", [])}
        bridge("POST", "/reading-list/add", {"title": "MUSCLE19P1", "url": page19a})
        bridge("POST", "/reading-list/add", {"title": "MUSCLE19P2", "url": page19b})
        sum19 = bridge("POST", "/reading-list/summarize", {"urls": [page19a, page19b], "limit": 5})
        ok("摘要：桥触发入队两条", sum19.get("ok") is True and sum19.get("queued") == 2)
        deadline19 = time.time() + 150
        got19 = {}
        while time.time() < deadline19:
            items19 = {i.get("url"): (i.get("summary") or "") for i in bridge("GET", "/reading-list").get("items", [])}
            got19 = items19
            if got19.get(page19a) and got19.get(page19b):
                break
            time.sleep(1)
        ok("摘要：两条摘要落回条目", bool(got19.get(page19a)) and bool(got19.get(page19b)))
        ok("摘要：内容来自页面实读（回显标记）",
           "MUSCLE19P1" in got19.get(page19a, "") and "MUSCLE19P2" in got19.get(page19b, ""))
        untouched = all(
            (i.get("summary") or None) == (before19.get(i.get("url")) or None)
            for i in bridge("GET", "/reading-list").get("items", [])
            if i.get("url") not in (page19a, page19b))
        ok("摘要：只动指定条目（其它条目摘要不变）", untouched)
        # ── MUSCLE20：备忘录工具（参数校验路径；AppleEvent 留给用户在场时授权）──
        bridge("POST", "/agent/new", {})
        bridge("POST", "/agent/send", {"text": "MUSCLE20 备忘录校验"})
        deadline20 = time.time() + 150
        while time.time() < deadline20:
            st20 = bridge("GET", "/agent/messages")
            if not st20.get("busy") and any("MUSCLE20-DONE" in (m.get("content") or "")
                                            for m in st20.get("messages", [])):
                break
            time.sleep(1)
        conv20_id = bridge("GET", "/agent/trace").get("conversation")
        conv20 = json.loads((Path.home() / "Library/Application Support/Desire/storage"
                             / f"conversation-{conv20_id}.json").read_text())
        tools20 = [m.get("content") or "" for m in conv20.get("messages", []) if m.get("role") == "tool"]
        note20 = next((t for t in tools20 if "Missing title" in t), "")
        search20 = next((t for t in tools20 if "2 characters" in t), "")
        ok("备忘录：addNote 缺标题走 Error 约定", note20.startswith("Error:"))
        ok("备忘录：searchNotes 太短走 Error 约定", search20.startswith("Error:"))
        ok("备忘录：校验路径不发 AppleEvent（无授权等待——回合自行收尾）",
           "MUSCLE20-DONE" in " ".join(m.get("content") or "" for m in bridge("GET", "/agent/messages").get("messages", [])))
        # ── MUSCLE21：站点字体（最小字号 + 字体族；桥直接驱动，无模型往返）──
        bridge("POST", "/navigate", {"url": f"http://127.0.0.1:{API_PORT}/fontpage"})
        time.sleep(2)
        r21 = bridge("POST", "/site-settings/font",
                     {"host": "127.0.0.1", "minFontSize": 16, "fontFamily": "Songti SC"})
        ok("站点字体：桥设置回执（生效值 + 站点显式值）",
           r21.get("minFontSize") == 16 and r21.get("siteMinFontSize") == 16)
        time.sleep(0.6)
        probe21 = ("JSON.stringify({"
                   "small:getComputedStyle(document.getElementById('tiny')).fontSize,"
                   "plain:getComputedStyle(document.getElementById('plain')).fontFamily,"
                   "authored:getComputedStyle(document.getElementById('authored')).fontFamily,"
                   "tag:!!document.getElementById('desire-site-font-family'),"
                   "marked:document.getElementById('tiny').hasAttribute('data-desire-minfont')})")
        d21 = json.loads(bridge("POST", "/execute", {"js": probe21}).get("result") or "{}")
        ok("站点字体：最小字号把内联 10px 抬到 16px（带标记）",
           d21.get("small") == "16px" and d21.get("marked") is True)
        ok("站点字体：字体族注入、作者字体优先（Menlo 不被覆盖）",
           "Songti" in (d21.get("plain") or "") and d21.get("authored") == "Menlo"
           and d21.get("tag") is True)
        bridge("POST", "/site-settings/font",
               {"host": "127.0.0.1", "minFontSize": None, "fontFamily": None})
        time.sleep(0.6)
        d21b = json.loads(bridge("POST", "/execute", {"js": (
            "JSON.stringify({small:getComputedStyle(document.getElementById('tiny')).fontSize,"
            "tag:!!document.getElementById('desire-site-font-family')})")}).get("result") or "{}")
        ok("站点字体：清覆盖后原内联字号原样还原（10px / 样式移除）",
           d21b.get("small") == "10px" and d21b.get("tag") is False)
        # ── MUSCLE22：书签导入去重（HTML 解析 + 撞库/组内划分 + 策略落库；桥直接驱动）──
        BM_SEED = "https://seed-bm22.test/keep"
        BM_URLS = [BM_SEED, BM_SEED + "/", "https://fresh-bm22.test/one",
                   "https://fresh-bm22.test/two", "https://fresh-bm22.test/two?x=1"]
        for u in BM_URLS:
            for _ in range(5):
                bridge("POST", "/bookmarks/remove", {"url": u})
        bridge("POST", "/bookmarks/add", {"title": "SEED22", "url": BM_SEED})
        bm_html = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
<DL><p>
  <DT><H3>ImportTest</H3>
  <DL><p>
    <DT><A HREF="https://seed-bm22.test/keep/">SEED22 dup</A>
    <DT><A HREF="https://fresh-bm22.test/one">Fresh One</A>
    <DT><A HREF="https://fresh-bm22.test/two">Fresh Two</A>
    <DT><A HREF="https://fresh-bm22.test/two?x=1">Fresh Two Query</A>
    <DT><A HREF="https://fresh-bm22.test/two">Fresh Two Again</A>
  </DL><p>
</DL><p>
"""
        (Path("/tmp/bm22_import.html")).write_text(bm_html)
        r22 = bridge("POST", "/bookmarks/import", {"path": "/tmp/bm22_import.html", "dryRun": True})
        ok("导入去重：dryRun 统计（total 5 / 撞库 1 / 组内 1 / 全新 3）",
           r22.get("total") == 5 and r22.get("existingDuplicates") == 1
           and r22.get("innerDuplicates") == 1 and r22.get("fresh") == 3)
        r22b = bridge("POST", "/bookmarks/import", {"path": "/tmp/bm22_import.html"})
        ok("导入去重：skipDuplicates 只落全新 3 条", r22b.get("imported") == 3)
        time.sleep(1.2)
        urls22 = [e.get("url") for e in bridge("GET", "/bookmarks").get("entries", [])]
        ok("导入去重：全新三连在库、撞库/组内重复未进",
           all(u in urls22 for u in ("https://fresh-bm22.test/one",
                                     "https://fresh-bm22.test/two",
                                     "https://fresh-bm22.test/two?x=1"))
           and urls22.count(BM_SEED) == 1 and (BM_SEED + "/") not in urls22)
        # ── MUSCLE23：AI 双语对照（分块旁路翻译 → 段落后回填；桥直接驱动）──
        bridge("POST", "/navigate", {"url": f"http://127.0.0.1:{API_PORT}/bipage"})
        time.sleep(2)
        st23 = bridge("POST", "/bilingual", {"on": True})
        ok("双语对照：开启回执 on=true", st23.get("on") is True)
        deadline23 = time.time() + 90
        final23 = {}
        while time.time() < deadline23:
            final23 = bridge("GET", "/bilingual")
            if not final23.get("running") and final23.get("total", 0) > 0:
                break
            time.sleep(1)
        ok("双语对照：流水线收尾、全部段落翻完（done==total≥3）",
           final23.get("done") == final23.get("total") and final23.get("total", 0) >= 3
           and final23.get("error") in (None, "null"))
        d23 = json.loads(bridge("POST", "/execute", {"js": (
            "JSON.stringify({nodes:document.querySelectorAll('.desire-bilingual').length,"
            "texts:[...document.querySelectorAll('.desire-bilingual')].map(function(n){return n.textContent}),"
            "marked:document.querySelectorAll('[data-desire-bi]').length})")}).get("result") or "{}")
        texts23 = d23.get("texts") or []
        ok("双语对照：译文节点数==段落数、带块标记",
           d23.get("nodes") == final23.get("total") and d23.get("marked") == final23.get("total"))
        ok("双语对照：首条按序号对齐且含正文（fox 段）",
           bool(texts23) and texts23[0].startswith("译(1) ")
           and any("quick brown fox" in t for t in texts23))
        st23b = bridge("POST", "/bilingual", {"on": False})
        time.sleep(1)
        d23b = json.loads(bridge("POST", "/execute", {"js": (
            "JSON.stringify({nodes:document.querySelectorAll('.desire-bilingual').length,"
            "marked:document.querySelectorAll('[data-desire-bi]').length})")}).get("result") or "{}")
        ok("双语对照：关闭后译文与标记清零", st23b.get("on") is False
           and d23b.get("nodes") == 0 and d23b.get("marked") == 0)
        assert all(c for _, c in checks), "存在失败项"
        print("\nexecution E2E ALL PASS（%d 项）" % len(checks))
    finally:
        # 朗读兜底：万一 MUSCLE16 中途失败也别让机器一直念。
        try:
            bridge("POST", "/speech/stop", {})
        except Exception:
            pass
        # 摘要兜底（MUSCLE19）：只删本脚本加进去的两条阅读条目（URL 精确匹配）。
        try:
            for pth in ("/rlpage1", "/rlpage2"):
                bridge("POST", "/reading-list/remove", {"url": f"http://127.0.0.1:{API_PORT}{pth}"})
        except Exception:
            pass
        # 选题兜底（MUSCLE18）：只清本脚本创建的 MUSCLE18 选题/目标（前缀精确匹配）
        # 与可能残留的每日选题采集任务。
        try:
            st18f = bridge("GET", "/promotion/state")
            for p in st18f.get("posts", []):
                if (p.get("title") or "").startswith("MUSCLE18 选题"):
                    bridge("POST", "/promotion/post/remove", {"id": p.get("id")})
            for g in st18f.get("goals", []):
                if (g.get("title") or "") == "MUSCLE18 选题目标":
                    bridge("POST", "/promotion/goal/remove", {"id": g.get("id")})
            bridge("POST", "/promotion/review", {"kind": "dailyTopics", "action": "remove"})
        except Exception:
            pass
        # 双语对照兜底（MUSCLE23）：无论如何先关掉（防在跑的批次）。
        try:
            bridge("POST", "/bilingual", {"on": False})
        except Exception:
            pass
        # 日程兜底（MUSCLE4）：万一回合中途失败留下 "E2E 自清理日程"，
        # 用一次小程序化回合删掉（仅当临时档案仍活跃——绝不拿用户真档案跑）。
        try:
            prof_now = bridge("GET", "/ai/profiles")
            active_now = next((p["id"] for p in prof_now.get("profiles", []) if p.get("active")), None)
            if active_now and active_now == temp_id:
                bridge("POST", "/agent/new", {})
                bridge("POST", "/agent/send", {"text": "MUSCLE4CLEAN 兜底清理"})
                dl4c = time.time() + 60
                while time.time() < dl4c:
                    ap4c = bridge("GET", "/approvals")
                    if ap4c.get("pending"):
                        bridge("POST", "/approvals/resolve", {"decision": "allow_once"})
                        continue
                    msgs4c = bridge("GET", "/agent/messages")
                    if not msgs4c.get("busy") and any("MUSCLE4CLEAN-DONE" in (m.get("content") or "")
                                                      for m in msgs4c.get("messages", [])):
                        break
                    time.sleep(1)
        except Exception:
            pass
        # 书签导入兜底（MUSCLE22）：循环删到无副本（find 每次只删第一条）。
        try:
            for u in ("https://seed-bm22.test/keep", "https://seed-bm22.test/keep/",
                      "https://fresh-bm22.test/one", "https://fresh-bm22.test/two",
                      "https://fresh-bm22.test/two?x=1"):
                for _ in range(5):
                    bridge("POST", "/bookmarks/remove", {"url": u})
            Path("/tmp/bm22_import.html").unlink(missing_ok=True)
        except Exception:
            pass
        # 站点字体兜底（MUSCLE21）：清掉本脚本对 127.0.0.1 的覆盖。
        try:
            bridge("POST", "/site-settings/font",
                   {"host": "127.0.0.1", "minFontSize": None, "fontFamily": None})
        except Exception:
            pass
        # 预算兜底：恢复测试前的预算值（别把用户/环境的设置留在 500）。
        try:
            if _orig_budget is not None:
                bridge("POST", "/agent/budget", {"tokens": _orig_budget})
        except Exception:
            pass
        # 关掉测试标签（fixture 页 + 本 fixture 服务器的残留 /dl 页）——
        # 收敛式：每次重快照，因为关一个标签会挪掉后面所有索引。
        try:
            for _ in range(4):
                stale = [t for t in bridge("GET", "/state").get("tabs", [])
                         if "/fixture" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/dl" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/flaky" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/article" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/fontpage" in (t.get("url") or "")
                         or f"127.0.0.1:{API_PORT}/bipage" in (t.get("url") or "")]
                if not stale:
                    break
                for t in stale:
                    bridge("POST", "/close-tab", {"index": t.get("index")})
                time.sleep(0.5)
        except Exception as exc:
            print("关标签跳过:", exc)
        # MUSCLE8 收尾：先兜底删工作区（按名字用桥端点），再关掉新窗口——
        # 只在 /state 显示的确实是**新窗口**（只有 fixture/新标签页）时才发
        # closeWindow：命令打到 key window 上，护栏防误关用户窗口。
        try:
            bridge("POST", "/workspaces/delete", {"name": "E2E-MUSCLE8"})
            bridge("POST", "/tab-groups/delete", {"name": "E2E 组（改名）"})
            for _arch in bridge("GET", "/session-archives").get("archives", []):
                if "E2E12" in (_arch.get("file") or ""):
                    bridge("POST", "/session-archives/delete", {"file": _arch["file"]})
            for _w in bridge("GET", "/watches").get("watches", []):
                if "E2E" in (_w.get("name") or ""):
                    bridge("POST", "/watches/remove", {"name": _w["name"]})
            # 关窗即归档（v0.7.18）：测试窗的会话会进归档——把"URL 全是本地
            # fixture"的归档趁早删掉（自己造的，别占用户归档的 5 个名额）。
            for _arch in bridge("GET", "/session-archives").get("archives", []):
                urls = _arch.get("urls") or []
                if urls and all("127.0.0.1" in u for u in urls):
                    bridge("POST", "/session-archives/delete", {"file": _arch["file"]})
            try:
                wins_now = len([w for w in bridge("GET", "/agent/windows").get("windows", [])
                                if w.get("windowVisible")])
                if wins_now > 1:
                    print("警告：仍有 %d 个活窗口（测试窗口可能没关干净，请人工看一眼）" % wins_now)
            except Exception:
                pass
        except Exception as exc:
            print("MUSCLE8 收尾跳过:", exc)
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
