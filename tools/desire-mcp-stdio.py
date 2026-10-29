#!/usr/bin/env python3
"""Desire MCP server over stdio (shim for clients without HTTP transport).

Forwards newline-delimited JSON-RPC to Desire's local MCP endpoint.
Requires Desire running with --mcp-server (default port 8798; override with
DESIRE_MCP_URL).
"""
import json
import os
import sys
import urllib.request

URL = os.environ.get("DESIRE_MCP_URL", "http://127.0.0.1:8798/mcp")


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        request = urllib.request.Request(
            URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=900) as response:
                body = response.read().decode("utf-8", "replace")
        except Exception as error:  # bridge down / app not running
            if payload.get("id") is None:
                continue
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": payload.get("id"),
                "error": {
                    "code": -32603,
                    "message": f"Desire MCP bridge unreachable at {URL}: {error}",
                },
            }), flush=True)
            continue
        if payload.get("id") is None:
            continue  # notifications get no response
        if body:
            print(body, flush=True)


if __name__ == "__main__":
    main()
