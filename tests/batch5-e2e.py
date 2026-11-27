#!/usr/bin/env python3
"""v0.8.80 批 5 / v0.8.81 批 6 端到端：

1) 定时任务链：A 成功 → B 自动投递，B 的提示词用 `{{prev.output}}` / `{{prev.artifacts}}`
   拿到 A 的最终回答与产物路径；A→B→A 成环被拒；B 可用 "continue" 复用 A 的输出
   再跑一次；任务级重试上限经桥写入/读回。
2) 批量下载时段窗口：创建批次时带关闭窗口 → 立即暂停；清窗口恢复；开窗口可跑。
3) 翻译收口：替换式占位符不再泄漏 ⟦N⟧（页面内 JS 直接验证）；站点自动双语
   经桥设置后，页面加载自动开始翻译（假端点）。

前置：封闭实例在前台（浏览器/标签操作）。用法：
    python3 tests/batch5-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import http.server
import json
import os
import re
import threading
import time
import urllib.request
from datetime import datetime, timedelta

CHAIN_PORT = 8911
TRANSLATE_PORT = 8912
PAGE_PORT = 8913
checks = []
state = {"chain_prompts": [], "template_prompts": [], "translate_requests": 0}


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def sse(handler, text, model):
    body = (
        'data: ' + json.dumps({"id": "x", "model": model,
                               "choices": [{"index": 0, "delta": {"role": "assistant",
                                                                  "content": text}}]}) + '\n\n'
        'data: ' + json.dumps({"id": "x", "model": model, "choices": [],
                               "usage": {"prompt_tokens": 100, "completion_tokens": 10}}) + '\n\n'
        'data: [DONE]\n\n'
    ).encode()
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class ChainFake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        tools = payload.get("tools") or []
        messages = payload.get("messages") or []
        user_text = ""
        for message in reversed(messages):
            if message.get("role") == "user" and isinstance(message.get("content"), str):
                user_text = message["content"]
                break
        model = "fake-chain"
        if tools and "CHAIN-SECOND" in user_text:
            state["chain_prompts"].append(user_text)
            sse(self, "SECOND-DONE", model)
            return
        if tools and "TEMPLATE-CHAIN" in user_text:
            state["template_prompts"].append(user_text)
            sse(self, "TEMPLATE-B-DONE", model)
            return
        if tools and "CHAIN-FIRST" in user_text:
            sse(self, "FIRST-OUTPUT /tmp/chain-artifact-b5.md", model)
            return
        sse(self, "TITLE", model)


class TranslateFake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
        messages = payload.get("messages") or []
        system = ""
        user_text = ""
        for message in messages:
            if message.get("role") == "system" and not system:
                system = message.get("content") or ""
            if message.get("role") == "user" and isinstance(message.get("content"), str):
                user_text = message["content"]
        model = "fake-translate-b5"
        if "DESIRE_BILINGUAL_TRANSLATE" in system:
            state["translate_requests"] += 1
            count = len(re.findall(r"(?m)^\d+\.\s", user_text))
            translations = [f"译文{i + 1}" for i in range(max(count, 1))]
            sse(self, json.dumps(translations, ensure_ascii=False), model)
            return
        sse(self, "TITLE", model)


class Page(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = """<!doctype html><meta charset="utf-8"><title>batch5 translation</title>
        <p>Hello <code>foo()</code> world.</p>
        <p>Second paragraph for translation.</p>
        <p>Third paragraph with <code>bar()</code> inline code.</p>
        <li>List item text.</li>
        """.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def create_profile(base, name, port, model):
    return br(base, "POST", "/ai/profiles", {
        "name": name,
        "endpoint": f"http://127.0.0.1:{port}/v1/chat/completions",
        "model": model,
        "key": "b5-key-1234567890",
        "apiFormat": "openai",
    }).get("id")


def wait_for(base, path, predicate, timeout=60):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = br(base, "GET", path)
        except Exception:
            time.sleep(0.3)
            continue
        if predicate(last):
            return last
        time.sleep(0.3)
    return last


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    startup = (br(base, "GET", "/state").get("startup") or {})
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    ok("实例在前台", br(base, "GET", "/state").get("isActive") is True, "先 osascript activate")

    chain_server = http.server.ThreadingHTTPServer(("127.0.0.1", CHAIN_PORT), ChainFake)
    translate_server = http.server.ThreadingHTTPServer(("127.0.0.1", TRANSLATE_PORT), TranslateFake)
    page_server = http.server.ThreadingHTTPServer(("127.0.0.1", PAGE_PORT), Page)
    for server in (chain_server, translate_server, page_server):
        threading.Thread(target=server.serve_forever, daemon=True).start()

    previous_active = br(base, "GET", "/ai/profiles").get("active")
    created_profiles = []
    task_a = f"b5-chain-a-{int(time.time()) % 100000}"
    task_b = f"b5-chain-b-{int(time.time()) % 100000}"
    batch_id = None
    try:
        # ---------- 1. 定时任务链输出交接 ----------
        chain_id = create_profile(base, f"b5-chain-{task_a}", CHAIN_PORT, "fake-chain")
        created_profiles.append(chain_id)
        if chain_id:
            br(base, "POST", "/ai/profiles/activate", {"id": chain_id})
        br(base, "POST", "/agent/new", {})
        br(base, "POST", "/agent/tasks/create", {"name": task_a, "prompt": "CHAIN-FIRST", "minutes": 120})
        br(base, "POST", "/agent/tasks/create", {
            "name": task_b,
            "prompt": "CHAIN-SECOND PREV:{{prev.output}} ART:{{prev.artifacts}}",
            "minutes": 120,
            "retries": 2,
        })
        chained = br(base, "POST", "/agent/tasks/chain", {"name": task_a, "chainTo": task_b})
        ok("任务链：A → B 设置成功", chained.get("ok") is True, str(chained)[:200])
        cycle = br(base, "POST", "/agent/tasks/chain", {"name": task_b, "chainTo": task_a})
        ok("任务链：成环被拒", "error" in cycle and "loop" in cycle.get("error", ""), str(cycle)[:200])
        tasks = br(base, "GET", "/agent/tasks").get("tasks", [])
        row_a = next((t for t in tasks if t.get("name") == task_a), {})
        row_b = next((t for t in tasks if t.get("name") == task_b), {})
        ok("任务链：任务卡带 chainTo / 完整路径 / 任务级重试",
           row_a.get("chainTo") == task_b
           and row_a.get("chainPath") == [task_a, task_b]
           and row_b.get("retries") == 2,
           json.dumps({"a": row_a.get("chainPath"), "b": row_b.get("retries")}, ensure_ascii=False)[:240])

        br(base, "POST", "/agent/tasks/fire", {"name": task_a})
        deadline = time.time() + 60
        while time.time() < deadline and not state["chain_prompts"]:
            time.sleep(0.4)
        second = state["chain_prompts"][-1] if state["chain_prompts"] else ""
        ok("任务链：B 自动投递并拿到 A 的输出",
           "FIRST-OUTPUT" in second, second[:300])
        ok("任务链：占位符已渲染（不残留 {{prev.*}}）",
           "{{prev." not in second and "/tmp/chain-artifact-b5.md" in second, second[:300])
        # v0.8.81 批 6：从 B 继续——复用 A 最近一次成功输出，不重跑 A。
        before = len(state["chain_prompts"])
        continued = br(base, "POST", "/agent/tasks/continue", {"name": task_b})
        deadline = time.time() + 60
        while time.time() < deadline and len(state["chain_prompts"]) <= before:
            time.sleep(0.4)
        third = state["chain_prompts"][-1] if len(state["chain_prompts"]) > before else ""
        ok("任务链：从 B 继续复用 A 的成功输出",
           continued.get("ok") is True and len(state["chain_prompts"]) == before + 1
           and "FIRST-OUTPUT" in third,
           f"count={len(state['chain_prompts'])} prompt={third[:240]}")
        br(base, "POST", "/agent/tasks/remove", {"name": task_a})
        br(base, "POST", "/agent/tasks/remove", {"name": task_b})

        # ---------- 1b. 命令模板完成 → 下一任务（v0.8.81 批 7） ----------
        template_name = f"b5-tpl-{int(time.time()) % 100000}"
        template_a = task_a + "-tpl"
        template_b = task_b + "-tpl"
        made = br(base, "POST", "/jobs/templates", {
            "name": template_name,
            "tool": "python3",
            "args": ["-c",
                     "print('TEMPLATE-OUTPUT /tmp/chain-template-artifact.md')"],
            "timeoutMinutes": 1,
        })
        ok("模板链：命令模板创建", made.get("ok") is True, str(made)[:200])
        br(base, "POST", "/agent/tasks/create", {
            "name": template_a, "jobTemplate": template_name, "minutes": 120,
        })
        br(base, "POST", "/agent/tasks/create", {
            "name": template_b, "minutes": 120,
            "prompt": "TEMPLATE-CHAIN PREV:{{prev.output}} ART:{{prev.artifacts}}",
        })
        br(base, "POST", "/agent/tasks/chain",
           {"name": template_a, "chainTo": template_b})
        br(base, "POST", "/agent/tasks/fire", {"name": template_a})
        deadline = time.time() + 90
        while time.time() < deadline and not state["template_prompts"]:
            time.sleep(0.4)
        tpl_prompt = state["template_prompts"][-1] if state["template_prompts"] else ""
        ok("模板链：命令作业完成后自动投递下一任务并带上日志输出/产物",
           "TEMPLATE-OUTPUT" in tpl_prompt
           and "/tmp/chain-template-artifact.md" in tpl_prompt
           and "{{prev." not in tpl_prompt,
           tpl_prompt[:320])
        tpl_runs = br(base, "GET", "/agent/tasks").get("runs", [])
        tpl_run = next((r for r in tpl_runs
                        if r.get("task") == template_a and r.get("status") == "success"), {})
        ok("模板链：模板任务的 run 记录带作业输出",
           "TEMPLATE-OUTPUT" in (tpl_run.get("prompt") or "")
           or "TEMPLATE-OUTPUT" in (tpl_run.get("output") or ""),
           json.dumps(tpl_run, ensure_ascii=False)[:300])
        br(base, "POST", "/agent/tasks/remove", {"name": template_a})
        br(base, "POST", "/agent/tasks/remove", {"name": template_b})
        br(base, "POST", "/jobs/templates",
           {"action": "delete", "name": template_name})

        # ---------- 2. 批量下载时段窗口 ----------
        now = datetime.now()
        closed_start = (now + timedelta(minutes=90)).strftime("%H:%M")
        closed_end = (now + timedelta(minutes=120)).strftime("%H:%M")
        open_start = (now - timedelta(minutes=10)).strftime("%H:%M")
        open_end = (now + timedelta(minutes=10)).strftime("%H:%M")
        created_batch = br(base, "POST", "/media/batch", {
            "mode": "list",
            "urls": ["http://127.0.0.1:9/b5-no-such-stream"],
            "folderName": f"b5-window-{task_a}",
            "windowStart": closed_start, "windowEnd": closed_end,
            "maxMinutes": 30, "maxConcurrent": 2,
        })
        batch_id = created_batch.get("batchId")
        ok("批窗口：创建批次时带上窗口", bool(batch_id), str(created_batch)[:200])
        if batch_id:
            def batch_row():
                rows = br(base, "GET", f"/media/batch?id={batch_id}").get("batches", [])
                return rows[0] if rows else {}
            row = wait_for(base, f"/media/batch?id={batch_id}",
                           lambda body: bool(body.get("batches")), timeout=20) or {}
            row = (row.get("batches") or [{}])[0] if row.get("batches") else {}
            window = row.get("window") or {}
            ok("批窗口：关闭时段立即暂停",
               row.get("paused") is True and window.get("open") is False,
               json.dumps(row, ensure_ascii=False)[:300])
            ok("批窗口：并发/时长/摘要随快照下发",
               window.get("maxConcurrent") == 2 and window.get("maxMinutes") == 30
               and "–" in (window.get("summary") or ""),
               json.dumps(window, ensure_ascii=False)[:200])
            br(base, "POST", "/media/batch/window", {"id": batch_id, "start": "", "end": ""})
            time.sleep(0.8)
            cleared = batch_row()
            ok("批窗口：清窗口后不再被窗口暂停",
               cleared.get("paused") is not True or cleared.get("state") != "running",
               json.dumps(cleared, ensure_ascii=False)[:250])
            br(base, "POST", "/media/batch/window", {
                "id": batch_id, "start": open_start, "end": open_end,
                "maxMinutes": 0, "maxConcurrent": 3,
            })
            time.sleep(0.5)
            opened = batch_row()
            ok("批窗口：开放时段可继续",
               (opened.get("window") or {}).get("open") is True
               and (opened.get("window") or {}).get("maxConcurrent") == 3,
               json.dumps(opened.get("window"), ensure_ascii=False)[:200])
            br(base, "POST", "/media/batch/cancel", {"id": batch_id})

        # ---------- 3. 翻译收口 ----------
        translate_id = create_profile(base, f"b5-translate-{task_a}", TRANSLATE_PORT, "fake-translate-b5")
        created_profiles.append(translate_id)
        if translate_id:
            br(base, "POST", "/ai/profiles/activate", {"id": translate_id})
        br(base, "POST", "/site-settings/auto-bilingual", {"host": "127.0.0.1", "enabled": False})
        br(base, "POST", "/new-tab", {"url": f"http://127.0.0.1:{PAGE_PORT}/manual?t={task_a}"})
        time.sleep(1.5)

        js_source = open(os.path.join(os.path.dirname(__file__), "..",
                                      "apps/macos/Desire/UserScripts/bilingual-translate.js"),
                         encoding="utf-8").read()
        br(base, "POST", "/execute", {"js": js_source})
        collect = br(base, "POST", "/execute", {
            "js": "JSON.stringify(window.__desireBilingualCollect({maxBlocks:20,maxChars:50000}))"
        }).get("result")
        blocks = []
        try:
            blocks = json.loads(collect).get("blocks", [])
        except Exception:
            blocks = []
        target = next((b for b in blocks if "⟦0⟧" in (b.get("text") or "")), None)
        ok("翻译替换式：collect 把 inline code 收成占位符", target is not None,
           str(collect)[:300])
        if target:
            br(base, "POST", "/execute", {
                "js": "window.__desireBilingualReplace([{id:%s,text:%s}])" % (
                    json.dumps(target["id"]), json.dumps("译文 ⟦0⟧ 结束"))
            })
            html = br(base, "POST", "/execute", {
                "js": "document.querySelector('[data-desire-bi=\\\"%s\\\"]').innerHTML" % target["id"]
            }).get("result")
            ok("翻译替换式：⟦N⟧ 还原成原始 <code>，正文无占位符",
               isinstance(html, str) and "<code>foo()</code>" in html and "⟦" not in html,
               str(html)[:200])
            br(base, "POST", "/execute", {"js": "window.__desireBilingualRestore()"})
            restored = br(base, "POST", "/execute", {
                "js": "document.querySelector('[data-desire-bi=\\\"%s\\\"]').innerHTML" % target["id"]
            }).get("result")
            ok("翻译替换式：还原后 inline code 仍在（innerHTML 保存）",
               isinstance(restored, str) and "<code>foo()</code>" in restored,
               str(restored)[:200])

        # 站点自动双语（S3）：设置后新页面加载即开始翻译
        br(base, "POST", "/site-settings/auto-bilingual", {"host": "127.0.0.1", "enabled": True})
        settings = br(base, "GET", "/site-settings?host=127.0.0.1")
        ok("自动双语：站点设置可写可读", settings.get("autoBilingual") is True, str(settings)[:200])
        br(base, "POST", "/navigate", {"url": f"http://127.0.0.1:{PAGE_PORT}/auto?t={task_a}"})
        deadline = time.time() + 45
        translated = 0
        while time.time() < deadline:
            result = br(base, "POST", "/execute", {
                "js": "document.querySelectorAll('.desire-bilingual').length"
            }).get("result")
            translated = int(result) if isinstance(result, (int, float)) else 0
            if translated >= 2:
                break
            time.sleep(0.6)
        # 命中缓存时 requests=0 也算成功（同 URL 重开零模型调用正是缓存的意义）。
        ok("自动双语：页面加载后自动产出译文块",
           translated >= 2,
           f"nodes={translated} requests={state['translate_requests']}")
        leftover = br(base, "POST", "/execute", {
            "js": "document.body.innerText.indexOf('⟦')"
        }).get("result")
        ok("自动双语：页面正文无占位符残留", leftover == -1, str(leftover))
        br(base, "POST", "/site-settings/auto-bilingual", {"host": "127.0.0.1", "enabled": False})
        br(base, "POST", "/execute", {"js": "window.__desireBilingualClear && window.__desireBilingualClear()"})
    finally:
        try:
            br(base, "POST", "/site-settings/auto-bilingual", {"host": "127.0.0.1", "enabled": False})
            br(base, "POST", "/agent/tasks/remove", {"name": task_a})
            br(base, "POST", "/agent/tasks/remove", {"name": task_b})
            if batch_id:
                br(base, "POST", "/media/batch/cancel", {"id": batch_id})
            if previous_active:
                br(base, "POST", "/ai/profiles/activate", {"id": previous_active})
            for profile_id in created_profiles:
                if profile_id:
                    br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
        except Exception:
            pass
        chain_server.shutdown()
        translate_server.shutdown()
        page_server.shutdown()

    passed = sum(1 for _, cond in checks if cond)
    print("\nv0.8.80 批 5 + v0.8.81 链运维：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
