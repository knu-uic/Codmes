process.env.NODE_ENV = "test";
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { OpenAICompatibleRuntime } from "./openai-compatible-runtime.mjs";
import { setCredentialValue, setDefaultModel, writeRuntimeConfig } from "./config-store.mjs";
import { installPlugin } from "./plugin-registry.mjs";
import { writeSecurityConfig } from "./security-policy.mjs";
import { saveToolModeOverride } from "./tool-mode-registry.mjs";

test("OpenAI-compatible runtime streams chat completions from Codmes config", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-"));
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");

  let request = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (url, options) => {
      request = { url, options, body: JSON.parse(options.body) };
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"안녕"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"하세요"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  const events = [];
  runtime.on("event", (event) => events.push(event));

  const result = await runtime.submitPrompt({
    sessionId: "session-1",
    message: "소개해줘",
    history: [
      { role: "user", content: "이전 질문" },
      { role: "assistant", content: "이전 답변" }
    ],
    context: {
      workspaceContext: {
        workspace: { scopeType: "current", activePath: "Notes/a.md" },
        inlineBlocks: [{ title: "Current resource", path: "Notes/a.md", content: "# Alpha" }]
      }
    }
  });

  assert.equal(result.reply, "안녕하세요");
  assert.equal(request.url, "http://model.test/v1/chat/completions");
  assert.equal(request.options.headers.authorization, "Bearer test-key");
  assert.equal(request.body.model, "demo-model");
  assert.equal(request.body.messages[0].role, "system");
  assert.match(request.body.messages[0].content, /Notes\/a\.md/);
  assert.deepEqual(request.body.messages.slice(-3).map((m) => m.role), ["user", "assistant", "user"]);
  assert.deepEqual(events.map((event) => event.type), ["turn.start", "message.delta", "message.delta", "turn.complete"]);
  assert.equal(typeof events[0].promptTokenEstimate, "number");
  assert.equal(typeof events[0].contextWindow, "number");
  assert.equal(typeof events[0].contextUsageRatio, "number");
});

test("OpenAI-compatible runtime streams Ollama reasoning deltas as activity events", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-ollama-reasoning-"));
  await setDefaultModel(root, "ollama-local", "gemma4:e2b-mlx");

  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async () => ({
      ok: true,
      headers: { get: () => "text/event-stream" },
      body: streamChunks([
        'data: {"choices":[{"delta":{"role":"assistant","content":"","reasoning":"Thinking"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"","reasoning":" Process"}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"안녕하세요"}}]}\n\n',
        'data: [DONE]\n\n'
      ])
    })
  });

  const events = [];
  runtime.on("event", (event) => events.push(event));

  const result = await runtime.submitPrompt({
    sessionId: "session-ollama",
    message: "안녕"
  });

  assert.equal(result.reply, "안녕하세요");
  assert.equal(result.reasoning, "Thinking Process");
  assert.deepEqual(events.map((event) => event.type), [
    "turn.start",
    "reasoning.delta",
    "reasoning.delta",
    "message.delta",
    "turn.complete"
  ]);
  assert.equal(events.filter((event) => event.type === "reasoning.delta").map((event) => event.text).join(""), "Thinking Process");
});

test("OpenAI-compatible runtime uses Codex Responses transport for OpenAI Codex", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-codex-"));
  await writeRuntimeConfig(root, {
    defaultModel: {
      provider: "openai-codex",
      model: "gpt-5.4-mini",
      baseUrl: "https://chatgpt.com/backend-api/codex"
    }
  });
  await setCredentialValue(root, "openai-codex", "access_token", fakeJwt({
    exp: Math.floor(Date.now() / 1000) + 3600,
    "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" }
  }));

  let request = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (url, options) => {
      request = { url, options, body: JSON.parse(options.body) };
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"type":"response.output_text.delta","delta":"안녕"}\n\n',
          'data: {"type":"response.output_text.delta","delta":"하세요"}\n\n',
          'data: {"type":"response.completed","response":{"output":[]}}\n\n'
        ])
      };
    }
  });

  const longSessionId = "session-2026-07-13T09-00-00-000Z-12345678-1234-4234-9234-123456789abc";
  const result = await runtime.submitPrompt({ sessionId: longSessionId, message: "안녕" });

  assert.equal(result.reply, "안녕하세요");
  assert.equal(result.provider, "openai-codex");
  assert.equal(request.url, "https://chatgpt.com/backend-api/codex/responses");
  assert.equal(request.options.headers.authorization.startsWith("Bearer "), true);
  assert.equal(request.options.headers.originator, "codex_cli_rs");
  assert.equal(request.options.headers["ChatGPT-Account-ID"], "acct_test");
  assert.equal(request.body.model, "gpt-5.4-mini");
  assert.equal(request.body.stream, true);
  assert.equal(request.body.store, false);
  assert.equal(typeof request.body.prompt_cache_key, "string");
  assert.ok(request.body.prompt_cache_key.length <= 64);
  assert.equal(typeof request.options.headers.session_id, "string");
  assert.ok(request.options.headers.session_id.length <= 64);
  assert.equal(request.options.headers["x-client-request-id"], request.options.headers.session_id);
  assert.ok(Array.isArray(request.body.input));
  assert.equal(request.body.input.at(-1).content[0].type, "input_text");
});

test("OpenAI-compatible runtime reports setup when no model is selected", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-missing-"));
  const runtime = new OpenAICompatibleRuntime({ workspaceRoot: root });
  await assert.rejects(
    () => runtime.submitPrompt({ sessionId: "session-1", message: "hello" }),
    /No default model is configured/
  );
});

test("OpenAI-compatible runtime injects search results and RAG chunks into model context", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-rag-"));
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");

  let request = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      request = JSON.parse(options.body);
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"찾은 내용을 요약했어요."}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({
    sessionId: "session-1",
    message: "검색 결과로 설명해줘",
    context: {
      workspaceContext: {
        workspace: { scopeType: "workspace", ragRecommended: true },
        searchResults: [
          { path: "Notes/search.md", kind: "markdown", snippet: "검색 결과 스니펫" }
        ],
        ragChunks: [
          { path: "Documents/manual.pdf", page: 3, text: "PDF 청크 내용" }
        ]
      }
    }
  });

  const system = request.messages[0].content;
  assert.match(system, /Search results context/);
  assert.match(system, /Notes\/search\.md/);
  assert.match(system, /검색 결과 스니펫/);
  assert.match(system, /RAG chunk context/);
  assert.match(system, /Documents\/manual\.pdf page 3/);
  assert.match(system, /PDF 청크 내용/);
});

test("OpenAI-compatible runtime executes workspace search tool calls", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-tools-"));
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", "git.md"), "# Git\n\ngit pull brings remote changes.", "utf8");
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");

  const requests = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      if (requests.length === 1) {
        return {
          ok: true,
          headers: { get: () => "text/event-stream" },
          body: streamChunks([
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_search","type":"function","function":{"name":"workspace_search","arguments":"{\\"query\\":\\"git pull\\",\\"scopePath\\":\\"Notes\\"}"}}]}}]}\n\n',
            'data: [DONE]\n\n'
          ])
        };
      }
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"git pull 설명을 찾았어요."}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  const events = [];
  runtime.on("event", (event) => events.push(event));

  const result = await runtime.submitPrompt({
    sessionId: "session-1",
    message: "git pull 관련 노트 있어?"
  });

  assert.equal(result.reply, "git pull 설명을 찾았어요.");
  assert.equal(result.toolRounds, 1);
  assert.equal(requests.length, 2);
  assert.ok(requests[0].tools.some((tool) => tool.function.name === "workspace_search"));
  const toolMessage = requests[1].messages.find((message) => message.role === "tool");
  assert.equal(toolMessage.name, "workspace_search");
  assert.match(toolMessage.content, /Notes\/git\.md/);
  assert.deepEqual(events.map((event) => event.type), [
    "turn.start",
    "tool.start",
    "tool.complete",
    "message.delta",
    "turn.complete"
  ]);
});

test("OpenAI-compatible runtime filters tools by surface defaults", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-surface-tools-"));
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");

  const requests = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({ sessionId: "chat-session", message: "hello", surface: "chat" });
  await runtime.submitPrompt({ sessionId: "notes-session", message: "search notes", surface: "notes" });
  await runtime.submitPrompt({ sessionId: "code-session", message: "inspect code", surface: "code" });

  const chatTools = new Set(requests[0].tools.map((tool) => tool.function.name));
  const notesTools = new Set(requests[1].tools.map((tool) => tool.function.name));
  const codeTools = new Set(requests[2].tools.map((tool) => tool.function.name));
  assert.match(requests[0].messages[0].content, /Surface mode: Chat/);
  assert.match(requests[1].messages[0].content, /Surface mode: Notes/);
  assert.match(requests[2].messages[0].content, /Surface mode: Code/);

  assert.equal(chatTools.has("conversation_search"), true);
  assert.equal(chatTools.has("memory_search"), true);
  assert.equal(chatTools.has("workspace_search"), false);
  assert.equal(chatTools.has("search_project"), false);

  assert.equal(notesTools.has("codmes_search"), true);
  assert.equal(notesTools.has("read_note_file"), true);
  assert.equal(notesTools.has("apply_patch"), false);

  assert.equal(codeTools.has("search_project"), true);
  assert.equal(codeTools.has("apply_patch"), true);
  assert.equal(codeTools.has("codmes_search"), false);
});

test("OpenAI-compatible runtime expands discovered safe tools within the same turn", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-discovery-"));
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", "rag.md"), "Codmes search indexes notes and PDFs.", "utf8");
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");

  const requests = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      if (requests.length === 1) {
        return {
          ok: true,
          headers: { get: () => "text/event-stream" },
          body: streamChunks([
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_discover","type":"function","function":{"name":"tool_discovery","arguments":"{\\"reason\\":\\"need indexed document search\\",\\"desiredCapability\\":\\"search indexed pdf notes documents\\"}"}}]}}]}\n\n',
            'data: [DONE]\n\n'
          ])
        };
      }
      if (requests.length === 2) {
        return {
          ok: true,
          headers: { get: () => "text/event-stream" },
          body: streamChunks([
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_codmes_search","type":"function","function":{"name":"codmes_search","arguments":"{\\"query\\":\\"Codmes search\\",\\"scopePath\\":\\"Notes\\"}"}}]}}]}\n\n',
            'data: [DONE]\n\n'
          ])
        };
      }
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"Codmes search 결과를 확인했어요."}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });
  const events = [];
  runtime.on("event", (event) => events.push(event));

  const result = await runtime.submitPrompt({
    sessionId: "session-discovery",
    message: "문서 검색이 필요해",
    surface: "chat"
  });

  assert.equal(result.reply, "Codmes search 결과를 확인했어요.");
  assert.equal(result.toolRounds, 2);
  assert.equal(requests.length, 3);
  assert.equal(requests[0].tools.some((tool) => tool.function.name === "codmes_search"), false);
  assert.equal(requests[1].tools.some((tool) => tool.function.name === "codmes_search"), true);
  const toolMessages = requests[2].messages.filter((message) => message.role === "tool");
  assert.equal(toolMessages[0].name, "tool_discovery");
  assert.equal(toolMessages[1].name, "codmes_search");
  assert.match(toolMessages[1].content, /Notes\/rag\.md/);
  assert.equal(events.some((event) => event.type === "tool.discovery.request"), true);
  assert.equal(events.some((event) => event.type === "tool.discovery.result"), true);
  assert.equal(events.some((event) => event.type === "tool.expansion.applied" && event.expandedTools.includes("codmes_search")), true);

  await runtime.submitPrompt({
    sessionId: "session-discovery",
    message: "다음 질문",
    surface: "chat"
  });
  assert.equal(requests[3].tools.some((tool) => tool.function.name === "codmes_search"), false);
});

test("OpenAI-compatible runtime blocks discovered tools disabled by surface mode", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-discovery-blocked-"));
  await setDefaultModel(root, "custom", "demo-model");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_BASE_URL", "http://model.test/v1");
  await setCredentialValue(root, "custom", "CODMES_CUSTOM_API_KEY", "test-key");
  await saveToolModeOverride(root, "chat", {
    mode: "custom",
    enabledTools: ["tool_discovery", "conversation_search", "conversation_read", "memory_search"],
    disabledTools: ["codmes_search"]
  });

  const requests = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      if (requests.length === 1) {
        return {
          ok: true,
          headers: { get: () => "text/event-stream" },
          body: streamChunks([
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_discover","type":"function","function":{"name":"tool_discovery","arguments":"{\\"reason\\":\\"need indexed document search\\",\\"desiredCapability\\":\\"search indexed pdf notes documents\\"}"}}]}}]}\n\n',
            'data: [DONE]\n\n'
          ])
        };
      }
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"검색 도구는 차단되어 있어요."}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });
  const events = [];
  runtime.on("event", (event) => events.push(event));

  await runtime.submitPrompt({ sessionId: "blocked-discovery", message: "문서 검색", surface: "chat" });
  assert.equal(requests[1].tools.some((tool) => tool.function.name === "codmes_search"), false);
  assert.equal(events.some((event) => event.type === "tool.expansion.blocked"), true);
});

async function* streamChunks(chunks) {
  for (const chunk of chunks) yield Buffer.from(chunk, "utf8");
}

async function writeMockMcpServer(root, { tools, handler }) {
  const script = `
import readline from "readline";

const tools = ${JSON.stringify(tools)};
let callCount = 0;
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line);
    if (req.method === "initialize") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "mock-mcp", version: "1.0.0" }
        }
      }) + "\\n");
    } else if (req.method === "tools/list") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: { tools }
      }) + "\\n");
    } else if (req.method === "tools/call") {
      callCount += 1;
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          content: [
            { type: "text", text: "${handler} called " + callCount }
          ]
        }
      }) + "\\n");
    }
  } catch (err) {}
});
`;
  const serverPath = path.join(root, "mock-approval-mcp.mjs");
  await fs.writeFile(serverPath, script, "utf8");
  return serverPath;
}

test("OpenAI-compatible runtime executes fallback provider chain on error", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-fallback-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "primary-key");
  await setCredentialValue(root, "lmstudio", "CODMES_LM_API_KEY", "fallback-key");

  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    fallbackChain: ["lmstudio:local-model"]
  });

  const calls = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (url, options) => {
      calls.push({ url, body: JSON.parse(options.body) });
      if (calls.length === 1) {
        return {
          ok: false,
          status: 429,
          text: async () => "Rate limit exceeded"
        };
      }
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"성공"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  const events = [];
  runtime.on("event", (event) => events.push(event));

  const result = await runtime.submitPrompt({
    sessionId: "session-fallback",
    message: "테스트"
  });

  assert.equal(result.reply, "성공");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].body.model, "gpt-5.5");
  assert.equal(calls[1].body.model, "local-model");
  assert.ok(events.some(e => e.type === "fallback.attempt"));
});

test("OpenAI-compatible runtime filters tools using disabledTools config", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-tools-filter-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");

  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    disabledTools: ["workspace_search"]
  });

  let sentTools = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (url, options) => {
      const body = JSON.parse(options.body);
      sentTools = body.tools;
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"필터 완료"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({ sessionId: "session-1", message: "안녕" });
  assert.ok(sentTools);
  assert.equal(sentTools.some(t => t.function.name === "workspace_search"), false);
  assert.equal(sentTools.some(t => t.function.name === "workspace_read_file"), true);
});

test("OpenAI-compatible runtime global disabledTools can block core recall tools", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-core-disabled-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");

  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    disabledTools: ["memory_search"]
  });

  let sentTools = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      sentTools = JSON.parse(options.body).tools;
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"필터 완료"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({ sessionId: "session-core-disabled", message: "안녕", surface: "chat" });
  assert.equal(sentTools.some(t => t.function.name === "memory_search"), false);
  assert.equal(sentTools.some(t => t.function.name === "conversation_search"), true);
});

test("OpenAI-compatible runtime exposes MCP tools and executes them via stdio JSON-RPC", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-mcp-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");

  const mockMcpScript = `
import readline from "readline";

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on("line", (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line);
    if (req.method === "initialize") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "mock-calculator", version: "1.0.0" }
        }
      }) + "\\n");
    } else if (req.method === "tools/list") {
      process.stdout.write(JSON.stringify({
        jsonrpc: "2.0",
        id: req.id,
        result: {
          tools: [
            {
              name: "add",
              description: "Add two numbers",
              inputSchema: {
                type: "object",
                properties: {
                  a: { type: "number" },
                  b: { type: "number" }
                },
                required: ["a", "b"]
              }
            }
          ]
        }
      }) + "\\n");
    } else if (req.method === "tools/call") {
      const { a, b } = req.params.arguments || {};
      if (req.params.name === "add") {
        process.stdout.write(JSON.stringify({
          jsonrpc: "2.0",
          id: req.id,
          result: {
            content: [
              { type: "text", text: String((a || 0) + (b || 0)) }
            ]
          }
        }) + "\\n");
      } else {
        process.stdout.write(JSON.stringify({
          jsonrpc: "2.0",
          id: req.id,
          error: { code: -32601, message: "Method not found" }
        }) + "\\n");
      }
    }
  } catch (err) {}
});
`;
  const serverPath = path.join(root, "mock-server.mjs");
  await fs.writeFile(serverPath, mockMcpScript, "utf8");

  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    mcpServers: [
      { name: "calculator", command: "node", args: [serverPath], enabled: true }
    ]
  });

  let sentTools = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (url, options) => {
      const body = JSON.parse(options.body);
      sentTools = body.tools;
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"mcp tool found"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({ sessionId: "session-1", message: "계산해줘" });
  assert.ok(sentTools);
  assert.equal(sentTools.some(t => t.function.name === "mcp__calculator__add"), true);

  const execResult = await runtime.executeToolCall({
    id: "call_mcp",
    name: "mcp__calculator__add",
    arguments: '{"a":5,"b":10}'
  }, { sessionId: "session-1" });

  assert.equal(execResult.ok, true);
  assert.deepEqual(execResult.output, [{ type: "text", text: "15" }]);

  runtime.close();
});

test("OpenAI-compatible runtime exposes remote MCP tools only on the configured Chat surface", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-remote-mcp-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");
  await writeRuntimeConfig(root, { defaultModel: { provider: "openai-api", model: "gpt-5.5" }, mcpServers: [{ name: "knu-rag", transport: "streamable_http", url: "https://example.test/api/mcp/", credential_id: "knu-rag", surfaces: ["chat"], enabled: true }] });
  let sentTools = [];
  let starts = 0;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    mcpClientFactory: () => ({ status: "stopped", async start() { starts += 1; this.status = "running"; }, async listTools() { return [{ name: "search_knu_notices", inputSchema: { type: "object" } }]; }, stop() {} }),
    fetchImpl: async (_url, options) => ({ ok: true, headers: { get: () => "text/event-stream" }, body: (sentTools = JSON.parse(options.body).tools, streamChunks(['data: {"choices":[{"delta":{"content":"ok"}}]}\n\n', "data: [DONE]\n\n"])) })
  });
  await runtime.submitPrompt({ sessionId: "chat-remote-mcp", message: "공지 찾아줘", surface: "chat" });
  assert.equal(starts, 1);
  assert.equal(sentTools.some((tool) => tool.function.name === "mcp__knu_rag__search_knu_notices"), true, JSON.stringify(sentTools));
  await runtime.submitPrompt({ sessionId: "notes-remote-mcp", message: "공지 찾아줘", surface: "notes" });
  assert.equal(sentTools.some((tool) => tool.function.name === "mcp__knu_rag__search_knu_notices"), false);
  assert.equal(starts, 1);
  runtime.close();
});

test("OpenAI-compatible runtime exposes a plugin-declared public name through the common Tool Registry", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-plugin-tool-"));
  const source = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-plugin-source-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");
  await fs.writeFile(path.join(source, "plugin.json"), JSON.stringify({
    schemaVersion: 1,
    id: "kr.ac.kongju.knu",
    version: "0.3.0",
    name: "KNU",
    platforms: ["macos", "ios"],
    surface: {
      id: "knu",
      type: "declarative",
      title: "KNU",
      upstreamUrl: "http://127.0.0.1:8000",
      entryPath: "/api/notices",
      navigation: [{ id: "notices", title: "Notices", path: "/api/notices" }]
    },
    mcp: {
      name: "knu",
      transport: "streamable_http",
      url: "http://127.0.0.1:8000/api/mcp",
      surfaces: ["knu"],
      allowUnauthenticated: true,
      requiresApproval: true
    },
    tools: {
      schemaVersion: 1,
      tools: [{
        name: "knu_search_notices",
        description: "Search current KNU notices.",
        inputSchema: {
          type: "object",
          properties: { query: { type: "string" } },
          required: ["query"]
        },
        provider: { type: "mcp", server: "knu", tool: "search_knu_notices" },
        requiresApproval: true,
        readOnly: true
      }]
    }
  }), "utf8");
  await installPlugin(root, source);
  await writeSecurityConfig(root, {
    approvalMode: "suggest",
    allowShell: true,
    allowedCommands: [],
    deniedCommands: [],
    requireApproval: []
  });

  let sentTools = [];
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    mcpClientFactory: () => ({
      status: "stopped",
      async start() { this.status = "running"; },
      async listTools() {
        return [{
          name: "search_knu_notices",
          description: "Dynamic description",
          inputSchema: {
            type: "object",
            properties: { query: { type: "string" } },
            required: ["query"]
          }
        }];
      },
      async callTool(name, args) {
        return {
          content: [{
            type: "text",
            text: `${name}:${args.query}`
          }]
        };
      },
      stop() {}
    }),
    fetchImpl: async (_url, options) => ({
      ok: true,
      headers: { get: () => "text/event-stream" },
      body: (
        sentTools = JSON.parse(options.body).tools,
        streamChunks(['data: {"choices":[{"delta":{"content":"ok"}}]}\n\n', "data: [DONE]\n\n"])
      )
    })
  });

  await runtime.submitPrompt({
    sessionId: "knu-plugin-tool",
    message: "공지 찾아줘",
    surface: "knu"
  });
  assert.equal(sentTools.some((tool) => tool.function.name === "knu_search_notices"), true);
  assert.equal(sentTools.some((tool) => tool.function.name === "mcp__knu__search_knu_notices"), false);
  assert.equal(runtime.toolRegistry.get("knu_search_notices").provider.type, "mcp");
  assert.equal(runtime.toolRegistry.get("knu_search_notices").pluginId, "kr.ac.kongju.knu");
  const result = await runtime.executeToolCall({
    id: "knu-search-call",
    name: "knu_search_notices",
    arguments: { query: "수강 철회" }
  }, {
    sessionId: "knu-plugin-tool",
    surface: "knu",
    approved: true
  });
  assert.deepEqual(result.output, [{
    type: "text",
    text: "search_knu_notices:수강 철회"
  }]);

  await runtime.createSession({
    sessionId: "knu-plugin-full",
    accessMode: "full"
  });
  const fullModeResult = await runtime.executeToolCall({
    id: "knu-search-full-call",
    name: "knu_search_notices",
    arguments: { query: "한미 대학생 연수" }
  }, {
    sessionId: "knu-plugin-full",
    surface: "knu"
  });
  assert.deepEqual(fullModeResult.output, [{
    type: "text",
    text: "search_knu_notices:한미 대학생 연수"
  }]);
  runtime.close();
});

test("Planner calendar writes require approval in Safe mode and execute immediately in Full mode", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-calendar-mode-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");
  await installPlugin(root, path.resolve("marketplace/sources/planner"));
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async () => ({
      ok: true,
      headers: { get: () => "text/event-stream" },
      body: streamChunks(['data: {"choices":[{"delta":{"content":"ok"}}]}\n\n', "data: [DONE]\n\n"])
    })
  });
  await runtime.createSession({ sessionId: "calendar-safe", accessMode: "confirm" });
  await runtime.submitPrompt({ sessionId: "calendar-safe", message: "일정 생성", surface: "planner" });
  const call = {
    id: "calendar-create",
    name: "calendar_create",
    arguments: {
      item: {
        title: "회의",
        startsAt: "2026-08-01T10:00:00+09:00",
        endsAt: "2026-08-01T11:00:00+09:00"
      }
    }
  };
  await assert.rejects(
    () => runtime.executeToolCall(call, { sessionId: "calendar-safe", surface: "planner" }),
    (error) => error.approvalRequired === true
      && error.pendingState.preview.operation === "create"
  );
  await runtime.createSession({ sessionId: "calendar-full", accessMode: "full" });
  await runtime.submitPrompt({ sessionId: "calendar-full", message: "일정 생성", surface: "planner" });
  const created = await runtime.executeToolCall(call, {
    sessionId: "calendar-full",
    surface: "planner"
  });
  assert.equal(created.created, true);
  runtime.close();
});

test("OpenAI-compatible runtime routes MCP tools with underscores through the registry map", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-mcp-underscore-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");
  const serverPath = await writeMockMcpServer(root, {
    tools: [
      {
        name: "search_pdf",
        description: "Search indexed PDF documents",
        inputSchema: { type: "object", properties: { query: { type: "string" } } }
      }
    ],
    handler: "search_pdf"
  });
  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    mcpServers: [
      { name: "doc_search", command: "node", args: [serverPath], enabled: true }
    ]
  });

  let sentTools = null;
  const runtime = new OpenAICompatibleRuntime({
    workspaceRoot: root,
    fetchImpl: async (_url, options) => {
      sentTools = JSON.parse(options.body).tools;
      return {
        ok: true,
        headers: { get: () => "text/event-stream" },
        body: streamChunks([
          'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n',
          'data: [DONE]\n\n'
        ])
      };
    }
  });

  await runtime.submitPrompt({ sessionId: "session-mcp-underscore", message: "search", surface: "notes" });
  assert.equal(sentTools.some(t => t.function.name === "mcp__doc_search__search_pdf"), false);

  const result = await runtime.executeToolCall({
    id: "call_search_pdf",
    name: "mcp__doc_search__search_pdf",
    arguments: '{"query":"architecture"}'
  }, { sessionId: "session-mcp-underscore" });
  assert.equal(result.ok, true);
  assert.deepEqual(result.output, [{ type: "text", text: "search_pdf called 1" }]);
  runtime.close();
});

test("OpenAI-compatible runtime codmes_search uses Codmes native workspace search", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-codmes-search-"));
  await fs.mkdir(path.join(root, "Notes"), { recursive: true });
  await fs.writeFile(path.join(root, "Notes", "a.md"), "architecture note", "utf8");
  await writeRuntimeConfig(root, {
    mcpServers: [
      { name: "unrelated_search_mcp", command: "node", args: ["unused.js"], enabled: true }
    ]
  });

  const runtime = new OpenAICompatibleRuntime({ workspaceRoot: root });
  const result = await runtime.executeToolCall({
    id: "call_codmes_search",
    name: "codmes_search",
    arguments: '{"query":"architecture"}'
  }, { sessionId: "session-codmes-search", surface: "notes" });

  assert.equal(result.ok, true);
  assert.equal(result.source, "codmes-search");
  assert.equal(result.fallbackUsed, false);
  assert.match(result.results[0].snippet, /architecture note/);
  runtime.close();
});

test("OpenAI-compatible runtime does not swallow MCP approvalRequired errors", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-mcp-approval-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "test-key");
  await writeSecurityConfig(root, {
    approvalMode: "auto",
    allowShell: true,
    allowedCommands: [],
    deniedCommands: [],
    requireApproval: ["mcp.tool.call"]
  });

  const serverPath = await writeMockMcpServer(root, {
    tools: [
      {
        name: "delete_file",
        description: "Delete a file",
        inputSchema: {
          type: "object",
          properties: { path: { type: "string" } },
          required: ["path"]
        }
      }
    ],
    handler: "delete_file"
  });
  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    mcpServers: [
      { name: "fs", command: "node", args: [serverPath], enabled: true }
    ]
  });

  const runtime = new OpenAICompatibleRuntime({ workspaceRoot: root });
  const events = [];
  runtime.on("event", (event) => events.push(event));

  await assert.rejects(
    () => runtime.executeToolCall({
      id: "call_delete",
      name: "mcp__fs__delete_file",
      arguments: "{\"path\":\"Notes/a.md\"}"
    }, {
      sessionId: "session-approval",
      taskId: "task-approval"
    }),
    (error) => {
      assert.equal(error.approvalRequired, true);
      assert.equal(error.category, "mcp.tool.call");
      assert.equal(error.pendingState.toolName, "delete_file");
      return true;
    }
  );
  assert.equal(events.some((event) => event.type === "approval.required"), true);
  assert.equal(events.some((event) => event.type === "tool.error"), false);

  runtime.close();
});

test("McpClient server crash handling and timeout error", async () => {
  const { McpClient } = await import("./mcp-client.mjs");
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-mcp-crash-"));
  
  const timeoutServerScript = `
import readline from "readline";
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
rl.on("line", (line) => {
  const req = JSON.parse(line);
  if (req.method === "initialize") {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: req.id,
      result: { protocolVersion: "2024-11-05", capabilities: {}, serverInfo: { name: "timeout-server" } }
    }) + "\\n");
  }
});

`;
  const timeoutServerPath = path.join(root, "timeout-server.mjs");
  await fs.writeFile(timeoutServerPath, timeoutServerScript, "utf8");

  const client = new McpClient("timeout", "node", [timeoutServerPath]);
  await client.start();

  await assert.rejects(
    () => client.sendRequest("tools/list", {}, 100),
    /timed out/
  );

  client.stop();

  const crashServerScript = `
process.exit(1);
`;
  const crashServerPath = path.join(root, "crash-server.mjs");
  await fs.writeFile(crashServerPath, crashServerScript, "utf8");

  const crashClient = new McpClient("crash", "node", [crashServerPath]);
  await assert.rejects(
    () => crashClient.start(),
    /exited with code 1/
  );
  
  crashClient.stop();
});

test("OpenAI-compatible runtime fallback conditions separation", async () => {
  const { classifyError } = await import("./openai-compatible-runtime.mjs");

  assert.equal(classifyError({ status: 429 }), "rate_limit");
  assert.equal(classifyError(new Error("Rate limit exceeded")), "rate_limit");
  assert.equal(classifyError(new Error("Too many requests")), "rate_limit");

  assert.equal(classifyError({ status: 401 }), "auth_error");
  assert.equal(classifyError({ status: 403 }), "auth_error");
  assert.equal(classifyError(new Error("unauthorized access")), "auth_error");
  assert.equal(classifyError(new Error("needs an API key")), "auth_error");

  assert.equal(classifyError(new Error("fetch failed")), "network_error");
  assert.equal(classifyError(new Error("getaddrinfo ENOTFOUND")), "network_error");
  assert.equal(classifyError({ status: 504 }), "network_error");

  assert.equal(classifyError({ status: 503 }), "provider_unavailable");
  assert.equal(classifyError(new Error("Unknown provider: foo")), "provider_unavailable");

  assert.equal(classifyError({ status: 404 }), "model_unavailable");
  assert.equal(classifyError(new Error("Unknown model")), "model_unavailable");
});

test("SessionRuntime rename, export, and prune", async () => {
  const { SessionRuntime, titleFromFirstUserMessage } = await import("../session-runtime.mjs");
  const { WorkspaceAgentStateStore } = await import("../agent-engine.mjs");

  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-sessions-test-"));
  const stateStore = new WorkspaceAgentStateStore(root);
  await stateStore.ensure();

  const sessionRuntime = new SessionRuntime({ stateStore });

  const sessionId = "sess-123";
  const sessionObj = {
    id: sessionId,
    title: "Old Title",
    model: "demo-model",
    preview: "",
    updatedAt: new Date().toISOString(),
    messages: [
      { role: "user", content: "안녕", createdAt: new Date().toISOString() },
      { role: "assistant", content: "반가워", createdAt: new Date().toISOString() }
    ]
  };
  await stateStore.writeSession(sessionObj);

  const renameRes = await sessionRuntime.renameSession(sessionId, "New Title");
  assert.equal(renameRes.ok, true);
  const updated = await stateStore.readSession(sessionId);
  assert.equal(updated.title, "New Title");

  const exportRes = await sessionRuntime.exportSession(sessionId);
  assert.equal(exportRes.ok, true);
  assert.match(exportRes.markdown, /# Session: New Title/);
  assert.match(exportRes.markdown, /## USER\n안녕/);

  const autotitleSessionId = "sess-autotitle";
  await stateStore.writeSession({
    id: autotitleSessionId,
    title: "Session 7/13/2026",
    updatedAt: new Date().toISOString(),
    messages: []
  });
  await sessionRuntime.appendSessionMessage(autotitleSessionId, {
    role: "user",
    content: "내가 공부한 것 중에 예제 들어서 설명해 줄 수있어?"
  });
  const autotitled = await stateStore.readSession(autotitleSessionId);
  assert.equal(autotitled.title, "내가 공부한 것 중에 예제 들어서 설명해 줄 수있어");
  assert.equal(titleFromFirstUserMessage("이 파일 설명 좀 해줘"), "이 파일 설명 좀 해줘");

  const legacySessionId = "sess-legacy-title";
  await stateStore.writeSession({
    id: legacySessionId,
    title: "Codmes Chat 2026. 7. 13. AM 10:36:15",
    updatedAt: new Date().toISOString(),
    messages: [
      { role: "user", content: "너를 표로 소개해봐", createdAt: new Date().toISOString() }
    ]
  });
  const listed = await sessionRuntime.listSessions(20, { includeArchived: true });
  const repaired = listed.sessions.find((session) => session.id === legacySessionId);
  assert.equal(repaired.title, "너를 표로 소개해봐");
  const repairedStored = await stateStore.readSession(legacySessionId);
  assert.equal(repairedStored.title, "너를 표로 소개해봐");

  const emptySessionId = "sess-empty";
  await stateStore.writeSession({
    id: emptySessionId,
    title: "Empty Session",
    updatedAt: new Date().toISOString(),
    messages: []
  });

  const pruneRes = await sessionRuntime.pruneSessions();
  assert.equal(pruneRes.ok, true);
  assert.equal(pruneRes.pruned, 1);

  const emptySession = await stateStore.readSession(emptySessionId);
  assert.equal(emptySession, null);
});

test("OpenAI-compatible runtime fallback event condition mapping", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-openai-runtime-fallback-cond-"));
  await setDefaultModel(root, "openai-api", "gpt-5.5");
  await setCredentialValue(root, "openai-api", "CODMES_OPENAI_API_KEY", "primary-key");
  await setCredentialValue(root, "lmstudio", "CODMES_LM_API_KEY", "fallback-key");

  await writeRuntimeConfig(root, {
    defaultModel: { provider: "openai-api", model: "gpt-5.5" },
    fallbackChain: ["lmstudio:local-model"]
  });

  const conditions = [
    { status: 429, expected: "rate_limit" },
    { status: 401, expected: "auth_error" },
    { status: 504, expected: "network_error" },
    { status: 404, expected: "model_unavailable" },
    { status: 503, expected: "provider_unavailable" }
  ];

  for (const cond of conditions) {
    let fallbackEvent = null;
    const runtime = new OpenAICompatibleRuntime({
      workspaceRoot: root,
      fetchImpl: async () => {
        return {
          ok: false,
          status: cond.status,
          text: async () => "Mock Error"
        };
      }
    });

    runtime.on("event", (e) => {
      if (e.type === "fallback.attempt") {
        fallbackEvent = e;
      }
    });

    try {
      await runtime.submitPrompt({ sessionId: "session-fallback-cond", message: "테스트" });
    } catch {
      // fine
    }

    assert.ok(fallbackEvent, `Fallback event should be emitted for status ${cond.status}`);
    assert.equal(fallbackEvent.condition, cond.expected);
  }
});

test("McpClient lifecycle: initialize, list, call, idle-timeout, and logs", async () => {
  const { McpClient } = await import("./mcp-client.mjs");
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "codmes-mcp-lifecycle-"));

  const mockMcpScript = `
import readline from "readline";

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on("line", (line) => {
  if (!line.trim()) return;
  const req = JSON.parse(line);
  if (req.method === "initialize") {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: req.id,
      result: {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "mock-lifecycle", version: "1.0.0" }
      }
    }) + "\\n");
  } else if (req.method === "tools/list") {
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: req.id,
      result: {
        tools: [{ name: "test_tool", description: "A test tool" }]
      }
    }) + "\\n");
  } else if (req.method === "tools/call") {
    process.stderr.write("mcp log test\\n");
    process.stdout.write(JSON.stringify({
      jsonrpc: "2.0",
      id: req.id,
      result: { content: [{ type: "text", text: "hello " + req.params.arguments.val }] }
    }) + "\\n");
  }
});
`;

  const serverPath = path.join(root, "mock-server.mjs");
  await fs.writeFile(serverPath, mockMcpScript, "utf8");

  const client = new McpClient("lifecycle", "node", [serverPath], {
    workspaceRoot: root,
    idleTimeoutMs: 100
  });

  await client.start();
  assert.equal(client.status, "running");

  const tools = await client.listTools();
  assert.equal(tools.length, 1);
  assert.equal(tools[0].name, "test_tool");

  const res = await client.callTool("test_tool", { val: "world" });
  assert.deepEqual(res.content, [{ type: "text", text: "hello world" }]);

  const logFile = path.join(root, ".codmes", "tool-logs", "mcp-lifecycle.stderr.log");
  const logContent = await fs.readFile(logFile, "utf8");
  assert.match(logContent, /mcp log test/);

  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(client.status, "stopped");

  const res2 = await client.callTool("test_tool", { val: "lazy" });
  assert.equal(client.status, "running");
  assert.deepEqual(res2.content, [{ type: "text", text: "hello lazy" }]);

  client.stop();
  assert.equal(client.status, "stopped");
});

function fakeJwt(payload) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({ alg: "none", typ: "JWT" })}.${encode(payload)}.signature`;
}
