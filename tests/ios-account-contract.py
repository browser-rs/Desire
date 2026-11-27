#!/usr/bin/env python3
"""iOS 账号安全接口契约（v0.8.83 批 5）。

用本地 API（默认 http://127.0.0.1:18090）走一遍 iPhone 账号安全页真正
调用的接口：恢复码、审计、设备列表、设备吊销、旧 refresh 失效。
断言的是 **JSON 字段名/类型**（RemoteAccountModels.swift 的 CodingKeys），
不是 UI。无 API / 非 dev 验证码时明确 SKIP（退出码 0，不假绿）。

用法：python3 tests/ios-account-contract.py [--server URL]
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
import uuid


def http(method, url, body=None, token=None, timeout=30):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            return exc.code, json.loads(raw) if raw else {}
        except ValueError:
            return exc.code, {"raw": raw}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", default="http://127.0.0.1:18090")
    args = parser.parse_args()

    try:
        status, health = http("GET", args.server + "/health", timeout=3)
        if status != 200 or not (health.get("data") or {}).get("db"):
            print(f"SKIP: API/DB unavailable at {args.server}")
            return 0
    except Exception as exc:
        print(f"SKIP: API unavailable at {args.server} ({exc})")
        return 0

    tag = uuid.uuid4().hex[:8]
    username = f"iOSContract{tag}"
    password = f"Contract{tag}9"
    device_a = f"contract-mac-{tag}"
    device_b = f"contract-ios-{tag}"
    checks = []

    def check(name, condition, detail=""):
        checks.append((name, bool(condition)))
        print(("✓ " if condition else "✗ ") + name + (f"  {detail}" if detail and not condition else ""))

    access = None
    try:
        status, captcha = http("GET", args.server + "/auth/captcha")
        code = ((captcha.get("data") or {}).get("code"))
        captcha_id = ((captcha.get("data") or {}).get("captcha_id"))
        if status != 200 or not code:
            print("SKIP: captcha dev code unavailable (non-dev server?)")
            return 0

        status, registered = http("POST", args.server + "/auth/register", {
            "username": username,
            "password": password,
            "device": {"device_id": device_a, "name": "Contract Mac", "platform": "macOS"},
            "captcha_id": captcha_id,
            "captcha_code": code,
        })
        data = registered.get("data") or {}
        access = data.get("access_token")
        check("注册返回 TokenPair", status == 200 and bool(access)
              and bool(data.get("refresh_token")) and isinstance(data.get("expires_in"), int),
              str(registered))
        if not access:
            return 1

        status, audit = http("GET", args.server + "/auth/audit", token=access)
        events = audit.get("data") or []
        check("审计返回事件数组", status == 200 and isinstance(events, list) and len(events) > 0,
              str(audit))
        if events:
            first = events[0]
            check("审计字段与 iOS 模型一致",
                  all(k in first for k in ("id", "event", "detail", "ip", "created_at"))
                  and isinstance(first.get("id"), int)
                  and isinstance(first.get("created_at"), str),
                  str(first))
        else:
            check("审计字段与 iOS 模型一致", False, "empty")

        status, devices = http("GET", args.server + "/auth/devices", token=access)
        rows = devices.get("data") or []
        mine = next((d for d in rows if d.get("device_id") == device_a), None)
        check("设备列表含当前设备", status == 200 and mine is not None, str(devices))
        if mine:
            check("设备字段与 iOS 模型一致",
                  all(k in mine for k in ("id", "device_id", "name", "platform",
                                          "revoked", "last_seen_at", "created_at"))
                  and mine.get("revoked") is False,
                  str(mine))

        status, recovery = http("POST", args.server + "/auth/recovery-code", token=access)
        check("恢复码返回 recovery_code",
              status == 200 and bool((recovery.get("data") or {}).get("recovery_code")),
              str(recovery))

        status, second = http("POST", args.server + "/auth/login", {
            "username": username,
            "password": password,
            "device": {"device_id": device_b, "name": "Contract iPhone", "platform": "iOS"},
        })
        second_data = second.get("data") or {}
        check("第二设备登录", status == 200 and bool(second_data.get("access_token")),
              str(second))

        status, revoked = http("POST", args.server + "/auth/devices/revoke",
                               {"device_id": device_b}, token=access)
        check("吊销第二设备", status == 200, str(revoked))

        status, devices2 = http("GET", args.server + "/auth/devices", token=access)
        rows2 = devices2.get("data") or []
        target = next((d for d in rows2 if d.get("device_id") == device_b), None)
        check("吊销态回读为 true", target is not None and target.get("revoked") is True,
              str(devices2))

        if second_data.get("refresh_token"):
            status, refreshed = http("POST", args.server + "/auth/refresh", {
                "refresh_token": second_data["refresh_token"]})
            check("旧 refresh 已失效（401）", status == 401, str(refreshed))
        else:
            check("旧 refresh 已失效（401）", False, "no refresh token")

        status, deleted = http("DELETE", args.server + "/auth/account",
                               {"password": password}, token=access)
        check("删除测试账号", status == 200, str(deleted))
    finally:
        if access:
            # 删除失败时兜底：脚本不把测试账号留在库里。
            status, _ = http("DELETE", args.server + "/auth/account",
                             {"password": password}, token=access)
            if status not in (200, 401):
                print(f"warning: test account cleanup status={status}")

    failed = [name for name, ok in checks if not ok]
    print(f"\niOS 账号契约：{len(checks) - len(failed)}/{len(checks)} 通过")
    for name in failed:
        print("  ✗", name)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
