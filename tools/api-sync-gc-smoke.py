#!/usr/bin/env python3
"""同步引擎「通用墓碑 GC」E2E 冒烟（v0.7.21 服务端批次）。

覆盖：
  1. 设备游标上报（pull 带 device → sync_pull_cursors 落行）
  2. 游标判定支：被所有活跃设备越过的墓碑（且超过宽限期）被回收，
     未被越过的（更晚的墓碑）保留
  3. 兜底支：无任何游标 → 只删超过 180 天的墓碑
  4. 过期设备游标清理（seen_at > 180 天）
  5. dry-run 只数不删
  6. 用户级联清理（测试账号自清）

前置：本地 MySQL（DATABASE_URL）与 desire-api 已跑（BASE，默认 127.0.0.1:18090）。
用法：DATABASE_URL=mysql://root:..@127.0.0.1:3306/desire python3 tools/api-sync-gc-smoke.py
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("GC_SMOKE_BASE", "http://127.0.0.1:18090")
DATABASE_URL = os.environ.get("DATABASE_URL", "")
fails: list[str] = []


def check(name: str, cond: bool, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  {extra}" if extra and not cond else ""))
    if not cond:
        fails.append(name)


def http(method: str, path: str, body=None, token: str | None = None):
    req = urllib.request.Request(BASE + path, method=method)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, data=data, timeout=20) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"_http": e.code}


# ---------- mysql CLI 通道 ----------

def parse_db_url(url: str):
    assert url.startswith("mysql://"), "DATABASE_URL 需为 mysql:// 形式"
    rest = url[len("mysql://"):]
    creds, hostpart = rest.split("@", 1)
    user, _, password = creds.partition(":")
    hostport, _, db = hostpart.partition("/")
    host, _, port = hostport.partition(":")
    return user, password, host, port or "3306", db


def mysql_query(sql: str) -> str:
    user, password, host, port, db = parse_db_url(DATABASE_URL)
    out = subprocess.run(
        ["mysql", "-h", host, "-P", port, "-u", user, f"-p{password}", db,
         "--batch", "--skip-column-names", "-e", sql],
        capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"mysql failed: {out.stderr.strip()}")
    return out.stdout.strip()


def main():
    if not DATABASE_URL:
        print("需要 DATABASE_URL 环境变量（mysql://…）")
        sys.exit(2)

    stamp = str(int(time.time()))
    username = f"e2egc{stamp}"
    password = "e2e-Passw0rd-1"

    device = {"device_id": f"gc-smoke-{stamp}", "name": "gc smoke", "platform": "macOS"}
    captcha = (http("GET", "/auth/captcha").get("data") or {})
    check("dev 验证码带明文码", bool(captcha.get("captcha_id")) and bool(captcha.get("code")), captcha)
    reg = http("POST", "/auth/register", {
        "username": username, "password": password, "device": device,
        "captcha_id": captcha.get("captcha_id", ""),
        "captcha_code": captcha.get("code", "")})
    check("注册测试账号", bool((reg.get("data") or {}).get("access_token")), reg)
    login = http("POST", "/auth/login", {
        "username": username, "password": password, "device": device})
    token = (login.get("data") or {}).get("access_token")
    check("登录拿到 access token", bool(token), login)
    if not token:
        sys.exit(1)

    user_id = mysql_query(
        f"SELECT id FROM users WHERE username = '{username}'").strip()
    check("库中拿到 user_id", bool(user_id))

    domain = "bookmarks"
    b_id, c_id = f"gc-B-{stamp}", f"gc-C-{stamp}"

    def push(items):
        return http("POST", f"/sync/{domain}", {"items": items}, token=token)

    def pull(since=None, since_id=None, device=None):
        q = []
        if since:
            q.append("since=" + urllib.parse.quote(since))
        if since_id is not None:
            q.append(f"since_id={since_id}")
        if device:
            q.append("device=" + device)
        path = f"/sync/{domain}" + ("?" + "&".join(q) if q else "")
        return http("GET", path, token=token)

    def items_of(resp):
        return (resp.get("data") or {}).get("items", [])

    # 1) B：写入后墓碑；C：稍后再墓碑（晚于 d1 游标）
    push([{"client_id": b_id, "client_updated_at": "2026-10-18T01:00:00.000000",
           "payload": {"title": "B"}}])
    push([{"client_id": b_id, "client_updated_at": "2026-10-18T01:01:00.000000",
           "deleted": True}])
    rows_b = mysql_query(
        f"SELECT updated_at FROM sync_items WHERE user_id={user_id} AND client_id='{b_id}'")
    check("B 墓碑落库", bool(rows_b), rows_b)

    # 2) d1 全量拉取 → 复合游标 → 再增量拉（上报 d1 游标）
    full = items_of(pull())
    check("d1 全量拉取含 B 墓碑", any(i.get("client_id") == b_id and i.get("deleted") for i in full), full)
    last = full[-1]
    cursor_ts, cursor_id = last["updated_at"], last["id"]
    r = pull(since=cursor_ts, since_id=cursor_id, device="d1")
    check("d1 增量拉取成功（游标被记账）", "data" in r, r)
    seen = mysql_query(
        f"SELECT COUNT(*) FROM sync_pull_cursors WHERE user_id={user_id} AND device_id='d1'")
    check("设备游标台账落行（d1）", seen == "1", seen)

    # 3) C：晚于 d1 游标的墓碑（应被保留）
    time.sleep(1.1)   # 让 updated_at 明确晚于游标
    push([{"client_id": c_id, "client_updated_at": "2026-10-18T02:00:00.000000",
           "payload": {"title": "C"}}])
    push([{"client_id": c_id, "client_updated_at": "2026-10-18T02:01:00.000000",
           "deleted": True}])

    # 4) 把 B 的行改老 60 天（越过 30 天宽限；仍在 d1 游标之内）
    mysql_query(
        f"UPDATE sync_items SET updated_at = NOW() - INTERVAL 60 DAY "
        f"WHERE user_id={user_id} AND client_id='{b_id}'")

    # 5) dry-run：只数不删，游标判定支
    dry = http("POST", "/sync/gc?dry_run=1", {}, token=token)
    dry_data = dry.get("data") or {}
    check("dry-run 判定支=cursor", (dry_data.get("basis") or {}).get(domain) == "cursor", dry_data)
    check("dry-run 计数 B 恰 1 条", (dry_data.get("deleted") or {}).get(domain) == 1, dry_data)
    still = mysql_query(
        f"SELECT COUNT(*) FROM sync_items WHERE user_id={user_id} AND client_id='{b_id}'")
    check("dry-run 未真删", still == "1", still)

    # 6) 真跑：B 回收、C 保留
    real = http("POST", "/sync/gc", {}, token=token)
    real_data = real.get("data") or {}
    check("真跑回收 B 恰 1 条", (real_data.get("deleted") or {}).get(domain) == 1, real_data)
    b_left = mysql_query(
        f"SELECT COUNT(*) FROM sync_items WHERE user_id={user_id} AND client_id='{b_id}'")
    c_row = mysql_query(
        f"SELECT deleted_at IS NOT NULL FROM sync_items WHERE user_id={user_id} AND client_id='{c_id}'")
    check("B 墓碑已回收", b_left == "0", b_left)
    check("C 墓碑保留（未被游标覆盖）", c_row == "1", c_row)

    # 7) 兜底支：清掉游标 → 只删超 180 天
    mysql_query(f"DELETE FROM sync_pull_cursors WHERE user_id={user_id}")
    fb = http("POST", "/sync/gc", {}, token=token)
    fb_data = fb.get("data") or {}
    check("无游标走兜底支", (fb_data.get("basis") or {}).get(domain) == "fallback", fb_data)
    c_still = mysql_query(
        f"SELECT COUNT(*) FROM sync_items WHERE user_id={user_id} AND client_id='{c_id}'")
    check("兜底支保留 <180 天的 C", c_still == "1", c_still)

    # 8) 把 C 改老 200 天 → 兜底支回收
    mysql_query(
        f"UPDATE sync_items SET updated_at = NOW() - INTERVAL 200 DAY "
        f"WHERE user_id={user_id} AND client_id='{c_id}'")
    fb2 = http("POST", "/sync/gc", {}, token=token)
    fb2_data = fb2.get("data") or {}
    check("兜底支回收超 180 天的 C", (fb2_data.get("deleted") or {}).get(domain) == 1, fb2_data)

    # 9) 过期游标清理：插一条 seen_at 200 天前的
    mysql_query(
        f"INSERT INTO sync_pull_cursors (user_id, domain, device_id, cursor_updated_at, cursor_id, seen_at) "
        f"VALUES ({user_id}, '{domain}', 'stale-dev', NOW(), 1, NOW() - INTERVAL 200 DAY)")
    stale = http("POST", "/sync/gc", {}, token=token)
    stale_data = stale.get("data") or {}
    check("过期游标被清理（stale_cursors≥1）", (stale_data.get("stale_cursors") or 0) >= 1, stale_data)
    stale_left = mysql_query(
        f"SELECT COUNT(*) FROM sync_pull_cursors WHERE user_id={user_id} AND device_id='stale-dev'")
    check("过期游标行已删", stale_left == "0", stale_left)

    # 10) 级联清理测试账号
    mysql_query(f"DELETE FROM users WHERE id={user_id}")
    left_items = mysql_query(
        f"SELECT COUNT(*) FROM sync_items WHERE user_id={user_id}")
    left_cursors = mysql_query(
        f"SELECT COUNT(*) FROM sync_pull_cursors WHERE user_id={user_id}")
    check("级联清理（items/cursors 归零）", left_items == "0" and left_cursors == "0",
          (left_items, left_cursors))

    print()
    if fails:
        print(f"FAILURES: {fails}")
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    import urllib.parse  # noqa: E402  (parse 在 pull() 里用)
    main()
