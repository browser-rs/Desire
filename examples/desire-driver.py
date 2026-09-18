#!/usr/bin/env python3
"""Desire driver example (Python, stdlib only).

Drives Desire's automation bridge (http://127.0.0.1:8799) end to end:
navigate → wait for the pageReady SSE event → read text → download →
wait for downloadCompleted.

Run: DESIRE_TOKEN=<token?> python3 examples/desire-driver.py
Requires Desire launched with `--automation` (and the same
`--automation-token` if one is set).
"""

import json
import os
import threading
import time
import urllib.request

BASE = "http://127.0.0.1:8799"
TOKEN = os.environ.get("DESIRE_TOKEN")
HEADERS = {"Content-Type": "application/json"}
if TOKEN:
    HEADERS["Authorization"] = f"Bearer {TOKEN}"


def call(method: str, path: str, payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(BASE + path, data=body, headers=HEADERS, method=method)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode())


def listen_events(handler, seconds: float) -> None:
    """Consume the /events SSE stream on a thread."""
    request = urllib.request.Request(BASE + "/events", headers=HEADERS)
    response = urllib.request.urlopen(request, timeout=60)

    def pump():
        start = time.time()
        for raw in response:
            if time.time() - start > seconds:
                break
            line = raw.decode().strip()
            if line.startswith("data:"):
                handler(json.loads(line[5:]))

    threading.Thread(target=pump, daemon=True).start()


def wait_for_event(kind: str, seconds: float = 30) -> dict:
    """Subscribe, then resolve when an event of `kind` arrives."""
    found = threading.Event()
    payload_box: list[dict] = []

    def handler(event: dict):
        if event.get("kind") == kind and not found.is_set():
            payload_box.append(event)
            found.set()

    listen_events(handler, seconds)
    found.wait(timeout=seconds)
    return payload_box[0] if payload_box else {}


def main() -> None:
    # Bridge self-description: every endpoint + event, machine-readable.
    index = call("GET", "/")
    print(f"bridge: {index['service']} — {len(index['endpoints'])} endpoints")

    ready = threading.Event()
    listen_events(lambda e: ready.set() if e.get("kind") == "pageReady" else None, 15)

    # Navigate (a page without a beforeunload guard).
    call("POST", "/navigate", {"url": "https://example.com"})
    ready.wait(timeout=15)
    print("page ready")

    info = call("GET", "/page/url")
    print("page:", info["url"], "|", info.get("title", ""))

    # Download example (small.zip from a local server would be ideal;
    # here we demonstrate the call shape only).
    # call("POST", "/downloads/start", {"url": "https://example.com/file.zip"})

    print("done — full endpoint catalog at GET /")


if __name__ == "__main__":
    main()
