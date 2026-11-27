#!/usr/bin/env python3
"""API 账号安全 DB 级 E2E（v0.8.81 批 1）：需要真实 API + MySQL + 已跑 0021。

覆盖：
  1) 同设备两次登录 → logout 第一次 → 第二次 refresh 也必须失效（S1）；
  2) 改密 → 旧 access 立即 401，当前设备 refresh 仍可换新 access（token 版本）；
  3) 恢复码 → 重置密码、旧 refresh 全失效、恢复码一次性；
  4) 设备版本/用户版本即时生效。

前置：`DESIRE_ENV=dev`（captcha 返回明文码）、`desire-migrate` 已跑。
本机无 MySQL 时跳过（退出码 2），不要冒充通过。
用法：python3 tests/api-db-e2e.py [--base http://127.0.0.1:18090]
"""
import argparse
import json
import time
import urllib.error
import urllib.request

checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def request(base, method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.loads(resp.read().decode())
            return resp.status, payload
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode())
        except Exception:
            payload = {}
        return exc.code, payload
    except (urllib.error.URLError, ConnectionError, TimeoutError) as exc:
        return 0, {"error": str(exc)}


def data_of(payload):
    return (payload or {}).get("data") or {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18090")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    status, health = request(base, "GET", "/health")
    if status != 200:
        print(f"△ 跳过：API 不可达 {base}/health（status={status}）")
        return 2
    if not (health.get("data") or {}).get("db"):
        print("△ 跳过：API health 显示 db=false")
        return 2

    status, captcha = request(base, "GET", "/auth/captcha")
    captcha_data = data_of(captcha)
    if status != 200 or not captcha_data.get("code"):
        print("△ 跳过：非 dev 环境（captcha 不返回明文码）或验证码端点不可用")
        return 2

    tag = str(int(time.time()))[-7:]
    username = f"dbe2e{tag}"
    password = "E2ePass12345"
    password2 = "E2ePass23456"
    password3 = "E2ePass34567"
    device = {"device_id": f"db-e2e-{tag}", "name": "DB E2E", "platform": "macOS"}

    status, payload = request(base, "POST", "/auth/register", {
        "username": username, "password": password,
        "captcha_id": captcha_data["captcha_id"], "captcha_code": captcha_data["code"],
        "device": device,
    })
    tokens1 = data_of(payload)
    ok("注册并签发 token", status == 200 and tokens1.get("access_token") and tokens1.get("refresh_token"),
       str(payload)[:300])
    if not tokens1:
        return 1

    # 同设备第二次登录：两条 refresh token 同属一个 devices 行。
    status, payload = request(base, "POST", "/auth/login", {
        "username": username, "password": password, "device": device,
    })
    tokens2 = data_of(payload)
    ok("同设备第二次登录", status == 200 and tokens2.get("refresh_token"), str(payload)[:200])

    # logout 第一次登录：必须把同设备的第二条 refresh 也吊销（S1）。
    status, payload = request(base, "POST", "/auth/logout",
                              {"refresh_token": tokens1["refresh_token"]})
    ok("logout 接受", status == 200, str(payload)[:200])
    status, _ = request(base, "GET", "/auth/me", token=tokens1["access_token"])
    ok("logout 后旧 access 立即 401", status == 401, f"status={status}")
    status, payload = request(base, "POST", "/auth/refresh",
                              {"refresh_token": tokens2["refresh_token"]})
    ok("logout 吊销同设备全部 refresh（第二条也 401）", status == 401,
       f"status={status} {payload}")

    # 重新登录，改密：旧 access 失效，当前设备 refresh 仍可用。
    status, payload = request(base, "POST", "/auth/login", {
        "username": username, "password": password, "device": device,
    })
    tokens3 = data_of(payload)
    status, payload = request(base, "PUT", "/auth/password", {
        "old_password": password, "new_password": password2,
    }, token=tokens3.get("access_token"))
    ok("改密成功", status == 200, f"status={status} {payload}")
    status, _ = request(base, "GET", "/auth/me", token=tokens3.get("access_token"))
    ok("改密后旧 access 401（用户版本 +1）", status == 401, f"status={status}")
    status, refreshed = request(base, "POST", "/auth/refresh",
                                {"refresh_token": tokens3["refresh_token"]})
    ok("当前设备 refresh 仍可换新 access", status == 200 and data_of(refreshed).get("access_token"),
       f"status={status} {str(refreshed)[:200]}")
    new_access = data_of(refreshed).get("access_token")
    new_refresh = data_of(refreshed).get("refresh_token")

    # 恢复码：生成 → 重置 → 旧 refresh 全失效；恢复码一次性。
    status, payload = request(base, "POST", "/auth/recovery-code", {}, token=new_access)
    recovery = data_of(payload).get("recovery_code")
    ok("生成恢复码", status == 200 and bool(recovery), str(payload)[:200])
    status, payload = request(base, "POST", "/auth/recover", {
        "username": username, "recovery_code": recovery or "", "new_password": password3,
    })
    ok("恢复码重置密码", status == 200, f"status={status} {str(payload)[:200]}")
    status, _ = request(base, "GET", "/auth/me", token=new_access)
    ok("恢复后旧 access 401", status == 401, f"status={status}")
    status, _ = request(base, "POST", "/auth/refresh", {"refresh_token": new_refresh})
    ok("恢复后旧 refresh 401（全端吊销）", status == 401, f"status={status}")
    status, payload = request(base, "POST", "/auth/recover", {
        "username": username, "recovery_code": recovery or "", "new_password": password2,
    })
    ok("恢复码只能使用一次", status == 401, f"status={status} {str(payload)[:160]}")

    status, payload = request(base, "POST", "/auth/login", {
        "username": username, "password": password3, "device": device,
    })
    final = data_of(payload)
    ok("新密码登录", status == 200 and final.get("access_token"), f"status={status}")

    # 清理：删除测试账号（级联清同步/设备/令牌/审计）。
    if final.get("access_token"):
        status, payload = request(base, "DELETE", "/auth/account",
                                  {"password": password3}, token=final["access_token"])
        ok("清理：删除测试账号", status == 200, f"status={status} {payload}")

    passed = sum(1 for _, cond in checks if cond)
    print(f"\nAPI DB E2E：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
