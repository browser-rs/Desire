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
# OVERFLOW_ONCE：第一次带 OVERFLOWTEST 的请求报 context length 错误，之后正常 ——
# 用于验证应用会"压缩预算减半重试"。
overflow_seen = 0
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

        # 分支判据只看最后一条 user 消息 + 本轮（其后）的工具结果。历史轮次里
        # 的用例关键词绝不能影响本轮分支——否则 E4 的请求体里带着 E2/E3 的
        # 关键词，会串到别人的分支（2026-09-24，eval 三查三改才定位到这）。
        last_user_idx = max((i for i, m in enumerate(msgs_all) if m.get("role") == "user"), default=-1)
        mode_text = (msgs_all[last_user_idx].get("content") or "") if last_user_idx >= 0 else ""
        round_msgs = msgs_all[last_user_idx + 1:]
        has_tool = any(m.get("role") == "tool" for m in round_msgs)

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
    script = workdir / "fixture.py"
    script.write_text(FIXTURE_SOURCE)
    port_file = workdir / "port"
    child_env = {**os.environ,
                 "EVAL_PORT": "0",          # 临时端口：8880 被占也不受影响
                 "EVAL_PORT_FILE": str(port_file),
                 "EVAL_SECRET_PATH": str(secret),
                 "EVAL_SECRET2_PATH": str(workdir / "secret2.txt"),
                 "EVAL_MISSING_PATH": str(workdir / "missing.txt")}
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
    check("E4 超限后自动重试并完成回合", text.startswith("auth="))
    check("E4 未把超限当失败丢弃", "⚠️" not in text)


# ---------- 主流程 ----------

CASES = [("E1 plain-echo", case_plain_echo),
         ("E2 fail-convention", case_fail_convention),
         ("E3 redaction", case_redaction),
         ("E4 overflow-retry", case_overflow_retry)]

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
    args, _ = parser.parse_known_args()
    BRIDGE = args.base

    bridge("GET", "/state")   # 桥健康检查；不可达会直接抛错
    ensure_workdir()
    install_profile()
    try:
        for name, case in CASES:
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
