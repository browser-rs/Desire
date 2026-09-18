/**
 * Desire MCP driver example (TypeScript, zero dependencies).
 *
 * Speaks Model Context Protocol over Streamable HTTP directly —
 * initialize → tools/list → tools/call — against Desire's MCP server
 * (http://127.0.0.1:8798/mcp, launch Desire with `--mcp-server`,
 * optionally `--mcp-token <token>`).
 *
 * Run: npx tsx examples/desire-mcp-driver.ts
 */

const MCP_URL = "http://127.0.0.1:8798/mcp";
const TOKEN = process.env.DESIRE_MCP_TOKEN;
let sessionID: string | undefined;
let nextID = 0;

interface RPCResponse {
  result?: { tools?: unknown[]; content?: { type: string; text: string }[] };
  error?: { code: number; message: string };
}

async function rpc(method: string, params?: unknown): Promise<RPCResponse> {
  const body: Record<string, unknown> = { jsonrpc: "2.0", method };
  if (params !== undefined) body.params = params;
  const isNotification = body.id === undefined;

  const response = await fetch(MCP_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      ...(sessionID ? { "Mcp-Session-Id": sessionID } : {}),
      ...(TOKEN ? { Authorization: `Bearer ${TOKEN}` } : {}),
    },
    body: JSON.stringify(body),
  });

  const session = response.headers.get("Mcp-Session-Id");
  if (session && !sessionID) sessionID = session;
  if (!response.ok || isNotification) {
    return {} as RPCResponse;
  }
  return (await response.json()) as RPCResponse;
}

async function main() {
  await rpc("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "desire-example", version: "0.1.0" },
  });
  await rpc("notifications/initialized");

  const listed = await rpc("tools/list", {});
  const tools = (listed.result?.tools ?? []) as { name: string }[];
  console.log(`${tools.length} tools:`, tools.map((t) => t.name).join(", "));

  const navigated = await rpc("tools/call", {
    name: "navigate",
    arguments: { url: "https://example.com" },
  });
  console.log("navigate:", navigated.result?.content?.[0]?.text);

  const text = await rpc("tools/call", {
    name: "getPageText",
    arguments: {},
  });
  console.log(
    "page text:",
    (text.result?.content?.[0]?.text ?? "").slice(0, 120),
  );
}

main().catch((error) => {
  console.error("driver failed:", error);
  process.exit(1);
});
