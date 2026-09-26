#!/usr/bin/env python3
"""远程控制 E2E 冒烟:同一账号演 desktop/controller 双角色,全链路验证。

用法: python3 tools/api-remote-smoke.py [BASE_URL]   (默认 http://127.0.0.1:18090)
前置: api 已在本机运行(desktop/controller 角色走 REST,express 走 WS)。
覆盖: 配对签发/认领 / push→pull 双方向 / replace 语义 / last_seen 在线判定
      / 吊销后 push 403 / WS express(尽力而为,未配 Redis 时警告跳过)。
清理: 脚本只创建 `smoke_rc_` 前缀用户;测试完由调用方按标记清理(见脚本输出)。
"""
import base64
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:18090"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # 本机直连,禁代理

STEP_NO = 0


def step(msg):
    global STEP_NO
    STEP_NO += 1
    print(f"ok {STEP_NO}: {msg}")


def call(method, path, body=None, token=None):
    """返回 (http_status, envelope)。"""
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = json.dumps(body).encode() if body is not None else None
    try:
        with OPENER.open(req, data=data, timeout=10) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def must(method, path, body=None, token=None):
    status, env = call(method, path, body, token)
    assert status == 200 and env.get("code") == 0, f"{method} {path} -> {status} {env}"
    return env.get("data")


# ---- 最小 WS 客户端(保持连接读 Text 帧;够 express 验证用) ----

def ws_connect(host, port, path, token):
    """握手 + 返回 (socket, 已缓冲字节)。调用方负责 close。"""
    sock = socket.create_connection((host, port), timeout=8)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {token}\r\n\r\n"
    )
    sock.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("ws handshake failed")
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    assert b" 101 " in head.split(b"\r\n")[0], head.split(b"\r\n")[0]
    return sock, rest


def ws_read_text(sock, rest, timeout):
    """在既有连接上读下一个 Text 帧;超时返回 None。"""
    deadline = time.time() + timeout
    sock.settimeout(max(0.5, timeout))

    def recv_exact(n):
        nonlocal rest
        while len(rest) < n:
            try:
                chunk = sock.recv(4096)
            except (socket.timeout, TimeoutError):
                return False
            if not chunk:
                return False
            rest += chunk
        return True

    while time.time() < deadline:
        if not recv_exact(2):
            return None
        b1, b2 = rest[0], rest[1]
        opcode = b1 & 0x0F
        ln = b2 & 0x7F
        rest = rest[2:]
        if ln == 126:
            if not recv_exact(2):
                return None
            ln = int.from_bytes(rest[:2], "big")
            rest = rest[2:]
        elif ln == 127:
            if not recv_exact(8):
                return None
            ln = int.from_bytes(rest[:8], "big")
            rest = rest[8:]
        if not recv_exact(ln):
            return None
        payload, rest = rest[:ln], rest[ln:]
        if opcode == 1:
            return payload.decode()
        # 8=close 9=ping(忽略) 其他帧跳过
    return None


def main():
    # health
    status, env = call("GET", "/health")
    assert status == 200, f"health -> {status}"
    step("GET /health")

    # 注册 + 双角色登录(同账号)
    user = f"smoke_rc_{uuid.uuid4().hex[:8]}"
    password = "SmokeRc123"
    desk = f"SMOKE-RC-DESK-{uuid.uuid4().hex[:6]}"
    ctrl_name = "SmokePhone"
    status, cap = call("GET", "/auth/captcha")
    assert status == 200, "captcha 失败"
    captcha = cap["data"]
    must("POST", "/auth/register", {
        "username": user, "password": password,
        "device": {"device_id": f"{desk}-reg", "name": "Smoke", "platform": "macOS"},
        "captcha_id": captcha["captcha_id"], "captcha_code": captcha.get("code", ""),
    })
    step(f"注册测试账号 {user}")

    def login(device_id):
        status, cap = call("GET", "/auth/captcha")
        assert status == 200
        captcha = cap["data"]
        return must("POST", "/auth/login", {
            "username": user, "password": password,
            "device": {"device_id": device_id, "name": "Smoke", "platform": "macOS"},
            "captcha_id": captcha["captcha_id"], "captcha_code": captcha.get("code", ""),
        })["access_token"]

    desk_tok = login(f"{desk}-d")
    ctrl_tok = login(f"{desk}-c")
    step("同账号双角色登录(desktop/controller)")

    # 配对签发 + 认领
    code = must("POST", "/remote/pairing/start", {
        "desktop_device_id": desk, "desktop_name": "SmokeMac",
    }, token=desk_tok)["code"]
    assert len(code) == 8, code
    claimed = must("POST", "/remote/pairing/claim", {
        "code": code, "controller_name": ctrl_name,
    }, token=ctrl_tok)
    assert claimed["desktopDeviceId"] == desk, claimed
    step("配对码签发 + 认领(返回 desktopDeviceId)")

    # controller → desktop push/pull
    p1 = base64.b64encode(b"hello-from-controller").decode()
    must("POST", f"/remote/push?role=controller&device={desk}",
         {"payload": p1, "replace": False}, token=ctrl_tok)
    pulled = must("GET", f"/remote/pull?role=desktop&device={desk}", token=desk_tok)
    assert any(i["payload"] == p1 for i in pulled["items"]), pulled
    assert "desktopOnline" in pulled, pulled
    step("controller→desktop push + pull 取帧(带 desktopOnline)")

    # desktop → controller + replace 语义 + lane 隔离:
    # 快照 lane 两连发只留最后一条;回包(无 lane)不被快照的 replace 误删
    pa = base64.b64encode(b"snapshot-v1").decode()
    pb = base64.b64encode(b"snapshot-v2").decode()
    pc = base64.b64encode(b"reply-sessions").decode()
    must("POST", f"/remote/push?role=desktop&device={desk}&lane=snapshot",
         {"payload": pa, "replace": True}, token=desk_tok)
    must("POST", f"/remote/push?role=desktop&device={desk}",
         {"payload": pc, "replace": False}, token=desk_tok)
    must("POST", f"/remote/push?role=desktop&device={desk}&lane=snapshot",
         {"payload": pb, "replace": True}, token=desk_tok)
    pulled = must("GET", f"/remote/pull?role=controller&device={desk}", token=ctrl_tok)
    payloads = [i["payload"] for i in pulled["items"]]
    assert payloads == [pc, pb], payloads
    step("desktop→controller:replace 只清快照 lane,回包不被误删")

    # devices 列表 + 在线判定(刚 pull 过 → online;>15s 不 pull → offline)
    devices = must("GET", "/remote/devices", token=desk_tok)["devices"]
    assert any(d["controllerName"] == ctrl_name and d["online"] for d in devices), devices
    step("devices 列表:桌面 last_seen 窗口内 = online")
    print("  … 等 16s 验证 last_seen 过期(在线窗口 15s)")
    time.sleep(16)
    devices = must("GET", "/remote/devices", token=desk_tok)["devices"]
    assert any(d["controllerName"] == ctrl_name and not d["online"] for d in devices), devices
    step(">15s 无 pull → online=false(跨实例判定基于 DB,不依赖进程内注册表)")

    # WS express(尽力而为:未配 Redis 时服务器静默跳过 → 警告并继续)
    # 顺序敏感:先连 WS(连接保持),push 在连接存续期间发出,再读帧
    code = must("POST", "/remote/pairing/start", {
        "desktop_device_id": desk, "desktop_name": "SmokeMac",
    }, token=desk_tok)["code"]
    must("POST", "/remote/pairing/claim", {
        "code": code, "controller_name": ctrl_name + "-2",
    }, token=ctrl_tok)
    host = BASE.split("//")[1].split(":")[0]
    port = int(BASE.split(":")[-1])
    pe = base64.b64encode(b"express-probe").decode()
    wsock, wbuf = ws_connect(host, port, f"/remote/ws?role=desktop&device={desk}", desk_tok)
    try:
        must("POST", f"/remote/push?role=controller&device={desk}",
             {"payload": pe, "replace": False}, token=ctrl_tok)
        express = ws_read_text(wsock, wbuf, timeout=6)
    finally:
        wsock.close()
    if express and json.loads(express).get("payload") == pe:
        step("WS express:push 后即时到达(同形信封 id+payload)")
    else:
        print("WARN: express 未到达 —— 服务器大概率未配置 DESIRE_REDIS_URL;"
              "pull 兜底已覆盖,生产部署需两实例共享同一 Redis")
    # express 探针帧留在信箱里,取走(桌面 role 的 inbox_take 不校验配对)
    must("GET", f"/remote/pull?role=desktop&device={desk}", token=desk_tok)

    # 吊销 → controller push 403
    r = must("POST", "/remote/pairing/revoke", {
        "desktop_device_id": desk, "controller_name": None,
    }, token=desk_tok)
    assert r["revoked"] >= 1, r
    status, env = call("POST", f"/remote/push?role=controller&device={desk}",
                       {"payload": p1, "replace": False}, token=ctrl_tok)
    assert status == 403, f"吊销后 push -> {status} {env}"
    step("吊销后 controller push → 403")

    print(f"\n全部 {STEP_NO} 步通过。清理测试用户(仅本地 dev 库):")
    print(f"  mysql -h 127.0.0.1 -u root -p desire -e "
          f"\"DELETE FROM users WHERE username='{user}';\"")


if __name__ == "__main__":
    main()
