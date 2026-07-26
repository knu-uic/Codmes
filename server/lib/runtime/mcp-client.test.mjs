import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { StreamableHttpMcpClient } from "./mcp-client.mjs";

test("Streamable HTTP MCP uses a fresh server-side bearer for initialize, list, and call", async () => {
  const requests = [];
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    const message = JSON.parse(body);
    requests.push({ authorization: req.headers.authorization, method: message.method });
    const result = message.method === "initialize"
      ? { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "knu", version: "1" } }
      : message.method === "tools/list"
        ? { tools: [{ name: "search_knu_notices", inputSchema: { type: "object" } }] }
        : { content: [{ type: "text", text: "notice" }] };
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  let token = "first-secret";
  const client = new StreamableHttpMcpClient("knu-rag", `http://127.0.0.1:${port}/api/mcp/`, { tokenAccessor: () => token, timeoutMs: 1000 });
  try {
    await client.start();
    token = "rotated-secret";
    assert.equal((await client.listTools())[0].name, "search_knu_notices");
    assert.equal((await client.callTool("search_knu_notices", { query: "registration" })).content[0].text, "notice");
    assert.deepEqual(requests.map((item) => item.method), ["initialize", "notifications/initialized", "tools/list", "tools/call"]);
    assert.deepEqual(requests.map((item) => item.authorization), ["Bearer first-secret", "Bearer first-secret", "Bearer rotated-secret", "Bearer rotated-secret"]);
  } finally {
    client.stop();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("Streamable HTTP MCP redacts bearer material from failures", async () => {
  const client = new StreamableHttpMcpClient("knu-rag", "http://127.0.0.1:1/api/mcp/", {
    tokenAccessor: () => "very-secret-token",
    fetchImpl: async () => { throw new Error("Authorization: Bearer very-secret-token failed"); }
  });
  await assert.rejects(() => client.start(), (error) => {
    assert.doesNotMatch(error.message, /very-secret-token/);
    assert.match(error.message, /REDACTED/);
    return true;
  });
});

test("Streamable HTTP MCP aborts an in-flight request when its timeout expires", async () => {
  let aborted = false;
  const client = new StreamableHttpMcpClient("knu-rag", "http://127.0.0.1:1/api/mcp/", {
    tokenAccessor: () => "secret",
    timeoutMs: 20,
    fetchImpl: async (_input, init) => new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => { aborted = true; reject(new DOMException("aborted", "AbortError")); }, { once: true });
    })
  });
  await assert.rejects(() => client.start(), /timed out/);
  assert.equal(aborted, true);
  assert.equal(client.status, "stopped");
});
