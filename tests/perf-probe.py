#!/usr/bin/env python3
"""性能回归探针（v0.8.84 批 5 第 16 件）。

封闭实例上的确定性测量（全部走桥，不需要屏幕录制/辅助功能权限）：
  阶段 A（--fresh 冷启动）
    1. 冷启动（0 标签）：首窗毫秒 + 启动审计合计（审计预算 700ms）
    2. 大页面管道：30k 节点主框架 + 3 iframe → /state 的 domNodes 必须
       落在主框架口径（iframe 报告覆盖会把计数冲掉）
    3. 导航守卫：无监听器导航 skip 计数增长（零 JS 收益面）；页面内联
       注册 beforeunload 后再导航 → probe 计数增长（保护面，页面自身
       内联脚本跑在 page world，能看到 beforeunload-watch 装的钩子）
    4. 内存压力模拟：warning 后 governor load == paused、下载并发归零
       （模拟是单向置位，本阶段放最后，重启即复位）
  阶段 B（41 标签恢复）
    5. 40 个 about:blank 标签 + 优雅退出 + 同 dataDir 重启：restoreTabs
       计时 + 懒建意外建必须为 0（意外建 >0 = 启动/遍历路径违规触碰挂起标签）

阈值存 tests/perf-baseline.json（**Release 口径**——launch-hermetic 固定跑
Debug 产物，Debug 数字超阈只打 WARN 不判失败；`--strict` 才按阈值判）。
发版 checklist 在 Release clean 构建后跑本脚本；CI 不跑（应用无法激活）。

用法：python3 tests/perf-probe.py [--strict]
前置：tools/launch-hermetic.sh（脚本自管旧实例收尾与清理）。
"""

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = "http://127.0.0.1:8799"
BASELINE = json.loads((ROOT / "tests" / "perf-baseline.json").read_text())


def http(method, url, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if body else {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw else {}


def bridge(method, path, body=None, timeout=60):
    return http(method, BRIDGE + path, body, timeout)


def wait_bridge(timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return bridge("GET", "/state", timeout=2)
        except Exception:
            time.sleep(0.4)
    raise RuntimeError("bridge did not come up")


def launch(data_dir):
    # --activate：浏览器端点只在激活实例可用；firstWindowMs 的口径也以
    # 前台启动为准（后台启动会把首窗时间污染成 heal 路径）。
    subprocess.run([str(ROOT / "tools/launch-hermetic.sh"), data_dir, "--activate"],
                   check=True, stdout=subprocess.DEVNULL)
    return wait_bridge()


def quit_app():
    try:
        bridge("POST", "/app/quit", {}, timeout=5)
    except Exception:
        pass
    time.sleep(3)


def big_page_fixture(workdir):
    """30k 主框架节点 + 3 个 iframe（iframe 不注入 pagePerf——
    forMainFrameOnly；本探针验证端到端"主框架计数落地且未被覆盖"。"""
    html = ("<!DOCTYPE html><html><body><script>document.title='PERF-BIG';</script>"
            + "".join(f"<div class='n{i}'>x</div>" for i in range(30000))
            + "<iframe src='about:blank'></iframe>" * 3
            + "</body></html>")
    p = pathlib.Path(workdir) / "big.html"
    p.write_text(html)
    return p.as_uri()


def beforeunload_fixture(workdir):
    """页面内联脚本注册 beforeunload（page world）→ 下一次导航走合成探针。"""
    html = ("<!DOCTYPE html><html><body><script>"
            "document.title='PERF-UNLOAD';"
            "window.addEventListener('beforeunload', function(){});"
            "</script>unload fixture</body></html>")
    p = pathlib.Path(workdir) / "unload.html"
    p.write_text(html)
    return p.as_uri()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true",
                        help="Debug 产物也按阈值判失败（默认只 WARN）")
    args = parser.parse_args()

    checks = []          # (name, ok)
    thresholds = []      # (name, value, threshold) Debug-WARN 候选

    def threshold(name, value, key, lower_is_better=True):
        t = BASELINE.get(key)
        if t is None:
            checks.append((f"{name}（基线缺 {key}）", False))
            return
        thresholds.append((name, value, t, lower_is_better))

    workdir = tempfile.mkdtemp(prefix="perf-probe-")
    data_dir = tempfile.mkdtemp(prefix="perf-probe-data-")
    try:
        # ── 阶段 A：冷启动 ──
        launch(data_dir)
        time.sleep(4)
        d = bridge("GET", "/diag/startup")
        audit = d.get("launchAudit") or {}
        first_ms = d.get("firstWindowMs") or 0
        audit_ms = audit.get("totalMs") or 0
        print(f"冷启动: 首窗 {first_ms}ms, 审计 {audit_ms}ms "
              f"(预算 {audit.get('budgetMs')}ms)")
        threshold("冷启动首窗 ms", first_ms, "coldFirstWindowMs")
        threshold("冷启动审计 ms", audit_ms, "coldAuditMs")
        # 审计预算是 Release 口径（LaunchAudit.budgetMs=700）——Debug 产物
        # 慢于 Release，超预算在这里只随 threshold() 走 WARN，--strict 才判。

        # 大页面管道（iframe 不覆盖主框架计数）
        probe_before = (d.get("navGuard") or {}).get("probes") or 0
        skip_before = (d.get("navGuard") or {}).get("skipped") or 0
        bridge("POST", "/navigate", {"url": big_page_fixture(workdir)}, timeout=30)
        time.sleep(2)
        st = bridge("GET", "/state")
        nodes = (st.get("tabs") or [{}])[st.get("selected", 0)].get("domNodes") or 0
        print(f"大页面 domNodes: {nodes}")
        checks.append((f"主框架计数落地（{nodes} ∈ "
                       f"[{BASELINE['bigPageDomNodesMin']}, {BASELINE['bigPageDomNodesMax']}]）",
                       BASELINE["bigPageDomNodesMin"] <= nodes <= BASELINE["bigPageDomNodesMax"]))

        # beforeunload 探针路径：带监听器页面 → 离开 → probes 增长
        bridge("POST", "/navigate", {"url": beforeunload_fixture(workdir)}, timeout=30)
        time.sleep(1.5)
        bridge("POST", "/navigate", {"url": "about:blank"}, timeout=30)
        time.sleep(1.5)
        d = bridge("GET", "/diag/startup")
        probe_after = (d.get("navGuard") or {}).get("probes") or 0
        skip_after = (d.get("navGuard") or {}).get("skipped") or 0
        print(f"导航守卫: probes +{probe_after - probe_before}, "
              f"skipped +{skip_after - skip_before}")
        checks.append((f"带监听器导航走探针（probes +{probe_after - probe_before} ≥1）",
                       probe_after > probe_before))
        checks.append((f"无监听器导航零 JS（skipped +{skip_after - skip_before} ≥1）",
                       skip_after > skip_before))

        # 内存压力模拟（单向置位——放本阶段最后，重启复位）
        bridge("POST", "/diag/memory-pressure", {"level": "warning"})
        time.sleep(1)
        g = bridge("GET", "/diag/resource-governor")
        print(f"压力模拟: load={g.get('load')}, "
              f"downloadConcurrency@4={g.get('downloadConcurrencyAt4')}")
        checks.append((f"压力 warning → paused（got {g.get('load')}）",
                       g.get("load") == "paused"))
        checks.append(("下载并发归零", (g.get("downloadConcurrencyAt4") or 0) == 0))

        # ── 40 标签 + 优雅退出 ──
        for _ in range(40):
            bridge("POST", "/new-tab", {"url": "about:blank"}, timeout=15)
        quit_app()

        # ── 阶段 B：41 标签恢复 ──
        launch(data_dir)
        time.sleep(6)
        d = bridge("GET", "/diag/startup")
        rt = d.get("restoreTabs") or {}
        lw = d.get("lazyWebViews") or {}
        print(f"恢复: tabs={rt.get('tabs')}, ms={rt.get('ms')}, "
              f"懒建 {lw.get('created')} 个, 意外建 {lw.get('unexpected')} 个")
        checks.append((f"恢复标签数 == 41（got {rt.get('tabs')}）",
                       rt.get("tabs") == 41))
        threshold("恢复装载 ms", rt.get("ms") or 0, "restoreApplyMs")
        checks.append(("懒建意外建必须为 0", (lw.get("unexpected") or 0) == 0))
        quit_app()

        # Debug-WARN 判定（Release 口径基线，Debug 超阈只提示）
        hard_fail = False
        for name, ok in checks:
            if not ok:
                hard_fail = True
        if not hard_fail:
            for name, value, t, lower in thresholds:
                over = value > t if lower else value < t
                if over:
                    if args.strict:
                        checks.append((f"{name}: {value} > {t}", False))
                        hard_fail = True
                    else:
                        print(f"⚠ WARN {name}: {value} 超基线 {t}"
                              f"（Debug 口径，Release 闸门以 --strict 复核）")
    finally:
        quit_app()
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(data_dir, ignore_errors=True)

    failed = [name for name, ok in checks if not ok]
    mode = "strict" if args.strict else "Debug-WARN"
    print(f"\nperf-probe：{len(checks) - len(failed)}/{len(checks)} 通过（{mode}）")
    for name in failed:
        print("  ✗", name)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
