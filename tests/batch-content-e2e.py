#!/usr/bin/env python3
"""正片识别端到端（v0.8.77 批 1）：本地测试站点三种详情页 → `listPageVideos` 回执与
`downloadVideoList` 的任务表都必须是"排除杂项后的准确正片集合"。

前置：
- 应用以 tools/launch-hermetic.sh 启动（存储/偏好/钥匙串三项隔离——本脚本会装带 Key
  的假档案、往隔离数据目录里下载测试片），且**在前台**（隐藏解析器要创建 WKWebView，
  未激活的进程里会阻塞）。不在前台会直接退出，不会抢焦点。
- 本机有 ffmpeg（测试站点启动时现生成 HLS 素材）。

用法：python3 tests/batch-content-e2e.py [--base http://127.0.0.1:8799]
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SITE_PORT = 8895
MODEL_PORT = 8896
checks = []


def ok(label, cond, detail=""):
    checks.append((label, bool(cond)))
    print(("✓ " if cond else "✗ ") + label + ("" if cond or not detail else f" — {detail}"))


def br(base, method, path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


class Model(BaseHTTPRequestHandler):
    """假模型：用户消息 → listPageVideos；工具结果 → 结束。旁路调用一律 500。"""
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _sse(self, chunks):
        payload = b"".join(f"data: {json.dumps(c)}\n\n".encode() for c in chunks) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        request = json.loads(self.rfile.read(length) or b"{}")
        messages = request.get("messages") or []
        last = messages[-1] if messages else {}
        if not request.get("tools"):
            self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        def chunk(delta, finish=None):
            return {"id": "cmpl-b77", "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": "b77-fixture", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}

        if last.get("role") == "user":
            call = {"index": 0, "id": "call_list_videos", "type": "function",
                    "function": {"name": "listPageVideos", "arguments": "{}"}}
            self._sse([chunk({"role": "assistant", "tool_calls": [call]}), chunk({}, "tool_calls")])
        else:
            self._sse([chunk({"role": "assistant", "content": "BATCH-LIST-DONE"}), chunk({}, "stop")])


def wait_turn(base):
    deadline = time.time() + 120
    while time.time() < deadline:
        state = br(base, "GET", "/agent/messages")
        text = json.dumps(state, ensure_ascii=False)
        if "BATCH-LIST-DONE" in text and not state.get("busy"):
            return state.get("messages", [])
        time.sleep(0.5)
    raise TimeoutError("listPageVideos 回合超时")


def tool_result(messages, marker):
    for message in messages:
        if message.get("role") == "tool" and marker in (message.get("content") or ""):
            return message.get("content") or ""
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:8799")
    args = parser.parse_args()
    base = args.base

    state = br(base, "GET", "/state")
    startup = state.get("startup") or {}
    if not (startup.get("dataDir") and startup.get("prefs") == "isolated" and startup.get("secrets") == "file"):
        print("✗ 需要封闭实例（dataDir / prefs=isolated / secrets=file）——用 tools/launch-hermetic.sh 启动")
        return 2
    if not state.get("isActive"):
        print("✗ 实例不在前台：隐藏解析器要创建 WKWebView，未激活的进程里会阻塞。"
              "把测试实例切到前台再跑（本脚本不会自己抢焦点）。")
        return 3
    data_dir = startup["dataDir"]
    site_base = f"http://127.0.0.1:{SITE_PORT}"

    # 端口上已经有本夹具在跑（手工起的、留着调试用）就复用；否则自己起一个、跑完收掉。
    site = None
    try:
        br(site_base, "GET", "/stats", timeout=2)
    except Exception:
        site = subprocess.Popen([sys.executable, os.path.join(HERE, "fixtures", "batch-site-server.py"), str(SITE_PORT)],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    model = ThreadingHTTPServer(("127.0.0.1", MODEL_PORT), Model)
    import threading
    threading.Thread(target=model.serve_forever, daemon=True).start()
    profile_id = None
    conversation_ids = set()
    batch_id = None
    adapter_installed = False
    try:
        if site is not None:
            info = json.loads(site.stdout.readline())
            print(f"测试站点就绪：{site_base}（素材 {info['root']}）")
        else:
            print(f"测试站点复用：{site_base}")
        br(site_base, "GET", "/_reset", timeout=10)   # 过期状态与请求计数从头算

        created = br(base, "POST", "/ai/profiles", {
            "name": "b77-fixture", "endpoint": f"http://127.0.0.1:{MODEL_PORT}/v1/chat/completions",
            "model": "b77-fixture", "key": "b77-fake-key"})
        profile_id = created["id"]
        br(base, "POST", "/ai/profiles/activate", {"id": profile_id})
        assert br(base, "GET", "/ai/profiles").get("active") == profile_id
        br(base, "POST", "/agent/send", {"text": "/access full"})
        time.sleep(2)

        expectations = {
            "/videos/aaa-001/": {
                "title": "单视频 + 杂项",
                "content": ["1 content video", "/hls/aaa/index.m3u8"],
                "excluded": ["HLS segment of index", "preview/thumbnail", "ad "],
                "must_not": ["zzz_preview", "/ads/", "seg-000", "thumb.ts"],
            },
            # 这个工具只看得见**已加载**的播放器：懒加载页此刻只有第 1 部起了播。
            # 三部齐全由下面的批量下载路径（隐藏解析器会滚动收集）断言。
            "/videos/bbb-002/": {
                "title": "多视频（滚动才加载）——工具快照",
                "content": ["content video", "/hls/bbb-ep1/index.m3u8", "scroll so they load"],
                "excluded": ["preview/thumbnail"],
                "must_not": ["ccc-720p.mp4", "zzz_preview", "seg-000"],
            },
            "/videos/ccc-003/": {
                "title": "单视频 + 预览噪声",
                "content": ["1 content video", "/hls/ccc/index.m3u8"],
                "excluded": ["HLS segment of index", "preview/thumbnail"],
                "must_not": ["zzz_preview", "seg-000"],
            },
        }
        for path, want in expectations.items():
            br(base, "POST", "/navigate", {"url": site_base + path})
            time.sleep(2.5)
            br(base, "POST", "/agent/new", {})
            time.sleep(1)
            br(base, "POST", "/agent/send", {"text": "BATCHSITE 列出这个页面的视频"})
            messages = wait_turn(base)
            trace = br(base, "GET", "/agent/trace")
            if trace.get("conversation"):
                conversation_ids.add(trace["conversation"])
            result = tool_result(messages, "content video")
            ok(f"{want['title']}：listPageVideos 有正片清单", bool(result), json.dumps(messages[-3:], ensure_ascii=False)[:300])
            for needle in want["content"]:
                ok(f"{want['title']}：含 {needle}", needle in result, result[:400])
            for needle in want["excluded"]:
                ok(f"{want['title']}：排除清单含「{needle}」", needle in result, result[:600])
            for needle in want["must_not"]:
                ok(f"{want['title']}：正片里没有 {needle}", needle not in result.split("Excluded")[0], result[:400])

        # ---- 站点规则（v0.8.77 批 2）：带 download 段的适配器只管它声明的路径 ----
        adapter = {
            "format": "desire/adapter-1",
            "name": "fixture-site",
            "hosts": ["127.0.0.1"],
            "pathPrefixes": ["/videos/aaa-001/", "/videos/ccc-003/", "/videos/ddd-004/", "/videos/eee-005/"],
            "notes": "e2e fixture",
            "protocolBody": {"protocolVersion": "desire/1"},
            "download": {"detail": "regex:var hlsUrl\\s*=\\s*'([^']+)'", "perPage": "one",
                         "connections": 4, "tokenMinutes": 50},
        }
        adapter_path = os.path.join(data_dir, "fixture-adapter.json")
        with open(adapter_path, "w", encoding="utf-8") as handle:
            json.dump(adapter, handle, ensure_ascii=False, indent=2)
        # 原名位置上先放一份"别的技能"（实测形态：智能体在任务里自己存的同名站点技能，
        # 写着"绝不要用批量下载"）——同步出来的说明性技能**绝不覆盖**它，另找落点。
        skills_dir = os.path.join(data_dir, "skills")
        os.makedirs(skills_dir, exist_ok=True)
        foreign = os.path.join(skills_dir, "127-0-0-1-download.md")
        foreign_text = ("---\nname: 127-0-0-1-download\ndescription: 别人写的站点技能\n---\n"
                        "这个站点绝不要用批量下载，自己写脚本。\n")
        with open(foreign, "w", encoding="utf-8") as handle:
            handle.write(foreign_text)
        imported = br(base, "POST", "/dpp/adapters/import", {"path": adapter_path})
        adapter_installed = True
        entry = next((a for a in br(base, "GET", "/dpp/adapters").get("adapters", [])
                      if a.get("name") == "fixture-site"), None)
        ok("适配器导入并启用", bool(entry) and entry.get("enabled") is True,
           json.dumps(imported, ensure_ascii=False)[:120] + " | " + json.dumps(entry, ensure_ascii=False)[:200])

        # ---- 批量：五个详情页 ----
        #   aaa：规则命中（1 条）· bbb：无规则 → 通用识别（3 条）· ccc：规则命中
        #   ddd：规则落空 → 回退通用识别（1 条）· eee：规则命中，但分片先 403 →
        #   重新解析 → 从已抓到的分片续传
        started = br(base, "POST", "/media/batch", {
            "mode": "list",
            "urls": [site_base + p for p in
                     ["/videos/aaa-001/", "/videos/bbb-002/", "/videos/ccc-003/", "/videos/ddd-004/", "/videos/eee-005/"]],
            "directory": os.path.join(data_dir, "batch-out")})
        ok("批量已启动", "batchId" in started, json.dumps(started, ensure_ascii=False))
        batch_id = started.get("batchId")
        deadline = time.time() + 240
        snapshot = None
        # 等批次整体结束：单条的 failed 不算完——地址中途过期的那条会在十几秒后重新解析续传。
        while batch_id and time.time() < deadline:
            batches = br(base, "GET", f"/media/batch?id={batch_id}").get("batches", [])
            snapshot = batches[0] if batches else None
            if snapshot and snapshot.get("state") in ("finished", "cancelled"):
                break
            time.sleep(1)
        items = (snapshot or {}).get("items", [])
        by_state = {}
        for item in items:
            by_state.setdefault(item.get("state"), []).append(item)
        ok("批量任务表 = 7 条正片（1 + 3 + 1 + 1 + 1）", len(items) == 7,
           json.dumps([(i.get("title"), i.get("state")) for i in items], ensure_ascii=False)[:700])
        expected = sorted(f"{site_base}{p}" for p in
                          ["/hls/aaa/index.m3u8", "/hls/bbb-ep1/index.m3u8", "/hls/bbb-ep2/index.m3u8",
                           "/clips/ccc-1080p.mp4", "/hls/ccc/index.m3u8", "/clips/ccc-720p.mp4",
                           "/expire/hls/aaa/index.m3u8"])
        medias = sorted(i.get("media", "") for i in items)
        ok("每条任务指向正片（没有分片/预览/广告）", medias == expected, str(medias))
        titles = [i.get("title", "") for i in items]
        ok("多视频页展开成 02 / 02-2 / 02-3",
           any(t.startswith("02-2-") for t in titles) and any(t.startswith("02-3-") for t in titles), str(titles))
        ok("七条全部下载完成（含中途过期后续传的那一条）",
           len(by_state.get("finished", [])) == 7,
           json.dumps({k: [(i.get("title"), i.get("summary")) for i in v] for k, v in by_state.items()}, ensure_ascii=False)[:900])

        log = br(base, "GET", f"/media/batch/log?id={batch_id}")
        log_text = json.dumps(log, ensure_ascii=False)
        ok("批次日志写明排除了什么", "已排除" in log_text and "条正片" in log_text, log_text[:300])
        ok("批次日志：站点规则命中（aaa / ccc / eee）", log_text.count("站点规则「fixture-site」提取到") >= 3, log_text[-900:])
        ok("批次日志：规则落空时回退通用识别（ddd）", "提取不到，已回退通用识别" in log_text, log_text[-900:])
        ok("批次日志：地址中途过期后重新解析续传（eee）", "地址中途过期" in log_text, log_text[-900:])
        # 研判与测速（v0.8.77 批 6）：每个任务一行"研判"（事实 → 引擎），做过测速的再一行"测速"。
        ok("批次日志：每个下载写了研判", log_text.count("研判：") >= 7, log_text[-1200:])
        ok("批次日志：并发下载写了测速结论", log_text.count("测速：") >= 4, log_text[-1200:])

        # ---- 打磨回写（规则"不停打磨"）----
        adapter_file = os.path.join(data_dir, "DPPAdapters", "fixture-site.json")
        refined = json.load(open(adapter_file, encoding="utf-8")) if os.path.exists(adapter_file) else {}
        download = refined.get("download") or {}
        ok("过期一次后有效期自动缩短 50 → 30", download.get("tokenMinutes") == 30, json.dumps(download, ensure_ascii=False)[:300])
        ok("修订记录留痕", bool(download.get("revisions")) and "tokenMinutes 50 → 30" in download["revisions"][0]["change"],
           json.dumps(download.get("revisions"), ensure_ascii=False)[:200])
        ok("覆盖前的旧版有备份",
           any(f.startswith("fixture-site-") for f in os.listdir(os.path.join(data_dir, "dpp-adapter-backups")))
           if os.path.isdir(os.path.join(data_dir, "dpp-adapter-backups")) else False)

        # ---- 续传的证据：已抓到的分片没有重抓 ----
        stats = br(site_base, "GET", "/stats", timeout=10)
        hits = stats.get("hits", {})
        ok("续传：过期前抓到的分片只请求过 1 次", hits.get("/expire/hls/aaa/seg-000.ts") == 1, json.dumps(
            {k: v for k, v in hits.items() if "/expire/" in k}, ensure_ascii=False))
        ok("续传：过期时 403 的分片在重新解析后补抓（403 一次 + 成功一次）",
           hits.get("/expire/hls/aaa/seg-005.ts") == 2, json.dumps({k: v for k, v in hits.items() if "/expire/" in k}))
        ok("续传：播放列表在过期之后被重新取过（拿到新签名）", stats.get("expireRefreshes") == 1
           and hits.get("/expire/hls/aaa/index.m3u8", 0) >= 2, json.dumps({k: v for k, v in stats.items() if k != "hits"}))
        # 开头的测速那一轮也会抓到尾部两个分片（提前吃到 403），所以次数是 2–4 次而不是严格的 2 次；
        # 要断言的是"过期过、重新解析后补抓了、没有反复重试"。
        ok("续传：尾部三个分片都补抓了、且没有反复重试",
           all(2 <= hits.get(f"/expire/hls/aaa/seg-00{n}.ts", 0) <= 4 for n in (3, 4, 5)),
           json.dumps({k: v for k, v in hits.items() if "/expire/" in k}))

        # ---- 说明性技能随适配器同步；适配器删除后撤掉。原名被占 → 落在 -site 上 ----
        skill = os.path.join(data_dir, "skills", "127-0-0-1-download-site.md")
        skill_text = open(skill, encoding="utf-8").read() if os.path.exists(skill) else ""
        ok("技能同步：生成了该站点的说明性技能", "synced from DPP adapter download rules" in skill_text, skill_text[:200])
        ok("技能同步：只说怎么做，不写提取细节",
           "downloadVideoList" in skill_text and "var hlsUrl" not in skill_text, skill_text[:400])
        ok("技能同步：落点名字与正文 name 一致",
           "name: 127-0-0-1-download-site\n" in skill_text, skill_text[:120])
        foreign_now = open(foreign, encoding="utf-8").read() if os.path.exists(foreign) else ""
        ok("技能同步：同名位置上别的技能原样保留（不覆盖）", foreign_now == foreign_text, foreign_now[:200])
        br(base, "POST", "/dpp/adapters/remove", {"name": "fixture-site"})
        time.sleep(1.5)
        ok("技能同步：适配器删除后技能随之撤掉", not os.path.exists(skill))
        foreign_after = open(foreign, encoding="utf-8").read() if os.path.exists(foreign) else ""
        ok("技能同步：撤回只动自己写的那份", foreign_after == foreign_text, foreign_after[:200])
    finally:
        if batch_id:
            try:
                br(base, "POST", "/media/batch/cancel", {"id": batch_id})
            except Exception:
                pass
        if profile_id:
            try:
                br(base, "POST", "/ai/profiles/delete", {"id": profile_id})
            except Exception:
                pass
        if conversation_ids:
            try:
                br(base, "POST", "/conversations/delete", {"ids": sorted(conversation_ids)})
            except Exception:
                pass
        model.shutdown()
        if adapter_installed:
            try:
                br(base, "POST", "/dpp/adapters/remove", {"name": "fixture-site"})
            except Exception:
                pass
        if site is not None:
            site.terminate()
            site.wait(timeout=10)

    passed = sum(1 for _, c in checks if c)
    print(f"\n正片识别端到端：{passed}/{len(checks)} 通过")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    sys.exit(main())
