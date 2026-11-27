#!/usr/bin/env python3
"""v0.8.81 批 4 端到端（Remote 控制帧）：

1) 标签：新建 → tabs 帧多一条；建组 → toggleGroup 折叠；清理。
2) 批量下载：手机发 start（URL 列表 + 时段窗口）→ Mac 出现批次；
   窗口未开 → 立即 paused；取消。
3) ack 诊断：/remote/status 暴露 ackedFrames / pendingAck / lastAckAt
   （未登录时允许为 0，只证明字段已接线）。

前置：封闭实例 + 前台/有标签。用法：
python3 tests/batch4-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import time
import urllib.request

checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def dispatch(base, inner):
    return br(base, "POST", "/remote/dispatch", {"json": json.dumps(inner)})


def frame_of(base, inner, name):
    result = dispatch(base, inner)
    return next((f for f in (result.get("frames") or []) if f.get("t") == name), None), result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base
    startup = (br(base, "GET", "/state").get("startup") or {})
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    tabs_before = len(br(base, "GET", "/state").get("tabs") or [])
    ok("实例有标签页（工具需要活动窗口）", tabs_before >= 1, str(tabs_before))

    batch_id = None
    group_name = "b4-probe-group"
    try:
        # 1. 新建标签 + 组折叠
        tabs_frame, _ = frame_of(base, {"t": "tabAction", "action": "new", "text": ""}, "tabs")
        tabs = (tabs_frame or {}).get("tabs") or []
        ok("标签：手机新建标签后 tabs 帧多一条", len(tabs) == tabs_before + 1,
           f"{tabs_before} -> {len(tabs)}")
        new_tab = next((t for t in tabs if not t.get("selected")), None)
        created = br(base, "POST", "/tabgroups/create",
                     {"name": group_name, "index": 1})
        groups = br(base, "GET", "/tabgroups").get("groups") or []
        group = next((g for g in groups if g.get("name") == group_name), None)
        ok("标签组：桥创建分组", created.get("ok") is True and group is not None,
           str(created)[:160])
        if group:
            dispatch(base, {"t": "tabAction", "action": "toggleGroup",
                            "text": group.get("id") or group_name})
            groups2 = br(base, "GET", "/tabgroups").get("groups") or []
            g2 = next((g for g in groups2 if g.get("name") == group_name), {})
            ok("标签组：手机 toggleGroup 折叠生效", g2.get("collapsed") is True,
               json.dumps(g2, ensure_ascii=False)[:200])

        # 2. 手机发起批量下载 + 时段窗口
        spec = {
            "urls": ["http://127.0.0.1:1/b4"],
            "folder": "b4-probe-batch",
            "connections": 2,
            "windowStart": "22:00", "windowEnd": "06:00",
            "maxMinutes": 30, "maxConcurrent": 2,
        }
        frame_of(base, {"t": "batchAction", "action": "start",
                        "body": json.dumps(spec)}, "batchDownloads")
        batches = br(base, "GET", "/media/batch").get("batches") or []
        batch = next((b for b in batches if b.get("folder") == "b4-probe-batch"), None)
        batch_id = batch.get("id") if batch else None
        window = (batch or {}).get("window") or {}
        ok("批量下载：手机 start 创建批次并带时段窗口",
           batch is not None and window.get("start") == "22:00"
           and window.get("end") == "06:00" and window.get("maxConcurrent") == 2,
           json.dumps(batch, ensure_ascii=False)[:350])
        ok("批量下载：窗口未开 → 批次立即暂停", batch is not None and batch.get("paused") is True,
           str((batch or {}).get("paused")))

        # 3. ack 诊断字段
        status = br(base, "GET", "/remote/status")
        ok("ack：/remote/status 暴露回执诊断",
           "ackedFrames" in status and "pendingAck" in status and "lastAckAt" in status,
           json.dumps({k: status.get(k) for k in ("ackedFrames", "pendingAck", "lastAckAt")},
                      ensure_ascii=False))
    finally:
        try:
            if batch_id:
                br(base, "POST", "/media/batch/manage",
                   {"action": "cancel", "batchId": batch_id})
            br(base, "POST", "/tabgroups/delete", {"name": group_name})
            # 关掉本测试新建的标签（按 URL 空 + 非选中识别）
            tabs = br(base, "GET", "/state").get("tabs") or []
            for tab in tabs:
                if not tab.get("selected") and not (tab.get("url") or ""):
                    dispatch(base, {"t": "tabAction", "action": "close", "id": tab["id"]})
        except Exception:
            pass

    passed = sum(1 for _, cond in checks if cond)
    print("\nv0.8.81 批 4：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
