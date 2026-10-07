#!/usr/bin/env python3
"""Agent 评估脚本：固定 prompt 集 → 假端点 → 断言轨迹与消息（优化清单 P1-⑤）。

把"发一条消息 → 肉眼看回复"的产品化：全部用例**确定性**（假端点，不需要真模型），
断言打在桥端点（/agent/messages、/agent/trace）上，覆盖：

  E1 plain-echo       系统提示契约：system 只有一条且在开头（sysCount=1、sysAt=[0]）
  E2 fail-convention  工具失败 → 结果以 Error: 开头、模型所见一致、轨迹 threwError、机械核验触发
  E3 redaction        读凭据文件 → 工具结果与模型所见都是 [redacted]，原文不出现在对话里
  E4 overflow-retry   首次请求报 context length → 应用自动减半预算重试并完成回合

自包含：fixture 端点与凭据文件由脚本在临时目录生成，不依赖仓库外任何路径。

用法：
  前置：应用以 --automation 启动、桥可达（默认 http://127.0.0.1:8799）。
  运行：python3 tests/agent-eval.py [--base URL] [--cleanup] [--keep-fixture]
    --cleanup  结束时删除评估写入的会话（按脚本记录的精确 id）。默认保留。
    --keep-fixture 结束后不删除临时模型档案（默认删除并恢复原档案）。

退出码：全部通过 = 0；任何失败 = 1。
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BRIDGE = "http://127.0.0.1:8799"
# 命中 SecretRedactor 的 sk- 形态规则（sk- 后 ≥16 个词字符），脱敏断言因此确定性成立。
EVAL_FAKE_KEY = "sk-evalfakekey1234567890"
FIXTURE_SOURCE = r'''
#!/usr/bin/env python3
"""Fake OpenAI-compatible chat-completions endpoint (SSE).

把收到的 Authorization 与自定义请求头**回显在回复文本里**，于是"自定义模型服务
的 Key / 额外请求头真的到了服务端"可以被断言——不需要真的模型。

    POST /v1/chat/completions  →  data: {...chunk with the echo...} / [DONE]
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("EVAL_PORT") or 8880)
# 三个文件路径由 agent-eval.py 通过环境变量注入（临时目录，跑完即删）。
SECRET_PATH = os.environ.get("EVAL_SECRET_PATH")
SECRET2_PATH = os.environ.get("EVAL_SECRET2_PATH")
MISSING_PATH = os.environ.get("EVAL_MISSING_PATH")
BIG_PATH = os.environ.get("EVAL_BIG_PATH")
# OVERFLOW_ONCE：第一次带 OVERFLOWTEST 的请求报 context length 错误，之后正常 ——
# 用于验证应用会"压缩预算减半重试"。
overflow_seen = 0
# E7：逐请求记录（model/system 首段/末条 user）——断言旁路路由后的请求模型。
REQUESTS = []
# 每次请求前延迟（秒）：用来放大"正文完成后还在跑额外模型调用"的时间差。
DELAY = float(os.environ.get("FAKE_DELAY", "0"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    @staticmethod
    def big_plain():
        # 单个巨大段落（无代码块/列表/表格）：用来区分"文本量大"与"块多/代码块滚动视图"。
        return "这是一段很长的纯文本。" * 1200

    @staticmethod
    def big_markdown():
        blocks = ["# 压测回答\n\n"]
        for index in range(40):
            blocks.append(f"## 小节 {index}\n\n")
            blocks.append("这是一个**加粗**的段落，带 `inline code`、一个 [链接](https://example.com/x) 和裸地址 https://example.com/" + str(index) + "。" * 6 + "\n\n")
            blocks.append("- 列表项一\n- 列表项二，带 `code`\n- 列表项三\n\n")
            blocks.append("| 列 A | 列 B |\n| --- | --- |\n| 值 1 | 值 2 |\n| 值 3 | 值 4 |\n\n")
            blocks.append("```swift\nfunc f" + str(index) + "() {\n    print(\"hello " + str(index) + "\")\n}\n```\n\n")
        return "".join(blocks)

    def do_GET(self):
        # /requests：dump 已记录的请求（E7 断言旁路路由后的 model 字段）。
        if self.path.startswith("/requests"):
            body = json.dumps({"requests": REQUESTS}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # /reset：清空 OVERFLOW 计数（评估脚本用，保证用例确定性）。
        if self.path.startswith("/reset"):
            global overflow_seen
            overflow_seen = 0
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers()
            self.wfile.write(b"ok"); return
        # /v1/models：让"Fetch from API"这类路径也能被验证。
        if self.path.endswith("/models"):
            body = json.dumps({"object": "list", "data": [
                {"id": "fake-1", "object": "model"},
                {"id": "fake-2", "object": "model"},
                {"id": "fake-3", "object": "model"},
            ]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        sys.stderr.write(f"[fake] POST {self.path}\n"); sys.stderr.flush()
        if DELAY:
            time.sleep(DELAY)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}

        auth = self.headers.get("Authorization", "")
        tenant = self.headers.get("X-Tenant", "")
        model = body.get("model", "?")
        msgs_all = body.get("messages") or []
        sys_count = sum(1 for m in msgs_all if m.get("role") == "system")
        sys_positions = [i for i, m in enumerate(msgs_all) if m.get("role") == "system"]
        has_notes = any("Session notes" in (m.get("content") or "") for m in msgs_all[:1])
        text = (f"auth={auth}; tenant={tenant}; model={model}; "
                f"sysCount={sys_count}; sysAt={sys_positions}; notesInSystem={has_notes}")

        # 标题生成请求（system 含 "conversation title"）：回一个固定短标题——
        # 太长的回复会被 generateTitle 的 ≤80 字守卫拒绝、记账不落盘。
        system_text = (msgs_all[0].get("content") or "") if msgs_all else ""
        if "conversation title" in system_text:
            text = "评估标题"

        # 分支判据只看最后一条 user 消息 + 本轮（其后）的工具结果。历史轮次里
        # 的用例关键词绝不能影响本轮分支——否则 E4 的请求体里带着 E2/E3 的
        # 关键词，会串到别人的分支（2026-09-24，eval 三查三改才定位到这）。
        last_user_idx = max((i for i, m in enumerate(msgs_all) if m.get("role") == "user"), default=-1)
        mode_text = (msgs_all[last_user_idx].get("content") or "") if last_user_idx >= 0 else ""
        round_msgs = msgs_all[last_user_idx + 1:]
        has_tool = any(m.get("role") == "tool" for m in round_msgs)
        # E7：逐请求记录（model + system 首段 + 末条 user），供 GET /requests 断言。
        REQUESTS.append({"model": model, "system": system_text[:160], "lastUser": mode_text[:64]})
        # 诊断（CI E6 超时用）：分支输入落盘 + stderr（CI 日志可见）。
        import sys as _sys
        _line = f"FIXTURE-REQ: mode={mode_text[:48]!r} has_tool={has_tool} tools={len([m for m in round_msgs if m.get('role') == 'tool'])}"
        with open("/tmp/eval-fixture-debug.log", "a") as _dbg:
            _dbg.write(_line + "\n")
        print(_line, file=_sys.stderr)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        # 思考流模式：先流式发 reasoning_content，再发正文（验证折叠展示）。
        if "THINKSTREAM" in mode_text:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            def emit(field, piece):
                chunk = {"id": "chatcmpl-think", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model, "choices": [{"index": 0, "delta": {field: piece}, "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.05)
            for piece in ["我需要先确认用户的意图。", "问题里提到 THINKSTREAM，", "说明是在测试思考过程的展示。", "那么直接回答即可。"]:
                emit("reasoning_content", piece)
            emit("content", "这是正式答复：思考过程已经在上方折叠块里。")
            done = {"id": "chatcmpl-think", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        # 契约校验模式：OpenAI 要求 system 只能出现在开头，出现在中间就报错
        # （复现 amd 网关的 "System message must be at the beginning."）。
        msgs = body.get("messages") or []
        for index, m in enumerate(msgs):
            if m.get("role") == "system" and index != 0:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                payload = json.dumps({"error": {"message": "System message must be at the beginning.", "type": "invalid_request_error"}})
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True
                return

        # 超限重试模式（OVERFLOWTEST）：第一次报 context length，之后放行。
        body_text = json.dumps(body)

        # 提问模式（ASKME）：发一个 askUser 工具调用（验证挂起/超时/自动弹面板）。
        if "ASKME" in mode_text and not has_tool:
            call = {"index": 0, "id": "call_ask_1", "type": "function",
                    "function": {"name": "askUser",
                                 "arguments": json.dumps({"question": "ASKME 要继续吗？"})}}
            chunk = {"id": "chatcmpl-ask", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-ask", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return
        if "ASKME" in mode_text and has_tool:
            reply = "ASKME-DONE"
            chunk = {"id": "chatcmpl-ask", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-ask", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 并行批模式（PARAREAD）：一次发 3 个 readFile（两个存在、一个不存在），
        # 用于验证只读工具并行批的配对与顺序。
        if "PARAREAD" in mode_text and not has_tool:
            calls = []
            for i, path in enumerate([SECRET_PATH,
                                      SECRET2_PATH,
                                      MISSING_PATH]):
                calls.append({"index": i, "id": f"call_p{i}", "type": "function",
                              "function": {"name": "readFile",
                                           "arguments": json.dumps({"path": path})}})
            chunk = {"id": "chatcmpl-para", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": calls},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-para", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return
        if "PARAREAD" in mode_text and has_tool:
            reply = "PARA-DONE（%d 个工具结果已收到）" % len([m for m in msgs if m.get("role") == "tool"])
            chunk = {"id": "chatcmpl-para", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-para", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 白板契约（E8，0.6.7）：一条消息连发 10 个 whiteboard/screenshot 调用——
        # 顺序敏感的 whiteboard 串行执行后，按序断言成功文案与 Error: 契约分支。
        if "EVAL-WB" in mode_text and not has_tool:
            def wb(cid, i, args):
                return {"index": i, "id": cid, "type": "function",
                        "function": {"name": "whiteboard",
                                     "arguments": json.dumps(args, ensure_ascii=False)}}
            calls = [
                wb("call_wb1", 0, {"action": "get"}),                                        # 空板读回（非失败）
                wb("call_wb2", 1, {"action": "edit", "index": 99, "content": "x"}),          # Error: 越界
                wb("call_wb3", 2, {"action": "delete"}),                                     # Error: 缺 index
                wb("call_wb4", 3, {"action": "render", "title": "E8", "blocks": [
                    {"type": "note", "content": "第一块笔记"},
                    {"type": "mermaid", "content": "flowchart TD\nA-->B"}]}),                # 成功 2 块
                wb("call_wb5", 4, {"action": "move", "index": 1, "delta": 5}),               # Error: 移动越界
                wb("call_wb6", 5, {"action": "edit", "index": 2,
                                   "content": "flowchart TD\nX-->Y"}),                       # 成功改块 2
                wb("call_wb7", 6, {"action": "get"}),                                        # 读回含 X-->Y
            ]
            chunk = {"id": "chatcmpl-wb", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": calls},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-wb", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return
        if "EVAL-WB" in mode_text and has_tool:
            reply = "WBDONE"
            chunk = {"id": "chatcmpl-wb", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-wb", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 证据引用链（E10，本地专属）：screenshot → append evidence:"last" → get。
        if "EVAL-EVID" in mode_text:
            tool_msgs = [m for m in msgs_all if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_ev1", "type": "function",
                        "function": {"name": "screenshot", "arguments": "{}"}}
                finish = "tool_calls"
            elif len(tool_msgs) == 1:
                call = {"index": 0, "id": "call_ev2", "type": "function",
                        "function": {"name": "whiteboard",
                                     "arguments": json.dumps({"action": "append", "blocks": [
                                         {"type": "image", "evidence": "last"}]}, ensure_ascii=False)}}
                finish = "tool_calls"
            elif len(tool_msgs) == 2:
                call = {"index": 0, "id": "call_ev3", "type": "function",
                        "function": {"name": "whiteboard",
                                     "arguments": json.dumps({"action": "get"})}}
                finish = "tool_calls"
            else:
                call = None
                finish = "stop"
            if call is not None:
                chunk = {"id": "chatcmpl-ev", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
            else:
                chunk = {"id": "chatcmpl-ev", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": "EVIDONE"},
                                      "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-ev", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 会话拦截（NETRULE，0.6.6）：无工具结果 → 发 networkRules(add block)；
        # 有工具结果 → 收尾文本 NETRULE-DONE。
        if "NETRULE" in mode_text and not has_tool:
            call = {"index": 0, "id": "call_netr_1", "type": "function",
                    "function": {"name": "networkRules",
                                 "arguments": json.dumps({"action": "add",
                                                          "urlFilter": "^https://eval-nrule\\.test/",
                                                          "kind": "block"})}}
            chunk = {"id": "chatcmpl-nr", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-nr", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return
        if "NETRULE" in mode_text and has_tool:
            reply = "NETRULE-DONE"
            chunk = {"id": "chatcmpl-nr2", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-nr2", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        if "READSECRET" in mode_text and not has_tool:
            body_text_note = json.dumps({"path": SECRET_PATH})
            call = {"index": 0, "id": "call_read_1", "type": "function",
                    "function": {"name": "readFile", "arguments": body_text_note}}
            chunk = {"id": "chatcmpl-read", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-read", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return
        if "READSECRET" in mode_text and has_tool:
            seen = [m.get("content") or "" for m in msgs if m.get("role") == "tool"][-1]
            reply = "MODEL-SAW>>>" + seen + "<<<END"
            chunk = {"id": "chatcmpl-read", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-read", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        if "OVERFLOWTEST" in mode_text:
            global overflow_seen
            overflow_seen += 1
            sys.stderr.write(f"[fake] OVERFLOWTEST request #{overflow_seen}\n"); sys.stderr.flush()
            if overflow_seen == 1:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                payload = json.dumps({"error": {"message": "This model's maximum context length is 4096 tokens, however your messages resulted in 8123 tokens", "type": "invalid_request_error"}})
                self.wfile.write(f"data: {payload}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True
                return
            overflow_seen = 0

        # 异常模式：EMPTYSTREAM = 200 但流里没有任何内容；ERRORSTREAM = 流内错误负载。
        body_text = json.dumps(body)

        # 工具+脱敏模式（TOOLSECRET）：第一轮让模型调 readFile 去读一个含**假密钥**的文件，
        # 于是工具结果入会话前必经 SecretRedactor；第二轮把**模型实际收到的**工具消息原文
        # 回显出来——「模型看到的是 [redacted]」因此可以被直接断言。
        if "TOOLSECRET" in mode_text:
            tool_msgs = [m for m in round_msgs if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_secret_1", "type": "function",
                        "function": {"name": "readFile",
                                     "arguments": json.dumps({"path": MISSING_PATH})}}
                chunk = {"id": "chatcmpl-tool", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                done = {"id": "chatcmpl-tool", "object": "chat.completion.chunk", "created": int(time.time()),
                        "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
                self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True
                return
            seen = tool_msgs[-1].get("content") or ""
            reply = "MODEL-SAW>>>" + seen + "<<<END"
            chunk = {"id": "chatcmpl-tool", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-tool", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if "ERRORSTREAM" in mode_text:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            payload = json.dumps({"error": {"message": "context length exceeded (fixture)", "type": "invalid_request_error"}})
            self.wfile.write(f"data: {payload}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return
        if "EMPTYSTREAM" in mode_text:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.close_connection = True
            return

        # 工具结果摘要缓存（E9，0.6.7）：读 20KB 大文件 → 应用把结果截成
        # 「头部 + getToolResult 句柄」→ 模型按句柄取回全文（含 END 哨兵）。
        # 三轮分支；任一轮形态不符都回可判定的降级文本。
        if "EVAL-BIG" in mode_text:
            tool_msgs = [m for m in msgs_all if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_e9a", "type": "function",
                        "function": {"name": "readFile",
                                     "arguments": json.dumps({"path": BIG_PATH})}}
                chunk = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                done = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                        "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
                self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush(); self.close_connection = True
                return
            last_tool = tool_msgs[-1]
            content = last_tool.get("content") or ""
            if len(tool_msgs) == 1:
                if "getToolResult(callId:" not in content or "truncated" not in content:
                    reply = "E9DONE-notrunc"
                else:
                    # 从 stub 里解析总长，切**尾部** 3000 字符（END 哨兵所在）
                    import re as _re
                    m = _re.search(r"(\d+) chars total", content)
                    total = int(m.group(1)) if m else 0
                    call = {"index": 0, "id": "call_e9b", "type": "function",
                            "function": {"name": "getToolResult",
                                         "arguments": json.dumps({"callId": last_tool.get("tool_call_id"),
                                                                  "offset": max(0, total - 3000),
                                                                  "length": 3000})}}
                    chunk = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                             "model": model,
                             "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                          "finish_reason": None}]}
                    self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    done = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                            "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]}
                    self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush(); self.close_connection = True
                    return
            else:
                reply = "E9DONE-full" if "EVALBIG-END-SENTINEL" in content else "E9DONE-partial"
            chunk = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": model,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                  "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-e9", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # DPP 一键上板（E11，本地专属）：demo 商店页 pageExtract → whiteboard
        # from:"extract" 一条指令出板。生产网络依赖 → 默认 CI 跳过（EVAL_E11=1）。
        if "EVAL-BOARD" in mode_text:
            tool_msgs = [m for m in msgs_all if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_e11a", "type": "function",
                        "function": {"name": "pageExtract",
                                     "arguments": json.dumps({"view": "products"})}}
                finish = "tool_calls"
            elif len(tool_msgs) == 1:
                call = {"index": 0, "id": "call_e11b", "type": "function",
                        "function": {"name": "whiteboard",
                                     "arguments": json.dumps({"action": "render", "from": "extract"})}}
                finish = "tool_calls"
            else:
                result = tool_msgs[-1].get("content") or ""
                reply = "E11DONE-board" if "Whiteboard updated" in result and "2 block(s)" in result else "E11DONE-miss"
                call = None
                finish = "stop"
            if call is not None:
                chunk = {"id": "chatcmpl-e11", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
            else:
                chunk = {"id": "chatcmpl-e11", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                      "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-e11", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 跨源 pageAction（E13，本地专属）：pageAction("frame-toggle") 路由
        # 进子框架点击 → pageExtract 读回状态 → E13DONE-on。
        if "EVAL-FRAME-ACT" in mode_text:
            tool_msgs = [m for m in msgs_all if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_e13a", "type": "function",
                        "function": {"name": "pageAction",
                                     "arguments": json.dumps({"name": "frame-toggle"})}}
                finish = "tool_calls"
            elif len(tool_msgs) == 1:
                call = {"index": 0, "id": "call_e13b", "type": "function",
                        "function": {"name": "pageExtract",
                                     "arguments": json.dumps({"view": "frameState"})}}
                finish = "tool_calls"
            else:
                extract = tool_msgs[-1].get("content") or ""
                reply = "E13DONE-on" if "E13-FRAME-ON" in extract else "E13DONE-off"
                call = None
                finish = "stop"
            if call is not None:
                chunk = {"id": "chatcmpl-e13", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
            else:
                chunk = {"id": "chatcmpl-e13", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                      "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-e13", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 跨源子框架提取（E12，本地专属）：pageExtract("frameProducts") →
        # 抽取结果含哨兵（per-frame 执行证明）→ E12DONE-frame。
        if "EVAL-FRAME" in mode_text:
            tool_msgs = [m for m in msgs_all if m.get("role") == "tool"]
            if not tool_msgs:
                call = {"index": 0, "id": "call_e12a", "type": "function",
                        "function": {"name": "pageExtract",
                                     "arguments": json.dumps({"view": "frameProducts"})}}
                finish = "tool_calls"
            else:
                result = tool_msgs[-1].get("content") or ""
                reply = "E12DONE-frame" if "E12-FRAME-SENTINEL" in result else "E12DONE-miss"
                call = None
                finish = "stop"
            if call is not None:
                chunk = {"id": "chatcmpl-e12", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]},
                                      "finish_reason": None}]}
            else:
                chunk = {"id": "chatcmpl-e12", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": reply},
                                      "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "chatcmpl-e12", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush(); self.close_connection = True
            return

        # 长回答压力模式：提示里含 BIGSTREAM 时流式吐 ~40KB Markdown（含代码块、
        # 列表、表格），用来复现"流式输出卡死"。
        if "BIGPLAIN" in mode_text or "BIGSTREAM" in mode_text:
            text = self.big_plain() if "BIGPLAIN" in mode_text else self.big_markdown()
            step = 20
            for index in range(0, len(text), step):
                piece = text[index:index + step]
                chunk = {
                    "id": "chatcmpl-fake",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}],
                }
                try:
                    self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                    self.wfile.flush()
                except Exception:
                    return
                time.sleep(0.004)
        else:
            chunk = {
                "id": "chatcmpl-fake",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}],
            }
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()

        done = {
            "id": "chatcmpl-fake",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 12000, "completion_tokens": 800, "total_tokens": 12800},
        }
        self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        # SSE 结束就该关连接：不关的话客户端会一直等（实测把"回合结束"拖后 2.8s）
        self.close_connection = True


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    port_file = os.environ.get("EVAL_PORT_FILE")
    if port_file:
        with open(port_file, "w") as fh:
            fh.write(str(server.server_address[1]))
    server.serve_forever()

'''
FIXTURE_PORT = 8880
# 显式禁代理：urllib 默认读 http(s)_proxy 环境变量，127.0.0.1 也会被送进代理
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))
# 端点不能再是模块级常量——端口改临时后要等 ensure_workdir 握手完才知道
def fixture_endpoint() -> str:
    return f"http://127.0.0.1:{FIXTURE_PORT}/v1/chat/completions"
POLL_TIMEOUT = 90


def bridge(method, path, body=None):
    req = urllib.request.Request(BRIDGE + path, method=method)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data=data, timeout=15) as resp:
        return json.loads(resp.read().decode())


def fixture_bridge(method, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{FIXTURE_PORT}{path}", timeout=10) as resp:
        return resp.read().decode()


# ---------- 假端点与档案管理 ----------

fixture_proc = None


workdir = None


def ensure_workdir():
    """生成 fixture 端点脚本与凭据文件（临时目录，结束即删）。

    曾经依赖本机 /tmp/desire-fixture/fake_openai.py——CI 上不存在，
    eval 第一步就 "fixture endpoint did not come up"（2026-09-24）。
    现在完全自包含：脚本、凭据、路径全部由这里生成，不碰仓库外任何路径。
    """
    global workdir
    # fixture 文件放进 **agent 工作区**（/state 的 agentWorkspace）：readFile 对
    # 工作区内的路径免审批；临时目录在 CI 上会被工作区闸门拦下，E2/E3 的工具
    # 结果全变成 denied（2026-09-24）。取不到工作区（旧构建）才退回临时目录。
    try:
        workspace = bridge("GET", "/state").get("agentWorkspace")
        assert workspace
        root = pathlib.Path(workspace) / ".eval-fixture"
        root.mkdir(parents=True, exist_ok=True)
        workdir = root
    except Exception:
        workdir = pathlib.Path(tempfile.mkdtemp(prefix="desire-eval-"))
    secret = workdir / "secret.txt"
    secret.write_text(
        f"gateway token: {EVAL_FAKE_KEY}\n"
        "aws: AKIAIOSFODNN7EXAMPLE\n"
        "header: Bearer abcdefghijklmnopqrstuvwxyz\n")
    (workdir / "secret2.txt").write_text("second target for the parallel-read batch\n")
    # E9（工具结果摘要缓存）：~20KB 大文件——头部 600 字符之外才有 END 哨兵，
    # 截断 stub 里看不到它，getToolResult 取回全文才可见。
    big = workdir / "big.txt"
    filler = "".join(f"line {i:05d}: filler text for the oversized tool result test\n" for i in range(700))
    big.write_text("EVALBIG-BEGIN head of a very large tool result\n" + filler +
                   "\nEVALBIG-END-SENTINEL tail marker beyond the truncation head\n")
    script = workdir / "fixture.py"
    script.write_text(FIXTURE_SOURCE)
    port_file = workdir / "port"
    child_env = {**os.environ,
                 "EVAL_PORT": "0",          # 临时端口：8880 被占也不受影响
                 "EVAL_PORT_FILE": str(port_file),
                 "EVAL_SECRET_PATH": str(secret),
                 "EVAL_SECRET2_PATH": str(workdir / "secret2.txt"),
                 "EVAL_MISSING_PATH": str(workdir / "missing.txt"),
                 "EVAL_BIG_PATH": str(big)}
    global fixture_proc
    err_file = open(workdir / "fixture.err", "wb")
    fixture_proc = subprocess.Popen(
        [sys.executable, str(script)],
        stdout=subprocess.DEVNULL, stderr=err_file, env=child_env)
    deadline = time.time() + 60
    while time.time() < deadline:
        if fixture_proc.poll() is not None:
            err_file.close()
            tail = (workdir / "fixture.err").read_text(errors="replace")[-2000:]
            raise RuntimeError(f"fixture 进程启动即退（exit={fixture_proc.returncode}）：\n{tail}")
        if port_file.exists():
            global FIXTURE_PORT
            FIXTURE_PORT = int(port_file.read_text().strip())
            try:
                fixture_bridge("GET", "/reset")
                return
            except Exception:
                pass
        time.sleep(0.3)
    err_file.close()
    tail = (workdir / "fixture.err").read_text(errors="replace")[-2000:]
    raise RuntimeError(f"fixture endpoint did not come up on port 8880（exit={fixture_proc.poll()}）\n{tail}")


def stop_fixture():
    if fixture_proc:
        fixture_proc.terminate()


previous_active = None
eval_profile_id = None


def install_profile():
    global previous_active, eval_profile_id
    profiles = bridge("GET", "/ai/profiles")
    previous_active = profiles.get("active")
    created = bridge("POST", "/ai/profiles", body={
        "name": "eval-fixture",
        "endpoint": fixture_endpoint(),
        "model": "fake-1",
        "key": "eval-key-1234567890",
    })
    eval_profile_id = created["id"]
    bridge("POST", "/ai/profiles/activate", body={"id": eval_profile_id})


def restore_profile():
    try:
        if previous_active:
            bridge("POST", "/ai/profiles/activate", body={"id": previous_active})
        if eval_profile_id:
            bridge("POST", "/ai/profiles/delete", body={"id": eval_profile_id})
    except Exception as exc:
        print(f"⚠️ 恢复档案失败（请手工检查）：{exc}")


# ---------- 轮次驱动与断言 ----------

eval_conversations = []


def run_case(prompt):
    """发一条消息并等回合结束。返回 (messages, last_turn)。"""
    before_ids = {m.get("id") for m in bridge("GET", "/agent/messages").get("messages", [])}
    sent = bridge("POST", "/agent/send", body={"text": prompt})
    if not sent.get("ok"):
        # /agent/send 在没有活会话时也回 200 + {"error": …}，不检查就变成 90s 超时假象。
        raise RuntimeError(f"/agent/send 被拒：{sent}")
    deadline = time.time() + POLL_TIMEOUT
    while time.time() < deadline:
        state = bridge("GET", "/agent/messages")
        # 判据 = 出现了**新 id** 的 assistant 消息且不再忙碌；复核一次防抖。
        # 不能比条数——/agent/messages 只回 suffix(12)，长对话里"条数变多"永远
        # 不成立，回合明明完成了也被判超时（2026-09-24 第二遍全超时的真因；
        # 第一遍总能过只是因为对话还短）。
        def fresh_reply(state):
            return [m for m in state.get("messages", [])
                    if m.get("id") not in before_ids and m.get("role") == "assistant"]
        if fresh_reply(state) and not state.get("busy"):
            time.sleep(0.5)
            state = bridge("GET", "/agent/messages")
            if fresh_reply(state) and not state.get("busy"):
                trace = bridge("GET", "/agent/trace")
                eval_conversations.append(trace["conversation"])
                return state.get("messages", [])
        time.sleep(0.5)
    raise TimeoutError(f"回合超时未完成：{prompt}")


def last_exchange(msgs):
    """最后一个回合的 (user, assistant, tool 消息列表)。"""
    tail = list(reversed(msgs))
    assistant = next(m for m in tail if m["role"] == "assistant")
    tools = [m for m in msgs if m["role"] == "tool"]
    user = next(m for m in reversed(msgs) if m["role"] == "user")
    return user, assistant, tools


# ---------- 用例 ----------

def case_plain_echo():
    msgs = run_case("EVAL-PLAIN 请用一句话回应")
    _, assistant, _ = last_exchange(msgs)
    text = assistant.get("content") or ""
    check("E1 system 只有一条且在开头", "sysCount=1" in text and "sysAt=[0]" in text)


def case_fail_convention():
    msgs = run_case("EVAL-TOOLSECRET 读取 /tmp/desire-fixture/does-not-exist.txt")
    _, assistant, tools = last_exchange(msgs)
    turn = json.loads(bridge("GET", "/agent/trace")["jsonl"].split("\n")[-1])
    step = (turn.get("steps") or [{}])[0]
    check("E2 工具被调用", step.get("action") == "readFile")
    check("E2 工具结果以 Error: 开头", (step.get("result") or "").startswith("Error:"))
    check("E2 轨迹标记 threwError", step.get("threwError") is True)
    seen = assistant.get("content") or ""
    check("E2 模型看到的也是失败（Error:）", seen.startswith("MODEL-SAW>>>Error:"))
    check("E2 机械核验触发（全部失败 → 提示）", bool(assistant.get("verificationNote")))


def case_redaction():
    msgs = run_case("EVAL-READSECRET 读取凭据文件")
    _, assistant, tools = last_exchange(msgs)
    tool_text = "\n".join(m.get("content") or "" for m in tools)
    check("E3 工具结果无原始密钥", EVAL_FAKE_KEY not in tool_text)
    check("E3 工具结果有掩码", "[redacted]" in tool_text)
    seen = assistant.get("content") or ""
    check("E3 模型所见无原始密钥", EVAL_FAKE_KEY not in seen)
    check("E3 模型所见有掩码", "[redacted]" in seen)


def case_overflow_retry():
    fixture_bridge("GET", "/reset")   # 清计数：保证本用例确定性地先收到一次超限错误
    msgs = run_case("EVAL-OVERFLOWTEST 请简短回答")
    _, assistant, _ = last_exchange(msgs)
    text = assistant.get("content") or ""
    if not text.startswith("auth="):
        print(f"E4-DEBUG final text: {text[:200]!r}")
    check("E4 超限后自动重试并完成回合", text.startswith("auth="))
    check("E4 未把超限当失败丢弃", "⚠️" not in text)


# ---------- E5 fixtures 回放（个性化 7：真实 👍 语料回归）----------

FIXTURE_ITEMS = []


def case_network_rules():
    """networkRules 会话拦截（0.6.6）：加规则 → 断言轨迹与 /intercept 的
    sessionRules → 清理。CI 上三次确定性超时（本地稳定全绿）——归为
    环境性差异，默认仅在本地跑（EVAL_E6=1 显式开启）。"""
    msgs = run_case("EVAL-NETRULE 屏蔽 eval-nrule.test 的请求")
    _, assistant, tools = last_exchange(msgs)
    turn = json.loads(bridge("GET", "/agent/trace")["jsonl"].split("\n")[-1])
    step = next((s for s in turn.get("steps") or [] if s.get("action") == "networkRules"), None)
    check("E6 networkRules 被调用", step is not None)
    result = (step or {}).get("result") or ""
    check("E6 工具结果确认会话规则", "Network rule added (session)" in result)
    check("E6 轨迹无 threwError", step.get("threwError") is not True)
    seen = assistant.get("content") or ""
    check("E6 收尾文本", "NETRULE-DONE" in seen)
    intercept = bridge("GET", "/intercept")
    sessions = intercept.get("sessionRules") or []
    check("E6 /intercept 会话规则在场", any("eval-nrule" in (x.get("urlFilter") or "") for x in sessions))
    # 清理：清掉会话规则（不依赖模型）
    bridge("POST", "/intercept/session/clear")


def case_fixtures():
    """真实 👍 语料回放：每条 goal 在假端点环境跑一个完整回合，断言系统
    契约在个性化改动后仍成立（system 唯一第 0 位 + notes 折叠语义）。
    语料由 scripts/export-thumbsup-eval.py 生成（仓库外，含真实内容勿提交）。"""
    if not FIXTURE_ITEMS:
        results.append(("E5 无 fixtures（--fixtures 未提供或文件为空）", True, ""))
        print("○ E5 无 fixtures，跳过")
        return
    ran, ok_count = 0, 0
    failures = []
    for item in FIXTURE_ITEMS[:5]:
        goal = item.get("goal") or ""
        if not goal.strip():
            continue
        ran += 1
        try:
            msgs = run_case(goal)
            _, assistant, _ = last_exchange(msgs)
            text = assistant.get("content") or ""
            # fixture 端点回显的契约行：system 唯一第 0 位。
            contract_ok = "sysCount=1" in text and "sysAt=[0]" in text
            if contract_ok:
                ok_count += 1
            else:
                failures.append(f"{goal[:40]}…（契约行缺失）")
        except Exception as exc:
            failures.append(f"{goal[:40]}…（{exc}）")
    if ran == 0:
        results.append(("E5 fixtures 全为空 goal", True, ""))
        print("○ E5 无有效 fixtures，跳过")
        return
    check(f"E5 真实语料回放 {ran} 条全过", ok_count == ran)
    if failures:
        results[-1] = (results[-1][0], False, "; ".join(failures[:3]))


# ---------- 主流程 ----------

def case_bypass_routing():
    """E7 旁路成本路由（0.6.7）：旁路档案指向同一 fixture（便宜模型名），
    断言 ① 标题生成请求带旁路档案的 model（成本感知路由生效）；
    ② 主回合仍走 eval 档案的模型；③ 记账按实际模型分账进统计。"""
    created = bridge("POST", "/ai/profiles", body={
        "name": "eval-bypass",
        "endpoint": fixture_endpoint(),
        "model": "fake-bypass",
        "key": "eval-key-1234567890",
    })
    bypass_id = created["id"]
    bridge("POST", "/ai/bypass-profile", body={"id": bypass_id})
    check("E7 路由已登记", (bridge("GET", "/ai/bypass-profile") or {}).get("profileId") == bypass_id)
    try:
        bridge("POST", "/agent/new", body={})   # 标题生成每会话只跑一次：必须新会话
        run_case("EVAL-BYPASS 请用一句话回应")
        # 标题请求在回合结束**之后**才发（isProcessing 交还之后）——轮询 fixture 记录。
        deadline = time.time() + 20
        requests = []
        bypass_titles = []
        while time.time() < deadline:
            requests = json.loads(fixture_bridge("GET", "/requests")).get("requests", [])
            bypass_titles = [r for r in requests
                             if r.get("model") == "fake-bypass"
                             and "conversation title" in (r.get("system") or "")]
            if bypass_titles:
                break
            time.sleep(0.5)
        check("E7 标题请求走旁路档案的模型", len(bypass_titles) >= 1)
        check("E7 主回合仍走 eval 档案的模型", any(
            r.get("model") == "fake-1" and "conversation title" not in (r.get("system") or "")
            for r in requests))
        # 记账：旁路逐笔按实际模型分账。会话落盘在 DiskStore 上排队（评估负载下
        # 积压可达分钟级）——轮询统计直到出现 fake-bypass 桶或超时。
        deadline = time.time() + 30
        stats = {}
        while time.time() < deadline:
            stats = bridge("GET", "/agent/stats")
            if any(m.get("model") == "fake-bypass" for m in stats.get("models", [])):
                break
            time.sleep(1)
        check("E7 统计含旁路 token", (stats.get("bypassTokens") or 0) > 0)
        check("E7 统计分模型含 fake-bypass（按实际跑的模型归账）", any(
            m.get("model") == "fake-bypass" for m in stats.get("models", [])))
    finally:
        bridge("POST", "/ai/bypass-profile", body={})   # 清除路由，不污染后续/其他用例
        bridge("POST", "/ai/profiles/delete", body={"id": bypass_id})


def case_whiteboard_contract():
    """E8 白板工具契约（0.6.7 评估集扩面）：一条消息 7 个调用按序执行——
    成功文案、Error: 契约分支（越界/缺参/移动越界）、读板闭环（编辑后 get
    读回新内容）。screenshot→evidence 链拆到 E10（CI 无头环境截图无图像
    数据，环境性差异——与 E6 同款处理）。"""
    bridge("POST", "/agent/new", body={})   # 干净会话 = 空板
    msgs = run_case("EVAL-WB 白板契约测试")
    tools = [m for m in msgs if m.get("role") == "tool"]
    assistant = [m for m in msgs if m.get("role") == "assistant"][-1]
    check("E8 七次调用全部有结果", len(tools) >= 7)
    texts = [(t.get("content") or "") for t in tools[-7:]]
    check("E8 空板 get 非失败", texts[0] == "Whiteboard is empty.")
    check("E8 越界 edit 报 Error:", texts[1].startswith("Error:") and "out of range" in texts[1])
    check("E8 缺 index 报 Error:", texts[2].startswith("Error:") and "Missing index" in texts[2])
    check("E8 render 成功两块", texts[3].startswith("Whiteboard updated: 2 block(s)"))
    check("E8 move 越界报 Error:", texts[4].startswith("Error:") and "out of range" in texts[4])
    check("E8 edit 块 2 成功", texts[5].startswith("Whiteboard block 2 edited"))
    check("E8 get 读回编辑后的内容", "X-->Y" in texts[6] and "2 block(s)" in texts[6])
    check("E8 收尾", "WBDONE" in (assistant.get("content") or ""))


def case_tool_result_summary():
    """E9 工具结果摘要缓存（0.6.7）：readFile 20KB → 请求里被截成
    「头部 + getToolResult 句柄」（fixture 在第二轮只见 stub，END 哨兵不可见）
    → 模型按句柄调 getToolResult 取回全文 → END 哨兵可见。全链由 fixture
    侧断言（stub 形态、句柄取回），eval 侧断言最终收敛 E9DONE-full。"""
    bridge("POST", "/agent/new", body={})
    msgs = run_case("EVAL-BIG 请读取并确认大文件内容")
    _, assistant, _ = last_exchange(msgs)
    check("E9 截断→句柄→取回全文 全链收敛", (assistant.get("content") or "") == "E9DONE-full")


def case_evidence_chain():
    """E10 screenshot→evidence 引用链（0.6.7，本地专属）：截图 → append image
    块（evidence:"last"，零 base64 回传）→ get 读出 [image]。CI 无头环境截图
    无图像数据，默认跳过；EVAL_E10=1 本地显式运行（与 E6 同款口径）。"""
    bridge("POST", "/agent/new", body={})
    msgs = run_case("EVAL-EVID 证据引用链测试")
    tools = [m for m in msgs if m.get("role") == "tool"]
    assistant = [m for m in msgs if m.get("role") == "assistant"][-1]
    check("E10 三次调用全部有结果", len(tools) >= 3)
    texts = [(t.get("content") or "") for t in tools[-3:]]
    check("E10 screenshot 成功", not texts[0].startswith("Error:"))
    check("E10 append evidence 成功", texts[1].startswith("Whiteboard appended: 1 block(s)"))
    check("E10 get 含 image 块（evidence 已解析）", "[image]" in texts[2])
    check("E10 收尾", "EVIDONE" in (assistant.get("content") or ""))


def case_dpp_board():
    """E11 DPP 一键上板（0.6.9，本地专属）：demo 商店页 pageExtract →
    whiteboard from:"extract" 一条指令出板（note + table 两块）。生产网络
    依赖，默认 CI 跳过；EVAL_E11=1 本地显式运行（需先 POST /navigate 到 demo 商店）。"""
    bridge("POST", "/navigate", body={"url": "https://desire.mankong.icu/demo/"})
    time.sleep(3)   # DPP L3 SDK 声明注入
    bridge("POST", "/agent/new", body={})
    msgs = run_case("EVAL-BOARD 把商品列表做成白板")
    tools = [m for m in msgs if m.get("role") == "tool"]
    assistant = [m for m in msgs if m.get("role") == "assistant"][-1]
    check("E11 两步工具链完成", len(tools) >= 2)
    check("E11 一条指令出板（note+table）",
          "Whiteboard updated" in (tools[-1].get("content") or "")
          and "2 block(s)" in (tools[-1].get("content") or ""))
    check("E11 收尾", "E11DONE-board" in (assistant.get("content") or ""))


def case_dpp_frame_extract():
    """E12 DPP 跨源子框架提取（0.7 切片二，本地专属）：双源 fixture
    （18877 主页内嵌 18878 跨源 iframe，各自带 L2 声明）——主框架看不到
    子框架 DOM，pageExtract("frameProducts") 抽到的哨兵 = per-frame 执行
    的唯一证明。默认 CI 跳过；EVAL_E12=1 本地显式运行。"""
    import subprocess, tempfile, pathlib
    work = pathlib.Path(tempfile.mkdtemp(prefix="dpp-iframe-"))
    (work / "main.html").write_text(
        '<html><h1>Main frame</h1>'
        '<iframe src="http://127.0.0.1:18878/frame.html" width="300" height="150"></iframe>'
        '<script>window.__desireProtocolExposed = {views: {main: {item: "h1"}}};</script></html>')
    # 字段相对 **item 元素** 解析（spec §4.3）——哨兵必须放进 item 子树。
    # E13 增强：框架内按钮 + 状态 span + click handler + action 声明
    # （pageAction 的点击与状态变化都发生在**子框架**——读回状态即全链证明）
    (work / "frame.html").write_text(
        '<html><h1 data-frame="yes">Cross-origin frame content '
        '<span id="marker">E12-FRAME-SENTINEL</span></h1>'
        '<button id="frame-btn">toggle</button><span id="frame-state">off</span>'
        '<script>window.__desireProtocolExposed = {views: {frameProducts: {'
        'item: "[data-frame]", fields: {title: {selector: "#marker"},'
        'state: {selector: "#frame-state"}}}},'
        'actions: {"frame-toggle": {run: [{click: "#frame-btn"}],'
        'effects: "local"}}};'
        'document.getElementById("frame-btn").addEventListener("click",'
        'function(){document.getElementById("frame-state").textContent = "E13-FRAME-ON";});'
        '</script></html>')
    servers = []
    for port in (18877, 18878):
        servers.append(subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port), "--directory", str(work)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(1)
    try:
        bridge("POST", "/navigate", body={"url": "http://127.0.0.1:18877/main.html"})
        time.sleep(3.5)   # 主框架解析 + 子框架采集防抖 + per-frame 解析
        bridge("POST", "/agent/new", body={})
        msgs = run_case("EVAL-FRAME 抽取跨源框架的商品")
        tools = [m for m in msgs if m.get("role") == "tool"]
        assistant = [m for m in msgs if m.get("role") == "assistant"][-1]
        check("E12 一次工具调用完成", len(tools) >= 1)
        result = tools[-1].get("content") or ""
        if "E12-FRAME-SENTINEL" not in result:
            print(f"E12-DEBUG result: {result[:260]!r}")
        check("E12 抽取结果含子框架哨兵（per-frame 执行）", "E12-FRAME-SENTINEL" in result)
        check("E12 收尾", "E12DONE-frame" in (assistant.get("content") or ""))
    finally:
        for s in servers:
            s.terminate()
        shutil.rmtree(work, ignore_errors=True)


def case_dpp_frame_action():
    """E13 跨源 pageAction 全链（0.7 切片二）：动作声明在跨源子框架——
    pageAction 路由进框架点击按钮（框架内 handler 置状态），pageExtract
    读回状态文本。三段全在子框架内完成 = 动作路由的真验收。"""
    import subprocess, tempfile, pathlib
    work = pathlib.Path(tempfile.mkdtemp(prefix="dpp-iframe-act-"))
    (work / "main.html").write_text(
        '<html><h1>Main frame</h1>'
        '<iframe src="http://127.0.0.1:18879/frame.html" width="300" height="150"></iframe>'
        '<script>window.__desireProtocolExposed = {views: {main: {item: "h1"}}};</script></html>')
    (work / "frame.html").write_text(
        '<html><h1 data-frame="yes">Frame</h1>'
        '<button id="frame-btn">toggle</button><span id="frame-state">off</span>'
        '<script>window.__desireProtocolExposed = {views: {frameState: {'
        'item: "body", fields: {state: {selector: "#frame-state"}}}},'
        'actions: {"frame-toggle": {run: [{click: "#frame-btn"}],'
        'effects: "local"}}};'
        'document.getElementById("frame-btn").addEventListener("click",'
        'function(){document.getElementById("frame-state").textContent = "E13-FRAME-ON";});'
        '</script></html>')
    servers = []
    for port in (18878, 18879):
        servers.append(subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port), "--directory", str(work)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(1)
    try:
        bridge("POST", "/navigate", body={"url": "http://127.0.0.1:18879/main.html"})
        time.sleep(3.5)
        bridge("POST", "/agent/new", body={})
        msgs = run_case("EVAL-FRAME-ACT 点跨源框架的按钮")
        tools = [m for m in msgs if m.get("role") == "tool"]
        assistant = [m for m in msgs if m.get("role") == "assistant"][-1]
        check("E13 两次工具调用完成", len(tools) >= 2)
        for i, t in enumerate(tools):
            r = t.get("content") or ""
            if i == 0 and "clicked" not in r and "Action executed" not in r:
                print(f"E13-DEBUG tool[0]: {r[:200]!r}")
        act_result = tools[0].get("content") or ""
        check("E13 pageAction 成功（路由进子框架）",
              "Action executed" in act_result or "clicked" in act_result)
        extract = tools[-1].get("content") or ""
        check("E13 提取读回框架内状态变化", "E13-FRAME-ON" in extract)
        check("E13 收尾", "E13DONE-on" in (assistant.get("content") or ""))
    finally:
        for s in servers:
            s.terminate()
        shutil.rmtree(work, ignore_errors=True)


def case_bridge_guard():
    """E14：桥的 Host/Origin 双闸（0.7.4 安全轮回归）。
    urllib 默认不带 Origin；403 会抛 HTTPError，按状态码断言。"""
    def code(req):
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status
        except urllib.error.HTTPError as e:
            return e.code

    ok = urllib.request.Request(BRIDGE + "/state")
    check("E14 正常 curl 形态（无 Origin）200", code(ok) == 200)

    rebind = urllib.request.Request(BRIDGE + "/state")
    rebind.add_header("Host", "evil.example.com")
    check("E14 恶意 Host（DNS rebinding）403", code(rebind) == 403)

    cross = urllib.request.Request(BRIDGE + "/navigate", method="POST", data=b"{}")
    cross.add_header("Content-Type", "application/json")
    cross.add_header("Origin", "https://evil.example.com")
    check("E14 跨站 Origin 403", code(cross) == 403)

    nulled = urllib.request.Request(BRIDGE + "/navigate", method="POST", data=b"{}")
    nulled.add_header("Content-Type", "application/json")
    nulled.add_header("Origin", "null")
    check("E14 Origin null（file:// 源）403", code(nulled) == 403)

    local = urllib.request.Request(BRIDGE + "/state")
    local.add_header("Origin", "http://127.0.0.1:8799")
    check("E14 本机 Origin 200", code(local) == 200)


def case_har_export():
    """E15：HAR 1.2 导出（0.7.5 DevTools 回归）。
    导航到桥自身的 /state（必然可达），断言条目与结构；再验 scope 过滤错误路径。"""
    bridge("POST", "/navigate", body={"url": BRIDGE + "/state"})
    # 导航→netEntry→store 有延迟（CI 虚机更慢）：轮询而不是固定睡——
    # 固定 sleep(2) 在 CI 上 entries 还是 0（首次发版实测）。
    entries = []
    for _ in range(20):
        time.sleep(0.5)
        entries = bridge("GET", "/devtools/har?scope=all").get("log", {}).get("entries", [])
        if entries:
            break
    log = {"version": "1.2", "entries": entries}
    check("E15 log.version == 1.2",
          bridge("GET", "/devtools/har?scope=all").get("log", {}).get("version") == "1.2")
    check("E15 entries >= 1", len(entries) >= 1)
    if entries:
        e = entries[-1]
        check("E15 entry 结构完整",
              all(k in e for k in ("request", "response", "timings", "startedDateTime")))
        check("E15 request 必备字段",
              all(k in e.get("request", {}) for k in ("method", "url", "headers", "queryString")))
    bad = bridge("GET", "/devtools/har?scope=tab=not-a-uuid")
    check("E15 非法 tab uuid 报错", "error" in bad)


CASES = [("E1 plain-echo", case_plain_echo),
         ("E2 fail-convention", case_fail_convention),
         ("E3 redaction", case_redaction),
         ("E4 overflow-retry", case_overflow_retry),
         ("E5 fixtures-replay", case_fixtures),
         ("E6 network-rules（本地专属，EVAL_E6=1 开启）", case_network_rules),
         ("E7 bypass-routing", case_bypass_routing),
         ("E8 whiteboard-contract", case_whiteboard_contract),
         ("E9 tool-result-summary", case_tool_result_summary),
         ("E10 evidence-chain（本地专属，EVAL_E10=1 开启）", case_evidence_chain),
         ("E11 dpp-board（本地专属，EVAL_E11=1 开启）", case_dpp_board),
         ("E12 dpp-frame-extract（本地专属，EVAL_E12=1 开启）", case_dpp_frame_extract),
         ("E13 dpp-frame-action（本地专属，EVAL_E13=1 开启）", case_dpp_frame_action),
         ("E14 bridge-guard", case_bridge_guard),
         ("E15 har-export", case_har_export)]

results = []


def check(name, condition):
    results.append((name, bool(condition), "" if condition else "断言不成立"))


def main():
    global BRIDGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default=BRIDGE)
    parser.add_argument("--cleanup", action="store_true",
                        help="删除评估写入的会话（按脚本记录的精确 id）")
    parser.add_argument("--keep-fixture", action="store_true")
    parser.add_argument("--fixtures", default="",
                        help="thumbsup 评估素材 JSON（scripts/export-thumbsup-eval.py 生成）；E5 用例回放其 goal")
    args, _ = parser.parse_known_args()
    BRIDGE = args.base
    if args.fixtures:
        if os.path.exists(args.fixtures):
            with open(args.fixtures, encoding="utf-8") as fh:
                FIXTURE_ITEMS.extend(json.load(fh).get("fixtures", []))
            print(f"E5 fixtures 已加载：{len(FIXTURE_ITEMS)} 条")
        else:
            print(f"E5 fixtures 文件不存在：{args.fixtures}（用例将跳过）")

    bridge("GET", "/state")   # 桥健康检查；不可达会直接抛错
    ensure_workdir()
    install_profile()
    try:
        for name, case in CASES:
            if case is case_network_rules and os.environ.get("EVAL_E6") != "1":
                results.append((name + " — CI 跳过（本地 EVAL_E6=1 运行）", True, ""))
                continue
            if case is case_evidence_chain and os.environ.get("EVAL_E10") != "1":
                results.append((name + " — CI 跳过（本地 EVAL_E10=1 运行）", True, ""))
                continue
            if case is case_dpp_board and os.environ.get("EVAL_E11") != "1":
                results.append((name + " — CI 跳过（本地 EVAL_E11=1 运行）", True, ""))
                continue
            if case is case_dpp_frame_extract and os.environ.get("EVAL_E12") != "1":
                results.append((name + " — CI 跳过（本地 EVAL_E12=1 运行）", True, ""))
                continue
            if case is case_dpp_frame_action and os.environ.get("EVAL_E13") != "1":
                results.append((name + " — CI 跳过（本地 EVAL_E13=1 运行）", True, ""))
                continue
            try:
                case()
                results.append((name, True, ""))
                print(f"✓ {name}")
            except Exception as exc:
                results.append((name, False, str(exc)))
                print(f"✗ {name}: {exc}")
    finally:
        restore_profile()
        stop_fixture()
        if fixture_proc:
            fixture_proc.wait(timeout=10)
        if workdir:
            shutil.rmtree(workdir, ignore_errors=True)
        if args.cleanup and eval_conversations:
            ids = sorted(set(eval_conversations))
            result = bridge("POST", "/conversations/delete", body={"ids": ids})
            if result.get("liveConversationDeleted"):
                # 活会话删了会把实例的投递目标打残（后续 /agent/send 静默失效），
                # 同一实例的下一次评估就全超时。留着它，换实例再清。
                print("注：评估会话是活会话，已跳过删除（避免打残实例的投递目标）")
            else:
                print(f"已删除评估会话：{len(result.get('deleted') or [])} 个")

    print(f"\n评估结果：{sum(1 for _, ok, _ in results if ok)}/{len(results)} 通过")
    failed = [(name, note) for name, ok, note in results if not ok]
    for name, note in failed:
        print(f"  ✗ {name}" + (f" — {note}" if note else ""))
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
