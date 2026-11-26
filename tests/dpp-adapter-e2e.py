#!/usr/bin/env python3
"""DPP 适配器导出的往返端到端（v0.8.79 批 3）：导入 → 导出（剥遥测）→ 重新导入 →
规则与协议体一致；顺带拍一张 Studio 下载规则表单的快照。

前置：封闭实例已启动（`tools/launch-hermetic.sh`）；存储/偏好/钥匙串三项隔离。
不依赖浏览器激活（只走适配器仓库与离屏快照）。

用法：python3 tests/dpp-adapter-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import os
import time
import urllib.request

checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_bridge(base, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return br(base, "GET", "/state", timeout=3)
        except Exception:
            time.sleep(0.4)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    state = wait_bridge(base)
    ok("桥可达", state is not None)
    if not state:
        return finish()
    startup = state.get("startup") or {}
    ok("封闭实例（存储/偏好/密钥三项隔离）",
       startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file",
       str(startup))
    data_dir = startup.get("dataDir")
    if not data_dir:
        return finish()

    tag = "b79x%d" % (int(time.time()) % 100000)
    name = "export-demo-" + tag
    work = os.path.join(data_dir, "..")
    fixture_path = os.path.abspath(os.path.join(work, "adapter-fixture-%s.json" % tag))
    export_path = os.path.abspath(os.path.join(work, "adapter-exported-%s.json" % tag))

    fixture = {
        "format": "desire/adapter-1",
        "name": name,
        "hosts": ["demo.example"],
        "pathPrefixes": ["/videos/"],
        "protocolBody": {
            "protocolVersion": "desire/1",
            "views": {"list": {"item": ".card", "fields": {
                "title": ".t",
                "link": {"selector": "a", "attr": "href", "type": "url"},
            }}},
        },
        "notes": "export round-trip fixture",
        "sourceURL": "/tmp/should-be-stripped.json",
        "download": {
            "detail": "regex:var hlsUrl\\s*=\\s*'([^']+)'",
            "perPage": "one",
            "engine": "parallel",
            "connections": 6,
            "tokenMinutes": 30,
            "exclude": ["_preview\\.mp4$"],
            "measured": {"singleBytesPerSecond": 1048576, "parallelBytesPerSecond": 9437184,
                         "connections": 8, "samples": 3, "lastMeasuredAt": 780000000},
            "lastMatchAt": 780000000,
            "lastError": "older failure",
            "consecutiveFailures": 2,
            "revisions": [{"at": 780000000, "change": "connections 8 -> 6"}],
        },
    }
    with open(fixture_path, "w", encoding="utf-8") as fh:
        json.dump(fixture, fh, ensure_ascii=False, indent=2)

    try:
        imported = br(base, "POST", "/dpp/adapters/import", {"path": fixture_path})
        ok("导入夹具", imported.get("ok") is True and imported.get("name") == name, str(imported))
        listing = br(base, "GET", "/dpp/adapters")
        row = next((a for a in listing.get("adapters", []) if a.get("name") == name), None)
        ok("适配器出现在清单里", row is not None and row.get("hosts") == ["demo.example"])

        exported = br(base, "POST", "/dpp/adapters/export", {"name": name, "path": export_path})
        ok("导出成功", exported.get("ok") is True and exported.get("bytes", 0) > 0, str(exported))
        ok("导出文件落地", os.path.isfile(export_path))

        with open(export_path, encoding="utf-8") as fh:
            package = json.load(fh)
        rules = package.get("download") or {}
        telemetry = [k for k in ("measured", "lastMatchAt", "lastFailureAt", "lastError",
                                 "consecutiveFailures", "revisions") if k in rules]
        ok("导出剥离遥测（实测/修订/最近命中失败）", telemetry == [], str(telemetry))
        ok("导出剥离本地溯源（sourceURL/installedAt）",
           "sourceURL" not in package and "installedAt" not in package)
        ok("导出保留规则",
           rules.get("detail") == fixture["download"]["detail"] and rules.get("perPage") == "one"
           and rules.get("engine") == "parallel" and rules.get("connections") == 6
           and rules.get("tokenMinutes") == 30 and rules.get("exclude") == fixture["download"]["exclude"],
           json.dumps({k: rules.get(k) for k in ("detail", "perPage", "engine", "connections")},
                      ensure_ascii=False))
        fields = (((package.get("protocolBody") or {}).get("views") or {}).get("list") or {}).get("fields") or {}
        ok("导出保留协议体（简写 + selector/attr 对象两种形态）",
           fields.get("title") == ".t"
           and isinstance(fields.get("link"), dict)
           and fields["link"].get("selector") == "a"
           and fields["link"].get("attr") == "href"
           and fields["link"].get("type") == "url", json.dumps(fields, ensure_ascii=False))

        br(base, "POST", "/dpp/adapters/remove", {"name": name})
        listing = br(base, "GET", "/dpp/adapters")
        ok("删除后清单里没有它", all(a.get("name") != name for a in listing.get("adapters", [])))

        reimported = br(base, "POST", "/dpp/adapters/import", {"path": export_path})
        ok("重新导入导出包", reimported.get("ok") is True, str(reimported))
        installed_path = os.path.join(data_dir, "DPPAdapters", name + ".json")
        ok("重新导入落盘", os.path.isfile(installed_path))
        if os.path.isfile(installed_path):
            with open(installed_path, encoding="utf-8") as fh:
                installed = json.load(fh)
            ok("往返：下载规则一致", installed.get("download") == package.get("download"))
            ok("往返：协议体一致", installed.get("protocolBody") == package.get("protocolBody"))
            warnings = (installed.get("protocolBody") or {}).get("warnings") or []
            ok("往返：来源戳不随加载次数增长",
               warnings.count("adapter: " + name) == 1, str(warnings))
            ok("往返：重新导入记下来源", installed.get("sourceURL", "").endswith(
                os.path.basename(export_path)) and "installedAt" in installed)

        snapshot = br(base, "GET", "/panel/snapshot?name=dppstudio", timeout=60)
        path = snapshot.get("path") or ""
        ok("Studio 快照拍出下载规则表单",
           snapshot.get("download") is True and os.path.isfile(path)
           and os.path.getsize(path) > 5000, str(snapshot))
    finally:
        try:
            br(base, "POST", "/dpp/adapters/remove", {"name": name})
        except Exception:
            pass
        for path in (fixture_path, export_path):
            try:
                os.remove(path)
            except OSError:
                pass

    return finish()


def finish():
    passed = sum(1 for _, cond in checks if cond)
    print("\n适配器导出端到端：%d/%d 通过" % (passed, len(checks)))
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
