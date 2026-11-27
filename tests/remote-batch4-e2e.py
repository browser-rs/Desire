#!/usr/bin/env python3
"""Remote 控制帧（v0.8.80 批 4）的桥 E2E：走 `/remote/dispatch` 把内层帧
送进真实分发器，并检查回帧与真实状态。

覆盖：产物（列表/读取，P0 改走控制帧）、实时标签（列表/切换/关闭/分组）、
体检、同步健康、适配器、批量下载与下载记录帧；标签动作以 `/state` 对账。

前置：封闭实例在前台（标签动作要真实 TabManager）。
用法：python3 tests/remote-batch4-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import time
import urllib.request

checks = []
TAG = str(int(time.time()) % 1000000)


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def dispatch(base, frame):
    body = br(base, "POST", "/remote/dispatch", {"json": json.dumps(frame)})
    return body.get("frames") or []


def frame_of(frames, kind):
    return next((f for f in frames if f.get("t") == kind), None)


def state(base):
    return br(base, "GET", "/state")


def wait_tabs(base, count, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = state(base)
        if len(st.get("tabs") or []) >= count:
            return st
        time.sleep(0.3)
    return state(base)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    st = state(base)
    startup = st.get("startup") or {}
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    ok("实例在前台（标签动作需要真实窗口）", st.get("isActive") is True, "先 osascript activate")

    group_name = f"remote-b4-{TAG}"
    try:
        # 至少三个标签，切换/关闭都不碰最后一页
        for _ in range(3):
            if len((state(base).get("tabs") or [])) >= 3:
                break
            br(base, "POST", "/new-tab", {"url": "about:blank"})
            time.sleep(0.4)
        st = wait_tabs(base, 3)
        ok("准备：至少三个标签", len(st.get("tabs") or []) >= 3, str(len(st.get("tabs") or [])))

        # ---- 实时标签帧 ----
        tabs_frame = frame_of(dispatch(base, {"t": "tabs"}), "tabs")
        state_tabs = st.get("tabs") or []
        ok("标签帧：数量与 /state 一致、恰有一个选中",
           tabs_frame is not None
           and len(tabs_frame.get("tabs") or []) == len(state_tabs)
           and sum(1 for t in tabs_frame["tabs"] if t.get("selected")) == 1,
           json.dumps(tabs_frame or {}, ensure_ascii=False)[:300])
        ok("标签帧：窗口清单带 active",
           bool(tabs_frame) and any(w.get("active") for w in tabs_frame.get("windows") or []))

        # 切换到一个未选中的标签
        target = next((t for t in tabs_frame["tabs"] if not t.get("selected")), None)
        if target:
            frames = dispatch(base, {"t": "tabAction", "action": "select", "id": target["id"]})
            st2 = state(base)
            selected_index = st2.get("selected")
            selected = (st2.get("tabs") or [])[selected_index] if isinstance(selected_index, int) else {}
            updated = frame_of(frames, "tabs")
            ok("标签动作：切换到目标标签",
               updated is not None
               and any(t.get("id") == target["id"] and t.get("selected") for t in updated.get("tabs") or []),
               json.dumps(selected, ensure_ascii=False)[:200])
            before = len(st2.get("tabs") or [])
            dispatch(base, {"t": "tabAction", "action": "close", "id": target["id"]})
            after = len(state(base).get("tabs") or [])
            ok("标签动作：关闭后数量 -1", after == before - 1, f"{before} → {after}")
        else:
            ok("标签动作：切换到目标标签", False, "没有未选中标签")

        # 分组出现在帧里
        created = br(base, "POST", "/tabgroups/create", {"name": group_name, "index": 0})
        if created.get("ok") is not False:
            grouped = frame_of(dispatch(base, {"t": "tabs"}), "tabs")
            ok("标签帧：分组名称/颜色随帧下发",
               any(g.get("name") == group_name for g in (grouped or {}).get("groups") or []),
               json.dumps((grouped or {}).get("groups"), ensure_ascii=False)[:200])

        # ---- 产物：控制帧通道 ----
        art = frame_of(dispatch(base, {"t": "artifacts"}), "artifacts")
        ok("产物帧：ok/列表（不再直连中继 /artifacts）",
           art is not None and art.get("ok") is True and isinstance(art.get("artifacts"), list),
           json.dumps(art or {}, ensure_ascii=False)[:200])
        content = frame_of(dispatch(base, {"t": "artifactRead",
                                          "text": f"/tmp/not-an-artifact-{TAG}.bin"}),
                           "artifactContent")
        ok("产物读取帧：索引外路径被拒（白名单仍在 Mac 端）",
           content is not None and content.get("path", "").endswith(f"not-an-artifact-{TAG}.bin")
           and content.get("ok") is not True and bool(content.get("error")),
           json.dumps(content or {}, ensure_ascii=False)[:200])

        # ---- 体检 / 同步 / 适配器 ----
        doctor = frame_of(dispatch(base, {"t": "doctor"}), "doctor")
        ok("体检帧：逐项结果（passed/total 一致）",
           doctor is not None and doctor.get("total") == len(doctor.get("checks") or [])
           and 0 <= doctor.get("passed", -1) <= doctor.get("total", 0)
           and len(doctor.get("checks") or []) > 0,
           json.dumps(doctor or {}, ensure_ascii=False)[:300])
        sync = frame_of(dispatch(base, {"t": "syncHealth"}), "syncHealth")
        ok("同步帧：登录态/逐域/设备字段齐全",
           sync is not None and "signedIn" in sync
           and isinstance(sync.get("domains"), list)
           and isinstance(sync.get("devices"), list),
           json.dumps(sync or {}, ensure_ascii=False)[:300])
        adapters = frame_of(dispatch(base, {"t": "adapters"}), "adapters")
        ok("适配器帧：列表与加载错误",
           adapters is not None and isinstance(adapters.get("adapters"), list)
           and isinstance(adapters.get("loadErrors"), dict),
           json.dumps(adapters or {}, ensure_ascii=False)[:200])

        # ---- 批量下载 / 下载记录帧 ----
        batch = frame_of(dispatch(base, {"t": "batchDownloads"}), "batchDownloads")
        ok("批量下载帧：批次列表（可空）", batch is not None and isinstance(batch.get("batches"), list),
           json.dumps(batch or {}, ensure_ascii=False)[:200])
        history = frame_of(dispatch(base, {"t": "downloadHistory"}), "downloadHistory")
        ok("下载记录帧：站点/批次/总计",
           history is not None and isinstance(history.get("sites"), list)
           and isinstance(history.get("batches"), list)
           and isinstance(history.get("totals"), dict),
           json.dumps(history or {}, ensure_ascii=False)[:200])
        noop = dispatch(base, {"t": "batchAction", "action": "pause",
                               "id": "00000000-0000-0000-0000-000000000000"})
        ok("批量动作：未知批次不崩、仍回最新帧",
           frame_of(noop, "batchDownloads") is not None)
    finally:
        try:
            br(base, "POST", "/tabgroups/delete", {"name": group_name})
        except Exception:
            pass

    passed = sum(1 for _, cond in checks if cond)
    print("\nRemote 控制帧：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
