"""会话激活自检（共享 helper，2026-11-19 终版）。

浏览器端点依赖 NSApp.isActive——后台自动化实例（用户在用别的 app）时
navigate 等静默失效、页面不加载（CI 教训的本地同源）。探针直接读桥
/state 的 isActive（最准；System Events frontmost 查询在该场景会误报）。
"""

import json
import urllib.request

# 显式禁代理：桥是 127.0.0.1，代理会拦本地回环。
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def is_app_active(base_url: str, timeout: int = 10) -> bool:
    """读桥 /state 的 isActive。桥不可达时抛网络异常（由调用方决定语义）。"""
    req = urllib.request.Request(base_url.rstrip("/") + "/state")
    with opener.open(req, timeout=timeout) as resp:
        return bool(json.loads(resp.read().decode()).get("isActive"))


def ensure_active(base_url: str, timeout: int = 10) -> None:
    """浏览器依赖用例的入口闸：非前台即抛 RuntimeError 并给恢复指引。"""
    if not is_app_active(base_url, timeout=timeout):
        raise RuntimeError(
            "激活自检失败：Desire 不在前台（isActive=false）——浏览器端点将静默失效。"
            "恢复：osascript -e 'tell application \"Desire\" to activate' 或点击 Desire 窗口后重试")
