#!/usr/bin/env python3
"""Desire soak driver (0.3.4): opens N tabs against the local test server,
samples RSS/memory-pressure, then closes everything and writes a JSON report.

Usage:
  python3 tools/soak.py --tabs 50 --minutes 10 [--report /tmp/soak.json]

Requires the app running with --automation (bridge on 8799) and the test
server on 8877.
"""
import argparse, json, subprocess, time, urllib.request

BRIDGE = "http://127.0.0.1:8799"

def post(path, payload=None):
    req = urllib.request.Request(BRIDGE + path, data=json.dumps(payload or {}).encode(), method="POST")
    return json.load(urllib.request.urlopen(req, timeout=30))

def get(path):
    return json.load(urllib.request.urlopen(BRIDGE + path, timeout=30))

def rss_kb():
    out = subprocess.check_output(["ps", "-o", "rss=", "-p", subprocess.check_output(["pgrep", "-x", "Desire"]).split()[0].decode()])
    return int(out.split()[0])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tabs", type=int, default=50)
    ap.add_argument("--minutes", type=int, default=10)
    ap.add_argument("--sample-interval", type=int, default=30)
    ap.add_argument("--report", default="/tmp/desire-soak.json")
    args = ap.parse_args()

    report = {"started": time.strftime("%FT%T"), "tabs": args.tabs,
              "planned_minutes": args.minutes, "samples": [], "events": []}

    # 收敛到 1 个标签
    while len(get("/state")["tabs"]) > 1:
        post("/close-tab", {"index": 0})

    t0 = time.time()
    for i in range(args.tabs):
        post("/new-tab", {"url": f"http://127.0.0.1:8877/soak-{i}"})
    report["events"].append({"t": round(time.time()-t0, 1), "what": "opened", "n": args.tabs})

    samples = report["samples"]
    end = time.time() + args.minutes * 60
    # 巡检切换：每轮把选中标签顺序走一遍（模拟真实使用）
    round_ = 0
    while time.time() < end:
        n = len(get("/state")["tabs"])
        idx = round_ % n
        post("/switch-tab", {"index": idx})
        samples.append({"t": round(time.time()-t0, 1), "rss_kb": rss_kb(),
                        "tabs": n, "selected": idx})
        round_ += 1
        time.sleep(args.sample_interval)

    # 关闭风暴
    t1 = time.time()
    while len(get("/state")["tabs"]) > 1:
        post("/close-tab", {"index": 0})
    report["events"].append({"t": round(time.time()-t1, 1), "what": "close-storm-s"})
    report["final_rss_kb"] = rss_kb()
    report["ended"] = time.strftime("%FT%T")

    rss = [s["rss_kb"] for s in samples]
    report["rss_summary"] = {
        "start_kb": rss[0] if rss else None,
        "end_kb": rss[-1] if rss else None,
        "max_kb": max(rss) if rss else None,
        "growth_kb": (rss[-1] - rss[0]) if len(rss) > 1 else 0,
    }
    with open(args.report, "w") as f:
        json.dump(report, f, indent=2)
    print(json.dumps(report["rss_summary"], indent=2))
    print("report:", args.report)

if __name__ == "__main__":
    main()
